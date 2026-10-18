#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d /tmp/catet-tests.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
xcrun swiftc -parse-as-library -swift-version 5 -target arm64-apple-macosx14.0 -D CATET_ENGINE_TEST "$ROOT"/Sources/Shared/*.swift "$ROOT"/Sources/CatetEngine/*.swift "$ROOT"/tests/EngineTests.swift -o "$WORK/engine-tests"
"$WORK/engine-tests"
xcrun swiftc -parse-as-library -swift-version 5 -target arm64-apple-macosx14.0 "$ROOT"/Sources/Shared/*.swift "$ROOT"/Sources/Catet/MeetingStore.swift "$ROOT"/Sources/Catet/CaptureIssue.swift "$ROOT"/Sources/Catet/RecordingDialog.swift "$ROOT"/Sources/Catet/MeetingRecorder.swift "$ROOT"/Sources/Catet/WaveWriter.swift "$ROOT"/tests/AudioTests.swift -o "$WORK/audio-tests" -framework AppKit -framework AVFoundation -framework ScreenCaptureKit
"$WORK/audio-tests"
xcrun swiftc -parse-as-library -swift-version 5 -target arm64-apple-macosx14.0 "$ROOT"/Sources/Shared/*.swift "$ROOT"/tests/CodexAccountsTests.swift -o "$WORK/account-tests"
"$WORK/account-tests"
xcrun swiftc -parse-as-library -swift-version 5 -target arm64-apple-macosx14.0 "$ROOT"/Sources/Catet/LiveTranscriptionSupport.swift "$ROOT"/tests/LiveTranscriptionTests.swift -o "$WORK/live-transcription-tests" -framework AVFoundation
"$WORK/live-transcription-tests"
xcrun swiftc -parse-as-library -swift-version 5 -target arm64-apple-macosx14.0 "$ROOT"/Sources/Shared/MeetingHooks.swift "$ROOT"/tests/HookTests.swift -o "$WORK/hook-tests"
"$WORK/hook-tests"
xcrun swiftc -parse-as-library -swift-version 5 -target arm64-apple-macosx14.0 "$ROOT"/Sources/Shared/*.swift "$ROOT"/Sources/CatetEngine/*.swift -o "$WORK/CatetEngine"
cp "$ROOT/runtime.json" "$WORK/runtime.json"
xcrun swiftc -parse-as-library -swift-version 5 -target arm64-apple-macosx14.0 "$ROOT"/tests/AudioArchiveTests.swift -o "$WORK/audio-archive-tests"
FFMPEG="$(/usr/bin/plutil -extract ffmpeg raw -o - "$WORK/runtime.json")"
"$WORK/audio-archive-tests" "$WORK/CatetEngine" "$FFMPEG"
xcrun swiftc -parse-as-library -swift-version 5 -target arm64-apple-macosx14.0 "$ROOT"/Sources/Shared/*.swift "$ROOT"/Sources/Catet/MeetingStore.swift "$ROOT"/tests/RecordingFinalizationTests.swift -o "$WORK/recording-finalization-tests" -framework AppKit -framework AVFoundation
"$WORK/recording-finalization-tests"
