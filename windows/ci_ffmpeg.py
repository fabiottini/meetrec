"""CI: ffmpeg.exe with the same sources and checks as the Windows setup, put on PATH for the next steps.
gyan.dev first (checked with its .sha256), FFmpeg-Builds on GitHub when gyan.dev fails (checked
with the GitHub release digest). FFMPEG_SOURCE=btbn uses the second one directly, so CI tests both."""
import hashlib
import json
import os
import re
import urllib.request
import zipfile
from pathlib import Path

GYAN = "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip"   # same as SetupForm.FfmpegUrl
dest = Path("tools").resolve()
dest.mkdir(exist_ok=True)
zpath = dest / "ffmpeg.zip"


def fetch(url, sha):
    urllib.request.urlretrieve(url, zpath)
    got = hashlib.sha256(zpath.read_bytes()).hexdigest()
    assert got == sha, f"SHA-256 {got} != {sha}"
    print("downloaded", url, "SHA-256 ok", got[:16])


def btbn():
    h = {"User-Agent": "meetrec-ci"}
    if os.environ.get("GH_TOKEN"):
        h["Authorization"] = "Bearer " + os.environ["GH_TOKEN"]
    rel = json.load(urllib.request.urlopen(urllib.request.Request(
        "https://api.github.com/repos/FFmpeg-Builds/FFmpeg-Builds/releases/latest", headers=h)))
    best = None
    for a in rel["assets"]:
        m = re.match(r"^ffmpeg-n(\d+)\.(\d+)-latest-win64-gpl-[\d.]+\.zip$", a["name"])     # same rule as the setup
        if m and (best is None or (int(m[1]), int(m[2])) > best[0]):
            best = ((int(m[1]), int(m[2])), a)
    a = best[1]
    assert a["digest"].startswith("sha256:"), "no digest"
    fetch(a["browser_download_url"], a["digest"][7:])


if os.environ.get("FFMPEG_SOURCE") == "btbn":
    btbn()
else:
    try:
        fetch(GYAN, urllib.request.urlopen(GYAN + ".sha256").read().decode().split()[0])
    except Exception as e:
        print("gyan.dev failed:", e, "-> FFmpeg-Builds")
        btbn()
with zipfile.ZipFile(zpath) as z:
    entry = next(n for n in z.namelist() if n.lower().endswith("/ffmpeg.exe"))
    (dest / "ffmpeg.exe").write_bytes(z.read(entry))
zpath.unlink()
with open(os.environ["GITHUB_PATH"], "a") as f:
    f.write(str(dest) + "\n")
print("ffmpeg ->", dest / "ffmpeg.exe")
