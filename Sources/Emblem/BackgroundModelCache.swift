import Foundation

/// This is a cache, never a writer lease. Reuse only after a completed durable
/// pass; foreground edits or any changed library JSON invalidate the snapshot.
@MainActor final class BackgroundModelCache {
    private var cached:AppModel?
    private var revision:[String:String]?
    private static let transient:Set<String>=["background-status.json","foreground-request.json","gmail-push-inbox.json"]
    private func signature(root:URL)throws->[String:String] {
        var result:[String:String]=[:]
        for url in try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)
            where url.pathExtension=="json" && !Self.transient.contains(url.lastPathComponent) {
            let a=try FileManager.default.attributesOfItem(atPath:url.path)
            result[url.lastPathComponent]="\((a[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0):\((a[.size] as? NSNumber)?.uint64Value ?? 0):\((a[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0)"
        }
        return result
    }
    func model(root:URL,factory:()->AppModel)throws->AppModel {
        if let cached,cached.root.standardizedFileURL==root.standardizedFileURL,
           revision == (try signature(root:root)) {cached.isShuttingDown=false;return cached}
        discard()
        return factory()
    }
    func remember(_ model:AppModel)throws {
        guard model.lastSavedRowsRevision==model.rowsRevision else {discard();return}
        revision=try signature(root:model.root);cached=model
    }
    func discard(){cached=nil;revision=nil}
}
