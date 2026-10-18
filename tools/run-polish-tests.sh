#!/bin/bash
# Synthetic fixtures only. Does not read browser profiles or use provider credentials.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
sources=()
for file in Sources/*.swift; do
  [[ "$file" == "Sources/main.swift" ]] || sources+=("$file")
done
swiftc -swift-version 5 -target "$(uname -m)-apple-macos13.0" -framework AppKit -framework WebKit -framework Security -lsqlite3 \
  -o build/polish-tests "${sources[@]}" tools/polish-tests.swift tools/chrome-session-tests.swift tools/browser-feature-tests.swift tools/browser-parity-tests.swift tools/bookmark-tests.swift tools/session-import-tests.swift tools/password-tests.swift tools/typing-sleep-tests.swift
build/polish-tests "$@"
