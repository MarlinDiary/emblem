import AppKit
import Contacts
import Carbon
import PortraitCore

/// A launchd helper that owns only the low-cost push sockets. It acquires the
/// library writer lease for a bounded pass after a notification or fallback
/// deadline, and never competes with the foreground app for Contacts state.
@MainActor enum BackgroundSyncAgent {
    private struct ListenerDescriptor {
        var accountID:String
        var state:GmailPushState
        var channelToken:String
        var signature:String {state.accountKey+"|"+state.deviceID+"|"+channelToken}
    }
    private struct RunningListener {var signature:String;var task:Task<Void,Never>}
    private static var processingWake=false
    private static var queuedWake=false
    private static let modelCache=BackgroundModelCache()

    nonisolated static func fallbackInterval(mailEnabled:Bool,accounts:[GmailAccount],now:Date)->TimeInterval {
        // Push must not slow down another mailbox that still uses regular sync.
        mailEnabled || accounts.contains(where:{!$0.pushIsHealthy(at:now)}) ? 60:900
    }
    nonisolated static func mailFallbackAttention(permission:OSStatus)->String? {
        // procNotFound only means Mail is closed; its fallback resumes when Mail runs.
        permission == noErr || permission == OSStatus(procNotFound) ? nil : "Apple Mail fallback needs permission. Gmail continues checking connected accounts."
    }
    private static func fallbackInterval(root:URL)->TimeInterval {
        let automation=(try? Data(contentsOf:root.appendingPathComponent("automation.json"))).flatMap{try? JSONDecoder().decode(AutomationPreferences.self,from:$0)}
        var accounts=(try? Data(contentsOf:root.appendingPathComponent("gmail.json"))).flatMap{try? JSONDecoder().decode(GmailConnections.self,from:$0)}?.accounts ?? []
        let presence=GmailPushPresence(root:root)
        for index in accounts.indices {
            let heartbeat=try? presence.lastAlive(accountID:accounts[index].id)
            accounts[index].push?.deliveryHeartbeat=heartbeat
        }
        return fallbackInterval(mailEnabled:automation?.mail != false,accounts:accounts,now:Date())
    }

    static func run(arguments:[String])async->Int32 {
        do {
            let root=try EmblemMigration.migrateLibraryIfNeeded()
            guard backgroundEnabled(root:root) else {writeStatus("disabled",root:root);return 0}
            // Start registered sockets before any potentially long archive/avatar pass.
            if GmailPushConfiguration.current() != nil,!listenerDescriptors(root:root).isEmpty {return await listen(root:root)}
            if !LibraryLease.foregroundRequested(root:root) {_=await processOnce(root:root)}
            do {
                if LibraryLease.foregroundRequested(root:root) {writeStatus("foreground-active",root:root)}
                return 0
            }
        } catch {print("BACKGROUND_AGENT_ERROR=\(error.localizedDescription)");return 1}
    }

    private static func backgroundEnabled(root:URL)->Bool {
        guard let bytes=try? Data(contentsOf:root.appendingPathComponent("mail-sync.json")),
              let preferences=try? JSONDecoder().decode(MailSyncState.self,from:bytes) else{return false}
        return preferences.enabled && preferences.background
    }

    private static func listenerDescriptors(root:URL)->[ListenerDescriptor] {
        guard let data=try? Data(contentsOf:root.appendingPathComponent("gmail.json")),
              let connections=try? JSONDecoder().decode(GmailConnections.self,from:data) else{return []}
        return connections.accounts.compactMap {account in
            guard account.pushRegistrationIsValid(at:Date()),let state=account.push,
                  let channel=try? GmailPushCredentials.channelToken(accountID:account.id) else{return nil}
            return ListenerDescriptor(accountID:account.id,state:state,channelToken:channel)
        }
    }

    private static func listen(root:URL)async->Int32 {
        guard let configuration=GmailPushConfiguration.current() else{return 0}
        var running:[String:RunningListener]=[:]
        var lastFallback=Date.distantPast
        var foregroundWasBusy=(try? LibraryLease.writerIsBusy(root:root)) ?? true
        defer {for listener in running.values {listener.task.cancel()}}
        while !Task.isCancelled && backgroundEnabled(root:root) {
            if LibraryLease.foregroundRequested(root:root) {modelCache.discard()}
            let descriptors=listenerDescriptors(root:root),ids=Set(descriptors.map(\.accountID))
            for (id,listener) in running where !ids.contains(id) {listener.task.cancel();running.removeValue(forKey:id)}
            for descriptor in descriptors where running[descriptor.accountID]?.signature != descriptor.signature {
                running[descriptor.accountID]?.task.cancel()
                let rootCopy=root,id=descriptor.accountID,state=descriptor.state,channel=descriptor.channelToken
                let task=Task {
                    await GmailPushListener.run(configuration:configuration,state:state,channelToken:channel,accountID:id,root:rootCopy) {history in
                        do {
                            try GmailPushInbox(root:rootCopy).append(.init(accountID:id,historyID:history,receivedAt:Date()))
                            GmailPushSignal.post()
                            await MainActor.run { _ = Task { await handleWake(root:rootCopy) } }
                        } catch {await MainActor.run {writeStatus("push-handoff-error",root:rootCopy,attention:error.localizedDescription)}}
                    }
                }
                running[descriptor.accountID]=RunningListener(signature:descriptor.signature,task:task)
            }
            guard !running.isEmpty else {writeStatus("polling-fallback",root:root);return 0}
            let foregroundBusy=processingWake ? foregroundWasBusy : (try? LibraryLease.writerIsBusy(root:root)) ?? true
            let presence=GmailPushPresence(root:root)
            let connected=descriptors.filter{(try? presence.lastAlive(accountID:$0.accountID)) != nil}.count
            writeStatus(connected == 0 ? "push-reconnecting":foregroundBusy ? "push-listening-foreground":"push-listening",root:root,pushListeners:connected)
            if (foregroundWasBusy && !foregroundBusy) || Date().timeIntervalSince(lastFallback)>=fallbackInterval(root:root) {
                _=await processOnce(root:root)
                lastFallback=Date()
            }
            foregroundWasBusy=foregroundBusy
            try? await Task.sleep(for:.seconds(10))
        }
        return 0
    }

    private static func handleWake(root:URL)async {
        if processingWake {queuedWake=true;return}
        processingWake=true
        repeat {
            queuedWake=false
            try? await Task.sleep(for:.milliseconds(200))
            _=await processOnce(root:root)
        } while queuedWake && !Task.isCancelled
        processingWake=false
    }

    private static func processOnce(root:URL)async->Int32 {
        if LibraryLease.foregroundRequested(root:root) {modelCache.discard();return 0}
        guard let lease=try? LibraryLease.acquire(root:root) else{return 0}
        defer {withExtendedLifetime(lease){}}
        return await perform(root:root)
    }

    private static func perform(root:URL)async->Int32 {
        // Only the bounded mail pass needs prompt execution; idle sockets do
        // not hold an activity assertion or prevent natural system sleep.
        let activity=ProcessInfo.processInfo.beginActivity(options:.userInitiatedAllowingIdleSystemSleep,reason:"Process newly received mail")
        defer {ProcessInfo.processInfo.endActivity(activity)}
        guard CNContactStore.authorizationStatus(for:.contacts) == .authorized else {writeStatus("contacts-permission-required",root:root);return 0}
        let automation=try? JSONDecoder().decode(AutomationPreferences.self,from:Data(contentsOf:root.appendingPathComponent("automation.json")))
        let target=NSAppleEventDescriptor(descriptorType:typeApplicationBundleID,data:Data("com.apple.mail".utf8))
        let permission=target.map {AEDeterminePermissionToAutomateTarget($0.aeDesc,typeWildCard,typeWildCard,false)} ?? OSStatus(errAEEventNotPermitted)
        let mailAllowed=permission==noErr
        let model:AppModel
        do {model=try modelCache.model(root:root) {AppModel(demo:false,rootOverride:root)}}
        catch {writeStatus("library-read-error",root:root,attention:error.localizedDescription);return 1}
        guard model.launchError == nil,model.automation.setupComplete else {writeStatus("setup-required",root:root,model:model);return 0}
        model.mailAutomationAvailable=mailAllowed
        if automation?.mail != false,let attention=mailFallbackAttention(permission:permission) {model.automaticAttention=attention}
        model.allowsHistoryScan=false;model.allowsPermissionPrompts=false;model.automation.contactsPrompted=true
        guard !LibraryLease.foregroundRequested(root:root) else {writeStatus("yielded",root:root,model:model);return 0}
        writeStatus("running",root:root,model:model)
        model.automaticTick()
        let deadline=Date().addingTimeInterval(150)
        var yielded=false
        while model.gmailSyncTask != nil || model.gmailPushMaintenanceTask != nil || model.discoveryTask != nil || model.automaticTask != nil || model.syncTask != nil || model.isScanning {
            if LibraryLease.foregroundRequested(root:root) || Date()>=deadline || Task.isCancelled {yielded=true;break}
            // The socket cannot take this writer lease. Keep replaying incoming
            // hints while slower avatar/discovery/sync tasks are still running.
            model.consumeGmailPushInbox()
            try? await Task.sleep(for:.milliseconds(200))
        }
        model.isShuttingDown=true
        let tasks=[model.discoveryTask,model.automaticTask,model.syncTask,model.gmailSyncTask,model.gmailPushMaintenanceTask].compactMap{$0}
        for task in tasks {task.cancel()};for task in tasks {await task.value}
        do {try await model.saveAsync()}
        catch {writeStatus("save-error",root:root,model:model,attention:error.localizedDescription);return 1}
        do {try modelCache.remember(model)}
        catch {modelCache.discard()}
        writeStatus(yielded ? "yielded":"completed",root:root,model:model)
        print("BACKGROUND_AGENT=\(yielded ? "YIELDED":"COMPLETED") PID=\(getpid())")
        return 0
    }

    private static func writeStatus(_ state:String,root:URL,model:AppModel?=nil,attention:String?=nil,pushListeners:Int?=nil) {
        var data:[String:Any]=["state":state,"pid":getpid(),"timestamp":Date().timeIntervalSinceReferenceDate]
        if let date=model?.automation.lastInbox {data["lastInbox"]=date.timeIntervalSinceReferenceDate}
        if let model {
            let dates=model.gmail.accounts.compactMap{$0.cursor.lastCheck};if let latest=dates.max(){data["lastGmailCheck"]=latest.timeIntervalSinceReferenceDate}
            data["gmailPrimaryAccounts"]=MailProviderRouting.primaryEmails(model.gmail.accounts,now:Date()).count
            data["pushReadyAccounts"]=model.gmail.accounts.filter{$0.pushIsHealthy(at:Date())}.count
        }
        if let pushListeners {data["pushListeners"]=pushListeners}
        if let error=attention ?? model?.automaticAttention ?? model?.syncAttention {data["attention"]=error}
        let url=root.appendingPathComponent("background-status.json")
        if let encoded=try? JSONSerialization.data(withJSONObject:data,options:.sortedKeys) {
            try? encoded.write(to:url,options:.atomic);try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        }
    }
}
