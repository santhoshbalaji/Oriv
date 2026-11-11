import SwiftUI
import BrowserCore
import BrowserEngine
import WebKit

struct MobileSettingsView: View {
    @Environment(\.browserTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Bindable var controller: MobileController
    let profiles: MobileProfiles
    private var profileName: String { profiles.profiles.first { $0.id == controller.profileID }?.name ?? "None (Private)" }
    var body: some View {
        @Bindable var settings = controller.session.settings
        Form {
            Section {
                NavigationLink { MobileProfileChooser(controller: controller, profiles: profiles) } label: {
                    LabeledContent { Text(profileName).foregroundStyle(theme.secondaryText) } label: { rowLabel("Profile", "person.crop.circle", theme) }
                }
                NavigationLink { ContinuitySettingsView(continuity: profiles.continuity) } label: { rowLabel("Mac & iPhone", "laptopcomputer.and.iphone", theme) }
                NavigationLink { MobileAppearanceSettings(appearance: $controller.appearance, profileName: controller.profileID == nil ? nil : profileName) } label: {
                    LabeledContent { Text(controller.appearance.rawValue).foregroundStyle(theme.secondaryText) } label: { rowLabel("Appearance", "circle.lefthalf.filled", theme) }
                }.accessibilityIdentifier("appearanceSettings")
            }.listRowBackground(theme.row)
            Section {
                Picker("Search engine", selection: $settings.searchEngine) { ForEach(SearchEngine.allCases) { Text($0.rawValue).tag($0) } }.id(controller.appearance)
                Toggle("Open Links from Other Apps Privately", isOn: Binding(get: { profiles.openExternalLinksPrivately }, set: { profiles.openExternalLinksPrivately = $0 })).tint(theme.accent)
                Toggle("Restore tabs", isOn: $settings.restoreTabs).tint(theme.accent)
            } header: { Text("Browsing") } footer: {
                Text("Suggestions stay on this device; searches are sent only when you submit them. Private tabs are never restored.")
            }.listRowBackground(theme.row)
            Section {
                PrivacySettingsControls(session: controller.session)
                Picker("Ad blocking", selection: Binding(get: { controller.session.adBlocker.mode }, set: { controller.session.adBlocker.setMode($0) })) { ForEach(AdBlockingMode.allCases) { Text($0.rawValue).tag($0) } }.id(controller.appearance)
                if let error = controller.session.adBlocker.preparationError { Text(error).foregroundStyle(.red) }
                NavigationLink("Website Data") { MobileWebsiteData(manager: controller.session.websiteData) }
                NavigationLink("Clear Browsing Data") { MobileClearBrowsingData(session: controller.session) }
                if !controller.session.adBlocker.regularExceptions.isEmpty {
                    DisclosureGroup("Allowed sites (\(controller.session.adBlocker.regularExceptions.count))") {
                        ForEach(controller.session.adBlocker.regularExceptions.sorted(), id: \.self) { host in
                            HStack { Text(host); Spacer(); Button("Remove") { controller.session.adBlocker.removeRegularException(host) }.accessibilityLabel("Remove exception for \(host)") }
                        }
                    }
                }
                if !settings.rules.isEmpty {
                    DisclosureGroup("Site permissions (\(settings.rules.count))") {
                        ForEach(settings.rules.keys.sorted(), id: \.self) { origin in
                            HStack { Text(origin).rowTitleLines(); Spacer(); Button("Reset") { settings.removeRule(origin); controller.session.tabs.forEach { $0.stopCapture() } } }
                        }
                    }
                }
            } header: { Text("Privacy") } footer: {
                Text(controller.session.adBlocker.mode.detail + " Reload open pages to apply a change.")
            }.listRowBackground(theme.row)
            Section {
                Button("Open iOS Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
            } header: { Text("Passwords and permissions") } footer: {
                Text("Passwords and passkeys use iOS AutoFill. Camera, microphone and location always ask for your permission.")
            }.listRowBackground(theme.row)
            Section {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
            } footer: { Text("WebKit is supplied by iOS. Install system updates for engine and media fixes.") }.listRowBackground(theme.row)
        }.orivListStyle(theme).navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
}

struct MobileAppearanceSettings: View {
    @Environment(\.browserTheme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Binding var appearance: BrowserAppearance
    let profileName: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(profileName.map { "For the \($0) profile." } ?? "For this private session.").font(.callout).foregroundStyle(theme.secondaryText)
                LazyVGrid(columns: typeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 155), spacing: OrivSpacing.large)], spacing: OrivSpacing.large) {
                    ForEach(BrowserAppearance.allCases) { choice in
                        Button { appearance = choice } label: {
                            VStack(alignment: .leading, spacing: OrivSpacing.medium) {
                                if !typeSize.isAccessibilitySize { AppearancePreview(choice: choice) }
                                Text(choice.rawValue).font(.body).foregroundStyle(theme.text).fixedSize(horizontal: false, vertical: true)
                                Label(appearance == choice ? "Selected" : "Use theme", systemImage: appearance == choice ? "checkmark.circle.fill" : "circle")
                                    .font(.callout).foregroundStyle(theme.secondaryText)
                            }.padding(OrivSpacing.large).frame(maxWidth: .infinity, alignment: .leading)
                                .background(theme.surface, in: .rect(cornerRadius: OrivRadius.large))
                                .overlay { RoundedRectangle(cornerRadius: OrivRadius.large).strokeBorder(appearance == choice ? theme.accent : theme.separator, lineWidth: appearance == choice ? 2 : 1) }
                        }.buttonStyle(.plain).accessibilityLabel("Use \(choice.rawValue) appearance")
                            .accessibilityAddTraits(appearance == choice ? [.isSelected] : [])
                    }
                }
                Text("T3 Code uses black surfaces and blue accents. System follows your device appearance. Websites control their own colors.").font(.callout).foregroundStyle(theme.secondaryText)
            }.padding(20)
        }.background(theme.canvas).navigationTitle("Appearance").navigationBarTitleDisplayMode(.inline)
    }
}

struct MobileSiteSettings: View {
    @Environment(\.browserTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    let session: BrowserSession
    let tab: BrowserTab
    private var rule: SiteRule { session.settings.rule(for: tab.url, isPrivate: tab.isPrivate) }
    var body: some View {
        Form {
            Section {
                if tab.isPrivate { Label("Private browsing", systemImage: "eyeglasses").foregroundStyle(theme.privateAccent) }
                let connection = ConnectionCue(tab, includeRecording: false)
                Label(connection.label, systemImage: connection.symbol).foregroundStyle(connection.color(theme))
                Text(tab.url.flatMap(SiteOrigin.init)?.displayName ?? "No website open").textSelection(.enabled)
                Text(tab.isSecure ? "HTTPS encrypts this connection. It does not verify the site's identity or claims." : "A fully secure connection has not been confirmed. Check the address before sharing sensitive information.").font(.callout).foregroundStyle(theme.secondaryText)
            }.listRowBackground(theme.surface)
            if let url = tab.url {
                Section("Protection") {
                    PrivacyShieldControls(session: session, tab: tab)
                    if session.adBlocker.mode == .off { Text("Ad blocking is off in Settings.").foregroundStyle(theme.secondaryText) }
                    permission("Camera", path: \.camera, url: url)
                    permission("Microphone", path: \.microphone, url: url)
                    Toggle("Allow automatic pop-ups", isOn: Binding(get: { rule.allowsAutomaticPopups }, set: { var updated = rule; updated.allowsAutomaticPopups = $0; session.settings.setRule(updated, for: url, isPrivate: tab.isPrivate) })).tint(theme.accent)
                    Text("Ask uses WebKit and iOS permission prompts. Reload to apply changes to pop-ups and blocking.").font(.caption).foregroundStyle(theme.secondaryText)
                    if tab.isCapturingCamera || tab.isCapturingMicrophone {
                        Label("Camera or microphone in use", systemImage: "record.circle.fill").foregroundStyle(.red)
                        Button("Stop Camera and Microphone") { tab.stopCapture() }
                    }
                    Button("Reset Site Permissions") { session.settings.setRule(SiteRule(), for: url, isPrivate: tab.isPrivate); tab.stopCapture() }
                    Button("Reload Page") { tab.reload(); dismiss() }
                    if tab.isPrivate { Text("Private permissions and blocking exceptions are forgotten when the last private tab closes.").font(.caption).foregroundStyle(theme.secondaryText) }
                }.listRowBackground(theme.surface)
            }
        }.scrollContentBackground(.hidden).background(theme.canvas).navigationTitle("Site settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
    private func permission(_ title: String, path: WritableKeyPath<SiteRule, SitePermission>, url: URL) -> some View {
        Picker(title, selection: Binding(get: { rule[keyPath: path] }, set: { var updated = rule; updated[keyPath: path] = $0; session.settings.setRule(updated, for: url, isPrivate: tab.isPrivate); if $0 == .block { tab.stopCapture() } })) {
            ForEach(SitePermission.allCases) { Text($0.rawValue).tag($0) }
        }
    }
}

struct MobileClearBrowsingData: View {
    @Environment(\.browserTheme) private var theme
    let session: BrowserSession
    @State private var hours = 1
    @State private var history = true
    @State private var cache = false
    @State private var sites = false
    @State private var permissions = false
    @State private var confirm = false
    @State private var working = false
    @State private var completed = false
    var body: some View {
        Form {
            Section {
                Picker("Time range", selection: $hours) {
                    Text("Last hour").tag(1); Text("Last 24 hours").tag(24); Text("Last 7 days").tag(168); Text("All time").tag(0)
                }
                Toggle("Browsing history", isOn: $history).tint(theme.accent)
                Toggle("Cached website files", isOn: $cache).tint(theme.accent)
                Toggle("Cookies and website data", isOn: $sites).tint(theme.accent)
                Toggle("All saved site permissions", isOn: $permissions).tint(theme.accent)
            }.listRowBackground(theme.surface)
            Section {
                Text("Website data includes logins and offline work. WebKit applies the time range to stored records, which may contain older content. Bookmarks, open tabs and files you saved are retained.").font(.callout).foregroundStyle(theme.secondaryText)
                Button("Clear Selected Data…", role: .destructive) { confirm = true }.disabled(!history && !cache && !sites && !permissions)
                if working { ProgressView("Clearing data…") }
                if completed { Label("Selected browsing data cleared", systemImage: "checkmark.circle").accessibilityAddTraits(.updatesFrequently) }
            }.listRowBackground(theme.surface)
        }.scrollContentBackground(.hidden).background(theme.canvas).navigationTitle("Clear browsing data").disabled(working)
            .confirmationDialog("Clear selected browsing data?", isPresented: $confirm, titleVisibility: .visible) {
                Button("Clear Data", role: .destructive) {
                    working = true; completed = false
                    let since = hours == 0 ? Date.distantPast : Date.now.addingTimeInterval(-Double(hours) * 3600)
                    Task {
                        if history { session.clearHistory(since: since) }
                        if permissions { session.settings.clearRules(); session.tabs.forEach { $0.stopCapture() } }
                        if cache || sites { await session.websiteData.clear(since: since, cacheOnly: !sites) }
                        working = false; completed = true
                    }
                }
            } message: { Text("This cannot be undone. Close website tabs first to prevent them from recreating data. Clearing cookies may sign you out.") }
    }
}

struct MobileWebsiteData: View {
    @Environment(\.browserTheme) private var theme
    let manager: WebsiteDataManager
    @State private var query = ""
    @State private var pending: [WKWebsiteDataRecord] = []
    @State private var confirm = false
    var body: some View {
        List {
            Text("Cookies, caches and offline storage. Removing data can sign you out. Bookmarks are kept separately.").font(.callout).foregroundStyle(theme.secondaryText)
            let records = manager.records.filter { query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(query) }
            if manager.isWorking { ProgressView() }
            else if manager.records.isEmpty { BrowserEmptyState("No website data").listRowBackground(theme.row).listRowSeparator(.hidden) }
            else if records.isEmpty { BrowserEmptyState("No results for “\(query)”.").listRowBackground(theme.row).listRowSeparator(.hidden) }
            ForEach(records, id: \.displayName) { record in
                VStack(alignment: .leading) { Text(record.displayName); Button("Remove…", role: .destructive) { pending = [record]; confirm = true } }
            }
            if !manager.records.isEmpty { Button("Remove All…", role: .destructive) { pending = manager.records; confirm = true } }
        }.scrollContentBackground(.hidden).background(theme.canvas).navigationTitle("Website data").searchable(text: $query)
            .disabled(manager.isWorking).task { await manager.refresh() }
            .confirmationDialog("Remove website data?", isPresented: $confirm, titleVisibility: .visible) {
                Button("Remove Data", role: .destructive) { let records = pending; pending = []; Task { await manager.remove(records) } }
            } message: { Text("Remove stored data for \(pending.count) websites? This cannot be undone. Close their tabs first to prevent them from recreating data.") }
    }
}

private struct MobileProfileChooser: View {
    @Environment(\.browserTheme) private var theme
    let controller: MobileController
    let profiles: MobileProfiles
    @State private var error: String?
    @State private var editing = false
    @State private var editingID: UUID?
    @State private var name = ""
    @State private var archiving: BrowserProfile?
    var body: some View {
        List {
            Section("On this device") {
                Button("New Profile…") { editingID = nil; name = ""; editing = true }
                ForEach(profiles.profiles.filter { $0.archivedAt == nil }) { profile in
                    Button { profiles.select(profile) } label: {
                        HStack { Text(profile.name).foregroundStyle(theme.text); Spacer(); if profile.id == controller.profileID { Image(systemName: "checkmark") } }
                    }.accessibilityAddTraits(profile.id == controller.profileID ? [.isSelected] : [])
                        .contextMenu {
                            if !profile.isPersonal { Button("Rename") { editingID = profile.id; name = profile.name; editing = true } }
                            if !profile.isPersonal && profile.id != controller.profileID { Button("Archive…") { archiving = profile } }
                        }
                }
            }
            if profiles.profiles.contains(where: { $0.archivedAt != nil }) {
                Section("Archived") { ForEach(profiles.profiles.filter { $0.archivedAt != nil }) { profile in Button("Restore \(profile.name)") { profiles.restore(profile.id) } } }
            }
            Section {
                Text("Each profile keeps tabs, history, bookmarks, settings and website logins separate on this device. Profiles are not locked accounts. Touch and hold a profile to rename or archive it.").font(.callout).foregroundStyle(theme.secondaryText)
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.scrollContentBackground(.hidden).background(theme.canvas).navigationTitle("Profiles")
            .alert(editingID == nil ? "New profile" : "Rename profile", isPresented: $editing) {
                TextField("Name", text: $name)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    do { try profiles.saveName(name, for: editingID); error = nil }
                    catch { self.error = error.localizedDescription }
                }
            } message: { Text("Names must be unique and contain 1–40 characters.") }
            .confirmationDialog("Archive profile?", isPresented: Binding(get: { archiving != nil }, set: { if !$0 { archiving = nil } }), titleVisibility: .visible) {
                Button("Archive") { if let profile = archiving { profiles.archive(profile.id) }; archiving = nil }
            } message: { Text("Private tabs close and any unsaved edits in them are lost. Regular tabs and saved data remain available when you restore this profile.") }
    }
}
