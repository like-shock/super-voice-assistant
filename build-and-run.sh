#!/bin/bash
# Build, codesign with stable identifier, and run
# This ensures CoreML ANE specialization cache is reused across runs

set -e

cd "$(dirname "$0")"

echo "🔨 Building..."
swift build

BINARY=".build/debug/SuperVoiceAssistant"

echo "🔏 Signing with stable identifier..."
codesign --force --sign - --identifier "com.likeshock.SuperVoiceAssistant" "$BINARY"

echo "🚀 Running..."
exec "$BINARY"
