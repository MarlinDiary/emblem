import AppKit
import Contacts
import PortraitCore
import PortraitContactsBridge

@MainActor final class AppleContacts: ContactStorePort {
    lazy var store = CNContactStore()
    let keys: [CNKeyDescriptor] = [CNContactIdentifierKey, CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey, CNContactEmailAddressesKey, CNContactImageDataAvailableKey, CNContactImageDataKey, CNContactThumbnailImageDataKey] as [CNKeyDescriptor]
    func requestAccess() async throws {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .authorized { return }
        guard status == .notDetermined else {
            throw PortraitError.message("Allow full Contacts access for MailPortrait in System Settings → Privacy & Security → Contacts.")
        }
        do {
            // TCC defers a first privacy prompt for background applications.
            // Bring the already-visible native window forward before asking.
            NSApp.activate(ignoringOtherApps: true)
            await Task.yield()
            // Use the documented completion-handler entry point directly. The
            // SDK-generated async overlay has stalled before reaching TCC on
            // macOS 27 beta, leaving the UI in a permanent loading state.
            let result: Result<Bool, Error> = await withCheckedContinuation { (continuation: CheckedContinuation<Result<Bool, Error>, Never>) in
                store.requestAccess(for: .contacts) { granted, error in
                    if let error { continuation.resume(returning: .failure(error)) }
                    else { continuation.resume(returning: .success(granted)) }
                }
            }
            let granted = try result.get()
            guard granted else { throw PortraitError.message("Allow MailPortrait in System Settings → Privacy & Security → Contacts, then reconnect.") }
        } catch {
            throw PortraitError.message("Contacts access is not enabled. Check MailPortrait in System Settings → Privacy & Security → Contacts. System details: \(error.localizedDescription)")
        }
        try requireFullAccess()
    }
    func requireFullAccess() throws {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { throw PortraitError.message("Full Contacts access is not enabled. Photo previews remain available; no new contacts will be created.") }
    }
    func fetch(_ predicate: NSPredicate?) throws -> [CNContact] {
        try requireFullAccess()
        let request = CNContactFetchRequest(keysToFetch: keys); request.predicate = predicate; request.unifyResults = false
        var contacts: [CNContact] = []
        try store.enumerateContacts(with: request) { contact, _ in contacts.append(contact) }
        return contacts
    }
    static func availableImage(original:Data?,thumbnail:Data?)->Data? {original ?? thumbnail}
    func snapshot(_ contact: CNContact) -> ContactSnapshot {
        let name = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
        return .init(id: contact.identifier, name: name.isEmpty ? contact.organizationName : name, emails: contact.emailAddresses.map { EmailAddress($0.value as String)?.value ?? ($0.value as String) }, image: Self.availableImage(original:contact.imageData,thumbnail:contact.thumbnailImageData))
    }
    func matches(email: String) throws -> [ContactSnapshot] { try fetch(CNContact.predicateForContacts(matchingEmailAddress: email)).map(snapshot) }
    /// Bound native IPC to batches, not one synchronous request per linked row.
    func snapshots(ids:[String])throws->[String:ContactSnapshot] {
        let values=Array(Set(ids));var result:[String:ContactSnapshot]=[:]
        for start in stride(from:0,to:values.count,by:200) {
            let group=Array(values[start..<min(start+200,values.count)])
            for contact in try fetch(CNContact.predicateForContacts(withIdentifiers:group)) {let value=snapshot(contact);result[value.id]=value}
        }
        return result
    }
    nonisolated static func readSnapshots(ids:[String]) throws -> [String:ContactSnapshot] {
        guard !ids.isEmpty else{return [:]}
        guard CNContactStore.authorizationStatus(for:.contacts) == .authorized else {throw PortraitError.message("Full Contacts access is not enabled.")}
        let store=CNContactStore(),values=Array(Set(ids));var result:[String:ContactSnapshot]=[:]
        let keys=[CNContactIdentifierKey,CNContactGivenNameKey,CNContactFamilyNameKey,CNContactOrganizationNameKey,CNContactEmailAddressesKey,CNContactImageDataKey,CNContactThumbnailImageDataKey] as [CNKeyDescriptor]
        for start in stride(from:0,to:values.count,by:200) {
            try Task.checkCancellation()
            let request=CNContactFetchRequest(keysToFetch:keys);request.unifyResults=false
            request.predicate=CNContact.predicateForContacts(withIdentifiers:Array(values[start..<min(start+200,values.count)]))
            try store.enumerateContacts(with:request) {c,stop in
                if Task.isCancelled {stop.pointee=true;return}
                let personal=[c.givenName,c.familyName].filter{!$0.isEmpty}.joined(separator:" ")
                result[c.identifier]=ContactSnapshot(id:c.identifier,name:personal.isEmpty ? c.organizationName : personal,emails:c.emailAddresses.map{$0.value as String},image:c.imageData ?? c.thumbnailImageData)
            }
        }
        return result
    }
    func get(id: String) throws -> ContactSnapshot? { try fetch(CNContact.predicateForContacts(withIdentifiers: [id])).first.map(snapshot) }
    func raw(id: String) throws -> CNMutableContact {
        guard let contact = try fetch(CNContact.predicateForContacts(withIdentifiers: [id])).first?.mutableCopy() as? CNMutableContact else { throw PortraitError.message("The contact no longer exists.") }
        return contact
    }
    func execute(_ request: CNSaveRequest) throws { try requireFullAccess(); request.transactionAuthor = "org.mailportrait.app"; try store.execute(request) }
    func create(name: String, email: String, image: Data) throws -> ContactSnapshot {
        try create(name:name,emails:[email],image:image)
    }
    func create(name:String,emails:[String],image:Data) throws -> ContactSnapshot {
        let contact = CNMutableContact()
        contact.givenName = name.isEmpty ? emails.first ?? "Contacts" : name
        contact.emailAddresses = contactDistinctEmails(emails).sorted().map { CNLabeledValue(label:CNLabelOther,value:$0 as NSString) }
        contact.imageData = image
        let request = CNSaveRequest(); request.add(contact, toContainerWithIdentifier: store.defaultContainerIdentifier()); try execute(request)
        guard let result = try get(id: contact.identifier) else { throw PortraitError.message("The saved contact could not be read back.") }
        return result
    }
    func setImage(id: String, image: Data?) throws -> ContactSnapshot {
        guard let current=try get(id:id) else { throw PortraitError.message("The contact no longer exists.") }
        return try update(id:id,image:image,emails:current.emails)
    }
    func update(id:String,image:Data?,emails:[String]) throws -> ContactSnapshot {
        let contact = try raw(id: id)
        // Alias-only updates must not rewrite/re-encode an unchanged photo.
        if digest(Self.availableImage(original:contact.imageData,thumbnail:contact.thumbnailImageData)) != digest(image) {contact.imageData = image}
        // Preserve every existing label (work/home/etc.) and only use "other" for
        // aliases MailPortrait adds. Replacing the array indiscriminately would
        // silently discard user-authored Contacts metadata.
        var existing: [String: CNLabeledValue<NSString>] = [:]
        for value in contact.emailAddresses {
            let key = (value.value as String).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if existing[key] == nil { existing[key] = value }
        }
        contact.emailAddresses = contactDistinctEmails(emails).sorted().map { email in
            existing[email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
                ?? CNLabeledValue(label: CNLabelOther, value: email as NSString)
        }
        let request = CNSaveRequest(); request.update(contact); try execute(request)
        guard let result = try get(id: id) else { throw PortraitError.message("The saved photo could not be read back.") }
        return result
    }
    func rename(id:String,expectedName:String,name:String)throws->ContactSnapshot {
        let contact=try raw(id:id)
        guard contact.givenName==expectedName,contact.familyName.isEmpty,contact.organizationName.isEmpty else{throw PortraitError.message("The contact name changed elsewhere and is preserved.")}
        contact.givenName=name
        let request=CNSaveRequest();request.update(contact);try execute(request)
        guard let after=try get(id:id),after.name==name else{throw PortraitError.message("The saved name did not match when read back.")}
        return after
    }
    func delete(id: String) throws { let request = CNSaveRequest(); request.delete(try raw(id: id)); try execute(request) }
    func historyToken() -> Data? { store.currentHistoryToken }
    func historyUnchanged(since token: Data?) throws -> Bool {
        var error: NSError?
        let result = MPHistoryUnchanged(store, token, &error)
        if let error { throw error }
        return result
    }
    nonisolated static func readHistoryUnchanged(since token:Data)throws->Bool {
        try Task.checkCancellation()
        guard CNContactStore.authorizationStatus(for:.contacts) == .authorized else {throw PortraitError.message("Full Contacts access is not enabled.")}
        var error:NSError?
        let result=MPHistoryUnchanged(CNContactStore(),token,&error)
        if let error {throw error}
        try Task.checkCancellation()
        return result
    }
    func historyUnchanged(for contactID: String, since token: Data?) throws -> Bool {
        try requireFullAccess()
        var error: NSError?
        let result = MPContactHistoryInspection(store, token, contactID, &error)
        if let error { throw error }
        return result?["unchanged"] as? Bool == true
    }
    func defaultAccountName() throws -> String {
        let id = store.defaultContainerIdentifier()
        return try store.containers(matching: CNContainer.predicateForContainers(withIdentifiers: [id])).first?.name ?? "Default Contacts Account"
    }
}

enum MailImport {
    /// Static script: no user input is interpolated. Only sender fields of at most 200 selected messages.
    static let selectedSendersScript = """
    with timeout of 30 seconds
        tell application "Mail"
            set picked to selection
            set output to {}
            set total to count of picked
            if total > 200 then set total to 200
            repeat with n from 1 to total
                set end of output to sender of item n of picked
            end repeat
            return output
        end tell
    end timeout
    """
    static func selectedSenders() async throws -> [String] {
        try await Task.detached(priority: .userInitiated) {
            var error: NSDictionary?
            let script = NSAppleScript(source: selectedSendersScript)!
            let result = script.executeAndReturnError(&error)
            guard error == nil else { throw PortraitError.message("Mail import did not finish. Allow automation access and select messages in Mail before retrying (\(error?[NSAppleScript.errorNumber] ?? "unknown")）") }
            guard result.numberOfItems > 0 else { return [] }
            return (1...result.numberOfItems).compactMap { result.atIndex($0)?.stringValue }
        }.value
    }
}
