import XCTest
@testable import PortraitCore

/// Photos are ~97% of the library file and are rewritten whenever any field changes.
/// Stored once by content, the saved JSON carries references instead of base64.
final class PhotoStoreTests: XCTestCase {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("photo-store-" + UUID().uuidString)
    }
    private func candidate(_ bytes: [UInt8]) -> AvatarCandidate {
        AvatarCandidate(source: .touchIcon, origin: "https://fixture.test/icon.png", width: 64, height: 64, png: Data(bytes))
    }

    func testIdenticalPhotosAreStoredOnce() throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = PhotoStore(directory: directory)
        let image = Data(repeating: 7, count: 40_000)
        let first = try store.store(image), second = try store.store(image)
        XCTAssertEqual(first, second)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
        XCTAssertEqual(store.load(first), image)
        XCTAssertNil(store.load("not-a-reference"))
    }

    func testEncodingKeepsPhotoBytesOutOfTheJSON() throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = PhotoStore(directory: directory)
        let photo = candidate(Array(repeating: 9, count: 60_000))
        let snapshot = ContactSnapshot(id: "contact", name: "Fixture", emails: ["person@fixture.test"], image: Data(repeating: 3, count: 50_000))
        let encoder = JSONEncoder(); encoder.userInfo[.photoStore] = store
        let data = try encoder.encode([photo]), contact = try encoder.encode(snapshot)
        XCTAssertLessThan(data.count, 2_000, "The candidate JSON no longer carries its photo")
        XCTAssertLessThan(contact.count, 1_000, "The contact JSON no longer carries its photo")
        let decoder = JSONDecoder(); decoder.userInfo[.photoStore] = store
        XCTAssertEqual(try decoder.decode([AvatarCandidate].self, from: data).first?.png, photo.png)
        XCTAssertEqual(try decoder.decode(ContactSnapshot.self, from: contact).image, snapshot.image)
    }

    func testLegacyInlineLibraryStillDecodes() throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = PhotoStore(directory: directory)
        let photo = candidate([1, 2, 3, 4])
        let legacy = try JSONEncoder().encode([photo])
        XCTAssertGreaterThan(legacy.count, 100)
        let decoder = JSONDecoder(); decoder.userInfo[.photoStore] = store
        XCTAssertEqual(try decoder.decode([AvatarCandidate].self, from: legacy).first?.png, photo.png)
    }

    func testAMissingPhotoDecodesEmptyInsteadOfFailingTheLibrary() throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = PhotoStore(directory: directory)
        let encoder = JSONEncoder(); encoder.userInfo[.photoStore] = store
        let data = try encoder.encode([candidate([5, 5, 5])])
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: file)
        }
        let decoder = JSONDecoder(); decoder.userInfo[.photoStore] = store
        let decoded = try decoder.decode([AvatarCandidate].self, from: data)
        XCTAssertTrue(decoded.first?.png.isEmpty == true, "One lost photo must not make the whole library unreadable")
    }

    func testCollectingGarbageKeepsReferencedPhotos() throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = PhotoStore(directory: directory)
        let kept = try store.store(Data(repeating: 1, count: 1_000))
        let alsoKept = try store.store(Data(repeating: 2, count: 1_000))
        let dropped = try store.store(Data(repeating: 3, count: 1_000))
        let removed = try store.collectGarbage(keeping: [kept, alsoKept], olderThan: 0)
        XCTAssertEqual(removed, 1)
        XCTAssertNotNil(store.load(kept)); XCTAssertNotNil(store.load(alsoKept)); XCTAssertNil(store.load(dropped))
    }

    func testRecentlyWrittenPhotosSurviveAConcurrentWritersCollection() throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = PhotoStore(directory: directory)
        let fresh = try store.store(Data(repeating: 4, count: 1_000))
        XCTAssertEqual(try store.collectGarbage(keeping: [], olderThan: 3_600), 0)
        XCTAssertNotNil(store.load(fresh))
    }
}
