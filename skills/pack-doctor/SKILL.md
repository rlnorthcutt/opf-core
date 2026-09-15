---
name: pack-doctor
description: Scan installed packs for placement, registration, lock, and dependency problems; report them in plain language; and fix the safe ones with explicit approval.
---

# pack-doctor

Diagnose the packs installed on this system: are they in the right place
for their trust tier, are their skills/tools/routines/agents actually
registered so the harness can see them, does `.opf-lock` still match
on-disk content, and are declared dependencies findable. Report findings
in plain language, then offer to fix the safe ones.

The canonical example this skill exists for: a pack sitting in the wrong
place can leave its skills unregistered - the harness never sees them, and
it looks like the pack "didn't install" when it actually just isn't where
anything is looking for it.

## Working directory assumption

Skills may run with the `OPF_CORE` environment variable pointing at the
opf-core checkout. If `OPF_CORE` is set, locate `pack-doctor.sh` and
`validate-pack.sh` under `$OPF_CORE/scripts/`. Otherwise, locate them
relative to this skill if it is bundled with opf-core (for example
`<opf-core>/scripts/pack-doctor.sh`). If neither is available, ask the user
for the opf-core checkout path.

## Determining what to scan

This skill needs to know where packs actually live on this system, which
varies by harness (spec `opf-host-layout.md` Section 1 is a non-normative
recommendation, not a universal location):

1. If the harness follows the host-layout profile, use its defaults:
   `--owned-root ~/packs --external-root ~/.packs-external`.
2. If the harness manages packs in its own location (for example a
   git-native harness with auto-discovery), ask the user where that is and
   pass it as `--owned-root`/`--external-root` as appropriate, or explain
   that placement/registration checks will be limited to whatever roots
   are given.
3. If the harness materializes items into a native per-type tree via
   symlinks (Section 1.4), also pass `--native-root <dir>` so the
   registration check can run. If it doesn't (or you don't know), omit it -
   the script skips that check gracefully with a NOTE rather than guessing.
4. Determine the identity to check against each pack's `OWNERS`: pass
   `--owner <name>` for each name/email the current user goes by, or let
   the script fall back to `git config user.name`/`user.email` read from
   inside each pack.

## Procedure

1. **Run a report-only scan first.** Never pass `--fix` on the first run:
   `bash <opf-core>/scripts/pack-doctor.sh --owned-root <dir> --external-root <dir> [--native-root <dir>] [--owner <name> ...]`.

2. **Translate the report into plain language, per pack.** Do not paste
   raw script output at the user. For each pack with findings, summarize
   what's wrong and why it matters in one or two sentences - use the
   script's own explanations (they already cite the relevant spec section)
   as your source of truth, but shorten them. Group findings by what the
   fix would be:
   - **Fixable now** (`move_pack`, `create_symlink`, `remove_symlink` in
     the script's fix list): "this pack is in the wrong place / this skill
     isn't registered - I can fix this."
   - **Needs your decision, not fixable by this skill**: a naming
     collision (spec `opf-host-layout.md` Section 1.6 - two packs both
     have an item with the same id; ask the user which one to rename),
     an unsatisfied/missing dependency (needs an actual install, which
     goes through `pack-install` with its own approval gates, not a
     silent fix here), or `.opf-lock` checksum drift (could be legitimate
     rolling-release content, or could be real tampering - ask the user
     which, don't assume).

3. **Ask which fixable findings to apply.** Offer "fix all of the safe
   ones," "fix none," or "let me choose" (in which case use `--only
   <pack-name>` per pack the user confirms). Never apply a fix without this
   step, even though the script's own `confirm()` prompts would also catch
   an unapproved change - the user should decide from your plain-language
   summary, not from raw tool prompts.

4. **Re-run with `--fix`** (and `--yes`, since approval already happened in
   step 3) for the confirmed scope. The script re-scans between its own
   fix phases so a single run fully resolves a "misplaced and unregistered"
   pack together, not just one half of it.

5. **Report the after-state in plain language.** The script prints its own
   "Report after fixes" section - summarize what changed and what (if
   anything) still needs the user's attention, using the same plain-language
   translation as step 2.

## Notes

- This skill and its script never install anything, never run any pack's
  `install.sh`, and never resolve a missing dependency by installing it.
  Those go through `pack-install`, which has its own approval gates - a
  diagnostic tool must not silently gain the power to install code.
- A naming collision (two packs' native-tree entries for the same item id
  pointing at different packs) is never auto-fixed, even with `--yes`: the
  script reports it as an error and expects a human to choose which pack
  to rename (spec `opf-host-layout.md` Section 1.6). Re-pointing the
  symlink automatically would silently change which pack's item the
  harness actually uses.
- `.opf-lock` checksum drift is reported, never silently accepted or
  reverted. Rewriting the lock to match on-disk content would erase
  evidence if the drift is real tampering rather than legitimate
  rolling-release content changes (spec Section 9.2).
- The version-range-satisfaction question for a found dependency ("is
  1.2.0 actually within `^1.0.0`") is deliberately NOT evaluated by the
  script - spec Section 4.5 requires a harness to reject a range it cannot
  parse rather than guess, and a partial semver-range implementation would
  risk being subtly wrong. Report what's found and let the user (or
  `pack-install`, which does implement real resolution) judge it.

See `spec/opf-host-layout.md` Section 1.3 for trust tier and Section 1.4-1.6
for symlink materialization and the collision rule, and
`spec/opf-pack-boundaries.md` Section 2 for `OWNERS`.
