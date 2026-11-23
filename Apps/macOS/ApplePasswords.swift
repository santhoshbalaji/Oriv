import AppKit
import BrowserEngine
import WebKit

/// Tests can observe the handoff without interacting with macOS Passwords.
@MainActor protocol PasswordPickerRequesting {
    func requestPicker(in webView: WKWebView) async -> Bool
}

@MainActor struct AppKitPasswordPicker: PasswordPickerRequesting {
    func requestPicker(in webView: WKWebView) async -> Bool {
        guard !BackgroundUIMode.isEnabled, NSApp.isActive,
              let view = webView as? PasswordContextWebView,
              let window = view.window, window === NSApp.keyWindow,
              ApplePasswords.webViewHasResponder(view, in: window) else { return false }
        return await view.requestFocusedFieldMenu()
    }
}

@MainActor final class PasswordContextWebView: WKWebView {
    private struct MenuRequest {
        let id = UUID()
        let result: CheckedContinuation<Bool, Never>
    }

    private var pendingMenu: MenuRequest?
    private weak var openedMenu: NSMenu?
    private var openedMenuID: UUID?

    func requestFocusedFieldMenu() async -> Bool {
        guard pendingMenu == nil else { return false }
        return await withCheckedContinuation { result in
            let request = MenuRequest(result: result)
            pendingMenu = request
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, self.pendingMenu?.id == request.id else { return }
                self.pendingMenu = nil
                request.result.resume(returning: false)
            }
            // WebKit locates the focused element in its own frame, accounting
            // for scroll and zoom. The native menu retains the field context.
            showContextMenuForSelection(nil)
        }
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        guard let request = pendingMenu else { return }
        pendingMenu = nil
        guard let window, window === NSApp.keyWindow,
              ApplePasswords.webViewHasResponder(self, in: window) else {
            request.result.resume(returning: false)
            return
        }
        openedMenu = menu
        openedMenuID = request.id
        request.result.resume(returning: true)

        // AppKit can supply AutoFill as a contextual addition that is absent
        // from WebKit's NSMenu. Keep tracking the native menu in that case.
        let id = request.id
        RunLoop.main.perform(inModes: [.eventTracking]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.openedMenuID == id, let menu = self.openedMenu,
                      let window = self.window, window === NSApp.keyWindow, NSApp.isActive,
                      ApplePasswords.webViewHasResponder(self, in: window),
                      let item = ApplePasswords.passwordsItem(in: menu), let submenu = item.menu else { return }
                let index = submenu.index(of: item)
                guard index >= 0 else { return }
                menu.cancelTrackingWithoutAnimation()
                submenu.performActionForItem(at: index)
            }
        }
    }

    override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
        if openedMenu === menu {
            openedMenu = nil
            openedMenuID = nil
        }
        super.didCloseMenu(menu, with: event)
    }
}

/// Native handoff only. Oriv never reads the vault, clipboard credentials or password fields.
@MainActor enum ApplePasswords {
    static func passwordsItem(in contextMenu: NSMenu) -> NSMenuItem? {
        let autoFill = contextMenu.items.first {
            !$0.isHidden && $0.isEnabled && $0.submenu != nil &&
                ($0.identifier?.rawValue == "_NSMenuItemAutoFillIdentifier" || $0.title == "AutoFill")
        }
        return autoFill?.submenu?.items.first {
            !$0.isHidden && $0.isEnabled && $0.action != nil && $0.submenu == nil &&
                ($0.title == "Passwords…" || $0.title == "Passwords...")
        }
    }

    static func requestFill(in tab: BrowserTab, window: NSWindow, picker: any PasswordPickerRequesting,
                            stillSelected: () -> Bool) async -> Bool {
        guard tab.isInstantiated else { return false }
        let webView = tab.webView
        guard webView.window === window else { return false }
        if !webViewHasResponder(webView, in: window), !window.makeFirstResponder(webView) { return false }
        guard await tab.passwordFields.canRequestPicker(in: webView),
              stillSelected(), webView.window === window,
              webViewHasResponder(webView, in: window) else { return false }
        return await picker.requestPicker(in: webView)
    }

    fileprivate static func webViewHasResponder(_ webView: WKWebView, in window: NSWindow) -> Bool {
        guard let responder = window.firstResponder as? NSView else { return false }
        return responder === webView || responder.isDescendant(of: webView)
    }

    static func open() {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Passwords") else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }
}
