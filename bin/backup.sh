#!/bin/bash
set -euo pipefail

source /opt/sys-backup-v5/bin/telegram.sh

START=$(date +%s)

TS=$(date +%Y-%m-%d_%H-%M-%S)
NAME="backup_${TS}"

BASE="/opt/sys-backup-v5"
TMP="/tmp/sys-backup-v5/${NAME}"
LOG="/var/log/sys-backup-v5/backup.log"

REMOTE="backup"
RDIR="Server-Backups/${NAME}"

mkdir -p "$TMP/volumes"
mkdir -p "$TMP/bind_mounts"

echo "Backup gestartet: $TS" | tee "$LOG"

#################################
### 1) Modelle
#################################
echo "models:" > "${TMP}/model_manifest.yml"
echo "  ollama: Docker-Modus" >> "${TMP}/model_manifest.yml"

#################################
### 2) Docker-Volumes
#################################
VOLUMES=$(docker volume ls --format '{{.Name}}' | grep '^services_')

for VOL in $VOLUMES; do
    docker run --rm \
        -v "${VOL}:/data:ro" \
        -v "${TMP}/volumes:/out" \
        alpine sh -c "cd /data && tar -czf /out/${VOL}.tar.gz ."
done

#################################
### 3) Bind Mounts
#################################
MOUNTS=(
    "/etc/caddy"
    "/opt/services"
    "/opt/sys-backup-v5"
    "/root/.config/rclone"
    "/var/lib/caddy"
)

for M in "${MOUNTS[@]}"; do
    SAFE=$(echo "$M" | sed 's/\//_/g')
    tar -czf "${TMP}/bind_mounts/${SAFE}.tar.gz" -C "$M" .
done

#################################
### 4) Hashes + Manifest
#################################
find "$TMP" -type f -exec sha256sum {} \; > "${TMP}/hashes.sha256"

cat <<EOF > "${TMP}/manifest.yml"
backup: "$NAME"
time: "$TS"
host: "$(hostname)"
volumes:
$(echo "$VOLUMES" | sed 's/^/ - /')
bind_mounts:
$(printf "%s\n" "${MOUNTS[@]}" | sed 's/^/ - /')
EOF

#################################
### 5) Upload
#################################
rclone copy "$TMP" "${REMOTE}:${RDIR}" -P

#################################
### 6) Telegram
#################################
END=$(date +%s)
DUR=$((END-START))

MSG="🟦 *Backup abgeschlossen*\n\n"
MSG+="🗂 *Name:* ${NAME}\n"
MSG+="🖥 *Server:* $(hostname)\n"
MSG+="⏱ *Dauer:* ${DUR} Sekunden\n\n"
MSG+="🔐 *Volumes:*\n"
for VOL in $VOLUMES; do MSG+=" • \`${VOL}\`\n"; done
MSG+="\n🧩 *Bind Mounts:*\n"
for M in "${MOUNTS[@]}"; do MSG+=" • ${M}\n"; done

send_telegram_message "$MSG"

#################################
### 7) Cleanup
#################################
rm -rf "$TMP"

echo "Backup fertig: $NAME"
