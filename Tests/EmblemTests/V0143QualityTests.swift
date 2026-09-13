import XCTest
import Combine
import PortraitCore
@testable import Emblem

private struct ReceiptScanner:MailScannerPort {
 var messages:[(String,Date)]
 func inventory(source:ScanSource)async throws->MailScanInventory {.init(mailboxes:[.init(account:"fixture",path:["INBOX"],label:"INBOX",count:messages.count)],warnings:[])}
 func page(mailbox:MailScanMailbox,start:Int,size:Int)async throws->MailScanPage {
  let page=Array(messages.dropFirst(start-1).prefix(size))
  return .init(senders:page.map{$0.0},currentCount:messages.count,receivedAt:page.map{$0.1})
 }
}
final class V0143QualityTests:XCTestCase {
 @MainActor func model(scanner:(any MailScannerPort)?=nil)throws->AppModel {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  addTeardownBlock{try? FileManager.default.removeItem(at:root)}
  return AppModel(demo:true,rootOverride:root,mailScanner:scanner,backgroundWorkAllowed:false)
 }
 func testTypedReceiptDateDoesNotDependOnLocaleOrTimeZone()throws {
  let date=Date(timeIntervalSince1970:1789234321)
  XCTAssertEqual(ScriptValue.read(ScriptValue.date(date).descriptor).date,date)
 }
 @MainActor func testScanUsesMaximumDateAcrossDuplicateMessagesAndPersists()async throws {
  let a="Alice <a@auckland.ac.nz>",b="Bob <b@vuw.ac.nz>",date:(Int)->Date={Date(timeIntervalSinceReferenceDate:Double($0))}
  let scanner=ReceiptScanner(messages:[(a,date(100)),(b,date(200)),(a,date(300))]),m=try model(scanner:scanner)
  await m.performScan(.inbox,automatic:true)
  XCTAssertEqual(m.visibleGroups.map{$0.representative.id},["a@auckland.ac.nz","b@vuw.ac.nz"])
  XCTAssertEqual(m.rows.first{$0.id=="a@auckland.ac.nz"}?.lastInboxReceivedAt,date(300))
  XCTAssertEqual(m.scanReport?.duplicateEntries,1)
  let re=AppModel(demo:true,rootOverride:m.root,backgroundWorkAllowed:false)
  XCTAssertEqual(re.visibleGroups.map{$0.representative.id},m.visibleGroups.map{$0.representative.id})
  XCTAssertEqual(re.selectedID,re.visibleGroups.first?.representative.id)
  let before=m.rows.map{$0.lastInboxReceivedAt};await m.performScan(.contacts,automatic:true)
  XCTAssertEqual(before,m.rows.map{$0.lastInboxReceivedAt})
 }
 @MainActor func testMovedOutOfInboxDoesNotRemainAboveCurrentInboxSender()async throws {
  let m=try model(scanner:ReceiptScanner(messages:[("a@auckland.ac.nz",Date(timeIntervalSinceReferenceDate:100))]))
  m.rows=[SenderRow(email:EmailAddress("old@vuw.ac.nz")!,name:"Old",lastInboxReceivedAt:Date(timeIntervalSinceReferenceDate:500))]
  await m.performScan(.inbox,automatic:true)
  XCTAssertNil(m.rows.first{$0.id=="old@vuw.ac.nz"}?.lastInboxReceivedAt)
  XCTAssertEqual(m.visibleGroups.first?.representative.id,"a@auckland.ac.nz")
 }
 @MainActor func testReceiptGroupUsesNewestMemberAndTiesAreStable()throws {
  let c=ContactSnapshot(id:"brand",name:"Brand",emails:[],image:nil)
  let a=SenderRow(email:EmailAddress("a@claude.com")!,name:"Claude",lastInboxReceivedAt:Date(timeIntervalSinceReferenceDate:100),current:c)
  let b=SenderRow(email:EmailAddress("b@claude.com")!,name:"Claude",lastInboxReceivedAt:Date(timeIntervalSinceReferenceDate:300),current:c)
  let other=SenderRow(email:EmailAddress("a@auckland.ac.nz")!,name:"Alice",lastInboxReceivedAt:Date(timeIntervalSinceReferenceDate:200))
  let groups=SenderGrouping.groups([a,other,b]);XCTAssertEqual(groups[0].representative.id,b.id);XCTAssertEqual(groups[0].members.count,2)
  XCTAssertEqual(SenderGrouping.groups([a,a]).first?.members.map(\.id),[a.id,a.id])
 }
 func testSharedRelayRuleDoesNotRenameEmployeesOrTrustUnrelatedViaLabels() {
  func name(_ email:String,_ display:String)->String {SharedSenderIdentity.contactName(email:EmailAddress(email)!,displayName:display)}
  XCTAssertEqual(name("invitations@linkedin.com","Jordan via LinkedIn"),"LinkedIn")
  XCTAssertEqual(name("inmail-hit-reply@linkedin.com","wenxin XIAO"),"LinkedIn")
  XCTAssertEqual(name("elliott.wen@linkedin.com","Elliott Wen"),"Elliott Wen")
  XCTAssertEqual(name("notifications@slack.com","Jordan via Slack"),"Slack")
  XCTAssertEqual(name("notifications@slack.com","Jordan via Tesla"),"Jordan via Tesla")
  XCTAssertEqual(name("notifications@gmail.com","Jordan via Gmail"),"Jordan via Gmail")
 }
 @MainActor func testRepairIsNameOnlyIdempotentAndUndoable()async throws {
  let m=try model(),c=try NameAvatar.candidate(name:"LinkedIn"),e=EmailAddress("invitations@linkedin.com")!
  let creation=try m.engine.apply(email:e,name:"Elliott Wen via LinkedIn",candidate:c,allowCreate:true)
  let before=try XCTUnwrap(m.port.get(id:creation.contactID!))
  m.rows=[SenderRow(email:e,name:before.name,completed:true,candidates:[c],selectedCandidate:c.id,current:before)];m.records=try m.engine.records()
  try m.repairSharedSenderNames();let after=try XCTUnwrap(m.port.get(id:before.id))
  XCTAssertEqual(after.name,"LinkedIn");XCTAssertEqual(after.image,before.image);XCTAssertEqual(after.emails,before.emails);XCTAssertEqual(after.id,before.id)
  try m.repairSharedSenderNames();XCTAssertEqual(try m.engine.records().count,2)
  let correction=try XCTUnwrap(m.engine.records().last);try m.engine.undo(id:correction.id)
  XCTAssertEqual(try m.port.get(id:before.id),before)
 }
 @MainActor func testRepairProtectsPreexistingAndUserRenamedCards()throws {
  let m=try model(),c=try NameAvatar.candidate(name:"LinkedIn"),e=EmailAddress("invitations@linkedin.com")!
  let before=try m.port.create(name:"Elliott Wen via LinkedIn",email:e.value,image:c.png)
  XCTAssertThrowsError(try m.engine.renameCreatedContact(contactID:before.id,expectedName:before.name,name:"LinkedIn",expectedEmails:before.emails))
  XCTAssertEqual(try m.port.get(id:before.id),before)
  let e2=EmailAddress("inmail-hit-reply@linkedin.com")!,creation=try m.engine.apply(email:e2,name:"wenxin XIAO",candidate:c,allowCreate:true),id=creation.contactID!
  _=try m.port.rename(id:id,expectedName:"wenxin XIAO",name:"My LinkedIn inbox")
  XCTAssertThrowsError(try m.engine.renameCreatedContact(contactID:id,expectedName:"wenxin XIAO",name:"LinkedIn",expectedEmails:[e2.value]))
  XCTAssertEqual(try m.port.get(id:id)?.name,"My LinkedIn inbox")
 }
 @MainActor func testRecentDeltaKeepsOlderInboxDatesAndIsIdempotent()async throws {
  let m=try model();m.rows=[SenderRow(email:EmailAddress("old@auckland.ac.nz")!,name:"Old",lastInboxReceivedAt:Date(timeIntervalSinceReferenceDate:100))]
  let page=MailScanPage(senders:["A <a@vuw.ac.nz>","A <a@vuw.ac.nz>"],currentCount:2,receivedAt:[Date(timeIntervalSinceReferenceDate:300),Date(timeIntervalSinceReferenceDate:200)])
  let first=try await m.ingestRecentInbox(page);XCTAssertTrue(first)
  XCTAssertEqual(m.rows.count,2);XCTAssertEqual(m.visibleGroups.first?.representative.id,"a@vuw.ac.nz")
  XCTAssertEqual(m.rows.first{$0.id=="old@auckland.ac.nz"}?.lastInboxReceivedAt,Date(timeIntervalSinceReferenceDate:100))
  let revision=m.rowsRevision;let second=try await m.ingestRecentInbox(page);XCTAssertTrue(second);XCTAssertEqual(revision,m.rowsRevision)
  let malformed=try await m.ingestRecentInbox(.init(senders:["a@vuw.ac.nz"],currentCount:1));XCTAssertFalse(malformed)
 }
 @MainActor func testUnchangedContactScanDoesNotPublishRows()throws {
  let m=try model(),c=ContactSnapshot(id:"a",name:"A",emails:["a@auckland.ac.nz"],image:Data([1]))
  m.rows=[SenderRow(email:EmailAddress(c.emails[0])!,name:c.name,current:c)]
  var count=0;let token=m.$rows.dropFirst().sink{_ in count+=1};defer{token.cancel()}
  m.applyScanContactIndex([c.emails[0]:[c]]);XCTAssertEqual(count,0)
 }
}
