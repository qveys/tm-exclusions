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
  ├── collect_post_scan_paths()  ← brew --cache + large VM/disk images (deduped list)
  ├── apply_static_paths()       ← process 'path' entries
  ├── scan_dynamic_patterns()    ← process 'pattern' entries with find
  ├── apply_extra_paths()        ← apply paths from collect_post_scan_paths()
  └── generate_report()
```

## Config Merge Order

Configuration is loaded and merged in this order:
1. **Default rules** — resolved by `resolve_default_conf()`: if **`TM_EXCLUSIONS_DEFAULT_CONF`** is set, its value is used as the rules file path and resolution stops (absolute path recommended; relative paths are passed through as-is). Otherwise, fallback checks in order: repo-relative `config/default.conf`, `../share/tm-exclusions/default.conf` beside the installed binary, `/usr/local/share/tm-exclusions/default.conf`, `/opt/homebrew/share/tm-exclusions/default.conf`, `/usr/share/tm-exclusions/default.conf`.
2. `~/.config/tm_exclusions/custom.conf` — user-defined rules

Strings for **en** / **fr** are embedded in `tm_exclusions.sh` (not external locale files); see **`docs/I18N.md`**.

Later entries are appended; there is no override or deduplication. Both files use the same `type|target|reason` format.

Targets may use leading `~` (expanded to `$HOME`) or the literal substring `$HOME` (expanded at parse time).

## Config Entry Types

| Type | Behavior |
|---|---|
| `path` | Static exclusion: apply `tmutil addexclusion` to exact expanded path |
| `pattern` | Dynamic scan: `find $HOME -maxdepth 6 -type d -name <pattern>` and exclude matches |
| `prune` | Scan skip: paths under this prefix are ignored during dynamic pattern scanning (not excluded from backup) |

## Scan Logic

Dynamic scanning uses `find` from `$HOME` with `-maxdepth 6` to keep execution time practical. For each configured pattern name (e.g., `node_modules`), matching directories are collected and processed.

Matches named **`target`** are accepted only when the parent directory looks like a Rust/Cargo, Maven, or Gradle project (`Cargo.toml`, `pom.xml`, `build.gradle`, or `build.gradle.kts` next to the `target` directory). Matches named **`worktrees`** are narrowed to typical Git/Cursor layouts (e.g. under `.git/worktrees` or `.cursor`).

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

Paths **outside `$HOME`** (for example `/Applications`) use **`sudo tmutil … -p`** (privileged sticky exclusions). When stdin is not a TTY and there is no **passwordless sudo** cache (`sudo -n` fails), those paths are **skipped** with a clear log/report line so CI and automated smoke tests do not block on a sudo password.

### tmutil Wrappers

All `tmutil` interaction goes through wrapper functions (`tm_is_excluded`, `tm_add_exclusion`, `tm_remove_exclusion`). On non-macOS systems or when `tmutil` is absent, these functions simulate behavior (always report "not excluded," no-op on add/remove). This allows the tool to run its scan and config logic anywhere for testing.

A background **sudo credential refresh** loop may start when a privileged path is processed, mirroring long interactive runs.

### Note on Time Machine UI

Some exclusions applied via `tmutil addexclusion` (user-level "sticky" exclusions) may not be visible in System Settings > Time Machine. This is expected macOS behavior. Use `tmutil isexcluded <path>` to verify exclusion status.

## Report Generation

After processing all paths, a human-readable report is printed and saved to `~/.config/tm_exclusions/last_report.txt` by default. The report includes:
- Hostname, user, program version, timestamp, and mode
- Counts: checked, newly excluded, already excluded, skipped, errors
- **Inventory** (optional): `/Applications` item count, Homebrew formula/cask counts when `brew` exists, PATH directory stats. Set **`TM_EXCLUSIONS_SKIP_INVENTORY=1`** to skip this block (faster smoke/CI; `brew list` can be slow).
- **Disk usage**: `du -sh` per path touched in the run (existing paths only) and an approximate total in KiB
- Per-path detail lines
- When `tmutil` is available: an excerpt of **`tmutil listexclusions`** (first 500 lines)

**Report path overrides**

| Variable | Effect |
|----------|--------|
| `TM_EXCLUSIONS_REPORT` | Absolute or relative path for the saved report file instead of `~/.config/tm_exclusions/last_report.txt` |
| `TM_EXCLUSIONS_REPORT_DESKTOP=1` | Also write `~/Desktop/tm-exclusions_last_report.txt` |
| `TM_EXCLUSIONS_DEBUG_FIFO` | If set to a path, append the same `log_info` lines to **FD 5**. For a **named FIFO**, the script opens **read+write** (`exec 5<>`) so `open` does not block waiting for another process; regular files use append-only open. |

## First-run custom config

Before normal runs (default apply, `--dry-run`, `--report-only`, `--uninstall`) and before `--add` / `--list` / `--edit`, the tool ensures `~/.config/tm_exclusions/` exists and creates **`custom.conf`** from the same template as `--init` if the file is missing. This matches legacy “auto init” behavior.

## Discovered extra paths (`collect_post_scan_paths`)

Immediately after **`load_config()`** (and before static paths / dynamic scan), the tool builds **`EXTRA_PATHS`**:

- **`brew --cache`** when `brew` is on `PATH` and the cache directory exists
- Large disk images under **`$HOME`** in one `find` pass (covers `~/Library` too): files matching `.vmdk`, `.qcow2`, `.raw`, `.img` over **512 MiB** (`find -size +512M`), and **`.sparsebundle` directory bundles** (`-type d`), pruning iCloud “Mobile Documents” trees

Paths are **deduplicated** before `apply_extra_paths()` runs (after the pattern scan), which applies them like extra static rules.

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

Possible follow-ups:
- **tmux split-pane** or richer agent-oriented debug UX around `TM_EXCLUSIONS_DEBUG_FIFO`
- **Watch mode**: detect new regenerable directories and re-apply
- **Heavier inventory** (full app listings, full `brew list`, deep PATH enumeration) — intentionally capped today for speed

The current architecture (config-driven, function-based) supports these additions without major restructuring.

## Default rule catalog

`config/default.conf` ships approximately 102 rules organized in 17 categories. Categories use `#@CategoryName` markers — cosmetic in 1.x (treated as comments by the loader), forward-compatible with the category-aware report grouping tracked in [#34](https://github.com/qveys/tm-exclusions/issues/34).

| # | Category | Section(s) | Sample entries |
|---|---|---|---|
| 1 | Applications | path | `/Applications`, `$HOME/Applications` |
| 2 | Node.js / JavaScript | path + pattern | `$HOME/.npm`, `$HOME/.pnpm-store`, `node_modules`, `.next`, `.turbo` |
| 3 | Python | path + pattern | `$HOME/.cache/pip`, `$HOME/.pyenv/versions`, `.venv`, `__pycache__`, `.ruff_cache` |
| 4 | Docker | path | `$HOME/.docker`, `$HOME/Library/Containers/com.docker.docker` |
| 5 | Homebrew | path | `/opt/homebrew`, `/usr/local/Cellar`, `$HOME/Library/Caches/Homebrew` |
| 6 | Rust / Cargo | path + pattern | `$HOME/.cargo/registry`, `$HOME/.rustup/toolchains`, `target` |
| 7 | Java / JVM | path + pattern | `$HOME/.m2/repository`, `$HOME/.gradle/caches`, `.gradle` |
| 8 | Go | path | `$HOME/go/pkg/mod`, `$HOME/.cache/go-build` |
| 9 | Ruby / iOS | path + pattern | `$HOME/.rbenv/versions`, `$HOME/.cocoapods`, `Pods` |
| 10 | Xcode / Apple Dev Tools | path | `$HOME/Library/Developer/Xcode/DerivedData`, `…/CoreSimulator` |
| 11 | macOS Caches | path | `$HOME/Library/Caches`, `$HOME/Library/Logs` |
| 12 | Dev Tools | path | `$HOME/.terraform.d/plugin-cache`, IDE extensions and caches |
| 13 | AI / LLM | path | `$HOME/.cache/huggingface`, `$HOME/.ollama/models`, Claude VM bundles |
| 14 | App Support | path (opt-in) | Application Support entries for Cursor, JetBrains, Zed, … (commented out — see Opt-in entries) |
| 15 | Claude Code / Codex | pattern | `.auto-claude`, `.codex`, `worktrees` |
| 16 | Generic caches | pattern (opt-in) | `.cache` (commented out — uncomment to enable) |
| 17 | Prune zones | prune | `$HOME/Library`, `$HOME/.Trash`, `$HOME/.nvm`, … |

### Path style

Home-rooted paths use `$HOME/...`. The loader also accepts the legacy `~/...` form. System paths are absolute (`/Applications`, `/opt/homebrew`).

### Opt-in entries

Several entries ship commented out:
- `path|/private/var/folders` — already covered by macOS Time Machine StdExclusions; `du` on it can fail on partially-readable subdirs and aborts the script (see [#45](https://github.com/qveys/tm-exclusions/issues/45)).
- `path|$HOME/.docker` — kept in backups because it holds `config.json` (registry auth tokens). Bulky Docker data is covered by other rules.
- All `path|$HOME/Library/Application Support/<app>` entries (Antigravity, auto-claude-ui, Cursor, discord, GitKrakenCLI, JetBrains, virtualenv, vscode-sqltools, Zed) — these directories mix user data (settings, keymaps, sessions) with regenerable caches; re-enable selectively only after confirming the app's specific layout is cache-only.
- `pattern|.cache` — would match any project's `.cache/` directory (too broad as a default).
- `pattern|site-packages` — already covered by `.venv` patterns.

Uncomment them in your installed `default.conf` if you have specific use cases.

### Cloud-sync prunes

Pruning `$HOME/Dropbox`, `$HOME/Google Drive`, `$HOME/OneDrive` is **not** part of the default config — those directories typically contain non-regenerable user data, and pruning them at scan time risks masking caches/build artifacts that should be excluded. An opt-in mechanism is tracked in [#44](https://github.com/qveys/tm-exclusions/issues/44).

### Catalog invariants

The smoke test suite (`tests/smoke.bats-like.sh`) guards five invariants:
- ≥ 100 active rules (path/pattern/prune lines).
- Exactly 17 distinct `#@` category labels.
- Three section banners present (`# ── STATIC EXCLUSIONS (path) ──`, `# ── DYNAMIC SCAN PATTERNS (pattern) ──`, `# ── SCAN PRUNE ZONES (prune) ──`); the smoke test matches them by prefix.
- No rule uses the `~/` home prefix (must be `$HOME/`).
- Every rule sits under a `#@` marker.

Adjusting the taxonomy therefore forces a coordinated update of the docs and the test thresholds.
