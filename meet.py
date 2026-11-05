#!/usr/bin/env python3
"""meet: record meetings from the CLI, transcribe locally with Vibe, link to Outlook, save to Obsidian.

  meet start [-t TITLE]     start recording in background (mic + system audio)
  meet stop [--no-process]  stop and process (transcript + note)
  meet rec [-t TITLE]       foreground: record until Ctrl-C, then process
  meet status               current recording
  meet process DIR          (re)process a recording folder
  meet recover              list recordings never processed (e.g. after a crash)
  meet login / logout / whoami   Microsoft login for the calendar (Calendars.Read)
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
import urllib.parse
import urllib.request
from pathlib import Path

HOME = Path.home()
APP_DIR = Path(__file__).resolve().parent
CONF_DIR = HOME / ".config" / "meetrec"
STATE_DIR = HOME / ".local" / "state" / "meetrec"
CURRENT = STATE_DIR / "current.json"
VIBE_SUPPORT = HOME / "Library/Application Support/github.com.thewh1teagle.vibe"

DEFAULTS = {
    "recordings_dir": str(HOME / "Recordings" / "meetings"),
    "vault": "",                                       # Obsidian vault (required)
    "meetings_dir": "Meetings",                        # relative to the vault, + /YYYY-MM/
    "people_dir": "People",                            # person notes, linked by nome_cognome.md
    "context": "work",                                 # frontmatter `context:`
    "language": "it",
    "me": "Me",                                        # label for the mic track
    "others_label": "Altri",                           # label for the system-audio track
    "vibe_bin": "/Applications/vibe.app/Contents/MacOS/vibe",
    "vibe_model": str(VIBE_SUPPORT / "ggml-large-v3-turbo.bin"),
    "ffmpeg": shutil.which("ffmpeg") or "/opt/homebrew/bin/ffmpeg",
    "capture_bin": str(APP_DIR / "capture" / "meetrec-capture"),
    "mic_id": None,
    "auto_gain": True,                                 # lower the mic input volume when it clips
    "summary": True,
    "summary_cmd": ["claude", "-p", "--model", "sonnet"],
    "keep_raw": False,
    "keep_tracks": False,                              # keep mic.m4a/system.m4a after processing (mix.m4a is always kept)
    # Microsoft Graph (calendar). Same public client used by the ms365 MCP server.
    "ms_client_id": "084a3e9f-a9f4-43f7-89f9-d229cf97853e",
    "ms_authority": "https://login.microsoftonline.com/organizations",
    "timezone": "Europe/Rome",
}


USER_KEYS = ["recordings_dir", "vault", "meetings_dir", "people_dir", "context", "language", "me",
             "others_label", "mic_id", "auto_gain", "summary", "keep_raw", "keep_tracks"]


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
            "language": a.lang or C["language"]}
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


def cmd_stop(a):
    d = stop_capture()
    if d and not a.no_process:
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


# ---------------------------------------------------------------- calendar (Microsoft Graph)

def msal_app():
    import msal
    cache = msal.SerializableTokenCache()
    cf = CONF_DIR / "msal_cache.json"
    if cf.exists():
        cache.deserialize(cf.read_text())
    app = msal.PublicClientApplication(C["ms_client_id"], authority=C["ms_authority"], token_cache=cache)
    return app, cache, cf


def save_cache(cache, cf):
    if cache.has_state_changed:
        CONF_DIR.mkdir(parents=True, exist_ok=True)
        cf.write_text(cache.serialize())
        os.chmod(cf, 0o600)


SCOPES = ["Calendars.Read"]


def cmd_login(a):
    app, cache, cf = msal_app()
    flow = app.initiate_device_flow(scopes=SCOPES)
    if "user_code" not in flow:
        say(f"device flow failed: {flow.get('error_description')}")
        return 1
    print(flow["message"], flush=True)
    res = app.acquire_token_by_device_flow(flow)
    save_cache(cache, cf)
    if "access_token" in res:
        say(f"logged in as {res.get('id_token_claims', {}).get('preferred_username')}")
        return 0
    say(f"login failed: {res.get('error')}: {res.get('error_description')}")
    return 1


def graph_token():
    try:
        app, cache, cf = msal_app()
    except ImportError:
        return None
    accts = app.get_accounts()
    if not accts:
        return None
    res = app.acquire_token_silent(SCOPES, account=accts[0])
    save_cache(cache, cf)
    return res.get("access_token") if res else None


def graph_events(start, end):
    tok = graph_token()
    if not tok:
        say("calendar: not logged in (run: meet login) - skipping")
        return None
    q = urllib.parse.urlencode({
        "startDateTime": start.isoformat(), "endDateTime": end.isoformat(),
        "$select": "subject,start,end,organizer,attendees,bodyPreview,webLink,onlineMeeting,isAllDay,isCancelled,showAs,location",
        "$orderby": "start/dateTime", "$top": "50"})
    req = urllib.request.Request("https://graph.microsoft.com/v1.0/me/calendarView?" + q, headers={
        "Authorization": f"Bearer {tok}", "Prefer": f'outlook.timezone="{C["timezone"]}"'})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return json.loads(r.read())["value"]
    except Exception as e:
        say(f"calendar: request failed ({e}) - skipping")
        return None


def parse_graph_dt(x):
    from zoneinfo import ZoneInfo
    s = x["dateTime"][:19]
    return dt.datetime.fromisoformat(s).replace(tzinfo=ZoneInfo(C["timezone"]))


def match_event(rec_start, rec_end):
    evs = graph_events(rec_start - dt.timedelta(hours=3), rec_end + dt.timedelta(hours=1))
    if not evs:
        return None
    best, best_score = None, 0.0
    for e in evs:
        if e.get("isAllDay") or e.get("isCancelled"):
            continue
        es, ee = parse_graph_dt(e["start"]), parse_graph_dt(e["end"])
        overlap = (min(ee, rec_end) - max(es, rec_start)).total_seconds()
        # also accept a recording started a bit early
        if overlap <= 0 and abs((es - rec_start).total_seconds()) > 600:
            continue
        score = overlap - abs((es - rec_start).total_seconds()) / 10
        if best is None or score > best_score:
            best, best_score = e, score
    if best:
        best["_start"], best["_end"] = parse_graph_dt(best["start"]), parse_graph_dt(best["end"])
    return best


def cmd_events(a):
    from zoneinfo import ZoneInfo
    day = dt.date.fromisoformat(a.date) if a.date else dt.date.today()
    tz = ZoneInfo(C["timezone"])
    s = dt.datetime.combine(day, dt.time(0), tz)
    evs = graph_events(s, s + dt.timedelta(days=1))
    if evs is None:
        return 1
    for e in evs:
        print(f"{e['start']['dateTime'][11:16]}-{e['end']['dateTime'][11:16]}  {e['subject']}"
              f"  ({len(e.get('attendees', []))} invitati)")
    return 0


# ---------------------------------------------------------------- obsidian note

def slug_person(name):
    import unicodedata
    n = unicodedata.normalize("NFKD", name).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", "_", n).strip("_")


def people_links(event):
    vault, pdir = Path(C["vault"]), C["people_dir"]
    me = graph_me_email()
    out, seen = [], set()
    entries = [event.get("organizer", {})] + event.get("attendees", [])
    for x in entries:
        ea = x.get("emailAddress", {})
        name, mail = ea.get("name") or "", (ea.get("address") or "").lower()
        if not name or (me and mail == me) or "@" in name and not mail:
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


def graph_me_email():
    try:
        app, _, _ = msal_app()
        accts = app.get_accounts()
        return accts[0]["username"].lower() if accts else None
    except Exception:
        return None


def safe_filename(s):
    s = re.sub(r'[\\/:*?"<>|#^\[\]]+', " ", s)
    return re.sub(r"\s+", " ", s).strip()[:100] or "meeting"


def summarize(title, event, transcript_text):
    if not C["summary"] or not shutil.which(C["summary_cmd"][0]):
        return None, None
    agenda = (event or {}).get("bodyPreview", "")[:1500]
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
    title = meta.get("title") or (event or {}).get("subject") or f"Meeting {rec_start:%H:%M}"
    if not C["vault"]:
        raise SystemExit(f"[meet] set 'vault' in {CONF_DIR / 'config.json'} (or in the MeetRec settings)")
    vault = Path(C["vault"])
    folder = vault / C["meetings_dir"] / rec_start.strftime("%Y-%m")
    folder.mkdir(parents=True, exist_ok=True)
    base = f"{rec_start:%Y-%m-%d} - {safe_filename(title)}"
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
          f"summary: {yq(summary_line)}", f"date: {rec_start:%Y-%m-%d}", f"created: {dt.date.today()}"]
    fm.append("people:" + ("" if people else " []"))
    fm += [f"  - {yq(p)}" for p in people]
    fm += ["tags: []", f"time: {yq(f'{rec_start:%H:%M}-{rec_end:%H:%M}')}", f"duration_min: {dur}",
           f"recording: {yq(str(d / 'mix.m4a'))}", "source: meetrec"]
    if event:
        fm += [f"calendar_subject: {yq(event.get('subject', ''))}",
               "calendar_time: " + yq(f"{event['_start']:%H:%M}-{event['_end']:%H:%M}"),
               f"calendar_link: {yq(event.get('webLink', ''))}"]
    fm.append("---")

    body = [f"# {title}", ""]
    if event:
        org = event.get("organizer", {}).get("emailAddress", {}).get("name", "")
        att = ", ".join(a["emailAddress"].get("name", "") for a in event.get("attendees", []))
        body += ["> [!info] Dal calendario",
                 f"> **{event.get('subject', '')}**, {event['_start']:%d/%m/%Y %H:%M}-{event['_end']:%H:%M}"
                 f" ([apri in Outlook]({event.get('webLink', '')}))",
                 f"> Organizzatore: {org}", f"> Invitati: {att}"]
        agenda = (event.get("bodyPreview") or "").strip()
        if agenda:
            body += ["> ", "> **Agenda dall'invito:** " + re.sub(r"\s*\n\s*", " ", agenda)[:1200]]
        body.append("")
    else:
        body += ["_Nessun evento di calendario trovato per questo orario._", ""]
    body += [f"Registrazione: `{d / 'mix.m4a'}` ({dur} min, dalle {rec_start:%H:%M} alle {rec_end:%H:%M}).", ""]
    if summary_body:
        body += ["## Riassunto", "", "_Generato automaticamente dalla trascrizione: da verificare._", "",
                 summary_body, ""]
    who = ("traccia unica, interlocutori non separati" if single_track else
           f"**{C['me']}** = mio microfono, **{C['others_label']}** = audio degli altri partecipanti")
    body += ["## Trascrizione", "",
             f"_Trascrizione automatica locale (Vibe, whisper large-v3-turbo); {who}._", "",
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
    segs = transcribe(d, tracks, meta.get("language") or C["language"])
    levels = {n: track_levels(d, n) for n in tracks}
    turns = merge(segs, levels)
    single = len(tracks) == 1
    (d / "transcript.md").write_text(transcript_md(turns, single))

    rec_start = dt.datetime.fromisoformat(meta["started_at"])
    rec_end = dt.datetime.fromisoformat(meta["stopped_at"])
    event = match_event(rec_start, rec_end)
    if event:
        say(f"calendar match: {event['subject']} ({event['_start']:%H:%M}-{event['_end']:%H:%M})")
        write_json(d / "event.json", {k: v for k, v in event.items() if not k.startswith("_")})
    title = meta.get("title") or (event or {}).get("subject") or "meeting"
    plain = "\n".join(f"[{hms(t['start'])}] {t['speaker']}: {t['text']}" for t in turns)
    one, body = summarize(title, event, plain) if turns else (None, None)
    note = write_note(d, meta, event, turns, single, one, body)
    meta["note"] = str(note)
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
    return 0


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


def cmd_whoami(a):
    try:
        app, _, _ = msal_app()
    except ImportError:
        print("msal not installed")
        return 1
    accts = app.get_accounts()
    if not accts:
        print("not logged in")
        return 1
    ok = graph_token() is not None
    print(accts[0]["username"] + ("" if ok else " (token expired: run meet login)"))
    return 0 if ok else 1


def cmd_logout(a):
    (CONF_DIR / "msal_cache.json").unlink(missing_ok=True)
    say("logged out")
    return 0


def cmd_mics(a):
    return subprocess.call([C["capture_bin"], "--list-mics"])


def main():
    p = argparse.ArgumentParser(prog="meet", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    for name in ("start", "rec"):
        s = sub.add_parser(name)
        s.add_argument("-t", "--title", help="title (default: from Outlook calendar)")
        s.add_argument("-l", "--lang", help="language, default from config (it)")
        s.add_argument("--no-mic", action="store_true", help="system audio only")
    s = sub.add_parser("stop")
    s.add_argument("--no-process", action="store_true")
    sub.add_parser("status")
    s = sub.add_parser("process")
    s.add_argument("dir")
    s = sub.add_parser("recover")
    s.add_argument("--json", action="store_true")
    sub.add_parser("login")
    sub.add_parser("logout")
    sub.add_parser("whoami")
    s = sub.add_parser("events")
    s.add_argument("date", nargs="?")
    sub.add_parser("mics")
    a = p.parse_args()
    return {"start": cmd_start, "rec": cmd_rec, "stop": cmd_stop, "status": cmd_status, "process": cmd_process,
            "recover": cmd_recover, "login": cmd_login, "logout": cmd_logout, "whoami": cmd_whoami, "events": cmd_events, "mics": cmd_mics}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main() or 0)
