#!/usr/bin/env bash
# ==============================================================================
# Zorin OS AD Join & X11VNC Management Tool
# File: lib/pam_homedir.sh
# Description: PAM configuration for auto-mkhomedir and Repair Tool for Home Directories.
# ==============================================================================

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/backup_rollback.sh
source "$LIB_DIR/backup_rollback.sh"

PAM_COMMON_SESSION="/etc/pam.d/common-session"

configure_pam_mkhomedir() {
    check_root
    msg_step "CẤU HÌNH PAM TỰ ĐỘNG TẠO HOME DIRECTORY (PAM_MKHOMEDIR)"

    if [[ ! -f "$PAM_COMMON_SESSION" ]]; then
        msg_err "Không tìm thấy file $PAM_COMMON_SESSION!"
        return 1
    fi

    # Backup file
    backup_file "$PAM_COMMON_SESSION" "pam"

    # Check if pam_mkhomedir is already enabled
    if grep -q "pam_mkhomedir.so" "$PAM_COMMON_SESSION"; then
        msg_ok "pam_mkhomedir.so đã được cấu hình trong $PAM_COMMON_SESSION."
    else
        msg_info "Đang thêm mô-đun pam_mkhomedir vào $PAM_COMMON_SESSION..."
        # Add pam_mkhomedir with skel=/etc/skel and umask=0077 (giving 700 to user home dir)
        echo "session optional        pam_mkhomedir.so skel=/etc/skel umask=0077" >> "$PAM_COMMON_SESSION"
        msg_ok "Đã thêm thành công pam_mkhomedir.so vào $PAM_COMMON_SESSION."
    fi

    # Alternatively trigger pam-auth-update if available
    if command -v pam-auth-update >/dev/null 2>&1; then
        pam-auth-update --enable mkhomedir 2>/dev/null || true
    fi

    return 0
}

repair_user_home_dir() {
    check_root
    msg_step "CÔNG CỤ SỬA LỖI PHÂN QUYỀN HOME DIRECTORY CHO AD USER"

    local target_user="$1"
    if [[ -z "$target_user" ]]; then
        prompt_with_default "Nhập tên tài khoản AD cần kiểm tra/sửa (VD: username)" "" target_user
    fi

    if [[ -z "$target_user" ]]; then
        msg_warn "Chưa nhập username. Bắt đầu quét tự động các thư mục AD trong /home..."
        scan_and_fix_ad_homedirs
        return 0
    fi

    # 1. Lookup user via getent/id
    msg_info "Đang tra cứu thông tin tài khoản: ${target_user}..."
    local user_entry
    user_entry=$(getent passwd "$target_user" 2>/dev/null)

    if [[ -z "$user_entry" ]]; then
        msg_err "Không tìm thấy user '${target_user}' qua SSSD/NSS. Vui lòng kiểm tra lại tên tài khoản hoặc kết nối AD."
        return 1
    fi

    # Extract user information dynamically without hard-coding
    local homedir
    homedir=$(echo "$user_entry" | cut -d: -f6)
    local uid
    uid=$(id -u "$target_user" 2>/dev/null)
    local primary_gid
    primary_gid=$(id -g "$target_user" 2>/dev/null)
    local primary_group
    primary_group=$(id -gn "$target_user" 2>/dev/null || echo "$primary_gid")

    echo -e "   User:          ${C_CYAN}${target_user}${C_RESET}"
    echo -e "   UID:           ${C_CYAN}${uid}${C_RESET}"
    echo -e "   Primary Group: ${C_CYAN}${primary_group} (${primary_gid})${C_RESET}"
    echo -e "   Home Dir:      ${C_CYAN}${homedir}${C_RESET}"

    # 2. Check and fix Home Directory
    if [[ ! -d "$homedir" ]]; then
        msg_info "Thư mục $homedir chưa tồn tại. Đang khởi tạo từ /etc/skel..."
        mkdir -p "$homedir"
        if [[ -d /etc/skel ]]; then
            cp -rT /etc/skel "$homedir" 2>/dev/null || true
        fi
    fi

    local current_owner
    current_owner=$(stat -c "%U:%G" "$homedir" 2>/dev/null || stat -c "%u:%g" "$homedir")
    local current_perms
    current_perms=$(stat -c "%a" "$homedir" 2>/dev/null)

    echo -e "   Chủ sở hữu hiện tại: ${C_YELLOW}${current_owner}${C_RESET}"
    echo -e "   Quyền hạn hiện tại:  ${C_YELLOW}${current_perms}${C_RESET}"

    # Fix ownership and permissions
    msg_info "Đang sửa quyền: chown -R ${target_user}:${primary_group} ${homedir}..."
    chown -R "${uid}:${primary_gid}" "$homedir"

    msg_info "Đang đặt quyền truy cập an toàn: chmod 700 ${homedir}..."
    chmod 700 "$homedir"

    # Ensure critical subdirectories for Xorg exist and have correct permissions
    mkdir -p "${homedir}/.local/share/xorg" \
             "${homedir}/.local/share/keyrings" \
             "${homedir}/.local/state/wireplumber" \
             "${homedir}/.config" 2>/dev/null || true

    chown -R "${uid}:${primary_gid}" "${homedir}/.local" "${homedir}/.config" 2>/dev/null || true
    chmod 700 "${homedir}/.local" "${homedir}/.config" 2>/dev/null || true

    msg_ok "========================================================="
    msg_ok "ĐÃ SỬA XONG PHÂN QUYỀN HOME DIRECTORY CHO ${target_user}!"
    msg_ok "Home Directory: ${homedir} (Owner: ${target_user}, Chmod: 700)"
    msg_ok "========================================================="
    return 0
}

scan_and_fix_ad_homedirs() {
    msg_info "Quét tất cả thư mục có dạng *@* trong /home..."
    local count=0
    for dir in /home/*@*; do
        [[ ! -d "$dir" ]] && continue
        count=$((count + 1))
        local owner
        owner=$(stat -c "%U" "$dir" 2>/dev/null)
        local base
        base=$(basename "$dir")
        local username
        username=$(echo "$base" | cut -d@ -f1)

        echo -e "Phát hiện: ${C_WHITE}${dir}${C_RESET} (Owner hiện tại: ${C_YELLOW}${owner}${C_RESET})"
        if [[ "$owner" == "root" ]]; then
            msg_warn "Thư mục $dir đang bị chiếm quyền bởi root! Đang tiến hành sửa..."
            repair_user_home_dir "$username"
        else
            msg_ok "Thư mục $dir đã có chủ sở hữu hợp lệ (${owner})."
        fi
    done

    if [[ $count -eq 0 ]]; then
        msg_info "Không tìm thấy thư mục người dùng AD dạng /home/*@* nào trên máy."
    fi
}
