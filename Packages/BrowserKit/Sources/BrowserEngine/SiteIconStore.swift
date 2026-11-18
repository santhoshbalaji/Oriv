import BrowserCore
import CryptoKit
import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers
import WebKit

/// Already decoded off the main actor; rendering never decodes an original image.
public struct SiteIcon: @unchecked Sendable {
    public let image: CGImage
    public let png: Data
}

/// The only disk writer. Regular profiles have separate directories; private
/// requests never call it. Entries are 64px PNGs, at most 256 files / 4 MiB.
public actor SiteIconDiskCache {
    public static let maximumEntries = 256
    public static let maximumBytes = 4 * 1_024 * 1_024
    private let directory: URL?
    public init(directory: URL?) { self.directory = directory }
    private func file(_ key: String) -> URL? {
        directory?.appendingPathComponent(SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() + ".png")
    }
    public func read(_ key: String) -> SiteIcon? {
        guard let file = file(key), let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let date = values.contentModificationDate, Date().timeIntervalSince(date) < 7 * 86_400,
              (values.fileSize ?? .max) <= 128 * 1_024, let data = try? Data(contentsOf: file) else { return nil }
        return Self.decode(data)
    }
    public func write(_ icon: SiteIcon, key: String) {
        guard let directory, let file = file(key) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try icon.png.write(to: file, options: .atomic)
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
                .filter { $0.pathExtension == "png" }
                .map { ($0, try $0.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])) }
                .sorted { ($0.1.contentModificationDate ?? .distantPast) > ($1.1.contentModificationDate ?? .distantPast) }
            var bytes = 0
            for (index, item) in files.enumerated() {
                bytes += item.1.fileSize ?? 0
                if index >= Self.maximumEntries || bytes > Self.maximumBytes { try? FileManager.default.removeItem(at: item.0) }
            }
        } catch { /* A cache failure never interrupts browsing. */ }
    }
    public func clear() { if let directory { try? FileManager.default.removeItem(at: directory) } }
    public func decode(_ data: Data) -> SiteIcon? { Self.decode(data) }
    private static func decode(_ data: Data) -> SiteIcon? {
        guard data.count <= 1_048_576, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 64,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return SiteIcon(image: image, png: output as Data)
    }
}

@MainActor @Observable public final class SiteIconStore {
    public static let memoryLimit = 128
    public private(set) var revision = 0
    @ObservationIgnored private var icons: [String: SiteIcon] = [:]
    @ObservationIgnored private var order: [String] = []
    @ObservationIgnored private var requests: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var requestTokens: [String: UUID] = [:]
    @ObservationIgnored private var cacheGeneration = 0
    @ObservationIgnored private var misses: [String: Date] = [:]
    @ObservationIgnored private var privateGeneration = 0
    @ObservationIgnored private let disk: SiteIconDiskCache
    /// Returns only an already instantiated, loaded page. Looking up an icon
    /// must never restore a sleeping tab or navigate a bookmark/history entry.
    @ObservationIgnored public var document: ((URL, Bool) -> WKWebView?)?
    public init(directory: URL? = nil) { disk = SiteIconDiskCache(directory: directory) }
    public static func key(_ url: URL, isPrivate: Bool) -> String? {
        guard AddressResolver.isWebURL(url), let host = url.host?.lowercased() else { return nil }
        return (isPrivate ? "private:" : "regular:") + (url.scheme ?? "https") + "://" + host + (url.port.map { ":\($0)" } ?? "")
    }
    public func icon(for url: URL?, isPrivate: Bool) -> SiteIcon? {
        _ = revision
        guard let url, let key = Self.key(url, isPrivate: isPrivate) else { return nil }
        return icons[key]
    }
    public func load(_ url: URL, isPrivate: Bool) async {
        guard let key = Self.key(url, isPrivate: isPrivate) else { return }
        if icons[key] != nil { touch(key); return }
        if let request = requests[key] { await request.value; return }
        if let miss = misses[key], Date().timeIntervalSince(miss) < 30 { return }
        guard requests.count < 16 else { return }
        let generation = privateGeneration
        let cacheGeneration = self.cacheGeneration
        let token = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if requestTokens[key] == token { requests[key] = nil; requestTokens[key] = nil }
            }
            var attempted = false
            weak var attemptedView: WKWebView?
            var icon = isPrivate ? nil : await disk.read(key)
            let cacheHit = icon != nil
            if icon == nil, !Task.isCancelled, let view = document?(url, isPrivate),
               let pageURL = view.url, Self.key(pageURL, isPrivate: isPrivate) == key {
                attempted = true
                attemptedView = view
                icon = await fetch(in: view, pageURL: pageURL, isPrivate: isPrivate)
            }
            guard !Task.isCancelled, cacheGeneration == self.cacheGeneration, !isPrivate || generation == privateGeneration else { return }
            if let icon {
                icons[key] = icon; touch(key)
                while order.count > Self.memoryLimit { icons[order.removeFirst()] = nil }
                revision += 1
                if !isPrivate && !cacheHit { await disk.write(icon, key: key) }
            } else if attempted, let view = attemptedView,
                      canDiscover(in: view, pageURL: url, isPrivate: isPrivate) {
                misses[key] = Date()
                if misses.count > Self.memoryLimit { misses.removeValue(forKey: misses.keys.sorted().first!) }
            }
        }
        requestTokens[key] = token
        requests[key] = task
        await task.value
    }
    private func touch(_ key: String) { order.removeAll { $0 == key }; order.append(key) }
    public func endPrivateSession() {
        privateGeneration += 1
        for key in Array(requests.keys) where key.hasPrefix("private:") { requests.removeValue(forKey: key)?.cancel(); requestTokens[key] = nil }
        icons = icons.filter { !$0.key.hasPrefix("private:") }
        misses = misses.filter { !$0.key.hasPrefix("private:") }
        order.removeAll { $0.hasPrefix("private:") }; revision += 1
    }
    public func shutdown() { cacheGeneration += 1; requests.values.forEach { $0.cancel() }; requests = [:]; requestTokens = [:]; document = nil; endPrivateSession() }
    public func clear() async {
        cacheGeneration += 1
        requests.values.forEach { $0.cancel() }; requests = [:]; requestTokens = [:]; endPrivateSession()
        icons = [:]; order = []; misses = [:]; revision += 1
        await disk.clear()
    }
    private func canDiscover(in view: WKWebView, pageURL: URL, isPrivate: Bool) -> Bool {
        !Task.isCancelled && !view.isLoading && view.url == pageURL && document?(pageURL, isPrivate) === view
    }
    private func fetch(in view: WKWebView, pageURL: URL, isPrivate: Bool) async -> SiteIcon? {
        guard canDiscover(in: view, pageURL: pageURL, isPrivate: isPrivate) else { return nil }
        // The site's own DOM supplies candidates. No history URL is probed.
        let links = (try? await view.evaluateJavaScript("""
            Array.from(document.querySelectorAll('link[rel]')).filter(l =>
              /^(icon|shortcut icon|apple-touch-icon|apple-touch-icon-precomposed)$/i.test(l.rel.trim()))
              .slice(0, 8).map(l => l.href)
            """)) as? [String] ?? []
        var candidates = links.compactMap(URL.init(string:))
        if let fallback = URL(string: "/favicon.ico", relativeTo: pageURL)?.absoluteURL { candidates.append(fallback) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 5; configuration.timeoutIntervalForResource = 8
        // An ephemeral cookie jar seeded from this WKWebsiteDataStore retains
        // domain/path/secure matching, including across redirects.
        let cookies = await view.configuration.websiteDataStore.httpCookieStore.allCookies()
        Self.firstPartyCookies(cookies, pageURL: pageURL).forEach { configuration.httpCookieStorage?.setCookie($0) }
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        for url in candidates.prefix(9) {
            guard canDiscover(in: view, pageURL: pageURL, isPrivate: isPrivate) else { return nil }
            var data: Data?
            if url.scheme == "data", url.absoluteString.utf8.count < 1_400_000 { data = Self.dataURL(url) }
            else if AddressResolver.isWebURL(url), pageURL.scheme != "https" || url.scheme == "https" {
                data = await Self.download(url, session: session, securePage: pageURL.scheme == "https")
            }
            guard let data else { continue }
            if let icon = await disk.decode(data) { return icon }
            // Download/decoding can outlive selection, discard or a same-URL
            // navigation. Revalidate before executing any more document JS.
            guard canDiscover(in: view, pageURL: pageURL, isPrivate: isPrivate) else { return nil }
            // WebKit can rasterize SVG / ICO types ImageIO doesn't accept. The
            // bytes are supplied, so this fallback performs no extra network load.
            let png = try? await view.callAsyncJavaScript("""
                const image = new Image(); image.src = source;
                await image.decode();
                const canvas = document.createElement('canvas'); canvas.width = canvas.height = 64;
                const scale = Math.min(64/image.naturalWidth, 64/image.naturalHeight);
                canvas.getContext('2d').drawImage(image, 0, 0, image.naturalWidth*scale, image.naturalHeight*scale);
                return canvas.toDataURL('image/png');
                """, arguments: ["source": "data:image/svg+xml;base64," + data.base64EncodedString()], in: nil, contentWorld: .world(name: "OrivSiteIcon")) as? String
            if let png, let url = URL(string: png), let data = Self.dataURL(url), let icon = await disk.decode(data) { return icon }
        }
        return nil
    }
    /// A linked third-party icon must not gain the rest of the profile's
    /// authenticated cookies by bypassing WebKit's third-party-cookie policy.
    static func firstPartyCookies(_ cookies: [HTTPCookie], pageURL: URL) -> [HTTPCookie] {
        guard let host = pageURL.host?.lowercased() else { return [] }
        return cookies.filter { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return !domain.isEmpty && (host == domain || host.hasSuffix("." + domain))
        }
    }
    private nonisolated static func download(_ url: URL, session: URLSession, securePage: Bool) async -> Data? {
        do {
            let (bytes, response) = try await session.bytes(from: url)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
                  !securePage || response.url?.scheme == "https",
                  response.expectedContentLength <= 1_048_576 else { return nil }
            var result = Data()
            for try await byte in bytes {
                guard !Task.isCancelled, result.count < 1_048_576 else { return nil }
                result.append(byte)
            }
            return result
        } catch { return nil }
    }
    private static func dataURL(_ url: URL) -> Data? {
        let parts = url.absoluteString.split(separator: ",", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return parts[0].hasSuffix(";base64") ? Data(base64Encoded: String(parts[1])) : String(parts[1]).removingPercentEncoding?.data(using: .utf8)
    }
}
