#!/usr/bin/env bash
# Regression checks: isolated HOME and fake commands, never real Time Machine.
set -euo pipefail
# Resolve the repo root before sourcing: test_helpers.sh reuses SCRIPT_DIR for it.
SAFETY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/test_helpers.sh
source "${SAFETY_DIR}/test_helpers.sh"

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
export HOME="$TEST_DIR/home"
mkdir -p "$HOME/.config/tm_exclusions" "$TEST_DIR/bin"
export TM_EXCLUSIONS_DEFAULT_CONF="$TEST_DIR/default.conf"
export TM_EXCLUSIONS_SKIP_INVENTORY=1 TM_EXCLUSIONS_SKIP_DU=1
export TM_EXCLUSIONS_REPORT="$TEST_DIR/report"
export TEST_CALLS="$TEST_DIR/calls"
export LANG=C LC_ALL=C
unset TM_EXCLUSIONS_EXTRA_CONF TM_EXCLUSIONS_REPORT_DESKTOP TM_EXCLUSIONS_LOCALES_DIR
cat > "$TEST_DIR/bin/tmutil" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$TEST_CALLS"
case "$1" in
    isexcluded)
        case "${TEST_STATUS:-included}" in
            fail) exit 1 ;;
            malformed) echo unknown ;;
            excluded) printf '[Excluded] %s\n' "$2" ;;
            *) printf '[Included] %s\n' "$2" ;;
        esac ;;
    addexclusion|removeexclusion) exit "${TEST_MUTATE_EXIT:-0}" ;;
esac
STUB
cat > "$TEST_DIR/bin/brew" <<'STUB'
#!/bin/sh
[ "$1" != --cache ] || printf '%s\n' "$HOME/brew-cache"
exit 0
STUB
cat > "$TEST_DIR/bin/sudo" <<'STUB'
#!/bin/sh
exit 1
STUB
chmod +x "$TEST_DIR/bin/"*
export PATH="$TEST_DIR/bin:$PATH"

# Uses the shared helpers' run_cli against the CLI under test.
run() {
    run_cli "$1" "$TEST_DIR/out" "${@:2}"
}

mkdir -p "$HOME/project/cache/saved" "$HOME/project/other/cache" "$HOME/brew-cache" \
    "$HOME/disks/private.sparsebundle" "$HOME/disks/public.sparsebundle"
ln -s "$HOME/project/cache" "$HOME/cache-alias"
cat > "$TM_EXCLUSIONS_DEFAULT_CONF" <<'CONF'
path|$HOME/project|broad parent
path|$HOME/cache-alias|alias parent
path|$HOME/project/cache/../cache|dot parent
path|$HOME/project/cache/saved|saved state
pattern|cache|regenerable cache
setting|scan_images|true
CONF
cat > "$HOME/.config/tm_exclusions/custom.conf" <<'CONF'
keep|~/project/cache/saved/|precious state
keep|~/brew-cache|retain brew cache
keep|~/disks/private.sparsebundle|VM data
CONF
run 0
assert_file_contains "$TEST_CALLS" "addexclusion $HOME/project/other/cache" \
    "regenerable cache outside keep is excluded"
assert_file_contains "$TEST_CALLS" "addexclusion $HOME/disks/public.sparsebundle" \
    "opted-in sparsebundle is excluded"
assert_eq 2 "$(grep -c '^addexclusion ' "$TEST_CALLS")" "only two mutations are performed"
assert_file_contains "$TM_EXCLUSIONS_REPORT" 'precious state' "report keeps the rule reason"
assert_file_contains "$TM_EXCLUSIONS_REPORT" 'Summary by rule' "report includes the rule summary"
assert_file_contains "$TM_EXCLUSIONS_REPORT" \
    "$(printf '\t%s:5 | pattern|cache | regenerable cache' "$TM_EXCLUSIONS_DEFAULT_CONF")" \
    "rule summary attributes the dynamic match to its config line"
assert_file_contains "$TM_EXCLUSIONS_REPORT" \
    'tmutil listexclusions (first 500 lines; status: empty)' \
    "report states the listexclusions status"
assert_file_contains "$TM_EXCLUSIONS_REPORT" "KEEP  $HOME/project (protected by keep" \
    "keep blocks the broad parent exclusion"
run 0 --report-only
assert_file_lacks_regex "$TEST_CALLS" '^(addexclusion|removeexclusion) ' \
    "report-only performs no mutation"
assert_file_contains "$TM_EXCLUSIONS_REPORT" "NEED  $HOME/project/other/cache" \
    "report-only still records the needed exclusion"
run 0 --uninstall --force --dry-run
assert_file_lacks_regex "$TEST_CALLS" '^(addexclusion|removeexclusion) ' \
    "forced uninstall dry-run performs no mutation"
assert_file_contains "$TM_EXCLUSIONS_REPORT" "WOULD_REMOVE $HOME/project/other/cache" \
    "forced uninstall dry-run plans the removable path"
assert_true "forced uninstall dry-run leaves kept paths alone" \
    not grep -Fq "WOULD_REMOVE $HOME/project/cache/saved" "$TM_EXCLUSIONS_REPORT"

# Persistent exclusions (including inherited ones) are an error, never silently removed.
export TEST_STATUS=excluded
run 1 --dry-run
assert_file_contains "$TM_EXCLUSIONS_REPORT" 'Protected path is still excluded' \
    "an already-excluded protected path is reported"
assert_file_lacks_regex "$TEST_CALLS" '^(addexclusion|removeexclusion) ' \
    "an already-excluded protected path is not mutated"
unset TEST_STATUS

# Default discovery does not pick up VM images; opting in discloses truncation.
: > "$TM_EXCLUSIONS_DEFAULT_CONF"
: > "$HOME/.config/tm_exclusions/custom.conf"
run 0 --dry-run
assert_true "image discovery stays off by default" \
    not grep -Fq 'sparsebundle' "$TM_EXCLUSIONS_REPORT"
printf '%s\n' 'setting|scan_images|true' > "$TM_EXCLUSIONS_DEFAULT_CONF"
for ((i=0; i<51; i++)); do mkdir "$HOME/disks/$i.sparsebundle"; done
run 0 --dry-run
assert_file_contains "$TM_EXCLUSIONS_REPORT" 'LIMIT Image discovery limited to 50' \
    "candidate overflow is disclosed as LIMIT"
assert_eq 50 "$(grep -c '^WOULD .*sparsebundle' "$TM_EXCLUSIONS_REPORT")" \
    "image discovery is capped at 50 candidates"

# A failed or unrecognized status must not be treated as Included in any mode.
# Literal placeholder is expanded by the CLI.
# shellcheck disable=SC2016
printf '%s\n' 'path|$HOME/project|test reason' > "$TM_EXCLUSIONS_DEFAULT_CONF"
for TEST_STATUS in fail malformed; do
    export TEST_STATUS
    for mode in --dry-run --report-only --uninstall; do
        run 1 "$mode"
        assert_file_contains "$TM_EXCLUSIONS_REPORT" \
            'Unable to determine Time Machine exclusion status:' \
            "unknown status ($TEST_STATUS, $mode) is reported"
        assert_file_lacks_regex "$TEST_CALLS" '^(addexclusion|removeexclusion) ' \
            "unknown status ($TEST_STATUS, $mode) performs no mutation"
        assert_file_lacks_regex "$TM_EXCLUSIONS_REPORT" '^(NEED|WOULD|ADD) ' \
            "unknown status ($TEST_STATUS, $mode) plans no change"
    done
done
export TEST_STATUS=included TEST_MUTATE_EXIT=1
run 1
assert_file_contains "$TM_EXCLUSIONS_REPORT" 'Error excluding:' \
    "a failed add is reported"
export TEST_STATUS=excluded
run 1 --uninstall
assert_file_contains "$TM_EXCLUSIONS_REPORT" 'Error removing exclusion:' \
    "a failed removal is reported"
unset TEST_STATUS TEST_MUTATE_EXIT

# Partial discovery retains its results and records failure in the persisted report.
cat > "$TEST_DIR/bin/find" <<'STUB'
#!/bin/sh
case "$*" in
    *-print0*) printf '%s\000' "$HOME/disks/private.sparsebundle" ;;
    *) printf '%s\n' "$HOME/project/other/cache" ;;
esac
exit 1
STUB
chmod +x "$TEST_DIR/bin/find"
for config in 'pattern|cache|cache reason' 'setting|scan_images|true'; do
    printf '%s\n' "$config" > "$TM_EXCLUSIONS_DEFAULT_CONF"
    run 1 --dry-run
    assert_file_contains "$TM_EXCLUSIONS_REPORT" 'Incomplete scan:' \
        "partial scan failure is reported ($config)"
    assert_file_contains "$TM_EXCLUSIONS_REPORT" 'WOULD ' \
        "partial scan results are still planned ($config)"
done
rm "$TEST_DIR/bin/find"

# Invalid keep input prevents every mutation; CLI --add persists a usable rule.
printf '%s\n' 'path|~/project|test' 'keep|relative/path|invalid' > "$TM_EXCLUSIONS_DEFAULT_CONF"
run 1
assert_file_lacks_regex "$TEST_CALLS" '^(addexclusion|removeexclusion) ' \
    "an invalid keep rule prevents all mutation"
assert_file_contains "$TM_EXCLUSIONS_REPORT" 'Invalid keep rule' \
    "an invalid keep rule is reported"
: > "$TM_EXCLUSIONS_DEFAULT_CONF"
run 0 --add keep "$HOME/project" 'preserve state'
assert_file_contains "$HOME/.config/tm_exclusions/custom.conf" \
    "keep|$HOME/project|preserve state" "--add persists the keep rule"
run 1 --add keep 'relative/path' 'invalid'
run 1 --add keep "$HOME/project" $'bad\npath|/|injection'
run 0 --lang fr --dry-run
assert_file_contains "$TM_EXCLUSIONS_REPORT" 'preserve state' \
    "the added keep rule survives a localized run"

# Literal keeps support root and symlink/dot spellings; nested du entries count once.
# shellcheck disable=SC1090
source <(sed '/^main /d' "$ROOT/tm_exclusions.sh")
# du accounting stores physical spellings, so expectations are normalized too
# (/var is a symlink to /private/var on macOS).
PHYSICAL_PROJECT="$(normalize_path "$HOME/project")"
DU_PATHS=""
du_track_path "$HOME/project/cache/saved"
du_track_path "$HOME/project"
du_track_path "$HOME/project/other/cache"
assert_eq "$PHYSICAL_PROJECT" "$DU_PATHS" "nested du entries collapse into their parent"
DU_PATHS=""
du_track_path "$HOME/project/other/cache"
du_track_path "$HOME/cache-alias/saved"
assert_eq "$(printf '%s\n%s' \
    "$(normalize_path "$HOME/project/other/cache")" \
    "$(normalize_path "$HOME/project/cache/saved")")" "$DU_PATHS" \
    "symlinked and dot spellings dedupe against their physical parent"
DU_PATHS=""
du_track_path "$HOME/project"
du_track_path "$HOME/cache-alias/saved"
assert_eq "$PHYSICAL_PROJECT" "$DU_PATHS" \
    "a physical parent absorbs its symlinked descendants"
CONF_KEEPS="$(normalize_path "$HOME/cache-alias/../cache/saved")"
assert_true "keep blocks its parent" keep_blocks "$HOME/project/cache"
assert_true "keep ignores unrelated siblings" not keep_blocks "$HOME/project/other/cache"
CONF_KEEPS=/
assert_true "root keep blocks everything" keep_blocks "$HOME/project"

# Catalog protects mixed state roots and retains regenerable caches.
# Used by sourced functions.
# shellcheck disable=SC2034
CONF_PATHS="" CONF_PATTERNS="" CONF_RULES="" CONF_KEEPS=""
source "$ROOT/locales/en.sh"
declare_i18n_en
parse_config_file "$ROOT/config/default.conf"
for target in /opt/homebrew "$HOME/.pulumi" "$HOME/Library/Developer/Xcode/Archives" \
    "$HOME/Library/Containers/com.docker.docker" "$HOME/Library/Developer/CoreSimulator/Devices"; do
    assert_true "catalog does not ship $target" \
        not grep -Fxq "$target" <<<"$CONF_PATHS"
done
for pattern in .codex .auto-claude worktrees build dist; do
    assert_true "catalog does not ship the $pattern pattern" \
        not grep -Fxq "$pattern" <<<"$CONF_PATTERNS"
done
assert_true "catalog still ships the node_modules pattern" \
    grep -Fxq node_modules <<<"$CONF_PATTERNS"
printf 'Safety checks passed.\n'
test_summary
