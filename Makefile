.PHONY: setup check-hooks help test lint install uninstall check release tag

SCRIPT = tm_exclusions.sh
PREFIX ?= /usr/local/bin
INSTALL_NAME = tm-exclusions
SHARE_DIR ?= $(abspath $(PREFIX)/../share/tm-exclusions)
BASE_BRANCH ?= master

# Auto-detect whether sudo is required for install/uninstall.
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

test: ## Run smoke tests
	@echo "Running smoke tests..."
	@bash tests/smoke.bats-like.sh

lint: ## Run ShellCheck on all shell scripts
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
	@shellcheck -x -s sh .githooks/post-checkout
	@shellcheck -x -s sh .githooks/post-checkout-fallback
	@shellcheck -x -s sh .githooks/post-merge
	@shellcheck -x -s sh .githooks/post-merge-fallback
	@shellcheck -x -s sh .githooks/prune-gone-branches.sh
	@echo "ShellCheck passed."

install: setup ## Install tm-exclusions to PREFIX (default: /usr/local/bin)
	@echo "Installing $(INSTALL_NAME) to $(PREFIX)..."
	@if [ -n "$(SUDO)" ]; then $(SUDO) -v; fi
	@$(SUDO) sh -c 'install -d "$(SHARE_DIR)" && install -m 755 "$(SCRIPT)" "$(PREFIX)/$(INSTALL_NAME)" && install -m 644 config/default.conf "$(SHARE_DIR)/default.conf"'
	@echo "Installed. Run '$(INSTALL_NAME) --help' to get started."

uninstall: ## Remove tm-exclusions from PREFIX
	@if [ ! -f "$(PREFIX)/$(INSTALL_NAME)" ] && [ ! -f "$(SHARE_DIR)/default.conf" ]; then \
	  echo "$(INSTALL_NAME) is not installed. Nothing to remove."; \
	else \
	  echo "Removing $(INSTALL_NAME) from $(PREFIX)..."; \
	  if [ -n "$(SUDO)" ]; then $(SUDO) -v; fi; \
	  $(SUDO) rm -f "$(PREFIX)/$(INSTALL_NAME)" "$(SHARE_DIR)/default.conf"; \
	  if [ -d "$(SHARE_DIR)" ]; then $(SUDO) rmdir "$(SHARE_DIR)" 2>/dev/null || true; fi; \
	  echo "Removed."; \
	fi

check: lint test ## Run all checks (lint + test)

release: ## Cut a release PR — make release VERSION=x.y.z  (run make tag after merge)
	@test -n "$(VERSION)" || { echo "Usage: make release VERSION=x.y.z" >&2; exit 1; }
	@command -v gh >/dev/null 2>&1 || { \
	  echo "Error: gh CLI not installed." >&2; \
	  echo "Install it with: brew install gh" >&2; \
	  echo "Or see https://cli.github.com/" >&2; \
	  exit 1; \
	}
	@git diff --quiet && git diff --cached --quiet || \
	  { echo "Error: uncommitted changes — commit or stash first." >&2; exit 1; }
	@if git show-ref --verify --quiet refs/heads/release/v$(VERSION); then \
	  echo "Error: branch release/v$(VERSION) already exists." >&2; \
	  exit 1; \
	fi
	@$(MAKE) check
	@git checkout -b release/v$(VERSION)
	@current_version="$$(sed -n 's/^readonly VERSION="\([^"]*\)"/\1/p' $(SCRIPT))"; \
	  test -n "$$current_version" || { echo "Error: could not determine current version from $(SCRIPT)." >&2; exit 1; }; \
	  tmp_file="$$(mktemp)"; \
	  sed 's|^readonly VERSION=".*"|readonly VERSION="$(VERSION)"|' $(SCRIPT) > "$$tmp_file" && mv "$$tmp_file" $(SCRIPT)
	@tmp_file="$$(mktemp)"; \
	  awk '/^## Unreleased$$/{print; print ""; print "## v$(VERSION)"; next}1' CHANGELOG.md > "$$tmp_file" && mv "$$tmp_file" CHANGELOG.md
	@git add $(SCRIPT) CHANGELOG.md
	@git commit -m "🔖 chore(release): bump to v$(VERSION)"
	@git push -u origin release/v$(VERSION)
	@printf 'Release v$(VERSION).\n\nAfter merge, push the tag to trigger the GitHub release workflow:\n```\nmake tag VERSION=$(VERSION)\n```\n' | \
	  gh pr create --title "🔖 chore(release): v$(VERSION)" --body-file - --base $(BASE_BRANCH)

tag: ## Push the release tag after the release PR is merged — make tag VERSION=x.y.z
	@test -n "$(VERSION)" || { echo "Usage: make tag VERSION=x.y.z" >&2; exit 1; }
	@git fetch origin
	@git tag v$(VERSION) origin/$(BASE_BRANCH)
	@git push origin v$(VERSION)
