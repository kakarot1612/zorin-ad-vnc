#!/usr/bin/env bash
# ==============================================================================
# Zorin OS AD Join & X11VNC Management Tool
# File: lib/gdm_xorg.sh
# Description: Force ALL Users (AD & Local) to Use Xorg (X11) Exclusively,
#              Disabling Wayland Completely for Full VNC & Remote Desktop Support.
# ==============================================================================

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/backup_rollback.sh
source "$LIB_DIR/backup_rollback.sh"

find_gdm_conf() {
    if [[ -f "/etc/gdm3/custom.conf" ]]; then
        echo "/etc/gdm3/custom.conf"
    elif [[ -f "/etc/gdm/custom.conf" ]]; then
        echo "/etc/gdm/custom.conf"
    else
        echo "/etc/gdm3/custom.conf"
    fi
}

disable_wayland_sessions_globally() {
    # 1. Disable /usr/share/wayland-sessions so GDM cannot offer Wayland
    if [[ -d "/usr/share/wayland-sessions" ]]; then
        local wayland_files
        wayland_files=$(find /usr/share/wayland-sessions -maxdepth 1 -name "*.desktop" 2>/dev/null || true)
        if [[ -n "$wayland_files" ]]; then
            msg_info "Đang vô hiệu hóa các phiên Wayland trong /usr/share/wayland-sessions/..."
            mkdir -p /usr/share/wayland-sessions.disabled
            for wf in /usr/share/wayland-sessions/*.desktop; do
                [[ -f "$wf" ]] || continue
                mv -f "$wf" /usr/share/wayland-sessions.disabled/ 2>/dev/null || true
            done
            msg_ok "Đã chuyển toàn bộ Wayland sessions vào thư mục cách ly: /usr/share/wayland-sessions.disabled/"
        fi
    fi

    # 2. Reset any cached user sessions in AccountsService to Xorg
    if [[ -d "/var/lib/AccountsService/users" ]]; then
        msg_info "Đang chuẩn hóa phiên đăng nhập của tất cả tài khoản về Xorg..."
        local default_xsess="zorin"
        if [[ -f "/usr/share/xsessions/zorin.desktop" ]]; then
            default_xsess="zorin"
        elif [[ -f "/usr/share/xsessions/zorin-xorg.desktop" ]]; then
            default_xsess="zorin-xorg"
        elif [[ -f "/usr/share/xsessions/ubuntu.desktop" ]]; then
            default_xsess="ubuntu"
        elif [[ -f "/usr/share/xsessions/ubuntu-xorg.desktop" ]]; then
            default_xsess="ubuntu-xorg"
        elif [[ -f "/usr/share/xsessions/gnome-xorg.desktop" ]]; then
            default_xsess="gnome-xorg"
        fi

        for user_acc in /var/lib/AccountsService/users/*; do
            [[ -f "$user_acc" ]] || continue
            if grep -q -i "wayland" "$user_acc" 2>/dev/null; then
                sed -i -E "s/XSession=.*wayland.*/XSession=${default_xsess}/I" "$user_acc" 2>/dev/null || true
            fi
        done
    fi
}

configure_gdm_xorg() {
    check_root
    msg_step "CẤU HÌNH HỆ THỐNG ÉP TOÀN BỘ NGƯỜI DÙNG CHỈ SỬ DỤNG XORG (X11)"

    local gdm_conf
    gdm_conf=$(find_gdm_conf)

    # Ensure parent dir exists
    mkdir -p "$(dirname "$gdm_conf")"

    if [[ -f "$gdm_conf" ]]; then
        backup_file "$gdm_conf" "gdm"
    else
        touch "$gdm_conf"
    fi

    msg_info "1. Đang cấu hình WaylandEnable=false trong ${gdm_conf}..."

    # Check if [daemon] section exists
    if ! grep -q "\[daemon\]" "$gdm_conf"; then
        cat >> "$gdm_conf" <<EOF

[daemon]
WaylandEnable=false
EOF
    else
        # If WaylandEnable exists (commented or uncommented), update it
        if grep -q -E "^#?[[:space:]]*WaylandEnable=" "$gdm_conf"; then
            sed -i -E 's/^#?[[:space:]]*WaylandEnable=.*/WaylandEnable=false/' "$gdm_conf"
        else
            # Insert under [daemon]
            sed -i '/\[daemon\]/a WaylandEnable=false' "$gdm_conf"
        fi
    fi

    # Verify GDM WaylandEnable=false
    if grep -q -E "^WaylandEnable=false" "$gdm_conf"; then
        msg_ok "Đã cấu hình thành công GDM: WaylandEnable=false"
    else
        msg_err "Cấu hình WaylandEnable không thành công. Hãy kiểm tra lại file ${gdm_conf}"
        return 1
    fi

    # 2. Disable all Wayland sessions system-wide
    msg_info "2. Vô hiệu hóa triệt để mọi phiên Wayland trên hệ điều hành..."
    disable_wayland_sessions_globally

    # 3. Configure system environment default
    msg_info "3. Cấu hình biến môi trường toàn hệ thống ép phiên X11..."
    cat > /etc/profile.d/zorin-xorg-session.sh <<'EOF'
# Force X11 Session Type indicator
if [[ -z "$XDG_SESSION_TYPE" || "$XDG_SESSION_TYPE" == "wayland" ]]; then
    export XDG_SESSION_TYPE=x11
fi
EOF
    chmod 644 /etc/profile.d/zorin-xorg-session.sh

    msg_ok "========================================================="
    msg_ok "ĐÃ THIẾT LẬP THÀNH CÔNG: TẤT CẢ USER CHỈ SỬ DỤNG XORG (X11)!"
    msg_ok "Wayland đã bị vô hiệu hóa hoàn toàn trên toàn bộ hệ điều hành."
    msg_ok "========================================================="

    # Check current session type
    local current_type="${XDG_SESSION_TYPE:-unknown}"
    echo -e "Trạng thái phiên hiện tại: ${C_YELLOW}${current_type}${C_RESET}"
    if [[ "$current_type" == "wayland" ]]; then
        msg_warn "Phiên hiện tại đang là Wayland. Cần KHỞI ĐỘNG LẠI MÁY (Reboot) để chuyển hoàn toàn sang Xorg."
        if prompt_confirm "Bạn có muốn khởi động lại máy (Reboot) ngay bây giờ?" "N"; then
            msg_info "Đang khởi động lại hệ thống..."
            reboot
        fi
    else
        msg_ok "Hệ thống đang hoạt động trên nền tảng Xorg (X11)."
    fi

    return 0
}

check_xorg_status() {
    msg_step "KIỂM TRA TRẠNG THÁI XORG / WAYLAND TRÊN HỆ THỐNG"

    local gdm_conf
    gdm_conf=$(find_gdm_conf)
    echo -e "File cấu hình GDM: ${C_CYAN}${gdm_conf}${C_RESET}"

    if [[ -f "$gdm_conf" ]] && grep -q -E "^WaylandEnable=false" "$gdm_conf"; then
        msg_ok "Cấu hình GDM: WaylandEnable=false (ĐÃ BẬT ÉP XORG)"
    else
        msg_warn "Cấu hình GDM: Chưa có hoặc chưa tắt Wayland (WaylandEnable=false chưa thiết lập)!"
    fi

    if [[ -d "/usr/share/wayland-sessions.disabled" ]]; then
        msg_ok "Các phiên Wayland toàn hệ thống: ĐÃ BỊ VÔ HIỆU HÓA HOÀN TOÀN"
    elif [[ -d "/usr/share/wayland-sessions" ]] && ls /usr/share/wayland-sessions/*.desktop >/dev/null 2>&1; then
        msg_warn "Các phiên Wayland toàn hệ thống: VẪN CÒN TỒN TẠI TRONG /usr/share/wayland-sessions"
    else
        msg_ok "Các phiên Wayland toàn hệ thống: KHÔNG CÓ"
    fi

    local current_type="${XDG_SESSION_TYPE:-chưa xác định}"
    echo -e "Biến môi trường XDG_SESSION_TYPE: ${C_CYAN}${current_type}${C_RESET}"

    # Check active sessions via loginctl
    if command -v loginctl >/dev/null 2>&1; then
        echo -e "\n${C_BOLD}Danh sách sessions từ loginctl:${C_RESET}"
        loginctl list-sessions --no-legend 2>/dev/null | while read -r sess_id uid user seat tty state; do
            local sess_type
            sess_type=$(loginctl show-session "$sess_id" -p Type --value 2>/dev/null || echo "n/a")
            echo -e "  - Session ${C_WHITE}${sess_id}${C_RESET}: User=${C_CYAN}${user}${C_RESET} Seat=${seat} State=${state} Type=${C_GREEN}${sess_type}${C_RESET}"
        done
    fi

    # Check Xorg processes
    local xorg_procs
    xorg_procs=$(pgrep -a Xorg || true)
    if [[ -n "$xorg_procs" ]]; then
        msg_ok "Tiến trình Xorg đang chạy:"
        echo -e "${C_DIM}${xorg_procs}${C_RESET}"
    else
        msg_warn "Không tìm thấy tiến trình Xorg nào đang chạy."
    fi
}
