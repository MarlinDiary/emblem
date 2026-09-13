import Foundation
import PortraitCore

struct BatchIssue: Identifiable, Codable {
    let id: String
    let reason: String
}
struct BatchJob: Identifiable {
    let id: String
    let rows: [SenderRow]
    let candidate: AvatarCandidate
    var existing: ContactSnapshot? { rows.compactMap(\.current).first }
    var createsContact: Bool { existing == nil }
    var name: String { existing?.name ?? rows[0].name }
}
struct BatchPlan {
    let jobs: [BatchJob]
    let excluded: [BatchIssue]
    var emailCount: Int { jobs.reduce(0) { $0 + $1.rows.count } }
    var newContactCount: Int { jobs.filter(\.createsContact).count }
    var updateCount: Int { jobs.count - newContactCount }
}
struct BatchProgress: Codable {
    var batchID: UUID? = nil
    let total: Int
    var processed = 0
    var succeeded = 0
    var issues: [BatchIssue] = []
    var cancelled = false
    var finished = false
    var undoing = false
    var title: String {
        if !finished { return "\(undoing ? "Undoing" : "Applying") \(processed) / \(total)" }
        return "\(cancelled ? "Stopped · " : "")\(undoing ? "Undone" : "Applied") \(succeeded) contacts\(issues.isEmpty ? "" : " · \(issues.count) need review")"
    }
}

enum BatchPlanner {
    static func reviewReason(_ row: SenderRow) -> String? {
        if row.ignored { return "Ignored" }
        if row.completed { return "Applied" }
        if row.current?.image != nil { return "Keep existing contact photo" }
        if let issue = row.applicationIssue { return issue }
        if row.notes.contains(where: { ContactMatchNote.isAmbiguous($0) }) { return "Email matches multiple contacts" }
        guard let image = row.chosen else { return "No matching photo yet" }
        if image.lowResolution { return "Image resolution is too low" }
        if row.selectionIsManual == true { return nil }
        if !image.recommendedAutomatically { return "Image framing needs review" }
        if image.source == .domainIcon { return "Third-party icon needs review" }
        return nil
    }
    static func isReady(_ row: SenderRow) -> Bool { reviewReason(row) == nil }
    static func brandKey(_ row: SenderRow) -> String? {
        guard row.current == nil, row.chosen?.source.isBrand == true,
              !InstitutionalProfilePolicy.keepsMailboxIndependent(row.email),
              !row.email.domain.hasSuffix(".edu"), !row.email.domain.contains(".edu."), !row.email.domain.contains(".ac."),
              InstitutionalProfilePolicy.normalizedPersonName(row.name) == nil,
              !SenderGrouping.hasPersonEvidence(row), !SenderGrouping.emailLooksCompatibleWithPersonName(row),
              ManagedIdentityScope.key(row) != nil else { return nil }
        // Same name, registered domain, declared website/profile AND exact image.
        // A display-only person group never grants permission to merge cards.
        return SenderGrouping.key(row) + "|" + digest(row.chosen?.png)
    }
    static func plan(_ rows: [SenderRow], groupBrands: Bool = true) -> BatchPlan {
        var excluded: [BatchIssue] = [], buckets: [[SenderRow]] = [], index: [String:Int] = [:]
        var seen = Set<String>()
        for row in rows where seen.insert(row.id).inserted {
            if let reason = reviewReason(row) { excluded.append(.init(id: row.id, reason: reason)); continue }
            let key: String
            if let contact = row.current { key = "contact|" + contact.id }
            else { key = (groupBrands ? brandKey(row) : nil) ?? "email|" + row.id }
            if let i = index[key] { buckets[i].append(row) }
            else { index[key] = buckets.count; buckets.append([row]) }
        }
        var jobs: [BatchJob] = []
        for members in buckets {
            guard let first = members.first, let candidate = first.chosen else { continue }
            guard Set(members.map { digest($0.chosen?.png) }).count == 1 else {
                excluded += members.map { .init(id: $0.id, reason: "Different photos were selected for the same contact. Choose one photo first.") }; continue
            }
            jobs.append(.init(id: first.id, rows: members, candidate: candidate))
        }
        return .init(jobs: jobs, excluded: excluded)
    }
}

extension AppModel {
    var batchResultURL: URL { root.appendingPathComponent("batch-result.json") }
    func loadBatchResult() throws {
        if FileManager.default.fileExists(atPath: batchResultURL.path) {
            batchProgress = try JSONDecoder().decode(BatchProgress.self, from: Data(contentsOf: batchResultURL))
        }
        // Recover UI state from the per-card journal if the app closed after a
        // Contacts write but before saving the large sender cache.
        var recovered = rows
        for record in records where record.batchID != nil && (record.state == .applied || record.state == .undone) {
            let affected = Set(record.affectedEmails ?? [record.email])
            for i in recovered.indices where affected.contains(recovered[i].id) || recovered[i].current?.id == record.contactID {
                recovered[i].completed = record.state == .applied
                if record.state == .undone {
                    if record.created { recovered[i].ignored = true; recovered[i].current = nil }
                    else { recovered[i].current?.image = record.beforeImage }
                } else if recovered[i].current == nil, let contactID = record.contactID {
                    recovered[i].current = ContactSnapshot(id: contactID, name: recovered[i].name, emails: Array(affected).sorted(), image: recovered[i].chosen?.png)
                }
            }
        }
        rows = recovered
    }
    var readyCount: Int { rows.filter(BatchPlanner.isReady).count }
    var reviewCount: Int { pendingCount - readyCount }
    var batchScopeIDs: [String] {
        let visible = visibleRows
        return (batchMode ? visible.filter { selectedForBatch.contains($0.id) } : visible).filter(BatchPlanner.isReady).map(\.id)
    }
    var batchEnabledJobs: [BatchJob] { batchPlan?.jobs.filter { batchAllowCreate || !$0.createsContact } ?? [] }
    var latestBatchID: UUID? { records.last { $0.batchID != nil && $0.state == .applied }?.batchID }
    func prepareBatch(ids: [String]) {
        guard !busy, !isScanning, discoveryTask == nil, launchError == nil else { return }
        stopAutomaticWork()
        let scope = Set(ids)
        batchRows = rows.filter { scope.contains($0.id) }
        batchGroupBrands = true; batchAllowCreate = false
        rebuildBatchPlan()
        let conflicts = batchPlan?.excluded.filter { $0.reason.contains("Different photos were selected for the same contact") || $0.reason.contains("同一联系人选了不同头像") } ?? []
        if !conflicts.isEmpty {
            var updated = rows
            for issue in conflicts { if let i = updated.firstIndex(where: { $0.id == issue.id }) { updated[i].applicationIssue = issue.reason } }
            rows = updated
        }
        guard batchPlan?.jobs.isEmpty == false else { message = "No photos are ready in this selection. Unresolved senders remain in your library."; return }
        guard contactsConnected else { batchWaitingForContacts = true; showContactConsent = true; return }
        showBatchConfirmation = true
    }
    func rebuildBatchPlan() { batchPlan = BatchPlanner.plan(batchRows, groupBrands: batchGroupBrands) }
    func resumeBatchAfterContacts() {
        batchWaitingForContacts = false
        let ids = Set(batchRows.map(\.id)); batchRows = rows.filter { ids.contains($0.id) }
        rebuildBatchPlan(); showBatchConfirmation = true
    }
    func confirmBatch() {
        let jobs = batchEnabledJobs
        guard !jobs.isEmpty, !busy, !isScanning, discoveryTask == nil, showBatchConfirmation else { return }
        let batchID = UUID(), create = batchAllowCreate
        showBatchConfirmation = false
        run {
            try await self.ensureContactsAccess()
            self.batchProgress = .init(batchID: batchID, total: jobs.count)
            defer { self.finishBatch() }
            for job in jobs {
                if Task.isCancelled { self.batchProgress?.cancelled = true; break }
                do {
                    // Re-read immediately before each write. A new match or photo
                    // after confirmation is a conflict, not implicit new approval.
                    for (offset, row) in job.rows.enumerated() {
                        if offset % 16 == 0 { await Task.yield(); try Task.checkCancellation() }
                        let live = try self.port.matches(email: row.id)
                        guard live.count <= 1, live.first == row.current, live.first?.image == nil else {
                            throw PortraitError.message("Contacts changed. The current version is preserved; review it again.")
                        }
                    }
                    let record: ChangeRecord
                    if job.rows.count > 1 && job.createsContact {
                        record = try self.engine.applyGroup(emails: job.rows.map(\.email), name: job.name, candidate: job.candidate, allowCreate: create, managedKey: nil, batchID: batchID)
                    } else {
                        record = try self.engine.apply(email: job.rows[0].email, name: job.name, candidate: job.candidate, allowCreate: create, batchID: batchID)
                    }
                    guard let contactID = record.contactID, let contact = try self.port.get(id: contactID) else { throw PortraitError.message("The saved contact needs verification.") }
                    let ids = Set(job.rows.map(\.id))
                    var updated = self.rows
                    for i in updated.indices where ids.contains(updated[i].id) || updated[i].current?.id == contactID {
                        updated[i].current = contact; updated[i].completed = true; updated[i].status = record.detail
                    }
                    self.rows = updated; self.records.append(record)
                    self.batchProgress?.succeeded += 1
                } catch is CancellationError {
                    self.batchProgress?.cancelled = true; break
                } catch {
                    self.batchProgress?.issues.append(.init(id: job.id, reason: error.localizedDescription))
                    let ids = Set(job.rows.map(\.id))
                    var updated = self.rows
                    for i in updated.indices where ids.contains(updated[i].id) { updated[i].applicationIssue = error.localizedDescription }
                    self.rows = updated
                }
                self.batchProgress?.processed += 1
                // Core write-ahead journal persists every card with a batch ID.
                // Yield between system calls so scrolling and Stop remain usable.
                try? await Task.sleep(nanoseconds: 4_000_000)
            }
        }
    }
    func finishBatch() {
        do { records = try engine.records() } catch { errorText = error.localizedDescription }
        save(); selectedForBatch.removeAll(); batchMode = false
        batchProgress?.finished = true
        message = batchProgress?.title ?? "Finished"
        if let batchProgress {
            do {
                try JSONEncoder().encode(batchProgress).write(to: batchResultURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: batchResultURL.path)
            } catch { errorText = "Batch summary was not saved: \(error.localizedDescription); individual change records are retained." }
        }
        reconcileSelection()
    }
    func undoBatch(_ id: UUID) {
        let entries = records.filter { $0.batchID == id && $0.state == .applied }.reversed()
        guard !entries.isEmpty else { return }
        run {
            self.batchProgress = .init(batchID: id, total: entries.count, undoing: true)
            defer { self.finishBatch() }
            try await self.ensureContactsAccess()
            for record in entries {
                if Task.isCancelled { self.batchProgress?.cancelled = true; break }
                do {
                    try self.engine.undo(id: record.id)
                    var updated = self.rows
                    for i in updated.indices where updated[i].current?.id == record.contactID || updated[i].id == record.email {
                        let matches = try self.port.matches(email: updated[i].id)
                        updated[i].current = matches.count == 1 ? matches.first : nil
                        updated[i].completed = false; updated[i].status = "Undone"
                        if record.created { updated[i].ignored = true }
                    }
                    self.rows = updated; self.batchProgress?.succeeded += 1
                } catch { self.batchProgress?.issues.append(.init(id: record.email, reason: error.localizedDescription)) }
                self.batchProgress?.processed += 1
                try? await Task.sleep(nanoseconds: 4_000_000)
            }
        }
    }
}
