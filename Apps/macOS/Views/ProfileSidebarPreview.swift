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
    @Environment(\.dynamicTypeSize) private var textSize
    let profile: BrowserProfile
    let preview: ProfileSidebarPreview
    let size: CGSize
    var query = ""
    var profileTrailingInset: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            ProfileHeaderArtwork(name: profile.name, tabCount: preview.rows.count, marksGeometry: false)
                .padding(.trailing, profileTrailingInset).padding(.vertical, 8)
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                Text(query.isEmpty ? OrivStrings.searchTabs : query).lineLimit(1)
                Spacer(minLength: 0)
                if query.isEmpty { Text("⇧⌘A").font(.system(size: 10)) }
                else { Image(systemName: "xmark.circle.fill").frame(width: 24) }
            }
            .font(OrivType.detail).foregroundStyle(theme.secondaryText)
            .padding(.horizontal, MacBrowserLayout.sidebarRowInset).frame(height: 32)
            .background(theme.sidebar.field.opacity(0.7), in: .rect(cornerRadius: OrivRadius.small))
            .padding(.bottom, 10)
            GeometryReader { _ in
                list.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }.clipped()
            HStack(spacing: 8) {
                Image(systemName: "plus").frame(width: 19)
                Text("New Tab")
                Spacer()
                Text("⌘T").font(.system(size: 10)).foregroundStyle(theme.secondaryText)
            }.font(OrivType.body).padding(.horizontal, MacBrowserLayout.sidebarRowInset)
                .frame(height: 36).padding(.bottom, MacBrowserLayout.sidebarFooterGap)
        }
        .foregroundStyle(theme.text)
        .frame(width: size.width, height: size.height)
    }

    private var list: some View {
        let pins = preview.rows.filter { !$0.isPrivate && $0.record.isPinned }
        let regular = preview.rows.filter { !$0.isPrivate && !$0.record.isPinned }
        let privateRows = preview.rows.filter(\.isPrivate)
        let duplicateTitles = Set(Dictionary(grouping: preview.rows, by: { $0.record.title }).filter { $0.value.count > 1 }.keys)
        let limit = max(1, Int(size.height / 36) + 1)
        return VStack(spacing: 0) {
            if !pins.isEmpty {
                SidebarSectionHeading(title: "Pinned", count: pins.count, marksGeometry: false)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 9) {
                    ForEach(pins.prefix(SidebarTabs.gridLimit)) { row in
                        artwork(row, tile: true, duplicateTitles: duplicateTitles).frame(height: 48)
                    }
                }.padding(.vertical, 4)
            }
            rows("More pinned tabs", Array(pins.dropFirst(SidebarTabs.gridLimit)), limit: limit, duplicates: duplicateTitles)
            rows("Tabs", regular, limit: limit, duplicates: duplicateTitles)
            rows("Private", privateRows, limit: limit, duplicates: duplicateTitles)
            if preview.rows.isEmpty { SidebarSectionHeading(title: "No tabs", count: 0, marksGeometry: false) }
        }.fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func rows(_ title: String, _ rows: [ProfileSidebarPreview.Row],
                                   limit: Int, duplicates: Set<String>) -> some View {
        if !rows.isEmpty {
            SidebarSectionHeading(title: title, count: rows.count, marksGeometry: false)
            VStack(spacing: 1) {
                ForEach(rows.prefix(limit)) { row in
                    artwork(row, tile: false, duplicateTitles: duplicates).frame(height: textSize.isAccessibilitySize ? 60 : 36)
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
