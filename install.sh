#!/bin/zsh
# Builds MeetRec and installs it in ~/Applications, then opens it (the app runs its own setup).
# Without building: unzip dist/MeetRec.zip into /Applications or ~/Applications.
set -euo pipefail
cd "${0:A:h}"
./build.sh
DEST="$HOME/Applications/MeetRec.app"
pkill -x MeetRec 2>/dev/null || true
mkdir -p "$HOME/Applications"
[[ -d "$DEST" ]] && rm -r "$DEST"
ditto dist/MeetRec.app "$DEST"
open "$DEST"
echo "installed $DEST"
