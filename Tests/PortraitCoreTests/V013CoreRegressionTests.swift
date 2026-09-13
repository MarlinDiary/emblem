import XCTest
import AppKit
@testable import PortraitCore
final class V013CoreRegressionTests: XCTestCase {
    private func assets() throws -> URL { guard let root=ProcessInfo.processInfo.environment["MAILPORTRAIT_V013_ASSETS"] else { throw XCTSkip("real asset corpus opt-in") };return URL(fileURLWithPath:root) }
    func testCurrentlyDeclaredFaviconBeatsConventionalTouchInPersistedCandidates() throws {
        let root=try assets()
        let rows=try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("corpus.json"))) as! [[String:Any]]
        let row=try XCTUnwrap(rows.first { ($0["email"] as? String)?.contains("sevenrooms.com") == true })
        let candidates=try (row["candidates"] as! [[String:Any]]).map { entry -> AvatarCandidate in
            var entry=entry;entry["png"]=try Data(contentsOf:root.appendingPathComponent(entry["file"] as! String)).base64EncodedString()
            entry["declared"]=(entry["source"] as? String)=="favicon"
            return try JSONDecoder().decode(AvatarCandidate.self,from:JSONSerialization.data(withJSONObject:entry))
        }
        XCTAssertEqual(CandidateSelection.automaticChoice(candidates)?.source,.favicon)
        print("SEVENROOMS preferred=\(CandidateSelection.automaticChoice(candidates)?.source.rawValue ?? "none")")
    }
    func testMaskableDeclarationDoesNotPermitVisibleLogoClipping() throws {
        let root=try assets();let data=try Data(contentsOf:root.appendingPathComponent("asset-877a783995.original"))
        let c=try ImagePipeline.decode(.init(data:data,url:URL(string:"https://bellroy.com/web-app-manifest-512x512.png")!),source:.manifest,maskable:true)
        XCTAssertNotEqual(c.effectiveFraming,.brandMaskable)
        let rep=try XCTUnwrap(NSBitmapImageRep(data:c.png));var ink=0,clipped=0
        for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide {
            let color=try XCTUnwrap(rep.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB))
            if color.redComponent-color.blueComponent>0.25 && color.alphaComponent>0.5 {
                ink+=1;let dx=(Double(x)+0.5)/Double(rep.pixelsWide)-0.5,dy=(Double(y)+0.5)/Double(rep.pixelsHigh)-0.5
                if dx*dx+dy*dy>0.25 { clipped+=1 }
            }
        } }
        let fraction=Double(clipped)/Double(max(1,ink));XCTAssertLessThan(fraction,0.001)
        try c.png.write(to:root.appendingPathComponent("bellroy-after.png"))
        print("BELLROY framing=\(c.effectiveFraming.rawValue) CLIPPED_INK_FRACTION=\(fraction)")
    }
    func testGoogleHasAFirstPartyUnframedHighResolutionSource() throws {
        let asset=try XCTUnwrap(OfficialBrandAssets.asset(for:URL(string:"https://google.com/")!))
        XCTAssertEqual(asset.artwork,.logo)
        let c=try ImagePipeline.decode(.init(data:Data(contentsOf:try assets().appendingPathComponent("google-official-logo.png")),url:asset.assetURL,contentType:"image/png"),source:.officialBrand,artwork:asset.artwork)
        XCTAssertGreaterThanOrEqual(min(c.width,c.height),512);XCTAssertTrue(c.recommendedAutomatically)
        try c.png.write(to:try assets().appendingPathComponent("google-after.png"))
    }
    func testActualAucklandShieldHasCenteredVisibleBounds() throws {
        let root=try assets();let data=try Data(contentsOf:root.appendingPathComponent("0cffddf08f37.png"))
        let rep=try XCTUnwrap(NSBitmapImageRep(data:data));var xs:[Int]=[],ys:[Int]=[]
        for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide {
            let c=try XCTUnwrap(rep.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB))
            if c.blueComponent<0.7 && c.redComponent<0.4 && c.alphaComponent>0.5 { xs.append(x);ys.append(y) }
        } }
        let left=try XCTUnwrap(xs.min()),right=rep.pixelsWide-1-(try XCTUnwrap(xs.max())),top=try XCTUnwrap(ys.min()),bottom=rep.pixelsHigh-1-(try XCTUnwrap(ys.max()))
        XCTAssertLessThanOrEqual(abs(left-right),3);XCTAssertLessThanOrEqual(abs(top-bottom),3)
        print("AUCKLAND BOUNDS LEFT=\(left) RIGHT=\(right) TOP=\(top) BOTTOM=\(bottom) PIXELS=\(rep.pixelsWide)")
    }
}
