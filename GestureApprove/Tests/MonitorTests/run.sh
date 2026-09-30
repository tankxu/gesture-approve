#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
TEST_BIN="$(mktemp -t ga-monitor-regression)"
trap 'rm -f "$TEST_BIN"' EXIT
swiftc -swift-version 5 Sources/GestureApprove/Monitor*.swift Sources/GestureApprove/LocalMonitor.swift Sources/GestureApprove/HubServer.swift Sources/GestureApprove/Usage*.swift Sources/GestureApprove/Localization.swift Tests/MonitorTests/Regression.swift -o "$TEST_BIN"
cd ..
"$TEST_BIN"
