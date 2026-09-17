#!/usr/bin/env bash
# ==============================================================================
# Zorin OS AD Join & X11VNC Management Tool
# File: lib/vnc_manager.sh
# Description: Manage x11vnc installation, secure password setup, and systemd service.
# ==============================================================================

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"

install_x11vnc() {
    msg_step "CÀI ĐẶT GÓI X11VNC"

    if command -v x11vnc >/dev/null 2>&1; then
        local ver
        ver=$(x11vnc -version 2>&1 | head -n 1)
        msg_ok "x11vnc đã được cài đặt: ${ver}"
        return 0
    fi

    msg_info "Đang cài đặt x11vnc qua apt..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq || true
    if apt-get install -y x11vnc; then
        msg_ok "Cài đặt x11vnc thành công!"
        return 0
    else
        msg_err "Cài đặt x11vnc thất bại!"
        return 1
    fi
}

setup_vnc_password() {
    check_root
    msg_step "THIẾT LẬP MẬT KHẨU KẾT NỐI VNC (BẢO MẬT)"

    if ! command -v x11vnc >/dev/null 2>&1; then
        install_x11vnc || return 1
    fi

    mkdir -p "$VNC_CONFIG_DIR"

    local vnc_pass=""
    echo -e "${C_CYAN}Mật khẩu VNC giới hạn tối đa 8 ký tự theo chuẩn RFB/x11vnc.${C_RESET}"
    prompt_secure_password "Nhập mật khẩu VNC mới" vnc_pass true

    # Store password securely with x11vnc
    local target_user="${VNC_USER:-${SUDO_USER:-$(logname 2>/dev/null || id -un 1000 2>/dev/null || whoami)}}"
    x11vnc -storepasswd "$vnc_pass" "$VNC_PASSWD_FILE" >/dev/null 2>&1
    chmod 755 "$VNC_CONFIG_DIR"
    chmod 644 "$VNC_PASSWD_FILE"
    ln -sf "$VNC_PASSWD_FILE" /etc/x11vnc/vncpwd 2>/dev/null || true
    chmod 644 /etc/x11vnc/vncpwd 2>/dev/null || true

    unset vnc_pass

    if [[ -f "$VNC_PASSWD_FILE" ]]; then
        msg_ok "Đã lưu mật khẩu VNC an toàn tại: ${VNC_PASSWD_FILE}"
        return 0
    else
        msg_err "Không thể tạo file mật khẩu VNC!"
        return 1
    fi
}

configure_vnc_settings() {
    check_root
    msg_step "CẤU HÌNH THÔNG SỐ VNC SERVICE"

    mkdir -p "$VNC_CONFIG_DIR"
    local conf_file="${VNC_CONFIG_DIR}/zorin-vnc.conf"

    local current_port="5900"
    if [[ -f "$conf_file" ]]; then
        # shellcheck source=/dev/null
        source "$conf_file" 2>/dev/null || true
    fi

    local new_port
    prompt_with_default "Cổng VNC (Port)" "${VNC_PORT:-5900}" new_port

    cat > "$conf_file" <<EOF
# Cấu hình Zorin X11VNC Service
VNC_PORT="${new_port}"
EOF
    chmod 644 "$conf_file"
    msg_ok "Đã cập nhật cấu hình tại: ${conf_file} (Port: ${new_port})"
}

install_vnc_systemd_service() {
    check_root
    msg_step "CÀI ĐẶT SYSTEMD SERVICE CHO X11VNC (PROVEN PRODUCTION SETUP)"

    # 1. Ensure x11vnc binary is installed
    if ! command -v x11vnc >/dev/null 2>&1; then
        install_x11vnc || return 1
    fi

    # 2. Detect primary user and home
    local target_user="${VNC_USER:-${SUDO_USER:-$(logname 2>/dev/null || id -un 1000 2>/dev/null || whoami)}}"
    local target_home
    target_home=$(getent passwd "$target_user" 2>/dev/null | cut -d: -f6)
    target_home="${target_home:-/home/$target_user}"
    local target_uid
    target_uid=$(id -u "$target_user" 2>/dev/null || echo 1000)

    # 3. Ensure VNC password file exists (/etc/x11vnc/passwd)
    mkdir -p "$VNC_CONFIG_DIR"
    chmod 755 "$VNC_CONFIG_DIR"
    if [[ ! -s "$VNC_PASSWD_FILE" ]]; then
        if [[ -s /etc/x11vnc/vncpwd ]]; then
            cp /etc/x11vnc/vncpwd "$VNC_PASSWD_FILE"
        else
            msg_info "Chưa có file mật khẩu VNC, tạo mật khẩu mặc định (123456)..."
            x11vnc -storepasswd "123456" "$VNC_PASSWD_FILE" >/dev/null 2>&1
            if [[ ! -s "$VNC_PASSWD_FILE" ]]; then
                printf "123456\n123456\n" | x11vnc -storepasswd "$VNC_PASSWD_FILE" >/dev/null 2>&1 || true
            fi
        fi
    fi
    chmod 600 "$VNC_PASSWD_FILE"
    chown -R "${target_user}:${target_user}" "$VNC_CONFIG_DIR" 2>/dev/null || true
    ln -sf "$VNC_PASSWD_FILE" /etc/x11vnc/vncpwd 2>/dev/null || true
    msg_ok "File mật khẩu VNC: ${VNC_PASSWD_FILE} (User: ${target_user})"

    # 4. Ensure Xauthority file exists and has correct permissions
    touch "${target_home}/.Xauthority" 2>/dev/null || true

    # Find active Xorg auth cookie from live session
    local auth_found=""
    local xorg_auth
    xorg_auth=$(ps -eo args 2>/dev/null | grep -E '[X]org' | grep -o -E -- '-auth[ =][^ ]+' | awk '{print $2}' | head -n 1)
    if [[ -n "$xorg_auth" && -f "$xorg_auth" ]]; then
        auth_found="$xorg_auth"
    fi

    if [[ -z "$auth_found" ]]; then
        local env_auth
        env_auth=$(grep -s -z -h '^XAUTHORITY=' /proc/[0-9]*/environ 2>/dev/null | tr '\0' '\n' | grep '^XAUTHORITY=' | head -n 1 | cut -d= -f2-)
        if [[ -n "$env_auth" && -f "$env_auth" ]]; then
            auth_found="$env_auth"
        fi
    fi

    if [[ -z "$auth_found" ]]; then
        for f in "/run/user/${target_uid}/gdm/Xauthority" "/run/user/${target_uid}/.Xauthority" /run/user/"${target_uid}"/xauth* /var/lib/gdm3/.Xauthority; do
            if [[ -f "$f" ]]; then
                auth_found="$f"
                break
            fi
        done
    fi

    if [[ -n "$auth_found" && -f "$auth_found" ]]; then
        cp -f "$auth_found" "${target_home}/.Xauthority" 2>/dev/null || true
        msg_ok "Đã đồng bộ cookie Xorg: ${auth_found} -> ${target_home}/.Xauthority"
    fi
    chown "${target_user}:${target_user}" "${target_home}/.Xauthority" 2>/dev/null || true
    chmod 600 "${target_home}/.Xauthority" 2>/dev/null || true

    # 5. Create systemd service unit matching proven working setup
    local unit_file="/etc/systemd/system/x11vnc.service"
    cat > "$unit_file" <<EOF
[Unit]
Description=x11vnc remote desktop
After=display-manager.service network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${target_user}
Environment="DISPLAY=:0"
Environment="DISPALY=:0"
Environment="XAUTHORITY=${target_home}/.Xauthority"
ExecStart=/usr/bin/x11vnc -display \${DISPALY} -auth \${XAUTHORITY} -rfbauth ${VNC_PASSWD_FILE} -forever -shared -noxdamage -noshm -rfbport 5900
Restart=on-failure
RestartSec=10

[Install]
WantedBy=graphical.target
Alias=zorin-x11vnc.service
EOF

    ln -sf "$unit_file" "/etc/systemd/system/${SYSTEMD_SERVICE}"

    systemctl daemon-reload
    systemctl enable x11vnc.service 2>/dev/null || true
    systemctl restart x11vnc.service 2>/dev/null || true
    msg_ok "Đã kích hoạt và khởi động dịch vụ: x11vnc.service (User: ${target_user})"

    # 7. Multi-user VNC hooks: Allow x11vnc to capture screen for ANY user (Local or AD)
    # Hook 1: Xsession.d (runs for all Xorg sessions upon login)
    mkdir -p /etc/X11/Xsession.d
    cat > /etc/X11/Xsession.d/99zorin-vnc-xauth <<'EOF'
# Grant local display access so x11vnc service can remote into any user's session
if [ -n "$DISPLAY" ]; then
    xhost +local: >/dev/null 2>&1 || true
fi
EOF
    chmod 644 /etc/X11/Xsession.d/99zorin-vnc-xauth

    # Hook 2: XDG Desktop Autostart (Tự động khởi chạy x11vnc cho bất kỳ user nào logon vào Desktop)
    mkdir -p /etc/xdg/autostart
    cat > /etc/xdg/autostart/zorin-x11vnc.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Zorin X11VNC Remote Desktop
Comment=Automatically launch x11vnc when user logs in
Exec=sh -c "xhost +local: 2>/dev/null; pkill -u $USER -x x11vnc 2>/dev/null; sleep 1; x11vnc -display :0 -forever -shared -rfbport 5900 -noxdamage -repeat -rfbauth /etc/x11vnc/vncpwd"
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF
    chmod 644 /etc/xdg/autostart/zorin-x11vnc.desktop
    chmod 755 /etc/x11vnc
    chmod 644 /etc/x11vnc/passwd /etc/x11vnc/vncpwd 2>/dev/null || true

    # Clean up obsolete daemon files from previous iterations to prevent confusion
    rm -f /usr/local/bin/zorin-x11vnc-daemon.sh 2>/dev/null || true
    systemctl stop zorin-x11vnc-daemon.service 2>/dev/null || true
    systemctl disable zorin-x11vnc-daemon.service 2>/dev/null || true
    rm -f /etc/systemd/system/zorin-x11vnc-daemon.service 2>/dev/null || true

    su - "$target_user" -c "DISPLAY=:0 XAUTHORITY='${target_home}/.Xauthority' xhost +local:" 2>/dev/null || true
    xhost +local: >/dev/null 2>&1 || true
    msg_ok "Đã kích hoạt tự động chạy VNC cho mọi User (Local & Domain AD khi Logon):"
    msg_info " - Hook 1: /etc/X11/Xsession.d/99zorin-vnc-xauth (Ủy quyền Xorg)"
    msg_info " - Hook 2: /etc/xdg/autostart/zorin-x11vnc.desktop (Chạy VNC khi bất kỳ User nào đăng nhập)"

    # 8. TỰ ĐỘNG KIỂM THỬ DỊCH VỤ & CỔNG MẠNG NGAY SAU KHI CÀI ĐẶT
    verify_vnc_service
    return $?
}

verify_vnc_service() {
    msg_step "KIỂM THỬ DỊCH VỤ X11VNC & KIỂM TRA CỔNG KẾT NỐI (PORT TEST)"
    
    local port="5900"
    if [[ -f "${VNC_CONFIG_DIR}/zorin-vnc.conf" ]]; then
        # shellcheck source=/dev/null
        source "${VNC_CONFIG_DIR}/zorin-vnc.conf" 2>/dev/null || true
        port="${VNC_PORT:-5900}"
    fi

    echo -e "${C_CYAN}Đang chờ dịch vụ x11vnc khởi động và gắn cổng ${port}...${C_RESET}"
    sleep 2

    # 1. Kiểm tra trạng thái service systemd
    local service_state
    service_state=$(systemctl is-active x11vnc.service 2>/dev/null || echo "unknown")

    if [[ "$service_state" == "active" ]]; then
        msg_ok "1. Trạng thái Service [x11vnc.service]: ĐANG CHẠY [ACTIVE]"
    else
        msg_err "1. Trạng thái Service [x11vnc.service]: THẤT BẠI [Trạng thái: ${service_state}]"
    fi

    # 2. Kiểm tra tiến trình x11vnc
    local pids
    pids=$(pgrep -d ' ' x11vnc 2>/dev/null || true)
    if [[ -n "$pids" ]]; then
        local run_user
        run_user=$(ps -o user= -p "$(echo "$pids" | awk '{print $1}')" 2>/dev/null | tr -d ' ')
        msg_ok "2. Tiến trình x11vnc (PID: ${pids}): ĐANG CHẠY (User: ${C_CYAN}${run_user}${C_RESET})"
    else
        msg_err "2. Tiến trình x11vnc: KHÔNG TÌM THẤY TRONG BỘ NHỚ"
    fi

    # 3. Kiểm thử cổng mạng TCP 5900 (Port test)
    local port_listen=""
    if command -v ss >/dev/null 2>&1; then
        port_listen=$(ss -tulpn 2>/dev/null | grep -E ":${port}\b" || true)
    elif command -v netstat >/dev/null 2>&1; then
        port_listen=$(netstat -tulpn 2>/dev/null | grep -E ":${port}\b" || true)
    fi

    if [[ -n "$port_listen" ]]; then
        msg_ok "3. Kiểm thử cổng mạng TCP ${port}: THÀNH CÔNG! CỔNG ĐÃ MỞ [LISTENING]"
        echo -e "   ${C_CYAN}Socket: ${port_listen}${C_RESET}"
        local local_ip
        local_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
        echo -e "\n${C_GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
        echo -e "${C_BOLD}${C_GREEN}✓ THIẾT LẬP VNC HOÀN TẤT VÀ KIỂM THỬ THÀNH CÔNG!${C_RESET}"
        echo -e "  Địa chỉ kết nối từ máy khác (VNC Viewer): ${C_BOLD}${C_WHITE}${local_ip}:${port}${C_RESET}"
        echo -e "${C_GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
        return 0
    else
        msg_err "3. Kiểm thử cổng mạng TCP ${port}: THẤT BẠI! CỔNG CHƯA MỞ."
        
        # Chẩn đoán nguyên nhân chuyên sâu
        echo -e "\n${C_BOLD}${C_YELLOW}=== CHẨN ĐOÁN NGUYÊN NHÂN LỖI & HƯỚNG XỬ LÝ ===${C_RESET}"
        
        # Kiểm tra Wayland
        local sess_type="${XDG_SESSION_TYPE:-unknown}"
        if [[ "$sess_type" == "wayland" ]]; then
            echo -e "${C_RED}[!] NGUYÊN NHÂN CHÍNH: Phiên đồ họa hiện tại đang là WAYLAND!${C_RESET}"
            echo -e "    x11vnc không thể hoạt động trên Wayland. Máy cần được reboot để chuyển sang Xorg."
            echo -e "    👉 Hãy gõ: ${C_BOLD}sudo reboot${C_RESET}"
        fi

        # Kiểm tra file password
        if [[ ! -s "$VNC_PASSWD_FILE" ]]; then
            echo -e "${C_RED}[!] File mật khẩu VNC chưa tồn tại hoặc bị rỗng: ${VNC_PASSWD_FILE}${C_RESET}"
            echo -e "    👉 Hãy chọn mục [8] trong menu để đặt mật khẩu VNC."
        else
            echo -e "${C_GREEN}[✓] File mật khẩu VNC đã có: ${VNC_PASSWD_FILE}${C_RESET}"
        fi

        # In 15 dòng nhật ký lỗi từ systemd journalctl
        echo -e "\n${C_BOLD}${C_RED}=== CHI TIẾT LOG LỖI DỊCH VỤ (journalctl -u x11vnc) ===${C_RESET}"
        journalctl -u x11vnc -n 15 --no-pager 2>/dev/null || true
        echo -e "${C_BOLD}${C_RED}======================================================${C_RESET}\n"
        return 1
    fi
}

show_vnc_status() {
    verify_vnc_service
}
