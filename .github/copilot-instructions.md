# Copilot Instructions for tm-exclusions

## Language and compatibility
- All code must be compatible with **Bash 3.2+** (stock macOS shell).
- Do not use Bash 4+ features: associative arrays, `readarray`, `mapfile`, `${var,,}`, `${var^^}`, `|&`, etc.
- Use `$(...)` for command substitution, not backticks.
- Always quote variables: `"$var"` not `$var`.

## macOS-first
- This is a macOS-focused tool. All paths, behaviors, and assumptions target macOS.
- `tmutil` is the authoritative interface for Time Machine exclusions.
- Some exclusions may not appear in System Settings UI even when active. Document this.

## Documentation integrity
- **README.md must match the actual implementation.** Do not document features that are not implemented.
- Do not claim more exclusion rules than actually exist in `config/default.conf`.
- Do not reference tmux UI, GUI, or features planned for future versions as if they exist now.

## Code style
- Prefer straightforward shell functions over clever one-liners.
- Use `set -euo pipefail` at the top of scripts.
- Validate arguments early and fail clearly.
- Use comments sparingly but usefully.
- Keep functions focused and readable.

## Testing
- Tests must be updated whenever behavior changes.
- Tests run without requiring real Time Machine mutation (no `sudo`, no actual `tmutil` calls in CI).
- Use the test helper framework in `tests/test_helpers.sh`.

## Config format
- Config files use `type|target|reason` format.
- Supported types: `path`, `pattern`, `prune`.
- Lines starting with `#` are comments.

## When making changes
1. Update the implementation in `tm_exclusions.sh`.
2. Update `config/default.conf` if adding/removing exclusion rules.
3. Update `README.md` to reflect any behavior changes.
4. Update `docs/ARCHITECTURE.md` if the architecture changes.
5. Update or add tests in `tests/`.
6. Run `make lint` and `make test` before committing.
