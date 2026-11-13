"""Unzip the Windows package in a temp folder (as a user would), run the app self test with its own
embedded Python, and render the UI images.

    python windows/test_app.py MeetRec-windows.zip <images_dir>
"""
import json
import os
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

pkg, images = Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve()
tmp = Path(tempfile.mkdtemp(prefix="meetrec-app-"))
zipfile.ZipFile(pkg).extractall(tmp)
app = tmp / "MeetRec" / "MeetRec.exe"
conf = tmp / "config.json"
conf.write_text(json.dumps({"vault": str(tmp / "vault"), "recordings_dir": str(tmp / "recs"), "ui_language": "en"}))
# a clean environment: no Python on PATH, so the app must use the embedded one
env = {k: v for k, v in os.environ.items() if k.upper() not in ("PYTHONHOME", "PYTHONPATH")}
env["PATH"] = r"C:\Windows\System32;C:\Windows"
env["MEETREC_CONFIG_FILE"] = str(conf)
env["MEETREC_CONF"] = str(conf)

r = subprocess.run([str(app), "--self-test"], capture_output=True, text=True, encoding="utf-8", errors="replace",
                   env=env, timeout=300)
print(r.stdout, r.stderr)
ok = r.returncode == 0 and "ALL OK" in r.stdout

images.mkdir(parents=True, exist_ok=True)
r2 = subprocess.run([str(app), "--render-docs", str(images)], capture_output=True, text=True, encoding="utf-8",
                    errors="replace", env=env, timeout=300)
print(r2.stdout, r2.stderr)
pngs = sorted(p.name for p in images.glob("*.png"))
print("images:", pngs)
ok = ok and r2.returncode == 0 and len(pngs) >= 5

cmd = subprocess.run([str(tmp / "MeetRec" / "meet.cmd"), "--version"], capture_output=True, text=True, env=env)
print("meet.cmd:", cmd.stdout.strip(), cmd.stderr.strip())
ok = ok and cmd.stdout.startswith("MeetRec")
# the recorder inside MeetRec.exe, through the same test as the standalone one
rec = subprocess.run([sys.executable, str(Path(__file__).resolve().parent.parent / "scripts" / "test_recorder.py"),
                      str(app), "--capture"])
ok = ok and rec.returncode == 0
print("ALL OK" if ok else "FAILED")
sys.exit(0 if ok else 1)
