#!/usr/bin/env bash
# ==============================================================================
# Zorin OS AD Join & X11VNC Management Tool
# File: lib/sssd_config.sh
# Description: Backup, tune, and configure SSSD and AD GPO Access Control.
# ==============================================================================

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/backup_rollback.sh
source "$LIB_DIR/backup_rollback.sh"

SSSD_CONF="/etc/sssd/sssd.conf"

configure_sssd() {
    check_root
    msg_step "CẤU HÌNH DỊCH VỤ SSSD (SYSTEM SECURITY SERVICES DAEMON)"

    if [[ ! -f "$SSSD_CONF" ]]; then
        msg_warn "Không tìm thấy file $SSSD_CONF. Có thể máy chưa join AD qua realm."
        if ! prompt_confirm "Bạn có muốn tạo mới file $SSSD_CONF?" "Y"; then
            return 1
        fi
    fi

    # Backup existing configuration
    if [[ -f "$SSSD_CONF" ]]; then
        backup_file "$SSSD_CONF" "sssd"
    fi

    # Determine Domain Name
    local domain
    local current_realm
    current_realm=$(realm list 2>/dev/null | grep -E '^domain-name:' | awk '{print $2}' | head -n 1)
    prompt_with_default "Tên Active Directory Domain" "${current_realm:-bestpacific.com}" domain

    # GPO Mode option
    echo ""
    echo -e "${C_BOLD}Chọn chế độ AD GPO Access Control:${C_RESET}"
    echo "  1) Enforcing  (Khuyên dùng - Tuân thủ chính sách bảo mật AD GPO)"
    echo "  2) Permissive (Troubleshooting - Bỏ qua chặn GPO nếu gặp lỗi PAM service)"
    local gpo_choice
    prompt_with_default "Lựa chọn [1-2]" "1" gpo_choice

    local gpo_setting="ad_gpo_access_control = enforcing"
    if [[ "$gpo_choice" == "2" ]]; then
        gpo_setting="ad_gpo_access_control = permissive"
        msg_warn "Đang thiết lập GPO ở chế độ Permissive (Troubleshooting mode)."
    else
        msg_info "Đang thiết lập GPO ở chế độ Enforcing (Standard mode)."
    fi

    # Check if domain section exists or build a clean configuration
    msg_info "Đang cập nhật cấu hình vào ${SSSD_CONF}..."
    
    cat > "$SSSD_CONF" <<EOF
[sssd]
services = nss, pam, ssh
config_file_version = 2
domains = ${domain}

[domain/${domain}]
id_provider = ad
access_provider = ad
auth_provider = ad
chpass_provider = ad

# Tùy chọn Home Directory và tên người dùng ngắn
fallback_homedir = /home/%u@%d
use_fully_qualified_names = False

# GPO Access Control
${gpo_setting}

# Cache & Performance
cache_credentials = True
krb5_store_password_if_offline = True
default_shell = /bin/bash
ldap_id_mapping = True
EOF

    # Set strict permissions (SSSD will fail to start if not 0600)
    chmod 600 "$SSSD_CONF"
    chown root:root "$SSSD_CONF"
    msg_ok "Đã phân quyền an toàn 0600 cho ${SSSD_CONF}"

    # Clear SSSD cache and restart service
    msg_info "Đang xóa SSSD cache và khởi động lại dịch vụ SSSD..."
    if command -v sss_cache >/dev/null 2>&1; then
        sss_cache -E 2>/dev/null || true
    fi
    systemctl restart sssd

    if systemctl is-active --quiet sssd; then
        msg_ok "Dịch vụ SSSD đang hoạt động [ACTIVE RUNNING]."
    else
        msg_err "Dịch vụ SSSD khởi động thất bại. Kiểm tra journalctl -u sssd.service."
        return "$ERR_SSSD"
    fi

    # Check domain status
    if command -v sssctl >/dev/null 2>&1; then
        echo -e "\n${C_BOLD}Trạng thái domain từ sssctl:${C_RESET}"
        sssctl domain-status "$domain" 2>/dev/null || true
    fi

    return 0
}

toggle_gpo_mode() {
    check_root
    msg_step "THAY ĐỔI CHẾ ĐỘ AD GPO ACCESS CONTROL (ENFORCING / PERMISSIVE)"

    if [[ ! -f "$SSSD_CONF" ]]; then
        msg_err "Không tìm thấy file $SSSD_CONF!"
        return 1
    fi

    backup_file "$SSSD_CONF" "sssd-gpo-toggle"

    local current_mode="Không xác định (mặc định enforcing)"
    if grep -q "ad_gpo_access_control = permissive" "$SSSD_CONF"; then
        current_mode="Permissive"
    elif grep -q "ad_gpo_access_control = enforcing" "$SSSD_CONF"; then
        current_mode="Enforcing"
    fi

    echo -e "Chế độ hiện tại: ${C_CYAN}${current_mode}${C_RESET}"
    echo "1) Thiết lập ENFORCING"
    echo "2) Thiết lập PERMISSIVE"
    local choice
    prompt_with_default "Chọn chế độ mới [1/2]" "1" choice

    if [[ "$choice" == "2" ]]; then
        if grep -q "ad_gpo_access_control" "$SSSD_CONF"; then
            sed -i 's/ad_gpo_access_control.*/ad_gpo_access_control = permissive/' "$SSSD_CONF"
        else
            sed -i '/\[domain\/.*\]/a ad_gpo_access_control = permissive' "$SSSD_CONF"
        fi
        msg_ok "Đã chuyển GPO sang: PERMISSIVE"
    else
        if grep -q "ad_gpo_access_control" "$SSSD_CONF"; then
            sed -i 's/ad_gpo_access_control.*/ad_gpo_access_control = enforcing/' "$SSSD_CONF"
        else
            sed -i '/\[domain\/.*\]/a ad_gpo_access_control = enforcing' "$SSSD_CONF"
        fi
        msg_ok "Đã chuyển GPO sang: ENFORCING"
    fi

    chmod 600 "$SSSD_CONF"
    systemctl restart sssd
    msg_ok "Dịch vụ SSSD đã được khởi động lại."
}
