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

private actor EncodeCounter {
    private(set) var count=0
    func record() {count += 1}
}
