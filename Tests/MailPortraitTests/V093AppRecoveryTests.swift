import XCTest
import PortraitCore
@testable import MailPortrait

final class V093AppRecoveryTests: XCTestCase {
    @MainActor
    func testOpeningDoesNotRefreshAnExistingManualReviewCandidate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var row = SenderRow(email: EmailAddress("review@brand.test")!, name: "Brand")
        let wide = AvatarCandidate(source: .siteLogo, origin: "fixture", width: 800, height: 200, png: Data([1]))
        row.candidates = [wide]
        row.lookupPolicy = AutomaticLookupPolicy.key(row, website: true, gravatar: false)
        row.lastLookup = Date()
        let savedPolicy = row.lookupPolicy
        try JSONEncoder().encode([row]).write(to: root.appendingPathComponent("senders.json"), options: .atomic)

        let model = AppModel(demo: false, rootOverride: root)
        XCTAssertEqual(model.rows[0].lookupPolicy, savedPolicy)
        XCTAssertNil(model.rows[0].selectedCandidate)
        XCTAssertFalse(AutomaticLookupPolicy.due(model.rows[0], website: true, gravatar: false, now: Date()))
    }

    func testNewRecoveryPolicyRefreshesOnlyRowsThatStillHaveNoCandidate() {
        let now = Date()
        var missing = SenderRow(email: EmailAddress("hello@brand.test")!, name: "Brand")
        missing.lookupPolicy = "v092|true|false|brand.test"
        missing.lastLookup = now

        var ready = SenderRow(email: EmailAddress("ready@brand.test")!, name: "Brand")
        let image = AvatarCandidate(source: .touchIcon, origin: "fixture", width: 256, height: 256, png: Data([1]))
        ready.candidates = [image]
        ready.selectedCandidate = image.id
        ready.lookupPolicy = AutomaticLookupPolicy.key(ready, website: true, gravatar: false)
        ready.lastLookup = now

        XCTAssertTrue(AutomaticLookupPolicy.due(missing, website: true, gravatar: false, now: now))
        XCTAssertFalse(AutomaticLookupPolicy.due(ready, website: true, gravatar: false, now: now))
    }

    func testWeakSourceFailureDoesNotHourlyRefreshAnExistingChosenImage() {
        let now = Date()
        var ready = SenderRow(email: EmailAddress("ready@brand.test")!, name: "Brand")
        let image = AvatarCandidate(source: .touchIcon, origin: "fixture", width: 256, height: 256, png: Data([1]))
        ready.candidates = [image]
        ready.selectedCandidate = image.id
        ready.lookupPolicy = AutomaticLookupPolicy.key(ready, website: true, gravatar: false)
        ready.lastLookup = now.addingTimeInterval(-2 * 3600)
        ready.sourceReports = [.init(.favicon, .unavailable, detail: "weaker fallback failed")]
        XCTAssertFalse(AutomaticLookupPolicy.due(ready, website: true, gravatar: false, now: now))
    }

    func testInstitutionAliasMailboxesRemainSeparateRows() {
        let rows = [
            SenderRow(email: EmailAddress("one@aucklanduni.ac.nz")!, name: "University of Auckland"),
            SenderRow(email: EmailAddress("two@aucklanduni.ac.nz")!, name: "University of Auckland")
        ]
        XCTAssertEqual(SenderGrouping.groups(rows).count, 2)
    }
}
