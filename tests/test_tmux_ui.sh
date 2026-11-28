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
import os, pty, sys, errno, select, signal, time
argv = sys.argv[1:]
delay = float(os.environ.get("PTY_SIGNAL_AFTER") or 0)
signame = os.environ.get("PTY_SIGNAL") or "TERM"
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
# With PTY_SIGNAL_AFTER=<seconds>, the child receives PTY_SIGNAL once, then the
# drain continues: used to prove a signal reaches the CLI's cleanup.
sent = False
start = time.time()
while True:
    if delay and not sent and time.time() - start >= delay:
        try:
            os.kill(pid, getattr(signal, "SIG" + signame))
        except OSError:
            pass
        sent = True
    if delay and not sent:
        ready, _, _ = select.select([fd], [], [], 0.05)
        if not ready:
            continue
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

# Stub tmux: parses "-S <socket> <subcommand> ..." and records the subcommand,
# its arguments and the pane environment it would have received. It emulates the
# left pane (runs the re-exec wrapper), the right pane (nothing to read) and
# attach-session (blocks until the wrapper writes the exit-status file). On
# TMUX_FAIL_NEW_SESSION=1 it fails new-session like an unavailable tmux; on
# TMUX_FAIL_SPLIT=1 it fails the log pane after the run has started.
STUB_TMUX_DIR="$WORK/tmux-stub"
mkdir -p "$STUB_TMUX_DIR"
cat > "$STUB_TMUX_DIR/tmux" <<'STUB'
#!/bin/sh
if [ "$1" = -L ] || [ "$1" = -S ]; then shift 2; fi
sub="$1"
printf 'SUB=%s ARGS=%s LOG=%s DEBUG_LOG=%s SOCK=%s\n' \
    "$sub" "$*" "${TM_EXCLUSIONS_TMUX_LOG:-}" "${TM_EXCLUSIONS_DEBUG_FIFO:-}" "${TM_EXCLUSIONS_TMUX_SOCK:-}" >> "$TMUX_CALLS"
if [ "${TMUX_FAIL_NEW_SESSION:-0}" = 1 ] && [ "$sub" = new-session ]; then exit 1; fi
if [ "${TMUX_FAIL_SPLIT:-0}" = 1 ] && [ "$sub" = split-window ]; then exit 1; fi
case "$sub" in
    display-message)
        # Left-pane supervisor: alive (default) or dead with a status.
        case "$*" in
            *pane_dead_status*) printf '%s\n' "${TMUX_PANE_STATUS:-}" ;;
            *) if [ -n "${TMUX_PANE_DIES:-}" ]; then printf '1\n'; else printf '0\n'; fi ;;
        esac
        exit 0
        ;;
    set-option) exit 0 ;;
esac
case "$sub" in
    new-session)
        if [ -n "${TMUX_KEEP_WRAPPER:-}" ]; then cp "$TM_EXCLUSIONS_TMUX_WRAPPER" "$TMUX_KEEP_WRAPPER" 2>/dev/null; fi
        # stdin from /dev/null so the wrapper's "press Enter" read never blocks
        # this stub (the real tmux pane provides a TTY instead).
        "${TM_EXCLUSIONS_TMUX_WRAPPER}" < /dev/null &
        ;;
    attach-session)
        if [ -n "${TMUX_SLOW_ATTACH:-}" ]; then sleep "$TMUX_SLOW_ATTACH"; exit 0; fi
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

# Exported so the stub tmux (spawned by tmux_launch) always finds the log path,
# even in the help/redirect/--quiet scenarios that pass no explicit TMUX_CALLS.
export TMUX_CALLS="$WORK/tmux.calls"

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
            TM_EXCLUSIONS_TMUX_BIN="/nonexistent/tmux" \
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

    # --- after the tmux cleanup, the fallback run keeps its stderr ---
    # tmux_cleanup must not leave the shell's stderr (or any inherited fd)
    # redirected: the fallback scan that follows still reports its own errors.
    echo ""
    echo "--- fallback after cleanup keeps stderr ---"
    : > "$TMUTIL_CALLS"
    : > "$TMUX_CALLS"
    # The report warning is emitted after tmux_cleanup ran (fallback path): if
    # cleanup left the shell's stderr redirected, it would silently disappear.
    printf 'path|%s/cache|x\nsetting|report_path|/nonexistent-dir-xyz/r.txt\n' "$B_HOME" \
        > "$WORK/unwritable-report.conf"
    rc=0
    run_pty "$WORK/out-fail-err" \
        env HOME="$B_HOME" PATH="$STUB_TMUX_DIR:$B_BIN:$PATH" TERM=xterm \
            TM_EXCLUSIONS_DEFAULT_CONF="$WORK/unwritable-report.conf" TMUX_CALLS="$TMUX_CALLS" \
            TMUX_FAIL_NEW_SESSION=1 \
            bash "$TM_EXCLUSIONS" --tmux --dry-run || rc=$?
    assert_file_contains "$WORK/out-fail-err" "Could not save report to" \
        "fallback after cleanup: stderr still works after tmux_cleanup"

    # --- log pane failure after the run started: no fallback, no second scan ---
    echo ""
    echo "--- log pane failure: single pane, no fallback ---"
    : > "$TMUTIL_CALLS"
    : > "$TMUX_CALLS"
    rc=0
    run_pty "$WORK/out-split-fail" \
        env HOME="$B_HOME" PATH="$STUB_TMUX_DIR:$B_BIN:$PATH" TERM=xterm \
            TM_EXCLUSIONS_DEFAULT_CONF="$CONF" TMUX_CALLS="$TMUX_CALLS" TMUX_FAIL_SPLIT=1 \
            bash "$TM_EXCLUSIONS" --tmux --dry-run || rc=$?
    assert_eq 0 "$rc" "log pane failure: the run still exits 0"
    assert_file_contains "$WORK/out-split-fail" "single tmux pane" \
        "log pane failure: the missing pane is reported"
    assert_eq 1 "$(isexcluded_count)" "log pane failure: the scan ran exactly once (no second scan)"
    assert_true "log pane failure: the client was still attached to the running session" \
        grep -q '^SUB=attach-session' "$TMUX_CALLS"

    # --- the left pane dies before it reports (signal before its traps) ---
    # The session must be closed by the supervisor and its exit status
    # published, instead of the parent waiting on the surviving log pane.
    echo ""
    echo "--- left pane dies without reporting ---"
    : > "$TMUTIL_CALLS"
    : > "$TMUX_CALLS"
    rc=0
    run_pty "$WORK/out-pane-dead" \
        env HOME="$B_HOME" PATH="$STUB_TMUX_DIR:$B_BIN:$PATH" TERM=xterm \
            TM_EXCLUSIONS_DEFAULT_CONF="$CONF" TMUX_CALLS="$TMUX_CALLS" \
            TMUX_PANE_DIES=1 TMUX_PANE_STATUS=130 \
            bash "$TM_EXCLUSIONS" --tmux --dry-run || rc=$?
    assert_eq 130 "$rc" "left pane died: the published pane status is returned"
    assert_true "left pane died: the session is closed by the supervisor" \
        grep -q '^SUB=kill-session' "$TMUX_CALLS"

    # --- no log pane at all with a run larger than any pipe buffer ---
    # The log target is a regular file, so neither a missing pane nor a closed
    # one can block the inner run; the PTY watchdog turns a regression (a FIFO
    # without a reader) into exit 143 instead of a dead test.
    echo ""
    echo "--- no log pane: a large run never blocks ---"
    BIG_CONF="$WORK/big.conf"
    : > "$BIG_CONF"
    bi=0
    while [ "$bi" -lt 400 ]; do
        printf 'path|%s/home/missing%d|many log lines for the FIFO\n' "$B_HOME" "$bi" >> "$BIG_CONF"
        bi=$((bi + 1))
    done
    : > "$TMUTIL_CALLS"
    : > "$TMUX_CALLS"
    rc=0
    export PTY_SIGNAL_AFTER=25 PTY_SIGNAL=TERM
    run_pty "$WORK/out-big-fail" \
        env HOME="$B_HOME" PATH="$STUB_TMUX_DIR:$B_BIN:$PATH" TERM=xterm \
            TM_EXCLUSIONS_DEFAULT_CONF="$BIG_CONF" TMUX_CALLS="$TMUX_CALLS" TMUX_FAIL_SPLIT=1 \
            bash "$TM_EXCLUSIONS" --tmux --dry-run --verbose || rc=$?
    unset PTY_SIGNAL_AFTER PTY_SIGNAL
    assert_eq 0 "$rc" "no log pane: a verbose run of 400 paths still finishes"

    # --- TMPDIR too long for the platform socket path: normal single-pane run ---
    echo ""
    echo "--- TMPDIR too long for a unix socket: normal run ---"
    # 104 ASCII characters: over the limit even when $WORK is short (/tmp on Linux).
    LONG_TMP="$WORK/$(i=0; while [ "$i" -lt 104 ]; do printf 'd'; i=$((i + 1)); done)"
    mkdir -p "$LONG_TMP"
    : > "$TMUTIL_CALLS"
    : > "$TMUX_CALLS"
    rc=0
    run_pty "$WORK/out-long-tmp" \
        env HOME="$B_HOME" PATH="$STUB_TMUX_DIR:$B_BIN:$PATH" TERM=xterm TMPDIR="$LONG_TMP" \
            TM_EXCLUSIONS_DEFAULT_CONF="$CONF" TMUX_CALLS="$TMUX_CALLS" \
            bash "$TM_EXCLUSIONS" --tmux --dry-run || rc=$?
    assert_eq 0 "$rc" "long TMPDIR: the run still exits 0"
    assert_true "long TMPDIR: no tmux interface is attempted" test ! -s "$TMUX_CALLS"
    assert_eq 1 "$(isexcluded_count)" "long TMPDIR: the scan ran exactly once"

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
    assert_true "right pane: split-window follows the debug log" grep -q '^SUB=split-window' "$TMUX_CALLS"
    # shellcheck disable=SC2016  # the \$ is a literal dollar in the recorded pane command
    assert_true "the two destinations differ: left runs the wrapper, right follows the log" \
        grep -q 'SUB=new-session ARGS=.*exec "\$TM_EXCLUSIONS_TMUX_WRAPPER"' "$TMUX_CALLS"
    # shellcheck disable=SC2016  # the \$ is a literal dollar in the recorded pane command
    assert_true "the right pane follows the run's debug log" \
        grep -q 'SUB=split-window ARGS=.*tail -n +1 -f' "$TMUX_CALLS"
    # shellcheck disable=SC2016  # the \$ is a literal dollar in the recorded pane command
    assert_true "the log pane follows the file the inner run appends to" \
        grep -q 'SUB=split-window ARGS=.*"\$TM_EXCLUSIONS_TMUX_LOG"' "$TMUX_CALLS"
    assert_true "the log pane never takes the keyboard (split-window -d)" \
        grep -q 'SUB=split-window ARGS=.*-d.*' "$TMUX_CALLS"
    assert_true "the dedicated server uses a private socket path (-S inside the work dir)" \
        grep -q 'SOCK=/.*tm_exc_work\.[A-Za-z0-9]*/s' "$TMUX_CALLS"
    assert_true "the child writes its log lines to the run's log file" \
        grep -q 'DEBUG_LOG=/.*debug\.log' "$TMUX_CALLS"
    assert_eq 1 "$(isexcluded_count)" "interactive two panes: the scan ran exactly once (no double scan)"
    assert_eq 0 "$(grep -c '^addexclusion$' "$TMUTIL_CALLS" || true)" \
        "interactive two panes: --dry-run preserved (no mutation)"
    assert_true "cleanup kills the session" grep -q '^SUB=kill-session' "$TMUX_CALLS"
    assert_true "cleanup kills the dedicated server" grep -q '^SUB=kill-server' "$TMUX_CALLS"
    assert_file_contains "$WORK/out-two-panes" "Summary" \
        "the progress/state pane still shows the interactive summary"

    # --- the wrapper writes its status once, at session close ---
    echo ""
    echo "--- Wrapper: a single status write ---"
    : > "$TMUX_CALLS"
    rm -f "$WORK/wrapper.copy"
    rc=0
    run_pty "$WORK/out-wrapper" \
        env HOME="$B_HOME" PATH="$STUB_TMUX_DIR:$B_BIN:$PATH" TERM=xterm \
            TM_EXCLUSIONS_DEFAULT_CONF="$CONF" TMUX_CALLS="$TMUX_CALLS" \
            TMUX_KEEP_WRAPPER="$WORK/wrapper.copy" \
            bash "$TM_EXCLUSIONS" --tmux --dry-run || rc=$?
    assert_eq 0 "$rc" "wrapper: the run still exits 0"
    assert_true "wrapper: the generated script was captured" test -s "$WORK/wrapper.copy"
    # shellcheck disable=SC2016  # the \$ is a literal dollar in the generated wrapper
    assert_eq 1 "$(grep -c '> "$TM_EXCLUSIONS_TMUX_RC.tmp"' "$WORK/wrapper.copy" || true)" \
        "wrapper: the status is written exactly once, through a temporary file"
    # No pipe into grep -q: pipefail turns its early exit into a SIGPIPE error.
    awk '/^finish\(\) \{$/ { getline; print; exit }' "$WORK/wrapper.copy" > "$WORK/finish-first.txt"
    assert_file_contains "$WORK/finish-first.txt" 'trap "" INT TERM HUP' \
        "wrapper: signals are ignored before anything else in finish"
    # shellcheck disable=SC2016  # the \$ is a literal dollar in the generated wrapper
    assert_true "wrapper: an already published status is never replaced" \
        grep -q '\[ -s "\$TM_EXCLUSIONS_TMUX_RC" \] && return 0' "$WORK/wrapper.copy"

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

    # --- SIGTERM while attached: cleanup runs, nothing is left behind ---
    echo ""
    echo "--- SIGTERM while attached: cleanup ---"
    # Short TMPDIR: the private tmux socket path must stay under macOS's
    # 104-byte unix-socket limit, or the interface falls back by design.
    TERM_TMP="$WORK/t"
    mkdir -p "$TERM_TMP"
    : > "$TMUTIL_CALLS"
    : > "$TMUX_CALLS"
    rc=0
    export PTY_SIGNAL_AFTER=1 PTY_SIGNAL=TERM
    run_pty "$WORK/out-term" \
        env HOME="$B_HOME" PATH="$STUB_TMUX_DIR:$B_BIN:$PATH" TERM=xterm TMPDIR="$TERM_TMP" \
            TM_EXCLUSIONS_DEFAULT_CONF="$CONF" TMUX_CALLS="$TMUX_CALLS" TMUX_SLOW_ATTACH=30 \
            bash "$TM_EXCLUSIONS" --tmux --dry-run || rc=$?
    unset PTY_SIGNAL_AFTER PTY_SIGNAL
    assert_eq 143 "$rc" "SIGTERM while attached: the CLI exits 143 instead of waiting for the client"
    assert_eq 0 "$(find "$TERM_TMP" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')" \
        "SIGTERM while attached: the private work directory is gone"
    assert_true "SIGTERM while attached: the attached client was stopped" \
        grep -q '^SUB=attach-session' "$TMUX_CALLS"
    assert_true "SIGTERM while attached: the dedicated server was killed" \
        grep -q '^SUB=kill-server' "$TMUX_CALLS"

    # --- Real tmux: Ctrl-C in the left pane closes the session (no hang) ---
    echo ""
    echo "--- Real tmux: Ctrl-C in the left pane ---"
    if command -v tmux >/dev/null 2>&1; then
        CT_TMP="$WORK/c"
        mkdir -p "$CT_TMP"
        # A slow tmutil keeps the scan running while the interrupt is sent, so
        # the test always exercises the mid-scan path (a finished run keeps its
        # own status, which is a different, also valid outcome).
        CT_BIN="$WORK/ctbin"
        mkdir -p "$CT_BIN"
        cp "$B_BIN/tmutil" "$B_BIN/sudo" "$B_BIN/brew" "$CT_BIN/"
        cat > "$CT_BIN/tmutil" <<'CTSTUB'
#!/bin/sh
sleep 5
printf '[Included] %s\n' "$2"
exit 0
CTSTUB
        chmod +x "$CT_BIN/tmutil"
        : > "$TMUTIL_CALLS"
        run_pty "$WORK/out-ctrlc" \
            env HOME="$B_HOME" PATH="$CT_BIN:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" TERM=xterm \
                TMPDIR="$CT_TMP" TM_EXCLUSIONS_DEFAULT_CONF="$CONF" \
                bash "$TM_EXCLUSIONS" --tmux --dry-run &
        ct_runner=$!
        ct_sock=""
        ct_i=0
        while [ "$ct_i" -lt 100 ] && [ -z "$ct_sock" ]; do
            ct_sock="$(find "$CT_TMP" -maxdepth 2 -type s -name s 2>/dev/null | head -1)"
            [ -n "$ct_sock" ] || sleep 0.1 2>/dev/null || sleep 1
            ct_i=$((ct_i + 1))
        done
        assert_true "real tmux Ctrl-C: the private socket appears" test -n "$ct_sock"
        sleep 1
        # Left pane = the first pane of the window (the wrapper); address it by
        # its pane id, since the window index is not guaranteed.
        ct_pane="$(tmux -S "$ct_sock" list-panes -F '#{pane_id}' 2>/dev/null | head -1)"
        assert_true "real tmux Ctrl-C: the left pane exists" test -n "$ct_pane"
        tmux -S "$ct_sock" send-keys -t "$ct_pane" C-c 2>/dev/null || true
        ct_waited=0
        while kill -0 "$ct_runner" 2>/dev/null && [ "$ct_waited" -lt 100 ]; do
            sleep 0.2 2>/dev/null || sleep 1
            ct_waited=$((ct_waited + 1))
        done
        ct_hang=0
        if kill -0 "$ct_runner" 2>/dev/null; then
            ct_hang=1
            kill -TERM "$ct_runner" 2>/dev/null || true
        fi
        rc=0
        wait "$ct_runner" 2>/dev/null || rc=$?
        assert_eq 0 "$ct_hang" "real tmux Ctrl-C: the CLI does not hang on a closed pane status"
        assert_eq 130 "$rc" "real tmux Ctrl-C: the run exits 130"
        assert_eq 0 "$(find "$CT_TMP" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')" \
            "real tmux Ctrl-C: no socket or work directory left behind"
    else
        echo "  SKIP real tmux Ctrl-C: tmux not installed"
    fi

    # --- Real tmux: a detach at the closing prompt returns the scan status ---
    echo ""
    echo "--- Real tmux: detach at the closing prompt ---"
    if command -v tmux >/dev/null 2>&1; then
        DT_TMP="$WORK/d"
        mkdir -p "$DT_TMP"
        : > "$TMUTIL_CALLS"
        run_pty "$WORK/out-detach" \
            env HOME="$B_HOME" PATH="$B_BIN:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" TERM=xterm \
                TMPDIR="$DT_TMP" TM_EXCLUSIONS_DEFAULT_CONF="$CONF" \
                bash "$TM_EXCLUSIONS" --tmux --dry-run &
        dt_runner=$!
        dt_sock=""
        dt_i=0
        while [ "$dt_i" -lt 100 ] && [ -z "$dt_sock" ]; do
            dt_sock="$(find "$DT_TMP" -maxdepth 2 -type s -name s 2>/dev/null | head -1)"
            [ -n "$dt_sock" ] || sleep 0.1 2>/dev/null || sleep 1
            dt_i=$((dt_i + 1))
        done
        assert_true "real tmux detach: the private socket appears" test -n "$dt_sock"
        dt_pane="$(tmux -S "$dt_sock" list-panes -F '#{pane_id}' 2>/dev/null | head -1)"
        # Wait for the closing prompt: the status is published there, so a
        # detach must return it instead of making the parent re-attach.
        dt_i=0
        : > "$WORK/pane.txt"
        while [ "$dt_i" -lt 150 ]; do
            tmux -S "$dt_sock" capture-pane -p -t "$dt_pane" > "$WORK/pane.txt" 2>/dev/null || true
            grep -q "press Enter" "$WORK/pane.txt" 2>/dev/null && break
            sleep 0.2 2>/dev/null || sleep 1
            dt_i=$((dt_i + 1))
        done
        assert_true "real tmux detach: the closing prompt is shown" \
            grep -q "press Enter" "$WORK/pane.txt"
        tmux -S "$dt_sock" detach-client -s tm-exclusions 2>/dev/null || true
        dt_waited=0
        while kill -0 "$dt_runner" 2>/dev/null && [ "$dt_waited" -lt 100 ]; do
            sleep 0.2 2>/dev/null || sleep 1
            dt_waited=$((dt_waited + 1))
        done
        dt_hang=0
        if kill -0 "$dt_runner" 2>/dev/null; then
            dt_hang=1
            kill -TERM "$dt_runner" 2>/dev/null || true
        fi
        rc=0
        wait "$dt_runner" 2>/dev/null || rc=$?
        assert_eq 0 "$dt_hang" "real tmux detach: the CLI does not wait for a second client"
        assert_eq 0 "$rc" "real tmux detach: the published scan status is returned"
        assert_eq 0 "$(find "$DT_TMP" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')" \
            "real tmux detach: no socket or work directory left behind"
    else
        echo "  SKIP real tmux detach: tmux not installed"
    fi

    # --- Real tmux (opt-in, isolated socket): two panes and full cleanup ---
    echo ""
    echo "--- Real tmux on a dedicated socket (skipped when tmux absent) ---"
    if command -v tmux >/dev/null 2>&1; then
        REAL_TMP="$WORK/r"
        mkdir -p "$REAL_TMP"
        : > "$TMUTIL_CALLS"
        rc=0
        run_pty "$WORK/out-real-tmux" \
            env HOME="$B_HOME" PATH="$B_BIN:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" TERM=xterm \
                TMPDIR="$REAL_TMP" TM_EXCLUSIONS_DEFAULT_CONF="$CONF" TM_EXCLUSIONS_TMUX_NO_HOLD=1 \
                bash "$TM_EXCLUSIONS" --tmux --dry-run || rc=$?
        assert_eq 0 "$rc" "real tmux: --tmux --dry-run exits 0"
        assert_eq 1 "$(isexcluded_count)" "real tmux: the scan ran exactly once"
        assert_eq 0 "$(find "$REAL_TMP" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')" \
            "real tmux: no socket or work directory left behind"
    else
        echo "  SKIP real tmux: tmux not installed"
    fi
fi

test_summary
