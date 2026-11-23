import BrowserCore
import SwiftUI

extension ProfileColor {
    func tint(in theme: Theme) -> Color {
        switch self {
        case .mulberry: theme.secondaryText
        case .ocean: .blue
        case .fern: .green
        case .amber: .orange
        case .slate: .secondary
        }
    }
    var title: String { rawValue.capitalized }
}

private extension ProfileSymbol {
    var title: String {
        switch self {
        case .person: "Personal"
        case .work: "Work"
        case .study: "Study"
        case .travel: "Travel"
        case .creative: "Creative"
        }
    }
}

struct ProfileMenu: View {
    let profiles: BrowserProfiles
    let iconOnly: Bool
    let tabCount: Int
    let showsKeyboardFocus: Bool
    @FocusState private var focused: Bool
    @State private var hovered = false

    var body: some View {
        Menu {
            ForEach(profiles.available) { profile in
                Button {
                    profiles.switchFromSidebar(profile.id, source: profiles.controller)
                } label: {
                    Label(profile.name + (profile.id == profiles.active.id ? " — Current" : ""),
                          systemImage: profile.id == profiles.active.id ? "checkmark" : profile.symbol.rawValue)
                }
            }
            Divider()
            Button("Manage Profiles…", systemImage: "person.crop.rectangle.stack") { profiles.showManager = true }
        } label: {
            ProfileHeaderArtwork(profile: profiles.active, tabCount: tabCount, iconOnly: iconOnly)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .focused($focused)
        .modifier(SidebarFocusRing(visible: focused && showsKeyboardFocus))
        .modifier(SidebarToneSurface(tone: hovered ? .hover : nil))
        .onHover { hovered = $0 }
        .transformPreference(SidebarKeyboardFocusKey.self) { $0 = $0 || focused }
        .accessibilityLabel("Profile: \(profiles.active.name)")
        .accessibilityValue(SidebarTabs.countLabel(tabCount))
        .help("Switch profile in this window. Website logins, bookmarks and history are separate.")
    }
}

struct ProfileHeaderArtwork: View {
    @Environment(\.sidebarContrast) private var contrast
    @Environment(\.browserTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    let profile: BrowserProfile?
    let tabCount: Int
    var iconOnly = false
    var marksGeometry = true

    var body: some View {
        HStack(spacing: OrivSpacing.small) {
            Image(systemName: profile?.symbol.rawValue ?? "eyeglasses").font(OrivIcon.toolbarFont)
                .foregroundStyle(profile?.color.sidebarInk(dark: scheme == .dark) ?? theme.sidebarPrivateAccent)
                .frame(width: OrivLayout.sidebarProfileIconSize, height: OrivLayout.sidebarProfileIconSize)
                .accessibilityHidden(true)
            if !iconOnly {
                Text(profile?.name ?? "Private").font(OrivType.headline).lineLimit(1)
                    .browserGeometryMarker("sidebarProfileNameGeometry", when: marksGeometry)
                Text(tabCount.formatted()).font(OrivType.caption.monospacedDigit())
                    .foregroundStyle(theme.sidebarSecondaryText(contrast))
                    .browserGeometryMarker("sidebarProfileCountGeometry", when: marksGeometry)
                Spacer(minLength: 0)
                if profile != nil { Image(systemName: "chevron.up.chevron.down").font(OrivIcon.close) }
            }
        }
        .foregroundStyle(theme.text)
        .padding(.horizontal, OrivSpacing.small)
        .frame(height: OrivLayout.sidebarProfileHeight)
        .contentShape(Rectangle())
    }
}

struct ProfilesView: View {
    @Environment(\.browserTheme) private var theme
    let profiles: BrowserProfiles
    var canSwitch = true
    var inSettings = false
    @State private var selectedID: UUID?
    @State private var creating = false
    @State private var name = ""
    @State private var color: ProfileColor = .mulberry
    @State private var symbol: ProfileSymbol = .person
    @State private var message: String?
    @State private var archiveID: UUID?
    @State private var deleting: BrowserProfile?
    private var selected: BrowserProfile? { (profiles.available + profiles.archived).first { $0.id == selectedID } }
    var body: some View {
        HStack(spacing: OrivSpacing.medium) {
            if inSettings {
                profileList.settingsGroupSurface()
                    .padding(.leading, MacSettingsLayout.formHorizontalInset)
                    .padding(.vertical, MacSettingsLayout.formVerticalInset)
            } else {
                profileList.padding(.vertical, OrivSpacing.medium)
                Divider()
            }
            if inSettings {
                SettingsForm { editorSections }
            } else {
                Form { editorSections }.formStyle(.grouped)
            }
        }
        .onAppear { if selectedID == nil && !creating { choose(profiles.active) } }
        .sheet(item: $deleting) { profile in
            DeleteProfileConfirmation(profile: profile) {
                Task { @MainActor in
                    do { try await profiles.delete(profile); choose(profiles.active) }
                    catch { message = error.localizedDescription }
                }
            }
        }
        .confirmationDialog("Archive this profile?", isPresented: Binding(get: { archiveID != nil }, set: { if !$0 { archiveID = nil } })) {
            Button("Archive Profile", role: .destructive) { if let archiveID { perform { try profiles.archive(archiveID) } }; archiveID = nil }
        } message: { Text("Regular tabs and data are saved. Private tabs close. Restore the profile from this screen to find its files.") }
    }
    private var profileList: some View {
        VStack(alignment: .leading, spacing: OrivSpacing.medium) {
            SectionHeader(title: "Profiles", kind: .content, ink: theme.text)
            ScrollView {
                VStack(spacing: OrivSpacing.xs) {
                    ForEach(profiles.available) { profile in profileRow(profile) }
                    if !profiles.archived.isEmpty {
                        SectionHeader(title: "Archived", kind: .sidebar)
                            .padding(.top, OrivSpacing.large)
                        ForEach(profiles.archived) { profile in profileRow(profile) }
                    }
                }
            }
            Button("Add Profile", systemImage: "plus") {
                selectedID = nil; creating = true; name = ""; color = .ocean; symbol = .work; message = nil
            }.orivButton(.secondary).disabled(!profiles.canModify)
        }
        .frame(width: 175)
    }

    @ViewBuilder private var editorSections: some View {
        editorGroup(creating ? "New profile" : selected?.name ?? "Choose a profile",
                    detail: "Profiles keep website logins, tabs, history, settings, and bookmarks separate. Anyone using this Mac account can switch profiles. Apple Passwords and saved files use the same macOS account.") {
            TextField("Profile name", text: $name).accessibilityIdentifier("profileNameField")
            Picker("Symbol", selection: $symbol) {
                ForEach(ProfileSymbol.allCases, id: \.self) { Label($0.title, systemImage: $0.rawValue).tag($0) }
            }
            Picker("Color", selection: $color) {
                ForEach(ProfileColor.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            SettingRow(detail: profiles.notice) {
                Button(creating ? "Create Profile" : "Save Changes", action: saveProfile)
                    .orivButton(.primary)
                    .disabled(!profiles.canModify || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let message {
                Text(message).font(OrivType.caption).foregroundStyle(theme.danger)
                    .accessibilityIdentifier("profileEditorMessage")
            }
        }
        if let selected, selected.id != profiles.active.id, canSwitch || !selected.isPersonal {
            editorGroup("Profile actions", detail: "Archiving hides a profile. Its tabs, bookmarks, history and website data return when you restore it.") {
                if selected.archivedAt != nil {
                    Button("Restore Profile") { perform { try profiles.restore(selected.id) } }
                        .orivButton(.secondary).disabled(!profiles.canModify)
                } else {
                    if canSwitch {
                        Button("Switch to Profile") {
                            // Close the manager before checking for other open editors.
                            profiles.pendingSelection = selected.id
                            profiles.showManager = false
                        }.orivButton(.secondary)
                    }
                    if !selected.isPersonal {
                        Button("Archive Profile…", role: .destructive) { archiveID = selected.id }
                            .orivButton(.destructive).disabled(!profiles.canModify)
                    }
                }
                if !selected.isPersonal {
                    Button(OrivStrings.deleteProfilePrompt, role: .destructive) { deleting = selected }
                        .orivButton(.destructive).disabled(!profiles.canModify)
                    if inSettings, profiles.continuity.state.enabled {
                        Text("Deletion reaches other devices when they sync.")
                            .font(OrivType.caption).foregroundStyle(theme.textSecondary)
                    }
                }
            }
        }
    }

    @ViewBuilder private func editorGroup<Content: View>(_ title: String, detail: String,
                                                         @ViewBuilder content: @escaping () -> Content) -> some View {
        if inSettings {
            SettingsGroup(title, detail: detail, content: content)
        } else {
            Section(content: content, header: { Text(title) }, footer: { Text(detail) })
        }
    }

    private func saveProfile() {
        perform {
            if creating {
                choose(try profiles.create(name: name, color: color, symbol: symbol))
            } else if let selected {
                try profiles.update(selected.id, name: name, color: color, symbol: symbol)
            }
        }
    }

    private func profileRow(_ profile: BrowserProfile) -> some View {
        Button { choose(profile) } label: {
            HStack(spacing: OrivSpacing.small) {
                Image(systemName: profile.symbol.rawValue)
                    .foregroundStyle(inSettings && profile.color == .mulberry
                                     ? theme.private : profile.color.tint(in: theme))
                    .frame(width: OrivSpacing.larger)
                VStack(alignment: .leading, spacing: OrivSpacing.xs) {
                    Text(profile.name).font(OrivType.body).lineLimit(1)
                    if profile.id == profiles.active.id { Badge(text: "Current profile", padsLabel: false) }
                    else if let count = profiles.loadedController(profile.id)?.downloads.items.filter({ !$0.isFinished }).count, count > 0 {
                        Badge(text: "\(count) active downloads", kind: .count, padsLabel: false)
                    }
                }
                Spacer(minLength: 0)
            }.padding(OrivSpacing.medium).frame(maxWidth: .infinity, alignment: .leading)
                .modifier(ListSelection(selected: selectedID == profile.id))
        }.orivButton(.quiet)
            .accessibilityLabel(profile.name + (profile.id == profiles.active.id ? ", current profile" : ""))
            .accessibilityAddTraits(selectedID == profile.id ? [.isSelected] : [])
    }
    private func choose(_ profile: BrowserProfile) {
        selectedID = profile.id; creating = false; name = profile.name; color = profile.color; symbol = profile.symbol; message = nil
    }
    private func perform(_ body: () throws -> Void) { do { try body(); message = nil } catch { message = error.localizedDescription } }
}

struct ProfilesSheet: View {
    @Environment(\.browserTheme) private var theme
    let profiles: BrowserProfiles
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        OrivSheet(title: "Your browsing profiles", size: .large, height: 560) {
            ProfilesView(profiles: profiles)
        } actions: {
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }
    }
}
