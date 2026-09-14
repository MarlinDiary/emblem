import AppKit
import UniformTypeIdentifiers
import PortraitCore

extension AppModel {
    var gmailURL:URL {root.appendingPathComponent("gmail.json")}
    func loadGmail()throws {
        if FileManager.default.fileExists(atPath:gmailURL.path) {
            gmail=try JSONDecoder().decode(GmailConnections.self,from:Data(contentsOf:gmailURL))
            if GmailPushConfiguration.current() != nil {
                for index in gmail.accounts.indices where gmail.accounts[index].push == nil {
                    gmail.accounts[index].pushIssue="Reconnect once for instant updates. Regular Gmail sync continues."
                }
            }
        }
        refreshGmailPushDelivery()
    }
    func refreshGmailPushDelivery(now:Date=Date()) {
        let presence=GmailPushPresence(root:root)
        for index in gmail.accounts.indices where gmail.accounts[index].push != nil {
            let heartbeat=try? presence.lastAlive(accountID:gmail.accounts[index].id,now:now)
            if gmail.accounts[index].push?.deliveryHeartbeat != heartbeat {gmail.accounts[index].push?.deliveryHeartbeat=heartbeat}
        }
    }
    func saveGmail()throws {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try JSONEncoder().encode(gmail).write(to:gmailURL,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:gmailURL.path)
    }
    func connectGmail() {
        guard !gmailConnecting,!demo,root.standardizedFileURL==LibraryLease.liveRoot.standardizedFileURL else{return}
        gmailConnecting=true;gmailIssue=nil
        gmailSignInTask=Task { [weak self] in
            guard let self else{return}
            defer {self.gmailConnecting=false;self.gmailSignInTask=nil}
            do {
                var client=try self.gmailAuthorization.configuredClient()
                if client==nil {
                    let picker=NSOpenPanel();picker.allowedContentTypes=[.json];picker.canChooseDirectories=false;picker.allowsMultipleSelection=false
                    picker.title="Set Up Gmail";picker.message="Choose the Desktop app OAuth JSON downloaded from your Google Cloud project. This is a one-time setup for this open-source build."
                    picker.prompt="Choose Configuration"
                    guard picker.runModal() == .OK,let url=picker.url else{return}
                    try self.gmailAuthorization.importClient(Data(contentsOf:url));client=try self.gmailAuthorization.configuredClient()
                }
                guard let client else{return}
                let state=try await self.gmailAuthorization.authorize(client:client)
                try Task.checkCancellation()
                let tokens=try await GmailAuthorization.freshTokens(state)
                let profile=try await self.gmailAPI.profile(token:tokens.accessToken)
                guard let email=EmailAddress(profile.emailAddress) else{throw PortraitError.message("Gmail returned an invalid account address.")}
                let index=self.gmail.accounts.firstIndex{$0.email.caseInsensitiveCompare(email.value) == .orderedSame}
                let id=index.map{self.gmail.accounts[$0].id} ?? UUID().uuidString
                try self.gmailAuthorization.save(state,accountID:id)
                if let index {self.gmail.accounts[index].issue=nil;self.gmail.accounts[index].pushIssue=nil;self.gmail.accounts[index].cursor.retryAfter=nil}
                else {self.gmail.accounts.append(GmailAccount(id:id,email:email.value))}
                try self.saveGmail()
                do {
                    try await self.configureGmailPush(accountID:id,email:email.value,tokens:tokens)
                } catch {
                    if let i=self.gmail.accounts.firstIndex(where:{$0.id==id}) {self.gmail.accounts[i].pushIssue=error.localizedDescription;try? self.saveGmail()}
                }
                self.automation.setupComplete=true;self.saveAutomationPreferences()
                self.gmailConnecting=false
                self.automaticTick()
                self.backgroundPreferenceChanged?()
                NSApp.activate(ignoringOtherApps:true)
            } catch is CancellationError {}
            catch {self.gmailIssue=error.localizedDescription}
        }
    }
    func disconnectGmail(_ id:String) {
        gmailSyncTask?.cancel()
        gmailPushMaintenanceTask?.cancel()
        Task { [weak self] in
            guard let self else{return}
            if let task=self.gmailSyncTask {await task.value}
            if let task=self.gmailPushMaintenanceTask {await task.value}
            do {
                // Disconnect is local: retain discovered senders and Contacts.
                if let configuration=GmailPushConfiguration.current(),
                   let state=self.gmail.accounts.first(where:{$0.id==id})?.push,
                   let channel=try? GmailPushCredentials.channelToken(accountID:id) {
                    try? await GmailPushBackend(configuration:configuration).unregister(state:state,channelToken:channel)
                }
                try self.gmailAuthorization.forget(accountID:id)
                self.gmailForcedAccountIDs.remove(id)
                try? GmailPushPresence(root:self.root).remove(accountID:id)
                self.gmail.accounts.removeAll{$0.id==id};try self.saveGmail()
                self.refreshForegroundGmailPushListener(backgroundServiceActive:self.mailSync.background && BackgroundService.service.status == .enabled)
                self.backgroundPreferenceChanged?()
            } catch {self.gmailIssue=error.localizedDescription}
        }
    }
    func kickGmailSync(now:Date=Date(),forceAccountIDs:Set<String>=[]) {
        gmailForcedAccountIDs.formUnion(forceAccountIDs)
        let scheduledForced=gmailForcedAccountIDs
        let scheduled=Set(gmail.accounts.compactMap { account -> String? in
            guard (account.cursor.retryAfter ?? .distantPast)<=now else{return nil}
            let paginating=account.cursor.pageToken != nil || account.cursor.historyPageToken != nil || (account.cursor.sentBootstrapComplete != true && (account.cursor.sentRetryAfter ?? .distantPast)<=now)
            let interval=paginating ? 0.0:(account.pushIsHealthy(at:now) ? 900.0:60.0)
            return scheduledForced.contains(account.id) || now.timeIntervalSince(account.cursor.lastCheck ?? .distantPast)>=interval ? account.id:nil
        })
        guard backgroundWorkAllowed,!isShuttingDown,!demo,automation.setupComplete,automaticEnabled,
              !gmail.accounts.isEmpty,gmailSyncTask==nil,!gmailConnecting,launchError==nil,!busy,
              !scheduled.isEmpty else{return}
        gmailForcedAccountIDs.subtract(scheduled)
        gmailSyncTask=Task { [weak self] in
            guard let self else{return}
            defer {
                self.gmailSyncTask=nil;self.kickMailSync()
                if !self.gmailForcedAccountIDs.isEmpty {self.kickGmailSync(now:Date())}
            }
            for id in self.gmail.accounts.map(\.id) where scheduled.contains(id) {
                guard let index=self.gmail.accounts.firstIndex(where:{$0.id==id}),
                      (self.gmail.accounts[index].cursor.retryAfter ?? .distantPast)<=now else{continue}
                do {
                    let provider=self.gmailTokenProvider,authorization=self.gmailAuthorization
                    let token=try await withDeadline(seconds:25) {
                        if let provider {return try await provider(id)}
                        return try await authorization.token(accountID:id)
                    }
                    for pageIndex in 0..<3 {
                        try Task.checkCancellation()
                        guard let i=self.gmail.accounts.firstIndex(where:{$0.id==id}),!self.isShuttingDown else{break}
                        let api=self.gmailAPI,cursor=self.gmail.accounts[i].cursor
                        let batch=try await withDeadline(seconds:45) {try await api.batch(cursor:cursor,token:token,now:now)}
                        try Task.checkCancellation()
                        try await self.ingestGmail(batch,accountID:id)
                        self.kickAutomaticLookup();self.kickMailSync()
                        if !batch.hasMore {break}
                        if pageIndex == 2 && self.gmail.accounts.first(where:{$0.id==id})?.cursor.historyPageToken != nil {
                            self.gmailForcedAccountIDs.insert(id)
                        }
                    }
                    // A legacy account imports Sent independently, after servicing
                    // current history. A failed archive page never delays new inbox mail.
                    if let account=self.gmail.accounts.first(where:{$0.id==id}),account.cursor.historyID != nil,
                       account.cursor.sentBootstrapComplete != true,(account.cursor.sentRetryAfter ?? .distantPast)<=now {
                        do {
                            if let current=self.gmail.accounts.first(where:{$0.id==id}) {
                                try Task.checkCancellation()
                                let api=self.gmailAPI,cursor=current.cursor
                                let archive=Task {try await withDeadline(seconds:45) {try await api.sentBatch(cursor:cursor,token:token)}}
                                self.gmailSentBootstrapTask=archive
                                defer {self.gmailSentBootstrapTask=nil}
                                let batch=try await withTaskCancellationHandler {try await archive.value} onCancel:{archive.cancel()}
                                try Task.checkCancellation()
                                try await self.ingestGmail(batch,accountID:id)
                                self.kickAutomaticLookup();self.kickMailSync()
                            }
                        } catch is CancellationError {
                            if Task.isCancelled {throw CancellationError()}
                            // A new-mail hint preempts only archive work, without
                            // backoff. The deferred sync immediately replays history.
                        } catch {
                            if let i=self.gmail.accounts.firstIndex(where:{$0.id==id}) {
                                self.gmail.accounts[i].cursor.sentRetryAfter=now.addingTimeInterval(300)
                                try self.saveGmail()
                            }
                        }
                    }
                } catch is CancellationError {break}
                catch {
                    if let i=self.gmail.accounts.firstIndex(where:{$0.id==id}) {
                        self.gmail.accounts[i].issue=error.localizedDescription
                        self.gmail.accounts[i].cursor.retryAfter=now.addingTimeInterval(300)
                        do {try self.saveGmail()} catch {self.gmailIssue=error.localizedDescription}
                    }
                }
            }
        }
    }

    func configureGmailPush(accountID:String,email:String,tokens:GmailOAuthTokens)async throws {
        guard let configuration=GmailPushConfiguration.current() else{return}
        guard let idToken=tokens.idToken,!idToken.isEmpty else {throw PortraitError.message("Reconnect Gmail once to enable instant updates.")}
        let existing=gmail.accounts.first(where:{$0.id==accountID})?.push
        let deviceID=existing?.deviceID ?? UUID().uuidString
        let channel=try GmailPushCredentials.channelToken(accountID:accountID) ?? GmailPushCredentials.createChannelToken(accountID:accountID)
        let registration=try await GmailPushBackend(configuration:configuration).register(idToken:idToken,email:email,deviceID:deviceID,channelToken:channel)
        guard registration.accountKey.count==64,registration.accountKey.allSatisfy({$0.isHexDigit}) else {throw PortraitError.message("Instant update registration returned an invalid account key.")}
        var state=GmailPushState(accountKey:registration.accountKey,deviceID:deviceID,registeredAt:Date(),registrationExpiration:registration.expiresAt,watchExpiration:nil,lastWatchRenewal:nil,lastPush:existing?.lastPush)
        if let i=gmail.accounts.firstIndex(where:{$0.id==accountID}) {gmail.accounts[i].push=state;gmail.accounts[i].pushIssue=nil;gmail.accounts[i].pushRetryAfter=nil;try saveGmail()}
        let watch=try await gmailAPI.watch(token:tokens.accessToken,topicName:configuration.topicName)
        state.watchExpiration=watch.expiration;state.lastWatchRenewal=Date()
        if let i=gmail.accounts.firstIndex(where:{$0.id==accountID}) {gmail.accounts[i].push=state;gmail.accounts[i].pushIssue=nil;try saveGmail()}
    }

    func kickGmailPushMaintenance(now:Date=Date()) {
        guard backgroundWorkAllowed,!isShuttingDown,!demo,automation.setupComplete,automaticEnabled,
              gmailPushMaintenanceTask==nil,let configuration=GmailPushConfiguration.current(),
              gmail.accounts.contains(where:{$0.push != nil && ($0.pushRetryAfter ?? .distantPast)<=now && ($0.push!.registrationNeedsRenewal(now:now) || $0.push!.watchNeedsRenewal(now:now))}) else{return}
        gmailPushMaintenanceTask=Task { [weak self] in
            guard let self else{return}
            defer {self.gmailPushMaintenanceTask=nil}
            for id in self.gmail.accounts.map(\.id) {
                guard let index=self.gmail.accounts.firstIndex(where:{$0.id==id}),
                      (self.gmail.accounts[index].pushRetryAfter ?? .distantPast)<=now,
                      var state=self.gmail.accounts[index].push,
                      state.registrationNeedsRenewal(now:now) || state.watchNeedsRenewal(now:now) else{continue}
                let email=self.gmail.accounts[index].email
                do {
                    var tokens:GmailOAuthTokens?
                    if state.registrationNeedsRenewal(now:now) {
                        tokens=try await self.gmailAuthorization.tokens(accountID:id,forceRefresh:true)
                        guard let identity=tokens?.idToken,
                              let channel=try GmailPushCredentials.channelToken(accountID:id) else {throw GmailPushHTTPError(status:401)}
                        let renewed=try await GmailPushBackend(configuration:configuration).register(idToken:identity,email:email,deviceID:state.deviceID,channelToken:channel)
                        state.accountKey=renewed.accountKey;state.registeredAt=now;state.registrationExpiration=renewed.expiresAt
                    }
                    if state.watchNeedsRenewal(now:now) {
                        if tokens == nil {tokens=try await self.gmailAuthorization.tokens(accountID:id)}
                        let watch=try await self.gmailAPI.watch(token:tokens!.accessToken,topicName:configuration.topicName)
                        state.watchExpiration=watch.expiration;state.lastWatchRenewal=now
                    }
                    try Task.checkCancellation()
                    guard let i=self.gmail.accounts.firstIndex(where:{$0.id==id}) else{continue}
                    state.lastPush=self.gmail.accounts[i].push?.lastPush
                    self.gmail.accounts[i].push=state;self.gmail.accounts[i].pushIssue=nil;self.gmail.accounts[i].pushRetryAfter=nil;try self.saveGmail()
                    self.backgroundPreferenceChanged?()
                } catch is CancellationError {return}
                catch {
                    if let i=self.gmail.accounts.firstIndex(where:{$0.id==id}) {self.gmail.accounts[i].pushIssue=error.localizedDescription;self.gmail.accounts[i].pushRetryAfter=now.addingTimeInterval(300);try? self.saveGmail()}
                }
            }
        }
    }

    func noteGmailPush(accountID:String,historyID:String,receivedAt:Date=Date()) {
        guard gmail.accounts.contains(where:{$0.id==accountID}),GmailPushBackend.validHistory(historyID) else{return}
        gmailSentBootstrapTask?.cancel()
        refreshGmailPushDelivery()
        if let i=gmail.accounts.firstIndex(where:{$0.id==accountID}) {gmail.accounts[i].push?.lastPush=receivedAt;gmail.accounts[i].pushIssue=nil;try? saveGmail()}
        kickGmailSync(now:Date(),forceAccountIDs:[accountID])
    }

    func consumeGmailPushInbox() {
        do {
            let events=try GmailPushInbox(root:root).consume()
            for event in events {noteGmailPush(accountID:event.accountID,historyID:event.historyID,receivedAt:event.receivedAt)}
        } catch {gmailIssue="Instant update handoff: "+error.localizedDescription}
    }

    func refreshForegroundGmailPushListener(backgroundServiceActive:Bool) {
        gmailPushListenerTask?.cancel();gmailPushListenerTask=nil
        guard !backgroundServiceActive,!isShuttingDown,automaticEnabled,let configuration=GmailPushConfiguration.current() else{return}
        let descriptors=gmail.accounts.compactMap { account -> (String,GmailPushState,String)? in
            guard account.pushRegistrationIsValid(at:Date()),let state=account.push,
                  let token=try? GmailPushCredentials.channelToken(accountID:account.id) else{return nil}
            return (account.id,state,token)
        }
        guard !descriptors.isEmpty else{return}
        let listenerRoot=root
        gmailPushListenerTask=Task { [weak self] in
            await withTaskGroup(of:Void.self) {group in
                for (id,state,token) in descriptors {
                    group.addTask {
                        await GmailPushListener.run(configuration:configuration,state:state,channelToken:token,accountID:id,root:listenerRoot) {history in
                            await MainActor.run {self?.noteGmailPush(accountID:id,historyID:history)}
                        }
                    }
                }
                await group.waitForAll()
            }
        }
    }

    func stopGmailPushListening(){gmailPushListenerTask?.cancel();gmailPushListenerTask=nil}
    func ingestGmail(_ batch:GmailBatch,accountID:String)async throws {
        guard gmail.accounts.contains(where:{$0.id==accountID}) else{return}
        // Do not reuse a Mail scan's status counters or reset other providers' inbox dates.
        var seen=Set<String>()
        let previousReport=scanReport
        let previousRowsRevision=rowsRevision
        let existingIDs=Set(rows.map(\.id))
        var receiptOnlyIDs=Set<String>(),addedSender=false
        for message in batch.messages {
            let participants=MailParticipants.gmail(message,ownEmails:Set(gmail.accounts.map(\.email)))
            for participant in participants {
                let email=participant.email,revision=rowsRevision
                ingestScanned(email:email,name:participant.name,seen:&seen,receivedAt:participant.inboxReceivedAt)
                if existingIDs.contains(email.value) {
                    if rowsRevision != revision {receiptOnlyIDs.insert(email.value)}
                } else if rows.contains(where:{$0.id==email.value}) {addedSender=true}
            }
        }
        scanReport=previousReport
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        // Persist rows BEFORE the cursor. A crash can repeat a page but cannot skip it.
        // An empty/no-op history page has no sender state to protect, so do not
        // encode and atomically replace a large library merely to update Gmail.
        if rowsRevision != previousRowsRevision && !addedSender {
            try persistInboxReceiptOverlay(ids:receiptOnlyIDs)
            if lastSavedRowsRevision == previousRowsRevision {lastSavedRowsRevision=rowsRevision}
        } else if rowsRevision != previousRowsRevision {
            try Task.checkCancellation()
            let snapshot=rows,revision=rowsRevision
            let data:Data
            if let encoder=gmailRowsEncoder {data=try await encoder(snapshot)}
            else {data=try await Task.detached(priority:.utility) {try JSONEncoder().encode(snapshot)}.value}
            try Task.checkCancellation()
            // The batch is already in this snapshot. Later unsaved avatar edits
            // remain dirty; they must not starve the mail cursor by restarting
            // encoding forever. A newer durable save already includes this batch,
            // so never overwrite it with an older in-flight snapshot.
            if (lastSavedRowsRevision ?? 0)<revision {
                try data.write(to:stateURL,options:.atomic)
                try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:stateURL.path)
                if rowsRevision==revision {try clearInboxReceiptOverlay()}
                lastSavedRowsRevision=revision
            }
        }
        guard let i=gmail.accounts.firstIndex(where:{$0.id==accountID}) else{return}
        gmail.accounts[i].cursor=batch.cursor;gmail.accounts[i].issue=nil
        try saveGmail();reconcileSelection()
    }
}
