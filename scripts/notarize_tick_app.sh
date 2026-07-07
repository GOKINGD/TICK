#!/bin/zsh

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
APP_NAME="TICK"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
ARCHIVE_PATH="$ROOT_DIR/dist/$APP_NAME-notarization.zip"

require_env() {
  local name="$1"
  if [[ -z "${(P)name:-}" ]]; then
    echo "Missing required environment variable: $name" >&2
    exit 1
  fi
}

require_env APP_SIGN_IDENTITY
require_env APPLE_ID
require_env APPLE_TEAM_ID
require_env APPLE_APP_SPECIFIC_PASSWORD

echo "==> Building Developer ID signed app"
"$ROOT_DIR/scripts/build_tick_app.sh"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"
spctl --assess --type execute --verbose=4 "$APP_DIR" || true

echo "==> Creating notarization archive"
rm -f "$ARCHIVE_PATH"
ditto -c -k --keepParent "$APP_DIR" "$ARCHIVE_PATH"

echo "==> Submitting notarization request"
xcrun notarytool submit "$ARCHIVE_PATH" \
  --apple-id "$APPLE_ID" \
  --team-id "$APPLE_TEAM_ID" \
  --password "$APPLE_APP_SPECIFIC_PASSWORD" \
  --wait

echo "==> Stapling notarization ticket"
xcrun stapler staple "$APP_DIR"

echo "==> Repacking public download"
rm -f "$ROOT_DIR/docs/downloads/$APP_NAME-macOS.zip"
mkdir -p "$ROOT_DIR/docs/downloads"
ditto -c -k --keepParent "$APP_DIR" "$ROOT_DIR/docs/downloads/$APP_NAME-macOS.zip"

echo "==> Done:"
echo "$ROOT_DIR/docs/downloads/$APP_NAME-macOS.zip"
