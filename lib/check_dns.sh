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
        while [[ -z "$domain" ]]; do
            prompt_with_default "Nhập tên AD Domain cần kiểm tra" "" domain
            domain=$(echo "$domain" | tr -d '[:space:]')
            [[ -z "$domain" ]] && msg_warn "Tên AD Domain không được để trống!"
        done
    fi
    if [[ -z "$dc1" ]]; then
        while [[ -z "$dc1" ]]; do
            prompt_with_default "Nhập IP AD Domain Controller chính" "" dc1
            dc1=$(echo "$dc1" | tr -d '[:space:]')
            [[ -z "$dc1" ]] && msg_warn "IP Domain Controller không được để trống!"
        done
    fi
    if [[ -z "$dc2" ]]; then
        prompt_with_default "Nhập IP AD Domain Controller phụ (Tùy chọn - Enter nếu không có)" "" dc2
        dc2=$(echo "$dc2" | tr -d '[:space:]')
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

    # 2.1 Check for stale Host (A) record on AD DNS
    local cur_host
    cur_host=$(hostname -s)
    local dns_lookup_ip=""
    if command -v host >/dev/null 2>&1; then
        dns_lookup_ip=$(host "${cur_host}.${domain}" "$dc1" 2>/dev/null | awk '/has address/ {print $NF}' | head -n 1)
    elif command -v nslookup >/dev/null 2>&1; then
        dns_lookup_ip=$(nslookup "${cur_host}.${domain}" "$dc1" 2>/dev/null | awk '/Address: / {print $2}' | tail -n 1)
    fi
    local my_cur_ip=""
    my_cur_ip=$(ip route get "$dc1" 2>/dev/null | awk '{print $7}' | head -n 1)

    if [[ -n "$dns_lookup_ip" ]]; then
        if [[ "$dns_lookup_ip" != "$my_cur_ip" ]]; then
            msg_warn "PHÁT HIỆN BẢN GHI DNS CŨ CỦA MÁY [${cur_host^^}] TRÊN MÁY CHỦ DNS (${dc1})!"
            echo -e "   - DNS đang trỏ: ${C_RED}${dns_lookup_ip}${C_RESET} (IP máy cũ)"
            echo -e "   - IP thực tế của máy Zorin hiện tại: ${C_GREEN}${my_cur_ip}${C_RESET}"
            echo -e "   ${C_YELLOW}-> KHUYẾN NGHỊ: Hãy mở 'DNS Manager' (dnsmgmt.msc) trên Windows Server -> Forward Lookup Zones -> Xóa bản ghi Host (A) [${cur_host^^}] cũ để tránh ping nhầm và tránh lỗi phân quyền khi cập nhật DNS.${C_RESET}"
        else
            msg_ok "Bản ghi DNS của máy [${cur_host^^}] trên DNS trùng khớp IP hiện tại: ${my_cur_ip}"
        fi
    else
        msg_info "Chưa có bản ghi DNS cho [${cur_host^^}] trên Domain Controller (Sẽ được tự động tạo khi Join AD)."
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
    msg_info "4. Thử nghiệm 'realm discover' với Domain Controller [${dc1}]..."
    if command -v realm >/dev/null 2>&1; then
        local discover_out
        if discover_out=$(realm discover "$dc1" 2>&1); then
            msg_ok "Realm discover qua DC ${dc1} thành công:"
            echo -e "${C_DIM}${discover_out}${C_RESET}"
        elif discover_out=$(realm discover "$domain" 2>&1); then
            msg_ok "Realm discover qua Domain ${domain} thành công:"
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
    else
        msg_warn "Có một số cảnh báo hoặc lỗi kết nối. Hãy kiểm tra lại DNS/Firewall trước khi Join."
    fi

    # Check if Windows short-name resolution is needed
    echo ""
    if prompt_confirm "Bạn có muốn tối ưu hóa để Zorin OS ping được trực tiếp tên máy tính (VD: ping vn-printersrv) như Windows?" "Y"; then
        configure_windows_name_resolution "$domain"
    fi

    return 0
}

configure_windows_name_resolution() {
    check_root
    msg_step "CẤU HÌNH PHÂN GIẢI TÊN MÁY TÍNH WINDOWS (NETBIOS / WINS / DNS SEARCH)"

    local domain="$1"
    if [[ -z "$domain" && -f /etc/zorin-ad-vnc/ad_dc.conf ]]; then
        # shellcheck disable=SC1091
        source /etc/zorin-ad-vnc/ad_dc.conf
        domain="${DOMAIN}"
    fi
    if [[ -z "$domain" ]]; then
        domain=$(realm list 2>/dev/null | grep -E '^[[:space:]]*domain-name:' | awk '{print $2}' | head -n 1)
    fi
    if [[ -z "$domain" ]]; then
        prompt_with_default "Nhập tên AD Domain để cấu hình phân giải tên" "" domain
    fi

    msg_info "1. Cấu hình DNS Search Domain [${domain}] cho systemd-resolved..."
    mkdir -p /etc/systemd/resolved.conf.d 2>/dev/null || true
    cat > /etc/systemd/resolved.conf.d/enterprise-domain.conf <<EOF
[Resolve]
Domains=${domain}
LLMNR=yes
MulticastDNS=yes
EOF

    # Ensure /etc/resolv.conf search domain
    if [[ -f /etc/resolv.conf ]] && ! grep -q "search.*${domain}" /etc/resolv.conf; then
        sed -i "1s/^/search ${domain}\n/" /etc/resolv.conf 2>/dev/null || true
    fi

    msg_info "2. Cài đặt các gói hỗ trợ WINS / NetBIOS (libnss-winbind, winbind)..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq || true
    apt-get install -y libnss-winbind winbind samba-common-bin smbclient >/dev/null 2>&1 || true

    msg_info "3. Cấu hình /etc/nsswitch.conf kích hoạt phân giải WINS..."
    if [[ -f /etc/nsswitch.conf ]]; then
        if ! grep -E '^hosts:.*wins' /etc/nsswitch.conf >/dev/null 2>&1; then
            sed -i '/^hosts:/ s/$/ wins/' /etc/nsswitch.conf
            msg_ok "Đã thêm 'wins' vào /etc/nsswitch.conf"
        else
            msg_ok "/etc/nsswitch.conf đã có 'wins'."
        fi
    fi

    msg_info "4. Khởi động lại dịch vụ phân giải tên miền..."
    systemctl daemon-reload 2>/dev/null || true
    systemctl restart systemd-resolved 2>/dev/null || true
    systemctl restart winbind 2>/dev/null || true

    msg_ok "========================================================="
    msg_ok "CẤU HÌNH PHÂN GIẢI TÊN MÁY TÍNH WINDOWS HOÀN TẤT!"
    msg_ok "Từ bây giờ, bạn có thể ping trực tiếp tên máy tính (VD: ping vn-printersrv)"
    msg_ok "hoặc các máy tính khác trong mạng Domain như trên Windows!"
    msg_ok "========================================================="
}
