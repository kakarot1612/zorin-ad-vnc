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

    # 1. Probe Server Domain / OS information
    echo ""
    msg_info "Đang thăm dò thông tin máy chủ ${server_host}..."
    local probe_info
    probe_info=$(smbclient -N -L "$server_host" --option="client min protocol=SMB2" 2>&1 || true)
    local srv_domain srv_os
    srv_domain=$(echo "$probe_info" | grep -o -E 'Domain=\[[^]]+\]' | head -n 1 | cut -d'[' -f2 | cut -d']' -f1)
    srv_os=$(echo "$probe_info" | grep -o -E 'OS=\[[^]]+\]' | head -n 1 | cut -d'[' -f2 | cut -d']' -f1)

    if [[ -n "$srv_domain" ]]; then
        echo -e "   Phát hiện Server Domain / Workgroup: ${C_GREEN}${srv_domain}${C_RESET}"
    fi
    if [[ -n "$srv_os" ]]; then
        echo -e "   Hệ điều hành Server                 : ${C_CYAN}${srv_os}${C_RESET}"
    fi

    if [[ "$auth_choice" == "2" ]]; then
        msg_info "Đang tra cứu danh sách share từ ${server_host} với quyền Guest..."
        echo "$probe_info"
    else
        echo ""
        local raw_user
        prompt_with_default "Tài khoản (VD: tom hoặc tom@bestpacific.com)" "${SUDO_USER:-$USER}" raw_user
        local clean_user clean_domain
        normalize_ad_user_and_domain "$raw_user" "$domain" clean_user clean_domain

        local workgroup
        workgroup=$(get_ad_workgroup "$clean_domain")
        # If server reported a specific domain, consider it
        local target_wg="${srv_domain:-$workgroup}"

        local ad_pass=""
        prompt_secure_password "Mật khẩu cho [${clean_user}]" ad_pass false

        echo ""
        msg_info "Đang kết nối tới ${server_host}..."

        # Define candidate authentication strategies in order
        local auth_attempts=(
            "-W ${target_wg} -U ${clean_user}"
            "-U ${clean_user}@${clean_domain}"
            "-W ${workgroup} -U ${clean_user}"
            "-U ${clean_user}"
            "-W WORKGROUP -U ${clean_user}"
        )

        local smb_out="" smb_success=false
        for strat in "${auth_attempts[@]}"; do
            # Pipe password safely to stdin to prevent character escaping issues
            # shellcheck disable=SC2086
            smb_out=$(printf "%s\n" "$ad_pass" | smbclient -L "$server_host" $strat --option="client min protocol=SMB2" 2>&1)
            local exit_code=$?

            if [[ $exit_code -eq 0 ]] && [[ "$smb_out" =~ "Sharename" ]]; then
                smb_success=true
                msg_ok "Xác thực thành công với chế độ: ${strat}!"
                break
            fi

            # If not a logon failure (e.g. access denied to IPC$ or network issue), break early
            if [[ "$smb_out" != *"NT_STATUS_LOGON_FAILURE"* ]] && [[ "$smb_out" != *"NT_STATUS_UNSUCCESSFUL"* ]] && [[ $exit_code -eq 0 ]]; then
                smb_success=true
                break
            fi
        done

        unset ad_pass

        echo "--------------------------------------------------------"
        echo "$smb_out"
        echo "--------------------------------------------------------"

        if [[ "$smb_success" == "true" ]]; then
            msg_ok "Tra cứu danh sách thư mục chia sẻ thành công!"
        else
            msg_err "Xác thực không thành công (NT_STATUS_LOGON_FAILURE)."
            echo -e "${C_YELLOW}Gợi ý kiểm tra:${C_RESET}"
            echo -e "  1. Kiểm tra lại mật khẩu (chú ý phím Caps Lock / bộ gõ tiếng Việt)."
            echo -e "  2. Tài khoản ${clean_user} trên server 10.0.60.30 là tài khoản Domain hay tài khoản Local của riêng máy đó?"
            echo -e "  3. Kiểm tra xem tài khoản có bị khóa (Account locked) hoặc hết hạn trên AD không."
        fi
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

create_desktop_share_shortcut() {
    check_root
    msg_step "TẠO LỐI TẮT TRUY CẬP NHANH (SINGLE SIGN-ON - KHÔNG CẦN NHẬP MẬT KHẨU)"

    install_smb_dependencies || return 1

    local server_host
    prompt_with_default "Nhập IP hoặc Hostname của File Server" "10.0.60.30" server_host

    local share_name
    prompt_with_default "Nhập Tên Thư Mục Chia Sẻ" "BPVN-Fileserver" share_name

    local smb_url="smb://${server_host}/${share_name}"

    # Target user info
    local target_user="${SUDO_USER:-$USER}"
    local user_home
    user_home=$(getent passwd "$target_user" 2>/dev/null | cut -d: -f6)
    user_home="${user_home:-/home/$target_user}"

    local user_uid user_gid
    user_uid=$(id -u "$target_user" 2>/dev/null || echo "1000")
    user_gid=$(id -g "$target_user" 2>/dev/null || echo "1000")

    # 1. Create Desktop shortcut for current user
    for d_dir in "${user_home}/Desktop" "${user_home}/Bàn làm việc"; do
        if [[ -d "$d_dir" ]]; then
            local shortcut_file="${d_dir}/${share_name}.desktop"
            cat > "$shortcut_file" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=${share_name}
Comment=Thư mục chia sẻ ${smb_url}
Exec=nautilus ${smb_url}
Icon=folder-remote
Terminal=false
Categories=Network;FileTransfer;
EOF
            chmod +x "$shortcut_file"
            chown "${user_uid}:${user_gid}" "$shortcut_file"
            # Mark desktop file as trusted so GNOME doesn't prompt Untrusted Desktop File
            sudo -u "$target_user" gio set "$shortcut_file" metadata::trusted true 2>/dev/null || true
            gio set "$shortcut_file" metadata::trusted true 2>/dev/null || true
            msg_ok "Đã tạo lối tắt trên màn hình Desktop của [${target_user}]: ${shortcut_file}"
        fi
    done

    # 2. Add bookmark to Nautilus sidebar for current user
    local gtk_bookmarks="${user_home}/.config/gtk-3.0/bookmarks"
    mkdir -p "$(dirname "$gtk_bookmarks")"
    if ! grep -q "$smb_url" "$gtk_bookmarks" 2>/dev/null; then
        echo "${smb_url} ${share_name}" >> "$gtk_bookmarks"
        chown -R "${user_uid}:${user_gid}" "${user_home}/.config/gtk-3.0"
        msg_ok "Đã thêm thư mục [${share_name}] vào thanh bên (Sidebar) của Files (Nautilus)!"
    fi

    # 3. Synchronize to /etc/skel so ALL future AD users get this shortcut automatically
    mkdir -p /etc/skel/Desktop /etc/skel/.config/gtk-3.0
    cat > "/etc/skel/Desktop/${share_name}.desktop" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=${share_name}
Comment=Thư mục chia sẻ ${smb_url}
Exec=nautilus ${smb_url}
Icon=folder-remote
Terminal=false
Categories=Network;FileTransfer;
EOF
    chmod +x "/etc/skel/Desktop/${share_name}.desktop"
    if ! grep -q "$smb_url" "/etc/skel/.config/gtk-3.0/bookmarks" 2>/dev/null; then
        echo "${smb_url} ${share_name}" >> "/etc/skel/.config/gtk-3.0/bookmarks"
    fi
    msg_ok "Đã đồng bộ lối tắt vào /etc/skel cho TOÀN BỘ user AD đăng nhập sau này!"

    msg_ok "========================================================="
    msg_ok "TẠO LỐI TẮT FILE SERVER THÀNH CÔNG!"
    msg_ok "User chỉ cần: Nhấp đúp vào icon '${share_name}' ngoài Desktop"
    msg_ok "hoặc bấm vào sidebar trong Files (Nautilus) để mở thư mục."
    msg_ok "Hệ thống tự dùng vé Kerberos của AD để vào thẳng (GIỐNG HỆT WINDOWS)!"
    msg_ok "========================================================="
}

smb_file_share_menu() {
    while true; do
        echo -e "\n${C_BOLD}${C_BLUE}================================================================${C_RESET}"
        echo -e "${C_BOLD}${C_WHITE}       QUẢN LÝ THƯ MỤC CHIA SẺ MẠNG (WINDOWS SMB/CIFS)          ${C_RESET}"
        echo -e "${C_BOLD}${C_BLUE}================================================================${C_RESET}"
        echo " 1) Tra cứu thư mục chia sẻ trên Server (Browse SMB Shares)"
        echo " 2) Tạo Lối tắt Desktop & Sidebar (Single Sign-On - Không cần gõ mật khẩu)"
        echo " 3) Kết nối (Mount) Thư mục chia sẻ cố định vào máy Zorin (/mnt/shares)"
        echo " 4) Xem danh sách thư mục chia sẻ đang kết nối"
        echo " 5) Hủy kết nối (Unmount) Thư mục chia sẻ"
        echo " 6) Cài đặt / cập nhật các gói hỗ trợ SMB/CIFS"
        echo " 0) Quay lại Menu chính"
        echo "----------------------------------------------------------------"

        local sub_choice
        prompt_with_default "Chọn chức năng [0-6]" "2" sub_choice

        case "$sub_choice" in
            1) list_smb_shares_on_server ;;
            2) create_desktop_share_shortcut ;;
            3) mount_smb_share ;;
            4) list_mounted_shares ;;
            5) unmount_smb_share ;;
            6) install_smb_dependencies ;;
            0) break ;;
            *) msg_err "Lựa chọn không hợp lệ." ;;
        esac
    done
}
