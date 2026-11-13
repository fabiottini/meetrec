"""CI: ffmpeg.exe from the same URL the Windows setup uses, put on PATH for the next steps."""
import os
import urllib.request
import zipfile
from pathlib import Path

URL = "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip"   # same as SetupForm.FfmpegUrl
dest = Path("tools").resolve()
dest.mkdir(exist_ok=True)
urllib.request.urlretrieve(URL, dest / "ffmpeg.zip")
with zipfile.ZipFile(dest / "ffmpeg.zip") as z:
    entry = next(n for n in z.namelist() if n.lower().endswith("/ffmpeg.exe"))
    (dest / "ffmpeg.exe").write_bytes(z.read(entry))
(dest / "ffmpeg.zip").unlink()
with open(os.environ["GITHUB_PATH"], "a") as f:
    f.write(str(dest) + "\n")
print("ffmpeg ->", dest / "ffmpeg.exe")
