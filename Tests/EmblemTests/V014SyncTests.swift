import XCTest
import PortraitCore
@testable import Emblem

final class V014SyncTests:XCTestCase {
 @MainActor func testLegacySyncStateDecodesWithoutContactsHistoryToken()throws {
  let data=Data(#"{"enabled":true,"background":true,"enrolled":[],"excludedAtEnable":[],"suppressedKeys":[],"links":[],"explicitChoices":{}}"#.utf8)
  let legacy=try JSONDecoder().decode(MailSyncState.self,from:data)
  XCTAssertNil(legacy.contactsHistoryToken)
  XCTAssertNil(legacy.fingerprintMigrationRevision)
  var current=legacy;current.contactsHistoryToken=Data([1,2,3])
  XCTAssertEqual(try JSONDecoder().decode(MailSyncState.self,from:JSONEncoder().encode(current)).contactsHistoryToken,Data([1,2,3]))
 }
 @MainActor private func model()throws->AppModel {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  addTeardownBlock {try? FileManager.default.removeItem(at:root)}
  let m=AppModel(demo:true,rootOverride:root);m.automation.setupComplete=true;return m
 }
 @MainActor private func row(_ email:String="hello@sevenrooms.com",name:String="SevenRooms",variant:Int=0)throws->SenderRow {
  let c=try NameAvatar.candidate(name:name,variant:variant)
  return SenderRow(email:EmailAddress(email)!,name:name,candidates:[c],selectedCandidate:c.id,discoveredAt:Date())
 }
 @MainActor private func enable(_ m:AppModel) {m.mailSync.enabled=true;m.automaticEnabled=true;m.useWebsite=false;m.useGravatar=false}
 @MainActor func testDefaultIsOffAndPreviewNeverWrites()async throws {
  let m=try model();m.rows=[try row()];try await m.performMailSync()
  XCTAssertFalse(m.mailSync.enabled);XCTAssertFalse(m.mailSync.background);XCTAssertTrue(try m.engine.records().isEmpty)
 }
 @MainActor func testCreateOnceAndRestartIsIdempotent()async throws {
  let m=try model();m.rows=[try row()];enable(m)
  try await m.performMailSync();try await m.performMailSync()
  let store=try XCTUnwrap(m.port as? FixtureContactStore);XCTAssertEqual(store.contacts.count,1);XCTAssertEqual(try m.engine.records().count,1)
  let reopened=AppModel(demo:true,rootOverride:m.root);try await reopened.performMailSync()
  XCTAssertEqual(try reopened.engine.records().count,1);XCTAssertEqual(reopened.mailSync.links.count,1)
 }
 @MainActor func testNextChoiceAutomaticallyUpdatesSameCard()async throws {
  let m=try model();m.rows=[try row()];enable(m);try await m.performMailSync()
  let before=m.rows[0].current!.id,c=try NameAvatar.candidate(name:"SevenRooms",variant:2)
  m.addCandidate(c,to:m.rows[0].id);m.syncTask?.cancel();m.syncTask=nil
  try await m.performMailSync()
  XCTAssertEqual(m.rows[0].current?.id,before);XCTAssertEqual(digest(m.rows[0].current?.image),digest(c.png));XCTAssertEqual(try m.engine.records().count,2)
 }
 @MainActor func testExternalPhotoWinsAndExplicitUserChoiceCanReplaceIt()async throws {
  let m=try model();m.rows=[try row()];enable(m);try await m.performMailSync()
  let id=m.rows[0].current!.id, external=try NameAvatar.candidate(name:"SevenRooms",variant:2)
  _=try m.port.setImage(id:id,image:external.png);try await m.performMailSync();try await m.performMailSync()
  XCTAssertEqual(m.rows[0].current?.image,external.png);XCTAssertTrue(m.mailSync.links[0].externalPhoto)
  let c=try NameAvatar.candidate(name:"SevenRooms",variant:1);m.addCandidate(c,to:m.rows[0].id);m.syncTask?.cancel();m.syncTask=nil;try await m.performMailSync()
  XCTAssertEqual(m.rows[0].current?.image,c.png)
 }
 @MainActor func testDeletingInContactsSuppressesRecreationEvenAfterRestart()async throws {
  let m=try model();m.rows=[try row()];enable(m);try await m.performMailSync();try m.port.delete(id:m.rows[0].current!.id)
  try await m.performMailSync();let reopened=AppModel(demo:true,rootOverride:m.root);try await reopened.performMailSync()
  XCTAssertTrue(reopened.rows[0].ignored);XCTAssertTrue(try reopened.port.matches(email:m.rows[0].id).isEmpty);XCTAssertEqual(try reopened.engine.records().count,1)
 }
 @MainActor func testIgnoreDeletesOnlyAppCreatedCardAndUndoCanRestore()async throws {
  let m=try model();m.rows=[try row()];enable(m);try await m.performMailSync();let ids=Set(m.rows.map(\.id))
  try await m.ignoreSyncedSenders(ids);XCTAssertTrue(try m.port.matches(email:m.rows[0].id).isEmpty);XCTAssertTrue(m.rows[0].ignored)
  try await m.performMailSync();XCTAssertTrue(try m.port.matches(email:m.rows[0].id).isEmpty)
  m.restoreIgnored(ids);m.syncTask?.cancel();m.syncTask=nil;try await m.performMailSync();XCTAssertEqual(try m.port.matches(email:m.rows[0].id).count,1)
 }
 @MainActor func testIgnoreKeepsLaterEditedCardButProcessesOtherSenders()async throws {
  let m=try model();m.rows=[try row("first@fixture.test",name:"First"),try row("second@fixture.test",name:"Second")];enable(m)
  try await m.performMailSync();let first=try XCTUnwrap(m.rows[0].current?.id),second=try XCTUnwrap(m.rows[1].current?.id)
  _=try m.port.setImage(id:first,image:try NameAvatar.candidate(name:"Changed",variant:2).png)
  try await m.ignoreSyncedSenders(Set(m.rows.map(\.id)))
  XCTAssertNotNil(try m.port.get(id:first));XCTAssertNil(try m.port.get(id:second))
  XCTAssertTrue(m.rows.allSatisfy(\.ignored));XCTAssertEqual(m.ignoreSummary,"Ignored · 1 edited contact kept")
  XCTAssertTrue(m.mailSync.links.isEmpty)
 }
 @MainActor func testIgnoreExistingPhotoNeverDeletesUserCard()async throws {
  let m=try model();m.rows=[try row()];let c=try NameAvatar.candidate(name:"SevenRooms",variant:2)
  let contact=try m.port.create(name:"Original",email:m.rows[0].id,image:c.png);enable(m);try await m.performMailSync();try await m.ignoreSyncedSenders([m.rows[0].id])
  XCTAssertEqual(try m.port.get(id:contact.id)?.image,c.png);XCTAssertTrue(try m.engine.records().isEmpty)
 }
 @MainActor func testExistingEmptyPhotoIsFilledThenRestoredWithoutDeletingCard()async throws {
  let m=try model();m.rows=[try row()];let contact=try m.port.create(name:"Original",email:m.rows[0].id,image:Data([1]));_=try m.port.setImage(id:contact.id,image:nil)
  enable(m);try await m.performMailSync();XCTAssertNotNil(try m.port.get(id:contact.id)?.image)
  try await m.ignoreSyncedSenders([m.rows[0].id]);XCTAssertNotNil(try m.port.get(id:contact.id));XCTAssertNil(try m.port.get(id:contact.id)?.image)
 }
 @MainActor func testBrandRotatingAliasesReuseCardAndUniversitiesStayIndependent()async throws {
  let m=try model();m.rows=[try row("code-1@anthropic.com",name:"Anthropic")];enable(m);try await m.performMailSync()
  m.rows.insert(try row("code-2@anthropic.com",name:"Anthropic"),at:0);try await m.performMailSync()
  XCTAssertEqual((m.port as? FixtureContactStore)?.contacts.count,1);XCTAssertEqual(m.rows[0].current?.emails.count,2)
  m.rows.insert(contentsOf:[try row("a@auckland.ac.nz",name:"University of Auckland"),try row("b@auckland.ac.nz",name:"University of Auckland")],at:0);try await m.performMailSync()
  XCTAssertEqual((m.port as? FixtureContactStore)?.contacts.count,3)
 }
 @MainActor func testMoreThanOneBatchDoesNotStarveOlderRows()async throws {
  let m=try model();m.rows=try (0..<23).map{try row("person\($0)@auckland.ac.nz",name:"Person \($0)")};enable(m)
  try await m.performMailSync(limit:20);XCTAssertEqual((m.port as? FixtureContactStore)?.contacts.count,20)
  try await m.performMailSync(limit:20);XCTAssertEqual((m.port as? FixtureContactStore)?.contacts.count,23)
 }
 @MainActor func testFutureOnlyScopeAndAcademicSourcesNotGuessed()async throws {
  let m=try model();m.rows=[try row()];try await m.enableMailSync(includeExisting:false);m.syncTask?.cancel();m.syncTask=nil
  try await m.performMailSync();XCTAssertTrue(try m.engine.records().isEmpty)
  m.rows.insert(try row("help@bellroy.com",name:"Bellroy"),at:0);try await m.performMailSync();XCTAssertEqual((m.port as? FixtureContactStore)?.contacts.count,1)
 }
 @MainActor func testExplicitEnableAllIncludesLegacyRows()async throws {
  let m=try model();m.rows=[try row()];try await m.enableMailSync(includeExisting:true);m.syncTask?.cancel();m.syncTask=nil;try await m.performMailSync()
  XCTAssertEqual((m.port as? FixtureContactStore)?.contacts.count,1)
 }
 @MainActor func testContactAliasComparisonDoesNotAppendCaseOnlyVariants()async throws {
  let m=try model();m.rows=[try row("newzealand@tesla.com",name:"Tesla New Zealand")];enable(m);try await m.performMailSync()
  let id=try XCTUnwrap(m.rows[0].current?.id);m.rows.insert(try row("NewZealand@tesla.com",name:"Tesla New Zealand"),at:0)
  try await m.performMailSync();try await m.performMailSync()
  XCTAssertEqual(try m.port.get(id:id)?.emails,["newzealand@tesla.com"]);XCTAssertEqual(try m.engine.records().count,1)
  XCTAssertEqual(m.rows.count,2);XCTAssertTrue(m.rows.allSatisfy{$0.applicationIssue == nil})
  XCTAssertNil(try m.engine.appendManagedAliases(contactID:id,emails:[EmailAddress("NewZealand@tesla.com")!],managedKey:"brand"))
  XCTAssertEqual(try m.engine.records().count,1)
 }
 @MainActor func testLegacyCreatedBrandCardUsesMatchedEmailBeforeAddingNewAliases()async throws {
  let m=try model(),old=try row("noreply@tm.openai.com",name:"OpenAI"),new=try row("trustandsafety@tm1.openai.com",name:"OpenAI")
  let record=try m.engine.apply(email:old.email,name:old.name,candidate:old.chosen!,allowCreate:true)
  let id=try XCTUnwrap(record.contactID);_=try m.port.setImage(id:id,image:nil)
  m.rows=[new,old];enable(m);try await m.performMailSync();try await m.performMailSync()
  XCTAssertEqual(m.mailSync.links.count,1);XCTAssertTrue(m.rows.allSatisfy{$0.applicationIssue == nil})
  XCTAssertEqual((m.port as? FixtureContactStore)?.contacts.count,1)
  XCTAssertEqual(Set(try m.port.get(id:id)!.emails),Set([old.id,new.id]));XCTAssertNotNil(try m.port.get(id:id)?.image)
 }
 @MainActor func testBackgroundSwitchPersistsAndQuitPolicyIsHonest()throws {
  let m=try model();BackgroundLifecycle.model=m;let delegate=BackgroundLifecycle()
  XCTAssertTrue(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared));m.setBackground(true)
  XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared));let reopened=AppModel(demo:true,rootOverride:m.root);XCTAssertTrue(reopened.mailSync.background)
 }
 @MainActor func testDecliningSyncDoesNotChangeContacts()throws {let m=try model();m.setMailSyncEnabled(true);XCTAssertTrue(m.showSyncSetup);XCTAssertFalse(m.mailSync.enabled);XCTAssertTrue(try m.engine.records().isEmpty)}
 @MainActor func testLegacyFingerprintMigrationIsRecordedOnce()async throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
  let model=AppModel(demo:true,rootOverride:root,backgroundWorkAllowed:false)
  try await model.prepareSyncPhotoEvidence()
  XCTAssertEqual(model.mailSync.fingerprintMigrationRevision,1)
  let persisted=try JSONDecoder().decode(MailSyncState.self,from:Data(contentsOf:model.syncURL))
  XCTAssertEqual(persisted.fingerprintMigrationRevision,1)
 }
}
