#!/usr/bin/env bash
# Creates a free, self-signed code signing certificate named "Macky Local Signing" in your
# login keychain. Signing every build with the same certificate means macOS remembers the
# permissions you granted (microphone, screen recording, accessibility) across rebuilds.
# No Apple Developer account is needed. Safe to run more than once.
set -euo pipefail

IDENTITY_NAME="Macky Local Signing"
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "$IDENTITY_NAME"; then
  echo "✓ Certificatul \"$IDENTITY_NAME\" există deja."
  exit 0
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
# Temporary password only protects the file while it is imported; the file is deleted afterwards.
TEMPORARY_PASSWORD="macky-$(date +%s)"

cat > "$WORK_DIR/certificate.cnf" <<EOF
[ req ]
distinguished_name = subject
x509_extensions = code_signing_extensions
prompt = no

[ subject ]
CN = $IDENTITY_NAME

[ code_signing_extensions ]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF

echo "→ Generez certificatul (valabil 10 ani)…"
# The system LibreSSL produces a .p12 that `security import` always accepts.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -config "$WORK_DIR/certificate.cnf" \
  -keyout "$WORK_DIR/private-key.pem" -out "$WORK_DIR/certificate.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -name "$IDENTITY_NAME" \
  -inkey "$WORK_DIR/private-key.pem" -in "$WORK_DIR/certificate.pem" \
  -out "$WORK_DIR/identity.p12" -passout "pass:$TEMPORARY_PASSWORD"

echo "→ Îl import în Keychain (login)…"
security import "$WORK_DIR/identity.p12" -k "$LOGIN_KEYCHAIN" -P "$TEMPORARY_PASSWORD" \
  -T /usr/bin/codesign -T /usr/bin/security

echo "→ Îl marchez ca de încredere pentru semnare de cod."
echo "  macOS îți va cere parola de utilizator — e normal."
security add-trusted-cert -r trustRoot -p codeSign -k "$LOGIN_KEYCHAIN" "$WORK_DIR/certificate.pem"

if security find-identity -v -p codesigning | grep -q "$IDENTITY_NAME"; then
  echo "✓ Gata. Certificatul \"$IDENTITY_NAME\" poate semna aplicația."
else
  echo "✗ Certificatul a fost importat, dar macOS nu îl consideră valid încă."
  echo "  Deschide Keychain Access → login → Certificates → \"$IDENTITY_NAME\" → Trust → Code Signing: Always Trust."
  exit 1
fi
