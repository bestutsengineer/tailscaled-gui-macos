#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/tailscaled-gui-tests.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT
swiftc -swift-version 5 -D EXIT_CHANGE_TESTS \
    -module-cache-path "$TEST_ROOT/module-cache" \
    Sources/ExitDiagnostics.swift Sources/ExitChange.swift Tests/main.swift -o "$TEST_ROOT/exit-change-tests"
TAILSCALED_GUI_TEST_DIRECTORY="$TEST_ROOT/transaction" "$TEST_ROOT/exit-change-tests"
swiftc -swift-version 5 -D CONNECTION_TESTS \
    -module-cache-path "$TEST_ROOT/module-cache" \
    Sources/ConnectionBehavior.swift Sources/Tailscale.swift Tests/Connection/main.swift -o "$TEST_ROOT/connection-tests"
TAILSCALED_GUI_TEST_DIRECTORY="$TEST_ROOT/history" "$TEST_ROOT/connection-tests"
swiftc -swift-version 5 -module-cache-path "$TEST_ROOT/module-cache" \
    -framework AppKit -framework SwiftUI \
    Sources/RemoteAccessGuide.swift Tests/Guide/main.swift -o "$TEST_ROOT/guide-tests"
"$TEST_ROOT/guide-tests"
swiftc -swift-version 5 -module-cache-path "$TEST_ROOT/module-cache" \
    Sources/LoginItem.swift Tests/LoginItem/main.swift -o "$TEST_ROOT/login-item-tests"
TAILSCALED_GUI_TEST_DIRECTORY="$TEST_ROOT/login-item" "$TEST_ROOT/login-item-tests"
