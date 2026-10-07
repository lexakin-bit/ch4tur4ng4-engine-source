import Foundation

nonisolated struct CastlingRights: Hashable, Codable, Sendable {
    var whiteKingside: Bool = false
    var whiteQueenside: Bool = false
    var blackKingside: Bool = false
    var blackQueenside: Bool = false

    static let all = CastlingRights(whiteKingside: true, whiteQueenside: true, blackKingside: true, blackQueenside: true)
    static let none = CastlingRights()

    var fen: String {
        var s = ""
        if whiteKingside { s += "K" }
        if whiteQueenside { s += "Q" }
        if blackKingside { s += "k" }
        if blackQueenside { s += "q" }
        return s.isEmpty ? "-" : s
    }

    var isEmpty: Bool { !(whiteKingside || whiteQueenside || blackKingside || blackQueenside) }
}

nonisolated extension CastlingRights {
    init(fen: String) {
        self.init(
            whiteKingside: fen.contains("K"),
            whiteQueenside: fen.contains("Q"),
            blackKingside: fen.contains("k"),
            blackQueenside: fen.contains("q")
        )
    }
}

/// Immutable-style chess position. `making(_:)` returns the next position.
nonisolated struct Position: Hashable, Codable, Sendable {
    var board: [Int8]
    var sideToMove: PieceColor
    var castling: CastlingRights
    var enPassant: Int?
    var halfmoveClock: Int
    var fullmoveNumber: Int

    static let startFEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
    static let start: Position = Position(fen: startFEN) ?? .empty
    static let empty = Position(board: [Int8](repeating: 0, count: 64), sideToMove: .white, castling: .none, enPassant: nil, halfmoveClock: 0, fullmoveNumber: 1)

    init(board: [Int8], sideToMove: PieceColor, castling: CastlingRights, enPassant: Int?, halfmoveClock: Int, fullmoveNumber: Int) {
        self.board = board
        self.sideToMove = sideToMove
        self.castling = castling
        self.enPassant = enPassant
        self.halfmoveClock = halfmoveClock
        self.fullmoveNumber = fullmoveNumber
    }

    init?(fen: String) {
        let parts = fen.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        guard let placement = parts.first else { return nil }
        let rows = placement.split(separator: "/", omittingEmptySubsequences: false)
        guard rows.count == 8 else { return nil }
        var b = [Int8](repeating: 0, count: 64)
        for (i, row) in rows.enumerated() {
            let rank = 7 - i
            var file = 0
            for ch in row {
                if let n = ch.wholeNumberValue {
                    file += n
                } else if let p = Piece(fen: ch) {
                    guard file < 8 else { return nil }
                    b[Square.index(file: file, rank: rank)] = p.code
                    file += 1
                } else {
                    return nil
                }
            }
            guard file == 8 else { return nil }
        }
        board = b
        sideToMove = parts.count > 1 && parts[1].lowercased() == "b" ? .black : .white
        castling = parts.count > 2 ? CastlingRights(fen: parts[2]) : .none
        enPassant = parts.count > 3 ? Square.parse(parts[3]) : nil
        halfmoveClock = parts.count > 4 ? (Int(parts[4]) ?? 0) : 0
        fullmoveNumber = parts.count > 5 ? max(1, Int(parts[5]) ?? 1) : 1
    }

    // MARK: FEN

    var placementFEN: String {
        var rows: [String] = []
        for rank in stride(from: 7, through: 0, by: -1) {
            var row = ""
            var empty = 0
            for file in 0..<8 {
                if let p = self[Square.index(file: file, rank: rank)] {
                    if empty > 0 { row += "\(empty)"; empty = 0 }
                    row.append(p.fenChar)
                } else {
                    empty += 1
                }
            }
            if empty > 0 { row += "\(empty)" }
            rows.append(row)
        }
        return rows.joined(separator: "/")
    }

    var fen: String {
        let ep = enPassant.map { Square.name($0) } ?? "-"
        return "\(placementFEN) \(sideToMove.fenChar) \(castling.fen) \(ep) \(halfmoveClock) \(fullmoveNumber)"
    }

    /// Placement + side to move. Used to match opening theory regardless of clocks.
    var theoryKey: String { "\(placementFEN) \(sideToMove.fenChar)" }

    // MARK: Access

    subscript(_ s: Int) -> Piece? { Piece(code: board[s]) }

    func isOwn(_ s: Int, _ color: PieceColor) -> Bool {
        let c = board[s]
        return c != 0 && (c > 0) == (color == .white)
    }

    func isEnemy(_ s: Int, _ color: PieceColor) -> Bool {
        let c = board[s]
        return c != 0 && (c > 0) != (color == .white)
    }

    func kingSquare(_ color: PieceColor) -> Int? {
        board.firstIndex(of: Int8(6 * color.sign))
    }

    func pieces(of color: PieceColor) -> [(square: Int, piece: Piece)] {
        var out: [(square: Int, piece: Piece)] = []
        for s in 0..<64 {
            if let p = self[s], p.color == color { out.append((square: s, piece: p)) }
        }
        return out
    }

    func count(_ kind: PieceKind, _ color: PieceColor) -> Int {
        let code = Int8(kind.rawValue * color.sign)
        return board.reduce(0) { $0 + ($1 == code ? 1 : 0) }
    }

    func material(_ color: PieceColor) -> Int {
        pieces(of: color).reduce(0) { $0 + $1.piece.kind.points }
    }

    func nonPawnMaterial(_ color: PieceColor) -> Int {
        pieces(of: color).reduce(0) { $0 + ($1.piece.kind == .pawn ? 0 : $1.piece.kind.points) }
    }

    // MARK: Attacks

    func isAttacked(_ sq: Int, by color: PieceColor) -> Bool {
        let f = Square.file(sq), r = Square.rank(sq)
        let pawn = Int8(color.sign)
        let pr = color == .white ? r - 1 : r + 1
        if pr >= 0 && pr < 8 {
            if f > 0 && board[Square.index(file: f - 1, rank: pr)] == pawn { return true }
            if f < 7 && board[Square.index(file: f + 1, rank: pr)] == pawn { return true }
        }
        let knight = Int8(2 * color.sign)
        for t in Square.knightTargets[sq] where board[t] == knight { return true }
        let king = Int8(6 * color.sign)
        for t in Square.kingTargets[sq] where board[t] == king { return true }
        let bishop = Int8(3 * color.sign), rook = Int8(4 * color.sign), queen = Int8(5 * color.sign)
        for d in 0..<8 {
            for t in Square.rays[sq][d] {
                let c = board[t]
                if c == 0 { continue }
                if c == queen || (d < 4 ? c == rook : c == bishop) { return true }
                break
            }
        }
        return false
    }

    /// Squares of `color` pieces that attack `sq`.
    func attackers(of sq: Int, by color: PieceColor) -> [Int] {
        var out: [Int] = []
        let f = Square.file(sq), r = Square.rank(sq)
        let pawn = Int8(color.sign)
        let pr = color == .white ? r - 1 : r + 1
        if pr >= 0 && pr < 8 {
            if f > 0, board[Square.index(file: f - 1, rank: pr)] == pawn { out.append(Square.index(file: f - 1, rank: pr)) }
            if f < 7, board[Square.index(file: f + 1, rank: pr)] == pawn { out.append(Square.index(file: f + 1, rank: pr)) }
        }
        let knight = Int8(2 * color.sign)
        for t in Square.knightTargets[sq] where board[t] == knight { out.append(t) }
        let king = Int8(6 * color.sign)
        for t in Square.kingTargets[sq] where board[t] == king { out.append(t) }
        let bishop = Int8(3 * color.sign), rook = Int8(4 * color.sign), queen = Int8(5 * color.sign)
        for d in 0..<8 {
            for t in Square.rays[sq][d] {
                let c = board[t]
                if c == 0 { continue }
                if c == queen || (d < 4 ? c == rook : c == bishop) { out.append(t) }
                break
            }
        }
        return out
    }

    /// Squares attacked by the piece standing on `s` (ignores pins).
    func attackedSquares(from s: Int) -> [Int] {
        guard let p = self[s] else { return [] }
        switch p.kind {
        case .pawn:
            let r = Square.rank(s) + (p.color == .white ? 1 : -1)
            let f = Square.file(s)
            guard r >= 0 && r < 8 else { return [] }
            return [f - 1, f + 1].filter { $0 >= 0 && $0 < 8 }.map { Square.index(file: $0, rank: r) }
        case .knight:
            return Square.knightTargets[s]
        case .king:
            return Square.kingTargets[s]
        case .bishop, .rook, .queen:
            let dirs: Range<Int> = p.kind == .rook ? 0..<4 : (p.kind == .bishop ? 4..<8 : 0..<8)
            var out: [Int] = []
            for d in dirs {
                for t in Square.rays[s][d] {
                    out.append(t)
                    if board[t] != 0 { break }
                }
            }
            return out
        }
    }

    func inCheck(_ color: PieceColor) -> Bool {
        guard let k = kingSquare(color) else { return false }
        return isAttacked(k, by: color.opposite)
    }

    var isCheck: Bool { inCheck(sideToMove) }
    var isCheckmate: Bool { isCheck && legalMoves().isEmpty }
    var isStalemate: Bool { !isCheck && legalMoves().isEmpty }

    var isInsufficientMaterial: Bool {
        var minorCount = 0
        for c in board where c != 0 {
            switch abs(c) {
            case 6: continue
            case 2, 3: minorCount += 1
            default: return false
            }
            if minorCount > 1 { return false }
        }
        return true
    }

    // MARK: Move generation

    func pseudoLegalMoves(capturesOnly: Bool = false) -> [Move] {
        var moves: [Move] = []
        moves.reserveCapacity(capturesOnly ? 12 : 48)
        let us = sideToMove
        for s in 0..<64 {
            let c = board[s]
            guard c != 0, (c > 0) == (us == .white) else { continue }
            switch Int(abs(c)) {
            case 1:
                generatePawnMoves(s, us, capturesOnly, &moves)
            case 2:
                for t in Square.knightTargets[s] where !isOwn(t, us) {
                    if capturesOnly && board[t] == 0 { continue }
                    moves.append(Move(from: s, to: t))
                }
            case 6:
                for t in Square.kingTargets[s] where !isOwn(t, us) {
                    if capturesOnly && board[t] == 0 { continue }
                    moves.append(Move(from: s, to: t))
                }
                if !capturesOnly { generateCastling(s, us, &moves) }
            default:
                let kind = Int(abs(c))
                let dirs: Range<Int> = kind == 4 ? 0..<4 : (kind == 3 ? 4..<8 : 0..<8)
                for d in dirs {
                    for t in Square.rays[s][d] {
                        let target = board[t]
                        if target == 0 {
                            if !capturesOnly { moves.append(Move(from: s, to: t)) }
                            continue
                        }
                        if isEnemy(t, us) { moves.append(Move(from: s, to: t)) }
                        break
                    }
                }
            }
        }
        return moves
    }

    private func generatePawnMoves(_ s: Int, _ us: PieceColor, _ capturesOnly: Bool, _ moves: inout [Move]) {
        let f = Square.file(s), r = Square.rank(s)
        let dir = us == .white ? 1 : -1
        let startRank = us == .white ? 1 : 6
        let promoRank = us == .white ? 7 : 0
        let r1 = r + dir
        guard r1 >= 0 && r1 < 8 else { return }
        let one = Square.index(file: f, rank: r1)
        if board[one] == 0 {
            if r1 == promoRank {
                appendPromotions(s, one, &moves)
            } else if !capturesOnly {
                moves.append(Move(from: s, to: one))
                if r == startRank {
                    let two = Square.index(file: f, rank: r + 2 * dir)
                    if board[two] == 0 { moves.append(Move(from: s, to: two)) }
                }
            }
        }
        for df in [-1, 1] {
            let nf = f + df
            guard nf >= 0 && nf < 8 else { continue }
            let t = Square.index(file: nf, rank: r1)
            if isEnemy(t, us) {
                if r1 == promoRank { appendPromotions(s, t, &moves) } else { moves.append(Move(from: s, to: t)) }
            } else if t == enPassant, board[t] == 0 {
                moves.append(Move(from: s, to: t))
            }
        }
    }

    private func appendPromotions(_ from: Int, _ to: Int, _ moves: inout [Move]) {
        for kind in [PieceKind.queen, .rook, .bishop, .knight] {
            moves.append(Move(from: from, to: to, promotion: kind))
        }
    }

    private func generateCastling(_ s: Int, _ us: PieceColor, _ moves: inout [Move]) {
        let home = us == .white ? 4 : 60
        guard s == home else { return }
        let them = us.opposite
        let rook = Int8(4 * us.sign)
        let kingside = us == .white ? castling.whiteKingside : castling.blackKingside
        let queenside = us == .white ? castling.whiteQueenside : castling.blackQueenside
        guard kingside || queenside, !isAttacked(home, by: them) else { return }
        if kingside, board[home + 1] == 0, board[home + 2] == 0, board[home + 3] == rook,
           !isAttacked(home + 1, by: them), !isAttacked(home + 2, by: them) {
            moves.append(Move(from: home, to: home + 2))
        }
        if queenside, board[home - 1] == 0, board[home - 2] == 0, board[home - 3] == 0, board[home - 4] == rook,
           !isAttacked(home - 1, by: them), !isAttacked(home - 2, by: them) {
            moves.append(Move(from: home, to: home - 2))
        }
    }

    func legalMoves() -> [Move] {
        let us = sideToMove
        return pseudoLegalMoves().filter { !making($0).inCheck(us) }
    }

    func legalMoves(from s: Int) -> [Move] {
        legalMoves().filter { $0.from == s }
    }

    /// Resolves a from/to pair (UI input) to a legal move, defaulting promotions to a queen.
    func legalMove(from: Int, to: Int, promotion: PieceKind? = nil) -> Move? {
        let candidates = legalMoves().filter { $0.from == from && $0.to == to }
        if candidates.isEmpty { return nil }
        if let promotion, let m = candidates.first(where: { $0.promotion == promotion }) { return m }
        return candidates.first(where: { $0.promotion == .queen || $0.promotion == nil }) ?? candidates.first
    }

    func isCapture(_ m: Move) -> Bool {
        board[m.to] != 0 || (abs(board[m.from]) == 1 && Square.file(m.from) != Square.file(m.to))
    }

    func capturedPiece(_ m: Move) -> Piece? {
        if let p = self[m.to] { return p }
        if abs(board[m.from]) == 1 && Square.file(m.from) != Square.file(m.to) {
            return Piece(.pawn, sideToMove.opposite)
        }
        return nil
    }

    func isCastle(_ m: Move) -> Bool {
        abs(board[m.from]) == 6 && abs(m.to - m.from) == 2
    }

    func making(_ m: Move) -> Position {
        var p = self
        let c = board[m.from]
        let kind = abs(c)
        let us = sideToMove
        let captured = board[m.to]
        p.board[m.from] = 0
        if kind == 1 && m.to == enPassant && captured == 0 && Square.file(m.from) != Square.file(m.to) {
            p.board[m.to - us.forward] = 0
        }
        let lastRank = Square.rank(m.to) == 7 || Square.rank(m.to) == 0
        if kind == 1 && lastRank {
            p.board[m.to] = Int8((m.promotion ?? .queen).rawValue * us.sign)
        } else {
            p.board[m.to] = c
        }
        if kind == 6 && abs(m.to - m.from) == 2 {
            if m.to > m.from {
                p.board[m.from + 1] = p.board[m.from + 3]
                p.board[m.from + 3] = 0
            } else {
                p.board[m.from - 1] = p.board[m.from - 4]
                p.board[m.from - 4] = 0
            }
        }
        for sq in [m.from, m.to] {
            switch sq {
            case 0: p.castling.whiteQueenside = false
            case 7: p.castling.whiteKingside = false
            case 4: p.castling.whiteKingside = false; p.castling.whiteQueenside = false
            case 56: p.castling.blackQueenside = false
            case 63: p.castling.blackKingside = false
            case 60: p.castling.blackKingside = false; p.castling.blackQueenside = false
            default: break
            }
        }
        p.enPassant = (kind == 1 && abs(m.to - m.from) == 16) ? (m.from + m.to) / 2 : nil
        p.halfmoveClock = (kind == 1 || captured != 0) ? 0 : halfmoveClock + 1
        if us == .black { p.fullmoveNumber += 1 }
        p.sideToMove = us.opposite
        return p
    }

    /// Same position with the other side to move (used to ask "what is my opponent threatening?").
    func passingTurn() -> Position {
        var p = self
        p.sideToMove = sideToMove.opposite
        p.enPassant = nil
        return p
    }

    // MARK: SAN

    func san(_ m: Move, includeCheck: Bool = true) -> String {
        guard let piece = self[m.from] else { return m.uci }
        var s: String
        if piece.kind == .king && abs(m.to - m.from) == 2 {
            s = m.to > m.from ? "O-O" : "O-O-O"
        } else {
            let capture = isCapture(m)
            if piece.kind == .pawn {
                s = capture ? Square.fileName(Square.file(m.from)) + "x" : ""
                s += Square.name(m.to)
                let lastRank = Square.rank(m.to) == 7 || Square.rank(m.to) == 0
                if lastRank { s += "=" + (m.promotion ?? .queen).sanLetter }
            } else {
                s = piece.kind.sanLetter
                let others = legalMoves().filter { $0.to == m.to && $0.from != m.from && board[$0.from] == board[m.from] }
                if !others.isEmpty {
                    let sameFile = others.contains { Square.file($0.from) == Square.file(m.from) }
                    let sameRank = others.contains { Square.rank($0.from) == Square.rank(m.from) }
                    if !sameFile {
                        s += Square.fileName(Square.file(m.from))
                    } else if !sameRank {
                        s += "\(Square.rank(m.from) + 1)"
                    } else {
                        s += Square.name(m.from)
                    }
                }
                if capture { s += "x" }
                s += Square.name(m.to)
            }
        }
        if includeCheck {
            let next = making(m)
            if next.inCheck(next.sideToMove) {
                s += next.legalMoves().isEmpty ? "#" : "+"
            }
        }
        return s
    }

    func move(fromSAN raw: String) -> Move? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.replacingOccurrences(of: "e.p.", with: "")
        t = t.replacingOccurrences(of: "0-0-0", with: "O-O-O").replacingOccurrences(of: "0-0", with: "O-O")
        t.removeAll { "+#!?=".contains($0) }
        guard !t.isEmpty else { return nil }
        let legal = legalMoves()
        func normalized(_ m: Move) -> String {
            var x = san(m, includeCheck: false)
            x.removeAll { $0 == "=" }
            return x
        }
        if let m = legal.first(where: { normalized($0) == t }) { return m }
        let loose = t.replacingOccurrences(of: "x", with: "")
        if let m = legal.first(where: { normalized($0).replacingOccurrences(of: "x", with: "") == loose }) { return m }
        if let m = Move(uci: t), let resolved = legalMove(from: m.from, to: m.to, promotion: m.promotion) { return resolved }
        return nil
    }

    /// Formats a line of moves from this position, e.g. "17. Rc1 Rc8 18. Qd2".
    func sanLine(_ moves: [Move], limit: Int = 8) -> String {
        var p = self
        var parts: [String] = []
        for (i, m) in moves.prefix(limit).enumerated() {
            guard p.legalMoves().contains(m) else { break }
            if p.sideToMove == .white {
                parts.append("\(p.fullmoveNumber). \(p.san(m))")
            } else if i == 0 {
                parts.append("\(p.fullmoveNumber)… \(p.san(m))")
            } else {
                parts.append(p.san(m))
            }
            p = p.making(m)
        }
        return parts.joined(separator: " ")
    }

    // MARK: Validation

    var validationIssues: [String] {
        var issues: [String] = []
        let wk = count(.king, .white), bk = count(.king, .black)
        if wk != 1 { issues.append(wk == 0 ? "White needs a king." : "White has more than one king.") }
        if bk != 1 { issues.append(bk == 0 ? "Black needs a king." : "Black has more than one king.") }
        for s in 0..<8 where abs(board[s]) == 1 || abs(board[56 + s]) == 1 {
            issues.append("Pawns cannot stand on the first or last rank.")
            break
        }
        if count(.pawn, .white) > 8 || count(.pawn, .black) > 8 { issues.append("A side cannot have more than eight pawns.") }
        if pieces(of: .white).count > 16 || pieces(of: .black).count > 16 { issues.append("A side cannot have more than sixteen pieces.") }
        if wk == 1 && bk == 1 && inCheck(sideToMove.opposite) {
            issues.append("\(sideToMove.opposite.name) is in check but it is \(sideToMove.name)'s move.")
        }
        return issues
    }

    var isValidForAnalysis: Bool { validationIssues.isEmpty }

    /// Clears castling rights that the placement makes impossible.
    func sanitizedCastling() -> Position {
        var p = self
        if board[4] != 6 { p.castling.whiteKingside = false; p.castling.whiteQueenside = false }
        if board[7] != 4 { p.castling.whiteKingside = false }
        if board[0] != 4 { p.castling.whiteQueenside = false }
        if board[60] != -6 { p.castling.blackKingside = false; p.castling.blackQueenside = false }
        if board[63] != -4 { p.castling.blackKingside = false }
        if board[56] != -4 { p.castling.blackQueenside = false }
        if let ep = p.enPassant {
            let rank = Square.rank(ep)
            let valid = (p.sideToMove == .white && rank == 5 && board[ep - 8] == -1) || (p.sideToMove == .black && rank == 2 && board[ep + 8] == 1)
            if !valid || board[ep] != 0 { p.enPassant = nil }
        }
        return p
    }

    /// Placement rotated 90° clockwise — for photos taken from the side of the board.
    func rotatedClockwise() -> Position {
        var p = self
        var b = [Int8](repeating: 0, count: 64)
        for s in 0..<64 {
            let f = Square.file(s), r = Square.rank(s)
            b[Square.index(file: r, rank: 7 - f)] = board[s]
        }
        p.board = b
        p.castling = .none
        p.enPassant = nil
        return p
    }

    /// Whether castling or en passant could matter in this position.
    var hasAmbiguousState: Bool {
        let kingsHome = board[4] == 6 || board[60] == -6
        let pawnsOnFifth = (0..<8).contains { board[32 + $0] == 1 } || (0..<8).contains { board[24 + $0] == -1 }
        return kingsHome || pawnsOnFifth
    }
}
