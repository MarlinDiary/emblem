import XCTest
import PortraitCore
@testable import MailPortrait

private actor RetryBoundaryMail:MailScannerPort {
    var calls:[ScanSource]=[]
    func inventory(source:ScanSource)async throws->MailScanInventory {
        calls.append(source)
        if source == .allMail {throw PortraitError.message("History mailbox unavailable")}
        return .init(mailboxes:[.init(account:"fixture",path:["INBOX"],label:"INBOX",count:1)],warnings:[])
    }
    func page(mailbox:MailScanMailbox,start:Int,size:Int)async throws->MailScanPage {
        .init(senders:["LinkedIn <invitations@linkedin.com>"],currentCount:1,receivedAt:[Date(timeIntervalSinceReferenceDate:1000)])
    }
}
private struct ThrowingRecentMail:MailScannerPort {
    let cancelled:Bool
    func recentInbox(since:Date)async throws->MailScanPage? {
        if cancelled {throw CancellationError()}
        throw PortraitError.message("Inbox temporarily unavailable")
    }
    func inventory(source:ScanSource)async throws->MailScanInventory {throw PortraitError.message("Unexpected full fallback")}
    func page(mailbox:MailScanMailbox,start:Int,size:Int)async throws->MailScanPage {throw PortraitError.message("Unexpected paging")}
}
final class V0144BackgroundTests:XCTestCase {
    @MainActor func testInboxTransportFailureBacksOffButCancellationDoesNot()async throws {
        for cancelled in [false,true] {
            let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer {try? FileManager.default.removeItem(at:root)}
            let m=AppModel(demo:true,rootOverride:root,mailScanner:ThrowingRecentMail(cancelled:cancelled),backgroundWorkAllowed:false)
            let now=Date(),previous=now.addingTimeInterval(-180)
            m.automation.setupComplete=true;m.automation.contacts=false;m.automation.mail=true;m.mailSync.enabled=true
            m.automation.lastInbox=previous;m.automation.lastFullMail=now;m.automation.lastInboxSweep=now
            do {try await m.automaticallyDiscover(now:now);XCTFail("Expected scanner failure")}
            catch {XCTAssertEqual(error is CancellationError,cancelled)}
            XCTAssertEqual(m.automation.lastInbox,previous)
            XCTAssertNil(m.automation.fullMailRetryAfter)
            XCTAssertEqual(m.automation.mailRetryAfter,cancelled ? nil:now.addingTimeInterval(300))
            XCTAssertTrue(try m.engine.records().isEmpty)
        }
    }
    @MainActor func testHistoryFailureDoesNotDelayNewInboxChecks()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let scanner=RetryBoundaryMail(),m=AppModel(demo:true,rootOverride:root,mailScanner:scanner,backgroundWorkAllowed:false)
        let now=Date()
        m.automation.setupComplete=true;m.automation.contacts=false;m.automation.mail=true;m.mailSync.enabled=true
        m.automation.lastInbox=now.addingTimeInterval(-180);m.automation.lastFullMail=now.addingTimeInterval(-90000)
        try await m.automaticallyDiscover(now:now)
        let first=await scanner.calls
        XCTAssertEqual(first,[.inbox]);XCTAssertEqual(m.automation.lastInbox,now)
        try await m.automaticallyDiscover(now:now.addingTimeInterval(30))
        let second=await scanner.calls;XCTAssertEqual(second,[.inbox,.allMail])
        XCTAssertNil(m.automation.mailRetryAfter,"History failure must not close the inbox retry channel")
        try await m.automaticallyDiscover(now:now.addingTimeInterval(90))
        let third=await scanner.calls;XCTAssertEqual(third,[.inbox,.allMail,.inbox])
        XCTAssertEqual(m.automation.lastInbox,now.addingTimeInterval(90))
        XCTAssertEqual(m.rows.count,1);XCTAssertTrue(try m.engine.records().isEmpty)
        print("BACKGROUND_RETRY HISTORY_FAILURE=ISOLATED INBOX_CHECKS=2 REAL_CONTACT_WRITES=0")
    }
    @MainActor func testLegacySharedRetryGetsOneIndependentInboxChance()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let m=AppModel(demo:true,rootOverride:root,backgroundWorkAllowed:false)
        let retry=Date().addingTimeInterval(3600)
        m.automation.mailRetryAfter=retry;m.automation.setupComplete=true;m.saveAutomationPreferences()
        var legacy=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:m.automationURL)) as? [String:Any])
        legacy.removeValue(forKey:"mailRetryChannels")
        try JSONSerialization.data(withJSONObject:legacy).write(to:m.automationURL)
        let reopened=AppModel(demo:true,rootOverride:root,backgroundWorkAllowed:false)
        XCTAssertNil(reopened.automation.mailRetryAfter)
        reopened.saveAutomationPreferences()
        let current=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:reopened.automationURL)) as? [String:Any])
        XCTAssertEqual(current["fullMailRetryAfter"] as? Double,retry.timeIntervalSinceReferenceDate)
        XCTAssertEqual(current["mailRetryChannels"] as? Int,1)
    }
}
