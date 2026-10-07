import Foundation

/// Built-in alpha-beta engine. Runs off the main actor and streams iterative-deepening results.
/// Conforms to `ChessEngine`, so a UCI Stockfish adapter can replace it without UI changes.
nonisolated struct NativeEngine: ChessEngine {
    func analyze(fen: String, config: EngineConfig) -> AsyncStream<EngineAnalysis> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                guard let position = Position(fen: fen) else {
                    continuation.finish()
                    return
                }
                let searcher = Searcher(config: config)
                searcher.run(position, fen: fen) { continuation.yield($0) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

nonisolated final class Searcher {
    private let config: EngineConfig
    private var nodes = 0
    private var stopped = false
    private var currentDepth = 1
    private let startTime = DispatchTime.now().uptimeNanoseconds
    private var killers = [[Move]](repeating: [], count: 96)
    private var history = [Int](repeating: 0, count: 4096)
    private let rootMargin = 320

    init(config: EngineConfig) {
        self.config = config
    }

    private var elapsed: Double {
        Double(DispatchTime.now().uptimeNanoseconds - startTime) / 1_000_000_000
    }

    private func checkTime() {
        guard currentDepth > 1 else { return }
        if nodes & 1023 == 0 && (Task.isCancelled || elapsed > config.timeLimit) {
            stopped = true
        }
    }

    func run(_ position: Position, fen: String, emit: (EngineAnalysis) -> Void) {
        let legal = position.legalMoves()
        guard !legal.isEmpty else {
            let score = position.isCheck ? -ScoreMath.mate : 0
            emit(EngineAnalysis(fen: fen, sideToMove: position.sideToMove, depth: 0, nodes: 0, lines: [], rootScore: score, isFinal: true))
            return
        }
        var ordered = legal.sorted { orderScore($0, position, ply: 0) > orderScore($1, position, ply: 0) }
        var last: EngineAnalysis?

        for depth in 1...max(1, config.maxDepth) {
            currentDepth = depth
            var results: [EngineLine] = []
            var best = -ScoreMath.infinity
            for move in ordered {
                let child = position.making(move)
                let floor = best == -ScoreMath.infinity ? -ScoreMath.infinity : best - rootMargin
                var pv: [Move] = []
                let score = -negamax(child, depth: depth - 1, alpha: -ScoreMath.infinity, beta: -floor, ply: 1, pv: &pv)
                if stopped { break }
                let exact = floor == -ScoreMath.infinity || score > floor
                results.append(EngineLine(move: move, score: score, isExact: exact, pv: [move] + pv))
                best = max(best, score)
            }
            if stopped && depth > 1 { break }
            results.sort { $0.score > $1.score }
            ordered = results.map(\.move)
            let analysis = EngineAnalysis(fen: fen, sideToMove: position.sideToMove, depth: depth, nodes: nodes, lines: results, rootScore: results.first?.score ?? 0, isFinal: false)
            last = analysis
            emit(analysis)
            if let top = results.first, ScoreMath.isMate(top.score), ScoreMath.mate - abs(top.score) <= depth { break }
            if legal.count == 1 && depth >= 3 { break }
            if Task.isCancelled || elapsed > config.timeLimit * 0.55 { break }
        }
        if let last { emit(last.finalized()) }
    }

    // MARK: Search

    private func negamax(_ pos: Position, depth: Int, alpha: Int, beta: Int, ply: Int, pv: inout [Move]) -> Int {
        nodes += 1
        checkTime()
        if stopped { return 0 }
        if pos.halfmoveClock >= 100 || pos.isInsufficientMaterial { return 0 }

        let us = pos.sideToMove
        let inCheck = pos.inCheck(us)
        var depth = depth
        if inCheck && ply < currentDepth * 2 + 4 { depth += 1 }
        if depth <= 0 { return quiesce(pos, alpha: alpha, beta: beta, ply: ply, qdepth: 0) }

        var alpha = alpha
        var best = -ScoreMath.infinity
        var legalCount = 0
        let moves = pos.pseudoLegalMoves().sorted { orderScore($0, pos, ply: ply) > orderScore($1, pos, ply: ply) }

        for move in moves {
            let child = pos.making(move)
            if child.inCheck(us) { continue }
            legalCount += 1
            let quiet = !pos.isCapture(move) && move.promotion == nil
            var childPV: [Move] = []
            var score: Int
            if legalCount > 4 && depth >= 3 && quiet && !inCheck && !child.inCheck(child.sideToMove) {
                score = -negamax(child, depth: depth - 2, alpha: -alpha - 1, beta: -alpha, ply: ply + 1, pv: &childPV)
                if score > alpha && !stopped {
                    childPV = []
                    score = -negamax(child, depth: depth - 1, alpha: -beta, beta: -alpha, ply: ply + 1, pv: &childPV)
                }
            } else {
                score = -negamax(child, depth: depth - 1, alpha: -beta, beta: -alpha, ply: ply + 1, pv: &childPV)
            }
            if stopped { return 0 }
            if score > best {
                best = score
                if score > alpha {
                    alpha = score
                    pv = [move] + childPV
                    if score >= beta {
                        if quiet {
                            if ply < killers.count, !killers[ply].contains(move) {
                                killers[ply].insert(move, at: 0)
                                if killers[ply].count > 2 { killers[ply].removeLast() }
                            }
                            history[move.from * 64 + move.to] += depth * depth
                        }
                        break
                    }
                }
            }
        }
        if legalCount == 0 { return inCheck ? -(ScoreMath.mate - ply) : 0 }
        return best
    }

    private func quiesce(_ pos: Position, alpha: Int, beta: Int, ply: Int, qdepth: Int) -> Int {
        nodes += 1
        checkTime()
        if stopped { return 0 }
        let stand = Evaluator.evaluate(pos)
        if qdepth >= 6 || stand >= beta { return stand }
        var alpha = max(alpha, stand)
        let us = pos.sideToMove
        let captures = pos.pseudoLegalMoves(capturesOnly: true).sorted { orderScore($0, pos, ply: ply) > orderScore($1, pos, ply: ply) }
        for move in captures {
            if move.promotion == nil, let victim = pos.capturedPiece(move), stand + victim.kind.centipawns + 200 < alpha { continue }
            let child = pos.making(move)
            if child.inCheck(us) { continue }
            let score = -quiesce(child, alpha: -beta, beta: -alpha, ply: ply + 1, qdepth: qdepth + 1)
            if stopped { return 0 }
            if score >= beta { return score }
            alpha = max(alpha, score)
        }
        return alpha
    }

    private func orderScore(_ m: Move, _ pos: Position, ply: Int) -> Int {
        var s = 0
        if let victim = pos.capturedPiece(m) {
            let attacker = pos[m.from]?.kind.centipawns ?? 100
            s += 100_000 + victim.kind.centipawns * 10 - attacker / 10
        }
        if let promo = m.promotion { s += 90_000 + promo.centipawns }
        if ply < killers.count, killers[ply].contains(m) { s += 50_000 }
        s += min(history[m.from * 64 + m.to], 40_000)
        return s
    }
}

/// Static evaluation: material, piece-square tables, pawn structure, rook files, king shelter.
nonisolated enum Evaluator {
    // Tables are written from White's view with rank 8 first.
    private static let pawnT: [Int] = [
        0, 0, 0, 0, 0, 0, 0, 0,
        50, 50, 50, 50, 50, 50, 50, 50,
        10, 10, 20, 30, 30, 20, 10, 10,
        5, 5, 10, 25, 25, 10, 5, 5,
        0, 0, 0, 20, 20, 0, 0, 0,
        5, -5, -10, 0, 0, -10, -5, 5,
        5, 10, 10, -20, -20, 10, 10, 5,
        0, 0, 0, 0, 0, 0, 0, 0,
    ]
    private static let knightT: [Int] = [
        -50, -40, -30, -30, -30, -30, -40, -50,
        -40, -20, 0, 0, 0, 0, -20, -40,
        -30, 0, 10, 15, 15, 10, 0, -30,
        -30, 5, 15, 20, 20, 15, 5, -30,
        -30, 0, 15, 20, 20, 15, 0, -30,
        -30, 5, 10, 15, 15, 10, 5, -30,
        -40, -20, 0, 5, 5, 0, -20, -40,
        -50, -40, -30, -30, -30, -30, -40, -50,
    ]
    private static let bishopT: [Int] = [
        -20, -10, -10, -10, -10, -10, -10, -20,
        -10, 0, 0, 0, 0, 0, 0, -10,
        -10, 0, 5, 10, 10, 5, 0, -10,
        -10, 5, 5, 10, 10, 5, 5, -10,
        -10, 0, 10, 10, 10, 10, 0, -10,
        -10, 10, 10, 10, 10, 10, 10, -10,
        -10, 5, 0, 0, 0, 0, 5, -10,
        -20, -10, -10, -10, -10, -10, -10, -20,
    ]
    private static let rookT: [Int] = [
        0, 0, 0, 0, 0, 0, 0, 0,
        5, 10, 10, 10, 10, 10, 10, 5,
        -5, 0, 0, 0, 0, 0, 0, -5,
        -5, 0, 0, 0, 0, 0, 0, -5,
        -5, 0, 0, 0, 0, 0, 0, -5,
        -5, 0, 0, 0, 0, 0, 0, -5,
        -5, 0, 0, 0, 0, 0, 0, -5,
        0, 0, 0, 5, 5, 0, 0, 0,
    ]
    private static let queenT: [Int] = [
        -20, -10, -10, -5, -5, -10, -10, -20,
        -10, 0, 0, 0, 0, 0, 0, -10,
        -10, 0, 5, 5, 5, 5, 0, -10,
        -5, 0, 5, 5, 5, 5, 0, -5,
        0, 0, 5, 5, 5, 5, 0, -5,
        -10, 5, 5, 5, 5, 5, 0, -10,
        -10, 0, 5, 0, 0, 0, 0, -10,
        -20, -10, -10, -5, -5, -10, -10, -20,
    ]
    private static let kingMG: [Int] = [
        -30, -40, -40, -50, -50, -40, -40, -30,
        -30, -40, -40, -50, -50, -40, -40, -30,
        -30, -40, -40, -50, -50, -40, -40, -30,
        -30, -40, -40, -50, -50, -40, -40, -30,
        -20, -30, -30, -40, -40, -30, -30, -20,
        -10, -20, -20, -20, -20, -20, -20, -10,
        20, 20, 0, 0, 0, 0, 20, 20,
        20, 30, 10, 0, 0, 10, 30, 20,
    ]
    private static let kingEG: [Int] = [
        -50, -40, -30, -20, -20, -30, -40, -50,
        -30, -20, -10, 0, 0, -10, -20, -30,
        -30, -10, 20, 30, 30, 20, -10, -30,
        -30, -10, 30, 40, 40, 30, -10, -30,
        -30, -10, 30, 40, 40, 30, -10, -30,
        -30, -10, 20, 30, 30, 20, -10, -30,
        -30, -30, 0, 0, 0, 0, -30, -30,
        -50, -30, -30, -30, -30, -30, -30, -50,
    ]
    private static let passedBonus: [Int] = [0, 8, 14, 24, 40, 64, 100, 0]
    private static let phaseWeight: [Int] = [0, 0, 1, 1, 2, 4, 0]

    static func evaluate(_ pos: Position) -> Int {
        var mg = 0, eg = 0, phase = 0
        var pawnFiles: [[Int]] = [[Int](repeating: 0, count: 8), [Int](repeating: 0, count: 8)]
        var bishops = [0, 0]
        var kingSq = [4, 60]
        let b = pos.board

        for s in 0..<64 {
            let c = b[s]
            if c == 0 { continue }
            let kind = Int(abs(c))
            let white = c > 0
            let sign = white ? 1 : -1
            let f = s & 7, r = s >> 3
            let idx = white ? (7 - r) * 8 + f : r * 8 + f
            phase += phaseWeight[kind]
            switch kind {
            case 1:
                mg += sign * (100 + pawnT[idx]); eg += sign * (120 + pawnT[idx] / 2)
                pawnFiles[white ? 0 : 1][f] += 1
            case 2:
                mg += sign * (320 + knightT[idx]); eg += sign * (300 + knightT[idx])
            case 3:
                mg += sign * (330 + bishopT[idx]); eg += sign * (330 + bishopT[idx])
                bishops[white ? 0 : 1] += 1
            case 4:
                mg += sign * (500 + rookT[idx]); eg += sign * (520 + rookT[idx] / 2)
            case 5:
                mg += sign * (900 + queenT[idx]); eg += sign * (920 + queenT[idx])
            default:
                mg += sign * kingMG[idx]; eg += sign * kingEG[idx]
                kingSq[white ? 0 : 1] = s
            }
        }

        // Pawn structure and rook files.
        for s in 0..<64 {
            let c = b[s]
            let kind = Int(abs(c))
            guard kind == 1 || kind == 4 else { continue }
            let white = c > 0
            let side = white ? 0 : 1
            let sign = white ? 1 : -1
            let f = s & 7, r = s >> 3
            if kind == 4 {
                if pawnFiles[side][f] == 0 {
                    let bonus = pawnFiles[1 - side][f] == 0 ? 22 : 11
                    mg += sign * bonus; eg += sign * bonus / 2
                }
                continue
            }
            let left = f > 0 ? pawnFiles[side][f - 1] : 0
            let right = f < 7 ? pawnFiles[side][f + 1] : 0
            if left == 0 && right == 0 { mg -= sign * 12; eg -= sign * 16 }
            // Passed pawn: no enemy pawns ahead on this or adjacent files.
            var passed = true
            let enemy: Int8 = white ? -1 : 1
            var rr = white ? r + 1 : r - 1
            outer: while rr >= 0 && rr < 8 {
                for ff in max(0, f - 1)...min(7, f + 1) where b[rr * 8 + ff] == enemy {
                    passed = false
                    break outer
                }
                rr += white ? 1 : -1
            }
            if passed {
                let rel = white ? r : 7 - r
                mg += sign * passedBonus[rel] / 2
                eg += sign * passedBonus[rel]
            }
        }
        for side in 0..<2 {
            let sign = side == 0 ? 1 : -1
            for f in 0..<8 where pawnFiles[side][f] > 1 {
                mg -= sign * 12 * (pawnFiles[side][f] - 1)
                eg -= sign * 18 * (pawnFiles[side][f] - 1)
            }
            if bishops[side] >= 2 { mg += sign * 30; eg += sign * 45 }
            // King shelter in the middlegame.
            let k = kingSq[side]
            let kf = k & 7, kr = k >> 3
            let homeRank = side == 0 ? 0 : 7
            if kr == homeRank {
                let dir = side == 0 ? 1 : -1
                let ownPawn: Int8 = side == 0 ? 1 : -1
                var missing = 0
                for ff in max(0, kf - 1)...min(7, kf + 1) {
                    let a = (kr + dir) * 8 + ff
                    let bb = (kr + 2 * dir) * 8 + ff
                    if b[a] != ownPawn && (bb < 0 || bb > 63 || b[bb] != ownPawn) { missing += 1 }
                }
                mg -= sign * missing * 14
            } else if (kr == 1 && side == 0) || (kr == 6 && side == 1) {
                mg -= sign * 6
            } else {
                mg -= sign * 20
            }
        }

        let ph = min(24, phase)
        let score = (mg * ph + eg * (24 - ph)) / 24
        let tempo = 10
        return (pos.sideToMove == .white ? score : -score) + tempo
    }
}
