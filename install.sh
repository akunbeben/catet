#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
test -f runtime.json || { echo 'Run ./setup.sh first.' >&2; exit 1; }
RUNTIME="$HOME/Library/Application Support/Catet/runtime"
mkdir -p "$RUNTIME"
# Keep dependencies alive independently of the source checkout.
nix build --out-link "$RUNTIME/whisper" path:.#whisper
nix build --out-link "$RUNTIME/ffmpeg" 'path:.#ffmpeg^bin'
bash "$ROOT/build.sh"
xcrun swift "$ROOT/scripts/install.swift" "$ROOT/build/Catet.app" "$ROOT/build/signing-identity"
open /Applications/Catet.app --args --permissions --request-system-audio
