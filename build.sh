#!/bin/zsh
# Builds dist/MeetRec.app (universal: Apple Silicon + Intel) and dist/MeetRec.zip.
# The app is self-contained: recorder, meet.py and locales are inside the bundle.
set -euo pipefail
cd "${0:A:h}"

MIN=15.0
OUT=dist
APP="$OUT/MeetRec.app"
TMP=$(mktemp -d)

universal() {   # universal <output> <sources...>
  local out=$1; shift
  swiftc -O -target arm64-apple-macos$MIN  -o "$TMP/arm64" "$@"
  swiftc -O -target x86_64-apple-macos$MIN -o "$TMP/x86_64" "$@"
  lipo -create -output "$out" "$TMP/arm64" "$TMP/x86_64"
}

echo "==> build"
[[ -d "$APP" ]] && rm -r "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
universal "$APP/Contents/MacOS/meetrec-capture" capture/main.swift shared/MicVolume.swift
universal "$APP/Contents/MacOS/MeetRec" menubar/main.swift menubar/LevelPanel.swift menubar/Setup.swift shared/MicVolume.swift
cp menubar/Info.plist "$APP/Contents/Info.plist"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp meet.py "$APP/Contents/Resources/meet.py"
cp -R locales "$APP/Contents/Resources/locales"
codesign --force --deep --sign - "$APP"
[[ -d "$TMP" ]] && rm -r "$TMP"

echo "==> zip"
[[ -f "$OUT/MeetRec.zip" ]] && rm "$OUT/MeetRec.zip"
ditto -c -k --keepParent "$APP" "$OUT/MeetRec.zip"
ls -la "$OUT/MeetRec.zip"
