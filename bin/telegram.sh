#!/bin/bash
set -euo pipefail

CONF="/etc/sys-backup-v5/telegram.conf"

if [[ ! -f "$CONF" ]]; then
  exit 0
fi

# shellcheck disable=SC1090
source "$CONF"

if [[ -z "${TELEGRAM_CHAT_ID:-}" || -z "${TELEGRAM_BOT_TOKEN:-}" ]]; then
  exit 0
fi

MESSAGE="${1:-}"
if [[ -z "$MESSAGE" ]]; then
  exit 0
fi

curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -d chat_id="${TELEGRAM_CHAT_ID}" \
  -d text="$MESSAGE" \
  -d parse_mode="Markdown" >/dev/null 2>&1 || exit 0
