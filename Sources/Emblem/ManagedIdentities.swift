import Foundation
import PortraitCore

struct ManagedIdentity: Codable, Identifiable, Sendable {
    var id: String { key }
    let key: String
    let name: String
    let domain: String
    let contactID: String
    var knownEmails: Set<String>
}

enum ManagedIdentityScope {
    static func normalizedName(_ name:String) -> String {
        name.split(whereSeparator:\.isWhitespace).joined(separator:" ").lowercased()
    }
    static func key(_ row:SenderRow) -> String? {
        let name=normalizedName(row.name),local=row.id.split(separator:"@").first.map(String.init)?.lowercased() ?? ""
        guard !name.isEmpty,name != row.id.lowercased(),name != local,!name.contains("@"),!row.email.isSharedProvider else { return nil }
        return name + "|" + DomainRouting.primaryHost(for:row.email.domain)
    }
}

extension AppModel {
    var managedURL:URL { root.appendingPathComponent("managed-identities.json") }
    func loadManagedIdentities() throws {
        guard FileManager.default.fileExists(atPath:managedURL.path) else { return }
        managedIdentities=try JSONDecoder().decode([ManagedIdentity].self,from:Data(contentsOf:managedURL))
    }
    func saveManagedIdentities() throws {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try JSONEncoder().encode(managedIdentities).write(to:managedURL,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:managedURL.path)
    }
    func manageIdentity(key:String,name:String,contact:ContactSnapshot,emails:[String]) throws {
        let domain=key.split(separator:"|").last.map(String.init) ?? ""
        let item=ManagedIdentity(key:key,name:name,domain:domain,contactID:contact.id,knownEmails:Set(emails))
        if let index=managedIdentities.firstIndex(where:{ $0.key == key }) { managedIdentities[index]=item }
        else { managedIdentities.append(item) }
        try saveManagedIdentities()
    }
    func syncManagedAliases() {
        guard contactsConnected,!busy,!isScanning,!managedIdentities.isEmpty else { return }
        do {
            var changed=false
            for identityIndex in managedIdentities.indices {
                let key=managedIdentities[identityIndex].key
                let matching=rows.filter { !$0.ignored && ManagedIdentityScope.key($0) == key }
                let emails=matching.map(\.email)
                if let record=try engine.appendManagedAliases(contactID:managedIdentities[identityIndex].contactID,emails:emails,managedKey:key) {
                    records.append(record);changed=true
                }
                guard let contact=try port.get(id:managedIdentities[identityIndex].contactID) else { continue }
                managedIdentities[identityIndex].knownEmails=Set(contact.emails)
                let ids=Set(matching.map(\.id))
                for rowIndex in rows.indices where ids.contains(rows[rowIndex].id) {
                    rows[rowIndex].current=contact;rows[rowIndex].completed=true;rows[rowIndex].status="Linked to One Managed Contact"
                }
            }
            if changed { try saveManagedIdentities();save();message="New addresses were added to the matching managed contact." }
        } catch { automaticAttention="Managed contact sync did not finish: \(error.localizedDescription)" }
    }
}
