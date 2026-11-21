#!/usr/bin/env bash
# test_categories.sh — #@Category sections: parser, console headers, report (#46)
# Run: bash tests/test_categories.sh

set -euo pipefail

export LANG=C
export LC_ALL=C
export TM_EXCLUSIONS_SKIP_INVENTORY=1
export TM_EXCLUSIONS_SKIP_DU=1

# shellcheck source=tests/test_helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

TEST_HOME="$(mktemp -d)"
trap 'rm -rf "${TEST_HOME}"' EXIT

CAT_HOME="$TEST_HOME/home"
CAT_BIN="$TEST_HOME/bin"
mkdir -p "$CAT_HOME/.config/tm_exclusions" "$CAT_BIN" \
    "$CAT_HOME/.npm/_cacache" "$CAT_HOME/.cache/pip" \
    "$CAT_HOME/Git/proj/node_modules" "$CAT_HOME/Git/proj/.venv-x/__pycache__"
cat > "$CAT_BIN/tmutil" <<'STUB'
#!/bin/sh
if [ "$1" = isexcluded ]; then printf '[Included] %s\n' "$2"; fi
exit 0
STUB
printf '#!/bin/sh\nexit 0\n' > "$CAT_BIN/brew"
printf '#!/bin/sh\nexit 1\n' > "$CAT_BIN/sudo"
chmod +x "$CAT_BIN/"*

cat > "$CAT_HOME/rules" <<'CONF'
path|$HOME/before-marker|rule before any marker
#@Node.js
path|$HOME/.npm/_cacache|npm cache
pattern|node_modules|dependencies
#@Python
path|$HOME/.cache/pip|pip cache
path|$HOME/missing-python|missing python path
pattern|__pycache__|bytecode
#@
path|$HOME/after-empty-marker|back to the default category
CONF
cat > "$CAT_HOME/.config/tm_exclusions/custom.conf" <<'CONF'
path|$HOME/custom-before|custom rule before any marker
#@MyCategory
path|$HOME/custom-mine|custom rule in a user section
CONF
mkdir -p "$CAT_HOME/custom-mine" "$CAT_HOME/custom-before"

cat_run() {
    local out="$1" rc=0
    shift
    env HOME="$CAT_HOME" PATH="$CAT_BIN:$PATH" \
        TM_EXCLUSIONS_DEFAULT_CONF="$CAT_HOME/rules" \
        TM_EXCLUSIONS_REPORT="$CAT_HOME/report" \
        bash "$TM_EXCLUSIONS" "$@" > "$out" 2>&1 || rc=$?
    assert_eq 0 "$rc" "category CLI exits 0: $*"
}

# Line number of the first occurrence of a literal (0 when absent).
line_of() {
    grep -Fn -- "$2" "$1" | head -n 1 | cut -d: -f1 || true
}

echo ""
echo "--- Parser: category attached to each rule (#46) ---"
# The script minus its trailing `main "$@"` call, sourced inside a subshell
# (same technique as smoke.bats-like.sh) to inspect parse_config_file output.
sed '/^main /d' "$TM_EXCLUSIONS" > "$TEST_HOME/functions.sh"
parse_rules() {
    (
        export HOME="$CAT_HOME"
        # shellcheck disable=SC1091
        source "$TEST_HOME/functions.sh"
        CONF_RULES=""
        parse_config_file "$1"
        printf '%s\n' "$CONF_RULES"
    )
}
PARSED="$(parse_rules "$CAT_HOME/rules")"
assert_true "path before any marker uses the default (empty) category" \
    grep -Fq "path|$CAT_HOME/before-marker||" <<<"$PARSED"
assert_true "path after #@Node.js carries that category" \
    grep -Fq "path|$CAT_HOME/.npm/_cacache|Node.js|" <<<"$PARSED"
assert_true "pattern after #@Node.js carries that category" \
    grep -Fq "pattern|node_modules|Node.js|" <<<"$PARSED"
assert_true "pattern after #@Python carries that category" \
    grep -Fq "pattern|__pycache__|Python|" <<<"$PARSED"
assert_true "bare #@ resets to the default category" \
    grep -Fq "path|$CAT_HOME/after-empty-marker||" <<<"$PARSED"
PARSED_CUSTOM="$(parse_rules "$CAT_HOME/.config/tm_exclusions/custom.conf")"
assert_true "custom.conf starts in the default category (no leak from default.conf)" \
    grep -Fq "path|$CAT_HOME/custom-before||" <<<"$PARSED_CUSTOM"
assert_true "custom.conf accepts user-defined #@MyCategory sections" \
    grep -Fq "path|$CAT_HOME/custom-mine|MyCategory|" <<<"$PARSED_CUSTOM"

echo ""
echo "--- Console output: ══ Category ══ headers (#46) ---"
cat_run "$CAT_HOME/out-dry" --dry-run
for header in "══ Uncategorized ══" "══ Node.js ══" "══ Python ══" "══ MyCategory ══"; do
    assert_file_contains "$CAT_HOME/out-dry" "$header" "console shows header $header"
done
assert_eq 2 "$(grep -Fc '══ Node.js ══' "$CAT_HOME/out-dry")" \
    "a category gets one header per phase (static rules, then dynamic scan)"
NODE_LINE="$(line_of "$CAT_HOME/out-dry" '══ Node.js ══')"
PY_LINE="$(line_of "$CAT_HOME/out-dry" '══ Python ══')"
assert_true "categories follow catalog order (Node.js before Python)" \
    test "$NODE_LINE" -gt 0 -a "$NODE_LINE" -lt "$PY_LINE"
assert_file_contains "$CAT_HOME/out-dry" "$CAT_HOME/Git/proj → [DRY-RUN] Would exclude: 1" \
    "grouped natural-root summaries are preserved under the headers"

cat_run "$CAT_HOME/out-verbose" --verbose --dry-run
assert_file_contains "$CAT_HOME/out-verbose" "══ Python ══" "--verbose also groups by category"
assert_file_contains "$CAT_HOME/out-verbose" \
    "[DRY-RUN] Applying exclusion: $CAT_HOME/Git/proj/node_modules" \
    "--verbose keeps individual lines under their category"

cat_run "$CAT_HOME/out-quiet" --quiet --dry-run
assert_file_lacks_regex "$CAT_HOME/out-quiet" '══' "--quiet prints no console category headers"

cat_run "$CAT_HOME/out-fr" --lang fr --dry-run
assert_file_contains "$CAT_HOME/out-fr" "══ Sans catégorie ══" \
    "default category header is localized in French"

echo ""
echo "--- Report: ── Category ── subheadings (#46) ---"
cat_run "$CAT_HOME/out-report" --dry-run
for sub in "── Uncategorized ──" "── Node.js ──" "── Python ──" "── MyCategory ──"; do
    assert_file_contains "$CAT_HOME/report" "$sub" "report has subheading $sub"
done
NODE_R="$(line_of "$CAT_HOME/report" '── Node.js ──')"
PIP_R="$(line_of "$CAT_HOME/report" "WOULD $CAT_HOME/.cache/pip")"
PY_R="$(line_of "$CAT_HOME/report" '── Python ──')"
MINE_R="$(line_of "$CAT_HOME/report" '── MyCategory ──')"
CUSTOM_R="$(line_of "$CAT_HOME/report" "WOULD $CAT_HOME/custom-mine")"
assert_true "a path is listed under its own category" \
    test "$PIP_R" -gt "$PY_R" -a "$PY_R" -gt "$NODE_R"
assert_true "custom.conf section groups its path" \
    test "$CUSTOM_R" -gt "$MINE_R"
assert_file_contains "$CAT_HOME/report" "SKIP  $CAT_HOME/missing-python (not found)" \
    "report keeps every individual detail line"
assert_eq 1 "$(grep -Fc '── Node.js ──' "$CAT_HOME/report")" \
    "static and dynamic rules of one category share a single report subheading"

cat_run "$CAT_HOME/out-report-fr" --lang fr --dry-run
assert_file_contains "$CAT_HOME/report" "── Sans catégorie ──" \
    "report default category is localized in French"

test_summary
