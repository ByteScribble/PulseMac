#!/usr/bin/env bash
# Pre-commit / CI gate: format check (if swift-format is available), build, tests.
set -euo pipefail
cd "$(dirname "$0")/.."
if command -v swift-format >/dev/null 2>&1; then
  swift-format lint --strict --recursive Sources Tests
fi
swift build --build-tests
swift test --parallel
