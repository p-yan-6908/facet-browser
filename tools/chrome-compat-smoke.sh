#!/bin/bash
# Real-browser compatibility smoke test using a disposable Chrome profile only.
# It never opens the user's normal Chrome profile and never reads Chrome Safe Storage.
set -euo pipefail
cd "$(dirname "$0")/.."

CHROME="${CHROME_BIN:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
if [[ ! -x "$CHROME" ]]; then
  if [[ "${CHROME_REQUIRED:-0}" == "1" ]]; then echo "FAIL: Google Chrome is required at $CHROME" >&2; exit 1; fi
  echo "SKIP: Google Chrome is not installed at $CHROME"; exit 0
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/facet-chrome-compat.XXXXXX")"
USER_DATA="$TMP/user-data"
SERVER_PID=""
CHROME_PID=""
cleanup() {
  if [[ -n "$CHROME_PID" ]]; then kill -TERM "$CHROME_PID" 2>/dev/null || true; fi
  pkill -f -- "--user-data-dir=$USER_DATA" 2>/dev/null || true
  [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM
mkdir -p "$USER_DATA" build

PORT="$(python3 - <<'PY'
import socket
s=socket.socket()
s.bind(('127.0.0.1',0))
print(s.getsockname()[1])
s.close()
PY
)"

cat >"$TMP/server.py" <<'PY'
import pathlib, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

marker = pathlib.Path(sys.argv[2])
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        with marker.open('a') as f:
            f.write(self.path + '\n')
        self.send_response(200)
        self.send_header('Content-Type','text/html; charset=utf-8')
        self.send_header('Set-Cookie','facet_fixture=fixture-session-value; Path=/; Max-Age=3600; SameSite=Lax')
        self.end_headers()
        self.wfile.write(b'<!doctype html><title>Facet Chrome Compat</title><h1>Facet Chrome Compat</h1>')
    def log_message(self, fmt, *args):
        pass

HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
PY

python3 "$TMP/server.py" "$PORT" "$TMP/requested" &
SERVER_PID=$!
sleep 0.2

"$CHROME" --headless=new --user-data-dir="$USER_DATA" --no-first-run --no-default-browser-check \
  --disable-background-networking --disable-component-update --disable-sync --disable-default-apps \
  --disable-features=OptimizationHints,MediaRouter \
  "http://127.0.0.1:$PORT/facet-compat" \
  >"$TMP/chrome.out" 2>"$TMP/chrome.err" &
CHROME_PID=$!

for _ in {1..80}; do
  [[ -f "$TMP/requested" ]] && break
  if ! kill -0 "$CHROME_PID" 2>/dev/null; then
    cat "$TMP/chrome.err" >&2
    echo 'FAIL: disposable Chrome exited before requesting the loopback page' >&2
    exit 1
  fi
  sleep 0.1
done
[[ -f "$TMP/requested" ]] || {
  cat "$TMP/chrome.err" >&2
  echo 'FAIL: disposable Chrome never requested the loopback page' >&2
  exit 1
}
grep -q '/facet-compat' "$TMP/requested" || { echo 'FAIL: unexpected loopback request' >&2; exit 1; }

# Give Chrome time to commit History/Cookies, then terminate only this disposable profile.
sleep 1.5
kill -TERM "$CHROME_PID" 2>/dev/null || true
for _ in {1..30}; do
  kill -0 "$CHROME_PID" 2>/dev/null || break
  sleep 0.1
done
pkill -f -- "--user-data-dir=$USER_DATA" 2>/dev/null || true
wait "$CHROME_PID" 2>/dev/null || true
CHROME_PID=""

PROFILE="$USER_DATA/Default"
[[ -f "$PROFILE/History" ]] || { echo 'FAIL: Chrome History missing' >&2; exit 1; }
[[ -f "$PROFILE/Network/Cookies" || -f "$PROFILE/Cookies" ]] || { echo 'FAIL: Chrome Cookies missing' >&2; exit 1; }

sources=()
for f in Sources/*.swift; do
  [[ "$f" == "Sources/main.swift" ]] || sources+=("$f")
done
swiftc -swift-version 5 -target "$(uname -m)-apple-macos13.0" \
  -framework AppKit -framework WebKit -framework Security -lsqlite3 \
  -o build/chrome-compat-verify "${sources[@]}" tools/chrome-compat-verify.swift

"$CHROME" --version
./build/chrome-compat-verify "$PROFILE"
echo "PASS: no normal Chrome profile or Keychain secret was accessed"
