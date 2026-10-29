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
        NSGradient(colors: [NSColor(calibratedRed: 0.035, green: 0.11, blue: 0.14, alpha: 1),
                            NSColor(calibratedRed: 0.12, green: 0.28, blue: 0.31, alpha: 1)])!.draw(in: path, angle: 90)
        // Snap the sword to whole pixels so small sizes stay crisp.
        // At 16px use a fractional scale rather than overflowing the tile.
        let cell = tile.width * 0.78 / CGFloat(SwordIcon.size)
        let side = (cell >= 1 ? cell.rounded(.down) : cell) * CGFloat(SwordIcon.size)
        let origin = ((size - side) / 2).rounded(.down)
        SwordIcon.solid.draw(in: NSRect(x: origin, y: origin, width: side, height: side), color: .white)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    static func preview() -> Data {
        let width = 900, height = 520
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let states: [(SwordIcon, String)] = [(.empty, "Disconnected"), (.solid, "Connected"), (.exitNode, "Connected + exit node")]
        for (row, dark) in [false, true].enumerated() {
            let y = CGFloat(row * 260)
            let background = dark ? NSColor(calibratedWhite: 0.10, alpha: 1) : NSColor(calibratedWhite: 0.96, alpha: 1)
            let foreground = dark ? NSColor.white : NSColor(calibratedWhite: 0.12, alpha: 1)
            background.setFill()
            NSRect(x: 0, y: y, width: CGFloat(width), height: 260).fill()
            for (column, state) in states.enumerated() {
                let x = CGFloat(column * 300)
                state.0.draw(in: NSRect(x: x + 102, y: y + 132, width: 96, height: 96), color: foreground)
                state.0.draw(in: NSRect(x: x + 101, y: y + 82, width: 18, height: 18), color: foreground)
                state.0.draw(in: NSRect(x: x + 174, y: y + 73, width: 36, height: 36), color: foreground)
                let captionAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: foreground.withAlphaComponent(0.65)]
                ("1× · 18px" as NSString).draw(at: NSPoint(x: x + 86, y: y + 53), withAttributes: captionAttrs)
                ("Retina 2× · 36px" as NSString).draw(at: NSPoint(x: x + 154, y: y + 53), withAttributes: captionAttrs)
                let representations = state.0.menuBarImage.representations
                precondition(representations.map(\.pixelsWide).sorted() == [18, 36], "Both menu-bar scales must exist")
                let label = state.1 as NSString
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: foreground]
                label.draw(at: NSPoint(x: x + (300 - label.size(withAttributes: attrs).width) / 2, y: y + 21), withAttributes: attrs)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    static func main() throws {
        precondition(SwordIcon.hasSymmetricBase, "Sword outline and fill must mirror across the blade axis")
        if CommandLine.arguments.dropFirst().first == "--preview" {
            let path = CommandLine.arguments.dropFirst(2).first ?? "Resources/SwordPreview.png"
            try preview().write(to: URL(fileURLWithPath: path))
            return
        }
        let output = CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.iconset"
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        for (name, pixels) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                               ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512),
                               ("512x512@2x", 1024)] {
            try render(pixels).write(to: URL(fileURLWithPath: "\(output)/icon_\(name).png"))
        }
    }
}
