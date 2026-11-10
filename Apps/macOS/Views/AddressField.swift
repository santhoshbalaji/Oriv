import AppKit
import SwiftUI

/// An AppKit field provides reliable menu-driven focus and selection inside NSToolbar.
struct AddressField: NSViewRepresentable {
    @Environment(\.browserTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Binding var text: String
    @Binding var isEditing: Bool
    var placeholder = "Search or enter website"
    var displayText: String? = nil
    var foreground: Color? = nil
    let focusRequest: Int
    let submit: () -> Bool
    let cancel: () -> Void
    var moveSelection: (Int) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = FocusAwareAddressField()
        field.isBezeled = false
        field.drawsBackground = false
        field.font = .systemFont(ofSize: 13)
        field.placeholderString = placeholder
        field.lineBreakMode = .byTruncatingMiddle
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
        field.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        field.textColor = foreground.map(NSColor.init) ?? (theme.isT3Code ? NSColor(theme.text) : .labelColor)
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: foreground.map(NSColor.init) ?? (theme.isT3Code ? NSColor(theme.fieldText) : NSColor.placeholderTextColor)
        ])
        (field as? FocusAwareAddressField)?.editingText = text
        let editing = field.currentEditor() != nil
        let value = editing ? text : (displayText ?? text)
        if field.stringValue != value { field.stringValue = value }
        field.alignment = editing || displayText == nil ? .left : .center
        field.setAccessibilityValue(text)
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
        func controlTextDidEndEditing(_ notification: Notification) {
            parent.isEditing = false
            if let field = notification.object as? NSTextField {
                field.stringValue = parent.displayText ?? parent.text
                field.alignment = parent.displayText == nil ? .left : .center
            }
        }
        func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool {
            parent.isEditing = false
            return true
        }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.moveDown(_:)) { parent.moveSelection(1); return true }
            if selector == #selector(NSResponder.moveUp(_:)) { parent.moveSelection(-1); return true }
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

final class FocusAwareAddressField: NSTextField {
    var editingText = ""
    var focusBegan: (() -> Void)?
    override func becomeFirstResponder() -> Bool {
        // Restore the complete address before AppKit creates its field editor.
        // Merely selecting the compact host would make a click edit the wrong URL.
        stringValue = editingText
        alignment = .left
        let accepted = super.becomeFirstResponder()
        if accepted {
            DispatchQueue.main.async { [weak self] in
                // A toolbar update can finish editing before this callback runs.
                // Never restore the editing state after the responder has left.
                guard let self, let editor = self.currentEditor() else { return }
                self.focusBegan?()
                editor.selectAll(nil)
            }
        }
        return accepted
    }

    override func mouseDown(with event: NSEvent) {
        let wasEditing = currentEditor() != nil
        super.mouseDown(with: event)
        if !wasEditing { currentEditor()?.selectAll(nil) }
    }
}
