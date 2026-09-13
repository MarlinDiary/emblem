import XCTest
import PortraitCore
@testable import MailPortrait

final class IntegrationRegressionTests: XCTestCase {
    func testHardenedRuntimeIncludesContactsAndMailEntitlements() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/MailPortrait.entitlements"))
        let values = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(values["com.apple.security.personal-information.addressbook"] as? Bool, true)
        XCTAssertEqual(values["com.apple.security.automation.apple-events"] as? Bool, true)
    }
    @MainActor func testImportAfterConnectionImmediatelyMatchesExistingPhotoWithoutWrites() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(demo: true, rootOverride: root)
        let store = try XCTUnwrap(model.port as? FixtureContactStore)
        let original = try store.create(name: "Existing sender", email: "sender@example.org", image: Data([1,2,3]))
        model.importAddresses("sender@example.org")
        XCTAssertEqual(model.rows.first?.current?.id, original.id)
        XCTAssertEqual(model.rows.first?.current?.image, original.image)
        XCTAssertEqual(store.contacts.count, 1)
        XCTAssertTrue(try model.engine.records().isEmpty)
    }
    @MainActor func testEmptyMailSelectionReportsConnectionWithoutChangingList() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(demo: true, rootOverride: root)
        model.importAddresses("saved@example.org")
        model.acceptMailSenders([])
        XCTAssertTrue(model.mailConnected)
        XCTAssertEqual(model.lastMailImportCount, 0)
        XCTAssertEqual(model.rows.count, 1)
        XCTAssertTrue(model.errorText?.contains("Select one or more messages") == true)
        XCTAssertTrue(try model.engine.records().isEmpty)
    }
    @MainActor func testMailImportDeduplicatesAndNeverWritesContacts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(demo: true, rootOverride: root)
        model.acceptMailSenders(["Sender <sender@example.org>", "Sender <sender@example.org>"])
        XCTAssertTrue(model.mailConnected)
        XCTAssertEqual(model.lastMailImportCount, 2)
        XCTAssertEqual(model.rows.count, 1)
        XCTAssertTrue(try model.engine.records().isEmpty)
        XCTAssertTrue(try model.port.matches(email: "sender@example.org").isEmpty)
    }
    @MainActor func testDuplicateContactMatchesAreNotGuessedAndNotesDoNotAccumulate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(demo: true, rootOverride: root)
        _ = try model.port.create(name: "A", email: "sender@example.org", image: Data([1]))
        _ = try model.port.create(name: "B", email: "sender@example.org", image: Data([2]))
        model.importAddresses("sender@example.org")
        try model.refreshContactMatches()
        XCTAssertNil(model.rows.first?.current)
        XCTAssertEqual(model.rows.first?.notes.count, 1)
        XCTAssertTrue(try model.engine.records().isEmpty)
    }

}
