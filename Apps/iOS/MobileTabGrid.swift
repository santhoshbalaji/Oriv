import SwiftUI
import BrowserCore
import BrowserEngine
import UniformTypeIdentifiers
import WebKit

/// UIKit's local collection drag/drop supplies lift, cancellation and edge
/// auto-scroll. It shares no gesture recognizers with the page's WKWebView.
struct MobileTabGrid: UIViewControllerRepresentable {
    let controller: MobileController
    let profiles: MobileProfiles
    let tabs: [BrowserTab]
    let largeText: Bool
    let reduceMotion: Bool
    let open: (BrowserTab) -> Void
    let onPull: (CGFloat, Bool) -> Void
    func makeUIViewController(context: Context) -> MobileTabGridController { MobileTabGridController(model: self) }
    func updateUIViewController(_ view: MobileTabGridController, context: Context) { view.update(self) }
}

@MainActor final class MobileTabGridController: UICollectionViewController, UICollectionViewDragDelegate, UICollectionViewDropDelegate {
    var model: MobileTabGrid
    private var sections: [[BrowserTab]] = []
    private var identity: [String] = []
    private(set) var pulling = false
    private(set) var reordering = false
    private var dragGeneration = 0
    private var cancellation: MobileGestureCancellation?
    init(model: MobileTabGrid) {
        self.model = model
        super.init(collectionViewLayout: UICollectionViewFlowLayout())
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.dragInteractionEnabled = true
        collectionView.dragDelegate = self; collectionView.dropDelegate = self
        collectionView.register(MobileTabCell.self, forCellWithReuseIdentifier: "tab")
        collectionView.register(UICollectionReusableView.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: "header")
        collectionView.panGestureRecognizer.addTarget(self, action: #selector(panGrid(_:)))
        cancellation = MobileGestureCancellation { [weak self] in self?.cancelGestures() }
        update(model)
    }
    func update(_ model: MobileTabGrid) {
        self.model = model
        guard isViewLoaded else { return }
        let updated = [model.tabs.filter { !$0.isPrivate }, model.tabs.filter(\.isPrivate)].filter { !$0.isEmpty }
        let next = model.tabs.map { "\($0.id)-\($0.isPinned)-\($0.displayTitle)-\(model.controller.session.selectedTabID == $0.id)-\(model.largeText)" }
        sections = updated
        collectionView.overrideUserInterfaceStyle = model.controller.appearance.colorScheme.map { $0 == .dark ? .dark : .light } ?? .unspecified
        if identity != next { identity = next; collectionView.reloadData(); collectionView.collectionViewLayout.invalidateLayout() }
        collectionView.backgroundView = model.tabs.isEmpty ? UIHostingController(rootView: BrowserEmptyState("No matching tabs")).view : nil
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        navigationController?.view.accessibilityViewIsModal = true
        if let path = sections.enumerated().compactMap({ section, tabs in
            tabs.firstIndex { $0.id == model.controller.session.selectedTabID }.map { IndexPath(item: $0, section: section) }
        }).first {
            collectionView.scrollToItem(at: path, at: .centeredVertically, animated: false)
            UIAccessibility.post(notification: .screenChanged, argument: collectionView.cellForItem(at: path))
        } else { UIAccessibility.post(notification: .screenChanged, argument: collectionView) }
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.view.accessibilityViewIsModal = false
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let layout = collectionViewLayout as? UICollectionViewFlowLayout else { return }
        let columns: CGFloat = model.largeText ? 1 : 2
        let width = floor((collectionView.bounds.width - 32 - (columns - 1) * 16) / columns)
        let caption = UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: traitCollection).lineHeight
        let size = CGSize(width: max(100, width), height: model.largeText ? max(310, 220 + caption * 3 + 8) : width * 1.42 + 26)
        if layout.itemSize != size {
            layout.itemSize = size; layout.sectionInset = UIEdgeInsets(top: 12, left: 16, bottom: 20, right: 16)
            layout.minimumInteritemSpacing = 16; layout.minimumLineSpacing = 16
            layout.headerReferenceSize = CGSize(width: collectionView.bounds.width, height: sections.count > 1 ? max(36, UIFont.preferredFont(forTextStyle: .headline, compatibleWith: traitCollection).lineHeight + 12) : 0)
            layout.invalidateLayout()
        }
    }
    override func numberOfSections(in collectionView: UICollectionView) -> Int { sections.count }
    override func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { sections[section].count }
    override func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "tab", for: indexPath) as! MobileTabCell
        let tab = sections[indexPath.section][indexPath.item]
        let controller = model.controller
        cell.contentConfiguration = UIHostingConfiguration {
            MobileGridCard(tab: tab, selected: controller.session.selectedTabID == tab.id, largeText: model.largeText, close: { controller.close([tab.id]) })
                .browserAppearance(controller.appearance)
        }.margins(.all, 0)
        cell.reduceMotion = model.reduceMotion
        cell.close = { controller.close([tab.id]) }
        cell.open = { [weak self] in self?.model.open(tab) }
        cell.isAccessibilityElement = true
        cell.accessibilityLabel = "\(tab.isPinned ? "Pinned. " : "")\(tab.isPrivate ? "Private. " : "")\(tab.displayTitle)"
        cell.accessibilityTraits = controller.session.selectedTabID == tab.id ? [.button, .selected] : [.button]
        cell.accessibilityHint = "Double tap to open. Actions include Close Tab and Move Earlier or Later."
        cell.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Duplicate Tab") { _ in controller.session.duplicateTab(tab.id); return true },
            UIAccessibilityCustomAction(name: "Copy Link") { _ in if let url = tab.url { UIPasteboard.general.url = url }; return true },
            UIAccessibilityCustomAction(name: "Close Other Tabs") { _ in controller.closeOtherTabs(tab); return true },
            UIAccessibilityCustomAction(name: "Close Tab") { _ in controller.close([tab.id]); return true },
            UIAccessibilityCustomAction(name: "Move Earlier") { _ in controller.session.moveTab(tab.id, offset: -1); return true },
            UIAccessibilityCustomAction(name: "Move Later") { _ in controller.session.moveTab(tab.id, offset: 1); return true },
            UIAccessibilityCustomAction(name: tab.isPinned ? "Unpin Tab" : "Pin Tab") { _ in controller.session.togglePinned(tab.id); return true }
        ]
        return cell
    }
    override func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> UICollectionReusableView {
        let view = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: "header", for: indexPath)
        view.subviews.forEach { $0.removeFromSuperview() }
        let label = UILabel(frame: view.bounds.insetBy(dx: 16, dy: 0)); label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        label.text = sections[indexPath.section].first?.isPrivate == true ? "Private" : "Tabs"
        label.font = .preferredFont(forTextStyle: .headline); label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel; label.accessibilityTraits = .header
        view.addSubview(label); return view
    }
    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) { model.open(sections[indexPath.section][indexPath.item]) }
    override func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        let tab = sections[indexPath.section][indexPath.item], controller = model.controller, profiles = model.profiles
        func action(_ title: String, _ image: String, destructive: Bool = false, _ operation: @escaping () -> Void) -> UIAction {
            UIAction(title: title, image: UIImage(systemName: image), attributes: destructive ? .destructive : []) { _ in operation() }
        }
        let configuration = UIContextMenuConfiguration(actionProvider: { _ in
            var items: [UIMenuElement] = [
                UIAction(title: "Copy Link", image: UIImage(systemName: "doc.on.doc"), attributes: tab.url == nil ? .disabled : []) { _ in if let url = tab.url { UIPasteboard.general.url = url } },
                action(tab.isPinned ? "Unpin Tab" : "Pin Tab", "pin") { controller.session.togglePinned(tab.id) },
                action("Duplicate", "plus.square.on.square") { controller.session.duplicateTab(tab.id) },
                action("Move Earlier", "arrow.up") { controller.session.moveTab(tab.id, offset: -1) },
                action("Move Later", "arrow.down") { controller.session.moveTab(tab.id, offset: 1) }
            ]
            items = [UIMenu(options: .displayInline, children: [items.removeFirst()]), UIMenu(options: .displayInline, children: items)]
            var destinationsGroup: [UIMenuElement] = []
            destinationsGroup.append(UIMenu(title: "Move to Profile", image: UIImage(systemName: "person.crop.circle"), children: profiles.profiles.filter { $0.archivedAt == nil && $0.id != controller.profileID }.map { profile in
                UIAction(title: profile.name, attributes: tab.url == nil ? .disabled : []) { _ in controller.move(tab, to: profile) }
            }))
            let page = profiles.profiles.first { $0.id == controller.profileID }.flatMap { ContinuityPage(url: tab.url, title: tab.title, profile: $0, isPrivate: tab.isPrivate) }
            let destinations: [UIMenuElement] = profiles.continuity.otherDevices.map { device in
                UIAction(title: device.name, attributes: page == nil || !profiles.continuity.canSendPage ? .disabled : []) { _ in if let page { profiles.continuity.sendPage(page, to: device.id) } }
            }
            destinationsGroup.append(UIMenu(title: "Open on Mac", image: UIImage(systemName: "paperplane"), children: destinations.isEmpty ? [UIAction(title: "Set Up Mac & iPhone in Settings", attributes: .disabled) { _ in }] : destinations))
            items.append(UIMenu(options: .displayInline, children: destinationsGroup))
            items.append(UIMenu(options: .displayInline, children: [
                action("Close", "xmark", destructive: true) { controller.close([tab.id]) },
                action("Close Other Tabs", "xmark.square", destructive: true) { controller.closeOtherTabs(tab) }
            ]))
            return UIMenu(children: items)
        })
        configuration.preferredMenuElementOrder = .fixed
        return configuration
    }
    func collectionView(_ collectionView: UICollectionView, itemsForBeginning session: any UIDragSession, at indexPath: IndexPath) -> [UIDragItem] {
        let tab = sections[indexPath.section][indexPath.item]
        let item = UIDragItem(itemProvider: NSItemProvider(object: tab.id.uuidString as NSString)); item.localObject = tab.id
        reordering = true
        session.localContext = dragGeneration
        return [item]
    }
    func collectionView(_ collectionView: UICollectionView, dragSessionDidEnd session: any UIDragSession) { reordering = false }
    func collectionView(_ collectionView: UICollectionView, dragSessionIsRestrictedToDraggingApplication session: any UIDragSession) -> Bool { true }
    func collectionView(_ collectionView: UICollectionView, dropSessionDidUpdate session: any UIDropSession, withDestinationIndexPath destination: IndexPath?) -> UICollectionViewDropProposal {
        guard reordering, session.localDragSession?.localContext as? Int == dragGeneration, let id = session.items.first?.localObject as? UUID,
              let destination, sections.indices.contains(destination.section), sections[destination.section].indices.contains(destination.item),
              let source = model.controller.session.tabs.first(where: { $0.id == id }) else { return UICollectionViewDropProposal(operation: .forbidden) }
        let target = sections[destination.section][destination.item]
        return UICollectionViewDropProposal(operation: source.isPrivate == target.isPrivate && source.isPinned == target.isPinned ? .move : .forbidden, intent: .insertAtDestinationIndexPath)
    }
    func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: any UICollectionViewDropCoordinator) {
        guard reordering, let item = coordinator.items.first, let id = item.dragItem.localObject as? UUID,
              let destination = coordinator.destinationIndexPath, sections.indices.contains(destination.section), sections[destination.section].indices.contains(destination.item) else { return }
        model.controller.session.moveTab(id, to: sections[destination.section][destination.item].id)
        update(model)
        coordinator.drop(item.dragItem, toItemAt: destination)
        reordering = false
    }
    func cancelGestures() {
        pulling = false; reordering = false; dragGeneration += 1
        collectionView.cancelInteractiveMovement()
        collectionView.dragInteractionEnabled = false
        collectionView.dragInteractionEnabled = true
        collectionView.panGestureRecognizer.isEnabled = false
        collectionView.panGestureRecognizer.isEnabled = true
        for case let cell as MobileTabCell in collectionView.visibleCells { cell.cancelGestures() }
        model.onPull(0, true)
    }
    @objc func panGrid(_ gesture: UIPanGestureRecognizer) {
        guard cancellation?.suspended != true else { pulling = false; return }
        let translation = gesture.translation(in: collectionView)
        switch gesture.state {
        case .began:
            pulling = !reordering && collectionView.contentOffset.y <= -collectionView.adjustedContentInset.top + 2 && gesture.velocity(in: collectionView).y > abs(gesture.velocity(in: collectionView).x)
        case .changed:
            if pulling && !reordering { model.onPull(max(0, translation.y) / max(collectionView.bounds.height, 1), false) }
        case .ended, .cancelled:
            if pulling { model.onPull(gesture.state == .cancelled ? 0 : max(0, translation.y) / max(collectionView.bounds.height, 1), true) }
            pulling = false
        default: break
        }
    }
}

@MainActor final class MobileTabCell: UICollectionViewCell, UIGestureRecognizerDelegate {
    var close: (() -> Void)?
    var open: (() -> Void)?
    var reduceMotion = false
    private(set) var swiping = false
    private(set) var pinching = false
    private var cancellation: MobileGestureCancellation?
    override init(frame: CGRect) {
        super.init(frame: frame)
        let swipe = UIPanGestureRecognizer(target: self, action: #selector(swipe(_:))); swipe.maximumNumberOfTouches = 1; swipe.delegate = self
        addGestureRecognizer(swipe)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:))); pinch.delegate = self; addGestureRecognizer(pinch)
        cancellation = MobileGestureCancellation { [weak self] in self?.cancelGestures() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func prepareForReuse() { super.prepareForReuse(); cancelGestures(); close = nil; open = nil }
    func cancelGestures() {
        swiping = false; pinching = false
        for gesture in gestureRecognizers ?? [] { gesture.isEnabled = false; gesture.isEnabled = true }
        contentView.layer.removeAllAnimations()
        contentView.transform = .identity; contentView.alpha = 1
    }
    override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        if let pan = gesture as? UIPanGestureRecognizer { let v = pan.velocity(in: self); return v.x < -abs(v.y) * 1.4 }
        if let pinch = gesture as? UIPinchGestureRecognizer { return pinch.scale > 1 }
        return true
    }
    @objc func swipe(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began { swiping = cancellation?.suspended != true }
        let x = min(gesture.translation(in: self).x, 0)
        if gesture.state == .changed && swiping {
            if !reduceMotion { contentView.transform = CGAffineTransform(translationX: x, y: 0) }
            contentView.alpha = max(0.35, 1 + x / max(bounds.width, 1))
        } else if gesture.state == .ended || gesture.state == .cancelled {
            if gesture.state == .ended && swiping && x < -max(60, bounds.width * 0.35) { close?() }
            swiping = false
            UIView.animate(withDuration: reduceMotion ? 0.15 : 0.25) { self.contentView.transform = .identity; self.contentView.alpha = 1 }
        }
    }
    @objc func pinch(_ gesture: UIPinchGestureRecognizer) {
        if gesture.state == .began { pinching = cancellation?.suspended != true }
        if gesture.state == .changed && pinching {
            if !reduceMotion { contentView.transform = CGAffineTransform(scaleX: min(1.12, gesture.scale), y: min(1.12, gesture.scale)) }
            else { contentView.alpha = max(0.6, 2 - gesture.scale) }
        } else if gesture.state == .ended || gesture.state == .cancelled {
            if gesture.state == .ended && pinching && gesture.scale > 1.2 { open?() }
            pinching = false
            UIView.animate(withDuration: 0.2) { self.contentView.transform = .identity; self.contentView.alpha = 1 }
        }
    }
    override func accessibilityActivate() -> Bool { open?(); return true }
}

private struct MobileGridCard: View {
    @Environment(\.browserTheme) private var theme
    let tab: BrowserTab
    let selected: Bool
    let largeText: Bool
    let close: () -> Void
    var body: some View {
        VStack(spacing: 8) {
            MobileTabThumbnail(tab: tab)
                .clipShape(.rect(cornerRadius: 18))
                .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(selected ? theme.accent : theme.separator, lineWidth: selected ? 2 : 1) }
                .overlay(alignment: .topTrailing) {
                    Button(action: close) {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary).frame(width: 22, height: 22)
                            .background(.regularMaterial, in: Circle()).frame(width: 44, height: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("Close \(tab.displayTitle)")
                }
            Label(tab.displayTitle, systemImage: tab.isPinned ? "pin.fill" : tab.isPrivate ? "eyeglasses" : "globe")
                .font(.footnote.weight(.medium)).foregroundStyle(tab.isPrivate ? theme.privateAccent : theme.text)
                .lineLimit(largeText ? 3 : 1).frame(maxWidth: .infinity)
        }
    }
}
