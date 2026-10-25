import AppKit
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
    @ObservationIgnored var download: WKDownload?
    @ObservationIgnored var scopedAccess = false
}

@MainActor @Observable
final class DownloadManager: NSObject, WKDownloadDelegate {
    var items: [DownloadItem] = []
    @ObservationIgnored private var active: [ObjectIdentifier: DownloadItem] = [:]

    func begin(_ download: WKDownload) {
        let item = DownloadItem()
        item.download = download
        items.insert(item, at: 0)
        active[ObjectIdentifier(download)] = item
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping @MainActor (URL?) -> Void) {
        guard let item = active[ObjectIdentifier(download)] else { completionHandler(nil); return }
        item.name = (suggestedFilename as NSString).lastPathComponent
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.name
        panel.title = "Save download"
        panel.canCreateDirectories = true
        panel.begin { result in
            guard result == .OK, let url = panel.url else {
                item.status = "Cancelled"
                item.isFinished = true
                completionHandler(nil)
                self.finish(download)
                return
            }
            item.scopedAccess = url.startAccessingSecurityScopedResource()
            item.destination = url
            let temporaryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            item.temporaryURL = temporaryURL
            item.status = "Downloading"
            completionHandler(temporaryURL)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        if let item = active[ObjectIdentifier(download)], let temporary = item.temporaryURL, let destination = item.destination {
            do {
                // Preserve an existing destination until the complete download is ready.
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
                } else {
                    try FileManager.default.moveItem(at: temporary, to: destination)
                }
                item.status = "Completed"
            } catch {
                item.status = "Could not save file: \(error.localizedDescription)"
                item.isFailed = true
            }
            item.isFinished = true
        }
        finish(download)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        if let item = active[ObjectIdentifier(download)] {
            item.status = error.localizedDescription
            item.isFailed = true
            item.isFinished = true
        }
        finish(download)
    }

    func cancel(_ item: DownloadItem) {
        guard let download = item.download else { return }
        download.cancel { _ in }
        item.status = "Cancelled"
        item.isFinished = true
        finish(download)
    }

    private func finish(_ download: WKDownload) {
        guard let item = active.removeValue(forKey: ObjectIdentifier(download)) else { return }
        if let temporary = item.temporaryURL { try? FileManager.default.removeItem(at: temporary) }
        if item.scopedAccess { item.destination?.stopAccessingSecurityScopedResource() }
        item.download = nil
    }
}
