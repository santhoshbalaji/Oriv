#if DEBUG
import AppKit
import BrowserCore
import BrowserEngine
import CryptoKit
import SwiftUI
import WebKit

/// Debug-only visual evidence. Renders the real browser views with synthetic data into PNG
/// files plus a manifest, then exits (status 0 only when every scene was written). It runs only
/// when BROWSER_TESTING=1 (ephemeral profiles, no persisted browsing data) and
/// ORIV_VISUAL_SNAPSHOTS=1 are both set. Images go to the sandbox container's temporary
/// directory (OrivVisualSnapshots); scripts/capture-mac-visuals.sh validates and copies them.
/// ORIV_SNAPSHOT_ACTIVATE=1 makes the app frontmost so windows render in their active (key)
/// state. Release builds do not contain this file.
@MainActor enum VisualSnapshots {
    static var directory: URL? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["BROWSER_TESTING"] == "1", environment["ORIV_VISUAL_SNAPSHOTS"] == "1" else { return nil }
        guard let runID = environment["ORIV_SNAPSHOT_RUN_ID"], !runID.isEmpty,
              runID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return nil }
        return FileManager.default.temporaryDirectory.appendingPathComponent("OrivVisualSnapshots", isDirectory: true)
            .appendingPathComponent(runID, isDirectory: true)
    }

    private struct Scene: Encodable { let name: String; let file: String; let width: Int; let height: Int; let sha256: String; let keyWindow: Bool; let note: String? }
    private struct Manifest: Encodable {
        let runID: String; let startedAt: Date; var finishedAt: Date?; let osVersion: String
        let configuration = "Debug"; let activated: Bool
        var scenes: [Scene] = []; var failures: [String] = []; var limitations: [String] = []
    }
    private static var manifest: Manifest!

    static func run(into directory: URL) async {
        let environment = ProcessInfo.processInfo.environment
        let activate = environment["ORIV_SNAPSHOT_ACTIVATE"] == "1"
        manifest = Manifest(runID: environment["ORIV_SNAPSHOT_RUN_ID"] ?? "unspecified", startedAt: Date(),
                            osVersion: ProcessInfo.processInfo.operatingSystemVersionString, activated: activate)
        do {
            guard !FileManager.default.fileExists(atPath: directory.path) else {
                fputs("snapshot run directory already exists; refusing to overwrite it\n", stderr); exit(2)
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            fputs("snapshot directory unavailable: \(error)\n", stderr); exit(2)
        }
        if activate { NSApp.activate() }
        await renderScenes(into: directory, activate: activate)
        manifest.finishedAt = Date()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do { try encoder.encode(manifest).write(to: directory.appendingPathComponent("manifest.json")) }
        catch { fputs("manifest write failed: \(error)\n", stderr); exit(3) }
        exit(manifest.failures.isEmpty ? 0 : 1)
    }

    private static func renderScenes(into directory: URL, activate: Bool) async {
        // Pure UI classification assertions; no network or engine mutation is needed.
        let mixed = ConnectionCue(scheme: "https", secure: false, onlySecureContent: false, loading: false)
        if mixed != .mixedContent || mixed.symbol != "exclamationmark.shield" || mixed.label != "Some content isn't secure"
            || ConnectionCue(scheme: "http", secure: false, onlySecureContent: false, loading: false) != .notSecure
            || ConnectionCue(scheme: "https", secure: false, onlySecureContent: false, loading: true) != .information
            || ConnectionCue(scheme: "https", secure: true, onlySecureContent: true, loading: false) != .encrypted {
            manifest.failures.append("connection cue classification failed")
        }
        let size = CGSize(width: 1250, height: 820)
        let populated = seededProfiles()
        await capture("mac-01-start", directory, size, key: activate, expectedFields: ["addressField": ""]) { BrowserWindow(controller: populated.controller, profiles: populated) }

        let empty = BrowserProfiles(testing: true)
        await capture("mac-02-start-empty", directory, size, key: activate) { BrowserWindow(controller: empty.controller, profiles: empty) }

        let privateProfiles = seededProfiles()
        privateProfiles.controller.newTab(isPrivate: true)
        await capture("mac-03-private-start", directory, size, key: activate) { BrowserWindow(controller: privateProfiles.controller, profiles: privateProfiles) }

        let compact = seededProfiles()
        compact.controller.compactSidebar = true
        await capture("mac-04-compact-sidebar", directory, size, key: activate) { BrowserWindow(controller: compact.controller, profiles: compact) }

        if activate {
            let inactive = seededProfiles()
            await capture("mac-05-start-inactive-window", directory, size, key: false) { BrowserWindow(controller: inactive.controller, profiles: inactive) }
        }

        for (scheme, name) in [("https", "mac-06-loaded-https"), ("http", "mac-07-loaded-http")] {
            let loaded = seededProfiles()
            let tab = loaded.controller.session.addTab(url: nil, select: true, load: false)
            tab.webView.loadHTMLString(fixturePage(scheme: scheme), baseURL: URL(string: "\(scheme)://fixture.example/articles/visual-check"))
            // Let the page commit first, so the window opens on a loaded tab rather than focusing a blank address field.
            try? await Task.sleep(for: .milliseconds(800))
            await capture(name, directory, size, key: activate, settle: 1_800, compositeWeb: tab.webView) {
                BrowserWindow(controller: loaded.controller, profiles: loaded)
            }
        }

        let suggestionProfiles = seededProfiles()
        let session = suggestionProfiles.controller.session
        for (query, index, name) in [("dev", 1, "mac-08-suggestions-keyboard"), ("docs", nil, "mac-09-suggestions-similar")] as [(String, Int?, String)] {
            await capture(name, directory, CGSize(width: 760, height: 320), key: activate) {
                AddressSuggestionList(suggestions: session.suggestions(for: query, isPrivate: false), selectedIndex: index,
                                      address: query, engine: session.settings.searchEngine, isPrivate: false,
                                      choose: { _ in }, submit: {})
                    .frame(width: 720).padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .background(Theme.t3Code.canvas)
            }
        }

        for section in [LibrarySection.bookmarks, .history, .devices] {
            let profiles = seededProfiles()
            await capture("mac-10-library-\(section.id.lowercased().replacingOccurrences(of: " ", with: "-"))", directory, CGSize(width: 760, height: 540), key: activate) {
                LibraryView(controller: profiles.controller, profiles: profiles, section: section)
            }
        }
        for pane in SettingsPane.allCases {
            let settings = seededProfiles()
            await capture("mac-11-settings-\(pane.rawValue)", directory, CGSize(width: 640, height: 580), key: activate,
                          settle: pane == .passwords ? 1_800 : 900, toolbarStyle: .preference,
                          expectedFields: pane == .continuity ? ["continuityDeviceName": settings.continuity.state.deviceName] : [:]) {
                AppearanceSettings(appearance: .constant(.t3Code), controller: settings.controller, profiles: settings, initialPane: pane)
            }
        }
    }

    private static func fixturePage(scheme: String) -> String {
        """
        <!doctype html><html><head><meta name=viewport content="width=device-width"><title>Visual check article</title>
        <style>body{font:16px -apple-system,system-ui;max-width:680px;margin:48px auto;padding:0 24px;color:#1d1d1f;background:#fff;line-height:1.5}
        h1{font-size:32px;margin:0 0 8px}p.meta{color:#6e6e73;margin:0 0 24px}a{color:#0a58ca}</style></head>
        <body><h1>Visual check article</h1><p class=meta>Local fixture served as \(scheme)://fixture.example</p>
        <p>This synthetic page exists only so the browser chrome can be captured around real web content. No network request is made.</p>
        <p>Second paragraph with a <a href="#">sample link</a> to show link colour inside the page.</p></body></html>
        """
    }

    private static func seededProfiles() -> BrowserProfiles {
        let profiles = BrowserProfiles(testing: true)
        let session = profiles.controller.session
        let now = Date()
        let sites: [(String, String)] = [
            ("Apple Developer", "https://developer.apple.com/documentation/"),
            ("WebKit", "https://webkit.org/blog/"),
            ("Swift.org", "https://www.swift.org/documentation/"),
            ("Wikipedia, the free encyclopedia", "https://en.wikipedia.org/wiki/Main_Page"),
            ("GitHub", "https://github.com/"),
            ("Hacker News", "https://news.ycombinator.com/"),
            ("MDN Web Docs", "https://developer.mozilla.org/en-US/"),
            ("Example Domain", "https://example.com/")
        ]
        // Same-titled pages that differ only by path or query, for the disambiguation check.
        let lookalikes: [(String, String)] = [
            ("Docs", "https://docs.example.com/guide/install"),
            ("Docs", "https://docs.example.com/guide/upgrade"),
            ("Docs", "https://docs.example.com/search?q=tabs"),
            ("Docs", "https://docs.example.com/search?q=privacy")
        ]
        let bookmarks = sites.prefix(5).enumerated().map { index, site in
            Bookmark(title: site.0, url: URL(string: site.1)!, createdAt: now.addingTimeInterval(Double(index)))
        }
        let history = (sites.reversed() + lookalikes).enumerated().map { index, site in
            HistoryEntry(title: site.0, url: URL(string: site.1)!, visitedAt: now.addingTimeInterval(Double(-index * 600)))
        }
        do { try session.applyContinuity(bookmarks: Array(bookmarks), history: history) }
        catch { manifest.failures.append("seed data: \(error)") }
        for site in sites.prefix(6) { session.addTab(url: URL(string: site.1)!, select: false, load: false) }
        if let first = session.tabs.dropFirst().first { session.togglePinned(first.id) }
        return profiles
    }

    private static func capture<Content: View>(_ name: String, _ directory: URL, _ size: CGSize, key: Bool, settle: Int = 900,
                                               compositeWeb webView: WKWebView? = nil, toolbarStyle: NSWindow.ToolbarStyle = .unified,
                                               expectedFields: [String: String] = [:],
                                               @ViewBuilder content: () -> Content) async {
        let hosting = NSHostingController(rootView: content().browserAppearance(.t3Code))
        hosting.sceneBridgingOptions = [.toolbars, .title]
        let window = OffscreenWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = toolbarStyle
        window.contentViewController = hosting
        window.setContentSize(size)
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        if key {
            // Closing the previous key window can deactivate the app, so activate for every scene.
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        } else { window.orderFrontRegardless() }
        defer { window.orderOut(nil); window.close() }
        try? await Task.sleep(for: .milliseconds(settle))
        var attempts = 0
        while key && !window.isKeyWindow && attempts < 20 {
            attempts += 1
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(150))
        }
        window.displayIfNeeded()
        if key && !window.isKeyWindow { manifest.failures.append("\(name): requested an active window but it did not become key") }
        guard let frame = window.contentView?.superview,
              let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else {
            manifest.failures.append("\(name): no window frame to render"); return
        }
        func fields(in view: NSView) -> [NSTextField] {
            ((view as? NSTextField).map { [$0] } ?? []) + view.subviews.flatMap { fields(in: $0) }
        }
        for (identifier, expected) in expectedFields {
            let matches = fields(in: frame).filter { $0.accessibilityIdentifier() == identifier }
            // SwiftUI's macOS 27 Form editor may be an NSTextView rather than NSTextField.
            let actual = matches.count == 1 ? matches.first?.stringValue : (window.firstResponder as? NSTextView)?.string
            if actual != expected {
                manifest.failures.append("\(name): \(identifier) missing or contaminated (expected \(expected.debugDescription), actual \(actual.debugDescription))")
            }
        }
        frame.layoutSubtreeIfNeeded()
        frame.needsDisplay = true
        hosting.view.needsDisplay = true
        window.display()
        let capturedKeyWindow = window.isKeyWindow
        frame.cacheDisplay(in: frame.bounds, to: bitmap)
        var note: String?
        if let webView {
            if webView.window === window, let image = try? await webView.takeSnapshot(configuration: nil) {
                let rect = webView.convert(webView.bounds, to: frame)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                image.draw(in: rect)
                NSGraphicsContext.restoreGraphicsState()
                note = "web content composited from WKWebView.takeSnapshot"
            } else {
                note = "web content not rendered"
                manifest.limitations.append("\(name): web content could not be composited")
            }
        }
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            manifest.failures.append("\(name): PNG encoding failed"); return
        }
        let file = "\(name).png"
        do { try data.write(to: directory.appendingPathComponent(file)) }
        catch { manifest.failures.append("\(name): \(error.localizedDescription)"); return }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        manifest.scenes.append(Scene(name: name, file: file, width: bitmap.pixelsWide, height: bitmap.pixelsHigh,
                                     sha256: digest, keyWindow: capturedKeyWindow, note: note))
    }
}
/// Keeps capture windows off every display, even when they become key (AppKit would otherwise
/// move a key window on screen, where it can flash and pick up the real pointer's hover state).
private final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    /// Key appearance is needed for evidence, but real user input must never edit the scene.
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown, .keyUp, .flagsChanged,
             .leftMouseDown, .leftMouseUp, .leftMouseDragged,
             .rightMouseDown, .rightMouseUp, .rightMouseDragged,
             .otherMouseDown, .otherMouseUp, .otherMouseDragged,
             .mouseMoved, .mouseEntered, .mouseExited, .scrollWheel,
             .tabletPoint, .tabletProximity, .gesture, .magnify, .swipe, .rotate,
             .beginGesture, .endGesture, .smartMagnify, .pressure:
            return
        default: super.sendEvent(event)
        }
    }
}
#endif
