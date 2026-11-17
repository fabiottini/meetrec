"""config.example.json is valid for meet (meet config check) and the README shows exactly that file."""
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ex = Path("config.example.json").read_text().strip()
readme = Path("README.md").read_text()
m = re.search(r"<!-- config-example:start -->\n```json\n(.*?)\n```\n<!-- config-example:end -->", readme, re.S)
ok = True
if not m or m.group(1).strip() != ex:
    print("README: the config example differs from config.example.json")
    ok = False
with tempfile.TemporaryDirectory() as d:
    Path(d, "config.json").write_text(ex)
    r = subprocess.run([sys.executable, "meet.py", "config", "check"], capture_output=True, text=True,
                       env={**os.environ, "MEETREC_CONF_DIR": d})
    if r.returncode:
        print("config.example.json:", r.stdout.strip())
        ok = False
print("config example ok" if ok else "config example NOT ok")
sys.exit(0 if ok else 1)
