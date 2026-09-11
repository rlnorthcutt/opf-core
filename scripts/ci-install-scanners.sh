#!/usr/bin/env bash
#
# ci-install-scanners.sh - install semgrep/gitleaks/shellcheck/jsonschema for
# opf-core's CI scan templates.
#
# Single source of truth for scanner installation, called by both
# ci/pack-scan.gitlab-ci.yml and .github/workflows/scan.yml, which both
# already check out this repo before running their scan step. Keeping the
# install logic in one script (rather than duplicated per-CI-system YAML)
# means the two templates cannot silently drift to different tool versions
# or different install behavior.
#
# Versions can be overridden via SHELLCHECK_VERSION / GITLEAKS_VERSION
# environment variables (both CI templates export these); otherwise the
# defaults below are used. Bump the defaults here periodically.
#
set -euo pipefail

SHELLCHECK_VERSION="${SHELLCHECK_VERSION:-0.10.0}"
GITLEAKS_VERSION="${GITLEAKS_VERSION:-8.21.2}"

SUDO=""
if [[ "$(id -u)" -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
fi

pip install --disable-pip-version-check --quiet semgrep jsonschema

if ! command -v shellcheck >/dev/null 2>&1; then
  curl -sSfL "https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/shellcheck-v${SHELLCHECK_VERSION}.linux.x86_64.tar.xz" \
    | $SUDO tar -xJ -f - -C /usr/local/bin --strip-components=1 "shellcheck-v${SHELLCHECK_VERSION}/shellcheck"
  $SUDO chmod +x /usr/local/bin/shellcheck
fi

if ! command -v gitleaks >/dev/null 2>&1; then
  curl -sSfL "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" \
    | $SUDO tar -xz -f - -C /usr/local/bin gitleaks
  $SUDO chmod +x /usr/local/bin/gitleaks
fi
