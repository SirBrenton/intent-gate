# Refuse old Apple /usr/bin/make (3.81) because we rely on .ONESHELL (>= 3.82)
ifeq ($(MAKE_VERSION),3.81)
$(error This repo requires GNU Make >= 3.82. Use `gmake` or `./makew`.)
endif

PY 				:= .venv/bin/python
PIP 			:= .venv/bin/pip
INTENT_GATE 	:= $(PY) ./src/intent_gate.py
IR_TOOL 		:= $(PY) ./src/ir_tool.py
SANDBOX 		:= sandbox

DOCS 			:= docs
DEMO_BEFORE 	:= $(DOCS)/demo_before_denial.txt
DEMO_AFTER 		:= $(DOCS)/demo_after_denial.txt
DEMO_DIFF 		:= $(DOCS)/demo_denial_diff.patch
DEMO_SCOPE 		:= $(DOCS)/demo_scope_mismatch.txt

SHELL 			:= /bin/bash
.ONESHELL:

.PHONY: help venv deps fmt lint test check demo evidence clean

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
	@echo "  make evidence - regenerate denial before/after artifacts + diff"


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
	@set -euo pipefail
	if [ -z "$(SANDBOX)" ] || [ "$(SANDBOX)" = "/" ] || [ "$(SANDBOX)" = "." ] || [ "$(SANDBOX)" = ".." ]; then
		echo "FATAL: SANDBOX is unsafe: '$(SANDBOX)'"
		exit 2
	fi
	rm -f audit.jsonl
	mkdir -p "$(SANDBOX)"
	echo "hello" > "$(SANDBOX)/foo.txt"
	IR="$$( $(IR_TOOL) new --root "$(SANDBOX)" --actions delete --note "delete foo.txt in sandbox" )"
	echo
	echo "1) Expect DENY without Intent Record:"
	out1="$$( $(INTENT_GATE) --dry-run --print-decision -- rm foo.txt 2>&1 || true )"
	echo "$$out1"
	echo "$$out1" | grep -q "Denial Context Snapshot"
	echo "$$out1" | grep -q "did not influence the denial"
	echo
	echo "2) Expect ALLOW with Intent Record:"
	$(INTENT_GATE) --dry-run --print-decision --intent "$$IR" -- rm foo.txt
	echo
	echo "3) Execute delete (should succeed):"
	$(INTENT_GATE) --intent "$$IR" -- rm foo.txt
	test ! -e "$(SANDBOX)/foo.txt"
	echo
	echo "4) Sandbox listing:"
	ls -la "$(SANDBOX)"
	echo
	echo "5) Audit tail:"
	tail -n 4 audit.jsonl
	echo
	echo "6) Audit assertions:"
	grep -q '"event": "execution"' audit.jsonl
	grep -q '"returncode": 0' audit.jsonl
	echo "OK: execution recorded and returncode=0"
	echo
	echo "7) Audit counts:"
	grep -c '"event": "decision"' audit.jsonl
	grep -c '"event": "execution"' audit.jsonl


evidence:
	@DOCS="$(DOCS)" SANDBOX="$(SANDBOX)" PY="$(PY)" \
	  INTENT_GATE='$(INTENT_GATE)' IR_TOOL='$(IR_TOOL)' \
	  DEMO_BEFORE="$(DEMO_BEFORE)" DEMO_AFTER="$(DEMO_AFTER)" \
	  DEMO_DIFF="$(DEMO_DIFF)" DEMO_SCOPE="$(DEMO_SCOPE)" \
	  ./scripts/evidence.sh


clean:
	@set -euo pipefail
	if [ -z "$(SANDBOX)" ] || [ "$(SANDBOX)" = "/" ] || [ "$(SANDBOX)" = "." ] || [ "$(SANDBOX)" = ".." ]; then
		echo "FATAL: SANDBOX is unsafe: '$(SANDBOX)'"
		exit 2
	fi
	rm -rf -- "$(SANDBOX)"/*
	find . -name "__pycache__" -type d -prune -exec rm -rf {} +
	find . -name "*.pyc" -delete