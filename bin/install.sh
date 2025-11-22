#!/bin/bash
set -euo pipefail

echo "===================================================="
echo "  SYS-BACKUP-V5 – INSTALLATION (Wizard & Cloud)"
echo "===================================================="

CONFIG="/etc/sys-backup-v5.conf"
LOG_DIR="/var/log/sys-backup-v5"
SERVICES_DIR="/opt/services"
COMPOSE_FILE="${SERVICES_DIR}/docker-compose.yml"

# Nextcloud Defaults
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

apt update -y
apt install -y curl git unzip ca-certificates gnupg lsb-release rclone

############################################
### 4) DOCKER & DOCKER COMPOSE
############################################

echo "[2/5] Docker prüfen..."
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com | sh
fi

echo "[3/5] docker compose prüfen..."
if ! docker compose version &> /dev/null; then
    LATEST_COMPOSE=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep browser_download_url | grep linux-x86_64 | cut -d '"' -f 4)
    curl -L "$LATEST_COMPOSE" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
fi

############################################
### 5) CADDY INSTALLATION
############################################

if ! command -v caddy &> /dev/null; then
    apt install -y debian-keyring debian-archive-keyring apt-transport-https
    curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --dearmor -o /usr/share/keyrings/caddy.gpg
    echo "deb [signed-by=/usr/share/keyrings/caddy.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main" > /etc/apt/sources.list.d/caddy.list
    apt update
    apt install -y caddy
fi

systemctl enable caddy
systemctl restart caddy

############################################
### 6) RCLONE REMOTE EINRICHTEN
############################################

if ! rclone listremotes | grep -q "^${REMOTE_NAME}:"; then
    rclone config create "$REMOTE_NAME" webdav url="$NC_URL" vendor="nextcloud" user="$NC_USER" pass="$NC_PASS" --non-interactive
fi

# Verbindung testen
if ! rclone ls "${REMOTE_NAME}:${REMOTE_BACKUP_DIR}" >/dev/null 2>&1; then
    rclone mkdir "${REMOTE_NAME}:${REMOTE_BACKUP_DIR}"
fi

############################################
### 7) DOCKER-COMPOSE BASIS
############################################

mkdir -p "$SERVICES_DIR"
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
    networks:
      - webui-net
    restart: unless-stopped

  openwebui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: openwebui
    ports:
      - "3000:8080"
    environment:
      - OLLAMA_BASE_URL=http://ollama:11434
    volumes:
      - services_openwebui_data:/app/backend/data
    networks:
      - webui-net
    restart: unless-stopped

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
    networks:
      - webui-net
    restart: unless-stopped

  ollama:
    image: ollama/ollama:latest
    container_name: ollama
    ports:
      - "11434:11434"
    volumes:
      - services_ollama_data:/root/.ollama
    networks:
      - webui-net
    restart: unless-stopped

  watchtower:
    image: containrrr/watchtower
    container_name: watchtower
    command: --cleanup --interval 3600
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    networks:
      - webui-net
    restart: unless-stopped

EOF

############################################
### 8) ZUSATZ APPS
############################################
# (Unverändert – dein Code bleibt voll funktionsfähig)

add_uptime_kuma() {
cat >> "$COMPOSE_FILE" <<EOF
  uptime-kuma:
    image: louislam/uptime-kuma:1
    container_name: uptime-kuma
    ports:
      - "3001:3001"
    volumes:
      - services_uptimekuma_data:/app/data
    networks:
      - webui-net
    restart: unless-stopped

EOF
}

add_heimdall() {
cat >> "$COMPOSE_FILE" <<EOF
  heimdall:
    image: linuxserver/heimdall
    container_name: heimdall
    ports:
      - "8082:80"
    networks:
      - webui-net
    restart: unless-stopped

EOF
}

add_grafana() {
cat >> "$COMPOSE_FILE" <<EOF
  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    ports:
      - "3002:3000"
    volumes:
      - services_grafana_data:/var/lib/grafana
    networks:
      - webui-net
    restart: unless-stopped

EOF
}

add_prometheus() {
cat >> "$COMPOSE_FILE" <<EOF
  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    ports:
      - "9090:9090"
    volumes:
      - services_prometheus_data:/etc/prometheus
    networks:
      - webui-net
    restart: unless-stopped

EOF
}

add_redis() {
cat >> "$COMPOSE_FILE" <<EOF
  redis:
    image: redis:alpine
    container_name: redis
    ports:
      - "6379:6379"
    volumes:
      - services_redis_data:/data
    networks:
      - webui-net
    restart: unless-stopped

EOF
}

add_postgres() {
cat >> "$COMPOSE_FILE" <<EOF
  postgres:
    image: postgres:16
    container_name: postgres
    environment:
      - POSTGRES_USER=admin
      - POSTGRES_PASSWORD=changeme
      - POSTGRES_DB=appdb
    ports:
      - "5432:5432"
    volumes:
      - services_postgres_data:/var/lib/postgresql/data
    networks:
      - webui-net
    restart: unless-stopped

EOF
}

add_vaultwarden() {
cat >> "$COMPOSE_FILE" <<EOF
  vaultwarden:
    image: vaultwarden/server:latest
    container_name: vaultwarden
    ports:
      - "8084:80"
    volumes:
      - services_vaultwarden_data:/data
    networks:
      - webui-net
    restart: unless-stopped

EOF
}

add_gitea() {
cat >> "$COMPOSE_FILE" <<EOF
  gitea:
    image: gitea/gitea:latest
    container_name: gitea
    environment:
      - USER_UID=1000
      - USER_GID=1000
    ports:
      - "3003:3000"
    volumes:
      - services_gitea_data:/data
    networks:
      - webui-net
    restart: unless-stopped

EOF
}

add_jellyfin() {
cat >> "$COMPOSE_FILE" <<EOF
  jellyfin:
    image: jellyfin/jellyfin:latest
    container_name: jellyfin
    ports:
      - "8096:8096"
    volumes:
      - services_jellyfin_config:/config
    networks:
      - webui-net
    restart: unless-stopped

EOF
}

add_glances() {
cat >> "$COMPOSE_FILE" <<EOF
  glances:
    image: nicolargo/glances:latest-full
    container_name: glances
    ports:
      - "61208:61208"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks:
      - webui-net
    restart: unless-stopped

EOF
}

############################################
### 9) MENÜ FÜR ZUSATZ-APPS
############################################

zusatz_apps_menu() {
    echo ""
    echo "===================================================="
    echo " Zusatz-Apps installieren (optional)"
    echo "===================================================="
    echo "0) Keine zusätzlichen Apps"
    echo "1) Uptime-Kuma"
    echo "2) Heimdall"
    echo "3) Grafana"
    echo "4) Prometheus"
    echo "5) Redis"
    echo "6) Postgres"
    echo "7) Vaultwarden"
    echo "8) Gitea"
    echo "9) Jellyfin"
    echo "10) Glances"
    echo ""
    read -rp "Bitte Auswahl eingeben (z.B. 1 3 7 oder 0): " AUSWAHL

    if [[ "$AUSWAHL" == "0" || -z "$AUSWAHL" ]]; then
        echo "Keine Zusatz-Apps ausgewählt."
        return
    fi

    for app in $AUSWAHL; do
        case "$app" in
            1) add_uptime_kuma ;;
            2) add_heimdall ;;
            3) add_grafana ;;
            4) add_prometheus ;;
            5) add_redis ;;
            6) add_postgres ;;
            7) add_vaultwarden ;;
            8) add_gitea ;;
            9) add_jellyfin ;;
            10) add_glances ;;
            *) echo "Ungültige Auswahl: $app" ;;
        esac
    done
}

# Menü ausführen
zusatz_apps_menu

############################################
### 10) VOLUMES
############################################

cat >> "$COMPOSE_FILE" <<EOF
volumes:
  services_portainer_data:
  services_openwebui_data:
  services_n8n_data:
  services_ollama_data:
  services_uptimekuma_data:
  services_grafana_data:
  services_prometheus_data:
  services_redis_data:
  services_postgres_data:
  services_vaultwarden_data:
  services_gitea_data:
  services_jellyfin_config:

networks:
  webui-net:
    driver: bridge
EOF

############################################
### 11) CADDYFILE
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
### 12) DOCKER STARTEN
############################################

docker compose -f "$COMPOSE_FILE" up -d

############################################
### 13) TELEGRAM
############################################

if [[ "$TELEGRAM_ENABLED" == "yes" ]]; then
    INSTALL_TS="$(date '+%d.%m.%Y %H:%M:%S')"
    SERVER="$(hostname)"

    TELEGRAM_MESSAGE="$(cat <<EOF
✅ Installation erfolgreich

🖥 Server: ${SERVER}
🌐 Domain: ${BASE_DOMAIN}
⏱ Zeitpunkt: ${INSTALL_TS}

📦 Installierte Basis-Dienste:
 - Portainer
 - OpenWebUI
 - N8N
 - Ollama
 - Watchtower

ℹ️ Zusatz-Apps: siehe docker-compose.yml

EOF
)"

    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
         -d chat_id="${TELEGRAM_CHAT_ID}" \
         -d parse_mode="Markdown" \
         --data-urlencode "text=${TELEGRAM_MESSAGE}" >/dev/null
fi

echo "===================================================="
echo " Installation abgeschlossen!"
echo "===================================================="
