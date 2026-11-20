import BrowserEngine
import SwiftUI

/// Memory-only metadata search in an explicit privacy scope. Never reads a web view.
struct SidebarSearchPanel: View {
    @Environment(\.browserTheme) private var theme
    @Bindable var controller: BrowserController
    let dismiss: () -> Void
    @State private var results: [BrowserTab] = []
    @State private var selected = 0
    @State private var privateScope = false
    @FocusState private var focused: Bool
    private var metadata: [String] {
        controller.session.orderedTabs.map { "\($0.id)-\($0.displayTitle)-\($0.hostname)-\($0.isPrivate)" }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Search Tabs").font(.headline)
            Picker("Search scope", selection: $privateScope) {
                Text("Regular tabs").tag(false)
                Text("Private tabs").tag(true)
            }.pickerStyle(.segmented)
            TextField("Search titles and hosts", text: $controller.tabSearch)
                .textFieldStyle(.plain).focused($focused)
                .padding(8).background(theme.sidebar.field, in: .rect(cornerRadius: OrivRadius.small))
                .accessibilityIdentifier("railTabSearchField")
                .onExitCommand(perform: dismiss)
                .onSubmit { activate() }
                .onKeyPress(.downArrow) { selected = min(max(0, results.count - 1), selected + 1); return .handled }
                .onKeyPress(.upArrow) { selected = max(0, selected - 1); return .handled }
            Text("\(results.count) \(privateScope ? "private" : "regular") tabs")
                .font(.caption).foregroundStyle(theme.secondaryText).accessibilityIdentifier("tabSearchResultCount")
            resultList
        }.padding(14).foregroundStyle(theme.text)
            .background(theme.surface, in: .rect(cornerRadius: OrivRadius.popover))
            .overlay { RoundedRectangle(cornerRadius: OrivRadius.popover).stroke(theme.separator) }
            .background(SidebarHitTarget(kind: .searchPanel))
            .task {
                privateScope = controller.session.selectedTab?.isPrivate ?? controller.session.isExternalPrivate
                focused = true
            }
            .task(id: "\(controller.tabSearch)-\(privateScope)-\(metadata)") {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard !Task.isCancelled else { return }
                results = SidebarTabs.filtered(controller.session.orderedTabs.filter { $0.isPrivate == privateScope }, query: controller.tabSearch)
                selected = min(selected, max(0, results.count - 1))
            }
            .onDisappear { results = []; controller.tabSearch = "" }
    }
    private var resultList: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, tab in
                        resultRow(tab, index: index)
                    }
                }
            }.onChange(of: selected) { _, index in
                if results.indices.contains(index) { reader.scrollTo(results[index].id) }
            }
        }
    }

    private func resultRow(_ tab: BrowserTab, index: Int) -> some View {
        HStack {
            Button { controller.session.selectTab(tab.id); dismiss() } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(tab.displayTitle).lineLimit(2)
                    Text(tab.hostname).font(.caption).foregroundStyle(theme.secondaryText)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8).contentShape(Rectangle())
            }.buttonStyle(ContentButtonStyle()).accessibilityLabel(SidebarTabs.label(tab, selected: tab.id == controller.session.selectedTabID))
            Button { controller.requestCloseTab(tab.id) } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }
                .buttonStyle(ContentButtonStyle()).accessibilityLabel("Close \(tab.displayTitle)")
        }
        .background(index == selected ? theme.sidebar.selection : .clear, in: .rect(cornerRadius: OrivRadius.small))
        .id(tab.id)
    }

    private func activate() {
        guard results.indices.contains(selected) else { return }
        controller.session.selectTab(results[selected].id); dismiss()
    }
}
