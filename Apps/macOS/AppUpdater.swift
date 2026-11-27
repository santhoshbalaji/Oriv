import BrowserEngine
import Observation
import Sparkle
import SwiftUI

/// Sparkle updates for the Developer ID public beta. Builds without a feed URL
/// (development, tests, ad-hoc packages) never create an updater or contact oriv.dev.
@MainActor @Observable final class AppUpdater {
    static let shared = AppUpdater()

    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    private(set) var canCheckForUpdates = false
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private var automaticObservation: NSKeyValueObservation?

    var isAvailable: Bool { controller != nil }

    private init() {
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        guard !feed.isEmpty, !key.isEmpty, !SessionFactory.isTesting else {
            controller = nil
            return
        }
        // Sparkle asks the user before its first automatic check; nothing is sent until then.
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        automaticObservation = controller.updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] updater, _ in
            let value = updater.automaticallyChecksForUpdates
            Task { @MainActor in if self?.automaticallyChecks != value { self?.automaticallyChecks = value } }
        }
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheckForUpdates = value }
        }
    }

    func checkForUpdates() { controller?.checkForUpdates(nil) }

    /// Mirrors Sparkle's own preference, which starts unset: Sparkle asks before the first check.
    var automaticallyChecks = false {
        didSet {
            guard let updater = controller?.updater, updater.automaticallyChecksForUpdates != automaticallyChecks else { return }
            updater.automaticallyChecksForUpdates = automaticallyChecks
        }
    }
}

/// "Check for Updates…" in the Oriv menu, present only in builds that can update.
struct CheckForUpdatesCommand: Commands {
    @State private var updater = AppUpdater.shared

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            if updater.isAvailable {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
        }
    }
}
