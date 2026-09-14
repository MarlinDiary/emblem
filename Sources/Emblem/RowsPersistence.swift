import Foundation
import PortraitCore

extension AppModel {
    /// Await durability without making PNG/base64 serialization a main-thread
    /// operation. Newer durable user edits win; later unsaved edits stay dirty.
    /// Finish this flush even when its caller is shutting down/cancelled.
    func saveAsync() async throws {
        if let launchError {throw PortraitError.message(launchError)}
        guard lastSavedRowsRevision != rowsRevision else{return}
        let top=nextDiscoveryOrder+rows.count
        for i in rows.indices where rows[i].discoveryOrder == nil {rows[i].discoveryOrder=top-i}
        let snapshot=rows,revision=rowsRevision
        do {
            let data:Data
            if let encoder=rowsSnapshotEncoder {data=try await encoder(snapshot)}
            else {data=try await Task.detached(priority:.utility) {try JSONEncoder().encode(snapshot)}.value}
            if let saved=lastSavedRowsRevision,saved>=revision {return}
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            try data.write(to:stateURL,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:stateURL.path)
            if rowsRevision==revision {try clearInboxReceiptOverlay()}
            lastSavedRowsRevision=revision
        } catch {errorText="The library was not saved: \(error.localizedDescription)";throw error}
    }
}
