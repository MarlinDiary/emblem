import Foundation
import PortraitCore

/// Contacts change-history enumeration is synchronous and may take a long time
/// when a saved token spans many system events. Keep that IPC off the main actor
/// and bound the await. A timeout is conservative: the caller performs a full
/// linked-card read and stores a fresh token instead of trusting stale history.
enum CancellableContactHistoryRead {
    static func unchanged(token:Data,timeout:TimeInterval=2,
                          reader:@escaping @Sendable (Data)throws->Bool = {try AppleContacts.readHistoryUnchanged(since:$0)})async throws->Bool {
        let worker=Task.detached(priority:.utility) {try Task.checkCancellation();return try reader(token)}
        defer {worker.cancel()}
        return try await withTaskCancellationHandler {
            try await withDeadline(seconds:timeout) {try await worker.value}
        } onCancel: {worker.cancel()}
    }
}
