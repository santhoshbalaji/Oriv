import SwiftUI

/// The system-accent marker identifies the active row at its leading edge.
struct SelectionMarker: View {
    @Environment(\.browserTheme) private var theme
    @Environment(\.self) private var environment
    var height: CGFloat = 16
    var background: Color? = nil

    var body: some View {
        let surface = (background ?? theme.fillSelected).resolve(in: environment)
        Capsule().fill(theme.markerAccent(on: surface, in: environment))
            .frame(width: 3, height: height).accessibilityHidden(true)
    }
}

/// Shared list and card treatment. Native containers own focus and selection behavior.
struct ListSelection: ViewModifier {
    enum Kind { case row, card }

    @Environment(\.browserTheme) private var theme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.chromeContrastOverride) private var captureContrast
    var kind: Kind = .row
    var selected: Bool
    var radius = OrivRadius.control
    var fill: Color? = nil
    var drawsMarker = true

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius)
        let increased = (captureContrast ?? contrast) == .increased
        content
            .background {
                if kind == .row && selected {
                    shape.fill(fill ?? theme.fillSelected)
                        .overlay(alignment: .leading) {
                            if drawsMarker { SelectionMarker(background: fill).padding(.leading, OrivSpacing.xxs) }
                        }
                }
            }
            .overlay {
                if selected && increased {
                    shape.strokeBorder(theme.separatorStrong, lineWidth: 2)
                } else if kind == .card {
                    shape.strokeBorder(selected ? theme.accent : theme.respecting(captureContrast ?? contrast).separator,
                                       lineWidth: selected ? 2 : 1)
                }
            }
    }
}
