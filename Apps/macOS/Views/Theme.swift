import BrowserCore
import SwiftUI

/// Shared by the Mac and iPhone targets. Existing stored appearance names remain valid.
enum BrowserAppearance: String, CaseIterable, Identifiable {
    case system = "System", light = "Light", dark = "Dark", t3Code = "T3 Code"
    var id: String { rawValue }
    var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark, .t3Code: .dark }
    }
    var theme: Theme { self == .t3Code ? .t3Code : .classic }
}

/// Color roles, rather than process-wide mutable colors, keep profile windows and previews independent.
struct Theme {
    let isT3Code: Bool
    let accent: Color
    let canvas: Color
    let surface: Color
    let field: Color
    let chrome: Color
    let separator: Color
    let text: Color
    let secondaryText: Color
    let selection: Color
    let thread: Color
    /// Accent for text and small glyphs. The brand accent stays for fills, focus and selection.
    var accentText: Color
    let privateAccent = adaptive("Private", light: 0x8944AB, dark: 0xBB85F5)
    var controlFill: Color { isT3Code ? Self.hex(0x346BF1) : accent }
    /// Placeholders must read as hints, never as entered content.
    var fieldText: Color { secondaryText }
    var page: Color { isT3Code ? canvas : surface }
    /// One background for every list and form row.
    var row: Color { surface }
    /// Muted amber, used only for connection warnings such as "Not secure" (7.2:1 on the T3 field).
    var warning: Color { isT3Code ? Self.hex(0xD9A04A) : Self.classicWarning }
    private static let classicWarning = adaptive("Warning", light: 0x8A5300, dark: 0xD9A04A)

    // T3 Code Nightly 0.1.7-nightly.20261103.4119, built-in dark palette.
    // The app's default dark canvas overrides its base palette to pure black.
    // Secondary text and accent text are lightened from the palette so they reach 4.5:1 on every surface.
    static let t3Code = Theme(isT3Code: true, accent: hex(0x346BF1), canvas: hex(0x000000),
        surface: hex(0x111111), field: hex(0x1E1E1E), chrome: hex(0x0A0A0A), separator: hex(0x191919),
        text: hex(0xF5F5F5), secondaryText: hex(0xA3A3A3), selection: hex(0x1C1C1C), thread: hex(0x191919),
        accentText: hex(0x5B8CFF))
    static let classic = Theme(isT3Code: false, accent: adaptive("Mulberry", light: 0x713C52, dark: 0xE3ADC4),
        canvas: adaptive("Mist", light: 0xF3F0F5, dark: 0x1D1B20),
        surface: adaptive("Paper", light: 0xFCFAFD, dark: 0x252228), field: nativeField, chrome: nativeChrome,
        separator: nativeSeparator, text: adaptive("Ink", light: 0x1D1B20, dark: 0xF5F5F5),
        secondaryText: adaptive("Secondary", light: 0x66626A, dark: 0xABA6AF),
        selection: adaptive("Selection", light: 0xE8DFEA, dark: 0x322C35),
        thread: adaptive("Thread", light: 0xC8B8CD, dark: 0x6C5B73),
        accentText: adaptive("Mulberry", light: 0x713C52, dark: 0xE3ADC4))

    func respecting(_ contrast: ColorSchemeContrast) -> Theme {
        guard isT3Code && contrast == .increased else { return self }
        return Theme(isT3Code: true, accent: accent, canvas: canvas, surface: surface,
            field: field, chrome: chrome, separator: Self.hex(0x818181), text: text,
            secondaryText: Self.hex(0xB8B8B8), selection: Self.hex(0x242424), thread: thread,
            accentText: Self.hex(0x79A5FF))
    }
    #if os(macOS)
    private static let nativeField = Color(nsColor: .textBackgroundColor)
    private static let nativeChrome = Color(nsColor: .windowBackgroundColor)
    private static let nativeSeparator = Color(nsColor: .separatorColor)
    #else
    private static let nativeField = Color(uiColor: .secondarySystemGroupedBackground)
    private static let nativeChrome = Color(uiColor: .systemBackground)
    private static let nativeSeparator = Color(uiColor: .separator)
    #endif

    static func editorial(_ size: CGFloat) -> Font { .system(size: size, weight: .medium, design: .serif) }
    private static func hex(_ value: UInt32) -> Color {
        Color(.sRGB, red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255,
              blue: Double(value & 255) / 255, opacity: 1)
    }
    private static func adaptive(_ name: String, light: UInt32, dark: UInt32) -> Color {
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

private struct BrowserThemeKey: EnvironmentKey { static let defaultValue: Theme = .classic }
extension EnvironmentValues {
    var browserTheme: Theme {
        get { self[BrowserThemeKey.self] }
        set { self[BrowserThemeKey.self] = newValue }
    }
}

private struct BrowserAppearanceModifier: ViewModifier {
    let appearance: BrowserAppearance
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        let theme = appearance.theme.respecting(contrast)
        content.environment(\.browserTheme, theme)
            .preferredColorScheme(appearance.colorScheme)
            // macOS 27 uses tint for Form picker values and text buttons, just as iOS does.
            // Text controls inherit accentText; fills, focus and selection opt in to accent/controlFill.
            .tint(theme.accentText).accentColor(theme.accentText)
            .background(theme.canvas)
            #if os(macOS)
            .toolbarBackground(theme.chrome, for: .windowToolbar)
            .toolbarBackground(theme.isT3Code ? .visible : .automatic, for: .windowToolbar)
            #else
            .toolbarBackground(theme.chrome, for: .navigationBar, .tabBar)
            .toolbarBackground(theme.isT3Code ? .visible : .automatic, for: .navigationBar, .tabBar)
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

    func browserAppearance(_ appearance: BrowserAppearance) -> some View {
        modifier(BrowserAppearanceModifier(appearance: appearance))
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
                }.padding(8).frame(width: 36).background(theme.canvas)
                VStack(alignment: .leading, spacing: 8) {
                    Capsule().fill(theme.field).frame(height: 8)
                    RoundedRectangle(cornerRadius: 2).fill(theme.accent).frame(width: 32, height: 5)
                    RoundedRectangle(cornerRadius: 2).fill(theme.secondaryText.opacity(0.4)).frame(height: 3)
                    Spacer()
                }.padding(8).frame(maxWidth: .infinity)
            }.frame(height: 78).background(theme.page).clipShape(.rect(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(theme.separator, lineWidth: 1) }
        }
    }
}

struct OrivIdentity: View {
    @Environment(\.browserTheme) private var theme
    var subtitle: String? = nil
    var body: some View {
        HStack(spacing: 10) {
            Image("OrivMark").resizable().scaledToFit().frame(width: 30, height: 30)
                .clipShape(.rect(cornerRadius: 8)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(AppIdentity.name).font(.headline.weight(.semibold))
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(theme.secondaryText) }
            }
        }
    }
}

/// A quiet continuation of the app mark, kept away from controls and reading text.
struct OrivThread: View {
    @Environment(\.browserTheme) private var theme
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        Canvas { context, size in
            var path = Path()
            let w = size.width, h = size.height
            path.move(to: CGPoint(x: 0, y: h * 0.7))
            path.addCurve(to: CGPoint(x: w, y: h * 0.3), control1: CGPoint(x: w * 0.6, y: h * 0.7), control2: CGPoint(x: w * 0.4, y: -h * 0.2))
            path.addCurve(to: CGPoint(x: 0, y: h * 0.3), control1: CGPoint(x: w * 1.1, y: h * 1.1), control2: CGPoint(x: w * 0.3, y: h * 1.1))
            path.addCurve(to: CGPoint(x: w, y: h * 0.7), control1: CGPoint(x: -w * 0.1, y: -h * 0.1), control2: CGPoint(x: w * 0.4, y: -h * 0.1))
            context.stroke(path, with: .color(theme.thread), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        }.opacity(contrast == .increased ? 0 : 0.65).accessibilityHidden(true).allowsHitTesting(false)
    }
}

struct EditorHeading: View {
    @Environment(\.browserTheme) private var theme
    let title: String
    let subtitle: String
    let symbol: String
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.system(size: 21, weight: .light)).foregroundStyle(theme.accent)
                .frame(width: 42, height: 42).background(theme.accent.opacity(0.08), in: .rect(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(Theme.editorial(25)).foregroundStyle(theme.text).accessibilityAddTraits(.isHeader)
                Text(subtitle).font(.callout).foregroundStyle(theme.secondaryText)
            }
        }.padding(.bottom, 6)
    }
}

/// Quiet content affordance. Navigation and toolbars retain their system materials.
struct ContentButtonStyle: ButtonStyle {
    @Environment(\.colorSchemeContrast) private var contrast
    func makeBody(configuration: Configuration) -> some View {
        HoverContent(configuration: configuration, contrast: contrast)
    }

    private struct HoverContent: View {
        @Environment(\.browserTheme) private var theme
        let configuration: Configuration
        let contrast: ColorSchemeContrast
        @Environment(\.isFocused) private var isFocused
        @State private var hovered = false
        var body: some View {
            configuration.label
                .background {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.primary.opacity(configuration.isPressed ? 0.10 : hovered ? 0.05 : 0))
                }
                .overlay {
                    if isFocused {
                        RoundedRectangle(cornerRadius: 10).strokeBorder(theme.accent, lineWidth: 2)
                    } else if hovered && contrast == .increased {
                        RoundedRectangle(cornerRadius: 10).strokeBorder(theme.separator, lineWidth: 1)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 10))
                .onHover { hovered = $0 }
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

/// The selected row's marker: a narrow brand-accent bar (4.3:1 on the T3 toolbar, 3.7:1 on the selection fill).
struct SelectionMarker: View {
    @Environment(\.browserTheme) private var theme
    var height: CGFloat = 16
    var body: some View {
        Capsule().fill(theme.accent).frame(width: 3, height: height).accessibilityHidden(true)
    }
}

/// Selected-row background with the leading marker, for lists that draw their own selection.
struct SelectedRowBackground: View {
    @Environment(\.browserTheme) private var theme
    var cornerRadius: CGFloat = 7
    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius).fill(theme.selection)
            .overlay(alignment: .leading) { SelectionMarker().padding(.leading, 2) }
    }
}

/// Local symbols/monograms avoid sending browsing history to a favicon service.
/// Deliberately monochrome so pages, not decoration, carry the colour.
struct SiteIdentity: View {
    @Environment(\.browserTheme) private var theme
    var url: URL?
    var size: CGFloat = 32
    var isPrivate = false
    var isSelected = false

    /// The site's own name (apple in developer.apple.com), not a subdomain such as en. or www.
    private var host: String {
        let labels = (url?.host() ?? "").split(separator: ".")
        return labels.count >= 2 ? String(labels[labels.count - 2]) : labels.first.map(String.init) ?? ""
    }
    private var symbol: String? {
        if isPrivate { return "eyeglasses" }
        if url == nil || host.isEmpty { return "globe" }
        if host.first?.isLetter != true { return "globe" }
        return nil
    }
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.27).fill(theme.field)
            if let symbol {
                Image(systemName: symbol).font(.system(size: size * 0.42, weight: .medium))
            } else {
                Text(String(host.prefix(1)).uppercased())
                    .font(.system(size: size * 0.46, weight: .semibold, design: .rounded))
            }
        }
        .foregroundStyle(isPrivate ? theme.privateAccent : (isSelected ? theme.text : theme.secondaryText))
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

extension View {
    /// Shared list/form chrome: canvas behind, one row surface, no system grouped grey.
    func orivListStyle(_ theme: Theme) -> some View {
        scrollContentBackground(.hidden).background(theme.canvas)
    }
}

/// The address line under a row's title (see `URLDisplay`). Pass the list's context so rows
/// with the same title gain just enough path or query to be told apart.
func secondaryLine(title: String, url: URL?, in context: URLDisplay.Context? = nil) -> String? {
    if let context { return context.secondaryLine(title: title, url: url) }
    return URLDisplay.secondaryLine(title: title, url: url)
}
