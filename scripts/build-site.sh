#!/bin/zsh
# Refreshes site/ with the current build artifacts (icon + downloads).
# Run scripts/build-app.sh first. Deploy site/ to /srv/static/finedisplay on the server.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

mkdir -p site/dl
ICONSET="$(mktemp -d)/AppIcon.iconset"
swift scripts/make-icon.swift "$ICONSET" >/dev/null
magick "$ICONSET/icon_256x256@2x.png" -strip -colors 255 -dither FloydSteinberg site/icon.png
rm -rf "$(dirname "$ICONSET")"

if [[ -d dist ]]; then
  cp dist/FineDisplay-*.zip dist/finedisplay-cli-*.zip site/dl/ 2>/dev/null || true
  cp dist/SHA256SUMS site/dl/SHA256SUMS 2>/dev/null || true
  # SHA256SUMS lists absolute paths; keep only basenames.
  sed -i '' -E 's#  .*/#  #' site/dl/SHA256SUMS
fi
ls -la site site/dl
