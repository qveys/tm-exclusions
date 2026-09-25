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
- **Prune support** to skip scanning irrelevant trees
- **Dry-run mode** to preview changes without applying them
- **Report-only mode** to audit current exclusion status
- **Uninstall** to remove exclusions matching the current configured rules and discovered patterns
- **Idempotent** — safe to run repeatedly
- **Multilingual** — English and French output
- **Config management** — add custom rules, init/list/edit config
- **Human-readable reports** after each run (host/user/version, optional inventory, `du` summary, `tmutil listexclusions` excerpt)
- Reports group actions by rule, distinguish missing and privilege-blocked paths, and state the `tmutil listexclusions` result.

Optional environment variables (see **`docs/ARCHITECTURE.md`**): `TM_EXCLUSIONS_REPORT`, `TM_EXCLUSIONS_REPORT_DESKTOP`, `TM_EXCLUSIONS_SKIP_INVENTORY`, `TM_EXCLUSIONS_DEBUG_FIFO`.

Preview the selected exclusions with `tm-exclusions --dry-run` before applying them.

---

## 🎨 Terminal display

Interactive terminals get cyan section headings, status colors, emojis, progress
bars and a compact final summary. During cache and disk-image discovery, the
current directory updates (when `setting|scan_images|true` is enabled) on a single line (long paths show their tail).
Progress counts completed static rules and
completed scan patterns, not elapsed time. The full inventory, disk usage and
per-path details remain in the saved report, whose location is printed at the end.

```text
  🛡️  tm-exclusions  v1.3.0

  📁  Application des règles d’exclusion statiques...

  ━━━━━━━━━━━━━━━━━━━━ 100%  42/42

  📊  Bilan

  Chemins vérifiés : 42
  Seraient exclus : 12
  Déjà exclus : 25
  Ignorés : 5
  Erreurs : 0
```

Try `bash tm_exclusions.sh --dry-run --lang fr` in your terminal.
Pipes, redirected output, `TERM=dumb`, `NO_COLOR=1` and `--quiet` keep the
plain full report without decorations or progress updates. Saved reports and
debug logs always remain plain text. No extra dependencies are required.

## ✨ Features

| | Feature | Details |
|---|---|---|
| 📦 | **Built-in rules** | 100+ active rules across 17 categories, plus opt-in examples (Node.js, Python, Rust, Java, Xcode, AI/LLM, Docker, Homebrew, …) |
| 🔍 | **Dynamic scan** | Recursively finds `node_modules`, `.venv`, `__pycache__`, tool-specific build caches |
| 🔒 | **Dual tmutil strategy** | User paths via `tmutil addexclusion`; system paths via `sudo tmutil ... -p` |
| 🌍 | **Multilingual** | French / English (auto-detected from `$LANG`) |
| 📊 | **Rich report** | Saved report with counters/details (+ optional inventory and desktop copy) |
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

Config files are loaded, merged, then applied via a dual `tmutil` strategy (user paths under `$HOME`, fixed-path for system paths). Dynamic scan uses `find "$HOME" -maxdepth 6 -type d -name <pattern>` and `prune` rules filter matched results under configured prefixes. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full flowchart and details.

> 💡 Most exclusions won't appear in System Settings → Time Machine. They're still active — verify with `tmutil isexcluded ~/Library/Caches`

<details>
<summary>📦 <strong>Built-in Categories</strong> (17 categories — see <code>config/default.conf</code> for the full list)</summary>

| Category | Examples |
|---|---|
| 🍎 **Applications** | Opt-in: `/Applications`, `$HOME/Applications` |
| 📗 **Node.js / JavaScript** | npm/yarn/pnpm caches; opt-in `.bun` and `.nvm`;  dynamic `node_modules`, `.next`, `.turbo`, `.parcel-cache` |
| 🐍 **Python** | pip/pipx caches and Python environments; opt-in mixed uv/conda roots; dynamic `.venv`, `venv`, `__pycache__`, `.pytest_cache`, `.ruff_cache` |
| 🐳 **Docker** | Opt-in Docker Desktop data (may contain databases and persistent volumes) |
| 🍺 **Homebrew** | `/usr/local/Cellar` and discovered `brew --cache`; `/opt/homebrew` is opt-in (includes `etc` and `var`) |
| 🦀 **Rust / Cargo** | Cargo registry/git, rustup toolchains; dynamic `target` |
| ☕ **Java / JVM** | Maven, Gradle, Ivy and Coursier caches; opt-in SBT root; dynamic `.gradle` |
| 🐹 **Go** | Go module cache, build cache |
| 💎 **Ruby / iOS** | rbenv; opt-in mixed RVM/gems/CocoaPods roots; dynamic `Pods` |
| 🔨 **Xcode / Apple Dev Tools** | DerivedData, DeviceSupport, CoreSimulator Caches/Temp/Volumes; Archives and Devices are opt-in |
| 🗄️ **macOS Caches** | `~/Library/Caches`, `/private/var/folders`; Logs are opt-in |
| 🛠️ **Dev Tools** | IDE caches (JetBrains, VS Code), Terraform and kubectl caches; mixed Pulumi/Helm roots are opt-in |
| 🤖 **AI / LLM** | Hugging Face, LM Studio, Claude runtime bundles, SuperWhisper; Ollama models and agent sessions are opt-in |
| 🧰 **IDE and Dev Tool Caches** | Selective Application Support caches: Cursor Chromium cache, JetBrains plugins, Zed languages, Discord Cache, … |
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
  --quiet, -q      Quiet mode (no banner, no colors, no spinners)
  --desktop-report Write a report copy to ~/Desktop (default: off; avoids clutter on cron/launchd runs)
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

Image discovery is off by default. With `scan_images=true`, it considers at most
50 `.sparsebundle` directories or `.vmdk`/`.qcow2`/`.raw`/`.img` files larger than
512 MiB. Extra candidates are disclosed as `LIMIT` in the report. This is a cap
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
| `TM_EXCLUSIONS_SKIP_INVENTORY=1` | Skip inventory block in report |
| `TM_EXCLUSIONS_SKIP_DU=1` | Skip per-path `du` disk-usage section in report |
| `TM_EXCLUSIONS_DEBUG_FIFO` | Mirror `log_info` output to FD 5 |

---

## 🔎 Current behavior notes

- In non-interactive runs without cached/passwordless sudo (`sudo -n`), system paths are not silently skipped: each one is recorded as a privilege-blocked entry in the report and counted, so the run exits non-zero (see [Results and exit codes](#results-and-exit-codes)). No blocking prompt is ever shown. Privileged exclusions such as `/private/var/folders` use `sudo tmutil addexclusion -p` when credentials are available.
- Report disk-usage uses `du -sk` and ignores permission-denied children, so partially-readable trees like `/private/var/folders` cannot abort a run under `set -euo pipefail`.
- Reports include a rule summary, separate missing-path and privilege-blocked counts, and an explicit `tmutil listexclusions` status (`ok`, `empty`, `failed`, or `unavailable`).
- `--uninstall` removes exclusions matching current configured static rules, dynamic matches, and discovered extra paths. It also drops retired catalog paths that are still excluded (today: the former `$HOME/Library/Developer/CoreSimulator` parent).
- Apply and `--dry-run` drop that same retired parent exclusion when `tmutil` still has it, then add the granular CoreSimulator subdirs. Manual equivalent: `tmutil removeexclusion "$HOME/Library/Developer/CoreSimulator"`.
- Dynamic scan depth is intentionally capped to `find -maxdepth 6`.
- Report output always prints to stdout, including with `--quiet`.
- On non-macOS or without `tmutil`, behavior is simulated (useful for tests).

---

## 🧪 Development

```bash
make test     # Run TAP-format smoke tests (--dry-run, no tmutil calls)
make lint     # ShellCheck on all .sh files
make version  # Print the current tm-exclusions version
make install  # Homebrew bin if writable, else /usr/local (admin prompt if needed)
```

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
