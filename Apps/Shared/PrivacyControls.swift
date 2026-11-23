import BrowserCore
import BrowserEngine
import SwiftUI

extension View {
    func forgetSiteAlert(_ selection: Binding<BrowserSite?>, session: BrowserSession, onError: @escaping (String) -> Void) -> some View {
        alert(selection.wrappedValue.map { "Forget \($0.domain)?" } ?? "Forget This Site?",
              isPresented: Binding(get: { selection.wrappedValue != nil }, set: { if !$0 { selection.wrappedValue = nil } }),
              presenting: selection.wrappedValue) { site in
            Button("Cancel", role: .cancel) {}
            Button("Forget This Site", role: .destructive) {
                Task {
                    do { try await session.forgetSite(site) }
                    catch { onError(error.localizedDescription) }
                }
            }
        } message: { _ in
            Text("Cookies, website data, and browsing history for this site will be removed from this profile. If you use Continuity, the history deletion will sync to your other devices.")
        }
    }
}

/// Shared policy controls; platform containers retain their native settings layout.
struct PrivacySettingsControls: View {
    let session: BrowserSession
    @State private var acknowledgements = false
    var body: some View {
        Toggle("Isolate each private tab", isOn: Binding(
            get: { session.settings.privateTabIsolation.isEnabled },
            set: { session.settings.privateTabIsolation.isEnabled = $0 }
        ))
        Text("Give new private tabs their own cookies and website data. Changes apply only to tabs you open next.")
            .font(.caption).foregroundStyle(.secondary)
        ForEach(PrivacyLayer.allCases.filter { $0 != .cookieBanners }) { layer in
            Toggle(layer.title, isOn: Binding(get: { session.settings.privacy.isEnabled(layer) }, set: { session.settings.privacy.setEnabled($0, layer) }))
                .disabled(layer == .globalPrivacyControl && !BrowserPrivacy.supportsGPC)
            if layer == .globalPrivacyControl && !BrowserPrivacy.supportsGPC {
                Text("Unavailable on this OS. Requires macOS 27 or iOS 27.").font(.caption).foregroundStyle(.secondary)
            }
        }
        Toggle("Skip ads that still start", isOn: Binding(
            get: { session.settings.privacy.skipYouTubeAds },
            set: { session.settings.privacy.skipYouTubeAds = $0 }
        )).disabled(!session.settings.privacy.isEnabled(.youtubeAds) || session.adBlocker.mode == .off)
        Text("Copy and Share clean links. Use Copy Original Link to keep every parameter. The link-cleaning switch controls navigation.").font(.caption).foregroundStyle(.secondary)
        Picker("Cookie banners", selection: Binding(
            get: { session.settings.privacy.cookieBannerMode },
            set: { session.settings.privacy.setCookieBannerMode($0) }
        )) {
            ForEach(CookieBannerMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
        }
        Text("Reject uses known opt-out controls and hides banners when no supported opt-out succeeds.")
            .font(.caption).foregroundStyle(.secondary)
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
        selectableLabel(tab.hostname, font: .headline)
        LabeledContent("Ad & tracker blocking", value: session.adBlocker.mode.rawValue)
        Toggle("Block ads and trackers on this site", isOn: Binding(
            get: { session.adBlocker.isEnabled(for: tab.url, isPrivate: tab.isPrivate) },
            set: { session.adBlocker.setException(!$0, for: tab.url, isPrivate: tab.isPrivate); reloadPrompt = true }
        )).disabled(session.adBlocker.mode == .off).shieldKeyboardFocus()
        ForEach(PrivacyLayer.allCases.filter { $0 != .youtubeAds || YouTubeProtection.supports(tab.url) }) { layer in
            Toggle(layer.title, isOn: Binding(
                get: { privacy.isEnabled(layer, for: tab.url, isPrivate: tab.isPrivate) && (layer != .globalPrivacyControl || BrowserPrivacy.supportsGPC) && (layer != .youtubeAds || session.adBlocker.isEnabled(for: tab.url, isPrivate: tab.isPrivate)) },
                set: { privacy.setException(!$0, layer, for: tab.url, isPrivate: tab.isPrivate); reloadPrompt = true }
            )).disabled(!privacy.isEnabled(layer) || layer == .globalPrivacyControl && !BrowserPrivacy.supportsGPC
                        || layer == .youtubeAds && !session.adBlocker.isEnabled(for: tab.url, isPrivate: tab.isPrivate))
                .shieldKeyboardFocus()
        }
        if !BrowserPrivacy.supportsGPC { Text("GPC unavailable on this OS (requires 27).").font(.caption).foregroundStyle(.secondary) }
        if let url = tab.url, HTTPSUpgradePolicy.isExempt(url) { Text("HTTPS upgrade is exempt for this local or connectivity-check address.").font(.caption).foregroundStyle(.secondary) }
        if privacy.isEnabled(.cookieBanners, for: tab.url, isPrivate: tab.isPrivate) {
            LabeledContent("Cookie banners", value: tab.cookieBannerResult ?? privacy.cookieBannerMode.rawValue)
        }
        selectableLabel("Lists: \(AdBlocker.rulesVersion)", font: .caption)
        if tab.isPrivate { Label("Exceptions last only for this private session.", systemImage: "eyeglasses").font(.caption) }
        Button("Site broken? Turn protections off for this site") {
            session.adBlocker.setException(true, for: tab.url, isPrivate: tab.isPrivate)
            for layer in PrivacyLayer.allCases { privacy.setException(true, layer, for: tab.url, isPrivate: tab.isPrivate) }
            reloadPrompt = true
        }.shieldKeyboardFocus()
        Button("Reset Site Protections") {
            session.adBlocker.setException(false, for: tab.url, isPrivate: tab.isPrivate)
            for layer in PrivacyLayer.allCases { privacy.setException(false, layer, for: tab.url, isPrivate: tab.isPrivate) }
            reloadPrompt = true
        }.shieldKeyboardFocus()
        Button("Reload Page") { tab.reload() }.shieldKeyboardFocus()
        Text("Reload to apply changes fully. Existing form contents stay in place until you choose to reload.").font(.caption).foregroundStyle(.secondary)
        .alert("Reload this page?", isPresented: $reloadPrompt) {
            Button("Later", role: .cancel) {}
            Button("Reload") { tab.reload() }
        } message: { Text("Reload applies the changed protections and may discard unsaved form contents.") }
    }

    private func selectableLabel(_ label: String, font: Font) -> some View {
        Text(label).font(font).textSelection(.enabled)
            #if os(macOS)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isStaticText)
            #endif
    }
}

private extension View {
    @ViewBuilder func shieldKeyboardFocus() -> some View {
        #if os(macOS)
        focusable()
        #else
        self
        #endif
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
        Color.clear
            .alert("This site doesn't support a secure connection",
                   isPresented:Binding(get:{ tab.httpWarningURL != nil },set:{ _ in }),
                   presenting:tab.httpWarningURL) { destination in
                Button("Go Back",role:.cancel) { tab.cancelHTTPFallback() }
                Button("Continue to HTTP") { tab.continueToHTTP(destination) }
            } message: { destination in
                Text("\(destination.host ?? "")\n\nContinuing uses unencrypted HTTP. Your choice is remembered for this exact host in this profile; private choices last only for this session.")
            }
    }
}
