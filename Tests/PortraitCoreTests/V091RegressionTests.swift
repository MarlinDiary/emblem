import XCTest
import AppKit
@testable import PortraitCore

private func v091PNG(width: Int = 256, height: Int = 256, draw: (CGContext) -> Void) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(context)
    return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
}

private func v091Pixel(_ data: Data, x: Int, y: Int) throws -> (Int, Int, Int, Int) {
    let image = try XCTUnwrap(NSBitmapImageRep(data: data))
    let color = try XCTUnwrap(image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
    return (Int((color.redComponent * 255).rounded()), Int((color.greenComponent * 255).rounded()),
            Int((color.blueComponent * 255).rounded()), Int((color.alphaComponent * 255).rounded()))
}

final class V091RegressionTests: XCTestCase {
    func testLinkedInUsesFirstPartyBrandPageAsset() throws {
        let asset = try XCTUnwrap(OfficialBrandAssets.asset(for: URL(string: "https://linkedin.com")!))
        XCTAssertEqual(asset.evidenceURL.absoluteString, "https://brand.linkedin.com/in-logo")
        XCTAssertEqual(asset.assetURL.host, "delivery-p143253-e1476319.adobeaemcloud.com")
    }

    func testTeslaUsesHighResolutionFirstPartySupportArtwork() throws {
        let asset = try XCTUnwrap(OfficialBrandAssets.asset(for: URL(string: "https://tesla.com")!))
        XCTAssertEqual(asset.assetURL.host, "digitalassets.tesla.com")
        XCTAssertEqual(asset.evidenceURL.host, "www.tesla.com")
    }

    func testRasterBelow128PixelsIsRejectedAtDecodeBoundary() {
        let tiny = v091PNG(width: 32, height: 32) { context in
            context.setFillColor(CGColor(red: 0, green: 0.3, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        XCTAssertThrowsError(try ImagePipeline.decode(.init(data: tiny, url: URL(string: "https://milkrun.com/apple-touch-icon.png")!), source: .touchIcon))
        XCTAssertTrue(CandidateSelection.recommended([
            .init(source: .touchIcon, origin: "tiny", width: 32, height: 32, png: tiny)
        ]).isEmpty)
    }

    func testColoredRoundedCanvasFillsTransparentCornersWithItsBackdrop() throws {
        let purple = CGColor(red: 0.58, green: 0.36, blue: 0.88, alpha: 1)
        let data = v091PNG { context in
            context.addPath(CGPath(roundedRect: CGRect(x: 2, y: 2, width: 252, height: 252), cornerWidth: 48, cornerHeight: 48, transform: nil))
            context.setFillColor(purple); context.fillPath()
            context.setFillColor(CGColor(red: 0.08, green: 0.03, blue: 0.2, alpha: 1))
            context.fillEllipse(in: CGRect(x: 83, y: 60, width: 90, height: 136))
        }
        let candidate = try ImagePipeline.decode(.init(data: data, url: URL(string: "https://fly.io/icon.png")!), source: .manifest)
        XCTAssertEqual(candidate.effectiveFraming, .brandCanvas)
        let corner = try v091Pixel(candidate.png, x: 0, y: 0)
        XCTAssertGreaterThan(corner.2, corner.0)
        XCTAssertGreaterThan(corner.3, 250)
    }

    func testColoredCanvasPreservesEnclosedTransparentNegativeSpace() throws {
        let blue = CGColor(red: 10 / 255, green: 102 / 255, blue: 194 / 255, alpha: 1)
        let data = v091PNG { context in
            context.addPath(CGPath(roundedRect: CGRect(x: 2, y: 2, width: 252, height: 252), cornerWidth: 28, cornerHeight: 28, transform: nil))
            context.setFillColor(blue); context.fillPath()
            context.setBlendMode(.clear)
            context.fill(CGRect(x: 88, y: 75, width: 80, height: 106))
        }
        let candidate = try ImagePipeline.decode(.init(data: data, url: URL(string: "https://linkedin.com/in.png")!), source: .officialBrand)
        XCTAssertEqual(candidate.effectiveFraming, .brandCanvas)
        let corner = try v091Pixel(candidate.png, x: 0, y: 0)
        let hole = try v091Pixel(candidate.png, x: 128, y: 128)
        XCTAssertGreaterThan(corner.2, corner.0)
        XCTAssertGreaterThan(hole.0, 245)
        XCTAssertGreaterThan(hole.1, 245)
        XCTAssertGreaterThan(hole.2, 245)
    }

    func testTransparentOrWhiteBackedLogoUsesCircleSafeFraming() throws {
        let data = v091PNG { context in
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
            context.setFillColor(CGColor(red: 0.82, green: 0, blue: 0.03, alpha: 1))
            context.fill(CGRect(x: 12, y: 0, width: 232, height: 55))
            context.fill(CGRect(x: 108, y: 0, width: 40, height: 250))
        }
        let candidate = try ImagePipeline.decode(.init(data: data, url: URL(string: "https://tesla.com/icon.png")!), source: .favicon)
        XCTAssertEqual(candidate.effectiveFraming, .brandSafe)
        XCTAssertLessThan(candidate.subjectWidth ?? 256, 256)
    }

    func testPortraitSVGPreservesIntrinsicAspectAndUsesCircleSafeFraming() throws {
        let svg = ##"<svg xmlns="http://www.w3.org/2000/svg" width="127" height="145" viewBox="0 0 127 145"><path fill="#0C0C48" d="M0 0h127v70c0 36-24 62-63.5 75C24 132 0 106 0 70z"/></svg>"##
        let image = try ImagePipeline.decode(
            .init(data: Data(svg.utf8), url: URL(string: "https://www.auckland.ac.nz/favicon.svg")!, contentType: "image/svg+xml"),
            source: .favicon
        )
        XCTAssertEqual(image.width, 127)
        XCTAssertEqual(image.height, 145)
        XCTAssertEqual(image.effectiveFraming, .brandSafe)
        XCTAssertLessThan(image.subjectWidth ?? 512, image.subjectHeight ?? 0)
    }

    func testLegacySquareSVGCacheRecoversDeclaredPortraitAspectOffline() throws {
        let oldSquare = v091PNG { context in
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
            context.setFillColor(CGColor(red: 12 / 255, green: 12 / 255, blue: 72 / 255, alpha: 1))
            context.addPath(CGPath(roundedRect: CGRect(x: 16, y: 0, width: 224, height: 256), cornerWidth: 0, cornerHeight: 0, transform: nil)); context.fillPath()
        }
        let legacy = AvatarCandidate(source: .favicon, origin: "https://www.auckland.ac.nz/favicon.svg", width: 127, height: 145, vector: true, png: oldSquare, framing: .brandCanvas, layoutRevision: 1)
        let migrated = try ImagePipeline.reframeStoredBrand(legacy)
        XCTAssertEqual(migrated.effectiveFraming, .brandSafe)
        XCTAssertLessThan(migrated.subjectWidth ?? 512, migrated.subjectHeight ?? 0)
        XCTAssertEqual(migrated.id, legacy.id)
    }
}
