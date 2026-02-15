#!/bin/bash
# Build, codesign with stable identity, and run.
# Stable codesign ensures CoreML ANE specialization cache is reused across builds.
#
# First time setup:
#   ./setup-codesign.sh

set -e
cd "$(dirname "$0")"
source .codesign.env

echo "🔨 Building..."
swift build

# Check if self-signed cert exists, fall back to ad-hoc
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "🔏 Signing with '$CERT_NAME'..."
    codesign --force --sign "$CERT_NAME" --identifier "$BUNDLE_ID" "$BINARY"
else
    echo "⚠️  Certificate '$CERT_NAME' not found, using ad-hoc signing"
    echo "   Run ./setup-codesign.sh to create it"
    codesign --force --sign - --identifier "$BUNDLE_ID" "$BINARY"
fi

echo "🚀 Running..."
exec "$BINARY"
