import Foundation
import ChessKitEngineCore
import os

/// Stockfish 17 (NNUE) running on the device. Conforms to `ChessEngine`, so every coaching
/// feature works unchanged. Positions Stockfish cannot accept safely fall back to the built-in engine.
nonisolated struct StockfishEngine: ChessEngine {
    /// A Stockfish-safe copy of the position: impossible castling/en-passant rights removed,
    /// illegal setups rejected (Stockfish assumes a legal position).
    static func prepared(_ fen: String) -> Position? {
        guard let position = Position(fen: fen) else { return nil }
        let clean = position.sanitizedCastling()
        return clean.validationIssues.isEmpty ? clean : nil
    }

    func analyze(fen: String, config: EngineConfig) -> AsyncStream<EngineAnalysis> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                guard let position = Self.prepared(fen) else {
                    for await analysis in NativeEngine().analyze(fen: fen, config: config) { continuation.yield(analysis) }
                    continuation.finish()
                    return
                }
                if position.legalMoves().isEmpty {
                    let score = position.isCheck ? -ScoreMath.mate : 0
                    continuation.yield(EngineAnalysis(fen: fen, sideToMove: position.sideToMove, depth: 0, nodes: 0, lines: [], rootScore: score, isFinal: true, engine: .stockfish))
                    continuation.finish()
                    return
                }
                let final = await StockfishBridge.shared.search(position: position, config: config, searchMoves: []) { update in
                    continuation.yield(update)
                }
                if let final {
                    continuation.yield(final)
                } else if !Task.isCancelled {
                    for await analysis in NativeEngine().analyze(fen: fen, config: config) { continuation.yield(analysis) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func scoreMove(fen: String, move: Move, config: EngineConfig) async -> EngineLine? {
        guard let position = Self.prepared(fen), position.legalMoves().contains(move) else {
            return await NativeEngine().scoreMove(fen: fen, move: move, config: config)
        }
        let result = await StockfishBridge.shared.search(position: position, config: config, searchMoves: [move]) { _ in }
        if let line = result?.best, line.move.from == move.from, line.move.to == move.to { return line }
        guard !Task.isCancelled else { return nil }
        return await NativeEngine().scoreMove(fen: fen, move: move, config: config)
    }
}

/// The app's engine: Stockfish once its network is ready, the built-in engine until then.
nonisolated struct AppEngine: ChessEngine {
    private var active: any ChessEngine {
        StockfishBridge.shared.isReady ? StockfishEngine() : NativeEngine()
    }

    var kind: EngineKind { StockfishBridge.shared.isReady ? .stockfish : .builtIn }

    func analyze(fen: String, config: EngineConfig) -> AsyncStream<EngineAnalysis> {
        active.analyze(fen: fen, config: config)
    }

    func scoreMove(fen: String, move: Move, config: EngineConfig) async -> EngineLine? {
        await active.scoreMove(fen: fen, move: move, config: config)
    }
}

/// Owns the single in-process Stockfish instance. Stockfish talks UCI over redirected
/// stdin/stdout, so only one instance may ever exist. Output is parsed strictly in order on a
/// serial queue; searches are serialized and separated by an `isready` barrier so lines from a
/// previous search can never leak into the next one.
nonisolated final class StockfishBridge: @unchecked Sendable {
    static let shared = StockfishBridge()

    private nonisolated enum State { case idle, starting, ready, failed }

    private nonisolated struct Waiter {
        let token: String
        let continuation: CheckedContinuation<Bool, Never>
    }

    private nonisolated final class Job: @unchecked Sendable {
        let position: Position
        let expectedLines: Int
        let onUpdate: @Sendable (EngineAnalysis) -> Void
        var lines: [Int: EngineLine] = [:]
        var depth: Int = 0
        var nodes: Int = 0
        var completion: CheckedContinuation<EngineAnalysis?, Never>?

        init(position: Position, expectedLines: Int, onUpdate: @escaping @Sendable (EngineAnalysis) -> Void) {
            self.position = position
            self.expectedLines = expectedLines
            self.onUpdate = onUpdate
        }
    }

    private let lock = NSLock()
    private let parseQueue = DispatchQueue(label: "app.ch4tur4ng4.stockfish.output", qos: .userInitiated)
    private let gate = SearchGate()
    private let logger = Logger(subsystem: "app.ch4tur4ng4", category: "Stockfish")
    private var messenger: EngineMessenger?
    private var state: State = .idle
    private var waiters: [UUID: Waiter] = [:]
    private var job: Job?
    private var threadCount: Int = 0

    var isReady: Bool { lock.withLock { state == .ready } }
    var threads: Int { lock.withLock { threadCount } }

    // MARK: Lifecycle

    /// Starts Stockfish with verified network files. Safe to call again after a failure.
    func start(bigNetwork: URL, smallNetwork: URL) async -> Bool {
        let shouldStart: Bool = lock.withLock {
            guard state == .idle || state == .failed else { return false }
            state = .starting
            return true
        }
        guard shouldStart else { return isReady }

        if lock.withLock({ messenger == nil }) {
            let engineMessenger = EngineMessenger(engineType: .stockfish)
            engineMessenger.responseHandler = { [self] text in
                parseQueue.async { self.handle(text) }
            }
            lock.withLock { messenger = engineMessenger }
            engineMessenger.start()
        }

        guard await request("uci", awaiting: "uciok", timeout: 15) else { return fail("Stockfish did not answer uci") }
        let threads = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount - 2))
        send("setoption name Threads value \(threads)")
        send("setoption name Hash value 64")
        send("setoption name EvalFile value \(bigNetwork.path(percentEncoded: false))")
        send("setoption name EvalFileSmall value \(smallNetwork.path(percentEncoded: false))")
        guard await request("isready", awaiting: "readyok", timeout: 30) else { return fail("Stockfish did not become ready") }

        lock.withLock {
            threadCount = threads
            state = .ready
        }
        logger.info("Stockfish ready with \(threads) threads")
        return true
    }

    private func fail(_ reason: String) -> Bool {
        lock.withLock { state = .failed }
        logger.error("\(reason, privacy: .public)")
        return false
    }

    // MARK: Search

    /// Runs one search. `onUpdate` receives each completed depth; the return value is final.
    func search(position: Position, config: EngineConfig, searchMoves: [Move], onUpdate: @escaping @Sendable (EngineAnalysis) -> Void) async -> EngineAnalysis? {
        guard isReady else { return nil }
        await gate.acquire()
        let result = await runSearch(position: position, config: config, searchMoves: searchMoves, onUpdate: onUpdate)
        await gate.release()
        return result
    }

    private func runSearch(position: Position, config: EngineConfig, searchMoves: [Move], onUpdate: @escaping @Sendable (EngineAnalysis) -> Void) async -> EngineAnalysis? {
        guard !Task.isCancelled else { return nil }
        let candidates = searchMoves.isEmpty ? position.legalMoves().count : searchMoves.count
        let lineCount = max(1, min(config.multiPV, candidates))

        // Barrier: setoption waits for any running search to finish, readyok confirms it.
        send("stop")
        send("setoption name MultiPV value \(lineCount)")
        guard await request("isready", awaiting: "readyok", timeout: 8) else { return nil }
        guard !Task.isCancelled else { return nil }

        let job = Job(position: position, expectedLines: lineCount, onUpdate: onUpdate)
        var go = "go depth \(config.stockfishDepth) movetime \(Int(config.stockfishTime * 1000))"
        if !searchMoves.isEmpty { go += " searchmoves " + searchMoves.map(\.uci).joined(separator: " ") }
        let fen = position.fen
        let watchdog = config.stockfishTime + 4

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<EngineAnalysis?, Never>) in
                lock.withLock {
                    job.completion = continuation
                    self.job = job
                }
                send("position fen \(fen)")
                send(go)
                if Task.isCancelled { send("stop") }
                scheduleWatchdog(for: job, after: watchdog)
            }
        } onCancel: {
            if self.isCurrent(job) { self.send("stop") }
        }
    }

    private func isCurrent(_ candidate: Job) -> Bool {
        lock.withLock { job === candidate }
    }

    /// Guards against a lost `bestmove`: stop the search, then finish with what we have.
    private func scheduleWatchdog(for watched: Job, after seconds: Double) {
        Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, self.isCurrent(watched) else { return }
            self.send("stop")
            try? await Task.sleep(for: .seconds(2))
            guard self.isCurrent(watched) else { return }
            self.logger.error("Stockfish search timed out; using the last completed depth")
            self.complete(watched, bestmove: nil)
        }
    }

    // MARK: Output

    private func handle(_ raw: String) {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        if line == "uciok" || line == "readyok" {
            resolve(token: line)
        } else if line.hasPrefix("bestmove") {
            guard let current = lock.withLock({ job }) else { return }
            let parts = line.split(separator: " ")
            complete(current, bestmove: parts.count > 1 ? Move(uci: String(parts[1])) : nil)
        } else if line.hasPrefix("info ") {
            handleInfo(line)
        }
    }

    private func handleInfo(_ line: String) {
        let tokens = line.split(separator: " ").map(String.init)
        guard let pvIndex = tokens.firstIndex(of: "pv"), pvIndex + 1 < tokens.count,
              let scoreIndex = tokens.firstIndex(of: "score"), scoreIndex + 2 < tokens.count,
              !tokens.contains("lowerbound"), !tokens.contains("upperbound"),
              let value = Int(tokens[scoreIndex + 2]) else { return }

        func number(after key: String) -> Int? {
            guard let i = tokens.firstIndex(of: key), i + 1 < tokens.count else { return nil }
            return Int(tokens[i + 1])
        }

        let score: Int
        switch tokens[scoreIndex + 1] {
        case "cp":
            score = value
        case "mate":
            if value > 0 {
                score = ScoreMath.mate - (2 * value - 1)
            } else {
                score = -(ScoreMath.mate - 2 * abs(value))
            }
        default:
            return
        }
        let depth = number(after: "depth") ?? 0
        let index = number(after: "multipv") ?? 1
        let nodes = number(after: "nodes") ?? 0

        let update: (EngineAnalysis, @Sendable (EngineAnalysis) -> Void)? = lock.withLock {
            guard let job else { return nil }
            let pv = Self.moves(tokens[(pvIndex + 1)...], from: job.position)
            guard let first = pv.first else { return nil }
            job.depth = max(job.depth, depth)
            job.nodes = max(job.nodes, nodes)
            job.lines[index] = EngineLine(move: first, score: score, isExact: true, pv: pv)
            guard index >= job.expectedLines, let analysis = Self.snapshot(job, isFinal: false) else { return nil }
            return (analysis, job.onUpdate)
        }
        if let update { update.1(update.0) }
    }

    private func complete(_ finished: Job, bestmove: Move?) {
        let outcome: (CheckedContinuation<EngineAnalysis?, Never>, EngineAnalysis?)? = lock.withLock {
            guard job === finished, let continuation = finished.completion else { return nil }
            finished.completion = nil
            job = nil
            if finished.lines.isEmpty, let bestmove, finished.position.legalMoves().contains(bestmove) {
                finished.lines[1] = EngineLine(move: bestmove, score: 0, isExact: false, pv: [bestmove])
            }
            return (continuation, Self.snapshot(finished, isFinal: true))
        }
        outcome?.0.resume(returning: outcome?.1)
    }

    private static func snapshot(_ job: Job, isFinal: Bool) -> EngineAnalysis? {
        let ordered = job.lines.sorted { a, b in
            a.value.score != b.value.score ? a.value.score > b.value.score : a.key < b.key
        }.map(\.value)
        guard let best = ordered.first else { return nil }
        return EngineAnalysis(fen: job.position.fen, sideToMove: job.position.sideToMove, depth: job.depth, nodes: job.nodes,
                              lines: ordered, rootScore: best.score, isFinal: isFinal, engine: .stockfish)
    }

    /// Converts a UCI principal variation, stopping at the first move that does not fit the position.
    private static func moves(_ ucis: ArraySlice<String>, from start: Position) -> [Move] {
        var position = start
        var out: [Move] = []
        for (i, text) in ucis.enumerated() {
            guard let move = Move(uci: text) else { break }
            if i == 0 {
                guard position.legalMoves().contains(move) else { break }
            } else {
                guard position.isOwn(move.from, position.sideToMove), !position.isOwn(move.to, position.sideToMove) else { break }
            }
            out.append(move)
            position = position.making(move)
        }
        return out
    }

    // MARK: Commands

    private func send(_ command: String) {
        let current = lock.withLock { messenger }
        current?.sendCommand(command)
    }

    private func request(_ command: String, awaiting token: String, timeout: Double) async -> Bool {
        let id = UUID()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            lock.withLock { waiters[id] = Waiter(token: token, continuation: continuation) }
            send(command)
            Task.detached(priority: .utility) { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.resolve(id: id, value: false)
            }
        }
    }

    private func resolve(token: String) {
        let matched: [Waiter] = lock.withLock {
            let ids = waiters.filter { $0.value.token == token }.map(\.key)
            return ids.compactMap { waiters.removeValue(forKey: $0) }
        }
        matched.forEach { $0.continuation.resume(returning: true) }
    }

    private func resolve(id: UUID, value: Bool) {
        let waiter = lock.withLock { waiters.removeValue(forKey: id) }
        waiter?.continuation.resume(returning: value)
    }
}

/// FIFO async mutex so only one search talks to Stockfish at a time.
private actor SearchGate {
    private var isBusy = false
    private var queue: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isBusy else {
            isBusy = true
            return
        }
        await withCheckedContinuation { queue.append($0) }
    }

    func release() {
        if queue.isEmpty {
            isBusy = false
        } else {
            queue.removeFirst().resume()
        }
    }
}
