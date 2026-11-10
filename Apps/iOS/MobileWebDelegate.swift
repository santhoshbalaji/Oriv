import BrowserCore
import BrowserEngine
import UIKit
import WebKit
import Observation

@MainActor final class MobileWebDelegate: NSObject, WKUIDelegate {
    weak var session: BrowserSession?
    weak var tab: BrowserTab?
    var contextCancellation: MobileGestureCancellation?
    weak var controller: MobileController?
    var touchedImageURL: URL?
    var touchedImageLinkURL: URL?
    var touchedImageRevision: Int?
    var touchedImageTime: TimeInterval = 0
    var imageTransfers: [UUID: MobileImageTransfer] = [:]
    var imageMenuInteraction: UIEditMenuInteraction?
    var imageMenuTarget: (image: URL, link: URL?, revision: Int)?
    init(session: BrowserSession, tab: BrowserTab) { self.session = session; self.tab = tab }
    static var presenter: UIViewController? {
        var controller = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController
        while let presented = controller?.presentedViewController { controller = presented }
        return controller
    }
    private var canPresent: Bool { session?.isProfileActive == true && session?.selectedTabID == tab?.id && Self.presenter?.presentedViewController == nil && !(Self.presenter is UIAlertController) }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil, let session, session.isProfileActive, let tab else { return nil }
        return session.addTab(url: navigationAction.request.url, isPrivate: tab.isPrivate, configuration: configuration, load: false).webView
    }
    func webViewDidClose(_ webView: WKWebView) { if let tab { session?.closeTab(tab.id) } }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        guard canPresent else { completionHandler(); return }
        let alert = dialog(message, frame: frame)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() }); Self.presenter?.present(alert, animated: true)
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        guard canPresent else { completionHandler(false); return }
        let alert = dialog(message, frame: frame)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) }); Self.presenter?.present(alert, animated: true)
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) {
        guard canPresent else { completionHandler(nil); return }
        let alert = dialog(prompt, frame: frame); alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(alert.textFields?.first?.text) }); Self.presenter?.present(alert, animated: true)
    }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        guard canPresent, let session, let tab else { decisionHandler(.deny); return }
        var components = URLComponents(); components.scheme = origin.protocol; components.host = origin.host
        if origin.port > 0 { components.port = origin.port }
        let rule = session.settings.rule(for: components.url, isPrivate: tab.isPrivate)
        let blocked = (type != .microphone && rule.camera == .block) || (type != .camera && rule.microphone == .block)
        decisionHandler(blocked ? .deny : .prompt)
    }
    func authenticate(_ challenge: URLAuthenticationChallenge,
                      completion: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard canPresent, challenge.previousFailureCount < 3 else { completion(.cancelAuthenticationChallenge, nil); return }
        let revision = tab?.documentRevision
        let alert = UIAlertController(title: "Sign in to \(challenge.protectionSpace.host)", message: challenge.protectionSpace.protocol == "https" ? "Website sign-in" : "This connection is not encrypted.", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "Username"; $0.textContentType = .username; $0.autocapitalizationType = .none }
        alert.addTextField { $0.placeholder = "Password"; $0.textContentType = .password; $0.isSecureTextEntry = true }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completion(.cancelAuthenticationChallenge, nil) })
        alert.addAction(UIAlertAction(title: "Sign in", style: .default) { [weak self] _ in
            guard self?.tab?.documentRevision == revision else { completion(.cancelAuthenticationChallenge, nil); return }
            completion(.useCredential, URLCredential(user: alert.textFields?[0].text ?? "", password: alert.textFields?[1].text ?? "", persistence: .forSession))
        }); Self.presenter?.present(alert, animated: true)
    }
    private func dialog(_ message: String, frame: WKFrameInfo) -> UIAlertController {
        UIAlertController(title: frame.securityOrigin.host.isEmpty ? "Website message" : frame.securityOrigin.host,
                          message: String(message.prefix(4000)), preferredStyle: .alert)
    }
}

@MainActor @Observable final class MobileDownloads: NSObject, WKDownloadDelegate {
    struct Entry: Identifiable {
        let id: UUID
        var name: String
        var url: URL?
        var status: String
        var isActive = true
        var bytesReceived: Int64 = 0
        var totalBytes: Int64 = 0
    }
    var entries: [Entry] = []
    var activeCount: Int { entries.filter(\.isActive).count }
    var hasActivity: Bool { !entries.isEmpty }
    @ObservationIgnored private var observations: [UUID: [NSKeyValueObservation]] = [:]
    @ObservationIgnored private var active: [ObjectIdentifier: (WKDownload, UUID, URL?)] = [:]
    func begin(_ download: WKDownload) {
        let id = UUID(); entries.insert(Entry(id: id, name: "Download", status: "Starting"), at: 0)
        active[ObjectIdentifier(download)] = (download, id, nil); download.delegate = self
        observations[id] = [download.progress.observe(\.completedUnitCount, options: [.initial, .new]) { [weak self] value, _ in
            let received = value.completedUnitCount, total = value.totalUnitCount
            Task { @MainActor in self?.update(id) { $0.bytesReceived = max(0, received); $0.totalBytes = max(0, total) } }
        }, download.progress.observe(\.totalUnitCount, options: [.initial, .new]) { [weak self] value, _ in
            let total = value.totalUnitCount
            Task { @MainActor in self?.update(id) { $0.totalBytes = max(0, total) } }
        }]
    }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping @MainActor (URL?) -> Void) {
        guard let entry = active[ObjectIdentifier(download)] else { completionHandler(nil); return }
        let name = String(URL(fileURLWithPath: suggestedFilename).lastPathComponent.prefix(160))
        let directory = URL.temporaryDirectory.appendingPathComponent("OrivDownloads/" + entry.1.uuidString)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(name.isEmpty || name == "." || name == ".." ? "download" : name)
            active[ObjectIdentifier(download)] = (download, entry.1, url)
            update(entry.1) { $0.name = url.lastPathComponent; $0.status = "Downloading" }; completionHandler(url)
        } catch { update(entry.1) { $0.status = error.localizedDescription; $0.isActive = false }; completionHandler(nil) }
    }
    func downloadDidFinish(_ download: WKDownload) {
        guard let entry = active.removeValue(forKey: ObjectIdentifier(download)) else { return }
        observations[entry.1] = nil
        update(entry.1) { $0.url = entry.2; $0.status = "Ready to save to Files or share"; $0.isActive = false }
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let entry = active.removeValue(forKey: ObjectIdentifier(download)) else { return }
        observations[entry.1] = nil
        update(entry.1) { $0.status = error.localizedDescription; $0.isActive = false }
    }
    func cancel(_ id: UUID) {
        guard let pair = active.first(where: { $0.value.1 == id }) else { return }
        pair.value.0.cancel { _ in }; active.removeValue(forKey: pair.key); observations[id] = nil; update(id) { $0.status = "Cancelled"; $0.isActive = false }
    }
    private func update(_ id: UUID, change: (inout Entry) -> Void) { if let index = entries.firstIndex(where: { $0.id == id }) { change(&entries[index]) } }
}
