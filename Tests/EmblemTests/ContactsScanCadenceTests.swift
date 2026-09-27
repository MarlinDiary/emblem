import XCTest
import PortraitCore
@testable import Emblem

private final class CountingContacts:ContactsScannerPort,@unchecked Sendable {
    private let lock=NSLock()
    private var enumerations=0
    var count:Int {lock.withLock{enumerations}}
    func batches()->AsyncThrowingStream<[ContactSnapshot],Error> {
        lock.withLock{enumerations += 1}
        return AsyncThrowingStream {continuation in
            continuation.yield([.init(id:"existing",name:"Has Photo",emails:["photo@company.org"],image:Data([7]))])
            continuation.finish()
        }
    }
}

/// Enumerating every contact with its thumbnail data four times an hour costs IPC and
/// memory even when nothing changed. Contacts change history already answers that.
final class ContactsScanCadenceTests:XCTestCase {
    @MainActor func testUnchangedContactsSkipTheFullEnumeration()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("contacts-cadence-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let contacts=CountingContacts()
        let model=AppModel(demo:false,rootOverride:root,contactScanner:contacts,backgroundWorkAllowed:false)
        model.automation.setupComplete=true;model.automation.mail=false;model.automation.contacts=true
        model.contactsHistoryTokenProvider={Data([9])}
        var unchanged=false,probes=0
        model.contactsHistoryUnchanged={_ in probes += 1;return unchanged}
        let start=Date()

        try await model.automaticallyDiscover(now:start)
        XCTAssertEqual(contacts.count,1,"The first pass has no history to trust")
        XCTAssertEqual(model.automation.contactsHistoryToken,Data([9]),"A token is kept for the next pass")

        unchanged=true
        try await model.automaticallyDiscover(now:start.addingTimeInterval(900))
        XCTAssertEqual(contacts.count,1,"Unchanged Contacts need no enumeration")
        XCTAssertEqual(probes,1)
        XCTAssertEqual(model.automation.lastContacts,start.addingTimeInterval(900),"The pass still counts as up to date")

        unchanged=false
        try await model.automaticallyDiscover(now:start.addingTimeInterval(1800))
        XCTAssertEqual(contacts.count,2,"A real Contacts change is still picked up")
    }
}
