import Foundation
import PortraitCore

struct MailParticipant:Sendable {
    var email:EmailAddress
    var name:String
    var inboxReceivedAt:Date?
}

enum MailParticipants {
    /// Split address lists without splitting quoted display names ("Doe, Jane")
    /// or angle addresses. Names are evidence for this address only.
    static func recipients(_ headers:[String],excluding own:Set<String>)->[MailParticipant] {
        let excluded=Set(own.map{$0.lowercased()})
        var seen=Set<String>(),result:[MailParticipant]=[]
        for header in headers {
            var segments:[String]=[],segment="",quoted=false,escaped=false,angle=0
            for character in header {
                if escaped {segment.append(character);escaped=false;continue}
                if character=="\\",quoted {segment.append(character);escaped=true;continue}
                if character=="\"" {quoted.toggle()}
                if !quoted {
                    if character=="<" {angle+=1}
                    if character==">" {angle=max(0,angle-1)}
                    if angle==0 && character==":" {segment="";continue}
                    if angle==0 && [",",";","\n"].contains(character) {segments.append(segment);segment="";continue}
                }
                segment.append(character)
            }
            segments.append(segment)
            for raw in segments {
                // An ambiguous malformed address token is not a contact.
                let addresses=EmailAddress.parseList(raw)
                guard addresses.count==1,let email=addresses.first,
                      !excluded.contains(email.value.lowercased()),seen.insert(email.value).inserted else{continue}
                let token=raw
                result.append(.init(email:email,name:email.suggestedDisplayName(in:token),inboxReceivedAt:nil))
            }
        }
        return result
    }
    static func gmail(_ message:GmailMessage,ownEmails:Set<String>)->[MailParticipant] {
        let labels=Set(message.labelIds ?? [])
        guard labels.isDisjoint(with:["SPAM","TRASH"]) else{return []}
        // Outgoing recipients never become inbox receipt dates or aliases of
        // the sender. The actual From also excludes send-as aliases of this account.
        if labels.contains("SENT") {
            let own=ownEmails.union(EmailAddress.parseList(message.sender ?? "").map(\.value))
            let headers=(message.payload?.headers ?? []).filter{["to","cc"].contains($0.name.lowercased())}.map(\.value)
            return recipients(headers,excluding:own)
        }
        guard labels.contains("INBOX"),let sender=message.sender,let date=message.received,
              EmailAddress.parseList(sender).count==1,let email=EmailAddress.parseList(sender).first else{return []}
        return [.init(email:email,name:email.suggestedDisplayName(in:sender),inboxReceivedAt:date)]
    }
}
