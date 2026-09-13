import AppKit
import UniformTypeIdentifiers
import PortraitCore

extension AppModel {
    var gmailURL:URL {root.appendingPathComponent("gmail.json")}
    func loadGmail()throws {
        if FileManager.default.fileExists(atPath:gmailURL.path) {gmail=try JSONDecoder().decode(GmailConnections.self,from:Data(contentsOf:gmailURL))}
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
                let token=try await GmailAuthorization.freshToken(state)
                let profile=try await self.gmailAPI.profile(token:token)
                guard let email=EmailAddress(profile.emailAddress) else{throw PortraitError.message("Gmail returned an invalid account address.")}
                let index=self.gmail.accounts.firstIndex{$0.email.caseInsensitiveCompare(email.value) == .orderedSame}
                let id=index.map{self.gmail.accounts[$0].id} ?? UUID().uuidString
                try self.gmailAuthorization.save(state,accountID:id)
                if let index {self.gmail.accounts[index].issue=nil;self.gmail.accounts[index].cursor.retryAfter=nil}
                else {self.gmail.accounts.append(GmailAccount(id:id,email:email.value))}
                try self.saveGmail()
                self.automation.setupComplete=true;self.saveAutomationPreferences()
                self.gmailConnecting=false
                self.automaticTick()
                NSApp.activate(ignoringOtherApps:true)
            } catch is CancellationError {}
            catch {self.gmailIssue=error.localizedDescription}
        }
    }
    func disconnectGmail(_ id:String) {
        gmailSyncTask?.cancel()
        Task { [weak self] in
            guard let self else{return}
            if let task=self.gmailSyncTask {await task.value}
            do {
                // Disconnect is local: retain discovered senders and Contacts.
                try self.gmailAuthorization.forget(accountID:id)
                self.gmail.accounts.removeAll{$0.id==id};try self.saveGmail()
            } catch {self.gmailIssue=error.localizedDescription}
        }
    }
    func kickGmailSync(now:Date=Date()) {
        guard backgroundWorkAllowed,!isShuttingDown,!demo,automation.setupComplete,automaticEnabled,
              !gmail.accounts.isEmpty,gmailSyncTask==nil,!gmailConnecting,launchError==nil,!busy,
              gmail.accounts.contains(where:{($0.cursor.retryAfter ?? .distantPast)<=now && now.timeIntervalSince($0.cursor.lastCheck ?? .distantPast)>=60}) else{return}
        gmailSyncTask=Task { [weak self] in
            guard let self else{return}
            defer {self.gmailSyncTask=nil;self.kickMailSync()}
            for id in self.gmail.accounts.map(\.id) {
                guard let index=self.gmail.accounts.firstIndex(where:{$0.id==id}),
                      (self.gmail.accounts[index].cursor.retryAfter ?? .distantPast)<=now,
                      now.timeIntervalSince(self.gmail.accounts[index].cursor.lastCheck ?? .distantPast)>=60 else{continue}
                do {
                    let provider=self.gmailTokenProvider,authorization=self.gmailAuthorization
                    let token=try await withDeadline(seconds:25) {
                        if let provider {return try await provider(id)}
                        return try await authorization.token(accountID:id)
                    }
                    for _ in 0..<3 {
                        try Task.checkCancellation()
                        guard let i=self.gmail.accounts.firstIndex(where:{$0.id==id}),!self.isShuttingDown else{break}
                        let api=self.gmailAPI,cursor=self.gmail.accounts[i].cursor
                        let batch=try await withDeadline(seconds:45) {try await api.batch(cursor:cursor,token:token,now:now)}
                        try Task.checkCancellation()
                        try await self.ingestGmail(batch,accountID:id)
                        self.kickAutomaticLookup();self.kickMailSync()
                        if !batch.hasMore {break}
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
    func ingestGmail(_ batch:GmailBatch,accountID:String)async throws {
        guard gmail.accounts.contains(where:{$0.id==accountID}) else{return}
        // Do not reuse a Mail scan's status counters or reset other providers' inbox dates.
        var seen=Set<String>()
        let previousReport=scanReport
        let previousRowsRevision=rowsRevision
        let existingIDs=Set(rows.map(\.id))
        var receiptOnlyIDs=Set<String>(),addedSender=false
        for message in batch.messages {
            guard let sender=message.sender,let date=message.received else{continue}
            let addresses=EmailAddress.parseList(sender)
            guard addresses.count==1,let email=addresses.first else{continue}
            let revision=rowsRevision
            ingestScanned(email:email,name:email.suggestedDisplayName(in:sender),seen:&seen,receivedAt:date)
            if existingIDs.contains(email.value) {
                if rowsRevision != revision {receiptOnlyIDs.insert(email.value)}
            } else if rows.contains(where:{$0.id==email.value}) {addedSender=true}
        }
        scanReport=previousReport
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        // Persist rows BEFORE the cursor. A crash can repeat a page but cannot skip it.
        // An empty/no-op history page has no sender state to protect, so do not
        // encode and atomically replace a large library merely to update Gmail.
        if rowsRevision != previousRowsRevision && !addedSender {
            try persistInboxReceiptOverlay(ids:receiptOnlyIDs)
            lastSavedRowsRevision=rowsRevision
        } else if rowsRevision != previousRowsRevision {
            while true {
                try Task.checkCancellation()
                let snapshot=rows,revision=rowsRevision
                let data=try await Task.detached(priority:.utility) {try JSONEncoder().encode(snapshot)}.value
                guard revision==rowsRevision else{continue}
                try data.write(to:stateURL,options:.atomic)
                try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:stateURL.path)
                try clearInboxReceiptOverlay()
                lastSavedRowsRevision=revision;break
            }
        }
        guard let i=gmail.accounts.firstIndex(where:{$0.id==accountID}) else{return}
        gmail.accounts[i].cursor=batch.cursor;gmail.accounts[i].issue=nil
        try saveGmail();reconcileSelection()
    }
}
