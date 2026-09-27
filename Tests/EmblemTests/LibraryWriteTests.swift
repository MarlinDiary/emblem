import XCTest
import PortraitCore
@testable import Emblem

/// Every save rewrites the whole library, so bookkeeping churn must not save per
/// batch: a measured helper pass rewrote 91.7 MB up to nine times in 32 seconds
/// while only two rows had changed.
final class LibraryWriteTests:XCTestCase {
    @MainActor private func model()throws->(AppModel,URL) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("library-write-"+UUID().uuidString)
        let m=AppModel(demo:true,rootOverride:root,backgroundWorkAllowed:false)
        m.rows=(0..<12).map { SenderRow(email:EmailAddress("person\($0)@company.org")!,name:"Person \($0)") }
        return (m,root)
    }

    @MainActor func testProvisionalMonogramsShareOneRewrite()async throws {
        let (m,root)=try model();defer{try? FileManager.default.removeItem(at:root)}
        let counter=EncodeCounter()
        m.rowsSnapshotEncoder={rows in await counter.record();return try RowsPersistence.encode(rows)}
        await m.prepareNameFallbacks(limit:3)
        await m.prepareNameFallbacks(limit:6)
        await m.prepareNameFallbacks(limit:12)
        XCTAssertGreaterThan(m.rows.filter{$0.chosen != nil}.count,3,"The batches produced provisional photos")
        var encodes=await counter.count
        XCTAssertEqual(encodes,0,"Provisional monograms wait for a durable boundary")
        try await m.saveAsync()
        encodes=await counter.count
        XCTAssertEqual(encodes,1,"One rewrite covers every batch")
    }

    @MainActor func testDeferredSaveStillReachesDiskOnItsOwn()async throws {
        let (m,root)=try model();defer{try? FileManager.default.removeItem(at:root)}
        let counter=EncodeCounter()
        m.rowsSnapshotEncoder={rows in await counter.record();return try RowsPersistence.encode(rows)}
        m.deferredSaveInterval=0.15
        m.rows[0].name="Renamed"
        m.saveSoon()
        for _ in 0..<40 where await counter.count == 0 {try await Task.sleep(for:.milliseconds(50))}
        let encodes=await counter.count
        XCTAssertEqual(encodes,1,"A deferred save must not be lost")
        XCTAssertEqual(m.lastSavedRowsRevision,m.rowsRevision)
    }

    @MainActor func testDurableBoundaryCancelsThePendingRewrite()async throws {
        let (m,root)=try model();defer{try? FileManager.default.removeItem(at:root)}
        let counter=EncodeCounter()
        m.rowsSnapshotEncoder={rows in await counter.record();return try RowsPersistence.encode(rows)}
        m.deferredSaveInterval=0.15
        m.rows[0].name="Renamed"
        m.saveSoon()
        try await m.saveAsync()
        try await Task.sleep(for:.milliseconds(400))
        let encodes=await counter.count
        XCTAssertEqual(encodes,1,"The flush replaces the pending rewrite instead of adding one")
    }
}

extension LibraryWriteTests {
    /// The journal is read and rewritten in full for every Contacts mutation.
    @MainActor func testJournalIsWrittenCompactly()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("journal-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let url=root.appendingPathComponent("changes.json")
        let journal=FileJournal(url:url)
        let store=try FixtureContactStore()
        let engine=ChangeEngine(store:store,journal:journal)
        let candidate=try NameAvatar.candidate(name:"Fixture Person")
        _=try engine.apply(email:EmailAddress("person@fixture.org")!,name:"Fixture Person",candidate:candidate,allowCreate:true)
        let text=try String(contentsOf:url,encoding:.utf8)
        XCTAssertFalse(text.contains("\n  "),"Pretty printing inflates every rewrite of the journal")
        XCTAssertEqual(try journal.read().count,1)
    }
}

private actor EncodeCounter {
    private(set) var count=0
    func record() {count += 1}
}

extension LibraryWriteTests {
    /// Measured on the installed build58 with the app closed: 30 minutes of helper
    /// passes rewrote the 3.64 MB library 53 times while the change journal recorded
    /// one Contacts write. Every lookup result and every provisional monogram kicks a
    /// sync pass, and each pass flushed the whole library whether or not it had
    /// written anything to Contacts.
    @MainActor func testASyncPassThatAppliesNothingLeavesTheRewriteDeferred()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("sync-write-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let m=AppModel(demo:true,rootOverride:root,backgroundWorkAllowed:false)
        let photo=try NameAvatar.candidate(name:"SevenRooms")
        m.rows=[SenderRow(email:EmailAddress("hello@sevenrooms.com")!,name:"SevenRooms",candidates:[photo],selectedCandidate:photo.id,discoveredAt:Date())]
        m.mailSync.enabled=true
        let counter=EncodeCounter()
        m.rowsSnapshotEncoder={rows in await counter.record();return try RowsPersistence.encode(rows)}

        try await m.performMailSync()
        XCTAssertEqual(try m.engine.records().count,1,"The first pass writes one contact")
        var encodes=await counter.count
        XCTAssertEqual(encodes,1,"A completed Contacts write is a durable boundary")

        // Each pass is preceded by the bookkeeping that kicked it: a finished lookup
        // stores its result, status and retry stamp on rows it cannot apply anywhere.
        for attempt in 0..<6 {
            m.rows[0].status="No photo yet; lookup will retry (\(attempt))."
            m.rows[0].lastLookup=Date()
            try await m.performMailSync()
        }
        encodes=await counter.count
        XCTAssertEqual(encodes,1,"Passes that apply nothing must not rewrite the library")
        XCTAssertEqual(try m.engine.records().count,1,"No extra Contacts writes were made")
        XCTAssertNotEqual(m.lastSavedRowsRevision,m.rowsRevision,"Their bookkeeping is still pending, not lost")

        try await m.saveAsync()
        encodes=await counter.count
        XCTAssertEqual(encodes,2,"One flush covers every deferred pass")
        XCTAssertEqual(m.lastSavedRowsRevision,m.rowsRevision)
    }
}
