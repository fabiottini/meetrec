#!/bin/zsh
# Builds the recorder and the menu bar app, sets up the Python venv and installs:
#   ~/.local/bin/meet          CLI wrapper
#   ~/Applications/MeetRec.app menu bar app
set -euo pipefail
REPO="${0:A:h}"
cd "$REPO"

for t in swiftc ffmpeg python3; do
  command -v $t >/dev/null || { echo "missing: $t"; exit 1; }
done
[[ -x /Applications/vibe.app/Contents/MacOS/vibe ]] || echo "warning: Vibe not found in /Applications (needed for transcription)"

echo "==> python venv"
[[ -d .venv ]] || python3 -m venv .venv
.venv/bin/pip install -q --upgrade pip msal

echo "==> recorder"
swiftc -O -o capture/meetrec-capture capture/main.swift shared/MicVolume.swift

echo "==> meet CLI"
mkdir -p "$HOME/.local/bin"
rm -f "$HOME/.local/bin/meet"
cat > "$HOME/.local/bin/meet" <<WRAP
#!/bin/sh
exec "$REPO/.venv/bin/python" "$REPO/meet.py" "\$@"
WRAP
chmod +x "$HOME/.local/bin/meet"

echo "==> menu bar app"
APP="$HOME/Applications/MeetRec.app"
BUILD=$(mktemp -d)
mkdir -p "$BUILD/MeetRec.app/Contents/MacOS"
swiftc -O -o "$BUILD/MeetRec.app/Contents/MacOS/MeetRec" menubar/main.swift menubar/LevelPanel.swift shared/MicVolume.swift
cp menubar/Info.plist "$BUILD/MeetRec.app/Contents/Info.plist"
mkdir -p "$BUILD/MeetRec.app/Contents/Resources"
cp assets/AppIcon.icns "$BUILD/MeetRec.app/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$BUILD/MeetRec.app"
pkill -x MeetRec 2>/dev/null || true
mkdir -p "$HOME/Applications"
[[ -d "$APP.old" ]] && rm -r "$APP.old"
[[ -d "$APP" ]] && mv "$APP" "$APP.old"
mv "$BUILD/MeetRec.app" "$APP"
rmdir "$BUILD"
[[ -d "$APP.old" ]] && rm -r "$APP.old"
open "$APP"

echo "done. Open MeetRec > Impostazioni to set the vault and log in to Outlook."
