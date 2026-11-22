#!/usr/bin/env bash
# test_path_inventory.sh — CLI tools survey across PATH directories (issue #49).
#
# Covers list_path_dirs() / list_dir_executables() / build_path_tools_inventory()
# and their integration in the report: system directories summarised by count,
# toolchain directories listed by name, duplicate / empty / relative / missing
# PATH entries ignored, symbolic-link tools counted, non-executables and broken
# links not, names with spaces and newlines, wrapping, one pass per directory
# (find/ls never run on a PATH directory), TM_EXCLUSIONS_SKIP_INVENTORY=1 and
# --quiet. Everything runs against a mktemp -d tree: the real /usr/bin is never
# listed (the system directories are overridden through
# TM_EXCLUSIONS_SYSTEM_PATHS).
set -euo pipefail

PATHINV_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/test_helpers.sh
source "${PATHINV_TEST_DIR}/test_helpers.sh"

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
export HOME="$TEST_DIR/home"
export LANG=C LC_ALL=C
export TM_EXCLUSIONS_SKIP_DU=1
export TM_EXCLUSIONS_REPORT="$TEST_DIR/report"
export TOOL_CALLS="$TEST_DIR/tool_calls"
unset TM_EXCLUSIONS_SKIP_INVENTORY TM_EXCLUSIONS_EXTRA_CONF TM_EXCLUSIONS_REPORT_DESKTOP
unset TM_EXCLUSIONS_LOCALES_DIR TM_EXCLUSIONS_DEFAULT_CONF
mkdir -p "$HOME/.config/tm_exclusions" "$TEST_DIR/bin"
: > "$TOOL_CALLS"

# Stubs first in PATH. find and ls log every call and then run the real tool,
# so a survey that shelled out to them is caught.
REAL_FIND="$(command -v find)"
REAL_LS="$(command -v ls)"
cat > "$TEST_DIR/bin/find" <<STUB
#!/bin/sh
printf 'find %s\n' "\$*" >> "\$TOOL_CALLS"
exec "$REAL_FIND" "\$@"
STUB
cat > "$TEST_DIR/bin/ls" <<STUB
#!/bin/sh
printf 'ls %s\n' "\$*" >> "\$TOOL_CALLS"
exec "$REAL_LS" "\$@"
STUB
cat > "$TEST_DIR/bin/tmutil" <<'STUB'
#!/bin/sh
if [ "$1" = isexcluded ]; then printf '[Included] %s\n' "$2"; fi
exit 0
STUB
cat > "$TEST_DIR/bin/brew" <<'STUB'
#!/bin/sh
exit 0
STUB
cat > "$TEST_DIR/bin/sudo" <<'STUB'
#!/bin/sh
case "$1" in
    -n|-v) exit 0 ;;
    tmutil) shift; exec tmutil "$@" ;;
    *) exit 1 ;;
esac
STUB
chmod +x "$TEST_DIR/bin/"*
STUB_BIN="$TEST_DIR/bin"
BASE_PATH="/usr/bin:/bin"
export PATH="$STUB_BIN:$BASE_PATH"

# Fake system directory (counted only) and toolchain directories (listed).
SYS="$TEST_DIR/fake_sys/usr_bin"
DEV="$TEST_DIR/dev tools/bin"
DEV2="$HOME/.cargo/bin"
EMPTYDIR="$TEST_DIR/empty_bin"
OTHER="$TEST_DIR/other"
mkdir -p "$SYS" "$DEV" "$DEV2" "$EMPTYDIR" "$OTHER/real_dir" "$DEV/a_subdir"
mkexe() { : > "$1"; chmod +x "$1"; }
for n in sysone systwo systhree; do mkexe "$SYS/$n"; done
for n in node npm "my tool" zeta alpha; do mkexe "$DEV/$n"; done
mkexe "$DEV/.hidden-tool"
: > "$DEV/README.txt"                       # not executable
: > "$DEV/notes"; chmod 644 "$DEV/notes"    # not executable
ln -s "$DEV/node" "$DEV/nodejs"             # link to an executable: counted
ln -s "$DEV/does_not_exist" "$DEV/broken"   # broken link: ignored
ln -s "$OTHER/real_dir" "$DEV/dirlink"      # link to a directory: ignored
mkexe "$OTHER/outside"
ln -s "$OTHER/outside" "$DEV/outside-link"  # link to an exec elsewhere: counted
NL_TOOL="$DEV/new"$'\n'"line"
mkexe "$NL_TOOL"
mkexe "$DEV2/cargo"
mkexe "$DEV2/rustc"

# Executables in DEV: 5 plain + .hidden-tool + nodejs + outside-link + the
# newline-named one = 9.
EXPECTED_DEV=$(printf '%s\n' ".hidden-tool" "alpha" "my tool" "new\\nline" "node" "nodejs" "npm" "outside-link" "zeta")

# Load the functions only (drop the trailing `main "$@"` call). Temp file
# instead of process substitution: `source <(...)` returns 0 without defining
# anything under Bash 3.2 (macOS default), a silent false green.
sed '/^main /d' "$TM_EXCLUSIONS" > "$TEST_DIR/tm_exclusions_functions.sh"
# shellcheck disable=SC1091
source "$TEST_DIR/tm_exclusions_functions.sh"
for fn in list_path_dirs list_dir_executables build_path_tools_inventory; do
    if ! type "$fn" >/dev/null 2>&1; then
        echo "FAIL: $fn is not defined in $TM_EXCLUSIONS (feature missing or source failed silently)" >&2
        exit 1
    fi
done
# shellcheck source=locales/en.sh
source "${ROOT}/locales/en.sh"
declare_i18n_en

tool_calls_on() { grep -cF -- "$1" "$TOOL_CALLS" || true; }

# list_path_dirs output (NUL-separated) as text lines, a newline written as \n.
dir_lines() {
    local d
    while IFS= read -r -d '' d; do
        printf '%s\n' "${d//$'\n'/\\n}"
    done < <(list_path_dirs "$1")
}

echo "path inventory tests"
echo "========================================"

echo ""
echo "--- list_path_dirs ---"
NLDIR="$TEST_DIR/nl"$'\n'"dir"
mkdir -p "$NLDIR"
mkdir -p "$TEST_DIR/rel"
assert_eq "$SYS
$DEV
$DEV2" "$(dir_lines "$SYS:$DEV:$SYS:$DEV2:$DEV/")" \
    "duplicates (also with a trailing slash) are dropped, first occurrence order kept"
assert_eq "$SYS
$DEV" "$(dir_lines "$SYS:$TEST_DIR/does_not_exist:$DEV")" "missing directory is ignored"
assert_eq "$SYS
$DEV" "$(dir_lines ":$SYS::$DEV:")" "empty entries (current directory) are ignored"
assert_eq "$SYS" "$(cd "$TEST_DIR" && dir_lines "rel:.:$SYS")" "relative entries are ignored"
assert_eq "$SYS" "$(dir_lines "$SYS:$DEV/README.txt")" "a file in PATH is not a directory"
assert_eq "$TEST_DIR/nl\\ndir" "$(dir_lines "$NLDIR")" "directory name with a newline is one entry"
assert_eq "" "$(dir_lines "")" "empty PATH lists nothing"
assert_eq "" "$(dir_lines "::")" "PATH of only empty entries lists nothing"

echo ""
echo "--- list_dir_executables ---"
assert_eq "$EXPECTED_DEV" "$(list_dir_executables "$DEV")" \
    "executables, links to executables, spaces, dotfile and newline name; no plain files, broken or directory links, subdirectories"
assert_eq "" "$(list_dir_executables "$EMPTYDIR")" "empty directory lists nothing"
assert_eq "3" "$(list_dir_executables "$SYS" | wc -l | tr -d '[:space:]')" "system fake dir has 3 executables"
assert_exit_code 0 "broken link does not make the listing fail" list_dir_executables "$DEV"

echo ""
echo "--- build_path_tools_inventory ---"
export TM_EXCLUSIONS_SYSTEM_PATHS="$SYS:/usr/bin:/bin"
: > "$TOOL_CALLS"
PATH="$STUB_BIN:$SYS:$DEV:$SYS/:$DEV2:$EMPTYDIR:$TEST_DIR/does_not_exist::$BASE_PATH"
inv="$(build_path_tools_inventory 80)"
PATH="$STUB_BIN:$BASE_PATH"
assert_eq "Command-line tools on PATH:" "$(printf '%s\n' "$inv" | head -n 1)" "localized header"
assert_true "system directory is summarised by count only" \
    grep -qxF "[sys] $SYS (3 binaries — omitted)" <<EOF
$inv
EOF
assert_true "system tool names are not listed" not grep -q "sysone\|systwo\|systhree" <<EOF
$inv
EOF
assert_true "dev directory shows its executable count" \
    grep -qxF "[dev] $DEV (9 binaries):" <<EOF
$inv
EOF
assert_true "dev directory lists tool names (spaces kept)" \
    grep -qF "my tool" <<EOF
$inv
EOF
assert_true "symbolic-link tool is listed" grep -q "nodejs" <<EOF
$inv
EOF
assert_true "non-executable files are not listed" not grep -q "README.txt\|notes" <<EOF
$inv
EOF
assert_true "broken link is not listed" not grep -q "broken" <<EOF
$inv
EOF
assert_true "link to a directory is not listed" not grep -q "dirlink" <<EOF
$inv
EOF
assert_true "name with a newline is listed on one line, escaped" grep -qF 'new\nline' <<EOF
$inv
EOF
assert_true "second dev directory is listed" \
    grep -qxF "[dev] $DEV2 (2 binaries):" <<EOF
$inv
EOF
assert_true "empty directory shows a zero count and no list" \
    grep -qxF "[dev] $EMPTYDIR (0 binaries)" <<EOF
$inv
EOF
assert_eq "1" "$(printf '%s\n' "$inv" | grep -cF "$SYS " || true)" "duplicate system entry shown once"
assert_eq "1" "$(printf '%s\n' "$inv" | grep -cF "[dev] $DEV " || true)" "duplicate dev entry shown once"
assert_true "missing directory is not shown" not grep -qF "does_not_exist" <<EOF
$inv
EOF
assert_eq "0" "$(tool_calls_on "$DEV")" "no find/ls is run on a PATH directory"
assert_eq "0" "$(tool_calls_on "$SYS")" "no find/ls is run on a system directory"

# Single-binary wording and the nothing-to-show notice.
ONE="$TEST_DIR/one_bin"
mkdir -p "$ONE"; mkexe "$ONE/solo"
PATH="$STUB_BIN:$ONE:$BASE_PATH"
assert_true "singular wording for one binary" \
    grep -qxF "[dev] $ONE (1 binary):" <<EOF
$(build_path_tools_inventory 80)
EOF
PATH="::$TEST_DIR/does_not_exist"
inv_none="$(build_path_tools_inventory 80)"
PATH="$STUB_BIN:$BASE_PATH"
assert_true "no usable directory prints the localized notice" \
    grep -qF "$MSG_INVENTORY_PATH_NONE" <<EOF
$inv_none
EOF

# Wrapping: no line wider than the requested width, names never split, no
# trailing comma, every name still present.
BIG="$TEST_DIR/big_bin"
mkdir -p "$BIG"
i=0
while [[ "$i" -lt 60 ]]; do
    mkexe "$BIG/tool-number-$i"
    i=$((i + 1))
done
PATH="$STUB_BIN:$BIG:$BASE_PATH"
wrapped="$(build_path_tools_inventory 40)"
PATH="$STUB_BIN:$BASE_PATH"
assert_eq "60" "$(printf '%s\n' "$wrapped" | grep -o 'tool-number-[0-9]*' | wc -l | tr -d '[:space:]')" \
    "all 60 tool names are listed"
too_wide="$(printf '%s\n' "$wrapped" | awk '/^  / && length($0) > 40 { n++ } END { print n + 0 }')"
assert_eq "0" "$too_wide" "wrapped name lines stay within the width (indent included, header lines aside)"
assert_true "wrapped lines carry no trailing comma" not grep -qE ',$' <<EOF
$wrapped
EOF

# A directory with thousands of executables: complete listing, still no fork
# of find/ls (one shell pass).
HUGE="$TEST_DIR/huge_bin"
mkdir -p "$HUGE"
i=0
while [[ "$i" -lt 3000 ]]; do
    : > "$HUGE/t$i"
    i=$((i + 1))
done
chmod +x "$HUGE"/t*
: > "$TOOL_CALLS"
PATH="$STUB_BIN:$HUGE:$BASE_PATH"
huge_inv="$(build_path_tools_inventory 80)"
PATH="$STUB_BIN:$BASE_PATH"
assert_true "huge directory: count is exact" grep -qxF "[dev] $HUGE (3000 binaries):" <<EOF
$huge_inv
EOF
assert_eq "0" "$(tool_calls_on "$HUGE")" "huge directory: still no find/ls"

source "${ROOT}/locales/fr.sh"
declare_i18n_fr
PATH="$STUB_BIN:$SYS:$DEV:$BASE_PATH"
inv_fr="$(build_path_tools_inventory 80)"
PATH="$STUB_BIN:$BASE_PATH"
assert_true "French header is localized" grep -qxF "Outils en ligne de commande dans PATH:" <<EOF
$inv_fr
EOF
assert_true "French system summary is localized" \
    grep -qxF "[sys] $SYS (3 binaires — omis)" <<EOF
$inv_fr
EOF
declare_i18n_en

echo ""
echo "--- build_inventory_section gating ---"
: > "$TOOL_CALLS"
PATH="$STUB_BIN:$SYS:$DEV:$BASE_PATH"
QUIET=0
sec="$(build_inventory_section 0)"
assert_true "normal run includes the PATH tools survey" grep -qF "[dev] $DEV (9 binaries):" <<EOF
$sec
EOF
assert_true "normal run keeps the PATH directory count line" grep -q "^PATH: [0-9]* existing directories" <<EOF
$sec
EOF
QUIET=1
: > "$TOOL_CALLS"
sec_quiet="$(build_inventory_section 0)"
assert_true "--quiet suppresses the PATH tools survey" not grep -qF "[dev]" <<EOF
$sec_quiet
EOF
assert_true "--quiet does not list tool names" not grep -qF "my tool" <<EOF
$sec_quiet
EOF
assert_eq "0" "$(tool_calls_on "$DEV")" "--quiet: no find/ls on a PATH directory"
# QUIET is read by build_inventory_section (sourced from the script under test).
# shellcheck disable=SC2034
QUIET=0
: > "$TOOL_CALLS"
sec_skip="$(TM_EXCLUSIONS_SKIP_INVENTORY=1 build_inventory_section 0)"
assert_true "SKIP_INVENTORY=1 states it was skipped" grep -q "skipped: TM_EXCLUSIONS_SKIP_INVENTORY=1" <<EOF
$sec_skip
EOF
assert_true "SKIP_INVENTORY=1 lists no PATH tools" not grep -qF "[dev]" <<EOF
$sec_skip
EOF
assert_eq "0" "$(wc -c < "$TOOL_CALLS" | tr -d '[:space:]')" "SKIP_INVENTORY=1 runs no find/ls at all"
PATH="$STUB_BIN:$BASE_PATH"

# CLI runs write to files, not $(...): the sudo keepalive's orphaned sleep would
# otherwise hold a capture pipe open for up to 55 s per run.
run_cli_to() {
    local out="$1"
    shift
    rm -f "$TM_EXCLUSIONS_REPORT"
    "$@" > "$out" 2>&1 || true
}
CLI_PATH="$STUB_BIN:$SYS:$DEV:$DEV2:$BASE_PATH"
export TM_EXCLUSIONS_SYSTEM_PATHS="$SYS:/bin:/usr/bin:/sbin:/usr/sbin"

echo ""
echo "--- Report integration (fake HOME, fake PATH) ---"
run_cli_to "$TEST_DIR/out" env PATH="$CLI_PATH" bash "$TM_EXCLUSIONS" --verbose --report-only
assert_true "report lists the dev directory with its count" \
    grep -qxF "[dev] $DEV (9 binaries):" "$TM_EXCLUSIONS_REPORT"
assert_true "report lists the ~/.cargo/bin tools" grep -qxF "[dev] $DEV2 (2 binaries):" "$TM_EXCLUSIONS_REPORT"
assert_true "report summarises the system directory" \
    grep -qxF "[sys] $SYS (3 binaries — omitted)" "$TM_EXCLUSIONS_REPORT"
assert_true "report does not list system tool names" not grep -q "systwo" "$TM_EXCLUSIONS_REPORT"
assert_true "verbose stdout shows the PATH tools survey" grep -qF "[dev] $DEV" "$TEST_DIR/out"

run_cli_to "$TEST_DIR/out-fr" env PATH="$CLI_PATH" bash "$TM_EXCLUSIONS" --lang fr --verbose --report-only
assert_true "--lang fr report uses the localized header" \
    grep -q "^Outils en ligne de commande dans PATH:" "$TM_EXCLUSIONS_REPORT"

run_cli_to "$TEST_DIR/out-quiet" env PATH="$CLI_PATH" bash "$TM_EXCLUSIONS" --quiet --report-only
assert_true "--quiet report is still generated" grep -q "=== Inventory (informational) ===" "$TM_EXCLUSIONS_REPORT"
assert_true "--quiet report has no PATH tools survey" not grep -qF "[dev]" "$TM_EXCLUSIONS_REPORT"
assert_true "--quiet report has no PATH tools header" not grep -q "Command-line tools on PATH" "$TM_EXCLUSIONS_REPORT"

: > "$TOOL_CALLS"
TM_EXCLUSIONS_SKIP_INVENTORY=1 run_cli_to "$TEST_DIR/out-skip" env PATH="$CLI_PATH" bash "$TM_EXCLUSIONS" --verbose --report-only
assert_true "SKIP_INVENTORY=1 report has no PATH tools survey" not grep -qF "[dev]" "$TM_EXCLUSIONS_REPORT"
assert_true "SKIP_INVENTORY=1 report states it was skipped" \
    grep -q "skipped: TM_EXCLUSIONS_SKIP_INVENTORY=1" "$TM_EXCLUSIONS_REPORT"
assert_eq "0" "$(tool_calls_on "$DEV")" "no find/ls on any PATH directory across the CLI runs"

# A suite that ran nothing must never pass.
if [[ "$TESTS_RUN" -le 0 ]]; then
    echo "FAIL: no assertion was executed" >&2
    exit 1
fi
test_summary
