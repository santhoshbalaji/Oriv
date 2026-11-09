import SwiftUI
import BrowserCore
import BrowserEngine

struct ContinuitySettingsView: View {
    @Environment(\.browserTheme) private var theme
    let continuity: BrowserContinuity
    @State private var deviceName = ""
    var body: some View {
        Form {
            Section {
                Toggle("Sync with iCloud", isOn: Binding(get: { continuity.state.enabled }, set: continuity.setEnabled)).tint(theme.accent)
                    .disabled(!continuity.isConfigured || !continuity.canSave)
                    .accessibilityIdentifier("continuityEnabled")
                Text("Keep bookmarks, history, profiles, regular tabs and browser preferences available on your Mac and iPhone.")
                    .font(.callout).foregroundStyle(theme.secondaryText)
            } header: { Text("Browser sync") } footer: {
                Text("Uses your private iCloud database. Turning sync off pauses this device and retains existing copies. History deletions sync when your devices reconnect.")
            }.listRowBackground(theme.surface)
            Section("Status") {
                Text(continuity.status).accessibilityIdentifier("continuityStatus")
                if let date = continuity.state.lastSync { LabeledContent("Last successful sync", value: date.formatted(date: .abbreviated, time: .shortened)) }
                Button { Task { await continuity.syncNow() } } label: {
                    HStack { Text("Sync Now"); if continuity.isSyncing { ProgressView().controlSize(.small) } }
                }.disabled(!continuity.state.enabled || continuity.isSyncing || !continuity.isConfigured)
                Text("Sync runs while Oriv is active and resumes when you return. Tabs on other devices reflect their last sync.").font(.caption).foregroundStyle(theme.secondaryText)
            }.listRowBackground(theme.surface)
            Section("This device") {
                LabeledContent("Device name") {
                    // One visible label: the field's own title is hidden (macOS forms would repeat it).
                    TextField("Device name", text: $deviceName, prompt: Text("Name")).labelsHidden().multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("continuityDeviceName")
                        .accessibilityLabel("Device name").onSubmit { continuity.setDeviceName(deviceName) }
                }
                Button("Save Device Name") { continuity.setDeviceName(deviceName) }.disabled(deviceName == continuity.state.deviceName || deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || deviceName.count > 80)
                Toggle("Handoff", isOn: Binding(get: { continuity.isConfigured && continuity.state.handoffEnabled }, set: continuity.setHandoff)).tint(theme.accent)
                    .disabled(!continuity.isConfigured || !continuity.canSave)
                Text("Continue your current regular page on a nearby device signed in to the same Apple Account. Opens a new tab in the matching profile.").font(.caption).foregroundStyle(theme.secondaryText)
            }.listRowBackground(theme.surface)
            Section("Stays on this device") {
                Text("Website logins and cookies, private tabs, form drafts, downloads, device permissions and profile selection. Archiving a profile is local to this device.")
                Text("Passwords and passkeys are managed by Apple Passwords and iCloud Keychain, separately from Oriv sync.").font(.caption).foregroundStyle(theme.secondaryText)
            }.listRowBackground(theme.surface)
        }.formStyle(.grouped).scrollContentBackground(.hidden).background(theme.canvas)
            .navigationTitle("Mac & iPhone")
            .onAppear { deviceName = continuity.state.deviceName }
    }
}

struct OtherDeviceTabsView: View {
    @Environment(\.browserTheme) private var theme
    let continuity: BrowserContinuity
    var search = ""
    let open: (ContinuityPage) -> Void
    private var devices: [ContinuityDevice] { continuity.state.devices.filter { $0.id != continuity.state.deviceID } }
    private func tabs(_ profile: ContinuityProfile, _ device: ContinuityDevice) -> [TabRecord] {
        continuity.state.tabs(for: profile.id, device: device.id).filter { tab in
            search.isEmpty || tab.title.localizedCaseInsensitiveContains(search) || (tab.url?.absoluteString.localizedCaseInsensitiveContains(search) ?? false)
        }
    }
    var body: some View {
        Group {
            if !continuity.isConfigured {
                ContentUnavailableView("Not available in this build", systemImage: "laptopcomputer.and.iphone",
                    description: Text("Mac & iPhone sync needs a signed build of Oriv."))
            } else if !continuity.state.enabled {
                ContentUnavailableView {
                    Label("Continue on another device", systemImage: "laptopcomputer.and.iphone")
                } description: {
                    Text("Sync tabs, bookmarks and history between your Mac and iPhone.")
                } actions: { setupAction }
            } else if devices.isEmpty {
                ContentUnavailableView("No other devices yet", systemImage: "laptopcomputer.and.iphone",
                    description: Text("Turn on sync in Oriv on your other device, using the same Apple Account."))
            } else if !search.isEmpty && devices.allSatisfy({ device in continuity.state.profiles.allSatisfy { tabs($0, device).isEmpty } }) {
                ContentUnavailableView.search(text: search)
            } else {
                List {
                    ForEach(devices) { device in
                        Section {
                            ForEach(continuity.state.profiles) { profile in
                                let matches = tabs(profile, device)
                                if !matches.isEmpty {
                                    if continuity.state.profiles.count > 1 {
                                        Text(profile.name).font(.caption.weight(.medium)).foregroundStyle(theme.secondaryText).listRowBackground(theme.row)
                                    }
                                    let context = URLDisplay.Context(matches.compactMap { tab in tab.url.map { (tab.title, $0) } })
                                    ForEach(matches) { tab in
                                        Button {
                                            if let page = ContinuityPage(url: tab.url, title: tab.title, profile: profile.browserProfile, isPrivate: false) { open(page) }
                                        } label: {
                                            HStack(spacing: 12) {
                                                SiteIdentity(url: tab.url, size: 24)
                                                Text(tab.title.isEmpty ? (tab.url?.host() ?? "Page") : tab.title).foregroundStyle(theme.text).rowTitleLines()
                                                if let host = secondaryLine(title: tab.title, url: tab.url, in: context) {
                                                    Text(host).font(.caption).foregroundStyle(theme.secondaryText).lineLimit(1)
                                                }
                                                Spacer(minLength: 0)
                                            }.frame(minHeight: 44).contentShape(Rectangle())
                                        }.buttonStyle(.plain).listRowBackground(theme.row)
                                            .accessibilityHint("Opens a new regular tab in \(profile.name)")
                                    }
                                }
                            }
                            if continuity.state.profiles.allSatisfy({ continuity.state.tabs(for: $0.id, device: device.id).isEmpty }) {
                                Text("No open tabs at last sync").foregroundStyle(theme.secondaryText).listRowBackground(theme.row)
                            }
                        } header: {
                            HStack(alignment: .firstTextBaseline) {
                                Text(device.name)
                                Spacer()
                                Text(device.updatedAt.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(theme.secondaryText)
                            }.accessibilityElement(children: .combine)
                        }
                    }
                }.orivListStyle(theme)
            }
        }.background(theme.canvas).navigationTitle("Other devices")
    }
    @ViewBuilder private var setupAction: some View {
        #if os(macOS)
        SettingsLink { Text("Set Up in Settings") }
        #else
        NavigationLink("Set Up Mac & iPhone") { ContinuitySettingsView(continuity: continuity) }
        #endif
    }
}

@MainActor private final class HandoffPublisher {
    private var activity: NSUserActivity?
    func update(_ page: ContinuityPage?, type: String) {
        activity?.invalidate(); activity = nil
        guard let page else { return }
        let next = NSUserActivity(activityType: type)
        next.title = page.title; next.webpageURL = page.url; next.userInfo = page.userInfo
        next.requiredUserInfoKeys = Set(page.userInfo.keys)
        next.isEligibleForHandoff = true; next.isEligibleForSearch = false; next.isEligibleForPublicIndexing = false
        #if os(iOS)
        next.isEligibleForPrediction = false
        #endif
        activity = next; next.becomeCurrent()
    }
}

struct BrowserHandoff: ViewModifier {
    let continuity: BrowserContinuity
    let session: BrowserSession
    let profile: BrowserProfile
    let open: (ContinuityPage) -> Void
    @Environment(\.scenePhase) private var phase
    @State private var publisher = HandoffPublisher()
    private var page: ContinuityPage? {
        guard phase == .active, continuity.canHandoff, let tab = session.selectedTab else { return nil }
        return ContinuityPage(url: tab.url, title: tab.title, profile: profile, isPrivate: tab.isPrivate)
    }
    func body(content: Content) -> some View {
        content.onChange(of: page, initial: true) { _, value in publisher.update(value, type: continuity.activityType) }
            .onDisappear { publisher.update(nil, type: continuity.activityType) }
            .onContinueUserActivity(continuity.activityType) { activity in
                guard continuity.canHandoff, let page = ContinuityPage(userInfo: activity.userInfo) else { return }
                open(page)
            }
    }
}
