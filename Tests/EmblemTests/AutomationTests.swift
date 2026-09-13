import XCTest
import AppKit
import Contacts
import PortraitCore
@testable import Emblem

private actor AutoClient: ResourceFetching {
    let png: Data
    var requests = [URL]()
    let delay: UInt64
    let failure: Bool
    init(png: Data, delay: UInt64 = 0, failure: Bool = false) { self.png=png; self.delay=delay; self.failure=failure }
    func fetch(_ url: URL, limit: Int) async throws -> WebResource {
        requests.append(url)
        if delay > 0 { try await Task.sleep(nanoseconds:delay) }
        try Task.checkCancellation()
        if failure { throw HTTPResourceError(status:503) }
        if url.path == "/apple-touch-icon.png" { return .init(data:png,url:url) }
        if url.path == "/" { return .init(data:Data("<html/>".utf8),url:url) }
        throw HTTPResourceError(status:404)
    }
}
private struct AutoContacts: ContactsScannerPort {
    func batches() -> AsyncThrowingStream<[ContactSnapshot],Error> {
        AsyncThrowingStream { s in
            s.yield([.init(id:"existing",name:"Has Photo",emails:["photo@company.org"],image:Data([7]))]); s.finish()
        }
    }
}
private actor AutoMail: MailScannerPort {
    var inventories = 0
    func inventory(source:ScanSource) async throws -> MailScanInventory {
        inventories += 1
        return .init(mailboxes:[.init(account:"local",path:["Inbox"],label:"Inbox",count:2)],warnings:[])
    }
    func page(mailbox:MailScanMailbox,start:Int,size:Int) async throws -> MailScanPage {
        .init(senders:["Sender <a@company.org>","photo@company.org"],currentCount:2)
    }
}
final class AutomationTests: XCTestCase {
    @MainActor private func model(delay: UInt64 = 0, failure: Bool = false) throws -> (AppModel,URL,AutoClient) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("auto-"+UUID().uuidString)
        let png = try DemoImages.candidate(symbol:"star.fill",color:.systemBlue).png
        let client = AutoClient(png:png,delay:delay,failure:failure)
        let model = AppModel(demo:false,rootOverride:root,resolverFactory:{ AvatarResolver(client:client) })
        model.automation.mail = false; model.automation.contacts = false
        return (model,root,client)
    }
    @MainActor func settle(_ model: AppModel) async throws {
        for _ in 0..<10000 {
            if !model.automaticWorking && !model.busy { return }
            try await Task.sleep(nanoseconds:1_000_000)
        }
        XCTFail("Automatic work did not settle")
    }
    @MainActor func testNothingStartsBeforeOneTimeSetup() async throws {
        let (m,root,client) = try model(); defer { try? FileManager.default.removeItem(at:root) }
        m.importAddresses("a@company.org"); m.automaticTick(); try await settle(m)
        let calls = await client.requests
        XCTAssertTrue(calls.isEmpty); XCTAssertFalse(m.contactsConnected); XCTAssertTrue(try m.engine.records().isEmpty)
    }
    @MainActor func testAutomaticBatchBeyondFiftyWithoutButtonsAndRestartDoesNotRepeat() async throws {
        let (m,root,client) = try model(); defer { try? FileManager.default.removeItem(at:root) }
        m.importAddresses((0..<61).map { "a\($0)@mail.company.org" }.joined(separator:"\n"))
        m.enableAutomaticSetup(); try await settle(m)
        XCTAssertEqual(m.rows.filter { $0.chosen != nil }.count,61)
        XCTAssertEqual(m.automaticFinished,61); XCTAssertNil(m.errorText)
        XCTAssertTrue(try m.engine.records().isEmpty); XCTAssertFalse(m.showApplyConfirmation)
        let first = await client.requests
        XCTAssertEqual(first.filter { $0.absoluteString == "https://company.org/" }.count,1)
        XCTAssertFalse(first.contains { $0.host == "mail.company.org" || $0.host == "www.gravatar.com" })
        let reopened = AppModel(demo:false,rootOverride:root,resolverFactory:{ AvatarResolver(client:client) })
        XCTAssertTrue(reopened.useWebsite); XCTAssertFalse(reopened.useGravatar); XCTAssertTrue(reopened.automation.setupComplete)
        reopened.automaticTick(); try await settle(reopened)
        let second = await client.requests; XCTAssertEqual(first,second)
        let permissions = try FileManager.default.attributesOfItem(atPath:reopened.automationURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions,0o600)
    }
    @MainActor func testReadOnlyEndToEndDiscoveryLinksContactsAndLooksUpNewMailSender() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let client = AutoClient(png:try DemoImages.candidate(symbol:"star",color:.systemBlue).png)
        let mail = AutoMail()
        let m = AppModel(demo:false,rootOverride:root,resolverFactory:{ AvatarResolver(client:client) },mailScanner:mail,contactScanner:AutoContacts())
        m.enableAutomaticSetup(); try await settle(m)
        XCTAssertEqual(m.rows.count,2); XCTAssertTrue(m.mailConnected); XCTAssertTrue(m.contactsConnected)
        XCTAssertEqual(m.rows.first { $0.id == "photo@company.org" }?.current?.image,Data([7]))
        XCTAssertNil(m.rows.first { $0.id == "photo@company.org" }?.lastLookup)
        XCTAssertNotNil(m.rows.first { $0.id == "a@company.org" }?.chosen)
        XCTAssertTrue(try m.engine.records().isEmpty)
        m.automaticTick(); try await settle(m)
        let inventoryCount = await mail.inventories; XCTAssertEqual(inventoryCount,1)
    }
    @MainActor func testIgnoredCompletedExistingPhotosAndManualChoicesArePreserved() async throws {
        let (m,root,client) = try model(); defer { try? FileManager.default.removeItem(at:root) }
        m.importAddresses("ignore@company.org\ndone@company.org\nphoto@company.org\nmanual@company.org\nfresh@company.org")
        m.rows[0].ignored=true; m.rows[1].completed=true
        m.rows[2].current = .init(id:"p",name:"P",emails:[m.rows[2].id],image:Data([2]))
        let manual = try DemoImages.candidate(symbol:"heart",color:.systemRed)
        m.addCandidate(manual,to:m.rows[3].id)
        m.enableAutomaticSetup(); try await settle(m)
        XCTAssertNil(m.rows[0].lastLookup); XCTAssertNil(m.rows[1].lastLookup); XCTAssertNil(m.rows[2].lastLookup)
        XCTAssertEqual(m.rows[3].chosen?.id,manual.id); XCTAssertNil(m.rows[3].lastLookup)
        XCTAssertNotNil(m.rows[4].chosen); XCTAssertEqual(m.automaticTotal,1)
        let requests = await client.requests; XCTAssertFalse(requests.isEmpty)
    }
    @MainActor func testSelectionDuringInflightLookupWinsAndUIIsNotBusy() async throws {
        let (m,root,_) = try model(delay:30_000_000); defer { try? FileManager.default.removeItem(at:root) }
        m.importAddresses("a@company.org"); m.enableAutomaticSetup()
        try await Task.sleep(nanoseconds:5_000_000)
        XCTAssertTrue(m.automaticWorking); XCTAssertFalse(m.busy)
        let manual = try DemoImages.candidate(symbol:"heart",color:.systemRed)
        m.addCandidate(manual,to:m.rows[0].id)
        try await settle(m)
        XCTAssertEqual(m.rows[0].chosen?.id,manual.id); XCTAssertNil(m.rows[0].lastLookup)
    }
    @MainActor func testPauseCancelsInflightAndResumeCompletes() async throws {
        let (m,root,_) = try model(delay:30_000_000); defer { try? FileManager.default.removeItem(at:root) }
        m.importAddresses("a@company.org"); m.enableAutomaticSetup()
        try await Task.sleep(nanoseconds:5_000_000); m.pauseAutomatic(); try await settle(m)
        XCTAssertNil(m.rows[0].lastLookup); XCTAssertFalse(m.automaticEnabled)
        m.automaticEnabled = true; m.automaticTick(); try await settle(m)
        XCTAssertNotNil(m.rows[0].chosen)
    }
    @MainActor func testSourceRevocationCancelsAndPersists() async throws {
        let (m,root,_) = try model(delay:30_000_000); defer { try? FileManager.default.removeItem(at:root) }
        m.importAddresses("a@company.org"); m.enableAutomaticSetup()
        try await Task.sleep(nanoseconds:5_000_000); m.useWebsite=false; try await settle(m)
        XCTAssertNil(m.rows[0].lastLookup)
        XCTAssertFalse(AppModel(demo:false,rootOverride:root).useWebsite)
    }
    @MainActor func testTransientFailureIsBackedOffNotRetriedEveryTick() async throws {
        let (m,root,client) = try model(failure:true); defer { try? FileManager.default.removeItem(at:root) }
        m.importAddresses("a@company.org"); m.enableAutomaticSetup(); try await settle(m)
        let first = await client.requests
        m.automaticTick(); try await settle(m)
        let second = await client.requests; XCTAssertEqual(first,second)
        let row = m.rows[0], now = try XCTUnwrap(row.lastLookup)
        XCTAssertFalse(AutomaticLookupPolicy.due(row,website:true,gravatar:false,now:now.addingTimeInterval(3599)))
        XCTAssertTrue(AutomaticLookupPolicy.due(row,website:true,gravatar:false,now:now.addingTimeInterval(3601)))
    }
    @MainActor func testRemovedRowsStayRemovedAcrossAutomaticScansAndRestart() throws {
        let (m,root,_) = try model(); defer { try? FileManager.default.removeItem(at:root) }
        m.importAddresses("a@company.org"); m.removeFromList("a@company.org")
        let re = AppModel(demo:false,rootOverride:root)
        var seen = Set<String>()
        re.ingestScanned(email:EmailAddress("a@company.org")!,name:"A",seen:&seen)
        XCTAssertTrue(re.rows.isEmpty)
        re.importAddresses("a@company.org"); XCTAssertEqual(re.rows.count,1)
    }
    @MainActor func testInvalidWebsiteDoesNotBlockFollowingSenders() async throws {
        let (m,root,_) = try model(); defer { try? FileManager.default.removeItem(at:root) }
        m.importAddresses("bad@a.invalid\ngood@company.org")
        m.enableAutomaticSetup(); try await settle(m)
        XCTAssertNotNil(m.rows[0].lastLookup)
        // A failed website now offers explicitly local typography, while the
        // following sender still receives its real website image.
        XCTAssertEqual(m.rows.first{$0.id=="bad@a.invalid"}?.chosen?.source, .monogram)
        XCTAssertEqual(m.rows.first{$0.id=="good@company.org"}?.chosen?.source, .touchIcon)
        XCTAssertTrue(try m.engine.records().isEmpty)
        XCTAssertEqual(m.automaticFinished,2)
    }
    @MainActor func testContactsOptOutIsHonoredDuringMailScan() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let client = AutoClient(png:try DemoImages.candidate(symbol:"star",color:.systemBlue).png)
        let m = AppModel(demo:false,rootOverride:root,resolverFactory:{ AvatarResolver(client:client) },mailScanner:AutoMail(),contactScanner:AutoContacts())
        m.automation.contacts = false; m.enableAutomaticSetup(); try await settle(m)
        XCTAssertFalse(m.contactsConnected)
        XCTAssertNil(m.rows.first { $0.id == "photo@company.org" }?.current)
    }
    @MainActor func testVisibleSenderGetsAutomaticPriorityWithoutClickingLookup() async throws {
        let (m,root,_) = try model(delay:30_000_000); defer { try? FileManager.default.removeItem(at:root) }
        m.importAddresses("a@alpha.org\nz@zeta.org")
        m.selectedID = "z@zeta.org"
        m.enableAutomaticSetup()
        for _ in 0..<1000 { if m.activeLookups.count == 2 { break };try await Task.sleep(for:.milliseconds(1)) }
        // Child tasks run concurrently, so HTTP arrival order is deliberately not
        // contractual. The visible sender must be first in the dispatch queue.
        XCTAssertEqual(m.activeLookups.first?.host,"zeta.org")
        try await settle(m)
        XCTAssertEqual(m.automaticFinished,2)
    }
    func testSystemPermissionStateOverridesOldPromptFlagAfterAnUpdate() {
        XCTAssertTrue(AutomaticConnectionPolicy.mayRequestContacts(.notDetermined))
        XCTAssertTrue(AutomaticConnectionPolicy.mayRequestContacts(.authorized))
        XCTAssertFalse(AutomaticConnectionPolicy.mayRequestContacts(.denied))
        XCTAssertFalse(AutomaticConnectionPolicy.mayRequestContacts(.restricted))
    }
    func testOldSelectedRowsAreConservativelyPreserved() throws {
        var row = SenderRow(email:EmailAddress("a@company.org")!,name:"A")
        let image = AvatarCandidate(source:.touchIcon,origin:"url",width:256,height:256,png:Data())
        row.candidates=[image]; row.selectedCandidate=image.id
        var json = try JSONSerialization.jsonObject(with:JSONEncoder().encode(row)) as! [String:Any]
        json.removeValue(forKey:"selectionIsManual")
        let old = try JSONDecoder().decode(SenderRow.self,from:JSONSerialization.data(withJSONObject:json))
        XCTAssertNil(old.selectionIsManual)
        XCTAssertFalse(AutomaticLookupPolicy.due(old,website:true,gravatar:false,now:Date()))
    }

    @MainActor func testInstitutionPeopleDoNotShareOneDomainLookupResult() {
        let first = SenderRow(email: EmailAddress("v.terragni@auckland.ac.nz")!, name: "Valerio Terragni")
        let second = SenderRow(email: EmailAddress("elliott.wen@auckland.ac.nz")!, name: "Elliott Wen")
        let service = SenderRow(email: EmailAddress("studentinfo@auckland.ac.nz")!, name: "University of Auckland")
        XCTAssertNotEqual(AppModel.lookupJobKey(first, gravatar: false), AppModel.lookupJobKey(second, gravatar: false))
        XCTAssertEqual(AppModel.lookupJobKey(service, gravatar: false), "auckland.ac.nz")
    }
}
