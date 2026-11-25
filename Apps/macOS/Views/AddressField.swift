import AppKit
import BrowserCore
import SwiftUI

/// The capsule's background receives clicks that miss its field and controls.
struct AddressCapsuleHitArea: NSViewRepresentable {
    let focus: () -> Void

    func makeNSView(context: Context) -> HitView { HitView() }
    func updateNSView(_ view: HitView, context: Context) { view.focus = focus }

    final class HitView: NSView {
        var focus: (() -> Void)?
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func accessibilityIsIgnored() -> Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = convert(point, from: superview)
            let radius = bounds.height / 2
            return NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).contains(local)
                ? super.hitTest(point) : nil
        }
        override func mouseDown(with event: NSEvent) { focus?() }
    }
}

/// An AppKit field provides reliable menu-driven focus and selection inside NSToolbar.
struct AddressField: NSViewRepresentable {
    static let font = NSFont.systemFont(ofSize: OrivLayout.macAddressFontSize)
    static let restFont = NSFont.systemFont(ofSize: OrivLayout.macAddressFontSize, weight: .medium)
    @Environment(\.browserTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Binding var text: String
    @Binding var isEditing: Bool
    var placeholder = OrivStrings.addressPlaceholder
    var displayText: String? = nil
    var foreground: Color? = nil
    var showsNativePlaceholder = true
    let focusRequest: Int
    var profileEpoch: UUID? = nil
    var focusStillValid: () -> Bool = { true }
    let submit: () -> Bool
    let cancel: () -> Void
    var completion: String? = nil
    var hasSelectedSuggestion = false
    var moveSelection: (Int) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = FocusAwareAddressField()
        field.cell = PrivacyAddressCell(textCell: "")
        field.isEditable = true
        field.isSelectable = true
        field.isBezeled = false
        field.drawsBackground = false
        field.font = Self.font
        field.placeholderString = showsNativePlaceholder ? placeholder : nil
        field.lineBreakMode = .byTruncatingMiddle
        field.maximumNumberOfLines = 1
        field.usesSingleLineMode = true
        field.delegate = context.coordinator
        field.focusBegan = { [weak coordinator = context.coordinator] in coordinator?.parent.isEditing = true }
        field.setAccessibilityLabel("Address and search")
        field.setAccessibilityIdentifier("addressField")
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if context.coordinator.parent.profileEpoch != profileEpoch {
            context.coordinator.lastFocusRequest = 0
            context.coordinator.suppressCompletion = false
        }
        context.coordinator.parent = self
        field.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        field.textColor = foreground.map(NSColor.init) ?? (theme.isT3Code ? NSColor(theme.text) : .labelColor)
        field.placeholderString = showsNativePlaceholder ? placeholder : nil
        field.setAccessibilityPlaceholderValue(placeholder)
        (field as? FocusAwareAddressField)?.editingText = text
        let editor = field.currentEditor() as? NSTextView
        let showingCompact = editor == nil && displayText != nil
        let targetFont = showingCompact ? Self.restFont : Self.font
        if field.font != targetFont { field.font = targetFont }
        field.alignment = showingCompact ? .center : .natural
        if let editor {
            editor.insertionPointColor = field.textColor ?? .labelColor
            // Chrome changes and suggestion refreshes can arrive while the
            // native editor has a selection or is composing marked text.
            if !editor.hasMarkedText() {
                let inline = completion.flatMap {
                    !context.coordinator.suppressCompletion && $0.hasPrefix(text) && $0.utf16.count > text.utf16.count ? $0 : nil
                }
                let value = inline ?? text
                if editor.string != value {
                    let previous = editor.selectedRange()
                    editor.string = value
                    let end = text.utf16.count
                    if let inline {
                        editor.setSelectedRange(NSRange(location: end, length: inline.utf16.count - end))
                    } else {
                        let location = min(previous.location, end)
                        editor.setSelectedRange(NSRange(location: location, length: min(previous.length, end - location)))
                    }
                }
            }
        } else {
            let value = displayText ?? text
            if field.stringValue != value { field.stringValue = value }
        }
        field.setAccessibilityValue(text)
        guard focusRequest > 0, context.coordinator.lastFocusRequest != focusRequest else { return }
        context.coordinator.lastFocusRequest = focusRequest
        DispatchQueue.main.async { [weak coordinator = context.coordinator] in
            guard let window = field.window, let coordinator,
                  coordinator.parent.profileEpoch == profileEpoch,
                  coordinator.parent.focusRequest == focusRequest, focusStillValid() else { return }
            window.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AddressField
        var lastFocusRequest = 0
        var suppressCompletion = false
        private var deleting = false
        init(_ parent: AddressField) { self.parent = parent }
        func controlTextDidBeginEditing(_ notification: Notification) { parent.isEditing = true }
        func controlTextDidEndEditing(_ notification: Notification) {
            parent.isEditing = false
            if let field = notification.object as? NSTextField {
                field.stringValue = parent.displayText ?? parent.text
                field.font = parent.displayText == nil ? AddressField.font : AddressField.restFont
                field.alignment = parent.displayText == nil ? .natural : .center
            }
        }
        func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool {
            parent.isEditing = false
            return true
        }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            suppressCompletion = deleting
            deleting = false
            parent.text = field.currentEditor()?.string ?? field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.deleteBackward(_:)) || selector == #selector(NSResponder.deleteForward(_:)) {
                deleting = true; suppressCompletion = true
                return false
            }
            if selector == #selector(NSResponder.insertTab(_:)) || selector == #selector(NSResponder.moveRight(_:)) {
                let range = textView.selectedRange()
                if range.length > 0, NSMaxRange(range) == textView.string.utf16.count,
                   range.location == parent.text.utf16.count, textView.string.hasPrefix(parent.text) {
                    parent.text = textView.string; suppressCompletion = true
                    textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0)); return true
                }
            }
            if selector == #selector(NSResponder.moveDown(_:)) { parent.moveSelection(1); return true }
            if selector == #selector(NSResponder.moveUp(_:)) { parent.moveSelection(-1); return true }
            if selector == #selector(NSResponder.insertNewline(_:)) {
                if !parent.hasSelectedSuggestion { parent.text = textView.string }
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
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        if URL(string: editingText).map(AddressResolver.isWebURL) == true {
            menu.addItem(.separator())
            for (title, selector) in [("Copy Link", #selector(copyCleanLink)), ("Copy Original Link", #selector(copyOriginalLink))] {
                let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self; menu.addItem(item)
            }
        }
        return menu
    }
    @objc private func copyCleanLink() { if let url = URL(string: editingText) { PrivacyPasteboard.copy(url) } }
    @objc private func copyOriginalLink() { if let url = URL(string: editingText) { PrivacyPasteboard.copy(url, original: true) } }

    var editingText = ""
    var focusBegan: (() -> Void)?
    override func becomeFirstResponder() -> Bool {
        // Restore the complete address before AppKit creates its field editor.
        // Merely selecting the compact host would make a click edit the wrong URL.
        stringValue = editingText
        font = AddressField.font
        alignment = .natural
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

@MainActor final class PrivacyAddressEditor: NSTextView {
    override func copy(_ sender: Any?) {
        let selected = (string as NSString).substring(with: selectedRange())
        if let url = URL(string: selected), AddressResolver.isWebURL(url) { PrivacyPasteboard.copy(url) }
        else { super.copy(sender) }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        if URL(string: string).map(AddressResolver.isWebURL) == true {
            let item = NSMenuItem(title: "Copy Original Link", action: #selector(copyOriginalLink), keyEquivalent: "")
            item.target = self; menu?.addItem(item)
        }
        return menu
    }
    @objc private func copyOriginalLink() { if let url = URL(string: string) { PrivacyPasteboard.copy(url, original: true) } }
}

@MainActor final class PrivacyAddressCell: NSTextFieldCell {
    private let editor = PrivacyAddressEditor()
    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        editor.isFieldEditor = true
        return editor
    }
}
