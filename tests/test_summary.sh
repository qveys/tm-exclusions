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

echo ""
echo "--- real helper output formats ---"
# A suite that uses the real tests/test_helpers.sh, so the failure output has
# exactly the shapes the helpers print: multi-line "Output was:" (with a bare
# ---), an unindented file tail after FAIL, and run_cli's cat before FAIL
# around a blank line.
cat > "$WORK/fake_cli.sh" <<'EOF'
#!/usr/bin/env bash
printf 'context-before-blank\n\nafter-blank-line\n'
exit 3
EOF
printf 'tail-line-1\nsecret-marker-ZZ\n' > "$WORK/some.file"
cat > "$WORK/real.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "${ROOT}/tests/test_helpers.sh"
TM_EXCLUSIONS="$WORK/fake_cli.sh"
assert_eq "x" "x" "hidden-pass-desc"
assert_output_contains "no-such-text" "multiline-output-case" \\
    printf 'alpha-marker\nbeta-marker\n---\ngamma-marker\n'
assert_eq "x" "x" "hidden-pass-desc-2"
assert_file_contains "$WORK/some.file" "absent-text" "file-tail-case"
assert_eq "x" "x" "hidden-pass-desc-3"
run_cli 0 "$WORK/cli.log" --whatever || true
assert_eq "x" "x" "hidden-pass-desc-4"
test_summary
EOF
rc=0
run_runner "$WORK/real.out" "$WORK/real.sh" || rc=$?
assert_eq "1" "$rc" "real helpers: exit code 1"
assert_file_contains "$WORK/real.out" "FAILED: 7 total, 4 passed, 3 failed (1 of 1 suites)" \
    "real helpers: totals"
assert_file_contains "$WORK/real.out" "FAIL multiline-output-case" "real helpers: assert_output_contains FAIL listed"
assert_file_contains "$WORK/real.out" "alpha-marker" "real helpers: multi-line output, first line"
assert_file_contains "$WORK/real.out" "beta-marker" "real helpers: multi-line output, second line"
assert_file_contains "$WORK/real.out" "gamma-marker" "real helpers: multi-line output, line after bare ---"
assert_file_contains "$WORK/real.out" "FAIL file-tail-case" "real helpers: assert_file_contains FAIL listed"
assert_file_contains "$WORK/real.out" "secret-marker-ZZ" "real helpers: unindented file tail after FAIL"
assert_file_contains "$WORK/real.out" "CLI exit 3 (expected 0)" "real helpers: run_cli FAIL listed"
assert_file_contains "$WORK/real.out" "context-before-blank" "real helpers: run_cli context before FAIL across a blank line"
assert_file_contains "$WORK/real.out" "after-blank-line" "real helpers: run_cli context after the blank line"
assert_file_lacks_regex "$WORK/real.out" "hidden-pass-desc" "real helpers: PASS lines stay hidden"
assert_file_lacks_regex "$WORK/real.out" "Tests run:" "real helpers: suite totals box dropped"

echo ""
echo "--- no suite to run ---"
# Same layout as the repo with only the helper in tests/: the runner locates
# tests/ relative to itself, so run a copy of it there.
mkdir -p "$WORK/empty/scripts" "$WORK/empty/tests"
cp "$RUNNER" "$WORK/empty/scripts/test-summary.sh"
cp "${ROOT}/tests/test_helpers.sh" "$WORK/empty/tests/test_helpers.sh"
rc=0
bash "$WORK/empty/scripts/test-summary.sh" > "$WORK/empty.out" 2>&1 || rc=$?
assert_eq "1" "$rc" "no suite: exit code 1 (nothing verified is not a pass)"
assert_file_contains "$WORK/empty.out" "FAILED: 0 total, 0 passed, 0 failed (0 suites)" \
    "no suite: coherent 0/0/0 summary"
assert_file_lacks_regex "$WORK/empty.out" "unbound" "no suite: no unbound-variable error"

test_summary
