"""docs/hero.gif: the whole flow in a few frames, for the top of the README.

Built from the images `make docs` renders from the app (docs/*.png), with a caption per step and a
last frame with the note. Dev tool only (needs Pillow and ffmpeg; MeetRec itself does not).

    python3 scripts/make_hero.py
"""
import shutil
import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

W, H = 1200, 720
BG, CARD, FG, DIM, ACCENT = (24, 24, 27), (38, 38, 42), (240, 240, 244), (160, 160, 170), (229, 57, 53)
SF = "/System/Library/Fonts/SFNS.ttf"
MONO = "/System/Library/Fonts/SFNSMono.ttf"
docs = Path("docs")


def font(size, mono=False):
    return ImageFont.truetype(MONO if mono else SF, size)


def frame(step, caption, sub=""):
    im = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(im)
    if step:
        d.rounded_rectangle((40, 34, 92, 86), 14, fill=ACCENT)
        d.text((66, 60), str(step), font=font(30), fill="white", anchor="mm")
    d.text((112 if step else 40, 40), caption, font=font(34), fill=FG)
    if sub:
        d.text((112 if step else 40, 84), sub, font=font(21), fill=DIM)
    return im


def paste_fit(im, path, box):
    """the app image, scaled into box (x0, y0, x1, y1), centred"""
    pic = Image.open(path).convert("RGBA")
    x0, y0, x1, y1 = box
    k = min((x1 - x0) / pic.width, (y1 - y0) / pic.height, 1.0)
    pic = pic.resize((int(pic.width * k), int(pic.height * k)), Image.LANCZOS)
    im.paste(pic, (x0 + (x1 - x0 - pic.width) // 2, y0 + (y1 - y0 - pic.height) // 2), pic)


def note_frame():
    im = frame(4, "The note, in your folder", "Markdown (plain or Obsidian), text, JSON, subtitles · summary optional")
    d = ImageDraw.Draw(im)
    d.rounded_rectangle((120, 140, 1080, 615), 16, fill=CARD)
    y = 165
    d.text((150, y), "2026-11-09 - Weekly product sync.md", font=font(18, True), fill=DIM); y += 40
    d.text((150, y), "Weekly product sync", font=font(34), fill=FG); y += 52
    d.text((150, y), "From the calendar · 10:00-10:45 · Invited: Jane Doe, Mark Rossi", font=font(20), fill=DIM); y += 46
    d.text((150, y), "Summary", font=font(26), fill=FG); y += 40
    for line in ["• Release 2.4 confirmed for Thursday, after the regression tests.",
                 "• The new onboarding beta moves one week.",
                 "• Jane → release notes by Wednesday."]:
        d.text((170, y), line, font=font(21), fill=FG); y += 32
    y += 14
    d.text((150, y), "Transcript", font=font(26), fill=FG); y += 40
    for t, who, text in [("00:00:04", "Me", "Let's start with the release: are we ready for Thursday?"),
                         ("00:00:09", "Others", "Yes, only the regression tests are left, we close them tomorrow."),
                         ("00:00:15", "Me", "Good. And the onboarding beta?")]:
        d.text((170, y), t, font=font(18, True), fill=DIM)
        d.text((290, y - 2), f"{who}:", font=font(21), fill=ACCENT if who == "Me" else (90, 160, 255))
        d.text((290 + (50 if who == "Me" else 86), y - 2), text, font=font(21), fill=FG)
        y += 34
    return im


frames = []
f = frame(1, "Record from the menu bar", "one click or ⌃⌥⌘R · your voice and the others, on two tracks, locally")
paste_fit(f, docs / "menu-recording.png", (300, 130, 900, 700))
frames.append(f)
f = frame(None, "A call starts? MeetRec offers to record it", "Teams, Zoom, Meet, a browser… no bot joins the call")
paste_fit(f, docs / "tour-call.png", (160, 250, 1040, 560))
frames.append(f)
f = frame(2, "Stop: which meeting was it?", "events from every calendar, or write it yourself · optional instructions for the AI")
paste_fit(f, docs / "tour-which-meeting.png", (200, 130, 1000, 700))
frames.append(f)
f = frame(3, "Cut what should not be there (optional)", "listen, select, cut · then whisper.cpp transcribes on your computer")
paste_fit(f, docs / "tour-editor.png", (40, 150, 1160, 690))
frames.append(f)
frames.append(note_frame())

tmp = Path(tempfile.mkdtemp())
for i, im in enumerate(frames):
    im.save(tmp / f"f{i}.png")
# each frame 3.2 s, the note 5 s; palette for a small, clean GIF
lst = tmp / "list.txt"
lst.write_text("".join(f"file 'f{i}.png'\nduration {5 if i == len(frames) - 1 else 3.2}\n" for i in range(len(frames)))
               + f"file 'f{len(frames) - 1}.png'\n")
out = docs / "hero.gif"
subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "concat", "-safe", "0", "-i", str(lst),
                "-vf", "fps=10,scale=900:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128[p];[b][p]paletteuse=dither=none",
                "-loop", "0", str(out)], check=True)
shutil.rmtree(tmp)
print(out, f"{out.stat().st_size / 1e6:.2f} MB")
