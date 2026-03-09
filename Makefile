.PHONY: test test-verbose lint install-bats help

BATS        := bats
CVM_SCRIPT  := cvm.sh
TEST_DIR    := test/bats

# ── Targets ───────────────────────────────────────────────────────────────────

help:
	@echo "Targets:"
	@echo "  test          Run full test suite"
	@echo "  test-verbose  Run tests with verbose (tap) output"
	@echo "  lint          Syntax-check cvm.sh and install.sh"
	@echo "  install-bats  Install bats-core via Homebrew or npm"

test: _check-bats lint
	@echo ""
	@echo "Running CVM test suite..."
	@echo ""
	@$(BATS) $(TEST_DIR)/*.bats

test-verbose: _check-bats lint
	@$(BATS) --tap $(TEST_DIR)/*.bats

lint:
	@bash -n $(CVM_SCRIPT)  && echo "✓ cvm.sh syntax OK"
	@bash -n install.sh     && echo "✓ install.sh syntax OK"
	@bash -n test/helpers/bin/curl && echo "✓ mock curl syntax OK"

install-bats:
	@if command -v brew >/dev/null 2>&1; then \
		brew install bats-core; \
	elif command -v npm >/dev/null 2>&1; then \
		npm install -g bats; \
	else \
		echo "Install bats manually: https://github.com/bats-core/bats-core"; \
		exit 1; \
	fi

_check-bats:
	@command -v $(BATS) >/dev/null 2>&1 || { \
		echo ""; \
		echo "Error: bats not found. Install it with:"; \
		echo "  make install-bats"; \
		echo "  brew install bats-core"; \
		echo "  npm install -g bats"; \
		echo "  https://github.com/bats-core/bats-core"; \
		echo ""; \
		exit 1; \
	}
