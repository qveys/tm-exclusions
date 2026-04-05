.PHONY: setup install check-hooks

# ---------------------------------------------------------------------------
# Auto-bootstrap: configure the versioned hooks path on every 'make' invocation
# so that commit-msg and prepare-commit-msg hooks are always active without
# requiring an explicit 'make setup' first.
# The := assignment forces immediate evaluation at Makefile parse time, meaning
# the git config command runs before any target — idempotent and transparent.
# stderr is suppressed (2>/dev/null) to stay silent when invoked outside a git
# repository (e.g. some CI runners that only mount the Makefile).
# ---------------------------------------------------------------------------
_ := $(shell git config core.hooksPath .githooks 2>/dev/null)

setup: ## Explicitly install local Git hooks (also runs automatically on any 'make' invocation)
	git config core.hooksPath .githooks
	@set -e; \
	HOOKS_DIR=$$(git rev-parse --git-common-dir)/hooks; \
	mkdir -p "$$HOOKS_DIR"; \
	install -m 755 .githooks/commit-msg-fallback "$$HOOKS_DIR/commit-msg"; \
	install -m 755 .githooks/prepare-commit-msg-fallback "$$HOOKS_DIR/prepare-commit-msg"; \
	install -m 755 .githooks/post-checkout-fallback "$$HOOKS_DIR/post-checkout"
	@echo "✅  Git hooks installed. Conventional Commits will be enforced on every commit."

install: setup ## Install Git hooks (alias for setup)

check-hooks: ## Verify that the local Git hooks are active; exit 1 if not
	@HOOKS_PATH=$$(git config core.hooksPath 2>/dev/null); \
	if [ "$$HOOKS_PATH" = ".githooks" ]; then \
	  echo "✅  Git hooks are active (core.hooksPath = .githooks)."; \
	else \
	  echo "⚠️  Git hooks are NOT active. Run 'make setup' or 'make install' to install them." >&2; \
	  exit 1; \
	fi

check: check-hooks ## Check if Git hooks are active (alias for check-hooks)