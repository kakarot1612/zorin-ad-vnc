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

# 2. Check and install x11vnc package if not present
if ! command -v x11vnc >/dev/null 2>&1; then
    echo -e "\033[0;34m[INFO]\033[0m Đang cài đặt gói x11vnc..."
    apt-get update -qq || true
    apt-get install -y x11vnc >/dev/null 2>&1 || true
fi
if command -v x11vnc >/dev/null 2>&1; then
    echo -e "\033[0;32m[✓ OK]\033[0m Gói x11vnc đã sẵn sàng: $(x11vnc -version 2>&1 | head -n 1)"
fi

# 3. Ensure VNC default password exists and is valid
mkdir -p /etc/x11vnc
chmod 755 /etc/x11vnc
if [[ ! -s /etc/x11vnc/vncpwd ]]; then
    if command -v x11vnc >/dev/null 2>&1; then
        x11vnc -storepasswd "123456" /etc/x11vnc/vncpwd >/dev/null 2>&1 || true
        if [[ ! -s /etc/x11vnc/vncpwd ]]; then
            printf "123456\n123456\n" | x11vnc -storepasswd /etc/x11vnc/vncpwd >/dev/null 2>&1 || true
        fi
        chmod 644 /etc/x11vnc/vncpwd 2>/dev/null || true
        echo -e "\033[0;32m[✓ OK]\033[0m Đã tạo mật khẩu VNC mặc định: /etc/x11vnc/vncpwd (123456)"
    fi
fi

# 4. Install daemon script
cp "$INSTALL_DIR/lib/x11vnc_session_daemon.sh" "$DAEMON_PATH"
chmod +x "$DAEMON_PATH"
echo -e "\033[0;32m[✓ OK]\033[0m Đã cài đặt daemon script vào: $DAEMON_PATH"

# 4.1 Ensure GDM uses Xorg instead of Wayland for x11vnc
for gdm_conf in /etc/gdm3/custom.conf /etc/gdm/custom.conf; do
    if [[ -f "$gdm_conf" ]]; then
        if grep -q -E "^#?[[:space:]]*WaylandEnable=" "$gdm_conf"; then
            sed -i -E 's/^#?[[:space:]]*WaylandEnable=.*/WaylandEnable=false/' "$gdm_conf"
        else
            sed -i '/\[daemon\]/a WaylandEnable=false' "$gdm_conf" 2>/dev/null || echo -e "\n[daemon]\nWaylandEnable=false" >> "$gdm_conf"
        fi
        echo -e "\033[0;32m[✓ OK]\033[0m Đã cấu hình GDM ép Xorg (WaylandEnable=false): $gdm_conf"
    fi
done

# 5. Install systemd service & alias symlink
cp "$INSTALL_DIR/systemd/zorin-x11vnc.service" "$SERVICE_PATH"
ln -sf "$SERVICE_PATH" /etc/systemd/system/x11vnc.service
systemctl daemon-reload
systemctl enable zorin-x11vnc.service 2>/dev/null || true
systemctl restart zorin-x11vnc.service 2>/dev/null || true
echo -e "\033[0;32m[✓ OK]\033[0m Đã kích hoạt dịch vụ: zorin-x11vnc (Alias: x11vnc.service)"

# 6. Enable NetBIOS & LLMNR (so other PCs can ping this computer by hostname)
local_h=$(hostname -s)
if [[ -f /etc/samba/smb.conf ]]; then
    if ! grep -q "netbios name" /etc/samba/smb.conf; then
        sed -i "/\[global\]/a \   netbios name = ${local_h^^}\n   disable netbios = no" /etc/samba/smb.conf 2>/dev/null || true
    fi
    systemctl enable --now nmbd 2>/dev/null || true
    systemctl restart nmbd 2>/dev/null || true
fi
mkdir -p /etc/systemd/resolved.conf.d 2>/dev/null || true
cat > /etc/systemd/resolved.conf.d/llmnr.conf <<EOF
[Resolve]
LLMNR=yes
MulticastDNS=yes
EOF
systemctl restart systemd-resolved 2>/dev/null || true
echo -e "\033[0;32m[✓ OK]\033[0m Đã kích hoạt phản hồi NetBIOS (nmbd) & LLMNR cho tên máy: ${local_h^^}"

# 7. Create wrapper / symlink for global command 'zorin-ad-vnc'
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
