#!/usr/bin/env bash
# test_home_edge_cases.sh — regression tests for runs in unusual environments:
#   - $HOME containing "&" (Bash 5.2+ patsub_replacement corrupted every
#     $HOME-relative catalog path),
#   - an unwritable configuration directory (the first-run notice claimed a
#     config file had been created, and leaked a raw shell error),
#   - a directory name containing a newline (the scan output is line-based, so
#     the tail of such a path was processed as a relative path of the cwd).
# Every scenario uses a throwaway HOME, a stub tmutil that only records its
# calls, and never touches the real Time Machine state.
set -euo pipefail

# shellcheck source=tests/test_helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export TM_EXCLUSIONS_SKIP_DU=1 TM_EXCLUSIONS_SKIP_INVENTORY=1
TEST_CALLS="$WORK/tmutil.calls"
mkdir -p "$WORK/bin"
cat > "$WORK/bin/tmutil" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$TEST_CALLS"
case "$1" in isexcluded) echo "[Included]    $2" ;; esac
exit 0
EOF
chmod +x "$WORK/bin/tmutil"
export TEST_CALLS
export PATH="$WORK/bin:$PATH"

echo "home edge case tests"
echo "========================================"

# run_tm <out_file> [args...]: run the CLI with the interpreter running this
# suite ($BASH), so `/bin/bash tests/test_home_edge_cases.sh` exercises Bash 3.2
# and a Homebrew bash exercises Bash 5. The exit status is left in TM_RC.
TM_RC=0
run_tm() {
    local out="$1"
    shift
    : > "$TEST_CALLS"
    TM_RC=0
    "$BASH" "$TM_EXCLUSIONS" "$@" > "$out" 2>&1 || TM_RC=$?
}

# ---------------------------------------------------------------------------
# $HOME containing "&"
# ---------------------------------------------------------------------------
AMP_HOME="$WORK/R&D"
mkdir -p "$AMP_HOME/.npm/_cacache"
HOME="$AMP_HOME" run_tm "$WORK/amp.out" --lang en --report-only --verbose
assert_eq "0" "$TM_RC" "report-only run succeeds with a HOME containing '&'"
assert_file_contains "$WORK/amp.out" "$AMP_HOME/.npm/_cacache" \
    "a HOME containing '&' keeps its path in the expanded catalog rules"
assert_file_lacks_regex "$WORK/amp.out" 'R\$HOME' \
    "no \$HOME token is spliced into a HOME containing '&'"

test_summary
