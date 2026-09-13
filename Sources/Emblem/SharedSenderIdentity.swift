import Foundation
import PortraitCore

/// A notification relay is an address owned by a service, not the individual
/// named in a particular From header. Never make that transient person the card.
enum SharedSenderIdentity {
    static func serviceName(email:EmailAddress,displayName:String)->String? {
        let host=DomainRouting.primaryHost(for:email.domain)
        let local=email.value.split(separator:"@")[0].lowercased()
        let relays:Set<String>=["invitations","invitation","invites","inmail-hit-reply"]
        if host == "linkedin.com",relays.contains(local) {return "LinkedIn"}
        // General relay rule: a role mailbox + an explicit 'via Service' label,
        // and the named service agrees with the registrable domain. Personal
        // employee addresses and shared mailbox providers aren't rewritten.
        let roles=relays.union(["notifications","notification","messages","notify","noreply","no-reply"])
        guard !email.isSharedProvider,roles.contains(local),let range=displayName.range(of:" via ",options:[.caseInsensitive,.backwards]) else{return nil}
        let service=String(displayName[range.upperBound...]).trimmingCharacters(in:.whitespacesAndNewlines)
        let normalized=service.lowercased().filter{$0.isLetter || $0.isNumber}
        guard !normalized.isEmpty,normalized == host.split(separator:".").first.map(String.init) else{return nil}
        return service
    }
    static func contactName(email:EmailAddress,displayName:String)->String {serviceName(email:email,displayName:displayName) ?? displayName}
}

extension AppModel {
    func repairSharedSenderNames()throws {
        let owned=Set(records.filter{$0.created && $0.state == .applied}.compactMap(\.contactID))
        let grouped=Dictionary(grouping:rows.indices.compactMap {i -> (Int,String)? in
            guard let c=rows[i].current,owned.contains(c.id),let name=SharedSenderIdentity.serviceName(email:rows[i].email,displayName:rows[i].name),c.name != name,c.name==rows[i].name else{return nil}
            return (i,c.id)
        },by:{$0.1})
        for (_,indices) in grouped {
            let row=rows[indices[0].0]
            guard let current=row.current else{continue}
            do {
                if let record=try engine.renameCreatedContact(contactID:current.id,expectedName:current.name,name:row.displayName,expectedEmails:current.emails) {
                    records.append(record)
                    let fresh=try port.get(id:current.id)
                    var replacement=rows
                    for i in replacement.indices where replacement[i].current?.id==current.id {replacement[i].current=fresh}
                    rows=replacement
                }
            } catch {syncAttention=error.localizedDescription}
        }
    }
}
