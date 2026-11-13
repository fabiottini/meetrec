"""End-to-end test of meet.py without a microphone: import an audio file, transcribe it, write the note,
check it, cut it afterwards, list, delete the audio; plus start/stop of a fake recorder.
Runs the same on macOS and Windows (CI). Needs ffmpeg, whisper-cli and a model.

  python scripts/test_core.py AUDIO.wav --whisper PATH --model PATH [--vad PATH] [--word release]
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile
import textwrap
import time
from pathlib import Path

for _s in (sys.stdout, sys.stderr):                    # Windows console: cp1252 cannot print → or …
    try:
        _s.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

ROOT = Path(__file__).resolve().parent.parent
MEET = ROOT / "meet.py"
failures = []


def check(cond, what):
    print(("  ok    " if cond else "  FAIL  ") + what, flush=True)
    if not cond:
        failures.append(what)


def meet(*args, env):
    r = subprocess.run([sys.executable, str(MEET), *args], capture_output=True, text=True,
                       encoding="utf-8", errors="replace", env=env, stdin=subprocess.DEVNULL)
    print(textwrap.indent((r.stdout + r.stderr).strip(), "    | "), flush=True)
    return r


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("audio")
    ap.add_argument("--whisper", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--vad", default="")
    ap.add_argument("--word", default="release", help="a word that must be in the transcript")
    a = ap.parse_args()

    tmp = Path(tempfile.mkdtemp(prefix="meetrec-test-"))
    vault = tmp / "vault"
    vault.mkdir()
    conf = {"recordings_dir": str(tmp / "recs"), "vault": str(vault), "meetings_dir": "Meetings",
            "summary": False, "language": "en", "after_process_audio": "keep", "voice_profile": "none",
            "whisper_bin": a.whisper, "whisper_model": a.model, "vad_model": a.vad or str(tmp / "none"),
            "calendar_accounts": []}
    (tmp / "conf.json").write_text(json.dumps(conf), encoding="utf-8")
    # MEETREC_CONF_DIR: tokens and API keys of the test never touch your real config folder
    env = dict(os.environ, MEETREC_CONF=str(tmp / "conf.json"), MEETREC_CONF_DIR=str(tmp / "confdir"), PYTHONUTF8="1")

    print("== version")
    check(meet("--version", env=env).stdout.startswith("MeetRec"), "meet --version")

    print("== import (title with accents and symbols)")
    title = "Riunione è più → test…"
    r = meet("import", a.audio, "--at", "2026-11-09 10:00", "-t", title, "--no-process", env=env)
    rec = next((tmp / "recs").glob("*-import"), None)
    check(r.returncode == 0 and rec is not None and (rec / "mix.m4a").exists(), "import copies the audio")
    meet("choose", str(rec), "manual", "--title", title, "--people", "Jane Doe, mark@example.com", env=env)

    print("== process (whisper.cpp)")
    r = meet("process", str(rec), env=env)
    notes = list(vault.rglob("*.md"))
    check(r.returncode == 0 and len(notes) == 1, "process writes one note")
    text = notes[0].read_text(encoding="utf-8") if notes else ""
    check("## Transcript" in text, "note in English (meeting language en)")
    check(a.word.lower() in text.lower(), f"transcript contains '{a.word}'")
    check(title in text and "Jane Doe" in text, "accents, symbols and attendees survive (UTF-8)")

    print("== verify, peaks, list")
    check(meet("verify", str(rec), env=env).returncode == 0, "verify OK")
    r = meet("peaks", str(rec), "--n", "20", env=env)
    try:
        pk = json.loads(r.stdout.strip().splitlines()[-1])
        check(pk["duration"] > 1 and len(pk["peaks"]) >= 10, "peaks for the editor")
    except Exception:
        check(False, "peaks for the editor")
    check(rec.name in meet("list", env=env).stdout, "list shows the recording")

    print("== edit afterwards (no new transcription)")
    before = len(text)
    r = meet("edit", str(rec), "0:00.5-0:01.5", env=env)
    check(r.returncode == 0 and "transcribing" not in r.stdout, "edit cuts without transcribing again")
    after = notes[0].read_text(encoding="utf-8")
    check("cut after the transcript" in after.lower(), "note says the audio was cut")

    print("== delete the audio after the check")
    r = meet("drop-audio", str(rec), env=env)
    check(r.returncode == 0 and not (rec / "mix.m4a").exists(), "audio deleted, note kept")

    print("== recorder start/stop protocol (fake recorder)")
    fake = tmp / "fake_recorder.py"
    fake.write_text(textwrap.dedent('''
        import sys, time, pathlib
        d = pathlib.Path(sys.argv[1]); d.mkdir(parents=True, exist_ok=True)
        print("recording started", flush=True)
        while not (d / "stop.request").exists():
            time.sleep(0.1)
        (d / "capture.done").write_text("")
    '''), encoding="utf-8")
    sys.path.insert(0, str(ROOT))
    os.environ["MEETREC_CONF"] = str(tmp / "conf.json")
    os.environ["MEETREC_CONF_DIR"] = str(tmp / "confdir")
    import meet as m                                                   # noqa: E402
    check(m.pid_alive(os.getpid()) and not m.pid_alive(999999), "pid_alive")
    d = tmp / "fake"
    d.mkdir()
    with open(d / "log", "ab") as logf:
        p = m.spawn_detached([sys.executable, str(fake), str(d)], logf)
    time.sleep(1.5)
    check(m.pid_alive(p.pid), "detached recorder is running")
    if m.IS_WIN:
        stopped = m.stop_recorder(p.pid, d, wait=10)
        check(stopped and (d / "capture.done").exists(), "stop request: the recorder stops by itself")
    else:
        (d / "stop.request").write_text("stop")             # the macOS recorder uses SIGINT; same file test
        p.wait(timeout=5)                                    # reap it (a finished child is a zombie until then)
        check(not m.pid_alive(p.pid) and (d / "capture.done").exists(), "fake recorder stopped")

    print("== AI providers (local fake API, no real calls)")
    import http.server
    import threading
    seen = []

    class FakeAPI(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers["content-length"])))
            seen.append((self.path, self.headers.get("authorization") or self.headers.get("x-api-key"), body))
            out = ({"content": [{"type": "text", "text": "OK"}], "stop_reason": "end_turn"} if self.path.endswith("/messages")
                   else {"choices": [{"message": {"content": "OK"}}]})
            data = json.dumps(out).encode()
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *a):
            pass

    srv = http.server.HTTPServer(("127.0.0.1", 0), FakeAPI)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{srv.server_port}"
    conf_path = tmp / "conf.json"
    base_conf = json.loads(conf_path.read_text(encoding="utf-8"))

    def with_ai(**kw):
        conf_path.write_text(json.dumps({**base_conf, **kw}), encoding="utf-8")

    with_ai(ai_provider="openai-compatible", ai_base_url=url + "/v1", ai_model="llama3")
    r = meet("ai", "test", env=env)
    check(r.returncode == 0 and "OK" in r.stdout + r.stderr and seen and seen[-1][0] == "/v1/chat/completions",
          "openai-compatible provider")
    with_ai(ai_provider="anthropic", ai_base_url=url)
    r = subprocess.run([sys.executable, str(ROOT / "meet.py"), "ai", "key", "anthropic"], input="sk-test-key-123\n",
                       capture_output=True, text=True, encoding="utf-8", env=env)
    check(r.returncode == 0 and "sk-test-key-123" not in r.stdout + r.stderr, "API key stored, never printed")
    r = meet("ai", "test", env=env)
    check(r.returncode == 0 and seen[-1][0] == "/v1/messages" and seen[-1][1] == "sk-test-key-123"
          and "temperature" not in seen[-1][2], "anthropic provider")
    meet("ai", "key", "anthropic", "--delete", env=env)
    with_ai(ai_provider="none")
    r = meet("ai", "--json", env=env)
    check(json.loads(r.stdout.strip().splitlines()[-1])["ready"] is False, "AI off")
    with_ai()
    srv.shutdown()

    print()
    if failures:
        print(f"{len(failures)} FAILED: " + "; ".join(failures))
        sys.exit(1)
    print("all OK")


if __name__ == "__main__":
    main()
