#!/usr/bin/env bash
# test_home_edge_cases.sh — regression tests for runs in unusual environments:
#   - $HOME containing "&" (Bash 5.2+ patsub_replacement corrupted every
#     $HOME-relative catalog path),
#   - an unwritable configuration directory (the first-run notice claimed a
#     config file had been created, and leaked a raw shell error),
#   - a directory name containing a newline (the scan output is line-based, so
#     the tail of such a path was processed as a relative path of the cwd),
#   - directory names containing tabs in dynamic scan candidates and prune roots.
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
case "$1" in isexcluded) printf '[%s]    %s\n' "${TEST_STATUS:-Included}" "$2" ;; esac
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
assert_file_lacks_regex "$WORK/amp.out" 'R[$]HOME' \
    "no \$HOME token is spliced into a HOME containing '&'"

# ---------------------------------------------------------------------------
# A directory name containing a newline
# ---------------------------------------------------------------------------
# find prints one path per line, so "$HOME/x<NL>b/node_modules" reaches the
# scan as the two lines "$HOME/x" and "b/node_modules". The second one is a
# relative path: it must never be looked up (or excluded) against the cwd.
NL_HOME="$WORK/nl-home"
NL_CWD="$WORK/nl-cwd"
mkdir -p "$NL_HOME/proj/node_modules" "$NL_CWD/b/node_modules"
mkdir -p "$NL_HOME/x
b/node_modules"
(
    cd "$NL_CWD"
    HOME="$NL_HOME" run_tm "$WORK/nl.out" --lang en --dry-run --verbose
    printf '%s' "$TM_RC" > "$WORK/nl.rc"
    cp "$TEST_CALLS" "$WORK/nl.calls"
)
assert_eq "0" "$(cat "$WORK/nl.rc")" "dry-run succeeds with a newline in a directory name"
assert_file_contains "$WORK/nl.out" "Applying exclusion: $NL_HOME/proj/node_modules"     "a regular node_modules is still discovered"
assert_file_lacks_regex "$WORK/nl.out" 'exclusion: b/node_modules'     "the tail of a newline-split path is not processed as a relative path"
assert_file_lacks_regex "$WORK/nl.calls" '^isexcluded b/node_modules'     "tmutil is never asked about a path relative to the cwd"

# A truncated prefix can also point to an unrelated symlink beneath HOME.
# find -type d does not discover the symlink itself.
mkdir -p "$NL_HOME/phantom/node_modules"$'\n'"suffix/node_modules"
ln -s "$NL_HOME/proj/node_modules" "$NL_HOME/phantom/node_modules"
HOME="$NL_HOME" run_tm "$WORK/nl_force.out" --lang en --dry-run
assert_eq "0" "$TM_RC" "dry-run succeeds with a newline in a path"
assert_file_lacks_regex "$TEST_CALLS" '/phantom/node_modules$' \
    "tmutil is never asked about the absolute prefix of a newline-split path"

# ---------------------------------------------------------------------------
# Directory names containing tabs
# ---------------------------------------------------------------------------
TAB_HOME="$WORK/tab-home"
TAB_LITERAL="$TAB_HOME/pattern/cache"$'\t'"store"
TAB_PARENT="$TAB_HOME/proj"$'\t\t'"ect/node_modules"$'\t'
TAB_CHILD="$TAB_PARENT/nested/node_modules"
TAB_NEIGHBOR="$TAB_HOME/proj/node_modules"
TAB_ZONE="$TAB_HOME/zone"$'\t'"protected"
TAB_ZONE_NEIGHBOR="$TAB_HOME/zone/node_modules"
mkdir -p "$TAB_LITERAL" "$TAB_CHILD" "$TAB_NEIGHBOR" "$TAB_ZONE/node_modules" "$TAB_ZONE_NEIGHBOR"
TAB_CONF="$WORK/tab.conf"
printf 'pattern|node_modules*|cache\npattern|cache\tstore|tabbed pattern\nprune|%s|protected zone\n' \
    "$TAB_ZONE" > "$TAB_CONF"
assert_scan_calls() {
    local action="$1" no_scan_prune="$2" path
    shift 2
    for path in "$@"; do
        printf 'isexcluded %s\n%s %s\n' "$path" "$action" "$path"
    done > "$WORK/tab.expected"
    # Ignore report-only metadata calls while checking every path lookup and
    # mutation, including multiplicity and parent/child order.
    grep -E '^(isexcluded|addexclusion|removeexclusion) ' "$TEST_CALLS" > "$WORK/tab.actual" || true
    assert_true "$action (traversal pruning disabled=$no_scan_prune) receives exactly the expected paths" \
        diff -u "$WORK/tab.expected" "$WORK/tab.actual"
}

for no_scan_prune in 0 1; do
    HOME="$TAB_HOME" TM_EXCLUSIONS_DEFAULT_CONF="$TAB_CONF" \
        TM_EXCLUSIONS_NO_SCAN_PRUNE="$no_scan_prune" TM_EXCLUSIONS_REPORT="$WORK/tab.report" \
        run_tm "$WORK/tab.out" --lang en --quiet
    assert_eq "0" "$TM_RC" "apply succeeds with tabs in paths"
    assert_scan_calls addexclusion "$no_scan_prune" \
        "$TAB_LITERAL" "$TAB_PARENT" "$TAB_NEIGHBOR" "$TAB_ZONE_NEIGHBOR"
    if [[ "$no_scan_prune" = 0 ]]; then
        assert_file_contains "$WORK/tab.report" "SKIP  $TAB_ZONE (" \
            "the prune zone is reported with its full path"
    fi

    HOME="$TAB_HOME" TM_EXCLUSIONS_DEFAULT_CONF="$TAB_CONF" \
        TM_EXCLUSIONS_NO_SCAN_PRUNE="$no_scan_prune" TEST_STATUS=Excluded \
        run_tm "$WORK/tab.out" --lang en --quiet --uninstall
    assert_eq "0" "$TM_RC" "uninstall succeeds with tabs in paths"
    assert_scan_calls removeexclusion "$no_scan_prune" \
        "$TAB_LITERAL" "$TAB_PARENT" "$TAB_CHILD" "$TAB_NEIGHBOR" "$TAB_ZONE_NEIGHBOR"
done

# ---------------------------------------------------------------------------
# A configuration directory that cannot be created
# ---------------------------------------------------------------------------
# $HOME/.config is a regular file, so neither the directory nor the default
# custom.conf can be created (also true when the suite runs as root). The first
# run notice must not claim success, and no raw shell error may leak.
RO_HOME="$WORK/ro-home"
mkdir -p "$RO_HOME"
: > "$RO_HOME/.config"
HOME="$RO_HOME" run_tm "$WORK/ro.out" --lang en --list
assert_eq "1" "$TM_RC" "--list fails when the custom config cannot exist"
assert_file_lacks_regex "$WORK/ro.out" 'Created default custom config'     "no false 'created' notice when the config file could not be written"
assert_file_contains "$WORK/ro.out" "Could not create the default custom config"     "the failure is reported in English"
assert_file_lacks_regex "$WORK/ro.out" 'Not a directory|No such file'     "no raw shell error leaks"
HOME="$RO_HOME" run_tm "$WORK/ro_fr.out" --lang fr --list
assert_file_contains "$WORK/ro_fr.out" "Impossible de créer la configuration personnalisée"     "the failure is reported in French"
HOME="$RO_HOME" run_tm "$WORK/ro_init.out" --lang en --init
assert_eq "1" "$TM_RC" "--init exits 1 when the config directory cannot be created"
assert_file_contains "$WORK/ro_init.out" "Could not create the default custom config"     "--init reports the failure instead of a raw mkdir error"
# The scan itself does not need the file: a run still reaches its report.
HOME="$RO_HOME" TM_EXCLUSIONS_REPORT="$WORK/ro_report.txt" \
    run_tm "$WORK/ro_run.out" --lang en --report-only
assert_eq "0" "$TM_RC" "a report-only run does not need a writable config directory"
assert_file_lacks_regex "$WORK/ro_run.out" 'Created default custom config'     "a run without a writable config directory does not claim to have created it"

test_summary
