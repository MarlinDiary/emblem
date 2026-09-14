import XCTest
@testable import Emblem

final class DockActivationTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    func testBundleStartsAsAgentBeforeAnyAppKitRegistration() throws {
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: root.appendingPathComponent("Resources/Info.plist")),
            format: nil) as? [String: Any])
        XCTAssertEqual(plist["LSUIElement"] as? Bool, true,
                       "The same-bundle scanner and login agent must never start as Dock apps.")
        XCTAssertNotEqual(plist["LSBackgroundOnly"] as? Bool, true,
                          "The foreground interface must remain available.")
    }

    func testOnlyVisibleSessionPromotesAfterDiagnosticDispatch() throws {
        let app = try String(contentsOf: root.appendingPathComponent("Sources/Emblem/EmblemApp.swift"))
        let promotion = app.range(of: "NSApplication.shared.setActivationPolicy(.regular)")
        XCTAssertNotNil(promotion, "A user-opened window must have the normal Dock and app menu.")
        guard let promotion else { return }
        let diagnostics = try XCTUnwrap(app.range(of: "--live-icon-smoke"))
        let session = try XCTUnwrap(app.range(of: "_session = StateObject"))
        XCTAssertTrue(diagnostics.upperBound < promotion.lowerBound)
        XCTAssertTrue(promotion.upperBound < session.lowerBound)
    }

    func testHeadlessEntrypointsNeverPromoteToRegular() throws {
        let main = try String(contentsOf: root.appendingPathComponent("Sources/Emblem/EmblemMain.swift"))
        XCTAssertFalse(main.contains("setActivationPolicy(.regular)"))
        let foreground = try XCTUnwrap(main.range(of: "EmblemApp.main()"))
        for mode in ["--background-sync-agent", "--mail-scan-worker", "--gmail-status", "--background-service-status"] {
            XCTAssertTrue(try XCTUnwrap(main.range(of: mode)).lowerBound < foreground.lowerBound)
        }
    }
}
