#!/bin/bash
set -euo pipefail

LOG="/var/log/sys-backup-v5/restore.log"
REMOTE="backup"
REMOTE_DIR="Server-Backups"
TMP="/tmp/sys-backup-v5"

mkdir -p "$TMP"
mkdir -p "$(dirname "$LOG")"

echo "--------------------------------------------------------"
echo " SYS-BACKUP-V5 – RESTORE"
echo "--------------------------------------------------------"

RESTORE_START=$(date +%s)

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
# 5) VOLUME-MAPPING
########################################

echo ""
echo "Ermittle Volume-Mapping..."

BACKUP_VOLUMES=$(ls "${RESTORE_DIR}/volumes" | sed 's/.tar.gz//')
DOCKER_VOLUMES=$(docker volume ls -q)

declare -A MATCH

for B in $BACKUP_VOLUMES; do
    KEYWORD=$(echo "$B" | sed 's/services_//')
    for LV in $DOCKER_VOLUMES; do
        if [[ "$LV" == *"$KEYWORD"* ]]; then
            MATCH[$B]="$LV"
        fi
    done
done

echo "Gefundene Zuordnungen:"
for B in "${!MATCH[@]}"; do
    echo "  $B  →  ${MATCH[$B]}"
done

########################################
# 6) VOLUMES RESTOREN
########################################

echo ""
echo "Starte Volume-Restore..."

for B in "${!MATCH[@]}"; do

    LV="${MATCH[$B]}"
    ARCHIVE="${RESTORE_DIR}/volumes/${B}.tar.gz"

    if [[ ! -f "$ARCHIVE" ]]; then
        echo "⚠️ Volume fehlt im Backup: $B"
        continue
    fi

    echo "  ► Restore: $B  →  $LV"

    docker run --rm \
        -v "${LV}:/restore" \
        -v "${ARCHIVE}:/backup.tar.gz" \
        alpine sh -c "rm -rf /restore/* && tar -xzf /backup.tar.gz -C /restore"

done

########################################
# 7) BIND-MOUNTS RESTOREN
########################################

echo ""
echo "Starte Bind-Mount-Restore..."

for TAR in "${RESTORE_DIR}/bind_mounts/"*.tar.gz; do
    NAME=$(basename "$TAR" .tar.gz)
    RESTORE_PATH=$(echo "$NAME" | sed 's/^_//; s/_/\//g')

    echo "  ► Restore: /$RESTORE_PATH"

    mkdir -p "/$RESTORE_PATH"
    tar -xzf "$TAR" -C "/$RESTORE_PATH"
done

########################################
# 8) DOCKER STARTEN
########################################

echo ""
echo "Starte Docker-Services..."
docker compose -f /opt/services/docker-compose.yml up -d

########################################
# 9) CADDY RELOAD
########################################

echo ""
echo "Caddy reload..."
systemctl reload caddy || true

########################################
# 10) TELEGRAM REPORT
########################################

RESTORE_END=$(date +%s)
DURATION=$((RESTORE_END - RESTORE_START))

HUMAN_DURATION=$(printf "%02d:%02d:%02d" $((DURATION/3600)) $((DURATION%3600/60)) $((DURATION%60)))
NOW_HUMAN=$(date +"%d.%m.%Y %H:%M:%S")

RESTORED_LIST=$(ls "$RESTORE_DIR/volumes" | sed 's/.tar.gz//' | sed 's/^/ - /')
BIND_LIST=$(ls "$RESTORE_DIR/bind_mounts" | sed 's/.tar.gz//' | sed 's/_/\//g' | sed 's/^/ - \//')

REPORT=$(cat <<EOF
✅ *Restore erfolgreich*

🗂 *Backup:* ${SELECTED}
🖥 *Server:* $(hostname)
🔧 *Modus:* Komplettes Restore
⏱ *Dauer:* ${HUMAN_DURATION}
📅 *Zeitpunkt:* ${NOW_HUMAN}

🔁 *Wiederhergestellt (Volumes):*
${RESTORED_LIST}

🧩 *Bind Mounts:*
${BIND_LIST}
EOF
)

telegram "$REPORT"

echo ""
echo "--------------------------------------------------------"
echo " RESTORE ERFOLGREICH!"
echo " Backup: $SELECTED"
echo "--------------------------------------------------------"
