import AppKit
import BrowserCore
import Observation
import WebKit

@MainActor @Observable
final class DownloadItem: Identifiable {
    let id = UUID()
    var name = "Preparing download…"
    var status = "Choosing destination"
    var destination: URL?
    var temporaryURL: URL?
    var isFinished = false
    var isFailed = false
    var isPaused = false
    var isCancelling = false
    var bytesReceived: Int64 = 0
    var totalBytes: Int64 = 0
    var sourceURL: URL?
    var isPrivate = false
    var canResume: Bool { isPaused && resumeData != nil && sourceView != nil }
    var fractionCompleted: Double? { totalBytes > 0 ? min(1, Double(bytesReceived) / Double(totalBytes)) : nil }
    @ObservationIgnored var download: WKDownload?
    @ObservationIgnored weak var sourceView: WKWebView?
    @ObservationIgnored var resumeData: Data?
    @ObservationIgnored var observations: [NSKeyValueObservation] = []
    @ObservationIgnored var scopedAccess = false
}

@MainActor @Observable
final class DownloadManager: NSObject, WKDownloadDelegate {
    var items: [DownloadItem] = []
    var hasActiveDownloads: Bool { items.contains { !$0.isFinished } }
    @ObservationIgnored private var active: [ObjectIdentifier: DownloadItem] = [:]
    @ObservationIgnored var chooseDestination: ((String) async -> URL?)?

    func begin(_ download: WKDownload) {
        let item = DownloadItem()
        item.sourceView = download.webView
        item.isPrivate = download.webView?.configuration.websiteDataStore.isPersistent == false
        item.sourceURL = download.originalRequest?.url
        items.insert(item, at: 0)
        attach(download, to: item)
    }

    private func attach(_ download: WKDownload, to item: DownloadItem) {
        item.download = download; item.isFinished = false; item.isFailed = false; item.isPaused = false
        active[ObjectIdentifier(download)] = item
        download.delegate = self
        let progress = download.progress
        item.observations = [progress.observe(\.completedUnitCount, options: [.initial, .new]) { [weak item] value, _ in
            let received = value.completedUnitCount, total = value.totalUnitCount
            Task { @MainActor in item?.bytesReceived = received; item?.totalBytes = total }
        }, progress.observe(\.totalUnitCount, options: [.initial, .new]) { [weak item] value, _ in
            let total = value.totalUnitCount
            Task { @MainActor in item?.totalBytes = total }
        }]
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping @MainActor (URL?) -> Void) {
        guard let item = active[ObjectIdentifier(download)] else { completionHandler(nil); return }
        item.name = Self.safeFilename(suggestedFilename)
        Task { @MainActor in
            let url: URL?
            if let chooseDestination { url = await chooseDestination(item.name) }
            else {
                let panel = NSSavePanel(); panel.nameFieldStringValue = item.name; panel.title = "Save download"
                panel.canCreateDirectories = true
                url = await panel.begin() == .OK ? panel.url : nil
            }
            guard let url, active[ObjectIdentifier(download)] === item, !item.isCancelling else {
                completionHandler(nil); item.status = "Cancelled"; item.isFinished = true; finish(download); return
            }
            item.scopedAccess = url.startAccessingSecurityScopedResource()
            item.destination = url
            let temporaryURL = FileManager.default.temporaryDirectory.appendingPathComponent("oriv-download-\(UUID().uuidString)")
            item.temporaryURL = temporaryURL; item.status = "Downloading"
            completionHandler(temporaryURL)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = active[ObjectIdentifier(download)] else { return }
        if let temporary = item.temporaryURL, let destination = item.destination {
            do {
                // Keep Gatekeeper metadata even when WebKit used a temporary destination.
                try Self.markDownloadedFile(temporary, source: item.isPrivate ? nil : item.sourceURL)
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
                } else { try FileManager.default.moveItem(at: temporary, to: destination) }
                item.status = "Completed"
            } catch { item.status = "Could not save file: \(error.localizedDescription)"; item.isFailed = true }
        } else { item.status = "No download destination was selected."; item.isFailed = true }
        item.isFinished = true; finish(download)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = active[ObjectIdentifier(download)], !item.isCancelling else { return }
        item.status = error.localizedDescription; item.isFailed = true; item.isFinished = true
        item.resumeData = resumeData; item.isPaused = resumeData != nil
        finish(download, preservingPartial: resumeData != nil)
    }

    func pause(_ item: DownloadItem) {
        guard let download = item.download, !item.isCancelling, item.temporaryURL != nil else { return }
        item.isCancelling = true; item.status = "Pausing…"
        download.cancel { [weak self] data in
            item.isCancelling = false; item.isFinished = true; item.resumeData = data; item.isPaused = data != nil
            item.status = data == nil ? "Stopped — this server does not support resuming" : "Paused"
            self?.finish(download, preservingPartial: data != nil)
        }
    }
    func resume(_ item: DownloadItem) {
        guard item.canResume, let data = item.resumeData, let view = item.sourceView else { return }
        item.resumeData = nil; item.isPaused = false; item.isFinished = false; item.status = "Resuming…"
        view.resumeDownload(fromResumeData: data) { [weak self] download in
            guard let self, !item.isFinished else { download.cancel { _ in }; return }
            self.attach(download, to: item); item.status = "Downloading"
        }
    }
    func cancel(_ item: DownloadItem) {
        guard !item.isCancelling else { return }
        item.isCancelling = true
        if let download = item.download {
            download.cancel { [weak self] _ in
                item.isCancelling = false; item.status = "Cancelled"; item.isFinished = true
                self?.finish(download)
            }
        } else {
            cleanup(item); item.isCancelling = false; item.isPaused = false; item.isFinished = true; item.status = "Cancelled"
        }
    }
    func removeFinished() {
        for item in items where item.isFinished && !item.isPaused { cleanup(item) }
        items.removeAll { $0.isFinished && !$0.isPaused }
    }
    func shutdown() { for item in items { if let download = item.download { download.cancel { _ in } }; cleanup(item) } }

    private func finish(_ download: WKDownload, preservingPartial: Bool = false) {
        guard let item = active.removeValue(forKey: ObjectIdentifier(download)) else { return }
        item.observations = []; item.download = nil
        if !preservingPartial { cleanup(item) }
    }
    private func cleanup(_ item: DownloadItem) {
        if let temporary = item.temporaryURL { try? FileManager.default.removeItem(at: temporary) }
        item.temporaryURL = nil; item.resumeData = nil
        if item.scopedAccess { item.destination?.stopAccessingSecurityScopedResource(); item.scopedAccess = false }
    }
    static func safeFilename(_ value: String) -> String {
        let name = (value.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
            .components(separatedBy: .controlCharacters).joined().replacingOccurrences(of: ":", with: "-")
        return name.isEmpty || name == "." || name == ".." ? "Download" : String(name.prefix(200))
    }
    static func markDownloadedFile(_ url: URL, source: URL?) throws {
        var properties: [String: Any] = ["LSQuarantineType": "LSQuarantineTypeWebDownload", "LSQuarantineAgentName": AppIdentity.name, "LSQuarantineTimeStamp": Date()]
        if let source, AddressResolver.isWebURL(source) { properties["LSQuarantineDataURL"] = source }
        try (url as NSURL).setResourceValue(properties, forKey: .quarantinePropertiesKey)
    }
}
