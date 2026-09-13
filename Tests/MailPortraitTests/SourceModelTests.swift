import XCTest
import AppKit
import PortraitCore
@testable import MailPortrait

struct AppSourceClient: ResourceFetching {
    let png:Data
    func fetch(_ url:URL,limit:Int) async throws -> WebResource {
        if url.path == "/apple-touch-icon.png" { return .init(data:png,url:url) }
        throw HTTPResourceError(status:404)
    }
}
final class SourceModelTests: XCTestCase {
    @MainActor func testWebsiteMappingPersistsPerSenderWithoutNetworkConsent() async throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        let m=AppModel(demo:false,rootOverride:dir);m.importAddresses("a@company.org\nb@company.org")
        m.setWebsite("github.com",for:m.rows[0].id)
        let reopened=AppModel(demo:false,rootOverride:dir)
        XCTAssertEqual(reopened.rows[0].website,"https://github.com");XCTAssertNil(reopened.rows[1].website)
        XCTAssertFalse(reopened.useWebsite);XCTAssertFalse(reopened.contactsConnected)
    }
    @MainActor func testSourceSettingsDoesNotStartNetworkOrContacts() async throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        let m=AppModel(demo:false,rootOverride:dir);m.configureSources()
        XCTAssertTrue(m.showSourceConsent);XCTAssertTrue(m.sourceSettingsOnly);XCTAssertFalse(m.busy);XCTAssertFalse(m.contactsConnected)
    }
    @MainActor func testLookupKeepsManualPhotoAndPersistsSourceReports() async throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        let image=try DemoImages.candidate(symbol:"star",color:.systemBlue)
        let m=AppModel(demo:false,rootOverride:dir,resolverFactory:{ AvatarResolver(client:AppSourceClient(png:image.png)) })
        m.importAddresses("a@company.org");let id=m.rows[0].id;m.addCandidate(image,to:id)
        m.useWebsite=true;m.lookup(ids:[id])
        for _ in 0..<300 where m.busy { try await Task.sleep(nanoseconds:10_000_000) }
        XCTAssertFalse(m.busy);XCTAssertNil(m.errorText)
        XCTAssertEqual(m.rows[0].candidates.filter { $0.source == .manual }.count,1)
        XCTAssertTrue(m.rows[0].sourceReports?.contains { $0.source == .touchIcon && $0.outcome == .found } ?? false)
        let reopened=AppModel(demo:false,rootOverride:dir)
        XCTAssertNotNil(reopened.rows[0].lastLookup);XCTAssertFalse(reopened.rows[0].sourceReports!.isEmpty)
        XCTAssertTrue(try m.engine.records().isEmpty);XCTAssertFalse(m.contactsConnected)
    }
    @MainActor func testVersion02RowDecodesWithoutNewFields() async throws {
        let row=SenderRow(email:EmailAddress("a@company.org")!,name:"A")
        let old=try JSONEncoder().encode(row)
        let decoded=try JSONDecoder().decode(SenderRow.self,from:old)
        XCTAssertNil(decoded.sourceReports);XCTAssertNil(decoded.website);XCTAssertNil(decoded.lastLookup)
    }
    @MainActor func testLegacyBrandCandidateIsReframedLocallyWithoutChangingSelectionID() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        let source=try DemoImages.candidate(symbol:"shippingbox",color:.systemIndigo)
        let legacy=AvatarCandidate(source:.favicon,origin:"https://company.org/favicon.png",width:512,height:512,png:source.png,framing:nil,layoutRevision:nil)
        var row=SenderRow(email:EmailAddress("brand@company.org")!,name:"Company")
        row.candidates=[legacy];row.selectedCandidate=legacy.id
        try JSONEncoder().encode([row]).write(to:dir.appendingPathComponent("senders.json"),options:.atomic)
        let before=digest(legacy.png)
        let migrated=AppModel(demo:false,rootOverride:dir)
        XCTAssertNil(migrated.launchError)
        XCTAssertEqual(migrated.rows[0].selectedCandidate,legacy.id)
        XCTAssertEqual(migrated.rows[0].candidates[0].id,legacy.id)
        XCTAssertEqual(migrated.rows[0].candidates[0].framing,.brandCanvas)
        XCTAssertNotEqual(digest(migrated.rows[0].candidates[0].png),before)
        let reopened=AppModel(demo:false,rootOverride:dir)
        XCTAssertEqual(reopened.rows[0].candidates[0].framing,.brandCanvas)
        XCTAssertEqual(reopened.rows[0].selectedCandidate,legacy.id)
    }
    @MainActor func testCorruptLegacyCandidateDoesNotBlockOpeningSavedRows() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        let broken=AvatarCandidate(source:.favicon,origin:"https://company.org/favicon.png",width:32,height:32,png:Data([0,1,2]),framing:nil)
        var row=SenderRow(email:EmailAddress("brand@company.org")!,name:"Company");row.candidates=[broken]
        try JSONEncoder().encode([row]).write(to:dir.appendingPathComponent("senders.json"),options:.atomic)
        let model=AppModel(demo:false,rootOverride:dir)
        XCTAssertNil(model.launchError);XCTAssertEqual(model.rows.count,1);XCTAssertTrue(model.rows[0].candidates.isEmpty)
    }
    func testGlassRequiresModernOSAndRespectsAccessibility() {
        XCTAssertTrue(NativeAppearance.usesGlass(majorVersion:27,reduceTransparency:false,increasedContrast:false))
        XCTAssertFalse(NativeAppearance.usesGlass(majorVersion:14,reduceTransparency:false,increasedContrast:false))
        XCTAssertFalse(NativeAppearance.usesGlass(majorVersion:27,reduceTransparency:true,increasedContrast:false))
        XCTAssertFalse(NativeAppearance.usesGlass(majorVersion:27,reduceTransparency:false,increasedContrast:true))
    }
}
