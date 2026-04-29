# Changelog

All notable changes to this project will be documented in this file.

## Unreleased

### Config

- **Auto-prune `.bak` / `.old` shadow copies**: after config loading, every static `path|<P>` rule automatically extends `CONF_PRUNES` with `<P>.bak` and `<P>.old`. Shadow trees produced by tool reinstalls or migrations (e.g. `.bun.bak`, `.npm.bak`, `.cargo.bak`, `.pnpm-store.bak`) are silently skipped during the dynamic scan without any per-suffix opt-in. `pattern|` and `prune|` catalog entries are not auto-derived. `config/default.conf` is unchanged. ([#25](https://github.com/qveys/tm-exclusions/issues/25))
- **`TM_EXCLUSIONS_EXTRA_CONF`**: opt-in mechanism for power users with large cloud-sync trees. Set the env var to any config file to load it after `default.conf` and `custom.conf`. A missing, non-regular-file (e.g. a directory path), or unreadable value emits a stderr warning and continues — the loader now requires both `-f` (regular file) and `-r` (readable). The example file (`extra-prunes.example.conf`) is installed alongside `default.conf`: in a source checkout under `config/`, via `make install` under `${SHARE_DIR}/` (default `/usr/local/share/tm-exclusions/`), and via `brew install` under `$(brew --prefix)/share/tm-exclusions/`. `config/default.conf` is unchanged. ([#17](https://github.com/qveys/tm-exclusions/issues/17))

### CLI

- Desktop report policy made explicit: the `~/Desktop` copy is **off by default** (avoids clutter on unattended cron/launchd runs). Opt in with the new `--desktop-report` CLI flag or the existing `TM_EXCLUSIONS_REPORT_DESKTOP=1` env var; both are equivalent. ([#15](https://github.com/qveys/tm-exclusions/issues/15))
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

- Static paths for `/Applications` and `$HOME/Applications`.
- Default config now ships ~102 rules across 17 categories (up from 39). Path style normalized to `$HOME/...`. New `#@CategoryName` section markers (cosmetic in 1.x; future report grouping tracked in #34). Several entries ship commented (opt-in): `pattern|.cache`, `pattern|site-packages`, `path|$HOME/.docker` (keeps registry credentials), the `App Support` Application Support roots (mix of user data and caches), and `path|/private/var/folders` (`du`/pipefail abort, see #45). `$HOME/.ollama/models` replaces the parent `$HOME/.ollama` (preserves `id_ed25519` and chat history). Cloud-sync prunes deferred to user opt-in (#44). (#37)

### Fixed

- Dynamic scan no longer emits redundant child exclusions under an already-excluded parent. After the parent (e.g. `~/Git/<repo>/node_modules`) is kept, descendants matched by the same or another pattern (e.g. `.pnpm/<pkg>/node_modules`) are silently skipped — they're already covered transitively by the parent. Saves hundreds of lines per pnpm workspace and avoids duplicate `tmutil addexclusion` calls. ([#23](https://github.com/qveys/tm-exclusions/issues/23))

### Docs

- Architecture and README updated for the above. Ongoing parity checklist: GitHub issue [#34](https://github.com/qveys/tm-exclusions/issues/34).

## v1.2.0

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
