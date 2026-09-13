import Foundation

public struct IconReference: Equatable, Sendable {
    public let url: URL
    public let source: CandidateSource
    public let maskable: Bool
    public let declared: Bool
    public init(url: URL, source: CandidateSource, maskable: Bool = false, declared: Bool = true) {
        self.url = url; self.source = source; self.maskable = maskable; self.declared = declared
    }
}

public enum IconDiscovery {
    static func matches(_ pattern: String, _ text: String) -> [NSTextCheckingResult] {
        (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]).matches(in: text, range: NSRange(text.startIndex..., in: text))) ?? []
    }
    static func value(_ match: NSTextCheckingResult, group: Int, in text: String) -> String? {
        guard group < match.numberOfRanges, let range = Range(match.range(at: group), in: text) else { return nil }
        return String(text[range])
    }
    static func attributes(_ tag: String) -> [String: String] {
        var result: [String: String] = [:]
        for match in matches(#"([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#, tag) {
            if let key = value(match, group: 1, in: tag), let raw = value(match, group: 2, in: tag) ?? value(match, group: 3, in: tag) ?? value(match, group: 4, in: tag) {
                result[key.lowercased()] = raw.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&#38;", with: "&")
            }
        }
        return result
    }
    public static func links(html: String, base: URL) -> (icons: [IconReference], manifest: URL?) {
        // Ignore comments/script contents before inspecting static <link> metadata.
        var clean = html
        for pattern in [#"<!--[\s\S]*?-->"#, #"<script\b[^>]*>[\s\S]*?</script\s*>"#] {
            clean = clean.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        var icons: [IconReference] = [], manifest: URL?
        for match in matches(#"<link\b[^>]*>"#, clean) {
            guard let tag = value(match, group: 0, in: clean) else { continue }
            let attrs = attributes(tag)
            let rel = Set((attrs["rel"] ?? "").lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init))
            guard let href = attrs["href"], let url = URL(string: href, relativeTo: base)?.absoluteURL, NetworkPolicy.isAllowedURL(url) else { continue }
            if rel.contains("apple-touch-icon") || rel.contains("apple-touch-icon-precomposed") { icons.append(.init(url: url, source: .touchIcon)) }
            else if rel.contains("icon") { icons.append(.init(url: url, source: .favicon)) }
            else if rel.contains("manifest"), manifest == nil { manifest = url }
        }
        // Intentional conventional fallback; does not guess a parent/third-party brand domain.
        for path in ["/apple-touch-icon.png", "/favicon.ico"] {
            if let url = URL(string: path, relativeTo: base)?.absoluteURL, NetworkPolicy.isAllowedURL(url), !icons.contains(where: { $0.url == url }) {
                icons.append(.init(url: url, source: path.contains("touch") ? .touchIcon : .favicon, declared: false))
            }
        }
        return (Array(icons.prefix(12)), manifest)
    }
    public static func manifestIcons(data: Data, base: URL) -> [IconReference] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let entries = json["icons"] as? [[String: Any]] else { return [] }
        return Array(entries.prefix(12).compactMap { entry in
            let purpose = (entry["purpose"] as? String ?? "any").lowercased().split(whereSeparator: { $0.isWhitespace })
            guard (purpose.contains("any") || purpose.contains("maskable")), let src = entry["src"] as? String, let url = URL(string: src, relativeTo: base)?.absoluteURL, NetworkPolicy.isAllowedURL(url) else { return nil }
            return IconReference(url: url, source: .manifest, maskable: purpose.contains("maskable"))
        })
    }
}

/// Extracts only an explicit Schema.org organization logo. Open Graph images
/// are intentionally excluded because they are commonly article or campaign
/// banners rather than stable brand marks.
public enum StructuredLogoDiscovery {
    private static let organizationTypes: Set<String> = [
        "organization", "corporation", "brand", "educationalorganization",
        "governmentorganization", "ngo", "localbusiness", "sportsorganization"
    ]

    public static func urls(html: String, base: URL) -> [URL] {
        var found: [URL] = []
        for match in IconDiscovery.matches(#"<script\b([^>]*)>([\s\S]*?)</script\s*>"#, html) {
            guard let tag = IconDiscovery.value(match, group: 1, in: html),
                  IconDiscovery.attributes("<script " + tag + ">")["type"]?.lowercased() == "application/ld+json",
                  let body = IconDiscovery.value(match, group: 2, in: html),
                  let data = body.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) else { continue }
            collect(object, base: base, into: &found)
        }
        var seen = Set<URL>()
        return Array(found.filter { seen.insert($0).inserted }.prefix(6))
    }

    private static func collect(_ value: Any, base: URL, into found: inout [URL]) {
        if let values = value as? [Any] {
            for value in values { collect(value, base: base, into: &found) }
            return
        }
        guard let object = value as? [String: Any] else { return }
        let rawTypes = object["@type"] as? [String] ?? (object["@type"] as? String).map { [$0] } ?? []
        if rawTypes.contains(where: { organizationTypes.contains($0.lowercased()) }),
           let raw = logoString(object["logo"]),
           let url = URL(string: raw, relativeTo: base)?.absoluteURL,
           NetworkPolicy.isAllowedURL(url) {
            found.append(url)
        }
        // Schema graphs and nested publishers are both common. Recursing over
        // dictionaries remains safe because a logo is accepted only on an
        // object carrying one of the explicit organization types above.
        for nested in object.values { collect(nested, base: base, into: &found) }
    }

    private static func logoString(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        guard let value = value as? [String: Any] else { return nil }
        for key in ["contentUrl", "url"] {
            if let string = value[key] as? String { return string }
        }
        return nil
    }
}

public enum ProfileDiscovery {
    public static func image(html:String,base:URL) -> URL? {
        var clean=html
        for pattern in [#"<!--[\s\S]*?-->"#, #"<script\b[^>]*>[\s\S]*?</script\s*>"#] {
            clean=clean.replacingOccurrences(of:pattern,with:"",options:[.regularExpression,.caseInsensitive])
        }
        var twitter:URL?
        for match in IconDiscovery.matches(#"<meta\b[^>]*>"#,clean) {
            guard let tag=IconDiscovery.value(match,group:0,in:clean) else { continue }
            let attrs=IconDiscovery.attributes(tag), key=(attrs["property"] ?? attrs["name"] ?? "").lowercased()
            guard ["og:image","og:image:secure_url","twitter:image"].contains(key),
                  let content=attrs["content"], let url=URL(string:content,relativeTo:base)?.absoluteURL,
                  NetworkPolicy.isAllowedURL(url) else { continue }
            if key.hasPrefix("og:") { return url }
            twitter = twitter ?? url
        }
        return twitter
    }
}
