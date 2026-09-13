import XCTest
@testable import PortraitCore

final class AutomaticSourceRegressionTests: XCTestCase {
    func testCompanySubdomainFindsRegistrableWebsiteFirst() async throws {
        let base = URL(string:"https://openai.com/")!
        let client = SourceFixtureClient([.init(data:sourcePNG(256),url:base.appendingPathComponent("apple-touch-icon.png"))])
        let result = try await AvatarResolver(client:client).resolve(email:EmailAddress("noreply@tm.openai.com")!,gravatar:false,website:true)
        let requests = await client.requests
        XCTAssertEqual(requests.first,base)
        XCTAssertFalse(result.candidates.isEmpty)
        XCTAssertFalse(requests.contains { $0.host == "tm.openai.com" })
    }
    func testMaskableArtworkWinsOverLargerUnmaskedIcon() async throws {
        let base = URL(string:"https://company.org/")!
        let client = SourceFixtureClient([
            .init(data:Data("<link rel='manifest' href='/app.json'>".utf8),url:base),
            .init(data:Data(#"{"icons":[{"src":"/round.png","purpose":"maskable"}]}"#.utf8),url:base.appendingPathComponent("app.json")),
            .init(data:sourcePNG(192),url:base.appendingPathComponent("round.png")),
            .init(data:sourcePNG(512),url:base.appendingPathComponent("apple-touch-icon.png"))])
        let result = try await AvatarResolver(client:client).resolveWebsite(at:base)
        XCTAssertEqual(result.candidates.first?.origin,base.appendingPathComponent("round.png").absoluteString)
    }
}
