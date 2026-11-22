#!/usr/bin/env bash
# test_apps_inventory.sh — Installed applications inventory with disk sizes (issue #47).
#
# Covers list_app_bundles() / build_apps_inventory() and their integration in
# the report: apps in both /Applications-style and ~/Applications-style roots,
# empty and missing roots, names with spaces, the two-level depth limit,
# the single `du -sh` pass and TM_EXCLUSIONS_SKIP_INVENTORY=1. Everything runs
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
unset TM_EXCLUSIONS_SKIP_INVENTORY TM_EXCLUSIONS_EXTRA_CONF TM_EXCLUSIONS_REPORT_DESKTOP
unset TM_EXCLUSIONS_LOCALES_DIR TM_EXCLUSIONS_DEFAULT_CONF
mkdir -p "$HOME/.config/tm_exclusions" "$TEST_DIR/bin"
: > "$DU_CALLS"

# Fake du: one "<size>\t<path>" line per path argument, one log line per call.
# A path containing "Unreadable" yields no line, like a permission-denied du.
cat > "$TEST_DIR/bin/du" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$DU_CALLS"
for a in "$@"; do
    case "$a" in
        -*) continue ;;
        *Unreadable*) continue ;;
    esac
    printf '42M\t%s\n' "$a"
done
exit 0
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
         "$USR/Sub Folder/Nested One.app"
: > "$SYS/notes.txt"
EMPTY="$TEST_DIR/empty_apps"
mkdir -p "$EMPTY"
MISSING="$TEST_DIR/does_not_exist"

# Load the functions only (drop the trailing `main "$@"` call).
# shellcheck disable=SC1090
source <(sed '/^main /d' "$TM_EXCLUSIONS")
# shellcheck source=locales/en.sh
source "${ROOT}/locales/en.sh"
declare_i18n_en

du_call_count() { wc -l < "$DU_CALLS" | tr -d '[:space:]'; }

echo "apps inventory tests"
echo "========================================"

echo ""
echo "--- list_app_bundles ---"
listed="$(list_app_bundles "$SYS" "$USR")"
expected="$(printf '%s\n' \
    "$USR/Mine.app" \
    "$USR/Sub Folder/Nested One.app" \
    "$SYS/Alpha.app" \
    "$SYS/My Great App.app" \
    "$SYS/Unreadable.app" \
    "$SYS/Utilities/Tool.app" | LC_ALL=C sort)"
assert_eq "$expected" "$listed" \
    "both roots listed: depth 1 and 2 only, spaces kept, nested/helper apps excluded"
assert_true "depth-3 bundle is not listed" not grep -q "Too Deep" <<EOF
$listed
EOF
assert_true "helper app inside a bundle is not listed" not grep -q "Helper.app" <<EOF
$listed
EOF
assert_eq "" "$(list_app_bundles "$EMPTY")" "empty root lists nothing"
assert_eq "" "$(list_app_bundles "$MISSING")" "missing root lists nothing"
assert_eq "$USR/Mine.app
$USR/Sub Folder/Nested One.app" "$(list_app_bundles "$MISSING" "$USR")" \
    "missing root is skipped, the other root is still listed"

echo ""
echo "--- build_apps_inventory ---"
: > "$DU_CALLS"
inv="$(build_apps_inventory "$SYS" "$USR")"
assert_eq "1" "$(du_call_count)" "a single du call for all bundles"
assert_eq "Installed applications (6):" "$(printf '%s\n' "$inv" | head -n 1)" \
    "header shows the bundle count"
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
assert_true "bundle whose size cannot be read shows -" \
    grep -qxF "$(printf '  -\t%s' "$SYS/Unreadable.app")" <<EOF
$inv
EOF
assert_true "du received -sh and the paths after --" \
    grep -q -- "^-sh -- " "$DU_CALLS"

: > "$DU_CALLS"
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
    grep -q "^Applications installées (6):" <<EOF
$(build_apps_inventory "$SYS" "$USR")
EOF
declare_i18n_en

echo ""
echo "--- Report integration (fake HOME, fake du) ---"
: > "$DU_CALLS"
out="$(bash "$TM_EXCLUSIONS" --verbose --report-only 2>&1 || true)"
assert_true "report lists the ~/Applications bundle with its size" \
    grep -qF "$(printf '42M\t%s' "$USR/Mine.app")" "$TM_EXCLUSIONS_REPORT"
assert_true "report lists a depth-2 bundle with spaces" \
    grep -qF "$(printf '42M\t%s' "$USR/Sub Folder/Nested One.app")" "$TM_EXCLUSIONS_REPORT"
assert_true "report keeps the existing top-level count when /Applications exists" \
    bash -c '[ ! -d /Applications ] || grep -q "^/Applications (top-level): " "$1"' _ "$TM_EXCLUSIONS_REPORT"
assert_true "verbose stdout shows the applications inventory" \
    grep -qF "Mine.app" <<EOF
$out
EOF
assert_eq "1" "$(du_call_count)" "report run uses one du -sh call for the whole inventory"

: > "$DU_CALLS"
out_fr="$(bash "$TM_EXCLUSIONS" --lang fr --verbose --report-only 2>&1 || true)"
assert_true "--lang fr report uses the localized header" \
    grep -q "Applications installées (" "$TM_EXCLUSIONS_REPORT"
assert_true "--lang fr stdout shows the applications inventory" \
    grep -qF "Mine.app" <<EOF
$out_fr
EOF

echo ""
echo "--- TM_EXCLUSIONS_SKIP_INVENTORY=1 ---"
: > "$DU_CALLS"
TM_EXCLUSIONS_SKIP_INVENTORY=1 bash "$TM_EXCLUSIONS" --verbose --report-only >/dev/null 2>&1 || true
assert_true "skipped inventory does not list applications" \
    not grep -qF "Mine.app" "$TM_EXCLUSIONS_REPORT"
assert_true "skipped inventory states it was skipped" \
    grep -q "skipped: TM_EXCLUSIONS_SKIP_INVENTORY=1" "$TM_EXCLUSIONS_REPORT"
assert_eq "0" "$(du_call_count)" "skipped inventory never calls du"

echo ""
echo "--- Missing ~/Applications ---"
rm -rf "$USR"
: > "$DU_CALLS"
bash "$TM_EXCLUSIONS" --verbose --report-only >/dev/null 2>&1 || true
assert_true "report still generated without ~/Applications" \
    grep -q "=== Inventory (informational) ===" "$TM_EXCLUSIONS_REPORT"
assert_true "no ~/Applications entries when the folder is missing" \
    not grep -qF "$HOME/Applications" "$TM_EXCLUSIONS_REPORT"

test_summary
