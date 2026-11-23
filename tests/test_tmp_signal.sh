#!/usr/bin/env bash
# test_tmp_signal.sh — a signal in the mktemp window never strands a tm_exc_* file (#92)
#
# Every temporary file of tm_exclusions.sh lives in one private work directory
# created by a single `mktemp -d`; INT/TERM/HUP are ignored between that mktemp
# and the registration of the directory for cleanup. This suite reproduces the
# race: a `mktemp` shim creates the real file/directory, then stays suspended
# (its output not yet returned to the script) while a signal is sent to the
# script, exactly the window described in the issue. Whatever the outcome of the
# run, no tm_exc_* entry may remain in TMPDIR.
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
# for it) until $HOLD_GO exists. Later calls pass straight through.
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
printf '%s\n' "$out"
STUB
chmod +x "${WORK}/bin/"*

# run_interrupted <SIG> <label>: run the CLI, interrupt it while the first
# mktemp is suspended after creating its entry, then let it go on and check
# that TMPDIR holds no tm_exc_* entry.
run_interrupted() {
    local sig="$1" label="$2" hold pid i=0 left rc
    hold="$(mktemp -d "${WORK}/hold.XXXXXX")"
    mkdir "${hold}/tmp"
    # Job control (set -m) so the background job keeps the default SIGINT
    # disposition: a non-interactive `&` job would ignore it and could not trap it.
    (
        set -m
        HOME="${HOME_DIR}" TMPDIR="${hold}/tmp" PATH="${WORK}/bin:${PATH}" \
            REAL_MKTEMP="$REAL_MKTEMP" HOLD_MARK="${hold}/mark" HOLD_GO="${hold}/go" \
            TM_EXCLUSIONS_DEFAULT_CONF="$CONF" \
            "$BASH" "$TM_EXCLUSIONS" --dry-run --quiet >"${hold}/out" 2>&1 &
        echo $! > "${hold}/pid"
    )
    pid="$(cat "${hold}/pid")"
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
    rc=0
    i=0
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 400 ]; do
        sleep 0.05 2>/dev/null || sleep 1
        i=$((i + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill -KILL "$pid" 2>/dev/null || true
        rc=1
    fi
    left="$(find "${hold}/tmp" -name 'tm_exc_*' 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$rc" -eq 0 ] && [ "$left" -eq 0 ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        printf '%b  PASS%b %s: no tm_exc_* left in TMPDIR\n' "$GREEN" "$NC" "$label"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        printf '%b  FAIL%b %s: %s tm_exc_* entr(ies) left in TMPDIR (hung=%s)\n' "$RED" "$NC" "$label" "$left" "$rc"
        find "${hold}/tmp" -name 'tm_exc_*' 2>/dev/null | sed 's/^/        /'
    fi
}

echo "tm-exclusions temporary file signal window tests (#92)"
echo "========================================"

run_interrupted TERM "SIGTERM between mktemp and registration"
run_interrupted INT "SIGINT between mktemp and registration"
run_interrupted HUP "SIGHUP between mktemp and registration"

# Control: without any signal the same run leaves nothing either.
run_interrupted CONT "no-signal control run"

test_summary
