import Foundation

public enum LookupSource: String, Codable, CaseIterable, Sendable {
    case website, officialBrand, bimi, siteLogo, touchIcon, manifest, favicon, domainIcon, gravatar, profile, institutionProfile
    public var title: String {
        switch self { case .website: return "Website"; case .officialBrand: return "Official Brand"; case .bimi: return "BIMI"; case .siteLogo: return "Website Logo"; case .touchIcon: return "Apple Touch Icon"; case .manifest: return "Web App Icon"; case .favicon: return "SVG / Favicon"; case .domainIcon: return "Domain Icon"; case .gravatar: return "Portrait Services"; case .profile: return "Public Profile"; case .institutionProfile: return "Public Directory" }
    }
    public var symbol: String {
        switch self { case .website: return "globe"; case .officialBrand: return "checkmark.seal"; case .bimi: return "checkmark.shield"; case .siteLogo: return "building.2"; case .touchIcon: return "bookmark"; case .manifest: return "app.dashed"; case .favicon: return "safari"; case .domainIcon: return "network"; case .gravatar: return "person.crop.circle"; case .profile: return "person.text.rectangle"; case .institutionProfile: return "building.2.crop.circle" }
    }
}
public enum SourceOutcome: String, Codable, Sendable { case found, missing, skipped, unavailable }
public struct SourceReport: Identifiable, Codable, Sendable {
    public var id: String { source.rawValue + "|" + (target ?? "") }
    public var source: LookupSource
    public var outcome: SourceOutcome
    public var count: Int
    public var detail: String
    public var target: String?
    public init(_ source: LookupSource, _ outcome: SourceOutcome, count: Int = 0, detail: String, target: String? = nil) {
        self.source=source; self.outcome=outcome; self.count=count; self.detail=detail; self.target=target
    }
}
public struct LookupResult: Sendable {
    public var candidates: [AvatarCandidate]
    public var notes: [String]
    public var reports: [SourceReport]
    public var checkedAt: Date
    public init(candidates: [AvatarCandidate], notes: [String] = [], reports: [SourceReport] = [], checkedAt: Date = Date()) {
        self.candidates=candidates; self.notes=notes; self.reports=reports; self.checkedAt=checkedAt
    }
}
public enum WebsiteAddress {
    public static func parse(_ text: String) -> URL? {
        let raw=text.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !raw.isEmpty, let url=URL(string:raw.contains("://") ? raw : "https://"+raw), NetworkPolicy.isAllowedURL(url), url.query == nil, url.fragment == nil else { return nil }
        return url
    }
}

private struct IconFetchAttempt: Sendable { var source: CandidateSource; var image: AvatarCandidate?; var failure: String? }
private struct PersonFetchAttempt: Sendable { var source: CandidateSource; var image: AvatarCandidate?; var missing: Bool; var failure: String? }
private struct NoInstitutionalLookup: InstitutionalProfileSearching {
    func portrait(email:EmailAddress,displayName:String?)async throws->InstitutionalPortrait? {nil}
}
private struct NoBIMILookup: BIMILogoResolving {
    func logo(for domain: String) async throws -> BIMILogo? { nil }
}

// Session cache is bounded and expires; the app recreates it when source consent changes.
public actor AvatarResolver {
    private let client: ResourceFetching
    private let profiles: any InstitutionalProfileSearching
    private let bimi: any BIMILogoResolving
    private let domainIcons: any DomainIconURLProviding
    private var websites: [URL: LookupResult] = [:]
    /// Production entry point: real bounded HTTPS plus the Mac's configured DNS.
    public init() {
        self.client=SafeWebClient(); self.profiles=PublicInstitutionalProfiles(); self.bimi=PublicBIMI(); self.domainIcons=GoogleSiteIconProvider()
    }
    /// Dependency-injected entry point. BIMI is opt-in here so deterministic
    /// resource fixtures never leak into the machine's live DNS resolver.
    public init(client: ResourceFetching, profiles: (any InstitutionalProfileSearching)? = nil, bimi: (any BIMILogoResolving)? = nil, domainIcons: (any DomainIconURLProviding)? = nil) {
        self.client=client; self.profiles=profiles ?? (client as? any DirectoryResourceFetching).map {PublicInstitutionalProfiles(client:$0)} ?? NoInstitutionalLookup(); self.bimi=bimi ?? NoBIMILookup(); self.domainIcons=domainIcons ?? NoDomainIconProvider()
    }
    public func resolve(email: EmailAddress, displayName: String? = nil, gravatar: Bool, website: Bool, websiteOverride: URL? = nil, profileURL: URL? = nil) async throws -> LookupResult {
        try await withDeadline(seconds:25) {
            try await self.resolveWithinBudget(email:email,displayName:displayName,gravatar:gravatar,website:website,websiteOverride:websiteOverride,profileURL:profileURL)
        }
    }
    private func resolveWithinBudget(email: EmailAddress, displayName: String?, gravatar: Bool, website: Bool, websiteOverride: URL?, profileURL: URL?) async throws -> LookupResult {
        try Task.checkCancellation()
        var result=LookupResult(candidates:[])
        if gravatar {
            let client=self.client
            let attempts=try await withThrowingTaskGroup(of:PersonFetchAttempt.self) { group in
                for (url,source) in [(email.libravatarURL,CandidateSource.libravatar),(email.gravatarURL,.gravatar)] {
                    group.addTask {
                        do { return .init(source:source,image:try ImagePipeline.decode(await client.fetch(url,limit:4_000_000),source:source),missing:false,failure:nil) }
                        catch { try Task.checkCancellation(); return .init(source:source,image:nil,missing:(error as? HTTPResourceError)?.status == 404,failure:error.localizedDescription) }
                    }
                }
                var found:[PersonFetchAttempt]=[]
                for try await attempt in group { found.append(attempt) }
                return found.sorted { $0.source.rawValue < $1.source.rawValue }
            }
            result.candidates += attempts.compactMap(\.image)
            let count=attempts.compactMap(\.image).count
            let unavailable=attempts.first { !$0.missing && $0.image == nil }
            result.reports.append(.init(.gravatar,count > 0 ? .found : unavailable == nil ? .missing : .unavailable,count:count,
                detail:count > 0 ? "Checked Libravatar and Gravatar; person photos use a centered circular crop." : unavailable?.failure ?? "Neither portrait service matched; no generated image is presented as a person photo.",
                target:"libravatar.org + gravatar.com"))
        } else { result.reports.append(.init(.gravatar,.skipped,detail:"Portrait services are off, so no email hash was sent.")) }
        if let profileURL {
            do {
                let page=try await client.fetch(profileURL,limit:2_000_000)
                guard let imageURL=ProfileDiscovery.image(html:String(data:page.data,encoding:.utf8) ?? "",base:page.url) else { throw PortraitError.message("The profile page does not declare a usable person image.") }
                let image=try ImagePipeline.decode(await client.fetch(imageURL,limit:4_000_000),source:.profile)
                result.candidates.append(image)
                result.reports.append(.init(.profile,.found,count:1,detail:"Read the image from the confirmed public profile page; identity was not guessed from a name.",target:page.url.host))
            } catch {
                try Task.checkCancellation()
                result.reports.append(.init(.profile,.unavailable,detail:error.localizedDescription,target:profileURL.host))
            }
        }
        if website && InstitutionalProfilePolicy.isEligible(email: email, displayName: displayName) {
            let directoryTarget = InstitutionalProfilePolicy.directoryHost(for: email) ?? "organization public directory"
            do {
                if let portrait = try await profiles.portrait(email: email, displayName: displayName) {
                    let image = try ImagePipeline.decode(portrait.image, source: .institutionProfile)
                    result.candidates.append(image)
                    result.reports.append(.init(.institutionProfile, .found, count: 1, detail: "The organization directory has one exact full-name match; its public portrait was read.", target: portrait.profileURL.absoluteString))
                    result.notes.append("Person profile: \(portrait.matchedName) · \(portrait.profileURL.absoluteString)")
                } else {
                    result.reports.append(.init(.institutionProfile, .missing, detail: "The organization directory has no unique exact-name match; similar names and organization marks were not substituted.", target: directoryTarget))
                }
            } catch {
                try Task.checkCancellation()
                result.reports.append(.init(.institutionProfile, .unavailable, detail: error.localizedDescription, target: directoryTarget))
            }
        }
        var foundStrongBIMI = false
        if website {
            if result.candidates.contains(where: { $0.source == .institutionProfile && $0.recommendedAutomatically }) {
                result.reports.append(.init(.bimi, .skipped, detail: "A unique organization portrait was found and takes priority."))
            } else if email.isSharedProvider {
                result.reports.append(.init(.bimi, .skipped, detail: "Shared mailbox: the provider’s BIMI brand mark is not used as a person photo."))
            } else {
                do {
                    if let published = try await bimi.logo(for: email.domain) {
                        let image = try ImagePipeline.decode(await client.fetch(published.logoURL, limit: 4_000_000), source: .bimi)
                        result.candidates.append(image)
                        foundStrongBIMI = image.visuallyUsable && image.circularSuitable
                        result.reports.append(.init(.bimi, .found, count: 1, detail: "The sender domain publishes a BIMI logo in DNS; the record domain and source URL are preserved.", target: published.recordDomain))
                        result.notes.append("BIMI source: default._bimi.\(published.recordDomain) → \(published.logoURL.absoluteString)")
                    } else {
                        result.reports.append(.init(.bimi, .missing, detail: "Neither the sender host nor its registrable domain publishes a usable default BIMI logo.", target: email.domain))
                    }
                } catch {
                    try Task.checkCancellation()
                    result.reports.append(.init(.bimi, .unavailable, detail: error.localizedDescription, target: email.domain))
                }
            }
        }
        if website {
            if result.candidates.contains(where: { $0.source == .institutionProfile && $0.recommendedAutomatically }) {
                result.notes.append("A unique matching person portrait was found, so an organization mark will not replace it.")
            } else if foundStrongBIMI {
                result.notes.append("A clear domain-published BIMI mark was found, so weaker website icons will not replace it.")
            } else if email.isSharedProvider && websiteOverride == nil {
                result.reports.append(.init(.website,.skipped,detail:"Shared mailbox: the provider logo is skipped."))
            } else {
                var sites = DomainRouting.websites(for:email,override:websiteOverride)
                if websiteOverride == nil, let canonical = InstitutionalProfilePolicy.brandWebsiteURL(for: email),
                   !sites.contains(canonical) { sites.insert(canonical, at: 0) }
                for (index, site) in sites.enumerated() {
                    let found = try await resolveWebsite(at:site)
                    result.candidates += found.candidates; result.reports += found.reports; result.notes += found.notes
                    if index == 0, site.host != email.domain, websiteOverride == nil {
                        result.notes.append("The registrable domain is checked first: \(email.domain) → \(site.host ?? ""). The original host is tried only when no suitable image is found.")
                    }
                    if found.candidates.contains(where: { $0.visuallyUsable && $0.circularSuitable }) { break }
                }
            }
        } else { result.reports.append(.init(.website,.skipped,detail:"Website sources are off, so no website or icon service was requested.")) }
        let hasClearFirstParty = result.candidates.contains { $0.source != .domainIcon && $0.visuallyUsable && $0.circularSuitable }
        if website, !email.isSharedProvider, !hasClearFirstParty,
           let iconURL = domainIcons.iconURL(for: email.domain) {
            let target = DomainRouting.primaryHost(for: email.domain)
            do {
                let image = try ImagePipeline.decode(await client.fetch(iconURL, limit: 4_000_000), source: .domainIcon)
                result.candidates.append(image)
                result.reports.append(.init(.domainIcon, .found, count: 1, detail: "The website had no clear candidate; the domain icon service returned a decodable image. Only the registrable domain was sent.", target: target))
            } catch {
                try Task.checkCancellation()
                let missing = (error as? HTTPResourceError)?.status == 404 || error.localizedDescription.contains("below")
                result.reports.append(.init(.domainIcon, missing ? .missing : .unavailable, detail: missing ? "The domain icon service has no image meeting the quality threshold." : error.localizedDescription, target: target))
            }
        } else if website, hasClearFirstParty {
            result.reports.append(.init(.domainIcon, .skipped, detail: "A higher-confidence first-party source already exists, so the third-party domain icon service was not requested."))
        }
        result.candidates=Self.ranked(result.candidates)
        if result.candidates.isEmpty { result.notes.append("No match yet. You can choose a local photo.") }
        return result
    }
    // Public-domain preview: no email address or Contacts access is needed.
    public func resolveWebsite(at base: URL) async throws -> LookupResult {
        try await withDeadline(seconds:25) { try await self.resolveWebsiteWithinBudget(at:base) }
    }
    private func resolveWebsiteWithinBudget(at base: URL) async throws -> LookupResult {
        try Task.checkCancellation()
        guard NetworkPolicy.isAllowedURL(base) else { throw PortraitError.message("Enter a public HTTPS website.") }
        if let cached=websites[base], Date().timeIntervalSince(cached.checkedAt) < (cached.candidates.isEmpty ? 3600 : 86400) { return cached }
        var result=LookupResult(candidates:[])
        if let official = OfficialBrandAssets.asset(for: base) {
            do {
                let resource:WebResource
                if let local=OfficialBrandAssets.bundledURL(for:official) {resource=try .init(data:Data(contentsOf:local),url:official.assetURL,contentType:"image/svg+xml")}
                else {resource=try await client.fetch(official.assetURL,limit:4_000_000)}
                let image = try ImagePipeline.decode(resource, source: .officialBrand, artwork: official.artwork)
                result.candidates = [image]
                result.reports.append(.init(.officialBrand, .found, count: 1, detail: "\(official.description); the evidence page and source image URL are preserved.", target: official.evidenceURL.absoluteString))
                result.notes.append("Official source: \(official.evidenceURL.absoluteString)")
                if image.visuallyUsable && image.circularSuitable && (image.visualQuality?.contrast ?? 1) >= 0.5 {
                    websites[base] = result
                    return result
                }
            } catch {
                try Task.checkCancellation()
                result.reports.append(.init(.officialBrand, .unavailable, detail: "The official asset could not be read; website-provided icons will still be checked. \(error.localizedDescription)", target: official.evidenceURL.absoluteString))
            }
        }
        var refs=IconDiscovery.links(html:"",base:base).icons
        var manifestURL: URL?
        do {
            let page=try await client.fetch(base,limit:2_000_000)
            let html=String(data:page.data,encoding:.utf8) ?? ""
            let links=IconDiscovery.links(html:html,base:page.url)
            refs=links.icons; manifestURL=links.manifest
            refs += StructuredLogoDiscovery.urls(html: html, base: page.url).map { .init(url: $0, source: .siteLogo) }
            result.reports.append(.init(.website,.found,detail:"Read the icons and app manifest declared by the page.",target:page.url.host))
        } catch {
            try Task.checkCancellation()
            // A mail domain may have no homepage; conventional icons can still exist.
            result.reports.append(.init(.website,.unavailable,detail:"The home page could not be read; standard icon paths will still be checked. \(error.localizedDescription)",target:base.host))
        }
        var manifestFailure: String?
        if let manifest=manifestURL {
            do {
                let resource=try await client.fetch(manifest,limit:256_000)
                refs += IconDiscovery.manifestIcons(data:resource.data,base:resource.url)
            } catch { try Task.checkCancellation(); manifestFailure=error.localizedDescription }
        }
        func priority(_ reference: IconReference) -> Int {
            if reference.declared { return reference.source == .siteLogo ? 0 : 1 }
            return 2
        }
        refs.sort { priority($0) < priority($1) }
        var seen=Set<URL>()
        refs=Array(refs.filter { seen.insert($0.url).inserted }.prefix(24))
        // Fetch a small high-confidence stage first. Once a declared, maskable,
        // or structured logo passes the compact automatic gate, do not wait for slow
        // conventional fallback paths that cannot improve the selected result.
        // Compare declared favicons alongside touch/app icons. The old four-URL
        // stage could be filled by manifest sizes before a favicon was tried.
        let preferred = Array(refs.filter { $0.declared }.prefix(8))
        let preferredURLs = Set(preferred.map(\.url))
        let remaining = refs.filter { !preferredURLs.contains($0.url) }
        var attempts = try await fetchIcons(preferred)
        let skipped = attempts.compactMap(\.image).contains { $0.visuallyUsable && $0.circularSuitable } ? remaining : []
        if skipped.isEmpty { attempts += try await fetchIcons(remaining) }
        let skippedSources = Set(skipped.map(\.source))
        result.candidates += attempts.compactMap(\.image)
        for (kind,source) in [(LookupSource.siteLogo,CandidateSource.siteLogo),(.touchIcon,.touchIcon),(.manifest,.manifest),(.favicon,.favicon)] {
            let count=result.candidates.filter { $0.source == source }.count
            let failure=attempts.first { $0.source == source && $0.failure != nil }?.failure
            let detail: String
            if count > 0 { detail="Found \(count) decodable images, ranked by actual dimensions." }
            else if skippedSources.contains(source) { detail="A higher-confidence, circle-suitable declared image already exists, so weaker fallback paths were not awaited." }
            else if let failure { detail="The request did not finish: \(failure)" }
            else if kind == .siteLogo { detail="The website does not declare a usable Schema.org Organization.logo." }
            else if kind == .manifest, let error=manifestFailure { detail="The manifest could not be read: \(error)" }
            else if kind == .manifest, manifestURL == nil { detail="The page does not declare a Web App Manifest." }
            else { detail="No usable image was found; a generated icon is not presented as a match." }
            let outcome: SourceOutcome = count > 0 ? .found : skippedSources.contains(source) ? .skipped : (manifestFailure != nil && kind == .manifest) || failure != nil ? .unavailable : .missing
            result.reports.append(.init(kind,outcome,count:count,detail:detail,target:base.host))
        }
        result.candidates=Self.ranked(result.candidates)
        result.notes.append("Website icons represent a site or organization, not a person, and do not establish that an email is trustworthy.")
        if websites.count >= 64, let oldest = websites.min(by:{ $0.value.checkedAt < $1.value.checkedAt })?.key { websites.removeValue(forKey:oldest) }
        websites[base]=result
        return result
    }

    private func fetchIcons(_ refs: [IconReference]) async throws -> [IconFetchAttempt] {
        guard !refs.isEmpty else { return [] }
        // At most four icon requests are in flight; every request still uses SafeWebClient.
        let client=self.client
        return try await withThrowingTaskGroup(of:IconFetchAttempt.self) { group in
            var next=0, found:[IconFetchAttempt]=[]
            func enqueue(_ ref:IconReference) {
                group.addTask {
                    try Task.checkCancellation()
                    do {
                        var image = try ImagePipeline.decode(await client.fetch(ref.url,limit:4_000_000),source:ref.source,maskable:ref.maskable)
                        image.declared = ref.declared
                        return IconFetchAttempt(source:ref.source,image:image,failure:nil)
                    }
                    catch { try Task.checkCancellation(); return IconFetchAttempt(source:ref.source,image:nil,failure:(error as? HTTPResourceError)?.status == 404 ? nil : error.localizedDescription) }
                }
            }
            while next < min(4,refs.count) { enqueue(refs[next]); next += 1 }
            while let image=try await group.next() {
                found.append(image)
                if next < refs.count { enqueue(refs[next]); next += 1 }
            }
            return found
        }
    }
    private static func ranked(_ candidates:[AvatarCandidate]) -> [AvatarCandidate] {
        var seen=Set<String>()
        return candidates.sorted { $0.score == $1.score ? $0.origin < $1.origin : $0.score > $1.score }.filter { seen.insert(digest($0.png)).inserted }
    }
}

public enum CandidateSelection {
    /// Use the same ranking for fresh lookups and unsorted, persisted candidates.
    public static func automaticChoice(_ candidates: [AvatarCandidate]) -> AvatarCandidate? {
        candidates.filter(\.recommendedAutomatically).sorted {
            $0.score == $1.score ? $0.origin < $1.origin : $0.score > $1.score
        }.first
    }
    // Show one clear option per source first, not a wall of the same logo in every size.
    public static func recommended(_ candidates: [AvatarCandidate]) -> [AvatarCandidate] {
        let clear=candidates.filter(\.visuallyUsable).sorted { $0.score == $1.score ? $0.origin < $1.origin : $0.score > $1.score }
        var sources=Set<CandidateSource>()
        return clear.filter { sources.insert($0.source).inserted }
    }
}
