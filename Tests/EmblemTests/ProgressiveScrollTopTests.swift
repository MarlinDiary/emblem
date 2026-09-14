import AppKit
import SwiftUI
import XCTest
@testable import Emblem

final class ProgressiveScrollTopTests: XCTestCase {
    func testProgressiveTopRespectsAccessibilityAndLegacySystems() {
        XCTAssertTrue(NativeAppearance.usesGlass(majorVersion:27,reduceTransparency:false,increasedContrast:false))
        XCTAssertTrue(NativeAppearance.usesGlass(majorVersion:26,reduceTransparency:false,increasedContrast:false))
        XCTAssertFalse(NativeAppearance.usesGlass(majorVersion:15,reduceTransparency:false,increasedContrast:false))
        XCTAssertFalse(NativeAppearance.usesGlass(majorVersion:27,reduceTransparency:true,increasedContrast:false))
        XCTAssertFalse(NativeAppearance.usesGlass(majorVersion:27,reduceTransparency:false,increasedContrast:true))
    }

    func testEveryScrollingSurfaceUsesTheSharedNativeTopStyle() throws {
        let source=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/Emblem")
        for name in ["EmblemApp","SenderViews","PreferencesView","SourceViews","HistoryViews","BatchViews","Sheets"] {
            let text=try String(contentsOf:source.appendingPathComponent(name+".swift"))
            XCTAssertTrue(text.contains(".portraitScrollTop()"),name)
        }
        let shared=try String(contentsOf:source.appendingPathComponent("NativeGlass.swift"))
        XCTAssertTrue(shared.contains("content.scrollEdgeEffectStyle("))
        XCTAssertTrue(shared.contains("? .soft : .hard"))
        XCTAssertTrue(shared.contains("for: .top"))
        XCTAssertFalse(shared.contains("CAFilter"))
        XCTAssertFalse(shared.contains("Timer"))
        XCTAssertFalse(shared.contains(".blur("),"Use the system edge, not a blur on photos or a snapshot loop")
    }

    @MainActor func testTopStylePreservesViewportAndPhotoControlLayout() async throws {
        for scheme in [ColorScheme.light,.dark] {
                let content=ScrollView {
                    VStack(alignment:.leading,spacing:16) {
                        Text("Photo Sources").font(.title2)
                        Button("Choose a Photo") {}.accessibilityIdentifier("scroll-top-photo-control")
                        ForEach(0..<30,id:\.self) { _ in Text("Website Photos") }
                    }.padding(24)
                }.portraitScrollTop()
                    .environment(\.colorScheme,scheme)
                    .frame(width:550,height:480)
                let host=NSHostingView(rootView:content)
                host.frame=NSRect(x:0,y:0,width:550,height:480)
                let window=NSWindow(contentRect:host.frame,styleMask:[.titled],backing:.buffered,defer:false)
                window.contentView=host;host.layoutSubtreeIfNeeded()
                try await Task.sleep(for:.milliseconds(40))
                func scrolls(_ view:NSView)->[NSScrollView] {
                    (view as? NSScrollView).map {[$0]} ?? view.subviews.flatMap(scrolls)
                }
                let scroll=try XCTUnwrap(scrolls(host).first)
                XCTAssertEqual(host.bounds.width,550,accuracy:0.5)
                XCTAssertEqual(host.bounds.height,480,accuracy:0.5)
                XCTAssertGreaterThan(scroll.contentView.bounds.height,400,"No extra top banner or spacer")
                XCTAssertGreaterThan(scroll.documentView?.bounds.height ?? 0,scroll.contentView.bounds.height)
                window.orderOut(nil)
        }
    }
}
