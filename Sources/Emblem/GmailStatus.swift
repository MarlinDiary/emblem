import Foundation
import PortraitCore

/// Explicit local diagnostic. Never requests mail, exports credentials or writes
/// Contacts. Existing legacy credentials may undergo normal Keychain migration.
@MainActor enum GmailStatus {
    static func run(arguments:[String])->Int32 {
        do {
            let root:URL
            if let i=arguments.firstIndex(of:"--data-dir"),i+1<arguments.count {root=URL(fileURLWithPath:arguments[i+1])}
            else {root=LibraryLease.liveRoot}
            let accounts=try JSONDecoder().decode(GmailConnections.self,from:Data(contentsOf:root.appendingPathComponent("gmail.json"))).accounts
            let auth=GmailAuthorization(),now=Date(),formatter=ISO8601DateFormatter()
            let live=root.standardizedFileURL == LibraryLease.liveRoot.standardizedFileURL
            var rows=[[String:Any]]()
            for (index,var account) in accounts.enumerated() {
                account.push?.deliveryHeartbeat=try? GmailPushPresence(root:root).lastAlive(accountID:account.id,now:now)
                var row:[String:Any]=["index":index,"watchValid":account.pushRegistrationIsValid(at:now),
                    "pushHealthy":account.pushIsHealthy(at:now),"pushIssuePresent":account.pushIssue != nil,
                    "regularSyncIssuePresent":account.issue != nil,"historyCursorPresent":account.cursor.historyID != nil]
                if let date=account.cursor.lastCheck {row["lastGmailCheck"]=formatter.string(from:date)}
                if let date=account.push?.watchExpiration {row["watchExpiration"]=formatter.string(from:date)}
                if let date=account.push?.lastPush {row["lastPush"]=formatter.string(from:date)}
                if let date=account.push?.deliveryHeartbeat {row["deliveryHeartbeat"]=formatter.string(from:date)}
                if live {
                    do {row["authorization"]=try auth.statusMetadata(accountID:account.id)}
                    catch {let e=error as NSError;row["authorizationReadError"]=["domain":e.domain,"code":e.code]}
                } else {row["authorizationSkippedForIsolatedData"]=true}
                rows.append(row)
            }
            let report:[String:Any]=["checkedAt":formatter.string(from:now),"pushBuildConfigured":GmailPushConfiguration.current() != nil,
                "configuredClientSecretPresent":live && (try? auth.configuredClient()?.clientSecret) != nil,
                "accountCount":accounts.count,"accounts":rows,"mailRequests":0,"contactsWrites":0]
            let data=try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys])
            print(String(decoding:data,as:UTF8.self));return 0
        } catch {let e=error as NSError;print("GMAIL_STATUS_ERROR_DOMAIN=\(e.domain) CODE=\(e.code)");return 1}
    }
}
