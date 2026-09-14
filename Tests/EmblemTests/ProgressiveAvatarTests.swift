import XCTest
import PortraitCore
@testable import Emblem

final class ProgressiveAvatarTests: XCTestCase {
    @MainActor private func model() throws -> AppModel {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock {try? FileManager.default.removeItem(at:root)}
        return AppModel(demo:true,rootOverride:root)
    }
    @MainActor func testNewSenderGetsLocalAvatarBeforeAnyWebLookup() async throws {
        let m=try model();m.rows=[SenderRow(email:EmailAddress("new@fixture.test")!,name:"Fresh Sender")]
        XCTAssertNil(m.rows[0].lastLookup)
        await m.prepareNameFallbacks()
        XCTAssertEqual(m.rows[0].chosen?.source,.monogram)
        XCTAssertEqual(m.rows[0].selectionIsManual,false)
        XCTAssertNil(m.rows[0].lastLookup,"Local artwork must not claim a completed network lookup")
    }
    @MainActor func testProvisionalAvatarDoesNotReplacePersonalPhotoOrManualChoice() async throws {
        let m=try model();let c=try NameAvatar.candidate(name:"Original")
        let contact=try m.port.create(name:"Original",email:"personal@fixture.test",image:c.png)
        var personal=SenderRow(email:EmailAddress("personal@fixture.test")!,name:"Original");personal.current=contact
        var manual=SenderRow(email:EmailAddress("manual@fixture.test")!,name:"Manual");manual.selectionIsManual=true
        var ignored=SenderRow(email:EmailAddress("ignored@fixture.test")!,name:"Ignored");ignored.ignored=true
        m.rows=[personal,manual,ignored];await m.prepareNameFallbacks()
        XCTAssertTrue(m.rows.allSatisfy{$0.chosen==nil});XCTAssertEqual(try m.port.get(id:contact.id)?.image,c.png)
    }
    @MainActor func testLargeFreshLibraryPreparesOnlyBoundedBatch() async throws {
        let m=try model();m.rows=(0..<900).map {SenderRow(email:EmailAddress("p\($0)@fixture.test")!,name:"Person \($0)")}
        await m.prepareNameFallbacks()
        XCTAssertEqual(m.rows.filter{$0.chosen != nil}.count,24)
    }
    @MainActor func testProvisionalPhotoIsAppliedBeforeSlowWebsiteAndUpgradesSameCard()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store=try FixtureContactStore(),client=SlowProvisionalWeb(png:try NameAvatar.candidate(name:"Web Art",variant:1).png)
        let m=AppModel(demo:false,rootOverride:root,resolverFactory:{AvatarResolver(client:client)},contactStore:store)
        m.automation.setupComplete=true;m.useWebsite=true;m.useGravatar=false;m.mailSync.enabled=true
        m.rows=[SenderRow(email:EmailAddress("fresh@company.org")!,name:"Fresh Sender")]
        m.kickAutomaticLookup()
        for _ in 0..<150 where m.rows[0].current == nil {try await Task.sleep(for:.milliseconds(10))}
        let initial=try XCTUnwrap(m.rows[0].current)
        XCTAssertEqual(m.rows[0].chosen?.source,.monogram);XCTAssertNil(m.rows[0].lastLookup)
        if let t=m.automaticTask {await t.value}
        if let t=m.syncTask {await t.value}
        XCTAssertEqual(m.rows[0].chosen?.source,.touchIcon)
        XCTAssertEqual(m.rows[0].current?.id,initial.id);XCTAssertNotEqual(m.rows[0].current?.image,initial.image)
        try await m.drainAndSave();try? FileManager.default.removeItem(at:root)
    }
    @MainActor func testAppOwnedMonogramOnExistingEmptyCardCanUpgrade() async throws {
        let m=try model();let c=try NameAvatar.candidate(name:"Fresh Sender")
        let contact=try m.port.create(name:"Fresh Sender",email:"existing@fixture.test",image:Data([1]))
        _=try m.port.setImage(id:contact.id,image:nil)
        m.rows=[SenderRow(email:EmailAddress("existing@fixture.test")!,name:"Fresh Sender",candidates:[c],selectedCandidate:c.id)]
        m.rows[0].selectionIsManual=false;m.mailSync.enabled=true
        try await m.performMailSync()
        XCTAssertEqual(m.rows[0].current?.id,contact.id)
        XCTAssertTrue(m.managedFallbackIDs().contains(m.rows[0].id),"Only our unchanged automatic photo may upgrade, whether or not we created the card")
    }
}

private actor SlowProvisionalWeb:ResourceFetching {
    let png:Data
    init(png:Data){self.png=png}
    func fetch(_ url:URL,limit:Int)async throws->WebResource {
        guard url.host == "company.org" else{throw HTTPResourceError(status:404)}
        if url.path == "/" {try await Task.sleep(for:.seconds(2));return .init(data:Data("<link rel='apple-touch-icon' href='/photo.png'>".utf8),url:url)}
        if url.path == "/photo.png" {return .init(data:png,url:url)}
        throw HTTPResourceError(status:404)
    }
}
