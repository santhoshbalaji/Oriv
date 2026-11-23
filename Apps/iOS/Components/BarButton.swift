import SwiftUI

struct BarButton<Control: View>: View {
    var width = OrivTarget.touchBar.width
    @ViewBuilder let control: () -> Control

    var body: some View {
        control()
            .frame(width: width, height: OrivTarget.touchBar.height)
            .tint(.primary)
            .buttonStyle(.plain)
            .modifier(OrivMaterial.control())
    }
}

struct BarButtonIcon: View {
    @ScaledMetric(relativeTo: .body) private var primarySize = OrivIcon.bar
    @ScaledMetric(relativeTo: .body) private var secondarySize = OrivIcon.secondaryBar
    let symbol: String
    var secondary = false
    var width = OrivTarget.touchBar.width

    var body: some View {
        Image(systemName: symbol)
            .font(OrivIcon.barFont(scaledSize: secondary ? secondarySize : primarySize))
            .frame(width: width, height: OrivTarget.touchBar.height)
            .contentShape(Rectangle())
            .accessibilityHidden(true)
    }
}
