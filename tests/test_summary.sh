#!/usr/bin/env bash
# test_summary.sh — scripts/test-summary.sh on fake passing/failing/crashing suites.
set -euo pipefail

SUMMARY_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/test_helpers.sh
source "${SUMMARY_TEST_DIR}/test_helpers.sh"

RUNNER="${ROOT}/scripts/test-summary.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "test-summary runner tests"
echo "========================================"

# Fake suites emit the same PASS/FAIL line format as tests/test_helpers.sh.
cat > "$WORK/ok.sh" <<'EOF'
#!/usr/bin/env bash
printf '  PASS first\n  PASS second\n'
EOF
cat > "$WORK/bad.sh" <<'EOF'
#!/usr/bin/env bash
printf '  PASS good one\n'
printf 'diagnostic line before failure\n' >&2
printf '  FAIL broken one (expected exit 0, got 3)\n'
printf '    Output was: boom\n'
printf '  PASS good two\n'
exit 1
EOF
cat > "$WORK/crash.sh" <<'EOF'
#!/usr/bin/env bash
printf '  PASS before crash\n'
echo "unexpected crash message" >&2
exit 2
EOF

run_runner() {
    local out="$1"
    shift
    local rc=0
    bash "$RUNNER" "$@" > "$out" 2>&1 || rc=$?
    return "$rc"
}

echo ""
echo "--- all suites pass ---"
rc=0
run_runner "$WORK/ok.out" "$WORK/ok.sh" || rc=$?
assert_eq "0" "$rc" "passing suite: exit code 0"
assert_file_contains "$WORK/ok.out" "OK: 2 total, 2 passed, 0 failed (1 suites)" \
    "passing suite: compact OK summary"
assert_file_lacks_regex "$WORK/ok.out" "PASS first" \
    "passing suite: individual PASS lines are not echoed"

echo ""
echo "--- a failing suite ---"
rc=0
run_runner "$WORK/bad.out" "$WORK/ok.sh" "$WORK/bad.sh" || rc=$?
assert_eq "1" "$rc" "failing suite: exit code 1"
assert_file_contains "$WORK/bad.out" "FAILED: 5 total, 4 passed, 1 failed (1 of 2 suites)" \
    "failing suite: totals (2 + 2 passed across both suites, one failure)"
assert_file_contains "$WORK/bad.out" "FAIL bad.sh (exit 1, 1 failed)" \
    "failing suite: names the failing suite"
assert_file_contains "$WORK/bad.out" "FAIL broken one (expected exit 0, got 3)" \
    "failing suite: lists the failed assertion"
assert_file_contains "$WORK/bad.out" "Output was: boom" \
    "failing suite: shows the failure output"
assert_file_contains "$WORK/bad.out" "diagnostic line before failure" \
    "failing suite: shows the diagnostics printed before the failure"
assert_file_lacks_regex "$WORK/bad.out" "good (one|two)|first|second" \
    "failing suite: passing assertions stay hidden"

echo ""
echo "--- a suite crashing without a FAIL line ---"
rc=0
run_runner "$WORK/crash.out" "$WORK/crash.sh" || rc=$?
assert_eq "1" "$rc" "crashing suite: exit code 1"
assert_file_contains "$WORK/crash.out" "FAIL crash.sh (exit 2, 0 failed)" \
    "crashing suite: reported with its exit status"
assert_file_contains "$WORK/crash.out" "unexpected crash message" \
    "crashing suite: shows the tail of its output"
assert_file_contains "$WORK/crash.out" "FAILED: 2 total, 1 passed, 1 failed (1 of 1 suites)" \
    "crashing suite: counted as one failure"

test_summary
