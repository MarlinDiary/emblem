import XCTest
import PortraitCore
@testable import Emblem

/// A measured library was 91 MB, of which 88 MB was base64 photo data rewritten on
/// every save. Photos now live beside the library, stored once per content.
final class LibraryPhotoStorageTests:XCTestCase {
    private func temporaryRoot()throws->URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("photo-library-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        return root
    }
    private func row(_ address:String,_ name:String,photo:AvatarCandidate,contactPhoto:Bool=false)->SenderRow {
        var row=SenderRow(email:EmailAddress(address)!,name:name)
        row.candidates=[photo];row.selectedCandidate=photo.id;row.selectionIsManual=false
        if contactPhoto {row.current=ContactSnapshot(id:"contact-"+name,name:name,emails:[address],image:photo.png)}
        return row
    }
    private func size(_ url:URL)->Int {(try? FileManager.default.attributesOfItem(atPath:url.path)[.size] as? Int) .flatMap{$0} ?? 0}
    private func photoCount(_ root:URL)->Int {
        (try? FileManager.default.contentsOfDirectory(atPath:root.appendingPathComponent("photos").path).count) ?? 0
    }

    @MainActor func testLegacyLibraryMigratesAndKeepsTheOldFileForRollback()async throws {
        let root=try temporaryRoot();defer{try? FileManager.default.removeItem(at:root)}
        let photo=try NameAvatar.candidate(name:"Fixture Person")
        let legacy=root.appendingPathComponent("senders.json")
        try RowsPersistence.encode([row("person@fixture.org","Fixture Person",photo:photo,contactPhoto:true)]).write(to:legacy)
        let legacyBytes=size(legacy)
        XCTAssertGreaterThan(legacyBytes,photo.png.count,"The legacy file carries the photo twice as base64")

        let model=AppModel(demo:true,rootOverride:root,backgroundWorkAllowed:false)
        XCTAssertEqual(model.rows.first?.chosen?.png,photo.png,"Inline photos still load")
        model.rows[0].status="Renamed"
        try await model.saveAsync()

        let current=root.appendingPathComponent("senders-v2.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath:current.path))
        XCTAssertLessThan(size(current),photo.png.count/2,"Photo bytes no longer live in the library file")
        XCTAssertEqual(photoCount(root),1,"One photo, stored once for both the candidate and the contact copy")
        XCTAssertEqual(size(legacy),legacyBytes,"The previous format is left untouched for rollback")

        let reopened=AppModel(demo:true,rootOverride:root,backgroundWorkAllowed:false)
        XCTAssertEqual(reopened.rows.first?.chosen?.png,photo.png)
        XCTAssertEqual(reopened.rows.first?.current?.image,photo.png)
        XCTAssertEqual(reopened.rows.first?.status,"Renamed")
    }

    @MainActor func testSharedArtworkIsStoredOnceAndMetadataSavesDoNotRewriteIt()async throws {
        let root=try temporaryRoot();defer{try? FileManager.default.removeItem(at:root)}
        let shared=try NameAvatar.candidate(name:"Shared Brand")
        let model=AppModel(demo:true,rootOverride:root,backgroundWorkAllowed:false)
        model.rows=(0..<5).map {row("sender\($0)@brand.example","Sender \($0)",photo:shared)}
        try await model.saveAsync()
        XCTAssertEqual(photoCount(root),1,"Five senders sharing one logo store it once")
        let photosWritten=try FileManager.default.contentsOfDirectory(at:root.appendingPathComponent("photos"),includingPropertiesForKeys:[.contentModificationDateKey])
        let stamp=try photosWritten.first?.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate
        model.rows[0].status="Bookkeeping only"
        try await model.saveAsync()
        let after=try photosWritten.first?.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate
        XCTAssertEqual(stamp,after,"A metadata save must not rewrite stored photos")
        XCTAssertLessThan(size(root.appendingPathComponent("senders-v2.json")),shared.png.count,"Metadata only")
    }

    @MainActor func testReplacedPhotosAreCollectedWhileCurrentOnesStay()async throws {
        let root=try temporaryRoot();defer{try? FileManager.default.removeItem(at:root)}
        let first=try NameAvatar.candidate(name:"First Choice"),second=try NameAvatar.candidate(name:"Second Choice",variant:1)
        let model=AppModel(demo:true,rootOverride:root,backgroundWorkAllowed:false)
        model.rows=[row("person@fixture.org","First Choice",photo:first)]
        try await model.saveAsync()
        XCTAssertEqual(photoCount(root),1)
        model.rows[0].candidates=[second];model.rows[0].selectedCandidate=second.id
        try await model.saveAsync()
        XCTAssertEqual(photoCount(root),2,"Both are still on disk until collection runs")
        model.collectPhotoGarbage(olderThan:0)
        XCTAssertEqual(photoCount(root),1,"The replaced photo is collected")
        let reopened=AppModel(demo:true,rootOverride:root,backgroundWorkAllowed:false)
        XCTAssertEqual(reopened.rows.first?.chosen?.png,second.png)
    }

    @MainActor func testALostPhotoDropsOneCandidateInsteadOfTheLibrary()async throws {
        let root=try temporaryRoot();defer{try? FileManager.default.removeItem(at:root)}
        let photo=try NameAvatar.candidate(name:"Fixture Person")
        let model=AppModel(demo:true,rootOverride:root,backgroundWorkAllowed:false)
        model.rows=[row("person@fixture.org","Fixture Person",photo:photo),row("other@fixture.org","Other",photo:photo)]
        model.rows[1].name="Other"
        try await model.saveAsync()
        for file in try FileManager.default.contentsOfDirectory(at:root.appendingPathComponent("photos"),includingPropertiesForKeys:nil) {
            try FileManager.default.removeItem(at:file)
        }
        let reopened=AppModel(demo:true,rootOverride:root,backgroundWorkAllowed:false)
        XCTAssertEqual(reopened.rows.count,2,"The library still opens")
        XCTAssertNil(reopened.rows.first?.chosen,"A candidate without its photo is dropped")
        XCTAssertNil(reopened.launchError)
    }
}
