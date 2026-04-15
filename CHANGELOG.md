# Changelog

All notable changes to this project will be documented in this file.

## v1.1.0

### CLI

- Bump embedded version to **1.1.0** (`tm-exclusions --version`).

### CI and automation

- PR triage workflow: apply labels from `docs/LABELS.md` (Area, Type, Status, Priority, Effort, extras); Priority labels are mutually exclusive when multiple match.
- Label catalog reference in-repo (`docs/LABELS.md`) with JSON rules for triage.
- Dependabot for GitHub Actions; consolidated lint + smoke workflow; PR labeler and title normalization; stale bot; dependency review and CodeQL for Actions.

### Docs

- `AGENTS.md` guidance for agentic tools; expanded GitHub label reference.

## v1.0.0

- Initial stable release.
