# Architecture

## Overview

`tm-exclusions` is a single-file Bash CLI (`tm_exclusions.sh`) that manages macOS Time Machine exclusions for developer machines. It identifies regenerable content (caches, dependencies, build artifacts) and excludes them from backups via `tmutil`.

## Control Flow

```
main()
  ├── Pre-scan args for --lang and --quiet
  ├── detect_language()
  ├── parse_args()
  ├── Handle config commands (--init, --add, --list, --edit, --help, --version)
  ├── check_environment()
  ├── load_config()
  │   ├── parse_config_file(default.conf)
  │   └── parse_config_file(custom.conf)  [merged]
  ├── apply_static_paths()     ← process 'path' entries
  ├── scan_dynamic_patterns()  ← process 'pattern' entries with find
  └── generate_report()
```

## Config Merge Order

Configuration is loaded and merged in this order:
1. **Default rules** — resolved by `resolve_default_conf()`: if **`TM_EXCLUSIONS_DEFAULT_CONF`** is set, its value is used as the rules file path and resolution stops (absolute path recommended; relative paths are passed through as-is). Otherwise, fallback checks in order: repo-relative `config/default.conf`, `../share/tm-exclusions/default.conf` beside the installed binary, `/usr/local/share/tm-exclusions/default.conf`, `/opt/homebrew/share/tm-exclusions/default.conf`, `/usr/share/tm-exclusions/default.conf`.
2. `~/.config/tm_exclusions/custom.conf` — user-defined rules

Strings for **en** / **fr** are embedded in `tm_exclusions.sh` (not external locale files); see **`docs/I18N.md`**.

Later entries are appended; there is no override or deduplication. Both files use the same `type|target|reason` format.

## Config Entry Types

| Type | Behavior |
|---|---|
| `path` | Static exclusion: apply `tmutil addexclusion` to exact expanded path |
| `pattern` | Dynamic scan: `find $HOME -maxdepth 6 -type d -name <pattern>` and exclude matches |
| `prune` | Scan skip: paths under this prefix are ignored during dynamic pattern scanning (not excluded from backup) |

## Scan Logic

Dynamic scanning uses `find` from `$HOME` with `-maxdepth 6` to keep execution time practical. For each configured pattern name (e.g., `node_modules`), matching directories are collected and processed.

Before processing a found directory, it is checked against prune paths. If the directory falls under a pruned prefix, it is skipped silently (or with a log message).

## Prune Logic

Prune entries prevent the scanner from processing found directories under certain trees. For example, `prune|~/Library` prevents the tool from applying exclusions to `node_modules` directories inside `~/Library`, which are better handled by static path rules.

Prune does NOT apply a Time Machine exclusion. It only filters the dynamic scan results.

## Exclusion Application Strategy

For each path to exclude:
1. Check if the path exists on disk. If not, skip it.
2. Check if already excluded via `tmutil isexcluded`. If yes, record as "already excluded."
3. If not excluded, call `tmutil addexclusion` (or simulate in dry-run).
4. Record the result for the report.

This makes the tool **idempotent**: running it multiple times produces the same result.

### tmutil Wrappers

All `tmutil` interaction goes through wrapper functions (`tm_is_excluded`, `tm_add_exclusion`, `tm_remove_exclusion`). On non-macOS systems or when `tmutil` is absent, these functions simulate behavior (always report "not excluded," no-op on add/remove). This allows the tool to run its scan and config logic anywhere for testing.

### Note on Time Machine UI

Some exclusions applied via `tmutil addexclusion` (user-level "sticky" exclusions) may not be visible in System Settings > Time Machine. This is expected macOS behavior. Use `tmutil isexcluded <path>` to verify exclusion status.

## Report Generation

After processing all paths, a human-readable report is printed and saved to `~/.config/tm_exclusions/last_report.txt`. The report includes:
- Timestamp and mode
- Counts: checked, newly excluded, already excluded, skipped, errors
- Per-path detail lines

## Uninstall Behavior

`--uninstall` reverses applied exclusions:
- Iterates through the same static paths and dynamic patterns
- For each, calls `tmutil removeexclusion` instead of `addexclusion`
- Respects `--dry-run` and `--force`
- `--force` removes exclusions even if the path no longer exists

Uninstall is idempotent: removing a non-excluded path is a no-op.

## Language Detection / Override

1. If `--lang <code>` is passed, use that language.
2. Otherwise, check the `LANG` environment variable (e.g., `fr_FR.UTF-8` → French).
3. Default to English.

Supported languages: English (`en`), French (`fr`).

i18n is implemented as shell functions (`declare_i18n_en`, `declare_i18n_fr`) that set global message variables. Language detection runs before argument parsing to ensure error messages are localized.

## Testing Strategy

Tests are shell-based smoke tests in `tests/smoke.bats-like.sh` using helpers from `tests/test_helpers.sh`.

Tests validate:
- CLI flags and exit codes
- Help and version output
- Dry-run and report-only modes
- Invalid argument handling
- Config init, add, list commands
- Uninstall dry-run
- Language selection
- Config parsing with custom entries

Tests run without real `tmutil` mutations. On non-macOS systems (like CI runners), the tmutil wrappers simulate behavior, allowing full CLI testing.

## Future Work (v2)

Planned enhancements for future versions:
- **tmux dual-pane UI**: Live split-screen interface showing scan progress and exclusion status
- **Expanded rule sets**: Additional categories and more granular control
- **Watch mode**: Monitor for new regenerable directories and auto-exclude
- **Size estimation**: Show disk space impact of exclusions

These are **not implemented in v1**. The current architecture (config-driven, function-based) supports these additions without major restructuring.
