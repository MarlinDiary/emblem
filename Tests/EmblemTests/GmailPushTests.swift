import XCTest
import PortraitCore
@testable import Emblem

private actor GmailPushTransportFixture: GmailHTTPTransport {
    var routes: [String: [(Int, String)]]
    var requests: [URLRequest] = []
    var delay: Duration

    init(_ routes: [String: [(Int, String)]], delay: Duration = .zero) { self.routes = routes; self.delay = delay }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if delay != .zero { try await Task.sleep(for: delay) }
        let key = request.url!.path
        guard var queue = routes[key], !queue.isEmpty else { throw NSError(domain: "UnexpectedFixtureRequest", code: 1) }
        let item = queue.removeFirst(); routes[key] = queue
        return (Data(item.1.utf8), HTTPURLResponse(url: request.url!, statusCode: item.0, httpVersion: nil, headerFields: nil)!)
    }
}

private final class PushSocketFixture: GmailPushSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [URLSessionWebSocketTask.Message]
    private var pending: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
    private var stopped = false
    private var reads = 0
    init(_ messages: [URLSessionWebSocketTask.Message] = []) { self.messages = messages }
    var cancelled: Bool { lock.withLock { stopped } }
    var readCount: Int { lock.withLock { reads } }
    func resume() {}
    func ping() async throws {}
    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                reads += 1
                if stopped { continuation.resume(throwing: CancellationError()) }
                else if !messages.isEmpty { continuation.resume(returning: messages.removeFirst()) }
                else { pending = continuation }
            }
        }
    }
    func cancel() {
        let continuation = lock.withLock { () -> CheckedContinuation<URLSessionWebSocketTask.Message, Error>? in
            stopped = true; let value = pending; pending = nil; return value
        }
        continuation?.resume(throwing: CancellationError())
    }
}
private actor PushEventFixture {
    var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

final class GmailPushTests: XCTestCase {
    private let root = "/gmail/v1/users/me/"

    func testWatchUsesInboxOnlyAndNeverLeaksTokenIntoURL() async throws {
        let transport = GmailPushTransportFixture([
            root + "watch": [(200, #"{"historyId":"901","expiration":"1789344000000"}"#)]
        ])
        let response = try await GmailAPI(transport: transport).watch(
            token: "fixture-token",
            topicName: "projects/fixture-project/topics/emblem-gmail-events"
        )
        XCTAssertEqual(response.historyId, "901")
        XCTAssertEqual(response.expiration, Date(timeIntervalSince1970: 1_789_344_000))
        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, root + "watch")
        XCTAssertFalse(request.url!.absoluteString.contains("fixture-token"))
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["topicName"] as? String, "projects/fixture-project/topics/emblem-gmail-events")
        XCTAssertEqual(json["labelIds"] as? [String], ["INBOX"])
        XCTAssertEqual(json["labelFilterBehavior"] as? String, "INCLUDE")
    }

    func testLegacyGmailJSONDecodesWithoutPushState() throws {
        let data = Data(#"{"accounts":[{"id":"fixture","email":"fixture@gmail.com","cursor":{}}]}"#.utf8)
        let decoded = try JSONDecoder().decode(GmailConnections.self, from: data)
        XCTAssertNil(decoded.accounts.first?.push)
    }

    func testPendingPushInboxCoalescesHistoryAndConsumesAtomically() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = GmailPushInbox(root: root)
        try inbox.append(.init(accountID: "account-a", historyID: "41", receivedAt: Date(timeIntervalSince1970: 10)))
        try inbox.append(.init(accountID: "account-a", historyID: "43", receivedAt: Date(timeIntervalSince1970: 11)))
        try inbox.append(.init(accountID: "account-b", historyID: "7", receivedAt: Date(timeIntervalSince1970: 12)))
        let events = try inbox.consume()
        XCTAssertEqual(events.map(\.accountID), ["account-a", "account-b"])
        XCTAssertEqual(events.first?.historyID, "43")
        XCTAssertTrue(try inbox.consume().isEmpty)
    }

    func testPushConfigurationRejectsHTTPAndMismatchedTopicProject() throws {
        XCTAssertNil(GmailPushConfiguration(endpoint: URL(string: "http://push.emblem.protoyard.com")!, topicName: "projects/p/topics/t", oauthClientID: "599856306731-x.apps.googleusercontent.com", projectNumber: "599856306731"))
        XCTAssertNil(GmailPushConfiguration(endpoint: URL(string: "https://push.emblem.protoyard.com")!, topicName: "projects/p/topics/t", oauthClientID: "599856306731-x.apps.googleusercontent.com", projectNumber: "111"))
        XCTAssertNotNil(GmailPushConfiguration(endpoint: URL(string: "https://push.emblem.protoyard.com")!, topicName: "projects/project-id/topics/emblem-gmail-events", oauthClientID: "599856306731-x.apps.googleusercontent.com", projectNumber: "599856306731"))
    }

    func testLaunchAgentKeepsListenerAliveAndUsesSlowFallback() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let plist = source.appendingPathComponent("Resources/LaunchAgents/com.protoyard.emblem.sync.plist")
        let value = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any])
        XCTAssertEqual(value["StartInterval"] as? Int, 60, "The launchd safety timer preserves regular sync before a mailbox enables push; the live listener uses its own 900-second fallback")
        let keepAlive = try XCTUnwrap(value["KeepAlive"] as? [String: Any])
        XCTAssertEqual(keepAlive["SuccessfulExit"] as? Bool, false)
    }
    func testWatchRejectsMalformedExpirationAndNonASCIIHistory() async throws {
        for wire in [#"{"historyId":"901","expiration":"NaN"}"#, #"{"historyId":"９０１","expiration":"1789344000000"}"#] {
            let transport = GmailPushTransportFixture([root + "watch": [(200, wire)]])
            do {
                _ = try await GmailAPI(transport: transport).watch(token: "fixture-token", topicName: "projects/fixture-project/topics/emblem-gmail-events")
                XCTFail("Malformed watch response was accepted")
            } catch {}
        }
    }

    func testSocketCancellationUnblocksAnIdleReceive() async throws {
        let socket = PushSocketFixture()
        let task = Task { try await GmailPushBackend.receiveEvents(socket: socket) { _ in } }
        for _ in 0..<100 where socket.readCount == 0 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(socket.readCount, 1)
        task.cancel()
        do { try await task.value; XCTFail("Cancelled socket unexpectedly completed") } catch is CancellationError {}
        XCTAssertTrue(socket.cancelled)
    }

    func testSocketAcceptsReconnectHintButRejectsOversizedFrames() async throws {
        let socket = PushSocketFixture([
            .string(#"{"type":"gmail-history","historyId":"９０１"}"#),
            .string(#"{"type":"gmail-history","historyId":"0"}"#),
            .string(String(repeating: "x", count: 4_097))
        ])
        let events = PushEventFixture()
        do { try await GmailPushBackend.receiveEvents(socket: socket) { await events.append($0) }; XCTFail("Oversized frame accepted") } catch {}
        let values = await events.values
        XCTAssertEqual(values, ["0"])
        XCTAssertTrue(socket.cancelled)
    }

    func testWatchAndRegistrationRenewAutomaticallyBeforeExpiry() {
        let now = Date()
        var state = healthyPush(now: now)
        XCTAssertFalse(state.watchNeedsRenewal(now: now))
        XCTAssertTrue(state.watchNeedsRenewal(now: now.addingTimeInterval(86_400)))
        state.watchExpiration = now.addingTimeInterval(3_600)
        XCTAssertTrue(state.watchNeedsRenewal(now: now))
        XCTAssertFalse(state.registrationNeedsRenewal(now: now))
        state.registrationExpiration = now.addingTimeInterval(86_400)
        XCTAssertTrue(state.registrationNeedsRenewal(now: now))
        let account = GmailAccount(id: "account", email: "fixture@gmail.com", push: healthyPush(now: now))
        XCTAssertEqual(BackgroundSyncAgent.fallbackInterval(mailEnabled: false, accounts: [account], now: now), 900)
        XCTAssertEqual(BackgroundSyncAgent.fallbackInterval(mailEnabled: true, accounts: [account], now: now), 60)
        XCTAssertEqual(BackgroundSyncAgent.fallbackInterval(mailEnabled: false, accounts: [GmailAccount(id: "regular", email: "fixture@gmail.com")], now: now), 60)
    }

    func testWriterProbeDetectsForegroundExitWithoutKeepingTheLease() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var foreground = try XCTUnwrap(LibraryLease.acquire(root: directory)) as LibraryLease?
        XCTAssertTrue(try LibraryLease.writerIsBusy(root: directory))
        withExtendedLifetime(foreground) {}
        foreground = nil
        XCTAssertFalse(try LibraryLease.writerIsBusy(root: directory))
        let next = try XCTUnwrap(LibraryLease.acquire(root: directory))
        withExtendedLifetime(next) {}
    }

    @MainActor func testPushForcesFreshAccountWithoutJumpingToNotificationHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = fixtureModel(root: directory)
        let now = Date()
        model.gmail.accounts = [GmailAccount(id: "account", email: "fixture@gmail.com", cursor: .init(historyID: "100", lastCheck: now), push: healthyPush(now: now))]
        let transport = GmailPushTransportFixture([root + "history": [(200, #"{"historyId":"101"}"#)]])
        model.gmailAPI = GmailAPI(transport: transport)
        model.kickGmailSync(now: now.addingTimeInterval(61))
        XCTAssertNil(model.gmailSyncTask, "Healthy push account should not poll every minute")
        model.noteGmailPush(accountID: "account", historyID: "999999", receivedAt: now.addingTimeInterval(-86_400))
        await model.gmailSyncTask?.value
        XCTAssertEqual(model.gmail.accounts[0].cursor.historyID, "101")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        let query = URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertTrue(query.contains(.init(name: "startHistoryId", value: "100")))
    }

    @MainActor func testPushDuringSyncCoalescesAndRespectsFailureBackoff() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = fixtureModel(root: directory), now = Date()
        model.gmail.accounts = [GmailAccount(id: "account", email: "fixture@gmail.com", cursor: .init(historyID: "100", lastCheck: now), push: healthyPush(now: now))]
        let transport = GmailPushTransportFixture([root + "history": [(200, #"{"historyId":"101"}"#), (429, "{}")]], delay: .milliseconds(20))
        model.gmailAPI = GmailAPI(transport: transport)
        model.noteGmailPush(accountID: "account", historyID: "101")
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<10 { model.noteGmailPush(accountID: "account", historyID: "102") }
        for _ in 0..<100 {
            if model.gmailSyncTask == nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertNotNil(model.gmail.accounts[0].cursor.retryAfter)
        model.noteGmailPush(accountID: "account", historyID: "103")
        XCTAssertNil(model.gmailSyncTask, "A push must not spin through API rate-limit backoff")
        XCTAssertEqual(model.gmailForcedAccountIDs, ["account"])
    }

    @MainActor func testLongHistoryCatchupContinuesImmediatelyWithoutAnExtraPage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = fixtureModel(root: directory), now = Date()
        model.gmail.accounts = [GmailAccount(id: "account", email: "fixture@gmail.com", cursor: .init(historyID: "100", lastCheck: now), push: healthyPush(now: now))]
        let pages = (1...3).map { (200, "{\"historyId\":\"104\",\"nextPageToken\":\"p\($0)\"}") } + [(200, #"{"historyId":"104"}"#)]
        let transport = GmailPushTransportFixture([root + "history": pages])
        model.gmailAPI = GmailAPI(transport: transport)
        model.noteGmailPush(accountID: "account", historyID: "104")
        for _ in 0..<100 {
            if model.gmailSyncTask == nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(model.gmail.accounts[0].cursor.historyID, "104")
        XCTAssertTrue(model.gmailForcedAccountIDs.isEmpty)
        XCTAssertNil(model.gmail.accounts[0].issue)
    }

    func testRegisteredWatchWithoutLiveSocketRetainsRegularFallback() {
        let now = Date()
        let state = GmailPushState(accountKey: String(repeating: "a", count: 64), deviceID: UUID().uuidString,
                                   registeredAt: now, registrationExpiration: now.addingTimeInterval(180 * 86_400),
                                   watchExpiration: now.addingTimeInterval(7 * 86_400), lastWatchRenewal: now)
        let account = GmailAccount(id: "account", email: "fixture@gmail.com", push: state)
        XCTAssertFalse(account.pushIsHealthy(at: now), "A saved watch does not prove a live delivery channel")
        XCTAssertEqual(BackgroundSyncAgent.fallbackInterval(mailEnabled: false, accounts: [account], now: now), 60)
    }

    func testPresenceHeartbeatExpiresAndOldDisconnectCannotEraseNewSocket() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let presence = GmailPushPresence(root: directory), now = Date()
        XCTAssertNil(try presence.lastAlive(accountID: "account", now: now))
        try presence.alive(accountID: "account", connectionID: "old", connectionStartedAt: now, now: now)
        XCTAssertEqual(try presence.lastAlive(accountID: "account", now: now), now)
        try presence.alive(accountID: "account", connectionID: "new", connectionStartedAt: now.addingTimeInterval(1), now: now.addingTimeInterval(1))
        try presence.alive(accountID: "account", connectionID: "old", connectionStartedAt: now, now: now.addingTimeInterval(2))
        try presence.disconnected(accountID: "account", connectionID: "old")
        XCTAssertNotNil(try presence.lastAlive(accountID: "account", now: now.addingTimeInterval(2)))
        XCTAssertNil(try presence.lastAlive(accountID: "account", now: now.addingTimeInterval(122)))
        try presence.disconnected(accountID: "account", connectionID: "new")
        XCTAssertNil(try presence.lastAlive(accountID: "account", now: now.addingTimeInterval(2)))
        let record = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("gmail-push-presence"), includingPropertiesForKeys: nil).first { $0.pathExtension == "json" })
        try Data("{".utf8).write(to: record, options: .atomic)
        try presence.alive(accountID: "account", connectionID: "new", connectionStartedAt: now.addingTimeInterval(1), now: now.addingTimeInterval(3))
        XCTAssertNotNil(try presence.lastAlive(accountID: "account", now: now.addingTimeInterval(4)), "An authenticated heartbeat repairs corrupt non-authoritative presence state")
        try presence.remove(accountID: "account")
        XCTAssertNil(try presence.lastAlive(accountID: "account", now: now))
    }

    func testLiveChannelKeepsExactGmailPrimaryAndOfflineChannelRestoresFallback() {
        let now = Date()
        var account = GmailAccount(id: "account", email: "fixture@gmail.com", cursor: .init(historyID: "100", lastCheck: now.addingTimeInterval(-900)), push: healthyPush(now: now))
        XCTAssertEqual(MailProviderRouting.primaryEmails([account], now: now), ["fixture@gmail.com"])
        account.push?.deliveryHeartbeat = nil
        XCTAssertTrue(MailProviderRouting.primaryEmails([account], now: now).isEmpty)
        XCTAssertTrue(account.pushRegistrationIsValid(at: now), "Keep trying the registered socket even while regular sync is the fallback")
    }

    func testValidFrameRecordsLivenessBeforeWakingHistorySync() async throws {
        let socket = PushSocketFixture([.string(#"{"type":"gmail-history","historyId":"0"}"#), .string(String(repeating: "x", count: 4_097))])
        let events = PushEventFixture()
        do {
            try await GmailPushBackend.receiveEvents(socket: socket, onAlive: { await events.append("alive") }) { await events.append($0) }
            XCTFail("Oversized frame was accepted")
        } catch {}
        let values = await events.values
        XCTAssertEqual(values, ["alive", "0"])
    }

    private func healthyPush(now: Date) -> GmailPushState {
        .init(accountKey: String(repeating: "a", count: 64), deviceID: UUID().uuidString, registeredAt: now,
              registrationExpiration: now.addingTimeInterval(180 * 86_400), watchExpiration: now.addingTimeInterval(7 * 86_400), lastWatchRenewal: now, deliveryHeartbeat: now)
    }
    @MainActor private func fixtureModel(root: URL) -> AppModel {
        let model = AppModel(demo: false, rootOverride: root)
        model.automation.setupComplete = true; model.automation.contacts = false; model.automation.mail = false
        model.useWebsite = false; model.useGravatar = false; model.mailSync.enabled = false
        model.gmailTokenProvider = { _ in "fixture-token" }
        return model
    }

}
