import SwiftUI
import XCTest
import BrowserCore
import BrowserEngine
import WebKit
@testable import OrivMobile

@MainActor final class DesignSystemCaptureTests: XCTestCase {
    private var directory: URL!
    private var window: UIWindow!
    private var log: [String] = []

    private func shot(_ name: String, wait: Int = 900) async throws {
        try await Task.sleep(for: .milliseconds(wait))
        let format = UIGraphicsImageRendererFormat(); format.scale = 2; format.opaque = true
        let bounds = window.bounds
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
            self.window.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent(name + ".png"))
        log.append(name)
    }
    private func firstResponder(in view: UIView) -> UIView? {
        if view.isFirstResponder { return view }
        for sub in view.subviews { if let found = firstResponder(in: sub) { return found } }
        return nil
    }
    private func scrollViews(in view: UIView, into list: inout [UIScrollView]) {
        if let scroll = view as? UIScrollView, !(view is WKWebView), scroll.contentSize.height > scroll.bounds.height + 40 { list.append(scroll) }
        for sub in view.subviews { scrollViews(in: sub, into: &list) }
    }
    private func scrollPresented(toBottom: Bool) {
        guard let presented = window.rootViewController?.presentedViewController else { return }
        var list: [UIScrollView] = []; scrollViews(in: presented.view, into: &list)
        guard let scroll = list.first else { return }
        let y = toBottom ? scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom : -scroll.adjustedContentInset.top
        scroll.setContentOffset(CGPoint(x: 0, y: y), animated: false)
    }
    private func present<V: View>(_ name: String, _ controller: MobileController, bottom: Bool = false, @ViewBuilder _ content: () -> V) async throws {
        let host = UIHostingController(rootView: NavigationStack { content() }
            .browserAppearance(controller.appearance).environment(\.siteIcons, controller.session.siteIcons))
        host.overrideUserInterfaceStyle = window.overrideUserInterfaceStyle
        window.rootViewController?.present(host, animated: false)
        try await shot(name, wait: 1100)
        if bottom { scrollPresented(toBottom: true); try await shot(name + "-bottom", wait: 600) }
        host.dismiss(animated: false)
        try await Task.sleep(for: .milliseconds(500))
    }
    private func sheet(_ name: String, _ controller: MobileController, _ sheet: MobileSheet, bottom: Bool = false, wait: Int = 1300) async throws {
        controller.sheet = sheet
        try await shot(name, wait: wait)
        if bottom { scrollPresented(toBottom: true); try await shot(name + "-bottom", wait: 600) }
        controller.sheet = nil
        try await Task.sleep(for: .milliseconds(900))
    }
    private func load(_ tab: BrowserTab, card: Int, dark: Bool, scheme: String = "https") async throws {
        tab.stop(); tab.dismissError()
        tab.webView.loadHTMLString(ChromeVisualFixture.html(dark: dark, card: card), baseURL: URL(string: "\(scheme)://docs.example/designing-calm-interfaces-\(card)"))
        for _ in 0..<80 { if !tab.webView.isLoading && tab.webView.url != nil { break }; try await Task.sleep(for: .milliseconds(50)) }
    }

    func testCaptureInventory() async throws {
        #if targetEnvironment(simulator)
        guard let path = ProcessInfo.processInfo.environment["ORIV_DESIGN_CAPTURE_DIR"] else {
            throw XCTSkip("Run with scripts/capture-iphone-design.sh to render the design inventory.")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let profiles = MobileProfiles(forceEphemeral: true)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }
        window.rootViewController = UIHostingController(rootView: DesignCaptureRoot(profiles: profiles))
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(1200))
        let controller = profiles.current
        for (name, appearance) in [("light", BrowserAppearance.light), ("dark", .dark), ("black", .t3Code)] {
            controller.appearance = appearance
            window.overrideUserInterfaceStyle = appearance == .light ? .light : .dark
            for variant in ["standard", "reduced", "increased"] {
                try await present("\(name)-gallery-\(variant)", controller) {
                    DesignSystemGallery()
                        .environment(\.chromeReduceTransparencyOverride, variant == "reduced")
                        .environment(\.chromeContrastOverride, variant == "increased" ? .increased : nil)
                }
            }
        }
        let session = controller.session
        func mode(_ dark: Bool) async throws {
            window.overrideUserInterfaceStyle = dark ? .dark : .light
            controller.appearance = dark ? .dark : .light
            try await Task.sleep(for: .milliseconds(700))
        }
        // Empty start page, both modes, before any data exists.
        try await mode(false); window.endEditing(true); try await shot("light-01-start-empty")
        try await mode(true); try await shot("dark-01-start-empty")
        session.importBookmarks([
            Bookmark(title: "Atlas", url: URL(string: "https://atlas.example/")!),
            Bookmark(title: "Paper Library", url: URL(string: "https://library.example/shelf")!),
            Bookmark(title: "Evening Radio", url: URL(string: "https://radio.example/")!),
            Bookmark(title: "Coastal Research Archive", url: URL(string: "https://coastal-research-archive.example/reports/2026")!),
            Bookmark(title: "Example Guide", url: URL(string: "https://docs.example/guide/install")!),
        ])
        var seeded = false
        for dark in [false, true] {
            let p = dark ? "dark" : "light"
            try await mode(dark)
            if let first = session.tabs.first(where: { !$0.isPrivate }) { session.selectTab(first.id) }
            if !seeded {
                try await shot("\(p)-02-start")
            } else {
                let fresh = session.addTab(); _ = fresh
                try await shot("\(p)-02-start", wait: 1400)
            }
            // Address editing and suggestions.
            controller.addressFocusRequest += 1
            try await shot("\(p)-03-address-editing", wait: 1400)
            if let field = firstResponder(in: window) as? UITextField {
                field.insertText("ex")
                try await shot("\(p)-04-address-suggestions", wait: 1400)
                field.text = ""; field.sendActions(for: .editingChanged)
            } else { log.append("\(p)-04 skipped: no text field first responder") }
            window.endEditing(true)
            try await Task.sleep(for: .milliseconds(600))
            // Selecting another tab leaves address editing; the page loads in a new tab.
            let tab = session.addTab(select: true, load: false)
            try await Task.sleep(for: .milliseconds(600))
            try await load(tab, card: dark ? 2 : 0, dark: dark)
            try await shot("\(p)-05-page", wait: 1800)
            if !seeded {
                for i in 1..<4 {
                    let extra = session.addTab(select: false, load: false)
                    extra.webView.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
                    try await load(extra, card: i, dark: i == 2)
                }
                let secret = session.addTab(isPrivate: true, select: false, load: false)
                secret.webView.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
                try await load(secret, card: 1, dark: false)
                seeded = true
            }
            try await sheet("\(p)-06-tab-grid", controller, .tabs, wait: 2200)
            try await sheet("\(p)-07-library", controller, .library)
            try await sheet("\(p)-08-bookmarks", controller, .bookmarks)
            try await sheet("\(p)-09-history", controller, .history)
            try await sheet("\(p)-10-settings", controller, .settings, bottom: true)
            try await sheet("\(p)-11-site-settings", controller, .site, bottom: true)
            try await present("\(p)-12-appearance", controller) {
                MobileAppearanceSettings(appearance: .constant(controller.appearance), profileName: "Personal")
            }
            try await present("\(p)-13-clear-browsing-data", controller) { MobileClearBrowsingData(session: session) }
            try await present("\(p)-14-website-data", controller) { MobileWebsiteData(manager: session.websiteData) }
            try await present("\(p)-15-downloads", controller) { MobileDownloadsView(downloads: controller.downloads) }
            try await present("\(p)-16-continuity", controller, bottom: true) { ContinuitySettingsView(continuity: profiles.continuity) }
            try await present("\(p)-17-delete-profile", controller) { DeleteProfileConfirmation(profile: BrowserProfile(name: "Work"), confirm: {}) }
            // Private mode.
            if let secret = session.tabs.first(where: \.isPrivate) {
                session.selectTab(secret.id)
                try await shot("\(p)-18-private-page", wait: 1800)
                try await sheet("\(p)-19-private-tab-grid", controller, .tabs, wait: 2200)
            }
            let privateBlank = session.addTab(isPrivate: true)
            try await shot("\(p)-20-private-start", wait: 1400)
            session.closeTab(privateBlank.id)
            // Error state.
            if let first = session.tabs.first(where: { !$0.isPrivate }) { session.selectTab(first.id) }
            let broken = session.addTab(url: URL(string: "https://unreachable.invalid/page"))
            for _ in 0..<150 { if broken.errorMessage != nil { break }; try await Task.sleep(for: .milliseconds(100)) }
            log.append("\(p)-21 state: error=\(broken.errorMessage ?? "nil") url=\(broken.url?.absoluteString ?? "nil") loading=\(broken.isLoading) httpWarning=\(broken.httpWarningURL?.absoluteString ?? "nil")")
            try await shot("\(p)-21-error", wait: 900)
            session.closeTab(broken.id)
            let refused = session.addTab(url: URL(string: "http://127.0.0.1:9/unreachable"))
            for _ in 0..<80 { if refused.errorMessage != nil { break }; try await Task.sleep(for: .milliseconds(100)) }
            XCTAssertNotNil(refused.errorMessage, "A refused address should display the shared error state")
            XCTAssertEqual(refused.url, URL(string: "http://127.0.0.1:9/unreachable"))
            log.append("\(p)-21b state: error=\(refused.errorMessage ?? "nil") url=\(refused.url?.absoluteString ?? "nil") loading=\(refused.isLoading) httpWarning=\(refused.httpWarningURL?.absoluteString ?? "nil")")
            try await shot("\(p)-21b-refused", wait: 900)
            session.closeTab(refused.id)
            // Insecure page cue.
            let plain = session.addTab(select: true, load: false)
            try await load(plain, card: 3, dark: dark, scheme: "http")
            try await shot("\(p)-22-not-secure", wait: 1600)
            session.closeTab(plain.id)
            if let first = session.tabs.first(where: { !$0.isPrivate && $0.url != nil }) { session.selectTab(first.id) }
            try await Task.sleep(for: .milliseconds(600))
        }
        // Large accessibility text (light).
        try await mode(false)
        window.traitOverrides.preferredContentSizeCategory = .accessibilityExtraLarge
        try await shot("light-30-ax-page", wait: 1500)
        try await sheet("light-31-ax-tab-grid", controller, .tabs, wait: 2200)
        try await sheet("light-32-ax-settings", controller, .settings)
        try await sheet("light-33-ax-library", controller, .library)
        try await present("light-34-ax-appearance", controller) {
            MobileAppearanceSettings(appearance: .constant(controller.appearance), profileName: "Personal")
        }
        let blank = session.addTab()
        try await shot("light-35-ax-start", wait: 1500)
        session.closeTab(blank.id)
        window.traitOverrides.remove(UITraitPreferredContentSizeCategory.self)
        // External private link with its banner.
        try await mode(false)
        profiles.route(URL(string: "http://127.0.0.1:9/external-link")!)
        try await Task.sleep(for: .milliseconds(1500))
        if let external = profiles.externalPrivate, let tab = external.session.selectedTab {
            tab.stop(); tab.dismissError()
            tab.webView.loadHTMLString(ChromeVisualFixture.html(dark: false, card: 1), baseURL: URL(string: "https://docs.example/from-another-app"))
            try await Task.sleep(for: .milliseconds(1500))
        }
        window.overrideUserInterfaceStyle = .light
        try await shot("light-40-external-private", wait: 1200)
        window.overrideUserInterfaceStyle = .dark
        try await shot("dark-40-external-private", wait: 1200)
        try (log.joined(separator: "\n") + "\n").write(to: directory.appendingPathComponent("captures.txt"), atomically: true, encoding: .utf8)
        #else
        throw XCTSkip("Design inventory is a simulator fixture.")
        #endif
    }
}

private struct DesignCaptureRoot: View {
    let profiles: MobileProfiles
    var body: some View {
        MobileBrowserView(controller: profiles.current, profiles: profiles).id(profiles.current.profileID)
            .browserAppearance(profiles.current.appearance, followsPage: true).environment(\.scenePhase, .active)
    }
}
