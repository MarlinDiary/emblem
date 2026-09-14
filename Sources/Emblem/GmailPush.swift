import Foundation
import Security
import Darwin
import PortraitCore

struct GmailPushConfiguration: Equatable, Sendable {
    let endpoint: URL
    let topicName: String
    let oauthClientID: String
    let projectNumber: String

    init?(endpoint: URL, topicName: String, oauthClientID: String, projectNumber: String) {
        guard endpoint.scheme == "https", endpoint.host != nil,
              endpoint.user == nil, endpoint.password == nil,
              endpoint.query == nil, endpoint.fragment == nil, endpoint.port == nil || endpoint.port == 443,
              endpoint.path == "" || endpoint.path == "/",
              topicName.range(of: #"^projects/[a-z][a-z0-9-]{4,29}/topics/[A-Za-z][A-Za-z0-9._~-]{2,254}$"#, options: .regularExpression) != nil,
              projectNumber.range(of: #"^[0-9]{6,20}$"#, options: .regularExpression) != nil,
              oauthClientID.hasPrefix(projectNumber + "-"), oauthClientID.hasSuffix(".apps.googleusercontent.com") else { return nil }
        self.endpoint = endpoint
        self.topicName = topicName
        self.oauthClientID = oauthClientID
        self.projectNumber = projectNumber
    }

    static func current(bundle: Bundle = .main) -> Self? {
        guard let endpointText = bundle.object(forInfoDictionaryKey: "EmblemGmailPushEndpoint") as? String,
              let endpoint = URL(string: endpointText),
              let topic = bundle.object(forInfoDictionaryKey: "EmblemGmailPubSubTopic") as? String,
              let clientID = bundle.object(forInfoDictionaryKey: "EmblemGoogleClientID") as? String,
              let projectNumber = bundle.object(forInfoDictionaryKey: "EmblemGoogleProjectNumber") as? String else { return nil }
        return Self(endpoint: endpoint, topicName: topic, oauthClientID: clientID, projectNumber: projectNumber)
    }

    func url(path: String) -> URL { endpoint.appendingPathComponent(path) }
}

struct GmailPushState: Codable, Equatable, Sendable {
    var accountKey: String
    var deviceID: String
    var registeredAt: Date
    var registrationExpiration: Date
    var watchExpiration: Date?
    var lastWatchRenewal: Date?
    var lastPush: Date?
    var deliveryHeartbeat: Date? = nil

    func registrationNeedsRenewal(now: Date) -> Bool { registrationExpiration.timeIntervalSince(now) < 7 * 86_400 }
    func watchNeedsRenewal(now: Date) -> Bool {
        guard let expiration = watchExpiration, let last = lastWatchRenewal else { return true }
        return expiration.timeIntervalSince(now) < 48 * 3_600 || now.timeIntervalSince(last) >= 24 * 3_600
    }
}

extension GmailAccount {
    func pushRegistrationIsValid(at now: Date) -> Bool {
        guard let push, push.registrationExpiration > now,
              let watch = push.watchExpiration, watch > now else { return false }
        return true
    }
    func pushIsHealthy(at now: Date) -> Bool {
        guard pushIssue == nil, pushRegistrationIsValid(at: now), let heartbeat = push?.deliveryHeartbeat,
              now.timeIntervalSince(heartbeat) >= -60, now.timeIntervalSince(heartbeat) <= 120 else { return false }
        return true
    }
}

struct GmailPushEvent: Codable, Equatable, Sendable {
    var accountID: String
    var historyID: String
    var receivedAt: Date
}

/// A durable, cross-process handoff. The listener never needs the library writer
/// lease; it records a hint, then whichever process owns the library consumes it.
struct GmailPushInbox: Sendable {
    let root: URL
    private var url: URL { root.appendingPathComponent("gmail-push-inbox.json") }
    private var lockURL: URL { root.appendingPathComponent("gmail-push-inbox.lock") }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { flock(fd, LOCK_UN); close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return try body()
    }

    func append(_ event: GmailPushEvent) throws {
        try locked {
            var events = (try? JSONDecoder().decode([GmailPushEvent].self, from: Data(contentsOf: url))) ?? []
            if let index = events.firstIndex(where: { $0.accountID == event.accountID }) {
                let old = events[index]
                let useNewHistory = Self.numericHistory(event.historyID, exceeds: old.historyID)
                events[index] = GmailPushEvent(accountID: event.accountID,
                                               historyID: useNewHistory ? event.historyID : old.historyID,
                                               receivedAt: max(old.receivedAt, event.receivedAt))
            } else { events.append(event) }
            events.sort { $0.accountID < $1.accountID }
            try JSONEncoder().encode(events).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    func consume() throws -> [GmailPushEvent] {
        try locked {
            guard FileManager.default.fileExists(atPath: url.path) else { return [] }
            let events = try JSONDecoder().decode([GmailPushEvent].self, from: Data(contentsOf: url))
            try FileManager.default.removeItem(at: url)
            return events.sorted { $0.accountID < $1.accountID }
        }
    }

    private static func numericHistory(_ lhs: String, exceeds rhs: String) -> Bool {
        if lhs.count != rhs.count { return lhs.count > rhs.count }
        return lhs > rhs
    }
}

enum GmailPushSignal {
    static let notification = Notification.Name("com.protoyard.emblem.gmail-push")
    static func post() { DistributedNotificationCenter.default().post(name: notification, object: nil) }
}

enum GmailPushCredentials {
    private static func key(_ accountID: String) -> String { "push-channel:" + accountID }
    static func channelToken(accountID: String) throws -> String? {
        guard let data = try GmailKeychain.read(key(accountID)) else { return nil }
        guard let value = String(data: data, encoding: .utf8), valid(value) else {
            try? GmailKeychain.delete(key(accountID)); return nil
        }
        return value
    }
    static func createChannelToken(accountID: String) throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw PortraitError.message("A secure instant-update channel could not be created.")
        }
        let value = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        try GmailKeychain.save(Data(value.utf8), account: key(accountID))
        return value
    }
    static func delete(accountID: String) throws { try GmailKeychain.delete(key(accountID)) }
    static func valid(_ value: String) -> Bool {
        value.count >= 40 && value.count <= 128 && value.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
    }
}

struct GmailPushRegistration: Decodable, Sendable {
    var accountKey: String
    var expiresAt: Date
    private enum CodingKeys: String, CodingKey { case accountKey, expiresAt }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accountKey = try c.decode(String.self, forKey: .accountKey)
        let millis = try c.decode(Int64.self, forKey: .expiresAt)
        expiresAt = Date(timeIntervalSince1970: TimeInterval(millis) / 1_000)
    }
}

struct GmailPushWireEvent: Decodable, Sendable {
    var type: String
    var historyId: String
}

protocol GmailPushSocket: Sendable {
    func resume()
    func receive() async throws -> URLSessionWebSocketTask.Message
    func ping() async throws
    func cancel()
}

struct GmailPushSessionSocket: GmailPushSocket {
    var task: URLSessionWebSocketTask
    func resume() { task.resume() }
    func receive() async throws -> URLSessionWebSocketTask.Message { try await task.receive() }
    func ping() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
    func cancel() { task.cancel(with: .goingAway, reason: nil) }
}

/// Reject redirects rather than forwarding a registration identity/channel token.
final class GmailPushSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

final class GmailPushBackend: Sendable {
    let configuration: GmailPushConfiguration
    private let session: URLSession
    private let socketSession: URLSession

    init(configuration: GmailPushConfiguration) {
        self.configuration = configuration
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20; c.timeoutIntervalForResource = 25
        c.httpCookieStorage = nil; c.urlCredentialStorage = nil; c.urlCache = nil
        session = URLSession(configuration: c, delegate: GmailPushSessionDelegate(), delegateQueue: nil)
        let websocket = URLSessionConfiguration.ephemeral
        websocket.timeoutIntervalForRequest = 30; websocket.timeoutIntervalForResource = 7 * 86_400
        websocket.httpCookieStorage = nil; websocket.urlCredentialStorage = nil; websocket.urlCache = nil
        socketSession = URLSession(configuration: websocket, delegate: GmailPushSessionDelegate(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel(); socketSession.invalidateAndCancel() }

    func register(idToken: String, email: String, deviceID: String, channelToken: String) async throws -> GmailPushRegistration {
        guard let normalized = EmailAddress(email)?.value,
              GmailPushCredentials.valid(channelToken), Self.validDeviceID(deviceID) else { throw PortraitError.message("Instant update registration was invalid.") }
        var request = URLRequest(url: configuration.url(path: "v1/register"))
        request.httpMethod = "POST"; request.timeoutInterval = 20
        request.setValue("Bearer " + idToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["email": normalized, "deviceId": deviceID, "channelToken": channelToken])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, data.count <= 32_768 else { throw PortraitError.message("Instant update registration returned an unexpected response.") }
        guard http.statusCode == 200 else { throw GmailPushHTTPError(status: http.statusCode) }
        let registration = try JSONDecoder().decode(GmailPushRegistration.self, from: data)
        guard registration.accountKey.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
              registration.expiresAt > Date(), registration.expiresAt.timeIntervalSinceNow <= 181 * 86_400 else {
            throw PortraitError.message("Instant update registration returned an invalid expiration or account key.")
        }
        return registration
    }

    func unregister(state: GmailPushState, channelToken: String) async throws {
        var request = URLRequest(url: configuration.url(path: "v1/unregister"))
        request.httpMethod = "POST"; request.timeoutInterval = 20
        request.setValue("Bearer " + channelToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["accountKey": state.accountKey, "deviceId": state.deviceID])
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) || http.statusCode == 404 else {
            throw GmailPushHTTPError(status: (response as? HTTPURLResponse)?.statusCode ?? 500)
        }
    }

    func listen(state: GmailPushState, channelToken: String, onAlive: @escaping @Sendable () async -> Void, onEvent: @escaping @Sendable (String) async -> Void) async throws {
        var components = URLComponents(url: configuration.url(path: "v1/connect"), resolvingAgainstBaseURL: false)!
        components.scheme = "wss"
        components.queryItems = [URLQueryItem(name: "accountKey", value: state.accountKey), URLQueryItem(name: "deviceId", value: state.deviceID)]
        var request = URLRequest(url: components.url!); request.timeoutInterval = 30
        request.setValue("Bearer " + channelToken, forHTTPHeaderField: "Authorization")
        try await Self.receiveEvents(socket: GmailPushSessionSocket(task: socketSession.webSocketTask(with: request)), onAlive: onAlive, onEvent: onEvent)
    }

    static func receiveEvents(socket: any GmailPushSocket, onAlive: @escaping @Sendable () async -> Void = {}, onEvent: @escaping @Sendable (String) async -> Void) async throws {
        socket.resume()
        let heartbeat = Task {
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(45))
                    try await withDeadline(seconds: 15) { try await socket.ping() }
                    try Task.checkCancellation()
                    await onAlive()
                }
            } catch { if !Task.isCancelled { socket.cancel() } }
        }
        defer { heartbeat.cancel(); socket.cancel() }
        try await withTaskCancellationHandler {
            while !Task.isCancelled {
                let message = try await socket.receive()
                let data: Data
                switch message {
                case .string(let value): data = Data(value.utf8)
                case .data(let value): data = value
                @unknown default: throw PortraitError.message("Instant update channel returned an unsupported message.")
                }
                guard data.count <= 4_096 else { throw PortraitError.message("Instant update channel returned an oversized message.") }
                let event = try JSONDecoder().decode(GmailPushWireEvent.self, from: data)
                guard event.type == "gmail-history", Self.validHistory(event.historyId) else { continue }
                try Task.checkCancellation()
                await onAlive()
                await onEvent(event.historyId)
            }
            try Task.checkCancellation()
        } onCancel: { socket.cancel() }
    }

    static func validDeviceID(_ value: String) -> Bool {
        UUID(uuidString: value) != nil
    }
    static func validHistory(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 32 && value.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
    }
}

struct GmailPushHTTPError: LocalizedError, Sendable {
    var status: Int
    var errorDescription: String? {
        switch status {
        case 401, 403: return "Reconnect Gmail to enable instant updates."
        case 409: return "Instant updates are already changing. Try again shortly."
        case 429: return "Instant updates are busy. Emblem will retry."
        default: return "Instant updates did not finish (HTTP \(status))."
        }
    }
}

enum GmailPushListener {
    static func run(configuration: GmailPushConfiguration, state: GmailPushState, channelToken: String,
                    accountID: String, root: URL, onEvent: @escaping @Sendable (String) async -> Void) async {
        let presence = GmailPushPresence(root: root), connectionID = UUID().uuidString, connectionStartedAt = Date()
        var delay: Double = 1
        while !Task.isCancelled {
            do {
                try await GmailPushBackend(configuration: configuration).listen(state: state, channelToken: channelToken, onAlive: {
                    try? presence.alive(accountID: accountID, connectionID: connectionID, connectionStartedAt: connectionStartedAt)
                }, onEvent: onEvent)
                delay = 1
            } catch {
                try? presence.disconnected(accountID: accountID, connectionID: connectionID)
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .seconds(delay))
                delay = min(delay * 2, 60)
            }
        }
        try? presence.disconnected(accountID: accountID, connectionID: connectionID)
    }
}
