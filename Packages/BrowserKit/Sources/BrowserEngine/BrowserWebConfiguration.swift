import WebKit

/// Public WebKit settings shared by Mac and the future iPhone interface.
/// Apply before constructing the view, including views created for window.open.
@MainActor
enum BrowserWebConfiguration {
    static func apply(to configuration: WKWebViewConfiguration) {
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.preferences.isSiteSpecificQuirksModeEnabled = true
        // Throttle idle, detached tabs without suspending active media or networking.
        configuration.preferences.inactiveSchedulingPolicy = .throttle
        configuration.allowsAirPlayForMediaPlayback = true
        // Require a gesture for audio; video autoplay still follows WebKit's
        // visibility and platform rules (including videos with an audio track).
        configuration.mediaTypesRequiringUserActionForPlayback = .audio
        #if os(macOS)
        // WKWebView's Mac UA omits Version/Safari, so sites such as YouTube
        // misclassify modern WebKit as an unsupported browser. Append Safari's
        // compatibility tokens without replacing WebKit's platform identity.
        configuration.applicationNameForUserAgent = "Version/\(BrowserRuntime.safariCompatibilityVersion) Safari/605.1.15"
        #endif
        #if os(iOS)
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true
        #endif
        // Keep platform codecs, GPU and adaptive-streaming decisions.
    }
}
