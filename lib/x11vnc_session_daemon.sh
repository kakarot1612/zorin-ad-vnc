#!/usr/bin/env bash
# ==============================================================================
# Zorin OS AD Join & X11VNC Management Tool
# File: lib/x11vnc_session_daemon.sh
# Description: Background daemon that dynamically detects the active graphical
#              user session on seat0 and attaches x11vnc directly to that user's
#              Xorg desktop session.
# ==============================================================================

export HOME="/root"
DAEMON_LOG="/var/log/zorin-x11vnc.log"
CONFIG_FILE="/etc/x11vnc/zorin-vnc.conf"
PASSWD_FILE="/etc/x11vnc/passwd"

log_daemon() {
    local level="$1"
    local msg="$2"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] [$level] $msg" >> "$DAEMON_LOG"
}

# Read configuration or defaults
VNC_PORT="5900"
POLL_INTERVAL=3
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

find_active_gui_session() {
    # Find session on seat0 that is active
    if ! command -v loginctl >/dev/null 2>&1; then
        return 1
    fi

    local sessions
    sessions=$(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}')
    
    local greeter_session=""

    for sid in $sessions; do
        local seat user uid state stype
        seat=$(loginctl show-session "$sid" -p Seat --value 2>/dev/null)
        user=$(loginctl show-session "$sid" -p Name --value 2>/dev/null)
        uid=$(loginctl show-session "$sid" -p User --value 2>/dev/null)
        state=$(loginctl show-session "$sid" -p State --value 2>/dev/null)
        stype=$(loginctl show-session "$sid" -p Type --value 2>/dev/null)

        if [[ "$seat" == "seat0" ]] && [[ "$state" == "active" ]]; then
            if [[ "$stype" == "x11" ]] || [[ "$stype" == "wayland" ]]; then
                if [[ "$user" != "gdm" ]] && [[ "$user" != "Debian-gdm" ]]; then
                    # Prioritize logged-in user session
                    echo "$sid $user $uid $stype"
                    return 0
                else
                    greeter_session="$sid $user $uid $stype"
                fi
            fi
        fi
    done

    # Fallback to GDM greeter (login screen) if no regular user is logged in
    if [[ -n "$greeter_session" ]]; then
        echo "$greeter_session"
        return 0
    fi

    return 1
}

find_xauthority() {
    local uid="$1"
    local user="$2"
    local auth=""

    # 1. Inspect /proc/*/environ of active GUI sessions (direct ground truth)
    local proc_auth
    proc_auth=$(grep -s -z -h '^XAUTHORITY=' /proc/[0-9]*/environ 2>/dev/null | tr '\0' '\n' | grep '^XAUTHORITY=' | head -n 1 | cut -d= -f2-)
    if [[ -n "$proc_auth" && -f "$proc_auth" ]]; then
        echo "$proc_auth"
        return 0
    fi

    # 2. Extract directly from active Xorg process arguments
    local extracted
    extracted=$(ps -eo args 2>/dev/null | grep -E '[X]org' | grep -o -E -- '-auth[ =][^ ]+' | awk '{print $2}' | head -n 1)
    if [[ -n "$extracted" && -f "$extracted" ]]; then
        echo "$extracted"
        return 0
    fi

    # 3. Check user runtime directory
    if [[ -n "$uid" ]]; then
        for f in "/run/user/${uid}/gdm/Xauthority" "/run/user/${uid}/.Xauthority"; do
            if [[ -f "$f" ]]; then
                echo "$f"
                return 0
            fi
        done
        for f in /run/user/"${uid}"/xauth*; do
            if [[ -f "$f" ]]; then
                echo "$f"
                return 0
            fi
        done
    fi

    # 4. Check GDM greeter / system locations
    for f in /var/lib/gdm3/.Xauthority /run/gdm3/*/database /var/run/gdm3/*/database /run/user/*/gdm/Xauthority; do
        if [[ -f "$f" ]]; then
            echo "$f"
            return 0
        fi
    done

    # 5. Check user home directory
    if [[ -n "$user" ]]; then
        local user_home
        user_home=$(getent passwd "$user" | cut -d: -f6)
        if [[ -n "$user_home" && -f "${user_home}/.Xauthority" ]]; then
            echo "${user_home}/.Xauthority"
            return 0
        fi
    fi

    echo ""
}

find_display() {
    local sid="$1"
    local disp=""

    # 1. From active GUI process environment
    local proc_disp
    proc_disp=$(grep -s -z -h '^DISPLAY=:' /proc/[0-9]*/environ 2>/dev/null | tr '\0' '\n' | grep '^DISPLAY=:' | head -n 1 | cut -d= -f2-)
    if [[ -n "$proc_disp" ]]; then
        echo "$proc_disp"
        return 0
    fi

    # 2. From loginctl
    if [[ -n "$sid" ]]; then
        disp=$(loginctl show-session "$sid" -p Display --value 2>/dev/null)
    fi
    if [[ -n "$disp" ]]; then
        echo "$disp"
        return 0
    fi

    # 3. Check /tmp/.X11-unix active sockets
    local socket
    socket=$(ls /tmp/.X11-unix/X* 2>/dev/null | head -n 1)
    if [[ -n "$socket" ]]; then
        local num="${socket##*/X}"
        echo ":${num}"
        return 0
    fi

    # 4. Check Xorg processes
    local xorg_disp
    xorg_disp=$(ps -eo args 2>/dev/null | grep -E '[X]org' | grep -o -E ':[0-9]+' | head -n 1)
    if [[ -n "$xorg_disp" ]]; then
        echo "$xorg_disp"
        return 0
    fi

    echo ":0"
}

start_daemon_loop() {
    log_daemon "INFO" "Zorin x11vnc Dynamic Session Daemon starting..."
    log_daemon "INFO" "Target VNC Port: $VNC_PORT, Poll Interval: ${POLL_INTERVAL}s"

    local current_session_id=""
    local current_user=""
    local vnc_pid=""

    cleanup() {
        log_daemon "INFO" "Signal received. Stopping x11vnc (PID: $vnc_pid)..."
        if [[ -n "$vnc_pid" ]] && kill -0 "$vnc_pid" 2>/dev/null; then
            kill "$vnc_pid" 2>/dev/null || true
            wait "$vnc_pid" 2>/dev/null || true
        fi
        exit 0
    }

    trap cleanup SIGTERM SIGINT SIGHUP

    # Ensure config directory and password file have proper permissions
    mkdir -p "$(dirname "$PASSWD_FILE")"
    chmod 755 "$(dirname "$PASSWD_FILE")" 2>/dev/null || true
    if [[ -f "$PASSWD_FILE" ]]; then
        chmod 644 "$PASSWD_FILE" 2>/dev/null || true
    fi

    while true; do
        local session_info
        session_info=$(find_active_gui_session || true)

        if [[ -n "$session_info" ]]; then
            read -r sid user uid stype <<< "$session_info"

            # If this is a new session or previously had no session or x11vnc died
            if [[ "$sid" != "$current_session_id" ]] || [[ -z "$vnc_pid" ]] || ! kill -0 "$vnc_pid" 2>/dev/null; then
                # If there was an old x11vnc running, stop it first
                if [[ -n "$vnc_pid" ]] && kill -0 "$vnc_pid" 2>/dev/null; then
                    log_daemon "INFO" "Session changed (from $current_session_id to $sid). Stopping old x11vnc (PID: $vnc_pid)..."
                    kill "$vnc_pid" 2>/dev/null || true
                    wait "$vnc_pid" 2>/dev/null || true
                    vnc_pid=""
                fi

                current_session_id="$sid"
                current_user="$user"

                if [[ "$stype" == "wayland" ]]; then
                    log_daemon "WARN" "Session $sid ($user) is running Wayland. x11vnc requires Xorg! Skipping."
                    sleep "$POLL_INTERVAL"
                    continue
                fi

                local disp
                disp=$(find_display "$sid")
                local auth
                auth=$(find_xauthority "$uid" "$user")

                log_daemon "INFO" "Active GUI session detected: User=${user}, UID=${uid}, Display=${disp}, Auth=${auth:-[guess]}"

                # Build x11vnc command
                local cmd_args=(
                    "-display" "$disp"
                    "-forever"
                    "-shared"
                    "-rfbport" "$VNC_PORT"
                    "-noxdamage"
                    "-repeat"
                )

                if [[ -s "$PASSWD_FILE" ]]; then
                    cmd_args+=("-rfbauth" "$PASSWD_FILE")
                else
                    cmd_args+=("-passwd" "123456")
                fi

                if [[ -n "$auth" && -f "$auth" ]]; then
                    chmod 644 "$auth" 2>/dev/null || true
                    cmd_args+=("-auth" "$auth")
                else
                    cmd_args+=("-auth" "guess")
                fi

                log_daemon "INFO" "Launching x11vnc on display $disp for session: $user (UID: $uid)..."

                # Execute x11vnc as root with full privileges (never set bad /root/.Xauthority)
                if [[ -n "$auth" && -f "$auth" ]]; then
                    env DISPLAY="$disp" XAUTHORITY="$auth" \
                        x11vnc "${cmd_args[@]}" >> "$DAEMON_LOG" 2>&1 &
                else
                    env DISPLAY="$disp" \
                        x11vnc "${cmd_args[@]}" >> "$DAEMON_LOG" 2>&1 &
                fi
                vnc_pid=$!

                # Check if x11vnc survived initial startup
                sleep 1
                if ! kill -0 "$vnc_pid" 2>/dev/null; then
                    log_daemon "WARN" "x11vnc failed to start, retrying with raw -auth guess on display $disp..."
                    local fb_args=(
                        "-display" "$disp"
                        "-auth" "guess"
                        "-forever"
                        "-shared"
                        "-rfbport" "$VNC_PORT"
                        "-noxdamage"
                        "-repeat"
                        "-passwd" "123456"
                    )
                    env DISPLAY="$disp" x11vnc "${fb_args[@]}" >> "$DAEMON_LOG" 2>&1 &
                    vnc_pid=$!
                fi

                if kill -0 "$vnc_pid" 2>/dev/null; then
                    log_daemon "SUCCESS" "x11vnc started with PID: $vnc_pid on port $VNC_PORT"
                else
                    log_daemon "ERROR" "x11vnc could not bind to display $disp. Check log for details."
                fi
            fi
        else
            # No active session found
            if [[ -n "$vnc_pid" ]] && kill -0 "$vnc_pid" 2>/dev/null; then
                log_daemon "INFO" "No active session detected. Stopping x11vnc (PID: $vnc_pid)..."
                kill "$vnc_pid" 2>/dev/null || true
                wait "$vnc_pid" 2>/dev/null || true
                vnc_pid=""
                current_session_id=""
                current_user=""
            fi
        fi

        sleep "$POLL_INTERVAL"
    done
}

# If executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ $EUID -ne 0 ]]; then
        echo "This daemon must run as root." >&2
        exit 1
    fi
    start_daemon_loop
fi
