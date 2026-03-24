#!/bin/bash
# Build SPM, assemble .app bundle, codesign, and run.
# Usage: ./bundle-app.sh [--run] [--release]
#
set -e
cd "$(dirname "$0")"

RUN=false
OPEN=false
CONFIG="debug"
for arg in "$@"; do
    case "$arg" in
        --run) RUN=true ;;
        --open) OPEN=true ;;
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

# 1.5. Build MLX Metal shader library (required for Qwen3-ASR GPU inference)
MLX_METALLIB=".build/$CONFIG/mlx.metallib"
MLX_SCRIPT=".build/checkouts/qwen3-asr-swift/scripts/build_mlx_metallib.sh"
if [ -f "$MLX_SCRIPT" ] && [ ! -f "$MLX_METALLIB" ]; then
    echo "🔧 Building MLX Metal shaders..."
    BUILD_DIR="$(pwd)/.build" bash "$MLX_SCRIPT" "$CONFIG" || echo "⚠️  MLX metallib build failed (Qwen3-ASR will not work)"
fi

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

# MLX Metal shader library (required for Qwen3-ASR GPU inference)
# MLX looks for mlx.metallib next to the executable first
if [ -f ".build/$CONFIG/mlx.metallib" ]; then
    echo "📎 Copying MLX Metal library..."
    cp ".build/$CONFIG/mlx.metallib" "$MACOS_DIR/"
fi

# 3. Codesign (ad-hoc — .app bundle uses CFBundleIdentifier for stable identity)
echo "🔏 Signing (ad-hoc)..."
codesign --force --deep --sign - "$APP_DIR"

echo "✅ Bundle ready: $APP_DIR"

# 4. Run
if [ "$RUN" = true ]; then
    echo "🚀 Running (console log)..."
    exec "$MACOS_DIR/SuperVoiceAssistant"
elif [ "$OPEN" = true ]; then
    echo "🚀 Opening app..."
    open "$APP_DIR"
fi
