#!/usr/bin/env bash
#
# new-pack.sh - scaffold a new OPF pack from templates/pack-z-template/.
#
# Usage:
#   scripts/new-pack.sh <name> [vendor]
#
# Copies the template to ./<name>, replaces placeholder tokens in
# manifest.json, and prints next steps.
#
# Secrets checking is NOT performed here; that lives in the create-pack skill
# (skills/create-pack/SKILL.md). Run that skill (or gitleaks) before publishing.
#
set -euo pipefail

NAME="${1:-}"
VENDOR="${2:-}"

if [[ -z "$NAME" ]]; then
  echo "usage: $0 <name> [vendor]" >&2
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/../templates/pack-z-template"
DEST="./$NAME"

if [[ -e "$DEST" ]]; then
  echo "ERROR: destination already exists: $DEST" >&2
  exit 1
fi

cp -R "$TEMPLATE" "$DEST"

# Replace placeholder tokens in manifest.json.
MANIFEST="$DEST/manifest.json"
sed -i \
  -e "s/__PACK_NAME__/$NAME/g" \
  -e "s/__VENDOR__/$VENDOR/g" \
  "$MANIFEST"

echo "Created pack at $DEST"
echo
echo "Next steps:"
echo "  1. Edit $MANIFEST (set description, vendor, etc.)."
echo "  2. Run scripts/validate-pack.sh $DEST"
echo "  3. Add the CI include (.github/workflows/scan.yml or ci/pack-scan.gitlab-ci.yml)."
echo
echo "Note: this script does not check for secrets. Run the create-pack skill"
echo "or gitleaks before publishing the pack."