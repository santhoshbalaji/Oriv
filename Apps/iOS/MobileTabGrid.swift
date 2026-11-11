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
    var onPinch: ((BrowserTab, CGFloat, Bool) -> Void)? = nil
    var presented = true
    var visible = true
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
        super.init(collectionViewLayout: MobileTabGridLayout())
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
        let wasPresented = self.model.presented
        self.model = model
        guard isViewLoaded else { return }
        let updated = [model.tabs.filter { !$0.isPrivate }, model.tabs.filter(\.isPrivate)].filter { !$0.isEmpty }
        let next = model.tabs.map { "\($0.id)-\($0.isPinned)-\($0.displayTitle)-\(model.controller.session.selectedTabID == $0.id)-\(model.largeText)" }
        let previous = sections
        sections = updated
        (collectionViewLayout as? MobileTabGridLayout)?.reduceMotion = model.reduceMotion
        collectionView.overrideUserInterfaceStyle = model.controller.appearance.colorScheme.map { $0 == .dark ? .dark : .light } ?? .unspecified
        if identity != next {
            identity = next
            let oldIDs = previous.flatMap { $0.map(\.id) }, newIDs = updated.flatMap { $0.map(\.id) }
            let deletions = previous.enumerated().flatMap { section, tabs in
                tabs.enumerated().compactMap { item, tab in newIDs.contains(tab.id) ? nil : IndexPath(item:item, section:section) }
            }
            let onlyDeletes = previous.count == updated.count && !deletions.isEmpty && newIDs == oldIDs.filter { newIDs.contains($0) }
            if onlyDeletes {
                collectionView.performBatchUpdates { collectionView.deleteItems(at: deletions) } completion: { [weak self] _ in
                    self?.publishFrames()
                }
            } else if oldIDs == newIDs {
                collectionView.reconfigureItems(at: collectionView.indexPathsForVisibleItems)
            } else {
                UIView.transition(with:collectionView, duration:model.reduceMotion ? 0.18 : 0.25, options:.transitionCrossDissolve) { self.collectionView.reloadData() }
            }
            collectionView.collectionViewLayout.invalidateLayout()
        }
        collectionView.backgroundView = model.tabs.isEmpty ? UIHostingController(rootView: BrowserEmptyState("No matching tabs")).view : nil
        navigationController?.view.accessibilityViewIsModal = model.presented
        view.isHidden = !model.visible
        view.accessibilityElementsHidden = !model.presented
        navigationController?.view.isHidden = !model.visible
        navigationController?.view.accessibilityElementsHidden = !model.presented
        if model.presented && !wasPresented { revealSelected(announce:true) }
    }
    private func revealSelected(announce:Bool) {
        collectionView.layoutIfNeeded()
        if let path = sections.enumerated().compactMap({ section, tabs in
            tabs.firstIndex { $0.id == model.controller.session.selectedTabID }.map { IndexPath(item:$0,section:section) }
        }).first {
            collectionView.scrollToItem(at:path,at:.centeredVertically,animated:false)
            publishFrames()
            if announce { UIAccessibility.post(notification:.screenChanged,argument:collectionView.cellForItem(at:path)) }
        } else if announce { UIAccessibility.post(notification:.screenChanged,argument:collectionView) }
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        navigationController?.view.accessibilityViewIsModal = model.presented
        view.isHidden = !model.visible
        view.accessibilityElementsHidden = !model.presented
        navigationController?.view.isHidden = !model.visible
        navigationController?.view.accessibilityElementsHidden = !model.presented
        revealSelected(announce:model.presented)
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.view.accessibilityViewIsModal = false
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        publishFrames()
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
    private func publishFrames() {
        guard collectionView.window != nil else { return }
        let presentation = model.controller.tabPresentation
        var paths = Set(collectionView.indexPathsForVisibleItems)
        for (section,tabs) in sections.enumerated() {
            if let item = tabs.firstIndex(where: { $0.id == model.controller.session.selectedTabID }) { paths.insert(IndexPath(item:item,section:section)) }
        }
        for path in paths {
            guard sections.indices.contains(path.section), sections[path.section].indices.contains(path.item),
                  let attributes = collectionView.collectionViewLayout.layoutAttributesForItem(at:path) else { continue }
            let id = sections[path.section][path.item].id
            var rect = collectionView.convert(attributes.frame,to:nil)
            rect.size.height = max(1, rect.height - (model.largeText ? 80 : 26))
            if presentation.cardFrames[id] != rect { presentation.cardFrames[id] = rect }
        }
    }
    override func scrollViewDidScroll(_ scrollView: UIScrollView) { publishFrames() }

    override func numberOfSections(in collectionView: UICollectionView) -> Int { sections.count }
    override func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { sections[section].count }
    override func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "tab", for: indexPath) as! MobileTabCell
        let tab = sections[indexPath.section][indexPath.item]
        let controller = model.controller
        cell.contentConfiguration = UIHostingConfiguration {
            MobileGridCard(tab: tab, presentation: controller.tabPresentation, selected: controller.session.selectedTabID == tab.id, largeText: model.largeText, close: { controller.close([tab.id]) })
                .browserAppearance(controller.appearance)
        }.margins(.all, 0)
        cell.reduceMotion = model.reduceMotion
        cell.close = { controller.close([tab.id]) }
        cell.closeSwipe = { [weak cell] velocity in
            if tab.isPrivate { cell?.restore() }
            controller.close([tab.id], animation: { [weak cell] finish in
                guard let cell else { finish(); return }
                cell.flyAway(velocity:velocity, completion:finish)
            }, cancelled: { [weak cell] in cell?.restore() })
        }
        cell.pinchProgress = model.onPinch.map { action in { amount, ended in action(tab, amount, ended) } }
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
    var closeSwipe: ((CGFloat) -> Void)?
    var pinchProgress: ((CGFloat, Bool) -> Void)?
    private var animationGeneration = 0
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
    override func prepareForReuse() { super.prepareForReuse(); cancelGestures(); close = nil; open = nil; closeSwipe = nil; pinchProgress = nil }
    func cancelGestures() {
        animationGeneration += 1
        if pinching { pinchProgress?(0, true) }
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
    static func swipeCommits(distance: CGFloat, velocity: CGFloat, width: CGFloat) -> Bool {
        distance < -max(60, width * 0.35) || (distance < -20 && velocity < -650 && distance + velocity * 0.18 < -width * 0.5)
    }
    @objc func swipe(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began { swiping = cancellation?.suspended != true }
        let distance = gesture.translation(in:self).x, width = max(bounds.width, 1)
        if gesture.state == .changed && swiping {
            // Follow the finger; resist backwards motion and over-travel.
            let x = distance > 0 ? distance * 0.18 : distance < -width ? -width - sqrt(-distance-width)*4 : distance
            if !reduceMotion { contentView.transform = CGAffineTransform(translationX:x, y:0) }
            contentView.alpha = max(0.2, 1 - abs(x) / width * 0.65)
        } else if gesture.state == .ended || gesture.state == .cancelled {
            let commit = gesture.state == .ended && swiping && Self.swipeCommits(distance:distance, velocity:gesture.velocity(in:self).x, width:width)
            swiping = false
            if commit { if let closeSwipe { closeSwipe(gesture.velocity(in:self).x) } else { close?(); restore() } }
            else { restore() }
        }
    }
    func restore() {
        UIView.animate(withDuration:reduceMotion ? 0.18 : 0.38, delay:0, usingSpringWithDamping:0.8, initialSpringVelocity:0,
                       options:[.beginFromCurrentState,.allowUserInteraction]) {
            self.contentView.transform = .identity; self.contentView.alpha = 1
        }
    }
    func flyAway(velocity: CGFloat, completion: @escaping () -> Void) {
        animationGeneration += 1
        let request = animationGeneration
        let remaining = max(1, bounds.width + contentView.transform.tx)
        let duration = reduceMotion ? 0.18 : min(0.3, max(0.12, remaining / max(800, -velocity)))
        UIView.animate(withDuration:duration, delay:0, options:[.beginFromCurrentState,.curveEaseIn]) {
            if !self.reduceMotion { self.contentView.transform = CGAffineTransform(translationX:-self.bounds.width*1.35, y:0) }
            self.contentView.alpha = 0
        } completion: { [weak self] _ in
            guard let self, request == self.animationGeneration, self.cancellation?.suspended != true else { return }
            completion()
        }
    }
    @objc func pinch(_ gesture: UIPinchGestureRecognizer) {
        if gesture.state == .began { pinching = cancellation?.suspended != true }
        if gesture.state == .changed && pinching {
            if let pinchProgress { pinchProgress(min(1,max(0,(gesture.scale-1)/0.8)),false) }
            else if !reduceMotion { contentView.transform = CGAffineTransform(scaleX:min(1.12,gesture.scale), y:min(1.12,gesture.scale)) }
            else { contentView.alpha = max(0.6,2-gesture.scale) }
        } else if gesture.state == .ended || gesture.state == .cancelled {
            let valid = gesture.state == .ended && pinching
            if let pinchProgress, pinching { pinchProgress(valid ? min(1,max(0,(gesture.scale-1)/0.8)) : 0,true) }
            else if valid && gesture.scale > 1.2 { open?() }
            pinching = false; restore()
        }
    }
    override func accessibilityActivate() -> Bool { open?(); return true }
}

private struct MobileGridCard: View {
    @Environment(\.browserTheme) private var theme
    let tab: BrowserTab
    let presentation: MobileTabPresentation
    let selected: Bool
    let largeText: Bool
    let close: () -> Void
    var body: some View {
        VStack(spacing: 8) {
            MobileTabThumbnail(tab: tab, presentation: presentation)
                .opacity(presentation.activeID == tab.id ? 0 : 1)
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

/// Window/profile-local, memory-only snapshots. One capture per document/gesture,
/// never per animation frame. Closing a private tab releases its image immediately.
@MainActor @Observable final class MobileTabPresentation {
    private(set) var images: [UUID: UIImage] = [:]
    private var revisions: [UUID: Int] = [:]
    private var captures: [UUID: Task<Void, Never>] = [:]
    var cardFrames: [UUID: CGRect] = [:]
    var activeID: UUID?
    @ObservationIgnored private var refreshTask: Task<Void,Never>?
    var pendingSelection: UUID?
    var pendingNewTab: Bool?
    var inserting = false
    var insertionProgress: CGFloat = 0
    private var generation = 0
    private var settlementRevision = 0
    private var suspended = false
    var cacheRevision: Int { generation }
    func resume() { if suspended { suspended = false; generation += 1 } }

    func capture(_ tab: BrowserTab, refresh: Bool = false) {
        guard !suspended, captures[tab.id] == nil, tab.hasLoaded, tab.isInstantiated,
              refresh || revisions[tab.id] != tab.documentRevision || images[tab.id] == nil else { return }
        let revision = tab.documentRevision, request = generation
        let config = WKSnapshotConfiguration(); config.snapshotWidth = 440
        #if DEBUG
        MobileTransitionMetrics.snapshotCount += 1
        #endif
        captures[tab.id] = Task { @MainActor [weak self, weak tab] in
            guard let tab, !Task.isCancelled, tab.isInstantiated else { return }
            let image = try? await tab.webView.takeSnapshot(configuration: config)
            guard let self, request == self.generation else { return }
            self.captures[tab.id] = nil
            guard !Task.isCancelled, tab.documentRevision == revision else { return }
            if let image {
                if self.images.count >= 12, let oldest = self.images.keys.first(where: { $0 != self.activeID && $0 != tab.id }) { self.images[oldest] = nil; self.revisions[oldest] = nil }
                self.images[tab.id] = image; self.revisions[tab.id] = revision
            }
        }
    }
    func refreshAfterScrolling(_ tab:BrowserTab) {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self,weak tab] in
            try? await Task.sleep(for:.milliseconds(250))
            guard !Task.isCancelled, let self, let tab, self.activeID == nil, !self.suspended else { return }
            self.capture(tab,refresh:true)
        }
    }
    func begin(_ tab: BrowserTab?) {
        guard !suspended, let tab else { return }
        settlementRevision += 1
        #if DEBUG
        MobileTransitionMetrics.start("page-grid")
        #endif
        if activeID != tab.id {
            refreshTask?.cancel(); activeID = tab.id
            // The selected WKWebView's existing layer is transformed live.
            // Other cards use their already-rendered thumbnail; no capture here.
        }
    }
    func settleInGrid(_ tab:BrowserTab?) {
        #if DEBUG
        MobileTransitionMetrics.stop()
        #endif
        guard let tab, activeID == tab.id, tab.isInstantiated else { finish(); return }
        let request = generation, revision = tab.documentRevision, settlement = settlementRevision
        Task { @MainActor [weak self,weak tab] in
            guard let tab, tab.isInstantiated else { return }
            let config = WKSnapshotConfiguration(); config.snapshotWidth = 440
            let image = try? await tab.webView.takeSnapshot(configuration:config)
            guard let self, !self.suspended, request == self.generation, tab.isInstantiated, tab.documentRevision == revision else { return }
            if let image { self.images[tab.id] = image; self.revisions[tab.id] = revision }
            if self.activeID == tab.id && settlement == self.settlementRevision { self.finish() }
        }
    }
    func beginNewTab() {
        #if DEBUG
        MobileTransitionMetrics.start("new-tab")
        #endif
        activeID = UUID()
    }
    func finish() {
        settlementRevision += 1; activeID = nil; pendingSelection = nil; pendingNewTab = nil
        #if DEBUG
        MobileTransitionMetrics.stop()
        #endif
    }
    func remove(_ id: UUID) {
        captures.removeValue(forKey: id)?.cancel()
        images[id] = nil; revisions[id] = nil; cardFrames[id] = nil
        if activeID == id { finish() }
    }
    func discard() {
        refreshTask?.cancel()
        suspended = true; generation += 1; captures.values.forEach { $0.cancel() }; captures.removeAll()
        images.removeAll(); revisions.removeAll(); cardFrames.removeAll(); finish()
    }
}

/// Collection updates collapse the removed card while UIKit reflows survivors.
@MainActor private final class MobileTabGridLayout: UICollectionViewFlowLayout {
    var reduceMotion = false
    override func finalLayoutAttributesForDisappearingItem(at itemIndexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard let attributes = super.finalLayoutAttributesForDisappearingItem(at:itemIndexPath)?.copy() as? UICollectionViewLayoutAttributes else { return nil }
        attributes.alpha = 0
        attributes.transform = reduceMotion ? .identity : CGAffineTransform(scaleX:0.01,y:0.01)
        return attributes
    }
}

#if DEBUG
/// Main-thread display-link intervals, buffered in memory during an opt-in run.
/// This measures scheduling on the Simulator, not physical ProMotion rendering.
@MainActor final class MobileTransitionMetrics: NSObject {
    static var snapshotCount = 0
    private static let shared = MobileTransitionMetrics()
    private var link: CADisplayLink?
    private var frames: [Double] = []
    private var samples: [[String: Any]] = []
    private var name = ""
    private var snapshotsAtStart = 0
    static func start(_ name: String) {
        guard ProcessInfo.processInfo.arguments.contains("--oriv-transition-metrics"), shared.link == nil else { return }
        shared.name = name; shared.frames = []; shared.snapshotsAtStart = snapshotCount
        let link = CADisplayLink(target:shared,selector:#selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum:60,maximum:120,preferred:120)
        shared.link = link; link.add(to:.main,forMode:.common)
    }
    @objc private func tick(_ link: CADisplayLink) { frames.append(link.timestamp) }
    static func stop() {
        guard shared.link != nil else { return }
        shared.link?.invalidate(); shared.link = nil
        let deltas = zip(shared.frames,shared.frames.dropFirst()).map { ($1-$0)*1000 }
        shared.samples.append(["gesture":shared.name,"frameIntervalsMs":deltas,"snapshots":snapshotCount-shared.snapshotsAtStart])
        if let data = try? JSONSerialization.data(withJSONObject:shared.samples,options:[.sortedKeys]) {
            try? data.write(to:FileManager.default.temporaryDirectory.appendingPathComponent("oriv-transition-metrics.json"),options:.atomic)
        }
    }
}
#endif
