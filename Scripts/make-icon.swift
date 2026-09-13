import AppKit
import ImageIO
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let size = base * scale
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let inset = rect.insetBy(dx: CGFloat(size) * 0.08, dy: CGFloat(size) * 0.08)
            let shape = NSBezierPath(roundedRect: inset, xRadius: CGFloat(size) * 0.18, yRadius: CGFloat(size) * 0.18)
            NSGradient(starting: NSColor(red: 0.18, green: 0.68, blue: 1, alpha: 1), ending: NSColor(red: 0.04, green: 0.36, blue: 0.94, alpha: 1))?.draw(in: shape, angle: -90)
            let config = NSImage.SymbolConfiguration(pointSize: CGFloat(size) * 0.54, weight: .light).applying(.init(paletteColors: [.white]))
            NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: nil)?.withSymbolConfiguration(config)?.draw(in: rect.insetBy(dx: CGFloat(size) * 0.23, dy: CGFloat(size) * 0.23))
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { fatalError("icon render failed") }
        let suffix = scale == 2 ? "@2x" : ""
        try png.write(to: folder.appendingPathComponent("icon_\(base)x\(base)\(suffix).png"))
    }
}
