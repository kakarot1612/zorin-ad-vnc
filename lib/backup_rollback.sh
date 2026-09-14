#!/usr/bin/env bash
# ==============================================================================
# Zorin OS AD Join & X11VNC Management Tool
# File: lib/backup_rollback.sh
# Description: Configuration backup, snapshot listing, and restoration (rollback).
# ==============================================================================

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"

get_current_backup_dir() {
    local ts
    ts=$(date '+%Y%m%d_%H%M%S')
    echo "${BACKUP_DIR}/${ts}"
}

backup_file() {
    local src_file="$1"
    local tag="${2:-auto}"

    if [[ ! -f "$src_file" ]]; then
        return 0
    fi

    local ts
    ts=$(date '+%Y%m%d_%H%M%S')
    local snap_dir="${BACKUP_DIR}/${ts}_${tag}"
    mkdir -p "$snap_dir"

    # Recreate relative path or store with base name
    local fname
    fname=$(basename "$src_file")
    cp "$src_file" "${snap_dir}/${fname}"
    echo "$src_file" > "${snap_dir}/${fname}.orig_path"
    chmod 600 "${snap_dir}/${fname}" 2>/dev/null || true

    msg_ok "Đã sao lưu ${src_file} -> ${snap_dir}/${fname}"
    log_message "BACKUP" "Created backup of $src_file at $snap_dir"
}

create_full_backup() {
    check_root
    msg_step "TẠO BẢN SAO LƯU TOÀN DIỆN CẤU HÌNH HỆ THỐNG"

    local ts
    ts=$(date '+%Y%m%d_%H%M%S')
    local snap_dir="${BACKUP_DIR}/full_${ts}"
    mkdir -p "$snap_dir"

    local files=(
        "/etc/sssd/sssd.conf"
        "/etc/gdm3/custom.conf"
        "/etc/gdm/custom.conf"
        "/etc/pam.d/common-session"
        "/etc/systemd/system/${SYSTEMD_SERVICE}"
        "${VNC_CONFIG_DIR}/zorin-vnc.conf"
    )

    local backed_count=0
    for f in "${files[@]}"; do
        if [[ -f "$f" ]]; then
            local fname
            fname=$(basename "$f")
            cp "$f" "${snap_dir}/${fname}"
            echo "$f" > "${snap_dir}/${fname}.orig_path"
            backed_count=$((backed_count + 1))
        fi
    done

    msg_ok "Đã sao lưu ${backed_count} file cấu hình vào: ${snap_dir}"
    log_message "BACKUP" "Full backup completed in $snap_dir"
}

list_backups() {
    msg_step "DANH SÁCH CÁC BẢN SAO LƯU (BACKUP SNAPSHOTS)"

    if [[ ! -d "$BACKUP_DIR" ]]; then
        msg_info "Thư mục sao lưu $BACKUP_DIR chưa tồn tại."
        return 0
    fi

    local snapshots
    snapshots=$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d | sort -r)

    if [[ -z "$snapshots" ]]; then
        msg_info "Chưa có bản sao lưu nào."
        return 0
    fi

    local idx=1
    while IFS= read -r dir; do
        local dname
        dname=$(basename "$dir")
        local fcount
        fcount=$(find "$dir" -type f ! -name "*.orig_path" | wc -l)
        echo -e "  ${C_BOLD}[$idx]${C_RESET} ${C_CYAN}${dname}${C_RESET} (${fcount} files) -> ${dir}"
        idx=$((idx + 1))
    done <<< "$snapshots"
}

rollback_configuration() {
    check_root
    msg_step "KHÔI PHỤC CẤU HÌNH TỪ BẢN SAO LƯU (ROLLBACK)"

    if [[ ! -d "$BACKUP_DIR" ]]; then
        msg_err "Không tìm thấy thư mục sao lưu $BACKUP_DIR!"
        return 1
    fi

    local snapshots=()
    while IFS= read -r dir; do
        [[ -n "$dir" ]] && snapshots+=("$dir")
    done < <(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d | sort -r)

    if [[ ${#snapshots[@]} -eq 0 ]]; then
        msg_err "Không có bản sao lưu nào trong hệ thống để khôi phục."
        return 1
    fi

    echo -e "${C_BOLD}Chọn bản sao lưu để khôi phục:${C_RESET}"
    for i in "${!snapshots[@]}"; do
        local num=$((i + 1))
        local dname
        dname=$(basename "${snapshots[$i]}")
        echo "  $num) $dname"
    done

    local choice
    prompt_with_default "Nhập số thứ tự bản sao lưu" "1" choice
    local selected_idx=$((choice - 1))

    if [[ $selected_idx -lt 0 ]] || [[ $selected_idx -ge ${#snapshots[@]} ]]; then
        msg_err "Lựa chọn không hợp lệ."
        return 1
    fi

    local target_dir="${snapshots[$selected_idx]}"
    echo -e "Bản sao lưu đã chọn: ${C_YELLOW}${target_dir}${C_RESET}"

    if ! prompt_confirm "Bạn có chắc chắn muốn khôi phục lại cấu hình từ bản này?" "N"; then
        msg_info "Đã hủy thao tác khôi phục."
        return 0
    fi

    # Restore files
    msg_info "Đang phục hồi các file cấu hình..."
    for path_file in "$target_dir"/*.orig_path; do
        [[ ! -f "$path_file" ]] && continue
        local orig_path
        orig_path=$(cat "$path_file")
        local base
        base=$(basename "$path_file" .orig_path)
        local backup_src="${target_dir}/${base}"

        if [[ -f "$backup_src" ]]; then
            msg_info "Khôi phục: ${orig_path}"
            mkdir -p "$(dirname "$orig_path")"
            cp "$backup_src" "$orig_path"

            # Re-apply strict permissions if sssd.conf
            if [[ "$orig_path" == "/etc/sssd/sssd.conf" ]]; then
                chmod 600 "$orig_path"
                chown root:root "$orig_path"
            fi
        fi
    done

    # Restart services
    msg_info "Đang nạp lại và khởi động lại dịch vụ liên quan..."
    systemctl daemon-reload
    systemctl restart sssd 2>/dev/null || true

    msg_ok "========================================================="
    msg_ok "KHÔI PHỤC CẤU HÌNH THÀNH CÔNG TỪ BẢN SAO LƯU!"
    msg_ok "========================================================="
    log_message "SUCCESS" "Restored configuration from $target_dir"
}
