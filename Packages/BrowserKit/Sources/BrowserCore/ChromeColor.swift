import Foundation

/// sRGB values shared by the two native chrome implementations. No page data is persisted.
public struct ChromeColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double
    public init(_ red: Double, _ green: Double, _ blue: Double, alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }
    public var usable: Bool { [red, green, blue, alpha].allSatisfy { $0.isFinite && (0...1).contains($0) } && alpha > 0 }
    public func over(_ base: ChromeColor) -> ChromeColor {
        ChromeColor(red * alpha + base.red * (1 - alpha), green * alpha + base.green * (1 - alpha), blue * alpha + base.blue * (1 - alpha))
    }
    private func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    public var luminance: Double { 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue) }
    public var whiteForeground: Bool { luminance < sqrt(1.05 * 0.05) - 0.05 }
    public var foregroundContrast: Double { whiteForeground ? 1.05 / (luminance + 0.05) : (luminance + 0.05) / 0.05 }
    private var lab: (Double, Double, Double) {
        let r = linear(red), g = linear(green), b = linear(blue)
        func f(_ t: Double) -> Double { t > 216.0 / 24389 ? pow(t, 1.0 / 3) : (24389.0 / 27 * t + 16) / 116 }
        let x = f((0.4124564*r + 0.3575761*g + 0.1804375*b) / 0.95047)
        let y = f(0.2126729*r + 0.7151522*g + 0.0721750*b)
        let z = f((0.0193339*r + 0.1191920*g + 0.9503041*b) / 1.08883)
        return (116*y - 16, 500*(x-y), 200*(y-z))
    }
    /// CIE76 in D65 Lab, also used by the capture evidence measurements.
    public func deltaE(_ other: ChromeColor) -> Double {
        let a = lab, b = other.lab
        return sqrt(pow(a.0-b.0, 2) + pow(a.1-b.1, 2) + pow(a.2-b.2, 2))
    }
}

public enum ChromeColorSelection {
    /// Safari 26 ignores author theme colours in normal tabs. The viewport edge
    /// extends a constrained container, otherwise the body/html canvas is used.
    public static func select(edge: ChromeColor?, body: ChromeColor?, html: ChromeColor?, isDimming: Bool = false,
                              underPage: ChromeColor?, neutral: ChromeColor, isPrivate: Bool = false) -> ChromeColor {
        if isPrivate { return neutral }
        let base = underPage.flatMap { $0.usable ? $0.over(neutral) : nil } ?? neutral
        let root = html.flatMap { $0.usable ? $0.over(base) : nil } ?? base
        let page = body.flatMap { $0.usable ? $0.over(root) : nil } ?? root
        guard let edge, edge.usable else { return page }
        // WebKit PageColorSampler::finishedFixedContainerColor clamps at .75.
        // Dimming overlays always composite, even above that opacity threshold.
        if isDimming || edge.alpha < 0.75 { return edge.over(page) }
        return ChromeColor(edge.red, edge.green, edge.blue)
    }
}
