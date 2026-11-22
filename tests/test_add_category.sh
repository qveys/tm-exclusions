#!/usr/bin/env bash
# test_add_category.sh — Tests for scripts/add-category.sh (category scaffolding)
# Works on a throwaway copy of config/, locales/, scripts/ and the smoke test;
# never the real tree. `make` is a stub: the real make check is never run here.
#
# Run: bash tests/test_add_category.sh

# Config targets are literal "$HOME/..." strings, never meant to expand;
# `unchanged` is only called indirectly through assert_true.
# shellcheck disable=SC2016,SC2088,SC2329

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

REPO="${WORK}/repo"
CONF="${REPO}/config/default.conf"
SMOKE="${REPO}/tests/smoke.bats-like.sh"
STUB="${WORK}/stub"
MAKE_LOG="${WORK}/make.log"

# `make` stub: records its arguments, exits with $STUB_MAKE_RC (default 0).
mkdir -p "$STUB"
cat > "${STUB}/make" <<EOF
#!/bin/sh
echo "\$*" >> "${MAKE_LOG}"
exit "\${STUB_MAKE_RC:-0}"
EOF
chmod +x "${STUB}/make"

# Fresh copy of the pieces the tool reads or edits under $WORK/repo.
fresh_repo() {
    rm -rf "$REPO" "$MAKE_LOG"
    mkdir -p "${REPO}/tests"
    cp -R "${ROOT}/config" "${ROOT}/locales" "${ROOT}/scripts" "$REPO/"
    cp "${ROOT}/tests/smoke.bats-like.sh" "${REPO}/tests/"
}

# Run the tool on the copy with --skip-tests; sets RC and OUT. stdin is not a terminal.
run_add() {
    RC=0
    OUT="$(bash "${REPO}/scripts/add-category.sh" --root "$REPO" --skip-tests "$@" 2>&1 </dev/null)" || RC=$?
}

# Same, but without --skip-tests and with the make stub first in PATH.
run_add_full() {
    RC=0
    OUT="$(PATH="${STUB}:$PATH" bash "${REPO}/scripts/add-category.sh" --root "$REPO" "$@" 2>&1 </dev/null)" || RC=$?
}

# Interactive run fed from $1 (stdin content), with the test tty hook.
run_add_stdin() {
    local input="$1"
    shift
    RC=0
    OUT="$(printf '%s' "$input" | ADD_CATEGORY_ASSUME_TTY=1 bash "${REPO}/scripts/add-category.sh" --root "$REPO" --skip-tests "$@" 2>&1)" || RC=$?
}

snapshot() {
    rm -rf "${WORK}/before"
    mkdir -p "${WORK}/before"
    cp "$CONF" "${WORK}/before/default.conf"
    cp "$SMOKE" "${WORK}/before/smoke"
    cp -R "${REPO}/locales" "${WORK}/before/locales"
}
unchanged() {
    cmp -s "${WORK}/before/default.conf" "$CONF" &&
        cmp -s "${WORK}/before/smoke" "$SMOKE" &&
        diff -r "${WORK}/before/locales" "${REPO}/locales" >/dev/null
}
make_calls() { if [[ -f "$MAKE_LOG" ]]; then wc -l < "$MAKE_LOG" | tr -d ' '; else echo 0; fi; }
labels() { { grep -E '^#@' "$CONF" || true; } | sort -u | wc -l | tr -d ' '; }
expected_count() { sed -n 's/^EXPECTED_CATEGORY_COUNT=\([0-9][0-9]*\) .*/\1/p' "$SMOKE"; }
no_leftovers() {
    [[ ! -e "${REPO}/.add-category.lock" ]] &&
        [[ -z "$(find "$REPO" -name '*.new.*' 2>/dev/null)" ]]
}

echo ""
echo "--- Valid addition ---"
fresh_repo; snapshot
base_count="$(expected_count)"
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
assert_true "locales untouched" diff -r "${WORK}/before/locales" "${REPO}/locales"
assert_true "no lock or temp file left behind" no_leftovers
static_line="$(grep -n '^path|\$HOME/\.cafe/cache|' "$CONF" | cut -d: -f1)"
dyn_banner="$(grep -n '^# ── DYNAMIC SCAN PATTERNS' "$CONF" | cut -d: -f1)"
pat_line="$(grep -n '^pattern|\.cafe-build|' "$CONF" | cut -d: -f1)"
assert_true "path rule sits in the static section" test "$static_line" -lt "$dyn_banner"
assert_true "pattern rule sits in the dynamic section" test "$pat_line" -gt "$dyn_banner"

echo ""
echo "--- Category count stays green (point 1) ---"
assert_eq "$((base_count + 1))" "$(expected_count)" "EXPECTED_CATEGORY_COUNT bumped by one"
assert_eq "$(labels)" "$(expected_count)" "constant equals the distinct '#@' labels of the config"
assert_eq 1 "$(grep -c '^EXPECTED_CATEGORY_COUNT=[0-9]* # add-category: expected category count$' "$SMOKE")" "one marker line in the smoke test"
assert_file_contains "$SMOKE" '"${LABEL_COUNT}" -eq "${EXPECTED_CATEGORY_COUNT}"' "the smoke guard still compares the real label count"
assert_eq 1 "$(diff "${WORK}/before/smoke" "$SMOKE" | grep -c '^>')" "only the constant line changed in the smoke test"
assert_file_lacks_regex "${ROOT}/README.md" '[0-9]+ categories' "README quotes no category count"
assert_file_lacks_regex "${ROOT}/docs/ARCHITECTURE.md" '(Exactly|under) [0-9]+ (distinct|category)' "ARCHITECTURE quotes no category count"
# Two categories in a row: the constant keeps following.
run_add --name "Second" --add path '$HOME/.second/cache' 'Second cache'
assert_eq 0 "$RC" "second addition exits 0"
assert_eq "$((base_count + 2))" "$(expected_count)" "constant bumped again"
assert_eq "$(labels)" "$(expected_count)" "constant still equals the label count"

echo ""
echo "--- Validation runs on a copy before anything is replaced (point 1) ---"
fresh_repo; snapshot
run_add_full --name "Checked" --add path '$HOME/.checked/cache' 'Checked cache'
assert_eq 0 "$RC" "full run with a passing make exits 0"
assert_eq 1 "$(make_calls)" "make was invoked once"
assert_true "make check requested (lint + tests)" grep -Fq -- ' check' "$MAKE_LOG"
assert_true "make ran on a temporary copy, not on the real tree" not grep -Fq -- "-C ${REPO} " "$MAKE_LOG"
assert_file_contains "$CONF" '#@Checked' "files replaced after a passing make"
fresh_repo; snapshot
RC=0
OUT="$(STUB_MAKE_RC=1 PATH="${STUB}:$PATH" bash "${REPO}/scripts/add-category.sh" --root "$REPO" \
    --name "Failing" --add path '$HOME/.failing/cache' 'x' 2>&1 </dev/null)" || RC=$?
assert_eq 1 "$RC" "failing make gives exit 1"
assert_true "failing make: real files unchanged" unchanged
assert_true "failing make: no lock or temp file left" no_leftovers
fresh_repo
run_add_full --dry-run --name "Planned" --add path '$HOME/.planned/cache' 'x'
assert_eq 0 "$RC" "dry run exits 0"
assert_true "dry run does not run make" not test -e "$MAKE_LOG"
run_add --name "Quick" --add path '$HOME/.quick/cache' 'x'
assert_true "--skip-tests does not run make" not test -e "$MAKE_LOG"

echo ""
echo "--- Concurrent runs never lose an update (point 2) ---"
fresh_repo; snapshot
mkdir "${REPO}/.add-category.lock"
run_add --name "Locked" --add path '$HOME/.locked/cache' 'x'
assert_eq 1 "$RC" "held lock refused with exit 1"
assert_true "message names the lock" grep -Fq 'add-category.lock' <<<"$OUT"
assert_true "held lock: nothing modified" unchanged
assert_true "the other run's lock is left alone" test -d "${REPO}/.add-category.lock"
rmdir "${REPO}/.add-category.lock"
fresh_repo; base_count="$(expected_count)"
ra=0; rb=0
bash "${REPO}/scripts/add-category.sh" --root "$REPO" --skip-tests --name "Alpha" --add path '$HOME/.alpha/cache' 'a' >"${WORK}/a.out" 2>&1 </dev/null &
pa=$!
bash "${REPO}/scripts/add-category.sh" --root "$REPO" --skip-tests --name "Beta" --add path '$HOME/.beta/cache' 'b' >"${WORK}/b.out" 2>&1 </dev/null &
pb=$!
wait "$pa" || ra=$?
wait "$pb" || rb=$?
ok=0
[[ "$ra" -eq 0 ]] && ok=$((ok + 1))
[[ "$rb" -eq 0 ]] && ok=$((ok + 1))
present="$(grep -c '^#@\(Alpha\|Beta\)$' "$CONF")"
assert_true "at least one concurrent run succeeded" test "$ok" -ge 1
assert_true "a run that failed did so with exit 1" test "$ra" -le 1 -a "$rb" -le 1
assert_eq "$ok" "$present" "every successful run is present in the config (no silent loss)"
assert_eq "$((base_count + ok))" "$(expected_count)" "constant matches the number of categories added"
assert_eq "$(labels)" "$(expected_count)" "constant equals the label count after concurrent runs"
assert_true "no lock left after concurrent runs" no_leftovers

echo ""
echo "--- Duplicates refused ---"
fresh_repo; snapshot
run_add --name "Python" --add path '$HOME/.brand-new' 'x'
assert_eq 1 "$RC" "existing category refused (exit 1)"
assert_true "existing category: nothing modified" unchanged
run_add --name "Fresh" --add path '$HOME/.npm/_cacache' 'dup'
assert_eq 1 "$RC" "existing active rule refused (exit 1)"
run_add --name "Fresh" --add path '$HOME/.bun' 'dup of an opt-in rule'
assert_eq 1 "$RC" "existing opt-in (commented) rule refused"
run_add --name "Fresh" --add path '$HOME/.a' 'x' --add path '$HOME/.a' 'y'
assert_eq 1 "$RC" "same rule given twice refused"
assert_true "duplicates: nothing modified" unchanged

echo ""
echo "--- ~ and trailing slash are normalized before comparing (point 3) ---"
run_add --name "Fresh" --add path '~/.npm/_cacache' 'dup written with ~'
assert_eq 1 "$RC" "~/x duplicate of an existing \$HOME/x rule refused"
run_add --name "Fresh" --add path '$HOME/.npm/_cacache/' 'dup with trailing slash'
assert_eq 1 "$RC" "trailing-slash duplicate refused"
run_add --name "Fresh" --add path '~/.npm/_cacache/' 'both'
assert_eq 1 "$RC" "~ and trailing slash together refused"
run_add --name "Fresh" --add path '~/.same' 'x' --add path '$HOME/.same/' 'y'
assert_eq 1 "$RC" "both spellings given in one call refused"
assert_true "normalization refusals: nothing modified" unchanged
run_add --name "Tilde" --add path '~/.tilde/cache/' 'tilde input' --add keep '~' 'home'
assert_eq 0 "$RC" "~ target accepted"
assert_file_contains "$CONF" 'path|$HOME/.tilde/cache|tilde input' "written in the catalog form \$HOME/x, no trailing slash"
assert_file_contains "$CONF" 'keep|$HOME|home' "bare ~ written as \$HOME"
assert_file_lacks_regex "$CONF" '^(path|keep|prune)\|~' "no ~ target written to the catalog"

echo ""
echo "--- Unrecognized structure fails loudly (point 4) ---"
fresh_repo
sed 's/^# ── DYNAMIC SCAN PATTERNS/## ── DYNAMIC SCAN PATTERNS/' "$CONF" > "${CONF}.t" && mv "${CONF}.t" "$CONF"
snapshot
run_add --name "Anchor" --add path '$HOME/.anchor/cache' 'x'
assert_eq 1 "$RC" "extra # before the dynamic banner: nonzero exit"
assert_true "message explains the structure problem" grep -Fq 'unrecognized structure' <<<"$OUT"
assert_true "extra #: nothing modified" unchanged
fresh_repo
grep -v '^# ── SCAN PRUNE ZONES' "$CONF" > "${CONF}.t" && mv "${CONF}.t" "$CONF"
snapshot
run_add --name "Anchor" --add pattern '.anchor' 'x'
assert_eq 1 "$RC" "missing prune banner: nonzero exit"
assert_true "missing banner: nothing modified" unchanged
fresh_repo
grep -v '^EXPECTED_CATEGORY_COUNT=' "$SMOKE" > "${SMOKE}.t" && mv "${SMOKE}.t" "$SMOKE"
snapshot
run_add --name "Anchor" --add path '$HOME/.anchor/cache' 'x'
assert_eq 1 "$RC" "missing smoke constant: nonzero exit"
assert_true "missing constant: nothing modified" unchanged
assert_true "structure failures leave no lock" no_leftovers

echo ""
echo "--- End of input and newlines (point 5) ---"
fresh_repo; snapshot
run_add_stdin $'Interactive\npath\n$HOME/.inter/cache\nInter cache\n\n'
assert_eq 0 "$RC" "interactive run with a complete answer exits 0"
assert_file_contains "$CONF" 'path|$HOME/.inter/cache|Inter cache' "interactive rule written"
fresh_repo; snapshot
run_add_stdin $'Eof One\npath\n$HOME/.eof/cache\nEof cache\n'
assert_eq 1 "$RC" "EOF at the type prompt after a full rule aborts with exit 1"
assert_true "EOF at the type prompt: nothing written" unchanged
run_add_stdin $'Eof Two\npath\n$HOME/.eof/cache\n'
assert_eq 1 "$RC" "EOF at the reason prompt aborts"
run_add_stdin ''
assert_eq 1 "$RC" "EOF at the name prompt aborts"
assert_true "EOF anywhere: nothing written" unchanged
run_add --name $'\nNewline' --add path '$HOME/.nl/cache' 'x'
assert_eq 1 "$RC" "newline around the name refused (not trimmed)"
run_add --name $'Name\n' --add path '$HOME/.nl/cache' 'x'
assert_eq 1 "$RC" "trailing newline in the name refused"
run_add --name "Nl" --add path $'$HOME/.nl\n/cache' 'x'
assert_eq 1 "$RC" "newline in a target refused"
assert_true "newlines: nothing modified" unchanged

echo ""
echo "--- Invalid fields refused, nothing written ---"
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
assert_eq 2 "$RC" "missing rules (non-interactive) is a usage error"
run_add --bogus
assert_eq 2 "$RC" "unknown flag is a usage error"
assert_true "usage errors: nothing modified" unchanged
HELP="$(bash "$ADD" --help | tr -s '[:space:]' ' ')"
assert_true "--help says category names are not localized" grep -Fq 'names are not localized' <<<"$HELP"

echo ""
echo "--- Dry run ---"
fresh_repo; snapshot
run_add --dry-run --name "Planned" --add path '$HOME/.planned/cache' 'Planned cache'
assert_eq 0 "$RC" "dry run exits 0"
assert_true "dry run prints the planned diff" grep -Fq '+path|$HOME/.planned/cache|Planned cache' <<<"$OUT"
assert_true "dry run writes nothing" unchanged
assert_true "dry run leaves no lock or temp file" no_leftovers

echo ""
echo "--- Failed validation restores state ---"
fresh_repo; snapshot
# A target using a variable other than $HOME passes the field checks but is
# rejected by check-conf.sh: the real files must stay untouched.
run_add --name "Rejected" --add path '$USER/.x' 'bad variable'
assert_eq 1 "$RC" "check-conf failure gives a nonzero exit"
assert_true "check-conf failure: files unchanged" unchanged
assert_true "check-conf failure leaves no lock or temp file" no_leftovers
# Broken locale parity is propagated and also leaves the config alone.
fresh_repo
printf '    MSG_ONLY_EN="x"\n' >> "${REPO}/locales/en.sh"
snapshot
run_add --name "Parity" --add path '$HOME/.parity' 'x'
assert_eq 1 "$RC" "locale parity failure gives a nonzero exit"
assert_true "parity failure: files unchanged" unchanged

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
