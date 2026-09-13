import XCTest
import AppKit
@testable import PortraitCore

final class AddressTests: XCTestCase {
    func testParseAndDeduplicate() { XCTAssertEqual(EmailAddress.parseList("A <a@Example.COM>; a@example.com\nb@company.org").map(\.value), ["a@example.com", "b@company.org"]) }
    func testInvalidAddresses() { for value in ["x", "a@localhost", "a..b@company.org", ".a@company.org", "a.@company.org", "a@-company.org", "a@company..org", "a\n@company.org"] { XCTAssertNil(EmailAddress(value), value) } }
    func testPreserveLocalCase() { XCTAssertEqual(EmailAddress("Alice@Example.COM")?.value, "Alice@example.com") }
    func testSharedMailboxDomains() { XCTAssertTrue(EmailAddress("a@gmail.com")!.isSharedProvider); XCTAssertFalse(EmailAddress("a@company.org")!.isSharedProvider) }
    func testGravatarUsesNormalizedHashAnd404() { let address = EmailAddress("Alice@company.org")!; XCTAssertTrue(address.gravatarURL.absoluteString.contains(digest(Data("alice@company.org".utf8)))); XCTAssertTrue(address.gravatarURL.absoluteString.contains("d=404")) }
}

final class DiscoveryTests: XCTestCase {
    func testTouchIconAndManifestAcrossAttributeOrders() {
        let html = #"<LINK sizes='180x180' HREF='/touch.png' REL='apple-touch-icon'><link href='icons.svg' rel='icon'><link href='/app.webmanifest' rel='manifest'>"#
        let result = IconDiscovery.links(html: html, base: URL(string: "https://company.org/path/")!)
        XCTAssertTrue(result.icons.contains(.init(url: URL(string: "https://company.org/touch.png")!, source: .touchIcon)))
        XCTAssertTrue(result.icons.contains(.init(url: URL(string: "https://company.org/path/icons.svg")!, source: .favicon)))
        XCTAssertEqual(result.manifest?.absoluteString, "https://company.org/app.webmanifest")
    }
    func testIgnoreCommentAndScriptLinks() {
        let result = IconDiscovery.links(html: "<!-- <link rel='icon' href='/bad.png'> --><script>const s = `<link rel='icon' href='/bad2.png'>`;</script>", base: URL(string: "https://company.org")!)
        XCTAssertFalse(result.icons.contains { $0.url.path.contains("bad") })
    }
    func testManifestRelativeToManifestNotPage() {
        let json = Data(#"{"icons":[{"src":"big.png","sizes":"512x512"},{"src":"https://127.0.0.1/x"},{"src":"mono.svg","purpose":"monochrome"}]}"#.utf8)
        XCTAssertEqual(IconDiscovery.manifestIcons(data: json, base: URL(string: "https://company.org/assets/app.json")!).map(\.url.absoluteString), ["https://company.org/assets/big.png"])
    }
    func testLargeWideBannerLosesToSquareLogo() { XCTAssertGreaterThan(PortraitPolicy.qualityScore(width: 180, height: 180, vector: false), PortraitPolicy.qualityScore(width: 1200, height: 300, vector: false)) }
    func testSVGNotAssumedLowResolution() { XCTAssertGreaterThan(PortraitPolicy.qualityScore(width: 16, height: 16, vector: true), PortraitPolicy.qualityScore(width: 180, height: 180, vector: false)) }
}

final class ImageAndNetworkTests: XCTestCase {
    func testRejectLocalAndCredentialsAndHTTP() {
        for value in ["http://company.org/icon", "https://localhost/x", "https://127.0.0.1/x", "https://[::1]/x", "https://device.local/x", "https://a.internal/x", "https://user:pass@company.org/x", "https://company.org:8443/x", "file:///tmp/icon"] { XCTAssertFalse(NetworkPolicy.isAllowedURL(URL(string: value)!), value) }
    }
    func testAllowPublicHTTPS() { XCTAssertTrue(NetworkPolicy.isAllowedURL(URL(string: "https://cdn.company.org/logo.png")!)) }
    func testPrivateAddressRanges() { for value: UInt32 in [0x7f000001, 0x0a000001, 0xac100001, 0xc0a80101, 0xa9fe0001, 0x64400001, 0xc6120001, 0xe0000001] { XCTAssertFalse(NetworkPolicy.isPublicIPv4(value)) }; XCTAssertTrue(NetworkPolicy.isPublicIPv4(0x08080808)) }
    func testFakeIPRequiresPinnedLoopbackProxy() {
        XCTAssertFalse(NetworkPolicy.isAcceptableResolvedIPv4(0xc612000a, pinnedLoopbackProxy: false))
        XCTAssertTrue(NetworkPolicy.isAcceptableResolvedIPv4(0xc612000a, pinnedLoopbackProxy: true))
        XCTAssertTrue(NetworkPolicy.isAcceptableResolvedIPv4(0xc613ffff, pinnedLoopbackProxy: true))
        for value: UInt32 in [0x7f000001, 0x0a000001, 0xc0a80101, 0xa9fe0001, 0xc6140001] {
            if value == 0xc6140001 { XCTAssertEqual(NetworkPolicy.isAcceptableResolvedIPv4(value, pinnedLoopbackProxy: true), NetworkPolicy.isPublicIPv4(value)) }
            else { XCTAssertFalse(NetworkPolicy.isAcceptableResolvedIPv4(value, pinnedLoopbackProxy: true)) }
        }
    }
    func testOnlyExplicitLocalHTTPSProxyEnablesFakeIPSupport() {
        XCTAssertNotNil(NetworkPolicy.loopbackProxyConfiguration(["HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 6152]))
        for settings: [String: Any] in [[:], ["HTTPSEnable": 0, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 6152], ["HTTPSEnable": 1, "HTTPSProxy": "proxy.company.org", "HTTPSPort": 6152], ["HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 0]] { XCTAssertNil(NetworkPolicy.loopbackProxyConfiguration(settings)) }
    }
    func testStandaloneSVGAllowed() { XCTAssertTrue(ImagePipeline.validateSVG(Data(#"<svg xmlns="http://www.w3.org/2000/svg"><path d="M0 0L1 1"/></svg>"#.utf8))) }
    func testSVGExternalResourcesAndScriptsRejected() {
        for text in [#"<svg><script>alert(1)</script></svg>"#, #"<svg><image href="https://company.org/pixel"/></svg>"#, #"<svg onload="x"/>"#, #"<!DOCTYPE svg><svg/>"#, #"<svg><style>.a {fill: url(https://company.org/x)}</style></svg>"#, #"<svg><use href="file:///x"/></svg>"#] { XCTAssertFalse(ImagePipeline.validateSVG(Data(text.utf8))) }
    }
    func testFakeImageRejected() { XCTAssertThrowsError(try ImagePipeline.decode(.init(data: Data("<html>not an image</html>".utf8), url: URL(string: "https://company.org/icon")!), source: .favicon)) }
    func testLargePayloadRejected() { XCTAssertThrowsError(try ImagePipeline.decode(.init(data: Data(repeating: 0, count: 4_000_001), url: URL(string: "https://company.org/icon")!), source: .favicon)) }
}

@MainActor final class MemoryJournal: JournalPort {
    var records: [ChangeRecord] = []
    var writes = 0
    var failAt: Int?
    func read() throws -> [ChangeRecord] { records }
    func write(_ records: [ChangeRecord]) throws { writes += 1; if writes == failAt { throw PortraitError.message("fixture disk error") }; self.records = records }
}

final class ChangeEngineTests: XCTestCase {
    @MainActor func testJournalLockPreventsOverlappingMutations() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = FileJournal(url: dir.appendingPathComponent("changes.json")), b = FileJournal(url: dir.appendingPathComponent("changes.json"))
        try a.lock(); XCTAssertThrowsError(try b.lock()); a.unlock()
        try b.lock(); b.unlock()
    }
    @MainActor func testJournalRoundTripAndPermissions() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = FileJournal(url: dir.appendingPathComponent("changes.json"))
        try journal.write([]); XCTAssertTrue(try journal.read().isEmpty)
        let permissions = try FileManager.default.attributesOfItem(atPath: journal.url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }
    @MainActor func fixture() throws -> (FixtureContactStore, MemoryJournal, ChangeEngine, EmailAddress, AvatarCandidate) {
        let store = try FixtureContactStore(), journal = MemoryJournal()
        let email = EmailAddress("person@company.org")!
        let candidate = AvatarCandidate(source: .manual, origin: "fixture", width: 180, height: 180, png: Data([1,2,3]))
        return (store, journal, ChangeEngine(store: store, journal: journal), email, candidate)
    }
    @MainActor func testExplicitCreationRequired() async throws { let (store, _, engine, email, candidate) = try fixture(); XCTAssertThrowsError(try engine.apply(email: email, name: "Name", candidate: candidate, allowCreate: false)); XCTAssertTrue(store.contacts.isEmpty) }
    @MainActor func testExistingPhotoPreserved() async throws {
        let (store, _, engine, email, candidate) = try fixture(); store.contacts["1"] = .init(id: "1", name: "Name", emails: [email.value], image: Data([9]))
        XCTAssertThrowsError(try engine.apply(email: email, name: "Name", candidate: candidate, allowCreate: true)); XCTAssertEqual(store.contacts["1"]?.image, Data([9]))
    }
    @MainActor func testAmbiguousContactsSkipped() async throws {
        let (store, _, engine, email, candidate) = try fixture()
        for id in ["1", "2"] { store.contacts[id] = .init(id: id, name: "Name", emails: [email.value], image: nil) }
        XCTAssertThrowsError(try engine.apply(email: email, name: "Name", candidate: candidate, allowCreate: true)); XCTAssertEqual(store.contacts.count, 2)
    }
    @MainActor func testExistingContactUndoPreservesNewName() async throws {
        let (store, _, engine, email, candidate) = try fixture(); store.contacts["1"] = .init(id: "1", name: "Before", emails: [email.value], image: nil)
        let record = try engine.apply(email: email, name: "Ignored", candidate: candidate, allowCreate: false)
        store.contacts["1"]?.name = "After"
        try engine.undo(id: record.id); XCTAssertNil(store.contacts["1"]?.image); XCTAssertEqual(store.contacts["1"]?.name, "After")
    }
    @MainActor func testCreatedContactDeletionGuard() async throws {
        let (store, _, engine, email, candidate) = try fixture(); let record = try engine.apply(email: email, name: "Name", candidate: candidate, allowCreate: true)
        store.externalRevision += 1
        XCTAssertThrowsError(try engine.undo(id: record.id)); XCTAssertEqual(store.contacts.count, 1)
    }
    @MainActor func testCreatedContactUndo() async throws {
        let (store, journal, engine, email, candidate) = try fixture(); let record = try engine.apply(email: email, name: "Name", candidate: candidate, allowCreate: true)
        try engine.undo(id: record.id); XCTAssertTrue(store.contacts.isEmpty); XCTAssertEqual(journal.records[0].state, .undone)
    }
    @MainActor func testLaterPhotoNotOverwritten() async throws {
        let (store, _, engine, email, candidate) = try fixture(); let record = try engine.apply(email: email, name: "Name", candidate: candidate, allowCreate: true)
        store.contacts[record.contactID!]?.image = Data([8])
        XCTAssertThrowsError(try engine.undo(id: record.id)); XCTAssertEqual(store.contacts[record.contactID!]?.image, Data([8]))
    }
    @MainActor func testNoMutationIfBackupFails() async throws {
        let (store, journal, engine, email, candidate) = try fixture(); journal.failAt = 1
        XCTAssertThrowsError(try engine.apply(email: email, name: "Name", candidate: candidate, allowCreate: true)); XCTAssertTrue(store.contacts.isEmpty)
    }
    @MainActor func testPreparedJournalSurvivesCommitRecordFailure() async throws {
        let (store, journal, engine, email, candidate) = try fixture(); journal.failAt = 2
        XCTAssertThrowsError(try engine.apply(email: email, name: "Name", candidate: candidate, allowCreate: true)); XCTAssertEqual(store.contacts.count, 1); XCTAssertEqual(journal.records[0].state, .prepared)
        XCTAssertThrowsError(try engine.apply(email: email, name: "Name", candidate: candidate, allowCreate: true)); XCTAssertEqual(store.contacts.count, 1)
    }
    @MainActor func testAlreadyDeletedContactUndoIsHarmless() async throws {
        let (store, journal, engine, email, candidate) = try fixture(); let record = try engine.apply(email: email, name: "Name", candidate: candidate, allowCreate: true)
        store.contacts.removeAll(); try engine.undo(id: record.id); XCTAssertEqual(journal.records[0].state, .undone)
    }
    @MainActor func testRepeatedApplyDoesNotCreateDuplicate() async throws {
        let (store, _, engine, email, candidate) = try fixture(); _ = try engine.apply(email: email, name: "Name", candidate: candidate, allowCreate: true)
        XCTAssertThrowsError(try engine.apply(email: email, name: "Name", candidate: candidate, allowCreate: true)); XCTAssertEqual(store.contacts.count, 1)
    }
    @MainActor func testCorruptJournalFailsClosed() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("broken".utf8).write(to: url)
        let store = try FixtureContactStore(), engine = ChangeEngine(store: store, journal: FileJournal(url: url))
        XCTAssertThrowsError(try engine.apply(email: EmailAddress("a@company.org")!, name: "A", candidate: AvatarCandidate(source: .manual, origin: "test", width: 180, height: 180, png: Data([1])), allowCreate: true)); XCTAssertTrue(store.contacts.isEmpty)
    }
}
