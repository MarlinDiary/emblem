import XCTest
@testable import PortraitCore

private struct PublishedAmazonBIMI: BIMILogoResolving {
    let url: URL
    func logo(for domain: String) async throws -> BIMILogo? { .init(recordDomain:domain,logoURL:url) }
}
final class V0121LookupContinuationTests: XCTestCase {
    func testWideBIMIDoesNotStopLookingForACompactOfficialIcon() async throws {
        guard let state=ProcessInfo.processInfo.environment["EMBLEM_AMAZON_STATE"] else { throw XCTSkip("captured Amazon artwork opt-in") }
        struct Row:Decodable { var candidates:[AvatarCandidate] }
        let captured=try JSONDecoder().decode([Row].self,from:Data(contentsOf:URL(fileURLWithPath:state)))
        let original=try XCTUnwrap(captured.first?.candidates.first { $0.source == .bimi })
        let bimiURL=try XCTUnwrap(URL(string:original.origin))
        let homepage=URL(string:"https://amazon.com.au/")!,touch=URL(string:"https://amazon.com.au/apple-touch-icon.png")!
        let page=WebResource(data:Data(#"<link rel="apple-touch-icon" href="/apple-touch-icon.png">"#.utf8),url:homepage,contentType:"text/html")
        let resource=WebResource(data:original.png,url:bimiURL,contentType:"image/png")
        let icon=WebResource(data:sourcePNG(256),url:touch,contentType:"image/png")
        let client=SourceFixtureClient([resource,page,icon])
        let resolver=AvatarResolver(client:client,bimi:PublishedAmazonBIMI(url:bimiURL))
        let result=try await resolver.resolve(email:EmailAddress("prime@amazon.com.au")!,gravatar:false,website:true)
        let published=try XCTUnwrap(result.candidates.first { $0.source == .bimi })
        XCTAssertTrue(published.recommendedAutomatically)
        XCTAssertFalse(published.circularSuitable)
        XCTAssertEqual(CandidateSelection.automaticChoice(result.candidates)?.source,.touchIcon)
        let requests=await client.requests
        XCTAssertTrue(requests.contains(homepage));XCTAssertTrue(requests.contains(touch))
        // Identical BIMI pixels with every website route unavailable still win
        // over initials. All fetches are intercepted; no live Mail/Contacts/API.
        let missingSite=SourceFixtureClient([resource])
        let fallback=try await AvatarResolver(client:missingSite,bimi:PublishedAmazonBIMI(url:bimiURL)).resolve(email:EmailAddress("prime@amazon.com.au")!,gravatar:false,website:true)
        XCTAssertEqual(CandidateSelection.automaticChoice(fallback.candidates)?.source,.bimi)
        print("AMAZON_LOOKUP COMPACT_AVAILABLE=touchIcon WEBSITE_UNAVAILABLE=bimi WIDE_BIMI_SHORT_CIRCUIT=false NETWORK_REQUESTS=0")
    }
}
