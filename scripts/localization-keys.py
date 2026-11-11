#!/usr/bin/env python3
"""List the app's translatable text (FR-LN04).

    scripts/localization-keys.py            every L("…") key in Sources, as a JSON array
    scripts/localization-keys.py --check    what each table lacks or no longer needs; exit 1 if anything
    scripts/localization-keys.py --prune    drop entries the source no longer uses from each table

The tables are Sources/TrellisCore/Resources/Localizations/<language>.json: English text to translation.
"""
import json, pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
TABLES = ROOT / "Sources/TrellisCore/Resources/Localizations"
KEY = re.compile(r'(?<![A-Za-z0-9_.])L\(\s*"((?:[^"\\]|\\.)*)"')


def unescape(literal: str) -> str:
    literal = re.sub(r"\\u\{([0-9A-Fa-f]+)\}", lambda m: chr(int(m.group(1), 16)), literal)
    return re.sub(r"\\(.)", lambda m: {"n": "\n", "t": "\t"}.get(m.group(1), m.group(1)), literal)


def source_keys() -> list[str]:
    keys = set()
    for path in sorted((ROOT / "Sources").rglob("*.swift")):
        keys.update(unescape(m) for m in KEY.findall(path.read_text(encoding="utf-8")))
    return sorted(keys)


def write(path: pathlib.Path, table: dict[str, str]) -> None:
    path.write_text(json.dumps(dict(sorted(table.items())), ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def main() -> int:
    keys = source_keys()
    if len(sys.argv) == 1:
        print(json.dumps(keys, ensure_ascii=False, indent=2))
        return 0
    failed = False
    for path in sorted(TABLES.glob("*.json")):
        table = json.loads(path.read_text(encoding="utf-8"))
        missing, unused = [k for k in keys if k not in table], [k for k in table if k not in keys]
        if sys.argv[1] == "--prune":
            write(path, {k: v for k, v in table.items() if k in keys})
            print(f"{path.name}: removed {len(unused)}")
            continue
        failed = failed or bool(missing or unused)
        print(f"{path.name}: {len(missing)} missing, {len(unused)} unused")
        for key in missing:
            print(f"  missing: {json.dumps(key, ensure_ascii=False)}")
        for key in unused:
            print(f"  unused:  {json.dumps(key, ensure_ascii=False)}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
