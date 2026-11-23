import SwiftUI

/// WebKit's native field menu owns credential selection and insertion. This view
/// never requests, reads, copies or injects a password into the DOM.
struct PasswordsGuide: View {
    @Environment(\.browserTheme) private var theme
    @FocusState private var managePasswordsFocused: Bool
    var compact = false
    var showsFillHint = false

    var body: some View {
        if compact {
            OrivPopover(title: "Passwords", symbol: "key", width: 340) {
                if showsFillHint {
                    Text("Use the key or ⌥⇧⌘P to choose an account from Apple Passwords.")
                        .font(OrivType.body).foregroundStyle(theme.text)
                } else {
                    Text("Right-click or Control-click the login field, then choose AutoFill → Passwords…")
                        .font(OrivType.bodyEmphasized)
                    steps
                    Divider()
                    Text(privateTabNote).font(OrivType.caption).foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    managePasswords.focusable().focused($managePasswordsFocused)
                }
            }
            .defaultFocus($managePasswordsFocused, !showsFillHint)
            .browserGeometryMarker("passwordsGuidePanelGeometry")
        } else {
            Form {
                Section {
                    steps
                } header: {
                    Text("Fill a saved password")
                } footer: {
                    Text(privateTabNote)
                }
                Section("Apple Passwords") {
                    SettingRow(detail: "Passwords stay with Apple Passwords. macOS fills the field. Oriv never sees, stores or sends your saved passwords.") {
                        managePasswords
                    }
                }
                Section {
                    Text("In System Settings → General → AutoFill & Passwords, enable AutoFill and select Passwords. Turn on iCloud Passwords & Keychain to use your credentials on your other Apple devices.")
                        .font(OrivType.body).foregroundStyle(theme.textSecondary)
                } header: {
                    Text("Set up on your Mac")
                } footer: {
                    Text("The picker may require Touch ID or your Mac login password.")
                }
            }.formStyle(.grouped)
        }
    }

    private let privateTabNote = "Private tabs can fill from Passwords. The website receives the credential you choose."

    private var steps: some View {
        VStack(alignment: .leading, spacing: OrivSpacing.medium) {
            instruction("1", title: "Choose a login field", detail: "Control-click or right-click the username or password field on the website.")
            instruction("2", title: "AutoFill → Passwords…", detail: "Choose Passwords from the field’s native AutoFill menu.")
            instruction("3", title: "Unlock and choose", detail: "Authenticate with macOS, then choose the matching website and account.")
        }
    }

    private var managePasswords: some View {
        Button("Manage Passwords…", systemImage: "arrow.up.forward.app") { ApplePasswords.open() }
            .orivButton(.secondary).help("Open Apple Passwords to manage your vault")
    }

    private func instruction(_ number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: OrivSpacing.medium) {
            Text(number).font(OrivType.caption.weight(.semibold)).foregroundStyle(theme.secondaryText)
                .frame(width: OrivSpacing.xl, height: OrivSpacing.xl).background(theme.field, in: .circle)
            VStack(alignment: .leading, spacing: OrivSpacing.xs) {
                Text(title).font(OrivType.body.weight(.medium))
                Text(detail).font(OrivType.caption).foregroundStyle(theme.secondaryText).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(number). \(title). \(detail)")
        .accessibilityAddTraits(.isStaticText)
    }
}
