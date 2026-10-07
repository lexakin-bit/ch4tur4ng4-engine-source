import Foundation

/// Score helpers. Engine scores are centipawns from the perspective of the side to move,
/// with mate encoded as ±(mate - plies).
nonisolated enum ScoreMath {
    static let mate = 100_000
    static let mateThreshold = 99_000
    static let infinity = 1_000_000

    static func isMate(_ s: Int) -> Bool { abs(s) >= mateThreshold }

    /// Full moves to mate; positive when the scoring side delivers mate.
    static func mateMoves(_ s: Int) -> Int {
        let plies = mate - abs(s)
        let moves = max(1, (plies + 1) / 2)
        return s > 0 ? moves : -moves
    }

    /// Expected score in percent (0–100) for the scoring side.
    static func winPercent(_ s: Int) -> Double {
        if isMate(s) { return s > 0 ? 100 : 0 }
        let cp = Double(max(-1500, min(1500, s)))
        return 50 + 50 * (2 / (1 + exp(-0.00368208 * cp)) - 1)
    }
}

/// Search configuration. `maxDepth`/`timeLimit` drive the built-in searcher; the Stockfish
/// fields drive the on-device Stockfish search (depth cap, think time, number of lines).
nonisolated struct EngineConfig: Sendable, Hashable {
    var maxDepth: Int
    var timeLimit: Double
    var stockfishDepth: Int
    var stockfishTime: Double
    var multiPV: Int

    static let quick = EngineConfig(maxDepth: 4, timeLimit: 0.5, stockfishDepth: 16, stockfishTime: 0.4, multiPV: 1)
    static let standard = EngineConfig(maxDepth: 6, timeLimit: 2.0, stockfishDepth: 22, stockfishTime: 1.5, multiPV: 3)
    static let deep = EngineConfig(maxDepth: 9, timeLimit: 4.5, stockfishDepth: 30, stockfishTime: 3.5, multiPV: 4)
    static let review = EngineConfig(maxDepth: 5, timeLimit: 0.3, stockfishDepth: 18, stockfishTime: 0.35, multiPV: 2)
    /// Scores one specific move (the user's choice) when it is not among the top lines.
    static let probe = EngineConfig(maxDepth: 6, timeLimit: 1.5, stockfishDepth: 26, stockfishTime: 1.6, multiPV: 1)
}

nonisolated enum EngineKind: String, Sendable, Hashable {
    case builtIn
    case stockfish

    var displayName: String {
        switch self {
        case .builtIn: "Built-in engine"
        case .stockfish: "Stockfish 17"
        }
    }
}

nonisolated struct EngineLine: Hashable, Sendable {
    let move: Move
    /// Side-to-move perspective.
    let score: Int
    /// False when the score is only an upper bound (the move is clearly worse than the best).
    let isExact: Bool
    let pv: [Move]
}

nonisolated struct EngineAnalysis: Sendable {
    let fen: String
    let sideToMove: PieceColor
    let depth: Int
    let nodes: Int
    /// Best first. The built-in engine scores every legal move; Stockfish returns its top lines.
    let lines: [EngineLine]
    /// Side-to-move score of the position (terminal score when there are no legal moves).
    let rootScore: Int
    let isFinal: Bool
    var engine: EngineKind = .builtIn

    var best: EngineLine? { lines.first }
    var whiteScore: Int { sideToMove == .white ? rootScore : -rootScore }

    func line(for move: Move) -> EngineLine? {
        lines.first { $0.move.from == move.from && $0.move.to == move.to && ($0.move.promotion ?? .queen) == (move.promotion ?? .queen) }
    }

    func finalized() -> EngineAnalysis {
        EngineAnalysis(fen: fen, sideToMove: sideToMove, depth: depth, nodes: nodes, lines: lines, rootScore: rootScore, isFinal: true, engine: engine)
    }

    /// Adds a separately scored line (e.g. the user's move) without changing the best line.
    func adding(_ extra: EngineLine?) -> EngineAnalysis {
        guard let extra, line(for: extra.move) == nil else { return self }
        return EngineAnalysis(fen: fen, sideToMove: sideToMove, depth: depth, nodes: nodes, lines: lines + [extra], rootScore: rootScore, isFinal: isFinal, engine: engine)
    }
}

nonisolated enum MoveQuality: String, Codable, Sendable, CaseIterable, Hashable {
    case best = "Best"
    case excellent = "Excellent"
    case strong = "Strong"
    case playable = "Playable"
    case inaccuracy = "Inaccuracy"
    case mistake = "Mistake"
    case seriousMistake = "Serious Mistake"

    static func classify(drop: Double, isBest: Bool) -> MoveQuality {
        if isBest { return .best }
        switch drop {
        case ..<1.0: return .best
        case ..<3.0: return .excellent
        case ..<6.0: return .strong
        case ..<10.0: return .playable
        case ..<16.0: return .inaccuracy
        case ..<26.0: return .mistake
        default: return .seriousMistake
        }
    }

    static func classify(bestScore: Int, moveScore: Int, isBest: Bool) -> MoveQuality {
        classify(drop: max(0, ScoreMath.winPercent(bestScore) - ScoreMath.winPercent(moveScore)), isBest: isBest)
    }

    var isGood: Bool { self == .best || self == .excellent || self == .strong }
    var isError: Bool { self == .inaccuracy || self == .mistake || self == .seriousMistake }

    var headline: String {
        switch self {
        case .best: "Exactly right."
        case .excellent: "Excellent."
        case .strong: "Strong idea."
        case .playable: "Reasonable."
        case .inaccuracy: "Look closer."
        case .mistake: "Look again."
        case .seriousMistake: "Pause here."
        }
    }

    /// Learning-estimate target used when this result feeds the skill model.
    var skillTarget: Double {
        switch self {
        case .best: 90
        case .excellent: 84
        case .strong: 74
        case .playable: 60
        case .inaccuracy: 45
        case .mistake: 30
        case .seriousMistake: 18
        }
    }

    var rank: Int { MoveQuality.allCases.firstIndex(of: self) ?? 0 }
}

nonisolated struct MoveAnalysis: Sendable {
    let move: Move
    let line: EngineLine?
    let best: EngineLine?
    let quality: MoveQuality
    let drop: Double
}

/// Clean engine abstraction. Any engine (the built-in searcher, Stockfish over UCI, a server)
/// only needs to stream analyses; every coaching method is derived from that stream.
nonisolated protocol ChessEngine: Sendable {
    /// Streams progressively deeper results. The last element has `isFinal == true`.
    func analyze(fen: String, config: EngineConfig) -> AsyncStream<EngineAnalysis>
    /// Scores one move from the side-to-move perspective, including the expected reply in `pv`.
    func scoreMove(fen: String, move: Move, config: EngineConfig) async -> EngineLine?
}

nonisolated extension ChessEngine {
    func scoreMove(fen: String, move: Move, config: EngineConfig) async -> EngineLine? {
        guard let position = Position(fen: fen), position.legalMoves().contains(move) else { return nil }
        let child = position.making(move)
        guard let reply = await evaluatePosition(fen: child.fen, config: config) else { return nil }
        return EngineLine(move: move, score: -reply.rootScore, isExact: true, pv: [move] + (reply.best?.pv ?? []))
    }

    func evaluatePosition(fen: String, config: EngineConfig = .standard) async -> EngineAnalysis? {
        var last: EngineAnalysis?
        for await analysis in analyze(fen: fen, config: config) { last = analysis }
        return last
    }

    func bestMoves(fen: String, count: Int = 3, config: EngineConfig = .standard) async -> [EngineLine] {
        guard let analysis = await evaluatePosition(fen: fen, config: config) else { return [] }
        return Array(analysis.lines.prefix(count))
    }

    func analyzeMove(fen: String, move: Move, config: EngineConfig = .standard) async -> MoveAnalysis? {
        guard let analysis = await evaluatePosition(fen: fen, config: config), let best = analysis.best else { return nil }
        var line = analysis.line(for: move)
        if line == nil { line = await scoreMove(fen: fen, move: move, config: .probe) }
        let moveScore = line?.score ?? -ScoreMath.mate
        let isBest = line?.move == best.move
        let drop = max(0, ScoreMath.winPercent(best.score) - ScoreMath.winPercent(moveScore))
        return MoveAnalysis(move: move, line: line, best: best, quality: MoveQuality.classify(drop: drop, isBest: isBest), drop: drop)
    }

    func principalVariation(fen: String, config: EngineConfig = .standard) async -> [Move] {
        await evaluatePosition(fen: fen, config: config)?.best?.pv ?? []
    }

    func detectTacticalMotifs(fen: String, move: Move) async -> [TacticalMotif] {
        guard let position = Position(fen: fen), position.legalMoves().contains(move) else { return [] }
        return TacticDetector.detect(position, move).map(\.motif)
    }

    /// Evaluates a sequence of positions (e.g. a whole game). Scores are from White's perspective.
    func evaluationHistory(fens: [String], config: EngineConfig = .review, progress: (@Sendable (Int) -> Void)? = nil) async -> [EngineAnalysis?] {
        var out: [EngineAnalysis?] = []
        for (i, fen) in fens.enumerated() {
            if Task.isCancelled { break }
            out.append(await evaluatePosition(fen: fen, config: config))
            progress?(i + 1)
        }
        return out
    }
}
