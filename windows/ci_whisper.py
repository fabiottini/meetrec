"""CI: whisper.cpp for Windows (latest release with whisper-bin-x64.zip), the tiny model and the
silence filter; WHISPER (path of whisper-cli.exe) goes to GITHUB_ENV for the next steps."""
import json
import os
import pathlib
import urllib.request
import zipfile

h = {"Authorization": "Bearer " + os.environ["GH_TOKEN"], "User-Agent": "meetrec-ci"}
req = urllib.request.Request("https://api.github.com/repos/ggml-org/whisper.cpp/releases?per_page=20", headers=h)
rels = json.load(urllib.request.urlopen(req))
rel = next(r for r in rels if any(a["name"] == "whisper-bin-x64.zip" for a in r["assets"]))
url = next(a["browser_download_url"] for a in rel["assets"] if a["name"] == "whisper-bin-x64.zip")
print("whisper.cpp release", rel["tag_name"])
urllib.request.urlretrieve(url, "whisper.zip")
zipfile.ZipFile("whisper.zip").extractall("whisper")
cli = next(pathlib.Path("whisper").rglob("whisper-cli.exe"))
with open(os.environ["GITHUB_ENV"], "a") as f:
    f.write(f"WHISPER={cli.resolve()}\n")
os.makedirs("models", exist_ok=True)
for u in ["https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin",
          "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin"]:
    urllib.request.urlretrieve(u, "models/" + u.rsplit("/", 1)[1])
