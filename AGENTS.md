# AGENTS.md

This file provides guidance to AI agentic LLM CLI tools when working with code in this repository.

## Project overview
- `tm-exclusions` is a single-file Bash CLI (`tm_exclusions.sh`) for managing macOS Time Machine exclusions for regenerable developer data.
- It is config-driven: built-in rules come from the resolved default config (`resolve_default_conf()` in `tm_exclusions.sh` — e.g. `config/default.conf` in a repo checkout, `.../share/tm-exclusions/default.conf` when installed, or `$TM_EXCLUSIONS_DEFAULT_CONF` when set); user rules come from `~/.config/tm_exclusions/custom.conf`.
- Behavior and docs must stay aligned: when implementation changes, update `README.md`, tests in `tests/`, and `docs/ARCHITECTURE.md` when architectural behavior changes.

## Core development commands
- Show available make targets and manage the dev environment:
  - `make help`
  - `make setup`
  - `make check-hooks`
- Run all checks:
  - `make check`
- Lint shell scripts:
  - `make lint`
- Run smoke tests:
  - `make test`
- Run the smoke test script directly:
  - `bash tests/smoke.bats-like.sh`
- Install locally:
  - `make install`
- Uninstall:
  - `make uninstall`
- Run CLI without installing:
  - `bash tm_exclusions.sh --help`
  - `bash tm_exclusions.sh --dry-run`

## Single-test / focused validation workflow
- There is no native per-test selector in `tests/smoke.bats-like.sh` (it runs end-to-end smoke checks).
- For focused validation of one behavior, run the CLI command for that behavior directly (example: `bash tm_exclusions.sh --lang fr --help`) and/or execute a small isolated scenario with a temporary `HOME`.

## Architecture map (big picture)
- Entrypoint: `main()` in `tm_exclusions.sh`.
  - Pre-scans args for early language/quiet behavior.
  - Parses args into mode (`apply`, `dry-run`, `report-only`, `uninstall`) or config subcommands (`--init`, `--add`, `--list`, `--edit`).
  - Runs environment detection (`tmutil` availability, macOS check).
  - Loads merged config.
  - Applies static path processing, then dynamic pattern scanning.
  - Generates and persists report to `~/.config/tm_exclusions/last_report.txt`.
- Processing model:
  - Static rules (`path`) are handled directly.
  - Dynamic rules (`pattern`) are discovered with `find "$HOME" -maxdepth 6 -type d -name <pattern>`.
  - Prune rules (`prune`) do not create Time Machine exclusions. They only skip applying exclusions to dynamic matches whose paths fall under a prune prefix after discovery; `find` still walks from `$HOME` — these rules filter results afterward and do not limit which directories `find` visits.
- `tmutil` integration:
  - All Time Machine operations are wrapped via `tm_is_excluded`, `tm_add_exclusion`, `tm_remove_exclusion`.
  - On non-macOS or when `tmutil` is unavailable, wrappers simulate behavior so tests can run without mutating Time Machine state.
- Idempotency:
  - Apply mode checks existing exclusion status before adding.
  - Uninstall mode safely removes matched exclusions and supports `--force` for paths that no longer exist.

## Constraints and repo-specific rules
- Bash compatibility target is Bash 3.2+ (stock macOS). Avoid Bash 4+ features.
- Keep quoting strict and portable shell style consistent with current script.
- Config file format is `type|target|reason`; supported types are `path`, `pattern`, `prune`. The `target` field supports leading `~` expansion to the user’s home directory.
- Conventional Commits with leading emoji are enforced by local hooks in `.githooks/`.
  - Ensure hooks are active via `make setup` (also auto-bootstrapped by the Makefile).
