import Foundation

/// Side of the board. Raw value doubles as the sign used in the board array.
nonisolated enum PieceColor: Int, Codable, Sendable, Hashable, CaseIterable {
    case white = 1
    case black = -1

    var opposite: PieceColor { self == .white ? .black : .white }
    var name: String { self == .white ? "White" : "Black" }
    var possessive: String { self == .white ? "White's" : "Black's" }
    var fenChar: String { self == .white ? "w" : "b" }
    /// Pawn push direction in square-index units.
    var forward: Int { self == .white ? 8 : -8 }
    var sign: Int { rawValue }
}

nonisolated enum PieceKind: Int, Codable, Sendable, Hashable, CaseIterable {
    case pawn = 1, knight, bishop, rook, queen, king

    var points: Int {
        switch self {
        case .pawn: 1
        case .knight, .bishop: 3
        case .rook: 5
        case .queen: 9
        case .king: 0
        }
    }

    var centipawns: Int {
        switch self {
        case .pawn: 100
        case .knight: 320
        case .bishop: 330
        case .rook: 500
        case .queen: 900
        case .king: 0
        }
    }

    var name: String {
        switch self {
        case .pawn: "pawn"
        case .knight: "knight"
        case .bishop: "bishop"
        case .rook: "rook"
        case .queen: "queen"
        case .king: "king"
        }
    }

    var plural: String { name + "s" }

    var sanLetter: String {
        switch self {
        case .pawn: ""
        case .knight: "N"
        case .bishop: "B"
        case .rook: "R"
        case .queen: "Q"
        case .king: "K"
        }
    }

    var fenLower: Character {
        switch self {
        case .pawn: "p"
        case .knight: "n"
        case .bishop: "b"
        case .rook: "r"
        case .queen: "q"
        case .king: "k"
        }
    }

    /// Solid glyph with a text-presentation selector so it never renders as emoji.
    var glyph: String {
        switch self {
        case .pawn: "\u{265F}\u{FE0E}"
        case .knight: "\u{265E}\u{FE0E}"
        case .bishop: "\u{265D}\u{FE0E}"
        case .rook: "\u{265C}\u{FE0E}"
        case .queen: "\u{265B}\u{FE0E}"
        case .king: "\u{265A}\u{FE0E}"
        }
    }

    var isSlider: Bool { self == .bishop || self == .rook || self == .queen }
}

nonisolated struct Piece: Hashable, Codable, Sendable {
    let kind: PieceKind
    let color: PieceColor

    init(_ kind: PieceKind, _ color: PieceColor) {
        self.kind = kind
        self.color = color
    }

    init?(code: Int8) {
        guard code != 0, let kind = PieceKind(rawValue: Int(abs(code))) else { return nil }
        self.kind = kind
        self.color = code > 0 ? .white : .black
    }

    init?(fen: Character) {
        let lower = Character(fen.lowercased())
        guard let kind = PieceKind.allCases.first(where: { $0.fenLower == lower }) else { return nil }
        self.kind = kind
        self.color = fen.isUppercase ? .white : .black
    }

    var code: Int8 { Int8(kind.rawValue * color.rawValue) }

    var fenChar: Character {
        color == .white ? Character(String(kind.fenLower).uppercased()) : kind.fenLower
    }

    /// e.g. "white knight"
    var name: String { "\(color.name.lowercased()) \(kind.name)" }
}
