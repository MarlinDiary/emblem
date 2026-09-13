import XCTest
import PortraitCore
@testable import Emblem

final class BatchWorkflowTests: XCTestCase {
    func row(_ email: String, name: String = "Anthropic", source: CandidateSource = .touchIcon) -> SenderRow {
        let c = AvatarCandidate(source: source, origin: "https://anthropic.com/apple-touch-icon.png", width: 256, height: 256, png: Data([1,2,3]))
        return SenderRow(email: EmailAddress(email)!, name: name, candidates: [c], selectedCandidate: c.id)
    }
    func testReadyAndReviewAreDisjoint() {
        let good = row("hello@anthropic.com")
        var missing = good; missing.candidates = []
        var existing = good; existing.current = .init(id: "existing", name: "Existing", emails: [good.id], image: Data([9]))
        let fallback = row("support@bellroy.com", source: .domainIcon)
        XCTAssertTrue(BatchPlanner.isReady(good)); XCTAssertFalse(BatchPlanner.isReady(missing))
        XCTAssertFalse(BatchPlanner.isReady(existing)); XCTAssertFalse(BatchPlanner.isReady(fallback))
        XCTAssertEqual(BatchPlanner.plan([good, missing, existing, fallback]).jobs.count, 1)
    }
    func test134BrandAliasesBecomeOneCardButPeopleStaySeparate() {
        let brands = (0..<134).map { row("code\($0)@anthropic.com") }
        let people = [row("a@auckland.ac.nz", name: "University of Auckland"), row("b@auckland.ac.nz", name: "University of Auckland")]
        let plan = BatchPlanner.plan(brands + people)
        XCTAssertEqual(plan.jobs.count, 3); XCTAssertEqual(plan.emailCount, 136)
        XCTAssertEqual(plan.newContactCount, 3)
        XCTAssertEqual(BatchPlanner.plan(brands, groupBrands: false).jobs.count, 134)
    }
    func testSeparateContactsAndConflictingPicturesNeverMerge() {
        var a = row("hello@anthropic.com"), b = row("team@anthropic.com")
        a.current = .init(id: "a", name: a.name, emails: [a.id], image: nil)
        b.current = .init(id: "b", name: b.name, emails: [b.id], image: nil)
        XCTAssertEqual(BatchPlanner.plan([a,b]).jobs.count, 2)
        b.current = a.current; b.candidates[0].png = Data([9])
        let conflict = BatchPlanner.plan([a,b])
        XCTAssertEqual(conflict.jobs.count, 0); XCTAssertEqual(conflict.excluded.count, 2)
    }
    func test900RowsNeedOnePlanAndKeepStableOrder() {
        let rows = (0..<900).map { row("staff\($0)@vuw.ac.nz", name: "Staff \($0)", source: .institutionProfile) }
        let plan = BatchPlanner.plan(rows)
        XCTAssertEqual(plan.jobs.count, 900); XCTAssertEqual(plan.emailCount, 900)
        XCTAssertEqual(plan.jobs.first?.rows.first?.id, rows.first?.id)
        XCTAssertEqual(plan.jobs.last?.rows.first?.id, rows.last?.id)
    }
    @MainActor func model() -> AppModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("batch-test-" + UUID().uuidString)
        let m = AppModel(demo: true, rootOverride: root); m.automaticEnabled = false
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return m
    }
    @MainActor func finish(_ m: AppModel) async throws {
        for _ in 0..<3000 { if !m.busy { return }; try await Task.sleep(nanoseconds: 2_000_000) }
        XCTFail("batch did not finish")
    }
    @MainActor func testOneConfirmationApplyAndBatchUndo() async throws {
        let m = model(); m.rows = (0..<134).map { row("code\($0)@anthropic.com") }
        m.prepareBatch(ids: m.rows.map(\.id)); XCTAssertTrue(m.showBatchConfirmation)
        XCTAssertEqual(m.batchPlan?.jobs.count, 1); XCTAssertFalse(m.batchAllowCreate)
        m.batchAllowCreate = true; m.confirmBatch(); try await finish(m)
        XCTAssertEqual(m.rows.filter(\.completed).count, 134)
        XCTAssertEqual((m.port as! FixtureContactStore).contacts.count, 1)
        let batch = try XCTUnwrap(m.latestBatchID)
        XCTAssertEqual(m.records.first?.batchID, batch)
        m.undoBatch(batch); try await finish(m)
        XCTAssertEqual((m.port as! FixtureContactStore).contacts.count, 0)
        XCTAssertEqual(m.rows.filter(\.ignored).count, 134)
        XCTAssertEqual(m.records.first?.state, .undone)
    }
    @MainActor func testFreshContactChangeIsSkippedAndOtherJobsContinue() async throws {
        let m = model(); m.rows = [row("a@auckland.ac.nz"), row("b@auckland.ac.nz")]
        m.prepareBatch(ids: m.rows.map(\.id)); m.batchAllowCreate = true
        _ = try m.port.create(name: "New external contact", email: m.rows[0].id, image: Data([8]))
        m.confirmBatch(); try await finish(m)
        XCTAssertEqual(m.batchProgress?.succeeded, 1); XCTAssertEqual(m.batchProgress?.issues.count, 1)
        XCTAssertFalse(m.rows[0].completed); XCTAssertTrue(m.rows[1].completed)
        XCTAssertEqual(try m.port.matches(email: m.rows[0].id).first?.image, Data([8]))
    }
    @MainActor func testCancellationKeepsFinishedWorkAndResumeExcludesIt() async throws {
        let m = model(); m.rows = (0..<60).map { row("staff\($0)@vuw.ac.nz") }
        m.prepareBatch(ids: m.rows.map(\.id)); m.batchAllowCreate = true; m.confirmBatch()
        while (m.batchProgress?.processed ?? 0) < 2 { try await Task.sleep(nanoseconds: 1_000_000) }
        m.cancel(); try await finish(m)
        let done = m.rows.filter(\.completed).count
        XCTAssertGreaterThan(done, 0); XCTAssertLessThan(done, 60)
        XCTAssertTrue(m.batchProgress?.cancelled == true)
        m.prepareBatch(ids: m.rows.map(\.id)); XCTAssertEqual(m.batchPlan?.emailCount, 60 - done)
        XCTAssertEqual(try m.engine.records().filter { $0.state == .applied }.count, done)
    }
    @MainActor func testReadyCacheMovesNewImagesIntoSection() {
        let m = model(); var missing = row("a@anthropic.com"); missing.candidates = []; m.rows = [missing]; m.section = "ready"
        XCTAssertTrue(m.visibleRows.isEmpty)
        let good = row("a@anthropic.com")
        m.replaceRowsPreservingGrouping([good], changedIDs: [good.id])
        XCTAssertEqual(m.visibleRows.count, 1)
        m.section = "review"; XCTAssertTrue(m.visibleRows.isEmpty)
    }
    @MainActor func testSharedContactIsUpdatedOnceAndOtherFieldsPreserved() async throws {
        let m = model(); var a = row("one@icloud.com", name: "Elliott Wen", source: .gravatar)
        var b = a; b.email = EmailAddress("two@outlook.com")!
        let store = m.port as! FixtureContactStore
        let contact = ContactSnapshot(id: "person", name: "Keep this name", emails: [a.id,b.id,"third@gmail.com"], image: nil)
        store.contacts[contact.id] = contact; a.current = contact; b.current = contact; m.rows = [a,b]
        m.prepareBatch(ids: m.rows.map(\.id)); XCTAssertEqual(m.batchPlan?.jobs.count, 1)
        m.confirmBatch(); try await finish(m)
        XCTAssertEqual(m.records.count, 1); XCTAssertEqual(store.contacts[contact.id]?.name, contact.name)
        XCTAssertEqual(store.contacts[contact.id]?.emails, contact.emails)
    }
    @MainActor func testExistingPhotoAndExternalChangesSurviveUndo() async throws {
        let m = model(); m.rows = [row("a@auckland.ac.nz"),row("b@auckland.ac.nz")]
        m.prepareBatch(ids: m.rows.map(\.id)); m.batchAllowCreate = true; m.confirmBatch(); try await finish(m)
        let batch = try XCTUnwrap(m.latestBatchID)
        let firstID = try XCTUnwrap(m.rows[0].current?.id)
        _ = try m.port.setImage(id: firstID, image: Data([8]))
        m.undoBatch(batch); try await finish(m)
        XCTAssertEqual(m.batchProgress?.succeeded, 1); XCTAssertEqual(m.batchProgress?.issues.count, 1)
        XCTAssertEqual(try m.port.get(id: firstID)?.image, Data([8]))
    }
    @MainActor func testSearchAndSelectionLimitBatchScope() {
        let m = model(); m.rows = [row("a@auckland.ac.nz", name: "Alice"), row("b@vuw.ac.nz", name: "Bob")]
        m.search = "Alice"; XCTAssertEqual(m.batchScopeIDs, [m.rows[0].id])
        m.search = ""; m.batchMode = true; m.selectedForBatch = [m.rows[1].id]
        XCTAssertEqual(m.batchScopeIDs, [m.rows[1].id])
    }
    @MainActor func testJournalRecoversGroupedApplyAndUndoWithStaleSenderCache() async throws {
        let m = model(); m.rows = (0..<40).map { row("code\($0)@anthropic.com") }; m.save()
        let stale = try Data(contentsOf: m.stateURL)
        m.prepareBatch(ids: m.rows.map(\.id)); m.batchAllowCreate = true; m.confirmBatch(); try await finish(m)
        let batch = try XCTUnwrap(m.latestBatchID)
        try stale.write(to: m.stateURL, options: .atomic)
        let relaunched = AppModel(demo: true, rootOverride: m.root)
        XCTAssertEqual(relaunched.rows.filter(\.completed).count, 40)
        XCTAssertEqual(relaunched.latestBatchID, batch)
        relaunched.undoBatch(batch); try await finish(relaunched)
        try stale.write(to: m.stateURL, options: .atomic)
        let afterUndo = AppModel(demo: true, rootOverride: m.root)
        XCTAssertEqual(afterUndo.rows.filter(\.ignored).count, 40)
        XCTAssertEqual(afterUndo.rows.filter(\.completed).count, 0)
    }
    @MainActor func testHundredsOfIndependentCardsApplyWithoutIndividualConfirmation() async throws {
        let m = model(); m.rows = (0..<220).map { row("staff\($0)@auckland.ac.nz", name: "Staff \($0)", source: .institutionProfile) }
        m.prepareBatch(ids: m.rows.map(\.id)); m.batchAllowCreate = true
        m.confirmBatch(); try await finish(m)
        XCTAssertEqual(m.rows.filter(\.completed).count, 220)
        XCTAssertEqual(m.batchProgress?.succeeded, 220)
        XCTAssertEqual((m.port as! FixtureContactStore).contacts.count, 220)
        XCTAssertEqual(Set(m.records.compactMap(\.batchID)).count, 1)
        m.prepareBatch(ids: m.rows.map(\.id)); XCTAssertFalse(m.showBatchConfirmation)
        print("BATCH_FIXTURE CONFIRMATIONS=1 CARDS=220 APPLIED=220 DUPLICATE_WRITES=0 REAL_CONTACTS_WRITTEN=0")
    }

}
