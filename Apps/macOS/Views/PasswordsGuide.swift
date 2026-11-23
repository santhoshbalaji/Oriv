import SwiftUI

/// WebKit's native field menu owns credential selection and insertion. This view
/// never requests, reads, copies or injects a password into the DOM.
struct PasswordsGuide: View {
    @Environment(\.browserTheme) private var theme
    @FocusState private var managePasswordsFocused: Bool
    var compact = false
    var showsFillHint = false

    var body: some View {
        if showsFillHint {
            Text("Use the key or ⌥⇧⌘P to choose an account from Apple Passwords.")
                .font(.callout).foregroundStyle(theme.text).padding(16)
        } else {
            guide
        }
    }

    private var guide: some View {
        VStack(alignment: .leading, spacing: 18) {
            EditorHeading(title: "Passwords, in the page", subtitle: "Use Apple’s secure AutoFill picker.", symbol: "key")
            instruction("1", title: "Choose a login field", detail: "Control-click or right-click the username or password field on the website.")
            instruction("2", title: "AutoFill → Passwords…", detail: "Choose Passwords from the field’s native AutoFill menu.")
            instruction("3", title: "Unlock and choose", detail: "Authenticate with macOS, then choose the matching website and account.")
            Divider()
            Text("Private tabs can fill from Passwords. The website receives the credential you choose.")
                .font(.caption).foregroundStyle(theme.secondaryText).fixedSize(horizontal: false, vertical: true)
            if !compact {
                Text("Passwords stay with Apple Passwords. macOS fills the field. Oriv never sees, stores or sends your saved passwords.")
                    .font(.callout).foregroundStyle(theme.secondaryText)
                Text("With public macOS APIs, Oriv cannot automatically suggest logins when a field gains focus, save or update passwords, or suggest strong passwords.")
                    .font(.callout).foregroundStyle(theme.secondaryText)
                Label("Set up on your Mac", systemImage: "gearshape").font(.headline)
                Text("In System Settings → General → AutoFill & Passwords, enable AutoFill and select Passwords. Turn on iCloud Passwords & Keychain if you want credentials available on your other Apple devices.")
                    .font(.callout).foregroundStyle(theme.secondaryText)
                Text("The picker may require Touch ID or your Mac login password. No Apple developer account is needed for this field-menu flow.")
                    .font(.caption).foregroundStyle(theme.secondaryText)
            }
            if compact {
                managePasswords.focusable().focused($managePasswordsFocused)
            } else {
                managePasswords
            }
        }.padding(compact ? 22 : 28).frame(width: compact ? 340 : nil, alignment: .leading)
            .defaultFocus($managePasswordsFocused, compact)
            .browserGeometryMarker("passwordsGuidePanelGeometry", when: compact)
    }

    private var managePasswords: some View {
        Button("Manage Passwords…", systemImage: "arrow.up.forward.app") { ApplePasswords.open() }
            .buttonStyle(.bordered).help("Open Apple Passwords to manage your vault")
    }

    private func instruction(_ number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number).font(.caption.weight(.semibold)).foregroundStyle(theme.secondaryText)
                .frame(width: 24, height: 24).background(theme.field, in: .circle)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(theme.secondaryText).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(number). \(title). \(detail)")
        .accessibilityAddTraits(.isStaticText)
    }
}
