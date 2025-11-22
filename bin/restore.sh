#!/bin/bash
set -euo pipefail

LOG="/var/log/sys-backup-v5/restore.log"
CONFIG="/etc/sys-backup-v5.conf"
TMP="/tmp/sys-backup-v5"

mkdir -p "$TMP"
mkdir -p "$(dirname "$LOG")"

if [[ -f "$CONFIG" ]]; then
  # shellcheck disable=SC1090
  . "$CONFIG"
fi

REMOTE="${REMOTE_NAME:-backup}"
REMOTE_DIR="${REMOTE_DIR:-Server-Backups}"

telegram() {
    if [[ -x /opt/sys-backup-v5/bin/telegram.sh ]]; then
        /opt/sys-backup-v5/bin/telegram.sh "$*"
    fi
}

trap 'telegram "❌ Restore fehlgeschlagen auf $(hostname) um $(date)"' ERR

echo "--------------------------------------------------------"
echo " SYS-BACKUP-V5 – RESTORE"
echo "--------------------------------------------------------"

########################################
# 1) BACKUP AUSWÄHLEN
########################################

echo "Lade Backup-Liste aus Nextcloud..."

BACKUPS=$(rclone lsf "${REMOTE}:${REMOTE_DIR}" --dirs-only)

if [[ -z "$BACKUPS" ]]; then
    echo "❌ Keine Backups gefunden!"
    exit 1
fi

i=1
declare -A MAP

echo ""
echo "Verfügbare Backups:"
echo ""

while read -r BK; do
    [[ -z "$BK" ]] && continue
    BK=${BK%/}
    MAP[$i]="$BK"
    echo "  $i) $BK"
    ((i++))
done <<< "$BACKUPS"

echo ""
read -p "Backup wählen: " CHOICE

SELECTED="${MAP[$CHOICE]}"

if [[ -z "$SELECTED" ]]; then
    echo "❌ Ungültige Auswahl!"
    exit 1
fi

echo "Ausgewählt: $SELECTED"

########################################
# 2) BACKUP DOWNLOADEN
########################################

RESTORE_DIR="${TMP}/${SELECTED}"
rm -rf "$RESTORE_DIR"
mkdir -p "$RESTORE_DIR"

echo ""
echo "Lade Backup aus Nextcloud..."
rclone copy "${REMOTE}:${REMOTE_DIR}/${SELECTED}" "$RESTORE_DIR" -P

echo "✔ Backup vollständig geladen."

########################################
# 3) MANIFEST PRÜFEN
########################################

MANIFEST="${RESTORE_DIR}/manifest.yml"

if [[ ! -f "$MANIFEST" ]]; then
    echo "❌ Manifest fehlt!"
    exit 1
fi

echo "✔ Manifest gefunden."

########################################
# 4) DOCKER STOPPEN
########################################

echo ""
echo "Stoppe laufende Dienste..."
docker compose -f /opt/services/docker-compose.yml down || true

########################################
# 5) VOLUMES RESTOREN (1:1 nach Namen)
########################################

echo ""
echo "Starte Volume-Restore..."

if [[ -d "${RESTORE_DIR}/volumes" ]]; then
    for ARCHIVE in "${RESTORE_DIR}/volumes/"*.tar.gz; do
        [ -e "$ARCHIVE" ] || continue

        BNAME=$(basename "$ARCHIVE" .tar.gz)
        LV="$BNAME"

        echo "  ► Restore Volume: $BNAME  →  $LV"

        docker volume create "$LV" >/dev/null 2>&1 || true

        docker run --rm \
            -v "${LV}:/restore" \
            -v "${ARCHIVE}:/backup.tar.gz" \
            alpine sh -c "rm -rf /restore/* && tar -xzf /backup.tar.gz -C /restore"
    done
else
    echo "Keine Volume-Daten im Backup gefunden."
fi

########################################
# 6) BIND MOUNTS RESTOREN
########################################

echo ""
echo "Starte Bind-Mount-Restore..."

if [[ -d "${RESTORE_DIR}/bind_mounts" ]]; then
    for TAR in "${RESTORE_DIR}/bind_mounts/"*.tar.gz; do
        [ -e "$TAR" ] || continue
        NAME=$(basename "$TAR" .tar.gz)
        RESTORE_PATH=$(echo "$NAME" | sed 's/^_//; s/_/\//g')

        echo "  ► Restore: /$RESTORE_PATH"

        mkdir -p "/$RESTORE_PATH"
        tar -xzf "$TAR" -C "/$RESTORE_PATH"
    done
else
    echo "Keine Bind-Mount-Daten im Backup gefunden."
fi

########################################
# 7) DOCKER NEU STARTEN
########################################

echo ""
echo "Starte Docker-Services..."
docker compose -f /opt/services/docker-compose.yml up -d

########################################
# 8) CADDY RELOAD
########################################

echo ""
echo "Caddy reload..."
systemctl reload caddy || true

echo "--------------------------------------------------------"
echo " RESTORE ERFOLGREICH!"
echo " Backup: $SELECTED"
echo "--------------------------------------------------------"

# Dauer berechnen (bash-Variable SECONDS zählt seit Skriptstart)
DURATION_SECONDS=${SECONDS:-0}
printf -v DURATION "%02d:%02d:%02d" \
    $((DURATION_SECONDS / 3600)) \
    $(((DURATION_SECONDS % 3600) / 60)) \
    $((DURATION_SECONDS % 60))

TIMESTAMP="$(date '+%d.%m.%Y %H:%M:%S')"
SERVER="$(hostname)"

telegram "$(cat <<EOF
✅ Restore erfolgreich

🗂 Backup: ${SELECTED}
🖥 Server: ${SERVER}
🔧 Modus: Komplettes Restore
⏱ Dauer: ${DURATION}
📅 Zeitpunkt: ${TIMESTAMP}

🔁 Wiederhergestellt:
 - n8n Daten
 - Datenbank
 - Portainer
 - Caddy

🧩 Details:
 - n8n Daten (Volume: n8n_n8n_data)
 - Datenbank (Volume: n8n_postgres_data)
 - Portainer (Volume: portainer_data)
 - Caddy (Caddyfile, config/, data/)
EOF
)"
