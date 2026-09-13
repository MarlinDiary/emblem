import XCTest
import AppKit
@testable import PortraitCore

actor SourceFixtureClient: ResourceFetching {
    var resources: [URL: WebResource]
    var requests: [URL] = []
    init(_ resources: [WebResource]) { self.resources = Dictionary(uniqueKeysWithValues: resources.map { ($0.url, $0) }) }
    func fetch(_ url: URL, limit: Int) async throws -> WebResource {
        try Task.checkCancellation(); requests.append(url)
        guard let resource = resources[url] else { throw PortraitError.message("Fixture HTTP 404") }
        return resource
    }
}
func sourcePNG(_ size: Int = 256) -> Data {
    let context=CGContext(data:nil,width:size,height:size,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(gray:1,alpha:1));context.fill(CGRect(x:0,y:0,width:size,height:size))
    context.setFillColor(CGColor(gray:0,alpha:1));context.fill(CGRect(x:size/3,y:size/3,width:size/3,height:size/3))
    return NSBitmapImageRep(cgImage:context.makeImage()!).representation(using:.png,properties:[:])!

}
final class SourceRegressionTests: XCTestCase {
    func testHomepageFailureStillFindsTouchIcon() async throws {
        let url = URL(string:"https://company.org/apple-touch-icon.png")!
        let client = SourceFixtureClient([WebResource(data:sourcePNG(),url:url)])
        let result = try await AvatarResolver(client:client).resolve(email:EmailAddress("hello@company.org")!,gravatar:false,website:true)
        XCTAssertTrue(result.candidates.contains { $0.source == .touchIcon && $0.width == 256 }, "A missing homepage must not hide an existing high-resolution touch icon")
    }
    func testTinyGravatarDoesNotOutrankUsableWebsiteImage() {
        let tiny = AvatarCandidate(source:.gravatar,origin:"fixture",width:32,height:32,png:Data())
        let large = AvatarCandidate(source:.touchIcon,origin:"fixture",width:180,height:180,png:Data())
        XCTAssertGreaterThan(large.score,tiny.score,"Source priority must not promote a blurry avatar over a usable image")
    }
}
