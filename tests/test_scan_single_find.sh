#!/usr/bin/env bash
# test_scan_single_find.sh — Single-pass dynamic pattern discovery (issue #50).
#
# Proves that scan_dynamic_patterns() walks $HOME with ONE consolidated find
# call (instead of one find per configured pattern) and discovers exactly the
# same (path, pattern) pairs as the old per-pattern loop, reproduced below as
# the reference baseline. A fake `find` wrapper in PATH counts invocations,
# logs their arguments and tees the raw output of the single pass.
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
export HOME="$TEST_DIR/home"
mkdir -p "$HOME/.config/tm_exclusions" "$TEST_DIR/bin"
export TM_EXCLUSIONS_SKIP_INVENTORY=1 TM_EXCLUSIONS_SKIP_DU=1
export TM_EXCLUSIONS_REPORT="$TEST_DIR/report"
export TEST_CALLS="$TEST_DIR/calls"
export FIND_CALLS="$TEST_DIR/find_calls"
export FIND_ARGS="$TEST_DIR/find_args"
export FIND_RAW="$TEST_DIR/find_raw"
export LANG=C LC_ALL=C
: > "$FIND_CALLS"; : > "$FIND_ARGS"; : > "$FIND_RAW"
unset TM_EXCLUSIONS_EXTRA_CONF TM_EXCLUSIONS_REPORT_DESKTOP TM_EXCLUSIONS_LOCALES_DIR
unset TM_EXCLUSIONS_DEFAULT_CONF

REAL_DEFAULT_CONF="${SCRIPT_DIR}/config/default.conf"

# Never touch the host Time Machine / Homebrew; count and record every find.
cat > "$TEST_DIR/bin/tmutil" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$TEST_CALLS"
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
# No host privilege operations in tests; passwordless sudo "succeeds" so
# out-of-$HOME catalog paths do not turn into errors.
case "$1" in
    -n|-v) exit 0 ;;
    tmutil) shift; exec tmutil "$@" ;;
    *) exit 1 ;;
esac
STUB
cat > "$TEST_DIR/bin/find" <<'STUB'
#!/bin/sh
# Counting wrapper around the real find: one marker per invocation in
# $FIND_CALLS, arguments logged one per line in $FIND_ARGS, raw stdout
# teed to $FIND_RAW so the test can inspect the single consolidated pass.
printf '%s\n' '---' >> "$FIND_ARGS"
for a in "$@"; do printf '%s\n' "$a" >> "$FIND_ARGS"; done
printf 'x\n' >> "$FIND_CALLS"
out="$(mktemp)"
/usr/bin/find "$@" > "$out" 2>/dev/null
status=$?
cat "$out"
cat "$out" >> "$FIND_RAW"
rm -f "$out"
exit "$status"
STUB
chmod +x "$TEST_DIR/bin/"*
export PATH="$TEST_DIR/bin:$PATH"

# Reference implementation of the OLD discovery (one find per pattern, each
# match tagged with its pattern, then one global lexical sort) — the baseline
# the single-pass implementation must reproduce exactly (#50).
reference_discover() {
    local root="$1" patterns="$2" out="$3" p d
    : > "$out"
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        while IFS= read -r d; do
            [[ -z "$d" ]] && continue
            printf '%s\t%s\n' "$d" "$p" >> "$out"
        done < <(/usr/bin/find "$root" -maxdepth 6 -type d -name "$p" 2>/dev/null)
    done <<EOF
$patterns
EOF
    LC_ALL=C sort -t$'\t' -k1,1 "$out" > "$out.sorted"
    mv "$out.sorted" "$out"
}

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

reset_find_logs() {
    : > "$FIND_CALLS"; : > "$FIND_ARGS"; : > "$FIND_RAW"; : > "$TEST_CALLS"
}

find_call_count() {
    grep -c '^x$' "$FIND_CALLS" || true
}

echo "tm-exclusions single-find scan tests (#50)"
echo "========================================"

# ---------------------------------------------------------------------------
# Scenario A — end-to-end equivalence on a minimal config (tags + order).
# ---------------------------------------------------------------------------
echo ""
echo "--- Single pass vs per-pattern reference (minimal conf) ---"

A_HOME="$TEST_DIR/a"
A_CONF="$TEST_DIR/a-default.conf"
mkdir -p "$A_HOME/.config/tm_exclusions"
cat > "$A_CONF" <<'CONF'
# minimal default for the #50 equivalence test
pattern|node_modules|Node modules
pattern|venv|venv
pattern|venv*|venv glob
pattern|dist-*|dist glob
pattern|__pycache__|bytecode cache
pattern|.tox|tox envs
pattern|target|rust target
CONF
cat > "$A_HOME/.config/tm_exclusions/custom.conf" <<'CONF'
pattern|weird name|pattern containing a space
CONF

# Fake tree: nesting-free matches, a dir matching two patterns (venv, venv*),
# glob patterns, spaces in paths, a file (not dir) named node_modules,
# maxdepth boundary (depth 6 matches, depth 7 does not), and target dirs
# with/without a Cargo.toml next to them (pattern_match_allowed).
mkdir -p "$A_HOME/projA/node_modules"
mkdir -p "$A_HOME/projB/venv"
mkdir -p "$A_HOME/projC/venv2"
mkdir -p "$A_HOME/projD/dist-a" "$A_HOME/projD/dist-b" "$A_HOME/projD/distx"
mkdir -p "$A_HOME/my proj/node_modules"
mkdir -p "$A_HOME/projE/__pycache__" "$A_HOME/projE/.tox"
mkdir -p "$A_HOME/projF/target"
mkdir -p "$A_HOME/projG/target"
touch "$A_HOME/projG/Cargo.toml"
mkdir -p "$A_HOME/weird name"
mkdir -p "$A_HOME/file_nm"
touch "$A_HOME/file_nm/node_modules"
mkdir -p "$A_HOME/d6/a/b/c/d/node_modules"
mkdir -p "$A_HOME/d7/a/b/c/d/e/node_modules"

A_PATTERNS="$(grep -hE '^pattern\|' "$A_CONF" "$A_HOME/.config/tm_exclusions/custom.conf" | cut -d'|' -f2)"

reset_find_logs
assert_exit_code 0 \
    "apply run over fake tree exits 0" \
    env HOME="$A_HOME" TM_EXCLUSIONS_DEFAULT_CONF="$A_CONF" bash "$TM_EXCLUSIONS" -q

assert_eq 1 "$(find_call_count)" \
    "dynamic scan runs exactly ONE find invocation (not one per pattern)"

A_NAME_COUNT="$(grep -c '^-name$' "$FIND_ARGS" || true)"
assert_eq "$(printf '%s\n' "$A_PATTERNS" | grep -c .)" "$A_NAME_COUNT" \
    "the single find ORs every configured pattern as a -name operand"
assert_true "single find expression is parenthesized" \
    grep -qx '(' "$FIND_ARGS"
assert_true "single find expression is closed" \
    grep -qx ')' "$FIND_ARGS"

# Reference (old per-pattern logic) over the same tree and patterns.
reference_discover "$A_HOME" "$A_PATTERNS" "$TEST_DIR/a_ref"

# Expected processed list = reference pairs passed through the same downstream
# filters the scan applies (pattern_match_allowed for `target`, then the
# ancestor-descendant kept-prefix prune): no prune/keep/static rules exist in
# this config, so nothing else is dropped.
kept=""
: > "$TEST_DIR/a_expected"
while IFS=$'\t' read -r d p; do
    [[ -z "$d" ]] && continue
    if [[ "$p" = "target" ]]; then
        par="$(dirname "$d")"
        [[ -f "$par/Cargo.toml" || -f "$par/pom.xml" \
            || -f "$par/build.gradle" || -f "$par/build.gradle.kts" ]] || continue
    fi
    covered=0
    while IFS= read -r k; do
        [[ -z "$k" ]] && continue
        if [[ "$d" = "$k" || "$d" == "$k"/* ]]; then covered=1; break; fi
    done <<EOF
$kept
EOF
    [[ "$covered" -eq 1 ]] && continue
    printf '%s\n' "$d" >> "$TEST_DIR/a_expected"
    kept="${kept}${d}
"
done < "$TEST_DIR/a_ref"

grep '^addexclusion ' "$TEST_CALLS" | sed 's/^addexclusion //' > "$TEST_DIR/a_actual"

assert_files_equal "$TEST_DIR/a_expected" "$TEST_DIR/a_actual" \
    "processed paths (order, duplicates, tags) match the per-pattern reference"

# Raw discovery of the single pass equals the union of the per-pattern finds.
cut -f1 "$TEST_DIR/a_ref" | sort -u > "$TEST_DIR/a_ref_dirs"
sort -u "$FIND_RAW" > "$TEST_DIR/a_raw_dirs"
assert_files_equal "$TEST_DIR/a_ref_dirs" "$TEST_DIR/a_raw_dirs" \
    "single find discovers the same directories as the per-pattern reference"

# ---------------------------------------------------------------------------
# Scenario B — raw discovery equivalence with the real default.conf catalog.
# ---------------------------------------------------------------------------
echo ""
echo "--- Single pass over the real default.conf + custom.conf ---"

B_HOME="$TEST_DIR/b"
mkdir -p "$B_HOME/.config/tm_exclusions"
cat > "$B_HOME/.config/tm_exclusions/custom.conf" <<'CONF'
pattern|dist-*|custom glob pattern
pattern|weird name|custom pattern with a space
CONF

# Real-world noise: nested node_modules, prune-zone content (still walked by
# find, filtered downstream), site-packages shapes, spaces, depth boundary,
# a file named node_modules.
mkdir -p "$B_HOME/Git/proj/node_modules/.pnpm/foo/node_modules"
mkdir -p "$B_HOME/Git/proj2/target"
touch "$B_HOME/Git/proj2/Cargo.toml"
mkdir -p "$B_HOME/Git/proj3/target"
mkdir -p "$B_HOME/Library/Caches/x/node_modules"
mkdir -p "$B_HOME/.venv/lib/python3.12/site-packages"
mkdir -p "$B_HOME/tool/python3/site-packages"
mkdir -p "$B_HOME/my proj/node_modules"
mkdir -p "$B_HOME/d6/a/b/c/d/node_modules"
mkdir -p "$B_HOME/d7/a/b/c/d/e/node_modules"
mkdir -p "$B_HOME/dist-a" "$B_HOME/distx" "$B_HOME/weird name"
mkdir -p "$B_HOME/file_nm"
touch "$B_HOME/file_nm/node_modules"

B_PATTERNS="$(grep -hE '^pattern\|' "$REAL_DEFAULT_CONF" "$B_HOME/.config/tm_exclusions/custom.conf" | cut -d'|' -f2)"

reset_find_logs
assert_exit_code 0 \
    "dry-run with real default.conf over fake tree exits 0" \
    env HOME="$B_HOME" bash "$TM_EXCLUSIONS" -q --dry-run

assert_eq 1 "$(find_call_count)" \
    "dynamic scan runs exactly ONE find invocation with the full catalog"

B_NAME_COUNT="$(grep -c '^-name$' "$FIND_ARGS" || true)"
assert_eq "$(printf '%s\n' "$B_PATTERNS" | grep -c .)" "$B_NAME_COUNT" \
    "every default.conf + custom.conf pattern is a -name operand of the single find"

reference_discover "$B_HOME" "$B_PATTERNS" "$TEST_DIR/b_ref"
cut -f1 "$TEST_DIR/b_ref" | sort -u > "$TEST_DIR/b_ref_dirs"
sort -u "$FIND_RAW" > "$TEST_DIR/b_raw_dirs"
assert_files_equal "$TEST_DIR/b_ref_dirs" "$TEST_DIR/b_raw_dirs" \
    "single find over real catalog discovers the same directories as the per-pattern reference"

# ---------------------------------------------------------------------------
# Scenario C — extglob-literal regression: (path, pattern) pairs themselves.
# On Bash 3.2, `[[ $base == $pattern ]]` reads extended globs (+(…), @(…), …)
# even with extglob off, diverging from `find -name`; `case` does not. A
# literal directory named `+(cache)` must be tagged only with the pattern
# `+(cache)`, and `cache` only with `cache`. Run in --uninstall mode (the
# kept-prefix prune is bypassed there) so every tagged pair is processed and
# visible in the report as `REMOVE <path> [file:line | pattern|<pat> | …]`.
# The CLI is run with /bin/bash (Bash 3.2.57 on macOS) when available, so the
# pre-fix `[[ == ]]` tagging actually fails here.
# ---------------------------------------------------------------------------
echo ""
echo "--- Extglob-literal tagging regression (+(cache) vs cache) ---"

C_HOME="$TEST_DIR/c"
C_CONF="$TEST_DIR/c-default.conf"
mkdir -p "$C_HOME/.config/tm_exclusions"
mkdir -p "$C_HOME/p1/+(cache)" "$C_HOME/p2/cache" "$C_HOME/p3/cachecache"
cat > "$C_CONF" <<'CONF'
# extglob-looking pattern must stay a literal glob for find -name
pattern|+(cache)|extglob literal plus
pattern|cache|plain cache
CONF

C_PATTERNS="$(grep -hE '^pattern\|' "$C_CONF" | cut -d'|' -f2)"

BASH32="/bin/bash"
[[ -x "$BASH32" ]] || BASH32="bash"

reset_find_logs
assert_exit_code 0 \
    "uninstall run under $BASH32 over extglob-literal tree exits 0" \
    env HOME="$C_HOME" TM_EXCLUSIONS_DEFAULT_CONF="$C_CONF" TEST_STUB_EXCLUDED=1 \
        "$BASH32" "$TM_EXCLUSIONS" -q --uninstall

assert_eq 1 "$(find_call_count)" \
    "extglob scenario still uses exactly ONE find invocation"

reference_discover "$C_HOME" "$C_PATTERNS" "$TEST_DIR/c_ref"

# Extract (path, pattern) pairs from the report's REMOVE lines (trailing
# whitespace of the rule context is trimmed from the pattern field).
sed -n 's/^REMOVE \(.*\) \[.*| pattern|\([^|]*\)|.*\]$/\1\t\2/p' \
    "$TM_EXCLUSIONS_REPORT" | sed 's/[[:space:]]*$//' > "$TEST_DIR/c_actual"

assert_files_equal "$TEST_DIR/c_ref" "$TEST_DIR/c_actual" \
    "tagged (path, pattern) pairs match the per-pattern find reference"

test_summary
