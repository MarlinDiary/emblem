import Foundation
import PortraitCore

/// Only the exact authenticated mailbox can displace its Apple Mail account.
/// An unknown, stale or failed Gmail connection leaves Mail available.
enum MailProviderRouting {
    static func primaryEmails(_ accounts:[GmailAccount],now:Date)->Set<String> {
        Set(accounts.compactMap { account in
            guard account.issue == nil,account.cursor.retryAfter == nil,
                  account.cursor.historyID != nil,account.cursor.bootstrapHistoryID == nil,
                  account.cursor.pageToken == nil,account.cursor.historyPageToken == nil,
                  let checked=account.cursor.lastCheck,
                  now.timeIntervalSince(checked) >= -60,now.timeIntervalSince(checked) <= 180,
                  let email=EmailAddress(account.email) else {return nil}
            return email.value.lowercased()
        })
    }
}
