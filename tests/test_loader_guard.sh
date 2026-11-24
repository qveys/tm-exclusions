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

GUARD_DIR="$(
    source_dir="$(dirname -- "${BASH_SOURCE[0]}")" || exit 1
    [[ "$source_dir" != -* ]] || source_dir="./$source_dir"
    CDPATH='' cd -P -- "${source_dir}" >/dev/null 2>&1 && pwd
)"
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
# <root>/Makefile that load code through process substitution: the word "source"
# or a lone dot, spaces, an optional `--`, then an opening parenthesis right
# after a less-than sign (Bash 3.2 loads nothing from any of these spellings).
# Lines are first re-joined across backslash continuations, so the form may be
# split anywhere, and comment lines are skipped, so prose may mention the
# pitfall. Files come from `find -print0` and only paths are printed: nothing
# parses a colon-separated grep line, so a checkout path containing ':' is safe.
# This file is scanned too; its own text never spells the form out (the
# fixtures below build it).
# Fail-closed: whatever cannot be scanned (missing target, find error, file that
# is not readable, awk error) prints "cannot scan <path>", which is an offender
# line like any other, so the guard fails instead of staying silently green.
# shellcheck disable=SC2016
PSUB_AWK='
/^[[:space:]]*#/ { next }
{
    line = $0
    while (line ~ /\\$/ && (getline nxt) > 0) { sub(/\\$/, "", line); line = line nxt }
    if (line ~ /(^|[^[:alnum:]_])(source|\.)[[:space:]]+(--[[:space:]]+)?<[[:space:]]*\(/) found = 1
}
END { exit found ? 0 : 1 }'
psub_offenders() {
    local root="$1" target f rc list="$WORK/psub.list"
    for target in "$root/tests" "$root/scripts" "$root/Makefile"; do
        rc=0
        find "$target" -type f -print0 > "$list" 2>/dev/null || rc=$?
        if [[ "$rc" -ne 0 || ! -e "$target" ]]; then
            printf 'cannot scan %s\n' "$target"
            continue
        fi
        while IFS= read -r -d '' f; do
            if [[ ! -r "$f" ]]; then
                printf 'cannot scan %s\n' "$f"
                continue
            fi
            rc=0
            awk "$PSUB_AWK" "$f" || rc=$?
            case "$rc" in
                0) printf '%s\n' "$f" ;;
                1) ;;
                *) printf 'cannot scan %s\n' "$f" ;;
            esac
        done < "$list"
    done
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
inject_case "source with -- is reported" tests/a.sh "source -- ${PS_CMD}"
inject_case "the dot form with -- is reported" tests/a.sh ". -- ${PS_CMD}"
inject_case "a continuation between < and ( is reported" tests/a.sh $'source <\\\n'"${PS_CMD#<}"
inject_case "a continuation after -- is reported" tests/a.sh $'source -- \\\n  '"$PS_CMD"

# The guard's own file is scanned: a clean copy passes, an injected one fails.
make_repo "$CLEAN"
cp "$GUARD_DIR/test_loader_guard.sh" "$CLEAN/tests/test_loader_guard.sh"
assert_eq "" "$(psub_offenders "$CLEAN")" "a clean copy of this file is not reported (no self-exclusion)"
printf '%s\n' "$BAD_LINE" >> "$CLEAN/tests/test_loader_guard.sh"
assert_eq "$CLEAN/tests/test_loader_guard.sh" "$(psub_offenders "$CLEAN")" \
    "a load injected into this very file is reported"


# Fail-closed: what cannot be scanned makes the guard fail, never stay green.
rm -rf "$CLEAN"
make_repo "$CLEAN"
printf '%s\n' "$BAD_LINE" > "$CLEAN/tests/hidden.sh"
chmod 000 "$CLEAN/tests/hidden.sh"
if [[ -r "$CLEAN/tests/hidden.sh" ]]; then
    echo "  SKIP unreadable file: chmod 000 does not block reading here (root?)"
else
    assert_eq "cannot scan $CLEAN/tests/hidden.sh" "$(psub_offenders "$CLEAN")" \
        "an unreadable file makes the guard fail ('cannot scan')"
fi
chmod 600 "$CLEAN/tests/hidden.sh"
rm -f "$CLEAN/tests/hidden.sh"
mkdir "$CLEAN/tests/locked"
printf '%s\n' "$BAD_LINE" > "$CLEAN/tests/locked/x.sh"
chmod 000 "$CLEAN/tests/locked"
if ls "$CLEAN/tests/locked" >/dev/null 2>&1; then
    echo "  SKIP inaccessible directory: chmod 000 does not block listing here (root?)"
else
    assert_eq "cannot scan $CLEAN/tests" "$(psub_offenders "$CLEAN")" \
        "an inaccessible subdirectory makes the guard fail ('cannot scan')"
fi
chmod 700 "$CLEAN/tests/locked"
rm -rf "$CLEAN/tests/locked"
assert_eq "" "$(psub_offenders "$CLEAN")" "the readable checkout passes again once access is restored"
rm -rf "$CLEAN/scripts"
assert_eq "cannot scan $CLEAN/scripts" "$(psub_offenders "$CLEAN")" \
    "a missing scan target makes the guard fail ('cannot scan')"

test_summary
