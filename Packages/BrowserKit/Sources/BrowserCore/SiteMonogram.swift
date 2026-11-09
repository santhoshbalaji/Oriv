import Foundation

/// A display hint for local site monograms, never a security or domain-ownership boundary.
/// This intentionally small suffix list is not a public suffix implementation.
public enum SiteMonogram {
    private static let secondLevelSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "net.uk", "me.uk",
        "com.au", "net.au", "org.au", "edu.au", "gov.au",
        "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp",
        "co.in", "com.in", "net.in", "org.in", "ac.in", "edu.in", "gov.in",
        "com.br", "net.br", "org.br", "gov.br",
        "co.nz", "net.nz", "org.nz", "ac.nz", "govt.nz",
        "co.za", "com.sg", "com.cn", "com.hk", "com.mx", "com.tw", "co.kr"
    ]

    public static func label(for host: String?) -> String? {
        guard let host else { return nil }
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let labels = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard !normalized.isEmpty, !normalized.contains(":"),
              labels.allSatisfy({ !$0.isEmpty }),
              !labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
        if labels.count == 1 { return String(labels[0]) }
        let suffix = labels.suffix(2).joined(separator: ".")
        if secondLevelSuffixes.contains(suffix) {
            guard labels.count >= 3 else { return nil }
            return String(labels[labels.count - 3])
        }
        return String(labels[labels.count - 2])
    }
}
