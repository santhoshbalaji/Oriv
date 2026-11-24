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
    static let sidebarSelectionRadius: CGFloat = 13
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

    static let sidebarKeyboardFocus = adaptive("SidebarKeyboardFocus", light: 0x0F172A, dark: 0xFFFFFF)

    struct SidebarChromaticTokens: Equatable {
        let top: UInt32
        let bottom: UInt32
        let bloom: UInt32
        let guardColor: UInt32
        let active: UInt32
        let ink: UInt32
        let rim: UInt32
        let opaqueActive: UInt32

        static func resolve(_ color: SidebarColor, profile: ProfileColor?, dark: Bool, black: Bool) -> Self {
            if black { return self.black }
            switch color.effective(profileColor: profile, isT3Code: false) {
            case .graphite: return dark ? graphiteDark : graphiteLight
            case .sky: return dark ? skyDark : skyLight
            case .rose: return dark ? roseDark : roseLight
            case .lavender: return dark ? lavenderDark : lavenderLight
            case .peach: return dark ? peachDark : peachLight
            case .butter: return dark ? butterDark : butterLight
            case .mint: return dark ? mintDark : mintLight
            case .sage: return dark ? sageDark : sageLight
            case .profile:
                switch profile {
                case .mulberry: return dark ? mulberryDark : mulberryLight
                case .ocean: return dark ? oceanDark : oceanLight
                case .fern: return dark ? fernDark : fernLight
                case .amber: return dark ? amberDark : amberLight
                case .slate: return dark ? slateDark : slateLight
                case nil: return dark ? graphiteDark : graphiteLight
                }
            }
        }

        // D3 reference colors. Peach, Butter, Mint, Sage and the five profile
        // colors extend the same light/dark roles to the full preference set.
        private static let graphiteLight = Self(top: 0xF2F4FA, bottom: 0xE6EAF3, bloom: 0x93C5FD, guardColor: 0xFFFFFF,
            active: 0xD4E6FF, ink: 0x0C3566, rim: 0x1D6FD1, opaqueActive: 0xC9E0FC)
        private static let graphiteDark = Self(top: 0x2A2F3D, bottom: 0x1E222E, bloom: 0x4E89E8, guardColor: 0x0E1118,
            active: 0x36659E, ink: 0xFFFFFF, rim: 0x99C7FF, opaqueActive: 0x2E5A8F)
        private static let skyLight = Self(top: 0xDCF1FF, bottom: 0xC4E5FF, bloom: 0x60B8FF, guardColor: 0xF2FAFF,
            active: 0xB3DCFF, ink: 0x07335E, rim: 0x0E74D1, opaqueActive: 0xABD7FC)
        private static let skyDark = Self(top: 0x28527D, bottom: 0x1B3857, bloom: 0x4AA3FF, guardColor: 0x0C1D30,
            active: 0x2D6AAC, ink: 0xFFFFFF, rim: 0x9DD4FF, opaqueActive: 0x275C96)
        private static let roseLight = Self(top: 0xFFE3EF, bottom: 0xFCCBDD, bloom: 0xFF8CBA, guardColor: 0xFFF5F9,
            active: 0xFFC0D9, ink: 0x5E0F32, rim: 0xC92A6A, opaqueActive: 0xFBB6D2)
        private static let roseDark = Self(top: 0x693150, bottom: 0x4D223B, bloom: 0xF06CA3, guardColor: 0x260E1C,
            active: 0x9E3B6B, ink: 0xFFFFFF, rim: 0xFFB8D6, opaqueActive: 0x8C325E)
        private static let lavenderLight = Self(top: 0xECE3FF, bottom: 0xDACBFF, bloom: 0xB794FF, guardColor: 0xF8F5FF,
            active: 0xD2BFFF, ink: 0x311366, rim: 0x6F3FD1, opaqueActive: 0xCAB5FC)
        private static let lavenderDark = Self(top: 0x4F3878, bottom: 0x392759, bloom: 0xA67CFF, guardColor: 0x1A112E,
            active: 0x6947B0, ink: 0xFFFFFF, rim: 0xD8C7FF, opaqueActive: 0x5C3D9E)
        private static let peachLight = Self(top: 0xFFE7DA, bottom: 0xFAD4C0, bloom: 0xFFA37D, guardColor: 0xFFF6F0,
            active: 0xFFC8AA, ink: 0x602811, rim: 0xC24F20, opaqueActive: 0xFCC0A0)
        private static let peachDark = Self(top: 0x683B2D, bottom: 0x482B22, bloom: 0xFA9168, guardColor: 0x27150F,
            active: 0x9C4E38, ink: 0xFFFFFF, rim: 0xFFBB9F, opaqueActive: 0x8D422F)
        private static let butterLight = Self(top: 0xFFF3CA, bottom: 0xF9E6AC, bloom: 0xF4CF5D, guardColor: 0xFFFBF0,
            active: 0xFBE196, ink: 0x4F3507, rim: 0x956209, opaqueActive: 0xF6D986)
        private static let butterDark = Self(top: 0x59451F, bottom: 0x3D3118, bloom: 0xD9AE4C, guardColor: 0x241B0A,
            active: 0x826020, ink: 0xFFFFFF, rim: 0xF9D38C, opaqueActive: 0x745319)
        private static let mintLight = Self(top: 0xD8F5E8, bottom: 0xC1ECDA, bloom: 0x63DDB7, guardColor: 0xF0FFF8,
            active: 0xA9E8D2, ink: 0x0A4738, rim: 0x127C68, opaqueActive: 0x9EE1CB)
        private static let mintDark = Self(top: 0x235345, bottom: 0x163C31, bloom: 0x53CDA8, guardColor: 0x0A241C,
            active: 0x267359, ink: 0xFFFFFF, rim: 0x9CEDD1, opaqueActive: 0x20644E)
        private static let sageLight = Self(top: 0xE2EED2, bottom: 0xCFE2BA, bloom: 0xB0D883, guardColor: 0xF7FBEF,
            active: 0xC7E3A4, ink: 0x2C4119, rim: 0x50752D, opaqueActive: 0xBEDB96)
        private static let sageDark = Self(top: 0x445333, bottom: 0x2C3A22, bloom: 0xA5CB73, guardColor: 0x172010,
            active: 0x4E6933, ink: 0xFFFFFF, rim: 0xCFE9AA, opaqueActive: 0x4B6530)
        private static let mulberryLight = Self(top: 0xF6DFF3, bottom: 0xEBCBE9, bloom: 0xDB92DE, guardColor: 0xFFF5FE,
            active: 0xF1C1EF, ink: 0x501855, rim: 0x923D96, opaqueActive: 0xEAB5E8)
        private static let mulberryDark = Self(top: 0x603259, bottom: 0x42213E, bloom: 0xD278D1, guardColor: 0x251021,
            active: 0x863E82, ink: 0xFFFFFF, rim: 0xEFB8ED, opaqueActive: 0x77346F)
        private static let oceanLight = Self(top: 0xD4EEFD, bottom: 0xBDDEF7, bloom: 0x68BCF3, guardColor: 0xF1FAFF,
            active: 0xB4DFFF, ink: 0x0D395E, rim: 0x2275B8, opaqueActive: 0xA7D5F8)
        private static let oceanDark = Self(top: 0x284D74, bottom: 0x1A344E, bloom: 0x589AE6, guardColor: 0x0F1D30,
            active: 0x3367A0, ink: 0xFFFFFF, rim: 0xABD4FF, opaqueActive: 0x2C5A90)
        private static let fernLight = Self(top: 0xDCF3DA, bottom: 0xC7E7C5, bloom: 0x83D788, guardColor: 0xF3FFF2,
            active: 0xBDE7B8, ink: 0x1E4621, rim: 0x3A823E, opaqueActive: 0xB2DFAE)
        private static let fernDark = Self(top: 0x315137, bottom: 0x223B26, bloom: 0x75BE7D, guardColor: 0x122216,
            active: 0x3A6E42, ink: 0xFFFFFF, rim: 0xB4E7B7, opaqueActive: 0x356B3D)
        private static let amberLight = Self(top: 0xFDEBD1, bottom: 0xF5DCB8, bloom: 0xF9BA64, guardColor: 0xFFF9EF,
            active: 0xFFDAA1, ink: 0x5D360A, rim: 0xB36E1D, opaqueActive: 0xF9D194)
        private static let amberDark = Self(top: 0x634325, bottom: 0x47301E, bloom: 0xEAA452, guardColor: 0x291A0D,
            active: 0x955926, ink: 0xFFFFFF, rim: 0xFFCC91, opaqueActive: 0x844B1E)
        private static let slateLight = Self(top: 0xE3EBF6, bottom: 0xCCD9EA, bloom: 0x94B6DB, guardColor: 0xF6FAFF,
            active: 0xCCDDF1, ink: 0x243C59, rim: 0x4E7095, opaqueActive: 0xC3D6EA)
        private static let slateDark = Self(top: 0x3B4B61, bottom: 0x283647, bloom: 0x7A9FCC, guardColor: 0x15202F,
            active: 0x4C6B91, ink: 0xFFFFFF, rim: 0xC3D9F2, opaqueActive: 0x405D81)
        private static let black = Self(top: 0x0A0A0A, bottom: 0x0A0A0A, bloom: 0x242830, guardColor: 0x000000,
            active: 0x292E37, ink: 0xF5F5F5, rim: 0xA3AFC0, opaqueActive: 0x252A32)
    }

    enum SidebarTone {
        case selection, hover, search

        // The contrast gate reads these values and composites them over all tint backings.
        private static let selectionTone = (light: 0.42, dark: 0.10)
        private static let hoverTone = (light: 0.05, dark: 0.045)
        private static let searchTone = (light: 0.06, dark: 0.06)

        private func opacity(dark: Bool) -> Double {
            let pair = switch self {
            case .selection: Self.selectionTone
            case .hover: Self.hoverTone
            case .search: Self.searchTone
            }
            return dark ? pair.dark : pair.light
        }

        func fill(in theme: Theme, dark: Bool, opaque: Bool) -> Color {
            if opaque || theme.isT3Code {
                switch self {
                case .selection: return theme.sidebar.selection
                case .hover: return theme.sidebar.hover
                case .search: return theme.sidebar.field
                }
            }
            return (dark || self == .selection ? Color.white : Color.black).opacity(opacity(dark: dark))
        }

        func blend(over backing: SIMD3<Double>, dark: Bool) -> SIMD3<Double> {
            SidebarChromaticStyle.blend(SIMD3(repeating: dark || self == .selection ? 1 : 0),
                                        over: backing, opacity: opacity(dark: dark))
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

    static func hex(_ value: UInt32) -> Color {
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

#if os(macOS)
/// Resolves the panel and the tab treatments from the same appearance and glass level.
struct SidebarChromaticStyle: Equatable {
    let tokens: Theme.SidebarChromaticTokens
    let dark: Bool
    let black: Bool
    let level: SidebarGlassOpacity
    let opaque: Bool
    let increased: Bool
    let panel: FaviconBacking
    let hoveredPanel: FaviconBacking
    let activePanel: FaviconBacking

    static let balancedBacking = (light: 0.62, dark: 0.72)
    static let balancedGuard = (light: 0.44, dark: 0.84)
    static let highBacking = 0.86
    static let blackBacking = (balanced: 0.86, high: 0.94)
    static let blackGuard = 0.36
    static let satinBloom = (light: 0.22, dark: 0.16)
    static let satinSheen = (light: 0.32, dark: 0.02)
    static let activeOpacity = (light: 0.92, dark: 0.86)
    static let cushionHue = (light: 0.07, dark: 0.10)
    static let lightFrost: UInt32 = 0xFFFFFF
    static let darkFrost: UInt32 = 0x10141D
    static let primaryInk = Theme.adaptive("SidebarPrimaryInk", light: 0x141822, dark: 0xFFFFFF)
    static let secondaryInk = Theme.adaptive("SidebarSecondaryInk", light: 0x2A3446, dark: 0xE8EFFA)
    static let bloomStart: CGFloat = 8
    static let bloomEnd: CGFloat = 230
    static let sheenEnd = UnitPoint(x: 0.5, y: 0.22)
    static let selectionRim: CGFloat = 1
    static let iconHairline: CGFloat = 0.5
    static let cushionInset: CGFloat = 2.5

    let backingOpacity: Double
    let guardOpacity: Double
    let bloomOpacity: Double
    let sheenOpacity: Double
    let selectionOpacity: Double

    var sheen: Color { .white.opacity(sheenOpacity) }
    var ink: Color { Theme.hex(tokens.ink) }
    var fill: Color { Theme.hex(opaque ? tokens.opaqueActive : tokens.active).opacity(selectionOpacity) }
    var rimTop: Color { dark ? Theme.hex(tokens.rim).opacity(0.65) : .white.opacity(0.92) }
    var rimBottom: Color { Theme.hex(tokens.rim).opacity(dark ? 0.22 : 0.34) }
    var glow: Color { Theme.hex(dark ? tokens.bloom : tokens.rim).opacity(dark ? 0.34 : 0.20) }
    var iconEdge: Color { dark ? .white.opacity(0.20) : .black.opacity(0.14) }

    func cushion(light: Bool) -> Color {
        Self.color(Self.cushion(light: light, bloom: tokens.bloom))
    }

    func selectionGlow<Content: View>(_ content: Content) -> some View {
        content.shadow(color: glow, radius: 6, y: 1.5)
    }

    init(color: SidebarColor = .graphite, profile: ProfileColor? = nil, level: SidebarGlassOpacity = .balanced,
         environment: EnvironmentValues, overlay: Bool = false) {
        let black = environment.browserTheme.isT3Code
        let dark = black || environment.colorScheme == .dark
        let increased = environment.sidebarContrast == .increased
        let opaque = environment.sidebarNeedsOpaqueChrome || level == .solid
        let tokens = Theme.SidebarChromaticTokens.resolve(color, profile: profile, dark: dark, black: black)
        self.tokens = tokens
        self.level = level
        self.dark = dark
        self.black = black
        self.increased = increased
        self.opaque = opaque

        let backingOpacity: Double
        switch level {
        case .balanced: backingOpacity = black ? Self.blackBacking.balanced : dark ? Self.balancedBacking.dark : Self.balancedBacking.light
        case .high: backingOpacity = black ? Self.blackBacking.high : Self.highBacking
        case .solid: backingOpacity = 1
        }
        let guardOpacity = black ? Self.blackGuard : dark ? Self.balancedGuard.dark : Self.balancedGuard.light
        let bloomOpacity = black ? 0 : dark ? Self.satinBloom.dark : Self.satinBloom.light
        let sheenOpacity = black ? 0 : dark ? Self.satinSheen.dark : Self.satinSheen.light
        let selectionOpacity = opaque ? 1 : dark ? Self.activeOpacity.dark : Self.activeOpacity.light
        self.backingOpacity = backingOpacity
        self.guardOpacity = guardOpacity
        self.bloomOpacity = bloomOpacity
        self.sheenOpacity = sheenOpacity
        self.selectionOpacity = selectionOpacity

        // The renderer can't inspect live Liquid Glass behind a row. Bound the
        // backing from the layers' minimum and maximum channel contributions.
        let quiet: SIMD3<Double>
        let bright: SIMD3<Double>
        if overlay {
            let surface = environment.browserTheme.surface.resolve(in: environment)
            quiet = SIMD3(Double(surface.red), Double(surface.green), Double(surface.blue))
            bright = quiet
        } else {
            let top = Self.rgb(tokens.top), bottom = Self.rgb(tokens.bottom)
            let lower = pointwiseMin(top, bottom), upper = pointwiseMax(top, bottom)
            if opaque {
                quiet = lower
                bright = upper
            } else {
                let white = SIMD3(repeating: 1.0)
                let guardRGB = Self.rgb(tokens.guardColor)
                let darkest = Self.blend(lower, over: guardRGB * guardOpacity, opacity: backingOpacity)
                let lightest = Self.blend(upper, over: Self.blend(guardRGB, over: white, opacity: guardOpacity),
                                          opacity: backingOpacity)
                let bloom = Self.rgb(tokens.bloom)
                quiet = pointwiseMin(darkest, Self.blend(bloom, over: darkest, opacity: bloomOpacity))
                let bloomed = pointwiseMax(lightest, Self.blend(bloom, over: lightest, opacity: bloomOpacity))
                bright = Self.blend(white, over: bloomed, opacity: sheenOpacity)
            }
        }
        let lightCushion = Self.luminance(Self.cushion(light: true, bloom: tokens.bloom))
        let darkCushion = Self.luminance(Self.cushion(light: false, bloom: tokens.bloom))
        func iconBacking(_ first: SIMD3<Double>, _ second: SIMD3<Double>) -> FaviconBacking {
            let a = Self.luminance(first), b = Self.luminance(second)
            return FaviconBacking(luminance: min(a, b)...max(a, b), lightCushion: lightCushion, darkCushion: darkCushion)
        }
        panel = iconBacking(quiet, bright)
        if opaque || black {
            let hover = environment.browserTheme.sidebar.hover.resolve(in: environment)
            let rgb = SIMD3(Double(hover.red), Double(hover.green), Double(hover.blue))
            hoveredPanel = iconBacking(rgb, rgb)
        } else {
            hoveredPanel = iconBacking(Theme.SidebarTone.hover.blend(over: quiet, dark: dark),
                                       Theme.SidebarTone.hover.blend(over: bright, dark: dark))
        }
        let active = Self.rgb(opaque ? tokens.opaqueActive : tokens.active)
        activePanel = iconBacking(Self.blend(active, over: quiet, opacity: selectionOpacity),
                                  Self.blend(active, over: bright, opacity: selectionOpacity))
    }

    fileprivate static func blend(_ front: SIMD3<Double>, over back: SIMD3<Double>, opacity: Double) -> SIMD3<Double> {
        front * opacity + back * (1 - opacity)
    }

    private static func rgb(_ hex: UInt32) -> SIMD3<Double> {
        SIMD3(Double((hex >> 16) & 255), Double((hex >> 8) & 255), Double(hex & 255)) / 255
    }

    private static func color(_ rgb: SIMD3<Double>) -> Color {
        Color(.sRGB, red: rgb.x, green: rgb.y, blue: rgb.z)
    }

    private static func luminance(_ rgb: SIMD3<Double>) -> Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.x) + 0.7152 * linear(rgb.y) + 0.0722 * linear(rgb.z)
    }

    private static func cushion(light: Bool, bloom: UInt32) -> SIMD3<Double> {
        blend(rgb(bloom), over: rgb(light ? lightFrost : darkFrost), opacity: light ? cushionHue.light : cushionHue.dark)
    }
}

extension EnvironmentValues {
    @Entry var sidebarChromaticStyle: SidebarChromaticStyle? = nil
    @Entry var sidebarRowHovered = false

    var sidebarStyle: SidebarChromaticStyle { sidebarChromaticStyle ?? SidebarChromaticStyle(environment: self) }
}
#endif

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
    var sidebarSelectedInk: Color? = nil
    #if os(macOS)
    @Environment(\.self) private var environment

    @ViewBuilder private func sidebarArtwork(_ icon: SiteIcon) -> some View {
        let style = environment.sidebarStyle
        let backing = isSelected ? style.activePanel : environment.sidebarRowHovered ? style.hoveredPanel : style.panel
        let image = Image(decorative: icon.image, scale: 2).resizable()
        let shape = RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
        switch icon.treatment(on: backing) {
        case .fullBleed(let hairline):
            image.scaledToFit().clipShape(shape).overlay {
                if hairline { shape.strokeBorder(style.iconEdge, lineWidth: SidebarChromaticStyle.iconHairline) }
            }
        case .bare:
            image.scaledToFit()
        case .ink:
            image.renderingMode(.template).scaledToFit()
                .foregroundStyle(isSelected ? style.ink : theme.text)
        case .cushion(let light):
            image.scaledToFit().padding(SidebarChromaticStyle.cushionInset)
                .background(style.cushion(light: light), in: shape)
                .overlay { shape.strokeBorder(style.iconEdge, lineWidth: SidebarChromaticStyle.iconHairline) }
        }
    }
    #endif

    @ViewBuilder private func favicon(_ icon: SiteIcon) -> some View {
        #if os(macOS)
        if sidebarIcon {
            sidebarArtwork(icon)
        } else {
            platedArtwork(icon)
        }
        #else
        platedArtwork(icon)
        #endif
    }

    private func platedArtwork(_ icon: SiteIcon) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.27).fill(theme.field)
            RoundedRectangle(cornerRadius: size * 0.2).fill(theme.iconPlate).padding(1)
            Image(decorative: icon.image, scale: 2).resizable().scaledToFit().padding(size * 0.12)
        }
    }

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
            if let icon = artwork {
                favicon(icon)
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
        .foregroundStyle(isPrivate ? theme.privateAccent : (sidebarSelectedInk ?? (isSelected ? theme.text : theme.secondaryText)))
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
