import BrowserCore
import BrowserEngine
import SwiftUI

enum OrivSpacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let large: CGFloat = 16
    static let larger: CGFloat = 20
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

enum OrivRadius {
    static let badge: CGFloat = 6
    static let control: CGFloat = 8
    static let tile: CGFloat = 10
    static let panel: CGFloat = 12
    static let card: CGFloat = 14
    static let thumbnail: CGFloat = 18
    static let capsule = Capsule()

    @available(*, deprecated, renamed: "badge")
    static var compact: CGFloat { badge }
    @available(*, deprecated, renamed: "control")
    static var small: CGFloat { control }
    @available(*, deprecated, renamed: "tile")
    static var medium: CGFloat { tile }
    @available(*, deprecated, renamed: "panel")
    static var popover: CGFloat { panel }
    @available(*, deprecated, renamed: "card")
    static var large: CGFloat { card }
}

enum OrivType {
    #if os(macOS)
    static let body: Font = .system(size: 13)
    static let detail: Font = .system(size: 12)
    static let caption: Font = .system(size: 11)
    static let title: Font = .system(size: 15, weight: .semibold)
    static let windowTitle: Font = .system(size: 17, weight: .semibold)
    static let headline: Font = .system(size: 13, weight: .semibold)
    static let bodyEmphasized: Font = .system(size: 13, weight: .medium)
    static let sectionLabel: Font = .system(size: 11, weight: .semibold)
    static let badge: Font = .system(size: 10, weight: .medium)
    #else
    static let body: Font = .body
    static let detail: Font = .footnote
    static let caption: Font = .caption
    static let title: Font = .headline
    static let windowTitle: Font = .title3.weight(.semibold)
    static let headline: Font = .subheadline.weight(.semibold)
    static let bodyEmphasized: Font = .body.weight(.medium)
    static let sectionLabel: Font = .footnote.weight(.semibold)
    static let badge: Font = .caption2.weight(.medium)
    #endif

    @available(*, deprecated, renamed: "windowTitle")
    static var profile: Font { windowTitle }
}

enum OrivLayout {
    static let tileMinimumHeight: CGFloat = 84
    #if os(macOS)
    static let sheetPadding = OrivSpacing.xl
    static let popoverPadding = OrivSpacing.large
    static let macAddressFontSize: CGFloat = 13
    static let sidebarWidth: CGFloat = 256
    static let railWidth: CGFloat = 72
    static let toolbarHeight: CGFloat = 50
    static let controlHeight: CGFloat = 32
    static let tabRowHeight: CGFloat = 32
    static let sidebarProfileHeight: CGFloat = 32
    static let sidebarProfileIconSize: CGFloat = 22
    static let sidebarSearchHeight: CGFloat = 28
    static let sidebarSectionHeight: CGFloat = 24
    static let sidebarPinWidth: CGFloat = 44
    static let sidebarPinHeight: CGFloat = 36
    static let sidebarPinGap = OrivSpacing.small - OrivSpacing.xxs
    static let sidebarPinIconSize: CGFloat = 20
    static let sidebarPinCloseWidth: CGFloat = 20
    static let sidebarPinCloseHeight = sidebarPinHeight / 2
    static let sidebarPinRadius: CGFloat = 10
    static let sidebarFooterHeight: CGFloat = 36
    static let sidebarDownloadBadgeSize: CGFloat = 6
    static let sidebarAccessoryWidth = OrivTarget.macMinimum.width
    static let sidebarBadgeSize: CGFloat = 12
    static let sidebarFaviconSize: CGFloat = 19
    static let sidebarRailFaviconSize: CGFloat = 22
    static let sidebarAccessibilityRowHeight: CGFloat = 60
    static let listRowHeight: CGFloat = 28
    static let suggestionRowHeight: CGFloat = 38
    static let rowInset = OrivSpacing.small
    static let contentMaxWidth: CGFloat = 640
    #else
    static let toolbarHeight: CGFloat = 48
    static let controlHeight: CGFloat = 44
    static let tabRowHeight: CGFloat = 44
    static let listRowHeight: CGFloat = 44
    static let suggestionRowHeight: CGFloat = 52
    static let rowInset = OrivSpacing.large
    static let contentMaxWidth: CGFloat = 650
    #endif
}

enum OrivMotion {
    static let quick = Animation.easeOut(duration: 0.10)
    static let standard = Animation.easeInOut(duration: 0.20)
    static let navigate = Animation.spring(response: 0.38, dampingFraction: 0.9)
    static let reduced = Animation.easeInOut(duration: 0.18)

    static func navigation(reduceMotion: Bool) -> Animation { reduceMotion ? reduced : navigate }
}

enum OrivOutline {
    static let hairline: CGFloat = 0.5
    static let enhanced: CGFloat = 1.5
    static let focus: CGFloat = 2
    static let focusInset: CGFloat = 4
}

enum OrivIcon {
    static let toolbar: CGFloat = 14
    static let toolbarFont = Font.system(size: toolbar)
    static let rail: CGFloat = 16
    static let footer = rail
    static let inline: CGFloat = 12
    static let close = Font.system(size: 11, weight: .semibold)
    static let bar: CGFloat = 21
    static let secondaryBar: CGFloat = 20
    static let barMaximum: CGFloat = 28

    static func barFont(scaledSize: CGFloat) -> Font {
        .system(size: min(scaledSize, barMaximum), weight: .medium)
    }
}

enum OrivTarget {
    static let macMinimum = CGSize(width: 24, height: 24)
    static let macToolbar = CGSize(width: 28, height: 28)
    static let macRail = CGSize(width: 42, height: 36)
    static let touch = CGSize(width: 44, height: 44)
    static let touchBar = CGSize(width: 48, height: 48)
}

enum OrivElevation: ViewModifier {
    case flat, overlay, drawer

    @ViewBuilder func body(content: Content) -> some View {
        switch self {
        case .flat: content
        case .overlay: content.shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        case .drawer: content.modifier(DrawerShadow())
        }
    }

    private struct DrawerShadow: ViewModifier {
        @Environment(\.layoutDirection) private var direction

        func body(content: Content) -> some View {
            content.shadow(color: .black.opacity(0.12), radius: 8, x: direction == .leftToRight ? 4 : -4)
        }
    }
}

enum OrivMaterial: ViewModifier {
    #if os(macOS)
    case navigation(color: SidebarColor = .graphite, profileColor: ProfileColor? = nil)
    #endif
    case control(radius: CGFloat? = nil)
    case overlay(radius: CGFloat = OrivRadius.panel)
    case sheet

    @ViewBuilder func body(content: Content) -> some View {
        switch self {
        #if os(macOS)
        case let .navigation(color, profileColor):
            content.modifier(MacSidebarGlass(color: color, profileColor: profileColor))
        #endif
        case let .control(radius):
            content.modifier(BrowserGlass(radius: radius))
        case let .overlay(radius):
            content.modifier(OverlaySurface(radius: radius))
        case .sheet:
            content
        }
    }

    private struct OverlaySurface: ViewModifier {
        @Environment(\.browserTheme) private var theme
        @Environment(\.colorSchemeContrast) private var systemContrast
        @Environment(\.chromeContrastOverride) private var captureContrast
        let radius: CGFloat

        func body(content: Content) -> some View {
            let shape = RoundedRectangle(cornerRadius: radius)
            content.background(theme.surface, in: shape)
                .overlay { shape.strokeBorder((captureContrast ?? systemContrast) == .increased ? theme.separatorStrong : theme.separator) }
                .modifier(OrivElevation.overlay)
        }
    }
}

/// Shared by the Mac and iPhone targets. Existing stored appearance names remain valid.
enum BrowserAppearance: String, CaseIterable, Identifiable {
    case system = "System", light = "Light", dark = "Dark", t3Code = "T3 Code"
    var id: String { rawValue }
    var displayName: String { self == .t3Code ? OrivStrings.black : rawValue }
    var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark, .t3Code: .dark }
    }
    var theme: Theme { self == .t3Code ? .t3Code : .graphite }

    /// Read profile defaults without writing a choice for unset or unrecognized values.
    static func saved(_ value: String?) -> BrowserAppearance {
        value.flatMap(Self.init(rawValue:)) ?? .system
    }
}

#if os(macOS)
extension ProfileColor {
    func sidebarInk(dark: Bool) -> Color {
        switch self {
        case .mulberry: Theme.hex(dark ? 0xE9B7EF : 0x692978)
        case .ocean: Theme.hex(dark ? 0x95C8FF : 0x215B9A)
        case .fern: Theme.hex(dark ? 0xA3D79A : 0x346738)
        case .amber: Theme.hex(dark ? 0xF4C17E : 0x845214)
        case .slate: Theme.hex(dark ? 0xB5C7D9 : 0x4B5D70)
        }
    }
}
#endif

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
    let surfaceRaised: Color
    let fill: Color
    let chrome: Color
    var separator: Color
    let text: Color
    var textSecondary: Color
    let fillSelected: Color
    let textTertiary: Color
    let warning: Color
    let sidebar: SidebarPalette

    #if os(macOS)
    let accent = Color(nsColor: .controlAccentColor)
    #else
    let accent = Color.accentColor
    #endif
    #if os(macOS)
    // These roles stay legible across the brighter and darker glass inputs.
    private static let glassSecondary = adaptive("GlassSecondary", light: 0x282830, dark: 0xEEEEF2)
    private static let glassPrivate = adaptive("GlassPrivate", light: 0x391552, dark: 0xFAEDFF)
    func sidebarSecondaryText(_ contrast: ColorSchemeContrast) -> Color {
        guard contrast == .increased else { return Self.glassSecondary }
        return isT3Code ? Self.hex(0xB8B8B8) : Self.highContrastSecondary
    }
    var sidebarPrivateAccent: Color { Self.glassPrivate }

    enum SidebarTone {
        case selection, hover, search, pinSelection

        // The contrast gate reads these values and composites them over all tint backings.
        private static let selectionTone = (light: 0.42, dark: 0.10)
        private static let hoverTone = (light: 0.045, dark: 0.04)
        private static let searchTone = (light: 0.06, dark: 0.07)
        private static let pinSelectionTone = (light: 0.16, dark: 0.08)

        func fill(in theme: Theme, dark: Bool, opaque: Bool) -> Color {
            let opacity: (light: Double, dark: Double)
            let solid: Color
            switch self {
            case .selection: (opacity, solid) = (Self.selectionTone, theme.sidebar.selection)
            case .hover: (opacity, solid) = (Self.hoverTone, theme.sidebar.hover)
            case .search: (opacity, solid) = (Self.searchTone, theme.sidebar.field)
            case .pinSelection: (opacity, solid) = (Self.pinSelectionTone, theme.sidebar.selection)
            }
            if opaque || theme.isT3Code { return solid }
            let white = dark || self == .selection || self == .pinSelection
            return (white ? Color.white : Color.black).opacity(dark ? opacity.dark : opacity.light)
        }
    }

    func sidebarRim(dark: Bool, opaque: Bool) -> Color {
        opaque ? separatorStrong : Color.white.opacity(dark ? 0.16 : 0.55)
    }

    #endif

    var fillHover: Color { sidebar.hover }
    var separatorStrong: Color { isT3Code ? Self.hex(0x818181) : Self.highContrastSeparator }
    let danger = adaptive("Danger", light: 0xB3261E, dark: 0xFF9A8F)
    let success = adaptive("Success", light: 0x1D6B3A, dark: 0x7FD99A)
    let controlPrivate = adaptive("ControlPrivate", light: 0x391552, dark: 0xFAEDFF)
    let privateWash = adaptive("PrivateWash", light: 0xF3E9F9, dark: 0x33263D)
    let iconPlate = Color.white.opacity(0.88)

    @available(*, deprecated, renamed: "surfaceRaised")
    var row: Color { surfaceRaised }
    @available(*, deprecated, renamed: "fill")
    var field: Color { fill }
    @available(*, deprecated, renamed: "fillSelected")
    var selection: Color { fillSelected }
    @available(*, deprecated, renamed: "textSecondary")
    var secondaryText: Color { textSecondary }
    @available(*, deprecated, renamed: "textSecondary")
    var fieldText: Color { textSecondary }
    @available(*, deprecated, renamed: "canvas")
    var page: Color { canvas }
    @available(*, deprecated, message: "Use the private color role.")
    var privateAccent: Color { self.private }

    func onAccent(for resolvedAccent: Color.Resolved) -> Color {
        Self.luminance(resolvedAccent) < sqrt(1.05 * 0.05) - 0.05 ? .white : .black
    }

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
    let `private` = adaptive("Private", light: 0x713692, dark: 0xD5AAF8)

    static let t3Code = Theme(isT3Code: true, canvas: hex(0x000000),
        surface: hex(0x111111), surfaceRaised: hex(0x111111), fill: hex(0x1E1E1E), chrome: hex(0x0A0A0A), separator: hex(0x191919),
        text: hex(0xF5F5F5), textSecondary: hex(0xA3A3A3), fillSelected: hex(0x1C1C1C),
        textTertiary: hex(0x8A8A8A),
        warning: hex(0xD9A04A),
        sidebar: SidebarPalette(backing: hex(0x0A0A0A), field: hex(0x1E1E1E),
                               selection: hex(0x1C1C1C), hover: hex(0x171717)))

    static let graphite = Theme(isT3Code: false,
        canvas: adaptive("Canvas", light: 0xFFFFFF, dark: 0x1C1C1E),
        surface: adaptive("Surface", light: 0xF5F5F7, dark: 0x242426),
        surfaceRaised: adaptive("Row", light: 0xFFFFFF, dark: 0x2E2E30),
        fill: adaptive("Field", light: 0xE6E6EA, dark: 0x323236),
        chrome: adaptive("Chrome", light: 0xF0F0F3, dark: 0x252528),
        separator: adaptive("Separator", light: 0xC9C9CF, dark: 0x48484D),
        text: adaptive("Text", light: 0x1D1D1F, dark: 0xF5F5F7),
        textSecondary: adaptive("Secondary", light: 0x4E4E54, dark: 0xC2C2C8),
        fillSelected: adaptive("Selection", light: 0xDEDEE3, dark: 0x3D3D42),
        textTertiary: adaptive("Tertiary", light: 0x6A6A70, dark: 0xA1A1A8),
        warning: adaptive("Warning", light: 0x794900, dark: 0xE0AA55),
        sidebar: SidebarPalette(
            backing: adaptive("SidebarBacking", light: 0xF0F0F3, dark: 0x252528),
            field: adaptive("SidebarField", light: 0xE6E6EA, dark: 0x323236),
            selection: adaptive("SidebarSelection", light: 0xDEDEE3, dark: 0x3D3D42),
            hover: adaptive("SidebarHover", light: 0xE7E7EB, dark: 0x303034)))

    func respecting(_ contrast: ColorSchemeContrast) -> Theme {
        guard contrast == .increased else { return self }
        var palette = self
        palette.separator = separatorStrong
        palette.textSecondary = isT3Code ? Self.hex(0xB8B8B8) : Self.highContrastSecondary
        return palette
    }

    private static let highContrastSeparator = adaptive("StrongSeparator", light: 0x646469, dark: 0xA3A3A9)
    private static let highContrastSecondary = adaptive("StrongSecondary", light: 0x36363B, dark: 0xD9D9DD)

    fileprivate static func hex(_ value: UInt32) -> Color {
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

/// Site-owned favicons, with a local monogram while unavailable.
struct SiteIdentity: View {
    @Environment(\.siteIcons) private var icons
    @Environment(\.browserTheme) private var theme
    var url: URL?
    var size: CGFloat = 32
    var isPrivate = false
    var isSelected = false
    var sidebarIcon = false
    var showsSidebarPrivateBadge = false
    var cachedOnly = false
    var previewIcons: [String: SiteIcon]? = nil
    @Environment(\.colorScheme) private var colorScheme

    /// The site's own name (apple in developer.apple.com), not a subdomain such as en. or www.
    private var host: String {
        SiteMonogram.label(for: url?.host()) ?? ""
    }
    private var symbol: String? {
        if isPrivate { return "eyeglasses" }
        if url == nil && sidebarIcon { return "magnifyingglass" }
        if url == nil || host.isEmpty { return "globe" }
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
        let artwork = icon
        return ZStack {
            if let icon = artwork, sidebarIcon {
                // Opaque artwork is full bleed. Transparent glyphs get a plate
                // only when their dominant luminance would disappear on the panel.
                if let lightPlate = icon.lightPlate(onDark: colorScheme == .dark, selected: isSelected) {
                    RoundedRectangle(cornerRadius: size * 0.2).fill(lightPlate ? Color.white : Color(white: 0.10))
                }
                Image(decorative: icon.image, scale: 2).resizable().scaledToFit()
                    .clipShape(.rect(cornerRadius: size * 0.2))
            } else if let image = artwork?.image {
                RoundedRectangle(cornerRadius: size * 0.27).fill(theme.field)
                // A pale plate keeps black/transparent monochrome marks readable
                // on dark sidebar material as well as light surfaces.
                RoundedRectangle(cornerRadius: size * 0.2).fill(theme.iconPlate).padding(1)
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
        #if os(macOS)
        .overlay(alignment: .topTrailing) {
            if sidebarIcon && showsSidebarPrivateBadge && isPrivate && artwork != nil {
                Image(systemName: "eyeglasses").resizable().scaledToFit()
                    .padding(OrivSpacing.xxs)
                    .frame(width: OrivLayout.sidebarBadgeSize, height: OrivLayout.sidebarBadgeSize)
                    .foregroundStyle(theme.sidebarPrivateAccent)
                    .background(theme.surface, in: Circle())
                    .accessibilityHidden(true)
            }
        }
        #endif
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
