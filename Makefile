PY 				:= .venv/bin/python
PIP 			:= .venv/bin/pip
INTENT_GATE		:= ./src/intent_gate.py
IR_TOOL 		:= ./src/ir_tool.py
SANDBOX 		:= sandbox

DOCS 			:= docs
DEMO_BEFORE 	:= $(DOCS)/demo_before_denial.txt
DEMO_AFTER 		:= $(DOCS)/demo_after_denial.txt
DEMO_DIFF 		:= $(DOCS)/demo_denial_diff.patch

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
	@set -euo pipefail
	mkdir -p "$(DOCS)" tmp "$(SANDBOX)"
	rm -f audit.jsonl
	echo "hello" > "$(SANDBOX)/foo.txt"
	@# BEFORE: do not overwrite baseline unless you intend to
	if [ ! -f "$(DEMO_BEFORE)" ]; then
		$(INTENT_GATE) --dry-run --print-decision -- rm foo.txt 2>&1 | tee "$(DEMO_BEFORE)" >/dev/null || true
	fi
	@# AFTER: always regenerate from current code
	$(INTENT_GATE) --dry-run --print-decision -- rm foo.txt 2>&1 | tee "$(DEMO_AFTER)" >/dev/null || true
	diff -u "$(DEMO_BEFORE)" "$(DEMO_AFTER)" >"$(DEMO_DIFF)" || true
	grep -q "Denial Context Snapshot" "$(DEMO_AFTER)"
	grep -q "did not influence the denial" "$(DEMO_AFTER)"
	! grep -q "DENY: DENY:" "$(DEMO_AFTER)"
	echo "OK: evidence artifacts regenerated and assertions passed"

clean:
	@set -euo pipefail
	if [ -z "$(SANDBOX)" ] || [ "$(SANDBOX)" = "/" ] || [ "$(SANDBOX)" = "." ] || [ "$(SANDBOX)" = ".." ]; then
		echo "FATAL: SANDBOX is unsafe: '$(SANDBOX)'"
		exit 2
	fi
	rm -rf -- "$(SANDBOX)"/*
	find . -name "__pycache__" -type d -prune -exec rm -rf {} +
	find . -name "*.pyc" -delete