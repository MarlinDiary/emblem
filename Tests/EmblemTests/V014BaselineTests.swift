import XCTest
import PortraitCore
@testable import Emblem
final class V014BaselineTests:XCTestCase {
 @MainActor func testNewDiscoveryComesFirstAndRescanKeepsOrder() throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
  let m=AppModel(demo:true,rootOverride:root)
  m.rows=[SenderRow(email:EmailAddress("support@bellroy.com")!,name:"Bellroy")]
  var seen=Set<String>();m.ingestScanned(email:EmailAddress("no-reply@email.claude.com")!,name:"Claude Team",seen:&seen)
  XCTAssertEqual(m.rows.first?.id,"no-reply@email.claude.com")
  seen=[];m.ingestScanned(email:EmailAddress("support@bellroy.com")!,name:"Bellroy",seen:&seen)
  XCTAssertEqual(m.rows.first?.id,"no-reply@email.claude.com")
 }
 func testClaudeProductHasItsOwnOfficialMark() { XCTAssertNotNil(OfficialBrandAssets.asset(for:URL(string:"https://email.claude.com/")!)) }
 func testStreamlinedMainFlow() throws {
  let base=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/Emblem")
  let main=try String(contentsOf:base.appendingPathComponent("EmblemApp.swift")),detail=try String(contentsOf:base.appendingPathComponent("SenderViews.swift"))
  for text in ["Label(\"已有头像\"","Label(\"已应用\"","Label(\"修改记录\""] {XCTAssertFalse(main.contains(text))}
  XCTAssertFalse(detail.contains("Text(\"可选头像\")"));XCTAssertFalse(detail.contains("Text(\"选项\")"));XCTAssertFalse(detail.contains("指定官网"))
  XCTAssertTrue(detail.contains("PhotoUploadTile"));XCTAssertTrue(main.contains("refresh-avatar"))
 }
}
