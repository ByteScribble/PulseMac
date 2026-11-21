#!/usr/bin/env bash
# Builds and tests the platform-independent targets (PulseCore, PulsePersistence,
# PulseMonitoring's portable parts) inside the official Swift Linux image.
# The macOS app target is excluded automatically by Package.swift on Linux.
set -euo pipefail
cd "$(dirname "$0")/.."
IMAGE="${SWIFT_IMAGE:-swift:6.0-noble}"
docker run --rm -v "$PWD":/src -w /src "$IMAGE" bash -c \
  "apt-get update -qq >/dev/null && apt-get install -y -qq libsqlite3-dev >/dev/null && swift build --build-path .build-linux && swift test --build-path .build-linux $*"
