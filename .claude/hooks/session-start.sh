#!/bin/bash
# Claude Code cloud sessions run on Linux, where AppKit and WebKit don't exist, so Facet
# can't be built or tested there. This installs the Swift that CI's macos-14 runner uses
# (Xcode 15.4) so tools/syntax-check.sh can catch syntax that CI's compiler would reject,
# and tells the session where the real build and tests run.
set -euo pipefail
[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0

SWIFT_VERSION=5.10.1
SWIFT_SHA256=e1a56752d80b2b759d9ccceae548bd8bdf21674c2b807b0a2738fdb0ba7034ef
SWIFT_DIR="/opt/swift-$SWIFT_VERSION"

if [ ! -x "$SWIFT_DIR/usr/bin/swiftc" ]; then
  url="https://download.swift.org/swift-$SWIFT_VERSION-release/ubuntu2404/swift-$SWIFT_VERSION-RELEASE/swift-$SWIFT_VERSION-RELEASE-ubuntu24.04.tar.gz"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl -sSfL --retry 3 -o "$tmp/swift.tar.gz" "$url"
  echo "$SWIFT_SHA256  $tmp/swift.tar.gz" | sha256sum -c --quiet - >&2
  mkdir -p "$tmp/swift"
  tar -xzf "$tmp/swift.tar.gz" -C "$tmp/swift" --strip-components=1
  rm -rf "$SWIFT_DIR"
  mv "$tmp/swift" "$SWIFT_DIR"
fi

if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo "export PATH=\"$SWIFT_DIR/usr/bin:\$PATH\"" >> "$CLAUDE_ENV_FILE"
fi

# Stdout becomes context for the session.
cat <<EOF
This is a Linux cloud session. Facet is a macOS app (AppKit, WebKit, Security), so
./build.sh and the suites in tools/ (run-polish-tests.sh, run-blocktest.sh,
chrome-compat-smoke.sh) can't run here. Swift $SWIFT_VERSION, the version CI's
macos-14 runner uses, is on PATH: run tools/syntax-check.sh before committing.
It parses every Swift file but can't type-check them without the macOS SDK.
The build and all test suites run in GitHub Actions (.github/workflows/ci.yml)
on every push, so read that run's result after pushing.
EOF
