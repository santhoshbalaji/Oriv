import AppKit
import BrowserEngine
import SwiftUI
import os.signpost

private let sidebarDragLog = OSLog(subsystem: "Oriv", category: "SidebarDrag")

@MainActor @Observable final class SidebarListHandle {
    @ObservationIgnored weak var collection: SidebarTabCollection?
    var hasFocus = false

    func focus(_ id: UUID? = nil) { collection?.focusTab(id) }

    func frame(for id: UUID) -> NSRect? {
        guard let collection, let path = collection.sidebar?.path(for: id),
              let item = collection.item(at: path), item.view.frame.intersects(collection.visibleRect) else { return nil }
        return item.view.convert(item.view.bounds, to: nil)
    }
}

struct NativeSidebarTabs: NSViewRepresentable {
    let controller: BrowserController
    var profiles: BrowserProfiles? = nil
    let handle: SidebarListHandle
    var tabs: [BrowserTab]
    var duplicateTitles: Set<String>
    let rail: Bool
    let peek: Bool
    let expandedWidth: CGFloat
    let searchRequest: ProfileScoped<SidebarTabQuery>?
    var searching: Bool { searchRequest != nil }
    let confirmClose: (UUID, Bool) -> Void

    func makeCoordinator() -> SidebarCollectionData { SidebarCollectionData() }

    func makeNSView(context: Context) -> SidebarTabScrollView {
        let list = SidebarTabCollection()
        list.collectionViewLayout = SidebarTabLayout()
        list.dataSource = context.coordinator
        list.delegate = context.coordinator
        list.sidebar = context.coordinator
        list.isSelectable = true
        list.allowsEmptySelection = false
        list.backgroundColors = [.clear]
        list.focusRingType = .none
        list.setAccessibilityLabel("Sidebar tabs")
        list.setAccessibilityIdentifier("sidebarTabs")
        list.register(SidebarCollectionItem.self, forItemWithIdentifier: SidebarCollectionItem.identifier)
        list.register(SidebarCollectionHeader.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                      withIdentifier: SidebarCollectionHeader.identifier)
        list.registerForDraggedTypes([SidebarCollectionData.pasteboardType])
        list.setDraggingSourceOperationMask(.move, forLocal: true)
        list.setDraggingSourceOperationMask([], forLocal: false)

        let scroll = SidebarTabScrollView()
        scroll.horizontalScrollElasticity = .none
        scroll.drawsBackground = false
        scroll.contentView = SidebarTabClipView()
        scroll.contentView.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = list
        context.coordinator.list = list
        return scroll
    }

    func updateNSView(_ scroll: SidebarTabScrollView, context: Context) {
        guard let list = context.coordinator.list else { return }
        scroll.profiles = profiles?.controller === controller ? profiles : nil
        // Legacy scrollbars reserve space even when idle. In the rail,
        // wheel/trackpad and keyboard scrolling use the entire rail viewport.
        let direction: NSUserInterfaceLayoutDirection = context.environment.layoutDirection == .rightToLeft ? .rightToLeft : .leftToRight
        scroll.userInterfaceLayoutDirection = direction
        list.userInterfaceLayoutDirection = direction
        let iconLayout = rail || peek
        scroll.usesIconLayout = iconLayout
        scroll.scrollerStyle = iconLayout ? .overlay : NSScroller.preferredScrollerStyle
        scroll.hasVerticalScroller = !iconLayout
        handle.collection = list
        let profileChanged = context.coordinator.controller.map { $0 !== controller } ?? false
        if profileChanged { list.resetKeyboardNavigation() }
        context.coordinator.update(self, environment: context.environment)
        if iconLayout, profileChanged, !context.environment.browserReduceMotion {
            scroll.wantsLayer = true
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.15
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            scroll.layer?.add(fade, forKey: "profileRailFade")
        }
        scroll.tile()
    }

    static func dismantleNSView(_ view: SidebarTabScrollView, coordinator: SidebarCollectionData) {
        coordinator.detach()
    }
}

/// One AppKit collection keeps selection, keyboard movement and the native
/// drag source intact between the tile grid, headings and full-width rows.
private final class SidebarTabLayout: NSCollectionViewLayout {
    struct Gap: Equatable {
        let section: Int
        let slot: Int
    }

    struct Drop {
        let target: SidebarDropTarget
        let gap: Gap
    }

    private struct SectionGeometry {
        let header: NSRect
        let itemsTop: CGFloat
        let end: CGFloat
        let count: Int
        let columns: Int
        let x: CGFloat
        let width: CGFloat
        let height: CGFloat
        let spacing: CGFloat
        let rtl: Bool

        var pitch: CGFloat { height + spacing }

        func frame(at slot: Int) -> NSRect {
            let deltaX = CGFloat(slot % columns) * (width + spacing)
            return NSRect(x: rtl ? x - deltaX : x + deltaX,
                          y: itemsTop + CGFloat(slot / columns) * pitch, width: width, height: height)
        }

        func visibleSlots(in rect: NSRect) -> Range<Int> {
            let rows = CGFloat((count + columns - 1) / columns)
            let firstRow = min(rows, max(0, floor((rect.minY - itemsTop) / pitch)))
            let endRow = min(rows, max(firstRow, ceil((rect.maxY - itemsTop) / pitch)))
            let first = min(count, Int(firstRow) * columns)
            let end = min(count, Int(endRow) * columns)
            return first..<end
        }

        func slot(at point: NSPoint) -> Int {
            let lastRow = CGFloat((count - 1) / columns)
            let row = Int(min(lastRow, max(0, (point.y - itemsTop) / pitch)))
            let leading = rtl ? x + width - point.x : point.x - x
            let column = min(columns - 1, max(0, Int(leading / (width + spacing))))
            return min(count - 1, row * columns + column)
        }
    }

    private var base: [SectionGeometry] = []
    private var projected: [SectionGeometry] = []
    private var source: IndexPath?
    private var hiddenSource: IndexPath?
    private var projectedGap: Gap?
    private var contentSize = NSSize.zero
    var preview: Gap?
    var hidesSource = false
    var landing: IndexPath?
    var gapFrame: NSRect? { projectedGap.map { projected[$0.section].frame(at: $0.slot) } }
    func previewSize(section: Int) -> NSSize? {
        guard base.indices.contains(section) else { return nil }
        return NSSize(width: base[section].width, height: base[section].height)
    }

    override func prepare() {
        super.prepare()
        guard let list = collectionView as? SidebarTabCollection, let data = list.sidebar else { return }
        let width = list.enclosingScrollView?.contentView.bounds.width ?? list.bounds.width
        let icons = data.isIconLayout
        let edge = icons ? MacBrowserLayout.railInset : 0
        let rowWidth = data.isRail ? MacBrowserLayout.railItemWidth : max(0, width - 2 * edge)
        let rowHeight = data.rowHeight
        let rowSpacing = icons ? OrivSpacing.small : OrivSpacing.xxs
        let pinGrid = SidebarTabs.PinGrid(availableWidth: rowWidth)
        let rtl = list.userInterfaceLayoutDirection == .rightToLeft
        let sections = data.sections
        hiddenSource = hidesSource ? data.dragPath : nil

        func makeGeometry(_ geometry: inout [SectionGeometry], source: IndexPath?, gap: Gap?) -> CGFloat {
            geometry.removeAll(keepingCapacity: true)
            var y: CGFloat = 0
            for (index, group) in sections.enumerated() {
                let header = NSRect(x: 0, y: y, width: width, height: group.headerHeight)
                y += header.height
                let top = y
                let count = group.tabs.count - (source?.section == index ? 1 : 0) + (gap?.section == index ? 1 : 0)
                let columns = group.grid ? pinGrid.columns : 1
                let height = group.grid ? OrivLayout.sidebarPinHeight : rowHeight
                let spacing = group.grid ? OrivLayout.sidebarPinGap : rowSpacing
                let widthOfItem = group.grid ? pinGrid.tileWidth : rowWidth
                y += CGFloat((count + columns - 1) / columns) * (height + spacing)
                if icons && !group.grid && count > 0 { y -= spacing }
                geometry.append(SectionGeometry(header: header, itemsTop: top, end: y, count: count,
                                                columns: columns, x: group.grid ? (rtl ? width - widthOfItem : 0) : edge,
                                                width: widthOfItem, height: height, spacing: spacing, rtl: group.grid && rtl))
            }
            return y + (icons ? 0 : 9)
        }

        let baseHeight = makeGeometry(&base, source: nil, gap: nil)
        let height: CGFloat
        if let preview, let source = hiddenSource, base.indices.contains(source.section), base.indices.contains(preview.section),
           (0..<base[source.section].count).contains(source.item),
           preview.slot >= 0, preview.slot <= base[preview.section].count - (source.section == preview.section ? 1 : 0) {
            self.source = source
            projectedGap = preview
            height = makeGeometry(&projected, source: source, gap: preview)
        } else {
            source = nil
            projectedGap = nil
            projected.removeAll(keepingCapacity: true)
            height = baseHeight
        }
        // Removing a tile can close a grid row. Keep the scroll extent stable
        // until the drag ends, so the clip view cannot push the pointer to a new slot.
        contentSize = NSSize(width: width, height: max(baseHeight, height))
    }

    override var collectionViewContentSize: NSSize { contentSize }
    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool { newBounds.width != contentSize.width }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        var result: [NSCollectionViewLayoutAttributes] = []
        let geometry = projected.isEmpty ? base : projected
        for (section, group) in geometry.enumerated() {
            if group.header.intersects(rect),
               let header = layoutAttributesForSupplementaryView(ofKind: NSCollectionView.elementKindSectionHeader,
                                                                  at: IndexPath(item: 0, section: section)) {
                result.append(header)
            }
            for slot in group.visibleSlots(in: rect) where group.frame(at: slot).intersects(rect) {
                if projectedGap?.section == section && projectedGap?.slot == slot { continue }
                let peer = slot - (projectedGap?.section == section && slot > (projectedGap?.slot ?? slot) ? 1 : 0)
                let item = peer + (source?.section == section && peer >= (source?.item ?? peer + 1) ? 1 : 0)
                if let attributes = layoutAttributesForItem(at: IndexPath(item: item, section: section)) {
                    result.append(attributes)
                }
            }
        }
        if let source, let hidden = layoutAttributesForItem(at: source), hidden.frame.intersects(rect) {
            result.append(hidden)
        }
        return result
    }

    override func layoutAttributesForItem(at path: IndexPath) -> NSCollectionViewLayoutAttributes? {
        // During a batch move AppKit can query the new geometry against its
        // previous counts. Only emit attributes valid in both snapshots.
        guard path.count == 2, base.indices.contains(path.section), (0..<base[path.section].count).contains(path.item),
              let collectionView, path.section < collectionView.numberOfSections,
              path.item < collectionView.numberOfItems(inSection: path.section) else { return nil }
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: path)
        if path == source || projected.isEmpty {
            attributes.frame = base[path.section].frame(at: path.item)
        } else {
            let peer = path.item - (source?.section == path.section && path.item > (source?.item ?? path.item) ? 1 : 0)
            let slot = peer + (projectedGap?.section == path.section && peer >= (projectedGap?.slot ?? peer + 1) ? 1 : 0)
            attributes.frame = projected[path.section].frame(at: slot)
        }
        if path == hiddenSource || path == landing { attributes.alpha = 0 }
        return attributes
    }

    override func layoutAttributesForSupplementaryView(ofKind kind: String,
                                                        at path: IndexPath) -> NSCollectionViewLayoutAttributes? {
        let geometry = projected.isEmpty ? base : projected
        guard kind == NSCollectionView.elementKindSectionHeader, path.count == 2, path.item == 0,
              geometry.indices.contains(path.section), !geometry[path.section].header.isEmpty,
              let collectionView, path.section < collectionView.numberOfSections else { return nil }
        let attributes = NSCollectionViewLayoutAttributes(forSupplementaryViewOfKind: kind, with: path)
        attributes.frame = geometry[path.section].header
        return attributes
    }

    // Use the stable, unshifted grid and row boundaries. Left and right
    // halves of adjacent cells map to one gap, which avoids redundant reflow.
    func drop(at point: NSPoint, retaining current: Drop? = nil) -> Drop? {
        guard let data = (collectionView as? SidebarTabCollection)?.sidebar,
              point.x >= 0, point.x < contentSize.width, point.y >= 0,
              let index = base.firstIndex(where: { point.y < $0.end }) ??
                base.lastIndex(where: { $0.count > 0 || !$0.header.isEmpty }) else { return nil }
        // Opening a new pinned row can put the visible gap over the old Tabs
        // heading. Keep that gap valid until the pointer actually leaves it.
        if let current, current.gap == projectedGap, current.gap.section != index, gapFrame?.contains(point) == true {
            return current
        }
        guard data.sections.indices.contains(index), data.sections[index].tabs.count == base[index].count else { return nil }
        let geometry = base[index]
        let section = data.sections[index]
        let source = data.dragPath
        let sourceTab = source.flatMap(data.tab(at:))

        func drop(_ target: SidebarDropTarget, boundary: Int) -> Drop {
            let removedBeforeBoundary = source?.section == index && (source?.item ?? boundary) < boundary
            return Drop(target: target, gap: Gap(section: index, slot: boundary - (removedBeforeBoundary ? 1 : 0)))
        }

        if geometry.header.contains(point) {
            guard case let .pinned(pinned, isPrivate)? = section.pinTarget,
                  pinned || sourceTab == nil || isPrivate == sourceTab?.isPrivate else { return nil }
            let privateDrop = sourceTab?.isPrivate ?? isPrivate
            let boundary = pinned && !privateDrop ? section.normalPinCount : geometry.count
            return drop(.pinned(pinned, isPrivate: privateDrop), boundary: boundary)
        }
        guard geometry.count > 0 else { return nil }
        let item = geometry.slot(at: point)
        let tab = section.tabs[item]
        guard sourceTab == nil || sourceTab?.isPrivate == tab.isPrivate else { return nil }
        let frame = geometry.frame(at: item)
        let after = section.grid ? (geometry.rtl ? point.x <= frame.midX : point.x >= frame.midX) : point.y >= frame.midY
        return drop(.between(tab.id, after: after), boundary: item + (after ? 1 : 0))
    }
}

private final class SidebarTabClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var bounds = super.constrainBoundsRect(proposedBounds)
        bounds.origin.x = 0
        return bounds
    }
}

final class SidebarTabScrollView: ProfileSidebarScrollView {
    var usesIconLayout = false
    private var viewportWidth: CGFloat = 0
    // AppKit can request a scroller again after laying out its document view.
    override var hasVerticalScroller: Bool {
        get { super.hasVerticalScroller }
        set { super.hasVerticalScroller = newValue && !usesIconLayout }
    }

    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        profiles?.sidebarSwitch.listViewportChanged(self)
    }

    override func tile() {
        super.tile()
        guard let list = documentView as? SidebarTabCollection else { return }
        let width = contentView.bounds.width
        if width > 0, width != viewportWidth {
            viewportWidth = width
            list.setFrameSize(NSSize(width: width, height: list.frame.height))
            list.collectionViewLayout?.invalidateLayout()
        }
    }
}

private struct SidebarSection {
    enum Kind: Equatable { case pinned, regular, privateTabs, empty }
    let kind: Kind
    let tabs: [BrowserTab]
    var heading: String? = nil
    var count = 0
    var grid = false
    var normalPinCount = 0
    var separator = false
    var pinTarget: SidebarDropTarget? = nil
    var retainedHeaderHeight: CGFloat? = nil

    var headerHeight: CGFloat {
        if let retainedHeaderHeight { return retainedHeaderHeight }
        if separator { return 25 }
        switch heading {
        case "Pinned", "Pin tab": return OrivLayout.sidebarSectionHeight
        case "Private", "Tabs", "Unpin tab": return OrivLayout.sidebarSectionHeight + OrivSpacing.xs
        case .some: return 40
        case nil: return 0
        }
    }
}

@MainActor final class SidebarCollectionData: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
    static let pasteboardType = NSPasteboard.PasteboardType("com.oriv.browser.sidebar-tab")

    weak var list: SidebarTabCollection?
    private var configuration: NativeSidebarTabs?
    fileprivate private(set) var sections: [SidebarSection] = []
    private var environment = EnvironmentValues()
    private var activeID: UUID?
    private(set) var hovered: IndexPath?
    private var hoveredAccessory: SidebarRowAccessory?
    private var drag: SidebarTabTransfer?
    private var dragCommitted = false
    private weak var dragImageSource: SidebarCollectionItem?
    private var validatedPasteboard: (sequence: Int, version: Int, matches: Bool)?
    private var paths: [UUID: IndexPath] = [:]
    private var deferredIconURLs: Set<URL> = []
    fileprivate var dragPath: IndexPath? { drag.flatMap { paths[$0.id] } }
    fileprivate var reduceMotion: Bool { environment.browserReduceMotion }
    var controller: BrowserController? { configuration?.controller }
    var isRail: Bool { configuration?.rail == true }
    var isSearching: Bool { configuration?.searching == true }
    var isIconLayout: Bool { isRail || configuration?.peek == true }
    var rowHeight: CGFloat {
        if isIconLayout { return OrivTarget.macRail.height }
        return environment.dynamicTypeSize.isAccessibilitySize ? OrivLayout.sidebarAccessibilityRowHeight : OrivLayout.tabRowHeight
    }

    private enum DragUpdate {
        case sections
        case move(UUID, hideLanding: Bool)
    }

    private func makeSections(_ configuration: NativeSidebarTabs) -> [SidebarSection] {
        let pinned = configuration.tabs.filter(\.isPinned)
        let regular = configuration.tabs.filter { !$0.isPinned && !$0.isPrivate }
        let privateTabs = configuration.tabs.filter { $0.isPrivate && !$0.isPinned }
        let pinDrag = dragCommitted ? nil : dragPath.flatMap(tab(at:))
        let pinning = pinDrag?.isPinned == false
        let unpinningRegular = pinDrag?.isPinned == true && pinDrag?.isPrivate == false
        let unpinningPrivate = pinDrag?.isPinned == true && pinDrag?.isPrivate == true
        let retainSections = dragCommitted ? sections : []
        let icons = configuration.rail || configuration.peek
        let privateHeading = configuration.controller.profile == nil ? nil : "Private"
        var hasVisibleSection = false
        let groups: [(SidebarSection.Kind, [BrowserTab], String?, String, Bool)] = [
            (.pinned, pinned, "Pinned", "Pin tab", pinning),
            (.regular, regular, "Tabs", "Unpin tab", unpinningRegular),
            (.privateTabs, privateTabs, privateHeading, "Unpin tab", unpinningPrivate)
        ]
        // The native drag session holds the original index path. Empty
        // sections take no space until they become drop targets.
        return groups.map { kind, tabs, title, emptyTitle, wantsEmptyTarget in
            let retained = retainSections.first { $0.kind == kind }
            guard !tabs.isEmpty || wantsEmptyTarget || retained?.pinTarget != nil else {
                if kind == .regular && configuration.tabs.isEmpty {
                    return SidebarSection(kind: .empty, tabs: [], heading: configuration.searching ? "No matching tabs" : "No tabs")
                }
                return SidebarSection(kind: kind, tabs: [])
            }
            let heading: String?
            if tabs.isEmpty {
                heading = retained != nil ? retained?.heading : emptyTitle
            } else {
                heading = icons ? nil : title
            }
            let separator = retained?.separator ?? (icons && (hasVisibleSection || heading != nil))
            hasVisibleSection = true
            return SidebarSection(kind: kind, tabs: tabs, heading: heading,
                                  count: icons ? 0 : tabs.count, grid: kind == .pinned && !icons && !configuration.searching,
                                  normalPinCount: kind == .pinned ? tabs.prefix { !$0.isPrivate }.count : 0,
                                  separator: separator, pinTarget: .pinned(kind == .pinned, isPrivate: kind == .privateTabs),
                                  retainedHeaderHeight: retained?.headerHeight)
        }
    }

    func update(_ value: NativeSidebarTabs, environment: EnvironmentValues) {
        update(value, environment: environment, dragUpdate: nil)
    }

    private func update(_ value: NativeSidebarTabs, environment: EnvironmentValues, dragUpdate: DragUpdate?) {
        guard let list else { return }
        let old = configuration
        if let old, old.controller !== value.controller { detach() }
        let oldSize = self.environment.dynamicTypeSize
        let oldStyle = self.environment.sidebarStyle
        let directionChanged = self.environment.layoutDirection != environment.layoutDirection
        let oldShown = selectedID
        let ownsFocus = list.window?.firstResponder === list
        let oldSections = sections
        let newSections = makeSections(value)
        let oldKinds = oldSections.map(\.kind)
        let newKinds = newSections.map(\.kind)
        let changesLayout = old?.rail != value.rail || old?.peek != value.peek || old?.searching != value.searching ||
            oldSections.map(\.headerHeight) != newSections.map(\.headerHeight)
        let profileChanged = old?.controller !== value.controller
        let changesContent = profileChanged || oldKinds != newKinds ||
            oldSections.map { $0.tabs.map(\.id) } != newSections.map { $0.tabs.map(\.id) }
        let newActive = value.controller.session.selectedTabID
        let changesActive = activeID != newActive
        configuration = value
        self.environment = environment
        activeID = newActive

        let needsLayout = changesLayout || changesContent || old?.expandedWidth != value.expandedWidth ||
            oldSize != environment.dynamicTypeSize || directionChanged
        let layout = list.collectionViewLayout as? SidebarTabLayout
        func applySections() {
            sections = newSections
            if changesContent {
                paths.removeAll(keepingCapacity: true)
                for (section, group) in sections.enumerated() {
                    for (index, tab) in group.tabs.enumerated() { paths[tab.id] = IndexPath(item: index, section: section) }
                }
            }
        }

        switch dragUpdate {
        case .sections where !changesContent:
            if needsLayout {
                list.animateDropSections {
                    applySections()
                    list.clearDragPreviewForContentChange()
                    layout?.invalidateLayout()
                }
            } else {
                applySections()
            }
        case .move(let id, let hideLanding):
            let from = paths[id]
            let to = newSections.enumerated().lazy.compactMap { index, group in
                group.tabs.firstIndex { $0.id == id }.map { IndexPath(item: $0, section: index) }
            }.first
            func applyDrop() {
                applySections()
                list.clearDragPreviewForContentChange()
                layout?.hidesSource = false
                layout?.landing = hideLanding ? to : nil
                layout?.invalidateLayout()
            }

            if let from, let to, from != to {
                // The visible siblings are already in their projected positions.
                // Commit them in place while AppKit moves the drag image to the gap.
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    list.performBatchUpdates {
                        applyDrop()
                        list.moveItem(at: from, to: to)
                    }
                }
            } else {
                applyDrop()
            }
        default:
            if needsLayout { list.clearDragPreviewForContentChange() }
            applySections()
            if changesLayout || changesContent { setHovered(nil) }
            if changesContent { list.reloadData() }
            if needsLayout {
                layout?.invalidateLayout()
                if drag != nil && !dragCommitted { list.refreshDragDestination() }
            }
        }

        if changesActive || profileChanged {
            select(newActive, reveal: drag == nil)
        } else if changesLayout || changesContent {
            // Preserve the keyboard highlight by ID as its index path changes.
            let highlight = ownsFocus || !changesLayout || dragUpdate != nil
                ? oldShown.flatMap { path(for: $0) != nil ? $0 : nil } : nil
            select(highlight ?? newActive, reveal: changesLayout && dragUpdate == nil && drag == nil)
        }
        let keepArtwork = dragUpdate != nil || (drag != nil && !needsLayout && oldStyle == environment.sidebarStyle &&
            old?.searchRequest == value.searchRequest && old?.duplicateTitles == value.duplicateTitles)
        for case let item as SidebarCollectionItem in list.visibleItems() {
            if let path = list.indexPath(for: item) { configure(item, at: path, keepArtwork: keepArtwork) }
        }
        for path in list.indexPathsForVisibleSupplementaryElements(ofKind: NSCollectionView.elementKindSectionHeader) {
            if let header = list.supplementaryView(forElementKind: NSCollectionView.elementKindSectionHeader, at: path) as? SidebarCollectionHeader {
                configure(header, section: path.section, keepArtwork: keepArtwork)
            }
        }
    }

    func detach() {
        list?.finishDragPresentation()
        deferredIconURLs.removeAll()
        if drag != nil {
            drag = nil
            dragCommitted = false
            dragImageSource?.clearDragImage()
            dragImageSource = nil
            configuration?.controller.sidebar.dragging = false
            configuration?.controller.sidebar.pointer(false, drag: false)
        }
    }

    private func applyDragState(_ active: Bool) {
        guard let value = configuration else { return }
        value.controller.sidebar.dragging = active
        setDragPointer(active)
        update(value, environment: environment, dragUpdate: .sections)
    }

    fileprivate var isDragging: Bool { drag != nil }

    fileprivate func setDragPointer(_ inside: Bool) {
        guard let sidebar = controller?.sidebar, sidebar.pointerInside != inside || inside && sidebar.rail else { return }
        sidebar.pointer(inside, drag: inside)
    }

    func path(for id: UUID) -> IndexPath? { paths[id] }

    func tab(at path: IndexPath) -> BrowserTab? {
        guard sections.indices.contains(path.section), sections[path.section].tabs.indices.contains(path.item) else { return nil }
        return sections[path.section].tabs[path.item]
    }

    var selectedID: UUID? { list?.selectionIndexPaths.first.flatMap(tab(at:))?.id }
    private var firstID: UUID? { sections.lazy.compactMap { $0.tabs.first?.id }.first }

    func select(_ id: UUID?, reveal: Bool) {
        guard let list else { return }
        let path = id.flatMap(path(for:))
        if list.selectionIndexPaths.count != (path == nil ? 0 : 1) || list.selectionIndexPaths.first != path {
            list.selectionIndexPaths = path.map { [$0] } ?? []
        }
        if let path, reveal { revealItem(at: path) }
    }

    func revealItem(at path: IndexPath) {
        guard let list, sections.indices.contains(path.section) else { return }
        list.layoutSubtreeIfNeeded()
        guard let frame = list.layoutAttributesForItem(at: path)?.frame else { return }
        let section = sections[path.section]
        if section.heading != nil,
           let first = list.layoutAttributesForItem(at: IndexPath(item: 0, section: path.section)),
           first.frame.minY == frame.minY,
           let header = list.layoutAttributesForSupplementaryElement(ofKind: NSCollectionView.elementKindSectionHeader,
                                                                    at: IndexPath(item: 0, section: path.section)) {
            list.scrollToVisible(frame.union(header.frame))
        } else {
            list.scrollToVisible(frame)
        }
    }

    func focus(_ id: UUID?) {
        select(id ?? selectedID ?? activeID ?? firstID, reveal: true)
        if selectedID == nil { select(firstID, reveal: true) }
    }

    func activateSelection() {
        guard let id = selectedID, let configuration else { return }
        if !activate(id, using: configuration) { select(activeID, reveal: false) }
    }

    private func activate(_ id: UUID, using configuration: NativeSidebarTabs) -> Bool {
        guard configuration.controller.activateSidebarTab(id, request: configuration.searchRequest) else { return false }
        // Record explicit commits before the next key event. The SwiftUI
        // update must preserve a highlight moved after this activation.
        activeID = id
        return true
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        if !((collectionView as? SidebarTabCollection)?.navigatingWithKeys ?? false) {
            activateSelection()
        }
    }

    func moveHighlight(toBoundary forward: Bool, byPage: Bool) {
        guard let list else { return }
        let paths = sections.enumerated().flatMap { section, group in
            group.tabs.indices.map { IndexPath(item: $0, section: section) }
        }
        guard let boundary = forward ? paths.last : paths.first else { return }
        if !byPage {
            select(tab(at: boundary)?.id, reveal: true)
            return
        }
        guard let current = list.selectionIndexPaths.first,
              let frame = list.layoutAttributesForItem(at: current)?.frame else {
            select(firstID, reveal: true)
            return
        }
        let targetY = frame.midY + (forward ? 1 : -1) * list.visibleRect.height
        let next = paths.min {
            let a = list.layoutAttributesForItem(at: $0)?.frame.midY ?? 0
            let b = list.layoutAttributesForItem(at: $1)?.frame.midY ?? 0
            return abs(a - targetY) < abs(b - targetY)
        } ?? boundary
        select(tab(at: next)?.id, reveal: true)
    }

    func resign() {
        select(activeID, reveal: false)
    }

    func setHovered(_ path: IndexPath?, accessory: SidebarRowAccessory? = nil) {
        guard hovered != path || hoveredAccessory != accessory else { return }
        let movedRows = hovered != path
        hoveredAccessory = accessory
        let previous = hovered
        hovered = path
        for index in Set([previous, path].compactMap({ $0 })) {
            if let item = list?.item(at: index) as? SidebarCollectionItem { configure(item, at: index) }
        }
        guard movedRows else { return }
        if let path, let tab = tab(at: path), !sections[path.section].grid, drag == nil {
            controller?.sidebarTooltip.hover(id: tab.id, text: SidebarTabs.label(tab, selected: tab.id == activeID))
        } else { controller?.sidebarTooltip.exit() }
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int { sections.count }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        sections.indices.contains(section) ? sections[section].tabs.count : 0
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: SidebarCollectionItem.identifier, for: indexPath) as! SidebarCollectionItem
        configure(item, at: indexPath)
        return item
    }

    private func configure(_ item: SidebarCollectionItem, at path: IndexPath, keepArtwork: Bool = false) {
        guard let configuration, let tab = tab(at: path) else { return }
        let grid = sections[path.section].grid
        let active = activeID == tab.id
        let icons = configuration.rail || configuration.peek
        let pinPosition = tab.isPinned ? "Pinned, \(path.item + 1) of \(sections[path.section].tabs.count)" : nil
        if item.pinPosition != pinPosition { item.pinPosition = pinPosition }
        let tooltip = grid ? tab.displayTitle : nil
        if item.view.toolTip != tooltip { item.view.toolTip = tooltip }
        if keepArtwork, item.tab === tab, item.active == active, item.isPinTile == grid, item.iconOnly == icons { return }
        item.tab = tab
        item.active = active
        item.isPinTile = grid
        item.iconOnly = icons
        item.command = { [weak controller = configuration.controller, weak tab] command in
            if let controller, let tab { SidebarTabs.perform(command, tab: tab, controller: controller) }
        }
        item.open = { [weak self, weak tab] in
            guard let self, let tab, let configuration = self.configuration else { return }
            if self.activate(tab.id, using: configuration) { self.select(tab.id, reveal: false) }
        }
        var hovered = hovered == path
        #if DEBUG
        hovered = hovered || environment.sidebarCaptureState.hover == tab.id
        #endif
        item.hovered = hovered
        let accessory = self.hovered == path ? hoveredAccessory : nil
        let artwork = artwork(for: tab, in: configuration, grid: grid, hovered: hovered, accessory: accessory)
        item.artwork = { artwork($0, false) }
        let style = environment.sidebarStyle
        let radius = grid || icons ? OrivLayout.sidebarPinRadius : OrivLayout.sidebarSelectionRadius
        (item.view as? SidebarAccessibleRow)?.setSelectionShadow(active && !style.opaque ? NSColor(style.glow) : nil,
                                                                radius: radius)
        item.refresh()
    }

    private func artwork(for tab: BrowserTab, in configuration: NativeSidebarTabs, grid: Bool,
                         hovered: Bool, accessory: SidebarRowAccessory?) -> (Bool, Bool) -> AnyView {
        // A host subtitle only helps when it says something the title doesn't.
        let subtitle = configuration.duplicateTitles.contains(tab.displayTitle)
            ? tab.url?.host.flatMap { $0.caseInsensitiveCompare(tab.displayTitle) == .orderedSame ? nil : $0 } : nil
        var environment = self.environment
        environment.sidebarDefersIconHydration = { [weak self] url in self?.deferIconHydration(url) == true }
        let active = activeID == tab.id
        let icons = configuration.rail || configuration.peek
        let peek = configuration.peek
        return { selected, preview in
            var content = SidebarTabArtwork(tab: tab, selected: selected, active: active, tile: grid,
                                            rail: icons, peek: peek, hovered: hovered,
                                            hoveredAccessory: accessory, subtitle: subtitle)
            content.drawsSelectionGlow = preview
            if preview {
                // ImageRenderer only needs the current profile's in-memory favicon.
                content.previewIcons = [:]
                if let url = tab.url, let key = SiteIconStore.key(url, isPrivate: tab.isPrivate),
                   let icon = environment.siteIcons?.icon(for: url, isPrivate: tab.isPrivate) {
                    content.previewIcons?[key] = icon
                }
            }
            if grid && !preview { return AnyView(content.help(tab.displayTitle).environment(\.self, environment)) }
            return AnyView(content.environment(\.self, environment))
        }
    }

    fileprivate func preview(for section: Int, size: NSSize, scale: CGFloat) -> NSDraggingImageComponent? {
        guard sections.indices.contains(section), let configuration, let source = dragPath, let tab = tab(at: source) else { return nil }
        let artwork = artwork(for: tab, in: configuration, grid: sections[section].grid, hovered: false, accessory: nil)
        let renderer = ImageRenderer(content: artwork(selectedID == tab.id, true).frame(width: size.width, height: size.height))
        renderer.scale = scale
        guard let image = renderer.cgImage else { return nil }
        let component = NSDraggingImageComponent(key: .icon)
        component.contents = image
        component.frame = NSRect(origin: .zero, size: size)
        return component
    }

    private func deferIconHydration(_ url: URL) -> Bool {
        guard isDragging else { return false }
        deferredIconURLs.insert(url)
        return true
    }

    func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> NSView {
        let header = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: SidebarCollectionHeader.identifier,
                                                          for: indexPath) as! SidebarCollectionHeader
        configure(header, section: indexPath.section)
        return header
    }

    private func configure(_ header: SidebarCollectionHeader, section index: Int, keepArtwork: Bool = false) {
        guard sections.indices.contains(index) else { return }
        let section = sections[index]
        let content = SidebarCollectionHeader.Content(heading: section.heading, count: section.count, separator: section.separator)
        if keepArtwork, header.content == content { return }
        header.content = content
        header.setAccessibilityElement(section.heading != nil)
        header.setAccessibilityRole(section.kind == .empty ? .staticText : NSAccessibility.Role(rawValue: "AXHeading"))
        if let heading = section.heading {
            header.setAccessibilityLabel(section.count > 0 ? "\(heading), \(SidebarTabs.countLabel(section.count))" : heading)
        }
        if case let .pinned(pinned, _)? = section.pinTarget, section.heading != nil {
            header.toolTip = pinned ? "Drop a tab here to pin it" : "Drop a pinned tab here to unpin it"
        } else {
            header.toolTip = nil
        }
        header.host.rootView = AnyView(headerArtwork(section).environment(\.self, environment))
    }

    @ViewBuilder private func headerArtwork(_ section: SidebarSection) -> some View {
        if section.separator {
            Rectangle().fill(environment.browserTheme.separator.opacity(0.7)).frame(width: 24, height: 1)
        } else if let heading = section.heading {
            if heading == "Pin tab" || heading == "Unpin tab" {
                SidebarSectionHeading(title: heading, count: 0)
                    .modifier(SidebarToneSurface(tone: .selection))
            } else if section.count > 0 { SidebarSectionHeading(title: heading, count: section.count) }
            else { Text(heading).font(OrivType.detail).foregroundStyle(environment.browserTheme.sidebarSecondaryText(environment.sidebarContrast)) }
        }
    }

    func menu(for tab: BrowserTab) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ command: SidebarTabCommand) {
            menu.addItem(SidebarMenuItem(title) { [weak self, weak tab] in
                if let controller = self?.controller, let tab { SidebarTabs.perform(command, tab: tab, controller: controller) }
            })
        }
        add(tab.isPinned ? "Unpin Tab" : "Pin Tab", .pin)
        add("Duplicate Tab", .duplicate)
        add("Move Up", .moveUp)
        add("Move Down", .moveDown)
        if tab.url != nil {
            menu.addItem(.separator())
            add("Reload", .reload)
            add("Copy Link", .copyLink)
            add(SidebarTabs.muteLabel(tab), .mute)
            add(tab.mediaSuspended ? "Resume Media Playback" : "Pause and Block Media Playback", .media)
        }
        menu.addItem(.separator())
        add("Close Tab", .close)
        for (label, right) in [("Close Other Tabs", false), ("Close Tabs to the Right", true)] {
            menu.addItem(SidebarMenuItem(label) { [weak self] in self?.configuration?.confirmClose(tab.id, right) })
        }
        menu.addItem(.separator())
        add("New Private Tab", .newPrivate)
        return menu
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt path: IndexPath) -> (any NSPasteboardWriting)? {
        guard let tab = tab(at: path), let controller,
              let data = try? JSONEncoder().encode(SidebarTabTransfer(id: tab.id, owner: controller.sidebarDragID)) else { return nil }
        let item = NSPasteboardItem()
        item.setData(data, forType: Self.pasteboardType)
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession,
                        willBeginAt screenPoint: NSPoint, forItemsAt paths: Set<IndexPath>) {
        session.animatesToStartingPositionsOnCancelOrFail = !reduceMotion
        if let path = paths.first { beginDrag(at: path) }
    }

    func beginDrag(at path: IndexPath) {
        os_signpost(.begin, log: sidebarDragLog, name: "DragStart")
        defer { os_signpost(.end, log: sidebarDragLog, name: "DragStart") }
        guard let tab = tab(at: path), let controller else { return }
        validatedPasteboard = nil
        drag = SidebarTabTransfer(id: tab.id, owner: controller.sidebarDragID)
        dragImageSource = list?.item(at: path) as? SidebarCollectionItem
        list?.beginDragPresentation()
        // Leave AppKit's source index path untouched while it takes the image.
        Task { [weak self] in self?.activateDrag() }
    }

    fileprivate func activateDrag() {
        guard drag != nil, let controller, !controller.sidebar.dragging else { return }
        os_signpost(.begin, log: sidebarDragLog, name: "DragSetup")
        defer { os_signpost(.end, log: sidebarDragLog, name: "DragSetup") }
        controller.sidebarTooltip.dismiss()
        setHovered(nil)
        list?.hideDragSource(at: dragPath)
        applyDragState(true)
        list?.layoutSubtreeIfNeeded()
        list?.warmDragPreview()
    }

    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession,
                        endedAt screenPoint: NSPoint, dragOperation operation: NSDragOperation) {
        // A successful destination concludes after AppKit's image lands.
        if operation != .move || !dragCommitted { endDrag() }
    }

    func endDrag() {
        guard drag != nil else { return }
        list?.finishDragPresentation()
        drag = nil
        dragCommitted = false
        dragImageSource?.clearDragImage()
        dragImageSource = nil
        applyDragState(false)
        list?.layoutSubtreeIfNeeded()
        (list?.enclosingScrollView as? SidebarTabScrollView)?.profiles?.sidebarSwitch.sidebarDragFinished()
        let urls = deferredIconURLs
        deferredIconURLs.removeAll()
        if !urls.isEmpty, let icons = environment.siteIcons {
            Task { [weak self] in
                for url in urls {
                    guard let self, self.environment.siteIcons === icons else { return }
                    if !self.deferIconHydration(url) { await icons.loadCached(url) }
                }
            }
        }
    }

    func dropTarget(at point: NSPoint) -> SidebarDropTarget? {
        (list?.collectionViewLayout as? SidebarTabLayout)?.drop(at: point)?.target
    }

    fileprivate func acceptsDrag(_ info: NSDraggingInfo, readPasteboard: Bool = false) -> Bool {
        guard let list, let controller, let drag, !dragCommitted, controller.session.isProfileActive,
              info.draggingSource as? NSCollectionView === list,
              info.draggingSourceOperationMask.contains(.move), drag.owner == controller.sidebarDragID else { return false }
        let pasteboard = info.draggingPasteboard
        let sequence = info.draggingSequenceNumber
        let version = pasteboard.changeCount
        if let cached = validatedPasteboard, cached.sequence == sequence, cached.version == version { return cached.matches }
        guard readPasteboard else { return false }
        let item = pasteboard.data(forType: Self.pasteboardType).flatMap { try? JSONDecoder().decode(SidebarTabTransfer.self, from: $0) }
        let matches = item?.id == drag.id && item?.owner == drag.owner
        validatedPasteboard = (sequence, version, matches)
        return matches
    }

    fileprivate func commit(_ drop: SidebarTabLayout.Drop, animated: Bool) -> IndexPath? {
        guard let drag, let source = dragPath, var value = configuration else { return nil }
        let controller = value.controller
        let staysInPlace = source.section == drop.gap.section && source.item == drop.gap.slot
        guard staysInPlace || SidebarTabs.drop([drag], on: drop.target, controller: controller) else { return nil }

        dragCommitted = true
        value.tabs = value.searchRequest.map(controller.tabSearchResults) ?? controller.session.orderedTabs
        value.duplicateTitles = SidebarTabs.duplicateTitles(in: value.tabs)
        update(value, environment: environment, dragUpdate: .move(drag.id, hideLanding: animated))
        list?.layoutSubtreeIfNeeded()
        return path(for: drag.id)
    }

}

final class SidebarTabCollection: NSCollectionView {
    weak var sidebar: SidebarCollectionData?
    private(set) var navigatingWithKeys = false
    private var keyboardNavigation = false
    private var ownsFocus = false
    var showsKeyboardFocus: Bool { ownsFocus && keyboardNavigation }
    private var pointerTracking: NSTrackingArea?
    private let insertionMarker = {
        let marker = SidebarInsertionMarker()
        marker.wantsLayer = true
        marker.layerContentsRedrawPolicy = .onSetNeedsDisplay
        return marker
    }()
    private var edgeScroll: Timer?
    private var dragLocation: NSPoint?
    private var lastScrollTick: TimeInterval?
    private var requestedDrop: SidebarTabLayout.Drop?
    private var sourcePreview: NSDraggingImageComponent?
    private var alternatePreview: NSDraggingImageComponent?
    private var showingAlternatePreview = false
    private var dragLayout: SidebarTabLayout? { collectionViewLayout as? SidebarTabLayout }
    var insertionMarkerFrame: NSRect? { insertionMarker.superview == nil ? nil : insertionMarker.frame }
    #if DEBUG
    private(set) var dragRelayoutCount = 0
    private(set) var dragArtworkRefreshCount = 0
    private(set) var dragImageRenderCount = 0
    private var framePacing: SidebarDragFramePacing?
    var dragFramePacingTestOutput: URL?

    fileprivate func didRefreshDragArtwork() {
        if sidebar?.isDragging == true { dragArtworkRefreshCount += 1 }
    }
    #endif

    private func showInsertionMarker(_ frame: NSRect?) {
        guard let frame else { insertionMarker.removeFromSuperview(); return }
        if insertionMarker.frame.size != frame.size { insertionMarker.needsDisplay = true }
        if insertionMarker.frame != frame { insertionMarker.frame = frame }
        if insertionMarker.superview == nil { addSubview(insertionMarker, positioned: .above, relativeTo: nil) }
    }

    fileprivate func clearDragPreviewForContentChange() {
        requestedDrop = nil
        dragLayout?.preview = nil
        showInsertionMarker(nil)
    }

    fileprivate func beginDragPresentation() {
        #if DEBUG
        if sidebar?.controller?.testing == false || dragFramePacingTestOutput != nil {
            framePacing = SidebarDragFramePacing.start(in: self, output: dragFramePacingTestOutput)
        }
        #endif
        if let path = sidebar?.dragPath { sourcePreview = item(at: path)?.draggingImageComponents.first }
    }

    fileprivate func hideDragSource(at path: IndexPath?) {
        guard let layout = dragLayout else { return }
        layout.hidesSource = true
        if let path {
            let context = NSCollectionViewLayoutInvalidationContext()
            context.invalidateItems(at: [path])
            layout.invalidateLayout(with: context)
        }
    }

    fileprivate func warmDragPreview() {
        guard let sidebar, let path = sidebar.dragPath, sidebar.sections.indices.contains(path.section),
              let section = sidebar.sections.firstIndex(where: {
                  $0.pinTarget != nil && $0.grid != sidebar.sections[path.section].grid
              }) else { return }
        _ = alternateImage(for: section)
    }

    private func alternateImage(for section: Int) -> NSDraggingImageComponent? {
        guard let size = dragLayout?.previewSize(section: section), size.width > 0, size.height > 0 else { return nil }
        if let alternatePreview, alternatePreview.frame.size == size { return alternatePreview }
        os_signpost(.begin, log: sidebarDragLog, name: "DragImage")
        defer { os_signpost(.end, log: sidebarDragLog, name: "DragImage") }
        #if DEBUG
        dragImageRenderCount += 1
        #endif
        alternatePreview = sidebar?.preview(for: section, size: size, scale: window?.backingScaleFactor ?? 2)
        return alternatePreview
    }

    private func updateDragImage(_ sender: NSDraggingInfo, for drop: SidebarTabLayout.Drop?) {
        guard let sidebar, let source = sidebar.dragPath else { return }
        let section = drop?.gap.section ?? source.section
        guard sidebar.sections.indices.contains(section), sidebar.sections.indices.contains(source.section) else { return }
        let alternate = sidebar.sections[section].grid != sidebar.sections[source.section].grid
        let size = dragLayout?.previewSize(section: section)
        guard alternate != showingAlternatePreview || (alternate && alternatePreview?.frame.size != size),
              let component = alternate ? alternateImage(for: section) : sourcePreview else { return }
        sender.enumerateDraggingItems(options: [], for: self, classes: [NSPasteboardItem.self], searchOptions: [:]) { item, _, _ in
            let frame = item.draggingFrame
            let size = component.frame.size
            // Preserve the center of the native image through a format change.
            item.setDraggingFrame(NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2,
                                         width: size.width, height: size.height), contents: component.contents)
            self.showingAlternatePreview = alternate
        }
    }

    fileprivate func finishDragPresentation() {
        stopEdgeScrolling()
        dragLocation = nil
        if let layout = dragLayout {
            let concealed = layout.landing ?? (layout.hidesSource ? sidebar?.dragPath : nil)
            layout.landing = nil
            layout.hidesSource = false
            if let concealed {
                let context = NSCollectionViewLayoutInvalidationContext()
                context.invalidateItems(at: [concealed])
                layout.invalidateLayout(with: context)
            }
        }
        requestDrop(nil)
        sourcePreview = nil
        alternatePreview = nil
        showingAlternatePreview = false
        #if DEBUG
        framePacing?.finish()
        framePacing = nil
        #endif
    }

    private func requestDrop(_ drop: SidebarTabLayout.Drop?) {
        let previousGap = requestedDrop?.gap
        requestedDrop = drop
        if previousGap != drop?.gap { needsLayout = true }
    }

    fileprivate func refreshDragDestination() {
        guard let dragLocation else { return }
        layoutSubtreeIfNeeded()
        requestDrop(drop(at: dragLocation))
    }

    private func drop(at windowPoint: NSPoint) -> SidebarTabLayout.Drop? {
        guard sidebar?.dragPath != nil else { return nil }
        return dragLayout?.drop(at: convert(windowPoint, from: nil), retaining: requestedDrop)
    }

    override func layout() {
        guard let layout = dragLayout, layout.preview != requestedDrop?.gap else { super.layout(); return }
        os_signpost(.begin, log: sidebarDragLog, name: "DragRelayout")
        defer { os_signpost(.end, log: sidebarDragLog, name: "DragRelayout") }
        #if DEBUG
        dragRelayoutCount += 1
        #endif
        let animate = sidebar?.reduceMotion == false
        let positions = animate ? visiblePositions() : []
        withoutImplicitDragAnimation {
            layout.preview = requestedDrop?.gap
            layout.invalidateLayout()
            super.layout()
            showInsertionMarker(layout.gapFrame)
            animatePositions(from: positions)
        }
    }

    fileprivate func animateDropSections(changes: @MainActor () -> Void) {
        os_signpost(.begin, log: sidebarDragLog, name: "DragRelayout")
        defer { os_signpost(.end, log: sidebarDragLog, name: "DragRelayout") }
        let before = sidebar?.reduceMotion == false ? visiblePositions() : []
        withoutImplicitDragAnimation {
            changes()
            layoutSubtreeIfNeeded()
            animatePositions(from: before)
        }
    }

    private func withoutImplicitDragAnimation(_ changes: () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            changes()
            CATransaction.commit()
        }
    }

    private struct Position {
        let view: SidebarReflowView
        let tab: UUID?
        let frame: NSRect
        let position: CGPoint
        let velocity: CGPoint
    }

    private func visiblePositions() -> [Position] {
        var positions: [Position] = []
        let time = CACurrentMediaTime()
        func capture(_ view: NSView, tab: UUID? = nil) {
            guard let view = view as? SidebarReflowView, let layer = view.layer, !view.isHidden, view.alphaValue > 0 else { return }
            let current = view.reflow?.sample(at: layer.convertTime(time, from: nil))
            positions.append(Position(view: view, tab: tab, frame: view.frame,
                                      position: current?.position ?? layer.position,
                                      velocity: current?.velocity ?? .zero))
        }
        for case let item as SidebarCollectionItem in visibleItems() {
            capture(item.view, tab: item.tab?.id)
        }
        let kind = NSCollectionView.elementKindSectionHeader
        for path in indexPathsForVisibleSupplementaryElements(ofKind: kind) {
            if let header = supplementaryView(forElementKind: kind, at: path) { capture(header) }
        }
        return positions
    }

    private func animatePositions(from positions: [Position]) {
        let time = CACurrentMediaTime()
        for previous in positions {
            guard previous.view.superview != nil, let layer = previous.view.layer,
                  (previous.view as? SidebarAccessibleRow)?.item?.tab?.id == previous.tab,
                  previous.frame.origin != previous.view.frame.origin else { continue }
            let motion = SidebarReflowMotion(start: previous.position, end: layer.position,
                                            velocity: previous.velocity, begin: layer.convertTime(time, from: nil))
            previous.view.reflow = motion
            layer.add(motion.animation(), forKey: "sidebarReflow")
        }
    }

    private func updateEdgeScrolling(at point: NSPoint) {
        let viewport = visibleRect
        let velocity = edgeVelocity(at: convert(point, from: nil), viewport: viewport)
        guard (velocity < 0 && viewport.minY > bounds.minY) ||
              (velocity > 0 && viewport.maxY < bounds.maxY) else {
            stopEdgeScrolling()
            return
        }
        guard edgeScroll == nil else { return }
        // Keep scrolling while AppKit tracks a stationary pointer at an edge.
        let rate = max(60, window?.screen?.maximumFramesPerSecond ?? 60)
        let timer = Timer(timeInterval: 1.0 / Double(rate), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scrollDuringDrag() }
        }
        lastScrollTick = ProcessInfo.processInfo.systemUptime
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
        edgeScroll = timer
    }

    private func stopEdgeScrolling() {
        edgeScroll?.invalidate()
        edgeScroll = nil
        lastScrollTick = nil
    }

    private func edgeVelocity(at point: NSPoint, viewport: NSRect) -> CGFloat {
        let band = min(OrivTarget.macRail.height, viewport.height / 3)
        guard band > 0, viewport.contains(point) else { return 0 }
        let top = max(0, 1 - (point.y - viewport.minY) / band)
        let bottom = max(0, 1 - (viewport.maxY - point.y) / band)
        return 580 * (bottom * bottom - top * top)
    }

    private func scrollDuringDrag() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = min(1.0 / 30, now - (lastScrollTick ?? now))
        lastScrollTick = now
        guard let dragLocation, sidebar?.dragPath != nil, let scroll = enclosingScrollView else { return }
        let local = convert(dragLocation, from: nil)
        let velocity = edgeVelocity(at: local, viewport: visibleRect)
        guard velocity != 0 else { stopEdgeScrolling(); return }
        let clip = scroll.contentView
        let origin = clip.constrainBoundsRect(clip.bounds.offsetBy(dx: 0, dy: velocity * elapsed)).origin
        guard origin != clip.bounds.origin else { stopEdgeScrolling(); return }
        withoutImplicitDragAnimation {
            clip.scroll(to: origin)
            scroll.reflectScrolledClipView(clip)
        }
        let drop = drop(at: dragLocation)
        requestDrop(drop)
        #if DEBUG
        updateFramePhase(for: drop, scrolling: true)
        #endif
    }

    override func wantsPeriodicDraggingUpdates() -> Bool { false }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard sidebar?.acceptsDrag(sender, readPasteboard: true) == true else { return [] }
        sidebar?.activateDrag()
        sidebar?.setDragPointer(true)
        return draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        os_signpost(.begin, log: sidebarDragLog, name: "DraggingUpdated")
        defer { os_signpost(.end, log: sidebarDragLog, name: "DraggingUpdated") }
        guard sidebar?.acceptsDrag(sender) == true else {
            dragLocation = nil
            stopEdgeScrolling()
            requestDrop(nil)
            #if DEBUG
            framePacing?.phase = "outside"
            #endif
            return []
        }
        let point = sender.draggingLocation
        dragLocation = point
        updateEdgeScrolling(at: point)
        let drop = drop(at: point)
        requestDrop(drop)
        #if DEBUG
        updateFramePhase(for: drop)
        #endif
        updateDragImage(sender, for: drop)
        return drop == nil ? [] : .move
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        if let sender, sidebar?.acceptsDrag(sender) == true { updateDragImage(sender, for: nil) }
        sidebar?.setDragPointer(false)
        dragLocation = nil
        stopEdgeScrolling()
        requestDrop(nil)
        #if DEBUG
        framePacing?.phase = "outside"
        #endif
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard sidebar?.acceptsDrag(sender, readPasteboard: true) == true,
              let drop = drop(at: sender.draggingLocation) else { return false }
        requestDrop(drop)
        layoutSubtreeIfNeeded()
        updateDragImage(sender, for: drop)
        sender.animatesToDestination = sidebar?.reduceMotion == false && dragLayout?.gapFrame?.intersects(visibleRect) == true
        return true
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        os_signpost(.begin, log: sidebarDragLog, name: "DropCommit")
        defer { os_signpost(.end, log: sidebarDragLog, name: "DropCommit") }
        guard sidebar?.acceptsDrag(sender, readPasteboard: true) == true, let layout = dragLayout,
              let drop = drop(at: sender.draggingLocation) else { return false }
        let animated = sender.animatesToDestination
        let positions = animated ? visiblePositions() : []
        #if DEBUG
        framePacing?.phase = "commit"
        #endif
        var committedPath: IndexPath?
        withoutImplicitDragAnimation {
            committedPath = sidebar?.commit(drop, animated: animated)
            if committedPath != nil { animatePositions(from: positions) }
        }
        guard let path = committedPath else { return false }
        stopEdgeScrolling()
        if animated, let destination = layout.layoutAttributesForItem(at: path)?.frame {
            sender.draggingFormation = .none
            sender.enumerateDraggingItems(options: [], for: self, classes: [NSPasteboardItem.self], searchOptions: [:]) { item, _, _ in
                let size = item.draggingFrame.size
                item.draggingFrame.origin = NSPoint(x: destination.midX - size.width / 2, y: destination.midY - size.height / 2)
            }
        }
        dragLocation = nil
        #if DEBUG
        framePacing?.phase = "settling"
        #endif
        return true
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        sidebar?.endDrag()
    }

    #if DEBUG
    private func updateFramePhase(for drop: SidebarTabLayout.Drop?, scrolling: Bool = false) {
        guard let framePacing, let sidebar, let source = sidebar.dragPath else { return }
        guard let drop, sidebar.sections.indices.contains(source.section),
              sidebar.sections.indices.contains(drop.gap.section) else { framePacing.phase = "outside"; return }
        let startsPinned = sidebar.sections[source.section].kind == .pinned
        let endsPinned = sidebar.sections[drop.gap.section].kind == .pinned
        let phase = startsPinned ? (endsPinned ? "reorder-pins" : "unpin") : (endsPinned ? "pin" : "reorder-tabs")
        framePacing.phase = scrolling ? "edge-scroll/\(phase)" : phase
    }
    #endif

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        if selectionIndexPaths.isEmpty { sidebar?.focus(nil) }
        sidebar?.controller?.sidebarTooltip.dismiss()
        publishFocus(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        sidebar?.resign()
        publishFocus(false)
        return true
    }

    private func publishFocus(_ focused: Bool) {
        ownsFocus = focused
        updateFocusRing()
        sidebar?.setFocus(focused)
    }

    private func updateFocusRing() {
        guard let path = selectionIndexPaths.first, let item = item(at: path) as? SidebarCollectionItem else { return }
        item.updateFocusRing()
    }

    func resetKeyboardNavigation() {
        keyboardNavigation = false
        updateFocusRing()
    }

    func updateFocusInput(for event: NSEvent) {
        let wasKeyboard = keyboardNavigation
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            keyboardNavigation = false
        case .keyDown:
            if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                keyboardNavigation = false
            } else if [48, 115, 116, 119, 121, 123, 124, 125, 126].contains(event.keyCode) {
                keyboardNavigation = true
            }
        default: break
        }
        if keyboardNavigation != wasKeyboard { updateFocusRing() }
    }

    func focusTab(_ id: UUID?) {
        guard let window, window.makeFirstResponder(self) else { return }
        sidebar?.focus(id)
    }

    override func keyDown(with event: NSEvent) {
        updateFocusInput(for: event)
        let modified = !event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        if !modified {
            switch event.keyCode {
            case 36, 49, 76: sidebar?.activateSelection(); return
            case 53:
                if let controller = sidebar?.controller, controller.tabSearchIsFiltering {
                    controller.dismissTabSearch()
                    sidebar?.resign()
                    return
                }
            case 115, 116, 119, 121:
                sidebar?.moveHighlight(toBoundary: event.keyCode == 119 || event.keyCode == 121,
                                       byPage: event.keyCode == 116 || event.keyCode == 121)
                return
            case 123...126:
                let previous = selectionIndexPaths
                navigatingWithKeys = true
                defer { navigatingWithKeys = false }
                super.keyDown(with: event)
                if previous != selectionIndexPaths, let path = selectionIndexPaths.first { sidebar?.revealItem(at: path) }
                return
            default: break
            }
        }
        super.keyDown(with: event)
    }

    func interact(at windowPoint: NSPoint) -> Bool {
        let point = convert(windowPoint, from: nil)
        guard visibleRect.contains(point), let path = indexPathForItem(at: point) else { return false }
        if let item = item(at: path) as? SidebarCollectionItem,
           item.performClick(at: item.view.convert(point, from: self)) { return true }
        if selectionIndexPaths.contains(path) { sidebar?.activateSelection() }
        return false
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2, closeTab(at: event.locationInWindow) { return }
        super.otherMouseUp(with: event)
    }

    @discardableResult func closeTab(at windowPoint: NSPoint) -> Bool {
        guard visibleRect.contains(convert(windowPoint, from: nil)),
              let path = indexPathForItem(at: convert(windowPoint, from: nil)),
              let tab = sidebar?.tab(at: path), !tab.isPinned, let controller = sidebar?.controller else { return false }
        controller.requestCloseTab(tab.id)
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let path = indexPathForItem(at: convert(event.locationInWindow, from: nil)),
              let tab = sidebar?.tab(at: path) else { return nil }
        return sidebar?.menu(for: tab)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard pointerTracking == nil else { return }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        pointerTracking = area
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseMoved(with event: NSEvent) {
        guard sidebar?.isDragging != true else { return }
        if let presentation = sidebar?.controller?.sidebar, !presentation.pointerInside { presentation.pointer(true, moved: true) }
        let point = convert(event.locationInWindow, from: nil)
        let path = indexPathForItem(at: point)
        let item = path.flatMap { self.item(at: $0) as? SidebarCollectionItem }
        sidebar?.setHovered(path, accessory: item.flatMap { $0.accessory(at: $0.view.convert(point, from: self), includesClose: true) })

    }

    override func mouseExited(with event: NSEvent) {
        guard sidebar?.isDragging != true else { return }
        sidebar?.controller?.sidebar.pointer(false)
        sidebar?.setHovered(nil)
    }
}

extension SidebarCollectionData {
    func setFocus(_ focused: Bool) {
        let handle = configuration?.handle
        Task { handle?.hasFocus = focused }
    }
}

private final class SidebarMenuItem: NSMenuItem {
    private let invoke: () -> Void
    init(_ title: String, invoke: @escaping () -> Void) {
        self.invoke = invoke
        super.init(title: title, action: #selector(performItem), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("Sidebar menus are created in code") }
    @objc private func performItem() { invoke() }
}

private final class SidebarInsertionMarker: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func accessibilityIsIgnored() -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(Theme.sidebarKeyboardFocus).setStroke()
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2),
                                   xRadius: OrivRadius.control, yRadius: OrivRadius.control)
        outline.lineWidth = OrivOutline.focus
        outline.setLineDash([4, 4], count: 2, phase: 0)
        outline.stroke()
    }
}

private final class SidebarArtworkHost: NSHostingView<AnyView> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func accessibilityIsIgnored() -> Bool { true }
}

/// A short cubic trajectory ends at rest and carries its instantaneous
/// velocity into a new target, including reversals in the tile grid.
struct SidebarReflowMotion {
    let start: CGPoint
    let end: CGPoint
    let velocity: CGPoint
    let begin: CFTimeInterval
    static let duration = 0.15

    func sample(at time: CFTimeInterval) -> (position: CGPoint, velocity: CGPoint) {
        let t = min(1, max(0, (time - begin) / Self.duration))
        let remaining = 1 - t
        func axis(_ start: CGFloat, _ end: CGFloat, _ velocity: CGFloat) -> (CGFloat, CGFloat) {
            let distance = end - start
            let position = start + distance * (t * t * (3 - 2 * t)) +
                velocity * (Self.duration * t * remaining * remaining)
            let speed = distance * (6 * t * remaining / Self.duration) +
                velocity * (remaining * (1 - 3 * t))
            return (position, speed)
        }
        let (x, vx) = axis(start.x, end.x, velocity.x)
        let (y, vy) = axis(start.y, end.y, velocity.y)
        return (CGPoint(x: x, y: y), CGPoint(x: vx, y: vy))
    }

    func animation() -> CAKeyframeAnimation {
        let motion = CAKeyframeAnimation(keyPath: "position")
        let steps = 18
        motion.values = (0...steps).map { step in
            let time = begin + Self.duration * Double(step) / Double(steps)
            let position = sample(at: time).position
            return NSValue(point: CGPoint(x: position.x - end.x, y: position.y - end.y))
        }
        motion.isAdditive = true
        motion.beginTime = begin
        motion.duration = Self.duration
        return motion
    }
}

private class SidebarReflowView: NSView {
    var reflow: SidebarReflowMotion?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }
    required init?(coder: NSCoder) { fatalError("Sidebar views are created in code") }

    func clearReflow() {
        reflow = nil
        layer?.removeAnimation(forKey: "sidebarReflow")
    }
}

private final class SidebarCollectionItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("Sidebar tab")
    private let host = SidebarArtworkHost(rootView: AnyView(EmptyView()))
    var tab: BrowserTab?
    var active = false
    var isPinTile = false
    var pinPosition: String?
    var iconOnly = false
    var hovered = false
    var artwork: ((Bool) -> AnyView)?
    var command: ((SidebarTabCommand) -> Void)?
    var open: (() -> Void)?
    private var dragImage: NSDraggingImageComponent?

    override func loadView() {
        let row = SidebarAccessibleRow()
        row.item = self
        row.setAccessibilityElement(true)
        row.setAccessibilityRole(.row)
        host.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            host.topAnchor.constraint(equalTo: row.topAnchor),
            host.bottomAnchor.constraint(equalTo: row.bottomAnchor)
        ])
        view = row
    }

    override var draggingImageComponents: [NSDraggingImageComponent] {
        if let dragImage { return [dragImage] }
        guard let component = captureDragImage(of: view) else { return super.draggingImageComponents }
        dragImage = component
        return [component]
    }

    private func captureDragImage(of view: NSView) -> NSDraggingImageComponent? {
        os_signpost(.begin, log: sidebarDragLog, name: "DragImage")
        defer { os_signpost(.end, log: sidebarDragLog, name: "DragImage") }
        guard !view.bounds.isEmpty, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let image = bitmap.cgImage else { return nil }
        let component = NSDraggingImageComponent(key: .icon)
        component.frame = NSRect(origin: .zero, size: view.bounds.size)
        component.contents = image
        return component
    }

    func clearDragImage() { dragImage = nil }

    override func prepareForReuse() {
        super.prepareForReuse()
        clearDragImage()
        (view as? SidebarReflowView)?.clearReflow()
    }

    override var isSelected: Bool {
        didSet {
            if isSelected != oldValue {
                refresh()
            }
        }
    }

    func refresh() {
        guard let tab, let artwork else { return }
        #if DEBUG
        view.identifier = NSUserInterfaceItemIdentifier("sidebarItem-\(tab.id)")
        (collectionView as? SidebarTabCollection)?.didRefreshDragArtwork()
        #endif
        (view as? SidebarAccessibleRow)?.setAccessibilityIdentifier("sidebarTab-\(tab.id)")
        host.rootView = artwork(isSelected)
        updateFocusRing()
    }

    func updateFocusRing() {
        let list = collectionView as? SidebarTabCollection
        (view as? SidebarAccessibleRow)?.showsFocusRing = isSelected && list?.showsKeyboardFocus == true
    }

    func accessory(at point: NSPoint, includesClose: Bool) -> SidebarRowAccessory? {
        guard !iconOnly, let tab else { return nil }
        let rtl = collectionView?.userInterfaceLayoutDirection == .rightToLeft
        let trailing = rtl ? point.x - view.bounds.minX : view.bounds.maxX - point.x
        let slot = OrivLayout.sidebarAccessoryWidth
        if isPinTile {
            let fromTop = view.bounds.maxY - point.y
            return includesClose && (0..<OrivLayout.sidebarPinCloseWidth).contains(trailing) &&
                (0..<OrivLayout.sidebarPinCloseHeight).contains(fromTop)
                ? .close : nil
        }
        let insetTrailing = trailing - MacBrowserLayout.sidebarRowInset
        guard insetTrailing >= 0, abs(point.y - view.bounds.midY) <= OrivTarget.macMinimum.height / 2 else { return nil }
        if insetTrailing < slot { return includesClose ? .close : nil }
        if insetTrailing < 2 * slot, tab.mediaSuspended || tab.isAudioMuted || tab.isPlayingAudio { return .audio }
        return nil
    }

    func performClick(at point: NSPoint) -> Bool {
        switch accessory(at: point, includesClose: hovered || (!isPinTile && (active || isSelected))) {
        case .close: command?(.close)
        case .audio: command?(tab?.mediaSuspended == true ? .media : .mute)
        case nil: return false
        }
        return true
    }
}

private final class SidebarAccessibleRow: SidebarReflowView {
    weak var item: SidebarCollectionItem?
    private var shadowRadius: CGFloat = 0
    private var shadowBounds = NSRect.zero

    func setSelectionShadow(_ color: NSColor?, radius: CGFloat) {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.shadowColor = color?.cgColor
        layer.shadowOpacity = color == nil ? 0 : 1
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: -1)
        if shadowRadius != radius { shadowBounds = .zero }
        shadowRadius = radius
        updateShadowPath()
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        updateShadowPath()
    }

    private func updateShadowPath() {
        guard let layer, layer.shadowOpacity > 0, !bounds.isEmpty, shadowBounds != bounds else { return }
        shadowBounds = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.shadowPath = CGPath(roundedRect: bounds, cornerWidth: shadowRadius, cornerHeight: shadowRadius, transform: nil)
        CATransaction.commit()
    }
    var showsFocusRing = false {
        didSet {
            if showsFocusRing && oldValue {
                subviews.last?.needsDisplay = true
            } else if showsFocusRing {
                let ring = SidebarRowFocusRing(frame: bounds)
                ring.autoresizingMask = [.width, .height]
                addSubview(ring)
            } else if oldValue {
                subviews.last(where: { $0 is SidebarRowFocusRing })?.removeFromSuperview()
            }
        }
    }

    override var focusRingMaskBounds: NSRect { showsFocusRing ? bounds.insetBy(dx: OrivOutline.focusInset, dy: OrivOutline.focusInset) : .zero }
    var focusRadius: CGFloat {
        if item?.isPinTile == true || item?.iconOnly == true { return OrivLayout.sidebarPinRadius }
        return item?.active == true ? OrivLayout.sidebarSelectionRadius : OrivRadius.control
    }

    override func accessibilityChildren() -> [Any]? { [] }
    override func accessibilityLabel() -> String? {
        guard let item, let tab = item.tab else { return nil }
        return SidebarTabs.label(tab, selected: item.active)
    }
    override func accessibilityValue() -> Any? { item?.pinPosition }
    override func isAccessibilitySelected() -> Bool { item?.isSelected == true }
    override func accessibilityPerformPress() -> Bool { item?.open?(); return item?.tab != nil }
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard let item, let tab = item.tab else { return nil }
        var actions = [NSAccessibilityCustomAction(name: "Close Tab") { [weak item] in item?.command?(.close); return item != nil }]
        actions.append(NSAccessibilityCustomAction(name: tab.isPinned ? "Unpin Tab" : "Pin Tab") { [weak item] in
            item?.command?(.pin); return item != nil
        })
        if tab.isPlayingAudio || tab.isAudioMuted {
            actions.append(NSAccessibilityCustomAction(name: SidebarTabs.muteLabel(tab)) { [weak item] in
                item?.command?(.mute); return item != nil
            })
        }
        if tab.isPlayingAudio || tab.mediaSuspended {
            actions.append(NSAccessibilityCustomAction(name: tab.mediaSuspended ? "Resume Media Playback" : "Pause Media Playback") { [weak item] in
                item?.command?(.media); return item != nil
            })
        }
        return actions
    }
}

/// Draw an opaque focus ring above the hosted artwork. The collection remains
/// the responder and owns keyboard navigation, including through recycled rows.
private final class SidebarRowFocusRing: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func accessibilityIsIgnored() -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let row = superview as? SidebarAccessibleRow else { return }
        let radius = row.focusRadius - OrivOutline.focusInset
        let ring = NSBezierPath(roundedRect: row.focusRingMaskBounds, xRadius: radius, yRadius: radius)
        NSColor(Theme.sidebarKeyboardFocus).setStroke()
        ring.lineWidth = OrivOutline.focus
        ring.stroke()
    }
}

private final class SidebarCollectionHeader: SidebarReflowView, NSCollectionViewElement {
    static let identifier = NSUserInterfaceItemIdentifier("Sidebar section")
    struct Content: Equatable {
        let heading: String?
        let count: Int
        let separator: Bool
    }

    var content: Content?
    let host = SidebarArtworkHost(rootView: AnyView(EmptyView()))

    override init(frame: NSRect) {
        super.init(frame: frame)
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        addSubview(host)
    }
    required init?(coder: NSCoder) { fatalError("Sidebar sections are created in code") }
    override func prepareForReuse() {
        super.prepareForReuse()
        clearReflow()
    }
    override func accessibilityChildren() -> [Any]? { [] }
}

#if DEBUG
/// Records main-run-loop display cadence and the phase at each callback.
/// Display-link delivery alone cannot report WindowServer composition time.
@MainActor private final class SidebarDragFramePacing: NSObject {
    private struct Interval: Sendable {
        let milliseconds: Double
        let expectedMilliseconds: Double
        let phase: String
    }

    private struct Stats: Encodable {
        let count: Int
        let p50MS: Double?
        let p95MS: Double?
        let maxMS: Double?
        let hitches: Int

        init(_ samples: [Interval]) {
            let sorted = samples.map(\.milliseconds).sorted()
            count = sorted.count
            p50MS = sorted.isEmpty ? nil : sorted[(sorted.count - 1) / 2]
            p95MS = sorted.isEmpty ? nil : sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1]
            maxMS = sorted.last
            hitches = samples.filter { $0.milliseconds > 1.5 * $0.expectedMilliseconds }.count
        }
    }

    private struct Hitch: Encodable {
        let frame: Int
        let milliseconds: Double
        let expectedMilliseconds: Double
        let phase: String
    }

    private struct Report: Encodable {
        let startedAt: Date
        let total: Stats
        let phases: [String: Stats]
        let hitches: [Hitch]
    }

    private static let enabledByEnvironment = ProcessInfo.processInfo.environment["ORIV_SIDEBAR_DRAG_FRAMES"] == "1"
    private static let writer = DispatchQueue(label: "Oriv.SidebarDragFrames", qos: .utility)
    private let startedAt = Date()
    private let output: URL
    private var link: CADisplayLink?
    private var previous: (timestamp: CFTimeInterval, expected: CFTimeInterval)?
    private var intervals: [Interval] = []
    var phase = "setup"

    private init(output: URL) {
        self.output = output
    }

    static func start(in view: NSView, output: URL? = nil) -> SidebarDragFramePacing? {
        guard enabledByEnvironment || UserDefaults.standard.bool(forKey: "SidebarDragFramePacing") else { return nil }
        let file = output ?? URL.applicationSupportDirectory.appendingPathComponent("Oriv/sidebar-drag-frames.jsonl")
        let recorder = SidebarDragFramePacing(output: file)
        let link = view.displayLink(target: recorder, selector: #selector(record(_:)))
        recorder.link = link
        link.add(to: .main, forMode: .common)
        link.add(to: .main, forMode: .eventTracking)
        return recorder
    }

    @objc private func record(_ link: CADisplayLink) {
        let timestamp = link.timestamp
        if let previous, timestamp > previous.timestamp, previous.expected > 0 {
            intervals.append(Interval(milliseconds: (timestamp - previous.timestamp) * 1_000,
                                      expectedMilliseconds: previous.expected * 1_000, phase: phase))
        }
        previous = (timestamp, link.targetTimestamp - timestamp)
    }

    func finish() {
        link?.invalidate()
        link = nil
        let intervals = intervals
        let startedAt = startedAt
        let file = output
        Self.writer.async {
            let hitches = intervals.enumerated().compactMap { index, sample -> Hitch? in
                guard sample.milliseconds > 1.5 * sample.expectedMilliseconds else { return nil }
                return Hitch(frame: index + 1, milliseconds: sample.milliseconds,
                             expectedMilliseconds: sample.expectedMilliseconds, phase: sample.phase)
            }
            let report = Report(startedAt: startedAt, total: Stats(intervals),
                                phases: Dictionary(grouping: intervals, by: \.phase).mapValues(Stats.init),
                                hitches: hitches)
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                var line = try JSONEncoder().encode(report)
                line.append(0x0a)
                if FileManager.default.fileExists(atPath: file.path) {
                    let handle = try FileHandle(forWritingTo: file)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: line)
                } else {
                    try line.write(to: file, options: .atomic)
                }
            } catch {
                os_log("Could not write sidebar drag frame pacing", log: sidebarDragLog, type: .error)
            }
        }
    }
}
#endif
