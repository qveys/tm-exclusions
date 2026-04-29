# Security Policy

## Supported Versions

Security fixes target the latest minor release on `master`. Older releases are not patched — upgrade to the latest tagged version.

| Version | Supported |
|--------:|:---------:|
| Latest `v1.x` | ✅ |
| Older `v1.x` | ❌ |

## Reporting a Vulnerability

**Do not open a public issue for security reports.**

Use GitHub's private vulnerability reporting:

1. Go to [Security advisories](https://github.com/qveys/tm-exclusions/security/advisories/new).
2. Fill in the form with reproduction steps and impact.
3. The maintainer is notified privately and will acknowledge within 7 days.

If GitHub's flow is unavailable, email `contact@quentinveys.be` with subject prefix `[tm-exclusions security]`.

## Scope

This project is a Bash CLI that calls `tmutil` to manage Time Machine exclusions on macOS. Reports of interest:

- Command injection via crafted config entries, env vars, or CLI arguments.
- Unintended privilege escalation (e.g. `sudo` invocation paths that read attacker-controlled data).
- Path traversal that causes exclusions outside `$HOME` / configured roots.
- Workflow injection in `.github/workflows/` (untrusted PR title/body landing in `run:` blocks).

Out of scope: behaviour of `tmutil` itself, macOS system-level issues, and theoretical issues without a reproducible exploit on a stock macOS install.

## Disclosure

Coordinated disclosure preferred. Once a fix is released, credit goes in `CHANGELOG.md` and the GitHub Security Advisory unless you request otherwise.
