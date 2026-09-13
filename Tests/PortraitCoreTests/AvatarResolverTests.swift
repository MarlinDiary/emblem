import XCTest
@testable import PortraitCore

struct StatusClient: ResourceFetching {
    let status: Int
    func fetch(_ url:URL,limit:Int) async throws -> WebResource { throw HTTPResourceError(status:status) }
}
struct CancelClient: ResourceFetching {
    func fetch(_ url:URL,limit:Int) async throws -> WebResource { try await Task.sleep(nanoseconds:30_000_000_000); throw CancellationError() }
}
final class AvatarResolverTests: XCTestCase {
    private let email=EmailAddress("hello@company.org")!
    func testNoSourcesMeansNoNetworkRequests() async throws {
        let client=SourceFixtureClient([])
        let result=try await AvatarResolver(client:client).resolve(email:email,gravatar:false,website:false)
        let requests=await client.requests
        XCTAssertTrue(requests.isEmpty); XCTAssertEqual(result.reports.count,2)
        XCTAssertTrue(result.reports.allSatisfy { $0.outcome == .skipped })
    }
    func testSharedMailboxSkipsProviderLogo() async throws {
        let client=SourceFixtureClient([])
        let result=try await AvatarResolver(client:client).resolve(email:EmailAddress("person@gmail.com")!,gravatar:false,website:true)
        let requests=await client.requests
        XCTAssertTrue(requests.isEmpty); XCTAssertEqual(result.reports.last?.outcome,.skipped)
    }
    func testExplicitSiteCanBeUsedWithSharedMailbox() async throws {
        let base=URL(string:"https://company.org/")!
        let client=SourceFixtureClient([.init(data:sourcePNG(),url:base.appendingPathComponent("apple-touch-icon.png"))])
        let result=try await AvatarResolver(client:client).resolve(email:EmailAddress("person@gmail.com")!,gravatar:false,website:true,websiteOverride:base)
        let requests=await client.requests
        XCTAssertEqual(result.candidates.count,1); XCTAssertFalse(requests.contains { $0.host == "gmail.com" })
    }
    func testGravatar404IsMissingNotFakeAvatar() async throws {
        let result=try await AvatarResolver(client:StatusClient(status:404)).resolve(email:email,gravatar:true,website:false)
        XCTAssertTrue(result.candidates.isEmpty); XCTAssertEqual(result.reports.first?.outcome,.missing)
    }
    func testGravatar503IsFailureNotNoAccount() async throws {
        let result=try await AvatarResolver(client:StatusClient(status:503)).resolve(email:email,gravatar:true,website:false)
        XCTAssertEqual(result.reports.first?.outcome,.unavailable)
        XCTAssertTrue(result.reports.first!.detail.contains("503"))
    }
    func testManifestRelativeURLAndTrueDimensions() async throws {
        let base=URL(string:"https://company.org/")!
        let resources:[WebResource]=[
            .init(data:Data("<link rel='manifest' href='/assets/app.json'>".utf8),url:base),
            .init(data:Data(#"{"icons":[{"src":"big.png","sizes":"999x999"}]}"#.utf8),url:base.appendingPathComponent("assets/app.json")),
            .init(data:sourcePNG(192),url:base.appendingPathComponent("assets/big.png"))]
        let result=try await AvatarResolver(client:SourceFixtureClient(resources)).resolveWebsite(at:base)
        XCTAssertEqual(result.candidates.first?.width,192); XCTAssertEqual(result.candidates.first?.source,.manifest)
        XCTAssertEqual(result.reports.first { $0.source == .manifest }?.count,1)
    }
    func testBatchReusesWebsiteButDoesNotMixPersonalAvatar() async throws {
        let base=URL(string:"https://company.org/")!
        let client=SourceFixtureClient([.init(data:Data("<html/>".utf8),url:base)])
        let resolver=AvatarResolver(client:client)
        _=try await resolver.resolve(email:email,gravatar:true,website:true)
        _=try await resolver.resolve(email:EmailAddress("other@company.org")!,gravatar:true,website:true)
        let requests=await client.requests
        XCTAssertEqual(requests.filter { $0 == base }.count,1)
        XCTAssertEqual(Set(requests.filter { $0.host == "www.gravatar.com" }).count,2)
    }
    func testNewResolverDoesNotReuseEarlierConsentSessionCache() async throws {
        let base=URL(string:"https://company.org/")!,client=SourceFixtureClient([])
        _=try await AvatarResolver(client:client).resolveWebsite(at:base)
        _=try await AvatarResolver(client:client).resolveWebsite(at:base)
        let requests=await client.requests
        XCTAssertEqual(requests.filter { $0 == base }.count,2)
    }
    func testEqualImagesAreDeduplicated() async throws {
        let base=URL(string:"https://company.org/")!
        let client=SourceFixtureClient([.init(data:Data("<link rel='icon' href='/copy.png'>".utf8),url:base),.init(data:sourcePNG(),url:base.appendingPathComponent("copy.png")),.init(data:sourcePNG(),url:base.appendingPathComponent("apple-touch-icon.png"))])
        let result=try await AvatarResolver(client:client).resolveWebsite(at:base)
        XCTAssertEqual(result.candidates.count,1)
    }
    func testIconServerFailureIsNotReportedAsNoImage() async throws {
        let result=try await AvatarResolver(client:StatusClient(status:503)).resolveWebsite(at:URL(string:"https://company.org/")!)
        XCTAssertEqual(result.reports.first { $0.source == .touchIcon }?.outcome,.unavailable)
        XCTAssertEqual(result.reports.first { $0.source == .favicon }?.outcome,.unavailable)
    }
    func testPlainDomainAndHTTPSOnlyWebsiteInput() {
        XCTAssertEqual(WebsiteAddress.parse(" company.org ")?.absoluteString,"https://company.org")
        for value in ["http://company.org","file:///tmp/x","https://localhost","https://company.org?token=x","https://name:secret@company.org","https://company.org/#profile",""] { XCTAssertNil(WebsiteAddress.parse(value),value) }
    }
    func testRecommendationsCollapseSizesAndExcludeLowResolution() {
        let images=[AvatarCandidate(source:.manifest,origin:"a",width:512,height:512,png:Data()),AvatarCandidate(source:.manifest,origin:"b",width:192,height:192,png:Data()),AvatarCandidate(source:.favicon,origin:"c",width:32,height:32,png:Data())]
        XCTAssertEqual(CandidateSelection.recommended(images).map(\.origin),["a"])
    }
    func testLowResolutionOnlyResultsAreExcluded() {
        let tiny=AvatarCandidate(source:.favicon,origin:"a",width:32,height:32,png:Data())
        XCTAssertTrue(CandidateSelection.recommended([tiny]).isEmpty)
        XCTAssertTrue(tiny.lowResolution)
    }
    func testCancellationDoesNotReturnAnEmptySuccess() async throws {
        let task=Task { try await AvatarResolver(client:CancelClient()).resolveWebsite(at:URL(string:"https://company.org/")!) }
        task.cancel()
        do { _=try await task.value; XCTFail("Cancellation must propagate") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }
}
