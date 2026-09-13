import XCTest
import AppKit
@testable import PortraitCore

private actor V092DirectoryFixture: DirectoryResourceFetching {
    private let resources: [URL: WebResource]
    private(set) var requests: [URL] = []

    init(_ resources: [WebResource]) {
        self.resources = Dictionary(uniqueKeysWithValues: resources.map { ($0.url, $0) })
    }

    func fetch(_ url: URL, limit: Int) async throws -> WebResource {
        requests.append(url)
        guard let resource = resources[url] else { throw HTTPResourceError(status: 404) }
        return resource
    }

    func fetch(_ request: URLRequest, limit: Int) async throws -> WebResource {
        guard let url = request.url else { throw HTTPResourceError(status: 400) }
        requests.append(url)
        guard let resource = resources[url] else { throw HTTPResourceError(status: 404) }
        return resource
    }
}

private func v092PNG(width: Int = 256, height: Int = 256, draw: (CGContext) -> Void) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(context)
    return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
}

private func v092Pixel(_ data: Data, x: Int, y: Int) throws -> NSColor {
    let image = try XCTUnwrap(NSBitmapImageRep(data: data))
    return try XCTUnwrap(image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
}

final class V092RegressionTests: XCTestCase {
    func testInstitutionDirectoriesAreRoutedByDeclarativeRegistry() throws {
        let auckland = try XCTUnwrap(InstitutionalDirectoryRegistry.directory(for: EmailAddress("person@cs.auckland.ac.nz")!))
        XCTAssertEqual(auckland.publicHost, "profiles.auckland.ac.nz")

        let wellington = try XCTUnwrap(InstitutionalDirectoryRegistry.directory(for: EmailAddress("person@vuw.ac.nz")!))
        XCTAssertEqual(wellington.publicHost, "people.wgtn.ac.nz")
        XCTAssertEqual(wellington.emailDomains, ["vuw.ac.nz", "wgtn.ac.nz"])
        XCTAssertTrue(wellington.legacyProfileBases.contains(URL(string: "https://ecs.wgtn.ac.nz/Main/")!))

        XCTAssertTrue(InstitutionalProfilePolicy.isEligible(email: EmailAddress("jens.dietrich@vuw.ac.nz")!, displayName: "Jens Dietrich"))
        XCTAssertFalse(InstitutionalProfilePolicy.isEligible(email: EmailAddress("support@vuw.ac.nz")!, displayName: "Student Support"))
        XCTAssertTrue(InstitutionalProfilePolicy.keepsMailboxIndependent(EmailAddress("one@vuw.ac.nz")!))
    }

    func testOfficialLegacyProfileRequiresExactHeadingAndExplicitProfileImage() throws {
        let base = URL(string: "https://ecs.wgtn.ac.nz/Main/GradXiangGuo")!
        let html = """
        <h1 class="fs-title">School of Engineering and Computer Science</h1>
        <h1 id="Shawn_Guo"> Shawn Guo </h1>
        <img alt='Shawn Guo profile picture' class="profile-picture"
             src="https://ecs.wgtn.ac.nz/foswiki/pub/Main/GradXiangGuo/XiangGuo.jpg">
        """
        XCTAssertEqual(
            InstitutionalProfilePage.profileImage(html: html, base: base, exactName: "Shawn Guo")?.absoluteString,
            "https://ecs.wgtn.ac.nz/foswiki/pub/Main/GradXiangGuo/XiangGuo.jpg"
        )
        XCTAssertNil(InstitutionalProfilePage.profileImage(html: html, base: base, exactName: "Xiang Guo"))
        XCTAssertNil(InstitutionalProfilePage.profileImage(
            html: "<h1>Shawn Guo</h1><img src='https://ecs.wgtn.ac.nz/logo.png'>",
            base: base,
            exactName: "Shawn Guo"
        ))
    }

    func testRegisteredDirectoryResolverUsesOneExactResult() async throws {
        let api = URL(string: "https://people.wgtn.ac.nz/api/users")!
        let thumbnail = URL(string: "https://people.wgtn.ac.nz/api/users/2611/thumbnail")!
        let search = #"{"resource":[{"firstNameLastName":"Jens Dietrich","objectId":2611,"discoveryUrlId":"jens.dietrich","hasThumbnail":true}]}"#
        let photo = v092PNG(width: 240, height: 240) { context in
            context.setFillColor(CGColor(gray: 0.4, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 240, height: 240))
        }
        let encoded = try JSONSerialization.data(withJSONObject: ["thumbnail": photo.base64EncodedString()])
        let client = V092DirectoryFixture([
            .init(data: Data(search.utf8), url: api, contentType: "application/json"),
            .init(data: encoded, url: thumbnail, contentType: "application/json")
        ])
        let portrait = try await PublicInstitutionalProfiles(client: client).portrait(
            email: EmailAddress("jens.dietrich@vuw.ac.nz")!, displayName: "Dr Jens Dietrich"
        )
        XCTAssertEqual(portrait?.matchedName, "Jens Dietrich")
        XCTAssertEqual(portrait?.profileURL.absoluteString, "https://people.wgtn.ac.nz/jens.dietrich")
        let requests = await client.requests
        XCTAssertEqual(requests, [api, thumbnail])
    }

    func testLegacyDirectoryUsesSameExactNameGate() async throws {
        let api = URL(string: "https://people.wgtn.ac.nz/api/users")!
        let page = URL(string: "https://ecs.wgtn.ac.nz/Main/GradXiangGuo")!
        let image = URL(string: "https://ecs.wgtn.ac.nz/foswiki/pub/Main/GradXiangGuo/XiangGuo.jpg")!
        let html = """
        <h1>Shawn Guo</h1>
        <img class='profile-picture' alt='Shawn Guo profile picture' src='\(image.absoluteString)'>
        """
        let photo = v092PNG(width: 500, height: 500) { context in
            context.setFillColor(CGColor(gray: 0.4, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 500, height: 500))
        }
        let client = V092DirectoryFixture([
            .init(data: Data(#"{"resource":[]}"#.utf8), url: api, contentType: "application/json"),
            .init(data: Data(html.utf8), url: page, contentType: "text/html"),
            .init(data: photo, url: image, contentType: "image/png")
        ])
        let portrait = try await PublicInstitutionalProfiles(client: client).portrait(
            email: EmailAddress("xiang.guo@vuw.ac.nz")!, displayName: "Shawn Guo"
        )
        XCTAssertEqual(portrait?.matchedName, "Shawn Guo")
        XCTAssertEqual(portrait?.profileURL, page)
        let requests = await client.requests
        XCTAssertEqual(requests, [api, page, image])
    }

    func testNeutralRoundedSquareIsRecognisedAsAComposedCanvas() throws {
        let data = v092PNG { context in
            context.setFillColor(CGColor(red: 0.082, green: 0.102, blue: 0.122, alpha: 1))
            context.addPath(CGPath(roundedRect: CGRect(x: 16, y: 16, width: 224, height: 224),
                                   cornerWidth: 54, cornerHeight: 54, transform: nil))
            context.fillPath()
            context.setFillColor(CGColor(gray: 0.97, alpha: 1))
            context.fill(CGRect(x: 102, y: 63, width: 15, height: 130))
            context.setFillColor(CGColor(red: 0.13, green: 0.78, blue: 0.71, alpha: 1))
            context.fillEllipse(in: CGRect(x: 143, y: 161, width: 29, height: 29))
        }
        let candidate = try ImagePipeline.decode(
            .init(data: data, url: URL(string: "https://rewrite.so/apple-touch-icon.png")!),
            source: .touchIcon
        )
        XCTAssertEqual(candidate.effectiveFraming, .brandCanvas)
        let corner = try v092Pixel(candidate.png, x: 0, y: 0)
        XCTAssertLessThan(corner.redComponent, 0.3)
        XCTAssertLessThan(corner.greenComponent, 0.3)
        XCTAssertLessThan(corner.blueComponent, 0.3)
    }

    func testComposedNonMaskableCanvasGetsOpticalInsetWithoutLosingItsBackdrop() throws {
        let blue = CGColor(red: 10 / 255, green: 102 / 255, blue: 194 / 255, alpha: 1)
        let data = v092PNG(width: 240, height: 220) { context in
            context.setFillColor(blue)
            context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 224, height: 220),
                                   cornerWidth: 20, cornerHeight: 20, transform: nil))
            context.fillPath()
            context.setBlendMode(.clear)
            context.fill(CGRect(x: 32, y: 84, width: 34, height: 104))
            context.fill(CGRect(x: 87, y: 84, width: 102, height: 104))
        }
        let candidate = try ImagePipeline.decode(
            .init(data: data, url: URL(string: "https://brand.linkedin.com/in-logo.png")!),
            source: .officialBrand
        )
        XCTAssertEqual(candidate.effectiveFraming, .brandCanvas)
        XCTAssertEqual(candidate.layoutRevision, ImagePipeline.currentLayoutRevision)
        let edge = try v092Pixel(candidate.png, x: 0, y: 110)
        XCTAssertGreaterThan(edge.blueComponent, edge.redComponent)

        let rep = try XCTUnwrap(NSBitmapImageRep(data: candidate.png))
        let firstWhite = (0..<rep.pixelsWide).first { x in
            guard let c = rep.colorAt(x: x, y: 110)?.usingColorSpace(.deviceRGB) else { return false }
            return c.redComponent > 0.9 && c.greenComponent > 0.9 && c.blueComponent > 0.9
        }
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(firstWhite), 38, "The mark should have a small general optical safety inset")
    }

    func testFlatInstitutionalPlaceholderIsRejectedEvenWhenLarge() {
        let placeholder = v092PNG(width: 500, height: 500) { context in
            context.setFillColor(CGColor(gray: 0.88, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 500, height: 500))
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fillEllipse(in: CGRect(x: 170, y: 48, width: 160, height: 190))
            context.fill(CGRect(x: 95, y: 260, width: 310, height: 190))
        }
        XCTAssertThrowsError(try ImagePipeline.decode(
            .init(data: placeholder, url: URL(string: "https://institution.org/placeholder.png")!),
            source: .institutionProfile
        ))
    }
}
