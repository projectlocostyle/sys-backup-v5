#!/bin/bash
set -euo pipefail

############################################################
# PREMIUM TELEGRAM SEND SCRIPT (sys-backup-v5)
# - Fehlerresistent
# - Markdown-V2 kompatibel
# - Automatische Chunk-Splitting
# - Auto-Retry bei Netzwerkfehler
############################################################

TELEGRAM_TOKEN="8330139979:AAG2TDgNrC1E8twhK_46F9kZD-QTbuvZ8Y4"
TELEGRAM_CHAT="7547528240"

API_URL="https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage"
MAX_LEN=3900   # Telegram max. ~4096 safer limit

escape_md() {
    echo "$1" | sed \
        -e 's/\_/\\_/g' \
        -e 's/\*/\\*/g' \
        -e 's/\[/\\[/g' \
        -e 's/\]/\\]/g' \
        -e 's/(/\\(/g' \
        -e 's/)/\\)/g' \
        -e 's/\~/\\~/g' \
        -e 's/\`/\\`/g' \
        -e 's/>/\\>/g' \
        -e 's/#/\\#/g' \
        -e 's/\+/\\+/g' \
        -e 's/\-/\\-/g' \
        -e 's/\=/\\=/g' \
        -e 's/\!/\\!/g' \
        -e 's/\./\\./g'
}

send_chunk() {
    local CHUNK="$1"
    local RETRIES=4
    local WAIT=2

    for ((i=1; i<=RETRIES; i++)); do
        RESULT=$(curl -s -X POST "$API_URL" \
            -d chat_id="$TELEGRAM_CHAT" \
            -d parse_mode="MarkdownV2" \
            --data-urlencode "text=$CHUNK")

        if echo "$RESULT" | grep -q '"ok":true'; then
            return 0
        else
            echo "⚠️ Telegram Fehler, Wiederhole in ${WAIT}s..."
            sleep $WAIT
            WAIT=$((WAIT * 2))
        fi
    done

    echo "❌ Telegram endgültig fehlgeschlagen:"
    echo "$RESULT"
    return 1
}

telegram() {
    local MSG_RAW="$1"
    local MSG_ESCAPED
    MSG_ESCAPED=$(escape_md "$MSG_RAW")

    # Wenn Nachricht zu groß → splitten
    if (( ${#MSG_ESCAPED} > MAX_LEN )); then
        while (( ${#MSG_ESCAPED} > 0 )); do
            PART="${MSG_ESCAPED:0:MAX_LEN}"
            MSG_ESCAPED="${MSG_ESCAPED:MAX_LEN}"
            send_chunk "$PART"
        done
    else
        send_chunk "$MSG_ESCAPED"
    fi
}

# Direkter Aufruf möglich:
if [[ "${1:-}" != "" ]]; then
    telegram "$1"
fi
