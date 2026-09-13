import Foundation

/// PSL prevailing-rule algorithm, including PRIVATE boundaries (e.g. github.io).
/// A registrable domain is a routing hint, never evidence of sender identity.
public struct PublicSuffixRules: Sendable {
    private var exact = Set<String>(), wildcard = Set<String>(), exceptions = Set<String>()
    public init(_ text: String) {
        for line in text.split(whereSeparator: \.isNewline) {
            let value = line.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, !value.hasPrefix("//") else { continue }
            let exception = value.hasPrefix("!"), wild = value.hasPrefix("*.")
            let raw = exception ? String(value.dropFirst()) : wild ? String(value.dropFirst(2)) : value
            guard let host = URL(string: "https://" + raw)?.host?.lowercased() else { continue }
            if exception { exceptions.insert(host) } else if wild { wildcard.insert(host) } else { exact.insert(host) }
        }
    }
    public func registrableDomain(_ domain: String) -> String? {
        let labels = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn:".")).split(separator:".").map(String.init)
        guard labels.count > 1 else { return nil }
        var suffixCount = 1
        for i in labels.indices {
            let suffix = labels[i...].joined(separator:".")
            if exceptions.contains(suffix) { suffixCount = labels.count - i - 1; break }
            if exact.contains(suffix) { suffixCount = max(suffixCount,labels.count - i) }
            if i > 0 && wildcard.contains(suffix) { suffixCount = max(suffixCount,labels.count - i + 1) }
        }
        guard labels.count > suffixCount else { return nil }
        return labels.suffix(suffixCount + 1).joined(separator:".")
    }
    public static let bundled: PublicSuffixRules = {
        // Packaged app keeps the same vendored list as SwiftPM's test bundle.
        let url = Bundle.main.url(forResource:"public_suffix_list",withExtension:"dat")
            ?? Bundle.module.url(forResource:"public_suffix_list",withExtension:"dat")!
        return PublicSuffixRules((try? String(contentsOf:url,encoding:.utf8)) ?? "")
    }()
}

public enum DomainRouting {
    public static func primaryHost(for domain: String) -> String {
        PublicSuffixRules.bundled.registrableDomain(domain) ?? domain.lowercased()
    }
    public static func websites(for email: EmailAddress, override: URL? = nil) -> [URL] {
        guard !email.isSharedProvider || override != nil else { return [] }
        let primary = primaryHost(for: email.domain)
        let regional = regionalStoreHost(emailDomain: email.domain, primary: primary)
        var urls: [URL] = []
        if let override {
            urls.append(override)
            if let regional, override.host.map(primaryHost(for:)) == primary { urls.append(URL(string: "https://\(regional)/")!) }
        } else {
            urls.append(URL(string: "https://\(primary)/")!)
            if let regional { urls.append(URL(string: "https://\(regional)/")!) }
            if primary != email.domain { urls.append(URL(string: "https://\(email.domain)/")!) }
        }
        var seen = Set<String>()
        return urls.filter { seen.insert($0.absoluteString).inserted }
    }

    /// Marketing mail commonly embeds a market code in a subdomain (for
    /// example `nz-news.brand.com`) while the actual public storefront uses the
    /// country's registrable suffix. This is a routing fallback only; it is not
    /// treated as evidence of sender identity.
    public static func regionalStoreHost(emailDomain: String, primary: String) -> String? {
        guard primary.hasSuffix(".com"), emailDomain.hasSuffix("." + primary),
              let brand = primary.split(separator: ".").first.map(String.init) else { return nil }
        let prefix = emailDomain.dropLast(primary.count + 1)
        let tokens = prefix.split(whereSeparator: { $0 == "." || $0 == "-" || $0 == "_" }).map { $0.lowercased() }
        let suffixes = ["nz": "co.nz", "au": "com.au", "uk": "co.uk", "jp": "co.jp", "za": "co.za"]
        guard let market = tokens.first(where: { suffixes[$0] != nil }), let suffix = suffixes[market] else { return nil }
        return brand + "." + suffix
    }
}
