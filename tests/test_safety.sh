#!/usr/bin/env bash
# Regression checks: isolated HOME and fake commands, never real Time Machine.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
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
run() {
    local expected="$1" actual=0
    shift
    : > "$TEST_CALLS"
    bash "$ROOT/tm_exclusions.sh" "$@" > "$TEST_DIR/out" 2>&1 || actual=$?
    if [[ "$actual" -ne "$expected" ]]; then
        cat "$TEST_DIR/out"
        printf 'Expected exit %s, got %s\n' "$expected" "$actual" >&2
        exit 1
    fi
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
grep -Fq "addexclusion $HOME/project/other/cache" "$TEST_CALLS"
grep -Fq "addexclusion $HOME/disks/public.sparsebundle" "$TEST_CALLS"
[[ "$(grep -c '^addexclusion ' "$TEST_CALLS")" -eq 2 ]]
grep -Fq 'precious state' "$TM_EXCLUSIONS_REPORT"
grep -Fq 'Summary by rule' "$TM_EXCLUSIONS_REPORT"
grep -Fq $'\t'"$TM_EXCLUSIONS_DEFAULT_CONF:5 | pattern|cache | regenerable cache" "$TM_EXCLUSIONS_REPORT"
grep -Fq 'tmutil listexclusions (first 500 lines; status: empty)' "$TM_EXCLUSIONS_REPORT"
grep -Fq "$TM_EXCLUSIONS_DEFAULT_CONF:5 | pattern|cache | regenerable cache" "$TM_EXCLUSIONS_REPORT"
grep -Fq "KEEP  $HOME/project (protected by keep" "$TM_EXCLUSIONS_REPORT"
run 0 --report-only
if grep -Eq '^(addexclusion|removeexclusion) ' "$TEST_CALLS"; then exit 1; fi
grep -Fq "NEED  $HOME/project/other/cache" "$TM_EXCLUSIONS_REPORT"
run 0 --uninstall --force --dry-run
if grep -Eq '^(addexclusion|removeexclusion) ' "$TEST_CALLS"; then exit 1; fi
grep -Fq "WOULD_REMOVE $HOME/project/other/cache" "$TM_EXCLUSIONS_REPORT"
if grep -Fq "WOULD_REMOVE $HOME/project/cache/saved" "$TM_EXCLUSIONS_REPORT"; then exit 1; fi

# Persistent exclusions (including inherited ones) are an error, never silently removed.
export TEST_STATUS=excluded
run 1 --dry-run
grep -Fq 'Protected path is still excluded' "$TM_EXCLUSIONS_REPORT"
if grep -Eq '^(addexclusion|removeexclusion) ' "$TEST_CALLS"; then exit 1; fi
unset TEST_STATUS

# Default discovery does not pick up VM images; opting in discloses truncation.
: > "$TM_EXCLUSIONS_DEFAULT_CONF"
: > "$HOME/.config/tm_exclusions/custom.conf"
run 0 --dry-run
if grep -Fq 'sparsebundle' "$TM_EXCLUSIONS_REPORT"; then exit 1; fi
printf '%s\n' 'setting|scan_images|true' > "$TM_EXCLUSIONS_DEFAULT_CONF"
for ((i=0; i<51; i++)); do mkdir "$HOME/disks/$i.sparsebundle"; done
run 0 --dry-run
grep -Fq 'LIMIT Image discovery limited to 50' "$TM_EXCLUSIONS_REPORT"
[[ "$(grep -c '^WOULD .*sparsebundle' "$TM_EXCLUSIONS_REPORT")" -eq 50 ]]

# A failed or unrecognized status must not be treated as Included in any mode.
# Literal placeholder is expanded by the CLI.
# shellcheck disable=SC2016
printf '%s\n' 'path|$HOME/project|test reason' > "$TM_EXCLUSIONS_DEFAULT_CONF"
for TEST_STATUS in fail malformed; do
    export TEST_STATUS
    for mode in --dry-run --report-only --uninstall; do
        run 1 "$mode"
        grep -Fq 'Unable to determine Time Machine exclusion status:' "$TM_EXCLUSIONS_REPORT"
        if grep -Eq '^(addexclusion|removeexclusion) ' "$TEST_CALLS"; then exit 1; fi
        if grep -Eq '^(NEED|WOULD|ADD) ' "$TM_EXCLUSIONS_REPORT"; then exit 1; fi
    done
done
export TEST_STATUS=included TEST_MUTATE_EXIT=1
run 1
grep -Fq 'Error excluding:' "$TM_EXCLUSIONS_REPORT"
export TEST_STATUS=excluded
run 1 --uninstall
grep -Fq 'Error removing exclusion:' "$TM_EXCLUSIONS_REPORT"
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
    grep -Fq 'Incomplete scan:' "$TM_EXCLUSIONS_REPORT"
    grep -q '^WOULD ' "$TM_EXCLUSIONS_REPORT"
done
rm "$TEST_DIR/bin/find"

# Invalid keep input prevents every mutation; CLI --add persists a usable rule.
printf '%s\n' 'path|~/project|test' 'keep|relative/path|invalid' > "$TM_EXCLUSIONS_DEFAULT_CONF"
run 1
if grep -Eq '^(addexclusion|removeexclusion) ' "$TEST_CALLS"; then exit 1; fi
grep -Fq 'Invalid keep rule' "$TM_EXCLUSIONS_REPORT"
: > "$TM_EXCLUSIONS_DEFAULT_CONF"
run 0 --add keep "$HOME/project" 'preserve state'
grep -Fq "keep|$HOME/project|preserve state" "$HOME/.config/tm_exclusions/custom.conf"
run 1 --add keep 'relative/path' 'invalid'
run 1 --add keep "$HOME/project" $'bad\npath|/|injection'
run 0 --lang fr --dry-run
grep -Fq 'preserve state' "$TM_EXCLUSIONS_REPORT"

# Literal keeps support root and symlink/dot spellings; nested du entries count once.
# shellcheck disable=SC1090
source <(sed '/^main /d' "$ROOT/tm_exclusions.sh")
DU_PATHS=""
du_track_path "$HOME/project/cache/saved"
du_track_path "$HOME/project"
du_track_path "$HOME/project/other/cache"
[[ "$DU_PATHS" = "$HOME/project" ]]
CONF_KEEPS="$(normalize_path "$HOME/cache-alias/../cache/saved")"
keep_blocks "$HOME/project/cache"
if keep_blocks "$HOME/project/other/cache"; then exit 1; fi
CONF_KEEPS=/
keep_blocks "$HOME/project"

# Catalog protects mixed state roots and retains regenerable caches.
# Used by sourced functions.
# shellcheck disable=SC2034
CONF_PATHS="" CONF_PATTERNS="" CONF_RULES="" CONF_KEEPS=""
source "$ROOT/locales/en.sh"
declare_i18n_en
parse_config_file "$ROOT/config/default.conf"
for target in /opt/homebrew "$HOME/.pulumi" "$HOME/Library/Developer/Xcode/Archives" \
    "$HOME/Library/Containers/com.docker.docker" "$HOME/Library/Developer/CoreSimulator/Devices"; do
    if printf '%s\n' "$CONF_PATHS" | grep -Fxq "$target"; then exit 1; fi
done
for pattern in .codex .auto-claude worktrees build dist; do
    if printf '%s\n' "$CONF_PATTERNS" | grep -Fxq "$pattern"; then exit 1; fi
done
printf '%s\n' "$CONF_PATTERNS" | grep -Fxq node_modules
printf 'Safety checks passed.\n'
