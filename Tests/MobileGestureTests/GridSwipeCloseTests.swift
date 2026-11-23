import XCTest
import SwiftUI
import BrowserCore
import BrowserEngine
@testable import OrivMobile

/// Native presentation-layer samples. These exercise the real collection and
/// close policy; they do not claim to measure physical touch-delivery latency.
@MainActor final class GridSwipeCloseTests: XCTestCase {
    private func number(_ value:Any?) -> Double {
        if let value = value as? Double { return value }
        if let value = value as? CGFloat { return Double(value) }
        if let value = value as? Float { return Double(value) }
        return .nan
    }
    private var baseline: Bool { ProcessInfo.processInfo.environment["ORIV_GRID_BASELINE"] == "1" }
    func testDistanceExitAndReflowFrames() async throws { try await exercise(name:"distance",travel:100,velocity:0,commit:true) }
    func testVelocityExitAndReflowFrames() async throws { try await exercise(name:"velocity",travel:32,velocity:-1600,commit:true) }
    func testCancelFrames() async throws { try await exercise(name:"cancel",travel:32,velocity:0,commit:false) }
    func testReduceMotionFrames() async throws { try await exercise(name:"reduce-motion",travel:100,velocity:0,commit:true,reduce:true) }
    func testLastTabFrames() async throws { try await exercise(name:"last",travel:100,velocity:0,commit:true,count:1) }

    func testSwitchingModesReplacesTheVisibleCard() async throws {
        let fixture = try GridSwipeFixture(count: 1, reduce: false)
        defer { fixture.dispose() }
        try await fixture.ready()

        let grid = fixture.grid
        let privateTab = fixture.controller.session.addTab(isPrivate: true, select: false, load: false)
        let firstCard = IndexPath(item: 0, section: 0)
        var model = grid.model
        model.tabs = [privateTab]
        grid.update(model)
        grid.collectionView.layoutIfNeeded()

        let cell = try XCTUnwrap(grid.collectionView.cellForItem(at: firstCard) as? MobileTabCell)
        XCTAssertEqual(cell.representedTabID, privateTab.id)
        XCTAssertTrue(cell.accessibilityLabel?.hasPrefix("Private.") == true)
    }

    func testTerminalOnlyCommitAndRightResistance() async throws {
        let fixture = try GridSwipeFixture(count:4,reduce:false); defer { fixture.dispose() }
        try await fixture.ready()
        let cell = try XCTUnwrap(fixture.grid.collectionView.cellForItem(at:IndexPath(item:1,section:0)) as? MobileTabCell)
        let id = try XCTUnwrap(cell.representedTabID)
        let pan = GridSwipePan(); pan.phase = .began; cell.swipe(pan)
        pan.phase = .changed; pan.delta.x = 40; cell.swipe(pan)
        XCTAssertEqual(cell.swipeSurface.transform.tx,7.2,accuracy:0.01)
        pan.phase = .cancelled; cell.swipe(pan)
        try await Task.sleep(for:.milliseconds(500))
        pan.phase = .began; pan.delta = .zero; cell.swipe(pan)
        pan.phase = .ended; pan.delta.x = -100; cell.swipe(pan)
        try await Task.sleep(for:.milliseconds(950))
        XCTAssertFalse(fixture.controller.session.tabs.contains { $0.id == id })
    }
    func testOverlappingClosesAndRegrabSpring() async throws {
        let fixture = try GridSwipeFixture(count:8,reduce:false); defer { fixture.dispose() }
        try await fixture.ready()
        let a = try XCTUnwrap(fixture.grid.collectionView.cellForItem(at:IndexPath(item:1,section:0)) as? MobileTabCell)
        let b = try XCTUnwrap(fixture.grid.collectionView.cellForItem(at:IndexPath(item:2,section:0)) as? MobileTabCell)
        let ids = [try XCTUnwrap(a.representedTabID),try XCTUnwrap(b.representedTabID)]
        let pan = GridSwipePan(); pan.phase = .began; b.swipe(pan)
        pan.phase = .changed; pan.delta.x = -40; b.swipe(pan)
        pan.phase = .cancelled; b.swipe(pan)
        try await Task.sleep(for:.milliseconds(80))
        let position = try XCTUnwrap(b.swipeSurface.layer.presentation()).affineTransform().tx
        pan.phase = .began; pan.delta = .zero; b.swipe(pan)
        XCTAssertEqual(b.swipeSurface.transform.tx,position,accuracy:2,"Regrab must preserve the presented position")
        pan.phase = .changed; pan.delta.x = -110; b.swipe(pan)
        pan.phase = .ended; b.swipe(pan)
        XCTAssertTrue(b.closing)
        let other = GridSwipePan(); other.phase = .began; a.swipe(other)
        XCTAssertTrue(a.swiping,"Another card remains interactive during an exit")
        other.phase = .ended; other.delta.x = -100; a.swipe(other)
        try await Task.sleep(for:.milliseconds(1100))
        XCTAssertTrue(ids.allSatisfy { id in !fixture.controller.session.tabs.contains { $0.id == id } })
        let shown = fixture.grid.collectionView.visibleCells.compactMap { ($0 as? MobileTabCell)?.representedTabID }
        XCTAssertEqual(Set(shown).count,shown.count)
        XCTAssertFalse(shown.contains { ids.contains($0) })
    }
    func testPrivateConfirmCancelAndSectionReflowFrames() async throws {
        let fixture = try GridSwipeFixture(count:2,reduce:false); defer { fixture.dispose() }
        fixture.controller.session.addTab(isPrivate:true,select:false,load:false)
        try await fixture.ready()
        let tab = try XCTUnwrap(fixture.controller.session.tabs.first(where:\.isPrivate))
        let cell = try XCTUnwrap(fixture.grid.collectionView.cellForItem(at:IndexPath(item:0,section:1)) as? MobileTabCell)
        let frames = GridSwipeFrames(fixture:fixture,closing:cell,id:tab.id)
        frames.start(); defer { frames.stop() }
        for confirm in [false,true] {
            let pan = GridSwipePan(); pan.phase = .began; cell.swipe(pan)
            pan.phase = .changed; pan.delta.x = -110; cell.swipe(pan)
            pan.phase = .ended; cell.swipe(pan)
            try await Task.sleep(for:.milliseconds(500))
            XCTAssertTrue(fixture.controller.session.tabs.contains { $0.id == tab.id })
            let alert = try XCTUnwrap(fixture.controller.closeConfirmation)
            XCTAssertEqual(alert.title,"Close Private Tabs?")
            XCTAssertEqual(cell.swipeSurface.transform.tx,0,accuracy:0.01)
            // Same one-shot resolution as the actual alert buttons. UIKit owns
            // the button dismissal; the hosted regression dismisses explicitly.
            fixture.controller.resolveTabClose(confirm:confirm)
            alert.dismiss(animated:false)
            try await Task.sleep(for:.milliseconds(1000))
            XCTAssertEqual(fixture.controller.session.tabs.contains { $0.id == tab.id },!confirm)
        }
        XCTAssertEqual(fixture.grid.collectionView.numberOfSections,1)
        try attach(frames,name:"private-confirm-cancel-section")
    }
    func testReuseDuringCommittedExitFinishesExactlyOnce() async throws {
        let cell = MobileTabCell(frame:CGRect(x:0,y:0,width:180,height:280))
        var completions = 0
        cell.flyAway(velocity:-900) { completions += 1 }
        cell.prepareForReuse(); cell.prepareForReuse()
        try await Task.sleep(for:.milliseconds(500))
        XCTAssertEqual(completions,1)
        XCTAssertEqual(cell.swipeSurface.transform,.identity)
        XCTAssertEqual(cell.swipeSurface.alpha,1)
    }
    private func attach(_ frames:GridSwipeFrames,name:String) throws {
        let attachment = XCTAttachment(data:try JSONSerialization.data(withJSONObject:["rows":frames.rows,"exitModelMaxX":frames.exitModelMaxX as Any? ?? NSNull(),"baseline":baseline,"maximumFPS":frames.fixture.window.screen.maximumFramesPerSecond],options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
        attachment.name = "grid-swipe-\(name)-frames"; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func exercise(name:String,travel:CGFloat,velocity:CGFloat,commit:Bool,reduce:Bool = false,count:Int = 6) async throws {
        let fixture = try GridSwipeFixture(count:count,reduce:reduce)
        defer { fixture.dispose() }
        try await fixture.ready()
        let index = count > 1 ? 1 : 0 // Right column must clear the viewport too.
        let tab = fixture.controller.session.orderedTabs[index]
        let cell = try XCTUnwrap(fixture.grid.collectionView.cellForItem(at:IndexPath(item:index,section:0)) as? MobileTabCell)
        let frames = GridSwipeFrames(fixture:fixture,closing:cell,id:tab.id)
        let survivors = Set(fixture.grid.collectionView.visibleCells.compactMap { ($0 as? MobileTabCell)?.representedTabID }).subtracting([tab.id])
        frames.start(); defer { frames.stop() }
        let pan = GridSwipePan(); pan.phase = .began; cell.swipe(pan)
        for step in 1...10 {
            pan.phase = .changed; pan.delta = CGPoint(x:-travel*CGFloat(step)/10,y:0); cell.swipe(pan)
            if !reduce { XCTAssertEqual(cell.swipeSurface.transform.tx,pan.delta.x,accuracy:0.01) }
            try await Task.sleep(for:.milliseconds(17))
            if ProcessInfo.processInfo.environment["ORIV_GRID_RASTER"] == "1" && [3,6,9].contains(step) {
                let image = UIGraphicsImageRenderer(bounds:fixture.window.bounds).image { _ in fixture.window.drawHierarchy(in:fixture.window.bounds,afterScreenUpdates:false) }
                let a = XCTAttachment(image:image); a.name = "grid-swipe-\(name)-drag-\(step)"; a.lifetime = .keepAlways; add(a)
            }
        }
        frames.phase = "settle"; pan.phase = .ended; pan.speed = CGPoint(x:velocity,y:0); cell.swipe(pan)
        try await Task.sleep(for:.milliseconds(1000))
        frames.stop()
        let removed = !fixture.controller.session.tabs.contains { $0.id == tab.id }
        XCTAssertEqual(removed,commit)
        if !commit { XCTAssertEqual(cell.swipeSurface.transform.tx,0,accuracy:0.01); XCTAssertEqual(cell.swipeSurface.alpha,1,accuracy:0.01) }
        if !baseline && commit && !reduce { XCTAssertLessThanOrEqual(frames.exitModelMaxX ?? .infinity,0,"Exit endpoint must clear the whole viewport before removal") }
        XCTAssertGreaterThan(frames.rows.count,20)
        try attach(frames,name:name)
        var previous:[String:[String:Any]] = [:], previousTime:Double?
        var intermediateReflowFrames = 0
        for row in frames.rows {
            let cells = row["cells"] as? [[String:Any]] ?? []
            let ids = cells.compactMap { $0["id"] as? String }
            XCTAssertEqual(Set(ids).count,ids.count,"No duplicate cell in any sampled frame")
            XCTAssertTrue(survivors.allSatisfy { ids.contains($0.uuidString) },"Every visible survivor must persist through the reflow")
            if row["alive"] as? Bool == false {
                XCTAssertFalse(cells.contains { $0["id"] as? String == tab.id.uuidString && number($0["alpha"]) > 0.01 },"The removed card must never flash back")
            } else {
                XCTAssertEqual(row["hasThumbnail"] as? Bool,true,"Keep the thumbnail until the exit completes")
            }
            if !reduce, row["phase"] as? String == "drag",
               let closing = cells.first(where:{ $0["id"] as? String == tab.id.uuidString }) {
                XCTAssertEqual(number(closing["x"])-number(closing["cellX"]),number(row["closingTX"]),accuracy:0.5,"Presentation geometry must track the recognized drag 1:1")
            }
            let time = row["time"] as? Double ?? 0
            var moved = false
            for current in cells {
                guard let id = current["id"] as? String, let uuid = UUID(uuidString:id), survivors.contains(uuid),
                      let old = previous[id], let previousTime else { continue }
                let dx = number(current["cellX"]) - number(old["cellX"])
                let dy = number(current["cellY"]) - number(old["cellY"])
                let distance = hypot(dx,dy)
                XCTAssertLessThan(distance/max(0.001,time-previousTime),reduce ? 9_000 : 4_500,"Survivors must reflow continuously rather than jump a grid slot")
                moved = moved || distance > 0.5
            }
            if moved { intermediateReflowFrames += 1 }
            previous = Dictionary(uniqueKeysWithValues:cells.compactMap { cell in (cell["id"] as? String).map { ($0,cell) } })
            previousTime = time
        }
        if commit && count > 1 { XCTAssertGreaterThan(intermediateReflowFrames,3,"Reflow must include intermediate positions") }
        let image = UIGraphicsImageRenderer(bounds:fixture.window.bounds).image { _ in fixture.window.drawHierarchy(in:fixture.window.bounds,afterScreenUpdates:false) }
        let picture = XCTAttachment(image:image); picture.name = "grid-swipe-\(name)-settled"; picture.lifetime = .keepAlways; add(picture)
    }

    /// Clean Release Instruments workload. No raster capture or per-frame file
    /// writes; the external recorder includes every stall in its window.
    func testProfileRepeatedSwipeClose() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ORIV_GRID_PROFILE"] == "1","Opt-in Instruments workload")
        let fixture = try GridSwipeFixture(count:10,reduce:false)
        defer { fixture.dispose() }
        try await fixture.ready()
        print("GRID_SWIPE_PROFILE_READY pid=\(ProcessInfo.processInfo.processIdentifier) thermal=\(ProcessInfo.processInfo.thermalState.rawValue) lowPower=\(ProcessInfo.processInfo.isLowPowerModeEnabled)")
        try await Task.sleep(for:.seconds(7))
        for _ in 0..<22 {
            for _ in 0..<2 { fixture.controller.session.addTab(select:false,load:false) }
            try await Task.sleep(for:.milliseconds(300))
            let cell = try XCTUnwrap(fixture.grid.collectionView.cellForItem(at:IndexPath(item:1,section:0)) as? MobileTabCell)
            let pan = GridSwipePan(); pan.phase = .began; cell.swipe(pan)
            for step in 1...10 {
                pan.phase = .changed; pan.delta = CGPoint(x:-CGFloat(step)*10,y:0); cell.swipe(pan)
                try await Task.sleep(for:.milliseconds(16))
            }
            pan.phase = .ended; pan.speed = CGPoint(x:-900,y:0); cell.swipe(pan)
            try await Task.sleep(for:.milliseconds(600))
        }
    }
}

@MainActor private struct GridSwipeRoot: View {
    let profiles:MobileProfiles
    let reduce:Bool
    var body:some View {
        let c = profiles.current
        MobileTabGrid(controller:c,profiles:profiles,tabs:c.session.orderedTabs,largeText:false,reduceMotion:reduce,open:{ _ in },onPull:{ _,_ in })
            .browserAppearance(c.appearance)
    }
}
@MainActor private final class GridSwipeFixture {
    let profiles = MobileProfiles()
    var controller:MobileController { profiles.current }
    let window:UIWindow
    let previous:UIWindow?
    var grid:MobileTabGridController {
        func find(_ c:UIViewController) -> MobileTabGridController? { (c as? MobileTabGridController) ?? c.children.lazy.compactMap { find($0) }.first }
        return find(window.rootViewController!)!
    }
    init(count:Int,reduce:Bool) throws {
        #if !targetEnvironment(simulator)
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ORIV_DEVICE_QA"] == "1" && Bundle.main.bundleIdentifier?.hasSuffix(".qa") == true,"Owner-approved isolated QA host required")
        #endif
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previous = scene.windows.first(where:\.isKeyWindow)
        window = UIWindow(windowScene:scene)
        for _ in 1..<count { controller.session.addTab(select:false,load:false) }
        for (i,tab) in controller.session.orderedTabs.enumerated() {
            let image = UIGraphicsImageRenderer(size:CGSize(width:180,height:240)).image { context in
                UIColor(hue:CGFloat(i)/CGFloat(count),saturation:0.65,brightness:0.7,alpha:1).setFill(); context.fill(CGRect(x:0,y:0,width:180,height:240))
                ("Card \(i)" as NSString).draw(at:CGPoint(x:20,y:30),withAttributes:[.font:UIFont.systemFont(ofSize:28),.foregroundColor:UIColor.white])
            }
            controller.tabPresentation.store(image,for:tab.id,revision:tab.documentRevision)
        }
        window.rootViewController = UIHostingController(rootView:GridSwipeRoot(profiles:profiles,reduce:reduce))
        window.makeKeyAndVisible()
    }
    func ready() async throws { try await Task.sleep(for:.milliseconds(600)); window.layoutIfNeeded(); grid.collectionView.layoutIfNeeded() }
    func dispose() { grid.cancelGestures(); window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible(); controller.session.shutdown(); profiles.continuity.shutdown() }
}
@MainActor private final class GridSwipePan:UIPanGestureRecognizer {
    var phase:UIGestureRecognizer.State = .possible
    var delta = CGPoint.zero, speed = CGPoint.zero
    override var state:UIGestureRecognizer.State { get { phase } set { phase = newValue } }
    override func translation(in view:UIView?) -> CGPoint { delta }
    override func velocity(in view:UIView?) -> CGPoint { speed }
}
@MainActor private final class GridSwipeFrames:NSObject {
    let fixture:GridSwipeFixture
    weak var closing:MobileTabCell?
    let id:UUID
    var link:CADisplayLink?
    var rows:[[String:Any]] = []
    var phase = "drag"
    var exitModelMaxX:CGFloat?
    init(fixture:GridSwipeFixture,closing:MobileTabCell,id:UUID) { self.fixture = fixture; self.closing = closing; self.id = id }
    func start() { let l = CADisplayLink(target:self,selector:#selector(frame)); l.preferredFrameRateRange = CAFrameRateRange(minimum:60,maximum:120,preferred:120); l.add(to:.main,forMode:.common); link = l }
    func stop() { link?.invalidate(); link = nil }
    @objc private func frame() {
        let alive = fixture.controller.session.tabs.contains { $0.id == id }
        let cells = fixture.grid.collectionView.visibleCells.compactMap { cell -> [String:Any]? in
            guard let cell = cell as? MobileTabCell else { return nil }
            let p = cell.layer.presentation() ?? cell.layer
            let c = cell.swipeSurface.layer.presentation() ?? cell.swipeSurface.layer
            let rect = c.convert(c.bounds,to:fixture.window.layer.presentation() ?? fixture.window.layer)
            return ["id":cell.representedTabID?.uuidString ?? "missing","cell":String(ObjectIdentifier(cell).hashValue),"x":rect.minX,"y":rect.minY,"width":rect.width,"alpha":c.opacity,"cellX":p.frame.minX,"cellY":p.frame.minY]
        }
        if alive, let closing {
            exitModelMaxX = closing.convert(closing.bounds,to:fixture.window).maxX + closing.swipeSurface.transform.tx
        }
        rows.append(["hasThumbnail":fixture.controller.tabPresentation.images[id] != nil,"time":ProcessInfo.processInfo.systemUptime,"phase":phase,"alive":alive,"cells":cells,"closingTX":closing.map { ($0.swipeSurface.layer.presentation() ?? $0.swipeSurface.layer).affineTransform().tx } ?? 0,"closingAlpha":closing.map { ($0.swipeSurface.layer.presentation() ?? $0.swipeSurface.layer).opacity } ?? 0])
    }
}
