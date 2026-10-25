import BrowserCore
import ProductivityKit
import SwiftUI

enum WorkspaceFilter: String, CaseIterable, Identifiable {
    case all = "All saved", today = "Today", upcoming = "Upcoming", waiting = "Waiting", archive = "Archive", trash = "Trash"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .all: "bookmark"; case .today: "sun.max"; case .upcoming: "calendar"
        case .waiting: "hourglass"; case .archive: "archivebox"; case .trash: "trash"
        }
    }
}

struct WorkspaceView: View {
    @Bindable var controller: BrowserController
    @State private var filter: WorkspaceFilter = .all
    @State private var search = ""
    @State private var newItem = false
    @Environment(\.scenePhase) private var phase
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let store = controller.workspace {
                NavigationSplitView {
                    List(selection: $filter) {
                        Section("Library") {
                            scopeRow(.all, store: store)
                        }
                        Section("Follow through") {
                            ForEach([WorkspaceFilter.today, .upcoming, .waiting]) { scope in scopeRow(scope, store: store) }
                        }
                        Section {
                            ForEach(WorkspaceFilter.allCases.suffix(2)) { scope in
                                scopeRow(scope, store: store)
                            }
                        }
                    }.listStyle(.sidebar)
                        .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
                        .safeAreaInset(edge: .top) {
                            OrivIdentity(subtitle: "Workspace").frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 12)
                        }
                        .safeAreaInset(edge: .bottom) {
                            VStack(alignment: .leading, spacing: 5) {
                                Label("On this Mac", systemImage: "internaldrive")
                                    .font(.caption.weight(.medium))
                                Text("Saved locally. Ready offline.").font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                        }
                } content: {
                    let visible = filtered(store)
                    List(selection: $controller.selectedItemID) {
                        ForEach(visible) { item in
                            WorkspaceItemRow(item: item, actions: store.steps(for: item.id), isSelected: controller.selectedItemID == item.id)
                                .tag(item.id).padding(.vertical, 7)
                        }
                    }
                    .navigationTitle(filter.rawValue)
                    .navigationSubtitle("\(visible.count) \(visible.count == 1 ? "item" : "items")")
                    .scrollContentBackground(.hidden).background(Theme.canvas)
                    .searchable(text: $search, prompt: "Search saved content")
                    .overlay {
                        if visible.isEmpty {
                            ContentUnavailableView {
                                Label(search.isEmpty ? emptyTitle : "No matching items", systemImage: filter.symbol)
                            } description: {
                                Text(search.isEmpty ? emptyDescription : "Try a title, note, action or phrase from a saved page.")
                            } actions: {
                                if filter == .all && search.isEmpty {
                                    Button("Create an item") { newItem = true }.buttonStyle(.glass)
                                }
                            }
                        }
                    }
                    .frame(minWidth: 250)
                    .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 380)
                } detail: {
                    if let id = controller.selectedItemID, let item = store.item(id) {
                        WorkspaceDetail(controller: controller, store: store, item: item).id(item.id)
                            .navigationSplitViewColumnWidth(min: 400, ideal: 620)
                    } else {
                        VStack(alignment: .leading, spacing: 22) {
                            OrivThread().frame(width: 110, height: 80)
                            Text("Keep a thought.\nGive it a next step.").font(Theme.editorial(32))
                                .accessibilityAddTraits(.isHeader)
                            Text("Your sources, notes and actions belong together. Choose an item to pick up where you left off.")
                                .font(.body).foregroundStyle(.secondary).lineSpacing(4)
                            Divider()
                            Label("Save a page with ⌘D", systemImage: "bookmark")
                            Label("Keep the context in your own words", systemImage: "text.alignleft")
                            Label("Follow through with actions & reminders", systemImage: "checklist")
                            Button("Create an item", systemImage: "plus") { newItem = true }.buttonStyle(.glass)
                        }.frame(maxWidth: 370, alignment: .leading).padding(40)
                            .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.surface)
                    }
                }
                .navigationSplitViewStyle(.balanced)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("New item", systemImage: "square.and.pencil") { newItem = true }.help("Create an item")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Browser", systemImage: "safari") { openWindow(id: "browser") }.help("Open browser")
                    }
                }
                .sheet(isPresented: $newItem) { ItemEditor(controller: controller, store: store) }
                .onChange(of: store.revision) { _, _ in
                    controller.refreshReminders()
                    reconcileSelection(in: store)
                }
                .onChange(of: filter) { _, _ in reconcileSelection(in: store) }
                .onChange(of: search) { _, _ in reconcileSelection(in: store) }
            } else {
                ContentUnavailableView("Workspace couldn’t open", systemImage: "externaldrive.badge.exclamationmark",
                    description: Text(controller.workspaceError ?? "Your existing data has been preserved. Try reopening Oriv."))
            }
        }
        .frame(minWidth: 960, minHeight: 620)
        .alert("Workspace", isPresented: Binding(get: { controller.workspaceError != nil }, set: { if !$0 { controller.workspaceError = nil } })) {
            Button("OK") { controller.workspaceError = nil }
        } message: { Text(controller.workspaceError ?? "") }
        .task { controller.refreshReminders() }
        .onChange(of: phase) { _, value in if value == .active { controller.refreshReminders() } }
        .onAppear { focusRequestedItem() }
        .onChange(of: controller.workspaceRequest) { _, _ in focusRequestedItem() }
    }

    private var emptyTitle: String {
        switch filter {
        case .all: "A home for what matters"; case .today: "Nothing due today"; case .upcoming: "Room for your next step"
        case .waiting: "Nothing waiting"; case .archive: "Your archive is empty"; case .trash: "Trash is empty"
        }
    }
    private var emptyDescription: String {
        switch filter {
        case .all: "Save useful pages with their context, then add notes and next actions."
        case .today, .upcoming: "Add a due date or reminder to an action to see it here."
        case .waiting: "Set an item to Waiting when you’re expecting a response."
        case .archive: "Archive items you want to keep without active reminders."
        case .trash: "Items moved to Trash stay recoverable."
        }
    }
    private func scopeRow(_ scope: WorkspaceFilter, store: WorkspaceStore) -> some View {
        HStack(spacing: 10) {
            Label(scope.rawValue, systemImage: scope.symbol)
            Spacer()
            let count = filtered(store, scope: scope, query: "").count
            if count > 0 { Text("\(count)").font(.caption).monospacedDigit().foregroundStyle(.secondary) }
        }.padding(.vertical, 5).tag(scope)
    }
    private func filtered(_ store: WorkspaceStore) -> [SavedItem] { filtered(store, scope: filter, query: search) }
    private func filtered(_ store: WorkspaceStore, scope filter: WorkspaceFilter, query: String) -> [SavedItem] {
        let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now))!
        return store.items.filter { item in
            guard store.matches(item, query: query) else { return false }
            if filter == .trash { return item.deletedAt != nil }
            guard item.deletedAt == nil else { return false }
            if filter == .archive { return item.archivedAt != nil }
            guard item.archivedAt == nil else { return false }
            switch filter {
            case .all: return true
            case .waiting: return item.state == .waiting
            case .today: return store.steps(for: item.id).contains { !$0.isComplete && [$0.dueAt, $0.reminderAt].compactMap { $0 }.contains { $0 < end } }
            case .upcoming: return store.steps(for: item.id).contains { !$0.isComplete && [$0.dueAt, $0.reminderAt].compactMap { $0 }.contains { $0 >= end } }
            default: return false
            }
        }
    }
    private func reconcileSelection(in store: WorkspaceStore) {
        if let id = controller.selectedItemID, !filtered(store).contains(where: { $0.id == id }) {
            controller.selectedItemID = nil
        }
    }
    private func focusRequestedItem() {
        let item = controller.selectedItemID.flatMap { controller.workspace?.item($0) }
        filter = item?.deletedAt != nil ? .trash : item?.archivedAt != nil ? .archive : .all
        search = ""
    }
}

private struct WorkspaceItemRow: View {
    let item: SavedItem
    let actions: [WorkspaceAction]
    let isSelected: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SiteIdentity(url: item.url, size: 32, isSelected: isSelected)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title).font(.body.weight(.medium)).lineLimit(2)
                Text(item.purpose.isEmpty ? item.url?.host() ?? "Personal item" : item.purpose)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: 8) {
                    Text(item.state.rawValue).fontWeight(.medium)
                    let count = actions.filter { !$0.isComplete }.count
                    if count > 0 { Label("\(count)", systemImage: "checklist") }
                }.font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 2)
    }
}

private enum DetailPane: String, CaseIterable { case overview = "Overview", content = "Content", activity = "Activity" }
private struct NoteDraft: Identifiable { let id = UUID(); let note: WorkspaceNote? }
private struct ActionDraft: Identifiable { let id = UUID(); let action: WorkspaceAction? }

private struct WorkspaceDetail: View {
    let controller: BrowserController
    let store: WorkspaceStore
    let item: SavedItem
    @State private var pane: DetailPane = .overview
    @State private var editItem = false
    @State private var noteDraft: NoteDraft?
    @State private var actionDraft: ActionDraft?
    @Environment(\.openWindow) private var openWindow
    private var inactive: Bool { item.deletedAt != nil || item.archivedAt != nil }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    if let message = controller.reminders.message, store.steps(for: item.id).contains(where: { $0.reminderAt != nil && !$0.isComplete }) {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(message, systemImage: "bell.badge").font(.callout)
                            if controller.reminders.permission == .unknown {
                                Button("Enable notifications") { controller.refreshReminders(requestPermission: true) }
                            }
                        }.padding(14).background(.quaternary, in: .rect(cornerRadius: 12))
                    }
                    Picker("Show item details", selection: $pane) {
                        ForEach(DetailPane.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden()
                    switch pane {
                    case .overview: overview
                    case .content: content
                    case .activity: activity
                    }
                }.padding(32).frame(maxWidth: 780, alignment: .leading).frame(maxWidth: .infinity)
            }.background(Theme.surface)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Edit details", systemImage: "pencil") { editItem = true }.disabled(item.deletedAt != nil)
                    Button(item.archivedAt == nil ? "Archive item" : "Return to library", systemImage: "archivebox") {
                        controller.performWorkspace { try store.setArchived(item.id, archived: item.archivedAt == nil) }
                    }.disabled(item.deletedAt != nil)
                    Divider()
                    Button(item.deletedAt == nil ? "Move to Trash" : "Restore item", systemImage: item.deletedAt == nil ? "trash" : "arrow.uturn.backward") {
                        controller.performWorkspace { try store.setDeleted(item.id, deleted: item.deletedAt == nil) }
                    }
                } label: { Label("Item actions", systemImage: "ellipsis") }
            }
        }
        .sheet(isPresented: $editItem) { ItemEditor(controller: controller, store: store, item: item) }
        .sheet(item: $noteDraft) { draft in NoteEditor(controller: controller, store: store, itemID: item.id, note: draft.note) }
        .sheet(item: $actionDraft) { draft in ActionEditor(controller: controller, store: store, itemID: item.id, action: draft.action) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(item.deletedAt != nil ? "In Trash" : item.archivedAt != nil ? "Archived" : item.state.rawValue,
                      systemImage: item.deletedAt != nil ? "trash" : item.archivedAt != nil ? "archivebox" : "bookmark")
                    .font(.caption.weight(.medium)).foregroundStyle(Theme.accent)
                Spacer()
                Text(item.createdAt, format: .dateTime.month(.abbreviated).day().year()).font(.caption).foregroundStyle(.secondary)
            }
            Text(item.title).font(Theme.editorial(32)).textSelection(.enabled).accessibilityAddTraits(.isHeader)
            if !item.purpose.isEmpty { Text(item.purpose).font(.system(size: 14)).lineSpacing(4).foregroundStyle(.secondary).textSelection(.enabled) }
            if let url = item.url {
                Button {
                    controller.openExternal(url); openWindow(id: "browser")
                } label: { Label(url.host() ?? url.absoluteString, systemImage: "arrow.up.right") }
                .buttonStyle(.link).help(url.absoluteString)
            }
            if inactive { Text("Reminders are paused for this item. Restore it to continue.").font(.callout).foregroundStyle(.secondary) }
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Next actions").font(.headline)
                    Spacer()
                    Button("Add action", systemImage: "plus") { actionDraft = ActionDraft(action: nil) }
                        .buttonStyle(.glass).disabled(inactive)
                }
                let steps = store.steps(for: item.id)
                if steps.isEmpty {
                    Text("What would you like to do with this? Add a next step, with a date or reminder if you need one.")
                        .foregroundStyle(.secondary).font(.callout)
                }
                ForEach(steps) { action in
                    HStack(alignment: .top, spacing: 12) {
                        Button {
                            controller.performWorkspace { try store.completeAction(action.id, completed: !action.isComplete) }
                        } label: {
                            Image(systemName: action.isComplete ? "checkmark.circle.fill" : "circle")
                                .font(.title3).foregroundStyle(action.isComplete ? Theme.completion : .secondary)
                        }.buttonStyle(.plain).padding(.top, 2).disabled(inactive)
                            .accessibilityLabel("\(action.isComplete ? "Reopen" : "Complete") \(action.title)")
                        VStack(alignment: .leading, spacing: 5) {
                            Text(action.title).strikethrough(action.isComplete).foregroundStyle(action.isComplete ? .secondary : .primary)
                            if let date = action.dueAt {
                                Label("Due \(date.formatted(date: .abbreviated, time: .shortened))", systemImage: "calendar")
                                    .font(.caption).foregroundStyle(!action.isComplete && date < .now ? Color.orange : .secondary)
                            }
                            if let date = action.reminderAt, !action.isComplete {
                                let delivered = controller.reminders.deliveredIDs.contains("oriv.action.\(action.id.uuidString)")
                                Label("\(delivered ? "In Notification Center ·" : date < .now ? "Reminder was" : "Remind") \(date.formatted(date: .abbreviated, time: .shortened))", systemImage: delivered ? "bell.badge" : "bell")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        Menu {
                            Button("Edit action") { actionDraft = ActionDraft(action: action) }
                            if !action.isComplete {
                                Button("Snooze reminder 1 hour") {
                                    controller.performWorkspace {
                                        try store.saveAction(itemID: item.id, actionID: action.id, title: action.title,
                                            dueAt: action.dueAt, reminderAt: .now.addingTimeInterval(3600))
                                    }
                                    controller.refreshReminders(requestPermission: true)
                                }
                            }
                        } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(inactive)
                        .accessibilityLabel("Actions for \(action.title)")
                    }.padding(.vertical, 5)
                    Divider()
                }
            }
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Notes").font(.headline); Spacer()
                    Button("Add note", systemImage: "square.and.pencil") { noteDraft = NoteDraft(note: nil) }
                        .buttonStyle(.glass).disabled(inactive)
                }
                let notes = store.currentNotes(for: item.id)
                if notes.isEmpty { Text("Keep your thoughts, decisions and updates with the source.").font(.callout).foregroundStyle(.secondary) }
                ForEach(notes) { note in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(note.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Edit") { noteDraft = NoteDraft(note: note) }.buttonStyle(.link).disabled(inactive)
                        }
                        Text(note.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.canvas, in: .rect(cornerRadius: 12))
                        .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 1).fill(Theme.thread).frame(width: 2).padding(.vertical, 16) }
                }
            }
        }
    }
    @ViewBuilder private var content: some View {
        let sources = store.sources(for: item.id)
        if sources.isEmpty {
            ContentUnavailableView("No captured content yet", systemImage: "doc.text",
                description: Text("Open the source in the browser and choose Capture Page Again from the Library menu."))
        }
        ForEach(sources) { source in
            VStack(alignment: .leading, spacing: 12) {
                Label(source.kind.rawValue, systemImage: "doc.text").font(.headline)
                Text("Saved \(source.capturedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
                Text(source.url.absoluteString).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if !source.explanation.isEmpty { Text(source.explanation).font(.callout).foregroundStyle(.secondary) }
                if !source.selection.isEmpty, source.kind != .selection {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Selected passage").font(.subheadline.weight(.medium))
                        Text(source.selection).textSelection(.enabled)
                    }.padding(14).background(.quaternary, in: .rect(cornerRadius: 10))
                }
                Text(source.text.isEmpty ? "Only the link was saved." : source.text)
                    .font(.body).lineSpacing(5).textSelection(.enabled)
            }
            Divider()
        }
    }
    private var activity: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(store.activity.filter { $0.itemID == item.id }) { event in
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 6) {
                        Circle().fill(Theme.accent).frame(width: 6, height: 6)
                        Rectangle().fill(Theme.thread).frame(width: 1)
                    }.frame(width: 12).padding(.top, 6).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(event.text)
                        Text(event.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.fixedSize(horizontal: false, vertical: true)
            }
            let allNotes = store.notes.filter { $0.itemID == item.id }
            if !allNotes.isEmpty {
                DisclosureGroup("Note history (\(allNotes.count))") {
                    ForEach(allNotes) { note in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(note.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                            Text(note.body).textSelection(.enabled)
                        }.padding(.vertical, 8)
                    }
                }
            }
        }
    }
}
