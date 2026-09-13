import Foundation
import PortraitCore

struct SenderGroup: Identifiable {
    let id: String
    var members: [SenderRow]
    var representative: SenderRow { members[0] }
    var avatar: Data? { members.compactMap { $0.current?.image ?? $0.chosen?.png }.first }
    var emailIDs: Set<String> { Set(members.map(\.id)) }
}

struct VisibleGroupingSnapshot {
    let revision: UInt64
    let groups: [SenderGroup]
    let rows: [SenderRow]
    let groupIndexByID: [String: Int]
    let groupIndexByEmail: [String: Int]
    let rowByEmail: [String: SenderRow]
    let emailIDs: Set<String>

    static let empty = VisibleGroupingSnapshot(
        revision: .max,
        groups: [], rows: [],
        groupIndexByID: [:], groupIndexByEmail: [:], rowByEmail: [:], emailIDs: []
    )
}

enum SenderGrouping {
    static func normalizedName(_ row: SenderRow) -> String {
        row.name.split(whereSeparator: \.isWhitespace).joined(separator:" ").lowercased()
    }
    static func hasPersonEvidence(_ row: SenderRow) -> Bool {
        if let current = row.current, current.image != nil,
           current.name.split(whereSeparator: \.isWhitespace).joined(separator:" ").lowercased() == normalizedName(row) { return true }
        return row.candidates.contains { [.gravatar, .libravatar, .profile, .institutionProfile].contains($0.source) && $0.recommendedAutomatically }
    }
    static func emailLooksCompatibleWithPersonName(_ row: SenderRow) -> Bool {
        let words = normalizedName(row).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 2 }
        guard words.count >= 2 && words.count <= 5 else { return false }
        let local = row.id.split(separator:"@").first.map(String.init)?.lowercased() ?? ""
        let tokens = Set(local.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        return Set(words).isSubset(of: tokens)
    }
    static func crossDomainPersonNames(_ rows: [SenderRow]) -> Set<String> {
        let buckets = Dictionary(grouping: rows, by: normalizedName)
        return Set(buckets.compactMap { name, members in
            guard !name.isEmpty,
                  Set(members.map { DomainRouting.primaryHost(for: $0.email.domain) }).count > 1,
                  members.contains(where: hasPersonEvidence),
                  members.allSatisfy(emailLooksCompatibleWithPersonName) else { return nil }
            return name
        })
    }
    static func key(_ row: SenderRow, crossDomainPeople: Set<String> = []) -> String {
        let name = row.name.split(whereSeparator: \.isWhitespace).joined(separator:" ").lowercased()
        let local = row.id.split(separator:"@").first.map(String.init) ?? ""
        if crossDomainPeople.contains(name) { return "person|" + name }
        if let contact = row.current { return "contact|" + contact.id }
        if InstitutionalProfilePolicy.keepsMailboxIndependent(row.email) { return "email|" + row.id }
        // Display grouping only. Existing contacts and shared mail providers keep
        // independent identities. A name alone is never a cross-domain match.
        guard !row.email.isSharedProvider, !name.isEmpty,
              name != row.id, name != local, !name.contains("@") else { return "email|" + row.id }
        let domain = DomainRouting.primaryHost(for:row.email.domain)
        var site = URLComponents(string:row.website ?? "https://" + domain + "/")
        let host = site?.host?.lowercased()
        site?.host = host
        if site?.path.isEmpty == true { site?.path = "/" }
        if site?.port == 443 { site?.port = nil }
        return "name|" + name + "|" + domain + "|" + (site?.string ?? row.website ?? "") + "|" + (row.profileURL ?? "")
    }
    static func groups(_ rows: [SenderRow]) -> [SenderGroup] {
        let crossDomainPeople = crossDomainPersonNames(rows)
        var result: [SenderGroup] = [], indices: [String:Int] = [:]
        // Receipt time is independent of scanning/discovery order. A group is
        // positioned by its newest inbox message, with stable order for ties.
        let ordered = rows.enumerated().sorted { a,b in
            let left=a.element.lastInboxReceivedAt ?? .distantPast,right=b.element.lastInboxReceivedAt ?? .distantPast
            return left == right ? a.offset < b.offset : left > right
        }.map(\.element)
        for row in ordered {
            let key = key(row, crossDomainPeople: crossDomainPeople)
            if let index = indices[key] { result[index].members.append(row) }
            else { indices[key] = result.count; result.append(.init(id:key,members:[row])) }
        }
        return result
    }
}

extension AppModel {
    func invalidateVisibleGrouping() {
        visibleGroupingRevision &+= 1
    }

    func visibleGroupingSnapshot() -> VisibleGroupingSnapshot {
        if visibleGroupingCache.revision == visibleGroupingRevision { return visibleGroupingCache }

        // Search any alias, but retain all members of the matching display group.
        let groups = SenderGrouping.groups(sectionRows).filter { group in
            search.isEmpty || group.members.contains { $0.id.localizedCaseInsensitiveContains(search) || $0.displayName.localizedCaseInsensitiveContains(search) || $0.name.localizedCaseInsensitiveContains(search) }
        }
        let rows = groups.flatMap(\.members)
        var groupIndexByID: [String: Int] = [:]
        var groupIndexByEmail: [String: Int] = [:]
        var rowByEmail: [String: SenderRow] = [:]
        for (groupIndex, group) in groups.enumerated() {
            groupIndexByID[group.id] = groupIndex
            for row in group.members {
                groupIndexByEmail[row.id] = groupIndex
                rowByEmail[row.id] = row
            }
        }
        visibleGroupingBuildCount += 1
        visibleGroupingCache = VisibleGroupingSnapshot(
            revision: visibleGroupingRevision,
            groups: groups, rows: rows,
            groupIndexByID: groupIndexByID,
            groupIndexByEmail: groupIndexByEmail,
            rowByEmail: rowByEmail,
            emailIDs: Set(rowByEmail.keys)
        )
        return visibleGroupingCache
    }

    /// Candidate/status changes should refresh visible row values without
    /// recalculating Public Suffix grouping for the entire mailbox. Callers use
    /// this only when ids, names, contact ids, websites and section membership
    /// are unchanged.
    func replaceRowsPreservingGrouping(_ replacement: [SenderRow], changedIDs: Set<String>) {
        guard !(section == "ready" || section == "review"), replacement.count == rows.count,
              zip(replacement, rows).allSatisfy({ pair in pair.0.id == pair.1.id }) else {
            rows = replacement
            return
        }
        preserveVisibleGroupingOnRowsChange = true
        rows = replacement
        preserveVisibleGroupingOnRowsChange = false
        guard visibleGroupingCache.revision == visibleGroupingRevision, !changedIDs.isEmpty else { return }
        let updates = Dictionary(uniqueKeysWithValues: replacement.lazy.filter { changedIDs.contains($0.id) }.map { ($0.id, $0) })
        let groups = visibleGroupingCache.groups.map { group in
            SenderGroup(id: group.id, members: group.members.map { updates[$0.id] ?? $0 })
        }
        let flatRows = visibleGroupingCache.rows.map { updates[$0.id] ?? $0 }
        var rowByEmail = visibleGroupingCache.rowByEmail
        for (id, row) in updates where rowByEmail[id] != nil { rowByEmail[id] = row }
        visibleGroupingCache = VisibleGroupingSnapshot(
            revision: visibleGroupingCache.revision,
            groups: groups,
            rows: flatRows,
            groupIndexByID: visibleGroupingCache.groupIndexByID,
            groupIndexByEmail: visibleGroupingCache.groupIndexByEmail,
            rowByEmail: rowByEmail,
            emailIDs: visibleGroupingCache.emailIDs
        )
    }

    var visibleGroups: [SenderGroup] { visibleGroupingSnapshot().groups }
    var visibleEmailCount: Int { visibleGroupingSnapshot().rows.count }
    var senderListFooterSummary: String {
        search.isEmpty
            ? "\(visibleGroups.count) groups · \(visibleEmailCount) addresses"
            : "Filtered: \(visibleGroups.count) groups · \(visibleEmailCount) addresses"
    }
    func clearSenderSearch() { search = "" }
    var selectedGroup: SenderGroup? {
        guard let selectedID else { return nil }
        let snapshot = visibleGroupingSnapshot()
        guard let index = snapshot.groupIndexByEmail[selectedID] else { return nil }
        return snapshot.groups[index]
    }
    var selectedListID: String? {
        get {
            guard let selectedID else { return nil }
            let snapshot = visibleGroupingSnapshot()
            return snapshot.groupIndexByEmail[selectedID].map { snapshot.groups[$0].id }
        }
        set {
            let snapshot = visibleGroupingSnapshot()
            if let newValue, let index = snapshot.groupIndexByID[newValue] {
                let group = snapshot.groups[index]
                if !group.emailIDs.contains(selectedID ?? "") { selectedID = group.representative.id }
            }
        }
    }
    func selectGroup(_ group: SenderGroup, enabled: Bool) {
        if enabled { selectedForBatch.formUnion(group.emailIDs) }
        else { selectedForBatch.subtract(group.emailIDs) }
    }
    func ignoreGroup(_ group: SenderGroup) {
        guard !busy else { return }
        let ids = group.emailIDs, ignored = !group.representative.ignored
        for index in rows.indices where ids.contains(rows[index].id) { rows[index].ignored = ignored }
        save(); reconcileSelection()
    }
    func removeGroup(_ group: SenderGroup) {
        guard !busy else { return }
        let ids = group.emailIDs
        automation.excludedEmails = (automation.excludedEmails ?? []).union(ids)
        rows.removeAll { ids.contains($0.id) }
        save(); saveAutomationPreferences(); reconcileSelection()
    }
}
