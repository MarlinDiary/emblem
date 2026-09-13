import XCTest
@testable import Emblem

final class EmblemRebrandTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testCanonicalProductIdentityIsEmblem() throws {
        let package = try String(contentsOf: root.appendingPathComponent("Package.swift"))
        XCTAssertTrue(package.contains("name: \"Emblem\""))
        XCTAssertTrue(package.contains(".executable(name: \"Emblem\", targets: [\"Emblem\"])"))
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: root.appendingPathComponent("Resources/Info.plist")),
            format: nil
        ) as? [String: Any])
        XCTAssertEqual(info["CFBundleDisplayName"] as? String, "Emblem")
        XCTAssertEqual(info["CFBundleExecutable"] as? String, "Emblem")
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, "org.mailportrait.app", "preserve the existing macOS privacy grants across the product rename")
    }

    func testNewRuntimeNamesAndLegacyMigrationAreBothPresent() throws {
        let migration = try String(contentsOf: root.appendingPathComponent("Sources/Emblem/EmblemMigration.swift"))
        XCTAssertTrue(migration.contains("applicationSupportParent"))
        XCTAssertTrue(migration.contains("MailPortrait"), "the previous data directory must be migrated")
        XCTAssertTrue(migration.contains("org.mailportrait.gmail"), "the previous Keychain service must be migrated")
        XCTAssertTrue(migration.contains("org.mailportrait.sync"), "the previous background service must be removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Resources/LaunchAgents/com.protoyard.emblem.sync.plist").path))
    }

    func testBuildScriptProducesEmblemApp() throws {
        let script = try String(contentsOf: root.appendingPathComponent("Scripts/build-app.sh"))
        XCTAssertTrue(script.contains("--product Emblem"))
        XCTAssertTrue(script.contains("Emblem.app"))
        XCTAssertTrue(script.contains("Resources/Emblem.entitlements"))
    }

    func testForegroundUpgradeRequestsUndeterminedContactsAccessOnce() throws {
        let session = try String(contentsOf: root.appendingPathComponent("Sources/Emblem/AppSession.swift"))
        XCTAssertTrue(session.contains("CNContactStore.authorizationStatus(for: .contacts) == .notDetermined"))
        XCTAssertTrue(session.contains("model.connectContacts()"))
        let agent = try String(contentsOf: root.appendingPathComponent("Sources/Emblem/BackgroundSyncAgent.swift"))
        XCTAssertFalse(agent.contains("requestAccess(for:"), "background work must never display a permission prompt")
    }

    func testLegacyLibraryIsCopiedOnceAndPreserved() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: parent) }
        let old = parent.appendingPathComponent("MailPortrait", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("preserved".utf8).write(to: old.appendingPathComponent("sender-library.json"))
        let migrated = try EmblemMigration.migrateLibraryIfNeeded(applicationSupport: parent)
        XCTAssertEqual(migrated.lastPathComponent, "Emblem")
        XCTAssertEqual(try String(contentsOf: migrated.appendingPathComponent("sender-library.json")), "preserved")
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.appendingPathComponent("sender-library.json").path))
        try Data("current".utf8).write(to: migrated.appendingPathComponent("sender-library.json"), options: .atomic)
        XCTAssertEqual(try EmblemMigration.migrateLibraryIfNeeded(applicationSupport: parent), migrated)
        XCTAssertEqual(try String(contentsOf: migrated.appendingPathComponent("sender-library.json")), "current")
    }
}
