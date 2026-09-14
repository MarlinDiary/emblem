import XCTest
import AppKit
import PortraitCore
@testable import Emblem
final class PublicArtworkTests:XCTestCase {
 struct Asset:Decodable {
  let name:String,file:String,url:String,artwork:String,sha256:String
  func data()throws->Data {try Data(contentsOf:Bundle.module.resourceURL!.appendingPathComponent("Fixtures/PublicArtwork/"+file))}
  func candidate()throws->AvatarCandidate {
   try ImagePipeline.decode(.init(data:data(),url:URL(string:url)!),source:.officialBrand,artwork:artwork == "logo" ? .logo:.appIcon)
  }
 }
 static func assets()throws->[Asset] {
  try JSONDecoder().decode([Asset].self,from:Data(contentsOf:Bundle.module.resourceURL!.appendingPathComponent("Fixtures/PublicArtwork/manifest.json")))
 }
 func testImmutableFirstPartyCorpusAndSafeGeometry()throws {
  let assets=try Self.assets();XCTAssertGreaterThanOrEqual(assets.count,5)
  for asset in assets {
   XCTAssertEqual(digest(try asset.data()),asset.sha256,asset.name)
   let c=try asset.candidate();XCTAssertTrue(c.visuallyUsable,asset.name)
   let b=try XCTUnwrap(NSBitmapImageRep(data:c.png));XCTAssertEqual(b.pixelsWide,b.pixelsHigh)
   XCTAssertGreaterThanOrEqual(b.pixelsWide,128)
   if asset.artwork == "logo" {
    XCTAssertEqual(c.framing,.brandSafe)
    let bg=try XCTUnwrap(b.colorAt(x:0,y:0)?.usingColorSpace(.deviceRGB))
    var subject=0,outside=0
    for y in 0..<b.pixelsHigh {for x in 0..<b.pixelsWide {
     guard let p=b.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB) else{continue}
     let delta=abs(p.redComponent-bg.redComponent)+abs(p.greenComponent-bg.greenComponent)+abs(p.blueComponent-bg.blueComponent)
     if delta>0.35 {
      subject += 1
      let dx=Double(x)+0.5-Double(b.pixelsWide)/2,dy=Double(y)+0.5-Double(b.pixelsHigh)/2
      if dx*dx+dy*dy>pow(Double(b.pixelsWide)/2,2) {outside += 1}
     }
    }}
    XCTAssertGreaterThan(subject,50,asset.name)
    XCTAssertLessThan(Double(outside)/Double(max(1,subject)),0.005,asset.name+" must fit Mail's circular mask")
   }
  }
 }
}
