import AppKit
import SwiftUI

/// An AppKit field provides reliable menu-driven focus and selection inside NSToolbar.
struct AddressField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isEditing: Bool
    let focusRequest: Int
    let submit: () -> Bool
    let cancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = FocusAwareAddressField()
        field.isBezeled = false
        field.drawsBackground = false
        field.font = .systemFont(ofSize: 13)
        field.placeholderString = "Search or enter website"
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.usesSingleLineMode = true
        field.focusRingType = .none
        field.delegate = context.coordinator
        field.focusBegan = { [weak coordinator = context.coordinator] in coordinator?.parent.isEditing = true }
        field.setAccessibilityLabel("Address and search")
        field.setAccessibilityIdentifier("addressField")
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        guard focusRequest > 0, context.coordinator.lastFocusRequest != focusRequest else { return }
        context.coordinator.lastFocusRequest = focusRequest
        DispatchQueue.main.async {
            guard let window = field.window else { return }
            window.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AddressField
        var lastFocusRequest = 0
        init(_ parent: AddressField) { self.parent = parent }
        func controlTextDidBeginEditing(_ notification: Notification) { parent.isEditing = true }
        func controlTextDidEndEditing(_ notification: Notification) { parent.isEditing = false }
        func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool {
            parent.isEditing = false
            return true
        }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                parent.text = control.stringValue
                if parent.submit() {
                    parent.isEditing = false
                    control.window?.makeFirstResponder(nil)
                }
                return true
            }
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                parent.cancel()
                parent.isEditing = false
                control.stringValue = parent.text
                control.window?.makeFirstResponder(nil)
                return true
            }
            return false
        }
    }
}

private final class FocusAwareAddressField: NSTextField {
    var focusBegan: (() -> Void)?
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { DispatchQueue.main.async { [weak self] in self?.focusBegan?() } }
        return accepted
    }
}
