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
# Temporary files to remove on exit/signal
TMP_FILES=""
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

ui_summary() {
    ui_section "📊" "${MSG_UI_SUMMARY}"
    printf '  %s %s\n' "$MSG_REPORT_CHECKED" "$TOTAL_CHECKED"
    printf '  %s%s %s%s\n' "$UI_GREEN" "$1" "$TOTAL_EXCLUDED" "$UI_RESET"
    printf '  %s %s\n' "$MSG_REPORT_ALREADY" "$TOTAL_ALREADY"
    printf '  %s%s %s%s\n' "$UI_DIM" "$MSG_REPORT_SKIPPED" "$TOTAL_SKIPPED" "$UI_RESET"
    printf '  %s %s\n' "$MSG_REPORT_ERRORS" "$TOTAL_ERRORS"
    printf '  %s %s\n' "$MSG_REPORT_BLOCKED" "$TOTAL_BLOCKED"
    # Cumulative disk usage of the paths touched in this run (#45). The total is
    # computed once by generate_report and passed in as $2 — never recomputed
    # here — so the summary always matches the report even if a path disappears
    # while tmutil listexclusions runs between the two.
    if [[ -n "${2:-}" ]]; then
        printf '  %s %s\n' "$MSG_REPORT_SIZE_TOTAL" "$2"
    fi
    if [[ "${MODE}" = "uninstall" ]]; then
        printf '  %s %s\n' "$MSG_REPORT_REMOVED" "$TOTAL_REMOVED"
    fi
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

# Track paths for optional du summary (dedupe; Bash 3.2 — no associative arrays)
du_track_path() {
    local p="$1" entry normalized retained=""
    [[ -z "$p" || ! -e "$p" ]] && return 0
    # Compare physical spellings: symlinked and `..`-relative duplicates must not
    # inflate the total, and stored entries are normalized on the way in too.
    if ! p="$(normalize_path "$p")"; then
        return 0
    fi
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        normalized="$entry"
        if [[ -e "$entry" ]]; then
            normalized="$(normalize_path "$entry")" || normalized="$entry"
        fi
        path_under "$p" "$normalized" && return 0
        if ! path_under "$normalized" "$p"; then retained="${retained}${normalized}
"; fi
    done <<EOF
${DU_PATHS}
EOF
    DU_PATHS="${retained}${p}"
}

# KiB on disk for $1. Permission-denied children (typical of /private/var/folders)
# make BSD/GNU du exit non-zero even when a partial total was printed. Capture
# du independently so set -euo pipefail cannot abort report generation (#18, #55).
du_size_kb() {
    local raw=""
    raw="$(du -sk -- "$1" 2>/dev/null || true)"
    [[ -z "$raw" ]] && return 0
    awk '{print $1; exit}' <<EOF
${raw}
EOF
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
format_size_kb() {
    awk -v k="$1" 'BEGIN {
        if (k < 1024) { printf "%dK", k; exit }
        x = k / 1024.0
        if (x < 1024) { printf "%.1fM", x; exit }
        x = x / 1024.0
        if (x < 1024) { printf "%.1fG", x; exit }
        x = x / 1024.0
        printf "%.1fT", x
    }'
}

# Record the KiB size of $1 (empty when unreadable). Overwrites an existing entry.
du_size_record() {
    local p="$1" kb="$2" entry ek found=0 retained=""
    [[ -z "$p" ]] && return 0
    while IFS=$'\t' read -r entry ek; do
        [[ -z "$entry" ]] && continue
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

# Echo the recorded KiB of $1; returns 1 when $1 has no recorded entry.
du_size_lookup() {
    local p="$1" entry kb
    while IFS=$'\t' read -r entry kb; do
        [[ -z "$entry" ]] && continue
        if [[ "$entry" = "$p" ]]; then
            printf '%s' "$kb"
            return 0
        fi
    done <<EOF
${DU_SIZES}
EOF
    return 1
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
path_size_column() {
    PATH_SIZE_COL=""
    du_enabled || return 0
    local p="$1" np="" szk=""
    if [[ -n "$p" && -e "$p" ]]; then
        if ! np="$(normalize_path "$p")"; then np="$p"; fi
        # Consult the cache before measuring: a repeated rule (same path twice)
        # must not walk the same tree again (#45).
        if ! szk="$(du_size_lookup "$np")"; then
            szk="$(du_size_kb "$np")"
            du_size_record "$np" "$szk"
        fi
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

unregister_tmp_file() {
    local f="$1"
    [[ -z "$f" || -z "${TMP_FILES}" ]] && return 0
    TMP_FILES="$(printf '%s\n' "${TMP_FILES}" | grep -Fvx "$f" || true)"
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
    du_track_path "$path"
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
        log_path_result need "$path" "  $MSG_REPORT_NEED_EXCLUSION $(path_suffix "$size_col" "$path")"
        add_report_line "NEED  $path (not excluded)"
    elif [[ "$DRY_RUN" -eq 1 ]]; then
        TOTAL_EXCLUDED=$((TOTAL_EXCLUDED + 1))
        log_path_result apply "$path" "  $MSG_DRY_RUN_PREFIX $MSG_APPLYING $(path_suffix "$size_col" "$path")"
        add_report_line "WOULD $path"
    elif tm_add_exclusion "$path"; then
        TOTAL_EXCLUDED=$((TOTAL_EXCLUDED + 1))
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
    kept_file="$(mktemp "${TMPDIR:-/tmp}/tm_exc_kept.XXXXXX")"
    register_tmp_file "$kept_file"
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
    all_results="$(mktemp "${TMPDIR:-/tmp}/tm_exc_all.XXXXXX")"
    register_tmp_file "$all_results"

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
    tmp_scan="$(mktemp "${TMPDIR:-/tmp}/tm_exc.XXXXXX")"
    register_tmp_file "$tmp_scan"
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
    unregister_tmp_file "$tmp_scan"

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
    sorted_results="$(mktemp "${TMPDIR:-/tmp}/tm_exc_sorted.XXXXXX")"
    register_tmp_file "$sorted_results"
    LC_ALL=C sort -t$'\t' -k1,1 "$all_results" > "$sorted_results"
    rm -f "$all_results"
    unregister_tmp_file "$all_results"

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
    unregister_tmp_file "$sorted_results"
    unregister_tmp_file "$kept_file"
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
    tmp="$(mktemp "${TMPDIR:-/tmp}/tm_exc_disk.XXXXXX")"
    register_tmp_file "$tmp"
    # Stream directories and matching images from the same walk, NUL-delimited.
    # Sparsebundles are reported as candidates but their contents stay pruned.
    show_scan_path "$HOME"
    if ! find "$HOME" \( -path '*/Mobile Documents/*' -o -path '*/Library/Mobile Documents/*' \) -prune -o \
        \( -type d -print0 \( -name '*.sparsebundle' -prune \) \) -o \
        \( -type f \( -name '*.vmdk' -o -name '*.qcow2' -o -name '*.raw' -o -name '*.img' \) -size +512M -print0 \) \
        2>/dev/null | {
            local candidate count=0
            while IFS= read -r -d '' candidate; do
                # The find stream is NUL-delimited but the candidate batch file is
                # newline-delimited (Bash 3.2); a path containing a newline would
                # be split into bogus entries, so reject it explicitly.
                if [[ "$candidate" = *$'\n'* ]]; then
                    record_error "$MSG_SCAN_NEWLINE_PATH"
                    continue
                fi
                if [[ -d "$candidate" ]]; then
                    show_scan_path "$candidate"
                    [[ "$candidate" = *.sparsebundle ]] || continue
                fi
                count=$((count + 1))
                if [[ "$count" -le 51 ]]; then printf '%s\n' "$candidate" >> "$tmp"; fi
            done
        }; then
        record_error "$MSG_SCAN_FAILED $HOME"
    fi
    clear_progress
    if [[ "$(wc -l < "$tmp")" -gt 50 ]]; then
        add_report_line "LIMIT $MSG_IMAGE_LIMIT"
    fi
    local image_count=0

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        image_count=$((image_count + 1))
        [[ "$image_count" -gt 50 ]] && break
        extra_paths_append "$line"
    done < "$tmp"
    rm -f "$tmp"
    unregister_tmp_file "$tmp"
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
# trailing comma.
wrap_name_list() {
    awk -v width="$1" '
        NF { names[++n] = $0 }
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

    if [[ "${UI}" -eq 1 ]]; then
        ui_summary "$excluded_label" "$size_total_disp"
    elif [[ "$VERBOSE" -eq 1 || "$QUIET" -eq 1 ]]; then
        printf '\n%s\n' "$report"
    else
        printf '\n%s\n' "$console_report"
    fi

    out_path="$(resolve_report_out_path)"

    if mkdir -p "$(dirname "${out_path}")" 2>/dev/null && printf '%s\n' "$report" > "${out_path}" 2>/dev/null; then
        log_info ""
        log_info "${MSG_REPORT_SAVED} ${out_path}"
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
