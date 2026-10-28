import AppKit

/// The pixel sword drawn in the menu bar (and, via tools/MakeIcon.swift, in the app icon).
/// Solid while connected, empty (outline) while not; a dot means an exit node carries traffic,
/// a "!" means something needs a look.
enum SwordIcon: String {
    case solid, empty, exitNode, warning

    /// 18 × 18 cells. X: drawn in every variant. #: the blade's fill, solid variants only.
    static let map = [
        "...............XXX",
        "..............X##X",
        ".............X###X",
        "............X###X.",
        "...........X###X..",
        "..........X###X...",
        ".........X###X....",
        "....XX..X###X.....",
        ".....XXX###X......",
        "......XXX#X.......",
        ".......XXX........",
        ".....XX.XX........",
        "....XX...XX.......",
        "...XX.....X.......",
        "...X..............",
        ".XX...............",
        ".XX...............",
        "..................",
    ]
    static let size = 18

    /// Extra cells in the empty top-left corner: a dot for an exit node, a "!" for a warning.
    private var badge: [(Int, Int)] {
        switch self {
        case .exitNode: return [(1, 1), (2, 1), (1, 2), (2, 2)]
        case .warning: return [(1, 0), (2, 0), (1, 1), (2, 1), (1, 2), (2, 2), (1, 3), (2, 3), (1, 5), (2, 5)]
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
        image.accessibilityDescription = "Tailnet"
        return image
    }
}
