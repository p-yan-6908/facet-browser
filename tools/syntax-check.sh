#!/bin/bash
# Checks that need no macOS SDK, so they also run in Linux cloud sessions: shell, Python
# and Swift syntax, and whitespace errors in uncommitted changes. They catch typos before
# CI does; the build and the test suites still need macOS.
set -uo pipefail
cd "$(dirname "$0")/.."

status=0
for f in build.sh tools/*.sh tools/kmem; do
  bash -n "$f" || status=1
done
for f in tools/*.py; do
  python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read(), sys.argv[1])' "$f" || status=1
done
# One file at a time: the tools are single-file scripts with top-level code.
for f in Sources/*.swift tools/*.swift; do
  swiftc -parse -swift-version 5 "$f" || status=1
done
git diff --check HEAD || status=1

if [ "$status" -eq 0 ]; then
  echo "syntax-check: ok"
else
  echo "syntax-check: FAILED" >&2
fi
exit "$status"
