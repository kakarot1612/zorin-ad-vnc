#!/usr/bin/env bash
# ==============================================================================
# Zorin OS AD Join & X11VNC Management Tool
# File: install.sh
# Description: One-command installer to setup the management tool globally.
# ==============================================================================

set -e

if [[ $EUID -ne 0 ]]; then
    echo -e "\033[0;31m[✗ ERROR]\033[0m Script này yêu cầu quyền root. Vui lòng chạy: sudo ./install.sh"
    exit 1
fi

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_PATH="/usr/local/bin/zorin-ad-vnc"
DAEMON_PATH="/usr/local/bin/zorin-x11vnc-daemon.sh"
SERVICE_PATH="/etc/systemd/system/zorin-x11vnc.service"

echo -e "\033[1;34m==>\033[1;37m ĐANG CÀI ĐẶT ZORIN AD JOIN & X11VNC MANAGEMENT TOOL...\033[0m"

# 1. Ensure scripts have execution permissions
chmod +x "$INSTALL_DIR"/*.sh "$INSTALL_DIR"/lib/*.sh 2>/dev/null || true

# 2. Install daemon script
cp "$INSTALL_DIR/lib/x11vnc_session_daemon.sh" "$DAEMON_PATH"
chmod +x "$DAEMON_PATH"
echo -e "\033[0;32m[✓ OK]\033[0m Đã cài đặt daemon script vào: $DAEMON_PATH"

# 3. Install systemd service
cp "$INSTALL_DIR/systemd/zorin-x11vnc.service" "$SERVICE_PATH"
systemctl daemon-reload
echo -e "\033[0;32m[✓ OK]\033[0m Đã cài đặt systemd unit: $SERVICE_PATH"

# 4. Create wrapper / symlink for global command 'zorin-ad-vnc'
cat > "$BIN_PATH" <<EOF
#!/usr/bin/env bash
exec bash "$INSTALL_DIR/zorin-ad-vnc.sh" "\$@"
EOF
chmod +x "$BIN_PATH"
echo -e "\033[0;32m[✓ OK]\033[0m Đã tạo lệnh toàn cục: $BIN_PATH"

echo -e "\n\033[1;32m=================================================================\033[0m"
echo -e "\033[1;32m CÀI ĐẶT THÀNH CÔNG! BẠN CÓ THỂ CHẠY TOOL BẰNG CÁCH GÕ:         \033[0m"
echo -e "   \033[1;37msudo zorin-ad-vnc\033[0m"
echo -e " Hoặc chạy trực tiếp: \033[1;37msudo ./zorin-ad-vnc.sh\033[0m"
echo -e "\033[1;32m=================================================================\033[0m\n"

read -r -p "Bạn có muốn mở giao diện quản trị ngay bây giờ? [Y/n]: " run_now
run_now="${run_now:-Y}"
if [[ "$run_now" =~ ^[Yy]$ ]]; then
    exec "$BIN_PATH"
fi
