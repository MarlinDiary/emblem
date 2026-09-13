import XCTest
import PortraitCore
@testable import Emblem

final class V0121AmazonMigrationTests: XCTestCase {
    @MainActor func testRealAmazonCacheChoosesExistingBrandWithoutContactWritesAndPreservesManualChoice() async throws {
        guard let file=ProcessInfo.processInfo.environment["EMBLEM_AMAZON_STATE"] else { throw XCTSkip("captured real Amazon cache opt-in") }
        let data=try Data(contentsOf:URL(fileURLWithPath:file))
        let baseline=try JSONDecoder().decode([SenderRow].self,from:data)
        XCTAssertEqual(baseline.count,6)
        XCTAssertTrue(baseline.allSatisfy { $0.email.domain == "amazon.com.au" && $0.chosen?.source == .monogram && $0.selectionIsManual != true })
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try data.write(to:root.appendingPathComponent("senders.json"))
        let model=AppModel(demo:true,rootOverride:root);model.automaticEnabled=false
        for row in model.rows { XCTAssertEqual(row.chosen?.source,.bimi,row.id) }
        await model.prepareAvatarQuality()
        for row in model.rows {
            XCTAssertEqual(row.chosen?.source,.bimi,row.id)
            XCTAssertNil(BatchPlanner.reviewReason(row),row.id)
            let original=try XCTUnwrap(baseline.first { $0.id==row.id }?.candidates.first { $0.source == .bimi })
            XCTAssertEqual(row.chosen?.id,original.id)
            XCTAssertEqual(row.chosen?.png,original.png)
        }
        XCTAssertEqual(Set(model.rows.map(\.id)),Set(baseline.map(\.id)))
        XCTAssertTrue(try model.engine.records().isEmpty)
        XCTAssertEqual(model.rows.filter { $0.chosen?.source == .bimi }.count,6)
        model.save()
        let reopened=AppModel(demo:true,rootOverride:root)
        XCTAssertEqual(reopened.rows.filter { $0.chosen?.source == .bimi }.count,6)
        var manual=baseline;manual[0].selectionIsManual=true
        try JSONEncoder().encode(manual).write(to:root.appendingPathComponent("senders.json"))
        let preserved=AppModel(demo:true,rootOverride:root)
        await preserved.prepareAvatarQuality()
        XCTAssertEqual(preserved.rows.first{$0.id==baseline[0].id}?.selectedCandidate,baseline[0].selectedCandidate)
        XCTAssertEqual(preserved.rows.first{$0.id==baseline[0].id}?.chosen?.source,.monogram)
        XCTAssertEqual(preserved.rows.filter { $0.chosen?.source == .bimi }.count,5)
        print("REAL_AMAZON ROWS=6 AUTO_BIMI=\(model.rows.filter { $0.chosen?.source == .bimi }.count) REOPEN_BIMI=\(reopened.rows.filter { $0.chosen?.source == .bimi }.count) MANUAL_MONOGRAM=\(preserved.rows.first{$0.id==baseline[0].id}?.chosen?.source.rawValue ?? "none") CONTACT_WRITES=0 ORIGINAL_PNG_AND_IDS=UNCHANGED")
    }
}
