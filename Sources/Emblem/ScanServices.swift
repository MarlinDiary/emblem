import AppKit
import Contacts
import Carbon
import PortraitCore

// Mail and Contacts only supply local preview data. None of these APIs save contacts.
enum ScanSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case inbox, allMail, contacts
    var id: String { rawValue }
    var title: String { switch self { case .inbox: return "Apple Mail · All Inboxes"; case .allMail: return "Apple Mail · All Mailboxes"; case .contacts: return "Contacts" } }
    var unit: String { self == .contacts ? "contacts" : "messages" }
}
enum ScanPhase: String, Codable, Sendable { case running, completed, partial, stopped, failed }
struct ScanReport: Codable, Sendable, Identifiable {
    var id = UUID()
    var source: ScanSource
    var started = Date()
    var finished: Date?
    var phase = ScanPhase.running
    var examined = 0
    var total: Int?
    var added = 0
    var existing = 0
    var invalid = 0
    var withoutEmail = 0
    var duplicateEntries = 0
    var mailboxes = 0
    var completedMailboxes = 0
    var warnings: [String] = []
    var unique: Int { added + existing }
    var resultText: String {
        let end: String = switch phase { case .running: "Importing"; case .completed: "Import Complete"; case .partial: "Partially Complete"; case .stopped: "Stopped"; case .failed: "Import Incomplete" }
        return "\(end) · \(examined) \(source.unit) checked, \(added) added, \(existing) already in the library."
    }
}
struct MailScanMailbox: Sendable, Hashable {
    var account: String
    var path: [String]
    var label: String
    var count: Int
    var reference: Int = 0
}
struct MailScanInventory: Sendable { var mailboxes: [MailScanMailbox]; var warnings: [String] }
struct MailScanPage: Sendable { var senders: [String]; var currentCount: Int; var unreadable: Int = 0; var receivedAt:[Date?] = [] }
protocol MailScannerPort: Sendable {
    func recentInbox(since:Date) async throws -> MailScanPage?
    func recentInbox(since:Date,excludingAccountEmails:Set<String>) async throws -> MailScanPage?
    func inventory(source:ScanSource,excludingAccountEmails:Set<String>) async throws -> MailScanInventory
    func inventory(source: ScanSource) async throws -> MailScanInventory
    func page(mailbox: MailScanMailbox, start: Int, size: Int) async throws -> MailScanPage
}
extension MailScannerPort {
    func recentInbox(since:Date,excludingAccountEmails:Set<String>)async throws->MailScanPage? {
        // Older adapters cannot scope accounts: keep their original path, which
        // is lossless and deduplicated at sender ingestion.
        try await recentInbox(since:since)
    }
    func inventory(source:ScanSource,excludingAccountEmails:Set<String>)async throws->MailScanInventory {
        try await inventory(source:source)
    }
    func recentInbox(since:Date) async throws -> MailScanPage? {nil}
}
protocol ContactsScannerPort: Sendable {
    func batches() -> AsyncThrowingStream<[ContactSnapshot], Error>
}

struct LiveContactsScanner: ContactsScannerPort {
    func batches() -> AsyncThrowingStream<[ContactSnapshot], Error> {
        AsyncThrowingStream { continuation in
            let worker = Task.detached(priority: .userInitiated) {
                do {
                    guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
                        throw PortraitError.message("Allow full Contacts access, then import again.")
                    }
                    let store = CNContactStore()
                    let keys = [CNContactIdentifierKey, CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey, CNContactEmailAddressesKey, CNContactThumbnailImageDataKey] as [CNKeyDescriptor]
                    let request = CNContactFetchRequest(keysToFetch: keys)
                    request.unifyResults = false // Keep duplicate raw cards visible to the write guard.
                    var batch: [ContactSnapshot] = []
                    try store.enumerateContacts(with: request) { contact, stop in
                        if Task.isCancelled { stop.pointee = true; return }
                        let personalName = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                        batch.append(.init(id: contact.identifier, name: personalName.isEmpty ? contact.organizationName : personalName,
                                           emails: contact.emailAddresses.map { $0.value as String }, image: contact.thumbnailImageData))
                        if batch.count == 100 { continuation.yield(batch); batch.removeAll(keepingCapacity: true) }
                    }
                    try Task.checkCancellation()
                    if !batch.isEmpty { continuation.yield(batch) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in worker.cancel() }
        }
    }
}

// Typed Apple-event parameters keep mailbox/account strings out of executable script source.
indirect enum ScriptValue: Codable, Sendable {
    case text(String), number(Int), list([ScriptValue]), date(Date)
    var descriptor: NSAppleEventDescriptor {
        switch self {
        case .date(let value): return NSAppleEventDescriptor(date:value)
        case .text(let value): return NSAppleEventDescriptor(string: value)
        case .number(let value): return NSAppleEventDescriptor(int32: Int32(clamping: value))
        case .list(let values):
            let result = NSAppleEventDescriptor.list()
            for (index, value) in values.enumerated() { result.insert(value.descriptor, at: index + 1) }
            return result
        }
    }
    static func read(_ descriptor: NSAppleEventDescriptor) -> ScriptValue {
        if descriptor.descriptorType == typeLongDateTime,let date=descriptor.dateValue {return .date(date)}
        if descriptor.descriptorType == typeAEList {
            return .list((0..<descriptor.numberOfItems).compactMap { descriptor.atIndex($0 + 1) }.map(read))
        }
        if descriptor.descriptorType == typeSInt32 || descriptor.descriptorType == typeSInt64 { return .number(Int(descriptor.int32Value)) }
        return .text(descriptor.stringValue ?? "")
    }
    var values: [ScriptValue] { if case .list(let v) = self { return v }; return [] }
    var string: String { if case .text(let v) = self { return v }; return "" }
    var date:Date? {if case .date(let date)=self{return date};return nil}
    var integer: Int { if case .number(let v) = self { return v }; return Int(string) ?? 0 }
}

struct LiveMailScanner: MailScannerPort {
    func recentInbox(since:Date)async throws->MailScanPage? {
        try await recentInbox(since:since,excludingAccountEmails:[])
    }
    func recentInbox(since:Date,excludingAccountEmails:Set<String>)async throws->MailScanPage? {
        let routed = !excludingAccountEmails.isEmpty
        let result=try await MailScanScriptRunner.shared.call(routed ? "scanroutedrecent":"scanrecent",arguments:[.date(since)] + (routed ? [.list(excludingAccountEmails.sorted().map{.text($0)})]:[]))
        let values=result.values
        guard values.count==4 else{throw PortraitError.message("Mail returned incomplete incremental data.")}
        let senders=values[0].values.map(\.string)
        guard senders.count==values[1].integer else{return nil} // Large catch-up uses the full paging path.
        return .init(senders:senders,currentCount:values[1].integer,unreadable:values[2].integer,receivedAt:values[3].values.map(\.date))
    }

    func inventory(source: ScanSource) async throws -> MailScanInventory {
        try await inventory(source:source,excludingAccountEmails:[])
    }
    func inventory(source:ScanSource,excludingAccountEmails:Set<String>)async throws->MailScanInventory {
        let routed = !excludingAccountEmails.isEmpty
        let result = try await MailScanScriptRunner.shared.call(routed ? "scanroutedinventory":"scaninventory", arguments: [.text(source.rawValue)] + (routed ? [.list(excludingAccountEmails.sorted().map{.text($0)})]:[]))
        let parts = result.values
        guard parts.count == 2 else { throw PortraitError.message("Mail returned an unexpected mailbox list.") }
        var seen = Set<String>(), boxes: [MailScanMailbox] = []
        for entry in parts[0].values {
            let v = entry.values
            guard v.count == 5 else { throw PortraitError.message("Mail returned incomplete mailbox data.") }
            let path = v[1].values.map(\.string), key = v[0].string + "\u{0}" + path.joined(separator: "\u{0}")
            if seen.insert(key).inserted { boxes.append(.init(account:v[0].string,path:path,label:v[2].string,count:max(0,v[3].integer),reference:v[4].integer)) }
        }
        return .init(mailboxes: boxes, warnings: parts[1].values.map(\.string))
    }
    func page(mailbox: MailScanMailbox, start: Int, size: Int) async throws -> MailScanPage {
        guard start >= 1, size > 0, size <= 200 else { throw PortraitError.message("The scan page range is invalid.") }
        let result = try await MailScanScriptRunner.shared.call("scanpageat", arguments: [.text(mailbox.account), .list(mailbox.path.map{.text($0)}), .number(start), .number(size)])
        let values = result.values
        guard values.count == 4 else { throw PortraitError.message("Mail returned an unexpected page format.") }
        let senders: [String]
        if case .list(let entries) = values[0] { senders = entries.map(\.string) }
        else { senders = values[0].string.isEmpty ? [] : [values[0].string] }
        return .init(senders:senders,currentCount:values[1].integer,unreadable:values[2].integer,receivedAt:values[3].values.map(\.date))
    }
}

enum MailScanScripts {
    // Only account/mailbox labels, counts, message IDs, sender and received dates are read. No body, subject,
    // attachments, credentials, message source, or read-status mutation.
    static let source = #"""
    property scanReferences : {}
    on scanInventory(scanKind)
        return my scanRoutedInventory(scanKind, {})
    end scanInventory
    on scanAccounts()
        with timeout of 15 seconds
            tell application "Mail"
                set resultRows to {}
                repeat with acct in accounts
                    if enabled of acct then set end of resultRows to {id of acct, email addresses of acct}
                end repeat
                return resultRows
            end tell
        end timeout
    end scanAccounts
    on accountUsesGmail(acct, primaryEmails)
        tell application "Mail"
            try
                set addresses to email addresses of acct
                repeat with addressValue in addresses
                    ignoring case
                        if primaryEmails contains (addressValue as text) then return true
                    end ignoring
                end repeat
            end try
        end tell
        return false
    end accountUsesGmail
    on scanRoutedInventory(scanKind, primaryEmails)
        set my scanReferences to {}
        with timeout of 30 seconds
            tell application "Mail"
                if scanKind is "inbox" and (count of primaryEmails) is 0 then
                    set my scanReferences to {inbox}
                    return {{{"@inbox", {}, "All Inboxes", count of messages of inbox, 1}}, {}}
                end if
                set resultRows to {}
                set problems to {}
                repeat with acct in accounts
                    if enabled of acct and not my accountUsesGmail(acct, primaryEmails) then
                        set acctKey to id of acct
                        set acctLabel to name of acct
                        try
                            if scanKind is "inbox" then
                                -- IMAP's INBOX is case-insensitive, including Google
                                -- Workspace and Exchange's Inbox. Fail visibly if an
                                -- unusual account does not expose this mailbox.
                                set boxRef to mailbox "INBOX" of acct
                                set end of resultRows to {acctKey, {name of boxRef}, acctLabel & " · Inbox", count of messages of boxRef, 0}
                            else
                                repeat with boxRef in mailboxes of acct
                                    set walked to my walkBox(contents of boxRef, acctKey, acctLabel, {}, 0)
                                    set resultRows to resultRows & item 1 of walked
                                    set problems to problems & item 2 of walked
                                end repeat
                            end if
                        on error errText number errNo
                            set end of problems to "Account import incomplete (" & errNo & "): " & acctLabel
                        end try
                    end if
                end repeat
                if scanKind is "inbox" then return {resultRows, problems}
                repeat with boxRef in mailboxes
                    set localBox to false
                    try
                        set owningAccount to account of boxRef
                        if owningAccount is missing value then set localBox to true
                    on error
                        set localBox to true
                    end try
                    if localBox then
                        set walked to my walkBox(contents of boxRef, "@local", "On My Mac", {}, 0)
                        set resultRows to resultRows & item 1 of walked
                        set problems to problems & item 2 of walked
                    end if
                end repeat
                return {resultRows, problems}
            end tell
        end timeout
    end scanRoutedInventory
    on walkBox(boxRef, acctKey, acctLabel, ancestors, depth)
        tell application "Mail"
            set rowsFound to {}
            set problems to {}
            try
                set boxName to name of boxRef
                set boxPath to ancestors & {boxName}
                set itemCount to count of messages of boxRef
                set storedBoxes to my scanReferences
                set end of storedBoxes to boxRef
                set my scanReferences to storedBoxes
                set end of rowsFound to {acctKey, boxPath, acctLabel & " · " & boxName, itemCount, count of storedBoxes}
                if depth >= 32 then
                    set end of problems to "Mailbox nesting exceeds 32 levels: " & boxName
                else
                    repeat with childBox in mailboxes of boxRef
                        set childResult to my walkBox(contents of childBox, acctKey, acctLabel, boxPath, depth + 1)
                        set rowsFound to rowsFound & item 1 of childResult
                        set problems to problems & item 2 of childResult
                    end repeat
                end if
            on error errText number errNo
                set end of problems to "Mailbox information incomplete (" & errNo & "): " & acctLabel
            end try
            return {rowsFound, problems}
        end tell
    end walkBox
    on scanRecent(sinceDate)
        return my scanRoutedRecent(sinceDate, {})
    end scanRecent
    on scanRoutedRecent(sinceDate, primaryEmails)
        set pageDeadline to (current date) + 15
        with timeout of 15 seconds
            tell application "Mail"
                if (count of primaryEmails) is 0 then
                    set recentMessages to (messages of inbox whose date received is greater than or equal to sinceDate)
                else
                    set recentMessages to {}
                    repeat with acct in accounts
                        if enabled of acct and not my accountUsesGmail(acct, primaryEmails) then
                            set targetBox to mailbox "INBOX" of acct
                            set recentMessages to recentMessages & (messages of targetBox whose date received is greater than or equal to sinceDate)
                        end if
                    end repeat
                end if
                set totalCount to count of recentMessages
                if totalCount > 200 then return {{}, totalCount, 0, {}}
                set fromFields to {}
                set dateFields to {}
                set unreadableCount to 0
                repeat with messageRef in recentMessages
                    if (current date) >= pageDeadline then error "Mail recent page exceeded time budget" number -1712
                    try
                        set fromField to sender of messageRef
                        set receivedField to date received of messageRef
                        if fromField is missing value then error "Sender missing" number -1728
                        set end of fromFields to fromField
                        set end of dateFields to receivedField
                    on error
                        set end of fromFields to ""
                        set end of dateFields to missing value
                        set unreadableCount to unreadableCount + 1
                    end try
                end repeat
                return {fromFields, totalCount, unreadableCount, dateFields}
            end tell
        end timeout
    end scanRoutedRecent
    on scanPageAt(acctKey, pathParts, firstIndex, pageSize)
        with timeout of 15 seconds
            tell application "Mail"
                if acctKey is "@inbox" then
                    set targetBox to inbox
                else
                    if (count of pathParts) is 0 then error "Missing mailbox path" number -1728
                    set firstName to item 1 of pathParts
                    if acctKey is "@local" then
                        set targetBox to mailbox firstName
                    else
                        set targetAccount to first account whose id is acctKey
                        set targetBox to mailbox firstName of targetAccount
                    end if
                    repeat with partIndex from 2 to count of pathParts
                        set childName to item partIndex of pathParts
                        set targetBox to mailbox childName of targetBox
                    end repeat
                end if
                set my scanReferences to {targetBox}
            end tell
            return my scanPage(1, firstIndex, pageSize)
        end timeout
    end scanPageAt
    on scanPage(referenceNumber, firstIndex, pageSize)
        set pageDeadline to (current date) + 15
        with timeout of 15 seconds
            set storedBoxes to my scanReferences
            if referenceNumber < 1 or referenceNumber > (count of storedBoxes) then error "Mailbox reference expired" number -1728
            set targetBox to item referenceNumber of storedBoxes
            tell application "Mail"
                set itemCount to count of messages of targetBox
                if firstIndex > itemCount then return {{}, itemCount, 0, {}}
                set lastIndex to firstIndex + pageSize - 1
                if lastIndex > itemCount then set lastIndex to itemCount
                set expectedCount to lastIndex - firstIndex + 1
                try
                    set pageIDs to id of (messages firstIndex thru lastIndex of targetBox)
                    set fromFields to sender of (messages firstIndex thru lastIndex of targetBox)
                    set dateFields to date received of (messages firstIndex thru lastIndex of targetBox)
                    set stableIDs to id of (messages firstIndex thru lastIndex of targetBox)
                    if class of fromFields is not list then set fromFields to {fromFields}
                    if class of dateFields is not list then set dateFields to {dateFields}
                    if pageIDs is equal to stableIDs and (count of fromFields) is expectedCount and (count of dateFields) is expectedCount then return {fromFields, itemCount, 0, dateFields}
                end try
                -- Some recovered/deleted message indexes have holes. One inaccessible item
                -- must not discard an entire page or the rest of the mailbox.
                set fromFields to {}
                set dateFields to {}
                set unreadableCount to 0
                repeat with messageIndex from firstIndex to lastIndex
                    -- AppleScript timeout applies per event, not to the entire fallback loop.
                    if (current date) >= pageDeadline then error "Mail page exceeded its time budget" number -1712
                    try
                        set messageRef to message messageIndex of targetBox
                        set fromField to sender of messageRef
                        set receivedField to date received of messageRef
                        if fromField is missing value then error "Sender missing" number -1728
                        set end of fromFields to fromField
                        set end of dateFields to receivedField
                    on error
                        set end of fromFields to ""
                        set end of dateFields to missing value
                        set unreadableCount to unreadableCount + 1
                    end try
                end repeat
                return {fromFields, itemCount, unreadableCount, dateFields}
            end tell
        end timeout
    end scanPage
    """#
}
