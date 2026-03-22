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
    else
        echo -e "${RED}Không thể cài đặt unzip. Vui lòng cài thủ công.${NC}"
        exit 1
    fi
fi

# -------------------------------------------------
# 2b. Cài đặt và cấu hình firewall (ufw cho Debian/Ubuntu, firewalld cho RHEL)
if command -v ufw >/dev/null 2>&1; then
    log "Configuring ufw firewall..."
    ufw --force enable
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow 8080/tcp
elif command -v firewall-cmd >/dev/null 2>&1; then
    log "Configuring firewalld..."
    systemctl enable --now firewalld
    firewall-cmd --permanent --add-service=http
    firewall-cmd --permanent --add-service=https
    firewall-cmd --permanent --add-port=8080/tcp
    firewall-cmd --reload
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
unzip -o "$TEMP_ZIP" -d "$INSTALL_DIR"
rm -f "$TEMP_ZIP" # Dọn dẹp sau khi giải nén thành công

cd "$INSTALL_DIR"
chmod +x panel
chmod -R +x scripts/
mkdir -p storage
chmod 755 storage

# Tạo .env nếu chưa có
if [ ! -f ".env" ]; then
    cp .env.example .env || touch .env
    echo -e "${YELLOW}Đã tạo file .env từ mẫu. Vui lòng cập nhật cấu hình nếu cần.${NC}"
fi

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
echo -e "Địa chỉ Panel: http://$IP_ADDRESS:8080"
echo -e "Thư mục cài đặt: $INSTALL_DIR"
echo -e "Trạng thái Service: systemctl status wootify-panel"
echo -e "Xem Logs: journalctl -u wootify-panel -f"
echo -e "${GREEN}==============================================${NC}"
echo -e "${YELLOW}Lưu ý: Đừng quên mở cổng 8080 trên Firewall của bạn.${NC}"
