import AppKit
import SwiftUI
import BrowserCore
import BrowserEngine

enum MacSettingsLayout {
    static let formHorizontalInset = OrivSpacing.xl
    static let formVerticalInset = OrivSpacing.large
    static let groupGap = OrivSpacing.larger
    static let groupHorizontalInset = OrivSpacing.large
    static let groupVerticalInset = OrivSpacing.medium
    static let rowGap = OrivSpacing.xs
    static let headingGap = OrivSpacing.small
}

enum SettingsPane: String, CaseIterable, Hashable {
    case general, profiles, continuity, appearance, privacy, passwords, about

    var title: String { self == .continuity ? OrivStrings.sync : rawValue.capitalized }
    // oriv:raw-metric Preferred Settings viewport heights, including the native toolbar.
    var windowHeight: CGFloat {
        switch self {
        case .general: 520
        case .profiles: 500
        case .continuity: 720
        case .appearance: 745
        case .privacy: 830
        case .passwords: 540
        case .about: AppIdentity.isDevelopment ? 500 : 430
        }
    }

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

struct ProfileSettings: View {
    let profiles: BrowserProfiles

    var body: some View {
        let controller = profiles.controller
        AppearanceSettings(appearance: Binding(get: { controller.appearance }, set: { controller.appearance = $0 }),
                           controller: controller, profiles: profiles)
    }
}

struct AppearanceSettings: View {
    @Environment(\.colorScheme) private var sidebarSwatchScheme
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.chromeContrastOverride) private var captureContrast
    @Environment(\.chromeReduceTransparencyOverride) private var captureReduceTransparency
    private var contrast: ColorSchemeContrast { captureContrast ?? systemContrast }
    private var reduceTransparency: Bool { systemReduceTransparency || captureReduceTransparency }
    private var solidBackdrop: Bool { appearance == .t3Code || reduceTransparency || contrast == .increased }
    private var theme: Theme { appearance.theme.respecting(contrast) }
    @Binding var appearance: BrowserAppearance
    @AppStorage(SidebarGlassOpacity.preferenceKey) private var sidebarGlassOpacity: SidebarGlassOpacity = .balanced
    let controller: BrowserController
    var profiles: BrowserProfiles? = nil
    private var adBlocker: AdBlocker { controller.session.adBlocker }
    @State private var defaultBrowserStatus = ""
    @State private var changingDefault = false
    private struct DataSheet: Identifiable {
        enum Kind { case websiteData, clearBrowsingData }
        let id: Kind
        let session: BrowserSession
    }
    @State private var dataSheet: DataSheet?
    @State private var acknowledgments = false
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

    private var profileScope: String { "This profile · \(controller.profile?.name ?? "Private")" }
    private var syncedScope: String {
        profiles?.continuity.state.enabled == true ? "\(profileScope) · Synced" : profileScope
    }

    var body: some View {
        panel
            // oriv:raw-metric Fixed width for seven native toolbar items; the height follows the pane.
            .frame(width: 660)
            .frame(minHeight: 300, idealHeight: selectedPane.windowHeight, maxHeight: .infinity)
            .background { windowBackdrop.ignoresSafeArea() }
            .background {
                SettingsToolbar(panes: panes, selection: selectedPane,
                                opaqueBackground: solidBackdrop || BackgroundUIMode.isEnabled,
                                increasedContrast: contrast == .increased,
                                opaqueColor: solidBackdrop ? theme.canvas : theme.chrome) { pane = $0 }
            }
            .preferredColorScheme(appearance.colorScheme)
            .sheet(item: $dataSheet) { sheet in
                switch sheet.id {
                case .websiteData: WebsiteDataView(manager: sheet.session.websiteData)
                case .clearBrowsingData: ClearBrowsingDataView(session: sheet.session)
                }
            }
            .sheet(isPresented: $acknowledgments) { PrivacyAcknowledgements() }
            .environment(\.browserTheme, theme)
    }

    @ViewBuilder private var windowBackdrop: some View {
        if solidBackdrop {
            theme.canvas.ignoresSafeArea()
        } else if BackgroundUIMode.isEnabled {
            theme.chrome
        } else {
            WindowBackdropMaterial(material: .underWindowBackground)
        }
    }

    @ViewBuilder private var panel: some View {
        switch selectedPane {
        case .general: generalPanel
        case .profiles: if let profiles { ProfilesView(profiles: profiles, canSwitch: false, inSettings: true) }
        case .continuity: if let profiles { ContinuitySettingsView(continuity: profiles.continuity) }
        case .appearance: appearancePanel
        case .privacy: privacyPanel
        case .passwords: PasswordsGuide()
        case .about: aboutPanel
        }
    }

    private var generalPanel: some View {
        @Bindable var settings = controller.session.settings
        return SettingsForm {
            if let profiles {
                SettingsGroup("External links", scope: "All profiles on this Mac") {
                    SettingRow(detail: "External links open signed out, separate from every profile. Move a page to a profile when you choose.") {
                        Toggle(OrivStrings.openLinksPrivately, isOn: Binding(
                            get: { profiles.openExternalLinksPrivately },
                            set: { profiles.openExternalLinksPrivately = $0 }
                        ))
                    }
                }
            }
            SettingsGroup("Browsing", scope: syncedScope) {
                SettingRow(detail: "Searches are sent only when you submit them. Address suggestions use local tabs, saved pages and history.") {
                    BrowsingPreferencePicker(title: "Search engine", selection: $settings.searchEngine,
                                             options: SearchEngine.allCases, label: \.rawValue)
                }
                SettingRow(detail: "Pinned tabs always return. Private tabs are never restored. This takes effect on the next launch.") {
                    Toggle("Restore tabs when Oriv starts", isOn: $settings.restoreTabs)
                }
                SettingRow(detail: "Applies to newly opened tabs.") {
                    BrowsingPreferencePicker(title: "Default page zoom", selection: $settings.defaultZoom,
                                             options: [0.75, 0.9, 1, 1.1, 1.25, 1.5, 2], label: { "\(Int($0 * 100))%" })
                }
            }
            SettingsGroup("Default browser", scope: "This Mac") {
                SettingRow(detail: defaultBrowserStatus.isEmpty ? (isDefaultBrowser ? "\(AppIdentity.name) is your default browser." : "macOS will ask you to confirm this change.") : defaultBrowserStatus) {
                    LabeledContent("Open web links with Oriv") {
                        Button("Make Default…") {
                            changingDefault = true
                            Task {
                                defer { changingDefault = false }
                                do {
                                    for scheme in ["https", "http"] {
                                        try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: scheme)
                                    }
                                    defaultBrowserStatus = isDefaultBrowser ? "\(AppIdentity.name) is your default browser." : "The change wasn’t confirmed for both HTTP and HTTPS. Check macOS Settings."
                                } catch { defaultBrowserStatus = "The default browser wasn’t changed for every scheme. \(error.localizedDescription)" }
                            }
                        }
                        .accessibilityLabel("Make \(AppIdentity.name) the default browser")
                        .disabled(changingDefault || isDefaultBrowser)
                    }
                }
            }
        }
    }
    private var isDefaultBrowser: Bool {
        ["http", "https"].allSatisfy { scheme in
            NSWorkspace.shared.urlForApplication(toOpen: URL(string: "\(scheme)://example.com")!)?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
        }
    }

    private var appearancePanel: some View {
        SettingsForm {
            SettingsGroup("Appearance", scope: syncedScope, detail: OrivStrings.appearanceSummary,
                          marker: "settingsAppearanceHeader") {
                HStack(spacing: OrivSpacing.medium) {
                    ForEach(BrowserAppearance.allCases) { choice in
                        Button { appearance = choice } label: {
                            VStack(spacing: OrivSpacing.small) {
                                AppearancePreview(choice: choice)
                                    .overlay(alignment: .bottomTrailing) {
                                        if appearance == choice {
                                            Image(systemName: "checkmark")
                                                .font(OrivType.caption.weight(.semibold))
                                                .padding(OrivSpacing.xs)
                                                .foregroundStyle(theme.text)
                                                .background(theme.surfaceRaised, in: .circle)
                                                .accessibilityHidden(true)
                                        }
                                    }
                                Text(choice.displayName).font(OrivType.body.weight(appearance == choice ? .semibold : .regular))
                            }.padding(OrivSpacing.small).frame(maxWidth: .infinity)
                                .modifier(Tile(kind: .appearance(.clear), selected: appearance == choice))
                        }.orivButton(.quiet).accessibilityLabel("Use \(choice.displayName) appearance")
                            .accessibilityAddTraits(appearance == choice ? [.isSelected] : [])
                    }
                }
            }
            if let profileColor = controller.sidebarProfileColor(in: profiles) {
                SettingsGroup("Sidebar color", scope: profileScope,
                              detail: appearance == .t3Code ? "Sidebar color is available in System, Light and Dark." : nil) {
                    // oriv:raw-metric Five equal columns balance the nine swatches across two rows.
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: OrivSpacing.small), count: 5),
                              spacing: OrivSpacing.small) {
                        ForEach(SidebarColor.allCases, id: \.self) { choice in
                            sidebarSwatch(choice, profileColor: profileColor)
                        }
                    }
                    .disabled(appearance == .t3Code)
                }
            }
            SettingsGroup("Sidebar and gestures", scope: "All profiles on this Mac") {
                if let profiles {
                    LabeledContent("Swipe between profiles") {
                        Picker("Swipe between profiles", selection: Binding(
                            get: { profiles.profileSwipePreference }, set: { profiles.profileSwipePreference = $0 }
                        )) {
                            ForEach(ProfileSwipePreference.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.labelsHidden()
                    }
                }
                SettingRow(detail: reduceTransparency || contrast == .increased
                           ? "macOS uses a solid sidebar with your accessibility settings."
                           : "Controls the sidebar in browser windows.") {
                    LabeledContent("Glass opacity") {
                        Picker("Glass opacity", selection: $sidebarGlassOpacity) {
                            ForEach(SidebarGlassOpacity.allCases, id: \.self) { choice in
                                Text(choice.rawValue).tag(choice)
                            }
                        }.labelsHidden().pickerStyle(.segmented)
                    }
                }
            }
            SettingsGroup("Collapsed sidebar", scope: profileScope) {
                SettingRow(detail: "Off by default. Hover reveals titles over the page. Use ⌥⌘S to expand or collapse with the keyboard. Hover reveal is suspended while VoiceOver is running.") {
                    Toggle("Show sidebar when hovering over collapsed tabs", isOn: Binding(get: { controller.hoverSidebar }, set: { controller.hoverSidebar = $0 }))
                }
            }
        }
    }

    private func sidebarSwatch(_ choice: SidebarColor, profileColor: ProfileColor) -> some View {
        let selected = appearance != .t3Code && controller.sidebarColor == choice
        return Button {
            controller.sidebarColor = choice
        } label: {
            VStack(spacing: OrivSpacing.xs) {
                Rectangle().fill(.clear).frame(height: OrivTarget.macMinimum.height)
                    .modifier(Tile(kind: .swatch(choice.swatch(profile: profileColor, dark: sidebarSwatchScheme == .dark)), selected: selected))
                    .opacity(appearance == .t3Code ? 0.45 : 1)
                    .overlay {
                        if selected {
                            Image(systemName: "checkmark").font(OrivType.caption.weight(.semibold))
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
        SettingsForm {
            SettingsGroup("Privacy controls", scope: profileScope) {
                PrivacySettingsControls(session: controller.session)
            }
            SettingsGroup("Ad and tracker blocking", scope: syncedScope,
                          detail: "Applies to normal and private tabs. Reload open pages to apply changes fully. Private site exceptions are forgotten when the last private tab closes.") {
                SettingRow(detail: adBlocker.mode.detail) {
                    LabeledContent("Ad blocking") {
                        Picker("Ad blocking", selection: Binding(get: { adBlocker.mode }, set: { adBlocker.setMode($0) })) {
                            ForEach(AdBlockingMode.allCases) { Text($0.rawValue).tag($0) }
                        }.labelsHidden().pickerStyle(.segmented)
                    }
                }
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
            }
            SettingsGroup("Browsing data", scope: profileScope,
                          detail: "History deletions reach other devices when Sync is on.") {
                LabeledContent("Cookies and offline storage") {
                    Button("Manage Website Data…") {
                        dataSheet = DataSheet(id: .websiteData, session: controller.session)
                    }.orivButton(.secondary)
                }
                LabeledContent("History and caches") {
                    Button("Clear Browsing Data…") {
                        dataSheet = DataSheet(id: .clearBrowsingData, session: controller.session)
                    }.orivButton(.destructive)
                }
            }
            SettingsGroup("Site permissions", scope: syncedScope) {
                if controller.session.settings.rules.isEmpty {
                    Text("No site permissions saved.").foregroundStyle(theme.textSecondary)
                } else {
                    DisclosureGroup("Saved permissions (\(controller.session.settings.rules.count))") {
                        ForEach(controller.session.settings.rules.keys.sorted(), id: \.self) { origin in
                            LabeledContent {
                                Button("Reset") { controller.session.settings.removeRule(origin) }
                                    .accessibilityLabel("Reset site permissions for \(origin)")
                            } label: {
                                Text(origin).lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                }
            }
        }
    }

    private var aboutPanel: some View {
        SettingsForm {
            SettingsGroup(AppIdentity.name, detail: "Oriv uses the web engine supplied by macOS. Install macOS and Safari updates for WebKit fixes and media support.") {
                LabeledContent("Version", value: "\(runtime.appVersion) (\(runtime.appBuild))")
                LabeledContent("Build", value: AppIdentity.channel)
                LabeledContent("macOS", value: runtime.operatingSystem)
                LabeledContent("WebKit", value: runtime.webKitBuild)
                LabeledContent("Protection list version", value: AdBlocker.rulesVersion)
            }.textSelection(.enabled)
            SettingsGroup("Open source") {
                Button("Acknowledgments…") { acknowledgments = true }
            }
            if AppIdentity.isDevelopment {
                SettingsGroup("Development build") {
                    Text("This build keeps its browsing profiles and website data separate from the installed Oriv release.")
                        .foregroundStyle(theme.textSecondary)
                }
            }
        }
    }
}

struct SettingsForm<Content: View>: View {
    @Environment(\.browserTheme) private var theme
    @Environment(\.snapshotUnscrolled) private var unscrolled
    @ViewBuilder let content: () -> Content

    var body: some View {
        Group {
            if unscrolled {
                // Natural height, as inside the scroll view; overflow is clipped, not squeezed.
                form.fixedSize(horizontal: false, vertical: true)
                    .frame(maxHeight: .infinity, alignment: .top).clipped()
            } else {
                ScrollView { form }.scrollEdgeEffectStyle(.soft, for: .top)
            }
        }
        .font(OrivType.body)
        .foregroundStyle(theme.text)
        .tint(theme.accent)
        .labeledContentStyle(SettingsLabelStyle())
        .toggleStyle(SettingsToggleStyle())
        .pickerStyle(.menu)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: MacSettingsLayout.groupGap, content: content)
            .padding(.horizontal, MacSettingsLayout.formHorizontalInset)
            .padding(.vertical, MacSettingsLayout.formVerticalInset)
    }
}

private struct SettingsLabelStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: OrivSpacing.medium) {
            configuration.label
            Spacer(minLength: 0)
            configuration.content
        }
    }
}

private struct SettingsToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(isOn: configuration.$isOn) {
            configuration.label.frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
    }
}

struct SettingsGroup<Content: View>: View {
    @Environment(\.browserTheme) private var theme
    let title: String
    var scope: String?
    var detail: String?
    var marker: String?
    @ViewBuilder let content: () -> Content

    init(_ title: String, scope: String? = nil, detail: String? = nil, marker: String? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.scope = scope
        self.detail = detail
        self.marker = marker
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MacSettingsLayout.headingGap) {
            HStack(alignment: .firstTextBaseline) {
                if let marker { heading.browserGeometryMarker(marker) }
                else { heading }
                Spacer(minLength: OrivSpacing.small)
                if let scope {
                    Text(scope).font(OrivType.caption).foregroundStyle(theme.textSecondary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                }
            }
            VStack(alignment: .leading, spacing: MacSettingsLayout.rowGap, content: content)
            if let detail {
                Text(detail).font(OrivType.caption).foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsGroupSurface()
        .accessibilityElement(children: .contain)
    }

    private var heading: some View {
        Text(title).font(OrivType.headline).layoutPriority(1).accessibilityAddTraits(.isHeader)
    }
}

extension View {
    func settingsGroupSurface() -> some View { modifier(SettingsGroupSurface()) }
}

private struct SettingsGroupSurface: ViewModifier {
    @Environment(\.browserTheme) private var theme
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.chromeContrastOverride) private var captureContrast

    func body(content: Content) -> some View {
        let increased = (captureContrast ?? systemContrast) == .increased
        let shape = RoundedRectangle(cornerRadius: OrivRadius.panel)
        content.padding(.horizontal, MacSettingsLayout.groupHorizontalInset)
            .padding(.vertical, MacSettingsLayout.groupVerticalInset)
            .background(theme.surfaceRaised, in: shape)
            .overlay { shape.strokeBorder(theme.separator, lineWidth: increased ? 1.5 : 0.5) }
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
    let opaqueBackground: Bool
    let increasedContrast: Bool
    let opaqueColor: Color
    let select: (SettingsPane) -> Void

    func makeNSView(context: Context) -> ToolbarHost { ToolbarHost() }
    func updateNSView(_ view: ToolbarHost, context: Context) {
        view.panes = panes
        view.selection = selection
        view.select = select
        view.opaqueBackground = opaqueBackground
        view.increasedContrast = increasedContrast
        view.opaqueColor = opaqueColor
        view.installToolbar()
    }

    final class ToolbarHost: NSView, NSToolbarDelegate {
        var panes: [SettingsPane] = []
        var selection = SettingsPane.general
        var select: ((SettingsPane) -> Void)?
        var opaqueBackground = true
        var increasedContrast = false
        var opaqueColor = Color(nsColor: .windowBackgroundColor)
        private var sizedPane: SettingsPane?
        private var appliedBackground: Color?
        private var appliedBackgroundOnce = false
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
            appliedBackgroundOnce = false
            installToolbar()
        }

        func installToolbar() {
            guard let window, !panes.isEmpty else { return }
            let identifiers = panes.map(\.identifier)
            if window.toolbar !== settingsToolbar {
                window.toolbarStyle = .preference
                window.styleMask.insert(.fullSizeContentView)
                window.titlebarAppearsTransparent = true
                window.title = "\(AppIdentity.name) Settings"
                window.setAccessibilityIdentifier("orivSettingsWindow")
                window.toolbar = settingsToolbar
            }
            // Assign window state only when it changes: each assignment invalidates the hosting
            // view's environment, which re-runs this update and loops on heavy panes.
            if window.isOpaque != opaqueBackground { window.isOpaque = opaqueBackground }
            let background: Color? = opaqueBackground ? opaqueColor : nil
            if !appliedBackgroundOnce || appliedBackground != background {
                appliedBackgroundOnce = true
                appliedBackground = background
                window.backgroundColor = background.map { NSColor($0) } ?? .clear
            }
            let separator: NSTitlebarSeparatorStyle = increasedContrast ? .line : .none
            if window.titlebarSeparatorStyle != separator { window.titlebarSeparatorStyle = separator }
            resizeWindow(for: selection, in: window)
            if settingsToolbar.itemIdentifiers != identifiers { settingsToolbar.itemIdentifiers = identifiers }
            if settingsToolbar.selectedItemIdentifier != selection.identifier {
                settingsToolbar.selectedItemIdentifier = selection.identifier
            }
        }

        private func resizeWindow(for pane: SettingsPane, in window: NSWindow) {
            guard sizedPane != pane else { return }
            sizedPane = pane
            // Wait for the new pane's layout and preserve the native toolbar's position.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window, self.sizedPane == pane else { return }
                let available = (window.screen ?? NSScreen.main)?.visibleFrame
                let height = min(pane.windowHeight, available?.height ?? pane.windowHeight)
                var frame = window.frame
                frame.origin.y = frame.maxY - height
                frame.size.height = height
                if let available, !BackgroundUIMode.isEnabled {
                    frame.origin.y = max(available.minY, min(frame.minY, available.maxY - height))
                }
                window.setFrame(frame, display: true)
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
