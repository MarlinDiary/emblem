import Foundation
import Darwin
import CFNetwork

public enum NetworkPolicy {
    public static func isAllowedURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443, let host = url.host?.lowercased(), host.count <= 253, host.contains("."), !host.hasSuffix("."), !host.contains(":"), host.contains(where: { $0.isLetter }) else { return false }
        let denied = ["localhost", "local", "internal", "test", "invalid", "example", "onion", "home", "lan", "arpa"]
        guard !denied.contains(where: { host == $0 || host.hasSuffix("." + $0) }), !["example.com", "example.org", "example.net"].contains(host) else { return false }
        return host.utf8.allSatisfy { (48...57).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 }
    }
    public static func isPublicIPv4(_ value: UInt32) -> Bool {
        let a = (value >> 24) & 255, b = (value >> 16) & 255, c = (value >> 8) & 255
        if a == 0 || a == 10 || a == 127 || a >= 224 { return false }
        if a == 100 && (64...127).contains(b) { return false }
        if a == 169 && b == 254 || a == 172 && (16...31).contains(b) || a == 192 && b == 168 { return false }
        if a == 192 && (b == 0 || b == 2) || a == 198 && (b == 18 || b == 19 || (b == 51 && c == 100)) || a == 203 && b == 0 && c == 113 { return false }
        return true
    }
    public static func isAcceptableResolvedIPv4(_ value: UInt32, pinnedLoopbackProxy: Bool) -> Bool {
        // Some user-configured local proxies return a benchmark-range Fake-IP.
        // Accept that range only when this session is explicitly pinned to that proxy.
        isPublicIPv4(value) || (pinnedLoopbackProxy && value & 0xfffe0000 == 0xc6120000)
    }
    public static func loopbackProxyConfiguration(_ settings: [String: Any]) -> [AnyHashable: Any]? {
        guard (settings["HTTPSEnable"] as? NSNumber)?.boolValue == true,
              let host = settings["HTTPSProxy"] as? String,
              ["127.0.0.1", "::1", "localhost"].contains(host.lowercased()),
              let port = settings["HTTPSPort"] as? NSNumber, (1...65535).contains(port.intValue) else { return nil }
        return ["HTTPSEnable": 1, "HTTPSProxy": host, "HTTPSPort": port,
                "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0,
                "ExcludeSimpleHostnames": 0, "ExceptionsList": [String]()]
    }
    public static func validate(_ url: URL, pinnedLoopbackProxy: Bool = false) throws {
        guard isAllowedURL(url), let host = url.host else { throw PortraitError.message("Only public HTTPS websites on port 443 are accepted. Local addresses and URLs containing credentials are blocked.") }
        var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "443", &hints, &result) == 0, let first = result else { throw PortraitError.message("The website hostname could not be resolved: \(host)") }
        defer { freeaddrinfo(first) }
        var pointer: UnsafeMutablePointer<addrinfo>? = first
        while let node = pointer {
            if node.pointee.ai_family == AF_INET {
                let address = node.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
                guard isAcceptableResolvedIPv4(address, pinnedLoopbackProxy: pinnedLoopbackProxy) else { throw PortraitError.message("The website resolves to a non-public network address and was skipped.") }
            } else if node.pointee.ai_family == AF_INET6 {
                var address = node.pointee.ai_addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                let bytes = withUnsafeBytes(of: &address) { Array($0) }
                guard bytes[0] & 0xe0 == 0x20, !(bytes[0] == 0x20 && bytes[1] == 1 && bytes[2] == 0x0d && bytes[3] == 0xb8) else { throw PortraitError.message("The website resolves to a non-public IPv6 address and was skipped.") }
            } else { throw PortraitError.message("This network address is not supported.") }
            pointer = node.pointee.ai_next
        }
    }
}

public struct HTTPResourceError: LocalizedError, Sendable {
    public let status: Int
    public var errorDescription: String? { "The website returned HTTP \(status)." }
    public init(status: Int) { self.status=status }
}

public struct WebResource: Sendable {
    public let data: Data
    public let url: URL
    public let contentType: String
    public init(data: Data, url: URL, contentType: String = "") { self.data = data; self.url = url; self.contentType = contentType }
}
public protocol ResourceFetching: Sendable { func fetch(_ url: URL, limit: Int) async throws -> WebResource }

final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let pinnedLoopbackProxy: Bool
    init(pinnedLoopbackProxy: Bool) { self.pinnedLoopbackProxy = pinnedLoopbackProxy }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard task.countOfBytesReceived < 4_000_000, let url = request.url else { completionHandler(nil); return }
        let pinned = pinnedLoopbackProxy
        Task {
            let accepted = (try? await DNSPreflight.validate(url,pinned:pinned)) != nil
            completionHandler(accepted && task.state != .canceling && task.state != .completed ? request : nil)
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}

public final class SafeWebClient: ResourceFetching, @unchecked Sendable {
    private let session: URLSession
    private let pinnedLoopbackProxy: Bool
    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 10; config.timeoutIntervalForResource = 25; config.httpMaximumConnectionsPerHost = 2
        let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] ?? [:]
        let localProxy = NetworkPolicy.loopbackProxyConfiguration(settings)
        pinnedLoopbackProxy = localProxy != nil
        if let localProxy { config.connectionProxyDictionary = localProxy }
        session = URLSession(configuration: config, delegate: RedirectGuard(pinnedLoopbackProxy: pinnedLoopbackProxy), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    public func fetch(_ url: URL, limit: Int = 4_000_000) async throws -> WebResource {
        let request = URLRequest(url: url)
        return try await fetch(request, limit: limit)
    }
    public func fetch(_ input: URLRequest, limit: Int = 4_000_000) async throws -> WebResource {
        try Task.checkCancellation()
        guard let url = input.url else { throw PortraitError.message("The website request has no URL.") }
        let pinned = pinnedLoopbackProxy
        try await DNSPreflight.validate(url,pinned:pinned)
        try Task.checkCancellation()
        var request = input
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue("Emblem/0.18 (+local-avatar-helper)", forHTTPHeaderField: "User-Agent")
        }
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, let finalURL = response.url, NetworkPolicy.isAllowedURL(finalURL) else { throw PortraitError.message("The website did not return a valid response.") }
        guard (200...299).contains(http.statusCode) else { throw HTTPResourceError(status: http.statusCode) }
        guard response.expectedContentLength <= Int64(limit) else { throw PortraitError.message("The image or page exceeds the size limit.") }
        var data = Data()
        for try await byte in stream {
            if data.count % 4096 == 0 { try Task.checkCancellation() }
            guard data.count < limit else { throw PortraitError.message("The downloaded content exceeds the size limit.") }
            data.append(byte)
        }
        return WebResource(data: data, url: finalURL, contentType: response.mimeType ?? "")
    }
}
