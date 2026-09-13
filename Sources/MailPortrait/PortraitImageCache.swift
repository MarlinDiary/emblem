import AppKit
import Foundation
import ImageIO
import PortraitCore

/// SwiftUI may evaluate a row body repeatedly while selection changes. Keep the
/// already-decoded image object instead of reconstructing it from PNG data on
/// each evaluation. The cache is UI-owned and therefore main-actor confined.
@MainActor
final class PortraitImageCache {
    static let shared = PortraitImageCache()

    private let images = NSCache<NSString, NSImage>()

    private init() {
        images.countLimit = 512
        images.totalCostLimit = 64 * 1_024 * 1_024
    }

    func image(for data: Data, pixelSize: Int? = nil) -> NSImage? {
        let key = (digest(data) + "/" + String(pixelSize ?? 0)) as NSString
        if let cached = images.object(forKey: key) { return cached }
        let image: NSImage
        if let pixelSize, let source=CGImageSourceCreateWithData(data as CFData,nil),
           let thumbnail=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:max(1,pixelSize),kCGImageSourceShouldCacheImmediately:true] as CFDictionary) {
            // Downsample once to the actual backing pixels. Letting the GPU
            // shrink a 1024px glyph at every 38pt row introduces edge shimmer.
            image=NSImage(size:NSSize(width:thumbnail.width,height:thumbnail.height))
            image.addRepresentation(NSBitmapImageRep(cgImage:thumbnail))
        } else if let decoded=NSImage(data:data) { image=decoded }
        else { return nil }
        images.setObject(image, forKey: key, cost: data.count)
        return image
    }
}
