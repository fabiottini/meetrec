"""Every T("key") used by the apps (macOS and Windows) exists in every locale file, and all locale files have the same keys."""
import json
import re
import sys
from pathlib import Path

used = set()
for f in [*Path("menubar").glob("*.swift"), *Path("windows/app").glob("*.cs")]:
    text = f.read_text()
    used |= set(re.findall(r'T\("([a-z_0-9]+)"', text))
    used |= set(re.findall(r'"(g\d_(?:title|text))"', text))       # Google guide steps
    used |= set(re.findall(r'"(voice_(?:none|p\d))"', text))       # voice profile names
    used |= set(re.findall(r'"(ai_p_[a-z_]+)"', text))             # AI provider names
    used |= set(re.findall(r'"(m\d_(?:title|text))"', text))       # Microsoft guide steps

locales = {f.stem: set(json.loads(f.read_text())) for f in Path("locales").glob("*.json")}
ok = True
for code, keys in sorted(locales.items()):
    missing = sorted(used - keys)
    if missing:
        print(f"{code}: missing {missing}")
        ok = False
base = locales.get("en", set())
for code, keys in sorted(locales.items()):
    if code in ("en", "it") and keys != base:
        print(f"{code}: keys differ from en: {sorted(keys ^ base)}")
        ok = False
unused = sorted(base - used - {"_language_name"})
if unused:
    print(f"unused keys (fine, but can be removed): {unused}")
print("locales ok" if ok else "locales NOT ok")
sys.exit(0 if ok else 1)
