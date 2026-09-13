import XCTest
import AppKit
import PortraitCore
@testable import Emblem

private actor TestMailScanner: MailScannerPort {
    let boxes: [MailScanMailbox]
    let senders: [String:[String]]
    let failed: Set<String>
    let delayAfterFirst: Bool
    var calls: [(Int,Int)] = []
    init(_ senders: [String:[String]], failed: Set<String> = [], delayAfterFirst: Bool = false) {
        self.senders=senders; self.failed=failed; self.delayAfterFirst=delayAfterFirst
        boxes=senders.keys.sorted().map { .init(account:"test",path:[$0],label:$0,count:senders[$0]!.count) }
    }
    func inventory(source: ScanSource) async throws -> MailScanInventory { .init(mailboxes:boxes,warnings:[]) }
    func page(mailbox: MailScanMailbox,start: Int,size: Int) async throws -> MailScanPage {
        calls.append((start,size))
        if failed.contains(mailbox.label) { throw PortraitError.message("Fixture mailbox offline") }
        if delayAfterFirst && start>1 { try await Task.sleep(nanoseconds:3_000_000_000) }
        let all=senders[mailbox.label]!
        return .init(senders:Array(all.dropFirst(start-1).prefix(size)),currentCount:all.count)
    }
}
private struct TestContactsScanner: ContactsScannerPort {
    var contacts: [ContactSnapshot]
    func batches() -> AsyncThrowingStream<[ContactSnapshot],Error> {
        AsyncThrowingStream { stream in
            for start in stride(from:0,to:contacts.count,by:2) { stream.yield(Array(contacts[start..<min(start+2,contacts.count)])) }
            stream.finish()
        }
    }
}
final class ScanModelTests: XCTestCase {
    @MainActor func makeModel(mail: (any MailScannerPort)? = nil,contacts: (any ContactsScannerPort)? = nil) -> (AppModel,URL) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("emblem-scan-"+UUID().uuidString)
        return (AppModel(demo:true,rootOverride:root,mailScanner:mail,contactScanner:contacts),root)
    }
    @MainActor func settle(_ model: AppModel) async throws {
        for _ in 0..<3000 { if !model.busy && !model.isScanning && model.discoveryTask == nil { return }; try await Task.sleep(nanoseconds:1_000_000) }
        XCTFail("scan did not settle")
    }
    func testNativeMailScriptsCompileWithoutExecuting() throws {
        let script=try XCTUnwrap(NSAppleScript(source:MailScanScripts.source))
        var error:NSDictionary?
        XCTAssertTrue(script.compileAndReturnError(&error),"\(error ?? [:])")
        XCTAssertNil(error)
        XCTAssertTrue(MailScanScripts.source.contains("if (current date) >= pageDeadline"))
        XCTAssertFalse(MailScanScripts.source.contains("read status"))
        XCTAssertFalse(MailScanScripts.source.contains("subject of"))
        XCTAssertFalse(MailScanScripts.source.contains("content of"))
    }
    func testTypedMailboxParametersPreserveQuotesAndUnicode() {
        let value=ScriptValue.list([.text("Folder \"quoted\" \\ 子目录"),.number(201),.list([.text("nested")])])
        let decoded=ScriptValue.read(value.descriptor).values
        XCTAssertEqual(decoded[0].string,"Folder \"quoted\" \\ 子目录")
        XCTAssertEqual(decoded[1].integer,201)
        XCTAssertEqual(decoded[2].values[0].string,"nested")
    }
    @MainActor func testAllMailPagingBeyondTwoHundredAndRepeatIsIdempotent() async throws {
        let input=(0..<451).map { "Sender \($0) <sender\($0)@example.org>" }
        let mail=TestMailScanner(["inbox":input])
        let (model,root)=makeModel(mail:mail);defer { try? FileManager.default.removeItem(at:root) }
        model.startScan(.allMail);try await settle(model)
        XCTAssertEqual(model.rows.count,451);XCTAssertEqual(model.scanReport?.examined,451)
        XCTAssertEqual(model.scanReport?.added,451);XCTAssertEqual(model.scanReport?.phase,.completed)
        let calls=await mail.calls
        XCTAssertEqual(calls.map(\.0),[1,201,401]);XCTAssertEqual(calls.map(\.1),[200,200,51])
        XCTAssertTrue(model.mailConnected);XCTAssertTrue(try model.engine.records().isEmpty)
        model.startScan(.allMail);try await settle(model)
        XCTAssertEqual(model.rows.count,451);XCTAssertEqual(model.scanReport?.added,0);XCTAssertEqual(model.scanReport?.existing,451)
        let reopened=AppModel(demo:true,rootOverride:root)
        XCTAssertEqual(reopened.rows.count,451);XCTAssertEqual(reopened.scanReport?.phase,.completed)
    }
    @MainActor func testCancelKeepsOnlyCompletedPagesAndPersistsStoppedStatus() async throws {
        let mail=TestMailScanner(["inbox":(0..<450).map { "s\($0)@example.org" }],delayAfterFirst:true)
        let (model,root)=makeModel(mail:mail);defer { try? FileManager.default.removeItem(at:root) }
        model.startScan(.allMail)
        for _ in 0..<1000 { if model.scanReport?.examined==200 { break }; try await Task.sleep(nanoseconds:1_000_000) }
        XCTAssertEqual(model.scanReport?.examined,200)
        model.cancel();try await settle(model)
        XCTAssertEqual(model.rows.count,200);XCTAssertEqual(model.scanReport?.phase,.stopped)
        let reopened=AppModel(demo:true,rootOverride:root)
        XCTAssertEqual(reopened.rows.count,200);XCTAssertEqual(reopened.scanReport?.phase,.stopped)
        XCTAssertTrue(try model.engine.records().isEmpty)
    }
    @MainActor func testPartialFailureContinuesOtherMailboxesAndReportsIt() async throws {
        let mail=TestMailScanner(["a-offline":["lost@example.org"],"b-online":["ok@example.org","ok@example.org","bad"]],failed:["a-offline"])
        let (model,root)=makeModel(mail:mail);defer { try? FileManager.default.removeItem(at:root) }
        model.startScan(.allMail);try await settle(model)
        XCTAssertEqual(model.rows.count,1);XCTAssertEqual(model.scanReport?.examined,3)
        XCTAssertEqual(model.scanReport?.phase,.partial);XCTAssertEqual(model.scanReport?.warnings.count,1)
        XCTAssertEqual(model.scanReport?.invalid,1);XCTAssertEqual(model.scanReport?.duplicateEntries,1)
        XCTAssertEqual(model.scanReport?.completedMailboxes,1)
    }
    @MainActor func testContactsEnumerateAllEmailsSkipNoEmailAndDoNotGuessDuplicates() async throws {
        let contacts=TestContactsScanner(contacts:[
            .init(id:"a",name:"A",emails:["a@example.org","second@example.org"],image:Data([1])),
            .init(id:"b",name:"B",emails:[],image:nil),
            .init(id:"c",name:"C",emails:["bad", "a@example.org"],image:nil)])
        let (model,root)=makeModel(contacts:contacts);defer { try? FileManager.default.removeItem(at:root) }
        model.startScan(.contacts);try await settle(model)
        XCTAssertEqual(model.rows.count,2);XCTAssertEqual(model.scanReport?.examined,3)
        XCTAssertEqual(model.scanReport?.withoutEmail,1);XCTAssertEqual(model.scanReport?.invalid,1)
        XCTAssertNil(model.rows.first { $0.id=="a@example.org" }?.current)
        XCTAssertEqual(model.rows.first { $0.id=="a@example.org" }?.notes.count,1)
        XCTAssertEqual(model.rows.first { $0.id=="second@example.org" }?.current?.id,"a")
        XCTAssertEqual(model.pendingCount,1)
        XCTAssertTrue(try model.engine.records().isEmpty)
    }
    @MainActor func testScanPreservesExistingAppliedIgnoredManualSourceAndJournal() async throws {
        let mail=TestMailScanner(["inbox":["hello@northstar.example","team@paperplane.example","new@example.org"]])
        let (model,root)=makeModel(mail:mail);defer { try? FileManager.default.removeItem(at:root) }
        model.loadDemo()
        let first=model.rows[0].id
        model.prepareApply(ids:[first]);model.allowCreate=true;model.confirmApply();try await settle(model)
        model.ignore("team@paperplane.example",ignored:true)
        model.rows[0].website="https://github.com"
        let beforeJournal=try Data(contentsOf:root.appendingPathComponent("changes.json"))
        let candidate=model.rows[0].chosen?.id
        model.startScan(.allMail);try await settle(model)
        XCTAssertTrue(model.rows.first { $0.id==first }!.completed)
        XCTAssertEqual(model.rows.first { $0.id==first }!.chosen?.id,candidate)
        XCTAssertEqual(model.rows.first { $0.id==first }!.website,"https://github.com")
        XCTAssertTrue(model.rows.first { $0.id=="team@paperplane.example" }!.ignored)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("changes.json")),beforeJournal)
        XCTAssertEqual(model.scanReport?.added,1)
    }
    @MainActor func testScanningClearsOldSearchAndAppliedFilter() async throws {
        let mail=TestMailScanner(["inbox":["new@example.org"]])
        let (model,root)=makeModel(mail:mail);defer { try? FileManager.default.removeItem(at:root) }
        model.section="completed";model.search="old search"
        model.startScan(.allMail);try await settle(model)
        XCTAssertEqual(model.section,"all");XCTAssertEqual(model.search,"")
        XCTAssertEqual(model.visibleRows.count,1)
    }
    @MainActor func testUnreadableItemsAreReportedRatherThanSilentSuccess() async throws {
        struct UnreadableScanner: MailScannerPort {
            func inventory(source: ScanSource) async throws -> MailScanInventory { .init(mailboxes:[.init(account:"test",path:["folder"],label:"folder",count:2)],warnings:[]) }
            func page(mailbox:MailScanMailbox,start:Int,size:Int) async throws -> MailScanPage { .init(senders:["valid@example.org", ""],currentCount:2,unreadable:1) }
        }
        let (model,root)=makeModel(mail:UnreadableScanner());defer { try? FileManager.default.removeItem(at:root) }
        model.startScan(.allMail);try await settle(model)
        XCTAssertEqual(model.rows.count,1);XCTAssertEqual(model.scanReport?.examined,2)
        XCTAssertEqual(model.scanReport?.invalid,1);XCTAssertEqual(model.scanReport?.phase,.partial)
        XCTAssertEqual(model.scanReport?.warnings.count,1)
    }
    @MainActor func testUnfinishedReportRestoresAsStoppedAndManualLimitRemainsExplicit() throws {
        let (model,root)=makeModel();defer { try? FileManager.default.removeItem(at:root) }
        model.importAddresses((0..<250).map { "a\($0)@example.org" }.joined(separator:"\n"),limit:200)
        XCTAssertEqual(model.rows.count,200)
        model.scanReport=ScanReport(source:.allMail);try model.persistScan()
        let reopened=AppModel(demo:true,rootOverride:root)
        XCTAssertEqual(reopened.scanReport?.phase,.stopped)
        XCTAssertEqual(reopened.scanReport?.warnings.count,1)
    }
}
