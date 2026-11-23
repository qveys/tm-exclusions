#!/usr/bin/env bash
# test_loader_guard.sh — guards against silent false greens in the test suites (#88).
#
# Under Bash 3.2 (stock macOS /bin/bash) `source <(command)` returns 0 without
# defining anything, so a suite that loads the CLI that way can run no
# assertion yet exit 0. This suite proves, on fake suites, that:
#   - a suite that executes zero assertions exits nonzero (test_summary),
#   - a suite whose script load defined nothing exits nonzero (require_functions),
#   - write_functions_file + source really defines the CLI's functions,
#   - no test or script (this file included) loads code through process
#     substitution, on one line or continued, `source` or `.` form, also in a
#     checkout path containing ':' (psub_offenders, run on fake checkouts).
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

# psub_offenders <root>: print the files under <root>/tests, <root>/scripts and
# <root>/Makefile that load code through process substitution (the forbidden
# form: the word "source" or a lone dot, then optional spaces, then an opening
# parenthesis right after a less-than sign). Lines are first re-joined across
# backslash continuations (that spelling is just as broken under Bash 3.2) and
# comment lines are skipped, so prose may mention the pitfall. Files come from
# `find -print0` and only paths are printed: nothing parses a colon-separated
# grep line, so a checkout path containing ':' is safe. This file is scanned
# too; its own text never spells the form out (the fixtures below build it).
# shellcheck disable=SC2016
PSUB_AWK='
/^[[:space:]]*#/ { next }
{
    line = $0
    while (line ~ /\\$/ && (getline nxt) > 0) { sub(/\\$/, "", line); line = line " " nxt }
    if (line ~ /(^|[^[:alnum:]_])(source|\.)[[:space:]]*<\(/) found = 1
}
END { exit found ? 0 : 1 }'
psub_offenders() {
    local root="$1" f
    local dirs=()
    [[ -d "$root/tests" ]] && dirs+=("$root/tests")
    [[ -d "$root/scripts" ]] && dirs+=("$root/scripts")
    [[ -f "$root/Makefile" ]] && dirs+=("$root/Makefile")
    [[ ${#dirs[@]} -gt 0 ]] || return 0
    while IFS= read -r -d '' f; do
        if awk "$PSUB_AWK" "$f"; then
            printf '%s\n' "$f"
        fi
    done < <(find "${dirs[@]}" -type f -print0)
}

# The forbidden form, built piecewise so that no line of this file contains it.
PS_OPEN='<''('
BAD_LINE="source ${PS_OPEN}sed -n p x)"
BAD_DOT=". ${PS_OPEN}sed -n p x)"
COMMENT_LINE="# never write source ${PS_OPEN}...) here"

# make_repo <dir>: a clean fake checkout (comments may mention the form).
make_repo() {
    mkdir -p "$1/tests" "$1/scripts"
    printf '%s\n' '#!/usr/bin/env bash' "$COMMENT_LINE" 'source ./helpers.sh' \
        'done < <(find . -type f)' > "$1/tests/a.sh"
    printf '%s\n' "  $COMMENT_LINE" 'echo ok' > "$1/scripts/b.sh"
    printf '%s\n' "# $COMMENT_LINE" 'test:' '	@bash tests/a.sh' > "$1/Makefile"
}

# The real repository is clean, including this very file.
assert_eq "" "$(psub_offenders "$ROOT")" "no process-substitution load in tests/, scripts/ or the Makefile"

# Fixtures: a clean fake checkout passes, even under a path containing ':'.
CLEAN="$WORK/checkout:colon/repo"
make_repo "$CLEAN"
assert_eq "" "$(psub_offenders "$CLEAN")" \
    "clean checkout in a path containing ':' passes (comments may mention the form)"

# Each injection must be reported (path printed), in a ':' path as well.
inject_case() { # <description> <relative file> <line(s) to append>
    make_repo "$CLEAN"
    printf '%s\n' "$3" >> "$CLEAN/$2"
    assert_eq "$CLEAN/$2" "$(psub_offenders "$CLEAN")" "$1"
}
PS_CMD="${PS_OPEN}sed -n p x)"
inject_case "an injected load in another tests/ file is reported (':' path)" tests/a.sh "$BAD_LINE"
inject_case "an injected load in scripts/ is reported" scripts/b.sh "$BAD_LINE"
inject_case "an injected load in the Makefile is reported" Makefile $'\t'"$BAD_LINE"
inject_case "the dot form is reported" tests/a.sh "$BAD_DOT"
inject_case "a backslash-continued load is reported" tests/a.sh $'source \\\n    '"$PS_CMD"
inject_case "a continued dot form is reported" tests/a.sh $'. \\\n  '"$PS_CMD"
inject_case "a load inside a bash -c block is reported" tests/a.sh "bash -c '$BAD_LINE'"

# The guard's own file is scanned: a clean copy passes, an injected one fails.
make_repo "$CLEAN"
cp "$GUARD_DIR/test_loader_guard.sh" "$CLEAN/tests/test_loader_guard.sh"
assert_eq "" "$(psub_offenders "$CLEAN")" "a clean copy of this file is not reported (no self-exclusion)"
printf '%s\n' "$BAD_LINE" >> "$CLEAN/tests/test_loader_guard.sh"
assert_eq "$CLEAN/tests/test_loader_guard.sh" "$(psub_offenders "$CLEAN")" \
    "a load injected into this very file is reported"

test_summary
