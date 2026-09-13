import XCTest
import PortraitCore
@testable import MailPortrait

@MainActor private final class GroupJournal: JournalPort {
    var records:[ChangeRecord]=[]
    func read() throws -> [ChangeRecord] { records }
    func write(_ records:[ChangeRecord]) throws { self.records=records }
}
final class ManagedIdentityTests:XCTestCase {
    @MainActor fileprivate func fixture() throws -> (FixtureContactStore,GroupJournal,ChangeEngine,AvatarCandidate) {
        let store=try FixtureContactStore(),journal=GroupJournal(),image=AvatarCandidate(source:.favicon,origin:"fixture",width:256,height:256,png:Data([1,2,3]),framing:.brandSafe)
        return (store,journal,ChangeEngine(store:store,journal:journal),image)
    }
    @MainActor func testGroupCreatesOneContactForManyEmailsAndUndoRemovesOnlyThatCard() throws {
        let (store,journal,engine,image)=try fixture()
        let emails=[EmailAddress("code-1@company.org")!,EmailAddress("code-2@company.org")!]
        let record=try engine.applyGroup(emails:emails,name:"Company",candidate:image,allowCreate:true,managedKey:"company|company.org")
        XCTAssertEqual(store.contacts.count,1);XCTAssertEqual(Set(store.contacts.values.first!.emails),Set(emails.map(\.value)))
        XCTAssertEqual(journal.records.count,1);XCTAssertEqual(record.managedKey,"company|company.org")
        try engine.undo(id:record.id);XCTAssertTrue(store.contacts.isEmpty)
    }
    @MainActor func testExistingContactPhotoIsPreservedAndAliasesAreReversible() throws {
        let (store,_,engine,image)=try fixture()
        let original=try store.create(name:"Company",email:"first@company.org",image:Data([9]))
        let record=try engine.applyGroup(emails:[EmailAddress("first@company.org")!,EmailAddress("next@company.org")!],name:"Company",candidate:image,allowCreate:false,managedKey:nil)
        XCTAssertEqual(store.contacts[original.id]?.image,Data([9]));XCTAssertEqual(store.contacts[original.id]?.emails.count,2)
        try engine.undo(id:record.id)
        XCTAssertEqual(store.contacts[original.id]?.image,Data([9]));XCTAssertEqual(store.contacts[original.id]?.emails,["first@company.org"])
    }
    @MainActor func testExistingDifferentContactsAreNeverMerged() throws {
        let (store,_,engine,image)=try fixture()
        _=try store.create(name:"One",email:"one@company.org",image:Data([1]))
        _=try store.create(name:"Two",email:"two@company.org",image:Data([2]))
        XCTAssertThrowsError(try engine.applyGroup(emails:[EmailAddress("one@company.org")!,EmailAddress("two@company.org")!],name:"Company",candidate:image,allowCreate:false,managedKey:nil))
        XCTAssertEqual(store.contacts.count,2)
    }
    @MainActor func testManagedIdentityAddsFutureAliasToSameCardWithoutCreatingAnother() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer { try? FileManager.default.removeItem(at:root) }
        let model=AppModel(demo:true,rootOverride:root)
        model.rows=[SenderRow(email:EmailAddress("code-1@company.org")!,name:"Company"),SenderRow(email:EmailAddress("code-2@company.org")!,name:"Company")]
        let candidate=try DemoImages.candidate(symbol:"building.2",color:.systemBlue)
        for i in model.rows.indices { model.rows[i].candidates=[candidate];model.rows[i].selectedCandidate=candidate.id }
        let group=try XCTUnwrap(model.visibleGroups.first)
        model.prepareApplyGroup(group);model.allowCreate=true;model.confirmApply()
        for _ in 0..<1000 { if !model.busy { break };try await Task.sleep(for:.milliseconds(1)) }
        let store=try XCTUnwrap(model.port as? FixtureContactStore)
        XCTAssertEqual(store.contacts.count,1);XCTAssertEqual(store.contacts.values.first?.emails.count,2);XCTAssertEqual(model.managedIdentities.count,1)
        model.rows.append(SenderRow(email:EmailAddress("code-3@company.org")!,name:"Company"));model.syncManagedAliases()
        XCTAssertEqual(store.contacts.count,1);XCTAssertEqual(store.contacts.values.first?.emails.count,3)
        XCTAssertEqual(model.rows.last?.current?.id,store.contacts.values.first?.id);XCTAssertTrue(model.rows.last?.completed == true)
    }
    @MainActor func testUndoManagedGroupStopsManagementAndReconcilesEveryAliasRow() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer { try? FileManager.default.removeItem(at:root) }
        let model=AppModel(demo:true,rootOverride:root)
        model.rows=[SenderRow(email:EmailAddress("code-1@company.org")!,name:"Company"),SenderRow(email:EmailAddress("code-2@company.org")!,name:"Company")]
        let candidate=try DemoImages.candidate(symbol:"building.2",color:.systemBlue)
        for i in model.rows.indices { model.rows[i].candidates=[candidate];model.rows[i].selectedCandidate=candidate.id }
        model.prepareApplyGroup(try XCTUnwrap(model.visibleGroups.first));model.allowCreate=true;model.confirmApply()
        for _ in 0..<1000 { if !model.busy { break };try await Task.sleep(for:.milliseconds(1)) }
        let record=try XCTUnwrap(model.records.last);XCTAssertEqual(model.managedIdentities.count,1)
        model.undo(record)
        for _ in 0..<1000 { if !model.busy { break };try await Task.sleep(for:.milliseconds(1)) }
        XCTAssertTrue(model.managedIdentities.isEmpty)
        XCTAssertTrue(model.rows.allSatisfy { !$0.completed && $0.current == nil && $0.ignored })
        XCTAssertTrue(try XCTUnwrap(model.port as? FixtureContactStore).contacts.isEmpty)
    }
    @MainActor func testManagedScopeRequiresExactNameAndRegistrableDomain() {
        let seed=SenderRow(email:EmailAddress("code-1@notify.company.org")!,name:"Company")
        let same=SenderRow(email:EmailAddress("code-2@auth.company.org")!,name:"  company  ")
        let otherName=SenderRow(email:EmailAddress("code-3@company.org")!,name:"Company Billing")
        let otherDomain=SenderRow(email:EmailAddress("code-4@other.org")!,name:"Company")
        XCTAssertEqual(ManagedIdentityScope.key(seed),ManagedIdentityScope.key(same))
        XCTAssertNotEqual(ManagedIdentityScope.key(seed),ManagedIdentityScope.key(otherName))
        XCTAssertNotEqual(ManagedIdentityScope.key(seed),ManagedIdentityScope.key(otherDomain))
    }
    @MainActor func testManagedScopeNeverUsesSharedMailProviderOrBareAddressName() {
        XCTAssertNil(ManagedIdentityScope.key(SenderRow(email:EmailAddress("person@gmail.com")!,name:"Person")))
        XCTAssertNil(ManagedIdentityScope.key(SenderRow(email:EmailAddress("code@company.org")!,name:"code")))
    }
}
