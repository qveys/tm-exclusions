# Changelog

All notable changes to this project will be documented in this file.

## Unreleased

### Build

- **`make install` / `make uninstall`**: default `PREFIX` is `$(brew --prefix)/bin` when writable, otherwise `/usr/local/bin`. Elevation no longer uses `sudo sh -c` (blocked by restricted sudoers). Cascade: unprivileged `install`/`rm` when the destination is writable, else `sudo /usr/bin/install` (or `/bin/rm`) per file, else a macOS admin dialog via `osascript`.
- `make version` prints the current `tm_exclusions.sh` version without running the CLI. ([#43](https://github.com/qveys/tm-exclusions/issues/43))
- `make install` / `make uninstall` also install and remove `locales/*.sh` under `$(SHARE_DIR)/locales/`. ([#16](https://github.com/qveys/tm-exclusions/issues/16))

### i18n

- **External locale files**: all user-visible strings moved out of `tm_exclusions.sh` into `locales/en.sh` and `locales/fr.sh`, sourced at runtime by `load_i18n()`. `resolve_locales_dir()` looks at `TM_EXCLUSIONS_LOCALES_DIR` (ignored as root), the repo checkout, then the installed share dirs; a missing locale file is a fatal error rather than a silent fallback. ([#16](https://github.com/qveys/tm-exclusions/issues/16))
- **`--lang`**: values are allowlisted to `en`/`fr` before any locale path is built, so an untrusted value can never become a sourced filename; unsupported codes report "Unsupported language" instead of "locale files not found".

### Config

- **Auto-prune `.bak` / `.old` shadow copies**: after config loading, every static `path|<P>` rule automatically extends `CONF_PRUNES` with `<P>.bak` and `<P>.old`. Shadow trees produced by tool reinstalls or migrations (e.g. `.bun.bak`, `.npm.bak`, `.cargo.bak`, `.pnpm-store.bak`) are silently skipped during the dynamic scan without any per-suffix opt-in. `pattern|` and `prune|` catalog entries are not auto-derived. `config/default.conf` is unchanged. ([#25](https://github.com/qveys/tm-exclusions/issues/25))
- **`TM_EXCLUSIONS_EXTRA_CONF`**: opt-in mechanism for power users with large cloud-sync trees. Set the env var to any config file to load it after `default.conf` and `custom.conf`. A missing, non-regular-file (e.g. a directory path), or unreadable value emits a stderr warning and continues — the loader now requires both `-f` (regular file) and `-r` (readable). The example file (`extra-prunes.example.conf`) is installed alongside `default.conf`: in a source checkout under `config/`, via `make install` under `${SHARE_DIR}/` (`$(PREFIX)/../share/tm-exclusions`, i.e. `$(brew --prefix)/share/tm-exclusions/` when the Homebrew bin is writable, otherwise `/usr/local/share/tm-exclusions/`), and via `brew install` under `$(brew --prefix)/share/tm-exclusions/`. `config/default.conf` is unchanged. ([#17](https://github.com/qveys/tm-exclusions/issues/17))

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

### Security / Hardening

- Signal handling and temp file cleanup: register all `mktemp` files and clean them up deterministically on `EXIT`, `INT` (SIGINT), `TERM` (SIGTERM), and `HUP` (SIGHUP), stopping background sudo keepalive and re-raising the signal cleanly.
- `$EDITOR` support with arguments: parse `$EDITOR` into an indexed argument array (`read -r -a`) in `cmd_config_edit` so multi-word commands (e.g. `code --wait`, `subl -w`, `nano -B`) execute properly without invoking `eval`.

### Default rules

- Re-enabled **`path|/private/var/folders`** under macOS Caches. Per-user kernel temp/caches are regenerable; privileged apply uses `sudo tmutil addexclusion -p` when credentials are available. ([#55](https://github.com/qveys/tm-exclusions/issues/55))
- `$HOME/Library/Developer/CoreSimulator` is no longer excluded as a parent tree. The catalog now targets `Caches`, `Temp`, `Volumes`, and `Devices` so root-level simulator metadata stays in backups; comment out `Devices` in a local catalog copy to retain simulator device state. `/Library/Developer/CoreSimulator` is unchanged (system runtimes). Apply / `--dry-run` / `--uninstall` drop the retired parent `tmutil` exclusion when it is still present (manual equivalent: `tmutil removeexclusion "$HOME/Library/Developer/CoreSimulator"`). ([#54](https://github.com/qveys/tm-exclusions/issues/54))
- Default prune zones now cover package-manager reinstall/migration shadow copies (`.bun.bak`, `.npm.bak`, `.yarn.bak`, `.pnpm-store.bak`, `.cargo.bak`, and matching `.old` siblings). These trees are disposable duplicates of catalogued caches; pruning them stops the dynamic scan from emitting one exclusion per nested `dist`/`node_modules` without excluding the parent from Time Machine. ([#25](https://github.com/qveys/tm-exclusions/issues/25))
- Static paths for `/Applications` and `$HOME/Applications`.
- Default config now ships ~117 rules across 17 categories (up from 39). Path style normalized to `$HOME/...`. New `#@CategoryName` section markers (cosmetic in 1.x; future report grouping tracked in #34). Several entries ship commented (opt-in): `pattern|.cache`, `pattern|site-packages`, `path|$HOME/.docker` (keeps registry credentials), and the `App Support` Application Support roots (mix of user data and caches). `$HOME/.ollama/models` replaces the parent `$HOME/.ollama` (preserves `id_ed25519` and chat history). Cloud-sync prunes deferred to user opt-in (#44). (#37)

### Fixed

- Dynamic scan no longer emits redundant child exclusions under an already-excluded parent. After the parent (e.g. `~/Git/<repo>/node_modules`) is kept, descendants matched by the same or another pattern (e.g. `.pnpm/<pkg>/node_modules`) are silently skipped — they're already covered transitively by the parent. Saves hundreds of lines per pnpm workspace and avoids duplicate `tmutil addexclusion` calls. ([#23](https://github.com/qveys/tm-exclusions/issues/23))
- Report `du -sk` no longer aborts under `set -euo pipefail` when a path has unreadable children (e.g. `/private/var/folders`). `du_size_kb()` captures `du` independently of the formatting pipeline and keeps a partial total when one is printed. ([#55](https://github.com/qveys/tm-exclusions/issues/55), [#18](https://github.com/qveys/tm-exclusions/issues/18))

### CI and automation

- **Automated patch releases**: new workflow (`.github/workflows/auto-patch.yml`) and script (`scripts/check-auto-patch.sh`) to automatically apply and publish a patch release (`vX.Y.(Z+1)`) directly on `master` whenever 5 or more PRs have been merged without an intermediate manual release (no release PR required).
- **GitHub Releases notes**: release workflow (`.github/workflows/release.yml`) now automatically extracts the curated section for the released version from `CHANGELOG.md` instead of generating a generic commit list.
- **Homebrew tap synchronization**: release workflow fully replaces `Formula/tm-exclusions.rb` in `qveys/homebrew-tools` to prevent `install` stanza drift, and supports manual tap re-sync via `workflow_dispatch` with a `tag` input.
- **Makefile enhancements**: `make release` now validates that `## Unreleased` has actual content, updates `Formula/tm-exclusions.rb`, and injects the changelog into the PR body; new target `make auto-patch` to inspect or run auto-patch status locally.
- **Auto-patch/release hardening**: `create-github-app-token` steps now request only `permission-contents: write`; `check-auto-patch.sh` validates `--threshold`, requires `HEAD` to match `origin/master` with a clean worktree before mutating release files, skips when a manual release is pending, counts merged PRs from commit subjects instead of `--oneline`-prefixed SHAs, uses a portable tag sort, and stages `Formula/tm-exclusions.rb` only when present; `make release`'s PR body no longer loses the Changelog section to a stale cross-recipe shell variable.

### CI and automation

- **Release workflow**: Synchronize `Formula/tm-exclusions.rb` to the Homebrew tap via `.github/workflows/release.yml` on every tag. This fixes `Errno::ENOENT` errors caused by stale tap formulas and adds a `workflow_dispatch` input to manually re-sync existing tags.

### Docs

- Ongoing parity checklist: GitHub issue [#34](https://github.com/qveys/tm-exclusions/issues/34).

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
