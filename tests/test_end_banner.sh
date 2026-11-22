#!/usr/bin/env bash
# test_end_banner.sh — interactive end-of-run summary banner (#44): counters,
# cumulative space excluded in readable units, report path, verification tip;
# hidden by --quiet; simulated wording in --dry-run (no mutation); 0 exclusions;
# unreadable or partially measured sizes (du exit != 0) flagged as partial/unknown
# instead of a false total; lower bounds never rounded up; tabs/newlines in names;
# --quiet stdout unchanged; copy-pasteable verification tip.
# Everything runs against a mktemp -d tree with stub tmutil/du in PATH: no real
# tmutil, du, macOS or /Applications dependency (GNU userland is fine).
# Run: bash tests/test_end_banner.sh
set -euo pipefail

export LANG=C
export LC_ALL=C
export TM_EXCLUSIONS_SKIP_INVENTORY=1
unset TM_EXCLUSIONS_SKIP_DU NO_COLOR

# shellcheck source=tests/test_helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

TEST_HOME="$(mktemp -d)"
trap 'rm -rf "${TEST_HOME}"' EXIT

B_HOME="$TEST_HOME/home"
B_BIN="$TEST_HOME/bin"
B_CALLS="$TEST_HOME/tmutil.calls"
B_ALL="$TEST_HOME/tmutil.all"
B_DU_CALLS="$TEST_HOME/du.calls"
mkdir -p "$B_HOME/.config/tm_exclusions" "$B_BIN"
# du is called with the physical path (normalize_path resolves symlinks such as
# macOS /var -> /private/var).
B_PHYS="$(cd -P "$B_HOME" && pwd)"
: > "$B_HOME/.config/tm_exclusions/custom.conf"

# tmutil stub: records mutations; paths named *already* are reported excluded.
cat > "$B_BIN/tmutil" <<STUB
#!/bin/sh
printf '%s\\n' "\$1" >> "$B_ALL"
case "\$1" in
    isexcluded)
        case "\$2" in
            *already*) printf '[Excluded] %s\n' "\$2" ;;
            *) printf '[Included] %s\n' "\$2" ;;
        esac ;;
    addexclusion|removeexclusion) printf '%s %s\n' "\$1" "\$2" >> "$B_CALLS" ;;
esac
exit 0
STUB
# du stub: size in KiB is encoded in the last path component (sz<KiB>, e.g.
# sz1024); a component containing "unk" fails like an unreadable tree.
cat > "$B_BIN/du" <<STUB
#!/bin/sh
for last; do :; done
printf '%s\n' "\$last" >> "$B_DU_CALLS"
base="\${last##*/}"
case "\$base" in
    *unk*) exit 1 ;;
    *part*) kb="\${base#sz}"; kb="\${kb%%[!0-9]*}"; printf '%s\\t%s\\n' "\$kb" "\$last"; exit 1 ;;
    sz*) kb="\${base#sz}"; kb="\${kb%%[!0-9]*}"; printf '%s\t%s\n' "\$kb" "\$last" ;;
    *) printf '8\t%s\n' "\$last" ;;
esac
STUB
printf '#!/bin/sh\nexit 1\n' > "$B_BIN/sudo"
chmod +x "$B_BIN/tmutil" "$B_BIN/du" "$B_BIN/sudo"

# Script minus its trailing `main "$@"`, loaded from a TEMPORARY FILE (never
# `source <(...)`: that does not define functions under Bash 3.2).
B_FUNCS="$TEST_HOME/functions.sh"
sed '/^main /d' "$TM_EXCLUSIONS" > "$B_FUNCS"

mkdir_paths() {
    local p
    for p in "$@"; do mkdir -p "$B_HOME/$p"; done
}

# banner_run <out> <mode> <dry 0|1> <quiet 0|1> <lang> <rel-path>...
# Processes each path with the real process_path, then generate_report with the
# interactive UI forced on (a pipe is never a tty). Colors stay empty.
banner_run() {
    local out="$1" mode="$2" dry="$3" quiet="$4" lang="$5"
    shift 5
    : > "$B_CALLS"
    : > "$B_ALL"
    : > "$B_DU_CALLS"
    (
        export HOME="$B_HOME"
        # shellcheck disable=SC2030
        export PATH="$B_BIN:$PATH"
        export TM_EXCLUSIONS_REPORT="$B_HOME/report.txt"
        # shellcheck disable=SC1090
        source "$B_FUNCS"
        # shellcheck disable=SC1090
        source "$ROOT/locales/${lang}.sh"
        "declare_i18n_${lang}"
        # shellcheck disable=SC2034
        MODE="$mode"
        # shellcheck disable=SC2034
        DRY_RUN="$dry"
        # shellcheck disable=SC2034
        QUIET="$quiet"
        # shellcheck disable=SC2034
        UI=1
        # shellcheck disable=SC2034
        HAS_TMUTIL=1
        local rel
        for rel in "$@"; do process_path "$B_HOME/$rel"; done
        generate_report
    ) > "$out" 2>&1 || true
}

# ---------------------------------------------------------------------------
echo ""
echo "--- format_size_kb: units, rounding, 1023/1024 boundaries ---"
fmt_case() {
    assert_eq "$2" "$(bash -c 'source "$1"; format_size_kb "$2"' _ "$B_FUNCS" "$1")" \
        "format_size_kb $1 -> $2"
}
fmt_case 0 "0K"
fmt_case 1 "1K"
fmt_case 1023 "1023K"
fmt_case 1024 "1.0M"
fmt_case 1535 "1.5M"
fmt_case 1536 "1.5M"
fmt_case 1048575 "1.0G"
fmt_case 1048576 "1.0G"
fmt_case 1572864 "1.5G"
fmt_case 2097152 "2.0G"
fmt_case 1073741823 "1.0T"
fmt_case 1073741824 "1.0T"
fmt_case 2147483648 "2.0T"
# Lower-bound ("≥") formatting truncates, never rounds up past the known value.
fmt_floor() {
    assert_eq "$2" "$(bash -c 'source "$1"; format_size_kb "$2" floor' _ "$B_FUNCS" "$1")" \
        "format_size_kb $1 floor -> $2"
}
fmt_floor 1023 "1023K"
fmt_floor 1024 "1.0M"
fmt_floor 2047 "1.9M"
fmt_floor 1048575 "1023.9M"
fmt_floor 1048576 "1.0G"
fmt_floor 2097151 "1.9G"

echo ""
echo "--- Interactive banner: mixed excluded / already / missing ---"
mkdir_paths c/sz1023 c/sz1024 c/sz3000-already
banner_run "$TEST_HOME/out-mixed" apply 0 0 en c/sz1023 c/sz1024 c/sz3000-already c/missing-one
OUT="$TEST_HOME/out-mixed"
assert_file_contains "$OUT" "Summary" "banner heading is shown in an interactive run"
assert_file_lacks_regex "$OUT" 'Would exclude:' "apply run uses the real 'Newly excluded' label"
assert_file_contains "$OUT" "Newly excluded: 2" "banner counts newly excluded paths"
assert_file_contains "$OUT" "Already excluded: 1" "banner counts already-excluded paths"
assert_file_contains "$OUT" "Missing paths: 1" "banner counts missing paths"
assert_file_contains "$OUT" "Space excluded: 2.0M" "space excluded = 1023K + 1024K = 2047K -> 2.0M"
assert_file_contains "$OUT" "Disk usage total: 4.9M" "disk usage total covers touched paths (1023+1024+3000K)"
assert_file_contains "$OUT" "Report saved to: $B_HOME/report.txt" "banner shows the report path"
assert_file_contains "$OUT" "Verify an exclusion with: tmutil isexcluded $(printf '%q' "$B_HOME/c/sz1023")" \
    "banner tip is a real command on the first excluded path"
assert_file_lacks_regex "$OUT" 'isexcluded <' "banner tip has no <placeholder> (it would be a shell syntax error)"
assert_eq 1 "$(grep -Fc 'Report saved to:' "$OUT")" "report path is printed once"
assert_file_lacks_regex "$OUT" 'Simulated run' "apply run is not labelled simulated"
assert_eq 2 "$(grep -c '^addexclusion ' "$B_CALLS")" "exactly the two new paths were really excluded"
assert_true "control: an apply run does log mutation commands (the dry-run check is meaningful)" \
    grep -qx addexclusion "$B_ALL"
# Same figures in the saved report as in the banner.
assert_file_contains "$B_HOME/report.txt" "Space excluded: 2.0M" "report carries the same space excluded"
assert_file_contains "$B_HOME/report.txt" "Disk usage total: 4.9M" "report carries the same disk usage total"
assert_file_contains "$B_HOME/report.txt" "Newly excluded: 2" "report carries the same excluded counter"
# du runs at most once per processed path (no re-measure for the banner).
assert_eq 3 "$(wc -l < "$B_DU_CALLS" | tr -d ' ')" "du ran once per existing path (3), never again for the banner"
assert_eq 0 "$(sort "$B_DU_CALLS" | uniq -d | wc -l | tr -d ' ')" "no path was measured twice"

echo ""
echo "--- --dry-run: simulated wording, no mutation ---"
banner_run "$TEST_HOME/out-dry" apply 1 0 en c/sz1023 c/sz1024 c/sz3000-already c/missing-one
OUT="$TEST_HOME/out-dry"
assert_file_contains "$OUT" "Simulated run" "dry-run banner says the run is simulated"
assert_file_contains "$OUT" "[DRY-RUN]" "dry-run banner carries the DRY-RUN marker"
assert_file_contains "$OUT" "Space that would be excluded (simulated): 2.0M" "dry-run space is labelled simulated"
assert_file_lacks_regex "$OUT" 'Space excluded:' "dry-run never claims space was excluded"
assert_file_contains "$OUT" "Would exclude: 2" "dry-run counter uses the 'would' label"
assert_eq 0 "$(wc -l < "$B_CALLS" | tr -d ' ')" "dry-run called no tmutil mutation"
assert_eq 0 "$(grep -Evc '^(isexcluded|listexclusions)$' "$B_ALL" || true)" \
    "dry-run: only read-only isexcluded/listexclusions were called (no addexclusion/removeexclusion)"
# shellcheck disable=SC2016
assert_true "dry-run still does the read-only status lookups (isexcluded and listexclusions)" \
    bash -c 'grep -qx isexcluded "$1" && grep -qx listexclusions "$1"' _ "$B_ALL"

echo ""
echo "--- --quiet: no banner ---"
banner_run "$TEST_HOME/out-quiet" apply 0 1 en c/sz1023 c/sz1024
OUT="$TEST_HOME/out-quiet"
assert_file_lacks_regex "$OUT" 'Summary' "quiet prints no banner heading"
assert_file_lacks_regex "$OUT" 'tmutil isexcluded' "quiet prints no verification tip"
assert_file_lacks_regex "$OUT" '📊' "quiet prints no banner glyph"
# End to end through the real CLI (stdout is a pipe: plain, but must never gain the banner).
B_RULES="$B_HOME/rules"
# shellcheck disable=SC2016
printf 'path|$HOME/c/sz1023|a\npath|$HOME/c/sz1024|b\n' > "$B_RULES"
# shellcheck disable=SC2329
cli_run() {
    local out="$1"
    shift
    # shellcheck disable=SC2031
    env HOME="$B_HOME" PATH="$B_BIN:$PATH" TM_EXCLUSIONS_DEFAULT_CONF="$B_RULES" \
        TM_EXCLUSIONS_REPORT="$B_HOME/cli-report.txt" \
        bash "$TM_EXCLUSIONS" "$@" > "$out" 2>&1
}
# stdout only (stderr carries a non-macOS notice on Linux runners).
# shellcheck disable=SC2329
cli_stdout() {
    local out="$1"
    shift
    # shellcheck disable=SC2031
    env HOME="$B_HOME" PATH="$B_BIN:$PATH" TM_EXCLUSIONS_DEFAULT_CONF="$B_RULES" \
        TM_EXCLUSIONS_REPORT="$B_HOME/cli-report-q.txt" \
        bash "$TM_EXCLUSIONS" "$@" > "$out" 2>/dev/null
}
: > "$B_CALLS"
assert_exit_code 0 "CLI --quiet --dry-run exits 0" cli_run "$TEST_HOME/cli-quiet" --quiet --dry-run
assert_file_lacks_regex "$TEST_HOME/cli-quiet" 'Verify an exclusion with' "CLI --quiet shows no banner tip"
assert_file_lacks_regex "$TEST_HOME/cli-quiet" '📊' "CLI --quiet shows no banner glyph"
# --quiet keeps its pre-#44 stdout: the full report WITHOUT the new space line
# (that line lives in the saved report file only).
assert_exit_code 0 "CLI --quiet --dry-run stdout capture exits 0" \
    cli_stdout "$TEST_HOME/cli-quiet-out" --quiet --dry-run
assert_file_lacks_regex "$TEST_HOME/cli-quiet-out" 'Space (excluded|that would be excluded)' \
    "--quiet stdout has no new space line"
assert_file_contains "$B_HOME/cli-report-q.txt" "Space that would be excluded (simulated): 2.0M" \
    "--quiet still saves the space line in the report file"
assert_eq "$(grep -v '^Space that would be excluded' "$B_HOME/cli-report-q.txt")" \
    "$(tail -n +2 "$TEST_HOME/cli-quiet-out")" \
    "--quiet stdout is exactly the saved report minus the space line"
assert_true "--quiet stdout still prints the report counters" \
    grep -q 'Missing paths: 0' "$TEST_HOME/cli-quiet-out"
: > "$B_ALL"
assert_exit_code 0 "CLI --dry-run exits 0" cli_run "$TEST_HOME/cli-dry" --dry-run
assert_file_contains "$B_HOME/cli-report.txt" "Space that would be excluded (simulated): 2.0M" \
    "CLI report carries the simulated space (same figure as the banner)"
assert_eq 0 "$(wc -l < "$B_CALLS" | tr -d ' ')" "CLI --dry-run called no tmutil mutation"
assert_eq 0 "$(grep -Evc '^(isexcluded|listexclusions)$' "$B_ALL" || true)" \
    "CLI --dry-run: only isexcluded/listexclusions were called"

echo ""
echo "--- Zero exclusions ---"
banner_run "$TEST_HOME/out-zero" apply 0 0 en c/sz3000-already c/missing-two
OUT="$TEST_HOME/out-zero"
assert_file_contains "$OUT" "Newly excluded: 0" "zero exclusions: counter is 0"
assert_file_contains "$OUT" "Space excluded: 0K" "zero exclusions: space is 0K, not blank"
assert_file_contains "$OUT" "tmutil isexcluded $(printf '%q' "$B_HOME/c/sz3000-already")" \
    "zero exclusions: tip falls back to the first processed path"
banner_run "$TEST_HOME/out-none" apply 0 0 en
assert_file_contains "$TEST_HOME/out-none" "Space excluded: 0K" "no path at all: space is 0K"
assert_file_contains "$TEST_HOME/out-none" 'tmutil isexcluded "/path/to/folder"' \
    "no path: tip shows an unambiguous example without <placeholder>"
assert_file_lacks_regex "$TEST_HOME/out-none" 'isexcluded <' "no path: no chevrons in the tip"
banner_run "$TEST_HOME/out-none-fr" apply 0 0 fr
assert_file_contains "$TEST_HOME/out-none-fr" 'tmutil isexcluded "/chemin/vers/dossier"' "no path: French example"

echo ""
echo "--- Unknown sizes: partial / unknown, never a false total ---"
mkdir_paths c/unk-tree c/unk-two
banner_run "$TEST_HOME/out-partial" apply 0 0 en c/sz1024 c/unk-tree
OUT="$TEST_HOME/out-partial"
assert_file_contains "$OUT" "Newly excluded: 2" "unreadable size does not change the counter"
assert_file_contains "$OUT" "Space excluded: ≥ 1.0M (partial, unmeasured paths: 1)" \
    "partial total is a lower bound with the unmeasured count"
assert_file_lacks_regex "$OUT" 'Space excluded: 1\.0M$' "partial total is not presented as exact"
assert_file_contains "$B_HOME/report.txt" "Space excluded: ≥ 1.0M (partial, unmeasured paths: 1)" \
    "report shows the same partial total"
banner_run "$TEST_HOME/out-unknown" apply 0 0 en c/unk-tree c/unk-two
assert_file_contains "$TEST_HOME/out-unknown" "Space excluded: unknown (sizes could not be read)" \
    "no readable size at all: unknown, not 0K"
assert_file_lacks_regex "$TEST_HOME/out-unknown" 'Space excluded: 0K' "all-unknown is never shown as 0K"

echo ""
echo "--- Nested exclusions counted once; names with spaces / newline ---"
mkdir_paths "c/sz100" "c/sz100/sz50" "c/with space/sz10"
banner_run "$TEST_HOME/out-nested" apply 0 0 en c/sz100/sz50 c/sz100 "c/with space/sz10"
assert_file_contains "$TEST_HOME/out-nested" "Newly excluded: 3" "nested paths are all counted as excluded"
assert_file_contains "$TEST_HOME/out-nested" "Space excluded: 110K" \
    "child under an excluded parent is not double counted; name with a space is measured"
NL_REL="c/new"$'\n'"line"
mkdir -p "$B_HOME/$NL_REL"
banner_run "$TEST_HOME/out-newline" apply 0 0 en c/sz1024 "$NL_REL"
assert_file_contains "$TEST_HOME/out-newline" "Space excluded: ≥ 1.0M (partial, unmeasured paths: 1)" \
    "a newline in a name is flagged as unmeasured rather than dropped from the total"
assert_eq 0 "$(grep -c 'c/new' "$B_DU_CALLS" || true)" \
    "a newline name never reaches du (no parasitic du calls on its fragments)"
assert_eq 1 "$(grep -Fxc "$B_PHYS/c/sz1024" "$B_DU_CALLS")" "the other path was still measured exactly once"

echo ""
echo "--- Audit mode (--report) and French locale ---"
banner_run "$TEST_HOME/out-audit" report-only 0 0 en c/sz1024
assert_file_contains "$TEST_HOME/out-audit" "Space needing exclusion: 1.0M" "audit labels the space as needing exclusion"
assert_file_lacks_regex "$TEST_HOME/out-audit" 'Simulated run' "audit is not a simulated run"
banner_run "$TEST_HOME/out-fr" apply 1 0 fr c/sz1024 c/unk-tree
OUT="$TEST_HOME/out-fr"
assert_file_contains "$OUT" "Bilan" "French banner heading"
assert_file_contains "$OUT" "Exécution simulée" "French dry-run banner says simulated"
assert_file_contains "$OUT" "Espace qui serait exclu (simulé) : ≥ 1.0M (partiel, chemins non mesurés : 1)" \
    "French simulated + partial wording"
assert_file_contains "$OUT" "Vérifier une exclusion avec : tmutil isexcluded $(printf '%q' "$B_HOME/c/sz1024")" \
    "French verification tip on a real path"

echo ""
echo "--- Uninstall: no space-excluded figure ---"
banner_run "$TEST_HOME/out-uninstall" uninstall 0 0 en c/sz3000-already
assert_file_lacks_regex "$TEST_HOME/out-uninstall" 'Space excluded:' "uninstall does not report space excluded"

echo ""
echo "--- TM_EXCLUSIONS_SKIP_DU=1: no size figure ---"
(
    export TM_EXCLUSIONS_SKIP_DU=1
    banner_run "$TEST_HOME/out-nodu" apply 0 0 en c/sz1024
)
assert_file_lacks_regex "$TEST_HOME/out-nodu" 'Space excluded:' "SKIP_DU hides the space figure"
assert_file_contains "$TEST_HOME/out-nodu" "tmutil isexcluded" "SKIP_DU still shows the rest of the banner"

echo ""
echo "--- Lower bound is never rounded up ---"
mkdir_paths c/sz2047
banner_run "$TEST_HOME/out-lb" apply 0 0 en c/sz2047 c/unk-tree
assert_file_contains "$TEST_HOME/out-lb" "Space excluded: ≥ 1.9M (partial, unmeasured paths: 1)" \
    "2047K measured + 1 unreadable: bound is 1.9M, not 2.0M"
assert_file_lacks_regex "$TEST_HOME/out-lb" 'Space excluded: ≥ 2\.0M' "bound does not exceed the 2047K actually measured"
banner_run "$TEST_HOME/out-exact" apply 0 0 en c/sz2047
assert_file_contains "$TEST_HOME/out-exact" "Space excluded: 2.0M" "an exact (complete) total keeps normal rounding"

echo ""
echo "--- du exits non-zero with a partial size (GNU/BSD unreadable children) ---"
mkdir_paths c/sz32-part c/sz64-part
banner_run "$TEST_HOME/out-part-only" apply 0 0 en c/sz32-part
assert_file_contains "$TEST_HOME/out-part-only" "Space excluded: unknown (sizes could not be read)" \
    "a partial du size alone is unmeasured, not shown as 32K"
assert_file_lacks_regex "$TEST_HOME/out-part-only" 'Space excluded: 32K' "partial size is never presented as the exact total"
banner_run "$TEST_HOME/out-part-mix" apply 0 0 en c/sz1024 c/sz32-part c/sz64-part
assert_file_contains "$TEST_HOME/out-part-mix" "Space excluded: ≥ 1.0M (partial, unmeasured paths: 2)" \
    "partial measurements are counted unmeasured and not added to the total"
assert_file_contains "$B_HOME/report.txt" "Space excluded: ≥ 1.0M (partial, unmeasured paths: 2)" \
    "report shows the same partial figure"
assert_eq 1 "$(grep -Fxc "$B_PHYS/c/sz32-part" "$B_DU_CALLS")" "partial path measured once (cached with its partial flag)"

echo ""
echo "--- Tab in a path name: size cache stays consistent ---"
TAB_REL="c/sz42"$'\t'"tab"
mkdir -p "$B_HOME/$TAB_REL"
banner_run "$TEST_HOME/out-tab" apply 0 0 en "$TAB_REL"
assert_file_contains "$TEST_HOME/out-tab" "Space excluded: 42K" "a tab in the name does not turn the size into unknown"
assert_file_lacks_regex "$TEST_HOME/out-tab" 'unknown' "tab path: no unknown figure"
assert_file_contains "$TEST_HOME/out-tab" "Disk usage total: 42K" "tab path: disk usage total uses the cached size"
assert_eq 1 "$(grep -Fxc "$B_PHYS/$TAB_REL" "$B_DU_CALLS")" "tab path measured by du exactly once"

echo ""
echo "--- Verification tip is a copy-pasteable command ---"
# Round trip: the quoted argument must evaluate back to the exact path in Bash,
# including spaces, quotes, $, backticks, a newline and a leading-dash component.
tip_roundtrip() {
    local rel="$1" desc="$2" out="$TEST_HOME/out-tip" line arg got
    mkdir -p "$B_HOME/$rel"
    banner_run "$out" apply 0 0 en "$rel"
    line="$(grep 'Verify an exclusion with: tmutil isexcluded ' "$out" | head -n 1)"
    arg="${line#*tmutil isexcluded }"
    got="$(eval "printf '%s' $arg")"
    assert_eq "$B_HOME/$rel" "$got" "tip round-trips: $desc"
}
tip_roundtrip "c/with space/dir" "spaces"
tip_roundtrip "c/it's \"q\"" "single and double quotes"
# shellcheck disable=SC2016
tip_roundtrip 'c/$HOME `x` \back' "dollar, backtick, backslash"
tip_roundtrip "c/-dash dir" "leading-dash component"
tip_roundtrip "c/new"$'\n'"line" "newline (single-line \$'...' form)"
assert_eq 1 "$(grep -c 'Verify an exclusion with' "$TEST_HOME/out-tip")" "the tip stays on one line even for a newline name"

if [[ "$TESTS_RUN" -eq 0 ]]; then
    echo "FAIL: no assertion was executed" >&2
    exit 1
fi
test_summary
