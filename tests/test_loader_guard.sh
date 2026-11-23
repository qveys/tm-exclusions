#!/usr/bin/env bash
# test_loader_guard.sh — guards against silent false greens in the test suites (#88).
#
# Under Bash 3.2 (stock macOS /bin/bash) `source <(command)` returns 0 without
# defining anything, so a suite that loads the CLI that way can run no
# assertion yet exit 0. This suite proves, on fake suites, that:
#   - a suite that executes zero assertions exits nonzero (test_summary),
#   - a suite whose script load defined nothing exits nonzero (require_functions),
#   - write_functions_file + source really defines the CLI's functions,
#   - no test or script loads code through process substitution.
# Fake suites run with the same interpreter as this one ($BASH), so
# `/bin/bash tests/test_loader_guard.sh` exercises Bash 3.2.
set -euo pipefail

GUARD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/test_helpers.sh
source "${GUARD_DIR}/test_helpers.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "loader guard tests"
echo "========================================"

# make_suite <name> <body>: a fake suite sourcing the shared helpers.
make_suite() {
    {
        printf '#!/usr/bin/env bash\nset -euo pipefail\n'
        printf 'source "%s/tests/test_helpers.sh"\n' "$ROOT"
        printf '%s\n' "$2"
    } > "$WORK/$1.sh"
}

# suite_rc <name>: exit code of the fake suite (its output is kept in <name>.out).
suite_rc() {
    local rc=0
    "$BASH" "$WORK/$1.sh" > "$WORK/$1.out" 2>&1 || rc=$?
    printf '%s' "$rc"
}

make_suite zero 'test_summary'
assert_eq "1" "$(suite_rc zero)" "a suite that runs zero assertions exits nonzero"
assert_file_contains "$WORK/zero.out" "no assertion was executed" \
    "the zero-assertion failure is explained"

make_suite one_pass 'assert_eq x x "passing assertion"
test_summary'
assert_eq "0" "$(suite_rc one_pass)" "a suite with one passing assertion exits 0"

make_suite one_fail 'assert_eq x y "failing assertion"
test_summary'
assert_eq "1" "$(suite_rc one_fail)" "a suite with a failing assertion exits nonzero"

# A load that defines nothing (what `source <(...)` does under Bash 3.2).
# shellcheck disable=SC2016
make_suite empty_load ': > "$0.empty"
source "$0.empty"
require_functions normalize_path
assert_eq x x "unreachable"
test_summary'
assert_eq "1" "$(suite_rc empty_load)" "a load that defines nothing exits nonzero"
assert_file_contains "$WORK/empty_load.out" "function normalize_path is not defined" \
    "the missing function is named"

# shellcheck disable=SC2016
make_suite real_load 'write_functions_file "$0.fn"
source "$0.fn"
require_functions normalize_path keep_blocks parse_config_file
assert_eq x x "loaded"
test_summary'
assert_eq "0" "$(suite_rc real_load)" \
    "write_functions_file + source defines the CLI functions"

# Repository-wide: no suite or script may load code through process substitution
# (comment lines explaining the pitfall are fine; this file is excluded as it
# names the pattern).
PSUB_HITS="$(grep -rnE '(^|[^[:alnum:]_])(source|\.)[[:space:]]+<\(' \
    "$ROOT/tests" "$ROOT/scripts" "$ROOT/Makefile" --exclude=test_loader_guard.sh \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
assert_eq "" "$PSUB_HITS" "no 'source <(...)' in tests/, scripts/ or the Makefile"

test_summary
