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
        [ -n "${TEST_EXCLUDED_PATH:-}" ] && [ "$2" = "$TEST_EXCLUDED_PATH" ] && {
            printf '[Excluded] %s\n' "$2"; exit 0; }
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

# Hypervisor bundles are candidates whole (contents pruned, no size gate); flat
# images are size-gated; a .vbox file is excluded alone unless it sits in a folder
# named after it (<name>/<name>.vbox), which then stands for the VM; cloud trees stay pruned.
rm -rf "$HOME/disks"
mkdir -p "$HOME/vms/a.utm/Data" "$HOME/vms/b.vmwarevm" "$HOME/vms/c.parallels" "$HOME/vms/d.pvm" \
    "$HOME/vms/a.utm/nested.vmwarevm" "$HOME/VirtualBox VMs/box" "$HOME/Documents/Documents.vbox" \
    "$HOME/Library/CloudStorage/Drive/e.utm" \
    "$HOME/Library/Mobile Documents/f.vmwarevm"
for big in "$HOME/vms/big.iso" "$HOME/vms/big.ova" "$HOME/Library/CloudStorage/Drive/big.iso"; do
    dd if=/dev/zero of="$big" bs=1 count=0 seek=537919488 2>/dev/null
done
: > "$HOME/vms/small.iso"
: > "$HOME/vms/small.ova"
: > "$HOME/VirtualBox VMs/box/box.vbox"
: > "$HOME/stray.vbox"
: > "$HOME/Documents/loose.vbox"
run 0 --dry-run
for found in vms/a.utm vms/b.vmwarevm vms/c.parallels vms/d.pvm vms/big.iso vms/big.ova \
    "VirtualBox VMs/box" Documents/loose.vbox stray.vbox; do
    assert_file_contains "$TM_EXCLUSIONS_REPORT" "WOULD $HOME/$found " \
        "VM discovery reports $found"
done
for missing in small.iso small.ova nested.vmwarevm CloudStorage 'Mobile Documents' \
    'box/box.vbox'; do
    assert_file_lacks_regex "$TM_EXCLUSIONS_REPORT" "^WOULD .*$missing" \
        "VM discovery skips $missing"
done
assert_eq 9 "$(grep '^WOULD ' "$TM_EXCLUSIONS_REPORT" | grep -vc 'brew-cache')" \
    "VM discovery plans exactly the expected paths"
assert_true "a loose .vbox does not exclude its whole folder" \
    not grep -Fq "WOULD $HOME/Documents " "$TM_EXCLUSIONS_REPORT"
assert_true "a directory named like its parent plus .vbox is not a candidate" \
    not grep -Fq "WOULD $HOME/Documents/Documents.vbox " "$TM_EXCLUSIONS_REPORT"
rm -rf "$HOME/vms" "$HOME/VirtualBox VMs" "$HOME/stray.vbox" "$HOME/Library" "$HOME/Documents"

# A folder named after its .vbox is never $HOME, with or without a trailing slash.
HOME_PLAIN="$HOME"
: > "$HOME/home.vbox"
for HOME in "$HOME_PLAIN" "$HOME_PLAIN/"; do
    export HOME
    run 0 --dry-run
    assert_file_contains "$TM_EXCLUSIONS_REPORT" "home.vbox " \
        "a .vbox named like HOME is excluded as a file (HOME=$HOME)"
    assert_true "HOME is never proposed (HOME=$HOME)" \
        not grep -Eq "^WOULD ${HOME_PLAIN}/* " "$TM_EXCLUSIONS_REPORT"
done
HOME="$HOME_PLAIN"
export HOME
rm -f "$HOME/home.vbox"

# Exact duplicates and covered descendants never use up the 50 slots; real overflow still does.
make_vms() {
    local n i
    for ((i = 0; i < $1; i++)); do
        n="$HOME/many/vm$i"
        mkdir -p "$n"
        : > "$n/vm$i.vbox"
        dd if=/dev/zero of="$n/disk.vmdk" bs=1 count=0 seek=537919488 2>/dev/null
    done
}
make_vms 26
run 0 --dry-run
assert_eq 26 "$(grep -c '^WOULD .*many/vm[0-9]* ' "$TM_EXCLUSIONS_REPORT")" \
    "26 VM folders (vbox + large vmdk) are all planned once"
assert_true "26 VM folders do not trigger LIMIT" \
    not grep -Fq 'LIMIT' "$TM_EXCLUSIONS_REPORT"
make_vms 51
run 0 --dry-run
assert_file_contains "$TM_EXCLUSIONS_REPORT" 'LIMIT Image discovery limited to 50' \
    "51 distinct VM folders still disclose LIMIT"
assert_eq 50 "$(grep -c '^WOULD .*many/vm[0-9]* ' "$TM_EXCLUSIONS_REPORT")" \
    "51 distinct VM folders are capped at 50"
rm -rf "$HOME/many"

# A keep inside a VM folder protects the folder, so its descendants stay candidates;
# without keep they are covered by the folder. Sorted order must not hide descendants
# behind look-alike siblings (v, v-b, v.x) across ~200 raw candidates.
mkdir -p "$HOME/VMs/Box/saved" "$HOME/VMs/Free"
for name in Box Free; do
    : > "$HOME/VMs/$name/$name.vbox"
    dd if=/dev/zero of="$HOME/VMs/$name/disk.vmdk" bs=1 count=0 seek=537919488 2>/dev/null
done
printf '%s\n' 'keep|~/VMs/Box/saved|precious state' > "$HOME/.config/tm_exclusions/custom.conf"
run 0 --dry-run
assert_file_contains "$TM_EXCLUSIONS_REPORT" "KEEP  $HOME/VMs/Box (" \
    "a keep inside a VM folder protects the folder"
assert_file_contains "$TM_EXCLUSIONS_REPORT" "WOULD $HOME/VMs/Box/disk.vmdk " \
    "the disk of a protected VM folder stays a candidate"
assert_file_contains "$TM_EXCLUSIONS_REPORT" "WOULD $HOME/VMs/Free " \
    "an unprotected VM folder is excluded as a whole"
assert_true "an unprotected VM folder covers its disk" \
    not grep -Fq "WOULD $HOME/VMs/Free/disk.vmdk " "$TM_EXCLUSIONS_REPORT"
: > "$HOME/.config/tm_exclusions/custom.conf"
rm -rf "$HOME/VMs"
for name in $(seq 0 39) v v-b v.x; do
    mkdir -p "$HOME/many/vm$name"
    : > "$HOME/many/vm$name/vm$name.vbox"
    for k in 1 2 3 4; do
        dd if=/dev/zero of="$HOME/many/vm$name/disk$k.vmdk" bs=1 count=0 seek=537919488 2>/dev/null
    done
done
run 0 --dry-run
assert_eq 43 "$(grep -c '^WOULD .*many/vm[0-9a-z.-]* ' "$TM_EXCLUSIONS_REPORT")" \
    "200+ raw candidates collapse to one entry per VM folder"
assert_true "collapsed VM folders do not trigger LIMIT" \
    not grep -Fq 'LIMIT' "$TM_EXCLUSIONS_REPORT"
assert_file_lacks_regex "$TM_EXCLUSIONS_REPORT" '^WOULD .*\.vmdk ' \
    "covered disks are not planned on their own"
rm -rf "$HOME/many"

# Uninstall caps at 200, not 50: 25 VM folders (50 candidates with their descendants)
# must not starve an independent disk excluded alone, and no LIMIT is shown below the cap.
make_vms 25
dd if=/dev/zero of="$HOME/zz-alone.vmdk" bs=1 count=0 seek=537919488 2>/dev/null
TEST_EXCLUDED_PATH="$HOME/zz-alone.vmdk" run 0 --uninstall --dry-run
assert_file_contains "$TM_EXCLUSIONS_REPORT" "WOULD_REMOVE $HOME/zz-alone.vmdk" \
    "uninstall reaches an independent disk past 50 candidates"
assert_true "uninstall below its cap reports no LIMIT" not grep -Fq 'LIMIT' "$TM_EXCLUSIONS_REPORT"
rm -rf "$HOME/many" "$HOME/zz-alone.vmdk"

# Past 200 distinct candidates uninstall discloses LIMIT and keeps 200. Discovery only
# (processing 200 paths is slow), run from a sourced temp copy of the script.
mkdir -p "$HOME/lots"
for ((i = 0; i < 201; i++)); do mkdir "$HOME/lots/d$i.sparsebundle"; done
sed '/^main /d' "$ROOT/tm_exclusions.sh" > "$TEST_DIR/functions.sh"
for mode in uninstall apply; do
    expected=50
    [[ "$mode" = uninstall ]] && expected=200
    out="$(bash -c 'set -euo pipefail
        source "$1"; source "$2/locales/en.sh"; declare_i18n_en
        CONF_SCAN_IMAGES=1 MODE="$3"
        collect_post_scan_paths
        printf "%s\n" "$EXTRA_PATHS" | grep -c sparsebundle
        printf "%s\n" "$REPORT_LINES" | grep -c "^LIMIT "' _ "$TEST_DIR/functions.sh" "$ROOT" "$mode")"
    assert_eq "$expected
1" "$out" "$mode discovery keeps $expected of 201 candidates and reports LIMIT once"
done
rm -rf "$HOME/lots"

# Uninstall must still offer a disk excluded alone by an older version, even though
# exclusion mode now covers it with its VM folder (Box/Box.vbox) or bundle (X.utm).
mkdir -p "$HOME/Box" "$HOME/X.utm/Data"
: > "$HOME/Box/Box.vbox"
for big in "$HOME/Box/disk.vmdk" "$HOME/X.utm/Data/disk.qcow2"; do
    dd if=/dev/zero of="$big" bs=1 count=0 seek=537919488 2>/dev/null
done
TEST_EXCLUDED_PATH="$HOME/Box/disk.vmdk" run 0 --uninstall --dry-run
assert_file_contains "$TM_EXCLUSIONS_REPORT" "WOULD_REMOVE $HOME/Box/disk.vmdk" \
    "uninstall offers the disk an older version excluded alone in a VM folder"
TEST_EXCLUDED_PATH="$HOME/Box/Box.vbox" run 0 --uninstall --dry-run
assert_file_contains "$TM_EXCLUSIONS_REPORT" "WOULD_REMOVE $HOME/Box/Box.vbox" \
    "uninstall offers a .vbox file excluded alone, not only its folder"
TEST_EXCLUDED_PATH="$HOME/X.utm/Data/disk.qcow2" run 0 --uninstall --dry-run
assert_file_contains "$TM_EXCLUSIONS_REPORT" "WOULD_REMOVE $HOME/X.utm/Data/disk.qcow2" \
    "uninstall offers the disk an older version excluded alone inside a bundle"
run 0 --dry-run
assert_file_contains "$TM_EXCLUSIONS_REPORT" "WOULD $HOME/X.utm " \
    "exclusion mode still takes the bundle whole"
assert_true "exclusion mode does not walk into the bundle" \
    not grep -Fq "X.utm/Data" "$TM_EXCLUSIONS_REPORT"
rm -rf "$HOME/Box" "$HOME/X.utm"

# Documented limit: a keep inside a VM bundle protects the whole bundle; its disks are
# not walked, so they are not excluded individually.
mkdir -p "$HOME/Protected.utm/Data/saved"
dd if=/dev/zero of="$HOME/Protected.utm/Data/independent.qcow2" bs=1 count=0 seek=537919488 2>/dev/null
printf '%s\n' 'keep|~/Protected.utm/Data/saved|precious state' > "$HOME/.config/tm_exclusions/custom.conf"
run 0 --dry-run
assert_file_contains "$TM_EXCLUSIONS_REPORT" "KEEP  $HOME/Protected.utm (" \
    "a keep inside a VM bundle protects the bundle"
assert_file_lacks_regex "$TM_EXCLUSIONS_REPORT" '^WOULD .*independent\.qcow2' \
    "disks of a protected bundle are not excluded individually"
: > "$HOME/.config/tm_exclusions/custom.conf"
rm -rf "$HOME/Protected.utm"
mkdir -p "$HOME/disks/private.sparsebundle"

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
# Temp file (removed with TEST_DIR by the EXIT trap), never `source <(...)`:
# that defines nothing under Bash 3.2.
write_functions_file "$TEST_DIR/tm_exclusions_functions.sh"
# shellcheck disable=SC1091
source "$TEST_DIR/tm_exclusions_functions.sh"
require_functions normalize_path du_track_path keep_blocks parse_config_file
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
