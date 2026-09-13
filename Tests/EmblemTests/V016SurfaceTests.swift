import XCTest
@testable import Emblem
final class V016SurfaceTests: XCTestCase {
    private var source: URL { URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/Emblem") }
    func testSettingsHaveDirectGmailAndConcisePrivacy() throws {
        let text=try String(contentsOf:source.appendingPathComponent("PreferencesView.swift"))
        XCTAssertTrue(text.contains("Connect Gmail"))
        XCTAssertTrue(text.contains("Gravatar and Libravatar"))
        XCTAssertFalse(text.contains("Emblem 0.14.2"))
    }
    func testPrimaryChromeIsEnglishAndSelectionRemainsNative() throws {
        let list=try String(contentsOf:source.appendingPathComponent("SenderViews.swift"))
        let table=try String(contentsOf:source.appendingPathComponent("VirtualizedSenderTable.swift"))
        XCTAssertFalse(list.contains("没有发件人"))
        XCTAssertFalse(list.contains("机构人物照片"))
        XCTAssertTrue(list.contains("VirtualizedSenderTable("))
        XCTAssertTrue(table.contains("table.style = .sourceList"))
        XCTAssertTrue(table.contains("table.selectionHighlightStyle = .regular"))
        XCTAssertFalse(list.contains("List(selection:"))
        XCTAssertFalse(list.contains(".listRowBackground("))
    }
    func testHeadlessWorkIsDispatchedBeforeSwiftUIStarts()throws {
        let entry=try String(contentsOf:source.appendingPathComponent("EmblemMain.swift"))
        XCTAssertTrue(entry.contains("@main enum EmblemMain"))
        let session=try String(contentsOf:source.appendingPathComponent("AppSession.swift"))
        XCTAssertTrue(session.contains("addingTimeInterval(180)"))
        XCTAssertFalse(session.contains("Reopen shortly"))
        XCTAssertTrue(entry.range(of:"--background-sync-agent")!.lowerBound < entry.range(of:"EmblemApp.main()")!.lowerBound)
        for file in ["BackgroundSyncAgent.swift","MailScanWorker.swift"] {
            XCTAssertFalse(try String(contentsOf:source.appendingPathComponent(file)).contains("NSApplication.shared"))
        }
    }

}
