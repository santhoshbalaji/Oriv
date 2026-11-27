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

/// Captures clicks on the page scrim above WKWebView so clicking outside the
/// suggestions popover dismisses address editing cleanly without activating page links.
struct AddressScrimHitArea: NSViewRepresentable {
    let dismiss: () -> Void

    func makeNSView(context: Context) -> ScrimView { ScrimView() }
    func updateNSView(_ view: ScrimView, context: Context) { view.dismiss = dismiss }

    final class ScrimView: NSView {
        var dismiss: (() -> Void)?
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func accessibilityIsIgnored() -> Bool { true }
        override func mouseDown(with event: NSEvent) { dismiss?() }
    }
}

/// An AppKit field provides reliable menu-driven focus and selection inside NSToolbar.
struct AddressField: NSViewRepresentable {
    static let font = OrivMacV3.Address.focusedNSFont
    static let restFont = OrivMacV3.Address.restNSFont
    static let bigFieldFont = OrivMacV3.Address.bigFieldNSFont
    @Environment(\.browserTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.v3AppearanceMode) private var v3Mode
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.chromeContrastOverride) private var captureContrast
    @Binding var text: String
    @Binding var isEditing: Bool
    var placeholder = OrivStrings.addressPlaceholder
    var displayText: String? = nil
    var foreground: Color? = nil
    var isBigField = false
    var showsNativePlaceholder = true
    let focusRequest: Int
    var profileEpoch: UUID? = nil
    var focusStillValid: () -> Bool = { true }
    let submit: () -> Bool
    let cancel: () -> Void
    var completion: String? = nil
    var hasSelectedSuggestion = false
    var moveSelection: (Int) -> Void = { _ in }
    var onInlineCompletionChange: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = FocusAwareAddressField()
        field.cell = PrivacyAddressCell(textCell: "")
        field.isEditable = true
        field.isSelectable = true
        field.isBezeled = false
        field.drawsBackground = false
        // The capsule draws its own focus halo; AppKit's ring would box the text inside it.
        field.focusRingType = .none
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
            context.coordinator.reportInlineCompletion(false)
        }
        context.coordinator.parent = self
        field.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        field.textColor = foreground.map(NSColor.init) ?? (theme.isT3Code ? NSColor(theme.text) : .labelColor)
        field.placeholderString = showsNativePlaceholder ? placeholder : nil
        field.setAccessibilityPlaceholderValue(placeholder)
        (field as? FocusAwareAddressField)?.editingText = text
        let targetEditingFont = isBigField ? Self.bigFieldFont : Self.font
        (field as? FocusAwareAddressField)?.editingFont = targetEditingFont
        let editor = field.currentEditor() as? NSTextView
        let showingCompact = editor == nil && displayText != nil
        let targetFont = showingCompact ? Self.restFont : targetEditingFont
        if field.font != targetFont { field.font = targetFont }
        field.alignment = showingCompact ? .center : .natural
        let increasedContrast = (captureContrast ?? systemContrast) == .increased
        if let editor {
            if editor.font != targetEditingFont { editor.font = targetEditingFont }
            editor.insertionPointColor = field.textColor ?? .labelColor
            let privacyEditor = editor as? PrivacyAddressEditor
            privacyEditor?.isBigField = isBigField
            privacyEditor?.onInlineCompletionDismissed = { [weak coordinator = context.coordinator] in
                coordinator?.reportInlineCompletion(false)
            }
            // Chrome changes and suggestion refreshes can arrive while the
            // native editor has a selection or is composing marked text.
            if !editor.hasMarkedText() {
                let inline = completion.flatMap {
                    !context.coordinator.suppressCompletion && $0.hasPrefix(text) && $0.utf16.count > text.utf16.count ? $0 : nil
                }
                let value = inline ?? text
                let end = text.utf16.count
                let completionRange = inline.map { NSRange(location: end, length: $0.utf16.count - end) }
                if editor.string != value {
                    let previous = editor.selectedRange()
                    editor.string = value
                    if let completionRange {
                        editor.setSelectedRange(completionRange)
                    } else {
                        let location = min(previous.location, end)
                        editor.setSelectedRange(NSRange(location: location, length: min(previous.length, end - location)))
                    }
                }
                let activeCompletion = completionRange.flatMap { editor.selectedRange() == $0 ? $0 : nil }
                privacyEditor?.updateInlineCompletion(
                    range: activeCompletion,
                    mode: v3Mode,
                    increasedContrast: increasedContrast
                )
                context.coordinator.reportInlineCompletion(activeCompletion != nil)
            } else {
                privacyEditor?.updateInlineCompletion(range: nil, mode: v3Mode, increasedContrast: increasedContrast)
                context.coordinator.reportInlineCompletion(false)
            }
        } else {
            let value = displayText ?? text
            if field.stringValue != value { field.stringValue = value }
            context.coordinator.reportInlineCompletion(false)
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
        private var reportedInlineCompletion = false
        init(_ parent: AddressField) { self.parent = parent }

        func reportInlineCompletion(_ active: Bool) {
            guard reportedInlineCompletion != active else { return }
            reportedInlineCompletion = active
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.parent.onInlineCompletionChange(self.reportedInlineCompletion)
            }
        }

        func controlTextDidBeginEditing(_ notification: Notification) { parent.isEditing = true }
        func controlTextDidEndEditing(_ notification: Notification) {
            parent.isEditing = false
            suppressCompletion = false
            reportInlineCompletion(false)
            if let field = notification.object as? NSTextField {
                (field.currentEditor() as? PrivacyAddressEditor)?.clearInlineCompletion()
                field.stringValue = parent.displayText ?? parent.text
                let editingFont = parent.isBigField ? AddressField.bigFieldFont : AddressField.font
                field.font = parent.displayText == nil ? editingFont : AddressField.restFont
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
            if suppressCompletion {
                (field.currentEditor() as? PrivacyAddressEditor)?.clearInlineCompletion()
                reportInlineCompletion(false)
            }
            parent.text = field.currentEditor()?.string ?? field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.deleteBackward(_:)) || selector == #selector(NSResponder.deleteForward(_:)) {
                deleting = true; suppressCompletion = true
                (textView as? PrivacyAddressEditor)?.clearInlineCompletion()
                reportInlineCompletion(false)
                return false
            }
            if selector == #selector(NSResponder.insertTab(_:)) || selector == #selector(NSResponder.moveRight(_:)) {
                let range = textView.selectedRange()
                if range.length > 0, NSMaxRange(range) == textView.string.utf16.count,
                   range.location == parent.text.utf16.count, textView.string.hasPrefix(parent.text) {
                    parent.text = textView.string; suppressCompletion = true
                    (textView as? PrivacyAddressEditor)?.clearInlineCompletion()
                    reportInlineCompletion(false)
                    textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0)); return true
                }
            }
            if selector == #selector(NSResponder.moveDown(_:)) { parent.moveSelection(1); return true }
            if selector == #selector(NSResponder.moveUp(_:)) { parent.moveSelection(-1); return true }
            if selector == #selector(NSResponder.insertNewline(_:)) {
                if !parent.hasSelectedSuggestion { parent.text = textView.string }
                if parent.submit() {
                    parent.isEditing = false
                    reportInlineCompletion(false)
                    control.window?.makeFirstResponder(nil)
                }
                return true
            }
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                parent.cancel()
                parent.isEditing = false
                suppressCompletion = false
                (textView as? PrivacyAddressEditor)?.clearInlineCompletion()
                reportInlineCompletion(false)
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
    var editingFont: NSFont = AddressField.font
    var focusBegan: (() -> Void)?
    override func becomeFirstResponder() -> Bool {
        // Restore the complete address before AppKit creates its field editor.
        // Merely selecting the compact host would make a click edit the wrong URL.
        stringValue = editingText
        font = editingFont
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
    private(set) var inlineCompletionRange: NSRange?
    private var inlineCompletionMode: OrivMacV3.AppearanceMode = .light
    private var usesHighContrastSelection = false
    var isBigField = false
    var onInlineCompletionDismissed: (() -> Void)?

    func updateInlineCompletion(range: NSRange?, mode: OrivMacV3.AppearanceMode, increasedContrast: Bool) {
        let changed = inlineCompletionRange != range || inlineCompletionMode != mode || usesHighContrastSelection != increasedContrast
        inlineCompletionRange = range
        inlineCompletionMode = mode
        usesHighContrastSelection = increasedContrast
        if changed {
            applyInlineCompletionAppearance()
            needsDisplay = true
        }
    }

    func clearInlineCompletion() {
        guard inlineCompletionRange != nil else { return }
        inlineCompletionRange = nil
        applyInlineCompletionAppearance()
        needsDisplay = true
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting stillSelectingFlag: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelectingFlag)
        if let range = inlineCompletionRange, selectedRange() != range {
            inlineCompletionRange = nil
            applyInlineCompletionAppearance()
            needsDisplay = true
            onInlineCompletionDismissed?()
        }
    }

    private func applyInlineCompletionAppearance() {
        clearTemporaryCompletionAttributes()
        guard let range = inlineCompletionRange,
              range.length > 0,
              NSMaxRange(range) <= (string as NSString).length,
              !usesHighContrastSelection else {
            selectedTextAttributes = OrivMacV3.Address.defaultSelectionAttributes
            return
        }
        let fg = OrivMacV3.Address.inlineCompletionNSForeground(inlineCompletionMode)
        selectedTextAttributes = [
            .backgroundColor: OrivMacV3.Address.clearSelectionNSColor,
            .foregroundColor: fg,
        ]
        if let textLayoutManager, let tcm = textLayoutManager.textContentManager {
            let docStart = tcm.documentRange.location
            if let start = tcm.location(docStart, offsetBy: range.location),
               let end = tcm.location(start, offsetBy: range.length),
               let textRange = NSTextRange(location: start, end: end) {
                textLayoutManager.setRenderingAttributes([.foregroundColor: fg], for: textRange)
            }
        } else if let layoutManager {
            layoutManager.addTemporaryAttribute(.foregroundColor, value: fg, forCharacterRange: range)
        }
    }

    private func clearTemporaryCompletionAttributes() {
        if let textLayoutManager, let docRange = textLayoutManager.textContentManager?.documentRange {
            textLayoutManager.removeRenderingAttribute(.foregroundColor, for: docRange)
        } else if let layoutManager, let storage = textStorage, storage.length > 0 {
            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: storage.length))
        }
    }

    override func drawBackground(in rect: NSRect) {
        if !usesHighContrastSelection,
           !hasMarkedText(),
           let range = inlineCompletionRange,
           let window,
           range.length > 0,
           NSMaxRange(range) <= (string as NSString).length,
           selectedRange() == range {
            let screenRect = firstRect(forCharacterRange: range, actualRange: nil)
            if !screenRect.isEmpty {
                let windowRect = window.convertFromScreen(screenRect)
                var local = convert(windowRect, from: nil)
                let boundaryX = local.minX
                // Flush leading edge with typed text (zero gap); subtle trailing & vertical breathing room.
                local.size.width += OrivMacV3.Address.inlineCompletionTrailingPadding
                local = local.insetBy(dx: 0, dy: -OrivMacV3.Address.inlineCompletionVerticalPadding)
                local = local.intersection(bounds)
                if !local.isEmpty {
                    OrivMacV3.Address.inlineCompletionNSBackground(inlineCompletionMode).setFill()
                    let corner = OrivMacV3.Address.inlineCompletionCornerRadius
                    NSBezierPath(roundedRect: local, xRadius: corner, yRadius: corner).fill()

                    let caretWidth = OrivMacV3.Address.inlineCompletionCaretWidth
                    let targetCaretHeight = isBigField
                        ? OrivMacV3.Address.bigFieldInlineCompletionCaretHeight
                        : OrivMacV3.Address.inlineCompletionCaretHeight
                    let caretHeight = min(targetCaretHeight, local.height)
                    let caretRect = NSRect(
                        x: max(bounds.minX, boundaryX - caretWidth / 2),
                        y: local.midY - caretHeight / 2,
                        width: caretWidth,
                        height: caretHeight
                    )
                    OrivMacV3.Address.inlineCompletionNSCaret(inlineCompletionMode).setFill()
                    NSBezierPath(roundedRect: caretRect, xRadius: caretWidth / 2, yRadius: caretWidth / 2).fill()
                }
                return
            }
        }
        super.drawBackground(in: rect)
    }

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
