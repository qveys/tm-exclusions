#!/usr/bin/env bash
# scripts/check-i18n.sh
#
# Translation parity checker: verifies that every MSG_* key assigned in the
# English locale (locales/en.sh) is also assigned in the French locale
# (locales/fr.sh), and vice versa. Every mismatch is reported with the
# file:line of the definition that has no counterpart.
#
# Usage: scripts/check-i18n.sh [en_file fr_file]
#   With no arguments, compares locales/en.sh against locales/fr.sh.
#
# Exit status: 0 = keys in 1:1 parity, 1 = missing or extra keys,
#              2 = usage error or unreadable file.
#
# Bash 3.2+ compatible (macOS stock bash).
set -euo pipefail

ROOT="$(
    source_dir="$(dirname -- "${BASH_SOURCE[0]}")" || exit 1
    [[ "$source_dir" != -* ]] || source_dir="./$source_dir"
    CDPATH='' cd -P -- "${source_dir}/.." >/dev/null 2>&1 && pwd
)"

usage() {
  cat <<EOF
Usage: $(basename "$0") [en_file fr_file]

Check that locales/en.sh and locales/fr.sh define the same MSG_* keys.
With no arguments, compares locales/en.sh against locales/fr.sh.

Reports every key defined in one locale but missing from the other, with the
file:line of the existing definition. Exit status: 0 parity, 1 mismatch,
2 usage error.
EOF
}

# List "KEY<TAB>LINE" for every MSG_* assignment in a locale file.
list_keys() {
  awk '
    match($0, /^[[:space:]]*MSG_[A-Za-z0-9_]*=/) {
      key = substr($0, RSTART, RLENGTH - 1)
      sub(/^[[:space:]]*/, "", key)
      printf "%s\t%d\n", key, NR
    }
  ' "$1"
}

# Print "file:line: error: ..." for each key of <src> absent from <other>.
# Usage: report_missing <src_file> <other_file> <src_keys> <other_keys>
report_missing() {
  local src="$1" other="$2" src_keys="$3" other_keys="$4"
  # list_keys emits only nonempty KEY<TAB>LINE records. A blank line
  # separates the reference set from the records to check in source order.
  SRC_FILE="$src" OTHER_FILE="$other" awk -F '\t' '
    !NF { checking = 1; next }
    !checking { seen[$1] = 1; next }
    !($1 in seen) {
      printf "%s:%s: error: %s is missing from %s\n", ENVIRON["SRC_FILE"], $2, $1, ENVIRON["OTHER_FILE"] > "/dev/stderr"
      missing++
    }
    END { print missing + 0 }
  ' <<EOF
$other_keys

$src_keys
EOF
}

main() {
  local en fr
  case "${1:-}" in
    -h|--help) usage; return 0 ;;
  esac
  case "$#" in
    0) en="${ROOT}/locales/en.sh"; fr="${ROOT}/locales/fr.sh" ;;
    2) en="$1"; fr="$2" ;;
    *) usage >&2; return 2 ;;
  esac

  local f
  for f in "$en" "$fr"; do
    if [ ! -r "$f" ]; then
      printf 'error: cannot read %s\n' "$f" >&2
      return 2
    fi
  done

  local en_keys fr_keys
  en_keys="$(list_keys "$en")"
  fr_keys="$(list_keys "$fr")"

  local missing_in_fr missing_in_en
  missing_in_fr="$(report_missing "$en" "$fr" "$en_keys" "$fr_keys")"
  missing_in_en="$(report_missing "$fr" "$en" "$fr_keys" "$en_keys")"

  local total=$((missing_in_fr + missing_in_en))
  if [ "$total" -gt 0 ]; then
    printf 'i18n parity broken: %d key(s) missing in %s, %d key(s) missing in %s.\n' \
      "$missing_in_fr" "$(basename "$fr")" "$missing_in_en" "$(basename "$en")" >&2
    return 1
  fi

  local n
  n="$(printf '%s\n' "$en_keys" | grep -c . || true)"
  printf 'i18n parity OK: %s keys in %s and %s.\n' "$n" "$(basename "$en")" "$(basename "$fr")"
}

main "$@"
