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
| `pattern` | Dynamic scan: a single `find $HOME -maxdepth 6 -type d \( -name <p1> -o -name <p2> … \)` over all patterns, then exclude matches |
| `prune` | Scan skip: paths under this prefix are ignored during dynamic pattern scanning (not excluded from backup) |
| `keep` | Protect a literal path and descendants across all modes; also block ancestor exclusions. Existing exclusions are reported, not automatically removed. |
| `setting` | Preference, not a Time Machine rule. Keys: `report_path` (saved report **file** path) and boolean `desktop_report` / `scan_images` (`true`/`1`/`yes` or `false`/`0`/`no`). Unknown keys and invalid `desktop_report` values warn on stderr and are ignored. |

## Scan Logic

Dynamic scanning walks `$HOME` with a single `find` — `-maxdepth 6` keeps execution time practical — that ORs every configured pattern into one expression: `find $HOME -maxdepth 6 -type d \( -name p1 -o -name p2 … \)`. One traversal of the tree discovers all patterns at once (#50); there is deliberately no `-prune`, because the old per-pattern walks kept descending into matched directories (nested matches such as `node_modules/.pnpm/*/node_modules` must still be discovered, notably in uninstall mode). The `scan_dynamic_patterns()` function then uses a two-phase approach to collect and process matches:

**Phase 1: Collect**  
The single consolidated `find` locates every directory matching any configured pattern. Each discovered directory is tagged with every configured pattern whose glob matches its basename (the same `(dir, pattern)` pairs the per-pattern `find -name <pattern>` calls produced), written tab-separated to a temporary file. All patterns are collected before any processing begins.

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

`log_path_result()` buffers presentation events separately from exclusion decisions
and report details. At each phase boundary, `flush_path_results()` emits them under
one `══ Category ══` header per category (`ui_category()`; categories in order of first
appearance, none under `--quiet`), then counts by action and natural root: `Git/<repo>`, a hidden `~/.tool`, or the matched
directory’s direct parent. Missing and already-excluded paths use counters without
path lists. Prune results are counted by root. Errors and privilege skips bypass
this buffer and remain individually visible on stderr.

Default output shows these groups and final counters, including when redirected.
`-v` / `--verbose` restores individual status lines and the plain full report.
Interactive runs retain their compact final summary; the informational inventory
(Homebrew cask/formula names included) is the exception and is also printed inline.
`--quiet` takes precedence:
no status lines, and the full report on stdout, as before. All modes save the same
complete report; if writing fails, compact output falls back to the full report.
Debug FD 5 receives undecorated console messages.

Verbose runs prefix every per-path status line with a formatted disk size
(#45): `process_path()` calls `path_size_column()`, which runs one `du -sk` per
existing path, records the KiB value in `DU_SIZES`, and returns a string that
`path_suffix()` right-aligns in a fixed 8-cell column before the path. Missing
or unreadable paths (including `du` failures) display `-` and never fail the
run. The measurement is reused by the report, so a tree is never walked twice.
`--quiet` keeps `log_info()` silent, so no per-path line (size included) is
printed; `TM_EXCLUSIONS_SKIP_DU=1` disables the column entirely. The interactive
summary (`ui_summary()`) and the report counters gain a cumulative
`MSG_REPORT_SIZE_TOTAL` line formatted by `format_size_kb()` over `du_total_kb()`.

### End-of-run banner and space excluded (#44)

`generate_report()` computes the "space excluded" figure once (`excl_space_display()` → `SPACE_EXCL_DISP`) and hands it to both the report counters and the interactive banner `ui_summary()`, so they always show the same text. `process_path()` records each newly excluded path (apply, `--dry-run` and `--report`) in `EXCL_PATHS` through `excl_track_path()` (shared nesting/dedupe logic `path_set_add()`, also used by `du_track_path()`); `excl_space_compute()` then sums the KiB already stored in `DU_SIZES` — it never runs `du` itself. Unreadable sizes (and names containing a newline, which the newline-delimited set cannot hold) are counted as unmeasured: the figure becomes `≥ <total> (partial, …)` or `unknown`, never a false total. Labels: `MSG_UI_SPACE_EXCLUDED`, `MSG_UI_SPACE_SIMULATED` (`--dry-run`, with a "simulated" note), `MSG_UI_SPACE_NEEDED` (`--report`); the figure is hidden in uninstall mode and with `TM_EXCLUSIONS_SKIP_DU=1`. The report file is written before the banner so the banner only advertises a file that exists. `format_size_kb()` promotes a value that would round to `1024.0` to the next unit (`1048575K` → `1.0G`). `--quiet` never prints the banner (`ui_summary()` also guards on it) and its stdout gains no line (it only benefits from the `format_size_kb` boundary fix): the space line is stripped from the quiet stdout report and kept in the report file. A `du` that exits non-zero but printed a size (unreadable children) is recorded with a `!` marker (`du_size_kb path mark`, `du_size_is_partial()`); per-path columns still show that partial size (#55) but the space figure counts it as unmeasured. `DU_SIZES` lines split at the last tab, so tabs in paths are safe; names with a newline skip `du` (`-`) and count as unmeasured — decided by `size_path_unsafe()` (size computation only, never called by the keep/exclusion/uninstall guards; `normalize_path()` is untouched): raw name with a newline, or — when a symlink or `..` is in the path — a physical resolution (`cd -P && pwd -P` with an `x` sentinel, failures propagated) containing one, e.g. an alias to `small<LF>`, which `$(...)` would otherwise collapse onto the neighbouring `small`. Ordinary paths are decided with builtins only (no subshell); the last answer is memoized. `format_size_kb value floor` truncates for the `≥` lower bound. In `--dry-run` no mutation (`addexclusion`/`removeexclusion`) is issued, but the read-only status lookups (`isexcluded`, `listexclusions`) still run. The verification tip is a real, `printf %q`-quoted path (`EXCL_FIRST_PATH`, else `TIP_PATH`).

## Report Generation

After processing all paths, a human-readable report is saved; stdout receives a compact summary by default or the full plain report with `--verbose` / `--quiet`. The default file is `~/.config/tm_exclusions/last_report.txt`. The report includes:
- Hostname, user, program version, timestamp, and mode
- Counts: checked, newly excluded, already excluded, skipped, errors
- **Inventory** (optional): `/Applications` item count, installed `.app` bundles of `/Applications` and `~/Applications` (up to two levels deep, symbolic links followed, bundles not descended into; NUL-separated) with their `du -sh -H` size from one grouped `du` pass (`list_app_bundles()`, `build_apps_inventory()`; none found → localized notice), installed Homebrew casks and CLI formulae **listed by name** in blocks wrapped to the terminal width (report standard 80 otherwise, no trailing commas) when `brew` exists — a friendly notice is shown when it does not — plus PATH directory stats and a **CLI tools survey** of the PATH directories (`list_path_dirs()`, `list_dir_executables()`, `build_path_tools_inventory()`): standard system directories (`TM_EXCLUSIONS_SYSTEM_PATHS`, default `/bin:/sbin:/usr/bin:/usr/sbin`) are summarised by binary count, every other directory lists its executable names in wrapped blocks; empty/relative/missing/duplicate entries are ignored and each directory is read in one shell-glob pass (symbolic-link tools counted). The survey is also skipped by `--quiet`. Set **`TM_EXCLUSIONS_SKIP_INVENTORY=1`** to skip this block (faster smoke/CI; `brew list` and `du` over apps can be slow).
- **Disk usage**: `du -sk` per path touched in the run (existing paths only), formatted for display, and an approximate total in KiB. Sizes are measured once per path while it is processed (`path_size_column()` → `DU_SIZES`) and looked up again here (`du_size_lookup()`), so the report does not re-walk trees; only an unrecorded path falls back to a fresh `du`. `du_track_path()` removes nested entries when a parent is present, regardless of insertion order. Hard links and APFS clones can still affect estimates. `du_size_kb()` captures `du` independently of any pipeline so a non-zero exit from unreadable children (e.g. `/private/var/folders`) cannot trip `set -euo pipefail`. A cumulative formatted total (`MSG_REPORT_SIZE_TOTAL`, via `du_total_kb()`) is added to the counters block (#45).
- Per-path detail lines with source file/line, rule target and reason (including expanded path globs), or discovery origin
- A compact summary grouped by rule context, plus separate counts for missing paths and paths blocked by unavailable privileges
- When `tmutil` is available: an excerpt of **`tmutil listexclusions`** (first 500 lines)

The `tmutil listexclusions` section always reports its status: `ok`, `empty`,
`failed (exit N)`, or `unavailable`. An empty result is therefore distinguishable
from a command failure. Missing configured paths are counted and retained in the
saved detail list with their rule context; default stdout only shows their count.

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
- **Heavier inventory** (recursive scans, tool versions) — intentionally capped today for speed; the PATH survey lists top-level executables only

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

### Category sections

`parse_config_file()` treats a `#@<Name>` line as a category marker (`parse_category_marker()`
trims it and neutralizes control characters and `|`); the rules that follow carry that
category in `CONF_RULES` (`type|target|category|context`). Each config file starts in
the default category, which is stored as the empty string and rendered with
`MSG_CATEGORY_DEFAULT`, so default and custom rules never inherit a section from another
file and `custom.conf` may define its own `#@MyCategory` sections. `set_rule_context()` sets
`RULE_CATEGORY` next to `RULE_CONTEXT`, and every site that clears one clears the other.
`add_report_line()` records each detail line twice: once in `REPORT_LINES` (unchanged) and
once in `REPORT_GROUPED` as `<category>\t<line>`; `group_report_details()` prints the
saved report's `Details:` block under `── Category ──` subheadings, categories in order of
first appearance and lines in processing order. Dynamic matches take the category of the
`pattern` rule that found them, so one scan can touch several categories; the ordering
of the scan itself (global path sort) is unchanged, only the output is grouped. Discovered
paths and retired exclusions use the default category.

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
for dynamic rules is a single traversal since
[#50](https://github.com/qveys/tm-exclusions/issues/50) (one consolidated `find`
with all patterns OR-ed together); the image scan above remains its own pass.

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
