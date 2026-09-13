#!/usr/bin/env python3
"""
resolve-scan-excludes.py <manifest.json> <pack-dir>

Prints, one per line, the pack-relative file paths that the manifest's
scan.exclude patterns match AND that are NOT an "executable file type"
(spec Section 7.3, rule (a): exclusions never apply to executable file
types, so an executable file is always content-scanned regardless of any
exclusion pattern).

This is the set of paths a content scanner (semgrep) may actually be told
to skip. Used by scripts/install-pack.sh; scan.exclude applies to content
scanning only (spec Section 7.3) - never to secrets scanning or structural
validation, so this script is not used anywhere else.
"""
import json
import os
import re
import sys

EXEC_EXTENSIONS = {".sh", ".py"}


def glob_to_regex(pattern):
    pattern = pattern.strip("/")
    out = []
    i = 0
    n = len(pattern)
    while i < n:
        c = pattern[i]
        if c == "*":
            if i + 1 < n and pattern[i + 1] == "*":
                out.append("(?:[^/]+/)*[^/]*")
                i += 2
                continue
            out.append("[^/]*")
            i += 1
            continue
        elif c == "?":
            out.append("[^/]")
            i += 1
            continue
        elif c == "[":
            j = i + 1
            while j < n and pattern[j] != "]":
                j += 1
            if j < n:
                out.append(pattern[i:j + 1])
                i = j + 1
                continue
            out.append(re.escape(c))
            i += 1
            continue
        else:
            out.append(re.escape(c))
            i += 1
    return re.compile("^" + "".join(out) + "$")


def is_executable(path):
    ext = os.path.splitext(path)[1]
    if ext in EXEC_EXTENSIONS:
        return True
    try:
        with open(path, "rb") as fh:
            return fh.read(2) == b"#!"
    except OSError:
        return False


def main():
    manifest_path, pack_dir = sys.argv[1], sys.argv[2]
    manifest = json.load(open(manifest_path))
    scan = manifest.get("scan")
    excludes = scan.get("exclude") if isinstance(scan, dict) else None
    if not isinstance(excludes, list):
        return

    relpaths = []
    for root, _dirs, files in os.walk(pack_dir):
        for name in files:
            relpaths.append(os.path.relpath(os.path.join(root, name), pack_dir))

    safe = set()
    for pattern in excludes:
        if not isinstance(pattern, str) or not pattern:
            continue
        rx = glob_to_regex(pattern)
        for rel in relpaths:
            if rx.match(rel) and not is_executable(os.path.join(pack_dir, rel)):
                safe.add(rel)

    for rel in sorted(safe):
        print(rel)


if __name__ == "__main__":
    main()
