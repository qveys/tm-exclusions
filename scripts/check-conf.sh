#!/usr/bin/env bash
# scripts/check-conf.sh
#
# Standalone syntax validator for tm-exclusions `.conf` files (type|target|reason).
# Mirrors the rules enforced by parse_config_file() in tm_exclusions.sh, but
# reports every problem with file:line instead of failing mid-run.
#
# Usage: scripts/check-conf.sh [file ...]
#   With no arguments, validates every config/*.conf in the repository.
#
# Exit status: 0 = all files valid, 1 = at least one syntax error,
#              2 = usage error or unreadable file.
#
# Bash 3.2+ compatible (macOS stock bash).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ERRORS=0
FILES=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [file ...]

Validate tm-exclusions config files (type|target|reason).
With no arguments, checks every config/*.conf in the repository.

Checks: known type, pipe-delimited fields, non-empty target and reason,
\$HOME/~ usage, path traversal (..), and valid setting keys/values.

Exit status: 0 valid, 1 syntax errors found, 2 usage error.
EOF
}

report() {
  # report <file> <line> <message>
  printf '%s:%s: error: %s\n' "$1" "$2" "$3" >&2
  ERRORS=$((ERRORS + 1))
}

# True when a path-like string contains a '..' path component.
has_traversal() {
  case "$1" in
    ..|../*|*/..|*/../*) return 0 ;;
  esac
  return 1
}

# Validate the $HOME / ~ usage of a path-style target (path, prune, keep).
# Prints an error message on stdout and returns 1 when invalid.
check_path_target() {
  local target="$1"
  # shellcheck disable=SC2088,SC2016
  case "$target" in
    /*|\~|\~/*|\$HOME|\$HOME/*) ;;
    *)
      printf 'target must start with /, ~, ~/, $HOME or $HOME/ (got: %s)' "$target"
      return 1
      ;;
  esac
  # Any '$' other than a leading '$HOME' is a typo ($HOMEE, ${HOME}, $USER...).
  local rest="$target"
  case "$target" in
    \$HOME*) rest="${target#\$HOME}" ;;
  esac
  case "$rest" in
    *\$*)
      printf '%s' "unsupported variable in target; only a leading \$HOME is expanded (got: ${target})"
      return 1
      ;;
  esac
  return 0
}

check_line() {
  local file="$1" num="$2" line="$3"

  case "$line" in
    ""|\#*) return 0 ;; # blank, comment, or `#@` section marker
  esac

  case "$line" in
    *$'\r'*)
      report "$file" "$num" "carriage return found (use LF line endings)"
      return 0
      ;;
  esac

  case "$line" in
    *'|'*) ;;
    *)
      report "$file" "$num" "missing '|' delimiter; expected type|target|reason"
      return 0
      ;;
  esac

  local type="${line%%|*}"
  local rest="${line#*|}"
  local target="${rest%%|*}"
  local reason=""
  local has_reason=0
  if [[ "$rest" == *'|'* ]]; then
    has_reason=1
    reason="${rest#*|}"
  fi

  case "$type" in
    path|pattern|prune|keep|setting) ;;
    *)
      report "$file" "$num" "unknown type '${type}' (expected path, pattern, prune, keep or setting)"
      return 0
      ;;
  esac

  if [[ -z "$target" ]]; then
    report "$file" "$num" "empty target field for '${type}'"
    return 0
  fi

  if [[ "$type" != setting ]]; then
    if [[ "$has_reason" -eq 0 || -z "$reason" ]]; then
      report "$file" "$num" "missing reason field; expected ${type}|target|reason"
    fi
  fi

  case "$type" in
    path|prune|keep)
      if [[ "$type" == keep && "$target" == *$'\t'* ]]; then
        report "$file" "$num" "tab character not allowed in keep target"
      fi
      local msg
      if ! msg="$(check_path_target "$target")"; then
        report "$file" "$num" "$msg"
      fi
      if has_traversal "$target"; then
        report "$file" "$num" "path traversal ('..') not allowed in target: ${target}"
      fi
      ;;
    pattern)
      case "$target" in
        */*)
          report "$file" "$num" "pattern must be a directory name without '/' (got: ${target})"
          ;;
      esac
      if has_traversal "$target"; then
        report "$file" "$num" "path traversal ('..') not allowed in pattern: ${target}"
      fi
      ;;
    setting)
      case "$target" in
        report_path)
          if [[ -z "$reason" ]]; then
            report "$file" "$num" "setting report_path requires a value"
          elif has_traversal "$reason"; then
            report "$file" "$num" "path traversal ('..') not allowed in report_path: ${reason}"
          fi
          ;;
        scan_images|desktop_report)
          case "$reason" in
            true|1|yes|false|0|no) ;;
            *)
              report "$file" "$num" "setting ${target} must be true/1/yes or false/0/no (got: '${reason}')"
              ;;
          esac
          ;;
        *)
          report "$file" "$num" "unknown setting '${target}' (expected report_path, scan_images or desktop_report)"
          ;;
      esac
      ;;
  esac
  return 0
}

check_file() {
  local file="$1"
  if [[ ! -f "$file" || ! -r "$file" ]]; then
    printf '%s: error: not a readable file\n' "$file" >&2
    return 2
  fi
  local before="$ERRORS" num=0 line label="$file"
  while IFS= read -r line || [[ -n "$line" ]]; do
    num=$((num + 1))
    check_line "$label" "$num" "$line"
  done < "$file"
  FILES=$((FILES + 1))
  if [[ "$ERRORS" -eq "$before" ]]; then
    printf 'OK   %s\n' "$file"
  else
    printf 'FAIL %s (%d error(s))\n' "$file" "$((ERRORS - before))"
  fi
  return 0
}

main() {
  case "${1:-}" in
    -h|--help) usage; exit 0 ;;
  esac

  local targets=()
  if [[ $# -gt 0 ]]; then
    targets=("$@")
  else
    local f
    for f in "$ROOT"/config/*.conf; do
      [[ -e "$f" ]] && targets+=("$f")
    done
    if [[ ${#targets[@]} -eq 0 ]]; then
      echo "Error: no config/*.conf files found under ${ROOT}" >&2
      exit 2
    fi
  fi

  local f rc=0
  for f in "${targets[@]}"; do
    check_file "$f" || rc=2
  done

  if [[ "$rc" -eq 2 ]]; then
    exit 2
  fi
  if [[ "$ERRORS" -gt 0 ]]; then
    printf 'Config validation failed: %d error(s) in %d file(s).\n' "$ERRORS" "$FILES" >&2
    exit 1
  fi
  printf 'Config validation passed: %d file(s).\n' "$FILES"
}

main "$@"
