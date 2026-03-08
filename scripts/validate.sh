#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 2>/dev/null || true)}"
NPM_BIN="${NPM_BIN:-$(command -v npm 2>/dev/null || true)}"
MODE="${1:-all}"

if [ -z "$PYTHON_BIN" ]; then
	echo "python3 not found" >&2
	exit 1
fi

cd "$REPO_ROOT"

ensure_npm() {
	if [ ! -f package.json ]; then
		return 0
	fi
	if [ -z "$NPM_BIN" ]; then
		echo "npm not found" >&2
		exit 1
	fi
	if [ ! -d node_modules ]; then
		echo "node_modules not found. Install dependencies with: $NPM_BIN install" >&2
		exit 1
	fi
}

run_lint() {
	bash -n scripts/dictation-enter.sh
	shfmt -d scripts/*.sh
	shellcheck scripts/*.sh
	ensure_npm
	if [ -f package.json ]; then
		"$NPM_BIN" run lint --silent
	fi
}

ensure_pytest() {
	if ! "$PYTHON_BIN" -m pytest --version >/dev/null 2>&1; then
		echo "pytest not found. Install dev dependencies with: $PYTHON_BIN -m pip install -r requirements-dev.txt" >&2
		exit 1
	fi
}

run_test() {
	ensure_npm
	if [ -f package.json ]; then
		"$NPM_BIN" run test:node --silent
	fi
	ensure_pytest
	"$PYTHON_BIN" -m pytest -q -m "not smoke"
}

run_smoke() {
	ensure_pytest
	"$PYTHON_BIN" -m pytest -q -m smoke
}

case "$MODE" in
lint)
	run_lint
	;;
test)
	run_test
	;;
smoke)
	run_smoke
	;;
all)
	run_lint
	run_test
	run_smoke
	;;
*)
	echo "usage: scripts/validate.sh [lint|test|smoke|all]" >&2
	exit 1
	;;
esac
