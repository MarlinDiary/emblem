import Foundation
import ImageIO
import CoreGraphics

private final class PhotoFingerprintCache:@unchecked Sendable {
    static let shared=PhotoFingerprintCache()
    let values=NSCache<NSString,NSString>()
    init(){values.countLimit=2048}
}
/// Exact decoded pixels, dimensions and orientation; no perceptual tolerance.
/// PNG/JPEG container metadata is not an avatar change.
public func photoPixelHash(_ data:Data?)->String? {
    guard let data else{return "none"}
    let key=digest(data) as NSString
    if let cached=PhotoFingerprintCache.shared.values.object(forKey:key){return cached as String}
    guard let source=CGImageSourceCreateWithData(data as CFData,nil),let image=CGImageSourceCreateImageAtIndex(source,0,nil),image.width*image.height<=16_777_216 else{return nil}
    let width=image.width,height=image.height
    var bytes=[UInt8](repeating:0,count:width*height*4)
    let drew=bytes.withUnsafeMutableBytes {raw->Bool in
        guard let context=CGContext(data:raw.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue) else{return false}
        context.draw(image,in:CGRect(x:0,y:0,width:width,height:height));return true
    }
    guard drew else{return nil}
    let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any]
    let orientation=(properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    var value=Data("\(width)x\(height):\(orientation):".utf8);value.append(contentsOf:bytes)
    let hash=digest(value);PhotoFingerprintCache.shared.values.setObject(hash as NSString,forKey:key);return hash
}
public func photoMatches(_ data:Data?,encodedHash:String,pixelHash:String?)->Bool {
    if digest(data)==encodedHash{return true}
    guard let pixelHash,let actual=photoPixelHash(data) else{return false}
    return pixelHash==actual
}

extension ChangeEngine {
    /// Add evidence only when the original PNG's byte hash is already recorded.
    /// This never mutates Contacts or changes an existing hash/history token.
    public func enrichPhotoFingerprints(_ known:[String:String]) throws {
        try journal.lock();defer{journal.unlock()};var rows=try journal.read();var changed=false
        for i in rows.indices where rows[i].afterPixelHash == nil {
            if let value=known[rows[i].afterHash] {rows[i].afterPixelHash=value;changed=true}
            else if rows[i].source=="managed-alias",digest(rows[i].beforeImage)==rows[i].afterHash,let value=photoPixelHash(rows[i].beforeImage){rows[i].afterPixelHash=value;changed=true}
        }
        if changed{try journal.write(rows)}
    }
    /// Recover only a proven no-op case-only alias intent. Unknown writes stay prepared.
    public func reconcileRedundantAliasIntents() throws {
        try journal.lock();defer{journal.unlock()};var rows=try journal.read();var changed=false
        for i in rows.indices {
            let r=rows[i]
            guard r.state == .prepared,r.source=="managed-alias",let id=r.contactID,let before=r.beforeEmails,
                  before.contains(where:{$0.caseInsensitiveCompare(r.email) == .orderedSame}),
                  r.afterEmailsHash==digestEmails(Array(Set(before+[r.email])).sorted()),
                  digest(r.beforeImage)==r.afterHash,let current=try store.get(id:id),
                  digestEmails(current.emails)==digestEmails(before),
                  photoMatches(current.image,encodedHash:r.afterHash,pixelHash:photoPixelHash(r.beforeImage)) else{continue}
            rows[i].state = .undone;rows[i].detail="Verified and removed a redundant alias operation: the address differed only by letter case, so the existing addresses and photo were preserved.";changed=true
        }
        if changed{try journal.write(rows)}
    }
}
