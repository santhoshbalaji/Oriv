import ProductivityKit
import SwiftUI

struct CaptureSheet: View {
    let controller: BrowserController
    let capture: PageCapture
    @State private var title: String
    @State private var purpose = ""
    @State private var choice: CaptureKind
    @State private var saving = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    init(controller: BrowserController, capture: PageCapture) {
        self.controller = controller; self.capture = capture
        _title = State(initialValue: capture.title); _choice = State(initialValue: capture.kind)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                SiteIdentity(url: capture.url, size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Save with context").font(Theme.editorial(27))
                    Text(capture.url.host() ?? "Page").font(.callout).foregroundStyle(.secondary)
                }
            }
            Text("Title").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            TextField("Title", text: $title).textFieldStyle(.roundedBorder)
            Picker("Keep", selection: $choice) {
                if !capture.text.isEmpty { Text(capture.kind.rawValue).tag(capture.kind) }
                if !capture.selection.isEmpty { Text("Selected passage").tag(CaptureKind.selection) }
                Text("Link only").tag(CaptureKind.link)
            }.pickerStyle(.segmented)
            Text(capture.explanation).font(.caption).foregroundStyle(.secondary)
            if choice != .link {
                ScrollView {
                    Text(choice == .selection ? capture.selection : capture.text)
                        .font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(14)
                }.frame(height: 180).background(Theme.field, in: .rect(cornerRadius: 12))
            }
            TextField("Why are you saving this? (optional)", text: $purpose, axis: .vertical)
                .lineLimit(2...4).textFieldStyle(.roundedBorder)
            Text("Saved on this Mac. Form fields and passwords are excluded. Review the preview before saving sensitive content.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                let existing = controller.workspace?.existingItem(for: capture.url)
                Button(existing == nil ? "Save item" : "Add snapshot") {
                    guard let store = controller.workspace else { return }
                    saving = true
                    do {
                        var draft = capture; draft.title = title
                        let id = try store.save(draft, purpose: purpose, kind: choice, existingID: existing?.id)
                        dismiss(); controller.showWorkspace(itemID: id)
                    } catch { self.error = error.localizedDescription; saving = false }
                }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
            }
        }.padding(28).frame(width: 560).background(Theme.surface)
    }
}

struct ItemEditor: View {
    let controller: BrowserController
    let store: WorkspaceStore
    let item: SavedItem?
    @State private var title: String
    @State private var purpose: String
    @State private var state: ItemState
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    init(controller: BrowserController, store: WorkspaceStore, item: SavedItem? = nil) {
        self.controller = controller; self.store = store; self.item = item
        _title = State(initialValue: item?.title ?? ""); _purpose = State(initialValue: item?.purpose ?? "")
        _state = State(initialValue: item?.state ?? .reference)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            EditorHeading(title: item == nil ? "Create an item" : "Edit item", subtitle: "A place for context and what comes next.", symbol: "bookmark")
            Text("Title").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            TextField("Title", text: $title).textFieldStyle(.roundedBorder)
            TextField("What would you like to remember or achieve?", text: $purpose, axis: .vertical)
                .lineLimit(3...6).textFieldStyle(.roundedBorder)
            if item != nil {
                Picker("Status", selection: $state) {
                    ForEach(ItemState.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    do {
                        if let item { try store.updateItem(item.id, title: title, purpose: purpose, state: state) }
                        else { controller.selectedItemID = try store.createItem(title: title, purpose: purpose) }
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(28).frame(width: 490).background(Theme.surface)
    }
}

struct NoteEditor: View {
    let controller: BrowserController
    let store: WorkspaceStore
    let itemID: UUID
    let note: WorkspaceNote?
    @State private var bodyText: String
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    init(controller: BrowserController, store: WorkspaceStore, itemID: UUID, note: WorkspaceNote?) {
        self.controller = controller; self.store = store; self.itemID = itemID; self.note = note
        _bodyText = State(initialValue: note?.body ?? "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            EditorHeading(title: note == nil ? "Add a note" : "Edit note", subtitle: "Keep a thought, decision or update with this item.", symbol: "text.alignleft")
            TextEditor(text: $bodyText).font(.body).padding(8).frame(height: 220)
                .background(Theme.field, in: .rect(cornerRadius: 10)).accessibilityLabel("Note text")
            if note != nil { Text("Previous text stays available in Activity → Note history.").font(.caption).foregroundStyle(.secondary) }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save note") {
                    do { try store.addNote(to: itemID, body: bodyText, replacing: note?.id); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(.glassProminent).keyboardShortcut("s", modifiers: .command)
                    .disabled(bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(28).frame(width: 540).background(Theme.surface)
    }
}

struct ActionEditor: View {
    let controller: BrowserController
    let store: WorkspaceStore
    let itemID: UUID
    let action: WorkspaceAction?
    @State private var title: String
    @State private var hasDue: Bool
    @State private var due: Date
    @State private var hasReminder: Bool
    @State private var reminder: Date
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    init(controller: BrowserController, store: WorkspaceStore, itemID: UUID, action: WorkspaceAction?) {
        self.controller = controller; self.store = store; self.itemID = itemID; self.action = action
        _title = State(initialValue: action?.title ?? "")
        _hasDue = State(initialValue: action?.dueAt != nil); _due = State(initialValue: action?.dueAt ?? .now.addingTimeInterval(86400))
        _hasReminder = State(initialValue: action?.reminderAt != nil)
        _reminder = State(initialValue: action?.reminderAt ?? .now.addingTimeInterval(3600))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            EditorHeading(title: action == nil ? "Your next action" : "Edit action", subtitle: "One clear step to move this forward.", symbol: "checklist")
            TextField("What needs to happen?", text: $title).textFieldStyle(.roundedBorder)
            Toggle("Set a due date", isOn: $hasDue)
            if hasDue { DatePicker("Due", selection: $due, displayedComponents: [.date, .hourAndMinute]) }
            Divider()
            Toggle("Remind me", isOn: $hasReminder)
            if hasReminder {
                DatePicker("Reminder", selection: $reminder, displayedComponents: [.date, .hourAndMinute])
                Menu("Quick choices", systemImage: "clock") {
                    Button("In 5 minutes") { reminder = .now.addingTimeInterval(300) }
                    Button("In an hour") { reminder = .now.addingTimeInterval(3600) }
                    Button("Tomorrow at 9 am") {
                        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: .now)!
                        reminder = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)!
                    }
                }.fixedSize().buttonStyle(.glass)
                Text(controller.reminders.permission == .allowed ? "This alert will be scheduled on this Mac when you save." : "If needed, Oriv will ask for notification permission when you save. Alerts are scheduled on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Times use \(TimeZone.current.identifier). A due date and a reminder can be different.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save action") {
                    do {
                        try store.saveAction(itemID: itemID, actionID: action?.id, title: title,
                            dueAt: hasDue ? due : nil, reminderAt: hasReminder ? reminder : nil)
                        controller.refreshReminders(requestPermission: hasReminder); dismiss()
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(28).frame(width: 510).background(Theme.surface)
    }
}
