import AppKit
import XCTest
import PortraitCore
@testable import MailPortrait

final class VirtualizedSenderTableTests:XCTestCase {
    @MainActor func testLargeTableConfiguresOnlyVisibleCellsAndSelectionDoesNotReload()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let model=AppModel(demo:true,rootOverride:root,backgroundWorkAllowed:false)
        model.rows=(0..<1800).map {index in
            SenderRow(email:EmailAddress("person\(index)@company\(index).com")!,name:"Person \(index)")
        }
        let groups=model.visibleGroups
        let coordinator=VirtualizedSenderTable.Coordinator(model:model)
        let scroll=coordinator.makeScrollView()
        scroll.frame=NSRect(x:0,y:0,width:320,height:620)
        let window=NSWindow(contentRect:scroll.frame,styleMask:[.borderless],backing:.buffered,defer:false)
        window.contentView=scroll
        coordinator.update(scroll:scroll,groups:groups,rowsRevision:model.rowsRevision,
                           navigationKey:"all|",selectedGroupID:groups.first?.id,
                           batchMode:false,selectedForBatch:[],controlsDisabled:false)
        window.contentView?.layoutSubtreeIfNeeded();coordinator.table.layoutSubtreeIfNeeded()
        XCTAssertEqual(coordinator.table.numberOfRows,1800)
        XCTAssertGreaterThan(coordinator.configuredCellCount,0)
        XCTAssertLessThan(coordinator.configuredCellCount,80,"Only visible native cells should be constructed")
        let reloads=coordinator.fullReloadCount
        coordinator.update(scroll:scroll,groups:groups,rowsRevision:model.rowsRevision,
                           navigationKey:"all|",selectedGroupID:groups[900].id,
                           batchMode:false,selectedForBatch:[],controlsDisabled:false)
        XCTAssertEqual(coordinator.fullReloadCount,reloads,"Selection must not rebuild 1,800 sender rows")
        XCTAssertEqual(coordinator.table.selectedRow,900)
    }
}
