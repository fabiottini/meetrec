"""Windows recorder test without audio devices: `--test-tone` sends a tone through the same writer,
gap filling, levels file and stop.request protocol used with real devices; then meet.py builds the mix.

    python scripts/test_recorder.py path/to/meetrec-capture.exe
"""
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

exe = Path(sys.argv[1]).resolve()
work = Path(tempfile.mkdtemp(prefix="meetrec-rec-"))
d = work / "rec"
fails = []


def check(name, ok, info=""):
    print(("OK   " if ok else "FAIL ") + name + (f"  ({info})" if info else ""), flush=True)
    if not ok:
        fails.append(name)


log = open(work / "capture.log", "wb")
p = subprocess.Popen([str(exe), str(d), "--test-tone", "60"], stdout=log, stderr=log)
started = False
for _ in range(100):
    time.sleep(0.1)
    if (work / "capture.log").exists() and b"recording started" in (work / "capture.log").read_bytes():
        started = True
        break
check("recording started", started)
time.sleep(1.5)
check("levels file while recording", (d / "levels").exists(),
      (d / "levels").read_text() if (d / "levels").exists() else "")
time.sleep(3.5)
t0 = time.time()
(d / "stop.request").write_text("stop")
try:
    rc = p.wait(timeout=10)
except subprocess.TimeoutExpired:
    p.kill()
    rc = None
check("stops on stop.request", rc == 0, f"exit {rc}, {time.time() - t0:.2f} s")
log.close()
print((work / "capture.log").read_text(encoding="utf-8"))

check("capture.done", (d / "capture.done").exists())
check("levels removed", not (d / "levels").exists())
durs = {}
for n, rate in (("system", 48000), ("mic", 16000)):
    m = json.loads((d / f"{n}.json").read_text())
    check(f"{n}.json", m["format"] == "s16le" and m["channels"] == 1 and m["sample_rate"] == rate, str(m))
    durs[n] = m["offset_seconds"] + (d / f"{n}.s16").stat().st_size / 2 / rate
check("about 5 s recorded", all(4.5 < v < 6.5 for v in durs.values()), str(durs))
# the system tone stops every other second (like loopback with nothing playing): the gaps must be
# filled, so the two tracks keep the same length
check("tracks aligned (gaps filled)", abs(durs["system"] - durs["mic"]) < 0.25, str(durs))

# system track: tone in even seconds, silence in odd seconds, in the right place
raw = (d / "system.s16").read_bytes()
import array
a = array.array("h")
a.frombytes(raw)


def rms(sec):
    w = a[int((sec + 0.2) * 48000):int((sec + 0.8) * 48000)]
    return (sum(x * x for x in w) / max(1, len(w))) ** 0.5


pattern = [rms(s) for s in range(4)]
check("system tone on even seconds, silence on odd", pattern[0] > 3000 and pattern[2] > 3000
      and pattern[1] < 100 and pattern[3] < 100, ", ".join(f"{x:.0f}" for x in pattern))

# meet.py turns the tracks into the mix (same path as after a real recording)
(work / "conf.json").write_text(json.dumps({"recordings_dir": str(work / "recs"), "vault": str(work / "vault")}))
env = {**os.environ, "MEETREC_CAPTURE": str(exe), "MEETREC_CONF": str(work / "conf.json"), "PYTHONUTF8": "1"}
r = subprocess.run([sys.executable, "meet.py", "prepare", str(d)], capture_output=True, text=True,
                   encoding="utf-8", env=env)
print(r.stdout, r.stderr)
mix = d / "mix.m4a" if (d / "mix.m4a").exists() else None
check("meet.py prepare builds the mix", r.returncode == 0 and mix is not None, str(mix))

print("\n" + ("ALL OK" if not fails else f"{len(fails)} FAILED: {', '.join(fails)}"))
sys.exit(1 if fails else 0)
