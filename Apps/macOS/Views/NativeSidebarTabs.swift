import AppKit
import BrowserEngine
import SwiftUI

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

/// Virtualized tab rows and fixed-size pinned favicon tiles.
private final class SidebarTabLayout: NSCollectionViewLayout {
    struct Drop: Equatable {
        let target: SidebarDropTarget
        let section: Int
        let slot: Int
    }

    private var items: [IndexPath: NSCollectionViewLayoutAttributes] = [:]
    private var headers: [IndexPath: NSCollectionViewLayoutAttributes] = [:]
    private var hitItems: [IndexPath: NSCollectionViewLayoutAttributes] = [:]
    private var hitHeaders: [IndexPath: NSCollectionViewLayoutAttributes] = [:]
    private var hitSectionEnds: [CGFloat] = []
    private var pinColumns = 1
    private var contentSize = NSSize.zero
    var preview: Drop?
    var landing: UUID?
    private(set) var gap: NSRect?

    override func prepare() {
        super.prepare()
        guard let list = collectionView as? SidebarTabCollection, let data = list.sidebar else { return }
        let width = list.enclosingScrollView?.contentView.bounds.width ?? list.bounds.width
        let icons = data.isIconLayout
        let edge = icons ? MacBrowserLayout.railInset : 0
        let rowWidth = data.isRail ? MacBrowserLayout.railItemWidth : max(0, width - 2 * edge)
        let rowHeight = data.rowHeight
        let spacing = icons ? OrivSpacing.small : OrivSpacing.xxs
        let gridGap = OrivLayout.sidebarPinGap
        let pinGrid = SidebarTabs.PinGrid(availableWidth: rowWidth)
        let rtl = list.userInterfaceLayoutDirection == .rightToLeft
        pinColumns = pinGrid.columns
        gap = nil

        func makeFrames(source: IndexPath?, drop: Drop?) -> CGFloat {
            items.removeAll(keepingCapacity: true)
            headers.removeAll(keepingCapacity: true)
            if drop == nil { hitSectionEnds.removeAll(keepingCapacity: true) }
            var y: CGFloat = 0
            for (section, group) in data.sections.enumerated() {
                if group.headerHeight > 0 {
                    let path = IndexPath(item: 0, section: section)
                    let header = NSCollectionViewLayoutAttributes(forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                                                                   with: path)
                    header.frame = NSRect(x: 0, y: y, width: width, height: group.headerHeight)
                    headers[path] = header
                    y += group.headerHeight
                }

                let removed = source?.section == section ? source?.item : nil
                let inserted = drop?.section == section ? drop?.slot : nil
                let count = group.tabs.count - (removed == nil ? 0 : 1) + (inserted == nil ? 0 : 1)
                for slot in 0..<count {
                    let frame: NSRect
                    if group.grid {
                        let x = CGFloat(slot % pinGrid.columns) * (pinGrid.tileWidth + gridGap)
                        let origin = rtl ? width - x - pinGrid.tileWidth : x
                        frame = NSRect(x: origin, y: y, width: pinGrid.tileWidth, height: OrivLayout.sidebarPinHeight)
                        if (slot + 1).isMultiple(of: pinGrid.columns) || slot == count - 1 {
                            y += OrivLayout.sidebarPinHeight + gridGap
                        }
                    } else {
                        frame = NSRect(x: edge, y: y, width: rowWidth, height: rowHeight)
                        y += rowHeight + spacing
                    }
                    if slot == inserted {
                        gap = frame
                    } else {
                        let peer = slot - (inserted.map { slot > $0 } == true ? 1 : 0)
                        let index = peer + (removed.map { peer >= $0 } == true ? 1 : 0)
                        let path = IndexPath(item: index, section: section)
                        let item = NSCollectionViewLayoutAttributes(forItemWith: path)
                        item.frame = frame
                        if group.tabs[index].id == landing { item.alpha = 0 }
                        items[path] = item
                    }
                }
                if icons && !group.grid && count > 0 { y -= spacing }
                if drop == nil { hitSectionEnds.append(y) }
            }
            return y + (icons ? 0 : 9)
        }

        let baseHeight = makeFrames(source: nil, drop: nil)
        var height = baseHeight
        if let preview, let source = data.dragPath, let original = items[source] {
            hitItems = items
            hitHeaders = headers
            height = makeFrames(source: source, drop: preview)
            let hidden = NSCollectionViewLayoutAttributes(forItemWith: source)
            hidden.frame = original.frame
            hidden.alpha = 0
            items[source] = hidden
        } else {
            hitItems.removeAll()
            hitHeaders.removeAll()
        }
        contentSize = NSSize(width: width, height: height)
    }

    override var collectionViewContentSize: NSSize { contentSize }
    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool { newBounds.width != contentSize.width }
    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        (Array(items.values) + Array(headers.values)).filter { $0.frame.intersects(rect) }
    }
    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? { items[indexPath] }
    override func layoutAttributesForSupplementaryView(ofKind elementKind: String,
                                                        at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? { headers[indexPath] }

    // Resolve the pointer against the unshifted positions so animating a
    // neighbor past the pointer cannot cause the insertion slot to oscillate.
    func drop(at point: NSPoint) -> Drop? {
        guard let list = collectionView as? SidebarTabCollection, let data = list.sidebar,
              point.x >= 0, point.x < contentSize.width, point.y >= 0,
              !hitSectionEnds.isEmpty else { return nil }
        let index = hitSectionEnds.firstIndex(where: { point.y < $0 }) ?? hitSectionEnds.count - 1
        guard data.sections.indices.contains(index) else { return nil }
        let routingItems = hitItems.isEmpty ? items : hitItems
        let routingHeaders = hitItems.isEmpty ? headers : hitHeaders
        let section = data.sections[index]
        let firstPath = IndexPath(item: 0, section: index)
        let source = data.dragPath
        let sourceTab = source.flatMap(data.tab(at:))
        if let header = routingHeaders[firstPath]?.frame, header.contains(point) {
            guard let target = section.pinTarget,
                  case let .pinned(pinned, _) = target else { return nil }
            let isPrivate = sourceTab?.isPrivate == true
            let end = section.tabs.lastIndex { $0.isPrivate == isPrivate }.map { $0 + 1 }
            let slot = end ?? (pinned && !isPrivate ? 0 : section.tabs.count)
            let adjusted = slot - (source?.section == index && (source?.item ?? slot) < slot ? 1 : 0)
            return Drop(target: .pinned(pinned, isPrivate: pinned ? isPrivate : section.kind == .privateTabs),
                        section: index, slot: adjusted)
        }
        guard let first = routingItems[firstPath]?.frame else { return nil }
        let rtl = list.userInterfaceLayoutDirection == .rightToLeft
        let gap = OrivLayout.sidebarPinGap
        let item: Int
        if section.grid {
            let row = Int((point.y - first.minY) / (first.height + gap))
            let leading = rtl ? first.maxX - point.x : point.x - first.minX
            let column = min(pinColumns - 1, max(0, Int(leading / (first.width + gap))))
            item = min(row * pinColumns + column, section.tabs.count - 1)
        } else {
            let spacing = data.isIconLayout ? OrivSpacing.small : OrivSpacing.xxs
            item = min(Int((point.y - first.minY) / (first.height + spacing)), section.tabs.count - 1)
        }
        let path = IndexPath(item: item, section: index)
        guard let tab = data.tab(at: path), let frame = routingItems[path]?.frame else { return nil }
        guard sourceTab == nil || sourceTab?.isPrivate == tab.isPrivate else { return nil }
        let after = section.grid ? (rtl ? point.x <= frame.midX : point.x >= frame.midX) : point.y >= frame.midY
        let boundary = item + (after ? 1 : 0)
        let slot = boundary - (source?.section == index && (source?.item ?? boundary) < boundary ? 1 : 0)
        return Drop(target: .between(tab.id, after: after), section: index, slot: slot)
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
    var separator = false
    var pinTarget: SidebarDropTarget? = nil

    var headerHeight: CGFloat {
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
    private var validatedPasteboard: (sequence: Int, version: Int, matches: Bool)?
    private var paths: [UUID: IndexPath] = [:]
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

    private func makeSections(_ configuration: NativeSidebarTabs) -> [SidebarSection] {
        let pinned = configuration.tabs.filter(\.isPinned)
        let regular = configuration.tabs.filter { !$0.isPinned && !$0.isPrivate }
        let privateTabs = configuration.tabs.filter { $0.isPrivate && !$0.isPinned }
        let pinDrag = (dragCommitted ? nil : drag).flatMap { item in configuration.tabs.first(where: { $0.id == item.id }) }
        let pinning = pinDrag?.isPinned == false
        let unpinningRegular = pinDrag?.isPinned == true && pinDrag?.isPrivate == false
        let unpinningPrivate = pinDrag?.isPinned == true && pinDrag?.isPrivate == true
        var result: [SidebarSection] = []
        if configuration.rail || configuration.peek {
            for group in [
                SidebarSection(kind: .pinned, tabs: pinned, heading: pinning && pinned.isEmpty ? "Pin tab" : nil,
                               pinTarget: .pinned(true)),
                SidebarSection(kind: .regular, tabs: regular, heading: unpinningRegular && regular.isEmpty ? "Unpin tab" : nil, pinTarget: .pinned(false)),
                SidebarSection(kind: .privateTabs, tabs: privateTabs, heading: unpinningPrivate && privateTabs.isEmpty ? "Unpin tab" : nil,
                               pinTarget: .pinned(false, isPrivate: true))
            ] where !group.tabs.isEmpty || group.heading != nil {
                var group = group
                // Keep icon layouts compact, including the empty drag targets.
                group.separator = !result.isEmpty || group.heading != nil
                result.append(group)
            }
        } else {
            if !pinned.isEmpty || pinning {
                result.append(SidebarSection(kind: .pinned, tabs: pinned, heading: pinned.isEmpty ? "Pin tab" : "Pinned",
                                             count: pinned.count, grid: !configuration.searching,
                                             pinTarget: .pinned(true)))
            }
            if !regular.isEmpty || unpinningRegular {
                result.append(SidebarSection(kind: .regular, tabs: regular, heading: regular.isEmpty ? "Unpin tab" : "Tabs",
                                             count: regular.count, pinTarget: .pinned(false)))
            }
            if !privateTabs.isEmpty || unpinningPrivate {
                let heading = privateTabs.isEmpty ? "Unpin tab" : (configuration.controller.profile == nil ? nil : "Private")
                result.append(SidebarSection(kind: .privateTabs, tabs: privateTabs, heading: heading,
                                             count: privateTabs.count, pinTarget: .pinned(false, isPrivate: true)))
            }
        }
        if result.isEmpty {
            result.append(SidebarSection(kind: .empty, tabs: [], heading: configuration.searching ? "No matching tabs" : "No tabs"))
        }
        return result
    }

    func update(_ value: NativeSidebarTabs, environment: EnvironmentValues) {
        guard let list else { return }
        let old = configuration
        if let old, old.controller !== value.controller { detach() }
        let oldSize = self.environment.dynamicTypeSize
        let directionChanged = self.environment.layoutDirection != environment.layoutDirection
        let oldShown = selectedID
        let ownsFocus = list.window?.firstResponder === list
        let newSections = makeSections(value)
        let changesLayout = old?.rail != value.rail || old?.peek != value.peek || old?.searching != value.searching ||
            sections.map(\.headerHeight) != newSections.map(\.headerHeight)
        let profileChanged = old?.controller !== value.controller
        let changesContent = profileChanged || sections.map(\.kind) != newSections.map(\.kind) ||
            sections.map { $0.tabs.map(\.id) } != newSections.map { $0.tabs.map(\.id) }
        let newActive = value.controller.session.selectedTabID
        let changesActive = activeID != newActive
        configuration = value
        self.environment = environment
        sections = newSections
        if changesContent {
            paths.removeAll(keepingCapacity: true)
            for (section, group) in sections.enumerated() {
                for (index, tab) in group.tabs.enumerated() { paths[tab.id] = IndexPath(item: index, section: section) }
            }
        }
        activeID = newActive

        let needsLayout = changesLayout || changesContent || old?.expandedWidth != value.expandedWidth ||
            oldSize != environment.dynamicTypeSize || directionChanged
        if needsLayout { list.clearDragPreviewForContentChange() }
        if changesLayout || changesContent {
            setHovered(nil)
            list.reloadData()
        }
        if needsLayout { list.collectionViewLayout?.invalidateLayout() }
        if changesActive || profileChanged {
            select(newActive, reveal: true)
        } else if changesLayout || changesContent {
            // The search field can finish releasing focus after the collection
            // has already received arrow keys. Carry the highlight through the
            // layout change by ID, even if pinned tiles move to different paths.
            let highlight = ownsFocus || !changesLayout ? oldShown.flatMap { path(for: $0) != nil ? $0 : nil } : nil
            select(highlight ?? newActive, reveal: changesLayout && drag == nil)
        }
        for item in list.visibleItems() {
            if let item = item as? SidebarCollectionItem, let path = list.indexPath(for: item) { configure(item, at: path) }
        }
        for path in list.indexPathsForVisibleSupplementaryElements(ofKind: NSCollectionView.elementKindSectionHeader) {
            if let header = list.supplementaryView(forElementKind: NSCollectionView.elementKindSectionHeader, at: path) as? SidebarCollectionHeader {
                configure(header, section: path.section)
            }
        }
    }

    func detach() {
        list?.finishDragPresentation()
        if drag != nil {
            drag = nil
            dragCommitted = false
            configuration?.controller.sidebar.dragging = false
            configuration?.controller.sidebar.pointer(false, drag: false)
        }
    }

    private func applyDragState(_ active: Bool) {
        guard let value = configuration else { return }
        value.controller.sidebar.dragging = active
        setDragPointer(active)
        update(value, environment: environment)
    }

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
        list.selectionIndexPaths = path.map { [$0] } ?? []
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
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { sections[section].tabs.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: SidebarCollectionItem.identifier, for: indexPath) as! SidebarCollectionItem
        configure(item, at: indexPath)
        return item
    }

    private func configure(_ item: SidebarCollectionItem, at path: IndexPath) {
        guard let configuration, let tab = tab(at: path) else { return }
        let grid = sections[path.section].grid
        item.tab = tab
        item.active = activeID == tab.id
        item.isPinTile = grid
        item.pinPosition = tab.isPinned ? "Pinned, \(path.item + 1) of \(sections[path.section].tabs.count)" : nil
        item.view.toolTip = grid ? tab.displayTitle : nil
        item.iconOnly = configuration.rail || configuration.peek
        item.command = { [weak controller = configuration.controller, weak tab] command in
            if let controller, let tab { SidebarTabs.perform(command, tab: tab, controller: controller) }
        }
        item.open = { [weak self, weak tab] in
            guard let self, let tab else { return }
            if self.activate(tab.id, using: configuration) { self.select(tab.id, reveal: false) }
        }
        let environment = self.environment
        var hovered = hovered == path
        #if DEBUG
        hovered = hovered || environment.sidebarCaptureState.hover == tab.id
        #endif
        item.hovered = hovered
        let active = item.active
        // A host subtitle only helps when it says something the title doesn't.
        let subtitle = configuration.duplicateTitles.contains(tab.displayTitle)
            ? tab.url?.host.flatMap { $0.caseInsensitiveCompare(tab.displayTitle) == .orderedSame ? nil : $0 } : nil
        let accessory = self.hovered == path ? hoveredAccessory : nil
        item.artwork = { selected in
            let content = SidebarTabArtwork(tab: tab, selected: selected, active: active,
                                            tile: grid, rail: configuration.rail || configuration.peek, peek: configuration.peek,
                                            hovered: hovered, hoveredAccessory: accessory, subtitle: subtitle)
            if grid { return AnyView(content.help(tab.displayTitle).environment(\.self, environment)) }
            return AnyView(content.environment(\.self, environment))
        }
        item.refresh()
    }

    func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> NSView {
        let header = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: SidebarCollectionHeader.identifier,
                                                          for: indexPath) as! SidebarCollectionHeader
        configure(header, section: indexPath.section)
        return header
    }

    private func configure(_ header: SidebarCollectionHeader, section index: Int) {
        guard sections.indices.contains(index) else { return }
        let section = sections[index]
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
        session.animatesToStartingPositionsOnCancelOrFail = true
        if let path = paths.first { beginDrag(at: path) }
    }

    func beginDrag(at path: IndexPath) {
        guard let tab = tab(at: path), let controller else { return }
        controller.sidebarTooltip.dismiss()
        validatedPasteboard = nil
        drag = SidebarTabTransfer(id: tab.id, owner: controller.sidebarDragID)
        // Start after AppKit has taken its drag image from the originating cell.
        Task { [weak self] in if self?.drag != nil { self?.applyDragState(true) } }
    }

    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession,
                        endedAt screenPoint: NSPoint, dragOperation operation: NSDragOperation) {
        endDrag()
    }

    func endDrag() {
        guard drag != nil else { return }
        list?.finishDragPresentation()
        drag = nil
        dragCommitted = false
        applyDragState(false)
    }

    func dropTarget(at point: NSPoint) -> SidebarDropTarget? {
        (list?.collectionViewLayout as? SidebarTabLayout)?.drop(at: point)?.target
    }

    fileprivate func acceptsDrag(_ info: NSDraggingInfo) -> Bool {
        guard let list, let controller, let drag, !dragCommitted, controller.session.isProfileActive,
              info.draggingSource as? NSCollectionView === list,
              info.draggingSourceOperationMask.contains(.move), drag.owner == controller.sidebarDragID else { return false }
        let pasteboard = info.draggingPasteboard
        let sequence = info.draggingSequenceNumber
        let version = pasteboard.changeCount
        if let cached = validatedPasteboard, cached.sequence == sequence, cached.version == version { return cached.matches }
        let item = pasteboard.data(forType: Self.pasteboardType).flatMap { try? JSONDecoder().decode(SidebarTabTransfer.self, from: $0) }
        let matches = item?.id == drag.id && item?.owner == drag.owner
        validatedPasteboard = (sequence, version, matches)
        return matches
    }

    fileprivate func drop(at point: NSPoint) -> SidebarTabLayout.Drop? {
        guard let list, let source = dragPath.flatMap(tab(at:)),
              let drop = (list.collectionViewLayout as? SidebarTabLayout)?.drop(at: point) else { return nil }
        if case .pinned(_, let isPrivate) = drop.target, isPrivate != source.isPrivate { return nil }
        return drop
    }

    fileprivate func commit(_ target: SidebarDropTarget, landingIn layout: SidebarTabLayout, animated: Bool) -> IndexPath? {
        guard let drag, var value = configuration else { return nil }
        let controller = value.controller
        let landsInPlace: Bool
        if case .between(let receiver, _) = target { landsInPlace = receiver == drag.id }
        else { landsInPlace = false }
        guard landsInPlace || SidebarTabs.drop([drag], on: target, controller: controller) else { return nil }

        dragCommitted = true
        layout.landing = animated ? drag.id : nil
        list?.clearDragPreviewForContentChange()
        value.tabs = value.searchRequest.map(controller.tabSearchResults) ?? controller.session.orderedTabs
        value.duplicateTitles = SidebarTabs.duplicateTitles(in: value.tabs)
        update(value, environment: environment)
        layout.invalidateLayout()
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
    private let insertionMarker = SidebarInsertionMarker()
    private var edgeScroll: Timer?
    private var dragLocation: NSPoint?
    private var lastScrollTick: TimeInterval?
    private var dragLayout: SidebarTabLayout? { collectionViewLayout as? SidebarTabLayout }
    var insertionMarkerFrame: NSRect? { insertionMarker.superview == nil ? nil : insertionMarker.frame }

    private func showInsertionMarker(_ frame: NSRect?) {
        guard let frame else { insertionMarker.removeFromSuperview(); return }
        insertionMarker.frame = frame
        if insertionMarker.superview == nil { addSubview(insertionMarker, positioned: .above, relativeTo: nil) }
    }

    fileprivate func clearDragPreviewForContentChange() {
        dragLayout?.preview = nil
        showInsertionMarker(nil)
    }

    fileprivate func finishDragPresentation() {
        stopEdgeScroll()
        dragLocation = nil
        if let layout = dragLayout, layout.landing != nil {
            layout.landing = nil
            layout.invalidateLayout()
        }
        presentDrop(nil)
    }

    private func presentDrop(_ drop: SidebarTabLayout.Drop?) {
        guard let layout = dragLayout, layout.preview != drop else { return }
        let animate = sidebar?.reduceMotion == false
        let oldPositions = animate ? cellPositions() : [:]
        layout.preview = drop
        layout.invalidateLayout()
        layoutSubtreeIfNeeded()
        showInsertionMarker(layout.gap)
        if animate { animateCells(from: oldPositions) }
    }

    private func cellPositions() -> [UUID: (NSPoint, CGPoint?)] {
        Dictionary(uniqueKeysWithValues: visibleItems().compactMap { item in
            (item as? SidebarCollectionItem)?.tab.map { tab in
                let layer = item.view.layer
                let from = layer?.presentation()?.position ?? layer?.position
                return (tab.id, (item.view.frame.origin, from))
            }
        })
    }

    private func animateCells(from oldPositions: [UUID: (NSPoint, CGPoint?)]) {
        for case let item as SidebarCollectionItem in visibleItems() {
            guard let id = item.tab?.id, let (origin, position) = oldPositions[id],
                  origin != item.view.frame.origin else { continue }
            item.animateReflow(from: position, origin: origin, flipped: item.view.superview?.isFlipped == true)
        }
    }

    // A native drag can stop delivering updates while the pointer is held
    // still at an edge. Scroll during AppKit's tracking loop as well.
    private func updateEdgeScroll() {
        guard let dragLocation, enclosingScrollView != nil,
              edgeVelocity(at: convert(dragLocation, from: nil).y) != 0 else {
            stopEdgeScroll()
            return
        }
        guard edgeScroll == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scrollDuringDrag() }
        }
        lastScrollTick = ProcessInfo.processInfo.systemUptime
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
        edgeScroll = timer
    }

    private func stopEdgeScroll() {
        edgeScroll?.invalidate()
        edgeScroll = nil
        lastScrollTick = nil
    }

    private func edgeVelocity(at y: CGFloat) -> CGFloat {
        let band = min(OrivTarget.macRail.height, visibleRect.height / 3)
        guard band > 0, y >= visibleRect.minY, y <= visibleRect.maxY else { return 0 }
        let top = max(0, 1 - (y - visibleRect.minY) / band)
        let bottom = max(0, 1 - (visibleRect.maxY - y) / band)
        return 580 * (bottom * bottom - top * top)
    }

    private func scrollDuringDrag() {
        guard let dragLocation, sidebar?.dragPath != nil, let scroll = enclosingScrollView else {
            stopEdgeScroll()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = min(1.0 / 30, now - (lastScrollTick ?? now))
        lastScrollTick = now
        let clip = scroll.contentView
        let local = convert(dragLocation, from: nil)
        let velocity = edgeVelocity(at: local.y)
        let origin = clip.constrainBoundsRect(clip.bounds.offsetBy(dx: 0, dy: velocity * elapsed)).origin
        guard origin != clip.bounds.origin else { return }
        clip.scroll(to: origin)
        scroll.reflectScrolledClipView(clip)
        presentDrop(sidebar?.drop(at: convert(dragLocation, from: nil)))
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard sidebar?.acceptsDrag(sender) == true else { finishDragPresentation(); return [] }
        let point = sender.draggingLocation
        if dragLocation == nil { sidebar?.setDragPointer(true) }
        let drop = sidebar?.drop(at: convert(point, from: nil))
        presentDrop(drop)
        dragLocation = point
        updateEdgeScroll()
        return drop == nil ? [] : .move
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        sidebar?.setDragPointer(false)
        finishDragPresentation()
        super.draggingExited(sender)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard sidebar?.acceptsDrag(sender) == true,
              let drop = sidebar?.drop(at: convert(sender.draggingLocation, from: nil)) else { return false }
        presentDrop(drop)
        sender.animatesToDestination = sidebar?.reduceMotion == false
        return true
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard sidebar?.acceptsDrag(sender) == true, let layout = dragLayout,
              let drop = sidebar?.drop(at: convert(sender.draggingLocation, from: nil)) else { return false }
        presentDrop(drop)
        let animated = sender.animatesToDestination
        let positions = animated ? cellPositions() : [:]
        guard let path = sidebar?.commit(drop.target, landingIn: layout, animated: animated) else { return false }
        if animated, let destination = layout.layoutAttributesForItem(at: path)?.frame,
           destination.intersects(visibleRect) {
            animateCells(from: positions)
            sender.draggingFormation = .none
            sender.enumerateDraggingItems(options: [], for: self, classes: [NSPasteboardItem.self], searchOptions: [:]) { item, _, _ in
                let size = item.draggingFrame.size
                item.draggingFrame = NSRect(x: destination.midX - size.width / 2, y: destination.midY - size.height / 2,
                                           width: size.width, height: size.height)
            }
        }
        stopEdgeScroll()
        return true
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        finishDragPresentation()
        super.concludeDragOperation(sender)
    }

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
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        pointerTracking = area
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseMoved(with event: NSEvent) {
        if let presentation = sidebar?.controller?.sidebar, !presentation.pointerInside { presentation.pointer(true, moved: true) }
        let point = convert(event.locationInWindow, from: nil)
        let path = indexPathForItem(at: point)
        let item = path.flatMap { self.item(at: $0) as? SidebarCollectionItem }
        sidebar?.setHovered(path, accessory: item.flatMap { $0.accessory(at: $0.view.convert(point, from: self), includesClose: true) })

    }

    override func mouseExited(with event: NSEvent) {
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
        guard !view.bounds.isEmpty, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return super.draggingImageComponents
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let component = NSDraggingImageComponent(key: .icon)
        component.frame = NSRect(origin: .zero, size: view.bounds.size)
        component.contents = bitmap.cgImage
        return [component]
    }

    func animateReflow(from oldPosition: CGPoint?, origin: NSPoint, flipped: Bool) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        let position = layer.position
        let animation = CASpringAnimation(keyPath: "position")
        animation.fromValue = oldPosition ?? CGPoint(x: position.x + origin.x - view.frame.minX,
                                                     y: position.y + (origin.y - view.frame.minY) * (flipped ? -1 : 1))
        animation.toValue = position
        animation.mass = 1
        animation.stiffness = 470
        animation.damping = 43
        animation.duration = animation.settlingDuration
        layer.add(animation, forKey: "sidebarReflow")
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

private final class SidebarAccessibleRow: NSView {
    weak var item: SidebarCollectionItem?
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

private final class SidebarCollectionHeader: NSView, NSCollectionViewElement {
    static let identifier = NSUserInterfaceItemIdentifier("Sidebar section")
    let host = SidebarArtworkHost(rootView: AnyView(EmptyView()))

    override init(frame: NSRect) {
        super.init(frame: frame)
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        addSubview(host)
    }
    required init?(coder: NSCoder) { fatalError("Sidebar sections are created in code") }
    override func accessibilityChildren() -> [Any]? { [] }
}
