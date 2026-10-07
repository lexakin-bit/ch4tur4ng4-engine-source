#!/usr/bin/env bash
# Builds ChessKitEngine (which compiles Stockfish 17) for iOS with the same flags the app uses:
# NNUE_EMBEDDING_OFF (networks are loaded at runtime) and NO_PEXT, C++17 (gnu++17), arm64.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$ROOT/build/src/chesskit-engine"

if [ ! -f "$PKG/Package.swift" ]; then
  echo "Run scripts/fetch-sources.sh first." >&2
  exit 1
fi

cd "$PKG"
xcodebuild build \
  -scheme ChessKitEngine \
  -destination "generic/platform=iOS" \
  -configuration Release \
  -derivedDataPath "$ROOT/build/DerivedData" \
  CODE_SIGNING_ALLOWED=NO

echo "Built. Products are in $ROOT/build/DerivedData/Build/Products/Release-iphoneos"
