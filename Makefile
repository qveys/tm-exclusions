.PHONY: test lint install uninstall help

SCRIPT = tm_exclusions.sh
PREFIX ?= /usr/local/bin
INSTALL_NAME = tm-exclusions

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

install: ## Install tm-exclusions to PREFIX (default: /usr/local/bin)
	@echo "Installing $(INSTALL_NAME) to $(PREFIX)..."
	@install -m 755 $(SCRIPT) $(PREFIX)/$(INSTALL_NAME)
	@echo "Installed. Run '$(INSTALL_NAME) --help' to get started."

uninstall: ## Remove tm-exclusions from PREFIX
	@echo "Removing $(INSTALL_NAME) from $(PREFIX)..."
	@rm -f $(PREFIX)/$(INSTALL_NAME)
	@echo "Removed."

check: lint test ## Run all checks (lint + test)
