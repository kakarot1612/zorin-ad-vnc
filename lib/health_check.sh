#!/usr/bin/env bash
# ==============================================================================
# Zorin OS AD Join & X11VNC Management Tool
# File: lib/health_check.sh
# Description: Full system diagnostics & health dashboard for AD, PAM, Xorg, and x11vnc.
# ==============================================================================

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/check_dns.sh
source "$LIB_DIR/check_dns.sh"

format_status() {
    local label="$1"
    local status="$2"
    local is_ok="$3"

    if [[ "$is_ok" == "true" ]]; then
        printf "%-32s [ %b%s%b ]\n" "$label" "$C_GREEN" "$status" "$C_RESET"
    elif [[ "$is_ok" == "warn" ]]; then
        printf "%-32s [ %b%s%b ]\n" "$label" "$C_YELLOW" "$status" "$C_RESET"
    else
        printf "%-32s [ %b%s%b ]\n" "$label" "$C_RED" "$status" "$C_RESET"
    fi
}

run_health_check() {
    local domain="$1"
    local dc1="$2"
    local dc2="$3"
    local test_user="$4"

    # Auto detect domain & DCs from persistent config if not supplied
    if [[ -f /etc/zorin-ad-vnc/ad_dc.conf ]]; then
        # shellcheck disable=SC1091
        source /etc/zorin-ad-vnc/ad_dc.conf
        [[ -z "$domain" ]] && domain="${DOMAIN}"
        [[ -z "$dc1" ]] && dc1="${DC1}"
        [[ -z "$dc2" ]] && dc2="${DC2}"
    fi

    # Read from realm list or sssd.conf if still empty
    if [[ -z "$domain" ]]; then
        domain=$(realm list 2>/dev/null | grep -E '^[[:space:]]*domain-name:' | awk '{print $2}' | head -n 1)
    fi
    if [[ -z "$dc1" && -f /etc/sssd/sssd.conf ]]; then
        dc1=$(grep -E '^[[:space:]]*ad_server' /etc/sssd/sssd.conf | cut -d= -f2 | awk -F, '{print $1}' | tr -d '[:space:]')
        dc2=$(grep -E '^[[:space:]]*ad_server' /etc/sssd/sssd.conf | cut -d= -f2 | awk -F, '{print $2}' | tr -d '[:space:]')
    fi

    echo ""
    echo -e "${C_BOLD}${C_BG_BLUE}               ZORIN AD / X11VNC HEALTH CHECK DASHBOARD               ${C_RESET}"
    echo "======================================================================"

    # 1. DNS
    if [[ -n "$domain" ]]; then
        if getent hosts "$domain" >/dev/null 2>&1; then
            format_status "DNS Resolution (${domain})" "OK" "true"
        else
            format_status "DNS Resolution (${domain})" "FAILED" "false"
        fi
    else
        format_status "DNS Resolution" "NO DOMAIN SET" "warn"
    fi

    # 2. AD1 Reachable
    if [[ -n "$dc1" ]]; then
        if check_port_open "$dc1" 389 2; then
            format_status "AD1 Reachable (${dc1})" "OK" "true"
        else
            format_status "AD1 Reachable (${dc1})" "UNREACHABLE" "false"
        fi
    fi

    # 3. AD2 Reachable
    if [[ -n "$dc2" ]]; then
        if check_port_open "$dc2" 389 2; then
            format_status "AD2 Reachable (${dc2})" "OK" "true"
        else
            format_status "AD2 Reachable (${dc2})" "UNREACHABLE" "warn"
        fi
    fi

    # 4. Kerberos (Port 88 on DC1 or DC2)
    if [[ -n "$dc1" ]] && check_port_open "$dc1" 88 2; then
        format_status "Kerberos KDC (Port 88)" "OK (${dc1})" "true"
    elif [[ -n "$dc2" ]] && check_port_open "$dc2" 88 2; then
        format_status "Kerberos KDC (Port 88)" "OK (${dc2})" "true"
    elif [[ -z "$dc1" ]]; then
        format_status "Kerberos KDC (Port 88)" "NOT CONFIGURED" "warn"
    else
        format_status "Kerberos KDC (Port 88)" "FAILED" "false"
    fi

    # 5. Realm Joined
    local realm_status
    realm_status=$(realm list 2>/dev/null | grep -E '^[[:space:]]*domain-name:' | awk '{print $2}' | head -n 1)
    if [[ -n "$realm_status" ]]; then
        format_status "Realm Domain Joined" "OK (${realm_status})" "true"
    else
        format_status "Realm Domain Joined" "NOT JOINED" "false"
    fi

    # 6. SSSD Running
    if systemctl is-active --quiet sssd 2>/dev/null; then
        format_status "SSSD Service" "RUNNING" "true"
    else
        format_status "SSSD Service" "STOPPED" "false"
    fi

    # 7. AD User Lookup
    local test_lookup_user="$test_user"
    if [[ -z "$test_lookup_user" ]] && command -v loginctl >/dev/null 2>&1; then
        test_lookup_user=$(loginctl list-users --no-legend 2>/dev/null | awk '$2 != "gdm" && $2 != "Debian-gdm" && $2 != "root" {print $2; exit}')
    fi
    if [[ -n "$test_lookup_user" ]]; then
        if getent passwd "$test_lookup_user" >/dev/null 2>&1; then
            format_status "AD User Lookup (${test_lookup_user})" "OK" "true"
        else
            format_status "AD User Lookup (${test_lookup_user})" "NOT FOUND" "warn"
        fi
    fi

    # 8. PAM mkhomedir
    if grep -q "pam_mkhomedir.so" /etc/pam.d/common-session 2>/dev/null; then
        format_status "PAM mkhomedir" "CONFIGURED" "true"
    else
        format_status "PAM mkhomedir" "MISSING" "warn"
    fi

    # 9. GDM Wayland Disabled
    local gdm_conf="/etc/gdm3/custom.conf"
    [[ ! -f "$gdm_conf" ]] && gdm_conf="/etc/gdm/custom.conf"
    if [[ -f "$gdm_conf" ]] && grep -q -E "^WaylandEnable=false" "$gdm_conf"; then
        format_status "GDM Wayland Disabled" "OK (Wayland=false)" "true"
    else
        format_status "GDM Wayland Disabled" "NOT CONFIGURED" "warn"
    fi

    # 10. Session Type
    local cur_sess_type="${XDG_SESSION_TYPE:-unknown}"
    if [[ "$cur_sess_type" == "x11" ]]; then
        format_status "Current Session Type" "X11" "true"
    elif [[ "$cur_sess_type" == "wayland" ]]; then
        format_status "Current Session Type" "WAYLAND" "false"
    else
        format_status "Current Session Type" "${cur_sess_type}" "warn"
    fi

    # 11. Xorg Running
    if pgrep -a Xorg >/dev/null 2>&1; then
        format_status "Xorg Server Process" "RUNNING" "true"
    else
        format_status "Xorg Server Process" "NOT RUNNING" "warn"
    fi

    # 12. x11vnc Service
    if systemctl is-active --quiet "${SYSTEMD_SERVICE}" 2>/dev/null; then
        format_status "zorin-x11vnc.service" "ACTIVE" "true"
    else
        format_status "zorin-x11vnc.service" "INACTIVE" "warn"
    fi

    # 13. VNC Port 5900 Listening
    local vnc_port="5900"
    if [[ -f "${VNC_CONFIG_DIR}/zorin-vnc.conf" ]]; then
        vnc_port=$(grep "VNC_PORT=" "${VNC_CONFIG_DIR}/zorin-vnc.conf" | cut -d'"' -f2)
        vnc_port="${vnc_port:-5900}"
    fi

    local port_ok=false
    if command -v ss >/dev/null 2>&1; then
        if ss -tulpn | grep -q ":${vnc_port} "; then
            port_ok=true
        fi
    fi

    if [[ "$port_ok" == "true" ]]; then
        format_status "VNC Port ${vnc_port}" "LISTENING" "true"
    else
        format_status "VNC Port ${vnc_port}" "NOT LISTENING" "warn"
    fi

    echo "----------------------------------------------------------------------"
    echo -e "${C_BOLD}THÔNG TIN PHIÊN ĐỒ HỌA HIỆN TẠI (ACTIVE GUI SESSION):${C_RESET}"

    # Extract active session details
    local active_sid="" active_user="Chưa có user login" active_uid="" active_disp=":0" active_auth=""
    if command -v loginctl >/dev/null 2>&1; then
        local sids
        sids=$(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}')
        for sid in $sids; do
            local seat user uid state stype
            seat=$(loginctl show-session "$sid" -p Seat --value 2>/dev/null)
            user=$(loginctl show-session "$sid" -p Name --value 2>/dev/null)
            uid=$(loginctl show-session "$sid" -p User --value 2>/dev/null)
            state=$(loginctl show-session "$sid" -p State --value 2>/dev/null)
            stype=$(loginctl show-session "$sid" -p Type --value 2>/dev/null)

            if [[ "$seat" == "seat0" ]] && [[ "$state" == "active" ]] && [[ "$user" != "gdm" ]] && [[ "$user" != "Debian-gdm" ]]; then
                active_sid="$sid"
                active_user="$user"
                active_uid="$uid"
                if [[ -f "/run/user/${uid}/gdm/Xauthority" ]]; then
                    active_auth="/run/user/${uid}/gdm/Xauthority"
                fi
                break
            fi
        done
    fi

    echo -e "  Current Desktop User : ${C_CYAN}${active_user}${C_RESET}"
    echo -e "  Session ID           : ${C_CYAN}${active_sid:-None}${C_RESET}"
    echo -e "  User UID             : ${C_CYAN}${active_uid:-None}${C_RESET}"
    echo -e "  Display              : ${C_CYAN}${active_disp}${C_RESET}"
    echo -e "  Xauthority           : ${C_CYAN}${active_auth:-Chưa phát hiện}${C_RESET}"

    local vnc_proc_user
    vnc_proc_user=$(ps -o user= -p "$(pgrep x11vnc | head -n 1)" 2>/dev/null | tr -d ' ')
    if [[ -n "$vnc_proc_user" ]]; then
        echo -e "  x11vnc Running User  : ${C_GREEN}${vnc_proc_user}${C_RESET}"
    else
        echo -e "  x11vnc Running User  : ${C_YELLOW}Không có tiến trình${C_RESET}"
    fi

    echo "======================================================================"
}
