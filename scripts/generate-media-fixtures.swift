// Generate original test media using Apple's encoders; no downloads or third-party tools.
// Usage: swift scripts/generate-media-fixtures.swift build/media-fixtures
import AppKit
import AVFoundation
import CoreVideo

let directory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/media-fixtures")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let seconds = 12
let fps: Int32 = 30
let width = 640, height = 360

func output(_ name: String) throws -> URL {
    let url = directory.appendingPathComponent(name)
    if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    return url
}

func makeVideo(_ name: String, codec: AVVideoCodecType) async throws -> URL {
    let url = try output(name)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: codec, AVVideoWidthKey: width, AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 600_000,
                                        AVVideoMaxKeyFrameIntervalKey: fps]
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
        sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                                     kCVPixelBufferWidthKey as String: width,
                                     kCVPixelBufferHeightKey as String: height])
    writer.add(input)
    guard writer.startWriting() else { throw writer.error! }
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<(seconds * Int(fps)) {
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed { throw writer.error! }
            try await Task.sleep(for: .milliseconds(5))
        }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer) == kCVReturnSuccess,
              let buffer else { fatalError("Cannot allocate test frame") }
        CVPixelBufferLockBaseAddress(buffer, [])
        let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
        context.setFillColor(NSColor(red: 0.04, green: 0.08, blue: 0.13, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let x = Double(frame % 180) / 180 * 540
        context.setFillColor(NSColor.systemTeal.cgColor)
        context.fill(CGRect(x: x, y: 90, width: 100, height: 100))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let text = String(format: "Personal Browser · %@\nFrame %03d · %.2f seconds", codec.rawValue, frame, Double(frame) / Double(fps))
        (text as NSString).draw(in: CGRect(x: 24, y: 230, width: 590, height: 100), withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 22, weight: .medium), .foregroundColor: NSColor.white
        ])
        NSGraphicsContext.restoreGraphicsState()
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: fps)) else { throw writer.error! }
    }
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { throw writer.error! }
    return url
}

func makeTone() throws -> URL {
    let samples = 24_000 * seconds
    var data = Data()
    func ascii(_ value: String) { data.append(contentsOf: value.utf8) }
    func u32(_ value: UInt32) { var n = value.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
    func u16(_ value: UInt16) { var n = value.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
    ascii("RIFF"); u32(UInt32(36 + samples * 2)); ascii("WAVEfmt "); u32(16)
    u16(1); u16(1); u32(24_000); u32(48_000); u16(2); u16(16); ascii("data"); u32(UInt32(samples * 2))
    for sample in 0..<samples {
        let tone = sin(Double(sample) * 2 * .pi * 440 / 24_000) * 1_000
        u16(UInt16(bitPattern: Int16(tone)))
    }
    let url = try output("tone.wav"); try data.write(to: url); return url
}

let video = try await makeVideo("silent.mp4", codec: .h264)
_ = try await makeVideo("hevc.mp4", codec: .hevc)
let audio = try makeTone()
let composition = AVMutableComposition()
for (url, type) in [(video, AVMediaType.video), (audio, AVMediaType.audio)] {
    let asset = AVURLAsset(url: url)
    let source = try await asset.loadTracks(withMediaType: type).first!
    let track = composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid)!
    try track.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: Double(seconds), preferredTimescale: 600)), of: source, at: .zero)
}
let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPreset640x480)!
exporter.shouldOptimizeForNetworkUse = true
try await exporter.export(to: output("avc-aac.mp4"), as: .mp4)
print("Generated H.264/AAC, silent H.264 and HEVC fixtures in \(directory.path)")
