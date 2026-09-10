---
name: pack-install
description: Install or update an OPF pack: validate, scan, approve, configure, install, atomically swap.
---

# pack-install

Install or update an OPF pack. This is the canonical operator skill for OPF
(Section 8.1 of `spec/opf-spec-v1.md`). It is an ordinary `SKILL.md` skill, so
any harness that can run skills and shell commands can use it. OPF requires
zero harness-native pack features.

Follow the procedure below in order. It is deterministic.

## Procedure

1. **Validate the manifest.** Validate the pack's `manifest.json` against
   `schema/v1/manifest.schema.json`. Reject the install on any validation
   failure. Do not proceed past this step on failure.

2. **Stage the pack.** Copy the incoming pack into a temporary staging
   directory, for example `<pack>.new`, as a sibling of the final install
   path.

3. **Scan the staging copy.** Run the static scan on the staging directory.
   Error-class findings stop the install here. Warnings are surfaced for user
   acknowledgment before continuing.

4. **Obtain explicit user approval for `install.sh`.** Show the full text of
   `install.sh` on a first install. On an update, show the diff against the
   previously installed (and previously approved) version. Do not run
   `install.sh` without explicit approval. A pack with no `install.sh` does
   not require this step.

5. **Resolve configuration.** Prompt the user for any required config entries
   declared in the manifest's `config` block (Section 4.4). Store the resolved
   values outside the pack root (for example the harness secret store or a
   config location adjacent to the runtime data directory). Secrets never go
   in the pack.

6. **Write `.opf-env` into the staging directory.** Include the five `PACK_*`
   variables plus the resolved config values as environment variables:

   | Variable | Meaning |
   |---|---|
   | `PACK_ROOT` | The staging directory. |
   | `PACK_NAME` | The pack name from the manifest. |
   | `PACK_DATA_DIR` | The runtime data directory for the pack. |
   | `PACK_VERSION` | The pack version from the manifest. |
   | `PACK_INSTALL_DIR` | The FINAL installed path. |
   | `<config keys>` | Resolved config values as env vars. |

7. **Run `install.sh`.** Run it with cwd = the staging directory,
   `PACK_ROOT` = the staging directory, and `PACK_INSTALL_DIR` = the FINAL
   installed path (Section 8.4). Treat a non-zero exit as a failed install.

8. **Write `.opf-lock` into the staging directory** on success (exit 0).
   Record the version, date, source (including the commit SHA when the source
   is git), checksums, dependency closure, and `data_dir`.

9. **Swap.** Replace the installed pack with the staged directory using two
   renames: rename the installed pack to `<pack>.old`, rename the staging
   directory to the installed path, then delete `<pack>.old` (Section 8.1.1).
   On any failure before the swap, remove the staging directory; the
   previously installed pack is left untouched.

## Notes

- `.opf-env` and `.opf-lock` are excluded from the scan. The installer never
  scans its own state files.
- Install is atomic: no partial state is ever visible. The old pack remains
  intact on any failure.
- `install.sh` must be idempotent and fail-safe. A non-zero exit means the
  install failed and must be reported to the user.

See `spec/opf-spec-v1.md` Section 8.1 for the normative procedure.