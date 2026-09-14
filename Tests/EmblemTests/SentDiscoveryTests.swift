import AppKit

import XCTest
import PortraitCore
@testable import Emblem

private actor SentTransport:GmailHTTPTransport {
    var requests:[URLRequest]=[]
    func data(for request:URLRequest)async throws->(Data,HTTPURLResponse) {
        requests.append(request)
        let body:String
        switch request.url!.lastPathComponent {
        case "watch": body=#"{"historyId":"101","expiration":"1789344000000"}"#
        case "history": body=#"{"historyId":"101","history":[{"messagesAdded":[{"message":{"id":"abc","labelIds":["SENT"]}}]}]}"#
        default: body=sentMessage
        }
        return (Data(body.utf8),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
    }
}
private let sentMessage=#"{"id":"abc","labelIds":["SENT"],"internalDate":"1789286400000","payload":{"headers":[{"name":"From","value":"My Alias <alias@protoyard.com>"},{"name":"To","value":"\"Doe, Jane\" <jane@protoyard.com>, My Alias <alias@protoyard.com>"},{"name":"Cc","value":"Sam <sam@protoyard.com>, jane@protoyard.com, Me <me@gmail.com>"},{"name":"Bcc","value":"hidden@protoyard.com"}]}}"#
final class SentDiscoveryTests:XCTestCase {
    func testSentHistoryRequestsRecipientMetadataWithoutExpandingScope()async throws {
        let transport=SentTransport()
        let batch=try await GmailAPI(transport:transport).batch(cursor:.init(historyID:"100"),token:"fixture")
        XCTAssertEqual(batch.messages.count,1)
        let requests=await transport.requests
        XCTAssertEqual(requests.count,2)
        let headers=Set(URLComponents(url:try XCTUnwrap(requests.last?.url),resolvingAgainstBaseURL:false)!.queryItems!.filter{$0.name=="metadataHeaders"}.compactMap(\.value))
        XCTAssertEqual(headers,["From","To","Cc"])
        XCTAssertEqual(GmailAPI.scope,"https://www.googleapis.com/auth/gmail.metadata")
    }
    func testWatchIncludesSentAsWellAsInbox()async throws {
        let transport=SentTransport()
        _=try await GmailAPI(transport:transport).watch(token:"fixture",topicName:"projects/fixture-project/topics/emblem-gmail-events")
        let requests=await transport.requests
        let json=try JSONSerialization.jsonObject(with:XCTUnwrap(requests.first?.httpBody)) as! [String:Any]
        XCTAssertEqual(json["labelIds"] as? [String],["INBOX","SENT"])
    }
    @MainActor func testSentRecipientsAreDiscoveredWithoutSelfBCCOrInboxReordering()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let m=AppModel(demo:true,rootOverride:root,backgroundWorkAllowed:false)
        let receipt=Date(timeIntervalSince1970:100)
        m.rows=[SenderRow(email:EmailAddress("sam@protoyard.com")!,name:"Sam",lastInboxReceivedAt:receipt)]
        m.gmail.accounts=[GmailAccount(id:"fixture",email:"me@gmail.com")]
        let sent=try JSONDecoder().decode(GmailMessage.self,from:Data(sentMessage.utf8))
        try await m.ingestGmail(.init(messages:[sent,sent],cursor:.init(historyID:"101"),hasMore:false),accountID:"fixture")
        XCTAssertEqual(Set(m.rows.map(\.id)),["jane@protoyard.com","sam@protoyard.com"])
        XCTAssertEqual(m.rows.first{$0.id=="jane@protoyard.com"}?.name,"Doe, Jane")
        XCTAssertNil(m.rows.first{$0.id=="jane@protoyard.com"}?.lastInboxReceivedAt)
        XCTAssertEqual(m.rows.first{$0.id=="sam@protoyard.com"}?.lastInboxReceivedAt,receipt)
        XCTAssertEqual(SenderGrouping.groups(m.rows).first?.representative.id,"sam@protoyard.com")
        XCTAssertTrue(m.rows.allSatisfy{$0.syncEligible != false})
        let reopened=AppModel(demo:true,rootOverride:root,backgroundWorkAllowed:false)
        XCTAssertEqual(Set(reopened.rows.map(\.id)),["jane@protoyard.com","sam@protoyard.com"])
        XCTAssertEqual(reopened.gmail.accounts.first?.cursor.historyID,"101")
        XCTAssertTrue(try m.engine.records().isEmpty)
    }
}

private actor SentMailScanner:MailScannerPort {
    var sentCalls=0
    func inventory(source:ScanSource)async throws->MailScanInventory {.init(mailboxes:[],warnings:[])}
    func page(mailbox:MailScanMailbox,start:Int,size:Int)async throws->MailScanPage {.init(senders:[],currentCount:0)}
    func sentPage(start:Int,size:Int,excludingAccountEmails:Set<String>)async throws->MailScanPage? {
        sentCalls+=1
        return .init(senders:["Jane <jane@protoyard.com>\nSam <sam@protoyard.com>\nignored@protoyard.com"],currentCount:1,receivedAt:[Date()])
    }
}
private struct NoSentContacts:ContactsScannerPort {
    func batches()->AsyncThrowingStream<[ContactSnapshot],Error> {AsyncThrowingStream{$0.finish()}}
}
extension SentDiscoveryTests {
    @MainActor func testAppleMailAutomaticallyDiscoversSentRecipientsAndHonorsIgnore()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let scanner=SentMailScanner()
        let m=AppModel(demo:false,rootOverride:root,mailScanner:scanner,contactScanner:NoSentContacts(),backgroundWorkAllowed:false)
        m.automation.setupComplete=true;m.automation.contacts=false;m.automation.excludedEmails=["ignored@protoyard.com"]
        m.useWebsite=false;m.useGravatar=false;m.mailSync.enabled=false;m.allowsHistoryScan=false
        try await m.automaticallyDiscover(now:Date())
        XCTAssertEqual(Set(m.rows.map(\.id)),["jane@protoyard.com","sam@protoyard.com"])
        XCTAssertTrue(m.rows.allSatisfy{$0.lastInboxReceivedAt==nil && $0.syncEligible != false})
        let calls=await scanner.sentCalls
        XCTAssertEqual(calls,1)
        let reopened=AppModel(demo:true,rootOverride:root,backgroundWorkAllowed:false)
        XCTAssertEqual(Set(reopened.rows.map(\.id)),["jane@protoyard.com","sam@protoyard.com"])
        XCTAssertTrue(try m.engine.records().isEmpty)
    }
}

private actor SentPageTransport:GmailHTTPTransport {
    var pages:[(Int,String)]
    var requests:[URLRequest]=[]
    init(_ pages:[(Int,String)]) {self.pages=pages}
    func data(for request:URLRequest)async throws->(Data,HTTPURLResponse) {
        requests.append(request)
        let result:(Int,String)
        if request.url!.lastPathComponent=="messages" {result=pages.removeFirst()}
        else if request.url!.lastPathComponent=="history" {result=(200,#"{"historyId":"102"}"#)}
        else {result=(200,sentMessage)}
        return (Data(result.1.utf8),HTTPURLResponse(url:request.url!,statusCode:result.0,httpVersion:nil,headerFields:nil)!)
    }
}
extension SentDiscoveryTests {
    @MainActor func testAppleMailSentScriptCompilesAndReadsNoBodiesOrBCC()throws {
        let script=try XCTUnwrap(NSAppleScript(source:MailScanScripts.source))
        var error:NSDictionary?
        XCTAssertTrue(script.compileAndReturnError(&error),error?.description ?? "")
        XCTAssertTrue(MailScanScripts.source.contains("sent mailbox"))
        XCTAssertTrue(MailScanScripts.source.contains("to recipients of messageRef"))
        XCTAssertTrue(MailScanScripts.source.contains("cc recipients of messageRef"))
        XCTAssertFalse(MailScanScripts.source.contains("bcc recipients"))
        XCTAssertFalse(MailScanScripts.source.contains("content of"))
        XCTAssertFalse(MailScanScripts.source.contains("subject of"))
    }
    func testLegacySentBackfillPreservesInboxAndHistoryPagination()async throws {
        let original=try JSONDecoder().decode(GmailCursor.self,from:Data(#"{"historyID":"100","historyPageToken":"history-next","lastCheck":20}"#.utf8))
        XCTAssertNil(original.sentBootstrapComplete)
        let transport=SentPageTransport([(200,#"{"messages":[{"id":"abc"}],"nextPageToken":"sent-next"}"#),(200,"{}")])
        let api=GmailAPI(transport:transport)
        let first=try await api.sentBatch(cursor:original,token:"fixture")
        XCTAssertEqual(first.messages.count,1);XCTAssertTrue(first.hasMore)
        XCTAssertEqual(first.cursor.historyID,original.historyID)
        XCTAssertEqual(first.cursor.historyPageToken,original.historyPageToken)
        XCTAssertEqual(first.cursor.lastCheck,original.lastCheck)
        XCTAssertEqual(first.cursor.sentPageToken,"sent-next")
        let second=try await api.sentBatch(cursor:first.cursor,token:"fixture")
        XCTAssertFalse(second.hasMore);XCTAssertEqual(second.cursor.sentBootstrapComplete,true)
        XCTAssertNil(second.cursor.sentPageToken)
        let requests=await transport.requests
        let lists=requests.filter{$0.url!.lastPathComponent=="messages"}
        XCTAssertEqual(lists.count,2)
        let query=URLComponents(url:lists[1].url!,resolvingAgainstBaseURL:false)!.queryItems!
        XCTAssertTrue(query.contains(.init(name:"labelIds",value:"SENT")))
        XCTAssertTrue(query.contains(.init(name:"pageToken",value:"sent-next")))
    }
    @MainActor func testSentArchiveFailureDoesNotBackoffIncomingHistory()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let now=Date(),transport=SentPageTransport([(429,"{}")])
        let m=AppModel(demo:false,rootOverride:root)
        m.mailSync.enabled=false;m.automation.setupComplete=true;m.automation.mail=false;m.automation.contacts=false
        m.useWebsite=false;m.useGravatar=false;m.gmailTokenProvider={_ in "fixture"}
        m.gmail.accounts=[.init(id:"fixture",email:"me@gmail.com",cursor:.init(historyID:"100"))]
        m.gmailAPI=GmailAPI(transport:transport)
        m.kickGmailSync(now:now);await m.gmailSyncTask?.value
        XCTAssertEqual(m.gmail.accounts[0].cursor.historyID,"102")
        XCTAssertNil(m.gmail.accounts[0].issue);XCTAssertNil(m.gmail.accounts[0].cursor.retryAfter)
        XCTAssertEqual(m.gmail.accounts[0].cursor.sentRetryAfter,now.addingTimeInterval(300))
        m.kickGmailSync(now:now.addingTimeInterval(61));await m.gmailSyncTask?.value
        let requests=await transport.requests
        XCTAssertEqual(requests.filter{$0.url!.lastPathComponent=="history"}.count,2)
        XCTAssertEqual(requests.filter{$0.url!.lastPathComponent=="messages"}.count,1)
        XCTAssertTrue(try m.engine.records().isEmpty)
    }
    @MainActor func testOutgoingPhotoUsesAutomaticSyncAndCreatesOnlyOneFixtureCard()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let m=AppModel(demo:true,rootOverride:root,backgroundWorkAllowed:false)
        m.gmail.accounts=[.init(id:"fixture",email:"me@gmail.com")]
        m.automation.setupComplete=true;m.mailSync.enabled=true;m.useWebsite=true
        let sent=try JSONDecoder().decode(GmailMessage.self,from:Data(sentMessage.utf8))
        try await m.ingestGmail(.init(messages:[sent],cursor:.init(historyID:"101"),hasMore:false),accountID:"fixture")
        XCTAssertTrue(m.rows.allSatisfy{AutomaticLookupPolicy.due($0,website:true,gravatar:true,now:Date())})
        let photo=try NameAvatar.candidate(name:"Jane")
        for i in m.rows.indices {m.rows[i].candidates=[photo];m.rows[i].selectedCandidate=photo.id;m.rows[i].lastLookup=Date()}
        try await m.performMailSync();try await m.performMailSync()
        XCTAssertEqual(try m.port.matches(email:"jane@protoyard.com").count,1)
        XCTAssertEqual(try m.port.matches(email:"sam@protoyard.com").count,1)
        XCTAssertEqual(try m.port.matches(email:"alias@protoyard.com").count,0)
        let count=try m.engine.records().count
        XCTAssertEqual(count,2)
        XCTAssertTrue(m.rows.allSatisfy{$0.current?.image != nil})
        XCTAssertTrue(m.rows.allSatisfy{$0.lastInboxReceivedAt==nil})
    }
    func testSentSpamTrashAndMalformedRecipientsAreNotEnrolled()throws {
        var message=try JSONDecoder().decode(GmailMessage.self,from:Data(sentMessage.utf8))
        message.labelIds=["SENT","SPAM"]
        XCTAssertTrue(MailParticipants.gmail(message,ownEmails:[]).isEmpty)
        message.labelIds=["SENT","TRASH"]
        XCTAssertTrue(MailParticipants.gmail(message,ownEmails:[]).isEmpty)
        let parsed=MailParticipants.recipients(["Friends: \"Doe, Jane\" <jane@protoyard.com>; malformed <one@protoyard.com two@protoyard.com>"],excluding:[])
        XCTAssertEqual(parsed.map(\.email.value),["jane@protoyard.com"])
        XCTAssertEqual(parsed.first?.name,"Doe, Jane")
    }
}

private actor SlowSentArchive:GmailHTTPTransport {
    var archiveStarted=false
    var archiveCancelled=false
    var historyReads=0
    func data(for request:URLRequest)async throws->(Data,HTTPURLResponse) {
        let body:String
        if request.url!.lastPathComponent=="messages" {
            archiveStarted=true
            do {try await Task.sleep(for:.seconds(10))}
            catch {archiveCancelled=true;throw error}
            body="{}"
        } else {historyReads+=1;body="{\"historyId\":\"\(100+historyReads)\"}"}
        return (Data(body.utf8),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
    }
}
extension SentDiscoveryTests {
    @MainActor func testNewMailHintPreemptsSlowSentArchive()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let transport=SlowSentArchive(),m=AppModel(demo:false,rootOverride:root)
        m.automation.setupComplete=true;m.automation.mail=false;m.automation.contacts=false;m.mailSync.enabled=false
        m.useWebsite=false;m.useGravatar=false;m.gmailTokenProvider={_ in "fixture"}
        m.gmail.accounts=[.init(id:"fixture",email:"me@gmail.com",cursor:.init(historyID:"100"))]
        m.gmailAPI=GmailAPI(transport:transport)
        m.kickGmailSync()
        for _ in 0..<100 {if await transport.archiveStarted {break};try await Task.sleep(for:.milliseconds(5))}
        let started=await transport.archiveStarted;XCTAssertTrue(started)
        m.noteGmailPush(accountID:"fixture",historyID:"999")
        for _ in 0..<100 {if m.gmail.accounts[0].cursor.historyID=="102" {break};try await Task.sleep(for:.milliseconds(5))}
        let serviced=m.gmail.accounts[0].cursor.historyID=="102",cancelled=await transport.archiveCancelled
        m.gmailSyncTask?.cancel();await m.gmailSyncTask?.value
        XCTAssertTrue(serviced,"A new-mail hint must not wait for a ten-second archive request")
        XCTAssertTrue(cancelled,"Archive work should yield to new mailbox activity")
        XCTAssertNil(m.gmail.accounts[0].cursor.retryAfter)
        XCTAssertNil(m.gmail.accounts[0].cursor.sentRetryAfter)
    }
}
