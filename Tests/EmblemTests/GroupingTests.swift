import XCTest
import PortraitCore
@testable import Emblem

final class GroupingTests: XCTestCase {
    private func row(_ email: String, _ name: String = "Anthropic") -> SenderRow { .init(email:EmailAddress(email)!,name:name) }
    func testSameNameAndRegistrableDomainGroupWithoutLosingEmails() {
        let rows = [row("hello@anthropic.com"),row("news@mail.anthropic.com","  ANTHROPIC  ")]
        let groups = SenderGrouping.groups(rows)
        XCTAssertEqual(groups.count,1); XCTAssertEqual(groups[0].members.map(\.id),rows.map(\.id))
        XCTAssertEqual(SenderGrouping.groups([rows[0],row("hello@github.com")]).count,2)
        var explicit = rows[0]; explicit.website = "https://anthropic.com"
        XCTAssertEqual(SenderGrouping.groups([explicit,rows[1]]).count,1, "Explicit root and inferred root are the same website")
    }
    func testSharedProviderDefaultNamesAndContactsAreNotCombined() {
        XCTAssertEqual(SenderGrouping.groups([row("one@gmail.com","Alex"),row("two@gmail.com","Alex")]).count,2)
        XCTAssertEqual(SenderGrouping.groups([row("news@anthropic.com","news"),row("news@mail.anthropic.com","news")]).count,2)
        var first = row("one@anthropic.com"), second = row("two@anthropic.com")
        first.current = .init(id:"1",name:"Anthropic",emails:[first.id],image:nil)
        second.current = .init(id:"2",name:"Anthropic",emails:[second.id],image:nil)
        XCTAssertEqual(SenderGrouping.groups([first,second]).count,2)
        first.current = nil; second.current = nil; second.website = "https://github.com/"
        XCTAssertEqual(SenderGrouping.groups([first,second]).count,2)
    }
    @MainActor func testAliasSearchSelectionAndGroupActionsPreserveJournal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let m = AppModel(demo:true,rootOverride:root)
        m.rows = [row("hello@anthropic.com"),row("news@mail.anthropic.com")]
        m.selectedID = m.rows[1].id; m.search = "news@mail"
        XCTAssertEqual(m.visibleGroups.count,1); XCTAssertEqual(m.visibleRows.count,2)
        let group = try XCTUnwrap(m.selectedGroup)
        m.selectedListID = group.id; m.reconcileSelection()
        XCTAssertEqual(m.selectedID,"news@mail.anthropic.com")
        m.selectGroup(group,enabled:true); XCTAssertEqual(m.selectedForBatch.count,2)
        m.selectGroup(group,enabled:false); XCTAssertTrue(m.selectedForBatch.isEmpty)
        m.ignoreGroup(group); XCTAssertEqual(m.ignoredCount,2)
        m.section = "ignored"; m.reconcileSelection(); m.removeGroup(try XCTUnwrap(m.visibleGroups.first))
        XCTAssertTrue(m.rows.isEmpty); XCTAssertEqual(m.automation.excludedEmails?.count,2)
        XCTAssertTrue(try m.engine.records().isEmpty)
    }
    @MainActor func testApplyIsDeferredWhileScanIsActive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let m = AppModel(demo:true,rootOverride:root)
        m.rows = [row("hello@anthropic.com")]; m.scanActive = true
        m.prepareApply(ids:m.rows.map(\.id))
        XCTAssertFalse(m.showApplyConfirmation); XCTAssertTrue(m.pendingIDs.isEmpty)
        XCTAssertTrue(try m.engine.records().isEmpty)
    }
}
