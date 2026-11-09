import BrowserEngine
import SwiftUI

/// One reading of a tab's connection state, used by the address field and site information on both platforms.
enum ConnectionCue: Equatable {
    case recording, encrypted, mixedContent, notSecure, information

    @MainActor init(_ tab: BrowserTab, includeRecording: Bool = true) {
        self.init(scheme: tab.url?.scheme, secure: tab.isSecure, onlySecureContent: tab.hasOnlySecureContent,
                  loading: tab.isLoading, recording: includeRecording && (tab.isCapturingCamera || tab.isCapturingMicrophone))
    }

    init(scheme: String?, secure: Bool, onlySecureContent: Bool, loading: Bool, recording: Bool = false) {
        if recording { self = .recording }
        else if scheme == "http" { self = .notSecure }
        else if secure { self = .encrypted }
        else if scheme == "https" && !onlySecureContent && !loading { self = .mixedContent }
        else { self = .information }
    }

    var symbol: String {
        switch self {
        case .recording: "record.circle.fill"
        case .encrypted: "lock.fill"
        case .mixedContent: "exclamationmark.shield"
        case .notSecure: "exclamationmark.shield.fill"
        case .information: "info.circle"
        }
    }

    /// Spoken and visible description. Only `notSecure` is also shown as text in the address field.
    var label: String {
        switch self {
        case .recording: "Camera or microphone in use"
        case .encrypted: "Encrypted connection"
        case .mixedContent: "Some content isn't secure"
        case .notSecure: "Not secure"
        case .information: "Connection information"
        }
    }

    func color(_ theme: Theme) -> Color {
        switch self {
        case .recording: .red
        case .notSecure: theme.warning
        case .encrypted, .mixedContent, .information: theme.secondaryText
        }
    }
}
