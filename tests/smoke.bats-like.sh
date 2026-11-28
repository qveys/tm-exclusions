#!/usr/bin/env bash
# smoke.bats-like.sh — Smoke tests for tm-exclusions
# These tests validate CLI behavior without requiring real Time Machine mutation.
# Run: bash tests/smoke.bats-like.sh

set -euo pipefail

export LANG=C
export LC_ALL=C
# Avoid slow brew enumeration during report smoke (inventory is optional detail)
export TM_EXCLUSIONS_SKIP_INVENTORY=1
# Absolute catalog rules (e.g. /Library/Developer/CoreSimulator) would be
# measured with du on the real machine: minutes per report-only run. Sizes are
# not asserted here; the size-column block below unsets this to test du itself.
export TM_EXCLUSIONS_SKIP_DU=1

TEST_HOME="$(mktemp -d)"
trap 'rm -rf "${TEST_HOME}"' EXIT
export HOME="${TEST_HOME}"

# Never use the host Time Machine or Homebrew cache in smoke tests.
mkdir -p "$TEST_HOME/bin"
cat > "$TEST_HOME/bin/tmutil" <<'STUB'
#!/bin/sh
if [ "$1" = isexcluded ]; then printf '[Included] %s\n' "$2"; fi
exit 0
STUB
cat > "$TEST_HOME/bin/brew" <<'STUB'
#!/bin/sh
exit 0
STUB
cat > "$TEST_HOME/bin/sudo" <<'STUB'
#!/bin/sh
# No host privilege operations in tests.
case "$1" in
    -n|-v) exit 0 ;;
    tmutil) shift; exec tmutil "$@" ;;
    *) exit 1 ;;
esac
STUB
chmod +x "$TEST_HOME/bin/"*
export PATH="$TEST_HOME/bin:$PATH"

SCRIPT_DIR="$(
    source_dir="$(dirname -- "${BASH_SOURCE[0]}")" || exit 1
    [[ "$source_dir" != -* ]] || source_dir="./$source_dir"
    CDPATH='' cd -P -- "${source_dir}" >/dev/null 2>&1 && pwd
)"
# shellcheck source=tests/test_helpers.sh
source "${SCRIPT_DIR}/test_helpers.sh"

# Functions of the CLI (no `main` call) for the unit blocks below, written to a
# file in TEST_HOME (removed by the EXIT trap): `source <(...)` defines nothing
# under Bash 3.2 and would turn those blocks into silent false greens.
TM_FUNCS="${TEST_HOME}/tm_exclusions_functions.sh"
write_functions_file "$TM_FUNCS"

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

pushd -- "$ROOT/.." >/dev/null
RELATIVE_CLI="${ROOT##*/}/tm_exclusions.sh"

assert_exit_code 0 \
    "relative --help with CDPATH exits 0" \
    env CDPATH="$PWD" "$BASH" -- "$RELATIVE_CLI" --help

assert_output_contains "Usage:" \
    "relative --help with CDPATH shows usage" \
    env CDPATH="$PWD" "$BASH" -- "$RELATIVE_CLI" --help

assert_exit_code 0 \
    "relative --lang en --help with CDPATH exits 0" \
    env CDPATH="$PWD" "$BASH" -- "$RELATIVE_CLI" --lang en --help

assert_output_contains "Usage:" \
    "relative --lang en --help with CDPATH shows usage" \
    env CDPATH="$PWD" "$BASH" -- "$RELATIVE_CLI" --lang en --help

popd >/dev/null

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

# ---- Makefile version target (#43) ----
echo ""
echo "--- Makefile version target ---"

assert_exit_code 0 \
    "make version exits 0" \
    make -C "$SCRIPT_DIR" --no-print-directory version

TESTS_RUN=$((TESTS_RUN + 1))
MAKE_VERSION_OUT="$(make -C "$SCRIPT_DIR" --no-print-directory version 2>&1)"
if [ "$MAKE_VERSION_OUT" = "$EXPECTED_VERSION" ]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '%b  PASS%b make version prints only the version string\n' "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '%b  FAIL%b make version output was %s (expected %s)\n' "$RED" "$NC" "$MAKE_VERSION_OUT" "$EXPECTED_VERSION"
fi

assert_output_contains "version" \
    "make help lists version target" \
    make -C "$SCRIPT_DIR" --no-print-directory help

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
    bash "$TM_EXCLUSIONS" --verbose --dry-run

assert_output_contains "dry-run" \
    "--dry-run output mentions dry-run in report" \
    bash "$TM_EXCLUSIONS" --verbose --dry-run

# ---- Report-only mode ----
echo ""
echo "--- Report-only mode ---"

assert_exit_code 0 \
    "--report-only exits 0" \
    bash "$TM_EXCLUSIONS" --verbose --report-only

assert_output_contains "Report" \
    "--report-only generates a report" \
    bash "$TM_EXCLUSIONS" --verbose --report-only

assert_output_contains "Host:" \
    "--report-only report includes host header" \
    bash "$TM_EXCLUSIONS" --verbose --report-only

assert_output_contains "Inventory" \
    "--report-only report includes inventory section" \
    bash "$TM_EXCLUSIONS" --verbose --report-only

assert_output_contains "Paths not yet excluded" \
    "--report-only summary labels NEED paths correctly" \
    bash "$TM_EXCLUSIONS" --verbose --report-only

# ---- Report env (TM_EXCLUSIONS_REPORT*) ----
echo ""
echo "--- TM_EXCLUSIONS_REPORT ---"

REPORT_OUT="${TEST_HOME}/tm_exclusions_ci_report.txt"
rm -f "${REPORT_OUT}"
assert_exit_code 0 \
    "TM_EXCLUSIONS_REPORT dry-run writes file" \
    env TM_EXCLUSIONS_REPORT="${REPORT_OUT}" bash "$TM_EXCLUSIONS" --verbose --dry-run

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
    env TM_EXCLUSIONS_SKIP_DU=1 bash "$TM_EXCLUSIONS" --verbose --dry-run

mkdir -p "${TEST_HOME}/Desktop"
DESK_COPY="${TEST_HOME}/Desktop/tm-exclusions_last_report.txt"
rm -f "${DESK_COPY}"
assert_exit_code 0 \
    "TM_EXCLUSIONS_REPORT_DESKTOP=1 writes Desktop copy" \
    env TM_EXCLUSIONS_REPORT_DESKTOP=1 bash "$TM_EXCLUSIONS" --verbose --dry-run

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
    bash "$TM_EXCLUSIONS" --verbose --dry-run

if [[ -f "${DESK_COPY}" ]]; then
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '%b  FAIL%b default run: Desktop copy should NOT exist\n' "$RED" "$NC"
else
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '%b  PASS%b default run: no Desktop copy (default OFF)\n' "$GREEN" "$NC"
fi

# ---- Homebrew inventory: casks and formulae listed by name (#48) ----
echo ""
echo "--- Homebrew inventory (#48) ---"

# Fake brew with known casks/formulae, shadowing the empty stub via PATH order.
BREW_BIN="${TEST_HOME}/brew-bin"
mkdir -p "${BREW_BIN}"
cat > "${BREW_BIN}/tmutil" <<'STUB'
#!/bin/sh
if [ "$1" = isexcluded ]; then printf '[Included] %s\n' "$2"; fi
exit 0
STUB
cat > "${BREW_BIN}/brew" <<'STUB'
#!/bin/sh
case "$1" in
    --cache) exit 0 ;;
    list)
        case "$2" in
            --cask)
                printf '%s\n' firefox visual-studio-code docker-desktop iterm2 \
                    raycast google-chrome spotify slack zoom
                ;;
            --formula)
                printf '%s\n' git ripgrep jq fzf \
                    a-deliberately-long-formula-name-for-wrap-testing wget tree
                ;;
        esac
        ;;
esac
exit 0
STUB
chmod +x "${BREW_BIN}/"*

BREW_REPORT="${TEST_HOME}/brew-inventory-report.txt"
rm -f "${BREW_REPORT}"
BREW_ENV=(env -u TM_EXCLUSIONS_SKIP_INVENTORY TM_EXCLUSIONS_SKIP_DU=1 PATH="${BREW_BIN}:${PATH}" TM_EXCLUSIONS_REPORT="${BREW_REPORT}")

# Output goes to a file, not $(...): the sudo keepalive's orphaned sleep would
# otherwise hold the capture pipe open for up to 55 s per run.
BREW_OUT="${TEST_HOME}/brew-out.txt"
BREW_RC=0
"${BREW_ENV[@]}" bash "$TM_EXCLUSIONS" --verbose --dry-run > "${BREW_OUT}" 2>&1 || BREW_RC=$?
assert_eq 0 "${BREW_RC}" "brew present: --verbose --dry-run exits 0 with inventory enabled"
assert_file_contains "${BREW_OUT}" "Homebrew casks (9):" \
    "brew present: casks listed with their count"
assert_file_contains "${BREW_OUT}" "Homebrew formulas (7):" \
    "brew present: formulae listed with their count"
assert_file_contains "${BREW_OUT}" "a-deliberately-long-formula-name-for-wrap-testing" \
    "brew present: formula names appear in output, not just counts"
assert_file_contains "${BREW_OUT}" "firefox, visual-studio-code" \
    "brew present: cask names are wrapped on comma-separated lines"

assert_file_contains "${BREW_REPORT}" "Homebrew casks (9):" \
    "brew present: saved report contains the cask list header"
assert_file_contains "${BREW_REPORT}" "firefox" \
    "brew present: saved report lists cask names"
assert_file_contains "${BREW_REPORT}" "ripgrep" \
    "brew present: saved report lists formula names"

TESTS_RUN=$((TESTS_RUN + 1))
if grep -qE ',$' "${BREW_REPORT}"; then
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '%b  FAIL%b wrapped inventory lines must not end with a trailing comma\n' "$RED" "$NC"
    grep -nE ',$' "${BREW_REPORT}" >&2
else
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '%b  PASS%b no trailing comma on wrapped inventory lines\n' "$GREEN" "$NC"
fi

# brew absent from PATH: friendly notice, no list, exit unchanged.
NOBREW_BIN="${TEST_HOME}/nobrew-bin"
mkdir -p "${NOBREW_BIN}"
cat > "${NOBREW_BIN}/tmutil" <<'STUB'
#!/bin/sh
if [ "$1" = isexcluded ]; then printf '[Included] %s\n' "$2"; fi
exit 0
STUB
cat > "${NOBREW_BIN}/sudo" <<'STUB'
#!/bin/sh
# No host privilege operations in tests.
case "$1" in
    -n|-v) exit 0 ;;
    tmutil) shift; exec tmutil "$@" ;;
    *) exit 1 ;;
esac
STUB
chmod +x "${NOBREW_BIN}/"*

# Output goes to a file, not $(...): the sudo keepalive's orphaned sleep would
# otherwise hold the capture pipe open for up to 55 s per run.
NOBREW_OUT="${TEST_HOME}/nobrew-out.txt"
NOBREW_RC=0
env -u TM_EXCLUSIONS_SKIP_INVENTORY TM_EXCLUSIONS_SKIP_DU=1 HOME="${TEST_HOME}" PATH="${NOBREW_BIN}:/usr/bin:/bin" \
    bash "$TM_EXCLUSIONS" --verbose --dry-run > "${NOBREW_OUT}" 2>&1 || NOBREW_RC=$?
assert_eq 0 "${NOBREW_RC}" "brew absent: --verbose --dry-run exits 0"
assert_file_contains "${NOBREW_OUT}" "brew not found in PATH" \
    "brew absent: friendly notice is shown"
assert_file_lacks_regex "${NOBREW_OUT}" "Homebrew casks \(" \
    "brew absent: no cask list is produced"

# TM_EXCLUSIONS_SKIP_INVENTORY=1 still wins when brew is present.
SKIPINV_OUT="${TEST_HOME}/skipinv-out.txt"
env TM_EXCLUSIONS_SKIP_DU=1 PATH="${BREW_BIN}:${PATH}" \
    bash "$TM_EXCLUSIONS" --verbose --dry-run > "${SKIPINV_OUT}" 2>&1 || true
assert_file_contains "${SKIPINV_OUT}" "(skipped: TM_EXCLUSIONS_SKIP_INVENTORY=1)" \
    "skip flag: inventory skipped even with brew present"
assert_file_lacks_regex "${SKIPINV_OUT}" "Homebrew casks \(" \
    "skip flag: no cask list when inventory is skipped"

# Unit: the wrapper never splits a name nor leaves a trailing comma.
# shellcheck disable=SC2016
assert_exit_code 0 "wrap_name_list wraps to width without trailing commas or split names" \
    bash -c '
set -euo pipefail
source "$1"
declare -F wrap_name_list >/dev/null
names="$(for ((i = 1; i <= 25; i++)); do printf "package-name-%s\n" "$i"; done)"
printf -v names "%s\n%s" "$names" "an-extremely-long-package-name-that-exceeds-the-wrap-width-on-purpose"
out="$(printf "%s\n" "$names" | wrap_name_list 40)"
[[ "$(printf "%s\n" "$out" | wc -l | tr -d " ")" -gt 1 ]]
while IFS= read -r line; do
    [[ "$line" != *, ]]
    if [[ "${#line}" -gt 40 ]]; then
        [[ "$line" = "an-extremely-long-package-name-that-exceeds-the-wrap-width-on-purpose" ]]
    fi
done <<< "$out"
for ((i = 1; i <= 25; i++)); do
    [[ "$out" == *"package-name-$i"* ]]
done
[[ "$out" == *"an-extremely-long-package-name-that-exceeds-the-wrap-width-on-purpose"* ]]
' _ "$TM_FUNCS"

# Unit: the 2-space indent counts toward the block width, and report_columns
# only queries the terminal when the caller pre-evaluated [[ -t 1 ]] = 1.
# shellcheck disable=SC2016
assert_exit_code 0 "brew_list_block keeps indented lines within the width; report_columns honors the tty flag" \
    bash -c '
set -euo pipefail
source "$1"
declare -F brew_list_block report_columns >/dev/null
brew() {
    case "$2" in
        --cask) printf "%s\n" "aaaaaaaaa" "bbbbbbbbbbbbbbbbbb" ;;
    esac
    return 0
}
out="$(brew_list_block --cask "Homebrew casks" 30)"
[[ "$(printf "%s\n" "$out" | head -n 1)" = "Homebrew casks (2):" ]]
# 9 + 2 + 18 = 29 unindented: with the old wrap (width 30) the indented line is
# 31 > 30 and this test must FAIL; with wrap width-2 it splits into 2 lines
# whose indented lengths are <= 30.
while IFS= read -r line; do
    [[ "${#line}" -le 30 ]]
    [[ "$line" != *, ]]
done <<< "$out"
[[ "$(report_columns)" = "80" ]]
[[ "$(report_columns 0)" = "80" ]]
tput() { printf "57\n"; }
[[ "$(report_columns 1)" = "57" ]]
tput() { printf "10\n"; }
[[ "$(report_columns 1)" = "80" ]]
' _ "$TM_FUNCS"

# Unit: interactive runs print the inventory body under a localized header.
# shellcheck disable=SC2016
assert_exit_code 0 "ui_print_inventory shows the inventory body inline" \
    bash -c '
set -euo pipefail
source "$1"
declare -F ui_print_inventory >/dev/null
source "$2/locales/en.sh"
declare_i18n_en
UI=1
UI_CYAN=""; UI_RESET=""; UI_DIM=""
inv="$(printf "=== Inventory (informational) ===\nHomebrew casks (2):\n  firefox, iterm2")"
ui_print_inventory "$inv" > "$3/inv-ui"
grep -q "Inventory" "$3/inv-ui"
grep -q "  Homebrew casks (2):" "$3/inv-ui"
grep -q "  firefox, iterm2" "$3/inv-ui"
if grep -q "^=== Inventory" "$3/inv-ui"; then exit 1; fi
source "$2/locales/fr.sh"
declare_i18n_fr
ui_print_inventory "$inv" > "$3/inv-ui-fr"
grep -q "Inventaire" "$3/inv-ui-fr"
' _ "$TM_FUNCS" "$SCRIPT_DIR" "$TEST_HOME"

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

assert_output_contains "Utilisation" \
    "--lang=fr shows French help" \
    bash "$TM_EXCLUSIONS" --lang=fr --help

assert_exit_code 1 \
    "--lang= rejects an empty language" \
    bash "$TM_EXCLUSIONS" --lang= --help

assert_output_contains "Usage:" \
    "--lang en shows English help" \
    bash "$TM_EXCLUSIONS" --lang en --help

assert_output_contains "Utilisation" \
    "LC_MESSAGES=fr_FR.UTF-8 shows French help (detect_language)" \
    env LC_ALL= LC_MESSAGES=fr_FR.UTF-8 LANG=C bash "$TM_EXCLUSIONS" --help

assert_exit_code 1 \
    "--lang rejects unsupported values" \
    bash "$TM_EXCLUSIONS" --lang de --help

assert_output_contains "Unsupported language" \
    "--lang de reports unsupported language, not missing locale files" \
    bash "$TM_EXCLUSIONS" --lang de --help

assert_output_not_contains "locale files not found" \
    "--lang de does not look like a broken locale install" \
    bash "$TM_EXCLUSIONS" --lang de --help

assert_output_contains "Unsupported language" \
    "--lang with path-like value reports unsupported language" \
    bash "$TM_EXCLUSIONS" --lang '../en' --help

assert_output_not_contains "locale files not found" \
    "--lang with path-like value does not look like a broken locale install" \
    bash "$TM_EXCLUSIONS" --lang '../en' --help

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

assert_exit_code 1 \
    "--add rejects an empty target" \
    bash "$TM_EXCLUSIONS" --add pattern "" "empty target"

assert_exit_code 1 \
    "--add rejects a pattern with a slash" \
    bash "$TM_EXCLUSIONS" --add pattern "a/b" "slash in pattern"

assert_output_not_contains "slash in pattern" \
    "--add leaves invalid patterns out of the custom config" \
    cat "$HOME/.config/tm_exclusions/custom.conf"

assert_output_contains "Règle ajoutée" \
    "--lang fr after --add localizes the confirmation" \
    bash "$TM_EXCLUSIONS" --add pattern "localized cache" "test reason" --lang fr

assert_output_contains "Rule added" \
    "--add treats an option-shaped reason as literal text" \
    bash "$TM_EXCLUSIONS" --lang en --add pattern "literal reason cache" --quiet

assert_output_contains "Langue non supportée" \
    "--lang= validates a trailing language after --add" \
    bash "$TM_EXCLUSIONS" --lang fr --add pattern "invalid language cache" "test reason" --lang=de --lang=fr

# Test invalid type
assert_exit_code 1 \
    "--add invalid type exits 1" \
    bash "$TM_EXCLUSIONS" --add invalid "/tmp/test" "test reason"

assert_exit_code 1 \
    "--add rejects trailing args" \
    bash "$TM_EXCLUSIONS" --add path "/tmp/test" "test reason" --quiet

# Test --edit with multi-word EDITOR
assert_output_contains "MOCK_EDIT:arg1:" \
    "--edit supports EDITOR with arguments" \
    env EDITOR="printf MOCK_EDIT:%s:%s arg1" bash "$TM_EXCLUSIONS" --edit

# ---- Uninstall dry-run ----
echo ""
echo "--- Uninstall dry-run ---"

assert_exit_code 0 \
    "--uninstall --dry-run exits 0" \
    bash "$TM_EXCLUSIONS" --verbose --uninstall --dry-run

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
    bash "$TM_EXCLUSIONS" --verbose --dry-run

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
    env TM_EXCLUSIONS_DEFAULT_CONF="${MINIMAL_CONF}" bash "$TM_EXCLUSIONS" --verbose --dry-run

assert_output_contains "/tmp/tm_exclusions_smoke_path" \
    "TM_EXCLUSIONS_DEFAULT_CONF dry-run uses override file" \
    env TM_EXCLUSIONS_DEFAULT_CONF="${MINIMAL_CONF}" bash "$TM_EXCLUSIONS" --verbose --dry-run

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
    env TM_EXCLUSIONS_DEFAULT_CONF="${MINIMAL_CONF}" bash "$TM_EXCLUSIONS" --verbose --dry-run

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

# Never use the host Time Machine or Homebrew cache in smoke tests.
mkdir -p "$TEST_HOME/bin"
cat > "$TEST_HOME/bin/tmutil" <<'STUB'
#!/bin/sh
if [ "$1" = isexcluded ]; then printf '[Included] %s\n' "$2"; fi
exit 0
STUB
cat > "$TEST_HOME/bin/brew" <<'STUB'
#!/bin/sh
exit 0
STUB
cat > "$TEST_HOME/bin/sudo" <<'STUB'
#!/bin/sh
# No host privilege operations in tests.
case "$1" in
    -n|-v) exit 0 ;;
    tmutil) shift; exec tmutil "$@" ;;
    *) exit 1 ;;
esac
STUB
chmod +x "$TEST_HOME/bin/"*
export PATH="$TEST_HOME/bin:$PATH"

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
MIN_ACTIVE_RULES=100
RULE_COUNT=$(grep -cE '^(path|pattern|prune)\|' "${CONF}" || true)
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "${RULE_COUNT}" -ge "${MIN_ACTIVE_RULES}" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '%b  PASS%b default.conf has >=%d active rules (got %d)\n' "$GREEN" "$NC" "${MIN_ACTIVE_RULES}" "${RULE_COUNT}"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '%b  FAIL%b default.conf has >=%d active rules (got %d)\n' "$RED" "$NC" "${MIN_ACTIVE_RULES}" "${RULE_COUNT}"
fi

# Distinct #@ category labels == EXPECTED_CATEGORY_COUNT. Single source of the
# number; scripts/add-category.sh bumps this exact line when it adds a category.
EXPECTED_CATEGORY_COUNT=18 # add-category: expected category count
LABEL_COUNT=$({ grep -E '^#@' "${CONF}" || true; } | sort -u | wc -l | tr -d ' ')
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "${LABEL_COUNT}" -eq "${EXPECTED_CATEGORY_COUNT}" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '%b  PASS%b default.conf has %d distinct #@ category labels\n' "$GREEN" "$NC" "${EXPECTED_CATEGORY_COUNT}"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '%b  FAIL%b default.conf has %d distinct #@ category labels (got %d)\n' "$RED" "$NC" "${EXPECTED_CATEGORY_COUNT}" "${LABEL_COUNT}"
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

# /private/var/folders is an active system-cache rule (#55)
TESTS_RUN=$((TESTS_RUN + 1))
if grep -qE '^path\|/private/var/folders\|' "${CONF}"; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '%b  PASS%b default.conf actively excludes /private/var/folders\n' "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '%b  FAIL%b default.conf missing active path|/private/var/folders rule\n' "$RED" "$NC"
fi

# ---- Backup cache prune zones (#25) ----
echo ""
echo "--- Backup cache prune zones (#25) ---"

# Shipped default.conf must list the package-manager .bak/.old prune zones.
# Quoted heredoc keeps the literal $HOME prefix used in config/default.conf.
while IFS= read -r bak_target; do
    [[ -z "$bak_target" ]] && continue
    TESTS_RUN=$((TESTS_RUN + 1))
    if grep -qF "prune|${bak_target}|" "${CONF}"; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        printf '%b  PASS%b default.conf prunes %s\n' "$GREEN" "$NC" "${bak_target}"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        printf '%b  FAIL%b default.conf missing prune for %s\n' "$RED" "$NC" "${bak_target}"
    fi
done <<'EOF'
$HOME/.bun.bak
$HOME/.bun.old
$HOME/.npm.bak
$HOME/.npm.old
$HOME/.yarn.bak
$HOME/.yarn.old
$HOME/.pnpm-store.bak
$HOME/.pnpm-store.old
$HOME/.cargo.bak
$HOME/.cargo.old
EOF

BAK_HOME="$(mktemp -d)"
# Reproduce the real-world noise: ~/.bun.bak/install/cache/<pkg>/node_modules
mkdir -p "${BAK_HOME}/.bun.bak/install/cache/pkg/node_modules"
mkdir -p "${BAK_HOME}/.npm.bak/foo/node_modules"
mkdir -p "${BAK_HOME}/.yarn.bak/cache/node_modules"
mkdir -p "${BAK_HOME}/.bun.old/install/cache/pkg/node_modules"
# Control: a non-catalog .bak tree must still be scanned.
mkdir -p "${BAK_HOME}/.unrelated.bak/pkg/node_modules"
# Control: a normal project tree must still be excluded.
mkdir -p "${BAK_HOME}/Git/proj/node_modules"

BAK_OUT="$(env HOME="${BAK_HOME}" \
                TM_EXCLUSIONS_DEFAULT_CONF="${CONF}" \
                bash "$TM_EXCLUSIONS" --verbose --dry-run 2>&1 || true)"

# Nested node_modules under .bun.bak must be pruned, not applied as an exclusion.
BAK_BUN_APPLY=$(printf '%s\n' "${BAK_OUT}" | grep -cE "(Applying exclusion:|Already excluded:).*\.bun\.bak/" || true)
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "${BAK_BUN_APPLY}" -eq 0 ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '%b  PASS%b ~/.bun.bak nested matches are not excluded\n' "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '%b  FAIL%b ~/.bun.bak should not emit exclusions, got %d\n' "$RED" "$NC" "${BAK_BUN_APPLY}"
fi

BAK_BUN_PRUNE=$(printf '%s\n' "${BAK_OUT}" | grep -cE "Pruning \(skipping scan of\):.*\.bun\.bak(/|$)" || true)
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "${BAK_BUN_PRUNE}" -ge 1 ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '%b  PASS%b ~/.bun.bak nested matches emit prune skip\n' "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '%b  FAIL%b expected prune skip under ~/.bun.bak\n' "$RED" "$NC"
fi

BAK_NPM_APPLY=$(printf '%s\n' "${BAK_OUT}" | grep -cE "(Applying exclusion:|Already excluded:).*\.npm\.bak/" || true)
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "${BAK_NPM_APPLY}" -eq 0 ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '%b  PASS%b ~/.npm.bak nested matches are not excluded\n' "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '%b  FAIL%b ~/.npm.bak should not emit exclusions, got %d\n' "$RED" "$NC" "${BAK_NPM_APPLY}"
fi

BAK_YARN_APPLY=$(printf '%s\n' "${BAK_OUT}" | grep -cE "(Applying exclusion:|Already excluded:).*\.yarn\.bak/" || true)
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "${BAK_YARN_APPLY}" -eq 0 ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '%b  PASS%b ~/.yarn.bak nested matches are not excluded\n' "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '%b  FAIL%b ~/.yarn.bak should not emit exclusions, got %d\n' "$RED" "$NC" "${BAK_YARN_APPLY}"
fi

BAK_OLD_APPLY=$(printf '%s\n' "${BAK_OUT}" | grep -cE "(Applying exclusion:|Already excluded:).*\.bun\.old/" || true)
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "${BAK_OLD_APPLY}" -eq 0 ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '%b  PASS%b ~/.bun.old nested matches are not excluded\n' "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '%b  FAIL%b ~/.bun.old should not emit exclusions, got %d\n' "$RED" "$NC" "${BAK_OLD_APPLY}"
fi

# Non-catalog .unrelated.bak must still receive the node_modules exclusion.
UNRELATED_HITS=$(printf '%s\n' "${BAK_OUT}" | grep -cE "(Applying exclusion:|Already excluded:).*\.unrelated\.bak/pkg/node_modules$" || true)
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "${UNRELATED_HITS}" -eq 1 ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '%b  PASS%b non-catalog ~/.unrelated.bak/pkg/node_modules is still excluded\n' "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '%b  FAIL%b expected 1 exclusion for ~/.unrelated.bak/pkg/node_modules, got %d\n' "$RED" "$NC" "${UNRELATED_HITS}"
fi

PROJ_HITS=$(printf '%s\n' "${BAK_OUT}" | grep -cE "(Applying exclusion:|Already excluded:).*Git/proj/node_modules$" || true)
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "${PROJ_HITS}" -eq 1 ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '%b  PASS%b normal Git/proj/node_modules is still excluded\n' "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '%b  FAIL%b expected 1 exclusion for Git/proj/node_modules, got %d\n' "$RED" "$NC" "${PROJ_HITS}"
fi

rm -rf "${BAK_HOME}"

# ---- Granular CoreSimulator subdirs (#54) ----
echo ""
echo "--- CoreSimulator subdirs (#54) ---"

# Do not exclude the HOME parent tree.
# Literal $HOME in the catalog (not expanded); [$] matches a dollar sign.
CSIM_PARENT_COUNT=$(grep -cE '^path\|[$]HOME/Library/Developer/CoreSimulator\|' "${CONF}" || true)
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "${CSIM_PARENT_COUNT}" -eq 0 ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '%b  PASS%b default.conf does not exclude HOME CoreSimulator parent\n' "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '%b  FAIL%b default.conf still excludes HOME CoreSimulator parent\n' "$RED" "$NC"
fi

CSIM_MISSING=""
for sub in Caches Temp Volumes; do
    if ! grep -qE "^path\\|[$]HOME/Library/Developer/CoreSimulator/${sub}\\|" "${CONF}"; then
        CSIM_MISSING="${CSIM_MISSING} ${sub}"
    fi
done
TESTS_RUN=$((TESTS_RUN + 1))
if [[ -z "${CSIM_MISSING}" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '%b  PASS%b default.conf excludes CoreSimulator Caches/Temp/Volumes\n' "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '%b  FAIL%b default.conf missing CoreSimulator subdir(s):%s\n' "$RED" "$NC" "${CSIM_MISSING}"
fi

CSIM_SYSTEM_COUNT=$(grep -cE '^path\|/Library/Developer/CoreSimulator\|' "${CONF}" || true)
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "${CSIM_SYSTEM_COUNT}" -eq 1 ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '%b  PASS%b default.conf still excludes system /Library/Developer/CoreSimulator\n' "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '%b  FAIL%b default.conf system CoreSimulator rule count is %d (expected 1)\n' "$RED" "$NC" "${CSIM_SYSTEM_COUNT}"
fi

# Upgrade: a leftover parent tmutil exclusion must be dropped (Copilot #54).
MIG_HOME="$(mktemp -d)"
mkdir -p "${MIG_HOME}/Library/Developer/CoreSimulator"
MIG_BIN="$(mktemp -d)"
cat > "${MIG_BIN}/tmutil" << 'EOF'
#!/bin/sh
cmd=$1
path=$2
parent="${HOME}/Library/Developer/CoreSimulator"
if [ "$cmd" = isexcluded ]; then
    if [ "${TMUTIL_STUB_EXCLUDE_PARENT:-}" = 1 ] && [ "$path" = "$parent" ]; then
        printf '%s [Excluded]\n' "$path"
    else
        printf '%s [Included]\n' "$path"
    fi
    exit 0
fi
exit 0
EOF
chmod +x "${MIG_BIN}/tmutil"
MIG_CONF="${MIG_HOME}/empty.conf"
: > "${MIG_CONF}"

MIG_OUT="$(env HOME="${MIG_HOME}" PATH="${MIG_BIN}:${PATH}" \
                TMUTIL_STUB_EXCLUDE_PARENT=1 \
                TM_EXCLUSIONS_DEFAULT_CONF="${MIG_CONF}" \
                bash "$TM_EXCLUSIONS" --verbose --dry-run 2>&1 || true)"
MIG_HITS=$(printf '%s\n' "${MIG_OUT}" | grep -cF "WOULD_REMOVE ${MIG_HOME}/Library/Developer/CoreSimulator" || true)
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "${MIG_HITS}" -eq 1 ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '%b  PASS%b dry-run drops retired CoreSimulator parent exclusion\n' "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '%b  FAIL%b expected 1 WOULD_REMOVE for retired CoreSimulator parent, got %d\n' "$RED" "$NC" "${MIG_HITS}"
fi

MIG_CTRL="$(env HOME="${MIG_HOME}" PATH="${MIG_BIN}:${PATH}" \
                 TMUTIL_STUB_EXCLUDE_PARENT=0 \
                 TM_EXCLUSIONS_DEFAULT_CONF="${MIG_CONF}" \
                 bash "$TM_EXCLUSIONS" --verbose --dry-run 2>&1 || true)"
MIG_CTRL_HITS=$(printf '%s\n' "${MIG_CTRL}" | grep -cF "WOULD_REMOVE ${MIG_HOME}/Library/Developer/CoreSimulator" || true)
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "${MIG_CTRL_HITS}" -eq 0 ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '%b  PASS%b dry-run is silent when CoreSimulator parent is not excluded\n' "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '%b  FAIL%b did not expect WOULD_REMOVE when parent is not excluded, got %d\n' "$RED" "$NC" "${MIG_CTRL_HITS}"
fi
rm -rf "${MIG_HOME}" "${MIG_BIN}"

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
                bash "$TM_EXCLUSIONS" --verbose --dry-run 2>&1 || true)"

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
                bash "$TM_EXCLUSIONS" --verbose --dry-run 2>&1 || true)"

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

# ---- du -sk tolerance for partially-readable paths (#18, #55) ----
# NOTE: chmod 000 on the subdir is vacuous on root CI runners (root ignores
# permission bits), so the test only exercises the pipefail fix on user runners.
echo ""
echo "--- du -sk tolerance for unreadable subdirs (#18, #55) ---"

DU_HOME="$(mktemp -d "${TEST_HOME}/du-test.XXXXXX")"
mkdir -p "${DU_HOME}/restrictedparent/unreadable_subdir"
chmod 000 "${DU_HOME}/restrictedparent/unreadable_subdir"
DU_CONF="${DU_HOME}/du-test.conf"
cat > "${DU_CONF}" << EOF
path|${DU_HOME}/restrictedparent|du tolerance test
EOF

assert_exit_code 0 \
    "--dry-run exits 0 with partially-unreadable path in config" \
    env -u TM_EXCLUSIONS_SKIP_DU HOME="${DU_HOME}" TM_EXCLUSIONS_DEFAULT_CONF="${DU_CONF}" \
        bash "$TM_EXCLUSIONS" --verbose --dry-run

assert_exit_code 0 \
    "--report-only exits 0 with partially-unreadable path in config" \
    env -u TM_EXCLUSIONS_SKIP_DU HOME="${DU_HOME}" TM_EXCLUSIONS_DEFAULT_CONF="${DU_CONF}" \
        bash "$TM_EXCLUSIONS" --verbose --report-only

chmod 700 "${DU_HOME}/restrictedparent/unreadable_subdir"
rm -rf "${DU_HOME}"

# Stub `du` that prints a partial total then exits 1 — the /private/var/folders
# failure mode — so the isolation in du_size_kb is covered even as root.
echo ""
echo "--- du -sk stub exits 1 without aborting (#55) ---"

FAKE_DU_BIN="$(mktemp -d "${TEST_HOME}/fake-du.XXXXXX")"
cat > "${FAKE_DU_BIN}/du" << 'EOF'
#!/bin/sh
# Mimic BSD/GNU du on /private/var/folders: partial total, then fail.
echo "42	dummy"
exit 1
EOF
chmod +x "${FAKE_DU_BIN}/du"

FAKE_DU_HOME="$(mktemp -d "${TEST_HOME}/fake-du-home.XXXXXX")"
mkdir -p "${FAKE_DU_HOME}/restrictedparent"
FAKE_DU_CONF="${FAKE_DU_HOME}/du-test.conf"
cat > "${FAKE_DU_CONF}" << EOF
path|${FAKE_DU_HOME}/restrictedparent|du stub test
EOF

assert_exit_code 0 \
    "--dry-run exits 0 when du -sk returns non-zero (#55)" \
    env -u TM_EXCLUSIONS_SKIP_DU HOME="${FAKE_DU_HOME}" PATH="${FAKE_DU_BIN}:${PATH}" \
        TM_EXCLUSIONS_DEFAULT_CONF="${FAKE_DU_CONF}" \
        bash "$TM_EXCLUSIONS" --verbose --dry-run

assert_output_contains "42K" \
    "report keeps partial du size when du exits 1 (#55)" \
    env -u TM_EXCLUSIONS_SKIP_DU HOME="${FAKE_DU_HOME}" PATH="${FAKE_DU_BIN}:${PATH}" \
        TM_EXCLUSIONS_DEFAULT_CONF="${FAKE_DU_CONF}" \
        bash "$TM_EXCLUSIONS" --verbose --dry-run

assert_output_contains "Total (sum of du -sk, KiB): 42" \
    "du total sums the partial KiB when du exits 1 (#55)" \
    env -u TM_EXCLUSIONS_SKIP_DU HOME="${FAKE_DU_HOME}" PATH="${FAKE_DU_BIN}:${PATH}" \
        TM_EXCLUSIONS_DEFAULT_CONF="${FAKE_DU_CONF}" \
        bash "$TM_EXCLUSIONS" --verbose --dry-run

rm -rf "${FAKE_DU_BIN}" "${FAKE_DU_HOME}"

# ---- Per-path disk size column (#45) ----
# Stub du with deterministic per-path sizes; every invocation is logged so the
# test can prove each existing path is walked exactly once (the per-path column
# and the end-of-run report share the same measurement).
echo ""
echo "--- Per-path disk size column (#45) ---"

SZ_BIN="$(mktemp -d "${TEST_HOME}/sz-du.XXXXXX")"
SZ_CALLS="${TEST_HOME}/sz-du-calls.log"
: > "${SZ_CALLS}"
SZ_HOME="$(mktemp -d "${TEST_HOME}/sz-home.XXXXXX")"
mkdir -p "${SZ_HOME}/caches/big" "${SZ_HOME}/caches/small" "${SZ_HOME}/caches/locked" "${SZ_HOME}/caches/vanish"
cat > "${SZ_BIN}/du" << EOF
#!/bin/sh
printf '%s\n' "\$*" >> "${SZ_CALLS}"
case "\$*" in
    *big*)    printf '1048576\t%s\n' "\$*"; exit 0 ;;
    *small*)  printf '42\t%s\n' "\$*"; exit 0 ;;
    *locked*) exit 1 ;;
    # vanish simulates a cache deleted between its measurement and the report.
    *vanish*) printf '1048576\t%s\n' "\$*"; rm -rf "${SZ_HOME}/caches/vanish"; exit 0 ;;
esac
printf '4\t%s\n' "\$*"; exit 0
EOF
chmod +x "${SZ_BIN}/du"

SZ_CONF="${SZ_HOME}/sz.conf"
cat > "${SZ_CONF}" << EOF
path|${SZ_HOME}/caches/big|big cache
path|${SZ_HOME}/caches/big|big cache again (duplicate rule on purpose)
path|${SZ_HOME}/caches/small|small cache
path|${SZ_HOME}/caches/locked|locked cache
path|${SZ_HOME}/caches/vanish|vanishing cache
path|${SZ_HOME}/gone|missing path
EOF

SZ_ENV=(env -u TM_EXCLUSIONS_SKIP_DU HOME="${SZ_HOME}" PATH="${SZ_BIN}:${PATH}" TM_EXCLUSIONS_DEFAULT_CONF="${SZ_CONF}")
SZ_OUT="${TEST_HOME}/sz-out.txt"
SZ_RC=0
"${SZ_ENV[@]}" bash "$TM_EXCLUSIONS" --verbose --dry-run > "${SZ_OUT}" 2>&1 || SZ_RC=$?
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "${SZ_RC}" -eq 0 ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '%b  PASS%b dry-run with size column exits 0 (#45)\n' "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '%b  FAIL%b dry-run with size column exited %d (#45)\n' "$RED" "$NC" "$SZ_RC"
    tail -n 40 "${SZ_OUT}" >&2
fi

# Size displayed next to each path, right-aligned in a fixed 8-cell column.
assert_file_contains "${SZ_OUT}" \
    "$(printf '  [DRY-RUN] Applying exclusion: %8s  %s' '1.0G' "${SZ_HOME}/caches/big")" \
    "size 1.0G is shown next to the big path, aligned in 8 cells (#45)"
assert_file_contains "${SZ_OUT}" \
    "$(printf '  [DRY-RUN] Applying exclusion: %8s  %s' '42K' "${SZ_HOME}/caches/small")" \
    "size 42K is shown next to the small path, aligned in 8 cells (#45)"

# Placeholders: unreadable path (du fails) and missing path both show "-".
assert_file_contains "${SZ_OUT}" \
    "$(printf '  [DRY-RUN] Applying exclusion: %8s  %s' '-' "${SZ_HOME}/caches/locked")" \
    "unreadable path shows the - placeholder without failing (#45)"
assert_file_contains "${SZ_OUT}" \
    "$(printf '  Path not found, skipping: %8s  %s' '-' "${SZ_HOME}/gone")" \
    "missing path shows the - placeholder (#45)"

# The vanishing cache is measured (and displayed) before disappearing.
assert_file_contains "${SZ_OUT}" \
    "$(printf '  [DRY-RUN] Applying exclusion: %8s  %s' '1.0G' "${SZ_HOME}/caches/vanish")" \
    "vanishing path still shows its measured size at process time (#45)"

# Cumulative global counter at end of run (KiB line kept, formatted total added).
# The vanishing path was deleted after its measurement, so the total must count
# only big + small (1048618 KiB) — never 2097194 — i.e. summary and report share
# the same source (du_total_kb) (#45, #77 review).
assert_file_contains "${SZ_OUT}" \
    "Total (sum of du -sk, KiB): 1048618" \
    "cumulative KiB total sums the surviving per-path sizes (#45)"
assert_file_lacks_regex "${SZ_OUT}" \
    '2097194' \
    "deleted-mid-run path is excluded from the cumulative total (#77 review)"
assert_file_contains "${SZ_OUT}" \
    "Disk usage total: 1.0G" \
    "cumulative formatted total is reported at end of run (#45)"

# Cost: one du invocation per distinct existing path — the duplicate big rule
# and the missing path must not add any walk (#45 review, bloquant).
SZ_DU_CALLS="$(wc -l < "${SZ_CALLS}" | tr -d '[:space:]')"
assert_eq 4 "${SZ_DU_CALLS}" \
    "repeated rule reuses the cached size: one du per distinct path (#45)"

# Quiet mode: no per-path size lines at all.
assert_output_not_contains "Applying exclusion:" \
    "quiet run prints no per-path application lines (#45)" \
    "${SZ_ENV[@]}" bash "$TM_EXCLUSIONS" -q --dry-run
assert_output_not_contains "Path not found, skipping:" \
    "quiet run prints no per-path not-found lines (#45)" \
    "${SZ_ENV[@]}" bash "$TM_EXCLUSIONS" -q --dry-run

# TM_EXCLUSIONS_SKIP_DU=1 keeps the plain line (no size column at all).
SZ_SD_OUT="${TEST_HOME}/sz-skipdu.txt"
"${SZ_ENV[@]}" env TM_EXCLUSIONS_SKIP_DU=1 bash "$TM_EXCLUSIONS" --verbose --dry-run > "${SZ_SD_OUT}" 2>&1 || true
assert_file_contains "${SZ_SD_OUT}" \
    "Applying exclusion: ${SZ_HOME}/caches/big" \
    "SKIP_DU=1 keeps the plain per-path line (#45)"
assert_file_lacks_regex "${SZ_SD_OUT}" \
    'exclusion: +([0-9.]+[KMGT]?|-)  ' \
    "SKIP_DU=1 shows no size column (#45)"

# Unit check (#77 review): du_total_kb is the single source of the cumulative
# total — a path deleted after its measurement must be skipped, exactly like
# the report's per-path lines, so summary and report can never diverge.
# Temp file instead of process substitution: `source <(...)` does not load
# functions under Bash 3.2 (macOS default).
_du_src=$(mktemp "${TMPDIR:-/tmp}/tm-du-src.XXXXXX")
sed '/^main /d' "$TM_EXCLUSIONS" > "$_du_src"
# shellcheck disable=SC1090
source "$_du_src"
rm -f "$_du_src"
require_functions du_total_kb du_size_record
# Used inside the sourced script (du_total_kb), invisible to ShellCheck here.
# shellcheck disable=SC2034
DU_PATHS=""
# shellcheck disable=SC2034
DU_SIZES=""
SZ_VICTIM="${SZ_HOME}/caches/vanish2"
SZ_SURVIVOR="${SZ_HOME}/caches/survivor"
mkdir -p "${SZ_VICTIM}" "${SZ_SURVIVOR}"
du_size_record "${SZ_VICTIM}" "1048576"
du_size_record "${SZ_SURVIVOR}" "42"
# shellcheck disable=SC2034
DU_PATHS="${SZ_VICTIM}
${SZ_SURVIVOR}"
rm -rf "${SZ_VICTIM}"
assert_eq 42 "$(du_total_kb)" \
    "du_total_kb skips a path deleted after measurement — same source as the report (#77 review)"

# Run-3 review: the cumulative total must be computed ONCE and handed to the
# summary. A `hostname` stub deletes the beta cache while generate_report
# assembles the report header (`Host: $(hostname)`) — i.e. after the total is
# computed and before the interactive summary — and report must equal summary
# (red on d251be7e where ui_summary recomputed du_total_kb).
SZ_TM_BIN="$(mktemp -d "${TEST_HOME}/sz-tm.XXXXXX")"
SZ_HOST_RAN="${SZ_TM_BIN}/hostname.ran"
cat > "${SZ_TM_BIN}/hostname" << EOF
#!/bin/sh
rm -rf "${SZ_HOME}/caches/beta"
: > "${SZ_HOST_RAN}"
echo stub-host
EOF
chmod +x "${SZ_TM_BIN}/hostname"
SZ_ALPHA="${SZ_HOME}/caches/alpha"
SZ_BETA="${SZ_HOME}/caches/beta"
mkdir -p "${SZ_ALPHA}" "${SZ_BETA}"
# Load the English locale directly: TM_EXCLUSIONS_LOCALES_DIR is ignored under
# root and the sourced script's BASH_SOURCE is /dev/fd/NN, so load_i18n could
# exit 1 there (#77 run-3 review).
# shellcheck source=locales/en.sh
source "$ROOT/locales/en.sh"
declare_i18n_en
# Globals consumed by the sourced script — invisible to ShellCheck here.
# shellcheck disable=SC2034
MODE="apply"
# shellcheck disable=SC2034
DRY_RUN=1
# shellcheck disable=SC2034
QUIET=0
# shellcheck disable=SC2034
UI=1
# shellcheck disable=SC2034
HAS_TMUTIL=1
# shellcheck disable=SC2034
TOTAL_CHECKED=2
# shellcheck disable=SC2034
TOTAL_EXCLUDED=2
# shellcheck disable=SC2034
TOTAL_ALREADY=0
# shellcheck disable=SC2034
TOTAL_SKIPPED=0
# shellcheck disable=SC2034
TOTAL_ERRORS=0
# shellcheck disable=SC2034
TOTAL_BLOCKED=0
# shellcheck disable=SC2034
TOTAL_NOT_FOUND=0
# shellcheck disable=SC2034
TOTAL_REMOVED=0
# shellcheck disable=SC2034
REPORT_LINES=""
# shellcheck disable=SC2034
RULE_SUMMARY=""
# shellcheck disable=SC2034
RULE_CONTEXT=""
# shellcheck disable=SC2034
DU_PATHS="${SZ_ALPHA}
${SZ_BETA}"
# shellcheck disable=SC2034
DU_SIZES="$(printf '%s\t100\n%s\t50' "${SZ_ALPHA}" "${SZ_BETA}")"
SZ_REPORT="${TEST_HOME}/sz-report.txt"
SZ_SUMMARY="${TEST_HOME}/sz-summary.txt"
SZ_OLD_PATH="${PATH}"
PATH="${SZ_TM_BIN}:${PATH}"
# In-process report of precomputed sizes: the smoke-wide SKIP_DU must not hide
# the very lines asserted below.
unset TM_EXCLUSIONS_SKIP_DU
TM_EXCLUSIONS_REPORT="${SZ_REPORT}" generate_report > "${SZ_SUMMARY}" 2>&1 || true
export TM_EXCLUSIONS_SKIP_DU=1
PATH="${SZ_OLD_PATH}"
assert_true "tree mutation point ran after the total (hostname stub invoked, beta removed)" \
    test -f "${SZ_HOST_RAN}" -a ! -e "${SZ_BETA}"
assert_file_contains "${SZ_REPORT}" "Total (sum of du -sk, KiB): 150" \
    "report total is computed before the tree changes (#77 run-3)"
assert_file_contains "${SZ_REPORT}" "Disk usage total: 150K" \
    "report carries the formatted cumulative total (#45)"
assert_file_contains "${SZ_SUMMARY}" "Disk usage total: 150K" \
    "interactive summary reuses the precomputed total — report == summary (#77 run-3)"
assert_file_lacks_regex "${SZ_SUMMARY}" 'Disk usage total: 100K' \
    "summary never recomputes the total after the tree changes (#77 run-3)"
rm -rf "${SZ_TM_BIN}"

rm -rf "${SZ_BIN}" "${SZ_HOME}"

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
              bash "$TM_EXCLUSIONS" --verbose --dry-run 2>&1 || true)"

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
        bash "$TM_EXCLUSIONS" --verbose --dry-run

assert_output_contains "Pruning" \
    "TM_EXCLUSIONS_EXTRA_CONF prune rule is applied (prune message emitted)" \
    env HOME="${EXTRA_HOME}" \
        TM_EXCLUSIONS_DEFAULT_CONF="${EXTRA_DEFAULT}" \
        TM_EXCLUSIONS_EXTRA_CONF="${EXTRA_CONF}" \
        bash "$TM_EXCLUSIONS" --verbose --dry-run

# Test: missing file → script does NOT abort, warns on stderr
MISSING_CONF="${EXTRA_HOME}/does-not-exist.conf"

assert_exit_code 0 \
    "TM_EXCLUSIONS_EXTRA_CONF missing file — script exits 0 (does not abort)" \
    env HOME="${EXTRA_HOME}" \
        TM_EXCLUSIONS_DEFAULT_CONF="${EXTRA_DEFAULT}" \
        TM_EXCLUSIONS_EXTRA_CONF="${MISSING_CONF}" \
        bash "$TM_EXCLUSIONS" --verbose --dry-run

EXTRA_WARN_STDERR="$(env HOME="${EXTRA_HOME}" \
    TM_EXCLUSIONS_DEFAULT_CONF="${EXTRA_DEFAULT}" \
    TM_EXCLUSIONS_EXTRA_CONF="${MISSING_CONF}" \
    bash "$TM_EXCLUSIONS" --verbose --dry-run 2>&1 1>/dev/null || true)"
TESTS_RUN=$((TESTS_RUN + 1))
if grep -q "Warning:.*TM_EXCLUSIONS_EXTRA_CONF" <<<"${EXTRA_WARN_STDERR}"; then
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
        bash "$TM_EXCLUSIONS" --verbose --dry-run

# Test: directory path → -r passes but -f fails → must warn (not silently no-op)
DIR_AS_CONF="${EXTRA_HOME}/some-dir"
mkdir -p "${DIR_AS_CONF}"

assert_exit_code 0 \
    "TM_EXCLUSIONS_EXTRA_CONF is a directory — script exits 0" \
    env HOME="${EXTRA_HOME}" \
        TM_EXCLUSIONS_DEFAULT_CONF="${EXTRA_DEFAULT}" \
        TM_EXCLUSIONS_EXTRA_CONF="${DIR_AS_CONF}" \
        bash "$TM_EXCLUSIONS" --verbose --dry-run

DIR_WARN_STDERR="$(env HOME="${EXTRA_HOME}" \
    TM_EXCLUSIONS_DEFAULT_CONF="${EXTRA_DEFAULT}" \
    TM_EXCLUSIONS_EXTRA_CONF="${DIR_AS_CONF}" \
    bash "$TM_EXCLUSIONS" --verbose --dry-run 2>&1 1>/dev/null || true)"
TESTS_RUN=$((TESTS_RUN + 1))
if grep -q "Warning:.*TM_EXCLUSIONS_EXTRA_CONF" <<<"${DIR_WARN_STDERR}"; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '%b  PASS%b TM_EXCLUSIONS_EXTRA_CONF directory path prints warning to stderr\n' "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '%b  FAIL%b TM_EXCLUSIONS_EXTRA_CONF directory path should print warning\n' "$RED" "$NC"
fi

rm -rf "${EXTRA_HOME}"

# ---- Report destination settings (#52) ----
echo ""
echo "--- setting|report_path / desktop_report (#52) ---"

REPSET_HOME="$(mktemp -d "${TEST_HOME}/report-setting.XXXXXX")"
REPSET_DEFAULT="${REPSET_HOME}/default.conf"
cat > "${REPSET_DEFAULT}" << 'EOF'
path|/tmp/tm_exclusions_report_setting_path|smoke report setting
EOF
mkdir -p "${REPSET_HOME}/.config/tm_exclusions" "${REPSET_HOME}/Desktop" "${REPSET_HOME}/Documents"

# Primary report file from config (tilde expansion)
cat > "${REPSET_HOME}/.config/tm_exclusions/custom.conf" << 'EOF'
setting|report_path|~/Documents/from-config.txt
EOF

assert_exit_code 0 \
    "setting|report_path dry-run exits 0" \
    env -u TM_EXCLUSIONS_REPORT -u TM_EXCLUSIONS_EXTRA_CONF \
        HOME="${REPSET_HOME}" TM_EXCLUSIONS_DEFAULT_CONF="${REPSET_DEFAULT}" \
        bash "$TM_EXCLUSIONS" --verbose --dry-run

TESTS_RUN=$((TESTS_RUN + 1))
if [[ -f "${REPSET_HOME}/Documents/from-config.txt" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '%b  PASS%b setting|report_path writes configured file\n' "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '%b  FAIL%b setting|report_path did not write ~/Documents/from-config.txt\n' "$RED" "$NC"
fi

TESTS_RUN=$((TESTS_RUN + 1))
if [[ -f "${REPSET_HOME}/.config/tm_exclusions/last_report.txt" ]]; then
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '%b  FAIL%b setting|report_path should not write the built-in last_report.txt\n' "$RED" "$NC"
else
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '%b  PASS%b setting|report_path does not write built-in last_report.txt\n' "$GREEN" "$NC"
fi

# $HOME expansion in report_path value
cat > "${REPSET_HOME}/.config/tm_exclusions/custom.conf" << 'EOF'
setting|report_path|$HOME/Documents/from-home-token.txt
EOF
assert_exit_code 0 \
    "setting|report_path with \$HOME token exits 0" \
    env -u TM_EXCLUSIONS_REPORT -u TM_EXCLUSIONS_EXTRA_CONF \
        HOME="${REPSET_HOME}" TM_EXCLUSIONS_DEFAULT_CONF="${REPSET_DEFAULT}" \
        bash "$TM_EXCLUSIONS" --verbose --dry-run
TESTS_RUN=$((TESTS_RUN + 1))
if [[ -f "${REPSET_HOME}/Documents/from-home-token.txt" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf "%b  PASS%b setting|report_path expands \$HOME in value\n" "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf "%b  FAIL%b setting|report_path \$HOME expansion missing file\n" "$RED" "$NC"
fi

# Env TM_EXCLUSIONS_REPORT overrides config report_path
ENV_REPORT="${REPSET_HOME}/from-env.txt"
rm -f "${REPSET_HOME}/Documents/from-config.txt"
cat > "${REPSET_HOME}/.config/tm_exclusions/custom.conf" << 'EOF'
setting|report_path|~/Documents/from-config.txt
EOF
assert_exit_code 0 \
    "TM_EXCLUSIONS_REPORT overrides setting|report_path" \
    env HOME="${REPSET_HOME}" TM_EXCLUSIONS_DEFAULT_CONF="${REPSET_DEFAULT}" \
        TM_EXCLUSIONS_REPORT="${ENV_REPORT}" \
        bash "$TM_EXCLUSIONS" --verbose --dry-run
TESTS_RUN=$((TESTS_RUN + 1))
if [[ -f "${ENV_REPORT}" && ! -f "${REPSET_HOME}/Documents/from-config.txt" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '%b  PASS%b TM_EXCLUSIONS_REPORT overrides setting|report_path\n' "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '%b  FAIL%b env report override: env=%s config=%s\n' "$RED" "$NC" \
        "$( [[ -f "${ENV_REPORT}" ]] && echo yes || echo no )" \
        "$( [[ -f "${REPSET_HOME}/Documents/from-config.txt" ]] && echo yes || echo no )"
fi

# desktop_report true without CLI/env
DESK_COPY="${REPSET_HOME}/Desktop/tm-exclusions_last_report.txt"
rm -f "${DESK_COPY}"
cat > "${REPSET_HOME}/.config/tm_exclusions/custom.conf" << 'EOF'
setting|desktop_report|true
EOF
assert_exit_code 0 \
    "setting|desktop_report|true dry-run exits 0" \
    env -u TM_EXCLUSIONS_REPORT -u TM_EXCLUSIONS_EXTRA_CONF -u TM_EXCLUSIONS_REPORT_DESKTOP \
        HOME="${REPSET_HOME}" \
        TM_EXCLUSIONS_DEFAULT_CONF="${REPSET_DEFAULT}" \
        bash "$TM_EXCLUSIONS" --verbose --dry-run
TESTS_RUN=$((TESTS_RUN + 1))
if [[ -f "${DESK_COPY}" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '%b  PASS%b setting|desktop_report|true writes Desktop copy\n' "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '%b  FAIL%b setting|desktop_report|true Desktop copy missing\n' "$RED" "$NC"
fi

# Env 0 overrides config true
rm -f "${DESK_COPY}"
assert_exit_code 0 \
    "TM_EXCLUSIONS_REPORT_DESKTOP=0 overrides setting|desktop_report|true" \
    env HOME="${REPSET_HOME}" TM_EXCLUSIONS_DEFAULT_CONF="${REPSET_DEFAULT}" \
        TM_EXCLUSIONS_REPORT_DESKTOP=0 \
        bash "$TM_EXCLUSIONS" --verbose --dry-run
TESTS_RUN=$((TESTS_RUN + 1))
if [[ -f "${DESK_COPY}" ]]; then
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '%b  FAIL%b env=0 should suppress Desktop copy from config\n' "$RED" "$NC"
else
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '%b  PASS%b TM_EXCLUSIONS_REPORT_DESKTOP=0 overrides config desktop_report\n' "$GREEN" "$NC"
fi

# CLI flag overrides config false
cat > "${REPSET_HOME}/.config/tm_exclusions/custom.conf" << 'EOF'
setting|desktop_report|false
EOF
rm -f "${DESK_COPY}"
assert_exit_code 0 \
    "--desktop-report overrides setting|desktop_report|false" \
    env -u TM_EXCLUSIONS_REPORT -u TM_EXCLUSIONS_EXTRA_CONF -u TM_EXCLUSIONS_REPORT_DESKTOP \
        HOME="${REPSET_HOME}" \
        TM_EXCLUSIONS_DEFAULT_CONF="${REPSET_DEFAULT}" \
        bash "$TM_EXCLUSIONS" --desktop-report --dry-run
TESTS_RUN=$((TESTS_RUN + 1))
if [[ -f "${DESK_COPY}" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '%b  PASS%b --desktop-report overrides setting|desktop_report|false\n' "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '%b  FAIL%b CLI --desktop-report should write Desktop copy\n' "$RED" "$NC"
fi

# Extra conf setting last-wins over custom.conf
cat > "${REPSET_HOME}/.config/tm_exclusions/custom.conf" << 'EOF'
setting|desktop_report|true
EOF
EXTRA_SET="${REPSET_HOME}/extra.conf"
cat > "${EXTRA_SET}" << 'EOF'
setting|desktop_report|false
EOF
rm -f "${DESK_COPY}"
assert_exit_code 0 \
    "later extra conf setting|desktop_report|false wins" \
    env -u TM_EXCLUSIONS_REPORT -u TM_EXCLUSIONS_REPORT_DESKTOP HOME="${REPSET_HOME}" \
        TM_EXCLUSIONS_DEFAULT_CONF="${REPSET_DEFAULT}" \
        TM_EXCLUSIONS_EXTRA_CONF="${EXTRA_SET}" \
        bash "$TM_EXCLUSIONS" --verbose --dry-run
TESTS_RUN=$((TESTS_RUN + 1))
if [[ -f "${DESK_COPY}" ]]; then
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '%b  FAIL%b extra conf desktop_report false should win over custom.conf true\n' "$RED" "$NC"
else
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '%b  PASS%b extra conf setting last-wins over custom.conf\n' "$GREEN" "$NC"
fi

# Report write failures warn without claiming success
: > "${REPSET_HOME}/blocked"
cat > "${REPSET_HOME}/.config/tm_exclusions/custom.conf" << 'EOF'
setting|report_path|~/blocked/report.txt
EOF
WRITE_FAIL_OUT="${REPSET_HOME}/write-fail.out"
WRITE_FAIL_ERR="${REPSET_HOME}/write-fail.err"
TESTS_RUN=$((TESTS_RUN + 1))
if ! env -u TM_EXCLUSIONS_REPORT -u TM_EXCLUSIONS_EXTRA_CONF HOME="${REPSET_HOME}" \
    TM_EXCLUSIONS_DEFAULT_CONF="${REPSET_DEFAULT}" \
    bash "$TM_EXCLUSIONS" --verbose --dry-run > "${WRITE_FAIL_OUT}" 2> "${WRITE_FAIL_ERR}"; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '%b  PASS%b setting|report_path write failure exits non-zero\n' "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '%b  FAIL%b setting|report_path write failure exits 0\n' "$RED" "$NC"
fi
TESTS_RUN=$((TESTS_RUN + 1))
if grep -q "Could not save report to: ${REPSET_HOME}/blocked/report.txt" "${WRITE_FAIL_ERR}" \
    && ! grep -q "Report saved to: ${REPSET_HOME}/blocked/report.txt" "${WRITE_FAIL_OUT}"; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '%b  PASS%b report write failure warns without success log\n' "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '%b  FAIL%b report write failure should warn and skip success log\n' "$RED" "$NC"
fi

# Two-field `setting|report_path` (no value) must not treat the key as a relative path
cat > "${REPSET_HOME}/.config/tm_exclusions/custom.conf" << 'EOF'
setting|report_path
EOF
rm -f "${REPSET_HOME}/.config/tm_exclusions/last_report.txt" "${REPSET_HOME}/report_path"
MISSING_FIELD_ERR="${REPSET_HOME}/missing-field.err"
assert_exit_code 0 \
    "setting|report_path without value exits 0" \
    env -u TM_EXCLUSIONS_REPORT -u TM_EXCLUSIONS_EXTRA_CONF \
        HOME="${REPSET_HOME}" TM_EXCLUSIONS_DEFAULT_CONF="${REPSET_DEFAULT}" \
        bash "$TM_EXCLUSIONS" --verbose --dry-run
env -u TM_EXCLUSIONS_REPORT -u TM_EXCLUSIONS_EXTRA_CONF \
    HOME="${REPSET_HOME}" TM_EXCLUSIONS_DEFAULT_CONF="${REPSET_DEFAULT}" \
    bash "$TM_EXCLUSIONS" --verbose --dry-run >/dev/null 2>"${MISSING_FIELD_ERR}" || true
TESTS_RUN=$((TESTS_RUN + 1))
if grep -q "Empty report_path setting" "${MISSING_FIELD_ERR}" \
    && [[ -f "${REPSET_HOME}/.config/tm_exclusions/last_report.txt" ]] \
    && [[ ! -e "${REPSET_HOME}/report_path" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '%b  PASS%b setting|report_path without value warns and keeps default report\n' "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '%b  FAIL%b setting|report_path without value should warn and ignore\n' "$RED" "$NC"
fi

# Empty third field
cat > "${REPSET_HOME}/.config/tm_exclusions/custom.conf" << 'EOF'
setting|report_path|
EOF
assert_output_contains "Empty report_path setting" \
    "setting|report_path| empty value warns" \
    env -u TM_EXCLUSIONS_REPORT -u TM_EXCLUSIONS_EXTRA_CONF \
        HOME="${REPSET_HOME}" TM_EXCLUSIONS_DEFAULT_CONF="${REPSET_DEFAULT}" \
        bash "$TM_EXCLUSIONS" --verbose --dry-run

# Invalid desktop_report value is ignored
rm -f "${DESK_COPY}"
cat > "${REPSET_HOME}/.config/tm_exclusions/custom.conf" << 'EOF'
setting|desktop_report|maybe
EOF
assert_output_contains "Invalid desktop_report value" \
    "setting|desktop_report|maybe warns" \
    env -u TM_EXCLUSIONS_REPORT -u TM_EXCLUSIONS_EXTRA_CONF -u TM_EXCLUSIONS_REPORT_DESKTOP \
        HOME="${REPSET_HOME}" TM_EXCLUSIONS_DEFAULT_CONF="${REPSET_DEFAULT}" \
        bash "$TM_EXCLUSIONS" --verbose --dry-run
TESTS_RUN=$((TESTS_RUN + 1))
if [[ -f "${DESK_COPY}" ]]; then
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '%b  FAIL%b invalid desktop_report should not write Desktop copy\n' "$RED" "$NC"
else
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '%b  PASS%b invalid desktop_report does not enable Desktop copy\n' "$GREEN" "$NC"
fi

# Unknown setting warns, still exits 0
cat > "${REPSET_HOME}/.config/tm_exclusions/custom.conf" << 'EOF'
setting|not_a_real_key|zzz
EOF
assert_exit_code 0 \
    "unknown setting key exits 0" \
    env HOME="${REPSET_HOME}" TM_EXCLUSIONS_DEFAULT_CONF="${REPSET_DEFAULT}" \
        bash "$TM_EXCLUSIONS" --verbose --dry-run
assert_output_contains "Unknown setting" \
    "unknown setting key warns" \
    env HOME="${REPSET_HOME}" TM_EXCLUSIONS_DEFAULT_CONF="${REPSET_DEFAULT}" \
        bash "$TM_EXCLUSIONS" --verbose --dry-run

assert_output_contains "setting (report_path, desktop_report, scan_images)" \
    "--help mentions setting config type" \
    env HOME="${REPSET_HOME}" bash "$TM_EXCLUSIONS" --help

cat > "${REPSET_HOME}/.config/tm_exclusions/custom.conf" << 'EOF'
setting|report_path
EOF
assert_output_contains "report_path vide" \
    "--lang fr localizes empty report_path warning" \
    env -u TM_EXCLUSIONS_REPORT -u TM_EXCLUSIONS_EXTRA_CONF \
        HOME="${REPSET_HOME}" TM_EXCLUSIONS_DEFAULT_CONF="${REPSET_DEFAULT}" \
        bash "$TM_EXCLUSIONS" --lang fr --dry-run

# --list shows setting lines
cat > "${REPSET_HOME}/.config/tm_exclusions/custom.conf" << 'EOF'
setting|report_path|~/Documents/from-config.txt
EOF
assert_output_contains "setting|report_path" \
    "--list shows setting|report_path line" \
    env HOME="${REPSET_HOME}" bash "$TM_EXCLUSIONS" --list

rm -rf "${REPSET_HOME}"

# ---- Locale loading (#16) ----
echo ""
echo "--- Locale loading (#16) ---"

# TM_EXCLUSIONS_LOCALES_DIR is deliberately ignored when running as root, so that
# `sudo -E` cannot make the script source an attacker-controlled locale file
# (see resolve_locales_dir). The expected outcome therefore depends on the EUID.
LOCALE_MISSING_STDERR="$(env TM_EXCLUSIONS_LOCALES_DIR=/nonexistent \
    bash "$TM_EXCLUSIONS" --lang en --help 2>&1 1>/dev/null || true)"
LOCALE_EXIT=0
env TM_EXCLUSIONS_LOCALES_DIR=/nonexistent bash "$TM_EXCLUSIONS" --lang en --help >/dev/null 2>&1 || LOCALE_EXIT=$?

TESTS_RUN=$((TESTS_RUN + 1))
if [[ "${EUID}" -eq 0 ]]; then
    # As root: the override must be ignored and the bundled locales used instead.
    if [[ "${LOCALE_EXIT}" -eq 0 ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        printf '%b  PASS%b TM_EXCLUSIONS_LOCALES_DIR is ignored when running as root\n' "$GREEN" "$NC"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        printf '%b  FAIL%b TM_EXCLUSIONS_LOCALES_DIR should be ignored as root (exit: %s)\n' "$RED" "$NC" "${LOCALE_EXIT}"
    fi
else
    if [[ "${LOCALE_EXIT}" -ne 0 ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        printf '%b  PASS%b TM_EXCLUSIONS_LOCALES_DIR=/nonexistent exits non-zero\n' "$GREEN" "$NC"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        printf '%b  FAIL%b TM_EXCLUSIONS_LOCALES_DIR=/nonexistent should exit non-zero\n' "$RED" "$NC"
    fi
fi

TESTS_RUN=$((TESTS_RUN + 1))
if [[ "${EUID}" -eq 0 ]]; then
    if [[ -z "${LOCALE_MISSING_STDERR}" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        printf '%b  PASS%b ignored override as root produces no locale error\n' "$GREEN" "$NC"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        printf '%b  FAIL%b ignored override as root should be silent (got: %s)\n' "$RED" "$NC" "${LOCALE_MISSING_STDERR}"
    fi
elif grep -q "locale files not found" <<<"${LOCALE_MISSING_STDERR}"; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '%b  PASS%b missing locales dir prints clear error to stderr\n' "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '%b  FAIL%b missing locales dir should print clear error to stderr (got: %s)\n' "$RED" "$NC" "${LOCALE_MISSING_STDERR}"
fi

# Test: TM_EXCLUSIONS_LOCALES_DIR=<repo>/locales explicitly (env-var override works)
REPO_LOCALES_DIR="${SCRIPT_DIR}/locales"
assert_exit_code 0 \
    "TM_EXCLUSIONS_LOCALES_DIR=<repo>/locales --lang en --help exits 0" \
    env TM_EXCLUSIONS_LOCALES_DIR="${REPO_LOCALES_DIR}" bash "$TM_EXCLUSIONS" --lang en --help

assert_output_contains "Usage:" \
    "TM_EXCLUSIONS_LOCALES_DIR env-var override loads English locale" \
    env TM_EXCLUSIONS_LOCALES_DIR="${REPO_LOCALES_DIR}" bash "$TM_EXCLUSIONS" --lang en --help

assert_exit_code 0 \
    "TM_EXCLUSIONS_LOCALES_DIR=<repo>/locales --lang fr --help exits 0" \
    env TM_EXCLUSIONS_LOCALES_DIR="${REPO_LOCALES_DIR}" bash "$TM_EXCLUSIONS" --lang fr --help

assert_output_contains "Utilisation" \
    "TM_EXCLUSIONS_LOCALES_DIR env-var override loads French locale" \
    env TM_EXCLUSIONS_LOCALES_DIR="${REPO_LOCALES_DIR}" bash "$TM_EXCLUSIONS" --lang fr --help
# ---- Temporary file cleanup and signal trap ----
echo ""
echo "--- Temporary file cleanup and signal trap ---"

CLEANUP_DIR="$(mktemp -d "${TEST_HOME}/cleanup-test.XXXXXX")"
TMP_HOLD="${CLEANUP_DIR}/tmp"
mkdir -p "${TMP_HOLD}"

# Normal run leaves no temp files in TMPDIR
env TMPDIR="${TMP_HOLD}" bash "$TM_EXCLUSIONS" --verbose --dry-run >/dev/null 2>&1
REMAINING_TMP=$(find "${TMP_HOLD}" -name 'tm_exc_*' 2>/dev/null | wc -l | tr -d ' ')
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "${REMAINING_TMP}" -eq 0 ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '%b  PASS%b no temp files leaked in TMPDIR after normal run\n' "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '%b  FAIL%b %d temp files leaked in TMPDIR after normal run\n' "$RED" "$NC" "${REMAINING_TMP}"
fi

# Signal trap (SIGTERM) removes registered temp files and terminates
SIG_TMP_FILE="${TMP_HOLD}/tm_exc_signal_test.tmp"
touch "${SIG_TMP_FILE}"

# The handler must re-raise SIGTERM after cleanup (POSIX exit status 128+15=143),
# not just remove the temp file, so a re-raise regression is caught even though
# the file-removal path alone would still pass.
# Exit 143 is also what an unarmed `kill -TERM` yields, so the handler functions
# are loaded from a file and verified (exit 97 if missing) before the signal.
SIG_FUNCS="${TEST_HOME}/signal_functions.sh"
sed -n \
    -e "/^sudo_keepalive_stop()/,/^}/p" \
    -e "/^register_tmp_file()/,/^}/p" \
    -e "/^cleanup_tmp_files()/,/^}/p" \
    -e "/^clear_progress()/,/^}/p" \
    -e "/^cleanup()/,/^}/p" \
    -e "/^on_signal()/,/^}/p" \
    "$TM_EXCLUSIONS" > "$SIG_FUNCS"
# shellcheck disable=SC2016
assert_exit_code 143 "signal handler re-raises SIGTERM (exit 143)" \
    bash -c '
source "$1"
declare -F register_tmp_file cleanup on_signal >/dev/null || exit 97
TMP_FILES=""
UI_PROGRESS=0
register_tmp_file "$2"
trap "cleanup" EXIT
trap "on_signal TERM" TERM
kill -TERM $$
exit 0 # not the last command of `bash -c`: Bash 3.2 then exits 0 instead of 143
' _ "${SIG_FUNCS}" "${SIG_TMP_FILE}"

TESTS_RUN=$((TESTS_RUN + 1))
if [[ ! -e "${SIG_TMP_FILE}" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '%b  PASS%b signal handler removes registered temp files on SIGTERM\n' "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '%b  FAIL%b registered temp file was not cleaned up on SIGTERM\n' "$RED" "$NC"
fi

rm -rf "${CLEANUP_DIR}"
# ---- Auto-prune .bak / .old shadow copies (#25) ----
echo ""
echo "--- Auto-prune .bak/.old shadow copies (#25) ---"

BAK_HOME="$(mktemp -d "${TEST_HOME}/bak-test.XXXXXX")"
# Fake catalog tool directory and its .bak shadow copy with a matchable sub-path
mkdir -p "${BAK_HOME}/.faketool"
mkdir -p "${BAK_HOME}/.faketool.bak/install/cache/dist"
# An unrelated .bak tree that has NO matching catalog path|~/random entry
mkdir -p "${BAK_HOME}/random.bak/some/dist"
BAK_CONF="${BAK_HOME}/bak-test.conf"
cat > "${BAK_CONF}" << EOF
path|${BAK_HOME}/.faketool|Fake tool directory
pattern|dist|dist directories
EOF

BAK_OUT="$(env HOME="${BAK_HOME}" \
               TM_EXCLUSIONS_DEFAULT_CONF="${BAK_CONF}" \
               bash "$TM_EXCLUSIONS" --verbose --dry-run 2>&1 || true)"

# Test A (positive): .faketool itself must be processed as a static path
BAK_STATIC_HITS=$(printf '%s\n' "${BAK_OUT}" | grep -cE "(Applying exclusion:|Already excluded:|DRY-RUN.*Applying exclusion:|\[DRY-RUN\]).*\.faketool$" || true)
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "${BAK_STATIC_HITS}" -ge 1 ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '%b  PASS%b .faketool static path is processed\n' "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '%b  FAIL%b .faketool static path was not processed (got %d hits)\n' "$RED" "$NC" "${BAK_STATIC_HITS}"
fi

# Test B (negative): .faketool.bak/install/cache/dist must NOT appear as an exclusion
BAK_SHADOW_HITS=$(printf '%s\n' "${BAK_OUT}" | grep -cE "(Applying exclusion:|Already excluded:).*\.faketool\.bak" || true)
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "${BAK_SHADOW_HITS}" -eq 0 ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '%b  PASS%b .faketool.bak shadow copy is pruned (not excluded)\n' "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '%b  FAIL%b .faketool.bak shadow copy was excluded (%d hit(s))\n' "$RED" "$NC" "${BAK_SHADOW_HITS}"
fi

# Test C: random.bak/some/dist (no catalog entry for ~/random) IS processed normally
BAK_RANDOM_HITS=$(printf '%s\n' "${BAK_OUT}" | grep -cE "(Applying exclusion:|Already excluded:).*random\.bak/some/dist$" || true)
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "${BAK_RANDOM_HITS}" -ge 1 ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '%b  PASS%b random.bak (no catalog entry) is still scanned normally\n' "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '%b  FAIL%b random.bak should be scanned normally (got %d hits)\n' "$RED" "$NC" "${BAK_RANDOM_HITS}"
fi

rm -rf "${BAK_HOME}"

# ---- Selective Application Support caches (#53) ----
echo ""
echo "--- Application Support caches (#53) ---"

# Path globs expand to concrete directories; unmatched globs are dropped.
GLOB_HOME="$(mktemp -d)"
mkdir -p "${GLOB_HOME}/Library/Application Support/FakeIDE/v1/plugins"
mkdir -p "${GLOB_HOME}/Library/Application Support/FakeIDE/v2/plugins"
mkdir -p "${GLOB_HOME}/Library/Application Support/FakeIDE/v1/options"
GLOB_CONF="${GLOB_HOME}/glob-default.conf"
cat > "${GLOB_CONF}" << 'EOF'
path|$HOME/Library/Application Support/FakeIDE/*/plugins|glob expansion smoke
EOF
GLOB_OUT="$(env HOME="${GLOB_HOME}" \
    TM_EXCLUSIONS_DEFAULT_CONF="${GLOB_CONF}" \
    bash "$TM_EXCLUSIONS" --verbose --dry-run 2>&1)" || true

assert_output_contains "${GLOB_HOME}/Library/Application Support/FakeIDE/v1/plugins" \
    "path glob expands JetBrains-style */plugins (v1)" \
    env HOME="${GLOB_HOME}" TM_EXCLUSIONS_DEFAULT_CONF="${GLOB_CONF}" \
    bash "$TM_EXCLUSIONS" --verbose --dry-run

assert_output_contains "${GLOB_HOME}/Library/Application Support/FakeIDE/v2/plugins" \
    "path glob expands JetBrains-style */plugins (v2)" \
    env HOME="${GLOB_HOME}" TM_EXCLUSIONS_DEFAULT_CONF="${GLOB_CONF}" \
    bash "$TM_EXCLUSIONS" --verbose --dry-run

TESTS_RUN=$((TESTS_RUN + 1))
if grep -Fq "WOULD ${GLOB_HOME}/Library/Application Support/FakeIDE/*/plugins" <<<"${GLOB_OUT}"; then
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '%b  FAIL%b unmatched/literal path glob leaked to output\n' "$RED" "$NC"
else
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '%b  PASS%b path glob does not leak a literal */plugins target\n' "$GREEN" "$NC"
fi

TESTS_RUN=$((TESTS_RUN + 1))
if grep -Fq "WOULD ${GLOB_HOME}/Library/Application Support/FakeIDE/v1/options [" <<<"${GLOB_OUT}"; then
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '%b  FAIL%b glob must not exclude sibling options/ (user settings)\n' "$RED" "$NC"
else
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '%b  PASS%b path glob does not exclude sibling options/ settings\n' "$GREEN" "$NC"
fi
rm -rf "${GLOB_HOME}"

# Default catalog: exclude known regenerable subdirs, keep settings/tokens.
AS_HOME="$(mktemp -d)"
mkdir -p "${AS_HOME}/Library/Application Support/Cursor/User/workspaceStorage"
mkdir -p "${AS_HOME}/Library/Application Support/Cursor/Cache"
printf '%s\n' '{}' > "${AS_HOME}/Library/Application Support/Cursor/User/settings.json"
mkdir -p "${AS_HOME}/Library/Application Support/JetBrains/IntelliJIdea2024.3/plugins"
mkdir -p "${AS_HOME}/Library/Application Support/JetBrains/IntelliJIdea2024.3/options"
mkdir -p "${AS_HOME}/Library/Application Support/Zed/languages"
mkdir -p "${AS_HOME}/Library/Application Support/discord/Cache"
mkdir -p "${AS_HOME}/Library/Application Support/auto-claude-ui/.venv"
mkdir -p "${AS_HOME}/Library/Application Support/auto-claude-ui/python-venv"
mkdir -p "${AS_HOME}/Library/Application Support/Antigravity/Code Cache"
mkdir -p "${AS_HOME}/Library/Application Support/Antigravity/GPUCache"
mkdir -p "${AS_HOME}/Library/Application Support/Antigravity/User"
printf '%s\n' '{}' > "${AS_HOME}/Library/Application Support/Antigravity/User/settings.json"
mkdir -p "${AS_HOME}/Library/Application Support/Antigravity IDE/Code Cache"
mkdir -p "${AS_HOME}/Library/Application Support/Antigravity IDE/GPUCache"
AS_OUT="$(env HOME="${AS_HOME}" bash "$TM_EXCLUSIONS" --verbose --dry-run 2>&1)" || true

for as_path in \
    "${AS_HOME}/Library/Application Support/Cursor/Cache" \
    "${AS_HOME}/Library/Application Support/JetBrains/IntelliJIdea2024.3/plugins" \
    "${AS_HOME}/Library/Application Support/Zed/languages" \
    "${AS_HOME}/Library/Application Support/discord/Cache" \
    "${AS_HOME}/Library/Application Support/auto-claude-ui/.venv" \
    "${AS_HOME}/Library/Application Support/auto-claude-ui/python-venv" \
    "${AS_HOME}/Library/Application Support/Antigravity/Code Cache" \
    "${AS_HOME}/Library/Application Support/Antigravity/GPUCache" \
    "${AS_HOME}/Library/Application Support/Antigravity IDE/Code Cache" \
    "${AS_HOME}/Library/Application Support/Antigravity IDE/GPUCache"
do
    TESTS_RUN=$((TESTS_RUN + 1))
    if grep -Fq "WOULD ${as_path} [" <<< "${AS_OUT}"; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        printf '%b  PASS%b dry-run would exclude %s\n' "$GREEN" "$NC" "${as_path#"${AS_HOME}"/}"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        printf '%b  FAIL%b dry-run did not exclude %s\n' "$RED" "$NC" "${as_path#"${AS_HOME}"/}"
    fi
done

for as_keep in \
    "${AS_HOME}/Library/Application Support/Cursor/User/workspaceStorage" \
    "${AS_HOME}/Library/Application Support/Cursor" \
    "${AS_HOME}/Library/Application Support/Cursor/User" \
    "${AS_HOME}/Library/Application Support/Cursor/User/settings.json" \
    "${AS_HOME}/Library/Application Support/JetBrains/IntelliJIdea2024.3/options" \
    "${AS_HOME}/Library/Application Support/discord" \
    "${AS_HOME}/Library/Application Support/auto-claude-ui" \
    "${AS_HOME}/Library/Application Support/Zed" \
    "${AS_HOME}/Library/Application Support/Antigravity" \
    "${AS_HOME}/Library/Application Support/Antigravity/User" \
    "${AS_HOME}/Library/Application Support/Antigravity/User/settings.json" \
    "${AS_HOME}/Library/Application Support/Antigravity IDE"
do
    TESTS_RUN=$((TESTS_RUN + 1))
    if grep -Fq "WOULD ${as_keep} [" <<< "${AS_OUT}"; then
        TESTS_FAILED=$((TESTS_FAILED + 1))
        printf '%b  FAIL%b must not exclude settings/parent path %s\n' "$RED" "$NC" "${as_keep#"${AS_HOME}"/}"
    else
        TESTS_PASSED=$((TESTS_PASSED + 1))
        printf '%b  PASS%b keeps settings/parent %s\n' "$GREEN" "$NC" "${as_keep#"${AS_HOME}"/}"
    fi
done
rm -rf "${AS_HOME}"

# ---- Terminal presentation (no Time Machine operations) ----
# Source definitions only, then exercise the same renderer used by the CLI.
# shellcheck disable=SC2016
assert_exit_code 0 "terminal progress, plain logs, quiet and bilingual summary" \
    bash -c '
set -euo pipefail
source "$1"
declare -F progress_start ui_summary >/dev/null
source "$2/locales/en.sh"
declare_i18n_en
init_ui
[[ "$UI" -eq 0 ]] # redirected stdout must stay plain
UI=1
UI_CYAN=$(printf "\033[36m")
UI_RESET=$(printf "\033[0m")
UI_HEADING=$(printf "\033[1;35m")
ui_section "📁" "Section" > "$3/heading"
ui_category "Category" >> "$3/heading"
grep -Fq "$UI_HEADING  ━━ 📁  Section$UI_RESET" "$3/heading"
grep -Fq "${UI_HEADING}══ Category ══$UI_RESET" "$3/heading"
progress_start "$(printf "one\ntwo")" > "$3/progress"
progress_step >> "$3/progress"
start_activity "Measuring" > "$3/counted-activity"
sleep 2
clear_progress >/dev/null
grep -Eq "50%  1/2.*Measuring.*[1-9]s" "$3/counted-activity"
SCAN_COLUMNS=22
progress_draw >/dev/null
start_activity "Measuring directory" > "$3/narrow"
sleep 2
clear_progress >/dev/null
grep -Eq "50%.*[1-9]s .*ry" "$3/narrow"
SCAN_COLUMNS=80
progress_step >> "$3/progress"
grep -q "100%  2/2" "$3/progress"
[[ "$UI_PROGRESS" -eq 0 ]]
progress_start "" > "$3/empty"
[[ ! -s "$3/empty" ]]
exec 5>"$3/debug"
DEBUG_LOG_FD=1
log_info "literal %s \\ path" > "$3/styled"
[[ "$(cat "$3/debug")" = "literal %s \\ path" ]]
[[ "$(cat "$3/styled")" == *"$UI_RESET"* ]]
QUIET=1
log_info "hidden" > "$3/quiet"
[[ ! -s "$3/quiet" ]]
QUIET=0
ui_summary "$MSG_REPORT_WOULD_EXCLUDE" > "$3/summary"
grep -q "Summary" "$3/summary"
source "$2/locales/fr.sh"
declare_i18n_fr
ui_summary "$MSG_REPORT_WOULD_EXCLUDE" > "$3/summary"
grep -q "Bilan" "$3/summary"
' _ "$TM_FUNCS" "$SCRIPT_DIR" "$TEST_HOME"

# ---- Live discovery: same traversal and candidates, single-line status ----
# shellcheck disable=SC2016
assert_exit_code 0 "live discovery preserves candidates, pruning and cap" \
    bash -c 'set -euo pipefail
source "$1"
declare -F collect_post_scan_paths >/dev/null
source "$2/locales/en.sh"
declare_i18n_en
CONF_SCAN_IMAGES=1
HOME="$3/discovery"
mkdir -p "$HOME/cache" "$HOME/project with spaces/subdir" \
    "$HOME/disk.sparsebundle/hidden.sparsebundle" \
    "$HOME/Library/Mobile Documents/cloud.sparsebundle"
dd if=/dev/zero of="$HOME/large.img" bs=1 count=0 seek=537919488 2>/dev/null
touch "$HOME/small.img"
brew() { printf "%s\n" "$HOME/cache"; }
tput() { printf "60\n"; }
collect_post_scan_paths > "$3/plain-discovery"
[[ ! -s "$3/plain-discovery" ]]
expected="$EXTRA_PATHS"
[[ "$expected" == *"$HOME/large.img"* && "$expected" == *"$HOME/disk.sparsebundle"* ]]
[[ "$expected" != *hidden* && "$expected" != *cloud* && "$expected" != *small.img* ]]
UI=1
collect_post_scan_paths > "$3/live-discovery"
[[ "$EXTRA_PATHS" = "$expected" && "$UI_PROGRESS" -eq 0 ]]
grep -q "project with spaces/subdir" "$3/live-discovery"
[[ "$(wc -l < "$3/live-discovery" | tr -d " ")" = 0 ]]
printf "%s\n" "$HOME/repo/node_modules" > "$3/scan-results"
start_activity "$MSG_SCANNING" "$HOME" "$3/scan-results" > "$3/activity"
sleep 2
clear_progress > /dev/null
[[ -z "$UI_ACTIVITY_PID" && "$UI_PROGRESS" -eq 0 ]]
grep -q "Last match ~/repo/node_modules" "$3/activity"
grep -Eq "[1-9][0-9]*s" "$3/activity"
UI=0
start_activity "$MSG_UI_MEASURE" > "$3/activity-plain"
[[ ! -s "$3/activity-plain" && -z "$UI_ACTIVITY_PID" ]]
UI=1
SCAN_COLUMNS=22
show_scan_path "$HOME/repo/node_modules" "1s · Last match " "1s " > "$3/narrow-match"
grep -q "1s .*ules" "$3/narrow-match"
SCAN_COLUMNS=15
show_scan_path "$HOME/repo/node_modules" "1s · Last match " "1s " > "$3/tiny-match"
grep -q "1s" "$3/tiny-match"
SCAN_COLUMNS=30
show_scan_path "$HOME/a very long directory name/with-tail" > "$3/short-discovery"
grep -q "with-tail" "$3/short-discovery"
frame=$(cat "$3/short-discovery")
begin=$(printf "\r\033[2K\033[?7l")
end=$(printf "\r\033[?7h")
[[ "$frame" == "$begin"*"$end" ]]
visible=${frame#"$begin"}
visible=${visible%"$end"}
[[ ${#visible} -lt 30 ]]
clear_progress > /dev/null
UI=0
for ((i=0; i<55; i++)); do mkdir "$HOME/image-$i.sparsebundle"; done
collect_post_scan_paths > "$3/plain-discovery"
[[ "$(printf "%s\n" "$EXTRA_PATHS" | wc -l | tr -d " ")" = 51 ]]
[[ ! -s "$3/plain-discovery" ]]
' _ "$TM_FUNCS" "$SCRIPT_DIR" "$TEST_HOME"

# ---- Grouped console output (#24) ----
echo ""
echo "--- Grouped console output (#24) ---"
BATCH_HOME="$TEST_HOME/batch-home"
BATCH_BIN="$TEST_HOME/batch-bin"
mkdir -p "$BATCH_HOME/.config/tm_exclusions" "$BATCH_BIN" \
    "$BATCH_HOME/Git/repo one/packages/a/node_modules" \
    "$BATCH_HOME/Git/repo one/packages/b/node_modules" \
    "$BATCH_HOME/Git/repo-extra/node_modules" \
    "$BATCH_HOME/.tool/a/dist" "$BATCH_HOME/.tool/b/dist" \
    "$BATCH_HOME/.tool/pruned/a/dist" "$BATCH_HOME/.tool/pruned/b/dist" \
    "$BATCH_HOME/.tool/pruned2/a/dist" \
    "$BATCH_HOME/already/cache"
: > "$BATCH_HOME/.config/tm_exclusions/custom.conf"
cat > "$BATCH_HOME/rules" <<'CONF'
path|$HOME/missing-one|missing cache one
path|$HOME/missing-two|missing cache two
path|$HOME/already/cache|existing exclusion
pattern|node_modules|dependencies
pattern|dist|build output
prune|$HOME/.tool/pruned|skip archived build output
prune|$HOME/.tool/pruned2|skip second archived build output
CONF
cat > "$BATCH_BIN/tmutil" <<'STUB'
#!/bin/sh
case "$1" in
    isexcluded)
        [ "${BATCH_STATUS_FAIL:-0}" != 1 ] || exit 1
        case "$2" in
            */already/cache) printf '[Excluded] %s\n' "$2" ;;
            *) printf '[Included] %s\n' "$2" ;;
        esac ;;
esac
exit 0
STUB
cat > "$BATCH_BIN/sudo" <<'STUB'
#!/bin/sh
touch "$HOME/sudo-called"
exit 1
STUB
chmod +x "$BATCH_BIN/"*
BATCH_ENV=(env HOME="$BATCH_HOME" PATH="$BATCH_BIN:$PATH"
    TM_EXCLUSIONS_DEFAULT_CONF="$BATCH_HOME/rules"
    TM_EXCLUSIONS_REPORT="$BATCH_HOME/report" TM_EXCLUSIONS_SKIP_DU=1)

batch_run() {
    local rc=0 out="$1"
    shift
    "${BATCH_ENV[@]}" bash "$TM_EXCLUSIONS" "$@" > "$out" 2>&1 || rc=$?
    assert_eq 0 "$rc" "batch CLI exits 0: $*"
}

batch_run "$BATCH_HOME/default" --dry-run
assert_file_contains "$BATCH_HOME/default" \
    "$BATCH_HOME/Git/repo one → [DRY-RUN] Would exclude: 2" \
    "workspace matches collapse into one natural-root summary"
assert_file_contains "$BATCH_HOME/default" \
    "$BATCH_HOME/Git/repo-extra → [DRY-RUN] Would exclude: 1" \
    "similarly named repositories remain separate groups"
assert_file_contains "$BATCH_HOME/default" \
    "$BATCH_HOME/.tool → [DRY-RUN] Would exclude: 2" \
    "hidden-tool matches collapse into one root summary"
assert_file_contains "$BATCH_HOME/default" "$BATCH_HOME/.tool → Pruned: 2" \
    "prune matches collapse into one counter per root"
assert_file_contains "$BATCH_HOME/default" 'Missing paths: 2 (paths: -v)' \
    "missing static paths collapse into one counter"
assert_file_contains "$BATCH_HOME/default" 'Already excluded: 1 (paths: -v)' \
    "already-excluded paths are counted without per-path noise"
assert_file_lacks_regex "$BATCH_HOME/default" \
    'packages/[ab]/node_modules|missing-(one|two)|already/cache|pruned/[ab]/dist|^Details:' \
    "default stdout does not leak detailed paths through the report"
assert_eq 1 "$(grep -Fc "$BATCH_HOME/Git/repo one →" "$BATCH_HOME/default")" \
    "one line represents all matches for a repository"
assert_file_contains "$BATCH_HOME/report" \
    "WOULD $BATCH_HOME/Git/repo one/packages/a/node_modules" \
    "saved report retains individual exclusions"
assert_file_contains "$BATCH_HOME/report" "SKIP  $BATCH_HOME/missing-one (not found)" \
    "saved report retains missing static paths"
assert_file_contains "$BATCH_HOME/report" "SKIP  $BATCH_HOME/.tool/pruned (" \
    "saved report retains one prune decision per zone (#13: nested matches are no longer visited)"
assert_file_contains "$BATCH_HOME/report" "OK    $BATCH_HOME/already/cache" \
    "saved report retains already-excluded paths"
sed '/^Date:/d' "$BATCH_HOME/report" > "$BATCH_HOME/report-reference"

for BATCH_FLAG in -v --verbose; do
    batch_run "$BATCH_HOME/verbose" "$BATCH_FLAG" --dry-run
    assert_file_contains "$BATCH_HOME/verbose" \
        "[DRY-RUN] Applying exclusion: $BATCH_HOME/Git/repo one/packages/a/node_modules" \
        "$BATCH_FLAG restores individual application lines"
    assert_file_contains "$BATCH_HOME/verbose" "Path not found, skipping: $BATCH_HOME/missing-one" \
        "$BATCH_FLAG restores missing-path lines"
    assert_file_contains "$BATCH_HOME/verbose" "Already excluded: $BATCH_HOME/already/cache" \
        "$BATCH_FLAG restores already-excluded lines"
    assert_file_contains "$BATCH_HOME/verbose" "Pruning (skipping scan of): $BATCH_HOME/.tool/pruned" \
        "$BATCH_FLAG restores individual prune lines (one per zone, #13)"
    assert_file_lacks_regex "$BATCH_HOME/verbose" ' → ' "$BATCH_FLAG emits no grouped lines"
    sed '/^Date:/d' "$BATCH_HOME/report" > "$BATCH_HOME/report-current"
    assert_true "$BATCH_FLAG leaves saved report identical" \
        cmp -s "$BATCH_HOME/report-reference" "$BATCH_HOME/report-current"
done

batch_run "$BATCH_HOME/quiet" --quiet --dry-run
assert_file_lacks_regex "$BATCH_HOME/quiet" \
    '^  (Applying exclusion:|Path not found, skipping:|Pruning \(skipping scan of\):)| → ' \
    "quiet output suppresses both progress details and grouped lines"
sed '/^Date:/d' "$BATCH_HOME/report" > "$BATCH_HOME/report-current"
assert_true "quiet keeps the same full saved report" \
    cmp -s "$BATCH_HOME/report-reference" "$BATCH_HOME/report-current"
assert_file_contains "$BATCH_HOME/quiet" \
    "WOULD $BATCH_HOME/Git/repo one/packages/a/node_modules" \
    "quiet stdout still includes the full report"
batch_run "$BATCH_HOME/quiet-verbose" --verbose --quiet --dry-run
assert_file_lacks_regex "$BATCH_HOME/quiet-verbose" 'Applying exclusion:| → ' \
    "quiet takes precedence over verbose"

batch_run "$BATCH_HOME/french" --lang fr --dry-run
assert_file_contains "$BATCH_HOME/french" \
    "$BATCH_HOME/Git/repo one → [SIMULATION] Seraient exclus : 2" \
    "root summaries are localized in French"
assert_file_contains "$BATCH_HOME/french" 'Chemins absents : 2 (chemins : -v)' \
    "missing-path summary is localized in French"
batch_run "$BATCH_HOME/audit" --report-only
assert_file_contains "$BATCH_HOME/audit" \
    "$BATCH_HOME/Git/repo one → Paths not yet excluded (action needed): 2" \
    "report-only summarizes needed exclusions without simulation labels"
batch_run "$BATCH_HOME/apply"
assert_file_contains "$BATCH_HOME/apply" \
    "$BATCH_HOME/Git/repo one → Newly excluded: 2" \
    "apply mode summarizes successfully applied exclusions"

# A failed report save must not strand details behind an unusable file path.
touch "$BATCH_HOME/blocked"
BATCH_RC=0
"${BATCH_ENV[@]}" TM_EXCLUSIONS_REPORT="$BATCH_HOME/blocked/report" \
    bash "$TM_EXCLUSIONS" --dry-run > "$BATCH_HOME/write-fail-out" \
    2> "$BATCH_HOME/write-fail-err" || BATCH_RC=$?
assert_eq 1 "$BATCH_RC" "failed report save still exits nonzero"
assert_file_contains "$BATCH_HOME/write-fail-out" \
    "WOULD $BATCH_HOME/Git/repo one/packages/a/node_modules" \
    "failed report save falls back to full details on stdout"
assert_file_contains "$BATCH_HOME/write-fail-err" 'Could not save report to:' \
    "failed report save remains individually visible"

# Actionable errors stay on stderr even while ordinary output is grouped.
BATCH_RC=0
"${BATCH_ENV[@]}" BATCH_STATUS_FAIL=1 bash "$TM_EXCLUSIONS" --dry-run \
    > "$BATCH_HOME/errors-out" 2> "$BATCH_HOME/errors-err" || BATCH_RC=$?
assert_eq 1 "$BATCH_RC" "grouped status failures still exit nonzero"
assert_file_contains "$BATCH_HOME/errors-err" \
    "Unable to determine Time Machine exclusion status: $BATCH_HOME/already/cache" \
    "grouping keeps actionable errors on stderr"
# A sibling of the temporary HOME exercises system-path handling on every OS.
system_cache="$TEST_HOME/system-cache"
mkdir -p "$system_cache"
printf 'path|%s|system cache\n' "$system_cache" >> "$BATCH_HOME/rules"
for mode in --dry-run --report-only; do
    batch_run "$BATCH_HOME/system-out" "$mode" </dev/null
    case "$mode" in --dry-run) result=WOULD ;; --report-only) result="NEED " ;; esac
    assert_file_contains "$BATCH_HOME/report" "$result $system_cache" "system path is inspected in $mode"
    assert_true "$mode never invokes sudo" test ! -e "$BATCH_HOME/sudo-called"
done
BATCH_RC=0
"${BATCH_ENV[@]}" bash "$TM_EXCLUSIONS" \
    < /dev/null > "$BATCH_HOME/system-out" 2> "$BATCH_HOME/system-err" || BATCH_RC=$?
assert_eq 1 "$BATCH_RC" "system writes without privileges still exit nonzero"
assert_file_contains "$BATCH_HOME/system-err" \
    "Skipping (non-interactive / no sudo cache) for system path: $system_cache" \
    "grouping keeps system-path skips individually visible"

# ---- Summary ----
test_summary
