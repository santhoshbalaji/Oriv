import BrowserCore
import Foundation
import WebKit

@MainActor public protocol SessionWebUIDelegate: WKUIDelegate {
    func authenticate(_ challenge: URLAuthenticationChallenge,
                      completion: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void)
}

/// Resolves the existing platform storage and makes a browser session. UI
/// adapters remain owned by their controllers because WKWebView holds them weakly.
@MainActor public struct SessionFactory {
    public let session: BrowserSession
    public let defaults: UserDefaults?
    private let profileDirectory: URL?

    public static var isTesting: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil || environment["BROWSER_TESTING"] == "1"
    }

    public static var storageRoot: URL {
        #if os(macOS)
        URL.applicationSupportDirectory.appendingPathComponent("PersonalBrowser", isDirectory: true)
        #else
        URL.applicationSupportDirectory.appendingPathComponent("Oriv", isDirectory: true)
        #endif
    }

    public init(profile: BrowserProfile?, rootOverride: URL? = nil, testing: Bool,
                bundleID: String, websiteStore: WKWebsiteDataStore? = nil,
                privateTabIsolation: PrivateTabIsolation? = nil) {
        if !testing, let profile {
            defaults = profile.defaultsName(bundleID: bundleID).flatMap { UserDefaults(suiteName: $0) }
                ?? (profile.isPersonal ? .standard : nil)
        } else {
            defaults = nil
        }
        if !testing || rootOverride != nil {
            profileDirectory = profile?.directory(in: rootOverride ?? Self.storageRoot)
        } else {
            profileDirectory = nil
        }
        let dataStore: WKWebsiteDataStore
        if let websiteStore {
            dataStore = websiteStore
        } else if !testing, let profile {
            dataStore = profile.isPersonal ? .default() : WKWebsiteDataStore(forIdentifier: profile.id)
        } else {
            dataStore = .nonPersistent()
        }
        session = BrowserSession(
            store: profileDirectory.map { SessionFileStore(fileURL: $0.appendingPathComponent("session.json")) },
            dataStore: dataStore, adBlocker: AdBlocker(defaults: defaults),
            settings: BrowserSettings(defaults: defaults, privateTabIsolation:
                privateTabIsolation ?? PrivateTabIsolation(defaults: testing ? nil : .standard)), externalPrivate: profile == nil,
            faviconDirectory: profileDirectory?.appendingPathComponent("Favicons", isDirectory: true)
        )
    }

    /// Remove only the named profile's data. The legacy Personal paths also
    /// contain the registry and continuity journal, so they are protected.
    public static func removeProfileData(_ profile: BrowserProfile, rootOverride: URL? = nil,
                                         bundleID: String, testing: Bool) async throws {
        guard let suite = profile.defaultsName(bundleID: bundleID) else { throw ProfileError.protectedProfile }
        if !testing {
            if await WKWebsiteDataStore.allDataStoreIdentifiers.contains(profile.id) {
                try await WKWebsiteDataStore.remove(forIdentifier: profile.id)
            }
            #if os(iOS)
            try removeDirectory(downloadStagingDirectory(for: profile.id))
            #endif
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        if !testing || rootOverride != nil {
            try removeDirectory(profile.directory(in: rootOverride ?? storageRoot))
        }
    }

    private static func removeDirectory(_ url: URL) throws {
        do { try FileManager.default.removeItem(at: url) }
        catch let error as CocoaError where error.code == .fileNoSuchFile {}
    }

    #if os(iOS)
    public static func downloadStagingDirectory(for profileID: UUID?) -> URL {
        URL.temporaryDirectory.appendingPathComponent("OrivDownloads", isDirectory: true)
            .appendingPathComponent(profileID?.uuidString ?? "Private", isDirectory: true)
    }
    #endif

    public func importLegacyBookmarks() -> Task<Void, Never>? {
        guard let database = profileDirectory?.appendingPathComponent("workspace.sqlite") else { return nil }
        return Task { [weak session] in
            await session?.importLegacyBookmarks(from: database)
        }
    }

    public static func attach(_ adapter: any SessionWebUIDelegate, to view: WKWebView, tab: BrowserTab) {
        view.uiDelegate = adapter
        tab.onAuthentication = { [weak adapter] challenge, completion in
            guard let adapter else { completion(.cancelAuthenticationChallenge, nil); return }
            adapter.authenticate(challenge, completion: completion)
        }
    }
}
