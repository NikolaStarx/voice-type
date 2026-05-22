#!/usr/bin/env bash
set -euo pipefail

NAME="VoiceType Build Code Signing"
PASSWORD="VoiceTypeBuildKeychain"
P12_PASSWORD="VoiceTypeBuildP12"
OUT_DIR="${HOME}/Library/Application Support/VoiceType/Signing"
KEYCHAIN="${OUT_DIR}/VoiceTypeBuild.keychain-db"
KEY="${OUT_DIR}/VoiceTypeBuild.key"
CRT="${OUT_DIR}/VoiceTypeBuild.crt"
P12="${OUT_DIR}/VoiceTypeBuild.p12"

mkdir -p "${OUT_DIR}"

if [[ ! -f "${KEYCHAIN}" ]]; then
  security create-keychain -p "${PASSWORD}" "${KEYCHAIN}" >/dev/null
fi

security unlock-keychain -p "${PASSWORD}" "${KEYCHAIN}" >/dev/null
security set-keychain-settings -lut 21600 "${KEYCHAIN}" >/dev/null

CURRENT_KEYCHAINS=()
while IFS= read -r line; do
  line="${line#    \"}"
  line="${line%\"}"
  [[ -n "${line}" ]] && CURRENT_KEYCHAINS+=("${line}")
done < <(security list-keychains -d user 2>/dev/null || true)

FOUND_KEYCHAIN=0
for current in "${CURRENT_KEYCHAINS[@]}"; do
  if [[ "${current}" == "${KEYCHAIN}" ]]; then
    FOUND_KEYCHAIN=1
    break
  fi
done

if [[ "${FOUND_KEYCHAIN}" == "0" ]]; then
  security list-keychains -d user -s "${KEYCHAIN}" "${CURRENT_KEYCHAINS[@]}" >/dev/null
fi

if [[ ! -f "${KEY}" || ! -f "${CRT}" || ! -f "${P12}" ]]; then
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
    -passout "pass:${P12_PASSWORD}" >/dev/null 2>&1
fi

if ! security find-identity -v -p codesigning "${KEYCHAIN}" 2>/dev/null | grep -q "\"${NAME}\""; then
  security import "${P12}" \
    -k "${KEYCHAIN}" \
    -P "${P12_PASSWORD}" \
    -T /usr/bin/codesign \
    -T /usr/bin/security >/dev/null
fi

security add-trusted-cert \
  -r trustRoot \
  -p codeSign \
  -k "${KEYCHAIN}" \
  "${CRT}" >/dev/null 2>&1 || true

security set-key-partition-list \
  -S apple-tool:,apple:,codesign: \
  -s \
  -k "${PASSWORD}" \
  "${KEYCHAIN}" >/dev/null

echo "Signing identity ready: ${NAME}"
