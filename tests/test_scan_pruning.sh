#!/usr/bin/env bash
# test_scan_pruning.sh — Real traversal pruning of the dynamic scan (issue #13).
#
# Proves, on a generated tree under a temporary HOME, that:
#   * parity: the pruned scan produces exactly the same tmutil calls (same
#     paths, same order) as the unpruned traversal (TM_EXCLUSIONS_NO_SCAN_PRUNE=1),
#     in apply and --uninstall modes, with and without `keep` rules;
#   * pruning: directories under a prune zone (layer 1), under a known static
#     exclusion (layer 2) and below an unconditional match (layer 3) are never
#     visited by find, while guarded patterns (`target` without a build file),
#     --uninstall and `keep` rules keep the traversal they need.
# A wrapper `find` records every directory the traversal visits (an -exec
# clause evaluated before the real expression), so the assertions are about
# traversal cost, not just about final results. tmutil is always a stub.
set -euo pipefail

SCAN_DIR="$(
    source_dir="$(dirname -- "${BASH_SOURCE[0]}")" || exit 1
    [[ "$source_dir" != -* ]] || source_dir="./$source_dir"
    CDPATH='' cd -P -- "${source_dir}" >/dev/null 2>&1 && pwd
)"
# shellcheck source=tests/test_helpers.sh
source "${SCAN_DIR}/test_helpers.sh"

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/bin"
export TM_EXCLUSIONS_SKIP_INVENTORY=1 TM_EXCLUSIONS_SKIP_DU=1
export TM_EXCLUSIONS_REPORT="$TEST_DIR/report"
export TEST_CALLS="$TEST_DIR/calls"
export VISITED="$TEST_DIR/visited"
export LANG=C LC_ALL=C
unset TM_EXCLUSIONS_EXTRA_CONF TM_EXCLUSIONS_REPORT_DESKTOP TM_EXCLUSIONS_LOCALES_DIR
unset TM_EXCLUSIONS_DEFAULT_CONF TM_EXCLUSIONS_NO_SCAN_PRUNE

cat > "$TEST_DIR/bin/tmutil" <<'STUB'
#!/bin/sh
printf '%s %s\n' "$1" "$2" >> "$TEST_CALLS"
if [ "$1" = isexcluded ]; then
    if [ "${TEST_STUB_EXCLUDED:-0}" = "1" ]; then
        printf '[Excluded] %s\n' "$2"
    else
        printf '[Included] %s\n' "$2"
    fi
fi
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
# Visit-recording find: `find ROOT -maxdepth N EXPR...` becomes
# `find ROOT -maxdepth N ( -type d -exec <log> {} + ! -type d ) -o ( EXPR )`.
# The first clause logs every directory find evaluates and is always false, so
# the real expression (and its -prune decisions) runs unchanged afterwards.
cat > "$TEST_DIR/bin/find" <<'STUB'
#!/bin/sh
root="$1"; depth_flag="$2"; depth="$3"; shift 3
# The -exec clause disables find's implicit -print, so add it back for
# expressions (e.g. the pre-#13 one) that rely on it.
for a in "$@"; do
    if [ "$a" = -print ]; then
        exec /usr/bin/find "$root" "$depth_flag" "$depth" \
            '(' -type d -exec sh -c 'printf "%s\n" "$@" >> "$VISITED"' sh '{}' + ! -type d ')' \
            -o '(' "$@" ')'
    fi
done
exec /usr/bin/find "$root" "$depth_flag" "$depth" \
    '(' -type d -exec sh -c 'printf "%s\n" "$@" >> "$VISITED"' sh '{}' + ! -type d ')' \
    -o '(' "$@" ')' -print
STUB
chmod +x "$TEST_DIR/bin/"*
export PATH="$TEST_DIR/bin:$PATH"

BASH32="/bin/bash"
[[ -x "$BASH32" ]] || BASH32="bash"

# build_tree HOME — one fixed shape exercising every pruning layer.
build_tree() {
    local h="$1"
    mkdir -p "$h/.config/tm_exclusions"
    # layer 1: prune zones (one with glob metacharacters in its name)
    mkdir -p "$h/zone/a/node_modules/deep" "$h/zo*ne[1]/b/node_modules/deep"
    # layer 2: static exclusion with nested matches and deep dirs
    mkdir -p "$h/staticdir/p/node_modules/q" "$h/staticdir/deep/er"
    # layer 3: unconditional match with nested matches below it
    mkdir -p "$h/proj/node_modules/.pnpm/a/node_modules/b/c"
    mkdir -p "$h/proj/src/lib"
    # guarded pattern: target with a build file is excluded, descendants covered
    mkdir -p "$h/cargo/target/debug/node_modules"
    touch "$h/cargo/Cargo.toml"
    # guarded pattern: target WITHOUT a build file is not excluded, so a match
    # below it must still be discovered
    mkdir -p "$h/nocargo/target/inner/node_modules/nested"
    # ordinary project dir with spaces
    mkdir -p "$h/my proj/node_modules"
}

write_conf() {
    cat > "$1" <<'CONF'
# generated for test_scan_pruning
path|$HOME/staticdir|static rule
pattern|node_modules|Node modules
pattern|target|rust target
prune|$HOME/zone|prune zone
prune|$HOME/zo*ne[1]|prune zone with glob characters
CONF
}

reset_logs() { : > "$TEST_CALLS"; : > "$VISITED"; }

assert_files_equal() {
    local exp="$1" act="$2" desc="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if diff -u "$exp" "$act" > "$TEST_DIR/last_diff" 2>&1; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        printf "${GREEN}  PASS${NC} %s\n" "$desc"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        printf "${RED}  FAIL${NC} %s\n" "$desc"
        sed 's/^/    /' "$TEST_DIR/last_diff" >&2
    fi
}

# run_scan HOME CONF LABEL BASH-BINARY NOPRUNE [extra args...]
# Leaves tmutil mutation calls in $TEST_DIR/calls.LABEL and visited dirs in
# $TEST_DIR/visited.LABEL.
run_scan() {
    local h="$1" conf="$2" label="$3" shbin="$4" noprune="$5"
    shift 5
    reset_logs
    env HOME="$h" TM_EXCLUSIONS_DEFAULT_CONF="$conf" \
        TM_EXCLUSIONS_NO_SCAN_PRUNE="$noprune" "$shbin" "$TM_EXCLUSIONS" -q "$@" \
        > "$TEST_DIR/out.$label" 2>&1 || true
    grep -E '^(addexclusion|removeexclusion) ' "$TEST_CALLS" > "$TEST_DIR/calls.$label" || true
    sort -u "$VISITED" > "$TEST_DIR/visited.$label"
    cp "$TM_EXCLUSIONS_REPORT" "$TEST_DIR/report.$label" 2>/dev/null || : > "$TEST_DIR/report.$label"
}

echo "tm-exclusions scan pruning tests (#13)"
echo "========================================"

H="$TEST_DIR/home"
CONF="$TEST_DIR/default.conf"
build_tree "$H"
write_conf "$CONF"

# ---------------------------------------------------------------------------
# Apply mode: parity and layers 1-3
# ---------------------------------------------------------------------------
echo ""
echo "--- Apply mode (all three layers) ---"

run_scan "$H" "$CONF" apply_full "$BASH32" 1
run_scan "$H" "$CONF" apply_pruned "$BASH32" 0

assert_true "unpruned reference run excluded something" \
    test -s "$TEST_DIR/calls.apply_full"
assert_files_equal "$TEST_DIR/calls.apply_full" "$TEST_DIR/calls.apply_pruned" \
    "parity: pruned scan issues the same tmutil calls, same order, as the full traversal"

assert_true "reference traversal visits the prune zone contents" \
    grep -qxF "$H/zone/a/node_modules" "$TEST_DIR/visited.apply_full"
# shellcheck disable=SC2016
assert_true "layer 1: nothing below a prune zone is visited" \
    bash -c '! grep -qE "^'"$H"'/zone/" "$1"' _ "$TEST_DIR/visited.apply_pruned"
assert_true "reference traversal visits the glob-named prune zone contents" \
    grep -qxF "$H/zo*ne[1]/b/node_modules" "$TEST_DIR/visited.apply_full"
# shellcheck disable=SC2016
assert_true "layer 1: zone with glob characters is pruned (not mistaken for a pattern)" \
    bash -c '! grep -qF -e "'"$H"'/zo*ne[1]/" "$1"' _ "$TEST_DIR/visited.apply_pruned"
assert_true "layer 1: the zone root itself is still reported as skipped" \
    grep -qF "SKIP  $H/zone (" "$TEST_DIR/report.apply_pruned"
# shellcheck disable=SC2016
assert_true "layer 2: nothing below a static exclusion is visited" \
    bash -c '! grep -qE "^'"$H"'/staticdir/" "$1"' _ "$TEST_DIR/visited.apply_pruned"
assert_true "reference traversal visits below the static exclusion" \
    grep -qxF "$H/staticdir/p/node_modules" "$TEST_DIR/visited.apply_full"
assert_true "layer 3: a matched node_modules is visited (it is the match)" \
    grep -qxF "$H/proj/node_modules" "$TEST_DIR/visited.apply_pruned"
# shellcheck disable=SC2016
assert_true "layer 3: nothing below a matched node_modules is visited" \
    bash -c '! grep -qE "^'"$H"'/proj/node_modules/" "$1"' _ "$TEST_DIR/visited.apply_pruned"
assert_true "reference traversal visits below a matched node_modules" \
    grep -qxF "$H/proj/node_modules/.pnpm/a/node_modules" "$TEST_DIR/visited.apply_full"
assert_true "guarded pattern: below an unconfirmed target/ the traversal continues" \
    grep -qxF "$H/nocargo/target/inner/node_modules" "$TEST_DIR/visited.apply_pruned"
assert_true "guarded pattern: node_modules below a rejected target/ is still excluded" \
    grep -qxF "addexclusion $H/nocargo/target/inner/node_modules" "$TEST_DIR/calls.apply_pruned"
assert_true "ordinary directories are still visited" \
    grep -qxF "$H/proj/src/lib" "$TEST_DIR/visited.apply_pruned"

FULL_N="$(grep -c . "$TEST_DIR/visited.apply_full")"
PRUNED_N="$(grep -c . "$TEST_DIR/visited.apply_pruned")"
echo "  info: directories visited, full traversal=$FULL_N pruned=$PRUNED_N"
assert_true "pruned traversal visits strictly fewer directories ($PRUNED_N < $FULL_N)" \
    test "$PRUNED_N" -lt "$FULL_N"

# ---------------------------------------------------------------------------
# --uninstall: layers 2 and 3 are off (every nested exclusion must be found)
# ---------------------------------------------------------------------------
echo ""
echo "--- Uninstall mode (only layer 1) ---"

export TEST_STUB_EXCLUDED=1
run_scan "$H" "$CONF" un_full "$BASH32" 1 --uninstall
run_scan "$H" "$CONF" un_pruned "$BASH32" 0 --uninstall
unset TEST_STUB_EXCLUDED

assert_true "uninstall: reference run removed exclusions" \
    test -s "$TEST_DIR/calls.un_full"
assert_files_equal "$TEST_DIR/calls.un_full" "$TEST_DIR/calls.un_pruned" \
    "parity (uninstall): same tmutil calls, same order, with and without pruning"
assert_true "uninstall: nested matches below node_modules are still visited" \
    grep -qxF "$H/proj/node_modules/.pnpm/a/node_modules" "$TEST_DIR/visited.un_pruned"
assert_true "uninstall: directories below a static rule are still visited" \
    grep -qxF "$H/staticdir/p/node_modules" "$TEST_DIR/visited.un_pruned"
# shellcheck disable=SC2016
assert_true "uninstall: prune zones stay pruned" \
    bash -c '! grep -qE "^'"$H"'/zone/" "$1"' _ "$TEST_DIR/visited.un_pruned"

# ---------------------------------------------------------------------------
# keep rules: layer 3 must stay off (a keep decides per match), parity holds
# ---------------------------------------------------------------------------
echo ""
echo "--- keep rules (layer 3 off) ---"

KH="$TEST_DIR/keephome"
build_tree "$KH"
KCONF="$TEST_DIR/keep.conf"
# shellcheck disable=SC2016
{ cat "$CONF"; printf 'keep|$HOME/proj/node_modules/.pnpm|keep a nested store\n'; } > "$KCONF"

run_scan "$KH" "$KCONF" keep_full "$BASH32" 1
run_scan "$KH" "$KCONF" keep_pruned "$BASH32" 0

assert_files_equal "$TEST_DIR/calls.keep_full" "$TEST_DIR/calls.keep_pruned" \
    "parity (keep): same tmutil calls, same order, with and without pruning"
assert_true "keep: a protected subtree below a match is still traversed" \
    grep -qxF "$KH/proj/node_modules/.pnpm/a" "$TEST_DIR/visited.keep_pruned"
# shellcheck disable=SC2016
assert_true "keep: layer 1 still prunes zones" \
    bash -c '! grep -qE "^'"$KH"'/zone/" "$1"' _ "$TEST_DIR/visited.keep_pruned"
# shellcheck disable=SC2016
assert_true "keep: the protected path itself is never excluded" \
    bash -c '! grep -qF "'"$KH"'/proj/node_modules/.pnpm" "$1"' _ "$TEST_DIR/calls.keep_pruned"

# ---------------------------------------------------------------------------
# Bash 5 (when available): same parity
# ---------------------------------------------------------------------------
if [[ -x /opt/homebrew/bin/bash ]]; then
    echo ""
    echo "--- Bash 5 parity ---"
    run_scan "$H" "$CONF" b5_pruned /opt/homebrew/bin/bash 0
    assert_files_equal "$TEST_DIR/calls.apply_full" "$TEST_DIR/calls.b5_pruned" \
        "parity (Bash 5): pruned scan equals the full traversal reference"
fi

# ---------------------------------------------------------------------------
# Guard list drift: pattern_is_guarded must name every pattern that
# pattern_match_allowed can reject.
# ---------------------------------------------------------------------------
echo ""
echo "--- Guarded pattern list stays in sync ---"

FN_LABELS="$(awk '
    /^pattern_match_allowed\(\)/ {infn=1; next}
    infn && /^}/ {exit}
    infn && /^    case "\$pat" in/ {incase=1; next}
    incase && /^        \*\)/ {exit}
    incase && /^        [a-z][a-z-]*\)/ {gsub(/[ )]/, ""); print}
' "$TM_EXCLUSIONS" | LC_ALL=C sort | tr '\n' ' ')"
GUARD_LABELS="$(awk '
    /^pattern_is_guarded\(\)/ {infn=1; next}
    infn && /^}/ {exit}
    infn && /\) return 0 ;;/ {sub(/\) return 0 ;;.*/, ""); gsub(/^ +/, ""); gsub(/\|/, "\n"); print}
' "$TM_EXCLUSIONS" | LC_ALL=C sort | tr '\n' ' ')"
assert_eq "site-packages target worktrees " "$FN_LABELS" \
    "pattern_match_allowed() guards the patterns this test expects"
assert_eq "$FN_LABELS" "$GUARD_LABELS" \
    "pattern_is_guarded() lists exactly the patterns guarded in pattern_match_allowed()"

test_summary
