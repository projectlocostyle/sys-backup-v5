#!/bin/bash
# Telegram Integration V2 – ultra-stabil

TELEGRAM_BOT_TOKEN="DEIN_BOT_TOKEN_HIER"
TELEGRAM_CHAT_ID="DEINE_CHAT_ID_HIER"

API_URL="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"

log_msg() {
    echo "[telegram] $1"
}

send_telegram_message() {
    local MESSAGE="$1"
    local RETRIES=5
    local DELAY=2

    SAFE_MSG=$(echo "$MESSAGE" | sed 's/"/\\"/g')

    for ((i=1; i<=RETRIES; i++)); do
        RESPONSE=$(curl -s -X POST "$API_URL" \
            -d chat_id="$TELEGRAM_CHAT_ID" \
            -d parse_mode="MarkdownV2" \
            --data-urlencode "text=$SAFE_MSG")

        if echo "$RESPONSE" | grep -q '"ok":true'; then
            log_msg "Telegram OK"
            return 0
        fi

        log_msg "⚠ Fehler ($i): $RESPONSE"
        sleep $DELAY
        DELAY=$((DELAY * 2))
    done

    log_msg "❌ Telegram endgültig fehlgeschlagen"
    return 1
}

telegram_test() {
    send_telegram_message "🟢 *Telegram OK* – Testnachricht empfangen."
}
