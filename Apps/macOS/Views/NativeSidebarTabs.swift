import AppKit
import BrowserEngine
import SwiftUI
import os.signpost

private let sidebarDragLog = OSLog(subsystem: "Oriv", category: "SidebarDrag")

@MainActor @Observable final class SidebarListHandle {
    @ObservationIgnored weak var collection: SidebarTabCollection?
    var hasFocus = false
    var contentHeight: CGFloat? = nil
    @ObservationIgnored var fallbackHeight: CGFloat? = nil

    func focus(_ id: UUID? = nil) { collection?.focusTab(id) }

    func updateContentHeight(_ height: CGFloat) {
        let current = contentHeight ?? fallbackHeight
        if let current, abs(current - height) <= 0.5 { return }
        contentHeight = height
    }

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
    var overflowing = true
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
        let started = list.dragWorkStart
        defer { list.recordDragWork("sidebarRepresentable", started: started) }
        scroll.profiles = profiles?.controller === controller ? profiles : nil
        // Legacy scrollbars reserve space even when idle. In the rail,
        // wheel/trackpad and keyboard scrolling use the entire rail viewport.
        let direction: NSUserInterfaceLayoutDirection = context.environment.layoutDirection == .rightToLeft ? .rightToLeft : .leftToRight
        scroll.userInterfaceLayoutDirection = direction
        list.userInterfaceLayoutDirection = direction
        let iconLayout = rail || peek
        scroll.usesIconLayout = iconLayout
        scroll.scrollerStyle = (iconLayout || !overflowing) ? .overlay : NSScroller.preferredScrollerStyle
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
        let rowSpacing = icons ? OrivSpacing.small : OrivMacV3.SidebarLayout.tabRowGap
        let pinGrid = SidebarTabs.PinGrid(availableWidth: rowWidth)
        let rtl = list.userInterfaceLayoutDirection == .rightToLeft
        let sections = data.sections
        hiddenSource = hidesSource ? data.dragPath : nil

        func makeGeometry(_ geometry: inout [SectionGeometry], source: IndexPath?, gap: Gap?) -> CGFloat {
            geometry.removeAll(keepingCapacity: true)
            var y: CGFloat = 0
            var hasVisibleSection = false
            for (index, group) in sections.enumerated() {
                let count = group.tabs.count - (source?.section == index ? 1 : 0) + (gap?.section == index ? 1 : 0)
                let headerHeight = gap == nil ? group.headerHeight :
                    data.projectedHeaderHeight(for: group, count: count, hasVisibleSection: hasVisibleSection)
                if count > 0 { hasVisibleSection = true }
                let header = NSRect(x: 0, y: y, width: width, height: headerHeight)
                y += header.height
                let top = y
                let columns = group.grid ? pinGrid.columns : 1
                let height = group.grid ? OrivMacV3.SidebarLayout.pinHeight : rowHeight
                let spacing = group.grid ? OrivMacV3.SidebarLayout.pinGap : rowSpacing
                let widthOfItem = group.grid ? pinGrid.tileWidth : rowWidth
                if count > 0 {
                    let rows = CGFloat((count + columns - 1) / columns)
                    if group.grid {
                        let hasFollowing = sections.dropFirst(index + 1).enumerated().contains { offset, later in
                            let laterIndex = index + 1 + offset
                            let laterCount = later.tabs.count - (source?.section == laterIndex ? 1 : 0) + (gap?.section == laterIndex ? 1 : 0)
                            return laterCount > 0 || later.headerHeight > 0
                        }
                        y += rows * (height + spacing) - spacing + (hasFollowing ? OrivMacV3.SidebarLayout.pinBottomMargin : rowSpacing)
                    } else {
                        y += rows * (height + spacing)
                        if icons {
                            y -= spacing
                        } else if group.kind == .regular {
                            let hasFollowing = sections.dropFirst(index + 1).enumerated().contains { offset, later in
                                let laterIndex = index + 1 + offset
                                let laterCount = later.tabs.count - (source?.section == laterIndex ? 1 : 0) + (gap?.section == laterIndex ? 1 : 0)
                                return laterCount > 0 || later.headerHeight > 0
                            }
                            if hasFollowing { y += OrivSpacing.medium - spacing }
                        }
                    }
                }
                geometry.append(SectionGeometry(header: header, itemsTop: top, end: y, count: count,
                                                columns: columns, x: group.grid ? (rtl ? width - widthOfItem : 0) : edge,
                                                width: widthOfItem, height: height, spacing: spacing, rtl: group.grid && rtl))
            }
            return y
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
        data.publishContentHeight(contentSize.height)
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
        if path == hiddenSource { attributes.alpha = 0 }
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
              point.x >= 0, point.x <= contentSize.width, point.y >= 0,
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

    var headerHeight: CGFloat {
        if separator { return 25 }
        switch heading {
        case "Pinned", "Pin tab", "Private", "Tabs", "Unpin tab": return OrivMacV3.SidebarLayout.sectionTotalHeight
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
    private var rowEnvironment = EnvironmentValues()
    private var cachedStyle: SidebarChromaticStyle?
    private var cachedMode: OrivMacV3.AppearanceMode = .light
    private var activeID: UUID?
    private(set) var hovered: IndexPath?
    private var hoveredAccessory: SidebarRowAccessory?
    private var drag: SidebarTabTransfer?
    private var pendingDrop: SidebarTabLayout.Drop?
    private var dropHandoff: Task<Void, Never>?
    private var awaitingDropUpdate = false
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
        if isIconLayout { return MacBrowserLayout.railItemHeight }
        return environment.dynamicTypeSize.isAccessibilitySize ? OrivLayout.sidebarAccessibilityRowHeight : OrivMacV3.SidebarLayout.tabRowHeight
    }

    private var lastPublishedHeight: CGFloat?

    fileprivate func publishContentHeight(_ height: CGFloat) {
        guard !isIconLayout, let handle = configuration?.handle else { return }
        if let last = lastPublishedHeight, abs(last - height) <= 0.5 { return }
        lastPublishedHeight = height
        DispatchQueue.main.async { [weak handle] in
            handle?.updateContentHeight(height)
        }
    }

    private enum DragUpdate {
        case sections
        case move(UUID)
    }

    private func makeSections(_ configuration: NativeSidebarTabs, publishingDrop: Bool, landedTabs: [[BrowserTab]]?) -> [SidebarSection] {
        let pinned = landedTabs?[0] ?? configuration.tabs.filter(\.isPinned)
        let regular = landedTabs?[1] ?? configuration.tabs.filter { !$0.isPinned && !$0.isPrivate }
        let privateTabs = landedTabs?[2] ?? configuration.tabs.filter { $0.isPrivate && !$0.isPinned }
        let pinDrag = publishingDrop ? nil : dragPath.flatMap(tab(at:))
        let pinning = pinDrag?.isPinned == false
        let unpinningRegular = pinDrag?.isPinned == true && pinDrag?.isPrivate == false
        let unpinningPrivate = pinDrag?.isPinned == true && pinDrag?.isPrivate == true
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
            let grid = kind == .pinned && !icons && !configuration.searching
            guard !tabs.isEmpty || wantsEmptyTarget else {
                if kind == .regular && configuration.tabs.isEmpty {
                    return SidebarSection(kind: .empty, tabs: [], heading: configuration.searching ? "No matching tabs" : "No tabs")
                }
                return SidebarSection(kind: kind, tabs: [], grid: grid)
            }
            let heading: String?
            if tabs.isEmpty {
                heading = emptyTitle
            } else {
                heading = icons ? nil : title
            }
            let separator = icons && (hasVisibleSection || heading != nil)
            hasVisibleSection = true
            return SidebarSection(kind: kind, tabs: tabs, heading: heading,
                                  count: icons ? 0 : tabs.count, grid: grid,
                                  normalPinCount: kind == .pinned ? tabs.prefix { !$0.isPrivate }.count : 0,
                                  separator: separator, pinTarget: .pinned(kind == .pinned, isPrivate: kind == .privateTabs))
        }
    }

    fileprivate func projectedHeaderHeight(for group: SidebarSection, count: Int, hasVisibleSection: Bool) -> CGFloat {
        guard count > 0 else { return 0 }
        let heading: String?
        switch group.kind {
        case .pinned: heading = "Pinned"
        case .regular: heading = "Tabs"
        case .privateTabs: heading = controller?.profile == nil ? nil : "Private"
        case .empty: heading = nil
        }
        return SidebarSection(kind: group.kind, tabs: [], heading: isIconLayout ? nil : heading,
                              separator: isIconLayout && hasVisibleSection).headerHeight
    }

    func update(_ value: NativeSidebarTabs, environment: EnvironmentValues) {
        update(value, environment: environment, dragUpdate: nil)
    }

    private func update(_ value: NativeSidebarTabs, environment: EnvironmentValues, dragUpdate: DragUpdate?,
                        landedTabs: [[BrowserTab]]? = nil) {
        guard let list else { return }
        let started = list.dragWorkStart
        defer { list.recordDragWork("collectionUpdate", started: started) }
        let old = configuration
        if let old, old.controller !== value.controller { detach() }
        let oldSize = self.environment.dynamicTypeSize
        let oldStyle = self.environment.sidebarStyle
        let directionChanged = self.environment.layoutDirection != environment.layoutDirection
        let oldShown = selectedID
        let ownsFocus = list.window?.firstResponder === list
        let oldSections = sections
        let publishingDrop = if case .move = dragUpdate { true } else { false }
        let newSections = makeSections(value, publishingDrop: publishingDrop, landedTabs: landedTabs)
        let oldKinds = oldSections.map(\.kind)
        let newKinds = newSections.map(\.kind)
        let changesLayout = old?.rail != value.rail || old?.peek != value.peek || old?.searching != value.searching ||
            oldSections.map(\.headerHeight) != newSections.map(\.headerHeight)
        let profileChanged = old?.controller !== value.controller
        let changesContent = profileChanged || oldKinds != newKinds ||
            oldSections.map { $0.tabs.map(\.id) } != newSections.map { $0.tabs.map(\.id) }
        let newActive = value.controller.session.selectedTabID
        let changesActive = activeID != newActive
        let isDropUpdate = dragUpdate == nil && awaitingDropUpdate
        if dragUpdate == nil { awaitingDropUpdate = false }
        configuration = value
        self.environment = environment
        var rowEnv = environment
        rowEnv.sidebarDefersIconHydration = { [weak self] url in self?.deferIconHydration(url) == true }
        rowEnvironment = rowEnv
        let resolvedStyle = environment.sidebarStyle
        cachedStyle = resolvedStyle
        cachedMode = OrivMacV3.AppearanceMode.resolve(theme: environment.browserTheme,
                                                      colorScheme: environment.colorScheme,
                                                      isPrivateWindow: environment.v3AppearanceMode == .private)
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
        case .move(let id):
            let from = paths[id]
            let to = newSections.enumerated().lazy.compactMap { index, group in
                group.tabs.firstIndex { $0.id == id }.map { IndexPath(item: $0, section: index) }
            }.first
            func applyDrop() {
                applySections()
                list.clearDragPreviewForContentChange()
                layout?.hidesSource = false
            }

            if let from, let to, from != to {
                // The visible siblings are already in their projected positions.
                // Keep the same collection items when publishing the landed move.
                let batchStarted = list.dragWorkStart
                list.performBatchUpdates {
                    applyDrop()
                    list.moveItem(at: from, to: to)
                }
                list.recordDragWork("collectionBatchMove", started: batchStarted)
            } else {
                applyDrop()
                layout?.invalidateLayout()
            }
        default:
            if needsLayout { list.clearDragPreviewForContentChange() }
            applySections()
            if changesLayout || changesContent { setHovered(nil) }
            if changesContent { list.reloadData() }
            if needsLayout {
                layout?.invalidateLayout()
                if drag != nil && pendingDrop == nil { list.refreshDragDestination() }
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
        let keepArtwork = dragUpdate != nil || ((drag != nil || isDropUpdate) && !needsLayout &&
            oldStyle == environment.sidebarStyle && old?.searchRequest == value.searchRequest &&
            old?.duplicateTitles == value.duplicateTitles)
        if isDropUpdate && keepArtwork && !changesActive { return }
        if case .move(let id) = dragUpdate, !changesActive {
            // The batch preserves item identity. Only the moved tab can have
            // switched between a tile and a row.
            if let path = paths[id], let item = list.item(at: path) as? SidebarCollectionItem {
                configure(item, at: path, keepArtwork: true)
            }
        } else {
            for case let item as SidebarCollectionItem in list.visibleItems() {
                if let path = list.indexPath(for: item) { configure(item, at: path, keepArtwork: keepArtwork) }
            }
        }
        for path in list.indexPathsForVisibleSupplementaryElements(ofKind: NSCollectionView.elementKindSectionHeader) {
            if let header = list.supplementaryView(forElementKind: NSCollectionView.elementKindSectionHeader, at: path) as? SidebarCollectionHeader {
                configure(header, section: path.section, keepArtwork: keepArtwork)
            }
        }
    }

    func detach() {
        commitPendingDropForSave()
        awaitingDropUpdate = false
        list?.finishDragPresentation()
        deferredIconURLs.removeAll()
        if drag != nil {
            drag = nil
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
        list.layoutSubtreeIfNeeded()
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

    func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem,
                        forRepresentedObjectAt indexPath: IndexPath) {
        #if DEBUG
        item.view.identifier = nil
        #endif
    }

    private func configure(_ item: SidebarCollectionItem, at path: IndexPath, keepArtwork: Bool = false) {
        guard let configuration, let tab = tab(at: path) else { return }
        let started = list?.dragWorkStart ?? 0
        defer { list?.recordDragWork("configureRow", started: started) }
        #if DEBUG
        item.setDragInstrumentation(list)
        #endif
        let grid = sections[path.section].grid
        let active = activeID == tab.id
        let icons = configuration.rail || configuration.peek
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
        let style = cachedStyle ?? environment.sidebarStyle
        let mode = cachedMode
        let radius = OrivMacV3.Radius.row
        let shadowColor: NSColor? = if active && !style.opaque {
            if mode == .private || mode == .black || style.isGraphite {
                OrivMacV3.Sidebar.activeShadow(mode).primary.map { NSColor($0.color) }
            } else {
                NSColor(style.glow)
            }
        } else { nil }
        (item.view as? SidebarAccessibleRow)?.setSelectionShadow(shadowColor, radius: radius)
        item.refresh()
    }

    private func artwork(for tab: BrowserTab, in configuration: NativeSidebarTabs, grid: Bool,
                         hovered: Bool, accessory: SidebarRowAccessory?) -> (Bool, Bool) -> AnyView {
        // A host subtitle only helps when it says something the title doesn't.
        let subtitle = configuration.duplicateTitles.contains(tab.displayTitle)
            ? tab.url?.host.flatMap { $0.caseInsensitiveCompare(tab.displayTitle) == .orderedSame ? nil : $0 } : nil
        let environment = self.rowEnvironment
        let active = activeID == tab.id
        let icons = configuration.rail || configuration.peek
        let peek = configuration.peek
        let style = cachedStyle
        let mode = cachedMode
        return { selected, preview in
            var content = SidebarTabArtwork(tab: tab, selected: selected, active: active, tile: grid,
                                            rail: icons, peek: peek, hovered: hovered,
                                            hoveredAccessory: accessory, subtitle: subtitle,
                                            resolvedStyle: style, resolvedMode: mode)
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

    fileprivate func preview(for tab: BrowserTab, grid: Bool, size: NSSize, scale: CGFloat) -> NSDraggingImageComponent? {
        guard let configuration else { return nil }
        let artwork = artwork(for: tab, in: configuration, grid: grid, hovered: false, accessory: nil)
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
        let started = list?.dragWorkStart ?? 0
        defer { list?.recordDragWork("configureHeading", started: started) }
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
        guard drag == nil, let tab = tab(at: path), let controller else { return }
        let started = CACurrentMediaTime()
        validatedPasteboard = nil
        drag = SidebarTabTransfer(id: tab.id, owner: controller.sidebarDragID)
        list?.beginDragPresentation(at: path, started: started)
        // Leave AppKit's source index path untouched while it takes the image.
        Task { [weak self] in self?.activateDrag() }
    }

    fileprivate func activateDrag() {
        guard drag != nil, let controller, !controller.sidebar.dragging else { return }
        let started = CACurrentMediaTime()
        defer { list?.recordDragWork("dragSetup", started: started) }
        os_signpost(.begin, log: sidebarDragLog, name: "DragSetup")
        defer { os_signpost(.end, log: sidebarDragLog, name: "DragSetup") }
        controller.sidebarTooltip.dismiss()
        setHovered(nil)
        list?.hideDragSource(at: dragPath)
        controller.sidebar.dragging = true
        setDragPointer(true)
        if let path = dragPath, let tab = tab(at: path),
           sections[tab.isPinned ? (tab.isPrivate ? 2 : 1) : 0].tabs.isEmpty,
           let configuration {
            update(configuration, environment: environment, dragUpdate: .sections)
        }
    }

    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession,
                        endedAt screenPoint: NSPoint, dragOperation operation: NSDragOperation) {
        // A successful destination concludes after AppKit's image lands.
        if pendingDrop == nil { endDrag() }
    }

    func endDrag() {
        guard drag != nil, pendingDrop == nil else { return }
        list?.animateDropSections {
            list?.finishDragPresentation()
            drag = nil
            applyDragState(false)
        }
        notifyDragFinished()
    }

    private func notifyDragFinished() {
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
        guard let list, let controller, let drag, pendingDrop == nil, controller.session.isProfileActive,
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

    fileprivate func acceptDrop(_ drop: SidebarTabLayout.Drop) -> Bool {
        guard let drag, let source = dragPath, let controller else { return false }
        guard staysInPlace(drop, source: source) || SidebarTabs.canDrop(drag, on: drop.target, controller: controller) else { return false }
        pendingDrop = drop
        controller.sidebarWithPendingDrop = self
        // Preserve the release geometry if a rail dwell was about to reveal titles.
        controller.sidebar.cancelPendingPeek()
        return true
    }

    private func staysInPlace(_ drop: SidebarTabLayout.Drop, source: IndexPath) -> Bool {
        source.section == drop.gap.section && source.item == drop.gap.slot
    }

    private func applyModelDrop(_ drop: SidebarTabLayout.Drop, drag: SidebarTabTransfer, controller: BrowserController) -> Bool {
        guard let source = dragPath else { return false }
        return staysInPlace(drop, source: source) || SidebarTabs.drop([drag], on: drop.target, controller: controller)
    }

    fileprivate func concludeDrop() {
        guard pendingDrop != nil, dropHandoff == nil else { return }
        list?.holdLandingImage()
        // AppKit is still showing its image in concludeDragOperation. Keep an
        // identical local image while it removes that image and returns to the
        // run loop. Publish the model after the visual handoff.
        dropHandoff = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            self?.publishDrop()
        }
    }

    private func clearPendingDrop() {
        if controller?.sidebarWithPendingDrop === self { controller?.sidebarWithPendingDrop = nil }
        pendingDrop = nil
        dropHandoff?.cancel()
        dropHandoff = nil
    }

    /// The application can quit during AppKit's landing animation. Save the
    /// accepted drop even if the normal presentation handoff has not run yet.
    func commitPendingDropForSave() {
        guard let drop = pendingDrop, let drag, let controller else { return }
        clearPendingDrop()
        _ = applyModelDrop(drop, drag: drag, controller: controller)
    }

    private func publishDrop() {
        guard let drop = pendingDrop, let drag, var value = configuration, let list else { return }
        list.markDropPublication()
        let started = list.dragWorkStart
        os_signpost(.begin, log: sidebarDragLog, name: "DropCommit")
        defer { os_signpost(.end, log: sidebarDragLog, name: "DropCommit") }
        clearPendingDrop()
        guard let source = dragPath, value.controller.session.isProfileActive,
              staysInPlace(drop, source: source) || SidebarTabs.canDrop(drag, on: drop.target, controller: value.controller) else {
            list.recordDragWork("dropCommit", started: started)
            endDrag()
            return
        }

        // Keep AppKit's items and replace their projected slots with the same
        // real slots. SwiftUI's subsequent update sees those IDs in place.
        if list.hasProjection(for: drop), let tab = tab(at: source),
           sections.indices.contains(drop.gap.section),
           (0...(sections[drop.gap.section].tabs.count - (source.section == drop.gap.section ? 1 : 0))).contains(drop.gap.slot) {
            var landedTabs = sections.map(\.tabs)
            landedTabs[source.section].remove(at: source.item)
            landedTabs[drop.gap.section].insert(tab, at: drop.gap.slot)
            value.tabs = landedTabs.flatMap { $0 }
            list.landDrop {
                update(value, environment: environment, dragUpdate: .move(drag.id), landedTabs: landedTabs)
            }
            list.recordDragWork("dropCollection", started: started)
            // Use the original path for the no-op check. paths now holds the
            // landed slot, so a lookup would mistake every move for a no-op.
            let modelStarted = list.dragWorkStart
            if !staysInPlace(drop, source: source) { _ = SidebarTabs.drop([drag], on: drop.target, controller: value.controller) }
            list.recordDragWork("dropModel", started: modelStarted)
        } else {
            // A live content change can invalidate the projection while AppKit
            // settles. Resolve by identity using the current model.
            _ = applyModelDrop(drop, drag: drag, controller: value.controller)
            list.recordDragWork("dropModel", started: started)
            let collectionStarted = list.dragWorkStart
            value.tabs = value.searchRequest.map(value.controller.tabSearchResults) ?? value.controller.session.orderedTabs
            value.duplicateTitles = SidebarTabs.duplicateTitles(in: value.tabs)
            list.animateDropSections {
                update(value, environment: environment, dragUpdate: .move(drag.id))
            }
            list.recordDragWork("dropCollection", started: collectionStarted)
        }
        awaitingDropUpdate = true
        self.drag = nil
        value.controller.sidebar.dragging = false
        setDragPointer(false)
        list.finishDragPresentation(keepRecording: true)
        notifyDragFinished()
        list.recordDragWork("dropCommit", started: started)
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
    private weak var trackingDrag: (any NSDraggingInfo)?
    private var lastScrollTick: TimeInterval?
    private var requestedDrop: SidebarTabLayout.Drop?
    private var sourcePreview: NSDraggingImageComponent?
    private var alternatePreview: NSDraggingImageComponent?
    private var sourceUsesGrid = false
    private var showingAlternatePreview = false
    private weak var warmedItem: SidebarCollectionItem?
    private var previewWarmup: Task<Void, Never>?
    private var landingImage: SidebarDragLandingView?
    private var dragLayout: SidebarTabLayout? { collectionViewLayout as? SidebarTabLayout }
    var insertionMarkerFrame: NSRect? { insertionMarker.superview == nil ? nil : insertionMarker.frame }
    #if DEBUG
    private(set) var dragRelayoutCount = 0
    private(set) var dragArtworkRefreshCount = 0
    private(set) var dragImageRenderCount = 0
    private var framePacing: SidebarDragFramePacing?
    var dragFramePacingTestOutput: URL?
    var dragLandingFrame: CGRect? { landingImage?.layer?.presentation()?.frame ?? landingImage?.frame }

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

    fileprivate func beginDragPresentation(at path: IndexPath, started: CFTimeInterval) {
        #if DEBUG
        framePacing?.finish()
        if sidebar?.controller?.testing == false || dragFramePacingTestOutput != nil {
            framePacing = SidebarDragFramePacing.start(in: self, output: dragFramePacingTestOutput)
        }
        #endif
        previewWarmup?.cancel()
        warmDragImages(at: path)
        sourcePreview = warmedItem?.dragImages?.source
        alternatePreview = warmedItem?.dragImages?.alternate
        sourceUsesGrid = sidebar?.sections[path.section].grid == true
        recordDragWork("dragBegin", started: started)
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

    func warmDragImages(at path: IndexPath) {
        guard let sidebar, let tab = sidebar.tab(at: path),
              let item = item(at: path) as? SidebarCollectionItem, item.tab === tab,
              let layout = dragLayout, let size = layout.previewSize(section: path.section), size.width > 0, size.height > 0 else { return }
        let scale = window?.backingScaleFactor ?? 2
        let grid = sidebar.sections[path.section].grid
        let alternateSize = sidebar.isIconLayout || sidebar.isSearching ? nil : layout.previewSize(section: grid ? 1 : 0)
        if let cached = item.dragImages, cached.size == size, cached.alternateSize == alternateSize, cached.scale == scale { return }

        os_signpost(.begin, log: sidebarDragLog, name: "DragImage")
        defer { os_signpost(.end, log: sidebarDragLog, name: "DragImage") }
        #if DEBUG
        dragImageRenderCount += 1
        #endif
        guard let source = sidebar.preview(for: tab, grid: grid, size: size, scale: scale) else { return }
        let alternate = alternateSize.flatMap { sidebar.preview(for: tab, grid: !grid, size: $0, scale: scale) }
        warmedItem?.dragImages = nil
        item.dragImages = SidebarDragImages(size: size, alternateSize: alternateSize, scale: scale,
                                           source: source, alternate: alternate)
        warmedItem = item
    }

    private func warmHoveredDragImages(at path: IndexPath?) {
        previewWarmup?.cancel()
        guard let path, let id = sidebar?.tab(at: path)?.id else { return }
        previewWarmup = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
            guard let self, sidebar?.isDragging == false, let current = sidebar?.path(for: id) else { return }
            warmDragImages(at: current)
        }
    }

    func warmDragImages(atWindowPoint point: NSPoint) {
        guard sidebar?.isDragging == false else { return }
        let local = convert(point, from: nil)
        if visibleRect.contains(local), let path = indexPathForItem(at: local) { warmDragImages(at: path) }
    }

    private func updateDragImage(_ sender: NSDraggingInfo, for drop: SidebarTabLayout.Drop?) {
        guard let sidebar, let source = sidebar.dragPath else { return }
        let section = drop?.gap.section ?? source.section
        guard sidebar.sections.indices.contains(section) else { return }
        let alternate = sidebar.sections[section].grid != sourceUsesGrid
        guard alternate != showingAlternatePreview, let component = alternate ? alternatePreview : sourcePreview else { return }
        let started = CACurrentMediaTime()
        defer { recordDragWork("previewSwap", started: started) }
        sender.enumerateDraggingItems(options: [], for: self, classes: [NSPasteboardItem.self], searchOptions: [:]) { item, _, _ in
            let frame = item.draggingFrame
            let size = component.frame.size
            item.draggingFrame = NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2,
                                        width: size.width, height: size.height)
            item.imageComponentsProvider = { [component] }
            self.showingAlternatePreview = alternate
        }
    }

    private var currentPreview: NSDraggingImageComponent? { showingAlternatePreview ? alternatePreview : sourcePreview }

    private func landingFrame(in gap: NSRect) -> NSRect {
        let size = currentPreview?.frame.size ?? gap.size
        return NSRect(x: gap.midX - size.width / 2, y: gap.midY - size.height / 2, width: size.width, height: size.height)
    }

    fileprivate func holdLandingImage() {
        guard let gap = dragLayout?.gapFrame, let image = currentPreview?.contents else { return }
        let view = SidebarDragLandingView(frame: landingFrame(in: gap))
        view.wantsLayer = true
        view.layerContentsRedrawPolicy = .never
        view.layer?.contents = image
        addSubview(view, positioned: .above, relativeTo: nil)
        landingImage = view
        showInsertionMarker(nil)
    }

    fileprivate func markDropPublication() {
        #if DEBUG
        framePacing?.phase = "publish"
        #endif
    }

    fileprivate var dragWorkStart: CFTimeInterval {
        #if DEBUG
        if framePacing != nil { return CACurrentMediaTime() }
        #endif
        return 0
    }

    fileprivate func recordDragWork(_ name: String, started: CFTimeInterval) {
        #if DEBUG
        if started > 0 { framePacing?.recordWork(name, started: started) }
        #endif
    }

    fileprivate func finishDragPresentation(keepRecording: Bool = false) {
        stopEdgeScrolling()
        dragLocation = nil
        trackingDrag = nil
        landingImage?.removeFromSuperview()
        landingImage = nil
        if let layout = dragLayout, layout.hidesSource {
            layout.hidesSource = false
            if let concealed = sidebar?.dragPath {
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
        if keepRecording, let recorder = framePacing {
            Task { [weak self, weak recorder] in
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, let recorder, framePacing === recorder else { return }
                recorder.finish()
                framePacing = nil
            }
        } else {
            framePacing?.finish()
            framePacing = nil
        }
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
        let workStarted = dragWorkStart
        defer { recordDragWork("collectionLayout", started: workStarted) }
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
            let nativeStarted = dragWorkStart
            super.layout()
            recordDragWork("nativeReflowLayout", started: nativeStarted)
            showInsertionMarker(layout.gapFrame)
            let animationStarted = dragWorkStart
            animatePositions(from: positions)
            recordDragWork("reflowAnimations", started: animationStarted)
        }
    }

    fileprivate func hasProjection(for drop: SidebarTabLayout.Drop) -> Bool {
        dragLayout?.preview == drop.gap && dragLayout?.gapFrame != nil
    }

    fileprivate func landDrop(changes: @MainActor () -> Void) {
        withoutImplicitDragAnimation { changes() }
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
            let presented = current == nil ? nil : layer.presentation()?.position
            positions.append(Position(view: view, tab: tab, frame: view.frame,
                                      position: presented ?? current?.position ?? layer.position,
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
        let workStarted = dragWorkStart
        defer { recordDragWork("edgeScroll", started: workStarted) }
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
        if let trackingDrag, let drop { updateDragImage(trackingDrag, for: drop) }
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
        let workStarted = dragWorkStart
        defer { recordDragWork("draggingUpdated", started: workStarted) }
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
        trackingDrag = sender
        dragLocation = point
        updateEdgeScrolling(at: point)
        let drop = drop(at: point)
        requestDrop(drop)
        #if DEBUG
        updateFramePhase(for: drop)
        #endif
        guard let drop else { return [] }
        updateDragImage(sender, for: drop)
        return .move
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        let workStarted = dragWorkStart
        defer { recordDragWork("draggingExited", started: workStarted) }
        if let sender, sidebar?.acceptsDrag(sender) == true { updateDragImage(sender, for: nil) }
        sidebar?.setDragPointer(false)
        trackingDrag = nil
        dragLocation = nil
        stopEdgeScrolling()
        requestDrop(nil)
        #if DEBUG
        framePacing?.phase = "outside"
        #endif
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let started = dragWorkStart
        defer { recordDragWork("prepareDrop", started: started) }
        guard sidebar?.acceptsDrag(sender, readPasteboard: true) == true,
              let drop = drop(at: sender.draggingLocation) else { return false }
        requestDrop(drop)
        layoutSubtreeIfNeeded()
        updateDragImage(sender, for: drop)
        sender.animatesToDestination = sidebar?.reduceMotion == false && dragLayout?.gapFrame?.intersects(visibleRect) == true
        return true
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let started = CACurrentMediaTime()
        guard let sidebar, sidebar.acceptsDrag(sender, readPasteboard: true),
              let drop = requestedDrop, sidebar.acceptDrop(drop) else { return false }
        stopEdgeScrolling()
        dragLocation = nil
        trackingDrag = nil
        if sender.animatesToDestination, let gap = dragLayout?.gapFrame {
            sender.draggingFormation = .none
            let destination = landingFrame(in: gap)
            sender.enumerateDraggingItems(options: [], for: self, classes: [NSPasteboardItem.self], searchOptions: [:]) { item, _, _ in
                item.draggingFrame = destination
            }
        }
        recordDragWork("dropRelease", started: started)
        #if DEBUG
        framePacing?.phase = "settling"
        #endif
        return true
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        let started = dragWorkStart
        defer { recordDragWork("landingHandoff", started: started) }
        sidebar?.concludeDrop()
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
        let workStarted = dragWorkStart
        defer { recordDragWork("trackingAreas", started: workStarted) }
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
        if sidebar?.hovered != path { warmHoveredDragImages(at: path) }
        sidebar?.setHovered(path, accessory: item.flatMap { $0.accessory(at: $0.view.convert(point, from: self), includesClose: true) })
    }

    override func mouseExited(with event: NSEvent) {
        warmHoveredDragImages(at: nil)
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
                                   xRadius: OrivMacV3.Radius.row, yRadius: OrivMacV3.Radius.row)
        outline.lineWidth = OrivOutline.focus
        outline.setLineDash([4, 4], count: 2, phase: 0)
        outline.stroke()
    }
}

private final class SidebarArtworkHost: NSHostingView<AnyView> {
    #if DEBUG
    weak var dragInstrumentation: SidebarTabCollection?

    override func layout() {
        let started = dragInstrumentation?.dragWorkStart ?? 0
        super.layout()
        dragInstrumentation?.recordDragWork("hostingLayout", started: started)
    }
    #endif

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func accessibilityIsIgnored() -> Bool { true }
}

/// A monotone cubic starts at the presented position and ends at rest.
/// Carry as much incoming velocity as the new target permits.
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
            let limit = 3 * distance / Self.duration
            let velocity = min(max(velocity, min(0, limit)), max(0, limit))
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

private struct SidebarDragImages {
    let size: NSSize
    let alternateSize: NSSize?
    let scale: CGFloat
    let source: NSDraggingImageComponent
    let alternate: NSDraggingImageComponent?
}

private final class SidebarDragLandingView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func accessibilityIsIgnored() -> Bool { true }
}

private final class SidebarCollectionItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("Sidebar tab")
    private let host = SidebarArtworkHost(rootView: AnyView(EmptyView()))
    #if DEBUG
    func setDragInstrumentation(_ list: SidebarTabCollection?) { host.dragInstrumentation = list }
    #endif

    var tab: BrowserTab?
    var active = false
    var isPinTile = false
    var pinPosition: String? {
        guard let tab, let data = (collectionView as? SidebarTabCollection)?.sidebar,
              let path = data.path(for: tab.id), data.sections[path.section].kind == .pinned else { return nil }
        return "Pinned, \(path.item + 1) of \(data.sections[path.section].tabs.count)"
    }
    var iconOnly = false
    var hovered = false
    var artwork: ((Bool) -> AnyView)?
    var command: ((SidebarTabCommand) -> Void)?
    var open: (() -> Void)?
    var dragImages: SidebarDragImages?

    override func loadView() {
        let row = SidebarAccessibleRow()
        row.item = self
        row.setAccessibilityElement(true)
        row.setAccessibilityRole(.row)
        // AppKit's collection layout supplies both dimensions, so SwiftUI
        // does not need to publish an intrinsic size for every reflow.
        host.sizingOptions = []
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
        if dragImages == nil, let list = collectionView as? SidebarTabCollection, let path = list.indexPath(for: self) {
            list.warmDragImages(at: path)
        }
        return dragImages.map { [$0.source] } ?? super.draggingImageComponents
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        dragImages = nil
        #if DEBUG
        view.identifier = nil
        #endif
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
        dragImages = nil
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
        if isPinTile {
            let fromTop = view.bounds.maxY - point.y
            return includesClose && (0..<OrivMacV3.SidebarLayout.pinCloseWidth).contains(trailing) &&
                (0..<OrivMacV3.SidebarLayout.pinCloseHeight).contains(fromTop)
                ? .close : nil
        }
        let hasAudio = tab.mediaSuspended || tab.isAudioMuted || tab.isPlayingAudio
        guard includesClose || hasAudio else { return nil }
        let slot = OrivMacV3.SidebarLayout.accessoryHitTarget
        let insetTrailing = trailing - OrivMacV3.SidebarLayout.tabRowPaddingHorizontal
        guard insetTrailing >= 0, abs(point.y - view.bounds.midY) <= slot / 2 else { return nil }
        if includesClose {
            if insetTrailing < slot { return .close }
            if hasAudio && insetTrailing < 2 * slot { return .audio }
        } else if hasAudio && insetTrailing < slot {
            return .audio
        }
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
        OrivMacV3.Radius.row
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
    let host = NSHostingView(rootView: AnyView(EmptyView()))

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

    private struct Work: Encodable, Sendable {
        let phase: String
        let frame: Int
        let offsetMS: Double
        let durationMS: Double
    }

    private struct Report: Encodable {
        let startedAt: Date
        let total: Stats
        let phases: [String: Stats]
        let hitches: [Hitch]
        let mainThreadWork: [String: [Work]]
    }

    private static let enabledByEnvironment = ProcessInfo.processInfo.environment["ORIV_SIDEBAR_DRAG_FRAMES"] == "1"
    private static let writer = DispatchQueue(label: "Oriv.SidebarDragFrames", qos: .utility)
    private let startedAt = Date()
    private let startTime = CACurrentMediaTime()
    private let output: URL
    private var link: CADisplayLink?
    private var previous: (timestamp: CFTimeInterval, expected: CFTimeInterval)?
    private var intervals: [Interval] = []
    private var work: [String: [Work]] = [:]
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

    func recordWork(_ name: String, started: CFTimeInterval) {
        let sample = Work(phase: phase, frame: intervals.count + 1,
                          offsetMS: (started - startTime) * 1_000, durationMS: (CACurrentMediaTime() - started) * 1_000)
        work[name, default: []].append(sample)
    }

    func finish() {
        link?.invalidate()
        link = nil
        let intervals = intervals
        let startedAt = startedAt
        let file = output
        let work = work
        Self.writer.async {
            let hitches = intervals.enumerated().compactMap { index, sample -> Hitch? in
                guard sample.milliseconds > 1.5 * sample.expectedMilliseconds else { return nil }
                return Hitch(frame: index + 1, milliseconds: sample.milliseconds,
                             expectedMilliseconds: sample.expectedMilliseconds, phase: sample.phase)
            }
            let report = Report(startedAt: startedAt, total: Stats(intervals),
                                phases: Dictionary(grouping: intervals, by: \.phase).mapValues(Stats.init),
                                hitches: hitches, mainThreadWork: work)
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
