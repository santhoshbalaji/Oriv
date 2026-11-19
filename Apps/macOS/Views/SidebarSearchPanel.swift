import BrowserEngine
import SwiftUI

/// Memory-only metadata search in an explicit privacy scope. Never reads a web view.
struct SidebarSearchPanel: View {
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
                .textFieldStyle(.plain).focused($focused).focusEffectDisabled()
                .padding(8).background(Theme.sidebar.field, in: .rect(cornerRadius: 9))
                .modifier(ChromeFocusIndicator(focused: focused, color: Theme.sidebar.accent))
                .accessibilityIdentifier("railTabSearchField")
                .onExitCommand(perform: dismiss)
                .onSubmit { activate() }
                .onKeyPress(.downArrow) { selected = min(max(0, results.count - 1), selected + 1); return .handled }
                .onKeyPress(.upArrow) { selected = max(0, selected - 1); return .handled }
            Text("\(results.count) \(privateScope ? "private" : "regular") tabs")
                .font(.caption).foregroundStyle(Theme.sidebar.secondaryText).accessibilityIdentifier("tabSearchResultCount")
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, tab in
                            HStack {
                                Button { controller.session.selectTab(tab.id); dismiss() } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(tab.displayTitle).lineLimit(2)
                                        Text(tab.hostname).font(.caption).foregroundStyle(Theme.sidebar.secondaryText)
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8).contentShape(Rectangle())
                                }.buttonStyle(ContentButtonStyle()).accessibilityLabel(SidebarTabs.label(tab, selected: tab.id == controller.session.selectedTabID))
                                Button { controller.requestCloseTab(tab.id) } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }
                                    .buttonStyle(ContentButtonStyle()).accessibilityLabel("Close \(tab.displayTitle)")
                            }
                            .background(index == selected ? Theme.sidebar.selection : .clear, in: .rect(cornerRadius: 8))
                            .id(tab.id)
                        }
                    }
                }.onChange(of: selected) { _, index in
                    if results.indices.contains(index) { reader.scrollTo(results[index].id) }
                }
            }
        }.padding(14).foregroundStyle(Theme.sidebar.text)
            .environment(\.browserTheme, Theme.sidebar).focusEffectDisabled()
            .background(Theme.sidebar.surface, in: .rect(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).stroke(Theme.sidebar.separator) }
            .browserGeometryMarker("sidebarSearchPanel")
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
    private func activate() {
        guard results.indices.contains(selected) else { return }
        controller.session.selectTab(results[selected].id); dismiss()
    }
}
