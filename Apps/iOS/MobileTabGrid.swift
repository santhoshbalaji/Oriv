import SwiftUI
import BrowserCore
import BrowserEngine
import UniformTypeIdentifiers
import WebKit
#if DEBUG
import os
#endif

/// UIKit's local collection drag/drop supplies lift, cancellation and edge
/// auto-scroll. It shares no gesture recognizers with the page's WKWebView.
struct MobileTabGrid: UIViewControllerRepresentable {
    let controller: MobileController
    let profiles: MobileProfiles
    var tabs: [BrowserTab]
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

@MainActor final class MobileTabGridController: UICollectionViewController, UICollectionViewDragDelegate, UICollectionViewDropDelegate, UICollectionViewDelegateFlowLayout {
    var model: MobileTabGrid
    private var sections: [[BrowserTab]] = []
    private struct CardContent: Equatable {
        let id: UUID
        let pinned: Bool
        let title: String
        @MainActor init(_ tab: BrowserTab) {
            id = tab.id
            pinned = tab.isPinned
            title = tab.displayTitle
        }
    }

    private var cardContent: [CardContent] = []
    private var renderedSelection: UUID?
    private var renderedLargeText: Bool?
    private var renderedAppearance: BrowserAppearance?
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
        let next = model.tabs.map(CardContent.init)
        let selected = model.controller.session.selectedTabID
        let appearance = model.controller.appearance
        let layout = collectionViewLayout as? MobileTabGridLayout
        if layout?.reduceMotion != model.reduceMotion { layout?.reduceMotion = model.reduceMotion }
        synchronizeStyle(appearance)
        if cardContent != next || renderedSelection != selected || renderedLargeText != model.largeText || renderedAppearance != appearance {
            let previous = sections
            let updated = [model.tabs.filter { !$0.isPrivate }, model.tabs.filter(\.isPrivate)].filter { !$0.isEmpty }
            let previousContent = Dictionary(uniqueKeysWithValues: cardContent.map { ($0.id, $0) })
            let nextContent = Dictionary(uniqueKeysWithValues: next.map { ($0.id, $0) })
            let previousSelection = renderedSelection
            let refreshAll = renderedLargeText != model.largeText || renderedAppearance != appearance
            cardContent = next
            renderedSelection = selected
            renderedLargeText = model.largeText
            renderedAppearance = appearance

            let oldIDs = previous.flatMap { $0.map(\.id) }, newIDs = updated.flatMap { $0.map(\.id) }
            let oldSections = previous.compactMap { $0.first?.isPrivate }
            let newSections = updated.compactMap { $0.first?.isPrivate }
            let removedSections = IndexSet(oldSections.indices.filter { !newSections.contains(oldSections[$0]) })
            let deletions = previous.enumerated().flatMap { section, tabs in
                tabs.enumerated().compactMap { item, tab in
                    newIDs.contains(tab.id) || removedSections.contains(section) ? nil : IndexPath(item:item,section:section)
                }
            }
            let onlyDeletes = newIDs.count < oldIDs.count && newIDs == oldIDs.filter { newIDs.contains($0) }
            // BrowserSession creates a fresh home tab after the final close.
            // Keep that path, with a batch replacement instead of a reload flash.
            let lastReplacement = oldIDs.count == 1 && newIDs.count == 1 && oldIDs != newIDs
            let canAnimate = collectionView.window != nil && !collectionView.bounds.isEmpty
                && !collectionView.isHidden && !collectionView.hasUncommittedUpdates
            if (onlyDeletes || lastReplacement) && canAnimate {
                // UIKit can refresh its pre-update counts during layout. Keep
                // the old data source until the batch actually starts.
                collectionView.layoutIfNeeded()
                let rate = UIUpdateLink(view:collectionView)
                rate.preferredFrameRateRange = CAFrameRateRange(minimum:80,maximum:120,preferred:120)
                rate.isEnabled = true
                UIView.animate(withDuration:model.reduceMotion ? 0.18 : 0.42,delay:0,
                               usingSpringWithDamping:model.reduceMotion ? 1 : 0.88,initialSpringVelocity:0,
                               options:[.beginFromCurrentState,.allowUserInteraction]) {
                    self.collectionView.performBatchUpdates {
                        self.sections = updated
                        self.collectionView.deleteSections(removedSections)
                        self.collectionView.deleteItems(at:deletions)
                        if lastReplacement {
                            if oldSections == newSections { self.collectionView.insertItems(at:[IndexPath(item:0,section:0)]) }
                            else { self.collectionView.insertSections(IndexSet(integer:0)) }
                        }
                    } completion: { [weak self] _ in rate.isEnabled = false; self?.publishFrames() }
                }
            } else if oldIDs == newIDs {
                sections = updated
                let changed = collectionView.indexPathsForVisibleItems.filter { path in
                    guard updated.indices.contains(path.section), updated[path.section].indices.contains(path.item) else { return false }
                    let id = updated[path.section][path.item].id
                    return refreshAll || id == selected || id == previousSelection || previousContent[id] != nextContent[id]
                }
                if !changed.isEmpty { collectionView.reconfigureItems(at: changed) }
            } else {
                sections = updated
                if canAnimate && !onlyDeletes && !lastReplacement {
                    UIView.transition(with:collectionView,duration:model.reduceMotion ? 0.18 : 0.25,options:.transitionCrossDissolve) { self.collectionView.reloadData() }
                } else {
                    collectionView.reloadData()
                }
                collectionView.collectionViewLayout.invalidateLayout()
            }
        }
        if model.tabs.isEmpty && collectionView.backgroundView == nil {
            collectionView.backgroundView = UIHostingController(rootView: BrowserEmptyState("No matching tabs")).view
        } else if !model.tabs.isEmpty && collectionView.backgroundView != nil {
            collectionView.backgroundView = nil
        }
        synchronizeVisibility()
        if model.presented && !wasPresented { revealSelected(announce:true) }
    }
    private func synchronizeStyle(_ appearance: BrowserAppearance) {
        let style: UIUserInterfaceStyle = appearance.colorScheme.map { $0 == .dark ? .dark : .light } ?? .unspecified
        if collectionView.overrideUserInterfaceStyle != style { collectionView.overrideUserInterfaceStyle = style }
    }

    private func revealSelected(announce:Bool) {
        collectionView.layoutIfNeeded()
        if let path = sections.enumerated().compactMap({ section, tabs in
            tabs.firstIndex { $0.id == model.controller.session.selectedTabID }.map { IndexPath(item:$0,section:section) }
        }).first {
            // An already centered selection needs no new scroll/layout pass.
            let viewport = collectionView.bounds
            if let frame = collectionView.layoutAttributesForItem(at: path)?.frame {
                let insets = collectionView.adjustedContentInset
                let bottom = max(-insets.top, collectionView.contentSize.height - viewport.height + insets.bottom)
                let offset = min(bottom, max(-insets.top, frame.midY - viewport.height / 2))
                if abs(collectionView.contentOffset.y - offset) > 1 {
                    collectionView.scrollToItem(at:path,at:.centeredVertically,animated:false)
                }
            }
            publishFrames()
            if announce { UIAccessibility.post(notification:.screenChanged,argument:collectionView.cellForItem(at:path)) }
        } else if announce { UIAccessibility.post(notification:.screenChanged,argument:collectionView) }
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        synchronizeVisibility()
        revealSelected(announce:model.presented)
    }
    private func synchronizeVisibility() {
        guard isViewLoaded else { return }
        let hidden = !model.visible
        let accessibilityHidden = !model.presented
        if view.isHidden != hidden { view.isHidden = hidden }
        if view.accessibilityElementsHidden != accessibilityHidden { view.accessibilityElementsHidden = accessibilityHidden }
        if let navigation = navigationController?.view {
            if navigation.accessibilityViewIsModal != model.presented { navigation.accessibilityViewIsModal = model.presented }
            if navigation.isHidden != hidden { navigation.isHidden = hidden }
            if navigation.accessibilityElementsHidden != accessibilityHidden { navigation.accessibilityElementsHidden = accessibilityHidden }
        }
    }
    override func viewWillTransition(to size:CGSize,with coordinator:any UIViewControllerTransitionCoordinator) {
        cancelGestures()
        super.viewWillTransition(to:size,with:coordinator)
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.view.accessibilityViewIsModal = false
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Navigation containment can arrive after the first model update. A
        // cached hosting graph must still hide its newly attached navigation UI.
        synchronizeVisibility()
        #if DEBUG
        MobileTransitionMetrics.gridLayouts += 1
        #endif
        publishFrames()
        guard let layout = collectionViewLayout as? UICollectionViewFlowLayout else { return }
        let columns: CGFloat = model.largeText ? 1 : 2
        let width = floor((collectionView.bounds.width - 32 - (columns - 1) * 16) / columns)
        let caption = UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: traitCollection).lineHeight
        let size = CGSize(width: max(100, width), height: model.largeText ? max(310, 220 + caption * 3 + 8) : width * 1.42 + 26)
        if layout.itemSize != size {
            layout.itemSize = size; layout.sectionInset = UIEdgeInsets(top: 12, left: 16, bottom: 20, right: 16)
            layout.minimumInteritemSpacing = 16; layout.minimumLineSpacing = 16
            layout.invalidateLayout()
        }
    }
    func collectionView(_ collectionView:UICollectionView,layout:UICollectionViewLayout,referenceSizeForHeaderInSection section:Int) -> CGSize {
        CGSize(width:collectionView.bounds.width,height:sections.count > 1 ? max(36,UIFont.preferredFont(forTextStyle:.headline,compatibleWith:traitCollection).lineHeight + 12) : 0)
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
        cell.represent(tab.id)
        #if DEBUG
        MobileTransitionMetrics.gridHostingConfigurations += 1
        #endif
        cell.setCard(UIHostingConfiguration {
            MobileGridCard(tab: tab, presentation: controller.tabPresentation, selected: controller.session.selectedTabID == tab.id, largeText: model.largeText, close: { controller.close([tab.id]) })
                .browserAppearance(controller.appearance)
                .environment(\.siteIcons, controller.session.siteIcons)
        }.margins(.all, 0))
        cell.canInteract = { [weak self] in self?.model.presented == true && self?.reordering == false && self?.pulling == false && self?.model.controller.closeConfirmation == nil }
        cell.reduceMotion = model.reduceMotion
        cell.close = { controller.close([tab.id]) }
        cell.closeSwipe = { [weak cell] velocity in
            if tab.isPrivate { cell?.restore() }
            controller.close([tab.id], animation: { [weak cell] finish in
                guard let cell, cell.representedTabID == tab.id else { finish(); return }
                cell.flyAway(velocity:velocity, completion:finish)
            }, cancelled: { [weak cell] in if cell?.representedTabID == tab.id { cell?.restore() } })
        }
        cell.pinchProgress = model.onPinch.map { action in { amount, ended in action(tab, amount, ended) } }
        cell.open = { [weak self] in self?.model.open(tab) }
        cell.isAccessibilityElement = true
        cell.accessibilityLabel = "\(tab.isPinned ? "Pinned. " : "")\(tab.isPrivate ? "Private. " : "")\(tab.displayTitle)"
        cell.accessibilityTraits = controller.session.selectedTabID == tab.id ? [.button, .selected] : [.button]
        cell.accessibilityHint = "Double tap to open. Actions include Close Tab and Move Earlier or Later."
        cell.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Duplicate Tab") { _ in controller.session.duplicateTab(tab.id); return true },
            UIAccessibilityCustomAction(name: "Copy Link") { _ in if let url = tab.url { PrivacyPasteboard.copy(url) }; return true },
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
    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let cell = collectionView.cellForItem(at:indexPath) as? MobileTabCell,
              cell.canInteract(), !cell.swiping, !cell.pinching, !cell.closing else { return }
        model.open(sections[indexPath.section][indexPath.item])
    }
    override func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        let tab = sections[indexPath.section][indexPath.item], controller = model.controller, profiles = model.profiles
        func action(_ title: String, _ image: String, destructive: Bool = false, _ operation: @escaping () -> Void) -> UIAction {
            UIAction(title: title, image: UIImage(systemName: image), attributes: destructive ? .destructive : []) { _ in operation() }
        }
        let configuration = UIContextMenuConfiguration(actionProvider: { _ in
            var items: [UIMenuElement] = [
                UIAction(title: "Copy Link", image: UIImage(systemName: "doc.on.doc"), attributes: tab.url == nil ? .disabled : []) { _ in if let url = tab.url { PrivacyPasteboard.copy(url) } },
                UIAction(title: "Copy Original Link", image: UIImage(systemName: "link"), attributes: tab.url == nil ? .disabled : []) { _ in if let url = tab.url { PrivacyPasteboard.copy(url, original: true) } },
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
        #if DEBUG
        MobileTransitionMetrics.note("grid-drag-begin", ["section":indexPath.section,"item":indexPath.item,"generation":dragGeneration])
        #endif
        guard model.presented, !pulling, model.controller.closeConfirmation == nil,
              !collectionView.visibleCells.contains(where: { ($0 as? MobileTabCell).map { $0.swiping || $0.pinching } ?? false }) else { return [] }
        let tab = sections[indexPath.section][indexPath.item]
        let item = UIDragItem(itemProvider: NSItemProvider(object: tab.id.uuidString as NSString)); item.localObject = tab.id
        reordering = true
        session.localContext = dragGeneration
        return [item]
    }
    func collectionView(_ collectionView: UICollectionView, dragSessionDidEnd session: any UIDragSession) {
        #if DEBUG
        MobileTransitionMetrics.note("grid-drag-end", ["reordering":reordering,"generation":dragGeneration])
        #endif
        reordering = false
    }
    func collectionView(_ collectionView: UICollectionView, dragSessionIsRestrictedToDraggingApplication session: any UIDragSession) -> Bool { true }
    func collectionView(_ collectionView: UICollectionView, dropSessionDidUpdate session: any UIDropSession, withDestinationIndexPath destination: IndexPath?) -> UICollectionViewDropProposal {
        guard reordering, session.localDragSession?.localContext as? Int == dragGeneration, let id = session.items.first?.localObject as? UUID,
              let destination, sections.indices.contains(destination.section), sections[destination.section].indices.contains(destination.item),
              let source = model.controller.session.tabs.first(where: { $0.id == id }) else { return UICollectionViewDropProposal(operation: .forbidden) }
        let target = sections[destination.section][destination.item]
        return UICollectionViewDropProposal(operation: source.isPrivate == target.isPrivate && source.isPinned == target.isPinned ? .move : .forbidden, intent: .insertAtDestinationIndexPath)
    }
    func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: any UICollectionViewDropCoordinator) {
        #if DEBUG
        MobileTransitionMetrics.note("grid-drop", ["reordering":reordering,"items":coordinator.items.count,"hasLocalID":coordinator.items.first?.dragItem.localObject is UUID,"destination":coordinator.destinationIndexPath.map { "\($0.section):\($0.item)" } ?? "none"])
        #endif
        guard reordering, let item = coordinator.items.first, let id = item.dragItem.localObject as? UUID,
              let source = item.sourceIndexPath,
              coordinator.session.localDragSession?.localContext as? Int == dragGeneration,
              let destination = coordinator.destinationIndexPath, sections.indices.contains(destination.section), sections[destination.section].indices.contains(destination.item),
              let sourceTab = model.controller.session.tabs.first(where: { $0.id == id }),
              sourceTab.isPrivate == sections[destination.section][destination.item].isPrivate,
              sourceTab.isPinned == sections[destination.section][destination.item].isPinned else { return }
        model.controller.session.moveTab(id, to: sections[destination.section][destination.item].id)
        #if DEBUG
        MobileTransitionMetrics.note("grid-drop-model", ["order":model.controller.session.orderedTabs.map(\.displayTitle),"source":id.uuidString,"target":sections[destination.section][destination.item].id.uuidString])
        #endif
        // UIKit needs the reordered data immediately. The representable's old
        // array still has the pre-drop order until SwiftUI evaluates it again.
        let visibleIDs = Set(model.tabs.map(\.id))
        var reordered = model
        reordered.tabs = model.controller.session.orderedTabs.filter { visibleIDs.contains($0.id) }
        model = reordered
        sections = [reordered.tabs.filter { !$0.isPrivate }, reordered.tabs.filter(\.isPrivate)].filter { !$0.isEmpty }
        cardContent = reordered.tabs.map(CardContent.init)
        // Reloading during an active UIKit drop restores its old cell layout.
        // Commit the matching collection move with the updated data source.
        collectionView.performBatchUpdates {
            if source != destination { self.collectionView.moveItem(at:source,to:destination) }
        } completion: { [weak self] _ in self?.publishFrames() }
        coordinator.drop(item.dragItem, toItemAt: destination)
        reordering = false
    }
    func cancelGestures() {
        let wasPulling = pulling
        pulling = false; reordering = false; dragGeneration += 1
        collectionView.cancelInteractiveMovement()
        collectionView.dragInteractionEnabled = false
        collectionView.dragInteractionEnabled = true
        collectionView.panGestureRecognizer.isEnabled = false
        collectionView.panGestureRecognizer.isEnabled = true
        for case let cell as MobileTabCell in collectionView.visibleCells { cell.cancelGestures() }
        if wasPulling { model.onPull(0, true) }
    }
    @objc func panGrid(_ gesture: UIPanGestureRecognizer) {
        guard cancellation?.suspended != true else { pulling = false; return }
        let translation = gesture.translation(in: collectionView)
        switch gesture.state {
        case .began:
            pulling = !reordering && !collectionView.visibleCells.contains(where: { ($0 as? MobileTabCell)?.swiping == true }) && collectionView.contentOffset.y <= -collectionView.adjustedContentInset.top + 2 && gesture.velocity(in: collectionView).y > abs(gesture.velocity(in: collectionView).x)
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
    var canInteract: () -> Bool = { true }
    var close: (() -> Void)?
    var open: (() -> Void)?
    var closeSwipe: ((CGFloat) -> Void)?
    var pinchProgress: ((CGFloat, Bool) -> Void)?
    var reduceMotion = false
    private(set) var swiping = false
    private(set) var pinching = false
    private(set) var closing = false
    // UICollectionView owns contentView's frame. Transform a separate surface
    // so hosting/layout updates cannot compensate for the drag's translation.
    let swipeSurface = UIView()
    private(set) var representedTabID:UUID?
    private var hostedCard: (UIView & UIContentView)?
    private var animator: UIViewPropertyAnimator?
    private var exitCompletion: (() -> Void)?
    private var dragOrigin: CGFloat = 0
    private var frameRateLink: UIUpdateLink?
    private var cancellation: MobileGestureCancellation?
    override init(frame: CGRect) {
        super.init(frame: frame)
        swipeSurface.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(swipeSurface)
        NSLayoutConstraint.activate([
            swipeSurface.leadingAnchor.constraint(equalTo:contentView.leadingAnchor),
            swipeSurface.trailingAnchor.constraint(equalTo:contentView.trailingAnchor),
            swipeSurface.topAnchor.constraint(equalTo:contentView.topAnchor),
            swipeSurface.bottomAnchor.constraint(equalTo:contentView.bottomAnchor)
        ])
        let swipe = UIPanGestureRecognizer(target:self,action:#selector(swipe(_:)))
        swipe.maximumNumberOfTouches = 1; swipe.delegate = self; addGestureRecognizer(swipe)
        let pinch = UIPinchGestureRecognizer(target:self,action:#selector(pinch(_:)))
        pinch.delegate = self; addGestureRecognizer(pinch)
        cancellation = MobileGestureCancellation { [weak self] in self?.cancelGestures() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func represent(_ id:UUID) {
        if representedTabID != id { cancelGestures(); representedTabID = id }
    }
    func setCard(_ configuration: some UIContentConfiguration) {
        if let hostedCard { hostedCard.configuration = configuration }
        else {
            let card = configuration.makeContentView()
            card.translatesAutoresizingMaskIntoConstraints = false; swipeSurface.addSubview(card)
            NSLayoutConstraint.activate([
                card.leadingAnchor.constraint(equalTo:swipeSurface.leadingAnchor),
                card.trailingAnchor.constraint(equalTo:swipeSurface.trailingAnchor),
                card.topAnchor.constraint(equalTo:swipeSurface.topAnchor),
                card.bottomAnchor.constraint(equalTo:swipeSurface.bottomAnchor)
            ])
            hostedCard = card
        }
    }
    override func prepareForReuse() {
        super.prepareForReuse(); cancelGestures()
        close = nil; open = nil; closeSwipe = nil; pinchProgress = nil
    }
    private func finishExit() {
        let finish = exitCompletion; exitCompletion = nil
        // Reuse can occur inside a collection update. Deliver a committed close
        // on the next turn rather than recursively mutating that batch.
        if let finish { Task { @MainActor in finish() } }
    }
    func cancelGestures() {
        animator?.stopAnimation(true); animator = nil
        finishExit(); closing = false
        if pinching { pinchProgress?(0,true) }
        swiping = false; pinching = false
        for gesture in gestureRecognizers ?? [] { gesture.isEnabled = false; gesture.isEnabled = true }
        swipeSurface.layer.removeAllAnimations()
        swipeSurface.transform = .identity; swipeSurface.alpha = 1
        stopFrameRate()
    }
    override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard canInteract(), !swiping, !pinching, !closing, cancellation?.suspended != true else { return false }
        if let pan = gesture as? UIPanGestureRecognizer { let v = pan.velocity(in:self); return v.x < -abs(v.y) * 1.4 }
        if let pinch = gesture as? UIPinchGestureRecognizer { return pinch.scale > 1 }
        return true
    }
    static func swipeCommits(distance: CGFloat, velocity: CGFloat, width: CGFloat) -> Bool {
        distance < -max(60,width * 0.35) || (distance < -20 && velocity < -650 && distance + velocity * 0.18 < -width * 0.5)
    }
    private func interruptSpring() {
        let layer = swipeSurface.layer.presentation()
        let transform = layer?.affineTransform() ?? swipeSurface.transform
        let alpha = CGFloat(layer?.opacity ?? Float(swipeSurface.alpha))
        animator?.stopAnimation(true); animator = nil
        swipeSurface.transform = transform; swipeSurface.alpha = alpha
    }
    @objc func swipe(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began {
            swiping = canInteract() && !pinching && !closing && cancellation?.suspended != true
            if swiping { interruptSpring(); dragOrigin = swipeSurface.transform.tx; startFrameRate() }
        }
        guard swiping else { return }
        let distance = gesture.translation(in:self).x + dragOrigin, width = max(bounds.width,1)
        if gesture.state == .began || gesture.state == .changed || gesture.state == .ended {
            // No layout, snapshot capture, or observable state writes here.
            // Keep leftward tracking 1:1, including travel beyond the card width.
            let x = distance > 0 ? distance * 0.18 : distance
            if !reduceMotion { swipeSurface.transform = CGAffineTransform(translationX:x,y:0) }
            swipeSurface.alpha = max(0.55,1 - abs(x) / width * 0.22)
        }
        if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
            let velocity = gesture.velocity(in:self).x
            let commit = gesture.state == .ended && Self.swipeCommits(distance:distance,velocity:velocity,width:width)
            swiping = false
            if commit { if let closeSwipe { closeSwipe(velocity) } else { close?(); restore() } }
            else { restore(velocity:velocity) }
        }
    }
    func restore(velocity:CGFloat = 0) {
        guard !closing else { return }
        interruptSpring(); startFrameRate()
        animate(to:0,alpha:1,velocity:velocity) { [weak self] in self?.stopFrameRate() }
    }
    func flyAway(velocity: CGFloat, completion: @escaping () -> Void) {
        guard !closing else { return }
        interruptSpring(); closing = true; exitCompletion = completion; startFrameRate()
        // A right-column card must traverse its distance to the viewport edge,
        // not merely its own width. Retain the hosted thumbnail until completion.
        let edge = window.map { convert(bounds,to:$0).maxX } ?? bounds.width
        animate(to:reduceMotion ? 0 : -edge - 24,alpha:0,velocity:min(0,velocity)) { [weak self] in
            guard let self else { return }
            self.stopFrameRate(); self.finishExit()
        }
    }
    private func animate(to x:CGFloat,alpha:CGFloat,velocity:CGFloat,completion:@escaping () -> Void) {
        let distance = x - swipeSurface.transform.tx
        let timing:UITimingCurveProvider = reduceMotion ? UICubicTimingParameters(animationCurve:.easeOut) :
            UISpringTimingParameters(dampingRatio:0.94,initialVelocity:CGVector(dx:abs(distance)>1 ? max(-12,min(12,velocity/distance)) : 0,dy:0))
        let animation = UIViewPropertyAnimator(duration:reduceMotion ? 0.18 : 0.42,timingParameters:timing)
        animation.addAnimations { self.swipeSurface.transform = CGAffineTransform(translationX:x,y:0); self.swipeSurface.alpha = alpha }
        animation.addCompletion { [weak self] position in
            guard position == .end else { return }
            self?.animator = nil; completion()
        }
        animator = animation; animation.startAnimation()
    }
    private func startFrameRate() {
        guard frameRateLink == nil else { return }
        let link = UIUpdateLink(view:swipeSurface)
        link.preferredFrameRateRange = CAFrameRateRange(minimum:80,maximum:120,preferred:120)
        link.isEnabled = true; frameRateLink = link
    }
    private func stopFrameRate() { frameRateLink?.isEnabled = false; frameRateLink = nil }
    isolated deinit { frameRateLink?.isEnabled = false }
    @objc func pinch(_ gesture: UIPinchGestureRecognizer) {
        if gesture.state == .began { pinching = canInteract() && !swiping && !closing && cancellation?.suspended != true }
        if gesture.state == .changed && pinching {
            if let pinchProgress { pinchProgress(min(1,max(0,(gesture.scale-1)/0.8)),false) }
            else if !reduceMotion { swipeSurface.transform = CGAffineTransform(scaleX:min(1.12,gesture.scale),y:min(1.12,gesture.scale)) }
            else { swipeSurface.alpha = max(0.6,2-gesture.scale) }
        } else if gesture.state == .ended || gesture.state == .cancelled {
            let valid = gesture.state == .ended && pinching
            if let pinchProgress, pinching { pinchProgress(valid ? min(1,max(0,(gesture.scale-1)/0.8)) : 0,true) }
            else if valid && gesture.scale > 1.2 { open?() }
            pinching = false; restore()
        }
    }
    override func accessibilityActivate() -> Bool { guard canInteract(), !closing else { return false }; open?(); return true }
}

struct MobileGridCard: View {
    @Environment(\.browserTheme) private var theme
    let tab: BrowserTab
    let presentation: MobileTabPresentation
    let selected: Bool
    let largeText: Bool
    let close: () -> Void
    var body: some View {
        VStack(spacing: 8) {
            MobileTabThumbnail(tab: tab, presentation: presentation)
                // The live surface is above this card. Keep its thumbnail as
                // backing while a newly selected/restored host mounts; activeID
                // alone does not mean WebKit has a composited layer yet.
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
    @ObservationIgnored private var imageOrder: [UUID] = []
    @ObservationIgnored private var imageBytes: [UUID: Int] = [:]
    let snapshotByteLimit: Int
    var snapshotBytes: Int { imageBytes.values.reduce(0,+) }
    private final class SnapshotCapture {
        var timeout:Task<Void,Never>?
        func cancel() { timeout?.cancel(); timeout = nil }
        deinit { timeout?.cancel() }
    }
    @ObservationIgnored private var captures: [UUID: SnapshotCapture] = [:]
    var cardFrames: [UUID: CGRect] = [:]
    var activeID: UUID?
    private(set) var livePreparation:UUID?
    private(set) var liveReady = true
    @ObservationIgnored private var refreshTask: Task<Void,Never>?
    var pendingSelection: UUID?
    var pendingNewTab: Bool?
    var inserting = false
    var insertionProgress: CGFloat = 0
    private var generation = 0
    private var settlementRevision = 0
    @ObservationIgnored private var settlementTask:Task<Void,Never>?
    private var suspended = false
    var cacheRevision: Int { generation }
    init(snapshotByteLimit:Int = 24 * 1_024 * 1_024) {
        self.snapshotByteLimit = max(0,snapshotByteLimit)
    }
    func resume() { if suspended { suspended = false; generation += 1 } }

    func capture(_ tab: BrowserTab, refresh: Bool = false) {
        guard !suspended, activeID == nil, captures[tab.id] == nil, tab.hasLoaded, tab.isInstantiated,
              refresh || revisions[tab.id] != tab.documentRevision || images[tab.id] == nil else { return }
        let id = tab.id, revision = tab.documentRevision, request = generation
        let capture = SnapshotCapture()
        captures[id] = capture
        let config = WKSnapshotConfiguration(); config.snapshotWidth = NSNumber(value:Double(min(440,cardFrames[tab.id]?.width ?? 220)))
        #if DEBUG
        MobileTransitionMetrics.snapshotCount += 1
        #endif
        capture.timeout = Task { @MainActor [weak self,weak capture] in
            do { try await Task.sleep(for:.seconds(3)) } catch { return }
            guard let self, let capture, self.captures[id] === capture else { return }
            self.captures[id] = nil; capture.cancel()
        }
        #if DEBUG
        let started = ProcessInfo.processInfo.systemUptime
        #endif
        // The async API retains its receiver and caller across a callback that
        // WebKit may never deliver. Closing a tab must release both immediately.
        tab.webView.takeSnapshot(with:config) { [weak self,weak tab,weak capture] image,_ in
            #if DEBUG
            MobileTransitionMetrics.recordSnapshot(image,seconds:ProcessInfo.processInfo.systemUptime-started)
            #endif
            guard let self, let capture, self.captures[id] === capture, request == self.generation else { return }
            self.captures[id] = nil; capture.cancel()
            guard let tab, tab.isInstantiated, tab.documentRevision == revision else { return }
            if let image {
                self.store(image,for:tab.id,revision:revision)
            }
        }
    }
    func store(_ image:UIImage,for id:UUID,revision:Int) {
        // Account for decoded pixels, including row padding and the device's
        // actual image scale. A count limit alone is not a memory bound.
        guard let pixels = image.cgImage else { return }
        let (bytes,overflow) = pixels.bytesPerRow.multipliedReportingOverflow(by:pixels.height)
        guard !overflow, bytes <= snapshotByteLimit else { return }
        removeImage(id)
        while images.count >= 12 || snapshotBytes > snapshotByteLimit-bytes {
            guard let old = imageOrder.first(where: { $0 != activeID && $0 != id }) else { return }
            removeImage(old)
        }
        images[id] = image; revisions[id] = revision; imageBytes[id] = bytes
        imageOrder.append(id)
    }
    private func removeImage(_ id:UUID) {
        images[id] = nil; revisions[id] = nil; imageBytes[id] = nil
        imageOrder.removeAll { $0 == id }
    }
    func releaseCachedSnapshots() {
        // Invalidate in-flight captures too: a late WebKit callback must not
        // refill the cache immediately after a memory warning.
        generation += 1
        refreshTask?.cancel(); refreshTask = nil
        captures.values.forEach { $0.cancel() }; captures.removeAll()
        settlementTask?.cancel(); settlementTask = nil; settlementRevision += 1
        images.removeAll(); revisions.removeAll(); imageBytes.removeAll(); imageOrder.removeAll()
        finish()
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
        settlementTask?.cancel(); settlementTask = nil
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
        settlementTask?.cancel()
        let complete: @MainActor @Sendable (UIImage?) -> Void = { [weak self,weak tab] image in
            guard let self, let tab, !self.suspended, request == self.generation,
                  settlement == self.settlementRevision else { return }
            if let image, tab.isInstantiated, tab.documentRevision == revision { self.store(image,for:tab.id,revision:revision) }
            // A failed thumbnail retains the existing backing card. It must
            // still release the live host and leave an interactive grid.
            if self.activeID == tab.id { self.finish() }
        }
        settlementTask = Task { @MainActor in
            do { try await Task.sleep(for:.seconds(2)) } catch { return }
            complete(nil)
        }
        let config = WKSnapshotConfiguration(); config.snapshotWidth = NSNumber(value:Double(min(440,cardFrames[tab.id]?.width ?? 220)))
        #if DEBUG
        let started = ProcessInfo.processInfo.systemUptime
        #endif
        tab.webView.takeSnapshot(with:config) { image,_ in
            #if DEBUG
            MobileTransitionMetrics.recordSnapshot(image,seconds:ProcessInfo.processInfo.systemUptime-started)
            #endif
            complete(image)
        }
    }
    func beginNewTab() {
        #if DEBUG
        MobileTransitionMetrics.start("new-tab")
        #endif
        activeID = UUID()
    }
    func prepareLive() { liveReady = false; livePreparation = UUID() }
    func didPrepareLive(_ token:UUID) {
        guard token == livePreparation else { return }
        liveReady = true; livePreparation = nil
    }
    func finish() {
        settlementTask?.cancel(); settlementTask = nil
        settlementRevision += 1; activeID = nil; pendingSelection = nil; pendingNewTab = nil
        livePreparation = nil; liveReady = true
        #if DEBUG
        MobileTransitionMetrics.stop()
        #endif
    }
    func remove(_ id: UUID) {
        captures.removeValue(forKey: id)?.cancel()
        removeImage(id); cardFrames[id] = nil
        if activeID == id { finish() }
    }
    func discard() {
        refreshTask?.cancel()
        suspended = true; releaseCachedSnapshots()
        cardFrames.removeAll(); finish()
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
    nonisolated(unsafe) static var gridInterpolations = 0
    static var gridLayouts = 0
    static var gridHostingConfigurations = 0
    static var webMorphUpdates = 0
    static var snapshotCount = 0
    private static let shared = MobileTransitionMetrics()
    private let log = OSLog(subsystem:"Oriv",category:"TabTransitions")
    private var link: CADisplayLink?
    private var frames: [Double] = []
    private var frameSampler:(() -> [String:Any])?
    private var frameEvidence:[[String:Any]] = []
    private var samples: [[String: Any]] = []
    private var trace: [[String:Any]] = []
    private var name = ""
    private var snapshotsAtStart = 0
    private var writeRevision = 0
    private var traceWriteRevision = 0
    private static let writer = SampleWriter()
    private static let traceWriter = SampleWriter()
    // Rows contain only immutable strings, numbers and value-type arrays.
    // Copy-on-write keeps each submitted snapshot independent of later appends.
    private struct SamplePayload: @unchecked Sendable {
        let revision: Int
        let rows: [[String:Any]]
    }
    private actor SampleWriter {
        private var revision = 0
        func write(_ payload:SamplePayload,filename:String = "oriv-transition-metrics.json") {
            guard payload.revision > revision else { return }
            revision = payload.revision
            if let data = try? JSONSerialization.data(withJSONObject:payload.rows,options:[.sortedKeys]) {
                try? data.write(to:FileManager.default.temporaryDirectory.appendingPathComponent(filename),options:.atomic)
            }
        }
    }
    static func note(_ event:String,_ values:[String:Any] = [:]) {
        guard ProcessInfo.processInfo.arguments.contains("--oriv-gesture-trace") else { return }
        shared.trace.append(["event":event,"values":values,"time":ProcessInfo.processInfo.systemUptime])
        shared.traceWriteRevision += 1
        let payload = SamplePayload(revision:shared.traceWriteRevision,rows:shared.trace)
        Task { await traceWriter.write(payload,filename:"oriv-gesture-trace.json") }
    }
    static func start(_ name: String,frameSampler:(() -> [String:Any])? = nil) {
        guard ProcessInfo.processInfo.arguments.contains("--oriv-transition-metrics"), shared.link == nil else { return }
        os_signpost(.begin,log:shared.log,name:"TabTransition","%{public}@",name)
        shared.name = name; shared.frames = []; shared.snapshotsAtStart = snapshotCount
        shared.frameSampler = frameSampler; shared.frameEvidence = []
        let link = CADisplayLink(target:shared,selector:#selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum:60,maximum:120,preferred:120)
        shared.link = link; link.add(to:.main,forMode:.common)
    }
    @objc private func tick(_ link: CADisplayLink) {
        frames.append(link.timestamp)
        if let frameSampler {
            var row = frameSampler(); row["timestamp"] = link.timestamp
            frameEvidence.append(row)
        }
    }
    static func stop() {
        guard shared.link != nil else { return }
        os_signpost(.end,log:shared.log,name:"TabTransition")
        shared.link?.invalidate(); shared.link = nil
        let deltas = zip(shared.frames,shared.frames.dropFirst()).map { ($1-$0)*1000 }
        shared.samples.append(["gesture":shared.name,"frameIntervalsMs":deltas,"snapshots":snapshotCount-shared.snapshotsAtStart,
            "frameEvidence":shared.frameEvidence])
        shared.frameSampler = nil; shared.frameEvidence = []
        writeSamples()
    }
    static func recordSnapshot(_ image:UIImage?,seconds:Double) {
        guard ProcessInfo.processInfo.arguments.contains("--oriv-transition-metrics") else { return }
        shared.samples.append(["event":"snapshot","seconds":seconds,"bytes":image?.cgImage.map { $0.bytesPerRow*$0.height } ?? 0,
            "width":image?.cgImage?.width ?? 0,"height":image?.cgImage?.height ?? 0])
        if shared.link == nil { writeSamples() }
    }
    static func recordPreparation(seconds:Double,success:Bool) {
        guard ProcessInfo.processInfo.arguments.contains("--oriv-transition-metrics") else { return }
        shared.samples.append(["event":"paint-preparation","seconds":seconds,"success":success])
    }
    private static func writeSamples() {
        shared.writeRevision += 1
        let payload = SamplePayload(revision:shared.writeRevision,rows:shared.samples)
        Task { await writer.write(payload) }
    }
}
#endif
