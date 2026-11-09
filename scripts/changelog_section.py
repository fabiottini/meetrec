"""Print the CHANGELOG.md section of a version (release notes for GitHub)."""
import re
import sys

v = sys.argv[1]
text = open("CHANGELOG.md").read()
m = re.search(r"^## " + re.escape(v) + r" .*?\n(.*?)(?=^## |\Z)", text, re.S | re.M)
print((m.group(1).strip() if m else f"MeetRec {v}") + f"""

**Install:** download `MeetRec-{v}.zip`, unzip it, move MeetRec to Applications and open it
(the first time: System Settings > Privacy & Security > Open Anyway). See the README.""")
