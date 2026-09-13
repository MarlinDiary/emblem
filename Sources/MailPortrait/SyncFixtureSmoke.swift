import Foundation
import PortraitCore

/// Release-binary smoke. All mutations go to a newly created, isolated fixture child.
@MainActor enum SyncFixtureSmoke {
    static func run(arguments:[String]) async ->Int32 {
        do {
            guard let i=arguments.firstIndex(of:"--data-dir"),i+1<arguments.count else{throw PortraitError.message("Missing fixture parent --data-dir")}
            let root=URL(fileURLWithPath:arguments[i+1]).appendingPathComponent("sync-fixture-"+UUID().uuidString)
            let m=AppModel(demo:true,rootOverride:root,backgroundWorkAllowed:false)
            m.automation.setupComplete=true;m.mailSync.enabled=true
            let c=try NameAvatar.candidate(name:"Claude Team")
            let email=EmailAddress("no-reply@email.claude.com")!
            m.rows=[SenderRow(email:email,name:"Claude Team",candidates:[c],selectedCandidate:c.id)]
            try await m.performMailSync();let contact=try m.port.matches(email:email.value).first
            guard let contact else{throw PortraitError.message("fixture creation failed")}
            let next=try NameAvatar.candidate(name:"Claude Team",variant:1);m.addCandidate(next,to:email.value);try await m.performMailSync()
            guard try m.port.get(id:contact.id)?.image == next.png else{throw PortraitError.message("fixture photo sync failed")}
            let external=try NameAvatar.candidate(name:"Claude Team",variant:2);_=try m.port.setImage(id:contact.id,image:external.png);try await m.performMailSync()
            guard m.rows[0].current?.image==external.png else{throw PortraitError.message("fixture inbound sync failed")}
            try m.port.delete(id:contact.id);try await m.performMailSync()
            guard m.rows[0].ignored,try m.port.matches(email:email.value).isEmpty else{throw PortraitError.message("fixture tombstone failed")}
            m.restoreIgnored([email.value]);try await m.performMailSync();try await m.ignoreSyncedSenders([email.value])
            guard try m.port.matches(email:email.value).isEmpty else{throw PortraitError.message("fixture ignore deletion failed")}
            print("SYNC_CREATE=PASS PHOTO_OUTBOUND=PASS PHOTO_INBOUND=PASS EXTERNAL_DELETE_TOMBSTONE=PASS IGNORE_DELETE=PASS")
            print("REAL_CONTACTS_READ=0 REAL_CONTACTS_WRITTEN=0 FIXTURE="+root.path)
            return 0
        } catch {print(error.localizedDescription);return 1}
    }
}
