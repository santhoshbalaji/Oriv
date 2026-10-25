import AppKit

/// Native handoff only. Oriv never reads the vault, clipboard credentials or password fields.
@MainActor enum ApplePasswords {
    static func open() {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Passwords") else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }
}
