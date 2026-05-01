# Packaging and distribution

## Makefile install (source checkout)

Default layout (see `Makefile`):

| Artifact | Path |
|----------|------|
| CLI | `$(PREFIX)/tm-exclusions` (default `PREFIX=/usr/local/bin`) |
| Built-in rules | `$(SHARE_DIR)/default.conf` with `SHARE_DIR` = `$(abspath $(PREFIX)/../share/tm-exclusions)` |

`tm_exclusions.sh` resolves the default rules via `resolve_default_conf()`: optional **`TM_EXCLUSIONS_DEFAULT_CONF`** override first; else `config/default.conf` (repo), `../share/tm-exclusions/default.conf` (next to the binary), then `/usr/local/share/tm-exclusions/default.conf`, `/opt/homebrew/share/tm-exclusions/default.conf`, and `/usr/share/tm-exclusions/default.conf`.

## Homebrew

### From this repository (development)

On macOS, with [Homebrew](https://brew.sh/) installed:

```bash
brew install --formula ./Formula/tm-exclusions.rb
```

The local formula is mainly a development install fixture. Do not bump only its `version` during a release PR; the tap automation below updates `url`, `version`, and `sha256` together after the tag exists.

### From the tap (`qveys/homebrew-tools`)

After a **`v*`** tag is pushed, `.github/workflows/release.yml` (if enabled) creates/updates the GitHub Release and bumps **`Formula/tm-exclusions.rb`** in **`qveys/homebrew-tools`** using repository secret **`HOMEBREW_TAP_TOKEN`** (PAT with `repo` on the tap).

Then:

```bash
brew tap qveys/tools
brew install tm-exclusions
```

(Confirm the tap name in [qveys/homebrew-tools](https://github.com/qveys/homebrew-tools) if it differs.)

### Tap formula sync

The release job (`.github/workflows/release.yml`) **fully replaces** `Formula/tm-exclusions.rb` in the tap with this repo’s copy at the released tag, then patches the `url`, `sha256`, and `version` lines. The install stanza therefore always matches what the release tarball actually ships — no manual sync required when the install layout changes.

If a past release (e.g. before this auto-sync was in place) left a stale install stanza in the tap, re-run the workflow manually against that tag to re-sync without cutting a new release: **Actions → Release → Run workflow** (select `master` as the branch — older tags predate the `workflow_dispatch` trigger) **→ tag: `vX.Y.Z`**.

## Relationship to epic #34

Homebrew ships the **current 1.x** CLI. Broader behavior parity with the archived 2.x script is tracked in GitHub issue **#34**; packaging does not wait on that epic. Release PRs should keep `tm_exclusions.sh` `VERSION`, `CHANGELOG.md`, and version smoke tests in sync; the Homebrew tap formula is updated by release automation after the tag is pushed.
