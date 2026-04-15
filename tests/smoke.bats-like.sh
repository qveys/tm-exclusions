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

# ---- Version ----
echo ""
echo "--- Version output ---"

assert_exit_code 0 \
    "--version exits 0" \
    bash "$TM_EXCLUSIONS" --version

assert_output_contains "tm-exclusions" \
    "--version shows program name" \
    bash "$TM_EXCLUSIONS" --version

assert_output_contains "1.1.0" \
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

# ---- Summary ----
test_summary
