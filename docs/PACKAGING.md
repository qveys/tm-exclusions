# Packaging and distribution

## Makefile install (source checkout)

Default layout (see `Makefile`):

| Artifact | Path |
|----------|------|
| CLI | `$(PREFIX)/tm-exclusions` — `PREFIX` defaults to `$(brew --prefix)/bin` when that directory is writable, otherwise `/usr/local/bin` |
| Built-in rules | `$(SHARE_DIR)/default.conf` with `SHARE_DIR` = `$(abspath $(PREFIX)/../share/tm-exclusions)` |
| Locale strings | `$(SHARE_DIR)/locales/en.sh` and `$(SHARE_DIR)/locales/fr.sh` |

`make install` / `make uninstall` never wrap the payload in `sudo sh -c` (sudoers often allows `sudo -v` but not `/bin/sh -c …`). Elevation order: write as the current user when `PREFIX` and `SHARE_DIR` are writable; else `sudo /usr/bin/install` (or `/bin/rm`) per file; else a macOS admin dialog via `osascript` (`do shell script … with administrator privileges`). Override with `PREFIX=…`, `SUDO=` (skip elevation), or `SUDO=sudo` (force).

`tm_exclusions.sh` resolves the default rules via `resolve_default_conf()`: optional **`TM_EXCLUSIONS_DEFAULT_CONF`** override first; else `config/default.conf` (repo), `../share/tm-exclusions/default.conf` (next to the binary), then `/usr/local/share/tm-exclusions/default.conf`, `/opt/homebrew/share/tm-exclusions/default.conf`, and `/usr/share/tm-exclusions/default.conf`.

Locale files are resolved by `resolve_locales_dir()`: **`TM_EXCLUSIONS_LOCALES_DIR`** when set (ignored under `EUID` 0, so `sudo -E` cannot redirect a `source`d path); else `<script_dir>/locales/` (repo checkout), `<script_dir>/../share/tm-exclusions/locales/` (next to the binary), then the `/usr/local`, `/opt/homebrew` and `/usr` share roots. There is no embedded fallback: a missing locale file is a fatal error.

## Homebrew

### From this repository (development)

On macOS, with [Homebrew](https://brew.sh/) installed:

```bash
brew install --formula ./Formula/tm-exclusions.rb
```

The local formula is mainly a development install fixture. Do not bump only its `version` during a release PR; the tap automation below updates `url`, `version`, and `sha256` together after the tag exists.

### From the tap (`qveys/homebrew-tools`)

After a **`v*`** tag is pushed, `.github/workflows/release.yml` creates/updates the GitHub Release (injecting release notes extracted directly from `CHANGELOG.md`) and updates **`Formula/tm-exclusions.rb`** in **`qveys/homebrew-tools`** using repository secret **`HOMEBREW_TOKEN`** (PAT with `repo` scope on the tap).

Then:

```bash
brew tap qveys/tools
brew install tm-exclusions
```

(Confirm the tap name in [qveys/homebrew-tools](https://github.com/qveys/homebrew-tools) if it differs.)

### Tap formula sync

The release job (`.github/workflows/release.yml`) **fully replaces** `Formula/tm-exclusions.rb` in the tap with this repo’s copy at the released tag, then patches the `url`, `sha256`, and `version` lines. The install stanza therefore always matches what the release tarball actually ships — avoiding drift or missing asset errors.

If a past release needs a formula re-sync without cutting a new release, trigger the workflow manually from GitHub Actions: **Actions → Release → Run workflow → tag: `vX.Y.Z`**.

## Release cadence and automation

- **Manual releases (Major / Minor / deliberate Patch)**: run `make release VERSION=x.y.z` to cut a release PR with checked changelog notes, merge on GitHub, then run `make tag VERSION=x.y.z` to push the signed tag.
- **Automated patch releases (Cadence of 5 PRs)**: `.github/workflows/auto-patch.yml` runs after every push to `master`. If $\ge 5$ PRs have been merged since the last release tag without an intermediate manual release, it automatically applies the patch release directly on `master` (bumps `VERSION`, rolls `CHANGELOG.md`, tags `vX.Y.(Z+1)` and publishes to GitHub and Homebrew) without requiring an intermediate PR. Inspect status locally at any time with `make auto-patch DRY_RUN=1`.

## Relationship to epic #34

Homebrew ships the **current 1.x** CLI. Broader behavior parity with the archived 2.x script is tracked in GitHub issue **#34**; packaging does not wait on that epic. Release PRs keep `tm_exclusions.sh` `VERSION`, `Formula/tm-exclusions.rb`, and `CHANGELOG.md` in sync; the Homebrew tap formula is updated by release automation after the tag is pushed.
