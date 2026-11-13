"""Build the Windows zip: MeetRec\\ with the tray app, the recorder, meet.py, the locales and an
embedded Python (no Python install needed). Runs on Windows (CI) after `dotnet publish` of windows/app.

    python windows/package.py <app_publish_dir> <out_dir>

MeetRec.exe is also the recorder (MeetRec.exe --capture), so there is one .NET runtime in the zip.

ffmpeg, whisper.cpp and the models are not in the zip: the setup in the app downloads them.
"""
import shutil
import sys
import urllib.request
import zipfile
from pathlib import Path

PYTHON = "3.12.10"
app_pub, out = (Path(a) for a in sys.argv[1:3])
root = Path(__file__).resolve().parent.parent
stage = out / "MeetRec"
shutil.rmtree(stage, ignore_errors=True)
stage.mkdir(parents=True)

shutil.copy2(app_pub / "MeetRec.exe", stage)
for f in ("meet.py", "VERSION", "LICENSE", "CHANGELOG.md"):
    shutil.copy2(root / f, stage)
shutil.copytree(root / "locales", stage / "locales")
# command line: meet.cmd next to the app (the setup can add this folder to PATH)
(stage / "meet.cmd").write_text('@echo off\r\nset "MEETREC_CAPTURE=%~dp0MeetRec.exe"\r\n'
                                '"%~dp0python\\python.exe" "%~dp0meet.py" %*\r\n', encoding="ascii")
(stage / "README.txt").write_text(
    "MeetRec for Windows\r\n\r\n"
    "1. Keep this folder where you like (for example %LOCALAPPDATA%\\Programs\\MeetRec).\r\n"
    "2. Start MeetRec.exe: the icon appears in the tray, next to the clock (it can hide under the ^ arrow).\r\n"
    "3. The setup opens and downloads what is missing (ffmpeg, whisper.cpp, the speech model).\r\n\r\n"
    "Command line: meet.cmd (same commands as `meet` on macOS).\r\n"
    "Everything runs on this PC; https://github.com/fabiottini/meetrec\r\n", encoding="utf-8")

url = f"https://www.python.org/ftp/python/{PYTHON}/python-{PYTHON}-embed-amd64.zip"
emb = out / "python-embed.zip"
if not emb.exists():
    print("downloading", url)
    urllib.request.urlretrieve(url, emb)
zipfile.ZipFile(emb).extractall(stage / "python")

dest = out / "MeetRec-windows.zip"
dest.unlink(missing_ok=True)
with zipfile.ZipFile(dest, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for f in sorted(stage.rglob("*")):
        if f.is_file():
            z.write(f, f.relative_to(out))
print(f"{dest}  {dest.stat().st_size / 1e6:.1f} MB")
