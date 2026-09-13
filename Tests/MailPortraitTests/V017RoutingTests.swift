import XCTest
import AppKit
@testable import MailPortrait
import PortraitCore

private actor RoutingMail:MailScannerPort {
 var scopes:[Set<String>]=[]
 var incremental=0
 var fail=false
 func setFailure(){fail=true}
 func inventory(source:ScanSource)async throws->MailScanInventory {try await inventory(source:source,excludingAccountEmails:[])}
 func inventory(source:ScanSource,excludingAccountEmails:Set<String>)async throws->MailScanInventory {
  scopes.append(excludingAccountEmails);if fail {throw GmailHTTPError(status:500)};return .init(mailboxes:[],warnings:[])
 }
 func recentInbox(since:Date,excludingAccountEmails:Set<String>)async throws->MailScanPage? {
  incremental += 1;scopes.append(excludingAccountEmails);return .init(senders:[],currentCount:0)
 }
 func page(mailbox:MailScanMailbox,start:Int,size:Int)async throws->MailScanPage {.init(senders:[],currentCount:0)}
}
private struct RoutingContacts:ContactsScannerPort {
 func batches()->AsyncThrowingStream<[ContactSnapshot],Error> {AsyncThrowingStream {$0.finish()}}
}
private actor RoutingGmail:GmailHTTPTransport {
 var status:Int
 var finished=false
 init(_ status:Int){self.status=status}
 func data(for request:URLRequest)async throws->(Data,HTTPURLResponse) {
  try await Task.sleep(for:.milliseconds(20));finished=true
  return (Data(#"{"historyId":"102"}"#.utf8),HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:nil)!)
 }
}
final class V017RoutingTests:XCTestCase {
 func testOnlyHealthyExactAuthenticatedMailboxesBecomePrimary() {
  let now=Date()
  let accounts=[
   GmailAccount(id:"1",email:"PRIMARY@GMAIL.COM",cursor:.init(historyID:"100",lastCheck:now)),
   GmailAccount(id:"2",email:"retry@gmail.com",cursor:.init(historyID:"100",lastCheck:now,retryAfter:now.addingTimeInterval(300))),
   GmailAccount(id:"3",email:"stale@gmail.com",cursor:.init(historyID:"100",lastCheck:now.addingTimeInterval(-181))),
   GmailAccount(id:"4",email:"new@gmail.com"),
   GmailAccount(id:"7",email:"bootstrap@gmail.com",cursor:.init(bootstrapHistoryID:"100",pageToken:"next",lastCheck:now)),
   GmailAccount(id:"8",email:"catchup@gmail.com",cursor:.init(historyID:"100",historyPageToken:"next",lastCheck:now)),
   GmailAccount(id:"5",email:"failed@gmail.com",cursor:.init(historyID:"100",lastCheck:now),issue:"Network"),
   GmailAccount(id:"6",email:"future@gmail.com",cursor:.init(historyID:"100",lastCheck:now.addingTimeInterval(61)))
  ]
  XCTAssertEqual(MailProviderRouting.primaryEmails(accounts,now:now),["primary@gmail.com"])
  XCTAssertTrue(MailProviderRouting.primaryEmails([],now:now).isEmpty)
 }
 @MainActor func testGmailFirstFailureFallbackThenRecovery()async throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer{try? FileManager.default.removeItem(at:root)}
  let mail=RoutingMail(),now=Date()
  let m=AppModel(demo:false,rootOverride:root,mailScanner:mail,contactScanner:RoutingContacts())
  m.automation.contacts=false;m.automation.setupComplete=true
  m.useWebsite=false;m.useGravatar=false;m.mailSync.enabled=false
  m.allowsHistoryScan=false
  m.gmailTokenProvider={_ in "local-fixture"}
  m.gmail.accounts=[GmailAccount(id:"1",email:"primary@gmail.com",cursor:.init(historyID:"100"))]
  let healthy=RoutingGmail(200);m.gmailAPI=GmailAPI(transport:healthy)
  m.kickGmailSync(now:now)
  try await m.automaticallyDiscover(now:now)
  let finished=await healthy.finished,first=await mail.scopes
  XCTAssertTrue(finished);XCTAssertEqual(first,[["primary@gmail.com"]])
  XCTAssertEqual(m.automation.mailPrimaryGmailEmails,["primary@gmail.com"])

  // The Mail cursor is fresh, but losing a primary must still force an inbox
  // catch-up. An unrelated account's recent cursor must not skip this outage.
  m.gmailAPI=GmailAPI(transport:RoutingGmail(429))
  let failedAt=now.addingTimeInterval(61)
  m.kickGmailSync(now:failedAt)
  try await m.automaticallyDiscover(now:failedAt)
  let failed=await mail.scopes,count=await mail.incremental
  XCTAssertEqual(failed.last,Set<String>())
  XCTAssertEqual(count,0)
  XCTAssertNotNil(m.gmail.accounts[0].issue)
  XCTAssertEqual(m.gmail.accounts[0].cursor.retryAfter,failedAt.addingTimeInterval(300))
  XCTAssertEqual(m.automation.mailPrimaryGmailEmails,[])

  m.gmailAPI=GmailAPI(transport:RoutingGmail(200))
  let recovery=failedAt.addingTimeInterval(301)
  m.kickGmailSync(now:recovery)
  try await m.automaticallyDiscover(now:recovery)
  let recovered=await mail.scopes
  XCTAssertEqual(recovered.last,["primary@gmail.com"])
  XCTAssertNil(m.gmail.accounts[0].issue)
  XCTAssertTrue(try m.engine.records().isEmpty)
 }
 @MainActor func testMissingMailPermissionDoesNotBlockGmail()async throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer{try? FileManager.default.removeItem(at:root)}
  let mail=RoutingMail(),m=AppModel(demo:false,rootOverride:root,mailScanner:mail,contactScanner:RoutingContacts())
  m.automation.contacts=false;m.automation.setupComplete=true;m.mailAutomationAvailable=false
  m.useWebsite=false;m.useGravatar=false;m.mailSync.enabled=false
  m.gmailTokenProvider={_ in "local-fixture"};m.gmailAPI=GmailAPI(transport:RoutingGmail(200))
  m.gmail.accounts=[GmailAccount(id:"1",email:"primary@gmail.com",cursor:.init(historyID:"100"))]
  m.kickGmailSync();try await m.automaticallyDiscover(now:Date())
  XCTAssertEqual(m.gmail.accounts[0].cursor.historyID,"102")
  let scopes=await mail.scopes;XCTAssertTrue(scopes.isEmpty)
 }
 @MainActor func testFailedMailCatchupRetainsBackoffAndPendingSweep()async throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer{try? FileManager.default.removeItem(at:root)}
  let mail=RoutingMail(),now=Date()
  await mail.setFailure()
  let m=AppModel(demo:true,rootOverride:root,mailScanner:mail,contactScanner:RoutingContacts(),backgroundWorkAllowed:false)
  m.automation.contacts=false;m.gmail.accounts=[GmailAccount(id:"1",email:"primary@gmail.com",cursor:.init(historyID:"100",lastCheck:now))]
  try await m.automaticallyDiscover(now:now)
  XCTAssertEqual(m.automation.mailRetryAfter,now.addingTimeInterval(300))
  XCTAssertEqual(m.automation.mailRoutingCatchup,true)
  try await m.automaticallyDiscover(now:now.addingTimeInterval(30))
  let scopes=await mail.scopes
  XCTAssertEqual(scopes.count,1)
  XCTAssertEqual(m.automation.mailRoutingCatchup,true)
 }
 @MainActor func testMailRoutingScriptCompiles()throws {
  let script=try XCTUnwrap(NSAppleScript(source:MailScanScripts.source))
  var error:NSDictionary?
  XCTAssertTrue(script.compileAndReturnError(&error),"\(String(describing:error))")
 }
}
