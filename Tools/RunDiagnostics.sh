#!/usr/bin/env bash
set -euo pipefail

APP="${VOICETYPE_APP:-/Applications/VoiceType.app}"
LOG="${HOME}/Library/Application Support/VoiceType/voice-type.log"
TEXT="VoiceType diagnostic paste 中文 English 123"

echo "[diagnostics] quit existing VoiceType"
osascript -e 'tell application "VoiceType" to quit' >/dev/null 2>&1 || true
pkill -x VoiceType >/dev/null 2>&1 || true

echo "[diagnostics] clear log: ${LOG}"
rm -f "${LOG}"

echo "[diagnostics] launch: ${APP}"
open "${APP}"
sleep 2

echo "[diagnostics] request diagnostic paste through DistributedNotificationCenter"
swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.codex.voicetype.diagnosticPaste"), object: nil, userInfo: ["text": "'"${TEXT}"'"], deliverImmediately: true)'
sleep 2

echo "[diagnostics] clipboard bytes after restore:"
pbpaste | wc -c | tr -d ' '
printf " bytes\n"

echo "[diagnostics] log:"
tail -240 "${LOG}" 2>/dev/null || true
