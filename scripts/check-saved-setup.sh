#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

swiftc -swift-version 6 -parse-as-library \
    "$PROJECT_ROOT/Sources/Pip/AppSettings.swift" \
    "$PROJECT_ROOT/Sources/Pip/SavedSetupStore.swift" \
    "$SCRIPT_DIR/check-saved-setup.swift" \
    -o "$TEMP_DIR/check-saved-setup"
"$TEMP_DIR/check-saved-setup"
