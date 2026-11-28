<p align="center">
  <img src="https://img.icons8.com/color/96/time-machine.png" alt="Time Machine" width="80"/>
</p>

<h1 align="center">🛡️ tm-exclusions</h1>

<p align="center">
  <strong>Reclaim tens of GB from your Time Machine backups — automatically.</strong><br/>
  A smart macOS exclusion manager for developer machines.
</p>

<p align="center">
  <a href="https://github.com/qveys/tm-exclusions/actions/workflows/ci.yml"><img src="https://img.shields.io/github/check-runs/qveys/tm-exclusions/master?style=flat-square&nameFilter=Smoke%20tests&label=tests" alt="Tests"/></a>
  <a href="https://github.com/qveys/tm-exclusions/actions/workflows/ci.yml"><img src="https://img.shields.io/github/check-runs/qveys/tm-exclusions/master?style=flat-square&nameFilter=ShellCheck&label=shellcheck" alt="ShellCheck"/></a>
  <img src="https://img.shields.io/badge/bash-3.2%2B-green?style=flat-square&logo=gnubash&logoColor=white" alt="Bash 3.2+"/>
  <img src="https://img.shields.io/badge/macOS-compatible-black?style=flat-square&logo=apple&logoColor=white" alt="macOS"/>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/qveys/tm-exclusions?style=flat-square" alt="License"/></a>
</p>

---

## 🤔 Why?

Developer caches and downloaded dependencies can occupy many GB in backups.
The default catalog targets regenerable content. Mixed data directories, VM disks,
archives and agent sessions require an explicit choice because they can hold unique data.

- **Static exclusion rules** for known cache/artifact paths across multiple ecosystems
- **Dynamic scanning** to discover `node_modules`, `.venv`, `__pycache__`, and other regenerable directories
- **Prune support** to skip scanning irrelevant trees — `find` never descends into prune zones, known static exclusions or below matched directories (multi-layer scan pruning)
- **Dry-run mode** to preview changes without applying them
- **Report-only mode** to audit current exclusion status
- **Uninstall** to remove exclusions matching the current configured rules and discovered patterns
- **Idempotent** — safe to run repeatedly
- **Multilingual** — English and French output
- **Config management** — add custom rules, init/list/edit config
- **Human-readable reports** after each run (host/user/version, optional inventory, `du` summary)
- Reports group actions by rule and distinguish missing and privilege-blocked paths.

Optional environment variables (see **`docs/ARCHITECTURE.md`**): `TM_EXCLUSIONS_REPORT`, `TM_EXCLUSIONS_REPORT_DESKTOP`, `TM_EXCLUSIONS_SKIP_INVENTORY`, `TM_EXCLUSIONS_DEBUG_FIFO`.

Preview the selected exclusions with `tm-exclusions --dry-run` before applying them.

---

## 🎨 Terminal display

Interactive terminals get bold magenta headings, cyan progress bars, status colors, emojis, progress
bars and a final summary. A blank line separates status entries and groups related
counters in the summary. By default, exclusions and prune matches
are grouped by natural root (a `Git/<repo>`, a hidden `~/.tool`, or the matched
directory’s parent), under one `══ Category ══` header per `#@Category` section of
the config (`-v` and `--quiet` follow the same rules as below; `--quiet` prints no
headers). Missing paths and already-excluded paths use counters.
Errors and system-path privilege skips remain individually visible. Use
`-v` / `--verbose` for every path and its formatted on-disk size (`du -sk`, right-aligned in a fixed column; `-` when the
path is missing or unreadable), and the summary ends with a cumulative
`Usage disque total :` line. During cache and disk-image discovery, the
current directory updates (when `setting|scan_images|true` is enabled) on a single line (long paths show their tail).
During Homebrew cache lookup, directory-size measurement, the pattern scan and
inventory collection, a status line shows the current operation and elapsed seconds.
During the pattern scan, the status shows the latest result when available, then
the directory being classified or processed and its position in the sorted results.
The bar and activity text update on one line, including in narrow tmux panes. A moving marker indicates an unknown total;
percentages count completed rules or sorted candidates once the total is known. The inventory (including installed
Homebrew casks and CLI formulae, listed by name in wrapped blocks) is also shown
inline; disk usage and per-path details remain in the saved report, whose
location is printed at the end, with the detail lines grouped under `── Category ──`
subheadings.

```text
  🛡️  tm-exclusions  v1.3.0

  📁  Application des règles d’exclusion statiques...

  ~/Git/project → Seraient exclus : 12
  Chemins absents : 5 (chemins : -v)
  ━━━━━━━━━━━━━━━━━━━━ 100%  42/42

  📊  Bilan

  Chemins vérifiés : 42
  Seraient exclus : 12
  Déjà exclus : 25
  Ignorés : 5
  Chemins absents : 5
  Erreurs : 0
  Usage disque total : 2.0G
  Espace qui serait exclu (simulé) : 1.2G

  📄 Rapport sauvegardé dans : ~/.config/tm_exclusions/last_report.txt
  💡 Vérifier une exclusion avec : tmutil isexcluded /Users/me/Git/project/node_modules
```

The final summary is a banner: counters (newly excluded / already excluded / skipped / missing),
the cumulative disk usage of the touched paths, the **space excluded** by this run (sum of the
`du -sk` sizes already measured for the newly excluded paths, shown as KB/MB/GB; nested paths
counted once), the saved report path and a copy-pasteable `tmutil isexcluded '<first processed path>'` verification tip (shell-quoted real path). With
`--dry-run` the banner says the run is **simulated** (no exclusion added or removed — only the read-only `tmutil isexcluded` status lookups run — projected values); `--report-only`
labels the figure "space needing exclusion" unless `--dry-run` is also set (the simulated label then wins). If some sizes cannot be read (or `du` exits non-zero on unreadable children, so its total is partial) the figure is shown as
a lower bound (truncated, never rounded up) (`≥ 1.0M (partial, unmeasured paths: 1)`), or `unknown` when none could be read — never a false
total. Interactive terminals only: `--quiet`, pipes and `NO_COLOR` runs print no banner (`--quiet` stdout gains no line — the space line stays in the saved report — but it benefits from the size-formatting fix at unit boundaries, e.g. `1048575K` now prints `1.0G` instead of `1024.0M`;
the figure is in the saved report and, for non-quiet plain runs, in the printed counters), and `TM_EXCLUSIONS_SKIP_DU=1` hides the size figures.

Try `bash tm_exclusions.sh --dry-run --lang fr` in your terminal.
Pipes, redirected output, `TERM=dumb` and `NO_COLOR=1` use the same compact
output without decorations or progress updates; `--verbose` restores the full
plain report in these runs. `--quiet` keeps its existing behavior: no status
lines, but the full report on stdout. Saved reports retain every exclusion,
prune decision and missing path, regardless of verbosity. Saved reports and
debug logs always remain plain text. No extra dependencies are required.

## 🖥️ Two-pane tmux interface (`--tmux`)

On an **interactive terminal**, `--tmux` runs the tool inside a dedicated tmux
session with two panes: the left pane shows the normal progress/status view, the
right pane streams the debug log (the same `log_info` lines exposed by
`TM_EXCLUSIONS_DEBUG_FIFO` on FD 5). The session runs on its own private socket,
so it never touches an existing tmux session; both panes are removed when the
run ends.

- The flag only takes effect on an interactive TTY. With **stdout redirected**
  (a pipe, a file) or under **`--quiet`**, the option is ignored and the run
  behaves exactly as if `--tmux` had not been passed — no tmux is started.
- If **`tmux` is not installed**, or the interface cannot be started, the tool
  prints a notice on stderr and falls back to the normal run (same arguments,
  same exit status, one scan only). Once the session exists there is no
  fallback: a missing log pane keeps a single pane, and a lost client stops the
  run instead of scanning twice (its status is then 1).
- The log pane never takes the keyboard, so a `sudo` password typed in the
  interface is only echoed in the left pane.
- `Ctrl-C`/`SIGTERM` stop the run and clean up the dedicated server, session and
  socket immediately, even while the client is attached.
- The left pane runs the same script with the same arguments (minus `--tmux`),
  so the scan, exclusions and exit code are unchanged. The log pane is wired
  through the existing `TM_EXCLUSIONS_DEBUG_FIFO`/FD 5 mechanism, so a
  manually-set `TM_EXCLUSIONS_DEBUG_FIFO` is overridden in this mode.
- When the run finishes, the left pane keeps the final summary on screen and
  waits for a keypress before closing (set `TM_EXCLUSIONS_TMUX_NO_HOLD=1` to
  close immediately). The `TM_EXCLUSIONS_TMUX_BIN` variable can point at a
  specific `tmux` binary (escape hatch for unusual installs and tests).

```bash
tm-exclusions --tmux --dry-run
```

## ✨ Features

| | Feature | Details |
|---|---|---|
| 📦 | **Built-in rules** | 100+ active rules across the built-in categories, plus opt-in examples (Node.js, Python, Rust, Java, Xcode, AI/LLM, Docker, Homebrew, …) |
| 🔍 | **Dynamic scan** | Recursively finds `node_modules`, `.venv`, `__pycache__`, tool-specific build caches |
| 🔒 | **Dual tmutil strategy** | User paths via `tmutil addexclusion`; system paths via `sudo tmutil ... -p` |
| 🌍 | **Multilingual** | French / English (auto-detected from `$LANG`) |
| 📊 | **Rich report** | Saved report with counters/details (+ optional inventory and desktop copy) |
| 📏 | **Per-path sizes** | Formatted `du -sk` size next to each path with `--verbose` (`-` if missing/unreadable), plus a cumulative total |
| 🔄 | **Idempotent** | Safe to re-run — skips already-excluded paths |
| 🐚 | **Bash 3.2** | Works with macOS stock shell — no dependencies |


---

## 🚀 Quick Start

### Install

```bash
# Homebrew (recommended)
brew tap qveys/tools
brew install tm-exclusions

# Or from source
git clone https://github.com/qveys/tm-exclusions.git
cd tm-exclusions
make install
# PREFIX = Homebrew bin if writable, else /usr/local/bin (macOS admin prompt if needed)
# Or run directly: bash tm_exclusions.sh --dry-run
```

From a git checkout:

```bash
brew install --formula ./Formula/tm-exclusions.rb
```

### Run

```bash
tm-exclusions --dry-run      # 👀 Preview (no changes)
tm-exclusions                # 🛡️ Apply all exclusions
tm-exclusions --report-only  # 📊 Generate report only
tm-exclusions --lang en      # 🇬🇧 Force English
```

---

## 🏗️ How It Works

Config files are loaded, merged, then applied via a dual `tmutil` strategy (user paths under `$HOME`, fixed-path for system paths). Dynamic scan uses a single `find "$HOME" -maxdepth 6 -type d \( -name <p1> -o -name <p2> … \)` pass covering every configured pattern at once, and the traversal is pruned in three layers (configured `prune` zones, known static `path` exclusions, and the inside of already-matched directories) so those trees are never walked; results are identical to a full traversal. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full flowchart and details.

> 💡 Most exclusions won't appear in System Settings → Time Machine. They're still active — verify with `tmutil isexcluded ~/Library/Caches`

<details>
<summary>📦 <strong>Built-in Categories</strong> (see <code>config/default.conf</code> for the full list)</summary>

| Category | Examples |
|---|---|
| 🍎 **Applications** | Opt-in: `/Applications`, `$HOME/Applications` |
| 📗 **Node.js / JavaScript** | npm/yarn/pnpm caches (incl. `~/Library/pnpm/store`), Bun package cache, nvm per-version `lib`/`bin` (not `etc/npmrc`), Puppeteer downloads; opt-in whole `.bun` and `.nvm` roots;  dynamic `node_modules`, `.next`, `.turbo`, `.parcel-cache`, `.output` (only with the Nitro `nitro.json` marker) |
| 🐍 **Python** | pip/pipx/uv caches, uv Python builds and tools, Python environments; opt-in mixed uv/conda roots; dynamic `.venv`, `venv` (real environments only), `__pycache__`, `.pytest_cache`, `.ruff_cache` |
| 🐳 **Docker** | Opt-in Docker Desktop data (may contain databases and persistent volumes) |
| 🍺 **Homebrew** | `Cellar` and `Caskroom` under `/opt/homebrew` and `/usr/local`, and discovered `brew --cache`; the whole `/opt/homebrew` is opt-in (includes `etc` and `var`) |
| 🦀 **Rust / Cargo** | Cargo registry/git, rustup toolchains; dynamic `target` |
| ☕ **Java / JVM** | Maven, Gradle, Ivy and Coursier caches; opt-in SBT root; dynamic `.gradle` (project caches only, never `~/.gradle`) |
| 🤖 **Android** | Android SDK, tooling cache; emulator images (`~/.android/avd`) are opt-in |
| 🐹 **Go** | Go module cache, build cache |
| 💎 **Ruby / iOS** | rbenv; opt-in mixed RVM/gems/CocoaPods roots; dynamic `Pods` (next to a `Podfile` or `Podfile.lock`) |
| 🔨 **Xcode / Apple Dev Tools** | DerivedData, DeviceSupport, CoreSimulator Caches/Temp/Volumes; Archives and Devices are opt-in |
| 🗄️ **macOS Caches** | `~/Library/Caches`, `/private/var/folders`; Logs are opt-in |
| 🛠️ **Dev Tools** | IDE caches (JetBrains, VS Code), Terraform and kubectl caches; mixed Pulumi/Helm roots are opt-in |
| 🤖 **AI / LLM** | Hugging Face Hub and Xet caches, LM Studio, Claude VM base image (`rootfs.img`), SuperWhisper; Ollama models and agent sessions are opt-in |
| 🧰 **IDE and Dev Tool Caches** | Selective Application Support caches: Cursor and VS Code Chromium caches, versioned JetBrains IDE plugins, Zed languages, Discord Cache, … |
| 🤝 **Claude Code / Codex** | Opt-in `.auto-claude`, `.codex`, `worktrees` (may contain uncommitted work and settings) |
| 🧼 **Generic caches** | (opt-in — see config) Pattern `.cache` |
| 🚫 **Prune zones** | Skip-scan-only: `~/Library`, `~/.Trash`, `~/.bun`, `~/.nvm`, package-manager `.bak`/`.old` shadow copies (`.bun.bak`, `.npm.bak`, …) |

</details>

---

## 📋 Usage

```
Usage: tm_exclusions.sh [OPTIONS]

Run modes:
  (none)           Apply all exclusions
  --dry-run        Preview without modifying anything
  --report-only    Generate report only

Persistent config file management:
  --add <type> <path> <reason>     Add an entry
  --list                           Show current config
  --edit                           Open in $EDITOR
  --init                           Create user config

Uninstall (idempotent — missing xattrs/paths silently skipped):
  --uninstall      Remove exclusions matching current rules (except keep paths)
  --uninstall --force   Also remove matching paths that no longer exist
  --uninstall --dry-run Preview what would be removed

Other:
  --verbose, -v    Show each path instead of grouped summaries
  --quiet, -q      Quiet mode (no banner, no colors, no spinners)
  --desktop-report Write a report copy to ~/Desktop (default: off; avoids clutter on cron/launchd runs)
  --tmux           Two-pane tmux interface (progress/status + debug log stream; requires tmux)
  --version        Show version
  --lang <fr|en>   Force language
  --help           Show help
```

---

## ⚙️ Configuration

The script loads two config files in order:

```
1️⃣  config/default.conf              ← Built-in rules (shipped)
2️⃣  ~/.config/tm_exclusions/custom.conf  ← Your additions (auto-created)
```

### Config format

```conf
# type|target|reason
#@Section Name
path|$HOME/.deno|Deno cache — reinstallable
pattern|.gradle|Gradle project cache
prune|$HOME/VMs
setting|report_path|~/Documents/tm-exclusions-last.txt
setting|desktop_report|true
```

| Type | Effect |
|---|---|
| `path` | 🎯 Static exclusion → `tmutil addexclusion` (targets may include `*` `?` `[` globs, expanded at load time) |
| `pattern` | 🔍 Directory name matched by `find -name` during scan |
| `prune` | ✂️ Path ignored by scan (no TM exclusion applied) |
| `keep` | Protect a literal path and its descendants; blocks exclusions of ancestors too |
| `setting` | ⚙️ Preference (`report_path`, `desktop_report`, `scan_images`); not a Time Machine rule |

### Category sections

A `#@<Category>` line starts a section: the `path`, `pattern` and `keep` rules that
follow belong to that category until the next marker. Console output and the report
group their results by category. Rules placed before the first marker of a file (and
a bare `#@`) use the default category (`Uncategorized` / `Sans catégorie`); each config
file starts in the default category, so a section of `default.conf` never leaks into
`custom.conf`. Add your own sections to `~/.config/tm_exclusions/custom.conf`:

```conf
#@MyCategory
path|~/MyLargeDataset|Large dataset not needed in backup
```

Rules added with `--add` are appended at the end of the file and therefore join its
last section.

### Protect data and choose broader exclusions

```conf
keep|~/VMs|VMs contain persistent data
keep|~/.codex|Agent settings and sessions
# Optional: only enable if you can regenerate every discovered image.
setting|scan_images|true
```

`keep` accepts literal absolute paths, `~` and `$HOME` (no glob expansion).
It protects the path and descendants in apply, dry-run, audit and uninstall modes,
including discovered images. An exclusion of an ancestor is skipped as well; other
sibling rules can still apply. Dot components and existing directory symlinks are resolved.
Unlike `prune`, it applies to static rules and discovery as well as dynamic matches.
Use `tm-exclusions --add keep ~/VMs "VM data"` to add a protection.

`keep` does **not** remove existing exclusions. If its existing target is still
excluded, the report flags the conflict and the command exits 1. Check the target
and its parents with `tmutil isexcluded`, then remove the relevant exclusion manually.
For a missing target, only future exclusions by this tool are prevented.

Mixed roots (Docker data, `/opt/homebrew`, `.pulumi`, Xcode Archives, simulator
Devices, IDE workspaceStorage, agent directories) and generic `build`/`dist`
patterns now ship commented out. Copy individual rules from `config/default.conf`
to `custom.conf` if needed. An upgrade does not remove previously applied exclusions
for these paths or old discovered images: review them explicitly before relying on backups.

The built-in rules also cover npm's `_cacache` and `_npx` under `~/.cache/npm`,
the pnpm store under `~/.local/share/pnpm`, and Gradle's `caches` and `wrapper`
under `~/.local/share/gradle`. JetBrains Toolbox plugin settings stay eligible
for backup. The next apply retires the old exclusion on `Toolbox/plugins` unless
an explicit path rule still selects it.

On the next apply, tm-exclusions removes legacy whole-directory exclusions for
`~/.cache/huggingface` and `~/Library/Application Support/Claude/vm_bundles`
unless an explicit path rule still selects them. The default catalog leaves Hugging
Face credentials and Claude VM session data eligible for backup. If you enable
image discovery, add this rule to protect the session disk as it grows:

```text
keep|$HOME/Library/Application Support/Claude/vm_bundles/claudevm.bundle/sessiondata.img|Claude VM session data
```

Developer-directory and image scans skip Photos library packages (`*.photoslibrary`). A failed directory walk reports its first filesystem diagnostic once and retains partial results.

Image discovery is off by default. With `scan_images=true`, it considers at most
50 candidates: VM bundle directories (`.sparsebundle`, `.utm`, `.vmwarevm`,
`.parallels`, `.pvm`) of any size, whose contents are not walked (a `keep` inside a VM bundle protects the whole bundle; its disks are not excluded individually); `.vmdk`/`.qcow2`/
`.raw`/`.img`/`.iso`/`.ova` files larger than 512 MiB; and `.vbox` files (the
whole folder when it is named after the file, as in `<name>/<name>.vbox`, never
`$HOME` itself). Duplicates and candidates already inside another candidate are
dropped before the cap (unless that candidate is protected by a `keep`). iCloud `Mobile Documents` and
`Library/CloudStorage` trees are skipped so nothing is downloaded. Discovered paths
appear in the report as `Discovery: …`. Extra candidates are disclosed as `LIMIT` in the report. This is a cap
on processed images, not traversal time. `scan_images=false` disables it again.
Candidate paths containing a newline are rejected and reported, because the
candidate list is newline-delimited.

### Results and exit codes

Exit 0 means processing completed without recorded errors; exit 1 means a failed
operation, unknown exclusion status, unavailable required privileges, incomplete scan,
invalid protection rule, keep conflict, or failed report write. Partial scan results
are still processed and reported. An unknown `tmutil isexcluded` result never permits
an add/remove, even with `--force`. Missing paths remain ordinary skips.

Report details include the source config file and line, matching rule and reason.
For discovery, the origin is indicated instead. Disk totals omit nested paths already
covered by a parent; they remain approximate disk usage, not guaranteed backup savings
(hard links, APFS clones and partial `du` totals can affect estimates).

### Report destination preference

Put these in `~/.config/tm_exclusions/custom.conf` so launchd/cron runs pick them up without extra flags or env vars:

```conf
# Primary saved report file (same idea as TM_EXCLUSIONS_REPORT — a file path, not a directory)
setting|report_path|~/Documents/tm-exclusions-last.txt
# Also copy the report to ~/Desktop/tm-exclusions_last_report.txt
setting|desktop_report|true
```

`report_path` is a **file** path (`~/` and `$HOME` expand like other config targets). `desktop_report` accepts `true`/`1`/`yes` or `false`/`0`/`no`. Later config files override earlier `setting` lines (last wins); rule types (`path`/`pattern`/`prune`/`keep`) still append; `keep` always wins.

**Precedence** (highest first):

1. CLI (`--desktop-report` enables the Desktop copy; there is no CLI flag for the primary file path)
2. Environment (`TM_EXCLUSIONS_REPORT`, `TM_EXCLUSIONS_REPORT_DESKTOP`) — when the env var is set, it overrides config, including `TM_EXCLUSIONS_REPORT_DESKTOP=0` to force the Desktop copy off
3. Config `setting|…` lines
4. Built-in default: `~/.config/tm_exclusions/last_report.txt` (Desktop copy off)

`--add` accepts `path`, `pattern`, `prune`, and `keep`. Add `setting` lines with `--edit` or by editing `custom.conf`.

### Add custom exclusions

```bash
# 🎯 Exclude a specific directory
tm-exclusions --add path ~/.deno "Deno cache — reinstallable"

# 🔍 Add a pattern for dynamic scan
tm-exclusions --add pattern .angular "Angular CLI cache"

# ✂️ Ignore a directory during scan
tm-exclusions --add prune ~/VMs "Skip dynamic matches"
```

### Power users: cloud-sync prune opt-in

If you have a massive cloud-sync tree (Dropbox, Google Drive, OneDrive) and want dynamic-scan results under those roots to be skipped, use **`TM_EXCLUSIONS_EXTRA_CONF`**:

```bash
# 1. Copy the example file to your preferred location.
#    The example file location depends on how you installed tm-exclusions:
#
#    From a source checkout:
#      config/extra-prunes.example.conf
#
#    From `brew install tm-exclusions`:
#      $(brew --prefix)/share/tm-exclusions/extra-prunes.example.conf
#
#    From `make install` (Homebrew prefix if writable, else /usr/local):
#      $(PREFIX)/../share/tm-exclusions/extra-prunes.example.conf
#      e.g. /opt/homebrew/share/tm-exclusions/extra-prunes.example.conf

# If PREFIX isn't on PATH (e.g. a custom `make install PREFIX=...`),
# `command -v` finds nothing and SHARE_DIR below is wrong — replace it
# with the absolute path, e.g. SHARE_DIR="/custom/prefix/share/tm-exclusions".
SHARE_DIR="$(dirname "$(command -v tm-exclusions)")/../share/tm-exclusions"
cp "$SHARE_DIR/extra-prunes.example.conf" \
   ~/.config/tm_exclusions/extra.conf

# 2. Uncomment the prune lines that apply to your setup (editor of your choice):
#    prune|$HOME/Dropbox|...
#    prune|$HOME/Google Drive|...
#    prune|$HOME/OneDrive|...

# 3. Point the env var at your file (add to ~/.zshrc or ~/.bash_profile):
export TM_EXCLUSIONS_EXTRA_CONF=~/.config/tm_exclusions/extra.conf
```

The extra config is loaded **after** `default.conf` and `custom.conf`, so entries there are additive. If the file is missing or unreadable a warning is printed to stderr and the script continues normally.

> `config/default.conf` intentionally does **not** include cloud-sync prunes — those trees contain user data that you may want backed up.

---

## 🔇 Quiet Mode (cron / launchd)

Use `--quiet` (or `-q`) for unattended execution:

- No banner, no colors, no spinners, no tmux
- No per-path status lines and no size column
- Report is still printed to stdout (summary/report output is not suppressed)
- Desktop report copy is **off by default** — opt in with `--desktop-report`, `TM_EXCLUSIONS_REPORT_DESKTOP=1`, or `setting|desktop_report|true` in `custom.conf`

Both cron and launchd need the absolute install path — run `command -v tm-exclusions` and substitute it below (the example uses the Apple Silicon Homebrew path).

```bash
# Weekly cron job
0 3 * * 0  /opt/homebrew/bin/tm-exclusions --quiet 2>>/tmp/tm_exclusions.err
```

<details>
<summary>📄 launchd plist example</summary>

Save as `~/Library/LaunchAgents/com.tm-exclusions.weekly.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.tm-exclusions.weekly</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>/opt/homebrew/bin/tm-exclusions</string>
    <string>--quiet</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Weekday</key>
    <integer>0</integer>
    <key>Hour</key>
    <integer>3</integer>
    <key>Minute</key>
    <integer>0</integer>
  </dict>
  <key>StandardErrorPath</key>
  <string>/tmp/tm_exclusions.err</string>
</dict>
</plist>
```

```bash
launchctl load ~/Library/LaunchAgents/com.tm-exclusions.weekly.plist
```

</details>

---

## 📋 Requirements

| Requirement | Details |
|---|---|
| 🍎 macOS | Any version with Time Machine |
| 🐚 Bash | 3.2+ (macOS stock) |
| 🔑 sudo | Optional — for system path exclusions |

---

## 🔧 Environment variables

| Variable | Effect |
|---|---|
| `TM_EXCLUSIONS_DEFAULT_CONF` | Override default rules file path |
| `TM_EXCLUSIONS_EXTRA_CONF` | Load an additional config file after default + custom (opt-in cloud-sync prunes, see [Power users](#power-users-cloud-sync-prune-opt-in)) |
| `TM_EXCLUSIONS_REPORT` | Override report output path (overrides `setting|report_path`) |
| `TM_EXCLUSIONS_REPORT_DESKTOP=1` | Also write a report copy to `~/Desktop` (opt-in; equivalent to `--desktop-report`; overrides `setting|desktop_report`) |
| `TM_EXCLUSIONS_SKIP_INVENTORY=1` | Skip inventory block (installed apps with sizes, Homebrew, PATH and its CLI tools survey) in report |
| `TM_EXCLUSIONS_SYSTEM_PATHS` | Colon-separated PATH directories treated as system (count only) in the PATH tools survey; default `/bin:/sbin:/usr/bin:/usr/sbin` |
| `TM_EXCLUSIONS_SKIP_DU=1` | Skip the per-path `du` size column and the disk-usage section in the report |
| `TM_EXCLUSIONS_DEBUG_FIFO` | Mirror `log_info` output to FD 5 |
| `TM_EXCLUSIONS_TMUX_BIN` | Use this exact `tmux` binary for `--tmux` (escape hatch for unusual installs and tests; a missing/non-executable path forces the fallback) |
| `TM_EXCLUSIONS_TMUX_NO_HOLD=1` | Close the `--tmux` panes immediately at the end instead of waiting for a keypress |

---

## 🔎 Current behavior notes

- Status checks, including dry-run and report-only, read system paths with unprivileged `tmutil isexcluded`. In non-interactive runs without cached/passwordless sudo (`sudo -n`), each required system-path change is recorded as a privilege-blocked entry in the report and counted, so the run exits non-zero (see [Results and exit codes](#results-and-exit-codes)). No blocking prompt is ever shown. Privileged exclusions such as `/private/var/folders` use `sudo tmutil addexclusion -p` when credentials are available.
- Report disk-usage uses `du -sk` and ignores permission-denied children, so partially-readable trees like `/private/var/folders` cannot abort a run under `set -euo pipefail`.
- Verbose runs show a right-aligned, human-readable size (e.g. `1.0G`) next to each processed path; missing or unreadable paths show `-` without failing, and the summary/report gain a cumulative `Disk usage total:` line. Each path is measured once (`du -sk`) and the report reuses that measurement, so trees are never walked twice. `--quiet` adds no per-path lines; `TM_EXCLUSIONS_SKIP_DU=1` disables the size column as well.
- Reports include a rule summary, separate missing-path and privilege-blocked counts.
- `--uninstall` removes exclusions matching current configured static rules, dynamic matches, and discovered extra paths. It also drops retired catalog paths that are still excluded (today: the former `$HOME/Library/Developer/CoreSimulator` parent, and `$HOME/.gradle`, which the `.gradle` pattern used to match as a whole).
- Apply and `--dry-run` drop those same retired exclusions when `tmutil` still has them, then add the granular rules (CoreSimulator subdirs, `~/.gradle/caches` and `~/.gradle/wrapper`); `--dry-run` only reports the removal. A retired path you still exclude with your own `path` rule is not migrated (`--uninstall` still removes it, like any static rule), and a `keep` rule below a retired path never blocks its removal. Manual equivalent: `tmutil removeexclusion "$HOME/Library/Developer/CoreSimulator"` and `tmutil removeexclusion "$HOME/.gradle"`.
- Dynamic scan depth is intentionally capped to `find -maxdepth 6`.
- Default stdout shows grouped results and counters. `--verbose` adds per-path status lines; in plain output it also prints the full report. `--quiet` continues to print the full report without status lines and takes precedence over `--verbose`. The full report is always saved.
- On non-macOS or without `tmutil`, behavior is simulated (useful for tests).

---

## 🧪 Development

```bash
make test     # Run all test suites, including the PTY and tmux cases when available
make test-summary  # Same suites, quiet: totals + only the failed assertions (nonzero on failure)
make lint     # ShellCheck on all .sh files
make check-conf  # Validate config/*.conf syntax (also part of make check)
make check-i18n  # Verify en/fr locales define the same MSG_* keys (also part of make check)
make setup    # Activate the local git hooks (core.hooksPath = .githooks), incl. the pre-commit lint hook
make version  # Print the current tm-exclusions version
make install  # Homebrew bin if writable, else /usr/local (admin prompt if needed)
```

### Pre-commit hook

`make setup` points `core.hooksPath` at `.githooks/`, which activates [`.githooks/pre-commit`](.githooks/pre-commit). It only looks at the files **staged** for the commit (never the whole working tree) and stays fast:

- staged `*.sh` → ShellCheck (same options as `make lint`); `locales/*.sh` → `bash -n`. The **staged content** is checked (exported from the index to a temporary directory), not the working-tree file, so a partially staged file is judged on what will be committed; files it sources are resolved from the working tree;
- staged `*.conf` → `scripts/check-conf.sh` (config syntax);
- a locale file staged without its sibling → non-blocking reminder to run `make check-i18n`.

A ShellCheck or config error blocks the commit; a missing `shellcheck` only prints a warning (CI still lints). Skip it for one commit with `git commit --no-verify`.

There is no one-line permanent opt-out: any `make` invocation (even `make help`) sets `core.hooksPath` back to `.githooks` (a different local value is reported on stderr before it is replaced), and the fallback hooks installed by `make setup` in `.git/hooks` do the same on the next commit, checkout or merge. `git config --unset core.hooksPath` therefore only lasts until then. `TM_EXCLUSIONS_NO_HOOKS=1 make …` skips the automatic `make` bootstrap (an explicit `make setup` still installs the hooks); to turn the hooks off for a clone, unset `core.hooksPath`, export `TM_EXCLUSIONS_NO_HOOKS=1` and delete the fallbacks in `$(git rev-parse --git-common-dir)/hooks`.

### Releasing

```bash
# 1. Open a release PR that bumps VERSION and CHANGELOG:
make release VERSION=1.1.0

# 2. After merging the release PR, tag the merge commit (GPG-signed):
make tag VERSION=1.1.0
```

> Tags must be GPG-signed (enforced by the `tag` ruleset). Set `user.signingkey` in your git config first.

CI handles the rest: creates GitHub release, computes tarball SHA256, and updates the [Homebrew formula](https://github.com/qveys/homebrew-tools).

---

## 📄 License

MIT

---

<p align="center">
  <sub>Made with ☕ on macOS — because your backups shouldn't weigh more than your code.</sub>
</p>
