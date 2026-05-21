#!/usr/bin/env bash
set -euo pipefail

NAME="VoiceType Local Code Signing"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
OUT_DIR="${HOME}/Library/Application Support/VoiceType/Signing"
KEY="${OUT_DIR}/VoiceTypeLocal.key"
CRT="${OUT_DIR}/VoiceTypeLocal.crt"
P12="${OUT_DIR}/VoiceTypeLocal.p12"
PASSWORD="VoiceTypeLocal"

mkdir -p "${OUT_DIR}"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"${NAME}\""; then
  echo "Signing identity already exists: ${NAME}"
  exit 0
fi

openssl req \
  -x509 \
  -newkey rsa:2048 \
  -keyout "${KEY}" \
  -out "${CRT}" \
  -days 3650 \
  -nodes \
  -subj "/CN=${NAME}/" \
  -addext "extendedKeyUsage=codeSigning" \
  -addext "keyUsage=digitalSignature" >/dev/null 2>&1

openssl pkcs12 \
  -legacy \
  -export \
  -inkey "${KEY}" \
  -in "${CRT}" \
  -name "${NAME}" \
  -out "${P12}" \
  -passout "pass:${PASSWORD}" >/dev/null 2>&1

security import "${P12}" -k "${KEYCHAIN}" -P "${PASSWORD}" -T /usr/bin/codesign
security add-trusted-cert -r trustRoot -p codeSign -k "${KEYCHAIN}" "${CRT}"

echo "Created signing identity: ${NAME}"
