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
            Text("Cookies, website data, and browsing history for this site will be removed from this profile. If Sync is on, the history deletion will reach your other devices.")
        }
    }
}

/// Shared policy controls; platform containers retain their native settings layout.
struct PrivacySettingsControls: View {
    @Environment(\.browserTheme) private var theme
    let session: BrowserSession
    @State private var acknowledgements = false
    var body: some View {
        SettingRow(detail: "Give new private tabs their own cookies and website data. Changes apply only to tabs you open next.") {
            Toggle("Isolate each private tab", isOn: Binding(
                get: { session.settings.privateTabIsolation.isEnabled },
                set: { session.settings.privateTabIsolation.isEnabled = $0 }
            ))
        }
        ForEach(PrivacyLayer.allCases.filter { $0 != .cookieBanners }) { layer in
            let unavailable = layer == .globalPrivacyControl && !BrowserPrivacy.supportsGPC
            let detail = if unavailable {
                OrivStrings.globalPrivacyControlUnavailable
            } else if layer == .linkCleaning {
                "Copy and Share clean links. Use Copy Original Link to keep every parameter. This switch controls navigation."
            } else {
                nil as String?
            }
            SettingRow(detail: detail) {
                Toggle(layer.title, isOn: Binding(get: { session.settings.privacy.isEnabled(layer) }, set: { session.settings.privacy.setEnabled($0, layer) }))
                    .disabled(unavailable)
            }
        }
        Toggle("Skip ads that still start", isOn: Binding(
            get: { session.settings.privacy.skipYouTubeAds },
            set: { session.settings.privacy.skipYouTubeAds = $0 }
        )).disabled(!session.settings.privacy.isEnabled(.youtubeAds) || session.adBlocker.mode == .off)
        SettingRow(detail: "Reject uses known opt-out controls and hides banners when no supported opt-out succeeds.") {
            Picker("Cookie banners", selection: Binding(
                get: { session.settings.privacy.cookieBannerMode },
                set: { session.settings.privacy.setCookieBannerMode($0) }
            )) {
                ForEach(CookieBannerMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
            }
        }
        Button("Acknowledgments") { acknowledgements = true }
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
    @Environment(\.browserTheme) private var theme
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
        if !BrowserPrivacy.supportsGPC { Text(OrivStrings.globalPrivacyControlUnavailable).font(.caption).foregroundStyle(theme.textSecondary) }
        if let url = tab.url, HTTPSUpgradePolicy.isExempt(url) { Text("Oriv allows HTTP for this local or network sign-in address.").font(.caption).foregroundStyle(theme.textSecondary) }
        if privacy.isEnabled(.cookieBanners, for: tab.url, isPrivate: tab.isPrivate) {
            LabeledContent("Cookie banners", value: tab.cookieBannerResult ?? privacy.cookieBannerMode.rawValue)
        }
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
        Text("Reload to apply changes fully. Existing form contents stay in place until you choose to reload.").font(.caption).foregroundStyle(theme.textSecondary)
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
        #if os(macOS)
        OrivSheet(title: "Privacy Acknowledgments", height: 600) {
            acknowledgmentText
        } actions: {
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        #else
        NavigationStack {
            acknowledgmentText.padding(OrivSpacing.large)
                .navigationTitle("Privacy Acknowledgments")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        #endif
    }

    private var acknowledgmentText: some View {
        ScrollView {
            Text(BundledPrivacyRules.acknowledgements).font(OrivType.body).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
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
