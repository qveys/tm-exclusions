#!/usr/bin/env bash
# test_apps_inventory.sh — Installed applications inventory with disk sizes (issue #47).
#
# Covers list_app_bundles() / build_apps_inventory() and their integration in
# the report: apps in both /Applications-style and ~/Applications-style roots,
# empty and missing roots, names with spaces and newlines, symbolic-link apps
# (sized as their target, never 0B), the two-level depth limit, the single
# `du -sh -H` pass and TM_EXCLUSIONS_SKIP_INVENTORY=1. Everything runs
# against a mktemp -d fake tree, a fake HOME and a fake `du` in PATH: no real
# /Applications content is required and no real du ever walks an app.
set -euo pipefail

APPS_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/test_helpers.sh
source "${APPS_TEST_DIR}/test_helpers.sh"

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
export HOME="$TEST_DIR/home"
export LANG=C LC_ALL=C
export TM_EXCLUSIONS_SKIP_DU=1
export TM_EXCLUSIONS_REPORT="$TEST_DIR/report"
export DU_CALLS="$TEST_DIR/du_calls"
export DU_ARGS="$TEST_DIR/du_args"
unset TM_EXCLUSIONS_SKIP_INVENTORY TM_EXCLUSIONS_EXTRA_CONF TM_EXCLUSIONS_REPORT_DESKTOP
unset TM_EXCLUSIONS_LOCALES_DIR TM_EXCLUSIONS_DEFAULT_CONF
mkdir -p "$HOME/.config/tm_exclusions" "$TEST_DIR/bin"
: > "$DU_CALLS"
: > "$DU_ARGS"

# Fake du: one "<size>\t<path>" line per path argument, one log line per call
# (DU_CALLS) and every path argument NUL-terminated in DU_ARGS. A path
# containing "Unreadable" yields no line, like a permission-denied du. Like the
# real du, a symbolic link is measured as 0B unless -H is given, in which case
# it is measured as its target (34M here; real bundles are 42M). A path
# containing "Partial" prints a PARTIAL total (7M) and makes du exit 1, like an
# app with an unreadable subdirectory.
cat > "$TEST_DIR/bin/du" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" | tr '\n' '~' >> "$DU_CALLS"
printf '\n' >> "$DU_CALLS"
h=0
rc=0
for a in "$@"; do
    [ "$a" = "-H" ] && h=1
done
for a in "$@"; do
    case "$a" in
        -*) continue ;;
    esac
    printf '%s\0' "$a" >> "$DU_ARGS"
    case "$a" in
        *Unreadable*) continue ;;
        *Partial*) printf '7M\t%s\n' "$a"; rc=1; continue ;;
    esac
    if [ -L "$a" ]; then
        if [ "$h" = 1 ]; then printf '34M\t%s\n' "$a"; else printf '0B\t%s\n' "$a"; fi
    else
        printf '42M\t%s\n' "$a"
    fi
done
exit "$rc"
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
export PATH="$TEST_DIR/bin:$PATH"

# Fake application trees (never the real /Applications).
SYS="$TEST_DIR/sys_apps"
USR="$HOME/Applications"
mkdir -p "$SYS/Alpha.app/Contents/Helper.app" \
         "$SYS/My Great App.app/Contents" \
         "$SYS/Utilities/Tool.app" \
         "$SYS/Utilities/Deep/Too Deep.app" \
         "$SYS/Unreadable.app" \
         "$SYS/PlainFolder" \
         "$USR/Mine.app" \
         "$USR/Sub Folder/Nested One.app" \
         "$TEST_DIR/cryptex/Safari.app" \
         "$TEST_DIR/cryptex/Feedback Assistant.app" \
         "$TEST_DIR/linked_dir/Inside.app" \
         "$TEST_DIR/user_cryptex/Linked Mine.app"
: > "$SYS/notes.txt"
# Symbolic links, as on recent macOS (Safari.app -> cryptex volume).
ln -s "$TEST_DIR/cryptex/Safari.app" "$SYS/Safari.app"
ln -s "$TEST_DIR/cryptex/Feedback Assistant.app" "$SYS/Utilities/Feedback Assistant.app"
ln -s "$TEST_DIR/linked_dir" "$SYS/Linked Folder"      # folder that is a link
ln -s "$TEST_DIR/user_cryptex/Linked Mine.app" "$USR/Linked Mine.app"
ln -s "$TEST_DIR/does_not_exist.app" "$SYS/Broken.app"  # broken link: ignored
ln -s "$SYS" "$SYS/Utilities/Loop"                      # loop: bounded by depth
: > "$TEST_DIR/plain_file"
ln -s "$TEST_DIR/plain_file" "$SYS/File Link.app"       # link to a file: ignored
# A file name with a newline (legal on APFS).
NL_APP="$SYS/Bad"$'\n'"Name.app"
mkdir -p "$NL_APP"
PART="$TEST_DIR/partial_apps"
mkdir -p "$PART/Good.app" "$PART/Partial Denied.app"
EMPTY="$TEST_DIR/empty_apps"
mkdir -p "$EMPTY"
MISSING="$TEST_DIR/does_not_exist"

# Load the functions only (drop the trailing `main "$@"` call). Temp file
# (removed with TEST_DIR by the EXIT trap) instead of process substitution:
# `source <(...)` returns 0 without defining anything under Bash 3.2 (macOS
# default), which would turn this whole suite into a silent false green.
sed '/^main /d' "$TM_EXCLUSIONS" > "$TEST_DIR/tm_exclusions_functions.sh"
# shellcheck disable=SC1091
source "$TEST_DIR/tm_exclusions_functions.sh"
for fn in list_app_bundles build_apps_inventory declare_i18n_en; do
    if [[ "$fn" != declare_i18n_en ]] && ! type "$fn" >/dev/null 2>&1; then
        echo "FAIL: $fn was not loaded from $TM_EXCLUSIONS (source failed silently?)" >&2
        exit 1
    fi
done
# shellcheck source=locales/en.sh
source "${ROOT}/locales/en.sh"
declare_i18n_en

du_call_count() { wc -l < "$DU_CALLS" | tr -d '[:space:]'; }

# list_app_bundles output (NUL-separated) as sorted text lines, a newline in a
# name being written as \n.
list_lines() {
    local p
    while IFS= read -r -d '' p; do
        printf '%s\n' "${p//$'\n'/\\n}"
    done < <(list_app_bundles "$@") | LC_ALL=C sort
}

# Number of NUL-terminated path arguments the fake du received.
du_arg_count() { tr -cd '\0' < "$DU_ARGS" | wc -c | tr -d '[:space:]'; }

# True when the fake du received exactly this path as one argument (called
# through assert_true, which shellcheck cannot follow).
# shellcheck disable=SC2329
du_got_arg() {
    local want="$1" a
    while IFS= read -r -d '' a; do
        [[ "$a" = "$want" ]] && return 0
    done < "$DU_ARGS"
    return 1
}

echo "apps inventory tests"
echo "========================================"

echo ""
echo "--- list_app_bundles ---"
listed="$(list_lines "$SYS" "$USR")"
expected="$(printf '%s\n' \
    "$USR/Linked Mine.app" \
    "$USR/Mine.app" \
    "$USR/Sub Folder/Nested One.app" \
    "$SYS/Alpha.app" \
    "$SYS/Bad\\nName.app" \
    "$SYS/Linked Folder/Inside.app" \
    "$SYS/My Great App.app" \
    "$SYS/Safari.app" \
    "$SYS/Unreadable.app" \
    "$SYS/Utilities/Feedback Assistant.app" \
    "$SYS/Utilities/Tool.app" | LC_ALL=C sort)"
assert_eq "$expected" "$listed" \
    "both roots: depth 1-2, spaces, symlink apps, link folder and newline name listed once each"
assert_true "depth-3 bundle is not listed" not grep -q "Too Deep" <<EOF
$listed
EOF
assert_true "helper app inside a bundle is not listed" not grep -q "Helper.app" <<EOF
$listed
EOF
assert_true "broken .app link is ignored" not grep -q "Broken.app" <<EOF
$listed
EOF
assert_true ".app link to a file is ignored" not grep -q "File Link.app" <<EOF
$listed
EOF
assert_true "symlink loop adds no entry (depth-bounded)" not grep -q "Loop" <<EOF
$listed
EOF
assert_eq "" "$(list_lines "$EMPTY")" "empty root lists nothing"
assert_eq "" "$(list_lines "$MISSING")" "missing root lists nothing"
assert_eq "$USR/Linked Mine.app
$USR/Mine.app
$USR/Sub Folder/Nested One.app" "$(list_lines "$MISSING" "$USR")" \
    "missing root is skipped, the other root is still listed"
assert_exit_code 0 "broken link does not make the listing fail" list_app_bundles "$SYS"
nl_entries="$(printf '%s\n' "$listed" | grep -c 'Name.app' || true)"
assert_eq "1" "$nl_entries" "newline in a name gives a single entry"

echo ""
echo "--- build_apps_inventory ---"
: > "$DU_CALLS"; : > "$DU_ARGS"
inv="$(build_apps_inventory "$SYS" "$USR")"
assert_eq "Installed applications (11):" "$(printf '%s\n' "$inv" | head -n 1)" \
    "header shows the right bundle count (newline name counted once)"
assert_eq "2" "$(du_call_count)" "one grouped du call plus one for the newline-named bundle"
assert_true "grouped du call uses -sh -H --" grep -q -- "^-sh -H -- " "$DU_CALLS"
assert_eq "11" "$(du_arg_count)" "du received each of the 11 bundles exactly once (newline name as a single path)"
assert_true "du received the full newline-named path as one argument" \
    du_got_arg "$NL_APP"
assert_true "du never received a fragment of the newline-named path" \
    not du_got_arg "Name.app"
assert_true "app with spaces gets its size" \
    grep -qxF "$(printf '  42M\t%s' "$SYS/My Great App.app")" <<EOF
$inv
EOF
assert_true "user app (~/Applications style) gets its size" \
    grep -qxF "$(printf '  42M\t%s' "$USR/Mine.app")" <<EOF
$inv
EOF
assert_true "depth-2 app gets its size" \
    grep -qxF "$(printf '  42M\t%s' "$USR/Sub Folder/Nested One.app")" <<EOF
$inv
EOF
assert_true "symlink app is sized as its target, not 0B" \
    grep -qxF "$(printf '  34M\t%s' "$SYS/Safari.app")" <<EOF
$inv
EOF
assert_true "symlink app in a subfolder is sized as its target" \
    grep -qxF "$(printf '  34M\t%s' "$SYS/Utilities/Feedback Assistant.app")" <<EOF
$inv
EOF
assert_true "user symlink app is sized as its target" \
    grep -qxF "$(printf '  34M\t%s' "$USR/Linked Mine.app")" <<EOF
$inv
EOF
assert_true "app inside a link folder is listed with its size" \
    grep -qxF "$(printf '  42M\t%s' "$SYS/Linked Folder/Inside.app")" <<EOF
$inv
EOF
assert_true "no entry is sized 0B" not grep -q "0B" <<EOF
$inv
EOF
assert_true "newline-named bundle: one line, escaped name, right size" \
    grep -qxF "$(printf '  42M\t%s' "$SYS/Bad\\nName.app")" <<EOF
$inv
EOF
assert_true "bundle whose size cannot be read shows -" \
    grep -qxF "$(printf '  -\t%s' "$SYS/Unreadable.app")" <<EOF
$inv
EOF

# An unreadable subdirectory: du prints a partial total and exits non-zero.
# The grouped pass failed, so each bundle is measured again on its own and the
# partial one is shown as "-" instead of its incomplete total.
: > "$DU_CALLS"; : > "$DU_ARGS"
inv_part="$(build_apps_inventory "$PART")"
assert_true "bundle with a partial du total shows -, not the partial size" \
    grep -qxF "$(printf '  -\t%s' "$PART/Partial Denied.app")" <<EOF
$inv_part
EOF
assert_true "partial total is never displayed" not grep -q "7M" <<EOF
$inv_part
EOF
assert_true "clean bundle keeps its size after the fallback" \
    grep -qxF "$(printf '  42M\t%s' "$PART/Good.app")" <<EOF
$inv_part
EOF
assert_eq "3" "$(du_call_count)" "failed grouped pass is redone once per bundle (1 + 2 calls)"

: > "$DU_CALLS"; : > "$DU_ARGS"
assert_eq "$MSG_INVENTORY_APPS_NONE" "$(build_apps_inventory "$EMPTY" "$MISSING")" \
    "empty and missing roots print the localized notice"
assert_eq "0" "$(du_call_count)" "no du call when there is nothing to measure"

source "${ROOT}/locales/fr.sh"
declare_i18n_fr
assert_true "French notice is localized" \
    grep -q "aucun bundle" <<EOF
$(build_apps_inventory "$EMPTY")
EOF
assert_true "French header is localized" \
    grep -q "^Applications installées (11):" <<EOF
$(build_apps_inventory "$SYS" "$USR")
EOF
declare_i18n_en

# CLI runs write to files, not $(...): the sudo keepalive's orphaned sleep would
# otherwise hold a capture pipe open for up to 55 s per run.
run_cli_to() {
    local out="$1"
    shift
    "$@" > "$out" 2>&1 || true
}

echo ""
echo "--- Report integration (fake HOME, fake du) ---"
: > "$DU_CALLS"; : > "$DU_ARGS"
run_cli_to "$TEST_DIR/out-en" bash "$TM_EXCLUSIONS" --verbose --report-only
assert_true "report lists the ~/Applications bundle with its size" \
    grep -qF "$(printf '42M\t%s' "$USR/Mine.app")" "$TM_EXCLUSIONS_REPORT"
assert_true "report lists a depth-2 bundle with spaces" \
    grep -qF "$(printf '42M\t%s' "$USR/Sub Folder/Nested One.app")" "$TM_EXCLUSIONS_REPORT"
assert_true "report lists a ~/Applications symlink app with its target size" \
    grep -qF "$(printf '34M\t%s' "$USR/Linked Mine.app")" "$TM_EXCLUSIONS_REPORT"
assert_true "report keeps the existing top-level count when /Applications exists" \
    bash -c "[ ! -d /Applications ] || grep -q '^/Applications (top-level): ' \"\$1\"" _ "$TM_EXCLUSIONS_REPORT"
assert_true "verbose stdout shows the applications inventory" \
    grep -qF "Mine.app" "$TEST_DIR/out-en"
assert_eq "1" "$(grep -c -- '^-sh -H -- ' "$DU_CALLS" || true)" \
    "report run uses one grouped du -sh -H call for the inventory"

: > "$DU_CALLS"; : > "$DU_ARGS"
run_cli_to "$TEST_DIR/out-fr" bash "$TM_EXCLUSIONS" --lang fr --verbose --report-only
assert_true "--lang fr report uses the localized header" \
    grep -q "Applications installées (" "$TM_EXCLUSIONS_REPORT"
assert_true "--lang fr stdout shows the applications inventory" \
    grep -qF "Mine.app" "$TEST_DIR/out-fr"

echo ""
echo "--- TM_EXCLUSIONS_SKIP_INVENTORY=1 ---"
: > "$DU_CALLS"; : > "$DU_ARGS"
TM_EXCLUSIONS_SKIP_INVENTORY=1 run_cli_to "$TEST_DIR/out-skip" bash "$TM_EXCLUSIONS" --verbose --report-only
assert_true "skipped inventory does not list applications" \
    not grep -qF "Mine.app" "$TM_EXCLUSIONS_REPORT"
assert_true "skipped inventory states it was skipped" \
    grep -q "skipped: TM_EXCLUSIONS_SKIP_INVENTORY=1" "$TM_EXCLUSIONS_REPORT"
assert_eq "0" "$(du_call_count)" "skipped inventory never calls du"

echo ""
echo "--- Missing ~/Applications ---"
rm -rf "$USR"
: > "$DU_CALLS"; : > "$DU_ARGS"
run_cli_to "$TEST_DIR/out-nousr" bash "$TM_EXCLUSIONS" --verbose --report-only
assert_true "report still generated without ~/Applications" \
    grep -q "=== Inventory (informational) ===" "$TM_EXCLUSIONS_REPORT"
assert_true "no ~/Applications entries when the folder is missing" \
    not grep -qF "$HOME/Applications" "$TM_EXCLUSIONS_REPORT"

# A suite that ran nothing must never pass.
if [[ "$TESTS_RUN" -le 0 ]]; then
    echo "FAIL: no assertion was executed" >&2
    exit 1
fi
test_summary
