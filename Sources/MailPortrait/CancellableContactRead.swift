import Foundation
import PortraitCore

/// Only read-only Contacts IPC may outlive this await. Late results have no
/// reference to AppModel or a journal and are discarded; writes never race it.
enum CancellableContactRead {
    static func snapshots(ids:[String],timeout:TimeInterval=120,
                          reader:@escaping @Sendable ([String])throws->[String:ContactSnapshot] = {try AppleContacts.readSnapshots(ids:$0)})async throws->[String:ContactSnapshot] {
        guard !ids.isEmpty else{return [:]}
        let worker=Task.detached(priority:.utility) {try Task.checkCancellation();return try reader(ids)}
        defer {worker.cancel()}
        return try await withTaskCancellationHandler {
            try await withDeadline(seconds:timeout) {try await worker.value}
        } onCancel: {worker.cancel()}
    }
}
