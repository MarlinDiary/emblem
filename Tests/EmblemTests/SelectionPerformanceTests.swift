import XCTest
import PortraitCore
@testable import Emblem

final class SelectionPerformanceTests: XCTestCase {
    @MainActor
    func testRepeatedSelectionReadsStayInteractive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(demo: true, rootOverride: root)
        model.rows = (0..<903).map { index in
            SenderRow(email: EmailAddress("person\(index)@company\(index).com")!, name: "Person \(index)")
        }
        _ = model.visibleGroups
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for index in 0..<150 {
                model.selectedID = model.rows[index].id
                _ = model.selectedListID
                _ = model.selectedGroup
                _ = model.selected
            }
        }
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        print("SELECTION_BENCHMARK seconds=\(seconds) rows=903 iterations=150")
        XCTAssertLessThan(seconds, 0.25, "Selecting must not rebuild and resort all 903 senders")
    }

    @MainActor
    func testSelectionReusesSnapshotAndContentChangesInvalidateIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(demo: true, rootOverride: root)
        model.rows = (0..<20).map { index in
            SenderRow(email: EmailAddress("person\(index)@company\(index).com")!, name: "Person \(index)")
        }

        _ = model.visibleGroups
        let firstBuildCount = model.visibleGroupingBuildCount
        for row in model.rows {
            model.selectedID = row.id
            XCTAssertEqual(model.selected?.id, row.id)
            XCTAssertNotNil(model.selectedGroup)
            XCTAssertNotNil(model.selectedListID)
        }
        XCTAssertEqual(model.visibleGroupingBuildCount, firstBuildCount)

        model.rows[0].name = "Renamed Person"
        _ = model.visibleGroups
        XCTAssertEqual(model.visibleGroupingBuildCount, firstBuildCount + 1)
        model.search = "Renamed"
        XCTAssertEqual(model.visibleRows.map(\.id), ["person0@company0.com"])
        XCTAssertEqual(model.visibleGroupingBuildCount, firstBuildCount + 2)
        model.section = "ignored"
        XCTAssertTrue(model.visibleGroups.isEmpty)
        XCTAssertEqual(model.visibleGroupingBuildCount, firstBuildCount + 3)
    }

    @MainActor
    func testPortraitImageCacheReusesDecodedImage() throws {
        let candidate = try DemoImages.candidate(symbol: "person.crop.circle", color: .systemBlue)
        let first = try XCTUnwrap(PortraitImageCache.shared.image(for: candidate.png))
        let second = try XCTUnwrap(PortraitImageCache.shared.image(for: candidate.png))
        XCTAssertTrue(first === second)
    }
}
