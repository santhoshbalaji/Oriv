import BrowserCore
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor enum PrivacyPasteboard {
    static func copy(_ url: URL, original: Bool = false) {
        let value = original ? url : URLCleaner.clean(url)
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([value as NSURL])
        NSPasteboard.general.setString(value.absoluteString, forType: .string)
        #else
        UIPasteboard.general.url = value
        #endif
    }
}
