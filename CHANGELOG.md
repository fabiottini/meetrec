# Changelog

Versions follow [Semantic Versioning](https://semver.org/): MAJOR.MINOR.PATCH.
MAJOR for changes that break existing use (config, CLI, notes), MINOR for new features,
PATCH for fixes. Every release has a git tag `vX.Y.Z` (`make tag`).

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
