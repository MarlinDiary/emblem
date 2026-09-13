import AppKit
import CoreText
import ImageIO
import PortraitCore

/// Deterministic local typography, explicitly labelled as generated artwork.
/// No lookup, email hash transmission, or synthetic portrait/brand attribution.
@MainActor enum NameAvatar {
    private static let cache = NSCache<NSString, CachedAvatar>()
    private final class CachedAvatar: NSObject { let value: AvatarCandidate; init(_ value: AvatarCandidate) { self.value = value } }
    static func normalized(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }
    static func initials(_ name: String) -> String {
        let clean = name.split(separator: "@").first.map(String.init) ?? name
        let words = clean.split { !$0.isLetter && !$0.isNumber }
        guard let first = words.first else { return "?" }
        if words.count > 1 { return words.prefix(2).compactMap(\.first).map(String.init).joined().uppercased() }
        let cjk = first.unicodeScalars.contains { (0x3400...0x9FFF).contains(Int($0.value)) }
        return String(first.prefix(cjk ? 2 : 1)).uppercased()
    }
    static func candidate(name: String, variant: Int = 0) throws -> AvatarCandidate {
        let key = digest(Data(normalized(name).utf8))
        let style = abs(variant % 3), cacheKey = "\(key)/\(style)" as NSString
        if let saved = cache.object(forKey: cacheKey) { return saved.value }
        let palettes: [(CGFloat, CGFloat, CGFloat)] = [(0.22,0.30,0.60),(0.12,0.40,0.44),(0.46,0.24,0.45),(0.40,0.31,0.55),(0.45,0.32,0.22),(0.24,0.36,0.29)]
        let seed = Int(key.prefix(2),radix:16) ?? 0
        let (r,g,b) = style == 2 ? (CGFloat(0.28),CGFloat(0.31),CGFloat(0.37)) : palettes[(seed + style * 3) % palettes.count]
        let size = 2048
        guard let context = CGContext(data:nil,width:size,height:size,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw PortraitError.message("Monogram rendering failed.") }
        // Quantised scanlines avoid CoreGraphics gradient dithering, which made
        // a simple 1024px monogram almost 1 MB and inflated large sender caches.
        context.setShouldAntialias(false)
        for y in 0..<size {
            let t = CGFloat(y) / CGFloat(size - 1)
            func channel(_ value: CGFloat) -> CGFloat { (max(0,min(1,value - 0.04 + t * 0.10)) * 255).rounded() / 255 }
            context.setFillColor(CGColor(red:channel(r),green:channel(g),blue:channel(b),alpha:1))
            context.fill(CGRect(x:0,y:y,width:size,height:1))
        }
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setAllowsFontSmoothing(true)
        context.setShouldSmoothFonts(true)
        context.setShouldSubpixelPositionFonts(true)
        context.setShouldSubpixelQuantizeFonts(false)
        let text = initials(name)
        let font = NSFont.systemFont(ofSize: text.count > 1 ? 760 : 980,weight:.semibold)
        let rounded = NSFont(descriptor:font.fontDescriptor.withDesign(.rounded) ?? font.fontDescriptor,size:font.pointSize) ?? font
        let line = CTLineCreateWithAttributedString(NSAttributedString(string:text,attributes:[.font:rounded,.foregroundColor:NSColor.white]))
        let bounds = CTLineGetImageBounds(line,context)
        context.textPosition = CGPoint(x:(CGFloat(size)-bounds.width)/2-bounds.minX,y:(CGFloat(size)-bounds.height)/2-bounds.minY)
        CTLineDraw(line,context)
        guard let image=context.makeImage(),
              let output=CGContext(data:nil,width:1024,height:1024,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw PortraitError.message("Monogram export failed.") }
        output.interpolationQuality = .high
        output.draw(image,in:CGRect(x:0,y:0,width:1024,height:1024))
        guard let final=output.makeImage(),let png=NSBitmapImageRep(cgImage:final).representation(using:.png,properties:[:]) else { throw PortraitError.message("Monogram export failed.") }
        let result = AvatarCandidate(source:.monogram,origin:"local://monogram/v2/\(cacheKey)",width:1024,height:1024,png:png,framing:.personFill)
        cache.countLimit = 384; cache.totalCostLimit = 40*1024*1024
        cache.setObject(CachedAvatar(result),forKey:cacheKey,cost:png.count)
        return result
    }
    static func choices(name: String, count: Int = 3) -> [AvatarCandidate] {
        (0..<count).compactMap { try? candidate(name:name,variant:$0) }
    }
}

extension AppModel {
    func prepareNameFallbacks() async {
        guard !preparingNameFallbacks else { return }
        preparingNameFallbacks = true
        defer { preparingNameFallbacks = false }
        var changed = false
        let ids = rows.filter { !$0.completed && !$0.ignored && $0.current?.image == nil && $0.chosen == nil && $0.lastLookup != nil }.map(\.id)
        for id in ids {
            guard !Task.isCancelled else { break }
            if let i=rows.firstIndex(where:{$0.id==id}), rows[i].chosen == nil, !rows[i].completed, !rows[i].ignored,
               rows[i].current?.image == nil, rows[i].selectionIsManual != true,
               let candidate=try? NameAvatar.candidate(name:rows[i].name) {
                var replacement=rows
                replacement[i].candidates.append(candidate);replacement[i].selectedCandidate=candidate.id
                replacement[i].selectionIsManual=false
                replaceRowsPreservingGrouping(replacement,changedIDs:[id]);changed=true
            }
            await Task.yield()
        }
        if changed { save() }
    }
    /// Storage in Contacts does not turn an applied website image into a new source.
    /// Prefer recorded sync provenance, then exact bytes/pixels; never guess a source.
    func currentAvatarSource(for row:SenderRow)->AvatarCandidate? {
        guard let photo=row.current?.image else {return nil}
        if let exact=row.candidates.first(where:{$0.png==photo}) {return exact}
        let hash=digest(photo)
        if let link=mailSync.links.first(where:{$0.contactID==row.current?.id && !$0.externalPhoto && $0.imageHash==hash}),
           let original=row.candidates.first(where:{digest($0.png)==link.desiredHash}) {return original}
        guard let pixels=photoPixelHash(photo) else {return nil}
        return row.candidates.first(where:{photoPixelHash($0.png)==pixels})
    }
    func avatarChoices(for row: SenderRow, allSizes: Bool) -> [AvatarCandidate] {
        let real=row.candidates.filter { $0.source != .monogram && $0.visuallyUsable }
        var choices=allSizes ? real : CandidateSelection.recommended(real)
        if let chosen=row.chosen, chosen.source != .monogram, !choices.contains(where:{$0.id==chosen.id}) { choices.append(chosen) }
        let currentSource=currentAvatarSource(for:row)
        if let currentSource,!choices.contains(where:{$0.id==currentSource.id}) {choices.insert(currentSource,at:0)}
        let letters=NameAvatar.choices(name:row.displayName,count:real.isEmpty ? 3 : 1)
        if let photo=row.current?.image,currentSource == nil,!choices.contains(where:{$0.png==photo}),
           let source=CGImageSourceCreateWithData(photo as CFData,nil),
           let metadata=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
           let width=metadata[kCGImagePropertyPixelWidth] as? Int,let height=metadata[kCGImagePropertyPixelHeight] as? Int {
            let h=digest(photo);let uuid=String(h.prefix(8))+"-"+String(h.dropFirst(8).prefix(4))+"-"+String(h.dropFirst(12).prefix(4))+"-"+String(h.dropFirst(16).prefix(4))+"-"+String(h.dropFirst(20).prefix(12))
            choices.insert(AvatarCandidate(source:.manual,origin:"contacts://"+(row.current?.id ?? row.id),width:width,height:height,png:photo,framing:.personFill,id:UUID(uuidString:uuid)!),at:0)
        }
        var hashes=Set(choices.map { digest($0.png) })
        // Keep positions stable when clicking another colour, including after
        // restart when the persisted selected candidate has a different UUID.
        for letter in letters where hashes.insert(digest(letter.png)).inserted {
            if let chosen=row.chosen, chosen.source == .monogram,
               digest(chosen.png) == digest(letter.png) || (chosen.origin.hasPrefix("local://monogram/v1/") && chosen.origin.split(separator:"/").last == letter.origin.split(separator:"/").last) {
                choices.append(chosen);hashes.insert(digest(chosen.png))
            }
            else { choices.append(letter) }
        }
        if let chosen=row.chosen, chosen.source == .monogram, hashes.insert(digest(chosen.png)).inserted { choices.append(chosen) }
        return choices
    }
}
