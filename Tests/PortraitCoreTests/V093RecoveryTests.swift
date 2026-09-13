import XCTest
import AppKit
@testable import PortraitCore

private actor TXTFixture: TXTRecordFetching {
    let values: [String: [String]]
    private(set) var names: [String] = []

    init(_ values: [String: [String]]) { self.values = values }

    func records(named name: String) async throws -> [String] {
        names.append(name)
        return values[name] ?? []
    }
}

private struct BIMIFixture: BIMILogoResolving {
    let logo: BIMILogo?
    func logo(for domain: String) async throws -> BIMILogo? { logo }
}

private func recoveryPNG() -> Data {
    let size = 256
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.05, green: 0.28, blue: 0.70, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fillEllipse(in: CGRect(x: 68, y: 68, width: 120, height: 120))
    return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
}

final class V093RecoveryTests: XCTestCase {
    func testBIMIParserAcceptsHTTPSLogoAndRejectsUnsafeOrEmptyLocations() {
        XCTAssertEqual(
            BIMIRecord.logoURL(from: "v=BIMI1; a=https://assets.company.org/cert.pem; l=https://assets.company.org/logo.svg;"),
            URL(string: "https://assets.company.org/logo.svg")
        )
        XCTAssertNil(BIMIRecord.logoURL(from: "v=BIMI1; l=http://assets.company.org/logo.svg"))
        XCTAssertNil(BIMIRecord.logoURL(from: "v=BIMI1; l=; a="))
        XCTAssertNil(BIMIRecord.logoURL(from: "v=DMARC1; l=https://assets.company.org/logo.svg"))
    }

    func testBIMILookupFallsBackFromSenderSubdomainToRegistrableDomain() async throws {
        let fixture = TXTFixture([
            "default._bimi.company.org": ["v=BIMI1; l=https://assets.company.org/logo.svg;"]
        ])
        let result = try await PublicBIMI(records: fixture).logo(for: "mail.company.org")
        XCTAssertEqual(result?.recordDomain, "company.org")
        XCTAssertEqual(result?.logoURL.absoluteString, "https://assets.company.org/logo.svg")
        let names = await fixture.names
        XCTAssertEqual(names, ["default._bimi.mail.company.org", "default._bimi.company.org"])
    }

    func testSquareBIMICanvasKeepsWideInnerMarkForReviewWithoutAutoSelectingIt() {
        let image = AvatarCandidate(
            source: .bimi,
            origin: "https://assets.company.org/logo.svg",
            width: 192,
            height: 192,
            vector: true,
            png: recoveryPNG(),
            framing: .brandSafe,
            subjectWidth: 150,
            subjectHeight: 34
        )
        XCTAssertFalse(image.circularSuitable)
        XCTAssertFalse(image.recommendedAutomatically)
        XCTAssertEqual(image.effectiveFraming, .brandSafe)
    }

    func testNearSquareStructuredLogoIsSafeInsetButSocialCardRemainsUnselected() {
        let logo = AvatarCandidate(source: .siteLogo, origin: "fixture", width: 120, height: 120, vector: true,
                                   png: recoveryPNG(), framing: .brandSafe, subjectWidth: 711, subjectHeight: 423)
        let socialCard = AvatarCandidate(source: .siteLogo, origin: "fixture", width: 1200, height: 628,
                                         png: recoveryPNG(), framing: .brandSafe, subjectWidth: 1200, subjectHeight: 628)
        XCTAssertTrue(logo.recommendedAutomatically)
        XCTAssertFalse(socialCard.recommendedAutomatically)
    }

    func testResolverUsesDomainPublishedBIMIBeforeWeakWebsiteFallbacks() async throws {
        let logoURL = URL(string: "https://assets.company.org/logo.svg")!
        let client = SourceFixtureClient([.init(data: recoveryPNG(), url: logoURL, contentType: "image/png")])
        let bimi = BIMIFixture(logo: .init(recordDomain: "company.org", logoURL: logoURL))
        let result = try await AvatarResolver(client: client, bimi: bimi).resolve(
            email: EmailAddress("news@mail.company.org")!, gravatar: false, website: true
        )
        XCTAssertEqual(result.candidates.first?.source, .bimi)
        XCTAssertEqual(result.reports.first(where: { $0.source == .bimi })?.outcome, .found)
        let requests = await client.requests
        XCTAssertEqual(requests, [logoURL])
    }

    func testStructuredOrganizationLogoIsExtractedWithoutUsingOpenGraphHeroImages() throws {
        let base = URL(string: "https://company.org/")!
        let html = #"""
        <meta property="og:image" content="/campaign-hero.jpg">
        <script type="application/ld+json">
        {"@context":"https://schema.org","@type":"Organization","name":"Brand","logo":{"@type":"ImageObject","contentUrl":"/assets/logo.svg"}}
        </script>
        """#
        XCTAssertEqual(StructuredLogoDiscovery.urls(html: html, base: base), [URL(string: "https://company.org/assets/logo.svg")!])
    }

    func testWebsiteResolverFetchesStructuredLogoAsItsOwnAuditableSource() async throws {
        let base = URL(string: "https://company.org/")!
        let logo = URL(string: "https://company.org/assets/logo.png")!
        let html = #"<script type="application/ld+json">{"@type":"Organization","logo":"/assets/logo.png"}</script>"#
        let client = SourceFixtureClient([
            .init(data: Data(html.utf8), url: base, contentType: "text/html"),
            .init(data: recoveryPNG(), url: logo, contentType: "image/png")
        ])
        let result = try await AvatarResolver(client: client, bimi: BIMIFixture(logo: nil)).resolveWebsite(at: base)
        XCTAssertEqual(result.candidates.first?.source, .siteLogo)
        XCTAssertEqual(result.reports.first(where: { $0.source == .siteLogo })?.outcome, .found)
    }

    func testDeclaredClearIconSkipsSlowConventionalFallbackPaths() async throws {
        let base = URL(string: "https://institution.org/")!
        let declared = base.appendingPathComponent("assets/identity.png")
        let html = #"<link rel="icon" href="/assets/identity.png">"#
        let client = SourceFixtureClient([
            .init(data: Data(html.utf8), url: base, contentType: "text/html"),
            .init(data: recoveryPNG(), url: declared, contentType: "image/png")
        ])
        let result = try await AvatarResolver(client: client).resolveWebsite(at: base)
        XCTAssertEqual(result.candidates.first?.origin, declared.absoluteString)
        let requests = await client.requests
        XCTAssertFalse(requests.contains(base.appendingPathComponent("apple-touch-icon.png")))
        XCTAssertEqual(result.reports.first(where: { $0.source == .touchIcon })?.outcome, .skipped)
    }

    func testInstitutionAliasUsesSharedDirectoryAndCanonicalBrandWebsite() throws {
        let directory = try XCTUnwrap(InstitutionalDirectoryRegistry.directory(for: EmailAddress("person@aucklanduni.ac.nz")!))
        XCTAssertEqual(directory.id, "auckland-discovery")
        XCTAssertEqual(directory.brandWebsiteURL, URL(string: "https://www.auckland.ac.nz/"))
        XCTAssertTrue(InstitutionalProfilePolicy.keepsMailboxIndependent(EmailAddress("person@aucklanduni.ac.nz")!))
    }
}
