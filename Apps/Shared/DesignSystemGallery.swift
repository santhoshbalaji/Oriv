#if DEBUG
import SwiftUI

/// A snapshot fixture for the tokens and shared components shipped in the app.
struct DesignSystemGallery: View {
    @Environment(\.browserTheme) private var baseTheme
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.chromeContrastOverride) private var captureContrast
    private var contrast: ColorSchemeContrast { captureContrast ?? systemContrast }
    private var theme: Theme { baseTheme.respecting(contrast) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: OrivSpacing.large) {
                Text("Oriv design system").font(OrivType.windowTitle)
                palette
                typeScale
                VStack(alignment: .leading, spacing: OrivSpacing.medium) {
                    Label("Private browsing", systemImage: "eyeglasses").foregroundStyle(theme.private)
                        .padding(OrivSpacing.small).background(theme.privateWash, in: .rect(cornerRadius: OrivRadius.control))
                    Label("Not secure", systemImage: "exclamationmark.shield").foregroundStyle(theme.warning)
                    Label("Page unavailable", systemImage: "network.slash").foregroundStyle(theme.danger)
                    Label("Synced", systemImage: "checkmark.circle").foregroundStyle(theme.success)
                    HStack {
                        SiteIdentity(url: URL(string: "https://atlas.example"))
                        Text("Atlas").font(OrivType.bodyEmphasized)
                        Spacer()
                        Badge.alreadyOpen
                    }.padding(OrivSpacing.small).modifier(ListSelection(selected: true))
                    HStack {
                        Button("Continue") {}.orivButton(.primary)
                        Button("Cancel") {}.orivButton(.secondary)
                        Button(OrivStrings.deleteProfile, role: .destructive) {}.orivButton(.destructive)
                        Button("Unavailable") {}.orivButton(.quiet).disabled(true)
                    }
                    SettingRow(detail: "Private tabs are never restored.") {
                        Toggle("Restore tabs", isOn: .constant(true))
                    }
                    SettingRow(detail: "Unavailable for this session.") {
                        Toggle("Sync", isOn: .constant(false)).disabled(true)
                    }
                    #if os(macOS)
                    OrivSearchField(text: .constant(""), shortcut: "⇧⌘A", sidebar: true) {
                        TextField("Search tabs", text: .constant(""))
                    }
                    OrivSearchField(text: .constant("Atlas"), focused: true) {
                        TextField("Search bookmarks", text: .constant("Atlas"))
                    }
                    #endif
                    Text("Control").padding(OrivSpacing.medium).modifier(OrivMaterial.control())
                    Text("Overlay").padding(OrivSpacing.medium).modifier(OrivMaterial.overlay())
                }.modifier(OrivMaterial.sheet)
            }
            .foregroundStyle(theme.text)
            .padding(OrivSpacing.xl)
        }.background(theme.canvas)
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
