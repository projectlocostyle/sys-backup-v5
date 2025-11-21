#!/bin/bash
set -euo pipefail

LOG="/var/log/sys-backup-v5/restore.log"
REMOTE="backup"
REMOTE_DIR="Server-Backups"
TMP="/tmp/sys-backup-v5"

mkdir -p "$TMP"
mkdir -p "$(dirname "$LOG")"

BASE="/opt/sys-backup-v5"
TELEGRAM_HELPER="${BASE}/bin/telegram.sh"

notify() {
  if [[ -x "$TELEGRAM_HELPER" ]]; then
    "$TELEGRAM_HELPER" "$1" || true
  fi
}

on_error() {
  notify "❌ *Restore fehlgeschlagen* auf \`$(hostname)\` (Zeile $1)."
}
trap 'on_error $LINENO' ERR

echo "--------------------------------------------------------" | tee "$LOG"
echo " SYS-BACKUP-V5 – RESTORE" | tee -a "$LOG"
echo "--------------------------------------------------------" | tee -a "$LOG"

########################################
# 1) BACKUP AUSWÄHLEN
########################################

echo "Lade Backup-Liste aus Nextcloud..." | tee -a "$LOG"

BACKUPS=$(rclone lsf "${REMOTE}:${REMOTE_DIR}" --dirs-only)

if [[ -z "$BACKUPS" ]]; then
    echo "❌ Keine Backups gefunden!" | tee -a "$LOG"
    exit 1
fi

i=1
declare -A MAP

echo "" | tee -a "$LOG"
echo "Verfügbare Backups:" | tee -a "$LOG"
echo "" | tee -a "$LOG"

while read -r BK; do
    [[ -z "$BK" ]] && continue
    BK=${BK%/}
    MAP[$i]="$BK"
    echo "  $i) $BK" | tee -a "$LOG"
    ((i++))
done <<< "$BACKUPS"

echo ""
read -p "Backup wählen: " CHOICE

SELECTED="${MAP[$CHOICE]}"

if [[ -z "$SELECTED" ]]; then
    echo "❌ Ungültige Auswahl!" | tee -a "$LOG"
    exit 1
fi

echo "Ausgewählt: $SELECTED" | tee -a "$LOG"

########################################
# 2) BACKUP DOWNLOADEN
########################################

RESTORE_DIR="${TMP}/${SELECTED}"
rm -rf "$RESTORE_DIR"
mkdir -p "$RESTORE_DIR"

echo "" | tee -a "$LOG"
echo "Lade Backup aus Nextcloud..." | tee -a "$LOG"
rclone copy "${REMOTE}:${REMOTE_DIR}/${SELECTED}" "$RESTORE_DIR" -P | tee -a "$LOG"

echo "✔ Backup vollständig geladen." | tee -a "$LOG"

########################################
# 3) MANIFEST PRÜFEN
########################################

MANIFEST="${RESTORE_DIR}/manifest.yml"

if [[ ! -f "$MANIFEST" ]]; then
    echo "❌ Manifest fehlt!" | tee -a "$LOG"
    exit 1
fi

echo "✔ Manifest gefunden: $MANIFEST" | tee -a "$LOG"

########################################
# 4) DOCKER STOPPEN
########################################

echo "" | tee -a "$LOG"
echo "Stoppe laufende Dienste..." | tee -a "$LOG"
docker compose -f /opt/services/docker-compose.yml down || true

########################################
# 5) VOLUME-MAPPING ERMITTELN
########################################

echo "" | tee -a "$LOG"
echo "Ermittle Volume-Mapping..." | tee -a "$LOG"

BACKUP_VOLUMES=""
if [[ -d "${RESTORE_DIR}/volumes" ]]; then
  BACKUP_VOLUMES=$(ls "${RESTORE_DIR}/volumes" | sed 's/.tar.gz//')
fi

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

echo "Gefundene Zuordnungen:" | tee -a "$LOG"
for B in "${!MATCH[@]}"; do
    echo "  $B  →  ${MATCH[$B]}" | tee -a "$LOG"
done

########################################
# 6) VOLUMES RESTOREN
########################################

echo "" | tee -a "$LOG"
echo "Starte Volume-Restore..." | tee -a "$LOG"

for B in "${!MATCH[@]}"; do
    LV="${MATCH[$B]}"
    ARCHIVE="${RESTORE_DIR}/volumes/${B}.tar.gz"

    if [[ ! -f "$ARCHIVE" ]]; then
        echo "⚠️ Volume fehlt im Backup: $B" | tee -a "$LOG"
        continue
    fi

    echo "  ► Restore: $B  →  $LV" | tee -a "$LOG"

    docker run --rm \
        -v "${LV}:/restore" \
        -v "${ARCHIVE}:/backup.tar.gz" \
        alpine sh -c "rm -rf /restore/* && tar -xzf /backup.tar.gz -C /restore"
done

########################################
# 7) BIND-MOUNTS RESTOREN
########################################

echo "" | tee -a "$LOG"
echo "Starte Bind-Mount-Restore..." | tee -a "$LOG"

if [[ -d "${RESTORE_DIR}/bind_mounts" ]]; then
  for TAR in "${RESTORE_DIR}/bind_mounts/"*.tar.gz; do
      NAME=$(basename "$TAR" .tar.gz)
      RESTORE_PATH=$(echo "$NAME" | sed 's/^_//; s/_/\//g')

      echo "  ► Restore: /${RESTORE_PATH}" | tee -a "$LOG"

      mkdir -p "/${RESTORE_PATH}"
      tar -xzf "$TAR" -C "/${RESTORE_PATH}"
  done
else
  echo "Keine Bind-Mounts im Backup gefunden." | tee -a "$LOG"
fi

########################################
# 8) DOCKER NEU STARTEN
########################################

echo "" | tee -a "$LOG"
echo "Starte Docker-Services..." | tee -a "$LOG"
docker compose -f /opt/services/docker-compose.yml up -d | tee -a "$LOG"

########################################
# 9) CADDY RELOAD
########################################

echo "" | tee -a "$LOG"
echo "Caddy reload..." | tee -a "$LOG"
systemctl reload caddy || true

echo "" | tee -a "$LOG"
echo "--------------------------------------------------------" | tee -a "$LOG"
echo " RESTORE ERFOLGREICH!" | tee -a "$LOG"
echo " Backup: $SELECTED" | tee -a "$LOG"
echo "--------------------------------------------------------" | tee -a "$LOG"

notify "✅ *Restore erfolgreich* auf \`$(hostname)\`  
Backup: \`${SELECTED}\`"
