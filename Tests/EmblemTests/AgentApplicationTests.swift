import XCTest
import AppKit
@testable import Emblem
final class AgentApplicationTests:XCTestCase {
    @MainActor func testBackgroundStartupNeverOpensAnUntitledForegroundWindow() {
        var opens=0
        let delegate=AgentApplication {done in opens+=1;done()}
        XCTAssertFalse(delegate.applicationOpenUntitledFile(NSApplication.shared));XCTAssertEqual(opens,0)
    }
    @MainActor func testUserReopenIsCoalescedUntilForegroundLaunchCompletes() {
        var opens=0;var completion:(()->Void)?
        let delegate=AgentApplication {done in opens+=1;completion=done}
        delegate.requestOpen();delegate.requestOpen();XCTAssertEqual(opens,1)
        completion?();delegate.requestOpen();XCTAssertEqual(opens,2)
    }
    @MainActor func testActualIsolatedAccessoryBootHasNoWindowsOrAutomaticReopen()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let executable=Bundle(for:AgentApplicationTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("Emblem")
        let task=Task.detached {
            let p=Process(),pipe=Pipe();p.executableURL=executable;p.arguments=["--agent-application-fixture","--data-dir",root.path];p.standardOutput=pipe;p.standardError=FileHandle.nullDevice
            try p.run();let data=pipe.fileHandleForReading.readDataToEndOfFile();p.waitUntilExit();return (p.terminationStatus,String(decoding:data,as:UTF8.self))
        }
        let result=try await task.value;XCTAssertEqual(result.0,0,result.1);XCTAssertTrue(result.1.contains("FOREGROUND_LAUNCHES=0"));XCTAssertTrue(result.1.contains("WINDOWS=0"))
    }
}
