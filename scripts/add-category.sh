#!/usr/bin/env bash
# scripts/add-category.sh
#
# Scaffold a new exclusion category in config/default.conf: validates the
# values, inserts a `#@<Name>` section with its `type|target|reason` entries
# following the file's layout, and validates the result with the existing
# checkers (scripts/check-conf.sh, scripts/check-i18n.sh).
#
# The config file is replaced only after validation passes; on any failure it
# is left untouched (exit 1). Nothing else is ever written. Category names are
# shown verbatim from the `#@` marker (only the default "Uncategorized" label
# is localized), so locales/*.sh need no new keys: check-i18n runs as a guard
# that the two locales are still in parity.
#
# Usage: scripts/add-category.sh [--root DIR] [--dry-run] [--name NAME]
#                                [--add TYPE TARGET REASON]...
#   Missing values (name, entries) are asked interactively when stdin is a
#   terminal; otherwise they are an error (exit 2).
#
# Exit status: 0 done (or dry-run ok), 1 refused or validation failed,
#              2 usage error.
#
# Bash 3.2+ compatible (macOS stock bash), GNU/Linux userland.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SELF_DIR}/.." && pwd)"
LF=$'\n'
NAME=""
HAVE_NAME=0
ENTRIES=""   # one "\ntype|target|reason" per entry
DRY_RUN=0
cand=""      # candidate config (temp file next to the real one)

usage() {
  cat <<EOF
Usage: $(basename "$0") [--root DIR] [--dry-run] [--name NAME] [--add TYPE TARGET REASON]...

Add a new category section to config/default.conf and validate it.

  --name NAME             category name (\`#@NAME\`); spaces and accents allowed
  --add TYPE TARGET REASON
                          one rule; TYPE is path, pattern, prune or keep.
                          Repeat for several rules.
  --dry-run               print the planned diff, write nothing
  --root DIR              repository root to edit (default: this checkout)

Missing name/rules are prompted for when stdin is a terminal.
'|' and control characters are refused in every field. An existing category
or rule is refused. The file is replaced only if check-conf and check-i18n pass.
Exit status: 0 ok, 1 refused/invalid, 2 usage error.
EOF
}

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage_error() { printf 'error: %s\n' "$1" >&2; usage >&2; exit 2; }

# Refuse empty values, '|' (field delimiter) and control characters (newline...).
check_field() { # label value
  case "$2" in
    "") die "$1 must not be empty" ;;
    *'|'*) die "$1 must not contain '|' (got: $2)" ;;
  esac
  if [[ "$2" == *[[:cntrl:]]* ]]; then
    die "$1 must not contain control characters or newlines"
  fi
}

add_entry() { # type target reason
  case "$1" in
    path|pattern|prune|keep) ;;
    *) die "unknown type '$1' (expected path, pattern, prune or keep)" ;;
  esac
  check_field "target" "$2"
  check_field "reason" "$3"
  case "$ENTRIES" in
    *"${LF}$1|$2|"*) die "entry given twice: $1|$2" ;;
  esac
  ENTRIES="${ENTRIES}${LF}$1|$2|$3"
}

set_name() {
  local n="$1"
  n="${n#"${n%%[![:space:]]*}"}"
  n="${n%"${n##*[![:space:]]}"}"
  check_field "category name" "$n"
  NAME="$n"
  HAVE_NAME=1
}

# True when a `#@<name>` marker (whitespace-trimmed, as the parser does) exists.
category_exists() {
  local line n
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      "#@"*)
        n="${line#\#@}"
        n="${n#"${n%%[![:space:]]*}"}"
        n="${n%"${n##*[![:space:]]}"}"
        [[ "$n" == "$1" ]] && return 0
        ;;
    esac
  done < "$CONF"
  return 1
}

# True when "type|target|" starts an active or commented-out (opt-in) rule.
entry_exists() {
  K="$1" awk 'BEGIN { k = ENVIRON["K"] }
    index($0, k) == 1 || index($0, "# " k) == 1 { f = 1 }
    END { exit !f }' "$CONF"
}

ask() { # prompt -> REPLY
  printf '%s' "$1" >&2
  IFS= read -r REPLY || REPLY=""
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      --dry-run) DRY_RUN=1; shift ;;
      --root)
        [[ $# -ge 2 ]] || usage_error "--root needs a directory"
        ROOT="$(cd "$2" 2>/dev/null && pwd)" || die "not a directory: $2"
        shift 2
        ;;
      --name)
        [[ $# -ge 2 ]] || usage_error "--name needs a value"
        set_name "$2"
        shift 2
        ;;
      --add)
        [[ $# -ge 4 ]] || usage_error "--add needs TYPE TARGET REASON"
        add_entry "$2" "$3" "$4"
        shift 4
        ;;
      *) usage_error "unknown argument: $1" ;;
    esac
  done

  CONF="${ROOT}/config/default.conf"
  [[ -r "$CONF" ]] || die "cannot read ${CONF}"

  if [[ -t 0 ]]; then
    if [[ "$HAVE_NAME" -eq 0 ]]; then
      ask "Category name: "
      set_name "$REPLY"
    fi
    if [[ -z "$ENTRIES" ]]; then
      local t target reason
      while :; do
        ask "Rule type (path|pattern|prune|keep, empty to finish): "
        t="$REPLY"
        [[ -n "$t" ]] || break
        ask "  target (e.g. \$HOME/.tool/cache): "; target="$REPLY"
        ask "  reason: "; reason="$REPLY"
        add_entry "$t" "$target" "$reason"
      done
    fi
  fi
  [[ "$HAVE_NAME" -eq 1 ]] || usage_error "missing --name"
  [[ -n "$ENTRIES" ]] || usage_error "missing --add TYPE TARGET REASON"

  category_exists "$NAME" && die "category already exists: ${NAME}"
  local type target reason b_static="" b_dynamic="" b_prune="" n=0
  while IFS='|' read -r type target reason; do
    [[ -n "$type" ]] || continue
    if entry_exists "${type}|${target}|"; then
      die "entry already exists: ${type}|${target}"
    fi
    case "$type" in
      pattern) b_dynamic="${b_dynamic}${type}|${target}|${reason}${LF}" ;;
      prune) b_prune="${b_prune}${type}|${target}|${reason}${LF}" ;;
      *) b_static="${b_static}${type}|${target}|${reason}${LF}" ;;
    esac
    n=$((n + 1))
  done <<EOF
${ENTRIES}
EOF
  # Same layout as the file: path/keep end the static section, pattern ends the
  # dynamic section, prune goes at the end of the file.
  if [[ -n "$b_static" ]]; then b_static="#@${NAME}${LF}${b_static}${LF}"; fi
  if [[ -n "$b_dynamic" ]]; then b_dynamic="#@${NAME}${LF}${b_dynamic}${LF}"; fi
  if [[ -n "$b_prune" ]]; then b_prune="${LF}#@${NAME}${LF}${b_prune}"; fi

  if ! grep -Fq '# ── DYNAMIC SCAN PATTERNS' "$CONF" || ! grep -Fq '# ── SCAN PRUNE ZONES' "$CONF"; then
    die "section banners not found in ${CONF}; cannot place the new category"
  fi

  local out rc=0
  cand="$(mktemp "${CONF}.XXXXXX")"
  trap 'rm -f "${cand:-}"' EXIT
  cp -p "$CONF" "$cand"
  B_STATIC="$b_static" B_DYNAMIC="$b_dynamic" awk '
    index($0, "# ── DYNAMIC SCAN PATTERNS") == 1 { printf "%s", ENVIRON["B_STATIC"] }
    index($0, "# ── SCAN PRUNE ZONES") == 1 { printf "%s", ENVIRON["B_DYNAMIC"] }
    { print }
  ' "$CONF" > "$cand"
  printf '%s' "$b_prune" >> "$cand"

  # Validate the candidate (and locale parity) before touching the real file.
  out="$(bash "${SELF_DIR}/check-conf.sh" "$cand" 2>&1)" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    printf '%s\n' "$out" >&2
    die "config validation failed; ${CONF} left unchanged"
  fi
  out="$(bash "${SELF_DIR}/check-i18n.sh" "${ROOT}/locales/en.sh" "${ROOT}/locales/fr.sh" 2>&1)" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    printf '%s\n' "$out" >&2
    die "locale parity check failed; ${CONF} left unchanged"
  fi

  diff -u "$CONF" "$cand" || true
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'Dry run: %d rule(s) for category "%s" planned, nothing written.\n' "$n" "$NAME"
    return 0
  fi
  mv "$cand" "$CONF"
  printf 'Added category "%s" (%d rule(s)) to %s.\n' "$NAME" "$n" "$CONF"
  printf 'Next: run "make check". The category count is asserted in tests/smoke.bats-like.sh and quoted in README.md and docs/ARCHITECTURE.md: update them.\n'
}

main "$@"
