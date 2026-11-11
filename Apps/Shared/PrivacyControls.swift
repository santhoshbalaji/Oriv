import BrowserCore
import BrowserEngine
import SwiftUI

/// Shared policy controls; platform containers retain their native settings layout.
struct PrivacySettingsControls: View {
    let session: BrowserSession
    @State private var acknowledgements = false
    var body: some View {
        ForEach(PrivacyLayer.allCases) { layer in
            Toggle(layer.title, isOn: Binding(get: { session.settings.privacy.isEnabled(layer) }, set: { session.settings.privacy.setEnabled($0, layer) }))
                .disabled(layer == .globalPrivacyControl && !BrowserPrivacy.supportsGPC)
            if layer == .globalPrivacyControl && !BrowserPrivacy.supportsGPC {
                Text("Unavailable on this OS. Requires macOS 27 or iOS 27.").font(.caption).foregroundStyle(.secondary)
            }
        }
        Text("Copy and Share clean links. Use Copy Original Link to keep every parameter. The link-cleaning switch controls navigation.").font(.caption).foregroundStyle(.secondary)
        Text("Hides cookie banners. Doesn't reject cookies.").font(.caption).foregroundStyle(.secondary)
        Text("Lists: \(AdBlocker.rulesVersion)").font(.caption).textSelection(.enabled)
        Button("Acknowledgements") { acknowledgements = true }
            .sheet(isPresented: $acknowledgements) { PrivacyAcknowledgements() }
        if !session.settings.privacy.regularExceptions.isEmpty {
            DisclosureGroup("Privacy site exceptions (\(session.settings.privacy.regularExceptions.count))") {
                ForEach(session.settings.privacy.regularExceptions.keys.sorted(), id: \.self) { host in
                    HStack {
                        Text(host).lineLimit(2)
                        Spacer()
                        Button("Reset") {
                            guard let url = URL(string: "https://" + host) else { return }
                            for layer in PrivacyLayer.allCases { session.settings.privacy.setException(false, layer, for: url, isPrivate: false) }
                        }.accessibilityLabel("Reset privacy exceptions for \(host)")
                    }
                }
            }
        }
    }
}

struct PrivacyShieldControls: View {
    let session: BrowserSession
    let tab: BrowserTab
    @State private var reloadPrompt = false
    private var privacy: BrowserPrivacy { session.settings.privacy }
    var body: some View {
        Text(tab.hostname).font(.headline).textSelection(.enabled)
        LabeledContent("Ad & tracker blocking", value: session.adBlocker.mode.rawValue)
        Toggle("Block ads and trackers on this site", isOn: Binding(
            get: { session.adBlocker.isEnabled(for: tab.url, isPrivate: tab.isPrivate) },
            set: { session.adBlocker.setException(!$0, for: tab.url, isPrivate: tab.isPrivate); reloadPrompt = true }
        )).disabled(session.adBlocker.mode == .off)
        ForEach(PrivacyLayer.allCases) { layer in
            Toggle(layer.title, isOn: Binding(
                get: { privacy.isEnabled(layer, for: tab.url, isPrivate: tab.isPrivate) && (layer != .globalPrivacyControl || BrowserPrivacy.supportsGPC) },
                set: { privacy.setException(!$0, layer, for: tab.url, isPrivate: tab.isPrivate); reloadPrompt = true }
            )).disabled(!privacy.isEnabled(layer) || layer == .globalPrivacyControl && !BrowserPrivacy.supportsGPC)
        }
        if !BrowserPrivacy.supportsGPC { Text("GPC unavailable on this OS (requires 27).").font(.caption).foregroundStyle(.secondary) }
        if let url = tab.url, HTTPSUpgradePolicy.isExempt(url) { Text("HTTPS upgrade is exempt for this local or connectivity-check address.").font(.caption).foregroundStyle(.secondary) }
        Text("Hides cookie banners. Doesn't reject cookies.").font(.caption).foregroundStyle(.secondary)
        Text("Lists: \(AdBlocker.rulesVersion)").font(.caption).textSelection(.enabled)
        if tab.isPrivate { Label("Exceptions last only for this private session.", systemImage: "eyeglasses").font(.caption) }
        Button("Site broken? Turn protections off for this site") {
            session.adBlocker.setException(true, for: tab.url, isPrivate: tab.isPrivate)
            for layer in PrivacyLayer.allCases { privacy.setException(true, layer, for: tab.url, isPrivate: tab.isPrivate) }
            reloadPrompt = true
        }
        Button("Reset Site Protections") {
            session.adBlocker.setException(false, for: tab.url, isPrivate: tab.isPrivate)
            for layer in PrivacyLayer.allCases { privacy.setException(false, layer, for: tab.url, isPrivate: tab.isPrivate) }
            reloadPrompt = true
        }
        Button("Reload Page") { tab.reload() }
        Text("Reload to apply changes fully. Existing form contents stay in place until you choose to reload.").font(.caption).foregroundStyle(.secondary)
        .alert("Reload this page?", isPresented: $reloadPrompt) {
            Button("Later", role: .cancel) {}
            Button("Reload") { tab.reload() }
        } message: { Text("Reload applies the changed protections and may discard unsaved form contents.") }
    }
}

struct PrivacyAcknowledgements: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Privacy Acknowledgements").font(.headline); Spacer(); Button("Done") { dismiss() } }
            ScrollView { Text(BundledPrivacyRules.acknowledgements).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
        }.padding(20).frame(minWidth: 280, idealWidth: 600, minHeight: 350, idealHeight: 600)
    }
}

struct HTTPFallbackView: View {
    let tab: BrowserTab
    var body: some View {
        ContentUnavailableView {
            Label("This site doesn't support a secure connection", systemImage: "lock.slash")
        } description: {
            Text(tab.httpWarningURL?.host ?? "")
            Text("Continuing uses unencrypted HTTP. Your choice is remembered for this exact host in this profile; private choices last only for this session.")
        } actions: {
            Button("Go Back") { tab.cancelHTTPFallback() }
            Button("Continue to HTTP") { tab.continueToHTTP() }
        }
    }
}
