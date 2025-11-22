#!/bin/bash
set -euo pipefail

echo "===================================================="
echo "  SYS-BACKUP-V5 – INSTALLATION"
echo "===================================================="

#######################################
### 0) CONFIG
#######################################

NC_URL="https://nextcloud.r-server.ch/remote.php/dav/files/backup/"
NC_USER="backup"
REMOTE_NAME="backup"
REMOTE_BACKUP_DIR="Server-Backups"

SERVICES_DIR="/opt/services"
COMPOSE_FILE="${SERVICES_DIR}/docker-compose.yml"

mkdir -p /var/log/sys-backup-v5

#######################################
### 1) System Update
#######################################
apt update -y
apt install -y curl git unzip ca-certificates gnupg lsb-release rclone

#######################################
### 2) Docker
#######################################
if ! command -v docker &>/dev/null; then
    curl -fsSL https://get.docker.com | sh
fi

#######################################
### 3) Docker Compose
#######################################
if ! docker compose version &>/dev/null; then
    LATEST=$(curl -s https://api.github.com/repos/docker/compose/releases/latest \
        | grep browser_download_url | grep linux-x86_64 | cut -d '"' -f 4)
    curl -L "$LATEST" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
fi

#######################################
### 4) Caddy Installation (Stabil)
#######################################
if ! command -v caddy &>/dev/null; then
    apt install -y debian-keyring debian-archive-keyring apt-transport-https

    curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
        | gpg --dearmor -o /usr/share/keyrings/caddy.gpg

    echo "deb [signed-by=/usr/share/keyrings/caddy.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main" \
        > /etc/apt/sources.list.d/caddy.list

    apt update
    apt install -y caddy
fi

systemctl enable caddy
systemctl restart caddy

#######################################
### 5) Rclone Remote
#######################################
if ! rclone listremotes | grep -q "^${REMOTE_NAME}:"; then
    read -s -p "Nextcloud Passwort: " NC_PASS
    echo ""

    rclone config create "${REMOTE_NAME}" webdav \
        url="${NC_URL}" vendor="nextcloud" \
        user="${NC_USER}" pass="${NC_PASS}" \
        --non-interactive
fi

rclone mkdir "${REMOTE_NAME}:${REMOTE_BACKUP_DIR}" || true

#######################################
### 6) Docker Compose erzeugen
#######################################

mkdir -p "$SERVICES_DIR"

cat > "$COMPOSE_FILE" << 'EOF'
version: "3.9"

services:
  portainer:
    image: portainer/portainer-ce:2.21.4
    container_name: portainer
    ports:
      - "9000:9000"
    volumes:
      - services_portainer_data:/data
      - /var/run/docker.sock:/var/run/docker.sock

  openwebui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: openwebui
    ports:
      - "3000:8080"
    volumes:
      - services_openwebui_data:/app/backend/data

  n8n:
    image: docker.n8n.io/n8nio/n8n
    container_name: n8n
    ports:
      - "5678:5678"
    volumes:
      - services_n8n_data:/home/node/.n8n

  ollama:
    image: ollama/ollama:latest
    container_name: ollama
    ports:
      - "11434:11434"
    volumes:
      - services_ollama_data:/root/.ollama

  watchtower:
    image: containrrr/watchtower
    container_name: watchtower
    command: --cleanup --interval 3600
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock

volumes:
  services_portainer_data:
  services_openwebui_data:
  services_n8n_data:
  services_ollama_data:
EOF

#######################################
### START
#######################################
docker compose -f "$COMPOSE_FILE" up -d

echo "===================================================="
echo " INSTALLATION FERTIG!"
echo "===================================================="
