#!/usr/bin/env bash
# scripts/add-category.sh
#
# Scaffold a new exclusion category: validates the values, inserts a `#@<Name>`
# section with its `type|target|reason` rules into config/default.conf
# (following the file's layout), bumps EXPECTED_CATEGORY_COUNT in
# tests/smoke.bats-like.sh, and validates everything on a temporary COPY of the
# repository (check-conf, check-i18n, then `make check` = lint + tests). The
# real files are replaced only if all of it passes; otherwise nothing is
# written (exit 1). No other file is ever touched.
#
# Category names are NOT localized: the CLI prints the `#@` label as written
# (only the default "Uncategorized" label is translated), so locales/*.sh need
# no new key. check-i18n still runs as a guard that the locales stay in parity.
#
# Usage: scripts/add-category.sh [--root DIR] [--dry-run] [--skip-tests]
#                                [--name NAME] [--add TYPE TARGET REASON]...
#   Missing values (name, rules) are asked interactively when stdin is a
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
SMOKE_REL="tests/smoke.bats-like.sh"
NAME=""
HAVE_NAME=0
ENTRIES=""   # one "\ntype|target|reason" per rule
DRY_RUN=0
SKIP_TESTS=0
LOCK=""      # lock directory, set only once this run owns it
WORK=""      # temporary copy of the repository (a sibling of ROOT, see make_work_dir)
BAK=""       # originals of the two edited files, kept until the install is done
INSTALLING=0 # 1 while the real files are being overwritten
KEEP_WORK=0  # 1 when a restore failed: keep WORK, it holds the originals

usage() {
  cat <<EOF
Usage: $(basename "$0") [--root DIR] [--dry-run] [--skip-tests] [--name NAME] [--add TYPE TARGET REASON]...

Add a new category section to config/default.conf and validate it.

  --name NAME             category name (\`#@NAME\`); spaces and accents allowed.
                          Shown as written by the CLI: category names are not
                          localized, so no locales/*.sh key is written.
  --add TYPE TARGET REASON
                          one rule; TYPE is path, pattern, prune or keep.
                          Repeat for several rules. A leading ~ becomes \$HOME
                          and trailing slashes are dropped.
  --dry-run               print the planned diff, write nothing, run no make
  --skip-tests            skip \`make check\` (lint + tests); check-conf and
                          check-i18n still run. Run \`make check\` afterwards.
  --root DIR              repository root to edit (default: this checkout)

Missing name/rules are prompted for when stdin is a terminal (end of input
aborts). '|', control characters and newlines are refused in every field. An
existing category or rule is refused, and only one run may edit a tree at a
time (lock directory .add-category.lock). The edit is validated on a copy of the
repository placed next to --root (else under $HOME, never under TMPDIR):
check-conf, check-i18n, make check. The real files are then overwritten in place
(mode kept) after a backup, and restored on any failure or signal, so they are
always either both updated or both untouched. EXPECTED_CATEGORY_COUNT in
$SMOKE_REL is bumped with the config.
Exit status: 0 ok, 1 refused/invalid, 2 usage error.
EOF
}

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage_error() { printf 'error: %s\n' "$1" >&2; usage >&2; exit 2; }

# Put both real files back from the backup (best effort, each one).
restore_originals() {
  local rc=0
  cp -p "${BAK}/default.conf" "$CONF" || rc=1
  cp -p "${BAK}/smoke" "$SMOKE" || rc=1
  if [[ "$rc" -ne 0 ]]; then
    printf 'error: could not restore the original files; they are saved in %s\n' "$BAK" >&2
  fi
  return "$rc"
}

# Runs on every exit and on INT/TERM/HUP: the real files end up either fully
# installed or fully restored, never half and half.
cleanup() {
  trap - EXIT
  if [[ "$INSTALLING" -eq 1 ]]; then
    restore_originals || KEEP_WORK=1
  fi
  if [[ -n "$LOCK" ]]; then rmdir "$LOCK" 2>/dev/null || true; fi
  case "$WORK" in
    *.add-category.*) if [[ "$KEEP_WORK" -eq 0 ]]; then rm -rf "$WORK"; fi ;;
  esac
}

# Working copy: a sibling of the repository root (else under $HOME), never under
# TMPDIR: the catalog excludes /private/var/folders and the smoke test would
# fail there on a valid copy.
make_work_dir() {
  if ! WORK="$(mktemp -d "${ROOT%/}.add-category.XXXXXX" 2>/dev/null)"; then
    WORK="$(mktemp -d "${HOME:-/nonexistent}/.add-category.XXXXXX" 2>/dev/null)" || WORK=""
  fi
  [[ -n "$WORK" ]] || die "cannot create a working directory next to ${ROOT} or under \$HOME"
}

# Every line given after FILE must be present, as a whole line, in FILE.
verify_added_lines() { # file line...
  local f="$1" l
  shift
  for l in "$@"; do
    if ! grep -Fxq -- "$l" "$f"; then
      printf 'error: expected line missing from %s: %s\n' "$f" "$l" >&2
      return 1
    fi
  done
}

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

# Catalog form of a target: path-like types use $HOME/..., no trailing slash.
norm_target() { # type target
  local t="$2"
  case "$1" in
    path|prune|keep)
      # shellcheck disable=SC2016
      case "$t" in
        \~) t='$HOME' ;;
        \~/*) t="\$HOME/${t#\~/}" ;;
      esac
      while [[ "$t" == */ && "$t" != "/" ]]; do t="${t%/}"; done
      ;;
  esac
  printf '%s' "$t"
}

add_entry() { # type target reason
  local target
  case "$1" in
    path|pattern|prune|keep) ;;
    *) die "unknown type '$1' (expected path, pattern, prune or keep)" ;;
  esac
  check_field "target" "$2"
  check_field "reason" "$3"
  target="$(norm_target "$1" "$2")"
  case "$ENTRIES" in
    *"${LF}$1|${target}|"*) die "rule given twice: $1|${target}" ;;
  esac
  ENTRIES="${ENTRIES}${LF}$1|${target}|$3"
}

set_name() {
  local n="$1"
  if [[ "$n" == *[[:cntrl:]]* ]]; then
    die "category name must not contain control characters or newlines"
  fi
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

# True when an active or commented-out (opt-in) rule of this type and target
# (normalized like norm_target, on both sides) is already in the catalog.
entry_exists() { # type normalized-target
  T="$1" V="$2" awk '
    function norm(t) {
      if (t == "~") t = "$HOME"
      else if (substr(t, 1, 2) == "~/") t = "$HOME/" substr(t, 3)
      while (length(t) > 1 && substr(t, length(t)) == "/") t = substr(t, 1, length(t) - 1)
      return t
    }
    BEGIN { type = ENVIRON["T"]; want = ENVIRON["V"] }
    {
      line = $0
      if (substr(line, 1, 2) == "# ") line = substr(line, 3)
      i = index(line, "|")
      if (i == 0 || substr(line, 1, i - 1) != type) next
      rest = substr(line, i + 1)
      j = index(rest, "|")
      t = (j > 0) ? substr(rest, 1, j - 1) : rest
      if (type != "pattern") t = norm(t)
      if (t == want) f = 1
    }
    END { exit !f }' "$CONF"
}

# The only reader of prompts. Any read failure is an abort: at end of input
# `read` fails even when it filled REPLY with a partial line, which is ignored.
ask() { # prompt -> REPLY
  printf '%s' "$1" >&2
  IFS= read -r REPLY || die "input ended (EOF); nothing written"
}

acquire_lock() {
  if ! mkdir "${ROOT}/.add-category.lock" 2>/dev/null; then
    die "cannot take ${ROOT}/.add-category.lock: another add-category run is in progress (or remove a stale lock)"
  fi
  LOCK="${ROOT}/.add-category.lock"
}

# Count lines of $2 that match the extended regex $1 (0 when none).
count_lines() { grep -Ec "$1" "$2" || true; }

main() {
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      --dry-run) DRY_RUN=1; shift ;;
      --skip-tests) SKIP_TESTS=1; shift ;;
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
  SMOKE="${ROOT}/${SMOKE_REL}"
  [[ -r "$CONF" ]] || die "cannot read ${CONF}"

  # ADD_CATEGORY_ASSUME_TTY=1 is a test hook: prompt even when stdin is a pipe.
  if [[ -t 0 || "${ADD_CATEGORY_ASSUME_TTY:-}" = 1 ]]; then
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

  # From here on the tree is read and edited under the lock.
  acquire_lock

  category_exists "$NAME" && die "category already exists: ${NAME}"
  local type target reason b_static="" b_dynamic="" b_prune="" n=0
  local added=("#@${NAME}")
  while IFS='|' read -r type target reason; do
    [[ -n "$type" ]] || continue
    if entry_exists "$type" "$target"; then
      die "rule already exists: ${type}|${target}"
    fi
    case "$type" in
      pattern) b_dynamic="${b_dynamic}${type}|${target}|${reason}${LF}" ;;
      prune) b_prune="${b_prune}${type}|${target}|${reason}${LF}" ;;
      *) b_static="${b_static}${type}|${target}|${reason}${LF}" ;;
    esac
    added+=("${type}|${target}|${reason}")
    n=$((n + 1))
  done <<EOF
${ENTRIES}
EOF
  # Same layout as the file: path/keep end the static section, pattern ends the
  # dynamic section, prune goes at the end of the file.
  if [[ -n "$b_static" ]]; then b_static="#@${NAME}${LF}${b_static}${LF}"; fi
  if [[ -n "$b_dynamic" ]]; then b_dynamic="#@${NAME}${LF}${b_dynamic}${LF}"; fi
  if [[ -n "$b_prune" ]]; then b_prune="${LF}#@${NAME}${LF}${b_prune}"; fi

  # The insertion anchors must be recognizable, or the edit could silently do nothing.
  local dyn_re='^# ── DYNAMIC SCAN PATTERNS' prune_re='^# ── SCAN PRUNE ZONES'
  if [[ "$(count_lines "$dyn_re" "$CONF")" -ne 1 || "$(count_lines "$prune_re" "$CONF")" -ne 1 ]]; then
    die "unrecognized structure: ${CONF} must contain exactly one '# ── DYNAMIC SCAN PATTERNS' and one '# ── SCAN PRUNE ZONES' banner line"
  fi
  local mark_re='^EXPECTED_CATEGORY_COUNT=[0-9]+ # add-category: expected category count$'
  if [[ ! -r "$SMOKE" || "$(count_lines "$mark_re" "$SMOKE")" -ne 1 ]]; then
    die "unrecognized structure: ${SMOKE} must contain exactly one EXPECTED_CATEGORY_COUNT=<n> # add-category: expected category count line"
  fi

  # Build the edited files on a temporary copy of the whole repository.
  make_work_dir
  local e
  for e in "$ROOT"/* "$ROOT"/.[!.]*; do
    case "$(basename "$e")" in .git|.add-category.lock) continue ;; esac
    if [[ -e "$e" ]]; then cp -R "$e" "$WORK/"; fi
  done
  local w_conf="${WORK}/config/default.conf" w_smoke="${WORK}/${SMOKE_REL}"
  B_STATIC="$b_static" B_DYNAMIC="$b_dynamic" awk '
    /^# ── DYNAMIC SCAN PATTERNS/ { printf "%s", ENVIRON["B_STATIC"] }
    /^# ── SCAN PRUNE ZONES/ { printf "%s", ENVIRON["B_DYNAMIC"] }
    { print }
  ' "$CONF" > "${w_conf}.new"
  printf '%s' "$b_prune" >> "${w_conf}.new"
  mv "${w_conf}.new" "$w_conf"
  # Test hook (harmless): removes this exact line from the generated config, to
  # prove that verify_added_lines catches a rule lost during generation.
  if [[ -n "${ADD_CATEGORY_TEST_DROP_LINE:-}" ]]; then
    grep -vFx -- "$ADD_CATEGORY_TEST_DROP_LINE" "$w_conf" > "${w_conf}.new" || true
    mv "${w_conf}.new" "$w_conf"
  fi
  awk '
    /^EXPECTED_CATEGORY_COUNT=[0-9]+ # add-category: expected category count$/ {
      split($0, a, /[= ]/)
      print "EXPECTED_CATEGORY_COUNT=" (a[2] + 1) " # add-category: expected category count"
      next
    }
    { print }
  ' "$SMOKE" > "${w_smoke}.new"
  mv "${w_smoke}.new" "$w_smoke"

  # The rules must really be in the new file, and the catalog must agree with the guard.
  verify_added_lines "$w_conf" "${added[@]}" || die "internal error: an added line is missing after the edit; nothing written"
  if cmp -s "$CONF" "$w_conf"; then die "internal error: config unchanged after the edit; nothing written"; fi
  local labels expected
  labels="$({ grep -E '^#@' "$w_conf" || true; } | sort -u | wc -l | tr -d ' ')"
  expected="$(sed -n 's/^EXPECTED_CATEGORY_COUNT=\([0-9][0-9]*\) .*/\1/p' "$w_smoke")"
  [[ "$labels" = "$expected" ]] ||
    die "${SMOKE_REL} expects ${expected} categories but the config has ${labels} distinct '#@' labels (inconsistent before the edit?); nothing written"

  # Validate on the copy; the real files stay untouched until all of it passes.
  local out rc=0
  out="$(bash "${WORK}/scripts/check-conf.sh" "$w_conf" 2>&1)" || rc=$?
  if [[ "$rc" -ne 0 ]]; then printf '%s\n' "$out" >&2; die "config validation failed; nothing written"; fi
  out="$(bash "${WORK}/scripts/check-i18n.sh" "${WORK}/locales/en.sh" "${WORK}/locales/fr.sh" 2>&1)" || rc=$?
  if [[ "$rc" -ne 0 ]]; then printf '%s\n' "$out" >&2; die "locale parity check failed; nothing written"; fi

  diff -u "$CONF" "$w_conf" || true
  diff -u "$SMOKE" "$w_smoke" || true
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'Dry run: %d rule(s) for category "%s" planned, nothing written.\n' "$n" "$NAME"
    return 0
  fi
  if [[ "$SKIP_TESTS" -eq 0 ]]; then
    echo "Running make check on a temporary copy (use --skip-tests to skip)..."
    # The ceiling keeps git from finding a repository above the copy (the Makefile sets core.hooksPath).
    GIT_CEILING_DIRECTORIES="$(dirname "$WORK")" make -C "$WORK" check || die "make check failed on the copy; nothing written"
  fi

  # Install: back up the originals, then write INTO the existing files (mode and
  # inode are kept). Any failure or signal restores both from the backup (cleanup).
  BAK="${WORK}/.backup"
  mkdir "$BAK"
  cp -p "$CONF" "${BAK}/default.conf"
  cp -p "$SMOKE" "${BAK}/smoke"
  INSTALLING=1
  cp "$w_conf" "$CONF" || die "could not write ${CONF}; originals restored"
  cp "$w_smoke" "$SMOKE" || die "could not write ${SMOKE}; originals restored"
  INSTALLING=0
  printf 'Added category "%s" (%d rule(s)) to %s and bumped EXPECTED_CATEGORY_COUNT to %s.\n' "$NAME" "$n" "$CONF" "$expected"
  if [[ "$SKIP_TESTS" -eq 1 ]]; then
    printf 'Lint and tests were skipped: run "make check" before committing.\n'
  fi
}

# Run only when executed, so tests can source the helpers above from a file.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
