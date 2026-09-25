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
  │   ├── parse_config_file(custom.conf)  [merged]
  │   └── parse_config_file($TM_EXCLUSIONS_EXTRA_CONF)  [optional, append]
  ├── collect_post_scan_paths()  ← brew --cache + opt-in VM/disk images (deduped list)
  ├── check_keeps()              ← flag existing exclusions on protected paths
  ├── apply_static_paths()       ← process 'path' entries
  ├── scan_dynamic_patterns()    ← process 'pattern' entries with find
  ├── apply_extra_paths()        ← apply paths from collect_post_scan_paths()
  └── generate_report()
```

## Config Merge Order

Configuration is loaded and merged in this order:
1. **Default rules** — resolved by `resolve_default_conf()`: if **`TM_EXCLUSIONS_DEFAULT_CONF`** is set, its value is used as the rules file path and resolution stops (absolute path recommended; relative paths are passed through as-is). Otherwise, fallback checks in order: repo-relative `config/default.conf`, `../share/tm-exclusions/default.conf` beside the installed binary, `/usr/local/share/tm-exclusions/default.conf`, `/opt/homebrew/share/tm-exclusions/default.conf`, `/usr/share/tm-exclusions/default.conf`.
2. `~/.config/tm_exclusions/custom.conf` — user-defined rules
3. (optional) `$TM_EXCLUSIONS_EXTRA_CONF` — additional additive config file

After all three config files are parsed, `derive_bak_old_prunes()` runs a one-time pass over `CONF_PATHS`. For every static `path|<P>` rule, it automatically appends `<P>.bak` and `<P>.old` to `CONF_PRUNES` (if not already present). This means common shadow copies produced by tool reinstalls or migrations (e.g. `.bun.bak`, `.npm.bak`, `.cargo.bak`) are silently skipped during the dynamic scan without requiring explicit catalog entries. Only `path|` entries trigger auto-derivation — `pattern|` and `prune|` entries are not processed. The auto-derived prune entries only affect `is_pruned()` / `scan_dynamic_patterns()`; `apply_static_paths()` is unchanged and will never call `tmutil addexclusion` on `.bak`/`.old` paths (which may not exist on most machines).

Strings for **en** / **fr** live in `locales/{en,fr}.sh`; see **`docs/I18N.md`**.

Later **rule** entries (`path` / `pattern` / `prune` / `keep`) are appended; there is no override or deduplication. **`setting`** lines are last-wins (a later file or later line replaces the earlier value for that key). Both files use the same `type|target|reason` format.

Targets may use leading `~` (expanded to `$HOME`) or the literal substring `$HOME` (expanded at parse time). For `setting|report_path|<file>`, those expansions apply to the **value** (third field). `path` targets may also contain glob metacharacters (`*`, `?`, `[`); they are expanded with `compgen -G` at load time. Unmatched globs are dropped so a literal `*` is never passed to `tmutil`. This is how versioned folders such as `$HOME/Library/Application Support/JetBrains/*/plugins` are covered without listing every IDE release.

## Config Entry Types

| Type | Behavior |
|---|---|
| `path` | Static exclusion: apply `tmutil addexclusion` to the expanded path (optional glob expansion at load time) |
| `pattern` | Dynamic scan: `find $HOME -maxdepth 6 -type d -name <pattern>` and exclude matches |
| `prune` | Scan skip: paths under this prefix are ignored during dynamic pattern scanning (not excluded from backup) |
| `keep` | Protect a literal path and descendants across all modes; also block ancestor exclusions. Existing exclusions are reported, not automatically removed. |
| `setting` | Preference, not a Time Machine rule. Keys: `report_path` (saved report **file** path) and boolean `desktop_report` / `scan_images` (`true`/`1`/`yes` or `false`/`0`/`no`). Unknown keys and invalid `desktop_report` values warn on stderr and are ignored. |

## Scan Logic

Dynamic scanning uses `find` from `$HOME` with `-maxdepth 6` to keep execution time practical. The `scan_dynamic_patterns()` function uses a two-phase approach to collect and process matches:

**Phase 1: Collect**  
For each configured pattern name (e.g., `node_modules`), `find` locates matching directories. Each match is tagged with its pattern name and written to a temporary file. All patterns are collected before any processing begins.

**Phase 2: Sort and process**  
The aggregated results are sorted lexically (`LC_ALL=C sort`). Because an ancestor path is always a strict string prefix of any descendant, this sort order guarantees parents precede their children. Each candidate is then processed in order:

1. Validate with `pattern_match_allowed` (e.g., **`target`** is accepted only when the parent directory looks like a Rust/Cargo, Maven, or Gradle project; **`worktrees`** is narrowed to typical Git/Cursor layouts).
2. Skip if the path falls under a config-level prune zone (`is_pruned` — logs `MSG_PRUNE_SKIP`).
3. Skip silently if the path is already covered by a previously-kept path (`is_covered_by_kept`). This prevents redundant exclusions for descendants of an already-excluded parent (e.g., if `~/Git/proj/node_modules` is kept, then `~/Git/proj/node_modules/.pnpm/foo/node_modules` is automatically skipped).
4. If the path passes all checks, record it in the kept-paths file and apply the exclusion.

**Kept-paths tracking**  
A temporary file (`kept_file`) tracks all paths that have been kept. This file is seeded with `CONF_PATHS` (static exclusions) at the start, so dynamic candidates falling under a static rule (e.g., `~/.npm/_npx/X/node_modules` under `~/.npm`) are also pruned. Each path that passes validation is appended to the kept-file before applying the exclusion, ensuring later matches in the same scan see it as already covered.

**Helper functions**  
- `path_under(descendant, ancestor)`: Returns 0 if `descendant` is the same as or under `ancestor`. Uses a quoted case pattern so paths with glob metacharacters (`*`, `[`, `?`) are matched literally.
- `is_covered_by_kept(check, kept_file)`: Returns 0 if `check` is covered by any entry in the kept-paths file (i.e., if any kept path is a prefix of `check`).

## Prune Logic

Prune entries prevent the scanner from processing found directories under certain trees. For example, `prune|~/Library` prevents the tool from applying exclusions to `node_modules` directories inside `~/Library`, which are better handled by static path rules.

Prune does NOT apply a Time Machine exclusion. It only filters the dynamic scan results. Within `scan_dynamic_patterns()`, the prune check (`is_pruned`) runs after `pattern_match_allowed` validation but before the prefix-prune (`is_covered_by_kept`). Paths under a prune zone emit a `MSG_PRUNE_SKIP` log message; paths pruned by prefix are dropped silently.

Package-manager reinstalls often leave a sibling of a catalogued cache (e.g. `~/.bun.bak` next to `~/.bun`). Those trees are not covered by the live-path prune (`~/.bun` does not match `~/.bun.bak`), so the default catalog ships explicit prune zones for `.bak` / `.old` siblings of `.bun`, `.npm`, `.yarn`, `.pnpm-store`, and `.cargo` ([#25](https://github.com/qveys/tm-exclusions/issues/25)). This stops the `dist` / `node_modules` scan from emitting one exclusion per nested package without excluding the backup directory from Time Machine.

## Exclusion Application Strategy

Static, dynamic and discovered paths share `process_path()`. For each path:
1. Reject keep-protected paths and ancestors; then check if the path exists on disk. If not, skip it.
2. Check `tmutil isexcluded`: 0 = excluded, 1 = included, 2 = unknown/error. Unknown status is an error and never permits a mutation; excluded paths are recorded as already excluded.
3. If not excluded, call `tmutil addexclusion` (or simulate in dry-run).
4. Record the result for the report.

This makes the tool **idempotent**: running it multiple times produces the same result.

Paths **outside `$HOME`** (for example `/Applications`) use **`sudo tmutil … -p`** (privileged sticky exclusions). When stdin is not a TTY and there is no **passwordless sudo** cache (`sudo -n` fails), those paths are **reported as errors** with exit 1 and a clear log/report line so CI and automated smoke tests do not block on a sudo password.

### tmutil Wrappers

All `tmutil` interaction goes through wrapper functions (`tm_is_excluded`, `tm_add_exclusion`, `tm_remove_exclusion`). On non-macOS systems or when `tmutil` is absent, these functions simulate behavior (always report "not excluded," no-op on add/remove). This allows the tool to run its scan and config logic anywhere for testing.

A background **sudo credential refresh** loop may start when a privileged path is processed, mirroring long interactive runs.

### Cleanup and Signal Traps

The tool traps `EXIT`, `INT` (SIGINT), `TERM` (SIGTERM), and `HUP` (SIGHUP) via `cleanup()` and `on_signal()`:
- **Temporary file tracking**: All temporary files created during dynamic scanning and disk inspection (`mktemp`) are registered in `TMP_FILES` and removed on normal completion or when receiving an interruption signal.
- **Sudo keepalive**: The background `sudo -n -v` keepalive loop is automatically terminated on exit or signal to prevent orphan background processes.
- **Signal propagation**: On trapped signals, cleanup executes and the signal is re-delivered to the process to preserve standard POSIX exit status.

### Note on Time Machine UI

Some exclusions applied via `tmutil addexclusion` (user-level "sticky" exclusions) may not be visible in System Settings > Time Machine. This is expected macOS behavior. Use `tmutil isexcluded <path>` to verify exclusion status.

## Terminal presentation

`init_ui()` enables presentation only for a TTY stdout, a non-dumb `TERM`,
non-quiet output and no non-empty `NO_COLOR`. Section headings and status logs
use ANSI colors and Unicode icons. `progress_start` / `progress_step` count
static rules, discovered extra paths, and completed dynamic scan patterns;
percentages describe work items, not time or discovered-directory counts.
Progress lines are cleared before messages and on cleanup; no cursor hiding or
background animation process is used. Opt-in image discovery streams visited directories and
matching images from one NUL-delimited `find` traversal. `show_scan_path()`
rewrites one status line, abbreviates HOME, sanitizes control characters and
truncates long paths to fit the terminal (allowing two cells per character).
The Homebrew lookup gets a waiting message before traversal starts. Only image
candidates count toward the 50-result cap; a 51st candidate produces a `LIMIT` report line. The stream is drained so genuine `find` failures remain detectable; sparsebundle contents and
iCloud subtrees remain pruned. Report preparation keeps a heading because its
total work is not known in advance.

Interactive runs print a compact localized summary instead of duplicating the
full report. The complete report is still saved unchanged. Plain output (including
`--quiet`) preserves the full report, and debug FD 5 receives undecorated messages.

## Report Generation

After processing all paths, a human-readable report is printed and saved. The default file is `~/.config/tm_exclusions/last_report.txt`. The report includes:
- Hostname, user, program version, timestamp, and mode
- Counts: checked, newly excluded, already excluded, skipped, errors
- **Inventory** (optional): `/Applications` item count, Homebrew formula/cask counts when `brew` exists, PATH directory stats. Set **`TM_EXCLUSIONS_SKIP_INVENTORY=1`** to skip this block (faster smoke/CI; `brew list` can be slow).
- **Disk usage**: `du -sk` per path touched in the run (existing paths only), formatted for display, and an approximate total in KiB. `du_track_path()` removes nested entries when a parent is present, regardless of insertion order. Hard links and APFS clones can still affect estimates. `du_size_kb()` captures `du` independently of any pipeline so a non-zero exit from unreadable children (e.g. `/private/var/folders`) cannot trip `set -euo pipefail`.
- Per-path detail lines with source file/line, rule target and reason (including expanded path globs), or discovery origin
- A compact summary grouped by rule context, plus separate counts for missing paths and paths blocked by unavailable privileges
- When `tmutil` is available: an excerpt of **`tmutil listexclusions`** (first 500 lines)

The `tmutil listexclusions` section always reports its status: `ok`, `empty`,
`failed (exit N)`, or `unavailable`. An empty result is therefore distinguishable
from a command failure. Missing configured paths are counted but omitted from the
long detail list; the rule summary remains available for them.

**Report path overrides** (precedence: CLI > environment > config `setting` > built-in default)

| Source | Effect |
|--------|--------|
| `setting\|report_path\|<file>` in config | Persistent primary report **file** path (`~` / `$HOME` expanded). Chosen over `report_dir` because `TM_EXCLUSIONS_REPORT` is already a file path, not a directory. |
| `TM_EXCLUSIONS_REPORT` | Absolute or relative path for the saved report file; overrides `setting\|report_path` |
| `setting\|desktop_report\|true` | Persistent opt-in for the Desktop copy at `~/Desktop/tm-exclusions_last_report.txt` |
| `--desktop-report` | CLI flag: always enables the Desktop copy (no `--no-desktop-report`) |
| `TM_EXCLUSIONS_REPORT_DESKTOP` | When **set**, overrides config: `1` enables the Desktop copy, any other value (including `0`) disables it |
| `TM_EXCLUSIONS_DEBUG_FIFO` | If set to a path, append the same `log_info` lines to **FD 5**. For a **named FIFO**, the script opens **read+write** (`exec 5<>`) so `open` does not block waiting for another process; regular files use append-only open. |

**Desktop report policy**: the Desktop copy is **off by default**. Enabling it on every run would clutter the user's Desktop during unattended cron/launchd executions. Opt in with `--desktop-report`, `TM_EXCLUSIONS_REPORT_DESKTOP=1`, or `setting|desktop_report|true` in `custom.conf`.

## First-run custom config

Before normal runs (default apply, `--dry-run`, `--report-only`, `--uninstall`) and before `--add` / `--list` / `--edit`, the tool ensures `~/.config/tm_exclusions/` exists and creates **`custom.conf`** from the same template as `--init` if the file is missing. This matches legacy “auto init” behavior.

When editing the config via `--edit`, `$EDITOR` (default: `vi`) is parsed into an argument array without `eval`, properly supporting multi-word commands (e.g. `code --wait`, `subl -w`, `nano -B`).

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

1. If `--lang en` or `--lang fr` is passed, use that language.
2. Otherwise, check locale env vars (`LC_ALL`, `LC_MESSAGES`, `LC_CTYPE`, then `LANG`).
3. Default to English.

Supported languages: English (`en`), French (`fr`). Unsupported `--lang` values
are not used to build `locales/<code>.sh` paths; i18n falls back to English so
`parse_args` can report `MSG_ERROR_INVALID_LANG` instead of a missing-file error.

i18n strings live in external files `locales/en.sh` and `locales/fr.sh`; the
matching `declare_i18n_<lang>` function is called after the file is sourced
(`load_i18n`). The `locales/` directory is located by `resolve_locales_dir()` —
via the `TM_EXCLUSIONS_LOCALES_DIR` env var (non-root), the source-checkout or
installed layouts relative to the script, or absolute Homebrew/system share
roots. Language detection runs before argument parsing to ensure error messages
are localized.

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

Smoke and safety tests inject fake `tmutil`, `brew` and `sudo` commands and use temporary HOME directories. `tests/test_safety.sh` exercises keep conflicts, mutation/status/scan failures, image opt-in/capping, provenance and nested disk totals without modifying host exclusions.

## Future Work (v2)

Possible follow-ups:
- **tmux split-pane** or richer agent-oriented debug UX around `TM_EXCLUSIONS_DEBUG_FIFO`
- **Watch mode**: detect new regenerable directories and re-apply
- **Heavier inventory** (full app listings, full `brew list`, deep PATH enumeration) — intentionally capped today for speed

The current architecture (config-driven, function-based) supports these additions without major restructuring.

## Default rule catalog

`config/default.conf` contains 100+ active rules organized under 17 category labels.
Mixed roots and generic `build`/`dist` patterns ship commented out as opt-in examples.
The active catalog keeps focused caches and dependencies. Docker state, `/opt/homebrew`,
Pulumi state, Xcode Archives, CoreSimulator Devices, IDE workspaceStorage, agent
sessions/worktrees and locally created Ollama models are not assumed regenerable.
Copy a commented rule to `custom.conf` to explicitly enable it.

### Protection and upgrades

`CONF_KEEPS` contains normalized literal paths. `keep_blocks()` compares candidates
in both directions (ancestor/descendant), resolving dot components and existing directory
symlinks. Protected static parents do not seed dynamic prefix suppression, allowing
unprotected sibling matches to be processed. `check_keeps()` reports already-excluded
existing targets (including inherited exclusions) as errors. It never removes them.
Missing keep targets are protected from future exclusions but cannot be checked with tmutil.
Malformed protection rules abort before exclusion processing.

The existing CoreSimulator parent migration is retained. Newly disabled catalog rules
and old image exclusions are **not automatically removed**: ownership is unknown.
Users must audit and remove those existing exclusions explicitly. `keep` cannot force
Time Machine to include a child of an excluded parent.

### Rule provenance and failures

`CONF_RULES` preserves expanded path targets or pattern/keep targets with config file,
line, original rule and reason. `set_rule_context()` selects the first matching rule's
provenance before processing. Identical duplicate rules therefore use the first source.
The report adds this context to action lines; discovered paths use a discovery label.

`record_error()` increments `TOTAL_ERRORS` and appends a diagnostic. Dynamic `find`
failures retain partial results but mark the scan incomplete. The final exit status is
1 when errors were recorded, including add/remove/status failures, required privileges,
keep conflicts, invalid keep rules and report persistence errors. A report-write error
is printed to stderr (and full results to stdout in terminal mode); an unwritable report
cannot contain its own persistence failure. Optional inventory remains informational.

`setting|scan_images|true` enables the otherwise disabled image scan. At most 50
candidates are processed; additional images produce a `LIMIT` line. The traversal is
still per-pattern for dynamic rules: this change does not implement the separate
single-traversal performance proposal.

### Cloud-sync prunes

Pruning `$HOME/Dropbox`, `$HOME/Google Drive`, `$HOME/OneDrive` is **not** part of the default config — those directories typically contain non-regenerable user data, and pruning them at scan time risks masking caches/build artifacts that should be excluded. An opt-in mechanism is available via `TM_EXCLUSIONS_EXTRA_CONF` (see [#17](https://github.com/qveys/tm-exclusions/issues/17)); point it at a copy of the example file to activate cloud-sync prunes.

The example file (`extra-prunes.example.conf`) ships in three locations depending on installation method:

| Installation | Location |
|---|---|
| Source checkout | `config/extra-prunes.example.conf` (repo root) |
| `make install` | `${SHARE_DIR}/extra-prunes.example.conf` (`SHARE_DIR` follows `PREFIX`: Homebrew share if writable, else `/usr/local/share/tm-exclusions/`) |
| `brew install tm-exclusions` | `$(brew --prefix)/share/tm-exclusions/extra-prunes.example.conf` |

The `TM_EXCLUSIONS_EXTRA_CONF` loader requires the value to be **both a regular file (`-f`) and readable (`-r`)**. A directory path, a missing path, or an unreadable path all trigger a stderr warning and continue; no silent no-op occurs.

### Catalog invariants

The smoke test suite (`tests/smoke.bats-like.sh`) guards these catalog invariants:
- ≥ 100 active rules (path/pattern/prune lines).
- Exactly 17 distinct `#@` category labels.
- Three section banners present (`# ── STATIC EXCLUSIONS (path) ──`, `# ── DYNAMIC SCAN PATTERNS (pattern) ──`, `# ── SCAN PRUNE ZONES (prune) ──`); the smoke test matches them by prefix.
- No rule uses the `~/` home prefix (must be `$HOME/`).
- Every rule sits under a `#@` marker.
- HOME CoreSimulator is split into `Caches` / `Temp` / `Volumes` (Devices is opt-in) (no parent-tree rule); `/Library/Developer/CoreSimulator` stays whole-tree.

Adjusting the taxonomy therefore forces a coordinated update of the docs and the test thresholds.
