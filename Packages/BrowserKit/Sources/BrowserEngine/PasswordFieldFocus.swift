#if os(macOS)
import WebKit

/// Ephemeral focus metadata from an isolated world. Never inspect field contents.
@MainActor @Observable
public final class PasswordFieldFocus: NSObject, WKScriptMessageHandler {
    public enum Kind: String {
        case username, password, newPassword, otp

        public var supportsPasswordFill: Bool { self == .username || self == .password }
    }

    public private(set) var kind: Kind?
    public private(set) var showsGlyph = false
    public private(set) var glyphRequest = 0
    private var frame: WKFrameInfo?
    private var origin: String?
    private let ownsWebView: (WKWebView) -> Bool

    static let world: WKContentWorld = {
        #if compiler(>=6.4)
        if #available(macOS 27.0, *) {
            let configuration = WKContentWorld.Configuration()
            configuration.autofillScriptingEnabled = true
            return WKContentWorld(configuration: configuration)
        }
        #endif
        return .world(name: "OrivPasswordFields")
    }()

    init(ownsWebView: @escaping (WKWebView) -> Bool) {
        self.ownsWebView = ownsWebView
    }

    func install(in controller: WKUserContentController) {
        for name in ["passwordFieldFocus", "passwordFieldGlyphFocus", "passwordFieldGlyphClick"] {
            controller.add(self, contentWorld: Self.world, name: name)
        }
        // Popup configurations can inherit the opener's user scripts.
        if !controller.userScripts.contains(where: { $0.source == Self.script }) {
            controller.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: false, in: Self.world))
        }
    }

    /// Closed tabs drop their handlers and the retained frame so the
    /// configuration's controller and the page can release immediately.
    func uninstall(from controller: WKUserContentController) {
        for name in ["passwordFieldFocus", "passwordFieldGlyphFocus", "passwordFieldGlyphClick"] {
            controller.removeScriptMessageHandler(forName: name, contentWorld: Self.world)
        }
        reset()
    }

    func reset() {
        kind = nil
        showsGlyph = false
        frame = nil
        origin = nil
    }

    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let webView = message.webView, ownsWebView(webView),
              let body = message.body as? [String: Any], body.count == 2,
              let origin = body["frame"] as? String else { return }
        let kind = (body["kind"] as? String).flatMap(Kind.init(rawValue:))
        if message.name == "passwordFieldGlyphClick" {
            guard kind?.supportsPasswordFill == true else { return }
            update(kind, in: message.frameInfo, origin: origin, showsGlyph: true)
            glyphRequest += 1
        } else if let kind {
            update(kind, in: message.frameInfo, origin: origin, showsGlyph: message.name == "passwordFieldGlyphFocus")
        } else if body["kind"] is NSNull, self.origin == origin,
                  frame?.isMainFrame == message.frameInfo.isMainFrame,
                  frame?.request.url == message.frameInfo.request.url {
            reset()
        }
    }

    private func update(_ kind: Kind?, in frame: WKFrameInfo, origin: String, showsGlyph: Bool) {
        self.kind = kind
        self.frame = frame
        self.origin = origin
        self.showsGlyph = showsGlyph
    }

    /// Recheck the exact focused element after moving the native responder back
    /// to WebKit. A removed field, changed type, or detached frame fails closed.
    public func canRequestPicker(in webView: WKWebView) async -> Bool {
        guard ownsWebView(webView), let kind, kind.supportsPasswordFill, let frame else { return false }
        let result = try? await webView.callAsyncJavaScript(
            "return window.orivPasswordFieldMatches?.(kind) === true;",
            arguments: ["kind": kind.rawValue], in: frame, contentWorld: Self.world)
        return result as? Bool == true && ownsWebView(webView) && self.frame === frame
    }

    static let script = #"""
    (() => {
        const handlers = window.webkit.messageHandlers;
        const frame = location.origin;
        const glyphAvailable = "autofillButtonType" in HTMLInputElement.prototype;
        let focused = null;

        function activeInput() {
            let element = document.activeElement;
            while (element?.shadowRoot?.activeElement)
                element = element.shadowRoot.activeElement;
            return element;
        }

        function classify(input) {
            if (!(input instanceof HTMLInputElement) || input.matches(":disabled") || input.readOnly)
                return null;
            const tokens = input.autocomplete.toLowerCase().split(/\s+/);
            if (input.type === "password")
                return tokens.includes("new-password") ? "newPassword" : "password";
            if (!["text", "email", "tel", "number"].includes(input.type))
                return null;
            if (tokens.includes("one-time-code")) return "otp";
            if (tokens.includes("username")) return "username";
            if (input.type !== "text" && input.type !== "email") return null;
            if (tokens.some(token => token && !["on", "off", "email"].includes(token))) return null;
            const fields = Array.from(input.form?.elements ?? []);
            return fields.some(field => field instanceof HTMLInputElement && field.type === "password" &&
                !field.autocomplete.toLowerCase().split(/\s+/).includes("new-password")) ? "username" : null;
        }

        function post(handler, kind) {
            handler.postMessage({kind, frame});
        }

        function clear() {
            if (focused && glyphAvailable && focused.autofillButtonType === "credentials")
                focused.autofillButtonType = "none";
            focused = null;
        }

        function update() {
            clear();
            const input = activeInput();
            const kind = classify(input);
            if (!kind) {
                post(handlers.passwordFieldFocus, null);
                return;
            }
            focused = input;
            if (glyphAvailable && (kind === "username" || kind === "password")) {
                input.autofillButtonType = "credentials";
                if (input.autofillButtonType === "credentials") {
                    post(handlers.passwordFieldGlyphFocus, kind);
                    return;
                }
            }
            post(handlers.passwordFieldFocus, kind);
        }

        window.orivPasswordFieldMatches = kind =>
            !!focused && (window === window.top || document.hasFocus()) &&
                activeInput() === focused && classify(focused) === kind;
        document.addEventListener("focusin", update, true);
        document.addEventListener("focusout", () => {
            if (!focused) return;
            clear();
            post(handlers.passwordFieldFocus, null);
        }, true);
        document.addEventListener("webkitautofillrequest", event => {
            if (!event.isTrusted || !focused || !event.composedPath().includes(focused) ||
                focused.autofillButtonType !== "credentials") return;
            const kind = classify(focused);
            if (kind === "username" || kind === "password")
                post(handlers.passwordFieldGlyphClick, kind);
        }, true);
        window.addEventListener("pageshow", update);
    })();
    """#
}
#endif
