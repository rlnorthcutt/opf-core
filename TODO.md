# TODO

Open work items for opf-core. The OPF v1 spec is frozen in `spec/`; this list tracks implementation and ecosystem work.

## Spec and docs

- [ ] Update schema `$id` (`schema/v1/manifest.schema.json`) if/when the repo transfers to the omnideck-dev org (it currently points at `opf-core/opf-core`, a placeholder org)
- [ ] Mark `opf-plan-v2.md` and `pack-spec-v2.md` (older drafts in a separate artifacts folder) as superseded or delete them, so nobody implements from the wrong document
- [ ] Add a rationale/design-decisions appendix if adopters ask for the why behind choices (TOML rejection, no permissions block, etc.)

## Tooling (scripts/)

- [ ] `validate-pack.sh`: add support for validating against the schema with `jsonschema` when python3+jsonschema are present (currently partial); add tests
- [ ] `validate-pack.sh`: check `scan.exclude` patterns (warn when a pattern matches nothing, per spec)
- [ ] `new-pack.sh`: interactive mode (prompt for name/vendor/description/item kinds) in addition to flags
- [ ] Add a `scripts/install-pack.sh` or make the pack-install skill logic available as a callable script for harnesses without skill support
- [ ] Consider a single-binary CLI (go or python) once bash checks outgrow bash (per reference doc)

## Skills (skills/)

- [ ] `pack-install`: implement the full 9-step procedure robustly (currently a SKILL.md description; test against a real pack)
- [ ] `create-pack`: wire the gitleaks secrets check with a grep fallback; test the refuse-on-secret path
- [ ] Consider a `pack-update` skill if rolling-release workflows need an explicit update helper (spec currently: same-version reinstall via pack-install)

## CI

- [ ] Test `.github/workflows/scan.yml` as a reusable workflow from a real pack repo (`workflow_call` needs a caller)
- [ ] Test `ci/pack-scan.gitlab-ci.yml` include in a GitLab project
- [ ] Decide whether scan runs on PRs and/or pushes; document the recommended wiring in the reference doc

## Ecosystem

- [ ] Create `pack-common` (per-org shared content) and a real pack or two to exercise the full flow: create, validate, install, update, uninstall
- [ ] Exercise the symlink pattern (create-pack move scenario) and the collision rule in practice
- [ ] Publish the spec trio somewhere indexable (repo README, possibly a docs site later); registry stays independent per spec
- [ ] Gather early-adopter feedback (two orgs already gave feedback rounds; more field data wanted)
- [ ] Review the work/internal early implementation against the public spec and fold improvements back

## Housekeeping

- [ ] Tag v1.0.0 of the schema/spec when frozen
- [ ] Add CONTRIBUTING.md and a code of conduct if the repo goes public/community
- [ ] Consider GitHub Pages or a small docs site for the spec