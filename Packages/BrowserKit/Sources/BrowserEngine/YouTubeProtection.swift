import Foundation
import WebKit

@MainActor public enum YouTubeProtection {
    static let hosts: Set<String> = [
        "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com",
        "youtube-nocookie.com", "www.youtube-nocookie.com"
    ]
    private static let prefix = "// Oriv YouTube policy\n"
    private static let runtime = Bundle.module.url(forResource: "youtube-v1", withExtension: "js", subdirectory: "Privacy")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    public static func supports(_ url: URL?) -> Bool {
        AdBlocker.host(for: url).map(hosts.contains) ?? false
    }

    static func source(disabledHosts: Set<String>, skipAds: Bool) -> String? {
        guard let runtime, let data = try? JSONEncoder().encode(disabledHosts.sorted()) else { return nil }
        return prefix + """
        (() => {
        const disabledHosts = \(String(decoding: data, as: UTF8.self));
        const skipAds = \(skipAds);
        \(runtime)
        })();
        """
    }

    @MainActor static func update(_ controller: WKUserContentController, source: String?) {
        let scripts = controller.userScripts
        let existing = scripts.filter { $0.source.hasPrefix(prefix) }
        if existing.count == 1 && existing.first?.source == source { return }
        if !existing.isEmpty {
            controller.removeAllUserScripts()
            scripts.filter { !$0.source.hasPrefix(prefix) }.forEach(controller.addUserScript)
        }
        if let source {
            controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        }
    }
}
