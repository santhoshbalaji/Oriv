#if DEBUG
import BrowserCore
import SwiftUI

/// A snapshot fixture for the tokens and shared components shipped in the app.
struct DesignSystemGallery: View {
    @Environment(\.browserTheme) private var baseTheme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.chromeContrastOverride) private var captureContrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.chromeReduceTransparencyOverride) private var captureReduceTransparency
    private var contrast: ColorSchemeContrast { captureContrast ?? systemContrast }
    private var theme: Theme { baseTheme.respecting(contrast) }

    enum Page: String, CaseIterable {
        case foundations, controls, rows, notices, presentations
        #if os(macOS)
        case designV3 = "design-v3"
        #endif
    }

    var page = Page.foundations
    #if os(macOS)
    var scrollable = true
    #endif
    @State private var restoresTabs = true
    @State private var query = ""
    @State private var contentQuery = "Atlas"
    @State private var searches = false
    @State private var showsSheet = false
    @State private var selected = true
    @FocusState private var searchFocused: Bool

    @ViewBuilder var body: some View {
        #if os(iOS)
        if page == .controls {
            galleryContent.searchable(text: $query, isPresented: $searches, prompt: "Search bookmarks")
        } else {
            galleryContent
        }
        #else
        galleryContent
        #endif
    }

    @ViewBuilder private var galleryContent: some View {
        #if os(macOS)
        if scrollable {
            ScrollView { galleryStack }.background(theme.canvas)
        } else {
            galleryStack
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(theme.canvas)
        }
        #else
        ScrollView { galleryStack }.background(theme.canvas)
        #endif
    }

    private var galleryStack: some View {
        VStack(alignment: .leading, spacing: OrivSpacing.large) {
            Text(pageTitle)
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
            #if os(macOS)
            case .designV3: designV3
            #endif
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(theme.text)
        .padding(OrivSpacing.large)
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
            OrivSearchField(text: $contentQuery, focused: true, onClear: { searchFocused = true }) {
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

    private var pageTitle: String {
        #if os(macOS)
        if page == .designV3 { return "Design v3" }
        #endif
        return page == .foundations ? "Oriv design system" : page.rawValue.capitalized
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

    #if os(macOS)
    private var v3Mode: OrivMacV3.AppearanceMode {
        OrivMacV3.AppearanceMode.resolve(theme: baseTheme, colorScheme: colorScheme)
    }

    private var v3Reduced: Bool {
        reduceTransparency || captureReduceTransparency || contrast == .increased
    }

    private var v3Increased: Bool {
        contrast == .increased
    }

    private var designV3: some View {
        VStack(alignment: .leading, spacing: OrivSpacing.large) {
            v3BackdropsSection
            HStack(alignment: .top, spacing: OrivSpacing.large) {
                v3SidebarSample(mode: v3Mode)
                v3SidebarSample(mode: .private)
                VStack(alignment: .leading, spacing: OrivSpacing.medium) {
                    v3ToolbarAndAddressSection(mode: v3Mode)
                    v3SuggestionsSection(mode: v3Mode)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            v3StartPageSection(mode: v3Mode)
        }
    }

    private var v3BackdropsSection: some View {
        VStack(alignment: .leading, spacing: OrivSpacing.small) {
            Text("Backdrops (Window & Start Page)")
                .font(OrivMacV3.Typography.sectionLabel)
                .foregroundStyle(OrivMacV3.Ink.secondary(v3Mode, increasedContrast: v3Increased))
            HStack(spacing: OrivSpacing.small) {
                v3BackdropSwatch(title: "Light", mode: .light, startPage: false)
                v3BackdropSwatch(title: "Dark", mode: .dark, startPage: false)
                v3BackdropSwatch(title: "Black", mode: .black, startPage: false)
                v3BackdropSwatch(title: "Private", mode: .private, startPage: false)
                v3BackdropSwatch(title: "Start Light", mode: .light, startPage: true)
                v3BackdropSwatch(title: "Start Dark", mode: .dark, startPage: true)
                v3BackdropSwatch(title: "Start Private", mode: .private, startPage: true)
            }
        }
    }

    private func v3BackdropSwatch(title: String, mode: OrivMacV3.AppearanceMode, startPage: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: OrivMacV3.Radius.row, style: .continuous)
        return ZStack(alignment: .bottomLeading) {
            OrivMacV3.Backdrop.BackdropView(mode: mode, startPage: startPage, profileColor: .mulberry, reduced: v3Reduced)
            Text(title)
                .font(OrivMacV3.Typography.sectionLabel)
                .foregroundStyle(OrivMacV3.Ink.primary(mode))
                .padding(.horizontal, OrivSpacing.small)
                .padding(.vertical, OrivSpacing.xs)
        }
        .frame(maxWidth: .infinity)
        .frame(height: OrivMacV3.StartLayout.bookmarkIconSize)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(OrivMacV3.Card.rim(mode, increasedContrast: v3Increased),
                               lineWidth: v3Increased ? OrivOutline.enhanced : OrivOutline.hairline)
        }
    }

    private func v3SidebarSample(mode: OrivMacV3.AppearanceMode) -> some View {
        let cardShape = RoundedRectangle(cornerRadius: OrivMacV3.Radius.sidebar, style: .continuous)
        let recipe = OrivMacV3.Sidebar.chromaticSwatches(color: .graphite, profile: .mulberry, mode: mode)
        let isPrivate = mode == .private
        let primary = OrivMacV3.Ink.primary(mode)
        let secondary = OrivMacV3.Ink.secondary(mode, increasedContrast: v3Increased)
        let tertiary = OrivMacV3.Ink.tertiary(mode, onSidebar: true, increasedContrast: v3Increased)
        return ZStack {
            OrivMacV3.Backdrop.BackdropView(mode: mode, startPage: false, reduced: v3Reduced)
            VStack(alignment: .leading, spacing: OrivSpacing.xs) {
                HStack {
                    HStack(spacing: OrivMacV3.SidebarLayout.lightGap) {
                        Circle().fill(OrivMacV3.Sidebar.trafficLightClose)
                            .frame(width: OrivMacV3.SidebarLayout.lightDiameter, height: OrivMacV3.SidebarLayout.lightDiameter)
                        Circle().fill(OrivMacV3.Sidebar.trafficLightMinimize)
                            .frame(width: OrivMacV3.SidebarLayout.lightDiameter, height: OrivMacV3.SidebarLayout.lightDiameter)
                        Circle().fill(OrivMacV3.Sidebar.trafficLightZoom)
                            .frame(width: OrivMacV3.SidebarLayout.lightDiameter, height: OrivMacV3.SidebarLayout.lightDiameter)
                    }
                    Spacer()
                    Image(systemName: "sidebar.leading")
                        .font(OrivMacV3.Typography.detail)
                        .foregroundStyle(secondary)
                        .frame(width: OrivMacV3.SidebarLayout.toggleSize, height: OrivMacV3.SidebarLayout.toggleSize)
                        .orivV3Glass(OrivMacV3.Sidebar.toggleRecipe(mode),
                                     in: RoundedRectangle(cornerRadius: OrivMacV3.Radius.control, style: .continuous),
                                     forceSolid: true)
                }
                .frame(height: OrivMacV3.SidebarLayout.titlebarHeight)
                .padding(.horizontal, OrivSpacing.xs)

                HStack(spacing: OrivSpacing.small) {
                    ZStack {
                        RoundedRectangle(cornerRadius: OrivMacV3.Radius.profileAvatar, style: .continuous)
                            .fill(OrivMacV3.Sidebar.profileAvatarBg(mode, profile: .mulberry))
                        Image(systemName: isPrivate ? "eyeglasses" : "person.fill")
                            .font(OrivMacV3.Typography.sectionLabel)
                            .foregroundStyle(OrivMacV3.Sidebar.profileAvatarInk(mode, profile: .mulberry))
                    }
                    .frame(width: OrivMacV3.SidebarLayout.profileAvatarSize, height: OrivMacV3.SidebarLayout.profileAvatarSize)
                    Text(isPrivate ? "Private" : "Personal")
                        .font(OrivMacV3.Typography.sidebarProfile)
                        .foregroundStyle(primary)
                    Spacer()
                    if !isPrivate {
                        Image(systemName: "chevron.up.chevron.down")
                            .font(OrivMacV3.Typography.shortcutHint)
                            .foregroundStyle(tertiary)
                    }
                }
                .frame(height: OrivMacV3.SidebarLayout.profileHeight)
                .padding(.horizontal, OrivMacV3.SidebarLayout.tabRowPaddingHorizontal)

                HStack(spacing: OrivMacV3.SidebarLayout.searchInnerGap) {
                    Image(systemName: "magnifyingglass")
                        .font(OrivMacV3.Typography.detail)
                        .foregroundStyle(secondary)
                    Text(isPrivate ? "Search private tabs" : "Search tabs")
                        .font(OrivMacV3.Typography.detail)
                        .foregroundStyle(secondary)
                    Spacer()
                    Text("⇧⌘A")
                        .font(OrivMacV3.Typography.shortcutHint)
                        .foregroundStyle(tertiary)
                }
                .padding(.horizontal, OrivMacV3.SidebarLayout.searchPaddingHorizontal)
                .frame(height: OrivMacV3.SidebarLayout.searchHeight)
                .background(OrivMacV3.Sidebar.searchFill(mode, solid: true),
                            in: RoundedRectangle(cornerRadius: OrivMacV3.Radius.sidebarSearch, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: OrivMacV3.Radius.sidebarSearch, style: .continuous)
                        .strokeBorder(v3Increased ? OrivMacV3.Card.rimIncreasedContrast(mode) : OrivMacV3.Sidebar.searchInnerRim(mode),
                                      lineWidth: v3Increased ? OrivOutline.enhanced : OrivOutline.hairline)
                }

                if !isPrivate {
                    HStack {
                        Text("Pinned").font(OrivMacV3.Typography.sectionLabel).foregroundStyle(secondary)
                        Spacer()
                        Text("4").font(OrivMacV3.Typography.sectionCount).foregroundStyle(tertiary)
                    }
                    .frame(height: OrivMacV3.SidebarLayout.sectionHeight)
                    .padding(.horizontal, OrivMacV3.SidebarLayout.sectionPaddingHorizontal)

                    HStack(spacing: OrivMacV3.SidebarLayout.pinGap) {
                        ForEach(["chevron.left.forwardslash.chevron.right", "apple.logo", "globe", "book.closed"], id: \.self) { symbol in
                            let pinShape = RoundedRectangle(cornerRadius: OrivMacV3.Radius.row, style: .continuous)
                            Image(systemName: symbol)
                                .font(OrivMacV3.Typography.detailSemibold)
                                .foregroundStyle(primary)
                                .frame(maxWidth: .infinity)
                                .frame(height: OrivMacV3.SidebarLayout.pinHeight)
                                .background(OrivMacV3.Sidebar.pinFill(mode, solid: true), in: pinShape)
                                .overlay {
                                    pinShape.strokeBorder(OrivMacV3.Sidebar.pinBorder(mode, increasedContrast: v3Increased),
                                                          lineWidth: v3Increased ? OrivOutline.enhanced : OrivOutline.hairline)
                                }
                                .orivV3Shadow(OrivMacV3.Sidebar.pinShadow(mode))
                        }
                    }
                }

                HStack {
                    Text(isPrivate ? "Private" : "Tabs")
                        .font(OrivMacV3.Typography.sectionLabel)
                        .foregroundStyle(isPrivate ? OrivMacV3.Semantic.privateAccent(mode, increasedContrast: v3Increased) : secondary)
                    Spacer()
                    Text(isPrivate ? "2" : "4").font(OrivMacV3.Typography.sectionCount).foregroundStyle(tertiary)
                }
                .frame(height: OrivMacV3.SidebarLayout.sectionHeight)
                .padding(.horizontal, OrivMacV3.SidebarLayout.sectionPaddingHorizontal)

                let activeRowShape = RoundedRectangle(cornerRadius: OrivMacV3.Radius.row, style: .continuous)
                HStack(spacing: OrivMacV3.SidebarLayout.tabRowInnerGap) {
                    Image(systemName: isPrivate ? "eyeglasses" : "doc.text.fill")
                        .font(OrivMacV3.Typography.detail)
                        .foregroundStyle(OrivMacV3.Sidebar.activeInk(mode))
                        .frame(width: OrivMacV3.SidebarLayout.tabFaviconSize, height: OrivMacV3.SidebarLayout.tabFaviconSize)
                    Text(isPrivate ? "Private Browsing" : "Designing calm interfaces")
                        .font(OrivMacV3.Typography.sidebarRowActive)
                        .foregroundStyle(OrivMacV3.Sidebar.activeInk(mode))
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "xmark")
                        .font(OrivMacV3.Typography.shortcutHint)
                        .foregroundStyle(OrivMacV3.Sidebar.activeInk(mode))
                }
                .padding(.horizontal, OrivMacV3.SidebarLayout.tabRowPaddingHorizontal)
                .frame(height: OrivMacV3.SidebarLayout.tabRowHeight)
                .background(OrivMacV3.Sidebar.activeFill(mode, solid: true), in: activeRowShape)
                .overlay {
                    activeRowShape.strokeBorder(OrivMacV3.Sidebar.activeBorder(mode, increasedContrast: v3Increased),
                                                lineWidth: v3Increased ? OrivOutline.focus : OrivOutline.hairline)
                }
                .orivV3Shadow(OrivMacV3.Sidebar.activeShadow(mode))

                HStack(spacing: OrivMacV3.SidebarLayout.tabRowInnerGap) {
                    Image(systemName: isPrivate ? "eyeglasses" : "waveform")
                        .font(OrivMacV3.Typography.detail)
                        .foregroundStyle(isPrivate ? OrivMacV3.Semantic.privateAccent(mode) : secondary)
                        .frame(width: OrivMacV3.SidebarLayout.tabFaviconSize, height: OrivMacV3.SidebarLayout.tabFaviconSize)
                    Text(isPrivate ? "fixture.example" : "Floating Points — Live")
                        .font(OrivMacV3.Typography.sidebarRow)
                        .foregroundStyle(primary)
                        .lineLimit(1)
                    Spacer()
                    if !isPrivate {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(OrivMacV3.Typography.detail)
                            .foregroundStyle(OrivMacV3.Sidebar.audioInk(mode))
                    }
                }
                .padding(.horizontal, OrivMacV3.SidebarLayout.tabRowPaddingHorizontal)
                .frame(height: OrivMacV3.SidebarLayout.tabRowHeight)

                HStack(spacing: OrivMacV3.SidebarLayout.tabRowInnerGap) {
                    Image(systemName: "plus")
                        .font(OrivMacV3.Typography.detail)
                        .foregroundStyle(secondary)
                        .frame(width: OrivMacV3.SidebarLayout.tabFaviconSize, height: OrivMacV3.SidebarLayout.tabFaviconSize)
                    Text(isPrivate ? "New Private Tab" : "New Tab")
                        .font(OrivMacV3.Typography.sidebarNewTab)
                        .foregroundStyle(secondary)
                    Spacer()
                    Text("⌘T").font(OrivMacV3.Typography.shortcutHint).foregroundStyle(tertiary)
                }
                .padding(.horizontal, OrivMacV3.SidebarLayout.tabRowPaddingHorizontal)
                .frame(height: OrivMacV3.SidebarLayout.newTabHeight)

                Spacer(minLength: OrivSpacing.small)

                if !isPrivate {
                    HStack(spacing: OrivMacV3.SidebarLayout.profileDotGap) {
                        ForEach([ProfileColor.mulberry, .ocean, .fern], id: \.self) { profile in
                            Circle().fill(OrivMacV3.Sidebar.profileDotColor(profile))
                                .frame(width: OrivMacV3.SidebarLayout.profileDotSize, height: OrivMacV3.SidebarLayout.profileDotSize)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, OrivSpacing.xs)
                }

                Rectangle()
                    .fill(OrivMacV3.Sidebar.footerSeparator(mode, increasedContrast: v3Increased))
                    .frame(height: v3Increased ? OrivOutline.enhanced : OrivOutline.hairline)

                HStack(spacing: OrivMacV3.SidebarLayout.footerGap) {
                    ForEach(["book", "clock", "arrow.down.circle", "laptopcomputer.and.iphone"], id: \.self) { icon in
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: icon)
                                .font(OrivMacV3.Typography.detail)
                                .foregroundStyle(secondary)
                                .frame(width: OrivMacV3.SidebarLayout.footerButtonSize, height: OrivMacV3.SidebarLayout.footerButtonSize)
                            if icon == "arrow.down.circle" && !isPrivate {
                                Circle().fill(OrivMacV3.Semantic.accent(mode))
                                    .frame(width: OrivMacV3.SidebarLayout.downloadDotSize, height: OrivMacV3.SidebarLayout.downloadDotSize)
                                    .overlay { Circle().stroke(OrivMacV3.Sidebar.downloadDotRing(mode), lineWidth: OrivOutline.enhanced) }
                                    .padding(OrivSpacing.xs)
                            }
                        }
                    }
                    Spacer()
                    Image(systemName: "gearshape")
                        .font(OrivMacV3.Typography.detail)
                        .foregroundStyle(secondary)
                        .frame(width: OrivMacV3.SidebarLayout.footerButtonSize, height: OrivMacV3.SidebarLayout.footerButtonSize)
                }
                .frame(height: OrivMacV3.SidebarLayout.footerHeight)
            }
            .padding(.horizontal, OrivMacV3.SidebarLayout.innerPaddingHorizontal)
            .padding(.bottom, OrivMacV3.SidebarLayout.innerPaddingBottom)
            .orivV3Glass(recipe, in: cardShape, forceSolid: true)
            .orivV3Shadow(OrivMacV3.Sidebar.elevation(mode))
            .padding(OrivMacV3.Frame.windowInset)
        }
        .frame(width: OrivMacV3.SidebarLayout.width + OrivSpacing.large, height: OrivMacV3.ToolbarLayout.addressRestWidth)
        .clipShape(RoundedRectangle(cornerRadius: OrivMacV3.Radius.sidebar, style: .continuous))
    }

    private func v3ToolbarAndAddressSection(mode: OrivMacV3.AppearanceMode) -> some View {
        let cardShape = RoundedRectangle(cornerRadius: OrivMacV3.Radius.pageCard, style: .continuous)
        let primary = OrivMacV3.Ink.primary(mode)
        let secondary = OrivMacV3.Ink.secondary(mode, increasedContrast: v3Increased)
        let tertiary = OrivMacV3.Ink.tertiary(mode, onSidebar: false, increasedContrast: v3Increased)
        return VStack(alignment: .leading, spacing: OrivSpacing.small) {
            Text("Toolbar Pills & Address Capsule (Rest + Focused)")
                .font(OrivMacV3.Typography.sectionLabel)
                .foregroundStyle(secondary)

            VStack(spacing: OrivSpacing.medium) {
                HStack(spacing: OrivSpacing.small) {
                    v3ToolbarLeadingPill(mode: mode)
                    Spacer(minLength: OrivSpacing.xs)
                    v3AddressRestCapsule(mode: mode, showProgress: mode == .dark)
                    Spacer(minLength: OrivSpacing.xs)
                    v3ToolbarTrailingPill(mode: mode)
                }

                // Focused address capsule with concentric halo & inline completion
                HStack(spacing: OrivMacV3.ToolbarLayout.addressFocusGap) {
                    Image(systemName: "magnifyingglass")
                        .font(OrivMacV3.Typography.detailSemibold)
                        .foregroundStyle(OrivMacV3.Focus.addressRing(mode, increasedContrast: v3Increased))
                    HStack(spacing: OrivSpacing.xxs) {
                        Text("dev")
                            .font(OrivMacV3.Typography.addressFocusedTyped)
                            .foregroundStyle(primary)
                        Text("eloper.apple.com")
                            .font(OrivMacV3.Typography.addressFocused)
                            .foregroundStyle(OrivMacV3.Address.inlineCompletionInk(mode))
                            .padding(.horizontal, OrivSpacing.xs)
                            .background(OrivMacV3.Address.inlineCompletionBg(mode),
                                        in: RoundedRectangle(cornerRadius: OrivMacV3.Radius.tabHint, style: .continuous))
                        Text("/documentation/")
                            .font(OrivMacV3.Typography.addressFocused)
                            .foregroundStyle(tertiary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text("Tab")
                        .font(OrivMacV3.Typography.shortcutHintBold)
                        .foregroundStyle(secondary)
                        .padding(.horizontal, OrivSpacing.xs)
                        .padding(.vertical, OrivSpacing.xxs)
                        .background(OrivMacV3.Address.tabHintFill(mode),
                                    in: RoundedRectangle(cornerRadius: OrivMacV3.Radius.tabHint, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: OrivMacV3.Radius.tabHint, style: .continuous)
                                .strokeBorder(OrivMacV3.Address.tabHintBorder(mode), lineWidth: OrivOutline.hairline)
                        }
                    Image(systemName: "xmark.circle.fill")
                        .font(OrivMacV3.Typography.detail)
                        .foregroundStyle(tertiary)
                }
                .padding(.leading, OrivMacV3.ToolbarLayout.addressFocusLeadingPadding)
                .padding(.trailing, OrivMacV3.ToolbarLayout.addressFocusTrailingPadding)
                .frame(height: OrivMacV3.ToolbarLayout.addressFocusHeight)
                .orivV3Glass(OrivMacV3.Address.focusFill(mode), in: OrivMacV3.Radius.capsule, forceSolid: true)
                .background {
                    if !v3Increased {
                        OrivMacV3.Radius.capsule
                            .stroke(OrivMacV3.Address.focusHalo(mode), lineWidth: OrivMacV3.Focus.addressHaloWidth + OrivMacV3.Focus.addressHaloWidth)
                    }
                }
                .orivV3Shadow(OrivMacV3.Address.focusShadow(mode))
            }
            .padding(OrivSpacing.medium)
            .background(OrivMacV3.Card.fill(mode), in: cardShape)
            .overlay {
                cardShape.strokeBorder(OrivMacV3.Card.rim(mode, increasedContrast: v3Increased),
                                       lineWidth: v3Increased ? OrivOutline.enhanced : OrivOutline.hairline)
            }
            .orivV3Shadow(OrivMacV3.Card.elevation(mode))
        }
    }

    private func v3ToolbarLeadingPill(mode: OrivMacV3.AppearanceMode) -> some View {
        let primary = OrivMacV3.Ink.primary(mode)
        return HStack(spacing: OrivMacV3.ToolbarLayout.groupGap) {
            Image(systemName: "chevron.backward")
                .font(OrivMacV3.Typography.detailSemibold)
                .foregroundStyle(primary)
                .frame(width: OrivMacV3.ToolbarLayout.buttonSize, height: OrivMacV3.ToolbarLayout.buttonSize)
            Rectangle()
                .fill(OrivMacV3.Toolbar.divider(mode, increasedContrast: v3Increased))
                .frame(width: OrivMacV3.ToolbarLayout.dividerSize.width, height: OrivMacV3.ToolbarLayout.dividerSize.height)
            Image(systemName: "chevron.forward")
                .font(OrivMacV3.Typography.detailSemibold)
                .foregroundStyle(primary)
                .opacity(OrivMacV3.Toolbar.disabledOpacity(mode, increasedContrast: v3Increased))
                .frame(width: OrivMacV3.ToolbarLayout.buttonSize, height: OrivMacV3.ToolbarLayout.buttonSize)
        }
        .padding(OrivMacV3.ToolbarLayout.groupPadding)
        .frame(height: OrivMacV3.ToolbarLayout.groupHeight)
        .orivV3Glass(OrivMacV3.Toolbar.groupTint(mode), in: OrivMacV3.Radius.capsule, forceSolid: true)
        .orivV3Shadow(OrivMacV3.Toolbar.groupShadow(mode))
    }

    private func v3ToolbarTrailingPill(mode: OrivMacV3.AppearanceMode) -> some View {
        let primary = OrivMacV3.Ink.primary(mode)
        return HStack(spacing: OrivMacV3.ToolbarLayout.groupGap) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(OrivMacV3.Typography.detailSemibold)
                    .foregroundStyle(primary)
                    .frame(width: OrivMacV3.ToolbarLayout.buttonSize, height: OrivMacV3.ToolbarLayout.buttonSize)
                Circle()
                    .fill(OrivMacV3.Toolbar.shieldDot(mode))
                    .frame(width: OrivMacV3.ToolbarLayout.shieldDotSize, height: OrivMacV3.ToolbarLayout.shieldDotSize)
                    .overlay { Circle().stroke(OrivMacV3.Toolbar.shieldDotRing(mode), lineWidth: OrivOutline.enhanced) }
                    .padding(OrivMacV3.ToolbarLayout.shieldDotInset)
            }
            Image(systemName: "square.and.arrow.up")
                .font(OrivMacV3.Typography.detailSemibold)
                .foregroundStyle(primary)
                .frame(width: OrivMacV3.ToolbarLayout.buttonSize, height: OrivMacV3.ToolbarLayout.buttonSize)
            Image(systemName: "ellipsis")
                .font(OrivMacV3.Typography.detailSemibold)
                .foregroundStyle(primary)
                .frame(width: OrivMacV3.ToolbarLayout.buttonSize, height: OrivMacV3.ToolbarLayout.buttonSize)
        }
        .padding(OrivMacV3.ToolbarLayout.groupPadding)
        .frame(height: OrivMacV3.ToolbarLayout.groupHeight)
        .orivV3Glass(OrivMacV3.Toolbar.groupTint(mode), in: OrivMacV3.Radius.capsule, forceSolid: true)
        .orivV3Shadow(OrivMacV3.Toolbar.groupShadow(mode))
    }

    private func v3AddressRestCapsule(mode: OrivMacV3.AppearanceMode, showProgress: Bool) -> some View {
        let primary = OrivMacV3.Ink.primary(mode)
        let secondary = OrivMacV3.Ink.secondary(mode, increasedContrast: v3Increased)
        return HStack {
            Image(systemName: "lock.fill")
                .font(OrivMacV3.Typography.shortcutHint)
                .foregroundStyle(secondary)
                .frame(width: OrivMacV3.ToolbarLayout.addressInlineIconSize, height: OrivMacV3.ToolbarLayout.addressInlineIconSize)
            Spacer()
            Text("docs.example.com")
                .font(OrivMacV3.Typography.addressRest)
                .foregroundStyle(primary)
                .lineLimit(1)
            Spacer()
            Image(systemName: "arrow.clockwise")
                .font(OrivMacV3.Typography.shortcutHint)
                .foregroundStyle(secondary)
                .frame(width: OrivMacV3.ToolbarLayout.addressInlineIconSize, height: OrivMacV3.ToolbarLayout.addressInlineIconSize)
        }
        .padding(.horizontal, OrivMacV3.ToolbarLayout.addressRestPaddingHorizontal)
        .frame(maxWidth: .infinity)
        .frame(height: OrivMacV3.ToolbarLayout.addressRestHeight)
        .orivV3Glass(OrivMacV3.Address.restFill(mode), in: OrivMacV3.Radius.capsule, forceSolid: true)
        .overlay(alignment: .bottomLeading) {
            if showProgress {
                Capsule()
                    .fill(OrivMacV3.Address.progressBar(mode))
                    .frame(width: OrivMacV3.ToolbarLayout.addressMinWidth, height: OrivMacV3.ToolbarLayout.progressHeight)
                    .padding(.horizontal, OrivMacV3.ToolbarLayout.progressHorizontalInset)
                    .orivV3Shadow(OrivMacV3.Address.progressGlow(mode))
            }
        }
        .clipShape(OrivMacV3.Radius.capsule)
        .orivV3Shadow(OrivMacV3.Address.restShadow(mode))
    }

    private func v3SuggestionsSection(mode: OrivMacV3.AppearanceMode) -> some View {
        let popoverShape = RoundedRectangle(cornerRadius: OrivMacV3.Radius.sidebar, style: .continuous)
        let rowShape = RoundedRectangle(cornerRadius: OrivMacV3.Radius.row, style: .continuous)
        let primary = OrivMacV3.Ink.primary(mode)
        let secondary = OrivMacV3.Ink.secondary(mode, increasedContrast: v3Increased)
        let tertiary = OrivMacV3.Ink.tertiary(mode, onSidebar: false, increasedContrast: v3Increased)
        return VStack(alignment: .leading, spacing: OrivSpacing.small) {
            Text("Suggestions Popover (Selected Row & Chips)")
                .font(OrivMacV3.Typography.sectionLabel)
                .foregroundStyle(secondary)

            VStack(alignment: .leading, spacing: OrivSpacing.xs) {
                Text("Switch to Tab")
                    .font(OrivMacV3.Typography.sectionLabel)
                    .foregroundStyle(tertiary)
                    .padding(.horizontal, OrivMacV3.ToolbarLayout.suggestionRowPaddingHorizontal)
                    .padding(.top, OrivSpacing.xs)

                HStack(spacing: OrivMacV3.ToolbarLayout.suggestionRowGap) {
                    RoundedRectangle(cornerRadius: OrivMacV3.Radius.profileAvatar, style: .continuous)
                        .fill(OrivMacV3.StartPage.sampleAppIconGradient(0))
                        .frame(width: OrivMacV3.ToolbarLayout.suggestionIconSize, height: OrivMacV3.ToolbarLayout.suggestionIconSize)
                        .overlay { Image(systemName: "apple.logo").font(OrivMacV3.Typography.detailSemibold).foregroundStyle(OrivMacV3.StartPage.appIconOnColor) }
                    VStack(alignment: .leading, spacing: OrivSpacing.xxs) {
                        Text("Apple Developer Documentation").font(OrivMacV3.Typography.sidebarRow).foregroundStyle(primary).lineLimit(1)
                        Text("developer.apple.com/documentation/swiftui").font(OrivMacV3.Typography.suggestionURL).foregroundStyle(secondary).lineLimit(1)
                    }
                    Spacer()
                    Text("Already open")
                        .font(OrivMacV3.Typography.shortcutHintBold)
                        .foregroundStyle(OrivMacV3.Suggestions.alreadyOpenPillInk(mode))
                        .padding(.horizontal, OrivSpacing.small)
                        .padding(.vertical, OrivSpacing.xs)
                        .background(OrivMacV3.Suggestions.alreadyOpenPillFill(mode), in: OrivMacV3.Radius.capsule)
                        .overlay { OrivMacV3.Radius.capsule.strokeBorder(OrivMacV3.Suggestions.alreadyOpenPillBorder(mode), lineWidth: OrivOutline.hairline) }
                }
                .padding(.horizontal, OrivMacV3.ToolbarLayout.suggestionRowPaddingHorizontal)
                .frame(height: OrivMacV3.ToolbarLayout.suggestionRowHeight)

                Text("Bookmarks")
                    .font(OrivMacV3.Typography.sectionLabel)
                    .foregroundStyle(tertiary)
                    .padding(.horizontal, OrivMacV3.ToolbarLayout.suggestionRowPaddingHorizontal)

                HStack(spacing: OrivMacV3.ToolbarLayout.suggestionRowGap) {
                    RoundedRectangle(cornerRadius: OrivMacV3.Radius.profileAvatar, style: .continuous)
                        .fill(OrivMacV3.StartPage.sampleAppIconGradient(3))
                        .frame(width: OrivMacV3.ToolbarLayout.suggestionIconSize, height: OrivMacV3.ToolbarLayout.suggestionIconSize)
                        .overlay { Text("M").font(OrivMacV3.Typography.detailSemibold).foregroundStyle(OrivMacV3.StartPage.appIconOnColor) }
                    VStack(alignment: .leading, spacing: OrivSpacing.xxs) {
                        Text("MDN Web Docs — CSS backdrop-filter")
                            .font(OrivMacV3.Typography.sidebarRowActive)
                            .foregroundStyle(OrivMacV3.Suggestions.selectedTitleInk(mode))
                            .lineLimit(1)
                        Text("developer.mozilla.org/en-US/docs/Web/CSS/backdrop-filter")
                            .font(OrivMacV3.Typography.suggestionURL)
                            .foregroundStyle(OrivMacV3.Suggestions.selectedURLInk(mode))
                            .lineLimit(1)
                    }
                    Spacer()
                    Text("↵")
                        .font(OrivMacV3.Typography.sectionLabel)
                        .foregroundStyle(OrivMacV3.Suggestions.returnKeyChipInk(mode))
                        .padding(.horizontal, OrivSpacing.small)
                        .padding(.vertical, OrivSpacing.xxs)
                        .background(OrivMacV3.Suggestions.returnKeyChipFill(mode),
                                    in: RoundedRectangle(cornerRadius: OrivMacV3.Radius.accessory, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: OrivMacV3.Radius.accessory, style: .continuous)
                                .strokeBorder(OrivMacV3.Suggestions.returnKeyChipBorder(mode), lineWidth: OrivOutline.hairline)
                        }
                }
                .padding(.horizontal, OrivMacV3.ToolbarLayout.suggestionRowPaddingHorizontal)
                .frame(height: OrivMacV3.ToolbarLayout.suggestionRowHeight)
                .background(OrivMacV3.Suggestions.selectedFill(mode), in: rowShape)
                .overlay {
                    rowShape.strokeBorder(OrivMacV3.Suggestions.selectedBorder(mode, increasedContrast: v3Increased),
                                          lineWidth: v3Increased ? OrivOutline.focus : OrivOutline.hairline)
                }

                Rectangle()
                    .fill(OrivMacV3.Suggestions.divider(mode, increasedContrast: v3Increased))
                    .frame(height: v3Increased ? OrivOutline.enhanced : OrivOutline.hairline)
                    .padding(.horizontal, OrivMacV3.ToolbarLayout.suggestionRowPaddingHorizontal)

                HStack(spacing: OrivMacV3.ToolbarLayout.suggestionRowGap) {
                    Image(systemName: "magnifyingglass")
                        .font(OrivMacV3.Typography.detail)
                        .foregroundStyle(secondary)
                        .frame(width: OrivMacV3.ToolbarLayout.suggestionIconSize)
                    Text("Search for \"dev\"").font(OrivMacV3.Typography.sidebarRow).foregroundStyle(primary)
                    Spacer()
                    Text("DuckDuckGo")
                        .font(OrivMacV3.Typography.sectionLabel)
                        .foregroundStyle(tertiary)
                        .padding(.horizontal, OrivSpacing.small)
                        .padding(.vertical, OrivSpacing.xxs)
                        .background(OrivMacV3.Suggestions.enginePillFill(mode), in: OrivMacV3.Radius.capsule)
                }
                .padding(.horizontal, OrivMacV3.ToolbarLayout.suggestionRowPaddingHorizontal)
                .frame(height: OrivMacV3.ToolbarLayout.suggestionSearchRowHeight)
            }
            .padding(OrivMacV3.ToolbarLayout.suggestionsPadding)
            .orivV3Glass(OrivMacV3.Popover.glassFill(mode), in: popoverShape, forceSolid: true)
            .orivV3Shadow(OrivMacV3.Popover.elevation(mode))
        }
    }

    private func v3StartPageSection(mode: OrivMacV3.AppearanceMode) -> some View {
        let containerShape = RoundedRectangle(cornerRadius: OrivMacV3.Radius.pageCard, style: .continuous)
        let primary = OrivMacV3.Ink.primary(mode)
        let secondary = OrivMacV3.Ink.secondary(mode, increasedContrast: v3Increased)
        let tertiary = OrivMacV3.Ink.tertiary(mode, onSidebar: false, increasedContrast: v3Increased)
        return VStack(alignment: .leading, spacing: OrivSpacing.small) {
            Text("Start Page Big Field & 52 pt App-Icon Tiles")
                .font(OrivMacV3.Typography.sectionLabel)
                .foregroundStyle(secondary)

            ZStack {
                OrivMacV3.Backdrop.BackdropView(mode: mode, startPage: true, profileColor: .mulberry, reduced: v3Reduced)
                VStack(spacing: OrivSpacing.large) {
                    HStack(spacing: OrivMacV3.StartLayout.bigFieldGap) {
                        Image(systemName: "magnifyingglass")
                            .font(OrivMacV3.Typography.startBigField)
                            .foregroundStyle(secondary)
                        Text("Search or enter address")
                            .font(OrivMacV3.Typography.startBigField)
                            .foregroundStyle(tertiary)
                        Spacer()
                        HStack(spacing: OrivMacV3.StartLayout.engineChipGap) {
                            Image(systemName: "magnifyingglass").font(OrivMacV3.Typography.detail)
                            Text("DuckDuckGo").font(OrivMacV3.Typography.detail)
                        }
                        .foregroundStyle(secondary)
                        .padding(.horizontal, OrivMacV3.StartLayout.engineChipPaddingHorizontal)
                        .frame(height: OrivMacV3.StartLayout.engineChipHeight)
                        .background(OrivMacV3.StartPage.engineChipFill(mode), in: OrivMacV3.Radius.capsule)
                    }
                    .padding(.leading, OrivMacV3.StartLayout.bigFieldLeadingPadding)
                    .padding(.trailing, OrivMacV3.StartLayout.bigFieldTrailingPadding)
                    .frame(maxWidth: OrivMacV3.StartLayout.columnWidth)
                    .frame(height: OrivMacV3.StartLayout.bigFieldSize.height)
                    .orivV3Glass(OrivMacV3.StartPage.bigFieldFill(mode, focused: true), in: OrivMacV3.Radius.capsule, forceSolid: true)
                    .background {
                        if !v3Increased {
                            OrivMacV3.Radius.capsule
                                .stroke(OrivMacV3.StartPage.bigFieldFocusHalo(mode), lineWidth: OrivMacV3.Focus.addressHaloWidth + OrivMacV3.Focus.addressHaloWidth)
                        }
                    }
                    .orivV3Shadow(OrivMacV3.StartPage.bigFieldShadow(mode))

                    HStack(spacing: OrivMacV3.StartLayout.bookmarkGap) {
                        v3AppIconTile(mode: mode, letter: "W", title: "WebKit", gradientIndex: 0, hovered: true)
                        v3AppIconTile(mode: mode, letter: "S", title: "Swift.org", gradientIndex: 1, hovered: false)
                        v3AppIconTile(mode: mode, letter: "F", title: "Fieldnotes", gradientIndex: 2, hovered: false)
                        v3AppIconTile(mode: mode, letter: "G", title: "GitHub", gradientIndex: 3, hovered: false)
                        Spacer()
                        // Private handoff pill preview in the same start/chrome showcase strip
                        HStack(spacing: OrivMacV3.ToolbarLayout.handoffGap) {
                            Image(systemName: "eyeglasses").foregroundStyle(OrivMacV3.Semantic.privateAccent(.private))
                            Text("Opened privately from Slack")
                                .font(OrivMacV3.Typography.handoffMessage)
                                .foregroundStyle(OrivMacV3.Handoff.messageInk)
                            Text("Move to Personal")
                                .font(OrivMacV3.Typography.detailSemibold)
                                .foregroundStyle(OrivMacV3.Handoff.moveButtonInk)
                                .padding(.horizontal, OrivSpacing.medium)
                                .frame(height: OrivMacV3.ToolbarLayout.handoffControlHeight)
                                .background(v3Increased ? AnyShapeStyle(OrivMacV3.Handoff.moveButtonSolid) : AnyShapeStyle(OrivMacV3.Handoff.moveButtonGradient),
                                            in: RoundedRectangle(cornerRadius: OrivMacV3.Radius.profileAvatar, style: .continuous))
                        }
                        .padding(.leading, OrivMacV3.ToolbarLayout.handoffLeadingPadding)
                        .padding(.trailing, OrivMacV3.ToolbarLayout.handoffTrailingPadding)
                        .frame(height: OrivMacV3.ToolbarLayout.handoffHeight)
                        .orivV3Glass(OrivMacV3.Handoff.bar,
                                     in: RoundedRectangle(cornerRadius: OrivMacV3.Radius.pageCard, style: .continuous),
                                     forceSolid: true)
                        .orivV3Shadow(OrivMacV3.Handoff.shadow)
                    }
                    .foregroundStyle(primary)
                }
                .padding(OrivSpacing.large)
            }
            .clipShape(containerShape)
            .overlay {
                containerShape.strokeBorder(OrivMacV3.Card.rim(mode, increasedContrast: v3Increased),
                                            lineWidth: v3Increased ? OrivOutline.enhanced : OrivOutline.hairline)
            }
        }
    }

    private func v3AppIconTile(mode: OrivMacV3.AppearanceMode, letter: String, title: String,
                               gradientIndex: Int, hovered: Bool) -> some View {
        let iconShape = RoundedRectangle(cornerRadius: OrivMacV3.Radius.startAppIcon, style: .continuous)
        let cardShape = RoundedRectangle(cornerRadius: OrivMacV3.Radius.startCard, style: .continuous)
        return VStack(spacing: OrivMacV3.StartLayout.bookmarkTileGap) {
            ZStack {
                iconShape.fill(OrivMacV3.StartPage.sampleAppIconGradient(gradientIndex))
                Text(letter)
                    .font(OrivMacV3.Typography.appIconMonogram)
                    .foregroundStyle(OrivMacV3.StartPage.appIconOnColor)
            }
            .frame(width: OrivMacV3.StartLayout.bookmarkIconSize, height: OrivMacV3.StartLayout.bookmarkIconSize)
            .overlay { iconShape.strokeBorder(OrivMacV3.StartPage.appIconInnerRim(mode), lineWidth: OrivOutline.hairline) }
            .orivV3Shadow(OrivMacV3.StartPage.appIconShadow(mode))
            Text(title)
                .font(OrivMacV3.Typography.suggestionURL)
                .foregroundStyle(OrivMacV3.Ink.primary(mode))
                .lineLimit(1)
        }
        .frame(minWidth: OrivMacV3.SidebarLayout.railWidth)
        .padding(.top, OrivMacV3.StartLayout.bookmarkTilePaddingTop)
        .padding(.horizontal, OrivSpacing.small)
        .padding(.bottom, OrivMacV3.StartLayout.bookmarkTilePaddingBottom)
        .background(hovered ? OrivMacV3.StartPage.tileHoverFill(mode, solid: true) : OrivMacV3.Card.fillStartPage, in: cardShape)
        .overlay {
            if hovered {
                cardShape.strokeBorder(OrivMacV3.StartPage.tileHoverBorder(mode, increasedContrast: v3Increased),
                                       lineWidth: v3Increased ? OrivOutline.enhanced : OrivOutline.hairline)
            }
        }
        .orivV3Shadow(hovered ? OrivMacV3.StartPage.tileHoverShadow(mode) : .none)
    }
    #endif
}
#endif
