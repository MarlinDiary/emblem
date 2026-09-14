import AppKit
import Contacts
import SwiftUI
import UniformTypeIdentifiers
import PortraitCore

enum ContactMatchNote {
    static let ambiguous="This email matches multiple contacts. Review them before applying a photo."
    static func isAmbiguous(_ note:String)->Bool {note==ambiguous || note.contains("匹配多个联系人")}
}

struct SenderRow: Identifiable, Codable, Sendable {
    var id: String { email.value }
    var email: EmailAddress
    var name: String
    var ignored = false
    var completed = false
    var candidates: [AvatarCandidate] = []
    var selectedCandidate: UUID?
    var notes: [String] = []
    var sourceReports: [SourceReport]?
    var selectionIsManual: Bool? = false
    var lookupPolicy: String?
    var lastLookup: Date?
    var website: String?
    var profileURL: String?
    var syncEligible:Bool?
    var discoveryOrder:Int?
    var discoveredAt: Date?
    var lastInboxReceivedAt: Date?
    var mailDisplayName: String?
    var current: ContactSnapshot?
    var applicationIssue: String?
    var status = "Not Checked"
    var displayName:String {SharedSenderIdentity.contactName(email:email,displayName:name)}
    var chosen: AvatarCandidate? { candidates.first { $0.id == selectedCandidate } }
}

@MainActor final class AppModel: ObservableObject {
    var isShuttingDown=false
    var allowsHistoryScan=true
    var mailAutomationAvailable=true
    var allowsPermissionPrompts=true
    var backgroundPreferenceChanged:(()->Void)?
    @Published var backgroundServiceIssue:String?
    @Published var backgroundServiceNeedsApproval=false
    let backgroundWorkAllowed:Bool
    @Published var mailSync=MailSyncState()
    @Published var showSyncSetup=false
    @Published var showHistoryTools=false
    @Published var syncAttention:String?
    @Published var lastIgnoredIDs=Set<String>()
    @Published var ignoreSummary:String?
    var syncFingerprintsReady=false
    var syncPassRunning=false
    var syncTask:Task<Void,Never>?
    var rowsRevision:UInt64=0
    var contactMutationRunner:((ContactMutationRequest) async throws -> ContactMutationResponse)?
    var lastSavedRowsRevision:UInt64?
    var lastScanCheckpoint=Date.distantPast
    @Published var rows: [SenderRow] = [] { didSet { rowsRevision &+= 1; if !preserveVisibleGroupingOnRowsChange { invalidateVisibleGrouping() } } }
    var preserveVisibleGroupingOnRowsChange = false
    @Published var selectedID: String? { didSet { if oldValue != selectedID { pinnedChoiceID = nil } } }
    var pinnedChoiceID: String?
    let navigationMemory=ListNavigationMemory()
    var navigationKey: String { section + "|" + search }
    var showsBatchAction: Bool { !mailSync.enabled && section != "history" && !batchScopeIDs.isEmpty }
    @Published var section = "all" { didSet {
        guard oldValue != section else { return }
        navigationMemory.selections[oldValue]=selectedID
        pinnedChoiceID=nil;invalidateVisibleGrouping()
        selectedID=navigationMemory.selections[section]
        batchMode=false;selectedForBatch.removeAll()
    } }
    @Published var busy = false
    @Published var message = "Find sender photos automatically."
    @Published var errorText: String?
    @Published var records: [ChangeRecord] = []
    var recordsFileRevision:String?
    @Published var contactsConnected = false
    @Published var mailConnected = false
    @Published var lastMailImportCount: Int?
    @Published var showScan = false
    @Published var scanSource = ScanSource.allMail
    @Published var scanReport: ScanReport?
    @Published var scanStage = ""
    @Published var scanStopping = false
    let mailScanner: any MailScannerPort
    let contactScanner: any ContactsScannerPort
    let usesLiveMailScan: Bool
    let usesLiveContactScan: Bool
    var scanURL: URL { root.appendingPathComponent("last-scan.json") }
    @Published var scanActive = false
    var isScanning: Bool { scanActive }
    @Published var accountName = "Default Contacts account"
    @Published var pendingIDs: [String] = []
    @Published var pendingManagedGroupID: String?
    @Published var manageFutureAliases = true
    @Published var managedIdentities:[ManagedIdentity] = []
    @Published var showApplyConfirmation = false
    @Published var allowCreate = false
    @Published var undoRecord: ChangeRecord?
    @Published var search = "" { didSet { pinnedChoiceID = nil; invalidateVisibleGrouping() } }
    @Published var websiteOverride = ""
    @Published var selectedForBatch = Set<String>()
    @Published var showImport = false
    @Published var importText = ""
    @Published var gmail = GmailConnections()
    @Published var gmailConnecting = false
    @Published var gmailIssue: String?
    var gmailSyncTask: Task<Void,Never>?
    var gmailSentBootstrapTask: Task<GmailBatch,Error>?
    var gmailSignInTask: Task<Void,Never>?
    var gmailPushMaintenanceTask: Task<Void,Never>?
    var gmailPushListenerTask: Task<Void,Never>?
    var gmailForcedAccountIDs=Set<String>()
    lazy var gmailAuthorization = GmailAuthorization()
    var gmailAPI = GmailAPI()
    var gmailTokenProvider: ((String) async throws -> String)?
    var rowsSnapshotEncoder: (([SenderRow]) async throws -> Data)?
    @Published var useGravatar = false { didSet { automaticSourcesChanged() } }
    @Published var useWebsite = false { didSet { automaticSourcesChanged() } }
    @Published var automaticEnabled = true { didSet { if !automaticEnabled { stopAutomaticWork() }; saveAutomationPreferences() } }
    @Published var showAutomaticSetup = false
    @Published var automaticWorking = false
    @Published var automaticFinished = 0
    @Published var automaticTotal = 0
    @Published var automaticAttention: String?
    @Published var automation = AutomationPreferences()
    var automationReady = false
    var automaticTask: Task<Void,Never>?
    var discoveryTask: Task<Void,Never>?
    @Published var activeLookups: [ActiveLookup] = []
    @Published var automaticTimeouts = 0
    var lookupTimeout: TimeInterval = 25
    var automaticResolver: AvatarResolver?
    @Published var showSourceConsent = false
    @Published var sourceSettingsOnly = false
    @Published var showContactConsent = false
    @Published var lookupIDs: [String] = []
    @Published var showBatchConfirmation = false
    @Published var batchPlan: BatchPlan?
    @Published var batchAllowCreate = false
    @Published var batchGroupBrands = true { didSet { rebuildBatchPlan() } }
    @Published var batchProgress: BatchProgress?
    @Published var undoBatchID: UUID?
    @Published var showBatchIssues = false
    var batchRows: [SenderRow] = []
    var batchWaitingForContacts = false
    var preparingNameFallbacks = false
    var preparingAvatarQuality = false
    @Published var batchMode = false
    @Published var selectedHistoryID: UUID?
    let demo: Bool
    let root: URL
    let apple = AppleContacts()
    let port: ContactStorePort
    let engine: ChangeEngine
    let resolverFactory: () -> AvatarResolver
    private var task: Task<Void, Never>?
    private var migratedCandidatePolicy = false
    var visibleGroupingRevision: UInt64 = 0
    var visibleGroupingCache = VisibleGroupingSnapshot.empty
    // Internal diagnostic used by regression tests to prove that selection does
    // not rebuild the expensive Public Suffix List grouping snapshot.
    var visibleGroupingBuildCount = 0
    var launchError: String?
    var stateURL: URL { root.appendingPathComponent("senders.json") }
    var sectionRows: [SenderRow] {
        rows.filter { row in
            switch section {
            case "ignored": return row.ignored
            case "completed": return row.completed && !row.ignored
            case "existing": return !row.ignored && !row.completed && row.current?.image != nil
            case "recent": return !row.ignored && (row.discoveredAt.map { $0 >= Date().addingTimeInterval(-7*86400) } ?? false)
            case "all": return !row.ignored
            case "ready": return BatchPlanner.isReady(row)
            case "review": return !row.ignored && !row.completed && row.current?.image == nil && !BatchPlanner.isReady(row)
            default: return !row.ignored && !row.completed && row.current?.image == nil
            }
        }
    }
    var visibleRows: [SenderRow] { visibleGroupingSnapshot().rows }
    var selected: SenderRow? {
        guard let selectedID else { return nil }
        return visibleGroupingSnapshot().rowByEmail[selectedID] ?? (pinnedChoiceID == selectedID ? rows.first { $0.id == selectedID } : nil)
    }
    var pendingCount: Int { rows.filter { !$0.ignored && !$0.completed && $0.current?.image == nil }.count }
    var appliedCount: Int { rows.filter { !$0.ignored && $0.completed }.count }
    var existingPhotoCount: Int { rows.filter { !$0.ignored && !$0.completed && $0.current?.image != nil }.count }
    var ignoredCount: Int { rows.filter(\.ignored).count }
    var activeCount: Int { rows.filter { !$0.ignored }.count }
    var sectionTitle: String { ["all": "Senders", "recent": "Recently Added", "pending": "Needs a Photo", "ready": "Ready", "review": "Review", "existing": "Existing Photos", "completed": "Applied", "ignored": "Ignored", "history": "Changes"][section] ?? "Senders" }
    var visibleRecords: [ChangeRecord] { records.filter { record in search.isEmpty || record.email.localizedCaseInsensitiveContains(search) || (rows.first { $0.id == record.email }?.name.localizedCaseInsensitiveContains(search) ?? false) } }
    var selectedHistory: ChangeRecord? { visibleRecords.first { $0.id == selectedHistoryID } ?? visibleRecords.last }
    func reconcileSelection() {
        if section == "history", !visibleRecords.contains(where: { $0.id == selectedHistoryID }) { selectedHistoryID = visibleRecords.last?.id }
        let snapshot = visibleGroupingSnapshot()
        if selectedID.map({ snapshot.emailIDs.contains($0) }) != true { selectedID = snapshot.rows.first?.id }
        selectedForBatch.formIntersection(snapshot.emailIDs)
    }
    func requestLookup(ids: [String], requiresWebsite: Bool = false) {
        guard !busy else { return }
        sourceSettingsOnly = false
        lookupIDs = ids
        if !demo && requiresWebsite && !useWebsite { showSourceConsent = true }
        else if demo || useGravatar || useWebsite || ids.contains(where:{ id in rows.first(where:{ $0.id == id })?.profileURL != nil }) { lookup(ids: ids) }
        else { showSourceConsent = true }
    }

    init(demo: Bool, rootOverride: URL? = nil, resolverFactory: @escaping () -> AvatarResolver = { AvatarResolver() }, mailScanner: (any MailScannerPort)? = nil, contactScanner: (any ContactsScannerPort)? = nil,backgroundWorkAllowed:Bool=true,contactStore:(any ContactStorePort)?=nil) {
        self.backgroundWorkAllowed=backgroundWorkAllowed
        self.resolverFactory = resolverFactory
        self.mailScanner = mailScanner ?? LiveMailScanner()
        self.contactScanner = contactScanner ?? LiveContactsScanner()
        usesLiveMailScan = mailScanner == nil; usesLiveContactScan = contactScanner == nil
        self.demo = demo
        root = rootOverride ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(demo ? "Emblem-Demo" : "Emblem", isDirectory: true)
        if let contactStore {port=contactStore}
        else if demo {
            do { port = try FixtureContactStore(url: root.appendingPathComponent("fixture-contacts.json")) }
            catch { port = try! FixtureContactStore(); launchError = "Demo library could not be read: \(error.localizedDescription)" }
        } else { port = apple }
        engine = ChangeEngine(store: port, journal: FileJournal(url: root.appendingPathComponent("changes.json")))
        do {
            if FileManager.default.fileExists(atPath: stateURL.path) {
                var loadedRows = try JSONDecoder().decode([SenderRow].self, from: Data(contentsOf: stateURL))
                if loadedRows.allSatisfy({$0.discoveryOrder == nil}) {
                    // Legacy storage appended first discoveries. Reverse once, without
                    // inventing timestamps for records whose age was never stored.
                    for i in loadedRows.indices {loadedRows[i].discoveryOrder=i}
                    loadedRows.reverse();migratedCandidatePolicy=true
                }
                // Transform the decoded value before publishing it. Mutating the
                // @Published array once per row otherwise copies an image-bearing
                // library hundreds of times during every launch.
                for rowIndex in loadedRows.indices {
                    let previousSelection = loadedRows[rowIndex].selectedCandidate
                    var candidates: [AvatarCandidate] = []
                    for candidate in loadedRows[rowIndex].candidates {
                        guard !candidate.lowResolution else { migratedCandidatePolicy = true; continue }
                        // Revision 3 images already use the safe-canvas model.
                        // Revision 4 only changes newly fetched declared app icons;
                        // re-rendering every cached image here would stall launch.
                        let layoutRevision = candidate.layoutRevision ?? 0
                        if candidate.source.isBrand && layoutRevision < 3,
                           let updated = try? ImagePipeline.reframeStoredBrand(candidate) {
                            candidates.append(updated); migratedCandidatePolicy = true
                        } else { candidates.append(candidate) }
                    }
                    loadedRows[rowIndex].candidates = candidates
                    if let previousSelection, !candidates.contains(where: { $0.id == previousSelection }) {
                        loadedRows[rowIndex].selectedCandidate = CandidateSelection.automaticChoice(candidates)?.id
                        loadedRows[rowIndex].selectionIsManual = false
                        loadedRows[rowIndex].lookupPolicy = nil
                        loadedRows[rowIndex].status = "Low-resolution photo removed; lookup queued."
                    } else if loadedRows[rowIndex].selectionIsManual != true,
                              let preferred = CandidateSelection.automaticChoice(candidates),
                              loadedRows[rowIndex].selectedCandidate != preferred.id {
                        loadedRows[rowIndex].selectedCandidate = preferred.id
                        loadedRows[rowIndex].selectionIsManual = false
                        // Only rows whose automatic choice actually changed are
                        // queued for a network refresh. This discovers a newer
                        // circle-suitable BIMI asset without rescanning every
                        // already-good sender in a large library.
                        loadedRows[rowIndex].lookupPolicy = nil
                        loadedRows[rowIndex].status = "Updated source preference; lookup queued."
                        migratedCandidatePolicy = true
                    }
                }
                rows=loadedRows
            }
            try loadInboxReceiptOverlay()
            records = try engine.records();recordsFileRevision=try currentChangeJournalRevision()
            try loadBatchResult()
            try loadManagedIdentities();try loadMailSync();try loadGmail()
            if FileManager.default.fileExists(atPath: scanURL.path) {
                scanReport = try JSONDecoder().decode(ScanReport.self, from: Data(contentsOf: scanURL))
                if scanReport?.phase == .running {
                    scanReport?.phase = .stopped; scanReport?.finished = Date()
                    scanReport?.warnings.append("The last import was interrupted. Imported senders are retained and deduplicated on the next check.")
                }
            }
        } catch { launchError = "The library could not be read. Keep the data folder: \(error.localizedDescription)" }
        do { try loadAutomationPreferences() } catch { launchError = "Settings could not be read. Keep the data folder: \(error.localizedDescription)" }
        if rows.allSatisfy({$0.lastInboxReceivedAt == nil}) {automation.lastInbox=nil}
        if demo { contactsConnected = true; accountName = "Demo Contacts (Local Test Files)" }
        if let launchError { errorText = launchError }
        selectedID = visibleGroups.first?.representative.id
        if migratedCandidatePolicy { save() }
        else if FileManager.default.fileExists(atPath:stateURL.path) {
            // The decoded file is already the durable snapshot. Mark its exact
            // revision as saved so an idle foreground close or background pass
            // does not encode and atomically replace every cached image.
            lastSavedRowsRevision=rowsRevision
        }
    }
    var nextDiscoveryOrder:Int {(rows.compactMap(\.discoveryOrder).max() ?? 0)+1}
    func save() {
        guard launchError == nil else { errorText = launchError; return }
        guard lastSavedRowsRevision != rowsRevision else{return}
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // New/test-created rows already have their intended visible order.
            let top=nextDiscoveryOrder+rows.count
            for i in rows.indices where rows[i].discoveryOrder == nil {rows[i].discoveryOrder=top-i}
            try JSONEncoder().encode(rows).write(to: stateURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
            try clearInboxReceiptOverlay()
            lastSavedRowsRevision=rowsRevision
        } catch { errorText = "The library was not saved: \(error.localizedDescription)" }
    }
    func importAddresses(_ text: String, limit: Int? = nil) {
        guard launchError == nil else { errorText = launchError; return }
        let emails = EmailAddress.parseList(text)
        defer { saveAutomationPreferences() }
        var count = 0
        for email in emails.prefix(limit ?? emails.count) where !rows.contains(where: { $0.email == email }) {
            automation.excludedEmails?.remove(email.value)
            rows.insert(SenderRow(email: email, name: email.suggestedDisplayName(in: text),discoveryOrder:nextDiscoveryOrder,discoveredAt:Date()),at:0); count += 1
        }
        if contactsConnected {
            do { try refreshContactMatches() }
            catch { contactsConnected = false; errorText = "Senders were imported, but Contacts refresh failed: \(error.localizedDescription)" }
        }
        section = "all"; selectedID = rows.first { !$0.ignored && !$0.completed }?.id
        message = count == 0 ? "No new addresses. Paste valid emails or check whether they are already in the library." : "Added \(count) senders to the library."
        save()
    }
    func importFromMail() {
        if demo { loadDemo(); return }
        run {
            let senders = try await MailImport.selectedSenders()
            self.acceptMailSenders(senders)
        }
    }
    func acceptMailSenders(_ senders: [String]) {
        mailConnected = true
        lastMailImportCount = senders.count
        guard !senders.isEmpty else {
            message = "Select one or more messages in Apple Mail, then import again."
            errorText = message
            return
        }
        importAddresses(senders.joined(separator: "\n"))
    }
    func refreshContactMatches() throws {
        let duplicateNote = ContactMatchNote.ambiguous
        // Read all matches first, then publish a coherent snapshot. Never write Contacts here.
        let matches = try rows.map { try port.matches(email: $0.email.value) }
        for index in rows.indices {
            rows[index].current = matches[index].count == 1 ? matches[index].first : nil
            rows[index].applicationIssue = nil
            rows[index].notes.removeAll { $0 == duplicateNote }
            if matches[index].count > 1 { rows[index].notes.append(duplicateNote) }
        }
    }
    func connectContacts(resumeApply: Bool = false) {
        run {
            do {
                if !self.demo { try await self.apple.requestAccess(); self.accountName = try self.apple.defaultAccountName() }
                try self.refreshContactMatches()
                self.contactsConnected = true
                self.message = "Contacts connected. Existing photos are preserved; new contacts use \(self.accountName)."
                self.save()
                if resumeApply && self.batchWaitingForContacts { self.resumeBatchAfterContacts() }
                else if resumeApply && !self.pendingIDs.isEmpty { self.allowCreate = false; self.showApplyConfirmation = true }
            } catch {
                self.contactsConnected = false
                throw error
            }
        }
    }
    func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy, !isScanning, discoveryTask == nil, launchError == nil else { return }
        stopAutomaticWork()
        busy = true
        task = Task {
            defer { busy = false; task = nil;kickMailSync() }
            do { try await operation() }
            catch is CancellationError { message = "Stopped. Completed previews are retained." }
            catch { errorText = error.localizedDescription }
        }
    }
    func cancel() { if isScanning { scanStopping = true; scanStage = "Stopping after the current system request…" }; task?.cancel(); if automaticWorking { pauseAutomatic() } }
    func lookup(ids: [String]) {
        guard demo || useGravatar || useWebsite || ids.contains(where:{ id in rows.first(where:{ $0.id == id })?.profileURL != nil }) else { errorText = "Choose photo sources first. Portrait services receive email hashes; websites receive lookup requests."; return }
        let override: URL?
        if !websiteOverride.trimmingCharacters(in: .whitespaces).isEmpty {
            guard ids.count == 1, let url = WebsiteAddress.parse(websiteOverride) else { errorText = "Enter a public HTTPS website for one sender at a time."; return }
            override = url
        } else { override = nil }
        let gravatar = useGravatar, website = useWebsite
        run {
            let resolver = self.resolverFactory()
            for id in ids {
                try Task.checkCancellation()
                guard let index = self.rows.firstIndex(where: { $0.id == id }), !self.rows[index].ignored else { continue }
                let email = self.rows[index].email
                self.rows[index].status = "Finding Photos…"; self.message = "Finding photos for \(email.value)"
                let result: LookupResult
                if self.demo {
                    self.rows[index].candidates = [try DemoImages.candidate(symbol: "envelope.badge", color: .systemBlue)]
                    self.rows[index].notes = ["Demo icons use system symbols, not real identities."]
                } else {
                    let site = override ?? self.rows[index].website.flatMap(WebsiteAddress.parse)
                    result = try await resolver.resolve(email: email, displayName: self.rows[index].name, gravatar: gravatar, website: website, websiteOverride: site, profileURL:self.rows[index].profileURL.flatMap(WebsiteAddress.parse))
                    let pinned = self.rows[index].selectionIsManual == true ? self.rows[index].selectedCandidate : nil
                    let manual = self.rows[index].candidates.filter { $0.source == .manual || $0.id == pinned }
                    self.rows[index].candidates = manual + result.candidates; self.rows[index].notes = result.notes
                    self.rows[index].sourceReports = result.reports; self.rows[index].lastLookup = result.checkedAt
                }
                if self.rows[index].selectionIsManual != true || self.rows[index].chosen == nil {
                    self.rows[index].selectedCandidate = CandidateSelection.automaticChoice(self.rows[index].candidates)?.id
                }
                self.rows[index].status = self.rows[index].candidates.isEmpty ? "No Match" : "\(self.rows[index].candidates.count) photos"
                self.save()
            }
            await self.prepareNameFallbacks()
            self.message = "Photos are ready."
        }
    }
    func configureSources() {
        guard !busy else { return }
        sourceSettingsOnly = true; lookupIDs = selectedID.map { [$0] } ?? []
        showSourceConsent = true
    }
    func setWebsite(_ value: String, for id: String) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].website = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : WebsiteAddress.parse(value)?.absoluteString
        rows[index].lookupPolicy = nil
        save()
    }
    func setProfileURL(_ value:String,for id:String) {
        guard let index=rows.firstIndex(where:{ $0.id == id }) else { return }
        rows[index].profileURL=value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? nil : WebsiteAddress.parse(value)?.absoluteString
        rows[index].lookupPolicy=nil
        save()
    }
    func addCandidate(_ candidate: AvatarCandidate, to id: String) {
        guard !candidate.origin.hasPrefix("contacts://"), !busy, let index = rows.firstIndex(where: { $0.id == id }), (!rows[index].completed || mailSync.enabled), !rows[index].ignored else { return }
        if let existing = rows[index].candidates.first(where: { digest($0.png) == digest(candidate.png) }) { rows[index].selectedCandidate=existing.id }
        else { rows[index].candidates.insert(candidate,at:0); rows[index].selectedCandidate=candidate.id }
        if selectedID == id { pinnedChoiceID = id }
        rows[index].selectionIsManual = true; rows[index].applicationIssue = nil; rows[index].status="Photo Selected"; save();queueChosenPhoto(id)
    }
    func choose(rowID: String, candidateID: UUID) { if let index = rows.firstIndex(where: { $0.id == rowID }) { rows[index].applicationIssue = nil; rows[index].selectedCandidate = candidateID; rows[index].selectionIsManual = true; save();queueChosenPhoto(rowID) } }
    func chooseFile() {
        guard !busy, let rowID=selectedID,rows.contains(where:{$0.id==rowID}) else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg, .tiff, .gif, .svg, .ico]; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url,let index=rows.firstIndex(where:{$0.id==rowID}) {
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 4_000_000 else { throw PortraitError.message("Choose an image smaller than 4 MB.") }
                let candidate = try ImagePipeline.decode(.init(data: Data(contentsOf: url), url: url), source: .manual)
                rows[index].candidates.insert(candidate, at: 0); rows[index].selectedCandidate = candidate.id; rows[index].selectionIsManual = true; rows[index].status = "Local Photo Selected"; save();queueChosenPhoto(rowID)
            } catch { errorText = error.localizedDescription }
        }
    }
    func prepareApply(ids: [String]) {
        guard !busy, !isScanning, discoveryTask == nil else { return }
        stopAutomaticWork() // Freeze the preview the user is about to approve.
        pendingIDs = ids.filter { id in rows.contains { $0.id == id && $0.chosen != nil && !$0.ignored && !$0.completed } }
        guard !pendingIDs.isEmpty else { errorText = "Choose a photo for the sender first."; return }
        guard contactsConnected else { showContactConsent = true; return }
        allowCreate = false; showApplyConfirmation = true
    }
    func prepareApplyGroup(_ group:SenderGroup) {
        guard !busy,!isScanning,discoveryTask == nil,group.members.count > 1,
              let key=ManagedIdentityScope.key(group.representative),group.members.contains(where:{ $0.chosen != nil }) else { return }
        stopAutomaticWork()
        pendingManagedGroupID=key;pendingIDs=group.members.map(\.id);manageFutureAliases=true
        guard contactsConnected else { showContactConsent=true;return }
        allowCreate=false;showApplyConfirmation=true
    }
    func confirmApply() {
        let ids = pendingIDs, create = allowCreate
        let managedKey=pendingManagedGroupID,keepManaging=manageFutureAliases
        showApplyConfirmation = false
        run {
            try await self.ensureContactsAccess()
            defer { self.pendingManagedGroupID=nil }
            if let managedKey {
                let positions=self.rows.indices.filter { ids.contains(self.rows[$0].id) }
                guard let first=positions.first,let candidate=positions.compactMap({ self.rows[$0].chosen }).first else { return }
                do {
                    let record=try self.engine.applyGroup(emails:positions.map { self.rows[$0].email },name:self.rows[first].name,candidate:candidate,allowCreate:create,managedKey:keepManaging ? managedKey : nil)
                    guard let contactID=record.contactID,let contact=try self.port.get(id:contactID) else { throw PortraitError.message("The saved contact could not be verified.") }
                    for index in positions { self.rows[index].current=contact;self.rows[index].completed=true;self.rows[index].status=record.detail }
                    if keepManaging { try self.manageIdentity(key:managedKey,name:self.rows[first].name,contact:contact,emails:positions.map { self.rows[$0].id }) }
                    self.records=try self.engine.records();self.save();self.selectedForBatch.removeAll()
                    self.message="One contact now covers \(positions.count) addresses. \(keepManaging ? "Future matching brand addresses will be added automatically." : "")"
                } catch { self.errorText=error.localizedDescription }
                return
            }
            var successes = 0, failures: [String] = []
            for id in ids {
                try Task.checkCancellation()
                guard let index = self.rows.firstIndex(where: { $0.id == id }), let candidate = self.rows[index].chosen else { continue }
                do {
                    let record = try self.engine.apply(email: self.rows[index].email, name: self.rows[index].name, candidate: candidate, allowCreate: create)
                    self.rows[index].completed = true; self.rows[index].status = record.detail
                    if let contactID = record.contactID { self.rows[index].current = try self.port.get(id: contactID) }
                    successes += 1
                } catch { failures.append("\(id): \(error.localizedDescription)") }
            }
            self.records = try self.engine.records(); self.save(); self.selectedForBatch.removeAll()
            self.message = "Applied \(successes) changes. \(self.demo ? "Only demo files changed." : "Mail may take a moment to refresh. Changes can be undone.")"
            if !failures.isEmpty { self.errorText = failures.joined(separator: "\n\n") }
        }
    }
    func ensureContactsAccess() async throws {
        if !allowsPermissionPrompts && !demo && CNContactStore.authorizationStatus(for:.contacts) != .authorized {throw PortraitError.message("Open Emblem to allow Contacts access.")}
        // UI connection state may predate a revoked grant or a replaced build.
        // Ask the real adapter for current system state on every write/undo.
        guard !demo, let live=port as? AppleContacts else { return }
        do { try await live.requestAccess(); contactsConnected=true }
        catch { contactsConnected=false;throw error }
    }
    func undo(_ record: ChangeRecord) {
        run {
            try await self.ensureContactsAccess()
            try self.engine.undo(id: record.id); self.records = try self.engine.records()
            if let managedKey=record.managedKey {
                // Undo is also an explicit stop signal. Otherwise the next scan
                // could immediately append the same aliases again.
                self.managedIdentities.removeAll { $0.key == managedKey }
                try self.saveManagedIdentities()
                let scoped=self.rows.indices.filter { ManagedIdentityScope.key(self.rows[$0]) == managedKey || self.rows[$0].current?.id == record.contactID }
                for index in scoped {
                    let matches=try self.port.matches(email:self.rows[index].id)
                    self.rows[index].current=matches.count == 1 ? matches.first : nil
                    if record.source == "managed-alias" { self.rows[index].completed=self.rows[index].current?.image != nil }
                    else { self.rows[index].completed=false }
                    self.rows[index].status="Managed Change Undone"
                    if record.created { self.rows[index].ignored=true }
                }
            } else {
                for index in self.rows.indices where self.rows[index].id == record.email || self.rows[index].current?.id == record.contactID {
                self.rows[index].completed = false; self.rows[index].status = "Undone"
                self.rows[index].current = try self.port.matches(email: self.rows[index].id).first
                if record.created { self.rows[index].ignored = true } // Never immediately re-create a deleted contact.
                }
            }
            self.save(); self.message = record.managedKey != nil ? "Managed changes were undone. Future addresses will no longer be added." : record.created ? "The app-created contact was removed and the sender ignored to prevent recreation." : "The photo change was undone. The contact is retained."
        }
    }
    func ignore(_ id: String, ignored: Bool) {
        guard !busy, let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].ignored = ignored; selectedForBatch.remove(id); save()
        message = ignored ? "Ignored in the library. Contacts are unchanged." : "Restored to the library."
    }
    func removeFromList(_ id: String) {
        guard !busy else { return }
        if automation.excludedEmails == nil { automation.excludedEmails = [] }
        automation.excludedEmails?.insert(id); saveAutomationPreferences()
        rows.removeAll { $0.id == id }; selectedForBatch.remove(id); selectedID = visibleGroupingSnapshot().rows.first?.id; save()
        message = "Removed from the library. Contacts and change history are retained."
    }
    /// Wait for cancellation and off-main snapshot encoding before yielding the
    /// writer lease. No background preference is changed by an app update.
    func drainAndSave() async throws {
        isShuttingDown=true
        let pending=[syncTask,automaticTask,discoveryTask,gmailSyncTask,gmailPushMaintenanceTask,gmailPushListenerTask,gmailSignInTask,task].compactMap{$0}
        let sent=gmailSentBootstrapTask
        gmailAuthorization.cancel();stopAutomaticWork();stopGmailPushListening()
        for t in pending {t.cancel()};sent?.cancel()
        for t in pending {await t.value}
        if let sent {_ = try? await sent.value}
        try await saveAsync()
    }
    func loadDemo() {
        guard demo else { return }
        importAddresses("hello@northstar.example\nteam@paperplane.example\nalex@friends.example\nhello@studio.example\nletters@daily.example\nupdates@orbit.example")
        let samples: [String: (String, String, NSColor)] = [
            "hello@northstar.example": ("Northstar", "sparkles", .systemIndigo),
            "team@paperplane.example": ("Paperplane", "paperplane.fill", .systemTeal),
            "alex@friends.example": ("Alex Morgan", "person.fill", .systemOrange),
            "hello@studio.example": ("Studio", "camera.macro", .systemPink),
            "letters@daily.example": ("Daily Notes", "text.book.closed.fill", .systemBrown),
            "updates@orbit.example": ("Orbit", "circle.hexagongrid.fill", .systemBlue)
        ]
        for index in rows.indices where rows[index].candidates.isEmpty {
            let sample = samples[rows[index].id] ?? ("Demo Sender", "envelope.fill", NSColor.systemBlue)
            rows[index].name = sample.0
            if let candidate = try? DemoImages.candidate(symbol: sample.1, color: sample.2) {
                rows[index].candidates = [candidate]
                if let alternate = try? DemoImages.candidate(symbol: sample.1, color: .darkGray) { rows[index].candidates.append(alternate) }
                rows[index].selectedCandidate = candidate.id; rows[index].status = "Photo Found"
            }
        }
        section = "all"; reconcileSelection()
        save()
    }
}

enum DemoImages {
    static func candidate(symbol: String, color: NSColor) throws -> AvatarCandidate {
        let image = NSImage(size: NSSize(width: 512, height: 512), flipped: false) { rect in
            color.setFill(); NSBezierPath(rect: rect).fill()
            let config = NSImage.SymbolConfiguration(pointSize: 230, weight: .regular).applying(.init(paletteColors: [.white]))
            if let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) { icon.draw(in: rect.insetBy(dx: 105, dy: 105)) }
            return true
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { throw PortraitError.message("Demo image rendering failed.") }
        return try ImagePipeline.decode(.init(data: png, url: URL(string: "demo://system-symbol/\(symbol)")!), source: .manual)
    }
}
