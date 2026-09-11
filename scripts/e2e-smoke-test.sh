#!/usr/bin/env bash
#
# e2e-smoke-test.sh - end-to-end smoke test for new-pack.sh, validate-pack.sh,
# and install-pack.sh. Exercises the golden path plus the specific
# security/atomicity guarantees the spec and these scripts claim, entirely
# inside a throwaway temp directory.
#
# Usage: scripts/e2e-smoke-test.sh
#
# Prints PASS/FAIL per check and a summary at the end. Exits 0 if every
# check passed, 1 if any failed.
#
# What this does NOT cover: semgrep/gitleaks/shellcheck are not installed on
# most dev machines, so those checks silently degrade to NOTE/fallback paths
# here rather than actually running (this script reports which tools were
# and weren't available). To exercise the real scanner path, install them
# (or run scripts/ci-install-scanners.sh) and re-run this script. It also
# does not exercise the CI templates themselves (ci/pack-scan.gitlab-ci.yml,
# .github/workflows/scan.yml) - those need a real GitLab/GitHub run.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NEW_PACK="$SCRIPT_DIR/new-pack.sh"
VALIDATE="$SCRIPT_DIR/validate-pack.sh"
INSTALL_PACK="$SCRIPT_DIR/install-pack.sh"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
FAILED_NAMES=()

pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() {
  FAIL=$((FAIL + 1))
  FAILED_NAMES+=("$1")
  echo "FAIL: $1"
  shift
  [[ $# -gt 0 ]] && printf '    %s\n' "$@"
}

# expect_exit "name" <expected-exit-code> -- <command...>
# Runs the command, captures combined output, compares exit code.
expect_exit() {
  local name="$1" expected="$2"
  shift 2
  local out rc
  out="$("$@" 2>&1)"
  rc=$?
  if [[ "$rc" -eq "$expected" ]]; then
    pass "$name"
  else
    fail "$name" "expected exit $expected, got $rc" "$(echo "$out" | tail -5)"
  fi
}

echo "Tool availability (affects which scan code paths get exercised):"
for t in semgrep gitleaks shellcheck; do
  if command -v "$t" >/dev/null 2>&1; then
    echo "  $t: available"
  else
    echo "  $t: NOT installed (fallback/NOTE path only)"
  fi
done
echo

# =============================================================================
echo "== new-pack.sh: golden path =="
cd "$WORKDIR"
expect_exit "new-pack: create with all item kinds, slash+ampersand in fields" 0 \
  "$NEW_PACK" golden "acme/co" -d "Reports w/ charts & graphs" --with tool,routine,agent,artifact --allow-secrets

if [[ -d golden ]]; then
  [[ -f golden/manifest.json ]] && python3 -c "import json; json.load(open('golden/manifest.json'))" 2>/dev/null \
    && pass "new-pack: manifest.json is valid JSON" \
    || fail "new-pack: manifest.json is valid JSON"

  grep -q "Reports w/ charts & graphs" golden/README.md 2>/dev/null \
    && pass "new-pack: description with / and & preserved exactly" \
    || fail "new-pack: description with / and & preserved exactly"

  grep -q '"vendor": "acme/co"' golden/manifest.json 2>/dev/null \
    && pass "new-pack: vendor with / preserved exactly" \
    || fail "new-pack: vendor with / preserved exactly"

  ! grep -rq "__PACK_NAME__\|__VENDOR__\|__DESCRIPTION__" golden/ 2>/dev/null \
    && pass "new-pack: no unreplaced placeholder tokens" \
    || fail "new-pack: no unreplaced placeholder tokens"

  all_dirs_present=1
  for d in tool routine agent artifact skill data; do
    [[ -d "golden/$d" ]] || all_dirs_present=0
  done
  [[ "$all_dirs_present" -eq 1 ]] \
    && pass "new-pack: --with created all requested subfolders" \
    || fail "new-pack: --with created all requested subfolders"
else
  fail "new-pack: golden path (no golden/ directory produced, skipping dependent checks)"
fi

echo
echo "== new-pack.sh: input validation happens before scaffolding =="
expect_exit "new-pack: --with typo is rejected" 1 \
  "$NEW_PACK" typo-test v -d "x" --with tols --allow-secrets
[[ ! -e "$WORKDIR/typo-test" ]] \
  && pass "new-pack: --with typo leaves no partial directory" \
  || fail "new-pack: --with typo leaves no partial directory"

echo
echo "== new-pack.sh: secrets gate =="
# The description is substituted into README.md/manifest.json at scaffold
# time, so a secret-shaped description is enough to exercise the gate
# without needing to seed a file after the fact.
expect_exit "new-pack: refuses to create a pack whose description contains a likely secret" 1 \
  "$NEW_PACK" secret-desc-test v -d "token: AKIAABCDEFGHIJKLMNOPQRST"
expect_exit "new-pack: --allow-secrets overrides the refusal" 0 \
  "$NEW_PACK" secret-desc-test-2 v -d "token: AKIAABCDEFGHIJKLMNOPQRST" --allow-secrets

# =============================================================================
echo
echo "== validate-pack.sh =="
expect_exit "validate: golden pack passes" 0 "$VALIDATE" golden

cp -R golden bad-name
python3 -c "
import json
m = json.load(open('bad-name/manifest.json'))
m['name'] = 'Not_Valid!'
json.dump(m, open('bad-name/manifest.json', 'w'))
"
expect_exit "validate: rejects an invalid pack name" 1 "$VALIDATE" bad-name

cp -R golden bad-datadir
python3 -c "
import json
m = json.load(open('bad-datadir/manifest.json'))
m['data_dir'] = '../../../../tmp/opf-smoketest-traversal'
json.dump(m, open('bad-datadir/manifest.json', 'w'))
"
expect_exit "validate: rejects a data_dir containing '..'" 1 "$VALIDATE" bad-datadir

cp -R golden gitignore-missing
echo ".opf-lock" > /dev/null  # no-op, just documenting intent
: > gitignore-missing/.opf-lock
sed -i '/\.opf-lock/d' gitignore-missing/.gitignore 2>/dev/null || true
expect_exit "validate: flags .opf-lock present but not gitignored" 1 "$VALIDATE" gitignore-missing

# Exit 2 (pass-with-warnings), not 0, is correct here: a separate,
# unrelated check always warns "'.opf-lock' is installer-written state and
# should not be committed" whenever the file is merely present, regardless
# of gitignore content. Exit 2 (not 1) confirms no ERROR fired - i.e. the
# gitignore-content check itself passed.
cp -R golden gitignore-anchored
: > gitignore-anchored/.opf-lock
printf '.opf-env\n/.opf-lock\n' > gitignore-anchored/.gitignore
expect_exit "validate: accepts a /-anchored gitignore entry" 2 "$VALIDATE" gitignore-anchored

cp -R golden gitignore-no-eol
: > gitignore-no-eol/.opf-lock
printf '.opf-env\n.opf-lock' > gitignore-no-eol/.gitignore  # no trailing newline
expect_exit "validate: accepts a gitignore with no trailing newline on the last entry" 2 "$VALIDATE" gitignore-no-eol

# =============================================================================
echo
echo "== install-pack.sh: golden path =="
expect_exit "install: fresh install succeeds" 0 "$INSTALL_PACK" golden golden-installed --yes

if [[ -f golden-installed/.opf-lock ]]; then
  python3 -c "import json; json.load(open('golden-installed/.opf-lock'))" 2>/dev/null \
    && pass "install: .opf-lock is valid JSON" \
    || fail "install: .opf-lock is valid JSON"
  python3 -c "
import json,sys
d = json.load(open('golden-installed/.opf-lock'))
sys.exit(0 if d.get('checksums') and 'manifest.json' in d['checksums'] else 1)
" && pass "install: .opf-lock records checksums including manifest.json" \
    || fail "install: .opf-lock records checksums including manifest.json"
else
  fail "install: .opf-lock exists after install"
fi

[[ -f golden-installed/.opf-env ]] && grep -q "^PACK_NAME=golden$" golden-installed/.opf-env \
  && pass "install: .opf-env has correct PACK_NAME" \
  || fail "install: .opf-env has correct PACK_NAME"

[[ -d golden-installed-data ]] \
  && pass "install: PACK_DATA_DIR created" \
  || fail "install: PACK_DATA_DIR created"

echo
echo "== install-pack.sh: unmanaged-directory protection =="
mkdir -p unmanaged-dir && touch unmanaged-dir/random-file
expect_exit "install: refuses to overwrite a dir with no .opf-lock" 1 \
  "$INSTALL_PACK" golden unmanaged-dir --yes
[[ -f unmanaged-dir/random-file && ! -f unmanaged-dir/.opf-lock ]] \
  && pass "install: unmanaged directory left untouched" \
  || fail "install: unmanaged directory left untouched"

echo
echo "== install-pack.sh: update and downgrade semantics =="
cp -R golden golden-v2
python3 -c "
import json
m = json.load(open('golden-v2/manifest.json'))
m['version'] = '0.2.0'
json.dump(m, open('golden-v2/manifest.json', 'w'))
"
expect_exit "install: update to a higher version succeeds" 0 \
  "$INSTALL_PACK" golden-v2 golden-installed --yes
python3 -c "
import json,sys
d = json.load(open('golden-installed/.opf-lock'))
sys.exit(0 if d.get('version') == '0.2.0' else 1)
" && pass "install: .opf-lock version updated after update" \
  || fail "install: .opf-lock version updated after update"

expect_exit "install: downgrade is refused by default" 1 \
  "$INSTALL_PACK" golden golden-installed --yes
expect_exit "install: downgrade succeeds with --allow-downgrade" 0 \
  "$INSTALL_PACK" golden golden-installed --yes --allow-downgrade

echo
echo "== install-pack.sh: install.sh approval, config, and diff-on-update =="
cp -R golden with-install-sh
python3 -c "
import json
m = json.load(open('with-install-sh/manifest.json'))
m['config'] = [{'name': 'MY_TOKEN', 'description': 'a token', 'required': True}]
json.dump(m, open('with-install-sh/manifest.json', 'w'))
"
cat > with-install-sh/install.sh <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
touch "$PACK_ROOT/installed.marker"
echo "$CONFIG_MY_TOKEN" > "$PACK_ROOT/token.out"
SCRIPT
chmod +x with-install-sh/install.sh

expect_exit "install: refuses install.sh without approval (no --yes, no tty)" 1 \
  "$INSTALL_PACK" with-install-sh with-install-sh-installed
expect_exit "install: refuses when a required config value is missing" 1 \
  "$INSTALL_PACK" with-install-sh with-install-sh-installed --yes
expect_exit "install: succeeds once required config is provided" 0 \
  "$INSTALL_PACK" with-install-sh with-install-sh-installed --yes --config MY_TOKEN=abc123
[[ -f with-install-sh-installed/installed.marker ]] \
  && pass "install: install.sh actually ran (marker file present)" \
  || fail "install: install.sh actually ran (marker file present)"
[[ "$(cat with-install-sh-installed/token.out 2>/dev/null)" == "abc123" ]] \
  && pass "install: CONFIG_MY_TOKEN reached install.sh correctly" \
  || fail "install: CONFIG_MY_TOKEN reached install.sh correctly"

cp -R with-install-sh with-install-sh-v2
python3 -c "
import json
m = json.load(open('with-install-sh-v2/manifest.json'))
m['version'] = '0.2.0'
json.dump(m, open('with-install-sh-v2/manifest.json', 'w'))
"
echo 'echo "v2 line"' >> with-install-sh-v2/install.sh
out="$("$INSTALL_PACK" with-install-sh-v2 with-install-sh-installed --yes --config MY_TOKEN=abc123 2>&1)"
echo "$out" | grep -q "diff against previously installed install.sh" \
  && pass "install: shows a diff (not full text) against the previously approved install.sh" \
  || fail "install: shows a diff (not full text) against the previously approved install.sh"

echo
echo "== install-pack.sh: install.sh failure leaves no partial state =="
cp -R golden failing-install
cat > failing-install/install.sh <<'SCRIPT'
#!/usr/bin/env bash
exit 7
SCRIPT
chmod +x failing-install/install.sh
expect_exit "install: a failing install.sh aborts the install" 1 \
  "$INSTALL_PACK" failing-install failing-install-installed --yes
[[ ! -e failing-install-installed && ! -e failing-install-installed.new ]] \
  && pass "install: no install dir or leftover staging dir after install.sh failure" \
  || fail "install: no install dir or leftover staging dir after install.sh failure"

echo
echo "== install-pack.sh: data_dir traversal is rejected before any directory is created =="
cp -R golden malicious-datadir
python3 -c "
import json
m = json.load(open('malicious-datadir/manifest.json'))
m['data_dir'] = '../../../../tmp/opf-smoketest-traversal-marker'
json.dump(m, open('malicious-datadir/manifest.json', 'w'))
"
expect_exit "install: rejects a manifest data_dir containing '..'" 1 \
  "$INSTALL_PACK" malicious-datadir malicious-datadir-installed --yes
[[ ! -e /tmp/opf-smoketest-traversal-marker ]] \
  && pass "install: no traversal directory created outside the workdir" \
  || fail "install: no traversal directory created outside the workdir"
rm -rf /tmp/opf-smoketest-traversal-marker 2>/dev/null

echo
echo "== install-pack.sh: nested file sharing a reserved name is still checksummed =="
cp -R golden nested-reserved-name
mkdir -p nested-reserved-name/data
echo "not actually installer state" > nested-reserved-name/data/.opf-lock
expect_exit "install: succeeds with a nested data/.opf-lock file present" 0 \
  "$INSTALL_PACK" nested-reserved-name nested-reserved-name-installed --yes
python3 -c "
import json, sys
d = json.load(open('nested-reserved-name-installed/.opf-lock'))
sys.exit(0 if 'data/.opf-lock' in d['checksums'] else 1)
" && pass "install: nested data/.opf-lock is present in checksums" \
  || fail "install: nested data/.opf-lock is present in checksums"

echo
echo "== install-pack.sh: fails closed if the validator is missing/broken =="
mkdir -p broken-validator-bin
cp "$INSTALL_PACK" broken-validator-bin/
cp "$SCRIPT_DIR/secret-patterns.sh" broken-validator-bin/ 2>/dev/null || true
cp "$SCRIPT_DIR/pack-name-pattern.sh" broken-validator-bin/ 2>/dev/null || true
chmod +x broken-validator-bin/install-pack.sh
expect_exit "install: aborts if validate-pack.sh is missing" 1 \
  broken-validator-bin/install-pack.sh golden broken-validator-installed --yes
[[ ! -e broken-validator-installed ]] \
  && pass "install: no install dir created when the validator is missing" \
  || fail "install: no install dir created when the validator is missing"

echo
echo "== install-pack.sh: secrets in a pack block install with no override =="
cp -R golden secret-in-pack
echo "aws_secret_access_key = \"AKIAABCDEFGHIJKLMNOP\"" >> secret-in-pack/README.md
expect_exit "install: refuses a pack containing a likely secret" 1 \
  "$INSTALL_PACK" secret-in-pack secret-in-pack-installed --yes

# =============================================================================
echo
echo "=============================================="
echo "  $PASS passed, $FAIL failed"
echo "=============================================="
if [[ "$FAIL" -gt 0 ]]; then
  echo "Failed checks:"
  printf '  - %s\n' "${FAILED_NAMES[@]}"
  exit 1
fi
exit 0
