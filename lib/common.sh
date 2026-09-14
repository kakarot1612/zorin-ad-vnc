#!/usr/bin/env bash
# ==============================================================================
# Zorin OS AD Join & X11VNC Management Tool
# File: lib/common.sh
# Description: Common utility functions, colors, logging, and secure credential prompts.
# ==============================================================================

# Exit codes
export ERR_GENERAL=1
export ERR_ROOT_REQUIRED=2
export ERR_DNS=3
export ERR_AD_JOIN=4
export ERR_SSSD=5
export ERR_VNC=6

# Colors
export C_RESET='\033[0m'
export C_BOLD='\033[1m'
export C_DIM='\033[2m'
export C_RED='\033[0;31m'
export C_GREEN='\033[0;32m'
export C_YELLOW='\033[0;33m'
export C_BLUE='\033[0;34m'
export C_MAGENTA='\033[0;35m'
export C_CYAN='\033[0;36m'
export C_WHITE='\033[1;37m'
export C_BG_BLUE='\033[44m'

# Paths
export LOG_FILE="/var/log/zorin-ad-vnc.log"
export BACKUP_DIR="/var/backups/zorin-ad-vnc"
export VNC_CONFIG_DIR="/etc/x11vnc"
export VNC_PASSWD_FILE="/etc/x11vnc/vncpwd"
export DAEMON_SCRIPT="/usr/local/bin/zorin-x11vnc-daemon.sh"
export SYSTEMD_SERVICE="zorin-x11vnc.service"

# Ensure log directory exists if running as root
init_logging() {
    if [[ $EUID -eq 0 ]]; then
        mkdir -p "$(dirname "$LOG_FILE")"
        touch "$LOG_FILE" 2>/dev/null || true
        chmod 600 "$LOG_FILE" 2>/dev/null || true
    fi
}

log_message() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Do not write to log file if directory not accessible
    if [[ -w "$(dirname "$LOG_FILE")" ]] || [[ -w "$LOG_FILE" ]]; then
        echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    fi
}

msg_info() {
    echo -e "${C_CYAN}[INFO]${C_RESET} $1"
    log_message "INFO" "$1"
}

msg_ok() {
    echo -e "${C_GREEN}[✓ OK]${C_RESET} $1"
    log_message "SUCCESS" "$1"
}

msg_warn() {
    echo -e "${C_YELLOW}[!] WARNING:${C_RESET} $1"
    log_message "WARN" "$1"
}

msg_err() {
    echo -e "${C_RED}[✗ ERROR]${C_RESET} $1" >&2
    log_message "ERROR" "$1"
}

msg_step() {
    echo -e "\n${C_BOLD}${C_BLUE}==>${C_WHITE} $1${C_RESET}"
    log_message "STEP" "$1"
}

# Verify script is run with sudo / root privileges
check_root() {
    if [[ $EUID -ne 0 ]]; then
        msg_err "Script này yêu cầu quyền root. Vui lòng chạy lại với lệnh: sudo $0"
        exit "$ERR_ROOT_REQUIRED"
    fi
}

# Prompt user for input with an optional default value
prompt_with_default() {
    local prompt_text="$1"
    local default_val="$2"
    local result_var="$3"
    local user_input

    if [[ -n "$default_val" ]]; then
        read -r -p "$(echo -e "${C_BOLD}${prompt_text}${C_RESET} [${C_CYAN}${default_val}${C_RESET}]: ")" user_input
        if [[ -z "$user_input" ]]; then
            eval "$result_var=\"$default_val\""
        else
            eval "$result_var=\"$user_input\""
        fi
    else
        read -r -p "$(echo -e "${C_BOLD}${prompt_text}${C_RESET}: ")" user_input
        eval "$result_var=\"$user_input\""
    fi
}

# Prompt user for password securely without echoing characters
# Never logs the password
prompt_secure_password() {
    local prompt_text="$1"
    local result_var="$2"
    local confirm="${3:-false}"
    local pass1=""
    local pass2=""

    while true; do
        read -r -s -p "$(echo -e "${C_BOLD}${prompt_text}${C_RESET}: ")" pass1
        echo "" >&2

        if [[ -z "$pass1" ]]; then
            msg_warn "Mật khẩu không được để trống. Vui lòng nhập lại."
            continue
        fi

        if [[ "$confirm" == "true" ]]; then
            read -r -s -p "$(echo -e "${C_BOLD}Xác nhận lại mật khẩu${C_RESET}: ")" pass2
            echo "" >&2

            if [[ "$pass1" != "$pass2" ]]; then
                msg_err "Mật khẩu xác nhận không khớp. Vui lòng nhập lại từ đầu."
                continue
            fi
        fi

        eval "$result_var=\"$pass1\""
        break
    done
}

# Confirmation prompt (Yes/No)
prompt_confirm() {
    local prompt_text="$1"
    local default_ans="${2:-Y}"
    local user_input
    local choice_str="[Y/n]"
    [[ "$default_ans" =~ ^[Nn]$ ]] && choice_str="[y/N]"

    read -r -p "$(echo -e "${C_YELLOW}${prompt_text}${C_RESET} ${choice_str}: ")" user_input
    user_input="${user_input:-$default_ans}"

    if [[ "$user_input" =~ ^[Yy]$ ]]; then
        return 0
    else
        return 1
    fi
}

# Pause until user presses Enter
press_enter_to_continue() {
    read -r -p "$(echo -e "\n${C_DIM}Nhấn [Enter] để quay lại menu...${C_RESET}")" _
}

# Initialize logging on load
init_logging
