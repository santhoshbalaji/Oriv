import AppKit
import BrowserCore
import BrowserEngine
import WebKit

/// AppKit adapters stay in the Mac target. iPhone supplies UIKit dialogs and its own web-view wrapper.
@MainActor final class MacWebUIDelegate: NSObject, WKUIDelegate {
    private weak var session: BrowserSession?
    private weak var tab: BrowserTab?

    init(session: BrowserSession, tab: BrowserTab) { self.session = session; self.tab = tab }

    func authenticate(_ challenge: URLAuthenticationChallenge,
                      completion: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let tab, session?.isProfileActive == true, session?.selectedTabID == tab.id, challenge.previousFailureCount < 3,
              let window = tab.webView.window, window.attachedSheet == nil else { completion(.cancelAuthenticationChallenge, nil); return }
        let revision = tab.documentRevision
        let space = challenge.protectionSpace
        let alert = NSAlert(); alert.messageText = "Sign in to \(space.host):\(space.port)"
        alert.informativeText = space.protocol == "https" ? "This website requires a username and password. Credentials are used for this browsing session." : "This website uses an unencrypted connection. Your username and password may be visible on the network."
        let username = NSTextField(), password = NSSecureTextField()
        username.placeholderString = "Username"; password.placeholderString = "Password"
        username.setAccessibilityLabel("Website username"); password.setAccessibilityLabel("Website password")
        let fields = NSStackView(views: [username, password]); fields.orientation = .vertical; fields.spacing = 10
        fields.frame = NSRect(x: 0, y: 0, width: 320, height: 60)
        username.widthAnchor.constraint(equalToConstant: 320).isActive = true
        password.widthAnchor.constraint(equalToConstant: 320).isActive = true
        alert.accessoryView = fields; alert.addButton(withTitle: "Sign in"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak tab] response in
            guard response == .alertFirstButtonReturn, let tab, tab.documentRevision == revision else { completion(.cancelAuthenticationChallenge, nil); return }
            completion(.useCredential, URLCredential(user: username.stringValue, password: password.stringValue, persistence: .forSession))
            password.stringValue = ""
        }
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        var components = URLComponents()
        components.scheme = origin.protocol.lowercased(); components.host = origin.host.lowercased()
        if origin.port > 0 { components.port = origin.port }
        guard let session, session.isProfileActive, let tab, session.selectedTabID == tab.id, webView.window != nil,
              let url = components.url, SiteOrigin(url) != nil else {
            decisionHandler(.deny); return
        }
        let rule = session.settings.rule(for: url, isPrivate: tab.isPrivate)
        let camera = type == .camera || type == .cameraAndMicrophone
        let microphone = type == .microphone || type == .cameraAndMicrophone
        decisionHandler((camera && rule.camera == .block) || (microphone && rule.microphone == .block) ? .deny : .prompt)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil, let session, session.isProfileActive, let tab else { return nil }
        let created = session.addTab(url: navigationAction.request.url, isPrivate: tab.isPrivate,
                                    configuration: configuration, load: false)
        // WebKit loads the original request, preserving POST bodies and opener semantics.
        return created.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let tab { session?.closeTab(tab.id) }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        guard let tab, session?.isProfileActive == true, session?.selectedTabID == tab.id, let window = webView.window,
              window.attachedSheet == nil else { completionHandler(nil); return }
        let revision = tab.documentRevision
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = !parameters.allowsDirectories
        panel.message = "Choose files for \(frame.securityOrigin.host)"
        panel.beginSheetModal(for: window) { [weak tab] result in
            completionHandler(result == .OK && tab?.documentRevision == revision ? panel.urls : nil)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        let alert = dialog(message, frame: frame)
        alert.addButton(withTitle: "OK")
        present(alert, on: webView) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        let alert = dialog(message, frame: frame)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        present(alert, on: webView) { response in completionHandler(response == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor (String?) -> Void) {
        let alert = dialog(prompt, frame: frame)
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        present(alert, on: webView) { result in completionHandler(result == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    private func dialog(_ message: String, frame: WKFrameInfo) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host.isEmpty ? "Website message" : frame.securityOrigin.host
        alert.informativeText = String(message.prefix(4000))
        return alert
    }

    private func present(_ alert: NSAlert, on webView: WKWebView,
                         completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
        guard session?.isProfileActive == true, session?.selectedTabID == tab?.id, let window = webView.window, window.attachedSheet == nil else {
            completion(.cancel); return
        }
        alert.beginSheetModal(for: window, completionHandler: completion)
    }
}
