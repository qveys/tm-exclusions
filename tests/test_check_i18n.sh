#!/usr/bin/env bash
# test_check_i18n.sh — Tests for scripts/check-i18n.sh (locale key parity checker)
#
# Run: bash tests/test_check_i18n.sh

set -euo pipefail

CHECK_I18N_TEST_DIR="$(
    source_dir="$(dirname -- "${BASH_SOURCE[0]}")" || exit 1
    [[ "$source_dir" != -* ]] || source_dir="./$source_dir"
    CDPATH='' cd -P -- "$source_dir" >/dev/null 2>&1 && pwd
)"
# shellcheck source=tests/test_helpers.sh
source "${CHECK_I18N_TEST_DIR}/test_helpers.sh"

CHECK="${ROOT}/scripts/check-i18n.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "check-i18n.sh tests"
echo "========================================"

# Write a locale fixture: locale_file <name> <content-with-printf-escapes>
locale_file() {
    # shellcheck disable=SC2059
    printf "$2" > "${WORK}/$1"
    printf '%s' "${WORK}/$1"
}

echo ""
echo "--- Repository locales ---"
assert_exit_code 0 "no args: repo locales/en.sh and locales/fr.sh are in parity" bash "$CHECK"
assert_output_contains "i18n parity OK" "success message printed" bash "$CHECK"
assert_exit_code 0 "--help exits 0" bash "$CHECK" --help

echo ""
echo "--- Aligned fixtures ---"
en="$(locale_file en_ok.sh 'f() {\n    MSG_A="a"\n    MSG_B="b"\n}\n')"
fr="$(locale_file fr_ok.sh 'f() {\n    MSG_B="b"\n    MSG_A="a"\n}\n')"
assert_exit_code 0 "same keys in a different order are in parity" bash "$CHECK" "$en" "$fr"

echo ""
echo "--- Missing keys are reported with file:line ---"
en="$(locale_file en_extra.sh 'f() {\n    MSG_A="a"\n    MSG_ONLY_EN="x"\n}\n')"
fr="$(locale_file fr_short.sh 'f() {\n    MSG_A="a"\n}\n')"
assert_exit_code 1 "key missing in fr fails" bash "$CHECK" "$en" "$fr"
assert_output_contains "en_extra.sh:3: error: MSG_ONLY_EN is missing from ${fr}" \
    "missing-in-fr reports en file:line" bash "$CHECK" "$en" "$fr"

en="$(locale_file en_short.sh 'f() {\n    MSG_A="a"\n}\n')"
fr="$(locale_file fr_extra.sh 'f() {\n    MSG_ONLY_FR="x"\n    MSG_A="a"\n}\n')"
assert_exit_code 1 "key missing in en fails" bash "$CHECK" "$en" "$fr"
assert_output_contains "fr_extra.sh:2: error: MSG_ONLY_FR is missing from ${en}" \
    "missing-in-en reports fr file:line" bash "$CHECK" "$en" "$fr"
assert_output_not_contains "MSG_A is missing" "present key not reported" bash "$CHECK" "$en" "$fr"

echo ""
# An empty reference still reports each unmatched assignment in source order.
empty="$(locale_file empty.sh '')"
rc=0
bash "$CHECK" "$en" "$empty" > "$WORK/empty.out" 2>&1 || rc=$?
assert_eq 1 "$rc" "empty French locale reports the English assignment"
assert_file_contains "$WORK/empty.out" "$en:2: error: MSG_A is missing from $empty" \
    "an empty reference preserves the source line number"
bash "$CHECK" "$empty" "$empty" > "$WORK/empty.out"
assert_file_contains "$WORK/empty.out" 'i18n parity OK: 0 keys' "two empty locales agree"

echo "--- Prefix keys are not confused ---"
en="$(locale_file en_pre.sh 'f() {\n    MSG_A="a"\n    MSG_A_LONG="b"\n}\n')"
fr="$(locale_file fr_pre.sh 'f() {\n    MSG_A_LONG="b"\n}\n')"
assert_exit_code 1 "MSG_A missing even though MSG_A_LONG exists" bash "$CHECK" "$en" "$fr"

echo ""
echo "--- Usage errors ---"
assert_exit_code 2 "unreadable file exits 2" bash "$CHECK" "${WORK}/nope-en.sh" "${WORK}/nope-fr.sh"
assert_exit_code 2 "single argument exits 2" bash "$CHECK" "$en"

test_summary
