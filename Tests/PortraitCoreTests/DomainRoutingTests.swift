import XCTest
@testable import PortraitCore

final class DomainRoutingTests: XCTestCase {
    func testBundledPSLIncludesCountryAndPrivateBoundaries() {
        let cases = ["tm.openai.com":"openai.com","mail.bbc.co.uk":"bbc.co.uk","news.auckland.ac.nz":"auckland.ac.nz","news.alice.github.io":"alice.github.io","letters.alice.blogspot.com":"alice.blogspot.com"]
        for (host,root) in cases { XCTAssertEqual(DomainRouting.primaryHost(for:host),root) }
        XCTAssertNil(PublicSuffixRules.bundled.registrableDomain("co.uk"))
        XCTAssertNil(PublicSuffixRules.bundled.registrableDomain("github.io"))
    }
    func testWildcardExceptionsAndUnknownTLD() {
        let rules = PublicSuffixRules("com\n*.ck\n!www.ck\n*.kawasaki.jp\n!city.kawasaki.jp")
        XCTAssertEqual(rules.registrableDomain("a.www.ck"),"www.ck")
        XCTAssertEqual(rules.registrableDomain("a.b.ck"),"a.b.ck")
        XCTAssertEqual(rules.registrableDomain("www.city.kawasaki.jp"),"city.kawasaki.jp")
        XCTAssertEqual(rules.registrableDomain("A.B.UNLISTED"),"b.unlisted")
        XCTAssertNil(rules.registrableDomain("b.ck"))
    }
    func testOverrideIsAuthoritativeAndProviderSubdomainIsSkipped() {
        XCTAssertTrue(DomainRouting.websites(for:EmailAddress("a@news.gmail.com")!).isEmpty)
        let override = URL(string:"https://support.apple.com/")!
        XCTAssertEqual(DomainRouting.websites(for:EmailAddress("a@news.gmail.com")!,override:override),[override])
    }
    func testRootFailureFallsBackToOriginalSubdomain() async throws {
        let base = URL(string:"https://news.company.org/")!
        let client = SourceFixtureClient([.init(data:sourcePNG(256),url:base.appendingPathComponent("apple-touch-icon.png"))])
        let result = try await AvatarResolver(client:client).resolve(email:EmailAddress("a@news.company.org")!,gravatar:false,website:true)
        let requests = await client.requests
        XCTAssertEqual(requests.first?.host,"company.org")
        XCTAssertEqual(result.candidates.first?.origin,base.appendingPathComponent("apple-touch-icon.png").absoluteString)
        XCTAssertEqual(Set(result.reports.map(\.id)).count,result.reports.count)
    }
    func testMaskablePurposeAndOldCandidateDecoding() throws {
        let base = URL(string:"https://company.org/")!
        let data = Data(#"{"icons":[{"src":"/a.png","purpose":"any maskable"},{"src":"/b.png","purpose":"monochrome"},{"src":"/c.png","purpose":"unknown"}]}"#.utf8)
        let refs = IconDiscovery.manifestIcons(data:data,base:base)
        XCTAssertEqual(refs.count,1); XCTAssertTrue(refs[0].maskable)
        let c = AvatarCandidate(source:.manifest,origin:"a",width:192,height:192,png:Data())
        var old = try JSONSerialization.jsonObject(with:JSONEncoder().encode(c)) as! [String:Any]
        old.removeValue(forKey:"maskable")
        let decoded = try JSONDecoder().decode(AvatarCandidate.self,from:JSONSerialization.data(withJSONObject:old))
        XCTAssertNil(decoded.maskable)
    }
    func testWideWordmarkAndTinyImagesAreNotAutomaticChoices() {
        XCTAssertFalse(AvatarCandidate(source:.favicon,origin:"a",width:800,height:200,vector:true,png:Data()).recommendedAutomatically)
        XCTAssertFalse(AvatarCandidate(source:.manifest,origin:"a",width:32,height:32,png:Data(),maskable:true).recommendedAutomatically)
        XCTAssertTrue(AvatarCandidate(source:.favicon,origin:"a",width:32,height:32,vector:true,png:Data()).recommendedAutomatically)
    }
}
