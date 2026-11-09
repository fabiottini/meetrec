# Changelog

Versions follow [Semantic Versioning](https://semver.org/): MAJOR.MINOR.PATCH.
MAJOR for changes that break existing use (config, CLI, notes), MINOR for new features,
PATCH for fixes. Every release has a git tag `vX.Y.Z` (`make tag`).

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
