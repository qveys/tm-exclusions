# Packaging and distribution

## Makefile install (source checkout)

Default layout (see `Makefile`):

| Artifact | Path |
|----------|------|
| CLI | `$(PREFIX)/tm-exclusions` (default `PREFIX=/usr/local/bin`) |
| Built-in rules | `$(SHARE_DIR)/default.conf` with `SHARE_DIR` = `$(abspath $(PREFIX)/../share/tm-exclusions)` |

`tm_exclusions.sh` resolves `config/default.conf` via `resolve_default_conf()` (repo checkout, `../share/tm-exclusions/default.conf` next to the binary, or standard `/usr/local` / `/opt/homebrew` share paths).

## Homebrew

### From this repository (development)

On macOS, with [Homebrew](https://brew.sh/) installed:

```bash
brew install --formula ./Formula/tm-exclusions.rb
```

Bump `url`, `version`, and `sha256` in `Formula/tm-exclusions.rb` when cutting a new tag (or let the tap automation below handle the tap copy).

### From the tap (`qveys/homebrew-tools`)

After a **`v*`** tag is pushed, `.github/workflows/release.yml` (if enabled) creates/updates the GitHub release and bumps **`Formula/tm-exclusions.rb`** in **`qveys/homebrew-tools`** using repository secret **`HOMEBREW_TAP_TOKEN`** (PAT with `repo` on the tap).

Then:

```bash
brew tap qveys/homebrew-tools
brew install tm-exclusions
```

(Confirm the tap name in [qveys/homebrew-tools](https://github.com/qveys/homebrew-tools) if it differs.)

### Tap formula sync

The `install` stanza in the tap **must** match this repo’s `Formula/tm-exclusions.rb` (`bin.install` + `share/tm-exclusions`). The release job only rewrites `url`, `sha256`, and `version` lines; if the install layout changes, update both places (or replace the tap file from this repo once).

## Relationship to epic #34

Homebrew ships the **current 1.x** CLI. Broader behavior parity with the archived 2.x script is tracked in GitHub issue **#34**; packaging does not wait on that epic, but version bumps should stay consistent across `tm_exclusions.sh` `VERSION`, `CHANGELOG.md`, and the formula.
