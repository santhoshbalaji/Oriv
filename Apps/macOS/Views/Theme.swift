import SwiftUI

enum Theme {
    static let accent = adaptive("Mulberry", light: 0x713C52, dark: 0xE3ADC4)
    static let privateAccent = Color(nsColor: .systemPurple)
    static let canvas = adaptive("Mist", light: 0xF3F0F5, dark: 0x1D1B20)
    static let surface = adaptive("Paper", light: 0xFCFAFD, dark: 0x252228)
    static let completion = adaptive("Fern", light: 0x35685D, dark: 0xA6CDBF)
    static let thread = adaptive("Thread", light: 0xC8B8CD, dark: 0x6C5B73)
    static let field = Color(nsColor: .textBackgroundColor)
    static let separator = Color(nsColor: .separatorColor)

    static func editorial(_ size: CGFloat) -> Font { .system(size: size, weight: .medium, design: .serif) }
    private static func adaptive(_ name: String, light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: name) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }
}

struct OrivIdentity: View {
    var subtitle: String? = nil
    var body: some View {
        HStack(spacing: 10) {
            Image("OrivMark").resizable().scaledToFit().frame(width: 30, height: 30)
                .clipShape(.rect(cornerRadius: 8)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Oriv").font(.system(size: 17, weight: .semibold, design: .serif))
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

/// A quiet continuation of the app mark, kept away from controls and reading text.
struct OrivThread: View {
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        Canvas { context, size in
            var path = Path()
            let w = size.width, h = size.height
            path.move(to: CGPoint(x: 0, y: h * 0.7))
            path.addCurve(to: CGPoint(x: w, y: h * 0.3), control1: CGPoint(x: w * 0.6, y: h * 0.7), control2: CGPoint(x: w * 0.4, y: -h * 0.2))
            path.addCurve(to: CGPoint(x: 0, y: h * 0.3), control1: CGPoint(x: w * 1.1, y: h * 1.1), control2: CGPoint(x: w * 0.3, y: h * 1.1))
            path.addCurve(to: CGPoint(x: w, y: h * 0.7), control1: CGPoint(x: -w * 0.1, y: -h * 0.1), control2: CGPoint(x: w * 0.4, y: -h * 0.1))
            context.stroke(path, with: .color(Theme.thread), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        }.opacity(contrast == .increased ? 0 : 0.65).accessibilityHidden(true).allowsHitTesting(false)
    }
}

struct EditorHeading: View {
    let title: String
    let subtitle: String
    let symbol: String
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.system(size: 21, weight: .light)).foregroundStyle(Theme.accent)
                .frame(width: 42, height: 42).background(Theme.accent.opacity(0.08), in: .rect(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(Theme.editorial(25)).accessibilityAddTraits(.isHeader)
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
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
        let configuration: Configuration
        let contrast: ColorSchemeContrast
        @State private var hovered = false
        var body: some View {
            configuration.label
                .background {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.primary.opacity(configuration.isPressed ? 0.10 : hovered ? 0.05 : 0))
                }
                .overlay {
                    if hovered && contrast == .increased {
                        RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.separator, lineWidth: 1)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 10))
                .onHover { hovered = $0 }
        }
    }
}

/// Local symbols/monograms avoid sending browsing history to a favicon service.
struct SiteIdentity: View {
    var url: URL?
    var size: CGFloat = 32
    var isPrivate = false
    var isSelected = false

    private var host: String { url?.host()?.replacingOccurrences(of: "www.", with: "") ?? "" }
    private var symbol: String? {
        if isPrivate { return "eyeglasses" }
        if url == nil { return "safari" }
        switch host {
        case "apple.com", "developer.apple.com": return "apple.logo"
        case "github.com": return "chevron.left.forwardslash.chevron.right"
        case "wikipedia.org", "en.wikipedia.org": return "book.closed"
        case "duckduckgo.com": return "magnifyingglass"
        default: return nil
        }
    }
    private var color: Color {
        if isSelected { return .primary }
        if isPrivate { return Theme.privateAccent }
        switch host {
        case "apple.com", "developer.apple.com": return .primary
        case "github.com": return .purple
        case "wikipedia.org", "en.wikipedia.org": return .brown
        case "duckduckgo.com": return .orange
        default: return Theme.accent
        }
    }
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.27)
                .fill(color.opacity(0.09))
            if let symbol {
                Image(systemName: symbol).font(.system(size: size * 0.45, weight: .medium))
            } else {
                Text(String(host.prefix(1)).uppercased())
                    .font(.system(size: size * 0.48, weight: .semibold, design: .rounded))
            }
        }
        .foregroundStyle(color)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
