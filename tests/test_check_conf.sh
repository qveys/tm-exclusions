#!/usr/bin/env bash
# test_check_conf.sh — Tests for scripts/check-conf.sh (config syntax validator)
#
# Run: bash tests/test_check_conf.sh

set -euo pipefail

CHECK_CONF_TEST_DIR="$(
    source_dir="$(dirname -- "${BASH_SOURCE[0]}")" || exit 1
    [[ "$source_dir" != -* ]] || source_dir="./$source_dir"
    CDPATH='' cd -P -- "${source_dir}" >/dev/null 2>&1 && pwd
)"
# shellcheck source=tests/test_helpers.sh
source "${CHECK_CONF_TEST_DIR}/test_helpers.sh"

CHECK="${ROOT}/scripts/check-conf.sh"
WORK="$(mktemp -d)"
# Literal (unexpanded) variable spellings used as test input.
H="\$HOME"
U="\$USER"
LIT_BRACE="\${HOME}"
trap 'rm -rf "$WORK"' EXIT

echo "check-conf.sh tests"
echo "========================================"

# Write a one-line config and run the validator on it.
# Usage: conf_file <name> <content-with-printf-escapes>
conf_file() {
    # shellcheck disable=SC2059
    printf "$2" > "${WORK}/$1"
    printf '%s' "${WORK}/$1"
}

echo ""
echo "--- Repository configs ---"
assert_exit_code 0 "no args: all repo config/*.conf are valid" bash "$CHECK"
assert_exit_code 0 "config/default.conf is valid" bash "$CHECK" "${ROOT}/config/default.conf"
assert_exit_code 0 "config/extra-prunes.example.conf is valid" \
    bash "$CHECK" "${ROOT}/config/extra-prunes.example.conf"
assert_exit_code 0 "--help exits 0" bash "$CHECK" --help

echo ""
echo "--- Valid syntax ---"
f="$(conf_file ok.conf "# comment\n#@Section\n\npath|${H}/.cache/x|reason\npath|~/y|reason\npath|/abs/z|reason\npattern|node_modules|deps\nprune|${H}/Library|skip\nkeep|${H}/Keep|keep it\nsetting|scan_images|true\nsetting|desktop_report|no\nsetting|report_path|${H}/r.txt\n")"
assert_exit_code 0 "all valid line kinds accepted" bash "$CHECK" "$f"
f="$(conf_file nonl.conf "path|${H}/x|no trailing newline")"
assert_exit_code 0 "last line without newline is validated" bash "$CHECK" "$f"
f="$(conf_file pipe-reason.conf "path|${H}/x|reason | with | pipes\n")"
assert_exit_code 0 "pipes inside reason are allowed" bash "$CHECK" "$f"

echo ""
echo "--- Invalid syntax is rejected with exit 1 ---"
f="$(conf_file badtype.conf "bogus|${H}/x|reason\n")"
assert_exit_code 1 "unknown type rejected" bash "$CHECK" "$f"
assert_output_contains "badtype.conf:1: error: unknown type 'bogus'" \
    "unknown type reports file:line" bash "$CHECK" "$f"

f="$(conf_file nopipe.conf '# ok\nnot a rule\n')"
assert_exit_code 1 "line without delimiter rejected" bash "$CHECK" "$f"
assert_output_contains "nopipe.conf:2: error: missing '|' delimiter" \
    "missing delimiter reports line number" bash "$CHECK" "$f"

f="$(conf_file noreason.conf "path|${H}/x\n")"
assert_exit_code 1 "missing reason field rejected" bash "$CHECK" "$f"
f="$(conf_file emptyreason.conf "path|${H}/x|\n")"
assert_exit_code 1 "empty reason rejected" bash "$CHECK" "$f"
f="$(conf_file notarget.conf 'path||reason\n')"
assert_exit_code 1 "empty target rejected" bash "$CHECK" "$f"

f="$(conf_file trav1.conf "path|${H}/../etc|reason\n")"
assert_exit_code 1 "path traversal in middle rejected" bash "$CHECK" "$f"
assert_output_contains "path traversal" "traversal error message" bash "$CHECK" "$f"
f="$(conf_file trav2.conf 'prune|../x|reason\n')"
assert_exit_code 1 "leading ../ rejected" bash "$CHECK" "$f"
f="$(conf_file trav3.conf 'path|/tmp/..|reason\n')"
assert_exit_code 1 "trailing /.. rejected" bash "$CHECK" "$f"
f="$(conf_file dots.conf "path|${H}/.cache/..hidden|reason\n")"
assert_exit_code 0 "name merely containing dots is not traversal" bash "$CHECK" "$f"

f="$(conf_file home1.conf "path|${H}E/x|reason\n")"
assert_exit_code 1 "typo'd \$HOMEE rejected" bash "$CHECK" "$f"
f="$(conf_file home2.conf "path|${LIT_BRACE}/x|reason\n")"
assert_exit_code 1 "\${HOME} form rejected" bash "$CHECK" "$f"
f="$(conf_file home3.conf "path|${H}/a/${U}|reason\n")"
assert_exit_code 1 "other variables rejected" bash "$CHECK" "$f"
f="$(conf_file home4.conf 'path|~other/x|reason\n')"
assert_exit_code 1 "~user form rejected" bash "$CHECK" "$f"
f="$(conf_file rel.conf 'prune|relative/dir|reason\n')"
assert_exit_code 1 "relative path target rejected" bash "$CHECK" "$f"
f="$(conf_file pat.conf 'pattern|a/b|reason\n')"
assert_exit_code 1 "pattern containing / rejected" bash "$CHECK" "$f"

f="$(conf_file set1.conf 'setting|nope|1\n')"
assert_exit_code 1 "unknown setting key rejected" bash "$CHECK" "$f"
f="$(conf_file set2.conf 'setting|scan_images|maybe\n')"
assert_exit_code 1 "invalid boolean setting value rejected" bash "$CHECK" "$f"
f="$(conf_file set3.conf 'setting|report_path|\n')"
assert_exit_code 1 "empty report_path rejected" bash "$CHECK" "$f"

f="$(conf_file keeptab.conf "keep|/tmp/a\tb|protect\n")"
assert_exit_code 1 "keep target containing a tab rejected" bash "$CHECK" "$f"
assert_output_contains "tab character not allowed in keep target" "keep tab error message" bash "$CHECK" "$f"
f="$(conf_file pathtab.conf "path|/tmp/a\tb|reason\n")"
assert_exit_code 0 "tab in path target still accepted (parser only rejects keep)" bash "$CHECK" "$f"

f="$(conf_file crlf.conf "path|${H}/x|reason\r\n")"
assert_exit_code 1 "CRLF line endings rejected" bash "$CHECK" "$f"

echo ""
echo "--- Multiple errors and files ---"
f="$(conf_file multi.conf "bogus|a|b\npath|${H}/ok|fine\npath|${H}/../x|bad\n")"
assert_output_contains "multi.conf:1:" "first error reported" bash "$CHECK" "$f"
assert_output_contains "multi.conf:3:" "later error also reported" bash "$CHECK" "$f"
assert_output_not_contains "multi.conf:2:" "valid line not reported" bash "$CHECK" "$f"
good="$(conf_file good2.conf "path|${H}/x|ok\n")"
assert_exit_code 1 "one bad file among several fails the run" bash "$CHECK" "$good" "$f"

echo ""
echo "--- Usage errors ---"
assert_exit_code 2 "missing file exits 2" bash "$CHECK" "${WORK}/does-not-exist.conf"

test_summary
