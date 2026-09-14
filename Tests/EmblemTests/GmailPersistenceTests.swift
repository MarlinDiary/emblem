import XCTest
import PortraitCore
@testable import Emblem

final class GmailPersistenceTests: XCTestCase {
    @MainActor private func model(_ root:URL)->AppModel {
        let model=AppModel(demo:false,rootOverride:root)
        model.automation.contacts=false;model.automation.mail=false
        model.useWebsite=false;model.useGravatar=false;model.mailSync.enabled=false
        model.gmail.accounts=[GmailAccount(id:"fixture",email:"owner@gmail.com",cursor:.init(historyID:"100"))]
        return model
    }
    private func batch()->GmailBatch {
        let message=GmailMessage(id:"a1",labelIds:["INBOX"],internalDate:"1789344000000",payload:.init(headers:[.init(name:"From",value:"New Sender <new@fixture.test>")]))
        return .init(messages:[message],cursor:.init(historyID:"101",lastCheck:Date()),hasMore:false)
    }
    @MainActor func testContinuousAvatarChangesDoNotStarveHistoryPersistence() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let model=model(root);var encodes=0
        model.rowsSnapshotEncoder={snapshot in
            encodes+=1
            if encodes>3 {throw NSError(domain:"SnapshotRetryStarvation",code:1)}
            model.rows[0].status="Avatar update \(encodes)"
            await Task.yield()
            return try JSONEncoder().encode(snapshot)
        }
        try await model.ingestGmail(batch(),accountID:"fixture")
        XCTAssertEqual(encodes,1,"A newer unsaved avatar must not force an unbounded re-encode")
        XCTAssertEqual(model.gmail.accounts[0].cursor.historyID,"101")
        let saved=try JSONDecoder().decode([SenderRow].self,from:Data(contentsOf:model.stateURL))
        XCTAssertEqual(saved.map(\.id),["new@fixture.test"],"The new mail sender must be durable before its cursor")
        XCTAssertNotEqual(model.lastSavedRowsRevision,model.rowsRevision,"The later avatar remains dirty for the next save")
        model.save()
        let latest=try JSONDecoder().decode([SenderRow].self,from:Data(contentsOf:model.stateURL))
        XCTAssertEqual(latest[0].status,"Avatar update 1")
    }
    @MainActor func testSnapshotNeverOverwritesANewerDurableUserEdit() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let model=model(root);var encodes=0
        model.rowsSnapshotEncoder={snapshot in
            encodes+=1
            if encodes>3 {throw NSError(domain:"SnapshotRetryStarvation",code:2)}
            model.rows[0].name="User Chosen Name";model.save()
            return try JSONEncoder().encode(snapshot)
        }
        try await model.ingestGmail(batch(),accountID:"fixture")
        let saved=try JSONDecoder().decode([SenderRow].self,from:Data(contentsOf:model.stateURL))
        XCTAssertEqual(saved[0].name,"User Chosen Name")
        XCTAssertEqual(encodes,1)
        XCTAssertEqual(model.lastSavedRowsRevision,model.rowsRevision)
        XCTAssertEqual(model.gmail.accounts[0].cursor.historyID,"101")
    }
    @MainActor func testEncoderFailureDoesNotAdvanceHistory() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let model=model(root)
        model.rowsSnapshotEncoder={_ in throw NSError(domain:"ControlledDiskFailure",code:1)}
        do {try await model.ingestGmail(batch(),accountID:"fixture");XCTFail("The persistence failure was hidden")}
        catch {XCTAssertEqual(model.gmail.accounts[0].cursor.historyID,"100")}
    }
    @MainActor func testReceiptOnlyOverlayDoesNotMarkUnrelatedAvatarEditsSaved() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let model=model(root)
        model.rows=[SenderRow(email:EmailAddress("new@fixture.test")!,name:"New Sender")];model.save()
        model.rows[0].status="Unsaved avatar choice"
        try await model.ingestGmail(batch(),accountID:"fixture")
        XCTAssertNotEqual(model.lastSavedRowsRevision,model.rowsRevision)
        model.save()
        let saved=try JSONDecoder().decode([SenderRow].self,from:Data(contentsOf:model.stateURL))
        XCTAssertEqual(saved[0].status,"Unsaved avatar choice")
    }
    @MainActor func testNewerReceiptOverlaySurvivesAnOlderInFlightSnapshot() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let model=model(root),receipt=Date(timeIntervalSince1970:1_789_350_000)
        model.rows=[SenderRow(email:EmailAddress("other@fixture.test")!,name:"Other")];model.save()
        model.rowsSnapshotEncoder={snapshot in
            let i=model.rows.firstIndex(where:{$0.id=="other@fixture.test"})!
            model.rows[i].lastInboxReceivedAt=receipt
            try model.persistInboxReceiptOverlay(ids:["other@fixture.test"])
            return try JSONEncoder().encode(snapshot)
        }
        try await model.ingestGmail(batch(),accountID:"fixture")
        XCTAssertTrue(FileManager.default.fileExists(atPath:model.inboxReceiptOverlayURL.path))
        let reopened=self.model(root)
        XCTAssertEqual(reopened.rows.first(where:{$0.id=="other@fixture.test"})?.lastInboxReceivedAt,receipt)
        XCTAssertTrue(reopened.rows.contains(where:{$0.id=="new@fixture.test"}))
    }
}
