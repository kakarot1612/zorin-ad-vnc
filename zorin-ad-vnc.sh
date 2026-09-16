#!/usr/bin/env bash
# ==============================================================================
# Zorin OS AD Join & X11VNC Management Tool
# File: zorin-ad-vnc.sh
# Description: Main CLI & TUI Management tool for Zorin OS AD Join & X11VNC.
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

# Load libraries
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/check_dns.sh
source "$LIB_DIR/check_dns.sh"
# shellcheck source=lib/ad_join.sh
source "$LIB_DIR/ad_join.sh"
# shellcheck source=lib/sssd_config.sh
source "$LIB_DIR/sssd_config.sh"
# shellcheck source=lib/pam_homedir.sh
source "$LIB_DIR/pam_homedir.sh"
# shellcheck source=lib/gdm_xorg.sh
source "$LIB_DIR/gdm_xorg.sh"
# shellcheck source=lib/vnc_manager.sh
source "$LIB_DIR/vnc_manager.sh"
# shellcheck source=lib/health_check.sh
source "$LIB_DIR/health_check.sh"
# shellcheck source=lib/backup_rollback.sh
source "$LIB_DIR/backup_rollback.sh"
# shellcheck source=lib/smb_share.sh
source "$LIB_DIR/smb_share.sh"
# shellcheck source=lib/printer_manager.sh
source "$LIB_DIR/printer_manager.sh"
# shellcheck source=lib/bamboo_setup.sh
source "$LIB_DIR/bamboo_setup.sh"

show_system_info() {
    msg_step "THÔNG TIN HỆ THỐNG (SYSTEM INFORMATION)"
    
    local os_desc="Không xác định"
    if [[ -f /etc/os-release ]]; then
        os_desc=$(grep "PRETTY_NAME=" /etc/os-release | cut -d'"' -f2)
    fi

    echo -e "  Hệ điều hành          : ${C_CYAN}${os_desc}${C_RESET}"
    echo -e "  Kernel Linux          : ${C_CYAN}$(uname -r)${C_RESET}"
    echo -e "  Hostname (FQDN)       : ${C_CYAN}$(hostname -f 2>/dev/null || hostname)${C_RESET}"
    echo -e "  Địa chỉ IP máy        : ${C_CYAN}$(hostname -I 2>/dev/null | awk '{print $1}')${C_RESET}"
    echo -e "  Kiểu phiên (Session)  : ${C_CYAN}${XDG_SESSION_TYPE:-unknown}${C_RESET}"
    echo -e "  Display Manager       : ${C_CYAN}$(systemctl is-active gdm3 2>/dev/null || systemctl is-active gdm 2>/dev/null || echo "N/A")${C_RESET}"
    
    local joined_realm
    joined_realm=$(realm list 2>/dev/null | grep -E '^domain-name:' | awk '{print $2}' | head -n 1)
    if [[ -n "$joined_realm" ]]; then
        echo -e "  Trạng thái AD Domain  : ${C_GREEN}ĐÃ THAM GIA (${joined_realm})${C_RESET}"
    else
        echo -e "  Trạng thái AD Domain  : ${C_YELLOW}CHƯA THAM GIA${C_RESET}"
    fi

    local vnc_active
    vnc_active=$(systemctl is-active "${SYSTEMD_SERVICE}" 2>/dev/null || echo "inactive")
    echo -e "  Dịch vụ x11vnc        : ${C_CYAN}${vnc_active}${C_RESET}"
}

test_ad_user() {
    msg_step "KIỂM TRA TÀI KHOẢN NGƯỜI DÙNG ACTIVE DIRECTORY"

    local user_to_test
    prompt_with_default "Nhập tên tài khoản AD cần kiểm tra (VD: vnit024)" "vnit024" user_to_test

    msg_info "1. Tra cứu thông tin tài khoản: id ${user_to_test}..."
    if id "$user_to_test" 2>&1; then
        msg_ok "Tra cứu 'id' thành công!"
    else
        msg_err "Tra cứu 'id' thất bại! SSSD chưa nhận diện được user này."
        return 1
    fi

    msg_info "2. Tra cứu NSS: getent passwd ${user_to_test}..."
    local pwent
    pwent=$(getent passwd "$user_to_test" 2>/dev/null)
    if [[ -n "$pwent" ]]; then
        echo -e "   Entry: ${C_CYAN}${pwent}${C_RESET}"
        msg_ok "Tra cứu 'getent passwd' thành công!"
    else
        msg_err "Không tìm thấy user trong database NSS."
    fi

    # Optional Kerberos ticket authentication test
    if prompt_confirm "Bạn có muốn kiểm tra xác thực mật khẩu qua Kerberos (kinit)?" "Y"; then
        local user_pass
        prompt_secure_password "Nhập mật khẩu cho tài khoản AD [${user_to_test}]" user_pass false
        
        local domain
        domain=$(realm list 2>/dev/null | grep -E '^domain-name:' | awk '{print $2}' | head -n 1)
        domain="${domain:-bestpacific.com}"
        local upn="${user_to_test}@${domain^^}"

        msg_info "Đang kiểm tra kinit ${upn}..."
        if echo "$user_pass" | kinit "$upn" 2>&1; then
            msg_ok "Xác thực Kerberos thành công! Ticket đã được cấp phát:"
            klist 2>/dev/null || true
            kdestroy 2>/dev/null || true
        else
            msg_err "Xác thực mật khẩu Kerberos thất bại!"
        fi
        unset user_pass
    fi
}

view_logs() {
    msg_step "XEM FILE NHẬT KÝ HỆ THỐNG (LOGS)"
    echo "1) Xem log công cụ (/var/log/zorin-ad-vnc.log)"
    echo "2) Xem log x11vnc session (/var/log/zorin-x11vnc.log)"
    echo "3) Xem log SSSD (journalctl -u sssd)"
    echo "4) Xem log GDM (journalctl -u gdm3)"
    echo "0) Quay lại"

    local choice
    prompt_with_default "Chọn mục muốn xem" "1" choice

    case "$choice" in
        1)
            if [[ -f "$LOG_FILE" ]]; then
                tail -n 40 "$LOG_FILE"
            else
                msg_info "File log $LOG_FILE chưa tồn tại."
            fi
            ;;
        2)
            if [[ -f "/var/log/zorin-x11vnc.log" ]]; then
                tail -n 40 "/var/log/zorin-x11vnc.log"
            else
                msg_info "File log /var/log/zorin-x11vnc.log chưa tồn tại."
            fi
            ;;
        3)
            journalctl -u sssd -n 40 --no-pager
            ;;
        4)
            journalctl -u gdm3 -n 40 --no-pager 2>/dev/null || journalctl -u gdm -n 40 --no-pager
            ;;
        *)
            return 0
            ;;
    esac
}

automated_quick_setup() {
    check_root
    msg_step "BẮT ĐẦU QUY TRÌNH THIẾT LẬP TỰ ĐỘNG CHO MÁY MỚI (ONE-CLICK SETUP)"
    echo "Quy trình bao gồm:"
    echo "  1. Kiểm tra DNS & Domain Controller"
    echo "  2. Cài đặt các gói phụ thuộc AD & x11vnc"
    echo "  3. Nhập tay user & mật khẩu để Join Active Directory"
    echo "  4. Cấu hình SSSD và phân quyền 0600"
    echo "  5. Cấu hình PAM pam_mkhomedir"
    echo "  6. Cấu hình GDM3 ép sử dụng Xorg (tắt Wayland)"
    echo "  7. Nhập tay mật khẩu VNC an toàn"
    echo "  8. Kích hoạt dịch vụ Zorin Dynamic X11VNC Session Daemon"
    echo "  9. Chạy Health Check tổng kết"
    echo "--------------------------------------------------------"

    if ! prompt_confirm "Bạn đã sẵn sàng thực hiện?" "Y"; then
        msg_info "Đã hủy thao tác."
        return 0
    fi

    # Create backup before changes
    create_full_backup

    # Step 1: Join AD (includes package installation & DNS check & interactive credentials)
    msg_step "[BƯỚC 1/6] THAM GIA ACTIVE DIRECTORY"
    if ! join_active_directory; then
        msg_err "Join AD thất bại. Dừng quy trình thiết lập tự động."
        return 1
    fi

    # Step 2: Configure SSSD
    msg_step "[BƯỚC 2/6] CẤU HÌNH SSSD"
    configure_sssd

    # Step 3: Configure PAM
    msg_step "[BƯỚC 3/6] CẤU HÌNH PAM VÀ HOME DIRECTORY"
    configure_pam_mkhomedir

    # Step 4: Configure GDM & Xorg
    msg_step "[BƯỚC 4/6] CẤU HÌNH GDM ÉP XORG"
    configure_gdm_xorg

    # Step 5: Install & Configure x11vnc
    msg_step "[BƯỚC 5/7] THIẾT LẬP X11VNC & MẬT KHẨU KẾT NỐI"
    install_x11vnc
    setup_vnc_password
    install_vnc_systemd_service

    # Step 6: Install & Configure Bamboo Vietnamese Input Method
    msg_step "[BƯỚC 6/7] CÀI ĐẶT BỘ GÕ TIẾNG VIỆT BAMBOO TOÀN HỆ THỐNG"
    setup_bamboo_system_wide

    # Step 7: Health check
    msg_step "[BƯỚC 7/7] KIỂM TRA TOÀN DIỆN HỆ THỐNG"
    run_health_check

    msg_ok "========================================================="
    msg_ok "QUY TRÌNH THIẾT LẬP TỰ ĐỘNG ĐÃ HOÀN TẤT!"
    msg_ok "LƯU Ý QUAN TRỌNG: Hãy KHỞI ĐỘNG LẠI MÁY (REBOOT) để Zorin OS"
    msg_ok "áp dụng hoàn toàn Xorg và cho phép AD user đăng nhập GUI."
    msg_ok "========================================================="

    if prompt_confirm "Bạn có muốn khởi động lại máy (Reboot) ngay bây giờ?" "N"; then
        msg_info "Đang khởi động lại hệ thống..."
        reboot
    fi
}

main_menu() {
    while true; do
        clear || true
        echo -e "${C_BOLD}${C_BLUE}================================================================${C_RESET}"
        echo -e "${C_BOLD}${C_WHITE}       ZORIN OS AD JOIN & ENTERPRISE MANAGEMENT TOOL            ${C_RESET}"
        echo -e "${C_DIM}           Hỗ trợ AD Domain: bestpacific.com | OS: Zorin OS      ${C_RESET}"
        echo -e "${C_BOLD}${C_BLUE}================================================================${C_RESET}"
        echo -e " ${C_CYAN}${C_BOLD}[1]  Thiết lập tự động toàn diện cho máy mới (All-in-One Quick Setup)${C_RESET}"
        echo -e " ${C_DIM}------------------- GIA NHẬP VÀ CẤU HÌNH DOMAIN AD -------------------${C_RESET}"
        echo -e " ${C_GREEN}[2]${C_RESET}  Kiểm tra DNS & Kết nối Domain Controller (DNS / AD Check)"
        echo -e " ${C_GREEN}[3]${C_RESET}  Cài đặt các gói phụ thuộc hệ thống (AD / SSSD / VNC / CUPS / SMB)"
        echo -e " ${C_GREEN}[4]${C_RESET}  Gia nhập Active Directory (Join AD - Nhập user/pass AD Admin)"
        echo -e " ${C_GREEN}[5]${C_RESET}  Cấu hình xác thực SSSD & Tự tạo thư mục Home (PAM mkhomedir)"
        echo -e " ${C_GREEN}[6]${C_RESET}  Cấu hình GDM3 ép sử dụng Xorg (Tắt Wayland bắt buộc cho VNC)"
        echo -e " ${C_DIM}------------------ ĐIỀU KHIỂN TỪ XA VÀ BỘ GÕ TIẾNG VIỆT ----------------${C_RESET}"
        echo -e " ${C_GREEN}[7]${C_RESET}  Cài đặt & Kích hoạt dịch vụ x11vnc (Remote Support cho mọi user)"
        echo -e " ${C_GREEN}[8]${C_RESET}  Đặt / Thay đổi mật khẩu kết nối VNC an toàn"
        echo -e " ${C_GREEN}[9]${C_RESET}  Cài đặt bộ gõ tiếng Việt IBus-Bamboo cho TẤT CẢ người dùng AD"
        echo -e " ${C_DIM}----------------- TÀI NGUYÊN DOANH NGHIỆP & MÁY IN MẠNG -----------------${C_RESET}"
        echo -e " ${C_GREEN}[10]${C_RESET} Quản lý Thư mục chia sẻ mạng Windows (SMB/CIFS File Shares)"
        echo -e " ${C_GREEN}[11]${C_RESET} Quản lý Máy in chia sẻ qua mạng (Windows Print Server / IP CUPS)"
        echo -e " ${C_DIM}------------------ KIỂM TRA, BẢO TRÌ & SỬA LỖI HỆ THỐNG ----------------${C_RESET}"
        echo -e " ${C_GREEN}[12]${C_RESET} Bảng kiểm tra tổng quan hệ thống (Health Check Dashboard)"
        echo -e " ${C_GREEN}[13]${C_RESET} Sửa lỗi phân quyền thư mục Home cho người dùng AD (Repair Home)"
        echo -e " ${C_GREEN}[14]${C_RESET} Kiểm tra đăng nhập tài khoản AD / Vé Kerberos (Test AD User)"
        echo -e " ${C_GREEN}[15]${C_RESET} Xem nhật ký hoạt động hệ thống (System & Service Logs)"
        echo -e " ${C_GREEN}[16]${C_RESET} Sao lưu & Khôi phục cấu hình hệ thống (Backup & Rollback)"
        echo -e " ${C_RED}[17]${C_RESET} Rời khỏi Active Directory (Leave AD Domain)"
        echo -e " ${C_BOLD}[0]${C_RESET}  Thoát (Exit)"
        echo -e "${C_BLUE}================================================================${C_RESET}"

        local choice
        prompt_with_default "Nhập lựa chọn của bạn [0-17]" "1" choice

        case "$choice" in
            1)  automated_quick_setup; press_enter_to_continue ;;
            2)  run_dns_ad_check; press_enter_to_continue ;;
            3)  install_ad_dependencies; press_enter_to_continue ;;
            4)  join_active_directory; press_enter_to_continue ;;
            5)
                configure_sssd
                configure_pam_mkhomedir
                press_enter_to_continue
                ;;
            6)  configure_gdm_xorg; press_enter_to_continue ;;
            7)  install_vnc_systemd_service; press_enter_to_continue ;;
            8)  setup_vnc_password; press_enter_to_continue ;;
            9)  bamboo_management_menu; press_enter_to_continue ;;
            10) smb_file_share_menu; press_enter_to_continue ;;
            11) printer_manager_menu; press_enter_to_continue ;;
            12) run_health_check; press_enter_to_continue ;;
            13) repair_user_home_dir; press_enter_to_continue ;;
            14) test_ad_user; press_enter_to_continue ;;
            15) view_logs; press_enter_to_continue ;;
            16)
                echo "1) Sao lưu toàn diện (Full Backup)"
                echo "2) Danh sách bản sao lưu"
                echo "3) Khôi phục cấu hình (Rollback)"
                local bchoice
                prompt_with_default "Lựa chọn [1-3]" "2" bchoice
                case "$bchoice" in
                    1) create_full_backup ;;
                    2) list_backups ;;
                    3) rollback_configuration ;;
                esac
                press_enter_to_continue
                ;;
            17) leave_active_directory; press_enter_to_continue ;;
            0)
                echo -e "\n${C_CYAN}Cảm ơn bạn đã sử dụng Zorin AD & Enterprise Management Tool! Tạm biệt.${C_RESET}"
                exit 0
                ;;
            *)
                msg_err "Lựa chọn không hợp lệ."
                sleep 1
                ;;
        esac
    done
}

# CLI Argument parsing
show_help() {
    echo "Cách sử dụng: sudo ./zorin-ad-vnc.sh [TÙY CHỌN]"
    echo ""
    echo "Tùy chọn:"
    echo "  --menu                Mở giao diện menu tương tác (Mặc định)"
    echo "  --check               Chạy bảng kiểm tra tổng quan Health Check"
    echo "  --status              Xem trạng thái AD và x11vnc"
    echo "  --auto-setup          Chạy toàn bộ quy trình thiết lập tự động"
    echo "  --repair [username]   Sửa lỗi quyền Home Directory cho user"
    echo "  --toggle-gpo          Chuyển đổi chế độ AD GPO Enforcing / Permissive"
    echo "  --share               Mở menu quản lý Thư mục chia sẻ mạng (SMB/CIFS)"
    echo "  --printer             Mở menu quản lý Máy in chia sẻ qua mạng"
    echo "  --bamboo              Cài đặt & Cấu hình bộ gõ tiếng Việt Bamboo toàn hệ thống"
    echo "  --help, -h            Hiển thị trợ giúp này"
    echo ""
}

# Entrypoint
if [[ $# -eq 0 ]]; then
    check_root
    main_menu
else
    case "$1" in
        --menu)
            check_root
            main_menu
            ;;
        --check)
            run_health_check
            ;;
        --status)
            show_vnc_status
            ;;
        --auto-setup)
            check_root
            automated_quick_setup
            ;;
        --repair)
            check_root
            repair_user_home_dir "$2"
            ;;
        --toggle-gpo)
            check_root
            toggle_gpo_mode
            ;;
        --share)
            check_root
            smb_file_share_menu
            ;;
        --printer)
            check_root
            printer_manager_menu
            ;;
        --bamboo)
            check_root
            bamboo_management_menu
            ;;
        --help|-h)
            show_help
            ;;
        *)
            msg_err "Tham số không hợp lệ: $1"
            show_help
            exit 1
            ;;
    esac
fi
