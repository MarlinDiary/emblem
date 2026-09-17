import XCTest
@testable import Emblem

final class HelperWatchdogTests:XCTestCase {
    private struct Run {var status:Int32;var seconds:TimeInterval;var output:String}
    private func fixture(_ mode:String,root:URL)throws->Run? {
        let executable=Bundle(for:HelperWatchdogTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("Emblem")
        let process=Process(),pipe=Pipe(),exited=DispatchSemaphore(value:0)
        process.executableURL=executable;process.arguments=["--helper-watchdog-fixture","--data-dir",root.path,"--mode",mode]
        process.standardOutput=pipe;process.standardError=FileHandle.nullDevice
        process.terminationHandler={_ in exited.signal()}
        let started=Date();try process.run()
        guard exited.wait(timeout:.now()+15) == .success else {kill(process.processIdentifier,SIGKILL);XCTFail("\(mode) fixture kept running");return nil}
        return Run(status:process.terminationStatus,seconds:Date().timeIntervalSince(started),output:String(decoding:pipe.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self))
    }
    private func temporaryRoot()->URL {FileManager.default.temporaryDirectory.appendingPathComponent("helper-watchdog-"+UUID().uuidString)}

    /// A helper whose cooperative pool or main thread stops must not keep the lease.
    func testStalledHelperExitsAndReleasesTheWriterLease()throws {
        for mode in ["pool","main"] {
            let root=temporaryRoot();defer{try? FileManager.default.removeItem(at:root)}
            guard let run=try fixture(mode,root:root) else{continue}
            XCTAssertEqual(run.status,HelperWatchdog.exitCode,mode)
            XCTAssertLessThan(run.seconds,10,mode)
            XCTAssertNotNil(try LibraryLease.acquire(root:root),"\(mode) stall kept the writer lease")
            let status=try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("background-status.json"))) as? [String:Any]
            XCTAssertEqual(status?["state"] as? String,"watchdog-restart",mode)
        }
    }

    func testIdleStallWaitsLongerAndHealthyHelperKeepsRunning()throws {
        let idle=temporaryRoot(),healthy=temporaryRoot()
        defer{try? FileManager.default.removeItem(at:idle);try? FileManager.default.removeItem(at:healthy)}
        if let run=try fixture("idle-pool",root:idle) {
            XCTAssertEqual(run.status,HelperWatchdog.exitCode)
            XCTAssertGreaterThanOrEqual(run.seconds,5,"An idle helper gets the longer grace period")
        }
        if let run=try fixture("healthy",root:healthy) {
            XCTAssertEqual(run.status,0,run.output)
            XCTAssertTrue(run.output.contains("WATCHDOG_HEALTHY=PASS"))
        }
    }

    func testLiveHelperStartsTheWatchdogAndMarksLeaseOwnership()throws {
        let source=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let agent=try String(contentsOf:source.appendingPathComponent("Sources/Emblem/BackgroundSyncAgent.swift"),encoding:.utf8)
        XCTAssertTrue(agent.contains("watchdog.start(timing:.live)"))
        XCTAssertTrue(agent.contains("watchdog.leaseHeld=true"))
        XCTAssertTrue(agent.contains("watchdog.leaseHeld=false"))
    }
}
