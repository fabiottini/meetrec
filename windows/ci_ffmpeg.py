"""CI: ffmpeg.exe from the same URL the Windows setup uses, put on PATH for the next steps."""
import hashlib
import os
import urllib.request
import zipfile
from pathlib import Path

URL = "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip"   # same as SetupForm.FfmpegUrl
dest = Path("tools").resolve()
dest.mkdir(exist_ok=True)
urllib.request.urlretrieve(URL, dest / "ffmpeg.zip")
# the same check as the setup: the SHA-256 published next to the zip
want = urllib.request.urlopen(URL + ".sha256").read().decode().split()[0]
got = hashlib.sha256((dest / "ffmpeg.zip").read_bytes()).hexdigest()
assert got == want, f"ffmpeg SHA-256 {got} != {want}"
print("ffmpeg SHA-256 ok", got[:16])
with zipfile.ZipFile(dest / "ffmpeg.zip") as z:
    entry = next(n for n in z.namelist() if n.lower().endswith("/ffmpeg.exe"))
    (dest / "ffmpeg.exe").write_bytes(z.read(entry))
(dest / "ffmpeg.zip").unlink()
with open(os.environ["GITHUB_PATH"], "a") as f:
    f.write(str(dest) + "\n")
print("ffmpeg ->", dest / "ffmpeg.exe")
