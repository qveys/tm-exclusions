<p align="center">
  <img src="https://img.icons8.com/color/96/time-machine.png" alt="Time Machine" width="80"/>
</p>

<h1 align="center">🛡️ tm-exclusions</h1>

<p align="center">
  <strong>Reclaim tens of GB from your Time Machine backups — automatically.</strong><br/>
  A smart macOS exclusion manager for developer machines.
</p>

<p align="center">
  <a href="https://github.com/qveys/tm-exclusions/actions/workflows/tests.yml"><img src="https://img.shields.io/github/actions/workflow/status/qveys/tm-exclusions/tests.yml?style=flat-square&label=tests" alt="Tests"/></a>
  <a href="https://github.com/qveys/tm-exclusions/actions/workflows/shellcheck.yml"><img src="https://img.shields.io/github/actions/workflow/status/qveys/tm-exclusions/shellcheck.yml?style=flat-square&label=shellcheck" alt="ShellCheck"/></a>
  <img src="https://img.shields.io/badge/bash-3.2%2B-green?style=flat-square&logo=gnubash&logoColor=white" alt="Bash 3.2+"/>
  <img src="https://img.shields.io/badge/macOS-compatible-black?style=flat-square&logo=apple&logoColor=white" alt="macOS"/>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/qveys/tm-exclusions?style=flat-square" alt="License"/></a>
</p>

---

## 🤔 Why?

A typical developer Mac wastes **30–60 GB** of backup space on content that's trivially regenerable:

```
node_modules/     ██████████████████████  12 GB
Docker data       ████████████████████    14 GB
.venv/            ████████                 4 GB
Xcode DevSupport  ██████████               5 GB
Homebrew          ██████████████          10 GB
Ollama models     ████████████████        11 GB
                  ─────────────────────────────
                  Total wasted: ~56 GB 💸
```
- **Static exclusion rules** for known cache/artifact paths across multiple ecosystems
- **Dynamic scanning** to discover `node_modules`, `.venv`, `build`, `dist`, and other regenerable directories
- **Prune support** to skip scanning irrelevant trees
- **Dry-run mode** to preview changes without applying them
- **Report-only mode** to audit current exclusion status
- **Uninstall** to remove exclusions matching the current configured rules and discovered patterns
- **Idempotent** — safe to run repeatedly
- **Multilingual** — English and French output
- **Config management** — add custom rules, init/list/edit config
- **Human-readable reports** after each run (host/user/version, optional inventory, `du` summary, `tmutil listexclusions` excerpt)

Optional environment variables (see **`docs/ARCHITECTURE.md`**): `TM_EXCLUSIONS_REPORT`, `TM_EXCLUSIONS_REPORT_DESKTOP`, `TM_EXCLUSIONS_SKIP_INVENTORY`, `TM_EXCLUSIONS_DEBUG_FIFO`.

**tm-exclusions** finds and excludes all of it in one command.

---

## ✨ Features

| | Feature | Details |
|---|---|---|
| 📦 | **Built-in rules** | Static + dynamic coverage across major dev ecosystems |
| 🔍 | **Dynamic scan** | Recursively finds `node_modules`, `.venv`, `__pycache__`, build dirs |
| 🔒 | **Dual tmutil strategy** | User paths via `tmutil addexclusion`; system paths via `sudo tmutil ... -p` |
| 🌍 | **Multilingual** | French / English (auto-detected from `$LANG`) |
| 📊 | **Rich report** | Saved report with counters/details (+ optional inventory and desktop copy) |
| 🔄 | **Idempotent** | Safe to re-run — skips already-excluded paths |
| 🐚 | **Bash 3.2** | Works with macOS stock shell — no dependencies |

<details>
<summary>📝 Brouillon (pas encore d'actualité)</summary>

| Item | Statut |
|---|---|
| **170+ built-in rules / 16 categories** | Brouillon |
| **Triple-layer pruning** | Brouillon |
| **tmux dual-pane UI** | Brouillon |
| **Desktop report generated on each run** | Brouillon (desktop copy via `TM_EXCLUSIONS_REPORT_DESKTOP=1`) |

</details>

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
<summary>📦 <strong>Built-in Categories</strong> (current coverage)</summary>

| Category | Examples |
|---|---|
| 🍎 **Applications** | `/Applications`, `~/Applications` |
| 📗 **Node.js** | npm/yarn/pnpm caches, dynamic `node_modules` |
| 🐍 **Python** | pip cache, virtualenvs, `.venv`, `venv`, `__pycache__` |
| 🐳 **Docker** | Desktop local data |
| 🍺 **Homebrew** | Homebrew download cache (+ discovered `brew --cache`) |
| 🦀 **Rust** | Cargo registry/git, rustup toolchains |
| ☕ **Java/JVM** | Maven, Gradle caches |
| 🔨 **Xcode** | DerivedData, Archives, CoreSimulator |
| 🤖 **AI/LLM** | Hugging Face, Ollama, LM Studio caches |
| 💻 **IDE Support** | JetBrains, VS Code caches |
| 🗂️ **Dynamic scan** | `node_modules`, `.venv`, `__pycache__`, `target`, `.next`, `.turbo`, `Pods`, `.gradle`, worktrees… |

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
  --uninstall      Remove all TM exclusions set by this script
  --uninstall --force   Remove without confirmation prompt
  --uninstall --dry-run Preview what would be removed

Other:
  --quiet, -q      Quiet mode (no banner, no colors, no spinners)
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
```

| Type | Effect |
|---|---|
| `path` | 🎯 Static exclusion → `tmutil addexclusion` |
| `pattern` | 🔍 Directory name matched by `find -name` during scan |
| `prune` | ✂️ Path ignored by scan (no TM exclusion applied) |

### Add custom exclusions

```bash
# 🎯 Exclude a specific directory
tm-exclusions --add path ~/.deno "Deno cache — reinstallable"

# 🔍 Add a pattern for dynamic scan
tm-exclusions --add pattern .angular "Angular CLI cache"

# ✂️ Ignore a directory during scan
tm-exclusions --add prune ~/VMs
```

---

## 🔇 Quiet Mode (cron / launchd)

Use `--quiet` (or `-q`) for unattended execution:

- No banner, no colors, no spinners, no tmux
- Report is still printed to stdout (summary/report output is not suppressed)
- Desktop report copy is generated only with `TM_EXCLUSIONS_REPORT_DESKTOP=1`

```bash
# Weekly cron job
0 3 * * 0  /usr/local/bin/tm-exclusions --quiet 2>>/tmp/tm_exclusions.err
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
    <string>/usr/local/bin/tm-exclusions</string>
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
| `TM_EXCLUSIONS_REPORT` | Override report output path |
| `TM_EXCLUSIONS_REPORT_DESKTOP=1` | Also write a report copy to Desktop |
| `TM_EXCLUSIONS_SKIP_INVENTORY=1` | Skip inventory block in report |
| `TM_EXCLUSIONS_SKIP_DU=1` | Skip per-path `du` disk-usage section in report |
| `TM_EXCLUSIONS_DEBUG_FIFO` | Mirror `log_info` output to FD 5 |

---

## 🔎 Current behavior notes

- In non-interactive runs without cached/passwordless sudo (`sudo -n`), system paths are skipped (no blocking prompt).
- `--uninstall` removes exclusions matching current configured static rules, dynamic matches, and discovered extra paths.
- Dynamic scan depth is intentionally capped to `find -maxdepth 6`.
- Report output always prints to stdout, including with `--quiet`.
- On non-macOS or without `tmutil`, behavior is simulated (useful for tests).

---

## 🧪 Development

```bash
make test     # Run TAP-format smoke tests (--dry-run, no tmutil calls)
make lint     # ShellCheck on all .sh files
make install  # Install to /usr/local
```

### Releasing

```bash
# 1. Bump VERSION in tm_exclusions.sh
# 2. Commit, then tag and push:
git tag v1.1.0
git push origin v1.1.0
```

CI handles the rest: creates GitHub release, computes tarball SHA256, and updates the [Homebrew formula](https://github.com/qveys/homebrew-tools).

---

## 📄 License

MIT

---

<p align="center">
  <sub>Made with ☕ on macOS — because your backups shouldn't weigh more than your code.</sub>
</p>
