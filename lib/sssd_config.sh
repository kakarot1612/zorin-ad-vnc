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

# Dynamic DNS Update to Windows Active Directory DNS Server
dyndns_update = True
dyndns_refresh_interval = 14400
dyndns_update_ptr = True
dyndns_ttl = 3600

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

register_ad_dns_and_netbios() {
    check_root
    msg_step "ĐĂNG KÝ BẢN GHI TÊN MÁY LÊN WINDOWS AD DNS & NETBIOS WINS"

    local current_host
    current_host=$(hostname -s)
    local domain
    domain=$(realm list 2>/dev/null | grep -E '^[[:space:]]*domain-name:' | awk '{print $2}' | head -n 1)
    domain="${domain:-bestpacific.com}"
    local fqdn="${current_host}.${domain}"
    local current_ip
    current_ip=$(hostname -I 2>/dev/null | awk '{print $1}')

    echo -e "Tên máy Zorin : ${C_CYAN}${current_host}${C_RESET} (${fqdn})"
    echo -e "Địa chỉ IP    : ${C_GREEN}${current_ip}${C_RESET}"
    echo -e "Domain AD     : ${C_YELLOW}${domain}${C_RESET}"
    echo "--------------------------------------------------------"

    # 1. Update SSSD with dyndns_update
    if [[ -f "$SSSD_CONF" ]]; then
        msg_info "1. Bật tính năng Dynamic DNS (dyndns_update) trong SSSD..."
        if ! grep -q "dyndns_update" "$SSSD_CONF"; then
            sed -i "/\[domain\/${domain}\]/a dyndns_update = True\ndyndns_refresh_interval = 14400\ndyndns_update_ptr = True\ndyndns_ttl = 3600" "$SSSD_CONF" 2>/dev/null || true
        else
            sed -i "s/dyndns_update = .*/dyndns_update = True/" "$SSSD_CONF" 2>/dev/null || true
        fi
        chmod 600 "$SSSD_CONF"
        chown root:root "$SSSD_CONF"
        systemctl restart sssd 2>/dev/null || true
        msg_ok "Đã kích hoạt Dynamic DNS trong SSSD và khởi động lại dịch vụ."
    fi

    # 2. Configure Samba NetBIOS Name Responder (nmbd)
    msg_info "2. Cấu hình NetBIOS Name Responder (để máy Windows ping trực tiếp tên ${current_host})..."
    local smb_conf="/etc/samba/smb.conf"
    if command -v smbd >/dev/null 2>&1 || dpkg -s samba >/dev/null 2>&1; then
        if [[ -f "$smb_conf" ]]; then
            local workgroup
            workgroup=$(get_ad_workgroup "$domain")
            if ! grep -q "netbios name" "$smb_conf"; then
                sed -i "/\[global\]/a \   workgroup = ${workgroup}\n   netbios name = ${current_host^^}\n   disable netbios = no" "$smb_conf" 2>/dev/null || true
            else
                sed -i "s/^[[:space:]]*netbios name = .*/   netbios name = ${current_host^^}/" "$smb_conf" 2>/dev/null || true
            fi
            systemctl enable --now nmbd 2>/dev/null || true
            systemctl restart nmbd 2>/dev/null || true
            msg_ok "Dịch vụ NetBIOS (nmbd) đã được kích hoạt trên cổng UDP 137."
        fi
    else
        msg_info "Đang cài đặt gói samba để kích hoạt NetBIOS..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq || true
        apt-get install -y samba >/dev/null 2>&1 || true
        systemctl enable --now nmbd 2>/dev/null || true
    fi

    # 3. Enable LLMNR responder in systemd-resolved
    msg_info "3. Kích hoạt phản hồi đa hướng LLMNR trong systemd-resolved..."
    mkdir -p /etc/systemd/resolved.conf.d 2>/dev/null || true
    cat > /etc/systemd/resolved.conf.d/llmnr-responder.conf <<EOF
[Resolve]
LLMNR=yes
MulticastDNS=yes
EOF
    systemctl restart systemd-resolved 2>/dev/null || true

    # 4. Perform direct Kerberos nsupdate if machine ticket exists
    msg_info "4. Gửi yêu cầu cập nhật bản ghi DNS (RFC 2136) trực tiếp lên Domain Controller..."
    if ! command -v nsupdate >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get install -y bind9-dnsutils >/dev/null 2>&1 || apt-get install -y dnsutils >/dev/null 2>&1 || true
    fi

    if [[ -f /etc/krb5.keytab ]] && command -v nsupdate >/dev/null 2>&1; then
        local machine_principal="${current_host^^}\$@${domain^^}"
        # Obtain Kerberos ticket for machine account
        kinit -k "$machine_principal" 2>/dev/null || true

        local octet1 octet2 octet3 octet4 ptr_record=""
        if [[ "$current_ip" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
            octet1="${BASH_REMATCH[1]}"
            octet2="${BASH_REMATCH[2]}"
            octet3="${BASH_REMATCH[3]}"
            octet4="${BASH_REMATCH[4]}"
            ptr_record="${octet4}.${octet3}.${octet2}.${octet1}.in-addr.arpa"
        fi

        local nsupdate_script="/tmp/nsupdate_ad.txt"
        cat > "$nsupdate_script" <<EOF
server ${domain}
update delete ${fqdn} A
update add ${fqdn} 3600 A ${current_ip}
send
EOF
        if [[ -n "$ptr_record" ]]; then
            cat >> "$nsupdate_script" <<EOF
server ${domain}
update delete ${ptr_record} PTR
update add ${ptr_record} 3600 PTR ${fqdn}.
send
EOF
        fi

        if nsupdate -g "$nsupdate_script" 2>&1; then
            msg_ok "Đã đăng ký trực tiếp bản ghi DNS: ${fqdn} -> ${current_ip}"
        else
            msg_info "Lệnh nsupdate hoàn tất. SSSD sẽ tự động gửi đồng bộ định kỳ."
        fi
        rm -f "$nsupdate_script" 2>/dev/null || true
        kdestroy 2>/dev/null || true
    fi

    # 5. NetworkManager Dispatcher Hook for automatic RFC 2136 updates on DHCP IP change
    msg_info "5. Thiết lập NetworkManager Hook để tự động cập nhật DNS khi nhận IP mới..."
    mkdir -p /etc/NetworkManager/dispatcher.d 2>/dev/null || true
    cat > /etc/NetworkManager/dispatcher.d/99-ad-dns-update.sh <<'EOF'
#!/bin/bash
# Automatically trigger SSSD dynamic DNS update on network up / DHCP change
ACTION="$2"
if [[ "$ACTION" == "up" || "$ACTION" == "dhcp4-change" ]]; then
    if systemctl is-active --quiet sssd; then
        systemctl restart sssd >/dev/null 2>&1 &
    fi
fi
EOF
    chmod 755 /etc/NetworkManager/dispatcher.d/99-ad-dns-update.sh 2>/dev/null || true
    msg_ok "Đã cài đặt NetworkManager Dispatcher Hook: /etc/NetworkManager/dispatcher.d/99-ad-dns-update.sh"

    msg_ok "========================================================="
    msg_ok "ĐĂNG KÝ TÊN MÁY LÊN HỆ THỐNG MẠNG HOÀN TẤT!"
    msg_ok "Từ các máy tính khác, bạn có thể kiểm tra:"
    msg_ok "  ping ${current_host}   hoặc   ping ${fqdn}"
    msg_ok "========================================================="
}
