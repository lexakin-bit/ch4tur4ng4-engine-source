#!/usr/bin/env bash
# Downloads the exact engine sources compiled into CH4TUR4NG4 and verifies them.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/build/src"
mkdir -p "$SRC"
cd "$SRC"

STOCKFISH_COMMIT="23f320bac6b554f6470d51f10b96613a7cd7b03d"
LC0_COMMIT="a78b208cf19ce45cfc32ed57e651ae661dbcb5c3"
CHESSKIT_ENGINE_TAG="0.7.0"

fetch() { # name url sha256
  local name="$1" url="$2" sum="$3"
  echo "Downloading $name"
  curl -fL --retry 3 -o "$name.tar.gz" "$url"
  echo "$sum  $name.tar.gz" | shasum -a 256 -c -
}

fetch stockfish "https://codeload.github.com/chesskit-app/Stockfish/tar.gz/$STOCKFISH_COMMIT" \
  5a2acbb965d76236bd1a16d55ca4128faa0ae0b4b0b8744e5e2bc0644990cb20
fetch lc0 "https://codeload.github.com/chesskit-app/lc0/tar.gz/$LC0_COMMIT" \
  9ccc5f4177a8f50ba8b66e34985f781c447a4671c21b858692d0f67b05b123f5
fetch chesskit-engine "https://codeload.github.com/chesskit-app/chesskit-engine/tar.gz/refs/tags/$CHESSKIT_ENGINE_TAG" \
  b6355426c1750c6ec9052d4ad91413dbc3ed3339fe38fd397ff40284ff4b4e35

rm -rf chesskit-engine
mkdir chesskit-engine
tar xzf chesskit-engine.tar.gz -C chesskit-engine --strip-components=1

ENGINES="chesskit-engine/Sources/ChessKitEngineCore/Engines"
rm -rf "$ENGINES/Stockfish" "$ENGINES/lc0"
mkdir -p "$ENGINES/Stockfish" "$ENGINES/lc0"
tar xzf stockfish.tar.gz -C "$ENGINES/Stockfish" --strip-components=1
tar xzf lc0.tar.gz -C "$ENGINES/lc0" --strip-components=1

echo "Downloading NNUE networks"
NETS="$SRC/networks"
mkdir -p "$NETS"
for net in nn-1111cefa1111.nnue nn-37f18f62d772.nnue; do
  curl -fL --retry 3 -o "$NETS/$net" "https://raw.githubusercontent.com/official-stockfish/networks/master/$net"
done
( cd "$NETS"
  echo "1111cefa11116b77161bd4b14dab4c50f26e5920c756f4861592be3dcd6de174  nn-1111cefa1111.nnue" | shasum -a 256 -c -
  echo "37f18f62d772f3107e1d6aaca3898c130c3c86f2ab63e6555fbbca20635a899d  nn-37f18f62d772.nnue" | shasum -a 256 -c - )

echo "Sources ready in $SRC"
