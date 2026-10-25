import AppKit
import BrowserEngine
import WebKit

/// AppKit adapters stay in the Mac target. iPhone will supply its own dialogs and web-view wrapper.
@MainActor final class MacWebUIDelegate: NSObject, WKUIDelegate {
    private weak var session: BrowserSession?
    private weak var tab: BrowserTab?

    init(session: BrowserSession, tab: BrowserTab) { self.session = session; self.tab = tab }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil, let session, let tab else { return nil }
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
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = !parameters.allowsDirectories
        panel.message = "Choose files for \(frame.securityOrigin.host)"
        if let window = webView.window {
            panel.beginSheetModal(for: window) { result in completionHandler(result == .OK ? panel.urls : nil) }
        } else { completionHandler(panel.runModal() == .OK ? panel.urls : nil) }
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
        if let window = webView.window { alert.beginSheetModal(for: window, completionHandler: completion) }
        else { completion(alert.runModal()) }
    }
}
