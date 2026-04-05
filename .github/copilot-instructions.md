# GitHub Copilot Instructions

## Commit message convention

Every commit message in this repository **must** follow the [Conventional Commits](https://www.conventionalcommits.org/) specification, with a **mandatory leading emoji**.

### Format

```
EMOJI <type>[(<scope>)][!]: <description>
```

### Rules

- The **emoji** is **mandatory**. It must be the first character and separated from the type by a single space.
- The **type** is mandatory and must be one of:
  `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `chore`, `ci`, `build`, `revert`
- The **scope** is optional and written in parentheses: `(acl)`, `(policy)`, `(ci)`, etc.
- The `!` suffix is optional and indicates a breaking change.
- The **description** is mandatory, must follow the colon+space, and must not be empty or end with whitespace.
- The first line must match the pattern.

### Valid examples

```
🎉 feat(acl): add new tag for servers
🔒 fix(policy): restrict access to prod
💥 chore!: drop legacy bootstrap config
📝 docs: update setup instructions
🔧 ci(workflow): add policy lint step
♻️ refactor(acl): split host aliases into groups
🚀 feat!: replace deny-all baseline with least-privilege policy
```

### Invalid examples

```
feat(acl): add new tag for servers  ← missing emoji
update stuff                        ← no type, no emoji
WIP                                 ← no type, no emoji
fix:                                ← missing emoji and description
Added tag                           ← no type, no emoji
feat : add tag                      ← space before colon, missing emoji
```

### Enforcement

A `commit-msg` Git hook in `.githooks/` blocks any non-conforming commit locally.
Activate it once after cloning with:

```bash
make setup
```