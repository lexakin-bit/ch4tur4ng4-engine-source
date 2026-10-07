import Foundation

nonisolated enum ArrowStyle: String, Codable, Sendable, Hashable {
    case suggestion, idea, threat, user, ghost
}

nonisolated struct BoardArrow: Hashable, Codable, Sendable {
    let from: Int
    let to: Int
    var style: ArrowStyle = .idea
}

nonisolated enum MarkStyle: String, Codable, Sendable, Hashable {
    case focus, region, target, candidate, uncertain
}

nonisolated struct SquareMark: Hashable, Sendable {
    let square: Int
    let style: MarkStyle
}

/// Everything drawn on top of the board for one teaching moment.
nonisolated struct BoardAnnotations: Hashable, Sendable {
    var marks: [SquareMark] = []
    var arrows: [BoardArrow] = []
    /// Fade pieces that are not part of the idea, so the eye lands on what matters.
    var dimOthers: Bool = false

    static let none = BoardAnnotations()

    init(marks: [SquareMark] = [], arrows: [BoardArrow] = [], dimOthers: Bool = false) {
        self.marks = marks
        self.arrows = arrows
        self.dimOthers = dimOthers
    }

    init(squares: [Int], style: MarkStyle = .focus, arrows: [BoardArrow] = [], dimOthers: Bool = false) {
        self.marks = squares.map { SquareMark(square: $0, style: style) }
        self.arrows = arrows
        self.dimOthers = dimOthers
    }

    var isEmpty: Bool { marks.isEmpty && arrows.isEmpty }

    var focusSquares: Set<Int> {
        var s = Set(marks.map(\.square))
        for a in arrows { s.insert(a.from); s.insert(a.to) }
        return s
    }
}

nonisolated extension Position {
    /// Vertical mirror with colours swapped — the same idea for the other side.
    func mirrored() -> Position {
        var b = [Int8](repeating: 0, count: 64)
        for s in 0..<64 { b[s ^ 56] = -board[s] }
        let c = CastlingRights(whiteKingside: castling.blackKingside, whiteQueenside: castling.blackQueenside, blackKingside: castling.whiteKingside, blackQueenside: castling.whiteQueenside)
        return Position(board: b, sideToMove: sideToMove.opposite, castling: c, enPassant: enPassant.map { $0 ^ 56 }, halfmoveClock: halfmoveClock, fullmoveNumber: fullmoveNumber)
    }
}

nonisolated extension Move {
    func mirrored() -> Move { Move(from: from ^ 56, to: to ^ 56, promotion: promotion) }
}

nonisolated enum Grammar {
    /// "rook", "knight and rook", "king, queen and rook"
    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + " and " + (items.last ?? "")
        }
    }

    static func article(_ word: String) -> String {
        guard let first = word.lowercased().first else { return "a" }
        return "aeiou".contains(first) ? "an" : "a"
    }

    static func number(_ n: Int) -> String {
        let words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
        return n >= 0 && n < words.count ? words[n] : "\(n)"
    }

    static func capitalized(_ s: String) -> String {
        guard let f = s.first else { return s }
        return f.uppercased() + s.dropFirst()
    }
}
