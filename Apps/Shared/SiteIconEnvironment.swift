import BrowserEngine
import SwiftUI

private struct SiteIconsKey: EnvironmentKey {
    static let defaultValue: SiteIconStore? = nil
}
extension EnvironmentValues {
    var siteIcons: SiteIconStore? {
        get { self[SiteIconsKey.self] }
        set { self[SiteIconsKey.self] = newValue }
    }
}
