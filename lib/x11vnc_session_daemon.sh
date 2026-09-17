#!/usr/bin/env bash
# ==============================================================================
# Zorin OS AD Join & X11VNC Management Tool
# File: lib/x11vnc_session_daemon.sh
# Description: Background daemon that dynamically detects the active graphical
#              user session on seat0 and attaches x11vnc directly to that user's
#              Xorg desktop session.
# ==============================================================================

DAEMON_LOG="/var/log/zorin-x11vnc.log"
CONFIG_FILE="/etc/x11vnc/zorin-vnc.conf"
PASSWD_FILE="/etc/x11vnc/vncpwd"

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
    # Find session on seat0 that is active and not GDM login screen
    if ! command -v loginctl >/dev/null 2>&1; then
        return 1
    fi

    local sessions
    sessions=$(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}')
    
    for sid in $sessions; do
        local seat user uid state stype
        seat=$(loginctl show-session "$sid" -p Seat --value 2>/dev/null)
        user=$(loginctl show-session "$sid" -p Name --value 2>/dev/null)
        uid=$(loginctl show-session "$sid" -p User --value 2>/dev/null)
        state=$(loginctl show-session "$sid" -p State --value 2>/dev/null)
        stype=$(loginctl show-session "$sid" -p Type --value 2>/dev/null)

        # Ignore non-seat0 or inactive sessions or the login greeter (gdm / Debian-gdm)
        if [[ "$seat" == "seat0" ]] && [[ "$state" == "active" ]] && [[ "$user" != "gdm" ]] && [[ "$user" != "Debian-gdm" ]]; then
            # Verify it is an X11 or graphical session
            if [[ "$stype" == "x11" ]] || [[ "$stype" == "wayland" ]]; then
                echo "$sid $user $uid $stype"
                return 0
            fi
        fi
    done

    return 1
}

find_xauthority() {
    local uid="$1"
    local user="$2"
    local auth=""

    # 1. Inspect user processes in /proc to get exact XAUTHORITY from active session
    if [[ -n "$uid" ]]; then
        local user_pids
        user_pids=$(pgrep -u "$uid" 2>/dev/null | head -n 30)
        for p in $user_pids; do
            if [[ -r "/proc/$p/environ" ]]; then
                auth=$(grep -s -z '^XAUTHORITY=' "/proc/$p/environ" 2>/dev/null | tr -d '\0' | cut -d= -f2-)
                if [[ -n "$auth" && -f "$auth" ]]; then
                    echo "$auth"
                    return 0
                fi
            fi
        done
    fi

    # 2. Standard GDM Xauthority location
    if [[ -f "/run/user/${uid}/gdm/Xauthority" ]]; then
        auth="/run/user/${uid}/gdm/Xauthority"
    elif [[ -f "/run/user/${uid}/.Xauthority" ]]; then
        auth="/run/user/${uid}/.Xauthority"
    fi

    # 3. Extract from Xorg process arguments if not found yet
    if [[ -z "$auth" ]]; then
        local xorg_cmd
        xorg_cmd=$(pgrep -a Xorg 2>/dev/null || true)
        local extracted
        extracted=$(echo "$xorg_cmd" | grep -o -E '\-auth [^ ]+' | awk '{print $2}' | head -n 1)
        if [[ -n "$extracted" ]] && [[ -f "$extracted" ]]; then
            auth="$extracted"
        fi
    fi

    # 4. Check user home directory
    if [[ -z "$auth" ]]; then
        local user_home
        user_home=$(getent passwd "$user" | cut -d: -f6)
        if [[ -f "${user_home}/.Xauthority" ]]; then
            auth="${user_home}/.Xauthority"
        fi
    fi

    echo "$auth"
}

find_display() {
    local sid="$1"
    local uid="$2"
    local disp=""

    # 1. Inspect user processes in /proc to get exact DISPLAY from active session
    if [[ -n "$uid" ]]; then
        local user_pids
        user_pids=$(pgrep -u "$uid" 2>/dev/null | head -n 30)
        for p in $user_pids; do
            if [[ -r "/proc/$p/environ" ]]; then
                disp=$(grep -s -z '^DISPLAY=' "/proc/$p/environ" 2>/dev/null | tr -d '\0' | cut -d= -f2-)
                if [[ -n "$disp" ]]; then
                    echo "$disp"
                    return 0
                fi
            fi
        done
    fi

    # 2. Check loginctl session property
    disp=$(loginctl show-session "$sid" -p Display --value 2>/dev/null)
    if [[ -n "$disp" ]]; then
        echo "$disp"
        return 0
    fi

    # 3. Check active sockets in /tmp/.X11-unix (newest socket)
    local latest_sock
    latest_sock=$(ls -t /tmp/.X11-unix/X* 2>/dev/null | head -n 1)
    if [[ -n "$latest_sock" ]]; then
        echo ":${latest_sock##*/X}"
        return 0
    fi

    echo ":1"
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

    while true; do
        local session_info
        session_info=$(find_active_gui_session || true)

        if [[ -n "$session_info" ]]; then
            read -r sid user uid stype <<< "$session_info"

            # If this is a new session or previously had no session
            if [[ "$sid" != "$current_session_id" ]] || [[ -z "$vnc_pid" ]] || ! kill -0 "$vnc_pid" 2>/dev/null; then
                # If there was an old x11vnc running, stop it first
                if [[ -n "$vnc_pid" ]] && kill -0 "$vnc_pid" 2>/dev/null; then
                    log_daemon "INFO" "Previous session $current_session_id ended. Stopping x11vnc (PID: $vnc_pid)..."
                    kill "$vnc_pid" 2>/dev/null || true
                    wait "$vnc_pid" 2>/dev/null || true
                    vnc_pid=""
                fi

                current_session_id="$sid"
                current_user="$user"

                if [[ "$stype" == "wayland" ]]; then
                    log_daemon "WARN" "User $user is running Wayland session. x11vnc requires Xorg! Skipping."
                    sleep "$POLL_INTERVAL"
                    continue
                fi

                local disp
                disp=$(find_display "$sid" "$uid")
                local auth
                auth=$(find_xauthority "$uid" "$user")

                if [[ -z "$auth" ]]; then
                    log_daemon "WARN" "Waiting for Xauthority file for user $user (UID $uid)..."
                    sleep 2
                    continue
                fi

                log_daemon "INFO" "Active GUI session detected: User=${user}, UID=${uid}, Display=${disp}, Auth=${auth}"

                # Ensure Xauthority is readable
                chmod 644 "$auth" 2>/dev/null || true

                # Build x11vnc command
                local cmd_args=(
                    "-display" "$disp"
                    "-auth" "$auth"
                    "-forever"
                    "-shared"
                    "-rfbport" "$VNC_PORT"
                    "-noxdamage"
                    "-repeat"
                    "-noshm"
                )

                if [[ -f "$PASSWD_FILE" ]]; then
                    chmod 644 "$PASSWD_FILE" 2>/dev/null || true
                    cmd_args+=("-rfbauth" "$PASSWD_FILE")
                else
                    log_daemon "WARN" "VNC password file $PASSWD_FILE not found! Running without password is not recommended."
                fi

                log_daemon "INFO" "Launching x11vnc on display $disp for user $user..."

                # Execute x11vnc as the target user with -noshm
                sudo -u "$user" env \
                    DISPLAY="$disp" \
                    XAUTHORITY="$auth" \
                    x11vnc "${cmd_args[@]}" >> "$DAEMON_LOG" 2>&1 &
                vnc_pid=$!

                sleep 1
                if ! kill -0 "$vnc_pid" 2>/dev/null; then
                    log_daemon "WARN" "Launch as user $user exited, retrying directly as root with -noshm..."
                    env DISPLAY="$disp" XAUTHORITY="$auth" \
                        x11vnc "${cmd_args[@]}" >> "$DAEMON_LOG" 2>&1 &
                    vnc_pid=$!
                fi

                if kill -0 "$vnc_pid" 2>/dev/null; then
                    log_daemon "SUCCESS" "x11vnc started with PID: $vnc_pid for user: $user on port $VNC_PORT"
                else
                    log_daemon "ERR" "Failed to start x11vnc for user $user on display $disp."
                fi
            fi
        else
            # No active user session (e.g. at GDM login screen or locked/logged out)
            if [[ -n "$vnc_pid" ]] && kill -0 "$vnc_pid" 2>/dev/null; then
                log_daemon "INFO" "User logged out or session deactivated. Stopping x11vnc (PID: $vnc_pid)..."
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
