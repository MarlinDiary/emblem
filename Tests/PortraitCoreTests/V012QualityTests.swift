import XCTest
import AppKit
@testable import PortraitCore

final class V012QualityTests: XCTestCase {
    func testDeliveredPixelsGateBlankAndBlurredImages() throws {
        let blank=AvatarVisualQuality(contrast:0.003,edgeSharpness:1.8)
        let soft=AvatarVisualQuality(contrast:0.98,edgeSharpness:0.21)
        var c=AvatarCandidate(source:.touchIcon,origin:"blank",width:512,height:512,png:Data())
        c.visualQuality=blank;XCTAssertFalse(c.recommendedAutomatically)
        c.visualQuality=soft;XCTAssertFalse(c.visuallyUsable)
        c.visualQuality = .init(contrast:0.9,edgeSharpness:0.62)
        XCTAssertTrue(c.recommendedAutomatically)
    }
    func testQualityCanOutrankTouchIconWithoutDomainExceptions() {
        let touch=AvatarCandidate(source:.touchIcon,origin:"touch",width:180,height:180,png:Data())
        let manifest=AvatarCandidate(source:.manifest,origin:"manifest",width:512,height:512,png:Data())
        XCTAssertGreaterThan(manifest.score,touch.score)
        XCTAssertEqual(CandidateSelection.recommended([touch,manifest]).first?.id,manifest.id)
        var framed=touch;framed.visualQuality = .init(contrast:0.9,edgeSharpness:0.65,frameFraction:0.025)
        let logo=AvatarCandidate(source:.siteLogo,origin:"logo",width:168,height:143,png:Data())
        XCTAssertGreaterThan(logo.score,framed.score)
    }
    func testAReadableWordmarkBeatsAnEmptySquare() {
        var blank=AvatarCandidate(source:.touchIcon,origin:"blank",width:512,height:512,png:Data())
        blank.visualQuality = .init(contrast:0,edgeSharpness:0)
        var logo=AvatarCandidate(source:.siteLogo,origin:"logo",width:532,height:128,png:Data(),subjectWidth:532,subjectHeight:108)
        logo.visualQuality = .init(contrast:1,edgeSharpness:0.68)
        XCTAssertTrue(logo.recommendedAutomatically)
        XCTAssertEqual(CandidateSelection.recommended([blank,logo]).first?.id,logo.id)
    }
    func testRealCorpusQuality() throws {
        guard let folder=ProcessInfo.processInfo.environment["MAILPORTRAIT_V012_ASSETS"] else { throw XCTSkip("real asset fixture opt-in") }
        let root=URL(fileURLWithPath:folder)
        let rows=try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("corpus.json"))) as! [[String:Any]]
        for row in rows {
            for entry in row["candidates"] as! [[String:Any]] {
                let source=CandidateSource(rawValue:entry["source"] as! String)!
                let data=try Data(contentsOf:root.appendingPathComponent(entry["file"] as! String))
                let q=try XCTUnwrap(ImagePipeline.visualQuality(of:data))
                let email=row["email"] as! String
                if email.contains("ubisoft") { XCTAssertTrue(q.isSoft) }
                if email.contains("ifttt"),source == .favicon { XCTAssertTrue(q.isBlank) }
                if email.contains("vervecopilot"),source == .touchIcon || source == .manifest { XCTAssertTrue(q.isBlank) }
            }
        }
        print("REAL_PIXEL_GATE IFTTT_EMPTY=REJECT VERVE_EMPTY=REJECT UBISOFT_BLUR=REJECT")
    }
}
