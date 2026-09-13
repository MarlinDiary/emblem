import Foundation
import CoreGraphics
import ImageIO

/// Measurements of the delivered pixels, not the nominal file dimensions or
/// prestige of its source. Persisted once so scrolling never decodes images.
public struct AvatarVisualQuality: Codable, Sendable {
    public let contrast: Double
    public let edgeSharpness: Double
    public let frameFraction: Double
    public let revision: Int
    public init(contrast: Double, edgeSharpness: Double, frameFraction: Double = 0, revision: Int = 1) {
        self.contrast=contrast;self.edgeSharpness=edgeSharpness;self.frameFraction=frameFraction;self.revision=revision
    }
    public var isBlank: Bool { contrast < 0.08 }
    public var isSoft: Bool { contrast >= 0.08 && edgeSharpness < 0.32 }
}

extension ImagePipeline {
    public static func visualQuality(of data: Data) -> AvatarVisualQuality? {
        guard let input=CGImageSourceCreateWithData(data as CFData,nil),
              let image=CGImageSourceCreateThumbnailAtIndex(input,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:128,kCGImageSourceShouldCacheImmediately:true] as CFDictionary) else { return nil }
        let w=image.width,h=image.height
        guard w>2,h>2 else { return nil }
        var bytes=[UInt8](repeating:0,count:w*h*4)
        return bytes.withUnsafeMutableBytes { raw in
            guard let ctx=CGContext(data:raw.baseAddress,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
            ctx.setFillColor(CGColor(gray:1,alpha:1));ctx.fill(CGRect(x:0,y:0,width:w,height:h));ctx.draw(image,in:CGRect(x:0,y:0,width:w,height:h))
            let p=raw.bindMemory(to:UInt8.self)
            var lo=[255,255,255],hi=[0,0,0],gradient=0.0,laplacian=0.0,frame=0
            for y in 0..<h { for x in 0..<w {
                let n=(y*w+x)*4
                for c in 0..<3 { lo[c]=min(lo[c],Int(p[n+c]));hi[c]=max(hi[c],Int(p[n+c])) }
                let rgb=(0..<3).map { Int(p[n+$0]) }
                if (x<w/8 || x>=w-w/8 || y<h/8 || y>=h-h/8),
                   rgb.max()!-rgb.min()!<15, rgb.min()!>180,rgb.max()!<247 { frame+=1 }
                if x>0,x<w-1,y>0,y<h-1 {
                    for c in 0..<3 {
                        let l=Double(p[n-4+c]),r=Double(p[n+4+c]),t=Double(p[n-w*4+c]),b=Double(p[n+w*4+c]),v=Double(p[n+c])
                        gradient+=abs(r-l)+abs(b-t);laplacian+=abs(l+r+t+b-4*v)
                    }
                }
            } }
            return .init(contrast:Double(zip(lo,hi).map { $1-$0 }.max() ?? 0)/255,
                         edgeSharpness:laplacian/max(0.001,gradient),frameFraction:Double(frame)/Double(w*h))
        }
    }
}
