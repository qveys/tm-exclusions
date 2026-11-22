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
    lnk0*) printf '0\\t%s\\n' "\$last" ;;
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
        # shellcheck disable=SC2030
        export HOME="$B_HOME"
        # shellcheck disable=SC2030
        export PATH="$B_BIN:$PATH"
        # shellcheck disable=SC2030
        export TM_EXCLUSIONS_REPORT="$B_HOME/report.txt"
        # shellcheck disable=SC1090
        source "$B_FUNCS"
        # shellcheck disable=SC1090
        source "$ROOT/locales/${lang}.sh"
        "declare_i18n_${lang}"
        # Optional hook for tests: shell code run after the script is loaded
        # (e.g. to make pwd -P fail).
        if [[ -n "${B_PRELUDE:-}" ]]; then eval "$B_PRELUDE"; fi
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
echo "--- Audit mode (--report-only) and French locale ---"
banner_run "$TEST_HOME/out-audit-dry" report-only 1 0 en c/sz1024
assert_file_contains "$TEST_HOME/out-audit-dry" "Space that would be excluded (simulated): 1.0M" \
    "--report-only with --dry-run: the simulated label wins over 'needing exclusion'"
assert_file_lacks_regex "$TEST_HOME/out-audit-dry" 'Space needing exclusion' "--report-only with --dry-run: no 'needing exclusion' label"
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

echo ""
echo "--- Trailing newline in a name never aliases the neighbouring directory ---"
# A link (and a real dir) named "sz92<LF>" next to a measured "sz92": normalize_path
# captures with $(...) and would drop the trailing newline, so the name used to
# collapse onto "sz92" and show its 92K. Raw-name check first: unmeasured, no du.
mkdir_paths c/sz92 c/emptytarget c/sz93 c/sz93-neighbour
NLT_LINK="c/sz92"$'\n'
ln -s "$B_HOME/c/emptytarget" "$B_HOME/$NLT_LINK"
banner_run "$TEST_HOME/out-nl-link" apply 0 0 en "$NLT_LINK"
OUT="$TEST_HOME/out-nl-link"
assert_file_lacks_regex "$OUT" '92K' "link 'sz92<LF>' does not show the neighbour's 92K"
assert_file_contains "$OUT" "Space excluded: unknown (sizes could not be read)" "link 'sz92<LF>' is counted unmeasured"
assert_eq 0 "$(grep -c 'c/sz92' "$B_DU_CALLS" || true)" "du is never called on the neighbour 'sz92' for the link"
assert_eq 0 "$(wc -l < "$B_DU_CALLS" | tr -d ' ')" "no du call at all for a trailing-newline name"
assert_file_lacks_regex "$B_HOME/report.txt" 'Disk usage total:|Total \(sum of du' \
    "report has no disk-usage figure borrowed from the neighbour"
NLT_DIR="c/sz93"$'\n'
mkdir -p "$B_HOME/$NLT_DIR"
banner_run "$TEST_HOME/out-nl-dir" apply 0 0 en "$NLT_DIR"
assert_file_lacks_regex "$TEST_HOME/out-nl-dir" '93K' "real dir 'sz93<LF>' does not show the neighbour's 93K"
assert_file_contains "$TEST_HOME/out-nl-dir" "Space excluded: unknown (sizes could not be read)" "real dir 'sz93<LF>' is counted unmeasured"
assert_eq 0 "$(wc -l < "$B_DU_CALLS" | tr -d ' ')" "no du call for the trailing-newline real dir"
# Both spellings processed: the neighbour is measured once, the newline name is unmeasured, no key confusion.
banner_run "$TEST_HOME/out-nl-both" apply 0 0 en c/sz92 "$NLT_LINK"
assert_file_contains "$TEST_HOME/out-nl-both" "Space excluded: ≥ 92K (partial, unmeasured paths: 1)" \
    "neighbour counted once, the newline-named link counted unmeasured"
assert_eq 1 "$(grep -Fxc "$B_PHYS/c/sz92" "$B_DU_CALLS")" "neighbour measured exactly once (no cache key confusion)"

echo ""
echo "--- An alias to a newline-named target never aliases the neighbour (#44) ---"
# Rule `path` -> alias -> "small<LF>" (empty) next to a measured "small": the raw
# alias name has no newline, but resolving it drops the target's trailing newline
# in a $(...) capture, so du used to run on the neighbour. Checked on the
# RESOLVED path too; --dry-run, as in the field report.
mkdir_paths c/sz92x c/sz95
NLA_TARGET="c/sz92x"$'\n'
mkdir -p "$B_HOME/$NLA_TARGET"
# The neighbour "sz92x" (made above) is measured by du as 92K, via its name.
ln -s "$B_HOME/$NLA_TARGET" "$B_HOME/c/alias-abs"
ln -s "sz92x"$'\n' "$B_HOME/c/alias-rel"
ln -s "$B_HOME/c/alias-abs" "$B_HOME/c/alias-chain"
NLM_TARGET="c/sz95"$'\n'"b"
mkdir -p "$B_HOME/$NLM_TARGET"
ln -s "$B_HOME/$NLM_TARGET" "$B_HOME/c/alias-mid"
nl_alias_case() {
    local alias_rel="$1" desc="$2" out="$TEST_HOME/out-nla"
    banner_run "$out" apply 1 0 en "$alias_rel"
    assert_file_lacks_regex "$out" 'sz92x|92K|95K' "$desc: nothing borrowed from the neighbour in the output"
    assert_file_contains "$out" "Space that would be excluded (simulated): unknown (sizes could not be read)" \
        "$desc: counted unmeasured in the simulated total"
    assert_eq 0 "$(wc -l < "$B_DU_CALLS" | tr -d ' ')" "$desc: du never called"
    assert_eq 0 "$(grep -Evc '^(isexcluded|listexclusions)$' "$B_ALL" || true)" "$desc: dry-run stayed read-only"
}
nl_alias_case c/alias-abs "absolute alias to 'sz92x<LF>'"
nl_alias_case c/alias-rel "relative alias to 'sz92x<LF>'"
nl_alias_case c/alias-chain "alias of an alias to 'sz92x<LF>'"
nl_alias_case c/alias-mid "alias to a target with a newline in the middle ('sz95<LF>b')"
# Control: the neighbour itself is still measured (the guard is not over-broad).
banner_run "$TEST_HOME/out-nla-ctl" apply 1 0 en c/sz95
assert_file_contains "$TEST_HOME/out-nla-ctl" "Space that would be excluded (simulated): 95K" "control: the real neighbour is measured"

# child of an alias to a newline-named directory (prefix resolution loses the newline)
mkdir -p "$B_HOME/$NLA_TARGET/inner"
nl_alias_case c/alias-abs/inner "child 'inner' of an alias to 'sz92x<LF>'"

echo ""
echo "--- size_path_unsafe: decided per path, no false positives ---"
unsafe_rc() {
    bash -c 'source "$1"; if size_path_unsafe "$2"; then echo unsafe; else echo safe; fi' _ "$B_FUNCS" "$1"
}
ln -s "$B_PHYS/c/sz1024" "$B_HOME/c/plain-link"
assert_eq safe "$(unsafe_rc "$B_PHYS/c/sz1024")" "ordinary physical path is safe"
assert_eq safe "$(unsafe_rc "$B_HOME/c/plain-link")" "link to an ordinary directory is safe"
assert_eq safe "$(unsafe_rc "$B_HOME/c/../c/sz1024")" "path with .. resolving to an ordinary directory is safe"
assert_eq safe "$(unsafe_rc "$B_HOME/c/does-not-exist")" "missing path is safe (nothing to alias)"
assert_eq unsafe "$(unsafe_rc "$B_HOME/c/sz92"$'\n')" "raw name ending in a newline is unsafe"
assert_eq unsafe "$(unsafe_rc "$B_HOME/c/alias-abs")" "alias to 'sz92x<LF>' is unsafe"
assert_eq unsafe "$(unsafe_rc "$B_HOME/c/alias-rel")" "relative alias to 'sz92x<LF>' is unsafe"
assert_eq unsafe "$(unsafe_rc "$B_HOME/c/alias-chain")" "alias of an alias is unsafe"
assert_eq unsafe "$(unsafe_rc "$B_HOME/c/alias-mid")" "alias to 'sz95<LF>b' is unsafe"
assert_eq unsafe "$(unsafe_rc "$B_HOME/c/alias-abs/inner")" "child of an alias to a newline name is unsafe"

echo ""
echo "--- Non-regression: normalize_path and path sets behave exactly as on master ---"
# Frozen verbatim copies of origin/master's normalize_path and du_track_path
# (641ae3d), renamed ref_*: the production functions must give the same output
# AND exit status on a battery of inputs. Committed copies: no git needed in CI.
B_REF="$TEST_HOME/ref.sh"
cat > "$B_REF" <<'REFEOF'
ref_normalize_path() {
    local path="$1" part normalized="" physical
    local -a parts
    IFS='/' read -r -a parts <<< "$path"
    for part in "${parts[@]}"; do
        case "$part" in
            ''|.) ;;
            ..) normalized="${normalized%/*}" ;;
            *) normalized="${normalized}/$part" ;;
        esac
        if [[ -d "${normalized:-/}" ]]; then
            physical="$(cd -P "${normalized:-/}" 2>/dev/null && pwd)" || return 1
            normalized="${physical%/}"
        fi
    done
    printf '%s\n' "${normalized:-/}"
}

ref_du_track_path() {
    local p="$1" entry normalized retained=""
    [[ -z "$p" || ! -e "$p" ]] && return 0
    # Compare physical spellings: symlinked and `..`-relative duplicates must not
    # inflate the total, and stored entries are normalized on the way in too.
    if ! p="$(ref_normalize_path "$p")"; then
        return 0
    fi
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        normalized="$entry"
        if [[ -e "$entry" ]]; then
            normalized="$(ref_normalize_path "$entry")" || normalized="$entry"
        fi
        path_under "$p" "$normalized" && return 0
        if ! path_under "$normalized" "$p"; then retained="${retained}${normalized}
"; fi
    done <<EOF
${DU_PATHS}
EOF
    DU_PATHS="${retained}${p}"
}
REFEOF
mkdir -p "$B_HOME/c/target-dir/sub" "$B_HOME/c/with space"
ln -sf "$B_HOME/c/target-dir" "$B_HOME/c/lnk"
ln -sf "$B_HOME/c/nowhere" "$B_HOME/c/broken"
mkdir -p "$B_HOME/c/gl1" "$B_HOME/c/-x"
battery_run() {
    # $1 = function name; prints "rc|output" for each input, one per line (newlines escaped)
    ( cd "$B_HOME" && bash -c '
        source "$1"; source "$2"; fn="$3"; shift 3
        for x in "$@"; do
            rc=0; out="$("$fn" "$x" 2>/dev/null)" || rc=$?
            printf "%s|%q\n" "$rc" "$out"
        done' _ "$B_FUNCS" "$B_REF" "$1" \
        "$B_HOME/c/sz1024" "c/sz1024" "$B_HOME/c/../c/sz1024" "./c" "$B_HOME//c///sz1024" "$B_HOME/c/sz1024/" \
        "$B_HOME/c/lnk" "$B_HOME/c/lnk/sub" "$B_HOME/c/lnk/../sz1024" "$B_HOME/c/broken" "$B_HOME/c/missing/x" \
        "" "~" "$B_HOME/c/with space" "$B_HOME/c/gl*" "-x" "c/-x" "/" "/." "/.." "$B_HOME/c/alias-abs" \
        "$B_HOME/c/alias-rel" "$B_HOME/c/alias-chain" "$B_HOME/c/alias-mid" "$B_HOME/c/sz92"$'\n' )
}
battery_run ref_normalize_path > "$TEST_HOME/battery-ref"
battery_run normalize_path > "$TEST_HOME/battery-pr"
assert_true "normalize_path output and exit status match master on every battery input" \
    cmp -s "$TEST_HOME/battery-ref" "$TEST_HOME/battery-pr"
assert_true "the battery actually ran (25 inputs, incl. empty, ~, glob, -x, newline names)" \
    test "$(wc -l < "$TEST_HOME/battery-pr" | tr -d ' ')" -eq 25
# pwd -P failure must surface as exit 1 (never masked)
pwdfail_rc() {
    bash -c 'source "$1"; source "$2"; pwd() { return 1; }; rc=0; "$3" "$4" >/dev/null 2>&1 || rc=$?; echo $rc' _ "$B_FUNCS" "$B_REF" "$1" "$B_PHYS/c/sz1024"
}
assert_eq 1 "$(pwdfail_rc ref_normalize_path)" "reference: failing pwd -> exit 1"
assert_eq 1 "$(pwdfail_rc normalize_path)" "normalize_path: failing pwd -> exit 1 (like master)"
# DU_PATHS bookkeeping: same set as master's du_track_path for ordinary paths
du_paths_run() {
    bash -c '
        source "$1"; source "$2"; fn="$3"; shift 3; DU_PATHS=""
        for x in "$@"; do "$fn" "$x"; done
        printf "%q\n" "$DU_PATHS"' _ "$B_FUNCS" "$B_REF" "$1" \
        "$B_HOME/c/sz100/sz50" "$B_HOME/c/sz100" "$B_HOME/c/lnk" "$B_HOME/c/target-dir/sub" "$B_HOME/c/with space" \
        "$B_HOME/c/missing" "$B_HOME/c/sz1024" "$B_HOME/c/../c/sz1024"
}
assert_eq "$(du_paths_run ref_du_track_path)" "$(du_paths_run du_track_path)" "du_track_path keeps master's DU_PATHS set for ordinary paths"

echo ""
echo "--- Security: keep protects an alias to a newline-named directory (as master) ---"
mkdir -p "$B_HOME/c/protect"$'\n'"/saved" "$B_HOME/c/protect/saved"
ln -sfn "$B_HOME/c/protect"$'\n' "$B_HOME/c/kalias"
KEEP_RULES="$B_HOME/keep-rules"
# shellcheck disable=SC2016
printf 'keep|$HOME/c/kalias/saved|protected\npath|$HOME/c/kalias/saved|same target\n' > "$KEEP_RULES"
# One report file per invocation (removed first) and a checked exit status: an
# early abort can then neither be masked nor leave a previous scenario's report
# or an already-empty mutation log to pass the assertions.
KEEP_RC=0
keep_cli() {
    local out="$1"
    shift
    : > "$B_CALLS"
    rm -f "${out}.report"
    KEEP_RC=0
    # shellcheck disable=SC2031
    env HOME="$B_HOME" PATH="$B_BIN:$PATH" TM_EXCLUSIONS_DEFAULT_CONF="$KEEP_RULES" \
        TM_EXCLUSIONS_REPORT="${out}.report" TM_EXCLUSIONS_SKIP_DU=1 \
        bash "$TM_EXCLUSIONS" "$@" > "$out" 2>/dev/null || KEEP_RC=$?
}
keep_cli "$TEST_HOME/keep-apply" --dry-run
assert_eq 0 "$KEEP_RC" "keep via alias: --dry-run exits 0"
assert_true "keep via alias: --dry-run wrote its own report" test -s "$TEST_HOME/keep-apply.report"
assert_eq 0 "$(wc -l < "$B_CALLS" | tr -d ' ')" "keep via alias: no mutation call"
assert_file_lacks_regex "$TEST_HOME/keep-apply.report" '^(WOULD|ADD|NEED) .*c/(kalias|protect)' "keep via alias: the protected path is never planned for exclusion"
assert_file_contains "$TEST_HOME/keep-apply.report" "KEEP  " "keep via alias: the protected path is reported as kept"
keep_cli "$TEST_HOME/keep-apply-real"
assert_eq 0 "$KEEP_RC" "keep via alias: apply mode exits 0"
assert_true "keep via alias: apply mode wrote its own report" test -s "$TEST_HOME/keep-apply-real.report"
assert_file_contains "$TEST_HOME/keep-apply-real.report" "KEEP  " "keep via alias: apply mode reports the path as kept"
assert_eq 0 "$(grep -c '^addexclusion' "$B_CALLS" || true)" "keep via alias: apply mode never calls addexclusion"
keep_cli "$TEST_HOME/keep-uninstall" --uninstall --force --dry-run
assert_eq 0 "$KEEP_RC" "keep via alias: forced simulated uninstall exits 0"
assert_true "keep via alias: uninstall wrote its own report" test -s "$TEST_HOME/keep-uninstall.report"
assert_file_lacks_regex "$TEST_HOME/keep-uninstall.report" '^(WOULD_REMOVE|REMOVE) .*c/(kalias|protect)' "keep via alias: forced simulated uninstall removes nothing under the protected path"
assert_file_contains "$TEST_HOME/keep-uninstall.report" "KEEP  " "keep via alias: uninstall still reports the path as kept"
assert_eq 0 "$(wc -l < "$B_CALLS" | tr -d ' ')" "keep via alias: uninstall makes no mutation call"

echo ""
echo "--- A failing physical resolution is unmeasured, never a raw-path fallback ---"
# pwd -P fails while plain pwd works: normalize_path (plain pwd) would still
# resolve the alias to the neighbouring 'sz92x' and du would measure it.
# shellcheck disable=SC2016
B_PRELUDE='pwd() { if [ "${1:-}" = "-P" ]; then return 1; fi; builtin pwd "$@"; }' \
    banner_run "$TEST_HOME/out-pwdfail" apply 1 0 en c/alias-abs
assert_file_lacks_regex "$TEST_HOME/out-pwdfail" 'sz92x|92K' "pwd -P failing: nothing borrowed from the neighbour"
assert_file_contains "$TEST_HOME/out-pwdfail" "Space that would be excluded (simulated): unknown (sizes could not be read)" \
    "pwd -P failing on a link: counted unmeasured, no raw-path fallback"
assert_eq 0 "$(wc -l < "$B_DU_CALLS" | tr -d ' ')" "pwd -P failing: du never called"

echo ""
echo "--- An alias redirected between two rules is re-decided (no stale answer) ---"
mkdir -p "$B_HOME/c/redir-target-ok"
ln -sfn "$B_HOME/c/sz1024" "$B_HOME/c/redir"
: > "$B_DU_CALLS"
(
    # shellcheck disable=SC2031
    export HOME="$B_HOME" TM_EXCLUSIONS_REPORT="$B_HOME/report.txt"
    # shellcheck disable=SC2030,SC2031
    export PATH="$B_BIN:$PATH"
    # shellcheck disable=SC1090
    source "$B_FUNCS"
    # shellcheck disable=SC1090
    source "$ROOT/locales/en.sh"
    declare_i18n_en
    # shellcheck disable=SC2034
    MODE=apply DRY_RUN=1 QUIET=0 UI=1 HAS_TMUTIL=1
    process_path "$B_HOME/c/redir"
    ln -sfn "$B_HOME/$NLA_TARGET" "$B_HOME/c/redir"
    process_path "$B_HOME/c/redir"
    generate_report
) > "$TEST_HOME/out-redir" 2>&1 || true
assert_file_contains "$TEST_HOME/out-redir" "Space that would be excluded (simulated): ≥ 1.0M (partial, unmeasured paths: 1)" \
    "second rule on the redirected alias is unmeasured, the first stays exact"
assert_file_lacks_regex "$TEST_HOME/out-redir" '92K' "redirected alias never shows the neighbour's 92K"
assert_eq 0 "$(grep -c 'c/sz92x' "$B_DU_CALLS" || true)" "du never called on the neighbour after the redirect"

echo ""
echo "--- Nesting by file identity: link / case spellings of one directory count once ---"
# (1) Portable (case-sensitive GNU/Linux CI included): a link spelling and the
# real spelling of the same directory, in every order. Total = the directory once.
mkdir -p "$B_HOME/c/sz100id/sz20id"
ln -sfn sz100id "$B_HOME/c/Link100"
banner_run "$TEST_HOME/out-id-fwd" apply 1 0 en c/Link100 c/sz100id/sz20id
assert_file_contains "$TEST_HOME/out-id-fwd" "Space that would be excluded (simulated): 100K" "link spelling then child: directory counted once (100K)"
banner_run "$TEST_HOME/out-id-rev" apply 1 0 en c/sz100id/sz20id c/Link100
assert_file_contains "$TEST_HOME/out-id-rev" "Space that would be excluded (simulated): 100K" "child then link spelling: directory counted once (100K)"
banner_run "$TEST_HOME/out-id-same" apply 1 0 en c/Link100 c/sz100id
assert_file_contains "$TEST_HOME/out-id-same" "Space that would be excluded (simulated): 100K" "one directory through two spellings: counted once (100K)"
banner_run "$TEST_HOME/out-id-two" apply 1 0 en c/sz100id c/sz1024
assert_file_contains "$TEST_HOME/out-id-two" "Space that would be excluded (simulated): 1.1M" "control: two unrelated directories still add up (100K + 1024K)"
banner_run "$TEST_HOME/out-id-gone" apply 1 0 en c/sz100id c/does-not-exist
assert_file_contains "$TEST_HOME/out-id-gone" "Space that would be excluded (simulated): 100K" "a missing path is ignored (no crash, no size)"
# A symlink to a FILE is a distinct measurement: du -sk measures the link itself
# (0K), not the 8M target. -ef would call them "the same object" and keep only the
# link's 0K.
: > "$B_HOME/c/sz8192file"
ln -sfn sz8192file "$B_HOME/c/lnk0"
banner_run "$TEST_HOME/out-fl-fwd" apply 1 0 en c/lnk0 c/sz8192file
assert_file_contains "$TEST_HOME/out-fl-fwd" "Space that would be excluded (simulated): 8.0M" "file link then its 8M target file: 8.0M (link 0K + file 8M)"
banner_run "$TEST_HOME/out-fl-rev" apply 1 0 en c/sz8192file c/lnk0
assert_file_contains "$TEST_HOME/out-fl-rev" "Space that would be excluded (simulated): 8.0M" "target file then its link: 8.0M"
assert_eq 1 "$(grep -c 'lnk0' "$B_DU_CALLS")" "both spellings were measured (the link is not dropped as 'the same object')"
# Link to a DIRECTORY (du follows nothing, but normalize_path resolves it): unchanged, counted once.
banner_run "$TEST_HOME/out-dl-fwd" apply 1 0 en c/Link100 c/sz100id
assert_file_contains "$TEST_HOME/out-dl-fwd" "Space that would be excluded (simulated): 100K" "directory link then its directory: counted once (100K)"
banner_run "$TEST_HOME/out-dl-rev" apply 1 0 en c/sz100id c/Link100
assert_file_contains "$TEST_HOME/out-dl-rev" "Space that would be excluded (simulated): 100K" "directory then its link: counted once (100K)"
# (2) Case-insensitive file systems (default APFS on macOS): "sz100CS" and "sz100cs" are one directory.
mkdir -p "$B_HOME/c/CaseProbe"
if [[ -d "$B_HOME/c/caseprobe" ]]; then
    mkdir -p "$B_HOME/c/sz100cs/sz20cs"
    banner_run "$TEST_HOME/out-ci-fwd" apply 1 0 en c/sz100CS c/sz100cs/sz20cs
    assert_file_contains "$TEST_HOME/out-ci-fwd" "Space that would be excluded (simulated): 100K" "case-insensitive FS: 'sz100CS' then 'sz100cs/sz20cs' counted once (100K)"
    banner_run "$TEST_HOME/out-ci-rev" apply 1 0 en c/sz100cs/sz20cs c/sz100CS
    assert_file_contains "$TEST_HOME/out-ci-rev" "Space that would be excluded (simulated): 100K" "case-insensitive FS: child then 'sz100CS' counted once (100K)"
    banner_run "$TEST_HOME/out-ci-same" apply 1 0 en c/sz100CS c/sz100cs
    assert_file_contains "$TEST_HOME/out-ci-same" "Space that would be excluded (simulated): 100K" "case-insensitive FS: 'sz100CS' and 'sz100cs' are one directory (100K)"
else
    echo "  INFO case-sensitive file system: the case-spelling check is covered by the link-spelling tests above"
fi

echo ""
echo "--- Cost: cd -P resolutions vs master (frozen reference), deterministic count ---"
# Master's size bookkeeping per processed path is ref_du_track_path + the one
# normalize_path of path_size_column; with no keep and a path under HOME nothing
# else in process_path resolves. 25 distinct ordinary paths, dry-run. Counting
# is a cd wrapper logging each call (functions are inherited by $(...)).
COST_ROOT="$B_PHYS/cost"
mkdir -p "$COST_ROOT"
for i in $(seq 1 25); do mkdir -p "$COST_ROOT/proj$i/node_modules/cache"; done
cost_paths() { for i in $(seq 1 25); do printf '%s\n' "$COST_ROOT/proj$i/node_modules/cache"; done; }
# Each helper writes its count to a file and returns the pipeline's status (never
# masked by wc): a run that processed nothing cannot satisfy the bound.
cd_calls_master() {
    local cnt="$TEST_HOME/cd.master" rc=0
    : > "$cnt"
    cost_paths | CD_LOG="$cnt" bash -c '
        source "$1"; source "$2"; DU_PATHS=""
        cd() { echo x >> "$CD_LOG"; builtin cd "$@"; }
        while IFS= read -r p; do
            ref_du_track_path "$p"
            np="$(ref_normalize_path "$p")"
        done' _ "$B_FUNCS" "$B_REF" || rc=$?
    return "$rc"
}
cd_calls_pr() {
    local cnt="$TEST_HOME/cd.pr" rc=0
    : > "$cnt"
    : > "$B_DU_CALLS"
    # shellcheck disable=SC2031
    cost_paths | HOME="$B_PHYS" PATH="$B_BIN:$PATH" CD_LOG="$cnt" bash -c '
        source "$1"; source "$2/locales/en.sh"; declare_i18n_en
        cd() { echo x >> "$CD_LOG"; builtin cd "$@"; }
        MODE=apply; DRY_RUN=1; QUIET=1; UI=0; HAS_TMUTIL=1
        while IFS= read -r p; do process_path "$p"; done' _ "$B_FUNCS" "$ROOT" >/dev/null 2>&1 || rc=$?
    return "$rc"
}
MASTER_RC=0
PR_RC=0
cd_calls_master || MASTER_RC=$?
cd_calls_pr || PR_RC=$?
COST_MASTER="$(wc -l < "$TEST_HOME/cd.master" | tr -d ' ')"
COST_PR="$(wc -l < "$TEST_HOME/cd.pr" | tr -d ' ')"
assert_eq 0 "$MASTER_RC" "cost: the frozen master bookkeeping run succeeded"
assert_eq 0 "$PR_RC" "cost: the real process_path run over the 25 paths succeeded"
# process_path must really have measured every path (fresh du log, 25 distinct entries).
assert_eq 25 "$(sort -u "$B_DU_CALLS" | wc -l | tr -d ' ')" "cost: du was fed by 25 distinct processed paths"
assert_true "baseline sanity: the frozen master bookkeeping resolves prefixes ($COST_MASTER cd calls)" test "$COST_MASTER" -gt 100
assert_true "the PR run resolved prefixes too ($COST_PR cd calls > 0), so the bound below is not vacuous" test "$COST_PR" -gt 0
assert_true "dry-run cd -P calls on 25 ordinary paths: PR ($COST_PR) <= master ($COST_MASTER) + 10" \
    test "$COST_PR" -le $((COST_MASTER + 10))

echo ""
echo "--- Documented options exist and the documented modes run ---"
HELP_OUT="$(bash "$TM_EXCLUSIONS" --help 2>&1 || true)"
doc_options() {
    {
        awk '/The final summary is a banner/{f=1} f{print} f&&/^$/{exit}' "$ROOT/README.md"
        grep -F '[#44]' "$ROOT/CHANGELOG.md" | head -n 1
        awk '/^### End-of-run banner/{f=1;next} f&&NF{print;exit}' "$ROOT/docs/ARCHITECTURE.md"
    } | grep -oE -e '--[a-z][a-z-]*' | sort -u
}
DOC_OPTS="$(doc_options)"
assert_true "the #44 docs mention command-line options (extraction works)" test -n "$DOC_OPTS"
while IFS= read -r opt; do
    [[ -n "$opt" ]] || continue
    # Whole option name: "--report" must not match "--report-only".
    assert_true "documented option $opt is listed by --help" grep -qE -e "(^|[^a-z-])${opt}([^a-z-]|\$)" <<<"$HELP_OUT"
done <<<"$DOC_OPTS"
assert_exit_code 0 "documented --report-only run exits 0" cli_run "$TEST_HOME/cli-audit" --report-only
assert_file_contains "$B_HOME/cli-report.txt" "Space needing exclusion: 2.0M" "documented --report-only labels the space as needing exclusion"
assert_exit_code 1 "the former wrong spelling --report is rejected (docs must not use it)" cli_run "$TEST_HOME/cli-badopt" --report

if [[ "$TESTS_RUN" -eq 0 ]]; then
    echo "FAIL: no assertion was executed" >&2
    exit 1
fi
test_summary
