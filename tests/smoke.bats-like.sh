#!/usr/bin/env bash
# smoke.bats-like.sh — Smoke tests for tm-exclusions
# These tests validate CLI behavior without requiring real Time Machine mutation.
# Run: bash tests/smoke.bats-like.sh

set -euo pipefail

export LANG=C
export LC_ALL=C
# Avoid slow brew enumeration during report smoke (inventory is optional detail)
export TM_EXCLUSIONS_SKIP_INVENTORY=1

TEST_HOME="$(mktemp -d)"
trap 'rm -rf "${TEST_HOME}"' EXIT
export HOME="${TEST_HOME}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/test_helpers.sh
source "${SCRIPT_DIR}/test_helpers.sh"

echo "tm-exclusions smoke tests"
echo "========================================"

# ---- Help ----
echo ""
echo "--- Help output ---"

assert_exit_code 0 \
    "--help exits 0" \
    bash "$TM_EXCLUSIONS" --help

assert_output_contains "Usage:" \
    "--help shows usage line" \
    bash "$TM_EXCLUSIONS" --help

assert_exit_code 0 \
    "-h exits 0 (alias for --help)" \
    bash "$TM_EXCLUSIONS" -h

assert_output_contains "Usage:" \
    "-h shows usage line" \
    bash "$TM_EXCLUSIONS" -h

assert_output_contains "dry-run" \
    "--help mentions dry-run" \
    bash "$TM_EXCLUSIONS" --help

assert_output_contains "report-only" \
    "--help mentions report-only" \
    bash "$TM_EXCLUSIONS" --help

assert_output_contains "uninstall" \
    "--help mentions uninstall" \
    bash "$TM_EXCLUSIONS" --help

assert_output_contains "config" \
    "--help mentions config management" \
    bash "$TM_EXCLUSIONS" --help

assert_output_contains "--force" \
    "--help mentions --force" \
    bash "$TM_EXCLUSIONS" --help

assert_output_contains "--desktop-report" \
    "--help mentions --desktop-report" \
    bash "$TM_EXCLUSIONS" --help

# ---- Version ----
echo ""
echo "--- Version output ---"

EXPECTED_VERSION=$(sed -n 's/^readonly VERSION="\([^"]*\)"/\1/p' "$TM_EXCLUSIONS")

if [ -z "$EXPECTED_VERSION" ]; then
    echo "FAIL: could not extract VERSION from $TM_EXCLUSIONS — refusing to assert against empty string" >&2
    exit 1
fi

assert_exit_code 0 \
    "--version exits 0" \
    bash "$TM_EXCLUSIONS" --version

assert_output_contains "tm-exclusions" \
    "--version shows program name" \
    bash "$TM_EXCLUSIONS" --version

assert_output_contains "$EXPECTED_VERSION" \
    "--version shows version number" \
    bash "$TM_EXCLUSIONS" --version

# ---- Invalid arguments ----
echo ""
echo "--- Invalid argument handling ---"

assert_exit_code 1 \
    "unknown flag exits 1" \
    bash "$TM_EXCLUSIONS" --nonexistent-flag

assert_output_contains "Unknown argument" \
    "unknown flag shows error message" \
    bash "$TM_EXCLUSIONS" --nonexistent-flag

# ---- Dry-run mode ----
echo ""
echo "--- Dry-run mode ---"

assert_exit_code 0 \
    "--dry-run exits 0" \
    bash "$TM_EXCLUSIONS" --dry-run

assert_output_contains "dry-run" \
    "--dry-run output mentions dry-run in report" \
    bash "$TM_EXCLUSIONS" --dry-run

# ---- Report-only mode ----
echo ""
echo "--- Report-only mode ---"

assert_exit_code 0 \
    "--report-only exits 0" \
    bash "$TM_EXCLUSIONS" --report-only

assert_output_contains "Report" \
    "--report-only generates a report" \
    bash "$TM_EXCLUSIONS" --report-only

assert_output_contains "Host:" \
    "--report-only report includes host header" \
    bash "$TM_EXCLUSIONS" --report-only

assert_output_contains "Inventory" \
    "--report-only report includes inventory section" \
    bash "$TM_EXCLUSIONS" --report-only

assert_output_contains "Paths not yet excluded" \
    "--report-only summary labels NEED paths correctly" \
    bash "$TM_EXCLUSIONS" --report-only

# ---- Report env (TM_EXCLUSIONS_REPORT*) ----
echo ""
echo "--- TM_EXCLUSIONS_REPORT ---"

REPORT_OUT="${TEST_HOME}/tm_exclusions_ci_report.txt"
rm -f "${REPORT_OUT}"
assert_exit_code 0 \
    "TM_EXCLUSIONS_REPORT dry-run writes file" \
    env TM_EXCLUSIONS_REPORT="${REPORT_OUT}" bash "$TM_EXCLUSIONS" --dry-run

if [[ ! -f "${REPORT_OUT}" ]]; then
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '%b  FAIL%b TM_EXCLUSIONS_REPORT file missing\n' "$RED" "$NC"
else
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '%b  PASS%b TM_EXCLUSIONS_REPORT file created\n' "$GREEN" "$NC"
fi

assert_output_contains "Host:" \
    "TM_EXCLUSIONS_REPORT file contains report header" \
    cat "${REPORT_OUT}"

assert_output_contains "TM_EXCLUSIONS_SKIP_DU=1" \
    "TM_EXCLUSIONS_SKIP_DU=1 skips du section in report output" \
    env TM_EXCLUSIONS_SKIP_DU=1 bash "$TM_EXCLUSIONS" --dry-run

mkdir -p "${TEST_HOME}/Desktop"
DESK_COPY="${TEST_HOME}/Desktop/tm-exclusions_last_report.txt"
rm -f "${DESK_COPY}"
assert_exit_code 0 \
    "TM_EXCLUSIONS_REPORT_DESKTOP=1 writes Desktop copy" \
    env TM_EXCLUSIONS_REPORT_DESKTOP=1 bash "$TM_EXCLUSIONS" --dry-run

if [[ ! -f "${DESK_COPY}" ]]; then
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '%b  FAIL%b Desktop report copy missing\n' "$RED" "$NC"
else
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '%b  PASS%b Desktop report copy created\n' "$GREEN" "$NC"
fi

# --desktop-report flag (equivalent to TM_EXCLUSIONS_REPORT_DESKTOP=1)
rm -f "${DESK_COPY}"
assert_exit_code 0 \
    "--desktop-report exits 0" \
    bash "$TM_EXCLUSIONS" --desktop-report --dry-run

if [[ ! -f "${DESK_COPY}" ]]; then
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '%b  FAIL%b --desktop-report: Desktop copy missing\n' "$RED" "$NC"
else
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '%b  PASS%b --desktop-report: Desktop copy created\n' "$GREEN" "$NC"
fi

# Default-OFF: without --desktop-report and without the env var, no Desktop copy
rm -f "${DESK_COPY}"
assert_exit_code 0 \
    "default run (no flag, no env var) exits 0" \
    bash "$TM_EXCLUSIONS" --dry-run

if [[ -f "${DESK_COPY}" ]]; then
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '%b  FAIL%b default run: Desktop copy should NOT exist\n' "$RED" "$NC"
else
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '%b  PASS%b default run: no Desktop copy (default OFF)\n' "$GREEN" "$NC"
fi

# ---- Quiet mode ----
echo ""
echo "--- Quiet mode ---"

assert_exit_code 0 \
    "--quiet --dry-run exits 0" \
    bash "$TM_EXCLUSIONS" --quiet --dry-run

# ---- Language selection ----
echo ""
echo "--- Language selection ---"

assert_output_contains "Utilisation" \
    "--lang fr shows French help" \
    bash "$TM_EXCLUSIONS" --lang fr --help

assert_output_contains "Usage:" \
    "--lang en shows English help" \
    bash "$TM_EXCLUSIONS" --lang en --help

assert_output_contains "Utilisation" \
    "LC_MESSAGES=fr_FR.UTF-8 shows French help (detect_language)" \
    env LC_ALL= LC_MESSAGES=fr_FR.UTF-8 LANG=C bash "$TM_EXCLUSIONS" --help

assert_exit_code 1 \
    "--lang rejects unsupported values" \
    bash "$TM_EXCLUSIONS" --lang de --help

# ---- Config init ----
echo ""
echo "--- Config management ---"

assert_exit_code 0 \
    "--init exits 0" \
    bash "$TM_EXCLUSIONS" --init

assert_exit_code 0 \
    "--init is idempotent" \
    bash "$TM_EXCLUSIONS" --init

assert_exit_code 0 \
    "--list exits 0 after init" \
    bash "$TM_EXCLUSIONS" --list

# Test --add
assert_exit_code 0 \
    "--add path works" \
    bash "$TM_EXCLUSIONS" --add path "/tmp/test" "test reason"

assert_output_contains "/tmp/test" \
    "--list shows added rule" \
    bash "$TM_EXCLUSIONS" --list

# Test invalid type
assert_exit_code 1 \
    "--add invalid type exits 1" \
    bash "$TM_EXCLUSIONS" --add invalid "/tmp/test" "test reason"

assert_exit_code 1 \
    "--add rejects trailing args" \
    bash "$TM_EXCLUSIONS" --add path "/tmp/test" "test reason" --quiet

# ---- Uninstall dry-run ----
echo ""
echo "--- Uninstall dry-run ---"

assert_exit_code 0 \
    "--uninstall --dry-run exits 0" \
    bash "$TM_EXCLUSIONS" --uninstall --dry-run

# ---- Config parsing ----
echo ""
echo "--- Config parsing ---"

# Create a test config with known entries
mkdir -p "${TEST_HOME}/.config/tm_exclusions"
cat > "${TEST_HOME}/.config/tm_exclusions/custom.conf" << 'EOF'
# Test config
path|/tmp/test_static|Static test path
pattern|test_pattern_dir|Test pattern
prune|/tmp/test_prune|Test prune
EOF

assert_exit_code 0 \
    "dry-run with custom config exits 0" \
    bash "$TM_EXCLUSIONS" --dry-run

# ---- Short flags ----
echo ""
echo "--- Short flags ---"

assert_exit_code 0 \
    "-q --dry-run exits 0 (short quiet flag)" \
    bash "$TM_EXCLUSIONS" -q --dry-run

# ---- Missing args for --add ----
echo ""
echo "--- Missing arguments ---"

assert_exit_code 1 \
    "--add with missing args exits 1" \
    bash "$TM_EXCLUSIONS" --add path

# ---- TM_EXCLUSIONS_DEFAULT_CONF (install-style override) ----
echo ""
echo "--- TM_EXCLUSIONS_DEFAULT_CONF ---"

MINIMAL_CONF="${TEST_HOME}/minimal-default.conf"
cat > "${MINIMAL_CONF}" << 'EOF'
# minimal default for smoke
path|/tmp/tm_exclusions_smoke_path|smoke test path
EOF

assert_exit_code 0 \
    "TM_EXCLUSIONS_DEFAULT_CONF dry-run exits 0" \
    env TM_EXCLUSIONS_DEFAULT_CONF="${MINIMAL_CONF}" bash "$TM_EXCLUSIONS" --dry-run

assert_output_contains "/tmp/tm_exclusions_smoke_path" \
    "TM_EXCLUSIONS_DEFAULT_CONF dry-run uses override file" \
    env TM_EXCLUSIONS_DEFAULT_CONF="${MINIMAL_CONF}" bash "$TM_EXCLUSIONS" --dry-run

# ---- Parity harness (#34) ----
echo ""
echo "--- Parity placeholders (epic #34) ---"

assert_output_contains "tm-exclusions" \
    "--version stable for packaging smoke" \
    bash "$TM_EXCLUSIONS" --version

# ---- Auto-init custom.conf on first run (#34) ----
echo ""
echo "--- Auto-init custom.conf ---"

AUTO_HOME="$(mktemp -d)"
export HOME="${AUTO_HOME}"
MINIMAL_CONF="${AUTO_HOME}/minimal.conf"
cat > "${MINIMAL_CONF}" << 'EOF'
path|/tmp/tm_exclusions_auto_init_path|smoke auto-init path
EOF

assert_exit_code 0 \
    "dry-run without prior --init creates custom.conf" \
    env TM_EXCLUSIONS_DEFAULT_CONF="${MINIMAL_CONF}" bash "$TM_EXCLUSIONS" --dry-run

if [[ ! -f "${AUTO_HOME}/.config/tm_exclusions/custom.conf" ]]; then
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '%b  FAIL%b custom.conf missing after first dry-run\n' "$RED" "$NC"
else
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '%b  PASS%b custom.conf exists after first dry-run\n' "$GREEN" "$NC"
fi

rm -rf "${AUTO_HOME}"
export HOME="${TEST_HOME}"

# ---- Catalog invariants (#37) ----
echo ""
echo "--- Catalog invariants ---"

# SCRIPT_DIR is reassigned to repo root by test_helpers.sh on source.
# The "──" markers in the section regex below are Unicode box-drawing
# characters (U+2500); editors that auto-substitute them with ASCII
# hyphens will break the catalog invariants.
CONF="${SCRIPT_DIR}/config/default.conf"

# Active rules (path/pattern/prune lines, ignoring comments).
# Floor is pinned to the documented baseline so silent regressions fail CI.
# Bump this constant when intentionally growing the catalog.
MIN_ACTIVE_RULES=102
RULE_COUNT=$(grep -cE '^(path|pattern|prune)\|' "${CONF}" || true)
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "${RULE_COUNT}" -ge "${MIN_ACTIVE_RULES}" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '%b  PASS%b default.conf has >=%d active rules (got %d)\n' "$GREEN" "$NC" "${MIN_ACTIVE_RULES}" "${RULE_COUNT}"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '%b  FAIL%b default.conf has >=%d active rules (got %d)\n' "$RED" "$NC" "${MIN_ACTIVE_RULES}" "${RULE_COUNT}"
fi

# Distinct #@ category labels == 17
LABEL_COUNT=$({ grep -E '^#@' "${CONF}" || true; } | sort -u | wc -l | tr -d ' ')
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "${LABEL_COUNT}" -eq 17 ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '%b  PASS%b default.conf has 17 distinct #@ category labels\n' "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '%b  FAIL%b default.conf has 17 distinct #@ category labels (got %d)\n' "$RED" "$NC" "${LABEL_COUNT}"
fi

# Three section markers exist
SECTION_COUNT=$(grep -cE '^# ── (STATIC EXCLUSIONS|DYNAMIC SCAN PATTERNS|SCAN PRUNE ZONES)' "${CONF}" || true)
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "${SECTION_COUNT}" -eq 3 ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '%b  PASS%b default.conf has the three section markers\n' "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '%b  FAIL%b default.conf has the three section markers (got %d)\n' "$RED" "$NC" "${SECTION_COUNT}"
fi

# No rule uses the ~/ home prefix (must be $HOME/)
TILDE_COUNT=$(grep -cE '^(path|pattern|prune)\|~/' "${CONF}" || true)
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "${TILDE_COUNT}" -eq 0 ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    # shellcheck disable=SC2016
    printf '%b  PASS%b default.conf uses $HOME/ not ~/ for home-rooted paths\n' "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    # shellcheck disable=SC2016
    printf '%b  FAIL%b default.conf uses ~/ on %d lines (must be $HOME/)\n' "$RED" "$NC" "${TILDE_COUNT}"
fi

# Every (path|pattern|prune) line is preceded by a #@ marker within its section
ORPHAN_COUNT=$(awk '
    /^# ── (STATIC EXCLUSIONS|DYNAMIC SCAN PATTERNS|SCAN PRUNE ZONES)/ {cat=0; next}
    /^#@/ {cat=1; next}
    /^(path|pattern|prune)\|/ {if (!cat) print NR}
' "${CONF}" | wc -l | tr -d ' ')
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "${ORPHAN_COUNT}" -eq 0 ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '%b  PASS%b default.conf has no orphan rule outside a #@ category\n' "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '%b  FAIL%b default.conf has %d rule(s) outside any #@ category\n' "$RED" "$NC" "${ORPHAN_COUNT}"
fi

# ---- Prefix-prune of redundant child exclusions (#23) ----
echo ""
echo "--- Prefix-prune (#23) ---"

PRUNE_HOME="$(mktemp -d)"
mkdir -p "${PRUNE_HOME}/Git/proj/node_modules/.pnpm/foo/node_modules"
mkdir -p "${PRUNE_HOME}/Git/proj/node_modules/.pnpm/bar/node_modules"
PRUNE_CONF="${PRUNE_HOME}/prune-test.conf"
cat > "${PRUNE_CONF}" << 'EOF'
pattern|node_modules|prefix-prune smoke
EOF

PRUNE_OUT="$(env HOME="${PRUNE_HOME}" \
                TM_EXCLUSIONS_DEFAULT_CONF="${PRUNE_CONF}" \
                bash "$TM_EXCLUSIONS" --dry-run 2>&1 || true)"

# Parent must be processed exactly once (Applying ... OR Already excluded ...),
# not 3 times — once for /node_modules plus twice for .pnpm/{foo,bar}/node_modules
# under it. Match either log line because tmutil may already report the path as
# excluded on macOS hosts where the test root inherits an ancestor exclusion
# (e.g. /var/folders/* is auto-excluded by Time Machine).
PARENT_HITS=$(printf '%s\n' "${PRUNE_OUT}" | grep -cE "(Applying exclusion:|Already excluded:).*Git/proj/node_modules$" || true)
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "${PARENT_HITS}" -eq 1 ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '%b  PASS%b parent node_modules processed exactly once\n' "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '%b  FAIL%b expected 1 parent line, got %d\n' "$RED" "$NC" "${PARENT_HITS}"
fi

# Nested .pnpm/<pkg>/node_modules must NOT be processed — covered by parent.
NESTED_HITS=$(printf '%s\n' "${PRUNE_OUT}" | grep -cE "(Applying exclusion:|Already excluded:).*\.pnpm/.*/node_modules" || true)
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "${NESTED_HITS}" -eq 0 ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '%b  PASS%b nested .pnpm/<pkg>/node_modules not re-excluded\n' "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '%b  FAIL%b nested .pnpm exclusions emitted: %d\n' "$RED" "$NC" "${NESTED_HITS}"
fi

rm -rf "${PRUNE_HOME}"

# ---- Prefix-prune handles glob metacharacters in paths (#23 review) ----
# Defensive coverage: directory names containing `*`, `?`, `[`, `]` must not
# accidentally match unrelated descendants. Quoted variable expansions in
# `case` patterns are literal, but a regression here would silently over-prune.
echo ""
echo "--- Prefix-prune: glob meta in paths (#23) ---"

GLOB_HOME="$(mktemp -d)"
mkdir -p "${GLOB_HOME}/proj[a]/node_modules"
mkdir -p "${GLOB_HOME}/projB/node_modules"
GLOB_CONF="${GLOB_HOME}/glob.conf"
cat > "${GLOB_CONF}" << 'EOF'
pattern|node_modules|glob meta smoke
EOF

GLOB_OUT="$(env HOME="${GLOB_HOME}" \
                TM_EXCLUSIONS_DEFAULT_CONF="${GLOB_CONF}" \
                bash "$TM_EXCLUSIONS" --dry-run 2>&1 || true)"

# Both literal-bracket and adjacent siblings must each be processed exactly
# once. If `[a]` were treated as a glob class, `proj[a]/node_modules` would
# also "cover" `projB/node_modules` and only one of the two would survive.
GLOB_HITS=$(printf '%s\n' "${GLOB_OUT}" | grep -cE "(Applying exclusion:|Already excluded:).*node_modules$" || true)
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "${GLOB_HITS}" -eq 2 ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '%b  PASS%b glob-meta sibling paths processed independently (got %d)\n' "$GREEN" "$NC" "${GLOB_HITS}"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '%b  FAIL%b expected 2 distinct exclusions, got %d\n' "$RED" "$NC" "${GLOB_HITS}"
fi

rm -rf "${GLOB_HOME}"

# ---- du -sk tolerance for partially-readable paths (#18) ----
# NOTE: chmod 000 on the subdir is vacuous on root CI runners (root ignores
# permission bits), so the test only exercises the pipefail fix on user runners.
echo ""
echo "--- du -sk tolerance for unreadable subdirs (#18) ---"

DU_HOME="$(mktemp -d "${TEST_HOME}/du-test.XXXXXX")"
mkdir -p "${DU_HOME}/restrictedparent/unreadable_subdir"
chmod 000 "${DU_HOME}/restrictedparent/unreadable_subdir"
DU_CONF="${DU_HOME}/du-test.conf"
cat > "${DU_CONF}" << EOF
path|${DU_HOME}/restrictedparent|du tolerance test
EOF

assert_exit_code 0 \
    "--dry-run exits 0 with partially-unreadable path in config" \
    env HOME="${DU_HOME}" TM_EXCLUSIONS_DEFAULT_CONF="${DU_CONF}" \
        bash "$TM_EXCLUSIONS" --dry-run

assert_exit_code 0 \
    "--report-only exits 0 with partially-unreadable path in config" \
    env HOME="${DU_HOME}" TM_EXCLUSIONS_DEFAULT_CONF="${DU_CONF}" \
        bash "$TM_EXCLUSIONS" --report-only

chmod 700 "${DU_HOME}/restrictedparent/unreadable_subdir"
rm -rf "${DU_HOME}"

# ---- site-packages filter (#26) ----
# Test A: ~/.faketool/lib/python3.14/site-packages IS excluded (valid Python tool install)
# Test B: ~/random/site-packages is NOT excluded (bare site-packages, no python-versioned parent)
# Test C: ~/.faketool/python3.14/site-packages is NOT excluded (parent is pythonX.Y but grandparent != lib)
echo ""
echo "--- site-packages pattern filter (#26) ---"

SP_HOME="$(mktemp -d "${TEST_HOME}/sp-test.XXXXXX")"
mkdir -p "${SP_HOME}/.faketool/lib/python3.14/site-packages"
mkdir -p "${SP_HOME}/random/site-packages"
mkdir -p "${SP_HOME}/.faketool/python3.14/site-packages"
SP_CONF="${SP_HOME}/sp-test.conf"
cat > "${SP_CONF}" << 'EOF'
pattern|site-packages|Python lib/pythonX.Y/site-packages trees (regenerable pip output)
EOF

SP_OUT="$(env HOME="${SP_HOME}" \
              TM_EXCLUSIONS_DEFAULT_CONF="${SP_CONF}" \
              bash "$TM_EXCLUSIONS" --dry-run 2>&1 || true)"

# Test A: valid lib/python3.14/site-packages must appear
SP_VALID_HITS=$(printf '%s\n' "${SP_OUT}" | grep -cE "(Applying exclusion:|Already excluded:).*\.faketool/lib/python3\.14/site-packages$" || true)
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "${SP_VALID_HITS}" -eq 1 ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '%b  PASS%b lib/python3.14/site-packages under ~/.<tool> is excluded\n' "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '%b  FAIL%b expected 1 exclusion for valid site-packages, got %d\n' "$RED" "$NC" "${SP_VALID_HITS}"
fi

# Test B: bare ~/random/site-packages must NOT appear (no python-versioned parent)
SP_BARE_HITS=$(printf '%s\n' "${SP_OUT}" | grep -cE "(Applying exclusion:|Already excluded:).*random/site-packages$" || true)
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "${SP_BARE_HITS}" -eq 0 ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '%b  PASS%b bare ~/random/site-packages (no python-versioned parent) is NOT excluded\n' "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '%b  FAIL%b bare site-packages should not be excluded, got %d hit(s)\n' "$RED" "$NC" "${SP_BARE_HITS}"
fi

# Test C: ~/.faketool/python3.14/site-packages must NOT appear (parent is pythonX.Y but grandparent != lib)
SP_NOLIB_HITS=$(printf '%s\n' "${SP_OUT}" | grep -cE "(Applying exclusion:|Already excluded:).*\.faketool/python3\.14/site-packages$" || true)
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "${SP_NOLIB_HITS}" -eq 0 ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '%b  PASS%b ~/.faketool/python3.14/site-packages (no lib/ grandparent) is NOT excluded\n' "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '%b  FAIL%b python3.14/site-packages without lib/ grandparent should not be excluded, got %d hit(s)\n' "$RED" "$NC" "${SP_NOLIB_HITS}"
fi

rm -rf "${SP_HOME}"

# ---- TM_EXCLUSIONS_EXTRA_CONF (#17) ----
echo ""
echo "--- TM_EXCLUSIONS_EXTRA_CONF (#17) ---"

EXTRA_HOME="$(mktemp -d "${TEST_HOME}/extra-conf-test.XXXXXX")"
EXTRA_CONF="${EXTRA_HOME}/extra.conf"
EXTRA_DEFAULT="${EXTRA_HOME}/default.conf"
# A directory that will be matched by the pattern and then pruned
mkdir -p "${EXTRA_HOME}/FakeDropbox/Code/node_modules"

# Default config: scan for node_modules so the prune filter can fire
cat > "${EXTRA_DEFAULT}" << 'EOF'
pattern|node_modules|JS dependency tree — regenerable
EOF

# Extra config: prune the FakeDropbox subtree using its real path
cat > "${EXTRA_CONF}" << EOF
# Cloud-sync prune opt-in
prune|${EXTRA_HOME}/FakeDropbox|Cloud-sync tree — skip regenerable sub-directories
EOF

assert_exit_code 0 \
    "TM_EXCLUSIONS_EXTRA_CONF valid file — script exits 0" \
    env HOME="${EXTRA_HOME}" \
        TM_EXCLUSIONS_DEFAULT_CONF="${EXTRA_DEFAULT}" \
        TM_EXCLUSIONS_EXTRA_CONF="${EXTRA_CONF}" \
        bash "$TM_EXCLUSIONS" --dry-run

assert_output_contains "Pruning" \
    "TM_EXCLUSIONS_EXTRA_CONF prune rule is applied (prune message emitted)" \
    env HOME="${EXTRA_HOME}" \
        TM_EXCLUSIONS_DEFAULT_CONF="${EXTRA_DEFAULT}" \
        TM_EXCLUSIONS_EXTRA_CONF="${EXTRA_CONF}" \
        bash "$TM_EXCLUSIONS" --dry-run

# Test: missing file → script does NOT abort, warns on stderr
MISSING_CONF="${EXTRA_HOME}/does-not-exist.conf"

assert_exit_code 0 \
    "TM_EXCLUSIONS_EXTRA_CONF missing file — script exits 0 (does not abort)" \
    env HOME="${EXTRA_HOME}" \
        TM_EXCLUSIONS_DEFAULT_CONF="${EXTRA_DEFAULT}" \
        TM_EXCLUSIONS_EXTRA_CONF="${MISSING_CONF}" \
        bash "$TM_EXCLUSIONS" --dry-run

EXTRA_WARN_STDERR="$(env HOME="${EXTRA_HOME}" \
    TM_EXCLUSIONS_DEFAULT_CONF="${EXTRA_DEFAULT}" \
    TM_EXCLUSIONS_EXTRA_CONF="${MISSING_CONF}" \
    bash "$TM_EXCLUSIONS" --dry-run 2>&1 1>/dev/null || true)"
TESTS_RUN=$((TESTS_RUN + 1))
if printf '%s\n' "${EXTRA_WARN_STDERR}" | grep -q "Warning:.*TM_EXCLUSIONS_EXTRA_CONF"; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '%b  PASS%b TM_EXCLUSIONS_EXTRA_CONF missing file prints warning to stderr\n' "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '%b  FAIL%b TM_EXCLUSIONS_EXTRA_CONF missing file should print warning\n' "$RED" "$NC"
fi

assert_output_not_contains "TM_EXCLUSIONS_EXTRA_CONF" \
    "no warning when extra conf not set" \
    env -u TM_EXCLUSIONS_EXTRA_CONF HOME="${EXTRA_HOME}" \
        TM_EXCLUSIONS_DEFAULT_CONF="${EXTRA_DEFAULT}" \
        bash "$TM_EXCLUSIONS" --dry-run

# Test: directory path → -r passes but -f fails → must warn (not silently no-op)
DIR_AS_CONF="${EXTRA_HOME}/some-dir"
mkdir -p "${DIR_AS_CONF}"

assert_exit_code 0 \
    "TM_EXCLUSIONS_EXTRA_CONF is a directory — script exits 0" \
    env HOME="${EXTRA_HOME}" \
        TM_EXCLUSIONS_DEFAULT_CONF="${EXTRA_DEFAULT}" \
        TM_EXCLUSIONS_EXTRA_CONF="${DIR_AS_CONF}" \
        bash "$TM_EXCLUSIONS" --dry-run

DIR_WARN_STDERR="$(env HOME="${EXTRA_HOME}" \
    TM_EXCLUSIONS_DEFAULT_CONF="${EXTRA_DEFAULT}" \
    TM_EXCLUSIONS_EXTRA_CONF="${DIR_AS_CONF}" \
    bash "$TM_EXCLUSIONS" --dry-run 2>&1 1>/dev/null || true)"
TESTS_RUN=$((TESTS_RUN + 1))
if printf '%s\n' "${DIR_WARN_STDERR}" | grep -q "Warning:.*TM_EXCLUSIONS_EXTRA_CONF"; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '%b  PASS%b TM_EXCLUSIONS_EXTRA_CONF directory path prints warning to stderr\n' "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '%b  FAIL%b TM_EXCLUSIONS_EXTRA_CONF directory path should print warning\n' "$RED" "$NC"
fi

rm -rf "${EXTRA_HOME}"

# ---- Summary ----
test_summary
