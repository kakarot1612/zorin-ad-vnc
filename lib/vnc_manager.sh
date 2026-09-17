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
    chmod 600 "$VNC_PASSWD_FILE"
    chown "${target_user}:${target_user}" "$VNC_PASSWD_FILE" 2>/dev/null || true
    ln -sf "$VNC_PASSWD_FILE" /etc/x11vnc/vncpwd 2>/dev/null || true

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
    chown "${target_user}:${target_user}" "${target_home}/.Xauthority" 2>/dev/null || true
    chmod 600 "${target_home}/.Xauthority" 2>/dev/null || true

    # Merge active Xorg cookie if available
    if [[ -f "/run/user/${target_uid}/gdm/Xauthority" ]]; then
        xauth -f "${target_home}/.Xauthority" merge "/run/user/${target_uid}/gdm/Xauthority" 2>/dev/null || true
    fi
    for xf in /run/user/"${target_uid}"/xauth*; do
        if [[ -f "$xf" ]]; then
            xauth -f "${target_home}/.Xauthority" merge "$xf" 2>/dev/null || true
        fi
    done

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
Environment="XAUTHORITY=${target_home}/.Xauthority"
ExecStart=/usr/bin/x11vnc -display :0 -auth ${target_home}/.Xauthority -rfbauth ${VNC_PASSWD_FILE} -forever -shared -noxdamage -rfbport 5900
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

    # 7. Multi-user VNC hook: Allow x11vnc to capture screen for ANY user (Local or AD)
    mkdir -p /etc/X11/Xsession.d
    cat > /etc/X11/Xsession.d/99zorin-vnc-xauth <<'EOF'
# Grant local display access so x11vnc service can remote into any user's session
if [ -n "$DISPLAY" ]; then
    xhost +local: >/dev/null 2>&1 || true
fi
EOF
    chmod 644 /etc/X11/Xsession.d/99zorin-vnc-xauth
    su - "$target_user" -c "DISPLAY=:0 xhost +local:" 2>/dev/null || true
    msg_ok "Đã cài đặt hook đa người dùng: /etc/X11/Xsession.d/99zorin-vnc-xauth"

    msg_info "Bạn có thể kiểm tra trạng thái bằng: systemctl status x11vnc"

    return 0
}

show_vnc_status() {
    msg_step "TRẠNG THÁI DỊCH VỤ X11VNC VÀ KẾT NỐI DESKTOP"

    # 1. Systemd Service
    if systemctl is-active --quiet "${SYSTEMD_SERVICE}"; then
        msg_ok "Systemd Service [${SYSTEMD_SERVICE}]: ĐANG CHẠY [ACTIVE]"
    else
        msg_warn "Systemd Service [${SYSTEMD_SERVICE}]: ĐANG TẮT [INACTIVE]"
    fi

    # 2. Listening Port
    local port="5900"
    if [[ -f "${VNC_CONFIG_DIR}/zorin-vnc.conf" ]]; then
        port=$(grep "VNC_PORT=" "${VNC_CONFIG_DIR}/zorin-vnc.conf" | cut -d'"' -f2)
        port="${port:-5900}"
    fi

    local port_listen=""
    if command -v ss >/dev/null 2>&1; then
        port_listen=$(ss -tulpn | grep ":${port} " || true)
    elif command -v netstat >/dev/null 2>&1; then
        port_listen=$(netstat -tulpn 2>/dev/null | grep ":${port} " || true)
    fi

    if [[ -n "$port_listen" ]]; then
        msg_ok "Cổng VNC (TCP ${port}): ĐANG LẮNG NGHE [LISTENING]"
        echo -e "   ${C_DIM}${port_listen}${C_RESET}"
    else
        msg_warn "Cổng VNC (TCP ${port}): CHƯA MỞ (Có thể chưa có user nào đăng nhập GUI Xorg)"
    fi

    # 3. Active x11vnc process and owner
    local vnc_pids
    vnc_pids=$(pgrep -a x11vnc || true)
    if [[ -n "$vnc_pids" ]]; then
        msg_ok "Tiến trình x11vnc đang chạy:"
        echo -e "${C_CYAN}${vnc_pids}${C_RESET}"
        local running_user
        running_user=$(ps -o user= -p "$(pgrep x11vnc | head -n 1)" 2>/dev/null | tr -d ' ')
        echo -e "   Chạy dưới user: ${C_GREEN}${running_user}${C_RESET} (Đảm bảo đúng desktop của user)"
    else
        msg_info "Hiện tại không có tiến trình x11vnc nào đang chạy (Chờ user đăng nhập)."
    fi

    # 4. Password file
    if [[ -f "$VNC_PASSWD_FILE" ]]; then
        msg_ok "File mật khẩu VNC: ĐÃ THIẾT LẬP (${VNC_PASSWD_FILE})"
    else
        msg_warn "File mật khẩu VNC: CHƯA THIẾT LẬP! Khuyên bạn nên chạy chức năng đặt mật khẩu."
    fi
}
