import AppKit

/// Opt-in UI policy shared by the Mac test host and visual capture app.
/// Foreground UI is a separate, explicit test-run permission; normal app usage
/// without either environment variable retains its usual window behaviour.
@MainActor enum BackgroundUIMode {
    static var foregroundAllowed: Bool { ProcessInfo.processInfo.environment["ORIV_FOREGROUND_UI"] == "1" }
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["ORIV_BACKGROUND_UI"] == "1" && !foregroundAllowed
    }
    static let foregroundOnlyReason = "Foreground-only UI check: requires an active, unoccluded app or a system full-screen/menu transition. Background mode skips it; ORIV_FOREGROUND_UI=1 requires orchestrator approval."

    struct Audit: Encodable {
        let enabled: Bool
        let foregroundAllowed: Bool
        let accessory: Bool
        let samples: Int
        let frontmostViolations: Int
        let activationViolations: Int
        let windowFrameSamples: Int
        let onscreenWindowViolations: Int
        let overlappingWindows: [String]
        let hiddenAuxiliaryRelocations: Int
    }
    struct WindowReport: Encodable {
        let name: String
        let windowID: Int
        let pid: Int32
        let key: Bool
        let occluded: Bool
        let layerBacked: Bool
        let appActive: Bool
        let frontmostIsTestApp: Bool
        let simulatedFullscreenLayout: Bool
        let frame: String
        let outsideAllScreens: Bool
    }
    static func report(_ window: NSWindow, name: String, simulatedFullscreenLayout: Bool = false) -> WindowReport {
        checkFrontmost()
        return WindowReport(name: name, windowID: window.windowNumber, pid: ProcessInfo.processInfo.processIdentifier,
            key: window.isKeyWindow, occluded: !window.occlusionState.contains(.visible),
            layerBacked: window.contentView?.wantsLayer ?? false, appActive: NSApp.isActive,
            frontmostIsTestApp: NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
            simulatedFullscreenLayout: simulatedFullscreenLayout, frame: NSStringFromRect(window.frame),
            outsideAllScreens: isOutsideAllScreens(window.frame))
    }
    /// Only test-owned windows use this subclass. AppKit cannot constrain them
    /// back onto a display, even after a resize, key request or screen change.
    class Window: NSWindow {
        override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask,
                      backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
            super.init(contentRect: isEnabled ? offscreenRect(contentRect) : contentRect,
                styleMask: style, backing: backingStoreType, defer: flag)
            if isEnabled { setFrame(offscreenRect(frame), display: false) }
        }
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
            isEnabled ? offscreenRect(frameRect) : super.constrainFrameRect(frameRect, to: screen)
        }
        override func setFrame(_ frameRect: NSRect, display flag: Bool) {
            super.setFrame(isEnabled ? offscreenRect(frameRect) : frameRect, display: flag)
        }
        override func setFrame(_ frameRect: NSRect, display flag: Bool, animate: Bool) {
            super.setFrame(isEnabled ? offscreenRect(frameRect) : frameRect, display: flag, animate: isEnabled ? false : animate)
        }
        override func setFrameOrigin(_ point: NSPoint) {
            super.setFrameOrigin(isEnabled ? offscreenRect(frame).origin : point)
        }
        override func setFrameTopLeftPoint(_ point: NSPoint) {
            if isEnabled { super.setFrameOrigin(offscreenRect(frame).origin) }
            else { super.setFrameTopLeftPoint(point) }
        }
    }
    static func isOutsideAllScreens(_ frame: NSRect) -> Bool {
        NSScreen.screens.allSatisfy { !$0.frame.intersects(frame) }
    }
    private static func offscreenRect(_ frame: NSRect) -> NSRect {
        let displays = NSScreen.screens.reduce(NSRect.null) { $0.union($1.frame) }
        return NSRect(origin: NSPoint(x: (displays.isNull ? 0 : displays.maxX) + 20_000,
                                     y: displays.isNull ? 0 : displays.minY), size: frame.size)
    }
    private final class CoverWindow: Window {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }
    /// A test-owned opaque cover, off every display, proves ID capture of
    /// an actually occluded target. It is never the window captured by the bridge.
    static func makeCover(for window: NSWindow) -> NSWindow? {
        guard isEnabled else { return nil }
        let cover = CoverWindow(contentRect: window.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        cover.isReleasedWhenClosed = false
        cover.ignoresMouseEvents = true
        cover.backgroundColor = .black
        cover.isOpaque = true
        cover.contentView?.wantsLayer = true
        cover.order(.below, relativeTo: 0)
        window.order(.below, relativeTo: cover.windowNumber)
        checkFrontmost()
        return cover
    }
    private static var installed = false
    private static var observers: [NSObjectProtocol] = []
    private static var activationObserver: NSObjectProtocol?
    private static var sampleTimer: Timer?
    private static var samples = 0
    private static var frontmostViolations = 0
    private static var activationViolations = 0
    private static var windowFrameSamples = 0
    private static var onscreenWindowViolations = 0
    private static var overlappingWindows: [String] = []
    private static var hiddenAuxiliaryRelocations = 0
    private static var checking = false

    /// Called from App.init and willFinishLaunching, before SwiftUI shows scenes.
    static func installAtLaunch() {
        guard isEnabled else { return }
        if NSApplication.shared.activationPolicy() != .accessory { NSApplication.shared.setActivationPolicy(.accessory) }
        guard !installed else { return }
        installed = true
        checkFrontmost()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { notification in
            let activatedPID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                if activatedPID == ProcessInfo.processInfo.processIdentifier {
                    frontmostViolations += 1
                }
                checkFrontmost()
            }
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: NSApp, queue: .main
        ) { _ in MainActor.assumeIsolated { activationViolations += 1; checkFrontmost() } })
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                let window = note.object as? NSWindow
                MainActor.assumeIsolated { window?.order(.below, relativeTo: 0); checkFrontmost() }
            })
        }
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didUpdateNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { checkFrontmost() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated {
            for window in NSApp.windows { window.setFrame(offscreenRect(window.frame), display: false) }
            checkFrontmost()
        } })
        // Sample throughout captures, including waits for WebKit and the PNG bridge.
        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
            Task { @MainActor in checkFrontmost() }
        }
        sampleTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    static func checkFrontmost() {
        guard isEnabled, !checking else { return }
        checking = true
        defer { checking = false }
        samples += 1
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            frontmostViolations += 1
        }
        for window in NSApp.windows {
            // SwiftUI can allocate a hidden layout/measurement window itself.
            // Place it before it is ever ordered; no framework class inspection
            // or private window APIs are needed.
            if !window.isVisible && !isOutsideAllScreens(window.frame) {
                window.setFrame(offscreenRect(window.frame), display: false)
                hiddenAuxiliaryRelocations += 1
            }
            windowFrameSamples += 1
            if !isOutsideAllScreens(window.frame) {
                onscreenWindowViolations += 1
                let detail = "\(String(describing: type(of: window))) \(NSStringFromRect(window.frame)) visible=\(window.isVisible)"
                if overlappingWindows.count < 20 && !overlappingWindows.contains(detail) { overlappingWindows.append(detail) }
                window.orderOut(nil)
                window.setFrame(offscreenRect(window.frame), display: false)
            }
        }
    }
    static func audit() -> Audit {
        checkFrontmost()
        return Audit(enabled: isEnabled, foregroundAllowed: foregroundAllowed,
            accessory: NSApp.activationPolicy() == .accessory, samples: samples,
            frontmostViolations: frontmostViolations, activationViolations: activationViolations,
            windowFrameSamples: windowFrameSamples, onscreenWindowViolations: onscreenWindowViolations,
            overlappingWindows: overlappingWindows, hiddenAuxiliaryRelocations: hiddenAuxiliaryRelocations)
    }

    /// Background key windows are allowed; they never activate or move forward.
    static func show(_ window: NSWindow, key: Bool = true, activate: Bool = false) {
        if isEnabled {
            installAtLaunch()
            window.hidesOnDeactivate = false
            window.ignoresMouseEvents = true
            window.isExcludedFromWindowsMenu = true
            window.collectionBehavior.remove(.moveToActiveSpace)
            window.contentView?.wantsLayer = true
            window.setFrame(offscreenRect(window.frame), display: false)
            window.order(.below, relativeTo: 0)
            if key { window.makeKey() }
            window.order(.below, relativeTo: 0)
            window.displayIfNeeded()
            checkFrontmost()
            return
        }
        if activate { NSApp.activate(ignoringOtherApps: true) }
        if key { window.makeKeyAndOrderFront(nil) }
        else { window.orderFrontRegardless() }
    }

    static func showBrowserWindow(_ window: NSWindow?) {
        guard let window else { return }
        show(window)
    }
}
