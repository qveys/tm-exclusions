.PHONY: setup check-hooks help test lint install uninstall check release tag version auto-patch

SCRIPT = tm_exclusions.sh
# Homebrew bin if writable (typical Apple Silicon), else /usr/local/bin.
# Override with: make install PREFIX=/some/bin
PREFIX ?= $(shell \
  bp=""; \
  if [ -n "$$HOMEBREW_PREFIX" ]; then bp="$$HOMEBREW_PREFIX"; \
  elif command -v brew >/dev/null 2>&1; then bp=$$(brew --prefix 2>/dev/null); fi; \
  if [ -n "$$bp" ] && [ -d "$$bp/bin" ] && [ -w "$$bp/bin" ]; then echo "$$bp/bin"; \
  else echo /usr/local/bin; fi)
INSTALL_NAME = tm-exclusions
SHARE_DIR ?= $(abspath $(PREFIX)/../share/tm-exclusions)
BASE_BRANCH ?= master
INSTALL_BIN = /usr/bin/install
RM_BIN = /bin/rm
RMDIR_BIN = /bin/rmdir

# Auto-detect whether elevation is required for install/uninstall.
# Override with: make install SUDO= (skip) or make install SUDO=sudo (force)
SUDO := $(shell \
  prefix_ok=''; share_ok=''; \
  if [ -d "$(PREFIX)" ]; then \
    if [ -w "$(PREFIX)" ]; then prefix_ok=1; fi; \
  elif [ -w "$(dir $(PREFIX))" ]; then \
    prefix_ok=1; \
  fi; \
  if [ -d "$(SHARE_DIR)" ]; then \
    if [ -w "$(SHARE_DIR)" ]; then share_ok=1; fi; \
  elif [ -w "$(dir $(SHARE_DIR))" ]; then \
    share_ok=1; \
  fi; \
  if [ -n "$$prefix_ok" ] && [ -n "$$share_ok" ]; then echo ''; \
  else echo 'sudo'; fi)

# Guard: install paths are embedded in shell source as single-quoted literals,
# so a path containing a single quote would silently mangle the destination.
# Checked at make level: by the time the shell sees it, the quoting is broken.
QUOTE := '
CHECK_QUOTES = $(if $(findstring $(QUOTE),$(CURDIR)$(PREFIX)$(SHARE_DIR)),\
  $(error Paths containing a single quote are not supported: $(CURDIR) $(PREFIX) $(SHARE_DIR)))

# Shell snippet: request macOS admin (Authorization Services), else print fallback.
# Expects $$cmd (POSIX command string, absolute paths, single-quoted arguments).
# Bypasses sudoers whitelist.
OSASCRIPT_OR_DIE = \
	echo "Requesting administrator privileges..."; \
	quoted=$$(printf '%s' "$$cmd" | sed 's/\\/\\\\/g; s/"/\\"/g'); \
	if command -v osascript >/dev/null 2>&1 && osascript -e "do shell script \"$$quoted\" with administrator privileges"; then \
	  :; \
	else \
	  echo "Error: could not modify $$PRE (privilege elevation failed)." >&2; \
	  echo "Try:  make install PREFIX=\"\$$(brew --prefix)/bin\"" >&2; \
	  echo "  or: brew install --formula ./Formula/tm-exclusions.rb" >&2; \
	  exit 1; \
	fi

# Auto-bootstrap the versioned hooks path on every `make` invocation so the
# local Conventional Commit hooks are active without requiring manual setup.
_ := $(shell git config core.hooksPath .githooks 2>/dev/null)

setup: ## Explicitly install local Git hooks (also runs automatically on any 'make' invocation)
	@git config core.hooksPath .githooks
	@set -e; \
	HOOKS_DIR=$$(git rev-parse --git-common-dir)/hooks; \
	mkdir -p "$$HOOKS_DIR"; \
	install -m 755 .githooks/commit-msg-fallback "$$HOOKS_DIR/commit-msg"; \
	install -m 755 .githooks/prepare-commit-msg-fallback "$$HOOKS_DIR/prepare-commit-msg"; \
	install -m 755 .githooks/post-checkout-fallback "$$HOOKS_DIR/post-checkout"; \
	install -m 755 .githooks/post-merge-fallback "$$HOOKS_DIR/post-merge"
	@echo "Git hooks installed (commit-msg, prepare-commit-msg, post-checkout, post-merge). Conventional Commits will be enforced on every commit."

check-hooks: ## Verify that the local Git hooks are active; exit 1 if not
	@HOOKS_PATH=$$(git config core.hooksPath 2>/dev/null); \
	if [ "$$HOOKS_PATH" = ".githooks" ]; then \
	  echo "Git hooks are active (core.hooksPath = .githooks)."; \
	else \
	  echo "Git hooks are NOT active. Run 'make setup' or 'make install' to install them." >&2; \
	  exit 1; \
	fi

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

version: ## Print the current tm-exclusions version
	@version="$$(sed -n 's/^readonly VERSION="\([^"]*\)"/\1/p' $(SCRIPT))"; \
	  test -n "$$version" || { echo "Error: could not determine version from $(SCRIPT)." >&2; exit 1; }; \
	  printf '%s\n' "$$version"

test: ## Run smoke tests
	@echo "Running smoke tests..."
	@bash tests/smoke.bats-like.sh
	@echo "Running release logic tests..."
	@bash tests/test_release_logic.sh

lint: ## Run ShellCheck on all shell scripts and syntax-check locale tables
	@if ! command -v shellcheck >/dev/null 2>&1; then \
	  echo "Error: shellcheck is not installed." >&2; \
	  echo "Install it with: brew install shellcheck" >&2; \
	  echo "Or see https://github.com/koalaman/shellcheck#installing" >&2; \
	  exit 1; \
	fi
	@echo "Running ShellCheck..."
	@shellcheck -x -s bash $(SCRIPT)
	@shellcheck -x -s bash tests/test_helpers.sh
	@shellcheck -x -s bash tests/smoke.bats-like.sh
	@shellcheck -x -s bash tests/test_release_logic.sh
	@for f in locales/*.sh; do bash -n "$$f" || exit 1; done
	@shellcheck -x -s sh .githooks/post-checkout
	@shellcheck -x -s sh .githooks/post-checkout-fallback
	@shellcheck -x -s sh .githooks/post-merge
	@shellcheck -x -s sh .githooks/post-merge-fallback
	@shellcheck -x -s sh .githooks/prune-gone-branches.sh
	@shellcheck -x -s bash scripts/check-auto-patch.sh
	@echo "ShellCheck passed."

install: setup ## Install tm-exclusions to PREFIX (Homebrew bin if writable, else /usr/local/bin)
	@echo "Installing $(INSTALL_NAME) to $(PREFIX)..."
	@$(CHECK_QUOTES)CUR='$(CURDIR)'; PRE='$(PREFIX)'; SHR='$(SHARE_DIR)'; \
	cmd="$(INSTALL_BIN) -d '$$SHR' '$$SHR/locales' '$$PRE' && $(INSTALL_BIN) -m 755 '$$CUR/$(SCRIPT)' '$$PRE/$(INSTALL_NAME)' && $(INSTALL_BIN) -m 644 '$$CUR/config/default.conf' '$$SHR/default.conf' && $(INSTALL_BIN) -m 644 '$$CUR/config/extra-prunes.example.conf' '$$SHR/extra-prunes.example.conf' && $(INSTALL_BIN) -m 644 '$$CUR'/locales/*.sh '$$SHR/locales/'"; \
	if [ -z "$(SUDO)" ]; then \
	  $(INSTALL_BIN) -d "$$SHR" "$$SHR/locales" "$$PRE" \
	  && $(INSTALL_BIN) -m 755 "$$CUR/$(SCRIPT)" "$$PRE/$(INSTALL_NAME)" \
	  && $(INSTALL_BIN) -m 644 "$$CUR/config/default.conf" "$$SHR/default.conf" \
	  && $(INSTALL_BIN) -m 644 "$$CUR/config/extra-prunes.example.conf" "$$SHR/extra-prunes.example.conf" \
	  && $(INSTALL_BIN) -m 644 "$$CUR"/locales/*.sh "$$SHR/locales/"; \
	elif $(SUDO) $(INSTALL_BIN) -d "$$SHR" "$$SHR/locales" "$$PRE" \
	  && $(SUDO) $(INSTALL_BIN) -m 755 "$$CUR/$(SCRIPT)" "$$PRE/$(INSTALL_NAME)" \
	  && $(SUDO) $(INSTALL_BIN) -m 644 "$$CUR/config/default.conf" "$$SHR/default.conf" \
	  && $(SUDO) $(INSTALL_BIN) -m 644 "$$CUR/config/extra-prunes.example.conf" "$$SHR/extra-prunes.example.conf" \
	  && $(SUDO) $(INSTALL_BIN) -m 644 "$$CUR"/locales/*.sh "$$SHR/locales/"; then \
	  :; \
	else \
	  $(OSASCRIPT_OR_DIE); \
	fi
	@echo "Installed. Run '$(INSTALL_NAME) --help' to get started."

uninstall: ## Remove tm-exclusions from PREFIX
	@$(CHECK_QUOTES)PRE='$(PREFIX)'; SHR='$(SHARE_DIR)'; \
	if [ ! -f "$$PRE/$(INSTALL_NAME)" ] && [ ! -f "$$SHR/default.conf" ]; then \
	  echo "$(INSTALL_NAME) is not installed. Nothing to remove."; \
	else \
	  echo "Removing $(INSTALL_NAME) from $$PRE..."; \
	  cmd="$(RM_BIN) -f '$$PRE/$(INSTALL_NAME)' '$$SHR/default.conf' '$$SHR/extra-prunes.example.conf' '$$SHR/locales/'*.sh || exit \$$?; if [ -d '$$SHR/locales' ]; then $(RMDIR_BIN) '$$SHR/locales' 2>/dev/null || true; fi; if [ -d '$$SHR' ]; then $(RMDIR_BIN) '$$SHR' 2>/dev/null || true; fi"; \
	  if [ -z "$(SUDO)" ]; then \
	    $(RM_BIN) -f "$$PRE/$(INSTALL_NAME)" "$$SHR/default.conf" "$$SHR/extra-prunes.example.conf" "$$SHR/locales/"*.sh || exit $$?; \
	    if [ -d "$$SHR/locales" ]; then $(RMDIR_BIN) "$$SHR/locales" 2>/dev/null || true; fi; \
	    if [ -d "$$SHR" ]; then $(RMDIR_BIN) "$$SHR" 2>/dev/null || true; fi; \
	  elif $(SUDO) $(RM_BIN) -f "$$PRE/$(INSTALL_NAME)" "$$SHR/default.conf" "$$SHR/extra-prunes.example.conf" "$$SHR/locales/"*.sh; then \
	    if [ -d "$$SHR/locales" ]; then $(SUDO) $(RMDIR_BIN) "$$SHR/locales" 2>/dev/null || true; fi; \
	    if [ -d "$$SHR" ]; then $(SUDO) $(RMDIR_BIN) "$$SHR" 2>/dev/null || true; fi; \
	  else \
	    $(OSASCRIPT_OR_DIE); \
	  fi; \
	  echo "Removed."; \
	fi

check: lint test ## Run all checks (lint + test)

release: ## Cut a release PR — make release VERSION=x.y.z  (run make tag after merge)
	@test -n "$(VERSION)" || { echo "Usage: make release VERSION=x.y.z" >&2; exit 1; }
	@echo "$(VERSION)" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$$' || \
	  { echo "Error: VERSION must match X.Y.Z (got: $(VERSION))." >&2; exit 1; }
	@command -v gh >/dev/null 2>&1 || { \
	  echo "Error: gh CLI not installed." >&2; \
	  echo "Install it with: brew install gh" >&2; \
	  echo "Or see https://cli.github.com/" >&2; \
	  exit 1; \
	}
	@git diff --quiet && git diff --cached --quiet || \
	  { echo "Error: uncommitted changes — commit or stash first." >&2; exit 1; }
	@git fetch origin $(BASE_BRANCH)
	@if git show-ref --verify --quiet refs/heads/release/v$(VERSION) || \
	    git ls-remote --exit-code --heads origin "release/v$(VERSION)" >/dev/null 2>&1; then \
	  echo "Error: branch release/v$(VERSION) already exists (locally or on origin)." >&2; \
	  exit 1; \
	fi
	@grep -q '^## Unreleased$$' CHANGELOG.md || \
	  { echo "Error: CHANGELOG.md is missing a '## Unreleased' section to roll into v$(VERSION)." >&2; exit 1; }
	@unreleased_content="$$(awk '/^## Unreleased$$/{found=1; next} found && /^## /{found=0} found && NF{print}' CHANGELOG.md)"; \
	  test -n "$$unreleased_content" || { \
	    echo "Error: '## Unreleased' section in CHANGELOG.md is empty. Add release notes before cutting a release." >&2; \
	    exit 1; \
	  }
	@$(MAKE) check
	@git checkout -b release/v$(VERSION) origin/$(BASE_BRANCH)
	@current_version="$$(sed -n 's/^readonly VERSION="\([^"]*\)"/\1/p' $(SCRIPT))"; \
	  test -n "$$current_version" || { echo "Error: could not determine current version from $(SCRIPT)." >&2; exit 1; }; \
	  tmp_file="$$(mktemp)"; \
	  sed 's|^readonly VERSION=".*"|readonly VERSION="$(VERSION)"|' $(SCRIPT) > "$$tmp_file" && mv "$$tmp_file" $(SCRIPT)
# Formula/tm-exclusions.rb is deliberately left alone: its url/sha256 can only be
# updated once the tag exists, so bumping version alone would make the local formula
# install the previous tarball under the new version (see docs/PACKAGING.md).
	@tmp_file="$$(mktemp)"; \
	  awk '/^## Unreleased$$/{print; print ""; print "## v$(VERSION)"; next}1' CHANGELOG.md > "$$tmp_file" && mv "$$tmp_file" CHANGELOG.md
	@git add $(SCRIPT) CHANGELOG.md
	@git commit -m "🔖 chore(release): bump to v$(VERSION)"
	@git push -u origin release/v$(VERSION)
	@pr_body="$$(printf 'Release v%s.\n\n### Changelog\n\n%s\n\n---\nAfter merge, push the tag to trigger the GitHub release workflow:\n```\nmake tag VERSION=%s\n```\n' "$(VERSION)" "$$(awk '/^## v$(VERSION)$$/{found=1; next} found && /^## /{found=0} found && NF{print}' CHANGELOG.md)" "$(VERSION)")"; \
	  printf '%s\n' "$$pr_body" | gh pr create --title "🔖 chore(release): v$(VERSION)" --body-file - --base $(BASE_BRANCH)

auto-patch: ## Check or execute auto-patch PR after >=5 PRs (use DRY_RUN=1 for test only)
	@if [ "$$(echo "$${DRY_RUN:-0}")" = "1" ]; then \
	  bash scripts/check-auto-patch.sh --dry-run; \
	else \
	  bash scripts/check-auto-patch.sh; \
	fi

tag: ## Push the signed release tag after the release PR is merged — make tag VERSION=x.y.z
	@test -n "$(VERSION)" || { echo "Usage: make tag VERSION=x.y.z" >&2; exit 1; }
	@echo "$(VERSION)" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$$' || \
	  { echo "Error: VERSION must match X.Y.Z (got: $(VERSION))." >&2; exit 1; }
	@signing_key="$$(git config --get user.signingkey)"; \
	  test -n "$$signing_key" || { \
	    echo "Error: user.signingkey is empty or unset — required for signed tags (the 'tag' ruleset enforces signatures)." >&2; \
	    echo "Configure with: git config --global user.signingkey <KEYID>" >&2; \
	    exit 1; \
	  }
	@git fetch origin
	@if git rev-parse --verify --quiet "v$(VERSION)" >/dev/null || \
	    git ls-remote --exit-code --tags origin "v$(VERSION)" >/dev/null 2>&1; then \
	  echo "Error: tag v$(VERSION) already exists (locally or on origin)." >&2; \
	  exit 1; \
	fi
	@base_version="$$(git show "origin/$(BASE_BRANCH):$(SCRIPT)" | sed -n 's/^readonly VERSION="\([^"]*\)"/\1/p')"; \
	  if [ "$$base_version" != "$(VERSION)" ]; then \
	    echo "Error: $(SCRIPT) on origin/$(BASE_BRANCH) has VERSION=\"$$base_version\", expected \"$(VERSION)\"." >&2; \
	    echo "Make sure 'make release VERSION=$(VERSION)' was merged before tagging." >&2; \
	    exit 1; \
	  fi
	@git tag -s v$(VERSION) origin/$(BASE_BRANCH) -m "Release v$(VERSION)"
	@git push origin v$(VERSION)
