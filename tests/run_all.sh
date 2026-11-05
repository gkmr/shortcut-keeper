#!/bin/bash
# Everything that runs without a Mac: python3 (stdlib only) and bash. No network, no real app configs touched.
#   tests/run_all.sh        exit 0 when every suite passes
# On-screen macOS tests (they move and pin real windows) live in tests/macos/ and are never run from here.
set -u
R="$(cd "$(dirname "$0")/.." && pwd)"; cd "$R" || exit 2
export PYTHONDONTWRITEBYTECODE=1
export SHORTCUT_KEEPER_HOME="$(mktemp -d)"   # director.sh writes its detect cache here, not in the repo
fail=0
step() { echo "== $1"; shift; if "$@"; then echo "   ok"; else echo "   FAILED"; fail=1; fi; }
step "keeper_core diff logic and keeper.py end to end (fixtures)" python3 -m unittest discover -s tests -p 'test_*.py'
step "meeting layouts against the layout rules" bash -c 'python3 tests/layout-test.py examples/fixtures/layouts.json | tail -1 | grep -qx "ALL PASS"'
step "Meeting Director call detection (fake window lists)" bash -c 'bash tests/director-test.sh | tail -1 | grep -qx "ALL PASS"'
step "Meeting Director background recheck (fake windows, 1 s loop)" bash -c 'bash tests/recheck-test.sh | tail -1 | grep -qx "ALL PASS"'
[ "$fail" = 0 ] && echo "ALL SUITES PASS" || { echo "SOME SUITES FAILED"; exit 1; }
