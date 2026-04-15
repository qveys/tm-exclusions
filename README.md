# tm-exclusions

**macOS Time Machine exclusion manager for developer machines.**

Automatically excludes regenerable content — caches, `node_modules`, virtual environments, build artifacts, model files — from Time Machine backups so you reclaim backup space safely.

## Why?

Developer machines accumulate gigabytes of regenerable data: package caches, build outputs, toolchain binaries, AI model downloads. Time Machine backs all of this up by default. `tm-exclusions` identifies these directories and excludes them via `tmutil`, saving significant backup time and disk space.

One command. Safe to rerun. No dependencies beyond stock macOS.

## Features (v1)

- **Static exclusion rules** for known cache/artifact paths across multiple ecosystems
- **Dynamic scanning** to discover `node_modules`, `.venv`, `build`, `dist`, and other regenerable directories
- **Prune support** to skip scanning irrelevant trees
- **Dry-run mode** to preview changes without applying them
- **Report-only mode** to audit current exclusion status
- **Uninstall** to remove exclusions matching the current configured rules and discovered patterns
- **Idempotent** — safe to run repeatedly
- **Multilingual** — English and French output
- **Config management** — add custom rules, init/list/edit config
- **Human-readable reports** saved after each run

### Covered Ecosystems

Default rules cover these areas:

| Category | Examples |
|---|---|
| Node.js | npm/yarn/pnpm caches, `node_modules` |
| Python | pip cache, virtualenvs, `__pycache__`, `.venv` |
| Rust | Cargo registry/git, `target` |
| Go | Module cache, build cache |
| Java/JVM | Gradle caches/wrapper, Maven repository |
| Docker | Docker Desktop local data |
| Xcode | DerivedData, Archives, CoreSimulator |
| Homebrew | Download cache |
| AI/LLM | Hugging Face, Ollama, LM Studio caches |
| IDE/Editor | JetBrains, VS Code caches |
| Build artifacts | `dist`, `build`, `.next`, `.turbo`, `Pods`, `.gradle` |

## Install

```bash
# Clone and install (uses sudo automatically when needed)
git clone https://github.com/qveys/tm-exclusions.git
cd tm-exclusions
make install
```

### Homebrew

After the formula is published in [qveys/homebrew-tools](https://github.com/qveys/homebrew-tools) (updated automatically on each **`v*`** tag when `HOMEBREW_TAP_TOKEN` is configured):

```bash
brew tap qveys/homebrew-tools
brew install tm-exclusions
```

From a git checkout you can install the local formula (macOS):

```bash
brew install --formula ./Formula/tm-exclusions.rb
```

See **`docs/PACKAGING.md`** for Makefile vs Homebrew layout and tap sync.

Or run directly without installing:

```bash
bash tm_exclusions.sh --help
```

## Usage

```bash
# Apply all exclusions (default mode)
tm-exclusions

# Preview what would be excluded
tm-exclusions --dry-run

# Report current status without making changes
tm-exclusions --report-only

# Remove exclusions matching the current configured rules
tm-exclusions --uninstall

# Remove exclusions even for paths that no longer exist
tm-exclusions --uninstall --force

# Preview uninstall
tm-exclusions --uninstall --dry-run

# Quiet mode (suppress non-essential output)
tm-exclusions --quiet
tm-exclusions -q

# French output
tm-exclusions --lang fr

# Show help
tm-exclusions --help

# Show version
tm-exclusions --version
```

## Configuration

### Config files

Rules are loaded and merged in order:

1. `config/default.conf` — built-in rules (shipped with the tool)
2. `~/.config/tm_exclusions/custom.conf` — your custom rules

After `make install`, the built-in rules are installed under a shared data path such as `/usr/local/share/tm-exclusions/default.conf`.

### Config format

Each line is: `type|target|reason`

| Type | Meaning |
|---|---|
| `path` | Exact path to exclude from backup |
| `pattern` | Directory name to find and exclude during scan |
| `prune` | Path prefix to skip during scanning (not excluded) |

Lines starting with `#` are comments.

### Managing custom rules

```bash
# Initialize custom config directory
tm-exclusions --init

# Add a custom exclusion
tm-exclusions --add path "~/MyLargeDataset" "Large dataset not needed in backup"
tm-exclusions --add pattern ".myframework_cache" "Framework cache directories"
tm-exclusions --add prune "~/Archive" "Skip scanning archive directory"

# List custom rules
tm-exclusions --list

# Edit custom config in $EDITOR
tm-exclusions --edit
```

### Custom exclusion examples

```
# Exclude a specific large directory
path|~/Datasets/imagenet|Large ML dataset

# Find and exclude all .terraform directories
pattern|.terraform|Terraform provider cache

# Skip scanning a mounted network volume
prune|/Volumes/NAS|Network volume
```

## Quiet Mode

Use `--quiet` or `-q` to suppress informational output. Reports and errors are still shown.

```bash
# Good for cron or launchd
tm-exclusions --quiet
```

## Scheduled Execution with launchd

Create `~/Library/LaunchAgents/com.tm-exclusions.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.tm-exclusions</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/tm-exclusions</string>
        <string>--quiet</string>
    </array>
    <key>StartInterval</key>
    <integer>86400</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/tm-exclusions.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/tm-exclusions.err</string>
</dict>
</plist>
```

Load it:

```bash
launchctl load ~/Library/LaunchAgents/com.tm-exclusions.plist
```

## Development

```bash
# Run tests
make test

# Run ShellCheck linting
make lint

# Run both
make check

# Install locally (uses sudo automatically when PREFIX or SHARE_DIR is not writable)
make install

# Uninstall (uses sudo automatically when PREFIX or SHARE_DIR is not writable)
make uninstall
```

## Limitations & Notes

- **Time Machine UI visibility**: Some exclusions applied via `tmutil addexclusion` may not appear in System Settings > Time Machine, even when they are active. Use `tmutil isexcluded <path>` to verify.
- **User-space exclusions**: The tool uses user-level (`addexclusion`) not fixed exclusions (`addexclusion -p`). These are "sticky" and follow the path even if renamed.
- **Uninstall scope**: `--uninstall` only removes exclusions matching the current configured static rules and discovered patterns. It does not track every exclusion from past runs.
- **Scan depth**: Dynamic scanning uses `find -maxdepth 6` from `$HOME` for practical execution time.
- **Non-macOS**: On non-macOS systems, the tool runs in simulation mode (no actual `tmutil` calls). Useful for testing and config management.
- **Bash 3.2**: Compatible with stock macOS Bash. No Bash 4+ features used.

## License

[MIT](LICENSE) — Quentin Veys
