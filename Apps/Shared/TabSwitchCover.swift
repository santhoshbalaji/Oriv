import SwiftUI
import WebKit
import BrowserCore
import BrowserEngine
import ImageIO
import Observation

#if os(macOS)
typealias CoverView = NSView
typealias CoverImage = NSImageView
#else
typealias CoverView = UIView
typealias CoverImage = UIImageView
#endif

/// A destination-only cover. Never borrow pixels from another tab or privacy
/// mode. A first paint signal identifies the document; a public WK snapshot
/// after attachment supplies the rendering barrier before cover dismissal.
final class TabSwitchCover: CoverView {
    private let imageView = CoverImage()
    private var generation = 0
    private var confirming = false
    private var renderAttempts = 0
    private weak var webView: WKWebView?
    private weak var presentedTab: BrowserTab?
    private var tabID: UUID?
    private var paintRevision = 0
    private var ready = false
    private var allowsPageInput = false
    private var waitingForLayout = false
    var reduceMotion = false
    var containsSnapshot: Bool { imageView.image != nil }
    #if os(macOS)
    private let label = NSTextField(labelWithString: "Loading page…")
    override var isOpaque: Bool { true }
    #else
    private let label = UILabel()
    #endif

    init() {
        super.init(frame: .zero)
        #if os(macOS)
        wantsLayer = true
        imageView.imageScaling = .scaleNone
        imageView.imageAlignment = .alignTopLeft
        clipsToBounds = true
        label.textColor = .secondaryLabelColor; label.alignment = .center
        #else
        isOpaque = true; label.text = "Loading page…"; label.textColor = .secondaryLabel; label.textAlignment = .center
        imageView.contentMode = .scaleToFill
        #endif
        addSubview(imageView); addSubview(label)
        NotificationCenter.default.addObserver(self,selector:#selector(invalidateImage(_:)),name:TabSnapshotCache.invalidated,object:nil)
        isHidden = true
        #if os(macOS)
        setAccessibilityElement(false)
        #else
        accessibilityElementsHidden = true
        #endif
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func invalidateImage(_ note:Notification) {
        if let id = note.userInfo?["tabID"] as? UUID, id != tabID { return }
        imageView.image = nil; label.isHidden = false
    }

    func begin(_ tab: BrowserTab, in webView: WKWebView, waitForLayout: Bool = false) {
        #if os(macOS)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        #endif
        cancel()
        presentedTab = tab; tab.switchPresentation = self
        generation += 1; confirming = false; renderAttempts = 0; ready = false; self.webView = webView; tabID = tab.id
        waitingForLayout = waitForLayout
        paintRevision = tab.documentRevision
        #if os(macOS)
        layer?.removeAllAnimations(); alphaValue = 1
        #else
        layer.removeAllAnimations(); alpha = 1; isUserInteractionEnabled = true
        #endif
        if let snapshot = tab.switchSnapshot, let source = CGImageSourceCreateWithData(snapshot.jpeg as CFData,nil),
           let cg = CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCacheImmediately:true] as CFDictionary) {
            #if os(macOS)
            imageView.image = NSImage(cgImage:cg,size:snapshot.pointSize)
            #else
            imageView.image = UIImage(cgImage:cg)
            #endif
        } else { imageView.image = nil }
        label.isHidden = imageView.image != nil
        let background = tab.lastPageBackground ?? ChromeColor(0.94,0.95,0.94)
        #if os(macOS)
        layer?.backgroundColor = NSColor(srgbRed:background.red,green:background.green,blue:background.blue,alpha:1).cgColor
        label.textColor = (background.whiteForeground ? NSColor.white : .black).withAlphaComponent(0.75)
        #else
        backgroundColor = UIColor(red:background.red,green:background.green,blue:background.blue,alpha:1)
        label.textColor = (background.whiteForeground ? UIColor.white : .black).withAlphaComponent(0.75)
        #endif
        isHidden = false
        confirmIfReady(tab)
        watchReadiness(tab)
    }
    func layoutDidSettle(_ tab: BrowserTab) {
        waitingForLayout = false
        confirmIfReady(tab)
    }
    private func watchReadiness(_ tab:BrowserTab) {
        guard !ready else { return }
        let token = generation
        withObservationTracking {
            _ = tab.hasRenderedContent; _ = tab.isRestoringWebView; _ = tab.documentRevision
        } onChange: { [weak self,weak tab] in
            Task { @MainActor in
                guard let self, let tab, self.generation == token, self.tabID == tab.id else { return }
                self.confirmIfReady(tab); self.watchReadiness(tab)
            }
        }
    }
    func confirmIfReady(_ tab: BrowserTab) {
        guard !ready, !waitingForLayout, tabID == tab.id, tab.isInstantiated, let webView, tab.webView === webView else { return }
        allowsPageInput = tab.hasRenderedContent && !tab.isRestoringWebView
        #if os(iOS)
        isUserInteractionEnabled = !allowsPageInput
        #endif
        guard webView.window != nil else { return }
        if paintRevision != tab.documentRevision {
            confirming = false; renderAttempts = 0; paintRevision = tab.documentRevision
        }
        guard tab.hasRenderedContent, !tab.isRestoringWebView, !confirming, renderAttempts < 3,
              webView.bounds.width > 0, webView.bounds.height > 0 else { return }
        confirming = true; renderAttempts += 1
        let token = generation, revision = tab.documentRevision
        #if os(macOS)
        let viewport = webView.bounds, frame = webView.frame
        let insets = webView.obscuredContentInsets
        #endif
        let config = WKSnapshotConfiguration(); config.snapshotWidth = 8; config.afterScreenUpdates = true
        webView.takeSnapshot(with:config) { [weak self,weak tab,weak webView] image,_ in
            guard let self, let tab, let webView, self.webView === webView, self.generation == token,
                  tab.isInstantiated, tab.webView === webView,
                  tab.documentRevision == revision else { return }
            self.confirming = false
            #if os(macOS)
            guard webView.bounds == viewport, webView.frame == frame,
                  webView.obscuredContentInsets.top == insets.top,
                  webView.obscuredContentInsets.left == insets.left,
                  webView.obscuredContentInsets.bottom == insets.bottom,
                  webView.obscuredContentInsets.right == insets.right else {
                // A successful paint for the old size cannot reveal a newly
                // resized view. Layout owns the geometry; confirm it again.
                self.renderAttempts = 0
                self.confirmIfReady(tab)
                return
            }
            #endif
            guard image != nil else {
                // A transient snapshot error must not strand an otherwise
                // painted tab behind its cover. No idle polling or force reveal.
                Task { @MainActor [weak self,weak tab] in
                    try? await Task.sleep(for:.milliseconds(50))
                    guard let self, let tab, self.generation == token, tab.documentRevision == revision else { return }
                    self.confirmIfReady(tab)
                }
                return
            }
            guard tab.hasRenderedContent, !tab.isRestoringWebView else { return }
            self.ready = true
            #if os(iOS)
            self.isUserInteractionEnabled = false
            #endif
            #if os(macOS)
            // The public rendering barrier has painted this exact viewport.
            // An instant swap has no inherited SwiftUI or layer animation.
            self.clear()
            #else
            if self.reduceMotion { self.clear(); return }
            UIView.animate(withDuration:0.1,delay:0,options:[.beginFromCurrentState,.curveEaseOut]) { self.alpha = 0 } completion: { [weak self] _ in
                if self?.generation == token { self?.clear() }
            }
            #endif
        }
    }
    func cancel() {
        generation += 1; ready = true; confirming = false
        clear(); presentedTab = nil; webView = nil
    }
    private func clear() {
        #if os(macOS)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        #endif
        isHidden = true; imageView.image = nil
        if presentedTab?.switchPresentation === self { presentedTab?.switchPresentation = nil }
    }
    #if os(macOS)
    override func hitTest(_ point:NSPoint) -> NSView? { allowsPageInput ? nil : super.hitTest(point) }
    override func layout() { super.layout(); layoutCover() }
    #else
    override func layoutSubviews() { super.layoutSubviews(); layoutCover() }
    #endif
    private func layoutCover() {
        #if os(macOS)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        #endif
        imageView.frame = bounds
        label.frame = CGRect(x:16,y:bounds.midY-16,width:max(0,bounds.width-32),height:32)
    }
}
