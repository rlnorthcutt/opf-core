#!/usr/bin/env bash
#
# validate-pack.sh - validate an OPF pack directory against the v1 spec.
#
# Usage:
#   scripts/validate-pack.sh <pack-dir>
#
# Checks (per spec/opf-spec-v1.md):
#   (a) manifest.json exists and parses as JSON (python3 is required)
#   (b) required fields present: name, version, pack_format (must be 1), description
#   (c) if jsonschema is available, validate against schema/v1/manifest.schema.json
#   (d) name matches ^[a-z0-9]([a-z0-9._-]*[a-z0-9])?$ and is not "." or ".."
#   (e) version matches the official semver regex
#   (f) path safety: no file path resolves outside the pack root
#       (symlink targets are resolved fully with realpath/readlink -f)
#   (g) if .opf-env or .opf-lock exists, .gitignore must contain it
#   (h) if .opf-lock exists, warn it is installer-written state and should not be committed
#   (i) if a contents field is present, warn if declared items do not match
#       actual folders (data/artifact use file-or-dir existence; the rest use isdir)
#   (j) README.md missing = warning
#   (k) lifecycle script contract for install.sh/uninstall.sh:
#       executable bit (error if missing), shebang (error if missing),
#       network-pattern scan (curl/wget/nc) = warning
#   (l) scan.exclude patterns: warn if a pattern matches nothing in the pack
#   (m) manifest.json must not contain unreplaced placeholder tokens
#       (e.g. __PACK_NAME__) - placeholder tokens never pass validation
#   (n) if present, data_dir must be a single path segment (no "/", not "."
#       or ".."), checked independently of jsonschema availability, since a
#       manifest-declared data_dir feeds a path join at install time
#   (o) contents.skills entries must match the skill-id grammar
#       ^[a-z0-9]+(-[a-z0-9]+)*$ (spec Section 3), independent of jsonschema
#   (p) a skill-id must equal its skills/<id>/SKILL.md name field
#   (q) a skill item must be exactly skills/<name>/SKILL.md (depth 1); a
#       nested skills/<name>/<sub>/SKILL.md is rejected regardless of
#       whether contents declares it (spec Section 3)
#   (r) a routine.json 'script' field must resolve inside its own
#       routines/<name>/ subfolder: no '../' escape, no absolute path
#       (spec Section 5.4)
#
# Exit codes:
#   0  pass
#   1  error (a required check failed)
#   2  warning-only (no errors, but warnings were emitted)
#
# Dependency: python3 is required. jsonschema and git are optional.
#
set -euo pipefail

PACK_DIR="${1:-}"
if [[ -z "$PACK_DIR" ]]; then
  echo "usage: $0 <pack-dir>" >&2
  exit 1
fi

PACK_DIR="$(cd "$PACK_DIR" 2>/dev/null && pwd)" || {
  echo "ERROR: pack directory does not exist or is not accessible: $PACK_DIR" >&2
  exit 1
}

MANIFEST="$PACK_DIR/manifest.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA="$SCRIPT_DIR/../schema/v1/manifest.schema.json"
# shellcheck source=scripts/pack-name-pattern.sh
source "$SCRIPT_DIR/pack-name-pattern.sh"

errors=0
warnings=0

note()  { echo "NOTE:    $*"; }
warn()  { echo "WARNING: $*"; warnings=$((warnings + 1)); }
error() { echo "ERROR:   $*"; errors=$((errors + 1)); }

resolve_path() {
  if command -v realpath >/dev/null 2>&1; then
    realpath "$1"
  else
    readlink -f "$1"
  fi
}

# --- (a) manifest.json exists and parses as JSON ---------------------------
if [[ ! -f "$MANIFEST" ]]; then
  error "manifest.json not found in $PACK_DIR"
  echo "FAIL: $errors error(s), $warnings warning(s)"
  exit 1
fi

if command -v python3 >/dev/null 2>&1; then
  if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$MANIFEST" >/dev/null 2>&1; then
    error "manifest.json is not valid JSON"
    echo "FAIL: $errors error(s), $warnings warning(s)"
    exit 1
  fi
else
  error "python3 is required for validation"
  echo "FAIL: $errors error(s), $warnings warning(s)"
  exit 1
fi

# --- (b) required fields present -------------------------------------------
name="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("name",""))' "$MANIFEST" 2>/dev/null || true)"
version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version",""))' "$MANIFEST" 2>/dev/null || true)"
pack_format="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("pack_format",""))' "$MANIFEST" 2>/dev/null || true)"
description="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("description",""))' "$MANIFEST" 2>/dev/null || true)"

if [[ -z "$name" ]]; then error "missing required field: name"; fi
if [[ -z "$version" ]]; then error "missing required field: version"; fi
if [[ -z "$pack_format" ]]; then error "missing required field: pack_format"; fi
if [[ -z "$description" ]]; then error "missing required field: description"; fi

if [[ -n "$pack_format" && "$pack_format" != "1" ]]; then
  error "pack_format must be 1 (got: $pack_format)"
fi

# --- (c) validate against schema if jsonschema available -------------------
if python3 -c 'import jsonschema' >/dev/null 2>&1; then
  if ! python3 - "$MANIFEST" "$SCHEMA" <<'PY' 2>/dev/null
import json, sys
import jsonschema
manifest = json.load(open(sys.argv[1]))
schema = json.load(open(sys.argv[2]))
jsonschema.validate(instance=manifest, schema=schema)
PY
  then
    error "manifest.json failed schema validation against $SCHEMA"
  fi
else
  note "jsonschema not installed; skipping schema validation (python3 present)"
fi

# --- (d) name pattern ------------------------------------------------------
if [[ -n "$name" ]]; then
  if [[ "$name" == "." || "$name" == ".." ]]; then
    error "name must not be '.' or '..'"
  elif ! [[ "$name" =~ $OPF_NAME_PATTERN ]]; then
    error "name does not match $OPF_NAME_PATTERN (got: $name)"
  fi
fi

# --- (e) version matches official semver regex -----------------------------
SEMVER='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-((0|[1-9][0-9]*|[0-9]*[a-zA-Z-][0-9a-zA-Z-]*)(\.(0|[1-9][0-9]*|[0-9]*[a-zA-Z-][0-9a-zA-Z-]*))*))?(\+([0-9a-zA-Z-]+(\.[0-9a-zA-Z-]+)*))?$'
if [[ -n "$version" && ! "$version" =~ $SEMVER ]]; then
  error "version does not match the official semver regex (got: $version)"
fi

# --- (n) data_dir must be a single safe path segment ------------------------
data_dir_field="$(python3 -c 'import json,sys; v=json.load(open(sys.argv[1])).get("data_dir"); print(v if isinstance(v,str) else "")' "$MANIFEST" 2>/dev/null || true)"
if [[ -n "$data_dir_field" ]]; then
  if [[ "$data_dir_field" == "." || "$data_dir_field" == ".." || "$data_dir_field" == */* ]]; then
    error "data_dir must be a single path segment, not '.', '..', or contain '/' (got: $data_dir_field)"
  elif ! [[ "$data_dir_field" =~ ^[A-Za-z0-9._-]+$ ]]; then
    error "data_dir does not match ^[A-Za-z0-9._-]+\$ (got: $data_dir_field)"
  fi
fi

# --- (f) path safety: no path resolves outside the pack root ---------------
# Resolve symlink targets fully (realpath, or readlink -f fallback) and verify
# the resolved path stays under the pack root. Handles chains and "..".
# NOTE: this walks files already on disk under PACK_DIR, so it catches a
# symlink inside an already-extracted pack that points outside the pack root.
# It is NOT a substitute for safe archive extraction: a zip/tar entry that
# escapes the pack root during a naive extraction (e.g. "../../etc/passwd")
# writes outside PACK_DIR and is never seen by this walk, because it never
# lands inside the tree being walked. Whatever unpacks the archive MUST
# reject or normalize escaping entries before this validator ever runs (spec
# Section 7).
PACK_REAL="$(resolve_path "$PACK_DIR")"
while IFS= read -r -d '' entry; do
  rel="${entry#"$PACK_DIR"/}"
  resolved="$(resolve_path "$entry" 2>/dev/null)" || {
    error "cannot resolve path: $rel"
    continue
  }
  case "$resolved" in
    "$PACK_REAL"|"$PACK_REAL"/*) : ;;
    *) error "path escapes pack root: $rel -> $resolved" ;;
  esac
done < <(find "$PACK_DIR" -print0)

# --- (g) .opf-env and .opf-lock must be gitignored --------------------------
# Accepts the exact-line form as well as the common /-anchored and trailing-/
# variants (e.g. "/.opf-lock", ".opf-lock/"), not just a byte-for-byte match,
# so a correctly gitignored file is never flagged as an error.
gitignore_has() {
  local dir="$1" target="$2" line
  [[ -f "$dir/.gitignore" ]] || return 1
  # `|| [[ -n "$line" ]]` also processes a final line with no trailing
  # newline, which `read` otherwise reports as EOF and the loop would skip.
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    line="${line#/}"
    line="${line%/}"
    [[ "$line" == "$target" ]] && return 0
  done < "$dir/.gitignore"
  return 1
}
for state_file in .opf-env .opf-lock; do
  if [[ -e "$PACK_DIR/$state_file" ]]; then
    if gitignore_has "$PACK_DIR" "$state_file"; then
      :
    else
      error "$state_file exists but .gitignore does not contain $state_file"
    fi
  fi
done

# --- (h) .opf-lock is installer-written state -------------------------------
if [[ -e "$PACK_DIR/.opf-lock" ]]; then
  warn ".opf-lock is installer-written state and should not be committed"
fi

# --- (i) contents field vs actual folders ----------------------------------
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  warn "$line"
done < <(python3 - "$MANIFEST" "$PACK_DIR" <<'PY' 2>/dev/null || true
import json, os, sys
manifest_path, pack_dir = sys.argv[1], sys.argv[2]
manifest = json.load(open(manifest_path))
contents = manifest.get("contents")
if not isinstance(contents, dict):
    sys.exit(0)
file_kinds = {"data", "artifacts"}
for kind, items in contents.items():
    if not isinstance(items, list):
        continue
    for item in items:
        if not isinstance(item, str) or not item:
            continue
        folder = os.path.join(pack_dir, kind, item)
        if kind in file_kinds:
            ok = os.path.exists(folder)
        else:
            ok = os.path.isdir(folder)
        if not ok:
            print(f"contents declares '{kind}/{item}' but no such item exists in the pack")
PY
)

# --- (o) skill-id grammar (contents.skills) ---------------------------------
# Per spec Section 3: skill-id MUST match the agentskills.io grammar, a
# stricter and distinct charset from the manifest name/vendor pattern above.
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  error "$line"
done < <(python3 - "$MANIFEST" <<'PY' 2>/dev/null || true
import json, re, sys
manifest = json.load(open(sys.argv[1]))
contents = manifest.get("contents")
skills = contents.get("skills") if isinstance(contents, dict) else None
if not isinstance(skills, list):
    sys.exit(0)
rx = re.compile(r'^[a-z0-9]+(-[a-z0-9]+)*$')
for skill_id in skills:
    if isinstance(skill_id, str) and skill_id and not rx.match(skill_id):
        print(f"skill-id '{skill_id}' does not match ^[a-z0-9]+(-[a-z0-9]+)*\$ (contents.skills)")
PY
)

# --- (p) skill-id must equal the SKILL.md name field ------------------------
# Spec Section 3 (A7-strength): "validators MUST enforce ... name==folder-name".
# An ERROR, not a warning: unlike the contents-vs-folder check (i), this is
# not "does the declared item exist" (folders are the truth for that); it is
# a structural conformance rule of the skill item itself, same footing as
# the manifest name pattern check (d), which is also an ERROR.
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  error "$line"
done < <(python3 - "$MANIFEST" "$PACK_DIR" <<'PY' 2>/dev/null || true
import json, os, re, sys
manifest_path, pack_dir = sys.argv[1], sys.argv[2]
manifest = json.load(open(manifest_path))
contents = manifest.get("contents")
skills = contents.get("skills") if isinstance(contents, dict) else None
if not isinstance(skills, list):
    sys.exit(0)
for skill_id in skills:
    if not isinstance(skill_id, str) or not skill_id:
        continue
    skill_md = os.path.join(pack_dir, "skills", skill_id, "SKILL.md")
    if not os.path.isfile(skill_md):
        continue
    text = open(skill_md).read()
    m = re.match(r'^---\r?\n(.*?)\r?\n---\r?\n', text, re.DOTALL)
    if not m:
        continue
    nm = re.search(r'^name:\s*(.+?)\s*$', m.group(1), re.MULTILINE)
    if not nm:
        continue
    name = nm.group(1).strip().strip('"\'')
    if name != skill_id:
        print(f"skill-id '{skill_id}' does not match SKILL.md name field '{name}'")
PY
)

# --- (q) skill items must be exactly skills/<name>/SKILL.md (depth 1) -------
# Spec Section 3 (A10): a nested skills/<name>/<sub>/SKILL.md is invalid.
# Structural, so it runs against the actual skills/ tree regardless of what
# contents declares (folders are the truth for existence, not for depth).
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  error "$line"
done < <(python3 - "$PACK_DIR" <<'PY' 2>/dev/null || true
import os, sys
pack_dir = sys.argv[1]
skills_dir = os.path.join(pack_dir, "skills")
if not os.path.isdir(skills_dir):
    sys.exit(0)
for root, dirs, files in os.walk(skills_dir):
    if "SKILL.md" not in files:
        continue
    rel = os.path.relpath(root, skills_dir)
    if rel == os.curdir:
        print("SKILL.md found directly in skills/; it must be inside skills/<name>/")
    elif os.sep in rel:
        print(f"skill nested deeper than depth 1: skills/{rel}/SKILL.md is invalid (must be skills/<name>/SKILL.md)")
PY
)

# --- (r) routine.json 'script' must stay inside the routine's own subfolder -
# Spec Section 5.4 (A8): containment for a descriptor field whose value is a
# path into the item's own files. No '../' escape, no absolute path.
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  error "$line"
done < <(python3 - "$PACK_DIR" <<'PY' 2>/dev/null || true
import json, os, sys
pack_dir = sys.argv[1]
routines_dir = os.path.join(pack_dir, "routines")
if not os.path.isdir(routines_dir):
    sys.exit(0)
for name in sorted(os.listdir(routines_dir)):
    descriptor = os.path.join(routines_dir, name, "routine.json")
    if not os.path.isfile(descriptor):
        continue
    try:
        with open(descriptor) as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        continue
    script = data.get("script") if isinstance(data, dict) else None
    if not isinstance(script, str) or not script:
        continue
    if os.path.isabs(script):
        print(f"routines/{name}/routine.json: 'script' must be a relative path, not absolute (got: {script})")
        continue
    routine_root = os.path.join(routines_dir, name)
    resolved = os.path.normpath(os.path.join(routine_root, script))
    routine_root_norm = os.path.normpath(routine_root)
    if resolved != routine_root_norm and not resolved.startswith(routine_root_norm + os.sep):
        print(f"routines/{name}/routine.json: 'script' escapes its own subfolder (got: {script})")
PY
)

# --- (j) README.md missing = warning ---------------------------------------
if [[ ! -f "$PACK_DIR/README.md" ]]; then
  warn "README.md is missing"
fi

# --- (k) lifecycle script contract -----------------------------------------
for script in install.sh uninstall.sh; do
  if [[ -e "$PACK_DIR/$script" ]]; then
    if [[ ! -x "$PACK_DIR/$script" ]]; then
      error "$script is not executable (missing +x)"
    fi
    first_line="$(head -n 1 "$PACK_DIR/$script" 2>/dev/null || true)"
    case "$first_line" in
      \#!*) : ;;
      *) error "$script is missing a shebang (first line must start with #!)" ;;
    esac
    if grep -qE '\b(curl|wget|nc)\b' "$PACK_DIR/$script" 2>/dev/null; then
      warn "$script uses network commands (curl/wget/nc); informational only"
    fi
  fi
done

# --- (l) scan.exclude patterns match nothing = warning ---------------------
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  warn "$line"
done < <(python3 - "$MANIFEST" "$PACK_DIR" <<'PY' 2>/dev/null || true
import json, os, re, sys
manifest_path, pack_dir = sys.argv[1], sys.argv[2]
manifest = json.load(open(manifest_path))
scan = manifest.get("scan")
if not isinstance(scan, dict):
    sys.exit(0)
excludes = scan.get("exclude")
if not isinstance(excludes, list):
    sys.exit(0)

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

relpaths = []
for root, dirs, files in os.walk(pack_dir):
    for name in files:
        relpaths.append(os.path.relpath(os.path.join(root, name), pack_dir))
    for name in dirs:
        relpaths.append(os.path.relpath(os.path.join(root, name), pack_dir))

for pattern in excludes:
    if not isinstance(pattern, str) or not pattern:
        continue
    rx = glob_to_regex(pattern)
    if not any(rx.match(rp) for rp in relpaths):
        print(f"scan.exclude pattern matches nothing in the pack: {pattern}")
PY
)

# --- (m) placeholder tokens must never pass validation ---------------------
if grep -qE '__[A-Z_]+__' "$MANIFEST" 2>/dev/null; then
  error "manifest.json contains unreplaced placeholder tokens (e.g. __PACK_NAME__); placeholder tokens must never pass validation"
fi

# --- summary ---------------------------------------------------------------
if [[ "$errors" -gt 0 ]]; then
  echo "FAIL: $errors error(s), $warnings warning(s)"
  exit 1
elif [[ "$warnings" -gt 0 ]]; then
  echo "PASS (with warnings): $warnings warning(s)"
  exit 2
else
  echo "PASS"
  exit 0
fi