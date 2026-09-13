import XCTest
import AppKit
import PortraitCore
@testable import MailPortrait

final class NameAvatarTests: XCTestCase {
    @MainActor func testFastlinkProducesRealHighResolutionLetterArtwork() throws {
        let a = try NameAvatar.candidate(name: "Fastlink")
        XCTAssertEqual(NameAvatar.initials("Fastlink"), "F")
        XCTAssertEqual(NameAvatar.initials("Valerio Terragni"), "VT")
        XCTAssertEqual(NameAvatar.initials("  陈 小明 "), "陈小")
        XCTAssertEqual(NameAvatar.initials("✨ Fastlink"), "F")
        XCTAssertEqual(a.source, .monogram)
        XCTAssertTrue(a.origin.hasPrefix("local://monogram/"))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: a.png))
        XCTAssertEqual(bitmap.pixelsWide, 1024); XCTAssertEqual(bitmap.pixelsHigh, 1024)
        XCTAssertLessThan(a.png.count,150_000); XCTAssertFalse(a.lowResolution); XCTAssertTrue(a.recommendedAutomatically)
    }
    @MainActor func testNamesAndVariantsAreStableWithoutLeakingNamesInOrigin() throws {
        let a = try NameAvatar.candidate(name: "Fastlink")
        let b = try NameAvatar.candidate(name: "  fastlink  ")
        XCTAssertEqual(a.png, b.png); XCTAssertEqual(a.id,b.id)
        XCTAssertNotEqual(a.png, try NameAvatar.candidate(name:"Fastlink",variant:1).png)
        XCTAssertFalse(a.origin.localizedCaseInsensitiveContains("fastlink"))
        XCTAssertLessThan(a.score, AvatarCandidate(source:.favicon,origin:"icon",width:256,height:256,png:Data([1])).score)
    }
    @MainActor func testFallbackNeverReplacesRealOrManualImagesAndKeepsLookupDue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let m = AppModel(demo:true,rootOverride:root)
        var row = SenderRow(email:EmailAddress("service@fastlink.com")!,name:"Fastlink")
        row.lastLookup = Date(); row.lookupPolicy = AutomaticLookupPolicy.key(row,website:true,gravatar:false)
        m.rows = [row]; await m.prepareNameFallbacks()
        XCTAssertEqual(m.rows[0].chosen?.source,.monogram)
        XCTAssertFalse(m.rows[0].selectionIsManual == true)
        let next = Date().addingTimeInterval(8*86400)
        XCTAssertTrue(AutomaticLookupPolicy.due(m.rows[0],website:true,gravatar:false,now:next))
        let real = AvatarCandidate(source:.touchIcon,origin:"site",width:256,height:256,png:Data([1]))
        m.rows[0].candidates = [real]; m.rows[0].selectedCandidate=real.id
        await m.prepareNameFallbacks(); XCTAssertEqual(m.rows[0].chosen?.id,real.id)
    }
    @MainActor func testManualMonogramSurvivesRestartAndCanBeAppliedAndUndone() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let m=AppModel(demo:true,rootOverride:root)
        let email=EmailAddress("service@fastlink.com")!
        m.rows=[SenderRow(email:email,name:"Fastlink")]
        let c=try NameAvatar.candidate(name:"Fastlink")
        m.addCandidate(c,to:email.value)
        let loaded=AppModel(demo:true,rootOverride:root)
        XCTAssertEqual(loaded.rows[0].chosen?.source,.monogram)
        XCTAssertTrue(loaded.rows[0].selectionIsManual == true)
        let change=try loaded.engine.apply(email:email,name:"Fastlink",candidate:c,allowCreate:true)
        XCTAssertEqual(try loaded.port.get(id:change.contactID!)?.image,c.png)
        try loaded.engine.undo(id:change.id)
        XCTAssertTrue((loaded.port as! FixtureContactStore).contacts.isEmpty)
    }
    @MainActor func testChoosingAnAvatarKeepsInspectorVisibleWhenQueueChanges() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let m=AppModel(demo:true,rootOverride:root)
        let weak=AvatarCandidate(source:.domainIcon,origin:"service",width:256,height:256,png:Data([1]))
        let row=SenderRow(email:EmailAddress("service@fastlink.com")!,name:"Fastlink",candidates:[weak],selectedCandidate:weak.id)
        m.rows=[row];m.section="review";m.selectedID=row.id
        m.addCandidate(try NameAvatar.candidate(name:row.name),to:row.id)
        XCTAssertTrue(m.visibleRows.isEmpty);XCTAssertEqual(m.selected?.id,row.id)
        XCTAssertEqual(m.selected?.chosen?.source,.monogram)
        m.search="different";XCTAssertNil(m.selected)
    }

    @MainActor func testColourSelectionDoesNotReorderChoices() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let m=AppModel(demo:true,rootOverride:root)
        m.rows=[SenderRow(email:EmailAddress("service@fastlink.com")!,name:"Fastlink")]
        let before=m.avatarChoices(for:m.rows[0],allSizes:false)
        m.addCandidate(before[2],to:m.rows[0].id)
        let after=m.avatarChoices(for:m.rows[0],allSizes:false)
        XCTAssertEqual(before.map { digest($0.png) },after.map { digest($0.png) })
        XCTAssertEqual(after[2].id,m.rows[0].selectedCandidate)
    }

}
