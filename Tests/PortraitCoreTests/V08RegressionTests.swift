import XCTest
import AppKit
@testable import PortraitCore

private actor V08SourceClient: ResourceFetching {
    let image: Data
    var requests: [URL] = []
    init(image: Data) { self.image=image }
    func fetch(_ url:URL,limit:Int) async throws -> WebResource {
        requests.append(url)
        if url.host == "www.gravatar.com" || url.host == "seccdn.libravatar.org" { return .init(data:image,url:url) }
        throw HTTPResourceError(status:404)
    }
}
private actor V08ProfileClient: ResourceFetching {
    let page = URL(string:"https://people.company.org/valerio")!
    let portrait = URL(string:"https://media.company.org/valerio.jpg")!
    let image: Data
    var requests: [URL] = []
    init(image: Data) { self.image = image }
    func fetch(_ url: URL, limit: Int) async throws -> WebResource {
        requests.append(url)
        if url == page {
            return .init(data: Data("<meta property='og:image' content='https://media.company.org/valerio.jpg'>".utf8), url: url)
        }
        if url == portrait { return .init(data: image, url: url) }
        throw HTTPResourceError(status: 404)
    }
}
private func v08PNG(width:Int,height:Int,draw:(CGContext)->Void) -> Data {
    let c=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(c)
    return NSBitmapImageRep(cgImage:c.makeImage()!).representation(using:.png,properties:[:])!
}
private func v08PortraitPNG(width: Int, height: Int) -> Data {
    v08PNG(width: width, height: height) { context in
        for stripe in 0..<64 {
            let red = CGFloat(stripe % 8) / 14
            let green = CGFloat((stripe / 8) % 8) / 14
            let blue = CGFloat((stripe * 5) % 8) / 14
            context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
            let x0 = CGFloat(stripe * width) / 64
            let x1 = CGFloat((stripe + 1) * width) / 64
            context.fill(CGRect(x: x0, y: 0, width: x1 - x0 + 1, height: CGFloat(height)))
        }
    }
}
final class V08RegressionTests: XCTestCase {
    func testPersonPhotoUsesCenterFillInsteadOfWhiteLetterbox() throws {
        let data=v08PortraitPNG(width:400,height:200)
        let candidate=try ImagePipeline.decode(.init(data:data,url:URL(string:"https://www.gravatar.com/avatar/hash")!),source:.gravatar)
        let image=try XCTUnwrap(NSBitmapImageRep(data:candidate.png))
        let top=try XCTUnwrap(image.colorAt(x:image.pixelsWide/2,y:5)?.usingColorSpace(.deviceRGB))
        XCTAssertLessThan(top.redComponent,0.2,"A portrait should crop excess width and fill the circular preview, not add white bars")
    }
    func testNonMaskableSquareLogoIsInsetIntoCircleSafeArea() throws {
        let data=v08PNG(width:256,height:256) { c in
            c.setFillColor(CGColor(gray:1,alpha:1));c.fill(CGRect(x:0,y:0,width:256,height:256))
            c.setFillColor(CGColor(gray:0,alpha:1))
            for r in [CGRect(x:0,y:0,width:36,height:36),CGRect(x:220,y:0,width:36,height:36),CGRect(x:0,y:220,width:36,height:36),CGRect(x:220,y:220,width:36,height:36)] { c.fill(r) }
        }
        let candidate=try ImagePipeline.decode(.init(data:data,url:URL(string:"https://company.org/icon.png")!),source:.favicon)
        let image=try XCTUnwrap(NSBitmapImageRep(data:candidate.png))
        let corner=try XCTUnwrap(image.colorAt(x:8,y:8)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(corner.redComponent,0.9,"Corner artwork must be scaled inside the circle-safe square instead of being clipped")
    }
    func testEmailAvatarLookupTriesOpenFederatedAndGravatarSources() async throws {
        let image=v08PNG(width:256,height:256) { c in c.setFillColor(CGColor(gray:0.2,alpha:1));c.fill(CGRect(x:0,y:0,width:256,height:256)) }
        let client=V08SourceClient(image:image)
        _=try await AvatarResolver(client:client).resolve(email:EmailAddress("person@company.org")!,gravatar:true,website:false)
        let hosts=Set(await client.requests.compactMap(\.host))
        XCTAssertTrue(hosts.contains("seccdn.libravatar.org"),"Try the open federated email-avatar source")
        XCTAssertTrue(hosts.contains("www.gravatar.com"),"Try Gravatar independently")
    }
    func testProfileMetadataPrefersOpenGraphImage() {
        let base=URL(string:"https://social.example.net/in/person")!
        let html="<meta content='/twitter.jpg' name='twitter:image'><meta content='https://cdn.example.net/person.jpg' property='og:image'>"
        XCTAssertEqual(ProfileDiscovery.image(html:html,base:base)?.absoluteString,"https://cdn.example.net/person.jpg")
        XCTAssertNil(ProfileDiscovery.image(html:"<meta property='og:image' content='http://127.0.0.1/x'>",base:base))
    }
    func testConfirmedProfilePageFetchesDeclaredPortraitAndUsesPersonFraming() async throws {
        let image=v08PortraitPNG(width:400,height:200)
        let client=V08ProfileClient(image:image)
        let result=try await AvatarResolver(client:client).resolve(email:EmailAddress("valerio@company.org")!,gravatar:false,website:false,profileURL:client.page)
        XCTAssertEqual(result.candidates.first?.source,.profile)
        XCTAssertEqual(result.candidates.first?.effectiveFraming,.personFill)
        XCTAssertEqual(result.reports.first(where:{ $0.source == .profile })?.outcome,.found)
        let requests=await client.requests
        XCTAssertEqual(requests,[client.page,client.portrait])
    }

}
