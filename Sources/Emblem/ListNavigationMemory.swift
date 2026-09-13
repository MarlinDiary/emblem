import SwiftUI
import AppKit

/// UI-only state. Navigation never edits sender identities or persisted Contacts.
@MainActor final class ListNavigationMemory {
    var offsets: [String: CGFloat] = [:]
    var selections: [String: String] = [:]
}

/// Keep the native List (selection, keyboard and context menus), and remember its
/// actual clip-view offset per category/search instead of scrolling to selection.
struct RememberListScroll: NSViewRepresentable {
    let memory: ListNavigationMemory
    let key: String
    func makeNSView(context: Context) -> Probe { Probe(memory:memory,key:key) }
    func updateNSView(_ view: Probe, context: Context) { view.update(key:key) }
    @MainActor final class Probe: NSView {
        let memory: ListNavigationMemory
        var key: String
        weak var scroll: NSScrollView?
        var observer: NSObjectProtocol?
        var restoring=false
        init(memory:ListNavigationMemory,key:String) { self.memory=memory;self.key=key;super.init(frame:.zero) }
        required init?(coder:NSCoder) { fatalError() }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
        override func hitTest(_ point:NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scheduleAttach() }
        override func layout() { super.layout(); if scroll == nil { scheduleAttach() } }
        func update(key:String) {
            guard self.key != key else { if scroll == nil { scheduleAttach() };return }
            if let scroll,!restoring { memory.offsets[self.key]=scroll.contentView.bounds.minY }
            self.key=key;restoring=true
            scheduleAttach()
        }
        func scheduleAttach() {
            DispatchQueue.main.async { [weak self] in self?.attachAndRestore() }
        }
        func attachAndRestore() {
            guard window != nil else { return }
            if scroll == nil {
                func descendants(_ view:NSView) -> [NSScrollView] {
                    (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(descendants)
                }
                let rect=convert(bounds,to:nil)
                var parent=superview
                while let p=parent {
                    if let found=descendants(p).first(where:{ candidate in
                        let r=candidate.convert(candidate.bounds,to:nil)
                        return abs(r.midX-rect.midX)<8 && abs(r.width-rect.width)<12 && r.height>100
                    }) { bind(found);break }
                    parent=p.superview
                }
            }
            if let scroll, restoring {
                scroll.layoutSubtreeIfNeeded()
                let maxY=max(0,(scroll.documentView?.frame.height ?? 0)-scroll.contentView.bounds.height)
                let y=min(maxY,max(0,memory.offsets[key] ?? 0))
                scroll.contentView.scroll(to:CGPoint(x:scroll.contentView.bounds.minX,y:y))
                scroll.reflectScrolledClipView(scroll.contentView)
                restoring=false
            }
        }
        func bind(_ scroll:NSScrollView) {
            self.scroll=scroll;restoring=true
            scroll.contentView.postsBoundsChangedNotifications=true
            observer=NotificationCenter.default.addObserver(forName:NSView.boundsDidChangeNotification,object:scroll.contentView,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self,!self.restoring,let scroll=self.scroll else { return }
                    self.memory.offsets[self.key]=scroll.contentView.bounds.minY
                }
            }
        }
    }
}
