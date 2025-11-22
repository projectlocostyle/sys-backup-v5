#!/bin/bash
set -euo pipefail

############################################################
# SYS-BACKUP-V5 – BACKUP SCRIPT
############################################################

CONFIG="/etc/sys-backup-v5.conf"
BASE="/opt/sys-backup-v5"
LOG_DIR="/var/log/sys-backup-v5"
TMP_BASE="/tmp/sys-backup-v5"

mkdir -p "$LOG_DIR"
mkdir -p "$TMP_BASE"

if [[ -f "$CONFIG" ]]; then
  # shellcheck disable=SC1090
  . "$CONFIG"
fi

REMOTE_NAME="${REMOTE_NAME:-backup}"
REMOTE_DIR_BASE="${REMOTE_DIR:-Server-Backups}"

TIMESTAMP="$(date +%Y-%m-%d_%H-%M-%S)"
BACKUP_NAME="backup_${TIMESTAMP}"

BACKUP_TMP="${TMP_BASE}/${BACKUP_NAME}"
REMOTE_DIR="${REMOTE_DIR_BASE}/${BACKUP_NAME}"

mkdir -p "$BACKUP_TMP/volumes"
mkdir -p "$BACKUP_TMP/bind_mounts"

LOG="${LOG_DIR}/backup.log"

telegram() {
    if [[ -x "${BASE}/bin/telegram.sh" ]]; then
        "${BASE}/bin/telegram.sh" "$*"
    fi
}

trap 'telegram "❌ Backup fehlgeschlagen auf $(hostname) um $(date)"' ERR

echo "--------------------------------------------------------" | tee "$LOG"
echo "SYS-BACKUP-V5 BACKUP gestartet: ${TIMESTAMP}" | tee -a "$LOG"
echo "--------------------------------------------------------" | tee -a "$LOG"
echo "" | tee -a "$LOG"

############################################################
# 1) MODEL-LISTEN (nur Info, keine Modelldaten)
############################################################

echo "Erfasse Modell-Listen..." | tee -a "$LOG"

echo "models:" > "${BACKUP_TMP}/model_manifest.yml"
echo "  ollama: Docker-Modus (keine Modelldaten im Backup)" >> "${BACKUP_TMP}/model_manifest.yml"

if [[ -d /opt/services/openwebui/models ]]; then
    echo "  openwebui:" >> "${BACKUP_TMP}/model_manifest.yml"
    ls /opt/services/openwebui/models | awk '{print "    - " $1}' >> "${BACKUP_TMP}/model_manifest.yml"
else
    echo "  openwebui: kein Modellordner" >> "${BACKUP_TMP}/model_manifest.yml"
fi

echo "ℹ️ Ollama läuft im Docker – Modelle werden NICHT im normalen Backup gesichert." | tee -a "$LOG"

############################################################
# 2) DOCKER VOLUME BACKUP
############################################################

echo "Starte Volume-Backup..." | tee -a "$LOG"

VOLUMES=$(docker volume ls --format '{{.Name}}' | grep '^services_' || true)

if [[ -z "$VOLUMES" ]]; then
    echo "Keine passenden Docker-Volumes gefunden (services_*)." | tee -a "$LOG"
else
    for VOL in $VOLUMES; do
        echo "  Volume: $VOL" | tee -a "$LOG"
        ARCHIVE="${BACKUP_TMP}/volumes/${VOL}.tar.gz"

        docker run --rm \
            -v "${VOL}:/data:ro" \
            -v "${BACKUP_TMP}/volumes:/out" \
            alpine sh -c "cd /data && tar -czf /out/${VOL}.tar.gz ."

        echo "    ✔ Gesichert: $ARCHIVE" | tee -a "$LOG"
    done
fi

############################################################
# 3) BIND-MOUNT BACKUP
############################################################

echo "Starte Bind-Mount-Backup..." | tee -a "$LOG"

MOUNTS=(
    "/etc/caddy"
    "/opt/services"
    "/opt/sys-backup-v5"
    "/root/.config/rclone"
    "/var/lib/caddy"
)

for SRC in "${MOUNTS[@]}"; do
    if [[ ! -d "$SRC" ]]; then
        echo "  Überspringe (nicht vorhanden): $SRC" | tee -a "$LOG"
        continue
    fi

    SAFE=$(echo "$SRC" | sed 's/\//_/g')
    ARCHIVE="${BACKUP_TMP}/bind_mounts/${SAFE}.tar.gz"

    echo "  Bind-Mount: $SRC" | tee -a "$LOG"

    tar -czf "$ARCHIVE" -C "$SRC" .

    echo "    ✔ Gesichert: $ARCHIVE" | tee -a "$LOG"
done

############################################################
# 4) HASH-BERECHNUNG
############################################################

HASHFILE="${BACKUP_TMP}/hashes.sha256"
find "$BACKUP_TMP" -type f -exec sha256sum {} \; > "$HASHFILE"
echo "✔ Hashes gespeichert unter: $HASHFILE" | tee -a "$LOG"

############################################################
# 5) MANIFEST ERZEUGEN
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

echo "✔ Manifest erstellt: $MANIFEST" | tee -a "$LOG"

############################################################
# 6) UPLOAD
############################################################

echo "Starte Upload zu Nextcloud..." | tee -a "$LOG"

rclone copy "$BACKUP_TMP" "${REMOTE_NAME}:${REMOTE_DIR}" -P | tee -a "$LOG"

echo "✔ Upload abgeschlossen." | tee -a "$LOG"

############################################################
# 7) CLEANUP
############################################################

rm -rf "$BACKUP_TMP"

echo "--------------------------------------------------------" | tee -a "$LOG"
echo "Backup erfolgreich abgeschlossen!" | tee -a "$LOG"
echo "Name: ${BACKUP_NAME}" | tee -a "$LOG"
echo "Remote: ${REMOTE_NAME}:${REMOTE_DIR}" | tee -a "$LOG"
echo "--------------------------------------------------------" | tee -a "$LOG"

telegram "✅ Backup erfolgreich auf $(hostname) – ${BACKUP_NAME}"
