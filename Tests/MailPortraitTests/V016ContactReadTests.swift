import XCTest
import PortraitCore
@testable import MailPortrait
final class V016ContactReadTests:XCTestCase {
    func testContactHistoryReadIsBoundedAndCancellable()async throws {
        let clock=ContinuousClock(),start=clock.now
        do {_=try await CancellableContactHistoryRead.unchanged(token:Data([1]),timeout:0.03,reader:{_ in Thread.sleep(forTimeInterval:0.3);return true});XCTFail("Expected timeout")}
        catch is DeadlineExceeded {} catch {XCTFail("Unexpected error: \(error)")}
        XCTAssertLessThan(start.duration(to:clock.now),.milliseconds(200))

        let cancelled=Task {try await CancellableContactHistoryRead.unchanged(token:Data([2]),reader:{_ in Thread.sleep(forTimeInterval:0.8);return true})}
        try await Task.sleep(for:.milliseconds(30));cancelled.cancel()
        do {_=try await cancelled.value;XCTFail("Cancellation should propagate")}
        catch is CancellationError {} catch {XCTFail("Unexpected error: \(error)")}
    }
    func testCancellationDoesNotWaitForNoncooperativeRead()async throws {
        let clock=ContinuousClock(),start=clock.now
        let task=Task {try await CancellableContactRead.snapshots(ids:["fixture"],reader:{_ in Thread.sleep(forTimeInterval:0.8);return [:]})}
        try await Task.sleep(for:.milliseconds(30));task.cancel()
        do {_=try await task.value;XCTFail("Cancellation should propagate")}
        catch is CancellationError {} catch {XCTFail("Unexpected error: \(error)")}
        XCTAssertLessThan(start.duration(to:clock.now),.milliseconds(400))
    }
    func testTimeoutAndEmptyInputNeverReturnPartialContacts()async throws {
        do {_=try await CancellableContactRead.snapshots(ids:["fixture"],timeout:0.03,reader:{_ in Thread.sleep(forTimeInterval:0.3);return [:]});XCTFail("Expected timeout")}
        catch is DeadlineExceeded {} catch {XCTFail("Unexpected error: \(error)")}
    }
    func testEmptyInputSkipsTheSystemStore()async throws {
        let result=try await CancellableContactRead.snapshots(ids:[],reader:{_ in XCTFail("Unexpected Contacts read");return [:]})
        XCTAssertTrue(result.isEmpty)
    }
}
