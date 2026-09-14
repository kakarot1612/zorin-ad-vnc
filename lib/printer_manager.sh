#!/usr/bin/env bash
# ==============================================================================
# Zorin OS AD Join & X11VNC Management Tool
# File: lib/printer_manager.sh
# Description: Manage Network Printers (Direct IP, JetDirect, IPP, Windows SMB Print Server).
# ==============================================================================

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"

install_printer_dependencies() {
    msg_step "KIỂM TRA VÀ CÀI ĐẶT DỊCH VỤ MÁY IN (CUPS & DRIVERS)"

    local pkgs=(cups cups-client cups-filters printer-driver-all smbclient)
    local missing=()
    for pkg in "${pkgs[@]}"; do
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then
            missing+=("$pkg")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        msg_info "Đang cài đặt các gói máy in: ${missing[*]}..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq || true
        apt-get install -y "${missing[@]}" || {
            msg_err "Cài đặt gói CUPS thất bại."
            return 1
        }
    fi

    # Ensure CUPS SMB backend exists
    if [[ ! -e "/usr/lib/cups/backend/smb" ]] && [[ -x "/usr/bin/smbspool" ]]; then
        ln -sf /usr/bin/smbspool /usr/lib/cups/backend/smb 2>/dev/null || true
    fi

    systemctl daemon-reload 2>/dev/null || true
    systemctl enable --now cups 2>/dev/null || true

    if systemctl is-active --quiet cups; then
        msg_ok "Dịch vụ máy in CUPS đang hoạt động [ACTIVE RUNNING]."
        return 0
    else
        msg_err "Dịch vụ CUPS khởi động thất bại. Hãy kiểm tra journalctl -u cups."
        return 1
    fi
}

list_printers() {
    msg_step "DANH SÁCH MÁY IN ĐÃ CÀI ĐẶT TRÊN HỆ THỐNG"

    if ! command -v lpstat >/dev/null 2>&1; then
        msg_warn "Lệnh 'lpstat' chưa có. Cần cài đặt CUPS trước."
        return 1
    fi

    echo -e "${C_BOLD}Trạng thái máy in:${C_RESET}"
    local printers
    printers=$(lpstat -p -d 2>&1 || true)
    if [[ -z "$printers" ]] || [[ "$printers" =~ "no system default destination" && ! "$printers" =~ "printer" ]]; then
        msg_info "Chưa có máy in nào được cài đặt trên máy này."
    else
        echo -e "${C_CYAN}${printers}${C_RESET}"
    fi

    echo -e "\n${C_BOLD}Chi tiết Device URI của các máy in:${C_RESET}"
    lpstat -v 2>/dev/null || true
}

add_network_printer_ip() {
    check_root
    msg_step "THÊM MÁY IN MẠNG TRỰC TIẾP QUA ĐỊA CHỈ IP (SOCKET / JETDIRECT / IPP)"

    install_printer_dependencies || return 1

    local printer_ip
    prompt_with_default "Nhập địa chỉ IP của Máy In (VD: 10.0.60.50)" "" printer_ip

    if [[ -z "$printer_ip" ]]; then
        msg_err "Địa chỉ IP máy in không được để trống."
        return 1
    fi

    local printer_name
    prompt_with_default "Nhập Tên Máy In hiển thị (Không dấu, không khoảng trắng, VD: IT_Canon_LBP2900)" "Printer_${printer_ip//./_}" printer_name

    echo ""
    echo -e "${C_BOLD}Chọn giao thức kết nối tới máy in:${C_RESET}"
    echo "  1) RAW Port 9100 / JetDirect (Phổ biến nhất cho Canon, HP, Ricoh, Brother)"
    echo "  2) IPP / IPPS (Internet Printing Protocol - Cổng 631 / Driverless Everywhere)"
    echo "  3) LPD / LPR (Cổng 515)"
    local proto_choice
    prompt_with_default "Chọn giao thức [1-3]" "1" proto_choice

    local device_uri
    case "$proto_choice" in
        2) device_uri="ipp://${printer_ip}/ipp/print" ;;
        3) device_uri="lpd://${printer_ip}/PASSTHRU" ;;
        *) device_uri="socket://${printer_ip}:9100" ;;
    esac

    echo ""
    echo -e "${C_BOLD}Chọn kiểu Driver (Trình điều khiển):${C_RESET}"
    echo "  1) IPP Everywhere / Driverless (Chuẩn hiện đại cho máy in mạng đời mới)"
    echo "  2) Generic PostScript Printer (Tương thích cao)"
    echo "  3) Generic PCL 6 / PCL XL Printer (Tương thích hầu hết máy in văn phòng)"
    echo "  4) Tự chỉ định file PPD (.ppd file)"
    local driver_choice
    prompt_with_default "Lựa chọn driver [1-4]" "1" driver_choice

    local driver_opt=""
    case "$driver_choice" in
        1) driver_opt="-m everywhere" ;;
        2) driver_opt="-m drv:///sample.drv/generic.ppd" ;;
        3) driver_opt="-m foomatic-db-compressed-ppds:0/ppd/foomatic-ppd/Generic-PCL_6_PCL_XL_Printer-pxlcolor.ppd" ;;
        4)
            local ppd_path
            prompt_with_default "Nhập đường dẫn đầy đủ tới file .ppd" "" ppd_path
            if [[ -f "$ppd_path" ]]; then
                driver_opt="-P $ppd_path"
            else
                msg_warn "Không tìm thấy file PPD. Tự động chuyển về Generic PostScript."
                driver_opt="-m drv:///sample.drv/generic.ppd"
            fi
            ;;
    esac

    msg_info "Đang cài đặt máy in: ${printer_name} -> ${device_uri}..."
    
    # Run lpadmin command
    # shellcheck disable=SC2086
    if lpadmin -p "$printer_name" -E -v "$device_uri" $driver_opt; then
        # Enable accepting jobs
        cupsaccept "$printer_name" 2>/dev/null || true
        cupsenable "$printer_name" 2>/dev/null || true

        msg_ok "========================================================="
        msg_ok "CÀI ĐẶT MÁY IN MẠNG THÀNH CÔNG!"
        msg_ok "Tên máy in : ${printer_name}"
        msg_ok "Địa chỉ URI: ${device_uri}"
        msg_ok "========================================================="

        if prompt_confirm "Bạn có muốn đặt máy in này làm MẶC ĐỊNH?" "Y"; then
            lpoptions -d "$printer_name"
            msg_ok "Đã đặt ${printer_name} làm máy in mặc định."
        fi

        if prompt_confirm "Bạn có muốn in một trang thử nghiệm (Print Test Page)?" "Y"; then
            print_test_page "$printer_name"
        fi
        return 0
    else
        msg_err "Cài đặt máy in thất bại. Hãy kiểm tra lại địa chỉ IP hoặc driver."
        return 1
    fi
}

add_windows_shared_printer() {
    check_root
    msg_step "THÊM MÁY IN SHARE TỪ WINDOWS PRINT SERVER (SMB PROTOCOL)"

    install_printer_dependencies || return 1

    local print_server
    prompt_with_default "Nhập IP hoặc Hostname của Windows Print Server (VD: 10.0.60.18 hoặc printserver)" "" print_server

    local share_printer_name
    prompt_with_default "Nhập Tên máy in chia sẻ trên Server (VD: Canon_Floor2, HP_Ketoan)" "" share_printer_name

    if [[ -z "$print_server" ]] || [[ -z "$share_printer_name" ]]; then
        msg_err "Địa chỉ server và tên máy in không được để trống."
        return 1
    fi

    local local_printer_name
    prompt_with_default "Tên máy in hiển thị trên Zorin OS" "${share_printer_name}" local_printer_name

    local domain
    domain=$(realm list 2>/dev/null | grep -E '^domain-name:' | awk '{print $2}' | head -n 1)
    domain="${domain:-bestpacific.com}"

    echo ""
    echo -e "${C_BOLD}Phương thức xác thực tới Windows Print Server:${C_RESET}"
    echo "  1) Nhập tài khoản Domain AD (Khuyên dùng)"
    echo "  2) Sử dụng Kerberos Single Sign-On (Nếu server hỗ trợ krb5 SMB printing)"
    echo "  3) Khách (Guest / Không mật khẩu)"
    local auth_choice
    prompt_with_default "Lựa chọn [1-3]" "1" auth_choice

    local smb_uri=""
    if [[ "$auth_choice" == "2" ]]; then
        smb_uri="smb://${print_server}/${share_printer_name}"
    elif [[ "$auth_choice" == "3" ]]; then
        smb_uri="smb://guest@${print_server}/${share_printer_name}"
    else
        local ad_user
        prompt_with_default "Tài khoản AD có quyền in" "${SUDO_USER:-$USER}" ad_user
        local ad_pass=""
        prompt_secure_password "Mật khẩu cho [${ad_user}]" ad_pass false

        # Format: smb://domain%5Cusername:password@server/printer
        local url_user
        url_user=$(echo -n "${domain}\\${ad_user}" | sed 's/\\/%5C/g')
        smb_uri="smb://${url_user}:${ad_pass}@${print_server}/${share_printer_name}"
        unset ad_pass
    fi

    msg_info "Đang cài đặt máy in SMB: ${local_printer_name}..."
    
    # Add printer with generic postscript or PCL driver
    if lpadmin -p "$local_printer_name" -E -v "$smb_uri" -m "drv:///sample.drv/generic.ppd"; then
        cupsaccept "$local_printer_name" 2>/dev/null || true
        cupsenable "$local_printer_name" 2>/dev/null || true

        msg_ok "========================================================="
        msg_ok "THÊM MÁY IN TỪ WINDOWS PRINT SERVER THÀNH CÔNG!"
        msg_ok "Tên máy in: ${local_printer_name}"
        msg_ok "Server    : ${print_server}/${share_printer_name}"
        msg_ok "========================================================="

        if prompt_confirm "Bạn có muốn đặt làm máy in mặc định?" "Y"; then
            lpoptions -d "$local_printer_name"
            msg_ok "Đã đặt làm máy in mặc định."
        fi
        return 0
    else
        msg_err "Cài đặt máy in từ Windows Print Server thất bại."
        return 1
    fi
}

print_test_page() {
    local target_printer="$1"

    if [[ -z "$target_printer" ]]; then
        prompt_with_default "Nhập tên máy in cần in thử" "" target_printer
    fi

    if [[ -z "$target_printer" ]]; then
        msg_err "Tên máy in không được để trống."
        return 1
    fi

    msg_info "Đang gửi lệnh in trang thử nghiệm tới: ${target_printer}..."

    # Create a nice test page text
    local test_txt="/tmp/zorin_testprint.txt"
    cat > "$test_txt" <<EOF
============================================================
           ZORIN OS ENTERPRISE PRINT TEST PAGE
============================================================
May in       : ${target_printer}
Thoi gian in : $(date '+%Y-%m-%d %H:%M:%S')
May tram     : $(hostname -f 2>/dev/null || hostname)
IP May tram  : $(hostname -I 2>/dev/null | awk '{print $1}')
Domain       : bestpacific.com
============================================================
Chuc mung! May in chia se qua mang da duoc ket noi va hoat
dong hoan hao tren he dieu hanh Zorin OS.
============================================================
EOF

    if lp -d "$target_printer" "$test_txt" 2>&1; then
        msg_ok "Lệnh in đã được gửi thành công tới máy in ${target_printer}!"
        rm -f "$test_txt"
        return 0
    else
        msg_err "Lệnh in trang thử nghiệm thất bại."
        rm -f "$test_txt"
        return 1
    fi
}

remove_printer() {
    check_root
    msg_step "XÓA MÁY IN KHỎI HỆ THỐNG"

    list_printers

    local del_printer
    prompt_with_default "Nhập tên máy in muốn xóa" "" del_printer

    if [[ -z "$del_printer" ]]; then
        msg_warn "Chưa nhập tên máy in."
        return 0
    fi

    if prompt_confirm "Bạn có chắc chắn muốn xóa máy in ${del_printer}?" "N"; then
        if lpadmin -x "$del_printer" 2>&1; then
            msg_ok "Đã xóa máy in ${del_printer} thành công."
        else
            msg_err "Không thể xóa máy in ${del_printer}."
        fi
    fi
}

printer_manager_menu() {
    while true; do
        echo -e "\n${C_BOLD}${C_BLUE}================================================================${C_RESET}"
        echo -e "${C_BOLD}${C_WHITE}       QUẢN LÝ MÁY IN CHIA SẺ QUA MẠNG (CUPS / SMB / IP)        ${C_RESET}"
        echo -e "${C_BOLD}${C_BLUE}================================================================${C_RESET}"
        echo " 1) Xem danh sách máy in đã cài đặt"
        echo " 2) Thêm máy in mạng qua Địa chỉ IP (RAW 9100 / JetDirect / IPP)"
        echo " 3) Thêm máy in từ Windows Print Server (SMB)"
        echo " 4) In trang thử nghiệm (Print Test Page)"
        echo " 5) Đặt máy in làm Mặc định (Default Printer)"
        echo " 6) Xóa máy in khỏi hệ thống"
        echo " 7) Cài đặt / cập nhật dịch vụ CUPS và Drivers"
        echo " 0) Quay lại Menu chính"
        echo "----------------------------------------------------------------"

        local p_choice
        prompt_with_default "Chọn chức năng [0-7]" "1" p_choice

        case "$p_choice" in
            1) list_printers ;;
            2) add_network_printer_ip ;;
            3) add_windows_shared_printer ;;
            4) print_test_page ;;
            5)
                local def_p
                prompt_with_default "Nhập tên máy in muốn đặt làm mặc định" "" def_p
                if [[ -n "$def_p" ]]; then
                    lpoptions -d "$def_p" && msg_ok "Đã đặt $def_p làm mặc định."
                fi
                ;;
            6) remove_printer ;;
            7) install_printer_dependencies ;;
            0) break ;;
            *) msg_err "Lựa chọn không hợp lệ." ;;
        esac
    done
}
