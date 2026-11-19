import BrowserCore
import Foundation
import CoreGraphics
import ImageIO
import Observation

/// Transient pixels only: no file URL, disk writer, session or continuity API.
/// Entries retain only JPEG bytes and metadata. The presentation layer
/// separately bounds the decoded image held by each visible cover.
@MainActor @Observable public final class TabSnapshotCache {
    public struct Snapshot {
        public let jpeg: Data
        public let width: Int
        public let height: Int
        /// Original WebKit viewport in points, independent of JPEG pixels and
        /// display scale. Presentation must never fit these pixels to a new size.
        public let pointSize: CGSize
        init(jpeg: Data, width: Int, height: Int, pointSize: CGSize? = nil) {
            self.jpeg = jpeg; self.width = width; self.height = height
            self.pointSize = pointSize ?? CGSize(width: width, height: height)
        }
        // Allow for the snapshot metadata, cache key and collection storage.
        var cost: Int { jpeg.count + 256 }
    }
    public static let maximumDimension = 640
    public static let maximumDecodedBytes = maximumDimension * maximumDimension * 4
    public static let invalidated = Notification.Name("OrivTabSnapshotInvalidated")
    public let byteLimit: Int
    public private(set) var cost = 0
    private var revision = 0
    @ObservationIgnored private var entries: [UUID: Snapshot] = [:]
    @ObservationIgnored private var order: [UUID] = []
    @ObservationIgnored private var captureID: UUID?
    @ObservationIgnored private var captureStart = ContinuousClock.now
    private static let captureDeadline: Duration = .milliseconds(750)
    @ObservationIgnored private var deadline: Task<Void, Never>?

    public init(byteLimit: Int = 8 * 1024 * 1024) { self.byteLimit = max(0, byteLimit) }
    public var count: Int { _ = revision; return entries.count }
    public func snapshot(for id: UUID) -> Snapshot? {
        _ = revision
        guard let snapshot = entries[id] else { return nil }
        order.removeAll { $0 == id }; order.append(id)
        return snapshot
    }
    func insert(_ snapshot: Snapshot, for id: UUID) {
        remove(id)
        guard snapshot.width > 0, snapshot.height > 0,
              snapshot.pointSize.width.isFinite, snapshot.pointSize.height.isFinite,
              snapshot.pointSize.width > 0, snapshot.pointSize.height > 0,
              snapshot.width <= Self.maximumDimension, snapshot.height <= Self.maximumDimension,
              snapshot.cost <= byteLimit else { return }
        while cost > byteLimit - snapshot.cost, let oldest = order.first { remove(oldest) }
        entries[id] = snapshot; order.append(id); cost += snapshot.cost
        revision += 1
    }
    public func remove(_ id: UUID) {
        if let previous = entries.removeValue(forKey: id) { cost -= previous.cost; revision += 1 }
        order.removeAll { $0 == id }
        NotificationCenter.default.post(name:Self.invalidated,object:self,userInfo:["tabID":id])
    }
    public func removeAll() {
        cancelCapture(); entries.removeAll(); order.removeAll(); cost = 0; revision += 1
        NotificationCenter.default.post(name:Self.invalidated,object:self)
    }
    func beginCapture() -> UUID? {
        // An expired capture never blocks the next switch, even if its timer hasn't run yet.
        if captureID != nil, ContinuousClock.now - captureStart >= Self.captureDeadline { cancelCapture() }
        guard captureID == nil, byteLimit > 0 else { return nil }
        let id = UUID(); captureID = id; captureStart = .now
        deadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(750)) } catch { return }
            if self?.captureID == id { self?.cancelCapture() }
        }
        return id
    }
    func finishCapture(_ id: UUID) -> Bool {
        guard captureID == id else { return false }
        let expired = ContinuousClock.now - captureStart >= Self.captureDeadline
        cancelCapture(); return !expired
    }
    private func cancelCapture() { captureID = nil; deadline?.cancel(); deadline = nil }

    static func compress(_ source: CGImage, pointSize: CGSize? = nil) -> Snapshot? {
        let scale = min(1, CGFloat(maximumDimension) / CGFloat(max(source.width, source.height)))
        let width = max(1, Int(CGFloat(source.width) * scale)), height = max(1, Int(CGFloat(source.height) * scale))
        guard let context = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.setFillColor(CGColor(gray:1,alpha:1)); context.fill(CGRect(x:0,y:0,width:width,height:height))
        context.draw(source,in:CGRect(x:0,y:0,width:width,height:height))
        // WKWebView can return an unpainted solid surface just after attachment.
        // It is not a useful last frame. A labelled colour fallback is safer
        // than caching a white/black bitmap and treating it as page content.
        guard let pixels = context.data?.assumingMemoryBound(to:UInt8.self) else { return nil }
        let first = (Int(pixels[0]),Int(pixels[1]),Int(pixels[2]))
        var detail = false
        for index in stride(from:4,to:width*height*4,by:4) {
            if abs(Int(pixels[index])-first.0) > 8 || abs(Int(pixels[index+1])-first.1) > 8 || abs(Int(pixels[index+2])-first.2) > 8 {
                detail = true; break
            }
        }
        guard detail else { return nil }
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data,"public.jpeg" as CFString,1,nil) else { return nil }
        CGImageDestinationAddImage(destination,image,[kCGImageDestinationLossyCompressionQuality:0.65] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return Snapshot(jpeg:data as Data,width:width,height:height,pointSize:pointSize ?? CGSize(width:source.width,height:source.height))
    }
}
