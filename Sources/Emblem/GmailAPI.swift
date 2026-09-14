import Foundation
import PortraitCore

struct GmailCursor: Codable, Equatable, Sendable {
    var historyID: String?
    var bootstrapHistoryID: String?
    var pageToken: String?
    var historyPageToken: String?
    var lastCheck: Date?
    var retryAfter: Date?
}
struct GmailAccount: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var email: String
    var cursor = GmailCursor()
    var issue: String?
    var push: GmailPushState?
    var pushIssue: String?
    var pushRetryAfter: Date?
}
struct GmailConnections: Codable, Sendable { var accounts: [GmailAccount] = [] }
struct GmailHeader: Codable, Sendable { var name: String; var value: String }
struct GmailMessage: Decodable, Sendable {
    struct Payload: Decodable, Sendable { var headers: [GmailHeader]? }
    var id: String
    var labelIds: [String]?
    var internalDate: String?
    var payload: Payload?
    var sender: String? { payload?.headers?.first { $0.name.caseInsensitiveCompare("From") == .orderedSame }?.value }
    var received: Date? { internalDate.flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) } }
}
struct GmailProfile: Decodable, Sendable { var emailAddress: String; var historyId: String }
struct GmailWatchResponse: Sendable {
    var historyId: String
    var expiration: Date
}
struct GmailBatch: Sendable { var messages: [GmailMessage]; var cursor: GmailCursor; var hasMore: Bool }
struct GmailHTTPError: Error, LocalizedError, Sendable {
    var status: Int
    var errorDescription: String? {
        switch status {
        case 401: return "Sign in to Gmail again to resume syncing."
        case 403: return "Gmail access is not available. Check the account permission and Google API configuration."
        case 429: return "Gmail is busy. Sync will retry shortly."
        default: return "Gmail did not complete this check (HTTP \(status)). Sync will retry."
        }
    }
}
protocol GmailHTTPTransport: Sendable { func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) }
final class GmailURLSession: NSObject, GmailHTTPTransport, URLSessionTaskDelegate, @unchecked Sendable {
    private lazy var session: URLSession = {
        let c=URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest=25; c.timeoutIntervalForResource=40
        c.httpCookieStorage=nil; c.urlCredentialStorage=nil; c.urlCache=nil
        return URLSession(configuration:c,delegate:self,delegateQueue:nil)
    }()
    func data(for request:URLRequest)async throws->(Data,HTTPURLResponse) {
        let (data,response)=try await session.data(for:request)
        guard let response=response as? HTTPURLResponse,data.count<=5_000_000 else {throw PortraitError.message("Gmail returned an unexpected response.")}
        return (data,response)
    }
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping (URLRequest?)->Void) {completionHandler(nil)}
}
/// Read-only metadata scope: no body, subject, attachment, send or modify endpoints.
struct GmailAPI: Sendable {
    static let scope="https://www.googleapis.com/auth/gmail.metadata"
    var transport: any GmailHTTPTransport = GmailURLSession()
    private func get<T:Decodable>(_ path:String,query:[URLQueryItem]=[],token:String)async throws->T {
        var url=URLComponents(string:"https://gmail.googleapis.com/gmail/v1/users/me/"+path)!
        url.queryItems=query.isEmpty ? nil:query
        var request=URLRequest(url:url.url!);request.setValue("Bearer "+token,forHTTPHeaderField:"Authorization")
        request.setValue("application/json",forHTTPHeaderField:"Accept")
        let (data,response)=try await transport.data(for:request)
        guard response.statusCode==200 else {throw GmailHTTPError(status:response.statusCode)}
        return try JSONDecoder().decode(T.self,from:data)
    }
    private func post<T:Decodable>(_ path:String,body:[String:Any],token:String)async throws->T {
        let url=URL(string:"https://gmail.googleapis.com/gmail/v1/users/me/"+path)!
        var request=URLRequest(url:url);request.httpMethod="POST"
        request.setValue("Bearer "+token,forHTTPHeaderField:"Authorization")
        request.setValue("application/json",forHTTPHeaderField:"Accept")
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.httpBody=try JSONSerialization.data(withJSONObject:body)
        let (data,response)=try await transport.data(for:request)
        guard response.statusCode==200 else {throw GmailHTTPError(status:response.statusCode)}
        return try JSONDecoder().decode(T.self,from:data)
    }
    func profile(token:String)async throws->GmailProfile {
        try await get("profile",query:[.init(name:"fields",value:"emailAddress,historyId")],token:token)
    }
    func watch(token:String,topicName:String)async throws->GmailWatchResponse {
        guard topicName.range(of:#"^projects/[a-z][a-z0-9-]{4,29}/topics/[A-Za-z][A-Za-z0-9._~-]{2,254}$"#,options:.regularExpression) != nil else {throw PortraitError.message("Gmail watch configuration is invalid.")}
        struct Wire:Decodable {var historyId:String;var expiration:String}
        let wire:Wire=try await post("watch",body:["topicName":topicName,"labelIds":["INBOX"],"labelFilterBehavior":"INCLUDE"],token:token)
        guard GmailPushBackend.validHistory(wire.expiration),let millis=Double(wire.expiration),millis.isFinite,millis>0,millis<253_402_300_800_000,GmailPushBackend.validHistory(wire.historyId) else {throw PortraitError.message("Gmail returned an invalid watch response.")}
        return GmailWatchResponse(historyId:wire.historyId,expiration:Date(timeIntervalSince1970:millis/1000))
    }
    private struct Page:Decodable {struct ID:Decodable {var id:String}; var messages:[ID]?;var nextPageToken:String?}
    private struct HistoryPage:Decodable {
        struct History:Decodable {
            struct Added:Decodable {var message:GmailMessage;var labelIds:[String]?}
            var messagesAdded:[Added]?;var labelsAdded:[Added]?
        }
        var history:[History]?;var historyId:String;var nextPageToken:String?
    }
    func batch(cursor initial:GmailCursor,token:String,now:Date=Date())async throws->GmailBatch {
        var cursor=initial;var ids:[String]=[];var more=false
        if let history=cursor.historyID {
            var query=[URLQueryItem(name:"startHistoryId",value:history),.init(name:"maxResults",value:"100"),.init(name:"historyTypes",value:"messageAdded"),.init(name:"historyTypes",value:"labelAdded"),.init(name:"fields",value:"history(messagesAdded/message(id,labelIds),labelsAdded(message(id,labelIds),labelIds)),historyId,nextPageToken")]
            if let page=cursor.historyPageToken {query.append(.init(name:"pageToken",value:page))}
            do {
                let page:HistoryPage=try await get("history",query:query,token:token)
                for entry in page.history ?? [] {
                    ids += (entry.messagesAdded ?? []).filter { $0.message.labelIds?.contains("INBOX") != false }.map { $0.message.id }
                    ids += (entry.labelsAdded ?? []).filter { $0.labelIds?.contains("INBOX") == true }.map { $0.message.id }
                }
                cursor.historyPageToken=page.nextPageToken;more=page.nextPageToken != nil
                if !more {cursor.historyID=page.historyId}
            } catch let e as GmailHTTPError where e.status==404 || (e.status==400 && cursor.historyPageToken != nil) {
                // An expired history cursor is recoverable. Never remove discovered senders.
                return try await batch(cursor:GmailCursor(),token:token,now:now)
            }
        } else {
            if cursor.bootstrapHistoryID == nil {cursor.bootstrapHistoryID=try await profile(token:token).historyId}
            var query=[URLQueryItem(name:"labelIds",value:"INBOX"),.init(name:"maxResults",value:"100"),.init(name:"fields",value:"messages/id,nextPageToken")]
            if let page=cursor.pageToken {query.append(.init(name:"pageToken",value:page))}
            let page:Page
            do {page=try await get("messages",query:query,token:token)}
            catch let e as GmailHTTPError where e.status==400 && cursor.pageToken != nil {return try await batch(cursor:GmailCursor(),token:token,now:now)}
            ids=(page.messages ?? []).map(\.id);cursor.pageToken=page.nextPageToken;more=page.nextPageToken != nil
            if !more {cursor.historyID=cursor.bootstrapHistoryID;cursor.bootstrapHistoryID=nil}
        }
        var seen=Set<String>();ids=ids.filter {seen.insert($0).inserted}
        let messages=try await metadata(ids:ids,token:token)
        cursor.lastCheck=now;cursor.retryAfter=nil
        return GmailBatch(messages:messages,cursor:cursor,hasMore:more)
    }
    private func metadata(ids:[String],token:String)async throws->[GmailMessage] {
        try await withThrowingTaskGroup(of:GmailMessage?.self) { group in
            var next=0;var results:[GmailMessage]=[]
            func enqueue(_ id:String) {
                group.addTask {
                    guard !id.isEmpty,id.allSatisfy({$0.isHexDigit}) else {throw PortraitError.message("Gmail returned an invalid message identifier.")}
                    do {
                        let message:GmailMessage=try await get("messages/"+id,query:[.init(name:"format",value:"metadata"),.init(name:"metadataHeaders",value:"From"),.init(name:"fields",value:"id,labelIds,internalDate,payload/headers")],token:token)
                        return message.labelIds?.contains("INBOX") == true ? message:nil
                    } catch let e as GmailHTTPError where e.status==404 {return nil}
                }
            }
            while next<min(4,ids.count) {enqueue(ids[next]);next+=1}
            while let value=try await group.next() {
                if let value {results.append(value)}
                try Task.checkCancellation()
                if next<ids.count {enqueue(ids[next]);next+=1}
            }
            return results.sorted {($0.received ?? .distantPast)>($1.received ?? .distantPast)}
        }
    }
}
