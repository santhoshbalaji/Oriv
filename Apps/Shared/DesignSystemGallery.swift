#if DEBUG
import SwiftUI

/// A snapshot fixture for the tokens and shared components shipped in the app.
struct DesignSystemGallery: View {
    @Environment(\.browserTheme) private var baseTheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.chromeContrastOverride) private var captureContrast
    private var contrast: ColorSchemeContrast { captureContrast ?? systemContrast }
    private var theme: Theme { baseTheme.respecting(contrast) }

    enum Page: String, CaseIterable {
        case foundations, controls, rows, notices, presentations
    }

    var page = Page.foundations
    @State private var restoresTabs = true
    @State private var query = ""
    @State private var contentQuery = "Atlas"
    @State private var searches = false
    @State private var showsSheet = false
    @State private var selected = true
    @FocusState private var searchFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: OrivSpacing.large) {
                Text(page == .foundations ? "Oriv design system" : page.rawValue.capitalized)
                    .font(OrivType.windowTitle).accessibilityAddTraits(.isHeader)
                switch page {
                case .foundations:
                    palette
                    typeScale
                    Label("Private browsing", systemImage: "eyeglasses").foregroundStyle(theme.private)
                    Label("Not secure", systemImage: "exclamationmark.shield").foregroundStyle(theme.warning)
                    Label("Page unavailable", systemImage: "network.slash").foregroundStyle(theme.danger)
                    Label("Synced", systemImage: "checkmark.circle").foregroundStyle(theme.success)
                    Text("Control").padding(OrivSpacing.medium).modifier(OrivMaterial.control())
                    Text("Overlay").padding(OrivSpacing.medium).modifier(OrivMaterial.overlay())
                case .controls: controls
                case .rows: rows
                case .notices: notices
                case .presentations: presentations
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(theme.text)
            .padding(OrivSpacing.large)
        }
        .background(theme.canvas)
        #if os(iOS)
        .searchable(text: $query, isPresented: $searches, prompt: "Search bookmarks")
        #endif
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: OrivSpacing.medium) {
            let buttonLayout = buttonLayout
            buttonLayout {
                Button("Continue") {}.orivButton(.primary)
                Button("Cancel") {}.orivButton(.secondary)
                Button("Working") {}.orivButton(.secondary, busy: true)
            }
            buttonLayout {
                Button("Dismiss") {}.orivButton(.quiet)
                Button("Delete", role: .destructive) {}.orivButton(.destructive)
                Button("Show All") {}.orivButton(.link)
            }
            Button("Unavailable") {}.orivButton(.secondary).disabled(true)
            HStack(spacing: OrivSpacing.small) {
                #if os(macOS)
                ToolbarButton(label: "Back", symbol: "chevron.backward") {}.disabled(true)
                ToolbarButton(label: "Reload", symbol: "arrow.clockwise") {}
                ToolbarButton(label: "Site Privacy", symbol: "shield.lefthalf.filled", active: true) {}
                MacPageMenu { Button("New Tab") {} } label: { Image(systemName: "ellipsis").padding(OrivSpacing.small) }
                    .accessibilityLabel("Browser Actions")
                #else
                BarButton {
                    Button {} label: { BarButtonIcon(symbol: "chevron.left") }.disabled(true)
                }.accessibilityLabel("Back")
                BarButton {
                    Button {} label: { BarButtonIcon(symbol: "arrow.clockwise", secondary: true) }
                }.accessibilityLabel("Reload")
                BarButton {
                    Menu { Button("New Tab") {} } label: {
                        BarButtonIcon(symbol: "square.on.square")
                    } primaryAction: {}
                }.accessibilityLabel("Show All Tabs")
                #endif
            }
            #if os(macOS)
            OrivSearchField(text: $query, shortcut: "⇧⌘A", sidebar: true) {
                TextField("Search tabs", text: $query)
            }
            OrivSearchField(text: $contentQuery, focused: searchFocused, onClear: { searchFocused = true }) {
                TextField("Search bookmarks", text: $contentQuery).focused($searchFocused)
            }
            #endif
        }
    }

    private var buttonLayout: AnyLayout {
        if typeSize.isAccessibilitySize {
            AnyLayout(VStackLayout(alignment: .leading, spacing: OrivSpacing.small))
        } else {
            AnyLayout(HStackLayout(spacing: OrivSpacing.small))
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: OrivSpacing.medium) {
            SectionHeader(title: "Tabs", kind: .sidebar, count: 3)
            PageRowContent(title: "Atlas", url: URL(string: "https://atlas.example"),
                           isSelected: selected, accessory: .alreadyOpen)
                .padding(OrivSpacing.small).modifier(ListSelection(selected: selected))
            PageRowContent(title: "Private tab", url: nil, isPrivate: true, isLoading: true)
            PageRowContent(title: "Saved page", url: URL(string: "https://example.org"), layout: .titleOnly)
            HStack {
                Badge.alreadyOpen
                Badge(text: "Private", kind: .privateBrowsing)
                Badge(text: "3", kind: .count)
            }
            SettingRow(detail: "Private tabs are never restored.") {
                Toggle("Restore tabs", isOn: $restoresTabs)
            }
            SettingRow(detail: "Unavailable for this session.") {
                Toggle("Sync", isOn: .constant(false)).disabled(true)
            }
            SectionHeader(title: "Bookmarks", kind: .content, showAll: { selected.toggle() })
            HStack {
                Text("Atlas").modifier(Tile(kind: .site))
                Button { selected.toggle() } label: {
                    Label("System", systemImage: selected ? "checkmark.circle.fill" : "circle")
                        .padding(OrivSpacing.small)
                        .modifier(Tile(kind: .appearance(theme.surface), selected: selected))
                }.orivButton(.quiet).accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
    }

    private var notices: some View {
        VStack(alignment: .leading, spacing: OrivSpacing.small) {
            OrivBanner("Sync is on", tone: .success)
            OrivBanner("Private browsing", tone: .privateBrowsing)
            OrivBanner("Storage is unavailable", tone: .warning, dismiss: {})
            OrivBanner(message: "Bookmark removed", dismiss: {}) {
                Button("Undo") {}.orivButton(.link)
            }
            BrowserEmptyState("No bookmarks match your search.")
            PageErrorState(message: "The server couldn’t be reached.", host: "atlas.example", retry: {})
        }
    }

    private var presentations: some View {
        VStack(alignment: .leading, spacing: OrivSpacing.medium) {
            OrivSheetHeader(title: "Delete Work?", subtitle: "This can’t be undone.")
            Text("Deletes this profile’s tabs, history, bookmarks, and website data.")
                .font(OrivType.body).foregroundStyle(theme.textSecondary)
            HStack {
                Spacer()
                OrivSheetCancel(isDefault: true) {}
                Button("Delete Profile", role: .destructive) {}.orivButton(.destructive)
            }
            #if os(macOS)
            OrivPopover(title: "Site Privacy", symbol: "shield.lefthalf.filled") {
                Text("Protection for this profile").font(OrivType.detail)
                Toggle("Block trackers", isOn: .constant(true))
                Button("Reload Page") {}
            }
            #endif
            Button("Open Sheet") { showsSheet = true }.orivButton(.link)
                .sheet(isPresented: $showsSheet) {
                    OrivSheet(title: "Clear browsing data", busy: true, error: "Storage is unavailable.") {
                        Toggle("Browsing history", isOn: .constant(true)).disabled(true)
                    } actions: {
                        OrivSheetCancel { showsSheet = false }
                        Button("Clear Data", role: .destructive) {}.orivButton(.destructive).disabled(true)
                    }
                }
        }
    }

    private var palette: some View {
        HStack(spacing: OrivSpacing.small) {
            swatch("Canvas", theme.canvas)
            swatch("Surface", theme.surface)
            swatch("Raised", theme.surfaceRaised)
            swatch("Fill", theme.fill)
            swatch("Selected", theme.fillSelected)
        }
    }

    private var typeScale: some View {
        VStack(alignment: .leading, spacing: OrivSpacing.xs) {
            Text("Title").font(OrivType.title)
            Text("Headline").font(OrivType.headline)
            Text("Body · The page is the product.").font(OrivType.body)
            Text("Detail").font(OrivType.detail).foregroundStyle(theme.textSecondary)
            Text("Section label").font(OrivType.sectionLabel).foregroundStyle(theme.textSecondary)
            Text("Caption").font(OrivType.caption).foregroundStyle(theme.textTertiary)
        }
    }

    private func swatch(_ name: String, _ color: Color) -> some View {
        Text(name).font(OrivType.caption)
            .frame(maxWidth: .infinity).padding(.vertical, OrivSpacing.small)
            .background(color, in: .rect(cornerRadius: OrivRadius.control))
            .overlay {
                RoundedRectangle(cornerRadius: OrivRadius.control)
                    .strokeBorder(contrast == .increased ? theme.separatorStrong : theme.separator)
            }
    }
}
#endif
