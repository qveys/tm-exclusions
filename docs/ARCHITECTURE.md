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
| `keep` | Protect a literal path and descendants across all modes; also block ancestor exclusions. Existing exclusions are reported, not automatically removed — except retired catalog exclusions (`migrate_retired_exclusions()`): the migration drops those before keeps are checked, so a `keep` below a retired path gets its parent exclusion removed, unless an active static `path` rule still asks for that path. |
| `setting` | Preference, not a Time Machine rule. Keys: `report_path` (saved report **file** path) and boolean `desktop_report` / `scan_images` (`true`/`1`/`yes` or `false`/`0`/`no`). Unknown keys and invalid `desktop_report` values warn on stderr and are ignored. |

## Scan Logic

Dynamic scanning walks `$HOME` with a single `find` — `-maxdepth 6` keeps execution time practical — that ORs every configured pattern into one expression: `find $HOME -maxdepth 6 -type d \( -name p1 -o -name p2 … \)`. One traversal of the tree discovers all patterns at once (#50), and the traversal itself is pruned in three layers (#13, see [Scan pruning layers](#scan-pruning-layers)) so subtrees whose matches would be discarded anyway are never walked. The `scan_dynamic_patterns()` function then uses a two-phase approach to collect and process matches:

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

## Scan pruning layers

The scan used to filter after discovery: `find` walked every directory under `$HOME` (down to depth 6) and the results were then dropped by the prune zones and the kept-prefix check. Since #13 the `find` expression itself stops descending where the post-filters are guaranteed to drop everything below, in three layers. Each layer only skips subtrees whose matches the filters would discard, so the set of excluded paths is identical to the full traversal; the post-filters (`pattern_match_allowed`, `is_pruned`, `keep_blocks`, `is_covered_by_kept`) are unchanged and stay as the safety net.

| Layer | Expression | Skips | Active |
|-------|------------|-------|--------|
| 1. Prune zones | `-path <zone> -print -prune` | everything under each existing `prune` zone (`~/Library`, `~/.bun`, the `.bak`/`.old` shadow copies, …) | all modes, including `--uninstall` |
| 2. Static exclusions | `-path <path> -prune` | everything under an existing `path` rule not blocked by a `keep` (the tree is excluded wholesale, so nested matches are redundant) | not in `--uninstall` |
| 3. Unconditional matches | `-name <pattern> -print -prune` | everything below a directory matched by a pattern with no match guard (e.g. below `node_modules`: `.pnpm/*/node_modules`) | not in `--uninstall`, and only when no `keep` rule exists |

- **Layer 1** prints each zone root once before pruning it; the scan reports one `Pruning (skipping scan of):` entry per zone root (and the grouped `Pruned:` counter counts zones). Before #13 it reported one entry per nested match, which the traversal no longer visits. The zone is still never excluded from Time Machine.
- **Layer 2** reuses the kept-file seed of the prefix-prune (#23): a static path seeded there already covers all of its descendants, so descending adds nothing. Static paths protected by (or protecting) a `keep` are not seeded and not pruned.
- **Layer 3** is limited to patterns that `pattern_match_allowed()` never rejects. Guarded patterns (`target`, `worktrees`, `site-packages`, `.gradle`, `venv`, `virtualenv`, listed in `pattern_is_guarded()`; a test keeps both lists in sync) may be dropped after discovery, so their subtrees keep being traversed. With any `keep` rule configured the layer is off: a `keep` decides per match whether a directory is excluded, so nothing can be assumed covered.
- `--uninstall` bypasses the kept-prefix filter on purpose (every nested exclusion added by older versions must be removed individually), so only layer 1 applies there.
- Only existing, shallow-enough (depth ≤ 6) directories that are not symbolic links become `-path` clauses; glob metacharacters in zone names are escaped. Anything else is simply handled by the post-filters.

`TM_EXCLUSIONS_NO_SCAN_PRUNE=1` disables all three layers (old full traversal, per-match prune entries). It exists to measure and to roll back.

Reproducible before/after numbers: `scripts/measure-scan.sh` builds a fake tree under a temporary `HOME` (stub `tmutil`, `--dry-run`), counts the directories `find` evaluates and the wall time with and without pruning, and checks that the processed paths are identical (`--baseline PATH` compares against another checkout's script). `tests/test_scan_pruning.sh` proves parity (same `tmutil` calls, same order, apply / `--uninstall` / `keep`) and that pruned subtrees are never visited.

## Prune Logic

Prune entries prevent the scanner from processing found directories under certain trees. For example, `prune|~/Library` prevents the tool from applying exclusions to `node_modules` directories inside `~/Library`, which are better handled by static path rules.

Prune does NOT apply a Time Machine exclusion. It only keeps the dynamic scan out of the zone: `find` does not descend into it (layer 1 above), and `is_pruned` remains as a post-filter for anything that still reaches it. Each zone root emits one `MSG_PRUNE_SKIP` log message; paths pruned by prefix are dropped silently.

Package-manager reinstalls often leave a sibling of a catalogued cache (e.g. `~/.bun.bak` next to `~/.bun`). Those trees are not covered by the live-path prune (`~/.bun` does not match `~/.bun.bak`), so the default catalog ships explicit prune zones for `.bak` / `.old` siblings of `.bun`, `.npm`, `.yarn`, `.pnpm-store`, and `.cargo` ([#25](https://github.com/qveys/tm-exclusions/issues/25)). This stops the `dist` / `node_modules` scan from emitting one exclusion per nested package without excluding the backup directory from Time Machine.

## Exclusion Application Strategy

For the static pass, `apply_static_paths()` indexes the first category and rule context for each path once, then processes `CONF_PATHS` in order. Duplicate paths keep the first rule's metadata. Report lines record rule context events in processing order, and `generate_report()` counts them in first-seen order.

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
- **Temporary file tracking**: All temporary files (dynamic scanning, disk inspection, space journal) are created by `make_tmp_file` inside one private work directory (`mktemp -d`, created on first use by `ensure_tmp_dir`) held in `TMP_DIR` and removed on normal completion or when receiving an interruption signal (only the exact `tm_exc_work.XXXXXX` path returned by `mktemp -d`; a `TMPDIR` containing a control character such as a newline falls back to `/tmp`, and `TMPDIR` is resolved once to its physical path so a symbolic link retargeted meanwhile cannot strand the directory). Around that single `mktemp -d`, `INT`/`TERM`/`HUP` are switched atomically to a recorder (the `mktemp` child ignores them), then the normal handlers are restored and a recorded signal is replayed to them (cleanup, exit `128+n`): no signal is lost and none can leave a loose `tm_exc_*` entry in `TMPDIR` (covered by `tests/test_tmp_signal.sh`).
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

`generate_report()` computes the "space excluded" figure once (`excl_space_display()` → `SPACE_EXCL_DISP`) and hands it to both the report counters and the interactive banner `ui_summary()`, so they always show the same text. `process_path()` records each newly excluded path (apply, `--dry-run` and `--report-only`) through `excl_track_path()` as one `<normalized path><TAB><complete KiB or empty>` line appended to a temporary file (`EXCL_FILE`, removed by the exit trap): the normalized path and size come from `path_size_column()` (`PATH_SIZE_NP`/`PATH_SIZE_KB`), nothing is concatenated in a shell variable (quadratic in Bash 3.2) and no `cd`, stat or cache lookup happens at that point; `du_track_path()` only normalizes each path once and appends it; `finalize_du_paths()` collapses duplicates and descendants in a single awk pass before the du summary is built. `excl_space_compute()` then aggregates in one pass without running `du`: awk builds `<ASCII-lowercased path>/<0x01><KiB>` keys, `LC_ALL=C sort` orders them (an ancestor sorts right before its descendants) and a second awk walks them with a stack of open ancestors (O(n log n); 6000 independent paths aggregate in well under a second on Bash 3.2). An entry is *measured* when its size is complete and *unmeasured* when `du` failed or was partial; nesting only prevents double counting — an entry is ignored when it lies under a *measured* entry, or (if itself unmeasured) under any unmeasured ancestor; a measured descendant of an unmeasured ancestor is kept as a lower-bound contribution, so a partially readable parent plus a readable 8M child shows `≥ 8.0M (partial, …)`, and `unknown` only when nothing usable was measured. Ancestors are decided by path prefix with ASCII case folded (`Cache` / `cache/Child` on default case-insensitive APFS count once; a boundary is a `/`, so `foo` is not an ancestor of `foo-bar`); entries with the same folded path count once. Unreadable or partial sizes (and names containing a newline, which the newline-delimited set cannot hold) are counted as unmeasured: the figure becomes `≥ <total of the measurable, non-overlapping entries> (partial, …)` or `unknown` when nothing usable was measured, never a false total. Labels: `MSG_UI_SPACE_EXCLUDED`, `MSG_UI_SPACE_SIMULATED` (`--dry-run`, with a "simulated" note), `MSG_UI_SPACE_NEEDED` (`--report-only`, unless `--dry-run` is also set: the simulated label is tested first); the figure is hidden in uninstall mode and with `TM_EXCLUSIONS_SKIP_DU=1`. The report file is written before the banner so the banner only advertises a file that exists. `format_size_kb()` promotes a value that would round to `1024.0` to the next unit (`1048575K` → `1.0G`). `--quiet` never prints the banner (`ui_summary()` also guards on it) and its stdout gains no line (it only benefits from the `format_size_kb` boundary fix): the space line is stripped from the quiet stdout report and kept in the report file. A `du` that exits non-zero but printed a size (unreadable children) is recorded with a `!` marker (`du_size_kb path mark`, `du_size_is_partial()`); per-path columns still show that partial size (#55) but the space figure counts it as unmeasured. `DU_SIZES` lines split at the last tab, so tabs in paths are safe; names with a newline skip `du` (`-`) and count as unmeasured — decided by `size_path_unsafe()` (size computation only, never called by the keep/exclusion/uninstall guards; `normalize_path()` is untouched): raw name with a newline, or — when a symlink or `..` is in the path — a physical resolution (`cd -P && pwd -P` with an `x` sentinel) containing one — or failing: a link/`..` path whose resolution fails is unmeasured, never measured through the raw path — e.g. an alias to `small<LF>`, which `$(...)` would otherwise collapse onto the neighbouring `small`. Ordinary paths are decided with builtins only (no subshell, no `cd`); there is no memo — `process_path` decides once per processed path into `SIZE_UNSAFE_NOW`, so an alias redirected between two rules is re-decided. The excluded-paths list reuses the normalized path and size `path_size_column` already computed (no second normalization, no extra lookup), so the dry-run cost in `cd -P` resolutions equals master's. `format_size_kb value floor` truncates for the `≥` lower bound. In `--dry-run` no mutation (`addexclusion`/`removeexclusion`) is issued, but the read-only status lookup (`isexcluded`) still runs. The verification tip is a real, `printf %q`-quoted path (`EXCL_FIRST_PATH`, else `TIP_PATH`).

Known limits of the space figure (#44), deliberately not hardened — it is a display value only: no exclusion, protection (`keep`) or uninstall decision reads it (it is computed in `generate_report()` and only printed in the banner and the report):
- It is the sum of the sizes of the *tracked paths*, minus overlap by path prefix (ASCII case folded). It does **not** detect aliases or hard links between different paths: a link to a file and its target are two measurements (`du -sk` measures the link itself), and two hard links to one file listed as separate paths are summed twice. Non-ASCII case differences (é/É) are not folded, and the case folding assumes the default macOS volumes (case-insensitive): on a case-sensitive volume, two rules targeting two paths that differ only by case are counted as one (undercount).
- In apply mode, a path that inherits an exclusion already set on its parent is not *newly excluded*, so the order of application can change the displayed lower bound.
- It assumes a stable tree while the run lasts: moving, re-linking or redirecting directories or symbolic links between two rules can distort it (double counting or omission). A link retargeted during `addexclusion` keeps the size of its previous target, and a path deleted after being measured stays counted.
- A path whose name contains a newline, or the byte 0x01 (the sort/awk field separator), is not supported by the aggregation: it is counted as unmeasured (no crash, cautious result).
- `normalize_path()` is unchanged from before #44: if `pwd -P` succeeds but plain `pwd` fails inside it (a simulated failure), the size code measures the raw link and may report `0K` as measured.

## Report Generation

After processing all paths, a human-readable report is saved; stdout receives a compact summary by default or the full plain report with `--verbose` / `--quiet`. The default file is `~/.config/tm_exclusions/last_report.txt`. The report includes:
- Hostname, user, program version, timestamp, and mode
- Counts: checked, newly excluded, already excluded, skipped, errors
- **Inventory** (optional): `/Applications` item count, installed `.app` bundles of `/Applications` and `~/Applications` (up to two levels deep, symbolic links followed, bundles not descended into; NUL-separated) with their `du -sh -H` size from one grouped `du` pass (`list_app_bundles()`, `build_apps_inventory()`; none found → localized notice), installed Homebrew casks and CLI formulae **listed by name** in blocks wrapped to the terminal width (report standard 80 otherwise, no trailing commas) when `brew` exists — a friendly notice is shown when it does not — plus PATH directory stats and a **CLI tools survey** of the PATH directories (`list_path_dirs()`, `list_dir_executables()`, `build_path_tools_inventory()`): standard system directories (`TM_EXCLUSIONS_SYSTEM_PATHS`, default `/bin:/sbin:/usr/bin:/usr/sbin`) are summarised by binary count, every other directory lists its executable names in wrapped blocks; empty/relative/missing/duplicate entries are ignored and each directory is read in one shell-glob pass (symbolic-link tools counted). The survey is also skipped by `--quiet`. Set **`TM_EXCLUSIONS_SKIP_INVENTORY=1`** to skip this block (faster smoke/CI; `brew list` and `du` over apps can be slow).
- **Disk usage**: `du -sk` per path touched in the run (existing paths only), formatted for display, and an approximate total in KiB. Sizes are measured once per path while it is processed (`path_size_column()` → `DU_SIZES`) and looked up again here (`du_size_lookup()`), so the report does not re-walk trees; only an unrecorded path falls back to a fresh `du`. `du_track_path()` removes nested entries when a parent is present, regardless of insertion order. Hard links and APFS clones can still affect estimates. `du_size_kb()` captures `du` independently of any pipeline so a non-zero exit from unreadable children (e.g. `/private/var/folders`) cannot trip `set -euo pipefail`. A cumulative formatted total (`MSG_REPORT_SIZE_TOTAL`, via `du_total_kb()`) is added to the counters block (#45).
- Per-path detail lines with source file/line, rule target and reason (including expanded path globs), or discovery origin
- A compact summary grouped by rule context, plus separate counts for missing paths and paths blocked by unavailable privileges

The report holds no `tmutil` listing: `tmutil` has no verb that lists exclusions (only `addexclusion`, `removeexclusion` and `isexcluded`), so the tool only ever calls those three. Missing configured paths are counted and retained in the
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
- Large disk images under **`$HOME`** in one `find` pass (covers `~/Library` too): files matching `.vmdk`, `.qcow2`, `.raw`, `.img`, `.iso`, `.ova` over **512 MiB** (`find -size +512M`); **VM bundle directories** `.sparsebundle`, `.utm`, `.vmwarevm`, `.parallels`, `.pvm` (`-type d`, any size, contents pruned so multi-part disks inside are not size-gated or double counted; a `keep` inside a bundle protects the whole bundle and its disks are not excluded individually); and **`.vbox` files** (the file itself; its folder instead when named after it, as in VirtualBox’s `<name>/<name>.vbox` layout, because the disks live there — never `$HOME`). Before the 50-result cap, exact duplicates and candidates under another candidate are dropped (sorted list, one pass; kept when the ancestor is protected by `keep`, and in `--uninstall`, where an older version may have excluded only the disk: no reduction, no pruning of UTM/VMware/Parallels bundles and a cap of 200 instead of 50 there) iCloud “Mobile Documents” and `Library/CloudStorage` trees are pruned so nothing is downloaded

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

`config/default.conf` contains 100+ active rules organized under `#@` category labels.
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
- The number of distinct `#@` category labels equals `EXPECTED_CATEGORY_COUNT` in the smoke test (a single constant that `scripts/add-category.sh` bumps).
- Three section banners present (`# ── STATIC EXCLUSIONS (path) ──`, `# ── DYNAMIC SCAN PATTERNS (pattern) ──`, `# ── SCAN PRUNE ZONES (prune) ──`); the smoke test matches them by prefix.
- No rule uses the `~/` home prefix (must be `$HOME/`).
- Every rule sits under a `#@` marker.
- HOME CoreSimulator is split into `Caches` / `Temp` / `Volumes` (Devices is opt-in) (no parent-tree rule); `/Library/Developer/CoreSimulator` stays whole-tree.

Adjusting the taxonomy therefore forces a coordinated update of the docs and the test thresholds.
