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
# Exit status: 0 when every suite passed, 1 otherwise.
# Bash 3.2 compatible.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAIL_LINES=15

suites=()
if [[ $# -gt 0 ]]; then
    suites=("$@")
else
    for f in "$ROOT"/tests/*.sh; do
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

# Print each FAIL line of a suite log together with its diagnostic context:
# the non-result lines printed since the previous result/section line, plus
# the indented lines that follow it.
extract_failures() {
    awk '
        /^  PASS / { buf = ""; after = 0; next }
        /^  FAIL / {
            if (buf != "") printf "%s", buf
            print
            buf = ""; after = 1; next
        }
        /^$/ || /^---/ || /^====/ { buf = ""; after = 0; next }
        after && /^    / { print; next }
        { after = 0; buf = buf $0 "\n" }
    ' "$1"
}

for suite in "${suites[@]}"; do
    name="$(basename "$suite")"
    log="$WORK/$name.log"
    rc=0
    bash "$suite" > "$log" 2>&1 || rc=$?

    p=$(grep -c '^  PASS ' "$log" || true)
    f=$(grep -c '^  FAIL ' "$log" || true)
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
        "$total" "$passed" "$failed" "$failed_suites" "${#suites[@]}"
    exit 1
fi

printf 'OK: %d total, %d passed, 0 failed (%d suites)\n' \
    "$total" "$passed" "${#suites[@]}"
exit 0
