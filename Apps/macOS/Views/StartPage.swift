import AppKit
import BrowserCore
import BrowserEngine
import SwiftUI

struct MacStartAddressSlotBounds: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = nextValue() ?? value }
}

/// Fable-layout Mac start page rendered inside the Neon floating frame.
/// The single persistent `AddressField` overlay positions itself over the
/// reserved big-field slot reported via `onAddressSlotChange`.
struct StartPage: View {
    @Environment(\.browserTheme) private var theme
    @Environment(\.v3AppearanceMode) private var windowMode
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.chromeContrastOverride) private var captureContrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.chromeReduceTransparencyOverride) private var captureReduceTransparency
    @Environment(\.dynamicTypeSize) private var typeSize
    let session: BrowserSession
    let isPrivate: Bool
    var profile: BrowserProfile? = nil
    var hasTopBars: Bool = false
    let openLibrary: (LibrarySection) -> Void
    var onAddressSlotChange: (CGRect) -> Void = { _ in }
    @State private var formattedDate = Self.formatDate(.now)
    @State private var slotInDocument: CGRect = .zero
    @State private var scrollOffsetY: CGFloat = 0

    private var mode: OrivMacV3.AppearanceMode { isPrivate ? .private : windowMode }
    private var contrast: ColorSchemeContrast { captureContrast ?? systemContrast }
    private var increasedContrast: Bool { contrast == .increased }
    private var usesSolid: Bool {
        OrivMacV3.usesOpaqueSurface(theme: theme, reduceTransparency: reduceTransparency,
                                    captureReduceTransparency: captureReduceTransparency, contrast: contrast)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEEMMMMd")
        return formatter
    }()

    private static func formatDate(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    private func reportSlot(docRect: CGRect, scrollY: CGFloat) {
        guard docRect.width > 0, docRect.height > 0 else { return }
        let shifted = CGRect(x: docRect.minX, y: docRect.minY - scrollY, width: docRect.width, height: docRect.height)
        onAddressSlotChange(shifted)
    }

    var body: some View {
        GeometryReader { proxy in
            let cardWidth = proxy.size.width
            let cardHeight = proxy.size.height
            let columnWidth = OrivMacV3.StartLayout.columnWidth(for: cardWidth)
            let topMargin = OrivMacV3.StartLayout.headerTopMargin(for: cardHeight, hasTopBars: hasTopBars)
            TransparentVerticalScroll(
                viewportSize: proxy.size,
                onScrollYChange: { offsetY in
                    scrollOffsetY = offsetY
                    reportSlot(docRect: slotInDocument, scrollY: offsetY)
                }
            ) {
                VStack(spacing: .zero) {
                    OrivMacV3.Card.fillStartPage
                        .frame(height: topMargin)
                        .accessibilityHidden(true)
                    headerChip
                    Text(isPrivate ? "Private Browsing" : "Where to?")
                        .font(OrivMacV3.Typography.startHeroTitle)
                        .tracking(OrivMacV3.Typography.startHeroTracking)
                        .foregroundStyle(OrivMacV3.Ink.primary(mode))
                        .padding(.top, OrivMacV3.StartLayout.titleTopGap)
                        .accessibilityAddTraits(.isHeader)
                    OrivMacV3.Card.fillStartPage
                        .frame(width: columnWidth, height: OrivMacV3.StartLayout.bigFieldSize.height)
                        .padding(.top, OrivMacV3.StartLayout.bigFieldTopMargin)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("startPageDocument")) } action: { rect in
                            slotInDocument = rect
                            reportSlot(docRect: rect, scrollY: scrollOffsetY)
                        }
                        .accessibilityHidden(true)
                    if isPrivate {
                        privateInfoCard(cardWidth: cardWidth, columnWidth: columnWidth)
                            .padding(.top, OrivMacV3.StartLayout.privateCardTopGap)
                    } else {
                        MacStartPageSites(
                            session: session,
                            mode: mode,
                            cardWidth: cardWidth,
                            columnWidth: columnWidth,
                            usesSolid: usesSolid,
                            increasedContrast: increasedContrast,
                            open: { session.openSavedPage($0) },
                            showBookmarks: { openLibrary(.bookmarks) },
                            showHistory: { openLibrary(.history) }
                        )
                    }
                    Spacer(minLength: OrivSpacing.xl)
                    shortcutHintsFooter(cardWidth: cardWidth)
                        .padding(.bottom, OrivMacV3.StartLayout.footerBottomInset)
                }
                .frame(width: max(1, cardWidth))
                .frame(minHeight: max(1, cardHeight))
                .coordinateSpace(name: "startPageDocument")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isPrivate ? "Private Browsing Start Page" : "Start Page")
    }

    @ViewBuilder
    private var headerChip: some View {
        if isPrivate {
            HStack(spacing: OrivMacV3.StartLayout.profileChipGap) {
                Image(systemName: "eyeglasses")
                    .font(OrivMacV3.Typography.startPrivateChipIcon)
                    .accessibilityHidden(true)
                Text("Private window")
                    .font(OrivMacV3.Typography.startBody)
            }
            .foregroundStyle(OrivMacV3.Semantic.privateAccent(.private, increasedContrast: increasedContrast))
        } else {
            let activeColor = profile?.color ?? .mulberry
            let activeSymbol = profile?.symbol.rawValue ?? ProfileSymbol.person.rawValue
            let activeName = profile?.name ?? "Personal"
            HStack(spacing: OrivMacV3.StartLayout.profileChipGap) {
                ZStack {
                    Circle().fill(OrivMacV3.StartPage.profileChipGradient(activeColor))
                    Image(systemName: activeSymbol)
                        .font(OrivMacV3.Typography.startProfileChipSymbol)
                        .foregroundStyle(OrivMacV3.StartPage.appIconOnColor)
                }
                .frame(width: OrivMacV3.StartLayout.profileChipAvatar, height: OrivMacV3.StartLayout.profileChipAvatar)
                .overlay {
                    Circle().strokeBorder(OrivMacV3.StartPage.appIconInnerRim(mode), lineWidth: OrivOutline.hairline)
                }
                .accessibilityHidden(true)
                Text("\(activeName) · \(formattedDate)")
                    .font(OrivMacV3.Typography.startBody)
                    .foregroundStyle(OrivMacV3.Ink.secondary(mode, increasedContrast: increasedContrast))
            }
        }
    }

    private func privateInfoCard(cardWidth: CGFloat, columnWidth: CGFloat) -> some View {
        let singleColumn = cardWidth < OrivMacV3.StartLayout.frequentCollapseCardWidth || typeSize.isAccessibilitySize
        let cardShape = RoundedRectangle(cornerRadius: OrivMacV3.Radius.privateCard, style: .continuous)
        let cardFill = usesSolid ? OrivMacV3.StartPage.privateCardSolidFill : OrivMacV3.StartPage.privateCardFill
        let cardBorder = increasedContrast
            ? OrivMacV3.Card.rimIncreasedContrast(.private)
            : (usesSolid ? OrivMacV3.StartPage.privateCardSolidBorder : OrivMacV3.StartPage.privateCardBorder)
        let columns = Array(
            repeating: GridItem(.flexible(minimum: 0), spacing: OrivMacV3.StartLayout.privateCardColumnGap, alignment: .topLeading),
            count: singleColumn ? 1 : OrivMacV3.StartLayout.privateCardColumns
        )
        return LazyVGrid(columns: columns, alignment: .leading, spacing: OrivMacV3.StartLayout.privateCardRowGap) {
            VStack(alignment: .leading, spacing: .zero) {
                privateColumnHeading("Not kept after you close these tabs")
                privateInfoRow(
                    symbol: "clock.arrow.circlepath",
                    title: "Tabs and history",
                    detail: "Private tabs aren’t saved or added to history."
                )
                privateInfoRow(
                    symbol: "trash",
                    title: "Cookies and website data",
                    detail: "Discarded when the last tab sharing them closes."
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: .zero) {
                privateColumnHeading("Still visible or kept")
                privateInfoRow(
                    symbol: "eye",
                    title: "Your activity",
                    detail: "Websites and your network can still see it."
                )
                privateInfoRow(
                    symbol: "arrow.down.circle",
                    title: "Downloaded files",
                    detail: "They stay on your Mac."
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, OrivMacV3.StartLayout.privateCardPaddingVertical)
        .padding(.horizontal, OrivMacV3.StartLayout.privateCardPaddingHorizontal)
        .frame(width: columnWidth, alignment: .leading)
        .background(cardFill, in: cardShape)
        .overlay {
            cardShape.strokeBorder(cardBorder, lineWidth: increasedContrast ? OrivOutline.enhanced : OrivOutline.hairline)
        }
        .accessibilityIdentifier("homePrivateCard")
        .browserGeometryMarker("homePrivateCard")
    }

    private func privateColumnHeading(_ title: String) -> some View {
        Text(title)
            .font(OrivMacV3.Typography.sectionLabel)
            .foregroundStyle(OrivMacV3.Semantic.privateAccent(.private, increasedContrast: increasedContrast))
            .padding(.bottom, OrivMacV3.StartLayout.privateCardHeadingBottomGap)
            .accessibilityAddTraits(.isHeader)
    }

    private func privateInfoRow(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: OrivMacV3.StartLayout.privateCardItemGap) {
            Image(systemName: symbol)
                .font(OrivMacV3.Typography.startPrivateCardIcon)
                .foregroundStyle(OrivMacV3.Semantic.privateAccent(.private, increasedContrast: increasedContrast))
                .frame(width: OrivMacV3.StartLayout.privateCardIconSize, height: OrivMacV3.StartLayout.privateCardIconSize)
                .padding(.top, OrivSpacing.xxs)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: OrivMacV3.StartLayout.privateCardItemTextGap) {
                Text(title)
                    .font(OrivMacV3.Typography.startBody)
                    .foregroundStyle(OrivMacV3.Ink.primary(.private))
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(OrivMacV3.Typography.detail)
                    .foregroundStyle(OrivMacV3.Ink.secondary(.private, increasedContrast: increasedContrast))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, OrivMacV3.StartLayout.privateCardItemTopMargin)
        .accessibilityElement(children: .combine)
    }

    private func shortcutHintsFooter(cardWidth: CGFloat) -> some View {
        let hints: [(key: String, label: String)] = isPrivate
            ? [("⌘T", "New private tab"), ("⌘L", "Address"), ("⌘W", "Close tab")]
            : [("⌘L", "Address"), ("⇧⌘A", "Search tabs"), ("⇧⌘N", "New private tab"), ("⌥⌘S", "Sidebar")]
        let compact = cardWidth < OrivMacV3.StartLayout.footerWrapCardWidth
        return Group {
            if compact {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: OrivLayout.sidebarWidth / 2), spacing: OrivMacV3.StartLayout.footerCompactGap)],
                    spacing: OrivSpacing.small
                ) {
                    ForEach(hints, id: \.key) { hint in
                        shortcutHintChip(key: hint.key, label: hint.label)
                    }
                }
                .frame(maxWidth: OrivMacV3.StartLayout.columnWidth(for: cardWidth))
            } else {
                HStack(spacing: OrivMacV3.StartLayout.footerGap) {
                    ForEach(hints, id: \.key) { hint in
                        shortcutHintChip(key: hint.key, label: hint.label)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityHidden(true)
        .browserGeometryMarker("startPageFooterGeometry")
    }

    private func shortcutHintChip(key: String, label: String) -> some View {
        let keycapShape = RoundedRectangle(cornerRadius: OrivMacV3.Radius.tabHint, style: .continuous)
        return HStack(spacing: OrivMacV3.StartLayout.keycapTrailingMargin) {
            Text(key)
                .font(OrivMacV3.Typography.startKeycap)
                .foregroundStyle(OrivMacV3.StartPage.keycapInk(mode, increasedContrast: increasedContrast))
                .padding(.vertical, OrivMacV3.StartLayout.keycapPaddingVertical)
                .padding(.horizontal, OrivMacV3.StartLayout.keycapPaddingHorizontal)
                .background(OrivMacV3.StartPage.keycapFill(mode, solid: usesSolid), in: keycapShape)
                .overlay {
                    if increasedContrast {
                        keycapShape.strokeBorder(OrivMacV3.Card.rimIncreasedContrast(mode), lineWidth: OrivOutline.hairline)
                    }
                }
            Text(label)
                .font(OrivMacV3.Typography.startFooter)
                .foregroundStyle(OrivMacV3.StartPage.footerInk(mode, increasedContrast: increasedContrast))
        }
        .fixedSize()
    }
}

/// Mac-only Fable bookmarks row + Frequently Visited card (iPhone keeps `StartPageSites` untouched).
private struct MacStartPageSites: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let session: BrowserSession
    let mode: OrivMacV3.AppearanceMode
    let cardWidth: CGFloat
    let columnWidth: CGFloat
    let usesSolid: Bool
    let increasedContrast: Bool
    let open: (URL) -> Void
    let showBookmarks: () -> Void
    let showHistory: () -> Void

    private struct Query: Equatable {
        let session: ObjectIdentifier
        let revision: Int
        let bookmarkURLs: Set<URL>
    }

    @State private var loadedQuery: Query?
    @State private var frequent: [HistoryEntry] = []

    private var bookmarkColumnCount: Int {
        if typeSize.isAccessibilitySize { return OrivMacV3.StartLayout.bookmarkAccessibilityColumns }
        return cardWidth < OrivMacV3.StartLayout.bookmarkWrapCardWidth
            ? OrivMacV3.StartLayout.bookmarkCompactColumns
            : OrivMacV3.StartLayout.bookmarkColumns
    }

    private var frequentColumnCount: Int {
        if typeSize.isAccessibilitySize || cardWidth < OrivMacV3.StartLayout.frequentCollapseCardWidth {
            return 1
        }
        return OrivMacV3.StartLayout.frequentColumns
    }

    var body: some View {
        let bookmarks = Array(session.bookmarks.prefix(OrivMacV3.StartLayout.bookmarkColumns))
        let query = Query(
            session: ObjectIdentifier(session),
            revision: session.historyRevision,
            bookmarkURLs: Set(bookmarks.map(\.url))
        )
        let suggestions = loadedQuery == query ? frequent : []
        VStack(alignment: .leading, spacing: .zero) {
            if bookmarks.isEmpty && suggestions.isEmpty {
                emptyState
                    .padding(.top, OrivMacV3.StartLayout.sectionTopGap)
            } else {
                if !bookmarks.isEmpty {
                    bookmarksSection(bookmarks)
                        .padding(.top, OrivMacV3.StartLayout.sectionTopGap)
                }
                if !suggestions.isEmpty {
                    frequentSection(suggestions)
                        .padding(.top, OrivMacV3.StartLayout.sectionTopGap)
                }
            }
        }
        .frame(width: columnWidth, alignment: .leading)
        .task(id: query) {
            let entries = await session.frequentHistory(excluding: query.bookmarkURLs, isPrivate: false)
            guard !Task.isCancelled else { return }
            frequent = entries
            loadedQuery = query
        }
    }

    private var emptyState: some View {
        let shape = RoundedRectangle(cornerRadius: OrivMacV3.Radius.startCard, style: .continuous)
        return VStack(spacing: OrivSpacing.small) {
            Text("Bookmarks and frequently visited sites appear here.")
                .font(OrivMacV3.Typography.startBody)
                .foregroundStyle(OrivMacV3.Ink.secondary(mode, increasedContrast: increasedContrast))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("Type an address or search query above to get started.")
                .font(OrivMacV3.Typography.detail)
                .foregroundStyle(OrivMacV3.StartPage.footerInk(mode, increasedContrast: increasedContrast))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, OrivMacV3.StartLayout.emptyStatePaddingVertical)
        .padding(.horizontal, OrivMacV3.StartLayout.emptyStatePaddingHorizontal)
        .frame(maxWidth: .infinity)
        .background(OrivMacV3.StartPage.frequentCardFill(mode, solid: usesSolid), in: shape)
        .overlay {
            shape.strokeBorder(
                OrivMacV3.StartPage.frequentCardBorder(mode, increasedContrast: increasedContrast),
                lineWidth: increasedContrast ? OrivOutline.enhanced : OrivOutline.hairline
            )
        }
        .orivV3Shadow(OrivMacV3.StartPage.frequentCardShadow(mode))
        .accessibilityIdentifier("homeEmptyState")
        .browserGeometryMarker("homeEmptyState")
    }

    private func sectionHeader(_ title: String, showAll: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: OrivSpacing.small) {
            Text(title)
                .font(OrivMacV3.Typography.startSectionHeader)
                .foregroundStyle(OrivMacV3.Ink.secondary(mode, increasedContrast: increasedContrast))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: .zero)
            Button("Show All", action: showAll)
                .buttonStyle(.plain)
                .font(OrivMacV3.Typography.detail)
                .foregroundStyle(OrivMacV3.StartPage.linkInk(mode, increasedContrast: increasedContrast))
                .accessibilityLabel("Show All \(title)")
        }
    }

    private func bookmarksSection(_ bookmarks: [Bookmark]) -> some View {
        let columns = Array(
            repeating: GridItem(.flexible(minimum: 0), spacing: OrivMacV3.StartLayout.bookmarkGap, alignment: .top),
            count: bookmarkColumnCount
        )
        return VStack(alignment: .leading, spacing: OrivMacV3.StartLayout.sectionContentTopGap) {
            sectionHeader("Bookmarks", showAll: showBookmarks)
            LazyVGrid(columns: columns, alignment: .leading, spacing: OrivMacV3.StartLayout.bookmarkGap) {
                ForEach(bookmarks, id: \.url) { bookmark in
                    StartBookmarkTile(
                        title: bookmark.title,
                        url: bookmark.url,
                        mode: mode,
                        usesSolid: usesSolid,
                        increasedContrast: increasedContrast,
                        open: { open(bookmark.url) },
                        openInNewTab: { session.openSavedPage(bookmark.url, inNewTab: true) }
                    )
                }
            }
        }
        .accessibilityIdentifier("homeBookmarks")
        .browserGeometryMarker("homeBookmarks")
    }

    private func frequentSection(_ entries: [HistoryEntry]) -> some View {
        let cardShape = RoundedRectangle(cornerRadius: OrivMacV3.Radius.startCard, style: .continuous)
        let columns = Array(
            repeating: GridItem(.flexible(minimum: 0), spacing: OrivSpacing.xs, alignment: .leading),
            count: frequentColumnCount
        )
        return VStack(alignment: .leading, spacing: OrivMacV3.StartLayout.sectionContentTopGap) {
            sectionHeader("Frequently Visited", showAll: showHistory)
            LazyVGrid(columns: columns, alignment: .leading, spacing: OrivMacV3.StartLayout.frequentCardRowGap) {
                ForEach(entries, id: \.url) { entry in
                    StartFrequentRow(
                        title: entry.title,
                        url: entry.url,
                        mode: mode,
                        usesSolid: usesSolid,
                        increasedContrast: increasedContrast,
                        open: { open(entry.url) },
                        openInNewTab: { session.openSavedPage(entry.url, inNewTab: true) }
                    )
                }
            }
            .padding(OrivMacV3.StartLayout.frequentCardPadding)
            .background(OrivMacV3.StartPage.frequentCardFill(mode, solid: usesSolid), in: cardShape)
            .overlay {
                cardShape.strokeBorder(
                    OrivMacV3.StartPage.frequentCardBorder(mode, increasedContrast: increasedContrast),
                    lineWidth: increasedContrast ? OrivOutline.enhanced : OrivOutline.hairline
                )
            }
            .orivV3Shadow(OrivMacV3.StartPage.frequentCardShadow(mode))
        }
        .accessibilityIdentifier("homeFrequent")
        .browserGeometryMarker("homeFrequent")
    }
}

private struct StartBookmarkTile: View {
    @Environment(\.siteIcons) private var icons
    let title: String
    let url: URL
    let mode: OrivMacV3.AppearanceMode
    let usesSolid: Bool
    let increasedContrast: Bool
    let open: () -> Void
    let openInNewTab: () -> Void
    @State private var hovered = false

    private var displayName: String { title.isEmpty ? (url.host ?? "Saved page") : title }

    var body: some View {
        let cardShape = RoundedRectangle(cornerRadius: OrivMacV3.Radius.startCard, style: .continuous)
        Button(action: open) {
            VStack(spacing: OrivMacV3.StartLayout.bookmarkTileGap) {
                StartAppIcon(
                    url: url,
                    size: OrivMacV3.StartLayout.bookmarkIconSize,
                    cornerRadius: OrivMacV3.Radius.startAppIcon,
                    monogramFont: OrivMacV3.Typography.appIconMonogram,
                    mode: mode,
                    showsShadow: true
                )
                Text(displayName)
                    .font(OrivMacV3.Typography.suggestionURL)
                    .foregroundStyle(OrivMacV3.Ink.primary(mode))
                    .multilineTextAlignment(.center)
                    .lineLimit(2, reservesSpace: true)
                    .frame(maxWidth: .infinity)
            }
            .padding(.top, OrivMacV3.StartLayout.bookmarkTilePaddingTop)
            .padding(.horizontal, OrivMacV3.StartLayout.bookmarkTilePaddingHorizontal)
            .padding(.bottom, OrivMacV3.StartLayout.bookmarkTilePaddingBottom)
            .frame(maxWidth: .infinity)
            .background(hovered ? OrivMacV3.StartPage.tileHoverFill(mode, solid: usesSolid) : OrivMacV3.Card.fillStartPage, in: cardShape)
            .overlay {
                if hovered {
                    cardShape.strokeBorder(
                        OrivMacV3.StartPage.tileHoverBorder(mode, increasedContrast: increasedContrast),
                        lineWidth: increasedContrast ? OrivOutline.enhanced : OrivOutline.hairline
                    )
                }
            }
            .orivV3Shadow(hovered ? OrivMacV3.StartPage.tileHoverShadow(mode) : .none)
            .contentShape(cardShape)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(displayName)
        .accessibilityHint(url.host ?? "")
        .accessibilityIdentifier("homeBookmarks-tile")
        .browserGeometryMarker("homeBookmarks-tile")
        .contextMenu { Button("Open in New Tab", action: openInNewTab) }
        .help(url.absoluteString)
        .task(id: url) { await icons?.loadCached(url) }
    }
}

private struct StartFrequentRow: View {
    @Environment(\.siteIcons) private var icons
    let title: String
    let url: URL
    let mode: OrivMacV3.AppearanceMode
    let usesSolid: Bool
    let increasedContrast: Bool
    let open: () -> Void
    let openInNewTab: () -> Void
    @State private var hovered = false

    private var displayName: String { title.isEmpty ? (url.host ?? "Saved page") : title }
    private var displayHost: String { URLDisplay.site(url) ?? url.host ?? "" }

    var body: some View {
        let rowShape = RoundedRectangle(cornerRadius: OrivMacV3.Radius.row, style: .continuous)
        Button(action: open) {
            HStack(spacing: OrivMacV3.StartLayout.frequentRowGap) {
                StartAppIcon(
                    url: url,
                    size: OrivMacV3.StartLayout.frequentFaviconSize,
                    cornerRadius: OrivMacV3.StartLayout.frequentFaviconRadius,
                    monogramFont: OrivMacV3.Typography.frequentFaviconMonogram,
                    mode: mode,
                    showsShadow: false
                )
                Text(displayName)
                    .font(OrivMacV3.Typography.startBody)
                    .foregroundStyle(OrivMacV3.Ink.primary(mode))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !displayHost.isEmpty {
                    Text(displayHost)
                        .font(OrivMacV3.Typography.suggestionURL)
                        .foregroundStyle(OrivMacV3.StartPage.frequentHostInk(mode, increasedContrast: increasedContrast))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(.horizontal, OrivMacV3.StartLayout.frequentRowPaddingHorizontal)
            .frame(height: OrivMacV3.StartLayout.frequentRowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovered ? OrivMacV3.StartPage.frequentRowHover(mode, solid: usesSolid) : OrivMacV3.Card.fillStartPage, in: rowShape)
            .contentShape(rowShape)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(displayName)
        .accessibilityHint(url.host ?? "")
        .accessibilityIdentifier("homeFrequent-tile")
        .browserGeometryMarker("homeFrequent-tile")
        .contextMenu { Button("Open in New Tab", action: openInNewTab) }
        .help(url.absoluteString)
        .task(id: url) { await icons?.loadCached(url) }
    }
}

/// Renders a cached site favicon or deterministic Fable app-icon monogram squircle.
private struct StartAppIcon: View {
    @Environment(\.siteIcons) private var icons
    @Environment(\.browserTheme) private var theme
    let url: URL
    let size: CGFloat
    let cornerRadius: CGFloat
    let monogramFont: Font
    let mode: OrivMacV3.AppearanceMode
    let showsShadow: Bool

    private var hostLabel: String { SiteMonogram.label(for: url.host()) ?? url.host ?? "" }
    private var letter: String? {
        guard let first = hostLabel.first, first.isLetter else { return nil }
        return String(first).uppercased()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            if let icon = icons?.icon(for: url, isPrivate: false) {
                shape.fill(theme.iconPlate)
                Image(decorative: icon.image, scale: 2)
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.12)
                    .clipShape(shape)
            } else {
                shape.fill(OrivMacV3.StartPage.appIconGradient(for: hostLabel))
                if let letter {
                    Text(letter)
                        .font(monogramFont)
                        .foregroundStyle(OrivMacV3.StartPage.appIconOnColor)
                } else {
                    Image(systemName: "globe")
                        .font(monogramFont)
                        .foregroundStyle(OrivMacV3.StartPage.appIconOnColor)
                }
            }
        }
        .frame(width: size, height: size)
        .overlay {
            shape.strokeBorder(OrivMacV3.StartPage.appIconInnerRim(mode), lineWidth: OrivOutline.hairline)
        }
        .orivV3Shadow(showsShadow ? OrivMacV3.StartPage.appIconShadow(mode) : .none)
        .accessibilityHidden(true)
    }
}

/// Transparent vertical NSScrollView host so the start page shows the window
/// backdrop gradient through the rim-only card in both live compositing and
/// off-screen snapshots while supporting native macOS scrolling on short windows.
private struct TransparentVerticalScroll<Content: View>: NSViewRepresentable {
    let viewportSize: CGSize
    let onScrollYChange: (CGFloat) -> Void
    @ViewBuilder let content: () -> Content

    func makeCoordinator() -> Coordinator { Coordinator(onScrollYChange: onScrollYChange) }

    func makeNSView(context: Context) -> ScrollHost {
        let scroll = ScrollHost()
        let clip = FlippedClipView()
        clip.drawsBackground = false
        clip.postsBoundsChangedNotifications = true
        scroll.contentView = clip
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        let hosted = NSHostingView(rootView: AnyView(content().environment(\.self, context.environment)))
        hosted.sizingOptions = []
        scroll.documentView = hosted
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.boundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: clip
        )
        return scroll
    }

    func updateNSView(_ scroll: ScrollHost, context: Context) {
        context.coordinator.onScrollYChange = onScrollYChange
        let hosted = scroll.documentView as? NSHostingView<AnyView>
        hosted?.rootView = AnyView(content().environment(\.self, context.environment))
        scroll.updateDocumentSize(viewportSize: viewportSize)
    }

    static func dismantleNSView(_ scroll: ScrollHost, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    @MainActor final class Coordinator: NSObject {
        var onScrollYChange: (CGFloat) -> Void
        private var lastY: CGFloat = 0

        init(onScrollYChange: @escaping (CGFloat) -> Void) {
            self.onScrollYChange = onScrollYChange
        }

        @objc func boundsDidChange(_ notification: Notification) {
            guard let clip = notification.object as? NSClipView else { return }
            let y = clip.bounds.origin.y
            guard abs(y - lastY) > 0.25 else { return }
            lastY = y
            onScrollYChange(y)
        }
    }

    final class FlippedClipView: NSClipView {
        override var isFlipped: Bool { true }
    }

    final class ScrollHost: NSScrollView {
        private var lastViewport: CGSize = .zero

        func updateDocumentSize(viewportSize: CGSize) {
            lastViewport = viewportSize
            relayoutDocument()
        }

        override func layout() {
            super.layout()
            relayoutDocument()
        }

        private func relayoutDocument() {
            guard let doc = documentView else { return }
            let width = max(1, contentView.bounds.width > 0 ? contentView.bounds.width : lastViewport.width)
            let minHeight = max(1, contentView.bounds.height > 0 ? contentView.bounds.height : lastViewport.height)
            doc.frame.size.width = width
            let fittingHeight = doc.fittingSize.height
            let targetSize = CGSize(width: width, height: max(minHeight, fittingHeight))
            if abs(doc.frame.size.width - targetSize.width) > 0.5 || abs(doc.frame.size.height - targetSize.height) > 0.5 {
                doc.frame = CGRect(origin: .zero, size: targetSize)
            }
        }
    }
}
