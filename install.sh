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

# 3. Detect primary desktop user and home directory
TARGET_USER="${VNC_USER:-${SUDO_USER:-$(logname 2>/dev/null || id -un 1000 2>/dev/null || whoami)}}"
TARGET_HOME=$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6)
TARGET_HOME="${TARGET_HOME:-/home/$TARGET_USER}"
TARGET_UID=$(id -u "$TARGET_USER" 2>/dev/null || echo 1000)

# 4. Ensure VNC password file exists (/etc/x11vnc/passwd)
mkdir -p /etc/x11vnc
chmod 755 /etc/x11vnc
if [[ ! -s /etc/x11vnc/passwd ]]; then
    if [[ -s /etc/x11vnc/vncpwd ]]; then
        cp /etc/x11vnc/vncpwd /etc/x11vnc/passwd
    elif command -v x11vnc >/dev/null 2>&1; then
        x11vnc -storepasswd "123456" /etc/x11vnc/passwd >/dev/null 2>&1 || true
        if [[ ! -s /etc/x11vnc/passwd ]]; then
            printf "123456\n123456\n" | x11vnc -storepasswd /etc/x11vnc/passwd >/dev/null 2>&1 || true
        fi
    fi
fi
chown -R "${TARGET_USER}:${TARGET_USER}" /etc/x11vnc 2>/dev/null || true
chmod 600 /etc/x11vnc/passwd 2>/dev/null || true
ln -sf /etc/x11vnc/passwd /etc/x11vnc/vncpwd 2>/dev/null || true
echo -e "\033[0;32m[✓ OK]\033[0m File mật khẩu VNC: /etc/x11vnc/passwd (Sở hữu: ${TARGET_USER})"

# 5. Ensure Xauthority file exists and has correct permissions
touch "${TARGET_HOME}/.Xauthority" 2>/dev/null || true

# Copy active Xorg auth cookie from live session if present
if [[ -f "/run/user/${TARGET_UID}/gdm/Xauthority" ]]; then
    cp -f "/run/user/${TARGET_UID}/gdm/Xauthority" "${TARGET_HOME}/.Xauthority" 2>/dev/null || true
fi
local_xorg_auth=$(ps -eo args 2>/dev/null | grep -E '[X]org' | grep -o -E -- '-auth[ =][^ ]+' | awk '{print $2}' | head -n 1)
if [[ -n "$local_xorg_auth" && -f "$local_xorg_auth" ]]; then
    cp -f "$local_xorg_auth" "${TARGET_HOME}/.Xauthority" 2>/dev/null || true
fi
for xf in /run/user/"${TARGET_UID}"/xauth*; do
    if [[ -f "$xf" ]]; then
        xauth -f "${TARGET_HOME}/.Xauthority" merge "$xf" 2>/dev/null || true
    fi
done
chown "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/.Xauthority" 2>/dev/null || true
chmod 600 "${TARGET_HOME}/.Xauthority" 2>/dev/null || true

# 6. Ensure GDM uses Xorg instead of Wayland for x11vnc
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

# 7. Cài đặt script Daemon động vào /usr/local/bin/zorin-x11vnc-daemon.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/lib/x11vnc_session_daemon.sh" ]]; then
    cp -f "${SCRIPT_DIR}/lib/x11vnc_session_daemon.sh" "/usr/local/bin/zorin-x11vnc-daemon.sh"
fi
chmod 755 "/usr/local/bin/zorin-x11vnc-daemon.sh"
echo -e "\033[0;32m[✓ OK]\033[0m Đã cài đặt Daemon phát hiện phiên đăng nhập: /usr/local/bin/zorin-x11vnc-daemon.sh"

# Tạo systemd service cho Zorin OS Dynamic X11VNC Session Daemon (chuẩn máy mẫu)
cat > "/etc/systemd/system/zorin-x11vnc.service" <<EOF
[Unit]
Description=Zorin OS Dynamic X11VNC Session Daemon
Documentation=https://github.com/vnit/zorin-ad-vnc
After=network.target gdm.service sssd.service
Wants=gdm.service

[Service]
Type=simple
ExecStart=/usr/local/bin/zorin-x11vnc-daemon.sh
Restart=always
RestartSec=5
KillMode=process
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Dừng service x11vnc tĩnh cũ để tránh xung đột cổng 5900
systemctl stop x11vnc.service 2>/dev/null || true
systemctl disable x11vnc.service 2>/dev/null || true
rm -f /etc/systemd/system/x11vnc.service 2>/dev/null || true

systemctl daemon-reload
systemctl enable zorin-x11vnc.service 2>/dev/null || true
systemctl restart zorin-x11vnc.service 2>/dev/null || true
echo -e "\033[0;32m[✓ OK]\033[0m Đã kích hoạt dịch vụ: zorin-x11vnc.service"

# 8. Multi-user VNC hooks: Allow x11vnc to capture screen for ANY user (Local or AD)
# Hook 1: Xsession.d (runs for all Xorg sessions upon login)
mkdir -p /etc/X11/Xsession.d
cat > /etc/X11/Xsession.d/99zorin-vnc-xauth <<'EOF'
# Grant local display access so x11vnc service can remote into any user's session
if [ -n "$DISPLAY" ]; then
    xhost +local: >/dev/null 2>&1 || true
fi
EOF
chmod 644 /etc/X11/Xsession.d/99zorin-vnc-xauth
chmod 755 /etc/x11vnc
chmod 644 /etc/x11vnc/passwd /etc/x11vnc/vncpwd 2>/dev/null || true

# Apply immediately to current desktop if logged in
su - "$TARGET_USER" -c "DISPLAY=:0 XAUTHORITY='${TARGET_HOME}/.Xauthority' xhost +local:" 2>/dev/null || true
xhost +local: >/dev/null 2>&1 || true
echo -e "\033[0;32m[✓ OK]\033[0m Đã kích hoạt hook tự động chạy VNC cho mọi User (Local & Domain AD):"
echo -e "         - /etc/X11/Xsession.d/99zorin-vnc-xauth"
echo -e "         - /etc/xdg/autostart/zorin-vnc-xhost.desktop"

# 9. Kiểm thử cổng mạng TCP 5900 và trạng thái dịch vụ (Port Test)
echo -e "\n\033[1;34m==>\033[1;37m ĐANG KIỂM THỬ DỊCH VỤ X11VNC & CỔNG 5900 (PORT TEST)...\033[0m"
sleep 2
vnc_state=$(systemctl is-active zorin-x11vnc.service 2>/dev/null || echo "unknown")
if [[ "$vnc_state" == "active" ]]; then
    echo -e "\033[0;32m[✓ OK]\033[0m Dịch vụ zorin-x11vnc.service: ĐANG CHẠY [ACTIVE]"
else
    echo -e "\033[0;31m[✗ LỖI]\033[0m Dịch vụ zorin-x11vnc.service: THẤT BẠI [Trạng thái: ${vnc_state}]"
fi

if ss -tulpn 2>/dev/null | grep -E ':5900\b' >/dev/null; then
    echo -e "\033[0;32m[✓ OK]\033[0m Cổng TCP 5900: ĐÃ MỞ & ĐANG LẮNG NGHE [LISTENING]"
    local_vnc_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    echo -e "      Kết nối thử: \033[1;32m${local_vnc_ip}:5900\033[0m"
else
    echo -e "\033[0;31m[✗ LỖI]\033[0m Cổng TCP 5900 CHƯA MỞ!"
    if [[ "$XDG_SESSION_TYPE" == "wayland" ]]; then
        echo -e "\033[0;33m[!] NGUYÊN NHÂN: Phiên đồ họa đang chạy Wayland. Máy CẦN REBOOT (sudo reboot) để chuyển sang Xorg!\033[0m"
    fi
    echo -e "\033[1;31m--- Chi tiết lỗi systemd (journalctl -u x11vnc) ---\033[0m"
    journalctl -u x11vnc -n 12 --no-pager 2>/dev/null || true
    echo -e "\033[1;31m---------------------------------------------------\033[0m"
fi

# 10. Enable NetBIOS & LLMNR (so other PCs can ping this computer by hostname)
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
