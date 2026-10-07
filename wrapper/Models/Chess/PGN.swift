import Foundation

/// A game replayed from PGN or a plain move list.
nonisolated struct ParsedGame: Sendable {
    var headers: [String: String]
    var start: Position
    var moves: [Move]
    var sans: [String]
    var positions: [Position]
    var result: String

    private func header(_ key: String) -> String? {
        guard let v = headers[key]?.trimmingCharacters(in: .whitespaces), !v.isEmpty, v != "?" else { return nil }
        return v
    }

    var white: String { header("White") ?? "White" }
    var black: String { header("Black") ?? "Black" }
    var event: String? { header("Event") }
    var dateText: String? { header("Date")?.replacingOccurrences(of: ".??", with: "") }
    var title: String { "\(white) vs \(black)" }
}

nonisolated enum PGNParser {
    private static let results: Set<String> = ["1-0", "0-1", "1/2-1/2", "½-½", "*"]

    /// Splits a multi-game PGN file into individual game texts.
    static func splitGames(_ text: String) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var games: [String] = []
        var current = ""
        var sawMoves = false
        for line in normalized.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && sawMoves {
                games.append(current)
                current = ""
                sawMoves = false
            }
            if !trimmed.isEmpty && !trimmed.hasPrefix("[") { sawMoves = true }
            current += line + "\n"
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { games.append(current) }
        return games
    }

    static func parse(_ text: String) -> ParsedGame? {
        var headers: [String: String] = [:]
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let headerRegex = try? NSRegularExpression(pattern: #"\[(\w+)\s+"([^"]*)"\]"#)
        headerRegex?.enumerateMatches(in: text, range: full) { match, _, _ in
            guard let match, match.numberOfRanges == 3 else { return }
            headers[ns.substring(with: match.range(at: 1))] = ns.substring(with: match.range(at: 2))
        }
        var body = headerRegex?.stringByReplacingMatches(in: text, range: full, withTemplate: " ") ?? text
        body = stripAnnotations(body)

        var start = Position.start
        if let fen = headers["FEN"], let p = Position(fen: fen) { start = p }

        var position = start
        var moves: [Move] = []
        var sans: [String] = []
        var positions: [Position] = [start]
        var result = headers["Result"] ?? "*"

        for raw in body.split(whereSeparator: { $0.isWhitespace }) {
            var token = String(raw)
            if results.contains(token) { result = token; continue }
            if let r = token.range(of: #"^\d+\.+"#, options: .regularExpression) { token.removeSubrange(r) }
            if token.isEmpty || token.hasPrefix("$") || token.allSatisfy({ $0 == "." }) { continue }
            if results.contains(token) { result = token; continue }
            guard let move = position.move(fromSAN: token) else { break }
            sans.append(position.san(move))
            moves.append(move)
            position = position.making(move)
            positions.append(position)
        }
        guard !moves.isEmpty else { return nil }
        return ParsedGame(headers: headers, start: start, moves: moves, sans: sans, positions: positions, result: result)
    }

    private static func stripAnnotations(_ text: String) -> String {
        var out = ""
        var braceDepth = 0
        var parenDepth = 0
        var lineComment = false
        for ch in text {
            if lineComment {
                if ch == "\n" { lineComment = false; out.append(" ") }
                continue
            }
            switch ch {
            case "{": braceDepth += 1
            case "}": braceDepth = max(0, braceDepth - 1); out.append(" ")
            case "(" where braceDepth == 0: parenDepth += 1
            case ")" where braceDepth == 0: parenDepth = max(0, parenDepth - 1); out.append(" ")
            case ";" where braceDepth == 0 && parenDepth == 0: lineComment = true
            default:
                if braceDepth == 0 && parenDepth == 0 { out.append(ch) }
            }
        }
        return out
    }

    /// Exports a list of moves as PGN movetext.
    static func movetext(start: Position, moves: [Move]) -> String {
        var p = start
        var parts: [String] = []
        for m in moves {
            if p.sideToMove == .white { parts.append("\(p.fullmoveNumber).") }
            parts.append(p.san(m))
            p = p.making(m)
        }
        return parts.joined(separator: " ")
    }
}
