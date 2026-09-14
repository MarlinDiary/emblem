import Foundation
import CryptoKit
import Darwin

/// Socket liveness is independent of the large library's writer lease. A new
/// connection may replace an old one; an old disconnect must not erase it.
struct GmailPushPresence: Sendable {
    let root: URL
    private struct Record: Codable { var connectionID: String; var connectionStartedAt: Date; var lastAlive: Date? }
    private var folder: URL { root.appendingPathComponent("gmail-push-presence", isDirectory: true) }
    private func url(accountID: String) -> URL {
        let name = SHA256.hash(data: Data(accountID.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(name + ".json")
    }
    private func locked<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(folder.appendingPathComponent("presence.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { flock(fd, LOCK_UN); close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return try body()
    }
    private func read(accountID: String) throws -> Record? {
        let file = url(accountID: accountID)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let bytes = try Data(contentsOf: file)
        guard bytes.count <= 1_024 else { return nil }
        return try JSONDecoder().decode(Record.self, from: bytes)
    }
    private func save(_ value: Record, accountID: String) throws {
        let file = url(accountID: accountID)
        try JSONEncoder().encode(value).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    func alive(accountID: String, connectionID: String, connectionStartedAt: Date, now: Date = Date()) throws {
        try locked {
            if let current = try? read(accountID: accountID), current.connectionID != connectionID,
               current.connectionStartedAt > connectionStartedAt { return }
            try save(Record(connectionID: connectionID, connectionStartedAt: connectionStartedAt, lastAlive: now), accountID: accountID)
        }
    }
    func disconnected(accountID: String, connectionID: String) throws {
        try locked {
            guard var current = try read(accountID: accountID), current.connectionID == connectionID else { return }
            current.lastAlive = nil
            try save(current, accountID: accountID)
        }
    }
    func lastAlive(accountID: String, now: Date = Date()) throws -> Date? {
        try locked {
            guard let alive = try read(accountID: accountID)?.lastAlive,
                  now.timeIntervalSince(alive) >= -60, now.timeIntervalSince(alive) <= 120 else { return nil }
            return alive
        }
    }
    func remove(accountID: String) throws {
        try locked {
            let file = url(accountID: accountID)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
    }
}
