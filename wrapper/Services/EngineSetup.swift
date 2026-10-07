import Foundation
import CryptoKit
import Observation

/// Stockfish 17 NNUE network files. Names are the first 12 hex digits of each file's SHA-256.
nonisolated enum StockfishNetwork {
    nonisolated struct File: Sendable {
        let name: String
        let sha256: String
        let size: Int64
        var resourceName: String { (name as NSString).deletingPathExtension }
    }

    /// Main network, downloaded once (too large to ship in the app bundle).
    static let big = File(name: "nn-1111cefa1111.nnue", sha256: "1111cefa11116b77161bd4b14dab4c50f26e5920c756f4861592be3dcd6de174", size: 74_874_478)
    /// Small network, bundled with the app.
    static let small = File(name: "nn-37f18f62d772.nnue", sha256: "37f18f62d772f3107e1d6aaca3898c130c3c86f2ab63e6555fbbca20635a899d", size: 3_519_630)

    static let mirrors: [String] = [
        "https://raw.githubusercontent.com/official-stockfish/networks/master/",
        "https://tests.stockfishchess.org/api/nn/",
    ]

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Stockfish", isDirectory: true)
    }

    static var downloadedBig: URL { directory.appendingPathComponent(big.name) }

    /// Size and SHA-256 must both match: Stockfish terminates on a network it cannot load.
    static func isValid(_ url: URL, _ file: File) -> Bool {
        let path = url.path(percentEncoded: false)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber, size.int64Value == file.size else { return false }
        return sha256(of: url) == file.sha256
    }

    static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try? handle.read(upToCount: 4_194_304), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Prepares on-device Stockfish: verifies the bundled network, downloads the main network once,
/// and starts the engine. The built-in engine covers analysis until this reports `.ready`.
@Observable
final class EngineSetup {
    enum Phase: Equatable {
        case preparing
        case downloading(Double)
        case starting
        case ready
        case unavailable(String)
    }

    private(set) var phase: Phase = .preparing
    private(set) var threads: Int = 0
    @ObservationIgnored private var task: Task<Void, Never>?

    var isReady: Bool { phase == .ready }

    var downloadedMegabytes: Int {
        guard case .downloading(let fraction) = phase else { return 0 }
        return Int((Double(StockfishNetwork.big.size) * fraction / 1_000_000).rounded())
    }

    var totalMegabytes: Int { Int((Double(StockfishNetwork.big.size) / 1_000_000).rounded()) }

    func prepare() {
        guard task == nil, phase != .ready else { return }
        task = Task {
            await run()
            task = nil
        }
    }

    private func run() async {
        phase = .preparing
        guard let small = Bundle.main.url(forResource: StockfishNetwork.small.resourceName, withExtension: "nnue") else {
            phase = .unavailable("The Stockfish network is missing from this build.")
            return
        }
        let big = StockfishNetwork.downloadedBig
        let (smallValid, bigValid) = await Task.detached(priority: .utility) {
            (StockfishNetwork.isValid(small, StockfishNetwork.small), StockfishNetwork.isValid(big, StockfishNetwork.big))
        }.value
        guard smallValid else {
            phase = .unavailable("The bundled Stockfish network is damaged.")
            return
        }
        if !bigValid {
            do {
                try await download(to: big)
            } catch {
                phase = .unavailable(Self.message(for: error))
                return
            }
        }
        phase = .starting
        if await StockfishBridge.shared.start(bigNetwork: big, smallNetwork: small) {
            threads = StockfishBridge.shared.threads
            phase = .ready
        } else {
            phase = .unavailable("Stockfish could not start. The built-in engine is in use.")
        }
    }

    private func download(to destination: URL) async throws {
        phase = .downloading(0)
        var lastError: Error = URLError(.cannotConnectToHost)
        for base in StockfishNetwork.mirrors {
            guard let url = URL(string: base + StockfishNetwork.big.name) else { continue }
            do {
                let temp = try await NetworkDownloader().download(from: url) { [weak self] fraction in
                    Task { @MainActor in
                        guard let self, case .downloading = self.phase else { return }
                        self.phase = .downloading(fraction)
                    }
                }
                let valid = await Task.detached(priority: .utility) { StockfishNetwork.isValid(temp, StockfishNetwork.big) }.value
                guard valid else {
                    try? FileManager.default.removeItem(at: temp)
                    lastError = SetupError.corrupted
                    continue
                }
                let manager = FileManager.default
                try manager.createDirectory(at: StockfishNetwork.directory, withIntermediateDirectories: true)
                try? manager.removeItem(at: destination)
                try manager.moveItem(at: temp, to: destination)
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                var stored = destination
                try? stored.setResourceValues(values)
                return
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private enum SetupError: Error { case corrupted }

    private static func message(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return "Connect to the internet to finish setting up Stockfish."
            case .timedOut, .cannotConnectToHost, .cannotFindHost:
                return "The Stockfish download could not be reached. Try again shortly."
            default:
                break
            }
        }
        if error is SetupError { return "The download did not verify. Try again." }
        return "Stockfish setup did not finish. Try again."
    }
}

/// Downloads one file with progress callbacks.
nonisolated final class NetworkDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var progress: (@Sendable (Double) -> Void)?
    private var lastPercent: Int = -1

    func download(from url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        lock.withLock { self.progress = progress }
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                lock.withLock { self.continuation = continuation }
                session.downloadTask(with: url).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : StockfishNetwork.big.size
        let fraction = min(1, Double(totalBytesWritten) / Double(max(1, total)))
        let percent = Int(fraction * 100)
        let report: (@Sendable (Double) -> Void)? = lock.withLock {
            guard percent != lastPercent else { return nil }
            lastPercent = percent
            return progress
        }
        report?(fraction)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            finish(.failure(URLError(.badServerResponse)))
            return
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".nnue")
        do {
            try FileManager.default.moveItem(at: location, to: temp)
            finish(.success(temp))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }

    private func finish(_ result: Result<URL, Error>) {
        let pending = lock.withLock {
            let c = continuation
            continuation = nil
            return c
        }
        pending?.resume(with: result)
    }
}
