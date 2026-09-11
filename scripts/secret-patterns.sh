#!/usr/bin/env bash
#
# secret-patterns.sh - shared secret-detection regex for the gitleaks-
# unavailable grep fallback used by new-pack.sh and install-pack.sh. Meant to
# be sourced, not executed. Kept in one place so the two fallback scanners
# cannot silently drift from each other; edit the pattern here only.
#
OPF_SECRET_GREP_PATTERN='AKIA[0-9A-Z]{16}|-----BEGIN (RSA|EC|OPENSSH|PGP) PRIVATE KEY|sk-[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{36}|xox[baprs]-[A-Za-z0-9-]{10,}|(password|passwd|secret|api[_-]?key|token)[[:space:]]*[=:][[:space:]]*["'"'"'][^"'"'"']{8,}'
