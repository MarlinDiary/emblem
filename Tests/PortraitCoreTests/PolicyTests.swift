import XCTest
@testable import PortraitCore
final class PolicyTests: XCTestCase {
    func testHighResolutionWins() { XCTAssertGreaterThan(PortraitPolicy.qualityScore(width: 180, height: 180, vector: false), PortraitPolicy.qualityScore(width: 16, height: 16, vector: false)) }
    func testOnlyUnchangedAppCreatedContactsCanBeDeleted() {
        XCTAssertTrue(PortraitPolicy.mayDelete(createdByApp: true, imageMatches: true, historyUnchanged: true))
        XCTAssertFalse(PortraitPolicy.mayDelete(createdByApp: false, imageMatches: true, historyUnchanged: true))
        XCTAssertFalse(PortraitPolicy.mayDelete(createdByApp: true, imageMatches: false, historyUnchanged: true))
        XCTAssertFalse(PortraitPolicy.mayDelete(createdByApp: true, imageMatches: true, historyUnchanged: false))
    }
}
