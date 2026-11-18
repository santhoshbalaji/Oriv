import AppKit
import Observation
import SwiftUI

/// Window-local input modality. Focus ownership still belongs to SwiftUI/AppKit;
/// a click only hides its decoration, without breaking arrows or VoiceOver.
@MainActor @Observable final class ChromeFocusState {
    private(set) var keyboardNavigation: Bool? = nil
    var showsFocus: Bool {
        keyboardNavigation ?? (NSApp.isFullKeyboardAccessEnabled || NSWorkspace.shared.isVoiceOverEnabled)
    }

    func receive(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            keyboardNavigation = false
        case .keyDown:
            // Tab, arrows and explicit chrome shortcuts enable keyboard cues.
            if [48, 123, 124, 125, 126].contains(event.keyCode) ||
                event.modifierFlags.intersection([.command, .control]).isEmpty == false {
                keyboardNavigation = true
            }
        default: break
        }
    }
}

private struct ChromeFocusStateKey: EnvironmentKey {
    static let defaultValue: ChromeFocusState? = nil
}
extension EnvironmentValues {
    var chromeFocusState: ChromeFocusState? {
        get { self[ChromeFocusStateKey.self] }
        set { self[ChromeFocusStateKey.self] = newValue }
    }
}

/// Disable the platform's rectangular effect at the control, then draw exactly
/// one inset outline with the same shape as its hover/selection surface.
struct ChromeFocusIndicator: ViewModifier {
    var focused: Bool? = nil
    var radius: CGFloat = 9
    var color: Color? = nil
    var marker: String? = nil
    @Environment(\.isFocused) private var isFocused
    @Environment(\.chromeFocusState) private var input
    @Environment(\.browserTheme) private var theme

    func body(content: Content) -> some View {
        let visible = (focused ?? isFocused) && (input?.showsFocus ?? NSApp.isFullKeyboardAccessEnabled)
        content.focusEffectDisabled()
            .overlay {
                if visible {
                    RoundedRectangle(cornerRadius: radius).strokeBorder(color ?? theme.accent, lineWidth: 2)
                        .allowsHitTesting(false).accessibilityHidden(true)
                        .background { if let marker { BrowserGeometryMarker(name: marker) } }
                }
            }
    }
}
