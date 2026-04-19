#!/usr/bin/env bash
#
# VPS Go — 一站式 VPS 管理脚本
#
# 模块:
#   1. 开启内核自带 BBR
#   2. 设置队列调度算法 (fq/cake/fq_pie)
#   3. 设置IPv4 / IPv6 优先级
#   4. TCP 缓冲区调优
#   5. iPerf3 测速服务端
#   6. NodeQuality 测试
#   7. Docker 日志轮转配置
#   8. Mihomo 管理 (安装/配置/重启/卸载)
#   9. Sing-Box 管理 (安装/自启/重启/日志/卸载)
#  10. Snell V5 管理 (官方安装/配置/重启/日志/卸载)
#  11. WireGuard 原生节点 (安装/部署/重启/状态/卸载)
#  12. Shadowsocks-Rust 管理 (安装/配置/重启/日志/卸载)
#  13. Akile DNS 解锁检测与配置
#  14. Linux DNS 管理 (临时/永久修改)
#  15. Swap 管理
#
# 使用方法: bash vpsgo.sh
#

# --- 强制 bash 运行 ---
if [ -z "${BASH_VERSION:-}" ]; then
    if command -v bash >/dev/null 2>&1; then
        exec bash "$0" "$@"
    else
        echo "[Error] bash is required to run this script."
        exit 1
    fi
fi

set -uo pipefail

VERSION="2.28"

# --- 全局变量 ---
SCRIPT_DIR="$(cd -P -- "$(dirname -- "$0")" && pwd -P)"
INSTALL_PATH="${VPSGO_INSTALL_PATH:-/usr/local/bin/vpsgo}"
UPDATE_URL="https://raw.githubusercontent.com/imNebula/vpsgo/refs/heads/main/vpsgo.sh"

# 颜色
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
BLUE='\033[1;34m'
MAGENTA='\033[1;35m'
DIM='\033[2m'
BOLD='\033[1m'
PLAIN='\033[0m'

# --- 通用工具函数 ---
_red()    { printf "${RED}%b${PLAIN}" "$1"; }
_green()  { printf "${GREEN}%b${PLAIN}" "$1"; }
_yellow() { printf "${YELLOW}%b${PLAIN}" "$1"; }
_cyan()   { printf "${CYAN}%b${PLAIN}" "$1"; }
_blue()   { printf "${BLUE}%b${PLAIN}" "$1"; }

_info() {
    printf "${CYAN}• ${PLAIN}%s\n" "$1"
}

_success() {
    printf "${GREEN}✔ ${PLAIN}%s\n" "$1"
}

_warn() {
    printf "${YELLOW}⚠ ${PLAIN}%s\n" "$1"
}

_error() {
    printf "${RED}✘ ${PLAIN}%s\n" "$1"
    exit 1
}

_error_no_exit() {
    printf "${RED}✘ ${PLAIN}%s\n" "$1"
}

_install_script_file() {
    local src="$1" dst="$2" dst_dir
    dst_dir="$(dirname "$dst")"

    mkdir -p "$dst_dir" || return 1

    if command -v install >/dev/null 2>&1; then
        install -m 0755 "$src" "$dst" || return 1
    else
        cp "$src" "$dst" || return 1
        chmod 0755 "$dst" || return 1
    fi

    chmod 0755 "$dst" || return 1
    return 0
}

_ensure_script_mode_ok() {
    local path="$1"
    [[ -f "$path" ]] || return 1
    [[ -r "$path" && -x "$path" ]] && return 0
    chmod 0755 "$path" 2>/dev/null || return 1
    [[ -r "$path" && -x "$path" ]]
}

_status_kv() {
    local key="$1" value="$2" tone="${3:-cyan}" key_width="${4:-8}"
    local value_color="$CYAN"
    case "$tone" in
        green) value_color="$GREEN" ;;
        yellow) value_color="$YELLOW" ;;
        red) value_color="$RED" ;;
        dim) value_color="$DIM" ;;
    esac
    printf "  ${DIM}·${PLAIN} "
    _ui_pad_right_text "$key" "$key_width"
    printf " ${DIM}:${PLAIN} ${value_color}%s${PLAIN}\n" "$value"
}

_ui_term_cols() {
    local cols
    cols=$(tput cols 2>/dev/null || true)
    if ! _is_digit "${cols:-}"; then
        cols=80
    fi
    [ "$cols" -lt 72 ] && cols=72
    [ "$cols" -gt 100 ] && cols=100
    printf '%s' "$cols"
}

_ui_clear_screen() {
    [ -t 1 ] || return 0
    if command -v tput >/dev/null 2>&1; then
        tput clear 2>/dev/null || printf '\033[2J\033[H'
    else
        printf '\033[2J\033[H'
    fi
}

_ui_repeat_char() {
    local char="$1" count="$2"
    local i
    for ((i=0; i<count; i++)); do
        printf '%s' "$char"
    done
}

_ui_display_width() {
    local s="$1"
    awk -v s="$s" '
        BEGIN {
            w=0
            for (i=1; i<=length(s); i++) {
                c=substr(s, i, 1)
                if (c ~ /[ -~]/) w+=1
                else w+=2
            }
            print w
        }
    '
}

_ui_truncate_text() {
    local text="$1" max="$2"
    if ! _is_digit "${max:-}" || [ "$max" -le 0 ]; then
        printf ''
        return
    fi
    awk -v s="$text" -v max="$max" '
        BEGIN {
            if (max <= 0) { print ""; exit }
            out=""
            w=0
            n=length(s)
            for (i=1; i<=n; i++) {
                c=substr(s, i, 1)
                cw=(c ~ /[ -~]/) ? 1 : 2
                if (w + cw > max) break
                out=out c
                w+=cw
            }
            if (i <= n) {
                if (max <= 3) {
                    print substr("...", 1, max)
                    exit
                }
                while (length(out) > 0 && w > max - 3) {
                    c=substr(out, length(out), 1)
                    cw=(c ~ /[ -~]/) ? 1 : 2
                    out=substr(out, 1, length(out)-1)
                    w-=cw
                }
                out=out "..."
            }
            print out
        }
    '
}

_ui_pad_right_text() {
    local text="$1" target="$2"
    local width pad
    width=$(_ui_display_width "$text")
    printf '%s' "$text"
    if [ "$width" -lt "$target" ]; then
        pad=$((target - width))
        _ui_repeat_char " " "$pad"
    fi
}

_header() {
    local title="$1"
    local cols rule_w line safe_title
    cols=$(_ui_term_cols)
    rule_w=$((cols - 8))
    [ "$rule_w" -lt 24 ] && rule_w=24
    [ "$rule_w" -gt 72 ] && rule_w=72
    safe_title=$(_ui_truncate_text "$title" "$rule_w")
    line=$(_ui_repeat_char "─" "$rule_w")

    _ui_clear_screen
    printf "${CYAN}%s${PLAIN}\n" "$line"
    printf "  ${BOLD}%s${PLAIN}\n" "$safe_title"
    printf "${DIM}%s${PLAIN}\n" "$line"
}

_separator() {
    local cols rule_w line
    cols=$(_ui_term_cols)
    rule_w=$((cols - 12))
    [ "$rule_w" -lt 20 ] && rule_w=20
    [ "$rule_w" -gt 64 ] && rule_w=64
    line=$(_ui_repeat_char "─" "$rule_w")
    printf "${DIM}  %s${PLAIN}\n" "$line"
}

_menu_item() {
    local key="$1" label="$2" desc="${3:-}" tone="${4:-green}"
    local color="$GREEN" key_token cols
    local label_max desc_max label_txt desc_txt
    case "$tone" in
        red) color="$RED" ;;
        yellow) color="$YELLOW" ;;
        cyan) color="$CYAN" ;;
    esac

    key_token="[${key}]"

    cols=$(_ui_term_cols)
    if [[ -n "$desc" ]]; then
        label_max=$(( (cols - 20) / 2 ))
        desc_max=$(( cols - 14 - label_max ))
        [ "$label_max" -lt 10 ] && label_max=10
        [ "$desc_max" -lt 10 ] && desc_max=10
        label_txt=$(_ui_truncate_text "$label" "$label_max")
        desc_txt=$(_ui_truncate_text "$desc" "$desc_max")
    else
        label_txt=$(_ui_truncate_text "$label" "$((cols - 12))")
        desc_txt=""
    fi

    printf "  ${color}%s${PLAIN} %s" "$key_token" "$label_txt"
    [[ -n "$desc_txt" ]] && printf " ${DIM}%s${PLAIN}" "$desc_txt"
    printf "\n"
}

_menu_cell() {
    local key="$1" label="$2" desc="${3:-}" tone="${4:-green}" width="${5:-56}"
    local color="$GREEN" key_token
    local label_max desc_max label_txt desc_txt
    local key_w label_w desc_w cell_w pad
    case "$tone" in
        red) color="$RED" ;;
        yellow) color="$YELLOW" ;;
        cyan) color="$CYAN" ;;
    esac

    key_token="[${key}]"

    if [[ -n "$desc" ]]; then
        label_max=$(( (width - 12) / 2 ))
        desc_max=$(( width - 8 - label_max ))
        [ "$label_max" -lt 10 ] && label_max=10
        [ "$desc_max" -lt 8 ] && desc_max=8
        label_txt=$(_ui_truncate_text "$label" "$label_max")
        desc_txt=$(_ui_truncate_text "$desc" "$desc_max")
    else
        label_txt=$(_ui_truncate_text "$label" "$((width - 8))")
        desc_txt=""
    fi

    key_w=$(_ui_display_width "$key_token")
    label_w=$(_ui_display_width "$label_txt")
    desc_w=0
    cell_w=$((key_w + 1 + label_w))
    if [[ -n "$desc_txt" ]]; then
        desc_w=$(_ui_display_width "$desc_txt")
        cell_w=$((cell_w + 1 + desc_w))
    fi

    pad=1
    if [ "$cell_w" -lt "$width" ]; then
        pad=$((width - cell_w))
    fi

    printf "${color}%s${PLAIN} %s" "$key_token" "$label_txt"
    [[ -n "$desc_txt" ]] && printf " ${DIM}%s${PLAIN}" "$desc_txt"
    _ui_repeat_char " " "$pad"
}

_menu_pair() {
    local k1="$1" l1="$2" d1="${3:-}" t1="${4:-green}"
    local k2="${5:-}" l2="${6:-}" d2="${7:-}" t2="${8:-green}"
    _menu_item "$k1" "$l1" "$d1" "$t1"
    [[ -n "$k2" ]] && _menu_item "$k2" "$l2" "$d2" "$t2"
}

_exists() {
    local cmd="$1"
    if eval type type > /dev/null 2>&1; then
        eval type "$cmd" > /dev/null 2>&1
    elif command > /dev/null 2>&1; then
        command -v "$cmd" > /dev/null 2>&1
    else
        which "$cmd" > /dev/null 2>&1
    fi
    return $?
}

_is_digit() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

_is_valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

_is_64bit() {
    [ "$(getconf WORD_BIT)" = '32' ] && [ "$(getconf LONG_BIT)" = '64' ]
}

_version_ge() {
    test "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1"
}

_press_any_key() {
    echo ""
    printf "${DIM}  继续请按任意键...${PLAIN}"
    local SAVEDSTTY
    SAVEDSTTY=$(stty -g)
    stty -echo -icanon
    dd if=/dev/tty bs=1 count=1 2>/dev/null
    stty "$SAVEDSTTY"
    echo ""
    _ui_clear_screen
}

_network_reboot_prompt() {
    printf "\n"
    printf "  ${YELLOW}⚠${PLAIN} ${BOLD}重启建议:${PLAIN} ${DIM}完成全部网络调优后再重启系统，确保配置完全生效。${PLAIN}\n"
}

# --- 系统信息检测 ---
_os() {
    local os=""
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        os="${ID:-}"
        [ -n "$os" ] && printf '%s' "${os}" && return
    fi
    [ -f "/etc/redhat-release" ] && os="centos" && printf '%s' "${os}" && return
}

_os_full() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        printf '%s' "${PRETTY_NAME:-unknown}"
    elif [ -f /etc/redhat-release ]; then
        cat /etc/redhat-release
    elif [ -f /etc/lsb-release ]; then
        awk -F'[="]+' '/DESCRIPTION/{print $2}' /etc/lsb-release
    else
        printf '%s' "unknown"
    fi
}

_os_ver() {
    local main_ver
    main_ver="$(echo "$(_os_full)" | grep -oE '[0-9.]+')"
    printf '%s' "${main_ver%%.*}"
}

_kernel_version() {
    uname -r | cut -d- -f1
}

_detect_virt() {
    local virt=""
    if command -v virt-what >/dev/null 2>&1; then
        virt="$(virt-what 2>/dev/null | head -1)"
    elif command -v systemd-detect-virt >/dev/null 2>&1; then
        virt="$(systemd-detect-virt 2>/dev/null)"
    fi
    if [ -z "$virt" ] || [ "$virt" = "none" ]; then
        if [ -d /proc/vz ] && [ ! -d /proc/bc ]; then
            virt="openvz"
        elif [ -f /proc/1/environ ] && grep -qa 'container=lxc' /proc/1/environ 2>/dev/null; then
            virt="lxc"
        fi
    fi
    printf '%s' "${virt:-none}"
}

_show_sys_info() {
    local opsy arch kern virt cols text_max
    opsy="$(_os_full)"
    arch="$(uname -m) ($(getconf LONG_BIT) Bit)"
    kern="$(uname -r)"
    virt="$(_detect_virt)"

    cols=$(_ui_term_cols)
    text_max=$((cols - 18))
    [ "$text_max" -lt 24 ] && text_max=24

    opsy=$(_ui_truncate_text "$opsy" "$text_max")
    arch=$(_ui_truncate_text "$arch" "$text_max")
    kern=$(_ui_truncate_text "$kern" "$text_max")
    virt=$(_ui_truncate_text "$virt" "$text_max")

    printf "  ${BOLD}系统信息${PLAIN}\n"
    _separator
    _status_kv "OS" "$opsy" "dim" 8
    _status_kv "Arch" "$arch" "dim" 8
    _status_kv "Kernel" "$kern" "dim" 8
    _status_kv "Virt" "$virt" "dim" 8
    _separator
}

_is_alpine() {
    [ -f /etc/os-release ] || return 1
    (
        . /etc/os-release
        [[ "${ID:-}" == "alpine" ]]
    )
}

_has_systemd() {
    command -v systemctl >/dev/null 2>&1 || return 1
    systemctl list-unit-files >/dev/null 2>&1
}

_has_openrc() {
    _is_alpine || return 1
    command -v rc-service >/dev/null 2>&1 || return 1
    command -v rc-update >/dev/null 2>&1 || return 1
    [ -d /etc/init.d ]
}

_openrc_service_in_default() {
    local svc="$1"
    rc-update show default 2>/dev/null | awk '{print $1}' | grep -qx "$svc"
}

_systemd_service_exists() {
    local svc="$1" state
    _has_systemd || return 1
    state=$(systemctl show -p LoadState --value "${svc}.service" 2>/dev/null || true)
    [ -n "$state" ] && [ "$state" != "not-found" ]
}

_service_script_exists() {
    local svc="$1"
    [ -n "$svc" ] || return 1
    [ -f "/etc/init.d/${svc}" ] || [ -x "/etc/init.d/${svc}" ]
}

_restart_first_available_service() {
    local svc
    for svc in "$@"; do
        [ -n "$svc" ] || continue
        if _systemd_service_exists "$svc"; then
            systemctl restart "$svc" >/dev/null 2>&1
            return $?
        fi
        if _has_openrc && _service_script_exists "$svc"; then
            rc-service "$svc" restart >/dev/null 2>&1 || rc-service "$svc" start >/dev/null 2>&1
            return $?
        fi
        if ! _has_systemd && ! _has_openrc && command -v service >/dev/null 2>&1 && _service_script_exists "$svc"; then
            service "$svc" restart >/dev/null 2>&1
            return $?
        fi
    done
    return 1
}

_kernel_module_is_loadable() {
    local module="$1"
    [ -n "$module" ] || return 1
    command -v modinfo >/dev/null 2>&1 || return 1
    modinfo "$module" >/dev/null 2>&1
}

_persist_kernel_module_load() {
    local module="$1" conf_name="${2:-$1}"
    local modules_file openrc_modules

    [ -n "$module" ] || return 1
    mkdir -p /etc/modules-load.d
    modules_file="/etc/modules-load.d/${conf_name}.conf"
    if [ ! -f "$modules_file" ] || ! grep -qx "$module" "$modules_file" 2>/dev/null; then
        printf '%s\n' "$module" >> "$modules_file"
    fi

    if _has_openrc; then
        openrc_modules="/etc/modules"
        [ -f "$openrc_modules" ] || touch "$openrc_modules"
        if ! grep -qx "$module" "$openrc_modules" 2>/dev/null; then
            printf '%s\n' "$module" >> "$openrc_modules"
        fi
    fi
}

_tail_log_files_interactive() {
    local service_name="$1" log_file="$2" err_file="$3" status_hint="${4:-}"
    local follow printed=0 follow_target=""

    echo ""
    [ -n "$log_file" ] && _status_kv "${service_name} log" "$log_file" "cyan" 12
    [ -n "$err_file" ] && _status_kv "${service_name} err" "$err_file" "cyan" 12

    if [[ -n "$log_file" && -f "$log_file" ]]; then
        _info "显示最近 50 行日志 (Ctrl+C 退出实时跟踪)"
        _separator
        echo ""
        tail -n 50 "$log_file"
        printed=1
        follow_target="$log_file"
    fi

    if [[ -n "$err_file" && -s "$err_file" ]]; then
        echo ""
        _separator
        _warn "错误日志最近 20 行:"
        tail -n 20 "$err_file"
        printed=1
        if [[ -n "$follow_target" ]]; then
            follow_target="${follow_target} ${err_file}"
        else
            follow_target="$err_file"
        fi
    elif [[ "$printed" -eq 0 && -n "$err_file" && -f "$err_file" ]]; then
        _info "显示最近 50 行错误日志 (Ctrl+C 退出实时跟踪)"
        _separator
        echo ""
        tail -n 50 "$err_file"
        printed=1
        follow_target="$err_file"
    fi

    if [[ "$printed" -eq 0 ]]; then
        _warn "未检测到日志文件"
        [ -n "$status_hint" ] && _info "可先执行: ${status_hint}"
        return 1
    fi

    echo ""
    _separator
    read -rp "  是否实时跟踪日志? [y/N]: " follow
    if [[ "$follow" =~ ^[Yy] ]]; then
        echo ""
        _info "按 Ctrl+C 退出实时日志..."
        echo ""
        # shellcheck disable=SC2086
        tail -f $follow_target
    fi
    return 0
}

# --- 系统时间同步检查 ---

_time_sync_is_enabled() {
    if command -v timedatectl >/dev/null 2>&1; then
        local ntp_val
        ntp_val=$(timedatectl show -p NTP --value 2>/dev/null || true)
        if [ "$ntp_val" = "yes" ]; then
            return 0
        fi
    fi

    if _has_systemd; then
        local svc
        for svc in systemd-timesyncd chronyd chrony ntp ntpd; do
            if systemctl is-active --quiet "$svc" 2>/dev/null || systemctl is-enabled --quiet "$svc" 2>/dev/null; then
                return 0
            fi
        done
    fi

    if _has_openrc; then
        local svc
        for svc in chronyd ntpd openntpd; do
            if [[ -x "/etc/init.d/${svc}" ]]; then
                if rc-service "$svc" status >/dev/null 2>&1 || _openrc_service_in_default "$svc"; then
                    return 0
                fi
            fi
        done
    fi
    return 1
}

_time_sync_try_enable() {
    if command -v timedatectl >/dev/null 2>&1; then
        timedatectl set-ntp true >/dev/null 2>&1 || true
        local ntp_val
        ntp_val=$(timedatectl show -p NTP --value 2>/dev/null || true)
        [ "$ntp_val" = "yes" ] && return 0
    fi

    if _has_systemd; then
        local svc
        for svc in systemd-timesyncd chronyd chrony ntp ntpd; do
            if systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx "${svc}.service"; then
                systemctl enable --now "$svc" >/dev/null 2>&1 || true
                if systemctl is-active --quiet "$svc" 2>/dev/null; then
                    return 0
                fi
            fi
        done
    fi

    if _has_openrc; then
        local svc
        for svc in chronyd ntpd openntpd; do
            if [[ -x "/etc/init.d/${svc}" ]]; then
                rc-update add "$svc" default >/dev/null 2>&1 || true
                rc-service "$svc" restart >/dev/null 2>&1 || rc-service "$svc" start >/dev/null 2>&1 || true
                if rc-service "$svc" status >/dev/null 2>&1; then
                    return 0
                fi
            fi
        done
    fi
    return 1
}

_time_sync_check_and_enable() {
    _info "检查系统时间自动同步..."
    if _time_sync_is_enabled; then
        _info "系统时间自动同步: 已开启"
        return 0
    fi

    _warn "系统时间自动同步未开启，尝试自动开启..."
    if _time_sync_try_enable; then
        _success "系统时间自动同步已开启"
        return 0
    fi

    if _has_openrc; then
        _warn "自动开启失败，Alpine 可执行: apk add chrony && rc-update add chronyd default && rc-service chronyd start"
    else
        _warn "自动开启失败，请手动检查 timedatectl 或 chrony/ntp 服务"
    fi
    return 1
}

# --- 1. 开启内核自带 BBR ---

_bbr_error_detect() {
    local cmd="$1"
    _info "执行: ${cmd}"
    eval ${cmd}
    if [ $? -ne 0 ]; then
        _error "命令执行失败: ${cmd}"
    fi
}

_bbr_check_status() {
    local param
    param=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    [[ "${param}" == "bbr" ]]
}

_bbr_check_kernel() {
    local kv
    kv="$(_kernel_version)"
    _version_ge "${kv}" "4.9"
}

_bbr_is_container_like() {
    local virt
    virt="$(_detect_virt)"
    case "$virt" in
        lxc|lxc-libvirt|openvz|docker|podman|containerd|systemd-nspawn)
            return 0
            ;;
    esac
    if grep -qaE '(docker|containerd|kubepods|lxc)' /proc/1/cgroup 2>/dev/null; then
        return 0
    fi
    return 1
}

_bbr_is_available() {
    local avail
    avail=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
    echo "$avail" | grep -qw bbr
}

_bbr_try_load_module() {
    command -v modprobe >/dev/null 2>&1 || return 1
    modprobe tcp_bbr >/dev/null 2>&1 || return 1
    _bbr_is_available
}

_bbr_persist_module_load() {
    _kernel_module_is_loadable "tcp_bbr" || return 0
    _persist_kernel_module_load "tcp_bbr" "vpsgo-bbr"
}

_bbr_print_alpine_hint() {
    _is_alpine || return 0

    if _bbr_is_container_like; then
        _warn "Alpine 容器/LXC 场景下，BBR 是否可用取决于宿主机内核与权限放行。"
        _warn "请在宿主机确认 tcp_bbr 可用，并允许容器写入相关 sysctl。"
        return 0
    fi

    _warn "Alpine 当前仅支持在现有内核已提供 BBR 时直接启用，不自动替换内核。"
    _warn "请检查: modprobe tcp_bbr && sysctl net.ipv4.tcp_available_congestion_control"
    _warn "若仍无 bbr，请改用支持 BBR 的 Alpine 镜像/内核（如较新的 virt/lts 内核）。"
}

_bbr_check_os() {
    local virt
    if _exists "virt-what"; then
        virt="$(virt-what)"
    elif _exists "systemd-detect-virt"; then
        virt="$(systemd-detect-virt)"
    fi
    if [ -n "${virt}" ] && [ "${virt}" = "lxc" ]; then
        _error "虚拟化架构为 LXC，不支持修改内核。"
    fi
    if [ -n "${virt}" ] && [ "${virt}" = "openvz" ] || [ -d "/proc/vz" ]; then
        _error "虚拟化架构为 OpenVZ，不支持修改内核。"
    fi
    [ -z "$(_os)" ] && _error "不支持的操作系统"
    case "$(_os)" in
        ubuntu)
            [ -n "$(_os_ver)" ] && [ "$(_os_ver)" -lt 16 ] && _error "不支持的系统版本，请升级到 Ubuntu 16+ 后重试。"
            ;;
        debian)
            [ -n "$(_os_ver)" ] && [ "$(_os_ver)" -lt 8 ] && _error "不支持的系统版本，请升级到 Debian 8+ 后重试。"
            ;;
        centos)
            [ -n "$(_os_ver)" ] && [ "$(_os_ver)" -lt 6 ] && _error "不支持的系统版本，请升级到 CentOS 6+ 后重试。"
            ;;
        alpine)
            _error "当前 Alpine 内核版本过低 (< 4.9)，无法启用 BBR。请升级到支持 BBR 的 Alpine 内核/镜像后重试。"
            ;;
        *)
            _error "不支持的操作系统"
            ;;
    esac
}

_bbr_sysctl_config() {
    local sysctl_file="/etc/sysctl.d/99-vpsgo-bbr.conf"
    local can_set_qdisc="0"

    mkdir -p /etc/sysctl.d
    [ -f /etc/sysctl.conf ] && sed -i '/^[[:space:]]*net\.core\.default_qdisc[[:space:]]*=/d' /etc/sysctl.conf
    [ -f /etc/sysctl.conf ] && sed -i '/^[[:space:]]*net\.ipv4\.tcp_congestion_control[[:space:]]*=/d' /etc/sysctl.conf
    [ -n "${_TCPTUNE_SYSCTL_FILE:-}" ] && [ -f "${_TCPTUNE_SYSCTL_FILE}" ] && {
        sed -i '/^[[:space:]]*net\.core\.default_qdisc[[:space:]]*=/d' "${_TCPTUNE_SYSCTL_FILE}"
        sed -i '/^[[:space:]]*net\.ipv4\.tcp_congestion_control[[:space:]]*=/d' "${_TCPTUNE_SYSCTL_FILE}"
    }

    if [ -f /proc/sys/net/core/default_qdisc ] || sysctl -n net.core.default_qdisc >/dev/null 2>&1; then
        can_set_qdisc="1"
    fi

    {
        echo "net.ipv4.tcp_congestion_control = bbr"
        if [ "$can_set_qdisc" = "1" ]; then
            echo "net.core.default_qdisc = fq"
        fi
    } > "$sysctl_file"

    # -e 忽略未知 key，避免容器内缺少 net.core.default_qdisc 时直接失败
    if ! sysctl -e -p "$sysctl_file" >/dev/null 2>&1; then
        _warn "sysctl 应用失败，尝试直接写入运行时参数..."
        sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true
        [ "$can_set_qdisc" = "1" ] && sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true
    fi

    if _bbr_check_status; then
        return 0
    fi

    if _bbr_is_container_like; then
        _warn "检测到容器环境，当前容器可能无权限修改拥塞控制参数（需宿主机放开）"
    fi
    return 1
}

_bbr_get_latest_version() {
    local latest_version
    latest_version=($(wget -qO- https://kernel.ubuntu.com/~kernel-ppa/mainline/ | awk -F'"v' '/v[4-9]./{print $2}' | cut -d/ -f1 | grep -v - | sort -V))
    [ ${#latest_version[@]} -eq 0 ] && _error "获取最新内核版本失败。"

    local kernel_arr=()
    for i in "${latest_version[@]}"; do
        if _version_ge "$i" "5.15"; then
            kernel_arr+=("$i")
        fi
    done

    echo ""
    echo "  可选内核版本:"
    _separator
    local idx=1
    for k in "${kernel_arr[@]}"; do
        printf "    ${GREEN}%d${PLAIN}) %s\n" "$idx" "$k"
        ((idx++))
    done
    echo ""

    local pick
    read -rp "  选择内核版本 (默认最新 ${kernel_arr[-1]}): " pick
    if [ -z "$pick" ]; then
        pick=${#kernel_arr[@]}
    fi
    if ! _is_digit "$pick" || [ "$pick" -lt 1 ] || [ "$pick" -gt ${#kernel_arr[@]} ]; then
        _error "无效的选择"
    fi
    local kernel="${kernel_arr[$((pick-1))]}"

    local deb_name deb_kernel_url deb_kernel_name
    local modules_deb_name deb_kernel_modules_url deb_kernel_modules_name

    if _is_64bit; then
        deb_name=$(wget -qO- "https://kernel.ubuntu.com/~kernel-ppa/mainline/v${kernel}/" | grep "linux-image" | grep "generic" | awk -F'">' '/amd64.deb/{print $2}' | cut -d'<' -f1 | head -1)
        deb_kernel_url="https://kernel.ubuntu.com/~kernel-ppa/mainline/v${kernel}/${deb_name}"
        deb_kernel_name="linux-image-${kernel}-amd64.deb"
        modules_deb_name=$(wget -qO- "https://kernel.ubuntu.com/~kernel-ppa/mainline/v${kernel}/" | grep "linux-modules" | grep "generic" | awk -F'">' '/amd64.deb/{print $2}' | cut -d'<' -f1 | head -1)
        deb_kernel_modules_url="https://kernel.ubuntu.com/~kernel-ppa/mainline/v${kernel}/${modules_deb_name}"
        deb_kernel_modules_name="linux-modules-${kernel}-amd64.deb"
    else
        deb_name=$(wget -qO- "https://kernel.ubuntu.com/~kernel-ppa/mainline/v${kernel}/" | grep "linux-image" | grep "generic" | awk -F'">' '/i386.deb/{print $2}' | cut -d'<' -f1 | head -1)
        deb_kernel_url="https://kernel.ubuntu.com/~kernel-ppa/mainline/v${kernel}/${deb_name}"
        deb_kernel_name="linux-image-${kernel}-i386.deb"
        modules_deb_name=$(wget -qO- "https://kernel.ubuntu.com/~kernel-ppa/mainline/v${kernel}/" | grep "linux-modules" | grep "generic" | awk -F'">' '/i386.deb/{print $2}' | cut -d'<' -f1 | head -1)
        deb_kernel_modules_url="https://kernel.ubuntu.com/~kernel-ppa/mainline/v${kernel}/${modules_deb_name}"
        deb_kernel_modules_name="linux-modules-${kernel}-i386.deb"
    fi
    [ -z "${deb_name}" ] && _error "获取内核安装包名称失败，可能是编译失败，请选择其他版本重试。"

    # 导出变量给后续使用
    BBR_KERNEL="${kernel}"
    BBR_DEB_NAME="${deb_name}"
    BBR_DEB_KERNEL_URL="${deb_kernel_url}"
    BBR_DEB_KERNEL_NAME="${deb_kernel_name}"
    BBR_MODULES_DEB_NAME="${modules_deb_name}"
    BBR_DEB_KERNEL_MODULES_URL="${deb_kernel_modules_url}"
    BBR_DEB_KERNEL_MODULES_NAME="${deb_kernel_modules_name}"
}

_bbr_install_kernel() {
    case "$(_os)" in
        centos)
            if [ -n "$(_os_ver)" ]; then
                if ! _exists "perl"; then
                    _bbr_error_detect "yum install -y perl"
                fi
                if [ "$(_os_ver)" -eq 6 ]; then
                    _bbr_error_detect "rpm --import https://www.elrepo.org/RPM-GPG-KEY-elrepo.org"
                    local rpm_kernel_url="https://dl.lamp.sh/files/"
                    local rpm_kernel_name rpm_kernel_devel_name
                    if _is_64bit; then
                        rpm_kernel_name="kernel-ml-4.18.20-1.el6.elrepo.x86_64.rpm"
                        rpm_kernel_devel_name="kernel-ml-devel-4.18.20-1.el6.elrepo.x86_64.rpm"
                    else
                        rpm_kernel_name="kernel-ml-4.18.20-1.el6.elrepo.i686.rpm"
                        rpm_kernel_devel_name="kernel-ml-devel-4.18.20-1.el6.elrepo.i686.rpm"
                    fi
                    _bbr_error_detect "wget -c -t3 -T60 -O ${rpm_kernel_name} ${rpm_kernel_url}${rpm_kernel_name}"
                    _bbr_error_detect "wget -c -t3 -T60 -O ${rpm_kernel_devel_name} ${rpm_kernel_url}${rpm_kernel_devel_name}"
                    [ -s "${rpm_kernel_name}" ] && _bbr_error_detect "rpm -ivh ${rpm_kernel_name}" || _error "下载 ${rpm_kernel_name} 失败。"
                    [ -s "${rpm_kernel_devel_name}" ] && _bbr_error_detect "rpm -ivh ${rpm_kernel_devel_name}" || _error "下载 ${rpm_kernel_devel_name} 失败。"
                    rm -f ${rpm_kernel_name} ${rpm_kernel_devel_name}
                    [ ! -f "/boot/grub/grub.conf" ] && _error "未找到 /boot/grub/grub.conf"
                    sed -i 's/^default=.*/default=0/g' /boot/grub/grub.conf
                elif [ "$(_os_ver)" -eq 7 ]; then
                    local rpm_kernel_url="https://dl.lamp.sh/kernel/el7/"
                    local rpm_kernel_name rpm_kernel_devel_name
                    if _is_64bit; then
                        rpm_kernel_name="kernel-ml-5.15.60-1.el7.x86_64.rpm"
                        rpm_kernel_devel_name="kernel-ml-devel-5.15.60-1.el7.x86_64.rpm"
                    else
                        _error "不支持 32 位架构，请切换到 64 位系统。"
                    fi
                    _bbr_error_detect "wget -c -t3 -T60 -O ${rpm_kernel_name} ${rpm_kernel_url}${rpm_kernel_name}"
                    _bbr_error_detect "wget -c -t3 -T60 -O ${rpm_kernel_devel_name} ${rpm_kernel_url}${rpm_kernel_devel_name}"
                    [ -s "${rpm_kernel_name}" ] && _bbr_error_detect "rpm -ivh ${rpm_kernel_name}" || _error "下载 ${rpm_kernel_name} 失败。"
                    [ -s "${rpm_kernel_devel_name}" ] && _bbr_error_detect "rpm -ivh ${rpm_kernel_devel_name}" || _error "下载 ${rpm_kernel_devel_name} 失败。"
                    rm -f ${rpm_kernel_name} ${rpm_kernel_devel_name}
                    /usr/sbin/grub2-set-default 0
                fi
            fi
            ;;
        ubuntu|debian)
            _info "正在获取最新内核版本..."
            _bbr_get_latest_version
            if [ -n "${BBR_MODULES_DEB_NAME}" ]; then
                _bbr_error_detect "wget -c -t3 -T60 -O ${BBR_DEB_KERNEL_MODULES_NAME} ${BBR_DEB_KERNEL_MODULES_URL}"
            fi
            _bbr_error_detect "wget -c -t3 -T60 -O ${BBR_DEB_KERNEL_NAME} ${BBR_DEB_KERNEL_URL}"
            _bbr_error_detect "dpkg -i ${BBR_DEB_KERNEL_MODULES_NAME} ${BBR_DEB_KERNEL_NAME}"
            rm -f ${BBR_DEB_KERNEL_MODULES_NAME} ${BBR_DEB_KERNEL_NAME}
            _bbr_error_detect "/usr/sbin/update-grub"
            ;;
        *)
            ;; # do nothing
    esac
}

_bbr_reboot_os() {
    _network_reboot_prompt
}

_bbr_install() {
    _header "TCP BBR 拥塞控制算法"

    local cc qdisc
    cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
    qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"
    printf "  ${BOLD}当前状态${PLAIN}\n"
    _status_kv "拥塞算法" "${cc}" "cyan"
    _status_kv "队列算法" "${qdisc}" "cyan"

    if _bbr_check_status; then
        printf "\n"
        _success "TCP BBR 已经启用，无需重复操作。"
        _press_any_key
        return
    fi

    if _bbr_check_kernel; then
        printf "\n"
        _info "当前内核版本 >= 4.9，直接启用 BBR..."
        if ! _bbr_is_available; then
            _warn "当前内核未报告 BBR 可用，尝试加载 tcp_bbr 模块..."
            if _bbr_try_load_module; then
                _success "tcp_bbr 模块加载成功"
            else
                _warn "tcp_bbr 模块加载失败，可能是内核未启用 BBR 或容器无权限加载模块"
            fi
        fi
        if ! _bbr_is_available; then
            _error_no_exit "未检测到 BBR 可用项: net.ipv4.tcp_available_congestion_control"
            _warn "请在宿主机确认内核已启用 BBR（模块 tcp_bbr）并允许容器写入相关 sysctl"
            _bbr_print_alpine_hint
            _press_any_key
            return
        fi
        _bbr_persist_module_load || true
        if _bbr_sysctl_config; then
            _success "TCP BBR 启用成功!"
        else
            if _bbr_is_container_like; then
                _warn "当前为容器环境，BBR 参数通常由宿主机控制；配置已落盘但容器内可能无法立即生效"
            else
                _warn "BBR 配置已写入，但需重启后生效"
            fi
        fi
        printf "\n  ${BOLD}变更后状态${PLAIN}\n"
        _status_kv "拥塞算法" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)" "green"
        _status_kv "队列算法" "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)" "green"
        if _is_alpine; then
            _info "Alpine 已额外写入 BBR 模块持久化配置，重启后会继续尝试加载 tcp_bbr。"
        fi
        _network_reboot_prompt
        _press_any_key
        return
    fi

    _bbr_check_os
    _bbr_install_kernel
    _bbr_sysctl_config
    _bbr_reboot_os
}

# --- 2. 设置队列调度算法 ---

_qdisc_check_virt() {
    local virt
    virt="$(_detect_virt)"
    case "$virt" in
        openvz|ovz)
            _error "检测到虚拟化架构为 OpenVZ，共享母机内核，无法修改队列算法。"
            ;;
        lxc|lxc-libvirt)
            _warn "检测到虚拟化架构为 LXC/LXD（容器），共享母机内核。"
            _warn "队列算法能否生效取决于母机，脚本将继续尝试..."
            ;;
    esac
}

_qdisc_is_enabled() {
    [ "$(sysctl -n net.core.default_qdisc 2>/dev/null || true)" = "$1" ]
}

_qdisc_is_active_on_ifaces() {
    local qdisc="$1"
    local iface
    iface="$(ip -o route show default 2>/dev/null | awk '{print $5; exit}')"
    [ -z "$iface" ] && return 1
    tc qdisc show dev "$iface" 2>/dev/null | grep -q "\b${qdisc}\b"
}

_qdisc_print_status() {
    local tone="${1:-cyan}"
    local current_qdisc current_cc
    current_qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"
    current_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
    _status_kv "队列算法" "${current_qdisc}" "${tone}"
    _status_kv "拥塞算法" "${current_cc}" "${tone}"
}

_qdisc_persist_module_load() {
    local qdisc="$1"
    local module="sch_${qdisc}"
    _kernel_module_is_loadable "$module" || return 0
    _persist_kernel_module_load "$module" "$qdisc"
}

_qdisc_apply_to_ifaces() {
    local qdisc="$1"
    local iface
    if ! command -v tc >/dev/null 2>&1; then
        _warn "tc 命令不可用，无法实时应用 ${qdisc}，将在重启后生效。"
        return 0
    fi
    while IFS= read -r iface; do
        [ -z "$iface" ] && continue
        if tc qdisc replace dev "$iface" root "$qdisc" 2>/dev/null; then
            _info "已对 ${iface} 实时应用 ${qdisc}"
        else
            _warn "无法对 ${iface} 应用 ${qdisc}（可能不支持）"
        fi
    done < <(ip -o link show up 2>/dev/null | awk -F': ' '{print $2}' | grep -v '^lo$')
}

_qdisc_enable_sysctl() {
    local qdisc="$1"
    local sysctl_file="/etc/sysctl.d/99-${qdisc}.conf"
    mkdir -p /etc/sysctl.d

    # 清理旧配置
    [ -f /etc/sysctl.conf ] && sed -i '/^[[:space:]]*net\.core\.default_qdisc[[:space:]]*=/d' /etc/sysctl.conf
    # 避免与 TCP 调优文件中的 default_qdisc 冲突，导致重启后回退
    [ -n "${_TCPTUNE_SYSCTL_FILE:-}" ] && [ -f "${_TCPTUNE_SYSCTL_FILE}" ] && sed -i '/^[[:space:]]*net\.core\.default_qdisc[[:space:]]*=/d' "${_TCPTUNE_SYSCTL_FILE}"
    for old in fq cake fq_pie; do
        [ "$old" = "$qdisc" ] && continue
        rm -f "/etc/sysctl.d/99-${old}.conf"
    done

    printf '%s\n' "net.core.default_qdisc = ${qdisc}" > "$sysctl_file"

    if ! sysctl -p "$sysctl_file" >/dev/null 2>&1; then
        _warn "sysctl -p 执行失败，可能是容器环境权限不足。"
        return 1
    fi

    _qdisc_apply_to_ifaces "$qdisc"
}

_qdisc_min_kernel_for() {
    case "$1" in
        fq)     echo "3.12" ;;
        cake)   echo "4.19" ;;
        fq_pie) echo "4.19" ;;
    esac
}

_qdisc_setup() {
    _header "队列调度算法 (Qdisc) 设置"

    printf "  ${BOLD}当前状态${PLAIN}\n"
    _qdisc_print_status
    _info "提示: 默认使用 fq 一般已足够，更换算法不一定带来性能提升"
    _qdisc_check_virt

    printf "  ${BOLD}请选择要启用的队列调度算法${PLAIN}\n"
    _separator
    _menu_pair "1" "fq" "Fair Queuing (>=3.12)" "green" "2" "cake" "CAKE (>=4.19)" "green"
    _menu_pair "3" "fq_pie" "FQ+PIE (>=4.19)" "green" "0" "返回主菜单" "" "red"
    _separator

    local choice
    read -rp "  选择 [0-3]: " choice

    local qdisc=""
    case "$choice" in
        1) qdisc="fq" ;;
        2) qdisc="cake" ;;
        3) qdisc="fq_pie" ;;
        0) return ;;
        *) _error_no_exit "无效选项: ${choice}"; _press_any_key; return ;;
    esac

    local kv min_kv
    kv="$(_kernel_version)"
    min_kv="$(_qdisc_min_kernel_for "$qdisc")"

    if ! _version_ge "$kv" "$min_kv"; then
        _warn "当前内核版本 ${kv} < ${min_kv}，不支持 ${qdisc}。"
        _warn "请先升级内核到 ${min_kv}+ 后再执行。"
        _press_any_key
        return
    fi

    if _qdisc_is_enabled "$qdisc" && _qdisc_is_active_on_ifaces "$qdisc"; then
        _success "${qdisc} 已经启用且在网卡上生效，无需重复设置。"
        _qdisc_print_status "green"
        _press_any_key
        return
    fi

    # 加载内核模块
    local module="sch_${qdisc}"
    if command -v modprobe >/dev/null 2>&1; then
        if ! modprobe "$module" >/dev/null 2>&1; then
            _warn "${module} 模块加载失败，可能内核未内置该模块。"
        fi
    fi

    _qdisc_persist_module_load "$qdisc"

    _info "内核版本 ${kv} (>= ${min_kv})，开始启用 ${qdisc} 队列算法..."
    _qdisc_enable_sysctl "$qdisc" || true

    printf "\n  ${BOLD}应用结果${PLAIN}\n"
    if _qdisc_is_enabled "$qdisc" && _qdisc_is_active_on_ifaces "$qdisc"; then
        _success "${qdisc} 启用成功并已在网卡上生效!"
        _qdisc_print_status "green"
    elif _qdisc_is_enabled "$qdisc"; then
        _info "${qdisc} sysctl 配置已生效，部分网卡可能需要重启后应用。"
        _qdisc_print_status "yellow"
    else
        _warn "已写入 sysctl 配置，但当前未检测到 ${qdisc} 生效。"
        _qdisc_print_status "red"
        _warn "可尝试: modprobe ${module} && sysctl -p"
    fi

    _network_reboot_prompt
    _press_any_key
}

# --- 3. 设置 IPv4/IPv6 优先级 ---

_V4V6_GAI_CONF="/etc/gai.conf"
_V4V6_RULE_V4="precedence ::ffff:0:0/96  100"
_V4V6_RULE_RE='^#?[[:space:]]*precedence[[:space:]]+::ffff:0:0/96'

_v4v6_detect_current() {
    if [ ! -f "$_V4V6_GAI_CONF" ]; then
        echo "v6"  # 无配置文件，系统默认 IPv6 优先
        return
    fi
    if grep -qE '^precedence[[:space:]]+::ffff:0:0/96[[:space:]]' "$_V4V6_GAI_CONF"; then
        echo "v4"
    else
        echo "v6"
    fi
}

_v4v6_set_ipv4_first() {
    _info "设置 IPv4 优先..."
    if [ ! -f "$_V4V6_GAI_CONF" ]; then
        echo "$_V4V6_RULE_V4" > "$_V4V6_GAI_CONF"
        _info "创建 $_V4V6_GAI_CONF 并写入 IPv4 优先规则"
        return
    fi
    if grep -qE "$_V4V6_RULE_RE" "$_V4V6_GAI_CONF"; then
        sed -i -E "s|${_V4V6_RULE_RE}.*|${_V4V6_RULE_V4}|" "$_V4V6_GAI_CONF"
        _info "已更新 IPv4 优先规则 (precedence 100)"
    else
        echo "$_V4V6_RULE_V4" >> "$_V4V6_GAI_CONF"
        _info "已追加 IPv4 优先规则"
    fi
}

_v4v6_set_ipv6_first() {
    _info "设置 IPv6 优先..."
    if [ ! -f "$_V4V6_GAI_CONF" ]; then
        _info "无需修改，系统默认已是 IPv6 优先"
        return
    fi
    if grep -qE '^precedence[[:space:]]+::ffff:0:0/96[[:space:]]' "$_V4V6_GAI_CONF"; then
        sed -i -E 's|^(precedence[[:space:]]+::ffff:0:0/96.*)|# \1|' "$_V4V6_GAI_CONF"
        _info "已注释 IPv4 优先规则，恢复 IPv6 优先"
    else
        _info "无需修改，当前已是 IPv6 优先"
    fi
}

_v4v6_show_exits() {
    _info "正在探测出口 IP..."
    local ip4 ip6
    ip4=$(curl -4 -s -m 5 ip.sb 2>/dev/null || true)
    ip6=$(curl -6 -s -m 5 ip.sb 2>/dev/null || true)
    if [ -n "$ip4" ]; then
        printf "    ${YELLOW}IPv4 出口: %s${PLAIN}\n" "$ip4"
    else
        printf "    ${RED}IPv4 出口: 不可用${PLAIN}\n"
    fi
    if [ -n "$ip6" ]; then
        printf "    ${CYAN}IPv6 出口: %s${PLAIN}\n" "$ip6"
    else
        printf "    ${RED}IPv6 出口: 不可用${PLAIN}\n"
    fi
}

_v4v6_verify_ip() {
    _info "正在验证当前出口 IP..."
    local ip
    ip=$(curl -s -m 5 ip.sb || true)
    if [ -z "$ip" ]; then
        _error_no_exit "无法获取 IP，请检查网络"
        return
    fi
    printf "    ${YELLOW}出口 IP: %s${PLAIN}\n" "$ip"
    if echo "$ip" | grep -q ':'; then
        _info "当前出口为 IPv6"
    else
        _info "当前出口为 IPv4"
    fi
}

_v4v6_setup() {
    _header "IPv4 / IPv6 优先级切换"

    local current
    current="$(_v4v6_detect_current)"
    echo ""
    if [ "$current" = "v4" ]; then
        printf "  ${BOLD}当前状态:${PLAIN} ${YELLOW}IPv4 优先${PLAIN}\n"
    else
        printf "  ${BOLD}当前状态:${PLAIN} ${CYAN}IPv6 优先${PLAIN}\n"
    fi
    echo ""
    _v4v6_show_exits

    printf "  ${BOLD}请选择操作${PLAIN}\n"
    _separator
    _menu_pair "1" "设置 IPv4 优先" "" "green" "2" "设置 IPv6 优先" "" "green"
    _menu_item "0" "返回主菜单" "" "red"
    _separator

    local choice
    read -rp "  选择 [0-2]: " choice

    case "$choice" in
        1) _v4v6_set_ipv4_first ;;
        2) _v4v6_set_ipv6_first ;;
        0) return ;;
        *) _error_no_exit "无效选项: ${choice}"; _press_any_key; return ;;
    esac

    echo ""
    _v4v6_verify_ip
    _press_any_key
}

# --- 4. TCP 调优 ---

_TCPTUNE_SYSCTL_FILE="/etc/sysctl.d/99-proxy-tcp-bbr-fq.conf"
_TCPTUNE_BACKUP_DIR="/root/tcp_tuning_backups"
_TCPTUNE_MIN_CEILING_BYTES=$((8 * 1024 * 1024))
_TCPTUNE_MAX_CEILING_BYTES=$((256 * 1024 * 1024))
_TCPTUNE_CORE_MAX_FLOOR_BYTES=$((128 * 1024 * 1024))
_TCPTUNE_CAKE_SERVICE_NAME="vpsgo-tc-cake.service"
_TCPTUNE_CAKE_SERVICE_FILE="/etc/systemd/system/${_TCPTUNE_CAKE_SERVICE_NAME}"
_TCPTUNE_CAKE_OPENRC_SERVICE_NAME="vpsgo-tc-cake"
_TCPTUNE_CAKE_OPENRC_SERVICE_FILE="/etc/init.d/${_TCPTUNE_CAKE_OPENRC_SERVICE_NAME}"
_TCPTUNE_CAKE_APPLY_SCRIPT="/usr/local/bin/vpsgo-apply-cake.sh"
_TCPTUNE_LAST_BACKUP_FILE=""
_TCPTUNE_LAST_IFACE=""
_TCPTUNE_LAST_CEILING_BYTES=$((64 * 1024 * 1024))
_TCPTUNE_LAST_QDISC_MODE="fq"
_TCPTUNE_LAST_CAKE_BW_MBIT=0
_TCPTUNE_CONFLICTS=""

_tcptune_sysctl_get() {
    local key="$1" fallback="${2:-N/A}" value
    value=$(sysctl -n "$key" 2>/dev/null || true)
    if [ -z "$value" ]; then
        printf '%s' "$fallback"
    else
        printf '%s' "$value"
    fi
}

_tcptune_escape_ere() {
    printf '%s' "$1" | sed -E 's/[][(){}.^$*+?|\\/]/\\&/g'
}

_tcptune_bytes_to_mib_text() {
    awk -v b="$1" 'BEGIN { printf "%.2f MiB", b / 1024 / 1024 }'
}

_tcptune_core_cap_bytes() {
    local cap_bytes="$1"
    if [ "$cap_bytes" -lt "$_TCPTUNE_CORE_MAX_FLOOR_BYTES" ]; then
        printf '%s' "$_TCPTUNE_CORE_MAX_FLOOR_BYTES"
    else
        printf '%s' "$cap_bytes"
    fi
}

_tcptune_guess_iface() {
    local iface
    iface=$(ip -4 route show default 2>/dev/null | awk '{print $5}' | head -n1)
    [ -z "$iface" ] && iface=$(ip -6 route show default 2>/dev/null | awk '{print $5}' | head -n1)
    printf '%s' "$iface"
}

_tcptune_detect_link_speed() {
    local iface="$1" speed=""
    [ -z "$iface" ] && return 0
    if command -v ethtool >/dev/null 2>&1; then
        speed=$(ethtool "$iface" 2>/dev/null | awk -F: '/[Ss]peed:/ { gsub(/[^0-9]/, "", $2); print $2; exit }')
    fi
    if [ -z "$speed" ] && [ -r "/sys/class/net/${iface}/speed" ]; then
        speed=$(cat "/sys/class/net/${iface}/speed" 2>/dev/null || true)
    fi
    if ! _is_digit "${speed:-}" || [ "$speed" -le 0 ]; then
        speed=""
    fi
    printf '%s' "$speed"
}

_tcptune_detect_qdisc_mode() {
    local iface="$1"
    local current qdisc_output

    current=$(sysctl -n net.core.default_qdisc 2>/dev/null || true)
    case "$current" in
        cake) printf '%s' "cake"; return ;;
        fq) printf '%s' "fq"; return ;;
    esac

    if [ -n "$iface" ] && command -v tc >/dev/null 2>&1; then
        qdisc_output=$(tc qdisc show dev "$iface" 2>/dev/null || true)
        if echo "$qdisc_output" | grep -qE '\bcake\b'; then
            printf '%s' "cake"
            return
        fi
    fi

    printf '%s' "fq"
}

_tcptune_align_up_mib() {
    local value="$1"
    local mib=$((1024 * 1024))
    printf '%s' $(( (value + mib - 1) / mib * mib ))
}

_tcptune_calc_bdp_bytes() {
    local target_mbit="$1" rtt_ms="$2"
    # BDP_bytes = target_mbit × RTT_ms × 125
    printf '%s' $((target_mbit * rtt_ms * 125))
}

_tcptune_prompt_positive_int() {
    local prompt="$1" default="$2" input
    while true; do
        read -rp "  ${prompt} [默认 ${default}]: " input
        input="${input:-$default}"
        if _is_digit "$input" && [ "$input" -gt 0 ]; then
            printf '%s' "$input"
            return
        fi
        _warn "请输入大于 0 的整数。"
    done
}

_tcptune_prompt_required_positive_int() {
    local prompt="$1" input
    while true; do
        read -rp "  ${prompt}: " input
        if _is_digit "$input" && [ "$input" -gt 0 ]; then
            printf '%s' "$input"
            return
        fi
        _warn "请输入大于 0 的整数，且不要直接按回车。"
    done
}

_tcptune_show_current() {
    local iface qline
    echo ""
    printf "  ${BOLD}当前关键参数${PLAIN}\n"
    _separator
    _status_kv "congestion" "$(_tcptune_sysctl_get net.ipv4.tcp_congestion_control)" "dim" 18
    _status_kv "default_qdisc" "$(_tcptune_sysctl_get net.core.default_qdisc)" "dim" 18
    _status_kv "tcp_rmem" "$(_tcptune_sysctl_get net.ipv4.tcp_rmem)" "dim" 18
    _status_kv "tcp_wmem" "$(_tcptune_sysctl_get net.ipv4.tcp_wmem)" "dim" 18
    _status_kv "rmem_max" "$(_tcptune_sysctl_get net.core.rmem_max)" "dim" 18
    _status_kv "wmem_max" "$(_tcptune_sysctl_get net.core.wmem_max)" "dim" 18
    _status_kv "somaxconn" "$(_tcptune_sysctl_get net.core.somaxconn)" "dim" 18
    _status_kv "netdev_budget" "$(_tcptune_sysctl_get net.core.netdev_budget)" "dim" 18
    _status_kv "tcp_frto" "$(_tcptune_sysctl_get net.ipv4.tcp_frto)" "dim" 18
    iface="$(_tcptune_guess_iface)"
    if [ -n "$iface" ] && command -v tc >/dev/null 2>&1; then
        qline=$(tc qdisc show dev "$iface" 2>/dev/null | head -n1)
        [ -z "$qline" ] && qline="(无法读取)"
        _status_kv "qdisc(${iface})" "$qline" "dim" 18
    fi
}

_tcptune_choose_ceiling() {
    local link_speed="$1"
    local choice bw_mbps max_rtt_ms bdp_bytes cap_bytes max_bw_mbps rtt

    echo ""
    printf "  ${BOLD}选择配置模式${PLAIN}\n"
    _info "预设档位是经验值，不是带宽/RTT 的硬上限。"
    _separator
    _menu_item "1" "自动计算 (带宽 + RTT)" "ceiling=align_up(max(2×BDP,8MiB),1MiB)" "green"
    _menu_item "2" "16 MiB" "经验档位: 低 RTT / 轻负载" "green"
    _menu_item "3" "32 MiB" "经验档位: 中 RTT / 通用" "green"
    _menu_item "4" "64 MiB" "经验档位: 高 RTT / 跨区推荐" "green"
    _menu_item "5" "128 MiB" "经验档位: 高带宽或高并发" "green"
    _separator
    read -rp "  选择 [1-5，默认 4]: " choice
    choice="${choice:-4}"

    case "$choice" in
        1)
            if _is_digit "${link_speed:-}" && [ "$link_speed" -gt 0 ]; then
                _info "检测到网卡协商速率 ${link_speed} Mbps，仅供参考；请按上游真实限速或压测结果填写瓶颈带宽。"
            else
                _info "请按上游真实限速或压测结果填写瓶颈带宽，不要按网卡名义速率估算。"
            fi
            bw_mbps=$(_tcptune_prompt_required_positive_int "输入瓶颈带宽 (Mbps)")
            echo ""
            printf "  ${BOLD}RTT 输入建议${PLAIN}\n"
            _separator
            printf "    使用客户端到本机的 RTT P95，建议再留 10%%-20%% 裕量。\n"
            printf "    参考: 同区 10-60ms，跨区 60-150ms，跨洋 150-300ms。\n"
            printf "    不确定可先填 200，再根据压测结果微调。\n"
            max_rtt_ms=$(_tcptune_prompt_positive_int "输入 RTT(P95/最大) (ms)" "200")
            bdp_bytes=$(_tcptune_calc_bdp_bytes "$bw_mbps" "$max_rtt_ms")
            cap_bytes=$((bdp_bytes * 2))
            [ "$cap_bytes" -lt "$_TCPTUNE_MIN_CEILING_BYTES" ] && cap_bytes="$_TCPTUNE_MIN_CEILING_BYTES"
            cap_bytes=$(_tcptune_align_up_mib "$cap_bytes")
            [ "$cap_bytes" -gt "$_TCPTUNE_MAX_CEILING_BYTES" ] && cap_bytes="$_TCPTUNE_MAX_CEILING_BYTES"
            _status_kv "BDP(单流)" "$(_tcptune_bytes_to_mib_text "$bdp_bytes") (${bw_mbps}Mbps x ${max_rtt_ms}ms x 125)" "green" 18
            _status_kv "ceiling(2xBDP)" "$(_tcptune_bytes_to_mib_text "$cap_bytes")" "green" 18
            ;;
        2) cap_bytes=$((16 * 1024 * 1024)) ;;
        3) cap_bytes=$((32 * 1024 * 1024)) ;;
        4) cap_bytes=$((64 * 1024 * 1024)) ;;
        5) cap_bytes=$((128 * 1024 * 1024)) ;;
        *)
            _warn "无效选项，使用默认 64 MiB。"
            cap_bytes=$((64 * 1024 * 1024))
            ;;
    esac

    _TCPTUNE_LAST_CEILING_BYTES="$cap_bytes"
    echo ""
    _status_kv "最终 ceiling" "$(_tcptune_bytes_to_mib_text "$_TCPTUNE_LAST_CEILING_BYTES")" "green" 18

    echo ""
    printf "  ${BOLD}理论覆盖 (单流上限估算)${PLAIN}\n"
    _separator
    for rtt in 20 50 60 100 150 200 300; do
        max_bw_mbps=$(( _TCPTUNE_LAST_CEILING_BYTES * 8 * 1000 / (rtt * 1000000) ))
        printf "    RTT %3d ms -> 约 %4d Mbps\n" "$rtt" "$max_bw_mbps"
    done
}

_tcptune_choose_cake_bandwidth() {
    local link_speed="$1"
    local bw_mbit

    echo ""
    printf "  ${BOLD}CAKE 带宽上限设置${PLAIN}\n"
    _separator
    _info "请填写线路可稳定跑满的真实上限值，通常取压测稳定值的 90%-98%。"
    if _is_digit "${link_speed:-}" && [ "$link_speed" -gt 0 ]; then
        _info "检测到网卡协商速率 ${link_speed} Mbps，仅供参考，不能替代真实出口带宽。"
    fi
    bw_mbit=$(_tcptune_prompt_required_positive_int "输入 CAKE 带宽上限 (Mbps)")
    _TCPTUNE_LAST_CAKE_BW_MBIT="$bw_mbit"
    _status_kv "CAKE 带宽上限" "${_TCPTUNE_LAST_CAKE_BW_MBIT} Mbps" "green" 18
}

_tcptune_cake_service_label() {
    if _has_openrc; then
        printf '%s' "$_TCPTUNE_CAKE_OPENRC_SERVICE_NAME"
        return
    fi
    printf '%s' "$_TCPTUNE_CAKE_SERVICE_NAME"
}

_tcptune_disable_cake_persist() {
    local changed=0

    if _has_systemd; then
        systemctl disable --now "$_TCPTUNE_CAKE_SERVICE_NAME" >/dev/null 2>&1 || true
    fi
    if _has_openrc; then
        rc-service "$_TCPTUNE_CAKE_OPENRC_SERVICE_NAME" stop >/dev/null 2>&1 || true
        rc-update del "$_TCPTUNE_CAKE_OPENRC_SERVICE_NAME" default >/dev/null 2>&1 || true
    fi

    if [ -f "$_TCPTUNE_CAKE_SERVICE_FILE" ]; then
        rm -f "$_TCPTUNE_CAKE_SERVICE_FILE"
        changed=1
    fi
    if [ -f "$_TCPTUNE_CAKE_OPENRC_SERVICE_FILE" ]; then
        rm -f "$_TCPTUNE_CAKE_OPENRC_SERVICE_FILE"
        changed=1
    fi
    if [ -f "$_TCPTUNE_CAKE_APPLY_SCRIPT" ]; then
        rm -f "$_TCPTUNE_CAKE_APPLY_SCRIPT"
        changed=1
    fi

    if [ "$changed" -eq 1 ]; then
        if _has_systemd; then
            systemctl daemon-reload >/dev/null 2>&1 || true
        fi
        _info "已清理 CAKE 持久化配置，避免与 FQ 路径冲突。"
    fi
}

_tcptune_enable_cake_persist() {
    local iface="$1" bw_mbit="$2"
    local script_tmp service_tmp openrc_tmp

    if [ -z "$iface" ] || ! _is_digit "${bw_mbit:-}" || [ "$bw_mbit" -le 0 ]; then
        _warn "CAKE 持久化参数无效，跳过开机应用配置。"
        return 1
    fi

    _tcptune_disable_cake_persist

    script_tmp="${_TCPTUNE_CAKE_APPLY_SCRIPT}.tmp.$$"
    cat > "$script_tmp" << 'EOF'
#!/usr/bin/env bash
set -uo pipefail

iface="${1:-}"
bw_mbit="${2:-}"
qdisc_output=""
parents=""
parent_count=0
per_queue_bw=0

if [ -z "$iface" ] || [ -z "$bw_mbit" ]; then
    exit 0
fi
if ! command -v tc >/dev/null 2>&1; then
    exit 0
fi

if tc qdisc replace dev "$iface" root cake bandwidth "${bw_mbit}mbit" >/dev/null 2>&1; then
    exit 0
fi

qdisc_output=$(tc qdisc show dev "$iface" 2>/dev/null || true)
if ! echo "$qdisc_output" | grep -q "^qdisc mq "; then
    exit 0
fi

parents=$(printf '%s\n' "$qdisc_output" | awk '$4=="parent" { gsub(":", "", $5); if ($5 != "") print $5 }' | sort -u)
parent_count=$(printf '%s\n' "$parents" | sed '/^$/d' | wc -l | awk '{print $1}')
if [ "$parent_count" -le 0 ]; then
    exit 0
fi

per_queue_bw=$((bw_mbit / parent_count))
if [ "$per_queue_bw" -lt 1 ]; then
    per_queue_bw=1
fi

while IFS= read -r parent; do
    [ -z "$parent" ] && continue
    tc qdisc replace dev "$iface" parent "${parent}:" cake bandwidth "${per_queue_bw}mbit" >/dev/null 2>&1 || true
done <<< "$parents"
EOF
    mv "$script_tmp" "$_TCPTUNE_CAKE_APPLY_SCRIPT"
    chmod 0755 "$_TCPTUNE_CAKE_APPLY_SCRIPT"

    if _has_systemd; then
        service_tmp="${_TCPTUNE_CAKE_SERVICE_FILE}.tmp.$$"
        cat > "$service_tmp" << EOF
[Unit]
Description=vpsgo apply CAKE qdisc bandwidth cap
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${_TCPTUNE_CAKE_APPLY_SCRIPT} ${iface} ${bw_mbit}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        mv "$service_tmp" "$_TCPTUNE_CAKE_SERVICE_FILE"

        systemctl daemon-reload >/dev/null 2>&1 || true
        if systemctl enable --now "$_TCPTUNE_CAKE_SERVICE_NAME" >/dev/null 2>&1; then
            _success "CAKE 带宽上限已设置并持久化: ${bw_mbit} Mbps (${iface})"
            return 0
        fi
        _warn "CAKE 持久化服务启用失败，可手动执行: systemctl enable --now ${_TCPTUNE_CAKE_SERVICE_NAME}"
        return 1
    fi

    if _has_openrc; then
        openrc_tmp="${_TCPTUNE_CAKE_OPENRC_SERVICE_FILE}.tmp.$$"
        cat > "$openrc_tmp" << EOF
#!/sbin/openrc-run
description="vpsgo apply CAKE qdisc bandwidth cap"

depend() {
    need net
}

start() {
    ebegin "Applying CAKE qdisc to ${iface}"
    ${_TCPTUNE_CAKE_APPLY_SCRIPT} ${iface} ${bw_mbit} >/dev/null 2>&1
    eend \$?
}
EOF
        mv "$openrc_tmp" "$_TCPTUNE_CAKE_OPENRC_SERVICE_FILE"
        chmod 0755 "$_TCPTUNE_CAKE_OPENRC_SERVICE_FILE"
        if ! rc-update add "$_TCPTUNE_CAKE_OPENRC_SERVICE_NAME" default >/dev/null 2>&1; then
            if ! _openrc_service_in_default "$_TCPTUNE_CAKE_OPENRC_SERVICE_NAME"; then
                _warn "CAKE OpenRC 持久化启用失败，请检查 rc-update 状态"
                return 1
            fi
        fi
        if rc-service "$_TCPTUNE_CAKE_OPENRC_SERVICE_NAME" start >/dev/null 2>&1; then
            _success "CAKE 带宽上限已设置并持久化: ${bw_mbit} Mbps (${iface})"
            return 0
        fi
        _warn "CAKE 持久化脚本已写入，但 OpenRC 启动失败，可手动执行: rc-service ${_TCPTUNE_CAKE_OPENRC_SERVICE_NAME} start"
        return 1
    fi

    _warn "未检测到 systemd/OpenRC，已写入 CAKE 脚本但未自动配置开机应用。"
    return 1
}

_tcptune_ensure_bbr_available() {
    local avail
    avail=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
    if echo "$avail" | grep -qw bbr; then
        _success "检测到 BBR 可用。"
        return 0
    fi

    _warn "当前未检测到 BBR，尝试加载 tcp_bbr 模块..."
    modprobe tcp_bbr 2>/dev/null || true
    avail=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
    if echo "$avail" | grep -qw bbr; then
        _success "tcp_bbr 模块加载成功。"
        return 0
    fi
    return 1
}

_tcptune_backup_runtime() {
    local iface="$1" backup_file
    mkdir -p "$_TCPTUNE_BACKUP_DIR"
    backup_file="${_TCPTUNE_BACKUP_DIR}/sysctl_backup_$(date +%Y%m%d_%H%M%S).conf"
    {
        printf "# TCP Tuning Backup - %s\n" "$(date)"
        printf "# Kernel: %s\n" "$(uname -r)"
        printf "# Interface: %s\n" "${iface:-N/A}"
        printf "# Source: sysctl -a filtered snapshot\n\n"
        sysctl -a 2>/dev/null | grep -E "^net\.(core\.(rmem|wmem|somaxconn|netdev_max_backlog|netdev_budget|default_qdisc|busy_(poll|read)|optmem_max)|ipv4\.tcp_(rmem|wmem|congestion|frto|slow_start|notsent|window_scaling|timestamps|sack|moderate|mtu_probing|limit_output_bytes|fastopen|fin_timeout|keepalive|max_tw|tw_reuse|max_syn|syncookies|max_orphans|adv_win)|ipv4\.ip_local_port_range)" | sort
        printf "fs.file-max = %s\n" "$(_tcptune_sysctl_get fs.file-max)"
    } > "$backup_file"
    _TCPTUNE_LAST_BACKUP_FILE="$backup_file"
    _success "已备份当前配置: ${backup_file}"
}

_tcptune_write_sysctl_conf() {
    local cap_bytes="$1"
    local cap_mib core_cap_bytes tmp_file backup_file
    cap_mib=$((cap_bytes / 1024 / 1024))
    core_cap_bytes=$(_tcptune_core_cap_bytes "$cap_bytes")
    tmp_file="${_TCPTUNE_SYSCTL_FILE}.tmp.$$"

    cat > "$tmp_file" << EOF
# ================================================================
# Azure / Proxy TCP Baseline (BBR + FQ + autotuning)
# Generated: $(date)
# TCP autotune ceiling: ${cap_bytes} bytes (${cap_mib} MiB)
# core.rmem_max/core.wmem_max floor: ${core_cap_bytes} bytes
#
# References:
#   - Microsoft Learn: Optimize Azure VM network throughput
#   - Microsoft Learn: TCP/IP performance tuning for Azure VMs
#   - Linux Kernel Documentation/networking/ip-sysctl.rst
#
# Baseline:
#   1) BBR + fq pacing
#   2) 保留 TCP autotune，只提高 ceiling
#   3) 默认不碰 tcp_mem/udp_mem、socket default buffer、tw_reuse/timestamps
#   4) PMTUD/low-latency 相关项按需启用，不默认落盘
# ================================================================

# ---- [A] 拥塞控制 + 队列调度 ----
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq

# ---- [B] TCP autotune ceiling ----
# BDP_bytes = target_mbit x RTT_ms x 125
# ceiling = align_up(max(2 x BDP, 8MiB), 1MiB)
net.ipv4.tcp_rmem = 4096 131072 ${cap_bytes}
net.ipv4.tcp_wmem = 4096 65536 ${cap_bytes}
net.core.rmem_max = ${core_cap_bytes}
net.core.wmem_max = ${core_cap_bytes}

# ---- [C] 出站连接 / 突发流量 ----
net.ipv4.ip_local_port_range = 1024 65535
net.core.somaxconn = 32768
net.core.netdev_max_backlog = 16384
net.core.netdev_budget = 600

# ---- [D] 数据中心 / 有线网络默认项 ----
net.ipv4.tcp_frto = 0

# ---- [E] 按需启用的排障项 ----
# 仅在确认存在 PMTUD blackhole / 大包卡顿时启用:
# net.ipv4.tcp_mtu_probing = 1
#
# 尾延迟偏高时，可试 1048576 或 2097152 限制本机排队深度:
# net.ipv4.tcp_limit_output_bytes = 1048576
#
# busy_poll / busy_read 会额外消耗 CPU，默认保持关闭:
# net.core.busy_poll = 50
# net.core.busy_read = 50
EOF

    if [ -f "$_TCPTUNE_SYSCTL_FILE" ]; then
        backup_file="${_TCPTUNE_SYSCTL_FILE}.bak.$(date +%Y%m%d%H%M%S)"
        cp "$_TCPTUNE_SYSCTL_FILE" "$backup_file"
        _info "已备份旧调优文件: ${backup_file}"
    fi

    mv "$tmp_file" "$_TCPTUNE_SYSCTL_FILE"
    _success "已生成配置文件: ${_TCPTUNE_SYSCTL_FILE}"
}

_tcptune_build_managed_keys() {
    local params=(
        "net.ipv4.tcp_congestion_control"
        "net.core.default_qdisc"
        "net.ipv4.tcp_rmem"
        "net.ipv4.tcp_wmem"
        "net.core.rmem_max"
        "net.core.wmem_max"
        "net.ipv4.ip_local_port_range"
        "net.core.somaxconn"
        "net.core.netdev_max_backlog"
        "net.core.netdev_budget"
        "net.ipv4.tcp_frto"
    )
    printf '%s\n' "${params[@]}"
}

_tcptune_scan_conflicts() {
    local keys=("$@")
    local file key key_esc matches line
    local files=("/etc/sysctl.conf")

    _TCPTUNE_CONFLICTS=""

    shopt -s nullglob
    for file in /etc/sysctl.d/*.conf /run/sysctl.d/*.conf /usr/lib/sysctl.d/*.conf /lib/sysctl.d/*.conf; do
        files+=("$file")
    done
    shopt -u nullglob

    for file in "${files[@]}"; do
        [ -f "$file" ] || continue
        [ "$file" = "$_TCPTUNE_SYSCTL_FILE" ] && continue
        for key in "${keys[@]}"; do
            key_esc=$(_tcptune_escape_ere "$key")
            matches=$(grep -nE "^[[:space:]]*${key_esc}[[:space:]]*=" "$file" 2>/dev/null || true)
            [ -z "$matches" ] && continue
            while IFS= read -r line; do
                [ -z "$line" ] && continue
                _TCPTUNE_CONFLICTS+="${file}:${line}"$'\n'
            done <<< "$matches"
        done
    done

    [ -n "$_TCPTUNE_CONFLICTS" ]
}

_tcptune_print_conflicts() {
    [ -z "$_TCPTUNE_CONFLICTS" ] && return 0
    echo ""
    printf "  ${BOLD}检测到冲突项${PLAIN}\n"
    _separator
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        printf "    %s\n" "$line"
    done <<< "$_TCPTUNE_CONFLICTS"
}

_tcptune_cleanup_conflicts() {
    local keys=("$@")
    local file key key_esc backup file_changed files_count=0
    local files=("/etc/sysctl.conf")

    shopt -s nullglob
    for file in /etc/sysctl.d/*.conf /run/sysctl.d/*.conf; do
        files+=("$file")
    done
    shopt -u nullglob

    for file in "${files[@]}"; do
        [ -f "$file" ] || continue
        [ "$file" = "$_TCPTUNE_SYSCTL_FILE" ] && continue
        file_changed=0
        for key in "${keys[@]}"; do
            key_esc=$(_tcptune_escape_ere "$key")
            if grep -qE "^[[:space:]]*${key_esc}[[:space:]]*=" "$file" 2>/dev/null; then
                if [ "$file_changed" -eq 0 ]; then
                    backup="${file}.bak.vpsgo.$(date +%Y%m%d%H%M%S)"
                    cp "$file" "$backup" 2>/dev/null || true
                    _info "已备份冲突文件: ${backup}"
                    file_changed=1
                fi
                sed -i -E "s|^([[:space:]]*${key_esc}[[:space:]]*=.*)$|# [disabled by vpsgo-tcp-v2] \\1|g" "$file"
            fi
        done
        if [ "$file_changed" -eq 1 ]; then
            files_count=$((files_count + 1))
            _info "已清理冲突项: ${file}"
        fi
    done

    if [ "$files_count" -gt 0 ]; then
        _success "冲突清理完成，共处理 ${files_count} 个文件。"
    fi
}

_tcptune_resolve_conflicts_before_apply() {
    local keys=("$@")
    local choice

    if ! _tcptune_scan_conflicts "${keys[@]}"; then
        return 0
    fi

    _tcptune_print_conflicts
    echo ""
    _warn "检测到同名 sysctl 参数，若不清理，重启后可能被其他文件覆盖。"
    _separator
    _menu_item "1" "自动清理冲突项 (推荐)" "注释旧配置并保留备份" "green"
    _menu_item "2" "保留冲突继续" "当前可生效，重启后可能漂移" "yellow"
    _menu_item "0" "取消本次应用" "" "red"
    _separator
    read -rp "  选择 [0-2]: " choice

    case "$choice" in
        1|"")
            _tcptune_cleanup_conflicts "${keys[@]}"
            ;;
        2)
            _warn "已选择保留冲突项。"
            ;;
        0)
            _info "已取消。"
            return 1
            ;;
        *)
            _warn "无效选项，默认取消。"
            return 1
            ;;
    esac

    return 0
}

_tcptune_apply_sysctl_all() {
    local output rc
    output=$(sysctl --system 2>&1)
    rc=$?
    if [ "$rc" -eq 0 ]; then
        _success "sysctl 参数已应用。"
    else
        _warn "sysctl --system 返回非 0，可能是容器/内核权限限制。"
    fi
    if [ -n "$output" ]; then
        echo ""
        printf "  ${BOLD}sysctl 输出 (最后 4 行)${PLAIN}\n"
        _separator
        printf '%s\n' "$output" | tail -n4 | sed 's/^/    /'
    fi
}

_tcptune_verify_fq_qdisc() {
    local iface="$1" qdisc_output recheck

    if [ -z "$iface" ]; then
        _warn "未检测到出口网卡，跳过 qdisc 验证。"
        return 0
    fi
    if ! command -v tc >/dev/null 2>&1; then
        _warn "系统未安装 tc，跳过 qdisc 验证。"
        return 0
    fi

    qdisc_output=$(tc qdisc show dev "$iface" 2>/dev/null || true)
    if [ -z "$qdisc_output" ]; then
        _warn "无法读取 ${iface} 的 qdisc。"
        return 0
    fi

    printf "  ${BOLD}当前 qdisc (${iface})${PLAIN}\n"
    _separator
    printf '%s\n' "$qdisc_output" | sed 's/^/    /'

    if echo "$qdisc_output" | grep -q "^qdisc mq "; then
        _info "检测到多队列网卡 (mq root)，这是正常行为。"
        if echo "$qdisc_output" | grep -qE "\bfq\b"; then
            _success "FQ 已在 mq 的 leaf 子队列生效。"
        else
            _warn "未检测到 leaf fq，尝试替换为 fq..."
            while IFS= read -r parent; do
                [ -z "$parent" ] && continue
                tc qdisc replace dev "$iface" parent "${parent}:" fq >/dev/null 2>&1 || true
            done < <(printf '%s\n' "$qdisc_output" | awk '$4=="parent" { gsub(":", "", $5); if ($5 != "") print $5 }')
        fi
    elif echo "$qdisc_output" | grep -qE "^qdisc fq "; then
        _success "FQ qdisc 已生效。"
    else
        _warn "当前不是 fq，尝试设置 root fq..."
        tc qdisc replace dev "$iface" root fq >/dev/null 2>&1 || tc qdisc add dev "$iface" root fq >/dev/null 2>&1 || true
    fi

    recheck=$(tc qdisc show dev "$iface" 2>/dev/null || true)
    if [ -n "$recheck" ]; then
        echo ""
        printf "  ${BOLD}qdisc 复核 (${iface})${PLAIN}\n"
        _separator
        printf '%s\n' "$recheck" | sed 's/^/    /'
    fi
}

_tcptune_verify_cake_qdisc() {
    local iface="$1" bw_mbit="$2"
    local qdisc_output recheck parents parent_count per_queue_bw parent

    if [ -z "$iface" ]; then
        _warn "未检测到出口网卡，跳过 CAKE 验证。"
        return 1
    fi
    if ! command -v tc >/dev/null 2>&1; then
        _warn "系统未安装 tc，无法设置 CAKE。"
        return 1
    fi
    if ! _is_digit "${bw_mbit:-}" || [ "$bw_mbit" -le 0 ]; then
        _warn "CAKE 带宽上限无效，跳过 CAKE 验证。"
        return 1
    fi

    qdisc_output=$(tc qdisc show dev "$iface" 2>/dev/null || true)
    if [ -z "$qdisc_output" ]; then
        _warn "无法读取 ${iface} 的 qdisc。"
        return 1
    fi

    printf "  ${BOLD}当前 qdisc (${iface})${PLAIN}\n"
    _separator
    printf '%s\n' "$qdisc_output" | sed 's/^/    /'

    if tc qdisc replace dev "$iface" root cake bandwidth "${bw_mbit}mbit" >/dev/null 2>&1; then
        _success "已设置 root CAKE，带宽上限 ${bw_mbit} Mbps。"
    else
        _warn "设置 root CAKE 失败，尝试 mq 子队列回退方案..."
        if echo "$qdisc_output" | grep -q "^qdisc mq "; then
            parents=$(printf '%s\n' "$qdisc_output" | awk '$4=="parent" { gsub(":", "", $5); if ($5 != "") print $5 }' | sort -u)
            parent_count=$(printf '%s\n' "$parents" | sed '/^$/d' | wc -l | awk '{print $1}')
            if _is_digit "$parent_count" && [ "$parent_count" -gt 0 ]; then
                per_queue_bw=$((bw_mbit / parent_count))
                [ "$per_queue_bw" -lt 1 ] && per_queue_bw=1
                _warn "检测到 mq root，按 ${parent_count} 队列近似分摊为每队列 ${per_queue_bw} Mbps。"
                while IFS= read -r parent; do
                    [ -z "$parent" ] && continue
                    tc qdisc replace dev "$iface" parent "${parent}:" cake bandwidth "${per_queue_bw}mbit" >/dev/null 2>&1 || true
                done <<< "$parents"
            fi
        fi
    fi

    recheck=$(tc qdisc show dev "$iface" 2>/dev/null || true)
    if [ -n "$recheck" ]; then
        echo ""
        printf "  ${BOLD}qdisc 复核 (${iface})${PLAIN}\n"
        _separator
        printf '%s\n' "$recheck" | sed 's/^/    /'
    fi

    if echo "$recheck" | grep -qE '\bcake\b'; then
        _success "CAKE qdisc 已生效。"
        return 0
    fi

    _warn "未检测到 CAKE 生效，可能是内核/容器能力限制。"
    return 1
}

_tcptune_final_verify() {
    local iface="$1" cap_bytes="$2" qdisc_mode="${3:-fq}" cake_bw_mbit="${4:-0}"
    local errors=0 actual_rmem_max actual_wmem_max cc default_qdisc qdisc_now core_cap_bytes
    core_cap_bytes=$(_tcptune_core_cap_bytes "$cap_bytes")

    echo ""
    printf "  ${BOLD}最终验证${PLAIN}\n"
    _separator
    _status_kv "tcp_congestion_control" "$(_tcptune_sysctl_get net.ipv4.tcp_congestion_control)" "green" 24
    _status_kv "default_qdisc" "$(_tcptune_sysctl_get net.core.default_qdisc)" "green" 24
    _status_kv "tcp_rmem" "$(_tcptune_sysctl_get net.ipv4.tcp_rmem)" "green" 24
    _status_kv "tcp_wmem" "$(_tcptune_sysctl_get net.ipv4.tcp_wmem)" "green" 24
    _status_kv "core.rmem_max" "$(_tcptune_sysctl_get net.core.rmem_max)" "green" 24
    _status_kv "core.wmem_max" "$(_tcptune_sysctl_get net.core.wmem_max)" "green" 24
    _status_kv "ip_local_port_range" "$(_tcptune_sysctl_get net.ipv4.ip_local_port_range)" "green" 24
    _status_kv "somaxconn" "$(_tcptune_sysctl_get net.core.somaxconn)" "green" 24
    _status_kv "netdev_max_backlog" "$(_tcptune_sysctl_get net.core.netdev_max_backlog)" "green" 24
    _status_kv "netdev_budget" "$(_tcptune_sysctl_get net.core.netdev_budget)" "green" 24
    _status_kv "tcp_frto" "$(_tcptune_sysctl_get net.ipv4.tcp_frto)" "green" 24

    cc=$(_tcptune_sysctl_get net.ipv4.tcp_congestion_control)
    if [ "$cc" != "bbr" ]; then
        _error_no_exit "BBR 未生效 (当前: ${cc})。"
        errors=$((errors + 1))
    fi

    actual_rmem_max=$(_tcptune_sysctl_get net.core.rmem_max "0")
    actual_wmem_max=$(_tcptune_sysctl_get net.core.wmem_max "0")
    if _is_digit "$actual_rmem_max" && [ "$actual_rmem_max" -lt "$core_cap_bytes" ]; then
        _error_no_exit "rmem_max (${actual_rmem_max}) < floor (${core_cap_bytes})。"
        errors=$((errors + 1))
    fi
    if _is_digit "$actual_wmem_max" && [ "$actual_wmem_max" -lt "$core_cap_bytes" ]; then
        _error_no_exit "wmem_max (${actual_wmem_max}) < floor (${core_cap_bytes})。"
        errors=$((errors + 1))
    fi

    if [ "$(_tcptune_sysctl_get net.core.netdev_budget 0)" != "600" ]; then
        _warn "netdev_budget 当前不是 600。"
    fi
    if [ "$(_tcptune_sysctl_get net.ipv4.tcp_frto 1)" != "0" ]; then
        _warn "tcp_frto 当前不是 0。"
    fi

    default_qdisc=$(_tcptune_sysctl_get net.core.default_qdisc)
    if [ "$default_qdisc" != "fq" ]; then
        _error_no_exit "default_qdisc 非预期 (当前: ${default_qdisc}, 预期: fq)。"
        errors=$((errors + 1))
    fi

    if [ -n "$iface" ] && command -v tc >/dev/null 2>&1; then
        qdisc_now=$(tc qdisc show dev "$iface" 2>/dev/null || true)
        _status_kv "qdisc(${iface})" "$(printf '%s\n' "$qdisc_now" | head -n1)" "dim" 24
        if [ "$qdisc_mode" = "cake" ]; then
            _status_kv "cake_bandwidth" "${cake_bw_mbit} Mbps" "dim" 24
            if ! echo "$qdisc_now" | grep -qE '\bcake\b'; then
                _error_no_exit "未检测到 CAKE qdisc 生效。"
                errors=$((errors + 1))
            fi
        fi
    fi

    echo ""
    if [ "$errors" -eq 0 ]; then
        _success "核心参数验证通过。"
    else
        _warn "有 ${errors} 个关键项未通过，请检查上方输出。"
    fi
}

_tcptune_print_verify_hint() {
    local iface="${1:-$(_tcptune_guess_iface)}"
    local cap_bytes="${2:-$((64 * 1024 * 1024))}"
    local qdisc_mode="${3:-fq}"
    local cake_bw_mbit="${4:-0}"
    local cap_up cap_down core_cap_up core_cap_down

    cap_up=$((cap_bytes * 2))
    cap_down=$((cap_bytes / 2))
    [ "$cap_down" -lt "$_TCPTUNE_MIN_CEILING_BYTES" ] && cap_down="$_TCPTUNE_MIN_CEILING_BYTES"
    core_cap_up=$(_tcptune_core_cap_bytes "$cap_up")
    core_cap_down=$(_tcptune_core_cap_bytes "$cap_down")

    echo ""
    printf "  ${BOLD}文件与回滚${PLAIN}\n"
    _separator
    printf "    配置文件: %s\n" "$_TCPTUNE_SYSCTL_FILE"
    if [ -n "$_TCPTUNE_LAST_BACKUP_FILE" ]; then
        printf "    运行前备份: %s\n" "$_TCPTUNE_LAST_BACKUP_FILE"
        printf "    回滚命令: sysctl --load=%s\n" "$_TCPTUNE_LAST_BACKUP_FILE"
    fi

    echo ""
    printf "  ${BOLD}iperf3 测试建议${PLAIN}\n"
    _separator
    printf "    服务端: iperf3 -s\n"
    printf "    客户端单流: iperf3 -c <IP> -R -P 1 -t 30 -O 3\n"
    printf "    客户端四流: iperf3 -c <IP> -R -P 4 -t 30 -O 3\n"
    printf "    注意: 不要使用 -w (会覆盖 sysctl 调优)\n"
    printf "    判读: 若 -P 1 慢但 -P 4 明显更快，优先排查 RSS/IRQ/NIC 瓶颈\n"

    echo ""
    printf "  ${BOLD}实时诊断命令${PLAIN}\n"
    _separator
    printf "    uname -r\n"
    printf "    sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc\n"
    printf "    sysctl net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.core.rmem_max net.core.wmem_max\n"
    printf "    sysctl net.ipv4.ip_local_port_range net.core.somaxconn net.core.netdev_max_backlog net.core.netdev_budget net.ipv4.tcp_frto\n"
    printf "    ss -s\n"
    printf "    ss -tin | grep -E 'bbr|cwnd|pacing_rate'\n"
    printf "    nstat -az | egrep 'RetransSegs|TCPTimeouts|FastRetrans|TCPSynRetrans'\n"
    if [ -n "$iface" ]; then
        printf "    ethtool -i %s\n" "$iface"
        printf "    ethtool -g %s\n" "$iface"
        printf "    ethtool -S %s | egrep 'vf_|drop|miss|buffer|timeout'\n" "$iface"
        printf "    tc -s qdisc show dev %s\n" "$iface"
    else
        printf "    ethtool -i <出口网卡>\n"
        printf "    ethtool -g <出口网卡>\n"
        printf "    ethtool -S <出口网卡> | egrep 'vf_|drop|miss|buffer|timeout'\n"
        printf "    tc -s qdisc show dev <出口网卡>\n"
    fi
    if [ "$qdisc_mode" = "cake" ]; then
        printf "    提示: 多队列网卡可能显示 mq root，CAKE 可能在 leaf 子队列中。\n"
    else
        printf "    提示: 多队列网卡看到 mq root qdisc 是正常的，fq 在 leaf 子队列。\n"
    fi
    printf "    提示: BBR ProbeBW 产生少量重传是正常设计行为，不必追求 0 重传。\n"
    printf "    提示: Azure 上还要同时看 Azure Monitor 的 Inbound/Outbound Flows 与 Flow Creation Rate。\n"

    echo ""
    printf "  ${BOLD}微调命令${PLAIN}\n"
    _separator
    printf "    吞吐打不满且 RTT 偏大:\n"
    printf "      sysctl -w net.ipv4.tcp_rmem='4096 131072 %s'\n" "$cap_up"
    printf "      sysctl -w net.ipv4.tcp_wmem='4096 65536 %s'\n" "$cap_up"
    printf "      sysctl -w net.core.rmem_max=%s\n" "$core_cap_up"
    printf "      sysctl -w net.core.wmem_max=%s\n" "$core_cap_up"
    printf "      sysctl -w net.core.netdev_budget=1000\n"
    printf "    重传/排队抖动明显:\n"
    printf "      sysctl -w net.ipv4.tcp_rmem='4096 131072 %s'\n" "$cap_down"
    printf "      sysctl -w net.ipv4.tcp_wmem='4096 65536 %s'\n" "$cap_down"
    printf "      sysctl -w net.core.rmem_max=%s\n" "$core_cap_down"
    printf "      sysctl -w net.core.wmem_max=%s\n" "$core_cap_down"
    printf "    尾延迟偏高可先试:\n"
    printf "      sysctl -w net.ipv4.tcp_limit_output_bytes=1048576\n"
    printf "    怀疑 PMTUD blackhole / 大包卡顿:\n"
    printf "      sysctl -w net.ipv4.tcp_mtu_probing=1\n"
    printf "    提示: busy_poll/busy_read 默认保持关闭，除非连接数少且极度追求尾延迟。\n"
    if [ -n "$iface" ]; then
        if [ "$qdisc_mode" = "cake" ]; then
            printf "    当前 qdisc: CAKE (带宽上限 %s Mbps)\n" "${cake_bw_mbit}"
            printf "    临时调整上限:\n"
            printf "      tc qdisc replace dev %s root cake bandwidth %smbit\n" "$iface" "${cake_bw_mbit}"
            if _has_openrc; then
                printf "    永久生效由 OpenRC 服务 %s 负责。\n" "$_TCPTUNE_CAKE_OPENRC_SERVICE_NAME"
            else
                printf "    永久生效由 systemd 服务 %s 负责。\n" "$_TCPTUNE_CAKE_SERVICE_NAME"
            fi
        else
            printf "    如需限速且保持 pacing:\n"
            printf "      tc qdisc replace dev %s root fq maxrate 900mbit\n" "$iface"
            printf "    若必须 HTB 分类限速，记得在 class 下挂 fq 子队列。\n"
        fi
    fi
}

_tcptune_run_v2() {
    local iface link_speed mem_mb kernel confirm qdisc_mode kv min_kv
    local managed_keys=() key

    _header "TCP 调优 (Azure/Proxy 基线)"
    _tcptune_show_current
    echo ""
    _warn "将重写 TCP 调优配置并立即应用。"
    read -rp "  是否继续进行 TCP 调优? [Y/n]: " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        _info "已取消。"
        _press_any_key
        return
    fi

    echo ""
    _info "Step 1/8: 采集系统信息"
    iface="$(_tcptune_guess_iface)"
    if [ -z "$iface" ]; then
        read -rp "  无法自动识别出口网卡，请手动输入 (如 eth0): " iface
    fi
    if [ -z "$iface" ]; then
        _error_no_exit "未提供网卡，无法继续。"
        _press_any_key
        return
    fi
    _TCPTUNE_LAST_IFACE="$iface"
    link_speed=$(_tcptune_detect_link_speed "$iface")
    mem_mb=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
    kernel=$(uname -r)
    _status_kv "出口网卡" "$iface" "green" 18
    if [ -n "$link_speed" ]; then
        _status_kv "网卡协商速率" "${link_speed} Mbps (参考)" "green" 18
    else
        _warn "未能识别网卡协商速率，瓶颈带宽请按上游真实限速或压测结果手工输入。"
    fi
    _status_kv "系统内存" "${mem_mb} MB" "green" 18
    _status_kv "内核版本" "$kernel" "green" 18

    echo ""
    qdisc_mode=$(_tcptune_detect_qdisc_mode "$iface")
    _TCPTUNE_LAST_QDISC_MODE="$qdisc_mode"
    if [ "$_TCPTUNE_LAST_QDISC_MODE" = "cake" ]; then
        if ! command -v tc >/dev/null 2>&1; then
            _warn "未检测到 tc，无法应用 CAKE 带宽上限，自动回退到 FQ。"
            _TCPTUNE_LAST_QDISC_MODE="fq"
        else
            kv="$(_kernel_version)"
            min_kv="$(_qdisc_min_kernel_for cake)"
            if ! _version_ge "$kv" "$min_kv"; then
                _warn "当前内核 ${kv} 低于 CAKE 最低要求 ${min_kv}，自动回退到 FQ。"
                _TCPTUNE_LAST_QDISC_MODE="fq"
            fi
        fi
    fi
    if [ "$_TCPTUNE_LAST_QDISC_MODE" = "cake" ]; then
        _status_kv "Qdisc 模式" "cake (沿用现有设置)" "green" 18
    else
        _TCPTUNE_LAST_QDISC_MODE="fq"
        _status_kv "Qdisc 模式" "fq (Azure 基线)" "green" 18
    fi

    echo ""
    _info "Step 2/8: 计算 TCP 缓冲区 ceiling"
    _tcptune_choose_ceiling "$link_speed"

    echo ""
    if [ "$_TCPTUNE_LAST_QDISC_MODE" = "cake" ]; then
        _info "Step 3/8: 设置 CAKE 带宽上限"
        _tcptune_choose_cake_bandwidth "$link_speed"
    else
        _info "Step 3/8: FQ 模式无需设置额外带宽上限"
        _TCPTUNE_LAST_CAKE_BW_MBIT=0
    fi

    echo ""
    _info "Step 4/8: 检查 BBR 支持"
    if ! _tcptune_ensure_bbr_available; then
        _error_no_exit "当前内核未检测到 BBR。请先执行“开启 BBR”模块。"
        _press_any_key
        return
    fi

    echo ""
    _info "Step 5/8: 备份当前配置"
    _tcptune_backup_runtime "$iface"

    echo ""
    _info "Step 6/8: 生成并应用优化配置"
    while IFS= read -r key; do
        [ -n "$key" ] && managed_keys+=("$key")
    done < <(_tcptune_build_managed_keys)
    if ! _tcptune_resolve_conflicts_before_apply "${managed_keys[@]}"; then
        _press_any_key
        return
    fi
    _tcptune_write_sysctl_conf "$_TCPTUNE_LAST_CEILING_BYTES" "$_TCPTUNE_LAST_QDISC_MODE"
    _tcptune_apply_sysctl_all

    echo ""
    _info "Step 7/8: 验证并应用 Qdisc"
    if [ "$_TCPTUNE_LAST_QDISC_MODE" = "cake" ]; then
        _tcptune_verify_cake_qdisc "$iface" "$_TCPTUNE_LAST_CAKE_BW_MBIT" || true
        _tcptune_enable_cake_persist "$iface" "$_TCPTUNE_LAST_CAKE_BW_MBIT" || true
    else
        _tcptune_verify_fq_qdisc "$iface"
        _tcptune_disable_cake_persist
    fi

    echo ""
    _info "Step 8/8: 最终验证"
    _tcptune_final_verify "$iface" "$_TCPTUNE_LAST_CEILING_BYTES" "$_TCPTUNE_LAST_QDISC_MODE" "$_TCPTUNE_LAST_CAKE_BW_MBIT"
    _tcptune_print_verify_hint "$iface" "$_TCPTUNE_LAST_CEILING_BYTES" "$_TCPTUNE_LAST_QDISC_MODE" "$_TCPTUNE_LAST_CAKE_BW_MBIT"
    _network_reboot_prompt
    _press_any_key
}

_tcptune_setup() {
    while true; do
        _header "TCP 调优 (Azure/Proxy 基线)"
        _tcptune_show_current
        echo ""
        _info "原则: BBR + fq + autotune ceiling (RTT×带宽)，其余参数尽量少碰。"

        _separator
        _menu_pair "1" "应用 TCP 调优" "一键应用并验证" "green" "2" "查看验证命令" "iperf3/ss/tc/nstat" "cyan"
        _menu_item "0" "返回主菜单" "" "red"
        _separator

        local choice
        read -rp "  选择 [0-2]: " choice
        case "$choice" in
            1) _tcptune_run_v2 ;;
            2) _tcptune_print_verify_hint "$(_tcptune_guess_iface)" "$_TCPTUNE_LAST_CEILING_BYTES" "$_TCPTUNE_LAST_QDISC_MODE" "$_TCPTUNE_LAST_CAKE_BW_MBIT"; _press_any_key ;;
            0) return ;;
            *) _error_no_exit "无效选项: ${choice}"; _press_any_key ;;
        esac
    done
}

# --- 7. Docker 日志轮转 ---

_dockerlog_setup() {
    _header "日志轮转配置"

    # 检查 Docker 是否安装
    if ! command -v docker >/dev/null 2>&1; then
        _error_no_exit "未检测到 Docker，请先安装 Docker。"
        _press_any_key
        return
    fi

    # 检查 jq 是否安装
    if ! command -v jq >/dev/null 2>&1; then
        _warn "未检测到 jq，尝试自动安装..."
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -qq >/dev/null 2>&1 || true
            apt-get install -y -qq jq >/dev/null 2>&1 || true
        elif command -v yum >/dev/null 2>&1; then
            yum install -y jq >/dev/null 2>&1 || true
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y jq >/dev/null 2>&1 || true
        elif command -v apk >/dev/null 2>&1; then
            apk add --no-cache jq >/dev/null 2>&1 || true
        fi
        if ! command -v jq >/dev/null 2>&1; then
            _error_no_exit "需要 jq 工具来处理 JSON 配置，请先安装: apt/yum/dnf install jq 或 apk add jq"
            _press_any_key
            return
        fi
    fi

    local DAEMON_JSON="/etc/docker/daemon.json"
    local LOG_MAX_SIZE="10m"
    local LOG_MAX_FILE="7"

    echo ""
    _info "目标配置: log-driver=json-file, max-size=${LOG_MAX_SIZE}, max-file=${LOG_MAX_FILE}"

    # 显示当前配置
    if [ -f "$DAEMON_JSON" ]; then
        local cur_driver cur_size cur_file
        cur_driver=$(jq -r '.["log-driver"] // "未设置"' "$DAEMON_JSON" 2>/dev/null || echo "未设置")
        cur_size=$(jq -r '.["log-opts"]["max-size"] // "未设置"' "$DAEMON_JSON" 2>/dev/null || echo "未设置")
        cur_file=$(jq -r '.["log-opts"]["max-file"] // "未设置"' "$DAEMON_JSON" 2>/dev/null || echo "未设置")
        echo ""
        printf "  ${BOLD}当前配置:${PLAIN}\n"
        _separator
        printf "    log-driver : %s\n" "$cur_driver"
        printf "    max-size   : %s\n" "$cur_size"
        printf "    max-file   : %s\n" "$cur_file"

        # 检查是否已经一致
        if [ "$cur_driver" = "json-file" ] && [ "$cur_size" = "$LOG_MAX_SIZE" ] && [ "$cur_file" = "$LOG_MAX_FILE" ]; then
            echo ""
            _info "日志配置已存在且一致，无需修改。"
            _press_any_key
            return
        fi
    else
        echo ""
        _info "当前无 daemon.json 配置文件，将创建新配置。"
    fi

    printf "  ${BOLD}请选择操作${PLAIN}\n"
    _separator
    _menu_pair "1" "应用日志轮转配置" "自动备份原配置" "green" "0" "返回主菜单" "" "red"
    _separator

    local choice
    read -rp "  选择 [0-1]: " choice
    case "$choice" in
        1) ;;
        0) return ;;
        *) _error_no_exit "无效选项"; _press_any_key; return ;;
    esac

    # 确保目录存在
    mkdir -p /etc/docker

    # 备份原有配置
    if [ -f "$DAEMON_JSON" ]; then
        local backup="${DAEMON_JSON}.bak.$(date +%Y%m%d%H%M%S)"
        cp "$DAEMON_JSON" "$backup"
        _info "已备份原配置: ${backup}"
    fi

    # 合并/创建配置
    local LOG_CONFIG='{"log-driver":"json-file","log-opts":{"max-size":"'"$LOG_MAX_SIZE"'","max-file":"'"$LOG_MAX_FILE"'"}}'

    if [ -f "$DAEMON_JSON" ]; then
        if ! jq -s '.[0] * .[1]' "$DAEMON_JSON" <(echo "$LOG_CONFIG") > "${DAEMON_JSON}.tmp.$$"; then
            rm -f "${DAEMON_JSON}.tmp.$$"
            _error_no_exit "合并配置失败，原 daemon.json 可能不是合法 JSON，已保留备份: ${backup}"
            _press_any_key
            return
        fi
        mv "${DAEMON_JSON}.tmp.$$" "$DAEMON_JSON"
        _info "已合并日志配置到 daemon.json"
    else
        echo "$LOG_CONFIG" | jq . > "$DAEMON_JSON"
        _info "已创建 daemon.json"
    fi

    # 重启 Docker
    _info "正在重启 Docker..."
    if _restart_first_available_service docker; then
        _info "Docker 重启成功!"
    else
        _warn "Docker 重启失败，请手动执行: systemctl restart docker 或 rc-service docker restart"
    fi

    # 显示最终配置
    echo ""
    printf "  ${BOLD}最终配置:${PLAIN}\n"
    _separator
    printf "    log-driver : %s\n" "$(jq -r '.["log-driver"] // "N/A"' "$DAEMON_JSON" 2>/dev/null)"
    printf "    max-size   : %s\n" "$(jq -r '.["log-opts"]["max-size"] // "N/A"' "$DAEMON_JSON" 2>/dev/null)"
    printf "    max-file   : %s\n" "$(jq -r '.["log-opts"]["max-file"] // "N/A"' "$DAEMON_JSON" 2>/dev/null)"

    _press_any_key
}

# --- 8. Mihomo 安装 ---

_mihomo_download() {
    local url="$1" output="$2"
    rm -f "$output"
    if command -v curl >/dev/null 2>&1; then
        if curl -fL --retry 2 --connect-timeout 10 -o "$output" "$url"; then
            [[ -s "$output" ]] && return 0
        fi
        rm -f "$output"
    fi
    if command -v wget >/dev/null 2>&1; then
        if wget -q --show-progress -O "$output" "$url"; then
            [[ -s "$output" ]] && return 0
        fi
        rm -f "$output"
    fi
    return 1
}

_mihomo_detect_amd64_level() {
    local flags
    flags=$(grep -m1 '^flags' /proc/cpuinfo 2>/dev/null | cut -d: -f2 || true)
    if [[ -z "$flags" ]]; then
        _warn "无法读取 /proc/cpuinfo，使用最兼容版本"
        echo "amd64-compatible"
        return
    fi
    if echo "$flags" | grep -qw 'avx2'; then
        echo "amd64-v3"
    elif echo "$flags" | grep -qw 'sse4_2' && echo "$flags" | grep -qw 'popcnt'; then
        echo "amd64-v2"
    else
        echo "amd64-compatible"
    fi
}

_mihomo_detect_mips_float() {
    if grep -q 'FPU' /proc/cpuinfo 2>/dev/null; then
        echo "hardfloat"
    else
        echo "softfloat"
    fi
}

_mihomo_detect_arch() {
    local machine
    machine=$(uname -m)
    case "$machine" in
        x86_64|amd64)       _mihomo_detect_amd64_level ;;
        i386|i486|i586|i686) echo "386" ;;
        aarch64|arm64)      echo "arm64" ;;
        armv7*|armhf)       echo "armv7" ;;
        armv6*)             echo "armv6" ;;
        armv5*)             echo "armv5" ;;
        mips64)             echo "mips64" ;;
        mips64el|mips64le)  echo "mips64le" ;;
        mips)               echo "mips-$(_mihomo_detect_mips_float)" ;;
        mipsel|mipsle)      echo "mipsle-$(_mihomo_detect_mips_float)" ;;
        riscv64)            echo "riscv64" ;;
        s390x)              echo "s390x" ;;
        ppc64le)            echo "ppc64le" ;;
        loongarch64)        echo "loong64-abi2" ;;
        *)                  echo "" ;;
    esac
}

_mihomo_get_latest_version() {
    local version latest_url

    version=$(curl -fsSL https://api.github.com/repos/MetaCubeX/mihomo/releases/latest 2>/dev/null \
        | awk -F'"' '$2=="tag_name"{print $4; exit}')
    if [[ -n "${version:-}" ]] && [[ "$version" =~ ^v?[0-9]+([.][0-9]+){1,3}([._-][0-9A-Za-z]+)*$ ]]; then
        printf '%s' "$version"
        return 0
    fi

    latest_url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/MetaCubeX/mihomo/releases/latest 2>/dev/null || true)
    if [[ "$latest_url" == *"/releases/tag/"* ]]; then
        version="${latest_url##*/}"
        if [[ -n "${version:-}" ]] && [[ "$version" =~ ^v?[0-9]+([.][0-9]+){1,3}([._-][0-9A-Za-z]+)*$ ]]; then
            printf '%s' "$version"
            return 0
        fi
    fi

    return 1
}

_mihomo_try_install() {
    local arch="$1" version="$2"
    local install_dir="/usr/local/bin"
    local url="https://github.com/MetaCubeX/mihomo/releases/download/${version}/mihomo-linux-${arch}-${version}.gz"
    local tmp_file
    tmp_file=$(mktemp /tmp/mihomo.XXXXXX.gz)

    _info "下载 mihomo-linux-${arch}..."
    printf "    ${DIM}%s${PLAIN}\n" "$url"

    if ! _mihomo_download "$url" "$tmp_file"; then
        rm -f "$tmp_file"
        return 1
    fi
    if [[ ! -s "$tmp_file" ]]; then
        rm -f "$tmp_file"
        return 1
    fi

    gunzip -c "$tmp_file" > "${install_dir}/mihomo"
    chmod +x "${install_dir}/mihomo"
    rm -f "$tmp_file"

    if "${install_dir}/mihomo" -v 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

_mihomo_setup() {
    _header "Mihomo 代理内核安装"

    # 前置检查
    if [[ "$(uname -s)" != "Linux" ]]; then
        _error_no_exit "此功能仅支持 Linux 系统"
        _press_any_key
        return
    fi
    for cmd in curl gunzip; do
        if ! command -v "$cmd" &>/dev/null; then
            _error_no_exit "缺少必要命令: $cmd，请先安装"
            _press_any_key
            return
        fi
    done

    local INSTALL_DIR="/usr/local/bin"
    local CONFIG_DIR="/etc/mihomo"

    # 检测当前安装
    echo ""
    if [ -x "${INSTALL_DIR}/mihomo" ]; then
        local cur_ver
        cur_ver=$("${INSTALL_DIR}/mihomo" -v 2>/dev/null | head -1)
        [[ -z "$cur_ver" ]] && cur_ver="未知"
        _info "当前已安装: ${cur_ver}"
    else
        _info "当前未安装 mihomo"
    fi

    # 检测架构
    local ARCH
    ARCH=$(_mihomo_detect_arch)
    if [[ -z "$ARCH" ]]; then
        _error_no_exit "不支持的架构: $(uname -m)"
        _press_any_key
        return
    fi
    _info "检测到架构: ${ARCH}"

    local confirm_install
    read -rp "  是否安装或更新 mihomo? [Y/n]: " confirm_install
    if [[ "$confirm_install" =~ ^([Nn]|[Nn][Oo])$ ]]; then
        _info "已取消"
        _press_any_key
        return
    fi

    _time_sync_check_and_enable

    # 获取最新版本
    local LATEST_VERSION
    LATEST_VERSION=$(_mihomo_get_latest_version)
    if [[ -z "$LATEST_VERSION" ]]; then
        _error_no_exit "无法获取最新版本号，请检查网络连接"
        _press_any_key
        return
    fi
    _info "最新版本: ${LATEST_VERSION}"

    # 安装 (支持自动降级)
    echo ""
    mkdir -p "$CONFIG_DIR"

    if _mihomo_try_install "$ARCH" "$LATEST_VERSION"; then
        echo ""
        _info "mihomo (${ARCH}) 安装成功!"
    elif [[ "$ARCH" == "amd64-v3" ]]; then
        _warn "amd64-v3 运行失败，自动降级到 amd64-v2..."
        if _mihomo_try_install "amd64-v2" "$LATEST_VERSION"; then
            ARCH="amd64-v2"
            _info "mihomo (amd64-v2) 安装成功!"
        else
            _warn "amd64-v2 也运行失败，继续降级到 amd64-compatible..."
            if _mihomo_try_install "amd64-compatible" "$LATEST_VERSION"; then
                ARCH="amd64-compatible"
                _info "mihomo (amd64-compatible) 安装成功!"
            else
                _error_no_exit "安装失败，所有 amd64 版本均无法运行"
                _press_any_key
                return
            fi
        fi
    else
        _error_no_exit "安装验证失败，mihomo 无法运行"
        _press_any_key
        return
    fi

    echo ""
    printf "  ${BOLD}安装信息:${PLAIN}\n"
    _separator
    printf "    二进制路径 : %s\n" "${INSTALL_DIR}/mihomo"
    printf "    配置目录   : %s\n" "${CONFIG_DIR}"
    printf "    架构       : %s\n" "${ARCH}"
    printf "    版本       : %s\n" "${LATEST_VERSION}"

    _press_any_key
}

# --- 9. 生成 Mihomo 配置 ---

_MIHOMOCONF_CONFIG_DIR="/etc/mihomo"
_MIHOMOCONF_CONFIG_FILE="/etc/mihomo/config.yaml"
_MIHOMOCONF_SSL_DIR="/etc/mihomo/ssl"
_ACME_HOME="/root/.acme.sh"
_ACME_BIN="/root/.acme.sh/acme.sh"
_ACME_CERT_DEFAULT_DIR="/etc/mihomo/ssl"
_MIHOMOCONF_IPV4_FORCE_PROXY_NAME="vpsgo-ipv4-direct-google"
_MIHOMO_WG_PROXY_SUPPORT_CACHE="unknown"
_MIHOMO_SYSTEMD_SERVICE_FILE="/etc/systemd/system/mihomo.service"
_MIHOMO_OPENRC_SERVICE_FILE="/etc/init.d/mihomo"
_MIHOMO_OPENRC_LOG_FILE="/var/log/mihomo.log"
_MIHOMO_OPENRC_ERR_FILE="/var/log/mihomo.error.log"

_mihomoconf_gen_ss_password_128() { head -c 16 /dev/urandom | base64 | tr -d '\n'; }
_mihomoconf_gen_ss_password_256() { head -c 32 /dev/urandom | base64 | tr -d '\n'; }
_mihomoconf_gen_anytls_password()  { head -c 32 /dev/urandom | base64 | tr -d '\n' | tr '/+' 'Aa' | tr -d '=' | head -c 32; }

_mihomoconf_gen_ss_password_for_cipher() {
    local cipher="${1:-}"
    case "$cipher" in
        *256*) _mihomoconf_gen_ss_password_256 ;;
        *) _mihomoconf_gen_ss_password_128 ;;
    esac
}

_mihomoconf_gen_uuid() {
    if command -v uuidgen &>/dev/null; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    else
        cat /proc/sys/kernel/random/uuid 2>/dev/null || \
            head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' | \
            sed 's/\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)\(.\{12\}\)/\1-\2-\3-\4-\5/'
    fi
}

_mihomoconf_url_base64() {
    echo -n "$1" | base64 | tr -d '\n' | tr '+/' '-_' | tr -d '='
}

_mihomoconf_urlencode() {
    local string="$1" encoded="" i c hex
    local LC_ALL=C
    for (( i=0; i<${#string}; i++ )); do
        c="${string:$i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) encoded+="$c" ;;
            *)
                hex=$(printf '%s' "$c" | od -An -tx1 -v | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
                encoded+="%${hex}"
                ;;
        esac
    done
    printf '%s' "$encoded"
}

_mihomoconf_trim() {
    local s="${1:-}"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

_mihomoconf_get_server_ip() {
    local ip=""
    for url in "https://api.ipify.org" "https://ifconfig.me" "https://icanhazip.com"; do
        ip=$(curl -4 -fsSL --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')
        [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
        ip=""
    done
    if [[ -z "$ip" ]]; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "YOUR_SERVER_IP")
    fi
    echo "$ip"
}

_mihomoconf_gen_ss_link() {
    local server="$1" port="$2" cipher="$3" password="$4" name="$5"
    local enable_udp="${6:-1}" enable_uot="${7:-1}"
    local userinfo encoded_name query
    local -a params=()
    userinfo=$(_mihomoconf_url_base64 "${cipher}:${password}")
    encoded_name=$(_mihomoconf_urlencode "${name}")
    params+=("tfo=1")
    if [[ "$enable_udp" == "1" ]]; then
        params+=("udp=1")
    else
        params+=("udp=0")
        enable_uot="0"
    fi
    if [[ "$enable_uot" == "1" ]]; then
        params+=("uot=2")
    fi
    local IFS='&'
    query="${params[*]}"
    echo "ss://${userinfo}@${server}:${port}?${query}#${encoded_name}"
}

_mihomoconf_gen_anytls_link() {
    local server="$1" port="$2" password="$3" name="$4" sni="$5"
    local encoded_name params
    encoded_name=$(_mihomoconf_urlencode "${name}")
    params="fastopen=1&udp=1"
    if [[ -n "$sni" ]]; then
        params="peer=$(_mihomoconf_urlencode "$sni")&${params}"
    fi
    echo "anytls://${password}@${server}:${port}?${params}#${encoded_name}"
}

_mihomoconf_gen_hy2_link() {
    local server="$1" port="$2" password="$3" name="$4"
    local peer="${5:-}" insecure="${6:-0}" obfs="${7:-}" obfs_password="${8:-}" mport="${9:-}"
    local encoded_name query=""
    local params=()

    encoded_name=$(_mihomoconf_urlencode "${name}")
    [[ -n "$peer" ]] && params+=("peer=$(_mihomoconf_urlencode "$peer")")
    [[ "$insecure" == "1" ]] && params+=("insecure=1")
    if [[ -n "$obfs" ]]; then
        params+=("obfs=$(_mihomoconf_urlencode "$obfs")")
        [[ -n "$obfs_password" ]] && params+=("obfs-password=$(_mihomoconf_urlencode "$obfs_password")")
    fi
    [[ -n "$mport" ]] && params+=("mport=$(_mihomoconf_urlencode "$mport")")

    if (( ${#params[@]} > 0 )); then
        local IFS='&'
        query="?${params[*]}"
    fi
    echo "hysteria2://${password}@${server}:${port}${query}#${encoded_name}"
}

_mihomoconf_parse_port_list() {
    local input="$1" default_port="$2"
    local normalized token
    local -a ports=()

    normalized="${input//,/ }"
    if [[ -z "${normalized//[[:space:]]/}" ]]; then
        normalized="$default_port"
    fi

    for token in $normalized; do
        if ! _is_valid_port "$token"; then
            return 1
        fi
        local duplicated="n"
        local p
        for p in "${ports[@]}"; do
            if [[ "$p" == "$token" ]]; then
                duplicated="y"
                break
            fi
        done
        [[ "$duplicated" == "y" ]] && continue
        ports+=("$token")
    done

    [[ ${#ports[@]} -gt 0 ]] || return 1
    printf '%s\n' "${ports[@]}"
}

_mihomoconf_port_in_list() {
    local port="$1"
    shift || true
    local p
    for p in "$@"; do
        [[ "$p" == "$port" ]] && return 0
    done
    return 1
}

_mihomoconf_gen_listener_tag() {
    local prefix="$1"
    local suffix
    suffix=$(_mihomoconf_gen_uuid | cut -d'-' -f1)
    printf '%s_%s' "$prefix" "$suffix"
}

_mihomoconf_country_code_to_flag() {
    local code="${1^^}"
    if [[ ! "$code" =~ ^[A-Z]{2}$ ]]; then
        printf '%s' "🏳"
        return
    fi
    local first second
    printf -v first '\\U%08x' $((0x1F1E6 + $(printf '%d' "'${code:0:1}") - 65))
    printf -v second '\\U%08x' $((0x1F1E6 + $(printf '%d' "'${code:1:1}") - 65))
    printf '%b%b' "$first" "$second"
}

_mihomoconf_get_geo_profile() {
    local default_ip="$1"
    local api_url raw status country country_code city flag
    api_url="http://ip-api.com/json/${default_ip}?lang=zh-CN&fields=status,country,countryCode,city"

    raw=$(curl -fsSL --max-time 6 "$api_url" 2>/dev/null || true)
    status=$(printf '%s' "$raw" | sed -n 's/.*"status":"\([^"]*\)".*/\1/p')
    country=$(printf '%s' "$raw" | sed -n 's/.*"country":"\([^"]*\)".*/\1/p')
    country_code=$(printf '%s' "$raw" | sed -n 's/.*"countryCode":"\([^"]*\)".*/\1/p')
    city=$(printf '%s' "$raw" | sed -n 's/.*"city":"\([^"]*\)".*/\1/p')

    if [[ "$status" != "success" || -z "$country_code" ]]; then
        country="未知"
        city=""
        country_code="UN"
    fi

    country_code="${country_code^^}"
    if [[ "$country_code" == "TW" || "$country" == *"台湾"* ]]; then
        country_code="CN"
    fi

    flag=$(_mihomoconf_country_code_to_flag "$country_code")
    printf '%s\037%s\037%s\037%s\n' "$country" "$city" "$country_code" "$flag"
}

_mihomoconf_make_node_name() {
    local protocol="$1" flag="$2" country_code="$3"
    printf '[%s] %s %s' "$protocol" "$flag" "$country_code"
}

_mihomoconf_get_saved_host() {
    local config_file="$1"
    [[ -r "$config_file" ]] || return 0
    awk '
        /^# vpsgo-host:[[:space:]]*/ {
            line=$0
            sub(/^# vpsgo-host:[[:space:]]*/, "", line)
            print line
            exit
        }
    ' "$config_file"
}

_mihomoconf_set_saved_host() {
    local config_file="$1" host="$2" tmp
    [[ -n "$host" ]] || return 0
    tmp=$(mktemp)
    if grep -q '^# vpsgo-host:' "$config_file" 2>/dev/null; then
        awk -v h="$host" '
            /^# vpsgo-host:[[:space:]]*/ { print "# vpsgo-host: " h; next }
            { print }
        ' "$config_file" > "$tmp"
    else
        awk -v h="$host" '
            NR == 1 { print; print "# vpsgo-host: " h; next }
            { print }
            END { if (NR == 0) print "# vpsgo-host: " h }
        ' "$config_file" > "$tmp"
    fi
    mv "$tmp" "$config_file"
}

_mihomoconf_has_listener_type() {
    local type="$1"
    awk -v t="$type" '
        function trim(s) {
            sub(/^[[:space:]]+/, "", s)
            sub(/[[:space:]]+$/, "", s)
            return s
        }
        function unquote(s) {
            gsub(/^"/, "", s)
            gsub(/"$/, "", s)
            return s
        }
        /^[^[:space:]#][^:]*:[[:space:]]*.*$/ {
            in_listeners = ($0 ~ /^listeners:[[:space:]]*$/)
            next
        }
        in_listeners && /^    type:/ {
            line=$0
            sub(/^    type:[[:space:]]*/, "", line)
            if (unquote(trim(line)) == t) {
                found=1
                exit
            }
        }
        END { exit found ? 0 : 1 }
    ' "$_MIHOMOCONF_CONFIG_FILE" 2>/dev/null
}

_mihomoconf_list_listeners() {
    local type="$1"
    awk -v t="$type" '
        function trim(s) {
            sub(/^[[:space:]]+/, "", s)
            sub(/[[:space:]]+$/, "", s)
            return s
        }
        function unquote(s) {
            gsub(/^"/, "", s)
            gsub(/"$/, "", s)
            return s
        }
        /^[^[:space:]#][^:]*:[[:space:]]*.*$/ {
            in_listeners = ($0 ~ /^listeners:[[:space:]]*$/)
            next
        }
        !in_listeners { next }
        /^  - name:/ {
            line=$0
            sub(/^  - name:[[:space:]]*/, "", line)
            name=unquote(trim(line))
            found=0
            tag=""
            next
        }
        /^    tag:/ {
            line=$0
            sub(/^    tag:[[:space:]]*/, "", line)
            tag=unquote(trim(line))
            next
        }
        /^    type:/ {
            line=$0
            sub(/^    type:[[:space:]]*/, "", line)
            found=(unquote(trim(line)) == t)
            next
        }
        found && /^    port:/ {
            line=$0
            sub(/^    port:[[:space:]]*/, "", line)
            if (tag != "") {
                print "      " name " (tag: " tag ", 端口: " trim(line) ")"
            } else {
                print "      " name " (端口: " trim(line) ")"
            }
            found=0
        }
    ' "$_MIHOMOCONF_CONFIG_FILE" 2>/dev/null
}

_mihomoconf_remove_listeners_by_type() {
    local type="$1"
    local tmp
    tmp=$(mktemp)
    awk -v t="$type" '
        function trim(s) {
            sub(/^[[:space:]]+/, "", s)
            sub(/[[:space:]]+$/, "", s)
            return s
        }
        function unquote(s) {
            gsub(/^"/, "", s)
            gsub(/"$/, "", s)
            return s
        }
        function flush_item() {
            if (!in_item) return
            if (!skip_item) {
                printf "%s", item_buf
            }
            item_buf=""
            in_item=0
            skip_item=0
        }
        BEGIN {
            in_listeners=0
            in_item=0
            skip_item=0
            item_buf=""
        }
        /^[^[:space:]#][^:]*:[[:space:]]*.*$/ {
            if (in_listeners) {
                flush_item()
            }
            if ($0 ~ /^listeners:[[:space:]]*$/) {
                in_listeners=1
            } else {
                in_listeners=0
            }
            print
            next
        }
        !in_listeners {
            print
            next
        }
        /^  - name:/ {
            flush_item()
            in_item=1
            item_buf=$0 "\n"
            next
        }
        in_item {
            item_buf=item_buf $0 "\n"
            if ($0 ~ /^    type:/) {
                line=$0
                sub(/^    type:[[:space:]]*/, "", line)
                if (unquote(trim(line)) == t) {
                    skip_item=1
                }
            }
            next
        }
        { print }
        END {
            if (in_listeners) {
                flush_item()
            }
        }
    ' "$_MIHOMOCONF_CONFIG_FILE" > "$tmp"
    mv "$tmp" "$_MIHOMOCONF_CONFIG_FILE"
}

_mihomoconf_read_listener_rows() {
    local config_file="$1"
    awk '
        function trim(s) {
            sub(/^[[:space:]]+/, "", s)
            sub(/[[:space:]]+$/, "", s)
            return s
        }
        function lindent(s, p) {
            p = match(s, /[^ ]/)
            if (p == 0) return length(s)
            return p - 1
        }
        function unquote(s) {
            gsub(/^"/, "", s)
            gsub(/"$/, "", s)
            return s
        }
        function reset_state() {
            name=tag=type=port=cipher=password=user_id=user_pass=sni=""
            hy2_up=hy2_down=hy2_ignore=hy2_obfs=hy2_obfs_password=hy2_masquerade=hy2_mport=hy2_insecure=""
            in_users=0
            item_indent=-1
            users_indent=-1
        }
        function emit() {
            if (name == "") return
            printf "%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\n", \
                type, name, port, cipher, password, user_id, user_pass, sni, hy2_up, hy2_down, \
                hy2_ignore, hy2_obfs, hy2_obfs_password, hy2_masquerade, hy2_mport, hy2_insecure, tag
        }
        BEGIN {
            in_listeners=0
            reset_state()
        }
        /^[^[:space:]#][^:]*:[[:space:]]*.*$/ {
            if (in_listeners) {
                emit()
                reset_state()
            }
            in_listeners = ($0 ~ /^listeners:[[:space:]]*$/)
            next
        }
        !in_listeners { next }
        /^[[:space:]]*-[[:space:]]*name:/ {
            emit()
            line=$0
            item_indent=lindent($0)
            sub(/^[[:space:]]*-[[:space:]]*name:[[:space:]]*/, "", line)
            name=unquote(trim(line))
            tag=type=port=cipher=password=user_id=user_pass=sni=""
            hy2_up=hy2_down=hy2_ignore=hy2_obfs=hy2_obfs_password=hy2_masquerade=hy2_mport=hy2_insecure=""
            in_users=0
            users_indent=-1
            next
        }
        in_users {
            curr_indent=lindent($0)
            if (curr_indent <= users_indent) {
                in_users=0
            } else if ($0 ~ /^[[:space:]]+[^[:space:]#].*:/) {
                line=$0
                sub(/^[[:space:]]+/, "", line)
                pos=index(line, ":")
                if (pos > 0) {
                    key=substr(line, 1, pos - 1)
                    val=substr(line, pos + 1)
                    key=unquote(trim(key))
                    if (val !~ /^[[:space:]]*"/) {
                        sub(/[[:space:]]+#.*/, "", val)
                    }
                    val=unquote(trim(val))
                    if (user_id == "") user_id=key
                    if (user_pass == "") user_pass=val
                }
                next
            } else {
                next
            }
        }
        /^[[:space:]]+tag:/ {
            line=$0
            sub(/^[[:space:]]+tag:[[:space:]]*/, "", line)
            tag=unquote(trim(line))
            next
        }
        /^[[:space:]]+#[[:space:]]*vpsgo-sni:/ {
            line=$0
            sub(/^[[:space:]]+#[[:space:]]*vpsgo-sni:[[:space:]]*/, "", line)
            line=trim(line)
            sub(/\r$/, "", line)
            sni=unquote(line)
            next
        }
        /^[[:space:]]+#[[:space:]]*vpsgo-peer:/ {
            line=$0
            sub(/^[[:space:]]+#[[:space:]]*vpsgo-peer:[[:space:]]*/, "", line)
            line=trim(line)
            sub(/\r$/, "", line)
            sni=unquote(line)
            next
        }
        /^[[:space:]]+#[[:space:]]*vpsgo-mport:/ {
            line=$0
            sub(/^[[:space:]]+#[[:space:]]*vpsgo-mport:[[:space:]]*/, "", line)
            hy2_mport=trim(line)
            next
        }
        /^[[:space:]]+#[[:space:]]*vpsgo-insecure:/ {
            line=$0
            sub(/^[[:space:]]+#[[:space:]]*vpsgo-insecure:[[:space:]]*/, "", line)
            hy2_insecure=trim(line)
            next
        }
        /^[[:space:]]+type:/ {
            line=$0
            sub(/^[[:space:]]+type:[[:space:]]*/, "", line)
            type=unquote(trim(line))
            next
        }
        /^[[:space:]]+port:/ {
            line=$0
            sub(/^[[:space:]]+port:[[:space:]]*/, "", line)
            port=trim(line)
            next
        }
        /^[[:space:]]+cipher:/ {
            line=$0
            sub(/^[[:space:]]+cipher:[[:space:]]*/, "", line)
            cipher=trim(line)
            next
        }
        /^[[:space:]]+password:/ {
            line=$0
            sub(/^[[:space:]]+password:[[:space:]]*/, "", line)
            password=unquote(trim(line))
            next
        }
        /^[[:space:]]+up:/ {
            line=$0
            sub(/^[[:space:]]+up:[[:space:]]*/, "", line)
            hy2_up=trim(line)
            next
        }
        /^[[:space:]]+down:/ {
            line=$0
            sub(/^[[:space:]]+down:[[:space:]]*/, "", line)
            hy2_down=trim(line)
            next
        }
        /^[[:space:]]+ignore-client-bandwidth:/ {
            line=$0
            sub(/^[[:space:]]+ignore-client-bandwidth:[[:space:]]*/, "", line)
            hy2_ignore=trim(line)
            next
        }
        /^[[:space:]]+obfs:/ {
            line=$0
            sub(/^[[:space:]]+obfs:[[:space:]]*/, "", line)
            hy2_obfs=trim(line)
            next
        }
        /^[[:space:]]+obfs-password:/ {
            line=$0
            sub(/^[[:space:]]+obfs-password:[[:space:]]*/, "", line)
            hy2_obfs_password=unquote(trim(line))
            next
        }
        /^[[:space:]]+masquerade:/ {
            line=$0
            sub(/^[[:space:]]+masquerade:[[:space:]]*/, "", line)
            hy2_masquerade=unquote(trim(line))
            next
        }
        /^[[:space:]]+users:[[:space:]]*$/ {
            in_users=1
            users_indent=lindent($0)
            next
        }
        END {
            emit()
        }
    ' "$config_file"
}

_mihomoconf_is_valid_username() {
    local username="$1"
    [[ "$username" =~ ^[A-Za-z0-9._-]+$ ]]
}

_mihomoconf_collect_users_input() {
    local label="$1"
    local forced_mode="${2:-}"
    local password_style="${3:-anytls}"
    local mode raw count
    local -a users=()
    local auto_name_suffix=""

    while true; do
        if [[ "$forced_mode" == "1" || "$forced_mode" == "2" ]]; then
            mode="$forced_mode"
        else
            printf "    %s 用户配置方式:\n" "$label"
            printf "      ${GREEN}1${PLAIN}) 手动输入用户名列表 ${DIM}(默认)${PLAIN}\n"
            printf "      ${GREEN}2${PLAIN}) 自动随机生成用户名\n"
            read -rp "      ${label} 用户配置方式 [1=手动输入, 2=自动生成，默认 1]: " mode
            mode=$(_mihomoconf_trim "${mode:-1}")
        fi
        users=()

        case "$mode" in
            1)
                read -rp "      输入用户名列表 (空格/逗号分隔，如 alice,bob；留空自动生成 1 个): " raw
                raw="${raw//,/ }"
                local token valid=1
                for token in $raw; do
                    token=$(_mihomoconf_trim "$token")
                    [[ -z "$token" ]] && continue
                    if ! _mihomoconf_is_valid_username "$token"; then
                        _warn "用户名 ${token} 无效，仅支持字母/数字/.-_"
                        valid=0
                        break
                    fi
                    local exists=0 u
                    for u in "${users[@]}"; do
                        if [[ "$u" == "$token" ]]; then
                            exists=1
                            break
                        fi
                    done
                    [[ "$exists" -eq 1 ]] || users+=("$token")
                done
                if [[ "$valid" -ne 1 ]]; then
                    continue
                fi
                if (( ${#users[@]} == 0 )); then
                    auto_name_suffix=$(_mihomoconf_gen_uuid | cut -d'-' -f1)
                    users+=("user-${auto_name_suffix}")
                    _info "未输入用户名，已自动生成: ${users[0]}"
                fi
                ;;
            2)
                read -rp "      自动生成数量 [默认 1]: " count
                count=$(_mihomoconf_trim "${count:-1}")
                if ! _is_digit "$count" || [[ "$count" -le 0 ]]; then
                    _warn "数量必须是正整数"
                    continue
                fi
                local idx suffix
                for ((idx=1; idx<=count; idx++)); do
                    suffix=$(_mihomoconf_gen_uuid | cut -d'-' -f1)
                    users+=("user-${idx}-${suffix}")
                done
                ;;
            *)
                _warn "无效选项，请输入 1 或 2"
                continue
                ;;
        esac
        break
    done

    local username password
    for username in "${users[@]}"; do
        case "$password_style" in
            ss128) password=$(_mihomoconf_gen_ss_password_128) ;;
            ss256) password=$(_mihomoconf_gen_ss_password_256) ;;
            *) password=$(_mihomoconf_gen_anytls_password) ;;
        esac
        printf '%s\t%s\n' "$username" "$password"
    done
}

_mihomoconf_read_users_by_tag() {
    local config_file="$1" listener_tag="$2"
    awk -v target="$listener_tag" '
        function trim(s) {
            sub(/^[[:space:]]+/, "", s)
            sub(/[[:space:]]+$/, "", s)
            return s
        }
        function lindent(s, p) {
            p = match(s, /[^ ]/)
            if (p == 0) return length(s)
            return p - 1
        }
        function unquote(s) {
            gsub(/^"/, "", s)
            gsub(/"$/, "", s)
            return s
        }
        function update_match() {
            matched = ((tag != "" && tag == target) || (name != "" && name == target))
        }
        function reset_listener() {
            name=""
            tag=""
            in_users=0
            matched=0
            users_indent=-1
        }
        BEGIN {
            in_listeners=0
            reset_listener()
        }
        /^[^[:space:]#][^:]*:[[:space:]]*.*$/ {
            if (in_listeners) {
                reset_listener()
            }
            in_listeners = ($0 ~ /^listeners:[[:space:]]*$/)
            next
        }
        !in_listeners { next }
        /^[[:space:]]*-[[:space:]]*name:/ {
            reset_listener()
            line=$0
            sub(/^[[:space:]]*-[[:space:]]*name:[[:space:]]*/, "", line)
            name=unquote(trim(line))
            tag=name
            update_match()
            next
        }
        /^[[:space:]]+tag:/ {
            line=$0
            sub(/^[[:space:]]+tag:[[:space:]]*/, "", line)
            tag=unquote(trim(line))
            update_match()
            next
        }
        /^[[:space:]]+users:[[:space:]]*$/ {
            in_users=matched ? 1 : 0
            users_indent=lindent($0)
            next
        }
        in_users {
            curr_indent=lindent($0)
            if (curr_indent <= users_indent) {
                in_users=0
            } else if ($0 ~ /^[[:space:]]+[^[:space:]#].*:/) {
                line=$0
                sub(/^[[:space:]]+/, "", line)
                pos=index(line, ":")
                if (pos > 0) {
                    key=substr(line, 1, pos - 1)
                    val=substr(line, pos + 1)
                    key=unquote(trim(key))
                    if (val !~ /^[[:space:]]*"/) {
                        sub(/[[:space:]]+#.*/, "", val)
                    }
                    val=unquote(trim(val))
                    printf "%s\037%s\n", key, val
                }
                next
            } else {
                next
            }
        }
    ' "$config_file"
}

_mihomoconf_read_listener_user_rows() {
    local config_file="$1"
    local type name port cipher password user_id user_pass sni
    local hy2_up hy2_down hy2_ignore hy2_obfs hy2_obfs_password hy2_masquerade hy2_mport hy2_insecure listener_tag
    local username passwd
    while IFS=$'\x1f' read -r type name port cipher password user_id user_pass sni \
        hy2_up hy2_down hy2_ignore hy2_obfs hy2_obfs_password hy2_masquerade hy2_mport hy2_insecure listener_tag; do
        [[ -z "${name:-}" ]] && continue
        listener_tag="${listener_tag:-$name}"
        while IFS=$'\x1f' read -r username passwd; do
            [[ -z "${username:-}" ]] && continue
            printf "%s\037%s\037%s\037%s\037%s\037%s\n" \
                "$listener_tag" "$name" "$type" "${port:-}" "$username" "$passwd"
        done < <(_mihomoconf_read_users_by_tag "$config_file" "$listener_tag")
    done < <(_mihomoconf_read_listener_rows "$config_file")
}

_mihomoconf_listener_meta_by_tag() {
    local config_file="$1" listener_tag="$2"
    local type name port cipher password user_id user_pass sni
    local hy2_up hy2_down hy2_ignore hy2_obfs hy2_obfs_password hy2_masquerade hy2_mport hy2_insecure tag
    local resolved_tag
    while IFS=$'\x1f' read -r type name port cipher password user_id user_pass sni \
        hy2_up hy2_down hy2_ignore hy2_obfs hy2_obfs_password hy2_masquerade hy2_mport hy2_insecure tag; do
        [[ -n "${name:-}" ]] || continue
        resolved_tag="${tag:-$name}"
        if [[ "$resolved_tag" == "$listener_tag" || "$name" == "$listener_tag" ]]; then
            printf '%s\037%s\037%s\037%s\037%s\n' \
                "$resolved_tag" "$name" "$type" "${cipher:-}" "${password:-}"
            return 0
        fi
    done < <(_mihomoconf_read_listener_rows "$config_file")
    return 1
}

_mihomoconf_count_users_by_tag() {
    local config_file="$1" listener_tag="$2"
    local count=0 u p
    while IFS=$'\x1f' read -r u p; do
        [[ -n "${u:-}" ]] || continue
        count=$((count + 1))
    done < <(_mihomoconf_read_users_by_tag "$config_file" "$listener_tag")
    printf '%s' "$count"
}

_mihomoconf_count_listeners_by_user() {
    local config_file="$1" username="$2"
    local count=0 listener_tag listener_name type port u p
    while IFS=$'\x1f' read -r listener_tag listener_name type port u p; do
        [[ -n "${u:-}" ]] || continue
        [[ "$u" == "$username" ]] || continue
        count=$((count + 1))
    done < <(_mihomoconf_read_listener_user_rows "$config_file")
    printf '%s' "$count"
}

_mihomoconf_unique_listener_tag_by_user() {
    local config_file="$1" username="$2"
    local count=0 found_tag="" listener_tag listener_name type port u p
    while IFS=$'\x1f' read -r listener_tag listener_name type port u p; do
        [[ -n "${u:-}" ]] || continue
        [[ "$u" == "$username" ]] || continue
        found_tag="$listener_tag"
        count=$((count + 1))
        if [[ "$count" -gt 1 ]]; then
            return 1
        fi
    done < <(_mihomoconf_read_listener_user_rows "$config_file")
    [[ "$count" -eq 1 && -n "$found_tag" ]] || return 1
    printf '%s' "$found_tag"
}

_mihomoconf_user_password_by_tag() {
    local config_file="$1" listener_tag="$2" username="$3"
    local u p
    while IFS=$'\x1f' read -r u p; do
        [[ -n "${u:-}" ]] || continue
        if [[ "$u" == "$username" ]]; then
            printf '%s' "$p"
            return 0
        fi
    done < <(_mihomoconf_read_users_by_tag "$config_file" "$listener_tag")
    return 1
}

_mihomoconf_shadowsocks_master_password_for_listener() {
    local config_file="$1" listener_tag="$2" candidate_user_password="${3:-}"
    local resolved_tag listener_name listener_type cipher current_password
    local needs_new="0" u p

    if ! IFS=$'\x1f' read -r resolved_tag listener_name listener_type cipher current_password \
        < <(_mihomoconf_listener_meta_by_tag "$config_file" "$listener_tag"); then
        return 1
    fi
    [[ "$listener_type" == "shadowsocks" ]] || return 1

    if [[ -z "$current_password" ]]; then
        needs_new="1"
    fi
    if [[ -n "$candidate_user_password" && "$current_password" == "$candidate_user_password" ]]; then
        needs_new="1"
    fi
    while IFS=$'\x1f' read -r u p; do
        [[ -n "${u:-}" && -n "${p:-}" ]] || continue
        if [[ "$current_password" == "$p" ]]; then
            needs_new="1"
            break
        fi
    done < <(_mihomoconf_read_users_by_tag "$config_file" "$resolved_tag")

    if [[ "$needs_new" == "1" ]]; then
        current_password=$(_mihomoconf_gen_ss_password_for_cipher "$cipher")
    fi

    printf '%s' "$current_password"
}

_mihomoconf_listener_has_user() {
    local config_file="$1" listener_tag="$2" username="$3"
    local u p
    while IFS=$'\x1f' read -r u p; do
        if [[ "$u" == "$username" ]]; then
            return 0
        fi
    done < <(_mihomoconf_read_users_by_tag "$config_file" "$listener_tag")
    return 1
}

_mihomoconf_add_or_update_listener_user() {
    local config_file="$1" listener_tag="$2" username="$3" password="$4"
    local quoted_user quoted_pass quoted_shadow_pass shadow_pass tmp ec

    [[ -f "$config_file" ]] || return 1
    [[ -n "$listener_tag" && -n "$username" && -n "$password" ]] || return 1
    _mihomoconf_is_valid_username "$username" || return 1

    quoted_user=$(_mihomochain_yaml_quote "$username")
    quoted_pass=$(_mihomochain_yaml_quote "$password")
    shadow_pass=$(_mihomoconf_shadowsocks_master_password_for_listener "$config_file" "$listener_tag" "$password" 2>/dev/null || true)
    [[ -n "$shadow_pass" ]] || shadow_pass="$password"
    quoted_shadow_pass=$(_mihomochain_yaml_quote "$shadow_pass")
    tmp=$(mktemp)
    awk -v target="$listener_tag" -v user="$username" -v q_user="$quoted_user" -v q_pass="$quoted_pass" -v q_shadow_pass="$quoted_shadow_pass" '
        function trim(s) {
            sub(/^[[:space:]]+/, "", s)
            sub(/[[:space:]]+$/, "", s)
            return s
        }
        function lindent(s, p) {
            p = match(s, /[^ ]/)
            if (p == 0) return length(s)
            return p - 1
        }
        function unquote(s) {
            gsub(/^"/, "", s)
            gsub(/"$/, "", s)
            return s
        }
        function clear_item(   i) {
            for (i in item_lines) delete item_lines[i]
            line_count=0
            item_name=""
            item_tag=""
            item_type=""
        }
        function push_line(line, raw) {
            line_count++
            item_lines[line_count]=line
            if (line ~ /^[[:space:]]*-[[:space:]]*name:[[:space:]]*/) {
                raw=line
                sub(/^[[:space:]]*-[[:space:]]*name:[[:space:]]*/, "", raw)
                item_name=unquote(trim(raw))
                if (item_tag == "") item_tag=item_name
            } else if (line ~ /^[[:space:]]+tag:[[:space:]]*/) {
                raw=line
                sub(/^[[:space:]]+tag:[[:space:]]*/, "", raw)
                item_tag=unquote(trim(raw))
            } else if (line ~ /^[[:space:]]+type:[[:space:]]*/) {
                raw=line
                sub(/^[[:space:]]+type:[[:space:]]*/, "", raw)
                item_type=unquote(trim(raw))
            }
        }
        function print_item(   i) {
            for (i=1; i<=line_count; i++) print item_lines[i]
        }
        function upsert_shadow_password_line(   i, j, insert_at, new_line) {
            if (item_type != "shadowsocks") return
            new_line="    password: \"" q_shadow_pass "\""
            for (i=1; i<=line_count; i++) {
                if (item_lines[i] ~ /^[[:space:]]+password:[[:space:]]*/) {
                    if (item_lines[i] != new_line) {
                        item_lines[i]=new_line
                        changed=1
                    }
                    return
                }
            }
            insert_at=0
            for (i=1; i<=line_count; i++) {
                if (item_lines[i] ~ /^[[:space:]]+cipher:[[:space:]]*/) {
                    insert_at=i
                    break
                }
            }
            if (insert_at == 0) {
                for (i=1; i<=line_count; i++) {
                    if (item_lines[i] ~ /^[[:space:]]+port:[[:space:]]*/) {
                        insert_at=i
                        break
                    }
                }
            }
            if (insert_at == 0) insert_at=1
            for (j=line_count; j>=insert_at + 1; j--) {
                item_lines[j + 1]=item_lines[j]
            }
            item_lines[insert_at + 1]=new_line
            line_count++
            changed=1
        }
        function upsert_user(   i, j, line, pos, key, users_idx, users_end, user_line, curr_indent) {
            users_idx=0
            users_end=0
            user_line=0

            for (i=1; i<=line_count; i++) {
                if (item_lines[i] ~ /^[[:space:]]+users:[[:space:]]*$/) {
                    users_idx=i
                    users_end=i
                    break
                }
            }

            if (users_idx > 0) {
                for (i=users_idx + 1; i<=line_count; i++) {
                    curr_indent=lindent(item_lines[i])
                    if (curr_indent <= 4) break
                    users_end=i
                    if (item_lines[i] ~ /^[[:space:]]+[^[:space:]#].*:/) {
                        line=item_lines[i]
                        sub(/^[[:space:]]+/, "", line)
                        pos=index(line, ":")
                        if (pos > 0) {
                            key=unquote(trim(substr(line, 1, pos - 1)))
                            if (key == user) {
                                user_line=i
                            }
                        }
                    }
                }
                if (user_line > 0) {
                    item_lines[user_line] = "      \"" q_user "\": \"" q_pass "\""
                } else {
                    for (j=line_count; j>=users_end + 1; j--) {
                        item_lines[j + 1] = item_lines[j]
                    }
                    item_lines[users_end + 1] = "      \"" q_user "\": \"" q_pass "\""
                    line_count++
                }
                changed=1
                upsert_shadow_password_line()
                return
            }

            line_count++
            item_lines[line_count] = "    users:"
            line_count++
            item_lines[line_count] = "      \"" q_user "\": \"" q_pass "\""
            changed=1
            upsert_shadow_password_line()
        }
        function flush_item(   resolved_tag) {
            if (!in_item) return
            resolved_tag=item_tag
            if (resolved_tag == "") resolved_tag=item_name
            if (resolved_tag == target || item_name == target) {
                matched=1
                if (item_type != "anytls" && item_type != "hysteria2" && item_type != "hy2" && item_type != "shadowsocks") {
                    unsupported=1
                    print_item()
                } else {
                    upsert_user()
                    print_item()
                }
            } else {
                print_item()
            }
            in_item=0
            clear_item()
        }
        BEGIN {
            in_listeners=0
            in_item=0
            matched=0
            unsupported=0
            changed=0
            clear_item()
        }
        /^[^[:space:]#][^:]*:[[:space:]]*.*$/ {
            if (in_listeners) flush_item()
            in_listeners = ($0 ~ /^listeners:[[:space:]]*$/)
            print
            next
        }
        !in_listeners {
            print
            next
        }
        /^[[:space:]]*-[[:space:]]*name:[[:space:]]*/ {
            flush_item()
            in_item=1
            clear_item()
            push_line($0)
            next
        }
        in_item {
            push_line($0)
            next
        }
        { print }
        END {
            if (in_listeners) flush_item()
            if (!matched) exit 2
            if (unsupported) exit 3
            if (!changed) exit 4
        }
    ' "$config_file" > "$tmp"
    ec=$?
    if [[ "$ec" -eq 0 ]]; then
        mv "$tmp" "$config_file"
        return 0
    fi
    rm -f "$tmp"
    return "$ec"
}

_mihomoconf_force_rule_mode() {
    local config_file="$1"
    local tmp
    tmp=$(mktemp)
    awk '
        BEGIN { replaced=0 }
        /^mode:[[:space:]]*/ {
            if (!replaced) {
                print "mode: rule"
                replaced=1
            }
            next
        }
        { print }
        END {
            if (!replaced) print "mode: rule"
        }
    ' "$config_file" > "$tmp"
    mv "$tmp" "$config_file"
}

_mihomoconf_ensure_match_direct_rule() {
    local config_file="$1"
    if grep -Eq '^[[:space:]]*-[[:space:]]*MATCH,DIRECT[[:space:]]*$' "$config_file"; then
        return 0
    fi

    if ! grep -q '^rules:[[:space:]]*$' "$config_file"; then
        {
            echo ""
            echo "rules:"
            echo "  - MATCH,DIRECT"
        } >> "$config_file"
        return 0
    fi

    local tmp
    tmp=$(mktemp)
    awk '
        BEGIN { in_rules=0; inserted=0 }
        /^rules:[[:space:]]*$/ {
            in_rules=1
            print
            next
        }
        in_rules && /^[^ #]/ {
            if (!inserted) {
                print "  - MATCH,DIRECT"
                inserted=1
            }
            in_rules=0
        }
        { print }
        END {
            if (in_rules && !inserted) {
                print "  - MATCH,DIRECT"
            }
        }
    ' "$config_file" > "$tmp"
    mv "$tmp" "$config_file"
}

_mihomoconf_ipv4_google_pref_get() {
    local config_file="$1"
    local pref
    if [[ ! -f "$config_file" ]]; then
        echo "off"
        return 0
    fi
    pref=$(awk '
        /^# vpsgo-ipv4-google:[[:space:]]*(on|off)[[:space:]]*$/ {
            sub(/^# vpsgo-ipv4-google:[[:space:]]*/, "", $0)
            gsub(/[[:space:]]+$/, "", $0)
            print $0
            found=1
            exit
        }
        END {
            if (!found) print "off"
        }
    ' "$config_file")
    if [[ "$pref" != "on" && "$pref" != "off" ]]; then
        echo "off"
    else
        echo "$pref"
    fi
}

_mihomoconf_ipv4_google_pref_set() {
    local config_file="$1" pref="$2"
    local tmp
    [[ "$pref" == "on" ]] || pref="off"
    tmp=$(mktemp)
    awk -v p="$pref" '
        BEGIN { done=0 }
        /^# vpsgo-ipv4-google:[[:space:]]*(on|off)[[:space:]]*$/ {
            if (!done) {
                print "# vpsgo-ipv4-google: " p
                done=1
            }
            next
        }
        { print }
        END {
            if (!done) print "# vpsgo-ipv4-google: " p
        }
    ' "$config_file" > "$tmp"
    mv "$tmp" "$config_file"
}

_mihomoconf_ensure_ipv4_google_rules() {
    local config_file="$1"
    local proxy_name="$_MIHOMOCONF_IPV4_FORCE_PROXY_NAME"
    local tmp

    if ! grep -Fq "name: \"${proxy_name}\"" "$config_file"; then
        if grep -q '^proxies:[[:space:]]*$' "$config_file"; then
            tmp=$(mktemp)
            awk -v pname="$proxy_name" '
                function print_proxy() {
                    print "  - name: \"" pname "\""
                    print "    type: direct"
                    print "    udp: true"
                    print "    ip-version: ipv4"
                }
                BEGIN { in_proxies=0; inserted=0 }
                /^[^ #][^:]*:[[:space:]]*$/ {
                    if (in_proxies && !inserted) {
                        print_proxy()
                        inserted=1
                    }
                    in_proxies = ($0 ~ /^proxies:[[:space:]]*$/)
                    print
                    next
                }
                { print }
                END {
                    if (in_proxies && !inserted) {
                        print_proxy()
                    }
                }
            ' "$config_file" > "$tmp"
            mv "$tmp" "$config_file"
        else
            {
                echo ""
                echo "proxies:"
                echo "  - name: \"${proxy_name}\""
                echo "    type: direct"
                echo "    udp: true"
                echo "    ip-version: ipv4"
            } >> "$config_file"
        fi
    fi

    if ! grep -q '^rules:[[:space:]]*$' "$config_file"; then
        {
            echo ""
            echo "rules:"
            echo "  - DOMAIN,gemini.google.com,${proxy_name}"
            echo "  - DOMAIN,www.google.com,${proxy_name}"
            echo "  - MATCH,DIRECT"
        } >> "$config_file"
        return 0
    fi

    tmp=$(mktemp)
    awk -v pname="$proxy_name" '
        function print_ipv4_domain_rules() {
            print "  - DOMAIN,gemini.google.com," pname
            print "  - DOMAIN,www.google.com," pname
        }
        BEGIN { in_rules=0 }
        /^rules:[[:space:]]*$/ {
            in_rules=1
            print
            print_ipv4_domain_rules()
            next
        }
        in_rules && /^[^ #]/ { in_rules=0 }
        in_rules && /^[[:space:]]*-[[:space:]]*DOMAIN,gemini\.google\.com,/ { next }
        in_rules && /^[[:space:]]*-[[:space:]]*DOMAIN,www\.google\.com,/ { next }
        { print }
    ' "$config_file" > "$tmp"
    mv "$tmp" "$config_file"

    _mihomoconf_ensure_match_direct_rule "$config_file"
}

_mihomoconf_remove_ipv4_google_rules() {
    local config_file="$1"
    local proxy_name="$_MIHOMOCONF_IPV4_FORCE_PROXY_NAME"
    local tmp

    tmp=$(mktemp)
    awk -v pname="$proxy_name" '
        function trim(s) {
            sub(/^[[:space:]]+/, "", s)
            sub(/[[:space:]]+$/, "", s)
            return s
        }
        function unquote(s) {
            gsub(/^"/, "", s)
            gsub(/"$/, "", s)
            return s
        }
        BEGIN {
            in_proxies=0
            skip_proxy=0
        }
        /^[^ #][^:]*:[[:space:]]*$/ {
            in_proxies = ($0 ~ /^proxies:[[:space:]]*$/)
            skip_proxy=0
            print
            next
        }
        in_proxies && /^  - name:/ {
            line=$0
            sub(/^  - name:[[:space:]]*/, "", line)
            item=unquote(trim(line))
            if (item == pname) {
                skip_proxy=1
                next
            }
            skip_proxy=0
        }
        in_proxies && skip_proxy { next }
        /^[[:space:]]*-[[:space:]]*DOMAIN,gemini\.google\.com,/ { next }
        /^[[:space:]]*-[[:space:]]*DOMAIN,www\.google\.com,/ { next }
        { print }
    ' "$config_file" > "$tmp"
    mv "$tmp" "$config_file"
    _mihomoconf_ensure_match_direct_rule "$config_file"
}

_mihomoconf_apply_ipv4_google_policy() {
    local config_file="$1"
    local pref
    pref=$(_mihomoconf_ipv4_google_pref_get "$config_file")
    if [[ "$pref" == "on" ]]; then
        _mihomoconf_ensure_ipv4_google_rules "$config_file"
    else
        _mihomoconf_remove_ipv4_google_rules "$config_file"
    fi
}

_mihomoconf_setup() {
    _header "Mihomo 配置生成"

    local CONFIG_DIR="$_MIHOMOCONF_CONFIG_DIR"
    local CONFIG_FILE="$_MIHOMOCONF_CONFIG_FILE"
    local SSL_DIR="$_MIHOMOCONF_SSL_DIR"
    local CONFIG_STATUS

    local WRITE_MODE="new"
    local ENABLE_SS="n" ENABLE_ANYTLS="n" ENABLE_HY2="n"
    local SS_COUNT=0 ANYTLS_COUNT=0 HY2_COUNT=0
    local SS_REPLACE="n" ANYTLS_REPLACE="n" HY2_REPLACE="n"

    local -a SS_PORTS=() SS_TAGS=() SS_USER_ROWS=() SS_SERVER_PASSWORDS=()
    local SS_CIPHER=""
    local SS_EXPORT_UDP="1" SS_EXPORT_UOT="0"
    local -a ANYTLS_PORTS=() ANYTLS_TAGS=() ANYTLS_USER_ROWS=()
    local ANYTLS_SNI=""
    local -a HY2_PORTS=() HY2_TAGS=() HY2_MPORTS=() HY2_OBFS_PASSWORDS=() HY2_USER_ROWS=()
    local -a RESERVED_PORTS=() NEW_PORTS=()
    local HY2_UP="" HY2_DOWN=""
    local HY2_IGNORE_CLIENT_BANDWIDTH="false" HY2_SNI="" HY2_INSECURE="0"
    local HY2_OBFS="" HY2_MASQUERADE=""
    local IPV4_GOOGLE_PREF="off"
    local NODE_COUNTRY="" NODE_CITY="" NODE_COUNTRY_CODE="UN" NODE_FLAG="🏳"
    local SERVER_IP="" SERVER_HOST="" SAVED_HOST="" HOST_DEFAULT="" host_input=""

    if [[ -f "$CONFIG_FILE" ]]; then
        CONFIG_STATUS="已存在"
    else
        CONFIG_STATUS="不存在(生成时自动创建)"
    fi
    _info "配置: ${CONFIG_FILE}"
    _info "状态: ${CONFIG_STATUS}"
    _info "支持: AnyTLS / SS2022 / HY2"
    SAVED_HOST=$(_mihomoconf_get_saved_host "$CONFIG_FILE")
    [[ -n "$SAVED_HOST" ]] && _info "已保存 Host: ${SAVED_HOST}"
    IPV4_GOOGLE_PREF=$(_mihomoconf_ipv4_google_pref_get "$CONFIG_FILE")
    if [[ "$IPV4_GOOGLE_PREF" == "on" ]]; then
        _info "IPv4 定向(google/gemini): 已启用"
    else
        _info "IPv4 定向(google/gemini): 未启用"
    fi

    # ---- 判断写入模式 ----
    if [[ -f "$CONFIG_FILE" ]]; then
        printf "  ${BOLD}请选择操作 (已有配置)${PLAIN}\n"
        _separator
        _menu_pair "1" "追加新节点到现有配置" "" "green" "2" "覆盖并重新生成配置" "" "yellow"
        _menu_item "0" "返回主菜单" "" "red"
        _separator
        local file_action
        read -rp "  请选择 [0-2]: " file_action
        case "$file_action" in
            1) WRITE_MODE="append" ;;
            2) WRITE_MODE="new" ;;
            0) return ;;
            *) _error_no_exit "无效选项"; _press_any_key; return ;;
        esac
    fi

    # ---- 选择协议 ----
    printf "  ${BOLD}请选择要添加的协议 (可重复输入，空格分隔，可添加不同落地链式代理)${PLAIN}\n"
    printf "  ${DIM}提示: 每输入一次数字就会创建一个对应协议入站，例如 1 1 3 = 2个SS2022 + 1个HY2${PLAIN}\n"
    _separator
    _menu_pair "1" "SS2022" "" "green" "2" "AnyTLS" "" "green"
    _menu_item "3" "HY2" "" "green"
    _separator
    local PROTOCOL_CHOICES
    read -rp "  选择 (如 \"1 1 2\" 表示 2 个 SS + 1 个 AnyTLS): " -a PROTOCOL_CHOICES

    for ch in "${PROTOCOL_CHOICES[@]}"; do
        case "$ch" in
            1) ENABLE_SS="y"; SS_COUNT=$((SS_COUNT + 1)) ;;
            2) ENABLE_ANYTLS="y"; ANYTLS_COUNT=$((ANYTLS_COUNT + 1)) ;;
            3) ENABLE_HY2="y"; HY2_COUNT=$((HY2_COUNT + 1)) ;;
            *) _warn "忽略无效选项: $ch" ;;
        esac
    done
    if [[ "$SS_COUNT" -eq 0 && "$ANYTLS_COUNT" -eq 0 && "$HY2_COUNT" -eq 0 ]]; then
        _error_no_exit "未选择任何协议"
        _press_any_key
        return
    fi
    _status_kv "SS2022 数量" "${SS_COUNT}" "cyan" 10
    _status_kv "AnyTLS 数量" "${ANYTLS_COUNT}" "cyan" 10
    _status_kv "HY2 数量" "${HY2_COUNT}" "cyan" 10

    # ---- 追加模式: 检查已有同协议节点 ----
    if [[ "$WRITE_MODE" == "append" ]]; then
        if [[ "$ENABLE_SS" == "y" ]] && _mihomoconf_has_listener_type "shadowsocks"; then
            _warn "配置中已存在 SS2022 节点:"
            _mihomoconf_list_listeners "shadowsocks"
            _separator
            _menu_pair "1" "覆盖已有 SS2022 节点" "" "yellow" "2" "保留已有，继续添加" "" "green"
            _separator
            local ss_action
            read -rp "  请选择 [1/2，默认 2]: " ss_action
            [[ "${ss_action:-2}" == "1" ]] && SS_REPLACE="y"
        fi
        if [[ "$ENABLE_ANYTLS" == "y" ]] && _mihomoconf_has_listener_type "anytls"; then
            _warn "配置中已存在 AnyTLS 节点:"
            _mihomoconf_list_listeners "anytls"
            _separator
            _menu_pair "1" "覆盖已有 AnyTLS 节点" "" "yellow" "2" "保留已有，继续添加" "" "green"
            _separator
            local anytls_action
            read -rp "  请选择 [1/2，默认 2]: " anytls_action
            [[ "${anytls_action:-2}" == "1" ]] && ANYTLS_REPLACE="y"
        fi
        if [[ "$ENABLE_HY2" == "y" ]] && _mihomoconf_has_listener_type "hysteria2"; then
            _warn "配置中已存在 HY2 节点:"
            _mihomoconf_list_listeners "hysteria2"
            _separator
            _menu_pair "1" "覆盖已有 HY2 节点" "" "yellow" "2" "保留已有，继续添加" "" "green"
            _separator
            local hy2_action
            read -rp "  请选择 [1/2，默认 2]: " hy2_action
            [[ "${hy2_action:-2}" == "1" ]] && HY2_REPLACE="y"
        fi
    fi

    # ---- 端口冲突基线: 追加模式下保留现有端口（被替换协议除外）----
    if [[ "$WRITE_MODE" == "append" && -f "$CONFIG_FILE" ]]; then
        local _e_type _e_name _e_port _e_cipher _e_password _e_user_id _e_user_pass _e_sni _e_tag
        local _e_hy2_up _e_hy2_down _e_hy2_ignore _e_hy2_obfs _e_hy2_obfs_password _e_hy2_masquerade _e_hy2_mport _e_hy2_insecure
        while IFS=$'\x1f' read -r _e_type _e_name _e_port _e_cipher _e_password _e_user_id _e_user_pass _e_sni \
            _e_hy2_up _e_hy2_down _e_hy2_ignore _e_hy2_obfs _e_hy2_obfs_password _e_hy2_masquerade _e_hy2_mport _e_hy2_insecure _e_tag; do
            [[ -z "${_e_port:-}" ]] && continue
            case "$_e_type" in
                shadowsocks) [[ "$SS_REPLACE" == "y" ]] && continue ;;
                anytls) [[ "$ANYTLS_REPLACE" == "y" ]] && continue ;;
                hysteria2) [[ "$HY2_REPLACE" == "y" ]] && continue ;;
            esac
            _mihomoconf_port_in_list "$_e_port" "${RESERVED_PORTS[@]}" || RESERVED_PORTS+=("$_e_port")
        done < <(_mihomoconf_read_listener_rows "$CONFIG_FILE")
        if [ "${#RESERVED_PORTS[@]}" -gt 0 ]; then
            _info "已加载现有监听端口 ${#RESERVED_PORTS[@]} 个，创建时将自动避开冲突"
        fi
    fi

    # ---- SS2022 配置 ----
    if [[ "$ENABLE_SS" == "y" ]]; then
        printf "  ${BOLD}SS2022 配置${PLAIN}\n"
        _separator
        local _ss_idx ss_port_input
        for ((_ss_idx=1; _ss_idx<=SS_COUNT; _ss_idx++)); do
            while true; do
                read -rp "    SS2022 #${_ss_idx} 监听端口 [默认 12353]: " ss_port_input
                ss_port_input=$(_mihomoconf_trim "${ss_port_input:-12353}")
                if _is_valid_port "$ss_port_input"; then
                    if _mihomoconf_port_in_list "$ss_port_input" "${NEW_PORTS[@]}"; then
                        _warn "端口 ${ss_port_input} 与本次新增节点冲突，请更换端口"
                        continue
                    fi
                    if _mihomoconf_port_in_list "$ss_port_input" "${RESERVED_PORTS[@]}"; then
                        _warn "端口 ${ss_port_input} 已被现有 listeners 占用，请更换端口"
                        continue
                    fi
                    SS_PORTS+=("$ss_port_input")
                    NEW_PORTS+=("$ss_port_input")
                    break
                fi
                _warn "端口无效，请输入 1-65535 的数字"
            done
        done

        echo "    请选择加密方式:"
        printf "      ${GREEN}1${PLAIN}) 2022-blake3-aes-128-gcm ${DIM}(推荐)${PLAIN}\n"
        printf "      ${GREEN}2${PLAIN}) 2022-blake3-aes-256-gcm\n"
        local cipher_choice
        read -rp "    选择 [1/2，默认 1]: " cipher_choice
        case "${cipher_choice:-1}" in
            1) SS_CIPHER="2022-blake3-aes-128-gcm" ;;
            2) SS_CIPHER="2022-blake3-aes-256-gcm" ;;
            *) _error_no_exit "无效选项"; _press_any_key; return ;;
        esac
        local i _user_rows _u_name _u_pass _ss_user_total=0 _ss_pw_style
        if [[ "$SS_CIPHER" == "2022-blake3-aes-128-gcm" ]]; then
            _ss_pw_style="ss128"
        else
            _ss_pw_style="ss256"
        fi
        for i in "${!SS_PORTS[@]}"; do
            SS_TAGS+=("$(_mihomoconf_gen_listener_tag "ss_relay")")
            _user_rows=$(_mihomoconf_collect_users_input "SS2022 #$((i + 1))" "" "$_ss_pw_style")
            while IFS=$'\t' read -r _u_name _u_pass; do
                [[ -z "${_u_name:-}" || -z "${_u_pass:-}" ]] && continue
                SS_USER_ROWS+=("${i}"$'\x1f'"${_u_name}"$'\x1f'"${_u_pass}")
                _ss_user_total=$((_ss_user_total + 1))
            done <<< "$_user_rows"
        done
        _info "SS2022 已生成 ${#SS_PORTS[@]} 个入站，共 ${_ss_user_total} 个 user"
    fi

    # ---- AnyTLS 配置 ----
    if [[ "$ENABLE_ANYTLS" == "y" ]]; then
        printf "  ${BOLD}AnyTLS 配置${PLAIN}\n"
        _separator
        local _anytls_idx anytls_port_input
        for ((_anytls_idx=1; _anytls_idx<=ANYTLS_COUNT; _anytls_idx++)); do
            while true; do
                read -rp "    AnyTLS #${_anytls_idx} 监听端口 [默认 443]: " anytls_port_input
                anytls_port_input=$(_mihomoconf_trim "${anytls_port_input:-443}")
                if _is_valid_port "$anytls_port_input"; then
                    if _mihomoconf_port_in_list "$anytls_port_input" "${NEW_PORTS[@]}"; then
                        _warn "端口 ${anytls_port_input} 与本次新增节点冲突，请更换端口"
                        continue
                    fi
                    if _mihomoconf_port_in_list "$anytls_port_input" "${RESERVED_PORTS[@]}"; then
                        _warn "端口 ${anytls_port_input} 已被现有 listeners 占用，请更换端口"
                        continue
                    fi
                    ANYTLS_PORTS+=("$anytls_port_input")
                    NEW_PORTS+=("$anytls_port_input")
                    break
                fi
                _warn "端口无效，请输入 1-65535 的数字"
            done
        done
        read -rp "    SNI 域名 (留空则用 IP): " ANYTLS_SNI
        ANYTLS_SNI=$(_mihomoconf_trim "${ANYTLS_SNI:-}")
        local i _user_rows _u_name _u_pass _user_total=0
        for i in "${!ANYTLS_PORTS[@]}"; do
            ANYTLS_TAGS+=("$(_mihomoconf_gen_listener_tag "anytls_relay")")
            _user_rows=$(_mihomoconf_collect_users_input "AnyTLS #$((i + 1))")
            while IFS=$'\t' read -r _u_name _u_pass; do
                [[ -z "${_u_name:-}" || -z "${_u_pass:-}" ]] && continue
                ANYTLS_USER_ROWS+=("${i}"$'\x1f'"${_u_name}"$'\x1f'"${_u_pass}")
                _user_total=$((_user_total + 1))
            done <<< "$_user_rows"
        done
        _info "AnyTLS 已生成 ${#ANYTLS_PORTS[@]} 个入站，共 ${_user_total} 个 user"
    fi

    # ---- HY2 配置 ----
    if [[ "$ENABLE_HY2" == "y" ]]; then
        printf "  ${BOLD}HY2 配置${PLAIN}\n"
        _separator
        local _hy2_idx hy2_port_input
        for ((_hy2_idx=1; _hy2_idx<=HY2_COUNT; _hy2_idx++)); do
            while true; do
                read -rp "    HY2 #${_hy2_idx} 监听端口 [默认 8080]: " hy2_port_input
                hy2_port_input=$(_mihomoconf_trim "${hy2_port_input:-8080}")
                if _is_valid_port "$hy2_port_input"; then
                    if _mihomoconf_port_in_list "$hy2_port_input" "${NEW_PORTS[@]}"; then
                        _warn "端口 ${hy2_port_input} 与本次新增节点冲突，请更换端口"
                        continue
                    fi
                    if _mihomoconf_port_in_list "$hy2_port_input" "${RESERVED_PORTS[@]}"; then
                        _warn "端口 ${hy2_port_input} 已被现有 listeners 占用，请更换端口"
                        continue
                    fi
                    HY2_PORTS+=("$hy2_port_input")
                    NEW_PORTS+=("$hy2_port_input")
                    break
                fi
                _warn "端口无效，请输入 1-65535 的数字"
            done
        done

        if [[ -n "${ANYTLS_SNI:-}" ]]; then
            read -rp "    HY2 SNI 域名 [默认复用 AnyTLS: ${ANYTLS_SNI}]: " HY2_SNI
            HY2_SNI=$(_mihomoconf_trim "${HY2_SNI:-$ANYTLS_SNI}")
        else
            read -rp "    HY2 SNI 域名 (留空则用 IP): " HY2_SNI
            HY2_SNI=$(_mihomoconf_trim "${HY2_SNI:-}")
        fi

        read -rp "    up 上传速率 [默认 1000 Mbps]: " HY2_UP
        HY2_UP="${HY2_UP:-1000}"
        if ! _is_digit "$HY2_UP" || [[ "$HY2_UP" -le 0 ]]; then
            _error_no_exit "up 必须为正整数"
            _press_any_key
            return
        fi

        read -rp "    down 下载速率 [默认 1000 Mbps]: " HY2_DOWN
        HY2_DOWN="${HY2_DOWN:-1000}"
        if ! _is_digit "$HY2_DOWN" || [[ "$HY2_DOWN" -le 0 ]]; then
            _error_no_exit "down 必须为正整数"
            _press_any_key
            return
        fi

        # 按默认安全行为固定为关闭，不再交互询问
        HY2_IGNORE_CLIENT_BANDWIDTH="false"
        HY2_INSECURE="0"
        local _hy2_port
        for _hy2_port in "${HY2_PORTS[@]}"; do
            HY2_MPORTS+=("")
        done

        HY2_OBFS="salamander"
        for _hy2_port in "${HY2_PORTS[@]}"; do
            HY2_OBFS_PASSWORDS+=("$(_mihomoconf_gen_anytls_password)")
        done
        _info "HY2 salamander 已默认开启，obfs 密码随机生成"

        if [[ -n "$HY2_OBFS" ]]; then
            HY2_MASQUERADE=""
            _info "HY2 已启用 obfs=${HY2_OBFS}，将不写入 masquerade 以避免协议冲突"
        else
            local hy2_masquerade_input
            read -rp "    masquerade URL [默认 https://bing.com，输入 none 关闭]: " hy2_masquerade_input
            case "${hy2_masquerade_input:-}" in
                "") HY2_MASQUERADE="https://bing.com" ;;
                none|None|NONE) HY2_MASQUERADE="" ;;
                *) HY2_MASQUERADE="$hy2_masquerade_input" ;;
            esac
        fi

        local i _user_rows _u_name _u_pass _hy2_user_total=0
        for i in "${!HY2_PORTS[@]}"; do
            HY2_TAGS+=("$(_mihomoconf_gen_listener_tag "hy2_relay")")
            _user_rows=$(_mihomoconf_collect_users_input "HY2 #$((i + 1))" "1")
            while IFS=$'\t' read -r _u_name _u_pass; do
                [[ -z "${_u_name:-}" || -z "${_u_pass:-}" ]] && continue
                HY2_USER_ROWS+=("${i}"$'\x1f'"${_u_name}"$'\x1f'"${_u_pass}")
                _hy2_user_total=$((_hy2_user_total + 1))
            done <<< "$_user_rows"
        done
        _info "HY2 已生成 ${#HY2_PORTS[@]} 个入站，共 ${_hy2_user_total} 个 user"
    fi

    # ---- TLS 证书检查 (AnyTLS / HY2 共用) ----
    if [[ "$ENABLE_ANYTLS" == "y" || "$ENABLE_HY2" == "y" ]]; then
        mkdir -p "$SSL_DIR"
        if [[ -f "${SSL_DIR}/cert.crt" && -f "${SSL_DIR}/cert.key" ]]; then
            _info "已检测到 TLS 证书: ${SSL_DIR}/"
        else
            _warn "AnyTLS/HY2 需要 TLS 证书才能正常运行!"
            _warn "请将证书文件放到以下路径:"
            printf "    证书: ${YELLOW}${SSL_DIR}/cert.crt${PLAIN}\n"
            printf "    私钥: ${YELLOW}${SSL_DIR}/cert.key${PLAIN}\n"
            _info "目录 ${SSL_DIR}/ 已自动创建"
            printf "${YELLOW}  按任意键继续...${PLAIN}"
            local SAVEDSTTY
            SAVEDSTTY=$(stty -g)
            stty -echo -icanon
            dd if=/dev/tty bs=1 count=1 2>/dev/null
            stty "$SAVEDSTTY"
            echo ""
        fi
    fi

    SERVER_IP=$(_mihomoconf_get_server_ip)
    _info "服务器 IP: ${SERVER_IP}"
    IFS=$'\x1f' read -r NODE_COUNTRY NODE_CITY NODE_COUNTRY_CODE NODE_FLAG < <(_mihomoconf_get_geo_profile "$SERVER_IP")
    if [[ -n "$NODE_CITY" ]]; then
        _info "地区识别: ${NODE_COUNTRY} ${NODE_CITY} (${NODE_FLAG}${NODE_COUNTRY_CODE})"
    else
        _info "地区识别: ${NODE_COUNTRY} (${NODE_FLAG}${NODE_COUNTRY_CODE})"
    fi
    if [[ -n "$SAVED_HOST" ]]; then
        HOST_DEFAULT="$SAVED_HOST"
    elif [[ -n "${ANYTLS_SNI:-}" ]]; then
        HOST_DEFAULT="$ANYTLS_SNI"
    elif [[ -n "${HY2_SNI:-}" ]]; then
        HOST_DEFAULT="$HY2_SNI"
    else
        HOST_DEFAULT="$SERVER_IP"
    fi
    read -rp "  链接/JSON Host [默认 ${HOST_DEFAULT}，可填域名]: " host_input
    SERVER_HOST=$(_mihomoconf_trim "${host_input:-$HOST_DEFAULT}")
    _info "导出 Host: ${SERVER_HOST}"

    # ---- 写入配置 ----
    mkdir -p "$CONFIG_DIR"

    # 内部函数: 追加 listeners 到指定文件
    _mihomoconf_append_listeners_to() {
        local _target_file="$1"
        local i
        local _ss_port _ss_tag
        local _anytls_port _anytls_tag
        local _hy2_port _hy2_tag _hy2_mport _hy2_obfs_password
        local _row _li _u_name _u_pass _ss_primary_pass _ss_server_pass _ss_has_user
        if [[ "$ENABLE_SS" == "y" ]]; then
            for i in "${!SS_PORTS[@]}"; do
                _ss_port="${SS_PORTS[$i]}"
                _ss_tag="${SS_TAGS[$i]}"
                _ss_primary_pass=""
                _ss_server_pass=$(_mihomoconf_gen_ss_password_for_cipher "$SS_CIPHER")
                SS_SERVER_PASSWORDS[$i]="$_ss_server_pass"
                _ss_has_user=0
                cat >> "$_target_file" <<MIHOMOCONF_SS_EOF
  - name: ss2022-in-${_ss_port}
    tag: "${_ss_tag}"
    type: shadowsocks
    port: ${_ss_port}
    listen: "::"
    cipher: ${SS_CIPHER}
MIHOMOCONF_SS_EOF
                for _row in "${SS_USER_ROWS[@]}"; do
                    IFS=$'\x1f' read -r _li _u_name _u_pass <<< "$_row"
                    [[ "$_li" == "$i" ]] || continue
                    [[ -n "$_u_pass" && -z "$_ss_primary_pass" ]] && _ss_primary_pass="$_u_pass"
                done
                if [[ -z "$_ss_primary_pass" ]]; then
                    _ss_primary_pass=$(_mihomoconf_gen_ss_password_for_cipher "$SS_CIPHER")
                fi
                printf "    password: \"%s\"\n" "$_ss_server_pass" >> "$_target_file"
                printf "    users:\n" >> "$_target_file"
                for _row in "${SS_USER_ROWS[@]}"; do
                    IFS=$'\x1f' read -r _li _u_name _u_pass <<< "$_row"
                    [[ "$_li" == "$i" ]] || continue
                    _ss_has_user=1
                    printf "      \"%s\": \"%s\"\n" "$_u_name" "$_u_pass" >> "$_target_file"
                done
                if [[ "$_ss_has_user" -eq 0 ]]; then
                    printf "      \"direct\": \"%s\"\n" "$_ss_primary_pass" >> "$_target_file"
                fi
                printf "    udp: true\n" >> "$_target_file"
            done
        fi
        if [[ "$ENABLE_ANYTLS" == "y" ]]; then
            for i in "${!ANYTLS_PORTS[@]}"; do
                _anytls_port="${ANYTLS_PORTS[$i]}"
                _anytls_tag="${ANYTLS_TAGS[$i]}"
                cat >> "$_target_file" <<MIHOMOCONF_AT_EOF
  - name: anytls-in-${_anytls_port}
    tag: "${_anytls_tag}"
    type: anytls
    port: ${_anytls_port}
    listen: "::"
    # vpsgo-sni: ${ANYTLS_SNI}
    certificate: "${SSL_DIR}/cert.crt"
    private-key: "${SSL_DIR}/cert.key"
    users:
MIHOMOCONF_AT_EOF
                for _row in "${ANYTLS_USER_ROWS[@]}"; do
                    IFS=$'\x1f' read -r _li _u_name _u_pass <<< "$_row"
                    [[ "$_li" == "$i" ]] || continue
                    printf "      \"%s\": \"%s\"\n" "$_u_name" "$_u_pass" >> "$_target_file"
                done
            done
        fi
        if [[ "$ENABLE_HY2" == "y" ]]; then
            for i in "${!HY2_PORTS[@]}"; do
                _hy2_port="${HY2_PORTS[$i]}"
                _hy2_tag="${HY2_TAGS[$i]}"
                _hy2_mport="${HY2_MPORTS[$i]}"
                _hy2_obfs_password="${HY2_OBFS_PASSWORDS[$i]}"
                cat >> "$_target_file" <<MIHOMOCONF_HY2_EOF
  - name: hy2-in-${_hy2_port}
    tag: "${_hy2_tag}"
    type: hysteria2
    port: ${_hy2_port}
    listen: "::"
    # vpsgo-peer: ${HY2_SNI}
    # vpsgo-mport: ${_hy2_mport}
    # vpsgo-insecure: ${HY2_INSECURE}
    users:
MIHOMOCONF_HY2_EOF
                for _row in "${HY2_USER_ROWS[@]}"; do
                    IFS=$'\x1f' read -r _li _u_name _u_pass <<< "$_row"
                    [[ "$_li" == "$i" ]] || continue
                    printf "      \"%s\": \"%s\"\n" "$_u_name" "$_u_pass" >> "$_target_file"
                done
                cat >> "$_target_file" <<MIHOMOCONF_HY2_RATE_EOF
    up: ${HY2_UP}
    down: ${HY2_DOWN}
    ignore-client-bandwidth: ${HY2_IGNORE_CLIENT_BANDWIDTH}
MIHOMOCONF_HY2_RATE_EOF
                if [[ -n "$HY2_OBFS" ]]; then
                    cat >> "$_target_file" <<MIHOMOCONF_HY2_OBFS_EOF
    obfs: ${HY2_OBFS}
    obfs-password: "${_hy2_obfs_password}"
MIHOMOCONF_HY2_OBFS_EOF
                fi
                if [[ -n "$HY2_MASQUERADE" ]]; then
                    printf "    masquerade: \"%s\"\n" "$HY2_MASQUERADE" >> "$_target_file"
                fi
                cat >> "$_target_file" <<MIHOMOCONF_HY2_TLS_EOF
    alpn:
      - h3
    certificate: "${SSL_DIR}/cert.crt"
    private-key: "${SSL_DIR}/cert.key"
MIHOMOCONF_HY2_TLS_EOF
            done
        fi
    }

    if [[ "$WRITE_MODE" == "new" ]]; then
        cat > "$CONFIG_FILE" <<'MIHOMOCONF_HEADER'
# mihomo 服务端配置 (自动生成)
allow-lan: false
mode: rule
log-level: info
ipv6: true

dns:
  enable: true
  ipv6: true
  nameserver:
    - system

listeners:
MIHOMOCONF_HEADER
        _mihomoconf_append_listeners_to "$CONFIG_FILE"
    else
        [[ "$SS_REPLACE" == "y" ]] && _mihomoconf_remove_listeners_by_type "shadowsocks" && _info "已移除旧的 SS2022 节点"
        [[ "$ANYTLS_REPLACE" == "y" ]] && _mihomoconf_remove_listeners_by_type "anytls" && _info "已移除旧的 AnyTLS 节点"
        [[ "$HY2_REPLACE" == "y" ]] && _mihomoconf_remove_listeners_by_type "hysteria2" && _info "已移除旧的 HY2 节点"
        if grep -q '^listeners:' "$CONFIG_FILE" 2>/dev/null; then
            # 将新 listener 内容插入到 listeners: 块末尾（下一个顶级键之前）
            local _tmplistener
            _tmplistener="$(mktemp)"
            _mihomoconf_append_listeners_to "$_tmplistener"
            local _insert_line
            _insert_line=$(awk '/^listeners:/{found=NR; next} found && /^[^ #]/{print NR; exit}' "$CONFIG_FILE")
            if [ -n "$_insert_line" ]; then
                sed -i "$((_insert_line - 1))r $_tmplistener" "$CONFIG_FILE"
            else
                cat "$_tmplistener" >> "$CONFIG_FILE"
            fi
            rm -f "$_tmplistener"
        else
            echo "" >> "$CONFIG_FILE"
            echo "listeners:" >> "$CONFIG_FILE"
            _mihomoconf_append_listeners_to "$CONFIG_FILE"
        fi
    fi
    _mihomoconf_force_rule_mode "$CONFIG_FILE"
    _mihomoconf_ensure_match_direct_rule "$CONFIG_FILE"
    _mihomoconf_ipv4_google_pref_set "$CONFIG_FILE" "$IPV4_GOOGLE_PREF"
    _mihomoconf_apply_ipv4_google_policy "$CONFIG_FILE"
    _mihomoconf_set_saved_host "$CONFIG_FILE" "$SERVER_HOST"

    # ---- 输出结果 ----
    _header "配置生成完成"
    _info "配置文件: ${CONFIG_FILE}"
    _info "写入模式: $( [[ "$WRITE_MODE" == "new" ]] && echo "全新生成" || echo "追加到现有配置" )"

    # SS2022 输出
    if [[ "$ENABLE_SS" == "y" ]]; then
        local ss_export_udp_answer ss_export_uot_answer _ss_udp_bool _ss_uot_bool
        read -rp "  SS 导出: 是否开启 UDP? [Y/n]: " ss_export_udp_answer
        if [[ "$ss_export_udp_answer" =~ ^([Nn]|[Nn][Oo])$ ]]; then
            SS_EXPORT_UDP="0"
            SS_EXPORT_UOT="0"
            _info "已关闭 SS 导出的 UDP 与 UDP over TCP v2"
        else
            read -rp "  SS 导出: 是否开启 UDP over TCP v2? [y/N]: " ss_export_uot_answer
            if [[ "$ss_export_uot_answer" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]; then
                SS_EXPORT_UOT="1"
            else
                SS_EXPORT_UOT="0"
            fi
        fi
        [[ "$SS_EXPORT_UDP" == "1" ]] && _ss_udp_bool="true" || _ss_udp_bool="false"
        [[ "$SS_EXPORT_UOT" == "1" ]] && _ss_uot_bool="true" || _ss_uot_bool="false"

        printf "  ${BOLD}SS2022 连接信息 (%s 个)${PLAIN}\n" "${#SS_PORTS[@]}"
        local i SS_LINK _ss_port _ss_tag _ss_name _ss_client_name _row _li _u_name _u_pass _user_idx
        for i in "${!SS_PORTS[@]}"; do
            _ss_port="${SS_PORTS[$i]}"
            _ss_tag="${SS_TAGS[$i]}"
            _ss_name=$(_mihomoconf_make_node_name "SS" "$NODE_FLAG" "$NODE_COUNTRY_CODE")
            _separator
            printf "    [%s] 节点名: ${GREEN}%s${PLAIN}\n" "$((i + 1))" "$_ss_name"
            printf "      入站tag: ${GREEN}%s${PLAIN}\n" "$_ss_tag"
            printf "      服务器 : ${GREEN}%s${PLAIN}\n" "$SERVER_HOST"
            printf "      端口   : ${GREEN}%s${PLAIN}\n" "$_ss_port"
            printf "      加密   : ${GREEN}%s${PLAIN}\n" "$SS_CIPHER"
            _user_idx=0
            for _row in "${SS_USER_ROWS[@]}"; do
                IFS=$'\x1f' read -r _li _u_name _u_pass <<< "$_row"
                [[ "$_li" == "$i" ]] || continue
                _user_idx=$((_user_idx + 1))
                _ss_client_name="${_ss_name}-${_u_name}"
                local _client_pass="${_u_pass}"
                if [[ "$SS_CIPHER" == *"2022"* ]]; then
                    _client_pass="${SS_SERVER_PASSWORDS[$i]}:${_u_pass}"
                fi
                SS_LINK=$(_mihomoconf_gen_ss_link "$SERVER_HOST" "$_ss_port" "$SS_CIPHER" "$_client_pass" "$_ss_client_name" "$SS_EXPORT_UDP" "$SS_EXPORT_UOT")
                printf "      用户[%s]: ${GREEN}%s${PLAIN}\n" "$_user_idx" "$_u_name"
                printf "      密码   : ${GREEN}%s${PLAIN}\n" "$_u_pass"
                printf "  ${BOLD}SS2022 分享链接:${PLAIN}\n"
                printf "  ${GREEN}%s${PLAIN}\n" "$SS_LINK"
                printf "  ${BOLD}Clash Meta 客户端 YAML:${PLAIN}\n"
                cat <<MIHOMOCONF_SS_YAML
    proxies:
      - name: "${_ss_client_name}"
        type: ss
        server: ${SERVER_HOST}
        port: ${_ss_port}
        cipher: ${SS_CIPHER}
        password: "${_client_pass}"
MIHOMOCONF_SS_YAML
                printf "        udp: %s\n" "$_ss_udp_bool"
                printf "        tfo: true\n"
                printf "        udp-over-tcp: %s\n" "$_ss_uot_bool"
                if [[ "$SS_EXPORT_UOT" == "1" ]]; then
                    printf "        udp-over-tcp-version: 2\n"
                fi
            done
            if [[ "$_user_idx" -eq 0 ]]; then
                _warn "  SS2022 入站 ${_ss_tag} 未配置 user，已跳过导出"
            fi
        done
    fi

    # AnyTLS 输出
    if [[ "$ENABLE_ANYTLS" == "y" ]]; then
        printf "  ${BOLD}AnyTLS 连接信息 (%s 个)${PLAIN}\n" "${#ANYTLS_PORTS[@]}"
        local i ANYTLS_LINK _anytls_port _anytls_tag _anytls_name _anytls_client_name
        local _row _li _u_name _u_pass _user_idx
        for i in "${!ANYTLS_PORTS[@]}"; do
            _anytls_port="${ANYTLS_PORTS[$i]}"
            _anytls_tag="${ANYTLS_TAGS[$i]}"
            _anytls_name=$(_mihomoconf_make_node_name "AnyTLS" "$NODE_FLAG" "$NODE_COUNTRY_CODE")
            _separator
            printf "    [%s] 节点名: ${GREEN}%s${PLAIN}\n" "$((i + 1))" "$_anytls_name"
            printf "      入站tag: ${GREEN}%s${PLAIN}\n" "$_anytls_tag"
            printf "      服务器 : ${GREEN}%s${PLAIN}\n" "$SERVER_HOST"
            printf "      端口   : ${GREEN}%s${PLAIN}\n" "$_anytls_port"
            [[ -n "$ANYTLS_SNI" ]] && printf "      SNI    : ${GREEN}%s${PLAIN}\n" "$ANYTLS_SNI"
            _user_idx=0
            for _row in "${ANYTLS_USER_ROWS[@]}"; do
                IFS=$'\x1f' read -r _li _u_name _u_pass <<< "$_row"
                [[ "$_li" == "$i" ]] || continue
                _user_idx=$((_user_idx + 1))
                _anytls_client_name="${_anytls_name}-${_u_name}"
                ANYTLS_LINK=$(_mihomoconf_gen_anytls_link "$SERVER_HOST" "$_anytls_port" "$_u_pass" "$_anytls_client_name" "$ANYTLS_SNI")
                printf "      用户[%s]: ${GREEN}%s${PLAIN}\n" "$_user_idx" "$_u_name"
                printf "      密码   : ${GREEN}%s${PLAIN}\n" "$_u_pass"
                printf "  ${BOLD}AnyTLS 分享链接:${PLAIN}\n"
                printf "  ${GREEN}%s${PLAIN}\n" "$ANYTLS_LINK"
                printf "  ${BOLD}Clash Meta 客户端 YAML:${PLAIN}\n"
                cat <<MIHOMOCONF_AT_YAML
    proxies:
      - name: "${_anytls_client_name}"
        type: anytls
        server: ${SERVER_HOST}
        port: ${_anytls_port}
        password: "${_u_pass}"
        udp: true
        tfo: true
MIHOMOCONF_AT_YAML
                if [[ -n "$ANYTLS_SNI" ]]; then
                    echo "        sni: ${ANYTLS_SNI}"
                else
                    echo "        skip-cert-verify: true"
                fi
            done
            if [[ "$_user_idx" -eq 0 ]]; then
                _warn "  AnyTLS 入站 ${_anytls_tag} 未配置 user，已跳过导出"
            fi
        done
    fi

    # HY2 输出
    if [[ "$ENABLE_HY2" == "y" ]]; then
        printf "  ${BOLD}HY2 连接信息 (%s 个)${PLAIN}\n" "${#HY2_PORTS[@]}"
        local i HY2_LINK _hy2_port _hy2_tag _hy2_mport _hy2_obfs_password _hy2_name _hy2_client_name
        local _row _li _u_name _u_pass _user_idx
        for i in "${!HY2_PORTS[@]}"; do
            _hy2_port="${HY2_PORTS[$i]}"
            _hy2_tag="${HY2_TAGS[$i]}"
            _hy2_mport="${HY2_MPORTS[$i]}"
            _hy2_obfs_password="${HY2_OBFS_PASSWORDS[$i]}"
            _hy2_name=$(_mihomoconf_make_node_name "HY2" "$NODE_FLAG" "$NODE_COUNTRY_CODE")
            _separator
            printf "    [%s] 节点名: ${GREEN}%s${PLAIN}\n" "$((i + 1))" "$_hy2_name"
            printf "      入站tag: ${GREEN}%s${PLAIN}\n" "$_hy2_tag"
            printf "      服务器 : ${GREEN}%s${PLAIN}\n" "$SERVER_HOST"
            printf "      端口   : ${GREEN}%s${PLAIN}\n" "$_hy2_port"
            printf "      up/down: ${GREEN}%s/%s Mbps${PLAIN}\n" "$HY2_UP" "$HY2_DOWN"
            [[ -n "$HY2_SNI" ]] && printf "      SNI    : ${GREEN}%s${PLAIN}\n" "$HY2_SNI"
            [[ -n "$_hy2_mport" ]] && printf "      跳跃端口: ${GREEN}%s${PLAIN}\n" "$_hy2_mport"
            [[ "$HY2_INSECURE" == "1" ]] && printf "      insecure: ${YELLOW}开启${PLAIN}\n"
            [[ -n "$HY2_OBFS" ]] && printf "      obfs    : ${GREEN}%s${PLAIN}\n" "$HY2_OBFS"
            [[ -n "$HY2_MASQUERADE" ]] && printf "      masquerade: ${GREEN}%s${PLAIN}\n" "$HY2_MASQUERADE"
            _user_idx=0
            for _row in "${HY2_USER_ROWS[@]}"; do
                IFS=$'\x1f' read -r _li _u_name _u_pass <<< "$_row"
                [[ "$_li" == "$i" ]] || continue
                _user_idx=$((_user_idx + 1))
                _hy2_client_name="${_hy2_name}-${_u_name}"
                HY2_LINK=$(_mihomoconf_gen_hy2_link "$SERVER_HOST" "$_hy2_port" "$_u_pass" "$_hy2_client_name" "$HY2_SNI" "$HY2_INSECURE" "$HY2_OBFS" "$_hy2_obfs_password" "$_hy2_mport")
                printf "      用户[%s]: ${GREEN}%s${PLAIN}\n" "$_user_idx" "$_u_name"
                printf "      密码   : ${GREEN}%s${PLAIN}\n" "$_u_pass"
                printf "  ${BOLD}HY2 分享链接:${PLAIN}\n"
                printf "  ${GREEN}%s${PLAIN}\n" "$HY2_LINK"
                printf "  ${BOLD}HY2 JSON:${PLAIN}\n"
                cat <<MIHOMOCONF_HY2_JSON
    {
      "type": "hysteria2",
      "tag": "${_hy2_client_name}",
      "server": "${SERVER_HOST}",
      "server_port": ${_hy2_port},
      "password": "${_u_pass}",
      "sni": "${HY2_SNI}",
      "insecure": ${HY2_INSECURE},
      "up_mbps": ${HY2_UP},
      "down_mbps": ${HY2_DOWN},
      "mport": "${_hy2_mport}",
      "obfs": "${HY2_OBFS}",
      "obfs_password": "${_hy2_obfs_password}"
    }
MIHOMOCONF_HY2_JSON
            done
            if [[ "$_user_idx" -eq 0 ]]; then
                _warn "  HY2 入站 ${_hy2_tag} 未配置 user，已跳过导出"
            fi
        done
    fi

    _separator
    _info "可在 Mihomo 管理菜单中通过「读取配置并生成节点」随时生成链接/JSON"
    _info "启动命令: mihomo -d ${CONFIG_DIR}"
    if ! _mihomoconf_post_setup_service_prompt "$SSL_DIR" "$CONFIG_FILE"; then
        _warn "自动应用服务失败，可在 Mihomo 菜单手动执行「配置自启并启动」或「重启 Mihomo」"
    fi

    _press_any_key
}

# --- Mihomo 管理子菜单 ---

_mihomo_validate_config_dir() {
    local config_dir="${1:-$_MIHOMOCONF_CONFIG_DIR}"
    local output rc last_line reason_line

    if ! command -v mihomo >/dev/null 2>&1; then
        _error_no_exit "未检测到 mihomo，无法执行配置校验"
        return 1
    fi
    if [[ ! -d "$config_dir" ]]; then
        _error_no_exit "配置目录不存在: ${config_dir}"
        return 1
    fi

    output=$(mihomo -t -d "$config_dir" 2>&1)
    rc=$?
    if [[ "$rc" -eq 0 ]]; then
        return 0
    fi

    _error_no_exit "Mihomo 配置校验失败，已取消启动/重启以避免服务异常。"
    if echo "$output" | grep -qiE 'unsupport(ed)? proxy type:[[:space:]]*wireguard'; then
        _error_no_exit "当前 mihomo 不支持 proxies.type=wireguard。请删除该出站或升级 mihomo。"
    fi
    reason_line=$(printf '%s\n' "$output" | awk 'NF && $0 !~ /^configuration file .* test failed$/ {line=$0} END{print line}')
    if [[ -n "$reason_line" ]]; then
        printf "  ${DIM}%s${PLAIN}\n" "$reason_line"
    fi
    last_line=$(printf '%s\n' "$output" | tail -n1)
    if [[ -n "$last_line" && "$last_line" != "$reason_line" ]]; then
        printf "  ${DIM}%s${PLAIN}\n" "$last_line"
    fi
    return 1
}

_mihomo_supports_wireguard_proxy_outbound() {
    local tmpdir output rc last_line

    if [[ "$_MIHOMO_WG_PROXY_SUPPORT_CACHE" == "yes" ]]; then
        return 0
    fi
    if [[ "$_MIHOMO_WG_PROXY_SUPPORT_CACHE" == "no" ]]; then
        return 1
    fi
    if ! command -v mihomo >/dev/null 2>&1; then
        _MIHOMO_WG_PROXY_SUPPORT_CACHE="no"
        return 1
    fi

    tmpdir=$(mktemp -d)
    cat > "${tmpdir}/config.yaml" <<'EOF'
allow-lan: false
mode: rule
log-level: warning
ipv6: true
proxies:
  - name: "wg-probe"
    type: wireguard
    server: 1.1.1.1
    port: 51820
    ip: "10.0.0.2/32"
    private-key: "4J4kaP57uSQ90bzDoyzyFh7cZV2T6GpPwhD/c1e28GY="
    public-key: "2EdWUBPvC93MdEkTHspaWsstMQSpoJxYHb9kUSUieFc="
    allowed-ips:
      - "0.0.0.0/0"
      - "::/0"
rules:
  - MATCH,DIRECT
EOF

    output=$(mihomo -t -d "$tmpdir" 2>&1)
    rc=$?
    rm -rf "$tmpdir"

    if [[ "$rc" -eq 0 ]]; then
        _MIHOMO_WG_PROXY_SUPPORT_CACHE="yes"
        return 0
    fi

    if echo "$output" | grep -qiE 'unsupport(ed)? proxy type:[[:space:]]*wireguard'; then
        _MIHOMO_WG_PROXY_SUPPORT_CACHE="no"
        return 1
    fi

    if echo "$output" | grep -qiE "unknown shorthand flag: 't'|flag provided but not defined: -t"; then
        _warn "当前 mihomo 不支持 -t 测试参数，无法自动确认 WireGuard 出站兼容性。"
    else
        _warn "无法自动确认当前 mihomo 是否支持 WireGuard 出站。为避免服务异常，按不支持处理。"
        last_line=$(printf '%s\n' "$output" | tail -n1)
        [[ -n "$last_line" ]] && printf "  ${DIM}%s${PLAIN}\n" "$last_line"
    fi
    _MIHOMO_WG_PROXY_SUPPORT_CACHE="no"
    return 1
}

_mihomo_systemd_service_configured() {
    _has_systemd || return 1
    systemctl is-enabled mihomo.service &>/dev/null \
        || systemctl is-active mihomo.service &>/dev/null \
        || [[ -f "$_MIHOMO_SYSTEMD_SERVICE_FILE" ]]
}

_mihomo_openrc_service_configured() {
    _has_openrc || return 1
    [[ -x "$_MIHOMO_OPENRC_SERVICE_FILE" ]] || _openrc_service_in_default "mihomo"
}

_mihomo_service_is_active() {
    if _has_systemd && systemctl is-active --quiet mihomo 2>/dev/null; then
        return 0
    fi
    if _has_openrc && [[ -x "$_MIHOMO_OPENRC_SERVICE_FILE" ]] && rc-service mihomo status >/dev/null 2>&1; then
        return 0
    fi
    pgrep -x mihomo >/dev/null 2>&1
}

_mihomo_service_is_configured() {
    _mihomo_systemd_service_configured && return 0
    _mihomo_openrc_service_configured && return 0
    return 1
}

_mihomo_reload_cmd_for_acme() {
    if _has_systemd; then
        printf '%s' "systemctl restart mihomo >/dev/null 2>&1 || true"
        return
    fi
    if _has_openrc; then
        printf '%s' "rc-service mihomo restart >/dev/null 2>&1 || rc-service mihomo start >/dev/null 2>&1 || true"
        return
    fi
    printf '%s' "pkill -x mihomo >/dev/null 2>&1 || true; nohup mihomo -d /etc/mihomo >/dev/null 2>&1 &"
}

_mihomo_restart_now() {
    if ! command -v mihomo >/dev/null 2>&1; then
        _error_no_exit "未检测到 mihomo，请先安装"
        return 1
    fi

    if ! _mihomo_validate_config_dir "$_MIHOMOCONF_CONFIG_DIR"; then
        return 1
    fi

    if _mihomo_systemd_service_configured; then
        _info "通过 systemd 重启 mihomo..."
        if ! systemctl restart mihomo >/dev/null 2>&1; then
            _error_no_exit "mihomo 重启命令执行失败"
            return 1
        fi
        sleep 1
        if systemctl is-active --quiet mihomo; then
            _info "mihomo 已成功重启"
            return 0
        else
            _error_no_exit "mihomo 重启失败，请检查 systemctl status mihomo"
            return 1
        fi
    elif _mihomo_openrc_service_configured; then
        _info "通过 OpenRC 重启 mihomo..."
        if ! rc-service mihomo restart >/dev/null 2>&1; then
            if ! rc-service mihomo start >/dev/null 2>&1; then
                _error_no_exit "mihomo 重启命令执行失败"
                _warn "请检查: rc-service mihomo status"
                return 1
            fi
        fi
        sleep 1
        if _mihomo_service_is_active; then
            _info "mihomo 已成功重启"
            return 0
        fi
        _error_no_exit "mihomo 重启失败，请检查 rc-service mihomo status"
        return 1
    else
        local pid
        pid=$(pgrep -x mihomo 2>/dev/null || true)
        if [[ -n "$pid" ]]; then
            _info "终止旧进程 (PID: $pid)..."
            kill "$pid" 2>/dev/null
            sleep 1
        fi
        local config_dir="/etc/mihomo"
        if [[ ! -d "$config_dir" ]]; then
            _error_no_exit "配置目录 $config_dir 不存在，请先生成配置"
            return 1
        fi
        _info "启动 mihomo -d ${config_dir}..."
        nohup mihomo -d "$config_dir" >/dev/null 2>&1 &
        sleep 1
        if pgrep -x mihomo &>/dev/null; then
            _info "mihomo 已成功启动 (PID: $!)"
            return 0
        fi
        _error_no_exit "mihomo 启动失败"
        return 1
    fi
}

_mihomo_restart() {
    _header "Mihomo 重启"

    _mihomo_restart_now

    _press_any_key
}

_mihomo_enable_now() {
    local force_rewrite="${1:-0}"

    if ! command -v mihomo >/dev/null 2>&1; then
        _error_no_exit "未检测到 mihomo，请先安装"
        return 1
    fi

    local systemd_service_file="$_MIHOMO_SYSTEMD_SERVICE_FILE"
    local openrc_service_file="$_MIHOMO_OPENRC_SERVICE_FILE"
    local config_dir="/etc/mihomo"
    local mihomo_bin
    mihomo_bin=$(command -v mihomo)

    if [[ ! -d "$config_dir" ]]; then
        _error_no_exit "配置目录 $config_dir 不存在，请先生成配置"
        return 1
    fi
    if ! _mihomo_validate_config_dir "$config_dir"; then
        return 1
    fi

    if _has_systemd; then
        if [[ "$force_rewrite" == "1" || ! -f "$systemd_service_file" ]]; then
            _info "生成 systemd 服务文件..."
            cat > "$systemd_service_file" <<SERVICEEOF
[Unit]
Description=Mihomo Proxy Service
After=network.target

[Service]
Type=simple
ExecStart=${mihomo_bin} -d ${config_dir}
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SERVICEEOF
        fi

        systemctl daemon-reload >/dev/null 2>&1 || true
        if ! systemctl enable mihomo >/dev/null 2>&1; then
            _error_no_exit "设置开机自启失败，请检查 systemctl 状态"
            return 1
        fi
        _info "已设置开机自启"

        if ! systemctl restart mihomo >/dev/null 2>&1; then
            _error_no_exit "mihomo 启动失败，请检查: systemctl status mihomo"
            return 1
        fi
        sleep 1
        if systemctl is-active --quiet mihomo; then
            _info "mihomo 已成功启动"
            return 0
        fi
        _error_no_exit "mihomo 启动失败，请检查: systemctl status mihomo"
        return 1
    fi

    if _has_openrc; then
        if [[ "$force_rewrite" == "1" || ! -f "$openrc_service_file" ]]; then
            _info "生成 OpenRC 服务文件..."
            cat > "$openrc_service_file" <<SERVICEEOF
#!/sbin/openrc-run
name="Mihomo"
description="Mihomo Proxy Service"

command="${mihomo_bin}"
command_args="-d ${config_dir}"
command_background=true
pidfile="/run/mihomo.pid"
output_log="${_MIHOMO_OPENRC_LOG_FILE}"
error_log="${_MIHOMO_OPENRC_ERR_FILE}"

depend() {
    need net
}
SERVICEEOF
            chmod 0755 "$openrc_service_file" || {
                _error_no_exit "写入 OpenRC 服务文件失败: ${openrc_service_file}"
                return 1
            }
        fi

        if ! rc-update add mihomo default >/dev/null 2>&1; then
            if ! _openrc_service_in_default "mihomo"; then
                _error_no_exit "设置开机自启失败，请检查 rc-update 状态"
                return 1
            fi
        fi
        _info "已设置开机自启 (OpenRC)"

        if ! rc-service mihomo restart >/dev/null 2>&1; then
            if ! rc-service mihomo start >/dev/null 2>&1; then
                _error_no_exit "mihomo 启动失败，请检查: rc-service mihomo status"
                return 1
            fi
        fi
        sleep 1
        if _mihomo_service_is_active; then
            _info "mihomo 已成功启动"
            return 0
        fi
        _error_no_exit "mihomo 启动失败，请检查: rc-service mihomo status"
        return 1
    fi

    _warn "当前系统未检测到 systemd/OpenRC，无法配置开机自启，仅尝试立即启动"
    _mihomo_restart_now && return 0
    _error_no_exit "mihomo 启动失败"
    return 1
}

_mihomoconf_post_setup_service_prompt() {
    local ssl_dir="$1"
    local config_file="${2:-$_MIHOMOCONF_CONFIG_FILE}"
    local cert_file="${ssl_dir}/cert.crt"
    local key_file="${ssl_dir}/cert.key"
    local tls_required="0"
    local answer

    echo ""
    _separator
    _info "提示: 配置已生成，可立即应用到 mihomo 服务"

    if [[ -f "$config_file" ]] && grep -Eq '^[[:space:]]*type:[[:space:]]*(anytls|hysteria2)[[:space:]]*$' "$config_file"; then
        tls_required="1"
    fi

    if [[ "$tls_required" == "1" ]]; then
        if [[ ! -f "$cert_file" || ! -f "$key_file" ]]; then
            _warn "检测到 AnyTLS/HY2 配置但 SSL 证书不完整，跳过自动启动提示"
            return 0
        fi
        _info "检测到 SSL 证书: ${ssl_dir}"
    else
        _info "当前配置未启用 AnyTLS/HY2，跳过 SSL 证书检查"
    fi

    if _mihomo_service_is_active; then
        read -rp "  检测到 mihomo 已启动，是否立即重启应用新配置? [Y/n]: " answer
        if [[ "$answer" =~ ^([Nn]|[Nn][Oo])$ ]]; then
            _info "已跳过重启"
            return 0
        fi
        _mihomo_restart_now
        return $?
    fi

    if _mihomo_service_is_configured; then
        read -rp "  检测到 mihomo 服务已配置，是否立即启动? [Y/n]: " answer
        if [[ "$answer" =~ ^([Nn]|[Nn][Oo])$ ]]; then
            _info "已跳过启动"
            return 0
        fi
        _mihomo_restart_now
        return $?
    fi

    if [[ "$tls_required" == "1" ]]; then
        read -rp "  检测到 SSL 证书，是否配置自启并启动 mihomo? [Y/n]: " answer
    else
        read -rp "  是否配置自启并启动 mihomo? [Y/n]: " answer
    fi
    if [[ "$answer" =~ ^([Nn]|[Nn][Oo])$ ]]; then
        _info "已跳过自启动配置"
        return 0
    fi
    _mihomo_enable_now "1"
    return $?
}

_mihomo_enable() {
    _header "Mihomo 自启动配置"

    local service_file=""
    local service_name=""
    local force_rewrite="0"

    if _has_systemd; then
        service_file="$_MIHOMO_SYSTEMD_SERVICE_FILE"
        service_name="systemd"
    elif _has_openrc; then
        service_file="$_MIHOMO_OPENRC_SERVICE_FILE"
        service_name="OpenRC"
    fi

    if [[ -n "$service_file" && -f "$service_file" ]]; then
        _warn "${service_name} 服务文件已存在"
        local overwrite
        read -rp "  是否覆盖? [y/N]: " overwrite
        if [[ ! "$overwrite" =~ ^[Yy] ]]; then
            _press_any_key
            return
        fi
        force_rewrite="1"
    fi

    _mihomo_enable_now "$force_rewrite"

    _press_any_key
}

_mihomo_uninstall() {
    _header "Mihomo 卸载"

    local systemd_service_file="$_MIHOMO_SYSTEMD_SERVICE_FILE"
    local openrc_service_file="$_MIHOMO_OPENRC_SERVICE_FILE"
    local config_dir="$_MIHOMOCONF_CONFIG_DIR"
    local bin_path remove_config confirm p
    local removed_count=0
    local -a bin_candidates=()

    bin_path=$(command -v mihomo 2>/dev/null || true)

    _warn "将停止并卸载 Mihomo，可选删除配置目录。"
    printf "    systemd 服务文件: %s\n" "$systemd_service_file"
    printf "    OpenRC 服务文件 : %s\n" "$openrc_service_file"
    if [[ -n "$bin_path" ]]; then
        printf "    可执行文件: %s\n" "$bin_path"
    else
        printf "    可执行文件: %s\n" "/usr/local/bin/mihomo"
    fi
    printf "    配置目录: %s\n" "$config_dir"
    read -rp "  确认卸载 Mihomo? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy] ]]; then
        _info "已取消"
        _press_any_key
        return
    fi

    if _has_systemd; then
        if systemctl is-active --quiet mihomo 2>/dev/null || systemctl is-enabled mihomo.service &>/dev/null || [[ -f "$systemd_service_file" ]]; then
            systemctl stop mihomo >/dev/null 2>&1 || true
            systemctl disable mihomo >/dev/null 2>&1 || true
            _info "已停止并禁用 systemd 的 mihomo 服务"
        fi
    fi

    if _has_openrc; then
        if [[ -x "$openrc_service_file" ]] || _openrc_service_in_default "mihomo"; then
            rc-service mihomo stop >/dev/null 2>&1 || true
            rc-update del mihomo default >/dev/null 2>&1 || true
            _info "已停止并移除 OpenRC 的 mihomo 自启动"
        fi
    fi

    if pgrep -x mihomo >/dev/null 2>&1; then
        pkill -x mihomo >/dev/null 2>&1 || true
        sleep 1
    fi

    if [[ -f "$systemd_service_file" ]]; then
        rm -f "$systemd_service_file"
        removed_count=$((removed_count + 1))
        _info "已删除服务文件: $systemd_service_file"
    fi
    if [[ -f "$openrc_service_file" ]]; then
        rm -f "$openrc_service_file"
        removed_count=$((removed_count + 1))
        _info "已删除服务文件: $openrc_service_file"
    fi
    if _has_systemd; then
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl reset-failed mihomo >/dev/null 2>&1 || true
    fi

    [[ -n "$bin_path" ]] && bin_candidates+=("$bin_path")
    [[ "/usr/local/bin/mihomo" != "$bin_path" ]] && bin_candidates+=("/usr/local/bin/mihomo")
    [[ "/usr/bin/mihomo" != "$bin_path" ]] && bin_candidates+=("/usr/bin/mihomo")
    for p in "${bin_candidates[@]}"; do
        [[ -z "${p:-}" ]] && continue
        if [[ -f "$p" || -L "$p" ]]; then
            rm -f "$p"
            removed_count=$((removed_count + 1))
            _info "已删除可执行文件: $p"
        fi
    done

    if [[ -d "$config_dir" ]]; then
        read -rp "  是否同时删除配置目录 ${config_dir}? [y/N]: " remove_config
        if [[ "$remove_config" =~ ^[Yy] ]]; then
            rm -rf "$config_dir"
            removed_count=$((removed_count + 1))
            _info "已删除配置目录: $config_dir"
        else
            _info "已保留配置目录: $config_dir"
        fi
    fi

    if (( removed_count == 0 )); then
        _warn "未检测到可删除的 Mihomo 文件，已完成服务清理。"
    else
        _success "Mihomo 卸载完成"
    fi
    _press_any_key
}

_mihomo_log() {
    _header "Mihomo 日志"

    if ! command -v mihomo >/dev/null 2>&1; then
        _error_no_exit "未检测到 mihomo，请先安装"
        _press_any_key
        return
    fi

    echo ""
    if _mihomo_systemd_service_configured; then
        _info "显示最近 50 行日志 (Ctrl+C 退出实时跟踪)"
        _separator
        echo ""
        journalctl -u mihomo --no-pager -n 50
        echo ""
        _separator
        local follow
        read -rp "  是否实时跟踪日志? [y/N]: " follow
        if [[ "$follow" =~ ^[Yy] ]]; then
            echo ""
            _info "按 Ctrl+C 退出实时日志..."
            echo ""
            journalctl -u mihomo -f
        fi
    elif _mihomo_openrc_service_configured; then
        _tail_log_files_interactive "mihomo" "$_MIHOMO_OPENRC_LOG_FILE" "$_MIHOMO_OPENRC_ERR_FILE" "rc-service mihomo status" || true
    else
        _warn "mihomo 未配置为 systemd/OpenRC 服务，暂无统一日志入口"
        _info "提示: 可通过选项3「配置自启并启动」完成服务化管理"
    fi

    _press_any_key
}

_mihomo_read_config() {
    _header "Mihomo 节点导出"

    local config_file="$_MIHOMOCONF_CONFIG_FILE"
    local server_ip
    local saved_host
    local total_count=0
    local export_count=0
    local listener_total=0 listener_export=0 proxy_total=0 proxy_export=0
    local type name port cipher password user_id user_pass sni listener_tag
    local hy2_up hy2_down hy2_ignore hy2_obfs hy2_obfs_password hy2_masquerade hy2_mport hy2_insecure
    local p_name p_type p_server p_port p_cipher p_user p_pass p_sni p_insecure p_obfs p_obfs_password p_mport
    local p_wg_ip p_wg_ipv6 p_wg_private_key p_wg_public_key p_wg_allowed_ips p_wg_preshared_key p_wg_reserved p_wg_mtu p_wg_keepalive
    local SS_EXPORT_UDP="1" SS_EXPORT_UOT="0" SS_EXPORT_ASKED="0"
    local SS_EXPORT_UDP_BOOL="true" SS_EXPORT_UOT_BOOL="false"
    local NODE_COUNTRY="" NODE_CITY="" NODE_COUNTRY_CODE="UN" NODE_FLAG="🏳"
    local GEO_LOOKUP_IP=""

    if [[ ! -f "$config_file" ]]; then
        _error_no_exit "未找到配置文件: ${config_file}"
        _info "请先通过选项2「生成配置」创建配置文件"
        _press_any_key
        return
    fi

    if [[ ! -r "$config_file" ]]; then
        _error_no_exit "配置文件不可读: ${config_file}"
        _press_any_key
        return
    fi

    _info "配置文件: ${config_file}"
    _info "支持导出 listeners(AnyTLS / SS2022 / HY2) 与 proxies(WireGuard Beta)"
    saved_host=$(_mihomoconf_get_saved_host "$config_file")
    if [[ -n "$saved_host" ]]; then
        server_ip="$saved_host"
        _info "导出 Host(配置中): ${server_ip}"
    else
        server_ip=$(_mihomoconf_get_server_ip)
        _info "导出 Host(公网IP): ${server_ip}"
    fi
    GEO_LOOKUP_IP="$server_ip"
    if [[ ! "$GEO_LOOKUP_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        GEO_LOOKUP_IP=$(_mihomoconf_get_server_ip)
    fi
    IFS=$'\x1f' read -r NODE_COUNTRY NODE_CITY NODE_COUNTRY_CODE NODE_FLAG < <(_mihomoconf_get_geo_profile "$GEO_LOOKUP_IP")
    if [[ -n "$NODE_CITY" ]]; then
        _info "地区识别: ${NODE_COUNTRY} ${NODE_CITY} (${NODE_FLAG}${NODE_COUNTRY_CODE})"
    else
        _info "地区识别: ${NODE_COUNTRY} (${NODE_FLAG}${NODE_COUNTRY_CODE})"
    fi

    while IFS=$'\x1f' read -r type name port cipher password user_id user_pass sni \
        hy2_up hy2_down hy2_ignore hy2_obfs hy2_obfs_password hy2_masquerade hy2_mport hy2_insecure listener_tag; do
        [[ -z "${name:-}" ]] && continue
        total_count=$((total_count + 1))
        listener_total=$((listener_total + 1))
        listener_tag="${listener_tag:-$name}"

        case "$type" in
            shadowsocks)
                if [[ "$cipher" != 2022-* ]]; then
                    _warn "跳过 ${name}: 非 SS2022 节点 (cipher=${cipher})"
                    continue
                fi
                if [[ -z "$port" ]]; then
                    _warn "跳过 ${name}: 节点字段不完整"
                    continue
                fi
                if [[ "$SS_EXPORT_ASKED" != "1" ]]; then
                    local ss_export_udp_answer ss_export_uot_answer
                    read -rp "  SS 导出: 是否开启 UDP? [Y/n]: " ss_export_udp_answer < /dev/tty
                    if [[ "$ss_export_udp_answer" =~ ^([Nn]|[Nn][Oo])$ ]]; then
                        SS_EXPORT_UDP="0"
                        SS_EXPORT_UOT="0"
                        _info "已关闭 SS 导出的 UDP 与 UDP over TCP v2"
                    else
                        read -rp "  SS 导出: 是否开启 UDP over TCP v2? [y/N]: " ss_export_uot_answer < /dev/tty
                        if [[ "$ss_export_uot_answer" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]; then
                            SS_EXPORT_UOT="1"
                        else
                            SS_EXPORT_UOT="0"
                        fi
                    fi
                    [[ "$SS_EXPORT_UDP" == "1" ]] && SS_EXPORT_UDP_BOOL="true" || SS_EXPORT_UDP_BOOL="false"
                    [[ "$SS_EXPORT_UOT" == "1" ]] && SS_EXPORT_UOT_BOOL="true" || SS_EXPORT_UOT_BOOL="false"
                    SS_EXPORT_ASKED="1"
                fi
                local ss_found=0 ss_link ss_name ss_user ss_pass ss_client_pass
                while IFS=$'\x1f' read -r ss_user ss_pass; do
                    [[ -z "${ss_user:-}" || -z "${ss_pass:-}" ]] && continue
                    ss_found=1
                    ss_client_pass="$ss_pass"
                    if [[ "$cipher" == *"2022"* ]]; then
                        ss_client_pass="${password}:${ss_pass}"
                    fi
                    export_count=$((export_count + 1))
                    listener_export=$((listener_export + 1))
                    ss_name="$(_mihomoconf_make_node_name "SS" "$NODE_FLAG" "$NODE_COUNTRY_CODE")-${ss_user}"
                    ss_link=$(_mihomoconf_gen_ss_link "$server_ip" "$port" "$cipher" "$ss_client_pass" "$ss_name" "$SS_EXPORT_UDP" "$SS_EXPORT_UOT")
                    _separator
                    printf "  ${BOLD}[SS2022] %s${PLAIN}\n" "$ss_name"
                    printf "    入站tag: ${GREEN}%s${PLAIN}\n" "$listener_tag"
                    printf "    用户: ${GREEN}%s${PLAIN}\n" "$ss_user"
                    printf "    链接: ${GREEN}%s${PLAIN}\n" "$ss_link"
                    printf "    JSON:\n"
                    cat <<MIHOMO_SS2022_JSON
    {
      "type": "shadowsocks",
      "tag": "${ss_name}",
      "server": "${server_ip}",
      "server_port": ${port},
      "method": "${cipher}",
      "password": "${ss_client_pass}",
      "udp": ${SS_EXPORT_UDP_BOOL},
      "udp_over_tcp": { "enabled": ${SS_EXPORT_UOT_BOOL}, "version": 2 }
    }
MIHOMO_SS2022_JSON
                done < <(_mihomoconf_read_users_by_tag "$config_file" "$listener_tag")
                if [[ "$ss_found" -eq 0 ]]; then
                    # 兼容历史单密码配置
                    if [[ -z "$password" ]]; then
                        _warn "跳过 ${name}: 未配置可用 user/密码"
                        continue
                    fi
                    export_count=$((export_count + 1))
                    listener_export=$((listener_export + 1))
                    ss_name=$(_mihomoconf_make_node_name "SS" "$NODE_FLAG" "$NODE_COUNTRY_CODE")
                    ss_link=$(_mihomoconf_gen_ss_link "$server_ip" "$port" "$cipher" "$password" "$ss_name" "$SS_EXPORT_UDP" "$SS_EXPORT_UOT")
                    _separator
                    printf "  ${BOLD}[SS2022] %s${PLAIN}\n" "$ss_name"
                    printf "    入站tag: ${GREEN}%s${PLAIN}\n" "$listener_tag"
                    printf "    链接: ${GREEN}%s${PLAIN}\n" "$ss_link"
                    printf "    JSON:\n"
                    cat <<MIHOMO_SS2022_JSON
    {
      "type": "shadowsocks",
      "tag": "${ss_name}",
      "server": "${server_ip}",
      "server_port": ${port},
      "method": "${cipher}",
      "password": "${password}",
      "udp": ${SS_EXPORT_UDP_BOOL},
      "udp_over_tcp": { "enabled": ${SS_EXPORT_UOT_BOOL}, "version": 2 }
    }
MIHOMO_SS2022_JSON
                    _warn "提示: 该 SS2022 入站为旧 password 模式，建议迁移到 users 模式"
                fi
                ;;
            anytls)
                if [[ -z "$port" ]]; then
                    _warn "跳过 ${name}: 节点字段不完整"
                    continue
                fi
                local anytls_found=0 anytls_link anytls_name anytls_user anytls_pass
                while IFS=$'\x1f' read -r anytls_user anytls_pass; do
                    [[ -z "${anytls_user:-}" || -z "${anytls_pass:-}" ]] && continue
                    anytls_found=1
                    export_count=$((export_count + 1))
                    listener_export=$((listener_export + 1))
                    anytls_name="$(_mihomoconf_make_node_name "AnyTLS" "$NODE_FLAG" "$NODE_COUNTRY_CODE")-${anytls_user}"
                    anytls_link=$(_mihomoconf_gen_anytls_link "$server_ip" "$port" "$anytls_pass" "$anytls_name" "$sni")
                    _separator
                    printf "  ${BOLD}[AnyTLS] %s${PLAIN}\n" "$anytls_name"
                    printf "    入站tag: ${GREEN}%s${PLAIN}\n" "$listener_tag"
                    printf "    用户: ${GREEN}%s${PLAIN}\n" "$anytls_user"
                    printf "    链接: ${GREEN}%s${PLAIN}\n" "$anytls_link"
                    [[ -n "$sni" ]] && printf "    SNI: ${GREEN}%s${PLAIN}\n" "$sni"
                    printf "    JSON:\n"
                    cat <<MIHOMO_ANYTLS_JSON
    {
      "type": "anytls",
      "tag": "${anytls_name}",
      "server": "${server_ip}",
      "server_port": ${port},
      "password": "${anytls_pass}",
      "sni": "${sni}",
      "udp": true,
      "tfo": true
    }
MIHOMO_ANYTLS_JSON
                done < <(_mihomoconf_read_users_by_tag "$config_file" "$listener_tag")
                if [[ "$anytls_found" -eq 0 ]]; then
                    _warn "跳过 ${name}: 未配置可用 user"
                fi
                ;;
            hysteria2)
                if [[ -z "$port" ]]; then
                    _warn "跳过 ${name}: 节点字段不完整"
                    continue
                fi
                local hy2_found=0 hy2_link hy2_name hy2_user hy2_pass
                while IFS=$'\x1f' read -r hy2_user hy2_pass; do
                    [[ -z "${hy2_user:-}" || -z "${hy2_pass:-}" ]] && continue
                    hy2_found=1
                    export_count=$((export_count + 1))
                    listener_export=$((listener_export + 1))
                    hy2_name="$(_mihomoconf_make_node_name "HY2" "$NODE_FLAG" "$NODE_COUNTRY_CODE")-${hy2_user}"
                    hy2_link=$(_mihomoconf_gen_hy2_link "$server_ip" "$port" "$hy2_pass" "$hy2_name" "$sni" "${hy2_insecure:-0}" "$hy2_obfs" "$hy2_obfs_password" "$hy2_mport")
                    _separator
                    printf "  ${BOLD}[HY2] %s${PLAIN}\n" "$hy2_name"
                    printf "    入站tag: ${GREEN}%s${PLAIN}\n" "$listener_tag"
                    printf "    用户: ${GREEN}%s${PLAIN}\n" "$hy2_user"
                    printf "    链接: ${GREEN}%s${PLAIN}\n" "$hy2_link"
                    [[ -n "$sni" ]] && printf "    SNI: ${GREEN}%s${PLAIN}\n" "$sni"
                    [[ -n "$hy2_mport" ]] && printf "    端口跳跃: ${GREEN}%s${PLAIN}\n" "$hy2_mport"
                    [[ -n "$hy2_up" || -n "$hy2_down" ]] && printf "    up/down: ${GREEN}%s/%s Mbps${PLAIN}\n" "${hy2_up:-1000}" "${hy2_down:-1000}"
                    [[ -n "$hy2_obfs" ]] && printf "    obfs: ${GREEN}%s${PLAIN}\n" "$hy2_obfs"
                    [[ -n "$hy2_masquerade" ]] && printf "    masquerade: ${GREEN}%s${PLAIN}\n" "$hy2_masquerade"
                    printf "    JSON:\n"
                    cat <<MIHOMO_HY2_JSON
    {
      "type": "hysteria2",
      "tag": "${hy2_name}",
      "server": "${server_ip}",
      "server_port": ${port},
      "password": "${hy2_pass}",
      "sni": "${sni}",
      "insecure": ${hy2_insecure:-0},
      "up_mbps": ${hy2_up:-1000},
      "down_mbps": ${hy2_down:-1000},
      "mport": "${hy2_mport}",
      "obfs": "${hy2_obfs}",
      "obfs_password": "${hy2_obfs_password}"
    }
MIHOMO_HY2_JSON
                done < <(_mihomoconf_read_users_by_tag "$config_file" "$listener_tag")
                if [[ "$hy2_found" -eq 0 ]]; then
                    _warn "跳过 ${name}: 未配置可用 user"
                fi
                ;;
            *)
                _warn "跳过 ${name}: 暂不支持类型 ${type}"
                ;;
        esac
    done < <(_mihomoconf_read_listener_rows "$config_file")

    while IFS=$'\x1f' read -r p_name p_type p_server p_port p_cipher p_user p_pass p_sni p_insecure p_obfs p_obfs_password p_mport \
        p_wg_ip p_wg_ipv6 p_wg_private_key p_wg_public_key p_wg_allowed_ips p_wg_preshared_key p_wg_reserved p_wg_mtu p_wg_keepalive; do
        [[ -z "${p_name:-}" ]] && continue
        proxy_total=$((proxy_total + 1))
        total_count=$((total_count + 1))
        case "$p_type" in
            wireguard|wg)
                if [[ -z "$p_server" || -z "$p_port" || -z "$p_wg_ip" || -z "$p_wg_private_key" || -z "$p_wg_public_key" ]]; then
                    _warn "跳过 ${p_name}: wireguard(Beta) 字段不完整(server/port/ip/private-key/public-key)"
                    continue
                fi
                proxy_export=$((proxy_export + 1))
                export_count=$((export_count + 1))
                local wg_allowed_yaml
                wg_allowed_yaml=$(_mihomochain_yaml_list_from_csv "${p_wg_allowed_ips:-0.0.0.0/0,::/0}")
                _separator
                printf "  ${BOLD}[WireGuard Beta] %s${PLAIN}\n" "$p_name"
                printf "    出站名: ${GREEN}%s${PLAIN}\n" "$p_name"
                printf "    地址  : ${GREEN}%s:%s${PLAIN}\n" "$p_server" "$p_port"
                printf "    IP    : ${GREEN}%s${PLAIN}\n" "$p_wg_ip"
                [[ -n "$p_wg_ipv6" ]] && printf "    IPv6  : ${GREEN}%s${PLAIN}\n" "$p_wg_ipv6"
                printf "    YAML:\n"
                cat <<MIHOMO_WG_YAML
    proxies:
      - name: "${p_name}"
        type: wireguard
        server: "${p_server}"
        port: ${p_port}
        ip: "${p_wg_ip}"
MIHOMO_WG_YAML
                if [[ -n "$p_wg_ipv6" ]]; then
                    printf '        ipv6: "%s"\n' "$p_wg_ipv6"
                fi
                cat <<MIHOMO_WG_YAML2
        private-key: "${p_wg_private_key}"
        public-key: "${p_wg_public_key}"
        allowed-ips: ${wg_allowed_yaml}
        udp: true
MIHOMO_WG_YAML2
                if [[ -n "$p_wg_preshared_key" ]]; then
                    printf '        pre-shared-key: "%s"\n' "$p_wg_preshared_key"
                fi
                if [[ -n "$p_wg_reserved" ]]; then
                    if [[ "$p_wg_reserved" == \[*\] ]]; then
                        printf '        reserved: %s\n' "$p_wg_reserved"
                    else
                        printf '        reserved: "%s"\n' "$p_wg_reserved"
                    fi
                fi
                if [[ -n "$p_wg_mtu" ]]; then
                    printf '        mtu: %s\n' "$p_wg_mtu"
                fi
                if [[ -n "$p_wg_keepalive" ]]; then
                    printf '        persistent-keepalive: %s\n' "$p_wg_keepalive"
                fi
                ;;
        esac
    done < <(_mihomochain_read_proxy_rows "$config_file")

    _separator
    if [[ "$total_count" -eq 0 ]]; then
        _warn "未在配置中检测到可读节点 (listeners/proxies)"
    elif [[ "$export_count" -eq 0 ]]; then
        _warn "共读取 ${total_count} 个节点，但没有可导出的 AnyTLS/SS2022/HY2/WireGuard(Beta) 节点"
    else
        _info "listeners: 读取 ${listener_total}，导出 ${listener_export}"
        _info "proxies: 读取 ${proxy_total}，导出 ${proxy_export} (WireGuard Beta)"
        _info "总计: 读取 ${total_count}，导出 ${export_count}"
    fi

    _press_any_key
}

_mihomochain_db_ensure() {
    :
}

_mihomochain_is_valid_tag() {
    [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]
}

_mihomochain_yaml_quote() {
    local s="${1:-}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

_mihomochain_yaml_list_from_csv() {
    local raw="${1:-}" token
    local -a parts=() quoted=()

    raw=$(_mihomoconf_trim "$raw")
    if [[ "$raw" == \[*\] ]]; then
        printf '%s' "$raw"
        return 0
    fi

    raw="${raw//;/,}"
    raw="${raw// /,}"
    IFS=',' read -r -a parts <<< "$raw"
    for token in "${parts[@]}"; do
        token=$(_mihomoconf_trim "$token")
        [[ -z "$token" ]] && continue
        token="${token#\"}"
        token="${token%\"}"
        token="${token#\'}"
        token="${token%\'}"
        token="${token//\\/\\\\}"
        token="${token//\"/\\\"}"
        quoted+=("\"${token}\"")
    done

    if (( ${#quoted[@]} == 0 )); then
        printf '["0.0.0.0/0","::/0"]'
        return 0
    fi

    local out="[" i
    for i in "${!quoted[@]}"; do
        [[ "$i" -gt 0 ]] && out+=", "
        out+="${quoted[$i]}"
    done
    out+="]"
    printf '%s' "$out"
}

_mihomochain_read_proxy_rows() {
    local config_file="${1:-$_MIHOMOCONF_CONFIG_FILE}"
    [[ -f "$config_file" ]] || return 1
    awk '
        function trim(s) {
            sub(/^[[:space:]]+/, "", s)
            sub(/[[:space:]]+$/, "", s)
            return s
        }
        function unquote(s) {
            gsub(/^"/, "", s)
            gsub(/"$/, "", s)
            return s
        }
        function reset_item() {
            name=type=server=port=cipher=username=password=sni=insecure=obfs=obfs_password=mport=""
            wg_ip=wg_ipv6=wg_private_key=wg_public_key=wg_allowed_ips=wg_preshared_key=wg_reserved=wg_mtu=wg_keepalive=""
        }
        function emit() {
            if (name == "") return
            if (insecure == "") insecure="0"
            printf "%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\n", \
                name, type, server, port, cipher, username, password, sni, insecure, obfs, obfs_password, mport, \
                wg_ip, wg_ipv6, wg_private_key, wg_public_key, wg_allowed_ips, wg_preshared_key, wg_reserved, wg_mtu, wg_keepalive
        }
        BEGIN {
            in_proxies=0
            reset_item()
        }
        /^[^[:space:]#][^:]*:[[:space:]]*.*$/ {
            if (in_proxies) emit()
            in_proxies = ($0 ~ /^proxies:[[:space:]]*$/)
            if (!in_proxies) reset_item()
            next
        }
        !in_proxies { next }
        /^  - name:/ {
            emit()
            reset_item()
            line=$0
            sub(/^  - name:[[:space:]]*/, "", line)
            name=unquote(trim(line))
            next
        }
        /^    type:/ {
            line=$0
            sub(/^    type:[[:space:]]*/, "", line)
            type=trim(line)
            next
        }
        /^    server:/ {
            line=$0
            sub(/^    server:[[:space:]]*/, "", line)
            server=unquote(trim(line))
            next
        }
        /^    port:/ {
            line=$0
            sub(/^    port:[[:space:]]*/, "", line)
            port=trim(line)
            next
        }
        /^    cipher:/ {
            line=$0
            sub(/^    cipher:[[:space:]]*/, "", line)
            cipher=trim(line)
            next
        }
        /^    username:/ {
            line=$0
            sub(/^    username:[[:space:]]*/, "", line)
            username=unquote(trim(line))
            next
        }
        /^    password:/ {
            line=$0
            sub(/^    password:[[:space:]]*/, "", line)
            password=unquote(trim(line))
            next
        }
        /^    sni:/ {
            line=$0
            sub(/^    sni:[[:space:]]*/, "", line)
            sni=unquote(trim(line))
            next
        }
        /^    servername:/ {
            line=$0
            sub(/^    servername:[[:space:]]*/, "", line)
            if (sni == "") sni=unquote(trim(line))
            next
        }
        /^    skip-cert-verify:/ {
            line=$0
            sub(/^    skip-cert-verify:[[:space:]]*/, "", line)
            line=trim(line)
            if (line == "true" || line == "1") insecure="1"
            else insecure="0"
            next
        }
        /^    obfs:/ {
            line=$0
            sub(/^    obfs:[[:space:]]*/, "", line)
            obfs=unquote(trim(line))
            next
        }
        /^    obfs-password:/ {
            line=$0
            sub(/^    obfs-password:[[:space:]]*/, "", line)
            obfs_password=unquote(trim(line))
            next
        }
        /^    mport:/ {
            line=$0
            sub(/^    mport:[[:space:]]*/, "", line)
            mport=unquote(trim(line))
            next
        }
        /^    ip:/ {
            line=$0
            sub(/^    ip:[[:space:]]*/, "", line)
            wg_ip=unquote(trim(line))
            next
        }
        /^    ipv6:/ {
            line=$0
            sub(/^    ipv6:[[:space:]]*/, "", line)
            wg_ipv6=unquote(trim(line))
            next
        }
        /^    private-key:/ {
            line=$0
            sub(/^    private-key:[[:space:]]*/, "", line)
            wg_private_key=unquote(trim(line))
            next
        }
        /^    public-key:/ {
            line=$0
            sub(/^    public-key:[[:space:]]*/, "", line)
            wg_public_key=unquote(trim(line))
            next
        }
        /^    allowed-ips:/ {
            line=$0
            sub(/^    allowed-ips:[[:space:]]*/, "", line)
            wg_allowed_ips=trim(line)
            next
        }
        /^    pre-shared-key:/ {
            line=$0
            sub(/^    pre-shared-key:[[:space:]]*/, "", line)
            wg_preshared_key=unquote(trim(line))
            next
        }
        /^    reserved:/ {
            line=$0
            sub(/^    reserved:[[:space:]]*/, "", line)
            wg_reserved=trim(line)
            next
        }
        /^    mtu:/ {
            line=$0
            sub(/^    mtu:[[:space:]]*/, "", line)
            wg_mtu=trim(line)
            next
        }
        /^    persistent-keepalive:/ {
            line=$0
            sub(/^    persistent-keepalive:[[:space:]]*/, "", line)
            wg_keepalive=trim(line)
            next
        }
        END {
            if (in_proxies) emit()
        }
    ' "$config_file"
}

_mihomochain_outbound_exists() {
    local tag="$1"
    local name type server port cipher username password sni insecure obfs obfs_password mport
    local wg_ip wg_ipv6 wg_private_key wg_public_key wg_allowed_ips wg_preshared_key wg_reserved wg_mtu wg_keepalive
    while IFS=$'\x1f' read -r name type server port cipher username password sni insecure obfs obfs_password mport \
        wg_ip wg_ipv6 wg_private_key wg_public_key wg_allowed_ips wg_preshared_key wg_reserved wg_mtu wg_keepalive; do
        [[ "$name" == "$tag" ]] && return 0
    done < <(_mihomochain_read_proxy_rows)
    return 1
}

_mihomochain_gen_outbound_tag() {
    local tag
    while true; do
        tag="out_$(_mihomoconf_gen_uuid | cut -d'-' -f1)"
        if ! _mihomochain_outbound_exists "$tag"; then
            printf '%s' "$tag"
            return 0
        fi
    done
}

_mihomochain_outbound_name_by_tag() {
    local tag="$1"
    local name type server port cipher username password sni insecure obfs obfs_password mport
    local wg_ip wg_ipv6 wg_private_key wg_public_key wg_allowed_ips wg_preshared_key wg_reserved wg_mtu wg_keepalive
    while IFS=$'\x1f' read -r name type server port cipher username password sni insecure obfs obfs_password mport \
        wg_ip wg_ipv6 wg_private_key wg_public_key wg_allowed_ips wg_preshared_key wg_reserved wg_mtu wg_keepalive; do
        if [[ "$name" == "$tag" ]]; then
            printf '%s' "$name"
            return 0
        fi
    done < <(_mihomochain_read_proxy_rows)
    printf '%s' "$tag"
    return 1
}

_mihomochain_outbound_tag_by_name() {
    local name="$1"
    local n type server port cipher username password sni insecure obfs obfs_password mport
    local wg_ip wg_ipv6 wg_private_key wg_public_key wg_allowed_ips wg_preshared_key wg_reserved wg_mtu wg_keepalive
    while IFS=$'\x1f' read -r n type server port cipher username password sni insecure obfs obfs_password mport \
        wg_ip wg_ipv6 wg_private_key wg_public_key wg_allowed_ips wg_preshared_key wg_reserved wg_mtu wg_keepalive; do
        if [[ "$n" == "$name" ]]; then
            printf '%s' "$n"
            return 0
        fi
    done < <(_mihomochain_read_proxy_rows)
    return 1
}

_mihomochain_display_name() {
    local raw="${1:-}" show frag
    show="$raw"
    if [[ "$raw" == *"://"* ]]; then
        frag="${raw##*#}"
        if [[ -n "$frag" && "$frag" != "$raw" ]]; then
            show=$(_mihomochain_urldecode "$frag")
        fi
    fi
    if [[ ${#show} -gt 56 ]]; then
        show="${show:0:24}...${show: -20}"
    fi
    printf '%s' "$show"
}

_mihomochain_listener_name_by_tag() {
    local config_file="${1:-$_MIHOMOCONF_CONFIG_FILE}" in_tag="$2"
    local type name port cipher password user_id user_pass sni
    local hy2_up hy2_down hy2_ignore hy2_obfs hy2_obfs_password hy2_masquerade hy2_mport hy2_insecure listener_tag
    while IFS=$'\x1f' read -r type name port cipher password user_id user_pass sni \
        hy2_up hy2_down hy2_ignore hy2_obfs hy2_obfs_password hy2_masquerade hy2_mport hy2_insecure listener_tag; do
        [[ -z "${name:-}" ]] && continue
        if [[ "${listener_tag:-}" == "$in_tag" ]]; then
            printf '%s' "$name"
            return 0
        fi
    done < <(_mihomoconf_read_listener_rows "$config_file")
    printf '%s' "$in_tag"
    return 1
}

_mihomochain_listener_tag_by_name() {
    local config_file="${1:-$_MIHOMOCONF_CONFIG_FILE}" in_name="$2"
    local type name port cipher password user_id user_pass sni
    local hy2_up hy2_down hy2_ignore hy2_obfs hy2_obfs_password hy2_masquerade hy2_mport hy2_insecure listener_tag
    while IFS=$'\x1f' read -r type name port cipher password user_id user_pass sni \
        hy2_up hy2_down hy2_ignore hy2_obfs hy2_obfs_password hy2_masquerade hy2_mport hy2_insecure listener_tag; do
        [[ -z "${name:-}" ]] && continue
        if [[ "${name}" == "$in_name" ]]; then
            printf '%s' "${listener_tag}"
            return 0
        fi
    done < <(_mihomoconf_read_listener_rows "$config_file")
    return 1
}

_mihomochain_list_outbounds() {
    local config_file="${1:-$_MIHOMOCONF_CONFIG_FILE}"
    local shown=0 name type server port cipher username password sni insecure obfs obfs_password mport show_name
    local wg_ip wg_ipv6 wg_private_key wg_public_key wg_allowed_ips wg_preshared_key wg_reserved wg_mtu wg_keepalive
    while IFS=$'\x1f' read -r name type server port cipher username password sni insecure obfs obfs_password mport \
        wg_ip wg_ipv6 wg_private_key wg_public_key wg_allowed_ips wg_preshared_key wg_reserved wg_mtu wg_keepalive; do
        [[ -z "${name:-}" ]] && continue
        [[ "$name" == "$_MIHOMOCONF_IPV4_FORCE_PROXY_NAME" ]] && continue
        shown=1
        show_name=$(_mihomochain_display_name "$name")
        case "$type" in
            ss)
                printf "      %s (type=%s, %s:%s, cipher=%s)\n" "$show_name" "$type" "$server" "$port" "$cipher"
                ;;
            anytls)
                if [[ -n "${sni:-}" ]]; then
                    printf "      %s (type=%s, %s:%s, sni=%s)\n" "$show_name" "$type" "$server" "$port" "$sni"
                else
                    printf "      %s (type=%s, %s:%s)\n" "$show_name" "$type" "$server" "$port"
                fi
                ;;
            hy2|hysteria2)
                local extra=""
                [[ -n "${sni:-}" ]] && extra="${extra}, sni=${sni}"
                [[ -n "${obfs:-}" ]] && extra="${extra}, obfs=${obfs}"
                [[ "${insecure:-0}" == "1" ]] && extra="${extra}, insecure=1"
                printf "      %s (type=%s, %s:%s%s)\n" "$show_name" "$type" "$server" "$port" "$extra"
                ;;
            socks5|http)
                if [[ -n "${username:-}" || -n "${password:-}" ]]; then
                    printf "      %s (type=%s, %s:%s, auth=on)\n" "$show_name" "$type" "$server" "$port"
                else
                    printf "      %s (type=%s, %s:%s, auth=off)\n" "$show_name" "$type" "$server" "$port"
                fi
                ;;
            wireguard|wg)
                local wg_extra=""
                [[ -n "${wg_ip:-}" ]] && wg_extra="${wg_extra}, ip=${wg_ip}"
                [[ -n "${wg_allowed_ips:-}" ]] && wg_extra="${wg_extra}, allowed-ips=${wg_allowed_ips}"
                [[ -n "${wg_mtu:-}" ]] && wg_extra="${wg_extra}, mtu=${wg_mtu}"
                printf "      %s (type=wireguard, %s:%s%s)\n" "$show_name" "$server" "$port" "$wg_extra"
                ;;
            *)
                printf "      %s (type=%s, %s:%s)\n" "$show_name" "$type" "$server" "$port"
                ;;
        esac
    done < <(_mihomochain_read_proxy_rows "$config_file")

    if [[ "$shown" -eq 0 ]]; then
        _warn "暂无落地节点/二层代理"
    fi
}

_mihomochain_list_rules() {
    local config_file="${1:-$_MIHOMOCONF_CONFIG_FILE}"
    local shown=0 kind left right
    while IFS=$'\x1f' read -r kind left right; do
        [[ -z "${kind:-}" ]] && continue
        shown=1
        if [[ "$kind" == "RULE_USER" ]]; then
            printf "      user=%s -> outbound=%s\n" "$left" "$right"
        else
            printf "      in-name=%s -> outbound=%s\n" "$left" "$right"
        fi
    done < <(_mihomochain_read_rules_from_config "$config_file")
    if [[ "$shown" -eq 0 ]]; then
        _warn "暂无入站分流规则"
    fi
}

_mihomochain_read_rules_from_config() {
    local config_file="${1:-$_MIHOMOCONF_CONFIG_FILE}"
    [[ -f "$config_file" ]] || return 1
    awk '
        function trim(s) {
            sub(/^[[:space:]]+/, "", s)
            sub(/[[:space:]]+$/, "", s)
            return s
        }
        BEGIN { in_rules=0 }
        /^[^[:space:]#][^:]*:[[:space:]]*.*$/ {
            in_rules = ($0 ~ /^rules:[[:space:]]*$/)
            next
        }
        !in_rules { next }
        /^[[:space:]]*-[[:space:]]*/ {
            line=$0
            sub(/^[[:space:]]*-[[:space:]]*/, "", line)
            sub(/[[:space:]]+#.*/, "", line)
            line=trim(line)
            if (line ~ /^IN-USER,[^,]+,[^,]+$/) {
                split(line, a, ",")
                printf "RULE_USER\037%s\037%s\n", a[2], a[3]
            } else if (line ~ /^IN-NAME,[^,]+,[^,]+$/) {
                split(line, a, ",")
                printf "RULE_NAME\037%s\037%s\n", a[2], a[3]
            }
        }
    ' "$config_file"
}

_mihomochain_listener_name_by_user() {
    local config_file="${1:-$_MIHOMOCONF_CONFIG_FILE}" target_user="$2"
    local listener_tag listener_name type port username passwd
    while IFS=$'\x1f' read -r listener_tag listener_name type port username passwd; do
        [[ -z "${username:-}" ]] && continue
        if [[ "$username" == "$target_user" ]]; then
            printf '%s' "$listener_name"
            return 0
        fi
    done < <(_mihomoconf_read_listener_user_rows "$config_file")
    printf '%s' "-"
    return 1
}

_mihomochain_show_topology() {
    local config_file="${1:-$_MIHOMOCONF_CONFIG_FILE}"
    local shown=0 kind left right in_name out_name
    while IFS=$'\x1f' read -r kind left right; do
        [[ -z "${kind:-}" ]] && continue
        shown=1
        out_name=$(_mihomochain_display_name "$right")
        if [[ "$kind" == "RULE_USER" ]]; then
            in_name=$(_mihomochain_listener_name_by_user "$config_file" "$left")
            printf "      %s [user=%s]  ${DIM}-->${PLAIN}  %s\n" "$in_name" "$left" "$out_name"
        else
            printf "      %s  ${DIM}-->${PLAIN}  %s\n" "$left" "$out_name"
        fi
    done < <(_mihomochain_read_rules_from_config "$config_file")

    if [[ "$shown" -eq 0 ]]; then
        _warn "暂无已绑定规则"
        return 1
    fi
    return 0
}

_mihomochain_list_listeners() {
    local config_file="${1:-$_MIHOMOCONF_CONFIG_FILE}"
    if [[ ! -f "$config_file" ]]; then
        _warn "配置文件不存在: ${config_file}"
        return 1
    fi

    local found=0
    local type name port cipher password user_id user_pass sni
    local hy2_up hy2_down hy2_ignore hy2_obfs hy2_obfs_password hy2_masquerade hy2_mport hy2_insecure listener_tag
    local u_name u_pass u_count
    while IFS=$'\x1f' read -r type name port cipher password user_id user_pass sni \
        hy2_up hy2_down hy2_ignore hy2_obfs hy2_obfs_password hy2_masquerade hy2_mport hy2_insecure listener_tag; do
        [[ -z "${name:-}" ]] && continue
        found=1
        listener_tag="${listener_tag:-$name}"
        u_count=0
        while IFS=$'\x1f' read -r u_name u_pass; do
            [[ -z "${u_name:-}" ]] && continue
            u_count=$((u_count + 1))
        done < <(_mihomoconf_read_users_by_tag "$config_file" "$listener_tag")
        if [[ "$u_count" -gt 0 ]]; then
            printf "      %s (type=%s, port=%s, users=%s)\n" "$name" "$type" "${port:-N/A}" "$u_count"
        else
            printf "      %s (type=%s, port=%s)\n" "$name" "$type" "${port:-N/A}"
        fi
    done < <(_mihomoconf_read_listener_rows "$config_file")

    if [[ "$found" -eq 0 ]]; then
        _warn "未读取到 listeners 节点"
        return 1
    fi
    return 0
}

_mihomochain_base64url_decode() {
    local input="$1"
    local mod
    input="${input//-/+}"
    input="${input//_//}"
    mod=$(( ${#input} % 4 ))
    if (( mod == 2 )); then
        input="${input}=="
    elif (( mod == 3 )); then
        input="${input}="
    elif (( mod == 1 )); then
        return 1
    fi
    echo -n "$input" | base64 -d 2>/dev/null
}

_mihomochain_urldecode() {
    local s="${1:-}"
    # URI 中 '+' 本身是合法字符，不应默认当作空格处理，
    # 否则密码中包含 '+' 会被错误改写。
    printf '%b' "${s//%/\\x}"
}

_mihomochain_extract_link_name() {
    local link="${1:-}" frag
    [[ "$link" == *#* ]] || return 1
    frag="${link#*#}"
    frag=$(_mihomochain_urldecode "$frag")
    frag=$(_mihomoconf_trim "${frag:-}")
    [[ -n "$frag" ]] || return 1
    printf '%s' "$frag"
}

_mihomochain_default_outbound_name() {
    local out_type="${1:-outbound}" out_server="${2:-server}" out_port="${3:-0}"
    case "$out_type" in
        hysteria2) out_type="hy2" ;;
    esac
    printf '%s-%s-%s' "$out_type" "$out_server" "$out_port"
}

_mihomochain_add_or_update_outbound() {
    local tag="$1" type="$2" server="$3" port="$4" cipher="$5" username="$6" password="$7"
    local sni="${8:-}" insecure="${9:-0}" obfs="${10:-}" obfs_password="${11:-}" mport="${12:-}" out_name="${13:-}"
    local wg_ip="${14:-}" wg_ipv6="${15:-}" wg_private_key="${16:-}" wg_public_key="${17:-}"
    local wg_allowed_ips="${18:-}" wg_preshared_key="${19:-}" wg_reserved="${20:-}" wg_mtu="${21:-}" wg_keepalive="${22:-}"
    local config_file="$_MIHOMOCONF_CONFIG_FILE"
    local name q_name q_server q_cipher q_user q_pass q_sni q_obfs q_obfs_password q_mport
    local q_wg_ip q_wg_ipv6 q_wg_private_key q_wg_public_key q_wg_allowed_ips q_wg_preshared_key q_wg_reserved
    local tmp_block

    name="${out_name:-$tag}"
    q_name=$(_mihomochain_yaml_quote "$name")
    q_server=$(_mihomochain_yaml_quote "$server")
    q_cipher=$(_mihomochain_yaml_quote "$cipher")
    q_user=$(_mihomochain_yaml_quote "$username")
    q_pass=$(_mihomochain_yaml_quote "$password")
    q_sni=$(_mihomochain_yaml_quote "$sni")
    q_obfs=$(_mihomochain_yaml_quote "$obfs")
    q_obfs_password=$(_mihomochain_yaml_quote "$obfs_password")
    q_mport=$(_mihomochain_yaml_quote "$mport")
    q_wg_ip=$(_mihomochain_yaml_quote "$wg_ip")
    q_wg_ipv6=$(_mihomochain_yaml_quote "$wg_ipv6")
    q_wg_private_key=$(_mihomochain_yaml_quote "$wg_private_key")
    q_wg_public_key=$(_mihomochain_yaml_quote "$wg_public_key")
    q_wg_allowed_ips=$(_mihomochain_yaml_list_from_csv "$wg_allowed_ips")
    q_wg_preshared_key=$(_mihomochain_yaml_quote "$wg_preshared_key")
    q_wg_reserved=$(_mihomochain_yaml_quote "$wg_reserved")

    tmp_block=$(mktemp)
    case "$type" in
        ss)
            cat > "$tmp_block" <<EOF
  - name: "${q_name}"
    type: ss
    server: "${q_server}"
    port: ${port}
    cipher: ${q_cipher}
    password: "${q_pass}"
    udp: true
EOF
            ;;
        anytls)
            cat > "$tmp_block" <<EOF
  - name: "${q_name}"
    type: anytls
    server: "${q_server}"
    port: ${port}
    password: "${q_pass}"
    udp: true
    tfo: true
EOF
            if [[ -n "$q_sni" ]]; then
                printf '    sni: "%s"\n' "$q_sni" >> "$tmp_block"
            fi
            ;;
        hy2|hysteria2)
            cat > "$tmp_block" <<EOF
  - name: "${q_name}"
    type: hysteria2
    server: "${q_server}"
    port: ${port}
    password: "${q_pass}"
EOF
            if [[ -n "$q_sni" ]]; then
                printf '    sni: "%s"\n' "$q_sni" >> "$tmp_block"
            fi
            if [[ "$insecure" == "1" ]]; then
                echo "    skip-cert-verify: true" >> "$tmp_block"
            fi
            if [[ -n "$q_mport" ]]; then
                printf '    mport: "%s"\n' "$q_mport" >> "$tmp_block"
            fi
            if [[ -n "$q_obfs" ]]; then
                printf '    obfs: "%s"\n' "$q_obfs" >> "$tmp_block"
                if [[ -n "$q_obfs_password" ]]; then
                    printf '    obfs-password: "%s"\n' "$q_obfs_password" >> "$tmp_block"
                fi
            fi
            ;;
        socks5|http)
            cat > "$tmp_block" <<EOF
  - name: "${q_name}"
    type: ${type}
    server: "${q_server}"
    port: ${port}
EOF
            if [[ -n "$q_user" ]]; then
                printf '    username: "%s"\n' "$q_user" >> "$tmp_block"
            fi
            if [[ -n "$q_pass" ]]; then
                printf '    password: "%s"\n' "$q_pass" >> "$tmp_block"
            fi
            if [[ "$type" == "socks5" ]]; then
                echo "    udp: true" >> "$tmp_block"
            fi
            ;;
        wireguard|wg)
            if [[ -z "$server" || -z "$wg_ip" || -z "$wg_private_key" || -z "$wg_public_key" ]] || ! _is_valid_port "$port"; then
                rm -f "$tmp_block"
                return 1
            fi
            if ! _mihomo_supports_wireguard_proxy_outbound; then
                _error_no_exit "当前 mihomo 不支持 wireguard 出站 (proxies.type=wireguard)，请升级 mihomo 或改用其他出站类型"
                rm -f "$tmp_block"
                return 1
            fi
            cat > "$tmp_block" <<EOF
  - name: "${q_name}"
    type: wireguard
    server: "${q_server}"
    port: ${port}
    ip: "${q_wg_ip}"
    private-key: "${q_wg_private_key}"
    public-key: "${q_wg_public_key}"
    allowed-ips: ${q_wg_allowed_ips}
    udp: true
EOF
            if [[ -n "$q_wg_ipv6" ]]; then
                printf '    ipv6: "%s"\n' "$q_wg_ipv6" >> "$tmp_block"
            fi
            if [[ -n "$q_wg_preshared_key" ]]; then
                printf '    pre-shared-key: "%s"\n' "$q_wg_preshared_key" >> "$tmp_block"
            fi
            if [[ -n "$wg_reserved" ]]; then
                if [[ "$wg_reserved" == \[*\] ]]; then
                    printf '    reserved: %s\n' "$wg_reserved" >> "$tmp_block"
                else
                    printf '    reserved: "%s"\n' "$q_wg_reserved" >> "$tmp_block"
                fi
            fi
            if [[ -n "$wg_mtu" ]]; then
                printf '    mtu: %s\n' "$wg_mtu" >> "$tmp_block"
            fi
            if [[ -n "$wg_keepalive" ]]; then
                printf '    persistent-keepalive: %s\n' "$wg_keepalive" >> "$tmp_block"
            fi
            ;;
        *)
            rm -f "$tmp_block"
            return 1
            ;;
    esac

    _mihomochain_upsert_proxy_block "$config_file" "$name" "$tmp_block"
    rm -f "$tmp_block"
}

_mihomochain_add_or_update_rule() {
    local in_tag="$1" out_tag="$2"
    local config_file="$_MIHOMOCONF_CONFIG_FILE"
    local listener_name out_name
    local tmp_other tmp_user tmp_name tmp_new

    listener_name=$(_mihomochain_listener_name_by_tag "$config_file" "$in_tag" 2>/dev/null || true)
    [[ -n "$listener_name" ]] || listener_name="$in_tag"
    if ! _mihomochain_listener_tag_by_name "$config_file" "$listener_name" >/dev/null 2>&1; then
        return 1
    fi
    out_name=$(_mihomochain_outbound_name_by_tag "$out_tag" 2>/dev/null || true)
    [[ -n "$out_name" ]] || out_name="$out_tag"
    if ! _mihomochain_outbound_tag_by_name "$out_name" >/dev/null 2>&1; then
        return 1
    fi

    tmp_other=$(mktemp)
    tmp_user=$(mktemp)
    tmp_name=$(mktemp)
    tmp_new=$(mktemp)
    _mihomochain_rule_split_parts "$config_file" "$tmp_other" "$tmp_user" "$tmp_name"
    awk -F'\037' -v n="$listener_name" '$1!=n { print }' "$tmp_name" > "$tmp_new"
    printf '%s\037%s\n' "$listener_name" "$out_name" >> "$tmp_new"
    mv "$tmp_new" "$tmp_name"
    _mihomochain_rule_write_parts "$config_file" "$tmp_other" "$tmp_user" "$tmp_name"
    rm -f "$tmp_other" "$tmp_user" "$tmp_name"
}

_mihomochain_add_or_update_user_rule() {
    local in_tag="$1" username="$2" out_tag="$3"
    local config_file="$_MIHOMOCONF_CONFIG_FILE"
    local resolved_tag resolved_name resolved_type resolved_cipher resolved_password
    local resolved_user_count user_pass out_name
    local tmp_other tmp_user tmp_name tmp_new

    resolved_tag="$in_tag"
    if ! _mihomoconf_listener_has_user "$config_file" "$resolved_tag" "$username"; then
        resolved_tag=$(_mihomochain_listener_tag_by_name "$config_file" "$in_tag" 2>/dev/null || true)
    fi
    if ! _mihomoconf_listener_has_user "$config_file" "$resolved_tag" "$username"; then
        return 1
    fi

    if ! IFS=$'\x1f' read -r resolved_tag resolved_name resolved_type resolved_cipher resolved_password \
        < <(_mihomoconf_listener_meta_by_tag "$config_file" "$resolved_tag"); then
        return 1
    fi

    out_name=$(_mihomochain_outbound_name_by_tag "$out_tag" 2>/dev/null || true)
    [[ -n "$out_name" ]] || out_name="$out_tag"
    if ! _mihomochain_outbound_tag_by_name "$out_name" >/dev/null 2>&1; then
        return 1
    fi

    if [[ "$resolved_type" == "shadowsocks" ]]; then
        user_pass=$(_mihomoconf_user_password_by_tag "$config_file" "$resolved_tag" "$username" 2>/dev/null || true)
        [[ -n "$user_pass" ]] || return 1
        _mihomoconf_add_or_update_listener_user "$config_file" "$resolved_tag" "$username" "$user_pass" >/dev/null 2>&1 || return 1
        resolved_user_count=$(_mihomoconf_count_users_by_tag "$config_file" "$resolved_tag")
        if [[ "${resolved_user_count:-0}" == "1" ]]; then
            _mihomochain_add_or_update_rule "$resolved_tag" "$out_tag"
            return $?
        fi
    fi

    tmp_other=$(mktemp)
    tmp_user=$(mktemp)
    tmp_name=$(mktemp)
    tmp_new=$(mktemp)
    _mihomochain_rule_split_parts "$config_file" "$tmp_other" "$tmp_user" "$tmp_name"
    awk -F'\037' -v u="$username" '$1!=u { print }' "$tmp_user" > "$tmp_new"
    printf '%s\037%s\n' "$username" "$out_name" >> "$tmp_new"
    mv "$tmp_new" "$tmp_user"
    _mihomochain_rule_write_parts "$config_file" "$tmp_other" "$tmp_user" "$tmp_name"
    rm -f "$tmp_other" "$tmp_user" "$tmp_name"
}

_mihomochain_normalize_rules_for_compat() {
    local config_file="${1:-$_MIHOMOCONF_CONFIG_FILE}"
    local tmp_other tmp_user tmp_name tmp_user_new tmp_name_new tmp_rewrite
    local normalized="0"
    local username out_name listener_tag listener_name listener_type listener_cipher listener_password
    local user_count user_pass

    [[ -f "$config_file" ]] || return 1

    tmp_other=$(mktemp)
    tmp_user=$(mktemp)
    tmp_name=$(mktemp)
    tmp_user_new=$(mktemp)
    tmp_name_new=$(mktemp)
    _mihomochain_rule_split_parts "$config_file" "$tmp_other" "$tmp_user" "$tmp_name"
    : > "$tmp_user_new"
    cat "$tmp_name" > "$tmp_name_new"

    while IFS=$'\x1f' read -r username out_name; do
        [[ -n "${username:-}" && -n "${out_name:-}" ]] || continue
        listener_tag=$(_mihomoconf_unique_listener_tag_by_user "$config_file" "$username" 2>/dev/null || true)
        if [[ -n "$listener_tag" ]]; then
            if IFS=$'\x1f' read -r listener_tag listener_name listener_type listener_cipher listener_password \
                < <(_mihomoconf_listener_meta_by_tag "$config_file" "$listener_tag"); then
                if [[ "$listener_type" == "shadowsocks" ]]; then
                    user_pass=$(_mihomoconf_user_password_by_tag "$config_file" "$listener_tag" "$username" 2>/dev/null || true)
                    if [[ -n "$user_pass" ]]; then
                        _mihomoconf_add_or_update_listener_user "$config_file" "$listener_tag" "$username" "$user_pass" >/dev/null 2>&1 || true
                    fi
                    user_count=$(_mihomoconf_count_users_by_tag "$config_file" "$listener_tag")
                    if [[ "${user_count:-0}" == "1" && -n "$listener_name" ]]; then
                        tmp_rewrite=$(mktemp)
                        awk -F'\037' -v n="$listener_name" '$1!=n { print }' "$tmp_name_new" > "$tmp_rewrite"
                        mv "$tmp_rewrite" "$tmp_name_new"
                        printf '%s\037%s\n' "$listener_name" "$out_name" >> "$tmp_name_new"
                        normalized="1"
                        continue
                    fi
                fi
            fi
        fi
        printf '%s\037%s\n' "$username" "$out_name" >> "$tmp_user_new"
    done < "$tmp_user"

    if [[ "$normalized" == "1" ]]; then
        mv "$tmp_user_new" "$tmp_user"
        mv "$tmp_name_new" "$tmp_name"
        _mihomochain_rule_write_parts "$config_file" "$tmp_other" "$tmp_user" "$tmp_name"
    fi

    rm -f "$tmp_other" "$tmp_user" "$tmp_name" "$tmp_user_new" "$tmp_name_new"
}

_mihomochain_remove_outbound() {
    local tag="$1"
    local config_file="$_MIHOMOCONF_CONFIG_FILE"
    local out_name tmp_other tmp_user tmp_name tmp_new

    out_name=$(_mihomochain_outbound_name_by_tag "$tag" 2>/dev/null || true)
    [[ -n "$out_name" ]] || out_name="$tag"

    _mihomochain_remove_proxy_by_name "$config_file" "$out_name"
    tmp_other=$(mktemp)
    tmp_user=$(mktemp)
    tmp_name=$(mktemp)
    tmp_new=$(mktemp)
    _mihomochain_rule_split_parts "$config_file" "$tmp_other" "$tmp_user" "$tmp_name"
    awk -F'\037' -v o="$out_name" '$2!=o { print }' "$tmp_user" > "$tmp_new"
    mv "$tmp_new" "$tmp_user"
    tmp_new=$(mktemp)
    awk -F'\037' -v o="$out_name" '$2!=o { print }' "$tmp_name" > "$tmp_new"
    mv "$tmp_new" "$tmp_name"
    _mihomochain_rule_write_parts "$config_file" "$tmp_other" "$tmp_user" "$tmp_name"
    rm -f "$tmp_other" "$tmp_user" "$tmp_name"
}

_mihomochain_remove_rule() {
    local in_tag="$1"
    local config_file="$_MIHOMOCONF_CONFIG_FILE"
    local in_name tmp_other tmp_user tmp_name tmp_new

    in_name=$(_mihomochain_listener_name_by_tag "$config_file" "$in_tag" 2>/dev/null || true)
    [[ -n "$in_name" ]] || in_name="$in_tag"
    if ! _mihomochain_listener_tag_by_name "$config_file" "$in_name" >/dev/null 2>&1; then
        in_name="$in_tag"
    fi

    tmp_other=$(mktemp)
    tmp_user=$(mktemp)
    tmp_name=$(mktemp)
    tmp_new=$(mktemp)
    _mihomochain_rule_split_parts "$config_file" "$tmp_other" "$tmp_user" "$tmp_name"
    awk -F'\037' -v n="$in_name" '$1!=n { print }' "$tmp_name" > "$tmp_new"
    mv "$tmp_new" "$tmp_name"
    _mihomochain_rule_write_parts "$config_file" "$tmp_other" "$tmp_user" "$tmp_name"
    rm -f "$tmp_other" "$tmp_user" "$tmp_name"
}

_mihomochain_remove_user_rule() {
    local in_tag="$1" username="$2"
    local config_file="$_MIHOMOCONF_CONFIG_FILE"
    local tmp_other tmp_user tmp_name tmp_new
    local _unused_tag="$in_tag"

    tmp_other=$(mktemp)
    tmp_user=$(mktemp)
    tmp_name=$(mktemp)
    tmp_new=$(mktemp)
    _mihomochain_rule_split_parts "$config_file" "$tmp_other" "$tmp_user" "$tmp_name"
    awk -F'\037' -v u="$username" '$1!=u { print }' "$tmp_user" > "$tmp_new"
    mv "$tmp_new" "$tmp_user"
    _mihomochain_rule_write_parts "$config_file" "$tmp_other" "$tmp_user" "$tmp_name"
    rm -f "$tmp_other" "$tmp_user" "$tmp_name"
}

_mihomochain_upsert_proxy_block() {
    local config_file="$1" proxy_name="$2" block_file="$3"
    local tmp
    tmp=$(mktemp)
    awk -v target="$proxy_name" -v blockf="$block_file" '
        function trim(s) {
            sub(/^[[:space:]]+/, "", s)
            sub(/[[:space:]]+$/, "", s)
            return s
        }
        function unquote(s) {
            gsub(/^"/, "", s)
            gsub(/"$/, "", s)
            return s
        }
        function flush_item() {
            if (!in_item) return
            if (item_name == target) {
                if (!replaced) {
                    printf "%s", new_block
                    replaced=1
                }
            } else {
                printf "%s", item_buf
            }
            item_buf=""
            item_name=""
            in_item=0
        }
        BEGIN {
            in_proxies=0
            in_item=0
            has_proxies=0
            replaced=0
            item_buf=""
            item_name=""
            new_block=""
            while ((getline line < blockf) > 0) {
                new_block = new_block line "\n"
            }
            close(blockf)
        }
        /^[^[:space:]#][^:]*:[[:space:]]*.*$/ {
            if (in_proxies) {
                flush_item()
                if (!replaced) {
                    printf "%s", new_block
                    replaced=1
                }
            }
            in_proxies = ($0 ~ /^proxies:[[:space:]]*$/)
            if (in_proxies) has_proxies=1
            print
            next
        }
        !in_proxies {
            print
            next
        }
        /^  - name:/ {
            flush_item()
            in_item=1
            item_buf=$0 "\n"
            line=$0
            sub(/^  - name:[[:space:]]*/, "", line)
            item_name=unquote(trim(line))
            next
        }
        in_item {
            item_buf=item_buf $0 "\n"
            next
        }
        { print }
        END {
            if (in_proxies) {
                flush_item()
                if (!replaced) {
                    printf "%s", new_block
                    replaced=1
                }
            }
            if (!has_proxies) {
                print ""
                print "proxies:"
                printf "%s", new_block
            }
        }
    ' "$config_file" > "$tmp"
    mv "$tmp" "$config_file"
}

_mihomochain_remove_proxy_by_name() {
    local config_file="$1" proxy_name="$2"
    local tmp
    tmp=$(mktemp)
    awk -v target="$proxy_name" '
        function trim(s) {
            sub(/^[[:space:]]+/, "", s)
            sub(/[[:space:]]+$/, "", s)
            return s
        }
        function unquote(s) {
            gsub(/^"/, "", s)
            gsub(/"$/, "", s)
            return s
        }
        function flush_item() {
            if (!in_item) return
            if (item_name != target) {
                printf "%s", item_buf
            }
            item_buf=""
            item_name=""
            in_item=0
        }
        BEGIN {
            in_proxies=0
            in_item=0
            item_buf=""
            item_name=""
        }
        /^[^[:space:]#][^:]*:[[:space:]]*.*$/ {
            if (in_proxies) {
                flush_item()
            }
            in_proxies = ($0 ~ /^proxies:[[:space:]]*$/)
            print
            next
        }
        !in_proxies {
            print
            next
        }
        /^  - name:/ {
            flush_item()
            in_item=1
            item_buf=$0 "\n"
            line=$0
            sub(/^  - name:[[:space:]]*/, "", line)
            item_name=unquote(trim(line))
            next
        }
        in_item {
            item_buf=item_buf $0 "\n"
            next
        }
        { print }
        END {
            if (in_proxies) {
                flush_item()
            }
        }
    ' "$config_file" > "$tmp"
    mv "$tmp" "$config_file"
}

_mihomochain_rule_split_parts() {
    local config_file="$1" other_file="$2" user_file="$3" name_file="$4"
    : > "$other_file"
    : > "$user_file"
    : > "$name_file"
    awk -v of="$other_file" -v uf="$user_file" -v nf="$name_file" '
        function trim(s) {
            sub(/^[[:space:]]+/, "", s)
            sub(/[[:space:]]+$/, "", s)
            return s
        }
        BEGIN { in_rules=0 }
        /^[^[:space:]#][^:]*:[[:space:]]*.*$/ {
            in_rules = ($0 ~ /^rules:[[:space:]]*$/)
            next
        }
        !in_rules { next }
        /^[[:space:]]*-[[:space:]]*/ {
            line=$0
            sub(/^[[:space:]]*-[[:space:]]*/, "", line)
            sub(/[[:space:]]+#.*/, "", line)
            line=trim(line)
            if (line == "") next
            if (line ~ /^IN-USER,[^,]+,[^,]+$/) {
                split(line, a, ",")
                printf "%s\037%s\n", a[2], a[3] >> uf
            } else if (line ~ /^IN-NAME,[^,]+,[^,]+$/) {
                split(line, a, ",")
                printf "%s\037%s\n", a[2], a[3] >> nf
            } else if (line ~ /^MATCH,DIRECT$/) {
                next
            } else {
                print line >> of
            }
            next
        }
    ' "$config_file"
}

_mihomochain_rule_write_parts() {
    local config_file="$1" other_file="$2" user_file="$3" name_file="$4"
    local tmp_cfg
    tmp_cfg=$(mktemp)
    awk '
        BEGIN { skip=0 }
        skip && /^[^ #]/ { skip=0 }
        skip { next }
        /^rules:[[:space:]]*$/ { skip=1; next }
        { print }
    ' "$config_file" > "$tmp_cfg"

    {
        echo ""
        echo "rules:"
        while IFS= read -r line; do
            [[ -z "${line:-}" ]] && continue
            printf "  - %s\n" "$line"
        done < "$other_file"
        while IFS=$'\x1f' read -r user out; do
            [[ -z "${user:-}" || -z "${out:-}" ]] && continue
            printf "  - IN-USER,%s,%s\n" "$user" "$out"
        done < "$user_file"
        while IFS=$'\x1f' read -r in_name out; do
            [[ -z "${in_name:-}" || -z "${out:-}" ]] && continue
            printf "  - IN-NAME,%s,%s\n" "$in_name" "$out"
        done < "$name_file"
        echo "  - MATCH,DIRECT"
    } >> "$tmp_cfg"
    mv "$tmp_cfg" "$config_file"
}

_mihomochain_set_listener_tag() {
    local config_file="$1" listener_name="$2" new_tag="$3"
    local tmp
    tmp=$(mktemp)
    awk -v n="$listener_name" -v t="$new_tag" '
        function trim(s) {
            sub(/^[[:space:]]+/, "", s)
            sub(/[[:space:]]+$/, "", s)
            return s
        }
        function unquote(s) {
            gsub(/^"/, "", s)
            gsub(/"$/, "", s)
            return s
        }
        function flush_tag_if_needed() {
            if (in_target && !tag_done) {
                print "    tag: \"" t "\""
                changed=1
                tag_done=1
            }
        }
        BEGIN {
            in_target=0
            tag_done=0
            changed=0
        }
        /^  - name:/ {
            flush_tag_if_needed()
            line=$0
            sub(/^  - name:[[:space:]]*/, "", line)
            current=unquote(trim(line))
            in_target=(current==n)
            tag_done=0
            print
            next
        }
        in_target && /^    tag:/ {
            print "    tag: \"" t "\""
            changed=1
            tag_done=1
            next
        }
        in_target && /^[^ ]/ {
            flush_tag_if_needed()
            in_target=0
        }
        {
            print
        }
        END {
            flush_tag_if_needed()
            if (!changed) exit 2
        }
    ' "$config_file" > "$tmp"
    local ec=$?
    if [[ "$ec" -eq 0 ]]; then
        mv "$tmp" "$config_file"
        return 0
    fi
    rm -f "$tmp"
    return 1
}

_mihomochain_apply_to_config() {
    local config_file="$_MIHOMOCONF_CONFIG_FILE"
    if [[ ! -f "$config_file" ]]; then
        _error_no_exit "配置文件不存在: ${config_file}"
        return 1
    fi

    _mihomochain_normalize_rules_for_compat "$config_file"
    _mihomoconf_force_rule_mode "$config_file"
    _mihomoconf_ensure_match_direct_rule "$config_file"
    _mihomoconf_apply_ipv4_google_policy "$config_file"
    _info "链式代理配置已写入: ${config_file}"
    return 0
}

_mihomochain_apply_and_restart() {
    if ! _mihomochain_apply_to_config; then
        return 1
    fi
    if ! _mihomo_restart_now; then
        return 1
    fi
    _success "链式代理变更已实时生效"
    return 0
}

_mihomo_chain_proxy_manage() {
    _header "服务端链式代理"

    local config_file="$_MIHOMOCONF_CONFIG_FILE"

    if [[ ! -f "$config_file" ]]; then
        _error_no_exit "未找到配置文件: ${config_file}"
        _info "请先在 Mihomo 菜单中生成基础配置"
        _press_any_key
        return
    fi

    while true; do
        _header "服务端链式代理"
        _info "配置文件: ${config_file}"
        _info "实时生效: 保存后将自动写入并重启 mihomo"
        _info "提示: WireGuard 出站为 Beta 功能"
        _separator
        _menu_pair "1" "查看当前规则" "" "green" "2" "添加出口节点" "" "green"
        _menu_pair "3" "绑定入站节点 -> 出口节点" "" "green" "4" "绑定入站用户 -> 出口节点" "" "green"
        _menu_pair "5" "删除出口节点" "" "green" "6" "删除绑定规则" "" "green"
        _menu_item "7" "新增入站用户" "" "green"
        _menu_item "0" "返回上级菜单" "" "red"
        _separator

        local ch
        read -rp "  选择 [0-7]: " ch
        case "$ch" in
            1)
                printf "  ${BOLD}当前规则:${PLAIN}\n"
                _separator
                _mihomochain_show_topology "$config_file"
                printf "  ${BOLD}可用入站节点:${PLAIN}\n"
                _separator
                _mihomochain_list_listeners "$config_file"
                printf "  ${BOLD}可用出口节点:${PLAIN}\n"
                _separator
                _mihomochain_list_outbounds "$config_file"
                _press_any_key
                ;;
            2)
                printf "  ${BOLD}添加出口节点${PLAIN}\n"
                _separator
                _menu_pair "1" "通过链接导入" "ss:// hy2:// anytls:// wireguard:// (Beta)" "green" "2" "手动录入" "" "green"
                _separator
                local import_mode out_name out_tag out_type out_server out_port out_cipher out_user out_pass
                local out_sni out_insecure out_obfs out_obfs_pass out_mport
                local out_wg_ip out_wg_ipv6 out_wg_private_key out_wg_public_key out_wg_allowed_ips
                local out_wg_preshared_key out_wg_reserved out_wg_mtu out_wg_keepalive
                read -rp "  请选择 [1/2]: " import_mode
                import_mode=$(_mihomoconf_trim "${import_mode:-}")
                case "$import_mode" in
                    1|2) ;;
                    *)
                        if [[ "$import_mode" == *"://"* ]]; then
                            _error_no_exit "输入格式错误：这里请输入 1 或 2。若要通过链接导入，请先输入 1 再粘贴链接。"
                        else
                            _error_no_exit "无效选项，请输入 1 或 2"
                        fi
                        _press_any_key
                        continue
                        ;;
                esac
                out_cipher=""
                out_user=""
                out_pass=""
                out_sni=""
                out_insecure="0"
                out_obfs=""
                out_obfs_pass=""
                out_mport=""
                out_wg_ip=""
                out_wg_ipv6=""
                out_wg_private_key=""
                out_wg_public_key=""
                out_wg_allowed_ips=""
                out_wg_preshared_key=""
                out_wg_reserved=""
                out_wg_mtu=""
                out_wg_keepalive=""
                case "$import_mode" in
                    1)
                        local in_link link_body link_userinfo link_hostport link_query link_name
                        local rename_confirm custom_name_input
                        local ss_decoded kv k v
                        local -a _qarr
                        read -rp "  输入链接 (ss:// / hy2:// / hysteria2:// / anytls:// / wireguard://[Beta]): " in_link
                        in_link=$(_mihomoconf_trim "${in_link:-}")
                        if [[ -z "$in_link" ]]; then
                            _error_no_exit "链接不能为空"
                            _press_any_key
                            continue
                        fi
                        link_name=$(_mihomochain_extract_link_name "$in_link" 2>/dev/null || true)
                        case "$in_link" in
                            ss://*)
                                link_body="${in_link#ss://}"
                                link_body="${link_body%%#*}"
                                link_query=""
                                if [[ "$link_body" == *\?* ]]; then
                                    link_query="${link_body#*\?}"
                                    link_body="${link_body%%\?*}"
                                fi
                                link_body="${link_body%/}"
                                if [[ -n "$link_query" ]]; then
                                    IFS='&' read -r -a _qarr <<< "$link_query"
                                    for kv in "${_qarr[@]}"; do
                                        k="${kv%%=*}"
                                        k=$(_mihomochain_urldecode "$k")
                                        if [[ "$k" == "plugin" ]]; then
                                            _error_no_exit "暂不支持带 plugin 参数的 ss 链接，请使用手动录入"
                                            _press_any_key
                                            continue 2
                                        fi
                                    done
                                fi
                                if [[ "$link_body" == *@* ]]; then
                                    link_userinfo="${link_body%@*}"
                                    link_hostport="${link_body#*@}"
                                else
                                    # 兼容 ss://BASE64(method:password@server:port) 形式
                                    ss_decoded=$(_mihomochain_base64url_decode "$link_body")
                                    if [[ -z "$ss_decoded" || "$ss_decoded" != *@* ]]; then
                                        _error_no_exit "ss 链接格式错误"
                                        _press_any_key
                                        continue
                                    fi
                                    link_userinfo="${ss_decoded%@*}"
                                    link_hostport="${ss_decoded#*@}"
                                fi
                                link_hostport="${link_hostport%%/*}"
                                out_server="${link_hostport%:*}"
                                out_port="${link_hostport##*:}"
                                if [[ "$link_userinfo" == *:* ]]; then
                                    ss_decoded=$(_mihomochain_urldecode "$link_userinfo")
                                else
                                    ss_decoded=$(_mihomochain_base64url_decode "$link_userinfo")
                                fi
                                if [[ -z "$ss_decoded" || "$ss_decoded" != *:* ]] || ! _is_valid_port "$out_port"; then
                                    _error_no_exit "ss 链接解析失败"
                                    _press_any_key
                                    continue
                                fi
                                out_type="ss"
                                out_cipher="${ss_decoded%%:*}"
                                out_pass="${ss_decoded#*:}"
                                ;;
                            anytls://*)
                                link_body="${in_link#anytls://}"
                                link_body="${link_body%%#*}"
                                link_query=""
                                if [[ "$link_body" == *\?* ]]; then
                                    link_query="${link_body#*\?}"
                                    link_body="${link_body%%\?*}"
                                fi
                                if [[ "$link_body" != *@* ]]; then
                                    _error_no_exit "anytls 链接格式错误"
                                    _press_any_key
                                    continue
                                fi
                                link_userinfo="${link_body%@*}"
                                link_hostport="${link_body#*@}"
                                link_hostport="${link_hostport%%/*}"
                                out_server="${link_hostport%:*}"
                                out_port="${link_hostport##*:}"
                                out_pass=$(_mihomochain_urldecode "$link_userinfo")
                                if [[ -z "$out_server" || -z "$out_pass" ]] || ! _is_valid_port "$out_port"; then
                                    _error_no_exit "anytls 链接解析失败"
                                    _press_any_key
                                    continue
                                fi
                                out_type="anytls"
                                if [[ -n "$link_query" ]]; then
                                    IFS='&' read -r -a _qarr <<< "$link_query"
                                    for kv in "${_qarr[@]}"; do
                                        k="${kv%%=*}"
                                        [[ "$kv" == *=* ]] && v="${kv#*=}" || v=""
                                        k=$(_mihomochain_urldecode "$k")
                                        v=$(_mihomochain_urldecode "$v")
                                        case "$k" in
                                            peer|sni) out_sni="$v" ;;
                                        esac
                                    done
                                fi
                                ;;
                            hy2://*|hysteria2://*)
                                if [[ "$in_link" == hy2://* ]]; then
                                    link_body="${in_link#hy2://}"
                                else
                                    link_body="${in_link#hysteria2://}"
                                fi
                                link_body="${link_body%%#*}"
                                link_query=""
                                if [[ "$link_body" == *\?* ]]; then
                                    link_query="${link_body#*\?}"
                                    link_body="${link_body%%\?*}"
                                fi
                                if [[ "$link_body" != *@* ]]; then
                                    _error_no_exit "hy2 链接格式错误"
                                    _press_any_key
                                    continue
                                fi
                                link_userinfo="${link_body%@*}"
                                link_hostport="${link_body#*@}"
                                link_hostport="${link_hostport%%/*}"
                                out_server="${link_hostport%:*}"
                                out_port="${link_hostport##*:}"
                                out_pass=$(_mihomochain_urldecode "$link_userinfo")
                                if [[ -z "$out_server" || -z "$out_pass" ]] || ! _is_valid_port "$out_port"; then
                                    _error_no_exit "hy2 链接解析失败"
                                    _press_any_key
                                    continue
                                fi
                                out_type="hysteria2"
                                if [[ -n "$link_query" ]]; then
                                    IFS='&' read -r -a _qarr <<< "$link_query"
                                    for kv in "${_qarr[@]}"; do
                                        k="${kv%%=*}"
                                        [[ "$kv" == *=* ]] && v="${kv#*=}" || v=""
                                        k=$(_mihomochain_urldecode "$k")
                                        v=$(_mihomochain_urldecode "$v")
                                        case "$k" in
                                            peer|sni) out_sni="$v" ;;
                                            insecure)
                                                if [[ "$v" == "1" || "$v" =~ ^([Tt][Rr][Uu][Ee]|[Yy][Ee][Ss])$ ]]; then
                                                    out_insecure="1"
                                                fi
                                                ;;
                                            obfs) out_obfs="$v" ;;
                                            obfs-password|obfs_password) out_obfs_pass="$v" ;;
                                            mport) out_mport="$v" ;;
                                        esac
                                    done
                                fi
                                ;;
                            wireguard://*|wg://*)
                                if [[ "$in_link" == wireguard://* ]]; then
                                    link_body="${in_link#wireguard://}"
                                else
                                    link_body="${in_link#wg://}"
                                fi
                                link_body="${link_body%%#*}"
                                link_query=""
                                if [[ "$link_body" == *\?* ]]; then
                                    link_query="${link_body#*\?}"
                                    link_body="${link_body%%\?*}"
                                fi
                                if [[ "$link_body" != *@* ]]; then
                                    _error_no_exit "wireguard(Beta) 链接格式错误，需为 wireguard://PRIVATE_KEY@server:port?... "
                                    _press_any_key
                                    continue
                                fi
                                link_userinfo="${link_body%@*}"
                                link_hostport="${link_body#*@}"
                                link_hostport="${link_hostport%%/*}"
                                out_server="${link_hostport%:*}"
                                out_port="${link_hostport##*:}"
                                out_wg_private_key=$(_mihomochain_urldecode "$link_userinfo")
                                out_type="wireguard"
                                if [[ -n "$link_query" ]]; then
                                    IFS='&' read -r -a _qarr <<< "$link_query"
                                    for kv in "${_qarr[@]}"; do
                                        k="${kv%%=*}"
                                        [[ "$kv" == *=* ]] && v="${kv#*=}" || v=""
                                        k=$(_mihomochain_urldecode "$k")
                                        v=$(_mihomochain_urldecode "$v")
                                        case "$k" in
                                            ip|address|local-address) out_wg_ip="$v" ;;
                                            ipv6) out_wg_ipv6="$v" ;;
                                            public-key|publickey|peer-public-key|peer_public_key) out_wg_public_key="$v" ;;
                                            pre-shared-key|preshared-key|presharedkey|pre_shared_key) out_wg_preshared_key="$v" ;;
                                            allowed-ips|allowedips|allowed_ips) out_wg_allowed_ips="$v" ;;
                                            reserved) out_wg_reserved="$v" ;;
                                            mtu) out_wg_mtu="$v" ;;
                                            persistent-keepalive|persistent_keepalive|keepalive) out_wg_keepalive="$v" ;;
                                        esac
                                    done
                                fi
                                out_wg_allowed_ips=$(_mihomoconf_trim "${out_wg_allowed_ips:-0.0.0.0/0,::/0}")
                                if [[ -z "$out_server" || -z "$out_wg_private_key" || -z "$out_wg_public_key" || -z "$out_wg_ip" ]] || ! _is_valid_port "$out_port"; then
                                    _error_no_exit "wireguard(Beta) 链接解析失败，需包含 server/port/private-key/public-key/ip"
                                    _press_any_key
                                    continue
                                fi
                                if [[ -n "$out_wg_mtu" ]] && { ! _is_digit "$out_wg_mtu" || [[ "$out_wg_mtu" -le 0 ]]; }; then
                                    _error_no_exit "wireguard(Beta) mtu 必须为正整数"
                                    _press_any_key
                                    continue
                                fi
                                if [[ -n "$out_wg_keepalive" ]] && { ! _is_digit "$out_wg_keepalive" || [[ "$out_wg_keepalive" -lt 0 ]]; }; then
                                    _error_no_exit "wireguard(Beta) persistent-keepalive 必须为非负整数"
                                    _press_any_key
                                    continue
                                fi
                                ;;
                            *)
                                _error_no_exit "暂不支持该链接类型，请使用 ss:// / hy2:// / hysteria2:// / anytls:// / wireguard://(Beta)"
                                _press_any_key
                                continue
                                ;;
                        esac
                        out_name=$(_mihomoconf_trim "${link_name:-}")
                        if [[ -z "$out_name" ]]; then
                            out_name=$(_mihomochain_default_outbound_name "$out_type" "$out_server" "$out_port")
                        fi
                        read -rp "  是否自定义出口节点名称? [y/N]: " rename_confirm
                        if [[ "$rename_confirm" =~ ^[Yy] ]]; then
                            read -rp "  出口节点名称 [默认 ${out_name}]: " custom_name_input
                            out_name=$(_mihomoconf_trim "${custom_name_input:-$out_name}")
                        fi
                        ;;
                    2)
                        _separator
                        _menu_pair "1" "ss" "" "green" "2" "hy2" "" "green"
                        _menu_pair "3" "anytls" "" "green" "4" "socks5" "" "green"
                        _menu_pair "5" "http" "" "green" "6" "wireguard (Beta)" "" "green"
                        _separator
                        local type_choice
                        read -rp "  出站类型 [1-6]: " type_choice
                        case "$type_choice" in
                            1) out_type="ss" ;;
                            2) out_type="hysteria2" ;;
                            3) out_type="anytls" ;;
                            4) out_type="socks5" ;;
                            5) out_type="http" ;;
                            6) out_type="wireguard" ;;
                            *) _error_no_exit "无效类型"; _press_any_key; continue ;;
                        esac
                        read -rp "  出口节点名称: " out_name
                        out_name=$(_mihomoconf_trim "${out_name:-}")
                        read -rp "  server: " out_server
                        read -rp "  port: " out_port
                        if [[ -z "$out_server" ]] || ! _is_valid_port "$out_port"; then
                            _error_no_exit "server/port 输入无效"
                            _press_any_key
                            continue
                        fi
                        case "$out_type" in
                            ss)
                                read -rp "  cipher [默认 aes-256-gcm]: " out_cipher
                                out_cipher="${out_cipher:-aes-256-gcm}"
                                read -rp "  password: " out_pass
                                if [[ -z "$out_pass" ]]; then
                                    _error_no_exit "ss password 不能为空"
                                    _press_any_key
                                    continue
                                fi
                                ;;
                            anytls)
                                read -rp "  password: " out_pass
                                read -rp "  sni/peer [可留空]: " out_sni
                                if [[ -z "$out_pass" ]]; then
                                    _error_no_exit "anytls password 不能为空"
                                    _press_any_key
                                    continue
                                fi
                                ;;
                            hysteria2)
                                read -rp "  password: " out_pass
                                read -rp "  sni/peer [可留空]: " out_sni
                                local hy2_insecure_input
                                read -rp "  insecure (跳过证书验证)? [y/N]: " hy2_insecure_input
                                [[ "$hy2_insecure_input" =~ ^[Yy] ]] && out_insecure="1" || out_insecure="0"
                                read -rp "  obfs [可留空，如 salamander]: " out_obfs
                                if [[ -n "$out_obfs" ]]; then
                                    read -rp "  obfs-password [可留空]: " out_obfs_pass
                                fi
                                read -rp "  mport [可留空]: " out_mport
                                if [[ -z "$out_pass" ]]; then
                                    _error_no_exit "hy2 password 不能为空"
                                    _press_any_key
                                    continue
                                fi
                                ;;
                            socks5|http)
                                read -rp "  username [可留空]: " out_user
                                read -rp "  password [可留空]: " out_pass
                                ;;
                            wireguard)
                                read -rp "  ip (本地地址, 如 172.16.0.2/32): " out_wg_ip
                                out_wg_ip=$(_mihomoconf_trim "${out_wg_ip:-}")
                                read -rp "  ipv6 [可留空]: " out_wg_ipv6
                                out_wg_ipv6=$(_mihomoconf_trim "${out_wg_ipv6:-}")
                                read -rp "  private-key: " out_wg_private_key
                                out_wg_private_key=$(_mihomoconf_trim "${out_wg_private_key:-}")
                                read -rp "  public-key: " out_wg_public_key
                                out_wg_public_key=$(_mihomoconf_trim "${out_wg_public_key:-}")
                                read -rp "  allowed-ips [默认 0.0.0.0/0,::/0]: " out_wg_allowed_ips
                                out_wg_allowed_ips=$(_mihomoconf_trim "${out_wg_allowed_ips:-0.0.0.0/0,::/0}")
                                read -rp "  pre-shared-key [可留空]: " out_wg_preshared_key
                                out_wg_preshared_key=$(_mihomoconf_trim "${out_wg_preshared_key:-}")
                                read -rp "  reserved [可留空，如 209,98,59]: " out_wg_reserved
                                out_wg_reserved=$(_mihomoconf_trim "${out_wg_reserved:-}")
                                read -rp "  mtu [可留空，如 1408]: " out_wg_mtu
                                out_wg_mtu=$(_mihomoconf_trim "${out_wg_mtu:-}")
                                read -rp "  persistent-keepalive [可留空]: " out_wg_keepalive
                                out_wg_keepalive=$(_mihomoconf_trim "${out_wg_keepalive:-}")
                                if [[ -z "$out_wg_ip" || -z "$out_wg_private_key" || -z "$out_wg_public_key" ]]; then
                                    _error_no_exit "wireguard ip/private-key/public-key 不能为空"
                                    _press_any_key
                                    continue
                                fi
                                if [[ -n "$out_wg_mtu" ]] && { ! _is_digit "$out_wg_mtu" || [[ "$out_wg_mtu" -le 0 ]]; }; then
                                    _error_no_exit "wireguard mtu 必须为正整数"
                                    _press_any_key
                                    continue
                                fi
                                if [[ -n "$out_wg_keepalive" ]] && { ! _is_digit "$out_wg_keepalive" || [[ "$out_wg_keepalive" -lt 0 ]]; }; then
                                    _error_no_exit "wireguard persistent-keepalive 必须为非负整数"
                                    _press_any_key
                                    continue
                                fi
                                ;;
                        esac
                        ;;
                esac

                if [[ -z "$out_name" ]]; then
                    _error_no_exit "出口节点名称不能为空"
                    _press_any_key
                    continue
                fi
                if [[ "$out_name" == *"|"* ]]; then
                    _error_no_exit "出口节点名称不能包含字符 |"
                    _press_any_key
                    continue
                fi
                if [[ "$out_name" == "$_MIHOMOCONF_IPV4_FORCE_PROXY_NAME" ]]; then
                    _error_no_exit "该名称为系统保留名称，请更换出口节点名称"
                    _press_any_key
                    continue
                fi

                if [[ "$out_name$out_server$out_cipher$out_user$out_pass$out_sni$out_obfs$out_obfs_pass$out_mport"\
"$out_wg_ip$out_wg_ipv6$out_wg_private_key$out_wg_public_key$out_wg_allowed_ips$out_wg_preshared_key$out_wg_reserved$out_wg_mtu$out_wg_keepalive" == *"|"* ]]; then
                    _error_no_exit "字段中不能包含字符 |"
                    _press_any_key
                    continue
                fi

                if ! out_tag=$(_mihomochain_outbound_tag_by_name "$out_name" 2>/dev/null); then
                    out_tag=$(_mihomochain_gen_outbound_tag)
                fi
                if ! _mihomochain_add_or_update_outbound \
                    "$out_tag" "$out_type" "$out_server" "$out_port" \
                    "${out_cipher:-}" "${out_user:-}" "${out_pass:-}" \
                    "${out_sni:-}" "${out_insecure:-0}" "${out_obfs:-}" "${out_obfs_pass:-}" "${out_mport:-}" "${out_name}" \
                    "${out_wg_ip:-}" "${out_wg_ipv6:-}" "${out_wg_private_key:-}" "${out_wg_public_key:-}" \
                    "${out_wg_allowed_ips:-}" "${out_wg_preshared_key:-}" "${out_wg_reserved:-}" "${out_wg_mtu:-}" "${out_wg_keepalive:-}"; then
                    _error_no_exit "保存出口节点失败"
                    _press_any_key
                    continue
                fi
                _info "出站节点已保存: ${out_name} (${out_type})"
                if ! _mihomochain_apply_and_restart; then
                    _warn "自动应用或重启失败，请检查日志后重试"
                fi
                _press_any_key
                ;;
            3)
                local listener_name in_tag out_name out_show_name out_tag listener_input out_input
                local li oi idx type server port cipher username password sni insecure obfs obfs_password mport
                local wg_ip wg_ipv6 wg_private_key wg_public_key wg_allowed_ips wg_preshared_key wg_reserved wg_mtu wg_keepalive
                local l_type l_name l_port l_cipher l_password l_user_id l_user_pass l_sni
                local l_hy2_up l_hy2_down l_hy2_ignore l_hy2_obfs l_hy2_obfs_password l_hy2_masquerade l_hy2_mport l_hy2_insecure l_listener_tag
                local -a listener_names outbound_names outbound_show_names

                printf "  ${BOLD}可用入站节点:${PLAIN}\n"
                _separator
                idx=0
                while IFS=$'\x1f' read -r l_type l_name l_port l_cipher l_password l_user_id l_user_pass l_sni \
                    l_hy2_up l_hy2_down l_hy2_ignore l_hy2_obfs l_hy2_obfs_password l_hy2_masquerade l_hy2_mport l_hy2_insecure l_listener_tag; do
                    [[ -z "${l_name:-}" ]] && continue
                    listener_names+=("$l_name")
                    idx=$((idx + 1))
                    printf "      [%d] %s (type=%s, port=%s)\n" "$idx" "$l_name" "$l_type" "${l_port:-N/A}"
                done < <(_mihomoconf_read_listener_rows "$config_file")
                if (( ${#listener_names[@]} == 0 )); then
                    _warn "未读取到 listeners 节点"
                    _press_any_key
                    continue
                fi

                printf "  ${BOLD}可用出口节点:${PLAIN}\n"
                _separator
                idx=0
                while IFS=$'\x1f' read -r out_name type server port cipher username password sni insecure obfs obfs_password mport \
                    wg_ip wg_ipv6 wg_private_key wg_public_key wg_allowed_ips wg_preshared_key wg_reserved wg_mtu wg_keepalive; do
                    [[ -z "${out_name:-}" ]] && continue
                    [[ "$out_name" == "$_MIHOMOCONF_IPV4_FORCE_PROXY_NAME" ]] && continue
                    out_show_name=$(_mihomochain_display_name "$out_name")
                    outbound_names+=("$out_name")
                    outbound_show_names+=("$out_show_name")
                    idx=$((idx + 1))
                    case "$type" in
                        wireguard|wg)
                            if [[ -n "${wg_ip:-}" ]]; then
                                printf "      [%d] %s (type=wireguard, %s:%s, ip=%s)\n" "$idx" "$out_show_name" "$server" "$port" "$wg_ip"
                            else
                                printf "      [%d] %s (type=wireguard, %s:%s)\n" "$idx" "$out_show_name" "$server" "$port"
                            fi
                            ;;
                        *)
                            if [[ -n "${sni:-}" ]]; then
                                printf "      [%d] %s (type=%s, %s:%s, sni=%s)\n" "$idx" "$out_show_name" "$type" "$server" "$port" "$sni"
                            else
                                printf "      [%d] %s (type=%s, %s:%s)\n" "$idx" "$out_show_name" "$type" "$server" "$port"
                            fi
                            ;;
                    esac
                done < <(_mihomochain_read_proxy_rows "$config_file")
                if (( ${#outbound_names[@]} == 0 )); then
                    _warn "暂无落地节点/二层代理"
                    _press_any_key
                    continue
                fi

                read -rp "  选择入站节点 [序号]: " listener_input
                read -rp "  选择出口节点 [序号]: " out_input
                listener_input=$(_mihomoconf_trim "${listener_input:-}")
                out_input=$(_mihomoconf_trim "${out_input:-}")
                if [[ -z "$listener_input" || -z "$out_input" ]]; then
                    _error_no_exit "输入不能为空"
                    _press_any_key
                    continue
                fi
                if [[ ! "$listener_input" =~ ^[0-9]+$ ]] || [[ ! "$out_input" =~ ^[0-9]+$ ]]; then
                    _error_no_exit "请输入有效序号"
                    _press_any_key
                    continue
                fi
                li=$((10#$listener_input))
                oi=$((10#$out_input))
                if (( li < 1 || li > ${#listener_names[@]} )); then
                    _error_no_exit "入站序号超出范围: ${listener_input}"
                    _press_any_key
                    continue
                fi
                if (( oi < 1 || oi > ${#outbound_names[@]} )); then
                    _error_no_exit "出口序号超出范围: ${out_input}"
                    _press_any_key
                    continue
                fi
                listener_name="${listener_names[$((li - 1))]}"
                out_name="${outbound_names[$((oi - 1))]}"
                out_show_name="${outbound_show_names[$((oi - 1))]}"

                if ! in_tag=$(_mihomochain_listener_tag_by_name "$config_file" "$listener_name" 2>/dev/null); then
                    _error_no_exit "入站节点不存在: ${listener_name}"
                    _press_any_key
                    continue
                fi
                if ! out_tag=$(_mihomochain_outbound_tag_by_name "$out_name" 2>/dev/null); then
                    _error_no_exit "出口节点不存在: ${out_name}"
                    _press_any_key
                    continue
                fi
                if ! _mihomochain_add_or_update_rule "$in_tag" "$out_tag"; then
                    _error_no_exit "规则保存失败，请检查入站与出口配置"
                    _press_any_key
                    continue
                fi
                _info "规则已保存: ${listener_name} -> ${out_show_name}"
                if ! _mihomochain_apply_and_restart; then
                    _warn "自动应用或重启失败，请检查日志后重试"
                fi
                _press_any_key
                ;;
            4)
                local user_listener_tag user_listener_name user_name out_name out_show_name out_tag
                local listener_pick user_pick out_pick li ui oi idx type server port cipher username password sni insecure obfs obfs_password mport
                local wg_ip wg_ipv6 wg_private_key wg_public_key wg_allowed_ips wg_preshared_key wg_reserved wg_mtu wg_keepalive
                local l_type l_name l_port l_cipher l_password l_user_id l_user_pass l_sni
                local l_hy2_up l_hy2_down l_hy2_ignore l_hy2_obfs l_hy2_obfs_password l_hy2_masquerade l_hy2_mport l_hy2_insecure l_listener_tag
                local u_name u_pass user_count
                local -a listener_tags listener_names
                local -a listener_users outbound_names outbound_show_names

                printf "  ${BOLD}可用入站节点:${PLAIN}\n"
                _separator
                idx=0
                while IFS=$'\x1f' read -r l_type l_name l_port l_cipher l_password l_user_id l_user_pass l_sni \
                    l_hy2_up l_hy2_down l_hy2_ignore l_hy2_obfs l_hy2_obfs_password l_hy2_masquerade l_hy2_mport l_hy2_insecure l_listener_tag; do
                    [[ -z "${l_name:-}" ]] && continue
                    l_listener_tag="${l_listener_tag:-$l_name}"
                    user_count=0
                    while IFS=$'\x1f' read -r u_name u_pass; do
                        [[ -z "${u_name:-}" ]] && continue
                        user_count=$((user_count + 1))
                    done < <(_mihomoconf_read_users_by_tag "$config_file" "$l_listener_tag")
                    (( user_count > 0 )) || continue
                    listener_tags+=("$l_listener_tag")
                    listener_names+=("$l_name")
                    idx=$((idx + 1))
                    printf "      [%d] %s (type=%s, port=%s, users=%s)\n" \
                        "$idx" "$l_name" "$l_type" "${l_port:-N/A}" "$user_count"
                done < <(_mihomoconf_read_listener_rows "$config_file")
                if (( ${#listener_tags[@]} == 0 )); then
                    _warn "未读取到可绑定用户的入站节点"
                    _press_any_key
                    continue
                fi

                read -rp "  选择入站节点 [序号]: " listener_pick
                listener_pick=$(_mihomoconf_trim "${listener_pick:-}")
                if [[ -z "$listener_pick" || ! "$listener_pick" =~ ^[0-9]+$ ]]; then
                    _error_no_exit "请输入有效序号"
                    _press_any_key
                    continue
                fi
                li=$((10#$listener_pick))
                if (( li < 1 || li > ${#listener_tags[@]} )); then
                    _error_no_exit "入站节点序号超出范围: ${listener_pick}"
                    _press_any_key
                    continue
                fi
                user_listener_tag="${listener_tags[$((li - 1))]}"
                user_listener_name="${listener_names[$((li - 1))]}"

                printf "  ${BOLD}%s 的用户列表:${PLAIN}\n" "$user_listener_name"
                _separator
                idx=0
                listener_users=()
                while IFS=$'\x1f' read -r u_name u_pass; do
                    [[ -z "${u_name:-}" ]] && continue
                    listener_users+=("$u_name")
                    idx=$((idx + 1))
                    printf "      [%d] %s\n" "$idx" "$u_name"
                done < <(_mihomoconf_read_users_by_tag "$config_file" "$user_listener_tag")
                if (( ${#listener_users[@]} == 0 )); then
                    _warn "该入站没有可用用户"
                    _press_any_key
                    continue
                fi

                read -rp "  选择用户 [序号]: " user_pick
                user_pick=$(_mihomoconf_trim "${user_pick:-}")
                if [[ -z "$user_pick" || ! "$user_pick" =~ ^[0-9]+$ ]]; then
                    _error_no_exit "请输入有效序号"
                    _press_any_key
                    continue
                fi
                ui=$((10#$user_pick))
                if (( ui < 1 || ui > ${#listener_users[@]} )); then
                    _error_no_exit "用户序号超出范围: ${user_pick}"
                    _press_any_key
                    continue
                fi
                user_name="${listener_users[$((ui - 1))]}"

                printf "  ${BOLD}可用出口节点:${PLAIN}\n"
                _separator
                idx=0
                while IFS=$'\x1f' read -r out_name type server port cipher username password sni insecure obfs obfs_password mport \
                    wg_ip wg_ipv6 wg_private_key wg_public_key wg_allowed_ips wg_preshared_key wg_reserved wg_mtu wg_keepalive; do
                    [[ -z "${out_name:-}" ]] && continue
                    [[ "$out_name" == "$_MIHOMOCONF_IPV4_FORCE_PROXY_NAME" ]] && continue
                    out_show_name=$(_mihomochain_display_name "$out_name")
                    outbound_names+=("$out_name")
                    outbound_show_names+=("$out_show_name")
                    idx=$((idx + 1))
                    case "$type" in
                        wireguard|wg)
                            if [[ -n "${wg_ip:-}" ]]; then
                                printf "      [%d] %s (type=wireguard, %s:%s, ip=%s)\n" "$idx" "$out_show_name" "$server" "$port" "$wg_ip"
                            else
                                printf "      [%d] %s (type=wireguard, %s:%s)\n" "$idx" "$out_show_name" "$server" "$port"
                            fi
                            ;;
                        *)
                            if [[ -n "${sni:-}" ]]; then
                                printf "      [%d] %s (type=%s, %s:%s, sni=%s)\n" "$idx" "$out_show_name" "$type" "$server" "$port" "$sni"
                            else
                                printf "      [%d] %s (type=%s, %s:%s)\n" "$idx" "$out_show_name" "$type" "$server" "$port"
                            fi
                            ;;
                    esac
                done < <(_mihomochain_read_proxy_rows "$config_file")
                if (( ${#outbound_names[@]} == 0 )); then
                    _warn "暂无落地节点/二层代理"
                    _press_any_key
                    continue
                fi

                read -rp "  选择出口节点 [序号]: " out_pick
                out_pick=$(_mihomoconf_trim "${out_pick:-}")
                if [[ -z "$out_pick" || ! "$out_pick" =~ ^[0-9]+$ ]]; then
                    _error_no_exit "请输入有效序号"
                    _press_any_key
                    continue
                fi
                oi=$((10#$out_pick))
                if (( oi < 1 || oi > ${#outbound_names[@]} )); then
                    _error_no_exit "出口序号超出范围: ${out_pick}"
                    _press_any_key
                    continue
                fi
                out_name="${outbound_names[$((oi - 1))]}"
                out_show_name="${outbound_show_names[$((oi - 1))]}"

                if ! out_tag=$(_mihomochain_outbound_tag_by_name "$out_name" 2>/dev/null); then
                    _error_no_exit "出口节点不存在: ${out_show_name}"
                    _press_any_key
                    continue
                fi
                if ! _mihomochain_add_or_update_user_rule "$user_listener_tag" "$user_name" "$out_tag"; then
                    _error_no_exit "规则保存失败，可能是 user 不属于该入站或出口不存在"
                    _press_any_key
                    continue
                fi
                _info "规则已保存: ${user_listener_name}[user=${user_name}] -> ${out_show_name}"
                if ! _mihomochain_apply_and_restart; then
                    _warn "自动应用或重启失败，请检查日志后重试"
                fi
                _press_any_key
                ;;
            5)
                printf "  ${BOLD}当前出口节点:${PLAIN}\n"
                _separator
                local rm_out_idx=0 type server port cipher username password sni insecure obfs obfs_password mport out_name out_show_name
                local wg_ip wg_ipv6 wg_private_key wg_public_key wg_allowed_ips wg_preshared_key wg_reserved wg_mtu wg_keepalive
                local -a rm_out_names rm_out_show_names rm_out_tags
                while IFS=$'\x1f' read -r out_name type server port cipher username password sni insecure obfs obfs_password mport \
                    wg_ip wg_ipv6 wg_private_key wg_public_key wg_allowed_ips wg_preshared_key wg_reserved wg_mtu wg_keepalive; do
                    [[ -z "${out_name:-}" ]] && continue
                    [[ "$out_name" == "$_MIHOMOCONF_IPV4_FORCE_PROXY_NAME" ]] && continue
                    out_show_name=$(_mihomochain_display_name "$out_name")
                    rm_out_names+=("$out_name")
                    rm_out_show_names+=("$out_show_name")
                    rm_out_tags+=("$out_name")
                    rm_out_idx=$((rm_out_idx + 1))
                    case "$type" in
                        wireguard|wg)
                            if [[ -n "${wg_ip:-}" ]]; then
                                printf "      [%d] %s (type=wireguard, %s:%s, ip=%s)\n" "$rm_out_idx" "$out_show_name" "$server" "$port" "$wg_ip"
                            else
                                printf "      [%d] %s (type=wireguard, %s:%s)\n" "$rm_out_idx" "$out_show_name" "$server" "$port"
                            fi
                            ;;
                        *)
                            if [[ -n "${sni:-}" ]]; then
                                printf "      [%d] %s (type=%s, %s:%s, sni=%s)\n" "$rm_out_idx" "$out_show_name" "$type" "$server" "$port" "$sni"
                            else
                                printf "      [%d] %s (type=%s, %s:%s)\n" "$rm_out_idx" "$out_show_name" "$type" "$server" "$port"
                            fi
                            ;;
                    esac
                done < <(_mihomochain_read_proxy_rows "$config_file")
                if (( rm_out_idx == 0 )); then
                    _warn "暂无可删除的出口节点"
                    _press_any_key
                    continue
                fi

                local rm_pick rm_out_name rm_out_show_name rm_out_tag
                read -rp "  选择要删除的出口节点 [序号]: " rm_pick
                rm_pick=$(_mihomoconf_trim "${rm_pick:-}")
                if [[ -z "$rm_pick" ]]; then
                    _error_no_exit "输入不能为空"
                    _press_any_key
                    continue
                fi
                if [[ ! "$rm_pick" =~ ^[0-9]+$ ]]; then
                    _error_no_exit "请输入有效序号"
                    _press_any_key
                    continue
                fi
                rm_pick=$((10#$rm_pick))
                if (( rm_pick < 1 || rm_pick > rm_out_idx )); then
                    _error_no_exit "序号超出范围: ${rm_pick}"
                    _press_any_key
                    continue
                fi
                rm_out_name="${rm_out_names[$((rm_pick - 1))]}"
                rm_out_show_name="${rm_out_show_names[$((rm_pick - 1))]}"
                rm_out_tag="${rm_out_tags[$((rm_pick - 1))]}"
                if ! _mihomochain_remove_outbound "$rm_out_tag"; then
                    _error_no_exit "删除出口节点失败: ${rm_out_show_name}"
                    _press_any_key
                    continue
                fi
                _info "已删除出口节点及其关联规则: ${rm_out_show_name}"
                if ! _mihomochain_apply_and_restart; then
                    _warn "自动应用或重启失败，请检查日志后重试"
                fi
                _press_any_key
                ;;
            6)
                printf "  ${BOLD}当前规则:${PLAIN}\n"
                _separator
                local rule_idx=0 kind rule_left out_name in_name in_user out_show_name
                local -a rule_types rule_in_names rule_keys rule_users
                while IFS=$'\x1f' read -r kind rule_left out_name; do
                    [[ -z "${kind:-}" ]] && continue
                    case "$kind" in
                        RULE_NAME)
                            in_name="$rule_left"
                            in_user=""
                            ;;
                        RULE_USER)
                            in_user="$rule_left"
                            in_name=$(_mihomochain_listener_name_by_user "$config_file" "$in_user")
                            ;;
                        *)
                            continue
                            ;;
                    esac
                    out_show_name=$(_mihomochain_display_name "$out_name")
                    rule_types+=("$kind")
                    rule_in_names+=("$in_name")
                    rule_keys+=("$rule_left")
                    rule_users+=("$in_user")
                    rule_idx=$((rule_idx + 1))
                    if [[ "$kind" == "RULE_USER" ]]; then
                        printf "      [%d] %s [user=%s]  ${DIM}-->${PLAIN}  %s\n" "$rule_idx" "$in_name" "$in_user" "$out_show_name"
                    else
                        printf "      [%d] %s  ${DIM}-->${PLAIN}  %s\n" "$rule_idx" "$in_name" "$out_show_name"
                    fi
                done < <(_mihomochain_read_rules_from_config "$config_file")
                if (( rule_idx == 0 )); then
                    _warn "暂无可删除的绑定规则"
                    _press_any_key
                    continue
                fi

                local rm_rule_input rm_idx rm_key rm_listener_name rm_kind rm_user
                read -rp "  选择要删除的规则 [序号]: " rm_rule_input
                rm_rule_input=$(_mihomoconf_trim "${rm_rule_input:-}")
                if [[ -z "$rm_rule_input" ]]; then
                    _error_no_exit "输入不能为空"
                    _press_any_key
                    continue
                fi
                if [[ ! "$rm_rule_input" =~ ^[0-9]+$ ]]; then
                    _error_no_exit "请输入有效序号"
                    _press_any_key
                    continue
                fi
                rm_idx=$((10#$rm_rule_input))
                if (( rm_idx < 1 || rm_idx > rule_idx )); then
                    _error_no_exit "序号超出范围: ${rm_rule_input}"
                    _press_any_key
                    continue
                fi
                rm_kind="${rule_types[$((rm_idx - 1))]}"
                rm_key="${rule_keys[$((rm_idx - 1))]}"
                rm_listener_name="${rule_in_names[$((rm_idx - 1))]}"
                rm_user="${rule_users[$((rm_idx - 1))]}"
                if [[ "$rm_kind" == "RULE_USER" ]]; then
                    if ! _mihomochain_remove_user_rule "$rm_key" "$rm_user"; then
                        _error_no_exit "删除规则失败: ${rm_listener_name}[user=${rm_user}]"
                        _press_any_key
                        continue
                    fi
                    _info "规则已删除: ${rm_listener_name}[user=${rm_user}] -> *"
                else
                    if ! _mihomochain_remove_rule "$rm_key"; then
                        _error_no_exit "删除规则失败: ${rm_listener_name}"
                        _press_any_key
                        continue
                    fi
                    _info "规则已删除: ${rm_listener_name} -> *"
                fi
                if ! _mihomochain_apply_and_restart; then
                    _warn "自动应用或重启失败，请检查日志后重试"
                fi
                _press_any_key
                ;;
            7)
                local add_listener_pick add_listener_tag add_listener_name add_listener_type
                local add_listener_cipher
                local add_username add_password add_overwrite add_result add_action
                local idx li user_count l_type l_name l_port l_cipher l_password l_user_id l_user_pass l_sni
                local l_hy2_up l_hy2_down l_hy2_ignore l_hy2_obfs l_hy2_obfs_password l_hy2_masquerade l_hy2_mport l_hy2_insecure l_listener_tag
                local u_name u_pass
                local -a add_listener_tags add_listener_names add_listener_types add_listener_ciphers

                printf "  ${BOLD}可新增用户的入站节点:${PLAIN}\n"
                _separator
                idx=0
                while IFS=$'\x1f' read -r l_type l_name l_port l_cipher l_password l_user_id l_user_pass l_sni \
                    l_hy2_up l_hy2_down l_hy2_ignore l_hy2_obfs l_hy2_obfs_password l_hy2_masquerade l_hy2_mport l_hy2_insecure l_listener_tag; do
                    [[ -z "${l_name:-}" ]] && continue
                    case "$l_type" in
                        shadowsocks|anytls|hysteria2|hy2) ;;
                        *) continue ;;
                    esac
                    l_listener_tag="${l_listener_tag:-$l_name}"
                    user_count=0
                    while IFS=$'\x1f' read -r u_name u_pass; do
                        [[ -z "${u_name:-}" ]] && continue
                        user_count=$((user_count + 1))
                    done < <(_mihomoconf_read_users_by_tag "$config_file" "$l_listener_tag")
                    add_listener_tags+=("$l_listener_tag")
                    add_listener_names+=("$l_name")
                    add_listener_types+=("$l_type")
                    add_listener_ciphers+=("$l_cipher")
                    idx=$((idx + 1))
                    printf "      [%d] %s (type=%s, port=%s, users=%s)\n" \
                        "$idx" "$l_name" "$l_type" "${l_port:-N/A}" "$user_count"
                done < <(_mihomoconf_read_listener_rows "$config_file")
                if (( ${#add_listener_tags[@]} == 0 )); then
                    _warn "未找到支持 users 的入站节点 (SS2022/AnyTLS/HY2)"
                    _press_any_key
                    continue
                fi

                read -rp "  选择入站节点 [序号]: " add_listener_pick
                add_listener_pick=$(_mihomoconf_trim "${add_listener_pick:-}")
                if [[ -z "$add_listener_pick" || ! "$add_listener_pick" =~ ^[0-9]+$ ]]; then
                    _error_no_exit "请输入有效序号"
                    _press_any_key
                    continue
                fi
                li=$((10#$add_listener_pick))
                if (( li < 1 || li > ${#add_listener_tags[@]} )); then
                    _error_no_exit "入站节点序号超出范围: ${add_listener_pick}"
                    _press_any_key
                    continue
                fi
                add_listener_tag="${add_listener_tags[$((li - 1))]}"
                add_listener_name="${add_listener_names[$((li - 1))]}"
                add_listener_type="${add_listener_types[$((li - 1))]}"
                add_listener_cipher="${add_listener_ciphers[$((li - 1))]}"

                read -rp "  新用户名: " add_username
                add_username=$(_mihomoconf_trim "${add_username:-}")
                if [[ -z "$add_username" ]]; then
                    _error_no_exit "用户名不能为空"
                    _press_any_key
                    continue
                fi
                if ! _mihomoconf_is_valid_username "$add_username"; then
                    _error_no_exit "用户名无效，仅支持字母/数字/.-_"
                    _press_any_key
                    continue
                fi

                add_action="新增"
                if _mihomoconf_listener_has_user "$config_file" "$add_listener_tag" "$add_username"; then
                    add_action="更新"
                    read -rp "  用户已存在，将更新密码，是否继续? [Y/n]: " add_overwrite
                    add_overwrite=$(_mihomoconf_trim "${add_overwrite:-Y}")
                    if [[ "$add_overwrite" =~ ^[Nn]$ ]]; then
                        _info "已取消"
                        _press_any_key
                        continue
                    fi
                fi

                read -rp "  用户密码 [留空自动生成]: " add_password
                add_password=$(_mihomoconf_trim "${add_password:-}")
                if [[ -z "$add_password" ]]; then
                    if [[ "$add_listener_type" == "shadowsocks" ]]; then
                        add_password=$(_mihomoconf_gen_ss_password_for_cipher "$add_listener_cipher")
                    else
                        add_password=$(_mihomoconf_gen_anytls_password)
                    fi
                    _info "已自动生成密码: ${add_password}"
                fi

                _mihomoconf_add_or_update_listener_user "$config_file" "$add_listener_tag" "$add_username" "$add_password"
                add_result=$?
                if [[ "$add_result" -ne 0 ]]; then
                    case "$add_result" in
                        2) _error_no_exit "未找到入站节点: ${add_listener_name}" ;;
                        3) _error_no_exit "入站类型 ${add_listener_type} 不支持 users（仅支持 SS2022/AnyTLS/HY2）" ;;
                        *) _error_no_exit "用户写入失败，请检查配置格式后重试" ;;
                    esac
                    _press_any_key
                    continue
                fi

                _info "已${add_action}用户: ${add_listener_name}[user=${add_username}]"
                _info "可使用 [4] 将该用户绑定到指定出口节点"
                if ! _mihomochain_apply_and_restart; then
                    _warn "自动应用或重启失败，请检查日志后重试"
                fi
                _press_any_key
                ;;
            0) return ;;
            *)
                _error_no_exit "无效选项"
                sleep 1
                ;;
        esac
    done
}

_mihomo_ipv4_google_manage() {
    local config_file="$_MIHOMOCONF_CONFIG_FILE"
    if [[ ! -f "$config_file" ]]; then
        _error_no_exit "未找到配置文件: ${config_file}"
        _info "请先在 Mihomo 菜单中生成基础配置"
        _press_any_key
        return
    fi

    while true; do
        local pref new_pref
        pref=$(_mihomoconf_ipv4_google_pref_get "$config_file")
        _header "Gemini/Google IPv4 定向"
        _info "配置文件: ${config_file}"
        _info "用途: 解决出站 IP 不一致导致 Gemini 无法访问"
        if [[ "$pref" == "on" ]]; then
            _info "当前状态: 已启用"
        else
            _info "当前状态: 未启用"
        fi
        _separator
        _menu_pair "1" "启用" "gemini.google.com / www.google.com 走 IPv4" "green" "2" "关闭" "恢复默认链路" "yellow"
        _menu_item "0" "返回上级菜单" "" "red"
        _separator

        local ch
        read -rp "  选择 [0-2]: " ch
        case "$ch" in
            1) new_pref="on" ;;
            2) new_pref="off" ;;
            0) return ;;
            *) _error_no_exit "无效选项"; sleep 1; continue ;;
        esac

        _mihomoconf_ipv4_google_pref_set "$config_file" "$new_pref"
        _mihomoconf_apply_ipv4_google_policy "$config_file"
        _mihomoconf_force_rule_mode "$config_file"
        _mihomoconf_ensure_match_direct_rule "$config_file"
        if ! _mihomo_restart_now; then
            _warn "自动重启失败，请检查日志后重试"
        else
            if [[ "$new_pref" == "on" ]]; then
                _success "已启用 Gemini/Google IPv4 定向并实时生效"
            else
                _success "已关闭 Gemini/Google IPv4 定向并实时生效"
            fi
        fi
        _press_any_key
    done
}

_mihomo_manage() {
    while true; do
        _header "Mihomo 管理"
        local config_dir="$_MIHOMOCONF_CONFIG_DIR"
        local config_file="$_MIHOMOCONF_CONFIG_FILE"

        if command -v mihomo >/dev/null 2>&1; then
            local ver
            ver=$(mihomo -v 2>/dev/null | head -1)
            _info "当前版本: ${ver:-未知}"
            local pid
            pid=$(pgrep -x mihomo 2>/dev/null || true)
            if [[ -n "$pid" ]]; then
                printf "${GREEN}  ✔ ${PLAIN}运行状态: ${GREEN}运行中${PLAIN} (PID: $pid)\n"
            else
                printf "${GREEN}  ✔ ${PLAIN}运行状态: ${RED}未运行${PLAIN}\n"
            fi
        else
            _info "当前未安装 mihomo"
        fi
        _info "配置目录: ${config_dir}"
        _info "配置文件: ${config_file}"
        if [[ -f "$config_file" ]]; then
            printf "${GREEN}  ✔ ${PLAIN}配置状态: ${GREEN}已存在${PLAIN}\n"
        else
            printf "${GREEN}  ✔ ${PLAIN}配置状态: ${YELLOW}不存在${PLAIN} (可通过选项 2 生成)\n"
        fi

        _separator
        _menu_pair "1" "安装/更新 Mihomo" "" "green" "2" "生成配置" "SS2022 / AnyTLS / HY2" "green"
        _menu_pair "3" "配置自启并启动" "" "green" "4" "重启 Mihomo" "" "green"
        _menu_pair "5" "查看日志" "" "green" "6" "读取配置并生成节点" "" "green"
        _menu_pair "7" "服务端链式代理" "" "green" "8" "Gemini/Google IPv4 定向" "可选" "green"
        _menu_pair "9" "卸载 Mihomo" "可选删除配置" "yellow" "0" "返回主菜单" "" "red"
        _separator

        local choice
        read -rp "  选择 [0-9]: " choice
        case "$choice" in
            1) _mihomo_setup ;;
            2) _mihomoconf_setup ;;
            3) _mihomo_enable ;;
            4) _mihomo_restart ;;
            5) _mihomo_log ;;
            6) _mihomo_read_config ;;
            7) _mihomo_chain_proxy_manage ;;
            8) _mihomo_ipv4_google_manage ;;
            9) _mihomo_uninstall ;;
            0) return ;;
            *) _error_no_exit "无效选项"; sleep 1 ;;
        esac
    done
}

# --- 5. iPerf3 测速服务端 ---

_iperf3_check() {
    if command -v iperf3 >/dev/null 2>&1; then
        _info "iperf3 版本: $(iperf3 --version 2>&1 | head -1)"
        return 0
    fi

    _warn "未检测到 iperf3，正在尝试自动安装..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq && apt-get install -y -qq iperf3
    elif command -v yum >/dev/null 2>&1; then
        yum install -y iperf3
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y iperf3
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm iperf3
    elif command -v apk >/dev/null 2>&1; then
        apk add iperf3
    elif command -v zypper >/dev/null 2>&1; then
        zypper install -y iperf3
    else
        _error_no_exit "无法识别包管理器，请手动安装 iperf3"
        return 1
    fi

    if ! command -v iperf3 >/dev/null 2>&1; then
        _error_no_exit "iperf3 安装失败，请手动安装"
        return 1
    fi
    _info "iperf3 安装成功"
    return 0
}

_iperf3_get_public_ip() {
    local ip=""
    for url in "https://api.ipify.org" "https://ifconfig.me" "https://icanhazip.com"; do
        ip="$(curl -4 -s --max-time 3 "$url" 2>/dev/null || true)"
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            printf '%s' "$ip"
            return
        fi
    done
    printf '%s' ""
}

_iperf3_get_local_ip() {
    local ip=""
    if command -v ip >/dev/null 2>&1; then
        ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)"
    fi
    if [ -z "$ip" ] && command -v ifconfig >/dev/null 2>&1; then
        ip="$(ifconfig 2>/dev/null | awk '/inet / && !/127\.0\.0\.1/ {print $2; exit}' | sed 's/addr://')"
    fi
    printf '%s' "${ip:-unknown}"
}

_iperf3_check_port() {
    local port="$1"
    local pid
    if command -v lsof >/dev/null 2>&1; then
        pid="$(lsof -ti :"$port" 2>/dev/null || true)"
    elif command -v ss >/dev/null 2>&1; then
        pid="$(ss -tlnp "sport = :$port" 2>/dev/null | awk 'NR>1{match($0,/pid=([0-9]+)/,m); if(m[1]) print m[1]}' | head -1)"
    else
        _warn "lsof 和 ss 均不可用，无法检测端口占用"
        return 0
    fi
    [ -z "$pid" ] && return 0

    local proc_info
    proc_info="$(ps -p "$pid" -o pid=,comm= 2>/dev/null || echo "$pid unknown")"
    _warn "端口 $port 已被占用 (PID: $proc_info)"
    _separator
    _menu_pair "1" "终止占用进程并继续" "" "green" "2" "更换端口" "" "green"
    _menu_item "0" "返回" "" "red"
    _separator
    local action
    read -rp "  选择 [0-2]: " action
    case "$action" in
        1)
            kill "$pid" 2>/dev/null || true
            sleep 1
            if lsof -ti :"$port" >/dev/null 2>&1; then
                kill -9 "$pid" 2>/dev/null || true
                sleep 1
            fi
            if lsof -ti :"$port" >/dev/null 2>&1; then
                _error_no_exit "无法终止占用端口 $port 的进程"
                return 1
            fi
            _info "已终止进程 $pid"
            return 0
            ;;
        2)
            local new_port
            read -rp "  新端口号: " new_port
            if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
                _error_no_exit "端口号无效 (1-65535)"
                return 1
            fi
            # 通过全局变量返回新端口
            _IPERF3_PORT="$new_port"
            _iperf3_check_port "$new_port"
            return $?
            ;;
        0) return 1 ;;
        *) _error_no_exit "无效选项"; return 1 ;;
    esac
}

_iperf3_setup() {
    _header "iperf3 测速服务端"

    if ! _iperf3_check; then
        _press_any_key
        return
    fi

    printf "  ${BOLD}请选择操作${PLAIN}\n"
    _separator
    _menu_pair "1" "启动 iperf3 服务端" "" "green" "0" "返回主菜单" "" "red"
    _separator
    local choice
    read -rp "  选择 [0-1]: " choice
    case "$choice" in
        1) ;;
        0) return ;;
        *) _error_no_exit "无效选项"; _press_any_key; return ;;
    esac

    # 配置端口
    _IPERF3_PORT=5201
    local port_input
    read -rp "  监听端口 [默认 5201]: " port_input
    _IPERF3_PORT="${port_input:-5201}"
    if ! [[ "$_IPERF3_PORT" =~ ^[0-9]+$ ]] || [ "$_IPERF3_PORT" -lt 1 ] || [ "$_IPERF3_PORT" -gt 65535 ]; then
        _error_no_exit "端口号无效 (1-65535)"
        _press_any_key
        return
    fi

    # 检查端口占用
    if ! _iperf3_check_port "$_IPERF3_PORT"; then
        _press_any_key
        return
    fi

    # 获取 IP
    local local_ip public_ip
    local_ip="$(_iperf3_get_local_ip)"
    public_ip="$(_iperf3_get_public_ip)"

    # 启动服务端
    iperf3 -s -p "$_IPERF3_PORT" &
    local iperf_pid=$!
    _info "iperf3 已启动 (PID: $iperf_pid)"

    # 显示连接信息
    echo ""
    printf "  ${BOLD}服务端信息${PLAIN}\n"
    _separator
    printf "    监听端口 : %s\n" "$_IPERF3_PORT"
    if [ -n "$public_ip" ]; then
        printf "    公网地址 : %s\n" "$public_ip"
    fi
    echo ""
    printf "  ${BOLD}客户端连接命令:${PLAIN}\n"
    _separator
    printf "    ${GREEN}iperf3 -c %s -p %s${PLAIN}\n" "${public_ip:-$local_ip}" "$_IPERF3_PORT"
    if [ -n "$public_ip" ] && [ "$local_ip" != "$public_ip" ]; then
        printf "    ${DIM}局域网: iperf3 -c %s -p %s${PLAIN}\n" "$local_ip" "$_IPERF3_PORT"
    fi
    echo ""
    _info "按 Ctrl+C 停止服务端"
    echo ""

    # 等待服务端进程，Ctrl+C 时清理
    trap 'kill "$iperf_pid" 2>/dev/null; wait "$iperf_pid" 2>/dev/null; _info "iperf3 已关闭"' INT
    wait "$iperf_pid" 2>/dev/null || true
    trap - INT

    _press_any_key
}

# --- 6. NodeQuality 测试 ---

_nodequality_setup() {
    _header "NodeQuality 网络质量测试"

    if ! command -v curl >/dev/null 2>&1; then
        _error_no_exit "需要 curl 命令，请先安装"
        _press_any_key
        return
    fi

    echo ""
    _info "正在运行 NodeQuality 测试脚本..."
    _separator
    echo ""
    bash <(curl -sL https://run.NodeQuality.com)
    echo ""
    _press_any_key
}

# --- 10. Sing-Box 管理 ---

_SINGBOX_SERVICE_NAME="sing-box"
_SINGBOX_SYSTEMD_SERVICE_FILE="/etc/systemd/system/${_SINGBOX_SERVICE_NAME}.service"
_SINGBOX_OPENRC_SERVICE_FILE="/etc/init.d/${_SINGBOX_SERVICE_NAME}"
_SINGBOX_LOG_FILE="/var/log/sing-box.log"
_SINGBOX_ERR_FILE="/var/log/sing-box.error.log"

_singbox_running_pid() {
    local pid=""
    local pid_file="/run/${_SINGBOX_SERVICE_NAME}.pid"

    if [[ -f "$pid_file" ]]; then
        pid=$(tr -cd '0-9' < "$pid_file" 2>/dev/null || true)
        if _is_digit "${pid:-}" && kill -0 "$pid" >/dev/null 2>&1; then
            printf '%s' "$pid"
            return 0
        fi
    fi

    if command -v pgrep >/dev/null 2>&1; then
        pid=$(pgrep -x sing-box 2>/dev/null | head -n1 || true)
        [[ -z "$pid" ]] && pid=$(pgrep sing-box 2>/dev/null | head -n1 || true)
        if _is_digit "${pid:-}" && kill -0 "$pid" >/dev/null 2>&1; then
            printf '%s' "$pid"
            return 0
        fi
    fi
    return 1
}

_singbox_systemd_service_configured() {
    _has_systemd || return 1
    systemctl is-enabled "${_SINGBOX_SERVICE_NAME}.service" &>/dev/null \
        || systemctl is-active "${_SINGBOX_SERVICE_NAME}.service" &>/dev/null \
        || [[ -f "$_SINGBOX_SYSTEMD_SERVICE_FILE" ]]
}

_singbox_openrc_service_configured() {
    _has_openrc || return 1
    [[ -x "$_SINGBOX_OPENRC_SERVICE_FILE" ]] || _openrc_service_in_default "$_SINGBOX_SERVICE_NAME"
}

_singbox_service_is_active() {
    if _has_systemd && systemctl is-active --quiet "$_SINGBOX_SERVICE_NAME" 2>/dev/null; then
        return 0
    fi
    if _has_openrc && [[ -x "$_SINGBOX_OPENRC_SERVICE_FILE" ]] && rc-service "$_SINGBOX_SERVICE_NAME" status >/dev/null 2>&1; then
        return 0
    fi
    _singbox_running_pid >/dev/null 2>&1
}

_singbox_install_apt() {
    _info "使用 APT 官方仓库安装..."
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc
    chmod a+r /etc/apt/keyrings/sagernet.asc

    cat > /etc/apt/sources.list.d/sagernet.sources <<'SINGBOX_APT'
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
SINGBOX_APT

    apt-get update -qq
    printf "  ${BOLD}请选择版本${PLAIN}\n"
    _separator
    _menu_pair "1" "sing-box" "稳定版" "green" "2" "sing-box-beta" "测试版" "yellow"
    _separator
    local ver_choice
    read -rp "  请选择 [1/2，默认 1]: " ver_choice
    case "${ver_choice:-1}" in
        1) apt-get install -y sing-box ;;
        2) apt-get install -y sing-box-beta ;;
        *) _error_no_exit "无效选项"; return 1 ;;
    esac
}

_singbox_install_generic() {
    _info "使用官方安装脚本..."
    bash <(curl -fsSL https://sing-box.app/install.sh)
}

_singbox_setup() {
    _header "sing-box 安装"

    if ! command -v curl >/dev/null 2>&1; then
        _error_no_exit "需要 curl 命令，请先安装"
        _press_any_key
        return
    fi

    echo ""
    if command -v sing-box >/dev/null 2>&1; then
        local cur_ver
        cur_ver=$(sing-box version 2>/dev/null | head -1)
        [[ -z "$cur_ver" ]] && cur_ver="未知"
        _info "当前已安装: ${cur_ver}"
    else
        _info "当前未安装 sing-box"
    fi

    printf "  ${BOLD}请选择操作${PLAIN}\n"
    _separator
    _menu_pair "1" "安装/更新 sing-box" "" "green" "0" "返回主菜单" "" "red"
    _separator
    local choice
    read -rp "  选择 [0-1]: " choice
    case "$choice" in
        1) ;;
        0) return ;;
        *) _error_no_exit "无效选项"; _press_any_key; return ;;
    esac

    _time_sync_check_and_enable

    echo ""
    if command -v apt-get >/dev/null 2>&1; then
        if ! _singbox_install_apt; then
            _error_no_exit "sing-box 安装/更新失败"
            _press_any_key
            return
        fi
    else
        if ! _singbox_install_generic; then
            _error_no_exit "sing-box 安装/更新失败"
            _press_any_key
            return
        fi
    fi

    echo ""
    if command -v sing-box >/dev/null 2>&1; then
        _info "sing-box 安装成功!"
        _info "版本: $(sing-box version 2>/dev/null | head -1)"
    else
        _error_no_exit "sing-box 安装失败"
    fi

    _press_any_key
}

# --- Sing-Box 管理子菜单 ---

_singbox_enable() {
    _header "Sing-Box 自启动配置"

    if ! command -v sing-box >/dev/null 2>&1; then
        _error_no_exit "未检测到 sing-box，请先安装"
        _press_any_key
        return
    fi

    local service_file=""
    local service_name=""
    local force_rewrite="0"

    if _has_systemd; then
        service_file="$_SINGBOX_SYSTEMD_SERVICE_FILE"
        service_name="systemd"
    elif _has_openrc; then
        service_file="$_SINGBOX_OPENRC_SERVICE_FILE"
        service_name="OpenRC"
    fi

    if [[ -n "$service_file" && -f "$service_file" ]]; then
        _warn "${service_name} 服务文件已存在"
        local overwrite
        read -rp "  是否覆盖? [y/N]: " overwrite
        if [[ ! "$overwrite" =~ ^[Yy] ]]; then
            _press_any_key
            return
        fi
        force_rewrite="1"
    fi

    local config_file="/etc/sing-box/config.json"
    local singbox_bin
    singbox_bin=$(command -v sing-box 2>/dev/null || true)

    if [[ -z "$singbox_bin" || ! -x "$singbox_bin" ]]; then
        _error_no_exit "未检测到 sing-box，请先安装"
        _press_any_key
        return
    fi
    if [[ ! -f "$config_file" ]]; then
        _error_no_exit "未找到配置文件: ${config_file}"
        _press_any_key
        return
    fi

    if _has_systemd; then
        if [[ "$force_rewrite" == "1" || ! -f "$_SINGBOX_SYSTEMD_SERVICE_FILE" ]]; then
            _info "生成 systemd 服务文件..."
            cat > "$_SINGBOX_SYSTEMD_SERVICE_FILE" <<SINGBOX_SERVICE
[Unit]
Description=Sing-box Service
After=network.target

[Service]
User=root
ExecStart=${singbox_bin} run -c ${config_file}
Restart=on-failure
RestartSec=5s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SINGBOX_SERVICE
        fi
        systemctl daemon-reload >/dev/null 2>&1 || true
        if ! systemctl enable "$_SINGBOX_SERVICE_NAME" >/dev/null 2>&1; then
            _error_no_exit "设置开机自启失败，请检查 systemctl 状态"
            _press_any_key
            return
        fi
        _info "已设置开机自启"
        if ! systemctl restart "$_SINGBOX_SERVICE_NAME" >/dev/null 2>&1; then
            _error_no_exit "sing-box 启动失败，请检查: systemctl status ${_SINGBOX_SERVICE_NAME}"
            _press_any_key
            return
        fi
        sleep 1
        if systemctl is-active --quiet "$_SINGBOX_SERVICE_NAME"; then
            _info "sing-box 已成功启动"
        else
            _error_no_exit "sing-box 启动失败，请检查: systemctl status ${_SINGBOX_SERVICE_NAME}"
        fi
        _press_any_key
        return
    fi

    if _has_openrc; then
        mkdir -p "$(dirname "$_SINGBOX_LOG_FILE")"
        if [[ "$force_rewrite" == "1" || ! -f "$_SINGBOX_OPENRC_SERVICE_FILE" ]]; then
            _info "生成 OpenRC 服务文件..."
            cat > "$_SINGBOX_OPENRC_SERVICE_FILE" <<SINGBOX_SERVICE
#!/sbin/openrc-run
name="Sing-box"
description="Sing-box Service"

command="${singbox_bin}"
command_args="run -c ${config_file}"
command_background=true
pidfile="/run/${_SINGBOX_SERVICE_NAME}.pid"
output_log="${_SINGBOX_LOG_FILE}"
error_log="${_SINGBOX_ERR_FILE}"

depend() {
    need net
}
SINGBOX_SERVICE
            chmod 0755 "$_SINGBOX_OPENRC_SERVICE_FILE" || {
                _error_no_exit "写入 OpenRC 服务文件失败: ${_SINGBOX_OPENRC_SERVICE_FILE}"
                _press_any_key
                return
            }
        fi
        if ! rc-update add "$_SINGBOX_SERVICE_NAME" default >/dev/null 2>&1; then
            if ! _openrc_service_in_default "$_SINGBOX_SERVICE_NAME"; then
                _error_no_exit "设置开机自启失败，请检查 rc-update 状态"
                _press_any_key
                return
            fi
        fi
        _info "已设置开机自启 (OpenRC)"
        if ! rc-service "$_SINGBOX_SERVICE_NAME" restart >/dev/null 2>&1; then
            if ! rc-service "$_SINGBOX_SERVICE_NAME" start >/dev/null 2>&1; then
                _error_no_exit "sing-box 启动失败，请检查: rc-service ${_SINGBOX_SERVICE_NAME} status"
                _press_any_key
                return
            fi
        fi
        sleep 1
        if _singbox_service_is_active; then
            _info "sing-box 已成功启动"
        else
            _error_no_exit "sing-box 启动失败，请检查: rc-service ${_SINGBOX_SERVICE_NAME} status"
        fi
        _press_any_key
        return
    fi

    mkdir -p "$(dirname "$_SINGBOX_LOG_FILE")"
    _warn "当前系统未检测到 systemd/OpenRC，无法配置开机自启，仅尝试立即启动"
    pkill -x sing-box >/dev/null 2>&1 || true
    nohup "$singbox_bin" run -c "$config_file" >>"$_SINGBOX_LOG_FILE" 2>>"$_SINGBOX_ERR_FILE" &
    sleep 1
    if _singbox_running_pid >/dev/null 2>&1; then
        _info "sing-box 已成功启动"
    else
        _error_no_exit "sing-box 启动失败"
    fi

    _press_any_key
}

_singbox_restart() {
    _header "Sing-Box 重启"

    if ! command -v sing-box >/dev/null 2>&1; then
        _error_no_exit "未检测到 sing-box，请先安装"
        _press_any_key
        return
    fi

    if _singbox_systemd_service_configured; then
        _info "通过 systemd 重启 sing-box..."
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl restart "$_SINGBOX_SERVICE_NAME"
        sleep 1
        if systemctl is-active --quiet "$_SINGBOX_SERVICE_NAME"; then
            _info "sing-box 已成功重启"
        else
            _error_no_exit "sing-box 重启失败，请检查 systemctl status ${_SINGBOX_SERVICE_NAME}"
        fi
    elif _singbox_openrc_service_configured; then
        _info "通过 OpenRC 重启 sing-box..."
        if ! rc-service "$_SINGBOX_SERVICE_NAME" restart >/dev/null 2>&1; then
            if ! rc-service "$_SINGBOX_SERVICE_NAME" start >/dev/null 2>&1; then
                _error_no_exit "sing-box 重启失败，请检查 rc-service ${_SINGBOX_SERVICE_NAME} status"
                _press_any_key
                return
            fi
        fi
        sleep 1
        if _singbox_service_is_active; then
            _info "sing-box 已成功重启"
        else
            _error_no_exit "sing-box 重启失败，请检查 rc-service ${_SINGBOX_SERVICE_NAME} status"
        fi
    else
        local pid
        pid=$(_singbox_running_pid 2>/dev/null || true)
        if [[ -n "$pid" ]]; then
            _info "终止旧进程 (PID: $pid)..."
            kill "$pid" 2>/dev/null
            sleep 1
        fi
        _info "启动 sing-box..."
        mkdir -p "$(dirname "$_SINGBOX_LOG_FILE")"
        nohup sing-box run -c /etc/sing-box/config.json >>"$_SINGBOX_LOG_FILE" 2>>"$_SINGBOX_ERR_FILE" &
        sleep 1
        pid=$(_singbox_running_pid 2>/dev/null || true)
        if [[ -n "$pid" ]]; then
            _info "sing-box 已成功启动 (PID: ${pid})"
        else
            _error_no_exit "sing-box 启动失败"
        fi
    fi

    _press_any_key
}

_singbox_status() {
    _header "Sing-Box 运行状态"

    echo ""
    if _singbox_systemd_service_configured; then
        systemctl status "$_SINGBOX_SERVICE_NAME" --no-pager || true
    elif _singbox_openrc_service_configured; then
        rc-service "$_SINGBOX_SERVICE_NAME" status || true
    else
        local pid
        pid=$(_singbox_running_pid 2>/dev/null || true)
        if [[ -n "$pid" ]]; then
            printf "${GREEN}  ✔ ${PLAIN}运行状态: ${GREEN}运行中${PLAIN} (PID: $pid)\n"
        else
            printf "${GREEN}  ✔ ${PLAIN}运行状态: ${RED}未运行${PLAIN}\n"
        fi
    fi

    _press_any_key
}

_singbox_log() {
    _header "Sing-Box 日志"

    echo ""
    if _singbox_systemd_service_configured; then
        _info "显示最近 50 行日志 (Ctrl+C 退出实时跟踪)"
        _separator
        echo ""
        journalctl -u "$_SINGBOX_SERVICE_NAME" --no-pager -n 50
        echo ""
        _separator
        local follow
        read -rp "  是否实时跟踪日志? [y/N]: " follow
        if [[ "$follow" =~ ^[Yy] ]]; then
            echo ""
            _info "按 Ctrl+C 退出实时日志..."
            echo ""
            journalctl -u "$_SINGBOX_SERVICE_NAME" -f
        fi
    else
        if ! _tail_log_files_interactive "sing-box" "$_SINGBOX_LOG_FILE" "$_SINGBOX_ERR_FILE" "rc-service ${_SINGBOX_SERVICE_NAME} status"; then
            _warn "sing-box 当前未使用 systemd 管理，且未检测到日志文件"
            _info "提示: 可先执行选项 2「配置自启并启动」来设置 systemd/OpenRC 服务"
        fi
    fi

    _press_any_key
}

_singbox_uninstall() {
    _header "Sing-Box 卸载"

    local systemd_service_file="$_SINGBOX_SYSTEMD_SERVICE_FILE"
    local openrc_service_file="$_SINGBOX_OPENRC_SERVICE_FILE"
    local config_dir="/etc/sing-box"
    local apt_source="/etc/apt/sources.list.d/sagernet.sources"
    local apt_key="/etc/apt/keyrings/sagernet.asc"
    local bin_path remove_config remove_repo confirm p
    local removed_count=0
    local -a bin_candidates=() apt_pkgs=()

    bin_path=$(command -v sing-box 2>/dev/null || true)

    _warn "将停止并卸载 Sing-Box，可选删除配置目录。"
    printf "    systemd 服务文件: %s\n" "$systemd_service_file"
    printf "    OpenRC 服务文件 : %s\n" "$openrc_service_file"
    if [[ -n "$bin_path" ]]; then
        printf "    可执行文件: %s\n" "$bin_path"
    else
        printf "    可执行文件: %s\n" "/usr/bin/sing-box"
    fi
    printf "    配置目录: %s\n" "$config_dir"
    read -rp "  确认卸载 Sing-Box? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy] ]]; then
        _info "已取消"
        _press_any_key
        return
    fi

    if _has_systemd; then
        if systemctl is-active --quiet "$_SINGBOX_SERVICE_NAME" 2>/dev/null || systemctl is-enabled "${_SINGBOX_SERVICE_NAME}.service" &>/dev/null || [[ -f "$systemd_service_file" ]]; then
            systemctl stop "$_SINGBOX_SERVICE_NAME" >/dev/null 2>&1 || true
            systemctl disable "$_SINGBOX_SERVICE_NAME" >/dev/null 2>&1 || true
            _info "已停止并禁用 sing-box 服务"
        fi
    fi
    if _has_openrc; then
        if [[ -x "$openrc_service_file" ]] || _openrc_service_in_default "$_SINGBOX_SERVICE_NAME"; then
            rc-service "$_SINGBOX_SERVICE_NAME" stop >/dev/null 2>&1 || true
            rc-update del "$_SINGBOX_SERVICE_NAME" default >/dev/null 2>&1 || true
            _info "已停止并禁用 OpenRC 的 sing-box 服务"
        fi
    fi

    if _singbox_running_pid >/dev/null 2>&1; then
        pkill -x sing-box >/dev/null 2>&1 || pkill sing-box >/dev/null 2>&1 || true
        sleep 1
    fi

    if [[ -f "$systemd_service_file" ]]; then
        rm -f "$systemd_service_file"
        removed_count=$((removed_count + 1))
        _info "已删除服务文件: $systemd_service_file"
    fi
    if [[ -f "$openrc_service_file" ]]; then
        rm -f "$openrc_service_file"
        removed_count=$((removed_count + 1))
        _info "已删除服务文件: $openrc_service_file"
    fi
    if _has_systemd; then
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl reset-failed "$_SINGBOX_SERVICE_NAME" >/dev/null 2>&1 || true
    fi

    if command -v dpkg >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
        dpkg -s sing-box >/dev/null 2>&1 && apt_pkgs+=("sing-box")
        dpkg -s sing-box-beta >/dev/null 2>&1 && apt_pkgs+=("sing-box-beta")
        if (( ${#apt_pkgs[@]} > 0 )); then
            _info "检测到 APT 安装包: ${apt_pkgs[*]}"
            if apt-get remove -y "${apt_pkgs[@]}" >/dev/null 2>&1; then
                removed_count=$((removed_count + 1))
                _info "已卸载 APT 包: ${apt_pkgs[*]}"
            else
                _warn "APT 包卸载失败，可手动执行: apt-get remove -y ${apt_pkgs[*]}"
            fi
        fi
    fi

    [[ -n "$bin_path" ]] && bin_candidates+=("$bin_path")
    [[ "/usr/bin/sing-box" != "$bin_path" ]] && bin_candidates+=("/usr/bin/sing-box")
    [[ "/usr/local/bin/sing-box" != "$bin_path" ]] && bin_candidates+=("/usr/local/bin/sing-box")
    for p in "${bin_candidates[@]}"; do
        [[ -z "${p:-}" ]] && continue
        if [[ -f "$p" || -L "$p" ]]; then
            rm -f "$p"
            removed_count=$((removed_count + 1))
            _info "已删除可执行文件: $p"
        fi
    done

    if [[ -f "$_SINGBOX_LOG_FILE" || -f "$_SINGBOX_ERR_FILE" ]]; then
        rm -f "$_SINGBOX_LOG_FILE" "$_SINGBOX_ERR_FILE"
        removed_count=$((removed_count + 1))
        _info "已删除日志文件"
    fi

    if [[ -f "$apt_source" || -f "$apt_key" ]]; then
        read -rp "  是否同时删除 Sing-Box APT 源配置? [y/N]: " remove_repo
        if [[ "$remove_repo" =~ ^[Yy] ]]; then
            rm -f "$apt_source" "$apt_key"
            removed_count=$((removed_count + 1))
            _info "已删除 APT 源配置"
            if command -v apt-get >/dev/null 2>&1; then
                apt-get update -qq >/dev/null 2>&1 || true
            fi
        else
            _info "已保留 APT 源配置"
        fi
    fi

    if [[ -d "$config_dir" ]]; then
        read -rp "  是否同时删除配置目录 ${config_dir}? [y/N]: " remove_config
        if [[ "$remove_config" =~ ^[Yy] ]]; then
            rm -rf "$config_dir"
            removed_count=$((removed_count + 1))
            _info "已删除配置目录: $config_dir"
        else
            _info "已保留配置目录: $config_dir"
        fi
    fi

    if (( removed_count == 0 )); then
        _warn "未检测到可删除的 Sing-Box 文件，已完成服务清理。"
    else
        _success "Sing-Box 卸载完成"
    fi
    _press_any_key
}

_singbox_manage() {
    while true; do
        _header "Sing-Box 管理"

        echo ""
        if command -v sing-box >/dev/null 2>&1; then
            local ver
            ver=$(sing-box version 2>/dev/null | head -1)
            _info "当前版本: ${ver:-未知}"
            local pid
            pid=$(pgrep -x sing-box 2>/dev/null || true)
            if [[ -n "$pid" ]]; then
                printf "${GREEN}  ✔ ${PLAIN}运行状态: ${GREEN}运行中${PLAIN} (PID: $pid)\n"
            else
                printf "${GREEN}  ✔ ${PLAIN}运行状态: ${RED}未运行${PLAIN}\n"
            fi
        else
            _info "当前未安装 sing-box"
        fi

        _separator
        _menu_pair "1" "安装/更新 Sing-Box" "" "green" "2" "配置自启并启动" "" "green"
        _menu_pair "3" "重启 Sing-Box" "" "green" "4" "查看状态" "" "green"
        _menu_pair "5" "查看日志" "" "green" "6" "卸载 Sing-Box" "可选删除配置" "yellow"
        _menu_item "0" "返回主菜单" "" "red"
        _separator

        local choice
        read -rp "  选择 [0-6]: " choice
        case "$choice" in
            1) _singbox_setup ;;
            2) _singbox_enable ;;
            3) _singbox_restart ;;
            4) _singbox_status ;;
            5) _singbox_log ;;
            6) _singbox_uninstall ;;
            0) return ;;
            *) _error_no_exit "无效选项"; sleep 1 ;;
        esac
    done
}

# --- 11. Snell V5 管理 ---

_SNELL_CONFIG_DIR="/etc/snell"
_SNELL_CONFIG_FILE="/etc/snell/snell-server.conf"
_SNELL_SERVICE_NAME="snell"
_SNELL_SYSTEMD_SERVICE_FILE="/etc/systemd/system/${_SNELL_SERVICE_NAME}.service"
_SNELL_OPENRC_SERVICE_FILE="/etc/init.d/${_SNELL_SERVICE_NAME}"
_SNELL_BIN="/usr/local/bin/snell-server"
_SNELL_LOG_FILE="/var/log/snell.log"
_SNELL_ERR_FILE="/var/log/snell.error.log"
_SNELL_KB_URL="https://kb.nssurge.com/surge-knowledge-base/release-notes/snell"

_snell_running_pid() {
    local pid=""
    local pid_file="/run/${_SNELL_SERVICE_NAME}.pid"

    if [[ -f "$pid_file" ]]; then
        pid=$(tr -cd '0-9' < "$pid_file" 2>/dev/null || true)
        if _is_digit "${pid:-}" && kill -0 "$pid" >/dev/null 2>&1; then
            printf '%s' "$pid"
            return 0
        fi
    fi

    if command -v pgrep >/dev/null 2>&1; then
        pid=$(pgrep -x snell-server 2>/dev/null | head -n1 || true)
        [[ -z "$pid" ]] && pid=$(pgrep snell-server 2>/dev/null | head -n1 || true)
        if _is_digit "${pid:-}" && kill -0 "$pid" >/dev/null 2>&1; then
            printf '%s' "$pid"
            return 0
        fi
    fi
    return 1
}

_snell_systemd_service_configured() {
    _has_systemd || return 1
    systemctl is-enabled "${_SNELL_SERVICE_NAME}.service" &>/dev/null \
        || systemctl is-active "${_SNELL_SERVICE_NAME}.service" &>/dev/null \
        || [[ -f "$_SNELL_SYSTEMD_SERVICE_FILE" ]]
}

_snell_openrc_service_configured() {
    _has_openrc || return 1
    [[ -x "$_SNELL_OPENRC_SERVICE_FILE" ]] || _openrc_service_in_default "$_SNELL_SERVICE_NAME"
}

_snell_service_is_active() {
    if _has_systemd && systemctl is-active --quiet "$_SNELL_SERVICE_NAME" 2>/dev/null; then
        return 0
    fi
    if _has_openrc && [[ -x "$_SNELL_OPENRC_SERVICE_FILE" ]] && rc-service "$_SNELL_SERVICE_NAME" status >/dev/null 2>&1; then
        return 0
    fi
    _snell_running_pid >/dev/null 2>&1
}

_snell_detect_arch() {
    local machine
    machine=$(uname -m 2>/dev/null || echo unknown)
    case "$machine" in
        x86_64|amd64) echo "amd64" ;;
        i386|i486|i586|i686) echo "i386" ;;
        aarch64|arm64) echo "aarch64" ;;
        armv7l|armv7) echo "armv7l" ;;
        *) echo "" ;;
    esac
}

_snell_bin_version() {
    if [[ -x "$_SNELL_BIN" ]]; then
        local out
        out=$("$_SNELL_BIN" --version 2>/dev/null | head -1 || true)
        [[ -z "$out" ]] && out=$("$_SNELL_BIN" -v 2>/dev/null | head -1 || true)
        printf '%s' "$out"
        return
    fi
    echo ""
}

_snell_get_latest_version() {
    local page version
    page=$(curl -fsSL "$_SNELL_KB_URL" 2>/dev/null || true)
    version=$(printf '%s' "$page" | grep -oE 'snell-server-v5\.[0-9]+\.[0-9]+-linux-amd64\.zip' | head -1 \
        | sed -E 's/.*(v5\.[0-9]+\.[0-9]+).*/\1/')
    if [[ -z "$version" ]]; then
        version=$(printf '%s' "$page" | grep -oE 'v5\.[0-9]+\.[0-9]+' | head -1)
    fi
    printf '%s' "$version"
}

_snell_conf_get_value() {
    local key="$1"
    [[ -f "$_SNELL_CONFIG_FILE" ]] || return 1
    awk -F'=' -v k="$key" '
        function trim(s) {
            sub(/^[[:space:]]+/, "", s)
            sub(/[[:space:]]+$/, "", s)
            return s
        }
        {
            line=$0
            lower=tolower(line)
            want=tolower(k)
            if (lower ~ "^[[:space:]]*" want "[[:space:]]*=") {
                sub(/^[^=]*=/, "", line)
                print trim(line)
                exit
            }
        }
    ' "$_SNELL_CONFIG_FILE"
}

_snell_compose_listen_value() {
    local listen_addr="$1" port="$2" normalized_addr
    listen_addr=$(_mihomoconf_trim "${listen_addr:-0.0.0.0}")
    if [[ "$listen_addr" == *:* ]]; then
        if [[ "$listen_addr" =~ ^\[.*\]$ ]]; then
            normalized_addr="$listen_addr"
        else
            normalized_addr="[${listen_addr}]"
        fi
    else
        normalized_addr="$listen_addr"
    fi
    printf '%s:%s' "$normalized_addr" "$port"
}

_snell_parse_port_from_listen() {
    local listen="$1" candidate
    listen=$(_mihomoconf_trim "${listen%%#*}")
    [[ -n "$listen" ]] || return 1
    candidate=$(_mihomoconf_trim "${listen##*:}")
    if _is_valid_port "$candidate"; then
        printf '%s' "$candidate"
        return 0
    fi
    return 1
}

_snell_uri_host() {
    local host="$1"
    host=$(_mihomoconf_trim "${host:-}")
    if [[ "$host" == \[*\] ]]; then
        printf '%s' "$host"
        return 0
    fi
    if [[ "$host" == *:* ]]; then
        printf '[%s]' "$host"
        return 0
    fi
    printf '%s' "$host"
}

_snell_gen_uri_link() {
    local server="$1" port="$2" psk="$3" name="$4"
    local version="${5:-4}" obfs="${6:-}" obfs_host="${7:-}"
    local server_uri encoded_psk encoded_name query

    server_uri=$(_snell_uri_host "$server")
    encoded_psk=$(_mihomoconf_urlencode "$psk")
    encoded_name=$(_mihomoconf_urlencode "${name:-Snell-V5}")
    query="psk=${encoded_psk}&version=${version}"

    if [[ -n "$obfs" ]]; then
        query="${query}&obfs=$(_mihomoconf_urlencode "$obfs")"
    fi
    if [[ -n "$obfs_host" ]]; then
        query="${query}&obfs-host=$(_mihomoconf_urlencode "$obfs_host")"
    fi

    printf 'snell://%s:%s?%s#%s' "$server_uri" "$port" "$query" "$encoded_name"
}

_snell_port_usage_line() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -lnutpH 2>/dev/null | awk -v p="$port" '
            {
                addr=$5
                sub(/%[[:alnum:]_.-]+$/, "", addr)
                if (addr ~ "\\]:" p "$" || addr ~ ":" p "$") {
                    print
                    exit
                }
            }
        '
        return
    fi
    if command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | sed -n '2p'
    fi
}

_snell_port_conflict_with_mihomo() {
    local target_port="$1"
    local config_file="$_MIHOMOCONF_CONFIG_FILE"
    local type name port cipher password user_id user_pass sni
    local hy2_up hy2_down hy2_ignore hy2_obfs hy2_obfs_password hy2_masquerade hy2_mport hy2_insecure listener_tag

    [[ -f "$config_file" ]] || return 1
    while IFS=$'\x1f' read -r type name port cipher password user_id user_pass sni \
        hy2_up hy2_down hy2_ignore hy2_obfs hy2_obfs_password hy2_masquerade hy2_mport hy2_insecure listener_tag; do
        [[ -z "${port:-}" ]] && continue
        if [[ "$port" == "$target_port" ]]; then
            return 0
        fi
    done < <(_mihomoconf_read_listener_rows "$config_file")
    awk -v p="$target_port" '
        function trim(s) {
            sub(/^[[:space:]]+/, "", s)
            sub(/[[:space:]]+$/, "", s)
            return s
        }
        function unquote(s) {
            gsub(/^"/, "", s)
            gsub(/"$/, "", s)
            return s
        }
        function strip_comment(s) {
            sub(/[[:space:]]+#.*/, "", s)
            return s
        }
        BEGIN {
            in_listeners=0
        }
        /^[^[:space:]#][^:]*:[[:space:]]*.*$/ {
            key=$0
            sub(/:.*/, "", key)
            val=$0
            sub(/^[^:]*:[[:space:]]*/, "", val)

            if ($0 ~ /^listeners:[[:space:]]*$/) {
                in_listeners=1
                next
            }
            in_listeners=0

            if (key == "port" || key == "socks-port" || key == "mixed-port" || key == "redir-port" || key == "tproxy-port") {
                v=trim(unquote(strip_comment(val)))
                if (v ~ /^[0-9]+$/ && v == p) {
                    exit 0
                }
                next
            }
            if (key == "external-controller") {
                v=trim(unquote(strip_comment(val)))
                if (v ~ /:[0-9]+$/) {
                    c=v
                    sub(/^.*:/, "", c)
                    if (c == p) {
                        exit 0
                    }
                }
                next
            }
            next
        }
        END { exit 1 }
    ' "$config_file" >/dev/null 2>&1
}

_snell_pick_listen_port() {
    local default_port="${1:-6160}"
    local port_input usage_line

    while true; do
        read -rp "  Snell 监听端口 [默认 ${default_port}]: " port_input
        port_input=$(_mihomoconf_trim "${port_input:-$default_port}")
        if ! _is_valid_port "$port_input"; then
            _warn "端口无效，请输入 1-65535 的数字"
            continue
        fi
        if _snell_port_conflict_with_mihomo "$port_input"; then
            _warn "端口 ${port_input} 与 mihomo 配置冲突（listeners/port/mixed-port 等），请更换端口"
            continue
        fi
        usage_line=$(_snell_port_usage_line "$port_input")
        if [[ -n "$usage_line" && "$usage_line" != *"snell-server"* ]]; then
            _warn "端口 ${port_input} 已被占用: ${usage_line}"
            continue
        fi
        printf '%s' "$port_input"
        return 0
    done
}

_snell_install_latest_core() {
    local arch latest_version url tmp_zip tmp_dir extracted_bin ver_out

    if [[ "$(uname -s)" != "Linux" ]]; then
        _error_no_exit "Snell 仅支持 Linux 系统"
        return 1
    fi
    if ! command -v curl >/dev/null 2>&1; then
        _error_no_exit "缺少必要命令: curl，请先安装"
        return 1
    fi
    if ! command -v unzip >/dev/null 2>&1; then
        _warn "未检测到 unzip，尝试自动安装..."
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -qq >/dev/null 2>&1 || true
            apt-get install -y -qq unzip >/dev/null 2>&1 || true
        elif command -v yum >/dev/null 2>&1; then
            yum install -y unzip >/dev/null 2>&1 || true
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y unzip >/dev/null 2>&1 || true
        elif command -v apk >/dev/null 2>&1; then
            apk add --no-cache unzip >/dev/null 2>&1 || true
        fi
        if ! command -v unzip >/dev/null 2>&1; then
            _error_no_exit "缺少必要命令: unzip，请先安装"
            return 1
        fi
    fi

    arch=$(_snell_detect_arch)
    if [[ -z "$arch" ]]; then
        _error_no_exit "不支持的架构: $(uname -m)"
        return 1
    fi
    latest_version=$(_snell_get_latest_version)
    if [[ -z "$latest_version" ]]; then
        _error_no_exit "无法从官方知识库获取 Snell 最新版本号"
        return 1
    fi

    url="https://dl.nssurge.com/snell/snell-server-${latest_version}-linux-${arch}.zip"
    tmp_zip=$(mktemp /tmp/snell.XXXXXX.zip)
    tmp_dir=$(mktemp -d /tmp/snell.XXXXXX)

    _info "使用官方 Snell 工具安装: ${latest_version} (${arch})"
    printf "    ${DIM}%s${PLAIN}\n" "$url"
    if ! _mihomo_download "$url" "$tmp_zip"; then
        rm -rf "$tmp_zip" "$tmp_dir"
        _error_no_exit "官方下载失败，请检查网络或架构匹配"
        return 1
    fi
    if [[ ! -s "$tmp_zip" ]]; then
        rm -rf "$tmp_zip" "$tmp_dir"
        _error_no_exit "下载文件为空，请稍后重试"
        return 1
    fi

    if ! unzip -oq "$tmp_zip" -d "$tmp_dir"; then
        rm -rf "$tmp_zip" "$tmp_dir"
        _error_no_exit "解压失败"
        return 1
    fi
    extracted_bin=$(find "$tmp_dir" -type f -name 'snell-server' | head -1)
    if [[ -z "$extracted_bin" || ! -f "$extracted_bin" ]]; then
        rm -rf "$tmp_zip" "$tmp_dir"
        _error_no_exit "安装包中未找到 snell-server 可执行文件"
        return 1
    fi

    install -m 0755 "$extracted_bin" "$_SNELL_BIN"
    rm -rf "$tmp_zip" "$tmp_dir"

    if [[ ! -x "$_SNELL_BIN" ]]; then
        _error_no_exit "snell-server 安装失败"
        return 1
    fi
    ver_out=$(_snell_bin_version)
    _success "Snell 安装完成"
    [[ -n "$ver_out" ]] && _info "当前版本: $ver_out"
    return 0
}

_snell_install_latest() {
    _header "Snell V5 安装/更新"
    _time_sync_check_and_enable
    _snell_install_latest_core
    _press_any_key
}

_snell_enable_now() {
    if [[ ! -x "$_SNELL_BIN" ]]; then
        _error_no_exit "未检测到 snell-server，请先安装"
        return 1
    fi
    if [[ ! -f "$_SNELL_CONFIG_FILE" ]]; then
        _error_no_exit "未检测到配置文件: ${_SNELL_CONFIG_FILE}"
        return 1
    fi

    if _has_systemd; then
        cat > "$_SNELL_SYSTEMD_SERVICE_FILE" <<EOF
[Unit]
Description=Snell Proxy Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=${_SNELL_BIN} -c ${_SNELL_CONFIG_FILE}
Restart=on-failure
RestartSec=3
LimitNOFILE=32768

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload >/dev/null 2>&1 || true
        if ! systemctl enable "$_SNELL_SERVICE_NAME" >/dev/null 2>&1; then
            _error_no_exit "设置 snell 开机自启失败"
            return 1
        fi
        if ! systemctl restart "$_SNELL_SERVICE_NAME" >/dev/null 2>&1; then
            _error_no_exit "snell 启动失败，请检查: systemctl status ${_SNELL_SERVICE_NAME}"
            return 1
        fi
        sleep 1
        if systemctl is-active --quiet "$_SNELL_SERVICE_NAME"; then
            _success "snell 已成功启动"
            return 0
        fi
        _error_no_exit "snell 启动失败，请检查: systemctl status ${_SNELL_SERVICE_NAME}"
        return 1
    fi

    if _has_openrc; then
        mkdir -p "$(dirname "$_SNELL_LOG_FILE")"
        cat > "$_SNELL_OPENRC_SERVICE_FILE" <<EOF
#!/sbin/openrc-run
name="Snell"
description="Snell Proxy Service"

command="${_SNELL_BIN}"
command_args="-c ${_SNELL_CONFIG_FILE}"
command_background=true
pidfile="/run/${_SNELL_SERVICE_NAME}.pid"
output_log="${_SNELL_LOG_FILE}"
error_log="${_SNELL_ERR_FILE}"

depend() {
    need net
}
EOF
        chmod 0755 "$_SNELL_OPENRC_SERVICE_FILE" || {
            _error_no_exit "写入 OpenRC 服务文件失败: ${_SNELL_OPENRC_SERVICE_FILE}"
            return 1
        }
        if ! rc-update add "$_SNELL_SERVICE_NAME" default >/dev/null 2>&1; then
            if ! _openrc_service_in_default "$_SNELL_SERVICE_NAME"; then
                _error_no_exit "设置 snell 开机自启失败"
                return 1
            fi
        fi
        if ! rc-service "$_SNELL_SERVICE_NAME" restart >/dev/null 2>&1; then
            if ! rc-service "$_SNELL_SERVICE_NAME" start >/dev/null 2>&1; then
                _error_no_exit "snell 启动失败，请检查: rc-service ${_SNELL_SERVICE_NAME} status"
                return 1
            fi
        fi
        sleep 1
        if _snell_service_is_active; then
            _success "snell 已成功启动"
            return 0
        fi
        _error_no_exit "snell 启动失败，请检查: rc-service ${_SNELL_SERVICE_NAME} status"
        return 1
    fi

    mkdir -p "$(dirname "$_SNELL_LOG_FILE")"
    pkill -x snell-server >/dev/null 2>&1 || pkill snell-server >/dev/null 2>&1 || true
    nohup "$_SNELL_BIN" -c "$_SNELL_CONFIG_FILE" >>"$_SNELL_LOG_FILE" 2>>"$_SNELL_ERR_FILE" &
    sleep 1
    if _snell_running_pid >/dev/null 2>&1; then
        _success "snell 已成功启动 (非 systemd/OpenRC 模式)"
        return 0
    fi
    _error_no_exit "snell 启动失败"
    return 1
}

_snell_write_config() {
    local listen_addr="$1" port="$2" psk="$3" ipv6_flag="$4" egress_iface="$5"
    local listen_value
    listen_value=$(_snell_compose_listen_value "$listen_addr" "$port")
    mkdir -p "$_SNELL_CONFIG_DIR"
    cat > "$_SNELL_CONFIG_FILE" <<EOF
[snell-server]
listen = ${listen_value}
psk = ${psk}
ipv6 = ${ipv6_flag}
EOF
    if [[ -n "$egress_iface" ]]; then
        printf "egress-interface = %s\n" "$egress_iface" >> "$_SNELL_CONFIG_FILE"
    fi
}

_snell_configure() {
    _header "Snell V5 配置"

    local install_confirm current_listen current_port current_psk current_ipv6 current_egress
    local listen_port psk_input psk_value ipv6_input ipv6_flag listen_addr egress_iface
    local host_default host_input client_host

    if [[ ! -x "$_SNELL_BIN" ]]; then
        read -rp "  未检测到 snell-server，是否先安装最新版? [Y/n]: " install_confirm
        if [[ "$install_confirm" =~ ^([Nn]|[Nn][Oo])$ ]]; then
            _info "已取消"
            _press_any_key
            return
        fi
        _time_sync_check_and_enable
        if ! _snell_install_latest_core; then
            _press_any_key
            return
        fi
    fi

    current_port=$(_snell_conf_get_value "port" 2>/dev/null || true)
    if ! _is_valid_port "${current_port:-}"; then
        current_listen=$(_snell_conf_get_value "listen" 2>/dev/null || true)
        current_port=$(_snell_parse_port_from_listen "$current_listen" 2>/dev/null || true)
    fi
    if ! _is_valid_port "${current_port:-}"; then
        current_port="6160"
    fi
    current_psk=$(_snell_conf_get_value "psk" 2>/dev/null || true)
    current_ipv6=$(_snell_conf_get_value "ipv6" 2>/dev/null || true)
    current_egress=$(_snell_conf_get_value "egress-interface" 2>/dev/null || true)

    _info "将生成 Snell 配置并进行端口冲突检查（含 mihomo listeners 与常用监听端口字段）。"
    listen_port=$(_snell_pick_listen_port "$current_port")
    read -rp "  PSK [留空自动生成]: " psk_input
    psk_input=$(_mihomoconf_trim "${psk_input:-}")
    if [[ -n "$psk_input" ]]; then
        psk_value="$psk_input"
    elif [[ -n "$current_psk" ]]; then
        psk_value="$current_psk"
    else
        psk_value=$(_mihomoconf_gen_anytls_password)
    fi
    if [[ -z "$psk_value" ]]; then
        _error_no_exit "PSK 不能为空"
        _press_any_key
        return
    fi
    if [[ "$psk_value" == *"|"* ]]; then
        _error_no_exit "PSK 不能包含字符 |"
        _press_any_key
        return
    fi

    read -rp "  是否启用 IPv6 转发? [y/N]: " ipv6_input
    if [[ "$ipv6_input" =~ ^[Yy] ]]; then
        ipv6_flag="true"
        listen_addr="::0"
    else
        ipv6_flag="false"
        listen_addr="0.0.0.0"
    fi

    read -rp "  egress-interface [可留空，如 eth0]: " egress_iface
    egress_iface=$(_mihomoconf_trim "${egress_iface:-$current_egress}")
    if [[ -n "$egress_iface" ]]; then
        if ! ip link show "$egress_iface" >/dev/null 2>&1; then
            _warn "网卡 ${egress_iface} 不存在，已忽略 egress-interface 配置"
            egress_iface=""
        fi
    fi

    _snell_write_config "$listen_addr" "$listen_port" "$psk_value" "$ipv6_flag" "$egress_iface"
    _info "配置文件已写入: ${_SNELL_CONFIG_FILE}"

    if ! _snell_enable_now; then
        _warn "自动启动失败，请检查日志后重试"
        _press_any_key
        return
    fi

    host_default=$(_mihomoconf_get_saved_host "$_MIHOMOCONF_CONFIG_FILE" 2>/dev/null || true)
    [[ -z "$host_default" ]] && host_default=$(_mihomoconf_get_server_ip)
    read -rp "  客户端连接地址 [默认 ${host_default}]: " host_input
    client_host=$(_mihomoconf_trim "${host_input:-$host_default}")

    echo ""
    _separator
    printf "  ${BOLD}Snell V5 Surge 配置${PLAIN}\n"
    _separator
    printf "  Snell-V5 = snell, %s, %s, psk = %s, version = 5, reuse = true, tfo = true\n" "$client_host" "$listen_port" "$psk_value"
    _press_any_key
}

_snell_restart() {
    _header "Snell 重启"

    if [[ ! -x "$_SNELL_BIN" ]]; then
        _error_no_exit "未检测到 snell-server，请先安装"
        _press_any_key
        return
    fi

    if _snell_systemd_service_configured; then
        systemctl daemon-reload >/dev/null 2>&1 || true
        if ! systemctl restart "$_SNELL_SERVICE_NAME"; then
            _error_no_exit "snell 重启失败，请检查: systemctl status ${_SNELL_SERVICE_NAME}"
            _press_any_key
            return
        fi
        sleep 1
        if systemctl is-active --quiet "$_SNELL_SERVICE_NAME"; then
            _success "snell 已成功重启"
        else
            _error_no_exit "snell 重启失败，请检查: systemctl status ${_SNELL_SERVICE_NAME}"
        fi
    elif _snell_openrc_service_configured; then
        if ! rc-service "$_SNELL_SERVICE_NAME" restart >/dev/null 2>&1; then
            if ! rc-service "$_SNELL_SERVICE_NAME" start >/dev/null 2>&1; then
                _error_no_exit "snell 重启失败，请检查: rc-service ${_SNELL_SERVICE_NAME} status"
                _press_any_key
                return
            fi
        fi
        sleep 1
        if _snell_service_is_active; then
            _success "snell 已成功重启"
        else
            _error_no_exit "snell 重启失败，请检查: rc-service ${_SNELL_SERVICE_NAME} status"
        fi
    else
        local pid
        pid=$(_snell_running_pid 2>/dev/null || true)
        if [[ -n "$pid" ]]; then
            kill "$pid" 2>/dev/null || true
            sleep 1
        fi
        if [[ ! -f "$_SNELL_CONFIG_FILE" ]]; then
            _error_no_exit "未找到配置文件: ${_SNELL_CONFIG_FILE}"
            _press_any_key
            return
        fi
        mkdir -p "$(dirname "$_SNELL_LOG_FILE")"
        nohup "$_SNELL_BIN" -c "$_SNELL_CONFIG_FILE" >>"$_SNELL_LOG_FILE" 2>>"$_SNELL_ERR_FILE" &
        sleep 1
        if _snell_running_pid >/dev/null 2>&1; then
            _success "snell 已成功启动"
        else
            _error_no_exit "snell 启动失败"
        fi
    fi
    _press_any_key
}

_snell_status() {
    _header "Snell 运行状态"

    if _snell_systemd_service_configured; then
        echo ""
        systemctl status "$_SNELL_SERVICE_NAME" --no-pager
    elif _snell_openrc_service_configured; then
        echo ""
        rc-service "$_SNELL_SERVICE_NAME" status || true
    else
        local pid
        pid=$(_snell_running_pid 2>/dev/null || true)
        echo ""
        if [[ -n "$pid" ]]; then
            printf "${GREEN}  ✔ ${PLAIN}运行状态: ${GREEN}运行中${PLAIN} (PID: %s)\n" "$pid"
        else
            printf "${GREEN}  ✔ ${PLAIN}运行状态: ${RED}未运行${PLAIN}\n"
        fi
        if [[ -f "$_SNELL_CONFIG_FILE" ]]; then
            _info "配置文件: $_SNELL_CONFIG_FILE"
        fi
    fi
    _press_any_key
}

_snell_log() {
    _header "Snell 日志"

    if _snell_systemd_service_configured; then
        _info "显示最近 50 行日志 (Ctrl+C 退出实时跟踪)"
        _separator
        echo ""
        journalctl -u "$_SNELL_SERVICE_NAME" --no-pager -n 50
        echo ""
        _separator
        local follow
        read -rp "  是否实时跟踪日志? [y/N]: " follow
        if [[ "$follow" =~ ^[Yy] ]]; then
            journalctl -u "$_SNELL_SERVICE_NAME" -f
        fi
    else
        if ! _tail_log_files_interactive "snell" "$_SNELL_LOG_FILE" "$_SNELL_ERR_FILE" "rc-service ${_SNELL_SERVICE_NAME} status"; then
            _warn "snell 当前未使用 systemd 管理，且未检测到日志文件"
        fi
    fi
    _press_any_key
}

_snell_uninstall() {
    _header "Snell 卸载"

    local confirm remove_config removed_count=0

    _warn "将停止并卸载 Snell，可选删除配置目录。"
    printf "    systemd 服务文件: %s\n" "$_SNELL_SYSTEMD_SERVICE_FILE"
    printf "    OpenRC 服务文件 : %s\n" "$_SNELL_OPENRC_SERVICE_FILE"
    printf "    可执行文件: %s\n" "$_SNELL_BIN"
    printf "    配置目录: %s\n" "$_SNELL_CONFIG_DIR"
    read -rp "  确认卸载 Snell? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy] ]]; then
        _info "已取消"
        _press_any_key
        return
    fi

    if _has_systemd; then
        systemctl stop "$_SNELL_SERVICE_NAME" >/dev/null 2>&1 || true
        systemctl disable "$_SNELL_SERVICE_NAME" >/dev/null 2>&1 || true
    fi
    if _has_openrc; then
        rc-service "$_SNELL_SERVICE_NAME" stop >/dev/null 2>&1 || true
        rc-update del "$_SNELL_SERVICE_NAME" default >/dev/null 2>&1 || true
    fi
    pkill -x snell-server >/dev/null 2>&1 || pkill snell-server >/dev/null 2>&1 || true

    if [[ -f "$_SNELL_SYSTEMD_SERVICE_FILE" ]]; then
        rm -f "$_SNELL_SYSTEMD_SERVICE_FILE"
        removed_count=$((removed_count + 1))
    fi
    if [[ -f "$_SNELL_OPENRC_SERVICE_FILE" ]]; then
        rm -f "$_SNELL_OPENRC_SERVICE_FILE"
        removed_count=$((removed_count + 1))
    fi
    if _has_systemd; then
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl reset-failed "$_SNELL_SERVICE_NAME" >/dev/null 2>&1 || true
    fi

    if [[ -f "$_SNELL_BIN" || -L "$_SNELL_BIN" ]]; then
        rm -f "$_SNELL_BIN"
        removed_count=$((removed_count + 1))
    fi

    if [[ -f "$_SNELL_LOG_FILE" || -f "$_SNELL_ERR_FILE" ]]; then
        rm -f "$_SNELL_LOG_FILE" "$_SNELL_ERR_FILE"
        removed_count=$((removed_count + 1))
    fi

    if [[ -d "$_SNELL_CONFIG_DIR" ]]; then
        read -rp "  是否同时删除配置目录 ${_SNELL_CONFIG_DIR}? [y/N]: " remove_config
        if [[ "$remove_config" =~ ^[Yy] ]]; then
            rm -rf "$_SNELL_CONFIG_DIR"
            removed_count=$((removed_count + 1))
        fi
    fi

    if (( removed_count == 0 )); then
        _warn "未检测到可删除的 Snell 文件，已完成服务清理。"
    else
        _success "Snell 卸载完成"
    fi
    _press_any_key
}

_snell_manage() {
    while true; do
        _header "Snell V5 管理"
        echo ""

        if [[ -x "$_SNELL_BIN" ]]; then
            local ver
            ver=$(_snell_bin_version)
            [[ -n "$ver" ]] && _info "当前版本: ${ver}" || _info "当前已安装 snell-server"
        else
            _info "当前未安装 snell-server"
        fi
        if [[ -f "$_SNELL_CONFIG_FILE" ]]; then
            local p
            p=$(_snell_conf_get_value "port" 2>/dev/null || true)
            if ! _is_valid_port "${p:-}"; then
                local l
                l=$(_snell_conf_get_value "listen" 2>/dev/null || true)
                p=$(_snell_parse_port_from_listen "$l" 2>/dev/null || true)
            fi
            _info "配置文件: ${_SNELL_CONFIG_FILE}"
            [[ -n "$p" ]] && _info "监听端口: ${p}"
        fi

        _separator
        _menu_pair "1" "安装/更新 Snell V5" "官方 snell-server" "green" "2" "配置并启动 Snell" "含端口冲突检查" "green"
        _menu_pair "3" "重启 Snell" "" "green" "4" "查看状态" "" "green"
        _menu_pair "5" "查看日志" "" "green" "6" "卸载 Snell" "可选删除配置" "yellow"
        _menu_item "0" "返回上级菜单" "" "red"
        _separator

        local ch
        read -rp "  选择 [0-6]: " ch
        case "$ch" in
            1) _snell_install_latest ;;
            2) _snell_configure ;;
            3) _snell_restart ;;
            4) _snell_status ;;
            5) _snell_log ;;
            6) _snell_uninstall ;;
            0) return ;;
            *) _error_no_exit "无效选项"; sleep 1 ;;
        esac
    done
}

# --- 12. Shadowsocks-Rust 管理 ---

_SSRUST_CONFIG_DIR="/etc/shadowsocks-rust"
_SSRUST_CONFIG_FILE="/etc/shadowsocks-rust/config.json"
_SSRUST_SYSTEMD_SERVICE_FILE="/etc/systemd/system/shadowsocks-rust.service"
_SSRUST_OPENRC_SERVICE_FILE="/etc/init.d/shadowsocks-rust"
_SSRUST_SERVICE_NAME="shadowsocks-rust"
_SSRUST_BIN="/usr/local/bin/ssserver"
_SSRUST_LOG_FILE="/var/log/shadowsocks-rust.log"
_SSRUST_ERR_FILE="/var/log/shadowsocks-rust.error.log"
_SSRUST_RELEASE_API="https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest"
_SSRUST_LAST_EXTRACT_ERROR=""

_ssrust_bin_version() {
    local bin_path out
    bin_path=$(command -v ssserver 2>/dev/null || true)
    [[ -z "$bin_path" ]] && bin_path="$_SSRUST_BIN"
    if [[ ! -x "$bin_path" ]]; then
        echo ""
        return
    fi
    out=$("$bin_path" --version 2>/dev/null | head -1 || true)
    [[ -z "$out" ]] && out=$("$bin_path" -V 2>/dev/null | head -1 || true)
    printf '%s' "$out"
}

_ssrust_running_pid() {
    local pid=""
    local pid_file="/run/${_SSRUST_SERVICE_NAME}.pid"
    local d p

    if [[ -f "$pid_file" ]]; then
        pid=$(tr -cd '0-9' < "$pid_file" 2>/dev/null || true)
        if _is_digit "${pid:-}" && kill -0 "$pid" >/dev/null 2>&1; then
            printf '%s' "$pid"
            return 0
        fi
    fi

    if command -v pgrep >/dev/null 2>&1; then
        pid=$(pgrep -x ssserver 2>/dev/null | head -n1 || true)
        if [[ -z "$pid" ]]; then
            # BusyBox pgrep 在部分版本不支持 -x
            pid=$(pgrep ssserver 2>/dev/null | head -n1 || true)
        fi
        if _is_digit "${pid:-}" && kill -0 "$pid" >/dev/null 2>&1; then
            printf '%s' "$pid"
            return 0
        fi
    fi

    if command -v pidof >/dev/null 2>&1; then
        pid=$(pidof ssserver 2>/dev/null | awk '{print $1}' || true)
        if _is_digit "${pid:-}" && kill -0 "$pid" >/dev/null 2>&1; then
            printf '%s' "$pid"
            return 0
        fi
    fi

    if command -v ps >/dev/null 2>&1; then
        pid=$(ps -eo pid=,comm= 2>/dev/null | awk '$2 == "ssserver" {print $1; exit}' || true)
        if _is_digit "${pid:-}" && kill -0 "$pid" >/dev/null 2>&1; then
            printf '%s' "$pid"
            return 0
        fi

        pid=$(ps -eo pid=,args= 2>/dev/null | awk '
            $0 ~ /(^|[[:space:]])ssserver([[:space:]]|$)/ {print $1; exit}
            $0 ~ /\/ssserver([[:space:]]|$)/ {print $1; exit}
        ' || true)
        if _is_digit "${pid:-}" && kill -0 "$pid" >/dev/null 2>&1; then
            printf '%s' "$pid"
            return 0
        fi

        # BusyBox ps 兼容
        pid=$(ps w 2>/dev/null | awk '/[s]sserver/ {if ($1 ~ /^[0-9]+$/) {print $1; exit}}' || true)
        if _is_digit "${pid:-}" && kill -0 "$pid" >/dev/null 2>&1; then
            printf '%s' "$pid"
            return 0
        fi
    fi

    # 最后兜底：直接遍历 /proc，避免依赖 pgrep/ps 参数兼容性
    for d in /proc/[0-9]*; do
        [[ -d "$d" ]] || continue
        p="${d##*/}"
        [[ "$p" =~ ^[0-9]+$ ]] || continue
        if [[ -r "$d/comm" ]]; then
            pid=$(head -n1 "$d/comm" 2>/dev/null || true)
            if [[ "$pid" == "ssserver" ]] && kill -0 "$p" >/dev/null 2>&1; then
                printf '%s' "$p"
                return 0
            fi
        fi
        if [[ -r "$d/cmdline" ]]; then
            if tr '\0' ' ' < "$d/cmdline" 2>/dev/null | grep -qE '(^|[[:space:]])ssserver([[:space:]]|$)|/ssserver([[:space:]]|$)'; then
                if kill -0 "$p" >/dev/null 2>&1; then
                    printf '%s' "$p"
                    return 0
                fi
            fi
        fi
    done
    return 1
}

_ssrust_detect_arch() {
    local machine
    machine=$(uname -m 2>/dev/null || echo unknown)
    case "$machine" in
        x86_64|amd64) echo "x86_64" ;;
        i386|i486|i586|i686) echo "i686" ;;
        aarch64|arm64) echo "aarch64" ;;
        armv7l|armv7|armhf) echo "armv7" ;;
        armv6l|armv6) echo "arm" ;;
        riscv64) echo "riscv64" ;;
        *) echo "" ;;
    esac
}

_ssrust_is_musl() {
    if command -v ldd >/dev/null 2>&1; then
        if ldd --version 2>&1 | grep -qi 'musl'; then
            return 0
        fi
    fi
    ls /lib/ld-musl-*.so.1 >/dev/null 2>&1
}

_ssrust_release_tag_from_json() {
    local release_json="$1"
    printf '%s\n' "$release_json" \
        | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        | head -1
}

_ssrust_asset_keywords() {
    local arch="$1" prefer_musl="$2"
    case "$arch" in
        x86_64)
            if [[ "$prefer_musl" == "1" ]]; then
                printf '%s\n' "x86_64-unknown-linux-musl" "x86_64-unknown-linux-gnu"
            else
                printf '%s\n' "x86_64-unknown-linux-gnu" "x86_64-unknown-linux-musl"
            fi
            ;;
        i686)
            if [[ "$prefer_musl" == "1" ]]; then
                printf '%s\n' "i686-unknown-linux-musl" "i686-unknown-linux-gnu"
            else
                printf '%s\n' "i686-unknown-linux-gnu" "i686-unknown-linux-musl"
            fi
            ;;
        aarch64)
            if [[ "$prefer_musl" == "1" ]]; then
                printf '%s\n' "aarch64-unknown-linux-musl" "aarch64-unknown-linux-gnu"
            else
                printf '%s\n' "aarch64-unknown-linux-gnu" "aarch64-unknown-linux-musl"
            fi
            ;;
        armv7)
            if [[ "$prefer_musl" == "1" ]]; then
                printf '%s\n' \
                    "armv7-unknown-linux-musleabihf" \
                    "arm-unknown-linux-musleabihf" \
                    "armv7-unknown-linux-gnueabihf" \
                    "arm-unknown-linux-gnueabihf"
            else
                printf '%s\n' \
                    "armv7-unknown-linux-gnueabihf" \
                    "arm-unknown-linux-gnueabihf" \
                    "armv7-unknown-linux-musleabihf" \
                    "arm-unknown-linux-musleabihf"
            fi
            ;;
        arm)
            if [[ "$prefer_musl" == "1" ]]; then
                printf '%s\n' "arm-unknown-linux-musleabihf" "arm-unknown-linux-gnueabihf"
            else
                printf '%s\n' "arm-unknown-linux-gnueabihf" "arm-unknown-linux-musleabihf"
            fi
            ;;
        riscv64)
            if [[ "$prefer_musl" == "1" ]]; then
                printf '%s\n' "riscv64gc-unknown-linux-musl" "riscv64gc-unknown-linux-gnu"
            else
                printf '%s\n' "riscv64gc-unknown-linux-gnu" "riscv64gc-unknown-linux-musl"
            fi
            ;;
        *)
            printf '%s\n' ""
            ;;
    esac
}

_ssrust_pick_asset_url() {
    local release_json="$1" arch="$2" prefer_musl="$3"
    local -a urls=() keywords=()
    local line kw url

    while IFS= read -r line; do
        [[ -n "$line" ]] && urls+=("$line")
    done < <(
        printf '%s\n' "$release_json" \
            | grep -oE 'https://[^"]+/download/[^"]+/shadowsocks-v[^"]+\.(tar\.xz|tar\.gz)' \
            | sort -u
    )
    (( ${#urls[@]} > 0 )) || return 1

    while IFS= read -r line; do
        [[ -n "$line" ]] && keywords+=("$line")
    done < <(_ssrust_asset_keywords "$arch" "$prefer_musl")

    for kw in "${keywords[@]}"; do
        for url in "${urls[@]}"; do
            if [[ "$url" == *"${kw}"* && "$url" == *"linux"* ]]; then
                printf '%s' "$url"
                return 0
            fi
        done
    done

    for url in "${urls[@]}"; do
        if [[ "$url" == *"${arch}"* && "$url" == *"linux"* ]]; then
            printf '%s' "$url"
            return 0
        fi
    done
    return 1
}

_ssrust_extract_archive() {
    local archive="$1" dst="$2" err_log
    err_log=$(mktemp /tmp/shadowsocks-rust.extract.XXXXXX.log)
    _SSRUST_LAST_EXTRACT_ERROR=""

    # 优先尝试自动识别，不依赖文件后缀
    tar -xf "$archive" -C "$dst" >/dev/null 2>"$err_log" && { rm -f "$err_log"; return 0; }

    # 常见压缩格式兼容路径
    tar -xJf "$archive" -C "$dst" >/dev/null 2>"$err_log" && { rm -f "$err_log"; return 0; }
    tar -xzf "$archive" -C "$dst" >/dev/null 2>"$err_log" && { rm -f "$err_log"; return 0; }
    if command -v unxz >/dev/null 2>&1; then
        unxz -c "$archive" 2>"$err_log" | tar -xf - -C "$dst" >/dev/null 2>>"$err_log" && { rm -f "$err_log"; return 0; }
    fi
    if command -v xz >/dev/null 2>&1; then
        xz -dc "$archive" 2>"$err_log" | tar -xf - -C "$dst" >/dev/null 2>>"$err_log" && { rm -f "$err_log"; return 0; }
    fi
    if command -v busybox >/dev/null 2>&1; then
        busybox xz -dc "$archive" 2>"$err_log" | tar -xf - -C "$dst" >/dev/null 2>>"$err_log" && { rm -f "$err_log"; return 0; }
    fi

    _SSRUST_LAST_EXTRACT_ERROR=$(tail -n 1 "$err_log" 2>/dev/null || true)
    rm -f "$err_log"
    return 1
}

_ssrust_try_install_xz() {
    _info "尝试安装 xz 解压组件..."
    if command -v apk >/dev/null 2>&1; then
        apk add --no-cache xz >/dev/null 2>&1 && return 0
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq >/dev/null 2>&1 || true
        apt-get install -y -qq xz-utils >/dev/null 2>&1 && return 0
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y xz >/dev/null 2>&1 && return 0
    elif command -v yum >/dev/null 2>&1; then
        yum install -y xz >/dev/null 2>&1 && return 0
    elif command -v zypper >/dev/null 2>&1; then
        zypper install -y xz >/dev/null 2>&1 && return 0
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm xz >/dev/null 2>&1 && return 0
    fi
    return 1
}

_ssrust_tmp_free_kb() {
    df -Pk /tmp 2>/dev/null | awk 'NR==2{print $4}'
}

_ssrust_is_container_like() {
    local virt
    virt="$(_detect_virt)"
    case "$virt" in
        lxc|openvz|docker|podman|containerd|systemd-nspawn)
            return 0
            ;;
    esac
    if grep -qaE '(docker|containerd|kubepods|lxc)' /proc/1/cgroup 2>/dev/null; then
        return 0
    fi
    return 1
}

_ssrust_strip_nofile_from_config() {
    local config_file="$1" tmp_file
    [[ -f "$config_file" ]] || return 0
    grep -q '"nofile"[[:space:]]*:' "$config_file" 2>/dev/null || return 0

    tmp_file=$(mktemp /tmp/shadowsocks-rust.config.XXXXXX.json)
    if ! awk '
        {
            if ($0 ~ /"nofile"[[:space:]]*:/) next
            lines[++n]=$0
        }
        END {
            for (i=1; i<=n; i++) {
                line=lines[i]
                if (line ~ /,[[:space:]]*$/) {
                    j=i+1
                    while (j<=n && lines[j] ~ /^[[:space:]]*$/) j++
                    if (j<=n && lines[j] ~ /^[[:space:]]*}/) sub(/,[[:space:]]*$/, "", line)
                }
                print line
            }
        }
    ' "$config_file" > "$tmp_file"; then
        rm -f "$tmp_file"
        return 1
    fi

    cat "$tmp_file" > "$config_file" || {
        rm -f "$tmp_file"
        return 1
    }
    rm -f "$tmp_file"
    return 0
}

_ssrust_install_latest_core() {
    local arch prefer_musl latest_json latest_version asset_url
    local tmp_pkg tmp_dir extracted_bin tmp_free_kb pkg_suffix

    if [[ "$(uname -s)" != "Linux" ]]; then
        _error_no_exit "shadowsocks-rust 仅支持 Linux 系统"
        return 1
    fi
    for cmd in curl tar; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            _error_no_exit "缺少必要命令: $cmd，请先安装"
            return 1
        fi
    done

    arch=$(_ssrust_detect_arch)
    if [[ -z "$arch" ]]; then
        _error_no_exit "不支持的架构: $(uname -m)"
        return 1
    fi

    prefer_musl="0"
    _ssrust_is_musl && prefer_musl="1"

    latest_json=$(curl -fsSL "$_SSRUST_RELEASE_API" 2>/dev/null || true)
    if [[ -z "$latest_json" ]]; then
        _error_no_exit "无法获取 shadowsocks-rust 最新版本信息"
        return 1
    fi
    latest_version=$(_ssrust_release_tag_from_json "$latest_json")
    if [[ -z "$latest_version" ]]; then
        _error_no_exit "解析 shadowsocks-rust 版本号失败"
        return 1
    fi

    asset_url=$(_ssrust_pick_asset_url "$latest_json" "$arch" "$prefer_musl")
    if [[ -z "$asset_url" ]]; then
        _error_no_exit "未找到匹配当前系统的 shadowsocks-rust 发行包"
        return 1
    fi

    pkg_suffix="pkg"
    [[ "$asset_url" == *.tar.xz ]] && pkg_suffix="tar.xz"
    [[ "$asset_url" == *.tar.gz ]] && pkg_suffix="tar.gz"
    tmp_pkg=$(mktemp "/tmp/shadowsocks-rust.XXXXXX.${pkg_suffix}")
    tmp_dir=$(mktemp -d /tmp/shadowsocks-rust.XXXXXX)

    tmp_free_kb=$(_ssrust_tmp_free_kb)
    if _is_digit "${tmp_free_kb:-}" && [ "$tmp_free_kb" -lt 20480 ]; then
        _warn "/tmp 可用空间较低 (${tmp_free_kb}KB)，解压可能失败，建议先清理磁盘空间"
    fi

    _info "下载 shadowsocks-rust: ${latest_version}"
    printf "    ${DIM}%s${PLAIN}\n" "$asset_url"
    if ! _mihomo_download "$asset_url" "$tmp_pkg"; then
        rm -rf "$tmp_pkg" "$tmp_dir"
        _error_no_exit "下载失败，请检查网络连接"
        return 1
    fi
    if [[ ! -s "$tmp_pkg" ]]; then
        rm -rf "$tmp_pkg" "$tmp_dir"
        _error_no_exit "下载文件为空，请稍后重试"
        return 1
    fi
    if ! _ssrust_extract_archive "$tmp_pkg" "$tmp_dir"; then
        if [[ "$asset_url" == *.xz ]] && _ssrust_try_install_xz; then
            if ! _ssrust_extract_archive "$tmp_pkg" "$tmp_dir"; then
                rm -rf "$tmp_pkg" "$tmp_dir"
                tmp_free_kb=$(_ssrust_tmp_free_kb)
                if _is_digit "${tmp_free_kb:-}" && [ "$tmp_free_kb" -lt 10240 ]; then
                    _error_no_exit "解压失败：/tmp 可用空间不足 (${tmp_free_kb}KB)"
                else
                    _error_no_exit "解压失败，请确认 tar/xz 支持已安装"
                fi
                [[ -n "${_SSRUST_LAST_EXTRACT_ERROR:-}" ]] && printf "  ${DIM}%s${PLAIN}\n" "$_SSRUST_LAST_EXTRACT_ERROR"
                return 1
            fi
        else
            rm -rf "$tmp_pkg" "$tmp_dir"
            tmp_free_kb=$(_ssrust_tmp_free_kb)
            if _is_digit "${tmp_free_kb:-}" && [ "$tmp_free_kb" -lt 10240 ]; then
                _error_no_exit "解压失败：/tmp 可用空间不足 (${tmp_free_kb}KB)"
            else
                _error_no_exit "解压失败，请确认 tar/xz 支持已安装"
            fi
            [[ -n "${_SSRUST_LAST_EXTRACT_ERROR:-}" ]] && printf "  ${DIM}%s${PLAIN}\n" "$_SSRUST_LAST_EXTRACT_ERROR"
            return 1
        fi
    fi

    extracted_bin=$(find "$tmp_dir" -type f -name 'ssserver' | head -1)
    if [[ -z "$extracted_bin" || ! -f "$extracted_bin" ]]; then
        rm -rf "$tmp_pkg" "$tmp_dir"
        _error_no_exit "发行包中未找到 ssserver 可执行文件"
        return 1
    fi

    install -m 0755 "$extracted_bin" "$_SSRUST_BIN"
    rm -rf "$tmp_pkg" "$tmp_dir"

    if [[ ! -x "$_SSRUST_BIN" ]]; then
        _error_no_exit "ssserver 安装失败"
        return 1
    fi

    _success "shadowsocks-rust 安装完成"
    _info "版本: $(_ssrust_bin_version)"
    _info "可执行文件: $_SSRUST_BIN"
    return 0
}

_ssrust_install_or_update() {
    _header "Shadowsocks-Rust 安装/更新"
    _time_sync_check_and_enable
    _ssrust_install_latest_core
    _press_any_key
}

_ssrust_conf_get_value() {
    local key="$1"
    [[ -f "$_SSRUST_CONFIG_FILE" ]] || return 1
    awk -v k="$key" '
        {
            line=$0
            if (line ~ "\"" k "\"[[:space:]]*:") {
                sub(/^[^:]*:[[:space:]]*/, "", line)
                sub(/[[:space:]]*,?[[:space:]]*$/, "", line)
                gsub(/^"/, "", line)
                gsub(/"$/, "", line)
                gsub(/^[[:space:]]+/, "", line)
                gsub(/[[:space:]]+$/, "", line)
                print line
                exit
            }
        }
    ' "$_SSRUST_CONFIG_FILE"
}

_ssrust_is_ss2022_aes_method() {
    case "${1:-}" in
        2022-blake3-aes-128-gcm|2022-blake3-aes-256-gcm) return 0 ;;
    esac
    return 1
}

_ssrust_gen_password_for_method() {
    local method="${1:-}"
    case "$method" in
        2022-blake3-aes-128-gcm) _mihomoconf_gen_ss_password_128 ;;
        2022-blake3-aes-256-gcm) _mihomoconf_gen_ss_password_256 ;;
        *) _mihomoconf_gen_anytls_password ;;
    esac
}

_ssrust_password_decoded_len() {
    local password="$1" decoded_len
    decoded_len=$(printf '%s' "$password" | base64 -d 2>/dev/null | wc -c | tr -d '[:space:]' || true)
    if ! _is_digit "${decoded_len:-}" || [ "$decoded_len" -eq 0 ]; then
        decoded_len=$(printf '%s' "$password" | base64 --decode 2>/dev/null | wc -c | tr -d '[:space:]' || true)
    fi
    _is_digit "${decoded_len:-}" || decoded_len="0"
    printf '%s' "$decoded_len"
}

_ssrust_method_password_compatible() {
    local method="${1:-}" password="${2:-}" decoded_len
    case "$method" in
        2022-blake3-aes-128-gcm)
            decoded_len=$(_ssrust_password_decoded_len "$password")
            [[ "$decoded_len" == "16" ]]
            ;;
        2022-blake3-aes-256-gcm)
            decoded_len=$(_ssrust_password_decoded_len "$password")
            [[ "$decoded_len" == "32" ]]
            ;;
        *)
            return 0
            ;;
    esac
}

_ssrust_port_conflict_with_mihomo() {
    local port="$1"
    if declare -F _snell_port_conflict_with_mihomo >/dev/null 2>&1; then
        _snell_port_conflict_with_mihomo "$port"
        return $?
    fi
    return 1
}

_ssrust_pick_listen_port() {
    local default_port="${1:-8388}"
    local port_input usage_line
    while true; do
        read -rp "  Shadowsocks-Rust 监听端口 [默认 ${default_port}]: " port_input
        port_input=$(_mihomoconf_trim "${port_input:-$default_port}")
        if ! _is_valid_port "$port_input"; then
            _warn "端口无效，请输入 1-65535 的数字"
            continue
        fi
        if _ssrust_port_conflict_with_mihomo "$port_input"; then
            _warn "端口 ${port_input} 与 mihomo 配置冲突（listeners/port/mixed-port 等），请更换端口"
            continue
        fi
        usage_line=$(_snell_port_usage_line "$port_input")
        if [[ -n "$usage_line" && "$usage_line" != *"ssserver"* ]]; then
            _warn "端口 ${port_input} 已被占用: ${usage_line}"
            continue
        fi
        printf '%s' "$port_input"
        return 0
    done
}

_ssrust_gen_ss_uri_link() {
    local server="$1" port="$2" method="$3" password="$4" name="$5"
    local userinfo encoded_name server_uri
    userinfo=$(_mihomoconf_url_base64 "${method}:${password}")
    encoded_name=$(_mihomoconf_urlencode "${name}")
    server_uri=$(_snell_uri_host "$server")
    printf 'ss://%s@%s:%s#%s' "$userinfo" "$server_uri" "$port" "$encoded_name"
}

_ssrust_write_config() {
    local listen_addr="$1" port="$2" method="$3" password="$4" mode="$5"
    mkdir -p "$_SSRUST_CONFIG_DIR"
    cat > "$_SSRUST_CONFIG_FILE" <<EOF
{
  "server": "${listen_addr}",
  "server_port": ${port},
  "password": "${password}",
  "method": "${method}",
  "mode": "${mode}",
  "fast_open": false
}
EOF
    chmod 600 "$_SSRUST_CONFIG_FILE"
}

_ssrust_systemd_service_configured() {
    _has_systemd || return 1
    systemctl is-enabled "${_SSRUST_SERVICE_NAME}.service" &>/dev/null \
        || systemctl is-active "${_SSRUST_SERVICE_NAME}.service" &>/dev/null \
        || [[ -f "$_SSRUST_SYSTEMD_SERVICE_FILE" ]]
}

_ssrust_openrc_service_configured() {
    _has_openrc || return 1
    [[ -x "$_SSRUST_OPENRC_SERVICE_FILE" ]] || _openrc_service_in_default "$_SSRUST_SERVICE_NAME"
}

_ssrust_service_is_active() {
    if _has_systemd && systemctl is-active --quiet "$_SSRUST_SERVICE_NAME" 2>/dev/null; then
        return 0
    fi
    if _has_openrc && rc-service "$_SSRUST_SERVICE_NAME" status >/dev/null 2>&1; then
        return 0
    fi
    _ssrust_running_pid >/dev/null 2>&1
}

_ssrust_restart_now() {
    local ss_bin config_file
    ss_bin=$(command -v ssserver 2>/dev/null || true)
    [[ -z "$ss_bin" ]] && ss_bin="$_SSRUST_BIN"
    config_file="$_SSRUST_CONFIG_FILE"

    if [[ ! -x "$ss_bin" ]]; then
        _error_no_exit "未检测到 ssserver，请先安装"
        return 1
    fi
    if [[ ! -f "$config_file" ]]; then
        _error_no_exit "未找到配置文件: ${config_file}"
        return 1
    fi
    if _ssrust_is_container_like; then
        _ssrust_strip_nofile_from_config "$config_file" || true
    fi

    if _ssrust_systemd_service_configured; then
        _info "通过 systemd 重启 shadowsocks-rust..."
        if ! systemctl restart "$_SSRUST_SERVICE_NAME" >/dev/null 2>&1; then
            _error_no_exit "重启失败，请检查: systemctl status ${_SSRUST_SERVICE_NAME}"
            return 1
        fi
        sleep 1
        if systemctl is-active --quiet "$_SSRUST_SERVICE_NAME"; then
            _success "shadowsocks-rust 已成功重启"
            return 0
        fi
        _error_no_exit "服务未激活，请检查: systemctl status ${_SSRUST_SERVICE_NAME}"
        return 1
    fi

    if _ssrust_openrc_service_configured; then
        _info "通过 OpenRC 重启 shadowsocks-rust..."
        if ! rc-service "$_SSRUST_SERVICE_NAME" restart >/dev/null 2>&1; then
            if ! rc-service "$_SSRUST_SERVICE_NAME" start >/dev/null 2>&1; then
                _error_no_exit "重启失败，请检查: rc-service ${_SSRUST_SERVICE_NAME} status"
                return 1
            fi
        fi
        sleep 1
        if _ssrust_service_is_active; then
            _success "shadowsocks-rust 已成功重启"
            return 0
        fi
        _error_no_exit "服务未激活，请检查: rc-service ${_SSRUST_SERVICE_NAME} status"
        return 1
    fi

    local pid
    pid=$(_ssrust_running_pid 2>/dev/null || true)
    if [[ -n "$pid" ]]; then
        _info "终止旧进程 (PID: $pid)..."
        kill "$pid" >/dev/null 2>&1 || true
        sleep 1
    fi
    mkdir -p "$(dirname "$_SSRUST_LOG_FILE")"
    nohup "$ss_bin" -c "$config_file" >>"$_SSRUST_LOG_FILE" 2>>"$_SSRUST_ERR_FILE" &
    sleep 1
    if _ssrust_running_pid >/dev/null 2>&1; then
        _success "shadowsocks-rust 已启动 (非 systemd/OpenRC 模式)"
        return 0
    fi
    _error_no_exit "shadowsocks-rust 启动失败"
    return 1
}

_ssrust_enable_now() {
    local force_rewrite="${1:-0}"
    local ss_bin config_file
    ss_bin=$(command -v ssserver 2>/dev/null || true)
    [[ -z "$ss_bin" ]] && ss_bin="$_SSRUST_BIN"
    config_file="$_SSRUST_CONFIG_FILE"

    if [[ ! -x "$ss_bin" ]]; then
        _error_no_exit "未检测到 ssserver，请先安装"
        return 1
    fi
    if [[ ! -f "$config_file" ]]; then
        _error_no_exit "未找到配置文件: ${config_file}"
        return 1
    fi
    if _ssrust_is_container_like; then
        _ssrust_strip_nofile_from_config "$config_file" || true
    fi

    if _has_systemd; then
        if [[ "$force_rewrite" == "1" || ! -f "$_SSRUST_SYSTEMD_SERVICE_FILE" ]]; then
            _info "生成 systemd 服务文件..."
            cat > "$_SSRUST_SYSTEMD_SERVICE_FILE" <<EOF
[Unit]
Description=Shadowsocks-Rust Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${ss_bin} -c ${config_file}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
        fi
        systemctl daemon-reload >/dev/null 2>&1 || true
        if ! systemctl enable "$_SSRUST_SERVICE_NAME" >/dev/null 2>&1; then
            _error_no_exit "设置开机自启失败，请检查 systemctl 状态"
            return 1
        fi
        _info "已设置开机自启"
        if ! systemctl restart "$_SSRUST_SERVICE_NAME" >/dev/null 2>&1; then
            _error_no_exit "启动失败，请检查: systemctl status ${_SSRUST_SERVICE_NAME}"
            return 1
        fi
        sleep 1
        if systemctl is-active --quiet "$_SSRUST_SERVICE_NAME"; then
            _success "shadowsocks-rust 已成功启动"
            return 0
        fi
        _error_no_exit "服务未激活，请检查: systemctl status ${_SSRUST_SERVICE_NAME}"
        return 1
    fi

    if _has_openrc; then
        if [[ "$force_rewrite" == "1" || ! -f "$_SSRUST_OPENRC_SERVICE_FILE" ]]; then
            _info "生成 OpenRC 服务文件..."
            cat > "$_SSRUST_OPENRC_SERVICE_FILE" <<EOF
#!/sbin/openrc-run
name="Shadowsocks-Rust"
description="Shadowsocks-Rust Server"

command="${ss_bin}"
command_args="-c ${config_file}"
command_background=true
pidfile="/run/${_SSRUST_SERVICE_NAME}.pid"
output_log="${_SSRUST_LOG_FILE}"
error_log="${_SSRUST_ERR_FILE}"

depend() {
    need net
}
EOF
            chmod 0755 "$_SSRUST_OPENRC_SERVICE_FILE" || {
                _error_no_exit "写入 OpenRC 服务文件失败: ${_SSRUST_OPENRC_SERVICE_FILE}"
                return 1
            }
        fi
        if ! rc-update add "$_SSRUST_SERVICE_NAME" default >/dev/null 2>&1; then
            if ! _openrc_service_in_default "$_SSRUST_SERVICE_NAME"; then
                _error_no_exit "设置开机自启失败，请检查 rc-update 状态"
                return 1
            fi
        fi
        _info "已设置开机自启 (OpenRC)"
        if ! rc-service "$_SSRUST_SERVICE_NAME" restart >/dev/null 2>&1; then
            if ! rc-service "$_SSRUST_SERVICE_NAME" start >/dev/null 2>&1; then
                _error_no_exit "启动失败，请检查: rc-service ${_SSRUST_SERVICE_NAME} status"
                return 1
            fi
        fi
        sleep 1
        if _ssrust_service_is_active; then
            _success "shadowsocks-rust 已成功启动"
            return 0
        fi
        _error_no_exit "服务未激活，请检查: rc-service ${_SSRUST_SERVICE_NAME} status"
        return 1
    fi

    _warn "当前系统未检测到 systemd/OpenRC，无法配置开机自启，仅尝试立即启动"
    _ssrust_restart_now && return 0
    _error_no_exit "shadowsocks-rust 启动失败"
    return 1
}

_ssrust_configure() {
    _header "Shadowsocks-Rust 配置"

    local install_confirm
    if ! command -v ssserver >/dev/null 2>&1 && [[ ! -x "$_SSRUST_BIN" ]]; then
        read -rp "  未检测到 ssserver，是否先安装最新版? [Y/n]: " install_confirm
        if [[ "$install_confirm" =~ ^([Nn]|[Nn][Oo])$ ]]; then
            _info "已取消"
            _press_any_key
            return
        fi
        _time_sync_check_and_enable
        if ! _ssrust_install_latest_core; then
            _press_any_key
            return
        fi
    fi

    local current_port current_method current_password current_mode current_server
    local listen_port method_pick method_default method_value
    local password_input password_value current_password_compatible
    local mode_pick mode_default mode_value
    local listen_input listen_addr host_default host_input client_host
    local uri_link udp_bool

    current_port=$(_ssrust_conf_get_value "server_port" 2>/dev/null || true)
    _is_valid_port "${current_port:-}" || current_port="8388"
    current_method=$(_ssrust_conf_get_value "method" 2>/dev/null || true)
    current_password=$(_ssrust_conf_get_value "password" 2>/dev/null || true)
    current_mode=$(_ssrust_conf_get_value "mode" 2>/dev/null || true)
    current_server=$(_ssrust_conf_get_value "server" 2>/dev/null || true)

    listen_port=$(_ssrust_pick_listen_port "$current_port")

    case "$current_method" in
        aes-256-gcm) method_default="2" ;;
        aes-128-gcm) method_default="3" ;;
        2022-blake3-aes-128-gcm) method_default="4" ;;
        2022-blake3-aes-256-gcm) method_default="5" ;;
        chacha20-ietf-poly1305|*) method_default="1" ;;
    esac
    _separator
    _menu_pair "1" "chacha20-ietf-poly1305" "默认/兼容性高" "green" "2" "aes-256-gcm" "" "green"
    _menu_pair "3" "aes-128-gcm" "" "green" "4" "2022-blake3-aes-128-gcm" "SS2022-AES-128" "green"
    _menu_pair "5" "2022-blake3-aes-256-gcm" "SS2022-AES-256" "green" "0" "取消" "" "red"
    _separator
    read -rp "  加密方法 [0-5，默认 ${method_default}]: " method_pick
    case "${method_pick:-$method_default}" in
        1) method_value="chacha20-ietf-poly1305" ;;
        2) method_value="aes-256-gcm" ;;
        3) method_value="aes-128-gcm" ;;
        4) method_value="2022-blake3-aes-128-gcm" ;;
        5) method_value="2022-blake3-aes-256-gcm" ;;
        0) _info "已取消"; _press_any_key; return ;;
        *) _error_no_exit "无效选项"; _press_any_key; return ;;
    esac

    if _ssrust_is_ss2022_aes_method "$method_value"; then
        _info "SS2022-AES 需要 Base64 密钥（128=16字节，256=32字节）"
    fi

    current_password_compatible="0"
    if [[ -n "$current_password" ]] && _ssrust_method_password_compatible "$method_value" "$current_password"; then
        current_password_compatible="1"
    fi

    read -rp "  密码 [留空自动生成兼容密钥/保留当前兼容值]: " password_input
    password_input=$(_mihomoconf_trim "${password_input:-}")
    if [[ -n "$password_input" ]]; then
        password_value="$password_input"
    elif [[ "$current_password_compatible" == "1" ]]; then
        password_value="$current_password"
    else
        password_value=$(_ssrust_gen_password_for_method "$method_value")
        if [[ -n "$current_password" && "$current_password_compatible" != "1" ]]; then
            _warn "当前密码与所选加密方法不匹配，已自动生成兼容密钥"
        fi
    fi
    if [[ -z "$password_value" ]]; then
        _error_no_exit "密码不能为空"
        _press_any_key
        return
    fi
    if [[ "$password_value" == *\"* || "$password_value" == *\\* ]]; then
        _error_no_exit "密码不能包含双引号或反斜杠，以免破坏 JSON 配置"
        _press_any_key
        return
    fi
    if _ssrust_is_ss2022_aes_method "$method_value" && ! _ssrust_method_password_compatible "$method_value" "$password_value"; then
        _error_no_exit "SS2022-AES 密钥格式无效，请输入对应长度的 Base64 密钥（128=16字节，256=32字节）"
        _press_any_key
        return
    fi

    case "$current_mode" in
        tcp_only) mode_default="2" ;;
        udp_only) mode_default="3" ;;
        tcp_and_udp|*) mode_default="1" ;;
    esac
    _separator
    _menu_pair "1" "tcp_and_udp" "默认" "green" "2" "tcp_only" "" "green"
    _menu_pair "3" "udp_only" "" "green" "0" "取消" "" "red"
    _separator
    read -rp "  传输模式 [0-3，默认 ${mode_default}]: " mode_pick
    case "${mode_pick:-$mode_default}" in
        1) mode_value="tcp_and_udp" ;;
        2) mode_value="tcp_only" ;;
        3) mode_value="udp_only" ;;
        0) _info "已取消"; _press_any_key; return ;;
        *) _error_no_exit "无效选项"; _press_any_key; return ;;
    esac

    [[ -z "$current_server" ]] && current_server="0.0.0.0"
    read -rp "  监听地址 [默认 ${current_server}，如 0.0.0.0 / ::]: " listen_input
    listen_addr=$(_mihomoconf_trim "${listen_input:-$current_server}")
    if [[ -z "$listen_addr" ]]; then
        _error_no_exit "监听地址不能为空"
        _press_any_key
        return
    fi
    if [[ "$listen_addr" == *\"* || "$listen_addr" == *\\* ]]; then
        _error_no_exit "监听地址不能包含双引号或反斜杠"
        _press_any_key
        return
    fi

    _ssrust_write_config "$listen_addr" "$listen_port" "$method_value" "$password_value" "$mode_value"
    _info "配置文件已写入: $_SSRUST_CONFIG_FILE"

    if ! _ssrust_enable_now "0"; then
        _warn "自动启动失败，请检查日志后重试"
        _press_any_key
        return
    fi

    host_default=$(_mihomoconf_get_saved_host "$_MIHOMOCONF_CONFIG_FILE" 2>/dev/null || true)
    [[ -z "$host_default" ]] && host_default=$(_mihomoconf_get_server_ip)
    read -rp "  客户端连接地址 [默认 ${host_default}]: " host_input
    client_host=$(_mihomoconf_trim "${host_input:-$host_default}")
    [[ -z "$client_host" ]] && client_host="$host_default"

    uri_link=$(_ssrust_gen_ss_uri_link "$client_host" "$listen_port" "$method_value" "$password_value" "SS-Rust")
    udp_bool="true"
    [[ "$mode_value" == "tcp_only" ]] && udp_bool="false"

    echo ""
    _separator
    printf "  ${BOLD}Shadowsocks-Rust 客户端参数${PLAIN}\n"
    _separator
    printf "    server   : %s\n" "$client_host"
    printf "    port     : %s\n" "$listen_port"
    printf "    method   : %s\n" "$method_value"
    printf "    password : %s\n" "$password_value"
    printf "    mode     : %s\n" "$mode_value"

    echo ""
    printf "  ${BOLD}SS URI 链接${PLAIN}\n"
    printf "  %s\n" "$uri_link"

    echo ""
    printf "  ${BOLD}Mihomo/Sing-Box 片段${PLAIN}\n"
    cat <<EOF
  proxies:
    - name: "SS-Rust"
      type: ss
      server: ${client_host}
      port: ${listen_port}
      cipher: ${method_value}
      password: "${password_value}"
      udp: ${udp_bool}
EOF
    _press_any_key
}

_ssrust_enable() {
    _header "Shadowsocks-Rust 自启动配置"

    local service_file=""
    local service_name=""
    local force_rewrite="0"

    if _has_systemd; then
        service_file="$_SSRUST_SYSTEMD_SERVICE_FILE"
        service_name="systemd"
    elif _has_openrc; then
        service_file="$_SSRUST_OPENRC_SERVICE_FILE"
        service_name="OpenRC"
    fi

    if [[ -n "$service_file" && -f "$service_file" ]]; then
        _warn "${service_name} 服务文件已存在"
        local overwrite
        read -rp "  是否覆盖? [y/N]: " overwrite
        if [[ ! "$overwrite" =~ ^[Yy] ]]; then
            _press_any_key
            return
        fi
        force_rewrite="1"
    fi

    _ssrust_enable_now "$force_rewrite"
    _press_any_key
}

_ssrust_restart() {
    _header "Shadowsocks-Rust 重启"
    _ssrust_restart_now
    _press_any_key
}

_ssrust_status() {
    _header "Shadowsocks-Rust 运行状态"
    echo ""
    if _ssrust_systemd_service_configured; then
        systemctl status "$_SSRUST_SERVICE_NAME" --no-pager || true
    elif _ssrust_openrc_service_configured; then
        rc-service "$_SSRUST_SERVICE_NAME" status || true
    fi
    local pid
    pid=$(_ssrust_running_pid 2>/dev/null || true)
    if _ssrust_service_is_active; then
        if [[ -n "$pid" ]]; then
            printf "${GREEN}  ✔ ${PLAIN}运行状态: ${GREEN}运行中${PLAIN} (PID: %s)\n" "$pid"
        else
            printf "${GREEN}  ✔ ${PLAIN}运行状态: ${GREEN}运行中${PLAIN}\n"
        fi
    else
        printf "${GREEN}  ✔ ${PLAIN}运行状态: ${RED}未运行${PLAIN}\n"
    fi
    if [[ -f "$_SSRUST_CONFIG_FILE" ]]; then
        _info "配置文件: $_SSRUST_CONFIG_FILE"
        _info "监听端口: $(_ssrust_conf_get_value "server_port" 2>/dev/null || echo unknown)"
        _info "加密方式: $(_ssrust_conf_get_value "method" 2>/dev/null || echo unknown)"
    fi
    _press_any_key
}

_ssrust_export_node_config() {
    _header "导出 Shadowsocks-Rust 节点配置文件"

    if [[ ! -f "$_SSRUST_CONFIG_FILE" ]]; then
        _error_no_exit "未找到配置文件: $_SSRUST_CONFIG_FILE"
        _info "请先执行「配置并启动 Shadowsocks-Rust」"
        _press_any_key
        return
    fi

    local listen_port method password mode server
    local host_default host_input client_host node_name node_name_input
    local uri_link udp_bool network_json_line
    local q_name q_server q_method q_password
    local safe_host export_dir base_name
    local txt_file mihomo_file singbox_file

    listen_port=$(_ssrust_conf_get_value "server_port" 2>/dev/null || true)
    method=$(_ssrust_conf_get_value "method" 2>/dev/null || true)
    password=$(_ssrust_conf_get_value "password" 2>/dev/null || true)
    mode=$(_ssrust_conf_get_value "mode" 2>/dev/null || true)
    server=$(_ssrust_conf_get_value "server" 2>/dev/null || true)

    if ! _is_valid_port "${listen_port:-}"; then
        _error_no_exit "配置中的端口无效，请先重新配置"
        _press_any_key
        return
    fi
    if [[ -z "$method" || -z "$password" ]]; then
        _error_no_exit "配置缺少 method/password，请先重新配置"
        _press_any_key
        return
    fi

    host_default=$(_mihomoconf_get_saved_host "$_MIHOMOCONF_CONFIG_FILE" 2>/dev/null || true)
    [[ -z "$host_default" ]] && host_default=$(_mihomoconf_get_server_ip)
    [[ -z "$host_default" ]] && host_default="${server:-YOUR_SERVER_IP}"

    read -rp "  客户端连接地址 [默认 ${host_default}]: " host_input
    client_host=$(_mihomoconf_trim "${host_input:-$host_default}")
    if [[ -z "$client_host" ]]; then
        _error_no_exit "客户端连接地址不能为空"
        _press_any_key
        return
    fi

    node_name="SS-Rust-${listen_port}"
    read -rp "  节点名称 [默认 ${node_name}]: " node_name_input
    node_name=$(_mihomoconf_trim "${node_name_input:-$node_name}")
    [[ -z "$node_name" ]] && node_name="SS-Rust-${listen_port}"

    uri_link=$(_ssrust_gen_ss_uri_link "$client_host" "$listen_port" "$method" "$password" "$node_name")
    udp_bool="true"
    [[ "$mode" == "tcp_only" ]] && udp_bool="false"
    network_json_line=""
    case "$mode" in
        tcp_only) network_json_line='  "network": "tcp",' ;;
        udp_only) network_json_line='  "network": "udp",' ;;
    esac

    q_name=$(_mihomochain_yaml_quote "$node_name")
    q_server=$(_mihomochain_yaml_quote "$client_host")
    q_method=$(_mihomochain_yaml_quote "$method")
    q_password=$(_mihomochain_yaml_quote "$password")

    safe_host=$(printf '%s' "$client_host" | tr -c 'A-Za-z0-9._-' '_')
    [[ -z "$safe_host" ]] && safe_host="server"
    export_dir="/root/vpsgo-export"
    if ! mkdir -p "$export_dir" >/dev/null 2>&1; then
        export_dir="/tmp/vpsgo-export"
        mkdir -p "$export_dir" >/dev/null 2>&1 || {
            _error_no_exit "创建导出目录失败: /root/vpsgo-export 和 /tmp/vpsgo-export"
            _press_any_key
            return
        }
    fi

    base_name="${safe_host}-${listen_port}"
    txt_file="${export_dir}/ssrust-${base_name}.txt"
    mihomo_file="${export_dir}/ssrust-${base_name}.mihomo.yaml"
    singbox_file="${export_dir}/ssrust-${base_name}.singbox.json"

    cat > "$txt_file" <<EOF
# Shadowsocks-Rust Node Export
name=${node_name}
server=${client_host}
port=${listen_port}
method=${method}
password=${password}
mode=${mode}
uri=${uri_link}
EOF

    cat > "$mihomo_file" <<EOF
proxies:
  - name: "${q_name}"
    type: ss
    server: "${q_server}"
    port: ${listen_port}
    cipher: "${q_method}"
    password: "${q_password}"
    udp: ${udp_bool}
EOF

    cat > "$singbox_file" <<EOF
{
  "type": "shadowsocks",
  "tag": "${q_name}",
  "server": "${q_server}",
  "server_port": ${listen_port},
  "method": "${q_method}",
${network_json_line}
  "password": "${q_password}"
}
EOF

    echo ""
    _success "节点配置文件已导出"
    printf "    文本参数   : %s\n" "$txt_file"
    printf "    Mihomo 配置: %s\n" "$mihomo_file"
    printf "    Sing-Box 配置: %s\n" "$singbox_file"
    echo ""
    printf "  ${BOLD}SS URI 链接${PLAIN}\n"
    printf "  %s\n" "$uri_link"
    _press_any_key
}

_ssrust_log() {
    _header "Shadowsocks-Rust 日志"
    echo ""
    if _ssrust_systemd_service_configured; then
        _info "显示最近 50 行日志 (Ctrl+C 退出实时跟踪)"
        _separator
        echo ""
        journalctl -u "$_SSRUST_SERVICE_NAME" --no-pager -n 50
        echo ""
        _separator
        local follow
        read -rp "  是否实时跟踪日志? [y/N]: " follow
        if [[ "$follow" =~ ^[Yy] ]]; then
            journalctl -u "$_SSRUST_SERVICE_NAME" -f
        fi
    else
        if ! _tail_log_files_interactive "ss-rust" "$_SSRUST_LOG_FILE" "$_SSRUST_ERR_FILE" "rc-service ${_SSRUST_SERVICE_NAME} status"; then
            _warn "未检测到日志文件"
            _info "提示: 可先执行「配置并启动 Shadowsocks-Rust」"
        fi
    fi
    _press_any_key
}

_ssrust_uninstall() {
    _header "Shadowsocks-Rust 卸载"

    local confirm remove_config remove_logs bin_path p removed_count=0
    local -a bin_candidates=()

    bin_path=$(command -v ssserver 2>/dev/null || true)

    _warn "将停止并卸载 Shadowsocks-Rust，可选删除配置目录与日志。"
    printf "    systemd 服务文件: %s\n" "$_SSRUST_SYSTEMD_SERVICE_FILE"
    printf "    OpenRC 服务文件 : %s\n" "$_SSRUST_OPENRC_SERVICE_FILE"
    if [[ -n "$bin_path" ]]; then
        printf "    可执行文件: %s\n" "$bin_path"
    else
        printf "    可执行文件: %s\n" "$_SSRUST_BIN"
    fi
    printf "    配置目录: %s\n" "$_SSRUST_CONFIG_DIR"
    read -rp "  确认卸载 Shadowsocks-Rust? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy] ]]; then
        _info "已取消"
        _press_any_key
        return
    fi

    if _has_systemd; then
        systemctl stop "$_SSRUST_SERVICE_NAME" >/dev/null 2>&1 || true
        systemctl disable "$_SSRUST_SERVICE_NAME" >/dev/null 2>&1 || true
    fi
    if _has_openrc; then
        rc-service "$_SSRUST_SERVICE_NAME" stop >/dev/null 2>&1 || true
        rc-update del "$_SSRUST_SERVICE_NAME" default >/dev/null 2>&1 || true
    fi
    pkill -x ssserver >/dev/null 2>&1 || true

    if [[ -f "$_SSRUST_SYSTEMD_SERVICE_FILE" ]]; then
        rm -f "$_SSRUST_SYSTEMD_SERVICE_FILE"
        removed_count=$((removed_count + 1))
        _info "已删除服务文件: $_SSRUST_SYSTEMD_SERVICE_FILE"
    fi
    if [[ -f "$_SSRUST_OPENRC_SERVICE_FILE" ]]; then
        rm -f "$_SSRUST_OPENRC_SERVICE_FILE"
        removed_count=$((removed_count + 1))
        _info "已删除服务文件: $_SSRUST_OPENRC_SERVICE_FILE"
    fi
    if _has_systemd; then
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl reset-failed "$_SSRUST_SERVICE_NAME" >/dev/null 2>&1 || true
    fi

    [[ -n "$bin_path" ]] && bin_candidates+=("$bin_path")
    [[ "$_SSRUST_BIN" != "$bin_path" ]] && bin_candidates+=("$_SSRUST_BIN")
    [[ "/usr/bin/ssserver" != "$bin_path" ]] && bin_candidates+=("/usr/bin/ssserver")
    for p in "${bin_candidates[@]}"; do
        [[ -z "$p" ]] && continue
        if [[ -f "$p" || -L "$p" ]]; then
            rm -f "$p"
            removed_count=$((removed_count + 1))
            _info "已删除可执行文件: $p"
        fi
    done

    if [[ -d "$_SSRUST_CONFIG_DIR" ]]; then
        read -rp "  是否同时删除配置目录 ${_SSRUST_CONFIG_DIR}? [y/N]: " remove_config
        if [[ "$remove_config" =~ ^[Yy] ]]; then
            rm -rf "$_SSRUST_CONFIG_DIR"
            removed_count=$((removed_count + 1))
            _info "已删除配置目录: $_SSRUST_CONFIG_DIR"
        else
            _info "已保留配置目录: $_SSRUST_CONFIG_DIR"
        fi
    fi

    if [[ -f "$_SSRUST_LOG_FILE" || -f "$_SSRUST_ERR_FILE" ]]; then
        read -rp "  是否同时删除日志文件? [y/N]: " remove_logs
        if [[ "$remove_logs" =~ ^[Yy] ]]; then
            rm -f "$_SSRUST_LOG_FILE" "$_SSRUST_ERR_FILE"
            removed_count=$((removed_count + 1))
            _info "已删除日志文件"
        else
            _info "已保留日志文件"
        fi
    fi

    if (( removed_count == 0 )); then
        _warn "未检测到可删除的 Shadowsocks-Rust 文件，已完成服务清理。"
    else
        _success "Shadowsocks-Rust 卸载完成"
    fi
    _press_any_key
}

_ssrust_manage() {
    while true; do
        _header "Shadowsocks-Rust 管理"
        echo ""

        if command -v ssserver >/dev/null 2>&1 || [[ -x "$_SSRUST_BIN" ]]; then
            local ver
            ver=$(_ssrust_bin_version)
            [[ -n "$ver" ]] && _info "当前版本: ${ver}" || _info "当前已安装 ssserver"
            local pid
            pid=$(_ssrust_running_pid 2>/dev/null || true)
            if _ssrust_service_is_active; then
                if [[ -n "$pid" ]]; then
                    printf "${GREEN}  ✔ ${PLAIN}运行状态: ${GREEN}运行中${PLAIN} (PID: $pid)\n"
                else
                    printf "${GREEN}  ✔ ${PLAIN}运行状态: ${GREEN}运行中${PLAIN}\n"
                fi
            else
                printf "${GREEN}  ✔ ${PLAIN}运行状态: ${RED}未运行${PLAIN}\n"
            fi
        else
            _info "当前未安装 shadowsocks-rust"
        fi
        if [[ -f "$_SSRUST_CONFIG_FILE" ]]; then
            local p m
            p=$(_ssrust_conf_get_value "server_port" 2>/dev/null || true)
            m=$(_ssrust_conf_get_value "method" 2>/dev/null || true)
            _info "配置文件: ${_SSRUST_CONFIG_FILE}"
            [[ -n "$p" ]] && _info "监听端口: ${p}"
            [[ -n "$m" ]] && _info "加密方式: ${m}"
        fi

        _separator
        _menu_pair "1" "安装/更新 Shadowsocks-Rust" "官方 releases" "green" "2" "配置并启动 Shadowsocks-Rust" "含端口冲突检查" "green"
        _menu_pair "3" "配置自启并启动" "" "green" "4" "重启 Shadowsocks-Rust" "" "green"
        _menu_pair "5" "导出节点配置文件" "输出 SS/Mihomo/Sing-Box 文件" "green" "6" "查看日志" "" "green"
        _menu_pair "7" "卸载 Shadowsocks-Rust" "可选删除配置/日志" "yellow" "0" "返回上级菜单" "" "red"
        _separator

        local ch
        read -rp "  选择 [0-7]: " ch
        case "$ch" in
            1) _ssrust_install_or_update ;;
            2) _ssrust_configure ;;
            3) _ssrust_enable ;;
            4) _ssrust_restart ;;
            5) _ssrust_export_node_config ;;
            6) _ssrust_log ;;
            7) _ssrust_uninstall ;;
            0) return ;;
            *) _error_no_exit "无效选项"; sleep 1 ;;
        esac
    done
}

# --- 13. WireGuard 原生节点 ---

_WIREGUARD_DIR="/etc/wireguard"
_WIREGUARD_CLIENT_DIR="/etc/wireguard/clients"
_WIREGUARD_DEFAULT_IFACE="wg0"
_WIREGUARD_DEFAULT_PREFIX="10.66.0"
_WIREGUARD_SYSCTL_FILE="/etc/sysctl.d/99-vpsgo-wireguard.conf"
_WIREGUARD_IPV6_PREFIX="fd66:66:66:66"

_wireguard_service_name() {
    local iface="$1"
    if _has_openrc; then
        printf '%s' "vpsgo-wg-${iface}"
        return
    fi
    printf '%s' "wg-quick@${iface}"
}

_wireguard_service_file() {
    local iface="$1"
    if _has_openrc; then
        printf '%s' "/etc/init.d/$(_wireguard_service_name "$iface")"
    fi
}

_wireguard_firewall_service_name() {
    local iface="$1"
    printf '%s' "vpsgo-wg-nat-${iface}"
}

_wireguard_is_valid_ipv4() {
    local ip="$1" o1 o2 o3 o4 o
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r o1 o2 o3 o4 <<< "$ip"
    for o in "$o1" "$o2" "$o3" "$o4"; do
        _is_digit "$o" || return 1
        [[ "$o" -ge 0 && "$o" -le 255 ]] || return 1
    done
    return 0
}

_wireguard_is_private_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^10\. ]] && return 0
    [[ "$ip" =~ ^127\. ]] && return 0
    [[ "$ip" =~ ^192\.168\. ]] && return 0
    [[ "$ip" =~ ^169\.254\. ]] && return 0
    [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] && return 0
    return 1
}

_wireguard_is_valid_dns_name() {
    local name="$1"
    [[ "$name" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]]
}

_wireguard_local_ipv4() {
    local ip=""
    if command -v ip >/dev/null 2>&1; then
        ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
        if _wireguard_is_valid_ipv4 "$ip"; then
            printf '%s' "$ip"
            return 0
        fi
        ip=$(ip -4 addr 2>/dev/null | awk '/inet / && $2 !~ /^127\./ {sub(/\/.*/, "", $2); print $2; exit}')
        if _wireguard_is_valid_ipv4 "$ip"; then
            printf '%s' "$ip"
            return 0
        fi
    fi
    return 1
}

_wireguard_public_ipv4() {
    local ip=""
    ip=$(_mihomoconf_get_server_ip 2>/dev/null || true)
    if _wireguard_is_valid_ipv4 "$ip"; then
        printf '%s' "$ip"
        return 0
    fi
    return 1
}

_wireguard_detect_default_endpoint() {
    local iface="${1:-}" saved="" local_ip="" public_ip=""
    if [[ -n "$iface" ]]; then
        saved=$(_wireguard_meta_get "$iface" "vpsgo-endpoint" 2>/dev/null || true)
        if [[ -n "$saved" ]]; then
            printf '%s' "$saved"
            return 0
        fi
    fi
    saved=$(_mihomoconf_get_saved_host "$_MIHOMOCONF_CONFIG_FILE" 2>/dev/null || true)
    if [[ -n "$saved" ]]; then
        printf '%s' "$saved"
        return 0
    fi
    local_ip=$(_wireguard_local_ipv4 2>/dev/null || true)
    public_ip=$(_wireguard_public_ipv4 2>/dev/null || true)
    if _wireguard_is_valid_ipv4 "$local_ip" && _wireguard_is_private_ipv4 "$local_ip" && _wireguard_is_valid_ipv4 "$public_ip"; then
        printf '%s' "$public_ip"
        return 0
    fi
    if _wireguard_is_valid_ipv4 "$local_ip"; then
        printf '%s' "$local_ip"
        return 0
    fi
    if _wireguard_is_valid_ipv4 "$public_ip"; then
        printf '%s' "$public_ip"
        return 0
    fi
    printf '%s' "YOUR_SERVER_IP"
}

_wireguard_detect_ipv6_global() {
    local ip6=""
    if command -v ip >/dev/null 2>&1; then
        ip6=$(ip -6 addr show scope global 2>/dev/null | awk '/inet6 / {sub(/\/.*/, "", $2); print $2; exit}')
    fi
    [[ -n "$ip6" ]] || return 1
    printf '%s' "$ip6"
}

_wireguard_meta_get() {
    local iface="$1" key="$2"
    local conf_file="${_WIREGUARD_DIR}/${iface}.conf"
    [[ -f "$conf_file" ]] || return 1
    sed -n "s/^[[:space:]]*# ${key}[[:space:]]*:[[:space:]]*//p" "$conf_file" | head -1
}

_wireguard_default_dns() {
    local dns_line="" token out=()
    while IFS= read -r token; do
        token=$(_mihomoconf_trim "${token%%#*}")
        [[ -n "$token" ]] || continue
        [[ "$token" == "127.0.0.53" ]] && continue
        out+=("$token")
        [[ "${#out[@]}" -ge 2 ]] && break
    done < <(awk '/^[[:space:]]*nameserver[[:space:]]+/ {print $2}' /etc/resolv.conf 2>/dev/null)
    if [[ "${#out[@]}" -eq 0 && -f /run/systemd/resolve/resolv.conf ]]; then
        while IFS= read -r token; do
            token=$(_mihomoconf_trim "${token%%#*}")
            [[ -n "$token" ]] || continue
            out+=("$token")
            [[ "${#out[@]}" -ge 2 ]] && break
        done < <(awk '/^[[:space:]]*nameserver[[:space:]]+/ {print $2}' /run/systemd/resolve/resolv.conf 2>/dev/null)
    fi
    if [[ "${#out[@]}" -eq 0 ]]; then
        printf '%s' "1.1.1.1, 8.8.8.8"
        return 0
    fi
    dns_line="${out[*]}"
    dns_line="${dns_line// /, }"
    printf '%s' "$dns_line"
}

_wireguard_normalize_csv() {
    local raw="$1" token out=()
    IFS=',' read -r -a _wg_csv_arr <<< "$raw"
    for token in "${_wg_csv_arr[@]}"; do
        token=$(_mihomoconf_trim "$token")
        [[ -n "$token" ]] || continue
        out+=("$token")
    done
    (IFS=', '; printf '%s' "${out[*]}")
}

_wireguard_validate_dns_csv() {
    local raw="$1" token
    IFS=',' read -r -a _wg_dns_arr <<< "$raw"
    [[ "${#_wg_dns_arr[@]}" -gt 0 ]] || return 1
    for token in "${_wg_dns_arr[@]}"; do
        token=$(_mihomoconf_trim "$token")
        [[ -n "$token" ]] || continue
        if ! [[ "$token" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ || "$token" =~ : ]]; then
            return 1
        fi
    done
    return 0
}

_wireguard_firewall_service_file() {
    local iface="$1"
    local service_name
    service_name=$(_wireguard_firewall_service_name "$iface")
    if _has_openrc; then
        printf '%s' "/etc/init.d/${service_name}"
        return
    fi
    printf '%s' "/etc/systemd/system/${service_name}.service"
}

_wireguard_write_sysctl() {
    local enable_ipv6="${1:-0}"
    mkdir -p /etc/sysctl.d
    {
        echo "net.ipv4.ip_forward = 1"
        if [[ "$enable_ipv6" == "1" ]]; then
            echo "net.ipv6.conf.all.forwarding = 1"
        fi
    } > "$_WIREGUARD_SYSCTL_FILE"
    sysctl -e -q -p "$_WIREGUARD_SYSCTL_FILE" >/dev/null 2>&1 || true
}

_wireguard_write_firewall_service() {
    local iface="$1" port="$2" network_cidr="$3" egress_iface="$4"
    local enable_ipv6="${5:-0}" network_ipv6_cidr="${6:-}"
    local service_file iptables_path ip6tables_path
    service_file=$(_wireguard_firewall_service_file "$iface")
    iptables_path=$(command -v iptables 2>/dev/null || true)
    [[ -n "$iptables_path" ]] || return 1
    ip6tables_path=$(command -v ip6tables 2>/dev/null || true)

    if _has_openrc; then
        cat > "$service_file" <<EOF
#!/sbin/openrc-run
description="vpsgo WireGuard NAT rules for ${iface}"

depend() {
    need net
}

start() {
    ebegin "Applying WireGuard NAT rules for ${iface}"
    ${iptables_path} -w 5 -t nat -C POSTROUTING -s ${network_cidr} ! -d ${network_cidr} -o ${egress_iface} -j MASQUERADE 2>/dev/null || ${iptables_path} -w 5 -t nat -A POSTROUTING -s ${network_cidr} ! -d ${network_cidr} -o ${egress_iface} -j MASQUERADE
    ${iptables_path} -w 5 -C INPUT -p udp --dport ${port} -j ACCEPT 2>/dev/null || ${iptables_path} -w 5 -I INPUT -p udp --dport ${port} -j ACCEPT
    ${iptables_path} -w 5 -C FORWARD -s ${network_cidr} -j ACCEPT 2>/dev/null || ${iptables_path} -w 5 -I FORWARD -s ${network_cidr} -j ACCEPT
    ${iptables_path} -w 5 -C FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || ${iptables_path} -w 5 -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
EOF
        if [[ "$enable_ipv6" == "1" && -n "$network_ipv6_cidr" && -n "$ip6tables_path" ]]; then
            cat >> "$service_file" <<EOF
    ${ip6tables_path} -w 5 -t nat -C POSTROUTING -s ${network_ipv6_cidr} ! -d ${network_ipv6_cidr} -o ${egress_iface} -j MASQUERADE 2>/dev/null || ${ip6tables_path} -w 5 -t nat -A POSTROUTING -s ${network_ipv6_cidr} ! -d ${network_ipv6_cidr} -o ${egress_iface} -j MASQUERADE
    ${ip6tables_path} -w 5 -C FORWARD -s ${network_ipv6_cidr} -j ACCEPT 2>/dev/null || ${ip6tables_path} -w 5 -I FORWARD -s ${network_ipv6_cidr} -j ACCEPT
    ${ip6tables_path} -w 5 -C FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || ${ip6tables_path} -w 5 -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
EOF
        fi
        cat >> "$service_file" <<EOF
    eend \$?
}

stop() {
    ebegin "Removing WireGuard NAT rules for ${iface}"
    ${iptables_path} -w 5 -t nat -D POSTROUTING -s ${network_cidr} ! -d ${network_cidr} -o ${egress_iface} -j MASQUERADE 2>/dev/null || true
    ${iptables_path} -w 5 -D INPUT -p udp --dport ${port} -j ACCEPT 2>/dev/null || true
    ${iptables_path} -w 5 -D FORWARD -s ${network_cidr} -j ACCEPT 2>/dev/null || true
    ${iptables_path} -w 5 -D FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
EOF
        if [[ "$enable_ipv6" == "1" && -n "$network_ipv6_cidr" && -n "$ip6tables_path" ]]; then
            cat >> "$service_file" <<EOF
    ${ip6tables_path} -w 5 -t nat -D POSTROUTING -s ${network_ipv6_cidr} ! -d ${network_ipv6_cidr} -o ${egress_iface} -j MASQUERADE 2>/dev/null || true
    ${ip6tables_path} -w 5 -D FORWARD -s ${network_ipv6_cidr} -j ACCEPT 2>/dev/null || true
    ${ip6tables_path} -w 5 -D FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
EOF
        fi
        cat >> "$service_file" <<'EOF'
    eend 0
}
EOF
        chmod 0755 "$service_file" || return 1
        return 0
    fi

    cat > "$service_file" <<EOF
[Unit]
Description=vpsgo WireGuard NAT rules for ${iface}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c '${iptables_path} -w 5 -t nat -C POSTROUTING -s ${network_cidr} ! -d ${network_cidr} -o ${egress_iface} -j MASQUERADE 2>/dev/null || ${iptables_path} -w 5 -t nat -A POSTROUTING -s ${network_cidr} ! -d ${network_cidr} -o ${egress_iface} -j MASQUERADE'
ExecStart=/bin/sh -c '${iptables_path} -w 5 -C INPUT -p udp --dport ${port} -j ACCEPT 2>/dev/null || ${iptables_path} -w 5 -I INPUT -p udp --dport ${port} -j ACCEPT'
ExecStart=/bin/sh -c '${iptables_path} -w 5 -C FORWARD -s ${network_cidr} -j ACCEPT 2>/dev/null || ${iptables_path} -w 5 -I FORWARD -s ${network_cidr} -j ACCEPT'
ExecStart=/bin/sh -c '${iptables_path} -w 5 -C FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || ${iptables_path} -w 5 -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT'
ExecStop=/bin/sh -c '${iptables_path} -w 5 -t nat -D POSTROUTING -s ${network_cidr} ! -d ${network_cidr} -o ${egress_iface} -j MASQUERADE 2>/dev/null || true'
ExecStop=/bin/sh -c '${iptables_path} -w 5 -D INPUT -p udp --dport ${port} -j ACCEPT 2>/dev/null || true'
ExecStop=/bin/sh -c '${iptables_path} -w 5 -D FORWARD -s ${network_cidr} -j ACCEPT 2>/dev/null || true'
ExecStop=/bin/sh -c '${iptables_path} -w 5 -D FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true'
EOF
    if [[ "$enable_ipv6" == "1" && -n "$network_ipv6_cidr" && -n "$ip6tables_path" ]]; then
        cat >> "$service_file" <<EOF
ExecStart=/bin/sh -c '${ip6tables_path} -w 5 -t nat -C POSTROUTING -s ${network_ipv6_cidr} ! -d ${network_ipv6_cidr} -o ${egress_iface} -j MASQUERADE 2>/dev/null || ${ip6tables_path} -w 5 -t nat -A POSTROUTING -s ${network_ipv6_cidr} ! -d ${network_ipv6_cidr} -o ${egress_iface} -j MASQUERADE'
ExecStart=/bin/sh -c '${ip6tables_path} -w 5 -C FORWARD -s ${network_ipv6_cidr} -j ACCEPT 2>/dev/null || ${ip6tables_path} -w 5 -I FORWARD -s ${network_ipv6_cidr} -j ACCEPT'
ExecStart=/bin/sh -c '${ip6tables_path} -w 5 -C FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || ${ip6tables_path} -w 5 -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT'
ExecStop=/bin/sh -c '${ip6tables_path} -w 5 -t nat -D POSTROUTING -s ${network_ipv6_cidr} ! -d ${network_ipv6_cidr} -o ${egress_iface} -j MASQUERADE 2>/dev/null || true'
ExecStop=/bin/sh -c '${ip6tables_path} -w 5 -D FORWARD -s ${network_ipv6_cidr} -j ACCEPT 2>/dev/null || true'
ExecStop=/bin/sh -c '${ip6tables_path} -w 5 -D FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true'
EOF
    fi
    cat >> "$service_file" <<'EOF'

[Install]
WantedBy=multi-user.target
EOF
}

_wireguard_write_service() {
    local iface="$1"
    local conf_file="${_WIREGUARD_DIR}/${iface}.conf"
    local service_file wgquick_bin
    _has_openrc || return 1
    wgquick_bin=$(command -v wg-quick 2>/dev/null || true)
    [[ -n "$wgquick_bin" ]] || return 1
    service_file=$(_wireguard_service_file "$iface")
    cat > "$service_file" <<EOF
#!/sbin/openrc-run
description="vpsgo WireGuard interface ${iface}"

depend() {
    need net
}

start_pre() {
    sysctl -e -q -p ${_WIREGUARD_SYSCTL_FILE} >/dev/null 2>&1 || true
}

start() {
    ebegin "Bringing up WireGuard ${iface}"
    ${wgquick_bin} down ${iface} >/dev/null 2>&1 || true
    ${wgquick_bin} up ${conf_file} >/dev/null 2>&1
    eend \$?
}

stop() {
    ebegin "Bringing down WireGuard ${iface}"
    ${wgquick_bin} down ${conf_file} >/dev/null 2>&1 || ${wgquick_bin} down ${iface} >/dev/null 2>&1 || true
    eend 0
}
EOF
    chmod 0755 "$service_file" || return 1
}

_wireguard_service_is_active() {
    local iface="$1"
    local service_name
    service_name=$(_wireguard_service_name "$iface")
    if _has_systemd && systemctl is-active --quiet "$service_name" 2>/dev/null; then
        return 0
    fi
    if _has_openrc && _service_script_exists "$service_name" && rc-service "$service_name" status >/dev/null 2>&1; then
        return 0
    fi
    command -v wg >/dev/null 2>&1 && wg show "$iface" >/dev/null 2>&1
}

_wireguard_remove_firewall_service() {
    local iface="$1" service_file
    service_file=$(_wireguard_firewall_service_file "$iface")
    if _has_systemd; then
        systemctl disable --now "$(basename "$service_file")" >/dev/null 2>&1 || true
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    if _has_openrc; then
        rc-service "$(_wireguard_firewall_service_name "$iface")" stop >/dev/null 2>&1 || true
        rc-update del "$(_wireguard_firewall_service_name "$iface")" default >/dev/null 2>&1 || true
    fi
    rm -f "$service_file"
}

_wireguard_detect_iface() {
    local f base
    if [[ -f "${_WIREGUARD_DIR}/${_WIREGUARD_DEFAULT_IFACE}.conf" ]]; then
        printf '%s' "$_WIREGUARD_DEFAULT_IFACE"
        return 0
    fi
    if [[ -d "$_WIREGUARD_DIR" ]]; then
        while IFS= read -r f; do
            base=$(basename "$f" .conf)
            [[ "$base" == *"-client"* ]] && continue
            printf '%s' "$base"
            return 0
        done < <(find "$_WIREGUARD_DIR" -maxdepth 1 -type f -name '*.conf' 2>/dev/null | sort)
    fi
    printf '%s' "$_WIREGUARD_DEFAULT_IFACE"
}

_wireguard_conf_get_value() {
    local iface="$1" key="$2"
    local conf_file="${_WIREGUARD_DIR}/${iface}.conf"
    [[ -f "$conf_file" ]] || return 1
    awk -F'=' -v k="$key" '
        function trim(s) {
            sub(/^[[:space:]]+/, "", s)
            sub(/[[:space:]]+$/, "", s)
            return s
        }
        {
            line=$0
            if (line ~ /^[[:space:]]*#/ || line ~ /^[[:space:]]*$/) next
            if (tolower(trim($1)) == tolower(k)) {
                val=substr(line, index(line, "=") + 1)
                print trim(val)
                exit
            }
        }
    ' "$conf_file"
}

_wireguard_detect_egress_iface() {
    local iface=""
    if command -v ip >/dev/null 2>&1; then
        iface=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    fi
    printf '%s' "$iface"
}

_wireguard_is_valid_ipv4_prefix() {
    local prefix="$1" o1 o2 o3 o
    [[ "$prefix" =~ ^([0-9]{1,3}\.){2}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r o1 o2 o3 <<< "$prefix"
    for o in "$o1" "$o2" "$o3"; do
        _is_digit "$o" || return 1
        [[ "$o" -ge 0 && "$o" -le 255 ]] || return 1
    done
    return 0
}

_wireguard_is_valid_client_name() {
    local name="$1"
    [[ -n "$name" && "$name" =~ ^[A-Za-z0-9._-]+$ ]]
}

_wireguard_get_prefix_from_conf() {
    local iface="$1"
    local address_line prefix
    address_line=$(_wireguard_conf_get_value "$iface" "Address" 2>/dev/null || true)
    if [[ "$address_line" =~ ([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})\.([0-9]{1,3})/[0-9]{1,2} ]]; then
        prefix="${BASH_REMATCH[1]}"
        if _wireguard_is_valid_ipv4_prefix "$prefix"; then
            printf '%s' "$prefix"
            return 0
        fi
    fi
    return 1
}

_wireguard_next_client_host() {
    local iface="$1" prefix="$2"
    local conf_file="${_WIREGUARD_DIR}/${iface}.conf"
    [[ -f "$conf_file" ]] || return 1
    awk -v pre="$prefix" '
        function trim(s) {
            sub(/^[[:space:]]+/, "", s)
            sub(/[[:space:]]+$/, "", s)
            return s
        }
        function mark_ip(token,   m, host) {
            token=trim(token)
            if (match(token, "^" pre "\\.([0-9]{1,3})/[0-9]{1,2}$", m)) {
                host=m[1] + 0
                if (host >= 1 && host <= 254) used[host]=1
            }
        }
        /^[[:space:]]*(Address|AllowedIPs)[[:space:]]*=/ {
            line=$0
            sub(/^[^=]*=/, "", line)
            n=split(line, arr, /,/)
            for (i=1; i<=n; i++) mark_ip(arr[i])
            next
        }
        END {
            for (i=2; i<=254; i++) {
                if (!(i in used)) {
                    print i
                    exit
                }
            }
        }
    ' "$conf_file"
}

_wireguard_port_conflict_with_mihomo() {
    local port="$1"
    if declare -F _snell_port_conflict_with_mihomo >/dev/null 2>&1; then
        _snell_port_conflict_with_mihomo "$port"
        return $?
    fi
    return 1
}

_wireguard_pick_port() {
    local default_port="${1:-51820}"
    local port_input usage_line
    while true; do
        read -rp "  WireGuard 监听端口 [默认 ${default_port}]: " port_input
        port_input=$(_mihomoconf_trim "${port_input:-$default_port}")
        if ! _is_valid_port "$port_input"; then
            _warn "端口无效，请输入 1-65535 的数字"
            continue
        fi
        if _wireguard_port_conflict_with_mihomo "$port_input"; then
            _warn "端口 ${port_input} 与 mihomo 配置冲突（listeners/port/mixed-port 等），请更换端口"
            continue
        fi
        usage_line=$(_snell_port_usage_line "$port_input")
        if [[ -n "$usage_line" && "$usage_line" != *"wireguard"* && "$usage_line" != *"wg-quick"* ]]; then
            _warn "端口 ${port_input} 已被占用: ${usage_line}"
            continue
        fi
        printf '%s' "$port_input"
        return 0
    done
}

_wireguard_install_tools_core() {
    if [[ "$(uname -s)" != "Linux" ]]; then
        _error_no_exit "WireGuard 原生节点仅支持 Linux 系统"
        return 1
    fi

    if command -v wg >/dev/null 2>&1 && command -v wg-quick >/dev/null 2>&1 \
        && command -v ip >/dev/null 2>&1 && command -v iptables >/dev/null 2>&1; then
        _info "检测到 wireguard-tools: $(wg --version 2>/dev/null | head -1)"
        modprobe wireguard >/dev/null 2>&1 || true
        return 0
    fi

    _info "正在检查 WireGuard 依赖..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq || true
        apt-get install -y -qq wireguard wireguard-tools >/dev/null 2>&1 \
            || apt-get install -y -qq wireguard-tools >/dev/null 2>&1 \
            || apt-get install -y -qq wireguard >/dev/null 2>&1
        command -v ip >/dev/null 2>&1 || apt-get install -y -qq iproute2 >/dev/null 2>&1 || true
        command -v iptables >/dev/null 2>&1 || apt-get install -y -qq iptables >/dev/null 2>&1 || true
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y wireguard-tools >/dev/null 2>&1 \
            || dnf install -y wireguard-tools wireguard-dkms >/dev/null 2>&1
        command -v ip >/dev/null 2>&1 || dnf install -y iproute >/dev/null 2>&1 || true
        command -v iptables >/dev/null 2>&1 || dnf install -y iptables >/dev/null 2>&1 || true
    elif command -v yum >/dev/null 2>&1; then
        yum install -y epel-release >/dev/null 2>&1 || true
        yum install -y wireguard-tools >/dev/null 2>&1 \
            || yum install -y kmod-wireguard wireguard-tools >/dev/null 2>&1
        command -v ip >/dev/null 2>&1 || yum install -y iproute >/dev/null 2>&1 || true
        command -v iptables >/dev/null 2>&1 || yum install -y iptables >/dev/null 2>&1 || true
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm wireguard-tools >/dev/null 2>&1
        command -v ip >/dev/null 2>&1 || pacman -Sy --noconfirm iproute2 >/dev/null 2>&1 || true
        command -v iptables >/dev/null 2>&1 || pacman -Sy --noconfirm iptables >/dev/null 2>&1 || true
    elif command -v apk >/dev/null 2>&1; then
        apk add wireguard-tools >/dev/null 2>&1
        command -v ip >/dev/null 2>&1 || apk add iproute2 >/dev/null 2>&1 || true
        command -v iptables >/dev/null 2>&1 || apk add iptables >/dev/null 2>&1 || true
    elif command -v zypper >/dev/null 2>&1; then
        zypper install -y wireguard-tools >/dev/null 2>&1
        command -v ip >/dev/null 2>&1 || zypper install -y iproute2 >/dev/null 2>&1 || true
        command -v iptables >/dev/null 2>&1 || zypper install -y iptables >/dev/null 2>&1 || true
    else
        _error_no_exit "无法识别包管理器，请手动安装 wireguard-tools"
        return 1
    fi

    if ! command -v wg >/dev/null 2>&1 || ! command -v wg-quick >/dev/null 2>&1; then
        _error_no_exit "wireguard-tools 安装失败，请手动安装后重试"
        return 1
    fi
    if ! command -v ip >/dev/null 2>&1; then
        _error_no_exit "缺少 iproute/ip 命令，请安装 iproute2 后重试"
        return 1
    fi
    if ! command -v iptables >/dev/null 2>&1; then
        _error_no_exit "缺少 iptables，无法配置 WireGuard NAT，请安装后重试"
        return 1
    fi

    modprobe wireguard >/dev/null 2>&1 || true
    _success "wireguard-tools 安装完成"
    _info "版本: $(wg --version 2>/dev/null | head -1)"
    return 0
}

_wireguard_install_or_update() {
    _header "WireGuard 安装/更新"
    _time_sync_check_and_enable
    if ! _wireguard_install_tools_core; then
        _press_any_key
        return
    fi
    _press_any_key
}

_wireguard_deploy() {
    _header "部署 WireGuard 原生节点"

    if ! _wireguard_install_tools_core; then
        _press_any_key
        return
    fi

    local iface_default iface_input iface conf_file
    local current_port listen_port endpoint_default endpoint_input endpoint_host
    local prefix_default prefix_input prefix
    local egress_default egress_input egress_iface
    local dns_default dns_input dns_servers
    local server_addr server_iface_addr network_cidr client_addr client_peer_addr
    local ipv6_global="" network6_cidr="" server_addr6="" client_addr6="" client_peer_addr6=""
    local client_iface_addr allowed_ips_client allowed_ips_peer
    local server_private server_public client_private client_public psk
    local client_name client_conf backup_file
    local service_name firewall_service_file
    local use_managed_firewall="0"
    local postup_line="" postdown_line=""

    iface_default=$(_wireguard_detect_iface)
    read -rp "  接口名 [默认 ${iface_default}]: " iface_input
    iface=$(_mihomoconf_trim "${iface_input:-$iface_default}")
    if [[ -z "$iface" || ! "$iface" =~ ^[A-Za-z0-9._-]+$ ]]; then
        _error_no_exit "接口名无效，仅支持字母/数字/._-"
        _press_any_key
        return
    fi

    conf_file="${_WIREGUARD_DIR}/${iface}.conf"
    current_port=$(_wireguard_conf_get_value "$iface" "ListenPort" 2>/dev/null || true)
    [[ -z "$current_port" ]] && current_port="51820"
    listen_port=$(_wireguard_pick_port "$current_port")

    endpoint_default=$(_wireguard_detect_default_endpoint "$iface")
    read -rp "  客户端连接地址 [默认 ${endpoint_default}]: " endpoint_input
    endpoint_host=$(_mihomoconf_trim "${endpoint_input:-$endpoint_default}")
    if [[ -z "$endpoint_host" ]]; then
        _error_no_exit "客户端连接地址不能为空"
        _press_any_key
        return
    fi
    if ! _wireguard_is_valid_ipv4 "$endpoint_host" && ! _wireguard_is_valid_dns_name "$endpoint_host" && [[ "$endpoint_host" != *:* ]]; then
        _warn "客户端连接地址既不是 IPv4 也不是标准域名，将按原样写入 Endpoint"
    fi

    prefix_default=$(_wireguard_conf_get_value "$iface" "Address" 2>/dev/null || true)
    if [[ "$prefix_default" =~ ^([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})\.1/24$ ]]; then
        prefix_default="${BASH_REMATCH[1]}"
    else
        prefix_default="$_WIREGUARD_DEFAULT_PREFIX"
    fi
    read -rp "  内网网段前缀 [默认 ${prefix_default}，格式如 10.66.0]: " prefix_input
    prefix=$(_mihomoconf_trim "${prefix_input:-$prefix_default}")
    if ! _wireguard_is_valid_ipv4_prefix "$prefix"; then
        _error_no_exit "网段前缀格式错误，请使用 x.x.x（每段 0-255）"
        _press_any_key
        return
    fi

    egress_default=$(_wireguard_detect_egress_iface)
    read -rp "  出口网卡 [默认 ${egress_default:-eth0}]: " egress_input
    egress_iface=$(_mihomoconf_trim "${egress_input:-${egress_default:-eth0}}")
    if command -v ip >/dev/null 2>&1 && ! ip link show "$egress_iface" >/dev/null 2>&1; then
        _error_no_exit "网卡 ${egress_iface} 不存在，请重新输入"
        _press_any_key
        return
    fi
    dns_default=$(_wireguard_meta_get "$iface" "vpsgo-dns" 2>/dev/null || true)
    [[ -z "$dns_default" ]] && dns_default=$(_wireguard_default_dns)
    read -rp "  客户端 DNS [默认 ${dns_default}]: " dns_input
    dns_servers=$(_wireguard_normalize_csv "${dns_input:-$dns_default}")
    if [[ -z "$dns_servers" ]] || ! _wireguard_validate_dns_csv "$dns_servers"; then
        _error_no_exit "客户端 DNS 格式无效，请使用逗号分隔的 IP 列表"
        _press_any_key
        return
    fi

    ipv6_global=$(_wireguard_detect_ipv6_global 2>/dev/null || true)
    if [[ -n "$ipv6_global" && -z "$(command -v ip6tables 2>/dev/null || true)" ]]; then
        _warn "检测到 IPv6 地址，但系统未安装 ip6tables，将仅配置 IPv4 WireGuard"
        ipv6_global=""
    fi

    server_addr="${prefix}.1/24"
    server_iface_addr="${server_addr}"
    network_cidr="${prefix}.0/24"
    client_addr="${prefix}.2/24"
    client_peer_addr="${prefix}.2/32"
    client_iface_addr="${client_addr}"
    allowed_ips_client="0.0.0.0/0"
    allowed_ips_peer="${client_peer_addr}"
    if [[ -n "$ipv6_global" ]]; then
        network6_cidr="${_WIREGUARD_IPV6_PREFIX}::/64"
        server_addr6="${_WIREGUARD_IPV6_PREFIX}::1/64"
        client_addr6="${_WIREGUARD_IPV6_PREFIX}::2/64"
        client_peer_addr6="${_WIREGUARD_IPV6_PREFIX}::2/128"
        client_iface_addr="${client_iface_addr}, ${client_addr6}"
        allowed_ips_client="${allowed_ips_client}, ::/0"
        allowed_ips_peer="${allowed_ips_peer}, ${client_peer_addr6}"
        server_iface_addr="${server_iface_addr}, ${server_addr6}"
    fi
    client_name="client1"
    client_conf="${_WIREGUARD_CLIENT_DIR}/${iface}-${client_name}.conf"

    server_private=$(wg genkey)
    server_public=$(printf '%s' "$server_private" | wg pubkey)
    client_private=$(wg genkey)
    client_public=$(printf '%s' "$client_private" | wg pubkey)
    psk=$(wg genpsk)
    if [[ -z "$server_private" || -z "$server_public" || -z "$client_private" || -z "$client_public" || -z "$psk" ]]; then
        _error_no_exit "WireGuard 密钥生成失败"
        _press_any_key
        return
    fi

    mkdir -p "$_WIREGUARD_DIR" "$_WIREGUARD_CLIENT_DIR"
    chmod 700 "$_WIREGUARD_DIR"
    chmod 700 "$_WIREGUARD_CLIENT_DIR"

    if [[ -f "$conf_file" ]]; then
        backup_file="${conf_file}.bak.$(date +%Y%m%d_%H%M%S)"
        cp -a "$conf_file" "$backup_file"
        _info "已备份原配置: ${backup_file}"
    fi

    _wireguard_write_sysctl "$([[ -n "$ipv6_global" ]] && echo 1 || echo 0)"

    if _has_systemd; then
        if _wireguard_write_firewall_service "$iface" "$listen_port" "$network_cidr" "$egress_iface" "$([[ -n "$ipv6_global" ]] && echo 1 || echo 0)" "$network6_cidr"; then
            firewall_service_file=$(_wireguard_firewall_service_file "$iface")
            systemctl daemon-reload >/dev/null 2>&1 || true
            if systemctl enable --now "$(basename "$firewall_service_file")" >/dev/null 2>&1; then
                use_managed_firewall="1"
            else
                _warn "vpsgo WireGuard NAT 服务启动失败，将回退为 wg-quick PostUp/PostDown 规则"
                rm -f "$firewall_service_file"
                systemctl daemon-reload >/dev/null 2>&1 || true
            fi
        fi
    fi
    if [[ "$use_managed_firewall" != "1" ]] && _has_openrc; then
        if _wireguard_write_firewall_service "$iface" "$listen_port" "$network_cidr" "$egress_iface" "$([[ -n "$ipv6_global" ]] && echo 1 || echo 0)" "$network6_cidr"; then
            firewall_service_file=$(_wireguard_firewall_service_file "$iface")
            if ! rc-update add "$(_wireguard_firewall_service_name "$iface")" default >/dev/null 2>&1; then
                if ! _openrc_service_in_default "$(_wireguard_firewall_service_name "$iface")"; then
                    _warn "vpsgo WireGuard NAT OpenRC 服务注册失败，将回退为 wg-quick PostUp/PostDown 规则"
                    rm -f "$firewall_service_file"
                fi
            fi
            if [[ -f "$firewall_service_file" ]]; then
                if rc-service "$(_wireguard_firewall_service_name "$iface")" start >/dev/null 2>&1; then
                    use_managed_firewall="1"
                else
                    _warn "vpsgo WireGuard NAT OpenRC 服务启动失败，将回退为 wg-quick PostUp/PostDown 规则"
                    rc-update del "$(_wireguard_firewall_service_name "$iface")" default >/dev/null 2>&1 || true
                    rm -f "$firewall_service_file"
                fi
            fi
        fi
    fi
    if [[ "$use_managed_firewall" != "1" ]]; then
        postup_line="PostUp = sysctl -w net.ipv4.ip_forward=1 >/dev/null; iptables -C FORWARD -s ${network_cidr} -j ACCEPT 2>/dev/null || iptables -I FORWARD -s ${network_cidr} -j ACCEPT; iptables -C FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT; iptables -C INPUT -p udp --dport ${listen_port} -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport ${listen_port} -j ACCEPT; iptables -t nat -C POSTROUTING -s ${network_cidr} ! -d ${network_cidr} -o ${egress_iface} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s ${network_cidr} ! -d ${network_cidr} -o ${egress_iface} -j MASQUERADE"
        postdown_line="PostDown = iptables -D FORWARD -s ${network_cidr} -j ACCEPT 2>/dev/null || true; iptables -D FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true; iptables -D INPUT -p udp --dport ${listen_port} -j ACCEPT 2>/dev/null || true; iptables -t nat -D POSTROUTING -s ${network_cidr} ! -d ${network_cidr} -o ${egress_iface} -j MASQUERADE 2>/dev/null || true"
        if [[ -n "$ipv6_global" && -n "$(command -v ip6tables 2>/dev/null || true)" ]]; then
            postup_line="${postup_line}; sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null; ip6tables -C FORWARD -s ${network6_cidr} -j ACCEPT 2>/dev/null || ip6tables -I FORWARD -s ${network6_cidr} -j ACCEPT; ip6tables -C FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || ip6tables -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT; ip6tables -t nat -C POSTROUTING -s ${network6_cidr} ! -d ${network6_cidr} -o ${egress_iface} -j MASQUERADE 2>/dev/null || ip6tables -t nat -A POSTROUTING -s ${network6_cidr} ! -d ${network6_cidr} -o ${egress_iface} -j MASQUERADE"
            postdown_line="${postdown_line}; ip6tables -D FORWARD -s ${network6_cidr} -j ACCEPT 2>/dev/null || true; ip6tables -D FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true; ip6tables -t nat -D POSTROUTING -s ${network6_cidr} ! -d ${network6_cidr} -o ${egress_iface} -j MASQUERADE 2>/dev/null || true"
        fi
    fi

    cat > "$conf_file" <<EOF
[Interface]
# vpsgo-endpoint: ${endpoint_host}
# vpsgo-dns: ${dns_servers}
# vpsgo-egress: ${egress_iface}
Address = ${server_iface_addr}
ListenPort = ${listen_port}
PrivateKey = ${server_private}
EOF
    if [[ -n "$postup_line" ]]; then
        printf '%s\n' "$postup_line" >> "$conf_file"
        printf '%s\n' "$postdown_line" >> "$conf_file"
    fi
    cat >> "$conf_file" <<EOF

[Peer]
# vpsgo-client: ${client_name}
PublicKey = ${client_public}
PresharedKey = ${psk}
AllowedIPs = ${allowed_ips_peer}
EOF
    chmod 600 "$conf_file"

    cat > "$client_conf" <<EOF
[Interface]
PrivateKey = ${client_private}
Address = ${client_iface_addr}
DNS = ${dns_servers}

[Peer]
PublicKey = ${server_public}
PresharedKey = ${psk}
Endpoint = ${endpoint_host}:${listen_port}
AllowedIPs = ${allowed_ips_client}
PersistentKeepalive = 25
EOF
    chmod 600 "$client_conf"

    service_name=$(_wireguard_service_name "$iface")
    if _has_systemd; then
        if systemctl is-enabled "${service_name}.service" &>/dev/null || systemctl is-active "${service_name}.service" &>/dev/null; then
            if ! systemctl restart "$service_name" >/dev/null 2>&1; then
                _error_no_exit "WireGuard 重启失败，请检查: systemctl status ${service_name}"
                _press_any_key
                return
            fi
        else
            if ! systemctl enable --now "$service_name" >/dev/null 2>&1; then
                _error_no_exit "WireGuard 启动失败，请检查: systemctl status ${service_name}"
                _press_any_key
                return
            fi
        fi
        if ! systemctl is-active --quiet "$service_name"; then
            _error_no_exit "WireGuard 服务未激活: ${service_name}"
            _press_any_key
            return
        fi
    elif _has_openrc; then
        if ! _wireguard_write_service "$iface"; then
            _error_no_exit "WireGuard OpenRC 服务写入失败"
            _press_any_key
            return
        fi
        if ! rc-update add "$service_name" default >/dev/null 2>&1; then
            if ! _openrc_service_in_default "$service_name"; then
                _error_no_exit "WireGuard OpenRC 服务注册失败，请检查 rc-update 状态"
                _press_any_key
                return
            fi
        fi
        if ! rc-service "$service_name" restart >/dev/null 2>&1; then
            if ! rc-service "$service_name" start >/dev/null 2>&1; then
                _error_no_exit "WireGuard 启动失败，请检查: rc-service ${service_name} status"
                _press_any_key
                return
            fi
        fi
        if ! _wireguard_service_is_active "$iface"; then
            _error_no_exit "WireGuard 服务未激活: ${service_name}"
            _press_any_key
            return
        fi
    else
        wg-quick down "$iface" >/dev/null 2>&1 || true
        if ! wg-quick up "$iface" >/dev/null 2>&1; then
            _error_no_exit "wg-quick 启动失败，请检查配置文件: ${conf_file}"
            _press_any_key
            return
        fi
    fi

    _success "WireGuard 原生节点部署完成"
    _info "服务端配置: ${conf_file}"
    _info "客户端配置: ${client_conf}"
    _info "监听端口: ${listen_port} (已检查与 mihomo 配置冲突)"
    [[ "$use_managed_firewall" == "1" ]] && _info "NAT 规则服务: $(basename "$firewall_service_file")"
    _separator
    printf "  ${BOLD}客户端连接参数${PLAIN}\n"
    printf "    Endpoint : %s:%s\n" "$endpoint_host" "$listen_port"
    printf "    地址段   : %s\n" "$client_iface_addr"
    printf "    DNS      : %s\n" "$dns_servers"
    printf "    路由     : %s\n" "$allowed_ips_client"
    if command -v qrencode >/dev/null 2>&1; then
        echo ""
        printf "  ${BOLD}客户端配置二维码 (ANSI):${PLAIN}\n"
        qrencode -t ANSIUTF8 < "$client_conf" || true
    else
        _info "未检测到 qrencode，已跳过二维码输出"
    fi
    _press_any_key
}

_wireguard_add_client() {
    _header "新增 WireGuard 客户端"

    if ! _wireguard_install_tools_core; then
        _press_any_key
        return
    fi

    local iface conf_file prefix next_host
    local listen_port endpoint_default endpoint_input endpoint_host
    local dns_default dns_input dns_servers
    local client_name_input client_name client_conf
    local server_private server_public client_private client_public psk
    local client_addr client_iface_addr client_addr6="" client_peer_addr6="" allowed_ips_client allowed_ips_peer
    local psk_file applied_runtime service_name allowed_ips_peer_runtime
    local overwrite

    iface=$(_wireguard_detect_iface)
    conf_file="${_WIREGUARD_DIR}/${iface}.conf"
    if [[ ! -f "$conf_file" ]]; then
        _error_no_exit "未找到服务端配置: ${conf_file}"
        _info "请先执行「部署/重建节点」"
        _press_any_key
        return
    fi

    prefix=$(_wireguard_get_prefix_from_conf "$iface" 2>/dev/null || true)
    if [[ -z "$prefix" ]]; then
        _error_no_exit "无法从 ${conf_file} 解析 Address 网段，当前仅支持 IPv4 /24 网段"
        _press_any_key
        return
    fi

    next_host=$(_wireguard_next_client_host "$iface" "$prefix")
    if [[ -z "$next_host" ]]; then
        _error_no_exit "未找到可用客户端地址（${prefix}.2-${prefix}.254 已用尽）"
        _press_any_key
        return
    fi
    client_addr="${prefix}.${next_host}/32"
    client_iface_addr="${prefix}.${next_host}/24"
    allowed_ips_peer="${client_addr}"
    allowed_ips_client="0.0.0.0/0"
    if grep -Eq '^[[:space:]]*Address[[:space:]]*=.*:' "$conf_file"; then
        client_addr6="${_WIREGUARD_IPV6_PREFIX}::${next_host}/64"
        client_peer_addr6="${_WIREGUARD_IPV6_PREFIX}::${next_host}/128"
        client_iface_addr="${client_iface_addr}, ${client_addr6}"
        allowed_ips_peer="${allowed_ips_peer}, ${client_peer_addr6}"
        allowed_ips_client="${allowed_ips_client}, ::/0"
    fi

    read -rp "  客户端名称 [默认 client${next_host}]: " client_name_input
    client_name=$(_mihomoconf_trim "${client_name_input:-client${next_host}}")
    if ! _wireguard_is_valid_client_name "$client_name"; then
        _error_no_exit "客户端名称无效，仅支持字母/数字/._-"
        _press_any_key
        return
    fi
    if awk -v n="$client_name" '
        function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
        {
            line=$0
            if (line ~ /^[[:space:]]*# vpsgo-client:/) {
                sub(/^[[:space:]]*# vpsgo-client:[[:space:]]*/, "", line)
                if (trim(line) == n) { found=1; exit }
            }
        }
        END { exit(found ? 0 : 1) }
    ' "$conf_file"; then
        _error_no_exit "服务端中已存在同名客户端: ${client_name}"
        _press_any_key
        return
    fi

    mkdir -p "$_WIREGUARD_CLIENT_DIR"
    chmod 700 "$_WIREGUARD_CLIENT_DIR"
    client_conf="${_WIREGUARD_CLIENT_DIR}/${iface}-${client_name}.conf"
    if [[ -f "$client_conf" ]]; then
        read -rp "  客户端配置已存在，是否覆盖 ${client_conf}? [y/N]: " overwrite
        if [[ ! "$overwrite" =~ ^[Yy] ]]; then
            _info "已取消"
            _press_any_key
            return
        fi
    fi

    listen_port=$(_wireguard_conf_get_value "$iface" "ListenPort" 2>/dev/null || true)
    [[ -z "$listen_port" ]] && listen_port="51820"
    endpoint_default=$(_wireguard_detect_default_endpoint "$iface")
    read -rp "  客户端连接地址 [默认 ${endpoint_default}]: " endpoint_input
    endpoint_host=$(_mihomoconf_trim "${endpoint_input:-$endpoint_default}")
    if [[ -z "$endpoint_host" ]]; then
        _error_no_exit "客户端连接地址不能为空"
        _press_any_key
        return
    fi
    dns_default=$(_wireguard_meta_get "$iface" "vpsgo-dns" 2>/dev/null || true)
    [[ -z "$dns_default" ]] && dns_default=$(_wireguard_default_dns)
    read -rp "  客户端 DNS [默认 ${dns_default}]: " dns_input
    dns_servers=$(_wireguard_normalize_csv "${dns_input:-$dns_default}")
    if [[ -z "$dns_servers" ]] || ! _wireguard_validate_dns_csv "$dns_servers"; then
        _error_no_exit "客户端 DNS 格式无效，请使用逗号分隔的 IP 列表"
        _press_any_key
        return
    fi

    server_private=$(_wireguard_conf_get_value "$iface" "PrivateKey" 2>/dev/null || true)
    if [[ -z "$server_private" ]]; then
        _error_no_exit "无法读取服务端 PrivateKey，请检查 ${conf_file}"
        _press_any_key
        return
    fi
    server_public=$(printf '%s' "$server_private" | wg pubkey)
    client_private=$(wg genkey)
    client_public=$(printf '%s' "$client_private" | wg pubkey)
    psk=$(wg genpsk)
    if [[ -z "$server_public" || -z "$client_private" || -z "$client_public" || -z "$psk" ]]; then
        _error_no_exit "客户端密钥生成失败"
        _press_any_key
        return
    fi

    {
        echo ""
        echo "[Peer]"
        printf "# vpsgo-client: %s\n" "$client_name"
        printf "PublicKey = %s\n" "$client_public"
        printf "PresharedKey = %s\n" "$psk"
        printf "AllowedIPs = %s\n" "$allowed_ips_peer"
    } >> "$conf_file"
    chmod 600 "$conf_file"

    cat > "$client_conf" <<EOF
# vpsgo-client: ${client_name}
[Interface]
PrivateKey = ${client_private}
Address = ${client_iface_addr}
DNS = ${dns_servers}

[Peer]
PublicKey = ${server_public}
PresharedKey = ${psk}
Endpoint = ${endpoint_host}:${listen_port}
AllowedIPs = ${allowed_ips_client}
PersistentKeepalive = 25
EOF
    chmod 600 "$client_conf"

    applied_runtime="0"
    if command -v wg >/dev/null 2>&1 && wg show "$iface" >/dev/null 2>&1; then
        allowed_ips_peer_runtime="${allowed_ips_peer//, /,}"
        psk_file=$(mktemp)
        printf '%s\n' "$psk" > "$psk_file"
        if wg set "$iface" peer "$client_public" preshared-key "$psk_file" allowed-ips "$allowed_ips_peer_runtime" >/dev/null 2>&1; then
            applied_runtime="1"
        fi
        rm -f "$psk_file"
    fi

    if [[ "$applied_runtime" == "0" ]]; then
        service_name=$(_wireguard_service_name "$iface")
        if _has_systemd && systemctl is-active --quiet "$service_name" 2>/dev/null; then
            if systemctl restart "$service_name" >/dev/null 2>&1; then
                applied_runtime="1"
            fi
        elif _has_openrc && _service_script_exists "$service_name"; then
            if rc-service "$service_name" restart >/dev/null 2>&1; then
                applied_runtime="1"
            fi
        fi
    fi

    _success "客户端 ${client_name} 已新增"
    _info "客户端地址: ${client_iface_addr}"
    _info "客户端配置: ${client_conf}"
    if [[ "$applied_runtime" == "1" ]]; then
        _info "服务端已应用新客户端，无需重建服务端"
    else
        _warn "已写入配置，但未确认运行时热加载，请执行「重启 WireGuard」使其生效"
    fi

    if command -v qrencode >/dev/null 2>&1; then
        echo ""
        printf "  ${BOLD}二维码 (ANSI):${PLAIN}\n"
        qrencode -t ANSIUTF8 < "$client_conf" || true
    fi
    _press_any_key
}

_wireguard_restart() {
    _header "WireGuard 重启"
    local iface service_name
    iface=$(_wireguard_detect_iface)
    if [[ ! -f "${_WIREGUARD_DIR}/${iface}.conf" ]]; then
        _error_no_exit "未找到 WireGuard 配置: ${_WIREGUARD_DIR}/${iface}.conf"
        _press_any_key
        return
    fi

    service_name="wg-quick@${iface}"
    service_name=$(_wireguard_service_name "$iface")
    if _has_systemd; then
        if ! systemctl restart "$service_name" >/dev/null 2>&1; then
            _error_no_exit "重启失败，请检查: systemctl status ${service_name}"
            _press_any_key
            return
        fi
        if systemctl is-active --quiet "$service_name"; then
            _success "WireGuard 已成功重启 (${iface})"
        else
            _error_no_exit "服务未运行，请检查: systemctl status ${service_name}"
        fi
    elif _has_openrc && _service_script_exists "$service_name"; then
        if ! rc-service "$service_name" restart >/dev/null 2>&1; then
            _error_no_exit "重启失败，请检查: rc-service ${service_name} status"
            _press_any_key
            return
        fi
        if _wireguard_service_is_active "$iface"; then
            _success "WireGuard 已成功重启 (${iface})"
        else
            _error_no_exit "服务未运行，请检查: rc-service ${service_name} status"
        fi
    else
        wg-quick down "$iface" >/dev/null 2>&1 || true
        if wg-quick up "$iface" >/dev/null 2>&1; then
            _success "WireGuard 已成功重启 (${iface})"
        else
            _error_no_exit "wg-quick 重启失败"
        fi
    fi
    _press_any_key
}

_wireguard_status() {
    _header "WireGuard 状态"
    local iface service_name conf_file firewall_service_file
    iface=$(_wireguard_detect_iface)
    conf_file="${_WIREGUARD_DIR}/${iface}.conf"
    service_name=$(_wireguard_service_name "$iface")
    firewall_service_file=$(_wireguard_firewall_service_file "$iface")

    if [[ -f "$conf_file" ]]; then
        _info "配置文件: ${conf_file}"
        _info "监听端口: $(_wireguard_conf_get_value "$iface" "ListenPort" 2>/dev/null || echo unknown)"
        _info "Endpoint: $(_wireguard_meta_get "$iface" "vpsgo-endpoint" 2>/dev/null || echo unknown)"
        _info "DNS: $(_wireguard_meta_get "$iface" "vpsgo-dns" 2>/dev/null || echo unknown)"
    else
        _warn "未找到配置文件: ${conf_file}"
    fi

    echo ""
    if _has_systemd; then
        systemctl status "$service_name" --no-pager 2>/dev/null || _warn "未检测到 systemd 服务 ${service_name}"
        if [[ -f "$firewall_service_file" ]]; then
            echo ""
            systemctl status "$(basename "$firewall_service_file")" --no-pager 2>/dev/null || _warn "未检测到 NAT 服务 $(basename "$firewall_service_file")"
        fi
    elif _has_openrc; then
        if _service_script_exists "$service_name"; then
            rc-service "$service_name" status || true
        else
            _warn "未检测到 OpenRC 服务 ${service_name}"
        fi
        if [[ -f "$firewall_service_file" ]]; then
            echo ""
            rc-service "$(_wireguard_firewall_service_name "$iface")" status || _warn "未检测到 NAT 服务 $(_wireguard_firewall_service_name "$iface")"
        fi
    fi
    echo ""
    if command -v wg >/dev/null 2>&1; then
        wg show "$iface" 2>/dev/null || wg show 2>/dev/null || true
    fi
    _press_any_key
}

_wireguard_show_client() {
    _header "WireGuard 客户端配置"
    local iface default_client client_file
    iface=$(_wireguard_detect_iface)
    default_client="${_WIREGUARD_CLIENT_DIR}/${iface}-client1.conf"
    read -rp "  客户端配置文件 [默认 ${default_client}]: " client_file
    client_file=$(_mihomoconf_trim "${client_file:-$default_client}")
    if [[ ! -f "$client_file" ]]; then
        _error_no_exit "未找到客户端配置: ${client_file}"
        _press_any_key
        return
    fi

    _info "客户端配置: ${client_file}"
    _separator
    cat "$client_file"
    if command -v qrencode >/dev/null 2>&1; then
        echo ""
        printf "  ${BOLD}二维码 (ANSI):${PLAIN}\n"
        qrencode -t ANSIUTF8 < "$client_file" || true
    fi
    _press_any_key
}

_wireguard_uninstall() {
    _header "卸载 WireGuard 原生节点"
    local iface service_name confirm remove_config
    iface=$(_wireguard_detect_iface)
    service_name=$(_wireguard_service_name "$iface")

    _warn "将停止 WireGuard 节点服务，可选删除配置文件"
    printf "    服务: %s\n" "$service_name"
    printf "    配置: %s\n" "${_WIREGUARD_DIR}/${iface}.conf"
    read -rp "  确认继续? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy] ]]; then
        _info "已取消"
        _press_any_key
        return
    fi

    if _has_systemd; then
        systemctl stop "$service_name" >/dev/null 2>&1 || true
        systemctl disable "$service_name" >/dev/null 2>&1 || true
    elif _has_openrc; then
        rc-service "$service_name" stop >/dev/null 2>&1 || true
        rc-update del "$service_name" default >/dev/null 2>&1 || true
    else
        wg-quick down "$iface" >/dev/null 2>&1 || true
    fi

    _wireguard_remove_firewall_service "$iface"
    if _has_openrc; then
        rm -f "$(_wireguard_service_file "$iface")"
    fi
    rm -f "$_WIREGUARD_SYSCTL_FILE"
    if _has_systemd; then
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    sysctl --system >/dev/null 2>&1 || true

    read -rp "  是否删除 WireGuard 配置目录 ${_WIREGUARD_DIR}? [y/N]: " remove_config
    if [[ "$remove_config" =~ ^[Yy] ]]; then
        rm -rf "$_WIREGUARD_DIR"
        _success "已删除配置目录: ${_WIREGUARD_DIR}"
    else
        _info "已保留配置目录: ${_WIREGUARD_DIR}"
    fi
    _success "WireGuard 节点已停止"
    _press_any_key
}

_wireguard_manage() {
    while true; do
        _header "WireGuard 原生节点"
        local iface conf_file listen_port
        iface=$(_wireguard_detect_iface)
        conf_file="${_WIREGUARD_DIR}/${iface}.conf"

        if command -v wg >/dev/null 2>&1; then
            _info "工具版本: $(wg --version 2>/dev/null | head -1)"
        else
            _info "当前未安装 wireguard-tools"
        fi
        _info "接口: ${iface}"
        if [[ -f "$conf_file" ]]; then
            listen_port=$(_wireguard_conf_get_value "$iface" "ListenPort" 2>/dev/null || true)
            _info "配置文件: ${conf_file}"
            [[ -n "$listen_port" ]] && _info "监听端口: ${listen_port}"
        else
            _info "配置文件: ${conf_file} (不存在，可通过选项 2 部署)"
        fi

        _separator
        _menu_pair "1" "安装/更新 WireGuard" "原生内核方案" "green" "2" "部署/重建节点" "含 Mihomo 端口冲突检查" "green"
        _menu_pair "3" "重启 WireGuard" "" "green" "4" "查看状态" "" "green"
        _menu_pair "5" "查看客户端配置" "可显示二维码" "green" "6" "新增客户端" "不重建服务端" "green"
        _menu_pair "7" "卸载 WireGuard 节点" "可选删除配置" "yellow" "0" "返回上级菜单" "" "red"
        _separator

        local ch
        read -rp "  选择 [0-7]: " ch
        case "$ch" in
            1) _wireguard_install_or_update ;;
            2) _wireguard_deploy ;;
            3) _wireguard_restart ;;
            4) _wireguard_status ;;
            5) _wireguard_show_client ;;
            6) _wireguard_add_client ;;
            7) _wireguard_uninstall ;;
            0) return ;;
            *) _error_no_exit "无效选项"; sleep 1 ;;
        esac
    done
}

# --- ACME 证书管理 ---

_acme_is_installed() {
    [ -x "$_ACME_BIN" ]
}

_acme_cmd() {
    "$_ACME_BIN" --home "$_ACME_HOME" "$@"
}

_acme_random_email() {
    printf '%04d@gmail.com' "$((RANDOM % 9000 + 1000))"
}

_acme_get_public_ipv4() {
    curl -4fsSL --max-time 6 https://api64.ipify.org 2>/dev/null || true
}

_acme_get_public_ipv6() {
    curl -6fsSL --max-time 6 https://api64.ipify.org 2>/dev/null || true
}

_acme_resolve_records() {
    local domain="$1" rtype="$2"
    if command -v dig >/dev/null 2>&1; then
        dig +short "$domain" "$rtype" 2>/dev/null \
            | sed 's/[[:space:]]*$//' \
            | grep -E '^[0-9a-fA-F:.]+$' || true
        return
    fi

    if command -v nslookup >/dev/null 2>&1; then
        nslookup -type="$rtype" "$domain" 2>/dev/null \
            | awk '/^Address: /{print $2}' \
            | grep -E '^[0-9a-fA-F:.]+$' || true
    fi
}

_acme_verify_domain_points_here() {
    local raw_domain="$1"
    local domain="$raw_domain"
    [[ "$domain" == \*.* ]] && domain="${domain#*.}"

    _dns_ensure_lookup_tool || true

    local local_v4 local_v6
    local_v4="$(_acme_get_public_ipv4)"
    local_v6="$(_acme_get_public_ipv6)"

    local -a rec_v4=() rec_v6=()
    mapfile -t rec_v4 < <(_acme_resolve_records "$domain" "A")
    mapfile -t rec_v6 < <(_acme_resolve_records "$domain" "AAAA")

    echo ""
    printf "  ${BOLD}域名指向校验${PLAIN}\n"
    _status_kv "Domain" "$domain" "cyan" 10
    _status_kv "本机 IPv4" "${local_v4:-N/A}" "cyan" 10
    _status_kv "本机 IPv6" "${local_v6:-N/A}" "cyan" 10
    _status_kv "DNS A" "${rec_v4[*]:-N/A}" "cyan" 10
    _status_kv "DNS AAAA" "${rec_v6[*]:-N/A}" "cyan" 10

    local matched=1 item
    matched=0
    if [ -n "$local_v4" ]; then
        for item in "${rec_v4[@]}"; do
            [ "$item" = "$local_v4" ] && matched=1
        done
    fi
    if [ "$matched" -eq 0 ] && [ -n "$local_v6" ]; then
        for item in "${rec_v6[@]}"; do
            [ "$item" = "$local_v6" ] && matched=1
        done
    fi

    if [ "$matched" -eq 1 ]; then
        _success "域名 A/AAAA 已正确指向本机（v4/v6 任一匹配）"
        return 0
    fi
    _warn "域名未指向本机公网 IP，签发可能失败"
    return 1
}

_acme_install_or_update() {
    _header "Acme.sh 安装/自动更新"

    local email_input email
    email="$(_acme_random_email)"
    read -rp "  注册邮箱 [默认 ${email}]: " email_input
    email="${email_input:-$email}"

    if ! command -v curl >/dev/null 2>&1; then
        _error_no_exit "缺少 curl，无法安装 acme.sh"
        _press_any_key
        return
    fi

    if ! _acme_is_installed; then
        _info "未检测到 acme.sh，开始安装..."
        if ! curl -fsSL https://get.acme.sh | sh -s email="$email"; then
            _error_no_exit "acme.sh 安装失败"
            _press_any_key
            return
        fi
    else
        _info "已安装 acme.sh，开始升级..."
        if ! _acme_cmd --upgrade; then
            _error_no_exit "acme.sh 升级失败"
            _press_any_key
            return
        fi
    fi

    _acme_cmd --upgrade --auto-upgrade >/dev/null 2>&1 || true
    _success "acme.sh 已就绪，并启用自动更新"
    _info "版本: $(_acme_cmd --version 2>/dev/null || echo unknown)"
    _press_any_key
}

_acme_manual_update() {
    _header "Acme.sh 手动更新"
    if ! _acme_is_installed; then
        _warn "未安装 acme.sh，请先执行安装/自动更新"
        _press_any_key
        return
    fi
    if _acme_cmd --upgrade; then
        _success "acme.sh 手动更新成功"
        _info "版本: $(_acme_cmd --version 2>/dev/null || echo unknown)"
    else
        _error_no_exit "acme.sh 手动更新失败"
    fi
    _press_any_key
}

_acme_manual_renew_cert() {
    _header "证书手动更新"
    if ! _acme_is_installed; then
        _warn "未安装 acme.sh，请先执行安装/自动更新"
        _press_any_key
        return
    fi

    echo ""
    _info "已签发证书列表:"
    _acme_cmd --list 2>/dev/null || true

    local domain
    read -rp "  输入要续期的域名: " domain
    domain="${domain//[[:space:]]/}"
    if [ -z "$domain" ]; then
        _error_no_exit "域名不能为空"
        _press_any_key
        return
    fi

    local cert_dir_input cert_dir
    cert_dir="${_ACME_CERT_DEFAULT_DIR}"
    read -rp "  证书输出目录 [默认 ${cert_dir}]: " cert_dir_input
    cert_dir="${cert_dir_input:-$cert_dir}"
    mkdir -p "$cert_dir"

    _info "开始手动续期: ${domain}"
    if ! _acme_cmd --renew -d "$domain" --force; then
        _error_no_exit "证书续期失败"
        _press_any_key
        return
    fi

    local reload_cmd
    reload_cmd=$(_mihomo_reload_cmd_for_acme)

    if _acme_cmd --install-cert -d "$domain" \
        --key-file "${cert_dir}/cert.key" \
        --fullchain-file "${cert_dir}/cert.crt" \
        --reloadcmd "$reload_cmd"; then
        _acme_cmd --upgrade --auto-upgrade >/dev/null 2>&1 || true
        _success "证书手动更新成功"
        _info "证书: ${cert_dir}/cert.crt"
        _info "私钥: ${cert_dir}/cert.key"
    else
        _error_no_exit "证书安装失败"
    fi

    _press_any_key
}

_acme_toggle_auto_update() {
    _header "Acme.sh 自动更新设置"
    if ! _acme_is_installed; then
        _warn "未安装 acme.sh，请先执行安装/自动更新"
        _press_any_key
        return
    fi

    _separator
    _menu_pair "1" "开启自动更新" "" "green" "2" "关闭自动更新" "" "yellow"
    _menu_item "0" "返回上级菜单" "" "red"
    _separator

    local pick
    read -rp "  选择 [0-2]: " pick
    case "$pick" in
        1)
            _acme_cmd --upgrade --auto-upgrade >/dev/null 2>&1 \
                && _success "已开启自动更新" \
                || _error_no_exit "开启自动更新失败"
            ;;
        2)
            _acme_cmd --upgrade --auto-upgrade 0 >/dev/null 2>&1 \
                && _success "已关闭自动更新" \
                || _error_no_exit "关闭自动更新失败"
            ;;
        0) return ;;
        *) _error_no_exit "无效选项: ${pick}" ;;
    esac
    _press_any_key
}

_acme_select_ca() {
    _separator
    _menu_pair "1" "Let's Encrypt" "letsencrypt" "green" "2" "ZeroSSL" "zerossl" "green"
    _menu_pair "3" "Buypass" "buypass" "green" "4" "SSL.com" "sslcom" "green"
    _separator
    local pick
    read -rp "  证书提供商 [1-4，默认 1]: " pick
    case "${pick:-1}" in
        1) _ACME_CA_SERVER="letsencrypt" ;;
        2) _ACME_CA_SERVER="zerossl" ;;
        3) _ACME_CA_SERVER="buypass" ;;
        4) _ACME_CA_SERVER="sslcom" ;;
        *) _ACME_CA_SERVER="letsencrypt" ;;
    esac
}

_acme_prepare_dns_provider() {
    _ACME_DNS_PROVIDER=""
    unset CF_Token CF_Account_ID CF_Key CF_Email Ali_Key Ali_Secret DP_Id DP_Key

    _separator
    _menu_pair "1" "Cloudflare" "dns_cf" "green" "2" "AliDNS" "dns_ali" "green"
    _menu_pair "3" "DNSPod(Tencent)" "dns_dp" "green" "0" "取消" "" "red"
    _separator

    local pick
    read -rp "  DNS 厂商 [0-3]: " pick
    case "$pick" in
        1)
            local cf_token cf_account cf_key cf_email
            read -rp "  CF_Token (推荐): " cf_token
            read -rp "  CF_Account_ID (可选): " cf_account
            if [ -n "$cf_token" ]; then
                export CF_Token="$cf_token"
                [ -n "$cf_account" ] && export CF_Account_ID="$cf_account"
            else
                read -rp "  CF_Key: " cf_key
                read -rp "  CF_Email: " cf_email
                if [ -z "$cf_key" ] || [ -z "$cf_email" ]; then
                    _error_no_exit "Cloudflare 凭据不完整"
                    return 1
                fi
                export CF_Key="$cf_key"
                export CF_Email="$cf_email"
            fi
            _ACME_DNS_PROVIDER="dns_cf"
            ;;
        2)
            local ali_key ali_secret
            read -rp "  Ali_Key: " ali_key
            read -rp "  Ali_Secret: " ali_secret
            if [ -z "$ali_key" ] || [ -z "$ali_secret" ]; then
                _error_no_exit "AliDNS 凭据不完整"
                return 1
            fi
            export Ali_Key="$ali_key"
            export Ali_Secret="$ali_secret"
            _ACME_DNS_PROVIDER="dns_ali"
            ;;
        3)
            local dp_id dp_key
            read -rp "  DP_Id: " dp_id
            read -rp "  DP_Key: " dp_key
            if [ -z "$dp_id" ] || [ -z "$dp_key" ]; then
                _error_no_exit "DNSPod 凭据不完整"
                return 1
            fi
            export DP_Id="$dp_id"
            export DP_Key="$dp_key"
            _ACME_DNS_PROVIDER="dns_dp"
            ;;
        0) return 1 ;;
        *) _error_no_exit "无效选项: ${pick}"; return 1 ;;
    esac
    return 0
}

_acme_issue_cert() {
    _header "Acme.sh 申请证书"

    if ! _acme_is_installed; then
        _warn "未安装 acme.sh，请先执行“安装/自动更新 acme.sh”"
        _press_any_key
        return
    fi

    local domain
    read -rp "  输入证书域名 (如 example.com 或 *.example.com): " domain
    domain="${domain//[[:space:]]/}"
    if [ -z "$domain" ]; then
        _error_no_exit "域名不能为空"
        _press_any_key
        return
    fi

    _acme_verify_domain_points_here "$domain" || {
        local force_continue
        read -rp "  域名未指向本机，仍继续申请? [y/N]: " force_continue
        [[ "$force_continue" =~ ^[Yy]$ ]] || { _press_any_key; return; }
    }

    local ca_server
    _acme_select_ca
    ca_server="${_ACME_CA_SERVER:-letsencrypt}"
    _info "证书提供商: ${ca_server}"
    _acme_cmd --set-default-ca --server "$ca_server" >/dev/null 2>&1 || true

    _separator
    _menu_pair "1" "80 端口验证" "standalone/http-01" "green" "2" "DNS 验证" "dns-01" "green"
    _menu_item "0" "取消" "" "red"
    _separator

    local method
    read -rp "  验证方式 [0-2]: " method
    case "$method" in
        1)
            if [[ "$domain" == \*.* ]]; then
                _error_no_exit "通配符域名不支持 80 端口验证，请使用 DNS 验证"
                _press_any_key
                return
            fi
            _info "开始 80 端口验证签发..."
            if ! _acme_cmd --issue -d "$domain" --standalone --httpport 80 --server "$ca_server"; then
                _error_no_exit "证书签发失败 (80 端口验证)"
                _press_any_key
                return
            fi
            ;;
        2)
            if ! _acme_prepare_dns_provider; then
                _press_any_key
                return
            fi
            _info "开始 DNS 验证签发 (${_ACME_DNS_PROVIDER})..."
            if ! _acme_cmd --issue -d "$domain" --dns "$_ACME_DNS_PROVIDER" --server "$ca_server"; then
                _error_no_exit "证书签发失败 (DNS 验证)"
                _press_any_key
                return
            fi
            ;;
        0)
            return
            ;;
        *)
            _error_no_exit "无效选项: ${method}"
            _press_any_key
            return
            ;;
    esac

    local cert_dir_input cert_dir
    cert_dir="${_ACME_CERT_DEFAULT_DIR}"
    read -rp "  证书输出目录 [默认 ${cert_dir}]: " cert_dir_input
    cert_dir="${cert_dir_input:-$cert_dir}"
    mkdir -p "$cert_dir"

    local reload_cmd
    reload_cmd=$(_mihomo_reload_cmd_for_acme)

    if _acme_cmd --install-cert -d "$domain" \
        --key-file "${cert_dir}/cert.key" \
        --fullchain-file "${cert_dir}/cert.crt" \
        --reloadcmd "$reload_cmd"; then
        _acme_cmd --upgrade --auto-upgrade >/dev/null 2>&1 || true
        _success "证书安装成功"
        _info "acme.sh 自动更新: 已开启"
        _info "证书: ${cert_dir}/cert.crt"
        _info "私钥: ${cert_dir}/cert.key"
    else
        _error_no_exit "证书安装失败"
    fi

    _press_any_key
}

_acme_manage() {
    while true; do
        _header "ACME 证书管理"
        if _acme_is_installed; then
            _info "acme.sh: $(_acme_cmd --version 2>/dev/null || echo unknown)"
        else
            _warn "acme.sh 未安装"
        fi

        _separator
        _menu_pair "1" "安装/自动更新 acme.sh" "Github 安装脚本" "green" "2" "申请证书 (80/DNS)" "签发并安装到目录" "green"
        _menu_pair "3" "手动更新 acme.sh" "" "green" "4" "自动更新设置" "开启/关闭" "green"
        _menu_item "5" "手动更新证书" "立即续期并覆盖安装" "green"
        _menu_item "0" "返回主菜单" "" "red"
        _separator

        local choice
        read -rp "  选择 [0-5]: " choice
        case "$choice" in
            1) _acme_install_or_update ;;
            2) _acme_issue_cert ;;
            3) _acme_manual_update ;;
            4) _acme_toggle_auto_update ;;
            5) _acme_manual_renew_cert ;;
            0) return ;;
            *) _error_no_exit "无效选项: ${choice}"; sleep 1 ;;
        esac
    done
}

# --- 14. Akile DNS 解锁检测与配置 ---

_akdns_install_deps() {
    local need_install=0
    local required_deps=(dig curl ip awk grep sed chattr lsattr mktemp readlink)
    local optional_deps=(nmcli resolvectl netplan)
    local missing_required=()
    local missing_optional=()
    local cmd

    for cmd in "${required_deps[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_required+=("$cmd")
        fi
    done
    for cmd in "${optional_deps[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_optional+=("$cmd")
        fi
    done

    if [ ${#missing_required[@]} -eq 0 ] && [ ${#missing_optional[@]} -eq 0 ]; then
        _info "Akile DNS 依赖已就绪"
        return 0
    fi

    need_install=1
    [ ${#missing_required[@]} -gt 0 ] && _warn "检测到缺失核心依赖: ${missing_required[*]}"
    [ ${#missing_optional[@]} -gt 0 ] && _warn "检测到缺失可选依赖: ${missing_optional[*]}"
    _info "正在尝试自动安装依赖..."

    local packages=()
    local unmapped_required=()
    local unmapped_optional=()
    local add_pkg
    add_pkg() {
        local p="$1"
        [[ " ${packages[*]} " == *" ${p} "* ]] || packages+=("$p")
    }

    local all_missing=("${missing_required[@]}" "${missing_optional[@]}")
    for cmd in "${all_missing[@]}"; do
        local mapped=1
        case "$cmd" in
            dig)
                if command -v apt-get >/dev/null 2>&1; then add_pkg dnsutils
                elif command -v yum >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1 || command -v zypper >/dev/null 2>&1; then add_pkg bind-utils
                elif command -v apk >/dev/null 2>&1; then add_pkg bind-tools
                elif command -v pacman >/dev/null 2>&1; then add_pkg bind
                else mapped=0; fi
                ;;
            curl) add_pkg curl ;;
            ip)
                if command -v apt-get >/dev/null 2>&1 || command -v apk >/dev/null 2>&1; then add_pkg iproute2
                elif command -v yum >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1 || command -v zypper >/dev/null 2>&1; then add_pkg iproute
                elif command -v pacman >/dev/null 2>&1; then add_pkg iproute2
                else mapped=0; fi
                ;;
            awk) add_pkg gawk ;;
            grep) add_pkg grep ;;
            sed) add_pkg sed ;;
            chattr|lsattr) add_pkg e2fsprogs ;;
            mktemp|readlink) add_pkg coreutils ;;
            nmcli)
                if command -v apt-get >/dev/null 2>&1; then add_pkg network-manager
                elif command -v yum >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1 || command -v zypper >/dev/null 2>&1; then add_pkg NetworkManager
                elif command -v pacman >/dev/null 2>&1; then add_pkg networkmanager
                elif command -v apk >/dev/null 2>&1; then add_pkg networkmanager
                else mapped=0; fi
                ;;
            resolvectl)
                if command -v apt-get >/dev/null 2>&1 || command -v yum >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1 || command -v zypper >/dev/null 2>&1; then add_pkg systemd
                elif command -v pacman >/dev/null 2>&1; then add_pkg systemd
                elif command -v apk >/dev/null 2>&1; then add_pkg openresolv
                else mapped=0; fi
                ;;
            netplan)
                if command -v apt-get >/dev/null 2>&1; then add_pkg netplan.io
                elif command -v apk >/dev/null 2>&1; then add_pkg netplan
                elif command -v pacman >/dev/null 2>&1; then add_pkg netplan
                else mapped=0; fi
                ;;
            *) mapped=0 ;;
        esac

        if [ "$mapped" -eq 0 ]; then
            if [[ " ${missing_required[*]} " == *" ${cmd} "* ]]; then
                unmapped_required+=("$cmd")
            else
                unmapped_optional+=("$cmd")
            fi
        fi
    done

    if [ ${#unmapped_required[@]} -gt 0 ]; then
        _error_no_exit "核心依赖无法自动映射安装，请手动安装: ${unmapped_required[*]}"
        return 1
    fi
    [ ${#unmapped_optional[@]} -gt 0 ] && _warn "可选依赖无法自动映射安装，将继续执行: ${unmapped_optional[*]}"

    if [ ${#packages[@]} -gt 0 ]; then
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -qq && apt-get install -y -qq "${packages[@]}"
        elif command -v yum >/dev/null 2>&1; then
            yum install -y "${packages[@]}"
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y "${packages[@]}"
        elif command -v pacman >/dev/null 2>&1; then
            pacman -Sy --noconfirm "${packages[@]}"
        elif command -v apk >/dev/null 2>&1; then
            apk add --no-cache "${packages[@]}"
        elif command -v zypper >/dev/null 2>&1; then
            zypper install -y "${packages[@]}"
        elif [ ${#missing_required[@]} -gt 0 ]; then
            _error_no_exit "无法识别包管理器，请手动安装核心依赖: ${missing_required[*]}"
            return 1
        else
            _warn "无法识别包管理器，可选依赖将跳过安装: ${missing_optional[*]}"
        fi
    fi

    local still_missing_required=()
    local still_missing_optional=()
    for cmd in "${required_deps[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            still_missing_required+=("$cmd")
        fi
    done
    for cmd in "${optional_deps[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            still_missing_optional+=("$cmd")
        fi
    done

    if [ ${#still_missing_required[@]} -gt 0 ]; then
        _error_no_exit "核心依赖安装不完整，请手动安装: ${still_missing_required[*]}"
        return 1
    fi
    [ ${#still_missing_optional[@]} -gt 0 ] && _warn "可选依赖仍缺失，将继续执行: ${still_missing_optional[*]}"

    if [ "$need_install" -eq 1 ]; then
        _info "Akile DNS 依赖检查完成"
    fi
    return 0
}

_akdns_setup() {
    _header "Akile DNS 解锁检测与配置"
    
    echo ""
    _warn "在操作之前，请务必前往 https://dns.akile.ai 添加本机的 IP！"
    _warn "如果不添加 IP，解锁设置将无法生效！"
    echo ""
    
    local confirm
    read -rp "  是否已在 https://dns.akile.ai 添加本机 IP? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy] ]]; then
        _info "请先前往网站添加 IP，然后再返回继续操作。"
        _press_any_key
        return
    fi
    
    echo ""
    if ! _akdns_install_deps; then
        _press_any_key
        return
    fi

    _info "正在启动 Akile DNS 脚本..."
    echo ""

    # 运行 Akile DNS 测试及配置脚本
    wget -qO- https://raw.githubusercontent.com/akile-network/aktools/refs/heads/main/akdns.sh | bash
    
    _press_any_key
}

# --- 15. Linux DNS 管理 ---

_DNS_SERVERS=()
_DNS_V4_SERVERS=()
_DNS_V6_SERVERS=()
_DNS_RESTART_SERVICES=()
_DNS_CLEAR_EXISTING=1

_dns_validate_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1

    local IFS='.'
    local o
    read -r -a octets <<< "$ip"
    [ "${#octets[@]}" -eq 4 ] || return 1

    for o in "${octets[@]}"; do
        [[ "$o" =~ ^[0-9]+$ ]] || return 1
        [ "$o" -ge 0 ] && [ "$o" -le 255 ] || return 1
    done
    return 0
}

_dns_validate_ipv6() {
    local ip="$1"
    [[ "$ip" == *:* ]] || return 1
    [[ "$ip" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
    return 0
}

_dns_add_server() {
    local token="$1"
    [ -n "$token" ] || return 1

    token="${token#[}"
    token="${token%]}"
    token="${token%,}"

    if _dns_validate_ipv4 "$token"; then
        if [[ " ${_DNS_SERVERS[*]} " != *" ${token} "* ]]; then
            _DNS_SERVERS+=("$token")
            _DNS_V4_SERVERS+=("$token")
        fi
        return 0
    fi

    if _dns_validate_ipv6 "$token"; then
        if [[ " ${_DNS_SERVERS[*]} " != *" ${token} "* ]]; then
            _DNS_SERVERS+=("$token")
            _DNS_V6_SERVERS+=("$token")
        fi
        return 0
    fi

    return 1
}

_dns_parse_servers() {
    local raw="$1"
    local token

    _DNS_SERVERS=()
    _DNS_V4_SERVERS=()
    _DNS_V6_SERVERS=()

    raw="${raw//，/,}"
    raw="${raw//;/ }"
    raw="${raw//,/ }"
    raw="${raw//$'\n'/ }"

    for token in $raw; do
        [ -z "$token" ] && continue

        if ! _dns_add_server "$token"; then
            _error_no_exit "无效 DNS 地址: ${token}"
            return 1
        fi
    done

    if [ ${#_DNS_SERVERS[@]} -eq 0 ]; then
        _error_no_exit "请至少输入一个有效 DNS 地址"
        return 1
    fi
    return 0
}

_dns_merge_existing_servers() {
    local token merged=0

    while IFS= read -r token; do
        [ -n "$token" ] || continue
        if _dns_add_server "$token"; then
            merged=$((merged + 1))
        fi
    done < <(awk '/^[[:space:]]*nameserver[[:space:]]+/ {print $2}' /etc/resolv.conf 2>/dev/null)

    if command -v resolvectl >/dev/null 2>&1 && resolvectl status >/dev/null 2>&1; then
        while IFS= read -r token; do
            [ -n "$token" ] || continue
            if _dns_add_server "$token"; then
                merged=$((merged + 1))
            fi
        done < <(resolvectl dns 2>/dev/null | tr ' ' '\n' | sed 's/%.*//' )
    fi

    if [ "$merged" -gt 0 ]; then
        _info "已保留并合并现有 DNS"
    else
        _warn "未获取到可合并的现有 DNS，继续仅使用新 DNS"
    fi
}

_dns_force_runtime_servers() {
    local iface
    command -v resolvectl >/dev/null 2>&1 || return 0
    resolvectl status >/dev/null 2>&1 || return 0

    while IFS= read -r iface; do
        [ -n "$iface" ] || continue
        resolvectl dns "$iface" "${_DNS_SERVERS[@]}" >/dev/null 2>&1 || true
        resolvectl domain "$iface" "~." >/dev/null 2>&1 || true
    done < <(resolvectl status 2>/dev/null | sed -n 's/^Link [0-9]\+ (\([^)]*\)).*$/\1/p')

    resolvectl flush-caches >/dev/null 2>&1 || true
}

_dns_default_iface() {
    local iface
    iface=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
    if [ -z "$iface" ]; then
        iface=$(ip -o link show 2>/dev/null | awk -F': ' '$2 !~ /^lo$/ {print $2; exit}')
    fi
    printf '%s' "$iface"
}

_dns_service_exists() {
    local svc="$1"
    if _has_systemd; then
        local state
        state=$(systemctl show -p LoadState --value "${svc}.service" 2>/dev/null || true)
        [ -n "$state" ] && [ "$state" != "not-found" ]
        return
    fi
    if _has_openrc; then
        _service_script_exists "$svc"
        return
    fi
    if command -v service >/dev/null 2>&1; then
        _service_script_exists "$svc"
        return
    fi
    return 1
}

_dns_mark_service_for_restart() {
    local svc="$1"
    [ -z "$svc" ] && return
    _dns_service_exists "$svc" || return
    if [[ " ${_DNS_RESTART_SERVICES[*]} " != *" ${svc} "* ]]; then
        _DNS_RESTART_SERVICES+=("$svc")
    fi
}

_dns_restart_service() {
    local svc="$1"
    if _has_systemd; then
        systemctl restart "$svc" >/dev/null 2>&1
        return $?
    fi
    if _has_openrc && _service_script_exists "$svc"; then
        rc-service "$svc" restart >/dev/null 2>&1 || rc-service "$svc" start >/dev/null 2>&1
        return $?
    fi
    if command -v service >/dev/null 2>&1; then
        service "$svc" restart >/dev/null 2>&1
        return $?
    fi
    return 1
}

_dns_restart_related_services() {
    local svc
    if [ ${#_DNS_RESTART_SERVICES[@]} -eq 0 ]; then
        _warn "未检测到需要重启的 DNS 相关组件，继续验证解析结果。"
        return 0
    fi

    _info "正在重启相关组件..."
    for svc in "${_DNS_RESTART_SERVICES[@]}"; do
        if _dns_restart_service "$svc"; then
            _status_kv "服务" "${svc}" "green" 10
        else
            _status_kv "服务" "${svc} (重启失败)" "yellow" 10
        fi
    done
    return 0
}

_dns_clear_resolv_immutable() {
    if command -v lsattr >/dev/null 2>&1 && command -v chattr >/dev/null 2>&1 && [ -e /etc/resolv.conf ]; then
        if lsattr /etc/resolv.conf 2>/dev/null | awk '{print $1}' | grep -q 'i'; then
            chattr -i /etc/resolv.conf >/dev/null 2>&1 || true
        fi
    fi
}

_dns_write_resolv_conf() {
    local backup="/etc/resolv.conf.vpsgo.bak"
    local dns

    if [ -e /etc/resolv.conf ] && [ ! -e "$backup" ]; then
        cp -a /etc/resolv.conf "$backup" >/dev/null 2>&1 || true
    fi

    _dns_clear_resolv_immutable
    if [ -L /etc/resolv.conf ]; then
        rm -f /etc/resolv.conf
    fi

    {
        printf "# Generated by VPSGo at %s\n" "$(date '+%F %T %Z')"
        for dns in "${_DNS_SERVERS[@]}"; do
            printf "nameserver %s\n" "$dns"
        done
        printf "options timeout:2 attempts:2 rotate\n"
    } > /etc/resolv.conf

    _info "已写入 /etc/resolv.conf"
    return 0
}

_dns_apply_permanent_resolvconf_head() {
    local head="/etc/resolvconf/resolv.conf.d/head"
    local backup="${head}.vpsgo.bak"
    local dns

    [ -d /etc/resolvconf/resolv.conf.d ] || return 1

    [ -f "$head" ] && [ ! -f "$backup" ] && cp -a "$head" "$backup" >/dev/null 2>&1 || true
    [ -f "$head" ] && sed -i '/^# VPSGO DNS BEGIN$/,/^# VPSGO DNS END$/d' "$head"

    {
        printf "# VPSGO DNS BEGIN\n"
        for dns in "${_DNS_SERVERS[@]}"; do
            printf "nameserver %s\n" "$dns"
        done
        printf "# VPSGO DNS END\n"
    } >> "$head"

    if command -v resolvconf >/dev/null 2>&1; then
        resolvconf -u >/dev/null 2>&1 || true
    fi
    _dns_mark_service_for_restart "resolvconf"
    _info "已写入 resolvconf 持久化配置: ${head}"
    return 0
}

_dns_apply_permanent_dhcp_overrides() {
    local dns_csv dhclient_conf dhcpcd_conf backup
    dns_csv=$(IFS=,; echo "${_DNS_SERVERS[*]}")

    dhclient_conf="/etc/dhcp/dhclient.conf"
    if [ -f "$dhclient_conf" ]; then
        backup="${dhclient_conf}.vpsgo.bak"
        [ -f "$backup" ] || cp -a "$dhclient_conf" "$backup" >/dev/null 2>&1 || true
        sed -i '/^[[:space:]]*supersede[[:space:]]\+domain-name-servers[[:space:]]\+/d' "$dhclient_conf"
        printf "supersede domain-name-servers %s;\n" "$dns_csv" >> "$dhclient_conf"
        _info "已写入 DHCP 持久化配置: ${dhclient_conf}"
    fi

    dhcpcd_conf="/etc/dhcpcd.conf"
    if [ -f "$dhcpcd_conf" ]; then
        backup="${dhcpcd_conf}.vpsgo.bak"
        [ -f "$backup" ] || cp -a "$dhcpcd_conf" "$backup" >/dev/null 2>&1 || true
        sed -i '/^[[:space:]]*static[[:space:]]\+domain_name_servers=/d' "$dhcpcd_conf"
        printf "static domain_name_servers=%s\n" "${_DNS_SERVERS[*]}" >> "$dhcpcd_conf"
        _info "已写入 dhcpcd 持久化配置: ${dhcpcd_conf}"
    fi
}

_dns_apply_runtime_resolved() {
    local iface
    command -v resolvectl >/dev/null 2>&1 || return 1

    if _dns_service_exists "systemd-resolved" && command -v systemctl >/dev/null 2>&1; then
        systemctl is-active --quiet systemd-resolved || systemctl start systemd-resolved >/dev/null 2>&1 || true
    fi
    resolvectl status >/dev/null 2>&1 || return 1

    iface="$(_dns_default_iface)"
    [ -n "$iface" ] || return 1

    if resolvectl dns "$iface" "${_DNS_SERVERS[@]}" >/dev/null 2>&1; then
        resolvectl domain "$iface" "~." >/dev/null 2>&1 || true
        resolvectl flush-caches >/dev/null 2>&1 || true
        _info "已通过 systemd-resolved 临时应用 DNS (接口: ${iface})"
        return 0
    fi

    return 1
}

_dns_apply_permanent_resolved() {
    local conf_dir conf_file dns_line

    _dns_service_exists "systemd-resolved" || return 1

    conf_dir="/etc/systemd/resolved.conf.d"
    conf_file="${conf_dir}/99-vpsgo-dns.conf"
    dns_line="${_DNS_SERVERS[*]}"

    mkdir -p "$conf_dir"
    [ -f "$conf_file" ] && cp -a "$conf_file" "${conf_file}.bak.$(date +%Y%m%d%H%M%S)" >/dev/null 2>&1 || true

    {
        printf "[Resolve]\n"
        printf "DNS=%s\n" "$dns_line"
        printf "FallbackDNS=\n"
        printf "Domains=~.\n"
    } > "$conf_file"

    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable systemd-resolved >/dev/null 2>&1 || true
    fi

    _dns_clear_resolv_immutable
    if [ -e /run/systemd/resolve/resolv.conf ]; then
        ln -snf /run/systemd/resolve/resolv.conf /etc/resolv.conf
    elif [ -e /run/systemd/resolve/stub-resolv.conf ]; then
        ln -snf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    fi

    _dns_mark_service_for_restart "systemd-resolved"
    _info "已写入 systemd-resolved 持久化配置: ${conf_file}"
    return 0
}

_dns_apply_permanent_nm() {
    local dns_v4 dns_v6 conn changed conn_changed
    local connections=()
    local unique_connections=()

    command -v nmcli >/dev/null 2>&1 || return 1
    nmcli -t -f RUNNING general status 2>/dev/null | grep -q '^running$' || return 1

    while IFS= read -r conn; do
        [ -n "$conn" ] && connections+=("$conn")
    done < <(nmcli -t -f NAME connection show --active 2>/dev/null)

    if [ ${#connections[@]} -eq 0 ]; then
        while IFS= read -r conn; do
            [ -n "$conn" ] && connections+=("$conn")
        done < <(nmcli -t -f NAME connection show 2>/dev/null)
    fi
    [ ${#connections[@]} -gt 0 ] || return 1

    for conn in "${connections[@]}"; do
        [[ " ${unique_connections[*]} " == *" ${conn} "* ]] || unique_connections+=("$conn")
    done
    connections=("${unique_connections[@]}")

    dns_v4="${_DNS_V4_SERVERS[*]}"
    dns_v6="${_DNS_V6_SERVERS[*]}"
    changed=0

    for conn in "${connections[@]}"; do
        conn_changed=0

        if [ "$_DNS_CLEAR_EXISTING" -eq 1 ]; then
            nmcli connection modify "$conn" ipv4.ignore-auto-dns yes >/dev/null 2>&1 && conn_changed=1
            nmcli connection modify "$conn" ipv6.ignore-auto-dns yes >/dev/null 2>&1 && conn_changed=1
            [ -z "$dns_v4" ] && nmcli connection modify "$conn" ipv4.dns "" >/dev/null 2>&1 && conn_changed=1
            [ -z "$dns_v6" ] && nmcli connection modify "$conn" ipv6.dns "" >/dev/null 2>&1 && conn_changed=1
        fi

        if [ -n "$dns_v4" ]; then
            nmcli connection modify "$conn" ipv4.ignore-auto-dns yes ipv4.dns "$dns_v4" >/dev/null 2>&1 && conn_changed=1
        fi
        if [ -n "$dns_v6" ]; then
            nmcli connection modify "$conn" ipv6.ignore-auto-dns yes ipv6.dns "$dns_v6" >/dev/null 2>&1 && conn_changed=1
        fi
        [ "$conn_changed" -eq 1 ] && changed=1
        nmcli connection up "$conn" >/dev/null 2>&1 || true
    done

    if [ "$changed" -eq 1 ]; then
        nmcli connection reload >/dev/null 2>&1 || true
        _dns_mark_service_for_restart "NetworkManager"
        _info "已写入 NetworkManager 持久化 DNS 配置"
        return 0
    fi
    return 1
}

_dns_apply_temporary() {
    _DNS_RESTART_SERVICES=()
    _info "正在临时修改 DNS..."

    if _dns_apply_runtime_resolved; then
        [ "$_DNS_CLEAR_EXISTING" -eq 1 ] && _dns_force_runtime_servers
        _dns_mark_service_for_restart "nscd"
        _dns_mark_service_for_restart "dnsmasq"
        _dns_restart_related_services
        _info "临时 DNS 修改完成（系统重启或网络重连后可能失效）"
        return 0
    fi

    if _dns_write_resolv_conf; then
        _dns_mark_service_for_restart "nscd"
        _dns_mark_service_for_restart "dnsmasq"
        _dns_restart_related_services
        _info "临时 DNS 修改完成（系统重启后可能失效）"
        return 0
    fi

    _error_no_exit "临时 DNS 修改失败"
    return 1
}

_dns_apply_permanent() {
    local methods=()
    local used_resolved=0
    _DNS_RESTART_SERVICES=()

    _info "正在写入永久 DNS 配置..."

    if _dns_apply_permanent_resolved; then
        methods+=("systemd-resolved")
        used_resolved=1
    fi

    if _dns_apply_permanent_nm; then
        methods+=("NetworkManager")
    fi

    if [ ${#methods[@]} -eq 0 ]; then
        if _dns_apply_permanent_resolvconf_head; then
            methods+=("resolvconf")
        fi
        if _dns_write_resolv_conf; then
            methods+=("/etc/resolv.conf")
        fi
        _dns_apply_permanent_dhcp_overrides
        _dns_mark_service_for_restart "networking"
        _dns_mark_service_for_restart "dhcpcd"
    fi

    _dns_mark_service_for_restart "nscd"
    _dns_mark_service_for_restart "dnsmasq"

    if [ ${#methods[@]} -gt 0 ]; then
        _status_kv "应用方式" "${methods[*]}" "cyan" 10
    else
        _warn "未检测到可写入的持久化 DNS 组件，可能需要手动配置。"
    fi
    _dns_restart_related_services
    # 使用 systemd-resolved 持久化时，避免重复写入同组运行时 DNS 导致展示重复
    if [ "$_DNS_CLEAR_EXISTING" -eq 1 ] && [ "$used_resolved" -eq 0 ]; then
        _dns_force_runtime_servers
    fi
    return 0
}

_dns_ensure_lookup_tool() {
    if command -v dig >/dev/null 2>&1 || command -v nslookup >/dev/null 2>&1; then
        return 0
    fi

    _warn "未检测到 dig/nslookup，尝试自动安装 DNS 查询工具..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq && apt-get install -y -qq dnsutils
    elif command -v yum >/dev/null 2>&1; then
        yum install -y bind-utils
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y bind-utils
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm bind
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache bind-tools
    elif command -v zypper >/dev/null 2>&1; then
        zypper install -y bind-utils
    fi

    if command -v dig >/dev/null 2>&1 || command -v nslookup >/dev/null 2>&1; then
        _info "DNS 查询工具安装完成"
        return 0
    fi
    _warn "无法自动安装 dig/nslookup，将跳过验证"
    return 1
}

_dns_show_current_config() {
    local line token
    local resolv_nameserver_line=""
    local resolved_line=""
    local resolv_tokens=()
    local resolved_tokens=()

    while IFS= read -r line; do
        [ -n "$line" ] || continue
        token="${line%%#*}"
        token="${token//[[:space:]]/}"
        [ -n "$token" ] || continue
        [[ " ${resolv_tokens[*]} " == *" ${token} "* ]] || resolv_tokens+=("$token")
    done < <(awk '/^[[:space:]]*nameserver[[:space:]]+/ {print $2}' /etc/resolv.conf 2>/dev/null)
    resolv_nameserver_line="${resolv_tokens[*]}"

    if command -v resolvectl >/dev/null 2>&1 && resolvectl status >/dev/null 2>&1; then
        while IFS= read -r line; do
            for token in $line; do
                token="${token%%#*}"
                token="${token%,}"
                token="${token%%\%*}"
                [ -n "$token" ] || continue
                [[ " ${resolved_tokens[*]} " == *" ${token} "* ]] || resolved_tokens+=("$token")
            done
        done < <(resolvectl dns 2>/dev/null | sed -n 's/^.*: //p')
        resolved_line="${resolved_tokens[*]}"
    fi

    echo ""
    printf "  ${BOLD}当前 DNS 配置${PLAIN}\n"
    if [ -n "$resolv_nameserver_line" ]; then
        _status_kv "/etc/resolv.conf" "$resolv_nameserver_line" "cyan" 17
    else
        _status_kv "/etc/resolv.conf" "未检测到 nameserver" "yellow" 17
    fi
    if [ -n "$resolved_line" ]; then
        _status_kv "systemd-resolved" "$resolved_line" "cyan" 17
    fi
}

_dns_verify_resolution() {
    local test_domain="cloudflare.com"
    local out server answer

    _dns_ensure_lookup_tool || true
    printf "  ${BOLD}解析验证${PLAIN}\n"
    _info "正在使用系统默认解析器验证 DNS..."

    if command -v dig >/dev/null 2>&1; then
        out=$(dig +time=3 +tries=1 "$test_domain" 2>/dev/null || true)
        server=$(echo "$out" | awk -F': ' '/^;; SERVER:/{print $2; exit}')
        answer=$(echo "$out" | awk '/^[^;].*[[:space:]]IN[[:space:]]A[[:space:]]/ {print $5; exit}')
        if [ -n "$server" ]; then
            _status_kv "dig SERVER" "$server" "cyan" 17
        fi
        if [ -n "$answer" ]; then
            _success "dig 解析成功: ${test_domain} -> ${answer}"
            return 0
        fi
        _warn "dig 未返回 A 记录，继续尝试 nslookup..."
    fi

    if command -v nslookup >/dev/null 2>&1; then
        out=$(nslookup "$test_domain" 2>/dev/null || true)
        server=$(echo "$out" | awk '/^Server:/{print $2; exit}')
        answer=$(echo "$out" | awk '/^Address: /{print $2}' | tail -1)
        if [ -n "$server" ]; then
            _status_kv "nslookup" "$server" "cyan" 17
        fi
        if [ -n "$answer" ]; then
            _success "nslookup 解析成功: ${test_domain} -> ${answer}"
            return 0
        fi
    fi

    _warn "DNS 验证未返回有效结果，请检查网络连通性或手动执行 dig/nslookup 复核。"
    return 1
}

_dns_benchmark_query_time() {
    local server="$1"
    local domain="$2"
    local out status query_time

    out=$(dig "@${server}" "${domain}" A +time=2 +tries=1 2>/dev/null || true)
    status=$(echo "$out" | awk -F'status: ' '/status:/{print $2; exit}' | cut -d',' -f1)
    query_time=$(echo "$out" | awk '/Query time:/{print $4; exit}')

    if [ "$status" = "NOERROR" ] && _is_digit "${query_time:-}"; then
        printf '%s' "$query_time"
        return 0
    fi

    printf '%s' "timeout"
    return 1
}

_dns_benchmark_show_ms() {
    local ms="$1"
    if _is_digit "$ms"; then
        printf "%s ms" "$ms"
    else
        printf "timeout"
    fi
}

_dns_benchmark_print_group_table() {
    local title="$1"
    local test_domain="$2"
    shift 2
    local entries=("$@")
    local tmp_file entry name server query_time ecs_flag score
    local ms_show ecs_show

    tmp_file=$(mktemp)

    echo ""
    printf "  ${BOLD}[ %s ]${PLAIN}\n" "$title"
    printf "    测试域名: ${CYAN}%s${PLAIN}\n" "$test_domain"
    _separator
    printf "    %-16s %-16s %-12s %-8s\n" "DNS" "地址" "延迟" "ECS"

    for entry in "${entries[@]}"; do
        name="${entry%%|*}"
        server="${entry#*|}"
        server="${server%%|*}"
        ecs_flag="${entry##*|}"
        query_time=$(_dns_benchmark_query_time "$server" "$test_domain")
        if _is_digit "$query_time"; then
            score="$query_time"
        else
            score="99999"
        fi
        printf '%s|%s|%s|%s|%s\n' "$score" "$name" "$server" "$query_time" "$ecs_flag" >> "$tmp_file"
    done

    while IFS='|' read -r score name server query_time ecs_flag; do
        ms_show=$(_dns_benchmark_show_ms "$query_time")
        if [ "$ecs_flag" = "yes" ]; then
            ecs_show="支持"
        else
            ecs_show="-"
        fi
        printf "    %-16s %-16s %-12s %-8s\n" "$name" "$server" "$ms_show" "$ecs_show"
    done < <(sort -t'|' -k1,1n -k2,2 "$tmp_file")

    rm -f "$tmp_file"
}

_dns_benchmark_mainstream() {
    local cn_dns=(
        "AliDNS|223.5.5.5|yes"
        "AliDNS-2|223.6.6.6|yes"
        "DNSPod|119.29.29.29|yes"
        "114DNS|114.114.114.114|no"
        "114DNS-2|114.114.115.115|no"
        "BaiduDNS|180.76.76.76|no"
    )

    local global_dns=(
        "Google|8.8.8.8|yes"
        "Google-2|8.8.4.4|yes"
        "Cloudflare|1.1.1.1|no"
        "Cloudflare-2|1.0.0.1|no"
        "Quad9|9.9.9.9|no"
        "OpenDNS|208.67.222.222|no"
        "AdGuard|94.140.14.14|no"
    )

    local ecs_dns=(
        "AliDNS-ECS|223.5.5.5|yes"
        "AliDNS-ECS2|223.6.6.6|yes"
        "DNSPod-ECS|119.29.29.29|yes"
        "Google-ECS|8.8.8.8|yes"
        "Google-ECS2|8.8.4.4|yes"
    )

    echo ""
    _info "DNS 测速基于 dig 请求延迟（单位 ms）"
    _warn "结果受线路、运营商缓存、网络波动影响，建议多测几次取平均。"

    _dns_ensure_lookup_tool || true
    if ! command -v dig >/dev/null 2>&1; then
        _error_no_exit "测速依赖 dig，当前环境不可用，请先安装后重试。"
        _press_any_key
        return
    fi

    while true; do
        printf "  ${BOLD}请选择测速分组${PLAIN}\n"
        _separator
        _menu_pair "1" "国内 DNS 组" "测试域名: qq.com" "green" "2" "国外 DNS 组" "测试域名: google.com" "green"
        _menu_pair "3" "ECS DNS 组" "常见支持 ECS 的 DNS" "green" "0" "返回上一层" "" "red"
        _separator

        local group_choice
        read -rp "  选择 [0-3]: " group_choice
        case "$group_choice" in
            1)
                _dns_benchmark_print_group_table "国内 DNS 组测速（ECS 标记）" "qq.com" "${cn_dns[@]}"
                _press_any_key
                return
                ;;
            2)
                _dns_benchmark_print_group_table "国外 DNS 组测速（ECS 标记，含 9.9.9.9）" "google.com" "${global_dns[@]}"
                _press_any_key
                return
                ;;
            3)
                _dns_benchmark_print_group_table "ECS DNS 组测速（qq.com）" "qq.com" "${ecs_dns[@]}"
                _dns_benchmark_print_group_table "ECS DNS 组测速（google.com）" "google.com" "${ecs_dns[@]}"
                _press_any_key
                return
                ;;
            0) return ;;
            *) _error_no_exit "无效选项: ${group_choice}"; sleep 1 ;;
        esac
    done
}

_dns_change_flow() {
    local mode="$1"
    local dns_input clear_existing

    echo ""
    read -rp "  是否清除现有 DNS，仅保留你输入的新 DNS? [Y/n]: " clear_existing
    echo ""
    read -rp "  请输入 DNS（空格/逗号分隔，如 1.1.1.1,8.8.8.8）: " dns_input
    if ! _dns_parse_servers "$dns_input"; then
        _press_any_key
        return
    fi

    _DNS_CLEAR_EXISTING=1
    if [[ "$clear_existing" =~ ^([Nn]|[Nn][Oo])$ ]]; then
        _DNS_CLEAR_EXISTING=0
        _dns_merge_existing_servers
    fi

    printf "  ${BOLD}应用计划${PLAIN}\n"
    _status_kv "模式" "$([ "$mode" = "temporary" ] && echo "临时修改" || echo "永久修改")" "cyan" 10
    _status_kv "DNS" "${_DNS_SERVERS[*]}" "cyan" 10
    printf "\n  ${BOLD}执行过程${PLAIN}\n"
    if [ "$mode" = "temporary" ]; then
        _dns_apply_temporary || true
    else
        _dns_apply_permanent || true
    fi

    _dns_show_current_config
    printf "\n"
    _dns_verify_resolution || true
    _press_any_key
}

_dns_manage() {
    while true; do
        _header "Linux DNS 管理"
        _dns_show_current_config

        printf "  ${BOLD}请选择操作${PLAIN}\n"
        _separator
        _menu_pair "1" "临时修改 DNS" "重启后可能失效" "green" "2" "永久修改 DNS" "持久化并重启组件" "green"
        _menu_pair "3" "仅验证当前 DNS" "dig/nslookup 测试" "green" "4" "主流 DNS 测速" "国内/国外/ECS 分组" "green"
        _menu_item "0" "返回主菜单" "" "red"
        _separator

        local choice
        read -rp "  选择 [0-4]: " choice
        case "$choice" in
            1) _dns_change_flow "temporary" ;;
            2) _dns_change_flow "permanent" ;;
            3)
                echo ""
                _dns_verify_resolution || true
                _press_any_key
                ;;
            4) _dns_benchmark_mainstream ;;
            0) return ;;
            *) _error_no_exit "无效选项: ${choice}"; sleep 1 ;;
        esac
    done
}

# --- 16. Swap 管理 ---

_swap_human_readable() {
    local bytes=$1
    if [ "$bytes" -ge $((1024 * 1024 * 1024)) ]; then
        awk -v b="$bytes" 'BEGIN{ printf "%.1f GiB", b/1024/1024/1024 }'
    else
        awk -v b="$bytes" 'BEGIN{ printf "%.0f MiB", b/1024/1024 }'
    fi
}

_swap_setup() {
    _header "Swap 管理"

    # ---- 检测物理内存 ----
    local mem_total_kb mem_total_bytes mem_total_display
    mem_total_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
    mem_total_bytes=$((mem_total_kb * 1024))
    mem_total_display=$(_swap_human_readable "$mem_total_bytes")

    # ---- 检测现有 Swap ----
    local swap_total_kb swap_total_bytes swap_total_display
    swap_total_kb=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo)
    swap_total_bytes=$((swap_total_kb * 1024))
    swap_total_display=$(_swap_human_readable "$swap_total_bytes")

    # ---- 检测硬盘剩余空间 ----
    local disk_avail_kb disk_avail_bytes disk_avail_display
    disk_avail_kb=$(df -k / | awk 'NR==2{print $4}')
    disk_avail_bytes=$((disk_avail_kb * 1024))
    disk_avail_display=$(_swap_human_readable "$disk_avail_bytes")

    # ---- 计算推荐 Swap 大小 (MiB) ----
    local mem_mib=$((mem_total_kb / 1024))
    local recommend_mib
    if [ "$mem_mib" -le 1024 ]; then
        recommend_mib=$((mem_mib * 2))
    elif [ "$mem_mib" -le 4096 ]; then
        recommend_mib=$mem_mib
    else
        recommend_mib=4096
    fi

    # 确保推荐值不超过磁盘可用空间的 80%
    local disk_limit_mib=$((disk_avail_kb / 1024 * 80 / 100))
    if [ "$recommend_mib" -gt "$disk_limit_mib" ]; then
        recommend_mib=$disk_limit_mib
    fi

    # 扣除已有 swap
    local existing_swap_mib=$((swap_total_kb / 1024))
    local recommend_new_mib=$((recommend_mib - existing_swap_mib))
    if [ "$recommend_new_mib" -lt 0 ]; then
        recommend_new_mib=0
    fi

    # ---- 展示信息 ----
    echo ""
    printf "  ${BOLD}[ 当前状态 ]${PLAIN}\n"
    printf "    物理内存:         ${CYAN}%s${PLAIN}\n" "$mem_total_display"
    printf "    现有 Swap:        ${CYAN}%s${PLAIN}\n" "$swap_total_display"
    printf "    硬盘剩余空间:     ${CYAN}%s${PLAIN}\n" "$disk_avail_display"
    printf "    推荐总 Swap:      ${CYAN}%s MiB${PLAIN}\n" "$recommend_mib"
    echo ""
    _separator

    if [ "$recommend_new_mib" -le 64 ]; then
        _info "当前 Swap (${existing_swap_mib} MiB) 已达到推荐值 (${recommend_mib} MiB)"
        _separator
        _menu_pair "1" "仍要创建/扩展 Swap" "" "green" "2" "删除现有 /swapfile" "" "red"
        _menu_item "0" "返回主菜单" "" "red"
        _separator
        local sub_choice
        read -rp "  选择: " sub_choice
        case "$sub_choice" in
            1) ;;
            2)
                if [ -f /swapfile ]; then
                    swapoff /swapfile 2>/dev/null
                    rm -f /swapfile
                    sed -i '\|/swapfile|d' /etc/fstab
                    _info "已删除 /swapfile 并移除 fstab 条目"
                    echo ""
                    local reboot_confirm
                    read -rp "  是否立即重启系统? [y/N]: " reboot_confirm
                    if [[ "$reboot_confirm" =~ ^[Yy] ]]; then
                        _info "系统将在 3 秒后重启..."
                        sleep 3
                        reboot
                    fi
                else
                    _warn "未找到 /swapfile"
                fi
                _press_any_key
                return
                ;;
            *) return ;;
        esac
        recommend_new_mib=$recommend_mib
    fi

    printf "  ${BOLD}[ 推荐新建 Swap ]${PLAIN}\n"
    printf "    推荐大小: ${GREEN}%s MiB${PLAIN}\n" "$recommend_new_mib"
    echo ""

    local swap_input swap_size_mib
    read -rp "  请输入要创建的 Swap 大小 (MiB) [默认 ${recommend_new_mib}]: " swap_input
    swap_size_mib="${swap_input:-$recommend_new_mib}"

    # 校验输入
    if ! _is_digit "$swap_size_mib" || [ "$swap_size_mib" -le 0 ]; then
        _error_no_exit "无效的大小: ${swap_size_mib}"
        _press_any_key
        return
    fi

    # 检查是否超过磁盘可用空间的 90%
    local max_allowed_mib=$((disk_avail_kb / 1024 * 90 / 100))
    if [ "$swap_size_mib" -gt "$max_allowed_mib" ]; then
        _error_no_exit "所选大小 (${swap_size_mib} MiB) 超过硬盘可用空间的 90% (${max_allowed_mib} MiB)"
        _press_any_key
        return
    fi

    # ---- 确认 ----
    echo ""
    _warn "将在 /swapfile 创建 ${swap_size_mib} MiB 的 Swap"
    local confirm
    read -rp "  确认? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy] ]]; then
        _info "已取消"
        _press_any_key
        return
    fi

    # ---- 如果已有 /swapfile，先关闭 ----
    if [ -f /swapfile ]; then
        _info "检测到已有 /swapfile，正在关闭..."
        swapoff /swapfile 2>/dev/null
        rm -f /swapfile
    fi

    # ---- 创建 Swap ----
    echo ""
    _info "正在创建 ${swap_size_mib} MiB 的 Swap 文件..."
    if command -v fallocate >/dev/null 2>&1; then
        fallocate -l "${swap_size_mib}M" /swapfile
    else
        dd if=/dev/zero of=/swapfile bs=1M count="$swap_size_mib" status=progress
    fi

    if [ $? -ne 0 ]; then
        _error_no_exit "Swap 文件创建失败"
        rm -f /swapfile
        _press_any_key
        return
    fi

    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile

    if [ $? -ne 0 ]; then
        _error_no_exit "Swap 启用失败"
        rm -f /swapfile
        _press_any_key
        return
    fi

    # ---- 写入 fstab 实现开机自动挂载 ----
    sed -i '\|/swapfile|d' /etc/fstab
    echo '/swapfile none swap sw 0 0' >> /etc/fstab

    # ---- 显示结果 ----
    echo ""
    _header "Swap 创建完成"
    echo ""
    local new_swap_kb new_swap_display
    new_swap_kb=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo)
    new_swap_display=$(_swap_human_readable "$((new_swap_kb * 1024))")
    printf "  ${BOLD}当前 Swap:${PLAIN} ${GREEN}%s${PLAIN}\n" "$new_swap_display"
    _info "已写入 /etc/fstab，重启后自动生效"

    echo ""
    local reboot_confirm
    read -rp "  是否立即重启系统? [y/N]: " reboot_confirm
    if [[ "$reboot_confirm" =~ ^[Yy] ]]; then
        _info "系统将在 3 秒后重启..."
        sleep 3
        reboot
    fi

    _press_any_key
}

# --- Root SSH 启用 ---

_rootssh_pick_source_user() {
    local user="${SUDO_USER:-}"
    if [ -n "$user" ] && [ "$user" != "root" ]; then
        printf '%s' "$user"
        return
    fi
    awk -F: '$3 >= 1000 && $1 != "nobody" && $7 !~ /(nologin|false)/ {print $1; exit}' /etc/passwd
}

_rootssh_set_sshd_option() {
    local file="$1" key="$2" value="$3"
    if grep -Eq "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]+" "$file"; then
        sed -i -E "s|^[[:space:]]*#?[[:space:]]*${key}[[:space:]].*|${key} ${value}|g" "$file"
    else
        printf '\n%s %s\n' "$key" "$value" >> "$file"
    fi
}

_rootssh_write_override_conf() {
    local d="/etc/ssh/sshd_config.d"
    local f="${d}/00-vpsgo-root-login.conf"
    mkdir -p "$d"
    cat > "$f" <<'EOF'
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
EOF
    chmod 644 "$f"
}

_rootssh_cleanup_forced_command_keys() {
    local f="/root/.ssh/authorized_keys"
    [ -f "$f" ] || return 0
    local bak="${f}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$f" "$bak"
    awk '
        /Please login as the user/ { next }
        /rather than the user "root"/ { next }
        { print }
    ' "$bak" > "${f}.tmp.$$"
    install -m 600 "${f}.tmp.$$" "$f"
    rm -f "${f}.tmp.$$"
    chown root:root "$f"
    if ! cmp -s "$bak" "$f"; then
        _info "已清理 root authorized_keys 中的云厂商限制条目"
    fi
}

_rootssh_copy_key_if_exists() {
    local src_user="$1"
    local src_home src_key
    src_home=$(getent passwd "$src_user" 2>/dev/null | awk -F: '{print $6}')
    [ -z "$src_home" ] && src_home="/home/${src_user}"
    src_key="${src_home}/.ssh/authorized_keys"
    local dst_dir="/root/.ssh"
    local dst_key="${dst_dir}/authorized_keys"

    if [ -z "$src_user" ] || [ "$src_user" = "root" ]; then
        _warn "未找到可复制密钥的普通用户，已跳过密钥复制"
        return 0
    fi
    if [ ! -s "$src_key" ]; then
        _warn "未找到 ${src_key}，已跳过密钥复制"
        return 0
    fi

    mkdir -p "$dst_dir"
    chmod 700 "$dst_dir"
    touch "$dst_key"
    chmod 600 "$dst_key"

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        grep -Fqx "$line" "$dst_key" || echo "$line" >> "$dst_key"
    done < "$src_key"

    chown -R root:root "$dst_dir"
    _success "已复制密钥: ${src_key} -> ${dst_key}"
}

_ssh_authorized_keys_has_entries() {
    local f="$1"
    [ -s "$f" ] || return 1
    awk '
        /^[[:space:]]*$/ { next }
        /^[[:space:]]*#/ { next }
        { found=1; exit }
        END { exit(found ? 0 : 1) }
    ' "$f"
}

_ssh_keyonly_has_any_key() {
    local key_file user uid home shell
    if _ssh_authorized_keys_has_entries "/root/.ssh/authorized_keys"; then
        return 0
    fi
    while IFS=: read -r user _ uid _ _ home shell; do
        [[ "${uid:-}" =~ ^[0-9]+$ ]] || continue
        (( uid >= 1000 )) || continue
        [[ "$user" == "nobody" ]] && continue
        [[ "${shell:-}" =~ (nologin|false)$ ]] && continue
        key_file="${home}/.ssh/authorized_keys"
        if _ssh_authorized_keys_has_entries "$key_file"; then
            return 0
        fi
    done < /etc/passwd
    return 1
}

_ssh_keyonly_write_override_conf() {
    local d="/etc/ssh/sshd_config.d"
    local f="${d}/99-vpsgo-key-only.conf"
    mkdir -p "$d"
    cat > "$f" <<'EOF'
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
AuthenticationMethods publickey
EOF
    chmod 644 "$f"
}

_rootssh_enable() {
    _header "启用 Root SSH 登录"
    _warn "将执行: 设置 root 密码、允许 root SSH、复制现有公钥"

    local confirm
    read -rp "  确认继续? [Y/n]: " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        _info "已取消"
        _press_any_key
        return
    fi

    echo ""
    _info "步骤 1/3: 设置 root 密码 (passwd root)"
    if ! passwd root; then
        _error_no_exit "root 密码设置失败"
        _press_any_key
        return
    fi

    echo ""
    _info "步骤 2/3: 修改 SSH 配置，允许 root 登录"
    local sshd_cfg="/etc/ssh/sshd_config"
    if [ ! -f "$sshd_cfg" ]; then
        _error_no_exit "未找到 ${sshd_cfg}"
        _press_any_key
        return
    fi
    local backup="${sshd_cfg}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$sshd_cfg" "$backup"
    _info "已备份 SSH 配置: ${backup}"

    _rootssh_set_sshd_option "$sshd_cfg" "PermitRootLogin" "yes"
    _rootssh_set_sshd_option "$sshd_cfg" "PasswordAuthentication" "yes"
    _rootssh_set_sshd_option "$sshd_cfg" "PubkeyAuthentication" "yes"
    _rootssh_write_override_conf

    if command -v sshd >/dev/null 2>&1; then
        if ! sshd -t -f "$sshd_cfg" >/dev/null 2>&1; then
            _error_no_exit "sshd 配置校验失败，已保留备份: ${backup}"
            _press_any_key
            return
        fi
    fi

    if ! _restart_first_available_service ssh sshd; then
        _warn "未检测到可重启的 ssh/sshd 服务，请手动重启 SSH 服务"
    fi

    echo ""
    _info "步骤 3/3: 复制现有用户公钥到 root"
    local src_user
    src_user="$(_rootssh_pick_source_user)"
    _rootssh_copy_key_if_exists "$src_user"
    _rootssh_cleanup_forced_command_keys

    echo ""
    _success "root SSH 登录配置完成"
    _warn "请在新终端先测试 root 登录成功后，再关闭当前会话"
    _press_any_key
}

_ssh_force_key_login() {
    _header "强制 SSH 密钥登录"
    _warn "将执行: 禁用 SSH 密码登录，仅允许证书/密钥登录"

    local confirm
    read -rp "  确认继续? [Y/n]: " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        _info "已取消"
        _press_any_key
        return
    fi

    if ! _ssh_keyonly_has_any_key; then
        _error_no_exit "未检测到可用 authorized_keys，已取消操作以避免 SSH 锁死"
        _press_any_key
        return
    fi

    echo ""
    _info "步骤 1/2: 修改 SSH 配置，禁用密码登录"
    local sshd_cfg="/etc/ssh/sshd_config"
    if [ ! -f "$sshd_cfg" ]; then
        _error_no_exit "未找到 ${sshd_cfg}"
        _press_any_key
        return
    fi
    local backup="${sshd_cfg}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$sshd_cfg" "$backup"
    _info "已备份 SSH 配置: ${backup}"

    _rootssh_set_sshd_option "$sshd_cfg" "PubkeyAuthentication" "yes"
    _rootssh_set_sshd_option "$sshd_cfg" "PasswordAuthentication" "no"
    _rootssh_set_sshd_option "$sshd_cfg" "KbdInteractiveAuthentication" "no"
    _rootssh_set_sshd_option "$sshd_cfg" "ChallengeResponseAuthentication" "no"
    _ssh_keyonly_write_override_conf

    if command -v sshd >/dev/null 2>&1; then
        if ! sshd -t -f "$sshd_cfg" >/dev/null 2>&1; then
            _error_no_exit "sshd 配置校验失败，已保留备份: ${backup}"
            _press_any_key
            return
        fi
    fi

    echo ""
    _info "步骤 2/2: 重启 SSH 服务并应用配置"
    if ! _restart_first_available_service ssh sshd; then
        _warn "未检测到可重启的 ssh/sshd 服务，请手动重启 SSH 服务"
    fi

    echo ""
    _success "SSH 已强制为密钥登录"
    _warn "密码登录已禁用，请先在新终端验证密钥登录成功后，再关闭当前会话"
    _press_any_key
}

# --- 自更新 ---

_self_update() {
    _header "VPSGo 更新"

    if ! command -v curl >/dev/null 2>&1; then
        _error_no_exit "需要 curl 命令"
        _press_any_key
        return
    fi

    _info "当前版本: v${VERSION}"
    _info "正在检查更新..."

    local tmp_file
    tmp_file=$(mktemp /tmp/vpsgo.XXXXXX.sh)
    if ! curl -fsSL -o "$tmp_file" "$UPDATE_URL"; then
        rm -f "$tmp_file"
        _error_no_exit "下载失败，请检查网络连接"
        _press_any_key
        return
    fi

    if [[ ! -s "$tmp_file" ]]; then
        rm -f "$tmp_file"
        _error_no_exit "下载文件为空"
        _press_any_key
        return
    fi

    if [[ -d "$INSTALL_PATH" ]]; then
        rm -f "$tmp_file"
        _error_no_exit "${INSTALL_PATH} 是目录，无法写入可执行文件"
        _press_any_key
        return
    fi

    local remote_ver
    remote_ver=$(grep '^VERSION=' "$tmp_file" | head -1 | sed 's/VERSION=//;s/[\"'"'"']//g')

    if [[ -z "$remote_ver" ]]; then
        _error_no_exit "无法解析远程版本号"
        rm -f "$tmp_file"
        _press_any_key
        return
    else
        _info "最新版本: v${remote_ver}"
        if [[ "$remote_ver" == "$VERSION" ]]; then
            _info "已是最新版本，无需更新"
            rm -f "$tmp_file"
            _press_any_key
            return
        fi
    fi

    if ! _install_script_file "$tmp_file" "$INSTALL_PATH"; then
        rm -f "$tmp_file"
        _error_no_exit "更新失败，无法写入 ${INSTALL_PATH}"
        _warn "请检查目录权限或挂载参数（如 noexec），或改用 VPSGO_INSTALL_PATH 指定其他路径"
        _press_any_key
        return
    fi

    if ! _ensure_script_mode_ok "$INSTALL_PATH"; then
        rm -f "$tmp_file"
        _error_no_exit "更新失败，${INSTALL_PATH} 权限异常"
        _warn "请手动执行: chmod 0755 ${INSTALL_PATH}"
        _press_any_key
        return
    fi

    rm -f "$tmp_file"

    _info "更新完成! v${VERSION} -> v${remote_ver}"
    _info "正在重新启动..."
    echo ""
    exec "$INSTALL_PATH" "$@"
}

# --- 自安装 ---

_self_install() {
    local self
    self="$(readlink -f "$0" 2>/dev/null || echo "$0")"

    if [[ -d "$INSTALL_PATH" ]]; then
        _warn "${INSTALL_PATH} 是目录，无法作为命令使用，请先删除该目录后重试"
        return
    fi

    # 如果已经是从 INSTALL_PATH 运行的，跳过
    if [[ "$(readlink -f "$INSTALL_PATH" 2>/dev/null)" == "$self" ]] || \
       [[ "$self" == "$INSTALL_PATH" ]]; then
        if ! _ensure_script_mode_ok "$INSTALL_PATH"; then
            _warn "检测到 ${INSTALL_PATH} 权限异常，请执行: chmod 0755 ${INSTALL_PATH}"
        fi
        return
    fi

    # 检查源文件是否可读（防止管道运行时 $0 不可用）
    if [[ ! -f "$self" ]] || [[ ! -r "$self" ]]; then
        return
    fi

    # 如果目标不存在，或者源文件更新了，则安装/更新
    if [[ ! -f "$INSTALL_PATH" ]]; then
        if _install_script_file "$self" "$INSTALL_PATH"; then
            _info "已安装到 ${INSTALL_PATH}，后续可直接输入 vpsgo 启动"
        else
            _warn "安装 ${INSTALL_PATH} 失败，可设置 VPSGO_INSTALL_PATH 指定其他可执行目录"
        fi
    elif [[ "$self" -nt "$INSTALL_PATH" ]] || ! cmp -s "$self" "$INSTALL_PATH"; then
        if _install_script_file "$self" "$INSTALL_PATH"; then
            _info "已更新 ${INSTALL_PATH}"
        else
            _warn "更新 ${INSTALL_PATH} 失败，可设置 VPSGO_INSTALL_PATH 指定其他可执行目录"
        fi
    elif ! _ensure_script_mode_ok "$INSTALL_PATH"; then
        _warn "检测到 ${INSTALL_PATH} 权限异常，请执行: chmod 0755 ${INSTALL_PATH}"
    fi
}

# --- 卸载 ---

_self_uninstall() {
    _header "VPSGo 卸载"

    if [[ ! -f "$INSTALL_PATH" ]]; then
        _info "VPSGo 未安装，无需卸载"
        _press_any_key
        return
    fi

    _warn "即将删除 ${INSTALL_PATH}"
    local confirm
    read -rp "  确认卸载? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy] ]]; then
        _info "已取消"
        _press_any_key
        return
    fi

    rm -f "$INSTALL_PATH"
    _info "VPSGo 已卸载，vpsgo 命令不再可用"
    echo ""
    exit 0
}

# --- 主菜单 ---

_show_banner() {
    local cols line_w line
    cols=$(_ui_term_cols)
    line_w=$((cols - 8))
    [ "$line_w" -lt 24 ] && line_w=24
    [ "$line_w" -gt 72 ] && line_w=72
    line=$(_ui_repeat_char "═" "$line_w")

    _ui_clear_screen
    printf "${CYAN}%s${PLAIN}\n" "$line"
    printf "${CYAN}"
    cat << 'BANNER'
 __     __  ____    ____     ____    ___  
 \ \   / / |  _ \  / ___|   / ___|  / _ \ 
  \ \ / /  | |_) | \___ \  | |  _  | | | |
   \ V /   |  __/   ___) | | |_| | | |_| |
    \_/    |_|     |____/   \____|  \___/ 
BANNER
    printf "${PLAIN}"
    printf "  ${DIM}   VPS 一站式管理脚本${PLAIN} ${BOLD}v%s${PLAIN}\n" "$VERSION"
    printf "${CYAN}%s${PLAIN}\n" "$line"
}

_show_main_menu() {
    _show_sys_info
    printf "  ${BOLD}[ 分类菜单 ]${PLAIN}\n"
    _separator
    _menu_item "1" "网络优化" "BBR/网卡调度/双栈选择/调优" "green"
    _menu_item "2" "脚本工具" "iPerf3/NodeQuality/DNS" "green"
    _menu_item "3" "系统优化" "日志轮转/Swap" "green"
    _menu_item "4" "代理工具助手" "Mihomo/Sing-Box/SSR/WireGuard" "green"
    _separator
    _menu_item "u" "更新 VPSGo" "从 Github 更新" "cyan"
    _menu_item "x" "卸载 VPSGo" "" "red"
    _menu_item "0" "退出脚本" "" "red"
    _separator
}

_network_opt_menu() {
    while true; do
        _header "网络优化"
        _menu_pair "1" "开启 BBR" "启用/诊断 BBR" "green" "2" "队列调度算法" "fq/cake/fq_pie" "green"
        _menu_pair "3" "IPv4/IPv6 优先级" "出口协议栈偏好" "green" "4" "TCP 缓冲区调优" "网络栈参数优化" "green"
        _separator
        _menu_item "0" "返回主菜单" "" "red"
        _separator
        local ch
        read -rp "  选择 [0-4]: " ch
        case "$ch" in
            1) _bbr_install ;;
            2) _qdisc_setup ;;
            3) _v4v6_setup ;;
            4) _tcptune_setup ;;
            0) return ;;
            *) _error_no_exit "无效选项: ${ch}"; sleep 1 ;;
        esac
    done
}

_script_tools_menu() {
    while true; do
        _header "脚本工具"
        _menu_pair "1" "iPerf3 测速服务端" "临时启动" "green" "2" "NodeQuality 测试" "VPS 综合测试" "green"
        _menu_pair "3" "Akile DNS 解锁检测" "媒体解锁测速" "green" "4" "Linux DNS 管理" "临时/永久 DNS" "green"
        _separator
        _menu_item "0" "返回主菜单" "" "red"
        _separator
        local ch
        read -rp "  选择 [0-4]: " ch
        case "$ch" in
            1) _iperf3_setup ;;
            2) _nodequality_setup ;;
            3) _akdns_setup ;;
            4) _dns_manage ;;
            0) return ;;
            *) _error_no_exit "无效选项: ${ch}"; sleep 1 ;;
        esac
    done
}

_system_opt_menu() {
    while true; do
        _header "系统优化"
        _menu_pair "1" "日志轮转" "限制容器日志" "green" "2" "Swap 管理" "修改虚拟内存" "green"
        _menu_pair "3" "启用 root SSH 登录" "设密/放行/复制密钥" "green" "4" "强制 SSH 密钥登录" "禁用密码登录" "green"
        _separator
        _menu_item "0" "返回主菜单" "" "red"
        _separator
        local ch
        read -rp "  选择 [0-4]: " ch
        case "$ch" in
            1) _dockerlog_setup ;;
            2) _swap_setup ;;
            3) _rootssh_enable ;;
            4) _ssh_force_key_login ;;
            0) return ;;
            *) _error_no_exit "无效选项: ${ch}"; sleep 1 ;;
        esac
    done
}

_proxy_tools_menu() {
    while true; do
        _header "代理工具助手"
        _menu_pair "1" "Mihomo 管理" "安装/配置/重启/卸载" "green" "2" "Sing-Box 管理" "安装/自启/重启/卸载" "green"
        _menu_pair "3" "Snell V5 管理" "官方安装/配置/冲突检查" "green" "4" "WireGuard 原生节点" "部署/重启/状态/卸载" "green"
        _menu_pair "5" "Shadowsocks-Rust 管理" "LXC/容器友好" "green" "6" "ACME 证书管理" "acme.sh/80端口/DNS签发" "green"
        _menu_item "0" "返回主菜单" "" "red"
        _separator
        local ch
        read -rp "  选择 [0-6]: " ch
        case "$ch" in
            1) _mihomo_manage ;;
            2) _singbox_manage ;;
            3) _snell_manage ;;
            4) _wireguard_manage ;;
            5) _ssrust_manage ;;
            6) _acme_manage ;;
            0) return ;;
            *) _error_no_exit "无效选项: ${ch}"; sleep 1 ;;
        esac
    done
}

main() {
    [[ $EUID -ne 0 ]] && _error "此脚本需要 root 权限，请使用 sudo vpsgo 运行"

    _self_install

    while true; do
        _show_banner
        _show_main_menu

        local choice
        read -rp "  选择: " choice

        case "$choice" in
            1) _network_opt_menu ;;
            2) _script_tools_menu ;;
            3) _system_opt_menu ;;
            4) _proxy_tools_menu ;;
            u|U) _self_update ;;
            x|X) _self_uninstall ;;
            0)
                echo ""
                _info "感谢使用 VPSGo，再见!"
                echo ""
                exit 0
                ;;
            *)
                _error_no_exit "无效选项: ${choice}"
                sleep 1
                ;;
        esac
    done
}

main "$@"
