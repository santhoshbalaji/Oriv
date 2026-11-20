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
            if ["sidebar-contrast", "p2", "sidebar-opacity", "phase2-contrast"].contains(environment["ORIV_GLASS_SCENE"] ?? "") {
                manifest.limitations.append("All windows stay off every display. Contrast matrix uses the real sidebar with a known white/black/purple glass input and labelled page swatch; the header is a layout spacer. It renders the production contrast backing and controls; reduced/increased variants use the opaque accessibility path. These are synthetic compositing/layout images, not live Liquid Glass acceptance.")
            } else {
                manifest.limitations.append("All windows stay off every display. Sidebar/glass fallback fixtures use the app's opaque Reduce Transparency variant; they cannot verify Liquid Glass.")
            }
        }
        if environment["ORIV_BATCH_VISUALS"] == "1" { await renderBatchScenes(into: directory, activate: activate) }
        else if environment["ORIV_GLASS_SCENE"] == "sidebar-live" { await renderLiveSidebar(into: directory, activate: activate) }
        else if let sites = environment["ORIV_LIVE_SITES"], !sites.isEmpty { await renderLiveSites(sites, into: directory, activate: activate) }
        else if environment["ORIV_GLASS_SCENE"] == "p3-github" { await renderGitHubFavicon(into: directory, activate: activate) }
        else if environment["ORIV_GLASS_SCENE"] == "phase5" { await renderProfileSwipeScenes(into: directory) }
        else if environment["ORIV_GLASS_SCENE"] == "phase2" { await renderThemeScenes(into: directory) }
        else if environment["ORIV_GLASS_SCENE"] == "phase2-contrast" { await renderThemeContrast(into: directory) }
        else if environment["ORIV_GLASS_SCENE"] == "p3-rtl" { await renderRightToLeft(into: directory, activate: activate) }
        else if environment["ORIV_GLASS_SCENE"] == "p2" { await renderP2Scenes(into: directory, activate: activate) }
        else if environment["ORIV_GLASS_SCENE"] == "sidebar-opacity" { await renderSidebarOpacity(into: directory) }
        else if environment["ORIV_GLASS_SCENE"] == "sidebar-contrast" { await renderSidebarContrastScenes(into: directory, activate: activate) }
        else if environment["ORIV_GLASS_SCENE"] == "sidebar-width" { await renderSidebarWidthScenes(into: directory) }
        else if environment["ORIV_GLASS_SCENE"] == "sidebar-b" { await renderSidebarBScenes(into: directory, activate: activate) }
        else if environment["ORIV_GLASS_SCENE"] == "sidebar-attached" { await renderAttachedSidebarScenes(into: directory, activate: activate) }
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

    private static func renderProfileSwipeScenes(into directory: URL) async {
        func seedTabs(_ controller: BrowserController, names: [String]) {
            for (index, name) in names.enumerated() {
                let tab = controller.session.addTab(url: URL(string: "https://example.test/\(index)"), select: false, load: false)
                tab.webView.loadHTMLString("<title>\(name)</title><p>Profile swipe fixture</p>", baseURL: URL(string: "https://example.test"))
                if index < 2 { controller.session.togglePinned(tab.id) }
            }
        }
        func anchor(in view: NSView) -> ProfileSidebarAnchor.Anchor? {
            if let anchor = view as? ProfileSidebarAnchor.Anchor, anchor.bounds.width > 0 { return anchor }
            for child in view.subviews {
                if let match = anchor(in: child) { return match }
            }
            return nil
        }
        func scroll(_ phase: NSEvent.Phase, dx: Int32) -> NSEvent? {
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                      wheel1: 0, wheel2: dx, wheel3: 0) else { return nil }
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase == .began ? 1 : 2)
            return NSEvent(cgEvent: event)
        }
        let scenes: [(String, BrowserAppearance, Int, Double, Bool, Bool, Bool)] =
            [("light-two", .light, 2, 0, false, false, false),
             ("light-three", .light, 3, 0, false, false, false),
             ("light-five", .light, 5, 0, false, false, false),
             ("dark-two", .dark, 2, 0, false, false, false),
             ("dark-three", .dark, 3, 0, false, false, false),
             ("dark-five", .dark, 5, 0, false, false, false),
             ("rtl", .light, 3, 0, true, false, false),
             ("light-swipe-30", .light, 3, 0.3, false, false, false),
             ("dark-swipe-50", .dark, 3, 0.5, false, false, false),
             ("t3-swipe-100", .t3Code, 3, 1, false, false, false),
             ("rtl-swipe-50", .light, 3, 0.5, true, false, false),
             ("reduce-motion-50", .dark, 3, 0.5, false, true, false),
             ("increase-contrast", .light, 3, 0, false, false, true)]
        for (scene, appearance, count, progress, rtl, reduceMotion, contrast) in scenes {
            let profiles = BrowserProfiles(testing: true)
            defer { profiles.shutdown() }
            profiles.profileSwipePreference = .on
            let source = profiles.controller
            source.appearance = appearance
            guard let work = try? profiles.create(name: "Work", color: .ocean, symbol: .work) else {
                manifest.failures.append("Could not create profile fixture")
                continue
            }
            for name in ["Reading", "Travel", "Studio"].prefix(count - 2) {
                _ = try? profiles.create(name: name, color: .fern, symbol: .study)
            }
            if progress > 0 {
                try? profiles.select(work.id)
                profiles.controller.appearance = appearance
                seedTabs(profiles.controller, names: ["Project notes", "Roadmap", "Team handbook", "Design review"])
                try? profiles.select(BrowserProfile.personalID)
            }
            seedTabs(source, names: ["Reading list", "Field guides", "Weekend routes", "Library catalogue"])
            await capture("mac-profile-\(scene)", directory, CGSize(width: 960, height: 620), key: false, settle: 350,
                          appearance: appearance, prepare: { window in
                guard progress > 0 else { return }
                window.contentView?.layoutSubtreeIfNeeded()
                guard let content = window.contentView, let region = anchor(in: content),
                      let began = scroll(.began, dx: 0),
                      let moved = scroll(.changed, dx: Int32(progress * region.bounds.width) * (rtl ? 1 : -1)) else {
                    manifest.failures.append("Missing gesture region for \(scene)")
                    return
                }
                let point = region.convert(NSPoint(x: region.bounds.midX, y: region.bounds.midY), to: nil)
                _ = profiles.sidebarSwitch.route(began, window: window, profiles: profiles, source: source, location: point)
                guard profiles.sidebarSwitch.route(moved, window: window, profiles: profiles, source: source, location: point),
                      profiles.sidebarSwitch.isCovering else {
                    manifest.failures.append("Synthetic swipe did not track for \(scene)")
                    return
                }
                await Task.yield()
            }) {
                BrowserWindow(controller: source, profiles: profiles)
                    .overlay { ProfileSidebarOverlayHost(switcher: profiles.sidebarSwitch) }
                    .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
                    .environment(\.sidebarCaptureReduceMotion, reduceMotion)
                    .environment(\.sidebarCaptureContrast, contrast ? .increased : nil)
                    .environment(\.chromeReduceTransparencyOverride, true)
            }
            if let window = source.sidebarWindow { profiles.sidebarSwitch.cancel(in: window) }
        }
    }

    private static func renderBatchScenes(into directory: URL, activate: Bool) async {
        let profiles = BrowserProfiles(testing: true)
        let controller = profiles.controller
        defer { profiles.shutdown() }
        let session = controller.session
        guard let tab = session.selectedTab else { manifest.failures.append("No fixture tab"); return }
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='128' height='128'><rect width='128' height='128' rx='24' fill='#217f67'/><path d='M28 64L54 90L102 38' stroke='white' stroke-width='13' fill='none'/></svg>"
        let icon = "data:image/svg+xml;base64," + Data(svg.utf8).base64EncodedString()
        let url = URL(string: "https://example.test/guide")!
        tab.webView.loadHTMLString("<html><head><title>Example Guide</title><link rel='icon' href='\(icon)'></head><body style='font:22px system-ui;padding:40px;background:#f7f6f2'><h1>Example Guide</h1><p>Local visual fixture.</p></body></html>", baseURL: url)
        for _ in 0..<200 {
            if tab.webView.title == "Example Guide", !tab.webView.isLoading { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        await session.siteIcons.load(url, isPrivate: false)
        if session.siteIcons.icon(for: url, isPrivate: false) == nil { manifest.failures.append("Fixture favicon missing") }
        _ = session.importBookmarks([Bookmark(title: "Example Reference", url: URL(string: "https://example.test/reference")!)])
        let matches = AddressSuggestions()
        await matches.update("exa", session: session, isPrivate: false)
        for (name, appearance) in [("light", BrowserAppearance.light), ("dark", .dark)] {
            await capture("mac-batch-sidebar-\(name)", directory, CGSize(width: 1000, height: 650), key: activate, compositeWeb: tab.webView, appearance: appearance) {
                BrowserWindow(controller: controller, profiles: profiles).frame(width: 1000, height: 650)
                    .environment(\.chromeReduceTransparencyOverride, true)
            }
            await capture("mac-batch-suggestions-\(name)", directory, CGSize(width: 760, height: 380), key: activate, appearance: appearance) {
                AddressSuggestionList(suggestions: matches.rows, selectedIndex: 0, address: "exa", engine: session.settings.searchEngine,
                    isPrivate: false, choose: { _ in }, submit: {})
                    .frame(width: 720).padding(20).frame(width: 760, height: 380, alignment: .top)
                    .environment(\.siteIcons, session.siteIcons)
            }
        }
    }

    private static func renderThemeScenes(into directory: URL) async {
        let size = CGSize(width: 1120, height: 760)
        for appearance in [BrowserAppearance.light, .dark, .t3Code] {
            let name = "mac-glass-theme-" + (appearance == .t3Code ? "t3-code" : appearance.rawValue.lowercased())
            let profiles = seededProfiles()
            let controller = profiles.controller
            controller.appearance = appearance
            for (surface, compact) in [("expanded", false), ("rail", true)] {
                controller.compactSidebar = compact
                await capture("\(name)-\(surface)", directory, size, key: false, appearance: appearance) {
                    BrowserWindow(controller: controller, profiles: profiles)
                }
            }
            await capture("\(name)-settings", directory, CGSize(width: 672, height: 612),
                          key: false, toolbarStyle: .preference, appearance: appearance) {
                AppearanceSettings(appearance: .constant(appearance), controller: controller, profiles: profiles, initialPane: .appearance)
            }
            let privateID = profiles.createPrivateWindow()
            if let context = profiles.privateWindows[privateID] {
                await capture("\(name)-private", directory, size, key: false, appearance: appearance) {
                    BrowserWindow(controller: context)
                }
            }
            profiles.shutdown()
        }
    }

    private static func renderThemeContrast(into directory: URL) async {
        for appearance in [BrowserAppearance.light, .dark, .t3Code] {
            let mode = appearance == .t3Code ? "t3-code" : appearance.rawValue.lowercased()
            let profiles = seededProfiles()
            let controller = profiles.controller
            controller.appearance = appearance
            let backdrop: Color = appearance == .light ? .black : .white
            let variants = SidebarGlassOpacity.allCases.map { ($0.rawValue.lowercased(), $0) }
                + [("reduced", .balanced), ("increased", .balanced)]
            for (state, compact) in [("expanded", false), ("rail", true)] {
                controller.compactSidebar = compact
                for (variant, opacity) in variants {
                    let name = "mac-glass-sidebar-contrast-theme-\(mode)-\(state)-\(variant)"
                    await capture(name, directory, CGSize(width: 420, height: 580), key: false, settle: 400, appearance: appearance) {
                        HStack(spacing: 0) {
                            BrowserSidebar(controller: controller, profiles: profiles)
                                .frame(width: compact ? MacBrowserLayout.railWidth : MacBrowserLayout.sidebarWidth)
                                .modifier(MacSidebarGlass())
                            backdrop
                        }
                        .environment(\.sidebarCaptureBackdrop, backdrop)
                        .environment(\.sidebarCaptureOpacity, opacity)
                        .environment(\.chromeReduceTransparencyOverride, variant == "reduced")
                        .environment(\.sidebarCaptureContrast, variant == "increased" ? .increased : nil)
                        .environment(\.siteIcons, controller.session.siteIcons)
                    }
                }
            }
            profiles.shutdown()
        }
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

    private static func renderGitHubFavicon(into directory: URL, activate: Bool) async {
        let controller = BrowserController(testing: true)
        defer { controller.shutdown() }
        let session = controller.session
        guard let home = session.selectedTab else { return }
        let url = URL(string: "https://github.com/")!
        let tab = session.addTab()
        tab.navigate(to: url)
        let name = "mac-glass-github-favicon"
        await capture(name, directory, CGSize(width: 1150, height: 720), key: activate,
                      appearance: .light, prepare: { window in
            let deadline = ContinuousClock.now + .seconds(30)
            while (tab.isLoading || session.siteIcons.icon(for: url, isPrivate: false) == nil) && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard session.siteIcons.icon(for: url, isPrivate: false) != nil else {
                manifest.failures.append("GitHub favicon discovery did not produce visible artwork")
                return
            }
            session.toggleBookmark()
            session.selectTab(home.id)
            try? await Task.sleep(for: .milliseconds(350))
            writeSidebarGeometry(window, to: directory.appendingPathComponent(name + "-geometry.json"))
        }) {
            BrowserWindow(controller: controller).environment(\.chromeReduceTransparencyOverride, true)
        }
    }

    private static func renderRightToLeft(into directory: URL, activate: Bool) async {
        let profiles = BrowserProfiles(testing: true)
        defer { profiles.shutdown() }
        let controller = profiles.controller
        for index in 1...4 {
            let tab = controller.session.addTab(url: URL(string: "https://site\(index).example"), select: false, load: false)
            controller.session.togglePinned(tab.id)
        }
        let size = CGSize(width: 1150, height: 720)
        for (label, appearance) in [("light", BrowserAppearance.light), ("dark", .dark)] {
            for rail in [false, true] {
                controller.compactSidebar = rail
                let name = "mac-glass-rtl-\(label)-\(rail ? "rail" : "expanded")"
                await capture(name, directory, size, key: activate, appearance: appearance, prepare: { window in
                    writeSidebarGeometry(window, to: directory.appendingPathComponent(name + "-geometry.json"))
                    if window.standardWindowButton(.closeButton).map({ $0.convert($0.bounds, to: nil).midX }) ?? 0 < size.width / 2 {
                        manifest.failures.append("\(name): expected native window buttons on the RTL leading edge")
                    }
                }) {
                    BrowserWindow(controller: controller, profiles: profiles)
                        .environment(\.chromeReduceTransparencyOverride, true)
                }
            }
        }
    }

    private static func renderP2Scenes(into directory: URL, activate: Bool) async {
        let root = directory.appendingPathComponent("p2-fixture")
        let home = TabRecord()
        let tabs = [
            TabRecord(title: "Field Notes", url: URL(string: "https://atlas.example")),
            TabRecord(title: "Field Notes", url: URL(string: "https://coastal-research-archive.example")),
            TabRecord(title: "Reading List", url: URL(string: "https://paper.example"))
        ]
        let bookmarks = [
            Bookmark(title: "Atlas", url: tabs[0].url!),
            Bookmark(title: "Paper Library", url: tabs[2].url!),
            Bookmark(title: "Evening Radio", url: URL(string: "https://radio.example")!)
        ]
        let history = [
            HistoryEntry(title: "Coastal Research Archive", url: tabs[1].url!, visitCount: 12),
            HistoryEntry(title: "Weather Desk", url: URL(string: "https://weather.example")!, visitCount: 8),
            HistoryEntry(title: "Design Journal", url: URL(string: "https://design.example")!, visitCount: 5)
        ]
        let profileRoot = BrowserProfile.personal.directory(in: root)
        do {
            try SessionFileStore(fileURL: profileRoot.appendingPathComponent("session.json"))
                .save(BrowserSnapshot(tabs: [home] + tabs, selectedTabID: home.id, bookmarks: bookmarks,
                                      history: history, legacyBookmarksImported: true), discardPrevious: true)
        } catch { manifest.failures.append("P2 fixture: \(error)"); return }
        let controller = BrowserController(rootDirectory: root, testing: true)
        defer { controller.shutdown() }
        let icons = SiteIconDiskCache(directory: profileRoot.appendingPathComponent("Favicons"))
        let artwork: [(Color, String)] = [
            (.teal, "map.fill"), (.indigo, "books.vertical.fill"), (.red, "waveform"),
            (.blue, "water.waves"), (.orange, "cloud.sun.fill"), (.purple, "scribble")
        ]
        for (url, (color, symbol)) in zip(bookmarks.map(\.url) + history.map(\.url), artwork) {
            let renderer = ImageRenderer(content: ZStack {
                RoundedRectangle(cornerRadius: 10).fill(color)
                Image(systemName: symbol).font(.system(size: 21, weight: .semibold)).foregroundStyle(.white)
            }.frame(width: 36, height: 36))
            renderer.scale = 2
            if let cg = renderer.cgImage, let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]),
               let icon = await icons.decode(data), let key = SiteIconStore.key(url, isPrivate: false) {
                await icons.write(icon, key: key)
                await controller.session.siteIcons.loadCached(url)
            } else { manifest.failures.append("P2 favicon fixture could not render") }
        }
        func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let match = view as? T { return match }
            return view.subviews.lazy.compactMap { find(type, in: $0) }.first
        }
        let size = CGSize(width: 1150, height: 720)
        let appearances = [("light", BrowserAppearance.light), ("dark", .dark)]
        for (label, appearance) in appearances {
            for layout in ["expanded", "rail"] {
                controller.compactSidebar = layout == "rail"
                let name = "mac-glass-p2-\(label)-\(layout)"
                await capture(name, directory, size, key: activate, appearance: appearance, prepare: { window in
                    writeSidebarGeometry(window, to: directory.appendingPathComponent(name + "-geometry.json"))
                    if label == "light", layout == "expanded", let content = window.contentView,
                       let data = find(SidebarTabCollection.self, in: content)?.sidebar,
                       let tab = controller.session.tabs.first(where: { $0.id == tabs[0].id }) {
                        let items = data.menu(for: tab).items.map { $0.isSeparatorItem ? "—" : $0.title }
                        if let receipt = try? JSONEncoder().encode(items) {
                            try? receipt.write(to: directory.appendingPathComponent("tab-menu-geometry.json"))
                        }
                    }
                }) {
                    BrowserWindow(controller: controller).frame(width: size.width, height: size.height)
                        .environment(\.chromeReduceTransparencyOverride, true)
                }
            }
        }
        manifest.skipped.append("mac-glass-p2-menu: native NSMenu tracking uses a display-constrained system window. The command inventory was read without opening it.")
        controller.compactSidebar = false
        controller.newTab(isPrivate: true)
        await capture("mac-glass-p2-private", directory, size, key: activate, appearance: .dark) {
            BrowserWindow(controller: controller).frame(width: size.width, height: size.height)
                .environment(\.chromeReduceTransparencyOverride, true)
        }
        controller.session.selectTab(home.id)
        controller.session.clearHistory()
        for (label, appearance) in appearances {
            await capture("mac-glass-p2-\(label)-no-history", directory, size, key: activate, appearance: appearance) {
                BrowserWindow(controller: controller).frame(width: size.width, height: size.height)
                    .environment(\.chromeReduceTransparencyOverride, true)
            }
            let backdrop = Color(.sRGB, red: 0.04, green: 0.67, blue: 0.64)
            for variant in ["glass-input", "reduced", "increased"] {
                let name = "mac-glass-sidebar-contrast-p2-\(label)-\(variant)"
                await capture(name, directory, size, key: activate, appearance: appearance) {
                    HStack(spacing: 0) {
                        BrowserSidebar(controller: controller).padding(.top, 24)
                            .frame(width: MacBrowserLayout.sidebarWidth)
                            .background { Color.clear.modifier(MacSidebarGlass()) }
                        LinearGradient(colors: [backdrop, .indigo, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)
                            .overlay(alignment: .topLeading) {
                                Text("Synthetic colour input").font(.title).foregroundStyle(.white).padding(32)
                            }
                    }.frame(width: size.width, height: size.height)
                        .environment(\.siteIcons, controller.session.siteIcons)
                        .environment(\.sidebarCaptureBackdrop, backdrop)
                        .environment(\.chromeReduceTransparencyOverride, variant == "reduced")
                        .environment(\.sidebarCaptureContrast, variant == "increased" ? .increased : .standard)
                }
            }
        }
    }

    private static func renderSidebarOpacity(into directory: URL) async {
        let profiles = BrowserProfiles(rootDirectory: directory.appendingPathComponent("opacity-fixture"), testing: true)
        defer { profiles.shutdown() }
        let controller = profiles.controller
        for title in ["Maps", "Reading List", "Weather"] {
            _ = controller.session.addTab(url: URL(string: "https://example.test/\(title.replacingOccurrences(of: " ", with: "-"))"),
                                          select: false, load: false)
        }
        await capture("mac-glass-sidebar-contrast-opacity-settings", directory, CGSize(width: 672, height: 612),
                      key: false, appearance: .light) {
            AppearanceSettings(appearance: .constant(.light), controller: controller, initialPane: .appearance)
        }
        let backdrop = Color(.sRGB, red: 96.0 / 255, green: 0, blue: 217.0 / 255)
        for appearance in [BrowserAppearance.light, .dark] {
            for choice in SidebarGlassOpacity.allCases {
                let name = "mac-glass-sidebar-contrast-opacity-\(appearance.rawValue.lowercased())-\(choice.rawValue.lowercased())"
                await capture(name, directory, CGSize(width: 780, height: 560), key: false, appearance: appearance) {
                    HStack(spacing: 0) {
                        BrowserSidebar(controller: controller, profiles: profiles)
                            .padding(.horizontal, 10)
                            .frame(width: MacBrowserLayout.sidebarWidth)
                            .background { Color.clear.modifier(MacSidebarGlass()) }
                        backdrop.overlay(alignment: .topLeading) {
                            Text("Synthetic glass input").font(.title).foregroundStyle(.white).padding(32)
                        }
                    }
                    .background(backdrop)
                    .environment(\.sidebarCaptureBackdrop, backdrop)
                    .environment(\.sidebarCaptureOpacity, choice)
                    .environment(\.siteIcons, controller.session.siteIcons)
                }
            }
        }
    }

    private static func renderSidebarContrastScenes(into directory: URL, activate: Bool) async {
        let root = directory.appendingPathComponent("contrast-fixture")
        let records = [TabRecord(title: "Maps", url: URL(string: "https://maps.example"), isPinned: true),
                       TabRecord(title: "Wikipedia – Liquid", url: URL(string: "https://wiki.example/liquid")),
                       TabRecord(title: "Reading list", url: URL(string: "https://reading.example"))]
        do {
            try SessionFileStore(fileURL: BrowserProfile.personal.directory(in: root).appendingPathComponent("session.json"))
                .save(BrowserSnapshot(tabs: records, selectedTabID: records[1].id), discardPrevious: true)
        } catch { manifest.failures.append("Contrast fixture: \(error)"); return }
        let profiles = BrowserProfiles(rootDirectory: root, testing: true)
        defer { profiles.shutdown() }
        let controller = profiles.controller
        _ = controller.session.addTab(isPrivate: true, select: false, load: false)
        guard let tab = controller.session.selectedTab else { manifest.failures.append("No contrast fixture tab"); return }
        for (page, hex, backdrop) in [("white", "#ffffff", Color.white), ("black", "#000000", Color.black),
                                      ("purple", "#6000d9", Color(.sRGB, red: 96.0 / 255, green: 0, blue: 217.0 / 255))] {
            let title = "Wikipedia – \(page) fixture"
            tab.webView.loadHTMLString("<title>\(title)</title><body style='margin:0;background:\(hex);color:\(page == "white" ? "black" : "white");font:24px system-ui;padding:60px;height:2000px'><h1>Wikipedia</h1><p>Local contrast fixture: \(page).</p></body>", baseURL: records[1].url)
            for _ in 0..<200 {
                if tab.webView.title == title && !tab.webView.isLoading { break }
                try? await Task.sleep(for: .milliseconds(25))
            }
            guard tab.webView.title == title else { manifest.failures.append("Contrast page did not load: \(page)"); continue }
            for (mode, appearance) in [("light", BrowserAppearance.light), ("dark", .dark)] {
                for variant in ["glass-input", "reduced", "increased"] {
                    for state in ["expanded", "rail", "search"] {
                        controller.compactSidebar = state == "rail"
                        controller.tabSearch = state == "search" ? "wiki" : ""
                        let name = "mac-glass-sidebar-contrast-\(mode)-\(page)-\(state)-\(variant)"
                        await capture(name, directory, CGSize(width: 1000, height: 760), key: activate, settle: 300,
                                      expectedFields: state == "search" ? ["tabSearchField": "wiki"] : [:], appearance: appearance,
                                      prepare: { window in
                                          if state == "search" { controller.searchTabs(); try? await Task.sleep(for: .milliseconds(100)) }
                                          writeSidebarGeometry(window, to: directory.appendingPathComponent(name + "-geometry.json"))
                                      }) {
                            // Isolate the real sidebar from the header's remote
                            // glass layers, which AppKit cannot cache off-screen.
                            // The page is a labelled exact-colour swatch, not WKWebView.
                            HStack(spacing: 0) {
                                VStack(spacing: 0) {
                                    HStack {
                                        Spacer()
                                        Image(systemName: "sidebar.left").frame(width: 32, height: 32)
                                    }.padding(.horizontal, 12).frame(height: MacBrowserLayout.headerHeight)
                                        .foregroundStyle(appearance.theme.text)
                                    BrowserSidebar(controller: controller, profiles: profiles).padding(.horizontal, 10)
                                }
                                .frame(width: controller.compactSidebar ? MacBrowserLayout.railWidth : MacBrowserLayout.sidebarWidth)
                                .background { Color.clear.modifier(MacSidebarGlass()) }
                                backdrop.overlay(alignment: .topLeading) {
                                    VStack(alignment: .leading, spacing: 24) {
                                        Text("Wikipedia").font(.system(size: 40, weight: .bold))
                                        Text("Synthetic \(page) page / sampled glass input")
                                    }.foregroundStyle(page == "white" ? .black : .white).padding(48)
                                }
                            }
                                .frame(width: 1000, height: 760).background(backdrop)
                                .environment(\.siteIcons, controller.session.siteIcons)
                                .environment(\.sidebarCaptureBackdrop, backdrop)
                                .environment(\.chromeReduceTransparencyOverride, variant == "reduced")
                                .environment(\.sidebarCaptureContrast, variant == "increased" ? .increased : .standard)
                        }
                    }
                }
            }
        }
    }

    /// Same real-window fixture before and after the sidebar change. Sleeping tabs
    /// are metadata only; generated local icons go through the production cache.
    private static func renderSidebarWidthScenes(into directory: URL) async {
        let root = directory.appendingPathComponent("sidebar-fixture")
        let home = TabRecord()
        let pins = (1...8).map { TabRecord(url: URL(string: "https://pin\($0).example"), isPinned: true) }
        let long = TabRecord(title: "A field guide to quieter interfaces and more considered everyday browsing",
                             url: URL(string: "https://field-guide.example"))
        let duplicates = ["docs", "help"].map {
            TabRecord(title: "Project notes", url: URL(string: "https://\($0).research-and-development.example"))
        }
        do {
            try SessionFileStore(fileURL: BrowserProfile.personal.directory(in: root).appendingPathComponent("session.json"))
                .save(BrowserSnapshot(tabs: pins + [home, long] + duplicates, selectedTabID: home.id))
        } catch { manifest.failures.append("Sidebar width fixture: \(error)"); return }

        let profiles = BrowserProfiles(rootDirectory: root, testing: true)
        defer { profiles.shutdown() }
        let controller = profiles.controller
        controller.session.addTab(isPrivate: true, select: false, load: false)
        let privateID = profiles.createPrivateWindow()
        guard let privateController = profiles.privateWindows[privateID] else {
            manifest.failures.append("Dedicated private window fixture missing"); return
        }
        privateController.session.addTab(isPrivate: true, select: false, load: false)

        for (mode, appearance) in [("light", BrowserAppearance.light), ("dark", .dark), ("rtl", .light), ("private", .dark)] {
            let name = "mac-glass-sidebar-width-\(mode)"
            let isPrivate = mode == "private"
            await capture(name, directory, CGSize(width: 1000, height: 680), key: false, appearance: appearance,
                          prepare: { window in
                              writeSidebarGeometry(window, to: directory.appendingPathComponent(name + "-geometry.json"))
                          }) {
                BrowserWindow(controller: isPrivate ? privateController : controller, profiles: isPrivate ? nil : profiles)
                    .environment(\.layoutDirection, mode == "rtl" ? .rightToLeft : .leftToRight)
                    .environment(\.chromeReduceTransparencyOverride, true)
                    .environment(\.sidebarCaptureState, SidebarCaptureState(hover: long.id))
            }
        }

        guard let file = NSApp.mainMenu?.items.first(where: { $0.title == "File" })?.submenu else {
            manifest.failures.append("AppKit File menu missing"); return
        }
        let modifiers: [(NSEvent.ModifierFlags, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        let items = file.items.map { item in
            let keys = modifiers.filter { item.keyEquivalentModifierMask.contains($0.0) }.map(\.1).joined()
            return ["title": item.title, "keyEquivalent": item.keyEquivalent,
                    "shortcut": item.keyEquivalent.isEmpty ? "" : keys + item.keyEquivalent.uppercased()]
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: items, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appendingPathComponent("file-menu.json"))
        } catch { manifest.failures.append("File menu inventory: \(error)") }
    }

    private static func renderSidebarBScenes(into directory: URL, activate: Bool) async {
        manifest.limitations.append("Benchmark matrix: 12/50/100 metadata tabs, nine pins, duplicate site icons, private tabs and long titles. Hover/focus and audio/loading visuals use Debug-only presentation inputs; native timing, focus, status labels and cancellation have separate tests. These images do not simulate real pointer movement or compositor motion.")
        let titles = ["Atlas Maps", "Postbox", "Orbit Code", "Paper Library", "Design resources", "Weekend in the mountains",
                      "A field guide to quieter interfaces and more considered everyday browsing", "Evening radio",
                      "Reading list", "Earth from above", "Ideas for the next chapter"]
        for count in [12, 50, 100] {
            let root = directory.appendingPathComponent("fixture-\(count)")
            let records = (0..<(count - 1)).map { index in
                TabRecord(title: titles[index % titles.count] + (index >= titles.count ? " \(index + 1)" : ""),
                          url: URL(string: "https://site\((index == 10 ? 9 : index) % titles.count).example/story/\(index)"), isPinned: index < 9)
            }
            do {
                let profileRoot = BrowserProfile.personal.directory(in: root)
                try SessionFileStore(fileURL: profileRoot.appendingPathComponent("session.json"))
                    .save(BrowserSnapshot(tabs: records, selectedTabID: records[9].id), discardPrevious: true)
                let disk = SiteIconDiskCache(directory: profileRoot.appendingPathComponent("Favicons"))
                for index in titles.indices {
                    let colors: [UInt32] = [0x238A71, 0x337AD0, 0x454453, 0xAF6738, 0x8C62C4, 0x4A7B8B, 0x5B7956, 0xC84D64, 0xB88226, 0x27749A, 0xA15881]
                    let symbols = ["map.fill", "envelope.fill", "curlybraces", "book.closed.fill", "square.stack.3d.up.fill", "mountain.2.fill", "leaf.fill", "waveform", "text.alignleft", "globe.asia.australia.fill", "paintpalette.fill"]
                    let hex = colors[index]
                    let renderer = ImageRenderer(content: ZStack {
                        RoundedRectangle(cornerRadius: 7).fill(Color(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1))
                        Image(systemName: symbols[index]).font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                    }.frame(width: 32, height: 32))
                    renderer.scale = 2
                    guard let cg = renderer.cgImage else { manifest.failures.append("Sidebar favicon render failed"); continue }
                    let image = NSImage(cgImage: cg, size: NSSize(width: 32, height: 32))
                    if let data = image.tiffRepresentation, let icon = await disk.decode(data),
                       let key = SiteIconStore.key(records[index].url!, isPrivate: false) {
                        await disk.write(icon, key: key)
                    }
                }
            } catch { manifest.failures.append("Sidebar fixture: \(error)"); continue }
            let profiles = BrowserProfiles(rootDirectory: root, testing: true)
            let controller = profiles.controller, session = controller.session
            let privateTab = session.addTab(isPrivate: true, select: false, load: false)
            privateTab.webView.loadHTMLString("<title>A gift, kept private</title><body>Private fixture</body>", baseURL: URL(string: "https://private.example"))
            for record in records.prefix(titles.count) { await session.siteIcons.load(record.url!, isPrivate: false) }
            let tab = session.selectedTab!
            for (mode, appearance) in [("light", BrowserAppearance.light), ("dark", .dark)] {
                tab.webView.loadHTMLString(sidebarFixture(color: mode == "light" ? "#f3f5ef" : "#202a25", light: mode == "light").replacingOccurrences(of: "<title>Found, don’t follow</title>", with: "<title>\(titles[6])</title>"), baseURL: records[9].url)
                for _ in 0..<100 { if !tab.webView.isLoading && tab.webView.title != nil { break }; try? await Task.sleep(for: .milliseconds(25)) }
                var scenes: [(Int, Bool, String)] = [820, 1280].flatMap { width in [false, true].map { (width, $0, "default") } }
                if count == 100 { scenes += [false, true].map { (1280, $0, "scrolled") } }
                if count == 12 {
                    scenes += ["hover", "focus", "reduced", "increased", "motion"].flatMap { variant in [false, true].map { (1280, $0, variant) } }
                    scenes += ["peek", "search", "tooltip"].map { (1280, true, $0) }
                    scenes += [(760, false, "narrow")]
                }
                for (width, rail, variant) in scenes {
                    controller.dismissTabSearch(); controller.sidebar.dismissOverlay(); controller.sidebarTooltip.dismiss()
                    controller.sidebar.resize(availableWidth: 1280)
                    controller.compactSidebar = false; controller.hoverSidebar = variant == "peek"
                    let suffix = variant == "default" ? "" : "-" + variant
                    let name = "mac-glass-sidebar-b-\(count)-\(mode)-\(width)-\(rail ? "rail" : "expanded")\(suffix)"
                    let state = SidebarCaptureState(hover: variant == "hover" ? records[10].id : nil,
                                                    loading: records[10].id, audio: records[9].id)
                    await capture(name, directory, CGSize(width: width, height: 900), key: activate, compositeWeb: tab.webView, appearance: appearance,
                                  prepare: { window in
                                      controller.sidebar.resize(availableWidth: 1280)
                                      controller.sidebar.resize(availableWidth: CGFloat(width))
                                      if rail {
                                          let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option],
                                              timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                                              characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1)
                                          if let event, window.performKeyEquivalent(with: event) {
                                              try? await Task.sleep(for: .milliseconds(300))
                                          } else { manifest.failures.append("Sidebar shortcut unavailable: \(name)") }
                                      }
                                      if variant == "peek" {
                                          controller.sidebar.pointer(true)
                                          try? await Task.sleep(for: .milliseconds(500))
                                          if !controller.sidebar.peeking { manifest.failures.append("Peek did not open: \(name)") }
                                      }
                                      if variant == "focus" {
                                          @MainActor func collection(in view: NSView) -> SidebarTabCollection? {
                                              (view as? SidebarTabCollection) ?? view.subviews.lazy.compactMap(collection(in:)).first
                                          }
                                          window.contentView.flatMap(collection(in:))?.focusTab(records[9].id)
                                      }
                                      if variant == "search" { controller.searchTabs(); try? await Task.sleep(for: .milliseconds(250)) }
                                      if variant == "tooltip" {
                                          controller.sidebarTooltip.hover(id: records[9].id, text: SidebarTabs.label(tab, selected: true))
                                          try? await Task.sleep(for: .milliseconds(700))
                                      }
                                      if variant == "scrolled" {
                                          @MainActor func tabScroll(in view: NSView) -> NSScrollView? {
                                              if view.identifier?.rawValue.hasPrefix("sidebarItem-") == true {
                                                  return view.enclosingScrollView
                                              }
                                              return view.subviews.lazy.compactMap(tabScroll(in:)).first
                                          }
                                          if let scroll = window.contentView.flatMap(tabScroll(in:)) {
                                              let clip = scroll.contentView
                                              clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY + 810))
                                              scroll.reflectScrolledClipView(clip)
                                              try? await Task.sleep(for: .milliseconds(200))
                                              if clip.bounds.minY < 500 { manifest.failures.append("Sidebar did not scroll: \(name)") }
                                          } else { manifest.failures.append("Sidebar scroll view unavailable: \(name)") }
                                      }
                                      writeSidebarGeometry(window, to: directory.appendingPathComponent(name + "-geometry.json"))
                                  }) {
                        BrowserWindow(controller: controller, profiles: profiles)
                            .environment(\.chromeReduceTransparencyOverride, BackgroundUIMode.isEnabled || variant == "reduced")
                            .environment(\.sidebarCaptureContrast, variant == "increased" ? .increased : .standard)
                            .environment(\.sidebarCaptureReduceMotion, variant == "motion")
                            .environment(\.sidebarCaptureState, state)
                    }
                }
            }
            profiles.shutdown()
        }
        let profiles = BrowserProfiles(testing: true)
        profiles.handleIncomingURL(URL(string: "https://private.example/story")!, sourceName: "Example App")
        if let controller = profiles.externalPrivate, let tab = controller.session.selectedTab {
            tab.webView.loadHTMLString(sidebarFixture(color: "#351553", light: false), baseURL: URL(string: "https://private.example/story"))
            try? await Task.sleep(for: .milliseconds(700))
            for rail in [false, true] {
                controller.compactSidebar = rail
                await capture("mac-glass-sidebar-b-private-\(rail ? "rail" : "expanded")", directory, CGSize(width: 820, height: 900),
                              key: activate, compositeWeb: tab.webView, appearance: .dark) {
                    BrowserWindow(controller: controller, profiles: profiles).environment(\.chromeReduceTransparencyOverride, BackgroundUIMode.isEnabled)
                }
            }
        }
        profiles.shutdown()
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

    /// Real window/control hierarchy and real local input, with no display or
    /// system fullscreen transition. The native tests assert these same states.
    private static func renderAttachedSidebarScenes(into directory: URL, activate: Bool) async {
        manifest.limitations.append("Attached sidebar: opaque background layout evidence. Fullscreen is simulated; native menu/titlebar reveal, live glass and spoken VoiceOver require foreground acceptance. Focus states use synthesized window-local input, never global input.")
        for (mode, appearance) in [("light", BrowserAppearance.light), ("dark", .dark)] {
            let root = directory.appendingPathComponent("attached-\(mode)")
            let records = ["Field atlas", "Research notes", "Found, don’t follow", "Reading list"].enumerated().map { index, title in
                TabRecord(title: title, url: URL(string: "https://site\(index).example/guide"), isPinned: index == 0)
            }
            do {
                try SessionFileStore(fileURL: BrowserProfile.personal.directory(in: root).appendingPathComponent("session.json"))
                    .save(BrowserSnapshot(tabs: records, selectedTabID: records[2].id), discardPrevious: true)
            } catch { manifest.failures.append("Attached fixture: \(error)"); continue }
            let profiles = BrowserProfiles(rootDirectory: root, testing: true)
            let c = profiles.controller
            for (index, item) in c.session.orderedTabs.enumerated() {
                item.webView.loadHTMLString(sidebarFixture(color: mode == "light" ? "#f3f5ef" : "#202a25", light: mode == "light")
                    .replacingOccurrences(of: "<title>Found, don’t follow</title>", with: "<title>\(records[index].title)</title>"), baseURL: records[index].url)
            }
            for _ in 0..<100 {
                if c.session.tabs.allSatisfy({ !$0.webView.isLoading && $0.webView.title != nil }) { break }
                try? await Task.sleep(for: .milliseconds(25))
            }
            for fullscreen in [false, true] {
                for layout in ["expanded", "rail", "overlay"] {
                    let states = fullscreen || layout == "overlay" ? ["default"] : ["default", "mouse-toggle", "mouse-row", "keyboard", "selected-focused"]
                    for state in states {
                        c.dismissTabSearch(); c.sidebar.dismissOverlay(); c.sidebar.resize(availableWidth: 1280)
                        c.compactSidebar = false; c.session.selectTab(records[2].id)
                        let name = "mac-glass-sidebar-attached-\(mode)-\(fullscreen ? "fullscreen" : "windowed")-\(layout)-\(state)"
                        let width: CGFloat = layout == "overlay" ? 780 : 1280
                        let destination = state == "mouse-row" || (layout == "rail" && state == "keyboard") ? records[3].id : (state == "selected-focused" ? records[1].id : records[2].id)
                        let page = c.session.tabs.first { $0.id == destination }!.webView
                        await capture(name, directory, CGSize(width: width, height: 900), key: activate, compositeWeb: page, appearance: appearance,
                                      prepare: { window in
                            c.sidebar.resize(availableWidth: width)
                            c.compactSidebar = layout == "rail"
                            if fullscreen { simulateFullscreenLayout(in: window) }
                            try? await Task.sleep(for: .milliseconds(250))
                            func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
                            func marker(_ id: String) -> NSView? { window.contentView.flatMap { views($0).first { $0.identifier?.rawValue == id } } }
                            @MainActor func send(_ event: NSEvent?) {
                                if let event, let fixture = window as? OffscreenWindow { fixture.sendFixtureEvent(event) }
                                else { manifest.failures.append("Missing local fixture input: \(name)") }
                            }
                            @MainActor func down() {
                                send(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: window.windowNumber, context: nil, characters: "\u{f701}", charactersIgnoringModifiers: "\u{f701}", isARepeat: false, keyCode: 125))
                            }
                            if state == "keyboard" || state == "selected-focused" || state == "mouse-row" {
                                if layout == "rail" {
                                    // Start in expanded search, then preserve the
                                    // production keyboard handoff while collapsing.
                                    c.compactSidebar = false
                                }
                                c.searchTabs(); try? await Task.sleep(for: .milliseconds(250))
                                down(); try? await Task.sleep(for: .milliseconds(200))
                                if state == "selected-focused" { down(); try? await Task.sleep(for: .milliseconds(200)) }
                                if layout == "rail" {
                                    if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1) {
                                        if !window.performKeyEquivalent(with: event) { manifest.failures.append("Rail key equivalent failed: \(name)") }
                                    }
                                    try? await Task.sleep(for: .milliseconds(250))
                                    down(); try? await Task.sleep(for: .milliseconds(200))
                                    if state == "keyboard" { c.session.selectTab(records[3].id) }
                                }
                            }
                            if state == "mouse-toggle" || state == "mouse-row" {
                                if state == "mouse-toggle" { c.compactSidebar = layout != "rail"; try? await Task.sleep(for: .milliseconds(200)) }
                                let id = state == "mouse-toggle" ? "sidebarToggleGeometry" : "sidebarItem-\(records[3].id)"
                                if let target = marker(id) {
                                    let point = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
                                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                                        send(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
                                    }
                                } else { manifest.failures.append("Missing click target: \(name)") }
                                try? await Task.sleep(for: .milliseconds(250))
                            }
                            if c.sidebar.rail != (layout == "rail") { manifest.failures.append("Wrong sidebar mode: \(name)") }
                            if ["keyboard", "selected-focused"].contains(state), !(window.firstResponder is SidebarTabCollection) {
                                manifest.failures.append("Native sidebar focus missing: \(name)")
                            }
                            writeSidebarGeometry(window, to: directory.appendingPathComponent(name + "-geometry.json"))
                        }) {
                            BrowserWindow(controller: c, profiles: profiles)
                                .environment(\.chromeReduceTransparencyOverride, true).environment(\.sidebarCaptureReduceMotion, true)
                        }
                    }
                }
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
            let tab = view.identifier?.rawValue.hasPrefix("sidebarItem-") == true
            return (view is BrowserGeometryMarker.Marker || view is SidebarHitTarget.TargetView || tab ? [view] : [])
                + view.subviews.flatMap(markers)
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
            let children = node.accessibilityChildren() ?? []
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
        for mode in ["light", "light-scrolled", "dark", "dark-scrolled", "theme", "theme-scrolled", "focused", "menu", "menu-dark", "menu-private", "menu-narrow", "private", "reduced", "insecure"] where (requested == "all" && !mode.hasPrefix("menu-")) || mode == requested || (requested == "page-menu" && mode.hasPrefix("menu")) {
            let profiles = BrowserProfiles(testing: true)
            var controller = profiles.controller
            if mode == "private" || mode == "menu-private" {
                profiles.handleIncomingURL(URL(string: "https://docs.example.com/designing-calm-interfaces")!, sourceName: "Example App")
                controller = profiles.externalPrivate!
            }
            let tab = controller.session.selectedTab!
            let address = "\(mode == "insecure" ? "http" : "https")://docs.example.com/designing-calm-interfaces"
            var html = ChromeVisualFixture.html(dark: mode.hasPrefix("dark") || mode.hasPrefix("theme") || mode == "private" || mode == "menu-dark" || mode == "menu-private")
            if mode.hasPrefix("theme") { html = html.replacingOccurrences(of: "#111111", with: "#1F6F5C") }
            if mode == "private" || mode == "menu-private" { html = html.replacingOccurrences(of: "#111111", with: "#000000") }
            tab.webView.loadHTMLString(html, baseURL: URL(string: address))
            if mode != "private" && mode != "menu-private" {
                for (card, path) in [(1, "room"), (2, "materials")] {
                    let url = URL(string: "https://docs.example.com/\(path)")!
                    let backgroundTab = controller.session.addTab(url: url, select: false, load: false)
                    backgroundTab.webView.loadHTMLString(ChromeVisualFixture.html(card: card), baseURL: url)
                }
            }
            try? await Task.sleep(for: .milliseconds(900))
            await capture("mac-glass-\(mode)", directory, CGSize(width: mode == "menu-narrow" ? 760 : 1440, height: 848), key: activate, settle: 1_400, compositeWeb: tab.webView,
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
                BrowserWindow(controller: controller, profiles: profiles)
                    .environment(\.chromeReduceTransparencyOverride, BackgroundUIMode.isEnabled || mode == "reduced")
            }
            if mode.hasPrefix("menu") {
                manifest.skipped.append("mac-glass-\(mode)-expanded: native Menu is a separate AppKit tracking window, constrained to a display. Opening it would violate the background-only policy. Toolbar/layout evidence only.")
            }
            profiles.shutdown()
        }
    }

    /// Opt-in network evidence in the isolated snapshot app. Third-party images
    /// stay in temporary/build output, never in the public fixture resources.
    /// Explicit opt-in network evidence, outside the deterministic test gates.
    /// Exercises production completion/cache and key-equivalent paths; no icon
    /// seeding or direct discovery request can mask a missing lifecycle trigger.
    private static func renderLiveSidebar(into directory: URL, activate: Bool) async {
        let urls = (ProcessInfo.processInfo.environment["ORIV_LIVE_SITES"] ?? "").split(separator: ",").compactMap { URL(string: String($0)) }
        guard !urls.isEmpty, urls.allSatisfy({ $0.scheme == "https" }) else {
            manifest.failures.append("sidebar-live requires explicit HTTPS ORIV_LIVE_SITES"); return
        }
        let profiles = BrowserProfiles(testing: true)
        defer { profiles.shutdown() }
        let c = profiles.controller, session = c.session
        guard let first = session.selectedTab else { return }
        first.navigate(to: urls[0])
        let tabs = [first] + urls.dropFirst().map { session.addTab(url: $0, select: false, load: false) }
        var narrowPageWidth: CGFloat = 0
        for state in ["expanded", "rail", "overlay"] {
            let size = CGSize(width: state == "expanded" ? 1000 : 780, height: 820)
            await capture("mac-glass-sidebar-live-\(state)", directory, size, key: activate,
                          compositeWeb: first.webView, appearance: .dark, prepare: { window in
                if state == "expanded" {
                    for tab in tabs {
                        session.selectTab(tab.id)
                        let deadline = Date().addingTimeInterval(30)
                        while Date() < deadline {
                            if !tab.isLoading, tab.hasRenderedContent,
                               session.siteIcons.icon(for: tab.url, isPrivate: false) != nil { break }
                            try? await Task.sleep(for: .milliseconds(100))
                        }
                        if tab.isLoading || session.siteIcons.icon(for: tab.url, isPrivate: false) == nil {
                            manifest.failures.append("Live sidebar icon unavailable: \(tab.url?.host ?? "unknown")")
                        }
                    }
                    session.selectTab(first.id)
                    try? await Task.sleep(for: .milliseconds(600))
                } else if state == "rail" {
                    narrowPageWidth = first.webView.bounds.width
                    if !c.sidebar.rail { manifest.failures.append("780pt sidebar did not auto-collapse") }
                } else {
                    guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                        characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1),
                          window.performKeyEquivalent(with: event) else {
                        manifest.failures.append("Live sidebar key equivalent was not handled"); return
                    }
                    c.sidebar.pointer(false); c.sidebar.panelInside = false; c.sidebar.focusInside = false
                    try? await Task.sleep(for: .milliseconds(1500))
                    if !c.sidebar.narrowOverlay { manifest.failures.append("Live sidebar explicit overlay closed") }
                    if abs(first.webView.bounds.width - narrowPageWidth) > 1 { manifest.failures.append("Live sidebar overlay resized the page") }
                }
                let viewport = (try? await first.webView.evaluateJavaScript("innerWidth")) as? Double ?? 0
                let geometry: [String: Any] = ["windowWidth": window.contentView?.bounds.width ?? 0,
                    "pageWidth": first.webView.bounds.width, "viewportWidth": viewport,
                    "sidebarWidth": c.sidebar.width, "pageReservation": c.sidebar.reservation,
                    "overlay": c.sidebar.narrowOverlay,
                    "icons": tabs.map { ["url": $0.url?.absoluteString ?? "", "cached": session.siteIcons.icon(for: $0.url, isPrivate: false) != nil] as [String: Any] }]
                if let data = try? JSONSerialization.data(withJSONObject: geometry, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: directory.appendingPathComponent("mac-glass-sidebar-live-\(state)-geometry.json"))
                }
            }) { BrowserWindow(controller: c, profiles: profiles).environment(\.chromeReduceTransparencyOverride, true) }
        }
    }

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
                                               appearance: BrowserAppearance = .t3Code,
                                               covered: Bool = false,
                                               prepare: (NSWindow) async -> Void = { _ in },
                                               @ViewBuilder content: () -> Content) async {
        let hosting = NSHostingController(rootView: content().browserAppearance(appearance))
        hosting.sceneBridgingOptions = [.toolbars, .title]
        let liveGlass = ProcessInfo.processInfo.environment["ORIV_GLASS_SCENE"]?.isEmpty == false || ProcessInfo.processInfo.environment["ORIV_LIVE_SITES"]?.isEmpty == false
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        if liveGlass { style.insert(.fullSizeContentView) }
        let window = OffscreenWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: style, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance.colorScheme.map { NSAppearance(named: $0 == .light ? .aqua : .darkAqua)! }
        // Capture stable geometry, without an inferred WindowServer opening animation.
        window.animationBehavior = .none
        window.toolbarStyle = toolbarStyle
        if name.hasPrefix("mac-glass-sidebar-contrast-") {
            // Direct hosting avoids scene toolbar/title bridging, whose remote
            // layer tree is absent from AppKit's off-screen bitmap cache.
            window.contentView = NSHostingView(rootView: content().browserAppearance(appearance))
        } else {
            window.contentViewController = hosting
        }
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
            simulatedFullscreenLayout: (name.contains("sidebar-fullscreen") || name.contains("attached-") && name.contains("-fullscreen-")) && !BackgroundUIMode.foregroundAllowed)
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
            if BackgroundUIMode.isEnabled {
                manifest.skipped.append("\(name): visual-foreground-only; compositor and Liquid Glass captures are skipped under the off-screen policy.")
                await offscreenFallback(window, webView: webView, name: name, directory: directory)
                return
            }
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
        let contrastFixture = name.hasPrefix("mac-glass-sidebar-contrast-")
        let target = contrastFixture ? window.contentView : window.contentView?.superview
        if let frame = target, let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
            frame.layoutSubtreeIfNeeded()
            frame.needsDisplay = true
            window.contentView?.needsDisplay = true
            window.display()
            window.contentView?.display()
            window.contentView?.layer?.displayIfNeeded()
            frame.cacheDisplay(in: frame.bounds, to: bitmap)
            if name.hasPrefix("mac-glass-menu"), let raw = bitmap.representation(using: .png, properties: [:]) {
                save(raw, suffix: "chrome", note: "Uncomposited off-screen cacheDisplay of the real window; WebKit and glass may be blank. Preserves overlays that page compositing would cover.")
            }
            if let pageImage, let host = webView?.superview {
                var rect = host.convert(host.bounds, to: frame)
                if frame.isFlipped { rect.origin.y = frame.bounds.maxY - rect.maxY }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                NSBezierPath(rect: rect).addClip()
                // Page snapshots are painted behind real chrome overlays.
                func overlays(_ view: NSView) -> [NSView] {
                    let own = ["browserSidebarGeometry", "sidebarSearchPanel", "sidebarTooltipGeometry"].contains(view.identifier?.rawValue ?? "") ? [view] : []
                    return own + view.subviews.flatMap(overlays)
                }
                if let content = window.contentView {
                    for overlay in overlays(content) {
                        var excluded = overlay.convert(overlay.bounds, to: frame)
                        if frame.isFlipped { excluded.origin.y = frame.bounds.maxY - excluded.maxY }
                        let clip = NSBezierPath(rect: rect)
                        clip.appendRect(excluded.intersection(rect)); clip.windingRule = .evenOdd; clip.addClip()
                    }
                }
                pageImage.draw(in: rect)
                NSGraphicsContext.restoreGraphicsState()
            }
            if let data = bitmap.representation(using: .png, properties: [:]) {
                save(data, suffix: contrastFixture ? "synthetic-composite" : "opaque-fallback", note: contrastFixture
                     ? "Real sidebar over synthetic sampled glass input and labelled page swatch, with production contrast backing/controls. Header is a layout spacer. Reduced/increased scenes use opaque accessibility material. No live Liquid Glass acceptance."
                     : "cacheDisplay non-glass chrome plus clipped WKWebView snapshot. Reduce Transparency variant; no Liquid Glass acceptance. Inspect before accepting.")
            }
        }
    }
}
/// Keeps capture windows off every display, even when they become key (AppKit would otherwise
/// move a key window on screen, where it can flash and pick up the real pointer's hover state).
private final class OffscreenWindow: BackgroundUIMode.Window {
    private var fixtureInput = false
    func sendFixtureEvent(_ event: NSEvent) {
        fixtureInput = true
        defer { fixtureInput = false }
        NSApp.sendEvent(event)
    }
    /// Key appearance is needed for evidence, but real user input must never edit the scene.
    override func sendEvent(_ event: NSEvent) {
        if fixtureInput { super.sendEvent(event); return }
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
