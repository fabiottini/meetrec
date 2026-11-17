#!/bin/zsh
# Builds MeetRec and installs it in /Applications, then opens it (the app runs its own setup).
# Without building: unzip dist/MeetRec.zip into /Applications.
set -euo pipefail
cd "${0:A:h}"
./build.sh
DEST="/Applications/MeetRec.app"
OLD="$HOME/Applications/MeetRec.app"
pkill -x MeetRec 2>/dev/null || true
[[ -d "$DEST" ]] && rm -r "$DEST"
ditto dist/MeetRec.app "$DEST"
# older versions went to ~/Applications: one copy only
[[ -f "$OLD/Contents/Resources/meet.py" ]] && rm -r "$OLD" && echo "removed the old copy $OLD"
open "$DEST"
echo "installed $DEST"
