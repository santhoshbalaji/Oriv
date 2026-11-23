import SwiftUI

/// A DEBUG-only presentation substitute keeps the production label and style
/// available to off-screen hit-testing without starting an AppKit menu session.
struct MacPageMenu<Content: View, Label: View>: View {
    var active = false
    @ViewBuilder let content: () -> Content
    @ViewBuilder let label: () -> Label
    #if DEBUG
    @Environment(\.pageMenuPresentationProbe) private var presentationProbe
    #endif

    var body: some View {
        Group {
            #if DEBUG
            if let presentationProbe {
                Button(action: presentationProbe, label: label)
            } else {
                Menu(content: content, label: label).menuStyle(.button).menuIndicator(.hidden)
            }
            #else
            Menu(content: content, label: label).menuStyle(.button).menuIndicator(.hidden)
            #endif
        }
        .menuOrder(.fixed)
        .buttonStyle(ToolbarButtonStyle(active: active))
    }
}

#if DEBUG
private struct PageMenuPresentationProbeKey: EnvironmentKey {
    static let defaultValue: (@MainActor () -> Void)? = nil
}
extension EnvironmentValues {
    var pageMenuPresentationProbe: (@MainActor () -> Void)? {
        get { self[PageMenuPresentationProbeKey.self] }
        set { self[PageMenuPresentationProbeKey.self] = newValue }
    }
}
#endif
