import CoreGraphics

/// The overview's content and geometry, kept pure so it can be checked.
public enum OverviewModel {
    public struct Card: Sendable, Equatable {
        /// Workspace number; for the "+" card, the free workspace a drop creates.
        public let workspace: Int
        public let isPlus: Bool
        public let isActive: Bool
        /// Windows, top-most first.
        public let windows: [UInt32]
    }

    /// Cards for one display: every workspace that has windows (plus the active one), in number
    /// order, then a "+" card for the first empty workspace.
    /// `visible` = windows showing now (top-most first); `parked` = (id, workspace, z).
    public static func cards(active: Int, visible: [UInt32], parked: [(id: UInt32, ws: Int, z: Int)]) -> [Card] {
        var by: [Int: [(UInt32, Int)]] = [active: visible.enumerated().map { ($0.element, $0.offset) }]
        for p in parked where p.ws != active { by[p.ws, default: []].append((p.id, p.z)) }
        var out = by.keys.sorted().map { n -> Card in
            let wins = n == active ? visible : by[n]!.sorted { $0.1 < $1.1 }.map(\.0)
            return Card(workspace: n, isPlus: false, isActive: n == active, windows: wins)
        }
        if let free = (1...WorkspaceState.count).first(where: { by[$0] == nil }) {
            out.append(Card(workspace: free, isPlus: true, isActive: false, windows: []))
        }
        return out
    }

    /// Workspace for a digit key, by key code (so ⇧ doesn't turn "1" into "!", and any
    /// keyboard layout's top row works): 1–9, 0 = 10; the keypad too. Nil for other keys.
    public static func workspace(forKeyCode code: Int) -> Int? {
        switch code {
        case 18, 83: 1
        case 19, 84: 2
        case 20, 85: 3
        case 21, 86: 4
        case 23, 87: 5
        case 22, 88: 6
        case 26, 89: 7
        case 28, 91: 8
        case 25, 92: 9
        case 29, 82: 10
        default: nil
        }
    }

    /// What a digit key does in the overview: with a window selected and ⇧ (or Space) held,
    /// send that window to workspace N of its display; otherwise show workspace N.
    public enum DigitAction: Equatable, Sendable { case show(Int), send(Int) }
    public static func digitAction(keyCode: Int, shift: Bool, carrying: Bool, windowSelected: Bool) -> DigitAction? {
        guard let n = workspace(forKeyCode: keyCode) else { return nil }
        return (shift || carrying) && windowSelected ? .send(n) : .show(n)
    }

    public struct Layout: Sendable, Equatable {
        public let cols: Int
        public let cardFrames: [CGRect]     // in the display's own coordinates (top-left origin)
        public let rowHeight: CGFloat
        public let rowsTop: CGFloat         // first row's offset inside a card
        public let maxRows: Int             // window rows that fit in a card
    }

    /// Grid of cards (same proportions as the Hammerspoon overview): 4 columns on wide
    /// displays, 3 otherwise; cards at most 460 pt tall; centred.
    public static func layout(cardCount n: Int, size: CGSize) -> Layout {
        let m: CGFloat = 44, gap: CGFloat = 22, top: CGFloat = 92, rowH: CGFloat = 40
        let cols = max(1, min(n, size.width >= 1700 ? 4 : 3))
        let rowsN = max(1, Int((Double(n) / Double(cols)).rounded(.up)))
        let cw = (size.width - 2 * m - CGFloat(cols - 1) * gap) / CGFloat(cols)
        let ch = min(460, (size.height - top - m - CGFloat(rowsN - 1) * gap) / CGFloat(rowsN))
        let gridW = CGFloat(cols) * cw + CGFloat(cols - 1) * gap
        let x0 = (size.width - gridW) / 2
        let frames = (0..<n).map { i in
            CGRect(x: x0 + CGFloat(i % cols) * (cw + gap), y: top + CGFloat(i / cols) * (ch + gap), width: cw, height: ch)
        }
        return Layout(cols: cols, cardFrames: frames, rowHeight: rowH, rowsTop: 56, maxRows: max(0, Int((ch - 64) / rowH)))
    }

    /// Keyboard selection: screen index, card index, row (0 = the whole card).
    public struct Selection: Sendable, Equatable {
        public var screen: Int, card: Int, row: Int
        public init(screen: Int, card: Int, row: Int) { self.screen = screen; self.card = card; self.row = row }
    }

    /// Moves the selection. ← / → go card to card and continue onto the next screen's cards;
    /// ↑ / ↓ go through a card's windows (row 0 = the card), then to the card above / below.
    /// `cards[s]` = number of cards on screen s; `rows[s][c]` = window rows on that card;
    /// `cols[s]` = grid columns on screen s.
    public static func move(_ sel: Selection, dx: Int, dy: Int, cards: [Int], rows: [[Int]], cols: [Int]) -> Selection {
        var s = sel.screen, c = sel.card, r = sel.row
        guard s < cards.count, c < cards[s] else { return sel }
        if dx != 0 {
            let nc = c + dx
            if nc >= 0 && nc < cards[s] { c = nc }
            else if s + dx >= 0 && s + dx < cards.count && cards[s + dx] > 0 {
                s += dx
                c = dx > 0 ? 0 : cards[s] - 1
            }
            r = min(r, rows[s][c])
        } else if dy != 0 {
            let nr = r + dy
            if nr >= 0 && nr <= rows[s][c] { r = nr }
            else if dy > 0 && c + cols[s] < cards[s] { c += cols[s]; r = 0 }
            else if dy < 0 && c - cols[s] >= 0 { c -= cols[s]; r = rows[s][c] }
        }
        return Selection(screen: s, card: c, row: r)
    }
}
