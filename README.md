# opf-core

Core tooling and reference implementation for the Open Pack Format (OPF), a harness-agnostic standard for packaging skills, tools, data, and routines.

## What is OPF

OPF is a standard for portable packs of skills, tools, routines, and data that work in any agent harness. A pack is a manifest plus embedded files, and it installs, updates, and removes with zero native harness code. Everything happens via scripts, skills, and agents that any harness able to run shell commands can execute.

## Repo layout

- `spec/` - the OPF v1 specification and the host layout companion doc.
- `schema/v1/` - the JSON Schema for the OPF v1 manifest.
- `skills/pack-install/` - the canonical pack-install skill (validate, scan, approve, install, swap).
- `skills/create-pack/` - the skill for scaffolding a new pack from the template.
- `scripts/validate-pack.sh` - validate a pack directory against the spec.
- `scripts/new-pack.sh` - scaffold a new pack from the template.
- `templates/pack-z-template/` - the starter template for a new pack.
- `ci/` - GitLab CI include for scanning a pack.
- `.github/workflows/` - reusable GitHub Actions workflow for scanning a pack.

## Getting started

Validate a pack:

```
scripts/validate-pack.sh <pack-dir>
```

Create a pack:

```
scripts/new-pack.sh
```

Install a pack: use the pack-install skill.

## Status

v1 spec, reference implementation: Omnideck.

## License

Apache 2.0.