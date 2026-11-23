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
        VStack(alignment: .leading, spacing: OrivSpacing.medium) {
            Text(OrivStrings.searchTabs).font(OrivType.title)
            Picker("Search scope", selection: $privateScope) {
                Text("Regular tabs").tag(false)
                Text("Private tabs").tag(true)
            }.pickerStyle(.segmented)
            OrivSearchField(text: $controller.tabSearch, focused: focused, onClear: { focused = true }) {
                TextField("Search titles and hosts", text: $controller.tabSearch)
                    .focused($focused)
                    .accessibilityIdentifier("railTabSearchField")
                    .onExitCommand(perform: dismiss)
                    .onSubmit { activate() }
                    .onKeyPress(.downArrow) { selected = min(max(0, results.count - 1), selected + 1); return .handled }
                    .onKeyPress(.upArrow) { selected = max(0, selected - 1); return .handled }
            }
            Text("\(results.count) \(privateScope ? "private" : "regular") tabs")
                .font(OrivType.caption).foregroundStyle(theme.secondaryText).accessibilityIdentifier("tabSearchResultCount")
            resultList
        }.padding(OrivSpacing.large).foregroundStyle(theme.text)
            .modifier(OrivMaterial.overlay())
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
                    Text(tab.hostname).font(OrivType.caption).foregroundStyle(theme.secondaryText)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8).contentShape(Rectangle())
            }.orivButton(.quiet).accessibilityLabel(SidebarTabs.label(tab, selected: tab.id == controller.session.selectedTabID))
                .accessibilityAddTraits(index == selected ? [.isSelected] : [])
            Button { controller.requestCloseTab(tab.id) } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }
                .orivButton(.quiet).accessibilityLabel("Close \(tab.displayTitle)")
        }
        .modifier(ListSelection(selected: index == selected, fill: theme.sidebar.selection))
        .id(tab.id)
    }

    private func activate() {
        guard results.indices.contains(selected) else { return }
        controller.session.selectTab(results[selected].id); dismiss()
    }
}
