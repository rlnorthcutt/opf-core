#!/usr/bin/env bash
#
# new-pack.sh - scaffold a new OPF pack from templates/pack-z-template/.
#
# Usage:
#   scripts/new-pack.sh <name> [vendor] [-d <description>] [--with <kinds>] [--allow-secrets]
#
# Copies the template to ./<name>, replaces placeholder tokens in all template
# text files (manifest.json, README.md, CHANGELOG.md, OWNERS, skill/example/SKILL.md),
# creates a .gitkeep-tracked subfolder for each item kind named in --with
# (comma-separated: tool, routine, agent, artifact - skill and data are
# already present in the template), runs a secrets gate, and prints next
# steps.
#
# Secrets gate: after scaffolding, the pack is scanned for likely secrets
# (gitleaks if available, otherwise a grep fallback). If findings are present
# the script REFUSES (exit 1) unless --allow-secrets is passed, which prints a
# loud warning and continues AT YOUR OWN RISK.
#
set -euo pipefail

NAME=""
VENDOR=""
DESCRIPTION=""
WITH_KINDS=""
ALLOW_SECRETS=0
POSITIONAL=()

USAGE="usage: $0 <name> [vendor] [-d <description>] [--with <kinds>] [--allow-secrets]"

# Parse options and positionals. Positionals are <name> and [vendor].
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--description)
      if [[ $# -lt 2 || -z "$2" ]]; then
        echo "ERROR: -d/--description requires a value" >&2
        exit 1
      fi
      DESCRIPTION="$2"
      shift 2
      ;;
    --with)
      if [[ $# -lt 2 || -z "$2" ]]; then
        echo "ERROR: --with requires a comma-separated list (tool,routine,agent,artifact)" >&2
        exit 1
      fi
      WITH_KINDS="$2"
      shift 2
      ;;
    --allow-secrets)
      ALLOW_SECRETS=1
      shift
      ;;
    -*)
      echo "ERROR: unknown option: $1" >&2
      echo "$USAGE" >&2
      exit 1
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

NAME="${POSITIONAL[0]:-}"
VENDOR="${POSITIONAL[1]:-}"
if [[ "${#POSITIONAL[@]}" -gt 2 ]]; then
  echo "ERROR: too many positional arguments" >&2
  echo "$USAGE" >&2
  exit 1
fi

if [[ -z "$NAME" ]]; then
  echo "$USAGE" >&2
  exit 1
fi

if [[ "$NAME" == "." || "$NAME" == ".." ]]; then
  echo "ERROR: name must not be '.' or '..'" >&2
  exit 1
fi

if ! [[ "$NAME" =~ ^[a-z0-9]([a-z0-9._-]*[a-z0-9])?$ ]]; then
  echo "ERROR: name must match ^[a-z0-9]([a-z0-9._-]*[a-z0-9])?$" >&2
  exit 1
fi

# Prompt for description if not provided.
if [[ -z "$DESCRIPTION" ]]; then
  if [[ -t 0 ]]; then
    printf 'Description (one-line summary): '
    IFS= read -r DESCRIPTION
  else
    IFS= read -r DESCRIPTION || true
  fi
fi
if [[ -z "$DESCRIPTION" ]]; then
  echo "ERROR: a description is required (-d/--description or prompt)" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/../templates/pack-z-template"
DEST="./$NAME"

if [[ -e "$DEST" ]]; then
  echo "ERROR: destination already exists: $DEST" >&2
  exit 1
fi

cp -R "$TEMPLATE" "$DEST"

# Replace placeholder tokens in ALL template text files.
# __PACK_NAME__, __VENDOR__, __DESCRIPTION__.
find "$DEST" -type f -print0 | while IFS= read -r -d '' f; do
  case "$f" in
    *.json|*.md|*/OWNERS|*/.gitignore) ;;
    *) continue ;;
  esac
  sed -i \
    -e "s/__PACK_NAME__/$NAME/g" \
    -e "s/__VENDOR__/$VENDOR/g" \
    -e "s/__DESCRIPTION__/$DESCRIPTION/g" \
    "$f"
done

# --- Create subfolders for requested item kinds -----------------------------
if [[ -n "$WITH_KINDS" ]]; then
  IFS=',' read -ra REQUESTED_KINDS <<< "$WITH_KINDS"
  for kind in "${REQUESTED_KINDS[@]}"; do
    kind="$(echo "$kind" | tr -d '[:space:]')"
    [[ -z "$kind" ]] && continue
    case "$kind" in
      tool|routine|agent|artifact)
        mkdir -p "$DEST/$kind"
        touch "$DEST/$kind/.gitkeep"
        ;;
      skill|data)
        : # already present in the template
        ;;
      *)
        echo "ERROR: unknown item kind for --with: $kind (expected: tool, routine, agent, artifact, skill, data)" >&2
        exit 1
        ;;
    esac
  done
fi

# --- Secrets gate ----------------------------------------------------------
echo "Scanning $DEST for secrets..."
findings=0
if command -v gitleaks >/dev/null 2>&1; then
  if ! gitleaks detect --source "$DEST" --no-git --redact -v >/tmp/opf-gitleaks.out 2>&1; then
    echo "gitleaks found potential secrets:"
    cat /tmp/opf-gitleaks.out
    findings=1
  fi
else
  # grep fallback. Exclude .git, data/, and binary files (grep -I).
  while IFS= read -r -d '' f; do
    case "$f" in
      */data/*|*/data|*/.git/*|*/.git) continue ;;
    esac
    if grep -InE 'AKIA[0-9A-Z]{16}|-----BEGIN (RSA|EC|OPENSSH|PGP) PRIVATE KEY|sk-[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{36}|xox[baprs]-[A-Za-z0-9-]{10,}|(password|passwd|secret|api[_-]?key|token)[[:space:]]*[=:][[:space:]]*["'"'"'][^"'"'"']{8,}' "$f" 2>/dev/null; then
      findings=1
    fi
  done < <(find "$DEST" -type f -print0)
fi

if [[ "$findings" -ne 0 ]]; then
  if [[ "$ALLOW_SECRETS" -eq 1 ]]; then
    echo
    echo "WARNING: potential secrets were found in $DEST but --allow-secrets was passed."
    echo "WARNING: You are proceeding AT YOUR OWN RISK. Do not publish this pack."
    echo
  else
    echo
    echo "ERROR: potential secrets were found in $DEST." >&2
    echo "ERROR: Remove the secrets and re-run, or pass --allow-secrets AT YOUR OWN RISK." >&2
    echo "ERROR: Refusing to create the pack." >&2
    exit 1
  fi
else
  echo "No secrets detected."
fi

ABS_DEST="$(cd "$DEST" && pwd)"
echo
echo "Created pack at $ABS_DEST"
echo
echo "Next steps:"
echo "  1. Edit $ABS_DEST/manifest.json (set vendor, etc.) if needed."
echo "  2. Run scripts/validate-pack.sh $ABS_DEST"
echo "  3. Add the CI include (.github/workflows/scan.yml or ci/pack-scan.gitlab-ci.yml)."
echo
echo "Note: the secrets gate ran on this pack. Re-run it before publishing if you"
echo "add files after scaffolding."