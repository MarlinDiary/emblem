import Foundation

extension ChangeEngine {
    /// Correct an app-created relay card without touching its photo, aliases,
    /// labels or any unrelated fields. Name and email guards are rechecked.
    @discardableResult public func renameCreatedContact(contactID:String,expectedName:String,name:String,expectedEmails:[String])throws->ChangeRecord? {
        try journal.lock();defer{journal.unlock()}
        var records=try journal.read()
        guard records.contains(where:{$0.contactID==contactID && $0.created && $0.state == .applied}),
              !records.contains(where:{$0.contactID==contactID && $0.state == .prepared}),
              let current=try store.get(id:contactID),digestEmails(current.emails)==digestEmails(expectedEmails) else{throw PortraitError.message("The sender-name repair no longer matches its evidence. The current contact is preserved.")}
        if current.name==name{return nil}
        guard current.name==expectedName else{throw PortraitError.message("The name was changed elsewhere. The current contact is preserved.")}
        var record=ChangeRecord(email:current.emails.first ?? "",source:"shared-sender-name",created:false,contactID:contactID,beforeImage:current.image,afterHash:digest(current.image),historyToken:store.historyToken())
        record.beforeName=current.name;record.afterName=name;record.afterEmailsHash=digestEmails(current.emails);record.afterPixelHash=photoPixelHash(current.image)
        records.append(record);try journal.write(records)
        let after=try store.rename(id:contactID,expectedName:expectedName,name:name)
        guard after.name==name,after.emails==current.emails,photoMatches(after.image,encodedHash:record.afterHash,pixelHash:record.afterPixelHash) else{throw PortraitError.message("The repaired sender name did not match on read-back. The record is preserved.")}
        record.state = .applied;record.detail="Replaced a personalized notification address name with the service name"
        records[records.count-1]=record;try journal.write(records);return record
    }
}
