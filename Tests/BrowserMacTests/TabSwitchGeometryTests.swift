import AppKit
import BrowserCore
@testable import BrowserEngine
import WebKit
import XCTest
@testable import PersonalBrowser

/// App-owned background pixels. The delayed public rendering barrier makes
/// both sides of the swap observable without relying on scheduler timing.
@MainActor final class TabSwitchGeometryTests: BackgroundUITestCase {
    func testSnapshotToLiveFrameSequence() async throws {
        try await captureSwitch(resize: false)
    }
    func testResizedSnapshotToLiveFrameSequence() async throws {
        try await captureSwitch(resize: true)
    }
    func testProfileFadeKeepsLoadingLabelHiddenUntilDestinationPaint() async throws {
        let session = BrowserSession(dataStore: .nonPersistent(), adBlocker: AdBlocker(defaults: nil), settings: BrowserSettings(defaults: nil))
        defer { session.shutdown() }
        let destination = session.addTab(load: false)
        destination.createWebView = { GeometrySnapshotWebView(frame: .zero, configuration: $0) }
        let web = try XCTUnwrap(destination.webView as? GeometrySnapshotWebView)
        let window = BackgroundUIMode.Window(contentRect: CGRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = WebViewHost(webView: web, tab: destination, profileEpoch: UUID())
        host.wantsLayer = true
        window.contentView = host; BackgroundUIMode.show(window, key: false)
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        web.loadHTMLString("<body style='background:#e32354'></body>", baseURL: URL(string: "https://profile-fade.test"))
        for _ in 0..<200 {
            if destination.hasRenderedContent && host.switchCover.isHidden { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(destination.hasRenderedContent)
        XCTAssertTrue(host.switchCover.isHidden)

        // Compare the native backing a fade can use with WebKit's snapshot.
        // An offscreen window does not provide a WindowServer frame recording.
        let native = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: native)
        let page = try await pixels(web)
        let data = try XCTUnwrap(page.tiffRepresentation)
        let webBitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        func redPage(_ bitmap: NSBitmapImageRep) -> Bool {
            guard let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB) else { return false }
            return color.redComponent > 0.7 && color.greenComponent < 0.3 && color.blueComponent < 0.5
        }
        XCTAssertTrue(redPage(webBitmap))
        print("PROFILE_CONTENT WebKitPixels=\(redPage(webBitmap)) nativeBackingPixels=\(redPage(native))")

        let source = session.addTab(load: false)
        host.setTab(source, profileEpoch: UUID())
        web.holdBarrier = true
        session.selectTab(destination.id)
        host.setTab(destination, profileEpoch: UUID())
        host.layoutSubtreeIfNeeded()
        let cover = host.switchCover
        let label = try XCTUnwrap(cover.subviews.compactMap { $0 as? NSTextField }.first)
        XCTAssertFalse(cover.isHidden)
        XCTAssertTrue(label.isHidden)
        XCTAssertFalse(web.barrierSizes.isEmpty)
        web.releaseBarrier()
        XCTAssertFalse(cover.isHidden, "Profile changes fade the destination cover after paint")
        for _ in 0..<60 where !cover.isHidden { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(cover.isHidden)
    }

    private func captureSwitch(resize: Bool) async throws {
        let session = BrowserSession(dataStore: .nonPersistent(), adBlocker: AdBlocker(defaults: nil), settings: BrowserSettings(defaults: nil))
        defer { session.shutdown() }
        let tab = session.addTab(load: false)
        tab.createWebView = { GeometrySnapshotWebView(frame: .zero, configuration: $0) }
        let web = try XCTUnwrap(tab.webView as? GeometrySnapshotWebView)
        let window = BackgroundUIMode.Window(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = WebViewHost(webView: web, tab: tab)
        window.contentView = host; BackgroundUIMode.show(window, key: false)
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        web.loadHTMLString("""
            <style>html,body{margin:0;background:#f3f5ef;color:#172d3e;font:24px system-ui}
            .anchor{position:absolute;left:80px;top:100px;width:160px;height:80px;background:#176ce3}
            .line{position:absolute;left:400px;top:0;width:4px;height:600px;background:#de6633}</style>
            <div style='padding:24px'>Viewport geometry • 800 × 600</div><div class=anchor></div><div class=line></div>
            """, baseURL: URL(string: "https://geometry.example"))
        for _ in 0..<200 {
            if !web.isLoading && tab.hasRenderedContent { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(tab.hasRenderedContent)
        try await Task.sleep(for: .milliseconds(150))
        for _ in 0..<100 {
            if host.switchCover.isHidden { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let image = try await pixels(web)
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let snapshot = try XCTUnwrap(TabSnapshotCache.compress(cg, pointSize: web.bounds.size))
        let source = session.addTab(load: false)
        host.setTab(source); host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(120))
        session.tabSnapshots.insert(snapshot, for: tab.id)
        if resize { window.setContentSize(CGSize(width: 1000, height: 700)) }
        host.needsLayout = true; host.layoutSubtreeIfNeeded()
        web.holdBarrier = true
        session.selectTab(tab.id)
        host.setTab(tab); host.needsLayout = true; host.layoutSubtreeIfNeeded()
        var frames: [[String: Any]] = []
        let started = ProcessInfo.processInfo.systemUptime
        for frame in 0..<8 {
            if frame == 4 { web.releaseBarrier() }
            try await Task.sleep(for: .milliseconds(40))
            let cover = host.switchCover
            cover.layoutSubtreeIfNeeded()
            let covered = !cover.isHidden
            XCTAssertEqual(cover.frame, web.frame)
            let snapshotView = try XCTUnwrap(cover.subviews.compactMap { $0 as? NSImageView }.first)
            XCTAssertEqual(snapshotView.imageScaling, .scaleNone)
            XCTAssertEqual(snapshotView.imageAlignment, .alignTopLeft)
            if let image = snapshotView.image { XCTAssertEqual(image.size, snapshot.pointSize) }
            XCTAssertEqual(cover.alphaValue, 1, "Mac handoff must be instant, with no inherited opacity animation")
            XCTAssertTrue((cover.layer?.animationKeys() ?? []).isEmpty)
            XCTAssertTrue((snapshotView.layer?.animationKeys() ?? []).isEmpty)
            let live = covered ? image : try await pixels(web)
            let result = NSImage(size: host.bounds.size)
            result.lockFocus()
            live.draw(in: host.bounds)
            if covered {
                let bitmap = try XCTUnwrap(cover.bitmapImageRepForCachingDisplay(in: cover.bounds))
                cover.cacheDisplay(in: cover.bounds, to: bitmap)
                NSImage(cgImage: try XCTUnwrap(bitmap.cgImage), size: cover.bounds.size)
                    .draw(in: host.bounds, from: .zero, operation: .sourceOver, fraction: cover.alphaValue)
            }
            result.unlockFocus()
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(result.tiffRepresentation)))
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let name = (resize ? "resized-" : "") + String(format: "switch-%02d", frame)
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
            frames.append(["frame": frame, "elapsedMs": (ProcessInfo.processInfo.systemUptime - started) * 1000,
                           "covered": covered, "snapshot": cover.containsSnapshot, "alpha": cover.alphaValue])
        }
        XCTAssertTrue(host.switchCover.isHidden)
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: frames, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = (resize ? "resized-" : "") + "switch-frames"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testSnapshotKeepsItsPointSizeAndTopLeadingAnchorAcrossViewportChanges() throws {
        let session = BrowserSession(dataStore: .nonPersistent(), adBlocker: AdBlocker(defaults: nil), settings: BrowserSettings(defaults: nil))
        defer { session.shutdown() }
        let tab = session.addTab(load: false)
        let context = try XCTUnwrap(CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 1600,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(CGRect(x: 30, y: 30, width: 80, height: 80))
        let pointSize = CGSize(width: 800, height: 600)
        session.tabSnapshots.insert(try XCTUnwrap(TabSnapshotCache.compress(try XCTUnwrap(context.makeImage()), pointSize: pointSize)), for: tab.id)
        let cover = TabSwitchCover()
        cover.begin(tab, in: tab.webView)
        let image = try XCTUnwrap(cover.subviews.compactMap { $0 as? NSImageView }.first)
        for viewport in [pointSize, CGSize(width: 560, height: 600), CGSize(width: 1100, height: 720)] {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 1; context.allowsImplicitAnimation = true
                cover.frame = CGRect(origin: .zero, size: viewport)
                cover.needsLayout = true; cover.layoutSubtreeIfNeeded()
            }
            XCTAssertEqual(image.image?.size, pointSize)
            XCTAssertEqual(image.imageScaling, .scaleNone)
            XCTAssertEqual(image.imageAlignment, .alignTopLeft)
            XCTAssertTrue(cover.clipsToBounds)
            XCTAssertTrue((image.layer?.animationKeys() ?? []).isEmpty)
        }
    }

    func testRenderBarrierWaitsForFinalLayoutAndRejectsPaintFromPreviousSize() throws {
        let tab = BrowserTab(dataStore: .nonPersistent()); defer { tab.close() }
        tab.createWebView = { GeometrySnapshotWebView(frame: .zero, configuration: $0) }
        let web = try XCTUnwrap(tab.webView as? GeometrySnapshotWebView)
        web.holdBarrier = true
        tab.webView(web, didFinish: nil)
        let host = WebViewHost(webView: web, tab: tab)
        XCTAssertTrue(web.barrierSizes.isEmpty, "A new host has not received its final frame yet")
        let window = BackgroundUIMode.Window(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host; BackgroundUIMode.show(window, key: false)
        defer { window.contentView = nil; window.close() }
        host.needsLayout = true; host.layoutSubtreeIfNeeded()
        XCTAssertEqual(web.barrierSizes, [web.bounds.size])
        let original = web.bounds.size
        window.setContentSize(CGSize(width: 1000, height: 700))
        host.needsLayout = true; host.layoutSubtreeIfNeeded()
        XCTAssertNotEqual(web.bounds.size, original)
        web.completeBarrier()
        XCTAssertFalse(host.switchCover.isHidden, "The old-size paint cannot release the cover")
        XCTAssertEqual(web.barrierSizes.count, 2)
        XCTAssertEqual(web.barrierSizes.last, web.bounds.size)
        web.completeBarrier()
        XCTAssertTrue(host.switchCover.isHidden)
        XCTAssertEqual(host.switchCover.alphaValue, 1)
        XCTAssertTrue((host.switchCover.layer?.animationKeys() ?? []).isEmpty)
    }

    private func pixels(_ web: WKWebView) async throws -> NSImage {
        let config = WKSnapshotConfiguration(); config.afterScreenUpdates = true; config.snapshotWidth = NSNumber(value: web.bounds.width)
        return try await withCheckedThrowingContinuation { reply in
            web.takeSnapshot(with: config) { image, error in
                if let image { reply.resume(returning: image) }
                else { reply.resume(throwing: error ?? NSError(domain: "GeometrySnapshot", code: 1)) }
            }
        }
    }
}

@MainActor private final class GeometrySnapshotWebView: WKWebView {
    var holdBarrier = false
    var barrierSizes: [CGSize] = []
    private var pending: (() -> Void)?
    override func takeSnapshot(with configuration: WKSnapshotConfiguration?, completionHandler: @escaping (NSImage?, (any Error)?) -> Void) {
        if holdBarrier, configuration?.snapshotWidth == 8 {
            barrierSizes.append(bounds.size)
            pending = { completionHandler(NSImage(size: CGSize(width: 8, height: 8)), nil) }
        } else { super.takeSnapshot(with: configuration, completionHandler: completionHandler) }
    }
    func completeBarrier() { let callback = pending; pending = nil; callback?() }
    func releaseBarrier() { holdBarrier = false; completeBarrier() }
}
