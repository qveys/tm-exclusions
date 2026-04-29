# Contributing

Thanks for considering a contribution. This is a small Bash project — keep PRs focused, scripts portable, and changes well-tested.

## Quick start

```bash
git clone https://github.com/qveys/tm-exclusions.git
cd tm-exclusions
make setup    # install local git hooks (Conventional Commits, etc.)
make check    # lint + smoke tests
```

See [`AGENTS.md`](AGENTS.md) for the full architecture, build commands, and Bash 3.2 constraints.

## Ground rules

- **Bash 3.2 compatibility only.** macOS ships Bash 3.2. No associative arrays, no `mapfile`/`readarray`, no `${var,,}`. `make lint` enforces this with ShellCheck.
- **No external runtime dependencies.** The CLI must work on a stock macOS install.
- **`--dry-run` first.** Any change to `tmutil` calls must be testable in dry-run mode.
- **Keep tests deterministic.** `tests/smoke.bats-like.sh` runs against `--dry-run`; it must not require sudo or real `tmutil` state.

## Commit style

Conventional Commits with a leading emoji, enforced by the local `commit-msg` hook (`.githooks/commit-msg-fallback`). Examples:

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
