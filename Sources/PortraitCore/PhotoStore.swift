import Foundation

/// Photos are almost the whole library and change far less often than the bookkeeping
/// around them, yet every save used to rewrite all of them as base64. Stored once by
/// content hash, a save rewrites metadata only, artwork shared by many senders is kept
/// once, and the bytes never pass through base64 on disk.
public struct PhotoStore: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    @discardableResult public func store(_ data: Data) throws -> String {
        let reference = digest(data)
        let url = file(reference)
        guard !FileManager.default.fileExists(atPath: url.path) else { return reference }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return reference
    }

    public func load(_ reference: String) -> Data? {
        guard Self.isReference(reference) else { return nil }
        return try? Data(contentsOf: file(reference), options: .mappedIfSafe)
    }

    /// A photo written moments ago may belong to a library snapshot that has not been
    /// saved yet, so only collect what has been unreferenced for a while.
    @discardableResult public func collectGarbage(keeping references: Set<String>, olderThan seconds: TimeInterval = 3_600, now: Date = Date()) throws -> Int {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var removed = 0
        for url in urls where url.pathExtension == "bin" {
            let reference = url.deletingPathExtension().lastPathComponent
            guard Self.isReference(reference), !references.contains(reference) else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            guard now.timeIntervalSince(modified) >= seconds else { continue }
            try FileManager.default.removeItem(at: url)
            removed += 1
        }
        return removed
    }

    private func file(_ reference: String) -> URL { directory.appendingPathComponent(reference + ".bin") }
    static func isReference(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}

public extension CodingUserInfoKey {
    /// Present while reading or writing a stored library: photo bytes live in the store
    /// and the JSON carries references. Without it, photos stay inline as before.
    static let photoStore = CodingUserInfoKey(rawValue: "org.mailportrait.photoStore")!
}

extension Decoder {
    /// Inline bytes (a library written before external photos) still decode; a photo
    /// whose file is missing decodes empty rather than failing the whole library.
    func photo(inline: Data?, reference: String?) -> Data? {
        if let inline { return inline }
        guard let reference else { return nil }
        return (userInfo[.photoStore] as? PhotoStore)?.load(reference) ?? Data()
    }
}
extension Encoder {
    func photoReference(_ data: Data) throws -> String? {
        guard !data.isEmpty, let store = userInfo[.photoStore] as? PhotoStore else { return nil }
        return try store.store(data)
    }
}
