#!/usr/bin/env bash
# test_add_category.sh — Tests for scripts/add-category.sh (category scaffolding)
# Works on a throwaway copy of config/, locales/ and scripts/; never the real tree.
#
# Run: bash tests/test_add_category.sh

# Config targets are literal "$HOME/..." strings, never meant to expand;
# `unchanged` is only called indirectly through assert_true.
# shellcheck disable=SC2016,SC2329

set -euo pipefail

ADD_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/test_helpers.sh
source "${ADD_TEST_DIR}/test_helpers.sh"

ADD="${ROOT}/scripts/add-category.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "add-category.sh tests"
echo "========================================"

if [[ ! -f "$ADD" ]]; then
    echo "scripts/add-category.sh is missing" >&2
    exit 1
fi

# Fresh copy of the validated pieces under $WORK/repo.
fresh_repo() {
    rm -rf "${WORK}/repo"
    mkdir -p "${WORK}/repo"
    cp -R "${ROOT}/config" "${ROOT}/locales" "${ROOT}/scripts" "${WORK}/repo/"
}

REPO="${WORK}/repo"
CONF="${REPO}/config/default.conf"

# Run the tool on the copy; sets RC and OUT. stdin is never a terminal here.
run_add() {
    RC=0
    OUT="$(bash "${REPO}/scripts/add-category.sh" --root "$REPO" "$@" 2>&1 </dev/null)" || RC=$?
}

snapshot() { cp "$CONF" "${WORK}/before.conf"; cp -R "${REPO}/locales" "${WORK}/before-locales"; }
unchanged() {
    cmp -s "${WORK}/before.conf" "$CONF" && diff -r "${WORK}/before-locales" "${REPO}/locales" >/dev/null
}
rm_snapshot() { rm -rf "${WORK}/before.conf" "${WORK}/before-locales"; }

echo ""
echo "--- Valid addition ---"
fresh_repo; snapshot
run_add --name "Café Tools" \
    --add path '$HOME/.cafe/cache' 'Café cache' \
    --add pattern '.cafe-build' 'Café build output' \
    --add prune '$HOME/.cafe/vm' 'Café VM — handled elsewhere'
assert_eq 0 "$RC" "valid addition exits 0"
assert_eq 3 "$(grep -c '^#@Café Tools$' "$CONF")" "marker written in static, dynamic and prune sections"
assert_file_contains "$CONF" 'path|$HOME/.cafe/cache|Café cache' "path rule written"
assert_file_contains "$CONF" 'pattern|.cafe-build|Café build output' "pattern rule written"
assert_file_contains "$CONF" 'prune|$HOME/.cafe/vm|Café VM — handled elsewhere' "prune rule written"
assert_exit_code 0 "check-conf passes on the result" bash "${REPO}/scripts/check-conf.sh" "$CONF"
assert_exit_code 0 "check-i18n passes on the copy" bash "${REPO}/scripts/check-i18n.sh" "${REPO}/locales/en.sh" "${REPO}/locales/fr.sh"
assert_true "locales untouched" diff -r "${WORK}/before-locales" "${REPO}/locales"
# The first rule is placed before the dynamic banner, the pattern after it.
static_line="$(grep -n '^path|\$HOME/\.cafe/cache|' "$CONF" | cut -d: -f1)"
dyn_banner="$(grep -n '^# ── DYNAMIC SCAN PATTERNS' "$CONF" | cut -d: -f1)"
pat_line="$(grep -n '^pattern|\.cafe-build|' "$CONF" | cut -d: -f1)"
assert_true "path rule sits in the static section" test "$static_line" -lt "$dyn_banner"
assert_true "pattern rule sits in the dynamic section" test "$pat_line" -gt "$dyn_banner"
rm_snapshot

echo ""
echo "--- Duplicates refused ---"
fresh_repo; snapshot
run_add --name "Python" --add path '$HOME/.brand-new' 'x'
assert_eq 1 "$RC" "existing category refused (exit 1)"
assert_true "existing category: nothing modified" unchanged
run_add --name "Fresh" --add path '$HOME/.npm/_cacache' 'dup'
assert_eq 1 "$RC" "existing active entry refused (exit 1)"
assert_true "existing entry: nothing modified" unchanged
run_add --name "Fresh" --add path '$HOME/.bun' 'dup of an opt-in entry'
assert_eq 1 "$RC" "existing opt-in (commented) entry refused"
assert_true "opt-in entry: nothing modified" unchanged
run_add --name "Fresh" --add path '$HOME/.a' 'x' --add path '$HOME/.a' 'y'
assert_eq 1 "$RC" "same entry given twice refused"
assert_true "repeated entry: nothing modified" unchanged
rm_snapshot

echo ""
echo "--- Invalid fields refused, nothing written ---"
fresh_repo; snapshot
run_add --name "Bad" --add path 'a|b' 'x'
assert_eq 1 "$RC" "'|' in target refused"
run_add --name "Bad|Name" --add path '$HOME/.x' 'x'
assert_eq 1 "$RC" "'|' in category name refused"
run_add --name "Bad" --add path '$HOME/.x' 'two
lines'
assert_eq 1 "$RC" "newline in reason refused"
run_add --name "Bad" --add path '' 'x'
assert_eq 1 "$RC" "empty target refused"
run_add --name "Bad" --add path '$HOME/.x' ''
assert_eq 1 "$RC" "empty reason refused"
run_add --name "  " --add path '$HOME/.x' 'x'
assert_eq 1 "$RC" "blank category name refused"
run_add --name "Bad" --add bogus '$HOME/.x' 'x'
assert_eq 1 "$RC" "unknown type refused"
assert_true "invalid fields: nothing modified" unchanged
run_add --add path '$HOME/.x' 'x'
assert_eq 2 "$RC" "missing name (non-interactive) is a usage error"
run_add --name "Bad"
assert_eq 2 "$RC" "missing entries (non-interactive) is a usage error"
run_add --bogus
assert_eq 2 "$RC" "unknown flag is a usage error"
assert_true "usage errors: nothing modified" unchanged
rm_snapshot

echo ""
echo "--- Dry run ---"
fresh_repo; snapshot
run_add --dry-run --name "Planned" --add path '$HOME/.planned/cache' 'Planned cache'
assert_eq 0 "$RC" "dry run exits 0"
assert_true "dry run prints the planned diff" grep -Fq '+path|$HOME/.planned/cache|Planned cache' <<<"$OUT"
assert_true "dry run writes nothing" unchanged
assert_eq 0 "$(find "${REPO}/config" -name 'default.conf.*' | wc -l | tr -d ' ')" "dry run leaves no temp file"
rm_snapshot

echo ""
echo "--- Failed validation restores state ---"
fresh_repo; snapshot
# A target using a variable other than $HOME passes the field checks but is
# rejected by check-conf.sh: the real file must stay untouched.
run_add --name "Rejected" --add path '$USER/.x' 'bad variable'
assert_eq 1 "$RC" "check-conf failure gives a nonzero exit"
assert_true "check-conf failure: config unchanged" unchanged
assert_eq 0 "$(find "${REPO}/config" -name 'default.conf.*' | wc -l | tr -d ' ')" "check-conf failure leaves no temp file"
rm_snapshot
# Broken locale parity is propagated and also leaves the config alone.
fresh_repo; snapshot
printf '    MSG_ONLY_EN="x"\n' >> "${REPO}/locales/en.sh"
run_add --name "Parity" --add path '$HOME/.parity' 'x'
assert_eq 1 "$RC" "locale parity failure gives a nonzero exit"
assert_true "parity failure: config unchanged" cmp -s "${WORK}/before.conf" "$CONF"
rm_snapshot

echo ""
echo "--- Name with spaces and accents ---"
fresh_repo
run_add --name "  Données Édition  " --add path '$HOME/Library/Données Édition/cache' 'Cache — régénérable'
assert_eq 0 "$RC" "spaces and accents accepted"
assert_file_contains "$CONF" '#@Données Édition' "name trimmed and written verbatim"
assert_file_contains "$CONF" 'path|$HOME/Library/Données Édition/cache|Cache — régénérable' "accented rule written"

if [[ "$TESTS_RUN" -eq 0 ]]; then
    echo "no assertion ran" >&2
    exit 1
fi
test_summary
