#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Match build-app.sh's debug SwiftPM product without rebuilding. Its generated
# accessor and the packaged app's real shader/localization bundle are prerequisites.
BIN_PATH="$(cd "$PROJECT_ROOT" && swift build --configuration debug --show-bin-path)"
BUILD_ROOT="$(dirname "$(dirname "$BIN_PATH")")"
shopt -s nullglob
# Prefer this build's executable target accessor, never a leftover XCTest
# testable clone. Older SwiftPM layouts place it directly beside the binary.
modern_accessor="$BUILD_ROOT/Intermediates.noindex/Pip.build/Debug/Pip-p.build/DerivedSources/resource_bundle_accessor.swift"
traditional_accessor="$BIN_PATH/Pip.build/DerivedSources/resource_bundle_accessor.swift"
if [[ -f "$modern_accessor" ]]; then
    ACCESSOR="$modern_accessor"
elif [[ -f "$traditional_accessor" ]]; then
    ACCESSOR="$traditional_accessor"
else
    printf 'error: generated Pip product resource accessor missing; first run bash scripts/build-app.sh debug\n' >&2
    exit 1
fi

debug_bundles=("$BIN_PATH"/Pip_*.bundle)
APP_RESOURCES="$PROJECT_ROOT/build/Pip.app/Contents/Resources"
if [[ ! -x "$BIN_PATH/Pip" || ! -x "$PROJECT_ROOT/build/Pip.app/Contents/MacOS/Pip" || ${#debug_bundles[@]} -ne 1 ]]; then
    printf 'error: native smoke requires debug SwiftPM output and a packaged app; first run bash scripts/build-app.sh debug\n' >&2
    exit 1
fi
# build-app.sh copies this exact debug bundle name into the signed app.
RESOURCE_BUNDLE="$APP_RESOURCES/$(basename "${debug_bundles[0]}")"
if [[ ! -f "$RESOURCE_BUNDLE/Contents/Resources/Video.metal" || ! -f "$RESOURCE_BUNDLE/Contents/Resources/en.lproj/Localizable.strings" || ! -f "$RESOURCE_BUNDLE/Contents/Resources/ko.lproj/Localizable.strings" ]]; then
    printf 'error: packaged app lacks Video.metal or localized strings; first run bash scripts/build-app.sh debug\n' >&2
    exit 1
fi

sources=()
for source in "$PROJECT_ROOT"/Sources/Pip/*.swift; do
    [[ "$source" == "$PROJECT_ROOT/Sources/Pip/Main.swift" ]] || sources+=("$source")
done

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
# PipResources resolves the shipped shader and localized strings beside this
# separate CLI executable; never substitute generated or mock resources.
ln -s "$RESOURCE_BUNDLE" "$TEMP_DIR/$(basename "$RESOURCE_BUNDLE")"

swiftc -swift-version 6 -parse-as-library -D DEBUG \
    "${sources[@]}" "$ACCESSOR" "$SCRIPT_DIR/check-native-state.swift" \
    -framework AppKit -framework Carbon -framework CoreGraphics \
    -framework CoreMedia -framework CoreVideo -framework Metal \
    -framework MetalKit -framework QuartzCore -framework ScreenCaptureKit \
    -framework ServiceManagement -o "$TEMP_DIR/check-native-state"

PACKAGE_RESOURCE_BUNDLE_PATH="$RESOURCE_BUNDLE" "$TEMP_DIR/check-native-state"
