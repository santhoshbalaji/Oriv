import BrowserEngine
import SwiftUI

struct SidebarSearchPanel: View {
    @Environment(\.browserTheme) private var theme
    @Environment(\.self) private var environment
    @Bindable var controller: BrowserController
    let dismiss: () -> Void
    @State private var highlighted: UUID?
    @FocusState private var focused: Bool

    var body: some View {
        let request = controller.tabSearchRequest
        let results = controller.tabSearchResults(request)
        let selected = results.first(where: { $0.id == highlighted }) ?? results.first
        VStack(alignment: .leading, spacing: OrivSpacing.medium) {
            Text(OrivStrings.searchTabs).font(OrivType.title)
            SidebarSearchScope(controller: controller)
            OrivSearchField(text: $controller.tabSearch, focused: focused, onClear: { focused = true }) {
                TextField("Search titles and hosts", text: $controller.tabSearch)
                    .focused($focused)
                    .accessibilityIdentifier("railTabSearchField")
                    .onExitCommand(perform: dismiss)
                    .onSubmit { if let selected { activate(selected.id, request: request) } }
                    .onKeyPress(.downArrow) { moveHighlight(1, in: results); return .handled }
                    .onKeyPress(.upArrow) { moveHighlight(-1, in: results); return .handled }
            }
            Text(SidebarTabs.countLabel(results.count))
                .font(OrivType.caption).foregroundStyle(theme.textSecondary).accessibilityIdentifier("tabSearchResultCount")
            if results.isEmpty {
                BrowserEmptyState("No matching tabs").frame(maxHeight: .infinity)
            } else {
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(spacing: OrivSpacing.xs) {
                            ForEach(results) { tab in
                                resultRow(tab, selected: tab.id == selected?.id, request: request)
                                    .id(tab.id)
                            }
                        }
                    }
                    .onChange(of: highlighted) { _, id in
                        if let id { reader.scrollTo(id) }
                    }
                }
            }
        }
        .padding(OrivSpacing.large)
        .foregroundStyle(theme.text)
        .modifier(OrivMaterial.overlay())
        .background(SidebarHitTarget(kind: .searchPanel))
        .task { focused = true }
        .onChange(of: request) { _, _ in highlighted = nil }
    }

    private func resultRow(_ tab: BrowserTab, selected: Bool, request: ProfileScoped<SidebarTabQuery>) -> some View {
        let active = tab.id == controller.session.selectedTabID
        let radius = OrivLayout.sidebarSelectionRadius
        let ink = active && environment.sidebarUsesTintedSelection ? Theme.SidebarSelection.ink(in: theme, dark: environment.colorScheme == .dark,
                                                      environment: environment) : nil
        return Button { activate(tab.id, request: request) } label: {
            HStack(spacing: OrivSpacing.small) {
                SiteIdentity(url: tab.url, size: OrivIcon.footer, isPrivate: tab.isPrivate,
                             isSelected: active, sidebarIcon: true, sidebarSelectedInk: ink)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: OrivSpacing.xxs) {
                    Text(tab.displayTitle).font(active ? OrivType.headline : OrivType.body).lineLimit(1)
                    Text(tab.hostname).font(OrivType.caption)
                        .foregroundStyle(ink ?? (active ? theme.sidebarSecondaryText(environment.sidebarContrast) : theme.textSecondary))
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(OrivSpacing.small).contentShape(Rectangle())
                .foregroundStyle(ink ?? theme.text)
        }
        .buttonStyle(SidebarToneButtonStyle(active: active))
        .accessibilityLabel(SidebarTabs.label(tab, selected: active))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .modifier(SidebarSelectionSurface(active: active, radius: radius))
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: radius - OrivOutline.focusInset)
                    .strokeBorder(Theme.sidebarKeyboardFocus, lineWidth: OrivOutline.focus)
                    .padding(OrivOutline.focusInset - OrivOutline.focus / 2)
                    .allowsHitTesting(false)
            }
        }
    }

    private func moveHighlight(_ offset: Int, in results: [BrowserTab]) {
        guard !results.isEmpty else { return }
        let index = results.firstIndex { $0.id == highlighted } ?? 0
        highlighted = results[min(results.count - 1, max(0, index + offset))].id
    }

    private func activate(_ id: UUID, request: ProfileScoped<SidebarTabQuery>) {
        if controller.activateSidebarTab(id, request: request) { dismiss() }
    }
}
