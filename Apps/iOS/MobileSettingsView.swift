import SwiftUI
import BrowserCore
import BrowserEngine
import WebKit

struct MobileSettingsView: View {
    @Environment(\.browserTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Bindable var controller: MobileController
    @Environment(\.dynamicTypeSize) private var typeSize
    let profiles: MobileProfiles
    private var profileName: String { profiles.profiles.first { $0.id == controller.profileID }?.name ?? "None (Private)" }
    var body: some View {
        @Bindable var settings = controller.session.settings
        Form {
            Section {
                NavigationLink { MobileProfileChooser(controller: controller, profiles: profiles) } label: {
                    settingsDestination("Profile", symbol: "person.crop.circle", detail: profileName)
                }
                NavigationLink { ContinuitySettingsView(continuity: profiles.continuity) } label: { rowLabel(OrivStrings.sync, "laptopcomputer.and.iphone", theme) }
                NavigationLink { MobileAppearanceSettings(appearance: $controller.appearance, profileName: controller.profileID == nil ? nil : profileName) } label: {
                    settingsDestination("Appearance", symbol: "circle.lefthalf.filled", detail: controller.appearance.displayName)
                }.accessibilityIdentifier("appearanceSettings")
            }.listRowBackground(theme.surfaceRaised)
            Section {
                Picker("Search engine", selection: $settings.searchEngine) { ForEach(SearchEngine.allCases) { Text($0.rawValue).tag($0) } }.id(controller.appearance)
                Toggle(OrivStrings.openLinksPrivately, isOn: Binding(get: { profiles.openExternalLinksPrivately }, set: { profiles.openExternalLinksPrivately = $0 })).tint(theme.accent)
                Toggle("Restore tabs", isOn: $settings.restoreTabs).tint(theme.accent)
            } header: { Text("Browsing") } footer: {
                Text("Suggestions stay on this device; searches are sent only when you submit them. Private tabs are never restored.")
            }.listRowBackground(theme.surfaceRaised)
            Section {
                PrivacySettingsControls(session: controller.session)
                SettingRow(detail: controller.session.adBlocker.mode == .strict ? AdBlockingMode.strict.detail : nil) {
                    Picker("Ad blocking", selection: Binding(get: { controller.session.adBlocker.mode }, set: { controller.session.adBlocker.setMode($0) })) {
                        ForEach(AdBlockingMode.allCases) { Text($0.rawValue).tag($0) }
                    }.id(controller.appearance)
                }
                if let error = controller.session.adBlocker.preparationError { Text(error).foregroundStyle(theme.danger) }
                if controller.session.adBlocker.mode == .strict {
                    if controller.session.adBlocker.isPreparingCNAME { ProgressView(OrivStrings.preparingTrackerProtection) }
                    if let error = controller.session.adBlocker.cnamePreparationError { Text(error).foregroundStyle(theme.danger) }
                }
                NavigationLink(OrivStrings.websiteData) { MobileWebsiteData(manager: controller.session.websiteData) }
                NavigationLink("Clear browsing data") { MobileClearBrowsingData(session: controller.session) }
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
            }.listRowBackground(theme.surfaceRaised)
            Section {
                Button("Open iOS Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
            } header: { Text("Passwords and permissions") } footer: {
                Text("Passwords come from iOS AutoFill. Tap the key above the keyboard, then choose the account. iOS fills the field. Oriv never reads, stores or sends your saved passwords. Camera, microphone and location always ask for your permission.")
            }.listRowBackground(theme.surfaceRaised)
            Section {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                LabeledContent("Protection list version", value: AdBlocker.rulesVersion)
            } header: { Text("About") } footer: { Text("WebKit is supplied by iOS. Install system updates for engine and media fixes.") }.listRowBackground(theme.surfaceRaised)
        }.orivListStyle(theme).navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }

    @ViewBuilder private func settingsDestination(_ title: String, symbol: String, detail: String) -> some View {
        if typeSize.isAccessibilitySize {
            SettingRow(detail: detail) { rowLabel(title, symbol, theme) }
        } else {
            LabeledContent {
                Text(detail).foregroundStyle(theme.textSecondary)
            } label: {
                rowLabel(title, symbol, theme)
            }
        }
    }
}

struct MobileAppearanceSettings: View {
    @Environment(\.browserTheme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Binding var appearance: BrowserAppearance
    let profileName: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: OrivSpacing.larger) {
                Text(profileName.map { "For the \($0) profile." } ?? "For this private session.").font(OrivType.body).foregroundStyle(theme.textSecondary)
                LazyVGrid(columns: typeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 155), spacing: OrivSpacing.large)], spacing: OrivSpacing.large) {
                    ForEach(BrowserAppearance.allCases) { choice in
                        Button { appearance = choice } label: {
                            VStack(alignment: .leading, spacing: OrivSpacing.medium) {
                                if !typeSize.isAccessibilitySize { AppearancePreview(choice: choice) }
                                HStack(alignment: .firstTextBaseline, spacing: OrivSpacing.small) {
                                    Text(choice.displayName).font(OrivType.body).foregroundStyle(theme.text)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                    if appearance == choice {
                                        Image(systemName: "checkmark").font(OrivType.detail.weight(.semibold))
                                            .foregroundStyle(theme.accent).accessibilityHidden(true)
                                    }
                                }
                            }.padding(OrivSpacing.large).frame(maxWidth: .infinity, alignment: .leading)
                                .modifier(Tile(kind: .appearance(theme.surface), selected: appearance == choice))
                        }.buttonStyle(.plain).accessibilityLabel("Use \(choice.displayName) appearance")
                            .accessibilityAddTraits(appearance == choice ? [.isSelected] : [])
                    }
                }
                Text(OrivStrings.appearanceSummary).font(OrivType.body).foregroundStyle(theme.textSecondary)
            }.padding(OrivSpacing.larger)
        }.background(theme.canvas).navigationTitle("Appearance").navigationBarTitleDisplayMode(.inline)
    }
}

struct MobileSiteSettings: View {
    @Environment(\.browserTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    let session: BrowserSession
    let tab: BrowserTab
    @State private var resetSite = false
    @State private var siteToForget: BrowserSite?
    @State private var forgetError: String?
    private var rule: SiteRule { session.settings.rule(for: tab.url, isPrivate: tab.isPrivate) }

    var body: some View {
        Form {
            Section {
                if tab.isPrivate { Label("Private browsing", systemImage: "eyeglasses").foregroundStyle(theme.private) }
                let connection = ConnectionCue(tab, includeRecording: false)
                SettingRow(detail: tab.isSecure
                    ? "HTTPS encrypts this connection."
                    : "Check the address before sharing sensitive information.") {
                    Label(connection.label, systemImage: connection.symbol).foregroundStyle(connection.color(theme))
                }
                Text(tab.url.flatMap(SiteOrigin.init)?.displayName ?? "No website open").textSelection(.enabled)
            }.listRowBackground(theme.surfaceRaised)
            if let url = tab.url {
                Section("Protection") {
                    PrivacyShieldControls(session: session, tab: tab)
                }.listRowBackground(theme.surfaceRaised)
                Section {
                    permission("Camera", path: \.camera, url: url)
                    permission("Microphone", path: \.microphone, url: url)
                    Toggle("Allow automatic pop-ups", isOn: Binding(get: { rule.allowsAutomaticPopups }, set: {
                        var updated = rule
                        updated.allowsAutomaticPopups = $0
                        session.settings.setRule(updated, for: url, isPrivate: tab.isPrivate)
                    })).tint(theme.accent)
                    if tab.isCapturingCamera || tab.isCapturingMicrophone {
                        SettingRow(detail: "Camera or microphone in use") {
                            Button("Stop Camera and Microphone") { tab.stopCapture() }
                                .foregroundStyle(theme.danger)
                        }
                    }
                } header: {
                    Text("Permissions")
                } footer: {
                    Text(tab.isPrivate
                         ? "Private permissions and blocking exceptions expire when the last private tab closes."
                         : "Ask uses WebKit and iOS permission prompts.")
                }.listRowBackground(theme.surfaceRaised)
                Section {
                    Button("Reload Page") { tab.reload(); dismiss() }
                    Button("Reset This Site…", role: .destructive) { resetSite = true }.orivButton(.destructive)
                    if let site = session.forgettableSite(for: tab) {
                        Button("Forget This Site…", role: .destructive) { siteToForget = site }.orivButton(.destructive)
                    }
                } footer: {
                    Text("Reload to apply changes to pop-ups and protections. Unsaved form contents may be lost.")
                }.listRowBackground(theme.surfaceRaised)
            }
            if let forgetError { Text(forgetError).foregroundStyle(theme.danger) }
        }.orivListStyle(theme).navigationTitle("Site settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("siteSettingsDone") } }
            .alert("Reset this site?", isPresented: $resetSite, presenting: tab.url) { url in
                Button("Cancel", role: .cancel) {}
                Button("Reset Site", role: .destructive) { reset(url) }
            } message: { _ in
                Text("Restore default protections and permissions for this site. Browsing data is kept. Reload to apply the changes.")
            }
            .forgetSiteAlert($siteToForget, session: session) { forgetError = $0 }
    }

    private func reset(_ url: URL) {
        session.settings.setRule(SiteRule(), for: url, isPrivate: tab.isPrivate)
        session.adBlocker.setException(false, for: url, isPrivate: tab.isPrivate)
        for layer in PrivacyLayer.allCases {
            session.settings.privacy.setException(false, layer, for: url, isPrivate: tab.isPrivate)
        }
        tab.stopCapture()
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
            }.listRowBackground(theme.surfaceRaised)
            Section {
                Text("Website data includes logins and offline work. WebKit applies the time range to stored records, which may contain older content. Bookmarks, open tabs and files you saved are retained.").font(OrivType.body).foregroundStyle(theme.textSecondary)
                Button(OrivStrings.clearSelectedData, role: .destructive) { confirm = true }.orivButton(.destructive).disabled(!history && !cache && !sites && !permissions)
                if working { ProgressView("Clearing data…") }
                if completed { Label("Selected browsing data cleared", systemImage: "checkmark.circle").foregroundStyle(theme.success).accessibilityAddTraits(.updatesFrequently) }
            }.listRowBackground(theme.surfaceRaised)
        }.orivListStyle(theme).navigationTitle("Clear browsing data").disabled(working)
            .confirmationDialog("Clear selected browsing data?", isPresented: $confirm, titleVisibility: .visible) {
                Button("Clear Data", role: .destructive) {
                    working = true; completed = false
                    let since = hours == 0 ? Date.distantPast : Date.now.addingTimeInterval(-Double(hours) * 3600)
                    Task {
                        if history { session.clearHistory(since: since) }
                        if permissions { session.settings.clearRules(); session.tabs.forEach { $0.stopCapture() } }
                        if cache || sites { await session.websiteData.clear(since: since, cacheOnly: !sites) }
                        if cache || sites { await session.siteIcons.clear() }
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
            Text("Cookies, caches and offline storage. Removing data can sign you out. Bookmarks are kept separately.").font(OrivType.body).foregroundStyle(theme.textSecondary)
            let records = manager.records.filter { query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(query) }
            if manager.isWorking { ProgressView() }
            else if manager.records.isEmpty { BrowserEmptyState("No website data").listRowBackground(theme.surfaceRaised).listRowSeparator(.hidden) }
            else if records.isEmpty { BrowserEmptyState("No results for “\(query)”.").listRowBackground(theme.surfaceRaised).listRowSeparator(.hidden) }
            ForEach(records, id: \.displayName) { record in
                VStack(alignment: .leading) { Text(record.displayName); Button("Remove…", role: .destructive) { pending = [record]; confirm = true }.orivButton(.destructive) }
            }
            if !manager.records.isEmpty { Button(OrivStrings.removeAll, role: .destructive) { pending = manager.records; confirm = true }.orivButton(.destructive) }
        }.orivListStyle(theme).navigationTitle(OrivStrings.websiteData).searchable(text: $query)
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
    @State private var deleting: BrowserProfile?
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
                            if !profile.isPersonal && profile.id != profiles.lastRegularProfileID {
                                Button("Archive…") { archiving = profile }
                                Button(OrivStrings.deleteProfilePrompt, role: .destructive) { deleting = profile }.orivButton(.destructive)
                            }
                        }
                }
            }
            if profiles.profiles.contains(where: { $0.archivedAt != nil }) {
                Section("Archived") {
                    ForEach(profiles.profiles.filter { $0.archivedAt != nil }) { profile in
                        Button("Restore \(profile.name)") { profiles.restore(profile.id) }
                            .contextMenu { Button(OrivStrings.deleteProfilePrompt, role: .destructive) { deleting = profile } }
                    }
                }
            }
            Section {
                Text("Each profile keeps tabs, history, bookmarks, settings and website logins separate on this device. Profiles are not locked accounts. Touch and hold a profile to manage it.").font(OrivType.body).foregroundStyle(theme.textSecondary)
            }
            if let error { Text(error).foregroundStyle(theme.danger) }
        }.orivListStyle(theme).navigationTitle("Profiles")
            .alert(editingID == nil ? "New profile" : "Rename profile", isPresented: $editing) {
                TextField("Name", text: $name)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    do { try profiles.saveName(name, for: editingID); error = nil }
                    catch { self.error = error.localizedDescription }
                }
            } message: { Text("Names must be unique and contain 1–40 characters.") }
            .sheet(item: $deleting) { profile in
                DeleteProfileConfirmation(profile: profile) {
                    Task { @MainActor in
                        do { try await profiles.delete(profile); error = nil }
                        catch { self.error = error.localizedDescription }
                    }
                }
            }
            .confirmationDialog("Archive profile?", isPresented: Binding(get: { archiving != nil }, set: { if !$0 { archiving = nil } }), titleVisibility: .visible) {
                Button("Archive") {
                    guard let profile = archiving else { return }
                    archiving = nil
                    do { try profiles.archive(profile.id); error = nil }
                    catch { self.error = error.localizedDescription }
                }
            } message: { Text("Private tabs close and any unsaved edits in them are lost. Regular tabs and saved data remain available when you restore this profile.") }
    }
}
