import Foundation
import Contacts
import PortraitCore
import PortraitContactsBridge

/// Explicit read-only diagnostic. Does not request permissions, write Contacts,
/// alter the journal, or call undo. Output contains decisions, not contact fields.
@MainActor enum UndoDiagnostics {
    static func run(arguments:[String])->Int32 {
        do {
            func path(_ flag:String)throws->URL {
                guard let i=arguments.firstIndex(of:flag),i+1<arguments.count else { throw PortraitError.message("Missing \(flag)") }
                return URL(fileURLWithPath:arguments[i+1],isDirectory:true)
            }
            let root=try path("--data-dir"),output=try path("--output-dir")
            try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
            let store=AppleContacts()
            var report:[String:Any]=["authorizationStatus":CNContactStore.authorizationStatus(for:.contacts).rawValue,"realContactsWrites":0,"journalWrites":0]
            var results:[[String:Any]]=[]
            do {
                try store.requireFullAccess()
                for record in try FileJournal(url:root.appendingPathComponent("changes.json")).read() where record.created && record.state == .applied {
                    guard let id=record.contactID else { continue }
                    let current=try store.get(id:id)
                    var item:[String:Any]=["recordID":record.id.uuidString,"contactExists":current != nil,"photoPresent":current?.image != nil,"photoBytes":current?.image?.count ?? 0,"photoMatches":photoMatches(current?.image,encodedHash:record.afterHash,pixelHash:record.afterPixelHash)]
                    item["currentPixelHash"]=photoPixelHash(current?.image) ?? "unavailable"
                    item["currentEncodedHash"]=digest(current?.image)
                    if let current,let expected=record.afterEmailsHash { item["emailsMatch"]=digestEmails(current.emails)==expected }
                    var error:NSError?
                    if let inspection=MPContactHistoryInspection(store.store,record.historyToken,id,&error) { item["history"]=inspection }
                    if let error { item["historyError"]=error.localizedDescription }
                    results.append(item)
                }
            } catch { report["error"]=error.localizedDescription }
            report["records"]=results
            let data=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
            try data.write(to:output.appendingPathComponent("contact-undo-diagnostic.json"),options:.atomic)
            print(String(decoding:data,as:UTF8.self));return 0
        } catch { print(error.localizedDescription);return 1 }
    }
}
