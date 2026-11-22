#!/usr/bin/env bash
# test_end_banner.sh — interactive end-of-run summary banner (#44): counters,
# cumulative space excluded in readable units, report path, verification tip;
# hidden by --quiet; simulated wording in --dry-run (no mutation); 0 exclusions;
# unreadable sizes flagged as partial/unknown instead of a false total.
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
B_DU_CALLS="$TEST_HOME/du.calls"
mkdir -p "$B_HOME/.config/tm_exclusions" "$B_BIN"
: > "$B_HOME/.config/tm_exclusions/custom.conf"

# tmutil stub: records mutations; paths named *already* are reported excluded.
cat > "$B_BIN/tmutil" <<STUB
#!/bin/sh
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
assert_file_contains "$OUT" "tmutil isexcluded <path>" "banner shows the verification tip"
assert_eq 1 "$(grep -Fc 'Report saved to:' "$OUT")" "report path is printed once"
assert_file_lacks_regex "$OUT" 'Simulated run' "apply run is not labelled simulated"
assert_eq 2 "$(grep -c '^addexclusion ' "$B_CALLS")" "exactly the two new paths were really excluded"
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

echo ""
echo "--- --quiet: no banner ---"
banner_run "$TEST_HOME/out-quiet" apply 0 1 en c/sz1023 c/sz1024
OUT="$TEST_HOME/out-quiet"
assert_file_lacks_regex "$OUT" 'Summary' "quiet prints no banner heading"
assert_file_lacks_regex "$OUT" 'tmutil isexcluded <path>' "quiet prints no verification tip"
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
: > "$B_CALLS"
assert_exit_code 0 "CLI --quiet --dry-run exits 0" cli_run "$TEST_HOME/cli-quiet" --quiet --dry-run
assert_file_lacks_regex "$TEST_HOME/cli-quiet" 'tmutil isexcluded <path>' "CLI --quiet shows no banner tip"
assert_file_lacks_regex "$TEST_HOME/cli-quiet" '📊' "CLI --quiet shows no banner glyph"
assert_exit_code 0 "CLI --dry-run exits 0" cli_run "$TEST_HOME/cli-dry" --dry-run
assert_file_contains "$B_HOME/cli-report.txt" "Space that would be excluded (simulated): 2.0M" \
    "CLI report carries the simulated space (same figure as the banner)"
assert_eq 0 "$(wc -l < "$B_CALLS" | tr -d ' ')" "CLI --dry-run called no tmutil mutation"

echo ""
echo "--- Zero exclusions ---"
banner_run "$TEST_HOME/out-zero" apply 0 0 en c/sz3000-already c/missing-two
OUT="$TEST_HOME/out-zero"
assert_file_contains "$OUT" "Newly excluded: 0" "zero exclusions: counter is 0"
assert_file_contains "$OUT" "Space excluded: 0K" "zero exclusions: space is 0K, not blank"
assert_file_contains "$OUT" "tmutil isexcluded <path>" "zero exclusions: banner still shows the tip"
banner_run "$TEST_HOME/out-none" apply 0 0 en
assert_file_contains "$TEST_HOME/out-none" "Space excluded: 0K" "no path at all: space is 0K"

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
assert_file_contains "$OUT" "Vérifier une exclusion avec : tmutil isexcluded <path>" "French verification tip"

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
assert_file_contains "$TEST_HOME/out-nodu" "tmutil isexcluded <path>" "SKIP_DU still shows the rest of the banner"

if [[ "$TESTS_RUN" -eq 0 ]]; then
    echo "FAIL: no assertion was executed" >&2
    exit 1
fi
test_summary
