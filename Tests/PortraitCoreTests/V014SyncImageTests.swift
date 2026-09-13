import XCTest
@testable import PortraitCore
@MainActor private final class V014Journal:JournalPort {
 var rows:[ChangeRecord]=[];var fail=false
 func read()throws->[ChangeRecord]{rows}
 func write(_ values:[ChangeRecord])throws {if fail{throw PortraitError.message("disk full")};rows=values}
}
final class V014SyncImageTests:XCTestCase {
 @MainActor func testStaleImageAndMissingEmailNeverOverwrite()throws {
  let store=try FixtureContactStore(),j=V014Journal(),engine=ChangeEngine(store:store,journal:j)
  let old=try store.create(name:"Bellroy",email:"support@bellroy.com",image:Data([1]))
  let c=AvatarCandidate(source:.manual,origin:"fixture",width:256,height:256,png:Data([2]))
  XCTAssertThrowsError(try engine.replaceSyncedImage(contactID:old.id,email:"support@bellroy.com",expectedHash:"stale",candidate:c))
  XCTAssertThrowsError(try engine.replaceSyncedImage(contactID:old.id,email:"wrong@bellroy.com",expectedHash:digest(old.image),candidate:c))
  XCTAssertEqual(try store.get(id:old.id)?.image,old.image);XCTAssertTrue(j.rows.isEmpty)
 }
 @MainActor func testJournalFailurePreventsImageWrite()throws {
  let store=try FixtureContactStore(),j=V014Journal(),engine=ChangeEngine(store:store,journal:j)
  let old=try store.create(name:"Bellroy",email:"support@bellroy.com",image:Data([1]));j.fail=true
  XCTAssertThrowsError(try engine.replaceSyncedImage(contactID:old.id,email:"support@bellroy.com",expectedHash:digest(old.image),candidate:AvatarCandidate(source:.manual,origin:"fixture",width:256,height:256,png:Data([2]))))
  XCTAssertEqual(try store.get(id:old.id)?.image,old.image)
 }
 @MainActor func testUndoPhotoReplacementRestoresExistingCard()throws {
  let store=try FixtureContactStore(),j=V014Journal(),engine=ChangeEngine(store:store,journal:j)
  let old=try store.create(name:"Original Name",email:"support@bellroy.com",image:Data([1]))
  let r=try engine.replaceSyncedImage(contactID:old.id,email:"support@bellroy.com",expectedHash:digest(old.image),candidate:AvatarCandidate(source:.manual,origin:"fixture",width:256,height:256,png:Data([2])))
  try engine.undo(id:r.id);XCTAssertEqual(try store.get(id:old.id)?.image,old.image);XCTAssertEqual(try store.get(id:old.id)?.name,"Original Name");XCTAssertEqual(store.contacts.count,1)
 }
}
