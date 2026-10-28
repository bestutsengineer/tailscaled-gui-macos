import AppKit

/// Three monochrome silhouettes, readable at the menu bar's native 18-point size.
/// The blade is filled when connected and outlined when disconnected. An outward
/// arrow marks a connected exit node. Errors belong in the tooltip and menu.
enum SwordIcon: String {
    case solid, empty, exitNode

    /// 18 × 18 cells. X: drawn in every variant. #: the blade's fill, solid variants only.
    static let map = [
        "..................",
        "...............XX.",
        "..............X#X.",
        ".............X##X.",
        "............X##X..",
        "...........X##X...",
        "..........X##X....",
        "....XX...X##X.....",
        ".....XX.X##X......",
        "......XX##X.......",
        ".......XXX........",
        "......XX.XX.......",
        ".....XX...XX......",
        "....XX............",
        "...XX.............",
        "..XXX.............",
        "..XX..............",
        "..................",
    ]
    static let size = 18

    /// An outward arrow occupies the blade's negative space. Unlike a
    /// dot, its silhouette still communicates routing at small sizes.
    private var badge: [(Int, Int)] {
        switch self {
        case .exitNode: return [(2, 2), (3, 2), (4, 2), (4, 3), (4, 4), (3, 3), (2, 4), (1, 5)]
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

    /// An 18-point template image for the status item; macOS tints it for light and dark menu bars.
    var menuBarImage: NSImage {
        let side = CGFloat(Self.size)
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            self.draw(in: rect, color: .black)
            return true
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
