#!/usr/bin/env bash
# ==============================================================================
# Zorin OS AD Join & X11VNC Management Tool
# File: lib/check_dns.sh
# Description: Verify DNS resolution, Kerberos/LDAP ports, and AD domain discovery.
# ==============================================================================

# Source common utilities if not already loaded
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"

check_port_open() {
    local host="$1"
    local port="$2"
    local timeout_sec="${3:-2}"

    if command -v nc >/dev/null 2>&1; then
        nc -z -w "$timeout_sec" "$host" "$port" >/dev/null 2>&1
        return $?
    elif timeout "$timeout_sec" bash -c "cat < /dev/null > /dev/tcp/$host/$port" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

run_dns_ad_check() {
    local domain="$1"
    local dc1="$2"
    local dc2="$3"

    if [[ -z "$domain" ]]; then
        prompt_with_default "Nhập tên AD Domain cần kiểm tra" "bestpacific.com" domain
    fi
    if [[ -z "$dc1" ]]; then
        prompt_with_default "Nhập IP AD Domain Controller 1" "10.0.60.19" dc1
    fi
    if [[ -z "$dc2" ]]; then
        prompt_with_default "Nhập IP AD Domain Controller 2" "10.0.60.20" dc2
    fi

    msg_step "BẮT ĐẦU KIỂM TRA DNS VÀ KẾT NỐI ACTIVE DIRECTORY"
    echo -e "Domain mục tiêu: ${C_WHITE}${domain}${C_RESET}"
    echo -e "AD Controller 1: ${C_WHITE}${dc1}${C_RESET}"
    echo -e "AD Controller 2: ${C_WHITE}${dc2}${C_RESET}"
    echo "--------------------------------------------------------"

    local all_ok=true

    # 1. Check FQDN
    msg_info "1. Kiểm tra Hostname FQDN..."
    local fqdn
    fqdn=$(hostname -f 2>/dev/null || hostname)
    echo -e "   Current Hostname: ${C_CYAN}${fqdn}${C_RESET}"

    # 2. Check DNS Resolution of Domain
    msg_info "2. Phân giải DNS cho domain: ${domain}..."
    if getent hosts "$domain" >/dev/null 2>&1; then
        local ips
        ips=$(getent hosts "$domain" | awk '{print $1}' | tr '\n' ' ')
        msg_ok "Phân giải thành công ${domain} -> ${ips}"
    else
        msg_err "Không thể phân giải domain ${domain} qua DNS! Hãy kiểm tra lại /etc/resolv.conf hoặc DNS IP."
        all_ok=false
    fi

    # 3. Check DC Reachability (Ping & Ports)
    for dc_ip in "$dc1" "$dc2"; do
        [[ -z "$dc_ip" ]] && continue
        msg_info "3. Kiểm tra Domain Controller: ${dc_ip}..."
        if ping -c 1 -W 2 "$dc_ip" >/dev/null 2>&1; then
            msg_ok "Ping tới ${dc_ip}: Phản hồi tốt"
        else
            msg_warn "Ping tới ${dc_ip}: Không có phản hồi (có thể bị chặn ICMP)"
        fi

        # Check Kerberos (TCP 88)
        if check_port_open "$dc_ip" 88 2; then
            msg_ok "Port Kerberos (88/TCP) trên ${dc_ip}: Đang MỞ [OPEN]"
        else
            msg_err "Port Kerberos (88/TCP) trên ${dc_ip}: KHÔNG KẾT NỐI ĐƯỢC [CLOSED/FILTERED]"
            all_ok=false
        fi

        # Check LDAP (TCP 389)
        if check_port_open "$dc_ip" 389 2; then
            msg_ok "Port LDAP (389/TCP) trên ${dc_ip}: Đang MỞ [OPEN]"
        else
            msg_err "Port LDAP (389/TCP) trên ${dc_ip}: KHÔNG KẾT NỐI ĐƯỢC [CLOSED/FILTERED]"
            all_ok=false
        fi
    done

    # 4. Run realm discover
    msg_info "4. Thử nghiệm 'realm discover ${domain}'..."
    if command -v realm >/dev/null 2>&1; then
        local discover_out
        if discover_out=$(realm discover "$domain" 2>&1); then
            msg_ok "Realm discover thành công:"
            echo -e "${C_DIM}${discover_out}${C_RESET}"
        else
            msg_err "Realm discover thất bại!"
            echo -e "${C_RED}${discover_out}${C_RESET}"
            all_ok=false
        fi
    else
        msg_warn "Lệnh 'realm' chưa được cài đặt. Sẽ được cài đặt tự động ở bước Join AD."
    fi

    echo "--------------------------------------------------------"
    if [[ "$all_ok" == "true" ]]; then
        msg_ok "TẤT CẢ KIỂM TRA MẠNG VÀ DNS ĐÃ SẴN SÀNG ĐỂ JOIN AD!"
        return 0
    else
        msg_warn "Có một số cảnh báo hoặc lỗi kết nối. Hãy kiểm tra lại DNS/Firewall trước khi Join."
        return 1
    fi
}
