import Foundation
import PortraitCore

enum RowsPersistence {
    static func encode(_ rows:[SenderRow])throws->Data {
        let encoder=JSONEncoder();encoder.outputFormatting=[.withoutEscapingSlashes]
        return try encoder.encode(rows)
    }
    /// Exact synthetic workload for launchd resource-class acceptance. Never
    /// opens the real library, Contacts, Gmail or Keychain.
    static func fixture()async->Int32 {
        do {
            var row=SenderRow(email:EmailAddress("image@fixture.test")!,name:"Encoding Fixture")
            let candidate=AvatarCandidate(source:.touchIcon,origin:"https://fixture.test/icon.png",width:256,height:256,png:Data(repeating:255,count:64_000))
            row.candidates=[candidate];row.selectedCandidate=candidate.id
            let rows=Array(repeating:row,count:1000),start=Date()
            let data=try await Task.detached(priority:.utility) {try encode(rows)}.value
            print("ROW_ENCODING_FIXTURE_BYTES=\(data.count) SECONDS=\(Date().timeIntervalSince(start)) APPKIT_APPLICATION=ABSENT CONTACT_WRITES=0 KEYCHAIN_READS=0")
            return 0
        } catch {return 1}
    }
}

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
            else {data=try await Task.detached(priority:.utility) {try RowsPersistence.encode(snapshot)}.value}
            if let saved=lastSavedRowsRevision,saved>=revision {return}
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            try data.write(to:stateURL,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:stateURL.path)
            if rowsRevision==revision {try clearInboxReceiptOverlay()}
            lastSavedRowsRevision=revision
        } catch {errorText="The library was not saved: \(error.localizedDescription)";throw error}
    }
}
