#!/usr/bin/env bash
# test-summary.sh — run the test suites quietly and print a concise summary.
#
# Usage: scripts/test-summary.sh [suite.sh ...]
#   No argument: every tests/*.sh suite except the shared helper
#   (tests/test_helpers.sh), i.e. the same set `make test` runs.
#
# The suites are run unmodified; their `  PASS ...` / `  FAIL ...` result lines
# (see tests/test_helpers.sh) are counted and only the failures are shown, with
# the diagnostic output printed just before or after each one. A suite that
# exits non-zero without printing any FAIL line (crash under `set -e`, syntax
# error, ...) is reported as failed with the tail of its output.
#
# Exit status of this script: 0 when every suite passed, 1 otherwise (including
# when no suite was found: nothing verified is not a pass). Through `make`, a
# failure shows as a nonzero status (GNU make reports 2 for a failed recipe).
# Counts come from each suite's own "Tests run: N  Passed: N  Failed: N" line
# when present, else from its `  PASS` / `  FAIL` result lines.
# Bash 3.2 compatible.

set -uo pipefail

ROOT="$(
    source_dir="$(dirname -- "${BASH_SOURCE[0]}")" || exit 1
    [[ "$source_dir" != -* ]] || source_dir="./$source_dir"
    CDPATH='' cd -P -- "${source_dir}/.." >/dev/null 2>&1 && pwd
)"
TAIL_LINES=15

suites=()
if [[ $# -gt 0 ]]; then
    suites=("$@")
else
    for f in "$ROOT"/tests/*.sh; do
        # Without nullglob an empty tests/ leaves the pattern itself in $f.
        [[ -f "$f" ]] || continue
        [[ "$(basename "$f")" = "test_helpers.sh" ]] && continue
        suites+=("$f")
    done
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

total=0
passed=0
failed=0
failed_suites=0
details="$WORK/details"
: > "$details"

# Print each FAIL line of a suite log with the raw output around it: every
# non-result line since the previous PASS/FAIL line (at most BEFORE_MAX, e.g. the
# `cat` run_cli does before its FAIL line) and every one up to the next
# PASS/FAIL line (at most AFTER_MAX, e.g. the `tail -n 40` of assert_file_contains
# or the continuation lines of a multi-line "Output was:"). Each log line is
# printed once, in order. Suite section banners and the final totals box are
# dropped; blank lines and a bare `---` from real output are kept.
BEFORE_MAX=20
AFTER_MAX=40
extract_failures() {
    awk -v bmax="$BEFORE_MAX" -v amax="$AFTER_MAX" '
        /^  PASS / { buf = ""; nbuf = 0; after = 0; next }
        /^  FAIL / {
            if (nbuf > 0) printf "%s", buf
            print
            buf = ""; nbuf = 0; after = 1; nafter = 0; next
        }
        /^--- .* ---$/ || /^=+$/ || /^Tests run:/ { next }
        after && nafter < amax { print; nafter++; next }
        {
            buf = buf $0 "\n"; nbuf++
            if (nbuf > bmax) { sub(/^[^\n]*\n/, "", buf); nbuf-- }
        }
    ' "$1"
}

nsuites=${#suites[@]}
# Nothing to run (e.g. tests/ holds only the helper): fail loudly rather than
# report a green "0 failed" for a run that verified nothing.
if [[ "$nsuites" -eq 0 ]]; then
    printf 'FAILED: 0 total, 0 passed, 0 failed (0 suites) - no test suite found\n'
    exit 1
fi

for suite in "${suites[@]}"; do
    name="$(basename "$suite")"
    log="$WORK/$name.log"
    rc=0
    bash "$suite" > "$log" 2>&1 || rc=$?

    # Prefer the suite's own totals line (test_summary in tests/test_helpers.sh,
    # printed last): counting `  PASS`/`  FAIL` lines would also count one
    # embedded in a multi-line value a helper printed. The log is never a TTY,
    # so the line carries no colour codes. A suite that crashed or does not
    # use test_summary has no such line: fall back to counting result lines.
    totals=$(sed -n 's/^Tests run: \([0-9][0-9]*\)  Passed: \([0-9][0-9]*\)  Failed: \([0-9][0-9]*\)$/\2 \3/p' "$log" | tail -n 1)
    if [[ -n "$totals" ]]; then
        p=${totals% *}
        f=${totals#* }
    else
        p=$(grep -c '^  PASS ' "$log" || true)
        f=$(grep -c '^  FAIL ' "$log" || true)
    fi
    total=$((total + p + f))
    passed=$((passed + p))
    failed=$((failed + f))

    if [[ "$f" -gt 0 || "$rc" -ne 0 ]]; then
        failed_suites=$((failed_suites + 1))
        {
            printf 'FAIL %s (exit %d, %d failed)\n' "$name" "$rc" "$f"
            if [[ "$f" -gt 0 ]]; then
                extract_failures "$log" | sed 's/^/  | /'
            else
                # Crash without a FAIL line: count it as one failure so the
                # totals never read "0 failed" next to a non-zero exit.
                failed=$((failed + 1))
                total=$((total + 1))
                tail -n "$TAIL_LINES" "$log" | sed 's/^/  | /'
            fi
        } >> "$details"
    fi
done

if [[ "$failed" -gt 0 || "$failed_suites" -gt 0 ]]; then
    cat "$details"
    printf 'FAILED: %d total, %d passed, %d failed (%d of %d suites)\n' \
        "$total" "$passed" "$failed" "$failed_suites" "$nsuites"
    exit 1
fi

printf 'OK: %d total, %d passed, 0 failed (%d suites)\n' \
    "$total" "$passed" "$nsuites"
exit 0
