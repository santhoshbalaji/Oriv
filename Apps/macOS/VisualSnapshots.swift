#if DEBUG
import AppKit
import BrowserCore
import BrowserEngine
import CryptoKit
import ScreenCaptureKit
import SwiftUI
import WebKit

/// Debug-only visual evidence. Renders the real browser views with synthetic data into PNG
/// files plus a manifest, then exits (status 0 only when every scene was written). It runs only
/// when BROWSER_TESTING=1 (ephemeral profiles, no persisted browsing data) and
/// ORIV_VISUAL_SNAPSHOTS=1 are both set. Images go to the sandbox container's temporary
/// directory (OrivVisualSnapshots); scripts/capture-mac-visuals.sh validates and copies them.
/// ORIV_SNAPSHOT_ACTIVATE=1 requests key windows. App activation additionally
/// requires the separately approved foreground UI mode. Release builds exclude this file.
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
        var keyWindowsRequested = false
        var backgroundUI: BackgroundUIMode.Audit?
        var skipped: [String] = []
        var windows: [BackgroundUIMode.WindowReport] = []
        var scenes: [Scene] = []; var evidence: [Scene] = []; var failures: [String] = []; var limitations: [String] = []
    }
    private static var manifest: Manifest!
    private static var offscreenCompositorUnavailable: String?

    static func run(into directory: URL) async {
        let environment = ProcessInfo.processInfo.environment
        let activate = environment["ORIV_SNAPSHOT_ACTIVATE"] == "1"
        manifest = Manifest(runID: environment["ORIV_SNAPSHOT_RUN_ID"] ?? "unspecified", startedAt: Date(),
                            osVersion: ProcessInfo.processInfo.operatingSystemVersionString, activated: activate && BackgroundUIMode.foregroundAllowed)
        manifest.keyWindowsRequested = activate
        do {
            guard !FileManager.default.fileExists(atPath: directory.path) else {
                fputs("snapshot run directory already exists; refusing to overwrite it\n", stderr); exit(2)
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            fputs("snapshot directory unavailable: \(error)\n", stderr); exit(2)
        }
        BackgroundUIMode.installAtLaunch()
        if BackgroundUIMode.isEnabled {
            manifest.limitations.append("All windows stay off every display. Sidebar/glass fallback fixtures use the app's opaque Reduce Transparency variant; they cannot verify Liquid Glass.")
        }
        if let sites = environment["ORIV_LIVE_SITES"], !sites.isEmpty { await renderLiveSites(sites, into: directory, activate: activate) }
        else if environment["ORIV_GLASS_SCENE"] == "sidebar" { await renderSidebarScenes(into: directory, activate: activate) }
        else if environment["ORIV_GLASS_SCENE"]?.isEmpty == false { await renderGlassScenes(into: directory, activate: activate) }
        else { await renderScenes(into: directory, activate: activate) }
        manifest.backgroundUI = BackgroundUIMode.audit()
        if BackgroundUIMode.isEnabled, let audit = manifest.backgroundUI,
           audit.frontmostViolations > 0 || audit.activationViolations > 0 || audit.onscreenWindowViolations > 0 {
            manifest.failures.append("Background UI became active/frontmost or overlapped a display during capture")
        }
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

        // Real routing and Move, using only ephemeral profiles and synthetic page content.
        let externalProfiles = BrowserProfiles(testing: true)
        let originalTabs = externalProfiles.controller.session.tabs.map(\.id)
        externalProfiles.handleIncomingURL(URL(string: "https://fixture.example/external")!, sourceName: "Example App")
        if let external = externalProfiles.externalPrivate, let privateTab = external.session.selectedTab {
            let privateID = privateTab.id
            privateTab.webView.loadHTMLString(fixturePage(scheme: "https"), baseURL: URL(string: "https://fixture.example/external"))
            try? await Task.sleep(for: .milliseconds(800))
            await capture("mac-12-external-private", directory, size, key: activate, compositeWeb: privateTab.webView) {
                BrowserWindow(controller: external, profiles: externalProfiles)
            }
            var closedEmptyWindow = false
            externalProfiles.closeExternalWindow = { closedEmptyWindow = true }
            do { try externalProfiles.moveExternalTab() }
            catch { manifest.failures.append("external Move: \(error)") }
            let destination = externalProfiles.controller.session
            if !external.session.tabs.isEmpty || external.session.selectedTabID != nil
                || externalProfiles.externalPrivate != nil || !closedEmptyWindow
                || destination.tabs.contains(where: { $0.id == privateID || $0.isPrivate })
                || !originalTabs.allSatisfy({ id in destination.tabs.contains { $0.id == id } })
                || destination.tabs.count != originalTabs.count + 1 {
                manifest.failures.append("external Move did not close the private tab/window or preserve destination tabs")
            }
            if let moved = destination.selectedTab {
                moved.webView.loadHTMLString(fixturePage(scheme: "https"), baseURL: URL(string: "https://fixture.example/external"))
                try? await Task.sleep(for: .milliseconds(800))
                await capture("mac-13-external-moved-to-personal", directory, size, key: activate, compositeWeb: moved.webView) {
                    BrowserWindow(controller: externalProfiles.controller, profiles: externalProfiles)
                }
            }
        } else { manifest.failures.append("external route did not create its private context") }
        externalProfiles.shutdown()

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

    private static func sidebarFixture(color: String, light: Bool) -> String {
        let ink = light ? "#251538" : "#ffffff", heading = light ? "#5e19af" : (color == "#101014" ? "#d8bbff" : "#ff783d")
        return """
        <!doctype html><html><head><title>Found, don’t follow</title><meta name="viewport" content="width=device-width,initial-scale=1"><style>
        *{box-sizing:border-box}body{margin:0;background:\(color);color:\(ink);font-family:Georgia,serif}header{height:66px;padding:0 24px;display:flex;align-items:center;justify-content:space-between;border-bottom:1px solid #ffffff50;font:600 12px -apple-system,sans-serif}header strong{font-size:25px;color:\(heading);letter-spacing:-1px}.hero{padding:32px max(30px,14vw) 60px;min-height:530px}h1{font-size:48px;font-weight:500;line-height:1.05;color:\(heading);letter-spacing:-2px;margin:0 0 38px}h1 span{display:block;margin-left:80px}.copy{margin-left:80px;max-width:780px;font-size:29px;line-height:1.12;letter-spacing:-1px}.copy p{margin:0 0 32px}.story{background:#e0ebed;color:#35134d;padding:26px max(30px,14vw) 80px;min-height:1400px}.story blockquote{margin:0;border-top:1px solid #958ca5;border-bottom:1px solid #958ca5;padding:24px 0;font-size:28px}.story h2{font:700 28px -apple-system,sans-serif;margin-top:56px}.story p{font-size:30px;line-height:1.3}@media(max-width:700px){header strong{font-size:17px}.hero{padding:32px 30px 50px}h1{font-size:42px}.copy{font-size:25px;margin-left:28px}h1 span{margin-left:28px}}
        </style></head><body><header><span>[START]</span><strong>ENTREPRENEURS FIRST</strong><span>[MENU]</span></header><section class="hero"><h1>FOUND,<span>↳DON’T FOLLOW</span></h1><div class="copy"><p>We turn exceptional individuals into funded founders. We back you first, then give you a bridge to Silicon Valley.</p><p>You might have an early idea, or be testing a cofounder. You might have nothing. What we’re most interested in is you and your potential.</p></div></section><section class="story"><blockquote>“Joining EF was a life-changing decision.”</blockquote><h2>WE BUILD COFOUNDING TEAMS FROM SCRATCH.</h2><p>Your potential is the starting point.</p><p>Meet people with the ambition to build something new. Explore ideas, share what you know and find your next collaborator.</p></section></body></html>
        """
    }

    private static func renderSidebarScenes(into directory: URL, activate: Bool) async {
        for mode in ["light", "purple", "dark", "collapsed", "fullscreen", "fullscreen-collapsed", "scrolled", "inactive", "minimum", "reduced", "rtl-largest", "covered"] {
            let profiles = BrowserProfiles(testing: true)
            let controller = profiles.controller
            controller.compactSidebar = mode == "collapsed" || mode == "fullscreen-collapsed"
            let tab = controller.session.selectedTab!
            let color = mode == "light" ? "#f7f7f2" : (mode == "dark" ? "#101014" : "#6000d9")
            let html = sidebarFixture(color: color, light: mode == "light")
            tab.webView.loadHTMLString(html, baseURL: URL(string: "https://fixture.example/sidebar"))
            for name in ["Apple — Example", "GitHub · Changelog", "A long example tab title for truncation"] {
                let other = controller.session.addTab(url: nil, select: false, load: false)
                other.webView.loadHTMLString("<title>\(name)</title><body>Example</body>", baseURL: URL(string: "https://fixture.example/other"))
            }
            try? await Task.sleep(for: .milliseconds(700))
            await capture("mac-glass-sidebar-\(mode)", directory,
                mode == "minimum" || mode == "rtl-largest" ? CGSize(width: 760, height: 520) : (mode.hasPrefix("fullscreen") && !BackgroundUIMode.foregroundAllowed ? CGSize(width: 1800, height: 1152) : CGSize(width: 1250, height: 815.625)),
                key: activate && mode != "inactive", compositeWeb: tab.webView, covered: mode == "covered", prepare: { window in
                    window.makeFirstResponder(tab.webView)
                    if mode.hasPrefix("fullscreen") {
                        if BackgroundUIMode.foregroundAllowed {
                            window.collectionBehavior.insert(.fullScreenPrimary)
                            window.toggleFullScreen(nil)
                            for _ in 0..<80 { if window.styleMask.contains(.fullScreen) { break }; try? await Task.sleep(for: .milliseconds(100)) }
                            try? await Task.sleep(for: .seconds(1))
                            if !window.styleMask.contains(.fullScreen) { manifest.failures.append("\(mode): did not enter fullscreen") }
                        } else {
                            simulateFullscreenLayout(in: window)
                            manifest.skipped.append("\(mode): system transition skipped. " + BackgroundUIMode.foregroundOnlyReason)
                            manifest.limitations.append("\(mode): geometry-only fullscreen layout in a normal background window; system buttons hidden by the fixture, no Space/menu transition.")
                            try? await Task.sleep(for: .milliseconds(250))
                        }
                    }
                    if mode == "scrolled" { _ = try? await tab.webView.evaluateJavaScript("window.scrollTo(0,780)"); try? await Task.sleep(for: .seconds(1)) }
                    if mode == "inactive" { window.resignKey(); if BackgroundUIMode.foregroundAllowed { NSApp.deactivate() } }
                    writeSidebarGeometry(window, to: directory.appendingPathComponent("mac-glass-sidebar-\(mode)-geometry.json"))
                    let page: [String: Any] = ["frame": NSStringFromRect(tab.webView.frame),
                        "windowFrame": NSStringFromRect(tab.webView.convert(tab.webView.bounds, to: nil)),
                        "hostFrame": NSStringFromRect(tab.webView.superview?.frame ?? .zero),
                        "viewport": (try? await tab.webView.evaluateJavaScript("({width:innerWidth,height:innerHeight,x:scrollX,y:scrollY,ready:document.readyState,text:document.body.innerText.length})")) ?? [:]]
                    if let data = try? JSONSerialization.data(withJSONObject: page, options: [.prettyPrinted, .sortedKeys]) {
                        try? data.write(to: directory.appendingPathComponent("mac-glass-sidebar-\(mode)-page-geometry.json"))
                    }
                }) {
                    BrowserWindow(controller: controller, profiles: profiles)
                        .environment(\.chromeReduceTransparencyOverride, BackgroundUIMode.isEnabled || mode == "reduced")
                        .environment(\.layoutDirection, mode == "rtl-largest" ? .rightToLeft : .leftToRight)
                        .dynamicTypeSize(mode == "rtl-largest" ? .accessibility5 : .large)
            }
            profiles.shutdown()
        }
    }

    private static func simulateFullscreenLayout(in window: NSWindow) {
        func visit(_ view: NSView) {
            if let chrome = view as? BrowserWindowChrome.WindowChromeView { chrome.simulatesFullscreenLayout = true; chrome.configure() }
            view.subviews.forEach(visit)
        }
        window.contentView.map(visit)
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(type)?.isHidden = true }
    }

    private static func writeSidebarGeometry(_ window: NSWindow, to url: URL) {
        func markers(_ view: NSView) -> [NSView] {
            (view is BrowserGeometryMarker.Marker ? [view] : []) + view.subviews.flatMap(markers)
        }
        let frames = (window.contentView.map { markers($0).map { ["name": $0.identifier?.rawValue ?? "", "frame": NSStringFromRect($0.convert($0.bounds, to: nil))] } }) ?? []
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { type -> [String: Any]? in
            guard let button = window.standardWindowButton(type) else { return nil }
            return ["type": type.rawValue, "frame": NSStringFromRect(button.convert(button.bounds, to: nil)), "hidden": button.isHiddenOrHasHiddenAncestor, "hostWindow": button.window?.windowNumber ?? -1, "hostVisible": button.window?.isVisible ?? false]
        }
        func accessibility(_ element: Any, depth: Int = 0) -> [[String: Any]] {
            guard depth < 10, let node = element as? NSAccessibilityProtocol else { return [] }
            let row: [String: Any] = ["role": node.accessibilityRole()?.rawValue ?? "", "label": node.accessibilityLabel() ?? "",
                "frame": NSStringFromRect(node.accessibilityFrame()), "depth": depth]
            let children: [Any] = node.accessibilityChildrenInNavigationOrder().map { $0.map { $0 as Any } } ?? node.accessibilityChildren() ?? []
            return [row] + children.flatMap { accessibility($0, depth: depth + 1) }
        }
        let value: [String: Any] = ["frame": NSStringFromRect(window.frame), "content": NSStringFromRect(window.contentView?.bounds ?? .zero),
            "fullscreen": window.styleMask.contains(.fullScreen), "key": window.isKeyWindow, "markers": frames, "buttons": buttons, "accessibility": accessibility(window),
            "appActive": NSApp.isActive, "occlusionState": window.occlusionState.rawValue,
            "frontmostIsTestApp": NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
            "layerBacked": window.contentView?.wantsLayer ?? false, "backgroundUI": BackgroundUIMode.isEnabled]
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: url) }
    }

    private static func renderGlassScenes(into directory: URL, activate: Bool) async {
        let requested = ProcessInfo.processInfo.environment["ORIV_GLASS_SCENE"] ?? "all"
        for mode in ["light", "light-scrolled", "dark", "dark-scrolled", "theme", "theme-scrolled", "focused", "menu", "private", "reduced", "insecure"] where requested == "all" || mode == requested {
            let profiles = BrowserProfiles(testing: true)
            var controller = profiles.controller
            if mode == "private" {
                profiles.handleIncomingURL(URL(string: "https://docs.example.com/designing-calm-interfaces")!, sourceName: "Example App")
                controller = profiles.externalPrivate!
            }
            let tab = controller.session.selectedTab!
            let address = "\(mode == "insecure" ? "http" : "https")://docs.example.com/designing-calm-interfaces"
            var html = ChromeVisualFixture.html(dark: mode.hasPrefix("dark") || mode.hasPrefix("theme") || mode == "private")
            if mode.hasPrefix("theme") { html = html.replacingOccurrences(of: "#111111", with: "#1F6F5C") }
            if mode == "private" { html = html.replacingOccurrences(of: "#111111", with: "#000000") }
            tab.webView.loadHTMLString(html, baseURL: URL(string: address))
            if mode != "private" {
                for (card, path) in [(1, "room"), (2, "materials")] {
                    let url = URL(string: "https://docs.example.com/\(path)")!
                    let backgroundTab = controller.session.addTab(url: url, select: false, load: false)
                    backgroundTab.webView.loadHTMLString(ChromeVisualFixture.html(card: card), baseURL: url)
                }
            }
            try? await Task.sleep(for: .milliseconds(900))
            await capture("mac-glass-\(mode)", directory, CGSize(width: 1440, height: 848), key: activate, settle: 1_400, compositeWeb: tab.webView,
                          expectedFields: ["addressField": mode == "focused" ? address : "docs.example.com"],
                          prepare: { window in
                if mode.hasSuffix("scrolled") {
                    _ = try? await tab.webView.evaluateJavaScript("window.scrollTo(0, 560)")
                    try? await Task.sleep(for: .milliseconds(500))
                }
                if mode == "focused" {
                    // Exercise the same focus request as the real Command-L menu item.
                    controller.focusAddress()
                    try? await Task.sleep(for: .milliseconds(500))
                    if let editor = window.firstResponder as? NSTextView,
                       editor.string == address, editor.selectedRange() == NSRange(location: 0, length: (address as NSString).length) {} else {
                        manifest.failures.append("focused address did not select the complete URL")
                    }
                }
                let geometry = (try? await tab.webView.evaluateJavaScript("({scrollY:window.scrollY,headerTop:document.querySelector('header').getBoundingClientRect().top})")) as? [String: Any] ?? [:]
                let scrollY = (geometry["scrollY"] as? NSNumber)?.doubleValue ?? -1
                if mode.hasSuffix("scrolled") ? scrollY < 500 : abs(scrollY) > 1 {
                    manifest.failures.append("\(mode): unexpected scroll position \(scrollY)")
                }
                let webFrame = tab.webView.convert(tab.webView.bounds, to: nil)
                let metrics: [String: Any] = ["scroll": geometry, "obscuredTop": tab.webView.obscuredContentInsets.top,
                    "webTopInWindow": webFrame.maxY, "contentLayoutTop": window.contentLayoutRect.maxY,
                    "titlebarTransparent": window.titlebarAppearsTransparent, "separatorStyle": window.titlebarSeparatorStyle.rawValue]
                if let data = try? JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: directory.appendingPathComponent("mac-glass-\(mode)-geometry.json"))
                }
            }) {
                BrowserWindow(controller: controller, profiles: profiles, initialPageMenu: mode == "menu")
                    .environment(\.chromeReduceTransparencyOverride, BackgroundUIMode.isEnabled || mode == "reduced")
            }
            profiles.shutdown()
        }
    }

    /// Opt-in network evidence in the isolated snapshot app. Third-party images
    /// stay in temporary/build output, never in the public fixture resources.
    private static func renderLiveSites(_ sites: String, into directory: URL, activate: Bool) async {
        let darkIndices = Set((ProcessInfo.processInfo.environment["ORIV_LIVE_DARK_INDICES"] ?? "").split(separator: ",").compactMap { Int($0) })
        let scrollIndices = Set((ProcessInfo.processInfo.environment["ORIV_LIVE_SCROLL_INDICES"] ?? "").split(separator: ",").compactMap { Int($0) })
        for (index, address) in sites.split(separator: ",").map(String.init).enumerated() {
            guard let url = URL(string: address), url.scheme == "https" else { continue }
            let profiles = BrowserProfiles(testing: true)
            profiles.controller.compactSidebar = ProcessInfo.processInfo.environment["ORIV_SIDEBAR_COLLAPSED"] == "1"
            let timing = ProcessInfo.processInfo.environment["ORIV_CHROME_TIMING"] == "1"
            let tab = profiles.controller.session.addTab(url:timing ? nil : url,select:true,load:!timing)
            if !timing && url.host == "fixture.invalid" { tab.webView.loadHTMLString(ChromeVisualFixture.html(), baseURL: url) }
            tab.webView.appearance = NSAppearance(named: darkIndices.contains(index + 1) ? .darkAqua : .aqua)
            try? await Task.sleep(for: .milliseconds(500))
            let name = "mac-glass-site\(index + 1)"
            await capture(name, directory, CGSize(width: 1440, height: 848), key: activate, compositeWeb: tab.webView, prepare: { window in
                for _ in 0..<60 {
                    if !tab.webView.isLoading { break }
                    try? await Task.sleep(for: .milliseconds(250))
                }
                try? await Task.sleep(for: .seconds(timing ? 0.2 : 3))
                let web = tab.webView
                window.makeFirstResponder(web)
                if ProcessInfo.processInfo.environment["ORIV_CHROME_TIMING"] == "1" {
                    ChromeTiming.event("captureNavigation", web: web)
                    let recording = Task { @MainActor in
                        for frame in 0..<20 {
                            await ownedImage(window, to: directory.appendingPathComponent("\(name)-timing-\(String(format: "%03d",frame)).png"))
                            try? await Task.sleep(for: .milliseconds(16))
                        }
                    }
                    if url.host == "fixture.invalid" { web.loadHTMLString(ChromeVisualFixture.html(), baseURL:url) } else { tab.navigate(to:url) }
                    await recording.value
                    window.makeFirstResponder(web)
                    try? await Task.sleep(for:.milliseconds(150))
                    if let data = try? Data(contentsOf: FileManager.default.temporaryDirectory.appendingPathComponent("oriv-chrome-timing.json")) {
                        try? data.write(to: directory.appendingPathComponent("\(name)-timing.json"))
                    }
                }
                if ProcessInfo.processInfo.environment["ORIV_FULLSCREEN_EVIDENCE"] == "1" {
                    await fullscreenEvidence(window, name: name, directory: directory)
                }
                if scrollIndices.contains(index + 1) {
                    _ = try? await web.evaluateJavaScript("window.scrollTo(0,560)")
                    try? await Task.sleep(for: .seconds(2))
                }
                let edge = (try? await web.callAsyncJavaScript(PageChrome.edgeScript,
                    arguments: ["inset": web.obscuredContentInsets.top, "viewWidth": web.bounds.width],
                    in: nil, contentWorld: .page)) as? [String: Any] ?? [:]
                let config = WKSnapshotConfiguration()
                config.rect = CGRect(x: 2, y: web.obscuredContentInsets.top + 1, width: web.bounds.width - 4, height: 6)
                if let image = try? await web.takeSnapshot(configuration: config), let data = image.tiffRepresentation,
                   let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: directory.appendingPathComponent("\(name)-strip.png"))
                }
                func hex(_ color: NSColor?) -> String {
                    guard let c = color?.usingColorSpace(.sRGB) else { return "none" }
                    return String(format: "#%02x%02x%02x", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
                }
                let dom = (try? await web.evaluateJavaScript("({title:document.title,href:location.href,theme:[...document.querySelectorAll('meta[name=theme-color]')].map(m=>({content:m.content,media:m.media})),html:getComputedStyle(document.documentElement).backgroundColor,body:getComputedStyle(document.body).backgroundColor,scrollY,top:document.elementFromPoint(innerWidth/2,1)?.tagName})")) as? [String: Any] ?? [:]
                if ProcessInfo.processInfo.environment["ORIV_SCROLL_EVIDENCE"] == "1" {
                    await scrollEvidence(web, controller: profiles.controller, window: window, name: name, directory: directory)
                }
                let metrics: [String: Any] = ["requested": address, "url": web.url?.absoluteString ?? "none", "error": tab.errorMessage ?? "none",
                    "theme": hex(web.themeColor), "underPage": hex(web.underPageBackgroundColor), "band": hex(window.backgroundColor),
                    "obscuredTop": web.obscuredContentInsets.top, "dom": dom, "edgeSelection": edge, "isLoading": web.isLoading]
                if let data = try? JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: directory.appendingPathComponent("\(name)-geometry.json"))
                }
            }) { BrowserWindow(controller: profiles.controller, profiles: profiles) }
            profiles.shutdown()
        }
    }

    /// In-process WindowServer capture, restricted to this process's exact window.
    /// ScreenCaptureKit includes compositor glass without a desktop/screen capture.
    private static func ownedPNG(_ window: NSWindow) async throws -> Data {
        if BackgroundUIMode.isEnabled, let reason = offscreenCompositorUnavailable {
            throw NSError(domain: "OwnedWindowCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
        }
        if ProcessInfo.processInfo.environment["ORIV_CAPTURE_RENDERER"] != "inprocess" {
            // The caller supplies an NSWindow created in this process. The shell
            // bridge validates this exact executable/PID before capturing its ID.
            guard let directory, window.windowNumber > 0 else { throw CocoaError(.fileNoSuchFile) }
            let name = "mac-glass-owned-" + UUID().uuidString
            let requestURL = directory.appendingPathComponent("capture-request.json")
            let resultURL = directory.appendingPathComponent("\(name)-live.png")
            let errorURL = directory.appendingPathComponent("capture-error.json")
            let request: [String: Any] = ["windowID": window.windowNumber, "pid": ProcessInfo.processInfo.processIdentifier, "name": name]
            try JSONSerialization.data(withJSONObject: request).write(to: requestURL, options: .atomic)
            defer { try? FileManager.default.removeItem(at: requestURL); try? FileManager.default.removeItem(at: resultURL); try? FileManager.default.removeItem(at: errorURL) }
            for _ in 0..<100 {
                if let data = try? Data(contentsOf: resultURL), NSBitmapImageRep(data: data) != nil { return data }
                if let data = try? Data(contentsOf: errorURL),
                   let error = try? JSONSerialization.jsonObject(with: data) as? [String: String], error["name"] == name {
                    let reason = error["reason"] ?? "Window image unavailable"
                    if BackgroundUIMode.isEnabled { offscreenCompositorUnavailable = reason }
                    throw NSError(domain: "OwnedWindowCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw CocoaError(.fileReadUnknown)
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let own = content.windows.first(where: {
            $0.windowID == CGWindowID(window.windowNumber) && $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
        }) else { throw CocoaError(.fileNoSuchFile) }
        let filter = SCContentFilter(desktopIndependentWindow: own)
        let configuration = SCStreamConfiguration()
        let scale = window.backingScaleFactor
        configuration.width = Int(window.frame.width * scale)
        configuration.height = Int(window.frame.height * scale)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        return data
    }
    private static func ownedImage(_ window: NSWindow, to url: URL) async {
        do {
            let data = try await ownedPNG(window), bitmap = NSBitmapImageRep(data: data)!
            try data.write(to: url)
            manifest.evidence.append(Scene(name: url.deletingPathExtension().lastPathComponent, file: url.lastPathComponent,
                width: bitmap.pixelsWide, height: bitmap.pixelsHigh,
                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                keyWindow: window.isKeyWindow, note: ProcessInfo.processInfo.environment["ORIV_CAPTURE_RENDERER"] != "inprocess" ? "PID-validated capture bridge, owned window only; UI actions in-process" : "In-process ScreenCaptureKit, owned window only"))
        } catch { manifest.failures.append("Owned window capture: \(error.localizedDescription)") }
    }
    private static func fullscreenEvidence(_ window: NSWindow, name: String, directory: URL) async {
        guard BackgroundUIMode.foregroundAllowed else {
            manifest.skipped.append("\(name): " + BackgroundUIMode.foregroundOnlyReason)
            return
        }
        var rows: [[String: Any]] = []
        func state(_ mode: String) async {
            BackgroundUIMode.show(window, key: true, activate: BackgroundUIMode.foregroundAllowed)
            try? await Task.sleep(for: .milliseconds(600))
            await ownedImage(window, to: directory.appendingPathComponent("\(name)-\(mode).png"))
            if let toolbarWindow = window.toolbar?.items.compactMap({ $0.view?.window }).first(where: { $0 !== window }) {
                await ownedImage(toolbarWindow, to: directory.appendingPathComponent("\(name)-\(mode)-toolbar.png"))
            }
            // AppKit can reveal the real lights in its own titlebar host even
            // without NSToolbar. Capture that app-owned host when it is onscreen.
            if let host = window.standardWindowButton(.closeButton)?.window, host !== window,
               NSApp.windows.contains(where: { $0 === host }), host.isVisible,
               let screen = window.screen, host.frame.intersects(screen.frame) {
                await ownedImage(host, to: directory.appendingPathComponent("\(name)-\(mode)-titlebar.png"))
            }
            func tree(_ view: NSView, depth: Int = 0) -> [String] {
                [String(repeating:" ",count:depth) + "\(type(of:view)) \(view.frame)"] + view.subviews.flatMap { tree($0, depth:depth+1) }
            }
            writeSidebarGeometry(window, to: directory.appendingPathComponent("\(name)-\(mode)-geometry.json"))
            rows.append(["mode":mode, "fullscreen":window.styleMask.contains(.fullScreen), "frame":NSStringFromRect(window.frame), "layout":NSStringFromRect(window.contentLayoutRect),
                "windows":NSApp.windows.map { ["id":$0.windowNumber, "class":String(describing:type(of:$0)), "frame":NSStringFromRect($0.frame), "tree":$0.contentView.map { tree($0.superview ?? $0) } ?? []] }])
        }
        await state("floating")
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.toggleFullScreen(nil)
        for _ in 0..<80 { if window.styleMask.contains(.fullScreen) { break }; try? await Task.sleep(for:.milliseconds(100)) }
        try? await Task.sleep(for:.seconds(1))
        await state("fullscreen")
        // Exercise AppKit's public menu reveal path in this isolated process.
        let menuWasVisible = NSMenu.menuBarVisible()
        NSMenu.setMenuBarVisible(true)
        // Window-local mouse event also reaches the owned toolbar handlers.
        if let event = NSEvent.mouseEvent(with:.mouseMoved, location:NSPoint(x:window.frame.width/2,y:window.frame.height-1), modifierFlags:[], timestamp:ProcessInfo.processInfo.systemUptime, windowNumber:window.windowNumber, context:nil, eventNumber:0, clickCount:0, pressure:0) { window.sendEvent(event) }
        await state("reveal")
        NSMenu.setMenuBarVisible(menuWasVisible)
        let options = NSApp.presentationOptions
        NSApp.presentationOptions.insert(.autoHideToolbar)
        await state("autohide")
        NSApp.presentationOptions = options
        window.toggleFullScreen(nil)
        for _ in 0..<80 { if !window.styleMask.contains(.fullScreen) { break }; try? await Task.sleep(for:.milliseconds(100)) }
        try? await Task.sleep(for:.seconds(1))
        await state("returned")
        if let data = try? JSONSerialization.data(withJSONObject: rows, options:[.prettyPrinted,.sortedKeys]) { try? data.write(to:directory.appendingPathComponent("\(name)-fullscreen.json")) }
    }

    /// Opt-in in-process input and model telemetry; never posts system input.
    private static func scrollEvidence(_ web: WKWebView, controller: BrowserController, window: NSWindow, name: String, directory: URL) async {
        var chrome: PageChrome?
        PageChrome.diagnosticObserver = { chrome = $0 }
        defer { PageChrome.diagnosticObserver = nil }
        // Obtain the window's existing model without replacing the production view.
        _ = try? await web.evaluateJavaScript("window.dispatchEvent(new Event('resize'))")
        try? await Task.sleep(for: .milliseconds(1200))
        controller.focusAddress()
        try? await Task.sleep(for: .milliseconds(150))
        window.makeFirstResponder(web)
        var rows: [[String: Any]] = []
        for (sequence, positions, delay) in [
            ("slow", [0.0,2,0,2,0,2,0,12,18,8,4,2,0,2,0], 100),
            ("fast", [0.0,30,0,30,0,30,0,30,0], 16),
            ("bounce", [0.0,-8,2,-4,2,0,-10,14,8,2,-6,0], 60)
        ] {
            for (index, y) in positions.enumerated() {
                if let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(index.isMultiple(of: 2) ? -4 : 4), wheel2: 0, wheel3: 0) {
                    event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                    event.setIntegerValueField(.scrollWheelEventScrollPhase, value: sequence == "fast" ? 0 : (index == 0 ? 1 : 2))
                    event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: sequence == "fast" ? 2 : 0)
                    if let native = NSEvent(cgEvent: event) { web.scrollWheel(with: native) }
                }
                _ = try? await web.evaluateJavaScript("window.scrollTo(0, \(y))")
                try? await Task.sleep(for: .milliseconds(delay))
                let actual = (try? await web.evaluateJavaScript("scrollY")) as? Double ?? -999
                rows.append(["sequence": sequence, "index": index, "requestedY": y, "actualY": actual,
                    "time": ProcessInfo.processInfo.systemUptime, "scrolled": chrome?.hasScrolled ?? false,
                    "under": chrome?.showsContentUnderChrome ?? false, "luminance": chrome?.luminance ?? -1,
                    "editing": (window.firstResponder as? NSTextView) != nil,
                    "focusRequest": controller.addressFocusRequest])
            }
            try? await Task.sleep(for: .milliseconds(350))
        }
        _ = try? await web.evaluateJavaScript("window.scrollTo(0,0)")
        window.makeFirstResponder(web)
        try? await Task.sleep(for: .milliseconds(800))
        if let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("\(name)-scroll.json"))
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
                                               covered: Bool = false,
                                               prepare: (NSWindow) async -> Void = { _ in },
                                               @ViewBuilder content: () -> Content) async {
        let hosting = NSHostingController(rootView: content().browserAppearance(.t3Code))
        hosting.sceneBridgingOptions = [.toolbars, .title]
        let liveGlass = ProcessInfo.processInfo.environment["ORIV_GLASS_SCENE"]?.isEmpty == false || ProcessInfo.processInfo.environment["ORIV_LIVE_SITES"]?.isEmpty == false
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        if liveGlass { style.insert(.fullSizeContentView) }
        let window = OffscreenWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: style, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // Capture stable geometry, without an inferred WindowServer opening animation.
        window.animationBehavior = .none
        window.toolbarStyle = toolbarStyle
        window.contentViewController = hosting
        window.setContentSize(size)
        window.setFrameOrigin(liveGlass ? (BackgroundUIMode.isEnabled && size.width == 1800 ? .zero : NSPoint(x: 40, y: 60)) : NSPoint(x: -30_000, y: -30_000))
        BackgroundUIMode.show(window, key: key, activate: key && BackgroundUIMode.foregroundAllowed)
        let cover = covered ? BackgroundUIMode.makeCover(for: window) : nil
        defer { cover?.orderOut(nil); cover?.close(); window.orderOut(nil); window.close() }
        try? await Task.sleep(for: .milliseconds(settle))
        var attempts = 0
        while key && !window.isKeyWindow && !BackgroundUIMode.isEnabled && attempts < 20 {
            attempts += 1
            BackgroundUIMode.show(window, key: true, activate: BackgroundUIMode.foregroundAllowed)
            try? await Task.sleep(for: .milliseconds(150))
        }
        await prepare(window)
        if key {
            // Keep the owned window key without changing the frontmost app in background mode.
            BackgroundUIMode.show(window, key: true, activate: BackgroundUIMode.foregroundAllowed)
            try? await Task.sleep(for: .milliseconds(200))
        }
        if BackgroundUIMode.isEnabled, let webView {
            webView.wantsLayer = true
            _ = try? await webView.takeSnapshot(configuration: nil)
            // WebKit's remote layer transaction can arrive after its snapshot
            // completion when occluded. Leave it behind owner windows to settle.
            try? await Task.sleep(for: .milliseconds(200))
        }
        window.displayIfNeeded()
        BackgroundUIMode.checkFrontmost()
        if key && !window.isKeyWindow {
            if BackgroundUIMode.isEnabled { manifest.limitations.append("\(name): inactive AppKit refused key-window status; capture remains at the back.") }
            else { manifest.failures.append("\(name): requested a key window but it did not become key") }
        }
        let report = BackgroundUIMode.report(window, name: name,
            simulatedFullscreenLayout: name.contains("sidebar-fullscreen") && !BackgroundUIMode.foregroundAllowed)
        manifest.windows.append(report)
        if covered && !report.occluded { manifest.failures.append("\(name): deliberate background cover did not occlude the target") }
        func fields(in view: NSView) -> [NSTextField] {
            ((view as? NSTextField).map { [$0] } ?? []) + view.subviews.flatMap { fields(in: $0) }
        }
        for (identifier, expected) in expectedFields {
            let matches = window.contentView.map { fields(in: $0.superview ?? $0) }?.filter { $0.accessibilityIdentifier() == identifier } ?? []
            let actual = matches.count == 1 ? matches.first?.stringValue : (window.firstResponder as? NSTextView)?.string
            if actual != expected {
                manifest.failures.append("\(name): \(identifier) missing or contaminated (expected \(expected.debugDescription), actual \(actual.debugDescription))")
            }
        }
        if liveGlass {
            do {
                let data = try await ownedPNG(window), image = NSBitmapImageRep(data: data)!
                try data.write(to: directory.appendingPathComponent("\(name).png"))
                manifest.scenes.append(Scene(name: name, file: "\(name).png", width: image.pixelsWide, height: image.pixelsHigh,
                    sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                    keyWindow: window.isKeyWindow, note: ProcessInfo.processInfo.environment["ORIV_CAPTURE_RENDERER"] != "inprocess" ? "PID-validated capture bridge, owned window only; UI actions in-process" : "In-process ScreenCaptureKit, owned window only"))
            } catch {
                if BackgroundUIMode.isEnabled {
                    manifest.skipped.append("\(name): visual-foreground-only; off-screen compositor capture unavailable: \(error.localizedDescription). Owner approval through the orchestrator is required for an on-screen capture.")
                    await offscreenFallback(window, webView: webView, name: name, directory: directory)
                } else { manifest.failures.append("\(name): capture failed: \(error.localizedDescription)") }
            }
            // Exit this isolated full-screen Space before closing the window.
            // Closing it directly can leave the next scene inside AppKit's exit
            // transition and cause its full-screen request to be ignored.
            if BackgroundUIMode.foregroundAllowed && window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
                for _ in 0..<80 {
                    if !window.styleMask.contains(.fullScreen) { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                try? await Task.sleep(for: .seconds(1))
            }
            return
        }
        guard let frame = window.contentView?.superview,
              let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else {
            manifest.failures.append("\(name): no window frame to render"); return
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
                NSBezierPath(rect: rect.intersection(frame.convert(window.contentLayoutRect, from: nil))).addClip()
                image.draw(in: rect)
                NSGraphicsContext.restoreGraphicsState()
                note = "web content composited from WKWebView.takeSnapshot"
            } else {
                note = "web content not rendered"
                manifest.limitations.append("\(name): web content could not be composited")
            }
        }
        let data = bitmap.representation(using: .png, properties: [:])
        guard let data else {
            manifest.failures.append("\(name): PNG encoding failed"); return
        }
        let file = "\(name).png"
        do { try data.write(to: directory.appendingPathComponent(file)) }
        catch { manifest.failures.append("\(name): \(error.localizedDescription)"); return }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let dimensions = NSBitmapImageRep(data: data)!
        manifest.scenes.append(Scene(name: name, file: file, width: dimensions.pixelsWide, height: dimensions.pixelsHigh,
                                     sha256: digest, keyWindow: capturedKeyWindow, note: note))
    }

    /// Never substitute a 2D render for Liquid Glass. Keep separately labelled
    /// page and non-glass candidates so their fidelity can be reviewed locally.
    private static func offscreenFallback(_ window: NSWindow, webView: WKWebView?, name: String, directory: URL) async {
        func save(_ data: Data, suffix: String, note: String) {
            guard let bitmap = NSBitmapImageRep(data: data) else { return }
            let file = "\(name)-\(suffix).png"
            do { try data.write(to: directory.appendingPathComponent(file)) }
            catch { manifest.failures.append("\(name): fallback write failed"); return }
            manifest.evidence.append(Scene(name: "\(name)-\(suffix)", file: file, width: bitmap.pixelsWide, height: bitmap.pixelsHigh,
                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), keyWindow: window.isKeyWindow, note: note))
        }
        var pageImage: NSImage?
        if let webView {
            let configuration = WKSnapshotConfiguration()
            configuration.rect = NSRect(origin: .zero, size: webView.superview?.bounds.size ?? webView.bounds.size)
            configuration.afterScreenUpdates = true
            for _ in 0..<3 {
                if let candidate = try? await webView.takeSnapshot(configuration: configuration),
                   let tiff = candidate.tiffRepresentation, let pixels = NSBitmapImageRep(data: tiff) {
                    var colors: Set<String> = []
                    for y in stride(from: 0, to: pixels.pixelsHigh, by: max(1, pixels.pixelsHigh / 60)) {
                        for x in stride(from: 0, to: pixels.pixelsWide, by: max(1, pixels.pixelsWide / 60)) {
                            if let color = pixels.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                                colors.insert(String(format: "%.2f,%.2f,%.2f", color.redComponent, color.greenComponent, color.blueComponent))
                            }
                        }
                    }
                    if colors.count > 1 { pageImage = candidate; break }
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        if let image = pageImage,
           let tiff = image.tiffRepresentation, let data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            save(data, suffix: "page", note: "In-process WKWebView.takeSnapshot, page only; no glass/chrome acceptance")
        } else if webView != nil { manifest.skipped.append("\(name)-page: visual-foreground-only; off-screen WebKit fixture stayed blank after three in-process snapshot attempts") }
        if let frame = window.contentView?.superview, let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
            frame.layoutSubtreeIfNeeded(); frame.cacheDisplay(in: frame.bounds, to: bitmap)
            if let pageImage, let host = webView?.superview {
                var rect = host.convert(host.bounds, to: frame)
                if frame.isFlipped { rect.origin.y = frame.bounds.maxY - rect.maxY }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                NSBezierPath(rect: rect).addClip()
                pageImage.draw(in: rect)
                NSGraphicsContext.restoreGraphicsState()
            }
            if let data = bitmap.representation(using: .png, properties: [:]) {
                save(data, suffix: "opaque-fallback", note: "cacheDisplay non-glass chrome plus clipped WKWebView snapshot. Reduce Transparency variant; no Liquid Glass acceptance. Inspect before accepting.")
            }
        }
    }
}
/// Keeps capture windows off every display, even when they become key (AppKit would otherwise
/// move a key window on screen, where it can flash and pick up the real pointer's hover state).
private final class OffscreenWindow: BackgroundUIMode.Window {
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
