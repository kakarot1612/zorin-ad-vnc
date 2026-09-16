#!/usr/bin/env bash
# ==============================================================================
# Zorin OS AD Join & X11VNC Management Tool
# File: lib/gdm_xorg.sh
# Description: Force GDM3 to use Xorg (X11) instead of Wayland for x11vnc compatibility.
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

configure_gdm_xorg() {
    check_root
    msg_step "CẤU HÌNH GDM3 ÉP SỬ DỤNG XORG (X11) THAY VÌ WAYLAND"

    local gdm_conf
    gdm_conf=$(find_gdm_conf)

    # Ensure parent dir exists
    mkdir -p "$(dirname "$gdm_conf")"

    if [[ -f "$gdm_conf" ]]; then
        backup_file "$gdm_conf" "gdm"
    else
        touch "$gdm_conf"
    fi

    msg_info "Đang cấu hình WaylandEnable=false trong ${gdm_conf}..."

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

    # Verify
    if grep -q -E "^WaylandEnable=false" "$gdm_conf"; then
        msg_ok "Đã cấu hình thành công: WaylandEnable=false"
    else
        msg_err "Cấu hình WaylandEnable không thành công. Hãy kiểm tra lại file ${gdm_conf}"
        return 1
    fi

    # Check current session type
    local current_type="${XDG_SESSION_TYPE:-unknown}"
    echo -e "Session type hiện tại của phiên đang chạy: ${C_YELLOW}${current_type}${C_RESET}"
    if [[ "$current_type" == "wayland" ]]; then
        msg_warn "Hệ thống hiện tại đang trong phiên Wayland. Cần khởi động lại máy để chuyển hẳn sang Xorg."
        if prompt_confirm "Bạn có muốn khởi động lại máy (Reboot) ngay bây giờ?" "N"; then
            msg_info "Đang khởi động lại hệ thống..."
            reboot
        fi
    elif [[ "$current_type" == "x11" ]]; then
        msg_ok "Hệ thống hiện tại ĐÃ ĐANG CHẠY X11/Xorg."
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
