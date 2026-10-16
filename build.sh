#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
test -f runtime.json || { echo 'Run ./setup.sh first.'; exit 1; }
APP="$ROOT/build/Catet.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swift scripts/make-icon.swift "$APP/Contents/Resources/Catet.icns"
xcrun swiftc -parse-as-library -swift-version 5 -O -target arm64-apple-macosx14.0 -module-name CatetEngine Sources/Shared/*.swift Sources/CatetEngine/*.swift -o "$APP/Contents/MacOS/CatetEngine"
xcrun swiftc -parse-as-library -swift-version 5 -O -target arm64-apple-macosx14.0 -module-name Catet Sources/Shared/*.swift Sources/Catet/*.swift -o "$APP/Contents/MacOS/Catet" -framework AppKit -framework SwiftUI -framework AVFoundation -framework ScreenCaptureKit -framework CoreMedia -framework AudioToolbox -framework Carbon
cp runtime.json "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Catet</string>
<key>CFBundleIdentifier</key><string>id.benny.catet</string>
<key>CFBundleName</key><string>Catet</string>
<key>CFBundleDisplayName</key><string>Catet</string>
<key>CFBundleIconFile</key><string>Catet.icns</string>
<key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>id.benny.catet</string><key>CFBundleURLSchemes</key><array><string>catet</string></array></dict></array>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.1</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><false/>
<key>NSMicrophoneUsageDescription</key><string>Catet records your microphone for meeting transcripts saved on this Mac.</string>
<key>NSScreenCaptureUsageDescription</key><string>Catet captures meeting audio from other apps. Screen images are not saved.</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
SIGN_ID="${CATET_SIGN_IDENTITY:-}"
SAVED_SIGNER="$HOME/Library/Application Support/Catet/runtime/signing-identity"
if [[ -z "$SIGN_ID" && -f "$SAVED_SIGNER" ]]; then
  SIGN_ID="$(cat "$SAVED_SIGNER")"
fi
if [[ -z "$SIGN_ID" ]]; then
  while read -r index fingerprint description; do
    if [[ "$fingerprint" =~ ^[A-Fa-f0-9]{40}$ ]]; then
      SIGN_ID="$fingerprint"
      break
    fi
  done < <(security find-identity -v -p codesigning)
fi
if [[ -z "$SIGN_ID" ]]; then
  echo 'A code-signing certificate is required to keep recording permissions stable. Set CATET_SIGN_IDENTITY to a valid Keychain signing identity.' >&2
  exit 1
fi
codesign --force --sign "$SIGN_ID" --timestamp=none "$APP/Contents/MacOS/CatetEngine"
codesign --force --sign "$SIGN_ID" --timestamp=none --identifier id.benny.catet "$APP"
codesign --verify --deep --strict "$APP"
printf '%s\n' "$SIGN_ID" > "$ROOT/build/signing-identity"
echo "$APP"
