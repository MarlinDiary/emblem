import XCTest
import PortraitCore
@testable import Emblem

private actor ForegroundHistoryScanner:MailScannerPort {
    var sources:[ScanSource]=[]
    func inventory(source:ScanSource)async throws->MailScanInventory {sources.append(source);return .init(mailboxes:[],warnings:[])}
    func page(mailbox:MailScanMailbox,start:Int,size:Int)async throws->MailScanPage {.init(senders:[],currentCount:0)}
}
final class V015AgentTests:XCTestCase {
    func root()throws->URL {let r=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);addTeardownBlock{try? FileManager.default.removeItem(at:r)};return r}
    func testLeaseExcludesSecondWriterAndReleasesAfterOwnerEnds()throws {
        let r=try root();var first=try LibraryLease.acquire(root:r)
        XCTAssertNotNil(first);XCTAssertNil(try LibraryLease.acquire(root:r))
        first=nil;let next=try LibraryLease.acquire(root:r);XCTAssertNotNil(next)
        withExtendedLifetime(next) {}
    }
    func testForegroundRequestBelongsToLiveProcessAndIsCleared()throws {
        let r=try root();try LibraryLease.requestForeground(root:r)
        XCTAssertTrue(LibraryLease.foregroundRequested(root:r))
        LibraryLease.clearOwnRequest(root:r);XCTAssertFalse(LibraryLease.foregroundRequested(root:r))
        try Data("{\"pid\":2147483647}".utf8).write(to:r.appendingPathComponent(LibraryLease.requestName))
        XCTAssertFalse(LibraryLease.foregroundRequested(root:r))
    }
    func testLaunchAgentKeepsOnlyPushListenerAliveAndUsesBoundedFallback()throws {
        let source=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let plist=source.appendingPathComponent("Resources/LaunchAgents/com.protoyard.emblem.sync.plist")
        let v=try XCTUnwrap(PropertyListSerialization.propertyList(from:Data(contentsOf:plist),format:nil) as? [String:Any])
        XCTAssertEqual(v["BundleProgram"] as? String,"Contents/MacOS/Emblem")
        XCTAssertEqual(v["StartInterval"] as? Int,60)
        XCTAssertEqual((v["KeepAlive"] as? [String:Any])?["SuccessfulExit"] as? Bool,false)
        XCTAssertEqual(v["ProgramArguments"] as? [String],["Emblem","--background-sync-agent"])
    }
    @MainActor func testBackgroundRegistrationRefreshesWhenBuildOrBundlePathChanges() {
        XCTAssertTrue(BackgroundService.shouldRefreshRegistration(isEnabled:true,registeredBuild:nil,currentBuild:"29",registeredBundlePath:nil,currentBundlePath:"/Applications/Emblem.app"))
        XCTAssertTrue(BackgroundService.shouldRefreshRegistration(isEnabled:true,registeredBuild:"27",currentBuild:"29",registeredBundlePath:"/Applications/Emblem.app",currentBundlePath:"/Applications/Emblem.app"))
        XCTAssertTrue(BackgroundService.shouldRefreshRegistration(isEnabled:true,registeredBuild:"29",currentBuild:"29",registeredBundlePath:"/tmp/Emblem.app",currentBundlePath:"/Applications/Emblem.app"))
        XCTAssertFalse(BackgroundService.shouldRefreshRegistration(isEnabled:true,registeredBuild:"29",currentBuild:"29",registeredBundlePath:"/Applications/Emblem.app",currentBundlePath:"/Applications/Emblem.app",registeredPushSignature:"account-a",currentPushSignature:"account-a"))
        XCTAssertTrue(BackgroundService.shouldRefreshRegistration(isEnabled:true,registeredBuild:"29",currentBuild:"29",registeredBundlePath:"/Applications/Emblem.app",currentBundlePath:"/Applications/Emblem.app",registeredPushSignature:"",currentPushSignature:"account-a"))
        XCTAssertFalse(BackgroundService.shouldRefreshRegistration(isEnabled:false,registeredBuild:"27",currentBuild:"29",registeredBundlePath:"/tmp/Emblem.app",currentBundlePath:"/Applications/Emblem.app"))
    }
    @MainActor func testShutdownDoesNotStartFollowupContactWrites()throws {
        let m=AppModel(demo:false,rootOverride:try root(),backgroundWorkAllowed:true)
        m.mailSync.enabled=true;m.automation.setupComplete=true;m.isShuttingDown=true
        m.automaticTick();XCTAssertNil(m.syncTask);XCTAssertNil(m.discoveryTask);XCTAssertNil(m.automaticTask)
        XCTAssertFalse(m.automaticMayRun);XCTAssertTrue(try m.engine.records().isEmpty)
    }
    @MainActor func testAgentChecksInboxWithoutStartingDailyHistorySweep()async throws {
        let scanner=ForegroundHistoryScanner(),m=AppModel(demo:true,rootOverride:try root(),mailScanner:scanner,backgroundWorkAllowed:false)
        let now=Date();m.allowsHistoryScan=false;m.automation.contacts=false;m.automation.mail=true;m.mailSync.enabled=true
        m.automation.lastInbox=now;m.automation.lastFullMail=now.addingTimeInterval(-90000)
        try await m.automaticallyDiscover(now:now)
        let before=await scanner.sources;XCTAssertTrue(before.isEmpty)
        try await m.automaticallyDiscover(now:now.addingTimeInterval(90))
        let after=await scanner.sources;XCTAssertEqual(after,[.inbox])
        XCTAssertTrue(try m.engine.records().isEmpty)
    }
    @MainActor func testDisablingBackgroundInvokesServiceReconciliationAndPersists()throws {
        let m=AppModel(demo:true,rootOverride:try root(),backgroundWorkAllowed:false)
        var changes=0;m.backgroundPreferenceChanged={changes+=1}
        m.setBackground(true);m.setBackground(false);XCTAssertEqual(changes,2)
        let saved=try JSONDecoder().decode(MailSyncState.self,from:Data(contentsOf:m.syncURL));XCTAssertFalse(saved.background)
    }
}
