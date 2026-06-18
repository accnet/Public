#!/bin/bash

# Tắt tất cả popup/dialog tương tác khi cài gói trên Ubuntu
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

# ========================================================
# WOOTIFYPANEL - PRODUCTION DEPLOY SCRIPT
# ========================================================

# 1. CẤU HÌNH URL BẢN RELEASE (Đường dẫn tải file .zip)
# Bạn có thể truyền URL vào khi chạy: ./deploy.sh https://url-cua-ban.zip
DEFAULT_URL="https://raw.githubusercontent.com/accnet/Public/main/woopanel/wootify-panel-release.zip"
RELEASE_URL=${1:-$DEFAULT_URL}

if [ -z "$RELEASE_URL" ]; then
    echo -e "${RED}Lỗi: Không tìm thấy RELEASE_URL. Vui lòng cấu hình trong script hoặc truyền vào đối số.${NC}"
    exit 1
fi

INSTALL_DIR="/opt/wootify-panel"
TEMP_ZIP="/tmp/wootify-panel-release.zip"

# Màu sắc cho log
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Hàm log
log() {
    echo -e "${GREEN}[INFO] $1${NC}"
}

replace_or_append_env() {
    local key="$1"
    local value="$2"
    local env_file="$3"

    if grep -qE "^${key}=" "$env_file" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$env_file"
    else
        echo "${key}=${value}" >> "$env_file"
    fi
}

# Kiểm tra quyền root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Vui lòng chạy script với quyền root (sudo).${NC}"
  exit 1
fi

echo -e "${GREEN}>>> Bắt đầu quy trình triển khai WootifyPanel Production...${NC}"

# 2. Kiểm tra và cài đặt công cụ giải nén
echo -e "${GREEN}[1/4] Kiểm tra môi trường hệ thống...${NC}"
if ! command -v unzip &> /dev/null; then
    echo -e "${YELLOW}Đang cài đặt unzip...${NC}"
    if command -v apt-get &> /dev/null; then
        apt-get update && apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" unzip curl
    elif command -v dnf &> /dev/null; then
        dnf install -y unzip curl
    elif command -v yum &> /dev/null; then
        yum install -y unzip curl
    else
        echo -e "${RED}Không thể cài đặt unzip. Vui lòng cài thủ công.${NC}"
        exit 1
    fi
fi

# -------------------------------------------------
# 2a. Kiểm tra và vô hiệu hóa Apache/Nginx nếu đang dùng port 80/443
detect_and_disable_web_servers() {
    local found=false
    local services_to_disable=()

    # Phát hiện Apache
    if command -v apache2 &>/dev/null || command -v httpd &>/dev/null; then
        found=true
        if systemctl is-active --quiet apache2 2>/dev/null; then
            services_to_disable+=("apache2")
        fi
        if systemctl is-active --quiet httpd 2>/dev/null; then
            services_to_disable+=("httpd")
        fi
    fi

    # Phát hiện Nginx
    if command -v nginx &>/dev/null; then
        if systemctl is-active --quiet nginx 2>/dev/null; then
            services_to_disable+=("nginx")
        fi
    fi

    # Nếu không có service nào đang chạy, kiểm tra thêm bằng port
    if [ ${#services_to_disable[@]} -eq 0 ]; then
        local port80_process
        port80_process=$(ss -tlnp 2>/dev/null | grep ':80 ' | head -1)
        local port443_process
        port443_process=$(ss -tlnp 2>/dev/null | grep ':443 ' | head -1)

        if [ -n "$port80_process" ] || [ -n "$port443_process" ]; then
            echo -e "${YELLOW}Phát hiện process đang listen trên port 80/443 (có thể là Apache/Nginx).${NC}"
            echo -e "${YELLOW}Chi tiết:${NC}"
            [ -n "$port80_process" ] && echo -e "${YELLOW}  Port 80: $port80_process${NC}"
            [ -n "$port443_process" ] && echo -e "${YELLOW}  Port 443: $port443_process${NC}"
            echo -e "${YELLOW}Vui lòng kiểm tra thủ công và tắt service nếu cần.${NC}"
        fi
    fi

    # Vô hiệu hóa và gỡ bỏ các service tìm thấy
    for svc in "${services_to_disable[@]}"; do
        echo -e "${YELLOW}Phát hiện $svc đang chạy. Tiến hành dừng, vô hiệu hóa và gỡ bỏ...${NC}"
        systemctl stop "$svc" 2>/dev/null
        systemctl disable "$svc" 2>/dev/null

        # Gỡ bỏ package tương ứng
        local pkg_name=""
        case "$svc" in
            apache2) pkg_name="apache2" ;;
            httpd)   pkg_name="httpd" ;;
            nginx)   pkg_name="nginx" ;;
        esac

        if [ -n "$pkg_name" ]; then
            echo -e "${YELLOW}Đang gỡ bỏ $pkg_name...${NC}"
            if command -v apt-get &>/dev/null; then
                apt-get purge -y "$pkg_name" 2>/dev/null
                apt-get autoremove -y 2>/dev/null
            elif command -v dnf &>/dev/null; then
                dnf remove -y "$pkg_name" 2>/dev/null
            elif command -v yum &>/dev/null; then
                yum remove -y "$pkg_name" 2>/dev/null
            fi
            echo -e "${GREEN}✓ Đã gỡ bỏ $pkg_name${NC}"
        fi

        echo -e "${GREEN}✓ Đã dừng, vô hiệu hóa và gỡ bỏ $svc thành công${NC}"
    done

    if [ "$found" = false ] && [ ${#services_to_disable[@]} -eq 0 ]; then
        log "Không phát hiện Apache/Nginx đang chạy. Tiếp tục..."
    fi
}

detect_and_disable_web_servers

# -------------------------------------------------
# 2b. Cài đặt và cấu hình firewall (ufw cho Debian/Ubuntu, firewalld cho RHEL)
if command -v apt-get >/dev/null 2>&1; then
    if ! command -v ufw >/dev/null 2>&1; then
        log "Installing ufw firewall..."
        apt-get update && apt-get install -y ufw
    fi

    if command -v ufw >/dev/null 2>&1; then
        log "Configuring ufw firewall..."
        ufw allow OpenSSH || ufw allow 22/tcp
        ufw allow 80/tcp
        ufw allow 443/tcp
        ufw allow 8888/tcp
        ufw --force enable
    fi
elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
    PKG_CMD="dnf"
    if ! command -v dnf >/dev/null 2>&1; then
        PKG_CMD="yum"
    fi

    if ! command -v firewall-cmd >/dev/null 2>&1; then
        log "Installing firewalld..."
        "$PKG_CMD" install -y firewalld
    fi

    if command -v firewall-cmd >/dev/null 2>&1; then
        log "Configuring firewalld..."
        systemctl enable --now firewalld
        firewall-cmd --permanent --add-service=ssh
        firewall-cmd --permanent --add-service=http
        firewall-cmd --permanent --add-service=https
        firewall-cmd --permanent --add-port=8888/tcp
        firewall-cmd --reload
    fi
else
    log "No firewall tool detected. Skipping firewall configuration."
fi
# -------------------------------------------------

# Tải file release (Xử lý cả URL và Local File)
echo -e "${GREEN}[2/4] Đang chuẩn bị file release...${NC}"

# Xóa file cũ nếu có
rm -f "$TEMP_ZIP"

if [[ "$RELEASE_URL" == http* ]]; then
    echo -e "${YELLOW}Đang tải từ URL: $RELEASE_URL${NC}"
    if command -v curl &> /dev/null; then
        curl -L "$RELEASE_URL" -o "$TEMP_ZIP"
    elif command -v wget &> /dev/null; then
        wget -O "$TEMP_ZIP" "$RELEASE_URL"
    else
        echo -e "${RED}Lỗi: Hệ thống thiếu cả curl và wget.${NC}"
        exit 1
    fi
else
    echo -e "${YELLOW}Sử dụng file local: $RELEASE_URL${NC}"
    cp "$RELEASE_URL" "$TEMP_ZIP" || { echo -e "${RED}Lỗi: Không thể copy file $RELEASE_URL${NC}"; exit 1; }
fi

if [ ! -f "$TEMP_ZIP" ] || [ ! -s "$TEMP_ZIP" ]; then
    echo -e "${RED}Lỗi: Không thể tải file từ $RELEASE_URL. Vui lòng kiểm tra lại URL.${NC}"
    exit 1
fi

# 4. Giải nén và thiết lập thư mục
echo -e "${GREEN}[3/4] Đang giải nén vào $INSTALL_DIR...${NC}"
mkdir -p "$INSTALL_DIR"

# Backup .env trước khi giải nén — unzip -o sẽ ghi đè .env bằng
# .env.example từ bản release, làm mất PANEL_PASSWORD và các tùy chỉnh.
ENV_BACKUP=""
if [ -f "$INSTALL_DIR/.env" ]; then
    ENV_BACKUP="$(mktemp)"
    cp "$INSTALL_DIR/.env" "$ENV_BACKUP"
    echo -e "${YELLOW}Đã backup .env hiện tại trước khi giải nén.${NC}"
fi

unzip -o "$TEMP_ZIP" -d "$INSTALL_DIR"
rm -f "$TEMP_ZIP" # Dọn dẹp sau khi giải nén thành công

# Khôi phục .env từ backup nếu có.
if [ -n "$ENV_BACKUP" ] && [ -f "$ENV_BACKUP" ]; then
    cp "$ENV_BACKUP" "$INSTALL_DIR/.env"
    rm -f "$ENV_BACKUP"
    echo -e "${YELLOW}Đã khôi phục .env từ backup.${NC}"
fi

cd "$INSTALL_DIR"
chmod +x panel
chmod -R +x scripts/
mkdir -p storage
chmod 755 storage

# Tạo .env nếu chưa có (lần đầu deploy)
if [ ! -f ".env" ]; then
    cp .env.example .env || touch .env
    echo -e "${YELLOW}Đã tạo file .env từ mẫu. Vui lòng cập nhật cấu hình nếu cần.${NC}"
fi

# Chuẩn hóa cấu hình production mặc định
replace_or_append_env "GIN_MODE" "release" ".env"
replace_or_append_env "PANEL_LISTEN_ADDR" ":8888" ".env"
replace_or_append_env "PANEL_COOKIE_SECURE" "true" ".env"

# 5. Cấu hình Systemd (Triển khai nhanh)
echo -e "${GREEN}[4/4] Đang thiết lập Systemd Service...${NC}"
SERVICE_FILE="/etc/systemd/system/wootify-panel.service"

cat > $SERVICE_FILE <<EOF
[Unit]
Description=WootifyPanel - Production
After=network.target

[Service]
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/panel
Restart=always
RestartSec=5
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=wootify-panel

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable wootify-panel
systemctl restart wootify-panel

# Lấy IP Public
IP_ADDRESS=$(curl -s --connect-timeout 2 ifconfig.me || hostname -I | awk '{print $1}')

echo -e "${GREEN}==============================================${NC}"
echo -e "${GREEN}   TRIỂN KHAI PRODUCTION HOÀN TẤT!   ${NC}"
echo -e "${GREEN}==============================================${NC}"
echo -e "Địa chỉ Panel: http://$IP_ADDRESS:8888"
echo -e "Thư mục cài đặt: $INSTALL_DIR"
echo -e "Trạng thái Service: systemctl status wootify-panel"
echo -e "Xem Logs: journalctl -u wootify-panel -f"
echo -e "${GREEN}==============================================${NC}"
echo -e "${YELLOW}Lưu ý: Script đã mở 80/443/8888 trên firewall hệ điều hành nếu có thể. Hãy kiểm tra thêm firewall/security group của nhà cung cấp VPS.${NC}"
