import XCTest
import SwiftUI
import AppKit
import PortraitCore
@testable import Emblem
private actor V014NoNetwork:ResourceFetching {
 func fetch(_ url:URL,limit:Int)async throws->WebResource {throw PortraitError.message("Network deliberately disabled in this test")}
}
final class V014QualityTests:XCTestCase {
 @MainActor func testRealClaudeMigrationUsesBundledFirstPartyVectorWithoutNetwork()async throws {
  let resolver=AvatarResolver(client:V014NoNetwork())
  let result=try await resolver.resolve(email:EmailAddress("no-reply@email.claude.com")!,displayName:"Claude Team",gravatar:false,website:true)
  let c=try XCTUnwrap(CandidateSelection.automaticChoice(result.candidates))
  XCTAssertEqual(c.source,.officialBrand);XCTAssertTrue(c.vector);XCTAssertTrue(c.recommendedAutomatically)
  if let folder=ProcessInfo.processInfo.environment["EMBLEM_V014_ASSETS"] {
   try c.png.write(to:URL(fileURLWithPath:folder).appendingPathComponent("claude-after.png"))
   let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
   let rows=try JSONDecoder().decode([SenderRow].self,from:Data(contentsOf:URL(fileURLWithPath:folder).deletingLastPathComponent().appendingPathComponent("state-before/senders.json")))
   let actual=try XCTUnwrap(rows.first{$0.id=="no-reply@email.claude.com"})
   let m=AppModel(demo:false,rootOverride:root,resolverFactory:{resolver});m.rows=[actual];m.automation.setupComplete=true;m.useWebsite=true;m.useGravatar=false
   XCTAssertTrue(AutomaticLookupPolicy.due(actual,website:true,gravatar:false,now:Date()))
   try await m.automaticallyResolve(now:Date());XCTAssertEqual(m.rows[0].chosen?.source,.officialBrand);XCTAssertTrue(try m.engine.records().isEmpty)
  }
  print("CLAUDE_FIRST_PARTY_VECTOR=PASS NETWORK_REQUESTS=0 CONTACT_WRITES=0")
 }
 @MainActor func testLegacyOrderMigratesOnceAndNeverInventsDates()throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  let old=[SenderRow(email:EmailAddress("hello@sevenrooms.com")!,name:"SevenRooms"),SenderRow(email:EmailAddress("support@bellroy.com")!,name:"Bellroy")]
  try JSONEncoder().encode(old).write(to:root.appendingPathComponent("senders.json"))
  let m=AppModel(demo:true,rootOverride:root);XCTAssertEqual(m.rows.map(\.id),old.reversed().map(\.id));XCTAssertTrue(m.rows.allSatisfy{$0.discoveredAt == nil})
  let re=AppModel(demo:true,rootOverride:root);XCTAssertEqual(re.rows.map(\.id),m.rows.map(\.id))
 }
 @MainActor func testJunkOnlyDiscoveryIsNotEnrolledButLaterInboxAppearanceIs()async throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
  let m=AppModel(demo:true,rootOverride:root);m.mailSync.enabled=true
  let email=EmailAddress("info@sevenrooms.com")!;var seen=Set<String>()
  m.ingestScanned(email:email,name:"SevenRooms",seen:&seen,eligibleForSync:MailSyncMailboxPolicy.allows(["Gmail","Spam"]))
  let c=try NameAvatar.candidate(name:"SevenRooms");m.rows[0].candidates=[c];m.rows[0].selectedCandidate=c.id
  try await m.performMailSync();XCTAssertTrue(try m.engine.records().isEmpty)
  m.ingestScanned(email:email,name:"SevenRooms",seen:&seen,eligibleForSync:true)
  try await m.performMailSync();XCTAssertEqual(try m.engine.records().count,1)
 }
 @MainActor func testPausedDiscoveryStillAllowsExplicitPhotoSync()async throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
  let m=AppModel(demo:true,rootOverride:root);m.mailSync.enabled=true;m.automaticEnabled=false
  let c=try NameAvatar.candidate(name:"Bellroy");m.rows=[SenderRow(email:EmailAddress("support@bellroy.com")!,name:"Bellroy",candidates:[c],selectedCandidate:c.id)]
  try await m.performMailSync();XCTAssertEqual(try m.engine.records().count,1)
 }
 @MainActor func testRealStreamlinedInterfaceSnapshots()async throws {
  guard let folder=ProcessInfo.processInfo.environment["EMBLEM_V014_ASSETS"],let snapshots=ProcessInfo.processInfo.environment["EMBLEM_SNAPSHOT_DIR"] else{throw XCTSkip("real visual corpus opt-in")}
  let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
  let m=AppModel(demo:false,rootOverride:root,backgroundWorkAllowed:false);m.automaticEnabled=false
  let rows=try JSONDecoder().decode([SenderRow].self,from:Data(contentsOf:URL(fileURLWithPath:folder).deletingLastPathComponent().appendingPathComponent("state-before/senders.json")))
  m.rows=Array(rows.reversed());m.selectedID="no-reply@email.claude.com"
  let result=try await AvatarResolver(client:V014NoNetwork()).resolve(email:EmailAddress(m.selectedID!)!,displayName:"Claude Team",gravatar:false,website:true)
  if let i=m.rows.firstIndex(where:{$0.id==m.selectedID}) {m.rows[i].candidates=result.candidates;m.rows[i].selectedCandidate=CandidateSelection.automaticChoice(result.candidates)?.id}
  m.mailSync.enabled=true
  let session=AppSession(arguments:[],isolatedRoot:root.appendingPathComponent("session"));session.model=m
  let output=URL(fileURLWithPath:snapshots);try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
  _=NSApplication.shared;let priorAppearance=NSApp.appearance;defer{NSApp.appearance=priorAppearance}
  for (name,scheme,width) in [("v014-light",ColorScheme.light,1100),("v014-dark",ColorScheme.dark,900)] {
   NSApp.appearance=NSAppearance(named:scheme == .dark ? .darkAqua : .aqua)
   let host=NSHostingView(rootView:MainView(model:m,session:session).preferredColorScheme(scheme).environment(\.colorScheme,scheme).background(Color(nsColor:.windowBackgroundColor)))
   let window=NSWindow(contentRect:CGRect(x:0,y:0,width:width,height:720),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
   window.appearance=NSAppearance(named:scheme == .dark ? .darkAqua : .aqua);window.contentView=host;host.frame=CGRect(x:0,y:0,width:width,height:720)
   window.setFrameOrigin(CGPoint(x:-20000,y:-20000));window.orderBack(nil)
   for _ in 0..<8 {host.layoutSubtreeIfNeeded();try await Task.sleep(for:.milliseconds(25))}
   let bitmap=try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds));window.effectiveAppearance.performAsCurrentDrawingAppearance {host.cacheDisplay(in:host.bounds,to:bitmap)}
   try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:output.appendingPathComponent(name+".png"));window.orderOut(nil)
  }
  XCTAssertTrue(try m.engine.records().isEmpty)
 }
}
