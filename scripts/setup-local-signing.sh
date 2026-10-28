#!/bin/bash
set -euo pipefail
# Own local signing identity only. No trust-store changes or Apple credentials.
identity='Framecast Studio Local Signing'
if security find-identity -p codesigning | /usr/bin/grep -Fq "\"$identity\""; then
  printf 'Local signing identity already exists.\n'
  exit 0
fi
signing_tmp="$(mktemp -d "${TMPDIR:-/tmp}/framecast-signing.XXXXXX")"
trap 'rm -rf "$signing_tmp"' EXIT
chmod 700 "$signing_tmp"
openssl rand -base64 32 > "$signing_tmp/password"
cat > "$signing_tmp/certificate.cnf" <<'CONF'
[req]
distinguished_name=subject
x509_extensions=extensions
prompt=no
[subject]
CN=Framecast Studio Local Signing
[extensions]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
subjectKeyIdentifier=hash
CONF
openssl req -new -newkey rsa:3072 -nodes -x509 -days 3650 -config "$signing_tmp/certificate.cnf" -keyout "$signing_tmp/key.pem" -out "$signing_tmp/cert.pem" 2>/dev/null
openssl pkcs12 -export -inkey "$signing_tmp/key.pem" -in "$signing_tmp/cert.pem" -name "$identity" -passout "file:$signing_tmp/password" -out "$signing_tmp/identity.p12"
keychain_path="$(security default-keychain -d user | tr -d '"' | sed 's/^ *//')"
security import "$signing_tmp/identity.p12" -k "$keychain_path" -P "$(cat "$signing_tmp/password")" -T /usr/bin/codesign
printf 'Installed own local signing identity; private key remains in login Keychain.\n'
