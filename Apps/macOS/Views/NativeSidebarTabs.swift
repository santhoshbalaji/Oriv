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
    let handle: SidebarListHandle
    let tabs: [BrowserTab]
    let rail: Bool
    let peek: Bool
    let searching: Bool
    let confirmClose: (UUID, Bool) -> Void

    func makeCoordinator() -> SidebarCollectionData { SidebarCollectionData() }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = SidebarTabLayout()
        let list = SidebarTabCollection()
        list.collectionViewLayout = layout
        list.dataSource = context.coordinator
        list.delegate = context.coordinator
        list.sidebar = context.coordinator
        list.isSelectable = true
        list.allowsEmptySelection = false
        list.backgroundColors = [.clear]
        list.focusRingType = .default
        list.setAccessibilityLabel("Sidebar tabs")
        list.setAccessibilityIdentifier("sidebarTabs")
        list.register(SidebarCollectionItem.self, forItemWithIdentifier: SidebarCollectionItem.identifier)
        list.register(SidebarCollectionHeader.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                      withIdentifier: SidebarCollectionHeader.identifier)
        list.registerForDraggedTypes([SidebarCollectionData.pasteboardType])
        list.setDraggingSourceOperationMask(.move, forLocal: true)
        list.setDraggingSourceOperationMask([], forLocal: false)

        let scroll = SidebarTabScrollView()
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

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let list = context.coordinator.list else { return }
        // Legacy scrollbars reserve space even when idle. In the rail,
        // wheel/trackpad and keyboard scrolling use the entire 56 pt viewport.
        let iconLayout = rail || peek
        scroll.scrollerStyle = iconLayout ? .overlay : NSScroller.preferredScrollerStyle
        scroll.hasVerticalScroller = !iconLayout
        handle.collection = list
        context.coordinator.update(self, environment: context.environment)
        scroll.tile()
    }

    static func dismantleNSView(_ view: NSScrollView, coordinator: SidebarCollectionData) {
        coordinator.cancelPreview()
    }
}

private final class SidebarTabLayout: NSCollectionViewFlowLayout {
    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        newBounds.width != collectionView?.bounds.width || super.shouldInvalidateLayout(forBoundsChange: newBounds)
    }
}

private final class SidebarTabClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var bounds = super.constrainBoundsRect(proposedBounds)
        bounds.origin.x = 0
        return bounds
    }
}

private final class SidebarTabScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard let list = documentView as? SidebarTabCollection else { return }
        let width = contentView.bounds.width
        if width > 0, list.frame.width != width {
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

@MainActor final class SidebarCollectionData: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
    static let pasteboardType = NSPasteboard.PasteboardType("com.oriv.browser.sidebar-tab")

    weak var list: SidebarTabCollection?
    private var configuration: NativeSidebarTabs?
    private var sections: [SidebarSection] = []
    private var environment = EnvironmentValues()
    private var activeID: UUID?
    private var preview: Task<Void, Never>?
    private(set) var hovered: IndexPath?
    private var drag: SidebarTabTransfer?
    var controller: BrowserController? { configuration?.controller }

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
        let oldShown = selectedID
        let newSections = makeSections(value)
        let changesContent = sections.map(\.kind) != newSections.map(\.kind) ||
            sections.map { $0.tabs.map(\.id) } != newSections.map { $0.tabs.map(\.id) }
        let newActive = value.controller.session.selectedTabID
        let changesActive = activeID != newActive
        configuration = value
        self.environment = environment
        sections = newSections
        activeID = newActive

        if changesLayout && old != nil {
            list.collectionViewLayout = SidebarTabLayout()
        }
        if changesLayout || changesContent {
            setHovered(nil)
            list.reloadData()
        }
        if changesLayout || changesContent || oldSize != environment.dynamicTypeSize {
            list.collectionViewLayout?.invalidateLayout()
        }
        if changesLayout || changesActive {
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
        if let path, reveal {
            list.layoutSubtreeIfNeeded()
            if let frame = list.layoutAttributesForItem(at: path)?.frame { list.scrollToVisible(frame) }
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
        item.artwork = { selected in
            let content = SidebarTabArtwork(tab: tab, selected: selected, active: active,
                                            tile: grid, rail: configuration.rail || configuration.peek, peek: configuration.peek,
                                            hovered: hovered)
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
            Rectangle().fill(Theme.sidebar.separator.opacity(0.7)).frame(width: 24, height: 1)
        } else if let heading = section.heading {
            if section.count > 0 { SidebarSectionHeading(title: heading, count: section.count) }
            else { Text(heading).font(OrivType.detail).foregroundStyle(Theme.sidebar.secondaryText) }
        }
    }

    func collectionView(_ collectionView: NSCollectionView, layout: NSCollectionViewLayout, sizeForItemAt path: IndexPath) -> NSSize {
        if sections[path.section].grid { return NSSize(width: min(56, collectionView.bounds.width), height: 48) }
        let icons = configuration?.rail == true || configuration?.peek == true
        let viewport = collectionView.enclosingScrollView?.contentView.bounds.width ?? collectionView.bounds.width
        let available = min(viewport, collectionView.bounds.width) - (icons ? 2 * MacBrowserLayout.railInset : 0)
        let width = configuration?.rail == true ? min(MacBrowserLayout.railItemWidth, available) : available
        return NSSize(width: max(0, width), height: icons || !environment.dynamicTypeSize.isAccessibilitySize ? 36 : 60)
    }

    func collectionView(_ collectionView: NSCollectionView, layout: NSCollectionViewLayout,
                        referenceSizeForHeaderInSection section: Int) -> NSSize {
        NSSize(width: collectionView.bounds.width, height: sections[section].headerHeight)
    }

    func collectionView(_ collectionView: NSCollectionView, layout: NSCollectionViewLayout, insetForSectionAt section: Int) -> NSEdgeInsets {
        if sections[section].grid {
            let edges = max(0, (collectionView.bounds.width - 248) / 2)
            return NSEdgeInsets(top: 4, left: edges, bottom: 5, right: edges)
        }
        let icons = configuration?.rail == true || configuration?.peek == true
        let inset = icons ? min(MacBrowserLayout.railInset, collectionView.bounds.width / 2) : 0
        let right = configuration?.rail == true
            ? max(inset, collectionView.bounds.width - inset - MacBrowserLayout.railItemWidth)
            : inset
        return NSEdgeInsets(top: 0, left: inset, bottom: icons ? 0 : 1, right: right)
    }

    func collectionView(_ collectionView: NSCollectionView, layout: NSCollectionViewLayout,
                        minimumLineSpacingForSectionAt section: Int) -> CGFloat {
        if sections[section].grid { return 9 }
        return configuration?.rail == true || configuration?.peek == true ? 6 : 1
    }

    func collectionView(_ collectionView: NSCollectionView, layout: NSCollectionViewLayout,
                        minimumInteritemSpacingForSectionAt section: Int) -> CGFloat { 8 }

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
        if tab.url != nil { add(tab.mediaSuspended ? "Resume Media Playback" : "Pause and Block Media Playback", .media) }
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

    private func publishFocus(_ focused: Bool) { sidebar?.setFocus(focused) }

    func focusTab(_ id: UUID?) {
        guard let window, window.makeFirstResponder(self) else { return }
        sidebar?.focus(id)
    }

    override func keyDown(with event: NSEvent) {
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
                navigatingWithKeys = true
                defer { navigatingWithKeys = false }
                super.keyDown(with: event)
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

    override var focusRingMaskBounds: NSRect {
        guard let frame = selectionIndexPaths.first.flatMap({ layoutAttributesForItem(at: $0)?.frame }) else { return .zero }
        return frame.intersection(visibleRect).insetBy(dx: 2, dy: 2)
    }

    override func drawFocusRingMask() {
        let rect = focusRingMaskBounds
        guard !rect.isEmpty else { return }
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
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
                collectionView?.noteFocusRingMaskChanged()
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
    }

    func performClick(at point: NSPoint) -> Bool {
        guard !iconOnly, let tab else { return false }
        let trailing = view.bounds.maxX - point.x - MacBrowserLayout.sidebarRowInset
        guard trailing >= 0, abs(point.y - view.bounds.midY) <= 12 else { return false }
        if trailing < 24, hovered || active || isSelected { command?(.close); return true }
        if trailing < 48, tab.isPlayingAudio || tab.mediaSuspended { command?(.media); return true }
        return false
    }
}

private final class SidebarAccessibleRow: NSView {
    weak var item: SidebarCollectionItem?
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
        if tab.isPlayingAudio || tab.mediaSuspended {
            actions.append(NSAccessibilityCustomAction(name: tab.mediaSuspended ? "Resume Media Playback" : "Pause Media Playback") { [weak item] in
                item?.command?(.media); return item != nil
            })
        }
        return actions
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
