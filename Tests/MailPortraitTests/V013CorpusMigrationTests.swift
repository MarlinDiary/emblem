import XCTest
import PortraitCore
@testable import MailPortrait
private actor V013CapturedWebsite:ResourceFetching {
    let root:URL
    let entries:[[String:Any]]
    init(root:URL)throws { self.root=root;entries=try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("originals.json"))) as! [[String:Any]] }
    func fetch(_ url:URL,limit:Int)async throws->WebResource {
        guard let e=entries.first(where:{$0["origin"] as? String == url.absoluteString}),let file=e["file"] as? String else { throw PortraitError.message("Captured HTTP 404") }
        return .init(data:try Data(contentsOf:root.appendingPathComponent(file)),url:url,contentType:e["type"] as? String ?? "application/octet-stream")
    }
}
final class V013CorpusMigrationTests:XCTestCase {
    @MainActor func testActualSavedSendersAutomaticallyReceiveFreshWebsiteChoices() async throws {
        guard let folder=ProcessInfo.processInfo.environment["MAILPORTRAIT_V013_ASSETS"] else { throw XCTSkip("real asset corpus opt-in") }
        let assets=URL(fileURLWithPath:folder),base=assets.deletingLastPathComponent()
        let rows=try JSONDecoder().decode([SenderRow].self,from:Data(contentsOf:base.appendingPathComponent("state-before/senders.json")))
        let selected=rows.filter { $0.email.domain == "google.com" || $0.email.domain == "bellroy.com" || $0.email.domain.hasSuffix("sevenrooms.com") }
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let resolver=AvatarResolver(client:try V013CapturedWebsite(root:assets))
        let m=AppModel(demo:false,rootOverride:root,resolverFactory:{ resolver })
        m.rows=selected;m.useWebsite=true;m.useGravatar=false;m.automation.setupComplete=true;m.automaticEnabled=true
        XCTAssertTrue(m.rows.allSatisfy { AutomaticLookupPolicy.due($0,website:true,gravatar:false,now:Date()) })
        try await m.automaticallyResolve(now:Date())
        for row in m.rows {
            let candidate=try XCTUnwrap(row.chosen,row.id)
            if row.email.domain.hasSuffix("sevenrooms.com") { XCTAssertEqual(candidate.source,.favicon);XCTAssertTrue(candidate.declared == true) }
            else if row.email.domain == "google.com" { XCTAssertEqual(candidate.source,.officialBrand) }
            else { XCTAssertEqual(candidate.source,.manifest);XCTAssertEqual(candidate.effectiveFraming,.brandSafe);XCTAssertEqual(candidate.layoutRevision,7) }
            XCTAssertFalse(AutomaticLookupPolicy.due(row,website:true,gravatar:false,now:Date()),"migration must not loop: \(row.id)")
        }
        XCTAssertEqual(m.rows.map(\.id),selected.map(\.id));XCTAssertTrue(try m.engine.records().isEmpty)
        try JSONEncoder().encode(m.rows).write(to:assets.appendingPathComponent("v013-targets-after.json"))
        print("REAL_ICON_MIGRATION ROWS=\(m.rows.count) SEVENROOMS=favicon GOOGLE=officialBrand BELLROY=brandSafe NETWORK_REQUESTS=0 CONTACT_WRITES=0")
    }
}
