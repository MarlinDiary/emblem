import Foundation
import Contacts
import PortraitCore

struct MailSyncLink:Codable {
    var key:String
    var contactID:String
    var emails:Set<String>
    var createdByApp:Bool
    var imageHash:String
    var desiredHash:String
    var imagePixelHash:String?
    var externalEmails:Bool?
    var externalPhoto = false
}
struct MailSyncState:Codable {
    var enabled=false
    var background=false
    var enrolled=Set<String>()
    var excludedAtEnable=Set<String>()
    var suppressedKeys=Set<String>()
    var links:[MailSyncLink]=[]
    var explicitChoices:[String:String]=[:]
    // Opaque Contacts change-history cursor. Missing in older libraries and
    // therefore optional for backward-compatible decoding.
    var contactsHistoryToken:Data?
    /// Versioned one-time enrichment for pre-pixel-hash journal records. New
    /// records already carry pixel evidence; an unresolvable legacy record
    /// remains protected by its exact encoded hash without rescanning forever.
    var fingerprintMigrationRevision:Int?
}

enum MailSyncIdentity {
    static func key(_ row:SenderRow)->String {
        // Academic mailboxes and shared providers never merge by brand/name.
        if InstitutionalProfilePolicy.keepsMailboxIndependent(row.email) || row.email.isSharedProvider { return "email|"+row.id }
        return ManagedIdentityScope.key(row).map { "brand|"+$0 } ?? "email|"+row.id
    }
}

extension AppModel {
    var syncURL:URL {root.appendingPathComponent("mail-sync.json")}
    var changeJournalURL:URL {root.appendingPathComponent("changes.json")}
    func currentChangeJournalRevision()throws->String? {
        guard FileManager.default.fileExists(atPath:changeJournalURL.path) else{return nil}
        let a=try FileManager.default.attributesOfItem(atPath:changeJournalURL.path)
        return "\((a[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0):\((a[.size] as? NSNumber)?.uint64Value ?? 0):\((a[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0)"
    }
    func reloadRecordsFromJournal()throws {records=try engine.records();recordsFileRevision=try currentChangeJournalRevision()}
    func refreshRecordsIfJournalChanged()throws {
        if try currentChangeJournalRevision() != recordsFileRevision {try reloadRecordsFromJournal()}
    }
    func loadMailSync() throws {
        if FileManager.default.fileExists(atPath:syncURL.path) {mailSync=try JSONDecoder().decode(MailSyncState.self,from:Data(contentsOf:syncURL))}
    }
    func saveMailSync() throws {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try JSONEncoder().encode(mailSync).write(to:syncURL,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:syncURL.path)
    }
    func enableMailSync(includeExisting:Bool) async throws {
        try await ensureContactsAccess()
        mailSync.enabled=true
        if !automation.setupComplete {
            automation.setupComplete=true;automation.mail=true;automation.contacts=true;useWebsite=true
            saveAutomationPreferences()
        }
        if includeExisting {mailSync.excludedAtEnable=[];mailSync.enrolled.formUnion(rows.filter{!$0.ignored}.map(\.id))}
        else {mailSync.excludedAtEnable.formUnion(rows.filter{!mailSync.enrolled.contains($0.id)}.map(\.id))}
        try saveMailSync();backgroundPreferenceChanged?();kickMailSync()
    }
    func setMailSyncEnabled(_ enabled:Bool) {
        if enabled {showSyncSetup=true;return}
        mailSync.enabled=false;syncTask?.cancel()
        do {try saveMailSync();backgroundPreferenceChanged?()} catch {errorText=error.localizedDescription}
    }
    func setBackground(_ enabled:Bool) {mailSync.background=enabled;do {try saveMailSync();backgroundPreferenceChanged?()} catch {errorText=error.localizedDescription}}
    func queueChosenPhoto(_ rowID:String) {
        guard mailSync.enabled,let row=rows.first(where:{$0.id==rowID}),!row.ignored else{return}
        mailSync.explicitChoices[MailSyncIdentity.key(row)]=rowID
        mailSync.enrolled.insert(rowID);mailSync.excludedAtEnable.remove(rowID)
        do {try saveMailSync();kickMailSync()} catch {errorText=error.localizedDescription}
    }
    func kickMailSync() {
        guard backgroundWorkAllowed,!isShuttingDown,mailSync.enabled,syncTask == nil,!syncPassRunning,launchError == nil,!busy,!isScanning,discoveryTask == nil,!showSyncSetup else{return}
        syncTask=Task { [weak self] in
            guard let self else{return}
            defer{self.syncTask=nil}
            do {try await Task.sleep(for:.milliseconds(350));try await self.performMailSync()}
            catch is CancellationError {}
            catch {self.syncAttention=error.localizedDescription}
        }
    }
    /// Runs one bounded batch, yielding between cards. No OS prompt from background work.
    func prepareSyncPhotoEvidence() async throws {
        try refreshRecordsIfJournalChanged()
        if !syncFingerprintsReady {
            if (mailSync.fingerprintMigrationRevision ?? 0)<1 {
                let wanted=Set(records.filter{$0.afterPixelHash == nil}.map(\.afterHash)+mailSync.links.filter{$0.imagePixelHash == nil}.map(\.desiredHash))
                let known:[String:String]
                if wanted.isEmpty {known=[:]}
                else {
                    let images=rows.flatMap(\.candidates).map(\.png)
                    known=await Task.detached(priority:.utility) {()->[String:String] in
                        var result:[String:String]=[:]
                        for data in images {let hash=digest(data);if wanted.contains(hash),result[hash]==nil,let pixels=photoPixelHash(data){result[hash]=pixels}}
                        return result
                    }.value
                }
                try Task.checkCancellation()
                if !known.isEmpty {try engine.enrichPhotoFingerprints(known);try reloadRecordsFromJournal()}
                for i in mailSync.links.indices where mailSync.links[i].imagePixelHash == nil && mailSync.links[i].createdByApp {mailSync.links[i].imagePixelHash=known[mailSync.links[i].desiredHash]}
                mailSync.fingerprintMigrationRevision=1
                try saveMailSync()
            }
            syncFingerprintsReady=true
        }
        if records.contains(where:{$0.state == .prepared}) {try engine.reconcileRedundantAliasIntents();try reloadRecordsFromJournal()}
    }
    func performMailSync(limit:Int=20) async throws {
        guard mailSync.enabled,launchError == nil,!busy,!isScanning,!syncPassRunning else{return}
        syncPassRunning=true;defer{syncPassRunning=false}
        if let live=port as? AppleContacts {try live.requireFullAccess()}
        try await prepareSyncPhotoEvidence()
        let live=port as? AppleContacts
        let contactsUnchanged:Bool
        if live != nil,let previous=mailSync.contactsHistoryToken {
            // Change history excludes this app's own transaction author. A
            // missing/expired cursor or query error falls back to the full read.
            contactsUnchanged=(try? await CancellableContactHistoryRead.unchanged(token:previous)) == true
        } else {contactsUnchanged=false}
        let native:[String:ContactSnapshot]?
        if live != nil && !contactsUnchanged {
            let ids=mailSync.links.map(\.contactID)
            native=try await CancellableContactRead.snapshots(ids:ids)
        } else {native=nil}
        try Task.checkCancellation()
        guard mailSync.enabled,!busy,!isScanning else{return}
        let initialRevision=visibleGroupingRevision
        let rowIndex=Dictionary(grouping:rows.indices,by:{MailSyncIdentity.key(rows[$0])})
        if !contactsUnchanged {try reconcileMailSync(rowIndex:rowIndex,nativeSnapshots:native)}
        defer {
            if let live {
                let token=live.historyToken()
                if token != mailSync.contactsHistoryToken {
                    mailSync.contactsHistoryToken=token
                    try? saveMailSync()
                }
            }
            if visibleGroupingRevision != initialRevision {save()}
        }
        try repairSharedSenderNames()
        let eligible=rows.filter{ $0.syncEligible != false && !$0.ignored && !mailSync.suppressedKeys.contains(MailSyncIdentity.key($0)) && (!mailSync.excludedAtEnable.contains($0.id) || mailSync.enrolled.contains($0.id)) }
        let eligibleIDs=Set(eligible.map(\.id));var seenKeys=Set<String>()
        let keys=eligible.map(MailSyncIdentity.key).filter{seenKeys.insert($0).inserted}
        var processed=0,expectedRowsRevision=rowsRevision
        for key in keys {
            guard rowsRevision==expectedRowsRevision else{break}
            try Task.checkCancellation()
            guard mailSync.enabled,!busy,processed<limit else{break}
            if mailSync.suppressedKeys.contains(key) {continue}
            let memberIndices=(rowIndex[key] ?? []).filter{eligibleIDs.contains(rows[$0].id) && !rows[$0].ignored}
            let members=memberIndices.map{rows[$0]}
            guard let first=members.first else{continue}
            let explicit=mailSync.explicitChoices[key]
            let representative=members.first(where:{$0.id==explicit}) ?? first
            guard let candidate=representative.chosen,candidate.source == .monogram || candidate.source == .manual || candidate.recommendedAutomatically else{continue}
            // Wait for an in-flight lookup before creating a fallback-only card.
            if candidate.source == .monogram && (activeLookups.contains{$0.id==Self.lookupJobKey(representative,gravatar:useGravatar)} || representative.lastLookup == nil && (useWebsite || useGravatar)){continue}
            do {
                var link=mailSync.links.first{$0.key==key}
                if let link, explicit == nil,link.desiredHash==digest(candidate.png),
                   (!link.createdByApp || link.externalEmails == true || members.allSatisfy({row in link.emails.contains{$0.caseInsensitiveCompare(row.id) == .orderedSame}})) {
                    if !records.contains(where:{$0.contactID==link.contactID && $0.state == .prepared}) {for i in memberIndices where rows[i].applicationIssue != nil {rows[i].applicationIssue=nil}}
                    continue
                }
                if link == nil {
                    let matches=try members.flatMap {try port.matches(email:$0.id)}
                    let unique=Dictionary(matches.map{($0.id,$0)},uniquingKeysWith: {a,_ in a})
                    guard unique.count<=1 else{throw PortraitError.message("These addresses belong to different contacts and remain separate.")}
                    if let contact=unique.values.first {
                        let created=try engine.records().contains{$0.contactID==contact.id && $0.created && $0.state == .applied}
                        link=MailSyncLink(key:key,contactID:contact.id,emails:Set(contact.emails),createdByApp:created,imageHash:digest(contact.image),desiredHash:digest(candidate.png),externalPhoto:contact.image != nil)
                        // Existing photos stay untouched until a deliberate new selection.
                        if contact.image == nil || (explicit != nil && digest(contact.image) != digest(candidate.png)) {
                            // The first/newest alias may not yet be on this legacy card.
                            // Verify the photo write against the exact email that matched it.
                            guard let matched=members.first(where:{row in contact.emails.contains{$0.caseInsensitiveCompare(row.id) == .orderedSame}}) else{throw PortraitError.message("The email link changed. The original contact is retained.")}
                            _=try engine.replaceSyncedImage(contactID:contact.id,email:matched.id,expectedHash:digest(contact.image),candidate:candidate)
                            if let fresh=try port.get(id:contact.id){link?.imageHash=digest(fresh.image);link?.externalPhoto=false}
                        }
                    } else {
                        let record:ChangeRecord
                        if members.count>1 {record=try engine.applyGroup(emails:members.map(\.email),name:SharedSenderIdentity.contactName(email:representative.email,displayName:representative.name),candidate:candidate,allowCreate:true,managedKey:nil)}
                        else {record=try engine.apply(email:representative.email,name:SharedSenderIdentity.contactName(email:representative.email,displayName:representative.name),candidate:candidate,allowCreate:true)}
                        guard let id=record.contactID,let contact=try port.get(id:id) else{throw PortraitError.message("The new contact could not be verified.")}
                        link=MailSyncLink(key:key,contactID:id,emails:Set(contact.emails),createdByApp:true,imageHash:digest(contact.image),desiredHash:digest(candidate.png))
                    }
                } else if var currentLink=link,let contact=try port.get(id:currentLink.contactID) {
                    // Only app-created brand cards receive additional rotating aliases.
                    if currentLink.createdByApp && currentLink.externalEmails != true {
                        let additions=members.filter{row in !currentLink.emails.contains{$0.caseInsensitiveCompare(row.id) == .orderedSame}}
                        if !additions.isEmpty {
                            guard try additions.allSatisfy({try port.matches(email:$0.id).allSatisfy{$0.id==contact.id}}) else{throw PortraitError.message("This new address already belongs to another contact. The existing link is preserved.")}
                            _=try engine.appendManagedAliases(contactID:contact.id,emails:additions.map(\.email),managedKey:key)
                            currentLink.emails.formUnion(additions.map(\.id))
                        }
                    }
                    if currentLink.desiredHash != digest(candidate.png) || explicit != nil {
                        if digest(contact.image) != digest(candidate.png) && (explicit != nil || (!currentLink.externalPhoto && digest(contact.image)==currentLink.imageHash)) {
                            _=try engine.replaceSyncedImage(contactID:contact.id,email:representative.id,expectedHash:digest(contact.image),candidate:candidate)
                            currentLink.imageHash=digest(try port.get(id:contact.id)?.image);currentLink.externalPhoto=false
                        }
                        currentLink.desiredHash=digest(candidate.png)
                    }
                    link=currentLink
                }
                if let link {
                    var link=link;link.imagePixelHash=photoPixelHash(try port.get(id:link.contactID)?.image)
                    mailSync.links.removeAll{$0.key==key};mailSync.links.append(link)
                    mailSync.enrolled.formUnion(members.map(\.id));mailSync.explicitChoices.removeValue(forKey:key)
                    let contact=try port.get(id:link.contactID)
                    for i in memberIndices {rows[i].current=contact;rows[i].completed=true;rows[i].applicationIssue=nil}
                    try saveMailSync();records=try engine.records()
                }
                processed+=1
            } catch {for i in memberIndices where rows[i].applicationIssue != error.localizedDescription {rows[i].applicationIssue=error.localizedDescription}}
            expectedRowsRevision=rowsRevision
            await Task.yield()
        }
    }
    func reconcileMailSync(rowIndex suppliedIndex:[String:[Int]]?=nil,nativeSnapshots suppliedSnapshots:[String:ContactSnapshot]?=nil) throws {
        guard mailSync.enabled else{return}
        if let live=port as? AppleContacts {try live.requireFullAccess()}
        var changed=false
        let rowIndex=suppliedIndex ?? Dictionary(grouping:rows.indices,by:{MailSyncIdentity.key(rows[$0])})
        let nativeSnapshots=try suppliedSnapshots ?? (port as? AppleContacts)?.snapshots(ids:mailSync.links.map(\.contactID))
        for i in mailSync.links.indices {
            let link=mailSync.links[i]
            let current:ContactSnapshot?
            if let nativeSnapshots {current=nativeSnapshots[link.contactID]} else {current=try port.get(id:link.contactID)}
            if let contact=current {
                for j in rowIndex[link.key] ?? [] where rows[j].current?.id != contact.id {rows[j].current=contact;rows[j].completed=true;changed=true}
                if digest(contact.image) != link.imageHash || Set(contact.emails) != link.emails {
                    changed=true
                    let samePixels=link.imagePixelHash != nil && link.imagePixelHash==photoPixelHash(contact.image)
                    let emailsChanged=Set(contact.emails.map{$0.lowercased()}) != Set(link.emails.map{$0.lowercased()})
                    if emailsChanged {mailSync.links[i].externalEmails=true}
                    if !samePixels {mailSync.links[i].externalPhoto=true}
                    else if link.imageHash=="none" && link.createdByApp {mailSync.links[i].externalPhoto=false}
                    mailSync.links[i].imageHash=digest(contact.image);mailSync.links[i].imagePixelHash=photoPixelHash(contact.image);mailSync.links[i].emails=Set(contact.emails)
                    for j in rowIndex[link.key] ?? [] {
                        rows[j].current=contact
                        // Pull the external photo, do not bounce our cached image back.
                        if mailSync.explicitChoices[link.key]==nil {rows[j].status="Synced with Contacts"}
                    }
                }
            } else {
                // A deletion in Contacts is a persistent stop signal, never recreate.
                changed=true
                mailSync.suppressedKeys.insert(link.key)
                for j in rowIndex[link.key] ?? [] {rows[j].ignored=true;rows[j].current=nil;rows[j].completed=false}
            }
        }
        if changed {try saveMailSync();save()}
    }
    func ignoreSyncedSenders(_ ids:Set<String>) async throws {
        guard !busy else{return}
        syncTask?.cancel();busy=true;defer{busy=false}
        let keys=Set(rows.filter{ids.contains($0.id)}.map(MailSyncIdentity.key))
        // Persist suppression before touching Contacts; failures cannot resurrect cards.
        mailSync.suppressedKeys.formUnion(keys)
        for i in rows.indices where keys.contains(MailSyncIdentity.key(rows[i])) {rows[i].ignored=true}
        try saveMailSync();save()
        lastIgnoredIDs=Set(rows.filter{keys.contains(MailSyncIdentity.key($0))}.map(\.id))
        if mailSync.enabled {
            if let live=port as? AppleContacts {try live.requireFullAccess()}
            for key in keys {
                let linked=mailSync.links.first{$0.key==key}
                let targetID=linked?.contactID ?? rows.first{MailSyncIdentity.key($0)==key}?.current?.id
                guard let targetID else{continue}
                let history=try engine.records().filter{$0.contactID==targetID && $0.state == .applied}
                // Never remove a pre-existing user card. Our own photo-only edits may be undone.
                for record in history.reversed() {try engine.undo(id:record.id)}
                mailSync.links.removeAll{$0.key==key}
                for i in rows.indices where MailSyncIdentity.key(rows[i])==key {rows[i].current=try port.get(id:targetID);rows[i].completed=false}
            }
            records=try engine.records();try saveMailSync();save()
        }
        reconcileSelection()
    }
    func restoreIgnored(_ ids:Set<String>) {
        let keys=Set(rows.filter{ids.contains($0.id)}.map(MailSyncIdentity.key))
        mailSync.suppressedKeys.subtract(keys);mailSync.links.removeAll{keys.contains($0.key)}
        for i in rows.indices where keys.contains(MailSyncIdentity.key(rows[i])) {rows[i].ignored=false;mailSync.enrolled.insert(rows[i].id)}
        lastIgnoredIDs=[];do{try saveMailSync();save();kickMailSync()}catch{errorText=error.localizedDescription}
    }
}

// Junk and trash may remain discoverable in the local library, but never enter
// the automatic address-book stream solely because a full archive scan saw them.
enum MailSyncMailboxPolicy {
    static func allows(_ path:[String])->Bool {
        let excluded:Set<String>=["junk","junk email","spam","trash","bin","deleted items","deleted messages","drafts","outbox","垃圾邮件","垃圾郵件","垃圾箱","废纸篓","廢紙簍","已删除邮件","草稿"]
        return !path.contains{excluded.contains($0.lowercased().trimmingCharacters(in:.whitespaces))}
    }
}
