import Foundation
import dnssd
import Darwin

public protocol TXTRecordFetching: Sendable {
    func records(named name: String) async throws -> [String]
}

private final class DNSQueryBox: @unchecked Sendable {
    var records: [String] = []
    var error: DNSServiceErrorType = DNSServiceErrorType(kDNSServiceErr_NoError)
    var finished = false
}

private let mailPortraitTXTCallback: DNSServiceQueryRecordReply = {
    _, flags, _, errorCode, _, _, _, dataLength, data, _, context in
    guard let context else { return }
    let box = Unmanaged<DNSQueryBox>.fromOpaque(context).takeUnretainedValue()
    if errorCode == kDNSServiceErr_NoError, let data {
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        var cursor = 0
        var chunks: [String] = []
        while cursor < Int(dataLength) {
            let count = Int(bytes[cursor])
            cursor += 1
            guard count > 0, cursor + count <= Int(dataLength) else { break }
            chunks.append(String(decoding: UnsafeBufferPointer(start: bytes + cursor, count: count), as: UTF8.self))
            cursor += count
        }
        if !chunks.isEmpty { box.records.append(chunks.joined()) }
    } else if errorCode != kDNSServiceErr_NoSuchRecord {
        box.error = errorCode
    }
    if flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) == 0 { box.finished = true }
}

/// Uses macOS's configured DNS resolver. No third-party favicon service sees an
/// email address; the query contains only `default._bimi.<sender-domain>`.
public struct SystemTXTRecordFetcher: TXTRecordFetching, Sendable {
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "MailPortrait.BIMI.DNS"
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .utility
        return queue
    }()

    public init() {}

    public func records(named name: String) async throws -> [String] {
        try await withDeadline(seconds: 4) {
            let gate = DeadlineGate<[String]>()
            let operation = BlockOperation {
                do { gate.finish(.success(try Self.blockingRecords(named: name))) }
                catch { gate.finish(.failure(error)) }
            }
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    gate.install(continuation)
                    Self.queue.addOperation(operation)
                }
            } onCancel: {
                operation.cancel()
                gate.finish(.failure(CancellationError()))
            }
        }
    }

    private static func blockingRecords(named name: String) throws -> [String] {
            let box = DNSQueryBox()
            var reference: DNSServiceRef?
            let start = DNSServiceQueryRecord(
                &reference,
                0,
                0,
                name,
                UInt16(kDNSServiceType_TXT),
                UInt16(kDNSServiceClass_IN),
                mailPortraitTXTCallback,
                Unmanaged.passUnretained(box).toOpaque()
            )
            guard start == kDNSServiceErr_NoError, let reference else {
                throw PortraitError.message("The BIMI DNS query could not start (\(start)).")
            }
            defer { DNSServiceRefDeallocate(reference) }
            let socket = DNSServiceRefSockFD(reference)
            guard socket >= 0 else { throw PortraitError.message("The BIMI DNS query has no connection to poll.") }
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            repeat {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { throw DeadlineExceeded(seconds: 3) }
                let milliseconds = Int32(max(1, min(3_000, remaining * 1_000)))
                var descriptor = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
                let ready = Darwin.poll(&descriptor, 1, milliseconds)
                if ready == 0 { throw DeadlineExceeded(seconds: 3) }
                if ready < 0 {
                    if errno == EINTR { continue }
                    throw PortraitError.message("The BIMI DNS poll failed (\(errno)).")
                }
                let process = DNSServiceProcessResult(reference)
                guard process == kDNSServiceErr_NoError else {
                    throw PortraitError.message("The BIMI DNS query failed (\(process)).")
                }
            } while !box.finished
            try Task.checkCancellation()
            guard box.error == kDNSServiceErr_NoError else {
                throw PortraitError.message("The BIMI DNS query returned an error (\(box.error)).")
            }
            return box.records
    }
}

public enum BIMIRecord {
    public static func logoURL(from record: String) -> URL? {
        let unquoted = record.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"")))
        var tags: [String: String] = [:]
        for field in unquoted.split(separator: ";", omittingEmptySubsequences: false) {
            let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            let key = pair[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if tags[key] == nil { tags[key] = value }
        }
        guard tags["v"]?.uppercased() == "BIMI1", let location = tags["l"], !location.isEmpty,
              let url = URL(string: location), NetworkPolicy.isAllowedURL(url) else { return nil }
        return url
    }

    static func isDeclaration(_ record: String) -> Bool {
        record.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"")))
            .uppercased().hasPrefix("V=BIMI1;")
    }
}

public struct BIMILogo: Equatable, Sendable {
    public let recordDomain: String
    public let logoURL: URL
    public init(recordDomain: String, logoURL: URL) {
        self.recordDomain = recordDomain
        self.logoURL = logoURL
    }
}

public protocol BIMILogoResolving: Sendable {
    func logo(for domain: String) async throws -> BIMILogo?
}

/// Conservative BIMI selector. An exact From-domain record wins; only absence
/// falls back to the registrable domain. Conflicting or malformed declarations
/// stop at that level instead of guessing.
public actor PublicBIMI: BIMILogoResolving {
    private let records: any TXTRecordFetching
    private var cache: [String: BIMILogo] = [:]
    private var knownMissing: Set<String> = []

    public init(records: any TXTRecordFetching = SystemTXTRecordFetcher()) {
        self.records = records
    }

    public func logo(for domain: String) async throws -> BIMILogo? {
        let domain = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if let cached = cache[domain] { return cached }
        if knownMissing.contains(domain) { return nil }
        var domains = [domain]
        if let primary = PublicSuffixRules.bundled.registrableDomain(domain), primary != domain { domains.append(primary) }
        for candidate in domains {
            try Task.checkCancellation()
            let answers = try await records.records(named: "default._bimi." + candidate)
            let declarations = answers.filter(BIMIRecord.isDeclaration)
            guard !declarations.isEmpty else { continue }
            let urls = Array(Set(declarations.compactMap(BIMIRecord.logoURL)))
            guard urls.count == 1, let url = urls.first else { knownMissing.insert(domain); return nil }
            let logo = BIMILogo(recordDomain: candidate, logoURL: url)
            cache[domain] = logo
            return logo
        }
        knownMissing.insert(domain)
        return nil
    }
}
