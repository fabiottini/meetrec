"""Unzip the Windows package in a temp folder (as a user would), run the app self test with its own
embedded Python, render the UI images, test the recorder of the package and, with --flow, the real
path of the app: import an audio file -> which meeting -> transcript -> note (dialogs answered by
themselves).

    python windows/test_app.py MeetRec-windows.zip <images_dir> [--flow call.wav --whisper exe --model bin --vad bin]
"""
import argparse
import json
import shutil
import os
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

ap = argparse.ArgumentParser()
ap.add_argument("pkg")
ap.add_argument("images")
ap.add_argument("--flow")
ap.add_argument("--whisper")
ap.add_argument("--model")
ap.add_argument("--vad", default="")
a = ap.parse_args()
pkg, images = Path(a.pkg).resolve(), Path(a.images).resolve()
ffmpeg = shutil.which("ffmpeg")
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
# the recorder of the package, through the same test as the standalone build
rec = subprocess.run([sys.executable, str(Path(__file__).resolve().parent.parent / "scripts" / "test_recorder.py"),
                      str(app.parent / "meetrec-capture.exe")])
ok = ok and rec.returncode == 0

if a.flow:
    # the app's own path, as after "Stop and process" or "Import audio file"
    flow_conf = tmp / "flow-config.json"
    notes = tmp / "notes"
    flow_conf.write_text(json.dumps({
        "recordings_dir": str(tmp / "recs-flow"), "output_dir": str(notes), "output_formats": ["md", "json"],
        "language": "en", "ui_language": "en", "summary": False, "after_process_audio": "ask",
        "whisper_bin": str(Path(a.whisper).resolve()), "whisper_model": str(Path(a.model).resolve()),
        "vad_model": str(Path(a.vad).resolve()) if a.vad else "", "ffmpeg": ffmpeg or "ffmpeg"}))
    fenv = {**env, "MEETREC_CONFIG_FILE": str(flow_conf), "MEETREC_CONF": str(flow_conf)}
    r3 = subprocess.run([str(app), "--test-flow", str(Path(a.flow).resolve())], capture_output=True, text=True,
                        encoding="utf-8", errors="replace", env=fenv, timeout=1200)
    print(r3.stdout, r3.stderr)
    written = sorted(p.name for p in notes.rglob("*.*"))
    print("notes:", written)
    ok = ok and r3.returncode == 0 and any(n.endswith(".md") for n in written) and any(n.endswith(".json") for n in written)
    if r3.returncode:
        log = Path(os.environ.get("LOCALAPPDATA", "")) / "MeetRec" / "state" / "app.log"
        if log.exists():
            print("--- app.log (end)\n" + log.read_text(encoding="utf-8", errors="replace")[-4000:])
print("ALL OK" if ok else "FAILED")
sys.exit(0 if ok else 1)
