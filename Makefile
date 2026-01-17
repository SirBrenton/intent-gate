PY := .venv/bin/python
PIP := .venv/bin/pip
INTENT_GATE := ./src/intent_gate.py
IR_TOOL := ./src/ir_tool.py
SANDBOX := sandbox

.PHONY: help venv deps fmt lint test check demo clean

help:
	@echo "Targets:"
	@echo "  make venv   - create venv"
	@echo "  make deps   - install deps"
	@echo "  make fmt    - format (placeholder until ruff/black added)"
	@echo "  make lint   - lint (placeholder until ruff added)"
	@echo "  make test   - run pytest"
	@echo "  make check  - fmt + lint + test"
	@echo "  make demo   - run the canonical intent-gate demo"
	@echo "  make clean  - remove sandbox contents + __pycache__"

venv:
	python3 -m venv .venv

deps:
	$(PIP) install -U pip
	$(PIP) install pyyaml python-dateutil pytest

# --- Quality gates (add tools later) ---
fmt:
	@echo "TODO: add formatter (ruff/black)."

lint:
	@echo "TODO: add linter (ruff)."

check: fmt lint test
# -------------------------------------

test:
	.venv/bin/pytest -q

demo:
	@set -euo pipefail; \
	mkdir -p "$(SANDBOX)"; \
	echo "hello" > "$(SANDBOX)/foo.txt"; \
	IR="$$( $(IR_TOOL) new --root "$(SANDBOX)" --actions delete --note "delete foo.txt in sandbox" )"; \
	echo ""; \
	echo "1) Expect DENY without Intent Record:"; \
	$(INTENT_GATE) --dry-run --print-decision -- rm foo.txt || true; \
	echo ""; \
	echo "2) Expect ALLOW with Intent Record:"; \
	$(INTENT_GATE) --dry-run --print-decision --intent "$$IR" -- rm foo.txt; \
	echo ""; \
	echo "3) Execute delete (should succeed):"; \
	$(INTENT_GATE) --intent "$$IR" -- rm foo.txt; \
	echo ""; \
	echo "4) Sandbox listing:"; \
	ls -la "$(SANDBOX)"

clean:
	rm -rf "$(SANDBOX)"/*
	find . -name "__pycache__" -type d -prune -exec rm -rf {} +
	find . -name "*.pyc" -delete
