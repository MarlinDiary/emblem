import XCTest
import AppKit
import SwiftUI
import PortraitCore
@testable import MailPortrait

private actor CapturedAssets: ResourceFetching {
    let root:URL
    let map:[String:[String:String]]
    init(root:URL) throws {
        self.root=root
        let entries=try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("originals.json"))) as! [[String:Any]]
        map=Dictionary(uniqueKeysWithValues:entries.compactMap { e in
            guard let file=e["file"] as? String,let origin=e["origin"] as? String else { return nil }
            return (origin,["file":file,"type":e["type"] as? String ?? "image/png"])
        })
    }
    func fetch(_ url:URL,limit:Int) async throws -> WebResource {
        guard let e=map[url.absoluteString] else { throw PortraitError.message("Not in captured asset set") }
        return .init(data:try Data(contentsOf:root.appendingPathComponent(e["file"]!)),url:url,contentType:e["type"]!)
    }
}
final class V012ExperienceTests:XCTestCase {
    @MainActor func testSectionSelectionAndBatchVisibility() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let m=AppModel(demo:true,rootOverride:root)
        let letter=try NameAvatar.candidate(name:"Fastlink")
        m.rows=[SenderRow(email:EmailAddress("hello@fastlink.com")!,name:"Fastlink",candidates:[letter],selectedCandidate:letter.id),SenderRow(email:EmailAddress("person@company.org")!,name:"Person")]
        m.selectedID=m.rows[0].id;XCTAssertTrue(m.showsBatchAction)
        m.section="review";m.reconcileSelection();XCTAssertEqual(m.selectedID,m.rows[1].id);XCTAssertFalse(m.showsBatchAction)
        m.section="all";m.reconcileSelection();XCTAssertEqual(m.selectedID,m.rows[0].id)
        m.section="history";XCTAssertFalse(m.showsBatchAction)
    }
    @MainActor func testNativeClipOffsetAndSelectionRestoreIndependently() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let m=AppModel(demo:true,rootOverride:root,backgroundWorkAllowed:false)
        m.rows=(0..<150).map { SenderRow(email:EmailAddress("person\($0)@company.org")!,name:"Person \($0)") }
        m.selectedID=m.rows[3].id
        _=NSApplication.shared
        let coordinator=VirtualizedSenderTable.Coordinator(model:m)
        let scroll=coordinator.makeScrollView()
        let window=NSWindow(contentRect:CGRect(x:-20000,y:-20000,width:300,height:550),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        window.contentView=scroll;window.orderBack(nil);defer { window.orderOut(nil) }
        func update() {
            coordinator.update(scroll:scroll,groups:m.visibleGroups,rowsRevision:m.rowsRevision,
                               navigationKey:m.navigationKey,selectedGroupID:m.selectedListID,
                               batchMode:m.batchMode,selectedForBatch:m.selectedForBatch,
                               controlsDisabled:false)
        }
        func settle() async throws {
            for _ in 0..<8 {
                window.contentView?.layoutSubtreeIfNeeded();coordinator.table.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds:25_000_000)
            }
        }
        update()
        try await settle()
        scroll.contentView.scroll(to:CGPoint(x:0,y:1800));scroll.reflectScrolledClipView(scroll.contentView)
        try await settle()
        XCTAssertEqual(m.navigationMemory.offsets["all|"] ?? -1,1800,accuracy:3)
        m.section="review";m.reconcileSelection();update();try await settle()
        XCTAssertEqual(scroll.contentView.bounds.minY,0,accuracy:3)
        scroll.contentView.scroll(to:CGPoint(x:0,y:900));scroll.reflectScrolledClipView(scroll.contentView)
        try await settle()
        m.section="all";m.reconcileSelection();update();try await settle()
        XCTAssertEqual(scroll.contentView.bounds.minY,1800,accuracy:3)
        XCTAssertEqual(m.selectedID,m.rows[3].id)
        print("NATIVE_SCROLL ALL=1800 REVIEW=900 RESTORED=\(Int(scroll.contentView.bounds.minY)) SELECTED_ROW=3")
    }
    @MainActor func testMonogramUsesBackingPixelThumbnail() throws {
        let c=try NameAvatar.candidate(name:"Fastlink")
        XCTAssertTrue(c.origin.hasPrefix("local://monogram/v2/"))
        let image=try XCTUnwrap(PortraitImageCache.shared.image(for:c.png,pixelSize:76))
        XCTAssertEqual(image.representations.first?.pixelsWide,76)
        XCTAssertTrue(image === PortraitImageCache.shared.image(for:c.png,pixelSize:76))
        if let folder=ProcessInfo.processInfo.environment["MAILPORTRAIT_V012_ASSETS"] {
            try c.png.write(to:URL(fileURLWithPath:folder).appendingPathComponent("monogram-after.png"))
            try NSBitmapImageRep(cgImage:image.cgImage(forProposedRect:nil,context:nil,hints:nil)!).representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:folder).appendingPathComponent("monogram-76px.png"))
        }
    }
    @MainActor func testRealCacheMigrationAndFreshOriginalCanvas() async throws {
        guard let folder=ProcessInfo.processInfo.environment["MAILPORTRAIT_V012_ASSETS"],let state=ProcessInfo.processInfo.environment["MAILPORTRAIT_REAL_STATE"] else { throw XCTSkip("read-only corpus opt-in") }
        let assets=URL(fileURLWithPath:folder)
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try FileManager.default.copyItem(at:URL(fileURLWithPath:state),to:root.appendingPathComponent("senders.json"))
        let m=AppModel(demo:false,rootOverride:root);m.automaticEnabled=false;m.useWebsite=true
        let before=m.rows.map(\.id)
        await m.prepareAvatarQuality();await m.prepareNameFallbacks()
        let sources:[String:CandidateSource]=["mail@ifttt.com":.touchIcon,"notifications@vervecopilot.com":.siteLogo,"updates@account.ubisoft.com":.monogram,"noreply@mailer2.okx.com":.manifest,"michaelt@cursor.so":.manifest]
        for (email,source) in sources { XCTAssertEqual(m.rows.first { $0.id==email }?.chosen?.source,source,email) }
        await m.refreshCanvasOriginals(client:try CapturedAssets(root:assets))
        let tesla=try XCTUnwrap(m.rows.first { $0.id=="aucklandsouthbodyrepair@tesla.com" }?.chosen)
        let cloud=try XCTUnwrap(m.rows.first { $0.id=="noreply@icloud.com.cn" }?.chosen)
        XCTAssertEqual(tesla.layoutRevision,ImagePipeline.currentLayoutRevision);XCTAssertEqual(cloud.layoutRevision,ImagePipeline.currentLayoutRevision)
        try tesla.png.write(to:assets.appendingPathComponent("tesla-after.png"))
        try cloud.png.write(to:assets.appendingPathComponent("icloud-after.png"))
        XCTAssertLessThan(cloud.visualQuality?.frameFraction ?? 1,0.005)
        let bitmap=try XCTUnwrap(NSBitmapImageRep(data:tesla.png))
        let edge=try XCTUnwrap(bitmap.colorAt(x:0,y:bitmap.pixelsHigh/2)?.usingColorSpace(.deviceRGB))
        let inner=try XCTUnwrap(bitmap.colorAt(x:bitmap.pixelsWide/5,y:bitmap.pixelsHigh/2)?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(edge.redComponent,inner.redComponent,accuracy:0.015)
        XCTAssertLessThan(edge.redComponent,0.99)
        XCTAssertEqual(before,m.rows.map(\.id));XCTAssertTrue(try m.engine.records().isEmpty)
        XCTAssertEqual(m.rows.first { $0.id=="noreply-fusion-notifications@auckland.ac.nz" }?.id,"noreply-fusion-notifications@auckland.ac.nz")
        try Data(contentsOf:m.stateURL).write(to:assets.appendingPathComponent("verified-migrated-senders.json"))
        print("CORPUS_MIGRATION ROWS=\(m.rows.count) IFTTT=touchIcon VERVE=siteLogo UBISOFT=monogram CURSOR=manifest OKX=manifest TESLA=uniformEdge ICLOUD=frameRemoved CONTACT_JOURNAL=EMPTY")
    }
}
