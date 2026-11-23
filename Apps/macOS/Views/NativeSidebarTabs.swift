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
    let tabs: [BrowserTab]
    let duplicateTitles: Set<String>
    let rail: Bool
    let peek: Bool
    let searching: Bool
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
        scroll.scrollerStyle = iconLayout ? .overlay : NSScroller.preferredScrollerStyle
        scroll.hasVerticalScroller = !iconLayout
        handle.collection = list
        let profileChanged = context.coordinator.controller.map { $0 !== controller } ?? false
        if profileChanged { list.resetKeyboardNavigation() }
        context.coordinator.update(self, environment: context.environment)
        if iconLayout, profileChanged {
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

/// Style B has fixed geometry with two widths and a four-column pinned grid.
private final class SidebarTabLayout: NSCollectionViewLayout {
    private var items: [IndexPath: NSCollectionViewLayoutAttributes] = [:]
    private var headers: [IndexPath: NSCollectionViewLayoutAttributes] = [:]
    private var contentSize = NSSize.zero

    override func prepare() {
        super.prepare()
        items.removeAll(keepingCapacity: true)
        headers.removeAll(keepingCapacity: true)
        guard let list = collectionView as? SidebarTabCollection, let data = list.sidebar else { return }
        let width = list.enclosingScrollView?.contentView.bounds.width ?? list.bounds.width
        let icons = data.isIconLayout
        let edge = icons ? MacBrowserLayout.railInset : 0
        let rowWidth = data.isRail ? MacBrowserLayout.railItemWidth : max(0, width - 2 * edge)
        let rowHeight = data.rowHeight
        let spacing: CGFloat = icons ? 6 : 1
        let gridColumns = 4
        let gridGap: CGFloat = 8
        let tileWidth = max(0, (rowWidth - CGFloat(gridColumns - 1) * gridGap) / CGFloat(gridColumns))
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
            if group.grid { y += 4 }
            for index in group.tabs.indices {
                let path = IndexPath(item: index, section: section)
                let item = NSCollectionViewLayoutAttributes(forItemWith: path)
                if group.grid {
                    let x = edge + CGFloat(index % gridColumns) * (tileWidth + gridGap)
                    let origin = list.userInterfaceLayoutDirection == .rightToLeft ? width - x - tileWidth : x
                    item.frame = NSRect(x: origin, y: y + CGFloat(index / gridColumns) * 57, width: tileWidth, height: 48)
                } else {
                    item.frame = NSRect(x: edge, y: y + CGFloat(index) * (rowHeight + spacing), width: rowWidth, height: rowHeight)
                }
                items[path] = item
            }
            if group.grid { y += CGFloat((group.tabs.count + gridColumns - 1) / gridColumns) * 57 - 4 }
            else if !group.tabs.isEmpty { y += CGFloat(group.tabs.count) * (rowHeight + spacing) - (icons ? spacing : 0) }
        }
        contentSize = NSSize(width: width, height: y + (icons ? 0 : 9))
    }

    override var collectionViewContentSize: NSSize { contentSize }
    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool { newBounds.width != contentSize.width }
    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        (Array(items.values) + Array(headers.values)).filter { $0.frame.intersects(rect) }
    }
    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? { items[indexPath] }
    override func layoutAttributesForSupplementaryView(ofKind elementKind: String,
                                                        at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? { headers[indexPath] }

    override func layoutAttributesForDropTarget(at point: NSPoint) -> NSCollectionViewLayoutAttributes? {
        if let item = items.values.first(where: { $0.frame.contains(point) }) { return item }
        guard let header = headers.values.first(where: { $0.frame.contains(point) }), let path = header.indexPath else { return nil }
        return layoutAttributesForInterItemGap(before: path)
    }

    override func layoutAttributesForInterItemGap(before indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard let frame = headers[indexPath]?.frame ?? items[indexPath]?.frame else { return nil }
        let gap = NSCollectionViewLayoutAttributes(forInterItemGapBefore: indexPath)
        gap.frame = NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: 2)
        return gap
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
    private var viewportWidth: CGFloat = 0
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
    enum Kind: Equatable { case pinned, overflow, regular, privateTabs, empty }
    let kind: Kind
    let tabs: [BrowserTab]
    var heading: String? = nil
    var count = 0
    var grid = false
    var separator = false
    var pinTarget: Bool? = nil

    var headerHeight: CGFloat {
        if separator { return 25 }
        switch heading {
        case "Pinned", "Pin tab", "Unpin tab": return 28
        case "Private": return 36
        case "Tabs", "More pinned tabs": return 32
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
    private var preview: Task<Void, Never>?
    private(set) var hovered: IndexPath?
    private var drag: SidebarTabTransfer?
    var controller: BrowserController? { configuration?.controller }
    var isRail: Bool { configuration?.rail == true }
    var isIconLayout: Bool { isRail || configuration?.peek == true }
    var rowHeight: CGFloat { isIconLayout || !environment.dynamicTypeSize.isAccessibilitySize ? 36 : 60 }

    private func makeSections(_ configuration: NativeSidebarTabs) -> [SidebarSection] {
        let pinned = configuration.tabs.filter(\.isPinned)
        let regular = configuration.tabs.filter { !$0.isPinned && !$0.isPrivate }
        let privateTabs = configuration.tabs.filter(\.isPrivate)
        var result: [SidebarSection] = []
        if configuration.rail || configuration.peek {
            for (kind, tabs) in [(SidebarSection.Kind.pinned, pinned), (.regular, regular), (.privateTabs, privateTabs)] where !tabs.isEmpty {
                result.append(SidebarSection(kind: kind, tabs: tabs, separator: !result.isEmpty))
            }
        } else {
            let pins = configuration.searching ? pinned : Array(pinned.prefix(SidebarTabs.gridLimit))
            if !pins.isEmpty {
                result.append(SidebarSection(kind: .pinned, tabs: pins, heading: "Pinned", count: pinned.count,
                                             grid: !configuration.searching, pinTarget: true))
                if pins.count < pinned.count {
                    let overflow = Array(pinned.dropFirst(pins.count))
                    result.append(SidebarSection(kind: .overflow, tabs: overflow, heading: "More pinned tabs", count: overflow.count))
                }
            } else if drag != nil && !configuration.searching && !configuration.controller.session.isExternalPrivate {
                result.append(SidebarSection(kind: .pinned, tabs: [], heading: "Pin tab", pinTarget: true))
            }
            if !regular.isEmpty {
                result.append(SidebarSection(kind: .regular, tabs: regular, heading: "Tabs", count: regular.count, pinTarget: false))
            } else if drag != nil && !configuration.searching && !configuration.controller.session.isExternalPrivate {
                result.append(SidebarSection(kind: .regular, tabs: [], heading: "Unpin tab", pinTarget: false))
            }
            if !privateTabs.isEmpty {
                result.append(SidebarSection(kind: .privateTabs, tabs: privateTabs, heading: "Private", count: privateTabs.count))
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
        let changesLayout = old?.rail != value.rail || old?.peek != value.peek || old?.searching != value.searching
        let oldSize = self.environment.dynamicTypeSize
        let directionChanged = self.environment.layoutDirection != environment.layoutDirection
        let oldShown = selectedID
        let newSections = makeSections(value)
        let profileChanged = old?.controller !== value.controller
        let changesContent = profileChanged || sections.map(\.kind) != newSections.map(\.kind) ||
            sections.map { $0.tabs.map(\.id) } != newSections.map { $0.tabs.map(\.id) }
        let newActive = value.controller.session.selectedTabID
        let changesActive = activeID != newActive
        configuration = value
        self.environment = environment
        sections = newSections
        activeID = newActive

        if changesLayout || changesContent {
            setHovered(nil)
            list.reloadData()
        }
        if changesLayout || changesContent || oldSize != environment.dynamicTypeSize || directionChanged {
            list.collectionViewLayout?.invalidateLayout()
        }
        if changesLayout || changesActive || profileChanged {
            cancelPreview()
            select(newActive, reveal: true)
        } else if changesContent {
            select(oldShown.flatMap { path(for: $0) != nil ? $0 : nil } ?? newActive, reveal: false)
            if selectedID != oldShown { cancelPreview() }
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
        cancelPreview()
        if drag != nil {
            drag = nil
            configuration?.controller.sidebar.dragging = false
            configuration?.controller.sidebar.pointer(false, drag: false)
        }
    }

    private func applyDragState(_ active: Bool) {
        guard let value = configuration else { return }
        value.controller.sidebar.dragging = active
        value.controller.sidebar.pointer(active, drag: active)
        update(value, environment: environment)
    }

    func path(for id: UUID) -> IndexPath? {
        for (section, group) in sections.enumerated() {
            if let item = group.tabs.firstIndex(where: { $0.id == id }) { return IndexPath(item: item, section: section) }
        }
        return nil
    }

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
        if section.heading != nil, path.item < (section.grid ? 4 : 1),
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

    func cancelPreview() {
        preview?.cancel()
        preview = nil
    }

    func activateSelection() {
        cancelPreview()
        guard let id = selectedID, controller?.session.selectedTabID != id else { return }
        controller?.session.selectTab(id)
        // Session policy can decline a switch, for example while a prompt is open.
        if controller?.session.selectedTabID != id { select(activeID, reveal: false) }
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let list else { return }
        if list.navigatingWithKeys { settlePreview() }
        else { activateSelection() }
    }

    func settlePreview() {
        cancelPreview()
        guard let id = selectedID, id != activeID else { return }
        preview = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard let self, self.selectedID == id, let list = self.list, list.window?.firstResponder === list else { return }
            self.activateSelection()
        }
    }

    func resign() {
        cancelPreview()
        select(activeID, reveal: false)
    }

    func setHovered(_ path: IndexPath?) {
        guard hovered != path else { return }
        let previous = hovered
        hovered = path
        for index in [previous, path].compactMap({ $0 }) {
            if let item = list?.item(at: index) as? SidebarCollectionItem { configure(item, at: index) }
        }
        if let path, let tab = tab(at: path), drag == nil {
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
        item.iconOnly = grid || configuration.rail || configuration.peek
        item.command = { [weak controller = configuration.controller, weak tab] command in
            if let controller, let tab { SidebarTabs.perform(command, tab: tab, controller: controller) }
        }
        item.open = { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.select(tab.id, reveal: false)
            self.activateSelection()
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
        item.artwork = { selected in
            let content = SidebarTabArtwork(tab: tab, selected: selected, active: active,
                                            tile: grid, rail: configuration.rail || configuration.peek, peek: configuration.peek,
                                            hovered: hovered, subtitle: subtitle)
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
            header.toolTip = section.pinTarget.map { $0 ? "Drop a regular tab here to pin it" : "Drop a pinned tab here to unpin it" }
        }
        header.host.rootView = AnyView(headerArtwork(section).environment(\.self, environment))
    }

    @ViewBuilder private func headerArtwork(_ section: SidebarSection) -> some View {
        if section.separator {
            Rectangle().fill(environment.browserTheme.separator.opacity(0.7)).frame(width: 24, height: 1)
        } else if let heading = section.heading {
            if section.count > 0 { SidebarSectionHeading(title: heading, count: section.count) }
            else { Text(heading).font(OrivType.detail).foregroundStyle(environment.browserTheme.sidebarSecondaryText) }
        }
    }

    func menu(for tab: BrowserTab) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ command: SidebarTabCommand) {
            menu.addItem(SidebarMenuItem(title) { [weak self, weak tab] in
                if let controller = self?.controller, let tab { SidebarTabs.perform(command, tab: tab, controller: controller) }
            })
        }
        if !tab.isPrivate { add(tab.isPinned ? "Unpin Tab" : "Pin Tab", .pin) }
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
        guard let tab = paths.first.flatMap(tab(at:)), let controller else { return }
        cancelPreview()
        controller.sidebarTooltip.dismiss()
        drag = SidebarTabTransfer(id: tab.id, owner: controller.sidebarDragID)
        // Start after AppKit has taken its drag image from the originating cell.
        Task { [weak self] in if self?.drag != nil { self?.applyDragState(true) } }
    }

    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession,
                        endedAt screenPoint: NSPoint, dragOperation operation: NSDragOperation) {
        drag = nil
        applyDragState(false)
    }

    func dropTarget(at point: NSPoint) -> SidebarDropTarget? {
        guard let list else { return nil }
        if let path = list.indexPathForItem(at: point), let tab = tab(at: path) { return .tab(tab.id) }
        for (index, section) in sections.enumerated() {
            if let pinned = section.pinTarget,
               let header = list.layoutAttributesForSupplementaryElement(ofKind: NSCollectionView.elementKindSectionHeader,
                                                                         at: IndexPath(item: 0, section: index)),
               header.frame.contains(point) { return .pinned(pinned) }
        }
        return nil
    }

    private func validatedDrop(_ info: NSDraggingInfo) -> (SidebarTabTransfer, SidebarDropTarget)? {
        guard let list, let controller, info.draggingSource as? NSCollectionView === list,
              let data = info.draggingPasteboard.data(forType: Self.pasteboardType),
              let item = try? JSONDecoder().decode(SidebarTabTransfer.self, from: data),
              let target = dropTarget(at: list.convert(info.draggingLocation, from: nil)),
              SidebarTabs.canDrop(item, on: target, controller: controller) else { return nil }
        return (item, target)
    }

    func collectionView(_ collectionView: NSCollectionView, validateDrop info: NSDraggingInfo,
                        proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        guard let (_, target) = validatedDrop(info) else { return [] }
        switch target {
        case .tab(let id):
            guard let path = path(for: id) else { return [] }
            proposedIndexPath.pointee = path as NSIndexPath
            dropOperation.pointee = .on
        case .pinned(let pinned):
            guard let group = sections.firstIndex(where: { $0.pinTarget == pinned }) else { return [] }
            proposedIndexPath.pointee = IndexPath(item: 0, section: group) as NSIndexPath
            dropOperation.pointee = .before
        }
        return .move
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop info: NSDraggingInfo,
                        indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        guard let (item, target) = validatedDrop(info), let controller else { return false }
        return SidebarTabs.drop([item], on: target, controller: controller)
    }
}

final class SidebarTabCollection: NSCollectionView {
    weak var sidebar: SidebarCollectionData?
    private(set) var navigatingWithKeys = false
    private var keyboardNavigation = false
    private var ownsFocus = false
    var showsKeyboardFocus: Bool { ownsFocus && keyboardNavigation }
    private var pointerTracking: NSTrackingArea?

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
            case 36, 76: sidebar?.activateSelection(); return
            case 53:
                if let controller = sidebar?.controller, !controller.tabSearch.isEmpty {
                    controller.tabSearch = ""
                    sidebar?.resign()
                    return
                }
            case 115, 116, 119, 121, 123...126:
                let previous = selectionIndexPaths
                navigatingWithKeys = true
                defer { navigatingWithKeys = false }
                super.keyDown(with: event)
                if previous != selectionIndexPaths, let path = selectionIndexPaths.first { sidebar?.revealItem(at: path) }
                sidebar?.settlePreview()
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
        else { sidebar?.cancelPreview() }
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
        sidebar?.setHovered(indexPathForItem(at: convert(event.locationInWindow, from: nil)))
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

private final class SidebarArtworkHost: NSHostingView<AnyView> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func accessibilityIsIgnored() -> Bool { true }
}

private final class SidebarCollectionItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("Sidebar tab")
    private let host = SidebarArtworkHost(rootView: AnyView(EmptyView()))
    var tab: BrowserTab?
    var active = false
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

    func performClick(at point: NSPoint) -> Bool {
        guard !iconOnly, let tab else { return false }
        let rtl = collectionView?.userInterfaceLayoutDirection == .rightToLeft
        let trailing = (rtl ? point.x - view.bounds.minX : view.bounds.maxX - point.x) - MacBrowserLayout.sidebarRowInset
        guard trailing >= 0, abs(point.y - view.bounds.midY) <= 12 else { return false }
        if trailing < 24, hovered || active || isSelected { command?(.close); return true }
        if trailing < 48 {
            if tab.mediaSuspended { command?(.media); return true }
            if tab.isAudioMuted { command?(.mute); return true }
            if tab.isPlayingAudio { command?(.media); return true }
        }
        return false
    }
}

private final class SidebarAccessibleRow: NSView {
    weak var item: SidebarCollectionItem?
    var showsFocusRing = false {
        didSet {
            guard showsFocusRing != oldValue else { return }
            if showsFocusRing {
                let ring = SidebarRowFocusRing(frame: bounds)
                ring.autoresizingMask = [.width, .height]
                addSubview(ring)
            } else {
                subviews.last(where: { $0 is SidebarRowFocusRing })?.removeFromSuperview()
            }
        }
    }

    override var focusRingMaskBounds: NSRect { showsFocusRing ? bounds.insetBy(dx: 4, dy: 4) : .zero }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 8, yRadius: 8).fill()
    }

    override func accessibilityChildren() -> [Any]? { [] }
    override func accessibilityLabel() -> String? {
        guard let item, let tab = item.tab else { return nil }
        return SidebarTabs.label(tab, selected: item.active)
    }
    override func isAccessibilitySelected() -> Bool { item?.isSelected == true }
    override func accessibilityPerformPress() -> Bool { item?.open?(); return item?.tab != nil }
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard let item, let tab = item.tab else { return nil }
        var actions = [NSAccessibilityCustomAction(name: "Close Tab") { [weak item] in item?.command?(.close); return item != nil }]
        if !tab.isPrivate {
            actions.append(NSAccessibilityCustomAction(name: tab.isPinned ? "Unpin Tab" : "Pin Tab") { [weak item] in
                item?.command?(.pin); return item != nil
            })
        }
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

/// Draw the AppKit ring above the hosted artwork. The collection remains the
/// responder and owns keyboard navigation, including through recycled rows.
private final class SidebarRowFocusRing: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func accessibilityIsIgnored() -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let row = superview else { return }
        NSGraphicsContext.saveGraphicsState()
        NSFocusRingPlacement.only.set()
        NSColor.black.setFill()
        row.drawFocusRingMask()
        NSGraphicsContext.restoreGraphicsState()
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
