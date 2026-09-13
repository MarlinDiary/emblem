import AppKit
import Contacts
import Carbon
import PortraitCore

/// A bounded launchd job. It never opens a window, requests privacy permission,
/// reads message bodies, or writes while the foreground owns the library lease.
@MainActor enum BackgroundSyncAgent {
    static func run(arguments:[String])async->Int32 {
        let root=LibraryLease.liveRoot
        do {
            guard !LibraryLease.foregroundRequested(root:root),let lease=try LibraryLease.acquire(root:root) else {return 0}
            defer {withExtendedLifetime(lease) {}}
            return await perform(root:root)
        } catch {print("BACKGROUND_AGENT_ERROR=\(error.localizedDescription)");return 1}
    }
    private static func perform(root:URL)async->Int32 {
        func status(_ state:String,_ model:AppModel?=nil) {
            var data:[String:Any]=["state":state,"pid":getpid(),"timestamp":Date().timeIntervalSinceReferenceDate]
            if let date=model?.automation.lastInbox {data["lastInbox"]=date.timeIntervalSinceReferenceDate}
            if let model {
                let dates=model.gmail.accounts.compactMap{$0.cursor.lastCheck}
                if let latest=dates.max() {data["lastGmailCheck"]=latest.timeIntervalSinceReferenceDate}
                data["gmailPrimaryAccounts"]=MailProviderRouting.primaryEmails(model.gmail.accounts,now:Date()).count
            }
            if let error=model?.automaticAttention ?? model?.syncAttention {data["attention"]=error}
            let url=root.appendingPathComponent("background-status.json")
            if let encoded=try? JSONSerialization.data(withJSONObject:data,options:.sortedKeys) {
                try? encoded.write(to:url,options:.atomic)
                try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
            }
        }
        guard let bytes=try? Data(contentsOf:root.appendingPathComponent("mail-sync.json")),
              let preferences=try? JSONDecoder().decode(MailSyncState.self,from:bytes),preferences.enabled,preferences.background else {status("disabled");return 0}
        guard CNContactStore.authorizationStatus(for:.contacts) == .authorized else {status("contacts-permission-required");return 0}
        let automation=try? JSONDecoder().decode(AutomationPreferences.self,from:Data(contentsOf:root.appendingPathComponent("automation.json")))
        let target=NSAppleEventDescriptor(descriptorType:typeApplicationBundleID,data:Data("com.apple.mail".utf8))
        let mailAllowed=target.map {AEDeterminePermissionToAutomateTarget($0.aeDesc,typeWildCard,typeWildCard,false)==noErr} ?? false
        let model=AppModel(demo:false,rootOverride:root)
        guard model.launchError == nil,model.automation.setupComplete else {status("setup-required",model);return 0}
        model.mailAutomationAvailable=mailAllowed
        if automation?.mail != false && !mailAllowed {
            model.automaticAttention="Apple Mail fallback needs permission. Gmail continues checking connected accounts."
        }
        model.allowsHistoryScan=false
        model.allowsPermissionPrompts=false
        // No permission request path is entered in an unattended process.
        model.automation.contactsPrompted=true
        guard !LibraryLease.foregroundRequested(root:root) else {status("yielded",model);return 0}
        status("running",model)
        model.automaticTick()
        let deadline=Date().addingTimeInterval(150)
        var yielded=false
        while model.gmailSyncTask != nil || model.discoveryTask != nil || model.automaticTask != nil || model.syncTask != nil || model.isScanning {
            if LibraryLease.foregroundRequested(root:root) || Date()>=deadline || Task.isCancelled {yielded=true;break}
            try? await Task.sleep(for:.milliseconds(200))
        }
        model.isShuttingDown=true
        let tasks=[model.discoveryTask,model.automaticTask,model.syncTask,model.gmailSyncTask].compactMap{$0}
        for task in tasks {task.cancel()}
        for task in tasks {await task.value}
        model.save()
        status(yielded ? "yielded":"completed",model)
        print("BACKGROUND_AGENT=\(yielded ? "YIELDED":"COMPLETED") PID=\(getpid())")
        return 0
    }
}
