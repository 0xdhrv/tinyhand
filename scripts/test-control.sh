#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tinyhand-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -D CONTROL_TEST -module-cache-path "$TEST_DIR/cache" \
  "$ROOT/Sources/TinyHand/ControlTransport.swift" "$ROOT/Sources/TinyHand/ControlBridge.swift" \
  "$ROOT/Tests/ControlBridge/Stubs.swift" "$ROOT/Tests/ControlBridge/main.swift" -o "$TEST_DIR/control-tests"
"$TEST_DIR/control-tests"
