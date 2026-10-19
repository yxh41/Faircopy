#!/usr/bin/env python3
"""Regenerate the duplicated "built-in app-search targets" list from a single
source of truth.

The list is needed in TWO modules that cannot share a Swift source file:
  * the panel side (WritingTools framework / injected dylib) as `kAppSearchDefaults`
  * the settings side (AIGate app + FaircopyPrefs bundle) as `AppSearchStore.defaults`

Both copies used to be hand-maintained in parallel and silently drifted. Now
`Resources/AppSearch/appsearch_defaults.json` is the only place you edit. Run this
script after changing it; it regenerates both Swift arrays between the
// >>> APPSEARCH_DEFAULTS_GENERATED >>> / // <<< ... <<< sentinels.

The two Swift types (`AppSearchTarget` / `AppSearchEntry`) declare the same
fields (id, name, searchTemplate, bareScheme) so a single JSON drives both.
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # WriteNow/
JSON_PATH = os.path.join(ROOT, "Resources", "AppSearch", "appsearch_defaults.json")

PANEL_FILE = os.path.join(
    ROOT, "Library", "WritingTools", "Sources", "WritingTools",
    "WritingToolsView", "WritingToolsView+AppSearch.swift")
SETTINGS_FILE = os.path.join(
    ROOT, "AIGate", "AIGate", "Editor", "FaircopyRootView.swift")

SENTINEL_RE = re.compile(
    r"(// >>> APPSEARCH_DEFAULTS_GENERATED >>>\n).*?(\n\s*// <<< APPSEARCH_DEFAULTS_GENERATED <<<)",
    re.DOTALL)


def esc(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"')


def build_items(targets, type_name, indent):
    pad = " " * indent
    lines = []
    for t in targets:
        lines.append(
            f'{pad}.init(id: "{esc(t["id"])}", name: "{esc(t["name"])}", '
            f'searchTemplate: "{esc(t["searchTemplate"])}", '
            f'bareScheme: "{esc(t["bareScheme"])}"),')
    return "\n".join(lines)


def regenerate(path, type_name, indent):
    with open(path, encoding="utf-8") as f:
        src = f.read()
    if not SENTINEL_RE.search(src):
        sys.exit(f"ERROR: sentinels not found in {path}; refusing to edit blindly.")
    items = build_items(targets, type_name, indent)
    new_src, n = SENTINEL_RE.subn(rf"\1{items}\2", src, count=1)
    if n != 1:
        sys.exit(f"ERROR: expected exactly one sentinel block in {path}, got {n}.")
    with open(path, "w", encoding="utf-8") as f:
        f.write(new_src)
    print(f"regenerated {os.path.relpath(path, ROOT)} with {len(targets)} targets "
          f"(type {type_name})")


def main():
    with open(JSON_PATH, encoding="utf-8") as f:
        global targets
        targets = json.load(f)
    if not isinstance(targets, list) or not targets:
        sys.exit("ERROR: appsearch_defaults.json must be a non-empty array.")
    regenerate(PANEL_FILE, "AppSearchTarget", indent=4)
    regenerate(SETTINGS_FILE, "AppSearchEntry", indent=8)


if __name__ == "__main__":
    main()
