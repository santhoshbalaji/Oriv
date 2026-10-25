import SwiftUI

/// WebKit's native field menu owns credential selection and insertion. This view
/// never requests, reads, copies or injects a password into the DOM.
struct PasswordsGuide: View {
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            EditorHeading(title: "Passwords, in the page", subtitle: "Use Apple’s secure AutoFill picker.", symbol: "key")
            instruction("1", title: "Choose a login field", detail: "Control-click or right-click the username or password field on the website.")
            instruction("2", title: "AutoFill → Passwords…", detail: "Choose Passwords from the field’s native AutoFill menu.")
            instruction("3", title: "Unlock and choose", detail: "Authenticate with macOS, then choose the matching website and account.")
            Divider()
            Text("Works through the native field menu in normal and private tabs. Oriv doesn’t provide Safari-style automatic suggestions or import your password vault.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !compact {
                Label("Set up on your Mac", systemImage: "gearshape").font(.headline)
                Text("In System Settings → General → AutoFill & Passwords, enable AutoFill and select Passwords. Turn on iCloud Passwords & Keychain if you want credentials available on your other Apple devices.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("The picker may require Touch ID or your Mac login password. No Apple developer account is needed for this field-menu flow.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Manage passwords…", systemImage: "arrow.up.forward.app") { ApplePasswords.open() }
                .buttonStyle(.glass).help("Open Apple Passwords to manage your vault")
        }.padding(compact ? 22 : 28).frame(width: compact ? 340 : nil, alignment: .leading)
    }
    private func instruction(_ number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number).font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                .frame(width: 24, height: 24).background(Theme.accent.opacity(0.09), in: .circle)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
