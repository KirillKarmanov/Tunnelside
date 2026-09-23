#!/bin/bash
# Creates a self-signed code signing certificate "Tunnelside Local Signing" in the login keychain.
# Needed once per machine: it signs both the app and the background service, and the service
# accepts commands only from an app with the same signature.
# No paid Apple Developer ID is needed. The private key is created in a temporary folder and
# deleted after import — it stays only in the keychain.
set -euo pipefail

NAME="${SIGN_IDENTITY:-Tunnelside Local Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "✓ Certificate \"${NAME}\" is already in the keychain"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
umask 077

cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.cnf" 2>/dev/null
PASS="$(openssl rand -hex 16)"
# 3DES/SHA1 — the PKCS#12 format that `security import` is guaranteed to read
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -out "$WORK/identity.p12" \
    -passout "pass:$PASS" -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign

echo "✓ Certificate \"${NAME}\" created, valid for 10 years"
openssl x509 -in "$WORK/cert.pem" -noout -fingerprint -sha1
echo "  On the first signing macOS may ask for access to the key — click \"Always Allow\"."
