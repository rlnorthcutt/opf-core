#!/usr/bin/env bash
#
# pack-doctor.sh - scan installed packs for placement, registration, lock,
# and dependency problems, report them, and optionally fix the safe ones.
#
# Usage:
#   scripts/pack-doctor.sh [options]
#
# Options:
#   --owned-root DIR      A root to scan for Owned packs: flat layout,
#                          <root>/<name>/manifest.json (repeatable).
#                          Default: ~/packs
#   --external-root DIR   A root to scan for External packs: vendor-nested
#                          layout, <root>/<vendor>/<name>/manifest.json
#                          (repeatable). Default: ~/.packs-external
#   --native-root DIR     The harness's native per-type tree (contains
#                          skills/, tools/, routines/, agents/, artifacts/),
#                          used to check symlink registration (spec
#                          opf-host-layout.md Section 1.4). Optional: not
#                          every harness uses this pattern; omitting it
#                          just skips the registration check with a NOTE.
#   --owner NAME           An identity to check against each pack's OWNERS
#                          file (repeatable). Default: this pack's own
#                          `git config user.name` / `user.email`, read from
#                          inside each pack's directory.
#   --only PACK_NAME       Scope --fix to only this pack (repeatable). Without
#                          it, --fix applies to every pack with a fixable
#                          finding. Report-only runs always cover every pack
#                          regardless of --only.
#   --fix                  Apply safe, reversible fixes after confirmation:
#                          move a misplaced pack to its correct root, or
#                          create/remove a native-tree symlink. Everything
#                          else (collisions, dependency gaps, checksum
#                          drift) is reported only - those need a human
#                          decision, not a mechanical fix.
#   --yes                  Skip confirmation prompts for --fix.
#   -h, --help
#
# What this checks, per discovered pack:
#   - manifest/structural validity (delegates to validate-pack.sh)
#   - placement: does the pack's actual location (flat under an owned root,
#     or vendor-nested under an external root) match the tier implied by
#     OWNERS (spec Section 3; opf-host-layout.md Section 1.3)? This is the
#     "pack is in the wrong place" case - the exact scenario that can leave
#     a pack's skills unregistered in the native tree.
#   - registration (only with --native-root): does each item (skill, tool,
#     routine, agent) have a native-tree entry that resolves to THIS pack's
#     copy? Missing, dangling, or pointing at a different pack are each
#     reported distinctly.
#   - lock drift: does .opf-lock's recorded checksums match the pack's
#     current on-disk content?
#   - dependencies: is each declared dependency (vendor/name) findable among
#     the scanned packs? Version RANGE SATISFACTION is not evaluated here
#     (that requires a real node-semver range engine - spec Section 4.5
#     explicitly says a harness MUST reject a range it cannot parse rather
#     than guess, and this tool does not implement one); found/not-found
#     and the versions on each side are reported so a human can judge.
#
# What this does NOT do: install anything, run any pack's install.sh, or
# resolve a dependency that's missing. Those go through pack-install, with
# its own approval gates - a diagnostic tool must not silently gain the
# power to install code.
#
# Exit codes: 0 clean, 1 at least one error-class finding, 2 warnings only.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATOR="$SCRIPT_DIR/validate-pack.sh"

usage() {
  sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

OWNED_ROOTS=()
EXTERNAL_ROOTS=()
NATIVE_ROOT=""
OWNERS_ARG=()
ONLY=()
FIX=0
YES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --owned-root)
      [[ $# -ge 2 ]] || { echo "ERROR: --owned-root requires a value" >&2; exit 1; }
      OWNED_ROOTS+=("$2"); shift 2 ;;
    --external-root)
      [[ $# -ge 2 ]] || { echo "ERROR: --external-root requires a value" >&2; exit 1; }
      EXTERNAL_ROOTS+=("$2"); shift 2 ;;
    --native-root)
      [[ $# -ge 2 ]] || { echo "ERROR: --native-root requires a value" >&2; exit 1; }
      NATIVE_ROOT="$2"; shift 2 ;;
    --owner)
      [[ $# -ge 2 ]] || { echo "ERROR: --owner requires a value" >&2; exit 1; }
      OWNERS_ARG+=("$2"); shift 2 ;;
    --only)
      [[ $# -ge 2 ]] || { echo "ERROR: --only requires a value" >&2; exit 1; }
      ONLY+=("$2"); shift 2 ;;
    --fix) FIX=1; shift ;;
    --yes) YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 1 ;;
    *) echo "ERROR: unexpected positional argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ ${#OWNED_ROOTS[@]} -eq 0 ]]; then OWNED_ROOTS=("$HOME/packs"); fi
if [[ ${#EXTERNAL_ROOTS[@]} -eq 0 ]]; then EXTERNAL_ROOTS=("$HOME/.packs-external"); fi

confirm() {
  local prompt="$1"
  if [[ $YES -eq 1 ]]; then return 0; fi
  if [[ -t 0 ]]; then
    local ans
    read -r -p "$prompt [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]]
    return $?
  fi
  echo "ERROR: non-interactive and no --yes; refusing to apply fixes without explicit approval." >&2
  return 1
}

# --- Scan: one python3 pass computes the full report as JSON -----------------
# A function, not a one-shot: --fix needs to re-scan between applying
# move_pack fixes and applying symlink fixes, because a symlink target
# computed from a pre-move snapshot would point at a pack's OLD location.
PY_ARGS=()
for r in "${OWNED_ROOTS[@]}"; do PY_ARGS+=(--owned-root "$r"); done
for r in "${EXTERNAL_ROOTS[@]}"; do PY_ARGS+=(--external-root "$r"); done
if [[ -n "$NATIVE_ROOT" ]]; then PY_ARGS+=(--native-root "$NATIVE_ROOT"); fi
for o in "${OWNERS_ARG[@]:-}"; do [[ -n "$o" ]] && PY_ARGS+=(--owner "$o"); done

run_scan() {
  local out_path="$1"
  python3 - "$out_path" "$VALIDATOR" "${PY_ARGS[@]}" <<'PY'
import argparse, hashlib, json, os, re, subprocess, sys

p = argparse.ArgumentParser()
p.add_argument("out_path")
p.add_argument("validator")
p.add_argument("--owned-root", action="append", default=[])
p.add_argument("--external-root", action="append", default=[])
p.add_argument("--native-root", default=None)
p.add_argument("--owner", action="append", default=[])
args = p.parse_args()

# Absolute, right away: a symlink's relative target resolves relative to
# the symlink's OWN directory, not the process cwd, so a relative root here
# would silently produce a dangling create_symlink fix the moment the
# native root and the pack root aren't the same relative depth.
owned_roots = [os.path.abspath(r) for r in args.owned_root]
external_roots = [os.path.abspath(r) for r in args.external_root]
native_root = os.path.abspath(args.native_root) if args.native_root else None
cli_owners = args.owner

ITEM_KINDS = ["skills", "tools", "routines", "agents"]


def read_manifest(pack_dir):
    try:
        with open(os.path.join(pack_dir, "manifest.json")) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def discover(root, nested):
    """nested=False: <root>/<name>/manifest.json. nested=True (external):
    <root>/<vendor>/<name>/manifest.json."""
    found = []
    if not os.path.isdir(root):
        return found
    if not nested:
        for name in sorted(os.listdir(root)):
            pack_dir = os.path.join(root, name)
            if os.path.isfile(os.path.join(pack_dir, "manifest.json")):
                found.append((pack_dir, "flat"))
    else:
        for vendor in sorted(os.listdir(root)):
            vendor_dir = os.path.join(root, vendor)
            if not os.path.isdir(vendor_dir):
                continue
            for name in sorted(os.listdir(vendor_dir)):
                pack_dir = os.path.join(vendor_dir, name)
                if os.path.isfile(os.path.join(pack_dir, "manifest.json")):
                    found.append((pack_dir, "nested"))
    return found


packs = []
seen_realpaths = set()
for root in owned_roots:
    for pack_dir, structural in discover(root, nested=False):
        rp = os.path.realpath(pack_dir)
        if rp in seen_realpaths:
            continue
        seen_realpaths.add(rp)
        packs.append({"path": pack_dir, "structural": structural, "root_kind": "owned-root"})
for root in external_roots:
    for pack_dir, structural in discover(root, nested=True):
        rp = os.path.realpath(pack_dir)
        if rp in seen_realpaths:
            continue
        seen_realpaths.add(rp)
        packs.append({"path": pack_dir, "structural": structural, "root_kind": "external-root"})

# Index every discovered pack by (vendor, name) for the dependency check.
by_vendor_name = {}
for pack in packs:
    manifest = read_manifest(pack["path"]) or {}
    key = (manifest.get("vendor") or "", manifest.get("name") or "")
    by_vendor_name.setdefault(key, []).append((pack["path"], manifest.get("version") or ""))


def owners_list(pack_dir):
    owners_path = os.path.join(pack_dir, "OWNERS")
    if not os.path.isfile(owners_path):
        return None
    names = []
    with open(owners_path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            names.append(line)
    return names


def git_identity(pack_dir):
    identities = []
    for key in ("user.name", "user.email"):
        try:
            out = subprocess.run(
                ["git", "-C", pack_dir, "config", "--get", key],
                capture_output=True, text=True, timeout=5,
            )
            if out.returncode == 0 and out.stdout.strip():
                identities.append(out.stdout.strip())
        except (OSError, subprocess.SubprocessError):
            pass
    return identities


def compute_checksums(pack_dir):
    checksums = {}
    skip = {".opf-env", ".opf-lock"}
    for root, dirs, files in os.walk(pack_dir):
        if ".git" in dirs:
            dirs.remove(".git")
        for fname in files:
            full = os.path.join(root, fname)
            rel = os.path.relpath(full, pack_dir)
            if rel in skip:
                continue
            h = hashlib.sha256()
            try:
                with open(full, "rb") as fh:
                    for chunk in iter(lambda: fh.read(65536), b""):
                        h.update(chunk)
            except OSError:
                continue
            checksums[rel] = f"sha256:{h.hexdigest()}"
    return checksums


results = []
fixes = []

for pack in packs:
    pack_dir = pack["path"]
    manifest = read_manifest(pack_dir)
    findings = []  # list of {severity, message}
    pack_fixes = []

    def add(severity, message):
        findings.append({"severity": severity, "message": message})

    if manifest is None:
        add("error", "manifest.json missing or not valid JSON; skipping further checks for this pack")
        results.append({"path": pack_dir, "vendor": None, "name": None, "findings": findings, "fixes": []})
        continue

    vendor = manifest.get("vendor")
    name = manifest.get("name") or os.path.basename(pack_dir)

    # --- (a) delegate structural/manifest validity to validate-pack.sh -----
    try:
        proc = subprocess.run([args.validator, pack_dir], capture_output=True, text=True)
        if proc.returncode == 1:
            add("error", "validate-pack.sh reported error(s):\n" + proc.stdout.strip())
        elif proc.returncode == 2:
            add("warning", "validate-pack.sh reported warning(s):\n" + proc.stdout.strip())
        elif proc.returncode != 0:
            add("warning", f"validate-pack.sh exited with unexpected status {proc.returncode}")
    except OSError as exc:
        add("warning", f"could not run validate-pack.sh: {exc}")

    # --- (b) placement: structural location vs OWNERS-implied tier ---------
    owners = owners_list(pack_dir)
    identities = list(cli_owners) if cli_owners else git_identity(pack_dir)
    if owners is None:
        add("info", "no OWNERS file; cannot determine intended trust tier for this pack")
        intended = None
    elif not identities:
        add("info", "no --owner given and no git identity found; cannot check OWNERS membership")
        intended = None
    else:
        intended = "owned" if any(i in owners for i in identities) else "external"

    structural = "owned" if pack["root_kind"] == "owned-root" else "external"
    if intended is not None and intended != structural:
        if intended == "owned":
            dest_root = owned_roots[0]
            dest = os.path.join(dest_root, name)
            add(
                "warning",
                f"you are listed in OWNERS but this pack sits under an external root "
                f"({pack['structural']} layout); it should be flat under an owned root, "
                f"e.g. {dest} - a pack sitting in the wrong root can leave a harness that "
                f"only scans configured roots unable to see its skills/tools at all",
            )
            pack_fixes.append({"type": "move_pack", "from": pack_dir, "to": dest})
        else:
            if not vendor:
                add(
                    "warning",
                    "you are not listed in OWNERS and this pack sits under an owned root, "
                    "but it has no vendor field so an external destination cannot be computed "
                    "automatically - add a vendor and move it under an external root by hand",
                )
            else:
                dest_root = external_roots[0]
                dest = os.path.join(dest_root, vendor, name)
                add(
                    "warning",
                    f"you are not listed in OWNERS but this pack sits under an owned root "
                    f"(editable); it should be locked under an external root, e.g. {dest}",
                )
                pack_fixes.append({"type": "move_pack", "from": pack_dir, "to": dest})

    # --- (c) native-tree registration (only if --native-root given) --------
    if native_root:
        for kind in ITEM_KINDS:
            kind_dir = os.path.join(pack_dir, kind)
            if not os.path.isdir(kind_dir):
                continue
            for item in sorted(os.listdir(kind_dir)):
                item_path = os.path.join(kind_dir, item)
                if not os.path.isdir(item_path):
                    continue
                native_entry = os.path.join(native_root, kind, item)
                if not os.path.lexists(native_entry):
                    add(
                        "warning",
                        f"{kind}/{item} is not registered in the native tree "
                        f"({native_entry} does not exist) - a harness that discovers items "
                        f"from the native tree will not see it",
                    )
                    pack_fixes.append({
                        "type": "create_symlink", "native_path": native_entry, "target": item_path,
                    })
                    continue
                if os.path.islink(native_entry):
                    link_target = os.path.realpath(native_entry)
                    if not os.path.exists(native_entry):
                        add("warning", f"{kind}/{item}'s native-tree entry ({native_entry}) is a dangling symlink")
                        pack_fixes.append({"type": "remove_symlink", "native_path": native_entry})
                    elif link_target != os.path.realpath(item_path):
                        add(
                            "error",
                            f"{kind}/{item}'s native-tree entry ({native_entry}) resolves to a "
                            f"DIFFERENT pack's copy ({link_target}) - a naming collision; resolve "
                            f"by renaming one of them (spec opf-host-layout.md Section 1.6), not "
                            f"by re-pointing the symlink automatically",
                        )
                else:
                    add(
                        "info",
                        f"{kind}/{item}'s native-tree entry ({native_entry}) is a real directory, "
                        f"not a symlink to this pack - cannot verify it's the same item",
                    )

    # --- (d) .opf-lock drift ------------------------------------------------
    lock_path = os.path.join(pack_dir, ".opf-lock")
    if os.path.isfile(lock_path):
        try:
            with open(lock_path) as fh:
                lock = json.load(fh)
        except (OSError, ValueError):
            add("warning", ".opf-lock exists but is not valid JSON")
            lock = None
        if lock is not None:
            recorded = lock.get("checksums") or {}
            actual = compute_checksums(pack_dir)
            recorded_set, actual_set = set(recorded), set(actual)
            changed = sorted(f for f in (recorded_set & actual_set) if recorded[f] != actual[f])
            added = sorted(actual_set - recorded_set)
            removed = sorted(recorded_set - actual_set)
            total = len(changed) + len(added) + len(removed)
            if total:
                examples = (changed + added + removed)[:5]
                more = f" (+{total - len(examples)} more)" if total > len(examples) else ""
                add(
                    "warning",
                    f".opf-lock checksums differ from on-disk content for {total} file(s): "
                    f"{', '.join(examples)}{more} - expected under the rolling-release profile "
                    f"(spec Section 9.2) if this pack tracks a ref rather than tagged versions; "
                    f"otherwise investigate before trusting this copy",
                )
    else:
        add("info", "no .opf-lock; this pack may not have gone through pack-install")

    # --- (e) dependency existence (not range satisfaction) ------------------
    for dep in manifest.get("dependencies") or []:
        if not isinstance(dep, dict):
            continue
        dep_key = (dep.get("vendor") or "", dep.get("name") or "")
        dep_range = dep.get("version") or "?"
        matches = by_vendor_name.get(dep_key)
        if not matches:
            add(
                "warning",
                f"dependency {dep_key[0]}/{dep_key[1]} (range {dep_range}) was not found among "
                f"scanned packs - install it via pack-install, or scan its root too",
            )
        else:
            versions = ", ".join(v for _, v in matches)
            add(
                "info",
                f"dependency {dep_key[0]}/{dep_key[1]} (range {dep_range}) found, installed "
                f"version(s): {versions} - range satisfaction not evaluated, verify manually",
            )

    results.append({"path": pack_dir, "vendor": vendor, "name": name, "findings": findings, "fixes": pack_fixes})
    fixes.extend({**f, "pack": name} for f in pack_fixes)

with open(args.out_path, "w") as fh:
    json.dump({"results": results, "fixes": fixes, "native_root": native_root}, fh)
PY
}

print_report() {
  local out_path="$1"
  python3 - "$out_path" <<'PY'
import json, sys

with open(sys.argv[1]) as fh:
    data = json.load(fh)

if not data.get("native_root"):
    print("NOTE: no --native-root given; skipping native-tree registration checks "
          "(not every harness uses this pattern - see opf-host-layout.md Section 1.4)")

sev_rank = {"error": 2, "warning": 1, "info": 0}
worst = 0
for pack in data["results"]:
    label = f"{pack['vendor']}/{pack['name']}" if pack["vendor"] else (pack["name"] or pack["path"])
    print(f"\n== {label} ({pack['path']}) ==")
    if not pack["findings"]:
        print("  OK: no issues found")
        continue
    for f in pack["findings"]:
        worst = max(worst, sev_rank.get(f["severity"], 0))
        tag = {"error": "ERROR", "warning": "WARNING", "info": "NOTE"}[f["severity"]]
        for i, line in enumerate(f["message"].splitlines()):
            print(f"  {tag}:  {line}" if i == 0 else f"           {line}")

print()
if worst == 2:
    print("FAIL: at least one pack has an error-class finding")
elif worst == 1:
    print("PASS (with warnings)")
else:
    print("PASS")
PY
}

exit_code_for() {
  local out_path="$1"
  python3 -c '
import json, sys
data = json.load(open(sys.argv[1]))
sev_rank = {"error": 2, "warning": 1, "info": 0}
worst = 0
for pack in data["results"]:
    for f in pack["findings"]:
        worst = max(worst, sev_rank.get(f["severity"], 0))
sys.exit(1 if worst == 2 else 2 if worst == 1 else 0)
' "$out_path"
}

fixes_of_type() {
  # fixes_of_type OUT_PATH TYPE... - prints matching fixes as TSV.
  local out_path="$1"; shift
  python3 -c '
import json, sys
data = json.load(open(sys.argv[1]))
wanted = set(sys.argv[2:])
for f in data["fixes"]:
    t = f["type"]
    if t not in wanted:
        continue
    pack = f["pack"]
    if t == "move_pack":
        a, b = f["from"], f["to"]
    elif t == "create_symlink":
        a, b = f["native_path"], f["target"]
    elif t == "remove_symlink":
        a, b = f["native_path"], ""
    else:
        continue
    print(pack + "\t" + t + "\t" + a + "\t" + b)
' "$out_path" "$@"
}

apply_fixes() {
  # apply_fixes OUT_PATH TYPE... - applies only fixes of the given type(s),
  # so the caller controls ordering (moves before symlinks - see below).
  local out_path="$1"; shift
  local applied=0
  while IFS=$'\t' read -r pack_name ftype a b; do
    [[ -z "$ftype" ]] && continue
    if [[ ${#ONLY[@]} -gt 0 ]]; then
      match=0
      for want in "${ONLY[@]}"; do [[ "$want" == "$pack_name" ]] && match=1; done
      [[ $match -eq 0 ]] && continue
    fi
    case "$ftype" in
      move_pack)
        if [[ -e "$b" ]]; then
          echo "SKIP: $pack_name: destination already exists, resolve manually: $b" >&2
          continue
        fi
        confirm "Move $pack_name: $a -> $b ?" || { echo "Skipped $pack_name."; continue; }
        mkdir -p "$(dirname "$b")"
        mv "$a" "$b"
        echo "Moved $pack_name to $b"
        applied=1
        ;;
      create_symlink)
        if [[ -e "$a" || -L "$a" ]]; then
          # Another pack's fix in this same run (or something already there)
          # claimed this native path first - a real collision between two
          # unregistered items sharing an id, not something to silently
          # overwrite. Report and move on; a re-run after resolving the
          # collision by hand will pick this back up.
          echo "SKIP: $pack_name: native path already exists, resolve the collision manually: $a" >&2
          continue
        fi
        confirm "Create native-tree symlink for $pack_name: $a -> $b ?" || { echo "Skipped $pack_name."; continue; }
        mkdir -p "$(dirname "$a")"
        ln -s "$b" "$a"
        echo "Linked $a -> $b"
        applied=1
        ;;
      remove_symlink)
        confirm "Remove dangling symlink for $pack_name: $a ?" || { echo "Skipped $pack_name."; continue; }
        rm -f "$a"
        echo "Removed dangling symlink $a"
        applied=1
        ;;
    esac
  done < <(fixes_of_type "$out_path" "$@")
  return $((1 - applied))
}

# --- Run it -------------------------------------------------------------------
REPORT_JSON="$(mktemp)"
trap 'rm -f "$REPORT_JSON"' EXIT

run_scan "$REPORT_JSON"
print_report "$REPORT_JSON"

if [[ $FIX -eq 1 ]]; then
  echo
  echo "==> Applying fixes"
  # Three ordered passes, re-scanning between each: a fix computed from a
  # stale snapshot can point at the wrong place once an earlier fix in the
  # same run has already changed the filesystem underneath it.
  #   1. Moves first: a symlink target computed before a move would point
  #      at the pack's old (pre-move) location.
  #   2. Dangling-symlink removal next: removing one can turn an item's
  #      status from "dangling" into "missing," which needs a fresh scan
  #      to be recognized as a create_symlink fix.
  #   3. Symlink creation last, against the now-current state.
  if apply_fixes "$REPORT_JSON" move_pack; then
    run_scan "$REPORT_JSON"
  fi
  if apply_fixes "$REPORT_JSON" remove_symlink; then
    run_scan "$REPORT_JSON"
  fi
  apply_fixes "$REPORT_JSON" create_symlink || true
  run_scan "$REPORT_JSON"
  echo
  echo "==> Report after fixes"
  print_report "$REPORT_JSON"
fi

exit_code_for "$REPORT_JSON"
