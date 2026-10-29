import AppKit

/// Three monochrome silhouettes, readable at the menu bar's native 18-point size.
/// The blade is filled when connected and outlined when disconnected. An outward
/// arrow marks a connected exit node. Errors belong in the tooltip and menu.
enum SwordIcon: String {
    case solid, empty, exitNode

    /// A deliberately chunky 12 × 12 grid inside an 18-point icon. Each cell is
    /// 1.5 points: exactly three physical pixels on a 2× Retina display.
    /// X: drawn in every variant. #: the blade's fill, solid variants only.
    static let map = [
        "..........XX",
        ".........X#X",
        "........X#X.",
        ".......X#X..",
        "..X...X#X...",
        "..XX.X#X....",
        "...XX#X.....",
        "....XX......",
        "...X.XX.....",
        "..X...XX....",
        "XX..........",
        "XX..........",
    ]
    static let size = 12
    static let menuPoints = 18

    /// The blade, guard, grip and pommel reflect exactly across x + y = 11.
    /// Keeping outline and fill symmetric separately preserves both base states.
    static var hasSymmetricBase: Bool {
        guard map.count == size, map.allSatisfy({ $0.count == size }) else { return false }
        let grid = map.map(Array.init)
        for y in 0..<size {
            for x in 0..<size where grid[y][x] != grid[size - 1 - x][size - 1 - y] { return false }
        }
        return true
    }

    /// An outward arrow occupies the blade's negative space. Unlike a
    /// dot, its silhouette still communicates routing at small sizes.
    private var badge: [(Int, Int)] {
        switch self {
        case .exitNode: return [(0, 0), (1, 0), (2, 0), (2, 1), (2, 2), (1, 1), (0, 2)]
        case .solid, .empty: return []
        }
    }

    private var filled: Bool { self == .solid || self == .exitNode }

    /// Grid cells (column, row) to paint, row 0 at the top.
    var cells: [(Int, Int)] {
        var out = badge
        for (row, line) in Self.map.enumerated() {
            for (col, ch) in line.enumerated() where ch == "X" || (filled && ch == "#") {
                out.append((col, row))
            }
        }
        return out
    }

    /// Paints the cells into `rect` (a square) in the current graphics context.
    func draw(in rect: NSRect, color: NSColor) {
        let cell = rect.width / CGFloat(Self.size)
        color.setFill()
        for (col, row) in cells {
            NSRect(x: rect.minX + CGFloat(col) * cell, y: rect.maxY - CGFloat(row + 1) * cell,
                   width: cell, height: cell).fill()
        }
    }

    /// Explicit 1× and 2× bitmaps prevent AppKit from resampling the pixel grid
    /// at Retina scale. At 1× the half-pixel edges use normal antialiasing; at 2×
    /// every cell lands on a whole 3 × 3 block of physical pixels.
    var menuBarImage: NSImage {
        let points = NSSize(width: Self.menuPoints, height: Self.menuPoints)
        let image = NSImage(size: points)
        for scale in [1, 2] {
            let pixels = Self.menuPoints * scale
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSGraphicsContext.current?.shouldAntialias = true
            self.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), color: .black)
            NSGraphicsContext.restoreGraphicsState()
            rep.size = points
            image.addRepresentation(rep)
        }
        image.isTemplate = true
        switch self {
        case .solid: image.accessibilityDescription = "Tailnet connected"
        case .empty: image.accessibilityDescription = "Tailnet disconnected"
        case .exitNode: image.accessibilityDescription = "Tailnet connected through an exit node"
        }
        return image
    }
}
