import XCTest
import PortraitCore
@testable import Emblem
final class V015SurfaceTests:XCTestCase {
    func testToolbarDoesNotContainFilterOrMislabelCurrentPhotoAsSource()throws {
        let source=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/Emblem")
        XCTAssertFalse(try String(contentsOf:source.appendingPathComponent("EmblemApp.swift")).contains("ToolbarItem(id:\"sender-filter\""))
        XCTAssertFalse(try String(contentsOf:source.appendingPathComponent("SenderViews.swift")).contains("return \"通讯录照片\""))
    }
    @MainActor func testAppliedWebsiteImageRetainsSourceInsteadOfDuplicateContactCandidate()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let m=AppModel(demo:true,rootOverride:root,backgroundWorkAllowed:false)
        let image=try NameAvatar.candidate(name:"LinkedIn").png
        let c=AvatarCandidate(source:.favicon,origin:"https://linkedin.com/favicon.png",width:1024,height:1024,png:image)
        var reencoded=image;reencoded.append(contentsOf:[0,0])
        XCTAssertEqual(photoPixelHash(image),photoPixelHash(reencoded))
        let row=SenderRow(email:EmailAddress("invitations@linkedin.com")!,name:"Elliott Wen via LinkedIn",candidates:[c],selectedCandidate:c.id,current:.init(id:"service",name:"LinkedIn",emails:["invitations@linkedin.com"],image:reencoded))
        m.rows=[row]
        let choices=m.avatarChoices(for:row,allSizes:false)
        XCTAssertFalse(choices.contains{$0.origin.hasPrefix("contacts://")})
        XCTAssertTrue(choices.contains{$0.id==c.id && $0.source == .favicon})
        XCTAssertTrue(try m.engine.records().isEmpty)
    }
    @MainActor func testExternalPhotoIsRetainedWithoutInventingWebsiteProvenance()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let m=AppModel(demo:true,rootOverride:root,backgroundWorkAllowed:false)
        let old=try NameAvatar.candidate(name:"LinkedIn"),personal=try NameAvatar.candidate(name:"Elliott Wen")
        let row=SenderRow(email:EmailAddress("elliott.wen@auckland.ac.nz")!,name:"Elliott Wen",candidates:[old],selectedCandidate:old.id,current:.init(id:"person",name:"Elliott Wen",emails:["elliott.wen@auckland.ac.nz"],image:personal.png))
        XCTAssertNil(m.currentAvatarSource(for:row))
        XCTAssertTrue(m.avatarChoices(for:row,allSizes:false).contains{$0.origin.hasPrefix("contacts://") && $0.png==personal.png})
        XCTAssertTrue(try m.engine.records().isEmpty)
    }
    @MainActor func testSameUrlWithNewArtworkDoesNotPretendItIsAlreadyApplied()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let m=AppModel(demo:true,rootOverride:root,backgroundWorkAllowed:false),email=EmailAddress("invitations@linkedin.com")!
        let old=AvatarCandidate(source:.favicon,origin:"https://linkedin.com/favicon.png",width:1024,height:1024,png:try NameAvatar.candidate(name:"LinkedIn").png)
        let newer=AvatarCandidate(source:.favicon,origin:old.origin,width:1024,height:1024,png:try NameAvatar.candidate(name:"New artwork").png)
        let record=try m.engine.apply(email:email,name:"LinkedIn",candidate:old,allowCreate:true)
        m.records=try m.engine.records()
        let row=SenderRow(email:email,name:"LinkedIn",candidates:[newer],selectedCandidate:newer.id,current:try m.port.get(id:record.contactID!))
        XCTAssertNil(m.currentAvatarSource(for:row))
        XCTAssertTrue(m.avatarChoices(for:row,allSizes:false).contains{$0.png==old.png})
    }
}
