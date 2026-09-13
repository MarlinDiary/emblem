import XCTest
@testable import PortraitCore

private actor UncooperativeOperation {
    var continuation: CheckedContinuation<Int,Never>?
    var release = false
    func run() async -> Int {
        if release { return 9 }
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish() { release = true; continuation?.resume(returning:9); continuation = nil }
}
final class DeadlineTests: XCTestCase {
    func testDeadlineReturnsEvenWhenOperationIgnoresCancellation() async throws {
        let operation = UncooperativeOperation(), clock = ContinuousClock(), started = ContinuousClock.now
        do { _ = try await withDeadline(seconds:0.03) { await operation.run() }; XCTFail("Expected timeout") }
        catch { XCTAssertTrue(error is DeadlineExceeded) }
        XCTAssertLessThan(started.duration(to:clock.now),.seconds(1))
        // Completion after timeout must neither resume twice nor reach the caller.
        await operation.finish()
    }
    func testCallerCancellationReturnsBeforeUnderlyingOperation() async throws {
        let operation = UncooperativeOperation()
        let task = Task { try await withDeadline(seconds:10) { await operation.run() } }
        try await Task.sleep(for:.milliseconds(10)); task.cancel()
        let started = ContinuousClock.now
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(started.duration(to:.now),.seconds(1))
        await operation.finish()
    }
    func testNormalResultAndErrorArePreserved() async throws {
        let value = try await withDeadline(seconds:1) { 42 }; XCTAssertEqual(value,42)
        do { _ = try await withDeadline(seconds:1) { throw HTTPResourceError(status:503) }; XCTFail() }
        catch { XCTAssertEqual((error as? HTTPResourceError)?.status,503) }
    }
    func testCancellationBeforeContinuationInstallation() async throws {
        let task = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await withDeadline(seconds:10) { 42 } }
        do { _ = try await task.value; XCTFail() }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
