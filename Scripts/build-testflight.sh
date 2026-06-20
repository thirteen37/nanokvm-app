#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

APP_NAME="${APP_NAME:-KVMConsole}"
SCHEME="${SCHEME:-KVMConsoleiPad}"
CONFIGURATION="${CONFIGURATION:-Release}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-9URLHJ84PY}"
PROJECT_FILE="${PROJECT_FILE:-KVMConsole.xcodeproj}"
EXPORT_OPTIONS="${EXPORT_OPTIONS:-ExportOptions-AppStore.plist}"
BUILD_ROOT="${BUILD_ROOT:-build/testflight}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$BUILD_ROOT/$APP_NAME.xcarchive}"
EXPORT_PATH="${EXPORT_PATH:-$BUILD_ROOT/export}"

# Build number: dotted YYYYMMDD.HHMMSS (flat 14-digit form exceeds Apple's
# 2^32-1 per-component limit). CI injects this; defaults to "now" for local runs.
BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%Y%m%d.%H%M%S)}"

# App Store Connect API key (cloud signing + upload).
ASC_KEY_ID="${ASC_KEY_ID:-}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-}"
ASC_KEY_PATH="${ASC_KEY_PATH:-}"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: missing required command: $1" >&2
    exit 1
  fi
}

require_env() {
  local name="$1"
  if [[ -z "${!name}" ]]; then
    echo "error: missing required environment variable: $name" >&2
    exit 1
  fi
}

log() {
  printf '\n==> %s\n' "$1"
}

require_command xcodegen
require_command xcodebuild

require_env ASC_KEY_ID
require_env ASC_ISSUER_ID
require_env ASC_KEY_PATH

if [[ ! -f "$ASC_KEY_PATH" ]]; then
  echo "error: App Store Connect API key not found: $ASC_KEY_PATH" >&2
  exit 1
fi

if [[ ! -f "$EXPORT_OPTIONS" ]]; then
  echo "error: export options plist not found: $EXPORT_OPTIONS" >&2
  exit 1
fi

log "Generating Xcode project"
xcodegen generate

rm -rf "$BUILD_ROOT"
mkdir -p "$BUILD_ROOT"

EFFECTIVE_EXPORT_OPTIONS="$BUILD_ROOT/ExportOptions-AppStore.plist"
cp "$EXPORT_OPTIONS" "$EFFECTIVE_EXPORT_OPTIONS"
/usr/libexec/PlistBuddy -c "Set :teamID $APPLE_TEAM_ID" "$EFFECTIVE_EXPORT_OPTIONS"

log "Archiving $SCHEME (build $BUILD_NUMBER)"
xcodebuild archive \
  -project "$PROJECT_FILE" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
  CODE_SIGN_STYLE=Automatic \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER"

log "Exporting and uploading to App Store Connect (TestFlight)"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EFFECTIVE_EXPORT_OPTIONS" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"

printf '\nTestFlight upload complete:\n  build %s of %s\n' "$BUILD_NUMBER" "$SCHEME"
