---
name: create-pack
description: Scaffold a new OPF pack from the template, creating subfolders for selected item kinds and enforcing the secrets gate before creating.
---

# create-pack

Scaffold a new OPF pack from the template in `templates/pack-z-template/`.
The scaffolder (`scripts/new-pack.sh`) enforces a secrets gate: it scans the
new pack for likely secrets and refuses to create it if any are found. This
skill instructs the agent to run `new-pack.sh` and to handle a refusal.

## Procedure

1. **Gather pack details from the user.** Ask for:
   - **name**: lowercase `[a-z0-9._-]`, 1-64 characters, no leading or
     trailing separator, and never `.` or `..`.
   - **vendor**: the publishing namespace.
   - **description**: a one-line summary.
   - **item kinds**: which items the pack will contain (skills, tools, data,
     routines, artifacts).

2. **Run the scaffolder.** Run `scripts/new-pack.sh <name> [vendor] -d
   "<description>" [--with <kinds>]`, where `<kinds>` is a comma-separated
   list drawn from the item kinds the user selected in step 1 (`tool`,
   `routine`, `agent`, `artifact` - omit `skill` and `data`, which the
   template already provides). The script copies the template, substitutes
   placeholder tokens, creates a `.gitkeep`-tracked subfolder for each
   requested kind, and runs the secrets gate.

3. **Verify the requested subfolders exist.** Confirm the scaffolder created
   a subfolder for each item kind the user selected in step 1. If `--with`
   was omitted or a kind was missed, create the subfolder by hand with a
   `.gitkeep` placeholder so git tracks the empty folder.

4. **Fill the manifest.** Edit `manifest.json` to set `name`, `version`
   (`0.1.0`), `pack_format` (`1`), `description`, and `vendor`. The
   scaffolder already substitutes `name`, `vendor`, and `description`.

5. **Handle the secrets gate.** `new-pack.sh` runs the secrets scan itself
   after scaffolding and before printing success. If it refuses (exit 1), do
   NOT bypass it. Tell the user which file and pattern matched, and stop.
   Only if the user explicitly accepts the risk may you re-run with
   `--allow-secrets`; print the loud warning the script emits.

6. **Point the user at the next steps.** Tell them to run
   `scripts/validate-pack.sh <pack-dir>` and to add the CI include
   (`.github/workflows/scan.yml` or `ci/pack-scan.gitlab-ci.yml`) to their
   repository.

## Notes

- Secrets never go in a pack. The scan flags likely secrets, and `.opf-env`
  must be gitignored.
- The template's `.gitignore` already excludes `.opf-env`, `.opf-lock`, and
  `.env`.
- The scaffolder refuses to create a pack that contains likely secrets unless
  `--allow-secrets` is passed at the user's explicit risk.

See `spec/opf-spec-v1.md` for the pack format and Section 7 for scanning.