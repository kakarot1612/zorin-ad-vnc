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

# Flush any pending or leftover characters in stdin buffer
flush_stdin() {
    local discard
    while read -t 0.05 -r discard 2>/dev/null; do :; done
}

# Prompt user for input with an optional default value
prompt_with_default() {
    local prompt_text="$1"
    local default_val="$2"
    local result_var="$3"
    local user_input

    flush_stdin

    if [[ -n "$default_val" ]]; then
        echo -e -n "${C_BOLD}${prompt_text}${C_RESET} [${C_CYAN}${default_val}${C_RESET}]: "
    else
        echo -e -n "${C_BOLD}${prompt_text}${C_RESET}: "
    fi

    if [[ -r /dev/tty ]]; then
        read -r user_input < /dev/tty
    else
        read -r user_input
    fi

    if [[ -z "$user_input" ]]; then
        eval "$result_var=\"$default_val\""
    else
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
        flush_stdin
        echo -e -n "${C_BOLD}${prompt_text}${C_RESET}: "
        if [[ -r /dev/tty ]]; then
            read -r -s pass1 < /dev/tty
        else
            read -r -s pass1
        fi
        echo ""

        if [[ -z "$pass1" ]]; then
            msg_warn "Mật khẩu không được để trống. Vui lòng nhập lại."
            continue
        fi

        if [[ "$confirm" == "true" ]]; then
            flush_stdin
            echo -e -n "${C_BOLD}Xác nhận lại mật khẩu${C_RESET}: "
            if [[ -r /dev/tty ]]; then
                read -r -s pass2 < /dev/tty
            else
                read -r -s pass2
            fi
            echo ""

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

    flush_stdin
    echo -e -n "${C_YELLOW}${prompt_text}${C_RESET} ${choice_str}: "
    if [[ -r /dev/tty ]]; then
        read -r user_input < /dev/tty
    else
        read -r user_input
    fi
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

# Normalize AD username and domain whether entered as user, user@domain.com, or DOMAIN\user
normalize_ad_user_and_domain() {
    local raw_input="$1"
    local default_domain="$2"
    local out_user_var="$3"
    local out_domain_var="$4"

    local parsed_user="$raw_input"
    local parsed_domain="${default_domain:-bestpacific.com}"

    if [[ "$raw_input" == *"@"* ]]; then
        parsed_user="${raw_input%%@*}"
        parsed_domain="${raw_input#*@}"
    elif [[ "$raw_input" == *"\\"* ]]; then
        parsed_domain="${raw_input%%\\*}"
        parsed_user="${raw_input#*\\}"
    elif [[ "$raw_input" == *"/"* ]]; then
        parsed_domain="${raw_input%%/*}"
        parsed_user="${raw_input#*/}"
    fi

    eval "$out_user_var=\"$parsed_user\""
    eval "$out_domain_var=\"$parsed_domain\""
}

# Get AD NetBIOS workgroup name (e.g. BESTPACIFIC from bestpacific.com)
get_ad_workgroup() {
    local domain="$1"
    local wg=""
    if command -v realm >/dev/null 2>&1; then
        wg=$(realm list 2>/dev/null | grep -E '^[[:space:]]*workgroup-name:' | awk '{print $2}' | head -n 1)
    fi
    if [[ -z "$wg" ]]; then
        wg="${domain%%.*}"
    fi
    echo "${wg^^}"
}

# URL encode string (RFC 3986)
urlencode() {
    local string="$1"
    if python3 -c "import urllib.parse" >/dev/null 2>&1; then
        python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$string"
    elif python -c "import urllib.parse" >/dev/null 2>&1; then
        python -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$string"
    else
        local strlen=${#string}
        local encoded=""
        local pos c o
        for (( pos=0 ; pos<strlen ; pos++ )); do
            c="${string:$pos:1}"
            case "$c" in
                [-_.~a-zA-Z0-9] ) o="${c}" ;;
                * ) printf -v o '%%%02X' "'$c" ;;
            esac
            encoded+="${o}"
        done
        echo "${encoded}"
    fi
}

# Check DNS name resolution and Ping / network port reachability
check_host_ping_and_resolve() {
    local target="$1"
    local desc="${2:-Máy chủ}"
    local -n out_ip="$3"

    if [[ -z "$target" ]]; then
        msg_err "LỖI: Tên máy chủ / IP không được để trống."
        return 1
    fi

    msg_info "Đang kiểm tra phân giải tên và kết nối mạng tới [${target}]..."

    local resolved_ip=""
    if [[ "$target" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        resolved_ip="$target"
    else
        # 1. Try direct hostname resolution
        resolved_ip=$(getent ahosts "$target" 2>/dev/null | awk '{print $1}' | head -n 1)
        if [[ -z "$resolved_ip" ]]; then
            resolved_ip=$(host "$target" 2>/dev/null | awk '/has address/ {print $NF}' | head -n 1)
        fi

        # 2. Try with Domain Suffix if target is a short name (VD: vn-printersrv -> vn-printersrv.bestpacific.com)
        if [[ -z "$resolved_ip" && "$target" != *"."* ]]; then
            local domain_suffix
            domain_suffix=$(realm list 2>/dev/null | grep -E '^[[:space:]]*domain-name:' | awk '{print $2}' | head -n 1)
            domain_suffix="${domain_suffix:-bestpacific.com}"
            msg_info "Thử phân giải với Domain Suffix [${target}.${domain_suffix}]..."
            resolved_ip=$(getent ahosts "${target}.${domain_suffix}" 2>/dev/null | awk '{print $1}' | head -n 1)
            if [[ -z "$resolved_ip" ]]; then
                resolved_ip=$(host "${target}.${domain_suffix}" 2>/dev/null | awk '/has address/ {print $NF}' | head -n 1)
            fi
        fi

        # 3. Try NetBIOS Name Resolution via nmblookup (Samba / Windows WINS broadcast)
        if [[ -z "$resolved_ip" ]] && command -v nmblookup >/dev/null 2>&1; then
            msg_info "Thử tra cứu NetBIOS Name (WINS broadcast) cho [${target}]..."
            resolved_ip=$(nmblookup "$target" 2>/dev/null | awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/ {print $1}' | head -n 1)
        fi
    fi

    if [[ -z "$resolved_ip" ]]; then
        msg_err "========================================================="
        msg_err "LỖI: Không thể phân giải tên [${target}] sang địa chỉ IP!"
        msg_err "Vui lòng kiểm tra lại cấu hình DNS hoặc nhập trực tiếp IP."
        msg_err "Hệ thống dừng thao tác. Tuyệt đối không kết nối khống!"
        msg_err "========================================================="
        return 1
    fi

    out_ip="$resolved_ip"

    local is_online=false
    # Check ICMP ping
    if ping -c 2 -W 2 "$resolved_ip" >/dev/null 2>&1; then
        is_online=true
        msg_ok "${desc} [${target}] (${resolved_ip}) phản hồi Ping tốt [ONLINE]."
    else
        # Fallback port check if ICMP ping is blocked by firewall (SMB 445/139, CUPS 631, RAW 9100)
        for port in 445 139 631 9100; do
            if timeout 2 bash -c "cat < /dev/null > /dev/tcp/${resolved_ip}/${port}" 2>/dev/null; then
                is_online=true
                msg_ok "${desc} [${target}] (${resolved_ip}) mở cổng dịch vụ ${port} [ONLINE]."
                break
            fi
        done
    fi

    if [[ "$is_online" != "true" ]]; then
        msg_err "========================================================="
        msg_err "LỖI MẠNG: Không thể Ping hoặc kết nối tới ${desc} [${target}] (${resolved_ip})!"
        msg_err "Thiết bị có thể đang tắt nguồn, đứt cáp mạng hoặc bị chặn tường lửa."
        msg_err "Hệ thống dừng thao tác. Tuyệt đối không kết nối khống!"
        msg_err "========================================================="
        return 1
    fi

    return 0
}

# Initialize logging on load
init_logging
