# Changelog

All notable changes to this project will be documented in this file.

## Unreleased

### CLI

- Paths outside `$HOME` use `sudo tmutil addexclusion -p` / `removeexclusion -p` when interactive sudo or a passwordless sudo cache is available; background `sudo -v` refresh for long runs. Non-interactive runs without `sudo -n` **skip** those paths instead of blocking.
- `-h` accepted as an alias for `--help`.
- Config: expand `$HOME` in rule targets (same idea as legacy `default.conf`); optional `#@…` lines remain comments.
- Dynamic scan: narrow `target` and `worktrees` matches to reduce false positives (Rust/Maven/Gradle projects; git/agent worktrees).
- After pattern scan: apply `brew --cache` when `brew` exists; scan for large VM / container disk files under `$HOME` / `~/Library` (excluding iCloud shortcut trees).
- Report: host, user, version; inventory block (Applications / Homebrew / PATH stats); `du` summary for paths touched; append `tmutil listexclusions` (first 500 lines) when `tmutil` is available. Env: `TM_EXCLUSIONS_REPORT`, `TM_EXCLUSIONS_REPORT_DESKTOP`, `TM_EXCLUSIONS_SKIP_INVENTORY`, `TM_EXCLUSIONS_DEBUG_FIFO`.
- First run of apply-like modes (and `--add` / `--list` / `--edit`) auto-creates `custom.conf` from the `--init` template if missing.
- Report-only: summary line for “not excluded” paths reads as **action needed**, not “newly excluded”; **Skipped:** label covers privileged skips and missing paths.
- `collect_post_scan_paths`: dedupe `EXTRA_PATHS`; **`find -size +512M`** (portable suffix); **`.sparsebundle`** matched as **directories**; **`worktrees`** glob matches `.git/worktrees` root.
- Debug FIFO: open with **`exec 5<>`** (read+write) so named pipes do not block on open.

### Default rules

- Static paths for `/Applications` and `~/Applications`.

### Docs

- Architecture and README updated for the above. Ongoing parity checklist: GitHub issue [#34](https://github.com/qveys/tm-exclusions/issues/34).

## v1.1.0

### CLI

- Embedded version **1.1.0** (`tm-exclusions --version`).

### CI and automation

- PR triage workflow: apply labels from `docs/LABELS.md` (Area, Type, Status, Priority, Effort, extras); Priority labels are mutually exclusive when multiple match.
- Label catalog reference in-repo (`docs/LABELS.md`) with JSON rules for triage.
- Dependabot for GitHub Actions; consolidated lint + smoke workflow; PR labeler and title normalization; stale bot; dependency review and CodeQL for Actions.

### Docs

- `AGENTS.md` guidance for agentic tools; expanded GitHub label reference.

## v1.0.0

- Initial stable release.
