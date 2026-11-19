import AppKit
import Observation
import SwiftUI

/// Window-local input modality. Focus ownership still belongs to SwiftUI/AppKit;
/// a click only hides its decoration, without breaking arrows or VoiceOver.
@MainActor @Observable final class ChromeFocusState {
    private(set) var keyboardNavigation: Bool? = nil
    private let fullKeyboardAccessEnabled: () -> Bool

    init(fullKeyboardAccessEnabled: @escaping () -> Bool = { NSApp.isFullKeyboardAccessEnabled }) {
        self.fullKeyboardAccessEnabled = fullKeyboardAccessEnabled
    }

    var showsFocus: Bool {
        keyboardNavigation ?? (fullKeyboardAccessEnabled() || NSWorkspace.shared.isVoiceOverEnabled)
    }

    func receive(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            keyboardNavigation = false
        case .keyDown:
            if fullKeyboardAccessEnabled() {
                // Respect the system's broader keyboard-focus policy.
                keyboardNavigation = true
            } else if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                // Shortcuts can transfer focus, but must not decorate a mouse
                // target or their destination before actual navigation.
                keyboardNavigation = false
            } else if [48, 123, 124, 125, 126].contains(event.keyCode) {
                // Shift-Tab and bare arrows navigate. AppKit also marks arrows
                // with .function, so do not reject that flag. Ordinary typing,
                // function keys and Space/Return never enter navigation mode;
                // activation preserves an already-established navigation cue.
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
    var marker = "chromeFocusIndicator"
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
                        .browserGeometryMarker(marker)
                }
            }
    }
}
