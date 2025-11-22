#!/bin/bash
# Zentraler Telegram-Sender für SYS-BACKUP-V5

CONFIG="/etc/sys-backup-v5.conf"

if [[ -f "$CONFIG" ]]; then
    # shellcheck disable=SC1090
    . "$CONFIG"
fi

if [[ "${TELEGRAM_ENABLED:-no}" != "yes" ]]; then
    exit 0
fi

TEXT="$*"

if [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]] || [[ -z "${TELEGRAM_CHAT_ID:-}" ]]; then
    exit 0
fi

curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${TEXT}" \
    >/dev/null 2>&1 || true
