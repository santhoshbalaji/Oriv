import AppKit
import SwiftUI
import XCTest
@testable import PersonalBrowser

@MainActor final class SettingsToolbarTests: BackgroundUITestCase {
    func testNativeSettingsItemsAndContentInEveryAppearance() async throws {
        let profiles = BrowserProfiles(testing: true)
        defer { profiles.shutdown() }
        for appearance in [BrowserAppearance.light, .dark, .t3Code, .system] {
            let host = NSHostingController(rootView: AppearanceSettings(appearance: .constant(appearance),
                controller: profiles.controller, profiles: profiles, initialPane: .appearance))
            host.sceneBridgingOptions = [.toolbars, .title]
            let window = BackgroundUIMode.Window(contentRect: NSRect(x: 0, y: 0, width: 660, height: 580),
                styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance == .light ? .aqua : .darkAqua)
            window.contentViewController = host
            window.setContentSize(NSSize(width: 660, height: 580))
            BackgroundUIMode.show(window, key: false)
            defer { window.close() }

            func marker(in view: NSView) -> NSView? {
                if view.identifier?.rawValue == "settingsAppearanceHeader", !view.bounds.isEmpty { return view }
                return view.subviews.lazy.compactMap(marker).first
            }
            try await eventually("native Settings toolbar and Appearance header") {
                host.view.layoutSubtreeIfNeeded()
                return window.toolbar?.visibleItems?.count == 7 && marker(in: host.view) != nil
            }
            let toolbar = try XCTUnwrap(window.toolbar)
            XCTAssertEqual(toolbar.items.map(\.label), ["General", "Profiles", "Sync", "Appearance", "Privacy", "Passwords", "About"])
            XCTAssertTrue(toolbar.items.allSatisfy { $0.image?.isTemplate == true && $0.view == nil })
            XCTAssertEqual(toolbar.displayMode, .iconAndLabel)
            XCTAssertEqual(toolbar.selectedItemIdentifier, SettingsPane.appearance.identifier)
            XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
            XCTAssertEqual(window.toolbarStyle, .preference)
            let appearanceHeight = window.frame.height
            let header = try XCTUnwrap(marker(in: host.view))
            let headerFrame = header.convert(header.bounds, to: nil)
            XCTAssertLessThan(headerFrame.maxY, window.contentLayoutRect.maxY - 1)
            XCTAssertTrue(window.contentLayoutRect.insetBy(dx: -1, dy: -1).contains(headerFrame))

            let frame = try XCTUnwrap(window.contentView?.superview)
            window.displayIfNeeded()
            let bitmap = try XCTUnwrap(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
            frame.cacheDisplay(in: frame.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "settings-appearance-\(appearance.rawValue)"
            attachment.lifetime = .keepAlways
            add(attachment)

            let privacy = try XCTUnwrap(toolbar.items.first { $0.itemIdentifier == SettingsPane.privacy.identifier })
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(privacy.action), to: privacy.target, from: privacy))
            try await eventually("Privacy toolbar selection") {
                toolbar.selectedItemIdentifier == SettingsPane.privacy.identifier && marker(in: host.view) == nil
                    && window.frame.height > appearanceHeight
            }
        }
    }

    func testProfileSwitchKeepsTheSettingsToolbarAndSelectedPane() async throws {
        let profiles = BrowserProfiles(testing: true)
        defer { profiles.shutdown() }
        let work = try profiles.create(name: "Work", color: .ocean, symbol: .work)
        let host = NSHostingController(rootView: ProfileSettings(profiles: profiles))
        host.sceneBridgingOptions = [.toolbars, .title]
        let window = BackgroundUIMode.Window(contentRect: NSRect(x: 0, y: 0, width: 660, height: 500),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        BackgroundUIMode.show(window, key: false)
        defer { window.close() }

        try await eventually("Settings toolbar installed") { window.toolbar?.items.count == 7 }
        let toolbar = try XCTUnwrap(window.toolbar)
        let profilesItem = try XCTUnwrap(toolbar.items.first { $0.itemIdentifier == SettingsPane.profiles.identifier })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(profilesItem.action), to: profilesItem.target, from: profilesItem))
        try await eventually("Profiles selected") { toolbar.selectedItemIdentifier == SettingsPane.profiles.identifier }

        // Changing the color scheme forces a Settings redraw after switching.
        profiles.controller.appearance = .light
        try profiles.select(work.id)
        profiles.controller.appearance = .dark
        try await eventually("Settings follows the new profile’s color scheme") {
            host.view.layoutSubtreeIfNeeded()
            return window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
        XCTAssertTrue(window.toolbar === toolbar)
        XCTAssertEqual(toolbar.selectedItemIdentifier, SettingsPane.profiles.identifier)
    }

}
