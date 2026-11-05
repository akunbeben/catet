#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
command -v nix >/dev/null || { echo 'Install Nix first: https://determinate.systems/nix/'; exit 1; }
command -v codex >/dev/null || { echo 'Install Codex CLI and run: codex login'; exit 1; }
mkdir -p .runtime
# Nix appends "-bin" to this out-link for the selected bin output.
nix build --out-link "$ROOT/.runtime/ffmpeg" 'path:.#ffmpeg^bin'
xcrun swift - "$ROOT" "$(command -v codex)" <<'SWIFT'
import Foundation
let args = CommandLine.arguments
let root = URL(fileURLWithPath: args[1])
func executable(_ path: String) -> String {
    root.appendingPathComponent(path).resolvingSymlinksInPath().path
}
let config = [
    "ffmpeg": executable(".runtime/ffmpeg-bin/bin/ffmpeg"),
    "codex": args[2]
]
for key in ["ffmpeg", "codex"] {
    guard FileManager.default.isExecutableFile(atPath: config[key]!) else {
        fatalError("Missing executable: \(config[key]!)")
    }
}
let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
try data.write(to: root.appendingPathComponent("runtime.json"), options: .atomic)
SWIFT
bash "$ROOT/install.sh"
echo "Ready. Open Catet from Applications."
