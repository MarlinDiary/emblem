import XCTest
import AppKit
@testable import PortraitCore

final class LogoCanvasTests: XCTestCase {
    private func logo(width:Int,height:Int) -> Data {
        let c=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(red:0.08,green:0.14,blue:0.22,alpha:1));c.fill(CGRect(x:0,y:0,width:width,height:height))
        c.setFillColor(CGColor(gray:1,alpha:1));c.fillEllipse(in:CGRect(x:width/3,y:height/3,width:width/3,height:height/3))
        return NSBitmapImageRep(cgImage:c.makeImage()!).representation(using:.png,properties:[:])!
    }
    func testSquareLogoDoesNotGainWhiteCorners() throws {
        let candidate=try ImagePipeline.decode(.init(data:logo(width:256,height:256),url:URL(string:"https://company.org/logo.png")!),source:.manifest)
        let image=NSBitmapImageRep(data:candidate.png)!,color=image.colorAt(x:1,y:1)!.usingColorSpace(.deviceRGB)!
        let bodyColor=image.colorAt(x:32,y:128)!.usingColorSpace(.deviceRGB)!
        XCTAssertEqual(color.redComponent,bodyColor.redComponent,accuracy:0.03,"Keep the source background instead of adding a white frame")
        XCTAssertEqual(color.blueComponent,bodyColor.blueComponent,accuracy:0.03)
        XCTAssertGreaterThan(image.colorAt(x:128,y:128)!.usingColorSpace(.deviceRGB)!.redComponent,0.9,"Keep the logo center intact")
    }
    func testWideLogoUsesItsBackgroundForLetterboxing() throws {
        let candidate=try ImagePipeline.decode(.init(data:logo(width:640,height:160),url:URL(string:"https://company.org/logo.png")!),source:.touchIcon)
        let image=NSBitmapImageRep(data:candidate.png)!,color=image.colorAt(x:1,y:1)!.usingColorSpace(.deviceRGB)!
        let bodyColor=image.colorAt(x:40,y:256)!.usingColorSpace(.deviceRGB)!
        XCTAssertEqual(color.redComponent,bodyColor.redComponent,accuracy:0.03,"Wide logos should extend their own background")
        XCTAssertEqual(color.blueComponent,bodyColor.blueComponent,accuracy:0.03)
        XCTAssertGreaterThan(image.colorAt(x:256,y:256)!.usingColorSpace(.deviceRGB)!.redComponent,0.9)
    }
}
