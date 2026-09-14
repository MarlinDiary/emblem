import Foundation
import Contacts
import PortraitCore

struct AutomationPreferences: Codable {
    var setupComplete = false
    var enabled = true
    var website = false
    var gravatar = false
    var mail = true
    var contacts = true
    var excludedEmails: Set<String>?
    var contactsPrompted = false
    var lastFullMail: Date?
    var lastInbox: Date?
    var lastInboxSweep: Date?
    var mailPrimaryGmailEmails: [String]?
    var mailRoutingCatchup: Bool?
    var lastContacts: Date?
    var mailRetryAfter: Date?
    var fullMailRetryAfter: Date?
    var mailRetryChannels: Int?
    var contactsRetryAfter: Date?

    mutating func separateMailRetryChannels() {
        guard mailRetryChannels == nil else {return}
        // Older versions shared one hour-long backoff across history and inbox.
        // Keep that deadline for history; give the independent inbox one chance.
        fullMailRetryAfter=fullMailRetryAfter ?? mailRetryAfter
        mailRetryAfter=nil;mailRetryChannels=1
    }
}

enum AutomaticConnectionPolicy {
    static func mayRequestContacts(_ status: CNAuthorizationStatus) -> Bool {
        status == .notDetermined || status == .authorized
    }
}

enum AutomaticLookupPolicy {
    static func key(_ row: SenderRow, website: Bool, gravatar: Bool) -> String {
        let person = website ? InstitutionalProfilePolicy.normalizedPersonName(row.name).map { "|person=\($0)" } ?? "" : ""
        // One-time website evidence migration refreshes legacy icon choices,
        // while person photos and useful BIMI keep their existing stable keys.
        // Each successful job records the resulting key, including misses.
        let outdatedArtwork = row.candidates.contains { $0.source == .officialBrand && $0.artwork == nil }
        let needsWebsiteEvidence = website && row.candidates.contains {
            ([CandidateSource.touchIcon, .manifest, .favicon].contains($0.source) && $0.declared == nil) || $0.source == .domainIcon
        }
        let official=URL(string:row.website ?? "https://"+row.email.domain+"/").flatMap{OfficialBrandAssets.asset(for:$0)}
        let needsOfficial=website && official.map{asset in !row.candidates.contains{$0.source == .officialBrand && $0.origin==asset.assetURL.absoluteString}} == true
        let revision = needsOfficial ? "v014-official" : needsWebsiteEvidence ? "v013-site" : outdatedArtwork ? "v011-artwork" : row.candidates.allSatisfy { $0.source == .monogram } ? "v094-missing" : "v092"
        return "\(revision)|\(website)|\(gravatar)|\(row.website ?? DomainRouting.primaryHost(for:row.email.domain))" + (row.profileURL.map { "|profile=\($0)" } ?? "") + person
    }
    static func due(_ row: SenderRow, website: Bool, gravatar: Bool, now: Date, managedFallback:Bool=false) -> Bool {
        guard website || gravatar || row.profileURL != nil, !row.ignored, (managedFallback || (!row.completed && row.current?.image == nil)),
              !(row.selectionIsManual ?? (row.chosen != nil)) else { return false }
        if row.lookupPolicy != key(row,website:website,gravatar:gravatar) { return true }
        guard let date = row.lastLookup else { return true }
        // A usable selected image wins over failures from weaker fallbacks.
        // Hourly retry is only for an entirely unresolved transient failure.
        let hasPhoto = row.chosen != nil && row.chosen?.source != .monogram
        let failed = !hasPhoto && row.sourceReports?.contains { $0.outcome == .unavailable } == true
        let interval: TimeInterval = hasPhoto ? 30 * 86400 : failed ? 3600 : 7 * 86400
        return now.timeIntervalSince(date) >= interval
    }
}

struct ActiveLookup: Identifiable, Sendable {
    let id: String
    let host: String
    let started: Date
}
private struct LookupJobResult: Sendable {
    let key: String
    let result: LookupResult
    let timedOut: Bool
}

extension AppModel {
    var automationURL: URL { root.appendingPathComponent("automation.json") }
    var automaticStatus: String {
        if !automation.setupComplete { return "Set Up Automatic Sync" }
        if !automaticEnabled { return "Automatic Lookup Paused" }
        if isScanning { return "Finding Photos · \(automaticFinished) / \(automaticTotal)" }
        if automaticWorking { return "Finding Photos · \(automaticFinished) / \(automaticTotal)" }
        return "Automatic Lookup On"
    }
    var automaticReadyCount: Int { rows.filter { !$0.ignored && !$0.completed && $0.current?.image == nil && $0.chosen != nil }.count }
    func loadAutomationPreferences() throws {
        if FileManager.default.fileExists(atPath:automationURL.path) {
            automation = try JSONDecoder().decode(AutomationPreferences.self,from:Data(contentsOf:automationURL))
        } else if let report = scanReport, report.phase == .completed {
            switch report.source {
            case .allMail: automation.lastFullMail = report.finished; automation.lastInbox = report.finished
            case .inbox: automation.lastInbox = report.finished
            case .contacts: automation.lastContacts = report.finished
            }
        }
        automation.separateMailRetryChannels()
        if automation.setupComplete {
            contactsConnected = automation.contacts && usesLiveContactScan && CNContactStore.authorizationStatus(for:.contacts) == .authorized
            mailConnected = automation.lastInbox != nil || automation.lastFullMail != nil
        }
        useWebsite = automation.website; useGravatar = automation.gravatar; automaticEnabled = automation.enabled
        automationReady = true
    }
    func saveAutomationPreferences() {
        guard automationReady, launchError == nil else { return }
        automation.website = useWebsite; automation.gravatar = useGravatar; automation.enabled = automaticEnabled
        do {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            try JSONEncoder().encode(automation).write(to:automationURL,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:automationURL.path)
        } catch { errorText = "Settings were not saved: \(error.localizedDescription)" }
    }
    func automaticSourcesChanged() {
        guard automationReady else { return }
        stopAutomaticWork()
        automaticResolver = nil
        saveAutomationPreferences()
    }
    func enableAutomaticSetup() {
        automation.setupComplete = true
        useWebsite = true // This one-time choice explicitly discloses website requests in the UI.
        automaticEnabled = true
        showAutomaticSetup = false
        saveAutomationPreferences()
        automaticTick()
    }
    func stopAutomaticWork() {
        gmailSyncTask?.cancel();gmailPushMaintenanceTask?.cancel(); automaticTask?.cancel(); discoveryTask?.cancel() }
    func refreshAutomaticWorking() { automaticWorking = automaticTask != nil || discoveryTask != nil }
    func pauseAutomatic() {
        automaticEnabled = false
        stopAutomaticWork()
    }
    var automaticMayRun: Bool {
        backgroundWorkAllowed && !isShuttingDown && !demo && automation.setupComplete && automaticEnabled && launchError == nil && !busy && !syncPassRunning &&
        !showApplyConfirmation && !showBatchConfirmation && undoBatchID == nil && !showSourceConsent && !showContactConsent && !showAutomaticSetup &&
        !showImport && !showScan && undoRecord == nil
    }
    func automaticTick(now: Date = Date()) {
        consumeGmailPushInbox()
        kickGmailPushMaintenance(now:now)
        kickGmailSync(now:now)
        kickMailSync()
        guard automaticMayRun else { return }
        if discoveryTask == nil && !isScanning {
            discoveryTask = Task { [weak self] in
                guard let self else { return }
                defer { self.discoveryTask = nil; self.refreshAutomaticWorking();self.kickMailSync() }
                do { try await self.automaticallyDiscover(now:now) }
                catch is CancellationError { }
                catch { self.automaticAttention = error.localizedDescription }
            }
            refreshAutomaticWorking()
        }
        kickAutomaticLookup(now:now);kickMailSync()
    }
    // A scan is a producer, not a prerequisite. Each page wakes the consumer;
    // both tasks run independently while awaiting Mail, Contacts, or the network.
    /// Only an unchanged, app-managed automatic monogram can be upgraded.
    /// Build the link index once per pass; no image decoding in the row loop.
    func managedFallbackIDs()->Set<String> {
        let links=Dictionary(grouping:mailSync.links,by: \.contactID)
        return Set(rows.compactMap { row in
            guard !row.ignored,row.selectionIsManual != true,let chosen=row.chosen,chosen.source == .monogram,
                  let current=row.current,let link=links[current.id]?.first,link.createdByApp,!link.externalPhoto,
                  link.desiredHash==digest(chosen.png),link.imageHash==digest(current.image) else{return nil}
            return row.id
        })
    }
    func kickAutomaticLookup(now: Date = Date()) {
        let fallbacks=managedFallbackIDs()
        guard automaticMayRun, automaticTask == nil,
              rows.contains(where:{ AutomaticLookupPolicy.due($0,website:useWebsite,gravatar:useGravatar,now:now,managedFallback:fallbacks.contains($0.id)) }) else { return }
        automaticTask = Task { [weak self] in
            guard let self else { return }
            defer { self.automaticTask = nil; self.activeLookups = []; self.refreshAutomaticWorking();self.kickMailSync() }
            do { try await self.automaticallyResolve(now:now) }
            catch is CancellationError { }
            catch { self.automaticAttention = error.localizedDescription }
        }
        refreshAutomaticWorking()
    }
    func automaticallyDiscover(now: Date) async throws {
        func due(_ date: Date?, after: TimeInterval) -> Bool { date.map { now.timeIntervalSince($0) >= after } ?? true }
        let permission: CNAuthorizationStatus = automation.contacts && usesLiveContactScan ? CNContactStore.authorizationStatus(for:.contacts) : .authorized
        if automation.contacts && (!contactsConnected || due(automation.lastContacts,after:900)) && (permission == .authorized || (automation.contactsRetryAfter ?? .distantPast) <= now) {
            // macOS may reset an ad-hoc build's permission identity after an update.
            // A fresh system 'notDetermined' status needs a fresh OS prompt; denied/restricted do not.
            if usesLiveContactScan && !AutomaticConnectionPolicy.mayRequestContacts(permission) {
                contactsConnected = false
                automaticAttention = "Allow Contacts access in System Settings → Privacy & Security. Photo previews remain available."
                automation.contactsRetryAfter = now.addingTimeInterval(900)
            } else {
                automation.contactsPrompted = true; saveAutomationPreferences()
                try Task.checkCancellation()
                await performScan(.contacts,automatic:true)
                try Task.checkCancellation()
                if scanReport?.phase == .completed { automation.lastContacts = now; automation.contactsRetryAfter = nil }
                else { automation.contactsRetryAfter = now.addingTimeInterval(900) }
            }
            saveAutomationPreferences()
        }
        try Task.checkCancellation()
        // Resolve Gmail first. Failure is persisted before choosing the fallback;
        // Mail's own retry and Contacts synchronization stay independent.
        if let gmailTask=gmailSyncTask {await gmailTask.value}
        try Task.checkCancellation()
        if automation.mail && mailAutomationAvailable {
            let primary=MailProviderRouting.primaryEmails(gmail.accounts,now:now)
            let routingChanged=Set(automation.mailPrimaryGmailEmails ?? []) != primary
            // A newly restored fallback must catch up the whole inbox, not reuse
            // the global Mail cursor from another account and silently miss mail.
            if routingChanged {
                automation.mailPrimaryGmailEmails=primary.sorted()
                automation.mailRoutingCatchup=true
                automation.mailRetryAfter=nil;automation.fullMailRetryAfter=nil
                automation.lastInboxSweep=nil;automation.lastFullMail=nil
            }
            let missingDates=usesLiveMailScan && !rows.isEmpty && rows.allSatisfy{$0.lastInboxReceivedAt == nil}
            let inboxAvailable=(automation.mailRetryAfter ?? .distantPast)<=now
            let historyAvailable=(automation.fullMailRetryAfter ?? .distantPast)<=now
            let inboxDue=due(automation.lastInbox,after:mailSync.enabled ? 60:900)
            let source:ScanSource?
            if inboxAvailable && automation.mailRoutingCatchup == true {source = .inbox}
            else if inboxAvailable && (missingDates || (mailSync.enabled && automation.lastInbox != nil && inboxDue)) {source = .inbox}
            else if automation.mailRoutingCatchup != true && allowsHistoryScan && historyAvailable && due(automation.lastFullMail,after:86400) {source = .allMail}
            else if inboxAvailable && inboxDue {source = .inbox}
            else {source=nil}
            if let source {
                do {
                    var incremental=false
                    if source == .inbox,let since=automation.lastInbox,!due(automation.lastInboxSweep,after:86400),
                       let page=try await mailScanner.recentInbox(since:since.addingTimeInterval(-300),excludingAccountEmails:primary) {
                        incremental=try await ingestRecentInbox(page)
                    }
                    if !incremental {await performScan(source,automatic:true,excludingAccountEmails:primary)}
                    try Task.checkCancellation()
                    if scanReport?.phase == .completed {
                        if source == .inbox {automation.mailRoutingCatchup=false}
                        if source == .allMail { automation.lastFullMail = now }
                        automation.lastInbox=now
                        if source == .inbox {
                            if !incremental {automation.lastInboxSweep=now}
                        }
                        if source == .allMail {automation.fullMailRetryAfter=nil}
                        else {automation.mailRetryAfter=nil}
                    } else {deferMailRetry(source,now:now)}
                    saveAutomationPreferences()
                } catch is CancellationError {throw CancellationError()}
                catch {deferMailRetry(source,now:now);saveAutomationPreferences();throw error}
            }
        }
        if !mailSync.enabled {syncManagedAliases()}
    }
    private func deferMailRetry(_ source:ScanSource,now:Date) {
        if source == .allMail {automation.fullMailRetryAfter=now.addingTimeInterval(3600)}
        else {automation.mailRetryAfter=now.addingTimeInterval(300)}
    }
    static func lookupJobKey(_ row: SenderRow, gravatar: Bool) -> String {
        // Never fan out a person's Gravatar, or a subdomain fallback, to other identities.
        (gravatar || row.profileURL != nil || InstitutionalProfilePolicy.isEligible(email: row.email, displayName: row.name)) ? row.id + "|" + (row.website ?? "") + "|" + (row.profileURL ?? "") : row.website ?? row.email.domain
    }
    func automaticallyResolve(now: Date) async throws {
        guard useWebsite || useGravatar || rows.contains(where:{ $0.profileURL != nil }) else { return }
        defer { save() }
        let website = useWebsite, gravatar = useGravatar, timeout = lookupTimeout
        let fallbacks=managedFallbackIDs()
        let resolver = automaticResolver ?? resolverFactory()
        automaticResolver = resolver
        var inFlight = Set<String>()
        // Consume fresh pages as they arrive. Three independent sites, at most four
        // icons per site; a stalled site cannot hold the rest of the queue hostage.
        try await withThrowingTaskGroup(of:LookupJobResult.self) { group in
            while true {
                try Task.checkCancellation()
                guard automaticMayRun, useWebsite == website, useGravatar == gravatar else { group.cancelAll(); return }
                let due = rows.filter { AutomaticLookupPolicy.due($0,website:website,gravatar:gravatar,now:now,managedFallback:fallbacks.contains($0.id)) }
                automaticTotal = automaticFinished + due.count
                var ordered = due.sorted {
                    if ($0.id == selectedID) != ($1.id == selectedID) { return $0.id == selectedID }
                    return (Self.lookupJobKey($0,gravatar:gravatar),$0.id) < (Self.lookupJobKey($1,gravatar:gravatar),$1.id)
                }
                while inFlight.count < 3 && !ordered.isEmpty {
                    let row = ordered.removeFirst(), key = Self.lookupJobKey(row,gravatar:gravatar)
                    guard inFlight.insert(key).inserted else { continue }
                    activeLookups.append(.init(id:key,host:row.website.flatMap { URL(string:$0)?.host } ?? DomainRouting.primaryHost(for:row.email.domain),started:Date()))
                    group.addTask {
                        do {
                            let result = try await withDeadline(seconds:timeout) {
                                try await resolver.resolve(email:row.email,displayName:row.name,gravatar:gravatar,website:website,websiteOverride:row.website.flatMap(WebsiteAddress.parse),profileURL:row.profileURL.flatMap(WebsiteAddress.parse))
                            }
                            return LookupJobResult(key:key,result:result,timedOut:false)
                        } catch is CancellationError { throw CancellationError() }
                        catch {
                            return LookupJobResult(key:key,result:LookupResult(candidates:[],reports:[.init(.website,.unavailable,detail:error.localizedDescription)]),timedOut:error is DeadlineExceeded)
                        }
                    }
                }
                guard !inFlight.isEmpty, let finished = try await group.next() else { return }
                inFlight.remove(finished.key); activeLookups.removeAll { $0.id == finished.key }
                try Task.checkCancellation()
                guard automaticMayRun, useWebsite == website, useGravatar == gravatar else { group.cancelAll(); return }
                if finished.timedOut { automaticTimeouts += 1 }
                // Re-evaluate after await: deleted, ignored, completed, and manually
                // selected rows win. New aliases from later pages receive this result.
                let stillManagedFallbacks=managedFallbackIDs()
                var updated = 0, replacement = rows
                var changedIDs = Set<String>()
                for index in replacement.indices where Self.lookupJobKey(replacement[index],gravatar:gravatar) == finished.key && AutomaticLookupPolicy.due(replacement[index],website:website,gravatar:gravatar,now:now,managedFallback:stillManagedFallbacks.contains(replacement[index].id)) {
                    let result = finished.result, previous = replacement[index].chosen
                    let manual = replacement[index].candidates.filter { $0.source == .manual && !$0.lowResolution }
                    var candidates = manual + Array(CandidateSelection.recommended(result.candidates).prefix(4))
                    if !candidates.contains(where: \.recommendedAutomatically), let previous { candidates.insert(previous,at:0) }
                    replacement[index].candidates = candidates
                    if !candidates.contains(where: \.recommendedAutomatically), let letter=try? NameAvatar.candidate(name:replacement[index].name) { candidates.append(letter); replacement[index].candidates=candidates }
                    replacement[index].selectedCandidate = CandidateSelection.automaticChoice(candidates)?.id
                    replacement[index].selectionIsManual = false
                    replacement[index].notes = replacement[index].notes.filter { ContactMatchNote.isAmbiguous($0) } + result.notes
                    replacement[index].sourceReports = result.reports; replacement[index].lastLookup = result.checkedAt
                    replacement[index].lookupPolicy = AutomaticLookupPolicy.key(replacement[index],website:website,gravatar:gravatar)
                    replacement[index].status = replacement[index].chosen?.source == .monogram ? "Monogram · Generated Locally" : replacement[index].chosen != nil ? "Photo Found" : finished.timedOut ? "Lookup timed out; it will retry." : result.candidates.isEmpty ? "No photo yet; lookup will retry." : "Photo Needs Review"
                    changedIDs.insert(replacement[index].id)
                    updated += 1
                }
                if updated > 0 { replaceRowsPreservingGrouping(replacement, changedIDs: changedIDs) }
                automaticFinished += updated
                if updated > 0 && (automaticFinished % 10 < updated) { save() }
                await Task.yield()
            }
        }
    }
    func contactsDidChange() {
        // Sync pulls linked cards directly. Do not rescan/re-encode the entire
        // library for each notification caused by our own Contacts writes.
        if !mailSync.enabled {automation.lastContacts = nil}
        kickMailSync()
    }
}
