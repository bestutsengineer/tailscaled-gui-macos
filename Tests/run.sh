#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/tailnet-tests.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT
swiftc -swift-version 5 -D EXIT_CHANGE_TESTS \
    -module-cache-path "$TEST_ROOT/module-cache" \
    Sources/ExitChange.swift Tests/main.swift -o "$TEST_ROOT/exit-change-tests"
TAILNET_TEST_DIRECTORY="$TEST_ROOT/transaction" "$TEST_ROOT/exit-change-tests"
