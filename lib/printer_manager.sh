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

    local pkgs=(cups cups-client cups-filters printer-driver-all printer-driver-fujixerox foomatic-db-compressed-ppds smbclient)
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

    # Ensure CUPS SMB backend exists and has correct permissions
    if [[ ! -e "/usr/lib/cups/backend/smb" ]] && [[ -x "/usr/bin/smbspool" ]]; then
        ln -sf /usr/bin/smbspool /usr/lib/cups/backend/smb 2>/dev/null || true
    fi
    if [[ -e "/usr/lib/cups/backend/smb" ]]; then
        chmod 700 /usr/lib/cups/backend/smb 2>/dev/null || true
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

    local default_dest
    default_dest=$(lpstat -d 2>/dev/null | awk -F': ' '{print $2}')
    echo -e "${C_BOLD}Máy in mặc định:${C_RESET} ${C_GREEN}${default_dest:-Chưa thiết lập}${C_RESET}\n"

    echo -e "${C_BOLD}Trạng thái các máy in:${C_RESET}"
    local printers
    printers=$(lpstat -p 2>&1 || true)
    if [[ -z "$printers" ]] || [[ "$printers" =~ "no system default destination" && ! "$printers" =~ "printer" ]]; then
        msg_info "Chưa có máy in nào được cài đặt trên máy này."
    else
        echo -e "${C_CYAN}${printers}${C_RESET}"
    fi

    echo -e "\n${C_BOLD}Chi tiết Device URI của các máy in:${C_RESET}"
    lpstat -v 2>/dev/null || true
}

select_printer_driver() {
    local -n out_driver_opt="$1"
    local -n out_model_desc="$2"

    echo ""
    echo -e "${C_BOLD}${C_BLUE}================================================================${C_RESET}"
    echo -e "${C_BOLD}${C_WHITE}           CHỌN MODEL VÀ TRÌNH ĐIỀU KHIỂN (DRIVER)              ${C_RESET}"
    echo -e "${C_BOLD}${C_BLUE}================================================================${C_RESET}"
    echo -e " ${C_GREEN}[1]  Fujifilm / Fuji Xerox Apeos Series (Dòng máy phổ biến Cty)${C_RESET}"
    echo -e " ${C_CYAN}[2]  Generic PCL 6 / PCL XL Color (Máy in Màu HP, Canon, Ricoh...)${C_RESET}"
    echo -e " ${C_CYAN}[3]  Generic PCL 6 / PCL XL Monochrome (Máy in Đen Trắng HP, Canon...)${C_RESET}"
    echo -e " [4]  Raw Queue (Gửi dữ liệu thô - Để Windows Server tự xử lý)"
    echo -e " [5]  IPP Everywhere / Driverless (Chuẩn in mạng Driverless đời mới)"
    echo -e " [6]  Generic PostScript (Chỉ dùng nếu máy in có chip Adobe PostScript)"
    echo -e " [7]  Tìm kiếm Model trong kho Driver hệ thống (Search CUPS lpinfo)"
    echo -e " [8]  Chỉ định file .PPD thủ công từ ổ đĩa"
    echo "----------------------------------------------------------------"

    local d_main
    prompt_with_default "Chọn nhóm Driver [1-8]" "1" d_main

    case "$d_main" in
        1)
            echo ""
            echo -e "${C_BOLD}${C_YELLOW}=== DANH SÁCH MODEL FUJIFILM / FUJI XEROX APEOS ===${C_RESET}"
            echo "  1) Fujifilm Apeos 4830 (Đen trắng / Monochrome)"
            echo "  2) Fujifilm Apeos 6340 (Đen trắng / Monochrome)"
            echo "  3) Fujifilm Apeos 3530 (Đen trắng / Monochrome)"
            echo "  4) Fujifilm Apeos C3370 / ApeosPort-V/VI C3370 (Màu / Color)"
            echo "  5) Fujifilm Apeos C3570 / ApeosPort-VII C3570 (Màu / Color)"
            echo "  6) Fujifilm Apeos C3371 / ApeosPort-VI C3371 (Màu / Color)"
            echo "  7) Fujifilm Apeos C3373 / DocuCentre-V C3373 (Màu / Color)"
            echo "  8) Dòng Fujifilm / Fuji Xerox Apeos khác"
            local apeos_choice
            prompt_with_default "Chọn Model máy in [1-8]" "4" apeos_choice

            # Check if printer-driver-fujixerox is installed
            if ! dpkg -s printer-driver-fujixerox >/dev/null 2>&1; then
                msg_info "Đang cài đặt gói bổ trợ printer-driver-fujixerox & foomatic..."
                export DEBIAN_FRONTEND=noninteractive
                apt-get update -qq || true
                apt-get install -y printer-driver-fujixerox foomatic-db-compressed-ppds >/dev/null 2>&1 || true
            fi

            local pxlcolor_ppd pxlmono_ppd fx_ppd
            pxlcolor_ppd=$(lpinfo -m 2>/dev/null | grep -E "Generic-PCL_6_PCL_XL_Printer-pxlcolor.ppd|pxlcolor.ppd" | head -n 1 | awk '{print $1}')
            pxlmono_ppd=$(lpinfo -m 2>/dev/null | grep -E "Generic-PCL_6_PCL_XL_Printer-pxlmono.ppd|pxlmono.ppd" | head -n 1 | awk '{print $1}')
            pxlcolor_ppd="${pxlcolor_ppd:-drv:///sample.drv/laserjet.ppd}"
            pxlmono_ppd="${pxlmono_ppd:-drv:///sample.drv/laserjet.ppd}"

            case "$apeos_choice" in
                1)
                    out_model_desc="Fujifilm Apeos 4830 (Mono PCL6)"
                    out_driver_opt="-m ${pxlmono_ppd}"
                    ;;
                2)
                    out_model_desc="Fujifilm Apeos 6340 (Mono PCL6)"
                    out_driver_opt="-m ${pxlmono_ppd}"
                    ;;
                3)
                    out_model_desc="Fujifilm Apeos 3530 (Mono PCL6)"
                    out_driver_opt="-m ${pxlmono_ppd}"
                    ;;
                4)
                    fx_ppd=$(lpinfo -m 2>/dev/null | grep -i -E "C3370|ApeosPort.*3370" | head -n 1 | awk '{print $1}')
                    if [[ -n "$fx_ppd" ]]; then
                        out_driver_opt="-m ${fx_ppd}"
                    else
                        out_driver_opt="-m ${pxlcolor_ppd}"
                    fi
                    out_model_desc="Fujifilm Apeos C3370 (Color PCL6/XL)"
                    ;;
                5)
                    fx_ppd=$(lpinfo -m 2>/dev/null | grep -i -E "C3570|ApeosPort.*3570" | head -n 1 | awk '{print $1}')
                    if [[ -n "$fx_ppd" ]]; then
                        out_driver_opt="-m ${fx_ppd}"
                    else
                        out_driver_opt="-m ${pxlcolor_ppd}"
                    fi
                    out_model_desc="Fujifilm Apeos C3570 (Color PCL6/XL)"
                    ;;
                6)
                    fx_ppd=$(lpinfo -m 2>/dev/null | grep -i -E "C3371|ApeosPort.*3371" | head -n 1 | awk '{print $1}')
                    if [[ -n "$fx_ppd" ]]; then
                        out_driver_opt="-m ${fx_ppd}"
                    else
                        out_driver_opt="-m ${pxlcolor_ppd}"
                    fi
                    out_model_desc="Fujifilm Apeos C3371 (Color PCL6/XL)"
                    ;;
                7)
                    fx_ppd=$(lpinfo -m 2>/dev/null | grep -i -E "C3373|DocuCentre.*3373|ApeosPort.*3373" | head -n 1 | awk '{print $1}')
                    if [[ -n "$fx_ppd" ]]; then
                        out_driver_opt="-m ${fx_ppd}"
                    else
                        out_driver_opt="-m ${pxlcolor_ppd}"
                    fi
                    out_model_desc="Fujifilm Apeos C3373 (Color PCL6/XL)"
                    ;;
                *)
                    out_model_desc="Fujifilm Apeos Series (Color PCL6/XL)"
                    out_driver_opt="-m ${pxlcolor_ppd}"
                    ;;
            esac
            ;;
        2)
            local pxl_col
            pxl_col=$(lpinfo -m 2>/dev/null | grep -E "Generic-PCL_6_PCL_XL_Printer-pxlcolor.ppd|pxlcolor.ppd" | head -n 1 | awk '{print $1}')
            out_driver_opt="-m ${pxl_col:-drv:///sample.drv/laserjet.ppd}"
            out_model_desc="Generic PCL 6 Color"
            ;;
        3)
            local pxl_mono
            pxl_mono=$(lpinfo -m 2>/dev/null | grep -E "Generic-PCL_6_PCL_XL_Printer-pxlmono.ppd|pxlmono.ppd" | head -n 1 | awk '{print $1}')
            out_driver_opt="-m ${pxl_mono:-drv:///sample.drv/laserjet.ppd}"
            out_model_desc="Generic PCL 6 Monochrome"
            ;;
        4)
            out_driver_opt="-m raw"
            out_model_desc="Raw Passthrough Queue"
            ;;
        5)
            out_driver_opt="-m everywhere"
            out_model_desc="IPP Everywhere / Driverless"
            ;;
        6)
            out_driver_opt="-m drv:///sample.drv/generic.ppd"
            out_model_desc="Generic PostScript Printer"
            ;;
        7)
            local search_kw
            prompt_with_default "Nhập từ khóa tìm kiếm Model (VD: 3370, C3570, LaserJet, Canon)" "Apeos" search_kw
            local search_results=()
            while IFS= read -r line; do
                [[ -n "$line" ]] && search_results+=("$line")
            done < <(lpinfo -m 2>/dev/null | grep -i "$search_kw" | head -n 20)

            if [[ ${#search_results[@]} -gt 0 ]]; then
                echo -e "\n${C_BOLD}Kết quả tìm kiếm driver:${C_RESET}"
                for idx in "${!search_results[@]}"; do
                    printf "  %2d) %s\n" "$((idx + 1))" "${search_results[$idx]}"
                done
                local s_sel
                prompt_with_default "Chọn driver [1-${#search_results[@]}]" "1" s_sel
                if [[ "$s_sel" =~ ^[0-9]+$ ]] && [[ "$s_sel" -ge 1 ]] && [[ "$s_sel" -le "${#search_results[@]}" ]]; then
                    local chosen_line="${search_results[$((s_sel - 1))]}"
                    local chosen_ppd="${chosen_line%% *}"
                    out_driver_opt="-m ${chosen_ppd}"
                    out_model_desc="${chosen_line#* }"
                else
                    out_driver_opt="-m drv:///sample.drv/laserjet.ppd"
                    out_model_desc="Generic PCL Laser"
                fi
            else
                msg_warn "Không tìm thấy kết quả phù hợp. Dùng Generic PCL 6."
                out_driver_opt="-m drv:///sample.drv/laserjet.ppd"
                out_model_desc="Generic PCL 6"
            fi
            ;;
        8)
            local ppd_file
            prompt_with_default "Nhập đường dẫn đầy đủ tới file .ppd" "" ppd_file
            if [[ -f "$ppd_file" ]]; then
                out_driver_opt="-P $ppd_file"
                out_model_desc="Custom PPD: $(basename "$ppd_file")"
            else
                msg_warn "File không tồn tại. Dùng Generic PCL 6."
                out_driver_opt="-m drv:///sample.drv/laserjet.ppd"
                out_model_desc="Generic PCL 6"
            fi
            ;;
        *)
            out_driver_opt="-m drv:///sample.drv/laserjet.ppd"
            out_model_desc="Generic PCL 6"
            ;;
    esac

    msg_ok "Đã chọn Driver: ${out_model_desc} (${out_driver_opt})"
}

add_network_printer_ip() {
    check_root
    msg_step "THÊM MÁY IN MẠNG TRỰC TIẾP QUA ĐỊA CHỈ IP (SOCKET / JETDIRECT / IPP)"

    install_printer_dependencies || return 1

    local printer_input
    prompt_with_default "Nhập địa chỉ IP hoặc Hostname của Máy In (VD: 10.0.60.50 hoặc printer-it)" "" printer_input

    if [[ -z "$printer_input" ]]; then
        msg_err "LỖI: Địa chỉ IP / Hostname máy in không được để trống."
        return 1
    fi

    local printer_ip=""
    check_host_ping_and_resolve "$printer_input" "Máy in" printer_ip || return 1

    local printer_name
    local default_pname
    default_pname=$(echo "Printer_${printer_input}" | tr ' ' '_' | tr -cd 'a-zA-Z0-9_-')
    prompt_with_default "Nhập Tên Máy In hiển thị (Không dấu, không khoảng trắng, VD: IT_Canon_LBP2900)" "$default_pname" printer_name

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

    # Driver & Model Selection
    local driver_opt=""
    local model_desc=""
    select_printer_driver driver_opt model_desc

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

browse_and_select_smb_printer() {
    local print_server="$1"
    local domain="$2"
    local -n out_selected="$3"
    local -n out_user="$4"
    local -n out_pass="$5"

    msg_info "Đang thăm dò danh sách máy in chia sẻ trên Server ${print_server}..."

    local smb_out=""
    local workgroup
    workgroup=$(get_ad_workgroup "$domain")

    # 1. Try Guest / Anonymous first
    smb_out=$(smbclient -N -L "$print_server" --option="client min protocol=SMB2" 2>&1 || true)

    # Check if access was denied or needs logon
    if [[ "$smb_out" =~ "NT_STATUS_ACCESS_DENIED" ]] || [[ "$smb_out" =~ "NT_STATUS_LOGON_FAILURE" ]] || [[ ! "$smb_out" =~ "Printer" ]]; then
        msg_info "Server yêu cầu xác thực tài khoản để xem danh sách máy in."
        local raw_ad_user
        prompt_with_default "Tài khoản duyệt danh sách (User cá nhân thông thường, VD: tom hoặc tom@bestpacific.com)" "${SUDO_USER:-$USER}" raw_ad_user
        local clean_ad_user clean_ad_domain
        normalize_ad_user_and_domain "$raw_ad_user" "$domain" clean_ad_user clean_ad_domain

        local ad_pass=""
        prompt_secure_password "Mật khẩu cho [${clean_ad_user}@${clean_ad_domain}]" ad_pass false

        out_user="${clean_ad_user}@${clean_ad_domain}"
        out_pass="$ad_pass"

        msg_info "Đang kết nối tới ${print_server}..."
        local auth_attempts=(
            "-W ${workgroup} -U ${clean_ad_user}"
            "-U ${clean_ad_user}@${clean_ad_domain}"
            "-U ${clean_ad_user}"
            "-W WORKGROUP -U ${clean_ad_user}"
        )

        for strat in "${auth_attempts[@]}"; do
            # shellcheck disable=SC2086
            smb_out=$(printf "%s\n" "$ad_pass" | smbclient -L "$print_server" $strat --option="client min protocol=SMB2" 2>&1)
            if [[ $? -eq 0 ]] && [[ "$smb_out" =~ "Sharename" ]]; then
                break
            fi
        done
    fi

    # Parse shares where Type == "Printer"
    local printer_list=()
    local comment_list=()

    while IFS='|' read -r p_name p_comm; do
        [[ -z "$p_name" ]] && continue
        # Ignore IPC and non-printer shares
        printer_list+=("$p_name")
        comment_list+=("$p_comm")
    done < <(echo "$smb_out" | awk '!/[ \t]+(Disk|IPC)[ \t]+/ && !/Sharename/ && !/---------/ {
        for(i=1;i<=NF;i++) {
            if($i=="Printer") {
                name=""; for(j=1;j<i;j++) name=(name?name " ":"")$j;
                comment=""; for(k=i+1;k<=NF;k++) comment=(comment?comment " ":"")$k;
                if(name != "") print name "|" comment;
                break;
            }
        }
    }')

    if [[ ${#printer_list[@]} -gt 0 ]]; then
        echo ""
        echo -e "${C_BOLD}${C_GREEN}================================================================${C_RESET}"
        echo -e "${C_BOLD}${C_WHITE} DANH SÁCH MÁY IN TRÊN WINDOWS PRINT SERVER (${print_server}):  ${C_RESET}"
        echo -e "${C_BOLD}${C_GREEN}================================================================${C_RESET}"
        for i in "${!printer_list[@]}"; do
            local num=$((i + 1))
            local p_name="${printer_list[$i]}"
            local p_comm="${comment_list[$i]}"
            if [[ -n "$p_comm" ]]; then
                printf "  ${C_CYAN}%2d)${C_RESET} %-28s ${C_YELLOW}(%s)${C_RESET}\n" "$num" "$p_name" "$p_comm"
            else
                printf "  ${C_CYAN}%2d)${C_RESET} %-28s\n" "$num" "$p_name"
            fi
        done
        echo -e "   0) Nhập tên máy in khác thủ công (Manual Input)"
        echo -e "----------------------------------------------------------------"

        local p_sel
        prompt_with_default "Chọn máy in muốn kết nối [1-${#printer_list[@]}]" "1" p_sel
        if [[ "$p_sel" =~ ^[0-9]+$ ]] && [[ "$p_sel" -ge 1 ]] && [[ "$p_sel" -le "${#printer_list[@]}" ]]; then
            out_selected="${printer_list[$((p_sel - 1))]}"
            msg_ok "Đã chọn máy in: ${out_selected}"
            return 0
        fi
    else
        msg_info "Không tự động tìm thấy danh sách máy in từ ${print_server} (hoặc Server giới hạn quyền duyệt)."
    fi

    return 1
}

add_windows_shared_printer() {
    check_root
    msg_step "THÊM MÁY IN SHARE TỪ WINDOWS PRINT SERVER (SMB PROTOCOL)"

    install_printer_dependencies || return 1

    local print_server
    prompt_with_default "Nhập IP hoặc Hostname của Windows Print Server" "vn-printersrv" print_server

    if [[ -z "$print_server" ]]; then
        msg_err "Địa chỉ server không được để trống."
        return 1
    fi

    # Verify server resolution and reachability (ping & port)
    local server_ip=""
    check_host_ping_and_resolve "$print_server" "Windows Print Server" server_ip || return 1

    local domain
    domain=$(realm list 2>/dev/null | grep -E '^domain-name:' | awk '{print $2}' | head -n 1)
    domain="${domain:-bestpacific.com}"

    local share_printer_name=""
    local auth_user=""
    local auth_pass=""

    # Attempt to browse server shares automatically
    echo ""
    if prompt_confirm "Bạn có muốn tự động tra cứu danh sách máy in trên ${print_server}?" "Y"; then
        browse_and_select_smb_printer "$print_server" "$domain" share_printer_name auth_user auth_pass || true
    fi

    # If not selected via browse, prompt manually
    if [[ -z "$share_printer_name" ]]; then
        prompt_with_default "Nhập Tên máy in chia sẻ trên Server (VD: Canon_Floor2, HP_Ketoan)" "" share_printer_name
    fi

    if [[ -z "$share_printer_name" ]]; then
        msg_err "Tên máy in chia sẻ không được để trống."
        return 1
    fi

    # Sanitize local CUPS printer name (CUPS does not allow spaces or special chars)
    local default_local_name
    default_local_name=$(echo "${share_printer_name}" | tr ' ' '_' | tr -cd 'a-zA-Z0-9_-')
    local local_printer_name
    prompt_with_default "Tên máy in hiển thị trên Zorin OS" "${default_local_name}" local_printer_name

    # Authentication setup for Connecting & Installing Printer Queue
    echo ""
    echo -e "${C_BOLD}${C_YELLOW}=== XÁC THỰC QUYỀN KẾT NỐI MÁY IN TRÊN WINDOWS PRINT SERVER ===${C_RESET}"
    echo -e "${C_DIM}Yêu cầu bắt buộc: Để cài đặt máy in, phải sử dụng tài khoản 'root' local hoặc${C_RESET}"
    echo -e "${C_DIM}tài khoản AD Quản trị đáp ứng định dạng 'domain\\user' hoặc 'user@domain'.${C_RESET}"
    echo -e "${C_DIM}Hệ thống sẽ kiểm tra xác thực trực tiếp và từ chối kết nối nếu sai thông tin.${C_RESET}\n"

    local auth_user_input=""
    local auth_pass_input=""
    local auth_success=false
    local retry_count=0
    local max_retries=3

    local default_admin="BESTPACIFIC\\Administrator"

    while [[ $retry_count -lt $max_retries ]]; do
        echo -e "${C_BOLD}Nhập tài khoản có quyền cài đặt máy in:${C_RESET}"
        echo -e "  - Định dạng AD Admin : ${C_GREEN}domain\\user${C_RESET} (VD: BESTPACIFIC\\Administrator)"
        echo -e "    hoặc               : ${C_GREEN}user@domain${C_RESET} (VD: Administrator@bestpacific.com)"
        echo -e "  - Định dạng Local    : ${C_GREEN}root${C_RESET}"

        prompt_with_default "Tài khoản cài đặt [hoặc 'q' để hủy]" "$default_admin" auth_user_input

        if [[ "$auth_user_input" =~ ^[Qq]$ ]]; then
            msg_info "Đã hủy thao tác kết nối máy in."
            return 0
        fi

        if [[ -z "$auth_user_input" ]]; then
            msg_err "LỖI: Tài khoản không được để trống! Hệ thống từ chối kết nối khống."
            retry_count=$((retry_count + 1))
            continue
        fi

        # Format check: must be 'root' or contain '\' or contain '@'
        if [[ "$auth_user_input" != "root" && "$auth_user_input" != *"\\"* && "$auth_user_input" != *"@"* ]]; then
            msg_err "========================================================="
            msg_err "LỖI ĐỊNH DẠNG: Tài khoản '${auth_user_input}' không hợp lệ!"
            msg_err "Bắt buộc phải là 'root' hoặc đúng định dạng 'domain\\user' / 'user@domain'."
            msg_warn "Ví dụ đúng: BESTPACIFIC\\Administrator hoặc Administrator@bestpacific.com"
            msg_err "========================================================="
            retry_count=$((retry_count + 1))
            continue
        fi

        prompt_secure_password "Mật khẩu cho [${auth_user_input}]" auth_pass_input false
        if [[ -z "$auth_pass_input" ]]; then
            msg_err "LỖI: Mật khẩu không được để trống! Hệ thống từ chối kết nối khống."
            retry_count=$((retry_count + 1))
            continue
        fi

        # Verify credentials against Windows Print Server
        msg_info "Đang kiểm tra xác thực tài khoản [${auth_user_input}] với máy chủ [${print_server}]..."
        local smb_auth_args=()
        local clean_user="" clean_dom="" workgroup=""

        if [[ "$auth_user_input" == "root" ]]; then
            smb_auth_args=("-U" "root")
            clean_user="root"
            clean_dom=""
            workgroup=""
        elif [[ "$auth_user_input" == *"\\"* ]]; then
            clean_dom="${auth_user_input%%\\*}"
            clean_user="${auth_user_input#*\\}"
            workgroup="$clean_dom"
            smb_auth_args=("-W" "$clean_dom" "-U" "$clean_user")
        elif [[ "$auth_user_input" == *"@"* ]]; then
            clean_user="${auth_user_input%%@*}"
            clean_dom="${auth_user_input#*@}"
            workgroup=$(get_ad_workgroup "$clean_dom")
            smb_auth_args=("-W" "$workgroup" "-U" "$clean_user")
        fi

        local auth_test_out
        auth_test_out=$(printf "%s\n" "$auth_pass_input" | smbclient -L "$print_server" "${smb_auth_args[@]}" --option="client min protocol=SMB2" 2>&1 || true)
        local test_rc=$?

        if [[ "$auth_test_out" =~ "NT_STATUS_LOGON_FAILURE" ]] || \
           [[ "$auth_test_out" =~ "NT_STATUS_WRONG_PASSWORD" ]] || \
           [[ "$auth_test_out" =~ "NT_STATUS_ACCOUNT_DISABLED" ]] || \
           [[ "$auth_test_out" =~ "NT_STATUS_ACCOUNT_LOCKED_OUT" ]] || \
           [[ "$auth_test_out" =~ "NT_STATUS_NO_SUCH_USER" ]] || \
           [[ $test_rc -ne 0 && ! "$auth_test_out" =~ "Sharename" ]]; then
            local err_status
            err_status=$(echo "$auth_test_out" | grep -o -E 'NT_STATUS_[A-Z_]+' | head -n 1)
            msg_err "========================================================="
            msg_err "LỖI XÁC THỰC: Tài khoản hoặc mật khẩu không chính xác!"
            if [[ -n "$err_status" ]]; then
                msg_err "Chi tiết mã lỗi từ Server: ${err_status}"
            fi
            msg_err "========================================================="
            retry_count=$((retry_count + 1))
            continue
        fi

        auth_success=true
        msg_ok "Xác thực tài khoản [${auth_user_input}] thành công! Máy chủ cho phép kết nối máy in."
        break
    done

    if [[ "$auth_success" != "true" ]]; then
        msg_err "========================================================="
        msg_err "KẾT NỐI THẤT BẠI: Quá số lần xác thực không thành công."
        msg_err "Hệ thống dừng cài đặt. Tuyệt đối không kết nối khống!"
        msg_err "========================================================="
        return 1
    fi

    # Driver & Model Selection
    local driver_opt=""
    local model_desc=""
    select_printer_driver driver_opt model_desc

    msg_info "Đang cài đặt máy in SMB: ${local_printer_name} -> ${print_server}/${share_printer_name}..."

    # Build CUPS SMB URI with encoded credentials
    local smb_uri=""
    local url_share_name
    url_share_name=$(urlencode "$share_printer_name")

    local enc_pass
    enc_pass=$(urlencode "$auth_pass_input")

    if [[ "$auth_user_input" == "root" ]]; then
        local enc_usr
        enc_usr=$(urlencode "root")
        smb_uri="smb://${enc_usr}:${enc_pass}@${print_server}/${url_share_name}"
    else
        local enc_dom enc_usr
        enc_dom=$(urlencode "${workgroup:-$clean_dom}")
        enc_usr=$(urlencode "$clean_user")
        smb_uri="smb://${enc_dom}%5C${enc_usr}:${enc_pass}@${print_server}/${url_share_name}"
    fi
    unset auth_pass_input enc_pass

    # Configure CUPS printer queue
    # shellcheck disable=SC2086
    if lpadmin -p "$local_printer_name" -E -v "$smb_uri" $driver_opt; then
        cupsaccept "$local_printer_name" 2>/dev/null || true
        cupsenable "$local_printer_name" 2>/dev/null || true

        msg_ok "========================================================="
        msg_ok "THÊM MÁY IN TỪ WINDOWS PRINT SERVER THÀNH CÔNG!"
        msg_ok "Tên máy in : ${local_printer_name}"
        msg_ok "Server     : \\\\${print_server}\\${share_printer_name}"
        msg_ok "Model/Driver: ${model_desc} (${driver_opt})"
        msg_ok "========================================================="

        if prompt_confirm "Bạn có muốn đặt máy in này làm MẶC ĐỊNH?" "Y"; then
            lpoptions -d "$local_printer_name"
            msg_ok "Đã đặt ${local_printer_name} làm máy in mặc định."
        fi

        if prompt_confirm "Bạn có muốn in một trang thử nghiệm (Print Test Page)?" "Y"; then
            print_test_page "$local_printer_name"
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

    msg_info "Đang gửi lệnh in trang thử nghiệm tới máy in [${target_printer}]..."

    local test_txt="/tmp/cups_test_page_${target_printer}.txt"
    cat > "$test_txt" <<EOF
======================================================================
  ZORIN OS ENTERPRISE PRINT TEST PAGE
======================================================================
  May in       : ${target_printer}
  Thoi gian    : $(date '+%Y-%m-%d %H:%M:%S')
  Hostname     : $(hostname)
  Nguoi dung   : ${USER:-$(whoami)}
======================================================================
  Chuc mung! May in da hoat dong chinh xac tren he dieu hanh Zorin OS.
  Khong con bi loi in tran giay trang do sai PostScript Driver!
======================================================================
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

change_printer_driver() {
    check_root
    msg_step "THAY ĐỔI DRIVER CHO MÁY IN HIỆN CÓ (SỬA LỖI IN GIẤY TRẮNG LIÊN TỤC)"

    list_printers

    local target_printer
    prompt_with_default "Nhập tên máy in muốn đổi Driver (VD: vn-it-office)" "vn-it-office" target_printer

    if [[ -z "$target_printer" ]]; then
        msg_warn "Chưa nhập tên máy in."
        return 1
    fi

    if ! lpstat -p "$target_printer" >/dev/null 2>&1; then
        msg_err "Không tìm thấy máy in '${target_printer}' trên hệ thống CUPS."
        return 1
    fi

    # Driver & Model Selection
    local driver_opt=""
    local model_desc=""
    select_printer_driver driver_opt model_desc

    msg_info "Đang cập nhật Driver cho máy in ${target_printer}..."
    # shellcheck disable=SC2086
    if lpadmin -p "$target_printer" $driver_opt; then
        cupsenable "$target_printer" 2>/dev/null || true
        cupsaccept "$target_printer" 2>/dev/null || true
        msg_ok "Đã cập nhật Driver cho máy in [${target_printer}] thành công!"
        msg_ok "Model / Driver: ${model_desc} (${driver_opt})"

        if prompt_confirm "Bạn có muốn in thử 1 trang kiểm tra ngay bây giờ?" "Y"; then
            print_test_page "$target_printer"
        fi
        return 0
    else
        msg_err "Cập nhật Driver thất bại."
        return 1
    fi
}

cancel_all_print_jobs() {
    check_root
    msg_step "HỦY TOÀN BỘ LỆNH IN ĐANG KẸT / IN TRÀN GIẤY TRẮNG"

    msg_info "1. Hủy tất cả các lệnh in trong hàng đợi CUPS (cancel -a -x)..."
    cancel -a -x 2>/dev/null || true
    lprm - 2>/dev/null || true

    msg_info "2. Làm sạch bộ nhớ hàng đợi của từng máy in..."
    for p in $(lpstat -p 2>/dev/null | awk '{print $2}'); do
        cupsdisable "$p" 2>/dev/null || true
        lpadmin -p "$p" -c 2>/dev/null || true
        cupsenable "$p" 2>/dev/null || true
    done

    msg_info "3. Khởi động lại dịch vụ CUPS..."
    systemctl restart cups 2>/dev/null || true

    msg_ok "========================================================="
    msg_ok "ĐÃ XÓA SẠCH HOÀN TOÀN CÁC LỆNH IN TRÊN HỆ THỐNG ZORIN OS!"
    msg_warn "QUAN TRỌNG: Nếu máy in vẫn đang tiếp tục nuốt và nhả giấy:"
    msg_warn "-> Do bộ nhớ đệm RAM bên trong máy in đã nhận lệnh từ trước."
    msg_warn "-> Hãy nhấn nút [CANCEL / STOP] trên bảng điều khiển máy in,"
    msg_warn "   hoặc TẮT CÔNG TẮC NGUỒN máy in khoảng 5 giây rồi BẬT LẠI."
    msg_ok "========================================================="
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
        echo " 7) Cài đặt / cập nhật dịch vụ CUPS và Drivers đầy đủ"
        echo -e " ${C_YELLOW}8) Đổi Driver cho máy in (Sửa lỗi in giấy trắng liên tục)${C_RESET}"
        echo -e " ${C_RED}9) Hủy TOÀN BỘ lệnh in đang kẹt (Cancel All Print Jobs)${C_RESET}"
        echo " 0) Quay lại Menu chính"
        echo "----------------------------------------------------------------"

        local p_choice
        prompt_with_default "Chọn chức năng [0-9]" "1" p_choice

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
            8) change_printer_driver ;;
            9) cancel_all_print_jobs ;;
            0) break ;;
            *) msg_err "Lựa chọn không hợp lệ." ;;
        esac
    done
}
