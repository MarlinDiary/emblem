import Foundation
import Contacts
import PortraitCore

extension AppModel {
    func startScan(_ source: ScanSource) {
        guard !busy, !isScanning, discoveryTask == nil else { return }
        showScan = false
        discoveryTask = Task {
            defer { discoveryTask = nil; refreshAutomaticWorking() }
            await performScan(source)
        }
        refreshAutomaticWorking()
    }
    func performScan(_ source: ScanSource, automatic: Bool = false, excludingAccountEmails:Set<String> = []) async {
            guard !scanActive else { return }
            scanActive = true
            defer { scanActive = false; kickAutomaticLookup() }
            kickAutomaticLookup()
            if !automatic { self.section = "all"; self.search = ""; self.reconcileSelection() }
            self.scanStopping = false
            self.scanReport = ScanReport(source:source)
            self.scanStage = source == .contacts ? "Reading Contacts…" : "Reading Mailboxes…"
            var seen = Set<String>()
            var inboxDates:[String:Date]=[:]
            do {
                try await self.persistScanCheckpoint()
                if source == .contacts {
                    if !self.demo && self.usesLiveContactScan {
                        if !self.allowsPermissionPrompts && CNContactStore.authorizationStatus(for:.contacts) != .authorized {throw PortraitError.message("Open MailPortrait to allow Contacts access.") }
                        try await self.apple.requestAccess(); self.accountName = try self.apple.defaultAccountName() }
                    self.contactsConnected = true
                    var index: [String: [ContactSnapshot]] = [:]
                    for try await batch in self.contactsBatches() {
                        try Task.checkCancellation()
                        self.scanReport?.examined += batch.count
                        for contact in batch {
                            let valid = contact.emails.compactMap(EmailAddress.init)
                            if valid.isEmpty { self.scanReport?.withoutEmail += 1 }
                            self.scanReport?.invalid += contact.emails.count - valid.count
                            for address in valid {
                                if !(index[address.value]?.contains { $0.id == contact.id } ?? false) { index[address.value, default:[]].append(contact) }
                                self.ingestScanned(email:address, name:contact.name, seen:&seen)
                            }
                        }
                        self.applyScanContactIndex(index,partial:true)
                        self.kickAutomaticLookup()
                        self.scanStage = "Checked \(self.scanReport?.examined ?? 0) contacts"
                        try await self.persistScanCheckpoint()
                        await Task.yield()
                    }
                    self.scanReport?.total = self.scanReport?.examined
                    self.applyScanContactIndex(index)
                } else {
                    if self.demo && self.usesLiveMailScan { throw PortraitError.message("Demo mode does not read Apple Mail.") }
                    let inventory = try await self.mailScanner.inventory(source:source,excludingAccountEmails:excludingAccountEmails)
                    self.mailConnected = true
                    self.scanReport?.mailboxes = inventory.mailboxes.count
                    self.scanReport?.total = inventory.mailboxes.reduce(0) { $0 + $1.count }
                    self.scanReport?.warnings = inventory.warnings
                    for mailbox in inventory.mailboxes {
                        try Task.checkCancellation()
                        self.scanStage = mailbox.label
                        var position = 1
                        var changed = false
                        var unreadable = 0
                        do {
                            while position <= mailbox.count {
                                try Task.checkCancellation()
                                let size = min(200,mailbox.count - position + 1)
                                let page = try await self.mailScanner.page(mailbox:mailbox,start:position,size:size)
                                try Task.checkCancellation()
                                if page.currentCount != mailbox.count { changed = true }
                                guard !page.senders.isEmpty else {
                                    self.scanReport?.warnings.append("Mailbox contents changed; some items were not read: \(mailbox.label)")
                                    break
                                }
                                unreadable += page.unreadable
                                self.scanReport?.examined += page.senders.count
                                for (offset,sender) in page.senders.enumerated() {
                                    let addresses = EmailAddress.parseList(sender)
                                    guard addresses.count == 1, let email = addresses.first else { self.scanReport?.invalid += 1; continue }
                                    let received = source == .inbox && page.receivedAt.indices.contains(offset) ? page.receivedAt[offset] : nil
                                    if let received {inboxDates[email.value]=max(inboxDates[email.value] ?? .distantPast,received)}
                                    self.ingestScanned(email:email,name:email.suggestedDisplayName(in:sender),seen:&seen,eligibleForSync:MailSyncMailboxPolicy.allows(mailbox.path),receivedAt:received)
                                }
                                position += page.senders.count
                                self.kickAutomaticLookup()
                                try await self.persistScanCheckpoint()
                                await Task.yield()
                            }
                            if unreadable > 0 { self.scanReport?.warnings.append("\(unreadable) sender records were not readable: \(mailbox.label)") }
                            self.scanReport?.completedMailboxes += 1
                            if changed { self.scanReport?.warnings.append("Mailbox contents changed during import. Check again to fill gaps: \(mailbox.label)") }
                        } catch is CancellationError { throw CancellationError() }
                        catch { self.scanReport?.warnings.append("Import incomplete for \(mailbox.label): \(error.localizedDescription)") }
                    }
                    self.lastMailImportCount = self.scanReport?.examined
                    if (!automatic || self.automation.contacts) && (self.demo || !self.usesLiveContactScan || CNContactStore.authorizationStatus(for:.contacts) == .authorized) {
                        self.scanStage = "Matching Contacts…"
                        do {
                            var index: [String:[ContactSnapshot]] = [:]
                            for try await batch in self.contactsBatches() {
                                try Task.checkCancellation()
                                for contact in batch {
                                    for email in contact.emails.compactMap(EmailAddress.init) {
                                        if !(index[email.value]?.contains { $0.id == contact.id } ?? false) { index[email.value,default:[]].append(contact) }
                                    }
                                }
                            }
                            self.applyScanContactIndex(index); self.contactsConnected = true
                            if !self.demo && self.usesLiveContactScan { self.accountName = try self.apple.defaultAccountName() }
                        } catch is CancellationError { throw CancellationError() }
                        catch { self.contactsConnected = false; self.scanReport?.warnings.append("Senders are kept; Contacts matching did not finish: \(error.localizedDescription)") }
                    }
                }
                self.scanReport?.phase = self.scanReport?.warnings.isEmpty == true ? .completed : .partial
                if source == .inbox,gmail.accounts.isEmpty,excludingAccountEmails.isEmpty,self.scanReport?.phase == .completed,(!inboxDates.isEmpty || self.scanReport?.examined == 0) {
                    var replacement=rows;var changed=false
                    for i in replacement.indices where replacement[i].lastInboxReceivedAt != inboxDates[replacement[i].id] {replacement[i].lastInboxReceivedAt=inboxDates[replacement[i].id];changed=true}
                    if changed {rows=replacement}
                }
            } catch is CancellationError {
                self.scanReport?.phase = .stopped
            } catch {
                self.scanReport?.phase = .failed
                self.scanReport?.warnings.append(error.localizedDescription)
                if !automatic { self.errorText = error.localizedDescription }
            }
            self.scanReport?.finished = Date()
            self.scanStopping = false; self.scanStage = ""
            if !automatic { self.section = "all" }; self.reconcileSelection()
            self.message = self.scanReport?.resultText ?? "Import Finished"
            do { try await self.persistScanCheckpoint(force:true) }
            catch { self.errorText = "The library was not saved. Keep the app open and check the disk: \(error.localizedDescription)" }
            if automatic, let warning = self.scanReport?.warnings.first { self.automaticAttention = warning }
    }
    func contactsBatches() -> AsyncThrowingStream<[ContactSnapshot],Error> {
        if demo && usesLiveContactScan {
            let contacts = (port as? FixtureContactStore)?.contacts.values.sorted { $0.id < $1.id } ?? []
            return AsyncThrowingStream { $0.yield(contacts); $0.finish() }
        }
        return contactScanner.batches()
    }
    func ingestScanned(email: EmailAddress, name: String, seen: inout Set<String>,eligibleForSync:Bool=true,receivedAt:Date?=nil) {
        if let receivedAt,let i=rows.firstIndex(where:{$0.id==email.value}),receivedAt > (rows[i].lastInboxReceivedAt ?? .distantPast) {
            rows[i].lastInboxReceivedAt=receivedAt;rows[i].mailDisplayName=name
        }
        if eligibleForSync,let i=rows.firstIndex(where:{$0.id==email.value}),rows[i].syncEligible==false {rows[i].syncEligible=true}
        guard seen.insert(email.value).inserted else { scanReport?.duplicateEntries += 1; return }
        guard !(automation.excludedEmails?.contains(email.value) ?? false) else { return }
        guard !rows.contains(where: { $0.id == email.value }) else { scanReport?.existing += 1; return }
        rows.insert(SenderRow(email:email,name:name.isEmpty ? String(email.value.split(separator:"@")[0]) : String(name.prefix(120)),syncEligible:eligibleForSync,discoveryOrder:nextDiscoveryOrder,discoveredAt:Date(),lastInboxReceivedAt:receivedAt,mailDisplayName:receivedAt == nil ? nil : name),at:0)
        scanReport?.added += 1
    }
    func applyScanContactIndex(_ index: [String:[ContactSnapshot]], partial: Bool = false) {
        let duplicateNote = ContactMatchNote.ambiguous
        var replacement=rows,changed=false
        for position in replacement.indices {
            if partial && index[replacement[position].id] == nil {continue}
            let matches=index[replacement[position].id] ?? []
            let current=matches.count == 1 ? matches.first : nil
            let notes=replacement[position].notes.filter{!ContactMatchNote.isAmbiguous($0)} + (matches.count > 1 ? [duplicateNote] : [])
            if current != replacement[position].current || notes != replacement[position].notes {
                replacement[position].current=current;replacement[position].notes=notes;changed=true
            }
        }
        if changed {rows=replacement}
    }
    /// Encoding the image-bearing library is expensive. Do it off the UI actor,
    /// checkpoint at most every five seconds, and never replace a newer save.
    func persistScanCheckpoint(force:Bool=false) async throws {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        if lastSavedRowsRevision != rowsRevision && (force || Date().timeIntervalSince(lastScanCheckpoint)>=5) {
            let snapshot=rows,revision=rowsRevision
            let data=try await Task.detached(priority:.utility) {try JSONEncoder().encode(snapshot)}.value
            if !force {try Task.checkCancellation()}
            if revision == rowsRevision {
                try data.write(to:stateURL,options:.atomic)
                try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:stateURL.path)
                try clearInboxReceiptOverlay()
                lastSavedRowsRevision=revision;lastScanCheckpoint=Date()
            }
        }
        if let scanReport {try JSONEncoder().encode(scanReport).write(to:scanURL,options:.atomic)}
    }

    func persistScan() throws {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        // Persist rows before the summary so a crash never claims more durable rows than exist.
        try JSONEncoder().encode(rows).write(to:stateURL,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:stateURL.path)
        try clearInboxReceiptOverlay()
        if let scanReport {
            try JSONEncoder().encode(scanReport).write(to:scanURL,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:scanURL.path)
        }
    }
}
