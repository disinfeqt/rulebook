#!/usr/bin/env python3
"""Checks that every string the app shows has a translation in each Resources/*.lproj.

A string is anything passed to L() or LN(), plus the static literals SwiftUI looks up on its own
(Text("…"), Button("…"), .help("…") and so on). Run it after adding or changing text:

    ./scripts/check-strings.py          # report missing and unused keys, exit 1 if any
    ./scripts/check-strings.py --keys   # print every key, to start a new translation from
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
LITERAL = r'"((?:[^"\\]|\\.)*)"'
# Views and modifiers whose first string literal is a localization key.
VIEWS = ("Text|Button|Label|Toggle|Section|Picker|TextField|LabeledContent|Menu|CommandMenu|"
         "ContentUnavailableView|TableColumn|InspectorSection")
MODIFIERS = "help|navigationTitle|navigationSubtitle"
PATTERNS = [
    re.compile(r"\bLN?\(\s*(?:[^\"()]*?,\s*)?" + LITERAL),         # L("…") and LN(count, "…"
    re.compile(r"\bLN\(\s*[^\"()]*?,\s*" + LITERAL + r"\s*,\s*" + LITERAL),  # LN's plural form
    re.compile(r"\b(?:" + VIEWS + r")\(\s*" + LITERAL),
    re.compile(r"\.(?:" + MODIFIERS + r")\(\s*" + LITERAL),
    re.compile(r"\?\s*" + LITERAL + r"\s*:\s*" + LITERAL + r"\)\s*\{"),  # Button(flag ? "A" : "B") {
]
ENTRY = re.compile(r"^\s*" + LITERAL + r"\s*=\s*" + LITERAL + r"\s*;\s*$")


def unescape(s):
    return s.replace('\\"', '"').replace("\\n", "\n").replace("\\\\", "\\")


def source_keys():
    keys = {}
    for path in sorted((ROOT / "Sources").rglob("*.swift")):
        # Blank out comment lines, keeping line numbers. Calls may span lines, so search the whole file.
        text = "\n".join("" if line.lstrip().startswith("//") else line for line in path.read_text().splitlines())
        for pattern in PATTERNS:
            for match in pattern.finditer(text):
                where = f"{path.relative_to(ROOT)}:{text.count(chr(10), 0, match.start()) + 1}"
                for group in match.groups():
                    if "\\(" in group:
                        sys.exit(f"{where}: interpolated literal, use L() with %@ or %d: {group}")
                    if group:
                        keys.setdefault(unescape(group), where)
    return keys


def table(path):
    entries = {}
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if not line.strip() or line.lstrip().startswith(("//", "/*")):
            continue
        match = ENTRY.match(line)
        if not match:
            sys.exit(f"{path.relative_to(ROOT)}:{number}: not a \"key\" = \"value\"; line")
        entries[unescape(match.group(1))] = unescape(match.group(2))
    return entries


def specifiers(s):
    """The format arguments a string consumes, order-independent: {1: '@', 2: 'd'}."""
    found, position = {}, 0
    for index, kind in re.findall(r"%(?:(\d+)\$)?([@d])", s.replace("%%", "")):
        position = int(index) if index else position + 1
        found[position] = kind
    return found


def main():
    keys = source_keys()
    if "--keys" in sys.argv:
        for key in keys:
            print(key.replace("\n", "\\n"))
        return
    failed = False
    for lproj in sorted((ROOT / "Resources").glob("*.lproj")):
        if lproj.name == "en.lproj":
            continue  # English is the key itself.
        entries = table(lproj / "Localizable.strings")
        for key, where in keys.items():
            if key not in entries:
                print(f"{lproj.name}: missing  {where}  {key!r}")
                failed = True
            elif specifiers(key) != specifiers(entries[key]):
                print(f"{lproj.name}: format arguments differ  {where}  {key!r} -> {entries[key]!r}")
                failed = True
        for key in entries.keys() - keys.keys():
            print(f"{lproj.name}: unused   {key!r}")
            failed = True
    if failed:
        sys.exit(1)
    print(f"{len(keys)} strings, all translated")


if __name__ == "__main__":
    main()
