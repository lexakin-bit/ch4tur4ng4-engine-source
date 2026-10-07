# CH4TUR4NG4 — engine source

This repository (https://github.com/lexakin-bit/ch4tur4ng4-engine-source) is the source offer for
the chess engine in the **CH4TUR4NG4** iPhone app.
It contains everything needed to rebuild the engine exactly as it ships in the app.

The app contains the **Stockfish 17** chess engine, Copyright (C) 2004–2024 The Stockfish
developers (see `stockfish/AUTHORS`). Stockfish is free software, licensed under the
**GNU General Public License v3.0** (see `COPYING`). It comes with NO WARRANTY.

Stockfish runs entirely on the device. No position is ever sent to a server.

## What ships in the app

| Component | Version / exact source | License |
|---|---|---|
| Stockfish | 17, `chesskit-app/Stockfish` @ `23f320bac6b554f6470d51f10b96613a7cd7b03d` | GPL v3 |
| Upstream Stockfish | `official-stockfish/Stockfish` tag `sf_17` | GPL v3 |
| ChessKitEngine (Swift ⇄ engine bridge) | `chesskit-app/chesskit-engine` tag `0.7.0` | MIT |
| Leela Chess Zero (compiled into ChessKitEngine, unused) | `chesskit-app/lc0` @ `a78b208cf19ce45cfc32ed57e651ae661dbcb5c3` | GPL v3 |
| Eigen (used by Lc0) | 3.4.0 | MPL 2.0 |
| NNUE networks | `nn-1111cefa1111.nnue` (downloaded on first launch), `nn-37f18f62d772.nnue` (bundled in app) from `official-stockfish/networks` | see that repository |

There is no WebAssembly build: the app is native iOS. Stockfish's C++ is compiled for arm64
by Xcode through Swift Package Manager, inside the app process.

## Repository layout

```
COPYING                         GNU GPL v3 (identical to Stockfish's Copying.txt)
stockfish/AUTHORS               Stockfish authors, unmodified
stockfish/sf_17-to-chesskit.patch
                                Every source change between Stockfish sf_17 and the tree
                                compiled into the app (main() renamed to _main() so the
                                engine can run inside an app process). CI workflow
                                deletions are omitted.
wrapper/Engine/                 The app's engine layer
  EngineTypes.swift             ChessEngine protocol, configs, analysis types
  StockfishEngine.swift         UCI bridge to Stockfish via ChessKitEngine
  NativeEngine.swift            Built-in fallback engine (used until Stockfish is ready)
  TacticDetector.swift          Tactic labelling used by engine results
wrapper/Services/EngineSetup.swift
                                Network verification (SHA-256), one-time download, engine start
wrapper/Models/                 Board, move and FEN types the engine layer depends on
scripts/fetch-sources.sh        Downloads the exact upstream sources and verifies them
scripts/build-ios.sh            Builds Stockfish + ChessKitEngine for iOS with Xcode
licenses/                       MIT (ChessKitEngine), MPL 2.0 (Eigen), Apache 2.0 (piece art)
```

## Rebuilding the engine

Requirements: macOS with Xcode 16 or later.

```sh
./scripts/fetch-sources.sh      # downloads sources into ./build/src and verifies SHA-256
./scripts/build-ios.sh          # compiles ChessKitEngine (with Stockfish) for iOS arm64
```

To use a modified Stockfish: edit `build/src/chesskit-engine/Sources/ChessKitEngineCore/Engines/Stockfish`,
rebuild, then point the app's Swift package dependency at your local `build/src/chesskit-engine`.

## Engine settings used by the app

`Threads` = min(4, CPU cores − 2) · `Hash` = 64 MB · `MultiPV` 1–4 ·
`EvalFile` / `EvalFileSmall` set to absolute paths of the verified networks.
Searches use `go depth N movetime M`, with optional `searchmoves` when scoring the player's own move.

## Written offer

If you cannot use the links above, contact the developer through the App Store listing's
support link. They will provide the complete corresponding source on request, for at least
three years after the last app release, at no charge beyond the cost of delivery.
