#!/usr/bin/env bash
#
# validate-pack.sh - validate an OPF pack directory against the v1 spec.
#
# Usage:
#   scripts/validate-pack.sh <pack-dir>
#
# Checks (per spec/opf-spec-v1.md):
#   (a) manifest.json exists and parses as JSON
#   (b) required fields present: name, version, pack_format (must be 1), description
#   (c) if python3 + jsonschema are available, validate against schema/v1/manifest.schema.json
#   (d) name matches ^[a-z0-9]([a-z0-9._-]*[a-z0-9])?$ and is not "." or ".."
#   (e) version matches the official semver regex
#   (f) path safety: no file path resolves outside the pack root
#       (checks for absolute symlinks and ".." components)
#   (g) if .opf-env exists, .gitignore must contain .opf-env
#   (h) if .opf-lock exists, warn it is installer-written state and should not be committed
#   (i) if a contents field is present, warn if declared items do not match actual folders
#   (j) README.md missing = warning
#
# Exit codes:
#   0  pass
#   1  error (a required check failed)
#   2  warning-only (no errors, but warnings were emitted)
#
# Dependency-light: bash + python3 (optional) + git (optional).
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

errors=0
warnings=0

note()  { echo "NOTE:    $*"; }
warn()  { echo "WARNING: $*"; warnings=$((warnings + 1)); }
error() { echo "ERROR:   $*"; errors=$((errors + 1)); }

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
  # Fallback: a minimal JSON sanity check using grep for balanced braces.
  if ! grep -q '{' "$MANIFEST" || ! grep -q '}' "$MANIFEST"; then
    error "manifest.json does not look like JSON (python3 not available for a full parse)"
    echo "FAIL: $errors error(s), $warnings warning(s)"
    exit 1
  fi
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

# --- (c) validate against schema if python3 + jsonschema available ---------
if command -v python3 >/dev/null 2>&1; then
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
fi

# --- (d) name pattern ------------------------------------------------------
if [[ -n "$name" ]]; then
  if [[ "$name" == "." || "$name" == ".." ]]; then
    error "name must not be '.' or '..'"
  elif ! [[ "$name" =~ ^[a-z0-9]([a-z0-9._-]*[a-z0-9])?$ ]]; then
    error "name does not match ^[a-z0-9]([a-z0-9._-]*[a-z0-9])?$ (got: $name)"
  fi
fi

# --- (e) version matches official semver regex -----------------------------
SEMVER='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-((0|[1-9][0-9]*|[0-9]*[a-zA-Z-][0-9a-zA-Z-]*)(\.(0|[1-9][0-9]*|[0-9]*[a-zA-Z-][0-9a-zA-Z-]*))*))?(\+([0-9a-zA-Z-]+(\.[0-9a-zA-Z-]+)*))?$'
if [[ -n "$version" && ! "$version" =~ $SEMVER ]]; then
  error "version does not match the official semver regex (got: $version)"
fi

# --- (f) path safety: no path resolves outside the pack root ---------------
# Check for ".." components and absolute symlinks.
while IFS= read -r -d '' entry; do
  rel="${entry#"$PACK_DIR"/}"
  case "$rel" in
    *"/../"*|"../"*|*"/..")
      error "path escapes pack root via '..': $rel"
      ;;
  esac
  if [[ -L "$entry" ]]; then
    target="$(readlink "$entry")"
    case "$target" in
      /*)
        error "absolute symlink escapes pack root: $rel -> $target"
        ;;
      *"/../"*|"../"*|*"/..")
        error "symlink escapes pack root via '..': $rel -> $target"
        ;;
    esac
  fi
done < <(find "$PACK_DIR" -print0)

# --- (g) .opf-env must be gitignored ---------------------------------------
if [[ -e "$PACK_DIR/.opf-env" ]]; then
  if [[ -f "$PACK_DIR/.gitignore" ]] && grep -q '^\.opf-env$' "$PACK_DIR/.gitignore"; then
    :
  else
    error ".opf-env exists but .gitignore does not contain .opf-env"
  fi
fi

# --- (h) .opf-lock is installer-written state -------------------------------
if [[ -e "$PACK_DIR/.opf-lock" ]]; then
  warn ".opf-lock is installer-written state and should not be committed"
fi

# --- (i) contents field vs actual folders ----------------------------------
if command -v python3 >/dev/null 2>&1; then
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    warn "${line#WARNING: }"
  done < <(python3 - "$MANIFEST" "$PACK_DIR" <<'PY' 2>/dev/null || true
import json, os, sys
manifest_path, pack_dir = sys.argv[1], sys.argv[2]
manifest = json.load(open(manifest_path))
contents = manifest.get("contents")
if not isinstance(contents, dict):
    sys.exit(0)
for kind, items in contents.items():
    if not isinstance(items, list):
        continue
    for item in items:
        if not isinstance(item, str) or not item:
            continue
        folder = os.path.join(pack_dir, kind, item)
        if not os.path.isdir(folder):
            print(f"contents declares '{kind}/{item}' but no such folder exists in the pack")
PY
)
fi

# --- (j) README.md missing = warning ---------------------------------------
if [[ ! -f "$PACK_DIR/README.md" ]]; then
  warn "README.md is missing"
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