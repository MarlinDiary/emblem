import XCTest
import Darwin
@testable import Emblem

final class MailScanRunnerTests:XCTestCase {
    private func shellWorker(_ script:String,_ parameters:[String])->MailScanScriptRunner {
        MailScanScriptRunner(executable:URL(fileURLWithPath:"/bin/sh"),arguments:["-c",script,"sh"]+parameters)
    }

    /// Process.waitUntilExit() can keep waiting after its child exits when a reused
    /// Swift executor thread once launched another Process at the same address.
    /// Each leaked wait holds a cooperative thread until the helper stops working.
    func testExitedWorkersReturnPromptlyAcrossRepeatedScans()async throws {
        let response=String(decoding:try JSONEncoder().encode(MailScriptResponse(value:.text("ok"),error:nil,mainThread:true)),as:UTF8.self)
        let runner=shellWorker(#"cat >/dev/null; printf %s "$1""#,[response])
        for scan in 0..<150 {
            let started=ContinuousClock.now
            let value=try await runner.call("fixture",arguments:[.number(scan)])
            XCTAssertEqual(value.string,"ok")
            XCTAssertLessThan(started.duration(to:.now),.seconds(5),"Scan \(scan) waited after its worker exited")
        }
    }

    func testSourcesNeverWaitForChildExitWithWaitUntilExit()throws {
        let sources=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/Emblem")
        for file in try FileManager.default.contentsOfDirectory(at:sources,includingPropertiesForKeys:nil) where file.pathExtension=="swift" {
            let calls=try String(contentsOf:file,encoding:.utf8).split(separator:"\n").filter {
                !$0.trimmingCharacters(in:.whitespaces).hasPrefix("//") && $0.contains(".waitUntilExit()")
            }
            XCTAssertTrue(calls.isEmpty,"\(file.lastPathComponent) waits through Process.waitUntilExit()")
        }
    }

    func testCancellationKillsTheWorkerChild()async throws {
        let marker=FileManager.default.temporaryDirectory.appendingPathComponent("mail-scan-worker-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:marker)}
        let runner=shellWorker(#"echo $$ > "$1.tmp" && mv "$1.tmp" "$1"; cat >/dev/null; exec sleep 60"#,[marker.path])
        let scan=Task {try await runner.call("fixture",arguments:[])}
        var pid:pid_t=0
        for _ in 0..<500 where pid==0 {
            try await Task.sleep(for:.milliseconds(10))
            pid=pid_t((try? String(contentsOf:marker,encoding:.utf8))?.trimmingCharacters(in:.whitespacesAndNewlines) ?? "") ?? 0
        }
        XCTAssertGreaterThan(pid,0)
        scan.cancel()
        do {_=try await scan.value;XCTFail("Expected cancellation")}
        catch {XCTAssertTrue(error is CancellationError)}
        for _ in 0..<500 where kill(pid,0)==0 {try await Task.sleep(for:.milliseconds(10))}
        XCTAssertNotEqual(kill(pid,0),0,"The cancelled worker must not keep running")
    }
}
