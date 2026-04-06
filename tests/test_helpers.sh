#!/usr/bin/env bash
# test_helpers.sh — Shared test utilities for tm-exclusions smoke tests
# Source this file from test scripts.

set -euo pipefail

# Path to the main script under test
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Exported for use by test scripts that source this file
# shellcheck disable=SC2034
TM_EXCLUSIONS="${SCRIPT_DIR}/tm_exclusions.sh"

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Colors (if terminal supports them)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    # shellcheck disable=SC2034
    YELLOW=''
    NC=''
fi

# Assert that a command exits with the expected code
# Usage: assert_exit_code <expected_code> <description> <command> [args...]
assert_exit_code() {
    local expected="$1"
    local desc="$2"
    shift 2
    TESTS_RUN=$((TESTS_RUN + 1))

    local actual=0
    "$@" >/dev/null 2>&1 || actual=$?

    if [[ "${actual}" -eq "${expected}" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        printf "${GREEN}  PASS${NC} %s\n" "$desc"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        printf "${RED}  FAIL${NC} %s (expected exit %d, got %d)\n" "$desc" "$expected" "$actual"
    fi
}

# Assert that command output contains a string
# Usage: assert_output_contains <expected_string> <description> <command> [args...]
assert_output_contains() {
    local expected="$1"
    local desc="$2"
    shift 2
    TESTS_RUN=$((TESTS_RUN + 1))

    local output
    output="$("$@" 2>&1)" || true

    if echo "$output" | grep -q -- "$expected"; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        printf "${GREEN}  PASS${NC} %s\n" "$desc"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        printf "${RED}  FAIL${NC} %s (output did not contain '%s')\n" "$desc" "$expected"
        printf "    Output was: %s\n" "$output"
    fi
}

# Assert that command output does NOT contain a string
# Usage: assert_output_not_contains <unexpected_string> <description> <command> [args...]
assert_output_not_contains() {
    local unexpected="$1"
    local desc="$2"
    shift 2
    TESTS_RUN=$((TESTS_RUN + 1))

    local output
    output="$("$@" 2>&1)" || true

    if echo "$output" | grep -q -- "$unexpected"; then
        TESTS_FAILED=$((TESTS_FAILED + 1))
        printf "${RED}  FAIL${NC} %s (output contained '%s')\n" "$desc" "$unexpected"
    else
        TESTS_PASSED=$((TESTS_PASSED + 1))
        printf "${GREEN}  PASS${NC} %s\n" "$desc"
    fi
}

# Print test summary and exit with appropriate code
test_summary() {
    echo ""
    echo "========================================"
    printf "Tests run: %d  Passed: ${GREEN}%d${NC}  Failed: ${RED}%d${NC}\n" \
        "$TESTS_RUN" "$TESTS_PASSED" "$TESTS_FAILED"
    echo "========================================"

    if [[ "${TESTS_FAILED}" -gt 0 ]]; then
        exit 1
    fi
    exit 0
}
