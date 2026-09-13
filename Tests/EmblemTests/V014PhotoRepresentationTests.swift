import XCTest
import PortraitCore
import PortraitContactsBridge
@testable import Emblem

final class V014PhotoRepresentationTests:XCTestCase {
 @MainActor func testProtectedExistingPhotoRecoveryIsGuardedAndIdempotent()throws {
  let m=try model(),old=try NameAvatar.candidate(name:"OpenAI"),new=try NameAvatar.candidate(name:"OpenAI",variant:1)
  let contact=try m.port.create(name:"OpenAI",email:"noreply@tm.openai.com",image:old.png);_=try m.port.setImage(id:contact.id,image:nil)
  let record=try m.engine.replaceSyncedImage(contactID:contact.id,email:"noreply@tm.openai.com",expectedHash:"none",candidate:new)
  let input=ProtectedPhotoRecovery(recordID:record.id,originalPNG:old.png,appliedPNG:new.png)
  XCTAssertTrue(try PhotoRecovery.restore(input,engine:m.engine,store:m.port));XCTAssertEqual(try m.port.get(id:contact.id)?.image,old.png)
  XCTAssertFalse(try PhotoRecovery.restore(input,engine:m.engine,store:m.port));XCTAssertEqual(try m.engine.records().count,2)
  _=try m.port.setImage(id:contact.id,image:NameAvatar.candidate(name:"OpenAI",variant:2).png)
  XCTAssertThrowsError(try PhotoRecovery.restore(input,engine:m.engine,store:m.port));XCTAssertEqual(try m.engine.records().count,2)
 }
 func testOwnCreationIsNotConfusedWithSubsequentEdits() {
  XCTAssertTrue(MPOwnedCreationHistoryUnchanged(0,0,0,0));XCTAssertTrue(MPOwnedCreationHistoryUnchanged(1,0,0,0))
  XCTAssertFalse(MPOwnedCreationHistoryUnchanged(2,0,0,0));XCTAssertFalse(MPOwnedCreationHistoryUnchanged(1,1,0,0))
  XCTAssertFalse(MPOwnedCreationHistoryUnchanged(1,0,1,0));XCTAssertFalse(MPOwnedCreationHistoryUnchanged(1,0,0,1))
 }
 @MainActor private func model()throws->AppModel {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  addTeardownBlock{try? FileManager.default.removeItem(at:root)}
  let m=AppModel(demo:true,rootOverride:root,backgroundWorkAllowed:false);m.automation.setupComplete=true;m.mailSync.enabled=true;return m
 }
 @MainActor private func row(_ address:String="newzealand@tesla.com")throws->SenderRow {
  let c=try NameAvatar.candidate(name:"Tesla New Zealand")
  return SenderRow(email:EmailAddress(address)!,name:"Tesla New Zealand",candidates:[c],selectedCandidate:c.id)
 }
 @MainActor func testThumbnailFallbackDoesNotMistakeExistingPhotoForEmpty()throws {
  let image=try NameAvatar.candidate(name:"Claude Team").png
  XCTAssertEqual(AppleContacts.availableImage(original:nil,thumbnail:image),image)
  XCTAssertEqual(AppleContacts.availableImage(original:Data([1]),thumbnail:image),Data([1]))
  XCTAssertNil(AppleContacts.availableImage(original:nil,thumbnail:nil))
  let path=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/Emblem/AppleContacts.swift")
  XCTAssertTrue(try String(contentsOf:path).contains("CNContactThumbnailImageDataKey"))
 }
 @MainActor func testEncodingOnlyChangeRecoversProvenNoOpAndUndoStillWorks()async throws {
  let m=try model();m.rows=[try row()];try await m.performMailSync()
  let original=try XCTUnwrap(m.rows[0].current),old=try XCTUnwrap(original.image)
  var reencoded=old;reencoded.append(Data("png container bytes after IEND".utf8))
  XCTAssertNotEqual(digest(old),digest(reencoded));XCTAssertEqual(photoPixelHash(old),photoPixelHash(reencoded))
  _=try m.port.setImage(id:original.id,image:reencoded)
  var intent=ChangeRecord(email:"NewZealand@tesla.com",source:"managed-alias",created:false,contactID:original.id,beforeImage:old,afterHash:digest(old),historyToken:m.port.historyToken())
  intent.beforeEmails=original.emails;intent.afterEmailsHash=digestEmails(original.emails+["NewZealand@tesla.com"]);intent.managedKey="brand"
  let journal=FileJournal(url:m.root.appendingPathComponent("changes.json"));var records=try journal.read();records.append(intent);try journal.write(records)
  try await m.performMailSync()
  XCTAssertFalse(m.mailSync.links[0].externalPhoto);XCTAssertEqual(try m.engine.records().last?.state,.undone)
  XCTAssertEqual(try m.port.get(id:original.id)?.image,reencoded)
  try await m.ignoreSyncedSenders([m.rows[0].id]);XCTAssertNil(try m.port.get(id:original.id))
 }
 @MainActor func testExternalPhotoAllowsAliasButExternalEmailRemovalStaysRemoved()async throws {
  let m=try model();m.rows=[try row()];try await m.performMailSync();let id=m.rows[0].current!.id
  let other=try NameAvatar.candidate(name:"Tesla New Zealand",variant:2).png
  _=try m.port.setImage(id:id,image:other);try await m.performMailSync();XCTAssertTrue(m.mailSync.links[0].externalPhoto)
  m.rows.insert(try row("deliveries@tesla.com"),at:0);try await m.performMailSync()
  XCTAssertEqual(try m.port.get(id:id)?.image,other);XCTAssertEqual(try m.port.get(id:id)?.emails.count,2)
  _=try m.port.update(id:id,image:other,emails:["newzealand@tesla.com"])
  try await m.performMailSync();try await m.performMailSync()
  XCTAssertEqual(try m.port.get(id:id)?.emails,["newzealand@tesla.com"]);XCTAssertEqual(m.mailSync.links[0].externalEmails,true)
 }
}
