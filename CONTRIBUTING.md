# Contributing

Thanks for considering a contribution. This is a small Bash project — keep PRs focused, scripts portable, and changes well-tested.

## Quick start

```bash
git clone https://github.com/qveys/tm-exclusions.git
cd tm-exclusions
make setup    # install local git hooks (Conventional Commits, staged-file lint, etc.)
make check    # lint + smoke tests
```

See [`AGENTS.md`](AGENTS.md) for the full architecture, build commands, and Bash 3.2 constraints.

## Ground rules

- **Bash 3.2 compatibility only.** macOS ships Bash 3.2. No associative arrays, no `mapfile`/`readarray`, no `${var,,}`. `make lint` enforces this with ShellCheck.
- **No external runtime dependencies.** The CLI must work on a stock macOS install.
- **`--dry-run` first.** Any change to `tmutil` calls must be testable in dry-run mode.
- **Keep tests deterministic.** `tests/smoke.bats-like.sh` runs against `--dry-run`; it must not require sudo or real `tmutil` state.
- **Never load a script with `source <(…)` in tests** (silent false green under Bash 3.2: it returns 0 without defining anything). Write it to a temporary file with `write_functions_file`, `source` that file, then call `require_functions` (both in `tests/test_helpers.sh`); `test_summary` fails a suite that ran no assertion.

## Pre-commit checks

`make setup` also activates the [`pre-commit`](.githooks/pre-commit) hook: staged `.sh` files are checked with ShellCheck, staged `.conf` files with `scripts/check-conf.sh`, and editing one locale file without the other prints a reminder (`make check-i18n`). It only inspects staged files (their **staged content**, so a partially staged file is judged on what will be committed), so it is fast; `make check` remains the full gate.

Skip it for one commit with `git commit --no-verify`. There is no one-line permanent opt-out: any `make` invocation (even `make help`) sets `core.hooksPath` back to `.githooks` — reporting on stderr a different local value it replaces — and the fallback hooks installed by `make setup` in `.git/hooks` restore it on the next commit, checkout or merge, so `git config --unset core.hooksPath` only lasts until then. `TM_EXCLUSIONS_NO_HOOKS=1 make …` skips the automatic `make` bootstrap (an explicit `make setup` still installs the hooks); to disable the hooks for a clone, unset `core.hooksPath`, export `TM_EXCLUSIONS_NO_HOOKS=1` and delete the fallbacks in `$(git rev-parse --git-common-dir)/hooks`.

## Adding an exclusion category

```bash
scripts/add-category.sh --dry-run --name "Deno" \
  --add path '$HOME/.deno/cache' 'Deno cache — re-downloaded' \
  --add pattern '.deno' 'Deno project cache'
```

Drop `--dry-run` to write it (run without `--name`/`--add` in a terminal to be prompted). The script validates the fields (`path`, `pattern`, `prune` or `keep`; no empty value, `|` or newline), refuses an existing category or rule, inserts the `#@Name` section into `config/default.conf` following its layout (`path`/`keep` before the pattern banner, `pattern` before the prune banner, `prune` at the end), and replaces the files only if `scripts/check-conf.sh`, `scripts/check-i18n.sh` and the checks below pass. A leading `~` is written as `$HOME`. Category names are not localized: the CLI prints the `#@` label as written (only "Uncategorized" is translated), so no `locales/*.sh` key is written. The script also bumps `EXPECTED_CATEGORY_COUNT` in `tests/smoke.bats-like.sh` (the single source of the category count) and, unless `--skip-tests` is given, runs `make check` (lint + tests) on a copy of the repository (next to the checkout, or under `$HOME` when the checkout itself is under `TMPDIR` or `/var/folders`) before touching any real file; the two real files are then overwritten in place and restored if anything fails, so they are both updated or both untouched; with `--skip-tests`, run `make check` yourself. Only one run may edit a tree at a time (`.add-category.lock`, taken through an `O_EXCL` guard file because some `mkdir` implementations, e.g. uutils coreutils, are not exclusive under a race). `config/default.conf` and the smoke test must be regular files (symbolic links are refused). Known limit: a signal in the few microseconds between creating the lock and recording its ownership, or a SIGKILL during the final restore, can leave a stale `.add-category.lock` or `.add-category.lock.guard` or an unrestored file; remove them by hand and check `git status`.

## Commit style

Conventional Commits with a leading emoji, enforced by the local [`commit-msg`](.githooks/commit-msg) hook (active when `core.hooksPath = .githooks`, set up by `make setup`). Examples:

```
✨ feat(config): expand default catalog to N rules
🐛 fix(scan): handle paths with spaces under $HOME
📝 docs: clarify uninstall semantics
🔧 chore(ci): bump actions/checkout to v5
```

All commits to `master` must be **GPG-signed** (enforced by repository ruleset). Configure once:

```bash
git config --global user.signingkey <YOUR_KEY_ID>
git config --global commit.gpgsign true
git config --global tag.gpgsign true
```

## Pull requests

1. Fork and branch from `master` (`feat/<topic>`, `fix/<topic>`, `chore/<topic>`).
2. Run `make check` before pushing.
3. Open the PR against `master`. The PR template walks you through the checklist.
4. CI must be green: ShellCheck, smoke tests, dependency review, label/title normalization.
5. Squash merges only.

## Releasing (maintainer)

```bash
make release VERSION=x.y.z   # opens release PR
# after merge:
make tag VERSION=x.y.z       # pushes signed tag, triggers release.yml
```

The `tag` ruleset enforces signed annotated tags. `make tag` fails fast if `user.signingkey` is unset.

## Reporting issues

- Bugs → use the **Bug report** issue template.
- Feature requests → use the **Feature request** issue template.
- Security → see [`SECURITY.md`](SECURITY.md). Do not open a public issue.
