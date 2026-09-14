import XCTest
import PortraitCore
@testable import Emblem

final class ContactMutationTests:XCTestCase {
    @MainActor private func setup()throws->(URL,FixtureContactStore,ChangeEngine,SenderRow) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("mutation-"+UUID().uuidString)
        let port=try FixtureContactStore()
        let engine=ChangeEngine(store:port,journal:FileJournal(url:root.appendingPathComponent("changes.json")))
        let candidate=try NameAvatar.candidate(name:"Fixture Person")
        var row=SenderRow(email:EmailAddress("person@fixture.org")!,name:"Fixture Person")
        row.candidates=[candidate];row.selectedCandidate=candidate.id;row.selectionIsManual=false
        return (root,port,engine,row)
    }
    @MainActor func testCreateThenUpgradeRetainsOneVerifiedCard()throws {
        let (root,port,engine,row)=try setup();defer{try? FileManager.default.removeItem(at:root)}
        let r=try ContactMutation.perform(.init(kind:.sync,members:[row],representativeID:row.id,key:"person"),port:port,engine:engine)
        XCTAssertEqual(r.contact?.emails,[row.id]);XCTAssertNotNil(r.contact?.image)
        var newer=row;let image=try NameAvatar.candidate(name:"Other",variant:1);newer.candidates=[image];newer.selectedCandidate=image.id
        let u=try ContactMutation.perform(.init(kind:.sync,members:[newer],representativeID:row.id,key:"person",link:r.link),port:port,engine:engine)
        XCTAssertEqual(u.contact?.id,r.contact?.id);XCTAssertEqual(u.contact?.image,image.png);XCTAssertEqual(port.contacts.count,1)
    }
    @MainActor func testSeparateExistingIdentitiesRejectBeforeMutation()throws {
        let (root,port,engine,row)=try setup();defer{try? FileManager.default.removeItem(at:root)}
        var other=row;other=SenderRow(email:EmailAddress("other@fixture.org")!,name:"Other")
        port.contacts=["a":.init(id:"a",name:"First",emails:[row.id],image:nil),"b":.init(id:"b",name:"Second",emails:[other.id],image:nil)]
        XCTAssertThrowsError(try ContactMutation.perform(.init(kind:.sync,members:[row,other],representativeID:row.id,key:"brand"),port:port,engine:engine))
        XCTAssertTrue(try engine.records().isEmpty);XCTAssertEqual(port.contacts.count,2)
    }
    @MainActor func testUndoKeepsTypedEditedPhotoProtection()throws {
        let (root,port,engine,row)=try setup();defer{try? FileManager.default.removeItem(at:root)}
        let r=try ContactMutation.perform(.init(kind:.sync,members:[row],representativeID:row.id,key:"person"),port:port,engine:engine)
        let id=try XCTUnwrap(r.contact?.id);port.contacts[id]?.image=Data("external edit".utf8)
        let rec=try XCTUnwrap(engine.records().last)
        XCTAssertThrowsError(try ContactMutation.perform(.init(kind:.undo,recordID:rec.id),port:port,engine:engine)) { XCTAssertTrue($0 is UndoProtection) }
        XCTAssertNotNil(port.contacts[id]);XCTAssertEqual(try engine.records().last?.state,.applied)
    }
    @MainActor func testPendingNativeWriteAllowsNewMailAndRetainsNewerChoice()async throws {
        let (root,port,_,row)=try setup();defer{try? FileManager.default.removeItem(at:root)}
        let m=AppModel(demo:true,rootOverride:root,backgroundWorkAllowed:false,contactStore:port)
        m.rows=[row];m.mailSync.enabled=true;m.save()
        let key=MailSyncIdentity.key(row),next=try NameAvatar.candidate(name:"Latest Manual",variant:1)
        m.contactMutationRunner={request in
            await Task.yield()
            var changed=m.rows[0];changed.candidates.append(next);changed.selectedCandidate=next.id;changed.selectionIsManual=true
            m.rows=[SenderRow(email:EmailAddress("new@fixture.org")!,name:"New Mail"),changed]
            m.mailSync.explicitChoices[key]=row.id
            return try ContactMutation.perform(request,port:port,engine:m.engine)
        }
        try await m.performMailSync()
        XCTAssertEqual(m.rows[0].id,"new@fixture.org");XCTAssertNil(m.rows[0].current)
        XCTAssertEqual(m.rows[1].chosen?.id,next.id);XCTAssertNotNil(m.rows[1].current)
        XCTAssertEqual(m.mailSync.explicitChoices[key],row.id,"The late old write must not consume the newer manual choice")
    }
    @MainActor func testLateFailureAfterNewMailDoesNotReuseOldArrayIndices()async throws {
        let (root,port,_,row)=try setup();defer{try? FileManager.default.removeItem(at:root)}
        let m=AppModel(demo:true,rootOverride:root,backgroundWorkAllowed:false,contactStore:port)
        var second=row;second=SenderRow(email:EmailAddress("second@fixture.org")!,name:"Second")
        second.candidates=row.candidates;second.selectedCandidate=row.selectedCandidate
        m.rows=[row,second];m.mailSync.enabled=true;m.save();var calls=0
        m.contactMutationRunner={_ in
            calls+=1;await Task.yield()
            m.rows.insert(SenderRow(email:EmailAddress("new@fixture.org")!,name:"New Mail"),at:0)
            throw PortraitError.message("Controlled backend failure")
        }
        try await m.performMailSync()
        XCTAssertEqual(calls,1);XCTAssertNil(m.rows[0].applicationIssue)
        XCTAssertNotNil(m.rows.first(where:{$0.id==row.id})?.applicationIssue)
        XCTAssertNil(m.rows.first(where:{$0.id==second.id})?.applicationIssue)
        XCTAssertTrue(port.contacts.isEmpty)
    }
    @MainActor func testActualHeadlessChildDrainsAfterCallerCancellation()async throws {
        let (root,_,_,row)=try setup();defer{try? FileManager.default.removeItem(at:root)}
        let executable=Bundle(for:ContactMutationTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("Emblem")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath:executable.path))
        let task=Task {try await ContactMutation.run(.init(kind:.sync,members:[row],representativeID:row.id,key:"person"),root:root,executable:executable,fixture:true)}
        await Task.yield();task.cancel()
        let response=try await task.value
        XCTAssertNil(response.error);XCTAssertNotNil(response.contact?.image);XCTAssertNotNil(response.elapsedSeconds)
        let store=try FixtureContactStore(url:root.appendingPathComponent("fixture-contacts.json"))
        XCTAssertEqual(store.contacts.count,1)
        XCTAssertEqual(try FileJournal(url:root.appendingPathComponent("changes.json")).read().last?.state,.applied)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:root.path).allSatisfy{!$0.hasPrefix("contact-mutation-")},"The private request/response directory must be cleaned")
    }
    func testWorkerIsDispatchedBeforeSwiftUIAndNeverKilledOnCancellation()throws {
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let entry=try String(contentsOf:root.appendingPathComponent("Sources/Emblem/EmblemMain.swift"));let code=try String(contentsOf:root.appendingPathComponent("Sources/Emblem/ContactMutation.swift"))
        XCTAssertLessThan(try XCTUnwrap(entry.range(of:"--contact-mutation-worker")?.lowerBound),try XCTUnwrap(entry.range(of:"EmblemApp.main()")?.lowerBound))
        XCTAssertTrue(code.contains("Bundle.main.executableURL"),"launchd passes a relative argv[0]")
        XCTAssertTrue(code.contains("let result=try await worker.value"));XCTAssertFalse(code.contains("process.terminate"));XCTAssertFalse(code.contains("worker.cancel"))
    }
}
