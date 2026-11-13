# Changelog

Versions follow [Semantic Versioning](https://semver.org/): MAJOR.MINOR.PATCH.
MAJOR for changes that break existing use (config, CLI, notes), MINOR for new features,
PATCH for fixes. Every release has a git tag `vX.Y.Z` (`make tag`).

## 1.7.0 – 2026-11-13

- **Windows (beta)**: `MeetRec-windows.zip` on every release. Tray app with the same menu and flows
  as the Mac (start/stop, which meeting, manual event, instructions, keep-audio question, import,
  recordings, audio editor, live levels, mute, call detection, Ctrl+Alt+Win+R), settings, and a
  setup that downloads ffmpeg, whisper.cpp and the models. Recorder with WASAPI (microphone +
  system audio loopback, silences filled so the tracks stay aligned), built into MeetRec.exe.
  Embedded Python, nothing to install; `meet.cmd` for the command line.
- `meet.py` runs on Windows too (paths, UTF-8, recorder start/stop), tested in CI on Windows.
- Fix: Google sign-in opened the browser through a broken helper (since the Windows groundwork).

## 1.6.0 – 2026-11-13

- Edit afterwards: menu **Recordings** with the processed meetings: open the note, **Edit audio…**
  (the editor on a transcribed recording; cut parts leave the audio and the transcript, later times
  move back, the same note is written again without transcribing again, speakers kept) and
  **Process again with instructions…**. `meet list`, `meet edit`.
- Transcription in short segments (about 30 characters, exact times also with the silence filter), so
  cuts after the transcript are precise to the word.
- Instructions: when they cut the audio, the saved transcription is realigned, so audio and
  transcript always match and new instructions cut the audio again.
- A lone "Grazie." is kept unless whisper stretched it over a long silence.

## 1.5.0 – 2026-11-13

- Notes follow the meeting language (Settings > Meeting language): English meetings get English
  headings, labels and summary; Italian meetings are unchanged.
- The level panel follows the width of the menu (macOS makes the menu wider for shortcuts and
  icons): waveform, meters and slider stretch, buttons stay on the right edge.
- README: the example note is in English.

## 1.4.0 – 2026-11-13

- **Instructions for Claude** when you stop a recording (e.g. "remove the part where I talk to people
  at the door"): Claude points at the sentences to remove, MeetRec removes them from the transcript
  and from the saved audio and writes in the note what was removed and why. Claude never rewrites the
  transcript; a request that would remove more than half of the recording is not applied. The
  instructions also guide the summary. `meet process --instructions`.
- **Audio editor** before the transcription: waveform of the whole recording, select by dragging,
  listen, cut (several times, with zoom), then apply and transcribe. Also **Edit audio…** on
  recordings to process. `meet cut`, `meet prepare`, `meet peaks`.

## 1.3.2 – 2026-11-13

- Fix: long menu titles were shortened twice (the last note lost its date: "202…61-12"). The
  shortening now measures the text with the "…" and already shortened titles are not cut again.

## 1.3.1 – 2026-11-13

- Menu: long titles (e.g. the last note name) are shortened with "…" in the middle, so the menu is
  as wide as the level panel and has no empty area; the full title is in the tooltip.
- Level panel: Test mic has its own row, no longer touching the meters.

## 1.3.0 – 2026-11-13

- Fix: the menu could take seconds (up to a minute with repeated clicks) to open, because the mic
  preview started by itself on the main thread (3 s with a Bluetooth headset). The menu now opens at
  once; the preview starts only with **Test mic**, in the background.
- Global shortcut **⌃⌥⌘R**: start a recording from any app, or stop and process it.
- The log (menu > Log) says which app uses the microphone and why the call prompt was shown or not.

## 1.2.0 – 2026-11-09

- Open source (MIT). README: personal project without support, privacy, recording consent,
  third-party components.
- Microsoft calendars use your own app registration (Setup > + Microsoft opens a step-by-step
  guide; `meet account ms-client <id>`). No borrowed client id by default.
- One-time notice about telling the other participants before the first recording.

## 1.1.0 – 2026-11-09

- Much lower CPU when idle (about 7% -> 0.2%): the menu bar icon is redrawn only when it changes,
  the timer slows down when nothing happens, config.json is read again only when it changes,
  call detection every 3 s.
- Version in the menu, `meet --version`, `VERSION` file, this changelog, `make tag` and
  `make bump-patch|minor|major`.

## 1.0.0 – 2026-11-09

First tagged release. Includes everything built so far:

- Recording of microphone and system audio on separate tracks, crash safe; menu bar app and `meet` CLI.
- Local transcription with whisper.cpp and a silence filter; speakers from the two tracks.
- Calendars: Microsoft (any account), Google, macOS Calendar; choose the meeting when you stop, or
  write its details yourself.
- Obsidian note with frontmatter, linked people, optional summary with Claude.
- Live levels, automatic gain reduction, mute switch, call detection.
- Import of audio files; stop and discard; keep or delete the audio after a verified transcript;
  record only my voice; single or separate transcript; voice profiles.
- Guided setup, Italian and English UI from JSON files, prebuilt universal app in `dist/`, Makefile.
