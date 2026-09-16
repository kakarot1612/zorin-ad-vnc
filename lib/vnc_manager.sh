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
    x11vnc -storepasswd "$vnc_pass" "$VNC_PASSWD_FILE" >/dev/null 2>&1
    chmod 644 "$VNC_PASSWD_FILE"
    chown root:root "$VNC_PASSWD_FILE"

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
POLL_INTERVAL=3
EOF
    chmod 644 "$conf_file"
    msg_ok "Đã cập nhật cấu hình tại: ${conf_file} (Port: ${new_port})"
}

install_vnc_systemd_service() {
    check_root
    msg_step "CÀI ĐẶT SYSTEMD SERVICE CHO DYNAMIC X11VNC"

    # 1. Ensure x11vnc binary is installed
    if ! command -v x11vnc >/dev/null 2>&1; then
        install_x11vnc || return 1
    fi

    # 2. Ensure VNC password file exists (generate default 123456 if missing)
    mkdir -p "$VNC_CONFIG_DIR"
    if [[ ! -f "$VNC_PASSWD_FILE" ]]; then
        msg_info "Chưa có file mật khẩu VNC, tạo mật khẩu mặc định (123456)..."
        x11vnc -storepasswd "123456" "$VNC_PASSWD_FILE" >/dev/null 2>&1
        chmod 644 "$VNC_PASSWD_FILE"
        chown root:root "$VNC_PASSWD_FILE"
        msg_ok "Đã tạo mật khẩu VNC mặc định tại: ${VNC_PASSWD_FILE} (Mật khẩu: 123456)"
    fi

    # 3. Copy daemon script to /usr/local/bin
    local src_daemon="${LIB_DIR}/x11vnc_session_daemon.sh"
    if [[ -f "$src_daemon" ]]; then
        cp "$src_daemon" "$DAEMON_SCRIPT"
        chmod +x "$DAEMON_SCRIPT"
        msg_ok "Đã cài đặt daemon script vào: ${DAEMON_SCRIPT}"
    else
        msg_err "Không tìm thấy file nguồn: ${src_daemon}"
        return 1
    fi

    # 4. Create systemd service unit with Alias=x11vnc.service
    local unit_file="/etc/systemd/system/${SYSTEMD_SERVICE}"
    cat > "$unit_file" <<EOF
[Unit]
Description=Zorin OS Dynamic X11VNC Session Daemon
Documentation=https://github.com/kakarot1612/zorin-ad-vnc
After=network.target gdm.service sssd.service
Wants=gdm.service

[Service]
Type=simple
ExecStart=${DAEMON_SCRIPT}
Restart=always
RestartSec=5
KillMode=process
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
Alias=x11vnc.service
EOF

    # 5. Create direct symlink for x11vnc.service so 'systemctl status x11vnc' works directly
    ln -sf "$unit_file" /etc/systemd/system/x11vnc.service

    systemctl daemon-reload
    systemctl enable "${SYSTEMD_SERVICE}" 2>/dev/null || true
    systemctl enable x11vnc.service 2>/dev/null || true
    systemctl restart "${SYSTEMD_SERVICE}"
    msg_ok "Đã kích hoạt và khởi động dịch vụ: ${SYSTEMD_SERVICE} (Alias: x11vnc.service)"
    msg_info "Bạn có thể kiểm tra trạng thái bằng cả: systemctl status x11vnc hoặc systemctl status zorin-x11vnc"

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
