.PHONY: setup check-hooks help test lint install uninstall check

SCRIPT = tm_exclusions.sh
PREFIX ?= /usr/local/bin
INSTALL_NAME = tm-exclusions
SHARE_DIR ?= $(abspath $(PREFIX)/../share/tm-exclusions)

# Auto-detect whether sudo is required for install/uninstall.
# Override with: make install SUDO='' (skip) or make install SUDO=sudo (force)
SUDO := $(shell if [ -d "$(PREFIX)" ] && [ -w "$(PREFIX)" ]; then echo ''; else echo 'sudo'; fi)

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
	install -m 755 .githooks/post-checkout-fallback "$$HOOKS_DIR/post-checkout"
	@echo "Git hooks installed. Conventional Commits will be enforced on every commit."

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
	@echo "Running ShellCheck..."
	@shellcheck -s bash $(SCRIPT)
	@shellcheck -s bash tests/test_helpers.sh
	@shellcheck -s bash tests/smoke.bats-like.sh
	@echo "ShellCheck passed."

install: setup ## Install tm-exclusions to PREFIX (default: /usr/local/bin)
	@echo "Installing $(INSTALL_NAME) to $(PREFIX)..."
	$(SUDO) install -d "$(SHARE_DIR)"
	$(SUDO) install -m 755 $(SCRIPT) $(PREFIX)/$(INSTALL_NAME)
	$(SUDO) install -m 644 config/default.conf "$(SHARE_DIR)/default.conf"
	@echo "Installed. Run '$(INSTALL_NAME) --help' to get started."

uninstall: ## Remove tm-exclusions from PREFIX
	@echo "Removing $(INSTALL_NAME) from $(PREFIX)..."
	$(SUDO) rm -f $(PREFIX)/$(INSTALL_NAME)
	$(SUDO) rm -f "$(SHARE_DIR)/default.conf"
	@echo "Removed."

check: lint test ## Run all checks (lint + test)
