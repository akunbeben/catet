#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
command -v nix >/dev/null || { echo 'Install Nix first: https://determinate.systems/nix/'; exit 1; }
command -v codex >/dev/null || { echo 'Install Codex CLI and run: codex login'; exit 1; }
mkdir -p .runtime
nix build --out-link "$ROOT/.runtime/whisper" path:.#whisper
# Nix appends "-bin" to this out-link for the selected bin output.
nix build --out-link "$ROOT/.runtime/ffmpeg" 'path:.#ffmpeg^bin'
MODEL_DIR="$HOME/Library/Application Support/Catet/models"
MODEL="$MODEL_DIR/ggml-large-v3-turbo-q5_0.bin"
mkdir -p "$MODEL_DIR"
SHA=394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2
if ! test -f "$MODEL" || ! echo "$SHA  $MODEL" | shasum -a 256 -c - >/dev/null 2>&1; then
  echo 'Downloading local multilingual Whisper model (574 MB). No audio is uploaded.'
  curl --fail --location --retry 3 --continue-at - --output "$MODEL.part" 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin'
  echo "$SHA  $MODEL.part" | shasum -a 256 -c -
  mv "$MODEL.part" "$MODEL"
fi
VAD="$MODEL_DIR/ggml-silero-v6.2.0.bin"
VAD_SHA=2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987
if ! test -f "$VAD" || ! echo "$VAD_SHA  $VAD" | shasum -a 256 -c - >/dev/null 2>&1; then
  curl --fail --location --retry 3 --output "$VAD.part" 'https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin'
  echo "$VAD_SHA  $VAD.part" | shasum -a 256 -c -
  mv "$VAD.part" "$VAD"
fi
xcrun swift - "$ROOT" "$MODEL" "$(command -v codex)" "$VAD" <<'SWIFT'
import Foundation
let args = CommandLine.arguments
let root = URL(fileURLWithPath: args[1])
func executable(_ path: String) -> String {
    root.appendingPathComponent(path).resolvingSymlinksInPath().path
}
let config = [
    "whisper": executable(".runtime/whisper/bin/whisper-cli"),
    "ffmpeg": executable(".runtime/ffmpeg-bin/bin/ffmpeg"),
    "model": args[2],
    "codex": args[3],
    "vad": args[4]
]
for key in ["whisper", "ffmpeg", "codex"] {
    guard FileManager.default.isExecutableFile(atPath: config[key]!) else {
        fatalError("Missing executable: \(config[key]!)")
    }
}
let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
try data.write(to: root.appendingPathComponent("runtime.json"), options: .atomic)
SWIFT
bash "$ROOT/install.sh"
echo "Ready. Open Catet from Applications."
