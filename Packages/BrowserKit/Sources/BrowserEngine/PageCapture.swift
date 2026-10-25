import Foundation
import ProductivityKit
import WebKit

public enum PageCaptureService {
    /// User-initiated, main-document extraction. Never reads input values, storage, cookies or other tabs.
    @MainActor public static func capture(_ tab: BrowserTab) async throws -> PageCapture {
        guard !tab.isPrivate else { throw WorkspaceError.unavailable("Private pages aren’t saved to the workspace.") }
        guard let url = tab.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), !tab.isLoading else {
            throw WorkspaceError.unavailable("Wait for the page to finish loading, then save it.")
        }
        let revision = tab.documentRevision
        let result: [String: Any]
        do {
            result = try await tab.webView.callAsyncJavaScript(script, arguments: [:], in: nil,
                contentWorld: .defaultClient) as? [String: Any] ?? [:]
        } catch {
            guard tab.url == url, tab.documentRevision == revision, !tab.isLoading else {
                throw WorkspaceError.unavailable("The page changed during capture. Save the current page again.")
            }
            return PageCapture(url: url, title: tab.displayTitle, explanation: "Readable text wasn’t available. You can still save the link and a note.")
        }
        guard tab.url == url, tab.documentRevision == revision, !tab.isLoading,
              result["url"] as? String == url.absoluteString else {
            throw WorkspaceError.unavailable("The page changed during capture. Save the current page again.")
        }
        let text = result["text"] as? String ?? ""
        let selection = result["selection"] as? String ?? ""
        let partial = result["partial"] as? Bool ?? false
        return PageCapture(url: url, title: tab.displayTitle, text: text, selection: selection,
            kind: text.isEmpty ? .link : partial ? .partial : .readable,
            explanation: text.isEmpty ? "No readable text was found. Save the link or add your own context."
                : partial ? "Some content was omitted or the capture reached its size limit. Review the saved text."
                : "Text from the loaded page. Images, embedded pages and form fields aren’t included.")
    }

    static let script = #"""
    const limit = 60000;
    const root = document.querySelector('article') || document.querySelector('main') || document.body;
    if (!root) return {url: location.href, text: '', selection: '', partial: true};
    const excluded = 'script,style,noscript,template,input,textarea,select,button,form,[contenteditable]:not([contenteditable="false"]),[hidden],[aria-hidden="true"],iframe,nav,header,footer,svg,canvas';
    let length = 0, visited = 0, partial = false;
    const parts = [];
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    let node;
    while ((node = walker.nextNode())) {
        if (++visited > 18000) { partial = true; break; }
        const parent = node.parentElement;
        if (!parent || parent.closest(excluded)) continue;
        const style = getComputedStyle(parent);
        if (style.visibility === 'hidden' || style.display === 'none' || !parent.getClientRects().length) continue;
        const text = node.textContent.replace(/\s+/g, ' ').trim();
        if (!text) continue;
        if (length + text.length > limit) { partial = true; break; }
        parts.push(text); length += text.length + 1;
    }
    let selection = '';
    const selected = window.getSelection();
    if (selected && selected.rangeCount) {
        const range = selected.getRangeAt(0);
        const start = range.startContainer.nodeType === 1 ? range.startContainer : range.startContainer.parentElement;
        const end = range.endContainer.nodeType === 1 ? range.endContainer : range.endContainer.parentElement;
        const fragment = range.cloneContents();
        if (start && end && !start.closest(excluded) && !end.closest(excluded) && !fragment.querySelector(excluded)) {
            selection = selected.toString().slice(0, limit);
        }
    }
    if (root.querySelector('iframe,canvas')) partial = true;
    return {url: location.href, text: parts.join('\n\n'), selection, partial};
    """#
}
