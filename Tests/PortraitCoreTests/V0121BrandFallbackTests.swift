import XCTest
@testable import PortraitCore

final class V0121BrandFallbackTests: XCTestCase {
    private func wide(_ source: CandidateSource = .bimi) -> AvatarCandidate {
        var image=AvatarCandidate(source:source,origin:"https://amazon.com.au/brand.svg",width:192,height:192,vector:true,png:Data(),framing:.brandSafe,subjectWidth:820,subjectHeight:205)
        image.visualQuality = .init(contrast:0.9215686274509803,edgeSharpness:0.6316771486032481)
        return image
    }
    private func letter() -> AvatarCandidate {
        AvatarCandidate(source:.monogram,origin:"local://monogram/v2/0",width:1024,height:1024,png:Data())
    }
    func testClearWideBIMIIsAnAutomaticFallbackBeforeInitials() {
        let bimi=wide(),monogram=letter()
        XCTAssertFalse(bimi.circularSuitable)
        XCTAssertTrue(bimi.recommendedAutomatically)
        XCTAssertEqual(CandidateSelection.recommended([monogram,bimi]).first(where:\.recommendedAutomatically)?.id,bimi.id)
    }
    func testCompactBrandMarkStillBeatsWideBIMIEvenFromLowerPrioritySource() {
        let bimi=wide()
        for source in [CandidateSource.touchIcon,.manifest,.officialBrand,.domainIcon] {
            let compact=AvatarCandidate(source:source,origin:"https://amazon.com.au/icon.png",width:128,height:128,png:Data())
            XCTAssertGreaterThan(compact.score,bimi.score,"\(source)")
            XCTAssertEqual(CandidateSelection.recommended([bimi,compact]).first(where:\.recommendedAutomatically)?.id,compact.id)
        }
    }
    func testNoBrandDomainExceptionAndBadPixelsDoNotBecomeFallbacks() {
        for source in [CandidateSource.bimi,.siteLogo,.officialBrand,.touchIcon,.manifest,.favicon] {
            var mark=wide(source)
            XCTAssertTrue(mark.recommendedAutomatically,"\(source)")
            mark.visualQuality = .init(contrast:0.001,edgeSharpness:0.6)
            XCTAssertFalse(mark.recommendedAutomatically)
            mark.visualQuality=nil
            XCTAssertFalse(mark.recommendedAutomatically)
        }
        var blurred=AvatarCandidate(source:.bimi,origin:"https://amazon.com.au/logo.png",width:192,height:192,png:Data(),framing:.brandSafe,subjectWidth:820,subjectHeight:205)
        blurred.visualQuality = .init(contrast:0.9,edgeSharpness:0.2)
        XCTAssertFalse(blurred.recommendedAutomatically)
        var card=AvatarCandidate(source:.siteLogo,origin:"https://amazon.com.au/campaign.png",width:1200,height:628,png:Data(),framing:.brandSafe)
        card.visualQuality = .init(contrast:0.9,edgeSharpness:0.6)
        XCTAssertFalse(card.recommendedAutomatically)
        var thin=AvatarCandidate(source:.bimi,origin:"https://amazon.com.au/logo.svg",width:192,height:192,vector:true,png:Data(),framing:.brandSafe,subjectWidth:1000,subjectHeight:30)
        thin.visualQuality = .init(contrast:0.9,edgeSharpness:0.6)
        XCTAssertFalse(thin.recommendedAutomatically)
    }
}
