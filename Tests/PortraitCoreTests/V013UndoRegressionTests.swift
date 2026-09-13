import XCTest
@testable import PortraitCore
@MainActor private final class ScopedHistoryStore:ContactStorePort {
    let fixture=try! FixtureContactStore()
    var targetChanged=false
    var scopedChecks=0
    func matches(email:String)throws->[ContactSnapshot] { try fixture.matches(email:email) }
    func get(id:String)throws->ContactSnapshot? { try fixture.get(id:id) }
    func create(name:String,email:String,image:Data)throws->ContactSnapshot { try fixture.create(name:name,email:email,image:image) }
    func setImage(id:String,image:Data?)throws->ContactSnapshot { try fixture.setImage(id:id,image:image) }
    func delete(id:String)throws { try fixture.delete(id:id) }
    func historyToken()->Data? { fixture.historyToken() }
    func historyUnchanged(since token:Data?)throws->Bool { try fixture.historyUnchanged(since:token) }
    func historyUnchanged(for contactID:String,since token:Data?)throws->Bool { scopedChecks+=1;return token != nil && !targetChanged }
}
final class V013UndoRegressionTests:XCTestCase {
    @MainActor func testUnrelatedContactChangesDoNotPreventDeletingAnUneditedCreatedCard() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store=ScopedHistoryStore(),engine=ChangeEngine(store:store,journal:FileJournal(url:root.appendingPathComponent("changes.json")))
        let image=AvatarCandidate(source:.manual,origin:"local-test",width:256,height:256,png:Data([1,2,3]))
        let record=try engine.apply(email:EmailAddress("noreply@tm.openai.com")!,name:"OpenAI",candidate:image,allowCreate:true)
        store.fixture.externalRevision=1 // another contact or group, not this card
        do { try engine.undo(id:record.id) } catch { XCTFail("Unrelated history blocked undo: \(error)") }
        XCTAssertNil(try store.get(id:record.contactID!));XCTAssertEqual(try engine.records().last?.state,.undone)
        print("SCOPED_UNDO unrelated_change=\(try store.get(id:record.contactID!) == nil ? "deleted" : "blocked")")
    }
    @MainActor func testTargetEditsStillPreventDeletion() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store=ScopedHistoryStore(),engine=ChangeEngine(store:store,journal:FileJournal(url:root.appendingPathComponent("changes.json")))
        let c=AvatarCandidate(source:.manual,origin:"local-test",width:256,height:256,png:Data([1,2,3]))
        let r=try engine.apply(email:EmailAddress("noreply@tm.openai.com")!,name:"OpenAI",candidate:c,allowCreate:true)
        store.fixture.externalRevision=1;store.targetChanged=true
        XCTAssertThrowsError(try engine.undo(id:r.id));XCTAssertNotNil(try store.get(id:r.contactID!))
    }
}
