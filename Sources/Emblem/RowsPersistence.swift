import Foundation
import PortraitCore

enum RowsPersistence {
    static func encode(_ rows:[SenderRow])throws->Data {
        let encoder=JSONEncoder();encoder.outputFormatting=[.withoutEscapingSlashes]
        // Keep the on-disk JSON array unchanged, but never build one enormous
        // Foundation encoder tree containing every base64 photo at once.
        // Reserve a bounded estimate to avoid repeated growing-buffer copies.
        let limit=128*1024*1024
        var estimate=2
        for row in rows where estimate<limit {
            let bytes=row.candidates.reduce(row.current?.image?.count ?? 0) {$0+$1.png.count}
            estimate += min(limit,bytes/3*4+4096)
        }
        var result=Data();result.reserveCapacity(min(estimate,limit));result.append(91)
        for row in rows {
            try autoreleasepool {
                let encoded=try encoder.encode(row)
                if result.count>1 {result.append(44)}
                result.append(encoded)
            }
        }
        result.append(93);return result
    }
    /// Compare the previous whole-array codec against the bounded codec with
    /// identical independently allocated image payloads. Only isolated output;
    /// no AppKit session, real library, Contacts, Gmail or Keychain.
    static func memoryFixture(arguments:[String])async->Int32 {
        guard let i=arguments.firstIndex(of:"--data-dir"),i+1<arguments.count else{return 64}
        let root=URL(fileURLWithPath:arguments[i+1]).standardizedFileURL.resolvingSymlinksInPath()
        let live=LibraryLease.liveRoot.standardizedFileURL.resolvingSymlinksInPath()
        guard root != live,!root.path.hasPrefix(live.path+"/") else{return 64}
        do {
            guard !FileManager.default.fileExists(atPath:root.appendingPathComponent("encoded-fixture.json").path) else{return 64}
            var rows:[SenderRow]=[];rows.reserveCapacity(1000)
            let copiedLibrary=arguments.contains("--copied-library")
            if copiedLibrary {
                let input=root.appendingPathComponent("input-fixture.json").resolvingSymlinksInPath()
                guard input.deletingLastPathComponent()==root else{return 64}
                rows=try JSONDecoder().decode([SenderRow].self,from:Data(contentsOf:input,options:.mappedIfSafe))
            } else {for index in 0..<1000 {
                var row=SenderRow(email:EmailAddress("image\(index)@fixture.test")!,name:"Encoding Fixture \(index)")
                let id=UUID(uuidString:String(format:"00000000-0000-0000-0000-%012x",index))!
                let candidate=AvatarCandidate(source:.touchIcon,origin:"https://fixture.test/icon.png",width:256,height:256,png:Data(repeating:255,count:64_000),id:id)
                row.candidates=[candidate];row.selectedCandidate=candidate.id;rows.append(row)
            }}
            let snapshot=rows
            let reference=arguments.contains("--reference-codec"),start=Date()
            let data=try await Task.detached(priority:.utility) {
                if reference {let e=JSONEncoder();e.outputFormatting=[.withoutEscapingSlashes];return try e.encode(snapshot)}
                return try encode(snapshot)
            }.value
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let output=root.appendingPathComponent("encoded-fixture.json")
            try data.write(to:output,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:output.path)
            print("ROW_MEMORY_FIXTURE MODE=\(reference ? "reference":"bounded") ROWS=\(snapshot.count) INPUT=\(copiedLibrary ? "private-isolated-copy":"1000x64000-independent-bytes") OUTPUT_BYTES=\(data.count) SECONDS=\(Date().timeIntervalSince(start)) APPKIT_APPLICATION=ABSENT CONTACT_WRITES=0 KEYCHAIN_READS=0")
            return 0
        } catch {print("ROW_MEMORY_FIXTURE_ERROR=\(error)");return 1}
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
