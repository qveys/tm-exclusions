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

SELF_DIR="$(
    source_dir="$(dirname -- "${BASH_SOURCE[0]}")" || exit 1
    [[ "$source_dir" != -* ]] || source_dir="./$source_dir"
    CDPATH='' cd -P -- "${source_dir}" >/dev/null 2>&1 && pwd
)"
ROOT="$(cd "${SELF_DIR}/.." && pwd)"
LF=$'\n'
SMOKE_REL="tests/smoke.bats-like.sh"
NAME=""
HAVE_NAME=0
ENTRIES=""   # one "\ntype|target|reason" per rule
DRY_RUN=0
SKIP_TESTS=0
LOCK=""      # lock directory, set only once this run owns it
GUARD=""     # O_EXCL guard file serializing the lock mkdir, set only while this run owns it
WORK=""      # temporary copy of the repository (a sibling of ROOT, see make_work_dir)
BAK=""       # snapshot of the two files (a sibling of WORK, outside the copied tree)
MAIN_PID=$$  # the main shell: cleanup must never act from a subshell
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
Limits: --root files must be regular files (symbolic links are refused). A
signal in the few microseconds between creating the lock and recording it, or a
second SIGKILL during the restore, can leave a stale .add-category.lock or
.add-category.lock.guard, or an unrestored file: remove them by hand and check
git status.
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
  [[ "$$" == "$MAIN_PID" ]] || return 0 # $$ is the main shell's pid even in subshells
  trap - EXIT
  if [[ "$INSTALLING" -eq 1 ]]; then
    trap '' INT TERM HUP # a second signal must not cut the restore short
    restore_originals || KEEP_WORK=1
  fi
  if [[ -n "$GUARD" ]]; then rm -f "$GUARD"; fi
  if [[ -n "$LOCK" ]]; then rmdir "$LOCK" 2>/dev/null || true; fi
  if [[ "$KEEP_WORK" -eq 0 ]]; then
    case "$WORK" in *.add-category.*) rm -rf "$WORK" ;; esac
    case "$BAK" in *.add-category.*.snapshot) rm -rf "$BAK" ;; esac
  fi
}

# Working copy: a sibling of the repository root, else under $HOME. Never under
# TMPDIR, /var/folders or /private/var/folders: the catalog excludes
# /private/var/folders and the smoke test would fail there on a valid copy.
make_work_dir() {
  local real tmp=""
  WORK=""
  real="$(CDPATH='' cd -P -- "$(dirname -- "${ROOT%/}")" >/dev/null 2>&1 && pwd)" || real=""
  if [[ -n "${TMPDIR:-}" ]]; then tmp="$(cd "$TMPDIR" 2>/dev/null && pwd -P)" || tmp=""; fi
  if [[ -n "$real" && "${real}/" != /var/folders/* && "${real}/" != /private/var/folders/* &&
    ( -z "$tmp" || "${real}/" != "${tmp}/"* ) ]]; then
    WORK="$(mktemp -d "${ROOT%/}.add-category.XXXXXX" 2>/dev/null)" || WORK=""
  fi
  if [[ -z "$WORK" ]]; then
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
category_exists() { # name file
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
  done < "$2"
  return 1
}

# True when an active or commented-out (opt-in) rule of this type and target
# (normalized like norm_target, on both sides) is already in the catalog.
entry_exists() { # type normalized-target file
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
    END { exit !f }' "$3"
}

# The only reader of prompts. Any read failure is an abort: at end of input
# `read` fails even when it filled REPLY with a partial line, which is ignored.
ask() { # prompt -> REPLY
  printf '%s' "$1" >&2
  IFS= read -r REPLY || die "input ended (EOF); nothing written"
}

# The lock is the directory .add-category.lock. Not every `mkdir` binary is
# exclusive under a race (uutils coreutils treats EEXIST as success), so the mkdir
# is serialized by a guard file created with noclobber (open with O_EXCL, done by
# the shell itself) and removed right after the mkdir.
# The EXIT/INT/TERM/HUP traps are installed before this runs. GUARD/LOCK are set
# right after each successful creation; a signal in the few microseconds in
# between would leave them behind (documented limit: remove the stale
# .add-category.lock and .add-category.lock.guard by hand).
acquire_lock() {
  local msg="cannot take ${ROOT}/.add-category.lock: another add-category run is in progress (or remove a stale .add-category.lock / .add-category.lock.guard)"
  if ! (set -C; : > "${ROOT}/.add-category.lock.guard") 2>/dev/null; then die "$msg"; fi
  GUARD="${ROOT}/.add-category.lock.guard"
  if ! mkdir "${ROOT}/.add-category.lock" 2>/dev/null; then die "$msg"; fi
  LOCK="${ROOT}/.add-category.lock"
  rm -f "$GUARD"
  GUARD=""
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
  if [[ -L "$CONF" || -L "$SMOKE" ]]; then
    die "${CONF} and ${SMOKE} must be regular files, not symbolic links (the install writes in place); nothing written"
  fi

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

  # From here on the tree is read and edited under the lock. Everything below is
  # derived from ONE snapshot of the two files, and the install refuses to write if
  # they differ from it: a lock that was lost for any reason cannot cause a lost update.
  acquire_lock
  [[ -r "$SMOKE" ]] || die "cannot read ${SMOKE}"
  make_work_dir
  BAK="${WORK}.snapshot"
  mkdir "$BAK"
  cp -p "$CONF" "${BAK}/default.conf"
  cp -p "$SMOKE" "${BAK}/smoke"
  local s_conf="${BAK}/default.conf" s_smoke="${BAK}/smoke"

  category_exists "$NAME" "$s_conf" && die "category already exists: ${NAME}"
  local type target reason b_static="" b_dynamic="" b_prune="" n=0
  local added=("#@${NAME}")
  while IFS='|' read -r type target reason; do
    [[ -n "$type" ]] || continue
    if entry_exists "$type" "$target" "$s_conf"; then
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
  if [[ "$(count_lines "$dyn_re" "$s_conf")" -ne 1 || "$(count_lines "$prune_re" "$s_conf")" -ne 1 ]]; then
    die "unrecognized structure: ${CONF} must contain exactly one '# ── DYNAMIC SCAN PATTERNS' and one '# ── SCAN PRUNE ZONES' banner line"
  fi
  local mark_re='^EXPECTED_CATEGORY_COUNT=[0-9]+ # add-category: expected category count$'
  if [[ "$(count_lines "$mark_re" "$s_smoke")" -ne 1 ]]; then
    die "unrecognized structure: ${SMOKE} must contain exactly one EXPECTED_CATEGORY_COUNT=<n> # add-category: expected category count line"
  fi

  # Build the edited files on a temporary copy of the whole repository.
  local e
  for e in "$ROOT"/* "$ROOT"/.[!.]*; do
    case "$(basename "$e")" in .git|.add-category.lock|.add-category.lock.guard) continue ;; esac
    if [[ -e "$e" ]]; then cp -R "$e" "$WORK/"; fi
  done
  local w_conf="${WORK}/config/default.conf" w_smoke="${WORK}/${SMOKE_REL}"
  B_STATIC="$b_static" B_DYNAMIC="$b_dynamic" awk '
    /^# ── DYNAMIC SCAN PATTERNS/ { printf "%s", ENVIRON["B_STATIC"] }
    /^# ── SCAN PRUNE ZONES/ { printf "%s", ENVIRON["B_DYNAMIC"] }
    { print }
  ' "$s_conf" > "${w_conf}.new"
  printf '%s' "$b_prune" >> "${w_conf}.new"
  mv "${w_conf}.new" "$w_conf"
  awk '
    /^EXPECTED_CATEGORY_COUNT=[0-9]+ # add-category: expected category count$/ {
      split($0, a, /[= ]/)
      print "EXPECTED_CATEGORY_COUNT=" (a[2] + 1) " # add-category: expected category count"
      next
    }
    { print }
  ' "$s_smoke" > "${w_smoke}.new"
  mv "${w_smoke}.new" "$w_smoke"

  # The rules must really be in the new file, and the catalog must agree with the guard.
  verify_added_lines "$w_conf" "${added[@]}" || die "internal error: an added line is missing after the edit; nothing written"
  if cmp -s "$s_conf" "$w_conf"; then die "internal error: config unchanged after the edit; nothing written"; fi
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

  diff -u "$s_conf" "$w_conf" || true
  diff -u "$s_smoke" "$w_smoke" || true
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'Dry run: %d rule(s) for category "%s" planned, nothing written.\n' "$n" "$NAME"
    return 0
  fi
  if [[ "$SKIP_TESTS" -eq 0 ]]; then
    echo "Running make check on a temporary copy (use --skip-tests to skip)..."
    # The ceiling keeps git from finding a repository above the copy (the Makefile sets core.hooksPath).
    GIT_CEILING_DIRECTORIES="$(dirname "$WORK")" make -C "$WORK" check || die "make check failed on the copy; nothing written"
  fi

  # Install: refuse if either file changed since the snapshot, then write INTO the
  # existing files (mode and inode are kept). Any failure or signal restores both
  # from the snapshot (cleanup).
  if ! cmp -s "$CONF" "$s_conf" || ! cmp -s "$SMOKE" "$s_smoke"; then
    die "${CONF} or ${SMOKE} changed while this run was working (concurrent edit or lost lock); nothing written"
  fi
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
