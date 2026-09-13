#!/usr/bin/env bash
#
# bump-pack-version.sh - deterministically bump an OPF pack's version.
#
# This is the mechanical counterpart to skills/pack-release/SKILL.md: the
# skill decides WHICH bump size fits the change (in plain language, for a
# non-technical pack owner) and writes the changelog wording; this script
# only does the arithmetic and the file edits, the same split used between
# new-pack.sh and create-pack.
#
# Usage:
#   scripts/bump-pack-version.sh <pack-dir> <major|minor|patch> [options]
#
# Options:
#   --note TEXT       One-line CHANGELOG entry to add under the new version
#                      heading (repeatable; each becomes its own bullet).
#   -h, --help        Show this help.
#
# Bump rules (standard semver): major resets minor.patch to 0.0 and drops
# any pre-release/build metadata; minor resets patch to 0 and drops
# pre-release/build metadata; patch increments patch and drops pre-release/
# build metadata. There is no "prerelease" bump kind in this script.
#
# Exit codes: 0 success, 1 failure (bad args, missing/invalid manifest,
# invalid current version).
#
set -euo pipefail

usage() {
  cat <<'EOF'
usage: bump-pack-version.sh <pack-dir> <major|minor|patch> [options]

Options:
  --note TEXT       CHANGELOG bullet to add under the new version heading
                     (repeatable).
  -h, --help        Show this help.
EOF
}

NOTES=()
POSITIONAL=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --note)
      [[ $# -ge 2 ]] || { echo "ERROR: --note requires TEXT" >&2; exit 1; }
      NOTES+=("$2")
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "ERROR: unknown option: $1" >&2
      usage
      exit 1
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

PACK_DIR_ARG="${POSITIONAL[0]:-}"
BUMP_KIND="${POSITIONAL[1]:-}"
if [[ -z "$PACK_DIR_ARG" || -z "$BUMP_KIND" ]]; then
  usage
  exit 1
fi

case "$BUMP_KIND" in
  major|minor|patch) ;;
  *)
    echo "ERROR: bump kind must be major, minor, or patch (got: $BUMP_KIND)" >&2
    exit 1
    ;;
esac

PACK_DIR="$(cd "$PACK_DIR_ARG" 2>/dev/null && pwd)" || {
  echo "ERROR: pack directory does not exist or is not accessible: $PACK_DIR_ARG" >&2
  exit 1
}

MANIFEST="$PACK_DIR/manifest.json"
if [[ ! -f "$MANIFEST" ]]; then
  echo "ERROR: manifest.json not found in $PACK_DIR" >&2
  exit 1
fi

NEW_VERSION="$(python3 - "$MANIFEST" "$BUMP_KIND" <<'PY'
import json, re, sys

manifest_path, kind = sys.argv[1], sys.argv[2]

with open(manifest_path) as fh:
    manifest = json.load(fh)

version = manifest.get("version")
if not isinstance(version, str):
    print("ERROR: manifest.json has no string 'version' field", file=sys.stderr)
    sys.exit(1)

m = re.match(r'^(\d+)\.(\d+)\.(\d+)(?:-[0-9A-Za-z.-]+)?(?:\+.*)?$', version)
if not m:
    print(f"ERROR: current version is not valid semver: {version}", file=sys.stderr)
    sys.exit(1)

major, minor, patch = (int(g) for g in m.groups())
if kind == "major":
    major, minor, patch = major + 1, 0, 0
elif kind == "minor":
    minor, patch = minor + 1, 0
else:
    patch += 1

new_version = f"{major}.{minor}.{patch}"
manifest["version"] = new_version

with open(manifest_path, "w") as fh:
    json.dump(manifest, fh, indent=2, sort_keys=False)
    fh.write("\n")

print(new_version)
PY
)"

echo "==> Bumped $PACK_DIR/manifest.json: $BUMP_KIND -> $NEW_VERSION"

# --- CHANGELOG.md ------------------------------------------------------------
CHANGELOG="$PACK_DIR/CHANGELOG.md"
if [[ ${#NOTES[@]} -gt 0 ]]; then
  if [[ ! -f "$CHANGELOG" ]]; then
    echo "NOTE: CHANGELOG.md not found in $PACK_DIR; skipping changelog entry."
  else
    set +e
    python3 - "$CHANGELOG" "$NEW_VERSION" "${NOTES[@]}" <<'PY'
import re, sys

changelog_path, new_version = sys.argv[1], sys.argv[2]
notes = sys.argv[3:]

with open(changelog_path) as fh:
    lines = fh.readlines()

# Table-style changelogs (e.g. "| date | version - change | why |") use a
# different insertion shape per org; guessing one would risk corrupting the
# file. Only insert a "## <version>" heading when the file already uses
# that convention, or has no changelog convention established yet.
has_heading = any(re.match(r'^##\s', line) for line in lines)
has_table = any(line.lstrip().startswith('|') for line in lines)
if not has_heading and has_table:
    sys.exit(3)

entry = [f"## {new_version}\n", "\n"] + [f"- {note}\n" for note in notes] + ["\n"]

# Insert right after the top-level "# ..." heading if present, otherwise at
# the very top - either way, above all prior version sections.
insert_at = 0
if lines and lines[0].lstrip().startswith("# "):
    insert_at = 1
    while insert_at < len(lines) and lines[insert_at].strip() == "":
        insert_at += 1

new_lines = lines[:insert_at] + entry + lines[insert_at:]
with open(changelog_path, "w") as fh:
    fh.writelines(new_lines)
PY
    changelog_rc=$?
    set -e
    if [[ $changelog_rc -eq 3 ]]; then
      echo "NOTE: CHANGELOG.md does not use '## <version>' headings and looks table-based; skipping automatic insertion. Add the $NEW_VERSION entry by hand."
    elif [[ $changelog_rc -ne 0 ]]; then
      echo "ERROR: failed to update CHANGELOG.md (exit $changelog_rc)" >&2
      exit 1
    else
      echo "==> Added CHANGELOG.md entry for $NEW_VERSION"
    fi
  fi
else
  echo "NOTE: no --note given; CHANGELOG.md left unchanged (add an entry before shipping)."
fi
