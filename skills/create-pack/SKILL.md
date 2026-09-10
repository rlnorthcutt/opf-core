---
name: create-pack
description: Scaffold a new OPF pack from the template, checking for secrets before creating.
---

# create-pack

Scaffold a new OPF pack from the template in `templates/pack-z-template/`.
Before creating, check the new pack for secrets and refuse to create it if any
are found.

## Procedure

1. **Gather pack details from the user.** Ask for:
   - **name**: lowercase `[a-z0-9._-]`, 1-64 characters, no leading or
     trailing separator, and never `.` or `..`.
   - **vendor**: the publishing namespace.
   - **description**: a one-line summary.
   - **item kinds**: which items the pack will contain (skills, tools, data,
     routines, artifacts).

2. **Copy the template.** Copy `templates/pack-z-template/` to the new pack
   directory.

3. **Fill the manifest.** Edit `manifest.json` to set `name`, `version`
   (`0.1.0`), `pack_format` (`1`), `description`, and `vendor`.

4. **Check for secrets.** Run `gitleaks` if it is available. If it is not,
   grep the new pack for common key, token, and password patterns (for
   example `AKIA`, `-----BEGIN`, `sk-`, `ghp_`, `password =`, `api_key`,
   `secret`). Check every file in the new pack.

5. **Refuse to create if secrets are found.** If any secret is detected, do
   not create the pack. Tell the user which file and pattern matched, and
   stop.

6. **Point the user at the next steps.** Tell them to run
   `scripts/validate-pack.sh <pack-dir>` and to add the CI include
   (`.github/workflows/scan.yml` or `ci/pack-scan.gitlab-ci.yml`) to their
   repository.

## Notes

- Secrets never go in a pack. The scan flags likely secrets, and `.opf-env`
  must be gitignored.
- The template's `.gitignore` already excludes `.opf-env`, `.opf-lock`, and
  `.env`.

See `spec/opf-spec-v1.md` for the pack format and Section 9 for scanning.