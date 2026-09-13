import Foundation

public struct DeadlineExceeded: LocalizedError, Sendable {
    public let seconds: TimeInterval
    public var errorDescription: String? { "The request exceeded \(Int(seconds)) seconds. It will retry later." }
}

// Unstructured race: a cancelled, non-cooperative OS call must not keep the caller
// waiting as a structured task-group race would. Late results are discarded once.
final class DeadlineGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value,Error>?
    private var continuation: CheckedContinuation<Value,Error>?
    private var tasks: [Task<Void,Never>] = []
    private var timers: [DispatchWorkItem] = []
    func install(_ continuation: CheckedContinuation<Value,Error>) {
        lock.lock()
        let result = self.result
        if result == nil { self.continuation = continuation }
        lock.unlock()
        if let result { continuation.resume(with:result) }
    }
    func track(_ task: Task<Void,Never>) {
        lock.lock(); let finished = result != nil
        if !finished { tasks.append(task) }
        lock.unlock()
        if finished { task.cancel() }
    }
    func track(_ timer: DispatchWorkItem) {
        lock.lock(); let finished = result != nil
        if !finished { timers.append(timer) }
        lock.unlock()
        if finished { timer.cancel() }
    }
    func finish(_ value: Result<Value,Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value
        let continuation = self.continuation, tasks = self.tasks, timers = self.timers
        self.continuation = nil; self.tasks = []; self.timers = []
        lock.unlock()
        tasks.forEach { $0.cancel() }
        timers.forEach { $0.cancel() }
        continuation?.resume(with:value)
    }
}

public func withDeadline<Value: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
    let gate = DeadlineGate<Value>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            gate.install(continuation)
            gate.track(Task {
                do { try Task.checkCancellation(); gate.finish(.success(try await operation())) }
                catch { gate.finish(.failure(error)) }
            })
            // A non-cooperative OS call may occupy Swift's cooperative pool.
            // Use a GCD timer so the deadline itself cannot be starved behind
            // the work it exists to bound.
            let timer=DispatchWorkItem {gate.finish(.failure(DeadlineExceeded(seconds:seconds)))}
            gate.track(timer)
            DispatchQueue.global(qos:.userInitiated).asyncAfter(deadline:.now()+max(0,seconds),execute:timer)
        }
    } onCancel: { gate.finish(.failure(CancellationError())) }
}

// getaddrinfo itself is not cancellable. Bound OS work to four threads, and cancel
// queued work so a long outage cannot accumulate blocking DNS threads.
enum DNSPreflight {
    private static let queue: OperationQueue = {
        let queue = OperationQueue(); queue.name = "MailPortrait.DNS"; queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .utility; return queue
    }()
    static func validate(_ url: URL, pinned: Bool) async throws {
        try await withDeadline(seconds:5) {
            let gate = DeadlineGate<Bool>()
            let operation = BlockOperation {
                do { try NetworkPolicy.validate(url,pinnedLoopbackProxy:pinned); gate.finish(.success(true)) }
                catch { gate.finish(.failure(error)) }
            }
            _ = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    gate.install(continuation)
                    queue.addOperation(operation)
                }
            } onCancel: {
                operation.cancel(); gate.finish(.failure(CancellationError()))
            }
        }
    }
}
