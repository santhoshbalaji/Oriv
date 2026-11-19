import XCTest
import SwiftUI
import WebKit
import BrowserCore
import BrowserEngine
@testable import OrivMobile

/// Presentation samples are scheduling/geometry evidence, not a claim about
/// physical display cadence. Pixel sampling runs separately from timing.
@MainActor final class GridMorphTests: XCTestCase {
    func testMeasureOneTab() async throws { try await measure(count:1,privateTab:false) }
    func testMeasureTenTabs() async throws { try await measure(count:10,privateTab:false) }
    func testMeasureThirtyTabs() async throws { try await measure(count:30,privateTab:false) }
    func testMeasureOnePrivateTab() async throws { try await measure(count:1,privateTab:true) }
    func testMeasureTenTabsWithPrivateSelection() async throws { try await measure(count:10,privateTab:true) }
    func testMeasureThirtyTabsWithPrivateSelection() async throws { try await measure(count:30,privateTab:true) }
    func testPixelsOneTab() async throws { try await measure(count:1,privateTab:false,raster:true) }
    func testPixelsTenTabs() async throws { try await measure(count:10,privateTab:false,raster:true) }
    func testPixelsThirtyTabs() async throws { try await measure(count:30,privateTab:false,raster:true) }
    func testPixelsPrivateTab() async throws { try await measure(count:1,privateTab:true,raster:true) }

    func testButtonAndCapsuleEntryMatchAtSampledProgress() async throws {
        for threshold in [0.1,0.3,0.5,0.7,0.9] as [CGFloat] {
            let button = try MorphFixture(count:1,privateTab:false); defer { button.dispose() }
            try await button.ready()
            let sampling = UIUpdateLink(view: button.window)
            var stopped = false
            sampling.addAction(to: .afterCATransactionCommit) { sampling, _ in
                guard !stopped, let rect = button.source.webView.superview?.frame,
                      let card = button.controller.tabPresentation.cardFrames[button.source.id] else { return }
                let travel = button.window.bounds.width - card.width
                guard travel > 0 else { return }
                let p = (button.window.bounds.width - rect.width) / travel
                if p >= threshold {
                    sampling.isEnabled = false
                    stopped = true
                    button.controller.gridMorph.pause(at:p)
                }
            }
            sampling.requiresContinuousUpdates = true
            sampling.isEnabled = true
            defer { sampling.isEnabled = false }
            button.controller.sheet = .tabs
            try await button.wait(label:"button frame sample at \(threshold)") { stopped }
            try await Task.sleep(for:.milliseconds(40))
            let buttonClip = try XCTUnwrap(button.source.webView.superview)
            let a = buttonClip.convert(buttonClip.bounds,to:button.window)
            let card = try XCTUnwrap(button.controller.tabPresentation.cardFrames[button.source.id])
            let progress = (button.window.bounds.width-a.width)/(button.window.bounds.width-card.width)
            XCTAssertGreaterThanOrEqual(progress,threshold-0.01)
            XCTAssertLessThan(progress,min(1.01,threshold+0.2),"A timed entry must contain intermediate frames")
            try await Task.sleep(for:.milliseconds(40))
            let color = button.controller.topChrome.presentationColor
            let before = raster(button.window)
            let first = XCTAttachment(image:before); first.name = "entry-button-\(threshold)"; first.lifetime = .keepAlways; add(first)
            button.controller.sheet = nil
            try await button.wait(label:"button cleanup closes") { button.controller.tabPresentation.activeID == nil && !button.controller.gridMorph.isAnimating }
            try await assertPageInput(button)
            let swipe = button
            let pan = try XCTUnwrap(descendants(swipe.window).compactMap { $0 as? MobileCapsulePan.Host }.first { $0.bounds.width > 100 && $0.window === swipe.window })
            XCTAssertTrue(pan.acceptsInput)
            pan.action?(.began,.zero,.zero)
            pan.action?(.changed,CGSize(width:0,height:-320*progress),.zero)
            try await swipe.wait(label:"capsule changes live geometry") { (swipe.source.webView.superview?.frame.width ?? swipe.window.bounds.width) < swipe.window.bounds.width-10 }
            try await Task.sleep(for:.milliseconds(80))
            let swipeClip = try XCTUnwrap(swipe.source.webView.superview)
            let b = swipeClip.convert(swipeClip.bounds,to:swipe.window)
            for (x,y) in zip([a.minX,a.minY,a.width,a.height],[b.minX,b.minY,b.width,b.height]) {
                XCTAssertEqual(x,y,accuracy:1,"Button/finger geometry at p=\(progress)")
            }
            XCTAssertLessThan(color.deltaE(swipe.controller.topChrome.presentationColor),3,"Safe-area fill must follow the same p")
            let after = raster(swipe.window)
            let second = XCTAttachment(image:after); second.name = "entry-swipe-\(threshold)"; second.lifetime = .keepAlways; add(second)
            let error = try rasterDifference(before,after,excludingTop:70,bottom:90)
            XCTAssertLessThan(error,5,"Mean pixel difference at p=\(progress), RGB scale 0...255")
            let witness = XCTAttachment(data:try JSONSerialization.data(withJSONObject:["threshold":threshold,"progress":progress,"button":[a.minX,a.minY,a.width,a.height],"swipe":[b.minX,b.minY,b.width,b.height],"meanPixelDifference":error]),uniformTypeIdentifier:"public.json")
            witness.name = "entry-parity-\(threshold)"; witness.lifetime = .keepAlways; add(witness)
            pan.action?(.cancelled,.zero,.zero)
            try await swipe.wait { swipe.controller.tabPresentation.activeID == nil }
        }
    }
    func testReleaseClockMatchesTheInstalledNativeHostSpring() async throws {
        let f = try MorphFixture(count:1,privateTab:false); defer { f.dispose() }
        try await f.ready()
        let reference = MobileWebHost(webView:WKWebView())
        // A separate blank reference host exercises the untouched 0.12.4
        // property animator, independently of the timed progress renderer.
        reference.frame = f.window.bounds; f.window.addSubview(reference); reference.layoutIfNeeded()
        defer { reference.removeFromSuperview() }
        let card = CGRect(x:16,y:128,width:177,height:251)
        let frames = MorphFrames(f); var errors:[CGFloat] = []; var samples:[[String:Any]] = []
        frames.onFrame = {
            guard let rect = reference.webView.superview?.layer.presentation()?.frame else { return }
            let expected = MobileGridMorph.frame(full:f.window.bounds,card:card,progress:f.controller.gridMorph.progress)
            let error = zip([rect.minX,rect.minY,rect.width,rect.height],[expected.minX,expected.minY,expected.width,expected.height]).map { abs($0-$1) }.max() ?? 0
            errors.append(error); samples.append(["progress":f.controller.gridMorph.progress,"error":error,"native":[rect.minX,rect.minY,rect.width,rect.height]])
        }
        frames.start(); defer { frames.stop() }
        reference.applyMorph(progress:0.5,card:card,animated:false)
        reference.applyMorph(progress:1,card:card,animated:true)
        var finished = false
        f.controller.gridMorph.animate(from:0.5,to:1,reduceMotion:false,tabID:f.source.id,update:{ _ in }) { finished = true }
        try await f.wait { finished }; frames.stop()
        XCTAssertGreaterThan(errors.count,10)
        // UIUpdateInfo.modelTime precedes the display-link presentation probe.
        // Bound that phase/overshoot difference as well as the average error.
        let rms = sqrt(errors.reduce(0) { $0+$1*$1 }/CGFloat(max(1,errors.count)))
        XCTAssertLessThan(rms,3,"Release RMS error against the installed native spring")
        XCTAssertLessThan(errors.max() ?? .infinity,5,"Release phase/overshoot error must stay below 0.81% of the fixture's height travel")
        let witness = XCTAttachment(data:try JSONSerialization.data(withJSONObject:samples),uniformTypeIdentifier:"public.json")
        witness.name = "installed-native-release-comparison"; witness.lifetime = .keepAlways; add(witness)
    }
    func testCapsuleCommitAndCancelUseTheSharedReleaseClock() async throws {
        let f = try MorphFixture(count:1,privateTab:false); defer { f.dispose() }
        try await f.ready()
        let pan = try XCTUnwrap(descendants(f.window).compactMap { $0 as? MobileCapsulePan.Host }.first { $0.bounds.width > 100 })
        pan.action?(.began,.zero,.zero)
        pan.action?(.changed,CGSize(width:0,height:-160),.zero)
        try await f.wait { f.controller.gridMorph.progress > 0.4 }
        pan.action?(.ended,CGSize(width:0,height:-160),CGSize(width:0,height:-250))
        try await f.wait { f.controller.gridMorph.isAnimating && f.controller.sheet == .tabs }
        try await f.wait { !f.controller.gridMorph.isAnimating && f.controller.tabPresentation.activeID == nil }
        XCTAssertEqual(f.controller.gridMorph.progress,1)
        f.controller.sheet = nil
        try await f.wait { f.controller.gridMorph.isAnimating }
        try await f.wait { !f.controller.gridMorph.isAnimating && f.controller.tabPresentation.activeID == nil }
        pan.action?(.began,.zero,.zero)
        pan.action?(.changed,CGSize(width:0,height:-30),.zero)
        pan.action?(.ended,CGSize(width:0,height:-30),CGSize(width:0,height:-40))
        try await f.wait { f.controller.gridMorph.isAnimating }
        try await f.wait { !f.controller.gridMorph.isAnimating && f.controller.tabPresentation.activeID == nil }
        XCTAssertNil(f.controller.sheet); XCTAssertEqual(f.controller.gridMorph.progress,0)
        try await assertPageInput(f)
    }

    private func raster(_ window:UIWindow) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(bounds:window.bounds,format:format).image { _ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true) }
    }
    private func rasterDifference(_ a:UIImage,_ b:UIImage,excludingTop top:Int,bottom:Int) throws -> Double {
        let first = try XCTUnwrap(a.cgImage), second = try XCTUnwrap(b.cgImage)
        XCTAssertEqual(first.width,second.width); XCTAssertEqual(first.height,second.height)
        let width = first.width,height = first.height
        func bytes(_ image:CGImage) throws -> [UInt8] {
            var output = [UInt8](repeating:0,count:width*height*4)
            let context = try XCTUnwrap(CGContext(data:&output,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image,in:CGRect(x:0,y:0,width:width,height:height)); return output
        }
        let x = try bytes(first),y = try bytes(second)
        var error = 0, samples = 0
        for row in top..<(height-bottom) { for column in 0..<width { for channel in 0..<3 {
            let index = (row*width+column)*4+channel
            error += abs(Int(x[index])-Int(y[index])); samples += 1
        } } }
        return Double(error)/Double(samples)
    }

    func testChromeLookupAfterHostTeardownDoesNotRecreateOrReconnectWebKit() async throws {
        let f = try MorphFixture(count:1,privateTab:false); defer { f.dispose() }
        try await f.ready()
        let chrome = f.controller.chrome(for:f.source)
        f.window.isHidden = true; f.window.rootViewController = nil
        f.controller.session.shutdown()
        for _ in 0..<10 { XCTAssertTrue(f.controller.chrome(for:f.source) === chrome) }
        try await Task.sleep(for:.milliseconds(150))
        XCTAssertFalse(f.source.isInstantiated,"A colour lookup during hosting teardown must not resurrect WebKit")
    }

    func testGridAnimationUsesTheInteractiveHostWithoutAnIndependentAnimator() async throws {
        let f = try MorphFixture(count:10,privateTab:false); defer { f.dispose() }
        try await f.ready()
        let host = try XCTUnwrap(f.source.webView.superview?.superview?.superview as? MobileWebHost)
        f.controller.sheet = .tabs
        try await f.wait { f.controller.gridMorph.isAnimating }
        for _ in 0..<12 {
            XCTAssertFalse(host.isMorphAnimating,"The progress clock must supply interactive geometry, never start another spring")
            XCTAssertTrue(f.source.webView.superview?.superview?.superview === host)
            try await Task.sleep(for:.milliseconds(15))
        }
        try await f.wait { f.controller.tabPresentation.activeID == nil }
    }

    func testInterruptingMorphHoldsTheDisplayedSafeAreaColour() async throws {
        let f = try MorphFixture(count:1,privateTab:false); defer { f.dispose() }
        try await f.ready()
        f.controller.sheet = .tabs
        try await f.wait { f.controller.gridMorph.isAnimating }
        try await Task.sleep(for:.milliseconds(80))
        let before = f.controller.topChrome.presentationColor
        XCTAssertGreaterThan(before.deltaE(ChromeColor(0,0,0)),5)
        f.controller.gridMorph.pause()
        XCTAssertLessThan(f.controller.topChrome.presentationColor.deltaE(before),3,"Stopping the spring must preserve its displayed fill, not reveal its model endpoint")
        f.controller.sheet = nil
        try await f.wait { f.controller.tabPresentation.activeID == nil && f.controller.sheet == nil }
        try await assertPageInput(f)
    }

    func testInterruptedProgressClockRejectsOldFramesAndCompletion() async throws {
        let f = try MorphFixture(count:1,privateTab:false); defer { f.dispose() }
        try await f.ready()
        let clock = f.controller.gridMorph; var samples:[CGFloat] = [], oldCompletion = false, newCompletion = false
        clock.animate(from:0,to:1,reduceMotion:false,tabID:f.source.id,
            update:{ samples.append($0) }) { oldCompletion = true }
        try await f.wait { samples.count > 3 }
        clock.pause(); let count = samples.count
        try await Task.sleep(for:.milliseconds(80))
        XCTAssertEqual(samples.count,count); XCTAssertFalse(oldCompletion)
        clock.animate(from:clock.progress,to:0,reduceMotion:false,tabID:f.source.id,
            update:{ samples.append($0) }) { newCompletion = true }
        try await f.wait { newCompletion }
        XCTAssertFalse(oldCompletion); XCTAssertEqual(samples.last,0)
        XCTAssertFalse(clock.isAnimating)
    }

    func testImmediateCloseCancelsPendingButtonEntry() async throws {
        let f = try MorphFixture(count:1,privateTab:false); defer { f.dispose() }
        try await f.ready()
        f.controller.sheet = .tabs
        try await f.wait { f.controller.gridMorph.isAnimating }
        f.controller.sheet = nil
        try await f.wait { f.controller.sheet == nil && f.controller.tabPresentation.activeID == nil && !f.controller.gridMorph.isAnimating }
        try await Task.sleep(for:.milliseconds(500))
        XCTAssertNil(f.controller.sheet); XCTAssertEqual(f.controller.gridMorph.progress,0)
        try await assertPageInput(f)
    }

    func testInterruptedOpenThenCloseRejectsOldCompletion() async throws {
        let f = try MorphFixture(count:10,privateTab:false); defer { f.dispose() }
        try await f.ready()
        f.controller.sheet = .tabs
        try await f.wait { f.controller.gridMorph.isAnimating }
        try await Task.sleep(for:.milliseconds(80))
        f.controller.sheet = nil
        try await f.wait { !f.controller.gridMorph.isAnimating && f.controller.tabPresentation.activeID == nil && f.controller.sheet == nil }
        try await Task.sleep(for:.milliseconds(500))
        XCTAssertNil(f.controller.sheet); XCTAssertNil(f.controller.tabPresentation.activeID)
        XCTAssertEqual(f.controller.gridMorph.progress,0)
        try await assertPageInput(f)
    }
    func testCloseThenQuickReopenKeepsGridAndRejectsStalePaint() async throws {
        let f = try MorphFixture(count:10,privateTab:false); defer { f.dispose() }
        try await f.ready(); try await open(f)
        f.controller.sheet = nil
        try await f.wait { f.controller.gridMorph.isAnimating }
        try await Task.sleep(for:.milliseconds(70))
        f.controller.sheet = .tabs
        try await f.wait { !f.controller.gridMorph.isAnimating && f.controller.tabPresentation.activeID == nil }
        try await Task.sleep(for:.milliseconds(500))
        XCTAssertEqual(f.controller.sheet,.tabs)
        XCTAssertEqual(f.controller.gridMorph.progress,1)
        XCTAssertEqual(f.source.webView.transform,.identity)
        f.controller.sheet = nil
        try await f.wait { f.controller.gridMorph.isAnimating }
        try await f.wait { !f.controller.gridMorph.isAnimating && f.controller.tabPresentation.activeID == nil && f.controller.sheet == nil }
        try await assertPageInput(f)
    }
    func testTapCardDuringOpeningSelectsDestinationExactlyOnce() async throws {
        let f = try MorphFixture(count:10,privateTab:false); defer { f.dispose() }
        try await f.ready()
        let host = f.source.webView.superview, viewport = f.source.webView.bounds
        f.controller.sheet = .tabs
        try await f.wait { f.controller.gridMorph.isAnimating }
        try await Task.sleep(for:.milliseconds(60))
        let frames = MorphFrames(f); frames.start(); defer { frames.stop() }
        let cell = try XCTUnwrap(descendants(f.window).compactMap { $0 as? MobileTabCell }.first { $0.representedTabID == f.destination.id })
        XCTAssertTrue(cell.accessibilityActivate(),"An opening grid must accept a card tap")
        try await f.wait { f.controller.session.selectedTabID == f.destination.id && f.controller.sheet == nil && f.controller.tabPresentation.activeID == nil && !f.controller.gridMorph.isAnimating }
        try await Task.sleep(for:.milliseconds(450))
        XCTAssertEqual(f.controller.session.selectedTabID,f.destination.id)
        frames.stop()
        let lastOutgoing = frames.rows.last { $0["selected"] as? String == f.source.id.uuidString && $0["active"] as? String == f.source.id.uuidString }
        if let rect = lastOutgoing?["clip"] as? [CGFloat], let card = f.controller.tabPresentation.cardFrames[f.source.id] {
            XCTAssertLessThanOrEqual(rect[2],card.width+30,"A tap must settle the outgoing image to its card before replacing it")
        } else { XCTFail("Missing outgoing presentation witness") }
        XCTAssertTrue(f.source.webView.superview === host)
        XCTAssertEqual(f.source.webView.bounds,viewport)
        try await assertPageInput(f)
    }
    func testClosedTabDuringOpeningCannotSurviveInMorphOrCache() async throws {
        let f = try MorphFixture(count:10,privateTab:false); defer { f.dispose() }
        try await f.ready()
        f.controller.sheet = .tabs
        try await f.wait { f.controller.gridMorph.isAnimating }
        f.controller.close([f.source.id])
        try await Task.sleep(for:.milliseconds(850))
        XCTAssertFalse(f.controller.session.tabs.contains { $0.id == f.source.id })
        XCTAssertNil(f.controller.tabPresentation.images[f.source.id])
        XCTAssertNil(f.controller.tabPresentation.activeID)
        XCTAssertFalse(f.controller.gridMorph.isAnimating)
        XCTAssertFalse(f.source.isInstantiated)
    }
    func testPrivateMorphAndConfirmationKeepPrivateImageMemoryOnly() async throws {
        let f = try MorphFixture(count:10,privateTab:true); defer { f.dispose() }
        try await f.ready(); try await open(f)
        f.controller.sheet = nil
        try await f.wait { f.controller.gridMorph.isAnimating }
        f.controller.sheet = .tabs
        try await f.wait { !f.controller.gridMorph.isAnimating && f.controller.tabPresentation.activeID == nil }
        XCTAssertTrue(f.controller.session.selectedTab?.isPrivate == true)
        for confirm in [false,true] {
            f.window.makeKeyAndVisible()
            try await f.wait { MobileWebDelegate.presenter === f.window.rootViewController && f.window.windowScene?.activationState == .foregroundActive }
            f.controller.close([f.source.id])
            let alert = try XCTUnwrap(f.controller.closeConfirmation,"confirm=\(confirm), key=\(f.window.isKeyWindow), presenter=\(String(describing:MobileWebDelegate.presenter))")
            XCTAssertTrue(f.controller.session.tabs.contains { $0.id == f.source.id })
            f.controller.resolveTabClose(confirm:confirm); alert.dismiss(animated:false)
            try await Task.sleep(for:.milliseconds(500))
            XCTAssertEqual(f.controller.session.tabs.contains { $0.id == f.source.id },!confirm)
        }
        XCTAssertNil(f.controller.tabPresentation.images[f.source.id])
        XCTAssertFalse(f.controller.session.recentlyClosedTabs.contains { $0.url == f.source.url })
        XCTAssertFalse(f.controller.gridMorph.isAnimating)
    }
    func testReduceMotionUsesCrossfadeWithoutSnapshotOrWebTransform() async throws {
        let f = try MorphFixture(count:1,privateTab:false,reduce:true); defer { f.dispose() }
        try await f.ready()
        f.controller.sheet = .tabs
        try await f.wait { f.controller.gridMorph.isAnimating }
        XCTAssertEqual(f.source.webView.superview?.frame,f.window.bounds)
        XCTAssertEqual(f.source.webView.transform,.identity)
        try await f.wait { f.controller.tabPresentation.activeID == nil }
        f.controller.sheet = nil
        try await f.wait { f.controller.gridMorph.isAnimating }
        XCTAssertEqual(f.source.webView.superview?.frame,f.window.bounds)
        try await f.wait { !f.controller.gridMorph.isAnimating && f.controller.tabPresentation.activeID == nil }
        try await assertPageInput(f)
    }
    func testPinchingAnotherCardUsesItsRetainedImageBeforeSelection() async throws {
        let f = try MorphFixture(count:10,privateTab:false); defer { f.dispose() }
        try await f.ready(); try await open(f)
        let cell = try XCTUnwrap(descendants(f.window).compactMap { $0 as? MobileTabCell }.first { $0.representedTabID == f.destination.id })
        cell.pinchProgress?(0.4,false)
        try await f.wait { f.controller.tabPresentation.activeID == f.destination.id }
        try await Task.sleep(for:.milliseconds(100))
        let rect = MobileGridMorph.frame(full:f.window.bounds,card:try XCTUnwrap(f.controller.tabPresentation.cardFrames[f.destination.id]),progress:0.6)
        let point = CGPoint(x:rect.midX,y:rect.maxY-20)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(bounds:f.window.bounds,format:format).image { _ in f.window.drawHierarchy(in:f.window.bounds,afterScreenUpdates:false) }
        let pixel = try XCTUnwrap(image.cgImage?.cropping(to:CGRect(origin:point,size:CGSize(width:1,height:1))))
        var bytes = [UInt8](repeating:0,count:4)
        let context = try XCTUnwrap(CGContext(data:&bytes,width:1,height:1,bitsPerComponent:8,bytesPerRow:4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(pixel,in:CGRect(x:0,y:0,width:1,height:1))
        XCTAssertLessThan(bytes[1],80,"The purple destination must not show the selected white page")
        XCTAssertGreaterThan(bytes[2],150)
        XCTAssertEqual(f.controller.session.selectedTabID,f.source.id)
        cell.pinchProgress?(0,true)
        try await f.wait { !f.controller.gridMorph.isAnimating && f.controller.tabPresentation.activeID == nil }
        XCTAssertEqual(f.controller.sheet,.tabs)
        XCTAssertNotNil(f.controller.tabPresentation.images[f.destination.id])
    }
    private func open(_ f:MorphFixture) async throws {
        f.controller.sheet = .tabs
        try await f.wait { f.controller.gridMorph.isAnimating }
        try await f.wait { !f.controller.gridMorph.isAnimating && f.controller.tabPresentation.activeID == nil }
    }
    private func assertPageInput(_ f:MorphFixture,file:StaticString = #filePath,line:UInt = #line) async throws {
        try await f.wait {
            guard let web = f.controller.session.selectedTab?.webView else { return false }
            return f.window.hitTest(CGPoint(x:f.window.bounds.midX,y:f.window.bounds.midY),with:nil)?.isDescendant(of:web) == true
        }
        guard let web = f.controller.session.selectedTab?.webView else { XCTFail("Missing live page",file:file,line:line); return }
        XCTAssertTrue(f.window.hitTest(CGPoint(x:f.window.bounds.midX,y:f.window.bounds.midY),with:nil)?.isDescendant(of:web) == true,"The live page must receive input after the grid leaves",file:file,line:line)
    }
    private func descendants(_ view:UIView) -> [UIView] { view.subviews.flatMap { [$0]+descendants($0) } }

    private func measure(count:Int,privateTab:Bool,raster:Bool = false) async throws {
        let f = try MorphFixture(count:count,privateTab:privateTab)
        defer { f.dispose() }
        try await f.ready()
        let frames = MorphFrames(f,raster:raster)
        frames.start(); defer { frames.stop() }
        try await Task.sleep(for:.milliseconds(50))
        for iteration in 0..<(raster ? 1 : 3) {
            frames.phase = "open-\(iteration)"; f.controller.sheet = .tabs
            try await f.wait { f.controller.tabPresentation.activeID != nil }
            try await f.wait { f.controller.tabPresentation.activeID == nil && f.controller.sheet == .tabs }
            try await Task.sleep(for:.milliseconds(120))
            frames.phase = "close-\(iteration)"; f.controller.sheet = nil
            try await f.wait { f.controller.tabPresentation.activeID != nil }
            try await f.wait { f.controller.sheet == nil && f.controller.tabPresentation.activeID == nil }
            try await Task.sleep(for:.milliseconds(120))
            frames.phase = "open-for-tap-\(iteration)"; f.controller.sheet = .tabs
            try await f.wait { f.controller.tabPresentation.activeID != nil }
            try await f.wait { f.controller.tabPresentation.activeID == nil && f.controller.sheet == .tabs }
            try await Task.sleep(for:.milliseconds(120))
            let target = f.controller.session.selectedTabID == f.source.id ? f.destination : f.source
            frames.phase = "tap-to-open-\(iteration)"
            f.controller.tabPresentation.pendingSelection = target.id; f.controller.sheet = nil
            try await f.wait { f.controller.tabPresentation.activeID != nil }
            try await f.wait { f.controller.session.selectedTabID == target.id && f.controller.tabPresentation.activeID == nil }
            try await Task.sleep(for:.milliseconds(200))
        }
        frames.stop()
        XCTAssertGreaterThan(frames.rows.count,raster ? 25 : 100)
        XCTAssertLessThanOrEqual(f.controller.tabPresentation.snapshotBytes,24*1_024*1_024)
        XCTAssertLessThanOrEqual(f.controller.tabPresentation.images.count,12)
        let data = try JSONSerialization.data(withJSONObject:["count":count,"private":privateTab,"raster":frames.raster,"maximumFPS":f.window.screen.maximumFramesPerSecond,"rows":frames.rows],options:[.sortedKeys])
        let a = XCTAttachment(data:data,uniformTypeIdentifier:"public.json")
        a.name = "grid-morph-\(count)-\(privateTab ? "private" : "normal")-frames"; a.lifetime = .keepAlways; add(a)
        for (name,image) in frames.images {
            let a = XCTAttachment(image:image); a.name = name; a.lifetime = .keepAlways; add(a)
        }
    }
}

@MainActor private final class MorphFixture {
    let profiles = MobileProfiles()
    var controller:MobileController { profiles.current }
    let source:BrowserTab
    let destination:BrowserTab
    let window:UIWindow
    private weak var previous:UIWindow?
    private var disposed = false
    init(count:Int,privateTab:Bool,reduce:Bool = false) throws {
        let c = profiles.current
        let initial = try XCTUnwrap(c.session.selectedTab)
        if privateTab {
            source = c.session.addTab(isPrivate:true,load:false)
            c.session.closeTab(initial.id)
        } else { source = initial }
        for _ in 1..<count { _ = c.session.addTab(isPrivate:privateTab,select:false,load:false) }
        let sourceID = source.id
        if count > 1 {
            destination = c.session.tabs.first { $0.id != sourceID }!
        } else { destination = source }
        c.session.selectTab(source.id)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        window = UIWindow(windowScene:scene); previous = scene.keyWindow
        window.rootViewController = UIHostingController(rootView:MobileBrowserView(controller:c,profiles:profiles,reduceMotionOverride:reduce)
            .browserAppearance(c.appearance,followsPage:true).environment(\.scenePhase,.active))
        window.makeKeyAndVisible()
    }
    func ready() async throws {
        // Prepare each snapshot while its tab is mounted. iOS 27 can suspend
        // an unattached WebKit view before the fixture or snapshot completes.
        try await prepare(source, path: "two")
        if destination !== source {
            try await prepare(destination, path: "chrome-paint")
            controller.session.selectTab(source.id)
            try await wait(label: "source reattached") { self.source.webView.window === self.window }
        }
        try await wait(label: "prepared native grid and live browser geometry") {
            guard let root = window.rootViewController, let grid = preparedGrid(in: root) else { return false }
            return grid.navigationController != nil && grid.isViewLoaded
                && source.hasRenderedContent && !source.webView.bounds.isEmpty
        }
    }
    private func preparedGrid(in parent: UIViewController) -> MobileTabGridController? {
        if let grid = parent as? MobileTabGridController { return grid }
        return parent.children.lazy.compactMap { self.preparedGrid(in: $0) }.first
    }
    private func prepare(_ tab: BrowserTab, path: String) async throws {
        controller.session.selectTab(tab.id)
        tab.navigate(to: URL(string: "http://127.0.0.1:8768/\(path)")!)
        try await wait(label: "\(path) loaded and attached", timeout: 30) {
            !tab.isLoading && tab.hasLoaded && tab.webView.window === self.window
        }
        controller.tabPresentation.capture(tab, refresh: true)
        try await wait(label: "\(path) snapshot") { self.controller.tabPresentation.images[tab.id] != nil }
    }
    func wait(label:String = "",timeout: TimeInterval = 12,_ predicate:() -> Bool) async throws {
        let deadline = CACurrentMediaTime() + timeout
        while !predicate() {
            if CACurrentMediaTime()>deadline {
                XCTFail("Timed out waiting for \(label), sheet=\(String(describing: controller.sheet)), progress=\(controller.gridMorph.progress)")
                throw MorphTimeout(condition: label, sheet: String(describing: controller.sheet),
                    nativeProgress: controller.gridMorph.progress)
            }
            try await Task.sleep(for:.milliseconds(10))
        }
    }
    func dispose() {
        guard !disposed else { return }; disposed = true
        controller.sheet = nil; controller.tabPresentation.finish()
        window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
        controller.session.shutdown(); profiles.continuity.shutdown()
    }
}
private struct MorphTimeout: Error {
    let condition: String
    let sheet: String
    let nativeProgress: CGFloat
}

@MainActor private final class MorphFrames:NSObject {
    let fixture:MorphFixture
    var phase = "ready"
    var rows:[[String:Any]] = []
    var images:[(String,UIImage)] = []
    let raster:Bool
    private var link:CADisplayLink?
    var onFrame:(() -> Void)?
    private var phaseFrames = 0
    private var lastPhase = ""
    init(_ fixture:MorphFixture,raster:Bool = false) { self.fixture = fixture; self.raster = raster }
    func start() {
        let link = CADisplayLink(target:self,selector:#selector(frame(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum:60,maximum:120,preferred:120)
        self.link = link; link.add(to:.main,forMode:.common)
    }
    func stop() { link?.invalidate(); link = nil }
    @objc private func frame(_ link:CADisplayLink) {
        onFrame?()
        if phase != lastPhase { lastPhase = phase; phaseFrames = 0 }
        phaseFrames += 1
        let c = fixture.controller, tab = c.session.selectedTab
        var row:[String:Any] = ["time":link.timestamp,"callback":CACurrentMediaTime(),"phase":phase,"frame":phaseFrames,
            "selected":tab?.id.uuidString ?? "","active":c.tabPresentation.activeID?.uuidString ?? "","grid":c.sheet == .tabs,
            "snapshots":c.tabPresentation.images.count,"bytes":c.tabPresentation.snapshotBytes]
        #if DEBUG
        row["interpolations"] = MobileTransitionMetrics.gridInterpolations
        row["layouts"] = MobileTransitionMetrics.gridLayouts
        row["webUpdates"] = MobileTransitionMetrics.webMorphUpdates
        row["driverProgress"] = c.gridMorph.progress
        row["driverAnimating"] = c.gridMorph.isAnimating
        #endif
        if let tab,tab.isInstantiated {
            let web = tab.webView
            let clip = web.superview
            let p = clip?.layer.presentation() ?? clip?.layer
            row["clip"] = p.map { [$0.frame.minX,$0.frame.minY,$0.frame.width,$0.frame.height] } ?? []
            row["webScale"] = web.layer.presentation()?.affineTransform().a ?? web.transform.a
            row["viewport"] = [web.bounds.width,web.bounds.height]
            row["attached"] = web.window === fixture.window
        }
        let cells = descendants(fixture.window).compactMap { $0 as? MobileTabCell }.filter { $0.window != nil && !$0.isHidden }
        row["cells"] = cells.compactMap { $0.representedTabID?.uuidString }
        if raster && [1,3,6,10,16,24,36].contains(phaseFrames) {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
            let image = UIGraphicsImageRenderer(bounds:fixture.window.bounds,format:format).image { _ in fixture.window.drawHierarchy(in:fixture.window.bounds,afterScreenUpdates:false) }
            images.append(("morph-\(phase)-\(phaseFrames)",image))
        }
        rows.append(row)
    }
    private func descendants(_ view:UIView) -> [UIView] { view.subviews.flatMap { [$0]+descendants($0) } }
}
