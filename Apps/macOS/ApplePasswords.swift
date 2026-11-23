import AppKit
import BrowserEngine
import WebKit

/// Tests can observe the handoff without interacting with macOS Passwords.
@MainActor protocol PasswordPickerRequesting {
    func requestPicker(in webView: WKWebView) -> Bool
}

@MainActor struct AppKitPasswordPicker: PasswordPickerRequesting {
    func requestPicker(in webView: WKWebView) -> Bool {
        guard !BackgroundUIMode.isEnabled, NSApp.isActive,
              let window = webView.window, window === NSApp.keyWindow,
              let item = ApplePasswords.enabledPasswordsItem(in: NSApp.mainMenu),
              ApplePasswords.webViewHasResponder(webView, in: window),
              let action = item.action else { return false }
        // Use the discovered item's action and target through AppKit's responder
        // routing. AppKit reports dispatch, while the system owns picker UI.
        return NSApp.sendAction(action, to: item.target, from: item)
    }
}

/// Native handoff only. Oriv never reads the vault, clipboard credentials or password fields.
@MainActor enum ApplePasswords {
    /// This identifier is menu metadata observed on macOS. The menu placement
    /// can change, so look it up each time and keep the native field-menu fallback.
    static func autoFillSubmenu(in mainMenu: NSMenu?) -> NSMenu? {
        for edit in mainMenu?.items.compactMap(\.submenu) ?? [] {
            if let item = edit.items.first(where: {
                $0.identifier?.rawValue == "_NSMenuItemAutoFillIdentifier" || $0.title == "AutoFill"
            }), let submenu = item.submenu {
                submenu.update()
                return submenu
            }
        }
        return nil
    }

    static func passwordsItem(in menu: NSMenu) -> NSMenuItem? {
        menu.items.first { $0.title == "Passwords…" || $0.title == "Passwords..." }
    }

    static func enabledPasswordsItem(in mainMenu: NSMenu?) -> NSMenuItem? {
        guard let menu = autoFillSubmenu(in: mainMenu),
              let item = passwordsItem(in: menu), item.isEnabled, !item.isHidden else { return nil }
        return item
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
        return picker.requestPicker(in: webView)
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
