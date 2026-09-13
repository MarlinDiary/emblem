import Foundation
import PortraitCore

extension AppModel {
    /// A short overlapping delta after the daily complete inbox sweep. Never
    /// clear old timestamps from a partial/delta view of the mailbox.
    func ingestRecentInbox(_ page:MailScanPage)async throws->Bool {
        guard page.unreadable==0,page.senders.count==page.currentCount,page.receivedAt.count==page.senders.count,page.receivedAt.allSatisfy({$0 != nil}) else{return false}
        guard !isScanning else{return false}
        scanActive=true;defer{scanActive=false;kickAutomaticLookup()}
        scanReport=ScanReport(source:.inbox)
        scanReport?.total=page.currentCount;scanReport?.examined=page.currentCount
        var seen=Set<String>()
        for (i,sender) in page.senders.enumerated() {
            guard let email=EmailAddress.parseList(sender).onlyElement else{scanReport?.invalid+=1;continue}
            ingestScanned(email:email,name:email.suggestedDisplayName(in:sender),seen:&seen,receivedAt:page.receivedAt[i])
        }
        scanReport?.phase = .completed;scanReport?.finished=Date();mailConnected=true
        try await persistScanCheckpoint(force:true)
        return true
    }
}
private extension Array {var onlyElement:Element? {count==1 ? first : nil}}
