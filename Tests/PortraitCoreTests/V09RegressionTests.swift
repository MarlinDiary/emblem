import XCTest
import AppKit
@testable import PortraitCore

private struct V09DirectoryFixture: InstitutionalProfileSearching {
    let result: InstitutionalPortrait?
    init(portrait: InstitutionalPortrait?) { result = portrait }
    func portrait(email: EmailAddress, displayName: String?) async throws -> InstitutionalPortrait? { result }
}

private actor V09WebFixture: ResourceFetching {
    let resources: [URL: WebResource]
    var requests: [URL] = []
    init(_ resources: [WebResource]) { self.resources = Dictionary(uniqueKeysWithValues: resources.map { ($0.url, $0) }) }
    func fetch(_ url: URL, limit: Int) async throws -> WebResource {
        requests.append(url)
        guard let resource = resources[url] else { throw HTTPResourceError(status: 404) }
        return resource
    }
}

private func v09PNG(width: Int, height: Int, draw: (CGContext) -> Void) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(context)
    return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
}

final class V09RegressionTests: XCTestCase {
    func testOfficialCatalogUsesRealFirstPartyEvidenceAndHighResolutionAssets() throws {
        let raycast = try XCTUnwrap(OfficialBrandAssets.asset(for: URL(string: "https://raycast.com")!))
        XCTAssertEqual(raycast.evidenceURL.host, "www.raycast.com")
        XCTAssertTrue(raycast.assetURL.absoluteString.contains("raycast-appicon.png"))

        let adidas = try XCTUnwrap(OfficialBrandAssets.asset(for: URL(string: "https://adidas.com")!))
        XCTAssertEqual(adidas.evidenceURL.host, "www.adidas-group.com")
        XCTAssertTrue(adidas.assetURL.absoluteString.contains("3-Bar_Logo"))
    }

    func testRegionalSenderDomainAddsNewZealandStoreFallbackEvenWithRootOverride() {
        let email = EmailAddress("adidas@nz-info.adidas.com")!
        let urls = DomainRouting.websites(for: email, override: URL(string: "https://adidas.com")!)
        XCTAssertEqual(urls.map(\.host), ["adidas.com", "adidas.co.nz"])
    }

    func testOfficialAssetShortCircuitsBlockedHomepageAndWinsSelection() async throws {
        let record = try XCTUnwrap(OfficialBrandAssets.asset(for: URL(string: "https://adidas.com")!))
        let logo = v09PNG(width: 1200, height: 843) { context in
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1200, height: 843))
            context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(CGRect(x: 360, y: 100, width: 480, height: 643))
        }
        let client = V09WebFixture([.init(data: logo, url: record.assetURL, contentType: "image/png")])
        let result = try await AvatarResolver(client: client, profiles: V09DirectoryFixture(portrait: nil))
            .resolveWebsite(at: URL(string: "https://adidas.com")!)
        XCTAssertEqual(result.candidates.first?.source, .officialBrand)
        XCTAssertEqual(result.reports.first?.source, .officialBrand)
        let requests = await client.requests
        XCTAssertEqual(requests, [record.assetURL], "A curated official asset should avoid a known blocked storefront")
    }

    func testAucklandExactNameDirectoryPortraitIsAutomaticallyPreferred() async throws {
        let data = v09PNG(width: 180, height: 180) { context in
            for stripe in 0..<64 {
                context.setFillColor(CGColor(red: CGFloat(stripe % 8) / 10,
                                             green: CGFloat((stripe / 8) % 8) / 10,
                                             blue: CGFloat((stripe * 3) % 8) / 10, alpha: 1))
                let x0 = CGFloat(stripe) * 180 / 64, x1 = CGFloat(stripe + 1) * 180 / 64
                context.fill(CGRect(x: x0, y: 0, width: x1 - x0 + 1, height: 180))
            }
        }
        let profile = InstitutionalPortrait(
            matchedName: "Valerio Terragni",
            profileURL: URL(string: "https://profiles.auckland.ac.nz/v-terragni")!,
            image: .init(data: data, url: URL(string: "https://profiles.auckland.ac.nz/api/users/112687/thumbnail")!, contentType: "image/png")
        )
        let client = V09WebFixture([])
        let result = try await AvatarResolver(client: client, profiles: V09DirectoryFixture(portrait: profile))
            .resolve(email: EmailAddress("v.terragni@auckland.ac.nz")!, displayName: "Valerio Terragni", gravatar: false, website: true)
        XCTAssertEqual(result.candidates.first?.source, .institutionProfile)
        XCTAssertEqual(result.candidates.first?.effectiveFraming, .personFill)
        XCTAssertEqual(result.reports.first(where: { $0.source == .institutionProfile })?.outcome, .found)
        XCTAssertTrue(result.candidates.first?.recommendedAutomatically == true)
    }

    func testInstitutionDirectoryOnlyQueriesClearPersonNames() {
        XCTAssertTrue(InstitutionalProfilePolicy.isEligible(email: EmailAddress("elliott.wen@auckland.ac.nz")!, displayName: "Elliott Wen"))
        XCTAssertFalse(InstitutionalProfilePolicy.isEligible(email: EmailAddress("studentinfo@auckland.ac.nz")!, displayName: "University of Auckland"))
        XCTAssertFalse(InstitutionalProfilePolicy.isEligible(email: EmailAddress("science-events@auckland.ac.nz")!, displayName: "Science Events"))
        // General organization profiles now use a strict email-and-name gate.
        XCTAssertTrue(InstitutionalProfilePolicy.isEligible(email: EmailAddress("person@raycast.com")!, displayName: "Ray Cast"))
        XCTAssertFalse(InstitutionalProfilePolicy.isEligible(email: EmailAddress("person@outlook.com")!, displayName: "Ray Cast"))
    }

    func testPrecomposedColoredAppIconAvoidsSecondInset() throws {
        let data = v09PNG(width: 256, height: 256) { context in
            context.setFillColor(CGColor(red: 0.68, green: 0.08, blue: 0.18, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fillEllipse(in: CGRect(x: 72, y: 72, width: 112, height: 112))
        }
        let candidate = try ImagePipeline.decode(.init(data: data, url: URL(string: "https://raycast.com/app-icon.png")!), source: .officialBrand)
        XCTAssertEqual(candidate.effectiveFraming, .brandCanvas)
    }

    func testBrandArtworkTrimsLargeWhiteMarginsBeforeCircleSafeLayout() throws {
        let data = v09PNG(width: 1200, height: 843) { context in
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1200, height: 843))
            context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(CGRect(x: 390, y: 90, width: 420, height: 663))
        }
        let candidate = try ImagePipeline.decode(.init(data: data, url: URL(string: "https://res.cloudinary.com/confirmed-web/image/upload/adidas-logo.jpg")!), source: .officialBrand)
        XCTAssertEqual(candidate.effectiveFraming, .brandSafe)
        XCTAssertLessThan(candidate.subjectWidth ?? 1200, 600)
        XCTAssertGreaterThan(candidate.subjectHeight ?? 0, 600)
        XCTAssertTrue(candidate.recommendedAutomatically)
    }
}
