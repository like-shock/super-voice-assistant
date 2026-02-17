#!/bin/bash
# Build SPM, assemble .app bundle, codesign, and run.
# Usage: ./bundle-app.sh [--run] [--release]
#
# First time setup:
#   ./setup-codesign.sh

set -e
cd "$(dirname "$0")"
source .codesign.env

RUN=false
CONFIG="debug"
for arg in "$@"; do
    case "$arg" in
        --run) RUN=true ;;
        --release) CONFIG="release" ;;
    esac
done

BUILD_FLAGS=""
if [ "$CONFIG" = "release" ]; then
    BUILD_FLAGS="-c release"
fi

APP_NAME="Super Voice Assistant.app"
APP_DIR=".build/$APP_NAME"
CONTENTS="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"
BUILT_BINARY=".build/$CONFIG/SuperVoiceAssistant"

# 1. Build
echo "🔨 Building ($CONFIG)..."
swift build $BUILD_FLAGS

# 2. Assemble .app bundle
echo "📦 Assembling $APP_NAME..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

# Binary
cp "$BUILT_BINARY" "$MACOS_DIR/SuperVoiceAssistant"

# Info.plist
cp Info.plist "$CONTENTS/Info.plist"

# Icon
if [ -f Sources/AppIcon.icns ]; then
    cp Sources/AppIcon.icns "$RESOURCES_DIR/AppIcon.icns"
fi

# .env → bundle Resources (for loadEnvironmentVariables)
if [ -f .env ]; then
    cp .env "$RESOURCES_DIR/.env"
fi

# 3. Codesign
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "🔏 Signing with '$CERT_NAME'..."
    codesign --force --deep --sign "$CERT_NAME" \
        --identifier "$BUNDLE_ID" \
        "$APP_DIR"
else
    echo "⚠️  Certificate '$CERT_NAME' not found, using ad-hoc signing"
    codesign --force --deep --sign - \
        --identifier "$BUNDLE_ID" \
        "$APP_DIR"
fi

echo "✅ Bundle ready: $APP_DIR"

# 4. Run
if [ "$RUN" = true ]; then
    echo "🚀 Launching..."
    open "$APP_DIR"
fi
