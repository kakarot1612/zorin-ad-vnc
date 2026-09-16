#!/usr/bin/env bash
# ==============================================================================
# Zorin OS AD Join & Enterprise Management Tool
# File: lib/app_installer.sh
# Description: Install Essential Enterprise Apps (Chrome, Zalo, WeChat, UltraViewer,
#              Chinese Input Method, Chinese Fonts, Vietnamese Bamboo, and Desktop Shortcuts).
# ==============================================================================

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/bamboo_setup.sh
source "$LIB_DIR/bamboo_setup.sh" 2>/dev/null || true

create_app_icons() {
    mkdir -p /usr/share/pixmaps 2>/dev/null || true

    # 1. Zalo SVG Icon
    if [[ ! -f /usr/share/pixmaps/zalo.svg ]]; then
        cat > /usr/share/pixmaps/zalo.svg <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128">
  <rect width="128" height="128" rx="28" fill="#0068FF"/>
  <path d="M28 88h36l-32-44h32v8H36l32 44H28z" fill="#FFF"/>
  <circle cx="82" cy="62" r="16" fill="none" stroke="#FFF" stroke-width="8"/>
  <rect x="94" y="46" width="8" height="32" fill="#FFF" rx="4"/>
  <circle cx="68" cy="42" r="6" fill="#FFF"/>
</svg>
EOF
        chmod 644 /usr/share/pixmaps/zalo.svg
    fi

    # 2. WeChat SVG Icon
    if [[ ! -f /usr/share/pixmaps/wechat.svg ]]; then
        cat > /usr/share/pixmaps/wechat.svg <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128">
  <rect width="128" height="128" rx="28" fill="#07C160"/>
  <!-- Big Bubble -->
  <path d="M52 28c-19.8 0-36 13.4-36 30 0 9.2 5 17.5 12.8 23.1L24 93l14.2-7.1c4.2 1.3 8.8 2.1 13.8 2.1 1.8 0 3.6-.1 5.3-.4C56 83.2 55 78.2 55 73c0-16.6 15.7-30 35-30 1.2 0 2.4.1 3.5.2C89.3 34.6 72 28 52 28z" fill="#FFF"/>
  <circle cx="39" cy="52" r="4" fill="#07C160"/>
  <circle cx="65" cy="52" r="4" fill="#07C160"/>
  <!-- Small Bubble -->
  <path d="M88 47c-16 0-29 11.2-29 25s13 25 29 25c3.8 0 7.4-.7 10.6-1.9L108 99l-2.6-7.8c5.4-4.5 8.6-10.8 8.6-17.7 0-13.8-13-26.5-26-26.5z" fill="#FFF"/>
  <circle cx="79" cy="68" r="3.5" fill="#07C160"/>
  <circle cx="97" cy="68" r="3.5" fill="#07C160"/>
</svg>
EOF
        chmod 644 /usr/share/pixmaps/wechat.svg
    fi

    # 3. UltraViewer SVG Icon
    if [[ ! -f /usr/share/pixmaps/ultraviewer.svg ]]; then
        cat > /usr/share/pixmaps/ultraviewer.svg <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128">
  <rect width="128" height="128" rx="28" fill="#FF5722"/>
  <!-- Monitor screen -->
  <rect x="24" y="24" width="80" height="56" rx="6" fill="#FFF"/>
  <rect x="30" y="30" width="68" height="44" rx="4" fill="#1E88E5"/>
  <!-- Stand -->
  <path d="M54 80h20v14H54zM40 94h48v6H40z" fill="#FFF"/>
  <!-- Remote Arrow inside screen -->
  <path d="M48 44l20 10-20 10z" fill="#FFD54F"/>
  <circle cx="76" cy="52" r="8" fill="#FFF"/>
</svg>
EOF
        chmod 644 /usr/share/pixmaps/ultraviewer.svg
    fi
}

install_chrome() {
    check_root
    msg_step "CÀI ĐẶT TRÌNH DUYỆT GOOGLE CHROME"

    if command -v google-chrome >/dev/null 2>&1 || command -v google-chrome-stable >/dev/null 2>&1; then
        msg_ok "Google Chrome đã được cài đặt trên hệ thống."
        export_single_desktop_shortcut "/usr/share/applications/google-chrome.desktop"
        return 0
    fi

    msg_info "Đang tải gói cài đặt Google Chrome Stable chính thức từ Google..."
    local chrome_deb="/tmp/google-chrome-stable_current_amd64.deb"
    if wget -q --show-progress -O "$chrome_deb" "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"; then
        msg_info "Đang cài đặt Google Chrome..."
        export DEBIAN_FRONTEND=noninteractive
        if apt-get install -y "$chrome_deb" >/dev/null 2>&1; then
            msg_ok "Cài đặt Google Chrome thành công!"
            rm -f "$chrome_deb"
            export_single_desktop_shortcut "/usr/share/applications/google-chrome.desktop"
            return 0
        else
            apt-get -f install -y >/dev/null 2>&1 || true
            msg_ok "Đã sửa lỗi phụ thuộc và cài đặt Google Chrome thành công!"
            rm -f "$chrome_deb"
            export_single_desktop_shortcut "/usr/share/applications/google-chrome.desktop"
            return 0
        fi
    else
        msg_err "Tải gói Google Chrome thất bại. Vui lòng kiểm tra kết nối Internet."
        return 1
    fi
}

install_zalo() {
    check_root
    msg_step "CÀI ĐẶT ỨNG DỤNG ZALO DESKTOP"

    create_app_icons

    # Ensure Google Chrome is installed for standalone app mode
    if ! command -v google-chrome >/dev/null 2>&1 && ! command -v google-chrome-stable >/dev/null 2>&1; then
        msg_info "Zalo Desktop yêu cầu trình duyệt Web nền tảng. Đang cài đặt Google Chrome..."
        install_chrome || true
    fi

    local chrome_bin="google-chrome"
    command -v google-chrome-stable >/dev/null 2>&1 && chrome_bin="google-chrome-stable"

    msg_info "Đang tạo bộ khởi chạy Zalo Desktop tiêu chuẩn..."
    cat > /usr/share/applications/zalo.desktop <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Zalo
Comment=Ứng dụng nhắn tin Zalo Doanh nghiệp
Exec=${chrome_bin} --app=https://chat.zalo.me/ --class=Zalo --name=Zalo
Icon=/usr/share/pixmaps/zalo.svg
Terminal=false
Categories=Network;InstantMessaging;Chat;Office;
StartupWMClass=chat.zalo.me
StartupNotify=true
EOF
    chmod 644 /usr/share/applications/zalo.desktop

    # Wrapper command /usr/local/bin/zalo
    cat > /usr/local/bin/zalo <<EOF
#!/usr/bin/env bash
exec ${chrome_bin} --app=https://chat.zalo.me/ --class=Zalo "\$@"
EOF
    chmod 755 /usr/local/bin/zalo

    export_single_desktop_shortcut "/usr/share/applications/zalo.desktop"
    msg_ok "Cài đặt Zalo Desktop thành công! Biểu tượng đã được xuất ra màn hình."
}

install_wechat() {
    check_root
    msg_step "CÀI ĐẶT ỨNG DỤNG WECHAT (微信)"

    create_app_icons

    # Ensure Google Chrome is installed for standalone app mode
    if ! command -v google-chrome >/dev/null 2>&1 && ! command -v google-chrome-stable >/dev/null 2>&1; then
        install_chrome || true
    fi

    local chrome_bin="google-chrome"
    command -v google-chrome-stable >/dev/null 2>&1 && chrome_bin="google-chrome-stable"

    msg_info "Đang tạo bộ khởi chạy WeChat Desktop tiêu chuẩn..."
    cat > /usr/share/applications/wechat.desktop <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=WeChat
GenericName=WeChat (微信)
Comment=Tencent WeChat Messaging Client
Exec=${chrome_bin} --app=https://wx.qq.com/ --class=WeChat --name=WeChat
Icon=/usr/share/pixmaps/wechat.svg
Terminal=false
Categories=Network;InstantMessaging;Chat;
StartupWMClass=wx.qq.com
StartupNotify=true
EOF
    chmod 644 /usr/share/applications/wechat.desktop

    # Wrapper command /usr/local/bin/wechat
    cat > /usr/local/bin/wechat <<EOF
#!/usr/bin/env bash
exec ${chrome_bin} --app=https://wx.qq.com/ --class=WeChat "\$@"
EOF
    chmod 755 /usr/local/bin/wechat

    export_single_desktop_shortcut "/usr/share/applications/wechat.desktop"
    msg_ok "Cài đặt WeChat Desktop thành công! Biểu tượng đã được xuất ra màn hình."
}

install_ultraviewer() {
    check_root
    msg_step "CÀI ĐẶT ĐIỀU KHIỂN TỪ XA ULTRAVIEWER (QUA WINE)"

    create_app_icons

    # 1. Install Wine
    msg_info "Kiểm tra và cài đặt Wine để chạy UltraViewer..."
    export DEBIAN_FRONTEND=noninteractive
    dpkg --add-architecture i386 2>/dev/null || true
    apt-get update -qq || true
    apt-get install -y wine wine64 winetricks wget libnotify-bin >/dev/null 2>&1 || true

    # 2. Download UltraViewer installer to permanent location /opt/ultraviewer
    mkdir -p /opt/ultraviewer
    local uv_exe="/opt/ultraviewer/UltraViewer_setup.exe"
    msg_info "Đang tải bộ cài đặt UltraViewer chính thức..."
    if [[ ! -f "$uv_exe" ]]; then
        wget -q --show-progress -O "$uv_exe" "https://ultraviewer.net/vi/UltraViewer_setup_6.6_vi.exe" || \
        wget -q --show-progress -O "$uv_exe" "https://ultraviewer.net/en/UltraViewer_setup_6.6_en.exe" || true
    fi
    chmod 644 "$uv_exe" 2>/dev/null || true

    # 3. Create persistent wrapper script
    cat > /usr/local/bin/ultraviewer <<'EOF'
#!/usr/bin/env bash
# UltraViewer Multi-user Launcher for Zorin OS
export WINEPREFIX="${HOME}/.wine"
UV_EXE64="${WINEPREFIX}/drive_c/Program Files (x86)/UltraViewer/UltraViewer_Desktop.exe"
UV_EXE32="${WINEPREFIX}/drive_c/Program Files/UltraViewer/UltraViewer_Desktop.exe"

if [[ -f "$UV_EXE64" ]]; then
    exec wine "$UV_EXE64" "$@"
elif [[ -f "$UV_EXE32" ]]; then
    exec wine "$UV_EXE32" "$@"
else
    # Auto-initialize UltraViewer in user's wine prefix on first run
    if [[ -f "/opt/ultraviewer/UltraViewer_setup.exe" ]]; then
        notify-send "UltraViewer" "Đang khởi tạo UltraViewer lần đầu cho tài khoản..." 2>/dev/null || true
        wine "/opt/ultraviewer/UltraViewer_setup.exe" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART 2>/dev/null
        sleep 2
        if [[ -f "$UV_EXE64" ]]; then
            exec wine "$UV_EXE64" "$@"
        elif [[ -f "$UV_EXE32" ]]; then
            exec wine "$UV_EXE32" "$@"
        fi
    fi
fi
EOF
    chmod 755 /usr/local/bin/ultraviewer

    # 4. Create Desktop Entry
    cat > /usr/share/applications/ultraviewer.desktop <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=UltraViewer
Comment=Phần mềm điều khiển máy tính từ xa UltraViewer
Exec=/usr/local/bin/ultraviewer
Icon=/usr/share/pixmaps/ultraviewer.svg
Terminal=false
Categories=Network;RemoteAccess;Utility;
StartupNotify=true
EOF
    chmod 644 /usr/share/applications/ultraviewer.desktop

    export_single_desktop_shortcut "/usr/share/applications/ultraviewer.desktop"
    msg_ok "Cài đặt UltraViewer hoàn tất! Biểu tượng đã được xuất ra màn hình."
}

install_chinese_fonts() {
    check_root
    msg_step "CÀI ĐẶT BỘ FONT CHỮ TIẾNG TRUNG ĐẦY ĐỦ (SIMPLIFIED & TRADITIONAL)"

    local font_pkgs=(
        fonts-noto-cjk
        fonts-noto-cjk-extra
        fonts-wqy-zenhei
        fonts-wqy-microhei
        fonts-arphic-uming
        fonts-arphic-ukai
    )

    msg_info "Đang cài đặt các gói font tiếng Trung: ${font_pkgs[*]}..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq || true
    if apt-get install -y "${font_pkgs[@]}"; then
        msg_info "Đang làm mới Font Cache hệ thống (fc-cache)..."
        fc-cache -f -v >/dev/null 2>&1 || true
        msg_ok "Cài đặt Font tiếng Trung thành công! Hệ thống hiển thị tiếng Trung chuẩn xác."
        return 0
    else
        msg_err "Cài đặt gói font thất bại."
        return 1
    fi
}

install_chinese_input() {
    check_root
    msg_step "CÀI ĐẶT BỘ GÕ TIẾNG TRUNG (IBUS-LIBPINYIN / PINYIN - KHAY HỆ THỐNG)"

    local pkgs=(ibus ibus-libpinyin ibus-pinyin)
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq || true
    apt-get install -y "${pkgs[@]}" >/dev/null 2>&1 || true

    # Configure IBus environment if not already set
    if [[ ! -f /etc/profile.d/bamboo.sh ]]; then
        cat > /etc/profile.d/bamboo.sh <<'EOF'
# System-wide IBus Input Configuration
export GTK_IM_MODULE=ibus
export QT_IM_MODULE=ibus
export XMODIFIERS=@im=ibus
export IBUS_ENABLE_SYNC_MODE=1
EOF
        chmod 644 /etc/profile.d/bamboo.sh
    fi

    # Update GLib schemas override: integrate both Bamboo & libpinyin docked in panel
    local gschema_override="/usr/share/glib-2.0/schemas/99_zorin_bamboo.gschema.override"
    mkdir -p "$(dirname "$gschema_override")"
    cat > "$gschema_override" <<'EOF'
[org.gnome.desktop.input-sources]
sources=[('xkb', 'us'), ('ibus', 'Bamboo'), ('ibus', 'libpinyin')]
mru-sources=[('ibus', 'Bamboo'), ('xkb', 'us'), ('ibus', 'libpinyin')]
show-all-sources=true

[desktop.ibus.general]
preload-engines=['Bamboo', 'libpinyin']

[desktop.ibus.panel]
show=0
show-icon-on-systray=true
lookup-table-orientation=0
EOF
    chmod 644 "$gschema_override"
    glib-compile-schemas /usr/share/glib-2.0/schemas/ 2>/dev/null || true

    # Update user session initializers
    for init_file in /usr/local/bin/zorin-bamboo-user-init.sh /usr/local/bin/zorin-bamboo-init.sh; do
        if [[ -f "$init_file" ]]; then
            sed -i "s|sources \"\[('xkb', 'us'), ('ibus', 'Bamboo')\]\"|sources \"[('xkb', 'us'), ('ibus', 'Bamboo'), ('ibus', 'libpinyin')]\"|g" "$init_file" 2>/dev/null || true
            sed -i "s|mru-sources \"\[('ibus', 'Bamboo'), ('xkb', 'us')\]\"|mru-sources \"[('ibus', 'Bamboo'), ('xkb', 'us'), ('ibus', 'libpinyin')]\"|g" "$init_file" 2>/dev/null || true
        fi
    done

    msg_ok "Đã kích hoạt Bộ gõ tiếng Trung (IBus Libpinyin) tích hợp gọn trong khay hệ thống!"
    msg_ok "Chuyển đổi ngôn ngữ gõ cực nhanh bằng phím tắt: [Super (Windows) + Phím cách]"
}

export_single_desktop_shortcut() {
    local desktop_file="$1"
    [[ ! -f "$desktop_file" ]] && return 0
    local filename
    filename=$(basename "$desktop_file")

    # 1. Copy to /etc/skel/Desktop and /etc/skel/Bàn làm việc for new AD users
    for skel_dir in "/etc/skel/Desktop" "/etc/skel/Bàn làm việc"; do
        mkdir -p "$skel_dir" 2>/dev/null || true
        cp -f "$desktop_file" "${skel_dir}/${filename}"
        chmod +x "${skel_dir}/${filename}"
    done

    # 2. Copy to all existing user desktops
    for home_dir in /home/*; do
        [[ ! -d "$home_dir" ]] && continue
        local user_name
        user_name=$(basename "$home_dir")

        local targets=()
        [[ -d "${home_dir}/Desktop" ]] && targets+=("${home_dir}/Desktop")
        [[ -d "${home_dir}/Bàn làm việc" ]] && targets+=("${home_dir}/Bàn làm việc")
        # Default create Desktop if neither exists
        if [[ ${#targets[@]} -eq 0 ]]; then
            mkdir -p "${home_dir}/Desktop" 2>/dev/null || true
            targets+=("${home_dir}/Desktop")
        fi

        local user_uid user_gid
        user_uid=$(stat -c '%u' "$home_dir" 2>/dev/null || id -u "$user_name" 2>/dev/null || echo "1000")
        user_gid=$(stat -c '%g' "$home_dir" 2>/dev/null || id -g "$user_name" 2>/dev/null || echo "1000")

        for d_dir in "${targets[@]}"; do
            cp -f "$desktop_file" "${d_dir}/${filename}"
            chmod 755 "${d_dir}/${filename}"
            chown "${user_uid}:${user_gid}" "${d_dir}/${filename}"
            su - "$user_name" -c "gio set '${d_dir}/${filename}' metadata::trusted true" 2>/dev/null || true
        done
    done
}

export_all_desktop_shortcuts() {
    check_root
    msg_step "XUẤT TOÀN BỘ BIỂU TƯỢNG RA MÀN HÌNH DESKTOP CHO TẤT CẢ USER"

    local apps=(
        "/usr/share/applications/google-chrome.desktop"
        "/usr/share/applications/zalo.desktop"
        "/usr/share/applications/wechat.desktop"
        "/usr/share/applications/ultraviewer.desktop"
    )

    for app in "${apps[@]}"; do
        if [[ -f "$app" ]]; then
            export_single_desktop_shortcut "$app"
        fi
    done

    msg_ok "Toàn bộ biểu tượng ứng dụng đã được xuất ra màn hình Desktop cho mọi người dùng!"
}

install_all_essential_apps() {
    check_root
    msg_step "BẮT ĐẦU CÀI ĐẶT TOÀN BỘ ỨNG DỤNG DOANH NGHIỆP CƠ BẢN (ALL-IN-ONE)"
    echo "Danh sách cài đặt tự động bao gồm:"
    echo "  1. Google Chrome Browser (Trình duyệt chuẩn doanh nghiệp)"
    echo "  2. Zalo Desktop (Nhắn tin công việc nhanh)"
    echo "  3. WeChat (微信 - Trao đổi đối tác & chuyên gia nước ngoài)"
    echo "  4. UltraViewer (Hỗ trợ IT điều khiển máy tính từ xa qua Wine)"
    echo "  5. Bộ Font chữ tiếng Trung đầy đủ (Noto CJK / WQY / Arphic)"
    echo "  6. Bộ gõ tiếng Trung Pinyin (IBus Libpinyin - Tích hợp ẩn khay hệ thống)"
    echo "  7. Bộ gõ tiếng Việt Bamboo (IBus Bamboo - Toàn hệ thống)"
    echo "  8. Tự động xuất biểu tượng ra màn hình Desktop cho toàn bộ người dùng"
    echo "--------------------------------------------------------"

    if ! prompt_confirm "Bạn có chắc chắn muốn cài đặt toàn bộ ứng dụng này?" "Y"; then
        msg_info "Đã hủy thao tác."
        return 0
    fi

    create_app_icons
    install_chrome || true
    install_zalo || true
    install_wechat || true
    install_ultraviewer || true
    install_chinese_fonts || true
    setup_bamboo_system_wide || true
    install_chinese_input || true
    export_all_desktop_shortcuts || true

    msg_ok "========================================================="
    msg_ok "CÀI ĐẶT TOÀN BỘ ỨNG DỤNG DOANH NGHIỆP CƠ BẢN THÀNH CÔNG!"
    msg_ok "Mọi người dùng AD và cục bộ đều có thể sử dụng ngay từ Desktop!"
    msg_ok "Phím tắt chuyển đổi bộ gõ: [Super (Windows) + Phím cách]"
    msg_ok "========================================================="
}

enterprise_apps_menu() {
    while true; do
        echo -e "\n${C_BOLD}${C_BLUE}================================================================${C_RESET}"
        echo -e "${C_BOLD}${C_WHITE}       QUẢN LÝ VÀ CÀI ĐẶT ỨNG DỤNG DOANH NGHIỆP CƠ BẢN          ${C_RESET}"
        echo -e "${C_BOLD}${C_BLUE}================================================================${C_RESET}"
        echo -e " ${C_CYAN}${C_BOLD}[1]  Cài đặt TẤT CẢ ứng dụng cơ bản (One-Click All-in-One)${C_RESET}"
        echo " ----------------------------------------------------------------"
        echo " [2]  Cài đặt Google Chrome Browser"
        echo " [3]  Cài đặt Zalo Desktop"
        echo " [4]  Cài đặt WeChat (微信)"
        echo " [5]  Cài đặt UltraViewer (Hỗ trợ điều khiển từ xa qua Wine)"
        echo " [6]  Cài đặt Bộ Font chữ tiếng Trung đầy đủ (Noto CJK / WQY / Arphic)"
        echo " [7]  Cài đặt Bộ gõ tiếng Trung Pinyin (IBus Libpinyin - Khay hệ thống)"
        echo " [8]  Cài đặt Bộ gõ tiếng Việt Bamboo (IBus Bamboo - Toàn hệ thống)"
        echo " [9]  Xuất toàn bộ biểu tượng (Icons) ra màn hình Desktop cho mọi user"
        echo " [0]  Quay lại Menu chính"
        echo "----------------------------------------------------------------"

        local choice
        prompt_with_default "Chọn chức năng [0-9]" "1" choice

        case "$choice" in
            1) install_all_essential_apps ;;
            2) install_chrome ;;
            3) install_zalo ;;
            4) install_wechat ;;
            5) install_ultraviewer ;;
            6) install_chinese_fonts ;;
            7) install_chinese_input ;;
            8) setup_bamboo_system_wide ;;
            9) export_all_desktop_shortcuts ;;
            0) break ;;
            *) msg_err "Lựa chọn không hợp lệ." ;;
        esac
    done
}
