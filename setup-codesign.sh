#!/bin/bash
# Create a self-signed code signing certificate for stable CoreML ANE cache.
# Run once. The certificate is stored in the login keychain.

set -e

CERT_NAME="SuperVoiceAssistant"
KEYCHAIN="login.keychain-db"

# Check if certificate already exists
if security find-identity -v -p codesigning | grep -q "$CERT_NAME"; then
    echo "✅ Certificate '$CERT_NAME' already exists"
    security find-identity -v -p codesigning | grep "$CERT_NAME"
    exit 0
fi

echo "🔏 Creating self-signed code signing certificate: '$CERT_NAME'"

# Create certificate signing request config
TMPDIR="$(cd "$(dirname "$0")" && pwd)/.codesign"
mkdir -p "$TMPDIR"
cat > "$TMPDIR/cert.cfg" << EOF
[ req ]
default_bits       = 2048
distinguished_name = req_dn
prompt             = no
[ req_dn ]
CN = $CERT_NAME
[ extensions ]
keyUsage = digitalSignature
extendedKeyUsage = codeSigning
EOF

# Generate key and self-signed certificate
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMPDIR/key.pem" \
    -out "$TMPDIR/cert.pem" \
    -days 3650 \
    -config "$TMPDIR/cert.cfg" \
    -extensions extensions \
    2>/dev/null

# Convert to p12 (no password)
openssl pkcs12 -export -passout pass: \
    -out "$TMPDIR/cert.p12" \
    -inkey "$TMPDIR/key.pem" \
    -in "$TMPDIR/cert.pem" \
    2>/dev/null

# Import into login keychain
security import "$TMPDIR/cert.p12" \
    -k "$KEYCHAIN" \
    -T /usr/bin/codesign \
    -f pkcs12 \
    -P ""

# Trust the certificate for code signing
# (macOS will still show "unknown developer" for Gatekeeper, but codesign works)
security add-trusted-cert -d -r trustRoot -k "$KEYCHAIN" "$TMPDIR/cert.pem" 2>/dev/null || true

# Cleanup
rm -rf "$TMPDIR"

# Verify
echo ""
echo "=== Installed certificate ==="
security find-identity -v -p codesigning | grep "$CERT_NAME"
echo ""
echo "✅ Done! Use in build-and-run.sh:"
echo "   codesign --force --sign '$CERT_NAME' .build/debug/SuperVoiceAssistant"
