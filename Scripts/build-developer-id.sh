#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

APP_NAME="${APP_NAME:-KVMConsole}"
SCHEME="${SCHEME:-KVMConsole}"
CONFIGURATION="${CONFIGURATION:-Release}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-9URLHJ84PY}"
NOTARY_PROFILE="${NOTARY_PROFILE:-KVMConsole-DeveloperID}"
NOTARY_KEYCHAIN="${NOTARY_KEYCHAIN:-}"
NOTARIZE="${NOTARIZE:-1}"
PROJECT_FILE="${PROJECT_FILE:-KVMConsole.xcodeproj}"
EXPORT_OPTIONS="${EXPORT_OPTIONS:-ExportOptions-DeveloperID.plist}"
BUILD_ROOT="${BUILD_ROOT:-build/developer-id}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$BUILD_ROOT/$APP_NAME.xcarchive}"
EXPORT_PATH="${EXPORT_PATH:-$BUILD_ROOT/export}"
NOTARY_ZIP_PATH="${NOTARY_ZIP_PATH:-$BUILD_ROOT/$APP_NAME-notarization.zip}"
FINAL_ZIP_PATH="${FINAL_ZIP_PATH:-$BUILD_ROOT/$APP_NAME-DeveloperID.zip}"

# Optional build number, shared with the iOS release so both platforms carry the
# same CFBundleVersion. When unset (e.g. local builds), the project default wins.
BUILD_NUMBER="${BUILD_NUMBER:-}"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: missing required command: $1" >&2
    exit 1
  fi
}

require_xcrun_tool() {
  if ! xcrun -f "$1" >/dev/null 2>&1; then
    echo "error: missing required xcrun tool: $1" >&2
    exit 1
  fi
}

log() {
  printf '\n==> %s\n' "$1"
}

case "$NOTARIZE" in
  1|true|TRUE|yes|YES)
    NOTARIZE=1
    ;;
  0|false|FALSE|no|NO)
    NOTARIZE=0
    ;;
  *)
    echo "error: NOTARIZE must be 1 or 0" >&2
    exit 1
    ;;
esac

require_command xcodegen
require_command xcodebuild
require_command codesign
require_command security
if [[ "$NOTARIZE" == "1" ]]; then
  require_command spctl
  require_xcrun_tool notarytool
  require_xcrun_tool stapler
fi

if ! security find-identity -v -p codesigning | grep -F "Developer ID Application" | grep -F "($APPLE_TEAM_ID)" >/dev/null; then
  echo "error: no Developer ID Application signing identity found for team $APPLE_TEAM_ID" >&2
  echo "Install the Developer ID Application certificate, then retry." >&2
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

EFFECTIVE_EXPORT_OPTIONS="$BUILD_ROOT/ExportOptions-DeveloperID.plist"
cp "$EXPORT_OPTIONS" "$EFFECTIVE_EXPORT_OPTIONS"
/usr/libexec/PlistBuddy -c "Set :teamID $APPLE_TEAM_ID" "$EFFECTIVE_EXPORT_OPTIONS"

log "Archiving $APP_NAME"
ARCHIVE_ARGS=(
  -project "$PROJECT_FILE"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -archivePath "$ARCHIVE_PATH"
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID"
  CODE_SIGN_STYLE=Manual
  CODE_SIGN_IDENTITY="Developer ID Application"
  SKIP_INSTALL=NO
)
if [[ -n "$BUILD_NUMBER" ]]; then
  ARCHIVE_ARGS+=(CURRENT_PROJECT_VERSION="$BUILD_NUMBER")
fi
xcodebuild archive "${ARCHIVE_ARGS[@]}"

log "Exporting Developer ID app"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EFFECTIVE_EXPORT_OPTIONS"

APP_PATH="$EXPORT_PATH/$APP_NAME.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "error: exported app not found at $APP_PATH" >&2
  exit 1
fi

log "Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

if [[ "$NOTARIZE" == "1" ]]; then
  log "Creating notarization zip"
  ditto -c -k --keepParent "$APP_PATH" "$NOTARY_ZIP_PATH"

  log "Submitting for notarization"
  NOTARYTOOL_ARGS=(
    --keychain-profile "$NOTARY_PROFILE"
    --team-id "$APPLE_TEAM_ID"
  )
  if [[ -n "$NOTARY_KEYCHAIN" ]]; then
    NOTARYTOOL_ARGS+=(--keychain "$NOTARY_KEYCHAIN")
  fi
  xcrun notarytool submit "$NOTARY_ZIP_PATH" \
    "${NOTARYTOOL_ARGS[@]}" \
    --wait

  log "Stapling ticket"
  xcrun stapler staple "$APP_PATH"
  xcrun stapler validate "$APP_PATH"
  spctl -a -vvv -t exec "$APP_PATH"
else
  log "Skipping notarization"
fi

log "Creating final distributable"
rm -f "$FINAL_ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$FINAL_ZIP_PATH"

if [[ "$NOTARIZE" == "1" ]]; then
  printf '\nDeveloper ID notarized build complete:\n  %s\n' "$FINAL_ZIP_PATH"
else
  printf '\nDeveloper ID signed build complete, not notarized:\n  %s\n' "$FINAL_ZIP_PATH"
fi
