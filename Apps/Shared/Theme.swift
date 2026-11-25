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
    case navigation(color: SidebarColor = .graphite, profileColor: ProfileColor? = nil, isPrivateWindow: Bool = false)
    #endif
    case control(radius: CGFloat? = nil)
    case overlay(radius: CGFloat = OrivRadius.panel)
    case sheet

    @ViewBuilder func body(content: Content) -> some View {
        switch self {
        #if os(macOS)
        case let .navigation(color, profileColor, isPrivateWindow):
            content.modifier(MacSidebarGlass(color: color, profileColor: profileColor, isPrivateWindow: isPrivateWindow))
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
        private static let selectionTone = (light: 0.42, dark: 0.06)
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

    static let balancedBacking = (light: 0.65, dark: 0.65)
    static let balancedGuard = (light: 0.65, dark: 0.65)
    static let highBacking = 0.86
    static let blackBacking = (balanced: 0.86, high: 0.94)
    static let blackGuard = 0.36
    static let satinBloom = (light: 0.055, dark: 0.055)
    static let satinSheen = (light: 0.025, dark: 0.025)
    static let activeOpacity = (light: 0.43, dark: 0.43)
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
    var rimTop: Color { dark ? Theme.hex(tokens.rim).opacity(0.38) : .white.opacity(0.60) }
    var rimBottom: Color { Theme.hex(tokens.rim).opacity(dark ? 0.14 : 0.24) }
    var glow: Color { Theme.hex(dark ? tokens.bloom : tokens.rim).opacity(dark ? 0.13 : 0.09) }
    var iconEdge: Color { dark ? .white.opacity(0.20) : .black.opacity(0.14) }

    func cushion(light: Bool) -> Color {
        Self.color(Self.cushion(light: light, bloom: tokens.bloom))
    }

    func selectionGlow<Content: View>(_ content: Content) -> some View {
        content.shadow(color: glow, radius: 4, y: 1)
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
#if os(macOS)
extension EnvironmentValues {
    @Entry var sidebarDefersIconHydration: ((URL) -> Bool)? = nil
}
#endif

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
                    #if os(macOS)
                    if sidebarIcon && !isPrivate && environment.sidebarDefersIconHydration?(url) == true { return }
                    #endif
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

#if os(macOS)
/// Design v3 token system and Liquid Glass recipes for macOS 26.
/// Existing `Theme`, `OrivSpacing`, `OrivRadius`, `OrivType`, `OrivLayout`,
/// `OrivMotion`, `OrivElevation`, and `OrivMaterial` symbols stay untouched so
/// iPhone and unmodified Mac views keep compiling without change.
enum OrivMacV3 {
    enum AppearanceMode: String, CaseIterable {
        case light, dark, black, `private`

        static func resolve(theme: Theme, colorScheme: ColorScheme, isPrivateWindow: Bool = false) -> Self {
            if isPrivateWindow { return .private }
            if theme.isT3Code { return .black }
            return colorScheme == .dark ? .dark : .light
        }

        var isDark: Bool { self != .light }
    }

    struct ShadowSpec: Equatable {
        let color: Color
        let radius: CGFloat
        let x: CGFloat
        let y: CGFloat

        init(color: Color, radius: CGFloat, x: CGFloat = 0, y: CGFloat = 0) {
            self.color = color
            self.radius = radius
            self.x = x
            self.y = y
        }
    }

    struct DualShadow: Equatable {
        let primary: ShadowSpec?
        let secondary: ShadowSpec?

        static let none = DualShadow(primary: nil, secondary: nil)

        init(primary: ShadowSpec?, secondary: ShadowSpec? = nil) {
            self.primary = primary
            self.secondary = secondary
        }
    }

    struct RadialGlow: Equatable {
        let hex: UInt32
        let opacity: Double
        let center: UnitPoint
        let radiusFraction: CGFloat

        var color: Color { Theme.hex(hex).opacity(opacity) }
    }

    /// Dual-path Liquid Glass recipe per §6.3:
    /// - Live glass: `.glassEffect` with `tintOpacity <= 0.35` plus optional guard `<= 0.20`.
    /// - Solid fallback: opaque color/gradient matching the mock appearance composited over its backdrop.
    struct GlassRecipe: Equatable {
        let tintHex: UInt32
        let tintOpacity: Double
        let guardHex: UInt32?
        let guardOpacity: Double
        let solidTopHex: UInt32
        let solidBottomHex: UInt32
        let interactive: Bool
        let clearGlass: Bool
        let borderColor: Color
        let borderWidth: CGFloat
        let specularTop: Color?
        let increasedBorderColor: Color

        init(tintHex: UInt32, tintOpacity: Double,
             guardHex: UInt32? = nil, guardOpacity: Double = 0,
             solidTopHex: UInt32, solidBottomHex: UInt32? = nil,
             interactive: Bool = false, clearGlass: Bool = false,
             borderColor: Color, borderWidth: CGFloat = OrivOutline.hairline,
             specularTop: Color? = nil, increasedBorderColor: Color) {
            self.tintHex = tintHex
            self.tintOpacity = tintOpacity
            self.guardHex = guardHex
            self.guardOpacity = guardOpacity
            self.solidTopHex = solidTopHex
            self.solidBottomHex = solidBottomHex ?? solidTopHex
            self.interactive = interactive
            self.clearGlass = clearGlass
            self.borderColor = borderColor
            self.borderWidth = borderWidth
            self.specularTop = specularTop
            self.increasedBorderColor = increasedBorderColor
        }

        var tintColor: Color { Theme.hex(tintHex) }
        var guardColor: Color? { guardHex.map(Theme.hex) }
        var solidColor: Color { Theme.hex(solidTopHex) }
        var solidGradient: LinearGradient {
            LinearGradient(colors: [Theme.hex(solidTopHex), Theme.hex(solidBottomHex)],
                           startPoint: .top, endPoint: .bottom)
        }
    }

    /// Shared opacity/compositing check matching `BrowserGlass` and `MacSidebarGlass`.
    @MainActor static func usesOpaqueSurface(theme: Theme, reduceTransparency: Bool, captureReduceTransparency: Bool,
                                             contrast: ColorSchemeContrast, forceSolid: Bool = false) -> Bool {
        reduceTransparency || captureReduceTransparency || contrast == .increased
            || theme.isT3Code || BackgroundUIMode.isEnabled || forceSolid
    }

    struct GlassModifier<S: InsettableShape>: ViewModifier {
        let recipe: GlassRecipe
        let shape: S
        var forceSolid = false

        @Environment(\.browserTheme) private var theme
        @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
        @Environment(\.colorSchemeContrast) private var systemContrast
        @Environment(\.chromeContrastOverride) private var captureContrast
        @Environment(\.chromeReduceTransparencyOverride) private var captureReduceTransparency

        func body(content: Content) -> some View {
            let contrast = captureContrast ?? systemContrast
            let opaque = OrivMacV3.usesOpaqueSurface(
                theme: theme,
                reduceTransparency: reduceTransparency,
                captureReduceTransparency: captureReduceTransparency,
                contrast: contrast,
                forceSolid: forceSolid
            )
            let increased = contrast == .increased
            if opaque {
                content
                    .background(recipe.solidGradient, in: shape)
                    .overlay {
                        if !increased, let specular = recipe.specularTop {
                            shape.inset(by: OrivOutline.hairline)
                                .stroke(
                                    LinearGradient(colors: [specular, .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.12)),
                                    lineWidth: 1
                                )
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay {
                        shape.strokeBorder(increased ? recipe.increasedBorderColor : recipe.borderColor,
                                           lineWidth: increased ? OrivOutline.enhanced : recipe.borderWidth)
                            .allowsHitTesting(false)
                    }
            } else {
                liveGlass(content, increased: increased)
            }
        }

        @ViewBuilder private func liveGlass(_ content: Content, increased: Bool) -> some View {
            let base = content.background {
                if let guardColor = recipe.guardColor, recipe.guardOpacity > 0 {
                    shape.fill(guardColor.opacity(recipe.guardOpacity)).allowsHitTesting(false)
                }
            }
            if recipe.clearGlass {
                base.glassEffect(.clear, in: shape)
                    .overlay {
                        shape.strokeBorder(recipe.borderColor, lineWidth: recipe.borderWidth)
                            .allowsHitTesting(false)
                    }
            } else if recipe.interactive {
                base.glassEffect(.regular.interactive().tint(recipe.tintColor.opacity(recipe.tintOpacity)), in: shape)
                    .overlay {
                        shape.strokeBorder(recipe.borderColor, lineWidth: recipe.borderWidth)
                            .allowsHitTesting(false)
                    }
            } else {
                base.glassEffect(.regular.tint(recipe.tintColor.opacity(recipe.tintOpacity)), in: shape)
                    .overlay {
                        shape.strokeBorder(recipe.borderColor, lineWidth: recipe.borderWidth)
                            .allowsHitTesting(false)
                    }
            }
        }
    }

    struct DualShadowModifier: ViewModifier {
        let shadow: DualShadow
        @Environment(\.colorSchemeContrast) private var systemContrast
        @Environment(\.chromeContrastOverride) private var captureContrast

        func body(content: Content) -> some View {
            let increased = (captureContrast ?? systemContrast) == .increased
            if increased {
                content
            } else if let primary = shadow.primary, let secondary = shadow.secondary {
                content
                    .shadow(color: primary.color, radius: primary.radius, x: primary.x, y: primary.y)
                    .shadow(color: secondary.color, radius: secondary.radius, x: secondary.x, y: secondary.y)
            } else if let primary = shadow.primary {
                content.shadow(color: primary.color, radius: primary.radius, x: primary.x, y: primary.y)
            } else {
                content
            }
        }
    }

    static func blendHex(_ front: UInt32, over back: UInt32, opacity: Double) -> UInt32 {
        let fr = Double((front >> 16) & 0xFF), fg = Double((front >> 8) & 0xFF), fb = Double(front & 0xFF)
        let br = Double((back >> 16) & 0xFF), bg = Double((back >> 8) & 0xFF), bb = Double(back & 0xFF)
        let r = UInt32((fr * opacity + br * (1 - opacity)).rounded()) & 0xFF
        let g = UInt32((fg * opacity + bg * (1 - opacity)).rounded()) & 0xFF
        let b = UInt32((fb * opacity + bb * (1 - opacity)).rounded()) & 0xFF
        return (r << 16) | (g << 8) | b
    }

    static func rgba(_ hex: UInt32, _ opacity: Double) -> Color {
        Theme.hex(hex).opacity(opacity)
    }

    // MARK: - 2.1 Window Backdrop
    enum Backdrop {
        static let lightStops: [UInt32] = [0xDDE6F5, 0xE7EBF3, 0xE1E7F0]
        static let darkStops: [UInt32] = [0x111521, 0x151822, 0x0F121B]
        static let privateStops: [UInt32] = [0x160F24, 0x120D1D, 0x0E0A16]

        static let lightBase = LinearGradient(
            stops: [
                .init(color: Theme.hex(0xDDE6F5), location: 0),
                .init(color: Theme.hex(0xE7EBF3), location: 0.48),
                .init(color: Theme.hex(0xE1E7F0), location: 1),
            ],
            startPoint: UnitPoint(x: 0.29, y: 0),
            endPoint: UnitPoint(x: 0.71, y: 1)
        )
        static let lightAmbient: [RadialGlow] = [
            RadialGlow(hex: 0xA8CEFF, opacity: 0.92, center: UnitPoint(x: 0.14, y: 0.12), radiusFraction: 0.48),
            RadialGlow(hex: 0xD4C6FA, opacity: 0.85, center: UnitPoint(x: 0.06, y: 0.86), radiusFraction: 0.44),
            RadialGlow(hex: 0xFFDEC4, opacity: 0.72, center: UnitPoint(x: 0.24, y: 0.48), radiusFraction: 0.34),
        ]

        static let startLightBaseHex: UInt32 = 0xF4F5FA
        static let startLightBase = Theme.hex(startLightBaseHex)
        static let startLightAmbient: [RadialGlow] = [
            RadialGlow(hex: 0x96BAFF, opacity: 0.48, center: UnitPoint(x: 0.22, y: 0.12), radiusFraction: 0.36),
            RadialGlow(hex: 0xFFC8AA, opacity: 0.42, center: UnitPoint(x: 0.86, y: 0.20), radiusFraction: 0.34),
            RadialGlow(hex: 0xC4AAFF, opacity: 0.34, center: UnitPoint(x: 0.62, y: 0.96), radiusFraction: 0.40),
            RadialGlow(hex: 0x96E2D6, opacity: 0.32, center: UnitPoint(x: 0.06, y: 0.92), radiusFraction: 0.34),
        ]
        static let startLightProfileMix: Double = 0.05

        static let darkBase = LinearGradient(
            stops: [
                .init(color: Theme.hex(0x111521), location: 0),
                .init(color: Theme.hex(0x151822), location: 0.50),
                .init(color: Theme.hex(0x0F121B), location: 1),
            ],
            startPoint: UnitPoint(x: 0.29, y: 0),
            endPoint: UnitPoint(x: 0.71, y: 1)
        )
        static let darkAmbient: [RadialGlow] = [
            RadialGlow(hex: 0x3E6CC6, opacity: 0.52, center: UnitPoint(x: 0.10, y: 0.16), radiusFraction: 0.62),
            RadialGlow(hex: 0x6E44B6, opacity: 0.44, center: UnitPoint(x: 0.16, y: 0.84), radiusFraction: 0.60),
            RadialGlow(hex: 0x2C8092, opacity: 0.34, center: UnitPoint(x: 0.24, y: 0.48), radiusFraction: 0.56),
        ]

        // Q7: Regular Dark start page uses cool slate-blue glows + profile bloom; purple stays Private-only.
        static let startDarkBaseHex: UInt32 = 0x111521
        static let startDarkBase = Theme.hex(startDarkBaseHex)
        static func startDarkAmbient(profileColor: ProfileColor = .ocean) -> [RadialGlow] {
            let tokens = Theme.SidebarChromaticTokens.resolve(.profile, profile: profileColor, dark: true, black: false)
            return [
                RadialGlow(hex: 0x3E6CC6, opacity: 0.38, center: UnitPoint(x: 0.20, y: 0.10), radiusFraction: 0.52),
                RadialGlow(hex: 0x2C8092, opacity: 0.30, center: UnitPoint(x: 0.86, y: 0.22), radiusFraction: 0.48),
                RadialGlow(hex: tokens.bloom, opacity: 0.22, center: UnitPoint(x: 0.60, y: 0.96), radiusFraction: 0.60),
            ]
        }

        static let blackHex: UInt32 = 0x000000
        static let black = Theme.hex(blackHex)

        static let privateBase = LinearGradient(
            stops: [
                .init(color: Theme.hex(0x160F24), location: 0),
                .init(color: Theme.hex(0x120D1D), location: 0.52),
                .init(color: Theme.hex(0x0E0A16), location: 1),
            ],
            startPoint: UnitPoint(x: 0.29, y: 0),
            endPoint: UnitPoint(x: 0.71, y: 1)
        )
        static let privateAmbient: [RadialGlow] = [
            RadialGlow(hex: 0x8B5CF6, opacity: 0.44, center: UnitPoint(x: 0.12, y: 0.14), radiusFraction: 0.64),
            RadialGlow(hex: 0xC084FC, opacity: 0.28, center: UnitPoint(x: 0.18, y: 0.88), radiusFraction: 0.62),
            RadialGlow(hex: 0x5B21B6, opacity: 0.24, center: UnitPoint(x: 0.62, y: 0.20), radiusFraction: 0.60),
        ]

        static let startPrivateBaseHex: UInt32 = 0x15101A
        static let startPrivateBase = Theme.hex(startPrivateBaseHex)
        static let startPrivateAmbient: [RadialGlow] = [
            RadialGlow(hex: 0x784EAA, opacity: 0.55, center: UnitPoint(x: 0.20, y: 0.10), radiusFraction: 0.52),
            RadialGlow(hex: 0x463C8C, opacity: 0.45, center: UnitPoint(x: 0.88, y: 0.22), radiusFraction: 0.48),
            RadialGlow(hex: 0x964696, opacity: 0.34, center: UnitPoint(x: 0.60, y: 1.00), radiusFraction: 0.60),
        ]

        static let reducedLightHex: UInt32 = 0xE7EBF3
        static let reducedDarkHex: UInt32 = 0x151822
        static let reducedPrivateHex: UInt32 = 0x120D1D
        static let reducedLight = Theme.hex(reducedLightHex)
        static let reducedDark = Theme.hex(reducedDarkHex)
        static let reducedPrivate = Theme.hex(reducedPrivateHex)

        static func reduced(_ mode: AppearanceMode) -> Color {
            switch mode {
            case .light: reducedLight
            case .dark: reducedDark
            case .black: black
            case .private: reducedPrivate
            }
        }

        struct BackdropView: View {
            let mode: AppearanceMode
            var startPage = false
            var profileColor: ProfileColor = .mulberry
            var reduced = false

            var body: some View {
                GeometryReader { proxy in
                    let maxDim = max(proxy.size.width, proxy.size.height)
                    ZStack {
                        if mode == .black {
                            Backdrop.black
                        } else if reduced {
                            startPage ? Card.fillStartPageSolid(mode) : Backdrop.reduced(mode)
                        } else {
                            baseLayer
                            ForEach(Array(glows.enumerated()), id: \.offset) { _, glow in
                                RadialGradient(
                                    colors: [glow.color, glow.color.opacity(0)],
                                    center: glow.center,
                                    startRadius: 0,
                                    endRadius: max(1, maxDim * glow.radiusFraction)
                                )
                            }
                            if startPage && mode == .light {
                                let profileTokens = Theme.SidebarChromaticTokens.resolve(.profile, profile: profileColor, dark: false, black: false)
                                RadialGradient(
                                    colors: [Theme.hex(profileTokens.bloom).opacity(Backdrop.startLightProfileMix), .clear],
                                    center: UnitPoint(x: 0.50, y: 0.25),
                                    startRadius: 0,
                                    endRadius: max(1, maxDim * 0.45)
                                )
                            }
                        }
                    }
                }
            }

            @ViewBuilder private var baseLayer: some View {
                switch (mode, startPage) {
                case (.light, false): Backdrop.lightBase
                case (.light, true): Backdrop.startLightBase
                case (.dark, false): Backdrop.darkBase
                case (.dark, true): Backdrop.startDarkBase
                case (.black, _): Backdrop.black
                case (.private, false): Backdrop.privateBase
                case (.private, true): Backdrop.startPrivateBase
                }
            }

            private var glows: [RadialGlow] {
                switch (mode, startPage) {
                case (.light, false): Backdrop.lightAmbient
                case (.light, true): Backdrop.startLightAmbient
                case (.dark, false): Backdrop.darkAmbient
                case (.dark, true): Backdrop.startDarkAmbient(profileColor: profileColor)
                case (.black, _): []
                case (.private, false): Backdrop.privateAmbient
                case (.private, true): Backdrop.startPrivateAmbient
                }
            }
        }
    }

    // MARK: - 2.2 Inset Page Card
    enum Card {
        static let fillLightHex: UInt32 = 0xFBFBF9
        static let fillDarkHex: UInt32 = 0x17181C
        static let fillBlackHex: UInt32 = 0x0A0A0A
        static let fillPrivateHex: UInt32 = 0x120D1A
        static let fillPrivateTopHex: UInt32 = 0x161020

        static let fillLight = Theme.hex(fillLightHex)
        static let fillDark = Theme.hex(fillDarkHex)
        static let fillBlack = Theme.hex(fillBlackHex)
        static let fillPrivate = Theme.hex(fillPrivateHex)
        static let fillPrivateGradient = LinearGradient(
            colors: [Theme.hex(fillPrivateTopHex), Theme.hex(fillPrivateHex)],
            startPoint: .top, endPoint: .bottom
        )
        static let fillStartPage: Color = .clear

        static let startSolidLightHex: UInt32 = 0xF4F5FA
        static let startSolidDarkHex: UInt32 = 0x151822
        static let startSolidBlackHex: UInt32 = 0x000000
        static let startSolidPrivateHex: UInt32 = 0x15101A

        static func fill(_ mode: AppearanceMode) -> Color {
            switch mode {
            case .light: fillLight
            case .dark: fillDark
            case .black: fillBlack
            case .private: fillPrivate
            }
        }

        static func fillStartPageSolid(_ mode: AppearanceMode) -> Color {
            switch mode {
            case .light: Theme.hex(startSolidLightHex)
            case .dark: Theme.hex(startSolidDarkHex)
            case .black: Theme.hex(startSolidBlackHex)
            case .private: Theme.hex(startSolidPrivateHex)
            }
        }

        static let rimLight = rgba(0x0F172A, 0.085)
        static let rimDark = rgba(0xFFFFFF, 0.085)
        static let rimBlack = rgba(0xFFFFFF, 0.12)
        static let rimPrivate = rgba(0xD8B4FE, 0.14)

        static func rim(_ mode: AppearanceMode, increasedContrast: Bool = false) -> Color {
            if increasedContrast { return rimIncreasedContrast(mode) }
            switch mode {
            case .light: return rimLight
            case .dark: return rimDark
            case .black: return rimBlack
            case .private: return rimPrivate
            }
        }

        static let rimICLightHex: UInt32 = 0x646469
        static let rimICDarkHex: UInt32 = 0xA3A3A9
        static let rimICBlackHex: UInt32 = 0x818181
        static let rimICPrivateHex: UInt32 = 0xD8B4FE

        static func rimIncreasedContrast(_ mode: AppearanceMode) -> Color {
            switch mode {
            case .light: Theme.hex(rimICLightHex)
            case .dark: Theme.hex(rimICDarkHex)
            case .black: Theme.hex(rimICBlackHex)
            case .private: Theme.hex(rimICPrivateHex)
            }
        }

        static let shadowLight = DualShadow(
            primary: ShadowSpec(color: rgba(0x0F172A, 0.06), radius: 12, y: 2),
            secondary: ShadowSpec(color: rgba(0x0F172A, 0.04), radius: 2, y: 0.5)
        )
        static let shadowDark = DualShadow(primary: ShadowSpec(color: rgba(0x000000, 0.42), radius: 24, y: 6))
        static let shadowBlack = DualShadow.none
        static let shadowPrivate = DualShadow(primary: ShadowSpec(color: rgba(0x000000, 0.48), radius: 26, y: 6))

        static func shadow(_ mode: AppearanceMode) -> DualShadow {
            switch mode {
            case .light: shadowLight
            case .dark: shadowDark
            case .black: shadowBlack
            case .private: shadowPrivate
            }
        }

        static func elevation(_ mode: AppearanceMode) -> DualShadow { shadow(mode) }
    }

    // MARK: - 2.3 Sidebar Glass Tint, Contrast Guard, and Controls
    enum Sidebar {
        // §6.3 live-glass bounds: tint <= 0.35, guard <= 0.20 (tuned per tint for WCAG >= 4.5:1 over v3 backdrops).
        static let v3TintOpacity = (balanced: 0.30, high: 0.35)
        static let v3HighGuardOpacity: Double = 0.20
        static let v3ChromaticSolidMix: Double = 0.65

        // Balanced per-tint guards (0.00 where raw glass already clears 4.5:1 over all backdrop stops & glows).
        static let v3BalancedGuardByTint: [String: Double] = [
            "graphiteLight": 0.00, "graphiteDark": 0.00,
            "amberLight": 0.00, "amberDark": 0.14,
            "butterLight": 0.00, "butterDark": 0.14,
            "fernLight": 0.00, "fernDark": 0.16,
            "lavenderLight": 0.06, "lavenderDark": 0.12,
            "mintLight": 0.00, "mintDark": 0.17,
            "mulberryLight": 0.05, "mulberryDark": 0.10,
            "oceanLight": 0.00, "oceanDark": 0.18,
            "peachLight": 0.00, "peachDark": 0.12,
            "roseLight": 0.04, "roseDark": 0.10,
            "sageLight": 0.00, "sageDark": 0.18,
            "skyLight": 0.00, "skyDark": 0.20,
            "slateLight": 0.00, "slateDark": 0.20,
            "private": 0.14, "black": 0.00,
        ]

        static let graphiteLightTint = GlassRecipe(
            tintHex: 0xF7F9FE, tintOpacity: v3TintOpacity.balanced,
            guardHex: 0xFFFFFF, guardOpacity: 0.00,
            solidTopHex: 0xF2F4FA, solidBottomHex: 0xE6EAF3,
            borderColor: border(.light), specularTop: specularTop(.light),
            increasedBorderColor: Card.rimIncreasedContrast(.light)
        )
        static let graphiteDarkTint = GlassRecipe(
            tintHex: 0x242A3A, tintOpacity: v3TintOpacity.balanced,
            guardHex: 0x0E1118, guardOpacity: 0.00,
            solidTopHex: 0x242A3A, solidBottomHex: 0x191E2A,
            borderColor: border(.dark), specularTop: specularTop(.dark),
            increasedBorderColor: Card.rimIncreasedContrast(.dark)
        )
        static let blackTint = GlassRecipe(
            tintHex: 0x0A0A0A, tintOpacity: 0.35,
            guardHex: 0x000000, guardOpacity: 0.00,
            solidTopHex: 0x0A0A0A, solidBottomHex: 0x0A0A0A,
            borderColor: border(.black), specularTop: nil,
            increasedBorderColor: Card.rimIncreasedContrast(.black)
        )
        static let privateTint = GlassRecipe(
            tintHex: 0x301C4E, tintOpacity: v3TintOpacity.balanced,
            guardHex: 0x120C1C, guardOpacity: 0.14,
            solidTopHex: 0x301C4E, solidBottomHex: 0x1E1232,
            borderColor: border(.private), specularTop: specularTop(.private),
            increasedBorderColor: Card.rimIncreasedContrast(.private)
        )

        static func chromaticSwatches(color: SidebarColor, profile: ProfileColor?, mode: AppearanceMode,
                                      level: SidebarGlassOpacity = .balanced) -> GlassRecipe {
            if mode == .black { return blackTint }
            if mode == .private {
                let tintAlpha = level == .high ? v3TintOpacity.high : v3TintOpacity.balanced
                let guardAlpha = level == .high ? v3HighGuardOpacity : (v3BalancedGuardByTint["private"] ?? 0.14)
                return GlassRecipe(
                    tintHex: 0x301C4E, tintOpacity: tintAlpha,
                    guardHex: 0x120C1C, guardOpacity: guardAlpha,
                    solidTopHex: 0x301C4E, solidBottomHex: 0x1E1232,
                    borderColor: border(.private), specularTop: specularTop(.private),
                    increasedBorderColor: Card.rimIncreasedContrast(.private)
                )
            }
            let dark = mode == .dark
            let effective = color.effective(profileColor: profile, isT3Code: false)
            let key: String
            switch effective {
            case .graphite: key = dark ? "graphiteDark" : "graphiteLight"
            case .profile:
                key = (profile?.rawValue ?? "graphite") + (dark ? "Dark" : "Light")
            default:
                key = effective.rawValue + (dark ? "Dark" : "Light")
            }
            let tokens = Theme.SidebarChromaticTokens.resolve(color, profile: profile, dark: dark, black: false)
            let tintAlpha = level == .high ? v3TintOpacity.high : v3TintOpacity.balanced
            let guardAlpha = level == .high ? v3HighGuardOpacity : (v3BalancedGuardByTint[key] ?? 0.0)
            let isGraphite = effective == .graphite || (effective == .profile && profile == nil)
            let tintHex: UInt32 = isGraphite ? (dark ? 0x242A3A : 0xF7F9FE) : tokens.top
            let backdropHex: UInt32 = dark ? Backdrop.reducedDarkHex : Backdrop.reducedLightHex
            let solidTop: UInt32 = isGraphite ? (dark ? 0x242A3A : 0xF2F4FA) : blendHex(tokens.top, over: backdropHex, opacity: v3ChromaticSolidMix)
            let solidBottom: UInt32 = isGraphite ? (dark ? 0x191E2A : 0xE6EAF3) : blendHex(tokens.bottom, over: backdropHex, opacity: v3ChromaticSolidMix)
            return GlassRecipe(
                tintHex: tintHex, tintOpacity: tintAlpha,
                guardHex: tokens.guardColor, guardOpacity: guardAlpha,
                solidTopHex: solidTop, solidBottomHex: solidBottom,
                borderColor: border(mode), specularTop: specularTop(mode),
                increasedBorderColor: Card.rimIncreasedContrast(mode)
            )
        }

        static func border(_ mode: AppearanceMode) -> Color {
            switch mode {
            case .light: rgba(0xFFFFFF, 0.72)
            case .dark: rgba(0xFFFFFF, 0.14)
            case .black: rgba(0xFFFFFF, 0.12)
            case .private: rgba(0xD8B4FE, 0.22)
            }
        }

        static func specularTop(_ mode: AppearanceMode) -> Color? {
            switch mode {
            case .light: rgba(0xFFFFFF, 0.85)
            case .dark: rgba(0xFFFFFF, 0.18)
            case .black: nil
            case .private: rgba(0xE9D5FF, 0.24)
            }
        }

        static func shadow(_ mode: AppearanceMode) -> DualShadow {
            switch mode {
            case .light:
                DualShadow(
                    primary: ShadowSpec(color: rgba(0x0F172A, 0.07), radius: 26, y: 8),
                    secondary: ShadowSpec(color: rgba(0x0F172A, 0.05), radius: 3, y: 1)
                )
            case .dark:
                DualShadow(primary: ShadowSpec(color: rgba(0x000000, 0.35), radius: 30, y: 10))
            case .black:
                .none
            case .private:
                DualShadow(primary: ShadowSpec(color: rgba(0x000000, 0.42), radius: 32, y: 10))
            }
        }

        static func elevation(_ mode: AppearanceMode) -> DualShadow { shadow(mode) }

        static func toggleFill(_ mode: AppearanceMode) -> Color {
            switch mode {
            case .light: rgba(0xFFFFFF, 0.36)
            case .dark: rgba(0xFFFFFF, 0.06)
            case .black: rgba(0xFFFFFF, 0.08)
            case .private: rgba(0xD8B4FE, 0.08)
            }
        }

        static func toggleRecipe(_ mode: AppearanceMode) -> GlassRecipe {
            switch mode {
            case .light:
                GlassRecipe(tintHex: 0xFFFFFF, tintOpacity: 0.24, solidTopHex: 0xF7F8FC,
                            clearGlass: true, borderColor: rgba(0xFFFFFF, 0.78),
                            increasedBorderColor: Card.rimIncreasedContrast(.light))
            case .dark:
                GlassRecipe(tintHex: 0xFFFFFF, tintOpacity: 0.06, solidTopHex: 0x303034,
                            clearGlass: true, borderColor: rgba(0xFFFFFF, 0.14),
                            increasedBorderColor: Card.rimIncreasedContrast(.dark))
            case .black:
                GlassRecipe(tintHex: 0xFFFFFF, tintOpacity: 0.08, solidTopHex: 0x171717,
                            clearGlass: true, borderColor: rgba(0xFFFFFF, 0.12),
                            increasedBorderColor: Card.rimIncreasedContrast(.black))
            case .private:
                GlassRecipe(tintHex: 0xD8B4FE, tintOpacity: 0.08, solidTopHex: 0x3B255E,
                            clearGlass: true, borderColor: rgba(0xE9D5FF, 0.18),
                            increasedBorderColor: Card.rimIncreasedContrast(.private))
            }
        }

        static func searchFill(_ mode: AppearanceMode, solid: Bool = false) -> Color {
            if solid {
                switch mode {
                case .light: return Theme.hex(0xE3E7F0)
                case .dark: return Theme.hex(0x2F3545)
                case .black: return Theme.hex(0x1E1E1E)
                case .private: return Theme.hex(0x3B265B)
                }
            }
            switch mode {
            case .light: return rgba(0x141A28, 0.055)
            case .dark: return rgba(0xFFFFFF, 0.065)
            case .black: return Theme.hex(0x1E1E1E)
            case .private: return rgba(0xD8B4FE, 0.075)
            }
        }

        static func searchInnerRim(_ mode: AppearanceMode) -> Color {
            switch mode {
            case .light: rgba(0x0F172A, 0.07)
            case .dark: rgba(0xFFFFFF, 0.09)
            case .black: rgba(0xFFFFFF, 0.08)
            case .private: rgba(0xE9D5FF, 0.12)
            }
        }

        static func pinFill(_ mode: AppearanceMode, solid: Bool = false) -> Color {
            if solid {
                switch mode {
                case .light: return Theme.hex(0xFFFFFF)
                case .dark: return Theme.hex(0x2E3444)
                case .black: return Theme.hex(0x171717)
                case .private: return Theme.hex(0x3E2861)
                }
            }
            switch mode {
            case .light: return rgba(0xFFFFFF, 0.52)
            case .dark: return rgba(0xFFFFFF, 0.075)
            case .black: return Theme.hex(0x171717)
            case .private: return rgba(0xD8B4FE, 0.10)
            }
        }

        static func pinBorder(_ mode: AppearanceMode, increasedContrast: Bool = false) -> Color {
            if increasedContrast { return Card.rimIncreasedContrast(mode) }
            switch mode {
            case .light: return rgba(0xFFFFFF, 0.78)
            case .dark: return rgba(0xFFFFFF, 0.13)
            case .black: return rgba(0xFFFFFF, 0.10)
            case .private: return rgba(0xD8B4FE, 0.18)
            }
        }

        static func pinShadow(_ mode: AppearanceMode) -> DualShadow {
            switch mode {
            case .light: DualShadow(primary: ShadowSpec(color: rgba(0x0F172A, 0.045), radius: 3, y: 1))
            case .dark: DualShadow(primary: ShadowSpec(color: rgba(0x000000, 0.18), radius: 6, y: 2))
            case .black: .none
            case .private: DualShadow(primary: ShadowSpec(color: rgba(0x000000, 0.22), radius: 6, y: 2))
            }
        }

        static func rowHover(_ mode: AppearanceMode, solid: Bool = false) -> Color {
            if solid {
                switch mode {
                case .light: return Theme.hex(0xE5E9F2)
                case .dark: return Theme.hex(0x2D3343)
                case .black: return Theme.hex(0x171717)
                case .private: return Theme.hex(0x3D275E)
                }
            }
            switch mode {
            case .light: return rgba(0x141A28, 0.05)
            case .dark: return rgba(0xFFFFFF, 0.06)
            case .black: return Theme.hex(0x171717)
            case .private: return rgba(0xD8B4FE, 0.08)
            }
        }

        static let activeSolidHex: [AppearanceMode: UInt32] = [
            .light: 0xE5F0FE,
            .dark: 0x2E5A8F,
            .black: 0x252A32,
            .private: 0x5A2C8A,
        ]

        static func activeFill(_ mode: AppearanceMode, solid: Bool = false) -> LinearGradient {
            if solid || mode == .black {
                if mode == .light {
                    return LinearGradient(colors: [Theme.hex(0xF6FAFF), Theme.hex(0xE5F0FE)],
                                          startPoint: .top, endPoint: .bottom)
                }
                let hex = activeSolidHex[mode] ?? 0x252A32
                return LinearGradient(colors: [Theme.hex(hex), Theme.hex(hex)], startPoint: .top, endPoint: .bottom)
            }
            switch mode {
            case .light:
                return LinearGradient(colors: [rgba(0xFFFFFF, 0.86), rgba(0xE0EEFF, 0.78)],
                                      startPoint: .top, endPoint: .bottom)
            case .dark:
                return LinearGradient(colors: [rgba(0x4E86E0, 0.40), rgba(0x3666B2, 0.34)],
                                      startPoint: .top, endPoint: .bottom)
            case .black:
                return LinearGradient(colors: [Theme.hex(0x292E37), Theme.hex(0x292E37)],
                                      startPoint: .top, endPoint: .bottom)
            case .private:
                return LinearGradient(colors: [rgba(0xA855F7, 0.36), rgba(0x7E22CE, 0.28)],
                                      startPoint: .top, endPoint: .bottom)
            }
        }

        static func activeBorder(_ mode: AppearanceMode, increasedContrast: Bool = false) -> Color {
            if increasedContrast { return activeInk(mode) }
            switch mode {
            case .light: return rgba(0x1D6FD1, 0.22)
            case .dark: return rgba(0x99C7FF, 0.34)
            case .black: return rgba(0xA3AFC0, 0.30)
            case .private: return rgba(0xD8B4FE, 0.40)
            }
        }

        static func activeTopHighlight(_ mode: AppearanceMode) -> Color? {
            switch mode {
            case .light: rgba(0xFFFFFF, 0.95)
            case .dark: rgba(0xBEDCFF, 0.32)
            case .black: nil
            case .private: rgba(0xF3E8FF, 0.34)
            }
        }

        static func activeShadow(_ mode: AppearanceMode) -> DualShadow {
            switch mode {
            case .light:
                DualShadow(
                    primary: ShadowSpec(color: rgba(0x1D6FD1, 0.10), radius: 8, y: 2),
                    secondary: ShadowSpec(color: rgba(0x0F172A, 0.06), radius: 2, y: 0.5)
                )
            case .dark:
                DualShadow(primary: ShadowSpec(color: rgba(0x3B82F6, 0.22), radius: 12, y: 3))
            case .black:
                .none
            case .private:
                DualShadow(primary: ShadowSpec(color: rgba(0x8B5CF6, 0.28), radius: 14, y: 3))
            }
        }

        static let activeInkLightHex: UInt32 = 0x0B3D78
        static let activeInkDarkHex: UInt32 = 0xFFFFFF
        static let activeInkBlackHex: UInt32 = 0xF5F5F5
        static let activeInkPrivateHex: UInt32 = 0xFFFFFF

        static func activeInk(_ mode: AppearanceMode) -> Color {
            switch mode {
            case .light: Theme.hex(activeInkLightHex)
            case .dark: Theme.hex(activeInkDarkHex)
            case .black: Theme.hex(activeInkBlackHex)
            case .private: Theme.hex(activeInkPrivateHex)
            }
        }

        static func audioInk(_ mode: AppearanceMode) -> Color {
            switch mode {
            case .light: rgba(0x007AFF, 0.92)
            case .dark, .black: Theme.hex(0x7CC0FF)
            case .private: Theme.hex(0xD8B4FE)
            }
        }

        static func profileAvatarBg(_ mode: AppearanceMode, profile: ProfileColor = .mulberry) -> LinearGradient {
            if mode == .private {
                return LinearGradient(colors: [rgba(0xC084FC, 0.24), rgba(0xC084FC, 0.24)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            if mode == .black {
                return LinearGradient(colors: [Theme.hex(0x242428), Theme.hex(0x1B1B1F)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            let dark = mode == .dark
            let baseHex: UInt32
            switch profile {
            case .mulberry: baseHex = dark ? 0xA855F7 : 0x8B5CF6
            case .ocean: baseHex = 0x3B82F6
            case .fern: baseHex = 0x22C55E
            case .amber: baseHex = 0xF59E0B
            case .slate: baseHex = 0x64748B
            }
            let topOpacity = dark ? 0.30 : 0.20
            let bottomOpacity = dark ? 0.20 : 0.30
            return LinearGradient(colors: [rgba(baseHex, topOpacity), rgba(baseHex, bottomOpacity)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        }

        static func profileAvatarInk(_ mode: AppearanceMode, profile: ProfileColor = .mulberry) -> Color {
            switch mode {
            case .private: Theme.hex(0xD8B4FE)
            case .light: profile == .mulberry ? Theme.hex(0x6B21A8) : profile.sidebarInk(dark: false)
            case .dark, .black: profile == .mulberry ? Theme.hex(0xE5B8FF) : profile.sidebarInk(dark: true)
            }
        }

        static func footerSeparator(_ mode: AppearanceMode, increasedContrast: Bool = false) -> Color {
            if increasedContrast { return Card.rimIncreasedContrast(mode) }
            switch mode {
            case .light: return rgba(0x14161A, 0.085)
            case .dark: return rgba(0xFFFFFF, 0.09)
            case .black: return Theme.hex(0x191919)
            case .private: return rgba(0xD8B4FE, 0.13)
            }
        }

        static func downloadDotRing(_ mode: AppearanceMode) -> Color {
            switch mode {
            case .light: rgba(0xF4F7FD, 0.95)
            case .dark: rgba(0x191E2A, 0.95)
            case .black: Theme.hex(0x0A0A0A)
            case .private: Theme.hex(0x1E1232)
            }
        }

        static let trafficLightClose = Theme.hex(0xFF5F57)
        static let trafficLightMinimize = Theme.hex(0xFEBC2E)
        static let trafficLightZoom = Theme.hex(0x28C840)
        static let trafficLightRim = rgba(0x000000, 0.14)

        static func profileDotColor(_ profile: ProfileColor) -> Color {
            switch profile {
            case .mulberry: Theme.hex(0x9333EA)
            case .ocean: Theme.hex(0x3B82F6)
            case .fern: Theme.hex(0x22C55E)
            case .amber: Theme.hex(0xF59E0B)
            case .slate: Theme.hex(0x64748B)
            }
        }
    }

    // MARK: - 2.4 Toolbar Glass and Scroll Edge
    enum Toolbar {
        static let solidLightHex: UInt32 = 0xFEFEFD
        static let solidDarkHex: UInt32 = 0x282C36
        static let solidBlackHex: UInt32 = 0x161618
        static let solidPrivateHex: UInt32 = 0x342250

        static func groupTint(_ mode: AppearanceMode) -> GlassRecipe {
            switch mode {
            case .light:
                GlassRecipe(tintHex: 0xFFFFFF, tintOpacity: 0.30,
                            solidTopHex: solidLightHex, interactive: true,
                            borderColor: groupBorder(.light), specularTop: groupTopHighlight(.light),
                            increasedBorderColor: Card.rimIncreasedContrast(.light))
            case .dark:
                GlassRecipe(tintHex: 0x282C36, tintOpacity: 0.30,
                            solidTopHex: solidDarkHex, interactive: true,
                            borderColor: groupBorder(.dark), specularTop: groupTopHighlight(.dark),
                            increasedBorderColor: Card.rimIncreasedContrast(.dark))
            case .black:
                GlassRecipe(tintHex: 0x161618, tintOpacity: 0.35,
                            solidTopHex: solidBlackHex, interactive: true,
                            borderColor: groupBorder(.black), specularTop: nil,
                            increasedBorderColor: Card.rimIncreasedContrast(.black))
            case .private:
                GlassRecipe(tintHex: 0x342250, tintOpacity: 0.32,
                            solidTopHex: solidPrivateHex, interactive: true,
                            borderColor: groupBorder(.private), specularTop: groupTopHighlight(.private),
                            increasedBorderColor: Card.rimIncreasedContrast(.private))
            }
        }

        static func groupBorder(_ mode: AppearanceMode) -> Color {
            switch mode {
            case .light: rgba(0x0F172A, 0.085)
            case .dark: rgba(0xFFFFFF, 0.14)
            case .black: rgba(0xFFFFFF, 0.14)
            case .private: rgba(0xD8B4FE, 0.20)
            }
        }

        static func groupTopHighlight(_ mode: AppearanceMode) -> Color? {
            switch mode {
            case .light: rgba(0xFFFFFF, 0.92)
            case .dark: rgba(0xFFFFFF, 0.18)
            case .black: nil
            case .private: rgba(0xE9D5FF, 0.20)
            }
        }

        static func groupShadow(_ mode: AppearanceMode) -> DualShadow {
            switch mode {
            case .light:
                DualShadow(
                    primary: ShadowSpec(color: rgba(0x0F172A, 0.065), radius: 10, y: 2),
                    secondary: ShadowSpec(color: rgba(0x0F172A, 0.04), radius: 2, y: 0.5)
                )
            case .dark:
                DualShadow(primary: ShadowSpec(color: rgba(0x000000, 0.32), radius: 14, y: 4))
            case .black:
                .none
            case .private:
                DualShadow(primary: ShadowSpec(color: rgba(0x000000, 0.34), radius: 14, y: 4))
            }
        }

        static func divider(_ mode: AppearanceMode, increasedContrast: Bool = false) -> Color {
            if increasedContrast { return Card.rimIncreasedContrast(mode) }
            switch mode {
            case .light: return rgba(0x0F172A, 0.12)
            case .dark: return rgba(0xFFFFFF, 0.12)
            case .black: return rgba(0xFFFFFF, 0.14)
            case .private: return rgba(0xD8B4FE, 0.16)
            }
        }

        static func disabledOpacity(_ mode: AppearanceMode, increasedContrast: Bool = false) -> Double {
            if increasedContrast { return 0.50 }
            return mode == .black ? 0.35 : 0.30
        }

        static func shieldDot(_ mode: AppearanceMode) -> Color {
            mode == .light ? Theme.hex(0x16A34A) : Theme.hex(0x4ADE80)
        }

        static func shieldDotRing(_ mode: AppearanceMode) -> Color {
            switch mode {
            case .light: rgba(0xFFFFFF, 0.92)
            case .dark: rgba(0x222630, 0.95)
            case .black: Theme.hex(0x161618)
            case .private: Theme.hex(0x342250)
            }
        }

        static func scrollEdge(_ mode: AppearanceMode, solid: Bool = false) -> LinearGradient {
            let base: UInt32
            switch mode {
            case .light: base = Card.fillLightHex
            case .dark: base = Card.fillDarkHex
            case .black: base = Card.fillBlackHex
            case .private: base = Card.fillPrivateTopHex
            }
            if solid || mode == .black {
                return LinearGradient(colors: [Theme.hex(base), Theme.hex(base)], startPoint: .top, endPoint: .bottom)
            }
            let topOpacity = mode == .light ? 0.88 : 0.80
            let midOpacity = mode == .light ? 0.66 : 0.48
            return LinearGradient(
                stops: [
                    .init(color: rgba(base, topOpacity), location: 0),
                    .init(color: rgba(base, midOpacity), location: 0.54),
                    .init(color: rgba(base, 0), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
        }
    }

    // MARK: - 2.5 Address Capsule
    enum Address {
        static let restSolidLightHex: UInt32 = 0xFEFEFE
        static let restSolidDarkHex: UInt32 = 0x2A2E38
        static let restSolidBlackHex: UInt32 = 0x18181B
        static let restSolidPrivateHex: UInt32 = 0x362354

        static let focusSolidLightHex: UInt32 = 0xFFFFFF
        static let focusSolidDarkHex: UInt32 = 0x222630
        static let focusSolidBlackHex: UInt32 = 0x1E1E22
        static let focusSolidPrivateHex: UInt32 = 0x301E4A

        static func restFill(_ mode: AppearanceMode) -> GlassRecipe {
            switch mode {
            case .light:
                GlassRecipe(tintHex: 0xFFFFFF, tintOpacity: 0.32,
                            solidTopHex: restSolidLightHex, interactive: true,
                            borderColor: restBorder(.light), specularTop: restTopHighlight(.light),
                            increasedBorderColor: Card.rimIncreasedContrast(.light))
            case .dark:
                GlassRecipe(tintHex: 0x2A2E38, tintOpacity: 0.30,
                            solidTopHex: restSolidDarkHex, interactive: true,
                            borderColor: restBorder(.dark), specularTop: restTopHighlight(.dark),
                            increasedBorderColor: Card.rimIncreasedContrast(.dark))
            case .black:
                GlassRecipe(tintHex: 0x18181B, tintOpacity: 0.35,
                            solidTopHex: restSolidBlackHex, interactive: true,
                            borderColor: restBorder(.black), specularTop: nil,
                            increasedBorderColor: Card.rimIncreasedContrast(.black))
            case .private:
                GlassRecipe(tintHex: 0x362354, tintOpacity: 0.34,
                            solidTopHex: restSolidPrivateHex, interactive: true,
                            borderColor: restBorder(.private), specularTop: restTopHighlight(.private),
                            increasedBorderColor: Card.rimIncreasedContrast(.private))
            }
        }

        static func hoverFill(_ mode: AppearanceMode) -> GlassRecipe {
            switch mode {
            case .light:
                GlassRecipe(tintHex: 0xFFFFFF, tintOpacity: 0.35,
                            solidTopHex: 0xFFFFFF, interactive: true,
                            borderColor: restBorder(.light), specularTop: restTopHighlight(.light),
                            increasedBorderColor: Card.rimIncreasedContrast(.light))
            case .dark:
                GlassRecipe(tintHex: 0x323743, tintOpacity: 0.35,
                            solidTopHex: 0x323743, interactive: true,
                            borderColor: restBorder(.dark), specularTop: restTopHighlight(.dark),
                            increasedBorderColor: Card.rimIncreasedContrast(.dark))
            case .black:
                GlassRecipe(tintHex: 0x222226, tintOpacity: 0.35,
                            solidTopHex: 0x222226, interactive: true,
                            borderColor: restBorder(.black), specularTop: nil,
                            increasedBorderColor: Card.rimIncreasedContrast(.black))
            case .private:
                GlassRecipe(tintHex: 0x422B66, tintOpacity: 0.35,
                            solidTopHex: 0x422B66, interactive: true,
                            borderColor: restBorder(.private), specularTop: restTopHighlight(.private),
                            increasedBorderColor: Card.rimIncreasedContrast(.private))
            }
        }

        static func restBorder(_ mode: AppearanceMode) -> Color {
            switch mode {
            case .light: rgba(0x0F172A, 0.09)
            case .dark: rgba(0xFFFFFF, 0.15)
            case .black: rgba(0xFFFFFF, 0.16)
            case .private: rgba(0xD8B4FE, 0.26)
            }
        }

        static func restTopHighlight(_ mode: AppearanceMode) -> Color? {
            switch mode {
            case .light: rgba(0xFFFFFF, 0.96)
            case .dark: rgba(0xFFFFFF, 0.19)
            case .black: nil
            case .private: rgba(0xF3E8FF, 0.22)
            }
        }

        static func restShadow(_ mode: AppearanceMode) -> DualShadow {
            switch mode {
            case .light:
                DualShadow(
                    primary: ShadowSpec(color: rgba(0x0F172A, 0.06), radius: 10, y: 2),
                    secondary: ShadowSpec(color: rgba(0x0F172A, 0.04), radius: 2, y: 0.5)
                )
            case .dark:
                DualShadow(primary: ShadowSpec(color: rgba(0x000000, 0.34), radius: 16, y: 4))
            case .black:
                .none
            case .private:
                DualShadow(primary: ShadowSpec(color: rgba(0x000000, 0.36), radius: 16, y: 4))
            }
        }

        static func focusFill(_ mode: AppearanceMode) -> GlassRecipe {
            switch mode {
            case .light:
                GlassRecipe(tintHex: 0xFFFFFF, tintOpacity: 0.35, guardHex: 0xFFFFFF, guardOpacity: 0.20,
                            solidTopHex: focusSolidLightHex, interactive: true,
                            borderColor: focusBorder(.light), borderWidth: 1.5,
                            increasedBorderColor: focusBorder(.light, increasedContrast: true))
            case .dark:
                GlassRecipe(tintHex: 0x222630, tintOpacity: 0.35, guardHex: 0x222630, guardOpacity: 0.20,
                            solidTopHex: focusSolidDarkHex, interactive: true,
                            borderColor: focusBorder(.dark), borderWidth: 1.5,
                            increasedBorderColor: focusBorder(.dark, increasedContrast: true))
            case .black:
                GlassRecipe(tintHex: 0x1E1E22, tintOpacity: 0.35,
                            solidTopHex: focusSolidBlackHex, interactive: true,
                            borderColor: focusBorder(.black), borderWidth: 1.5,
                            increasedBorderColor: focusBorder(.black, increasedContrast: true))
            case .private:
                GlassRecipe(tintHex: 0x301E4A, tintOpacity: 0.35, guardHex: 0x301E4A, guardOpacity: 0.20,
                            solidTopHex: focusSolidPrivateHex, interactive: true,
                            borderColor: focusBorder(.private), borderWidth: 1.5,
                            increasedBorderColor: focusBorder(.private, increasedContrast: true))
            }
        }

        static func focusBorder(_ mode: AppearanceMode, increasedContrast: Bool = false) -> Color {
            switch mode {
            case .light:
                increasedContrast ? Theme.hex(Semantic.accentLightHex) : rgba(Semantic.accentLightHex, 0.88)
            case .dark:
                increasedContrast ? Theme.hex(Semantic.accentDarkHex) : rgba(Semantic.accentDarkHex, 0.90)
            case .black:
                increasedContrast ? Theme.hex(Semantic.accentDarkHex) : rgba(Semantic.accentDarkHex, 0.92)
            case .private:
                increasedContrast ? Theme.hex(0xD8B4FE) : rgba(0xC084FC, 0.90)
            }
        }

        static func focusHalo(_ mode: AppearanceMode) -> Color {
            switch mode {
            case .light: rgba(Semantic.accentLightHex, 0.18)
            case .dark, .black: rgba(Semantic.accentDarkHex, 0.24)
            case .private: rgba(0xC084FC, 0.24)
            }
        }

        static func focusShadow(_ mode: AppearanceMode) -> DualShadow {
            switch mode {
            case .light: DualShadow(primary: ShadowSpec(color: rgba(0x0F172A, 0.12), radius: 20, y: 6))
            case .dark: DualShadow(primary: ShadowSpec(color: rgba(0x000000, 0.40), radius: 20, y: 6))
            case .black: .none
            case .private: DualShadow(primary: ShadowSpec(color: rgba(0x000000, 0.44), radius: 20, y: 6))
            }
        }

        static func inlineCompletionBg(_ mode: AppearanceMode) -> Color {
            switch mode {
            case .light: rgba(0x007AFF, 0.16)
            case .dark: rgba(0x3B82F6, 0.28)
            case .black: rgba(0x3B82F6, 0.30)
            case .private: rgba(0xC084FC, 0.28)
            }
        }

        static func inlineCompletionInk(_ mode: AppearanceMode) -> Color {
            switch mode {
            case .light: Theme.hex(0x0B3D78)
            case .dark: Theme.hex(0xE0EEFF)
            case .black: Theme.hex(0xFFFFFF)
            case .private: Theme.hex(0xF7F2FD)
            }
        }

        static func tabHintFill(_ mode: AppearanceMode) -> Color {
            switch mode {
            case .light: rgba(0x0F172A, 0.06)
            case .dark: rgba(0xFFFFFF, 0.09)
            case .black: Theme.hex(0x2A2A2E)
            case .private: rgba(0xD8B4FE, 0.12)
            }
        }

        static func tabHintBorder(_ mode: AppearanceMode) -> Color {
            switch mode {
            case .light: rgba(0x0F172A, 0.10)
            case .dark: rgba(0xFFFFFF, 0.14)
            case .black: Theme.hex(0x3F3F46)
            case .private: rgba(0xD8B4FE, 0.22)
            }
        }

        static let privatePillFill = rgba(0xC084FC, 0.24)
        static let privatePillBorder = rgba(0xD8B4FE, 0.34)
        static let privatePillInkHex: UInt32 = 0xEAD2FF
        static let privatePillInk = Theme.hex(privatePillInkHex)
        static let privatePillSolidFillHex: UInt32 = 0x33263D
        static let privatePillSolidInkHex: UInt32 = 0xD5AAF8
        static let privatePillSolidFill = Theme.hex(privatePillSolidFillHex)
        static let privatePillSolidInk = Theme.hex(privatePillSolidInkHex)

        static func progressBar(_ mode: AppearanceMode) -> LinearGradient {
            switch mode {
            case .light:
                LinearGradient(
                    stops: [
                        .init(color: rgba(0x007AFF, 0.18), location: 0),
                        .init(color: Theme.hex(0x007AFF), location: 0.70),
                        .init(color: Theme.hex(0x60A5FA), location: 1),
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
            case .dark:
                LinearGradient(
                    stops: [
                        .init(color: rgba(0x60A5FA, 0.15), location: 0),
                        .init(color: Theme.hex(0x60A5FA), location: 0.70),
                        .init(color: Theme.hex(0x93C5FD), location: 1),
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
            case .black:
                LinearGradient(colors: [Theme.hex(0x60A5FA), Theme.hex(0x60A5FA)],
                               startPoint: .leading, endPoint: .trailing)
            case .private:
                LinearGradient(
                    stops: [
                        .init(color: rgba(0xC084FC, 0.20), location: 0),
                        .init(color: Theme.hex(0xC084FC), location: 0.70),
                        .init(color: Theme.hex(0xE9D5FF), location: 1),
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
            }
        }

        static func progressGlow(_ mode: AppearanceMode) -> DualShadow {
            switch mode {
            case .light: DualShadow(primary: ShadowSpec(color: rgba(0x007AFF, 0.35), radius: 6))
            case .dark: DualShadow(primary: ShadowSpec(color: rgba(0x60A5FA, 0.65), radius: 8))
            case .black: .none
            case .private: DualShadow(primary: ShadowSpec(color: rgba(0xC084FC, 0.55), radius: 8))
            }
        }
    }

    // MARK: - 2.6 Popover, Suggestions, and Handoff Bar
    enum Popover {
        static let popoverSolidLightHex: UInt32 = 0xFCFDFF
        static let popoverSolidDarkHex: UInt32 = 0x22252E
        static let popoverSolidBlackHex: UInt32 = 0x141416
        static let popoverSolidPrivateHex: UInt32 = 0x2A1A42

        static func glassFill(_ mode: AppearanceMode) -> GlassRecipe {
            switch mode {
            case .light:
                GlassRecipe(tintHex: 0xFCFDFF, tintOpacity: 0.35, guardHex: 0xFCFDFF, guardOpacity: 0.20,
                            solidTopHex: popoverSolidLightHex, borderColor: border(.light),
                            specularTop: rgba(0xFFFFFF, 0.95),
                            increasedBorderColor: Card.rimIncreasedContrast(.light))
            case .dark:
                GlassRecipe(tintHex: 0x22252E, tintOpacity: 0.35, guardHex: 0x22252E, guardOpacity: 0.20,
                            solidTopHex: popoverSolidDarkHex, borderColor: border(.dark),
                            increasedBorderColor: Card.rimIncreasedContrast(.dark))
            case .black:
                GlassRecipe(tintHex: 0x141416, tintOpacity: 0.35,
                            solidTopHex: popoverSolidBlackHex, borderColor: border(.black),
                            increasedBorderColor: Card.rimIncreasedContrast(.black))
            case .private:
                GlassRecipe(tintHex: 0x2A1A42, tintOpacity: 0.35, guardHex: 0x2A1A42, guardOpacity: 0.20,
                            solidTopHex: popoverSolidPrivateHex, borderColor: border(.private),
                            increasedBorderColor: Card.rimIncreasedContrast(.private))
            }
        }

        static func border(_ mode: AppearanceMode) -> Color {
            switch mode {
            case .light: rgba(0x0F172A, 0.09)
            case .dark: rgba(0xFFFFFF, 0.14)
            case .black: rgba(0xFFFFFF, 0.14)
            case .private: rgba(0xD8B4FE, 0.24)
            }
        }

        static func shadow(_ mode: AppearanceMode) -> DualShadow {
            switch mode {
            case .light:
                DualShadow(
                    primary: ShadowSpec(color: rgba(0x0F172A, 0.22), radius: 54, y: 22),
                    secondary: ShadowSpec(color: rgba(0x0F172A, 0.08), radius: 14, y: 4)
                )
            case .dark:
                DualShadow(primary: ShadowSpec(color: rgba(0x000000, 0.55), radius: 54, y: 22))
            case .black:
                DualShadow(primary: ShadowSpec(color: rgba(0x000000, 0.70), radius: 36, y: 14))
            case .private:
                DualShadow(primary: ShadowSpec(color: rgba(0x000000, 0.58), radius: 54, y: 22))
            }
        }

        static func elevation(_ mode: AppearanceMode) -> DualShadow { shadow(mode) }
    }

    enum Suggestions {
        static func scrim(_ mode: AppearanceMode) -> Color {
            switch mode {
            case .light: rgba(0x0F1420, 0.08)
            case .dark: rgba(0x000000, 0.24)
            case .black: rgba(0x000000, 0.40)
            case .private: rgba(0x080410, 0.28)
            }
        }

        static func selectedFill(_ mode: AppearanceMode) -> LinearGradient {
            switch mode {
            case .light:
                LinearGradient(colors: [rgba(0x007AFF, 0.15), rgba(0x007AFF, 0.11)],
                               startPoint: .top, endPoint: .bottom)
            case .dark:
                LinearGradient(colors: [rgba(0x3B82F6, 0.28), rgba(0x3B82F6, 0.22)],
                               startPoint: .top, endPoint: .bottom)
            case .black:
                LinearGradient(colors: [Theme.hex(0x252A36), Theme.hex(0x252A36)],
                               startPoint: .top, endPoint: .bottom)
            case .private:
                LinearGradient(colors: [rgba(0xA855F7, 0.32), rgba(0xA855F7, 0.24)],
                               startPoint: .top, endPoint: .bottom)
            }
        }

        static func selectedBorder(_ mode: AppearanceMode, increasedContrast: Bool = false) -> Color {
            if increasedContrast { return selectedTitleInk(mode) }
            switch mode {
            case .light: return rgba(0x007AFF, 0.24)
            case .dark: return rgba(0x93C5FD, 0.30)
            case .black: return rgba(0x93C5FD, 0.32)
            case .private: return rgba(0xD8B4FE, 0.36)
            }
        }

        static let selectedTitleLightHex: UInt32 = 0x08346B
        static let selectedURLLightHex: UInt32 = 0x1E5494
        static let selectedURLDarkHex: UInt32 = 0xC7DCFF
        static let selectedURLPrivateHex: UInt32 = 0xEAD2FF

        static func selectedTitleInk(_ mode: AppearanceMode) -> Color {
            mode == .light ? Theme.hex(selectedTitleLightHex) : Theme.hex(0xFFFFFF)
        }

        static func selectedURLInk(_ mode: AppearanceMode) -> Color {
            switch mode {
            case .light: Theme.hex(selectedURLLightHex)
            case .dark, .black: Theme.hex(selectedURLDarkHex)
            case .private: Theme.hex(selectedURLPrivateHex)
            }
        }

        static func alreadyOpenPillFill(_ mode: AppearanceMode) -> Color {
            switch mode {
            case .light: rgba(0x007AFF, 0.12)
            case .dark, .black: rgba(0x3B82F6, 0.22)
            case .private: rgba(0xC084FC, 0.22)
            }
        }

        static func alreadyOpenPillBorder(_ mode: AppearanceMode) -> Color {
            switch mode {
            case .light: rgba(0x007AFF, 0.20)
            case .dark, .black: rgba(0x93C5FD, 0.30)
            case .private: rgba(0xD8B4FE, 0.34)
            }
        }

        static func alreadyOpenPillInk(_ mode: AppearanceMode) -> Color {
            switch mode {
            case .light: Theme.hex(0x0B3D78)
            case .dark, .black: Theme.hex(0xCFE4FF)
            case .private: Theme.hex(0xEAD2FF)
            }
        }

        static func returnKeyChipFill(_ mode: AppearanceMode) -> Color {
            switch mode {
            case .light: rgba(0xFFFFFF, 0.78)
            case .dark, .black: rgba(0xFFFFFF, 0.14)
            case .private: rgba(0xD8B4FE, 0.18)
            }
        }

        static func returnKeyChipBorder(_ mode: AppearanceMode) -> Color {
            switch mode {
            case .light: rgba(0x007AFF, 0.25)
            case .dark, .black: rgba(0x93C5FD, 0.32)
            case .private: rgba(0xD8B4FE, 0.36)
            }
        }

        static func returnKeyChipInk(_ mode: AppearanceMode) -> Color {
            mode == .light ? Theme.hex(0x0B3D78) : Theme.hex(0xFFFFFF)
        }

        static func enginePillFill(_ mode: AppearanceMode) -> Color {
            switch mode {
            case .light: rgba(0x0F172A, 0.05)
            case .dark: rgba(0xFFFFFF, 0.08)
            case .black: Theme.hex(0x222226)
            case .private: rgba(0xD8B4FE, 0.10)
            }
        }

        static func divider(_ mode: AppearanceMode, increasedContrast: Bool = false) -> Color {
            if increasedContrast { return Card.rimIncreasedContrast(mode) }
            switch mode {
            case .light: return rgba(0x0F172A, 0.09)
            case .dark: return rgba(0xFFFFFF, 0.10)
            case .black: return Theme.hex(0x222226)
            case .private: return rgba(0xD8B4FE, 0.14)
            }
        }
    }

    enum Handoff {
        static let solidBgHex: UInt32 = 0x33263D
        static let messageInkHex: UInt32 = 0xEAD8FF
        // Top stop tightened from #A855F7 (3.96:1) to #9B44F0 (4.68:1) so white ink passes WCAG AA across the full gradient.
        static let moveButtonTopHex: UInt32 = 0x9B44F0
        static let moveButtonBottomHex: UInt32 = 0x9333EA
        static let moveButtonSolidHex: UInt32 = 0x7E22CE

        static let bar = GlassRecipe(
            tintHex: 0x3C265E, tintOpacity: 0.34, guardHex: 0x161020, guardOpacity: 0.14,
            solidTopHex: solidBgHex, borderColor: rgba(0xD8B4FE, 0.24),
            specularTop: rgba(0xF3E8FF, 0.16),
            increasedBorderColor: Card.rimIncreasedContrast(.private)
        )
        static let shadow = DualShadow(primary: ShadowSpec(color: rgba(0x000000, 0.26), radius: 20, y: 6))
        static let messageInk = Theme.hex(messageInkHex)
        static let pickerFill = rgba(0xFFFFFF, 0.08)
        static let pickerBorder = rgba(0xD8B4FE, 0.20)
        static let moveButtonGradient = LinearGradient(
            colors: [Theme.hex(moveButtonTopHex), Theme.hex(moveButtonBottomHex)],
            startPoint: .top, endPoint: .bottom
        )
        static let moveButtonSolid = Theme.hex(moveButtonSolidHex)
        static let moveButtonInk = Theme.hex(0xFFFFFF)
    }

    // MARK: - 2.7 Start Page Surface Tokens
    enum StartPage {
        static let bigFieldSolidLightHex: UInt32 = 0xFFFFFF
        static let bigFieldSolidDarkHex: UInt32 = 0x2E2E30
        static let bigFieldSolidBlackHex: UInt32 = 0x18181B
        static let bigFieldSolidPrivateHex: UInt32 = 0x2B1D3B

        static func bigFieldFill(_ mode: AppearanceMode, focused: Bool = false) -> GlassRecipe {
            switch mode {
            case .light:
                GlassRecipe(tintHex: 0xFFFFFF, tintOpacity: focused ? 0.35 : 0.30,
                            guardHex: 0xFFFFFF, guardOpacity: focused ? 0.20 : 0.10,
                            solidTopHex: bigFieldSolidLightHex, interactive: true,
                            borderColor: focused ? bigFieldFocusBorder(.light) : rgba(0x141C2D, 0.09),
                            borderWidth: focused ? 1 : OrivOutline.hairline,
                            specularTop: rgba(0xFFFFFF, 0.95),
                            increasedBorderColor: focused ? bigFieldFocusBorder(.light, increasedContrast: true) : Card.rimIncreasedContrast(.light))
            case .dark:
                GlassRecipe(tintHex: 0x4A4D56, tintOpacity: focused ? 0.35 : 0.30,
                            guardHex: 0x222630, guardOpacity: focused ? 0.20 : 0.10,
                            solidTopHex: bigFieldSolidDarkHex, interactive: true,
                            borderColor: focused ? bigFieldFocusBorder(.dark) : rgba(0xFFFFFF, 0.18),
                            borderWidth: focused ? 1 : OrivOutline.hairline,
                            specularTop: rgba(0xFFFFFF, 0.22),
                            increasedBorderColor: focused ? bigFieldFocusBorder(.dark, increasedContrast: true) : Card.rimIncreasedContrast(.dark))
            case .black:
                GlassRecipe(tintHex: 0x18181B, tintOpacity: 0.35,
                            solidTopHex: bigFieldSolidBlackHex, interactive: true,
                            borderColor: focused ? bigFieldFocusBorder(.black) : rgba(0xFFFFFF, 0.16),
                            borderWidth: focused ? 1.5 : OrivOutline.hairline,
                            increasedBorderColor: focused ? bigFieldFocusBorder(.black, increasedContrast: true) : Card.rimIncreasedContrast(.black))
            case .private:
                GlassRecipe(tintHex: 0x604676, tintOpacity: focused ? 0.35 : 0.30,
                            guardHex: 0x2B1D3B, guardOpacity: focused ? 0.20 : 0.12,
                            solidTopHex: bigFieldSolidPrivateHex, interactive: true,
                            borderColor: focused ? bigFieldFocusBorder(.private) : rgba(0xD8B4FE, 0.24),
                            borderWidth: focused ? 1 : OrivOutline.hairline,
                            specularTop: rgba(0xEBCDFF, 0.24),
                            increasedBorderColor: focused ? bigFieldFocusBorder(.private, increasedContrast: true) : Card.rimIncreasedContrast(.private))
            }
        }

        static func bigFieldFocusBorder(_ mode: AppearanceMode, increasedContrast: Bool = false) -> Color {
            switch mode {
            case .light: Theme.hex(Semantic.linkLightHex)
            case .dark, .black: Theme.hex(0x3B9BFF)
            case .private: increasedContrast ? Theme.hex(0xD8B4FE) : Theme.hex(0xC792F5)
            }
        }

        static func bigFieldFocusHalo(_ mode: AppearanceMode) -> Color {
            switch mode {
            case .light: rgba(0x0A6CF5, 0.14)
            case .dark, .black: rgba(0x3B9BFF, 0.20)
            case .private: rgba(0xC792F5, 0.22)
            }
        }

        static func bigFieldShadow(_ mode: AppearanceMode) -> DualShadow {
            switch mode {
            case .light:
                DualShadow(
                    primary: ShadowSpec(color: rgba(0x141C3C, 0.22), radius: 20, y: 10),
                    secondary: ShadowSpec(color: rgba(0x141C3C, 0.08), radius: 6, y: 2)
                )
            case .dark, .private:
                DualShadow(primary: ShadowSpec(color: rgba(0x000000, 0.55), radius: 22, y: 10))
            case .black:
                .none
            }
        }

        static func engineChipFill(_ mode: AppearanceMode) -> Color {
            switch mode {
            case .light: rgba(0x000000, 0.055)
            case .dark, .private: rgba(0xFFFFFF, 0.08)
            case .black: Theme.hex(0x242428)
            }
        }

        static func tileHoverFill(_ mode: AppearanceMode, solid: Bool = false) -> Color {
            if solid {
                switch mode {
                case .light: return Theme.hex(0xFFFFFF)
                case .dark: return Theme.hex(0x2E323D)
                case .black: return Theme.hex(0x1C1C1C)
                case .private: return Theme.hex(0x33263D)
                }
            }
            switch mode {
            case .light: return rgba(0xFFFFFF, 0.86)
            case .dark: return rgba(0xFFFFFF, 0.16)
            case .black: return Theme.hex(0x1C1C1C)
            case .private: return rgba(0xD5AAF8, 0.20)
            }
        }

        static func tileHoverBorder(_ mode: AppearanceMode, increasedContrast: Bool = false) -> Color {
            if increasedContrast { return Card.rimIncreasedContrast(mode) }
            switch mode {
            case .light: return rgba(0x141C2D, 0.07)
            case .dark: return rgba(0xFFFFFF, 0.16)
            case .black: return Theme.hex(0x262626)
            case .private: return rgba(0xD5AAF8, 0.24)
            }
        }

        static func tileHoverShadow(_ mode: AppearanceMode) -> DualShadow {
            switch mode {
            case .light: DualShadow(primary: ShadowSpec(color: rgba(0x141C2D, 0.13), radius: 2.5, y: 1))
            case .dark, .private: DualShadow(primary: ShadowSpec(color: rgba(0x000000, 0.30), radius: 3, y: 1))
            case .black: .none
            }
        }

        static func appIconShadow(_ mode: AppearanceMode) -> DualShadow {
            switch mode {
            case .light: DualShadow(primary: ShadowSpec(color: rgba(0x141C3C, 0.35), radius: 14, y: 6))
            case .dark, .private: DualShadow(primary: ShadowSpec(color: rgba(0x000000, 0.45), radius: 14, y: 6))
            case .black: .none
            }
        }

        static func appIconInnerRim(_ mode: AppearanceMode) -> Color {
            mode == .light ? rgba(0x000000, 0.08) : rgba(0xFFFFFF, 0.12)
        }

        static func frequentCardFill(_ mode: AppearanceMode, solid: Bool = false) -> Color {
            if solid {
                switch mode {
                case .light: return Theme.hex(0xFFFFFF)
                case .dark: return Theme.hex(0x24262E)
                case .black: return Theme.hex(0x111111)
                case .private: return Theme.hex(0x23192E)
                }
            }
            switch mode {
            case .light: return rgba(0xFFFFFF, 0.86)
            case .dark, .private: return rgba(0xFFFFFF, 0.07)
            case .black: return Theme.hex(0x111111)
            }
        }

        static func frequentCardBorder(_ mode: AppearanceMode, increasedContrast: Bool = false) -> Color {
            if increasedContrast { return Card.rimIncreasedContrast(mode) }
            switch mode {
            case .light: return rgba(0x141C2D, 0.07)
            case .dark: return rgba(0xFFFFFF, 0.10)
            case .black: return Theme.hex(0x262626)
            case .private: return rgba(0xD5AAF8, 0.18)
            }
        }

        static func frequentCardShadow(_ mode: AppearanceMode) -> DualShadow {
            mode == .light ? DualShadow(primary: ShadowSpec(color: rgba(0x141C2D, 0.13), radius: 2.5, y: 1)) : .none
        }

        static let privateCardFill = rgba(0xD5AAF8, 0.09)
        static let privateCardBorder = rgba(0xD5AAF8, 0.25)
        static let privateCardSolidFillHex: UInt32 = 0x23192E
        static let privateCardSolidBorderHex: UInt32 = 0x6E4B8E
        static let privateCardSolidFill = Theme.hex(privateCardSolidFillHex)
        static let privateCardSolidBorder = Theme.hex(privateCardSolidBorderHex)

        static func keycapFill(_ mode: AppearanceMode) -> Color {
            switch mode {
            case .light: rgba(0x000000, 0.055)
            case .dark, .private: rgba(0xFFFFFF, 0.08)
            case .black: Theme.hex(0x1C1C1E)
            }
        }

        static let appIconOnColor = Theme.hex(0xFFFFFF)

        static func sampleAppIconGradient(_ index: Int) -> LinearGradient {
            switch index {
            case 0:
                LinearGradient(colors: [Theme.hex(0x4DA3FF), Theme.hex(0x1765D8)], startPoint: .topLeading, endPoint: .bottomTrailing)
            case 1:
                LinearGradient(colors: [Theme.hex(0xFF7A4D), Theme.hex(0xE8432B)], startPoint: .topLeading, endPoint: .bottomTrailing)
            case 2:
                LinearGradient(colors: [Theme.hex(0x6C8292), Theme.hex(0x42586A)], startPoint: .topLeading, endPoint: .bottomTrailing)
            default:
                LinearGradient(colors: [Theme.hex(0x24292F), Theme.hex(0x17161C)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
    }

    // MARK: - 2.8 Ink, Semantic Colours, and Focus Rings
    enum Ink {
        static let primaryLightHex: UInt32 = 0x14161A
        static let primaryDarkHex: UInt32 = 0xF5F6FA
        static let primaryBlackHex: UInt32 = 0xF5F5F5
        static let primaryPrivateHex: UInt32 = 0xF7F2FD

        static let secondaryLightHex: UInt32 = 0x4A4E59
        static let secondaryDarkHex: UInt32 = 0xB4BAC7
        static let secondaryBlackHex: UInt32 = 0xA3A3A3
        static let secondaryPrivateHex: UInt32 = 0xC8B7DE

        static let secondaryICLightHex: UInt32 = 0x36363B
        static let secondaryICDarkHex: UInt32 = 0xD9D9DD
        static let secondaryICBlackHex: UInt32 = 0xB8B8B8
        static let secondaryICPrivateHex: UInt32 = 0xE8D8FC

        static let tertiaryCardLightHex: UInt32 = 0x6E7380
        static let tertiaryCardDarkHex: UInt32 = 0x7E8594
        static let tertiaryCardBlackHex: UInt32 = 0x8A8A8A
        static let tertiaryCardPrivateHex: UInt32 = 0x9683B0

        // Tuned sidebar tertiary values so all 13 SidebarColor tints + Private pass >= 4.5:1
        // on panel/hover/search within the §6.3 live-glass guard <= 0.20 cap.
        static let tertiarySidebarLightHex: UInt32 = 0x4E5360
        static let tertiarySidebarDarkHex: UInt32 = 0xB4BAC7
        static let tertiarySidebarBlackHex: UInt32 = 0x8A8A8A
        static let tertiarySidebarPrivateHex: UInt32 = 0xB4A2CE

        static func primary(_ mode: AppearanceMode) -> Color {
            switch mode {
            case .light: Theme.hex(primaryLightHex)
            case .dark: Theme.hex(primaryDarkHex)
            case .black: Theme.hex(primaryBlackHex)
            case .private: Theme.hex(primaryPrivateHex)
            }
        }

        static func secondary(_ mode: AppearanceMode, increasedContrast: Bool = false) -> Color {
            switch (mode, increasedContrast) {
            case (.light, false): Theme.hex(secondaryLightHex)
            case (.light, true): Theme.hex(secondaryICLightHex)
            case (.dark, false): Theme.hex(secondaryDarkHex)
            case (.dark, true): Theme.hex(secondaryICDarkHex)
            case (.black, false): Theme.hex(secondaryBlackHex)
            case (.black, true): Theme.hex(secondaryICBlackHex)
            case (.private, false): Theme.hex(secondaryPrivateHex)
            case (.private, true): Theme.hex(secondaryICPrivateHex)
            }
        }

        static func tertiary(_ mode: AppearanceMode, onSidebar: Bool = false, increasedContrast: Bool = false) -> Color {
            if increasedContrast { return secondary(mode, increasedContrast: true) }
            switch (mode, onSidebar) {
            case (.light, false): return Theme.hex(tertiaryCardLightHex)
            case (.light, true): return Theme.hex(tertiarySidebarLightHex)
            case (.dark, false): return Theme.hex(tertiaryCardDarkHex)
            case (.dark, true): return Theme.hex(tertiarySidebarDarkHex)
            case (.black, _): return Theme.hex(tertiaryCardBlackHex)
            case (.private, false): return Theme.hex(tertiaryCardPrivateHex)
            case (.private, true): return Theme.hex(tertiarySidebarPrivateHex)
            }
        }
    }

    enum Semantic {
        static let accentLightHex: UInt32 = 0x007AFF
        static let linkLightHex: UInt32 = 0x0A6CF5
        static let accentDarkHex: UInt32 = 0x3B82F6
        static let privateAccentLightHex: UInt32 = 0x713692
        static let privateAccentDarkHex: UInt32 = 0xD8B4FE
        static let privateAccentStrongHex: UInt32 = 0xC084FC
        static let privateAccentICLightHex: UInt32 = 0x521E70
        static let privateAccentICDarkHex: UInt32 = 0xF0DBFF

        static func accent(_ mode: AppearanceMode) -> Color {
            mode == .private ? Theme.hex(privateAccentDarkHex) : Color(nsColor: .controlAccentColor)
        }

        static func danger(_ mode: AppearanceMode) -> Color {
            mode == .light ? Theme.hex(0xB3261E) : Theme.hex(0xFF9A8F)
        }

        static func warning(_ mode: AppearanceMode) -> Color {
            switch mode {
            case .light: Theme.hex(0x794900)
            case .dark, .private: Theme.hex(0xE0AA55)
            case .black: Theme.hex(0xD9A04A)
            }
        }

        static func success(_ mode: AppearanceMode) -> Color {
            mode == .light ? Theme.hex(0x1D6B3A) : Theme.hex(0x7FD99A)
        }

        static func privateAccent(_ mode: AppearanceMode, increasedContrast: Bool = false) -> Color {
            switch (mode, increasedContrast) {
            case (.light, false): Theme.hex(privateAccentLightHex)
            case (.light, true): Theme.hex(privateAccentICLightHex)
            case (_, false): Theme.hex(privateAccentDarkHex)
            case (_, true): Theme.hex(privateAccentICDarkHex)
            }
        }
    }

    enum Focus {
        static let sidebarRingLightHex: UInt32 = 0x0F172A
        static let sidebarRingDarkHex: UInt32 = 0xFFFFFF
        static let sidebarRingPrivateHex: UInt32 = 0xF7F2FD
        static let sidebarRingWidth: CGFloat = OrivOutline.focus
        static let sidebarRingInset: CGFloat = OrivOutline.focusInset
        static let addressHaloWidth: CGFloat = 3.5

        static func sidebarRing(_ mode: AppearanceMode) -> Color {
            switch mode {
            case .light: Theme.hex(sidebarRingLightHex)
            case .dark, .black: Theme.hex(sidebarRingDarkHex)
            case .private: Theme.hex(sidebarRingPrivateHex)
            }
        }

        static func addressRing(_ mode: AppearanceMode, increasedContrast: Bool = false) -> Color {
            Address.focusBorder(mode, increasedContrast: increasedContrast)
        }

        static func addressRingWidth(increasedContrast: Bool = false) -> CGFloat {
            increasedContrast ? OrivOutline.focus : 1.5
        }
    }

    // MARK: - 3.1 Radius Ladder
    enum Radius {
        static let sidebarFavicon: CGFloat = 5
        static let tabHint: CGFloat = 5
        static let accessory: CGFloat = 6
        static let profileAvatar: CGFloat = 7
        static let control: CGFloat = 8
        static let sidebarSearch: CGFloat = 9
        static let row: CGFloat = 10
        static let pageCard: CGFloat = 12
        static let startAppIcon: CGFloat = 12.5
        static let sidebar: CGFloat = 14
        static let startCard: CGFloat = 16
        static let privateCard: CGFloat = 20
        static let bigField: CGFloat = 26
        static let capsule = Capsule()
    }

    // MARK: - 3.2 Window Frame, Insets, and Fullscreen
    enum Frame {
        static let windowInset: CGFloat = 8
        static let sidebarCardGap: CGFloat = 8
        static let expandedReservation: CGFloat = SidebarLayout.width + windowInset + sidebarCardGap // 272
        static let railReservation: CGFloat = SidebarLayout.railWidth + windowInset + sidebarCardGap // 88
        static let fullscreenInset: CGFloat = 8
        static let webpageFullscreenInset: CGFloat = 0

        static func expandedReservation(sidebarWidth: CGFloat) -> CGFloat {
            sidebarWidth + windowInset + sidebarCardGap
        }
    }

    // MARK: - 3.3 Sidebar, Rail, and Traffic Lights (Q1, Q2, Q3 applied)
    enum SidebarLayout {
        static let width: CGFloat = 256
        static let widthRange: ClosedRange<CGFloat> = 220...360
        static let railWidth: CGFloat = 72 // Q2
        static let innerPaddingHorizontal: CGFloat = 8
        static let innerPaddingBottom: CGFloat = 8
        static let innerPaddingTop: CGFloat = 0
        // Q1: Sidebar titlebar (52 pt) and toolbar band (52 pt) share one horizontal centre line at y = 34 pt.
        static let titlebarHeight: CGFloat = 52
        static let lightsLeading: CGFloat = 22
        static let lightsRailLeading: CGFloat = 17
        static let lightsCenterY: CGFloat = 34 // 8 pt windowInset + 26 pt half of 52 pt titlebar
        static let lightsSpacing: CGFloat = 20
        static let lightDiameter: CGFloat = 12
        static let lightGap: CGFloat = 8
        static let toggleSize: CGFloat = 28
        static let profileHeight: CGFloat = 34
        static let profileBottomMargin: CGFloat = 6
        static let profileAvatarSize: CGFloat = 22
        static let searchHeight: CGFloat = 30
        static let searchBottomMargin: CGFloat = 14
        static let searchPaddingHorizontal: CGFloat = 9
        static let searchInnerGap: CGFloat = 7
        static let sectionHeight: CGFloat = 22
        static let sectionBottomMargin: CGFloat = 5
        static let sectionPaddingHorizontal: CGFloat = 8
        // Q3: Adaptive columns with 52 pt minimum tile width and 40 pt height (4 cols at 256 pt, up to 6 at 360 pt).
        static let pinMinWidth: CGFloat = 52
        static let pinColumns: Int = 4
        static let pinMaxColumns: Int = 6
        static let pinHeight: CGFloat = 40
        static let pinGap: CGFloat = 6
        static let pinBottomMargin: CGFloat = 16
        static let pinIconSize: CGFloat = 18
        static let pinIconMaxSize: CGFloat = 20
        static let tabRowHeight: CGFloat = 34
        static let tabRowGap: CGFloat = 2
        static let tabRowPaddingHorizontal: CGFloat = 8
        static let tabRowInnerGap: CGFloat = 9
        static let tabFaviconSize: CGFloat = 18
        static let accessoryVisual: CGFloat = 20
        static let accessoryHitTarget: CGFloat = 24
        static let newTabHeight: CGFloat = 34
        static let newTabTopMargin: CGFloat = 6
        static let profileDotSize: CGFloat = 7
        static let profileDotGap: CGFloat = 10
        static let profileDotsPaddingTop: CGFloat = 6
        static let profileDotsPaddingBottom: CGFloat = 8
        static let profileDotHitTarget: CGFloat = 24
        static let footerHeight: CGFloat = 40
        static let footerPaddingTop: CGFloat = 6
        static let footerGap: CGFloat = 4
        static let footerButtonSize: CGFloat = 32
        static let downloadDotSize: CGFloat = 6
        static let railItemSize = CGSize(width: 42, height: 36)
        static let railFaviconSize: CGFloat = 22
    }

    // MARK: - 3.4 Toolbar, Address Capsule, Suggestions, and Handoff Bar (Q1 applied)
    enum ToolbarLayout {
        // Q1: Toolbar band inside page card is 52 pt (centres at y = 34 pt from window top with 8 pt inset).
        static let overlayHeight: CGFloat = 52
        static let innerHeight: CGFloat = 36
        static let paddingHorizontal: CGFloat = 14
        static let groupHeight: CGFloat = 34
        static let groupPadding: CGFloat = 3
        static let groupGap: CGFloat = 2
        static let buttonSize: CGFloat = 28
        static let dividerSize = CGSize(width: 0.5, height: 14)
        static let dividerMarginHorizontal: CGFloat = 1
        static let shieldDotSize: CGFloat = 5
        static let shieldDotInset: CGFloat = 5
        static let addressRestWidth: CGFloat = 520
        static let addressMinWidth: CGFloat = 230
        static let addressRestHeight: CGFloat = 34
        static let addressRestPaddingHorizontal: CGFloat = 5
        static let addressInlineIconSize: CGFloat = 24
        static let addressSideSlotWidth: CGFloat = 48
        static let addressFocusWidth: CGFloat = 576
        static let addressFocusHeight: CGFloat = 36
        static let addressFocusLeadingPadding: CGFloat = 10
        static let addressFocusTrailingPadding: CGFloat = 6
        static let addressFocusGap: CGFloat = 8
        static let privatePillHeight: CGFloat = 24
        static let privatePillPaddingHorizontal: CGFloat = 9
        static let privatePillGap: CGFloat = 5
        static let progressHeight: CGFloat = 2
        static let progressHorizontalInset: CGFloat = 16
        static let suggestionsWidth: CGFloat = 576
        static let suggestionsTopGap: CGFloat = 7
        static let suggestionsPadding: CGFloat = 8
        static let suggestionRowHeight: CGFloat = 46
        static let suggestionRowPaddingHorizontal: CGFloat = 10
        static let suggestionRowGap: CGFloat = 11
        static let suggestionIconSize: CGFloat = 24
        static let suggestionSearchRowHeight: CGFloat = 38
        static let handoffHeight: CGFloat = 44
        static let handoffTopOffset: CGFloat = 58
        static let handoffHorizontalInset: CGFloat = 24
        static let handoffLeadingPadding: CGFloat = 14
        static let handoffTrailingPadding: CGFloat = 10
        static let handoffGap: CGFloat = 12
        static let handoffControlHeight: CGFloat = 26
    }

    // MARK: - 3.5 Start Page Geometry (Mac-only; Q8 applied)
    enum StartLayout {
        static let columnWidth: CGFloat = 724
        static let columnMinHorizontalMargin: CGFloat = 24
        static let headerTopMargin: CGFloat = 150
        static let shortWindowHeightThreshold: CGFloat = 760
        static let profileChipAvatar: CGFloat = 18
        static let profileChipGap: CGFloat = 8
        static let titleTopGap: CGFloat = 8
        static let bigFieldSize = CGSize(width: 724, height: 52)
        static let bigFieldTopMargin: CGFloat = 26
        static let bigFieldLeadingPadding: CGFloat = 18
        static let bigFieldTrailingPadding: CGFloat = 10
        static let bigFieldGap: CGFloat = 12
        static let engineChipHeight: CGFloat = 32
        static let engineChipPaddingHorizontal: CGFloat = 12
        static let engineChipGap: CGFloat = 6
        static let engineChipIconSize: CGFloat = 12
        static let sectionTopGap: CGFloat = 44
        static let sectionContentTopGap: CGFloat = 10
        static let bookmarkColumns: Int = 8
        static let bookmarkCompactColumns: Int = 4
        static let bookmarkWrapCardWidth: CGFloat = 772
        static let bookmarkGap: CGFloat = 8
        static let bookmarkIconSize: CGFloat = 52
        static let bookmarkTilePaddingTop: CGFloat = 12
        static let bookmarkTilePaddingHorizontal: CGFloat = 4
        static let bookmarkTilePaddingBottom: CGFloat = 10
        static let bookmarkTileGap: CGFloat = 8
        static let frequentCardPadding: CGFloat = 6
        static let frequentColumns: Int = 2
        static let frequentCollapseCardWidth: CGFloat = 600
        static let frequentRowHeight: CGFloat = 40
        static let frequentRowPaddingHorizontal: CGFloat = 10
        static let frequentRowGap: CGFloat = 10
        static let frequentFaviconSize: CGFloat = 20
        static let frequentFaviconRadius: CGFloat = 4.8
        static let privateCardTopGap: CGFloat = 40
        static let privateCardPaddingVertical: CGFloat = 22
        static let privateCardPaddingHorizontal: CGFloat = 26
        static let privateCardColumns: Int = 2
        static let privateCardRowGap: CGFloat = 10
        static let privateCardColumnGap: CGFloat = 34
        static let privateCardItemTopMargin: CGFloat = 8
        static let privateCardIconSize: CGFloat = 16
        static let footerBottomInset: CGFloat = 22
        static let footerGap: CGFloat = 22
        static let keycapPaddingVertical: CGFloat = 1
        static let keycapPaddingHorizontal: CGFloat = 5
        static let keycapTrailingMargin: CGFloat = 5
    }

    // MARK: - 4.1 Typography
    // Named `Typography` instead of `Type` because Swift always resolves `.Type` as a metatype.
    enum Typography {
        static let startHeroTitle: Font = .system(size: 30, weight: .bold)
        static let startHeroTracking: CGFloat = -0.5
        static let startBigField: Font = .system(size: 16, weight: .regular)
        static let addressFocused: Font = .system(size: 13.5, weight: .regular)
        static let addressFocusedTyped: Font = .system(size: 13.5, weight: .medium)
        static let addressRest: Font = .system(size: 13, weight: .medium)
        static let sidebarProfile: Font = .system(size: 13, weight: .semibold)
        static let sidebarRowActive: Font = .system(size: 13, weight: .semibold)
        static let sidebarRow: Font = .system(size: 13, weight: .regular)
        static let sidebarNewTab: Font = .system(size: 13, weight: .medium)
        static let startSectionHeader: Font = .system(size: 13, weight: .semibold)
        static let startBody: Font = .system(size: 13, weight: .regular)
        static let handoffMessage: Font = .system(size: 12.5, weight: .regular)
        static let handoffAppName: Font = .system(size: 12.5, weight: .semibold)
        static let detail: Font = .system(size: 12, weight: .regular)
        static let detailSemibold: Font = .system(size: 12, weight: .semibold)
        static let suggestionURL: Font = .system(size: 11.5, weight: .regular)
        static let sectionLabel: Font = .system(size: 11, weight: .semibold)
        static let sectionCount: Font = .system(size: 11, weight: .medium).monospacedDigit()
        static let shortcutHint: Font = .system(size: 10.5, weight: .medium).monospacedDigit()
        static let shortcutHintBold: Font = .system(size: 10.5, weight: .semibold).monospacedDigit()
        static let appIconMonogram: Font = .system(size: 28, weight: .bold)
        static let tightTracking: CGFloat = -0.065
        static let labelTracking: CGFloat = 0.22
    }

    // MARK: - 4.2 Motion
    enum Motion {
        static let quick = Animation.easeOut(duration: 0.10)
        static let standard = Animation.easeInOut(duration: 0.20)
        static let standardReduced = Animation.easeInOut(duration: 0.15)
        static let addressFocus = Animation.spring(response: 0.24, dampingFraction: 0.88)
        static let addressMorph = Animation.spring(response: 0.34, dampingFraction: 0.90)
        static let addressMorphReduced = Animation.easeInOut(duration: 0.15)
        static let popover = Animation.spring(response: 0.22, dampingFraction: 0.92)
        static let popoverReduced = Animation.easeInOut(duration: 0.12)
        static let progressShimmer = Animation.easeOut(duration: 0.18)
        static let tabLoading = Animation.linear(duration: 0.90).repeatForever(autoreverses: false)

        static func quick(reduceMotion: Bool) -> Animation? { reduceMotion ? nil : quick }
        static func standard(reduceMotion: Bool) -> Animation { reduceMotion ? standardReduced : standard }
        static func addressFocus(reduceMotion: Bool) -> Animation? { reduceMotion ? nil : addressFocus }
        static func addressMorph(reduceMotion: Bool) -> Animation { reduceMotion ? addressMorphReduced : addressMorph }
        static func popover(reduceMotion: Bool) -> Animation { reduceMotion ? popoverReduced : popover }
        static func progressShimmer(reduceMotion: Bool) -> Animation? { reduceMotion ? nil : progressShimmer }
        static func tabLoading(reduceMotion: Bool) -> Animation? { reduceMotion ? nil : tabLoading }
    }
}

extension View {
    func orivV3Glass<S: InsettableShape>(_ recipe: OrivMacV3.GlassRecipe, in shape: S, forceSolid: Bool = false) -> some View {
        modifier(OrivMacV3.GlassModifier(recipe: recipe, shape: shape, forceSolid: forceSolid))
    }

    func orivV3Shadow(_ shadow: OrivMacV3.DualShadow) -> some View {
        modifier(OrivMacV3.DualShadowModifier(shadow: shadow))
    }
}
#endif
