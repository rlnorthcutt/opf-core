# __PACK_NAME__

__DESCRIPTION__

A pack in the Open Pack Format (OPF). A pack is a manifest plus embedded
files, containing one or more items: skills, tools, data, routines, or
artifacts. Packs install, update, and remove with zero native harness code.

See `spec/opf-spec-v1.md` in the opf-core repository for the format.

## Contents

- `manifest.json` - the OPF v1 manifest.
- `skills/` - skills in this pack.
- `data/` - data shipped with this pack.
- `.github/workflows/scan.yml`, `.gitlab-ci.yml` - CI scanning, already wired
  to opf-core's validator and scan template. No setup needed.

## Validate

```
scripts/validate-pack.sh .
```