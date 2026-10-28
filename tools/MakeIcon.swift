import AppKit

/// Renders Resources/AppIcon.icns from SwordIcon's pixel map: the solid sword in white on a rounded tile.
/// Run from the repo root: ./tools/make-icon.sh
@main
enum MakeIcon {
    static func render(_ pixels: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let size = CGFloat(pixels)
        let tile = NSRect(x: size * 0.1, y: size * 0.1, width: size * 0.8, height: size * 0.8)
        let path = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
        NSGradient(colors: [NSColor(calibratedRed: 0.09, green: 0.11, blue: 0.16, alpha: 1),
                            NSColor(calibratedRed: 0.20, green: 0.25, blue: 0.36, alpha: 1)])!.draw(in: path, angle: 90)
        // Snap the sword to whole pixels so small sizes stay crisp.
        let cell = (tile.width * 0.72 / CGFloat(SwordIcon.size)).rounded(.down)
        let side = max(cell, 1) * CGFloat(SwordIcon.size)
        let origin = ((size - side) / 2).rounded(.down)
        SwordIcon.solid.draw(in: NSRect(x: origin, y: origin, width: side, height: side), color: .white)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    static func main() throws {
        let output = CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.iconset"
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        for (name, pixels) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                               ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512),
                               ("512x512@2x", 1024)] {
            try render(pixels).write(to: URL(fileURLWithPath: "\(output)/icon_\(name).png"))
        }
    }
}
