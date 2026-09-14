import XCTest
import PortraitCore
@testable import Emblem

final class BackgroundModelCacheTests:XCTestCase {
    @MainActor func testDurablePassIsReusedButRealForegroundChangesInvalidateIt() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let cache=BackgroundModelCache();var loads=0
        func factory()->AppModel {loads+=1;return AppModel(demo:true,rootOverride:root)}
        let first=try cache.model(root:root,factory:factory)
        first.rows=[SenderRow(email:EmailAddress("sender@fixture.test")!,name:"First")];first.save();first.isShuttingDown=true
        try cache.remember(first)
        try Data("{}".utf8).write(to:root.appendingPathComponent("background-status.json"))
        try GmailPushInbox(root:root).append(.init(accountID:"fixture",historyID:"101",receivedAt:Date()))
        let second=try cache.model(root:root,factory:factory)
        XCTAssertTrue(first===second);XCTAssertFalse(second.isShuttingDown);XCTAssertEqual(loads,1)
        var edited=first.rows;edited[0].name="Foreground Edit"
        try JSONEncoder().encode(edited).write(to:first.stateURL,options:.atomic)
        let third=try cache.model(root:root,factory:factory)
        XCTAssertFalse(first===third);XCTAssertEqual(loads,2);XCTAssertEqual(third.rows[0].name,"Foreground Edit")
    }
    @MainActor func testDirtySnapshotsAndExplicitTakeoverAreNeverReused() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let cache=BackgroundModelCache();var loads=0
        func factory()->AppModel {loads+=1;return AppModel(demo:true,rootOverride:root)}
        let first=try cache.model(root:root,factory:factory);first.save();try cache.remember(first)
        cache.discard();let second=try cache.model(root:root,factory:factory);XCTAssertFalse(first===second)
        second.rows=[SenderRow(email:EmailAddress("sender@fixture.test")!,name:"Dirty")];try cache.remember(second)
        let third=try cache.model(root:root,factory:factory);XCTAssertFalse(second===third);XCTAssertEqual(loads,3)
    }
    func testAgentUsesCacheOnlyAfterAcquiringItsWriterLease() throws {
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source=try String(contentsOf:root.appendingPathComponent("Sources/Emblem/BackgroundSyncAgent.swift"))
        XCTAssertTrue(source.contains("modelCache.model(root:root)"))
        XCTAssertTrue(source.contains("modelCache.remember(model)"))
        XCTAssertTrue(source.contains("modelCache.discard()"))
    }
}
