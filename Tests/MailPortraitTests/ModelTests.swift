import XCTest
import PortraitCore
@testable import MailPortrait

final class ModelTests: XCTestCase {
    @MainActor func makeModel(demo: Bool = true) -> (AppModel, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mailportrait-model-" + UUID().uuidString)
        return (AppModel(demo: demo, rootOverride: root), root)
    }
    @MainActor func settle(_ model: AppModel) async throws {
        for _ in 0..<1000 { if !model.busy { return }; await Task.yield() }
        XCTFail("model did not settle")
    }
    @MainActor func testDemoOpensCompleteGalleryWithoutPermissions() async throws {
        let (m, dir) = makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        m.loadDemo()
        XCTAssertEqual(m.activeCount, 6); XCTAssertEqual(m.section, "all"); XCTAssertEqual(m.selected?.name, "Orbit")
        XCTAssertTrue(m.contactsConnected); XCTAssertTrue(m.port is FixtureContactStore)
        XCTAssertFalse(m.useWebsite); XCTAssertFalse(m.useGravatar)
        XCTAssertTrue(m.rows.allSatisfy { $0.candidates.count == 2 && $0.chosen != nil })
    }
    @MainActor func testSearchNeverShowsStaleSelection() async throws {
        let (m, dir) = makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        m.loadDemo(); m.search = "Paperplane"; m.reconcileSelection()
        XCTAssertEqual(m.visibleRows.count, 1); XCTAssertEqual(m.selected?.name, "Paperplane")
        m.search = "no-such-sender"; m.reconcileSelection(); XCTAssertNil(m.selected); XCTAssertNil(m.selectedID)
    }
    @MainActor func testSectionChangeReconcilesSelectionAndBatch() async throws {
        let (m, dir) = makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        m.loadDemo(); let id = m.selectedID!; m.selectedForBatch = [id]; m.ignore(id, ignored: true); m.reconcileSelection()
        XCTAssertNotEqual(m.selectedID, id); XCTAssertTrue(m.selectedForBatch.isEmpty)
        m.section = "ignored"; m.reconcileSelection(); XCTAssertEqual(m.selectedID, id)
    }
    @MainActor func testNetworkConsentPrecedesFirstLookup() async throws {
        let (m, dir) = makeModel(demo: false); defer { try? FileManager.default.removeItem(at: dir) }
        m.importAddresses("hello@company.org"); m.requestLookup(ids: [m.selectedID!])
        XCTAssertTrue(m.showSourceConsent); XCTAssertFalse(m.busy); XCTAssertFalse(m.useWebsite); XCTAssertFalse(m.useGravatar)
    }
    @MainActor func testExplicitWebsiteNeedsItsOwnConsent() async throws {
        let (m, dir) = makeModel(demo: false); defer { try? FileManager.default.removeItem(at: dir) }
        m.useGravatar = true; m.importAddresses("hello@company.org"); m.requestLookup(ids: [m.selectedID!], requiresWebsite: true)
        XCTAssertTrue(m.showSourceConsent); XCTAssertFalse(m.busy); XCTAssertFalse(m.useWebsite)
    }
    @MainActor func testConnectGateDoesNotWriteOrAskOSByItself() async throws {
        let (m, dir) = makeModel(demo: false); defer { try? FileManager.default.removeItem(at: dir) }
        m.importAddresses("hello@company.org")
        let picture = AvatarCandidate(source: .manual, origin: "fixture", width: 180, height: 180, png: Data([1]))
        m.rows[0].candidates = [picture]; m.rows[0].selectedCandidate = picture.id
        m.prepareApply(ids: [m.rows[0].id])
        XCTAssertTrue(m.showContactConsent); XCTAssertFalse(m.showApplyConfirmation); XCTAssertFalse(m.busy)
        XCTAssertTrue(try m.engine.records().isEmpty)
    }
    @MainActor func testApplyAlwaysResetsCreationConsent() async throws {
        let (m, dir) = makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        m.loadDemo(); m.allowCreate = true; m.prepareApply(ids: [m.selectedID!])
        XCTAssertFalse(m.allowCreate); XCTAssertTrue(m.showApplyConfirmation)
    }
    @MainActor func testNativeFlowApplyUndoAndIgnore() async throws {
        let (m, dir) = makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        m.loadDemo(); let id = m.selectedID!; m.prepareApply(ids: [id]); m.allowCreate = true; m.confirmApply(); try await settle(m)
        XCTAssertEqual(m.appliedCount, 1); XCTAssertEqual(m.records.count, 1); XCTAssertNil(m.errorText)
        m.undo(m.records[0]); try await settle(m)
        XCTAssertEqual(m.records[0].state, .undone); XCTAssertEqual(m.ignoredCount, 1); XCTAssertEqual(m.appliedCount, 0)
        XCTAssertNil(try m.port.get(id: m.records[0].contactID!))
    }
    @MainActor func testBusyPreventsRemovingLookupRows() async throws {
        let (m, dir) = makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        m.loadDemo(); let id = m.selectedID!; m.busy = true; m.removeFromList(id); m.ignore(id, ignored: true)
        XCTAssertEqual(m.rows.count, 6); XCTAssertEqual(m.ignoredCount, 0)
    }
    @MainActor func testModeSwitchIsIsolatedAndRemembersEachModeConsent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = AppSession(arguments: ["test", "--demo"], isolatedRoot: root)
        session.model.useWebsite = true; session.switchMode(demo: false)
        XCTAssertFalse(session.model.demo); XCTAssertTrue(session.model.rows.isEmpty); XCTAssertFalse(session.model.useWebsite)
        XCTAssertEqual(session.model.root, root.appendingPathComponent("main"))
        session.switchMode(demo: true); XCTAssertEqual(session.model.rows.count, 6); XCTAssertTrue(session.model.useWebsite)
    }
    @MainActor func testImportRetainsSenderDisplayName() async throws {
        let (m, dir) = makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        m.importAddresses("\"Alice Chen\" <alice@example.org>\nbob@example.org")
        XCTAssertEqual(m.rows.map(\.name), ["bob", "Alice Chen"])
    }
    @MainActor func testRemovingSenderDoesNotRemoveHistoryOrContact() async throws {
        let (m, dir) = makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        m.loadDemo(); let id=m.selectedID!; m.prepareApply(ids: [id]); m.allowCreate=true; m.confirmApply(); try await settle(m)
        let record=m.records[0]; m.removeFromList(id)
        XCTAssertNotNil(try m.port.get(id: record.contactID!)); XCTAssertEqual(try m.engine.records().count,1)
        let reopened=AppModel(demo: true, rootOverride: dir)
        XCTAssertFalse(reopened.rows.contains { $0.id==id }); XCTAssertEqual(reopened.records.count,1)
    }
    @MainActor func testHistorySearchClearsUnmatchedDetail() async throws {
        let (m, dir) = makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        m.loadDemo(); m.prepareApply(ids:[m.selectedID!]); m.allowCreate=true; m.confirmApply(); try await settle(m)
        m.section="history"; m.search="Orbit"; m.reconcileSelection()
        XCTAssertEqual(m.visibleRecords.count,1); XCTAssertNotNil(m.selectedHistory)
        m.search="not-a-record"; m.reconcileSelection()
        XCTAssertTrue(m.visibleRecords.isEmpty); XCTAssertNil(m.selectedHistory)
    }
}
