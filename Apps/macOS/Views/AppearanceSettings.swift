import SwiftUI
import BrowserCore
import BrowserEngine

enum SettingsPane: String, CaseIterable, Hashable {
    case general, profiles, continuity, appearance, privacy, passwords, about
}

struct AppearanceSettings: View {
    @Environment(\.browserTheme) private var theme
    @Binding var appearance: BrowserAppearance
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
    var body: some View {
        TabView(selection: Binding(get: { pane ?? initialPane }, set: { pane = $0 })) {
            generalPanel.tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsPane.general)
            if let profiles { ProfilesView(profiles: profiles, canSwitch: false).padding(8).tabItem { Label("Profiles", systemImage: "person.crop.rectangle.stack") }.tag(SettingsPane.profiles) }
            if let profiles { ContinuitySettingsView(continuity: profiles.continuity).tabItem { Label("Continuity", systemImage: "laptopcomputer.and.iphone") }.tag(SettingsPane.continuity) }
            appearancePanel.tabItem { Label("Appearance", systemImage: "paintpalette") }.tag(SettingsPane.appearance)
            privacyPanel.tabItem { Label("Privacy", systemImage: "shield.lefthalf.filled") }.tag(SettingsPane.privacy)
            ScrollView { PasswordsGuide() }.tabItem { Label("Passwords", systemImage: "key") }.tag(SettingsPane.passwords)
            aboutPanel.tabItem { Label("About", systemImage: "info.circle") }.tag(SettingsPane.about)
        }
        .padding(16).frame(width: 640, height: 580)
        .background(theme.canvas).navigationTitle("\(AppIdentity.name) Settings")
        .sheet(isPresented: $websiteData) { WebsiteDataView(manager: controller.session.websiteData) }
        .sheet(isPresented: $clearBrowsingData) { ClearBrowsingDataView(session: controller.session) }
    }

    private var generalPanel: some View {
        @Bindable var settings = controller.session.settings
        return Form {
            Section("Browsing") {
                if let profiles {
                    Toggle("Open Links from Other Apps Privately", isOn: Binding(get: { profiles.openExternalLinksPrivately }, set: { profiles.openExternalLinksPrivately = $0 })).tint(theme.accent)
                    Text("External links open signed out, separate from every profile. Move a page to a profile when you choose.").font(OrivType.caption).foregroundStyle(theme.secondaryText)
                }
                Picker("Search engine", selection: $settings.searchEngine) {
                    ForEach(SearchEngine.allCases) { Text($0.rawValue).tag($0) }
                }
                Text("Searches are sent only when you submit them. Address suggestions use local tabs, saved pages and history.").font(.caption).foregroundStyle(theme.secondaryText)
                Toggle("Restore tabs when Oriv starts", isOn: $settings.restoreTabs).tint(theme.accent)
                Text("Pinned tabs always return. Private tabs are never restored. This takes effect on the next launch.").font(.caption).foregroundStyle(theme.secondaryText)
                Picker("Default page zoom", selection: $settings.defaultZoom) {
                    ForEach([0.75, 0.9, 1, 1.1, 1.25, 1.5, 2], id: \.self) { value in Text("\(Int(value * 100))%").tag(value) }
                }
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
        }.formStyle(.grouped).scrollContentBackground(.hidden)
    }
    private var isDefaultBrowser: Bool {
        ["http", "https"].allSatisfy { scheme in
            NSWorkspace.shared.urlForApplication(toOpen: URL(string: "\(scheme)://example.com")!)?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
        }
    }

    private var appearancePanel: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Appearance for the \(controller.profile?.name ?? "Private") profile").font(.system(size: 13)).foregroundStyle(theme.secondaryText)
            HStack(spacing: 12) {
                ForEach(BrowserAppearance.allCases) { choice in
                    Button { appearance = choice } label: {
                        VStack(spacing: 10) {
                            AppearancePreview(choice: choice)
                            Text(choice.rawValue).font(.callout.weight(appearance == choice ? .semibold : .regular))
                            Image(systemName: appearance == choice ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(appearance == choice ? theme.accent : theme.secondaryText)
                        }.padding(10).frame(maxWidth: .infinity)
                    }.buttonStyle(ContentButtonStyle()).accessibilityLabel("Use \(choice.rawValue) appearance")
                        .accessibilityAddTraits(appearance == choice ? [.isSelected] : [])
                }
            }
            Text("T3 Code uses black surfaces and blue accents. System follows your Mac. Websites keep their own colors.")
                .font(.callout).foregroundStyle(theme.secondaryText).lineSpacing(3)
            Spacer()
        }.padding(24)
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
                Picker("Ad blocking", selection: Binding(get: { adBlocker.mode }, set: { adBlocker.setMode($0) })) {
                    ForEach(AdBlockingMode.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).tint(theme.accent)
                Text(adBlocker.mode.detail).font(.callout).foregroundStyle(theme.secondaryText)
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
        }.formStyle(.grouped).scrollContentBackground(.hidden)
    }
    private var aboutPanel: some View {
        VStack(alignment: .leading, spacing: 24) {
            OrivIdentity()
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                GridRow { Text(AppIdentity.name).foregroundStyle(theme.secondaryText); Text("\(runtime.appVersion) (\(runtime.appBuild))") }
                GridRow { Text("Build").foregroundStyle(theme.secondaryText); Text(AppIdentity.channel) }
                GridRow { Text("macOS").foregroundStyle(theme.secondaryText); Text(runtime.operatingSystem) }
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
