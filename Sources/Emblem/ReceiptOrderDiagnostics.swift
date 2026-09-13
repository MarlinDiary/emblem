import Foundation
import PortraitCore

@MainActor enum ReceiptOrderDiagnostics {
    /// Read-only native Mail verification: sender/date metadata only. Isolated
    /// model disables background lookup/sync and never requests Contacts access.
    static func run(arguments:[String])async->Int32 {
        do {
            guard let i=arguments.firstIndex(of:"--output-dir"),i+1<arguments.count else{throw PortraitError.message("Missing --output-dir")}
            let root=URL(fileURLWithPath:arguments[i+1],isDirectory:true)
            let model=AppModel(demo:false,rootOverride:root,backgroundWorkAllowed:false)
            model.automation.contacts=false;model.automaticEnabled=false
            await model.performScan(.inbox,automatic:true)
            let ordered=model.visibleGroups.map(\.representative)
            let report:[String:Any]=["phase":model.scanReport?.phase.rawValue ?? "missing","examined":model.scanReport?.examined ?? 0,"senders":model.rows.count,"dated":model.rows.filter{$0.lastInboxReceivedAt != nil}.count,"ordered":ordered.map{["email":$0.id,"receivedAt":$0.lastInboxReceivedAt?.timeIntervalSince1970 ?? 0] as [String:Any]},"contactsRead":0,"contactsWritten":0,"warnings":model.scanReport?.warnings ?? []]
            try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("receipt-order.json"),options:.atomic)
            print("RECEIPT_DIAGNOSTIC PHASE=\(model.scanReport?.phase.rawValue ?? "missing") MESSAGES=\(model.scanReport?.examined ?? 0) SENDERS=\(model.rows.count) CONTACTS_READ=0 CONTACTS_WRITTEN=0")
            return model.scanReport?.phase == .completed ? 0 : 1
        }catch{print(error.localizedDescription);return 1}
    }
}
