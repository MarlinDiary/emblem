import XCTest
import PortraitCore
@testable import Emblem

final class V092AppRegressionTests: XCTestCase {
    private func row(_ email: String, _ name: String) -> SenderRow {
        .init(email: EmailAddress(email)!, name: name)
    }

    func testAllRegisteredInstitutionMailboxesStayIndependent() {
        let rows = [
            row("one@vuw.ac.nz", "Victoria University of Wellington"),
            row("two@vuw.ac.nz", "Victoria University of Wellington")
        ]
        XCTAssertEqual(SenderGrouping.groups(rows).count, 2)
    }

    @MainActor
    func testActiveSearchSummaryIsVisibleAndClearable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(demo: true, rootOverride: root)
        model.rows = [row("one@first.org", "First"), row("two@second.org", "Second")]
        model.search = "first"
        XCTAssertEqual(model.visibleGroups.count, 1)
        XCTAssertEqual(model.senderListFooterSummary, "Filtered: 1 groups · 1 addresses")
        model.clearSenderSearch()
        XCTAssertEqual(model.visibleGroups.count, 2)
        XCTAssertTrue(model.search.isEmpty)
    }
}
