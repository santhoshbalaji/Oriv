import AppKit
import SwiftUI
import BrowserCore
import BrowserEngine

enum SettingsPane: String, CaseIterable, Hashable {
    case general, profiles, continuity, appearance, privacy, passwords, about

    var title: String { self == .continuity ? OrivStrings.sync : rawValue.capitalized }
    var identifier: NSToolbarItem.Identifier { .init(rawValue: rawValue) }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .profiles: "person.crop.rectangle.stack"
        case .continuity: "laptopcomputer.and.iphone"
        case .appearance: "paintpalette"
        case .privacy: "shield.lefthalf.filled"
        case .passwords: "key"
        case .about: "info.circle"
        }
    }
}

struct AppearanceSettings: View {
    @Environment(\.colorSchemeContrast) private var contrast
    private var theme: Theme { appearance.theme.respecting(contrast) }
    @Binding var appearance: BrowserAppearance
    @AppStorage(SidebarGlassOpacity.preferenceKey) private var sidebarGlassOpacity: SidebarGlassOpacity = .balanced
    let controller: BrowserController
    var profiles: BrowserProfiles? = nil
    private var adBlocker: AdBlocker { controller.session.adBlocker }
    @State private var defaultBrowserStatus = ""
    @State private var changingDefault = false
    @State private var websiteData = false
    @State private var clearBrowsingData = false
    var initialPane: SettingsPane = .general
    @State private var pane: SettingsPane?
    private let runtime = BrowserRuntime.current
    private var panes: [SettingsPane] {
        SettingsPane.allCases.filter { profiles != nil || ($0 != .profiles && $0 != .continuity) }
    }
    private var selectedPane: SettingsPane {
        let selection = pane ?? initialPane
        return panes.contains(selection) ? selection : .general
    }

    var body: some View {
        panel
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(OrivSpacing.large)
            .frame(width: 640, height: 580)
            .background(theme.canvas)
            .background {
                SettingsToolbar(panes: panes, selection: selectedPane) { pane = $0 }
            }
            .preferredColorScheme(appearance.colorScheme)
            .sheet(isPresented: $websiteData) { WebsiteDataView(manager: controller.session.websiteData) }
            .sheet(isPresented: $clearBrowsingData) { ClearBrowsingDataView(session: controller.session) }
            .environment(\.browserTheme, theme)
    }

    @ViewBuilder private var panel: some View {
        switch selectedPane {
        case .general: generalPanel
        case .profiles: if let profiles { ProfilesView(profiles: profiles, canSwitch: false).padding(8) }
        case .continuity: if let profiles { ContinuitySettingsView(continuity: profiles.continuity) }
        case .appearance: appearancePanel
        case .privacy: privacyPanel
        case .passwords: ScrollView { PasswordsGuide() }
        case .about: aboutPanel
        }
    }

    private var generalPanel: some View {
        @Bindable var settings = controller.session.settings
        return Form {
            Section("Browsing") {
                if let profiles {
                    Toggle(OrivStrings.openLinksPrivately, isOn: Binding(get: { profiles.openExternalLinksPrivately }, set: { profiles.openExternalLinksPrivately = $0 })).tint(theme.accent)
                    Text("External links open signed out, separate from every profile. Move a page to a profile when you choose.").font(OrivType.caption).foregroundStyle(theme.secondaryText)
                }
                BrowsingPreferencePicker(title: "Search engine", selection: $settings.searchEngine,
                                         options: SearchEngine.allCases, label: \.rawValue)
                Text("Searches are sent only when you submit them. Address suggestions use local tabs, saved pages and history.").font(.caption).foregroundStyle(theme.secondaryText)
                Toggle("Restore tabs when Oriv starts", isOn: $settings.restoreTabs).tint(theme.accent)
                Text("Pinned tabs always return. Private tabs are never restored. This takes effect on the next launch.").font(.caption).foregroundStyle(theme.secondaryText)
                BrowsingPreferencePicker(title: "Default page zoom", selection: $settings.defaultZoom,
                                         options: [0.75, 0.9, 1, 1.1, 1.25, 1.5, 2], label: { "\(Int($0 * 100))%" })
                Text("Applies to newly opened tabs.").font(.caption).foregroundStyle(theme.secondaryText)
            }
            Section("Default browser") {
                Button("Make \(AppIdentity.name) the Default Browser…") {
                    changingDefault = true
                    Task {
                        defer { changingDefault = false }
                        do {
                            for scheme in ["https", "http"] { try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: scheme) }
                            defaultBrowserStatus = isDefaultBrowser ? "\(AppIdentity.name) is your default browser." : "The change wasn’t confirmed for both HTTP and HTTPS. Check macOS Settings."
                        } catch { defaultBrowserStatus = "The default browser wasn’t changed for every scheme. \(error.localizedDescription)" }
                    }
                }.disabled(changingDefault || isDefaultBrowser)
                Text(defaultBrowserStatus.isEmpty ? (isDefaultBrowser ? "\(AppIdentity.name) is your default browser." : "macOS will ask you to confirm this change.") : defaultBrowserStatus)
                    .font(.caption).foregroundStyle(theme.secondaryText)
            }
        }.formStyle(.grouped)
    }
    private var isDefaultBrowser: Bool {
        ["http", "https"].allSatisfy { scheme in
            NSWorkspace.shared.urlForApplication(toOpen: URL(string: "\(scheme)://example.com")!)?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
        }
    }

    private var appearancePanel: some View {
        Form {
            Section {
                HStack(spacing: OrivSpacing.medium) {
                    ForEach(BrowserAppearance.allCases) { choice in
                        Button { appearance = choice } label: {
                            VStack(spacing: OrivSpacing.small) {
                                AppearancePreview(choice: choice)
                                Text(choice.displayName).font(OrivType.body.weight(appearance == choice ? .semibold : .regular))
                                Image(systemName: appearance == choice ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(appearance == choice ? theme.accent : theme.secondaryText)
                            }.padding(OrivSpacing.small).frame(maxWidth: .infinity)
                        }.orivButton(.quiet).accessibilityLabel("Use \(choice.displayName) appearance")
                            .accessibilityAddTraits(appearance == choice ? [.isSelected] : [])
                    }
                }
                Text(OrivStrings.appearanceSummary)
                    .font(OrivType.detail).foregroundStyle(theme.secondaryText)
            } header: {
                Text("Appearance for the \(controller.profile?.name ?? "Private") profile")
                    .browserGeometryMarker("settingsAppearanceHeader")
            }
            if let profileColor = controller.sidebarProfileColor(in: profiles) {
                Section("Sidebar color") {
                    VStack(alignment: .leading, spacing: OrivSpacing.medium) {
                        HStack(spacing: OrivSpacing.small) {
                            sidebarSwatch(.graphite, profileColor: profileColor).frame(width: 108)
                            sidebarSwatch(.profile, profileColor: profileColor).frame(width: 108)
                        }
                        HStack(spacing: OrivSpacing.small) {
                            ForEach(SidebarColor.allCases.dropFirst(2), id: \.self) { choice in
                                sidebarSwatch(choice, profileColor: profileColor)
                            }
                        }
                    }
                    .disabled(appearance == .t3Code)
                    if appearance == .t3Code {
                        Text("Sidebar color is available in System, Light and Dark.")
                            .font(OrivType.caption).foregroundStyle(theme.secondaryText)
                    }
                }
            }
            Section("All profiles") {
                if let profiles {
                    Picker("Swipe between profiles", selection: Binding(
                        get: { profiles.profileSwipePreference }, set: { profiles.profileSwipePreference = $0 }
                    )) {
                        ForEach(ProfileSwipePreference.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                }
                Picker("Glass opacity", selection: $sidebarGlassOpacity) {
                    ForEach(SidebarGlassOpacity.allCases, id: \.self) { choice in
                        Text(choice.rawValue).tag(choice)
                    }
                }.pickerStyle(.segmented)
            }
            Section("Sidebar for this profile") {
                Toggle("Show sidebar when hovering over collapsed tabs", isOn: Binding(get: { controller.hoverSidebar }, set: { controller.hoverSidebar = $0 }))
                Text("Off by default. Hover reveals titles over the page. Use ⌥⌘S to expand or collapse with the keyboard. Hover reveal is suspended while VoiceOver is running.")
                    .font(OrivType.caption).foregroundStyle(theme.secondaryText)
            }
        }.formStyle(.grouped)
    }

    private func sidebarSwatch(_ choice: SidebarColor, profileColor: ProfileColor) -> some View {
        let selected = controller.sidebarColor == choice
        let shape = RoundedRectangle(cornerRadius: OrivRadius.small)
        return Button {
            controller.sidebarColor = choice
        } label: {
            VStack(spacing: OrivSpacing.xs) {
                shape.fill(choice.backing(in: .graphite, profileColor: profileColor))
                    .frame(height: 24)
                    .overlay { shape.strokeBorder(selected ? theme.accent : theme.separator, lineWidth: selected ? 2 : 1) }
                    .overlay {
                        if selected {
                            Image(systemName: "checkmark").font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.graphite.text)
                        }
                    }
                Text(choice.title).font(OrivType.caption.weight(selected ? .semibold : .regular))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .orivButton(.quiet)
        .accessibilityLabel(choice.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var privacyPanel: some View {
        Form {
            Section("Browsing data") {
                Button("Manage Website Data…") { websiteData = true }
                Button("Clear Browsing Data…") { clearBrowsingData = true }
                Text("Review cookies and offline storage, or clear history and caches by time range.").font(.caption).foregroundStyle(theme.secondaryText)
                if !controller.session.settings.rules.isEmpty {
                    DisclosureGroup("Site permissions (\(controller.session.settings.rules.count))") {
                        ForEach(controller.session.settings.rules.keys.sorted(), id: \.self) { origin in
                            HStack { Text(origin).lineLimit(1); Spacer(); Button("Reset") { controller.session.settings.removeRule(origin) } }
                        }
                    }
                }
            }
            Section {
                PrivacySettingsControls(session: controller.session)
                Picker("Ad blocking", selection: Binding(get: { adBlocker.mode }, set: { adBlocker.setMode($0) })) {
                    ForEach(AdBlockingMode.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).tint(theme.accent)
                Text(adBlocker.mode.detail).font(.callout).foregroundStyle(theme.secondaryText)
                if adBlocker.mode == .strict {
                    if adBlocker.isPreparingCNAME { ProgressView(OrivStrings.preparingTrackerProtection) }
                    if let error = adBlocker.cnamePreparationError { Text(error).foregroundStyle(theme.danger) }
                }
                if !adBlocker.regularExceptions.isEmpty {
                    DisclosureGroup("Allowed sites (\(adBlocker.regularExceptions.count))") {
                        ForEach(adBlocker.regularExceptions.sorted(), id: \.self) { host in
                            HStack {
                                Text(host).lineLimit(1)
                                Spacer()
                                Button("Remove") { adBlocker.removeRegularException(host) }
                                    .accessibilityLabel("Remove exception for \(host)")
                            }
                        }
                    }
                }
            } header: { Text("Protection while you browse") } footer: {
                Text("Applies to normal and private tabs. Reload open pages to apply changes fully. Private site exceptions are forgotten when the last private tab closes.")
            }
        }.formStyle(.grouped)
    }
    private var aboutPanel: some View {
        VStack(alignment: .leading, spacing: 24) {
            OrivIdentity()
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                GridRow { Text(AppIdentity.name).foregroundStyle(theme.secondaryText); Text("\(runtime.appVersion) (\(runtime.appBuild))") }
                GridRow { Text("Build").foregroundStyle(theme.secondaryText); Text(AppIdentity.channel) }
                GridRow { Text("macOS").foregroundStyle(theme.secondaryText); Text(runtime.operatingSystem) }
                GridRow { Text("Protection list version").foregroundStyle(theme.textSecondary); Text(AdBlocker.rulesVersion) }
                GridRow { Text("WebKit").foregroundStyle(theme.secondaryText); Text(runtime.webKitBuild) }
            }.font(.callout).textSelection(.enabled)
            if AppIdentity.isDevelopment {
                Text("Development build. Its browsing profiles and website data are separate from the installed Oriv release.")
                    .font(.callout).foregroundStyle(theme.secondaryText)
            }
            Divider()
            Text("Built with SwiftUI and WebKit. The browser engine is supplied by macOS; install macOS and Safari updates for engine fixes and media support.")
                .font(.callout).foregroundStyle(theme.secondaryText).lineSpacing(3)
            Spacer()
        }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A native pop-up exposes both its label and AppKit's standard AX press action.
private struct BrowsingPreferencePicker<Value: Equatable>: View {
    let title: String
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String

    var body: some View {
        LabeledContent {
            Popup(title: title, selection: $selection, options: options, label: label)
                .fixedSize()
        } label: {
            Text(title).accessibilityHidden(true)
        }
    }

    private struct Popup: NSViewRepresentable {
        let title: String
        @Binding var selection: Value
        let options: [Value]
        let label: (Value) -> String

        func makeNSView(context: Context) -> Control {
            let button = Control(frame: .zero, pullsDown: false)
            button.setAccessibilityLabel(title)
            button.target = button
            button.action = #selector(Control.choose)
            return button
        }

        func updateNSView(_ button: Control, context: Context) {
            let titles = options.map(label)
            if button.itemTitles != titles {
                button.removeAllItems()
                button.addItems(withTitles: titles)
            }
            button.selectItem(at: options.firstIndex(of: selection) ?? -1)
            button.onSelect = { index in
                if options.indices.contains(index) { selection = options[index] }
            }
        }

        final class Control: NSPopUpButton {
            var onSelect: ((Int) -> Void)?
            @objc func choose() { onSelect?(indexOfSelectedItem) }
        }
    }
}

/// AppKit owns the icon, label and accent rendering for each selection item.
private struct SettingsToolbar: NSViewRepresentable {
    let panes: [SettingsPane]
    let selection: SettingsPane
    let select: (SettingsPane) -> Void

    func makeNSView(context: Context) -> ToolbarHost { ToolbarHost() }
    func updateNSView(_ view: ToolbarHost, context: Context) {
        view.panes = panes
        view.selection = selection
        view.select = select
        view.installToolbar()
    }

    final class ToolbarHost: NSView, NSToolbarDelegate {
        var panes: [SettingsPane] = []
        var selection = SettingsPane.general
        var select: ((SettingsPane) -> Void)?
        private lazy var settingsToolbar: NSToolbar = {
            let toolbar = NSToolbar(identifier: "OrivSettings")
            toolbar.delegate = self
            toolbar.autosavesConfiguration = false
            toolbar.allowsUserCustomization = false
            toolbar.displayMode = .iconAndLabel
            return toolbar
        }()

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            installToolbar()
        }

        func installToolbar() {
            guard let window, !panes.isEmpty else { return }
            let identifiers = panes.map(\.identifier)
            if window.toolbar !== settingsToolbar {
                window.toolbarStyle = .preference
                window.styleMask.remove(.fullSizeContentView)
                window.title = "\(AppIdentity.name) Settings"
                window.setAccessibilityIdentifier("orivSettingsWindow")
                window.toolbar = settingsToolbar
            }
            if settingsToolbar.itemIdentifiers != identifiers { settingsToolbar.itemIdentifiers = identifiers }
            if settingsToolbar.selectedItemIdentifier != selection.identifier {
                settingsToolbar.selectedItemIdentifier = selection.identifier
            }
        }

        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { panes.map(\.identifier) }
        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { panes.map(\.identifier) }
        func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { panes.map(\.identifier) }

        func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                     willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
            guard let pane = panes.first(where: { $0.identifier == identifier }) else { return nil }
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = pane.title
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
            item.target = self
            item.action = #selector(selectItem(_:))
            return item
        }

        @objc private func selectItem(_ item: NSToolbarItem) {
            if let pane = panes.first(where: { $0.identifier == item.itemIdentifier }) { select?(pane) }
        }
    }
}
