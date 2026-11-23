#!/usr/bin/env bash
# test_tmp_signal.sh — a signal in the mktemp window never strands a tm_exc_* file (#92)
#
# Every temporary file of tm_exclusions.sh lives in one private work directory
# created by a single `mktemp -d`; around that mktemp INT/TERM/HUP are recorded
# (the mktemp child ignores them), then the normal handlers are restored and a
# recorded signal is replayed to them (cleanup, exit 128+n). This suite
# reproduces the race: a `mktemp` shim creates the real directory, then stays
# suspended (its output not yet returned to the script) while a signal is sent
# to the script, exactly the window described in the issue. The CLI must then
# die with the status of that signal and no tm_exc_* entry may remain in TMPDIR.
# Other cases: a TMPDIR holding a newline must not make the cleanup remove a
# decoy directory, and a TMPDIR symbolic link retargeted during mktemp must
# still be cleaned where the directory was created.
# A signal ignored when the suite starts (an `&` job, nohup) cannot be trapped by
# any shell: perl resets the dispositions when available, otherwise the affected
# case is reported SKIP with its reason (never a silent PASS).
# Run: bash tests/test_tmp_signal.sh   (use /bin/bash 3.2 and Bash 5 both)

set -euo pipefail

export LANG=C
export LC_ALL=C
export TM_EXCLUSIONS_SKIP_INVENTORY=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/test_helpers.sh
source "${SCRIPT_DIR}/test_helpers.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

REAL_MKTEMP="$(command -v mktemp)"

# Fake HOME with one pattern match so the scan creates its temporary files.
HOME_DIR="${WORK}/home"
mkdir -p "${HOME_DIR}/proj/node_modules" "${WORK}/bin"
CONF="${WORK}/test.conf"
printf 'pattern|node_modules|node_modules directories\n' > "$CONF"

cat > "${WORK}/bin/tmutil" <<'STUB'
#!/bin/sh
if [ "$1" = isexcluded ]; then printf '[Included] %s\n' "$2"; fi
exit 0
STUB
cat > "${WORK}/bin/sudo" <<'STUB'
#!/bin/sh
case "$1" in
    -n|-v) exit 0 ;;
    tmutil) shift; exec tmutil "$@" ;;
    *) exit 1 ;;
esac
STUB
# mktemp shim: the first call creates the real entry, announces it with
# $HOLD_MARK, then blocks (the caller's command substitution is still waiting
# for it) until $HOLD_GO exists. Later calls pass straight through. When
# $RETARGET_LINK is set, that symbolic link is then pointed at $RETARGET_TO.
cat > "${WORK}/bin/mktemp" <<'STUB'
#!/bin/sh
out="$("$REAL_MKTEMP" "$@")" || exit $?
if [ ! -e "$HOLD_MARK" ]; then
    : > "$HOLD_MARK"
    n=0
    while [ ! -e "$HOLD_GO" ] && [ "$n" -lt 400 ]; do
        sleep 0.05 2>/dev/null || sleep 1
        n=$((n + 1))
    done
fi
if [ -n "${MKTEMP_LOG:-}" ]; then printf '%s\n' "$*" >> "$MKTEMP_LOG"; fi
if [ -n "${RETARGET_LINK:-}" ]; then ln -sfn "$RETARGET_TO" "$RETARGET_LINK"; fi
printf '%s\n' "$out"
STUB
chmod +x "${WORK}/bin/"*

DEFAULT_SIGS=()
HAVE_PERL=0
if command -v perl >/dev/null 2>&1; then
    HAVE_PERL=1
    # shellcheck disable=SC2016  # Perl code, not shell expansion
    DEFAULT_SIGS=(perl -e '$SIG{INT} = $SIG{TERM} = $SIG{HUP} = "DEFAULT"; exec @ARGV or exit 127' --)
fi

# sig_ignored <SIG>: succeeds when a child of this suite would start with SIG
# ignored (then no shell can trap it): a bash raising it on itself survives.
sig_ignored() {
    local out
    # shellcheck disable=SC2016  # expanded by the inner bash
    out="$("$BASH" -c 'kill -s "$1" $$; echo survived' _ "$1" 2>/dev/null || true)"
    [ "$out" = survived ]
}

# run_interrupted <SIG> <expected-exit> <label>: run the CLI, interrupt it while
# the first mktemp is suspended after creating its entry, then let it go on and
# check both that TMPDIR holds no tm_exc_* entry and that the signal was not
# swallowed: the CLI must end with the status of a death by that signal
# (128+n), not carry on and exit 0.
run_interrupted() {
    local sig="$1" want="$2" label="$3" hold pid i=0 left got=""
    if [ "$HAVE_PERL" -eq 0 ] && [ "$sig" != CONT ] && sig_ignored "$sig"; then
        printf '%b  SKIP%b %s: SIG%s is ignored at suite start and perl is not available to reset it\n' \
            "$YELLOW" "$NC" "$label" "$sig"
        return 0
    fi
    hold="$(mktemp -d "${WORK}/hold.XXXXXX")"
    mkdir "${hold}/tmp"
    # The CLI must start with the default INT/TERM/HUP dispositions: a
    # non-interactive `&` job (or a suite itself started that way) ignores SIGINT,
    # and a shell cannot trap a signal ignored on entry. Job control (set -m) is
    # not enough then, so perl resets the dispositions before exec when present.
    # The inner subshell records the CLI's exit status (wait) for the assertions.
    (
        set -m
        (
            set -m
            HOME="${HOME_DIR}" TMPDIR="${hold}/tmp" PATH="${WORK}/bin:${PATH}" \
                REAL_MKTEMP="$REAL_MKTEMP" HOLD_MARK="${hold}/mark" HOLD_GO="${hold}/go" \
                TM_EXCLUSIONS_DEFAULT_CONF="$CONF" \
                ${DEFAULT_SIGS[@]+"${DEFAULT_SIGS[@]}"} "$BASH" "$TM_EXCLUSIONS" --dry-run --quiet >"${hold}/out" 2>&1 &
            cli=$!
            # Written then renamed: the reader never sees a created-but-empty file.
            echo "$cli" > "${hold}/pid.tmp"
            mv "${hold}/pid.tmp" "${hold}/pid"
            cli_rc=0
            wait "$cli" || cli_rc=$?
            echo "$cli_rc" > "${hold}/rc.tmp"
            mv "${hold}/rc.tmp" "${hold}/rc"
        ) >/dev/null 2>&1 &
    )
    i=0
    while [ ! -e "${hold}/pid" ] && [ "$i" -lt 200 ]; do
        sleep 0.05 2>/dev/null || sleep 1
        i=$((i + 1))
    done
    pid="$(cat "${hold}/pid")"
    i=0
    while [ ! -e "${hold}/mark" ] && [ "$i" -lt 200 ]; do
        sleep 0.05 2>/dev/null || sleep 1
        i=$((i + 1))
    done
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ ! -e "${hold}/mark" ]; then
        TESTS_FAILED=$((TESTS_FAILED + 1))
        printf '%b  FAIL%b %s: mktemp window never reached\n' "$RED" "$NC" "$label"
        kill -KILL "$pid" 2>/dev/null || true
        : > "${hold}/go"
        return 0
    fi
    kill -s "$sig" "$pid" 2>/dev/null || true
    : > "${hold}/go"
    i=0
    while [ ! -e "${hold}/rc" ] && [ "$i" -lt 400 ]; do
        sleep 0.05 2>/dev/null || sleep 1
        i=$((i + 1))
    done
    if [ -e "${hold}/rc" ]; then
        got="$(cat "${hold}/rc")"
    else
        kill -KILL "$pid" 2>/dev/null || true
        got="hung"
    fi
    left="$(find "${hold}/tmp" -name 'tm_exc_*' 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$got" = "$want" ] && [ "$left" -eq 0 ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        printf '%b  PASS%b %s: exit %s, no tm_exc_* left in TMPDIR\n' "$GREEN" "$NC" "$label" "$got"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        printf '%b  FAIL%b %s: exit %s (want %s), %s tm_exc_* entr(ies) left in TMPDIR\n' \
            "$RED" "$NC" "$label" "$got" "$want" "$left"
        find "${hold}/tmp" -name 'tm_exc_*' 2>/dev/null | sed 's/^/        /'
    fi
}

echo "tm-exclusions temporary file signal window tests (#92)"
echo "========================================"

run_interrupted TERM 143 "SIGTERM between mktemp and registration"
run_interrupted INT 130 "SIGINT between mktemp and registration"
run_interrupted HUP 129 "SIGHUP between mktemp and registration"

# Control: without any signal the same run succeeds and leaves nothing either.
run_interrupted CONT 0 "no-signal control run"

# A TMPDIR that is a symbolic link retargeted while mktemp runs: the directory
# created in the first target must still be removed, and the run must succeed.
LNK_A="${WORK}/lnk_a"
LNK_B="${WORK}/lnk_b"
mkdir -p "$LNK_A" "$LNK_B"
ln -s "$LNK_A" "${WORK}/lnk"
lk_rc=0
HOME="${HOME_DIR}" TMPDIR="${WORK}/lnk" PATH="${WORK}/bin:${PATH}" \
    REAL_MKTEMP="$REAL_MKTEMP" HOLD_MARK="${WORK}" \
    RETARGET_LINK="${WORK}/lnk" RETARGET_TO="$LNK_B" \
    TM_EXCLUSIONS_DEFAULT_CONF="$CONF" \
    "$BASH" "$TM_EXCLUSIONS" --dry-run --quiet >/dev/null 2>&1 || lk_rc=$?
assert_eq 0 "$lk_rc" "TMPDIR symlink retargeted during mktemp: the run still succeeds"
assert_true "TMPDIR symlink retargeted during mktemp: nothing left in the first target" \
    test -z "$(find "$LNK_A" -mindepth 1 2>/dev/null)"
assert_true "TMPDIR symlink retargeted during mktemp: nothing left in the new target" \
    test -z "$(find "$LNK_B" -mindepth 1 2>/dev/null)"

# A TMPDIR symbolic link whose physical path ends with, or contains, a newline
# must fall back to /tmp: the trailing newline used to be eaten (the path became
# that of the neighbouring directory) and a middle one kept the raw link.
NLREAL_END="${WORK}/nlreal"$'\n'
NLREAL_MID="${WORK}/nlmid"$'\n'"x"
mkdir -p "${WORK}/nlreal" "$NLREAL_END" "$NLREAL_MID"
ln -s "$NLREAL_END" "${WORK}/nl_end_lnk"
ln -s "$NLREAL_MID" "${WORK}/nl_mid_lnk"
for nl_case in nl_end_lnk nl_mid_lnk; do
    : > "${WORK}/mktemp.log"
    nl_rc=0
    HOME="${HOME_DIR}" TMPDIR="${WORK}/${nl_case}" PATH="${WORK}/bin:${PATH}" \
        REAL_MKTEMP="$REAL_MKTEMP" HOLD_MARK="${WORK}" MKTEMP_LOG="${WORK}/mktemp.log" \
        TM_EXCLUSIONS_DEFAULT_CONF="$CONF" \
        "$BASH" "$TM_EXCLUSIONS" --dry-run --quiet >/dev/null 2>&1 || nl_rc=$?
    assert_eq 0 "$nl_rc" "${nl_case}: the run still succeeds"
    assert_eq "-d /tmp/tm_exc_work.XXXXXX" "$(head -n 1 "${WORK}/mktemp.log")" \
        "${nl_case}: the work directory is created under /tmp, not through the link"
done
assert_true "newline-named symlink targets: nothing left in any of them" \
    test -z "$(find "${WORK}/nlreal" "$NLREAL_END" "$NLREAL_MID" -mindepth 1 2>/dev/null)"

# CDPATH=. with a relative TMPDIR: cd prints the directory it resolved, which
# must not leak into the captured physical path (the run used to fall back to /tmp).
mkdir -p "${WORK}/cdp/local"
CDP_PHYS="$(cd "${WORK}/cdp/local" && pwd -P)"
: > "${WORK}/mktemp.log"
cdp_rc=0
(
    cd "${WORK}/cdp"
    HOME="${HOME_DIR}" TMPDIR=local CDPATH=. PATH="${WORK}/bin:${PATH}" \
        REAL_MKTEMP="$REAL_MKTEMP" HOLD_MARK="${WORK}" MKTEMP_LOG="${WORK}/mktemp.log" \
        TM_EXCLUSIONS_DEFAULT_CONF="$CONF" \
        "$BASH" "$TM_EXCLUSIONS" --dry-run --quiet >/dev/null 2>&1
) || cdp_rc=$?
assert_eq 0 "$cdp_rc" "CDPATH=. TMPDIR=local: the run succeeds"
assert_eq "-d ${CDP_PHYS}/tm_exc_work.XXXXXX" "$(head -n 1 "${WORK}/mktemp.log")" \
    "CDPATH=. TMPDIR=local: the relative TMPDIR is used (physical path), not /tmp"
assert_true "CDPATH=. TMPDIR=local: nothing left in that directory" \
    test -z "$(find "${WORK}/cdp/local" -mindepth 1 2>/dev/null)"

# A TMPDIR holding a newline must never make the cleanup remove another
# directory: the work directory path was once split at the newline, and the
# first half (a decoy here, with a file in it) deleted recursively.
DECOY="${WORK}/decoy"
BADTMP="${DECOY}"$'\n'"sub"
mkdir -p "${DECOY}" "${BADTMP}"
printf 'precious\n' > "${DECOY}/keep.txt"
nl_rc=0
# HOLD_MARK names an existing path: the mktemp shim then never holds.
HOME="${HOME_DIR}" TMPDIR="${BADTMP}" PATH="${WORK}/bin:${PATH}" \
    REAL_MKTEMP="$REAL_MKTEMP" HOLD_MARK="${WORK}" \
    TM_EXCLUSIONS_DEFAULT_CONF="$CONF" \
    "$BASH" "$TM_EXCLUSIONS" --dry-run --quiet >/dev/null 2>&1 || nl_rc=$?
assert_eq 0 "$nl_rc" "TMPDIR with a newline: the run still succeeds (falls back to /tmp)"
assert_true "TMPDIR with a newline: the decoy directory and its file survive" test -f "${DECOY}/keep.txt"
assert_true "TMPDIR with a newline: nothing is created in the odd TMPDIR" \
    test -z "$(find "${BADTMP}" -mindepth 1 2>/dev/null)"

test_summary
