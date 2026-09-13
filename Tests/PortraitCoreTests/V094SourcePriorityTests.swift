import XCTest
import AppKit
@testable import PortraitCore

private struct DomainIconFixture: DomainIconURLProviding {
    let url: URL?
    func iconURL(for domain: String) -> URL? { url }
}

final class V094SourcePriorityTests: XCTestCase {
    func testBIMIIsStrictlyTheHighestAutomaticBrandSource() {
        let png = sourcePNG(180)
        let bimi = AvatarCandidate(source: .bimi, origin: "bimi", width: 128, height: 128, png: png)
        let official = AvatarCandidate(source: .officialBrand, origin: "official", width: 2048, height: 2048, vector: true, png: png)
        let touch = AvatarCandidate(source: .touchIcon, origin: "touch", width: 512, height: 512, png: png)
        XCTAssertGreaterThan(bimi.score, official.score)
        XCTAssertGreaterThan(bimi.score, touch.score)
    }

    func testWideBIMIWordmarkYieldsToCircleSuitableTouchIcon() {
        let bimi = AvatarCandidate(source: .bimi, origin: "bimi", width: 512, height: 512, vector: true, png: Data(), framing: .brandCanvas, subjectWidth: 420, subjectHeight: 92)
        let touch = AvatarCandidate(source: .touchIcon, origin: "touch", width: 256, height: 256, png: Data(), framing: .brandCanvas, subjectWidth: 150, subjectHeight: 138)
        XCTAssertFalse(bimi.recommendedAutomatically)
        XCTAssertTrue(touch.recommendedAutomatically)
    }

    func testHigherResolutionManifestCanBeatAnOrdinaryTouchIcon() {
        let png = sourcePNG(180)
        let manifest = AvatarCandidate(source: .manifest, origin: "manifest", width: 512, height: 512, png: png)
        let touch = AvatarCandidate(source: .touchIcon, origin: "touch", width: 256, height: 256, png: png)
        XCTAssertGreaterThan(manifest.score, touch.score)
    }

    func testGoogleSiteIconURLContainsOnlyTheRegistrableDomainAndRequestedSize() throws {
        let url = try XCTUnwrap(GoogleSiteIconProvider().iconURL(for: "mail.company.co.nz"))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "www.google.com")
        XCTAssertEqual(components.path, "/s2/favicons")
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }), [
            "domain_url": "https://company.co.nz",
            "sz": "256"
        ])
    }

    func testResolverUsesDomainIconServiceOnlyAfterFirstPartySourcesYieldNothing() async throws {
        let base = URL(string: "https://company.org/")!
        let fallback = URL(string: "https://icons.test/company.png")!
        let client = SourceFixtureClient([
            .init(data: Data("<html></html>".utf8), url: base, contentType: "text/html"),
            .init(data: sourcePNG(256), url: fallback, contentType: "image/png")
        ])
        let resolver = AvatarResolver(client: client, domainIcons: DomainIconFixture(url: fallback))
        let result = try await resolver.resolve(email: EmailAddress("hello@company.org")!, gravatar: false, website: true)
        XCTAssertEqual(result.candidates.first?.source, .domainIcon)
        XCTAssertEqual(result.reports.first(where: { $0.source == .domainIcon })?.outcome, .found)
        let requests = await client.requests
        XCTAssertTrue(requests.contains(fallback))
    }

    func testDeclaredIconCanvasPreservesNeutralDesignerLayout() throws {
        let size = 256
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.addPath(CGPath(rect: CGRect(x: 80, y: 70, width: 96, height: 116), transform: nil)); context.fillPath()
        let data = NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
        let candidate = try ImagePipeline.decode(.init(data: data, url: URL(string: "https://company.org/apple-touch-icon.png")!), source: .touchIcon)
        XCTAssertEqual(candidate.effectiveFraming, .brandCanvas)
    }
}
