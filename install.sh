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
chown "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/.Xauthority" 2>/dev/null || true
chmod 600 "${TARGET_HOME}/.Xauthority" 2>/dev/null || true

# Merge active Xorg cookie if available
if [[ -f "/run/user/${TARGET_UID}/gdm/Xauthority" ]]; then
    xauth -f "${TARGET_HOME}/.Xauthority" merge "/run/user/${TARGET_UID}/gdm/Xauthority" 2>/dev/null || true
fi
for xf in /run/user/"${TARGET_UID}"/xauth*; do
    if [[ -f "$xf" ]]; then
        xauth -f "${TARGET_HOME}/.Xauthority" merge "$xf" 2>/dev/null || true
    fi
done

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

# 7. Create & Install systemd unit matching the exact proven working setup
cat > "/etc/systemd/system/x11vnc.service" <<EOF
[Unit]
Description=x11vnc remote desktop
After=display-manager.service network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${TARGET_USER}
Environment="DISPLAY=:0"
Environment="DISPALY=:0"
Environment="XAUTHORITY=${TARGET_HOME}/.Xauthority"
ExecStart=/usr/bin/x11vnc -display \${DISPALY} -auth \${XAUTHORITY} -rfbauth /etc/x11vnc/passwd -forever -shared -noxdamage -rfbport 5900
Restart=on-failure
RestartSec=10

[Install]
WantedBy=graphical.target
Alias=zorin-x11vnc.service
EOF

ln -sf /etc/systemd/system/x11vnc.service /etc/systemd/system/zorin-x11vnc.service
systemctl daemon-reload
systemctl enable x11vnc.service 2>/dev/null || true
systemctl restart x11vnc.service 2>/dev/null || true
echo -e "\033[0;32m[✓ OK]\033[0m Đã kích hoạt dịch vụ: x11vnc.service (User: ${TARGET_USER})"

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

# Hook 2: XDG Desktop Autostart (runs when any user enters GUI desktop)
mkdir -p /etc/xdg/autostart
cat > /etc/xdg/autostart/zorin-vnc-xhost.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Zorin VNC XHost Setup
Exec=xhost +local:
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF
chmod 644 /etc/xdg/autostart/zorin-vnc-xhost.desktop

# Clean up obsolete daemon files from previous iterations to prevent confusion
rm -f /usr/local/bin/zorin-x11vnc-daemon.sh 2>/dev/null || true
systemctl stop zorin-x11vnc-daemon.service 2>/dev/null || true
systemctl disable zorin-x11vnc-daemon.service 2>/dev/null || true
rm -f /etc/systemd/system/zorin-x11vnc-daemon.service 2>/dev/null || true

# Apply immediately to current desktop if logged in
su - "$TARGET_USER" -c "DISPLAY=:0 xhost +local:" 2>/dev/null || true
echo -e "\033[0;32m[✓ OK]\033[0m Đã kích hoạt hook tự động chạy VNC cho mọi User (Local & Domain AD):"
echo -e "         - /etc/X11/Xsession.d/99zorin-vnc-xauth"
echo -e "         - /etc/xdg/autostart/zorin-vnc-xhost.desktop"

# 9. Enable NetBIOS & LLMNR (so other PCs can ping this computer by hostname)
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
