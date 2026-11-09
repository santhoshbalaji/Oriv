import BrowserCore
import SwiftUI

extension ProfileColor {
    func tint(in theme: Theme) -> Color {
        switch self {
        case .mulberry: Color(red: 0.89, green: 0.68, blue: 0.77)
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
    @Environment(\.browserTheme) private var theme
    let profiles: BrowserProfiles
    var compact = false
    var iconOnly = false
    var body: some View {
        Menu {
            ForEach(profiles.available) { profile in
                Button {
                    profiles.perform { try profiles.select(profile.id) }
                } label: {
                    Label(profile.name + (profile.id == profiles.active.id ? " — Current" : ""), systemImage: profile.id == profiles.active.id ? "checkmark" : profile.symbol.rawValue)
                }
            }
            Divider()
            Button("Manage Profiles…", systemImage: "person.crop.rectangle.stack") { profiles.showManager = true }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: profiles.active.symbol.rawValue).foregroundStyle(profiles.active.color.tint(in: theme))
                if !iconOnly { Text(profiles.active.name).foregroundStyle(theme.text).lineLimit(1) }
                if !compact && !iconOnly { Spacer(minLength: 0) }
            }.font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.borderlessButton).menuIndicator(iconOnly ? .hidden : .automatic)
        .accessibilityLabel("Profile: \(profiles.active.name)")
        .help("Switch profile in this window. Website logins, bookmarks and history are separate.")
    }
}

struct ProfilesView: View {
    @Environment(\.browserTheme) private var theme
    let profiles: BrowserProfiles
    var canSwitch = true
    @State private var selectedID: UUID?
    @State private var creating = false
    @State private var name = ""
    @State private var color: ProfileColor = .mulberry
    @State private var symbol: ProfileSymbol = .person
    @State private var message: String?
    @State private var archiveID: UUID?
    private var selected: BrowserProfile? { profiles.registry.profiles.first { $0.id == selectedID } }
    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Profiles").font(.headline)
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(profiles.available) { profile in profileRow(profile) }
                        if !profiles.archived.isEmpty {
                            Text("Archived").font(.caption).foregroundStyle(theme.secondaryText).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 16)
                            ForEach(profiles.archived) { profile in profileRow(profile) }
                        }
                    }
                }
                Button("Add Profile", systemImage: "plus") {
                    selectedID = nil; creating = true; name = ""; color = .ocean; symbol = .work; message = nil
                }.disabled(!profiles.canModify)
            }.frame(width: 175)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Label(creating ? "New profile" : selected?.name ?? "Choose a profile", systemImage: symbol.rawValue)
                        .font(.title2).foregroundStyle(color.tint(in: theme))
                    Text("Separate website logins, tabs, history, settings, and bookmarks.")
                        .font(.callout).foregroundStyle(theme.secondaryText)
                    TextField("Profile name", text: $name).textFieldStyle(.roundedBorder).accessibilityIdentifier("profileNameField")
                    Picker("Symbol", selection: $symbol) {
                        ForEach(ProfileSymbol.allCases, id: \.self) { Label($0.title, systemImage: $0.rawValue).tag($0) }
                    }
                    Picker("Color", selection: $color) { ForEach(ProfileColor.allCases, id: \.self) { Text($0.title).tag($0) } }
                    if let notice = profiles.notice { Text(notice).font(.caption).foregroundStyle(theme.secondaryText) }
                    if let message { Text(message).font(.callout).foregroundStyle(.red).accessibilityIdentifier("profileEditorMessage") }
                    HStack {
                        Button(creating ? "Create Profile" : "Save Changes") {
                            do {
                                if creating {
                                    let profile = try profiles.create(name: name, color: color, symbol: symbol)
                                    choose(profile)
                                } else if let selected { try profiles.update(selected.id, name: name, color: color, symbol: symbol) }
                                message = nil
                            } catch { message = error.localizedDescription }
                        }.buttonStyle(.borderedProminent).tint(theme.controlFill).disabled(!profiles.canModify || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if let selected, selected.archivedAt != nil {
                            Button("Restore") { perform { try profiles.restore(selected.id) } }.disabled(!profiles.canModify)
                        } else if let selected, selected.id != profiles.active.id, canSwitch {
                            Button("Switch to Profile") {
                                // Close the manager before the model checks for other open editors.
                                profiles.pendingSelection = selected.id
                                profiles.showManager = false
                            }
                        }
                    }
                    if let selected, selected.archivedAt == nil, selected.id != profiles.active.id, !selected.isPersonal {
                        Button("Archive Profile…", role: .destructive) { archiveID = selected.id }.disabled(!profiles.canModify)
                    }
                    Divider()
                    Text("Profiles organize your browsing; they aren’t locked accounts. Anyone using this Mac account can switch profiles. Apple Passwords and files you explicitly save use the same macOS account.")
                        .font(.caption).foregroundStyle(theme.secondaryText)
                    Text("Archiving hides a profile. Its tabs, bookmarks, history and website data remain available when you restore it.")
                        .font(.caption).foregroundStyle(theme.secondaryText)
                }.padding(.trailing, 6)
            }
        }
        .onAppear { if selectedID == nil && !creating { choose(profiles.active) } }
        .confirmationDialog("Archive this profile?", isPresented: Binding(get: { archiveID != nil }, set: { if !$0 { archiveID = nil } })) {
            Button("Archive Profile") { if let archiveID { perform { try profiles.archive(archiveID) } }; archiveID = nil }
        } message: { Text("Regular tabs and data are saved. Private tabs close. You can restore the profile from this screen. This does not delete its files.") }
    }
    private func profileRow(_ profile: BrowserProfile) -> some View {
        Button { choose(profile) } label: {
            HStack(spacing: 9) {
                Image(systemName: profile.symbol.rawValue).foregroundStyle(profile.color.tint(in: theme)).frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.name).lineLimit(1)
                    if profile.id == profiles.active.id { Text("Current profile").font(.caption2).foregroundStyle(theme.secondaryText) }
                    else if let count = profiles.loadedController(profile.id)?.downloads.items.filter({ !$0.isFinished }).count, count > 0 {
                        Text("\(count) active downloads").font(.caption2).foregroundStyle(theme.secondaryText)
                    }
                }
                Spacer(minLength: 0)
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(selectedID == profile.id ? theme.accent.opacity(0.12) : .clear, in: .rect(cornerRadius: 8))
        }.buttonStyle(.plain).accessibilityLabel(profile.name + (profile.id == profiles.active.id ? ", current profile" : ""))
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
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text("Your browsing profiles").font(Theme.editorial(24)); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            ProfilesView(profiles: profiles)
        }.padding(24).frame(width: 700, height: 560)
    }
}
