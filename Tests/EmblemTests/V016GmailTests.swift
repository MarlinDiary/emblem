import XCTest
import AppAuth
@testable import Emblem
import PortraitCore

private actor GmailTransportFixture:GmailHTTPTransport {
    var routes:[String:[(Int,String)]]
    var requests:[URLRequest]=[]
    init(_ routes:[String:[(Int,String)]]) {self.routes=routes}
    func data(for request:URLRequest)async throws->(Data,HTTPURLResponse) {
        requests.append(request)
        let key=request.url!.path
        guard var queue=routes[key],!queue.isEmpty else {throw NSError(domain:"UnexpectedFixtureRequest",code:1)}
        let item=queue.removeFirst();routes[key]=queue
        return (Data(item.1.utf8),HTTPURLResponse(url:request.url!,statusCode:item.0,httpVersion:nil,headerFields:nil)!)
    }
}
final class V016GmailTests:XCTestCase {
    private let root="/gmail/v1/users/me/"
    private let message=#"{"id":"abc","labelIds":["INBOX"],"internalDate":"1789286400000","payload":{"headers":[{"name":"From","value":"LinkedIn <invitations@linkedin.com>"}]}}"#
    func testBootstrapOnlyReadsFromMetadataAndCommitsBaselineHistory()async throws {
        let transport=GmailTransportFixture([root+"profile":[(200,#"{"emailAddress":"invitations@linkedin.com","historyId":"100"}"#)],root+"messages":[(200,#"{"messages":[{"id":"abc"}]}"#)],root+"messages/abc":[(200,message)]])
        let batch=try await GmailAPI(transport:transport).batch(cursor:GmailCursor(),token:"fixture-token")
        XCTAssertEqual(batch.messages.first?.sender,"LinkedIn <invitations@linkedin.com>")
        XCTAssertEqual(batch.cursor.historyID,"100");XCTAssertFalse(batch.hasMore)
        let requests=await transport.requests
        XCTAssertTrue(requests.allSatisfy{$0.httpMethod=="GET" && $0.url?.host=="gmail.googleapis.com"})
        let request=try XCTUnwrap(requests.last),query=URLComponents(url:request.url!,resolvingAgainstBaseURL:false)!.queryItems!
        XCTAssertTrue(query.contains(.init(name:"format",value:"metadata")))
        XCTAssertTrue(query.contains(.init(name:"metadataHeaders",value:"From")))
        XCTAssertFalse(query.contains{$0.name=="q"});XCTAssertFalse(request.url!.absoluteString.contains("fixture-token"))
    }
    func testBootstrapPaginationRetainsStartingHistory()async throws {
        let transport=GmailTransportFixture([root+"profile":[(200,#"{"emailAddress":"invitations@linkedin.com","historyId":"100"}"#)],root+"messages":[(200,#"{"nextPageToken":"page-2"}"#),(200,#"{}"#)]])
        let api=GmailAPI(transport:transport),first=try await api.batch(cursor:GmailCursor(),token:"fixture")
        XCTAssertNil(first.cursor.historyID);XCTAssertEqual(first.cursor.bootstrapHistoryID,"100")
        XCTAssertEqual(first.cursor.pageToken,"page-2");XCTAssertTrue(first.hasMore)
        let second=try await api.batch(cursor:first.cursor,token:"fixture")
        XCTAssertEqual(second.cursor.historyID,"100");XCTAssertNil(second.cursor.pageToken)
    }
    func testHistoryAddsInboxLabelsAndDeduplicatesIDs()async throws {
        let transport=GmailTransportFixture([root+"history":[(200,#"{"historyId":"130","history":[{"messagesAdded":[{"message":{"id":"abc","labelIds":["INBOX"]}}],"labelsAdded":[{"message":{"id":"abc"},"labelIds":["INBOX"]}]}]}"#)],root+"messages/abc":[(200,message)]])
        let batch=try await GmailAPI(transport:transport).batch(cursor:GmailCursor(historyID:"100"),token:"fixture")
        XCTAssertEqual(batch.messages.count,1);XCTAssertEqual(batch.cursor.historyID,"130")
        let requests=await transport.requests;XCTAssertEqual(requests.count,2)
    }
    func testHistoryPaginationDoesNotSkipUnprocessedPages()async throws {
        let transport=GmailTransportFixture([root+"history":[(200,#"{"historyId":"130","nextPageToken":"next"}"#),(200,#"{"historyId":"140"}"#)]])
        let api=GmailAPI(transport:transport),first=try await api.batch(cursor:GmailCursor(historyID:"100"),token:"fixture")
        XCTAssertEqual(first.cursor.historyID,"100");XCTAssertEqual(first.cursor.historyPageToken,"next")
        let second=try await api.batch(cursor:first.cursor,token:"fixture")
        XCTAssertEqual(second.cursor.historyID,"140");XCTAssertNil(second.cursor.historyPageToken)
    }
    func testExpiredHistoryRebuildsInboxWithoutDeletingLibrary()async throws {
        let transport=GmailTransportFixture([root+"history":[(404,"{}")],root+"profile":[(200,#"{"emailAddress":"invitations@linkedin.com","historyId":"900"}"#)],root+"messages":[(200,"{}")]])
        let batch=try await GmailAPI(transport:transport).batch(cursor:GmailCursor(historyID:"1"),token:"fixture")
        XCTAssertEqual(batch.cursor.historyID,"900")
    }
    func testMetadataFailureNeverReturnsAdvancedCursor()async throws {
        let transport=GmailTransportFixture([root+"history":[(200,#"{"historyId":"150","history":[{"messagesAdded":[{"message":{"id":"abc"}}]}]}"#)],root+"messages/abc":[(429,"{}")]])
        do {_=try await GmailAPI(transport:transport).batch(cursor:GmailCursor(historyID:"100"),token:"fixture");XCTFail("Expected rate limit")}
        catch let error as GmailHTTPError {XCTAssertEqual(error.status,429)}
    }
    func testDeletedMessageIsNotAnErrorAndArchivedMessagesAreExcluded()async throws {
        let transport=GmailTransportFixture([root+"history":[(200,#"{"historyId":"150","history":[{"messagesAdded":[{"message":{"id":"abc"}},{"message":{"id":"def"}}]}]}"#)],root+"messages/abc":[(404,"{}")],root+"messages/def":[(200,#"{"id":"def","labelIds":["SENT"]}"#)]])
        let batch=try await GmailAPI(transport:transport).batch(cursor:GmailCursor(historyID:"100"),token:"fixture")
        XCTAssertTrue(batch.messages.isEmpty);XCTAssertEqual(batch.cursor.historyID,"150")
    }
    @MainActor func testOAuthUsesMetadataScopePKCEAndFreshState()throws {
        let client=GmailOAuthClient(clientID:"test.apps.googleusercontent.com")
        let a=GmailAuthorization.request(client:client,redirect:URL(string:"http://127.0.0.1:41001")!)
        let b=GmailAuthorization.request(client:client,redirect:URL(string:"http://127.0.0.1:41001")!)
        let scopes=Set((a.scope ?? "").split(separator:" ").map(String.init))
        XCTAssertTrue(Set(GmailAuthorization.identityScopes).isSubset(of:scopes));XCTAssertEqual(a.codeChallengeMethod,"S256")
        XCTAssertNotNil(a.codeVerifier);XCTAssertNotEqual(a.state,b.state)
        XCTAssertEqual(a.configuration.tokenEndpoint.absoluteString,"https://oauth2.googleapis.com/token")
    }
    func testOnlyGoogleDesktopClientFilesAreAccepted()throws {
        let valid=Data(#"{"installed":{"client_id":"test.apps.googleusercontent.com","client_secret":"fixture-only"}}"#.utf8)
        XCTAssertEqual(try GmailOAuthClient.parse(valid).clientID,"test.apps.googleusercontent.com")
        XCTAssertThrowsError(try GmailOAuthClient.parse(Data(#"{"web":{"client_id":"test.apps.googleusercontent.com"}}"#.utf8)))
        XCTAssertThrowsError(try GmailOAuthClient.parse(Data(#"{"installed":{"client_id":"not-google"}}"#.utf8)))
    }
    @MainActor func testGmailIngestionPreservesOtherSendersAndManualPhotoAndPersistsCursorLast()async throws {
        let temp=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:temp)}
        let model=AppModel(demo:true,rootOverride:temp,backgroundWorkAllowed:false)
        let email=EmailAddress("billing@raycast.com")!
        model.rows=[SenderRow(email:email,name:"Raycast",selectionIsManual:true,lastInboxReceivedAt:Date(timeIntervalSince1970:1))]
        model.gmail.accounts=[GmailAccount(id:"fixture",email:"invitations@linkedin.com")]
        let message=try JSONDecoder().decode(GmailMessage.self,from:Data(self.message.utf8))
        try await model.ingestGmail(GmailBatch(messages:[message,message],cursor:GmailCursor(historyID:"500"),hasMore:false),accountID:"fixture")
        XCTAssertEqual(model.rows.count,2);XCTAssertEqual(model.rows.first{$0.email==email}?.selectionIsManual,true)
        let restored=AppModel(demo:true,rootOverride:temp,backgroundWorkAllowed:false)
        XCTAssertEqual(restored.rows.count,2);XCTAssertEqual(restored.gmail.accounts.first?.cursor.historyID,"500")
        XCTAssertTrue(try restored.engine.records().isEmpty)
    }
    @MainActor func testEmptyGmailIncrementAdvancesCursorWithoutRewritingSenderLibrary()async throws {
        let temp=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:temp)}
        let model=AppModel(demo:true,rootOverride:temp,backgroundWorkAllowed:false)
        model.rows=[SenderRow(email:EmailAddress("billing@raycast.com")!,name:"Raycast")]
        model.gmail.accounts=[GmailAccount(id:"fixture",email:"fixture@gmail.com")]
        model.save()
        let before=try XCTUnwrap((try FileManager.default.attributesOfItem(atPath:model.stateURL.path)[.systemFileNumber]) as? NSNumber)
        let checked=Date(timeIntervalSince1970:1_789_286_400)
        try await model.ingestGmail(GmailBatch(messages:[],cursor:GmailCursor(historyID:"501",lastCheck:checked),hasMore:false),accountID:"fixture")
        let after=try XCTUnwrap((try FileManager.default.attributesOfItem(atPath:model.stateURL.path)[.systemFileNumber]) as? NSNumber)
        XCTAssertEqual(after,before,"An empty Gmail history page must not atomically replace a 77 MB sender library")
        XCTAssertEqual(model.gmail.accounts.first?.cursor.historyID,"501")
        XCTAssertEqual(model.gmail.accounts.first?.cursor.lastCheck,checked)
    }
    @MainActor func testOpeningAndSavingAnUnchangedLibraryDoesNotReplaceIt()throws {
        let temp=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:temp)}
        try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true)
        let row=SenderRow(email:EmailAddress("billing@raycast.com")!,name:"Raycast",discoveryOrder:1,discoveredAt:Date())
        let url=temp.appendingPathComponent("senders.json")
        try JSONEncoder().encode([row]).write(to:url,options:.atomic)
        let before=try XCTUnwrap((try FileManager.default.attributesOfItem(atPath:url.path)[.systemFileNumber]) as? NSNumber)
        let restored=AppModel(demo:true,rootOverride:temp,backgroundWorkAllowed:false)
        restored.save()
        let after=try XCTUnwrap((try FileManager.default.attributesOfItem(atPath:url.path)[.systemFileNumber]) as? NSNumber)
        XCTAssertEqual(after,before,"Opening and checkpointing an unchanged library must not rewrite every image")
    }
    @MainActor func testExistingSenderReceiptUpdatePersistsWithoutReplacingImageLibrary()async throws {
        let temp=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:temp)}
        let model=AppModel(demo:true,rootOverride:temp,backgroundWorkAllowed:false)
        let email=EmailAddress("invitations@linkedin.com")!
        model.rows=[SenderRow(email:email,name:"LinkedIn",discoveryOrder:1,lastInboxReceivedAt:Date(timeIntervalSince1970:1))]
        model.gmail.accounts=[GmailAccount(id:"fixture",email:"fixture@gmail.com")]
        model.save()
        let before=try XCTUnwrap((try FileManager.default.attributesOfItem(atPath:model.stateURL.path)[.systemFileNumber]) as? NSNumber)
        let incoming=try JSONDecoder().decode(GmailMessage.self,from:Data(self.message.utf8))
        try await model.ingestGmail(GmailBatch(messages:[incoming],cursor:GmailCursor(historyID:"502"),hasMore:false),accountID:"fixture")
        let after=try XCTUnwrap((try FileManager.default.attributesOfItem(atPath:model.stateURL.path)[.systemFileNumber]) as? NSNumber)
        XCTAssertEqual(after,before,"A receipt-only update must not atomically replace an image-bearing library")
        let restored=AppModel(demo:true,rootOverride:temp,backgroundWorkAllowed:false)
        XCTAssertEqual(restored.rows.first?.lastInboxReceivedAt,incoming.received)
        XCTAssertEqual(restored.gmail.accounts.first?.cursor.historyID,"502")
    }
    @MainActor func testOpeningImageLibraryPublishesDecodedRowsOnlyOnce()throws {
        let temp=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:temp)}
        try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true)
        let avatar=try NameAvatar.candidate(name:"Fixture")
        let rows=(0..<120).map { i in SenderRow(email:EmailAddress("emblem-fixture-\(String(i))@gmail.com")!,name:"Sender \(String(i))",candidates:[avatar],selectedCandidate:avatar.id,selectionIsManual:true,discoveryOrder:i) }
        try JSONEncoder().encode(rows).write(to:temp.appendingPathComponent("senders.json"),options:.atomic)
        let restored=AppModel(demo:true,rootOverride:temp,backgroundWorkAllowed:false)
        XCTAssertEqual(restored.rows.count,120)
        XCTAssertEqual(restored.rowsRevision,2,"Only property initialization and the complete decoded library should publish")
    }
    func testKeychainRoundTripUsesOnlyDisposableFixtureData()throws {
        let id="test-"+UUID().uuidString
        defer {try? GmailKeychain.delete(id)}
        XCTAssertNil(try GmailKeychain.read(id))
        try GmailKeychain.save(Data("local fixture only".utf8),account:id)
        XCTAssertEqual(try GmailKeychain.read(id),Data("local fixture only".utf8))
        try GmailKeychain.save(Data("updated fixture".utf8),account:id)
        XCTAssertEqual(try GmailKeychain.read(id),Data("updated fixture".utf8))
        try GmailKeychain.delete(id);XCTAssertNil(try GmailKeychain.read(id))
    }
    @MainActor func testAutomaticMonogramCanRefreshButManualAndExternalPhotosAreProtected()async throws {
        let temp=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:temp)}
        let model=AppModel(demo:true,rootOverride:temp,backgroundWorkAllowed:false)
        let photo=try NameAvatar.candidate(name:"Fastlink")
        let contact=try model.port.create(name:"Fastlink",email:"hello@fastlink.com",image:photo.png)
        let row=SenderRow(email:EmailAddress("hello@fastlink.com")!,name:"Fastlink",completed:true,candidates:[photo],selectedCandidate:photo.id,selectionIsManual:false,current:contact)
        model.rows=[row]
        model.mailSync.links=[MailSyncLink(key:"fixture",contactID:contact.id,emails:[row.id],createdByApp:true,imageHash:digest(contact.image),desiredHash:digest(photo.png))]
        XCTAssertTrue(model.managedFallbackIDs().contains(row.id))
        XCTAssertTrue(AutomaticLookupPolicy.due(row,website:true,gravatar:true,now:Date(),managedFallback:true))
        model.rows[0].selectionIsManual=true;XCTAssertTrue(model.managedFallbackIDs().isEmpty)
        model.rows[0].selectionIsManual=false;model.mailSync.links[0].externalPhoto=true
        XCTAssertTrue(model.managedFallbackIDs().isEmpty)
    }

    @MainActor func testManagedMonogramLookupCommitsResultAndTerminates()async throws {
        let temp=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:temp)}
        let resolver=AvatarResolver(client:V016OfflineOnly())
        let model=AppModel(demo:false,rootOverride:temp,resolverFactory:{resolver})
        model.useWebsite=true;model.useGravatar=false
        let photo=try NameAvatar.candidate(name:"Claude")
        let contact=ContactSnapshot(id:"disposable-fixture",name:"Claude",emails:["no-reply@email.claude.com"],image:photo.png)
        let row=SenderRow(email:EmailAddress("no-reply@email.claude.com")!,name:"Claude",completed:true,candidates:[photo],selectedCandidate:photo.id,current:contact)
        model.rows=[row];model.automation.setupComplete=true
        model.mailSync.links=[MailSyncLink(key:"fixture",contactID:contact.id,emails:[row.id],createdByApp:true,imageHash:digest(contact.image),desiredHash:digest(photo.png))]
        let job=Task {try? await model.automaticallyResolve(now:Date())}
        let timeout=Task {try? await Task.sleep(for:.seconds(2));if !Task.isCancelled {job.cancel()}}
        await job.value;timeout.cancel()
        XCTAssertEqual(model.rows[0].chosen?.source,.officialBrand)
        XCTAssertNotNil(model.rows[0].lastLookup)
        XCTAssertEqual(model.automaticFinished,1)
        XCTAssertTrue(try model.engine.records().isEmpty)
    }

}

private actor V016OfflineOnly:ResourceFetching {
    func fetch(_ url:URL,limit:Int)async throws->WebResource {throw PortraitError.message("No network in this fixture")}
}
