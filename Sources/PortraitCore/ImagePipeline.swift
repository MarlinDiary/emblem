import AppKit
import ImageIO
import Foundation

private final class SVGValidator: NSObject, XMLParserDelegate {
    var allowed = true
    var rootSeen = false
    let elements: Set<String> = ["svg", "g", "path", "rect", "circle", "ellipse", "polygon", "polyline", "line", "defs", "lineargradient", "radialgradient", "stop", "clippath", "mask", "use", "symbol", "title", "desc", "style"]
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        if !rootSeen { rootSeen = true; if elementName.lowercased() != "svg" { allowed = false } }
        if !elements.contains(elementName.lowercased()) { allowed = false }
        for (key, value) in attributes {
            let key = key.lowercased(), value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if key.hasPrefix("on") || ((key == "href" || key == "xlink:href") && !value.hasPrefix("#")) { allowed = false }
        }
        if !allowed { parser.abortParsing() }
    }
}

public enum ImagePipeline {
    public static let currentLayoutRevision = 7

    private struct BrandAnalysis {
        let crop: CGRect
        let subjectWidth: Int
        let subjectHeight: Int
        let isPrecomposedCanvas: Bool
        let backdrop: CGColor?
    }
    public static func reframeStoredBrand(_ data:Data,maskable:Bool) throws -> Data {
        try decode(.init(data:data,url:URL(string:"https://migration.mailportrait.invalid/icon.png")!),source:.favicon,maskable:maskable).png
    }
    public static func reframeStoredBrand(_ candidate: AvatarCandidate) throws -> AvatarCandidate {
        // Already framed artwork is a payload, not an original image. Reapplying
        // a safe inset repeatedly would shrink the logo on every migration.
        if candidate.artwork != nil && (candidate.layoutRevision ?? 0) >= 5 { return candidate }
        let url = URL(string: candidate.origin) ?? URL(string:"https://migration.mailportrait.invalid/icon.png")!
        var sourceData = candidate.png
        // Layout revision 1 rasterized every SVG into a square before analysis.
        // Reconstruct the declared intrinsic ratio from the saved metadata so an
        // offline migration can repair tall crests without waiting for a refetch.
        if candidate.vector, candidate.width > 0, candidate.height > 0, candidate.width != candidate.height,
           let input = CGImageSourceCreateWithData(candidate.png as CFData, nil),
           let image = CGImageSourceCreateImageAtIndex(input, 0, nil) {
            let longest = max(image.width, image.height)
            let ratio = Double(candidate.width) / Double(candidate.height)
            let targetWidth = ratio >= 1 ? longest : max(1, Int((Double(longest) * ratio).rounded()))
            let targetHeight = ratio >= 1 ? max(1, Int((Double(longest) / ratio).rounded())) : longest
            if let context = CGContext(data:nil,width:targetWidth,height:targetHeight,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) {
                context.setFillColor(edgeBackground(image)); context.fill(CGRect(x:0,y:0,width:targetWidth,height:targetHeight))
                context.interpolationQuality = .high
                context.draw(image,in:CGRect(x:0,y:0,width:targetWidth,height:targetHeight))
                if let rebuilt = context.makeImage() { sourceData = try encodePNG(rebuilt) }
            }
        }
        let rendered = try decode(.init(data:sourceData,url:url),source:candidate.source,maskable:candidate.maskable == true)
        var updated = candidate
        updated.png = rendered.png
        updated.framing = rendered.framing
        updated.subjectWidth = rendered.subjectWidth
        updated.subjectHeight = rendered.subjectHeight
        updated.layoutRevision = currentLayoutRevision
        return updated
    }
    public static func validateSVG(_ data: Data) -> Bool {
        guard data.count <= 1_000_000, let text = String(data: data, encoding: .utf8) else { return false }
        let lower = text.lowercased()
        guard !lower.contains("<!doctype"), !lower.contains("<!entity"), !lower.contains("@import"), !lower.contains("\\"), !lower.contains("xml-stylesheet") else { return false }
        let urls = try! NSRegularExpression(pattern: #"url\s*\(\s*['"]?([^\s'"\)]+)"#, options: .caseInsensitive)
        for match in urls.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range(at: 1), in: text), text[range].hasPrefix("#") else { return false }
        }
        let validator = SVGValidator(), parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.delegate = validator
        return parser.parse() && validator.allowed && validator.rootSeen
    }

    public static func decode(_ resource: WebResource, source: CandidateSource, maskable: Bool = false, artwork: BrandArtwork? = nil) throws -> AvatarCandidate {
        let data = resource.data
        guard data.count <= 4_000_000 else { throw PortraitError.message("The image exceeds 4 MB.") }
        let prefix = String(data: data.prefix(8192), encoding: .utf8)?.lowercased() ?? ""
        let vector = resource.contentType == "image/svg+xml" || prefix.contains("<svg")
        let image: CGImage; let width: Int; let height: Int
        if vector {
            guard validateSVG(data), let nsImage = NSImage(data: data), nsImage.size.width > 0, nsImage.size.height > 0, nsImage.size.width <= 8192, nsImage.size.height <= 8192 else { throw PortraitError.message("The SVG is not a supported self-contained vector image; external resources and dynamic content are rejected.") }
            width = max(1, Int(nsImage.size.width.rounded()))
            height = max(1, Int(nsImage.size.height.rounded()))
            let renderScale = 512 / max(nsImage.size.width, nsImage.size.height)
            var rect = NSRect(x: 0, y: 0, width: nsImage.size.width * renderScale, height: nsImage.size.height * renderScale)
            guard let cg = nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { throw PortraitError.message("The SVG could not be rendered.") }
            image = cg
        } else {
            guard let input = CGImageSourceCreateWithData(data as CFData, nil) else { throw PortraitError.message("The resource is not a supported image.") }
            var best = -1, bestArea = 0, bestWidth = 0, bestHeight = 0
            for index in 0..<min(CGImageSourceGetCount(input), 32) {
                guard let props = CGImageSourceCopyPropertiesAtIndex(input, index, nil) as? [CFString: Any], let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0, w <= 8192, h <= 8192, w * h <= 20_000_000 else { continue }
                if w * h > bestArea { best = index; bestArea = w * h; bestWidth = w; bestHeight = h }
            }
            guard best >= 0, let cg = CGImageSourceCreateImageAtIndex(input, best, [kCGImageSourceShouldCache: false] as CFDictionary) else { throw PortraitError.message("The image dimensions are invalid or too large.") }
            image = cg; width = bestWidth; height = bestHeight
        }
        guard vector || min(width, height) >= PortraitPolicy.minimumRasterDimension else {
            throw PortraitError.message("The image’s short edge is below \(PortraitPolicy.minimumRasterDimension) pixels, so the low-resolution candidate was discarded.")
        }
        let publicPersonSources: Set<CandidateSource> = [.gravatar, .libravatar, .profile, .institutionProfile]
        guard !publicPersonSources.contains(source) || !looksLikeFlatPlaceholder(image) else {
            throw PortraitError.message("The public person image is a low-detail placeholder and was skipped.")
        }
        let size = vector ? 512 : min(512, max(width, height))
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw PortraitError.message("Image processing failed.") }
        // Person photos and brand marks need different composition. Mail supplies
        // the final circular mask; this square payload must keep the intended
        // subject or complete logo inside that mask.
        let brand = source.isBrand ? analyzeBrand(image, preserveDeclaredIconCanvas: source == .touchIcon || source == .manifest) : nil
        let framing: AvatarFraming
        if !source.isBrand { framing = .personFill }
        else if artwork == .logo { framing = .brandSafe }
        else if maskable && circleClipFraction(image) < 0.005 { framing = .brandMaskable }
        else if maskable { framing = .brandSafe }
        else if brand?.isPrecomposedCanvas == true { framing = .brandCanvas }
        else { framing = .brandSafe }
        let background = artwork == .logo ? edgeBackground(image) : framing == .brandCanvas ? brand?.backdrop ?? edgeBackground(image) : source.isBrand ? edgeBackground(image) : CGColor(gray: 1, alpha: 1)
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        // Portraits fill the circular canvas and crop excess width/height. Ordinary
        // brand artwork fits wholly inside the circle's inscribed square so letters
        // and corner details survive. A manifest maskable icon already promises a
        // circle-safe central region and may use the full canvas.
        let artworkImage: CGImage
        if artwork == .logo { artworkImage = brand.flatMap { image.cropping(to: $0.crop) } ?? image }
        else if framing == .brandSafe, let crop = brand?.crop, let cropped = image.cropping(to: crop) { artworkImage = cropped }
        else if framing == .brandCanvas, let backdrop = brand?.backdrop {
            artworkImage = removingNeutralIconFrame(replacingConnectedEdgeBackground(image, with: backdrop) ?? image, backdrop: backdrop)
        }
        else { artworkImage = image }
        // Non-maskable app-icon canvases receive a small optical inset. The
        // detected backdrop still fills the circle, while edge-hugging glyphs
        // get the breathing room expected from a native contact avatar.
        let padding: CGFloat
        if framing == .brandSafe { padding = CGFloat(size) * 0.15 }
        else if framing == .brandCanvas && !maskable { padding = CGFloat(size) * 0.04 }
        else { padding = 0 }
        let scale: CGFloat
        if framing == .personFill {
            scale = CGFloat(size) / CGFloat(min(artworkImage.width, artworkImage.height))
        } else {
            scale = (CGFloat(size) - padding * 2) / CGFloat(max(artworkImage.width, artworkImage.height))
        }
        let w = CGFloat(artworkImage.width) * scale, h = CGFloat(artworkImage.height) * scale
        context.interpolationQuality = .high
        context.draw(artworkImage, in: CGRect(x: (CGFloat(size) - w) / 2, y: (CGFloat(size) - h) / 2, width: w, height: h))
        guard let output = context.makeImage() else { throw PortraitError.message("The preview could not be generated.") }
        var candidate=AvatarCandidate(source: source, origin: resource.url.absoluteString, width: width, height: height, vector: vector, png: try encodePNG(output), maskable: maskable, framing: framing, subjectWidth: brand?.subjectWidth, subjectHeight: brand?.subjectHeight, layoutRevision: currentLayoutRevision, artwork: artwork)
        candidate.visualQuality=visualQuality(of:candidate.png)
        // Reject an actual blank render, including unsupported SVG styles and
        // white-on-transparent marks on our white contact canvas.
        if source.isBrand, candidate.visualQuality?.isBlank == true { throw PortraitError.message("The image has no recognizable artwork and was skipped.") }
        if source.isBrand, !vector, candidate.visualQuality?.isSoft == true { throw PortraitError.message("The image is too blurry and was skipped.") }
        return candidate
    }

    /// A manifest's maskable flag is a declaration, not proof. Check visible
    /// foreground against the circle before allowing a full-canvas render.
    /// Background colour is ignored so solid fields still extend naturally.
    private static func circleClipFraction(_ image: CGImage) -> Double {
        let size=160,background=edgeBackground(image)
        var bytes=[UInt8](repeating:0,count:size*size*4)
        return bytes.withUnsafeMutableBytes { raw in
            guard let context=CGContext(data:raw.baseAddress,width:size,height:size,bitsPerComponent:8,bytesPerRow:size*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return 1 }
            context.setFillColor(background);context.fill(CGRect(x:0,y:0,width:size,height:size))
            context.draw(image,in:CGRect(x:0,y:0,width:size,height:size))
            let pixels=raw.bindMemory(to:UInt8.self)
            let bg=(background.components ?? [1,1,1,1]).prefix(3).map { Double($0)*255 }
            guard bg.count==3 else { return 1 }
            var ink=0,clipped=0
            for y in 0..<size { for x in 0..<size {
                let i=(y*size+x)*4
                let distance=(0..<3).reduce(0.0) { $0+pow(Double(pixels[i+$1])-bg[$1],2) }
                if distance>42*42 {
                    ink+=1
                    let dx=(Double(x)+0.5)/Double(size)-0.5,dy=(Double(y)+0.5)/Double(size)-0.5
                    if dx*dx+dy*dy>0.25 { clipped+=1 }
                }
            } }
            return Double(clipped)/Double(max(1,ink))
        }
    }

    /// Estimate the visible mark independently of the file canvas. Large press
    /// images often contain a small logo surrounded by white space; trimming that
    /// space before the circle-safe inset keeps the mark legible. A coloured or
    /// transparent rounded-square app icon is treated as an already-composed
    /// canvas and is not inset a second time.
    private static func analyzeBrand(_ image: CGImage, preserveDeclaredIconCanvas: Bool) -> BrandAnalysis {
        let maxSample = 160
        let squareInput = Double(min(image.width, image.height)) / Double(max(image.width, image.height)) >= 0.9
        let scale = min(Double(maxSample) / Double(image.width), Double(maxSample) / Double(image.height), 1)
        let sampleWidth = max(1, Int((Double(image.width) * scale).rounded()))
        let sampleHeight = max(1, Int((Double(image.height) * scale).rounded()))
        var bytes = [UInt8](repeating: 0, count: sampleWidth * sampleHeight * 4)
        let background = edgeBackground(image).components ?? [1, 1, 1, 1]
        let result: (crop: CGRect?, backdrop: CGColor?) = bytes.withUnsafeMutableBytes { storage in
            guard let context = CGContext(data: storage.baseAddress, width: sampleWidth, height: sampleHeight, bitsPerComponent: 8, bytesPerRow: sampleWidth * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return (nil, nil) }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))
            let pixels = storage.bindMemory(to: UInt8.self)
            var minX = sampleWidth, minY = sampleHeight, maxX = -1, maxY = -1
            struct Bucket { var count = 0; var edge = 0; var red = 0; var green = 0; var blue = 0 }
            var buckets: [Int: Bucket] = [:]
            var opaqueEdgeCount = 0, transparentCount = 0
            let bg = (background.count >= 3 ? background : [1, 1, 1]).prefix(3).map { Double($0) * 255 }
            for y in 0..<sampleHeight { for x in 0..<sampleWidth {
                let offset = (y * sampleWidth + x) * 4, alpha = Int(pixels[offset + 3])
                let distance = (0..<3).reduce(0.0) { value, channel in
                    let delta = Double(pixels[offset + channel]) - bg[channel]
                    return value + delta * delta
                }.squareRoot()
                let foreground = alpha >= 32 && (alpha < 245 || distance > 42)
                if foreground { minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y) }
                if alpha < 32 { transparentCount += 1 }
                guard alpha >= 220 else { continue }
                let key = (Int(pixels[offset]) / 24) << 16 | (Int(pixels[offset + 1]) / 24) << 8 | Int(pixels[offset + 2]) / 24
                let edgeBand = x < max(2, sampleWidth / 10) || x >= sampleWidth - max(2, sampleWidth / 10) || y < max(2, sampleHeight / 10) || y >= sampleHeight - max(2, sampleHeight / 10)
                var bucket = buckets[key, default: Bucket()]
                bucket.count += 1; bucket.red += Int(pixels[offset]); bucket.green += Int(pixels[offset + 1]); bucket.blue += Int(pixels[offset + 2])
                if edgeBand { bucket.edge += 1; opaqueEdgeCount += 1 }
                buckets[key] = bucket
            } }
            let dominant = buckets.values.max { $0.count < $1.count }
            let backdrop: CGColor? = dominant.flatMap { bucket in
                let total = sampleWidth * sampleHeight
                guard bucket.count * 100 >= total * 32,
                      opaqueEdgeCount > 0, bucket.edge * 100 >= opaqueEdgeCount * 68 else { return nil }
                let rgb = [bucket.red, bucket.green, bucket.blue].map { Double($0) / Double(bucket.count) / 255 }
                let chroma = (rgb.max() ?? 0) - (rgb.min() ?? 0)
                // Neutral full-bleed logos on opaque white/black pages remain
                // ordinary marks. A neutral rounded-square with transparent
                // corners and a large stable field is a composed icon canvas.
                let neutralRoundedCanvas = transparentCount * 100 >= total * 2 && bucket.count * 100 >= total * 45
                let neutralDeclaredCanvas = preserveDeclaredIconCanvas && squareInput && bucket.count * 100 >= total * 45
                guard chroma >= 0.10 || neutralRoundedCanvas || neutralDeclaredCanvas else { return nil }
                return CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [rgb[0], rgb[1], rgb[2], 1])
            }
            guard maxX >= minX, maxY >= minY else { return (nil, backdrop) }
            let margin = 2
            minX = max(0, minX - margin); minY = max(0, minY - margin)
            maxX = min(sampleWidth - 1, maxX + margin); maxY = min(sampleHeight - 1, maxY + margin)
            return (CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1), backdrop)
        }
        let full = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let square = Double(min(image.width, image.height)) / Double(max(image.width, image.height)) >= 0.9
        let canvas = square && result.backdrop != nil
        guard let sampleCrop = result.crop else {
            return .init(crop: full, subjectWidth: image.width, subjectHeight: image.height, isPrecomposedCanvas: canvas, backdrop: result.backdrop)
        }
        let xScale = Double(image.width) / Double(sampleWidth), yScale = Double(image.height) / Double(sampleHeight)
        let crop = CGRect(x: floor(sampleCrop.minX * xScale), y: floor(sampleCrop.minY * yScale),
                          width: ceil(sampleCrop.width * xScale), height: ceil(sampleCrop.height * yScale)).intersection(full)
        return .init(crop: canvas ? full : crop,
                     subjectWidth: canvas ? image.width : max(1, Int(crop.width.rounded())),
                     subjectHeight: canvas ? image.height : max(1, Int(crop.height.rounded())),
                     isPrecomposedCanvas: canvas, backdrop: result.backdrop)
    }

    /// Replace only background pixels connected to the outer edge. This repairs
    /// white/transparent rounded-icon corners while preserving equally coloured
    /// details enclosed inside the mark.
    private static func replacingConnectedEdgeBackground(_ image: CGImage, with backdrop: CGColor) -> CGImage? {
        guard image.width <= 2048, image.height <= 2048 else { return image }
        let width = image.width, height = image.height, rowBytes = width * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * height)
        return bytes.withUnsafeMutableBytes { storage in
            guard let context = CGContext(data: storage.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let old = edgeBackground(image).components ?? [1, 1, 1, 1]
            let oldRGB = (old.count >= 3 ? Array(old.prefix(3)) : [1, 1, 1]).map { Int(($0 * 255).rounded()) }
            let fill = backdrop.components ?? [1, 1, 1, 1]
            let fillRGB = (fill.count >= 3 ? Array(fill.prefix(3)) : [1, 1, 1]).map { UInt8(max(0, min(255, Int(($0 * 255).rounded())))) }
            let pixels = storage.bindMemory(to: UInt8.self)
            var visited = [Bool](repeating: false, count: width * height), queue: [Int] = []
            func matches(_ index: Int) -> Bool {
                let offset = index * 4, alpha = Int(pixels[offset + 3])
                if alpha < 64 { return true }
                guard alpha >= 220 else { return false }
                let dr = Int(pixels[offset]) - oldRGB[0], dg = Int(pixels[offset + 1]) - oldRGB[1], db = Int(pixels[offset + 2]) - oldRGB[2]
                return dr * dr + dg * dg + db * db < 34 * 34
            }
            func seed(_ index: Int) {
                guard !visited[index], matches(index) else { return }
                visited[index] = true; queue.append(index)
            }
            for x in 0..<width { seed(x); seed((height - 1) * width + x) }
            for y in 0..<height { seed(y * width); seed(y * width + width - 1) }
            var cursor = 0
            while cursor < queue.count {
                let index = queue[cursor]; cursor += 1
                let x = index % width, y = index / width, offset = index * 4
                pixels[offset] = fillRGB[0]; pixels[offset + 1] = fillRGB[1]; pixels[offset + 2] = fillRGB[2]; pixels[offset + 3] = 255
                if x > 0 { seed(index - 1) }; if x + 1 < width { seed(index + 1) }
                if y > 0 { seed(index - width) }; if y + 1 < height { seed(index + width) }
            }
            // Some official icons use enclosed transparency as white negative
            // space (LinkedIn's letters are a real example). Once the outer
            // corners are filled, those interior holes must become opaque or the
            // brand-colour destination background would erase the glyph.
            for index in 0..<(width * height) where !visited[index] {
                let offset = index * 4
                if pixels[offset + 3] < 64 {
                    pixels[offset] = UInt8(oldRGB[0]); pixels[offset + 1] = UInt8(oldRGB[1]); pixels[offset + 2] = UInt8(oldRGB[2]); pixels[offset + 3] = 255
                }
            }
            return context.makeImage()
        }
    }

    private static func removingNeutralIconFrame(_ image: CGImage, backdrop: CGColor) -> CGImage {
        let color=backdrop.components ?? []
        guard color.count>=3, color.prefix(3).allSatisfy({ $0>0.94 }),image.width<=2048,image.height<=2048 else { return image }
        let w=image.width,h=image.height
        var bytes=[UInt8](repeating:0,count:w*h*4)
        return bytes.withUnsafeMutableBytes { raw in
            guard let ctx=CGContext(data:raw.baseAddress,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return image }
            ctx.draw(image,in:CGRect(x:0,y:0,width:w,height:h))
            let p=raw.bindMemory(to:UInt8.self)
            for y in 0..<h { for x in 0..<w where x<w/8 || x>=w-w/8 || y<h/8 || y>=h-h/8 {
                let i=(y*w+x)*4,alpha=max(1,Int(p[i+3])),rgb=(0..<3).map { min(255,Int(p[i+$0])*255/alpha) }
                if rgb.max()!-rgb.min()!<15,rgb.min()!>180 {
                    for c in 0..<3 { p[i+c]=UInt8((color[c]*255).rounded()) };p[i+3]=255
                }
            } }
            return ctx.makeImage() ?? image
        }
    }

    private static func encodePNG(_ image:CGImage) throws -> Data {
        let png=NSMutableData()
        guard let destination=CGImageDestinationCreateWithData(png,"public.png" as CFString,1,nil) else { throw PortraitError.message("The PNG destination could not be created.") }
        CGImageDestinationAddImage(destination,image,nil)
        guard CGImageDestinationFinalize(destination) else { throw PortraitError.message("The PNG could not be saved.") }
        return png as Data
    }

    /// Large dimensions alone do not make a useful portrait. Institution sites
    /// sometimes publish a 500 px two-colour silhouette as their fallback. A
    /// tiny quantised palette whose first four colours cover almost the entire
    /// image is treated as a placeholder; photographic grayscale headshots keep
    /// hundreds of tone buckets and pass.
    private static func looksLikeFlatPlaceholder(_ image: CGImage) -> Bool {
        let width = 64, height = 64
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        return bytes.withUnsafeMutableBytes { storage in
            guard let context = CGContext(data: storage.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let pixels = storage.bindMemory(to: UInt8.self)
            var buckets: [Int: Int] = [:], opaque = 0
            for index in 0..<(width * height) {
                let offset = index * 4
                guard pixels[offset + 3] >= 220 else { continue }
                opaque += 1
                let key = (Int(pixels[offset]) / 16) << 8
                    | (Int(pixels[offset + 1]) / 16) << 4
                    | Int(pixels[offset + 2]) / 16
                buckets[key, default: 0] += 1
            }
            guard opaque * 100 >= width * height * 85, buckets.count <= 32 else { return false }
            let dominant = buckets.values.sorted(by: >).prefix(4).reduce(0, +)
            return dominant * 100 >= opaque * 96
        }
    }

    private static func edgeBackground(_ image: CGImage) -> CGColor {
        let n = 24
        var bytes = [UInt8](repeating: 0, count: n * n * 4)
        return bytes.withUnsafeMutableBytes { storage in
            guard let c = CGContext(data: storage.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return CGColor(gray: 1, alpha: 1) }
            c.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
            let pixels = storage.bindMemory(to: UInt8.self)
            var channels = [[Double]](repeating: [], count: 3)
            var edgeCount = 0
            for y in 0..<n { for x in 0..<n where x == 0 || x == n - 1 || y == 0 || y == n - 1 {
                edgeCount += 1
                let offset = (y * n + x) * 4
                guard pixels[offset + 3] >= 245 else { continue }
                for channel in 0..<3 { channels[channel].append(Double(pixels[offset + channel]) / 255) }
            } }
            // Transparent or multicolored edges do not establish a reliable background.
            guard channels[0].count * 4 >= edgeCount * 3 else { return CGColor(gray: 1, alpha: 1) }
            var rgb: [Double] = []
            for values in channels {
                let sorted = values.sorted()
                guard sorted[sorted.count * 9 / 10] - sorted[sorted.count / 10] < 0.22 else { return CGColor(gray: 1, alpha: 1) }
                rgb.append(sorted[sorted.count / 2])
            }
            // Keep sampling and fill in the same color space; a generic RGB color
            // would be converted a second time and leave a visible tonal seam.
            return CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [rgb[0], rgb[1], rgb[2], 1])!
        }
    }
}
