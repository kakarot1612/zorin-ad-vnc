#!/usr/bin/env bash
# ==============================================================================
# Zorin OS AD Join & X11VNC Management Tool
# File: lib/smb_share.sh
# Description: Manage Windows / Active Directory Network File Shares (SMB/CIFS).
# ==============================================================================

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"

CREDENTIALS_DIR="/etc/cifs-credentials"

install_smb_dependencies() {
    msg_step "KIỂM TRA VÀ CÀI ĐẶT CÁC GÓI KẾT NỐI FILE SHARE (SMB/CIFS)"
    
    local pkgs=(cifs-utils smbclient keyutils gvfs-backends)
    local missing=()
    for pkg in "${pkgs[@]}"; do
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then
            missing+=("$pkg")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        msg_ok "Các gói phụ thuộc SMB/CIFS đã được cài đặt đầy đủ."
        return 0
    fi

    msg_info "Đang cài đặt các gói: ${missing[*]}..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq || true
    if apt-get install -y "${missing[@]}"; then
        msg_ok "Cài đặt thành công các gói hỗ trợ File Share!"
        return 0
    else
        msg_err "Cài đặt gói thất bại. Vui lòng kiểm tra kết nối mạng."
        return 1
    fi
}

list_smb_shares_on_server() {
    check_root
    msg_step "TRA CỨU DANH SÁCH THƯ MỤC CHIA SẺ TRÊN SERVER (SMB BROWSE)"

    local server_host
    prompt_with_default "Nhập IP hoặc Hostname của File Server" "10.0.60.30" server_host

    if [[ -z "$server_host" ]]; then
        msg_err "Địa chỉ server không được để trống."
        return 1
    fi

    install_smb_dependencies || return 1

    local domain
    domain=$(realm list 2>/dev/null | grep -E '^domain-name:' | awk '{print $2}' | head -n 1)
    domain="${domain:-bestpacific.com}"

    echo ""
    echo "1) Sử dụng tài khoản Domain Administrator hoặc tài khoản AD cá nhân"
    echo "2) Sử dụng chế độ Khách (Guest / Anonymous)"
    local auth_choice
    prompt_with_default "Chọn phương thức xác thực [1-2]" "1" auth_choice

    if [[ "$auth_choice" == "2" ]]; then
        msg_info "Đang tra cứu danh sách share từ ${server_host} với quyền Guest..."
        smbclient -N -L "$server_host" 2>&1 || true
    else
        echo ""
        local raw_user
        prompt_with_default "Tài khoản AD (VD: tom hoặc tom@bestpacific.com)" "${SUDO_USER:-$USER}" raw_user
        local clean_user clean_domain
        normalize_ad_user_and_domain "$raw_user" "$domain" clean_user clean_domain

        local workgroup
        workgroup=$(get_ad_workgroup "$clean_domain")

        local ad_pass=""
        prompt_secure_password "Mật khẩu cho tài khoản AD [${clean_user}@${clean_domain}]" ad_pass false

        echo ""
        msg_info "Đang tra cứu danh sách share từ ${server_host} với tài khoản [${clean_user}@${clean_domain}]..."

        local smb_out smb_code=0
        # 1. Try with UPN (tom@bestpacific.com)
        smb_out=$(smbclient -L "$server_host" -U "${clean_user}@${clean_domain}%${ad_pass}" --option="client min protocol=SMB2" 2>&1) || smb_code=$?

        # 2. If UPN failed with logon failure, fallback to NetBIOS workgroup (BESTPACIFIC\tom)
        if [[ $smb_code -ne 0 ]] && [[ "$smb_out" == *"NT_STATUS_LOGON_FAILURE"* ]]; then
            msg_info "Thử lại xác thực với NetBIOS Domain [${workgroup}\\${clean_user}]..."
            smb_out=$(smbclient -L "$server_host" -U "${clean_user}%${ad_pass}" -W "${workgroup}" --option="client min protocol=SMB2" 2>&1) || smb_code=$?
        fi

        # 3. If still failed, try NetBIOS backslash format
        if [[ $smb_code -ne 0 ]] && [[ "$smb_out" == *"NT_STATUS_LOGON_FAILURE"* ]]; then
            smb_out=$(smbclient -L "$server_host" -U "${workgroup}\\${clean_user}%${ad_pass}" --option="client min protocol=SMB2" 2>&1) || smb_code=$?
        fi

        echo "$smb_out"
        unset ad_pass
    fi
}

mount_smb_share() {
    check_root
    msg_step "KẾT NỐI (MOUNT) THƯ MỤC CHIA SẺ MẠNG (WINDOWS SMB/CIFS)"

    install_smb_dependencies || return 1

    local server_host=""
    while [[ -z "$server_host" ]]; do
        prompt_with_default "Nhập IP hoặc Hostname của File Server" "10.0.60.30" server_host
        if [[ -z "$server_host" ]]; then
            msg_warn "Địa chỉ server không được để trống. Vui lòng nhập lại."
        fi
    done

    local share_name=""
    while [[ -z "$share_name" ]]; do
        echo ""
        prompt_with_default "Nhập Tên Thư Mục Chia Sẻ trên server (VD: Data, IT) [hoặc 'q' để hủy]" "" share_name
        if [[ "$share_name" =~ ^[Qq]$ ]]; then
            msg_info "Đã hủy thao tác kết nối thư mục chia sẻ."
            return 0
        fi
        if [[ -z "$share_name" ]]; then
            msg_warn "Tên thư mục chia sẻ không được để trống. Vui lòng nhập tên share."
        fi
    done

    # Clean share path
    share_name="${share_name#/}"
    share_name="${share_name%/}"
    local unc_path="//${server_host}/${share_name}"

    local default_mount="/mnt/shares/${share_name}"
    local mount_point
    echo ""
    prompt_with_default "Thư mục gắn (Mount Point) trên Zorin OS" "$default_mount" mount_point

    mkdir -p "$mount_point"

    local domain
    domain=$(realm list 2>/dev/null | grep -E '^domain-name:' | awk '{print $2}' | head -n 1)
    domain="${domain:-bestpacific.com}"

    local target_user
    prompt_with_default "Tài khoản Zorin/AD cục bộ sẽ sở hữu thư mục mount" "${SUDO_USER:-$USER}" target_user
    local clean_target_user _dummy_d
    normalize_ad_user_and_domain "$target_user" "$domain" clean_target_user _dummy_d

    local target_uid target_gid
    target_uid=$(id -u "$clean_target_user" 2>/dev/null || id -u "$target_user" 2>/dev/null || echo "1000")
    target_gid=$(id -g "$clean_target_user" 2>/dev/null || id -g "$target_user" 2>/dev/null || echo "1000")

    echo ""
    echo -e "${C_BOLD}Chọn phương thức xác thực vào Windows File Server:${C_RESET}"
    echo "  1) Nhập tài khoản Domain AD (Lưu file credentials bảo mật 0600 - Khuyên dùng)"
    echo "  2) Sử dụng Kerberos SSO (Yêu cầu user đã đăng nhập GUI qua AD)"
    echo "  3) Truy cập Khách (Guest / Không cần mật khẩu)"
    local auth_type
    prompt_with_default "Lựa chọn [1-3]" "1" auth_type

    local mount_opts="uid=${target_uid},gid=${target_gid},iocharset=utf8,file_mode=0770,dir_mode=0770"

    if [[ "$auth_type" == "2" ]]; then
        # Kerberos
        mount_opts="${mount_opts},sec=krb5"
    elif [[ "$auth_type" == "3" ]]; then
        # Guest
        mount_opts="${mount_opts},guest"
    else
        # Manual Domain Credentials
        local raw_ad_user
        prompt_with_default "Tài khoản AD để truy cập File Share" "$clean_target_user" raw_ad_user
        local clean_ad_user clean_ad_domain
        normalize_ad_user_and_domain "$raw_ad_user" "$domain" clean_ad_user clean_ad_domain

        local workgroup
        workgroup=$(get_ad_workgroup "$clean_ad_domain")

        local ad_pass=""
        prompt_secure_password "Mật khẩu AD của [${clean_ad_user}@${clean_ad_domain}]" ad_pass false

        mkdir -p "$CREDENTIALS_DIR"
        chmod 700 "$CREDENTIALS_DIR"

        local cred_file="${CREDENTIALS_DIR}/${server_host}_${share_name}.cred"
        cat > "$cred_file" <<EOF
username=${clean_ad_user}
password=${ad_pass}
domain=${workgroup}
EOF
        chmod 600 "$cred_file"
        unset ad_pass

        mount_opts="${mount_opts},credentials=${cred_file}"
        msg_ok "Đã lưu thông tin xác thực an toàn vào: ${cred_file} (Quyền 0600)"
    fi

    # Perform mount
    msg_info "Đang mount ${unc_path} vào ${mount_point}..."
    if mount -t cifs "$unc_path" "$mount_point" -o "$mount_opts"; then
        msg_ok "========================================================="
        msg_ok "MOUNT THƯ MỤC CHIA SẺ THÀNH CÔNG!"
        msg_ok "Đường dẫn: ${mount_point} -> ${unc_path}"
        msg_ok "========================================================="

        # Ask to make it persistent in /etc/fstab
        if prompt_confirm "Bạn có muốn tự động kết nối lại thư mục này mỗi khi mở máy (/etc/fstab)?" "Y"; then
            local fstab_entry="${unc_path} ${mount_point} cifs ${mount_opts},_netdev,nofail 0 0"
            if ! grep -q "$unc_path" /etc/fstab; then
                echo "$fstab_entry" >> /etc/fstab
                msg_ok "Đã lưu vào /etc/fstab thành công!"
            else
                msg_warn "Đường dẫn ${unc_path} đã tồn tại trong /etc/fstab."
            fi
        fi
        return 0
    else
        msg_err "Mount thất bại! Vui lòng kiểm tra lại quyền truy cập, firewall hoặc mật khẩu."
        return 1
    fi
}

list_mounted_shares() {
    msg_step "DANH SÁCH CÁC THƯ MỤC MẠNG CIFS/SMB ĐANG KẾT NỐI"

    local cifs_mounts
    cifs_mounts=$(mount -t cifs 2>/dev/null || true)

    if [[ -z "$cifs_mounts" ]]; then
        msg_info "Hiện tại không có thư mục mạng CIFS/SMB nào đang mount."
    else
        echo -e "${C_CYAN}${cifs_mounts}${C_RESET}"
    fi

    echo -e "\n${C_BOLD}Các mục cấu hình trong /etc/fstab:${C_RESET}"
    grep -E "cifs" /etc/fstab 2>/dev/null || echo "  (Chưa có cấu hình cifs nào trong fstab)"
}

unmount_smb_share() {
    check_root
    msg_step "HỦY KẾT NỐI (UNMOUNT) THƯ MỤC CHIA SẺ MẠNG"

    local mounted_points=()
    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            local mp
            mp=$(echo "$line" | awk '{print $3}')
            mounted_points+=("$mp")
        fi
    done < <(mount -t cifs 2>/dev/null)

    if [[ ${#mounted_points[@]} -eq 0 ]]; then
        msg_info "Không có thư mục CIFS/SMB nào đang kết nối."
        return 0
    fi

    echo -e "${C_BOLD}Chọn thư mục cần Unmount:${C_RESET}"
    for i in "${!mounted_points[@]}"; do
        local num=$((i + 1))
        echo "  $num) ${mounted_points[$i]}"
    done

    local choice
    prompt_with_default "Nhập số thứ tự" "1" choice
    local idx=$((choice - 1))

    if [[ $idx -lt 0 ]] || [[ $idx -ge ${#mounted_points[@]} ]]; then
        msg_err "Lựa chọn không hợp lệ."
        return 1
    fi

    local target_mp="${mounted_points[$idx]}"
    msg_info "Đang unmount: ${target_mp}..."
    if umount -l "$target_mp" 2>/dev/null || umount "$target_mp"; then
        msg_ok "Đã unmount thành công: ${target_mp}"

        if prompt_confirm "Bạn có muốn xóa cấu hình của thư mục này khỏi /etc/fstab?" "Y"; then
            sed -i "\|${target_mp}|d" /etc/fstab
            msg_ok "Đã dọn dẹp /etc/fstab."
        fi
    else
        msg_err "Không thể unmount ${target_mp}. Có thể đang có tiến trình truy cập file."
    fi
}

smb_file_share_menu() {
    while true; do
        echo -e "\n${C_BOLD}${C_BLUE}================================================================${C_RESET}"
        echo -e "${C_BOLD}${C_WHITE}       QUẢN LÝ THƯ MỤC CHIA SẺ MẠNG (WINDOWS SMB/CIFS)          ${C_RESET}"
        echo -e "${C_BOLD}${C_BLUE}================================================================${C_RESET}"
        echo " 1) Tra cứu thư mục chia sẻ trên Server (Browse SMB Shares)"
        echo " 2) Kết nối (Mount) Thư mục chia sẻ vào máy Zorin"
        echo " 3) Xem danh sách thư mục chia sẻ đang kết nối"
        echo " 4) Hủy kết nối (Unmount) Thư mục chia sẻ"
        echo " 5) Cài đặt / cập nhật các gói hỗ trợ SMB/CIFS"
        echo " 0) Quay lại Menu chính"
        echo "----------------------------------------------------------------"

        local sub_choice
        prompt_with_default "Chọn chức năng [0-5]" "1" sub_choice

        case "$sub_choice" in
            1) list_smb_shares_on_server ;;
            2) mount_smb_share ;;
            3) list_mounted_shares ;;
            4) unmount_smb_share ;;
            5) install_smb_dependencies ;;
            0) break ;;
            *) msg_err "Lựa chọn không hợp lệ." ;;
        esac
    done
}
