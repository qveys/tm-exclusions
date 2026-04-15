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
readonly VERSION="1.1.0"
readonly PROGRAM_NAME="tm-exclusions"
readonly CUSTOM_CONF="${HOME}/.config/tm_exclusions/custom.conf"
readonly REPORT_FILE="${HOME}/.config/tm_exclusions/last_report.txt"
readonly CUSTOM_CONF_DIR="${HOME}/.config/tm_exclusions"

# ---------------------------------------------------------------------------
# Global state
# ---------------------------------------------------------------------------
MODE="apply"          # apply | dry-run | report-only | uninstall
QUIET=0
FORCE=0
LANG_OVERRIDE=""
CURRENT_LANG="en"
DRY_RUN=0
CONFIG_CMD=""         # add | list | edit | init
CONFIG_ADD_TYPE=""
CONFIG_ADD_PATH=""
CONFIG_ADD_REASON=""

# Counters for report
TOTAL_CHECKED=0
TOTAL_EXCLUDED=0
TOTAL_ALREADY=0
TOTAL_SKIPPED=0
TOTAL_ERRORS=0
TOTAL_REMOVED=0

# Arrays (Bash 3.2 compatible — indexed arrays)
# We store paths/patterns/prunes as newline-delimited strings
CONF_PATHS=""
CONF_PATTERNS=""
CONF_PRUNES=""
REPORT_LINES=""
# Paths discovered after config (brew cache, large VM images); newline-separated
EXTRA_PATHS=""
# Unique existing paths for optional du summary in report
DU_PATHS=""
SUDO_KEEPALIVE_PID=""
# When 1, log_info also appends to FD 5 (opened from TM_EXCLUSIONS_DEBUG_FIFO)
DEBUG_LOG_FD=0

# ---------------------------------------------------------------------------
# i18n strings
# ---------------------------------------------------------------------------
declare_i18n_en() {
    MSG_HELP_USAGE="Usage: ${PROGRAM_NAME} [OPTIONS]"
    MSG_HELP_DESC="macOS Time Machine exclusion manager for developer machines."
    MSG_HELP_MODES="Modes:"
    MSG_HELP_DEFAULT="  (default)          Apply exclusions"
    MSG_HELP_DRY_RUN="  --dry-run          Show what would be done without making changes"
    MSG_HELP_REPORT="  --report-only      Scan and report without applying exclusions"
    MSG_HELP_UNINSTALL="  --uninstall        Remove exclusions matching the current configured rules"
    MSG_HELP_OPTIONS="Options:"
    MSG_HELP_QUIET="  -q, --quiet        Suppress non-essential output"
    MSG_HELP_FORCE="  --force            With --uninstall, also remove matched paths that no longer exist"
    MSG_HELP_LANG="  --lang <en|fr>     Set output language"
    MSG_HELP_VERSION="  --version          Show version"
    MSG_HELP_HELP="  --help             Show this help"
    MSG_HELP_HELP_SHORT="  -h                 Same as --help"
    MSG_HELP_CONFIG="Config management:"
    MSG_HELP_ADD="  --add <type> <path> <reason>  Add a custom exclusion rule"
    MSG_HELP_LIST="  --list             List custom exclusion rules"
    MSG_HELP_EDIT="  --edit             Open custom config in \$EDITOR"
    MSG_HELP_INIT="  --init             Create custom config directory"
    MSG_HELP_TYPES="Supported types: path, pattern, prune"
    MSG_DRY_RUN_PREFIX="[DRY-RUN]"
    MSG_APPLYING="Applying exclusion:"
    MSG_ALREADY="Already excluded:"
    MSG_REMOVING="Removing exclusion:"
    MSG_NOT_EXCLUDED="Not currently excluded:"
    MSG_SCANNING="Scanning for regenerable directories..."
    MSG_STATIC="Applying static exclusion rules..."
    MSG_EXTRA_PATHS="Applying discovered paths (brew cache, large VM images)..."
    MSG_REPORT_TITLE="=== tm-exclusions Report ==="
    MSG_REPORT_CHECKED="Paths checked:"
    MSG_REPORT_EXCLUDED="Newly excluded:"
    MSG_REPORT_WOULD_EXCLUDE="Would exclude:"
    MSG_REPORT_ALREADY="Already excluded:"
    MSG_REPORT_SKIPPED="Skipped (not found):"
    MSG_REPORT_ERRORS="Errors:"
    MSG_REPORT_REMOVED="Removed:"
    MSG_REPORT_SAVED="Report saved to:"
    MSG_REPORT_DESKTOP_COPY="Also saved report copy to:"
    MSG_UNINSTALL_START="Removing tm-exclusions applied exclusions..."
    MSG_UNINSTALL_DONE="Uninstall complete."
    MSG_UNINSTALL_FORCE="Force mode: removing all matched exclusions."
    MSG_CONFIG_CREATED="Custom config directory created:"
    MSG_CONFIG_EXISTS="Custom config directory already exists:"
    MSG_CONFIG_AUTO_CREATED="Created default custom config (first run):"
    MSG_CONFIG_ADDED="Rule added to custom config:"
    MSG_CONFIG_EMPTY="No custom rules found."
    MSG_CONFIG_NO_FILE="Custom config file not found. Run --init first."
    MSG_ERROR_INVALID_ARG="Unknown argument:"
    MSG_ERROR_INVALID_TYPE="Invalid type. Supported: path, pattern, prune"
    MSG_ERROR_INVALID_LANG="Unsupported language for --lang. Supported values: en, fr."
    MSG_ERROR_MISSING_ARGS="Missing required arguments."
    MSG_ERROR_NOT_MACOS="Warning: Not running on macOS. Some features will be simulated."
    MSG_ERROR_NO_TMUTIL="Warning: tmutil not found. Running in simulation mode."
    MSG_PATH_NOT_FOUND="Path not found, skipping:"
    MSG_PRUNE_SKIP="Pruning (skipping scan of):"
    MSG_SKIP_PRIVILEGED="Skipping (non-interactive / no sudo cache) for system path:"
}

declare_i18n_fr() {
    MSG_HELP_USAGE="Utilisation : ${PROGRAM_NAME} [OPTIONS]"
    MSG_HELP_DESC="Gestionnaire d'exclusions Time Machine pour machines de développement macOS."
    MSG_HELP_MODES="Modes :"
    MSG_HELP_DEFAULT="  (défaut)           Appliquer les exclusions"
    MSG_HELP_DRY_RUN="  --dry-run          Montrer les actions sans les exécuter"
    MSG_HELP_REPORT="  --report-only      Scanner et rapporter sans appliquer"
    MSG_HELP_UNINSTALL="  --uninstall        Supprimer les exclusions correspondant aux règles configurées"
    MSG_HELP_OPTIONS="Options :"
    MSG_HELP_QUIET="  -q, --quiet        Mode silencieux"
    MSG_HELP_FORCE="  --force            Avec --uninstall, supprimer aussi les chemins correspondants absents"
    MSG_HELP_LANG="  --lang <en|fr>     Langue de sortie"
    MSG_HELP_VERSION="  --version          Afficher la version"
    MSG_HELP_HELP="  --help             Afficher cette aide"
    MSG_HELP_HELP_SHORT="  -h                 Identique à --help"
    MSG_HELP_CONFIG="Gestion de la configuration :"
    MSG_HELP_ADD="  --add <type> <chemin> <raison>  Ajouter une règle personnalisée"
    MSG_HELP_LIST="  --list             Lister les règles personnalisées"
    MSG_HELP_EDIT="  --edit             Ouvrir la configuration dans \$EDITOR"
    MSG_HELP_INIT="  --init             Créer le répertoire de configuration"
    MSG_HELP_TYPES="Types supportés : path, pattern, prune"
    MSG_DRY_RUN_PREFIX="[SIMULATION]"
    MSG_APPLYING="Application de l'exclusion :"
    MSG_ALREADY="Déjà exclu :"
    MSG_REMOVING="Suppression de l'exclusion :"
    MSG_NOT_EXCLUDED="Non exclu actuellement :"
    MSG_SCANNING="Recherche des répertoires régénérables..."
    MSG_STATIC="Application des règles d'exclusion statiques..."
    MSG_EXTRA_PATHS="Application des chemins découverts (cache brew, grosses images VM)..."
    MSG_REPORT_TITLE="=== Rapport tm-exclusions ==="
    MSG_REPORT_CHECKED="Chemins vérifiés :"
    MSG_REPORT_EXCLUDED="Nouvellement exclus :"
    MSG_REPORT_WOULD_EXCLUDE="Seraient exclus :"
    MSG_REPORT_ALREADY="Déjà exclus :"
    MSG_REPORT_SKIPPED="Ignorés (non trouvés) :"
    MSG_REPORT_ERRORS="Erreurs :"
    MSG_REPORT_REMOVED="Supprimés :"
    MSG_REPORT_SAVED="Rapport sauvegardé dans :"
    MSG_REPORT_DESKTOP_COPY="Copie du rapport également enregistrée dans :"
    MSG_UNINSTALL_START="Suppression des exclusions tm-exclusions..."
    MSG_UNINSTALL_DONE="Désinstallation terminée."
    MSG_UNINSTALL_FORCE="Mode forcé : suppression de toutes les exclusions correspondantes."
    MSG_CONFIG_CREATED="Répertoire de configuration créé :"
    MSG_CONFIG_EXISTS="Répertoire de configuration existant :"
    MSG_CONFIG_AUTO_CREATED="Configuration personnalisée par défaut créée (premier lancement) :"
    MSG_CONFIG_ADDED="Règle ajoutée à la configuration :"
    MSG_CONFIG_EMPTY="Aucune règle personnalisée trouvée."
    MSG_CONFIG_NO_FILE="Fichier de configuration non trouvé. Exécutez --init d'abord."
    MSG_ERROR_INVALID_ARG="Argument inconnu :"
    MSG_ERROR_INVALID_TYPE="Type invalide. Supportés : path, pattern, prune"
    MSG_ERROR_INVALID_LANG="Langue non supportée pour --lang. Valeurs supportées : en, fr."
    MSG_ERROR_MISSING_ARGS="Arguments requis manquants."
    MSG_ERROR_NOT_MACOS="Attention : pas sous macOS. Certaines fonctions seront simulées."
    MSG_ERROR_NO_TMUTIL="Attention : tmutil introuvable. Mode simulation activé."
    MSG_PATH_NOT_FOUND="Chemin introuvable, ignoré :"
    MSG_PRUNE_SKIP="Élagage (scan ignoré pour) :"
    MSG_SKIP_PRIVILEGED="Ignoré (non interactif / pas de cache sudo) pour chemin système :"
}

# ---------------------------------------------------------------------------
# Utility functions
# ---------------------------------------------------------------------------
log_info() {
    if [[ "${QUIET}" -eq 0 ]]; then
        echo "$@"
        if [[ "${DEBUG_LOG_FD}" -eq 1 ]]; then
            echo "$@" >&5 2>/dev/null || true
        fi
    fi
}

log_error() {
    echo "$@" >&2
}

add_report_line() {
    if [[ -z "${REPORT_LINES}" ]]; then
        REPORT_LINES="$1"
    else
        REPORT_LINES="${REPORT_LINES}
$1"
    fi
}

# Track paths for optional du summary (dedupe; Bash 3.2 — no associative arrays)
du_track_path() {
    local p="$1"
    [[ -z "$p" || ! -e "$p" ]] && return 0
    if printf '%s\n' "${DU_PATHS}" | grep -Fqx "$p" 2>/dev/null; then
        return 0
    fi
    if [[ -z "${DU_PATHS}" ]]; then
        DU_PATHS="$p"
    else
        DU_PATHS="${DU_PATHS}
$p"
    fi
}

# True if path is $HOME or under it (normalized, no trailing slash ambiguity)
path_under_home() {
    local p="$1"
    local h="${HOME%/}"
    local pn="${p%/}"
    case "$pn" in
        "${h}"|"${h}/"*) return 0 ;;
        *) return 1 ;;
    esac
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
            sudo -n true 2>/dev/null && sudo -n -v 2>/dev/null || true
        done
    ) &
    SUDO_KEEPALIVE_PID=$!
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
                */.git/worktrees/*|*/.cursor/*) return 0 ;;
            esac
            if [[ -f "${parent}/HEAD" && ( -d "${parent}/worktrees" || -f "${parent}/commondir" ) ]]; then
                return 0
            fi
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
        CURRENT_LANG="${LANG_OVERRIDE}"
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

    case "${CURRENT_LANG}" in
        fr) declare_i18n_fr ;;
        *)  declare_i18n_en ;;
    esac
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
            result="$(tmutil isexcluded "$path" 2>/dev/null)" || result=""
        else
            if ! privileged_tmutil_ok "$path"; then
                return 1
            fi
            sudo_prepare_for_path "$path"
            result="$(sudo tmutil isexcluded "$path" 2>/dev/null)" || result=""
        fi
        case "$result" in
            *"[Excluded]"*) return 0 ;;
            *) return 1 ;;
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
parse_config_file() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        return 0
    fi

    local line_num=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line_num=$((line_num + 1))
        # Skip empty lines and comments
        case "$line" in
            ""|\#*) continue ;;
        esac

        # Parse type|target|reason
        local entry_type entry_target entry_reason
        entry_type="${line%%|*}"
        local rest="${line#*|}"
        entry_target="${rest%%|*}"
        entry_reason="${rest#*|}"

        # Expand ~ to $HOME
        case "$entry_target" in
            "~"*) entry_target="${HOME}${entry_target#\~}" ;;
        esac
        # Expand $HOME in targets (legacy default.conf style)
        local home_token
        home_token="\$HOME"
        while [[ "${entry_target}" == *"${home_token}"* ]]; do
            entry_target="${entry_target//${home_token}/$HOME}"
        done

        case "$entry_type" in
            path)
                if [[ -z "${CONF_PATHS}" ]]; then
                    CONF_PATHS="${entry_target}"
                else
                    CONF_PATHS="${CONF_PATHS}
${entry_target}"
                fi
                ;;
            pattern)
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
            *)
                log_error "Warning: Unknown config entry type '${entry_type}' at ${file}:${line_num}"
                ;;
        esac
    done < "$file"
}

load_config() {
    CONF_PATHS=""
    CONF_PATTERNS=""
    CONF_PRUNES=""

    # Load default config first
    parse_config_file "$(resolve_default_conf)"
    # Merge custom config (entries are appended)
    parse_config_file "${CUSTOM_CONF}"
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
#
# Examples:
# path|~/MyLargeDataset|Large dataset not needed in backup
# pattern|.myframework_cache|Framework cache directories
# prune|~/Archive|Skip scanning archive directory
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
        path|pattern|prune) ;;
        *)
            log_error "${MSG_ERROR_INVALID_TYPE}"
            exit 1
            ;;
    esac

    if [[ ! -f "${CUSTOM_CONF}" ]]; then
        log_error "${MSG_CONFIG_NO_FILE}"
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
    exec "${editor}" "${CUSTOM_CONF}"
}

# ---------------------------------------------------------------------------
# Exclusion application
# ---------------------------------------------------------------------------
apply_exclusion() {
    local path="$1"
    TOTAL_CHECKED=$((TOTAL_CHECKED + 1))

    # Check if path exists
    if [[ ! -e "$path" ]]; then
        TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))
        log_info "  ${MSG_PATH_NOT_FOUND} ${path}"
        add_report_line "SKIP  ${path} (not found)"
        return 0
    fi

    du_track_path "$path"

    if cannot_privileged_tmutil "$path"; then
        TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))
        log_info "  ${MSG_SKIP_PRIVILEGED} ${path}"
        add_report_line "SKIP  ${path} (needs sudo for system path)"
        return 0
    fi

    # Check if already excluded
    if tm_is_excluded "$path"; then
        TOTAL_ALREADY=$((TOTAL_ALREADY + 1))
        log_info "  ${MSG_ALREADY} ${path}"
        add_report_line "OK    ${path} (already excluded)"
        return 0
    fi

    if [[ "${DRY_RUN}" -eq 1 ]]; then
        TOTAL_EXCLUDED=$((TOTAL_EXCLUDED + 1))
        log_info "  ${MSG_DRY_RUN_PREFIX} ${MSG_APPLYING} ${path}"
        add_report_line "WOULD ${path}"
        return 0
    fi

    if tm_add_exclusion "$path"; then
        TOTAL_EXCLUDED=$((TOTAL_EXCLUDED + 1))
        log_info "  ${MSG_APPLYING} ${path}"
        add_report_line "ADD   ${path}"
    else
        TOTAL_ERRORS=$((TOTAL_ERRORS + 1))
        log_error "  Error excluding: ${path}"
        add_report_line "ERROR ${path}"
    fi
}

remove_exclusion() {
    local path="$1"
    TOTAL_CHECKED=$((TOTAL_CHECKED + 1))

    if [[ ! -e "$path" ]] && [[ "${FORCE}" -eq 0 ]]; then
        TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))
        add_report_line "SKIP  ${path} (not found)"
        return 0
    fi

    if [[ -e "$path" ]]; then
        du_track_path "$path"
    fi

    if cannot_privileged_tmutil "$path"; then
        TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))
        log_info "  ${MSG_SKIP_PRIVILEGED} ${path}"
        add_report_line "SKIP  ${path} (needs sudo for system path)"
        return 0
    fi

    if ! tm_is_excluded "$path" && [[ "${FORCE}" -eq 0 ]]; then
        log_info "  ${MSG_NOT_EXCLUDED} ${path}"
        add_report_line "SKIP  ${path} (not excluded)"
        return 0
    fi

    if [[ "${DRY_RUN}" -eq 1 ]]; then
        TOTAL_REMOVED=$((TOTAL_REMOVED + 1))
        log_info "  ${MSG_DRY_RUN_PREFIX} ${MSG_REMOVING} ${path}"
        add_report_line "WOULD_REMOVE ${path}"
        return 0
    fi

    if tm_remove_exclusion "$path"; then
        TOTAL_REMOVED=$((TOTAL_REMOVED + 1))
        log_info "  ${MSG_REMOVING} ${path}"
        add_report_line "REMOVE ${path}"
    else
        TOTAL_ERRORS=$((TOTAL_ERRORS + 1))
        log_error "  Error removing exclusion: ${path}"
        add_report_line "ERROR ${path}"
    fi
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
        case "$check_path" in
            "${prune_entry}"|"${prune_entry}/"*)
                return 0
                ;;
        esac
    done <<EOF
${CONF_PRUNES}
EOF
    return 1
}

scan_dynamic_patterns() {
    log_info ""
    log_info "${MSG_SCANNING}"

    if [[ -z "${CONF_PATTERNS}" ]]; then
        return 0
    fi

    # Build find arguments for pattern matching
    # We scan from $HOME, respecting prune paths
    local scan_root="${HOME}"

    # Use a simpler approach: for each pattern, use find
    local pattern_name
    while IFS= read -r pattern_name; do
        [[ -z "$pattern_name" ]] && continue

        # Use find to locate directories matching pattern_name
        # -maxdepth 6 keeps it practical
        # Write found directories to a temp file to avoid subshell variable scope issues
        local tmp_results
        tmp_results="$(mktemp "${TMPDIR:-/tmp}/tm_exc.XXXXXX")"
        find "$scan_root" -maxdepth 6 -type d -name "$pattern_name" > "$tmp_results" 2>/dev/null || true

        while IFS= read -r found_dir; do
            [[ -z "$found_dir" ]] && continue

            if ! pattern_match_allowed "$pattern_name" "$found_dir"; then
                continue
            fi

            # Check if this path is under a pruned directory
            if is_pruned "$found_dir"; then
                log_info "  ${MSG_PRUNE_SKIP} ${found_dir}"
                continue
            fi

            if [[ "${MODE}" = "uninstall" ]]; then
                remove_exclusion "$found_dir"
            elif [[ "${MODE}" = "report-only" ]]; then
                TOTAL_CHECKED=$((TOTAL_CHECKED + 1))
                du_track_path "$found_dir"
                if cannot_privileged_tmutil "$found_dir"; then
                    TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))
                    add_report_line "SKIP  ${found_dir} (needs sudo for system path)"
                elif tm_is_excluded "$found_dir"; then
                    TOTAL_ALREADY=$((TOTAL_ALREADY + 1))
                    add_report_line "OK    ${found_dir} (excluded)"
                else
                    TOTAL_EXCLUDED=$((TOTAL_EXCLUDED + 1))
                    add_report_line "NEED  ${found_dir} (not excluded)"
                fi
            else
                apply_exclusion "$found_dir"
            fi
        done < "$tmp_results"
        rm -f "$tmp_results"
    done <<EOF
${CONF_PATTERNS}
EOF
}

apply_static_paths() {
    log_info ""
    log_info "${MSG_STATIC}"

    if [[ -z "${CONF_PATHS}" ]]; then
        return 0
    fi

    local static_path
    while IFS= read -r static_path; do
        [[ -z "$static_path" ]] && continue

        if [[ "${MODE}" = "uninstall" ]]; then
            remove_exclusion "$static_path"
        elif [[ "${MODE}" = "report-only" ]]; then
            TOTAL_CHECKED=$((TOTAL_CHECKED + 1))
            if [[ ! -e "$static_path" ]]; then
                TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))
                add_report_line "SKIP  ${static_path} (not found)"
            elif [[ -e "$static_path" ]]; then
                du_track_path "$static_path"
                if cannot_privileged_tmutil "$static_path"; then
                    TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))
                    add_report_line "SKIP  ${static_path} (needs sudo for system path)"
                elif tm_is_excluded "$static_path"; then
                    TOTAL_ALREADY=$((TOTAL_ALREADY + 1))
                    add_report_line "OK    ${static_path} (excluded)"
                else
                    TOTAL_EXCLUDED=$((TOTAL_EXCLUDED + 1))
                    add_report_line "NEED  ${static_path} (not excluded)"
                fi
            fi
        else
            apply_exclusion "$static_path"
        fi
    done <<EOF
${CONF_PATHS}
EOF
}

collect_post_scan_paths() {
    EXTRA_PATHS=""
    local line tmp

    if command -v brew >/dev/null 2>&1; then
        line="$(brew --cache 2>/dev/null)" || line=""
        if [[ -n "$line" && -e "$line" ]]; then
            EXTRA_PATHS="$line"
        fi
    fi

    tmp="$(mktemp "${TMPDIR:-/tmp}/tm_exc_disk.XXXXXX")"
    find "$HOME" \( -path '*/Mobile Documents/*' -o -path '*/Library/Mobile Documents/*' \) -prune -o \
        \( -type f \( -name '*.vmdk' -o -name '*.qcow2' -o -name '*.raw' -o -name '*.img' -o -name '*.sparsebundle' \) -size +512m \) -print 2>/dev/null | head -n 25 >>"$tmp" || true
    if [[ -d "${HOME}/Library" ]]; then
        find "${HOME}/Library" \( -path '*/Mobile Documents/*' \) -prune -o \
            \( -type f \( -name '*.vmdk' -o -name '*.qcow2' -o -name '*.raw' -o -name '*.img' -o -name '*.sparsebundle' \) -size +512m \) -print 2>/dev/null | head -n 25 >>"$tmp" || true
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        if [[ -z "${EXTRA_PATHS}" ]]; then
            EXTRA_PATHS="$line"
        else
            EXTRA_PATHS="${EXTRA_PATHS}
$line"
        fi
    done < "$tmp"
    rm -f "$tmp"
}

apply_extra_paths() {
    if [[ -z "${EXTRA_PATHS}" ]]; then
        return 0
    fi

    log_info ""
    log_info "${MSG_EXTRA_PATHS}"

    local extra_path
    while IFS= read -r extra_path; do
        [[ -z "$extra_path" ]] && continue

        if [[ "${MODE}" = "uninstall" ]]; then
            remove_exclusion "$extra_path"
        elif [[ "${MODE}" = "report-only" ]]; then
            TOTAL_CHECKED=$((TOTAL_CHECKED + 1))
            if [[ ! -e "$extra_path" ]]; then
                TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))
                add_report_line "SKIP  ${extra_path} (not found)"
            elif [[ -e "$extra_path" ]]; then
                du_track_path "$extra_path"
                if cannot_privileged_tmutil "$extra_path"; then
                    TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))
                    add_report_line "SKIP  ${extra_path} (needs sudo for system path)"
                elif tm_is_excluded "$extra_path"; then
                    TOTAL_ALREADY=$((TOTAL_ALREADY + 1))
                    add_report_line "OK    ${extra_path} (excluded)"
                else
                    TOTAL_EXCLUDED=$((TOTAL_EXCLUDED + 1))
                    add_report_line "NEED  ${extra_path} (not excluded)"
                fi
            fi
        else
            apply_exclusion "$extra_path"
        fi
    done <<EOF
${EXTRA_PATHS}
EOF
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
generate_report() {
    local report=""
    local dry_run_note=""
    local excluded_label="${MSG_REPORT_EXCLUDED}"
    local inv du_sec tm_list out_path path_total path_dirs p szk sh total_k desk_copy raw_list

    if [ "${DRY_RUN}" -eq 1 ]; then
        dry_run_note=" (dry-run)"
        excluded_label="${MSG_REPORT_WOULD_EXCLUDE}"
    fi

    inv="
=== Inventory (informational) ==="
    if [[ "${TM_EXCLUSIONS_SKIP_INVENTORY:-}" = "1" ]]; then
        inv="${inv}
(skipped: TM_EXCLUSIONS_SKIP_INVENTORY=1)"
    else
        if [[ -d /Applications ]]; then
            inv="${inv}
/Applications (top-level): $(find /Applications -maxdepth 1 -mindepth 1 2>/dev/null | wc -l | tr -d '[:space:]')"
        fi
        if command -v brew >/dev/null 2>&1; then
            inv="${inv}
Homebrew formulas: $(brew list --formula 2>/dev/null | wc -l | tr -d '[:space:]')"
            inv="${inv}
Homebrew casks: $(brew list --cask 2>/dev/null | wc -l | tr -d '[:space:]')"
        fi
        path_total="$(printf '%s' "${PATH:-}" | awk -F: '{print NF}')"
        path_dirs=0
        local oifs="${IFS}"
        IFS=':'
        for p in ${PATH:-}; do
            [[ -d "$p" ]] && path_dirs=$((path_dirs + 1))
        done
        IFS="${oifs}"
        inv="${inv}
PATH: ${path_dirs} existing directories (of ${path_total} colon-separated entries)"
    fi

    du_sec=""
    if [[ -n "${DU_PATHS}" ]]; then
        du_sec="
=== Disk usage (paths touched in this run, present on disk) ==="
        total_k=0
        while IFS= read -r p; do
            [[ -z "$p" || ! -e "$p" ]] && continue
            szk="$(du -sk "$p" 2>/dev/null | awk '{print $1}')"
            [[ -z "$szk" ]] && continue
            total_k=$((total_k + szk))
            sh="$(du -sh "$p" 2>/dev/null | awk '{print $1}')"
            du_sec="${du_sec}
${sh}	${p}"
        done <<EOF
${DU_PATHS}
EOF
        du_sec="${du_sec}
Total (sum of du -sk, KiB): ${total_k}
"
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
${MSG_REPORT_ERRORS} ${TOTAL_ERRORS}"

    if [[ "${MODE}" = "uninstall" ]]; then
        report="${report}
${MSG_REPORT_REMOVED} ${TOTAL_REMOVED}"
    fi

    report="${report}
${inv}"

    if [[ -n "${du_sec}" ]]; then
        report="${report}${du_sec}"
    fi

    if [[ -n "${REPORT_LINES}" ]]; then
        report="${report}

Details:
${REPORT_LINES}"
    fi

    tm_list=""
    if [[ "${HAS_TMUTIL}" -eq 1 ]]; then
        raw_list="$( { tmutil listexclusions 2>/dev/null || true; } | head -n 500)" || raw_list=""
        tm_list="
=== tmutil listexclusions (first 500 lines) ===
${raw_list}"
    fi
    report="${report}${tm_list}"

    echo ""
    echo "$report"

    out_path="${REPORT_FILE}"
    if [[ -n "${TM_EXCLUSIONS_REPORT:-}" ]]; then
        out_path="${TM_EXCLUSIONS_REPORT}"
    fi

    mkdir -p "$(dirname "${out_path}")" 2>/dev/null || true
    mkdir -p "${CUSTOM_CONF_DIR}" 2>/dev/null || true
    echo "$report" > "${out_path}" 2>/dev/null || true
    log_info ""
    log_info "${MSG_REPORT_SAVED} ${out_path}"

    if [[ "${TM_EXCLUSIONS_REPORT_DESKTOP:-}" = "1" ]]; then
        desk_copy="${HOME}/Desktop/tm-exclusions_last_report.txt"
        mkdir -p "${HOME}/Desktop" 2>/dev/null || true
        echo "$report" > "${desk_copy}" 2>/dev/null || true
        log_info "${MSG_REPORT_DESKTOP_COPY} ${desk_copy}"
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
    echo "${MSG_HELP_FORCE}"
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
                    LANG_OVERRIDE="$a2"
                    break
                fi
            done
            break
        fi
    done

    # Initialize language
    detect_language

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

    trap 'sudo_keepalive_stop' EXIT

    if [[ -n "${TM_EXCLUSIONS_DEBUG_FIFO:-}" ]]; then
        exec 5>>"${TM_EXCLUSIONS_DEBUG_FIFO}" && DEBUG_LOG_FD=1 || DEBUG_LOG_FD=0
    fi

    # Check environment
    check_environment

    # Load config
    load_config

    collect_post_scan_paths

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
}

main "$@"
