#!/bin/bash
set -euo pipefail

# Define Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}=======================================${NC}"
echo -e "${BLUE}   Wiretify VPS Installation Script    ${NC}"
echo -e "${BLUE}=======================================${NC}"

# Configuration
DOWNLOAD_URL="https://github.com/accnet/Public/raw/refs/heads/main/wiretify/wiretify.zip" # TODO: Update this URL to point to your wiretify.zip
TMP_DIR="/tmp/wiretify_install"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ENV_FILE=""
APP_PORT="${APP_PORT:-8080}"
WG_PORT="${WG_PORT:-51820}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin}"
WG_PRIVATE_KEY="${WG_PRIVATE_KEY:-}"

load_env_file() {
    local env_file="$1"
    if [ -f "$env_file" ]; then
        echo -e "${GREEN}[+] Loading configuration from ${env_file}...${NC}"
        set -a
        # shellcheck disable=SC1090
        . "$env_file"
        set +a
        SOURCE_ENV_FILE="$env_file"
    fi
}

validate_port() {
    local port_name="$1"
    local port_value="$2"
    if ! [[ "$port_value" =~ ^[0-9]+$ ]] || [ "$port_value" -lt 1 ] || [ "$port_value" -gt 65535 ]; then
        echo -e "${RED}Invalid ${port_name}: ${port_value}. Expected a number between 1 and 65535.${NC}"
        exit 1
    fi
}

# 1. Check Root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run as root (use sudo)!${NC}"
  exit 1
fi

if [ -f "$PWD/.env" ]; then
    load_env_file "$PWD/.env"
elif [ -f "$SCRIPT_DIR/.env" ]; then
    load_env_file "$SCRIPT_DIR/.env"
fi

validate_port "APP_PORT" "$APP_PORT"
validate_port "WG_PORT" "$WG_PORT"

# 2. Check and Install WireGuard & iptables
echo -e "${GREEN}[+] Checking and installing dependencies...${NC}"
if [ -x "$(command -v apt-get)" ]; then
    export DEBIAN_FRONTEND=noninteractive
    export NEEDRESTART_MODE=a
    apt-get update -yq
    apt-get install -yq -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" wireguard iptables iproute2 curl wget unzip
elif [ -x "$(command -v yum)" ]; then
    yum install -y epel-release
    yum install -y wireguard-tools iptables iproute curl wget unzip
else
    echo -e "${RED}Unsupported package manager. Please install wireguard and iptables manually.${NC}"
    exit 1
fi

if [ -z "$WG_PRIVATE_KEY" ] && [ -f /opt/wiretify/.env ]; then
    EXISTING_PRIVATE_KEY="$(grep '^WG_PRIVATE_KEY=' /opt/wiretify/.env | tail -n1 | cut -d= -f2- || true)"
    if [ -n "$EXISTING_PRIVATE_KEY" ]; then
        WG_PRIVATE_KEY="$EXISTING_PRIVATE_KEY"
        echo -e "${BLUE}[*] Reusing existing WG_PRIVATE_KEY from /opt/wiretify/.env${NC}"
    fi
fi

if [ -z "$WG_PRIVATE_KEY" ]; then
    echo -e "${GREEN}[+] Generating WireGuard server private key...${NC}"
    WG_PRIVATE_KEY="$(wg genkey)"
fi

# Enable IPv4 forwarding in kernel
echo -e "${GREEN}[+] Enabling IPv4 IP Forwarding...${NC}"
sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/g' /etc/sysctl.conf
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi
sysctl -p > /dev/null || sysctl -w net.ipv4.ip_forward=1 > /dev/null

# Configure Firewall Ports
echo -e "${GREEN}[+] Configuring Firewall ports (${APP_PORT}/TCP, ${WG_PORT}/UDP)...${NC}"
if [ -x "$(command -v ufw)" ] && ufw status | grep -q "Status: active"; then
    ufw allow "${APP_PORT}/tcp"
    ufw allow "${WG_PORT}/udp"
elif [ -x "$(command -v firewall-cmd)" ] && systemctl is-active --quiet firewalld; then
    firewall-cmd --add-port="${APP_PORT}/tcp" --permanent
    firewall-cmd --add-port="${WG_PORT}/udp" --permanent
    firewall-cmd --reload
elif [ -x "$(command -v iptables)" ]; then
    iptables -C INPUT -p tcp --dport "${APP_PORT}" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "${APP_PORT}" -j ACCEPT
    iptables -C INPUT -p udp --dport "${WG_PORT}" -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport "${WG_PORT}" -j ACCEPT
fi

# 3. Determine Public IP
PUBLIC_IP=$(curl -s ifconfig.me)
if [ -z "$PUBLIC_IP" ]; then
    PUBLIC_IP="127.0.0.1"
fi
echo -e "${GREEN}[+] Detected Public IP: ${PUBLIC_IP}${NC}"

# 4. Prepare deployment directory
echo -e "${GREEN}[+] Setting up /opt/wiretify directory...${NC}"
mkdir -p /opt/wiretify/data

# 5. Download and Extract
echo -e "${GREEN}[+] Downloading Wiretify from ${DOWNLOAD_URL}...${NC}"
rm -rf ${TMP_DIR}
mkdir -p ${TMP_DIR}
wget -qO ${TMP_DIR}/wiretify.zip "${DOWNLOAD_URL}"

echo -e "${GREEN}[+] Extracting files...${NC}"
cd ${TMP_DIR}
unzip -q wiretify.zip
cp wiretify /opt/wiretify/
chmod +x /opt/wiretify/wiretify
rm -rf /opt/wiretify/web
cp -r web /opt/wiretify/web
cd - > /dev/null
rm -rf ${TMP_DIR}

# 6. Create Systemd Service
echo -e "${GREEN}[+] Creating systemd service...${NC}"
cat <<EOF > /etc/systemd/system/wiretify.service
[Unit]
Description=Wiretify VPN Dashboard
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/wiretify
Environment="WIRETIFY_SERVER_ENDPOINT=${PUBLIC_IP}"
Environment="WIRETIFY_DB_PATH=/opt/wiretify/data/wiretify.db"
ExecStart=/opt/wiretify/wiretify
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# 7. Initial configuration (.env)
echo -e "${GREEN}[+] Writing /opt/wiretify/.env...${NC}"
cat <<EOF > /opt/wiretify/.env
APP_PORT=${APP_PORT}
WG_PORT=${WG_PORT}
ADMIN_PASSWORD=${ADMIN_PASSWORD}
WG_PRIVATE_KEY=${WG_PRIVATE_KEY}
EOF
chmod 600 /opt/wiretify/.env

# 8. Start Service
echo -e "${GREEN}[+] Starting Wiretify service...${NC}"
systemctl daemon-reload
systemctl enable wiretify
systemctl restart wiretify

# 9. Announce
echo -e "${BLUE}=======================================${NC}"
echo -e "${GREEN}Wiretify deployed successfully!${NC}"
echo -e "Dashboard: http://${PUBLIC_IP}:${APP_PORT}"
echo -e "Admin Password: ${ADMIN_PASSWORD}"
echo -e "Config File: /opt/wiretify/.env"
if [ -n "$SOURCE_ENV_FILE" ]; then
    echo -e "Source Env: ${SOURCE_ENV_FILE}"
fi
echo -e "WireGuard Port: ${WG_PORT} (Ensure this UDP port is open in your VPS firewall)"
echo -e "Service Status: systemctl status wiretify"
echo -e "To view logs run: journalctl -fu wiretify"
echo -e "${BLUE}=======================================${NC}"
