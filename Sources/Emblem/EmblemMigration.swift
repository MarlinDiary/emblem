import Foundation
import ServiceManagement
import PortraitCore

/// One-release compatibility bridge for installations created under the previous name.
/// The current library is copied atomically, so an interrupted upgrade leaves the source intact.
enum EmblemMigration {
    // A product rename must not discard the user's existing Mail/Contacts grants.
    // The stable bundle identifier therefore remains the compatibility identity.
    static let currentBundleIdentifier = "org.mailportrait.app"
    static let legacyBundleIdentifier = "org.mailportrait.app"
    static let legacyApplicationSupportName = "MailPortrait"
    static let currentApplicationSupportName = "Emblem"
    static let legacyKeychainService = "org.mailportrait.gmail"
    static let legacyBackgroundPlistName = "org.mailportrait.sync.plist"

    static func applicationSupportParent() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    @discardableResult
    static func migrateLibraryIfNeeded(applicationSupport parent: URL = applicationSupportParent()) throws -> URL {
        let manager = FileManager.default
        let current = parent.appendingPathComponent(currentApplicationSupportName, isDirectory: true)
        let legacy = parent.appendingPathComponent(legacyApplicationSupportName, isDirectory: true)
        if manager.fileExists(atPath: current.path) { return current }
        guard manager.fileExists(atPath: legacy.path) else { return current }
        guard let lease = try LibraryLease.acquire(root: legacy) else {
            throw PortraitError.message("The previous library is finishing background work. Emblem will retry when it is free.")
        }
        defer { withExtendedLifetime(lease) {} }
        try manager.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = parent.appendingPathComponent(".Emblem-migration-" + UUID().uuidString, isDirectory: true)
        defer { try? manager.removeItem(at: staging) }
        try manager.copyItem(at: legacy, to: staging)
        for transient in ["library-writer.lock", LibraryLease.requestName] {
            try? manager.removeItem(at: staging.appendingPathComponent(transient))
        }
        let marker: [String: Any] = [
            "source": legacyApplicationSupportName,
            "completedAt": ISO8601DateFormatter().string(from: Date())
        ]
        let markerData = try JSONSerialization.data(withJSONObject: marker, options: [.sortedKeys])
        try markerData.write(to: staging.appendingPathComponent("name-migration.json"), options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)
        try manager.moveItem(at: staging, to: current)
        return current
    }

    static func migratePreferences() {
        let defaults = UserDefaults.standard
        guard currentBundleIdentifier != legacyBundleIdentifier,
              let legacy = defaults.persistentDomain(forName: legacyBundleIdentifier), !legacy.isEmpty else { return }
        let current = defaults.persistentDomain(forName: currentBundleIdentifier) ?? [:]
        for (key, value) in legacy where current[key] == nil {
            // Registration markers are tied to the old agent and must be rebuilt.
            guard key != "MailPortraitBackgroundServiceRegisteredBuild",
                  key != "MailPortraitBackgroundServiceRegisteredBundlePath" else { continue }
            defaults.set(value, forKey: key)
        }
    }

    @MainActor static func unregisterLegacyBackgroundService() async {
        let service = SMAppService.agent(plistName: legacyBackgroundPlistName)
        guard service.status == .enabled || service.status == .requiresApproval else { return }
        try? await service.unregister()
    }
}
