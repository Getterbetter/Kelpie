#!/bin/sh
# Places the pinned prebuilt libghostty xcframework into the vendored
# GhosttyTerminal package. Idempotent; verifies the SHA-256 before unpacking.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Packages/GhosttyTerminal/Artifacts"
URL="https://github.com/Lakr233/libghostty-spm/releases/download/upstream.1.3.1/GhosttyKit.xcframework.zip"
SHA="68156e6c8f384816a6fa9703a589f82cebd16702887aa4073ee06b7943ec4ecb"
if [ -d "$DEST/GhosttyKit.xcframework" ]; then echo "GhosttyKit.xcframework already present"; exit 0; fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
echo "Downloading GhosttyKit.xcframework.zip"; curl -fsSL -o "$TMP/g.zip" "$URL"
GOT="$(shasum -a 256 "$TMP/g.zip" | cut -d' ' -f1)"
[ "$GOT" = "$SHA" ] || { echo "checksum mismatch: $GOT" >&2; exit 1; }
mkdir -p "$DEST"; unzip -q "$TMP/g.zip" -d "$DEST"; echo "Installed to $DEST"
