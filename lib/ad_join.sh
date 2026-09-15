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

    local admin_user
    prompt_with_default "Tài khoản AD Administrator để leave (hoặc để trống nếu force)" "Administrator" admin_user
    local admin_pass=""
    prompt_secure_password "Nhập mật khẩu cho ${admin_user} (Enter để bỏ qua mật khẩu)" admin_pass false

    msg_info "Đang thực hiện realm leave..."
    if [[ -n "$admin_pass" ]]; then
        echo "$admin_pass" | realm leave "$current_realm" -U "$admin_user" 2>&1
    else
        realm leave "$current_realm" 2>&1
    fi

    if [[ -z "$(realm list 2>/dev/null)" ]]; then
        msg_ok "Đã rời khỏi Active Directory thành công."
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

    # 3. Interactive Inputs (User & Password manually entered)
    local domain
    local dc1
    local dc2
    local admin_user
    local admin_pass

    prompt_with_default "Nhập AD Domain FQDN" "bestpacific.com" domain
    prompt_with_default "Nhập IP AD Domain Controller 1" "10.0.60.19" dc1
    prompt_with_default "Nhập IP AD Domain Controller 2" "10.0.60.20" dc2
    prompt_with_default "Nhập tên tài khoản AD Administrator" "Administrator" admin_user
    
    # Prompt password securely - hidden characters, no logging
    prompt_secure_password "Nhập mật khẩu cho tài khoản AD [${admin_user}]" admin_pass false

    # 4. Connectivity Check
    if ! run_dns_ad_check "$domain" "$dc1" "$dc2"; then
        if ! prompt_confirm "Kiểm tra kết nối có cảnh báo. Bạn có vẫn muốn tiếp tục Join AD?" "N"; then
            msg_warn "Hủy thao tác Join AD."
            return "$ERR_AD_JOIN"
        fi
    fi

    # 5. Execute realm join safely via stdin pipe
    msg_info "Đang kết nối và xác thực với Active Directory ${domain}..."
    local join_output
    local join_status=0

    # Execute realm join piping password into stdin
    join_output=$(echo "$admin_pass" | realm join "$domain" \
        -U "$admin_user" \
        --install=/ \
        --verbose 2>&1) || join_status=$?

    # Clear password from memory variable immediately
    unset admin_pass

    if [[ $join_status -eq 0 ]]; then
        msg_ok "========================================================="
        msg_ok "CHÚC MỪNG! ZORIN OS ĐÃ GIA NHẬP ACTIVE DIRECTORY THÀNH CÔNG!"
        msg_ok "========================================================="
        log_message "SUCCESS" "Joined Active Directory domain: $domain with user $admin_user"
        
        # Display realm information
        realm list
        return 0
    else
        msg_err "Gia nhập Active Directory THẤT BẠI (Mã lỗi: $join_status)!"
        echo -e "${C_RED}Chi tiết lỗi từ realm:${C_RESET}"
        echo "$join_output" | grep -v -i "password" || true
        log_message "ERROR" "Failed to join domain $domain with user $admin_user"
        return "$ERR_AD_JOIN"
    fi
}
