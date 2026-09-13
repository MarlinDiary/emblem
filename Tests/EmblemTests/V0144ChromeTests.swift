import XCTest
import SwiftUI
import AppKit
@testable import Emblem

final class V0144ChromeTests:XCTestCase {
    private var sources:URL {URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/Emblem")}
    func testSidebarOverlayCannotDefaultToHorizontalDivider()throws {
        let source=try String(contentsOf:sources.appendingPathComponent("EmblemApp.swift"))
        XCTAssertFalse(source.contains(".overlay(alignment:.trailing) {Divider()"),"A Divider without a horizontal stack draws across the sidebar at mid-height.")
    }
    func testSplitWindowUsesSystemToolbarGeometry()throws {
        let source=try String(contentsOf:sources.appendingPathComponent("EmblemApp.swift"))
        XCTAssertTrue(source.contains(".windowToolbarStyle(.automatic)"),"A forced unified toolbar paints a separate full-width top band over the sidebar.")
    }
    func testSidebarMaterialContinuesThroughTopSafeArea()throws {
        let source=try String(contentsOf:sources.appendingPathComponent("SenderViews.swift"))
        XCTAssertTrue(source.contains("SidebarMaterial().ignoresSafeArea(edges:.top)"),"Only the backdrop should extend under titlebar controls, not the list rows.")
    }
    @MainActor func testClosePolicyAndReopenDoNotReplaceSessionModel()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root);BackgroundLifecycle.model=nil}
        let session=AppSession(arguments:["test","--demo"],isolatedRoot:root)
        let original=ObjectIdentifier(session.model),delegate=BackgroundLifecycle()
        BackgroundLifecycle.model=session.model
        session.model.setBackground(true)
        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
        XCTAssertEqual(ObjectIdentifier(session.model),original)
        session.model.setBackground(false)
        XCTAssertTrue(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }
    @MainActor func testBoundaryPixelsStayOnRightEdgeInLightAndDark()async throws {
        for dark in [false,true] {
            NSApplication.shared.appearance=NSAppearance(named:dark ? .darkAqua : .aqua)
            let view=NSHostingView(rootView:(dark ? Color.black : Color.white)
                .overlay(alignment:.trailing) {SidebarBoundary()}
                .environment(\.displayScale,2).preferredColorScheme(dark ? .dark : .light))
            view.frame=CGRect(x:0,y:0,width:280,height:500)
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds:50_000_000)
            let bitmap=try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds))
            view.cacheDisplay(in:view.bounds,to:bitmap)
            let y=bitmap.pixelsHigh/2,background:CGFloat=dark ? 0:1
            let changed=(0..<bitmap.pixelsWide).filter { x in
                guard let color=bitmap.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB) else{return false}
                return abs(color.redComponent-background)>0.015
            }
            XCTAssertFalse(changed.isEmpty)
            XCTAssertLessThanOrEqual(changed.count,2)
            XCTAssertGreaterThanOrEqual(changed.first ?? 0,bitmap.pixelsWide-2)
            if let dir=ProcessInfo.processInfo.environment["EMBLEM_SNAPSHOT_DIR"] {
                let png=try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
                try png.write(to:URL(fileURLWithPath:dir).appendingPathComponent("v0144-boundary-\(dark ? "dark":"light").png"))
            }
            print("VERTICAL_BOUNDARY MODE=\(dark ? "dark":"light") MIDLINE_CHANGED_PIXELS=\(changed.count) WIDTH=\(bitmap.pixelsWide)")
        }
    }
}
