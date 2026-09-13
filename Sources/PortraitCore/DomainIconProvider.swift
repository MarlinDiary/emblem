import Foundation

/// A domain-only last resort used after the sender's own DNS and website have
/// yielded no clear brand artwork. It never receives the local part, display
/// name, Mail content, or Contacts data.
public protocol DomainIconURLProviding: Sendable {
    func iconURL(for domain: String) -> URL?
}

public struct GoogleSiteIconProvider: DomainIconURLProviding, Sendable {
    public init() {}

    public func iconURL(for domain: String) -> URL? {
        let primary = DomainRouting.primaryHost(for: domain)
        guard primary.contains("."), !primary.contains("/") else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.google.com"
        components.path = "/s2/favicons"
        components.queryItems = [
            .init(name: "domain_url", value: "https://\(primary)"),
            .init(name: "sz", value: "256")
        ]
        return components.url
    }
}

struct NoDomainIconProvider: DomainIconURLProviding {
    func iconURL(for domain: String) -> URL? { nil }
}
