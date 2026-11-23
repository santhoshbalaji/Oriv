import SwiftUI
import BrowserCore
import UIKit

/// A native editor provides URL selection and a clear button without changing the displayed host.
struct MobileAddressField: UIViewRepresentable {
    @Environment(\.browserTheme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Binding var text: String
    @Binding var editing: Bool
    let submit: () -> Void
    var completion: String? = nil
    var hasSelectedSuggestion = false
    var moveSelection: (Int) -> Void = { _ in }
    var cancel: () -> Void = {}
    // Match the capped SwiftUI address-bar environment using the native body style.
    private var contentSize: UIContentSizeCategory {
        switch typeSize {
        case .xSmall: .extraSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .xLarge: .extraLarge
        case .xxLarge: .extraExtraLarge
        case .xxxLarge: .extraExtraExtraLarge
        case .accessibility1: .accessibilityMedium
        case .accessibility2: .accessibilityLarge
        case .accessibility3: .accessibilityExtraLarge
        case .accessibility4: .accessibilityExtraExtraLarge
        default: .accessibilityExtraExtraExtraLarge
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextField {
        let field = MobilePrivacyAddressField()
        field.placeholder = OrivStrings.addressPlaceholder
        field.accessibilityLabel = "Address and search"
        field.accessibilityIdentifier = "browserAddress"
        field.keyboardType = .webSearch; field.returnKeyType = .go
        field.autocapitalizationType = .none; field.autocorrectionType = .no
        field.clearButtonMode = .whileEditing; field.adjustsFontForContentSizeCategory = false
        field.delegate = context.coordinator
        field.command = { [weak coordinator = context.coordinator] command in coordinator?.command(command) }
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        (field as? MobilePrivacyAddressField)?.hasInlineCompletion = false
        if field.text != text { field.text = text }
        if field.isFirstResponder, field.markedTextRange == nil, !context.coordinator.suppressCompletion,
           let completion, completion.hasPrefix(text), completion.count > text.count {
            (field as? MobilePrivacyAddressField)?.hasInlineCompletion = true
            field.text = completion
            if let start = field.position(from: field.beginningOfDocument, offset: text.utf16.count),
               let end = field.position(from: field.beginningOfDocument, offset: completion.utf16.count) {
                field.selectedTextRange = field.textRange(from: start, to: end)
            }
        }
        field.font = .preferredFont(forTextStyle: .body, compatibleWith: UITraitCollection(preferredContentSizeCategory: contentSize))
        field.textColor = UIColor(theme.text); field.tintColor = UIColor(theme.accent)
        field.attributedPlaceholder = NSAttributedString(string: OrivStrings.addressPlaceholder, attributes: [.foregroundColor: UIColor(theme.fieldText)])
        if editing && !field.isFirstResponder {
            DispatchQueue.main.async { [weak field, weak coordinator = context.coordinator] in
                guard coordinator?.parent.editing == true, let field else { return }
                field.becomeFirstResponder()
            }
        } else if !editing && field.isFirstResponder { field.resignFirstResponder() }
    }
    @MainActor final class Coordinator: NSObject, UITextFieldDelegate {
        var suppressCompletion = false
        var parent: MobileAddressField
        init(_ parent: MobileAddressField) { self.parent = parent }
        func textField(_ field: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            suppressCompletion = string.isEmpty
            return true
        }
        func textFieldShouldClear(_ field: UITextField) -> Bool { suppressCompletion = true; return true }
        func command(_ input: String) {
            switch input {
            case UIKeyCommand.inputUpArrow: parent.moveSelection(-1)
            case UIKeyCommand.inputDownArrow: parent.moveSelection(1)
            case UIKeyCommand.inputEscape: parent.cancel()
            default: break
            }
        }
        @objc func changed(_ field: UITextField) { parent.text = field.text ?? "" }
        func textFieldDidBeginEditing(_ field: UITextField) {
            DispatchQueue.main.async { [weak field] in field?.selectAll(nil) }
        }
        func textField(_ textField: UITextField, editMenuForCharactersIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard let text = textField.text, let url = URL(string: text), AddressResolver.isWebURL(url) else { return UIMenu(children: suggestedActions) }
            return UIMenu(children: suggestedActions + [UIAction(title: "Copy Original Link") { _ in PrivacyPasteboard.copy(url, original: true) }])
        }
        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            if !parent.hasSelectedSuggestion { parent.text = field.text ?? "" }; parent.submit(); return false
        }
    }
}

@MainActor final class MobilePrivacyAddressField: UITextField {
    var command: ((String) -> Void)?
    var hasInlineCompletion = false
    override var keyCommands: [UIKeyCommand]? {
        (super.keyCommands ?? []) + ([UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow, UIKeyCommand.inputEscape] + (hasInlineCompletion ? ["\t", UIKeyCommand.inputRightArrow] : [])).map {
            let command = UIKeyCommand(input: $0, modifierFlags: [], action: #selector(suggestionCommand(_:)))
            command.wantsPriorityOverSystemBehavior = true; return command
        }
    }
    @objc private func suggestionCommand(_ key: UIKeyCommand) {
        guard let input = key.input else { return }
        if input == "\t" || input == UIKeyCommand.inputRightArrow {
            if let selection = selectedTextRange, !selection.isEmpty, selection.end == endOfDocument {
                selectedTextRange = textRange(from: endOfDocument, to: endOfDocument)
                sendActions(for: .editingChanged)
            }
        } else { command?(input) }
    }
    override func copy(_ sender: Any?) {
        if let range = selectedTextRange, let text = text(in: range), let url = URL(string: text), AddressResolver.isWebURL(url) { PrivacyPasteboard.copy(url) }
        else { super.copy(sender) }
    }
}
