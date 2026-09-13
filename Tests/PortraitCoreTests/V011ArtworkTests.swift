import XCTest
import AppKit
@testable import PortraitCore

final class V011ArtworkTests: XCTestCase {
    func testOfficialLogoIsNotRecoloredIntoAppIconCanvas() throws {
        let c=CGContext(data:nil,width:240,height:220,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(red:0.04,green:0.4,blue:0.76,alpha:1))
        c.fill(CGRect(x:0,y:0,width:224,height:220))
        c.setBlendMode(.clear); c.fill(CGRect(x:35,y:45,width:42,height:132))
        let png=NSBitmapImageRep(cgImage:c.makeImage()!).representation(using:.png,properties:[:])!
        let a=try ImagePipeline.decode(.init(data:png,url:URL(string:"https://brand.linkedin.com/logo.png")!),source:.officialBrand,artwork:.logo)
        XCTAssertEqual(a.effectiveFraming,.brandSafe)
        XCTAssertEqual(a.artwork,.logo)
        let rep=try XCTUnwrap(NSBitmapImageRep(data:a.png))
        let corner=try XCTUnwrap(rep.colorAt(x:0,y:0)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(corner.redComponent,0.95); XCTAssertGreaterThan(corner.greenComponent,0.95)
    }
    func testMetadataDistinguishesLogoFromAppIconInsteadOfDomainHeuristics() throws {
        XCTAssertEqual(OfficialBrandAssets.asset(for:URL(string:"https://linkedin.com")!)?.artwork,.logo)
        XCTAssertEqual(OfficialBrandAssets.asset(for:URL(string:"https://raycast.com")!)?.artwork,.appIcon)
    }
    func testStoredCorrectlyFramedLogoDoesNotGetRecroppedOnMigration() throws {
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"256\" height=\"256\"><rect x=\"20\" y=\"20\" width=\"216\" height=\"216\" fill=\"blue\"/></svg>"
        let c=try ImagePipeline.decode(.init(data:Data(svg.utf8),url:URL(string:"https://brand.linkedin.com/logo.svg")!),source:.officialBrand,artwork:.logo)
        XCTAssertEqual(try ImagePipeline.reframeStoredBrand(c).png,c.png)
    }
}
