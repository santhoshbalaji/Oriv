import Foundation

public struct ContinuityPage: Equatable, Sendable {
    public var url: URL
    public var title: String
    public var profile: ContinuityProfile
    public init?(url: URL?, title: String, profile: BrowserProfile, isPrivate: Bool) {
        guard !isPrivate, let url, ContinuityRecord.safeURL(url), title.count <= 4_000 else { return nil }
        self.url = URLCleaner.clean(url); self.title = title; self.profile = ContinuityProfile(profile)
    }
    public var userInfo: [String: String] {
        ["url": url.absoluteString, "title": title, "profileID": profile.id.uuidString, "profileName": profile.name,
         "profileColor": profile.color.rawValue, "profileSymbol": profile.symbol.rawValue]
    }
    public init?(userInfo: [AnyHashable: Any]?) {
        guard let values = userInfo, let address = values["url"] as? String, let url = URL(string: address),
              let title = values["title"] as? String, let rawID = values["profileID"] as? String, let id = UUID(uuidString: rawID),
              let name = values["profileName"] as? String, ProfileRegistry.validName(name),
              let rawColor = values["profileColor"] as? String, let color = ProfileColor(rawValue: rawColor),
              let rawSymbol = values["profileSymbol"] as? String, let symbol = ProfileSymbol(rawValue: rawSymbol) else { return nil }
        self.init(url: url, title: title, profile: BrowserProfile(id: id, name: name, color: color, symbol: symbol), isPrivate: false)
    }
}

public extension ProfileRegistry {
    /// Preserve stable identities and local archive/selection state. Name collisions never join website stores.
    func importingContinuity(_ incoming: [ContinuityProfile]) throws -> Self {
        var next = self
        for value in incoming {
            if let index = next.profiles.firstIndex(where: { $0.id == value.id }) {
                next.profiles[index].name = value.name; next.profiles[index].color = value.color; next.profiles[index].symbol = value.symbol
            } else { next.profiles.append(value.browserProfile) }
        }
        var used = Set<String>()
        for index in next.profiles.indices.sorted(by: { next.profiles[$0].id.uuidString < next.profiles[$1].id.uuidString }) {
            let base = next.profiles[index].name
            var name = base, suffix = 2
            while !used.insert(name.lowercased()).inserted {
                name = String(base.prefix(32)) + " (\(suffix))"; suffix += 1
            }
            next.profiles[index].name = name
        }
        return try next.validated()
    }
}
