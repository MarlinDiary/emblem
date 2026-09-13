import Foundation

struct InboxReceiptOverlayValue:Codable,Equatable {
    var receivedAt:Date?
    var mailDisplayName:String?
    var syncEligible:Bool?
}

extension AppModel {
    var inboxReceiptOverlayURL:URL {root.appendingPathComponent("inbox-receipts.json")}

    func loadInboxReceiptOverlay()throws {
        guard FileManager.default.fileExists(atPath:inboxReceiptOverlayURL.path) else{return}
        let values=try JSONDecoder().decode([String:InboxReceiptOverlayValue].self,from:Data(contentsOf:inboxReceiptOverlayURL))
        var replacement=rows,changed=false
        for i in replacement.indices {
            guard let value=values[replacement[i].id] else{continue}
            if let date=value.receivedAt,date >= (replacement[i].lastInboxReceivedAt ?? .distantPast) {
                if replacement[i].lastInboxReceivedAt != date || replacement[i].mailDisplayName != value.mailDisplayName {changed=true}
                replacement[i].lastInboxReceivedAt=date;replacement[i].mailDisplayName=value.mailDisplayName
            }
            if value.syncEligible == true,replacement[i].syncEligible == false {replacement[i].syncEligible=true;changed=true}
        }
        if changed {rows=replacement}
    }

    /// Persist only fields that change when an already-known sender appears in
    /// new mail. The cursor may advance after this small atomic write without
    /// re-encoding cached PNG data for every sender.
    func persistInboxReceiptOverlay(ids:Set<String>)throws {
        var values:[String:InboxReceiptOverlayValue]=[:]
        if FileManager.default.fileExists(atPath:inboxReceiptOverlayURL.path) {
            values=try JSONDecoder().decode([String:InboxReceiptOverlayValue].self,from:Data(contentsOf:inboxReceiptOverlayURL))
        }
        for row in rows where ids.contains(row.id) {
            values[row.id]=InboxReceiptOverlayValue(receivedAt:row.lastInboxReceivedAt,mailDisplayName:row.mailDisplayName,syncEligible:row.syncEligible)
        }
        try JSONEncoder().encode(values).write(to:inboxReceiptOverlayURL,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:inboxReceiptOverlayURL.path)
    }

    func clearInboxReceiptOverlay()throws {
        guard FileManager.default.fileExists(atPath:inboxReceiptOverlayURL.path) else{return}
        try FileManager.default.removeItem(at:inboxReceiptOverlayURL)
    }
}
