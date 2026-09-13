import Foundation

public struct InstitutionalPortrait: Sendable {
    public let matchedName: String
    public let profileURL: URL
    public let image: WebResource

    public init(matchedName: String, profileURL: URL, image: WebResource) {
        self.matchedName = matchedName
        self.profileURL = profileURL
        self.image = image
    }
}

public protocol InstitutionalProfileSearching: Sendable {
    func portrait(email: EmailAddress, displayName: String?) async throws -> InstitutionalPortrait?
}

/// One institution entry describes a public directory family, not an individual
/// sender. New institutions can be added without changing matching, safety or
/// ranking code.
public struct InstitutionalDirectory: Equatable, Sendable {
    public let id: String
    public let emailDomains: [String]
    public let publicBaseURL: URL
    public let apiBaseURL: URL
    public let brandWebsiteURL: URL
    public let filterNames: [String]
    public let legacyProfileBases: [URL]
    public let legacyProfilePrefix: String

    public var publicHost: String { publicBaseURL.host ?? "" }

    public init(id: String, emailDomains: [String], publicBaseURL: URL, apiBaseURL: URL, brandWebsiteURL: URL,
                filterNames: [String], legacyProfileBases: [URL] = [], legacyProfilePrefix: String = "") {
        self.id = id
        self.emailDomains = emailDomains
        self.publicBaseURL = publicBaseURL
        self.apiBaseURL = apiBaseURL
        self.brandWebsiteURL = brandWebsiteURL
        self.filterNames = filterNames
        self.legacyProfileBases = legacyProfileBases
        self.legacyProfilePrefix = legacyProfilePrefix
    }
}

public enum InstitutionalDirectoryRegistry {
    public static let directories: [InstitutionalDirectory] = [
        .init(
            id: "auckland-discovery",
            emailDomains: ["auckland.ac.nz", "aucklanduni.ac.nz"],
            publicBaseURL: URL(string: "https://profiles.auckland.ac.nz")!,
            apiBaseURL: URL(string: "https://profiles.auckland.ac.nz/api")!,
            brandWebsiteURL: URL(string: "https://www.auckland.ac.nz/")!,
            filterNames: ["customFilterOne", "department", "tags", "customFilterTwo", "customFilterThree"]
        ),
        .init(
            id: "wellington-discovery",
            emailDomains: ["vuw.ac.nz", "wgtn.ac.nz"],
            publicBaseURL: URL(string: "https://people.wgtn.ac.nz")!,
            apiBaseURL: URL(string: "https://people.wgtn.ac.nz/api")!,
            brandWebsiteURL: URL(string: "https://www.wgtn.ac.nz/")!,
            filterNames: ["department", "customFilterThree", "customFilterOne", "tags"],
            legacyProfileBases: [URL(string: "https://ecs.wgtn.ac.nz/Main/")!],
            legacyProfilePrefix: "Grad"
        )
    ]

    public static func directory(for email: EmailAddress) -> InstitutionalDirectory? {
        let routed = DomainRouting.primaryHost(for: email.domain)
        return directories.first { directory in
            directory.emailDomains.contains { routed == $0 || email.domain == $0 || email.domain.hasSuffix("." + $0) }
        }
    }
}

public enum InstitutionalProfilePolicy {
    private static let titleWords: Set<String> = ["dr", "prof", "professor", "mr", "mrs", "ms", "miss", "sir", "dame"]
    private static let roleWords: Set<String> = [
        "university", "office", "team", "support", "service", "services", "information", "info", "events", "event",
        "alert", "alerts", "noreply", "reply", "submissions", "records", "care", "careers", "parking", "graduation", "orientation",
        "communications", "collections", "postgraduate", "faculty", "centre", "center", "admissions", "billing", "newsletter"
    ]

    public static func normalizedPersonName(_ displayName: String?) -> String? {
        guard let displayName else { return nil }
        let collapsed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace).map(String.init)
        let untitled = collapsed.drop(while: { titleWords.contains($0.trimmingCharacters(in: .punctuationCharacters).lowercased()) })
        guard (2...7).contains(untitled.count) else { return nil }
        let words = untitled.map { $0.trimmingCharacters(in: .punctuationCharacters) }
        guard words.allSatisfy({ word in
            !word.isEmpty && word.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) || $0 == "-" || $0 == "'" || $0 == "’" }
        }), !words.contains(where: { roleWords.contains($0.lowercased()) }) else { return nil }
        return words.joined(separator: " ")
    }

    public static func isEligible(email: EmailAddress, displayName: String?) -> Bool {
        !email.isSharedProvider && normalizedPersonName(displayName) != nil
    }

    /// Institution mailboxes are distinct operational identities. A repeated
    /// university display name is not evidence that two addresses are aliases.
    public static func keepsMailboxIndependent(_ email: EmailAddress) -> Bool {
        InstitutionalDirectoryRegistry.directory(for: email) != nil || email.domain.hasSuffix(".edu") || email.domain.contains(".ac.") || email.domain.contains(".edu.")
    }

    public static func directoryHost(for email: EmailAddress) -> String? {
        InstitutionalDirectoryRegistry.directory(for: email)?.publicHost
    }

    public static func brandWebsiteURL(for email: EmailAddress) -> URL? {
        InstitutionalDirectoryRegistry.directory(for: email)?.brandWebsiteURL
    }

    static func folded(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_NZ"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// Conservative parser for an institution-owned legacy profile page. Both the
/// page heading and an explicitly labelled profile image must name the same
/// person; a generic page logo is never accepted.
public enum InstitutionalProfilePage {
    public static func profileImage(html: String, base: URL, exactName: String) -> URL? {
        let headings = IconDiscovery.matches(#"<h1\b[^>]*>([\s\S]*?)</h1\s*>"#, html).compactMap {
            IconDiscovery.value($0, group: 1, in: html).map(plainText)
        }
        guard headings.contains(where: { InstitutionalProfilePolicy.folded($0) == InstitutionalProfilePolicy.folded(exactName) }) else { return nil }

        for match in IconDiscovery.matches(#"<img\b[^>]*>"#, html) {
            guard let tag = IconDiscovery.value(match, group: 0, in: html) else { continue }
            let attributes = IconDiscovery.attributes(tag)
            let classes = Set((attributes["class"] ?? "").lowercased().split(whereSeparator: \.isWhitespace).map(String.init))
            let alt = plainText(attributes["alt"] ?? "")
            guard classes.contains("profile-picture"),
                  InstitutionalProfilePolicy.folded(alt).contains(InstitutionalProfilePolicy.folded(exactName)),
                  let source = attributes["src"],
                  let url = URL(string: source, relativeTo: base)?.absoluteURL,
                  NetworkPolicy.isAllowedURL(url) else { continue }
            return url
        }
        return nil
    }

    private static func plainText(_ input: String) -> String {
        input.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

private struct DirectorySearchResponse: Decodable {
    let resource: [DirectoryUser]?
}
private struct DirectoryUser: Decodable {
    let firstNameLastName: String?
    let objectId: Int?
    let discoveryUrlId: String?
    let hasThumbnail: Bool?
}
private struct DirectoryThumbnail: Decodable { let thumbnail: String }

/// Request-capable resource client used by public directory adapters. Keeping
/// this separate from ordinary GET-only image fetching makes the external
/// request shape explicit and fixture-testable.
public protocol DirectoryResourceFetching: ResourceFetching {
    func fetch(_ request: URLRequest, limit: Int) async throws -> WebResource
}

extension SafeWebClient: DirectoryResourceFetching {}

/// Read-only public-directory resolver shared by all registered institutions.
/// It asks for one explicit display name and accepts only one exact full-name
/// result. An institution-specific legacy page strategy uses the same exact-name
/// gate and explicit profile-image gate.
public actor PublicInstitutionalProfiles: InstitutionalProfileSearching {
    let client: any DirectoryResourceFetching
    private var cache: [String: InstitutionalPortrait] = [:]
    private var knownMissing = Set<String>()

    public init(client: any DirectoryResourceFetching = SafeWebClient()) { self.client = client }

    public func portrait(email: EmailAddress, displayName: String?) async throws -> InstitutionalPortrait? {
        guard !email.isSharedProvider,let name = InstitutionalProfilePolicy.normalizedPersonName(displayName) else { return nil }
        let directory = InstitutionalDirectoryRegistry.directory(for: email)
        let key = (directory?.id ?? "organization") + "|" + email.value + "|" + InstitutionalProfilePolicy.folded(name)
        if let cached = cache[key] { return cached }
        if knownMissing.contains(key) { return nil }

        guard let directory else {
            if let portrait=try await organizationPortrait(email:email,name:name) {cache[key]=portrait;return portrait}
            knownMissing.insert(key);return nil
        }
        if let portrait = try await discoveryPortrait(directory: directory, name: name) {
            cache[key] = portrait
            return portrait
        }
        if let portrait = try await legacyPortrait(directory: directory, email: email, name: name) {
            cache[key] = portrait
            return portrait
        }
        knownMissing.insert(key)
        return nil
    }

    private func discoveryPortrait(directory: InstitutionalDirectory, name: String) async throws -> InstitutionalPortrait? {
        let payload: [String: Any] = [
            "params": ["by": "text", "category": "user", "text": name],
            "pagination": ["startFrom": 0, "perPage": 10],
            "filters": directory.filterNames.map {
                ["name": $0, "matchDocsWithMissingValues": true, "useValuesToFilter": false] as [String: Any]
            }
        ]
        var request = URLRequest(url: directory.apiBaseURL.appendingPathComponent("users"))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(directory.publicBaseURL.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(directory.publicBaseURL.appendingPathComponent("search").appending(queryItems: [
            .init(name: "type", value: "user")
        ]).absoluteString, forHTTPHeaderField: "Referer")

        let search = try await client.fetch(request, limit: 2_000_000)
        let response = try JSONDecoder().decode(DirectorySearchResponse.self, from: search.data)
        let exact = (response.resource ?? []).filter {
            guard let candidate = $0.firstNameLastName else { return false }
            return InstitutionalProfilePolicy.folded(candidate) == InstitutionalProfilePolicy.folded(name)
        }
        guard exact.count == 1, let user = exact.first, user.hasThumbnail == true,
              let objectID = user.objectId, let slug = user.discoveryUrlId,
              let matchedName = user.firstNameLastName else { return nil }

        let imageURL = directory.apiBaseURL.appendingPathComponent("users/\(objectID)/thumbnail")
        let thumbnailResource = try await client.fetch(imageURL, limit: 2_000_000)
        let image = try decodedThumbnail(thumbnailResource)
        return InstitutionalPortrait(
            matchedName: matchedName,
            profileURL: directory.publicBaseURL.appendingPathComponent(slug),
            image: WebResource(data: image.data, url: imageURL, contentType: image.contentType)
        )
    }

    private func legacyPortrait(directory: InstitutionalDirectory, email: EmailAddress, name: String) async throws -> InstitutionalPortrait? {
        guard !directory.legacyProfileBases.isEmpty else { return nil }
        var identifiers: [String] = []
        let local = email.value.split(separator: "@", maxSplits: 1).first.map(String.init) ?? ""
        for value in [local.split(separator: "+", maxSplits: 1).first.map(String.init) ?? local, name] {
            let tokens = value.split { !$0.isLetter }.map(String.init)
            guard tokens.count >= 2 else { continue }
            let joined = tokens.map { token in token.prefix(1).uppercased() + token.dropFirst() }.joined()
            let identifier = directory.legacyProfilePrefix + joined
            if !identifiers.contains(identifier) { identifiers.append(identifier) }
        }

        var firstUnexpectedError: Error?
        for base in directory.legacyProfileBases {
            for identifier in identifiers.prefix(2) {
                let pageURL = base.appendingPathComponent(identifier)
                do {
                    let page = try await client.fetch(pageURL, limit: 2_000_000)
                    let html = String(data: page.data, encoding: .utf8) ?? ""
                    guard let imageURL = InstitutionalProfilePage.profileImage(html: html, base: page.url, exactName: name) else { continue }
                    let image = try await client.fetch(imageURL, limit: 4_000_000)
                    return InstitutionalPortrait(matchedName: name, profileURL: page.url, image: image)
                } catch let error as HTTPResourceError where error.status == 404 {
                    continue
                } catch {
                    firstUnexpectedError = firstUnexpectedError ?? error
                }
            }
        }
        if let firstUnexpectedError { throw firstUnexpectedError }
        return nil
    }

    private func decodedThumbnail(_ resource: WebResource) throws -> (data: Data, contentType: String) {
        let encoded = try JSONDecoder().decode(DirectoryThumbnail.self, from: resource.data).thumbnail
        let body = encoded.components(separatedBy: ",").last ?? encoded
        guard let data = Data(base64Encoded: body, options: .ignoreUnknownCharacters), !data.isEmpty, data.count <= 4_000_000 else {
            throw PortraitError.message("The institution’s public profile returned invalid image data.")
        }
        let contentType: String
        if data.starts(with: [0x89, 0x50, 0x4e, 0x47]) { contentType = "image/png" }
        else if data.starts(with: [0x52, 0x49, 0x46, 0x46]) { contentType = "image/webp" }
        else if data.starts(with: [0xff, 0xd8, 0xff]) { contentType = "image/jpeg" }
        else { contentType = "application/octet-stream" }
        return (data, contentType)
    }
}

private extension URL {
    func appending(queryItems: [URLQueryItem]) -> URL {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)!
        components.queryItems = queryItems
        return components.url!
    }
}
