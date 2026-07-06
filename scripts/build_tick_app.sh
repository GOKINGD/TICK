#!/bin/zsh

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
BUILD_DIR="$ROOT_DIR/.build-app"
APP_NAME="TICK"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
INFO_PLIST_SOURCE="$ROOT_DIR/AppBundle/TICKInfo.plist"
EXECUTABLE_SOURCE="$ROOT_DIR/.build/release/$APP_NAME"
OBSERVER_NAME="TICKObserver"
OBSERVER_SOURCE="$ROOT_DIR/.build/release/$OBSERVER_NAME"
SIGN_IDENTITY="${APP_SIGN_IDENTITY:--}"
SIGN_OPTIONS=()

if [[ "$SIGN_IDENTITY" != "-" ]]; then
  SIGN_OPTIONS=(--options runtime)
fi

echo "==> Building release executable"
cd "$ROOT_DIR"
HOME="$BUILD_DIR/home" \
CLANG_MODULE_CACHE_PATH="$BUILD_DIR/ModuleCache" \
SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_DIR/ModuleCache" \
swift build -c release --product "$APP_NAME"
HOME="$BUILD_DIR/home" \
CLANG_MODULE_CACHE_PATH="$BUILD_DIR/ModuleCache" \
SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_DIR/ModuleCache" \
swift build -c release --product "$OBSERVER_NAME"

echo "==> Creating app bundle"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$INFO_PLIST_SOURCE" "$CONTENTS_DIR/Info.plist"
cp "$EXECUTABLE_SOURCE" "$MACOS_DIR/$APP_NAME"
cp "$OBSERVER_SOURCE" "$MACOS_DIR/$OBSERVER_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$OBSERVER_NAME"

echo "==> Signing app bundle"
codesign --force --deep "${SIGN_OPTIONS[@]}" --sign "$SIGN_IDENTITY" "$APP_DIR"

echo "==> Built app:"
echo "$APP_DIR"
