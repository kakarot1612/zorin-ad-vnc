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

    # Determine Domain Name and DC IPs
    local domain=""
    local dc1=""
    local dc2=""
    if [[ -f /etc/zorin-ad-vnc/ad_dc.conf ]]; then
        # shellcheck disable=SC1091
        source /etc/zorin-ad-vnc/ad_dc.conf
        domain="${DOMAIN}"
        dc1="${DC1}"
        dc2="${DC2}"
    fi

    local current_realm
    current_realm=$(realm list 2>/dev/null | grep -E '^[[:space:]]*domain-name:' | awk '{print $2}' | head -n 1)
    local default_domain="${domain:-${current_realm}}"
    prompt_with_default "Tên Active Directory Domain" "$default_domain" domain
    while [[ -z "$domain" ]]; do
        prompt_with_default "Tên Active Directory Domain" "" domain
        domain=$(echo "$domain" | tr -d '[:space:]')
    done

    prompt_with_default "IP Domain Controller chính (Site cục bộ)" "$dc1" dc1
    while [[ -z "$dc1" ]]; do
        prompt_with_default "IP Domain Controller chính (Site cục bộ)" "" dc1
        dc1=$(echo "$dc1" | tr -d '[:space:]')
    done

    prompt_with_default "IP Domain Controller phụ (Site cục bộ - Enter để bỏ qua)" "$dc2" dc2
    dc2=$(echo "$dc2" | tr -d '[:space:]')

    # Determine Domain Controller FQDN / DNS SRV Auto-Discovery
    # IMPORTANT: Never put raw IP addresses in ad_server, because Kerberos SPN requires FQDN!
    # Using raw IP causes Kerberos ticket mismatch and puts SSSD into 'Offline' mode.
    local ad_servers="_srv_"
    local dc1_fqdn=""
    if [[ -n "$dc1" ]]; then
        if command -v dig >/dev/null 2>&1; then
            dc1_fqdn=$(dig -x "$dc1" +short 2>/dev/null | sed 's/\.$//' | head -n 1)
        fi
        if [[ -z "$dc1_fqdn" ]] && command -v getent >/dev/null 2>&1; then
            dc1_fqdn=$(getent hosts "$dc1" 2>/dev/null | awk '{print $2}' | head -n 1)
        fi
    fi

    if [[ -n "$dc1_fqdn" && "$dc1_fqdn" != "$dc1" ]]; then
        ad_servers="${dc1_fqdn}, _srv_"
        msg_ok "Đã phân giải FQDN cho Domain Controller: ${dc1_fqdn}"
    else
        ad_servers="_srv_"
        msg_info "Sử dụng cơ chế tự động tìm kiếm DC qua AD DNS SRV (ad_server = _srv_)"
    fi

    # GPO Mode option (Default to Permissive for Linux workstations in AD)
    echo ""
    echo -e "${C_BOLD}Chọn chế độ AD GPO Access Control:${C_RESET}"
    echo "  1) Permissive (Khuyên dùng cho Linux - Bỏ qua chặn GPO Windows ở bước pam_acct_mgmt)"
    echo "  2) Enforcing  (Chỉ dùng nếu Windows DC đã thiết lập GPO riêng cho Linux)"
    local gpo_choice
    prompt_with_default "Lựa chọn [1-2]" "1" gpo_choice

    local gpo_setting="ad_gpo_access_control = permissive"
    if [[ "$gpo_choice" == "2" ]]; then
        gpo_setting="ad_gpo_access_control = enforcing"
        msg_warn "Đang thiết lập GPO ở chế độ Enforcing (Có thể bị chặn đăng nhập GUI nếu GPO không có quyền)."
    else
        msg_ok "Đang thiết lập GPO ở chế độ Permissive (Cho phép AD user đăng nhập bình thường)."
    fi

    # Check if domain section exists or build a clean configuration matching proven working setup
    msg_info "Đang cập nhật cấu hình vào ${SSSD_CONF} (Chuẩn hệ thống doanh nghiệp AD)..."
    
    cat > "$SSSD_CONF" <<EOF
[sssd]
domains = ${domain}
config_file_version = 2
services = nss, pam

[domain/${domain}]
dyndns_update = True
dyndns_refresh_interval = 14400
dyndns_update_ptr = True
dyndns_ttl = 3600
${gpo_setting}
default_shell = /bin/bash
krb5_store_password_if_offline = True
cache_credentials = True
krb5_realm = ${domain^^}
realmd_tags = manages-system joined-with-adcli
id_provider = ad
fallback_homedir = /home/%u@%d
ad_domain = ${domain}
use_fully_qualified_names = False
ldap_id_mapping = True
access_provider = ad
EOF

    # Set strict permissions (SSSD will fail to start if not 0600)
    chmod 600 "$SSSD_CONF"
    chown root:root "$SSSD_CONF"
    msg_ok "Đã phân quyền an toàn 0600 cho ${SSSD_CONF}"

    # Đảm bảo /etc/nsswitch.conf có sss
    if [[ -f /etc/nsswitch.conf ]]; then
        for db in passwd group shadow; do
            if ! grep -E "^${db}:.*sss" /etc/nsswitch.conf >/dev/null 2>&1; then
                sed -i "/^${db}:/ s/$/ sss/" /etc/nsswitch.conf 2>/dev/null || true
            fi
        done
        msg_ok "Đã đảm bảo /etc/nsswitch.conf kích hoạt phân giải SSSD."
    fi

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

set_gpo_permissive() {
    check_root
    msg_step "THIẾT LẬP AD GPO ACCESS CONTROL = PERMISSIVE (SỬA LỖI ĐĂNG NHẬP AD)"

    if [[ ! -f "$SSSD_CONF" ]]; then
        msg_err "Không tìm thấy file $SSSD_CONF! Máy chưa cấu hình SSSD."
        return 1
    fi

    backup_file "$SSSD_CONF" "sssd-gpo-permissive"

    # 1. Bật GPO Permissive để tránh bị GPO chặn pam_acct_mgmt
    if grep -q "ad_gpo_access_control" "$SSSD_CONF"; then
        sed -i 's/^[[:space:]]*ad_gpo_access_control[[:space:]]*=.*/ad_gpo_access_control = permissive/' "$SSSD_CONF"
    else
        sed -i '/\[domain\/.*\]/a ad_gpo_access_control = permissive' "$SSSD_CONF"
    fi

    # 2. Khắc phục lỗi SSSD Offline: Xóa bỏ hoàn toàn các dòng ad_server và dyndns_server gán IP thô
    # Để SSSD dùng cơ chế DNS Service Discovery chuẩn Active Directory như máy mẫu
    sed -i '/^[[:space:]]*ad_server[[:space:]]*=/d' "$SSSD_CONF"
    sed -i '/^[[:space:]]*dyndns_server[[:space:]]*=/d' "$SSSD_CONF"
    sed -i 's/services = nss, pam, ssh/services = nss, pam/' "$SSSD_CONF" 2>/dev/null || true

    chmod 600 "$SSSD_CONF"
    chown root:root "$SSSD_CONF"

    msg_info "Đang xóa SSSD cache và khởi động lại dịch vụ SSSD..."
    if command -v sss_cache >/dev/null 2>&1; then
        sss_cache -E 2>/dev/null || true
    fi
    systemctl restart sssd
    sleep 2

    if systemctl is-active --quiet sssd; then
        msg_ok "Đã cấu hình thành công: ad_gpo_access_control = permissive"
        msg_ok "Dịch vụ SSSD đang hoạt động [ACTIVE]."
        
        # In trạng thái domain status sau khi sửa
        local current_domain
        current_domain=$(grep -E '^[[:space:]]*domains[[:space:]]*=' "$SSSD_CONF" | head -n 1 | cut -d= -f2- | tr -d '[:space:]')
        if [[ -n "$current_domain" ]] && command -v sssctl >/dev/null 2>&1; then
            echo -e "\n${C_BOLD}${C_CYAN}=== KIỂM TRA TRẠNG THÁI DOMAIN SSSD (sssctl domain-status) ===${C_RESET}"
            sssctl domain-status "$current_domain" || true
            echo -e "${C_BOLD}${C_CYAN}===============================================================${C_RESET}\n"
        fi

        local check_user=""
        prompt_with_default "Nhập tên tài khoản AD để kiểm tra quyền đăng nhập (Enter để bỏ qua)" "" check_user
        if [[ -n "$check_user" ]] && command -v sssctl >/dev/null 2>&1; then
            msg_info "Đang kiểm tra quyền đăng nhập: sssctl user-checks ${check_user}..."
            sssctl user-checks "$check_user" || true
        fi
        return 0
    else
        msg_err "Dịch vụ SSSD khởi động thất bại. Kiểm tra journalctl -u sssd."
        return 1
    fi
}

toggle_gpo_mode() {
    check_root
    msg_step "THAY ĐỔI CHẾ ĐỘ AD GPO ACCESS CONTROL (PERMISSIVE / ENFORCING)"

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
    echo "1) Thiết lập PERMISSIVE (Khuyên dùng - Cho phép AD user đăng nhập GUI/Console)"
    echo "2) Thiết lập ENFORCING  (Bắt buộc tuân thủ GPO Windows - có thể bị chặn pam_acct_mgmt)"
    local choice
    prompt_with_default "Chọn chế độ mới [1/2]" "1" choice

    if [[ "$choice" == "2" ]]; then
        if grep -q "ad_gpo_access_control" "$SSSD_CONF"; then
            sed -i 's/^[[:space:]]*ad_gpo_access_control.*/ad_gpo_access_control = enforcing/' "$SSSD_CONF"
        else
            sed -i '/\[domain\/.*\]/a ad_gpo_access_control = enforcing' "$SSSD_CONF"
        fi
        msg_ok "Đã chuyển GPO sang: ENFORCING"
    else
        if grep -q "ad_gpo_access_control" "$SSSD_CONF"; then
            sed -i 's/^[[:space:]]*ad_gpo_access_control.*/ad_gpo_access_control = permissive/' "$SSSD_CONF"
        else
            sed -i '/\[domain\/.*\]/a ad_gpo_access_control = permissive' "$SSSD_CONF"
        fi
        msg_ok "Đã chuyển GPO sang: PERMISSIVE"
    fi

    chmod 600 "$SSSD_CONF"
    chown root:root "$SSSD_CONF"

    if command -v sss_cache >/dev/null 2>&1; then
        sss_cache -E 2>/dev/null || true
    fi
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
    if [[ -z "$domain" && -f /etc/zorin-ad-vnc/ad_dc.conf ]]; then
        # shellcheck disable=SC1091
        source /etc/zorin-ad-vnc/ad_dc.conf
        domain="${DOMAIN}"
    fi
    if [[ -z "$domain" ]]; then
        prompt_with_default "Nhập tên AD Domain để đăng ký DNS" "" domain
    fi
    local fqdn="${current_host}.${domain}"
    local current_ip
    current_ip=$(hostname -I 2>/dev/null | awk '{print $1}')

    echo -e "Tên máy Zorin : ${C_CYAN}${current_host}${C_RESET} (${fqdn})"
    echo -e "Địa chỉ IP    : ${C_GREEN}${current_ip}${C_RESET}"
    echo -e "Domain AD     : ${C_YELLOW}${domain}${C_RESET}"
    echo "--------------------------------------------------------"

    # Determine Local Domain Controller / DNS Server (Avoid connecting to remote WAN DCs)
    local local_dc=""
    if [[ -f /etc/zorin-ad-vnc/ad_dc.conf ]]; then
        # shellcheck disable=SC1091
        source /etc/zorin-ad-vnc/ad_dc.conf
        local_dc="${DC1}"
    fi

    if [[ -z "$local_dc" ]]; then
        local ns_candidates=()
        if [[ -f /etc/resolv.conf ]]; then
            mapfile -t ns_candidates < <(grep -E '^nameserver' /etc/resolv.conf | awk '{print $2}' | grep -v '127.0.0.53')
        fi
        for ns in "${ns_candidates[@]}"; do
            if check_port_open "$ns" 53 2; then
                local_dc="$ns"
                break
            fi
        done
    fi

    if [[ -z "$local_dc" ]]; then
        while [[ -z "$local_dc" ]]; do
            prompt_with_default "Nhập IP Domain Controller cục bộ để đăng ký DNS" "" local_dc
            local_dc=$(echo "$local_dc" | tr -d '[:space:]')
        done
    fi
    msg_info "Máy chủ DNS / Domain Controller cục bộ: ${C_GREEN}${local_dc}${C_RESET}"

    # 1. Update SSSD with dyndns_update and local dyndns_server
    if [[ -f "$SSSD_CONF" ]]; then
        msg_info "1. Bật tính năng Dynamic DNS (dyndns_update) trong SSSD với DC cục bộ [${local_dc}]..."
        if ! grep -q "dyndns_update" "$SSSD_CONF"; then
            sed -i "/\[domain\/${domain}\]/a dyndns_update = True\ndyndns_server = ${local_dc}\ndyndns_refresh_interval = 14400\ndyndns_update_ptr = True\ndyndns_ttl = 3600" "$SSSD_CONF" 2>/dev/null || true
        else
            sed -i "s/dyndns_update = .*/dyndns_update = True/" "$SSSD_CONF" 2>/dev/null || true
            if ! grep -q "dyndns_server" "$SSSD_CONF"; then
                sed -i "/dyndns_update = True/a dyndns_server = ${local_dc}" "$SSSD_CONF" 2>/dev/null || true
            else
                sed -i "s/dyndns_server = .*/dyndns_server = ${local_dc}/" "$SSSD_CONF" 2>/dev/null || true
            fi
        fi
        chmod 600 "$SSSD_CONF"
        chown root:root "$SSSD_CONF"
        systemctl restart sssd 2>/dev/null || true
        msg_ok "Đã kích hoạt Dynamic DNS trong SSSD (trỏ về ${local_dc})."
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
    msg_info "4. Gửi yêu cầu cập nhật bản ghi DNS (RFC 2136) trực tiếp lên Domain Controller [${local_dc}]..."
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
server ${local_dc}
update delete ${fqdn} A
update add ${fqdn} 3600 A ${current_ip}
send
EOF
        if [[ -n "$ptr_record" ]]; then
            cat >> "$nsupdate_script" <<EOF
server ${local_dc}
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
