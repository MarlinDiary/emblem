import XCTest
import PortraitCore
@testable import Emblem

final class BulkImportRegressionTests: XCTestCase {
    @MainActor func testBulkIngestionDoesNotSilentlyStopAtTwoHundred() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(demo: true, rootOverride: root)
        let input = (0..<451).map { "sender\($0)@example.org" }.joined(separator: "\n")
        model.importAddresses(input)
        XCTAssertEqual(model.rows.count, 451)
        model.importAddresses(input)
        XCTAssertEqual(model.rows.count, 451)
        XCTAssertTrue(try model.engine.records().isEmpty)
    }
}
