import SwiftUI

/// Visual surface for site, pinned and choice tiles. Containers own interaction.
struct Tile: ViewModifier {
    enum Kind {
        case site
        case pinned(Color)
        case appearance(Color)
        case swatch(Color)
    }

    @Environment(\.browserTheme) private var theme
    let kind: Kind
    var selected = false

    func body(content: Content) -> some View {
        switch kind {
        case .site:
            content
                .frame(maxWidth: .infinity, minHeight: OrivLayout.tileMinimumHeight)
                .background(theme.surface, in: .rect(cornerRadius: OrivRadius.tile))
        case let .pinned(fill):
            content.background(fill, in: .rect(cornerRadius: OrivRadius.tile))
        case let .appearance(fill):
            content
                .background(fill, in: .rect(cornerRadius: OrivRadius.card))
                .modifier(ListSelection(kind: .card, selected: selected, radius: OrivRadius.card))
        case let .swatch(fill):
            content
                .background(fill, in: .rect(cornerRadius: OrivRadius.control))
                .modifier(ListSelection(kind: .card, selected: selected))
        }
    }
}
