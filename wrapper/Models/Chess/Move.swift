import Foundation

nonisolated struct Move: Hashable, Codable, Sendable {
    let from: Int
    let to: Int
    var promotion: PieceKind?

    init(from: Int, to: Int, promotion: PieceKind? = nil) {
        self.from = from
        self.to = to
        self.promotion = promotion
    }

    init?(uci: String) {
        let text = uci.trimmingCharacters(in: .whitespaces).lowercased()
        guard text.count == 4 || text.count == 5 else { return nil }
        let chars = Array(text)
        guard let f = Square.parse(String(chars[0...1])), let t = Square.parse(String(chars[2...3])) else { return nil }
        from = f
        to = t
        if chars.count == 5 {
            guard let kind = PieceKind.allCases.first(where: { $0.fenLower == chars[4] }), kind != .pawn, kind != .king else { return nil }
            promotion = kind
        } else {
            promotion = nil
        }
    }

    var uci: String {
        Square.name(from) + Square.name(to) + (promotion.map { String($0.fenLower) } ?? "")
    }
}
