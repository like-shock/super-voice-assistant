#!/bin/bash
# Create a self-signed code signing certificate for stable CoreML ANE cache.
# Run once. The certificate is stored in the login keychain.

set -e
cd "$(dirname "$0")"
source .codesign.env

KEYCHAIN="login.keychain-db"

# Check if certificate already exists
if security find-identity -v -p codesigning | grep -q "$CERT_NAME"; then
    echo "✅ Certificate '$CERT_NAME' already exists"
    security find-identity -v -p codesigning | grep "$CERT_NAME"
    exit 0
fi

echo "🔏 Creating self-signed code signing certificate: '$CERT_NAME'"

# Create certificate signing request config
WORKDIR=".codesign"
mkdir -p "$WORKDIR"

cat > "$WORKDIR/cert.cfg" << EOF
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
    -keyout "$WORKDIR/key.pem" \
    -out "$WORKDIR/cert.pem" \
    -days 3650 \
    -config "$WORKDIR/cert.cfg" \
    -extensions extensions \
    2>/dev/null

# Convert to p12
P12_PASS="codesign-tmp"
openssl pkcs12 -export -passout "pass:$P12_PASS" \
    -out "$WORKDIR/cert.p12" \
    -inkey "$WORKDIR/key.pem" \
    -in "$WORKDIR/cert.pem" \
    2>/dev/null

# Import into login keychain
security import "$WORKDIR/cert.p12" \
    -k "$KEYCHAIN" \
    -T /usr/bin/codesign \
    -f pkcs12 \
    -P "$P12_PASS"

# Trust the certificate for code signing
security add-trusted-cert -d -r trustRoot -k "$KEYCHAIN" "$WORKDIR/cert.pem" 2>/dev/null || true

# Cleanup
rm -rf "$WORKDIR"

# Verify
echo ""
echo "=== Installed certificate ==="
security find-identity -v -p codesigning | grep "$CERT_NAME"
echo ""
echo "✅ Done! Now use ./build-and-run.sh"
