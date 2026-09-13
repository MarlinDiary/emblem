import XCTest
import SwiftUI
import AppKit
import PortraitCore
@testable import MailPortrait

final class SnapshotTests: XCTestCase {
    // Offscreen layout exports supplement, but never replace, native window QA.
    // WindowServer-composited materials and toolbar chrome may be absent here.
    @MainActor func testOffscreenLayoutExports() async throws {
        guard let path = ProcessInfo.processInfo.environment["MAILPORTRAIT_SNAPSHOT_DIR"] else { throw XCTSkip("Set MAILPORTRAIT_SNAPSHOT_DIR for native rendering checks") }
        let output=URL(fileURLWithPath:path, isDirectory:true)
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("mailportrait-snapshots-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        _ = NSApplication.shared
        let session=AppSession(arguments:["snapshot","--demo"],isolatedRoot:root)
        for (name,size,scheme) in [("gallery-light",CGSize(width:1160,height:760),ColorScheme.light),("gallery-dark",CGSize(width:1160,height:760),ColorScheme.dark),("gallery-compact",CGSize(width:960,height:660),ColorScheme.light)] {
            try await capture(MainView(model:session.model,session:session), name:name,size:size,scheme:scheme,output:output)
        }
        let m=session.model
        m.search="not-a-sender"; m.reconcileSelection()
        try await capture(MainView(model:m,session:session),name:"search-empty",size:CGSize(width:960,height:660),scheme:.light,output:output)
        m.search=""; m.reconcileSelection()
        try await capture(ImportSheet(model:m),name:"import",size:CGSize(width:526,height:325),scheme:.light,output:output)
        try await capture(SourceConsentSheet(model:m),name:"source-consent",size:CGSize(width:546,height:650),scheme:.light,output:output)
        m.prepareApply(ids:[m.selectedID!])
        try await capture(ApplySheet(model:m),name:"apply-confirmation",size:CGSize(width:516,height:400),scheme:.light,output:output)
        try await capture(PreferencesView(model:m),name:"settings",size:CGSize(width:550,height:480),scheme:.light,output:output)
        print("NATIVE_VIEW_SNAPSHOTS=8 REAL_CONTACTS_READ=0 REAL_CONTACTS_WRITTEN=0")
    }
    @MainActor func testRealLibraryWorkflowExports() async throws {
        guard let path = ProcessInfo.processInfo.environment["MAILPORTRAIT_SNAPSHOT_DIR"],
              let state = ProcessInfo.processInfo.environment["MAILPORTRAIT_REAL_STATE"] else { throw XCTSkip("Real-state rendering is opt-in and read-only") }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workflow-real-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: state), to: root.appendingPathComponent("senders.json"))
        let session = AppSession(arguments: ["snapshot", "--data-dir", root.path])
        let m = session.model
        m.automaticEnabled = false; m.automation.setupComplete = true
        m.contactsConnected = true; m.mailConnected = true; m.section = "ready"; m.reconcileSelection()
        let plan = BatchPlanner.plan(m.rows)
        print("REAL_STATE ROWS=\(m.rows.count) READY=\(m.readyCount) REVIEW=\(m.reviewCount) PLAN_EMAILS=\(plan.emailCount) CARDS=\(plan.jobs.count) NEW=\(plan.newContactCount) UPDATE=\(plan.updateCount)")
        for (name, size, scheme) in [("workflow-real-light", CGSize(width:1160,height:760), ColorScheme.light), ("workflow-real-dark", CGSize(width:1160,height:760), ColorScheme.dark), ("workflow-real-compact", CGSize(width:960,height:660), ColorScheme.light)] {
            try await capture(MainView(model:m,session:session),name:name,size:size,scheme:scheme,output:output)
        }
        m.prepareBatch(ids: m.batchScopeIDs); m.batchAllowCreate = true
        try await capture(BatchApplySheet(model:m),name:"workflow-batch-confirmation",size:CGSize(width:586,height:655),scheme:.light,output:output)
        m.showBatchConfirmation = false; m.section = "review"; m.reconcileSelection()
        try await capture(MainView(model:m,session:session),name:"workflow-review",size:CGSize(width:1160,height:760),scheme:.light,output:output)
        XCTAssertTrue(try m.engine.records().isEmpty)
        print("REAL_LIBRARY_RENDER_ONLY CONTACTS_WRITES=0 NETWORK_REQUESTS=0")
    }
    @MainActor func testV011ChoiceSurfaceWithRealAssets() async throws {
        guard let path=ProcessInfo.processInfo.environment["MAILPORTRAIT_SNAPSHOT_DIR"],
              let state=ProcessInfo.processInfo.environment["MAILPORTRAIT_REAL_STATE"],
              let original=ProcessInfo.processInfo.environment["MAILPORTRAIT_LINKEDIN_ORIGINAL"] else { throw XCTSkip("Real artwork rendering is opt-in") }
        let output=URL(fileURLWithPath:path,isDirectory:true)
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("v011-real-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try FileManager.default.copyItem(at:URL(fileURLWithPath:state),to:root.appendingPathComponent("senders.json"))
        let session=AppSession(arguments:["snapshot","--data-dir",root.path])
        let m=session.model;m.automaticEnabled=false;m.automation.setupComplete=true;m.contactsConnected=true;m.mailConnected=true
        let asset=try XCTUnwrap(OfficialBrandAssets.asset(for:URL(string:"https://linkedin.com")!))
        let rendered=try ImagePipeline.decode(.init(data:Data(contentsOf:URL(fileURLWithPath:original)),url:asset.assetURL),source:.officialBrand,artwork:asset.artwork)
        try rendered.png.write(to:output.appendingPathComponent("linkedin-after.png"))
        let i=try XCTUnwrap(m.rows.firstIndex { $0.id == "invitations@linkedin.com" })
        m.rows[i].candidates=[rendered];m.rows[i].selectedCandidate=rendered.id
        m.section="all";m.selectedID=m.rows[i].id
        for (name,size,scheme) in [("choices-linkedin-light",CGSize(width:1160,height:760),ColorScheme.light),("choices-linkedin-dark",CGSize(width:1160,height:760),ColorScheme.dark),("choices-linkedin-compact",CGSize(width:960,height:660),ColorScheme.light)] {
            try await capture(MainView(model:m,session:session),name:name,size:size,scheme:scheme,output:output)
        }
        try await capture(CandidateTile(candidate:rendered,selected:true,demo:false,action:{}).frame(width:130).padding(6),name:"selected-tile-light",size:CGSize(width:142,height:128),scheme:.light,output:output)
        try await capture(CandidateTile(candidate:rendered,selected:true,demo:false,action:{}).frame(width:130).padding(6),name:"selected-tile-dark",size:CGSize(width:142,height:128),scheme:.dark,output:output)
        for mode in ["light", "dark"] {
            let bitmap=try XCTUnwrap(NSBitmapImageRep(data:Data(contentsOf:output.appendingPathComponent("selected-tile-\(mode).png"))))
            var minX=bitmap.pixelsWide,minY=bitmap.pixelsHigh,maxX=0,maxY=0
            for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
                if let c=bitmap.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB), c.blueComponent>0.88,c.redComponent<0.40,c.greenComponent>0.35 {
                    minX=min(minX,x);maxX=max(maxX,x);minY=min(minY,y);maxY=max(maxY,y)
                }
            } }
            XCTAssertGreaterThan(maxX,minX);XCTAssertGreaterThan(maxY,minY)
            XCTAssertLessThan(minX,30);XCTAssertLessThan(minY,30)
            XCTAssertGreaterThanOrEqual(minX,10);XCTAssertGreaterThanOrEqual(minY,10)
            XCTAssertEqual(Double(minX),Double(bitmap.pixelsWide-1-maxX),accuracy:1)
            XCTAssertEqual(Double(minY),Double(bitmap.pixelsHigh-1-maxY),accuracy:1)
            print("SELECTION_BORDER mode=\(mode) LEFT=\(minX) RIGHT=\(bitmap.pixelsWide-1-maxX) TOP=\(minY) BOTTOM=\(bitmap.pixelsHigh-1-maxY)")
        }
        let fastlink=try XCTUnwrap(m.rows.first { $0.name == "Fastlink" })
        m.section="all";m.search="Fastlink";m.selectedID=fastlink.id
        await m.prepareNameFallbacks()
        let choices=m.avatarChoices(for:try XCTUnwrap(m.selected),allSizes:false)
        XCTAssertEqual(choices.filter { $0.source == .monogram }.count,3)
        try await capture(MainView(model:m,session:session),name:"choices-fastlink",size:CGSize(width:1160,height:760),scheme:.light,output:output)
        let alternate=try XCTUnwrap(choices.last)
        m.addCandidate(alternate,to:fastlink.id)
        XCTAssertEqual(m.selected?.chosen?.id,alternate.id)
        try await capture(MainView(model:m,session:session),name:"choices-fastlink-selected",size:CGSize(width:960,height:660),scheme:.dark,output:output)
        for (index,name) in ["Fastlink","Valerio Terragni"].enumerated() {
            let c=try NameAvatar.candidate(name:name)
            try c.png.write(to:output.appendingPathComponent("monogram-\(index).png"))
            print("MONOGRAM name=\(name) SIZE=1024 BYTES=\(c.png.count) SOURCE=local")
        }
        XCTAssertTrue(try m.engine.records().isEmpty)
        print("V011_REAL_ASSET_SNAPSHOTS=7 CONTACTS_WRITTEN=0 NETWORK_REQUESTS=0")
    }
    @MainActor private func capture<V: View>(_ view:V,name:String,size:CGSize,scheme:ColorScheme,output:URL) async throws {
        NSApp.appearance = NSAppearance(named:scheme == .dark ? .darkAqua : .aqua)
        let host=NSHostingView(rootView:view.preferredColorScheme(scheme).background(Color(nsColor: .windowBackgroundColor)))
        let window=NSWindow(contentRect:CGRect(origin:.zero,size:size),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.animationBehavior = .none
        window.appearance=NSAppearance(named:scheme == .dark ? .darkAqua : .aqua)
        window.contentView=host; host.frame=CGRect(origin:.zero,size:size)
        window.setFrameOrigin(CGPoint(x:-20000,y:-20000))
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds:25_000_000) }
        guard let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds) else { return XCTFail("missing bitmap") }
        host.cacheDisplay(in:host.bounds,to:bitmap)
        guard let png=bitmap.representation(using:.png,properties:[:]) else { return XCTFail("missing PNG") }
        XCTAssertGreaterThan(bitmap.pixelsWide,Int(size.width)-2)
        try png.write(to:output.appendingPathComponent(name+".png"))
        print("SNAPSHOT \(name) \(bitmap.pixelsWide)x\(bitmap.pixelsHigh) PNG_BYTES=\(png.count)")
    }
}
