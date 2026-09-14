# opf-core

[![opf-core self-test](https://github.com/rlnorthcutt/opf-core/actions/workflows/self-test.yml/badge.svg)](https://github.com/rlnorthcutt/opf-core/actions/workflows/self-test.yml)
[![OPF spec](https://img.shields.io/badge/OPF--spec-v1-blueviolet.svg)](spec/opf-spec-v1.md)
[![License: Apache 2.0](https://img.shields.io/github/license/rlnorthcutt/opf-core)](LICENSE)

Core tooling and reference implementation for the Open Pack Format (OPF), a harness-agnostic standard for packaging skills, tools, data, and routines.

## What is OPF

OPF is a standard for portable packs of skills, tools, routines, and data that work in any agent harness. A pack is a manifest plus embedded files, and it installs, updates, and removes with zero native harness code. Everything happens via scripts, skills, and agents that any harness able to run shell commands can execute.

## Using this repo

There are two ways to adopt opf-core, and they compose - most orgs start with the first and add the second once they outgrow the defaults.

**1. Install it into your harness, then make and share packs.** Point your harness at this repo (a git-native harness with skill auto-discovery needs nothing more than the clone; otherwise set the `OPF_CORE` environment variable to the checkout path so the `create-pack`, `pack-install`, and `pack-release` skills can locate their scripts). From there: scaffold a pack with `create-pack` (or `scripts/new-pack.sh` directly) - it ships CI-wired from the template - install or update packs with `pack-install` (or `scripts/install-pack.sh`), and ship new versions with `pack-release` (or `scripts/bump-pack-version.sh`). No fork needed for this path. Before scaffolding your first few packs, skim `spec/opf-pack-boundaries.md` - deciding what goes in one pack versus several, and who owns each one, is much cheaper to get right up front than to split apart later.

**2. Fork and adapt it for your team or org.** opf-core is a public, harness-agnostic infra repo by design - forking is expected, not a workaround. Common adaptations, documented in `spec/opf-host-layout.md` Section 2:

- Merge `templates/pack-z-template/` into your fork (a single-repo or template-folded-into-core topology) if a separate template repo is more indirection than your org needs.
- Vendor the spec and schema (`spec/`, `schema/`) into a private core repo if your infra can't reach GitHub at build/validate time.
- Point `ci/pack-scan.gitlab-ci.yml`'s `OPF_CORE_REPO` and `.github/workflows/scan.yml`'s `opf-core-repo` input at your fork, so every pack's CI resolves scan rules from it instead of upstream.
- Extend `ci/semgrep-opf-rules.yml` with org-specific dangerous-pattern rules, and start a `pack-common` repo for skills/tools once a second pack needs to share one.

Either way, `spec/opf-spec-v1.md` is the normative contract: adopt as much or as little of this repo's tooling as you want, as long as you honor the spec.

## Repo layout

- `spec/` - the OPF v1 specification and its two non-normative companion docs: host layout/distribution topology, and pack boundaries/ownership guidance.
- `schema/v1/` - the JSON Schema for the OPF v1 manifest.
- `skills/pack-install/` - the canonical pack-install skill (validate, scan, approve, install, swap).
- `skills/create-pack/` - the skill for scaffolding a new pack from the template.
- `scripts/validate-pack.sh` - validate a pack directory against the spec.
- `scripts/new-pack.sh` - scaffold a new pack from the template.
- `scripts/install-pack.sh` - deterministically install/update a single pack (validate, stage, scan, approve, install, lock, atomic swap); the hard-enforcement counterpart to the pack-install skill for harnesses that can run scripts but not skills.
- `scripts/ci-install-scanners.sh` - installs semgrep/gitleaks/shellcheck for CI; shared by both CI templates below so they can't silently drift to different tool versions.
- `ci/semgrep-opf-rules.yml` - curated, registry-independent semgrep ruleset mapped to the spec's dangerous-pattern categories; the CI-blocking scan gate.
- `scripts/resolve-scan-excludes.py` - resolves a manifest's `scan.exclude` patterns to actual files for `install-pack.sh`, filtering out anything that is an executable file type (exclusions never apply to those).
- `scripts/secret-patterns.sh`, `scripts/pack-name-pattern.sh` - shared regexes sourced by the scripts above, kept in one place so the secret-detection fallback and name validation can't drift between scripts.
- `scripts/e2e-smoke-test.sh` - the end-to-end regression suite (see Testing below).
- `templates/pack-z-template/` - the starter template for a new pack.
- `ci/pack-scan.gitlab-ci.yml` - GitLab CI include for scanning a pack.
- `.github/workflows/scan.yml` - reusable GitHub Actions workflow for scanning a pack; consuming packs call this via `uses:`.
- `.github/workflows/self-test.yml` - this repo's own CI: runs `scripts/e2e-smoke-test.sh` against the scripts above, once in a degraded (no scanners installed) state and once after installing the real scanners, on every push and pull request.

## Getting started

Create a pack:

```
scripts/new-pack.sh <name> [vendor] -d "<description>" [--with tool,routine,agent,artifact]
```

Validate a pack:

```
scripts/validate-pack.sh <pack-dir>
```

Install a pack: use the pack-install skill, or for a single pack without dependency resolution, call `scripts/install-pack.sh <source-dir> <install-dir>` directly.

## Testing

```
scripts/e2e-smoke-test.sh
```

Runs the create -> validate -> install -> update -> downgrade lifecycle end to end in a throwaway temp directory, plus the security/atomicity guarantees the spec claims (secrets gate, path-traversal rejection, atomic install failure, validator fail-closed behavior). Uninstall is not yet covered (there is no `uninstall-pack.sh`; see `TODO.md`). It prints which of semgrep/gitleaks/shellcheck are installed, since their absence changes which code paths run; `.github/workflows/self-test.yml` runs it both ways on every push/PR so the real scanner paths are exercised even when your local machine doesn't have those tools.

## Status

OPF v1 spec is frozen (`spec/`). Reference implementation: Omnideck. See `TODO.md` for open implementation and ecosystem work.

## License

Apache 2.0.
