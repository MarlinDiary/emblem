import XCTest
@testable import MailPortrait
import PortraitCore

private struct EmptyMail:MailScannerPort {
 func inventory(source:ScanSource)async throws->MailScanInventory {.init(mailboxes:[],warnings:[])}
 func page(mailbox:MailScanMailbox,start:Int,size:Int)async throws->MailScanPage {.init(senders:[],currentCount:0)}
}
private struct EmptyContacts:ContactsScannerPort {
 func batches()->AsyncThrowingStream<[ContactSnapshot],Error> {AsyncThrowingStream {$0.finish()}}
}
final class V017DateIsolationTests:XCTestCase {
 @MainActor func testAppleMailSweepPreservesConnectedGmailReceivedDate()async throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer {try? FileManager.default.removeItem(at:root)}
  let m=AppModel(demo:true,rootOverride:root,mailScanner:EmptyMail(),contactScanner:EmptyContacts(),backgroundWorkAllowed:false)
  let received=Date(timeIntervalSince1970:1789286400)
  m.gmail.accounts=[GmailAccount(id:"fixture",email:"gmail-fixture@gmail.com")]
  m.rows=[SenderRow(email:EmailAddress("billing@raycast.com")!,name:"Raycast",selectionIsManual:true,lastInboxReceivedAt:received)]
  await m.performScan(.inbox,automatic:true)
  XCTAssertEqual(m.scanReport?.phase,.completed)
  XCTAssertEqual(m.rows.first?.lastInboxReceivedAt,received)
  XCTAssertEqual(m.rows.first?.selectionIsManual,true)
 }
}
