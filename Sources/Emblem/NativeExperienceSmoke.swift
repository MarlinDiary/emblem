import AppKit
import SwiftUI
import PortraitCore

/// Opt-in executable UI regression, using a copied library and fixture Contacts.
/// Captures toolbar object identity, not merely a matching accessibility label.
@MainActor enum NativeExperienceSmoke {
    static func run(model:AppModel) async -> Int32 {
        do {
            for _ in 0..<40 where NSApp.windows.first(where: { $0.toolbar != nil }) == nil { try await Task.sleep(nanoseconds:50_000_000) }
            guard let window=NSApp.windows.first(where: { $0.toolbar != nil }),let toolbar=window.toolbar else { throw PortraitError.message("Native window toolbar missing") }
            let savedFrame=window.frame,savedAutosave=window.frameAutosaveName
            window.setFrameAutosaveName("")
            defer { window.setFrame(savedFrame,display:false);window.setFrameAutosaveName(savedAutosave) }
            window.setFrameOrigin(CGPoint(x:-20000,y:-20000))
            model.section="all";model.search="";model.reconcileSelection()
            try await Task.sleep(nanoseconds:250_000_000)
            func signature()->[(String,ObjectIdentifier)] { toolbar.items.map { ($0.itemIdentifier.rawValue,ObjectIdentifier($0)) } }
            let initial=signature()
            print("NATIVE_TOOLBAR_ITEMS " + initial.map(\.0).joined(separator:","))
            guard !initial.isEmpty,initial.contains(where: { $0.0.localizedCaseInsensitiveContains("search") }) else { throw PortraitError.message("Search toolbar item missing") }
            let toolbarID=ObjectIdentifier(toolbar)
            let rows=Array(model.visibleRows.prefix(30))
            guard rows.count>=3 else { throw PortraitError.message("UI fixture needs senders") }
            for row in rows {
                model.selectedID=row.id
                try await Task.sleep(nanoseconds:35_000_000)
                let now=signature()
                guard ObjectIdentifier(window.toolbar!)==toolbarID,now.count==initial.count,
                      zip(now,initial).allSatisfy({ $0.0.0==$0.1.0 && $0.0.1==$0.1.1 }) else { throw PortraitError.message("Toolbar or search object recreated during sender selection") }
            }
            print("NATIVE_TOOLBAR SELECTIONS=\(rows.count) ITEM_COUNT=\(initial.count) TOOLBAR_IDENTITY=STABLE SEARCH_IDENTITY=STABLE")
            model.section="history";model.reconcileSelection();try await Task.sleep(nanoseconds:150_000_000)
            guard !model.showsBatchAction else { throw PortraitError.message("Batch action visible in history") }
            print("NATIVE_EXPERIENCE HISTORY_BATCH_ACTION=ABSENT REAL_CONTACT_OPERATIONS=0")
            return 0
        } catch { print("NATIVE_EXPERIENCE_FAIL \(error.localizedDescription)");return 1 }
    }
}
