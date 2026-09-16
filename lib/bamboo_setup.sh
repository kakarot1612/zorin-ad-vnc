#!/usr/bin/env bash
# ==============================================================================
# Zorin OS AD Join & X11VNC Management Tool
# File: lib/bamboo_setup.sh
# Description: Automated System-wide Vietnamese Input Method (IBus-Bamboo) Setup
#              for ALL Active Directory Users on Zorin OS.
# ==============================================================================

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"

USER_INIT_SCRIPT="/usr/local/bin/zorin-bamboo-user-init.sh"
XDG_AUTOSTART_FILE="/etc/xdg/autostart/zorin-bamboo.desktop"
GSCHEMA_OVERRIDE="/usr/share/glib-2.0/schemas/99_zorin_bamboo.gschema.override"
PROFILE_ENV="/etc/profile.d/bamboo.sh"

install_bamboo_packages() {
    check_root
    msg_step "CÀI ĐẶT BỘ GÕ TIẾNG VIỆT IBUS-BAMBOO TỪ PPA CHÍNH THỨC"

    # Ensure software-properties-common is installed for add-apt-repository
    if ! command -v add-apt-repository >/dev/null 2>&1; then
        msg_info "Đang cài đặt software-properties-common..."
        apt-get update -qq || true
        apt-get install -y software-properties-common || true
    fi

    # Check if PPA is already added
    if ! grep -q "bamboo-engine/ibus-bamboo" /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null; then
        msg_info "Đang thêm PPA chính thức: ppa:bamboo-engine/ibus-bamboo..."
        add-apt-repository -y ppa:bamboo-engine/ibus-bamboo || {
            msg_warn "Không thể thêm PPA trực tiếp, thử tiếp tục với kho có sẵn..."
        }
    else
        msg_ok "PPA bamboo-engine/ibus-bamboo đã được cấu hình."
    fi

    msg_info "Đang cập nhật danh mục gói và cài đặt ibus-bamboo..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq || true

    local pkgs=(
        ibus-bamboo
        ibus
        ibus-gtk
        ibus-gtk3
        im-config
    )

    # Optional packages if available in distro
    for opt_pkg in ibus-gtk4 gir1.2-ibus-1.0; do
        if apt-cache show "$opt_pkg" >/dev/null 2>&1; then
            pkgs+=("$opt_pkg")
        fi
    done

    if apt-get install -y "${pkgs[@]}"; then
        msg_ok "Cài đặt thành công các gói IBus-Bamboo!"
        return 0
    else
        msg_err "Cài đặt ibus-bamboo thất bại. Vui lòng kiểm tra kết nối internet/apt."
        return 1
    fi
}

configure_system_environment() {
    check_root
    msg_step "CẤU HÌNH BIẾN MÔI TRƯỜNG BỘ GÕ TOÀN HỆ THỐNG"

    # 1. /etc/profile.d/bamboo.sh
    cat > "$PROFILE_ENV" <<'EOF'
# Zorin OS System-wide Vietnamese Input Method (IBus-Bamboo)
export GTK_IM_MODULE=ibus
export QT_IM_MODULE=ibus
export XMODIFIERS=@im=ibus
export IBUS_ENABLE_SYNC_MODE=1
EOF
    chmod 644 "$PROFILE_ENV"
    msg_ok "Đã tạo file cấu hình môi trường: ${PROFILE_ENV}"

    # 2. /etc/environment
    for var in "GTK_IM_MODULE=ibus" "QT_IM_MODULE=ibus" "XMODIFIERS=@im=ibus"; do
        local key="${var%%=*}"
        if grep -q "^${key}=" /etc/environment 2>/dev/null; then
            sed -i "s|^${key}=.*|${var}|" /etc/environment
        else
            echo "$var" >> /etc/environment
        fi
    done
    msg_ok "Đã cập nhật các biến môi trường vào /etc/environment"

    # 3. Set IBus as default via im-config
    if command -v im-config >/dev/null 2>&1; then
        im-config -n ibus 2>/dev/null || true
        msg_ok "Đã thiết lập im-config mặc định là: ibus"
    fi
}

configure_gnome_gschema_override() {
    check_root
    msg_step "CẤU HÌNH GSETTINGS SYSTEM-WIDE OVERRIDE CHO TOÀN BỘ USER"

    mkdir -p "$(dirname "$GSCHEMA_OVERRIDE")"

    # This ensures EVERY new or existing user that uses default GNOME schemas
    # gets US keyboard + Bamboo Vietnamese input source automatically!
    cat > "$GSCHEMA_OVERRIDE" <<'EOF'
[org.gnome.desktop.input-sources]
sources=[('xkb', 'us'), ('ibus', 'Bamboo')]
mru-sources=[('ibus', 'Bamboo'), ('xkb', 'us')]
show-all-sources=true

[desktop.ibus.general]
preload-engines=['Bamboo']
EOF
    chmod 644 "$GSCHEMA_OVERRIDE"

    msg_info "Đang biên dịch lại GLib schemas hệ thống..."
    if command -v glib-compile-schemas >/dev/null 2>&1; then
        glib-compile-schemas /usr/share/glib-2.0/schemas/
        msg_ok "Đã biên dịch lại schemas thành công với Bamboo làm nguồn nhập liệu mặc định!"
    else
        msg_warn "Lệnh glib-compile-schemas không khả dụng."
    fi
}

install_xdg_autostart_daemon() {
    check_root
    msg_step "CÀI ĐẶT SCRIPT AUTOSTART TOÀN CỤC CHO MỌI AD USER (XDG AUTOSTART)"

    # 1. Create the user initialization script
    cat > "$USER_INIT_SCRIPT" <<'EOF'
#!/usr/bin/env bash
# Zorin OS Bamboo User Session Initializer
# Run automatically on graphical session login for any user

# Wait a brief moment for GNOME session and D-Bus to be fully ready
sleep 2

# 1. Ensure IBus Daemon is running
if ! pgrep -u "$USER" -x ibus-daemon >/dev/null 2>&1; then
    ibus-daemon -drxR >/dev/null 2>&1 &
fi

# 2. Ensure Bamboo is present in user's GNOME input-sources
if command -v gsettings >/dev/null 2>&1; then
    current_sources=$(gsettings get org.gnome.desktop.input-sources sources 2>/dev/null || true)
    if [[ "$current_sources" != *"Bamboo"* ]]; then
        gsettings set org.gnome.desktop.input-sources sources "[('xkb', 'us'), ('ibus', 'Bamboo')]" 2>/dev/null || true
        gsettings set org.gnome.desktop.input-sources mru-sources "[('ibus', 'Bamboo'), ('xkb', 'us')]" 2>/dev/null || true
        gsettings set org.gnome.desktop.input-sources show-all-sources true 2>/dev/null || true
    fi
fi

# 3. Restart ibus engine cleanly if needed
if command -v ibus >/dev/null 2>&1; then
    ibus restart >/dev/null 2>&1 || true
fi
EOF
    chmod 755 "$USER_INIT_SCRIPT"
    msg_ok "Đã cài đặt User Initializer script vào: ${USER_INIT_SCRIPT}"

    # 2. Create XDG Autostart desktop entry for ALL users
    mkdir -p "$(dirname "$XDG_AUTOSTART_FILE")"
    cat > "$XDG_AUTOSTART_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=Zorin Bamboo Vietnamese Input Auto-Setup
Comment=Automatically configure IBus-Bamboo for any domain or local user
Exec=${USER_INIT_SCRIPT}
Terminal=false
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Phase=Application
EOF
    chmod 644 "$XDG_AUTOSTART_FILE"
    msg_ok "Đã cài đặt Autostart toàn hệ thống tại: ${XDG_AUTOSTART_FILE}"

    # 3. Also configure /etc/skel for new AD home directories created by pam_mkhomedir
    mkdir -p /etc/skel/.config/autostart
    cp "$XDG_AUTOSTART_FILE" /etc/skel/.config/autostart/zorin-bamboo.desktop 2>/dev/null || true
    msg_ok "Đã đồng bộ cấu hình vào /etc/skel cho các AD user mới."
}

apply_bamboo_to_existing_users() {
    msg_info "Đang quét và áp dụng cấu hình Bamboo cho các profile người dùng hiện có..."

    local count=0
    for home_dir in /home/*; do
        [[ ! -d "$home_dir" ]] && continue
        local user_name
        user_name=$(basename "$home_dir")

        # Skip non-user directories or root
        if ! id "$user_name" >/dev/null 2>&1; then
            # If domain user folder like user@domain.com
            local short_user
            short_user=$(echo "$user_name" | cut -d@ -f1)
            if id "$short_user" >/dev/null 2>&1; then
                user_name="$short_user"
            else
                continue
            fi
        fi

        count=$((count + 1))
        # Ensure autostart directory exists in user home
        mkdir -p "${home_dir}/.config/autostart"
        cp "$XDG_AUTOSTART_FILE" "${home_dir}/.config/autostart/zorin-bamboo.desktop" 2>/dev/null || true
        
        local user_uid user_gid
        user_uid=$(id -u "$user_name" 2>/dev/null)
        user_gid=$(id -g "$user_name" 2>/dev/null)
        if [[ -n "$user_uid" ]] && [[ -n "$user_gid" ]]; then
            chown -R "${user_uid}:${user_gid}" "${home_dir}/.config/autostart" 2>/dev/null || true
        fi
    done

    msg_ok "Đã cập nhật cấu hình Bamboo cho ${count} thư mục người dùng trên máy."
}

setup_bamboo_system_wide() {
    check_root
    msg_step "BẮT ĐẦU CÀI ĐẶT & CẤU HÌNH BAMBOO TOÀN HỆ THỐNG CHO MỌI AD USER"

    # Step 1: Install packages
    if ! install_bamboo_packages; then
        msg_err "Quá trình cài đặt gói IBus-Bamboo thất bại."
        return 1
    fi

    # Step 2: System Environment
    configure_system_environment

    # Step 3: GSchema Override
    configure_gnome_gschema_override

    # Step 4: XDG Autostart
    install_xdg_autostart_daemon

    # Step 5: Existing users
    apply_bamboo_to_existing_users

    msg_ok "========================================================="
    msg_ok "HOÀN TẤT THIẾT LẬP BỘ GÕ TIẾNG VIỆT BAMBOO TOÀN HỆ THỐNG!"
    msg_ok "Từ bây giờ, BẤT KỲ user Active Directory nào đăng nhập vào"
    msg_ok "Zorin Desktop đều sẽ TỰ ĐỘNG có sẵn bộ gõ tiếng Việt Bamboo!"
    msg_ok "Phím tắt chuyển đổi mặc định: Super + Space (Phím Windows + Cách)"
    msg_ok "========================================================="
}

show_bamboo_status() {
    msg_step "KIỂM TRA TRẠNG THÁI BỘ GÕ TIẾNG VIỆT BAMBOO"

    if dpkg -s ibus-bamboo >/dev/null 2>&1; then
        local ver
        ver=$(dpkg-query -W -f='${Version}' ibus-bamboo 2>/dev/null)
        msg_ok "Gói ibus-bamboo: ĐÃ CÀI ĐẶT (Phiên bản: ${ver})"
    else
        msg_warn "Gói ibus-bamboo: CHƯA CÀI ĐẶT"
    fi

    if [[ -f "$PROFILE_ENV" ]]; then
        msg_ok "Biến môi trường toàn hệ thống: ĐÃ CẤU HÌNH (${PROFILE_ENV})"
    else
        msg_warn "Biến môi trường toàn hệ thống: CHƯA CẤU HÌNH"
    fi

    if [[ -f "$GSCHEMA_OVERRIDE" ]]; then
        msg_ok "GSettings Schema Override: ĐÃ CẤU HÌNH (${GSCHEMA_OVERRIDE})"
    else
        msg_warn "GSettings Schema Override: CHƯA CẤU HÌNH"
    fi

    if [[ -f "$XDG_AUTOSTART_FILE" ]]; then
        msg_ok "XDG Autostart toàn cục: ĐÃ CẤU HÌNH (${XDG_AUTOSTART_FILE})"
    else
        msg_warn "XDG Autostart toàn cục: CHƯA CẤU HÌNH"
    fi

    local ibus_procs
    ibus_procs=$(pgrep -a ibus-daemon 2>/dev/null || true)
    if [[ -n "$ibus_procs" ]]; then
        msg_ok "Tiến trình ibus-daemon đang chạy:"
        echo -e "${C_CYAN}${ibus_procs}${C_RESET}"
    else
        msg_info "Tiến trình ibus-daemon hiện chưa chạy trong session này."
    fi
}

bamboo_management_menu() {
    while true; do
        echo -e "\n${C_BOLD}${C_BLUE}================================================================${C_RESET}"
        echo -e "${C_BOLD}${C_WHITE}       QUẢN LÝ BỘ GÕ TIẾNG VIỆT IBUS-BAMBOO (ALL AD USERS)      ${C_RESET}"
        echo -e "${C_BOLD}${C_BLUE}================================================================${C_RESET}"
        echo " 1) Cài đặt và Cấu hình Bamboo toàn hệ thống (Tự động cho MỌI user AD)"
        echo " 2) Kiểm tra trạng thái Bamboo trên hệ thống"
        echo " 3) Áp dụng lại cấu hình Bamboo cho các thư mục Home hiện có"
        echo " 4) Biên dịch lại GSettings schemas (glib-compile-schemas)"
        echo " 0) Quay lại Menu chính"
        echo "----------------------------------------------------------------"

        local b_choice
        prompt_with_default "Chọn chức năng [0-4]" "1" b_choice

        case "$b_choice" in
            1) setup_bamboo_system_wide ;;
            2) show_bamboo_status ;;
            3) apply_bamboo_to_existing_users ;;
            4) configure_gnome_gschema_override ;;
            0) break ;;
            *) msg_err "Lựa chọn không hợp lệ." ;;
        esac
    done
}
