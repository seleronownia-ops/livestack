#!/usr/bin/env bash
# Runs every check for Live Stack: core package tests, iOS unit + integration tests on a simulator, a Release build.
# Usage: scripts/verify.sh [simulator name]   (default: iPhone 16)
set -euo pipefail
cd "$(dirname "$0")/.."
SIM="${1:-iPhone 16}"
DEST="platform=iOS Simulator,name=${SIM}"

echo "== 1/4 Core package: unit tests (pure Swift, no Apple frameworks)"
swift test --package-path Packages/LiveStackCore 2>&1 | tail -5

echo "== 2/4 App: build for the simulator"
xcodebuild build -project LiveStack.xcodeproj -scheme LiveStack -destination "${DEST}" -quiet CODE_SIGNING_ALLOWED=NO

echo "== 3/4 App: unit + integration tests on the simulator (synthetic videos, real AVFoundation pipeline)"
xcodebuild test -project LiveStack.xcodeproj -scheme LiveStack -destination "${DEST}" -only-testing:LiveStackTests CODE_SIGNING_ALLOWED=NO 2>&1 | tee /tmp/livestack-tests.log | grep -E "Test (Case|Suite)|error:|\*\* TEST" | tail -40

echo "== 4/4 App: UI smoke test"
xcodebuild test -project LiveStack.xcodeproj -scheme LiveStack -destination "${DEST}" -only-testing:LiveStackUITests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test (Case|Suite)|error:|\*\* TEST" | tail -10

echo "All checks finished. Full simulator log: /tmp/livestack-tests.log"
