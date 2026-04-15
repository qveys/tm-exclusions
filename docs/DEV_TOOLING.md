# Developer tooling: `.cursor` vs archived `.claude`

This document compares what ships in **tm-exclusions** today versus the **archived** `tm-exclusion-main` tree (`~/Downloads/tm-exclusion-main`).

## This repository (Cursor-first)

| Area | Location | Role |
|------|----------|------|
| Agent instructions | `AGENTS.md` | Primary doc for AI CLI tools (Cursor, Claude Code, etc.) |
| Cursor rules / skills | `.cursor/skills/` | Repo-local skills (e.g. release orchestration, git cleanup) |
| Hooks | `.githooks/` + `Makefile` `setup` | Conventional Commits, hook fallbacks |
| CI | `.github/workflows/` | Lint, smoke, security, triage, **release** (tag → tap bump) |

There is **no** `.claude/` directory in this repo. Claude Code is expected to read **`AGENTS.md`** (and root **`CLAUDE.md`**, which points here).

## Archived layout (reference)

The archive included **`.claude/`** (project hooks, commands, settings) and a root **`CLAUDE.md`** tailored to that layout. That content is **not** copied verbatim: this project standardized on **`AGENTS.md`** + **`.cursor/skills/`** for agent UX.

## When to add `.claude/`

Optional if you want Claude Code–specific slash commands or settings that do not belong in `AGENTS.md`. Prefer keeping **one** canonical doc (`AGENTS.md`) and small pointers in `CLAUDE.md` to avoid drift.

## Audit checklist (occasional)

- [ ] `AGENTS.md` still lists accurate `make` targets and script entrypoints.
- [ ] `.cursor/skills/*` frontmatter paths still resolve from repo root.
- [ ] No duplicate/conflicting guidance between `CLAUDE.md` and `AGENTS.md`.
