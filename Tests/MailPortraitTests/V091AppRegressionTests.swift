import XCTest
import AppKit
import PortraitCore
@testable import MailPortrait

final class V091AppRegressionTests: XCTestCase {
    private func row(_ email: String, _ name: String) -> SenderRow {
        .init(email: EmailAddress(email)!, name: name)
    }

    func testAucklandInstitutionMailboxesStayAsIndependentRows() {
        let rows = [
            row("studentinfo@auckland.ac.nz", "University of Auckland"),
            row("noreply@auckland.ac.nz", "University of Auckland")
        ]
        XCTAssertEqual(SenderGrouping.groups(rows).count, 2)
    }

    @MainActor
    func testLegacyLowResolutionCandidateIsPrunedOnOpen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let tiny = AvatarCandidate(source: .touchIcon, origin: "https://milkrun.com/apple-touch-icon.png", width: 32, height: 32, png: Data([1, 2, 3]))
        var saved = row("help@milkrun.com", "MILKRUN")
        saved.candidates = [tiny]; saved.selectedCandidate = tiny.id
        try JSONEncoder().encode([saved]).write(to: root.appendingPathComponent("senders.json"))

        let model = AppModel(demo: false, rootOverride: root)
        XCTAssertTrue(model.rows[0].candidates.isEmpty)
        XCTAssertNil(model.rows[0].selectedCandidate)
    }

    @MainActor
    func testPresentationOnlyBatchDoesNotRebuildGroupingSnapshot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(demo: true, rootOverride: root)
        model.rows = (0..<903).map { row("person\($0)@company\($0).com", "Person \($0)") }
        _ = model.visibleGroups
        let builds = model.visibleGroupingBuildCount
        var replacement = model.rows
        replacement[450].status = "自动找到头像 · 待确认"
        model.replaceRowsPreservingGrouping(replacement, changedIDs: [replacement[450].id])
        XCTAssertEqual(model.visibleGroupingBuildCount, builds)
        XCTAssertEqual(model.visibleGroupingSnapshot().rowByEmail[replacement[450].id]?.status, "自动找到头像 · 待确认")
    }
}
