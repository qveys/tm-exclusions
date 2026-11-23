#!/usr/bin/env bash
# tm_exclusions.sh — macOS Time Machine exclusion manager for developer machines
# Automatically excludes regenerable content from backups.
#
# Compatible with Bash 3.2+ (stock macOS).
# Requires: tmutil (macOS built-in)
#
# Note: Some exclusions applied via `tmutil addexclusion` may not appear
# in System Settings > Time Machine UI, even though they are active.
# Use `tmutil isexcluded <path>` to verify.

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
readonly VERSION="1.3.0"
readonly PROGRAM_NAME="tm-exclusions"
readonly CUSTOM_CONF="${HOME}/.config/tm_exclusions/custom.conf"
readonly REPORT_FILE="${HOME}/.config/tm_exclusions/last_report.txt"
readonly CUSTOM_CONF_DIR="${HOME}/.config/tm_exclusions"
# Image discovery caps: what apply adds, and what --uninstall (removal only) walks.
readonly IMAGE_CAP_APPLY=50 IMAGE_CAP_UNINSTALL=200

# ---------------------------------------------------------------------------
# Global state
# ---------------------------------------------------------------------------
MODE="apply"          # apply | dry-run | report-only | uninstall
QUIET=0
VERBOSE=0
BATCH_EVENTS=""
FORCE=0
LANG_OVERRIDE=""
CURRENT_LANG="en"
DRY_RUN=0
CONFIG_CMD=""         # add | list | edit | init
CONFIG_ADD_TYPE=""
CONFIG_ADD_PATH=""
CONFIG_ADD_REASON=""
DESKTOP_REPORT=0

# Counters for report
TOTAL_CHECKED=0
TOTAL_EXCLUDED=0
TOTAL_ALREADY=0
TOTAL_SKIPPED=0
TOTAL_ERRORS=0
TOTAL_REMOVED=0
TOTAL_BLOCKED=0
TOTAL_NOT_FOUND=0

# Arrays (Bash 3.2 compatible — indexed arrays)
# We store paths/patterns/prunes as newline-delimited strings
CONF_PATHS=""
CONF_PATTERNS=""
CONF_PRUNES=""
CONF_KEEPS=""
CONF_RULES=""
RULE_CONTEXT=""
# Category (#@<Name> section marker) of the rule being parsed or processed; empty
# means the default category (rules before any marker, or `#@` with no name).
RULE_CATEGORY=""
CONF_SCAN_IMAGES=0
# Report destination preferences from setting|key|value (last file wins)
CONF_REPORT_PATH=""
CONF_DESKTOP_REPORT=0
REPORT_LINES=""
# Same detail lines as REPORT_LINES, as "<category>\t<line>" records for grouping.
REPORT_GROUPED=""
RULE_SUMMARY=""
TM_LIST_STATUS="not-run"
# Paths discovered after config (brew cache, large VM images); newline-separated
EXTRA_PATHS=""
# Unique existing paths for optional du summary in report
DU_PATHS=""
SUDO_KEEPALIVE_PID=""
# Temporary paths to remove on exit/signal, and the private work directory that
# holds every temporary file (see ensure_tmp_dir)
TMP_FILES=""
TMP_DIR=""
# When 1, log_info also appends to FD 5 (opened from TM_EXCLUSIONS_DEBUG_FIFO)
DEBUG_LOG_FD=0

# ---------------------------------------------------------------------------
# i18n locale resolution
# ---------------------------------------------------------------------------
# Finds the locales/ directory. Tries in order:
#   1. TM_EXCLUSIONS_LOCALES_DIR env var (escape hatch for tests / unusual installs;
#      ignored when running as root to avoid sourcing an untrusted path)
#   2. <script_dir>/locales/          (source-checkout layout)
#   3. <script_dir>/../share/tm-exclusions/locales/  (installed layout)
#   4. /usr/local/share, /opt/homebrew/share, /usr/share (Homebrew / system install roots)
resolve_locales_dir() {
    local script_dir candidate
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # Env-var override takes precedence when set, but only for non-root runs.
    # Under `sudo -E`, allowing this variable to control a `source`d path would be
    # a privilege-escalation footgun.
    if [[ -n "${TM_EXCLUSIONS_LOCALES_DIR:-}" && "${EUID}" -ne 0 ]]; then
        echo "${TM_EXCLUSIONS_LOCALES_DIR}"
        return 0
    fi

    for candidate in \
        "${script_dir}/locales" \
        "${script_dir}/../share/tm-exclusions/locales" \
        "/usr/local/share/tm-exclusions/locales" \
        "/opt/homebrew/share/tm-exclusions/locales" \
        "/usr/share/tm-exclusions/locales"
    do
        if [[ -d "${candidate}" ]]; then
            echo "${candidate}"
            return 0
        fi
    done

    return 1
}

# Source the locale file for the given language and call its declare function.
# Exits non-zero with a clear error if the locale file cannot be found.
# lang is allowlisted (en|fr) so untrusted --lang values never become filenames.
load_i18n() {
    local lang="$1"
    local locales_dir locale_file

    case "$lang" in
        en|fr) ;;
        *) lang="en" ;;
    esac

    locales_dir="$(resolve_locales_dir)" || {
        echo "Error: locale files not found; expected locales/${lang}.sh in <script-dir>/locales or installed share dir" >&2
        exit 1
    }

    locale_file="${locales_dir}/${lang}.sh"
    if [[ ! -f "${locale_file}" ]]; then
        echo "Error: locale files not found; expected locales/${lang}.sh in ${locales_dir}" >&2
        exit 1
    fi

    # shellcheck source=/dev/null
    source "${locale_file}"

    if ! declare -F "declare_i18n_${lang}" >/dev/null 2>&1; then
        echo "Error: ${locale_file} does not define declare_i18n_${lang}()" >&2
        exit 1
    fi

    "declare_i18n_${lang}"
}

# ---------------------------------------------------------------------------
# Utility functions
# ---------------------------------------------------------------------------
# Presentation is terminal-only; reports, pipes and debug logs stay plain.
UI=0
UI_PROGRESS=0
UI_DONE=0
UI_TOTAL=0
UI_RESET=""
UI_CYAN=""
UI_GREEN=""
UI_DIM=""

init_ui() {
    if [[ -t 1 && "${TERM:-dumb}" != "dumb" && -z "${NO_COLOR:-}" && "${QUIET}" -eq 0 ]]; then
        UI=1
        UI_RESET=$'\033[0m'
        UI_CYAN=$'\033[1;36m'
        UI_GREEN=$'\033[32m'
        UI_DIM=$'\033[2m'
    fi
}

clear_progress() {
    if [[ "${UI_PROGRESS}" -eq 1 ]]; then
        printf '\r\033[2K'
        UI_PROGRESS=0
    fi
}

ui_section() {
    clear_progress
    if [[ "${UI}" -eq 1 ]]; then
        printf '\n%s  %s  %s%s\n\n' "$UI_CYAN" "$1" "$2" "$UI_RESET"
    else
        log_info ""
        log_info "$2"
    fi
}

# Reserve two cells per character so wide Unicode paths cannot wrap the status.
show_scan_path() {
    [[ "${UI}" -eq 1 ]] || return 0
    local display="$1" width=$(((SCAN_COLUMNS - 6) / 2))
    [[ "$width" -gt 3 ]] || return 0
    # Literal home abbreviation for display only.
    # shellcheck disable=SC2088
    case "$display" in
        "$HOME") display="~" ;;
        "$HOME/"*) display="~/${display#"$HOME/"}" ;;
    esac
    display="${display//[[:cntrl:]]/?}"
    if [[ "${#display}" -gt "$width" ]]; then
        display="…${display: -$((width - 1))}"
    fi
    printf '\r\033[2K  %s› %s%s' "$UI_DIM" "$display" "$UI_RESET"
    UI_PROGRESS=1
}

progress_start() {
    [[ "${UI}" -eq 1 ]] || return 0
    UI_DONE=0
    UI_TOTAL=$(printf '%s\n' "$1" | awk 'length($0) {n++} END {print n+0}')
    progress_draw
}

progress_draw() {
    [[ "${UI}" -eq 1 && "${UI_TOTAL}" -gt 0 ]] || return 0
    local filled=$((UI_DONE * 20 / UI_TOTAL)) bar="" i
    for ((i=0; i<20; i++)); do
        if [[ "$i" -lt "$filled" ]]; then bar="${bar}━"; else bar="${bar}·"; fi
    done
    printf '\r\033[2K  %s%s%s %3d%%  %d/%d' "$UI_CYAN" "$bar" "$UI_RESET" \
        "$((UI_DONE * 100 / UI_TOTAL))" "$UI_DONE" "$UI_TOTAL"
    UI_PROGRESS=1
    if [[ "${UI_DONE}" -eq "${UI_TOTAL}" ]]; then
        printf '\n'
        UI_PROGRESS=0
    fi
}

progress_step() {
    [[ "${UI}" -eq 1 ]] || return 0
    UI_DONE=$((UI_DONE + 1))
    progress_draw
}

# End-of-run banner for interactive runs (#44). Arguments, all computed once by
# generate_report so the banner and the saved report show the same figures:
#   $1 label of the excluded counter     $2 disk usage total of touched paths
#   $3 label of the space-excluded line  $4 space-excluded value ("" = hide)
#   $5 report file path ("" = hide)     $6 path for the verification tip ("" = example)
# --quiet never shows it. Nothing here runs du: every size was measured once
# while its path was processed.
ui_summary() {
    [[ "${QUIET}" -eq 0 ]] || return 0
    ui_section "📊" "${MSG_UI_SUMMARY}"
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        printf '  %s%s %s%s\n' "$UI_CYAN" "$MSG_DRY_RUN_PREFIX" "$MSG_UI_SIMULATED_NOTE" "$UI_RESET"
    fi
    printf '  %s %s\n' "$MSG_REPORT_CHECKED" "$TOTAL_CHECKED"
    printf '  %s%s %s%s\n' "$UI_GREEN" "$1" "$TOTAL_EXCLUDED" "$UI_RESET"
    printf '  %s %s\n' "$MSG_REPORT_ALREADY" "$TOTAL_ALREADY"
    printf '  %s%s %s%s\n' "$UI_DIM" "$MSG_REPORT_SKIPPED" "$TOTAL_SKIPPED" "$UI_RESET"
    printf '  %s %s\n' "$MSG_REPORT_NOT_FOUND" "$TOTAL_NOT_FOUND"
    printf '  %s %s\n' "$MSG_REPORT_ERRORS" "$TOTAL_ERRORS"
    printf '  %s %s\n' "$MSG_REPORT_BLOCKED" "$TOTAL_BLOCKED"
    # Cumulative disk usage of the paths touched in this run (#45). The total is
    # computed once by generate_report and passed in as $2 — never recomputed
    # here — so the summary always matches the report even if a path disappears
    # while tmutil listexclusions runs between the two.
    if [[ -n "${2:-}" ]]; then
        printf '  %s %s\n' "$MSG_REPORT_SIZE_TOTAL" "$2"
    fi
    if [[ -n "${4:-}" ]]; then
        printf '  %s%s %s%s\n' "$UI_GREEN" "$3" "$4" "$UI_RESET"
    fi
    if [[ "${MODE}" = "uninstall" ]]; then
        printf '  %s %s\n' "$MSG_REPORT_REMOVED" "$TOTAL_REMOVED"
    fi
    if [[ -n "${5:-}" ]]; then
        printf '\n  %s📄 %s %s%s\n' "$UI_CYAN" "$MSG_REPORT_SAVED" "$5" "$UI_RESET"
    fi
    # Copy-pasteable command: a real path, shell-quoted (printf %q, Bash 3.2),
    # or a placeholder-free example when no path was processed. Paths are
    # absolute, so a leading "-" can never be read as an option.
    local tip_arg
    if [[ -n "${6:-}" ]]; then
        tip_arg="$(printf '%q' "$6")"
    else
        tip_arg="\"${MSG_UI_VERIFY_EXAMPLE}\""
    fi
    printf '  %s💡 %s tmutil isexcluded %s%s\n' "$UI_DIM" "$MSG_UI_VERIFY_TIP" "$tip_arg" "$UI_RESET"
}

log_info() {
    if [[ "${QUIET}" -eq 0 ]]; then
        clear_progress
        if [[ "${UI}" -eq 1 && -n "$*" ]]; then
            local color="$UI_DIM" icon="•"
            case "$*" in
                *"${MSG_DRY_RUN_PREFIX}"*) color="$UI_CYAN"; icon="🧪" ;;
                *"${MSG_APPLYING}"*|*"${MSG_ALREADY}"*) color="$UI_GREEN"; icon="✓" ;;
                *"${MSG_REMOVING}"*) color="$UI_CYAN"; icon="↩" ;;
                *"${MSG_REPORT_SAVED}"*|*"${MSG_REPORT_DESKTOP_COPY}"*) color="$UI_CYAN"; icon="📄" ;;
            esac
            printf '  %s%s %s%s\n' "$color" "$icon" "$*" "$UI_RESET"
        else
            printf '%s\n' "$*"
        fi
        if [[ "${DEBUG_LOG_FD}" -eq 1 ]]; then
            echo "$@" >&5 2>/dev/null || true
        fi
    fi
}

# Display label of the current rule category; the default category (empty) is
# localized. Sets CATEGORY_LABEL as a side effect — never capture it with $().
category_label() {
    CATEGORY_LABEL="${RULE_CATEGORY:-${MSG_CATEGORY_DEFAULT:-Uncategorized}}"
}

# Section header printed when output switches to a new category (#46).
ui_category() {
    [[ "${QUIET}" -eq 0 ]] || return 0
    clear_progress
    if [[ "${UI}" -eq 1 ]]; then
        printf '\n  %s══ %s ══%s\n' "$UI_CYAN" "$1" "$UI_RESET"
        if [[ "${DEBUG_LOG_FD}" -eq 1 ]]; then
            echo "══ $1 ══" >&5 2>/dev/null || true
        fi
    else
        log_info "══ $1 ══"
    fi
}

# Presentation only: decisions, counters and report details stay in process_path.
# Natural roots keep workspace packages together without merging separate repos.
batch_root() {
    local relative first rest
    BATCH_ROOT="${1%/*}"
    case "$1" in
        "$HOME/"*)
            relative="${1#"$HOME/"}"
            first="${relative%%/*}"
            case "$first" in
                .*) BATCH_ROOT="$HOME/$first" ;;
                Git)
                    if [[ "$relative" = Git ]]; then
                        BATCH_ROOT="$HOME/Git"
                    else
                        rest="${relative#*/}"
                        BATCH_ROOT="$HOME/Git/${rest%%/*}"
                    fi
                    ;;
            esac
            ;;
    esac
    [[ -n "$BATCH_ROOT" ]] || BATCH_ROOT="/"
}

# Buffers one presentation event as "<category>\t<action>\t<root>" (grouped
# summary) or "<category>\tdetail\t<line>" (--verbose). flush_path_results
# prints them under one `══ Category ══` header per category (#46).
log_path_result() {
    local action="$1" path="$2" detail="${3:-}"
    [[ "$QUIET" -eq 0 ]] || return 0
    category_label
    if [[ "$VERBOSE" -eq 1 ]]; then
        [[ -z "$detail" ]] || BATCH_EVENTS="${BATCH_EVENTS}${CATEGORY_LABEL}"$'\tdetail\t'"${detail}"$'\n'
        return 0
    fi
    BATCH_ROOT=""
    case "$action" in
        missing|already) ;;
        *) batch_root "$path" ;;
    esac
    BATCH_EVENTS="${BATCH_EVENTS}${CATEGORY_LABEL}"$'\t'"${action}"$'\t'"${BATCH_ROOT}"$'\n'
}

flush_path_results() {
    [[ -n "$BATCH_EVENTS" ]] || return 0
    local line kind rest action count root label
    while IFS= read -r line; do
        kind="${line%%$'\t'*}"
        rest="${line#*$'\t'}"
        case "$kind" in
            H) ui_category "$rest"; continue ;;
            D) log_info "$rest"; continue ;;
        esac
        IFS=$'\t' read -r action count root <<< "$rest"
        case "$action" in
            missing) label="$MSG_REPORT_NOT_FOUND" ;;
            already) label="$MSG_REPORT_ALREADY" ;;
            prune) label="$MSG_BATCH_PRUNED" ;;
            remove)
                label="$MSG_REPORT_REMOVED"
                if [[ "$DRY_RUN" -eq 1 ]]; then
                    label="$MSG_DRY_RUN_PREFIX $label"
                fi
                ;;
            need) label="$MSG_REPORT_NEED_EXCLUSION" ;;
            apply)
                label="$MSG_REPORT_EXCLUDED"
                if [[ "$DRY_RUN" -eq 1 ]]; then label="$MSG_DRY_RUN_PREFIX $MSG_REPORT_WOULD_EXCLUDE"; fi
                ;;
            *) continue ;;
        esac
        if [[ -n "$root" ]]; then
            log_info "  $root → $label $count"
        else
            log_info "  $label $count ($MSG_BATCH_DETAILS)"
        fi
    done < <(printf '%s' "$BATCH_EVENTS" | awk -F '\t' '
        NF >= 3 {
            c = $1
            if (!(c in known)) { known[c] = 1; cats[++nc] = c }
            if ($2 == "detail") {
                p = $0
                sub(/^[^\t]*\t[^\t]*\t/, "", p)
                r = ++rows[c]; kind[c, r] = "D"; val[c, r] = p
            } else {
                if (!($0 in counts)) { r = ++rows[c]; kind[c, r] = "A"; val[c, r] = $0 }
                counts[$0]++
            }
        }
        END {
            for (i = 1; i <= nc; i++) {
                c = cats[i]
                printf "H\t%s\n", c
                for (r = 1; r <= rows[c]; r++) {
                    if (kind[c, r] == "D") {
                        printf "D\t%s\n", val[c, r]
                    } else {
                        split(val[c, r], f, "\t")
                        printf "A\t%s\t%d\t%s\n", f[2], counts[val[c, r]], f[3]
                    }
                }
            }
        }')
    BATCH_EVENTS=""
}

log_error() {
    clear_progress
    if [[ -t 2 && "${TERM:-dumb}" != "dumb" && -z "${NO_COLOR:-}" ]]; then
        printf '\033[33m  ⚠ %s\033[0m\n' "$*" >&2
    else
        printf '%s\n' "$*" >&2
    fi
}

add_report_line() {
    local detail="$1"
    case "$detail" in
        SKIP\ *\(not\ found\))
            TOTAL_NOT_FOUND=$((TOTAL_NOT_FOUND + 1))
            ;;
    esac
    update_rule_summary "$detail"
    if [[ -n "$RULE_CONTEXT" ]]; then detail="$detail [$RULE_CONTEXT]"; fi
    category_label
    REPORT_GROUPED="${REPORT_GROUPED}${CATEGORY_LABEL}"$'\t'"${detail//$'\n'/ }"$'\n'
    if [[ -z "${REPORT_LINES}" ]]; then
        REPORT_LINES="$detail"
    else
        REPORT_LINES="${REPORT_LINES}
$detail"
    fi
}

update_rule_summary() {
    local action="$1" key="$RULE_CONTEXT" line count found=0 new_summary=""
    [[ -z "$key" ]] && return 0
    action="${action%% *}"
    while IFS=$'\t' read -r line count; do
        [[ -z "$line" ]] && continue
        if [[ "$line" = "$key" ]]; then
            count=$((count + 1))
            found=1
        fi
        new_summary="${new_summary}${line}"$'\t'"${count}"$'\n'
    done <<EOF
${RULE_SUMMARY}
EOF
    if [[ "$found" -eq 0 ]]; then
        new_summary="${new_summary}${key}"$'\t1\n'
    fi
    RULE_SUMMARY="$new_summary"
}

# Size measurement only (never called by keep/exclusion/uninstall guards).
# True (0) when measuring $1 could hit the WRONG directory because its raw or
# resolved name holds a newline: `$(...)` strips a trailing newline, so an alias
# to "small<LF>" resolves (in normalize_path) to the neighbouring "small" and its
# size would be shown instead (#44 review). Such paths are never measured and
# count as unmeasured. Returns 1 (safe) otherwise.
#
# Rule: a path that holds a symlink or ".." and whose physical resolution FAILS
# is unsafe too — never fall back to measuring the raw path.
#
# Cheap by construction: a path without newline, without "." / ".." component
# and with no symlink among its prefixes (the usual case) is decided with shell
# builtins only — no subshell, no cd. Only otherwise are the components resolved
# with an "x" sentinel and a separately tested `cd -P && pwd -P`. No memo:
# process_path asks once per processed path and keeps the answer in
# SIZE_UNSAFE_NOW, so it can never be stale for the next rule.
SIZE_UNSAFE_NOW=0
size_path_unsafe() {
    local p="$1" rest part prefix="" slow=0 normalized="" physical out rc=1
    case "$p" in
        *$'\n'*) rc=0 ;;
        *)
            [[ "$p" = /* ]] || slow=1
            rest="$p"
            while [[ "$slow" -eq 0 ]]; do
                part="${rest%%/*}"
                case "$part" in
                    ''|.) ;;
                    ..) slow=1 ;;
                    *)
                        prefix="${prefix}/${part}"
                        [[ -L "$prefix" ]] && slow=1
                        ;;
                esac
                case "$rest" in
                    */*) rest="${rest#*/}" ;;
                    *) break ;;
                esac
            done
            if [[ "$slow" -eq 1 ]]; then
                rest="$p"
                while :; do
                    part="${rest%%/*}"
                    case "$part" in
                        ''|.) ;;
                        ..) normalized="${normalized%/*}" ;;
                        *) normalized="${normalized}/$part" ;;
                    esac
                    if [[ -d "${normalized:-/}" ]]; then
                        # cd and pwd failures are propagated, not masked by the sentinel.
                        out="$(cd -P -- "${normalized:-/}" 2>/dev/null && pwd -P && printf x)" || { rc=0; break; }
                        physical="${out%x}"
                        physical="${physical%$'\n'}"
                        case "$physical" in
                            *$'\n'*) rc=0; break ;;
                        esac
                        normalized="${physical%/}"
                    fi
                    case "$rest" in
                        */*) rest="${rest#*/}" ;;
                        *) break ;;
                    esac
                done
            fi
            ;;
    esac
    return "$rc"
}

# Track paths for optional du summary (dedupe; Bash 3.2 — no associative arrays)
du_track_path() {
    local p="$1"
    [[ -z "$p" || ! -e "$p" ]] && return 0
    # Size bookkeeping only: never record a name whose measurement would hit the
    # wrong directory (#44).
    if [[ "$SIZE_UNSAFE_NOW" -eq 1 ]]; then return 0; fi
    DU_PATHS="$(path_set_add "$DU_PATHS" "$p")"
}

# Prints the newline-separated path set $1 with $2 merged in. Compare physical
# spellings: symlinked and `..`-relative duplicates must not inflate a total,
# and stored entries are normalized on the way in too. A path already covered
# by a stored ancestor is not added; stored descendants of $2 are dropped.
# Same logic as the former inline du_track_path (used only by it); it makes no
# newline decision: du_track_path skips unsafe names first (size_path_unsafe).
path_set_add() {
    local set="$1" p="$2" entry normalized retained=""
    if ! p="$(normalize_path "$p")"; then
        printf '%s' "$set"
        return 0
    fi
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        normalized="$entry"
        if [[ -e "$entry" ]]; then
            normalized="$(normalize_path "$entry")" || normalized="$entry"
        fi
        if path_under "$p" "$normalized"; then
            printf '%s' "$set"
            return 0
        fi
        if ! path_under "$normalized" "$p"; then retained="${retained}${normalized}
"; fi
    done <<EOF
${set}
EOF
    printf '%s%s' "$retained" "$p"
}

# Paths newly excluded (or that would be, in dry-run/audit) by this run, for the
# "space excluded" figure of the end-of-run summary and the report (#44); they
# are recorded in the EXCL_FILE temporary file (see excl_track_path).
EXCL_TOTAL_KB=0
EXCL_MEASURED=0
EXCL_UNKNOWN=0
SPACE_EXCL_DISP=""

EXCL_UNTRACKED=0
# First newly excluded path and first processed existing path: the verification
# tip of the banner shows a real, copy-pasteable command (#44).
EXCL_FIRST_PATH=""
TIP_PATH=""

# Records $1 (already measured by path_size_column) for the space figure: one
# "<normalized path><TAB><complete KiB or empty>" line appended to a temporary
# file (split at the last tab, so tabs in names are safe). Nothing is
# concatenated in a shell variable (that is quadratic in Bash 3.2) and no cd,
# stat or cache lookup happens here; nesting is decided later, in one awk pass
# (excl_space_compute). A path whose name is unsafe to measure (size_path_unsafe:
# newline), without a normalized form, or holding the byte 0x01 (unsupported:
# it is the awk/sort field separator) is counted as unmeasured instead.
EXCL_FILE=""
EXCL_FILE_FAILED=0
EXCL_TRACKED=0
excl_track_path() {
    local p="$1"
    [[ -z "$p" || ! -e "$p" ]] && return 0
    if [[ -z "$EXCL_FIRST_PATH" ]]; then EXCL_FIRST_PATH="$p"; fi
    du_enabled || return 0
    case "$PATH_SIZE_NP" in
        *$'\001'*) EXCL_UNTRACKED=$((EXCL_UNTRACKED + 1)); return 0 ;;
    esac
    if [[ "$SIZE_UNSAFE_NOW" -eq 1 || -z "$PATH_SIZE_NP" || "$EXCL_FILE_FAILED" -eq 1 ]]; then
        EXCL_UNTRACKED=$((EXCL_UNTRACKED + 1))
        return 0
    fi
    if [[ -z "$EXCL_FILE" ]]; then
        if ! make_tmp_file EXCL_FILE space 2>/dev/null; then
            EXCL_FILE_FAILED=1
            EXCL_UNTRACKED=$((EXCL_UNTRACKED + 1))
            return 0
        fi
    fi
    if printf '%s\t%s\n' "$PATH_SIZE_NP" "$PATH_SIZE_KB" >> "$EXCL_FILE" 2>/dev/null; then
        EXCL_TRACKED=$((EXCL_TRACKED + 1))
    else
        # A failed write can leave a fragment without its newline: the journal
        # is no longer trustworthy, so stop writing and let the aggregation
        # report everything as unmeasured.
        EXCL_FILE_FAILED=1
        EXCL_UNTRACKED=$((EXCL_UNTRACKED + 1))
    fi
}

# Sets EXCL_TOTAL_KB / EXCL_MEASURED / EXCL_UNKNOWN from the EXCL_FILE records —
# sizes already measured while each path was processed, never a fresh du (it can
# take tens of seconds per tree). An entry is MEASURED when its size is complete,
# UNMEASURED when du failed or was partial (non-zero exit, GNU and BSD alike);
# unmeasured entries are counted in EXCL_UNKNOWN and never added.
#
# Semantics (display value only; no decision reads it):
# - Entries nest by path PREFIX, with ASCII case folded (case-insensitive APFS:
#   "Cache" / "cache/Child"); non-ASCII case is not folded. An ancestor boundary
#   is a "/" ("foo" is not an ancestor of "foo-bar" or "foo bar").
# - An entry is ignored when it lies under a MEASURED entry (that size already
#   contains it), or — if itself unmeasured — under any unmeasured ancestor
#   (already counted there). A measured descendant of an unmeasured ancestor is
#   kept as a lower-bound contribution. Entries with the same folded path count
#   once (measured if any of them is, with the larger size).
# - Aliases / hard links between DIFFERENT paths are not detected: they are
#   summed as separate paths. In apply mode a path inheriting an exclusion
#   already set on its parent is not "newly excluded", so the order of
#   application can change the figure.
#
# One pass: awk builds "<folded path>/<0x01><KiB>" keys, `LC_ALL=C sort` orders
# them (an ancestor sorts right before its descendants), and a second awk walks
# the sorted list with a stack of open ancestors. O(n log n), no shell loop.
# Not meant for $() — it sets globals.
excl_space_compute() {
    local res="" total="" measured="" unknown=""
    EXCL_TOTAL_KB=0
    EXCL_MEASURED=0
    EXCL_UNKNOWN="$EXCL_UNTRACKED"
    if [[ "$EXCL_FILE_FAILED" -eq 1 ]]; then
        # The journal may hold a truncated record: never read it, no false total.
        EXCL_UNKNOWN=$((EXCL_TRACKED + EXCL_UNTRACKED))
        return 0
    fi
    [[ -n "$EXCL_FILE" && "$EXCL_TRACKED" -gt 0 ]] || return 0
    if res="$(LC_ALL=C awk '
            {
                line = $0
                j = length(line)
                while (j > 0 && substr(line, j, 1) != "\t") j--
                if (j == 0) next
                k = tolower(substr(line, 1, j - 1))
                if (substr(k, length(k), 1) != "/") k = k "/"
                printf "%s\001%s\n", k, substr(line, j + 1)
            }' "$EXCL_FILE" | LC_ALL=C sort | LC_ALL=C awk '
            function flush(   mc, uc) {
                if (!have) return
                while (sp > 0 && index(ckey, sk[sp]) != 1) sp--
                mc = 0; uc = 0
                if (sp > 0) { mc = smc[sp]; uc = suc[sp] }
                if (mc > 0) { }
                else if (cm) { total += ckb; meas++ }
                else if (uc == 0) { unk++ }
                sp++
                sk[sp] = ckey
                smc[sp] = mc + (cm ? 1 : 0)
                suc[sp] = uc + (cm ? 0 : 1)
            }
            {
                i = index($0, "\001")
                key = substr($0, 1, i - 1)
                kb = substr($0, i + 1)
                m = (kb ~ /^[0-9]+$/)
                if (have && key == ckey) {
                    if (m) { if (!cm || kb + 0 > ckb + 0) ckb = kb + 0; cm = 1 }
                    next
                }
                flush()
                ckey = key; cm = m; ckb = m ? kb + 0 : 0; have = 1
            }
            END { flush(); printf "%.0f %d %d\n", total, meas, unk }')"; then
        read -r total measured unknown <<< "$res"
        case "${total}${measured}${unknown}" in
            ''|*[!0-9]*) res="" ;;
        esac
    else
        res=""
    fi
    if [[ -z "$res" ]]; then
        # Aggregation failed: stay cautious, nothing measured.
        EXCL_UNKNOWN=$((EXCL_UNTRACKED + EXCL_TRACKED))
        return 0
    fi
    EXCL_TOTAL_KB="$total"
    EXCL_MEASURED="$measured"
    EXCL_UNKNOWN=$((EXCL_UNTRACKED + unknown))
    return 0
}

# Sets SPACE_EXCL_DISP: the readable total, "≥ <total> (partial: N unmeasured)"
# when some sizes are unknown, or "unknown" when none could be measured.
# Empty when the figure does not apply (du disabled or uninstall mode).
excl_space_display() {
    SPACE_EXCL_DISP=""
    du_enabled || return 0
    [[ "${MODE}" != "uninstall" ]] || return 0
    excl_space_compute
    if [[ "$EXCL_UNKNOWN" -eq 0 ]]; then
        SPACE_EXCL_DISP="$(format_size_kb "$EXCL_TOTAL_KB")"
    elif [[ "$EXCL_MEASURED" -eq 0 ]]; then
        SPACE_EXCL_DISP="${MSG_UI_SIZE_UNKNOWN}"
    else
        # Lower bound: truncated, never rounded up past the known total.
        SPACE_EXCL_DISP="≥ $(format_size_kb "$EXCL_TOTAL_KB" floor) (${MSG_UI_SIZE_PARTIAL} ${EXCL_UNKNOWN})"
    fi
    return 0
}

# KiB on disk for $1. Permission-denied children (typical of /private/var/folders)
# make BSD/GNU du exit non-zero even when a partial total was printed. Capture
# du independently so set -euo pipefail cannot abort report generation (#18, #55).
#
# With a second argument ("mark"), a non-zero du exit that still printed a size
# (unreadable children: the total is partial) appends "!" to the number so the
# size cache can tell a complete measurement from a lower bound (#44).
du_size_kb() {
    local raw="" rc=0 kb
    raw="$(du -sk -- "$1" 2>/dev/null)" || rc=$?
    [[ -z "$raw" ]] && return 0
    kb="$(awk '{print $1; exit}' <<EOF
${raw}
EOF
)"
    if [[ "$rc" -ne 0 && -n "${2:-}" && -n "$kb" ]]; then kb="${kb}!"; fi
    printf '%s\n' "$kb"
}

# Per-path disk sizes are computed once, while the path is processed, and reused
# by the end-of-run report so large trees are never walked twice (#45).
# DU_SIZES is a newline list of "<normalized path>\t<KiB>"; an empty KiB records
# a path whose size could not be read (placeholder "-"), not a missing entry.
DU_SIZES=""

# du runs unless TM_EXCLUSIONS_SKIP_DU=1 (report section and size column both off).
du_enabled() {
    [[ "${TM_EXCLUSIONS_SKIP_DU:-}" != "1" ]]
}

# Human-readable size from KiB (42K, 2.0M, 2.0G, 1.5T) — shared by the per-path
# column and the report so both format identically (#45).
#
# With "floor" as second argument the value is truncated (never rounded up) to
# one decimal: used for a lower bound ("≥ X") that must not exceed the known
# total (2047K -> 1.9M, not 2.0M). The unit is still promoted at 1024.
format_size_kb() {
    # Rounding mode: 1023.95 (not 1024) so a value that rounds to 1024.0 at one
    # decimal promotes to the next unit, never prints "1024.0M" (1048575K -> 1.0G).
    awk -v k="$1" -v floor="${2:-}" 'function fmt(x, u) {
            if (floor == "floor") { printf "%.1f%s", int(x * 10) / 10, u }
            else { printf "%.1f%s", x, u }
        }
        BEGIN {
        lim = (floor == "floor") ? 1024 : 1023.95
        if (k < 1024) { printf "%dK", k; exit }
        x = k / 1024.0
        if (x < lim) { fmt(x, "M"); exit }
        x = x / 1024.0
        if (x < lim) { fmt(x, "G"); exit }
        x = x / 1024.0
        fmt(x, "T")
    }'
}

# DU_SIZES lines are "<path>\t<KiB>[!]": the KiB never contains a tab, so each
# line splits at its LAST tab and a path may itself contain tabs (#44 review).
# A trailing "!" marks a partial measurement (du exited non-zero, e.g. on
# unreadable children). Paths containing a newline cannot be stored in this
# newline-delimited cache at all; callers skip them (see path_size_column).
#
# Record the KiB size of $1 (empty when unreadable). Overwrites an existing entry.
du_size_record() {
    local p="$1" kb="$2" line entry ek found=0 retained=""
    [[ -z "$p" ]] && return 0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        entry="${line%$'\t'*}"
        ek="${line##*$'\t'}"
        if [[ "$entry" = "$p" ]]; then found=1; ek="$kb"; fi
        retained="${retained}${entry}"$'\t'"${ek}"$'\n'
    done <<EOF
${DU_SIZES}
EOF
    if [[ "$found" -eq 0 ]]; then
        retained="${retained}${p}"$'\t'"${kb}"$'\n'
    fi
    DU_SIZES="$retained"
    return 0
}

# Echo the raw recorded value of $1 (may end in "!"); returns 1 when absent.
du_size_lookup_raw() {
    local p="$1" line entry kb
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        entry="${line%$'\t'*}"
        kb="${line##*$'\t'}"
        if [[ "$entry" = "$p" ]]; then
            printf '%s' "$kb"
            return 0
        fi
    done <<EOF
${DU_SIZES}
EOF
    return 1
}

# Echo the recorded KiB of $1 (partial marker stripped, so partial sizes keep
# showing as before, #55); returns 1 when $1 has no recorded entry.
du_size_lookup() {
    local raw
    raw="$(du_size_lookup_raw "$1")" || return 1
    printf '%s' "${raw%!}"
}

# True when the recorded size of $1 is only a lower bound (du exited non-zero).
du_size_is_partial() {
    local raw
    raw="$(du_size_lookup_raw "$1")" || return 1
    [[ "$raw" = *'!' ]]
}

# Cumulative disk usage (KiB) over the deduped DU_PATHS set, reusing recorded
# sizes; only unrecorded paths fall back to a fresh du (#45). This is the single
# source for both the report total and the interactive summary: paths that no
# longer exist at total time are skipped, exactly like the report's per-path
# lines, so the two can never diverge (CodeRabbit review on #77).
du_total_kb() {
    local p kb total=0
    while IFS= read -r p; do
        [[ -z "$p" || ! -e "$p" ]] && continue
        if ! kb="$(du_size_lookup "$p")"; then
            kb="$(du_size_kb "$p")"
        fi
        case "$kb" in
            ''|*[!0-9]*) continue ;;
        esac
        total=$((total + kb))
    done <<EOF
${DU_PATHS}
EOF
    printf '%s' "$total"
    return 0
}

# Sets PATH_SIZE_COL to the formatted size of $1 for the per-path status column:
# "-" when the path is absent or its size cannot be read (never a failure), ""
# when du is disabled (#45). Not meant to be captured with $() — it records the
# KiB size in DU_SIZES as a side effect, which a subshell would discard.
PATH_SIZE_COL=""
# Normalized form of the last path measured (the cache key); read by excl_track_path.
PATH_SIZE_NP=""
# KiB of that path when its measurement is complete, "" when unreadable or partial
# (du exited non-zero); read by excl_track_path so the space figure needs no
# second lookup in the size cache.
PATH_SIZE_KB=""
path_size_column() {
    PATH_SIZE_COL=""
    PATH_SIZE_NP=""
    PATH_SIZE_KB=""
    du_enabled || return 0
    local p="$1" np="" szk=""
    # A name that cannot be measured safely (newline, see size_path_unsafe) is
    # unmeasured: no du at all (#44 review).
    if [[ "$SIZE_UNSAFE_NOW" -eq 1 ]]; then
        PATH_SIZE_COL="-"
        return 0
    fi
    if [[ -n "$p" && -e "$p" ]]; then
        if ! np="$(normalize_path "$p")"; then np="$p"; fi
        PATH_SIZE_NP="$np"
        # Consult the cache before measuring: a repeated rule (same path twice)
        # must not walk the same tree again (#45).
        if ! szk="$(du_size_lookup "$np")"; then
            # "mark": remember a partial (du exited non-zero) measurement.
            szk="$(du_size_kb "$np" mark)"
            du_size_record "$np" "$szk"
            case "$szk" in
                *'!') szk="${szk%!}" ;;
                *) PATH_SIZE_KB="$szk" ;;
            esac
        elif ! du_size_is_partial "$np"; then
            PATH_SIZE_KB="$szk"
        fi
        case "$PATH_SIZE_KB" in
            ''|*[!0-9]*) PATH_SIZE_KB="" ;;
        esac
        case "$szk" in
            ''|*[!0-9]*) PATH_SIZE_COL="-" ;;
            *) PATH_SIZE_COL="$(format_size_kb "$szk")" ;;
        esac
    else
        PATH_SIZE_COL="-"
    fi
    return 0
}

# "<size right-aligned in 8 cells>  <path>" when a size column is available,
# else the plain path — keeps every status line's path column aligned (#45).
path_suffix() {
    local col="$1" p="$2"
    if [[ -n "$col" ]]; then
        printf '%8s  %s' "$col" "$p"
    else
        printf '%s' "$p"
    fi
}

# True if path is $HOME or under it (normalized, no trailing slash ambiguity)
path_under_home() {
    local p="$1" h="${HOME%/}"
    case "${p%/}" in
        "$h"|"$h/"*) return 0 ;;
    esac
    # macOS exposes /var through /private/var; normalized keep paths use the latter.
    p="$(normalize_path "$p")" || return 1
    h="$(normalize_path "$HOME")" || return 1
    path_under "$p" "$h"

}

sudo_keepalive_stop() {
    if [[ -n "${SUDO_KEEPALIVE_PID}" ]] && kill -0 "${SUDO_KEEPALIVE_PID}" 2>/dev/null; then
        kill "${SUDO_KEEPALIVE_PID}" 2>/dev/null || true
    fi
    SUDO_KEEPALIVE_PID=""
}

sudo_keepalive_start() {
    [[ "${HAS_TMUTIL}" -eq 0 ]] && return 0
    [[ -n "${SUDO_KEEPALIVE_PID}" ]] && return 0
    (
        while true; do
            sleep 55
            if sudo -n true 2>/dev/null; then
                sudo -n -v 2>/dev/null || true
            fi
        done
    ) &
    SUDO_KEEPALIVE_PID=$!
}

register_tmp_file() {
    local f="$1"
    [[ -z "$f" ]] && return 0
    if [[ -z "${TMP_FILES}" ]]; then
        TMP_FILES="$f"
    else
        TMP_FILES="${TMP_FILES}
$f"
    fi
}

# Every temporary file lives in ONE private directory created on first use, so
# a signal can never strand a loose tm_exc_* file in TMPDIR (#92). The window
# between `mktemp -d` and the assignment of TMP_DIR (the one thing the cleanup
# removes) is never without a handler: INT/TERM/HUP switch atomically from
# on_signal to a recorder (TMP_PENDING_SIG), the mktemp child ignores them (so a
# terminal Ctrl-C cannot kill it half-way), then the caller's own handlers are
# put back and the recorded signal is replayed to them (cleanup, exit 128+n).
# Files inside the directory get fixed names and go with it. A TMPDIR holding a
# control character (newline) falls back to /tmp, TMPDIR is resolved once to its
# physical path, and only the exact path returned by mktemp, with the expected
# name, is ever kept or removed.
TMP_PENDING_SIG=""
ensure_tmp_dir() {
    [[ -n "${TMP_DIR}" ]] && return 0
    local base="${TMPDIR:-/tmp}" cdir="" phys="" d="" s saved_int saved_term saved_hup
    case "$base" in *[[:cntrl:]]*) base=/tmp ;; esac
    # Resolve TMPDIR once to its physical path: if it is a symbolic link that is
    # retargeted while mktemp runs, the directory is still found (and removed)
    # where it was really created.
    # The sentinel keeps $(...) from eating trailing newlines of the path; a
    # physical path holding a control character falls back to /tmp like a raw one.
    # CDPATH is emptied for this cd: with CDPATH=. a relative TMPDIR makes cd print
    # the resolved path itself, which would corrupt the captured output.
    # A relative path gets a ./ prefix: `cd -- -` still means $OLDPWD in Bash 5.
    cdir="$base"
    case "$cdir" in /*) ;; *) cdir="./$cdir" ;; esac
    if phys="$(CDPATH='' cd -P -- "$cdir" >/dev/null 2>&1 && pwd -P && printf x)"; then
        phys="${phys%x}"
        phys="${phys%$'\n'}"
        case "$phys" in *[[:cntrl:]]*) base=/tmp ;; *) base="$phys" ;; esac
    fi
    saved_int="$(trap -p INT)"
    saved_term="$(trap -p TERM)"
    saved_hup="$(trap -p HUP)"
    TMP_PENDING_SIG=""
    trap 'TMP_PENDING_SIG="${TMP_PENDING_SIG:-INT}"' INT
    trap 'TMP_PENDING_SIG="${TMP_PENDING_SIG:-TERM}"' TERM
    trap 'TMP_PENDING_SIG="${TMP_PENDING_SIG:-HUP}"' HUP
    d="$(trap '' INT TERM HUP; exec mktemp -d "${base}/tm_exc_work.XXXXXX" 2>/dev/null)" || d=""
    case "$d" in
        "${base}"/tm_exc_work.??????)
            case "$d" in
                *[[:cntrl:]]*) ;;
                *) if [[ -d "$d" && ! -L "$d" ]]; then TMP_DIR="$d"; fi ;;
            esac
            ;;
    esac
    if [[ -z "${TMP_DIR}" && -n "$d" && -d "$d" ]]; then rmdir -- "$d" 2>/dev/null || true; fi
    if [[ -n "$saved_int" ]]; then eval "$saved_int"; else trap - INT; fi
    if [[ -n "$saved_term" ]]; then eval "$saved_term"; else trap - TERM; fi
    if [[ -n "$saved_hup" ]]; then eval "$saved_hup"; else trap - HUP; fi
    if [[ -n "${TMP_PENDING_SIG}" ]]; then
        s="${TMP_PENDING_SIG}"
        TMP_PENDING_SIG=""
        kill -s "$s" "$$"
    fi
    [[ -n "${TMP_DIR}" ]]
}

# make_tmp_file <var> <name>: create an empty temporary file <name> in the work
# directory and store its path in <var>. Never call it in a command
# substitution: the directory must be created in the main shell. Fails when the
# directory or the file cannot be created.
make_tmp_file() {
    ensure_tmp_dir || return 1
    : > "${TMP_DIR}/$2" || return 1
    printf -v "$1" '%s' "${TMP_DIR}/$2"
}

cleanup_tmp_files() {
    if [[ -n "${TMP_FILES}" ]]; then
        local f
        while IFS= read -r f; do
            if [[ -n "$f" && -e "$f" ]]; then
                rm -f "$f" 2>/dev/null || true
            fi
        done <<EOF
${TMP_FILES}
EOF
        TMP_FILES=""
    fi
    # The private work directory (see ensure_tmp_dir): only the exact name it
    # was given, never a path split or built from TMPDIR.
    if [[ -n "${TMP_DIR:-}" ]]; then
        case "${TMP_DIR}" in
            *[[:cntrl:]]*) ;;
            */tm_exc_work.??????)
                if [[ -d "${TMP_DIR}" && ! -L "${TMP_DIR}" ]]; then
                    rm -rf -- "${TMP_DIR}" 2>/dev/null || true
                fi
                ;;
        esac
        TMP_DIR=""
    fi
}

cleanup() {
    clear_progress
    sudo_keepalive_stop
    cleanup_tmp_files
}

on_signal() {
    local sig="$1"
    cleanup
    trap - "$sig" EXIT
    kill -s "$sig" "$$"
}

# Refresh sudo timestamp once before privileged tmutil calls (TTY may prompt)
sudo_prepare_for_path() {
    local path="$1"
    if path_under_home "$path"; then
        return 0
    fi
    if [[ "${HAS_TMUTIL}" -eq 0 ]]; then
        return 0
    fi
    sudo_keepalive_start
    sudo -v 2>/dev/null || true
}

# Paths outside $HOME need sudo + tmutil -p; skip when non-interactive and no cached sudo (CI / smoke).
privileged_tmutil_ok() {
    local path="$1"
    path_under_home "$path" && return 0
    if [[ "${HAS_TMUTIL}" -eq 0 ]]; then
        return 0
    fi
    if sudo -n true 2>/dev/null; then
        return 0
    fi
    if [[ -t 0 ]]; then
        return 0
    fi
    return 1
}

# True when we would need sudo+tmutil for this path but cannot (non-interactive smoke/CI).
cannot_privileged_tmutil() {
    local path="$1"
    [[ "${HAS_TMUTIL}" -eq 1 ]] || return 1
    path_under_home "$path" && return 1
    privileged_tmutil_ok "$path" && return 1
    return 0
}

# Dynamic pattern matches: drop obvious false positives (legacy 2.x parity)
pattern_match_allowed() {
    local pat="$1"
    local dir="$2"
    local parent
    parent="$(dirname "$dir")"

    case "$pat" in
        target)
            if [[ -f "${parent}/Cargo.toml" \
                || -f "${parent}/pom.xml" \
                || -f "${parent}/build.gradle" \
                || -f "${parent}/build.gradle.kts" ]]; then
                return 0
            fi
            return 1
            ;;
        worktrees)
            case "$dir" in
                */.git/worktrees|*/.git/worktrees/*|*/.cursor/*) return 0 ;;
            esac
            if [[ -f "${parent}/HEAD" && ( -d "${parent}/worktrees" || -f "${parent}/commondir" ) ]]; then
                return 0
            fi
            return 1
            ;;
        site-packages)
            # Allow only the canonical Python install shape:
            # .../lib/pythonX.Y/site-packages (pip's output dir, always
            # regenerable). Common matches: ~/.<tool>/lib/python3.14/...,
            # /opt/homebrew/lib/python3.X/..., ~/.pyenv/versions/.../lib/...
            # The lib/ grandparent guard rejects bare <tool>/pythonX/site-packages
            # layouts that would match by parent name alone.
            local grandparent
            grandparent="${parent%/*}"
            case "${parent##*/}" in
                python[0-9]*)
                    case "${grandparent##*/}" in
                        lib) return 0 ;;
                    esac
                    ;;
            esac
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

resolve_default_conf() {
    local script_dir candidate

    if [[ -n "${TM_EXCLUSIONS_DEFAULT_CONF:-}" ]]; then
        echo "${TM_EXCLUSIONS_DEFAULT_CONF}"
        return 0
    fi

    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    for candidate in \
        "${script_dir}/config/default.conf" \
        "${script_dir}/../share/tm-exclusions/default.conf" \
        "/usr/local/share/tm-exclusions/default.conf" \
        "/opt/homebrew/share/tm-exclusions/default.conf" \
        "/usr/share/tm-exclusions/default.conf"
    do
        if [[ -f "${candidate}" ]]; then
            echo "${candidate}"
            return 0
        fi
    done

    echo "${script_dir}/config/default.conf"
}

# Detect language from environment or override
detect_language() {
    local loc=""

    if [[ -n "${LANG_OVERRIDE}" ]]; then
        case "${LANG_OVERRIDE}" in
            en|fr) CURRENT_LANG="${LANG_OVERRIDE}" ;;
            *) CURRENT_LANG="en" ;;
        esac
    else
        if [[ -n "${LC_ALL:-}" ]]; then
            loc="${LC_ALL}"
        elif [[ -n "${LC_MESSAGES:-}" ]]; then
            loc="${LC_MESSAGES}"
        elif [[ -n "${LC_CTYPE:-}" ]]; then
            loc="${LC_CTYPE}"
        elif [[ -n "${LANG:-}" ]]; then
            loc="${LANG}"
        fi
        if [[ "${loc}" == fr* ]]; then
            CURRENT_LANG="fr"
        else
            CURRENT_LANG="en"
        fi
    fi

    load_i18n "${CURRENT_LANG}"
}

# Check if running on macOS with tmutil available
HAS_TMUTIL=0
check_environment() {
    if [[ "$(uname -s 2>/dev/null)" != "Darwin" ]]; then
        log_error "${MSG_ERROR_NOT_MACOS}"
    fi
    if command -v tmutil >/dev/null 2>&1; then
        HAS_TMUTIL=1
    else
        log_error "${MSG_ERROR_NO_TMUTIL}"
    fi
}

# ---------------------------------------------------------------------------
# tmutil wrappers (mockable for testing / non-macOS)
# ---------------------------------------------------------------------------
tm_is_excluded() {
    local path="$1"
    if [[ "${HAS_TMUTIL}" -eq 1 ]]; then
        local result=""
        if path_under_home "$path"; then
            result="$(tmutil isexcluded "$path" 2>/dev/null)" || return 2
        else
            if ! privileged_tmutil_ok "$path"; then
                return 2
            fi
            sudo_prepare_for_path "$path"
            result="$(sudo tmutil isexcluded "$path" 2>/dev/null)" || return 2
        fi
        case "$result" in
            *"[Excluded]"*) return 0 ;;
            *"[Included]"*) return 1 ;;
            *) return 2 ;;
        esac
    else
        # Simulation: never excluded
        return 1
    fi
}

tm_add_exclusion() {
    local path="$1"
    if [[ "${HAS_TMUTIL}" -eq 1 ]]; then
        if path_under_home "$path"; then
            tmutil addexclusion "$path" 2>/dev/null
        else
            if ! privileged_tmutil_ok "$path"; then
                return 1
            fi
            sudo_prepare_for_path "$path"
            sudo tmutil addexclusion -p "$path" 2>/dev/null
        fi
    else
        return 0
    fi
}

tm_remove_exclusion() {
    local path="$1"
    if [[ "${HAS_TMUTIL}" -eq 1 ]]; then
        if path_under_home "$path"; then
            tmutil removeexclusion "$path" 2>/dev/null
        else
            if ! privileged_tmutil_ok "$path"; then
                return 1
            fi
            sudo_prepare_for_path "$path"
            sudo tmutil removeexclusion -p "$path" 2>/dev/null
        fi
    else
        return 0
    fi
}

# ---------------------------------------------------------------------------
# Config loading
# ---------------------------------------------------------------------------
# Append one path to CONF_PATHS (newline-delimited).
append_conf_path() {
    local p="$1"
    [[ -z "$p" ]] && return 0
    CONF_RULES="${CONF_RULES}path|${p}|${RULE_CATEGORY}|${RULE_CONTEXT}
"
    if [[ -z "${CONF_PATHS}" ]]; then
        CONF_PATHS="${p}"
    else
        CONF_PATHS="${CONF_PATHS}
${p}"
    fi
}

# Append a path-rule target. Glob metacharacters (* ? [) are expanded against
# the filesystem at load time so versioned folders such as
# JetBrains/*/plugins resolve to concrete directories. Unmatched globs are
# dropped — a literal '*' must never be passed to tmutil.
append_conf_path_target() {
    local target="$1"
    case "$target" in
        *'*'*|*'?'*|*'['*)
            local glob_out glob_match
            glob_out="$(compgen -G "$target" || true)"
            [[ -z "$glob_out" ]] && return 0
            while IFS= read -r glob_match; do
                [[ -z "$glob_match" ]] && continue
                append_conf_path "$glob_match"
            done <<EOF
${glob_out}
EOF
            ;;
        *)
            append_conf_path "$target"
            ;;
    esac
}

# Category name from a `#@<Name>` marker line: surrounding whitespace is trimmed
# and control characters / `|` (the CONF_RULES delimiter) are neutralized.
parse_category_marker() {
    local name="${1#\#@}"
    name="${name//[[:cntrl:]]/ }"
    name="${name//|//}"
    name="${name#"${name%%[![:space:]]*}"}"
    name="${name%"${name##*[![:space:]]}"}"
    printf '%s' "$name"
}

parse_config_file() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        return 0
    fi

    # Each file starts in the default category: a `#@` section never leaks from
    # default.conf into custom.conf, so rules there are never mislabeled (#46).
    RULE_CATEGORY=""
    local line_num=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line_num=$((line_num + 1))
        # Skip empty lines and comments; `#@<Name>` starts a category section
        case "$line" in
            "#@"*) RULE_CATEGORY="$(parse_category_marker "$line")"; continue ;;
            ""|\#*) continue ;;
        esac

        # Parse type|target|reason
        local entry_type entry_target entry_reason
        entry_type="${line%%|*}"
        local rest="${line#*|}"
        entry_target="${rest%%|*}"
        # No third field (`setting|report_path`) must not reuse the key as the value.
        if [[ "$rest" != *'|'* ]]; then
            entry_reason=""
        else
            entry_reason="${rest#*|}"
        fi

        # Validate the raw target before expansion: a typo such as
        # `$HOMEE/VMs` or `~other` would otherwise expand into a real absolute
        # path and silently protect the wrong tree.
        # shellcheck disable=SC2088,SC2016
        case "$entry_target" in
            /*|\~|\~/*|\$HOME|\$HOME/*) ;;
            *)
                if [[ "$entry_type" = keep ]]; then
                    RULE_CONTEXT="${file}:${line_num} | ${entry_type}|${entry_target} | ${entry_reason}"
                    record_error "$MSG_INVALID_KEEP ${file}:${line_num}"
                    continue
                fi
                ;;
        esac

        # Expand ~ to $HOME
        case "$entry_target" in
            "~"*) entry_target="${HOME}${entry_target#\~}" ;;
        esac
        # Expand $HOME in targets (legacy default.conf style; one global replace)
        local home_token
        home_token="\$HOME"
        entry_target="${entry_target//${home_token}/$HOME}"

        RULE_CONTEXT="${file}:${line_num} | ${entry_type}|${entry_target} | ${entry_reason}"
        case "$entry_type" in
            keep)
                if [[ "$entry_target" != /* || "$entry_target" == *$'\t'* ]]; then
                    record_error "$MSG_INVALID_KEEP ${file}:${line_num}"
                    continue
                fi
                local keep_path
                if ! keep_path="$(normalize_path "$entry_target")"; then
                    record_error "$MSG_INVALID_KEEP ${file}:${line_num}"
                    continue
                fi
                CONF_KEEPS="${CONF_KEEPS}${keep_path}
"
                CONF_RULES="${CONF_RULES}keep|${keep_path}|${RULE_CATEGORY}|${RULE_CONTEXT}
"
                ;;
            path)
                append_conf_path_target "$entry_target"
                ;;
            pattern)
                CONF_RULES="${CONF_RULES}pattern|${entry_target}|${RULE_CATEGORY}|${RULE_CONTEXT}
"
                if [[ -z "${CONF_PATTERNS}" ]]; then
                    CONF_PATTERNS="${entry_target}"
                else
                    CONF_PATTERNS="${CONF_PATTERNS}
${entry_target}"
                fi
                ;;
            prune)
                if [[ -z "${CONF_PRUNES}" ]]; then
                    CONF_PRUNES="${entry_target}"
                else
                    CONF_PRUNES="${CONF_PRUNES}
${entry_target}"
                fi
                ;;
            setting)
                # Preferences (not Time Machine rules). Last occurrence wins.
                # Keys live in the target field; values in the reason field.
                case "$entry_target" in
                    report_path)
                        if [[ -z "$entry_reason" ]]; then
                            log_error "${MSG_ERROR_EMPTY_REPORT_PATH} ${file}:${line_num}"
                        else
                            case "$entry_reason" in
                                "~"*) entry_reason="${HOME}${entry_reason#\~}" ;;
                            esac
                            entry_reason="${entry_reason//${home_token}/$HOME}"
                            CONF_REPORT_PATH="$entry_reason"
                        fi
                        ;;
                    scan_images)
                        case "$entry_reason" in
                            true|1|yes) CONF_SCAN_IMAGES=1 ;;
                            false|0|no) CONF_SCAN_IMAGES=0 ;;
                            *) record_error "$MSG_INVALID_IMAGES ${file}:${line_num}" ;;
                        esac
                        ;;
                    desktop_report)
                        case "$entry_reason" in
                            true|1|yes)
                                CONF_DESKTOP_REPORT=1
                                ;;
                            false|0|no)
                                CONF_DESKTOP_REPORT=0
                                ;;
                            *)
                                log_error "${MSG_ERROR_INVALID_DESKTOP_REPORT} '${entry_reason}' at ${file}:${line_num} ${MSG_ERROR_INVALID_DESKTOP_REPORT_HINT}"
                                ;;
                        esac
                        ;;
                    *)
                        log_error "${MSG_ERROR_UNKNOWN_SETTING} '${entry_target}' at ${file}:${line_num}"
                        ;;
                esac
                ;;
            *)
                log_error "Warning: Unknown config entry type '${entry_type}' at ${file}:${line_num}"
                ;;
        esac
    done < "$file"
    RULE_CATEGORY=""
}

load_config() {
    CONF_PATHS=""
    CONF_PATTERNS=""
    CONF_PRUNES=""
    CONF_KEEPS=""
    CONF_RULES=""
    CONF_SCAN_IMAGES=0
    CONF_REPORT_PATH=""
    CONF_DESKTOP_REPORT=0

    # Load default config first
    parse_config_file "$(resolve_default_conf)"
    # Merge custom config (path/pattern/prune append; setting last-wins)
    parse_config_file "${CUSTOM_CONF}"
    # Extra config last: rules are additive; settings override earlier files.
    # Users point TM_EXCLUSIONS_EXTRA_CONF to an additional config file.
    if [[ -n "${TM_EXCLUSIONS_EXTRA_CONF:-}" ]]; then
        if [[ -f "${TM_EXCLUSIONS_EXTRA_CONF}" && -r "${TM_EXCLUSIONS_EXTRA_CONF}" ]]; then
            parse_config_file "${TM_EXCLUSIONS_EXTRA_CONF}"
        else
            log_error "Warning: TM_EXCLUSIONS_EXTRA_CONF is set but file is missing or unreadable: ${TM_EXCLUSIONS_EXTRA_CONF}"
        fi
    fi

    RULE_CONTEXT=""
    RULE_CATEGORY=""

    # Derive .bak / .old prune entries from every static path rule so that
    # shadow copies (e.g. ~/.bun.bak from a Bun reinstall) are silently skipped
    # during the dynamic scan without requiring explicit catalog entries.
    # Only path| entries are processed — pattern| and prune| are excluded.
    # Skipped in uninstall mode so prior exclusions under shadow trees can be cleaned up.
    if [[ "${MODE}" != "uninstall" ]]; then
        derive_bak_old_prunes
    fi
}

# For every static 'path' catalog entry P, append P.bak and P.old to
# CONF_PRUNES (if not already present).  These auto-derived prunes only
# affect is_pruned() / scan_dynamic_patterns(); apply_static_paths() is
# not changed — .bak/.old paths are never passed to tmutil addexclusion.
derive_bak_old_prunes() {
    [[ -z "${CONF_PATHS}" ]] && return 0
    local p clean_p suffix new_entries=""
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        clean_p="${p%/}"
        for suffix in .bak .old; do
            new_entries="${new_entries}${clean_p}${suffix}
"
        done
    done <<EOF
$(printf '%s\n' "${CONF_PATHS}")
EOF

    # Append and deduplicate once using awk (Bash 3.2 compatible)
    CONF_PRUNES=$(printf '%s\n%s' "${CONF_PRUNES}" "${new_entries}" | awk 'NF && !seen[$0]++')
}

# ---------------------------------------------------------------------------
# Config management commands
# ---------------------------------------------------------------------------
write_custom_config_if_absent() {
    if [[ -f "${CUSTOM_CONF}" ]]; then
        return 1
    fi
    cat > "${CUSTOM_CONF}" << 'CONF_EOF'
# tm-exclusions custom configuration
# Format: type|target|reason
# Types: path (static path), pattern (directory name for scan), prune (skip during scan)
#        keep (protect a path and descendants from exclusion)
#        setting (preferences: report_path, desktop_report, scan_images)
#
# Sections: a line starting with "#@" (e.g. "#@MyCategory") groups the rules
# below it under that name in console output and in the report. Rules before
# any marker are "Uncategorized"; rules added with --add are appended at the
# end of the file, so they join the last section.
#
# Examples:
# path|~/MyLargeDataset|Large dataset not needed in backup
# pattern|.myframework_cache|Framework cache directories
# prune|~/Archive|Skip dynamic matches in archive directory
# keep|~/VMs|Keep VM data in backups
# setting|scan_images|false
# setting|report_path|~/Documents/tm-exclusions-last.txt
# setting|desktop_report|true
CONF_EOF
    return 0
}

ensure_custom_conf_exists() {
    mkdir -p "${CUSTOM_CONF_DIR}" 2>/dev/null || true
    if write_custom_config_if_absent; then
        log_info "${MSG_CONFIG_AUTO_CREATED} ${CUSTOM_CONF}"
    fi
}

cmd_config_init() {
    if [[ -d "${CUSTOM_CONF_DIR}" ]]; then
        log_info "${MSG_CONFIG_EXISTS} ${CUSTOM_CONF_DIR}"
    else
        mkdir -p "${CUSTOM_CONF_DIR}"
        log_info "${MSG_CONFIG_CREATED} ${CUSTOM_CONF_DIR}"
    fi
    write_custom_config_if_absent || true
}

cmd_config_add() {
    local entry_type="$1"
    local entry_path="$2"
    local entry_reason="$3"

    case "${entry_type}" in
        path|pattern|prune|keep) ;;
        *)
            log_error "${MSG_ERROR_INVALID_TYPE}"
            exit 1
            ;;
    esac

    if [[ ! -f "${CUSTOM_CONF}" ]]; then
        log_error "${MSG_CONFIG_NO_FILE}"
        exit 1
    fi

    if [[ "$entry_path$entry_reason" == *$'\n'* || "$entry_path" == *'|'* || "$entry_path" == *$'\t'* ]]; then
        log_error "$MSG_INVALID_RULE"
        exit 1
    fi
    # Literal config placeholders are expanded when loading.
    # shellcheck disable=SC2088,SC2016
    if [[ "$entry_type" = keep && "$entry_path" != /* && "$entry_path" != '~' && "$entry_path" != '~/'* && "$entry_path" != '$HOME' && "$entry_path" != '$HOME/'* ]]; then
        log_error "$MSG_INVALID_KEEP"
        exit 1
    fi
    echo "${entry_type}|${entry_path}|${entry_reason}" >> "${CUSTOM_CONF}"
    log_info "${MSG_CONFIG_ADDED} ${entry_type}|${entry_path}|${entry_reason}"
}

cmd_config_list() {
    if [[ ! -f "${CUSTOM_CONF}" ]]; then
        log_error "${MSG_CONFIG_NO_FILE}"
        exit 1
    fi

    local found=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            ""|\#*) continue ;;
        esac
        echo "$line"
        found=1
    done < "${CUSTOM_CONF}"

    if [[ "${found}" -eq 0 ]]; then
        log_info "${MSG_CONFIG_EMPTY}"
    fi
}

cmd_config_edit() {
    if [[ ! -f "${CUSTOM_CONF}" ]]; then
        log_error "${MSG_CONFIG_NO_FILE}"
        exit 1
    fi

    local editor="${EDITOR:-vi}"
    local -a editor_cmd
    read -r -a editor_cmd <<< "${editor}"
    exec "${editor_cmd[@]}" "${CUSTOM_CONF}"
}

# ---------------------------------------------------------------------------
# Exclusion application
# ---------------------------------------------------------------------------
record_error() {
    TOTAL_ERRORS=$((TOTAL_ERRORS + 1))
    log_error "$*"
    add_report_line "ERROR $*"
}

record_blocked() {
    TOTAL_BLOCKED=$((TOTAL_BLOCKED + 1))
    TOTAL_ERRORS=$((TOTAL_ERRORS + 1))
    log_error "$*"
    add_report_line "BLOCKED $*"
}

set_rule_context() {
    local type target category context
    RULE_CONTEXT=""
    RULE_CATEGORY=""
    while IFS='|' read -r type target category context; do
        if [[ "$type" = "$1" && "$target" = "$2" ]]; then
            RULE_CONTEXT="$context"
            RULE_CATEGORY="$category"
            return 0
        fi
    done <<EOF
${CONF_RULES}
EOF
}

# Normalize dot components and existing symlink prefixes without requiring realpath.
normalize_path() {
    local path="$1" part normalized="" physical
    local -a parts
    IFS='/' read -r -a parts <<< "$path"
    for part in "${parts[@]}"; do
        case "$part" in
            ''|.) ;;
            ..) normalized="${normalized%/*}" ;;
            *) normalized="${normalized}/$part" ;;
        esac
        if [[ -d "${normalized:-/}" ]]; then
            physical="$(cd -P "${normalized:-/}" 2>/dev/null && pwd)" || return 1
            normalized="${physical%/}"
        fi
    done
    printf '%s\n' "${normalized:-/}"
}

# Reject both descendants and ancestors: excluding a parent would defeat keep.
keep_blocks() {
    [[ -n "$CONF_KEEPS" ]] || return 1
    local candidate entry normalized
    if ! candidate="$(normalize_path "$1")"; then
        record_error "$MSG_INVALID_KEEP $1"
        return 0
    fi
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        # Stored keeps may use symlink or `..` spellings; compare physical paths
        # so an alias cannot smuggle an exclusion past its protected target.
        normalized="$entry"
        if [[ -e "$entry" ]]; then
            normalized="$(normalize_path "$entry")" || normalized="$entry"
        fi
        if path_under "$candidate" "$normalized" || path_under "$normalized" "$candidate"; then
            return 0
        fi
    done <<EOF
${CONF_KEEPS}
EOF
    return 1
}

check_keeps() {
    local path status
    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        set_rule_context keep "$path"
        add_report_line "KEEP  $path"
        [[ -e "$path" ]] || continue
        if tm_is_excluded "$path"; then
            record_error "$MSG_KEEP_EXCLUDED $path"
        else
            status=$?
            if [[ "$status" -ne 1 ]]; then record_error "$MSG_CHECK_FAILED $path"; fi
        fi
    done <<EOF
${CONF_KEEPS}
EOF
    RULE_CONTEXT=""
    RULE_CATEGORY=""
}

# One decision path for static rules, dynamic matches and discovered paths.
process_path() {
    local path="$1" status size_col=""
    TOTAL_CHECKED=$((TOTAL_CHECKED + 1))
    if keep_blocks "$path"; then
        TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))
        add_report_line "KEEP  $path ($MSG_KEEP_SKIP)"
        return 0
    fi
    if [[ ! -e "$path" && ! ( "$MODE" = uninstall && "$FORCE" -eq 1 ) ]]; then
        TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))
        # Absent path: placeholder "-" in the size column, never a failure (#45).
        if du_enabled; then size_col="-"; fi
        log_path_result missing "$path" "  ${MSG_PATH_NOT_FOUND} $(path_suffix "$size_col" "$path")"
        add_report_line "SKIP  ${path} (not found)"
        return 0
    fi
    if cannot_privileged_tmutil "$path"; then
        record_blocked "$MSG_SKIP_PRIVILEGED $path"
        return 0
    fi
    local forced_missing=0
    if [[ ! -e "$path" && "$MODE" = uninstall && "$FORCE" -eq 1 ]]; then
        forced_missing=1
    fi
    if [[ "$forced_missing" -eq 0 ]]; then
        if tm_is_excluded "$path"; then status=0; else status=$?; fi
        if [[ "$status" -gt 1 ]]; then
            record_error "$MSG_CHECK_FAILED $path"
            return 0
        fi
    else
        # Forced removal of an already-deleted path has no exclusion status to
        # read; skipping the lookup still routes through tm_remove_exclusion so
        # leftover Time Machine records are cleaned and failures are reported.
        status=0
    fi
    # One decision per processed path (no memo): used by the three size helpers.
    SIZE_UNSAFE_NOW=0
    if size_path_unsafe "$path"; then SIZE_UNSAFE_NOW=1; fi
    du_track_path "$path"
    if [[ -z "$TIP_PATH" && -e "$path" ]]; then TIP_PATH="$path"; fi
    # Size computed once here and reused by the report; hidden when SKIP_DU=1.
    # path_size_column sets PATH_SIZE_COL (side effect) — never capture it with $().
    path_size_column "$path"
    size_col="$PATH_SIZE_COL"
    if [[ "$MODE" = uninstall ]]; then
        if [[ "$status" -eq 1 && "$FORCE" -eq 0 ]]; then
            TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))
            add_report_line "SKIP  $path (not excluded)"
        elif [[ "$DRY_RUN" -eq 1 ]]; then
            TOTAL_REMOVED=$((TOTAL_REMOVED + 1))
            log_path_result remove "$path" "  $MSG_DRY_RUN_PREFIX $MSG_REMOVING $(path_suffix "$size_col" "$path")"
            add_report_line "WOULD_REMOVE $path"
        elif tm_remove_exclusion "$path"; then
            TOTAL_REMOVED=$((TOTAL_REMOVED + 1))
            log_path_result remove "$path" "  $MSG_REMOVING $(path_suffix "$size_col" "$path")"
            add_report_line "REMOVE $path"
        else
            record_error "$MSG_REMOVE_FAILED $path"
        fi
    elif [[ "$status" -eq 0 ]]; then
        TOTAL_ALREADY=$((TOTAL_ALREADY + 1))
        log_path_result already "$path" "  $MSG_ALREADY $(path_suffix "$size_col" "$path")"
        add_report_line "OK    $path (already excluded)"
    elif [[ "$MODE" = report-only ]]; then
        TOTAL_EXCLUDED=$((TOTAL_EXCLUDED + 1))
        excl_track_path "$path"
        log_path_result need "$path" "  $MSG_REPORT_NEED_EXCLUSION $(path_suffix "$size_col" "$path")"
        add_report_line "NEED  $path (not excluded)"
    elif [[ "$DRY_RUN" -eq 1 ]]; then
        TOTAL_EXCLUDED=$((TOTAL_EXCLUDED + 1))
        excl_track_path "$path"
        log_path_result apply "$path" "  $MSG_DRY_RUN_PREFIX $MSG_APPLYING $(path_suffix "$size_col" "$path")"
        add_report_line "WOULD $path"
    elif tm_add_exclusion "$path"; then
        TOTAL_EXCLUDED=$((TOTAL_EXCLUDED + 1))
        excl_track_path "$path"
        log_path_result apply "$path" "  $MSG_APPLYING $(path_suffix "$size_col" "$path")"
        add_report_line "ADD   $path"
    else
        record_error "$MSG_ADD_FAILED $path"
    fi
}

# Retirement always removes, even when the current mode is apply.
remove_exclusion() {
    local MODE=uninstall
    process_path "$1"
}

# ---------------------------------------------------------------------------
# Scanning
# ---------------------------------------------------------------------------
is_pruned() {
    local check_path="$1"
    if [[ -z "${CONF_PRUNES}" ]]; then
        return 1
    fi

    local prune_entry
    while IFS= read -r prune_entry; do
        [[ -z "$prune_entry" ]] && continue
        # Check if check_path starts with prune_entry
        if [[ "$check_path" == "$prune_entry" || "$check_path" == "$prune_entry/"* ]]; then
            return 0
        fi
    done <<EOF
${CONF_PRUNES}
EOF
    return 1
}

# Returns 0 if $1 is the same as $2 or a descendant of $2.
# Pure string check — the quoted "$ancestor" expansion is treated literally
# inside the `case` pattern, so paths containing `*`, `?`, or `[…]` are
# matched as plain characters (no glob promotion).
# Trailing slashes are normalized so `/a/b` matches `/a/b/` as the same dir
# and `/a/b/c` is correctly recognized as a descendant of `/a/b/`.
path_under() {
    local descendant="${1%/}"
    local ancestor="${2%/}"
    [[ -z "$descendant" ]] && descendant="/"
    [[ -z "$ancestor" ]] && ancestor="/"
    [[ "$ancestor" = / ]] && return 0
    case "$descendant" in
        "$ancestor"|"$ancestor"/*) return 0 ;;
    esac
    return 1
}

# Returns 0 if $1 is covered by an entry in the kept-paths file ($2).
# An entry covers $1 when $1 == entry, or $1 lies under entry.
is_covered_by_kept() {
    local check="$1"
    local kept_file="$2"
    [[ -z "$kept_file" || ! -s "$kept_file" ]] && return 1
    local entry
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        path_under "$check" "$entry" && return 0
    done < "$kept_file"
    return 1
}

scan_dynamic_patterns() {
    ui_section "🔍" "${MSG_SCANNING}"

    if [[ -z "${CONF_PATTERNS}" ]]; then
        return 0
    fi

    # We scan from $HOME, respecting prune paths
    local scan_root="${HOME}"

    # Prefix-prune state: every path we decide to keep is appended here so that
    # subsequent candidates falling under it are skipped (issue #23).
    # Seed with CONF_PATHS so dynamic candidates under an already-known static
    # exclusion (e.g. ~/.npm covers ~/.npm/_npx/X/node_modules) are also pruned.
    local kept_file
    make_tmp_file kept_file kept
    if [[ -n "${CONF_PATHS}" ]]; then
        local static_seed
        while IFS= read -r static_seed; do
            [[ -z "$static_seed" ]] && continue
            if ! keep_blocks "$static_seed"; then printf '%s\n' "$static_seed" >> "$kept_file"; fi
        done <<EOF
${CONF_PATHS}
EOF
    fi

    # Collect all dynamic matches up-front (across all patterns) so we can sort
    # them globally — lexical sort puts ancestors before descendants because an
    # ancestor path is a strict string prefix of any descendant.
    local all_results
    make_tmp_file all_results all

    progress_start "${CONF_PATTERNS}"

    # Single consolidated traversal (#50): build ONE find expression with every
    # configured pattern OR-ed together — \( -name p1 -o -name p2 ... \) — so
    # the tree is walked once instead of once per pattern. The positional
    # parameters double as a Bash 3.2-safe argument vector. No -prune: the old
    # per-pattern walks kept descending into matched directories (nested
    # matches like node_modules/.pnpm/*/node_modules are required, notably in
    # uninstall mode), so the traversal must visit the exact same set.
    set --
    local pattern_name
    while IFS= read -r pattern_name; do
        [[ -z "$pattern_name" ]] && continue
        if [[ "$#" -eq 0 ]]; then
            set -- "$scan_root" -maxdepth 6 -type d '(' -name "$pattern_name"
        else
            set -- "$@" -o -name "$pattern_name"
        fi
    done <<EOF
${CONF_PATTERNS}
EOF

    local tmp_scan
    make_tmp_file tmp_scan scan
    if [[ "$#" -gt 0 ]]; then
        set -- "$@" ')'
        if ! find "$@" > "$tmp_scan" 2>/dev/null; then
            # One traversal covers every pattern; on failure, report once per
            # pattern exactly like the old per-pattern loop did.
            RULE_CONTEXT=""
            RULE_CATEGORY=""
            local err_pattern
            while IFS= read -r err_pattern; do
                [[ -z "$err_pattern" ]] && continue
                record_error "$MSG_SCAN_FAILED $scan_root ($err_pattern)"
            done <<EOF
${CONF_PATTERNS}
EOF
        fi
    fi

    # Tag each discovered directory with every configured pattern whose glob
    # matches its basename — the same (dir, pattern) pairs the per-pattern
    # `find -name <pattern>` calls produced, so pattern_match_allowed can
    # re-check later. Tab-separated; pattern names never contain tabs in our
    # config schema. A `case` pattern is required here, not `[[ == ]]`: on
    # Bash 3.2 `[[ == ]]` interprets extended globs (+(…), @(…), !(…), …) even
    # with extglob off, which would diverge from `find -name` (e.g. a literal
    # `+(cache)` directory). `case` only honors them when extglob is on, so
    # force extglob off around the loop and restore the initial state after.
    local extglob_was_on=0
    if shopt -q extglob; then extglob_was_on=1; fi
    shopt -u extglob
    local found_dir base_name
    while IFS= read -r found_dir; do
        [[ -z "$found_dir" ]] && continue
        base_name="${found_dir##*/}"
        while IFS= read -r pattern_name; do
            [[ -z "$pattern_name" ]] && continue
            # shellcheck disable=SC2254
            case "$base_name" in
                $pattern_name)
                    printf '%s\t%s\n' "$found_dir" "$pattern_name" >> "$all_results"
                    ;;
            esac
        done <<EOF
${CONF_PATTERNS}
EOF
    done < "$tmp_scan"
    if [[ "$extglob_was_on" -eq 1 ]]; then shopt -s extglob; fi
    rm -f "$tmp_scan"

    # Keep the progress-bar contract: one step per configured pattern.
    while IFS= read -r pattern_name; do
        [[ -z "$pattern_name" ]] && continue
        progress_step
    done <<EOF
${CONF_PATTERNS}
EOF

    # Sort by path so that a parent directory precedes its descendants and is
    # therefore kept first; descendants are then dropped by is_covered_by_kept.
    local sorted_results
    make_tmp_file sorted_results sorted
    LC_ALL=C sort -t$'\t' -k1,1 "$all_results" > "$sorted_results"
    rm -f "$all_results"

    local line found_dir matched_pattern
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        found_dir="${line%%$'\t'*}"
        matched_pattern="${line#*$'\t'}"

        if ! pattern_match_allowed "$matched_pattern" "$found_dir"; then
            continue
        fi

        set_rule_context pattern "$matched_pattern"

        # Skip if a config-level prune zone covers this path.
        if is_pruned "$found_dir"; then
            log_path_result prune "$found_dir" "  ${MSG_PRUNE_SKIP} ${found_dir}"
            add_report_line "SKIP  $found_dir ($MSG_PRUNE_SKIP)"
            continue
        fi

        if keep_blocks "$found_dir"; then
            process_path "$found_dir"
            continue
        fi

        # Skip if a previously-kept path (static or earlier dynamic) already
        # covers this one — prevents the redundant child-of-node_modules storm.
        # Bypassed in uninstall mode: each previously-added child exclusion
        # must be removed individually, otherwise descendants of an excluded
        # parent would be left behind in tmutil's exclusion list.
        if [[ "${MODE}" != "uninstall" ]] && is_covered_by_kept "$found_dir" "$kept_file"; then
            continue
        fi

        # Record before applying so later siblings/descendants in the same scan
        # see this path as "already kept". Skipped in uninstall mode so that no
        # descendant is suppressed.
        if [[ "${MODE}" != "uninstall" ]]; then
            printf '%s\n' "$found_dir" >> "$kept_file"
        fi

        process_path "$found_dir"
    done < "$sorted_results"

    flush_path_results
    rm -f "$sorted_results" "$kept_file"
}

apply_static_paths() {
    ui_section "📁" "${MSG_STATIC}"

    if [[ -z "${CONF_PATHS}" ]]; then
        return 0
    fi

    progress_start "${CONF_PATHS}"
    local static_path
    while IFS= read -r static_path; do
        [[ -z "$static_path" ]] && continue

        set_rule_context path "$static_path"
        process_path "$static_path"
        progress_step
    done <<EOF
${CONF_PATHS}
EOF
    flush_path_results
}

# Paths previously shipped as path| rules that the catalog no longer excludes.
# Apply / dry-run / uninstall drop them from tmutil when still present so an
# upgrade does not keep the old parent exclusion forever. Silent when the
# path is not currently excluded (simulation mode, fresh install, already migrated).
migrate_retired_exclusions() {
    local retired_path
    while IFS= read -r retired_path; do
        [[ -z "$retired_path" ]] && continue
        if [[ ! -e "$retired_path" ]] && [[ "${FORCE}" -eq 0 ]]; then
            continue
        fi
        if cannot_privileged_tmutil "$retired_path"; then
            continue
        fi
        if tm_is_excluded "$retired_path"; then :; else
            local status=$?
            if [[ "$status" -gt 1 ]]; then
                record_error "$MSG_CHECK_FAILED $retired_path"
                continue
            fi
            [[ "$FORCE" -eq 0 ]] && continue
        fi
        RULE_CONTEXT="$MSG_RETIRED_EXCLUSION"
        RULE_CATEGORY=""
        log_info "  ${MSG_RETIRED_EXCLUSION} ${retired_path}"
        remove_exclusion "$retired_path"
    done <<EOF
${HOME}/Library/Developer/CoreSimulator
EOF
}

# Append one path to EXTRA_PATHS if not already listed (Bash 3.2 — no associative arrays)
extra_paths_append() {
    local x="$1"
    [[ -z "$x" ]] && return 0
    if [[ -n "${EXTRA_PATHS}" ]] && printf '%s\n' "${EXTRA_PATHS}" | grep -Fqx "$x" 2>/dev/null; then
        return 0
    fi
    if [[ -z "${EXTRA_PATHS}" ]]; then
        EXTRA_PATHS="$x"
    else
        EXTRA_PATHS="${EXTRA_PATHS}
$x"
    fi
}

collect_post_scan_paths() {
    EXTRA_PATHS=""
    RULE_CONTEXT=""
    RULE_CATEGORY=""
    local line tmp
    local SCAN_COLUMNS=80
    if [[ "${UI}" -eq 1 ]]; then
        SCAN_COLUMNS="$(tput cols 2>/dev/null || printf '80')"
        case "$SCAN_COLUMNS" in
            ''|*[!0-9]*) SCAN_COLUMNS=80 ;;
        esac
        show_scan_path "$MSG_UI_BREW"
    fi

    if command -v brew >/dev/null 2>&1; then
        line="$(brew --cache 2>/dev/null)" || line=""
        if [[ -n "$line" && -e "$line" ]]; then
            extra_paths_append "$line"
        fi
    fi

    if [[ "$CONF_SCAN_IMAGES" -eq 0 ]]; then clear_progress; return 0; fi
    make_tmp_file tmp disk
    # Stream directories and matching images from the same walk, NUL-delimited.
    # VM/disk bundle directories (sparsebundle, UTM, VMware, Parallels) are
    # candidates as a whole, whatever their size, and their contents stay pruned:
    # multi-part disks inside never fall under the size gate. Flat image files are
    # size-gated. A .vbox file is a candidate itself; when it sits in a folder
    # named after it (VirtualBox's <name>/<name>.vbox layout) that folder holds the
    # VM's disks and becomes the candidate instead, unless it is $HOME. Cloud-synced
    # trees (iCloud, File Provider CloudStorage) are pruned so nothing is downloaded.
    # --uninstall walks into UTM/VMware/Parallels bundles as before bundle support,
    # so a disk an older version excluded on its own is still found.
    local -a prune_names=(-name '*.sparsebundle')
    if [[ "$MODE" != uninstall ]]; then
        prune_names+=(-o -name '*.utm' -o -name '*.vmwarevm' -o -name '*.parallels' -o -name '*.pvm')
    fi
    show_scan_path "$HOME"
    if ! find "$HOME" \( -path '*/Mobile Documents/*' -o -path '*/Library/Mobile Documents/*' \
            -o -path '*/Library/CloudStorage/*' \) -prune -o \
        \( -type d -print0 \( \( "${prune_names[@]}" \) -prune \) \) -o \
        \( -type f \( -name '*.vmdk' -o -name '*.qcow2' -o -name '*.raw' -o -name '*.img' \
            -o -name '*.iso' -o -name '*.ova' \) -size +512M -print0 \) -o \
        \( -type f -name '*.vbox' -print0 \) \
        2>/dev/null | {
            local candidate vbox_dir home_dir="$HOME"
            while [[ "$home_dir" = */ ]]; do home_dir="${home_dir%/}"; done
            while IFS= read -r -d '' candidate; do
                # The find stream is NUL-delimited but the candidate batch file is
                # newline-delimited (Bash 3.2); a path containing a newline would
                # be split into bogus entries, so reject it explicitly.
                if [[ "$candidate" = *$'\n'* ]]; then
                    record_error "$MSG_SCAN_NEWLINE_PATH"
                    continue
                fi
                if [[ "$candidate" = *.vbox && -f "$candidate" ]]; then
                    vbox_dir="${candidate%/*}"
                    while [[ "$vbox_dir" = */ ]]; do vbox_dir="${vbox_dir%/}"; done
                    if [[ -n "$vbox_dir" && "$vbox_dir" != "$home_dir" \
                        && "${vbox_dir##*/}.vbox" = "${candidate##*/}" ]]; then
                        # Uninstall also offers the file: it may be excluded on its own.
                        [[ "$MODE" = uninstall ]] && printf '%s/\n' "$candidate" >> "$tmp"
                        candidate="$vbox_dir"
                    fi
                elif [[ -d "$candidate" ]]; then
                    show_scan_path "$candidate"
                    case "$candidate" in
                        *.sparsebundle|*.utm|*.vmwarevm|*.parallels|*.pvm) ;;
                        *) continue ;;
                    esac
                fi
                # Trailing slash: sorted, a candidate is followed by its descendants.
                printf '%s/\n' "$candidate" >> "$tmp"
            done
        }; then
        record_error "$MSG_SCAN_FAILED $HOME"
    fi
    clear_progress
    # Cap after dedup: sort -u drops exact duplicates and puts each candidate right
    # before its descendants, which one pass then drops as already covered, unless
    # the ancestor is protected by keep (then it is not excluded and they stay).
    # Uninstall keeps descendants and uses a higher cap (it only removes exclusions):
    # an older version may have excluded only the disk, or a disk past the 50th slot.
    # The cap stays finite: per-path processing cost grows quadratically.
    if ! LC_ALL=C sort -u -o "$tmp" "$tmp"; then
        record_error "$MSG_SCAN_FAILED $HOME"
    fi
    local kept=0 prev="" prev_checked=0 prev_blocked=0 cap="$IMAGE_CAP_APPLY"
    [[ "$MODE" = uninstall ]] && cap="$IMAGE_CAP_UNINSTALL"
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        if [[ "$MODE" != uninstall && -n "$prev" && "$line" = "$prev"* ]]; then
            if [[ "$prev_checked" -eq 0 ]]; then
                prev_checked=1
                if keep_blocks "${prev%/}"; then prev_blocked=1; fi
            fi
            [[ "$prev_blocked" -eq 0 ]] && continue
        fi
        prev="$line" prev_checked=0 prev_blocked=0
        kept=$((kept + 1))
        if [[ "$kept" -le "$cap" ]]; then extra_paths_append "${line%/}"; fi
    done < "$tmp"
    if [[ "$kept" -gt "$cap" ]]; then
        if [[ "$MODE" = uninstall ]]; then
            add_report_line "LIMIT $MSG_IMAGE_LIMIT_UNINSTALL"
        else
            add_report_line "LIMIT $MSG_IMAGE_LIMIT"
        fi
    fi
    rm -f "$tmp"
}

apply_extra_paths() {
    if [[ -z "${EXTRA_PATHS}" ]]; then
        return 0
    fi

    ui_section "📦" "${MSG_EXTRA_PATHS}"

    progress_start "${EXTRA_PATHS}"
    local extra_path
    while IFS= read -r extra_path; do
        [[ -z "$extra_path" ]] && continue

        RULE_CONTEXT="$MSG_DISCOVERED | $extra_path"
        RULE_CATEGORY=""
        process_path "$extra_path"
        progress_step
    done <<EOF
${EXTRA_PATHS}
EOF
    flush_path_results
}

# ---------------------------------------------------------------------------
# Report destination (CLI > env > config setting > built-in default)
# ---------------------------------------------------------------------------
# There is no CLI flag for the primary report file path; TM_EXCLUSIONS_REPORT
# is the env-level override. --desktop-report is the CLI flag for the Desktop copy.
resolve_report_out_path() {
    if [[ -n "${TM_EXCLUSIONS_REPORT:-}" ]]; then
        printf '%s' "${TM_EXCLUSIONS_REPORT}"
        return
    fi
    if [[ -n "${CONF_REPORT_PATH}" ]]; then
        printf '%s' "${CONF_REPORT_PATH}"
        return
    fi
    printf '%s' "${REPORT_FILE}"
}

desktop_report_enabled() {
    # CLI flag always enables (there is no --no-desktop-report).
    if [[ "${DESKTOP_REPORT}" -eq 1 ]]; then
        return 0
    fi
    # When the env var is set (even to 0), it overrides config.
    if [[ -n "${TM_EXCLUSIONS_REPORT_DESKTOP+x}" ]]; then
        if [[ "${TM_EXCLUSIONS_REPORT_DESKTOP}" = "1" ]]; then
            return 0
        fi
        return 1
    fi
    if [[ "${CONF_DESKTOP_REPORT}" -eq 1 ]]; then
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# Inventory (informational)
# ---------------------------------------------------------------------------
# Width used to wrap the inventory lists: terminal width when the caller
# reports stdout as a terminal ($1 = 1 — evaluated outside any $(...), since
# inside a command substitution [[ -t 1 ]] is always false), otherwise the
# standard report width.
report_columns() {
    local cols=80
    if [[ "${1:-0}" = "1" ]]; then
        cols="$(tput cols 2>/dev/null || printf '80')"
    fi
    case "$cols" in
        ''|*[!0-9]*) cols=80 ;;
    esac
    if [[ "$cols" -lt 20 ]]; then cols=80; fi
    printf '%s' "$cols"
}

# Wrap newline-separated names (stdin) into comma-separated lines no wider
# than $1. Names are never split and the last item of each line carries no
# trailing comma. Only empty lines are dropped: a name made of blanks is kept.
wrap_name_list() {
    awk -v width="$1" '
        length($0) { names[++n] = $0 }
        END {
            line = ""
            for (i = 1; i <= n; i++) {
                if (line == "") {
                    line = names[i]
                } else if (length(line) + 2 + length(names[i]) <= width) {
                    line = line ", " names[i]
                } else {
                    print line
                    line = names[i]
                }
            }
            if (line != "") print line
        }
    '
}

# One wrapped inventory block: "<label> (<count>):" followed by the names,
# indented by two spaces and wrapped so that the indented lines stay within
# $3. $1 is the brew list flag (--cask / --formula).
brew_list_block() {
    local names count wrap_width
    names="$(brew list "$1" 2>/dev/null || true)"
    count="$(printf '%s\n' "$names" | awk 'NF { n++ } END { print n + 0 }')"
    printf '%s (%s):' "$2" "$count"
    if [[ "$count" -gt 0 ]]; then
        # The two-space indent counts toward the line width.
        wrap_width=$(( $3 - 2 ))
        [[ "$wrap_width" -lt 10 ]] && wrap_width=10
        printf '\n%s\n' "$(printf '%s\n' "$names" | wrap_name_list "$wrap_width" | sed 's/^/  /')"
    fi
}

# .app bundles under the given roots, up to two levels deep (e.g.
# /Applications/Foo.app and /Applications/Utilities/Bar.app), NUL-separated so
# any file name (spaces, newlines) survives. Bundles are never descended into,
# so nested helper apps are not listed. Symbolic links are followed (find -L):
# on recent macOS, Safari.app and Feedback Assistant.app are links into the
# cryptex volume, and a folder that is a link may hold apps; only links that
# resolve to a directory count, broken ones are ignored. The depth limit also
# bounds any symlink loop. Missing or unreadable roots are skipped.
list_app_bundles() {
    local root
    for root in "$@"; do
        [[ -d "$root" ]] || continue
        # Trailing slash: also follow a root that is itself a symlink.
        find -L "${root%/}/" -mindepth 1 -maxdepth 2 -type d -name '*.app' -prune -print0 2>/dev/null || true
    done
}

# Inventory of installed applications with their disk usage: "<label> (<n>):"
# then one "  <size><TAB><path>" line per bundle, sorted by path. Sizes come from
# a single `du -sh -H` pass (-H: a link is measured as its target, not as 0B);
# xargs only batches it when the argument list is huge, so the cost stays
# bounded. A bundle whose size cannot be read shows "-": an unreadable
# subdirectory makes du exit non-zero while still printing a PARTIAL total, so
# when the grouped pass fails every bundle is measured again on its own and
# only measurements with a zero status are kept. A path containing a newline
# would break du's line output, so it is always measured by its own du call
# and shown with the newline written as \n. Prints a notice instead when no
# bundle is found.
build_apps_inventory() {
    local -a plain=()
    local p count=0 size sizes="" rows="" disp out grouped_rc=0
    while IFS= read -r -d '' p; do
        count=$((count + 1))
        size=""
        case "$p" in
            *$'\n'*)
                # Only the first output line carries the size; a non-zero
                # status (partial total) means "unknown", and must not abort.
                if out="$(du -sh -H -- "$p" 2>/dev/null)"; then
                    size="${out%%$'\t'*}"
                else
                    size="-"
                fi
                [[ -z "$size" ]] && size="-"
                disp="${p//$'\n'/\\n}"
                ;;
            *)
                plain[${#plain[@]}]="$p"
                disp="$p"
                ;;
        esac
        # "<path>\001<size>", size when already known else empty. The size
        # never contains \001 but a path may (like tabs, newlines): the awk
        # below splits at the LAST \001.
        rows="${rows}${disp}"$'\001'"${size}"$'\n'
    done < <(list_app_bundles "$@")
    if [[ "$count" -eq 0 ]]; then
        printf '%s\n' "${MSG_INVENTORY_APPS_NONE}"
        return 0
    fi
    if [[ "${#plain[@]}" -gt 0 ]]; then
        # NUL-separated so names with spaces are safe. A failing du (xargs
        # exits non-zero) must not abort the report, but its totals may be
        # partial: fall back to one du per bundle and keep only the clean ones.
        sizes="$(printf '%s\0' "${plain[@]}" | xargs -0 du -sh -H -- 2>/dev/null)" || grouped_rc=$?
        if [[ "$grouped_rc" -ne 0 ]]; then
            sizes=""
            for p in "${plain[@]}"; do
                if out="$(du -sh -H -- "$p" 2>/dev/null)"; then
                    sizes="${sizes}${out}"$'\n'
                fi
            done
        fi
    fi
    printf '%s (%s):\n' "${MSG_INVENTORY_APPS}" "$count"
    # Sizes travel through the environment: awk -v would interpret backslashes.
    printf '%s' "$rows" | LC_ALL=C sort | DU_SH_OUT="$sizes" awk '
        BEGIN {
            sep = sprintf("%c", 1)
            n = split(ENVIRON["DU_SH_OUT"], lines, "\n")
            for (i = 1; i <= n; i++) {
                t = index(lines[i], "\t")
                if (t > 1) size[substr(lines[i], t + 1)] = substr(lines[i], 1, t - 1)
            }
        }
        length($0) {
            for (k = length($0); k > 0; k--) if (substr($0, k, 1) == sep) break
            if (k == 0) next
            path = substr($0, 1, k - 1)
            s = substr($0, k + 1)
            if (s == "") s = (path in size ? size[path] : "-")
            printf "  %s\t%s\n", s, path
        }
    '
}

# Physical path of existing directory $1 (symbolic links, "..", "//" and
# trailing slashes resolved): the identity of a directory, whatever its
# spelling. Printed followed by a literal "x" sentinel, which the caller must
# strip (phys="${phys%x}") after its command substitution: $(...) removes
# trailing newlines, which would merge "dir" and a sibling named "dir<LF>".
# One subshell per call.
physical_dir() {
    local out
    out="$(cd -P -- "$1" 2>/dev/null && pwd -P && printf x)" || return 1
    printf '%sx' "${out%$'\n'x}"
}

# Colon-separated PATH string ($1) as NUL-separated "<entry>" "<physical path>"
# pairs of usable directories. Duplicates are dropped on the PHYSICAL
# directory, so a symbolic link, "//dir" or "a/../dir" to an already listed
# directory counts once; the first occurrence (and its PATH spelling, minus
# trailing slashes) is kept, in PATH order. Skipped entries are empty (the
# current directory), relative (they depend on the working directory) and not
# an existing directory. NUL-separated so a name with a newline survives.
list_path_dirs() {
    local -a seen=()
    local entry phys i dup
    while IFS= read -r -d ':' entry; do
        [[ "$entry" = /* ]] || continue
        while [[ "$entry" = ?*/ ]]; do entry="${entry%/}"; done
        phys="$(physical_dir "$entry")" || continue
        phys="${phys%x}"
        dup=0
        i=0
        while [[ "$i" -lt "${#seen[@]}" ]]; do
            if [[ "${seen[$i]}" = "$phys" ]]; then dup=1; break; fi
            i=$((i + 1))
        done
        [[ "$dup" -eq 1 ]] && continue
        seen[${#seen[@]}]="$phys"
        printf '%s\0%s\0' "$entry" "$phys"
    done < <(printf '%s:' "$1")
}

# Executable files directly inside directory $1, one name per line, sorted.
# One pass of shell tests over a glob (no find/ls, no fork per file): a
# directory of thousands of tools stays fast. `-f` and `-x` follow symbolic
# links, so a link to an executable (Homebrew's bin/) counts while a broken
# link, a link to a directory or a non-executable file does not. A newline in a
# name is written as \n so every name stays on one line.
list_dir_executables() {
    local f name
    local -a names=()
    for f in "$1"/* "$1"/.[!.]* "$1"/..?*; do
        [[ -f "$f" && -x "$f" ]] || continue
        name="${f##*/}"
        names[${#names[@]}]="${name//$'\n'/\\n}"
    done
    [[ "${#names[@]}" -gt 0 ]] || return 0
    printf '%s\n' "${names[@]}" | LC_ALL=C sort
}

# Survey of the command-line tools installed in the PATH directories.
# $1 is the width of the wrapped lists. Standard system directories
# (TM_EXCLUSIONS_SYSTEM_PATHS, default /bin:/sbin:/usr/bin:/usr/sbin) only get
# their binary count: "[sys] <dir> (<n> binaries — omitted)". Every other
# directory is a toolchain one and gets "[dev] <dir> (<n> binaries):" followed
# by the tool names, wrapped like the Homebrew lists.
build_path_tools_inventory() {
    local width="${1:-80}" sys_dirs dir phys names count word wrap_width found=0
    local s sp is_sys shown
    local -a sys_phys=()
    sys_dirs="${TM_EXCLUSIONS_SYSTEM_PATHS:-/bin:/sbin:/usr/bin:/usr/sbin}"
    # System directories by physical identity, resolved once: an alias of one
    # (symbolic link, "//", "..") is a system directory too.
    while IFS= read -r -d ':' s; do
        [[ "$s" = /* ]] || continue
        sp="$(physical_dir "$s")" || continue
        sp="${sp%x}"
        sys_phys[${#sys_phys[@]}]="$sp"
    done < <(printf '%s:' "$sys_dirs")
    wrap_width=$(( width - 4 ))
    [[ "$wrap_width" -lt 10 ]] && wrap_width=10
    printf '%s:\n' "${MSG_INVENTORY_PATH}"
    while IFS= read -r -d '' dir && IFS= read -r -d '' phys; do
        found=1
        # A newline in the directory name is written as \n (one line each).
        shown="${dir//$'\n'/\\n}"
        names="$(list_dir_executables "$dir")"
        count="$(printf '%s\n' "$names" | awk 'length($0) { n++ } END { print n + 0 }')"
        word="${MSG_INVENTORY_PATH_BINARIES}"
        [[ "$count" -eq 1 ]] && word="${MSG_INVENTORY_PATH_BINARY}"
        is_sys=0
        for s in ${sys_phys[@]+"${sys_phys[@]}"}; do
            if [[ "$s" = "$phys" ]]; then is_sys=1; break; fi
        done
        if [[ "$is_sys" -eq 1 ]]; then
            printf '[sys] %s (%s %s — %s)\n' "$shown" "$count" "$word" "${MSG_INVENTORY_PATH_OMITTED}"
        else
            printf '[dev] %s (%s %s)' "$shown" "$count" "$word"
            if [[ "$count" -gt 0 ]]; then
                printf ':\n%s\n' "$(printf '%s\n' "$names" | wrap_name_list "$wrap_width" | sed 's/^/  /')"
            else
                printf '\n'
            fi
        fi
    done < <(list_path_dirs "${PATH:-}")
    if [[ "$found" -eq 0 ]]; then
        printf '  %s\n' "${MSG_INVENTORY_PATH_NONE}"
    fi
}

build_inventory_section() {
    local stdout_tty="${1:-0}" width path_total path_dirs p oifs
    printf '=== Inventory (informational) ===\n'
    if [[ "${TM_EXCLUSIONS_SKIP_INVENTORY:-}" = "1" ]]; then
        printf '(skipped: TM_EXCLUSIONS_SKIP_INVENTORY=1)\n'
        return 0
    fi
    if [[ -d /Applications ]]; then
        printf '/Applications (top-level): %s\n' \
            "$(find /Applications -maxdepth 1 -mindepth 1 2>/dev/null | wc -l | tr -d '[:space:]' || true)"
    fi
    build_apps_inventory /Applications "${HOME}/Applications"
    if command -v brew >/dev/null 2>&1; then
        width="$(report_columns "$stdout_tty")"
        printf '%s\n' "$(brew_list_block --cask 'Homebrew casks' "$width")"
        printf '%s\n' "$(brew_list_block --formula 'Homebrew formulas' "$width")"
    else
        printf 'Homebrew: not installed (brew not found in PATH), cask/formula lists skipped.\n'
    fi
    path_total="$(printf '%s' "${PATH:-}" | awk -F: '{print NF}')"
    path_dirs=0
    oifs="${IFS}"
    IFS=':'
    for p in ${PATH:-}; do
        [[ -d "$p" ]] && path_dirs=$((path_dirs + 1))
    done
    IFS="${oifs}"
    printf 'PATH: %s existing directories (of %s colon-separated entries)\n' "$path_dirs" "$path_total"
    if [[ "${QUIET}" -eq 0 ]]; then
        build_path_tools_inventory "$(report_columns "$stdout_tty")"
    fi
}

# Interactive runs get the inventory inline (first line of $1 is the report
# header, skipped here in favour of the localized section title).
ui_print_inventory() {
    ui_section "🍺" "${MSG_UI_INVENTORY}"
    printf '%s\n' "$1" | tail -n +2 | while IFS= read -r line; do
        printf '  %s\n' "$line"
    done
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
# Details lines grouped under `── Category ──` subheadings, categories in order
# of first appearance and lines in processing order (#46).
group_report_details() {
    if [[ -z "${REPORT_GROUPED}" ]]; then
        printf '%s' "${REPORT_LINES}"
        return 0
    fi
    printf '%s' "${REPORT_GROUPED}" | awk -F '\t' '
        NF >= 2 {
            c = $1
            if (!(c in known)) { known[c] = 1; cats[++nc] = c }
            l = $0
            sub(/^[^\t]*\t/, "", l)
            lines[c, ++rows[c]] = l
        }
        END {
            for (i = 1; i <= nc; i++) {
                c = cats[i]
                if (i > 1) print ""
                print "── " c " ──"
                for (r = 1; r <= rows[c]; r++) print lines[c, r]
            }
        }'
}

generate_report() {
    RULE_CONTEXT=""
    RULE_CATEGORY=""
    local report="" console_report=""
    local dry_run_note=""
    local excluded_label="${MSG_REPORT_EXCLUDED}"
    local inv du_sec size_total_line size_total_disp tm_list out_path path_total path_dirs p szk sh total_k desk_copy raw_list tm_list_rc
    local space_label banner_path report_saved=0 space_line="" tip_path=""
    local stdout_tty=0
    # Evaluated here, in the main shell: inside $(...) stdout is a pipe and
    # [[ -t 1 ]] would always be false.
    [[ -t 1 ]] && stdout_tty=1

    inv="$(build_inventory_section "$stdout_tty")"
    if [[ "${UI}" -eq 1 ]]; then
        ui_print_inventory "$inv"
        ui_section "📝" "$MSG_UI_REPORT"
    fi

    if [ "${DRY_RUN}" -eq 1 ]; then
        dry_run_note=" (dry-run)"
        excluded_label="${MSG_REPORT_WOULD_EXCLUDE}"
    elif [[ "${MODE}" = "report-only" ]]; then
        excluded_label="${MSG_REPORT_NEED_EXCLUSION}"
    fi

    du_sec=""
    size_total_line=""
    size_total_disp=""
    if [[ "${TM_EXCLUSIONS_SKIP_DU:-}" = "1" ]]; then
        du_sec="
=== Disk usage (paths touched in this run, present on disk) ===
(skipped: TM_EXCLUSIONS_SKIP_DU=1)"
    elif [[ -n "${DU_PATHS}" ]]; then
        du_sec="
=== Disk usage (paths touched in this run, present on disk) ==="
        while IFS= read -r p; do
            [[ -z "$p" || ! -e "$p" ]] && continue
            # Reuse the size recorded while the path was processed (#45); only an
            # unrecorded path falls back to a fresh du, recorded so du_total_kb
            # does not walk it again. `--` is applied inside du_size_kb;
            # unreadable children must not abort.
            if ! szk="$(du_size_lookup "$p")"; then
                szk="$(du_size_kb "$p")"
                du_size_record "$p" "$szk"
            fi
            case "$szk" in
                ''|*[!0-9]*) continue ;;
            esac
            sh="$(format_size_kb "$szk")"
            du_sec="${du_sec}
${sh}	${p}"
        done <<EOF
${DU_PATHS}
EOF
        # The total is computed ONCE here (du_total_kb skips paths deleted
        # since their measurement, exactly like the per-path lines above) and
        # passed to ui_summary as $2 — it is never recomputed afterwards, so
        # the report and the interactive summary always agree, even if a path
        # disappears while tmutil listexclusions runs in between (#45, #77 review).
        total_k="$(du_total_kb)"
        size_total_disp="$(format_size_kb "${total_k}")"
        du_sec="${du_sec}
Total (sum of du -sk, KiB): ${total_k}
"
        # Cumulative formatted counter for the report counters (#45); same
        # total_k as the KiB line above.
        size_total_line="
${MSG_REPORT_SIZE_TOTAL} ${size_total_disp}"
    fi

    # Space of the newly excluded paths (#44), from the sizes recorded while the
    # paths were processed. Computed once; the report counters and the
    # interactive banner both print this exact string. Simulated in dry-run,
    # "needing exclusion" in audit mode.
    excl_space_display
    space_label="${MSG_UI_SPACE_EXCLUDED}"
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        space_label="${MSG_UI_SPACE_SIMULATED}"
    elif [[ "${MODE}" = "report-only" ]]; then
        space_label="${MSG_UI_SPACE_NEEDED}"
    fi
    if [[ -n "${SPACE_EXCL_DISP}" ]]; then
        space_line="
${space_label} ${SPACE_EXCL_DISP}"
        size_total_line="${size_total_line}${space_line}"
    fi

    report="${MSG_REPORT_TITLE}
Host: $(hostname 2>/dev/null || echo unknown)
User: $(id -un 2>/dev/null || echo unknown)
${PROGRAM_NAME} ${VERSION}
Date: $(date '+%Y-%m-%d %H:%M:%S')
Mode: ${MODE}${dry_run_note}

${MSG_REPORT_CHECKED} ${TOTAL_CHECKED}
${excluded_label} ${TOTAL_EXCLUDED}
${MSG_REPORT_ALREADY} ${TOTAL_ALREADY}
${MSG_REPORT_SKIPPED} ${TOTAL_SKIPPED}
${MSG_REPORT_ERRORS} ${TOTAL_ERRORS}
${MSG_REPORT_BLOCKED} ${TOTAL_BLOCKED}
${MSG_REPORT_NOT_FOUND} ${TOTAL_NOT_FOUND}${size_total_line}"

    if [[ "${MODE}" = "uninstall" ]]; then
        report="${report}
${MSG_REPORT_REMOVED} ${TOTAL_REMOVED}"
    fi

    console_report="$report"

    report="${report}

${inv}"

    if [[ -n "${du_sec}" ]]; then
        report="${report}${du_sec}"
    fi

    if [[ -n "${REPORT_LINES}" ]]; then
        report="${report}

Details:
$(group_report_details)"
    fi

    tm_list=""
    if [[ "${HAS_TMUTIL}" -eq 1 ]]; then
        raw_list=""
        tm_list_rc=0
        raw_list="$(tmutil listexclusions 2>/dev/null)" || tm_list_rc=$?
        if [[ "$tm_list_rc" -ne 0 ]]; then
            TM_LIST_STATUS="failed (exit ${tm_list_rc})"
            raw_list="${MSG_REPORT_TMLIST_FAILED}"
        elif [[ -n "$raw_list" ]]; then
            TM_LIST_STATUS="ok"
            raw_list="$(printf '%s\n' "$raw_list" | head -n 500)"
        else
            TM_LIST_STATUS="empty"
            raw_list="${MSG_REPORT_TMLIST_EMPTY}"
        fi
        tm_list="
=== tmutil listexclusions (first 500 lines; status: ${TM_LIST_STATUS}) ===
${raw_list}"
    else
        TM_LIST_STATUS="unavailable"
    fi
    report="${report}${tm_list}"

    report="${report}

=== ${MSG_REPORT_RULE_SUMMARY} ==="
    if [[ -n "$RULE_SUMMARY" ]]; then
        while IFS=$'\t' read -r key count; do
            [[ -z "$key" ]] && continue
            report="${report}"$'\n'"${count}"$'\t'"${key}"
        done <<EOF
${RULE_SUMMARY}
EOF
    else
        report="${report}
${MSG_REPORT_RULE_SUMMARY_EMPTY}"
    fi

    # Write the report before the banner so the banner only advertises a file
    # that really exists (#44).
    out_path="$(resolve_report_out_path)"
    if mkdir -p "$(dirname "${out_path}")" 2>/dev/null && printf '%s\n' "$report" > "${out_path}" 2>/dev/null; then
        report_saved=1
    fi

    if [[ "${UI}" -eq 1 ]]; then
        banner_path=""
        if [[ "$report_saved" -eq 1 ]]; then banner_path="$out_path"; fi
        tip_path="${EXCL_FIRST_PATH:-$TIP_PATH}"
        ui_summary "$excluded_label" "$size_total_disp" "$space_label" "$SPACE_EXCL_DISP" "$banner_path" "$tip_path"
    elif [[ "$QUIET" -eq 1 ]]; then
        # --quiet stdout is unchanged from before #44: the new space line stays
        # in the saved report file only.
        printf '\n%s\n' "${report/"$space_line"/}"
    elif [[ "$VERBOSE" -eq 1 ]]; then
        printf '\n%s\n' "$report"
    else
        printf '\n%s\n' "$console_report"
    fi

    if [[ "$report_saved" -eq 1 ]]; then
        # The interactive banner already shows the report path.
        if [[ "${UI}" -eq 0 ]]; then
            log_info ""
            log_info "${MSG_REPORT_SAVED} ${out_path}"
        fi
    else
        record_error "${MSG_ERROR_REPORT_WRITE} ${out_path}"
        # Keep the detailed results accessible if the compact view cannot link a file.
        if [[ "${UI}" -eq 1 || ( "$VERBOSE" -eq 0 && "$QUIET" -eq 0 ) ]]; then printf '\n%s\n' "$report"; fi
    fi

    if desktop_report_enabled; then
        desk_copy="${HOME}/Desktop/tm-exclusions_last_report.txt"
        if mkdir -p "${HOME}/Desktop" 2>/dev/null && printf '%s\n' "$report" > "${desk_copy}" 2>/dev/null; then
            log_info "${MSG_REPORT_DESKTOP_COPY} ${desk_copy}"
        else
            record_error "${MSG_ERROR_REPORT_WRITE} ${desk_copy}"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Help and version
# ---------------------------------------------------------------------------
show_help() {
    echo "${MSG_HELP_USAGE}"
    echo "${MSG_HELP_DESC}"
    echo ""
    echo "${MSG_HELP_MODES}"
    echo "${MSG_HELP_DEFAULT}"
    echo "${MSG_HELP_DRY_RUN}"
    echo "${MSG_HELP_REPORT}"
    echo "${MSG_HELP_UNINSTALL}"
    echo ""
    echo "${MSG_HELP_OPTIONS}"
    echo "${MSG_HELP_QUIET}"
    echo "${MSG_HELP_VERBOSE}"
    echo "${MSG_HELP_FORCE}"
    echo "${MSG_HELP_DESKTOP_REPORT}"
    echo "${MSG_HELP_LANG}"
    echo "${MSG_HELP_VERSION}"
    echo "${MSG_HELP_HELP}"
    echo "${MSG_HELP_HELP_SHORT}"
    echo ""
    echo "${MSG_HELP_CONFIG}"
    echo "${MSG_HELP_ADD}"
    echo "${MSG_HELP_LIST}"
    echo "${MSG_HELP_EDIT}"
    echo "${MSG_HELP_INIT}"
    echo ""
    echo "${MSG_HELP_TYPES}"
}

show_version() {
    echo "${PROGRAM_NAME} ${VERSION}"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                CONFIG_CMD="help"
                return 0
                ;;
            --version)
                CONFIG_CMD="version"
                return 0
                ;;
            --dry-run)
                DRY_RUN=1
                ;;
            --report-only)
                MODE="report-only"
                ;;
            --uninstall)
                MODE="uninstall"
                ;;
            --force)
                FORCE=1
                ;;
            --desktop-report)
                DESKTOP_REPORT=1
                ;;
            --verbose|-v)
                VERBOSE=1
                ;;
            --quiet|-q)
                QUIET=1
                ;;
            --lang)
                if [[ $# -lt 2 ]]; then
                    log_error "${MSG_ERROR_MISSING_ARGS}"
                    exit 1
                fi
                shift
                case "$1" in
                    en|fr)
                        LANG_OVERRIDE="$1"
                        ;;
                    *)
                        log_error "${MSG_ERROR_INVALID_LANG}"
                        exit 1
                        ;;
                esac
                ;;
            --add)
                if [[ $# -lt 4 ]]; then
                    log_error "${MSG_ERROR_MISSING_ARGS}"
                    exit 1
                fi
                CONFIG_CMD="add"
                shift
                CONFIG_ADD_TYPE="$1"
                shift
                CONFIG_ADD_PATH="$1"
                shift
                CONFIG_ADD_REASON="$1"
                shift
                if [[ $# -gt 0 ]]; then
                    log_error "${MSG_ERROR_INVALID_ARG} $1"
                    exit 1
                fi
                return 0
                ;;
            --list)
                CONFIG_CMD="list"
                return 0
                ;;
            --edit)
                CONFIG_CMD="edit"
                return 0
                ;;
            --init)
                CONFIG_CMD="init"
                return 0
                ;;
            *)
                log_error "${MSG_ERROR_INVALID_ARG} $1"
                exit 1
                ;;
        esac
        shift
    done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    trap 'cleanup' EXIT
    trap 'on_signal INT' INT
    trap 'on_signal TERM' TERM
    trap 'on_signal HUP' HUP

    # First pass: detect --lang and --quiet before i18n init
    local arg
    for arg in "$@"; do
        case "$arg" in
            --quiet|-q) QUIET=1 ;;
        esac
    done

    # Peek for --lang in args
    local i=0
    for arg in "$@"; do
        i=$((i + 1))
        if [[ "$arg" = "--lang" ]]; then
            local next_i=$((i + 1))
            local j=0
            for a2 in "$@"; do
                j=$((j + 1))
                if [[ "$j" -eq "$next_i" ]]; then
                    # Capture raw value; detect_language/load_i18n allowlist
                    # before any locale path is built. parse_args reports
                    # MSG_ERROR_INVALID_LANG for unsupported codes.
                    LANG_OVERRIDE="$a2"
                    break
                fi
            done
            break
        fi
    done

    # Initialize language
    detect_language

    init_ui

    # Parse arguments fully
    parse_args "$@"

    case "${CONFIG_CMD}" in
        add|list|edit|"")
            ensure_custom_conf_exists
            ;;
    esac

    # Handle config/info commands
    case "${CONFIG_CMD}" in
        help)
            show_help
            exit 0
            ;;
        version)
            show_version
            exit 0
            ;;
        init)
            cmd_config_init
            exit 0
            ;;
        add)
            cmd_config_add "${CONFIG_ADD_TYPE}" "${CONFIG_ADD_PATH}" "${CONFIG_ADD_REASON}"
            exit 0
            ;;
        list)
            cmd_config_list
            exit 0
            ;;
        edit)
            cmd_config_edit
            exit 0
            ;;
    esac

    if [[ -n "${TM_EXCLUSIONS_DEBUG_FIFO:-}" ]]; then
        # FIFO: open read+write so open(2) does not block waiting for a separate reader.
        if [[ -p "${TM_EXCLUSIONS_DEBUG_FIFO}" ]]; then
            if exec 5<>"${TM_EXCLUSIONS_DEBUG_FIFO}"; then
                DEBUG_LOG_FD=1
            else
                DEBUG_LOG_FD=0
            fi
        else
            if exec 5>>"${TM_EXCLUSIONS_DEBUG_FIFO}"; then
                DEBUG_LOG_FD=1
            else
                DEBUG_LOG_FD=0
            fi
        fi
    fi

    # Check environment
    check_environment

    # Load config
    load_config
    if [[ "$TOTAL_ERRORS" -gt 0 ]]; then
        generate_report
        return 1
    fi

    if [[ "${UI}" -eq 1 ]]; then
        printf '\n%s  🛡️  %s%s  v%s\n' "$UI_CYAN" "$PROGRAM_NAME" "$UI_RESET" "$VERSION"
        printf '  %s\n' "$MSG_HELP_DESC"
        local mode_label="$MSG_UI_APPLY"
        case "$MODE" in
            report-only) mode_label="$MSG_UI_AUDIT" ;;
            uninstall) mode_label="$MSG_UI_UNINSTALL" ;;
        esac
        printf '  %s%s%s\n' "$UI_DIM" "$mode_label" "$UI_RESET"
        if [[ "${DRY_RUN}" -eq 1 ]]; then log_info "$MSG_DRY_RUN_PREFIX"; fi
    fi
    ui_section "🔎" "$MSG_UI_DISCOVERY"
    collect_post_scan_paths

    if [[ "${MODE}" != "report-only" ]]; then
        migrate_retired_exclusions
    fi

    check_keeps

    # Execute based on mode
    case "${MODE}" in
        uninstall)
            log_info "${MSG_UNINSTALL_START}"
            if [[ "${FORCE}" -eq 1 ]]; then
                log_info "${MSG_UNINSTALL_FORCE}"
            fi
            apply_static_paths
            scan_dynamic_patterns
            apply_extra_paths
            generate_report
            log_info ""
            log_info "${MSG_UNINSTALL_DONE}"
            ;;
        report-only)
            apply_static_paths
            scan_dynamic_patterns
            apply_extra_paths
            generate_report
            ;;
        apply|*)
            apply_static_paths
            scan_dynamic_patterns
            apply_extra_paths
            generate_report
            ;;
    esac
    [[ "$TOTAL_ERRORS" -eq 0 ]]
}

main "$@"
