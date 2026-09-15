#!/usr/bin/env python3
"""
compute-pack-checksums.py <pack-dir>

Prints the sha256 checksums of a pack's files as a JSON object, mapping
pack-relative path -> "sha256:<hex>". Skips .opf-env and .opf-lock
(installer-written state, excluded from checksums per spec Section 9.1)
and .git.

Shared by install-pack.sh (writing .opf-lock) and pack-doctor.sh (checking
.opf-lock for drift), so the two cannot silently compute checksums
differently and disagree about what counts as drift.
"""
import hashlib
import json
import os
import sys

SKIP_REL_PATHS = {".opf-env", ".opf-lock"}


def compute_checksums(pack_dir):
    checksums = {}
    for root, dirs, files in os.walk(pack_dir):
        if ".git" in dirs:
            dirs.remove(".git")
        for fname in files:
            full = os.path.join(root, fname)
            rel = os.path.relpath(full, pack_dir)
            if rel in SKIP_REL_PATHS:
                continue
            h = hashlib.sha256()
            try:
                with open(full, "rb") as fh:
                    for chunk in iter(lambda: fh.read(65536), b""):
                        h.update(chunk)
            except OSError:
                # A file can vanish or become unreadable between the
                # os.walk() listing and the open() (races, permissions);
                # skip it rather than crashing an install or a scan.
                continue
            checksums[rel] = f"sha256:{h.hexdigest()}"
    return checksums


def main():
    print(json.dumps(compute_checksums(sys.argv[1])))


if __name__ == "__main__":
    main()
