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
#   8. Mihomo 管理 (安装/配置/重启)
#   9. Sing-Box 管理 (安装/自启/重启/日志)
#  10. Akile DNS 解锁检测与配置
#  11. Linux DNS 管理 (临时/永久修改)
#  12. Swap 管理
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

VERSION="2.0"

# --- 全局变量 ---
SCRIPT_DIR="$(cd -P -- "$(dirname -- "$0")" && pwd -P)"
INSTALL_PATH="/usr/local/bin/vpsgo"
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
    [ -f "/etc/debian_version" ] && source /etc/os-release && os="${ID}" && printf '%s' "${os}" && return
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
        *)
            _error "不支持的操作系统"
            ;;
    esac
}

_bbr_sysctl_config() {
    [ -f /etc/sysctl.conf ] && sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    [ -f /etc/sysctl.conf ] && sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
    if ! sysctl -p >/dev/null 2>&1; then
        _warn "sysctl -p 执行失败，BBR 配置已写入但可能未立即生效"
        return 1
    fi
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
        if _bbr_sysctl_config; then
            _success "TCP BBR 启用成功!"
        else
            _warn "BBR 配置已写入 /etc/sysctl.conf，但需重启后生效"
        fi
        printf "\n  ${BOLD}变更后状态${PLAIN}\n"
        _status_kv "拥塞算法" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)" "green"
        _status_kv "队列算法" "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)" "green"
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
    local modules_file="/etc/modules-load.d/${qdisc}.conf"
    mkdir -p /etc/modules-load.d
    if [ ! -f "$modules_file" ] || ! grep -qx "$module" "$modules_file" 2>/dev/null; then
        printf '%s\n' "$module" >> "$modules_file"
    fi
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

_TCPTUNE_SYSCTL_TARGET="/etc/sysctl.d/999-net-tcp-tune.conf"
_TCPTUNE_KEY_REGEX='^(net[.]core[.]default_qdisc|net[.]core[.]rmem_max|net[.]core[.]wmem_max|net[.]ipv4[.]tcp_wmem|net[.]ipv4[.]tcp_rmem|net[.]ipv4[.]tcp_congestion_control|net[.]ipv4[.]tcp_window_scaling|net[.]ipv4[.]tcp_moderate_rcvbuf)[[:space:]]*='

_tcptune_is_num() {
    [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

_tcptune_is_int() {
    [[ "${1:-}" =~ ^[0-9]+$ ]]
}

_tcptune_default_iface() {
    ip -o -4 route show to default 2>/dev/null | awk '{print $5}' | head -1 || true
}

_tcptune_effective_qdisc() {
    local q
    q="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
    case "$q" in
        fq|cake) printf '%s' "$q" ;;
        *) printf 'fq' ;;
    esac
}

_tcptune_bytes_to_mib() {
    local bytes="${1:-0}"
    awk -v b="$bytes" 'BEGIN{ printf "%.2f", b/1024/1024 }'
}

_tcptune_comment_conflicts_in_sysctl_conf() {
    local f="/etc/sysctl.conf"
    [ -f "$f" ] || { _success "/etc/sysctl.conf 不存在"; return 0; }
    if grep -Eq "$_TCPTUNE_KEY_REGEX" "$f"; then
        _info "注释 /etc/sysctl.conf 中的冲突键"
        awk -v re="$_TCPTUNE_KEY_REGEX" '
            $0 ~ re && $0 !~ /^[[:space:]]*#/ { print "# " $0; next }
            { print $0 }
        ' "$f" > "${f}.tmp.$$"
        install -m 0644 "${f}.tmp.$$" "$f"
        rm -f "${f}.tmp.$$"
        _success "已注释掉冲突键"
    else
        _success "/etc/sysctl.conf 无冲突键"
    fi
}

_tcptune_delete_conflict_files_in_dir() {
    local dir="$1"
    local target="$2"
    [ -d "$dir" ] || { _success "$dir 不存在"; return 0; }
    shopt -s nullglob
    local f removed=0
    for f in "$dir"/*.conf; do
        if [ -n "$target" ] && [ "$(readlink -f "$f" 2>/dev/null)" = "$(readlink -f "$target" 2>/dev/null)" ]; then
            continue
        fi
        local base
        base="$(basename "$f")"
        # 只清理常见调优文件，避免误删云厂商/发行版自带 sysctl 文件
        if ! [[ "$base" =~ ^(99-(bbr|cake|fq|fq_pie|net|tcp).*[.]conf|999-net-.*[.]conf)$ ]]; then
            continue
        fi
        if grep -Eq "$_TCPTUNE_KEY_REGEX" "$f"; then
            rm -f -- "$f"
            _info "已删除冲突文件：$f"
            removed=1
        fi
    done
    shopt -u nullglob
    [ "$removed" -eq 1 ] && _success "$dir 中的冲突文件已删除" || _success "$dir 无需处理"
}

_tcptune_scan_conflicts_ro() {
    local dir="$1"
    [ -d "$dir" ] || { _success "$dir 不存在"; return 0; }
    if grep -RIlEq "$_TCPTUNE_KEY_REGEX" "$dir" 2>/dev/null; then
        _warn "发现潜在冲突（只提示不改）：$dir"
        grep -RhnE "$_TCPTUNE_KEY_REGEX" "$dir" 2>/dev/null || true
    else
        _success "$dir 未发现冲突"
    fi
}

_tcptune_cleanup_conflicts() {
    _info "步骤A：注释 /etc/sysctl.conf 冲突键"
    _tcptune_comment_conflicts_in_sysctl_conf
    _info "步骤B：删除 /etc/sysctl.d 下含冲突键的旧文件（不备份）"
    _tcptune_delete_conflict_files_in_dir "/etc/sysctl.d" "$_TCPTUNE_SYSCTL_TARGET"
    _info "步骤C：扫描其他目录（只读提示，不改）"
    _tcptune_scan_conflicts_ro "/usr/local/lib/sysctl.d"
    _tcptune_scan_conflicts_ro "/usr/lib/sysctl.d"
    _tcptune_scan_conflicts_ro "/lib/sysctl.d"
    _tcptune_scan_conflicts_ro "/run/sysctl.d"
}

_tcptune_apply_qdisc() {
    local qdisc="$1"
    local iface
    iface="$(_tcptune_default_iface)"
    if command -v tc >/dev/null 2>&1 && [ -n "${iface:-}" ]; then
        tc qdisc replace dev "$iface" root "$qdisc" 2>/dev/null || true
    fi
    printf '%s' "$iface"
}

_tcptune_write_profile() {
    local max_bytes="$1"
    local bw_mbps="$2"
    local rtt_ms="$3"
    local profile_tag="$4"
    local qdisc="$5"

    local tmpf
    tmpf="$(mktemp)"
    cat >"$tmpf" <<EOF_SYSCTL
# Auto-generated by VPSGo TCP Tune (${profile_tag})
# Bottleneck BW: ${bw_mbps} Mbps, RTT: ${rtt_ms} ms
# Max buffer: ${max_bytes} bytes (~$(_tcptune_bytes_to_mib "$max_bytes") MiB)

net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = ${qdisc}

net.core.rmem_max = ${max_bytes}
net.core.wmem_max = ${max_bytes}

net.ipv4.tcp_wmem = 4096 16384 ${max_bytes}
net.ipv4.tcp_rmem = 4096 87380 ${max_bytes}

net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_moderate_rcvbuf = 1
EOF_SYSCTL
    install -m 0644 "$tmpf" "$_TCPTUNE_SYSCTL_TARGET"
    rm -f "$tmpf"
    if ! sysctl -p "$_TCPTUNE_SYSCTL_TARGET" >/dev/null 2>&1; then
        _warn "应用 ${_TCPTUNE_SYSCTL_TARGET} 失败，请检查内核是否支持对应参数"
    fi
}

_tcptune_show_result() {
    local title="$1"
    local iface="$2"
    echo "==== ${title} ===="
    sysctl -n net.ipv4.tcp_congestion_control
    sysctl -n net.core.default_qdisc
    sysctl -n net.core.rmem_max
    sysctl -n net.core.wmem_max
    sysctl -n net.ipv4.tcp_wmem
    sysctl -n net.ipv4.tcp_rmem
    sysctl -n net.ipv4.tcp_window_scaling
    sysctl -n net.ipv4.tcp_moderate_rcvbuf
    if command -v tc >/dev/null 2>&1 && [ -n "${iface:-}" ]; then
        echo "qdisc on ${iface}:"
        tc qdisc show dev "$iface" || true
    fi
    echo "=================="
}

_tcptune_show_review() {
    _info "复核：查看加载顺序及最终值来源（只读）"
    grep -nE 'net[.]core[.](rmem_max|wmem_max|default_qdisc)|net[.]ipv4[.]tcp_(rmem|wmem|congestion_control|window_scaling|moderate_rcvbuf)' "$_TCPTUNE_SYSCTL_TARGET" 2>/dev/null || true
    sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true
    sysctl -n net.core.default_qdisc 2>/dev/null || true
    sysctl -n net.core.rmem_max 2>/dev/null || true
    sysctl -n net.core.wmem_max 2>/dev/null || true
    sysctl -n net.ipv4.tcp_wmem 2>/dev/null || true
    sysctl -n net.ipv4.tcp_rmem 2>/dev/null || true
}

_tcptune_mode_bdp() {
    _header "TCP 调优 - 方案一 (BDP 动态调优)"
    _warn "基于 BDP 给理论值，再按 iperf3 重传数做加减微调"

    local BW_Mbps_INPUT RTT_ms_INPUT BW_Mbps RTT_ms
    read -rp "  瓶颈带宽 (Mbps) [默认 1000]: " BW_Mbps_INPUT
    read -rp "  RTT (ms) [默认 150]: " RTT_ms_INPUT

    BW_Mbps="${BW_Mbps_INPUT:-1000}"
    RTT_ms="${RTT_ms_INPUT:-150}"
    _tcptune_is_int "$BW_Mbps" || BW_Mbps=1000
    _tcptune_is_num "$RTT_ms" || RTT_ms=150

    local BDP_BYTES
    BDP_BYTES=$(awk -v bw="$BW_Mbps" -v rtt="$RTT_ms" 'BEGIN{ printf "%.0f", bw*125*rtt }')
    local qdisc
    qdisc="$(_tcptune_effective_qdisc)"

    echo ""
    _info "理论 BDP: ${BDP_BYTES} bytes (~$(_tcptune_bytes_to_mib "$BDP_BYTES") MiB)"
    _info "沿用队列算法: ${qdisc}"

    _tcptune_cleanup_conflicts
    if command -v modprobe >/dev/null 2>&1; then
        modprobe tcp_bbr 2>/dev/null || true
        if [ "$qdisc" = "cake" ]; then
            modprobe sch_cake 2>/dev/null || true
        else
            modprobe sch_fq 2>/dev/null || true
        fi
    fi

    local current_max
    current_max="$BDP_BYTES"
    _tcptune_write_profile "$current_max" "$BW_Mbps" "$RTT_ms" "bdp" "$qdisc"

    local iface
    iface="$(_tcptune_apply_qdisc "$qdisc")"
    _tcptune_show_result "初始应用" "$iface"

    local tune_choice
    read -rp "  是否进入按 Retr 微调循环? [y/N]: " tune_choice
    if [[ "$tune_choice" =~ ^[Yy]$ ]]; then
        while true; do
            local retr delta action
            read -rp "  输入本轮 iperf3 Retr (q 退出): " retr
            case "$retr" in
                q|Q|"") break ;;
            esac
            if ! _tcptune_is_int "$retr"; then
                _warn "Retr 需为整数，已跳过"
                continue
            fi

            if [ "$retr" -eq 0 ]; then
                delta=$((3 * 1024 * 1024))
                action="上调 +3MiB"
            elif [ "$retr" -gt 100 ]; then
                delta=$((-2 * 1024 * 1024))
                action="下调 -2MiB"
            else
                delta=$((-1 * 1024 * 1024))
                action="轻降 -1MiB 保稳"
            fi

            current_max=$(( current_max + delta ))
            if [ "$current_max" -lt $((1 * 1024 * 1024)) ]; then
                current_max=$((1 * 1024 * 1024))
            fi

            _info "Retr=${retr} -> ${action}，新 max=$(_tcptune_bytes_to_mib "$current_max") MiB"
            _tcptune_write_profile "$current_max" "$BW_Mbps" "$RTT_ms" "bdp-tuning" "$qdisc"
            iface="$(_tcptune_apply_qdisc "$qdisc")"
            _tcptune_show_result "微调后" "$iface"
        done
    fi

    _tcptune_show_review
    _network_reboot_prompt
    _press_any_key
}

_tcptune_write_rc_local_tc() {
    local iface="$1"
    local rate="$2"
    local f="/etc/rc.local"
    local tmpf
    tmpf="$(mktemp)"

    if [ -f "$f" ]; then
        awk '
            BEGIN { skip=0 }
            /^# VPSGo TCP TC BEGIN$/ { skip=1; next }
            /^# VPSGo TCP TC END$/   { skip=0; next }
            skip == 0 {
                if ($0 ~ /^[[:space:]]*exit[[:space:]]+0[[:space:]]*$/) next
                print
            }
        ' "$f" > "$tmpf"
    else
        cat > "$tmpf" <<'EOF_RC_HEAD'
#!/bin/bash
# rc.local
EOF_RC_HEAD
    fi

    cat >> "$tmpf" <<EOF_RC
# VPSGo TCP TC BEGIN

tc qdisc del dev ${iface} root 2>/dev/null || true
tc qdisc add dev ${iface} root handle 1:0 htb default 10

# src 限速
tc class replace dev ${iface} parent 1:0 classid 1:1 htb rate ${rate}mbit ceil ${rate}mbit
tc filter replace dev ${iface} protocol ip parent 1:0 prio 1 u32 match ip src 0.0.0.0/0 flowid 1:1

# dst 限速
tc class replace dev ${iface} parent 1:0 classid 1:2 htb rate ${rate}mbit ceil ${rate}mbit
tc filter replace dev ${iface} protocol ip parent 1:0 prio 1 u32 match ip dst 0.0.0.0/0 flowid 1:2

# VPSGo TCP TC END

exit 0
EOF_RC

    install -m 0755 "$tmpf" "$f"
    rm -f "$tmpf"
}

_tcptune_mode_tc() {
    _header "TCP 调优 - 方案二 (TC 限速保稳)"
    _warn "用于高重传/抖动场景：大缓冲 + HTB 限速"

    local iface_default iface_input iface
    iface_default="$(_tcptune_default_iface)"
    read -rp "  网卡名 [默认 ${iface_default:-eth0}]: " iface_input
    iface="${iface_input:-${iface_default:-eth0}}"

    local BW_Mbps_INPUT BW_Mbps SAFE_RATE RATE_INPUT RATE
    read -rp "  瓶颈带宽 (Mbps) [默认 1000]: " BW_Mbps_INPUT
    BW_Mbps="${BW_Mbps_INPUT:-1000}"
    _tcptune_is_int "$BW_Mbps" || BW_Mbps=1000

    SAFE_RATE=$(awk -v bw="$BW_Mbps" 'BEGIN{ printf "%.0f", bw*0.90 }')
    read -rp "  初始限速值 (Mbps) [默认 ${SAFE_RATE}]: " RATE_INPUT
    RATE="${RATE_INPUT:-$SAFE_RATE}"
    _tcptune_is_int "$RATE" || RATE="$SAFE_RATE"
    local qdisc
    qdisc="$(_tcptune_effective_qdisc)"
    _info "沿用队列算法: ${qdisc}"

    _tcptune_cleanup_conflicts
    if command -v modprobe >/dev/null 2>&1; then
        modprobe tcp_bbr 2>/dev/null || true
        if [ "$qdisc" = "cake" ]; then
            modprobe sch_cake 2>/dev/null || true
        else
            modprobe sch_fq 2>/dev/null || true
        fi
        modprobe sch_htb 2>/dev/null || true
    fi

    _tcptune_write_profile 67108864 "$BW_Mbps" "0" "tc-fallback" "$qdisc"
    _tcptune_apply_qdisc "$qdisc" >/dev/null

    if ! command -v tc >/dev/null 2>&1; then
        _warn "未检测到 tc，无法应用 HTB 限速"
        _press_any_key
        return
    fi

    tc qdisc del dev "$iface" root 2>/dev/null || true
    tc qdisc add dev "$iface" root handle 1:0 htb default 10

    tc class replace dev "$iface" parent 1:0 classid 1:1 htb rate "${RATE}mbit" ceil "${RATE}mbit"
    tc filter replace dev "$iface" protocol ip parent 1:0 prio 1 u32 match ip src 0.0.0.0/0 flowid 1:1

    tc class replace dev "$iface" parent 1:0 classid 1:2 htb rate "${RATE}mbit" ceil "${RATE}mbit"
    tc filter replace dev "$iface" protocol ip parent 1:0 prio 1 u32 match ip dst 0.0.0.0/0 flowid 1:2

    echo "==== TC RESULT ===="
    echo "iface=${iface}, rate=${RATE}mbit"
    tc qdisc show dev "$iface" || true
    tc class show dev "$iface" || true
    echo "==================="

    local persist
    read -rp "  是否写入 /etc/rc.local 开机自启? [Y/n]: " persist
    if [[ ! "$persist" =~ ^[Nn]$ ]]; then
        _tcptune_write_rc_local_tc "$iface" "$RATE"
        _success "已写入 /etc/rc.local"
    fi

    _tcptune_show_review
    _network_reboot_prompt
    _press_any_key
}

_tcptune_setup() {
    while true; do
        _header "TCP 调优"
        _warn "调优为玄学内容，无法改变线路本质。"
        printf "  ${BOLD}请选择方案${PLAIN}\n"
        _separator
        _menu_item "1" "方案一: BDP 动态调优" "理论值 + 按 Retr 微调" "green"
        _menu_item "2" "方案二: TC 限速保稳" "高重传时的回退方案" "green"
        _menu_item "0" "返回主菜单" "" "red"
        _separator

        local choice
        read -rp "  选择 [0-2]: " choice

        case "$choice" in
            1) _tcptune_mode_bdp ;;
            2) _tcptune_mode_tc ;;
            0) return ;;
            *)
                _error_no_exit "无效选项: ${choice}"
                sleep 1
                ;;
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
        _error_no_exit "需要 jq 工具来处理 JSON 配置，请先安装: apt install -y jq 或 yum install -y jq"
        _press_any_key
        return
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
    if systemctl restart docker 2>/dev/null; then
        _info "Docker 重启成功!"
    else
        _warn "Docker 重启失败，请手动执行: systemctl restart docker"
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
    if command -v wget &>/dev/null; then
        wget -q --show-progress -O "$output" "$url"
    else
        curl -fSL -o "$output" "$url"
    fi
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
    read -rp "  安装/更新 mihomo? [Y/n]: " confirm_install
    if [[ "$confirm_install" =~ ^([Nn]|[Nn][Oo])$ ]]; then
        _info "已取消"
        _press_any_key
        return
    fi

    # 获取最新版本
    local LATEST_VERSION
    LATEST_VERSION=$(curl -fsSL https://api.github.com/repos/MetaCubeX/mihomo/releases/latest \
        | grep '"tag_name"' | head -1 | cut -d'"' -f4)
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
_MIHOMOCHAIN_DB_FILE="/etc/mihomo/chain-proxy.db"
_ACME_HOME="/root/.acme.sh"
_ACME_BIN="/root/.acme.sh/acme.sh"
_ACME_CERT_DEFAULT_DIR="/etc/mihomo/ssl"

_mihomoconf_gen_ss_password_128() { head -c 16 /dev/urandom | base64 | tr -d '\n'; }
_mihomoconf_gen_ss_password_256() { head -c 32 /dev/urandom | base64 | tr -d '\n'; }
_mihomoconf_gen_anytls_password()  { head -c 32 /dev/urandom | base64 | tr -d '\n' | tr '/+' 'Aa' | tr -d '=' | head -c 32; }

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
    local userinfo encoded_name
    userinfo=$(_mihomoconf_url_base64 "${cipher}:${password}")
    encoded_name=$(_mihomoconf_urlencode "${name}")
    echo "ss://${userinfo}@${server}:${port}?tfo=1&uot=2#${encoded_name}"
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
        /^[^ #][^:]*:[[:space:]]*$/ {
            in_listeners = ($0 ~ /^listeners:[[:space:]]*$/)
            next
        }
        in_listeners && /^    type:/ {
            line=$0
            sub(/^    type:[[:space:]]*/, "", line)
            if (line == t) {
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
        /^[^ #][^:]*:[[:space:]]*$/ {
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
            found=(trim(line) == t)
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
        /^[^ #][^:]*:[[:space:]]*$/ {
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
                if (trim(line) == t) {
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
        function unquote(s) {
            gsub(/^"/, "", s)
            gsub(/"$/, "", s)
            return s
        }
        function reset_state() {
            name=tag=type=port=cipher=password=user_id=user_pass=sni=""
            hy2_up=hy2_down=hy2_ignore=hy2_obfs=hy2_obfs_password=hy2_masquerade=hy2_mport=hy2_insecure=""
            in_users=0
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
        /^[^ #][^:]*:[[:space:]]*$/ {
            if (in_listeners) {
                emit()
                reset_state()
            }
            in_listeners = ($0 ~ /^listeners:[[:space:]]*$/)
            next
        }
        !in_listeners { next }
        /^  - name:/ {
            emit()
            line=$0
            sub(/^  - name:[[:space:]]*/, "", line)
            name=unquote(trim(line))
            tag=type=port=cipher=password=user_id=user_pass=sni=""
            hy2_up=hy2_down=hy2_ignore=hy2_obfs=hy2_obfs_password=hy2_masquerade=hy2_mport=hy2_insecure=""
            in_users=0
            next
        }
        /^    tag:/ {
            line=$0
            sub(/^    tag:[[:space:]]*/, "", line)
            tag=unquote(trim(line))
            next
        }
        /^    #[[:space:]]*vpsgo-sni:/ {
            line=$0
            sub(/^    #[[:space:]]*vpsgo-sni:[[:space:]]*/, "", line)
            line=trim(line)
            sub(/\r$/, "", line)
            sni=unquote(line)
            next
        }
        /^    #[[:space:]]*vpsgo-peer:/ {
            line=$0
            sub(/^    #[[:space:]]*vpsgo-peer:[[:space:]]*/, "", line)
            line=trim(line)
            sub(/\r$/, "", line)
            sni=unquote(line)
            next
        }
        /^    #[[:space:]]*vpsgo-mport:/ {
            line=$0
            sub(/^    #[[:space:]]*vpsgo-mport:[[:space:]]*/, "", line)
            hy2_mport=trim(line)
            next
        }
        /^    #[[:space:]]*vpsgo-insecure:/ {
            line=$0
            sub(/^    #[[:space:]]*vpsgo-insecure:[[:space:]]*/, "", line)
            hy2_insecure=trim(line)
            next
        }
        /^    type:/ {
            line=$0
            sub(/^    type:[[:space:]]*/, "", line)
            type=trim(line)
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
        /^    password:/ {
            line=$0
            sub(/^    password:[[:space:]]*/, "", line)
            password=unquote(trim(line))
            next
        }
        /^    up:/ {
            line=$0
            sub(/^    up:[[:space:]]*/, "", line)
            hy2_up=trim(line)
            next
        }
        /^    down:/ {
            line=$0
            sub(/^    down:[[:space:]]*/, "", line)
            hy2_down=trim(line)
            next
        }
        /^    ignore-client-bandwidth:/ {
            line=$0
            sub(/^    ignore-client-bandwidth:[[:space:]]*/, "", line)
            hy2_ignore=trim(line)
            next
        }
        /^    obfs:/ {
            line=$0
            sub(/^    obfs:[[:space:]]*/, "", line)
            hy2_obfs=trim(line)
            next
        }
        /^    obfs-password:/ {
            line=$0
            sub(/^    obfs-password:[[:space:]]*/, "", line)
            hy2_obfs_password=unquote(trim(line))
            next
        }
        /^    masquerade:/ {
            line=$0
            sub(/^    masquerade:[[:space:]]*/, "", line)
            hy2_masquerade=unquote(trim(line))
            next
        }
        /^    users:/ {
            in_users=1
            next
        }
        in_users && /^    [^ ]/ {
            in_users=0
        }
        in_users && /^[[:space:]]+[^[:space:]#].*:/ {
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
        }
        END {
            emit()
        }
    ' "$config_file"
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

    local -a SS_PORTS=() SS_PASSWORDS=() SS_TAGS=()
    local SS_CIPHER=""
    local -a ANYTLS_PORTS=() ANYTLS_USER_IDS=() ANYTLS_PASSWORDS=() ANYTLS_TAGS=()
    local ANYTLS_SNI=""
    local -a HY2_PORTS=() HY2_PASSWORDS=() HY2_TAGS=() HY2_MPORTS=() HY2_OBFS_PASSWORDS=()
    local -a RESERVED_PORTS=() NEW_PORTS=()
    local HY2_USER="hy2-user" HY2_UP="" HY2_DOWN=""
    local HY2_IGNORE_CLIENT_BANDWIDTH="false" HY2_SNI="" HY2_INSECURE="0"
    local HY2_OBFS="" HY2_MASQUERADE=""
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
    printf "  ${DIM}提示: 每输入一次数字就会创建一个对应协议入站，例如 1 1 2 2 = 2个SS2022 + 2个AnyTLS${PLAIN}\n"
    _separator
    _menu_pair "1" "SS2022" "" "green" "2" "AnyTLS" "" "green"
    _menu_item "3" "HY2" "" "green"
    _separator
    local PROTOCOL_CHOICES
    read -rp "  选择 (如 \"1 1 2 2\" 表示 2 个 SS + 2 个 AnyTLS): " -a PROTOCOL_CHOICES

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
        local _ss_port
        for _ss_port in "${SS_PORTS[@]}"; do
            if [[ "$SS_CIPHER" == "2022-blake3-aes-128-gcm" ]]; then
                SS_PASSWORDS+=("$(_mihomoconf_gen_ss_password_128)")
            else
                SS_PASSWORDS+=("$(_mihomoconf_gen_ss_password_256)")
            fi
            SS_TAGS+=("$(_mihomoconf_gen_listener_tag "ss_relay")")
        done
        _info "SS2022 已生成 ${#SS_PORTS[@]} 个入站(含随机密码与 tag)"
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
        local _anytls_port
        for _anytls_port in "${ANYTLS_PORTS[@]}"; do
            ANYTLS_USER_IDS+=("$(_mihomoconf_gen_uuid)")
            ANYTLS_PASSWORDS+=("$(_mihomoconf_gen_anytls_password)")
            ANYTLS_TAGS+=("$(_mihomoconf_gen_listener_tag "anytls_relay")")
        done
        _info "AnyTLS 已生成 ${#ANYTLS_PORTS[@]} 个入站(含随机 ID/密码/tag)"
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

        for _hy2_port in "${HY2_PORTS[@]}"; do
            HY2_PASSWORDS+=("$(_mihomoconf_gen_anytls_password)")
            HY2_TAGS+=("$(_mihomoconf_gen_listener_tag "hy2_relay")")
        done
        _info "HY2 已生成 ${#HY2_PORTS[@]} 个入站(含随机密码/tag)"
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
        local _ss_port _ss_password _ss_tag
        local _anytls_port _anytls_user_id _anytls_password _anytls_tag
        local _hy2_port _hy2_password _hy2_tag _hy2_mport _hy2_obfs_password
        if [[ "$ENABLE_SS" == "y" ]]; then
            for i in "${!SS_PORTS[@]}"; do
                _ss_port="${SS_PORTS[$i]}"
                _ss_password="${SS_PASSWORDS[$i]}"
                _ss_tag="${SS_TAGS[$i]}"
                cat >> "$_target_file" <<MIHOMOCONF_SS_EOF
  - name: ss2022-in-${_ss_port}
    tag: "${_ss_tag}"
    type: shadowsocks
    port: ${_ss_port}
    listen: "::"
    cipher: ${SS_CIPHER}
    password: "${_ss_password}"
    udp: true
MIHOMOCONF_SS_EOF
            done
        fi
        if [[ "$ENABLE_ANYTLS" == "y" ]]; then
            for i in "${!ANYTLS_PORTS[@]}"; do
                _anytls_port="${ANYTLS_PORTS[$i]}"
                _anytls_user_id="${ANYTLS_USER_IDS[$i]}"
                _anytls_password="${ANYTLS_PASSWORDS[$i]}"
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
      "${_anytls_user_id}": "${_anytls_password}"
MIHOMOCONF_AT_EOF
            done
        fi
        if [[ "$ENABLE_HY2" == "y" ]]; then
            for i in "${!HY2_PORTS[@]}"; do
                _hy2_port="${HY2_PORTS[$i]}"
                _hy2_password="${HY2_PASSWORDS[$i]}"
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
      "${HY2_USER}": "${_hy2_password}"
    up: ${HY2_UP}
    down: ${HY2_DOWN}
    ignore-client-bandwidth: ${HY2_IGNORE_CLIENT_BANDWIDTH}
MIHOMOCONF_HY2_EOF
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
mode: direct
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
    _mihomoconf_set_saved_host "$CONFIG_FILE" "$SERVER_HOST"

    # ---- 输出结果 ----
    _header "配置生成完成"
    _info "配置文件: ${CONFIG_FILE}"
    _info "写入模式: $( [[ "$WRITE_MODE" == "new" ]] && echo "全新生成" || echo "追加到现有配置" )"

    # SS2022 输出
    if [[ "$ENABLE_SS" == "y" ]]; then
        printf "  ${BOLD}SS2022 连接信息 (%s 个)${PLAIN}\n" "${#SS_PORTS[@]}"
        local i SS_LINK _ss_port _ss_password _ss_tag _ss_name
        for i in "${!SS_PORTS[@]}"; do
            _ss_port="${SS_PORTS[$i]}"
            _ss_password="${SS_PASSWORDS[$i]}"
            _ss_tag="${SS_TAGS[$i]}"
            _ss_name=$(_mihomoconf_make_node_name "SS" "$NODE_FLAG" "$NODE_COUNTRY_CODE")
            SS_LINK=$(_mihomoconf_gen_ss_link "$SERVER_HOST" "$_ss_port" "$SS_CIPHER" "$_ss_password" "$_ss_name")
            _separator
            printf "    [%s] 节点名: ${GREEN}%s${PLAIN}\n" "$((i + 1))" "$_ss_name"
            printf "      入站tag: ${GREEN}%s${PLAIN}\n" "$_ss_tag"
            printf "      服务器 : ${GREEN}%s${PLAIN}\n" "$SERVER_HOST"
            printf "      端口   : ${GREEN}%s${PLAIN}\n" "$_ss_port"
            printf "      加密   : ${GREEN}%s${PLAIN}\n" "$SS_CIPHER"
            printf "      密码   : ${GREEN}%s${PLAIN}\n" "$_ss_password"
            printf "  ${BOLD}SS2022 分享链接:${PLAIN}\n"
            printf "  ${GREEN}%s${PLAIN}\n" "$SS_LINK"
            printf "  ${BOLD}Clash Meta 客户端 YAML:${PLAIN}\n"
            cat <<MIHOMOCONF_SS_YAML
    proxies:
      - name: "${_ss_name}"
        type: ss
        server: ${SERVER_HOST}
        port: ${_ss_port}
        cipher: ${SS_CIPHER}
        password: "${_ss_password}"
        udp: true
        tfo: true
        udp-over-tcp: true
MIHOMOCONF_SS_YAML
        done
    fi

    # AnyTLS 输出
    if [[ "$ENABLE_ANYTLS" == "y" ]]; then
        printf "  ${BOLD}AnyTLS 连接信息 (%s 个)${PLAIN}\n" "${#ANYTLS_PORTS[@]}"
        local i ANYTLS_LINK _anytls_port _anytls_password _anytls_tag _anytls_name
        for i in "${!ANYTLS_PORTS[@]}"; do
            _anytls_port="${ANYTLS_PORTS[$i]}"
            _anytls_password="${ANYTLS_PASSWORDS[$i]}"
            _anytls_tag="${ANYTLS_TAGS[$i]}"
            _anytls_name=$(_mihomoconf_make_node_name "AnyTLS" "$NODE_FLAG" "$NODE_COUNTRY_CODE")
            ANYTLS_LINK=$(_mihomoconf_gen_anytls_link "$SERVER_HOST" "$_anytls_port" "$_anytls_password" "$_anytls_name" "$ANYTLS_SNI")
            _separator
            printf "    [%s] 节点名: ${GREEN}%s${PLAIN}\n" "$((i + 1))" "$_anytls_name"
            printf "      入站tag: ${GREEN}%s${PLAIN}\n" "$_anytls_tag"
            printf "      服务器 : ${GREEN}%s${PLAIN}\n" "$SERVER_HOST"
            printf "      端口   : ${GREEN}%s${PLAIN}\n" "$_anytls_port"
            printf "      密码   : ${GREEN}%s${PLAIN}\n" "$_anytls_password"
            printf "  ${BOLD}AnyTLS 分享链接:${PLAIN}\n"
            printf "  ${GREEN}%s${PLAIN}\n" "$ANYTLS_LINK"
            printf "  ${BOLD}Clash Meta 客户端 YAML:${PLAIN}\n"
            cat <<MIHOMOCONF_AT_YAML
    proxies:
      - name: "${_anytls_name}"
        type: anytls
        server: ${SERVER_HOST}
        port: ${_anytls_port}
        password: "${_anytls_password}"
        udp: true
        tfo: true
MIHOMOCONF_AT_YAML
            if [[ -n "$ANYTLS_SNI" ]]; then
                echo "        sni: ${ANYTLS_SNI}"
            else
                echo "        skip-cert-verify: true"
            fi
        done
    fi

    # HY2 输出
    if [[ "$ENABLE_HY2" == "y" ]]; then
        printf "  ${BOLD}HY2 连接信息 (%s 个)${PLAIN}\n" "${#HY2_PORTS[@]}"
        local i HY2_LINK _hy2_port _hy2_password _hy2_tag _hy2_mport _hy2_obfs_password _hy2_name
        for i in "${!HY2_PORTS[@]}"; do
            _hy2_port="${HY2_PORTS[$i]}"
            _hy2_password="${HY2_PASSWORDS[$i]}"
            _hy2_tag="${HY2_TAGS[$i]}"
            _hy2_mport="${HY2_MPORTS[$i]}"
            _hy2_obfs_password="${HY2_OBFS_PASSWORDS[$i]}"
            _hy2_name=$(_mihomoconf_make_node_name "HY2" "$NODE_FLAG" "$NODE_COUNTRY_CODE")
            HY2_LINK=$(_mihomoconf_gen_hy2_link "$SERVER_HOST" "$_hy2_port" "$_hy2_password" "$_hy2_name" "$HY2_SNI" "$HY2_INSECURE" "$HY2_OBFS" "$_hy2_obfs_password" "$_hy2_mport")
            _separator
            printf "    [%s] 节点名: ${GREEN}%s${PLAIN}\n" "$((i + 1))" "$_hy2_name"
            printf "      入站tag: ${GREEN}%s${PLAIN}\n" "$_hy2_tag"
            printf "      服务器 : ${GREEN}%s${PLAIN}\n" "$SERVER_HOST"
            printf "      端口   : ${GREEN}%s${PLAIN}\n" "$_hy2_port"
            printf "      用户   : ${GREEN}%s${PLAIN}\n" "$HY2_USER"
            printf "      密码   : ${GREEN}%s${PLAIN}\n" "$_hy2_password"
            printf "      up/down: ${GREEN}%s/%s Mbps${PLAIN}\n" "$HY2_UP" "$HY2_DOWN"
            [[ -n "$HY2_SNI" ]] && printf "      SNI    : ${GREEN}%s${PLAIN}\n" "$HY2_SNI"
            [[ -n "$_hy2_mport" ]] && printf "      跳跃端口: ${GREEN}%s${PLAIN}\n" "$_hy2_mport"
            [[ "$HY2_INSECURE" == "1" ]] && printf "      insecure: ${YELLOW}开启${PLAIN}\n"
            [[ -n "$HY2_OBFS" ]] && printf "      obfs    : ${GREEN}%s${PLAIN}\n" "$HY2_OBFS"
            [[ -n "$HY2_MASQUERADE" ]] && printf "      masquerade: ${GREEN}%s${PLAIN}\n" "$HY2_MASQUERADE"
            printf "  ${BOLD}HY2 分享链接:${PLAIN}\n"
            printf "  ${GREEN}%s${PLAIN}\n" "$HY2_LINK"
            printf "  ${BOLD}HY2 JSON:${PLAIN}\n"
            cat <<MIHOMOCONF_HY2_JSON
    {
      "type": "hysteria2",
      "tag": "${_hy2_name}",
      "server": "${SERVER_HOST}",
      "server_port": ${_hy2_port},
      "password": "${_hy2_password}",
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
    fi

    _separator
    _info "可在 Mihomo 管理菜单中通过「读取配置并生成节点」随时生成链接/JSON"
    _info "启动命令: mihomo -d ${CONFIG_DIR}"
    if ! _mihomoconf_post_setup_service_prompt "$SSL_DIR"; then
        _warn "自动应用服务失败，可在 Mihomo 菜单手动执行「配置自启并启动」或「重启 Mihomo」"
    fi

    _press_any_key
}

# --- Mihomo 管理子菜单 ---

_mihomo_restart_now() {
    if ! command -v mihomo >/dev/null 2>&1; then
        _error_no_exit "未检测到 mihomo，请先安装"
        return 1
    fi

    # systemd 服务
    if systemctl is-enabled mihomo.service &>/dev/null || systemctl is-active mihomo.service &>/dev/null; then
        _info "通过 systemd 重启 mihomo..."
        if ! systemctl restart mihomo; then
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
    else
        # 手动进程
        local pid
        pid=$(pgrep -x mihomo 2>/dev/null || true)
        if [[ -n "$pid" ]]; then
            _info "终止旧进程 (PID: $pid)..."
            kill "$pid" 2>/dev/null
            sleep 1
        fi
        local config_dir="/etc/mihomo"
        if [[ -d "$config_dir" ]]; then
            _info "启动 mihomo -d ${config_dir}..."
            nohup mihomo -d "$config_dir" >/dev/null 2>&1 &
            sleep 1
            if pgrep -x mihomo &>/dev/null; then
                _info "mihomo 已成功启动 (PID: $!)"
                return 0
            else
                _error_no_exit "mihomo 启动失败"
                return 1
            fi
        else
            _error_no_exit "配置目录 $config_dir 不存在，请先生成配置"
            return 1
        fi
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

    local service_file="/etc/systemd/system/mihomo.service"
    local config_dir="/etc/mihomo"
    local mihomo_bin
    mihomo_bin=$(command -v mihomo)

    if [[ ! -d "$config_dir" ]]; then
        _error_no_exit "配置目录 $config_dir 不存在，请先生成配置"
        return 1
    fi

    if [[ "$force_rewrite" == "1" || ! -f "$service_file" ]]; then
        _info "生成 systemd 服务文件..."
        cat > "$service_file" <<SERVICEEOF
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

    systemctl daemon-reload
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
}

_mihomoconf_post_setup_service_prompt() {
    local ssl_dir="$1"
    local cert_file="${ssl_dir}/cert.crt"
    local key_file="${ssl_dir}/cert.key"
    local answer

    echo ""
    _separator
    _info "提示: 配置已生成，可立即应用到 mihomo 服务"

    if [[ ! -f "$cert_file" || ! -f "$key_file" ]]; then
        _warn "未检测到完整 SSL 证书，跳过自动启动提示"
        return 0
    fi

    _info "检测到 SSL 证书: ${ssl_dir}"

    if pgrep -x mihomo >/dev/null 2>&1 || systemctl is-active --quiet mihomo 2>/dev/null; then
        read -rp "  检测到 mihomo 已启动，是否立即重启应用新配置? [Y/n]: " answer
        if [[ "$answer" =~ ^([Nn]|[Nn][Oo])$ ]]; then
            _info "已跳过重启"
            return 0
        fi
        _mihomo_restart_now
        return $?
    fi

    if systemctl is-enabled mihomo.service &>/dev/null || [[ -f /etc/systemd/system/mihomo.service ]]; then
        read -rp "  检测到 mihomo 服务已配置，是否立即启动? [Y/n]: " answer
        if [[ "$answer" =~ ^([Nn]|[Nn][Oo])$ ]]; then
            _info "已跳过启动"
            return 0
        fi
        _mihomo_restart_now
        return $?
    fi

    read -rp "  检测到 SSL 证书，是否配置自启并启动 mihomo? [Y/n]: " answer
    if [[ "$answer" =~ ^([Nn]|[Nn][Oo])$ ]]; then
        _info "已跳过自启动配置"
        return 0
    fi
    _mihomo_enable_now "1"
    return $?
}

_mihomo_enable() {
    _header "Mihomo 自启动配置"

    local service_file="/etc/systemd/system/mihomo.service"
    local force_rewrite="0"

    if [[ -f "$service_file" ]]; then
        _warn "systemd 服务文件已存在"
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

_mihomo_log() {
    _header "Mihomo 日志"

    if ! command -v mihomo >/dev/null 2>&1; then
        _error_no_exit "未检测到 mihomo，请先安装"
        _press_any_key
        return
    fi

    echo ""
    if systemctl is-enabled mihomo.service &>/dev/null || systemctl is-active mihomo.service &>/dev/null; then
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
    else
        _warn "mihomo 未使用 systemd 管理，无法通过 journalctl 查看日志"
        _info "提示: 可以通过选项3「配置自启并启动」来设置 systemd 服务"
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
    local type name port cipher password user_id user_pass sni listener_tag
    local hy2_up hy2_down hy2_ignore hy2_obfs hy2_obfs_password hy2_masquerade hy2_mport hy2_insecure
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
    _info "仅支持导出 AnyTLS / SS2022 / HY2 节点"
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
        listener_tag="${listener_tag:-$name}"

        case "$type" in
            shadowsocks)
                if [[ "$cipher" != 2022-* ]]; then
                    _warn "跳过 ${name}: 非 SS2022 节点 (cipher=${cipher})"
                    continue
                fi
                if [[ -z "$port" || -z "$password" ]]; then
                    _warn "跳过 ${name}: 节点字段不完整"
                    continue
                fi
                export_count=$((export_count + 1))
                local ss_link ss_name
                ss_name=$(_mihomoconf_make_node_name "SS" "$NODE_FLAG" "$NODE_COUNTRY_CODE")
                ss_link=$(_mihomoconf_gen_ss_link "$server_ip" "$port" "$cipher" "$password" "$ss_name")
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
      "udp_over_tcp": { "enabled": true }
    }
MIHOMO_SS2022_JSON
                ;;
            anytls)
                if [[ -z "$port" || -z "$user_pass" ]]; then
                    _warn "跳过 ${name}: 节点字段不完整"
                    continue
                fi
                export_count=$((export_count + 1))
                local anytls_link anytls_name
                anytls_name=$(_mihomoconf_make_node_name "AnyTLS" "$NODE_FLAG" "$NODE_COUNTRY_CODE")
                anytls_link=$(_mihomoconf_gen_anytls_link "$server_ip" "$port" "$user_pass" "$anytls_name" "$sni")
                _separator
                printf "  ${BOLD}[AnyTLS] %s${PLAIN}\n" "$anytls_name"
                printf "    入站tag: ${GREEN}%s${PLAIN}\n" "$listener_tag"
                printf "    链接: ${GREEN}%s${PLAIN}\n" "$anytls_link"
                [[ -n "$sni" ]] && printf "    SNI: ${GREEN}%s${PLAIN}\n" "$sni"
                printf "    JSON:\n"
                cat <<MIHOMO_ANYTLS_JSON
    {
      "type": "anytls",
      "tag": "${anytls_name}",
      "server": "${server_ip}",
      "server_port": ${port},
      "password": "${user_pass}",
      "sni": "${sni}",
      "udp": true,
      "tfo": true
    }
MIHOMO_ANYTLS_JSON
                ;;
            hysteria2)
                if [[ -z "$port" || -z "$user_pass" ]]; then
                    _warn "跳过 ${name}: 节点字段不完整"
                    continue
                fi
                export_count=$((export_count + 1))
                local hy2_link hy2_name
                hy2_name=$(_mihomoconf_make_node_name "HY2" "$NODE_FLAG" "$NODE_COUNTRY_CODE")
                hy2_link=$(_mihomoconf_gen_hy2_link "$server_ip" "$port" "$user_pass" "$hy2_name" "$sni" "${hy2_insecure:-0}" "$hy2_obfs" "$hy2_obfs_password" "$hy2_mport")
                _separator
                printf "  ${BOLD}[HY2] %s${PLAIN}\n" "$hy2_name"
                printf "    入站tag: ${GREEN}%s${PLAIN}\n" "$listener_tag"
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
      "password": "${user_pass}",
      "sni": "${sni}",
      "insecure": ${hy2_insecure:-0},
      "up_mbps": ${hy2_up:-1000},
      "down_mbps": ${hy2_down:-1000},
      "mport": "${hy2_mport}",
      "obfs": "${hy2_obfs}",
      "obfs_password": "${hy2_obfs_password}"
    }
MIHOMO_HY2_JSON
                ;;
            *)
                _warn "跳过 ${name}: 暂不支持类型 ${type}"
                ;;
        esac
    done < <(_mihomoconf_read_listener_rows "$config_file")

    _separator
    if [[ "$total_count" -eq 0 ]]; then
        _warn "未在配置中检测到 listeners 节点"
    elif [[ "$export_count" -eq 0 ]]; then
        _warn "共读取 ${total_count} 个节点，但没有可导出的 AnyTLS/SS2022/HY2 节点"
    else
        _info "共读取 ${total_count} 个节点，已导出 ${export_count} 个节点"
    fi

    _press_any_key
}

_mihomochain_db_ensure() {
    mkdir -p "$(dirname "$_MIHOMOCHAIN_DB_FILE")"
    touch "$_MIHOMOCHAIN_DB_FILE"
}

_mihomochain_is_valid_tag() {
    [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]
}

_mihomochain_outbound_exists() {
    local tag="$1"
    awk -F'|' -v t="$tag" '$1=="OUT" && $2==t { found=1 } END { exit !found }' "$_MIHOMOCHAIN_DB_FILE"
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
    awk -F'|' -v t="$tag" '
        $1=="OUT" && $2==t {
            if ($14 != "") print $14
            else print $2
            found=1
            exit
        }
        END { if (!found) print t }
    ' "$_MIHOMOCHAIN_DB_FILE"
}

_mihomochain_outbound_tag_by_name() {
    local name="$1"
    awk -F'|' -v n="$name" '
        $1=="OUT" {
            out_name = ($14 != "") ? $14 : $2
            if (out_name == n) {
                print $2
                found=1
                exit
            }
        }
        END { if (!found) exit 1 }
    ' "$_MIHOMOCHAIN_DB_FILE"
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
    if ! awk -F'|' '
        BEGIN { shown=0 }
        $1=="OUT" {
            shown=1
            out_name = ($14 != "") ? $14 : $2
            if ($3=="ss") {
                printf "      %s (type=%s, %s:%s, cipher=%s)\n", out_name, $3, $4, $5, $6
            } else if ($3=="anytls") {
                sni = ($9 != "") ? ", sni=" $9 : ""
                printf "      %s (type=%s, %s:%s%s)\n", out_name, $3, $4, $5, sni
            } else if ($3=="hysteria2" || $3=="hy2") {
                sni = ($9 != "") ? ", sni=" $9 : ""
                obfs = ($11 != "") ? ", obfs=" $11 : ""
                insecure = ($10 == "1") ? ", insecure=1" : ""
                printf "      %s (type=%s, %s:%s%s%s%s)\n", out_name, $3, $4, $5, sni, obfs, insecure
            } else if ($3=="socks5" || $3=="http") {
                auth = ($7 != "" || $8 != "") ? "auth=on" : "auth=off"
                printf "      %s (type=%s, %s:%s, %s)\n", out_name, $3, $4, $5, auth
            } else {
                printf "      %s (type=%s, %s:%s)\n", out_name, $3, $4, $5
            }
        }
        END { exit shown ? 0 : 1 }
    ' "$_MIHOMOCHAIN_DB_FILE"; then
        _warn "暂无落地节点/二层代理"
    fi
}

_mihomochain_list_rules() {
    if ! awk -F'|' '
        BEGIN { shown=0 }
        $1=="RULE" {
            shown=1
            printf "      listener-tag=%s -> outbound-tag=%s\n", $2, $3
        }
        END { exit shown ? 0 : 1 }
    ' "$_MIHOMOCHAIN_DB_FILE"; then
        _warn "暂无入站分流规则"
    fi
}

_mihomochain_show_topology() {
    local config_file="${1:-$_MIHOMOCONF_CONFIG_FILE}"
    local shown=0
    local kind in_tag out_tag
    while IFS='|' read -r kind in_tag out_tag; do
        [[ "$kind" == "RULE" ]] || continue
        shown=1
        local in_name out_name
        in_name=$(_mihomochain_listener_name_by_tag "$config_file" "$in_tag")
        out_name=$(_mihomochain_outbound_name_by_tag "$out_tag")
        printf "      %s  ${DIM}-->${PLAIN}  %s\n" "$in_name" "$out_name"
    done < "$_MIHOMOCHAIN_DB_FILE"

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
    while IFS=$'\x1f' read -r type name port cipher password user_id user_pass sni \
        hy2_up hy2_down hy2_ignore hy2_obfs hy2_obfs_password hy2_masquerade hy2_mport hy2_insecure listener_tag; do
        [[ -z "${name:-}" ]] && continue
        found=1
        printf "      %s (type=%s, port=%s)\n" "$name" "$type" "${port:-N/A}"
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

_mihomochain_add_or_update_outbound() {
    local tag="$1" type="$2" server="$3" port="$4" cipher="$5" username="$6" password="$7"
    local sni="${8:-}" insecure="${9:-0}" obfs="${10:-}" obfs_password="${11:-}" mport="${12:-}" out_name="${13:-}"
    local tmp
    tmp=$(mktemp)
    awk -F'|' -v t="$tag" '$1=="OUT" && $2==t { next } { print }' "$_MIHOMOCHAIN_DB_FILE" > "$tmp"
    printf 'OUT|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "$tag" "$type" "$server" "$port" "$cipher" "$username" "$password" "$sni" "$insecure" "$obfs" "$obfs_password" "$mport" "${out_name:-$tag}" >> "$tmp"
    mv "$tmp" "$_MIHOMOCHAIN_DB_FILE"
}

_mihomochain_add_or_update_rule() {
    local in_tag="$1" out_tag="$2"
    local tmp
    tmp=$(mktemp)
    awk -F'|' -v i="$in_tag" '$1=="RULE" && $2==i { next } { print }' "$_MIHOMOCHAIN_DB_FILE" > "$tmp"
    printf 'RULE|%s|%s\n' "$in_tag" "$out_tag" >> "$tmp"
    mv "$tmp" "$_MIHOMOCHAIN_DB_FILE"
}

_mihomochain_remove_outbound() {
    local tag="$1"
    local tmp
    tmp=$(mktemp)
    awk -F'|' -v t="$tag" '
        ($1=="OUT" && $2==t) { next }
        ($1=="RULE" && $3==t) { next }
        { print }
    ' "$_MIHOMOCHAIN_DB_FILE" > "$tmp"
    mv "$tmp" "$_MIHOMOCHAIN_DB_FILE"
}

_mihomochain_remove_rule() {
    local in_tag="$1"
    local tmp
    tmp=$(mktemp)
    awk -F'|' -v i="$in_tag" '($1=="RULE" && $2==i) { next } { print }' "$_MIHOMOCHAIN_DB_FILE" > "$tmp"
    mv "$tmp" "$_MIHOMOCHAIN_DB_FILE"
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

    _mihomochain_db_ensure

    local backup_file tmp_cfg tmp_out tmp_rule tmp_out_map has_out=0 has_rule=0
    backup_file="${config_file}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$config_file" "$backup_file"

    tmp_cfg=$(mktemp)
    tmp_out=$(mktemp)
    tmp_rule=$(mktemp)
    tmp_out_map=$(mktemp)

    # 服务端链式代理由 vpsgo 接管 proxies/rules 两个顶级段
    awk '
        BEGIN { skip=0 }
        skip && /^[^ #]/ { skip=0 }
        skip { next }
        /^proxies:[[:space:]]*$/ { skip=1; next }
        /^rules:[[:space:]]*$/ { skip=1; next }
        { print }
    ' "$config_file" > "$tmp_cfg"

    local kind tag type server port cipher username password sni insecure obfs obfs_password mport out_name in_tag out_tag
    while IFS='|' read -r kind tag type server port cipher username password sni insecure obfs obfs_password mport out_name; do
        [[ -z "${kind:-}" ]] && continue
        if [[ "$kind" == "OUT" ]]; then
            has_out=1
            [[ -z "${out_name:-}" ]] && out_name="$tag"
            case "$type" in
                ss)
                    cat >> "$tmp_out" <<EOF
  - name: "${out_name}"
    type: ss
    server: ${server}
    port: ${port}
    cipher: ${cipher}
    password: "${password}"
    udp: true
EOF
                    printf '%s|%s\n' "$tag" "$out_name" >> "$tmp_out_map"
                    ;;
                anytls)
                    cat >> "$tmp_out" <<EOF
  - name: "${out_name}"
    type: anytls
    server: ${server}
    port: ${port}
    password: "${password}"
    udp: true
    tfo: true
EOF
                    if [[ -n "$sni" ]]; then
                        printf "    sni: \"%s\"\n" "$sni" >> "$tmp_out"
                    fi
                    printf '%s|%s\n' "$tag" "$out_name" >> "$tmp_out_map"
                    ;;
                hy2|hysteria2)
                    cat >> "$tmp_out" <<EOF
  - name: "${out_name}"
    type: hysteria2
    server: ${server}
    port: ${port}
    password: "${password}"
EOF
                    if [[ -n "$sni" ]]; then
                        printf "    sni: \"%s\"\n" "$sni" >> "$tmp_out"
                    fi
                    if [[ "$insecure" == "1" ]]; then
                        echo "    skip-cert-verify: true" >> "$tmp_out"
                    fi
                    if [[ -n "$mport" ]]; then
                        printf "    mport: \"%s\"\n" "$mport" >> "$tmp_out"
                    fi
                    if [[ -n "$obfs" ]]; then
                        printf "    obfs: \"%s\"\n" "$obfs" >> "$tmp_out"
                        if [[ -n "$obfs_password" ]]; then
                            printf "    obfs-password: \"%s\"\n" "$obfs_password" >> "$tmp_out"
                        fi
                    fi
                    printf '%s|%s\n' "$tag" "$out_name" >> "$tmp_out_map"
                    ;;
                socks5|http)
                    cat >> "$tmp_out" <<EOF
  - name: "${out_name}"
    type: ${type}
    server: ${server}
    port: ${port}
EOF
                    if [[ -n "$username" ]]; then
                        printf "    username: \"%s\"\n" "$username" >> "$tmp_out"
                    fi
                    if [[ -n "$password" ]]; then
                        printf "    password: \"%s\"\n" "$password" >> "$tmp_out"
                    fi
                    if [[ "$type" == "socks5" ]]; then
                        echo "    udp: true" >> "$tmp_out"
                    fi
                    printf '%s|%s\n' "$tag" "$out_name" >> "$tmp_out_map"
                    ;;
                *)
                    _warn "跳过未知出站类型: ${type} (tag=${tag})"
                    ;;
            esac
        elif [[ "$kind" == "RULE" ]]; then
            in_tag="$tag"
            out_tag="$type"
            local out_proxy_name in_listener_name
            out_proxy_name=$(awk -F'|' -v t="$out_tag" '$1==t { print $2; exit }' "$tmp_out_map")
            in_listener_name=$(_mihomochain_listener_name_by_tag "$config_file" "$in_tag")
            if [[ "$in_listener_name" == "$in_tag" ]]; then
                in_listener_name=""
            fi

            if [[ -n "$out_proxy_name" && -n "$in_listener_name" ]]; then
                has_rule=1
                printf "  - IN-NAME,%s,%s\n" "$in_listener_name" "$out_proxy_name" >> "$tmp_rule"
            else
                _warn "跳过规则 ${in_tag}->${out_tag} (入站或出站不存在)"
            fi
        fi
    done < "$_MIHOMOCHAIN_DB_FILE"

    if [[ "$has_out" -eq 1 ]]; then
        {
            echo ""
            echo "proxies:"
            cat "$tmp_out"
        } >> "$tmp_cfg"
    fi

    if [[ "$has_rule" -eq 1 ]]; then
        # 有 rules 时必须启用 rule 模式，否则规则不会生效
        local tmp_mode
        tmp_mode=$(mktemp)
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
        ' "$tmp_cfg" > "$tmp_mode"
        mv "$tmp_mode" "$tmp_cfg"

        {
            echo ""
            echo "rules:"
            cat "$tmp_rule"
            echo "  - MATCH,DIRECT"
        } >> "$tmp_cfg"
    fi

    mv "$tmp_cfg" "$config_file"
    rm -f "$tmp_out" "$tmp_rule" "$tmp_out_map"
    _info "链式代理配置已写入: ${config_file}"
    _info "备份文件: ${backup_file}"
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

    _mihomochain_db_ensure
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
        _info "数据库: ${_MIHOMOCHAIN_DB_FILE}"
        _info "实时生效: 保存后将自动写入并重启 mihomo"
        _separator
        _menu_pair "1" "查看当前规则" "" "green" "2" "添加出口节点" "" "green"
        _menu_pair "3" "绑定入站节点 -> 出口节点" "" "green" "4" "删除出口节点" "" "green"
        _menu_item "5" "删除绑定规则" "" "green"
        _menu_item "0" "返回上级菜单" "" "red"
        _separator

        local ch
        read -rp "  选择 [0-5]: " ch
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
                _mihomochain_list_outbounds
                _press_any_key
                ;;
            2)
                printf "  ${BOLD}添加出口节点${PLAIN}\n"
                _separator
                _menu_pair "1" "通过链接导入" "ss:// hy2:// anytls://" "green" "2" "手动录入" "" "green"
                _separator
                local import_mode out_name out_tag out_type out_server out_port out_cipher out_user out_pass
                local out_sni out_insecure out_obfs out_obfs_pass out_mport
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
                read -rp "  出口节点名称: " out_name
                out_name=$(_mihomoconf_trim "${out_name:-}")
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
                out_cipher=""
                out_user=""
                out_pass=""
                out_sni=""
                out_insecure="0"
                out_obfs=""
                out_obfs_pass=""
                out_mport=""
                case "$import_mode" in
                    1)
                        local in_link link_body link_userinfo link_hostport link_query
                        local ss_decoded kv k v
                        local -a _qarr
                        read -rp "  输入链接 (ss:// / hy2:// / hysteria2:// / anytls://): " in_link
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
                            *)
                                _error_no_exit "暂不支持该链接类型，请使用 ss:// / hy2:// / hysteria2:// / anytls://"
                                _press_any_key
                                continue
                                ;;
                        esac
                        ;;
                    2)
                        _separator
                        _menu_pair "1" "ss" "" "green" "2" "hy2" "" "green"
                        _menu_pair "3" "anytls" "" "green" "4" "socks5" "" "green"
                        _menu_item "5" "http" "" "green"
                        _separator
                        local type_choice
                        read -rp "  出站类型 [1-5]: " type_choice
                        case "$type_choice" in
                            1) out_type="ss" ;;
                            2) out_type="hysteria2" ;;
                            3) out_type="anytls" ;;
                            4) out_type="socks5" ;;
                            5) out_type="http" ;;
                            *) _error_no_exit "无效类型"; _press_any_key; continue ;;
                        esac
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
                        esac
                        ;;
                esac

                if [[ "$out_name$out_server$out_cipher$out_user$out_pass$out_sni$out_obfs$out_obfs_pass$out_mport" == *"|"* ]]; then
                    _error_no_exit "字段中不能包含字符 |"
                    _press_any_key
                    continue
                fi

                if ! out_tag=$(_mihomochain_outbound_tag_by_name "$out_name" 2>/dev/null); then
                    out_tag=$(_mihomochain_gen_outbound_tag)
                fi
                _mihomochain_add_or_update_outbound \
                    "$out_tag" "$out_type" "$out_server" "$out_port" \
                    "${out_cipher:-}" "${out_user:-}" "${out_pass:-}" \
                    "${out_sni:-}" "${out_insecure:-0}" "${out_obfs:-}" "${out_obfs_pass:-}" "${out_mport:-}" "${out_name}"
                _info "出站节点已保存: ${out_name} (${out_type})"
                if ! _mihomochain_apply_and_restart; then
                    _warn "自动应用或重启失败，请检查日志后重试"
                fi
                _press_any_key
                ;;
            3)
                local listener_name in_tag out_name out_tag listener_input out_input
                local li oi idx kind tag type server port cipher username password sni insecure obfs obfs_password mport
                local l_type l_name l_port l_cipher l_password l_user_id l_user_pass l_sni
                local l_hy2_up l_hy2_down l_hy2_ignore l_hy2_obfs l_hy2_obfs_password l_hy2_masquerade l_hy2_mport l_hy2_insecure l_listener_tag
                local -a listener_names outbound_names

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
                while IFS='|' read -r kind tag type server port cipher username password sni insecure obfs obfs_password mport out_name; do
                    [[ "$kind" == "OUT" ]] || continue
                    [[ -n "${out_name:-}" ]] || out_name="$tag"
                    outbound_names+=("$out_name")
                    idx=$((idx + 1))
                    if [[ -n "${sni:-}" ]]; then
                        printf "      [%d] %s (type=%s, %s:%s, sni=%s)\n" "$idx" "$out_name" "$type" "$server" "$port" "$sni"
                    else
                        printf "      [%d] %s (type=%s, %s:%s)\n" "$idx" "$out_name" "$type" "$server" "$port"
                    fi
                done < "$_MIHOMOCHAIN_DB_FILE"
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
                _mihomochain_add_or_update_rule "$in_tag" "$out_tag"
                _info "规则已保存: ${listener_name} -> ${out_name}"
                if ! _mihomochain_apply_and_restart; then
                    _warn "自动应用或重启失败，请检查日志后重试"
                fi
                _press_any_key
                ;;
            4)
                printf "  ${BOLD}当前出口节点:${PLAIN}\n"
                _separator
                local rm_out_idx=0 kind tag type server port cipher username password sni insecure obfs obfs_password mport out_name
                local -a rm_out_names rm_out_tags
                while IFS='|' read -r kind tag type server port cipher username password sni insecure obfs obfs_password mport out_name; do
                    [[ "$kind" == "OUT" ]] || continue
                    [[ -n "${out_name:-}" ]] || out_name="$tag"
                    rm_out_names+=("$out_name")
                    rm_out_tags+=("$tag")
                    rm_out_idx=$((rm_out_idx + 1))
                    if [[ -n "${sni:-}" ]]; then
                        printf "      [%d] %s (type=%s, %s:%s, sni=%s)\n" "$rm_out_idx" "$out_name" "$type" "$server" "$port" "$sni"
                    else
                        printf "      [%d] %s (type=%s, %s:%s)\n" "$rm_out_idx" "$out_name" "$type" "$server" "$port"
                    fi
                done < "$_MIHOMOCHAIN_DB_FILE"
                if (( rm_out_idx == 0 )); then
                    _warn "暂无可删除的出口节点"
                    _press_any_key
                    continue
                fi

                local rm_pick rm_out_name rm_out_tag
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
                rm_out_tag="${rm_out_tags[$((rm_pick - 1))]}"
                _mihomochain_remove_outbound "$rm_out_tag"
                _info "已删除出口节点及其关联规则: ${rm_out_name}"
                if ! _mihomochain_apply_and_restart; then
                    _warn "自动应用或重启失败，请检查日志后重试"
                fi
                _press_any_key
                ;;
            5)
                printf "  ${BOLD}当前规则:${PLAIN}\n"
                _separator
                local rule_idx=0 kind in_tag out_tag in_name out_name
                local -a rule_in_names rule_in_tags
                while IFS='|' read -r kind in_tag out_tag; do
                    [[ "$kind" == "RULE" ]] || continue
                    in_name=$(_mihomochain_listener_name_by_tag "$config_file" "$in_tag")
                    out_name=$(_mihomochain_outbound_name_by_tag "$out_tag")
                    rule_in_names+=("$in_name")
                    rule_in_tags+=("$in_tag")
                    rule_idx=$((rule_idx + 1))
                    printf "      [%d] %s  ${DIM}-->${PLAIN}  %s\n" "$rule_idx" "$in_name" "$out_name"
                done < "$_MIHOMOCHAIN_DB_FILE"
                if (( rule_idx == 0 )); then
                    _warn "暂无可删除的绑定规则"
                    _press_any_key
                    continue
                fi

                local rm_listener_input rm_listener_name rm_in_tag rm_idx
                read -rp "  选择要删除的规则 [序号]: " rm_listener_input
                rm_listener_input=$(_mihomoconf_trim "${rm_listener_input:-}")
                if [[ -z "$rm_listener_input" ]]; then
                    _error_no_exit "输入不能为空"
                    _press_any_key
                    continue
                fi
                if [[ ! "$rm_listener_input" =~ ^[0-9]+$ ]]; then
                    _error_no_exit "请输入有效序号"
                    _press_any_key
                    continue
                fi
                rm_idx=$((10#$rm_listener_input))
                if (( rm_idx < 1 || rm_idx > rule_idx )); then
                    _error_no_exit "序号超出范围: ${rm_listener_input}"
                    _press_any_key
                    continue
                fi
                rm_in_tag="${rule_in_tags[$((rm_idx - 1))]}"
                rm_listener_name="${rule_in_names[$((rm_idx - 1))]}"
                _mihomochain_remove_rule "$rm_in_tag"
                _info "规则已删除: ${rm_listener_name} -> *"
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
        _menu_pair "7" "服务端链式代理" "" "green" "0" "返回主菜单" "" "red"
        _separator

        local choice
        read -rp "  选择 [0-7]: " choice
        case "$choice" in
            1) _mihomo_setup ;;
            2) _mihomoconf_setup ;;
            3) _mihomo_enable ;;
            4) _mihomo_restart ;;
            5) _mihomo_log ;;
            6) _mihomo_read_config ;;
            7) _mihomo_chain_proxy_manage ;;
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

    local service_file="/etc/systemd/system/sing-box.service"

    if [[ -f "$service_file" ]]; then
        _warn "systemd 服务文件已存在"
        local overwrite
        read -rp "  是否覆盖? [y/N]: " overwrite
        if [[ ! "$overwrite" =~ ^[Yy] ]]; then
            _press_any_key
            return
        fi
    fi

    _info "生成 systemd 服务文件..."
    cat > "$service_file" <<'SINGBOX_SERVICE'
[Unit]
Description=Sing-box Service
After=network.target

[Service]
User=root
ExecStart=/usr/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=5s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SINGBOX_SERVICE

    systemctl daemon-reload
    systemctl enable sing-box
    _info "已设置开机自启"

    systemctl start sing-box
    sleep 1
    if systemctl is-active --quiet sing-box; then
        _info "sing-box 已成功启动"
    else
        _error_no_exit "sing-box 启动失败，请检查: systemctl status sing-box"
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

    if systemctl is-enabled sing-box.service &>/dev/null || systemctl is-active sing-box.service &>/dev/null; then
        _info "通过 systemd 重启 sing-box..."
        systemctl daemon-reload
        systemctl restart sing-box
        sleep 1
        if systemctl is-active --quiet sing-box; then
            _info "sing-box 已成功重启"
        else
            _error_no_exit "sing-box 重启失败，请检查 systemctl status sing-box"
        fi
    else
        local pid
        pid=$(pgrep -x sing-box 2>/dev/null || true)
        if [[ -n "$pid" ]]; then
            _info "终止旧进程 (PID: $pid)..."
            kill "$pid" 2>/dev/null
            sleep 1
        fi
        _info "启动 sing-box..."
        nohup sing-box run -c /etc/sing-box/config.json >/dev/null 2>&1 &
        sleep 1
        if pgrep -x sing-box &>/dev/null; then
            _info "sing-box 已成功启动 (PID: $!)"
        else
            _error_no_exit "sing-box 启动失败"
        fi
    fi

    _press_any_key
}

_singbox_status() {
    _header "Sing-Box 运行状态"

    echo ""
    if systemctl is-enabled sing-box.service &>/dev/null || systemctl is-active sing-box.service &>/dev/null; then
        systemctl status sing-box --no-pager
    else
        local pid
        pid=$(pgrep -x sing-box 2>/dev/null || true)
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
    if systemctl is-enabled sing-box.service &>/dev/null || systemctl is-active sing-box.service &>/dev/null; then
        _info "显示最近 50 行日志 (Ctrl+C 退出实时跟踪)"
        _separator
        echo ""
        journalctl -u sing-box --no-pager -n 50
        echo ""
        _separator
        local follow
        read -rp "  是否实时跟踪日志? [y/N]: " follow
        if [[ "$follow" =~ ^[Yy] ]]; then
            echo ""
            _info "按 Ctrl+C 退出实时日志..."
            echo ""
            journalctl -u sing-box -f
        fi
    else
        _warn "sing-box 未使用 systemd 管理，无法通过 journalctl 查看日志"
        _info "提示: 可以通过选项2「配置自启并启动」来设置 systemd 服务"
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
        _menu_pair "5" "查看日志" "" "green" "0" "返回主菜单" "" "red"
        _separator

        local choice
        read -rp "  选择 [0-5]: " choice
        case "$choice" in
            1) _singbox_setup ;;
            2) _singbox_enable ;;
            3) _singbox_restart ;;
            4) _singbox_status ;;
            5) _singbox_log ;;
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

    if _acme_cmd --install-cert -d "$domain" \
        --key-file "${cert_dir}/cert.key" \
        --fullchain-file "${cert_dir}/cert.crt" \
        --reloadcmd "systemctl restart mihomo >/dev/null 2>&1 || true"; then
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

    if _acme_cmd --install-cert -d "$domain" \
        --key-file "${cert_dir}/cert.key" \
        --fullchain-file "${cert_dir}/cert.crt" \
        --reloadcmd "systemctl restart mihomo >/dev/null 2>&1 || true"; then
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

# --- 10. Akile DNS 解锁检测与配置 ---

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

# --- 11. Linux DNS 管理 ---

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
    if command -v systemctl >/dev/null 2>&1; then
        local state
        state=$(systemctl show -p LoadState --value "${svc}.service" 2>/dev/null || true)
        [ -n "$state" ] && [ "$state" != "not-found" ]
        return
    fi
    if command -v service >/dev/null 2>&1; then
        service "$svc" status >/dev/null 2>&1
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
    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart "$svc" >/dev/null 2>&1
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

# --- 12. Swap 管理 ---

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

    if systemctl is-active ssh >/dev/null 2>&1 || systemctl is-enabled ssh >/dev/null 2>&1; then
        systemctl restart ssh 2>/dev/null || _warn "重启 ssh 失败，请手动执行: systemctl restart ssh"
    elif systemctl is-active sshd >/dev/null 2>&1 || systemctl is-enabled sshd >/dev/null 2>&1; then
        systemctl restart sshd 2>/dev/null || _warn "重启 sshd 失败，请手动执行: systemctl restart sshd"
    else
        _warn "未检测到 ssh/sshd systemd 服务，请手动重启 SSH 服务"
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

    cp "$tmp_file" "$INSTALL_PATH"
    chmod +x "$INSTALL_PATH"
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

    # 如果已经是从 INSTALL_PATH 运行的，跳过
    if [[ "$(readlink -f "$INSTALL_PATH" 2>/dev/null)" == "$self" ]] || \
       [[ "$self" == "$INSTALL_PATH" ]]; then
        return
    fi

    # 检查源文件是否可读（防止管道运行时 $0 不可用）
    if [[ ! -f "$self" ]] || [[ ! -r "$self" ]]; then
        return
    fi

    # 如果目标不存在，或者源文件更新了，则安装/更新
    if [[ ! -f "$INSTALL_PATH" ]]; then
        install -m 0755 "$self" "$INSTALL_PATH"
        _info "已安装到 ${INSTALL_PATH}，后续可直接输入 vpsgo 启动"
    elif [[ "$self" -nt "$INSTALL_PATH" ]] || ! cmp -s "$self" "$INSTALL_PATH"; then
        install -m 0755 "$self" "$INSTALL_PATH"
        _info "已更新 ${INSTALL_PATH}"
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
    _menu_item "4" "代理工具助手" "Mihomo/Sing-Box" "green"
    _separator
    _menu_item "u" "更新 VPSGo" "从 Github 更新" "cyan"
    _menu_item "x" "卸载 VPSGo" "" "red"
    _menu_item "0" "退出脚本" "" "red"
    _separator
}

_network_opt_menu() {
    while true; do
        _header "网络优化"
        _menu_pair "1" "开启 BBR" "安装内核 BBR" "green" "2" "队列调度算法" "fq/cake/fq_pie" "green"
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
        _menu_item "3" "启用 root SSH 登录" "设密/放行/复制密钥" "green"
        _separator
        _menu_item "0" "返回主菜单" "" "red"
        _separator
        local ch
        read -rp "  选择 [0-3]: " ch
        case "$ch" in
            1) _dockerlog_setup ;;
            2) _swap_setup ;;
            3) _rootssh_enable ;;
            0) return ;;
            *) _error_no_exit "无效选项: ${ch}"; sleep 1 ;;
        esac
    done
}

_proxy_tools_menu() {
    while true; do
        _header "代理工具助手"
        _menu_pair "1" "Mihomo 管理" "安装/配置/重启" "green" "2" "Sing-Box 管理" "安装/自启/重启" "green"
        _menu_item "3" "ACME 证书管理" "acme.sh/80端口/DNS签发" "green"
        _separator
        _menu_item "0" "返回主菜单" "" "red"
        _separator
        local ch
        read -rp "  选择 [0-3]: " ch
        case "$ch" in
            1) _mihomo_manage ;;
            2) _singbox_manage ;;
            3) _acme_manage ;;
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
