# Contributing to MeetRec

Thanks for your interest. MeetRec is a **personal project, free and open source** (MIT license),
built by one person in spare time and shared as is. This page explains what to expect and how to
help.

## No warranty, no liability

- MeetRec is provided **"as is", without warranty of any kind** (see [LICENSE](LICENSE)). The author
  is **not responsible** for any problem it may cause: lost or corrupted recordings, wrong
  transcripts or notes, data sent to third-party services you enabled (calendars, Claude), legal
  issues from recording people, or anything else.
- **You are responsible for how you use it**: tell the people in a call that you are recording and
  ask for their consent where the law requires it.
- There is **no support and no roadmap**. Issues and pull requests are read when there is time;
  an answer, a fix or a merge is not guaranteed.
- Keep your own backups of recordings and notes that matter to you.

## Before you open an issue

- Search the existing issues first.
- Say your macOS version, your Mac (Apple Silicon or Intel), the MeetRec version (bottom of the
  menu, or `meet --version`) and the steps to reproduce.
- Attach the relevant lines of the log (menu > Log), **after removing anything private**: names,
  emails, meeting titles, transcript text, file paths with your user name. Never attach recordings,
  notes or files from `~/.config/meetrec/` (they contain your calendar login tokens).
- Security problems: do not open a public issue, see [SECURITY.md](SECURITY.md).

## Pull requests

Small, focused pull requests have the best chance.

1. Open an issue first for anything bigger than a small fix, so we agree on the idea before you
   spend time on it.
2. Fork the repository, create a branch, make the change.
3. Keep the style of the code around it: plain Swift (AppKit + SwiftUI, no external packages) and
   Python standard library only in `meet.py` (no pip dependencies).
4. Run the checks and build:

   ```sh
   make check      # meet.py syntax, locale keys in every language, Info.plist
   make build      # universal app in dist/
   make install    # try it on your Mac
   ```

5. If you add text to the app, add the key to **every** file in `locales/` (`make check` tells you
   what is missing).
6. Update the README when behaviour changes. Do not bump `VERSION` and do not commit
   `dist/MeetRec.zip`: the maintainer does that when releasing.
7. Describe in the pull request what you changed and how you tested it.

The main development copy is private: an accepted pull request may be applied there and then come
back to GitHub with the next sync, so your pull request can be closed with a link to the commit
that contains your change instead of being merged with the button. Credit stays with you
(`Co-authored-by` in the commit).

By contributing you agree that your contribution is released under the MIT license of the project.

## Translations

The app texts are in `locales/<language>.json`. To add a language, copy `locales/en.json`, translate
the values (not the keys), set `_language_name`, and open a pull request. You can try it before
without rebuilding: put the file in `~/.config/meetrec/locales/`.

## Code of conduct

Be kind and assume good faith. Harassment or abusive behaviour leads to blocked access.
