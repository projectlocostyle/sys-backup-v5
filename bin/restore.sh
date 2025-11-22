#!/bin/bash
set -euo pipefail

source /opt/sys-backup-v5/bin/telegram.sh

START=$(date +%s)

REMOTE="backup"
RDIR="Server-Backups"
TMP="/tmp/sys-backup-v5"

mkdir -p "$TMP"

echo "Backups werden geladen…"

LIST=$(rclone lsf "${REMOTE}:${RDIR}" --dirs-only)

i=1
declare -A MAP

while read -r BK; do
    [[ -z "$BK" ]] && continue
    BK=${BK%/}
    MAP[$i]="$BK"
    echo " $i) $BK"
    ((i++))
done <<< "$LIST"

read -p "Restore Nummer: " CH
SELECTED="${MAP[$CH]}"

REST="${TMP}/${SELECTED}"
rm -rf "$REST"
mkdir -p "$REST"

rclone copy "${REMOTE}:${RDIR}/${SELECTED}" "$REST" -P

docker compose -f /opt/services/docker-compose.yml down || true

### Volume Restore
VOL_BACKUP=$(ls "$REST/volumes" | sed 's/.tar.gz//')
VOL_LOCAL=$(docker volume ls -q)

declare -A MATCH

for B in $VOL_BACKUP; do
    KEY=$(echo "$B" | sed 's/services_//')
    for L in $VOL_LOCAL; do
        if [[ "$L" == *"$KEY"* ]]; then
            MATCH[$B]="$L"
        fi
    done
done

for B in "${!MATCH[@]}"; do
    docker run --rm \
        -v "${MATCH[$B]}:/restore" \
        -v "${REST}/volumes/${B}.tar.gz:/backup.tar.gz" \
        alpine sh -c "rm -rf /restore/* && tar -xzf /backup.tar.gz -C /restore"
done

### Bind Mounts
for TAR in "${REST}/bind_mounts/"*.tar.gz; do
    NAME=$(basename "$TAR" .tar.gz)
    DIR=$(echo "$NAME" | sed 's/^_//; s/_/\//g')
    mkdir -p "/$DIR"
    tar -xzf "$TAR" -C "/$DIR"
done

docker compose -f /opt/services/docker-compose.yml up -d

systemctl reload caddy

END=$(date +%s)
DUR=$((END-START))

MSG="🟢 *Restore erfolgreich*\n\n"
MSG+="🗂 *Backup:* ${SELECTED}\n"
MSG+="🖥 *Server:* $(hostname)\n"
MSG+="⏱ *Dauer:* ${DUR} Sekunden\n\n"
MSG+="🔁 *Volumes:*\n"
for V in "${!MATCH[@]}"; do MSG+=" • \`${V}\` → ${MATCH[$V]}\n"; done
MSG+="\n🧩 *Bind Mounts:*\n"
for TAR in "${REST}/bind_mounts/"*.tar.gz; do
    MSG+=" • $(basename "$TAR")\n"
done

send_telegram_message "$MSG"

echo "Restore abgeschlossen."
