#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIGURATION="${1:-${CONFIGURATION:-release}}"

case "$CONFIGURATION" in
    debug|release)
        ;;
    *)
        printf 'error: configuration must be debug or release (got %s)\n' "$CONFIGURATION" >&2
        exit 2
        ;;
esac

cd "$PROJECT_ROOT"
swift build --configuration "$CONFIGURATION" --product Pip
BIN_PATH="$(swift build --configuration "$CONFIGURATION" --show-bin-path)"
EXECUTABLE="$BIN_PATH/Pip"
if [[ ! -x "$EXECUTABLE" ]]; then
    printf 'error: SwiftPM did not emit executable at %s\n' "$EXECUTABLE" >&2
    exit 1
fi

RESOURCE_BUNDLE=""
for candidate in "$BIN_PATH"/Pip_*.bundle; do
    if [[ -d "$candidate" ]]; then
        RESOURCE_BUNDLE="$candidate"
        break
    fi
done
if [[ -z "$RESOURCE_BUNDLE" ]]; then
    printf 'error: SwiftPM resource bundle was not emitted in %s\n' "$BIN_PATH" >&2
    exit 1
fi

APP_PATH="$PROJECT_ROOT/build/Pip.app"
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$EXECUTABLE" "$APP_PATH/Contents/MacOS/Pip"
cp "$PROJECT_ROOT/Resources/Info.plist" "$APP_PATH/Contents/Info.plist"
# Keep resources in the signed app's resource directory, which Bundle.module searches.
ditto "$RESOURCE_BUNDLE" "$APP_PATH/Contents/Resources/$(basename "$RESOURCE_BUNDLE")"

/usr/bin/codesign --force --deep --sign - "$APP_PATH"
printf 'Built %s\n' "$APP_PATH"
