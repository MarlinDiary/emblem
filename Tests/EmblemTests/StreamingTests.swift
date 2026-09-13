import XCTest
import AppKit
import PortraitCore
@testable import Emblem

private actor StreamGate {
    var opened = false
    var waiters: [CheckedContinuation<Void,Never>] = []
    func wait() async { if !opened { await withCheckedContinuation { waiters.append($0) } } }
    func open() { opened = true; let pending = waiters; waiters = []; pending.forEach { $0.resume() } }
}
private actor StreamingMail: MailScannerPort {
    let gate: StreamGate
    init(_ gate: StreamGate) { self.gate = gate }
    func inventory(source: ScanSource) async throws -> MailScanInventory {
        .init(mailboxes:[.init(account:"local",path:["Inbox"],label:"Inbox",count:201)],warnings:[])
    }
    func page(mailbox: MailScanMailbox, start: Int, size: Int) async throws -> MailScanPage {
        if start > 1 { await gate.wait() }
        return .init(senders:start == 1 ? Array(repeating:"Anthropic <hello@anthropic.com>",count:200) : ["Anthropic <news@anthropic.com>"],currentCount:201)
    }
}
private actor StreamingClient: ResourceFetching {
    let png: Data
    let slow: StreamGate?
    init(png: Data, slow: StreamGate? = nil) { self.png = png; self.slow = slow }
    func fetch(_ url: URL, limit: Int) async throws -> WebResource {
        if url.host == "anthropic.com", let slow { await slow.wait() }
        try Task.checkCancellation()
        if url.path == "/" { return .init(data:Data("<html/>".utf8),url:url) }
        if url.path == "/apple-touch-icon.png" { return .init(data:png,url:url) }
        throw HTTPResourceError(status:404)
    }
}
final class StreamingTests: XCTestCase {
    @MainActor func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<1500 { if condition() { return }; try await Task.sleep(nanoseconds:1_000_000) }
    }
    @MainActor func testPreviewAppearsBeforeFinalMailPage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let gate = StreamGate()
        let client = StreamingClient(png:try DemoImages.candidate(symbol:"star",color:.systemBlue).png)
        let m = AppModel(demo:false,rootOverride:root,resolverFactory:{ AvatarResolver(client:client) },mailScanner:StreamingMail(gate))
        m.automation.contacts = false; m.enableAutomaticSetup()
        try await waitUntil { m.rows.first?.chosen != nil }
        XCTAssertTrue(m.isScanning, "Mail's final page is still gated")
        XCTAssertNotNil(m.rows.first?.chosen, "First-page preview must arrive before the final page")
        await gate.open()
        try await waitUntil { !m.automaticWorking && !m.busy }
        XCTAssertEqual(m.rows.count,2); XCTAssertTrue(try m.engine.records().isEmpty)
        m.pauseAutomatic(); try? FileManager.default.removeItem(at:root)
    }
    @MainActor func testSlowSiteDoesNotBlockAnotherSite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let gate = StreamGate()
        let client = StreamingClient(png:try DemoImages.candidate(symbol:"star",color:.systemBlue).png,slow:gate)
        let m = AppModel(demo:false,rootOverride:root,resolverFactory:{ AvatarResolver(client:client) })
        m.automation.mail = false; m.automation.contacts = false
        m.importAddresses("Anthropic <hello@anthropic.com>\nGitHub <hello@github.com>")
        m.selectedID = "hello@anthropic.com"; m.enableAutomaticSetup()
        try await waitUntil { m.rows.first { $0.email.domain == "github.com" }?.chosen != nil }
        XCTAssertNotNil(m.rows.first { $0.email.domain == "github.com" }?.chosen, "A delayed site must not hold other sites behind it")
        XCTAssertNil(m.rows.first { $0.email.domain == "anthropic.com" }?.lastLookup)
        await gate.open(); try await waitUntil { !m.automaticWorking }
        XCTAssertTrue(try m.engine.records().isEmpty)
        m.pauseAutomatic(); try? FileManager.default.removeItem(at:root)
    }
    @MainActor func testTimeoutMovesQueueOnAndLateResultsDoNotOverwriteChoices() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let gate = StreamGate()
        let client = StreamingClient(png:try DemoImages.candidate(symbol:"star",color:.systemBlue).png,slow:gate)
        let m = AppModel(demo:false,rootOverride:root,resolverFactory:{ AvatarResolver(client:client) })
        m.automation.mail = false; m.automation.contacts = false; m.lookupTimeout = 0.5 // The slow site is explicitly gated; allow image decoding under snapshot-test load.
        m.importAddresses("hello@anthropic.com\nhello@github.com")
        m.enableAutomaticSetup(); try await waitUntil { !m.automaticWorking }
        XCTAssertEqual(m.automaticTimeouts,1); XCTAssertEqual(m.automaticFinished,2)
        XCTAssertEqual(m.rows.first { $0.email.domain == "github.com" }?.chosen?.source,.touchIcon)
        let failed = try XCTUnwrap(m.rows.first { $0.email.domain == "anthropic.com" })
        XCTAssertNotNil(failed.lastLookup); XCTAssertEqual(failed.sourceReports?.first?.outcome,.unavailable)
        let manual = try DemoImages.candidate(symbol:"heart",color:.systemRed)
        m.addCandidate(manual,to:failed.id)
        await gate.open(); try await Task.sleep(for:.milliseconds(30))
        XCTAssertEqual(m.rows.first { $0.id == failed.id }?.chosen?.id,manual.id)
        XCTAssertTrue(try m.engine.records().isEmpty)
        m.pauseAutomatic(); try? FileManager.default.removeItem(at:root)
    }
    @MainActor func testRemovalDuringLookupIsNotResurrected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let gate = StreamGate()
        let client = StreamingClient(png:try DemoImages.candidate(symbol:"star",color:.systemBlue).png,slow:gate)
        let m = AppModel(demo:false,rootOverride:root,resolverFactory:{ AvatarResolver(client:client) })
        m.automation.mail = false; m.automation.contacts = false
        m.importAddresses("hello@anthropic.com"); m.enableAutomaticSetup()
        try await waitUntil { !m.activeLookups.isEmpty }
        m.removeFromList("hello@anthropic.com"); await gate.open()
        try await waitUntil { !m.automaticWorking }
        XCTAssertTrue(m.rows.isEmpty); XCTAssertTrue(try m.engine.records().isEmpty)
        m.pauseAutomatic(); try? FileManager.default.removeItem(at:root)
    }

}
