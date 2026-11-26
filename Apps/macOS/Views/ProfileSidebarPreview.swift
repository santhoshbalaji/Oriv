import AppKit
import BrowserCore
import BrowserEngine
import SwiftUI

struct ProfileSidebarPreview: Sendable {
    struct Row: Identifiable, Sendable {
        let record: TabRecord
        var isPrivate = false
        var id: UUID { record.id }
    }

    var rows: [Row] = []
    var selected: UUID?
    var icons: [String: SiteIcon] = [:]

    nonisolated static func read(directory: URL) async -> Self {
        let snapshot = try? SessionFileStore(fileURL: directory.appendingPathComponent("session.json")).load().snapshot
        let rows = (snapshot?.tabs ?? []).map {
            var record = $0
            if record.title.isEmpty || (record.url == nil && record.title == "New tab") {
                record.title = record.url?.host ?? "New Tab"
            }
            return Row(record: record)
        }
        let disk = SiteIconDiskCache(directory: directory.appendingPathComponent("Favicons"))
        var icons: [String: SiteIcon] = [:]
        let keys = rows.prefix(60).compactMap { $0.record.url.flatMap { SiteIconStore.key($0, isPrivate: false) } }
        for key in Set(keys) {
            guard !Task.isCancelled else { break }
            icons[key] = await disk.read(key)
        }
        return Self(rows: rows, selected: snapshot?.selectedTabID, icons: icons)
    }

    @MainActor init(session: BrowserSession) {
        rows = session.orderedTabs.map { tab in
            Row(record: TabRecord(id: tab.id, title: tab.displayTitle, url: tab.url, isPinned: tab.isPinned),
                isPrivate: tab.isPrivate)
        }
        selected = session.selectedTabID
        for row in rows.prefix(60) {
            if let url = row.record.url, let key = SiteIconStore.key(url, isPrivate: row.isPrivate) {
                icons[key] = session.siteIcons.icon(for: url, isPrivate: row.isPrivate)
            }
        }
    }

    func matches(_ other: Self) -> Bool {
        selected == other.selected && rows.map(\.record) == other.rows.map(\.record) &&
            rows.map(\.isPrivate) == other.rows.map(\.isPrivate) &&
            icons.mapValues { ObjectIdentifier($0.image) } == other.icons.mapValues { ObjectIdentifier($0.image) }
    }

    init(rows: [Row] = [], selected: UUID? = nil, icons: [String: SiteIcon] = [:]) {
        self.rows = rows; self.selected = selected; self.icons = icons
    }
}

struct ProfileSidebarPreviewArtwork: View {
    @Environment(\.browserTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.sidebarContrast) private var contrast
    @Environment(\.v3AppearanceMode) private var v3Mode
    let profile: BrowserProfile
    let preview: ProfileSidebarPreview
    let size: CGSize
    var query = ""
    var profileTrailingInset: CGFloat = 0

    var body: some View {
        let mode = OrivMacV3.AppearanceMode.resolve(theme: theme, colorScheme: scheme,
                                                    isPrivateWindow: v3Mode == .private)
        let increased = contrast == .increased
        let secondary = OrivMacV3.Ink.secondary(mode, increasedContrast: increased)
        let tertiary = OrivMacV3.Ink.tertiary(mode, onSidebar: true, increasedContrast: increased)
        VStack(spacing: 0) {
            ProfileHeaderArtwork(profile: profile, tabCount: preview.rows.count, marksGeometry: false)
                .padding(.trailing, profileTrailingInset)
                .padding(.top, profileTrailingInset > 0 ? OrivSpacing.xs : .zero)
                .padding(.bottom, OrivMacV3.SidebarLayout.profileBottomMargin)
            HStack(spacing: OrivMacV3.SidebarLayout.searchInnerGap) {
                Image(systemName: "magnifyingglass")
                Text(query.isEmpty ? OrivStrings.searchTabs : query).lineLimit(1)
                Spacer(minLength: 0)
                if query.isEmpty {
                    Text("⇧⌘A").font(OrivMacV3.Typography.shortcutHint)
                        .tracking(OrivMacV3.Typography.labelTracking)
                        .foregroundStyle(tertiary)
                } else { Image(systemName: "xmark.circle.fill").frame(width: OrivTarget.macMinimum.width) }
            }
            .font(OrivMacV3.Typography.detail).foregroundStyle(secondary)
            .padding(.horizontal, OrivMacV3.SidebarLayout.searchPaddingHorizontal)
            .frame(height: OrivMacV3.SidebarLayout.searchHeight)
            .modifier(SidebarToneSurface(tone: .search))
            .padding(.bottom, OrivMacV3.SidebarLayout.searchBottomMargin)
            GeometryReader { proxy in
                let newTabBlock = OrivMacV3.SidebarLayout.newTabTopMargin + OrivMacV3.SidebarLayout.newTabHeight
                VStack(spacing: 0) {
                    list
                        .frame(maxWidth: .infinity, maxHeight: max(0, proxy.size.height - newTabBlock), alignment: .topLeading)
                        .clipped()
                    HStack(spacing: OrivMacV3.SidebarLayout.tabRowInnerGap) {
                        Image(systemName: "plus").frame(width: OrivMacV3.SidebarLayout.tabFaviconSize)
                        Text("New Tab")
                        Spacer()
                        Text("⌘T").font(OrivMacV3.Typography.shortcutHint)
                            .tracking(OrivMacV3.Typography.labelTracking)
                            .foregroundStyle(tertiary)
                    }
                    .font(OrivMacV3.Typography.sidebarNewTab)
                    .foregroundStyle(secondary)
                    .padding(.horizontal, OrivMacV3.SidebarLayout.newTabLeadingPadding)
                    .frame(height: OrivMacV3.SidebarLayout.newTabHeight)
                    .padding(.top, OrivMacV3.SidebarLayout.newTabTopMargin)
                    Spacer(minLength: 0)
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            }
        }
        .foregroundStyle(OrivMacV3.Ink.primary(mode))
        .frame(width: size.width, height: size.height)
    }

    private var list: some View {
        let pins = preview.rows.filter { $0.record.isPinned }
        let regular = preview.rows.filter { !$0.isPrivate && !$0.record.isPinned }
        let privateRows = preview.rows.filter { $0.isPrivate && !$0.record.isPinned }
        let duplicateTitles = Set(Dictionary(grouping: preview.rows, by: { $0.record.title }).filter { $0.value.count > 1 }.keys)
        let limit = max(1, Int(size.height / OrivMacV3.SidebarLayout.tabRowHeight) + 1)
        let grid = SidebarTabs.PinGrid(availableWidth: size.width)
        let visiblePins = Array(pins.prefix(limit * grid.columns))
        let rowStarts = Array(stride(from: 0, to: visiblePins.count, by: grid.columns))
        return VStack(spacing: OrivMacV3.SidebarLayout.tabRowGap) {
            if !pins.isEmpty {
                SidebarSectionHeading(title: "Pinned", count: pins.count, marksGeometry: false)
                VStack(alignment: .leading, spacing: OrivMacV3.SidebarLayout.pinGap) {
                    ForEach(rowStarts, id: \.self) { start in
                        HStack(spacing: OrivMacV3.SidebarLayout.pinGap) {
                            ForEach(visiblePins.dropFirst(start).prefix(grid.columns)) { row in
                                artwork(row, tile: true, duplicateTitles: duplicateTitles)
                                    .frame(width: grid.tileWidth, height: OrivMacV3.SidebarLayout.pinHeight)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, OrivMacV3.SidebarLayout.pinBottomMargin - OrivMacV3.SidebarLayout.tabRowGap)
            }
            rows("Tabs", regular, limit: limit, duplicates: duplicateTitles)
            rows("Private", privateRows, limit: limit, duplicates: duplicateTitles)
            if preview.rows.isEmpty { SidebarSectionHeading(title: "No tabs", count: 0, marksGeometry: false) }
        }.fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func rows(_ title: String?, _ rows: [ProfileSidebarPreview.Row],
                                   limit: Int, duplicates: Set<String>) -> some View {
        if !rows.isEmpty {
            if let title { SidebarSectionHeading(title: title, count: rows.count, marksGeometry: false) }
            VStack(spacing: OrivMacV3.SidebarLayout.tabRowGap) {
                ForEach(rows.prefix(limit)) { row in
                    artwork(row, tile: false, duplicateTitles: duplicates)
                        .frame(height: textSize.isAccessibilitySize ? OrivLayout.sidebarAccessibilityRowHeight : OrivMacV3.SidebarLayout.tabRowHeight)
                }
            }
        }
    }

    private func artwork(_ row: ProfileSidebarPreview.Row, tile: Bool, duplicateTitles: Set<String>) -> some View {
        let subtitle = duplicateTitles.contains(row.record.title) ? row.record.url?.host : nil
        return SidebarTabArtwork(record: row.record, selected: row.id == preview.selected, tile: tile,
                                 subtitle: subtitle, icons: preview.icons, isPrivate: row.isPrivate)
    }
}
