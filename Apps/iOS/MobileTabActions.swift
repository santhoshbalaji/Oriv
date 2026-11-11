import SwiftUI
import Observation
import BrowserCore
import BrowserEngine
import WebKit

extension MobileController {
    /// Normal single closes are recoverable through Recently Closed. Private
    /// closes are irreversible; normal Close All remains a confirmed bulk action.
    func closeNeedsConfirmation(_ ids: [UUID], confirmAll: Bool = false) -> Bool {
        confirmAll || session.tabs.contains { ids.contains($0.id) && $0.isPrivate }
    }
    func close(_ ids: [UUID], confirmAll: Bool = false, completion: (() -> Void)? = nil,
               animation: ((@escaping () -> Void) -> Void)? = nil, cancelled: (() -> Void)? = nil) {
        var seen = Set<UUID>()
        let ids = ids.filter { id in seen.insert(id).inserted && session.tabs.contains { $0.id == id } }
        guard !ids.isEmpty else { completion?(); return }
        let privateTabs = session.tabs.contains { ids.contains($0.id) && $0.isPrivate }
        let operation = { [weak self] in
            guard let self else { return }
            let finish = { [weak self] in
                guard let self else { return }
                ids.forEach { self.session.closeTab($0); self.tabPresentation.remove($0) }
                completion?()
            }
            if let animation { animation(finish) } else { finish() }
        }
        guard closeNeedsConfirmation(ids, confirmAll: confirmAll) else { operation(); return }
        guard closeConfirmation == nil, let presenter = MobileWebDelegate.presenter,
              !(presenter is UIAlertController) else { cancelled?(); return }
        let alert = UIAlertController(title: privateTabs ? (confirmAll ? "Close All Private Tabs?" : "Close Private Tabs?") : "Close All Tabs?",
            message: privateTabs ? "Private tabs cannot be recovered from History or Recently Closed." : "This closes \(ids.count) tabs. You can reopen them from Recently Closed Tabs.", preferredStyle: .alert)
        closeConfirmation = alert
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in self?.closeConfirmation = nil; cancelled?() })
        alert.addAction(UIAlertAction(title: confirmAll ? "Close All Tabs" : ids.count == 1 ? "Close Tab" : "Close Tabs", style: .destructive) { [weak self] _ in
            self?.closeConfirmation = nil; operation()
        })
        presenter.present(alert, animated: !UIAccessibility.isReduceMotionEnabled)
    }
    func closeAllTabs() { close(session.tabsInSelectedMode.map(\.id), confirmAll: true) }
    func closeOtherTabs(_ tab: BrowserTab) {
        close(session.orderedTabs.filter { $0.id != tab.id && $0.isPrivate == tab.isPrivate && !$0.isPinned }.map(\.id))
    }
    func pasteAddress(search: Bool = false) {
        // No pasteboard contents are read while constructing a menu.
        guard let text = UIPasteboard.general.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        perform {
            if search { session.selectedTab?.navigate(to: session.settings.searchEngine.searchURL(text)) }
            else { try session.navigate(text) }
        }
    }
    func share(_ items: [Any], sourceView: UIView? = nil) {
        let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
        guard let presenter = MobileWebDelegate.presenter else { return }
        activity.popoverPresentationController?.sourceView = sourceView ?? presenter.view
        activity.popoverPresentationController?.sourceRect = sourceView?.bounds ?? CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
        presenter.present(activity, animated: !UIAccessibility.isReduceMotionEnabled)
    }
    func move(_ tab: BrowserTab, to profile: BrowserProfile) {
        guard let profiles else { return }
        if tab.isPrivate {
            close([tab.id],completion:{ [weak self,weak profiles] in
                guard let self else { return }
                profiles?.move(tab,from:self,to:profile)
            })
        } else { profiles.move(tab,from:self,to:profile) }
    }
}

struct MobileMoveTabMenu: View {
    let controller: MobileController
    let profiles: MobileProfiles
    let tab: BrowserTab
    var body: some View {
        Menu("Move to Profile", systemImage: "person.crop.circle") {
            ForEach(profiles.profiles.filter { $0.archivedAt == nil && $0.id != controller.profileID }) { profile in
                Button(profile.name, systemImage: profile.symbol.rawValue) { controller.move(tab, to: profile) }
            }
        }.disabled(tab.url == nil || !profiles.profiles.contains { $0.archivedAt == nil && $0.id != controller.profileID })
    }
}

struct MobileSendTabMenu: View {
    let controller: MobileController
    let profiles: MobileProfiles
    let tab: BrowserTab
    private var page: ContinuityPage? {
        guard let profile = profiles.profiles.first(where: { $0.id == controller.profileID }) else { return nil }
        return ContinuityPage(url: tab.url, title: tab.title, profile: profile, isPrivate: tab.isPrivate)
    }
    var body: some View {
        Menu("Open on Mac", systemImage: "paperplane") {
            if let page, profiles.continuity.canSendPage {
                ForEach(profiles.continuity.otherDevices) { device in
                    Button(device.name) { profiles.continuity.sendPage(page, to: device.id) }
                }
            } else {
                Text(tab.isPrivate ? "Unavailable in Private Browsing" : "Set Up Mac & iPhone in Settings")
            }
        }.disabled(page == nil || !profiles.continuity.canSendPage)
    }
}

struct MobileHistoryMenu: View {
    let tab: BrowserTab?
    let forward: Bool
    var body: some View {
        if let tab {
            let items = forward ? tab.webView.backForwardList.forwardList : tab.webView.backForwardList.backList.reversed()
            if items.isEmpty { Text("No \(forward ? "forward" : "back") history") }
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Button(item.title ?? URLDisplay.site(item.url) ?? item.url.absoluteString) { tab.go(to: item) }
            }
        }
    }
}

extension MobileController {
    /// A button route to the image commands for people who do not use a hold gesture.
    func showPageImages() {
        guard let tab = session.selectedTab, let adapter = tab.webView.uiDelegate as? MobileWebDelegate else { return }
        let revision = tab.documentRevision
        Task { @MainActor [weak self, weak tab, weak adapter] in
            guard let self, let tab else { return }
            do {
                let result = try await tab.webView.callAsyncJavaScript("return Array.from(document.images).slice(0,100).map(i=>({image:i.currentSrc||i.src,title:i.alt||'Image',link:i.closest('a[href]')?.href||''}))", arguments: [:], in: nil, contentWorld: .world(name: "OrivContext"))
                guard session.selectedTabID == tab.id, tab.documentRevision == revision, session.isProfileActive else { return }
                let images = result as? [[String: String]] ?? []
                let menu = UIAlertController(title: "Images on This Page", message: images.isEmpty ? "No images in this document." : nil, preferredStyle: .actionSheet)
                for (index, item) in images.enumerated() {
                    guard let image = item["image"].flatMap(URL.init(string:)) else { continue }
                    let link = item["link"].flatMap(URL.init(string:)).flatMap { AddressResolver.isWebURL($0) ? $0 : nil }
                    menu.addAction(UIAlertAction(title: "\(index + 1). \(item["title"] ?? "Image")", style: .default) { _ in
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(350))
                            guard tab.documentRevision == revision else { return }
                            adapter?.showImageMenu(image: image, link: link, point: CGPoint(x: tab.webView.bounds.midX, y: tab.webView.bounds.midY), in: tab.webView)
                        }
                    })
                }
                menu.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                guard let presenter = MobileWebDelegate.presenter else { return }
                menu.popoverPresentationController?.sourceView = presenter.view
                menu.popoverPresentationController?.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
                presenter.present(menu, animated: !UIAccessibility.isReduceMotionEnabled)
            } catch { message = error.localizedDescription }
        }
    }
}

/// A bottom-bar menu attaches above its source, leaving the address visible.
struct MobileAddressMenuSource: UIViewRepresentable {
    let controller: MobileController
    let profiles: MobileProfiles
    let tab: BrowserTab?
    var compact = false
    let action: () -> Void
    func makeUIView(context: Context) -> MobileAddressMenuButton { MobileAddressMenuButton(frame: .zero) }
    func updateUIView(_ button: MobileAddressMenuButton, context: Context) {
        button.tap = action
        button.tintColor = .label
        button.accessibilityValue = tab?.isPrivate == true ? "Private browsing" : nil
        button.accessibilityIdentifier = compact ? "browserCompactAddress" : "browserAddressDisplay"
        button.accessibilityLabel = compact ? "Expand browser controls, \(tab?.hostname ?? "Oriv")" : "\(tab.map { ConnectionCue($0) == .notSecure } == true ? "Not Secure. " : "")Address and search, \(tab?.url?.absoluteString ?? "new tab")"
        func item(_ title: String, _ symbol: String, disabled: Bool = false, destructive: Bool = false, _ perform: @escaping () -> Void) -> UIAction {
            UIAction(title: title, image: UIImage(systemName: symbol), attributes: destructive ? .destructive : disabled ? .disabled : []) { _ in perform() }
        }
        func group(_ children: [UIMenuElement]) -> UIMenu { UIMenu(options: .displayInline, children: children) }
        let copy = item("Copy", "doc.on.doc", disabled: tab?.url == nil) { if let url = tab?.url { PrivacyPasteboard.copy(url) } }
        let original = item("Copy Original Link", "link", disabled: tab?.url == nil) { if let url = tab?.url { PrivacyPasteboard.copy(url, original: true) } }
        var groups = [group([copy, original,
            item("Paste and Go", "doc.on.clipboard") { controller.pasteAddress() },
            item("Paste and Search", "magnifyingglass") { controller.pasteAddress(search: true) }
        ])]
        var sharing: [UIMenuElement] = [item("Share", "square.and.arrow.up", disabled: tab?.url == nil) { if let url = tab?.url { controller.share([URLCleaner.clean(url)]) } }]
        if let tab {
            sharing.append(UIMenu(title: "Move to Profile", image: UIImage(systemName: "person.crop.circle"), children: profiles.profiles.filter { $0.archivedAt == nil && $0.id != controller.profileID }.map { profile in
                item(profile.name, profile.symbol.rawValue, disabled: tab.url == nil) { controller.move(tab, to: profile) }
            }))
            let page = profiles.profiles.first { $0.id == controller.profileID }.flatMap { ContinuityPage(url: tab.url, title: tab.title, profile: $0, isPrivate: tab.isPrivate) }
            let destinations: [UIMenuElement] = profiles.continuity.otherDevices.map { device in
                item(device.name, "desktopcomputer", disabled: page == nil || !profiles.continuity.canSendPage) { if let page { profiles.continuity.sendPage(page, to: device.id) } }
            }
            sharing.append(UIMenu(title: "Open on Mac", image: UIImage(systemName: "paperplane"), children: destinations.isEmpty ? [item(tab.isPrivate ? "Unavailable in Private Browsing" : "Set Up Mac & iPhone in Settings", "desktopcomputer", disabled: true) {}] : destinations))
            groups.append(group(sharing))
            groups.append(group([
                item("Close Tab", "xmark", destructive: true) { controller.close([tab.id]) },
                item("Close All Tabs", "xmark.square", destructive: true) { controller.closeAllTabs() }
            ]))
        } else { groups.append(group(sharing)) }
        button.menu = UIMenu(children: groups)
    }
}

final class MobileAddressMenuButton: UIControl {
    var menu: UIMenu?
    var tap: (() -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
        isContextMenuInteractionEnabled = true
        isAccessibilityElement = true
        accessibilityTraits = .button
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func tapped() { tap?() }
    override func accessibilityActivate() -> Bool { tap?(); return true }
    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        let menu = menu
        let configuration = UIContextMenuConfiguration(actionProvider: { _ in menu })
        configuration.preferredMenuElementOrder = .fixed
        return configuration
    }
    override func menuAttachmentPoint(for configuration: UIContextMenuConfiguration) -> CGPoint {
        CGPoint(x: bounds.midX, y: bounds.minY - 12)
    }
}

/// Cancel transient touch state when UIKit suspends or deactivates a scene.
@MainActor final class MobileGestureCancellation: NSObject {
    private let action: () -> Void
    private(set) var suspended = false
    init(_ action: @escaping () -> Void) {
        self.action = action
        super.init()
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
                     UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(cancel), name: name, object: nil)
        }
        for name in [UIApplication.didBecomeActiveNotification, UIScene.didActivateNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(resume), name: name, object: nil)
        }
    }
    @objc private func cancel() { suspended = true; action() }
    @objc private func resume() { suspended = false }
    deinit { NotificationCenter.default.removeObserver(self) }
}

/// Shared by SwiftUI's drag callbacks and native cancellation tests. Only an
/// ended gesture with its original source may commit a tab or grid transition.
@MainActor @Observable final class MobileChromeGestureState {
    var translation: CGFloat = 0
    private(set) var axis: Axis?
    private(set) var source: UUID?
    var gridProgress: CGFloat = 0
    var gridPresented = false
    var gridClosing = false
    var finishingSwipe = false
    @ObservationIgnored private var cancellation: MobileGestureCancellation?
    init() { cancellation = MobileGestureCancellation { [weak self] in self?.cancel() } }
    func cancel() {
        translation = 0; axis = nil; source = nil; finishingSwipe = false
        gridProgress = gridPresented ? 1 : 0
        gridClosing = false
    }
    @discardableResult func capsule(_ phase: UIGestureRecognizer.State, translation delta: CGSize,
                                   predicted: CGSize = .zero, session: BrowserSession) -> Bool {
        if phase == .cancelled || phase == .failed { cancel(); return false }
        guard session.isProfileActive, cancellation?.suspended != true else { cancel(); return false }
        if phase == .began || phase == .changed {
            if source == nil { source = session.selectedTabID }
            if axis == nil { axis = abs(delta.width) > abs(delta.height) ? .horizontal : .vertical }
            if axis == .horizontal {
                let target = session.tabSwipeTarget(delta.width < 0 ? 1 : -1)
                translation = delta.width * (target == .boundary ? 0.18 : target == .newTab ? 0.45 : 1)
            } else { gridProgress = min(max(-delta.height / 320, 0), 1) }
        } else if phase == .ended {
            guard let source, session.selectedTabID == source else { cancel(); return false }
            var openGrid = false
            if axis == .horizontal {
                let direction = delta.width < 0 ? 1 : -1
                let target = session.tabSwipeTarget(direction)
                if abs(delta.width) > (target == .newTab ? 125 : 70) ||
                    (target != .newTab && abs(delta.width) > 25 && abs(predicted.width) > 180) {
                    session.commitTabSwipe(direction, from: source)
                }
            } else { openGrid = gridProgress > 0.3 }
            cancel()
            return openGrid
        }
        return false
    }
}
