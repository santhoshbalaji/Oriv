import AppKit

/// Test/capture presentation policy. It is inert during ordinary user launches.
/// Native Mac tests enable it in the scheme before the application is initialized.
@MainActor enum BackgroundUIMode {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["ORIV_BACKGROUND_UI"] == "1" }
    static var foregroundApproved: Bool { !isEnabled && ProcessInfo.processInfo.environment["ORIV_FOREGROUND_UI"] == "1" }
    private(set) static var activationViolationCount = 0
    private static var configured = false
    private static var activationObserver: NSObjectProtocol?
    private static var windowObservers: [NSObjectProtocol] = []

    static func configureAtLaunch() {
        guard isEnabled, !configured else { return }
        configured = true
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            activationViolationCount += 1
            application.deactivate()
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            guard pid == ProcessInfo.processInfo.processIdentifier else { return }
            MainActor.assumeIsolated {
                activationViolationCount += 1
                application.deactivate()
                application.windows.forEach { $0.order(.below, relativeTo: 0) }
            }
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                let window = note.object as? NSWindow
                MainActor.assumeIsolated { window?.order(.below, relativeTo: 0) }
            })
        }
    }

    static func present(_ window: NSWindow?, key: Bool = true) {
        guard let window else { return }
        window.ignoresMouseEvents = isEnabled
        if key { window.makeKey() } // Does not activate the application.
        window.order(isEnabled ? .below : .above, relativeTo: 0)
    }
}
