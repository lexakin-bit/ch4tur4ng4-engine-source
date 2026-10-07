import Foundation

nonisolated enum TacticalMotif: String, Codable, Sendable, CaseIterable, Hashable {
    case checkmate, smotheredMate, backRankMate, fork, pin, skewer, discoveredCheck, discoveredAttack, mateThreat, winsMaterial, promotion

    var name: String {
        switch self {
        case .checkmate: "checkmate"
        case .smotheredMate: "smothered mate"
        case .backRankMate: "back-rank mate"
        case .fork: "fork"
        case .pin: "pin"
        case .skewer: "skewer"
        case .discoveredCheck: "discovered check"
        case .discoveredAttack: "discovered attack"
        case .mateThreat: "mate threat"
        case .winsMaterial: "loose piece"
        case .promotion: "promotion"
        }
    }

    var term: ChessTerm? {
        switch self {
        case .smotheredMate: .smotheredMate
        case .backRankMate: .backRank
        case .fork: .fork
        case .pin: .pin
        case .skewer: .skewer
        case .discoveredCheck: .discoveredCheck
        case .discoveredAttack: .discoveredAttack
        case .winsMaterial: .loosePiece
        case .checkmate, .mateThreat, .promotion: nil
        }
    }

    var isMate: Bool { self == .checkmate || self == .smotheredMate || self == .backRankMate }
}

nonisolated struct TacticFinding: Hashable, Sendable {
    let motif: TacticalMotif
    let squares: [Int]
    let arrows: [BoardArrow]
    /// Standard chess language.
    let text: String
    /// Plain English, no notation.
    let simple: String

    var annotations: BoardAnnotations { BoardAnnotations(squares: squares, arrows: arrows) }
}

/// Recognises the tactical idea behind a move.
nonisolated enum TacticDetector {
    static func detect(_ pos: Position, _ m: Move) -> [TacticFinding] {
        guard let mover = pos[m.from] else { return [] }
        let us = mover.color, them = us.opposite
        let next = pos.making(m)
        guard let moved = next[m.to] else { return [] }
        let san = pos.san(m)
        let to = Square.name(m.to)
        var out: [TacticFinding] = []

        if next.inCheck(them) && next.legalMoves().isEmpty {
            let k = next.kingSquare(them) ?? m.to
            let neighbours = Square.kingTargets[k]
            if moved.kind == .knight && neighbours.allSatisfy({ next.isOwn($0, them) }) {
                out.append(TacticFinding(motif: .smotheredMate, squares: [m.to, k], arrows: [BoardArrow(from: m.from, to: m.to, style: .suggestion)],
                                         text: "\(san) is a smothered mate: the king is boxed in by its own pieces and the knight gives check.",
                                         simple: "Your knight gives check, and the king is trapped by its own pieces. That is checkmate."))
            } else if (moved.kind == .rook || moved.kind == .queen) && Square.rank(k) == (them == .white ? 0 : 7) && Square.rank(m.to) == Square.rank(k) {
                out.append(TacticFinding(motif: .backRankMate, squares: [m.to, k] + neighbours.filter { next.isOwn($0, them) }, arrows: [BoardArrow(from: m.from, to: m.to, style: .suggestion)],
                                         text: "\(san) is a back-rank mate: the king's own pawns take away its escape squares.",
                                         simple: "The king is stuck behind its own pawns, so a check on the back row is checkmate."))
            } else {
                out.append(TacticFinding(motif: .checkmate, squares: [m.to, k], arrows: [BoardArrow(from: m.from, to: m.to, style: .suggestion)],
                                         text: "\(san) is checkmate.",
                                         simple: "This is checkmate: the king has no way out."))
            }
            return out
        }

        // Fork / double attack by the moved piece.
        if moved.kind != .king {
            let attacked = next.attackedSquares(from: m.to).filter { next.isEnemy($0, us) }
            let valuable = attacked.filter { t in
                guard let p = next[t] else { return false }
                if p.kind == .king { return true }
                if p.kind.points > moved.kind.points { return true }
                return p.kind != .pawn && next.attackers(of: t, by: them).isEmpty
            }
            let enemyAttackers = next.attackers(of: m.to, by: them)
            let defended = !next.attackers(of: m.to, by: us).isEmpty
            let safe = enemyAttackers.isEmpty || (defended && enemyAttackers.allSatisfy { a in
                let k = next[a]?.kind
                return k == .king || (k?.points ?? 0) >= moved.kind.points
            })
            if valuable.count >= 2 && safe {
                let ordered = valuable.sorted { (next[$0]?.kind.rawValue ?? 0) > (next[$1]?.kind.rawValue ?? 0) }
                let names = ordered.prefix(3).compactMap { next[$0]?.kind.name }
                out.append(TacticFinding(motif: .fork, squares: [m.to] + ordered, arrows: ordered.map { BoardArrow(from: m.to, to: $0, style: .suggestion) },
                                         text: "\(san) is a fork: the \(moved.kind.name) attacks the \(Grammar.list(names)) at the same time.",
                                         simple: "Your \(moved.kind.name) attacks the \(Grammar.list(names)) at once. Your opponent cannot save everything."))
            }
        }

        // Discovered attacks: lines opened by the piece that moved away.
        for s in 0..<64 where s != m.to {
            guard let p = next[s], p.color == us, p.kind.isSlider else { continue }
            let before = Set(pos.attackedSquares(from: s))
            for t in next.attackedSquares(from: s) where !before.contains(t) {
                guard let victim = next[t], victim.color == them, Square.between(s, t).contains(m.from) else { continue }
                if victim.kind == .king {
                    out.append(TacticFinding(motif: .discoveredCheck, squares: [s, t, m.to], arrows: [BoardArrow(from: s, to: t, style: .threat), BoardArrow(from: m.from, to: m.to, style: .suggestion)],
                                             text: "\(san) uncovers a discovered check from the \(p.kind.name) on \(Square.name(s)).",
                                             simple: "Moving this piece opens the line for your \(p.kind.name), which now gives check."))
                } else if victim.kind.points >= 5 || (victim.kind.points >= 3 && next.attackers(of: t, by: them).isEmpty) {
                    out.append(TacticFinding(motif: .discoveredAttack, squares: [s, t, m.to], arrows: [BoardArrow(from: s, to: t, style: .threat), BoardArrow(from: m.from, to: m.to, style: .suggestion)],
                                             text: "\(san) is a discovered attack: the \(p.kind.name) on \(Square.name(s)) now hits the \(victim.kind.name) on \(Square.name(t)).",
                                             simple: "When this piece moves, your \(p.kind.name) behind it suddenly attacks the \(victim.kind.name)."))
                }
            }
        }

        // Pins and skewers created by a long-range piece.
        if moved.kind.isSlider {
            let dirs: Range<Int> = moved.kind == .rook ? 0..<4 : (moved.kind == .bishop ? 4..<8 : 0..<8)
            for d in dirs {
                var first: Int?
                for t in Square.rays[m.to][d] {
                    guard let p = next[t] else { continue }
                    guard let f = first else {
                        if p.color == us { break }
                        first = t
                        continue
                    }
                    guard p.color == them, let fp = next[f] else { break }
                    if p.kind == .king && fp.kind != .king && fp.kind != .pawn {
                        out.append(TacticFinding(motif: .pin, squares: [m.to, f, t], arrows: [BoardArrow(from: m.to, to: t, style: .suggestion)],
                                                 text: "\(san) pins the \(fp.kind.name) on \(Square.name(f)) to the king — it cannot legally move.",
                                                 simple: "The \(fp.kind.name) is stuck: if it moved, its own king would be in check."))
                    } else if fp.kind == .king && p.kind.points >= 3 {
                        out.append(TacticFinding(motif: .skewer, squares: [m.to, f, t], arrows: [BoardArrow(from: m.to, to: t, style: .suggestion)],
                                                 text: "\(san) skewers the king: once it steps aside, the \(p.kind.name) on \(Square.name(t)) falls.",
                                                 simple: "You check the king, and when it moves away you win the \(p.kind.name) behind it."))
                    } else if fp.kind == .queen && (p.kind == .rook || (p.kind.points >= 3 && next.attackers(of: t, by: them).isEmpty)) {
                        out.append(TacticFinding(motif: .skewer, squares: [m.to, f, t], arrows: [BoardArrow(from: m.to, to: t, style: .suggestion)],
                                                 text: "\(san) skewers the queen against the \(p.kind.name) on \(Square.name(t)).",
                                                 simple: "You attack the queen; when it moves, the \(p.kind.name) behind it is exposed."))
                    } else if p.kind.points >= 5 && p.kind.points > fp.kind.points && fp.kind.points >= 3 {
                        out.append(TacticFinding(motif: .pin, squares: [m.to, f, t], arrows: [BoardArrow(from: m.to, to: t, style: .suggestion)],
                                                 text: "\(san) pins the \(fp.kind.name) on \(Square.name(f)) against the \(p.kind.name).",
                                                 simple: "The \(fp.kind.name) cannot move without exposing the \(p.kind.name) behind it."))
                    }
                    break
                }
            }
        }

        // Threat of mate next move.
        if !next.inCheck(them) {
            let probe = next.passingTurn()
            if let mate = probe.legalMoves().first(where: { probe.making($0).isCheckmate }) {
                out.append(TacticFinding(motif: .mateThreat, squares: [mate.to], arrows: [BoardArrow(from: mate.from, to: mate.to, style: .idea)],
                                         text: "\(san) threatens \(probe.san(mate)), checkmate.",
                                         simple: "This threatens checkmate on \(Square.name(mate.to)) next move."))
            }
        }

        // Winning material outright.
        if let victim = pos.capturedPiece(m) {
            let undefended = pos.attackers(of: m.to, by: them).isEmpty
            if (undefended && victim.kind != .pawn) || victim.kind.points > mover.kind.points {
                let text = undefended
                    ? "\(san) wins the undefended \(victim.kind.name) on \(to)."
                    : "\(san) wins material: the \(mover.kind.name) takes a \(victim.kind.name)."
                let simple = undefended
                    ? "Take the \(victim.kind.name) on \(to) — nothing defends it."
                    : "Your \(mover.kind.name) captures a more valuable \(victim.kind.name)."
                out.append(TacticFinding(motif: .winsMaterial, squares: [m.to], arrows: [BoardArrow(from: m.from, to: m.to, style: .suggestion)], text: text, simple: simple))
            }
        }

        if let promo = m.promotion {
            out.append(TacticFinding(motif: .promotion, squares: [m.to], arrows: [BoardArrow(from: m.from, to: m.to, style: .suggestion)],
                                     text: promo == .queen ? "\(san) promotes the pawn to a queen." : "\(san) is an underpromotion to a \(promo.name).",
                                     simple: "Your pawn reaches the last row and becomes a \(promo.name)."))
        }
        return out
    }
}
