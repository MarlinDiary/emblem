import XCTest
import PortraitCore
@testable import Emblem
final class V013InterfaceRegressionTests:XCTestCase {
    func testNoRemovedNavigationOrPerSenderApplyOrDistractingLookupControls() throws {
        let source=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/Emblem")
        let main=try String(contentsOf:source.appendingPathComponent("EmblemApp.swift"))
        let sender=try String(contentsOf:source.appendingPathComponent("SenderViews.swift"))
        let status=try String(contentsOf:source.appendingPathComponent("AutomationViews.swift")).components(separatedBy:"struct AutomaticStatusView").last!
        XCTAssertFalse(main.contains("Label(\"待应用\""));XCTAssertFalse(main.contains("Label(\"需检查\""))
        for title in ["已有头像","已应用"] { XCTAssertFalse(main.contains("Label(\"\(title)\"")) }
        XCTAssertFalse(sender.contains("Button(\"应用头像\""));XCTAssertFalse(sender.contains("Image(systemName: \"plus\")"))
        XCTAssertFalse(status.contains("ProgressView"));XCTAssertFalse(status.contains("xmark"))
        XCTAssertTrue(main.contains("Apply All"))
    }
    @MainActor func testSelectingCandidateOnlyChangesPreviewAndKeepsBatchAvailable() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let m=AppModel(demo:true,rootOverride:root)
        let c=try NameAvatar.candidate(name:"SevenRooms")
        m.rows=[SenderRow(email:EmailAddress("hello@sevenrooms.com")!,name:"SevenRooms")];m.selectedID=m.rows[0].id
        m.addCandidate(c,to:m.rows[0].id)
        XCTAssertEqual(m.rows[0].chosen?.id,c.id);XCTAssertTrue(m.rows[0].selectionIsManual == true)
        XCTAssertTrue(try m.engine.records().isEmpty);XCTAssertTrue(m.showsBatchAction)
    }
}
