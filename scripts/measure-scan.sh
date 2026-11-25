#!/usr/bin/env bash
# measure-scan.sh — reproducible before/after metrics for the dynamic scan (#13).
#
# Generates a representative fake tree under a temporary HOME (node_modules
# stores with nested .pnpm packages, Library/.bun prune zones, a static ~/.npm
# cache, plain project sources), then runs `tm_exclusions.sh --dry-run -q` on it
# twice and prints, for each run:
#   * dirs visited — every directory the scan's `find` evaluates (counted by a
#     wrapper `find`, so it measures traversal cost, not the output);
#   * wall seconds — plain run, no counting wrapper, best of $REPEAT runs;
#   * paths processed — number of `tmutil isexcluded` lookups (one per path the
#     scan decided to process), compared between the two runs for parity.
#
# "before" = full traversal. By default it is the same script with
# TM_EXCLUSIONS_NO_SCAN_PRUNE=1; pass --baseline PATH to compare against another
# checkout's tm_exclusions.sh instead (e.g. the pre-#13 master).
#
# Safe by construction: a throw-away HOME, tmutil/sudo/brew replaced by stubs
# first in PATH, --dry-run always. It never touches Time Machine.
#
# Usage: scripts/measure-scan.sh [--script PATH] [--baseline PATH] [--scale N]
#   --scale N   tree size multiplier (default 1, ~3k dirs); REPEAT=N timing runs
# Works with Bash 3.2 and stock macOS tools (BSD find, perl for sub-second time).
set -euo pipefail

SELF_DIR="$(
    source_dir="$(dirname -- "${BASH_SOURCE[0]}")" || exit 1
    [[ "$source_dir" != -* ]] || source_dir="./$source_dir"
    CDPATH='' cd -P -- "${source_dir}" >/dev/null 2>&1 && pwd
)"
SCRIPT="${SELF_DIR}/../tm_exclusions.sh"
BASELINE=""
SCALE=1
REPEAT="${REPEAT:-3}"

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --script) SCRIPT="$2"; shift 2 ;;
        --baseline) BASELINE="$2"; shift 2 ;;
        --scale) SCALE="$2"; shift 2 ;;
        -h|--help) sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done
[[ "$SCALE" =~ ^[1-9][0-9]*$ ]] || { echo "--scale must be a positive integer" >&2; exit 2; }
[[ -f "$SCRIPT" ]] || { echo "Script not found: $SCRIPT" >&2; exit 2; }
[[ -z "$BASELINE" || -f "$BASELINE" ]] || { echo "Baseline not found: $BASELINE" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
HOME_DIR="$WORK/home"
BIN="$WORK/bin"
mkdir -p "$HOME_DIR/.config/tm_exclusions" "$BIN"

# ---- stubs: nothing here can reach the real Time Machine or Homebrew -------
cat > "$BIN/tmutil" <<'STUB'
#!/bin/sh
printf '%s %s\n' "$1" "$2" >> "$TMUTIL_LOG"
[ "$1" = isexcluded ] && printf '[Included] %s\n' "$2"
exit 0
STUB
printf '#!/bin/sh\nexit 0\n' > "$BIN/brew"
cat > "$BIN/sudo" <<'STUB'
#!/bin/sh
case "$1" in -n|-v) exit 0 ;; tmutil) shift; exec tmutil "$@" ;; *) exit 1 ;; esac
STUB
# Visit-counting find: logs every directory find evaluates, then runs the
# unchanged expression (the first clause is always false).
cat > "$BIN/find-count" <<'STUB'
#!/bin/sh
root="$1"; depth_flag="$2"; depth="$3"; shift 3
for a in "$@"; do
    if [ "$a" = -print ]; then
        exec /usr/bin/find "$root" "$depth_flag" "$depth" \
            '(' -type d -exec sh -c 'printf "%s\n" "$@" >> "$VISITED_LOG"' sh '{}' + ! -type d ')' \
            -o '(' "$@" ')'
    fi
done
exec /usr/bin/find "$root" "$depth_flag" "$depth" \
    '(' -type d -exec sh -c 'printf "%s\n" "$@" >> "$VISITED_LOG"' sh '{}' + ! -type d ')' \
    -o '(' "$@" ')' -print
STUB
chmod +x "$BIN/"*

# ---- representative tree ---------------------------------------------------
LIST="$WORK/dirs.list"
: > "$LIST"
proj=1
while [[ "$proj" -le $((20 * SCALE)) ]]; do
    base="$HOME_DIR/Git/proj$proj"
    printf '%s\n' "$base/src" "$base/src/lib" "$base/dist" >> "$LIST"
    pkg=1
    while [[ "$pkg" -le 25 ]]; do
        # a pnpm-style store: node_modules/.pnpm/<pkg>/node_modules/<pkg>/{lib,src}
        s="$base/node_modules/.pnpm/pkg$pkg/node_modules/pkg$pkg"
        printf '%s\n' "$s/lib" "$s/src" "$s/test" >> "$LIST"
        pkg=$((pkg + 1))
    done
    proj=$((proj + 1))
done
n=1
while [[ "$n" -le $((200 * SCALE)) ]]; do
    printf '%s\n' "$HOME_DIR/Library/Caches/app$n/cache/data" "$HOME_DIR/Library/Application Support/app$n/node_modules/x" >> "$LIST"
    n=$((n + 1))
done
n=1
while [[ "$n" -le $((100 * SCALE)) ]]; do
    printf '%s\n' "$HOME_DIR/.bun/install/cache/pkg$n/node_modules/y" "$HOME_DIR/.npm/_cacache/content-v2/sha$n/node_modules/z" >> "$LIST"
    n=$((n + 1))
done
# one-argument-per-line, spaces are fine: -I {} keeps each line as one argument
xargs -I{} mkdir -p {} < "$LIST"
DIR_COUNT="$(find "$HOME_DIR" -type d | wc -l | tr -d ' ')"

now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time' 2>/dev/null || date +%s; }

# run_once LABEL SCRIPT NOPRUNE WRAPPER -> visited count, seconds, calls in $WORK/*.LABEL
run_once() {
    local label="$1" script="$2" noprune="$3" counting="$4" t0 t1
    : > "$WORK/tmutil.$label"
    : > "$WORK/visited.$label"
    t0="$(now)"
    # shellcheck disable=SC2097,SC2098  # per-command env assignments are intended
    if [[ "$counting" = 1 ]]; then
        mkdir -p "$WORK/count-bin"
        cp "$BIN/find-count" "$WORK/count-bin/find"
        env HOME="$HOME_DIR" PATH="$WORK/count-bin:$BIN:$PATH" \
            TMUTIL_LOG="$WORK/tmutil.$label" VISITED_LOG="$WORK/visited.$label" \
            TM_EXCLUSIONS_NO_SCAN_PRUNE="$noprune" TM_EXCLUSIONS_SKIP_INVENTORY=1 \
            TM_EXCLUSIONS_SKIP_DU=1 TM_EXCLUSIONS_REPORT="$WORK/report.$label" \
            bash "$script" --dry-run -q > "$WORK/run.$label.log" 2>&1 || {
                cat "$WORK/run.$label.log" >&2
                return 1
            }
    else
        env HOME="$HOME_DIR" PATH="$BIN:$PATH" TMUTIL_LOG="$WORK/tmutil.$label" \
            TM_EXCLUSIONS_NO_SCAN_PRUNE="$noprune" TM_EXCLUSIONS_SKIP_INVENTORY=1 \
            TM_EXCLUSIONS_SKIP_DU=1 TM_EXCLUSIONS_REPORT="$WORK/report.$label" \
            bash "$script" --dry-run -q > "$WORK/run.$label.log" 2>&1 || {
                cat "$WORK/run.$label.log" >&2
                return 1
            }
    fi
    t1="$(now)"
    perl -e 'printf "%.2f\n", $ARGV[1] - $ARGV[0]' "$t0" "$t1" 2>/dev/null || echo "$((t1 - t0))"
}

best_time() {
    local label="$1" script="$2" noprune="$3" best="" t i=1
    while [[ "$i" -le "$REPEAT" ]]; do
        t="$(run_once "$label" "$script" "$noprune" 0)" || return 1
        if [[ -z "$best" ]] || perl -e 'exit !($ARGV[0] < $ARGV[1])' "$t" "$best" 2>/dev/null; then best="$t"; fi
        i=$((i + 1))
    done
    printf '%s\n' "$best"
}

BEFORE_SCRIPT="${BASELINE:-$SCRIPT}"
BEFORE_NOPRUNE=1
[[ -n "$BASELINE" ]] && BEFORE_NOPRUNE=0

run_once before "$BEFORE_SCRIPT" "$BEFORE_NOPRUNE" 1 > /dev/null
run_once after "$SCRIPT" 0 1 > /dev/null
T_BEFORE="$(best_time before_t "$BEFORE_SCRIPT" "$BEFORE_NOPRUNE")"
T_AFTER="$(best_time after_t "$SCRIPT" 0)"

V_BEFORE="$(sort -u "$WORK/visited.before" | grep -c . || true)"
V_AFTER="$(sort -u "$WORK/visited.after" | grep -c . || true)"
P_BEFORE="$(grep -c '^isexcluded ' "$WORK/tmutil.before" || true)"
P_AFTER="$(grep -c '^isexcluded ' "$WORK/tmutil.after" || true)"

printf 'tree: %s directories under a temporary HOME (scale %s), Bash %s\n' "$DIR_COUNT" "$SCALE" "${BASH_VERSION%%(*}"
printf '%-8s %14s %14s %18s\n' "" "dirs visited" "wall seconds" "paths processed"
printf '%-8s %14s %14s %18s\n' before "$V_BEFORE" "$T_BEFORE" "$P_BEFORE"
printf '%-8s %14s %14s %18s\n' after "$V_AFTER" "$T_AFTER" "$P_AFTER"
if [[ "$V_BEFORE" -gt 0 ]]; then
    printf 'traversal reduced by %s%% (%s -> %s directories)\n' \
        "$(( (V_BEFORE - V_AFTER) * 100 / V_BEFORE ))" "$V_BEFORE" "$V_AFTER"
fi

if diff <(grep '^isexcluded ' "$WORK/tmutil.before") <(grep '^isexcluded ' "$WORK/tmutil.after") > /dev/null; then
    echo "parity: OK — identical processed paths, same order"
else
    echo "parity: MISMATCH — processed paths differ between before and after" >&2
    diff <(grep '^isexcluded ' "$WORK/tmutil.before") <(grep '^isexcluded ' "$WORK/tmutil.after") | head -20 >&2 || true
    exit 1
fi
