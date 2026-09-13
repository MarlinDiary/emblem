import Foundation
import Darwin

@MainActor public protocol ContactStorePort: AnyObject {
    func matches(email: String) throws -> [ContactSnapshot]
    func get(id: String) throws -> ContactSnapshot?
    func create(name: String, email: String, image: Data) throws -> ContactSnapshot
    func setImage(id: String, image: Data?) throws -> ContactSnapshot
    func create(name:String,emails:[String],image:Data) throws -> ContactSnapshot
    func update(id:String,image:Data?,emails:[String]) throws -> ContactSnapshot
    func rename(id:String,expectedName:String,name:String) throws -> ContactSnapshot
    func delete(id: String) throws
    func historyToken() -> Data?
    func historyUnchanged(since token: Data?) throws -> Bool
    func historyUnchanged(for contactID: String, since token: Data?) throws -> Bool
}
public extension ContactStorePort {
    func rename(id:String,expectedName:String,name:String)throws->ContactSnapshot {throw PortraitError.message("This contact store does not support name updates.")}
    // Existing adapters remain conservative until they implement scoped history.
    func historyUnchanged(for contactID: String, since token: Data?) throws -> Bool {
        try historyUnchanged(since: token)
    }
    func create(name:String,emails:[String],image:Data) throws -> ContactSnapshot {
        guard let first=emails.first else { throw PortraitError.message("A contact needs at least one email address.") }
        let contact=try create(name:name,email:first,image:image)
        return try update(id:contact.id,image:image,emails:emails)
    }
    func update(id:String,image:Data?,emails:[String]) throws -> ContactSnapshot {
        let contact=try setImage(id:id,image:image)
        guard Set(contact.emails.map { $0.lowercased() }) == Set(emails.map { $0.lowercased() }) else { throw PortraitError.message("This contact store does not support merging email addresses.") }
        return contact
    }
}

@MainActor public protocol JournalPort: AnyObject {
    func read() throws -> [ChangeRecord]
    func write(_ records: [ChangeRecord]) throws
    func lock() throws
    func unlock()
}
public extension JournalPort { func lock() throws {} ; func unlock() {} }

@MainActor public final class FileJournal: JournalPort {
    public let url: URL
    private var lockFD: Int32 = -1
    public init(url: URL) { self.url = url }
    public func lock() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(url.appendingPathExtension("lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw PortraitError.message("The operation lock could not be created. Contacts were not changed.") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw PortraitError.message("Another MailPortrait operation is running. Try again shortly.") }
        lockFD = fd
    }
    public func unlock() { if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD); lockFD = -1 } }
    public func read() throws -> [ChangeRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([ChangeRecord].self, from: Data(contentsOf: url))
    }
    public func write(_ records: [ChangeRecord]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

@MainActor public final class ChangeEngine {
    let store: ContactStorePort
    let journal: JournalPort
    public init(store: ContactStorePort, journal: JournalPort) { self.store = store; self.journal = journal }
    public func records() throws -> [ChangeRecord] { try journal.read() }

    @discardableResult public func applyGroup(emails:[EmailAddress],name:String,candidate:AvatarCandidate,allowCreate:Bool,managedKey:String?,batchID:UUID? = nil) throws -> ChangeRecord {
        let values=contactDistinctEmails(emails.map(\.value)).sorted()
        guard !values.isEmpty else { throw PortraitError.message("There are no email addresses to apply.") }
        try journal.lock(); defer { journal.unlock() }
        var records=try journal.read()
        guard !records.contains(where:{ values.contains($0.email) && $0.state == .prepared }) else { throw PortraitError.message("This group has an unfinished write record. Review it first.") }
        var contacts:[String:ContactSnapshot]=[:]
        for email in values {
            let matches=try store.matches(email:email)
            guard matches.count <= 1 else { throw PortraitError.message("Addresses in this group match multiple contacts. Resolve them in Contacts first.") }
            if let match=matches.first { contacts[match.id]=match }
        }
        guard contacts.count <= 1 else { throw PortraitError.message("These addresses belong to different contacts and are not merged automatically.") }
        let before=contacts.values.first
        guard before != nil || allowCreate else { throw PortraitError.message("No contact exists. Allow creation of a new contact first.") }
        let combined=contactDistinctEmails((before?.emails ?? []) + values).sorted()
        let finalImage=before?.image ?? candidate.png
        var record=ChangeRecord(email:values[0],source:candidate.origin,created:before == nil,contactID:before?.id,beforeImage:before?.image,afterHash:digest(finalImage),historyToken:store.historyToken())
        record.afterPixelHash=photoPixelHash(finalImage)
        record.batchID=batchID;record.affectedEmails=values
        record.beforeEmails=before?.emails;record.afterEmailsHash=digestEmails(combined);record.managedKey=managedKey
        records.append(record);try journal.write(records)
        let after:ContactSnapshot
        do {
            if let before {
                guard let fresh=try store.get(id:before.id), digest(fresh.image) == digest(before.image), Set(fresh.emails.map { $0.lowercased() }) == Set(before.emails.map { $0.lowercased() }) else { throw PortraitError.message("The contact changed. Preview it again.") }
                after=try store.update(id:before.id,image:finalImage,emails:combined)
            } else {
                guard try values.allSatisfy({ try store.matches(email:$0).isEmpty }) else { throw PortraitError.message("A contact just appeared for an address in this group. Preview it again.") }
                after=try store.create(name:name,emails:combined,image:finalImage)
            }
        } catch { throw PortraitError.message("The write result needs review: \(error.localizedDescription) The operation intent is preserved in Changes.") }
        guard photoMatches(after.image,encodedHash:record.afterHash,pixelHash:record.afterPixelHash), digestEmails(after.emails) == record.afterEmailsHash else { throw PortraitError.message("The merged contact did not match on read-back. The record is preserved for review.") }
        record.contactID=after.id;record.state = .applied
        record.detail=before == nil ? "Created one contact with \(values.count) email addresses" : "Updated one contact with a photo and \(values.count) email addresses"
        records[records.count-1]=record;try journal.write(records)
        return record
    }

    @discardableResult public func appendManagedAliases(contactID:String,emails:[EmailAddress],managedKey:String) throws -> ChangeRecord? {
        try journal.lock();defer { journal.unlock() }
        var records=try journal.read()
        guard let before=try store.get(id:contactID) else { throw PortraitError.message("The managed contact no longer exists.") }
        let combined=contactDistinctEmails(before.emails + emails.map(\.value)).sorted()
        guard digestEmails(combined) != digestEmails(before.emails) else { return nil }
        guard !records.contains(where:{ $0.contactID == contactID && $0.state == .prepared }) else { throw PortraitError.message("The managed contact has an unfinished write record.") }
        var record=ChangeRecord(email:emails.first?.value ?? before.emails.first ?? "managed",source:"managed-alias",created:false,contactID:contactID,beforeImage:before.image,afterHash:digest(before.image),historyToken:store.historyToken())
        record.afterPixelHash=photoPixelHash(before.image)
        record.beforeEmails=before.emails;record.afterEmailsHash=digestEmails(combined);record.managedKey=managedKey
        records.append(record);try journal.write(records)
        let after=try store.update(id:contactID,image:before.image,emails:combined)
        guard photoMatches(after.image,encodedHash:record.afterHash,pixelHash:record.afterPixelHash),digestEmails(after.emails) == record.afterEmailsHash else { throw PortraitError.message("Managed email addresses did not match on read-back.") }
        record.state = .applied;record.detail="Automatically added \(combined.count-before.emails.count) new email addresses to the managed contact"
        records[records.count-1]=record;try journal.write(records)
        return record
    }

    @discardableResult public func apply(email: EmailAddress, name: String, candidate: AvatarCandidate, allowCreate: Bool, batchID: UUID? = nil) throws -> ChangeRecord {
        try journal.lock(); defer { journal.unlock() }
        var records = try journal.read()
        guard !records.contains(where: { $0.email == email.value && $0.state == .prepared }) else { throw PortraitError.message("This address has an unfinished write record. Review Changes before trying again.") }
        let matches = try store.matches(email: email.value)
        guard matches.count <= 1 else { throw PortraitError.message("This address matches multiple contacts or linked cards. Resolve them in Contacts first.") }
        let before = matches.first
        guard before?.image == nil else { throw PortraitError.message("The contact already has a photo, so the existing photo is preserved.") }
        guard before != nil || allowCreate else { throw PortraitError.message("No contact exists. Enable contact creation before applying.") }
        var record = ChangeRecord(email: email.value, source: candidate.origin, created: before == nil, contactID: before?.id, beforeImage: before?.image, afterHash: digest(candidate.png), historyToken: store.historyToken())
        record.afterPixelHash=photoPixelHash(candidate.png)
        record.batchID = batchID; record.affectedEmails = [email.value]
        records.append(record)
        try journal.write(records) // Write-ahead journal: never mutate without a durable intent/backup.
        let after: ContactSnapshot
        do {
            if let before {
                guard let fresh = try store.get(id: before.id), fresh.image == nil, fresh.emails.contains(email.value) else { throw PortraitError.message("The contact changed. Preview it again.") }
                after = try store.setImage(id: before.id, image: candidate.png)
            } else {
                guard try store.matches(email: email.value).isEmpty else { throw PortraitError.message("A contact just appeared for this address. Preview it again.") }
                after = try store.create(name: name, email: email.value, image: candidate.png)
            }
        } catch {
            // A system write can succeed before its read-back fails. Keep the prepared record;
            // treating the whole call as failed would make retries unsafe.
            throw PortraitError.message("The write result needs review: \(error.localizedDescription) The backup and operation intent are preserved in Changes.")
        }
        guard after.image != nil else { throw PortraitError.message("The contact photo was empty on read-back. The operation record is preserved for review.") }
        record.contactID = after.id; record.afterHash = digest(after.image); record.afterPixelHash=photoPixelHash(after.image); record.state = .applied; record.detail = before == nil ? "Created a contact and added its photo" : "Added a photo to an existing contact"
        records[records.count - 1] = record
        do { try journal.write(records) }
        catch { throw PortraitError.message("The photo was written, but its completion record could not be saved. Keep the data folder and review Contacts before trying again.") }
        return record
    }

    public func undo(id: UUID) throws {
        try journal.lock(); defer { journal.unlock() }
        var records = try journal.read()
        guard let index = records.firstIndex(where: { $0.id == id }), records[index].state == .applied, let contactID = records[index].contactID else { throw PortraitError.message("This record is unfinished or already undone.") }
        let record = records[index]
        if let current = try store.get(id: contactID) {
            guard photoMatches(current.image,encodedHash:record.afterHash,pixelHash:record.afterPixelHash) else { throw PortraitError.message("This contact’s photo changed after MailPortrait applied it. Your newer photo is preserved.") }
            if let expected=record.afterEmailsHash {
                guard digestEmails(current.emails) == expected else { throw PortraitError.message("This contact’s email addresses changed after MailPortrait applied them. The current contact is preserved.") }
            }
            if let beforeName=record.beforeName,let afterName=record.afterName {
                let restored=try store.rename(id:contactID,expectedName:afterName,name:beforeName)
                guard restored.name==beforeName,restored.emails==current.emails,photoMatches(restored.image,encodedHash:digest(current.image),pixelHash:photoPixelHash(current.image)) else{throw PortraitError.message("The restored name did not match on read-back.")}
            } else if record.created {
                let unchanged = try store.historyUnchanged(for: contactID, since: record.historyToken)
                guard PortraitPolicy.mayDelete(createdByApp: record.created, imageMatches: true, historyUnchanged: unchanged) else {
                    throw PortraitError.message("This contact has later edits or its change history expired. The contact is preserved for review in Contacts.")
                }
                try store.delete(id: contactID)
                guard try store.get(id: contactID) == nil else { throw PortraitError.message("The contact was still present on read-back. Review it in Contacts.") }
            } else {
                let restored:ContactSnapshot
                if let beforeEmails=record.beforeEmails { restored=try store.update(id:contactID,image:record.beforeImage,emails:beforeEmails) }
                else { restored=try store.setImage(id: contactID, image: record.beforeImage) }
                guard photoMatches(restored.image,encodedHash:digest(record.beforeImage),pixelHash:photoPixelHash(record.beforeImage)), record.beforeEmails == nil || digestEmails(restored.emails) == digestEmails(record.beforeEmails!) else { throw PortraitError.message("The restored contact did not match on read-back. Review it in Contacts.") }
            }
        }
        records[index].state = .undone
        records[index].detail = record.created ? "The created contact was removed or had already been deleted" : "Undid the photo change; other contact fields were preserved"
        try journal.write(records)
    }
}

/// Isolated store for demo mode and regression tests. No access to Apple Contacts.
@MainActor public final class FixtureContactStore: ContactStorePort {
    public var contacts: [String: ContactSnapshot] = [:]
    public var externalRevision = 0
    public let url: URL?
    private struct State: Codable { var contacts: [String: ContactSnapshot]; var externalRevision: Int }
    public init(url: URL? = nil) throws {
        self.url = url
        if let url, FileManager.default.fileExists(atPath: url.path) {
            let saved = try JSONDecoder().decode(State.self, from: Data(contentsOf: url)); contacts = saved.contacts; externalRevision = saved.externalRevision
        }
    }
    func persist() throws {
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(State(contacts: contacts, externalRevision: externalRevision)).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
    public func rename(id:String,expectedName:String,name:String)throws->ContactSnapshot {
        guard var contact=contacts[id],contact.name==expectedName else{throw PortraitError.message("The contact name changed. The current value is preserved.")}
        contact.name=name;contacts[id]=contact;try persist();return contact
    }
    public func matches(email: String) throws -> [ContactSnapshot] { contacts.values.filter { $0.emails.contains(email) } }
    public func get(id: String) throws -> ContactSnapshot? { contacts[id] }
    public func create(name: String, email: String, image: Data) throws -> ContactSnapshot {
        let contact = ContactSnapshot(id: UUID().uuidString, name: name, emails: [email], image: image); contacts[contact.id] = contact; try persist(); return contact
    }
    public func create(name:String,emails:[String],image:Data) throws -> ContactSnapshot {
        let contact=ContactSnapshot(id:UUID().uuidString,name:name,emails:Array(Set(emails)).sorted(),image:image);contacts[contact.id]=contact;try persist();return contact
    }
    public func update(id:String,image:Data?,emails:[String]) throws -> ContactSnapshot {
        guard var contact=contacts[id] else { throw PortraitError.message("The contact no longer exists") }
        contact.image=image;contact.emails=Array(Set(emails)).sorted();contacts[id]=contact;try persist();return contact
    }
    public func setImage(id: String, image: Data?) throws -> ContactSnapshot {
        guard var contact = contacts[id] else { throw PortraitError.message("The contact no longer exists") }
        contact.image = image; contacts[id] = contact; try persist(); return contact
    }
    public func delete(id: String) throws { contacts.removeValue(forKey: id); try persist() }
    public func historyToken() -> Data? { Data(String(externalRevision).utf8) }
    public func historyUnchanged(since token: Data?) throws -> Bool { token != nil && token == historyToken() }
}
