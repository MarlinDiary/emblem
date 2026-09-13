import Foundation

extension ChangeEngine {
    /// One-field, compare-and-swap update. The persisted intent precedes every write.
    /// Used only after the user enables sync or explicitly chooses a new photo.
    @discardableResult public func replaceSyncedImage(contactID:String, email:String, expectedHash:String, candidate:AvatarCandidate) throws -> ChangeRecord {
        try journal.lock();defer { journal.unlock() }
        var records=try journal.read()
        guard !records.contains(where: { $0.contactID == contactID && $0.state == .prepared }),
              let before=try store.get(id:contactID),digest(before.image)==expectedHash,
              before.emails.contains(where:{$0.caseInsensitiveCompare(email) == .orderedSame}) else {
            throw PortraitError.message("The contact just changed. Its current state is preserved until the next sync.")
        }
        var record=ChangeRecord(email:email,source:candidate.origin,created:false,contactID:contactID,beforeImage:before.image,afterHash:digest(candidate.png),historyToken:store.historyToken())
        record.afterPixelHash=photoPixelHash(candidate.png)
        record.affectedEmails=[email];records.append(record);try journal.write(records)
        let after=try store.setImage(id:contactID,image:candidate.png)
        guard after.image != nil else { throw PortraitError.message("The synced photo was empty on read-back. Review the contact.") }
        record.afterHash=digest(after.image);record.afterPixelHash=photoPixelHash(after.image);record.state = .applied;record.detail="Synced the photo automatically; other contact fields were preserved"
        records[records.count-1]=record;try journal.write(records);return record
    }
}
