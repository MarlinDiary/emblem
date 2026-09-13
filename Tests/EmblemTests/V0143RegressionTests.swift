import XCTest
import Combine
import PortraitCore
@testable import Emblem

final class V0143RegressionTests:XCTestCase {
 @MainActor func makeModel()throws->AppModel {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  addTeardownBlock {try? FileManager.default.removeItem(at:root)}
  let m=AppModel(demo:true,rootOverride:root,backgroundWorkAllowed:false);m.automation.setupComplete=true;return m
 }
 func dated(_ email:String,_ seconds:Double?,name:String="Sender")->SenderRow {
  var json:[String:Any] = ["email":["value":email],"name":name,"ignored":false,"completed":false,"candidates":[],"notes":[],"status":""]
  if let seconds {json["lastInboxReceivedAt"]=seconds}
  return try! JSONDecoder().decode(SenderRow.self,from:JSONSerialization.data(withJSONObject:json))
 }
 @MainActor func testInboxOrderUsesReceivedDateNotDiscoveryOrder()throws {
  let m=try makeModel();m.rows=[dated("old@auckland.ac.nz",100),dated("new@auckland.ac.nz",300),dated("none@auckland.ac.nz",nil)]
  XCTAssertEqual(m.visibleGroups.map{$0.representative.id},["new@auckland.ac.nz","old@auckland.ac.nz","none@auckland.ac.nz"])
  m.rows[0]=dated("old@auckland.ac.nz",400)
  XCTAssertEqual(m.visibleGroups.first?.representative.id,"old@auckland.ac.nz")
 }
 @MainActor func testSharedInvitationDoesNotBecomeOneInvitersContact()async throws {
  let m=try makeModel(),c=try NameAvatar.candidate(name:"LinkedIn")
  m.rows=[SenderRow(email:EmailAddress("invitations@linkedin.com")!,name:"Elliott Wen via LinkedIn",candidates:[c],selectedCandidate:c.id)]
  m.mailSync.enabled=true;try await m.performMailSync()
  XCTAssertEqual(try m.port.matches(email:"invitations@linkedin.com").first?.name,"LinkedIn")
 }
 @MainActor func testIdle903SenderSyncDoesNotInvalidateRowsOrRewriteLibrary()async throws {
  let m=try makeModel(),c=try NameAvatar.candidate(name:"Mail"),store=try XCTUnwrap(m.port as? FixtureContactStore),h=digest(c.png)
  var rows:[SenderRow]=[],links:[MailSyncLink]=[]
  for n in 0..<903 {
   let email=EmailAddress("person\(n)@auckland.ac.nz")!,contact=ContactSnapshot(id:"id-\(n)",name:"Person \(n)",emails:[email.value],image:c.png)
   store.contacts[contact.id]=contact
   let row=SenderRow(email:email,name:contact.name,completed:true,candidates:[c],selectedCandidate:c.id,current:contact)
   rows.append(row);links.append(.init(key:MailSyncIdentity.key(row),contactID:contact.id,emails:Set(contact.emails),createdByApp:true,imageHash:h,desiredHash:h))
  }
  m.rows=rows;m.mailSync.enabled=true;m.mailSync.links=links;m.syncFingerprintsReady=true;m.save()
  let before=try FileManager.default.attributesOfItem(atPath:m.stateURL.path)[.modificationDate] as! Date
  let revision=m.visibleGroupingRevision
  var publications=0;let token=m.$rows.dropFirst().sink{_ in publications+=1};defer{token.cancel()}
  let start=ContinuousClock.now;try await m.performMailSync();let elapsed=start.duration(to:.now)
  print("IDLE_SYNC_903_SECONDS=\(Double(elapsed.components.seconds)+Double(elapsed.components.attoseconds)/1e18) ROW_PUBLICATIONS=\(publications)")
  XCTAssertEqual(m.visibleGroupingRevision,revision);XCTAssertEqual(publications,0)
  XCTAssertEqual(try FileManager.default.attributesOfItem(atPath:m.stateURL.path)[.modificationDate] as? Date,before)
  XCTAssertLessThan(elapsed,.seconds(2))
 }
}
