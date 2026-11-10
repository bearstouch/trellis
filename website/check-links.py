#!/usr/bin/env python3
"""Check that every local href/src in website/docs resolves to a file (and #anchor, when given)."""
import re, sys, pathlib
DOCS = pathlib.Path(__file__).resolve().parent / "docs"
ids = {}
for p in DOCS.rglob("*.html"):
    ids[p.resolve()] = set(re.findall(r'\bid="([^"]+)"', p.read_text(encoding="utf-8")))
bad = 0
for p in sorted(DOCS.rglob("*.html")):
    if p.name.startswith("_"): continue
    for ref in re.findall(r'(?:href|src)="([^"]+)"', p.read_text(encoding="utf-8")):
        if re.match(r"^(https?:|mailto:|data:)", ref): continue
        path, _, frag = ref.partition("#")
        target = (p.parent / path).resolve() if path else p.resolve()
        if not target.exists():
            print(f"{p.relative_to(DOCS)}: missing {ref}"); bad += 1
        elif frag and target.suffix == ".html" and frag not in ids.get(target, set()):
            print(f"{p.relative_to(DOCS)}: missing anchor {ref}"); bad += 1
print("ok" if not bad else f"{bad} broken link(s)"); sys.exit(1 if bad else 0)
