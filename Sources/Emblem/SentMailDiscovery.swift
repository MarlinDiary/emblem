import Foundation
import PortraitCore

extension AppModel {
    func discoverSentMail(now:Date,primary:Set<String>)async throws {
        guard (automation.sentRetryAfter ?? .distantPast)<=now else{return}
        let sweeping=automation.lastSentSweep.map{now.timeIntervalSince($0)>=86_400} ?? true
        guard automation.sentPosition != nil || sweeping || now.timeIntervalSince(automation.lastSent ?? .distantPast)>=60 else{return}
        if automation.sentPosition==nil,!sweeping,let since=automation.lastSent,
           let page=try await mailScanner.recentSent(since:since.addingTimeInterval(-300),excludingAccountEmails:primary) {
            if page.senders.count==page.currentCount {
                try await ingestSentMail(page)
                automation.lastSent=now;automation.sentRetryAfter=nil;saveAutomationPreferences();return
            }
        }
        if automation.sentPosition==nil {automation.sentPosition=1;automation.sentBootstrapStarted=now}
        for _ in 0..<3 {
            try Task.checkCancellation()
            let start=automation.sentPosition ?? 1
            guard let page=try await mailScanner.sentPage(start:start,size:200,excludingAccountEmails:primary) else{return}
            guard !page.senders.isEmpty || start>page.currentCount else{throw PortraitError.message("Mail returned an incomplete Sent page.")}
            try await ingestSentMail(page)
            let next=start+page.senders.count
            // Library checkpoint completed before advancing the resumable cursor.
            if next>page.currentCount {
                automation.lastSent=automation.sentBootstrapStarted ?? now
                automation.lastSentSweep=now;automation.sentPosition=nil;automation.sentBootstrapStarted=nil
            } else {automation.sentPosition=next}
            automation.sentRetryAfter=nil;saveAutomationPreferences()
            kickAutomaticLookup();kickMailSync()
            if automation.sentPosition==nil {break}
        }
    }
    func ingestSentMail(_ page:MailScanPage)async throws {
        guard page.unreadable==0 else{throw PortraitError.message("Some Sent metadata is temporarily unreadable; it will retry.")}
        let oldReport=scanReport
        defer {scanReport=oldReport}
        var seen=Set<String>()
        let own=page.excludedRecipientEmails.union(gmail.accounts.map(\.email))
        for participant in MailParticipants.recipients(page.senders,excluding:own) {
            ingestScanned(email:participant.email,name:participant.name,seen:&seen)
        }
        try await persistScanCheckpoint(force:true)
    }
}
