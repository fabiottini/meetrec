#!/usr/bin/env python3
"""meet: record meetings from the CLI, transcribe locally with whisper.cpp, link to Outlook, save to Obsidian.

  meet start [-t TITLE]     start recording in background (mic + system audio)
  meet stop [--no-process | --discard]   stop and process (transcript + note), or stop and delete
  meet discard DIR          delete a recording folder
  meet verify DIR / meet drop-audio DIR   check a processed recording / delete its audio (only if OK)
  meet voice-test p1..p4    hear a voice profile on a few seconds of your microphone
  meet rec [-t TITLE]       foreground: record until Ctrl-C, then process
  meet status               current recording
  meet process DIR          (re)process a recording folder
  meet import FILE [-t TITLE] [--at "YYYY-MM-DD HH:MM"]   process an existing audio file (mp3, wav, m4a…)
  meet recover              list recordings never processed (e.g. after a crash)
  meet accounts             calendar accounts (Microsoft, Google, macOS Calendar), as many as you want
  meet account add microsoft | google | macos;  meet account remove ID
  meet candidates DIR / meet choose DIR N|none   events found for a recording, pick one
  meet events [DATE]        list calendar events of a day (test)
  meet mics                 list microphones
"""
import argparse
import datetime as dt
import difflib
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

HOME = Path.home()
APP_DIR = Path(__file__).resolve().parent
CONF_DIR = HOME / ".config" / "meetrec"
STATE_DIR = HOME / ".local" / "state" / "meetrec"
CURRENT = STATE_DIR / "current.json"
VIBE_SUPPORT = HOME / "Library/Application Support/github.com.thewh1teagle.vibe"
DATA_DIR = HOME / "Library" / "Application Support" / "MeetRec"      # models downloaded by the app setup
MODEL_URL = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"
VAD_URL = "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin"


def first_existing(*paths):
    for p in paths:
        if p and Path(p).exists():
            return str(p)
    return str(paths[0]) if paths else ""


def find_capture():
    # inside MeetRec.app: Contents/Resources/meet.py -> Contents/MacOS/meetrec-capture; in the repo: capture/
    return first_existing(os.environ.get("MEETREC_CAPTURE"),
                          APP_DIR.parent / "MacOS" / "meetrec-capture",
                          APP_DIR / "capture" / "meetrec-capture")

DEFAULTS = {
    "recordings_dir": str(HOME / "Recordings" / "meetings"),
    "vault": "",                                       # Obsidian vault (required)
    "meetings_dir": "Meetings",                        # relative to the vault, + /YYYY-MM/
    "people_dir": "People",                            # person notes, linked by nome_cognome.md
    "context": "work",                                 # frontmatter `context:`
    "language": "it",
    "me": "Me",                                        # label for the mic track
    "others_label": "Altri",                           # label for the system-audio track
    # transcription: whisper.cpp (brew install whisper-cpp); Vibe only as a fallback if whisper-cli is missing
    "whisper_bin": first_existing(shutil.which("whisper-cli"), "/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"),
    "whisper_model": first_existing(DATA_DIR / "models" / "ggml-large-v3-turbo.bin", VIBE_SUPPORT / "ggml-large-v3-turbo.bin"),
    "vad_model": first_existing(DATA_DIR / "models" / "ggml-silero-v6.2.0.bin", VIBE_SUPPORT / "ggml-silero-v6.2.0.bin"),
    "whisper_threads": 4,                              # keeps the Mac responsive while transcribing
    "vibe_bin": "/Applications/vibe.app/Contents/MacOS/vibe",
    "vibe_model": str(VIBE_SUPPORT / "ggml-large-v3-turbo.bin"),
    "ffmpeg": first_existing(shutil.which("ffmpeg"), "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"),
    "capture_bin": find_capture(),
    "mic_id": None,
    "auto_gain": True,                                 # lower the mic input volume when it clips
    "summary": True,
    "summary_cmd": ["claude", "-p", "--model", "sonnet"],
    "keep_raw": False,
    "keep_tracks": False,                              # keep mic.m4a/system.m4a after processing (mix.m4a is always kept)
    "record_system": True,                             # False: record only my voice (no system audio)
    "transcript_mode": "separate",                     # separate: me / others from the two tracks; mixed: one track from the mix
    "voice_profile": "none",                           # none | p1 | p2 | p3 | p4: alter the voice in the saved audio
    "voice_profile_scope": "mine",                     # mine: only my voice; all: every voice
    "after_process_audio": "ask",                      # ask | keep | delete (delete only after the result is verified)
    # Microsoft Graph (calendar). Same public client used by the ms365 MCP server.
    "ms_client_id": "084a3e9f-a9f4-43f7-89f9-d229cf97853e",
    "ms_authority": "https://login.microsoftonline.com/organizations",
    "timezone": "Europe/Rome",
}


USER_KEYS = ["recordings_dir", "vault", "meetings_dir", "people_dir", "context", "language", "me",
             "others_label", "mic_id", "auto_gain", "summary", "keep_raw", "keep_tracks", "record_system",
             "transcript_mode", "voice_profile", "voice_profile_scope", "after_process_audio"]


def load_conf():
    conf = dict(DEFAULTS)
    f = CONF_DIR / "config.json"
    if f.exists():
        conf.update(json.loads(f.read_text()))
    else:
        CONF_DIR.mkdir(parents=True, exist_ok=True)
        f.write_text(json.dumps({k: DEFAULTS[k] for k in USER_KEYS}, indent=2) + "\n")
    if os.environ.get("MEETREC_CONF"):      # extra overrides, e.g. for tests
        conf.update(json.loads(Path(os.environ["MEETREC_CONF"]).read_text()))
    # old configs pinned paths that may not exist any more (e.g. repo moved, app bundle): use defaults then
    for k in ("capture_bin", "ffmpeg", "whisper_bin", "whisper_model", "vad_model"):
        if not conf.get(k) or not Path(conf[k]).exists():
            conf[k] = DEFAULTS[k]
    return conf


C = load_conf()


def say(msg):
    print(f"[meet] {msg}", flush=True)


def now():
    return dt.datetime.now().astimezone()


def read_json(p, default=None):
    try:
        return json.loads(Path(p).read_text())
    except Exception:
        return default


def write_json(p, data):
    tmp = Path(str(p) + ".tmp")
    tmp.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
    tmp.replace(p)


def pid_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


# ---------------------------------------------------------------- recording

def cmd_start(a):
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    cur = read_json(CURRENT)
    if cur and pid_alive(cur["pid"]):
        say(f"already recording since {cur['started_at']} in {cur['dir']}")
        return 1
    start = now()
    d = Path(C["recordings_dir"]) / start.strftime("%Y-%m-%d_%H%M%S")
    d.mkdir(parents=True, exist_ok=True)
    cmd = [C["capture_bin"], str(d)]
    if a.no_mic:
        cmd.append("--no-mic")
    record_system = C["record_system"]
    if a.mic_only:
        record_system = False
    if a.with_system:
        record_system = True
    if not record_system:
        cmd.append("--no-system")
    if C.get("mic_id"):
        cmd += ["--mic-id", C["mic_id"]]
    if C.get("auto_gain", True):
        cmd.append("--auto-gain")
    logf = open(d / "capture.log", "ab")
    p = subprocess.Popen(cmd, stdout=logf, stderr=logf, stdin=subprocess.DEVNULL, start_new_session=True)
    # keep the Mac awake while recording
    subprocess.Popen(["caffeinate", "-i", "-w", str(p.pid)], start_new_session=True,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    meta = {"started_at": start.isoformat(timespec="seconds"), "title": a.title, "pid": p.pid,
            "language": a.lang or C["language"], "record_system": record_system,
            "transcript_mode": a.transcript or C["transcript_mode"],
            "voice_profile": a.voice_profile or C["voice_profile"],
            "voice_profile_scope": a.voice_scope or C["voice_profile_scope"]}
    write_json(d / "meta.json", meta)
    for _ in range(50):
        time.sleep(0.1)
        if (d / "capture.error").exists() or p.poll() is not None:
            say("capture failed to start:")
            print((d / "capture.log").read_text(), file=sys.stderr)
            return 1
        if b"recording started" in (d / "capture.log").read_bytes():
            break
    write_json(CURRENT, {**meta, "dir": str(d)})
    say(f"recording -> {d}")
    say("stop with: meet stop")
    return 0


def stop_capture():
    cur = read_json(CURRENT)
    if not cur:
        say("no recording in progress")
        return None
    d = Path(cur["dir"])
    if pid_alive(cur["pid"]):
        os.kill(cur["pid"], signal.SIGINT)
        for _ in range(100):
            if not pid_alive(cur["pid"]):
                break
            time.sleep(0.1)
        else:
            os.kill(cur["pid"], signal.SIGKILL)
    meta = read_json(d / "meta.json", {})
    meta["stopped_at"] = now().isoformat(timespec="seconds")
    write_json(d / "meta.json", meta)
    CURRENT.unlink(missing_ok=True)
    say(f"stopped ({duration_str(d)}) -> {d}")
    return d


def discard(d):
    """delete a recording folder: only real recordings (inside recordings_dir, with meta.json)"""
    d = Path(d).expanduser().resolve()
    root_ = Path(C["recordings_dir"]).expanduser().resolve()
    if d.parent != root_ or not (d / "meta.json").is_file():
        say(f"not a MeetRec recording folder, not deleted: {d}")
        return 1
    cur = read_json(CURRENT) or {}
    if Path(cur.get("dir", "/nonexistent")).resolve() == d and pid_alive(cur.get("pid", 0)):
        say("this recording is still running: stop it first (meet stop --discard)")
        return 1
    shutil.rmtree(d)
    say(f"recording deleted: {d}")
    return 0


def cmd_discard(a):
    return discard(a.dir)


def cmd_stop(a):
    d = stop_capture()
    if d and a.discard:
        return discard(d)
    if d and not a.no_process:
        if sys.stdin.isatty():
            ask_event(d)
        return process(d)
    return 0


def cmd_rec(a):
    if cmd_start(a):
        return 1
    say("recording... press Ctrl-C to stop")
    try:
        while True:
            cur = read_json(CURRENT)
            if not cur or not pid_alive(cur["pid"]):
                say("capture process ended unexpectedly")
                break
            time.sleep(1)
    except KeyboardInterrupt:
        print()
    d = stop_capture()
    return process(d) if d else 1


def track_seconds(d, name):
    total = 0.0
    for j in sorted(d.glob(f"{name}*.json")):
        m = read_json(j)
        raw = j.with_suffix(".s16")
        if m and raw.exists():
            total = max(total, m["offset_seconds"] + raw.stat().st_size / 2 / m["sample_rate"])
    return total


def duration_str(d):
    s = max(track_seconds(d, "system"), track_seconds(d, "mic"))
    if s == 0:
        s = probe_duration(d / "mix.m4a")
    return f"{int(s // 3600)}h{int(s % 3600 // 60):02d}m{int(s % 60):02d}s"


def cmd_status(a):
    cur = read_json(CURRENT)
    if not cur:
        say("not recording")
        return 0
    alive = pid_alive(cur["pid"])
    say(f"{'RECORDING' if alive else 'DEAD (run: meet stop)'} since {cur['started_at']} "
        f"[{duration_str(Path(cur['dir']))}] title={cur.get('title')!r} dir={cur['dir']}")
    return 0


# ---------------------------------------------------------------- audio

def ff(*args):
    subprocess.run([C["ffmpeg"], "-hide_banner", "-loglevel", "error", "-y", *args], check=True)


def probe_duration(p):
    if not Path(p).exists():
        return 0.0
    r = subprocess.run([C["ffmpeg"], "-hide_banner", "-i", str(p)], capture_output=True, text=True)
    m = re.search(r"Duration: (\d+):(\d+):([\d.]+)", r.stderr)
    return int(m[1]) * 3600 + int(m[2]) * 60 + float(m[3]) if m else 0.0


def track_inputs(d, name):
    """ffmpeg inputs + filter that place all segments of a raw track on a common timeline."""
    inputs, parts = [], []
    for j in sorted(d.glob(f"{name}*.json")):
        m = read_json(j)
        raw = j.with_suffix(".s16")
        if not m or not raw.exists() or raw.stat().st_size == 0:
            continue
        inputs.append((["-f", "s16le", "-ar", str(m["sample_rate"]), "-ac", "1"], str(raw), m["offset_seconds"]))
    return inputs


def render_track(d, name, out, rate):
    """raw segments -> one file (wav 16k for whisper, or m4a for archive)."""
    ins = track_inputs(d, name)
    if not ins:
        return False
    args, filt = [], []
    for i, (fmt, path, off) in enumerate(ins):
        args += fmt + ["-i", path]
        ms = int(round(off * 1000))
        filt.append(f"[{i}:a]aresample={rate},adelay={ms}:all=1[s{i}]")
    if len(ins) == 1:
        graph = filt[0].replace("[s0]", "[out]")
    else:
        graph = ";".join(filt) + ";" + "".join(f"[s{i}]" for i in range(len(ins))) + \
            f"amix=inputs={len(ins)}:normalize=0[out]"
    codec = ["-c:a", "pcm_s16le"] if str(out).endswith(".wav") else ["-c:a", "aac", "-b:a", "64k"]
    ff(*args, "-filter_complex", graph, "-map", "[out]", "-ac", "1", *codec, str(out))
    return True


def build_audio(d):
    """Create wav for transcription and m4a for archive. Raw files are removed only when m4a are verified."""
    have_raw = any(d.glob("*.s16"))
    tracks = [n for n in ("mic", "system") if any(d.glob(f"{n}*.json"))]
    if have_raw:
        for n in tracks:
            say(f"encoding {n} track")
            render_track(d, n, d / f"{n}.wav", 16000)
            render_track(d, n, d / f"{n}.m4a", 48000 if n == "system" else 16000)
        mixin = [x for n in tracks for x in ("-i", str(d / f"{n}.m4a"))]
        if len(tracks) == 2:
            ff(*mixin, "-filter_complex", "[0:a]aresample=48000[a];[1:a]aresample=48000[b];[a][b]amix=inputs=2:normalize=0",
               "-c:a", "aac", "-b:a", "96k", str(d / "mix.m4a"))
        elif tracks:
            shutil.copy(d / f"{tracks[0]}.m4a", d / "mix.m4a")
        ok = all(abs(probe_duration(d / f"{n}.m4a") - track_seconds(d, n)) < 3 for n in tracks)
        if ok and not C["keep_raw"]:
            for f in d.glob("*.s16"):
                f.unlink()
            say("raw audio verified and removed (m4a kept)")
        elif not ok:
            say("WARNING: m4a duration mismatch, raw files kept")
    else:
        # re-processing: reuse saved transcriptions; decode audio only for what is missing
        for n in ("mic", "system"):
            if not (d / f"{n}.segments.json").exists() and not (d / f"{n}.wav").exists() and (d / f"{n}.m4a").exists():
                ff("-i", str(d / f"{n}.m4a"), "-ar", "16000", "-ac", "1", str(d / f"{n}.wav"))
        tracks = [n for n in ("mic", "system") if (d / f"{n}.segments.json").exists() or (d / f"{n}.wav").exists()]
        if not tracks and (d / "mix.m4a").exists():
            # only the mix is left: transcribe it as one track (speakers not separated)
            if not (d / "mix.segments.json").exists() and not (d / "mix.wav").exists():
                ff("-i", str(d / "mix.m4a"), "-ar", "16000", "-ac", "1", str(d / "mix.wav"))
            tracks = ["mix"]
        return tracks
    return [n for n in tracks if (d / f"{n}.wav").exists()]


# ---------------------------------------------------------------- transcription (Vibe, local)

HALLUCINATIONS = re.compile(
    r"sottotitoli|amara\.org|qtss|grazie per la visione|iscriviti al canale|thanks for watching|"
    r"^\s*(grazie\.?|\.+|♪+)\s*$", re.I)


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def transcribe(d, tracks, lang):
    if all((d / f"{n}.segments.json").exists() for n in tracks):
        return {n: read_json(d / f"{n}.segments.json") for n in tracks}
    if Path(C["whisper_bin"]).exists() and Path(C["whisper_model"]).exists():
        return transcribe_whisper(d, tracks, lang)
    if Path(C["vibe_bin"]).exists():
        say("whisper.cpp not found, using Vibe")
        return transcribe_vibe(d, tracks, lang)
    raise RuntimeError("no transcription engine: install whisper.cpp (brew install whisper-cpp) "
                       "and the model (MeetRec > Setup)")


def transcribe_whisper(d, tracks, lang):
    """whisper.cpp CLI, one track at a time, with VAD (skips silence: about 2x faster)."""
    result = {}
    for n in tracks:
        out = d / f"{n}.segments.json"
        if out.exists():
            result[n] = read_json(out)
            continue
        say(f"transcribing {n} ({probe_duration(d / f'{n}.wav') / 60:.0f} min audio)...")
        t = time.time()
        cmd = [C["whisper_bin"], "-m", C["whisper_model"], "-f", str(d / f"{n}.wav"), "-l", lang,
               "-t", str(C["whisper_threads"]), "-oj", "-of", str(d / f"{n}.whisper"), "-np", "-pp"]
        if Path(C["vad_model"]).exists():
            cmd += ["--vad", "-vm", C["vad_model"]]
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        last = -1
        tail = []
        for line in p.stdout:
            tail = (tail + [line])[-20:]
            m = re.search(r"progress\s*=\s*(\d+)%", line)
            if m and int(m[1]) // 10 != last:          # report every 10%
                last = int(m[1]) // 10
                say(f"transcribing {n}: {m[1]}%")
        if p.wait():
            raise RuntimeError(f"whisper-cli failed on {n}: {''.join(tail)[-800:]}")
        raw = read_json(d / f"{n}.whisper.json", {})
        data = {"engine": "whisper.cpp", "segments": [
            {"start": x["offsets"]["from"] / 1000, "end": x["offsets"]["to"] / 1000,
             "text": x["text"], "no_speech_prob": 0.0}
            for x in raw.get("transcription", [])]}
        write_json(out, data)
        (d / f"{n}.whisper.json").unlink(missing_ok=True)
        result[n] = data
        say(f"  done in {time.time() - t:.0f}s")
    return result


def transcribe_vibe(d, tracks, lang):
    port = free_port()
    srv = subprocess.Popen([C["vibe_bin"], "serve", "-p", str(port), "--exit-with-parent", "true", C["vibe_model"]],
                           stdout=open(d / "vibe-server.log", "ab"), stderr=subprocess.STDOUT)
    base = f"http://127.0.0.1:{port}"
    try:
        for _ in range(120):
            try:
                if urllib.request.urlopen(base + "/ready", timeout=2).status == 200:
                    break
            except Exception:
                pass
            time.sleep(0.5)
        result = {}
        for n in tracks:
            out = d / f"{n}.segments.json"
            if out.exists():
                result[n] = read_json(out)
                continue
            say(f"transcribing {n} ({probe_duration(d / f'{n}.wav') / 60:.0f} min audio)...")
            t = time.time()
            r = subprocess.run(["curl", "-sS", "--fail-with-body", "-m", "7200", base + "/v1/audio/transcriptions",
                                "-F", f"file=@{d / f'{n}.wav'}", "-F", f"language={lang}",
                                "-F", "response_format=verbose_json"], capture_output=True, text=True)
            if r.returncode:
                raise RuntimeError(f"vibe transcription failed: {r.stdout[:500]} {r.stderr[:500]}")
            data = json.loads(r.stdout)
            write_json(out, data)
            result[n] = data
            say(f"  done in {time.time() - t:.0f}s")
        return result
    finally:
        srv.terminate()


def loudness_per_second(wav):
    """RMS level (dB) for each second of a 16 kHz wav, via ffmpeg astats."""
    r = subprocess.run([C["ffmpeg"], "-hide_banner", "-nostats", "-i", str(wav), "-af",
                        "asetnsamples=16000,astats=metadata=1:reset=1,"
                        "ametadata=print:key=lavfi.astats.Overall.RMS_level:file=-", "-f", "null", "-"],
                       capture_output=True, text=True)
    levels = []
    for m in re.finditer(r"RMS_level=(-?[\d.]+|-inf)", r.stdout):
        levels.append(-120.0 if m[1] == "-inf" else float(m[1]))
    return levels


SILENCE_DB = -50.0


def clean_segments(data, speaker, levels=None):
    out = []
    for s in data.get("segments", []):
        text = s["text"].strip()
        if not text or s.get("no_speech_prob", 0) > 0.6 or HALLUCINATIONS.search(text):
            continue
        # whisper often stretches the first segment after silence back to the window start
        start = max(s["start"], s["end"] - max(2.0, len(text) / 12))
        if levels is not None:
            window = levels[int(start):int(s["end"]) + 1]
            # text on a silent track (or past its end) is a whisper hallucination
            if not window or max(window) < SILENCE_DB:
                continue
        out.append({"start": start, "end": s["end"], "text": text, "speaker": speaker})
    return out


def track_levels(d, n):
    """per-second loudness of a track, cached in <track>.levels.json (survives deleting the audio)"""
    cache = d / f"{n}.levels.json"
    if cache.exists():
        return read_json(cache)
    if (d / f"{n}.wav").exists():
        lv = loudness_per_second(d / f"{n}.wav")
        write_json(cache, lv)
        return lv
    return None


def merge(segs_by_track, levels):
    me, others = C["me"], C["others_label"]
    if "mix" in segs_by_track:          # single mixed track: no speaker labels
        return join_turns(sorted(clean_segments(segs_by_track["mix"], "", levels.get("mix")), key=lambda s: s["start"]))
    mic = clean_segments(segs_by_track.get("mic", {}), me, levels.get("mic"))
    system = clean_segments(segs_by_track.get("system", {}), others, levels.get("system"))
    # drop mic segments that are just the speakers bleeding into the mic (no headphones)
    deduped = []
    for m in mic:
        bleed = any(s["start"] < m["end"] + 2 and s["end"] > m["start"] - 2 and
                    difflib.SequenceMatcher(None, m["text"].lower(), s["text"].lower()).ratio() > 0.6
                    for s in system)
        if not bleed:
            deduped.append(m)
    return join_turns(sorted(deduped + system, key=lambda s: s["start"]))


def join_turns(segs):
    turns = []
    for s in segs:
        if turns and turns[-1]["speaker"] == s["speaker"] and s["start"] - turns[-1]["end"] < 4:
            turns[-1]["text"] += " " + s["text"]
            turns[-1]["end"] = s["end"]
        else:
            turns.append(dict(s))
    return turns


def hms(sec):
    sec = int(sec)
    return f"{sec // 3600:02d}:{sec % 3600 // 60:02d}:{sec % 60:02d}"


def transcript_md(turns, single_track):
    lines = []
    for t in turns:
        who = "" if single_track else f"**{t['speaker']}:** "
        lines.append(f"`{hms(t['start'])}` {who}{t['text']}\n")
    return "\n".join(lines)


# ---------------------------------------------------------------- calendars (many accounts, many providers)
#
# Accounts live in config.json "calendar_accounts"; tokens in ~/.config/meetrec/tokens/<id>.json (0600).
#   microsoft  Microsoft Graph, work/school (authority organizations) or personal (consumers);
#              every calendar of the account, shared ones included. Device code login.
#   google     Google Calendar API, every calendar of the account. Browser login on a loopback
#              redirect; needs your OAuth "Desktop" client in ~/.config/meetrec/google_client.json.
#   macos      everything in the macOS Calendar app (iCloud, Google, Exchange, CalDAV, subscriptions)
#              through the meetrec-events helper (EventKit).
# Every provider returns the same event dict; duplicates across sources are shown once.

TOKENS_DIR = CONF_DIR / "tokens"
GOOGLE_CLIENT = CONF_DIR / "google_client.json"
MS_SCOPES = "Calendars.Read Calendars.Read.Shared offline_access openid profile"
MS_SCOPES_OLD = "Calendars.Read offline_access openid profile"     # logins made before multi-account
GOOGLE_SCOPES = "openid email https://www.googleapis.com/auth/calendar.readonly"


def http_json(url, data=None, headers=None, method=None):
    body = urllib.parse.urlencode(data).encode() if isinstance(data, dict) else data
    req = urllib.request.Request(url, data=body, headers=headers or {}, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        try:
            return json.loads(e.read())
        except Exception:
            return {"error": f"http {e.code}"}
    except Exception as e:
        return {"error": str(e)}


def jwt_claims(tok):
    import base64
    try:
        part = tok.split(".")[1]
        return json.loads(base64.urlsafe_b64decode(part + "=" * (-len(part) % 4)))
    except Exception:
        return {}


# ---- accounts

def accounts():
    migrate_old_login()
    return list(C.get("calendar_accounts") or [])


def save_accounts(accts):
    f = CONF_DIR / "config.json"
    cfg = read_json(f, {})
    cfg["calendar_accounts"] = accts
    write_json(f, cfg)
    C["calendar_accounts"] = accts


def token_file(acc):
    return TOKENS_DIR / f"{acc['id']}.json"


def save_token(acc, res, username=None):
    old = read_json(token_file(acc), {})
    claims = jwt_claims(res.get("id_token", ""))
    data = {"access_token": res["access_token"],
            "refresh_token": res.get("refresh_token") or old.get("refresh_token"),
            "expires_at": time.time() + int(res.get("expires_in", 3600)) - 120,
            "username": claims.get("preferred_username") or claims.get("email") or username or old.get("username")}
    TOKENS_DIR.mkdir(parents=True, exist_ok=True)
    token_file(acc).write_text(json.dumps(data, indent=2))
    os.chmod(token_file(acc), 0o600)
    return data


def new_account_id(provider):
    ids = {a["id"] for a in (C.get("calendar_accounts") or [])}
    i = 1
    while f"{provider}-{i}" in ids:
        i += 1
    return f"{provider}-{i}"


def migrate_old_login():
    """single-account era: token.json (or the msal cache) becomes the first Microsoft account"""
    if C.get("calendar_accounts") is not None:
        return
    accts = []
    old = read_json(CONF_DIR / "token.json")
    cache = read_json(CONF_DIR / "msal_cache.json", {})
    if old or cache:
        acc = {"id": "microsoft-1", "provider": "microsoft", "authority": "organizations", "scopes": MS_SCOPES_OLD}
        if old:
            TOKENS_DIR.mkdir(parents=True, exist_ok=True)
            token_file(acc).write_text(json.dumps(old, indent=2))
            os.chmod(token_file(acc), 0o600)
            acc["label"] = old.get("username")
        else:
            rt = next(iter(cache.get("RefreshToken", {}).values()), {}).get("secret")
            user = next(iter(cache.get("Account", {}).values()), {}).get("username")
            res = ms_post(acc, "token", {"grant_type": "refresh_token", "client_id": C["ms_client_id"],
                                         "refresh_token": rt or "", "scope": MS_SCOPES_OLD})
            if "access_token" in res:
                acc["label"] = save_token(acc, res, user).get("username")
        if acc.get("label"):
            accts.append(acc)
    save_accounts(accts)


def account_token(acc):
    """valid access token for the account, refreshed when needed (None if login is needed)"""
    if acc["provider"] == "macos":
        return "macos"
    tok = read_json(token_file(acc))
    if not tok:
        return None
    if time.time() < tok.get("expires_at", 0):
        return tok["access_token"]
    if not tok.get("refresh_token"):
        return None
    if acc["provider"] == "microsoft":
        res = ms_post(acc, "token", {"grant_type": "refresh_token", "client_id": C["ms_client_id"],
                                     "refresh_token": tok["refresh_token"], "scope": acc.get("scopes", MS_SCOPES)})
    else:
        client = google_client()
        if not client:
            return None
        res = http_json("https://oauth2.googleapis.com/token", {
            "grant_type": "refresh_token", "refresh_token": tok["refresh_token"],
            "client_id": client["client_id"], "client_secret": client.get("client_secret", "")})
    if "access_token" not in res:
        return None
    return save_token(acc, res)["access_token"]


def my_emails():
    out = set()
    for acc in accounts():
        for v in (acc.get("label"), read_json(token_file(acc), {}).get("username")):
            if v and "@" in v:
                out.add(v.lower())
    return out


# ---- Microsoft

MSA_TENANT = "9188040d-6c67-4c5b-b112-36a304b66dad"     # tenant id of personal Microsoft accounts


def ms_authority(acc):
    """login: 'common' (work, school or personal); refresh: the account's own kind"""
    a = acc.get("authority", "organizations")
    if a in ("consumers", "common"):
        return f"https://login.microsoftonline.com/{a}"
    return C["ms_authority"]


def ms_post(acc, path, data):
    return http_json(f"{ms_authority(acc)}/oauth2/v2.0/{path}", data, method="POST")


def ms_login():
    # one login for every kind of Microsoft account; the kind decides how the token is refreshed
    acc = {"id": new_account_id("microsoft"), "provider": "microsoft", "authority": "common", "scopes": MS_SCOPES}
    flow = ms_post(acc, "devicecode", {"client_id": C["ms_client_id"], "scope": MS_SCOPES})
    if "user_code" not in flow:
        say(f"device flow failed: {flow.get('error_description') or flow.get('error')}")
        return 1
    print(flow["message"], flush=True)       # the app reads URL and code from this line
    interval, deadline = int(flow.get("interval", 5)), time.time() + int(flow.get("expires_in", 900))
    while time.time() < deadline:
        time.sleep(interval)
        res = ms_post(acc, "token", {"grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                                     "client_id": C["ms_client_id"], "device_code": flow["device_code"]})
        if "access_token" in res:
            personal = jwt_claims(res.get("id_token", "")).get("tid") == MSA_TENANT
            acc["authority"] = "consumers" if personal else "organizations"
            return add_logged_account(acc, res)
        err = res.get("error")
        if err == "slow_down":
            interval += 5
        elif err != "authorization_pending":
            say(f"login failed: {err}: {res.get('error_description', '')[:300]}")
            return 1
    say("login failed: code expired")
    return 1


def add_logged_account(acc, res):
    data = save_token(acc, res)
    acc["label"] = data.get("username") or acc["id"]
    accts = [a for a in accounts() if not (a["provider"] == acc["provider"] and a.get("label") == acc["label"])]
    for a in accounts():                    # same account added again: drop the old token
        if a not in accts:
            token_file(a).unlink(missing_ok=True)
    save_accounts(accts + [acc])
    say(f"logged in as {acc['label']} ({acc['id']})")
    return 0


def ms_events(acc, start, end):
    tok = account_token(acc)
    if not tok:
        say(f"calendar {acc.get('label')}: login expired (Setup > Calendars) - skipped")
        return []
    hdr = {"Authorization": f"Bearer {tok}", "Prefer": 'outlook.timezone="UTC"'}
    cals = http_json("https://graph.microsoft.com/v1.0/me/calendars?$select=id,name&$top=100", headers=hdr)
    out = []
    for cal in cals.get("value", [{"id": None, "name": "Calendar"}]):
        base = (f"https://graph.microsoft.com/v1.0/me/calendars/{cal['id']}/calendarView" if cal["id"]
                else "https://graph.microsoft.com/v1.0/me/calendarView")
        q = urllib.parse.urlencode({
            "startDateTime": start.astimezone(dt.timezone.utc).isoformat(),
            "endDateTime": end.astimezone(dt.timezone.utc).isoformat(),
            "$select": "id,subject,start,end,organizer,attendees,bodyPreview,webLink,isAllDay,isCancelled",
            "$top": "100"})
        res = http_json(f"{base}?{q}", headers=hdr)
        if "error" in res:
            say(f"calendar {acc.get('label')}/{cal.get('name')}: {str(res['error'])[:120]}")
            continue
        for e in res.get("value", []):
            if e.get("isCancelled"):
                continue
            ppl = lambda x: {"name": x.get("emailAddress", {}).get("name") or "",
                             "email": (x.get("emailAddress", {}).get("address") or "").lower()}
            out.append({
                "id": e["id"], "account": acc["id"], "source": acc.get("label") or acc["id"], "calendar": cal.get("name"),
                "subject": e.get("subject") or "", "all_day": bool(e.get("isAllDay")),
                "start": e["start"]["dateTime"][:19] + "+00:00", "end": e["end"]["dateTime"][:19] + "+00:00",
                "organizer": ppl(e.get("organizer") or {}), "attendees": [ppl(x) for x in e.get("attendees", [])],
                "agenda": e.get("bodyPreview") or "", "link": e.get("webLink") or ""})
    return out


# ---- Google

def google_client():
    j = read_json(GOOGLE_CLIENT)
    return (j or {}).get("installed") or (j or {}).get("web") or j


def google_login():
    import base64
    import hashlib
    import http.server
    import secrets
    client = google_client()
    if not client or not client.get("client_id"):
        say(f"Google: missing OAuth client. Create a 'Desktop app' OAuth client in Google Cloud "
            f"(Calendar API enabled) and save its JSON as {GOOGLE_CLIENT} (Setup can do it)")
        return 2
    verifier = secrets.token_urlsafe(64)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    state = secrets.token_urlsafe(16)
    result = {}

    class H(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            if q.get("state", [""])[0] == state:
                result.update({k: v[0] for k, v in q.items()})
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            ok = "code" in result
            self.wfile.write(("<html><body style='font-family:-apple-system;padding:40px'><h2>MeetRec</h2><p>"
                              + ("Login completed, you can close this tab." if ok else "Login failed.")
                              + "</p></body></html>").encode())

        def log_message(self, *a):
            pass

    srv = http.server.HTTPServer(("127.0.0.1", 0), H)
    redirect = f"http://127.0.0.1:{srv.server_port}"
    url = "https://accounts.google.com/o/oauth2/v2/auth?" + urllib.parse.urlencode({
        "client_id": client["client_id"], "redirect_uri": redirect, "response_type": "code",
        "scope": GOOGLE_SCOPES, "access_type": "offline", "prompt": "consent select_account",
        "code_challenge": challenge, "code_challenge_method": "S256", "state": state})
    print(f"Open in your browser to sign in to Google: {url}", flush=True)
    subprocess.run(["open", url])
    srv.timeout = 300
    deadline = time.time() + 300
    while "code" not in result and "error" not in result and time.time() < deadline:
        srv.handle_request()
    srv.server_close()
    if "code" not in result:
        say(f"Google login failed: {result.get('error', 'timeout')}")
        return 1
    res = http_json("https://oauth2.googleapis.com/token", {
        "grant_type": "authorization_code", "code": result["code"], "redirect_uri": redirect,
        "client_id": client["client_id"], "client_secret": client.get("client_secret", ""), "code_verifier": verifier})
    if "access_token" not in res:
        say(f"Google login failed: {res.get('error')}: {res.get('error_description', '')}")
        return 1
    return add_logged_account({"id": new_account_id("google"), "provider": "google"}, res)


def google_events(acc, start, end):
    tok = account_token(acc)
    if not tok:
        say(f"calendar {acc.get('label')}: login expired (Setup > Calendars) - skipped")
        return []
    hdr = {"Authorization": f"Bearer {tok}"}
    cals = http_json("https://www.googleapis.com/calendar/v3/users/me/calendarList?minAccessRole=reader", headers=hdr)
    out = []
    for cal in cals.get("items", []):
        q = urllib.parse.urlencode({
            "timeMin": start.astimezone(dt.timezone.utc).isoformat(), "timeMax": end.astimezone(dt.timezone.utc).isoformat(),
            "singleEvents": "true", "orderBy": "startTime", "maxResults": "100"})
        res = http_json(f"https://www.googleapis.com/calendar/v3/calendars/{urllib.parse.quote(cal['id'])}/events?{q}", headers=hdr)
        for e in res.get("items", []):
            if e.get("status") == "cancelled":
                continue
            all_day = "date" in e.get("start", {})
            s = e["start"].get("dateTime") or (e["start"]["date"] + "T00:00:00+00:00")
            en = e["end"].get("dateTime") or (e["end"]["date"] + "T00:00:00+00:00")
            desc = re.sub(r"<[^>]+>", " ", e.get("description") or "")
            out.append({
                "id": e["id"], "account": acc["id"], "source": acc.get("label") or acc["id"], "calendar": cal.get("summary"),
                "subject": e.get("summary") or "", "all_day": all_day, "start": s, "end": en,
                "organizer": {"name": e.get("organizer", {}).get("displayName") or "", "email": (e.get("organizer", {}).get("email") or "").lower()},
                "attendees": [{"name": x.get("displayName") or "", "email": (x.get("email") or "").lower()}
                              for x in e.get("attendees", []) if not x.get("resource")],
                "agenda": desc, "link": e.get("htmlLink") or ""})
    return out


# ---- macOS Calendar (EventKit helper)

def events_helper():
    return first_existing(os.environ.get("MEETREC_EVENTS"), APP_DIR.parent / "MacOS" / "meetrec-events",
                          APP_DIR / "helpers" / "meetrec-events")


def macos_events(acc, start, end):
    h = events_helper()
    if not Path(h).exists():
        say("calendar macOS: meetrec-events helper not found - skipped")
        return []
    r = subprocess.run([h, "--from", start.isoformat(), "--to", end.isoformat()], capture_output=True, text=True, timeout=60)
    if r.returncode:
        say(f"calendar macOS: {r.stderr.strip()[:200]} - skipped")
        return []
    out = []
    for e in json.loads(r.stdout or "[]"):
        e.update({"account": acc["id"], "source": f"macOS · {e.get('source') or ''}".strip(" ·")})
        out.append(e)
    return out


PROVIDERS = {"microsoft": ms_events, "google": google_events, "macos": macos_events}


def all_events(start, end):
    """events of every account, duplicates (same title and start) shown once; direct accounts win over macOS"""
    evs = []
    for acc in sorted(accounts(), key=lambda a: a["provider"] == "macos"):
        try:
            evs += PROVIDERS[acc["provider"]](acc, start, end)
        except Exception as e:
            say(f"calendar {acc.get('label') or acc['id']}: {e} - skipped")
    seen, out = set(), []
    for e in evs:
        e["_start"] = dt.datetime.fromisoformat(e["start"].replace("Z", "+00:00")).astimezone()
        e["_end"] = dt.datetime.fromisoformat(e["end"].replace("Z", "+00:00")).astimezone()
        key = (re.sub(r"\W+", "", e["subject"].lower()), e["_start"].replace(second=0, microsecond=0))
        if key in seen:
            continue
        seen.add(key)
        out.append(e)
    return sorted(out, key=lambda e: e["_start"])


def candidates(rec_start, rec_end):
    """events that overlap the recording (or start within 10 min of it), best first"""
    out = []
    for e in all_events(rec_start - dt.timedelta(hours=3), rec_end + dt.timedelta(hours=1)):
        if e["all_day"]:
            continue
        overlap = (min(e["_end"], rec_end) - max(e["_start"], rec_start)).total_seconds()
        if overlap <= 0 and abs((e["_start"] - rec_start).total_seconds()) > 600:
            continue
        e["_score"] = overlap - abs((e["_start"] - rec_start).total_seconds()) / 10
        out.append(e)
    return sorted(out, key=lambda e: -e["_score"])


def plain_event(e):
    return {k: v for k, v in e.items() if not k.startswith("_")}


def load_event(d):
    """event chosen for this recording: meta['event'] (dict or 'none'), else the best candidate"""
    meta = read_json(d / "meta.json", {})
    ev = meta.get("event")
    if ev == "none":
        return None
    if isinstance(ev, dict):
        ev = dict(ev)
    else:
        cands = candidates(dt.datetime.fromisoformat(meta["started_at"]), dt.datetime.fromisoformat(meta["stopped_at"]))
        ev = cands[0] if cands else None
        if not ev:
            return None
    ev["_start"] = dt.datetime.fromisoformat(ev["start"].replace("Z", "+00:00")).astimezone()
    ev["_end"] = dt.datetime.fromisoformat(ev["end"].replace("Z", "+00:00")).astimezone()
    return ev


def recording_times(d):
    meta = read_json(d / "meta.json", {})
    if not meta.get("stopped_at"):
        secs = max(track_seconds(d, "system"), track_seconds(d, "mic")) or probe_duration(d / "mix.m4a")
        meta["stopped_at"] = (dt.datetime.fromisoformat(meta["started_at"]) + dt.timedelta(seconds=secs)).isoformat(timespec="seconds")
        write_json(d / "meta.json", meta)
    return dt.datetime.fromisoformat(meta["started_at"]), dt.datetime.fromisoformat(meta["stopped_at"])


def describe(e):
    return f"{e['_start']:%H:%M}-{e['_end']:%H:%M}  {e['subject']}  [{e['source']}]"


def cmd_candidates(a):
    d = Path(a.dir).expanduser().resolve()
    s, e = recording_times(d)
    cands = candidates(s, e)
    write_json(d / "candidates.json", [plain_event(c) for c in cands])
    if a.json:
        print(json.dumps([{**plain_event(c), "label": describe(c)} for c in cands], ensure_ascii=False))
    else:
        for i, c in enumerate(cands, 1):
            print(f"{i}. {describe(c)}")
    return 0


def parse_people(text):
    """'Mario Rossi, anna@x.com, Luca Bianchi <luca@y.com>' -> [{'name', 'email'}]"""
    out = []
    for part in re.split(r"[,;\n]+", text or ""):
        part = part.strip()
        if not part:
            continue
        m = re.match(r"^(.*?)\s*<([^>]+@[^>]+)>$", part)
        if m:
            out.append({"name": m[1].strip().strip('"'), "email": m[2].strip().lower()})
        elif "@" in part:
            local = part.split("@")[0].replace(".", " ").replace("_", " ").title()
            out.append({"name": local, "email": part.lower()})
        else:
            out.append({"name": part, "email": ""})
    return out


def manual_event(title, start, end, people="", agenda=""):
    return {"id": "manual", "manual": True, "account": "manual", "source": "manuale", "calendar": "",
            "subject": title, "all_day": False, "start": start, "end": end,
            "organizer": {"name": "", "email": ""}, "attendees": parse_people(people),
            "agenda": agenda or "", "link": ""}


def choose_event(d, choice, manual=None):
    meta = read_json(d / "meta.json", {})
    if choice == "none":
        meta["event"] = "none"
    elif choice == "manual":
        meta["event"] = manual
    else:
        cands = read_json(d / "candidates.json", [])
        meta["event"] = cands[int(choice) - 1]
    write_json(d / "meta.json", meta)


def cmd_choose(a):
    d = Path(a.dir).expanduser().resolve()
    manual = None
    if a.choice == "manual":
        if not a.title:
            say("manual event: --title is required")
            return 1
        s_, e_ = recording_times(d)
        start = dt.datetime.fromisoformat(a.start).astimezone() if a.start else s_
        end = dt.datetime.fromisoformat(a.end).astimezone() if a.end else e_
        manual = manual_event(a.title, start.isoformat(timespec="seconds"), end.isoformat(timespec="seconds"),
                              a.people or "", a.agenda or "")
    choose_event(d, a.choice, manual)
    return 0


def ask_event(d):
    """terminal: list the events found in every calendar and let the user pick (Enter = first)"""
    s, e = recording_times(d)
    cands = candidates(s, e)
    write_json(d / "candidates.json", [plain_event(c) for c in cands])
    if not cands:
        say("no calendar event at this time")
        ans = input("Write the meeting details yourself? [y/N] > ").strip().lower()
        if ans in ("y", "s", "yes", "si", "sì"):
            ask_manual(d, s, e)
        else:
            choose_event(d, "none")
        return
    print("Which meeting was it?")
    for i, c in enumerate(cands, 1):
        print(f"  {i}. {describe(c)}")
    print("  0. none of these")
    print("  m. none of these: I write it myself")
    ans = input(f"[1] > ").strip().lower() or "1"
    if ans == "m":
        ask_manual(d, s, e)
        return
    choose_event(d, "none" if ans == "0" else ans if ans.isdigit() and 1 <= int(ans) <= len(cands) else "1")


def ask_manual(d, s, e):
    """terminal: title, day, times, attendees, agenda (Enter keeps the recording values)"""
    title = ""
    while not title:
        title = input("Title: ").strip()
    day = input(f"Day [{s:%Y-%m-%d}]: ").strip() or f"{s:%Y-%m-%d}"
    t1 = input(f"Start [{s:%H:%M}]: ").strip() or f"{s:%H:%M}"
    t2 = input(f"End [{e:%H:%M}]: ").strip() or f"{e:%H:%M}"
    people = input("Attendees (comma separated, names or emails): ").strip()
    agenda = input("Agenda / notes (optional): ").strip()
    start = dt.datetime.fromisoformat(f"{day} {t1}").astimezone()
    end = dt.datetime.fromisoformat(f"{day} {t2}").astimezone()
    choose_event(d, "manual", manual_event(title, start.isoformat(timespec="seconds"),
                                           end.isoformat(timespec="seconds"), people, agenda))


def cmd_accounts(a):
    accts = accounts()
    rows = []
    for acc in accts:
        ok = account_token(acc) is not None
        rows.append({**acc, "ok": ok})
    if a.json:
        print(json.dumps({"accounts": rows, "google_client": bool(google_client())}, ensure_ascii=False))
    else:
        for r in rows:
            print(f"{r['id']:14} {r['provider']:10} {r.get('label') or '':40} {'ok' if r['ok'] else 'LOGIN NEEDED'}")
        if not rows:
            print("no calendar accounts (meet account add microsoft|google|macos)")
    return 0


def cmd_account(a):
    if a.action == "add":
        if a.provider == "microsoft":
            return ms_login()
        if a.provider == "google":
            return google_login()
        if a.provider == "macos":
            h = events_helper()
            r = subprocess.run([h, "--request-access"], capture_output=True, text=True) if Path(h).exists() else None
            if not r or r.returncode:
                say("macOS Calendar: access not granted (System Settings > Privacy > Calendars)")
                return 1
            accts = [x for x in accounts() if x["provider"] != "macos"]
            save_accounts(accts + [{"id": "macos", "provider": "macos", "label": "macOS Calendar"}])
            say("macOS Calendar added")
            return 0
    if a.action == "remove":
        accts = accounts()
        rid = a.id or a.provider
        keep = [x for x in accts if x["id"] != rid]
        if len(keep) == len(accts):
            say(f"no account {rid}")
            return 1
        (TOKENS_DIR / f"{rid}.json").unlink(missing_ok=True)
        save_accounts(keep)
        say(f"removed {rid}")
        return 0
    if a.action == "google-client":
        j = read_json(Path(a.provider).expanduser())
        c = (j or {}).get("installed") or (j or {}).get("web")
        if not c or not c.get("client_id"):
            say("not a Google OAuth client JSON (download it from Google Cloud > Credentials)")
            return 1
        CONF_DIR.mkdir(parents=True, exist_ok=True)
        GOOGLE_CLIENT.write_text(json.dumps(j, indent=2))
        os.chmod(GOOGLE_CLIENT, 0o600)
        say("Google OAuth client saved")
        return 0
    return 1


def cmd_login(a):          # old command: add a Microsoft work account
    return ms_login()


def cmd_whoami(a):
    rows = [(acc.get("label") or acc["id"], account_token(acc) is not None) for acc in accounts()]
    if not rows:
        print("not logged in")
        return 1
    for label, ok in rows:
        print(label + ("" if ok else " (login needed)"))
    return 0 if all(ok for _, ok in rows) else 1


def cmd_logout(a):         # old command: remove every account
    for acc in accounts():
        token_file(acc).unlink(missing_ok=True)
    save_accounts([])
    (CONF_DIR / "token.json").unlink(missing_ok=True)
    (CONF_DIR / "msal_cache.json").unlink(missing_ok=True)
    say("logged out")
    return 0


def cmd_now(a):
    """meetings going on now in every calendar (for the 'call detected' prompt)"""
    now_ = now()
    evs = [e for e in all_events(now_ - dt.timedelta(hours=2), now_ + dt.timedelta(minutes=15))
           if not e["all_day"] and e["_start"] - dt.timedelta(minutes=10) <= now_ <= e["_end"]]
    if a.json:
        print(json.dumps([{**plain_event(e), "label": describe(e)} for e in evs], ensure_ascii=False))
    else:
        for e in evs:
            print(describe(e))
    return 0


def cmd_events(a):
    day = dt.date.fromisoformat(a.date) if a.date else dt.date.today()
    s = dt.datetime.combine(day, dt.time(0)).astimezone()
    for e in all_events(s, s + dt.timedelta(days=1)):
        print(f"{'all day    ' if e['all_day'] else describe(e)[:11]} {e['subject']}  [{e['source']}"
              f"{' / ' + e['calendar'] if e.get('calendar') else ''}]  ({len(e.get('attendees', []))} attendees)")
    return 0


# ---------------------------------------------------------------- obsidian note

def slug_person(name):
    import unicodedata
    n = unicodedata.normalize("NFKD", name).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", "_", n).strip("_")


def people_links(event):
    vault, pdir = Path(C["vault"]), C["people_dir"]
    me = my_emails()
    out, seen = [], set()
    for x in [event.get("organizer") or {}] + event.get("attendees", []):
        name, mail = x.get("name") or "", (x.get("email") or "").lower()
        if not name or mail in me or ("@" in name and not mail):
            continue
        slug = slug_person(name)
        if slug in seen:
            continue
        seen.add(slug)
        if (vault / pdir / f"{slug}.md").exists():
            out.append(f"[[{pdir}/{slug}|{slug}]]")
        else:
            out.append(name)
    return out


def safe_filename(s):
    s = re.sub(r'[\\/:*?"<>|#^\[\]]+', " ", s)
    return re.sub(r"\s+", " ", s).strip()[:100] or "meeting"


def invite_agenda(event):
    """Text written in the invite, without the Teams/Zoom/Meet join block (links, meeting ID, passcode)."""
    t = (event or {}).get("agenda") or ""
    t = re.split(r"_{8,}|Microsoft Teams (?:meeting|Need help)|Riunione di Microsoft Teams|Join Zoom Meeting|"
                 r"Partecipa alla riunione Zoom|Join with Google Meet|Partecipa con Google Meet", t, maxsplit=1)[0]
    return re.sub(r"\s+", " ", t).strip()


def summarize(title, event, transcript_text):
    if not C["summary"] or not shutil.which(C["summary_cmd"][0]):
        return None, None
    agenda = invite_agenda(event)[:1500]
    prompt = f"""Sei l'assistente di {C['me']}. Qui sotto c'è la trascrizione automatica di un meeting.
Titolo dal calendario: {title}
Agenda dall'invito: {agenda or '(nessuna)'}

"{C['me']}" è il microfono di {C['me']}; "{C['others_label']}" sono tutti gli altri partecipanti (audio di sistema, non distinti tra loro).
La trascrizione contiene errori di riconoscimento: correggi i nomi tecnici evidenti, non inventare.

Rispondi in italiano, con questo formato esatto e niente altro:
RIASSUNTO: <una frase sola, max 25 parole, cosa si è discusso>
### Sintesi
<5-10 punti elenco>
### Decisioni
<punti elenco, oppure "Nessuna decisione esplicita.">
### Action item
<punti elenco "chi → cosa (scadenza se detta)", oppure "Nessuno.">
### Punti aperti
<punti elenco, oppure "Nessuno.">

TRASCRIZIONE:
{transcript_text}
"""
    say("summarizing with " + " ".join(C["summary_cmd"]))
    try:
        r = subprocess.run(C["summary_cmd"], input=prompt, capture_output=True, text=True, timeout=600, cwd="/tmp")
    except Exception as e:
        say(f"summary failed: {e}")
        return None, None
    if r.returncode:
        say(f"summary failed: {r.stderr[:300]}")
        return None, None
    text = r.stdout.strip()
    m = re.match(r"RIASSUNTO:\s*(.+)", text)
    one = m[1].strip() if m else None
    body = text[m.end():].strip() if m else text
    return one, body


def yq(s):
    return json.dumps(s, ensure_ascii=False)


def write_note(d, meta, event, turns, single_track, summary_line, summary_body):
    rec_start = dt.datetime.fromisoformat(meta["started_at"])
    rec_end = dt.datetime.fromisoformat(meta.get("stopped_at") or meta["started_at"])
    # the day of the meeting: what you typed for a manual event, else the recording day
    when = event["_start"] if event and event.get("manual") else rec_start
    title = (event or {}).get("subject") if event and event.get("manual") else None
    title = title or meta.get("title") or (event or {}).get("subject") or f"Meeting {rec_start:%H:%M}"
    if not C["vault"]:
        raise SystemExit(f"[meet] set 'vault' in {CONF_DIR / 'config.json'} (or in the MeetRec settings)")
    vault = Path(C["vault"])
    folder = vault / C["meetings_dir"] / when.strftime("%Y-%m")
    folder.mkdir(parents=True, exist_ok=True)
    base = f"{when:%Y-%m-%d} - {safe_filename(title)}"
    note = folder / f"{base}.md"
    prev = meta.get("note")
    if prev and Path(prev).exists():
        note = Path(prev)          # re-processing: update the same note
    else:
        i = 2
        while note.exists():
            note = folder / f"{base} ({i}).md"
            i += 1

    people = people_links(event) if event else []
    dur = int((rec_end - rec_start).total_seconds() // 60)
    summary_line = summary_line or f"Registrazione e trascrizione automatica del meeting \"{title}\"."
    fm = ["---", "type: meeting", f"context: {C['context']}", "status: done",
          f"summary: {yq(summary_line)}", f"date: {when:%Y-%m-%d}", f"created: {dt.date.today()}"]
    fm.append("people:" + ("" if people else " []"))
    fm += [f"  - {yq(p)}" for p in people]
    fm += ["tags: []", f"time: {yq(f'{rec_start:%H:%M}-{rec_end:%H:%M}')}", f"duration_min: {dur}",
           f"recording: {yq(str(d / 'mix.m4a'))}", "source: " + ("meetrec-import" if meta.get("source_file") else "meetrec")]
    if meta.get("voice_profile_applied"):
        fm.append(f"voice_profile: {meta['voice_profile_applied']}")
    if meta.get("source_file"):
        fm.append(f"source_file: {yq(meta['source_file'])}")
    if event:
        fm += [f"calendar_subject: {yq(event.get('subject', ''))}",
               "calendar_time: " + yq(f"{event['_start']:%H:%M}-{event['_end']:%H:%M}"),
               f"calendar_link: {yq(event.get('link', ''))}",
               f"calendar_source: {yq(event.get('source', ''))}"]
    fm.append("---")

    body = [f"# {title}", ""]
    if event:
        org = (event.get("organizer") or {}).get("name", "")
        att = ", ".join(x.get("name") or x.get("email", "") for x in event.get("attendees", []))
        manual = bool(event.get("manual"))
        head = f"> **{event.get('subject', '')}**, {event['_start']:%d/%m/%Y %H:%M}-{event['_end']:%H:%M}"
        if event.get("link"):
            head += f" ([apri nel calendario]({event['link']}))"
        if not manual and event.get("source"):
            head += f" · {event['source']}"
        body += ["> [!info] " + ("Dati del meeting (inseriti a mano)" if manual else "Dal calendario"), head]
        if org:
            body.append(f"> Organizzatore: {org}")
        if att:
            body.append(f"> {'Partecipanti' if manual else 'Invitati'}: {att}")
        agenda = invite_agenda(event)
        if agenda:
            body += ["> ", ("> **Agenda / note:** " if manual else "> **Agenda dall'invito:** ")
                     + re.sub(r"\s*\n\s*", " ", agenda)[:1200]]
        body.append("")
    else:
        body += ["_Nessun evento di calendario trovato per questo orario._", ""]
    altered = ""
    if meta.get("voice_profile_applied"):
        altered = (" Voce alterata (" + VOICE_PROFILES[meta["voice_profile_applied"]][0]
                   + (", solo la mia" if meta.get("voice_profile_scope") == "mine" and meta.get("record_system", True) else ", tutte le voci") + ").")
    body += [f"Registrazione: `{d / 'mix.m4a'}` ({dur} min, dalle {rec_start:%H:%M} alle {rec_end:%H:%M}).{altered}", ""]
    if meta.get("source_file"):
        body += [f"Importata dal file `{meta['source_file']}`.", ""]
    if summary_body:
        body += ["## Riassunto", "", "_Generato automaticamente dalla trascrizione: da verificare._", "",
                 summary_body, ""]
    who = ("traccia unica, interlocutori non separati" if single_track else
           f"**{C['me']}** = mio microfono, **{C['others_label']}** = audio degli altri partecipanti")
    body += ["## Trascrizione", "",
             f"_Trascrizione automatica locale (whisper large-v3-turbo); {who}._", "",
             transcript_md(turns, single_track) or "_(nessun parlato riconosciuto)_"]
    note.write_text("\n".join(fm) + "\n" + "\n".join(body) + "\n")
    return note


# ---------------------------------------------------------------- pipeline

def process(d):
    d = Path(d).expanduser().resolve()
    meta = read_json(d / "meta.json")
    if not meta:
        say(f"{d}: missing meta.json")
        return 1
    if not meta.get("stopped_at"):
        secs = max(track_seconds(d, "system"), track_seconds(d, "mic")) or probe_duration(d / "mix.m4a")
        meta["stopped_at"] = (dt.datetime.fromisoformat(meta["started_at"]) + dt.timedelta(seconds=secs)).isoformat(timespec="seconds")
        write_json(d / "meta.json", meta)
    tracks = build_audio(d)
    if not tracks:
        say("no audio found")
        return 1
    if opt(meta, "transcript_mode") == "mixed" and set(tracks) == {"mic", "system"}:
        # one transcript from the mix (speakers not separated), as chosen for this recording
        if not (d / "mix.segments.json").exists() and not (d / "mix.wav").exists():
            ff("-i", str(d / "mix.m4a"), "-ar", "16000", "-ac", "1", str(d / "mix.wav"))
        for n in tracks:
            (d / f"{n}.wav").unlink(missing_ok=True)
        tracks = ["mix"]
    segs = transcribe(d, tracks, meta.get("language") or C["language"])
    levels = {n: track_levels(d, n) for n in tracks}
    turns = merge(segs, levels)
    single = len(tracks) == 1
    (d / "transcript.md").write_text(transcript_md(turns, single))

    event = load_event(d)
    if event:
        say(f"calendar event: {describe(event)}")
        write_json(d / "event.json", plain_event(event))
    title = meta.get("title") or (event or {}).get("subject") or "meeting"
    plain = "\n".join(f"[{hms(t['start'])}] {t['speaker']}: {t['text']}" for t in turns)
    one, body = summarize(title, event, plain) if turns else (None, None)
    apply_voice_profile(d, meta)          # transcription was made on the original audio
    meta = read_json(d / "meta.json", meta)
    note = write_note(d, meta, event, turns, single, one, body)
    meta["note"] = str(note)
    meta["turns"] = len(turns)
    meta["tracks"] = tracks
    meta["processed_at"] = now().isoformat(timespec="seconds")
    write_json(d / "meta.json", meta)
    for n in tracks:
        (d / f"{n}.wav").unlink(missing_ok=True)
    # keep only the mix: transcriptions and levels are saved, so the note can be rebuilt without the tracks
    if not C.get("keep_tracks", False) and probe_duration(d / "mix.m4a") > 0:
        removed = [n for n in ("mic", "system") if (d / f"{n}.m4a").exists()]
        for n in removed:
            (d / f"{n}.m4a").unlink()
        if removed:
            say("separate tracks removed, mix.m4a kept")
    say(f"note: {note}")
    after_process_audio(d, meta)
    return 0


# ---------------------------------------------------------------- audio after the transcript

def opt(meta, key):
    """per-recording choice (meta.json), else the config default"""
    v = meta.get(key)
    return C[key] if v is None else v


def verify_processed(d):
    """(ok, reason): the note and the transcript really exist, so the audio can go"""
    meta = read_json(d / "meta.json", {})
    if not meta.get("processed_at"):
        return False, "not processed"
    note = Path(meta.get("note") or "")
    if not note.is_file():
        return False, f"note not found: {note}"
    text = note.read_text()
    if "## Trascrizione" not in text:
        return False, "the note has no transcript section"
    if int(meta.get("turns") or 0) <= 0 or not re.search(r"^`\d\d:\d\d:\d\d`", text, re.M):
        return False, "the transcript is empty"
    tr = d / "transcript.md"
    if not tr.is_file() or tr.stat().st_size == 0:
        return False, "transcript.md missing or empty"
    for n in meta.get("tracks") or []:
        if not (d / f"{n}.segments.json").is_file():
            return False, f"saved transcription of {n} missing"
    return True, f"{meta['turns']} transcript lines in {note.name}"


def drop_audio(d):
    d = Path(d).expanduser().resolve()
    ok, why = verify_processed(d)
    if not ok:
        say(f"audio kept: {why}")
        return 1
    meta = read_json(d / "meta.json", {})
    secs = probe_duration(d / "mix.m4a")
    for pat in ("*.m4a", "*.wav", "*.s16"):
        for f in d.glob(pat):
            f.unlink()
    note = Path(meta["note"])
    today = dt.date.today()
    text = note.read_text()
    text = re.sub(r'^recording: .*$', f'recording: ""\naudio_deleted: {today}', text, count=1, flags=re.M)
    text = re.sub(r"^Registrazione: `.*$",
                  f"Audio eliminato dopo la trascrizione il {today:%d/%m/%Y} ({secs / 60:.0f} min).", text, count=1, flags=re.M)
    note.write_text(text)
    meta["audio_deleted_at"] = now().isoformat(timespec="seconds")
    write_json(d / "meta.json", meta)
    say(f"audio deleted ({why}); transcript and note kept")
    return 0


def after_process_audio(d, meta):
    policy = opt(meta, "after_process_audio")
    if policy == "delete":
        drop_audio(d)
    elif policy == "ask" and sys.stdin.isatty():
        ok, why = verify_processed(d)
        if not ok:
            say(f"audio kept: {why}")
            return
        ans = input(f"Transcript OK ({why}). Delete the audio? [y/N] > ").strip().lower()
        if ans in ("y", "s", "yes", "si", "sì"):
            drop_audio(d)


def cmd_verify(a):
    ok, why = verify_processed(Path(a.dir).expanduser().resolve())
    print(("OK: " if ok else "NOT OK: ") + why)
    return 0 if ok else 1


def cmd_drop_audio(a):
    return drop_audio(a.dir)


# ---------------------------------------------------------------- voice profiles
#
# Alter the voice in the saved audio so a listener cannot tell who spoke, while the words stay
# clear (whisper still got 89-96% of the same words on a real call). Transcription is made on the
# original audio first; the original is then replaced. Profiles 1-2 only shift pitch and formants
# (partly reversible); 3 (robot) and 4 (radio) throw information away and are harder to undo.

# every profile: low cut before, loudness normalisation and a limiter after, so the altered voice is
# as loud and clear as a normal one (the first version lost up to 13 dB and sounded far away)
_PRE = "highpass=f=90,aresample=48000"
_POST = "dynaudnorm=f=150:g=15:p=0.9:m=20,alimiter=limit=0.89:level=false"

VOICE_PROFILES = {
    "p1": ("Profile 1: higher", f"{_PRE},asetrate=48000*1.19,aresample=48000,atempo=1/1.19,afreqshift=shift=40,{_POST}"),
    "p2": ("Profile 2: deeper", f"{_PRE},asetrate=48000*0.84,aresample=48000,atempo=1/0.84,afreqshift=shift=-40,"
                                f"chorus=0.5:0.9:30:0.25:0.2:1.5,{_POST}"),
    "p3": ("Profile 3: robot", f"{_PRE},afftfilt=real='hypot(re,im)':imag='0':win_size=1024:overlap=0.75,"
                               f"asetrate=48000*1.12,aresample=48000,atempo=1/1.12,{_POST}"),
    "p4": ("Profile 4: radio", f"{_PRE},asetrate=48000*1.2,aresample=48000,atempo=1/1.2,bandpass=f=1850:width_type=h:w=3100,"
                               f"vibrato=f=5:d=0.1,acrusher=bits=12:mode=log:aa=1,{_POST}"),
}
NORMALIZE = f"{_PRE},{_POST}"      # the original in voice-test, for a fair comparison


def alter(src, dst, profile):
    ff("-i", str(src), "-af", VOICE_PROFILES[profile][1], "-c:a", "aac", "-b:a", "96k", str(dst))


def replace_checked(new, old):
    """replace old with new only if the durations match (never lose audio to a failed filter)"""
    if abs(probe_duration(new) - probe_duration(old)) > 3:
        new.unlink(missing_ok=True)
        say(f"voice profile: duration mismatch on {old.name}, original kept")
        return False
    new.replace(old)
    return True


def apply_voice_profile(d, meta):
    profile = opt(meta, "voice_profile")
    if profile not in VOICE_PROFILES or meta.get("voice_profile_applied") == profile:
        return
    scope = opt(meta, "voice_profile_scope")
    mic, system, mix = d / "mic.m4a", d / "system.m4a", d / "mix.m4a"
    if scope == "mine" and mic.exists() and system.exists():
        alter(mic, d / "mic.alt.m4a", profile)
        ff("-i", str(d / "mic.alt.m4a"), "-i", str(system), "-filter_complex",
           "[0:a]aresample=48000[a];[1:a]aresample=48000[b];[a][b]amix=inputs=2:normalize=0",
           "-c:a", "aac", "-b:a", "96k", str(d / "mix.alt.m4a"))
        ok = replace_checked(d / "mix.alt.m4a", mix)
        if ok:
            replace_checked(d / "mic.alt.m4a", mic)
        else:
            (d / "mic.alt.m4a").unlink(missing_ok=True)
    else:
        # my voice only (no system track) or every voice, or an imported file: the whole mix
        alter(mix, d / "mix.alt.m4a", profile)
        ok = replace_checked(d / "mix.alt.m4a", mix)
        for t in (mic, system):
            if ok and t.exists():
                alter(t, d / f"{t.stem}.alt.m4a", profile)
                replace_checked(d / f"{t.stem}.alt.m4a", t)
    if ok:
        meta["voice_profile_applied"] = profile
        write_json(d / "meta.json", meta)
        say(f"voice altered in the saved audio: {VOICE_PROFILES[profile][0]} ({'my voice' if scope == 'mine' else 'all voices'})")


def cmd_voice_test(a):
    """record a few seconds from the mic, then play the original and the profile"""
    import tempfile
    if a.profile not in VOICE_PROFILES:
        say(f"profiles: {', '.join(VOICE_PROFILES)}")
        return 1
    t = Path(tempfile.mkdtemp(prefix="meetrec-voice-"))
    cmd = [C["capture_bin"], str(t / "r"), "--no-system"] + (["--mic-id", C["mic_id"]] if C.get("mic_id") else [])
    say(f"speak now: recording {a.seconds} seconds…")
    p = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(a.seconds)
    p.send_signal(signal.SIGINT)
    p.wait(timeout=10)
    raw = sorted((t / "r").glob("mic*.json"))
    if not raw:
        say("no audio recorded (microphone permission?)")
        return 1
    m = read_json(raw[0])
    ff("-f", "s16le", "-ar", str(m["sample_rate"]), "-ac", "1", "-i", str(raw[0].with_suffix(".s16")), str(t / "raw.wav"))
    ff("-i", str(t / "raw.wav"), "-af", NORMALIZE, str(t / "orig.wav"))
    ff("-i", str(t / "raw.wav"), "-af", VOICE_PROFILES[a.profile][1], str(t / "alt.wav"))
    if m["sample_rate"] <= 24000:
        say(f"note: the microphone records at {m['sample_rate'] // 1000} kHz (Bluetooth headset in call mode): "
            "low quality; for a better result use the Mac microphone")
    time.sleep(2)            # give Bluetooth headphones time to leave call mode before playing
    say("original…")
    subprocess.run(["afplay", str(t / "orig.wav")])
    say(f"{VOICE_PROFILES[a.profile][0]}…")
    subprocess.run(["afplay", str(t / "alt.wav")])
    shutil.rmtree(t)
    return 0


def file_start_time(src, duration):
    """When the audio was recorded: creation_time tag if present, else file mtime minus duration."""
    r = subprocess.run([C["ffmpeg"], "-hide_banner", "-i", str(src)], capture_output=True, text=True)
    m = re.search(r"creation_time\s*:\s*(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)", r.stderr)
    if m:
        t = dt.datetime.fromisoformat(m[1]).replace(tzinfo=dt.timezone.utc).astimezone()
        if t.year > 2000:
            return t, "creation_time"
    end = dt.datetime.fromtimestamp(src.stat().st_mtime).astimezone()
    return end - dt.timedelta(seconds=duration), "file date"


def cmd_import(a):
    src = Path(a.file).expanduser().resolve()
    if not src.is_file():
        say(f"file not found: {src}")
        return 1
    secs = probe_duration(src)
    if secs <= 0:
        say(f"not an audio file ffmpeg can read: {src}")
        return 1
    if a.at:
        start, how = dt.datetime.fromisoformat(a.at).astimezone(), "--at"
    else:
        start, how = file_start_time(src, secs)
    say(f"importing {src.name}: {secs / 60:.0f} min, recorded {start:%Y-%m-%d %H:%M} ({how})")
    d = Path(C["recordings_dir"]) / f"{start:%Y-%m-%d_%H%M%S}-import"
    i = 2
    while d.exists():
        d = Path(C["recordings_dir"]) / f"{start:%Y-%m-%d_%H%M%S}-import{i}"
        i += 1
    d.mkdir(parents=True)
    # the original stays untouched: keep an m4a copy next to the other recordings
    ff("-i", str(src), "-vn", "-c:a", "aac", "-b:a", "96k", str(d / "mix.m4a"))
    write_json(d / "meta.json", {
        "started_at": start.isoformat(timespec="seconds"),
        "stopped_at": (start + dt.timedelta(seconds=secs)).isoformat(timespec="seconds"),
        "title": a.title, "language": a.lang or C["language"], "source_file": str(src),
        "voice_profile": C["voice_profile"], "voice_profile_scope": "all"})
    say(f"recording folder -> {d}")
    if a.no_process:
        return 0
    if sys.stdin.isatty():
        ask_event(d)
    return process(d)


def cmd_process(a):
    return process(a.dir)


def cmd_recover(a):
    root = Path(C["recordings_dir"])
    cur = read_json(CURRENT) or {}
    items = []
    for d in sorted(root.glob("*/")):
        m = read_json(d / "meta.json", {})
        if m.get("processed_at") or str(d).rstrip("/") == cur.get("dir", "").rstrip("/"):
            continue
        items.append({"dir": str(d).rstrip("/"), "duration": duration_str(d), "title": m.get("title"),
                      "started_at": m.get("started_at")})
    if a.json:
        print(json.dumps(items))
        return 0
    for it in items:
        print(f"{it['dir']}  [{it['duration']}]  title={it['title']!r}  -> meet process '{it['dir']}'")
    if not items:
        say("nothing to recover")
    return 0


def cmd_mics(a):
    return subprocess.call([C["capture_bin"], "--list-mics"])


def app_version():
    """VERSION next to meet.py (repo, or Contents/Resources in the app)"""
    f = APP_DIR / "VERSION"
    return f.read_text().strip() if f.exists() else "dev"


def main():
    p = argparse.ArgumentParser(prog="meet", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--version", action="version", version=f"MeetRec {app_version()}")
    sub = p.add_subparsers(dest="cmd", required=True)
    for name in ("start", "rec"):
        s = sub.add_parser(name)
        s.add_argument("-t", "--title", help="title (default: from Outlook calendar)")
        s.add_argument("-l", "--lang", help="language, default from config (it)")
        s.add_argument("--no-mic", action="store_true", help="system audio only")
        s.add_argument("--mic-only", action="store_true", help="record only my voice (no system audio)")
        s.add_argument("--with-system", action="store_true", help="record my voice and the system audio")
        s.add_argument("--transcript", choices=["separate", "mixed"], help="separate (me / others) or mixed")
        s.add_argument("--voice-profile", choices=["none"] + list(VOICE_PROFILES), help="alter the voice in the saved audio")
        s.add_argument("--voice-scope", choices=["mine", "all"], help="voice profile on my voice only, or on all voices")
    s = sub.add_parser("stop")
    s.add_argument("--no-process", action="store_true")
    s.add_argument("--discard", action="store_true", help="stop and delete the recording")
    s = sub.add_parser("discard", help="delete a recording folder (e.g. one listed by meet recover)")
    s.add_argument("dir")
    sub.add_parser("status")
    s = sub.add_parser("import", help="process an existing audio file (mp3, wav, m4a, …)")
    s.add_argument("file")
    s.add_argument("-t", "--title", help="title (default: from the Outlook event at the file time)")
    s.add_argument("--at", help='when it was recorded, "YYYY-MM-DD HH:MM" (default: from the file)')
    s.add_argument("-l", "--lang", help="language, default from config")
    s.add_argument("--no-process", action="store_true", help="only copy the audio (the app asks for the event first)")
    s = sub.add_parser("process")
    s.add_argument("dir")
    s = sub.add_parser("recover")
    s.add_argument("--json", action="store_true")
    s = sub.add_parser("candidates", help="calendar events overlapping a recording")
    s.add_argument("dir")
    s.add_argument("--json", action="store_true")
    s = sub.add_parser("choose", help="pick the event for a recording: number from candidates, none, "
                                      "or manual --title … [--start ISO --end ISO --people … --agenda …]")
    s.add_argument("dir")
    s.add_argument("choice")
    s.add_argument("--title")
    s.add_argument("--start", help="ISO date-time, default: recording start")
    s.add_argument("--end", help="ISO date-time, default: recording end")
    s.add_argument("--people", help="comma separated names or emails")
    s.add_argument("--agenda")
    s = sub.add_parser("accounts", help="calendar accounts")
    s.add_argument("--json", action="store_true")
    s = sub.add_parser("account", help="account add microsoft | google | macos; account remove ID; "
                                       "account google-client FILE.json")
    s.add_argument("action", choices=["add", "remove", "google-client"])
    s.add_argument("provider", nargs="?", help="microsoft | google | macos (add), FILE (google-client)")
    s.add_argument("id", nargs="?")
    sub.add_parser("login")
    sub.add_parser("logout")
    sub.add_parser("whoami")
    s = sub.add_parser("now", help="meetings going on now in every calendar")
    s.add_argument("--json", action="store_true")
    s = sub.add_parser("events")
    s.add_argument("date", nargs="?")
    sub.add_parser("mics")
    s = sub.add_parser("verify", help="check that a recording was processed correctly (note + transcript)")
    s.add_argument("dir")
    s = sub.add_parser("drop-audio", help="delete the audio of a processed recording (only if verify is OK)")
    s.add_argument("dir")
    s = sub.add_parser("voice-test", help="record a few seconds and play them with a voice profile")
    s.add_argument("profile")
    s.add_argument("--seconds", type=int, default=5)
    a = p.parse_args()
    return {"start": cmd_start, "rec": cmd_rec, "stop": cmd_stop, "discard": cmd_discard, "status": cmd_status, "process": cmd_process, "import": cmd_import,
            "recover": cmd_recover, "candidates": cmd_candidates, "choose": cmd_choose,
            "accounts": cmd_accounts, "now": cmd_now, "account": cmd_account, "login": cmd_login, "logout": cmd_logout, "whoami": cmd_whoami, "events": cmd_events, "mics": cmd_mics,
            "verify": cmd_verify, "drop-audio": cmd_drop_audio, "voice-test": cmd_voice_test}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main() or 0)
