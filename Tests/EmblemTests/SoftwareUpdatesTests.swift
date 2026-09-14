import XCTest
import PortraitCore
@testable import Emblem
final class SoftwareUpdatesTests:XCTestCase {
 @MainActor func testUpdaterStartsOnlyForReadyVisiblePackagedApp() {
  let app=URL(fileURLWithPath:"/Applications/Emblem.app")
  XCTAssertTrue(SoftwareUpdates.mayStart(arguments:["Emblem"],bundle:app,ready:true))
  XCTAssertFalse(SoftwareUpdates.mayStart(arguments:["Emblem"],bundle:app,ready:false))
  for flag in ["--demo","--data-dir","--background-sync-agent","--scan-mail-worker","--self-test","--gmail-status","--ui-experience-smoke"] {
   XCTAssertFalse(SoftwareUpdates.mayStart(arguments:["Emblem",flag],bundle:app,ready:true),flag)
  }
  XCTAssertFalse(SoftwareUpdates.mayStart(arguments:["Emblem"],bundle:URL(fileURLWithPath:"/tmp/Emblem"),ready:true))
 }
 @MainActor func testQuitWaitsForDurableSaveAndRetainsBackgroundPreference()async throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer {try? FileManager.default.removeItem(at:root)}
  let session=AppSession(arguments:["fixture","--demo"],isolatedRoot:root)
  let m=session.model;m.mailSync.enabled=true;m.mailSync.background=true
  m.rowsSnapshotEncoder={ rows in try await Task.sleep(for:.milliseconds(80));return try JSONEncoder().encode(rows) }
  m.rows[0].name="Latest edit"
  try await session.prepareToQuit(installingUpdate:true)
  let saved=try JSONDecoder().decode([SenderRow].self,from:Data(contentsOf:m.stateURL))
  XCTAssertEqual(saved[0].name,"Latest edit");XCTAssertTrue(m.mailSync.background);XCTAssertTrue(m.isShuttingDown)
 }
}
