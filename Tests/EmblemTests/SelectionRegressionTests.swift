import XCTest
@testable import Emblem

final class SelectionRegressionTests: XCTestCase {
    @MainActor func testFilteredDetailNeverShowsUnmatchedSender() async throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        let model=AppModel(demo:true,rootOverride:dir)
        model.loadDemo()
        model.selectedID=model.rows[0].id
        model.search=model.rows[1].email.value
        XCTAssertTrue(model.selected == nil || model.visibleRows.contains { $0.id == model.selected?.id }, "Filtered list must never display another sender's details")
    }
}
