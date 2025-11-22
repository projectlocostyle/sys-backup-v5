#!/bin/bash
set -euo pipefail

############################################################
# SYS-BACKUP-V5 – PREMIUM BACKUP SCRIPT
# Mit Telegram-Report, Dauer, Manifest & Hashes
############################################################

BACKUP_START=$(date +%s)
TIMESTAMP="$(date +%Y-%m-%d_%H-%M-%S)"
BACKUP_NAME="backup_${TIMESTAMP}"

BASE="/opt/sys-backup-v5"
LOG_DIR="/var/log/sys-backup-v5"
TMP="/tmp/sys-backup-v5"
BACKUP_TMP="${TMP}/${BACKUP_NAME}"

REMOTE_NAME="backup"
REMOTE_DIR="Server-Backups/${BACKUP_NAME}"

mkdir -p "$LOG_DIR"
mkdir -p "$BACKUP_TMP/volumes"
mkdir -p "$BACKUP_TMP/bind_mounts"

LOG="${LOG_DIR}/backup.log"

echo "--------------------------------------------------------" | tee "$LOG"
echo "SYS-BACKUP-V5 BACKUP gestartet: ${TIMESTAMP}" | tee -a "$LOG"
echo "--------------------------------------------------------" | tee -a "$LOG"
echo "" | tee -a "$LOG"

############################################################
# 1) MODEL-MANIFEST
############################################################

echo "Erfasse Modell-Listen..." | tee -a "$LOG"

echo "models:" > "${BACKUP_TMP}/model_manifest.yml"
echo "  ollama: Docker-Modus (keine Modelldaten)" >> "${BACKUP_TMP}/model_manifest.yml"

if [[ -d /opt/services/openwebui/models ]]; then
    echo "  openwebui:" >> "${BACKUP_TMP}/model_manifest.yml"
    ls /opt/services/openwebui/models | awk '{print "    - " $1}' >> "${BACKUP_TMP}/model_manifest.yml"
else
    echo "  openwebui: kein Modellordner" >> "${BACKUP_TMP}/model_manifest.yml"
fi

echo "ℹ️ Modelle erfasst." | tee -a "$LOG"

############################################################
# 2) DOCKER VOLUMES BACKUP
############################################################

echo "Starte Volume-Backup..." | tee -a "$LOG"

VOLUMES=$(docker volume ls --format '{{.Name}}' | grep '^services_')

for VOL in $VOLUMES; do
    echo "  Volume: $VOL" | tee -a "$LOG"

    ARCHIVE="${BACKUP_TMP}/volumes/${VOL}.tar.gz"

    docker run --rm \
        -v "${VOL}:/data:ro" \
        -v "${BACKUP_TMP}/volumes:/out" \
        alpine sh -c "cd /data && tar -czf /out/${VOL}.tar.gz ."

    echo "    ✔ Gesichert: $ARCHIVE" | tee -a "$LOG"
done

############################################################
# 3) BIND-MOUNTS BACKUP
############################################################

echo "Starte Bind-Mount Backup..." | tee -a "$LOG"

MOUNTS=(
    "/etc/caddy"
    "/opt/services"
    "/opt/sys-backup-v5"
    "/root/.config/rclone"
    "/var/lib/caddy"
)

for SRC in "${MOUNTS[@]}"; do
    SAFE=$(echo "$SRC" | sed 's/\//_/g')
    ARCHIVE="${BACKUP_TMP}/bind_mounts/${SAFE}.tar.gz"

    echo "  Bind-Mount: $SRC" | tee -a "$LOG"

    tar -czf "$ARCHIVE" -C "$SRC" .

    echo "    ✔ Gesichert: $ARCHIVE" | tee -a "$LOG"
done

############################################################
# 4) HASHES
############################################################

HASHFILE="${BACKUP_TMP}/hashes.sha256"
find "$BACKUP_TMP" -type f -exec sha256sum {} \; > "$HASHFILE"
echo "✔ Hash-Datei erstellt: $HASHFILE" | tee -a "$LOG"

############################################################
# 5) MANIFEST
############################################################

MANIFEST="${BACKUP_TMP}/manifest.yml"

cat <<EOF > "$MANIFEST"
backup_name: "$BACKUP_NAME"
timestamp: "$TIMESTAMP"
host: "$(hostname)"
ip: "$(hostname -I | awk '{print $1}')"

volumes:
$(echo "$VOLUMES" | sed 's/^/  - /')

bind_mounts:
$(printf "%s\n" "${MOUNTS[@]}" | sed 's/^/  - /')
EOF

echo "✔ Manifest erstellt." | tee -a "$LOG"

############################################################
# 6) UPLOAD ZU NEXTCLOUD
############################################################

echo "Starte Upload zu Nextcloud..." | tee -a "$LOG"

rclone copy "$BACKUP_TMP" "${REMOTE_NAME}:${REMOTE_DIR}" -P | tee -a "$LOG"

echo "✔ Upload abgeschlossen." | tee -a "$LOG"

############################################################
# 7) CLEANUP
############################################################

rm -rf "$BACKUP_TMP"

############################################################
# 8) TELEGRAM REPORT
############################################################

BACKUP_END=$(date +%s)
DURATION=$((BACKUP_END - BACKUP_START))
HUMAN_DURATION=$(printf "%02d:%02d:%02d" $((DURATION/3600)) $((DURATION%3600/60)) $((DURATION%60)))
NOW_HUMAN=$(date +"%d.%m.%Y %H:%M:%S")

VOLUME_LIST=$(echo "$VOLUMES" | sed 's/^/ - /')
BIND_LIST=$(printf "%s\n" "${MOUNTS[@]}" | sed 's/^/ - /')

REPORT=$(cat <<EOF
📦 *Backup erfolgreich abgeschlossen!*

🗂 *Backup:* ${BACKUP_NAME}
🖥 *Server:* $(hostname)
⏱ *Dauer:* ${HUMAN_DURATION}
📅 *Zeitpunkt:* ${NOW_HUMAN}

🔐 *Volumes:*
${VOLUME_LIST}

🧩 *Bind-Mounts:*
${BIND_LIST}

🌩 *Upload nach Nextcloud:* OK
REMOTE: \`${REMOTE_NAME}:${REMOTE_DIR}\`
EOF
)

telegram "$REPORT"

echo "--------------------------------------------------------" | tee -a "$LOG"
echo "Backup erfolgreich abgeschlossen!" | tee -a "$LOG"
echo "Name: ${BACKUP_NAME}" | tee -a "$LOG"
echo "Remote: ${REMOTE_NAME}:${REMOTE_DIR}" | tee -a "$LOG"
echo "--------------------------------------------------------" | tee -a "$LOG"
