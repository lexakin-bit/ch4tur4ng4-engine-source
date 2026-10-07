import Foundation

/// Exact versions and source locations of the open-source components compiled into the app.
/// Keep these pins in sync with the ChessKitEngine version in the Xcode project.
nonisolated enum OpenSource {
    static let stockfishVersion = "Stockfish 17"
    static let stockfishCopyright = "Copyright (C) 2004–2024 The Stockfish developers (see AUTHORS file)"
    /// Exact Stockfish tree compiled into this app (ChessKitEngine 0.7.0 submodule pin).
    static let stockfishCommit = "23f320bac6b554f6470d51f10b96613a7cd7b03d"

    static let stockfishSource = link("https://github.com/chesskit-app/Stockfish/tree/23f320bac6b554f6470d51f10b96613a7cd7b03d")
    static let stockfishUpstream = link("https://github.com/official-stockfish/Stockfish/tree/sf_17")
    /// Public repository with this app's engine wrapper source, build notes and Stockfish modifications.
    static let engineWrapperSource = link("https://github.com/lexakin-bit/ch4tur4ng4-engine-source")
    static let stockfishNetworks = link("https://github.com/official-stockfish/networks")

    static let chessKitEngineVersion = "0.7.0"
    static let chessKitEngineSource = link("https://github.com/chesskit-app/chesskit-engine/tree/0.7.0")
    static let lc0Source = link("https://github.com/chesskit-app/lc0/tree/a78b208cf19ce45cfc32ed57e651ae661dbcb5c3")
    static let eigenSource = link("https://gitlab.com/libeigen/eigen/-/tree/3.4.0")
    static let chessnutSource = link("https://github.com/LexLuengas/chessnut-pieces")

    private static func link(_ string: String) -> URL {
        URL(string: string) ?? URL(fileURLWithPath: "/")
    }
}

/// License and notice files bundled at the app bundle root.
nonisolated enum LicenseDocument: String, CaseIterable, Hashable, Sendable {
    case gpl3
    case stockfishAuthors
    case chessKitEngineMIT
    case mpl2
    case apache2

    var title: String {
        switch self {
        case .gpl3: "GNU GPL v3"
        case .stockfishAuthors: "Stockfish Authors"
        case .chessKitEngineMIT: "ChessKitEngine License"
        case .mpl2: "Mozilla Public License 2.0"
        case .apache2: "Apache License 2.0"
        }
    }

    var resourceName: String {
        switch self {
        case .gpl3: "LICENSE_GPL"
        case .stockfishAuthors: "Stockfish_AUTHORS"
        case .chessKitEngineMIT: "LICENSE_ChessKitEngine_MIT"
        case .mpl2: "LICENSE_MPL-2.0"
        case .apache2: "LICENSE_Apache-2.0"
        }
    }

    func load() -> String? {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "txt") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

/// Navigation targets inside Settings.
nonisolated enum SettingsRoute: Hashable, Sendable {
    case licenses
    case document(LicenseDocument)
}
