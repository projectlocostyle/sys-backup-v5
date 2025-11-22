#!/bin/bash
# Telegram Integration V2 – ultra-stabil

TELEGRAM_BOT_TOKEN="8555709765:AAHgPyEfI4yB0U0dVPHfxs6DSqlDkXS9Hfc"
TELEGRAM_CHAT_ID="7547528240"

API_URL="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"

log_msg() {
    echo "[telegram] $1"
}

send_telegram_message() {
    local MESSAGE="$1"
    local RETRIES=5
    local DELAY=2

    # Entfernt problematische Zeichen
    SAFE_MSG=$(echo "$MESSAGE" | sed 's/"/\\"/g')

    for ((i=1; i<=RETRIES; i++)); do
        log_msg "Versuch $i Nachricht zu senden…"

        RESPONSE=$(curl -s -X POST "$API_URL" \
            -d chat_id="$TELEGRAM_CHAT_ID" \
            -d parse_mode="MarkdownV2" \
            --data-urlencode "text=$SAFE_MSG")

        if echo "$RESPONSE" | grep -q '"ok":true'; then
            log_msg "Telegram erfolgreich."
            return 0
        fi

        log_msg "⚠ Fehler: $RESPONSE"
        sleep $DELAY
        DELAY=$((DELAY * 2))
    done

    log_msg "❌ Telegram endgültig fehlgeschlagen!"
    return 1
}

# Testfunktion für Installations-Wizard
telegram_test() {
    send_telegram_message "🟢 *Telegram Test erfolgreich*\nNachrichten können gesendet werden."
}
