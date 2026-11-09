import Foundation

/// Product identity comes from the build configuration, while the Swift module remains stable.
enum AppIdentity {
    static let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Oriv"
    static let channel = Bundle.main.object(forInfoDictionaryKey: "OrivBuildChannel") as? String ?? "Release"
    static var isDevelopment: Bool { channel == "Development" }
}
