import BrowserCore
import BrowserEngine
import SwiftUI

/// Selective shared metrics. Deliberate platform geometry (including hit targets) stays local.
enum OrivSpacing {
    static let xs: CGFloat = 4
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let large: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

enum OrivRadius {
    static let compact: CGFloat = 6
    static let small: CGFloat = 8
    static let medium: CGFloat = 10
    static let popover: CGFloat = 12
    static let large: CGFloat = 14
    // Capsule shapes use Capsule(), rather than a radius tied to a particular height.
}

/// Mac's compact scale and iPhone's native, scalable text styles.
enum OrivType {
    #if os(macOS)
    static let body: Font = .system(size: 13)
    static let detail: Font = .system(size: 12)
    static let caption: Font = .system(size: 11)
    static let title: Font = .system(size: 15, weight: .semibold)
    static let profile: Font = .system(size: 17, weight: .semibold)
    #else
    static let body: Font = .body
    static let detail: Font = .footnote
    static let caption: Font = .caption
    static let title: Font = .headline
    #endif
}

/// Shared by the Mac and iPhone targets. Existing stored appearance names remain valid.
enum BrowserAppearance: String, CaseIterable, Identifiable {
    case system = "System", light = "Light", dark = "Dark", t3Code = "T3 Code"
    var id: String { rawValue }
    var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark, .t3Code: .dark }
    }
    var theme: Theme { self == .t3Code ? .t3Code : .graphite }

    /// Read profile defaults without writing a choice for unset or unrecognized values.
    static func saved(_ value: String?) -> BrowserAppearance {
        value.flatMap(Self.init(rawValue:)) ?? .system
    }
}

/// Color roles are scoped to the owning window, sheet or preview.
struct Theme {
    struct SidebarPalette {
        let backing: Color
        let field: Color
        let selection: Color
        let hover: Color
    }

    let isT3Code: Bool
    let canvas: Color
    let surface: Color
    let row: Color
    let field: Color
    let chrome: Color
    var separator: Color
    let text: Color
    var secondaryText: Color
    let selection: Color
    let warning: Color
    let sidebar: SidebarPalette

    #if os(macOS)
    let accent = Color(nsColor: .controlAccentColor)
    #else
    let accent = Color.accentColor
    #endif
    #if os(macOS)
    // These roles stay legible across the brighter and darker glass inputs.
    private static let glassSecondary = adaptive("GlassSecondary", light: 0x303037, dark: 0xEEEEF2)
    private static let glassPrivate = adaptive("GlassPrivate", light: 0x4C2269, dark: 0xF8DEFF)
    func sidebarSecondaryText(_ contrast: ColorSchemeContrast) -> Color {
        guard contrast == .increased else { return Self.glassSecondary }
        return isT3Code ? Self.hex(0xB8B8B8) : Self.highContrastSecondary
    }
    var sidebarPrivateAccent: Color { Self.glassPrivate }
    #endif

    var fieldText: Color { secondaryText }
    var page: Color { canvas }

    /// Preserve the system hue while meeting the 3:1 requirement on app-drawn selections.
    func markerAccent(on background: Color.Resolved, in environment: EnvironmentValues) -> Color {
        let resolved = accent.resolve(in: environment)
        let base = Self.luminance(background)
        let foreground = Self.luminance(resolved)
        let minimum: Float = 3.1
        guard (max(base, foreground) + 0.05) / (min(base, foreground) + 0.05) < minimum else { return accent }
        let darken = base >= 0.30
        let target = darken ? (base + 0.05) / minimum - 0.05 : (base + 0.05) * minimum - 0.05
        let endpoint: Float = darken ? 0 : 1
        let amount = (target - foreground) / (endpoint - foreground)
        return Color(.sRGBLinear,
                     red: Double(resolved.linearRed + (endpoint - resolved.linearRed) * amount),
                     green: Double(resolved.linearGreen + (endpoint - resolved.linearGreen) * amount),
                     blue: Double(resolved.linearBlue + (endpoint - resolved.linearBlue) * amount))
    }

    static func luminance(_ color: Color.Resolved) -> Float {
        0.2126 * color.linearRed + 0.7152 * color.linearGreen + 0.0722 * color.linearBlue
    }

    static let privateLight = hex(0x713692)
    static let privateDark = hex(0xD5AAF8)
    let privateAccent = adaptive("Private", light: 0x713692, dark: 0xD5AAF8)

    static let t3Code = Theme(isT3Code: true, canvas: hex(0x000000),
        surface: hex(0x111111), row: hex(0x111111), field: hex(0x1E1E1E), chrome: hex(0x0A0A0A), separator: hex(0x191919),
        text: hex(0xF5F5F5), secondaryText: hex(0xA3A3A3), selection: hex(0x1C1C1C),
        warning: hex(0xD9A04A),
        sidebar: SidebarPalette(backing: hex(0x0A0A0A), field: hex(0x1E1E1E),
                               selection: hex(0x1C1C1C), hover: hex(0x171717)))

    static let graphite = Theme(isT3Code: false,
        canvas: adaptive("Canvas", light: 0xFFFFFF, dark: 0x1C1C1E),
        surface: adaptive("Surface", light: 0xF5F5F7, dark: 0x242426),
        row: adaptive("Row", light: 0xFFFFFF, dark: 0x2E2E30),
        field: adaptive("Field", light: 0xE6E6EA, dark: 0x323236),
        chrome: adaptive("Chrome", light: 0xF0F0F3, dark: 0x252528),
        separator: adaptive("Separator", light: 0xC9C9CF, dark: 0x48484D),
        text: adaptive("Text", light: 0x1D1D1F, dark: 0xF5F5F7),
        secondaryText: adaptive("Secondary", light: 0x4E4E54, dark: 0xC2C2C8),
        selection: adaptive("Selection", light: 0xDEDEE3, dark: 0x3D3D42),
        warning: adaptive("Warning", light: 0x794900, dark: 0xE0AA55),
        sidebar: SidebarPalette(
            backing: adaptive("SidebarBacking", light: 0xF0F0F3, dark: 0x252528),
            field: adaptive("SidebarField", light: 0xE6E6EA, dark: 0x323236),
            selection: adaptive("SidebarSelection", light: 0xDEDEE3, dark: 0x3D3D42),
            hover: adaptive("SidebarHover", light: 0xE7E7EB, dark: 0x303034)))

    func respecting(_ contrast: ColorSchemeContrast) -> Theme {
        guard contrast == .increased else { return self }
        var palette = self
        palette.separator = isT3Code ? Self.hex(0x818181) : Self.highContrastSeparator
        palette.secondaryText = isT3Code ? Self.hex(0xB8B8B8) : Self.highContrastSecondary
        return palette
    }

    private static let highContrastSeparator = adaptive("StrongSeparator", light: 0x646469, dark: 0xA3A3A9)
    private static let highContrastSecondary = adaptive("StrongSecondary", light: 0x36363B, dark: 0xD9D9DD)

    private static func hex(_ value: UInt32) -> Color {
        Color(.sRGB, red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255,
              blue: Double(value & 255) / 255, opacity: 1)
    }
    static func adaptive(_ name: String, light: UInt32, dark: UInt32) -> Color {
        #if os(macOS)
        Color(nsColor: NSColor(name: name) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        })
        #else
        Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        })
        #endif
    }
}

private struct BrowserThemeKey: EnvironmentKey { static let defaultValue: Theme = .graphite }
extension EnvironmentValues {
    var browserTheme: Theme {
        get { self[BrowserThemeKey.self] }
        set { self[BrowserThemeKey.self] = newValue }
    }
}

private struct BrowserAppearanceModifier: ViewModifier {
    let appearance: BrowserAppearance
    var followsPage = false
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        let theme = appearance.theme.respecting(contrast)
        content.environment(\.browserTheme, theme)
            .preferredColorScheme(followsPage ? nil : appearance.colorScheme)
            .tint(theme.accent)
            #if os(iOS)
            .background(theme.canvas)
            #endif
            .transaction { transaction in
                if reduceMotion { transaction.animation = nil; transaction.disablesAnimations = true }
            }
            #if os(iOS)
            .toolbarBackground(theme.chrome, for: .navigationBar, .tabBar)
            .toolbarBackground((theme.isT3Code || reduceTransparency) ? .visible : .automatic, for: .navigationBar, .tabBar)
            #endif
    }
}

/// Row titles stay on one line at standard sizes and may wrap to two at accessibility text sizes.
private struct RowTitleLines: ViewModifier {
    @Environment(\.dynamicTypeSize) private var size
    func body(content: Content) -> some View { content.lineLimit(size.isAccessibilitySize ? 2 : 1) }
}

extension View {
    func rowTitleLines() -> some View { modifier(RowTitleLines()) }

    func browserAppearance(_ appearance: BrowserAppearance, followsPage: Bool = false) -> some View {
        modifier(BrowserAppearanceModifier(appearance: appearance, followsPage: followsPage))
    }
}

/// Both settings screens render their samples from the same palette as the live browser.
struct AppearancePreview: View {
    let choice: BrowserAppearance
    @Environment(\.colorScheme) private var systemScheme
    var body: some View {
        PreviewContent().environment(\.browserTheme, choice.theme)
            .environment(\.colorScheme, choice.colorScheme ?? systemScheme)
            .accessibilityHidden(true)
    }
    private struct PreviewContent: View {
        @Environment(\.browserTheme) private var theme
        var body: some View {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Circle().fill(theme.accent).frame(width: 8, height: 8)
                    RoundedRectangle(cornerRadius: 2).fill(theme.secondaryText.opacity(0.5)).frame(height: 4)
                    RoundedRectangle(cornerRadius: 2).fill(theme.secondaryText.opacity(0.3)).frame(height: 4)
                    Spacer()
                }.padding(OrivSpacing.small).frame(width: 36).background(theme.canvas)
                VStack(alignment: .leading, spacing: OrivSpacing.small) {
                    Capsule().fill(theme.field).frame(height: 8)
                    RoundedRectangle(cornerRadius: 2).fill(theme.accent).frame(width: 32, height: 5)
                    RoundedRectangle(cornerRadius: 2).fill(theme.secondaryText.opacity(0.4)).frame(height: 3)
                    Spacer()
                }.padding(OrivSpacing.small).frame(maxWidth: .infinity)
            }.frame(height: 78).background(theme.page).clipShape(.rect(cornerRadius: OrivRadius.small))
                .overlay { RoundedRectangle(cornerRadius: OrivRadius.small).strokeBorder(theme.separator, lineWidth: 1) }
        }
    }
}

/// Marks a suggestion that switches to an open tab instead of loading the page again.
struct SwitchToTabBadge: View {
    @Environment(\.browserTheme) private var theme
    var body: some View {
        Text("Already open").font(.caption2.weight(.medium)).foregroundStyle(theme.secondaryText).lineLimit(1).fixedSize()
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(theme.field, in: Capsule())
            .accessibilityLabel("Already open in a tab")
    }
}

/// The system-accent marker identifies the active row at its leading edge.
struct SelectionMarker: View {
    @Environment(\.browserTheme) private var theme
    @Environment(\.self) private var environment
    var height: CGFloat = 16
    var background: Color? = nil

    var body: some View {
        let surface = (background ?? theme.selection).resolve(in: environment)
        Capsule().fill(theme.markerAccent(on: surface, in: environment))
            .frame(width: 3, height: height).accessibilityHidden(true)
    }
}

/// Selected-row background with the leading marker, for lists that draw their own selection.
struct SelectedRowBackground: View {
    @Environment(\.browserTheme) private var theme
    var cornerRadius: CGFloat = OrivRadius.small
    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius).fill(theme.selection)
            .overlay(alignment: .leading) { SelectionMarker().padding(.leading, 2) }
    }
}

/// Site-owned favicons, with a local monogram while unavailable.
struct SiteIdentity: View {
    @Environment(\.siteIcons) private var icons
    @Environment(\.browserTheme) private var theme
    var url: URL?
    var size: CGFloat = 32
    var isPrivate = false
    var isSelected = false
    var sidebarIcon = false
    var cachedOnly = false
    var previewIcons: [String: SiteIcon]? = nil
    @Environment(\.colorScheme) private var colorScheme

    /// The site's own name (apple in developer.apple.com), not a subdomain such as en. or www.
    private var host: String {
        SiteMonogram.label(for: url?.host()) ?? ""
    }
    private var symbol: String? {
        if isPrivate { return "eyeglasses" }
        if url == nil || host.isEmpty || sidebarIcon { return "globe" }
        if host.first?.isLetter != true { return "globe" }
        return nil
    }
    private var icon: SiteIcon? {
        if let previewIcons {
            guard let url, let key = SiteIconStore.key(url, isPrivate: isPrivate) else { return nil }
            return previewIcons[key]
        }
        return icons?.icon(for: url, isPrivate: isPrivate)
    }

    var body: some View {
        ZStack {
            if let icon, sidebarIcon {
                // Opaque artwork is full bleed. Transparent glyphs get a plate
                // only when their dominant luminance would disappear on the panel.
                if let lightPlate = icon.lightPlate(onDark: colorScheme == .dark, selected: isSelected) {
                    RoundedRectangle(cornerRadius: size * 0.2).fill(lightPlate ? Color.white : Color(white: 0.10))
                }
                Image(decorative: icon.image, scale: 2).resizable().scaledToFit()
                    .clipShape(.rect(cornerRadius: size * 0.2))
            } else if let image = icon?.image {
                RoundedRectangle(cornerRadius: size * 0.27).fill(theme.field)
                // A pale plate keeps black/transparent monochrome marks readable
                // on dark sidebar material as well as light surfaces.
                RoundedRectangle(cornerRadius: size * 0.2).fill(Color.white.opacity(0.88)).padding(1)
                Image(decorative: image, scale: 2).resizable().scaledToFit().padding(size * 0.12)
            } else if let symbol {
                RoundedRectangle(cornerRadius: size * (sidebarIcon ? 0.2 : 0.27)).fill(theme.field)
                Image(systemName: symbol).font(.system(size: size * 0.42, weight: .medium))
            } else {
                RoundedRectangle(cornerRadius: size * (sidebarIcon ? 0.2 : 0.27)).fill(theme.field)
                Text(String(host.prefix(1)).uppercased())
                    #if os(macOS)
                    .font(.system(size: size * 0.46, weight: .semibold, design: .rounded))
                    #else
                    .font(.system(.footnote, design: .rounded, weight: .semibold))
                    // Decorative identity stays within its icon; readable row text scales separately.
                    .dynamicTypeSize(.large)
                    #endif
            }
        }
        .foregroundStyle(isPrivate ? theme.privateAccent : (isSelected ? theme.text : theme.secondaryText))
        .frame(width: size, height: size)
        .task(id: "\(url?.absoluteString ?? "")-\(isPrivate)-\((!sidebarIcon && !cachedOnly && url.flatMap { icons?.document?($0, isPrivate) } != nil))") {
            // Sidebar and start-page tiles are cache-only. The
            // session's completed-document path discovers icons. Sleeping
            // regular rows may hydrate their own profile's disk cache only.
            if let url, previewIcons == nil {
                if sidebarIcon || cachedOnly {
                    if !isPrivate { await icons?.loadCached(url) }
                } else { await icons?.load(url, isPrivate: isPrivate) }
            }
        }
        .accessibilityHidden(true)
    }
}

extension View {
    /// Shared list and form backdrop for app-owned rows.
    func orivListStyle(_ theme: Theme) -> some View {
        scrollContentBackground(.hidden).background(theme.surface)
    }
}

/// The address line under a row's title (see `URLDisplay`). Pass the list's context so rows
/// with the same title gain just enough path or query to be told apart.
func secondaryLine(title: String, url: URL?, in context: URLDisplay.Context? = nil) -> String? {
    if let context { return context.secondaryLine(title: title, url: url) }
    return URLDisplay.secondaryLine(title: title, url: url)
}
