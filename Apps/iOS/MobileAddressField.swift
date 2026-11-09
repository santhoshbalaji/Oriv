import SwiftUI
import UIKit

/// A native editor provides URL selection and a clear button without changing the displayed host.
struct MobileAddressField: UIViewRepresentable {
    @Environment(\.browserTheme) private var theme
    @Binding var text: String
    @Binding var editing: Bool
    let fontSize: CGFloat
    let submit: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.placeholder = "Search or enter address"
        field.accessibilityLabel = "Address and search"
        field.accessibilityIdentifier = "browserAddress"
        field.keyboardType = .webSearch; field.returnKeyType = .go
        field.autocapitalizationType = .none; field.autocorrectionType = .no
        field.clearButtonMode = .whileEditing; field.adjustsFontForContentSizeCategory = false
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        if field.text != text { field.text = text }
        field.font = .systemFont(ofSize: fontSize)
        field.textColor = UIColor(theme.text); field.tintColor = UIColor(theme.accent)
        field.attributedPlaceholder = NSAttributedString(string: "Search or enter address", attributes: [.foregroundColor: UIColor(theme.fieldText)])
        if editing && !field.isFirstResponder {
            DispatchQueue.main.async { [weak field, weak coordinator = context.coordinator] in
                guard coordinator?.parent.editing == true, let field else { return }
                field.becomeFirstResponder()
            }
        } else if !editing && field.isFirstResponder { field.resignFirstResponder() }
    }
    @MainActor final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: MobileAddressField
        init(_ parent: MobileAddressField) { self.parent = parent }
        @objc func changed(_ field: UITextField) { parent.text = field.text ?? "" }
        func textFieldDidBeginEditing(_ field: UITextField) {
            DispatchQueue.main.async { [weak field] in field?.selectAll(nil) }
        }
        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            parent.text = field.text ?? ""; parent.submit(); return false
        }
    }
}
