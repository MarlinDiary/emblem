import Foundation
import ImageIO
import PortraitCore

struct ProtectedPhotoRecovery:Codable {
    let recordID:UUID
    let originalPNG:Data
    let appliedPNG:Data
}
@MainActor enum PhotoRecovery {
    /// Narrow corrective operation for a known photo-only write that mistook a
    /// thumbnail-only existing card for empty. Never creates/deletes a contact.
    static func restore(_ input:ProtectedPhotoRecovery,engine:ChangeEngine,store:any ContactStorePort)throws->Bool {
        guard let record=try engine.records().first(where:{$0.id==input.recordID}),record.state == .applied,!record.created,record.beforeImage == nil,
              digest(input.appliedPNG)==record.afterHash,let id=record.contactID,let current=try store.get(id:id),
              current.emails.contains(where:{$0.caseInsensitiveCompare(record.email) == .orderedSame}),
              let originalPixels=photoPixelHash(input.originalPNG),let appliedPixels=photoPixelHash(input.appliedPNG) else{throw PortraitError.message("Recovery evidence does not match. The current photo is preserved.")}
        if photoPixelHash(current.image)==originalPixels{return false}
        guard photoPixelHash(current.image)==appliedPixels else{throw PortraitError.message("The photo changed elsewhere. It is preserved.")}
        guard let source=CGImageSourceCreateWithData(input.originalPNG as CFData,nil),let image=CGImageSourceCreateImageAtIndex(source,0,nil) else{throw PortraitError.message("The original photo backup is invalid.")}
        let candidate=AvatarCandidate(source:.manual,origin:"recovery://pre-sync-existing-photo",width:image.width,height:image.height,png:input.originalPNG)
        _=try engine.replaceSyncedImage(contactID:id,email:record.email,expectedHash:digest(current.image),candidate:candidate)
        guard photoPixelHash(try store.get(id:id)?.image)==originalPixels else{throw PortraitError.message("The restored photo needs verification. Backups are retained.")}
        return true
    }
    static func run(arguments:[String])->Int32 {
        do {
            func path(_ flag:String)throws->URL {guard let i=arguments.firstIndex(of:flag),i+1<arguments.count else{throw PortraitError.message("Missing "+flag)};return URL(fileURLWithPath:arguments[i+1])}
            let root=try path("--data-dir"),input=try JSONDecoder().decode(ProtectedPhotoRecovery.self,from:Data(contentsOf:path("--restoration-file")))
            let store=AppleContacts();try store.requireFullAccess()
            let changed=try restore(input,engine:ChangeEngine(store:store,journal:FileJournal(url:root.appendingPathComponent("changes.json"))),store:store)
            let report:[String:Any] = ["restored":true,"exactPixels":true,"photoWrites":changed ? 1 : 0,"contactsCreated":0,"contactsDeleted":0,"emailsChanged":0]
            try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:try path("--restoration-file").appendingPathExtension("result.json"),options:.atomic)
            print("PROTECTED_PHOTO_RESTORED=PASS EXACT_PIXELS=PASS CONTACT_CREATED=0 CONTACT_DELETED=0 EMAILS_CHANGED=0 PHOTO_WRITES=\(changed ? 1 : 0)")
            return 0
        }catch{print(error.localizedDescription);return 1}
    }
}
