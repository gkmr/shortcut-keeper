#!/bin/bash
# Builds ~/Applications/Key Deck.app from KeyDeck.swift.
#   ./build.sh --check   compile only (the installed app and its Accessibility permission are untouched)
#   ./build.sh           compile, install, sign
# Signing: the "Key Deck Local" certificate if present (Accessibility survives rebuilds), else ad-hoc
# (then System Settings > Privacy & Security > Accessibility: remove Key Deck with -, add it again with +).
set -euo pipefail
cd "$(dirname "$0")"
APP="$HOME/Applications/Key Deck.app"
OUT="$(mktemp -d)/KeyDeck"
[ "${1:-}" = "--check" ] && OUT="$(cd .. && pwd)/.state/KeyDeck-check"   # --check: the binary can render previews (--render)
swiftc -O -swift-version 5 -parse-as-library -framework AppKit -framework SwiftUI -framework Carbon -framework ApplicationServices \
  KeyDeck.swift -o "$OUT"
if [ "${1:-}" = "--check" ]; then echo "compiled OK (not installed): $OUT"; exit 0; fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv -f "$OUT" "$APP/Contents/MacOS/KeyDeck"
cp Info.plist "$APP/Contents/Info.plist"
if [ -f ../raycast-ext/assets/icon.png ] && [ ! -f "$APP/Contents/Resources/KeyDeck.icns" ]; then
  T=$(mktemp -d)/KeyDeck.iconset; mkdir -p "$T"
  for s in 16 32 128 256 512; do sips -z $s $s ../raycast-ext/assets/icon.png --out "$T/icon_${s}x${s}.png" >/dev/null; done
  R='@2x'   # retina suffix
  cp "$T/icon_32x32.png" "$T/icon_16x16$R.png"; cp "$T/icon_256x256.png" "$T/icon_128x128$R.png"; cp "$T/icon_512x512.png" "$T/icon_256x256$R.png"
  iconutil -c icns "$T" -o "$APP/Contents/Resources/KeyDeck.icns" || true
fi
# Sign with the stable "Key Deck Local" certificate when the user has created it (Keychain Access > Certificate Assistant >
# Create a Certificate: name Key Deck Local, Self Signed Root, Code Signing). Then Accessibility survives rebuilds.
# Without it, fall back to ad-hoc signing (Accessibility must be granted again after each install).
if security find-certificate -c "Key Deck Local" >/dev/null 2>&1 && codesign --force --sign "Key Deck Local" "$APP" 2>/dev/null; then
  echo "signed with Key Deck Local (Accessibility persists across rebuilds)"
else
  codesign --force --sign - "$APP"; echo "signed ad-hoc (grant Accessibility again)"
fi
echo "built $APP"
