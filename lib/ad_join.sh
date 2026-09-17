#!/usr/bin/env bash
# ==============================================================================
# Zorin OS AD Join & X11VNC Management Tool
# File: lib/ad_join.sh
# Description: Install dependencies and join Zorin OS to Microsoft Active Directory.
# ==============================================================================

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/check_dns.sh
source "$LIB_DIR/check_dns.sh"

REQUIRED_PACKAGES=(
    realmd
    sssd
    sssd-ad
    sssd-tools
    libnss-sss
    libpam-sss
    adcli
    samba-common-bin
    krb5-user
    packagekit
    oddjob
    oddjob-mkhomedir
    libpam-mkhomedir
    dnsutils
    net-tools
)

install_ad_dependencies() {
    msg_step "KIỂM TRA VÀ CÀI ĐẶT CÁC GÓI BỔ TRỢ ACTIVE DIRECTORY"
    
    local missing_pkgs=()
    for pkg in "${REQUIRED_PACKAGES[@]}"; do
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then
            missing_pkgs+=("$pkg")
        fi
    done

    if [[ ${#missing_pkgs[@]} -eq 0 ]]; then
        msg_ok "Tất cả các gói phụ thuộc AD đã được cài đặt đầy đủ."
        return 0
    fi

    msg_info "Đang cài đặt các gói còn thiếu: ${missing_pkgs[*]}..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq || true
    
    if apt-get install -y "${missing_pkgs[@]}"; then
        msg_ok "Cài đặt các gói phụ thuộc AD thành công!"
        return 0
    else
        msg_err "Cài đặt gói phụ thuộc thất bại. Vui lòng kiểm tra kết nối internet / apt repo."
        return 1
    fi
}

leave_active_directory() {
    check_root
    msg_step "RỜI KHỎI ACTIVE DIRECTORY (REALM LEAVE)"
    
    if ! command -v realm >/dev/null 2>&1; then
        msg_warn "Lệnh 'realm' chưa được cài đặt."
        return 0
    fi

    local current_realm
    current_realm=$(realm list 2>/dev/null | grep -E '^domain-name:' | awk '{print $2}' | head -n 1)

    if [[ -z "$current_realm" ]]; then
        msg_info "Hệ thống hiện tại chưa join bất kỳ Active Directory realm nào."
        return 0
    fi

    echo -e "Hệ thống đang tham gia domain: ${C_YELLOW}${current_realm}${C_RESET}"
    if ! prompt_confirm "Bạn có chắc chắn muốn rời khỏi domain ${current_realm}?" "N"; then
        msg_info "Đã hủy thao tác."
        return 0
    fi

    local admin_user=""
    prompt_with_default "Tài khoản quản trị AD để rời domain (Enter để bỏ qua nếu dùng force)" "" admin_user
    local admin_pass=""
    prompt_secure_password "Nhập mật khẩu cho tài khoản quản trị (Enter để bỏ qua nếu dùng force)" admin_pass false

    # Sanitize admin_user: strip DOMAIN\ or DOMAIN/ prefix and @DOMAIN suffix
    local clean_admin_user="$admin_user"
    clean_admin_user="${clean_admin_user#*\\}"
    clean_admin_user="${clean_admin_user#*/}"
    clean_admin_user="${clean_admin_user%@*}"

    msg_info "Đang thực hiện realm leave..."
    if [[ -n "$admin_pass" ]]; then
        echo "$admin_pass" | realm leave "$current_realm" -U "$clean_admin_user" 2>&1
    else
        realm leave "$current_realm" 2>&1
    fi

    if [[ -z "$(realm list 2>/dev/null)" ]]; then
        msg_ok "Đã rời khỏi Active Directory thành công."
        rm -f /etc/zorin-ad-vnc/ad_dc.conf /etc/krb5.keytab 2>/dev/null || true
    else
        msg_warn "Kiểm tra lại realm list, có thể cần gỡ bỏ thủ công bằng realm leave."
    fi
}

join_active_directory() {
    check_root
    msg_step "THỰC HIỆN GIA NHẬP ACTIVE DIRECTORY (REALM JOIN)"

    # 1. Install prerequisites
    if ! install_ad_dependencies; then
        return "$ERR_AD_JOIN"
    fi

    # 2. Check current status
    local current_realm
    current_realm=$(realm list 2>/dev/null | grep -E '^domain-name:' | awk '{print $2}' | head -n 1)
    if [[ -n "$current_realm" ]]; then
        msg_warn "Hệ thống ĐÃ ĐƯỢC JOIN vào domain: ${current_realm}"
        if ! prompt_confirm "Bạn có muốn rời khỏi domain cũ và tiến hành Join lại?" "N"; then
            msg_info "Bỏ qua quá trình Join AD."
            return 0
        fi
        leave_active_directory
    fi

    # 3. Inputs (Reads from .env if configured, otherwise prompts user dynamically)
    local domain="${AD_DOMAIN:-}"
    local dc1="${AD_DC1:-}"
    local dc2="${AD_DC2:-}"
    local admin_user="${AD_ADMIN_USER:-}"
    local admin_pass="${AD_ADMIN_PASS:-}"

    while [[ -z "$domain" ]]; do
        prompt_with_default "Nhập AD Domain FQDN" "" domain
        domain=$(echo "$domain" | tr -d '[:space:]')
        [[ -z "$domain" ]] && msg_warn "AD Domain FQDN không được để trống!"
    done

    while [[ -z "$dc1" ]]; do
        prompt_with_default "Nhập IP AD Domain Controller chính (Site cục bộ)" "" dc1
        dc1=$(echo "$dc1" | tr -d '[:space:]')
        [[ -z "$dc1" ]] && msg_warn "IP Domain Controller chính không được để trống!"
    done

    if [[ -z "$dc2" ]]; then
        prompt_with_default "Nhập IP AD Domain Controller phụ (Tùy chọn - Enter nếu không có)" "" dc2
        dc2=$(echo "$dc2" | tr -d '[:space:]')
    fi

    while [[ -z "$admin_user" ]]; do
        prompt_with_default "Nhập tên tài khoản quản trị AD để Join" "" admin_user
        admin_user=$(echo "$admin_user" | tr -d '[:space:]')
        [[ -z "$admin_user" ]] && msg_warn "Tài khoản quản trị không được để trống!"
    done
    
    # Prompt password securely if not provided via environment
    if [[ -z "$admin_pass" ]]; then
        prompt_secure_password "Nhập mật khẩu cho tài khoản AD [${admin_user}]" admin_pass false
    fi

    # 4. Sanitize admin_user: strip any DOMAIN\ or DOMAIN/ prefix and @domain suffix
    local clean_admin_user="$admin_user"
    clean_admin_user="${clean_admin_user#*\\}"
    clean_admin_user="${clean_admin_user#*/}"
    clean_admin_user="${clean_admin_user%@*}"
    if [[ "$clean_admin_user" != "$admin_user" ]]; then
        msg_info "Tài khoản xác thực AD: [${clean_admin_user}] (đã chuẩn hóa từ '${admin_user}')"
    else
        msg_info "Tài khoản xác thực AD: [${clean_admin_user}]"
    fi

    # 5. Save DC mapping persistently so SSSD and DNS updater always use the specified local DCs
    mkdir -p /etc/zorin-ad-vnc
    cat > /etc/zorin-ad-vnc/ad_dc.conf <<EOF
DOMAIN=${domain}
DC1=${dc1}
DC2=${dc2}
EOF

    # 6. Discover DC FQDN to prevent Kerberos SPN mismatch (Server not found in Kerberos database)
    msg_info "Thăm dò FQDN máy chủ Domain Controller [${dc1}]..."
    local dc_fqdn=""
    dc_fqdn=$(adcli info --domain-controller="$dc1" 2>/dev/null | grep -E '^[[:space:]]*domain-controller[[:space:]]*=' | awk '{print $3}' | head -n 1)
    if [[ -z "$dc_fqdn" ]]; then
        dc_fqdn=$(host "$dc1" 2>/dev/null | awk '/pointer/ {print $NF}' | sed 's/\.$//' | head -n 1)
    fi
    if [[ -n "$dc_fqdn" ]]; then
        msg_ok "Phát hiện FQDN Domain Controller: ${dc_fqdn}"
    else
        dc_fqdn="$dc1"
    fi

    # 7. Pre-configure /etc/krb5.conf to PIN KDC strictly to DC FQDN
    # Setting rdns = false prevents Kerberos from reversing DC IP to an unmapped SPN
    msg_info "Ghim cấu hình Kerberos KDC trực tiếp vào Domain Controller [${dc_fqdn}]..."
    cat > /etc/krb5.conf <<EOF
[libdefaults]
    default_realm = ${domain^^}
    dns_lookup_realm = true
    dns_lookup_kdc = true
    ticket_lifetime = 24h
    renew_lifetime = 7d
    forwardable = true

[domain_realm]
    .${domain,,} = ${domain^^}
    ${domain,,} = ${domain^^}
EOF

    # 8. Update /etc/resolv.conf and /etc/hosts with local DC
    if [[ -f /etc/resolv.conf ]] && ! grep -q "^nameserver[[:space:]]*${dc1}" /etc/resolv.conf; then
        sed -i "1s/^/nameserver ${dc1}\n/" /etc/resolv.conf 2>/dev/null || true
    fi
    sed -i "/^[[:space:]]*${dc1}[[:space:]]/d" /etc/hosts 2>/dev/null || true
    if [[ "$dc_fqdn" != "$dc1" ]]; then
        echo -e "${dc1}\t${dc_fqdn}\t${dc_fqdn%%.*}\t${domain}" >> /etc/hosts
    else
        echo -e "${dc1}\t${domain}" >> /etc/hosts
    fi

    # 9. Connectivity Check
    if ! run_dns_ad_check "$domain" "$dc1" "$dc2"; then
        if ! prompt_confirm "Kiểm tra kết nối có cảnh báo. Bạn có vẫn muốn tiếp tục Join AD?" "N"; then
            msg_warn "Hủy thao tác Join AD."
            return "$ERR_AD_JOIN"
        fi
    fi

    # Remove any stale keytab before joining
    rm -f /etc/krb5.keytab

    # 10. Execute AD Join strictly targeting DC FQDN
    msg_info "Đang kết nối và xác thực trực tiếp với Domain Controller [${dc_fqdn}] (${domain})..."
    local join_output=""
    local join_status=0

    # Primary method: adcli join targeting the discovered DC FQDN (satisfies Kerberos SPN requirement)
    msg_info "Phương thức 1: Gia nhập AD qua adcli join trỏ Domain Controller [${dc_fqdn}]..."
    join_output=$(printf "%s" "$admin_pass" | adcli join \
        --domain="$domain" \
        --domain-realm="${domain^^}" \
        --domain-controller="$dc_fqdn" \
        --computer-name="$(hostname -s)" \
        --login-user="$clean_admin_user" \
        --stdin-password \
        --verbose 2>&1) || join_status=$?

    # Fallback method: if FQDN failed, attempt with IP or realm join
    if [[ $join_status -ne 0 ]]; then
        msg_warn "Phương thức 1 gặp lỗi (Mã: $join_status), thử phương thức 2 qua realm join..."
        local realm_out=""
        local realm_status=0
        realm_out=$(echo "$admin_pass" | realm join "$dc_fqdn" \
            -U "$clean_admin_user" \
            --install=/ \
            --verbose 2>&1) || realm_status=$?
        
        if [[ $realm_status -ne 0 ]]; then
            msg_warn "realm join với DC FQDN gặp lỗi, thử realm join với domain ${domain}..."
            local r_out2=""
            r_out2=$(echo "$admin_pass" | realm join "$domain" \
                -U "$clean_admin_user" \
                --install=/ \
                --verbose 2>&1) || true
            realm_out+=$'\n'"$r_out2"
        fi
        join_output+=$'\n'"$realm_out"
    fi

    # Clear password from memory variable immediately
    unset admin_pass

    # Verify if keytab or realm exists
    if [[ -f /etc/krb5.keytab && -s /etc/krb5.keytab ]]; then
        join_status=0
    elif realm list 2>/dev/null | grep -qi "$domain"; then
        join_status=0
    fi

    if [[ $join_status -eq 0 ]]; then
        msg_ok "========================================================="
        msg_ok "CHÚC MỪNG! ZORIN OS ĐÃ GIA NHẬP ACTIVE DIRECTORY THÀNH CÔNG!"
        msg_ok "Domain Controller đã kết nối: ${dc_fqdn} (${dc1})"
        msg_ok "========================================================="
        log_message "SUCCESS" "Joined Active Directory domain: $domain on DC $dc_fqdn with user $clean_admin_user"
        
        # Configure SSSD to lock to dc1 and dc2
        msg_info "Tiến hành cấu hình SSSD ghim cứng Domain Controller [${dc1}]..."
        configure_sssd

        # Configure PAM mkhomedir
        configure_pam_mkhomedir

        # Display realm information
        echo ""
        realm list 2>/dev/null || true
        return 0
    else
        msg_err "Gia nhập Active Directory THẤT BẠI (Mã lỗi: $join_status)!"
        echo -e "${C_RED}Chi tiết lỗi:${C_RESET}"
        echo "$join_output" | grep -v -i "password" || true

        if echo "$join_output" | grep -qi "Insufficient permissions"; then
            echo -e "\n${C_YELLOW}=== HƯỚNG DẪN XỬ LÝ LỖI PHÂN QUYỀN (INSUFFICIENT PERMISSIONS) ===${C_RESET}"
            echo -e "  1. Tài khoản AD [${clean_admin_user}] đã xác thực mật khẩu THÀNH CÔNG."
            echo -e "  2. Tuy nhiên tài khoản này không có quyền tạo hoặc ghi đè tài khoản máy tính [$(hostname -s)] trong Active Directory."
            echo -e "  3. Cách khắc phục:"
            echo -e "     - Mở 'Active Directory Users and Computers' trên Windows Server."
            echo -e "     - Tìm tài khoản máy [$(hostname -s)] trong OU (hoặc CN=Computers) và XÓA BỎ (Delete) hoặc Reset tài khoản này."
            echo -e "     - Hoặc sử dụng tài khoản có quyền Domain Admin để thực hiện Join."
            echo -e "=================================================================\n"
        fi

        log_message "ERROR" "Failed to join domain $domain on DC $dc_fqdn with user $clean_admin_user"
        return "$ERR_AD_JOIN"
    fi
}
