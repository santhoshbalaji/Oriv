import Foundation
import WebKit

/// Runtime identity, deliberately separate from the app version and build SDK.
public struct BrowserRuntime: Sendable {
    public let appVersion: String
    public let appBuild: String
    public let operatingSystem: String
    public let webKitBuild: String

    /// Safari ships updates to the system WebKit on Mac independently of major
    /// OS upgrades. Use its installed version when accessible; otherwise report
    /// the conservative Safari baseline of our supported macOS 26+ platform.
    /// This is a site-compatibility token, not a claim that this app is Safari.
    public static var safariCompatibilityVersion: String {
        #if os(macOS)
        if let version = Bundle(path: "/Applications/Safari.app")?
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           version.range(of: #"^\d+(\.\d+){1,2}$"#, options: .regularExpression) != nil {
            return version
        }
        #endif
        return "\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion).0"
    }

    @MainActor public static var current: BrowserRuntime {
        let app = Bundle.main
        let webKit = Bundle(for: WKWebView.self)
        return BrowserRuntime(
            appVersion: app.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown",
            appBuild: app.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown",
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            webKitBuild: webKit.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "System WebKit"
        )
    }
}
