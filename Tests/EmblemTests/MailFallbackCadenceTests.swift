import XCTest
import PortraitCore
@testable import Emblem

private actor EmptyMailbox:MailScannerPort {
    private(set) var inventories=0
    var hasMail=false
    func deliverMail() {hasMail=true}
    func inventory(source:ScanSource,excludingAccountEmails:Set<String>)async throws->MailScanInventory {
        inventories += 1
        return .init(mailboxes:hasMail ? [.init(account:"local",path:["Inbox"],label:"Inbox",count:1)]:[],warnings:[])
    }
    func inventory(source:ScanSource)async throws->MailScanInventory {try await inventory(source:source,excludingAccountEmails:[])}
    func page(mailbox:MailScanMailbox,start:Int,size:Int)async throws->MailScanPage {
        .init(senders:["Sender <someone@company.org>"],currentCount:1)
    }
}

/// Every Apple Mail scan spawns a worker and wakes Mail. A measured helper scanned
/// every 60–75 s for days and examined zero messages, because the only account was
/// already covered by the Gmail API.
final class MailFallbackCadenceTests:XCTestCase {
    func testEmptyScansBackOffWhileRealMailKeepsTheFastCadence() {
        XCTAssertEqual(MailFallbackCadence.interval(consecutiveEmpty:0,syncEnabled:true),60)
        XCTAssertEqual(MailFallbackCadence.interval(consecutiveEmpty:2,syncEnabled:true),60)
        XCTAssertEqual(MailFallbackCadence.interval(consecutiveEmpty:3,syncEnabled:true),300)
        XCTAssertEqual(MailFallbackCadence.interval(consecutiveEmpty:5,syncEnabled:true),300)
        XCTAssertEqual(MailFallbackCadence.interval(consecutiveEmpty:6,syncEnabled:true),900)
        XCTAssertEqual(MailFallbackCadence.interval(consecutiveEmpty:99,syncEnabled:true),900)
        XCTAssertEqual(MailFallbackCadence.interval(consecutiveEmpty:9,syncEnabled:false),900,"Without sync the cadence is already slow")
    }

    func testHelperWakesOnTheSameBackoff() {
        let now=Date()
        let push=GmailPushState(accountKey:String(repeating:"a",count:64),deviceID:UUID().uuidString,registeredAt:now,
                                registrationExpiration:now.addingTimeInterval(180*86_400),watchExpiration:now.addingTimeInterval(7*86_400),
                                lastWatchRenewal:now,deliveryHeartbeat:now)
        let healthy=GmailAccount(id:"account",email:"fixture@gmail.com",push:push)
        XCTAssertEqual(BackgroundSyncAgent.fallbackInterval(mailEnabled:true,emptyInboxScans:0,accounts:[healthy],now:now),60)
        XCTAssertEqual(BackgroundSyncAgent.fallbackInterval(mailEnabled:true,emptyInboxScans:8,accounts:[healthy],now:now),900,
                       "A helper that only finds empty mailboxes must not wake every minute")
        XCTAssertEqual(BackgroundSyncAgent.fallbackInterval(mailEnabled:false,emptyInboxScans:8,accounts:[GmailAccount(id:"regular",email:"fixture@gmail.com")],now:now),60,
                       "An unhealthy Push account still needs the fast fallback")
    }

    @MainActor func testRepeatedEmptyInboxScansStopWakingMailEveryMinute()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("cadence-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let scanner=EmptyMailbox()
        let m=AppModel(demo:false,rootOverride:root,mailScanner:scanner,backgroundWorkAllowed:false)
        m.automation.setupComplete=true;m.automation.contacts=false;m.automation.mail=true
        m.mailSync.enabled=true;m.mailAutomationAvailable=true;m.allowsHistoryScan=false
        let start=Date()
        m.automation.lastInbox=start.addingTimeInterval(-3600)
        for minute in 0..<3 {try await m.automaticallyDiscover(now:start.addingTimeInterval(Double(minute)*60))}
        var scans=await scanner.inventories
        XCTAssertEqual(scans,3,"The first empty scans keep the one-minute cadence")
        try await m.automaticallyDiscover(now:start.addingTimeInterval(180))
        scans=await scanner.inventories
        XCTAssertEqual(scans,3,"After three empty scans a minute is too soon")
        try await m.automaticallyDiscover(now:start.addingTimeInterval(120+300))
        scans=await scanner.inventories
        XCTAssertEqual(scans,4,"The longer interval still scans")
        await scanner.deliverMail()
        try await m.automaticallyDiscover(now:start.addingTimeInterval(120+600))
        scans=await scanner.inventories
        XCTAssertEqual(scans,5)
        XCTAssertEqual(m.automation.emptyInboxScans ?? -1,0,"Real mail restores the fast cadence")
        try await m.automaticallyDiscover(now:start.addingTimeInterval(120+660))
        scans=await scanner.inventories
        XCTAssertEqual(scans,6,"Back to the one-minute cadence after real mail")
    }
}
