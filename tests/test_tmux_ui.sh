#!/usr/bin/env bash
# test_tmux_ui.sh — optional two-pane tmux interface (#14)
#
# Verifies the observable contract without mutating Time Machine and, except for
# one opt-in isolated check on a dedicated -L socket, without touching a real
# tmux server:
#   - --tmux is documented (--help) and only activates on an interactive TTY
#   - two distinct destinations (progress/state vs the debug log stream)
#   - automatic fallback when tmux is missing or its launch fails
#   - --quiet and redirected stdout keep their current behavior even with --tmux
#   - arguments and exit status are preserved and the scan runs exactly once
#   - only the resources this run created are cleaned up
# Run: bash tests/test_tmux_ui.sh   (use /bin/bash 3.2 and Bash 5 both)
set -euo pipefail

export LANG=C
export LC_ALL=C
export TM_EXCLUSIONS_SKIP_INVENTORY=1
unset NO_COLOR TM_EXCLUSIONS_SKIP_DU TM_EXCLUSIONS_DEBUG_FIFO TM_EXCLUSIONS_TMUX_CHILD

# shellcheck source=tests/test_helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

B_HOME="$WORK/home"
B_BIN="$WORK/bin"
mkdir -p "$B_HOME/cache" "$B_BIN"

# tmutil stub: logs each subcommand so "the scan runs exactly once" is provable.
TMUTIL_CALLS="$WORK/tmutil.calls"
cat > "$B_BIN/tmutil" <<STUB
#!/bin/sh
printf '%s\n' "\$1" >> "$TMUTIL_CALLS"
if [ "\$1" = isexcluded ]; then printf '[Included] %s\n' "\$2"; fi
exit 0
STUB
cat > "$B_BIN/sudo" <<'STUB'
#!/bin/sh
case "$1" in -n|-v) exit 0 ;; tmutil) shift; exec tmutil "$@" ;; *) exit 1 ;; esac
STUB
cat > "$B_BIN/brew" <<'STUB'
#!/bin/sh
exit 0
STUB
chmod +x "$B_BIN/tmutil" "$B_BIN/sudo" "$B_BIN/brew"

# Minimal config: a single static path under the fake HOME, no system paths.
CONF="$WORK/min.conf"
printf 'path|%s/cache|tmux test path\n' "$B_HOME" > "$CONF"

isexcluded_count() { grep -c '^isexcluded$' "$TMUTIL_CALLS" 2>/dev/null || true; }

# ---------------------------------------------------------------------------
# PTY helper: run a command with stdout attached to a pseudo-terminal, capture
# the combined output into <out>, and return the command's status. python3 is
# portable and adds no header noise; the PTY-dependent tests are SKIPped when it
# is unavailable.
# ---------------------------------------------------------------------------
HAVE_PTY=0
PTY_RUNNER="$WORK/pty_runner.py"
if command -v python3 >/dev/null 2>&1; then
    HAVE_PTY=1
    cat > "$PTY_RUNNER" <<'PYEOF'
import os, pty, sys, errno
argv = sys.argv[1:]
pid, fd = pty.fork()
if pid == 0:
    try:
        os.execvp(argv[0], argv)
    except OSError:
        os._exit(127)
    os._exit(127)

# Drain the master pty to stdout until end-of-stream. On Linux, reading the
# master after the slave side closes raises EIO instead of returning b""; that
# is the normal end, not an error, and must not lose the child's exit status.
while True:
    try:
        data = os.read(fd, 65536)
    except OSError as exc:
        if exc.errno == errno.EIO:
            break
        raise
    if not data:
        break
    sys.stdout.buffer.write(data)

_, status = os.waitpid(pid, 0)
if os.WIFEXITED(status):
    sys.exit(os.WEXITSTATUS(status))
sys.exit(128 + (os.WTERMSIG(status) if os.WIFSIGNALED(status) else 1))
PYEOF
fi
# run_pty <out> <cmd> [args...]: returns the command's exit status.
run_pty() {
    local out="$1"
    shift
    python3 "$PTY_RUNNER" "$@" > "$out" 2>&1
}

# Stub tmux: parses "-L <sock> <subcommand> ..." and records the subcommand, its
# arguments and the pane environment it would have received. It emulates the
# left pane (runs the re-exec wrapper), the right pane (nothing to read) and
# attach-session (blocks until the wrapper writes the exit-status file). On
# TMUX_FAIL_NEW_SESSION=1 it fails new-session like an unavailable tmux.
STUB_TMUX_DIR="$WORK/tmux-stub"
mkdir -p "$STUB_TMUX_DIR"
cat > "$STUB_TMUX_DIR/tmux" <<'STUB'
#!/bin/sh
if [ "$1" = -L ]; then shift 2; fi
sub="$1"
printf 'SUB=%s ARGS=%s FIFO=%s DEBUG_FIFO=%s\n' \
    "$sub" "$*" "${TM_EXCLUSIONS_TMUX_FIFO:-}" "${TM_EXCLUSIONS_DEBUG_FIFO:-}" >> "$TMUX_CALLS"
if [ "${TMUX_FAIL_NEW_SESSION:-0}" = 1 ] && [ "$sub" = new-session ]; then exit 1; fi
case "$sub" in
    new-session)
        "${TM_EXCLUSIONS_TMUX_WRAPPER}" &
        ;;
    attach-session)
        i=0
        while [ ! -s "${TM_EXCLUSIONS_TMUX_RC}" ] && [ "$i" -lt 400 ]; do
            sleep 0.05 2>/dev/null || sleep 1
            i=$((i + 1))
        done
        ;;
esac
exit 0
STUB
chmod +x "$STUB_TMUX_DIR/tmux"

TMUX_CALLS="$WORK/tmux.calls"

echo "tm-exclusions optional tmux interface tests (#14)"
echo "========================================"

# --- Help documents --tmux (en/fr), and a help/config command never launches it
echo ""
echo "--- Help documents --tmux ---"
assert_output_contains "--tmux" "--help lists --tmux (en)" \
    env HOME="$B_HOME" PATH="$B_BIN:$PATH" bash "$TM_EXCLUSIONS" --help
assert_output_contains "--tmux" "--help lists --tmux (fr)" \
    env HOME="$B_HOME" PATH="$B_BIN:$PATH" bash "$TM_EXCLUSIONS" --lang fr --help

: > "$TMUX_CALLS"
assert_exit_code 0 "--tmux --help exits 0 without launching tmux" \
    env HOME="$B_HOME" PATH="$STUB_TMUX_DIR:$B_BIN:$PATH" bash "$TM_EXCLUSIONS" --tmux --help
assert_true "a help command never launches the tmux interface" test ! -s "$TMUX_CALLS"

# --- Redirected stdout: no tmux, current behavior, exit code preserved ---
echo ""
echo "--- Non-interactive stdout: no tmux ---"
: > "$TMUTIL_CALLS"
: > "$TMUX_CALLS"
assert_exit_code 0 "--tmux with redirected stdout still exits 0" \
    env HOME="$B_HOME" PATH="$STUB_TMUX_DIR:$B_BIN:$PATH" TM_EXCLUSIONS_DEFAULT_CONF="$CONF" \
        bash "$TM_EXCLUSIONS" --tmux --dry-run
assert_true "redirected stdout: tmux was never invoked" test ! -s "$TMUX_CALLS"
assert_eq 1 "$(isexcluded_count)" "redirected stdout: the scan still ran once"

# --- --quiet: no tmux, current behavior ---
echo ""
echo "--- --quiet keeps its behavior even with --tmux ---"
: > "$TMUX_CALLS"
assert_exit_code 0 "--tmux --quiet --dry-run exits 0" \
    env HOME="$B_HOME" PATH="$STUB_TMUX_DIR:$B_BIN:$PATH" TM_EXCLUSIONS_DEFAULT_CONF="$CONF" \
        bash "$TM_EXCLUSIONS" --tmux --quiet --dry-run
assert_true "--quiet: tmux was never invoked" test ! -s "$TMUX_CALLS"

if [ "$HAVE_PTY" -eq 0 ]; then
    echo "  SKIP interactive tmux tests: python3 (pty) unavailable"
else
    # --- tmux missing: warning to stderr, normal run, exit code preserved ---
    echo ""
    echo "--- tmux missing on an interactive TTY: fallback ---"
    : > "$TMUTIL_CALLS"
    rc=0
    run_pty "$WORK/out-no-tmux" \
        env HOME="$B_HOME" PATH="$B_BIN:/usr/bin:/bin" TERM=xterm TM_EXCLUSIONS_DEFAULT_CONF="$CONF" \
            bash "$TM_EXCLUSIONS" --tmux --dry-run || rc=$?
    assert_eq 0 "$rc" "tmux missing: the run still exits 0"
    assert_file_contains "$WORK/out-no-tmux" "tmux not found" \
        "tmux missing: the fallback is announced on stderr"
    assert_eq 1 "$(isexcluded_count)" "tmux missing: the scan still ran once"

    # --- tmux launch failure: fallback, no double scan ---
    echo ""
    echo "--- tmux launch failure: fallback ---"
    : > "$TMUTIL_CALLS"
    : > "$TMUX_CALLS"
    rc=0
    run_pty "$WORK/out-fail" \
        env HOME="$B_HOME" PATH="$STUB_TMUX_DIR:$B_BIN:$PATH" TERM=xterm \
            TM_EXCLUSIONS_DEFAULT_CONF="$CONF" TMUX_CALLS="$TMUX_CALLS" TMUX_FAIL_NEW_SESSION=1 \
            bash "$TM_EXCLUSIONS" --tmux --dry-run || rc=$?
    assert_eq 0 "$rc" "tmux new-session failure: the run still exits 0"
    assert_file_contains "$WORK/out-fail" "Could not start the tmux interface" \
        "tmux new-session failure: the fallback is announced"
    assert_eq 1 "$(isexcluded_count)" "tmux new-session failure: the scan ran exactly once (no double scan)"

    # --- Interactive two panes (stub): wiring, single scan, exit code, cleanup ---
    echo ""
    echo "--- Interactive two panes (stub tmux) ---"
    : > "$TMUTIL_CALLS"
    : > "$TMUX_CALLS"
    rc=0
    run_pty "$WORK/out-two-panes" \
        env HOME="$B_HOME" PATH="$STUB_TMUX_DIR:$B_BIN:$PATH" TERM=xterm \
            TM_EXCLUSIONS_DEFAULT_CONF="$CONF" TMUX_CALLS="$TMUX_CALLS" \
            bash "$TM_EXCLUSIONS" --tmux --dry-run || rc=$?
    assert_eq 0 "$rc" "interactive --tmux --dry-run exits 0 (child status preserved)"
    assert_true "left pane: new-session runs the re-exec wrapper" grep -q '^SUB=new-session' "$TMUX_CALLS"
    assert_true "right pane: split-window streams the debug FIFO" grep -q '^SUB=split-window' "$TMUX_CALLS"
    # shellcheck disable=SC2016  # the \$ is a literal dollar in the recorded pane command
    assert_true "the two destinations differ: left runs the wrapper, right tails the FIFO" \
        grep -q 'SUB=new-session ARGS=.*exec "\$TM_EXCLUSIONS_TMUX_WRAPPER"' "$TMUX_CALLS"
    # shellcheck disable=SC2016  # the \$ is a literal dollar in the recorded pane command
    assert_true "the right pane command tails the dedicated FIFO" \
        grep -q 'SUB=split-window ARGS=.*cat -- "\$TM_EXCLUSIONS_TMUX_FIFO"' "$TMUX_CALLS"
    assert_true "the child receives a non-empty TM_EXCLUSIONS_DEBUG_FIFO (log stream)" \
        grep -q 'DEBUG_FIFO=/.*debug\.fifo' "$TMUX_CALLS"
    assert_eq 1 "$(isexcluded_count)" "interactive two panes: the scan ran exactly once (no double scan)"
    assert_eq 0 "$(grep -c '^addexclusion$' "$TMUTIL_CALLS" || true)" \
        "interactive two panes: --dry-run preserved (no mutation)"
    assert_true "cleanup kills the session" grep -q '^SUB=kill-session' "$TMUX_CALLS"
    assert_true "cleanup kills the dedicated server" grep -q '^SUB=kill-server' "$TMUX_CALLS"
    assert_file_contains "$WORK/out-two-panes" "Summary" \
        "the progress/state pane still shows the interactive summary"

    # --- Exit status propagation: a failing child exits non-zero ---
    echo ""
    echo "--- Exit status propagation through tmux ---"
    BAD_CONF="$WORK/bad.conf"
    printf 'keep|not-an-absolute-path|invalid keep\n' > "$BAD_CONF"
    : > "$TMUTIL_CALLS"
    : > "$TMUX_CALLS"
    rc=0
    run_pty "$WORK/out-bad" \
        env HOME="$B_HOME" PATH="$STUB_TMUX_DIR:$B_BIN:$PATH" TERM=xterm \
            TM_EXCLUSIONS_DEFAULT_CONF="$BAD_CONF" TMUX_CALLS="$TMUX_CALLS" \
            bash "$TM_EXCLUSIONS" --tmux --dry-run || rc=$?
    assert_eq 1 "$rc" "a failing inner run exits 1 through the tmux wrapper"
    assert_true "the wrapper still cleaned up after the failing run" grep -q '^SUB=kill-server' "$TMUX_CALLS"

    # --- Paths with spaces and special characters are safe (#14) ---
    echo ""
    echo "--- Script path with spaces: %q quoting end to end ---"
    SPACED="$WORK/sp ace d/copy"
    mkdir -p "$SPACED/locales"
    cp "$TM_EXCLUSIONS" "$SPACED/tm_exclusions.sh"
    cp "$ROOT/locales/en.sh" "$ROOT/locales/fr.sh" "$SPACED/locales/"
    : > "$TMUTIL_CALLS"
    : > "$TMUX_CALLS"
    rc=0
    run_pty "$WORK/out-spaced" \
        env HOME="$B_HOME" PATH="$STUB_TMUX_DIR:$B_BIN:$PATH" TERM=xterm \
            TM_EXCLUSIONS_DEFAULT_CONF="$CONF" TMUX_CALLS="$TMUX_CALLS" \
            bash "$SPACED/tm_exclusions.sh" --tmux --dry-run || rc=$?
    assert_eq 0 "$rc" "script in a spaced path: --tmux --dry-run exits 0"
    assert_eq 1 "$(isexcluded_count)" "script in a spaced path: the scan ran exactly once"
    assert_true "script in a spaced path: the wrapper ran the child" grep -q '^SUB=new-session' "$TMUX_CALLS"

    # --- Real tmux (opt-in, isolated socket): two panes and full cleanup ---
    echo ""
    echo "--- Real tmux on a dedicated -L socket (skipped when tmux absent) ---"
    if command -v tmux >/dev/null 2>&1; then
        SOCK_DIR="${TMUX_TMPDIR:-/tmp}/tmux-${UID:-0}"
        count_tm_exc() {
            local n=0 f
            for f in "$SOCK_DIR"/tm-exc-*; do
                [ -e "$f" ] || continue
                n=$((n + 1))
            done
            printf '%s' "$n"
        }
        before="$(count_tm_exc)"
        : > "$TMUTIL_CALLS"
        rc=0
        run_pty "$WORK/out-real-tmux" \
            env HOME="$B_HOME" PATH="$B_BIN:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" TERM=xterm \
                TM_EXCLUSIONS_DEFAULT_CONF="$CONF" \
                bash "$TM_EXCLUSIONS" --tmux --dry-run || rc=$?
        assert_eq 0 "$rc" "real tmux: --tmux --dry-run exits 0"
        assert_eq 1 "$(isexcluded_count)" "real tmux: the scan ran exactly once"
        after="$(count_tm_exc)"
        assert_eq "$before" "$after" "real tmux: no dedicated socket left behind"
    else
        echo "  SKIP real tmux: tmux not installed"
    fi
fi

test_summary
