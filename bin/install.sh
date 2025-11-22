#!/bin/bash
set -euo pipefail

echo "===================================================="
echo "  SYS-BACKUP-V5 – INSTALLATION (Wizard & Cloud)"
echo "===================================================="

CONFIG="/etc/sys-backup-v5.conf"
LOG_DIR="/var/log/sys-backup-v5"
SERVICES_DIR="/opt/services"
COMPOSE_FILE="${SERVICES_DIR}/docker-compose.yml"

# Nextcloud / rclone Defaults (kannst du bei Bedarf hier ändern)
NC_URL_DEFAULT="https://nextcloud.r-server.ch/remote.php/dav/files/backup/"
NC_USER_DEFAULT="backup"
REMOTE_NAME_DEFAULT="backup"
REMOTE_BACKUP_DIR_DEFAULT="Server-Backups"

mkdir -p "$LOG_DIR"

############################################
### 1) WIZARD: BASISDATEN ABFRAGEN
############################################

echo ""
echo ">>> Basis-Konfiguration (Wizard)"

read -p "Base-Domain (z.B. ai.locostyle.ch): " BASE_DOMAIN
BASE_DOMAIN="${BASE_DOMAIN:-ai.locostyle.ch}"

# Nextcloud-Remote (wir lassen URL/User voreingestellt)
echo ""
echo "Nextcloud / rclone:"
read -p "Nextcloud URL [${NC_URL_DEFAULT}]: " NC_URL
NC_URL="${NC_URL:-$NC_URL_DEFAULT}"

read -p "Nextcloud User [${NC_USER_DEFAULT}]: " NC_USER
NC_USER="${NC_USER:-$NC_USER_DEFAULT}"

read -p "rclone Remote-Name [${REMOTE_NAME_DEFAULT}]: " REMOTE_NAME
REMOTE_NAME="${REMOTE_NAME:-$REMOTE_NAME_DEFAULT}"

read -p "Remote Backup Ordner [${REMOTE_BACKUP_DIR_DEFAULT}]: " REMOTE_BACKUP_DIR
REMOTE_BACKUP_DIR="${REMOTE_BACKUP_DIR:-$REMOTE_BACKUP_DIR_DEFAULT}"

echo ""
read -s -p "Nextcloud Passwort: " NC_PASS
echo ""

# Telegram Wizard
echo ""
echo "Telegram-Benachrichtigungen?"
read -p "Aktivieren? (y/N): " TG_EN
TG_EN="${TG_EN:-n}"

if [[ "${TG_EN,,}" == "y" ]]; then
    TELEGRAM_ENABLED="yes"
    read -p "Telegram Chat-ID: " TELEGRAM_CHAT_ID
    read -s -p "Telegram Bot Token: " TELEGRAM_BOT_TOKEN
    echo ""
else
    TELEGRAM_ENABLED="no"
    TELEGRAM_CHAT_ID=""
    TELEGRAM_BOT_TOKEN=""
fi

# N8N Encryption Key generieren
if command -v openssl >/dev/null 2>&1; then
    N8N_ENCRYPTION_KEY="$(openssl rand -hex 32)"
else
    N8N_ENCRYPTION_KEY="$(head -c 32 /dev/urandom | base64)"
fi

N8N_DOMAIN="n8n.${BASE_DOMAIN}"
PORTAINER_DOMAIN="portainer.${BASE_DOMAIN}"
OLLAMA_DOMAIN="ollama.${BASE_DOMAIN}"
OPENWEBUI_DOMAIN="openwebui.${BASE_DOMAIN}"

############################################
### 2) CONFIG-FILE SCHREIBEN
############################################

cat > "$CONFIG" <<EOF
# SYS-BACKUP-V5 zentrale Konfiguration

BASE_DOMAIN="$BASE_DOMAIN"

N8N_DOMAIN="$N8N_DOMAIN"
PORTAINER_DOMAIN="$PORTAINER_DOMAIN"
OLLAMA_DOMAIN="$OLLAMA_DOMAIN"
OPENWEBUI_DOMAIN="$OPENWEBUI_DOMAIN"

REMOTE_NAME="$REMOTE_NAME"
REMOTE_DIR="$REMOTE_BACKUP_DIR"
NC_URL="$NC_URL"
NC_USER="$NC_USER"

TELEGRAM_ENABLED="$TELEGRAM_ENABLED"
TELEGRAM_CHAT_ID="$TELEGRAM_CHAT_ID"
TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN"

N8N_ENCRYPTION_KEY="$N8N_ENCRYPTION_KEY"
EOF

echo ""
echo "✔ Konfiguration geschrieben nach: $CONFIG"

############################################
### 3) SYSTEM UPDATES & TOOLS
############################################

echo ""
echo "[1/5] System aktualisieren & Tools installieren..."
apt update -y
apt install -y curl git unzip ca-certificates gnupg lsb-release rclone

############################################
### 4) DOCKER & DOCKER COMPOSE
############################################

echo ""
echo "[2/5] Docker prüfen..."
if ! command -v docker &> /dev/null; then
    echo "❌ Docker nicht gefunden – Installation..."
    curl -fsSL https://get.docker.com | sh
else
    echo "✔ Docker ist bereits installiert."
fi

echo ""
echo "[3/5] docker compose prüfen..."
if ! docker compose version &> /dev/null; then
    echo "❌ docker compose fehlt – Installation docker-compose (Standalone)..."
    LATEST_COMPOSE=$(curl -s https://api.github.com/repos/docker/compose/releases/latest \
        | grep browser_download_url | grep linux-x86_64 | cut -d '"' -f 4)
    curl -L "$LATEST_COMPOSE" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
else
    echo "✔ docker compose ist verfügbar."
fi

############################################
### 5) CADDY INSTALLATION
############################################

echo ""
echo "[4/5] Caddy installieren..."

if ! command -v caddy &> /dev/null; then
    apt install -y debian-keyring debian-archive-keyring apt-transport-https

    curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
        | gpg --dearmor -o /usr/share/keyrings/caddy.gpg

    echo "deb [signed-by=/usr/share/keyrings/caddy.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main" \
        > /etc/apt/sources.list.d/caddy.list

    apt update
    apt install -y caddy
else
    echo "✔ Caddy ist bereits installiert."
fi

systemctl enable caddy
systemctl restart caddy

############################################
### 6) RCLONE REMOTE EINRICHTEN
############################################

echo ""
echo "[5/5] rclone Remote '${REMOTE_NAME}' einrichten..."

if rclone listremotes | grep -q "^${REMOTE_NAME}:"; then
    echo "✔ Remote '${REMOTE_NAME}' existiert bereits."
else
    rclone config create "${REMOTE_NAME}" webdav \
        url="${NC_URL}" \
        vendor="nextcloud" \
        user="${NC_USER}" \
        pass="${NC_PASS}" \
        --non-interactive

    echo "✔ Remote '${REMOTE_NAME}' wurde erstellt."
fi

echo "Teste Nextcloud-Verbindung..."

if ! rclone ls "${REMOTE_NAME}:${REMOTE_BACKUP_DIR}" >/dev/null 2>&1; then
    echo "⚠ Ordner '${REMOTE_BACKUP_DIR}' existiert nicht – wird erzeugt..."
    rclone mkdir "${REMOTE_NAME}:${REMOTE_BACKUP_DIR}"
else
    echo "✔ Nextcloud erreichbar."
fi

############################################
### 7) DOCKER-COMPOSE ANLEGEN
############################################

echo ""
echo "Erzeuge Docker-Umgebung unter ${SERVICES_DIR}..."

mkdir -p "$SERVICES_DIR"

# Config laden für Variablen
. "$CONFIG"

cat > "$COMPOSE_FILE" <<EOF
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
    environment:
      - N8N_HOST=${N8N_DOMAIN}
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - N8N_EDITOR_BASE_URL=https://${N8N_DOMAIN}
      - WEBHOOK_URL=https://${N8N_DOMAIN}
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
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
    name: services_portainer_data
  services_openwebui_data:
    name: services_openwebui_data
  services_n8n_data:
    name: services_n8n_data
  services_ollama_data:
    name: services_ollama_data
EOF

echo "✔ docker-compose.yml erstellt: $COMPOSE_FILE"

############################################
### 8) CADDYFILE ERZEUGEN
############################################

cat > /etc/caddy/Caddyfile <<EOF
{
    email admin@${BASE_DOMAIN}
}

${BASE_DOMAIN} {
    respond "OK - ${BASE_DOMAIN} läuft"
}

n8n.${BASE_DOMAIN} {
    reverse_proxy localhost:5678
}

portainer.${BASE_DOMAIN} {
    reverse_proxy localhost:9000
}

ollama.${BASE_DOMAIN} {
    reverse_proxy localhost:11434
}

openwebui.${BASE_DOMAIN} {
    reverse_proxy localhost:3000
}
EOF

systemctl reload caddy || systemctl restart caddy

############################################
### 9) DOCKER STARTEN
############################################

docker compose -f "$COMPOSE_FILE" up -d

echo "===================================================="
echo " Installation abgeschlossen!"
echo "===================================================="

if [[ "$TELEGRAM_ENABLED" == "yes" ]]; then
    /opt/sys-backup-v5/bin/telegram.sh "✅ SYS-BACKUP-V5 installiert auf $(hostname) – Domain: ${BASE_DOMAIN}"
fi
