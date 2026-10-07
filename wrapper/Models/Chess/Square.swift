import Foundation

/// Square helpers. Index 0 = a1, 7 = h1, 56 = a8, 63 = h8.
nonisolated enum Square {
    static func file(_ s: Int) -> Int { s & 7 }
    static func rank(_ s: Int) -> Int { s >> 3 }
    static func index(file: Int, rank: Int) -> Int { rank * 8 + file }

    static func isValid(file: Int, rank: Int) -> Bool {
        file >= 0 && file < 8 && rank >= 0 && rank < 8
    }

    static func fileName(_ f: Int) -> String {
        String(Character(UnicodeScalar(UInt8(97 + max(0, min(7, f))))))
    }

    static func name(_ s: Int) -> String { fileName(file(s)) + "\(rank(s) + 1)" }

    static func parse(_ text: String) -> Int? {
        let chars = Array(text.lowercased())
        guard chars.count == 2,
              let fileAscii = chars[0].asciiValue,
              let rankValue = chars[1].wholeNumberValue else { return nil }
        let f = Int(fileAscii) - 97
        let r = rankValue - 1
        guard isValid(file: f, rank: r) else { return nil }
        return index(file: f, rank: r)
    }

    static func isLight(_ s: Int) -> Bool { (file(s) + rank(s)) % 2 == 1 }

    static func distance(_ a: Int, _ b: Int) -> Int {
        max(abs(file(a) - file(b)), abs(rank(a) - rank(b)))
    }

    /// Orthogonal directions first (0...3), diagonals after (4...7).
    static let directions: [(Int, Int)] = [(0, 1), (0, -1), (1, 0), (-1, 0), (1, 1), (1, -1), (-1, 1), (-1, -1)]

    static let knightTargets: [[Int]] = (0..<64).map { s in
        let deltas = [(1, 2), (2, 1), (2, -1), (1, -2), (-1, -2), (-2, -1), (-2, 1), (-1, 2)]
        return deltas.compactMap { d in
            let f = file(s) + d.0, r = rank(s) + d.1
            return isValid(file: f, rank: r) ? index(file: f, rank: r) : nil
        }
    }

    static let kingTargets: [[Int]] = (0..<64).map { s in
        directions.compactMap { d in
            let f = file(s) + d.0, r = rank(s) + d.1
            return isValid(file: f, rank: r) ? index(file: f, rank: r) : nil
        }
    }

    /// rays[square][direction] = squares walked outward from `square`.
    static let rays: [[[Int]]] = (0..<64).map { s in
        directions.map { d in
            var out: [Int] = []
            var f = file(s) + d.0, r = rank(s) + d.1
            while isValid(file: f, rank: r) {
                out.append(index(file: f, rank: r))
                f += d.0
                r += d.1
            }
            return out
        }
    }

    /// Squares strictly between two aligned squares (empty if not aligned).
    static func between(_ a: Int, _ b: Int) -> [Int] {
        for ray in rays[a] {
            if let i = ray.firstIndex(of: b) { return Array(ray[..<i]) }
        }
        return []
    }
}
