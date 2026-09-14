import XCTest
import PortraitCore
@testable import Emblem

private actor PersistenceHistoryTransport:GmailHTTPTransport {
    func data(for request:URLRequest) async throws ->(Data,HTTPURLResponse) {
        (Data(#"{"historyId":"101"}"#.utf8),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
    }
}
final class RowsPersistenceTests:XCTestCase {
    func testBoundedArrayPreservesEmptyEscapedUnicodeBinaryAndOrdering()throws {
        XCTAssertEqual(try RowsPersistence.encode([]),Data("[]".utf8))
        var rows=[SenderRow(email:EmailAddress("first@fixture.test")!,name:"Line\nQuote\" 日本語 🦉"),SenderRow(email:EmailAddress("second@fixture.test")!,name:"Last")]
        let c=AvatarCandidate(source:.manual,origin:"file:///fixture/photo.png",width:256,height:256,png:Data((0...255).map{UInt8($0)}))
        rows[0].candidates=[c];rows[0].selectedCandidate=c.id;rows[0].selectionIsManual=true;rows[1].ignored=true
        let bounded=try RowsPersistence.encode(rows),reference=try JSONEncoder().encode(rows)
        let a=try JSONSerialization.jsonObject(with:bounded) as! NSArray,b=try JSONSerialization.jsonObject(with:reference) as! NSArray
        XCTAssertEqual(a,b)
        let reopened=try JSONDecoder().decode([SenderRow].self,from:bounded)
        XCTAssertEqual(reopened.map(\.name),rows.map(\.name));XCTAssertEqual(reopened[0].chosen?.png,c.png)
        XCTAssertTrue(reopened[0].selectionIsManual==true);XCTAssertTrue(reopened[1].ignored)
    }
    func testBase64HeavyRowsRemainBackwardCompatibleWithoutSlashExpansion()throws {
        var row=SenderRow(email:EmailAddress("image@fixture.test")!,name:"Fixture")
        let candidate=AvatarCandidate(source:.touchIcon,origin:"https://fixture.test/icon.png",width:256,height:256,png:Data(repeating:255,count:32_000))
        row.candidates=[candidate];row.selectedCandidate=candidate.id
        let rows=Array(repeating:row,count:32),start=Date()
        let compact=try RowsPersistence.encode(rows),duration=Date().timeIntervalSince(start)
        let old=try JSONEncoder().encode(rows)
        let reopened=try JSONDecoder().decode([SenderRow].self,from:compact)
        XCTAssertEqual(reopened.count,rows.count);XCTAssertEqual(reopened[0].chosen?.png,candidate.png)
        XCTAssertLessThan(compact.count,old.count*3/5)
        XCTAssertFalse(String(decoding:compact,as:UTF8.self).contains("\\/"))
        print("ROW_BASE64_ENCODING_BYTES=\(compact.count) LEGACY_BYTES=\(old.count) SECONDS=\(duration) ROUND_TRIP=PASS")
    }
    @MainActor func testNewMailRunsWhileContactsSnapshotIsBeingEncoded() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=try FixtureContactStore(url:root.appendingPathComponent("fixture-contacts.json"))
        let m=AppModel(demo:false,rootOverride:root,contactStore:store)
        m.automation.setupComplete=true;m.automation.contacts=false;m.automation.mail=false
        m.useWebsite=false;m.useGravatar=false;m.mailSync.enabled=true
        var row=SenderRow(email:EmailAddress("sender@fixture.test")!,name:"New Sender")
        let photo=try NameAvatar.candidate(name:row.name);row.candidates=[photo];row.selectedCandidate=photo.id
        m.rows=[row]
        m.gmail.accounts=[GmailAccount(id:"fixture",email:"owner@gmail.com",cursor:.init(historyID:"100",lastCheck:Date(),sentBootstrapComplete:true))]
        m.gmailAPI=GmailAPI(transport:PersistenceHistoryTransport());m.gmailTokenProvider={_ in "fixture-token"}
        var encoding=false,finished=false
        m.rowsSnapshotEncoder={snapshot in encoding=true;try await Task.sleep(for:.milliseconds(300));return try JSONEncoder().encode(snapshot)}
        let sync=Task {try await m.performMailSync();finished=true}
        for _ in 0..<40 {if encoding || finished {break};try await Task.sleep(for:.milliseconds(5))}
        XCTAssertTrue(encoding,"Contacts sync must serialize its cache off the main actor")
        if encoding {
            m.kickGmailSync(forceAccountIDs:["fixture"])
            for _ in 0..<30 {if m.gmail.accounts[0].cursor.historyID=="101" {break};try await Task.sleep(for:.milliseconds(5))}
            XCTAssertEqual(m.gmail.accounts[0].cursor.historyID,"101")
            XCTAssertFalse(finished,"New-mail history must advance before the slow cache flush finishes")
        }
        try await sync.value
        m.syncTask?.cancel();if let task=m.syncTask {await task.value}
        let reopened=AppModel(demo:false,rootOverride:root,contactStore:store)
        XCTAssertTrue(reopened.rows[0].completed)
        XCTAssertNotNil(reopened.rows[0].current?.image)
    }
    @MainActor func testNewerDurableEditWinsAnAsyncFlush() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let m=AppModel(demo:true,rootOverride:root)
        m.rows=[SenderRow(email:EmailAddress("sender@fixture.test")!,name:"Original")]
        m.rowsSnapshotEncoder={snapshot in m.rows[0].name="Later edit";m.save();return try JSONEncoder().encode(snapshot)}
        try await m.saveAsync()
        let saved=try JSONDecoder().decode([SenderRow].self,from:Data(contentsOf:m.stateURL))
        XCTAssertEqual(saved[0].name,"Later edit")
        XCTAssertEqual(m.lastSavedRowsRevision,m.rowsRevision)
    }
    func testBackgroundRoutesAwaitNonblockingCacheFlush() throws {
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let background=try String(contentsOf:root.appendingPathComponent("Sources/Emblem/BackgroundSyncAgent.swift"))
        XCTAssertTrue(background.contains("await model.saveAsync()"))
        let automatic=try String(contentsOf:root.appendingPathComponent("Sources/Emblem/AutomationModel.swift"))
        let resolve=automatic.components(separatedBy:"func automaticallyResolve(now:").last!.components(separatedBy:"func contactsDidChange()").first!
        XCTAssertFalse(resolve.contains("defer { save() }"))
        XCTAssertTrue(resolve.contains("await saveAsync()"))
    }
}
