import Foundation
import PortraitCore

struct ContactMutationRequest: Codable, Sendable {
    enum Kind: String, Codable { case sync, undo }
    var kind: Kind
    var members: [SenderRow] = []
    var representativeID: String? = nil
    var key: String? = nil
    var explicit: String? = nil
    var link: MailSyncLink? = nil
    var recordID: UUID? = nil
}
struct ContactMutationResponse: Codable, Sendable {
    var link: MailSyncLink? = nil
    var contact: ContactSnapshot? = nil
    var error: String? = nil
    var protection: String? = nil
    var elapsedSeconds: Double? = nil
}

/// Execute the original write-ahead/identity/photo/history guards unchanged.
/// In production this runs in a short-lived headless child, not the UI/socket
/// main actor. A launched mutation is drained even if its caller is cancelled.
@MainActor enum ContactMutation {
    static func perform(_ request:ContactMutationRequest,port:any ContactStorePort,engine:ChangeEngine)throws->ContactMutationResponse {
        if request.kind == .undo {
            guard let id=request.recordID else {throw PortraitError.message("Missing change record.")}
            try engine.undo(id:id);return .init()
        }
        let members=request.members
        guard let key=request.key,let representative=members.first(where:{$0.id==request.representativeID}),let candidate=representative.chosen else {throw PortraitError.message("Missing sender photo.")}
        let explicit=request.explicit
        var link=request.link
        if link == nil {
            let matches=try members.flatMap {try port.matches(email:$0.id)}
            let unique=Dictionary(matches.map{($0.id,$0)},uniquingKeysWith:{a,_ in a})
            guard unique.count<=1 else {throw PortraitError.message("These addresses belong to different contacts and remain separate.")}
            if let contact=unique.values.first {
                let created=try engine.records().contains{$0.contactID==contact.id && $0.created && $0.state == .applied}
                link=MailSyncLink(key:key,contactID:contact.id,emails:Set(contact.emails),createdByApp:created,imageHash:digest(contact.image),desiredHash:digest(candidate.png),externalPhoto:contact.image != nil)
                if contact.image == nil || (explicit != nil && digest(contact.image) != digest(candidate.png)) {
                    guard let matched=members.first(where:{row in contact.emails.contains{$0.caseInsensitiveCompare(row.id) == .orderedSame}}) else {throw PortraitError.message("The email link changed. The original contact is retained.")}
                    _=try engine.replaceSyncedImage(contactID:contact.id,email:matched.id,expectedHash:digest(contact.image),candidate:candidate)
                    if let fresh=try port.get(id:contact.id){link?.imageHash=digest(fresh.image);link?.externalPhoto=false}
                }
            } else {
                let record:ChangeRecord
                if members.count>1 {record=try engine.applyGroup(emails:members.map(\.email),name:SharedSenderIdentity.contactName(email:representative.email,displayName:representative.name),candidate:candidate,allowCreate:true,managedKey:nil)}
                else {record=try engine.apply(email:representative.email,name:SharedSenderIdentity.contactName(email:representative.email,displayName:representative.name),candidate:candidate,allowCreate:true)}
                guard let id=record.contactID,let contact=try port.get(id:id) else {throw PortraitError.message("The new contact could not be verified.")}
                link=MailSyncLink(key:key,contactID:id,emails:Set(contact.emails),createdByApp:true,imageHash:digest(contact.image),desiredHash:digest(candidate.png))
            }
        } else if var currentLink=link,let contact=try port.get(id:currentLink.contactID) {
            if currentLink.createdByApp && currentLink.externalEmails != true {
                let additions=members.filter{row in !currentLink.emails.contains{$0.caseInsensitiveCompare(row.id) == .orderedSame}}
                if !additions.isEmpty {
                    guard try additions.allSatisfy({try port.matches(email:$0.id).allSatisfy{$0.id==contact.id}}) else {throw PortraitError.message("This new address already belongs to another contact. The existing link is preserved.")}
                    _=try engine.appendManagedAliases(contactID:contact.id,emails:additions.map(\.email),managedKey:key)
                    currentLink.emails.formUnion(additions.map(\.id))
                }
            }
            if currentLink.desiredHash != digest(candidate.png) || explicit != nil {
                if digest(contact.image) != digest(candidate.png) && (explicit != nil || (!currentLink.externalPhoto && digest(contact.image)==currentLink.imageHash)) {
                    _=try engine.replaceSyncedImage(contactID:contact.id,email:representative.id,expectedHash:digest(contact.image),candidate:candidate)
                    currentLink.imageHash=digest(try port.get(id:contact.id)?.image);currentLink.externalPhoto=false
                }
                currentLink.desiredHash=digest(candidate.png)
            }
            link=currentLink
        }
        if var link {
            let contact=try port.get(id:link.contactID)
            link.imagePixelHash=photoPixelHash(contact?.image)
            return .init(link:link,contact:contact)
        }
        return .init()
    }

    static func run(_ request:ContactMutationRequest,root:URL,executable override:URL?=nil,fixture:Bool=false)async throws->ContactMutationResponse {
        let executable=override ?? Bundle.main.executableURL ?? URL(fileURLWithPath:CommandLine.arguments[0]).standardizedFileURL
        let worker=Task.detached(priority:.userInitiated) {
            let directory=root.appendingPathComponent("contact-mutation-"+UUID().uuidString,isDirectory:true)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            defer {try? FileManager.default.removeItem(at:directory)}
            let input=directory.appendingPathComponent("request.json"),output=directory.appendingPathComponent("response.json")
            try JSONEncoder().encode(request).write(to:input,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:input.path)
            let process=Process();process.executableURL=executable
            process.arguments=["--contact-mutation-worker","--data-dir",root.path,"--request",input.path,"--response",output.path]
            if fixture {process.arguments?.append("--contact-mutation-fixture")}
            process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
            try process.run();process.waitUntilExit()
            guard FileManager.default.fileExists(atPath:output.path) else {throw PortraitError.message("The Contacts worker stopped. Its write-ahead record is retained; review Contacts before retrying.")}
            return try JSONDecoder().decode(ContactMutationResponse.self,from:Data(contentsOf:output))
        }
        // Do not cancel/kill a child between its durable intent and read-back.
        let result=try await worker.value
        if let p=result.protection {
            switch p {case "photo":throw UndoProtection.photoChanged;case "emails":throw UndoProtection.emailsChanged;default:throw UndoProtection.laterEdits}
        }
        if let error=result.error {throw PortraitError.message(error)}
        return result
    }

    static func worker(arguments:[String])->Int32 {
        func path(_ flag:String)throws->URL {guard let i=arguments.firstIndex(of:flag),i+1<arguments.count else{throw PortraitError.message("Missing worker path.")};return URL(fileURLWithPath:arguments[i+1])}
        do {
            let root=try path("--data-dir"),input=try path("--request"),output=try path("--response")
            let request=try JSONDecoder().decode(ContactMutationRequest.self,from:Data(contentsOf:input))
            let fixture=arguments.contains("--contact-mutation-fixture")
            guard !fixture || root.standardizedFileURL != LibraryLease.liveRoot.standardizedFileURL else{return 1}
            let store:any ContactStorePort
            if fixture {store=try FixtureContactStore(url:root.appendingPathComponent("fixture-contacts.json"))}
            else {let live=AppleContacts();try live.requireFullAccess();store=live}
            let engine=ChangeEngine(store:store,journal:FileJournal(url:root.appendingPathComponent("changes.json")))
            let started=ContinuousClock.now
            var response:ContactMutationResponse
            do {response=try perform(request,port:store,engine:engine)}
            catch let error as UndoProtection {
                let p:String=switch error {case .photoChanged:"photo";case .emailsChanged:"emails";case .laterEdits:"history"}
                response = .init(error:error.localizedDescription,protection:p)
            } catch {response = .init(error:error.localizedDescription)}
            let elapsed=started.duration(to:.now)
            response.elapsedSeconds=Double(elapsed.components.seconds)+Double(elapsed.components.attoseconds)/1e18
            try JSONEncoder().encode(response).write(to:output,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:output.path)
            return response.error == nil ? 0:1
        } catch {return 1}
    }
}
