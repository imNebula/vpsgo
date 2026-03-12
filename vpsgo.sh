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

VERSION="1.29"

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
    printf "${GREEN}  ✔ ${PLAIN}%s\n" "$1"
}

_warn() {
    printf "${YELLOW}  ⚠ ${PLAIN}%s\n" "$1"
}

_error() {
    printf "${RED}  ✘ ${PLAIN}%s\n" "$1"
    exit 1
}

_error_no_exit() {
    printf "${RED}  ✘ ${PLAIN}%s\n" "$1"
}

_header() {
    echo ""
    printf "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${PLAIN}\n"
    printf "${CYAN}  %s${PLAIN}\n" "$1"
    printf "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${PLAIN}\n"
}

_separator() {
    printf "${DIM}──────────────────────────────────────────────────${PLAIN}\n"
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
    printf "${DIM}  按任意键返回主菜单...${PLAIN}"
    local SAVEDSTTY
    SAVEDSTTY=$(stty -g)
    stty -echo -icanon
    dd if=/dev/tty bs=1 count=1 2>/dev/null
    stty "$SAVEDSTTY"
    echo ""
}

_network_reboot_prompt() {
    echo ""
    _warn "建议在完成所有的网络调节后，自行重启系统以确保所有配置完全生效。"
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
    local opsy arch kern virt
    opsy="$(_os_full)"
    arch="$(uname -m) ($(getconf LONG_BIT) Bit)"
    kern="$(uname -r)"
    virt="$(_detect_virt)"

    echo ""
    printf "  ${BOLD}[ 系统信息 ]${PLAIN}\n"
    printf "    OS: ${DIM}%s${PLAIN}  Arch: ${DIM}%s${PLAIN}\n" "$opsy" "$arch"
    printf "    Kernel: ${DIM}%s${PLAIN}  Virt: ${DIM}%s${PLAIN}\n" "$kern" "$virt"
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
    echo ""
    _info "当前拥塞算法: ${cc}"
    _info "当前队列算法: ${qdisc}"

    if _bbr_check_status; then
        echo ""
        _info "TCP BBR 已经启用，无需重复操作。"
        _press_any_key
        return
    fi

    if _bbr_check_kernel; then
        echo ""
        _info "当前内核版本 >= 4.9，直接启用 BBR..."
        if _bbr_sysctl_config; then
            _info "TCP BBR 启用成功!"
        else
            _warn "BBR 配置已写入 /etc/sysctl.conf，但需重启后生效"
        fi
        echo ""
        _info "当前拥塞算法: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
        _info "当前队列算法: $(sysctl -n net.core.default_qdisc 2>/dev/null)"
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
    local current_qdisc current_cc
    current_qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"
    current_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
    _info "当前队列算法: ${current_qdisc}"
    _info "当前拥塞算法: ${current_cc}"
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

    echo ""
    _qdisc_print_status
    _qdisc_check_virt

    echo ""
    echo "  请选择要启用的队列调度算法:"
    _separator
    printf "    ${GREEN}1${PLAIN}) fq      — Fair Queuing                ${DIM}(内核 >= 3.12)${PLAIN}\n"
    printf "    ${GREEN}2${PLAIN}) cake    — Common Applications Kept Enhanced  ${DIM}(内核 >= 4.19)${PLAIN}\n"
    printf "    ${GREEN}3${PLAIN}) fq_pie  — Fair Queuing + PIE          ${DIM}(内核 >= 4.19)${PLAIN}\n"
    echo ""
    printf "    ${RED}0${PLAIN}) 返回主菜单\n"
    echo ""

    local choice
    read -rp "  请输入选项 [0-3]: " choice

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
        _info "${qdisc} 已经启用且在网卡上生效，无需重复设置。"
        _qdisc_print_status
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

    echo ""
    if _qdisc_is_enabled "$qdisc" && _qdisc_is_active_on_ifaces "$qdisc"; then
        _info "${qdisc} 启用成功并已在网卡上生效!"
        _qdisc_print_status
    elif _qdisc_is_enabled "$qdisc"; then
        _info "${qdisc} sysctl 配置已生效，部分网卡可能需要重启后应用。"
        _qdisc_print_status
    else
        _warn "已写入 sysctl 配置，但当前未检测到 ${qdisc} 生效。"
        _qdisc_print_status
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

    echo ""
    echo "  请选择操作:"
    _separator
    printf "    ${GREEN}1${PLAIN}) 设置 IPv4 优先\n"
    printf "    ${GREEN}2${PLAIN}) 设置 IPv6 优先\n"
    echo ""
    printf "    ${RED}0${PLAIN}) 返回主菜单\n"
    echo ""

    local choice
    read -rp "  请输入选项 [0-2]: " choice

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

# --- 4. TCP 缓冲区调优 ---

_TCPTUNE_SYSCTL_TARGET="/etc/sysctl.d/999-net-tcp-tune.conf"
_TCPTUNE_KEY_REGEX='^(net\.core\.rmem_max|net\.core\.wmem_max|net\.core\.rmem_default|net\.core\.wmem_default|net\.core\.netdev_max_backlog|net\.ipv4\.tcp_rmem|net\.ipv4\.tcp_wmem|net\.ipv4\.tcp_mtu_probing|net\.ipv4\.tcp_fastopen|net\.ipv4\.tcp_slow_start_after_idle|net\.ipv4\.tcp_notsent_lowat|net\.ipv4\.tcp_timestamps|net\.ipv4\.tcp_sack|net\.ipv4\.tcp_window_scaling|net\.ipv4\.tcp_adv_win_scale)[[:space:]]*='

_tcptune_detect_mem_gib() {
    local kb
    if [ -f /proc/meminfo ]; then
        kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
        awk -v k="$kb" 'BEGIN{ printf "%.1f", k/1024/1024 }'
    elif command -v sysctl >/dev/null 2>&1 && sysctl -n hw.memsize >/dev/null 2>&1; then
        awk -v b="$(sysctl -n hw.memsize)" 'BEGIN{ printf "%.1f", b/1024/1024/1024 }'
    else
        echo "1"
    fi
}

_tcptune_rtt_ping_one() {
    local my_idx="$1"
    local my_name="$2"
    local my_ip="$3"
    local rtt
    rtt=$(ping -c 3 -W 5 "$my_ip" 2>/dev/null \
          | awk '/rtt|round-trip/ { split($4,a,"/"); printf "%.1f", a[2] }')
    if [ -n "$rtt" ] && [ "$rtt" != "0" ] && [ "$rtt" != "0.0" ]; then
        echo "${my_name}|${rtt}" > "${_RTT_TMPDIR}/${my_idx}.ok"
    else
        echo "${my_name}|timeout" > "${_RTT_TMPDIR}/${my_idx}.fail"
    fi
}

_tcptune_rtt_bg_start() {
    # 在后台并发 ping 所有节点，结果写入临时文件
    _RTT_TMPDIR=$(mktemp -d)
    local entries=(
        "180.163.117.56:上海/电信"
        "211.95.52.65:上海/联通"
        "117.186.171.239:上海/移动"
        "42.81.147.213:天津/电信"
        "123.117.133.134:北京/联通"
        "111.132.43.23:北京/移动"
        "59.37.89.174:广东佛山/电信"
        "157.148.78.253:广东广州/联通"
        "120.232.97.43:广东佛山/移动"
    )
    _RTT_BG_PIDS=()
    local idx=0
    for entry in "${entries[@]}"; do
        local ip="${entry%%:*}"
        local name="${entry#*:}"
        _tcptune_rtt_ping_one "$idx" "$name" "$ip" &
        _RTT_BG_PIDS+=($!)
        idx=$((idx+1))
    done
}

_tcptune_rtt_bg_collect() {
    # 等待后台 ping 完成，显示结果并返回建议 RTT
    _info "正在等待 RTT 测量完成..."
    for pid in "${_RTT_BG_PIDS[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    local results=() min_rtt="" rtt_sum=0 rtt_count=0

    # 按序号收集结果
    local idx=0
    while [ -f "${_RTT_TMPDIR}/${idx}.ok" ] || [ -f "${_RTT_TMPDIR}/${idx}.fail" ]; do
        if [ -f "${_RTT_TMPDIR}/${idx}.ok" ]; then
            local line name rtt
            line=$(cat "${_RTT_TMPDIR}/${idx}.ok")
            name="${line%%|*}"
            rtt="${line#*|}"
            results+=("$(printf "%-14s ${GREEN}%7s ms${PLAIN}" "${name}" "${rtt}")")
            rtt_sum=$(awk -v s="$rtt_sum" -v r="$rtt" 'BEGIN{ printf "%.1f", s+r }')
            rtt_count=$((rtt_count+1))
            if [ -z "$min_rtt" ] || awk -v a="$rtt" -v b="$min_rtt" 'BEGIN{exit !(a<b)}'; then
                min_rtt="$rtt"
            fi
        elif [ -f "${_RTT_TMPDIR}/${idx}.fail" ]; then
            local line name
            line=$(cat "${_RTT_TMPDIR}/${idx}.fail")
            name="${line%%|*}"
            results+=("$(printf "%-14s ${RED}%7s   ${PLAIN}" "${name}" "超时")")
        fi
        idx=$((idx+1))
    done

    # 清理临时文件
    rm -rf "${_RTT_TMPDIR}"

    # 双列排版输出到 /dev/tty
    _separator > /dev/tty
    local total=${#results[@]}
    local half=$(( (total + 1) / 2 ))
    local i
    for (( i=0; i<half; i++ )); do
        local left="${results[$i]}"
        local right=""
        if [ $((i + half)) -lt $total ]; then
            right="${results[$((i + half))]}"
        fi
        printf "    %s    %s\n" "$left" "$right" > /dev/tty
    done

    if [ "$rtt_count" -gt 0 ]; then
        local avg_rtt avg_int
        avg_rtt=$(awk -v s="$rtt_sum" -v n="$rtt_count" 'BEGIN{ printf "%.1f", s/n }')
        avg_int=$(awk -v r="$avg_rtt" 'BEGIN{ printf "%d", (r==int(r)) ? r : int(r)+1 }')
        echo "" > /dev/tty
        printf "  ${GREEN}✔ ${PLAIN}最低: ${CYAN}%s ms${PLAIN} | 平均: ${CYAN}%s ms${PLAIN} | 建议值: ${CYAN}%s ms${PLAIN}\n" "$min_rtt" "$avg_rtt" "$avg_int" > /dev/tty
        echo "$avg_int"
    else
        printf "  ${YELLOW}⚠ ${PLAIN}所有节点均不可达\n" > /dev/tty
        echo ""
    fi
}

_tcptune_detect_cc() {
    sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown"
}

_tcptune_detect_qdisc() {
    local iface="$1" qd="unknown"
    if command -v tc >/dev/null 2>&1 && [ -n "$iface" ]; then
        qd=$(tc qdisc show dev "$iface" 2>/dev/null | awk 'NR==1{print $2}' || echo "unknown")
    fi
    echo "$qd"
}

_tcptune_default_iface() {
    ip -o -4 route show to default 2>/dev/null | awk '{print $5}' | head -1 || true
}

_tcptune_bucket_le_mb() {
    local mb="${1:-0}"
    if   [ "$mb" -ge 64 ]; then echo 64
    elif [ "$mb" -ge 32 ]; then echo 32
    elif [ "$mb" -ge 16 ]; then echo 16
    elif [ "$mb" -ge  8 ]; then echo 8
    elif [ "$mb" -ge  4 ]; then echo 4
    else echo 4
    fi
}

_tcptune_comment_conflicts_in_sysctl_conf() {
    local f="/etc/sysctl.conf"
    [ -f "$f" ] || { _info "/etc/sysctl.conf 不存在，跳过"; return 0; }
    if grep -Eq "$_TCPTUNE_KEY_REGEX" "$f"; then
        _info "注释 /etc/sysctl.conf 中的冲突键..."
        awk -v re="$_TCPTUNE_KEY_REGEX" '
            $0 ~ re && $0 !~ /^[[:space:]]*#/ { print "# " $0; next }
            { print $0 }
        ' "$f" > "${f}.tmp.$$"
        install -m 0644 "${f}.tmp.$$" "$f"
        rm -f "${f}.tmp.$$"
        _info "已注释掉冲突键"
    else
        _info "/etc/sysctl.conf 无冲突键"
    fi
}

_tcptune_comment_conflicts_in_dir() {
    local dir="$1"
    [ -d "$dir" ] || { _info "$dir 不存在，跳过"; return 0; }
    shopt -s nullglob
    local modified=0
    for f in "$dir"/*.conf; do
        [ "$(readlink -f "$f")" = "$(readlink -f "$_TCPTUNE_SYSCTL_TARGET")" ] && continue
        if grep -Eq "$_TCPTUNE_KEY_REGEX" "$f"; then
            sed -i -E '/^[[:space:]]*(net\.core\.rmem_max|net\.core\.wmem_max|net\.core\.rmem_default|net\.core\.wmem_default|net\.core\.netdev_max_backlog|net\.ipv4\.tcp_rmem|net\.ipv4\.tcp_wmem|net\.ipv4\.tcp_mtu_probing|net\.ipv4\.tcp_fastopen|net\.ipv4\.tcp_slow_start_after_idle|net\.ipv4\.tcp_notsent_lowat|net\.ipv4\.tcp_timestamps|net\.ipv4\.tcp_sack|net\.ipv4\.tcp_window_scaling|net\.ipv4\.tcp_adv_win_scale)[[:space:]]*=/ s/^/# [vpsgo] /' "$f"
            _info "已注释冲突键: $f"
            modified=1
        fi
    done
    shopt -u nullglob
    [ "$modified" -eq 1 ] && _info "$dir 冲突键已注释" || _info "$dir 无需处理"
}

_tcptune_scan_conflicts_ro() {
    local dir="$1"
    [ -d "$dir" ] || return 0
    if grep -RIlEq "$_TCPTUNE_KEY_REGEX" "$dir" 2>/dev/null; then
        _warn "发现潜在冲突（只提示不改）: $dir"
        grep -RhnE "$_TCPTUNE_KEY_REGEX" "$dir" 2>/dev/null || true
    fi
}

_tcptune_setup_fq() {
    _header "TCP 缓冲区调优 (fq 模式 - 自动优化)"

    # ---- 后台启动 RTT 测量 ----
    _tcptune_rtt_bg_start

    # ---- 检测系统内存 ----
    local MEM_G
    MEM_G="$(_tcptune_detect_mem_gib)"
    _is_digit "${MEM_G%%.*}" || MEM_G=1
    echo ""
    _info "系统内存: ${MEM_G} GiB"
    _info "RTT 测量已在后台进行..."

    # ---- 输入带宽 ----
    local BW_Mbps_INPUT BW_Mbps
    read -rp "  带宽 (Mbps) [默认 1000]: " BW_Mbps_INPUT
    BW_Mbps="${BW_Mbps_INPUT:-1000}"
    _is_digit "$BW_Mbps" || BW_Mbps=1000

    # ---- 收集 RTT 结果 ----
    echo ""
    local AUTO_RTT
    AUTO_RTT="$(_tcptune_rtt_bg_collect)"

    local RTT_ms RTT_ms_INPUT
    if [ -n "$AUTO_RTT" ]; then
        read -rp "  请输入服务器与你之间的延迟 RTT (ms) [默认 ${AUTO_RTT}]: " RTT_ms_INPUT
        RTT_ms="${RTT_ms_INPUT:-$AUTO_RTT}"
    else
        _warn "RTT 自动检测失败"
        read -rp "  请手动输入 RTT (ms) [默认 150]: " RTT_ms_INPUT
        RTT_ms="${RTT_ms_INPUT:-150}"
    fi
    _is_digit "$RTT_ms" || RTT_ms=150

    # ---- 计算 BDP ----
    local BDP_BYTES MEM_BYTES TWO_BDP RAM_LIMIT_BYTES HARD_CAP MAX_NUM_BYTES
    BDP_BYTES=$(awk -v bw="$BW_Mbps" -v rtt="$RTT_ms" 'BEGIN{ printf "%.0f", bw*125*rtt }')
    MEM_BYTES=$(awk -v g="$MEM_G" 'BEGIN{ printf "%.0f", g*1024*1024*1024 }')
    TWO_BDP=$(( BDP_BYTES * 2 ))
    # 内存限制：RAM ≤ 2GB 用 3%，> 2GB 用 5%，保底 32MB
    RAM_LIMIT_BYTES=$(awk -v m="$MEM_BYTES" 'BEGIN{
        if (m <= 2*1024*1024*1024) limit=m*0.03; else limit=m*0.05
        if (limit < 33554432) limit=33554432
        printf "%.0f", limit
    }')
    if [ "$BW_Mbps" -gt 4000 ]; then
        HARD_CAP=$(( 128 * 1024 * 1024 ))
    elif [ "$BW_Mbps" -gt 1000 ]; then
        HARD_CAP=$(( 64 * 1024 * 1024 ))
    else
        HARD_CAP=$(( 32 * 1024 * 1024 ))
    fi
    MAX_NUM_BYTES=$(awk -v a="$TWO_BDP" -v b="$RAM_LIMIT_BYTES" -v c="$HARD_CAP" 'BEGIN{ m=a; if(b<m)m=b; if(c<m)m=c; printf "%.0f", m }')

    local MAX_MB MAX_BYTES
    MAX_MB=$(( MAX_NUM_BYTES / 1024 / 1024 ))
    [ "$MAX_MB" -lt 8 ] && MAX_MB=8
    MAX_BYTES=$(( MAX_MB * 1024 * 1024 ))

    local DEF_R DEF_W
    if [ "$MAX_MB" -ge 32 ]; then
        DEF_R=262144; DEF_W=524288
    elif [ "$MAX_MB" -ge 8 ]; then
        DEF_R=131072; DEF_W=262144
    else
        DEF_R=131072; DEF_W=131072
    fi

    local TCP_RMEM_MIN=4096 TCP_RMEM_DEF=131072 TCP_RMEM_MAX=$MAX_BYTES
    local TCP_WMEM_MIN=4096 TCP_WMEM_DEF=131072 TCP_WMEM_MAX=$MAX_BYTES

    # ---- 检测拥塞算法 ----
    local CURRENT_CC
    CURRENT_CC="$(_tcptune_detect_cc)"

    local IS_BBR=0
    case "$CURRENT_CC" in
        bbr|bbr2|bbr3) IS_BBR=1 ;;
    esac

    echo ""
    _info "拥塞算法: ${CURRENT_CC}"
    _info "BDP: $(awk -v b="$BDP_BYTES" 'BEGIN{ printf "%.2f", b/1024/1024 }') MB | 桶值: ${MAX_MB} MB"

    # ---- 自适应参数 ----
    local NOTSENT_LOWAT="" SLOW_START_IDLE=""

    if [ "$IS_BBR" -eq 1 ]; then
        SLOW_START_IDLE=0
        # notsent_lowat = clamp(BDP/8, 16KB, 256KB)
        NOTSENT_LOWAT=$(awk -v bdp="$BDP_BYTES" 'BEGIN{
            v = bdp / 8
            if (v < 16384) v = 16384
            if (v > 262144) v = 262144
            printf "%.0f", v
        }')
        _info "BBR 模式: 禁用 slow_start_after_idle, notsent_lowat=${NOTSENT_LOWAT}"
        echo ""
        local LOWAT_SKIP
        read -rp "  跳过 notsent_lowat 设置 (吞吐优先)? [y/N]: " LOWAT_SKIP
        if [[ "$LOWAT_SKIP" =~ ^[Yy] ]]; then
            NOTSENT_LOWAT=""
            _info "已跳过 notsent_lowat"
        fi
    else
        _info "非 BBR (${CURRENT_CC}): 仅调缓冲区"
    fi

    local BACKLOG
    if [ "$BW_Mbps" -ge 10000 ]; then
        BACKLOG=16384
    elif [ "$BW_Mbps" -ge 1000 ]; then
        BACKLOG=8192
    else
        BACKLOG=4096
    fi

    # ---- 冲突清理 ----
    echo ""
    _info "清理冲突配置..."
    _separator
    _tcptune_comment_conflicts_in_sysctl_conf
    _tcptune_comment_conflicts_in_dir "/etc/sysctl.d"
    _tcptune_scan_conflicts_ro "/usr/local/lib/sysctl.d"
    _tcptune_scan_conflicts_ro "/usr/lib/sysctl.d"
    _tcptune_scan_conflicts_ro "/lib/sysctl.d"
    _tcptune_scan_conflicts_ro "/run/sysctl.d"

    # ---- 写入配置 ----
    local tmpf
    tmpf="$(mktemp)"
    cat >"$tmpf" <<TCPTUNE_EOF
# Auto-generated by VPSGo TCP Tune
# Inputs: MEM_G=${MEM_G}GiB, BW=${BW_Mbps}Mbps, RTT=${RTT_ms}ms
# BDP: ${BDP_BYTES} bytes (~$(awk -v b="$BDP_BYTES" 'BEGIN{ printf "%.2f", b/1024/1024 }') MB)
# Caps: clamp(2*BDP, 8MB, min(RAM_cap, BW_cap)) -> Bucket ${MAX_MB} MB
# Detected CC: ${CURRENT_CC}

# ---- 核心缓冲区 ----
net.core.rmem_default = ${DEF_R}
net.core.wmem_default = ${DEF_W}
net.core.rmem_max = ${MAX_BYTES}
net.core.wmem_max = ${MAX_BYTES}
net.core.netdev_max_backlog = ${BACKLOG}

# ---- TCP 缓冲区 ----
net.ipv4.tcp_rmem = ${TCP_RMEM_MIN} ${TCP_RMEM_DEF} ${TCP_RMEM_MAX}
net.ipv4.tcp_wmem = ${TCP_WMEM_MIN} ${TCP_WMEM_DEF} ${TCP_WMEM_MAX}

# ---- 通用优化 ----
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_window_scaling = 1
TCPTUNE_EOF

    if [ -n "$SLOW_START_IDLE" ]; then
        cat >>"$tmpf" <<TCPTUNE_EOF

# BBR: 禁用 idle 后慢启动重置
net.ipv4.tcp_slow_start_after_idle = ${SLOW_START_IDLE}
TCPTUNE_EOF
    fi

    if [ -n "$NOTSENT_LOWAT" ]; then
        cat >>"$tmpf" <<TCPTUNE_EOF

# 控制未发送数据上限，减少 bufferbloat
net.ipv4.tcp_notsent_lowat = ${NOTSENT_LOWAT}
TCPTUNE_EOF
    fi

    install -m 0644 "$tmpf" "$_TCPTUNE_SYSCTL_TARGET"
    rm -f "$tmpf"
    sysctl --system >/dev/null

    # ---- 显示结果 ----
    echo ""
    _header "调优完成"
    echo ""
    printf "  ${BOLD}输入参数${PLAIN}\n"
    printf "    带宽: ${CYAN}%s Mbps${PLAIN}  RTT: ${CYAN}%s ms${PLAIN}  内存: ${CYAN}%s GiB${PLAIN}\n" "$BW_Mbps" "$RTT_ms" "$MEM_G"
    printf "    BDP: ${CYAN}$(awk -v b="$BDP_BYTES" 'BEGIN{ printf "%.2f", b/1024/1024 }') MB${PLAIN}  桶值: ${CYAN}${MAX_MB} MB${PLAIN}  CC: ${CYAN}${CURRENT_CC}${PLAIN}\n"
    echo ""
    _separator
    printf "  ${BOLD}核心缓冲区${PLAIN}\n"
    printf "    %-20s ${GREEN}%s${PLAIN}\n" "rmem_default"   "$(sysctl -n net.core.rmem_default 2>/dev/null)"
    printf "    %-20s ${GREEN}%s${PLAIN}\n" "wmem_default"   "$(sysctl -n net.core.wmem_default 2>/dev/null)"
    printf "    %-20s ${GREEN}%s${PLAIN}\n" "rmem_max"       "$(sysctl -n net.core.rmem_max 2>/dev/null)"
    printf "    %-20s ${GREEN}%s${PLAIN}\n" "wmem_max"       "$(sysctl -n net.core.wmem_max 2>/dev/null)"
    printf "    %-20s ${GREEN}%s${PLAIN}\n" "backlog"        "$(sysctl -n net.core.netdev_max_backlog 2>/dev/null)"
    echo ""
    printf "  ${BOLD}TCP 缓冲区${PLAIN}\n"
    printf "    %-20s ${GREEN}%s${PLAIN}\n" "tcp_rmem"       "$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null)"
    printf "    %-20s ${GREEN}%s${PLAIN}\n" "tcp_wmem"       "$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null)"
    echo ""
    printf "  ${BOLD}通用优化${PLAIN}\n"
    printf "    %-20s ${GREEN}%s${PLAIN}\n" "mtu_probing"    "$(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null)"
    printf "    %-20s ${GREEN}%s${PLAIN}\n" "fastopen"       "$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null)"
    printf "    %-20s ${GREEN}%s${PLAIN}\n" "timestamps"     "$(sysctl -n net.ipv4.tcp_timestamps 2>/dev/null)"
    printf "    %-20s ${GREEN}%s${PLAIN}\n" "sack"           "$(sysctl -n net.ipv4.tcp_sack 2>/dev/null)"
    printf "    %-20s ${GREEN}%s${PLAIN}\n" "window_scaling" "$(sysctl -n net.ipv4.tcp_window_scaling 2>/dev/null)"
    if [ "$IS_BBR" -eq 1 ]; then
        echo ""
        printf "  ${BOLD}BBR 参数${PLAIN}\n"
        printf "    %-20s ${GREEN}%s${PLAIN}\n" "slow_start_idle" "$(sysctl -n net.ipv4.tcp_slow_start_after_idle 2>/dev/null)"
        printf "    %-20s ${GREEN}%s${PLAIN}\n" "notsent_lowat"   "$(sysctl -n net.ipv4.tcp_notsent_lowat 2>/dev/null || echo N/A)"
    fi
    echo ""
    _separator
    _info "配置已写入: ${_TCPTUNE_SYSCTL_TARGET}"
    _info "配置已生效，重启后仍然有效"

    _network_reboot_prompt
    _press_any_key
}

_tcptune_manual_bucket() {
    _header "手动修改 TCP 缓冲区桶值"

    echo ""
    _info "桶值 = TCP 缓冲区最大值，决定单连接最大吞吐量"
    _info "理论最大速度 ≈ 桶值 / RTT (例: 16MB/100ms = 160MB/s = 1.28Gbps)"
    echo ""
    printf "  ${BOLD}可选桶值 (MB):${PLAIN}\n"
    _separator
    printf "    ${GREEN}4${PLAIN}   — 低延迟(<20ms) + 低带宽(<500Mbps) 或内存受限\n"
    printf "    ${GREEN}8${PLAIN}   — 低延迟(<30ms) + 中带宽(500Mbps-1Gbps)\n"
    printf "    ${GREEN}16${PLAIN}  — 中延迟(30-80ms) + 1Gbps 或 低延迟 + 2Gbps\n"
    printf "    ${GREEN}32${PLAIN}  — 高延迟(80-150ms) + 1-2Gbps 或 中延迟 + 3-5Gbps\n"
    printf "    ${GREEN}64${PLAIN}  — 高延迟(>150ms) + 高带宽(>2Gbps) 或跨国线路\n"
    echo ""
    printf "  ${DIM}提示: BDP = 带宽 × RTT，桶值应 ≥ 2×BDP 才能跑满带宽${PLAIN}\n"
    echo ""

    local BUCKET_MB
    while true; do
        read -rp "  请输入桶值 (4/8/16/32/64) [默认: 16]: " BUCKET_MB
        BUCKET_MB="${BUCKET_MB:-16}"

        # 验证输入是否合法
        case "$BUCKET_MB" in
            4|8|16|32|64)
                break
                ;;
            *)
                _error_no_exit "无效的桶值: ${BUCKET_MB}，请输入 4, 8, 16, 32 或 64"
                ;;
        esac
    done

    local MAX_BYTES=$(( BUCKET_MB * 1024 * 1024 ))
    local DEF_R DEF_W

    if [ "$BUCKET_MB" -ge 32 ]; then
        DEF_R=262144; DEF_W=524288
    elif [ "$BUCKET_MB" -ge 8 ]; then
        DEF_R=131072; DEF_W=262144
    else
        DEF_R=131072; DEF_W=131072
    fi

    local TCP_RMEM_MIN=4096 TCP_RMEM_DEF=131072 TCP_RMEM_MAX=$MAX_BYTES
    local TCP_WMEM_MIN=4096 TCP_WMEM_DEF=131072 TCP_WMEM_MAX=$MAX_BYTES

    # 检测拥塞算法
    local CURRENT_CC
    CURRENT_CC="$(_tcptune_detect_cc)"

    local BACKLOG
    if [ "$BUCKET_MB" -ge 32 ]; then
        BACKLOG=16384
    elif [ "$BUCKET_MB" -ge 16 ]; then
        BACKLOG=8192
    else
        BACKLOG=4096
    fi

    echo ""
    _info "拥塞算法: ${CURRENT_CC}"
    _info "桶值: ${BUCKET_MB} MB"

    # 确认配置
    echo ""
    _separator
    printf "  ${BOLD}配置信息确认${PLAIN}\n"
    printf "    桶值     : ${CYAN}%s MB${PLAIN}\n" "$BUCKET_MB"
    printf "    拥塞算法 : ${CYAN}%s${PLAIN}\n" "$CURRENT_CC"
    printf "    rmem_max : ${CYAN}%s${PLAIN}\n" "$MAX_BYTES"
    printf "    wmem_max : ${CYAN}%s${PLAIN}\n" "$MAX_BYTES"
    _separator
    echo ""

    local CONFIRM
    read -rp "  是否确认应用该配置？(y/n): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        _warn "已取消配置，未做任何更改。"
        _press_any_key
        return
    fi

    # 冲突清理
    echo ""
    _info "清理冲突配置..."
    _separator
    _tcptune_comment_conflicts_in_sysctl_conf
    _tcptune_comment_conflicts_in_dir "/etc/sysctl.d"
    _tcptune_scan_conflicts_ro "/usr/local/lib/sysctl.d"
    _tcptune_scan_conflicts_ro "/usr/lib/sysctl.d"
    _tcptune_scan_conflicts_ro "/lib/sysctl.d"
    _tcptune_scan_conflicts_ro "/run/sysctl.d"

    # 写入配置
    local tmpf
    tmpf="$(mktemp)"
    cat >"$tmpf" <<TCPTUNE_EOF
# Auto-generated by VPSGo TCP Tune (Manual Bucket Mode)
# Manual Bucket: ${BUCKET_MB} MB
# Detected CC: ${CURRENT_CC}

# ---- 核心缓冲区 ----
net.core.rmem_default = ${DEF_R}
net.core.wmem_default = ${DEF_W}
net.core.rmem_max = ${MAX_BYTES}
net.core.wmem_max = ${MAX_BYTES}
net.core.netdev_max_backlog = ${BACKLOG}

# ---- TCP 缓冲区 ----
net.ipv4.tcp_rmem = ${TCP_RMEM_MIN} ${TCP_RMEM_DEF} ${TCP_RMEM_MAX}
net.ipv4.tcp_wmem = ${TCP_WMEM_MIN} ${TCP_WMEM_DEF} ${TCP_WMEM_MAX}

# ---- 通用优化 ----
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_window_scaling = 1
TCPTUNE_EOF

    install -m 0644 "$tmpf" "$_TCPTUNE_SYSCTL_TARGET"
    rm -f "$tmpf"
    sysctl --system >/dev/null

    # 显示结果
    echo ""
    _header "调优完成 (手动桶值模式)"
    echo ""
    printf "  ${BOLD}配置参数${PLAIN}\n"
    printf "    桶值: ${CYAN}${BUCKET_MB} MB${PLAIN}  CC: ${CYAN}${CURRENT_CC}${PLAIN}\n"
    echo ""
    _separator
    printf "  ${BOLD}核心缓冲区${PLAIN}\n"
    printf "    %-20s ${GREEN}%s${PLAIN}\n" "rmem_default"   "$(sysctl -n net.core.rmem_default 2>/dev/null)"
    printf "    %-20s ${GREEN}%s${PLAIN}\n" "wmem_default"   "$(sysctl -n net.core.wmem_default 2>/dev/null)"
    printf "    %-20s ${GREEN}%s${PLAIN}\n" "rmem_max"       "$(sysctl -n net.core.rmem_max 2>/dev/null)"
    printf "    %-20s ${GREEN}%s${PLAIN}\n" "wmem_max"       "$(sysctl -n net.core.wmem_max 2>/dev/null)"
    printf "    %-20s ${GREEN}%s${PLAIN}\n" "backlog"        "$(sysctl -n net.core.netdev_max_backlog 2>/dev/null)"
    echo ""
    printf "  ${BOLD}TCP 缓冲区${PLAIN}\n"
    printf "    %-20s ${GREEN}%s${PLAIN}\n" "tcp_rmem"       "$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null)"
    printf "    %-20s ${GREEN}%s${PLAIN}\n" "tcp_wmem"       "$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null)"
    echo ""
    printf "  ${BOLD}通用优化${PLAIN}\n"
    printf "    %-20s ${GREEN}%s${PLAIN}\n" "mtu_probing"    "$(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null)"
    printf "    %-20s ${GREEN}%s${PLAIN}\n" "fastopen"       "$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null)"
    printf "    %-20s ${GREEN}%s${PLAIN}\n" "timestamps"     "$(sysctl -n net.ipv4.tcp_timestamps 2>/dev/null)"
    printf "    %-20s ${GREEN}%s${PLAIN}\n" "sack"           "$(sysctl -n net.ipv4.tcp_sack 2>/dev/null)"
    printf "    %-20s ${GREEN}%s${PLAIN}\n" "window_scaling" "$(sysctl -n net.ipv4.tcp_window_scaling 2>/dev/null)"
    echo ""
    _separator
    _info "配置已写入: ${_TCPTUNE_SYSCTL_TARGET}"
    _info "配置已生效，重启后仍然有效"

    _network_reboot_prompt
    _press_any_key
}

_tcptune_setup_cake() {
    local CAKE_IFACE="$1"
    local CAKE_SERVICE_FILE="/etc/systemd/system/set-cake.service"
    local CAKE_SCRIPT_FILE="/usr/local/bin/set-cake.sh"

    _header "CAKE 队列 + TCP 缓冲区调优 (自动模式)"

    # ---- 后台启动 RTT 测量 ----
    _tcptune_rtt_bg_start

    # ---- 检测系统内存 ----
    local MEM_G
    MEM_G="$(_tcptune_detect_mem_gib)"
    _is_digit "${MEM_G%%.*}" || MEM_G=1
    echo ""
    _info "系统内存: ${MEM_G} GiB"
    _info "网卡接口: ${CAKE_IFACE}"
    _info "RTT 测量已在后台进行..."

    # ---- CAKE: NAT 模式 ----
    local NAT_CHOICE NAT_MODE
    read -rp "  是否为 NAT 机器？(y/n) [默认: n]: " NAT_CHOICE
    case "$NAT_CHOICE" in
        [Yy]) NAT_MODE="nat" ;;
        [Nn]|"") NAT_MODE="nonat" ;;
        *) _info "输入无效，默认使用 nonat"; NAT_MODE="nonat" ;;
    esac

    # ---- CAKE: 链路类型 (默认 ethernet) ----
    local CAKE_LINK_OPTS="ethernet"

    # ---- CAKE: ACK 过滤 ----
    echo ""
    echo "  ACK 过滤 (仅对称链路建议关闭):"
    _separator
    printf "    ${GREEN}1${PLAIN}) 关闭 (no-ack-filter)  ${DIM}— 对称链路/默认推荐${PLAIN}\n"
    printf "    ${GREEN}2${PLAIN}) 开启 (ack-filter)     ${DIM}— 上行带宽显著小于下行时使用${PLAIN}\n"
    echo ""
    local ACK_CHOICE CAKE_ACK_OPT
    read -rp "  请选择 [1-2，默认 1]: " ACK_CHOICE
    case "${ACK_CHOICE:-1}" in
        2) CAKE_ACK_OPT="ack-filter" ;;
        *) CAKE_ACK_OPT="no-ack-filter" ;;
    esac

    # ---- 输入带宽 ----
    local BW_Mbps_INPUT BW_Mbps CAKE_BW
    read -rp "  带宽 (Mbps) [默认 1000]: " BW_Mbps_INPUT
    BW_Mbps="${BW_Mbps_INPUT:-1000}"
    _is_digit "$BW_Mbps" || BW_Mbps=1000
    # CAKE 整形带宽取实测值 93%，避免队列 overflow
    local CAKE_BW_VAL
    CAKE_BW_VAL=$(awk -v bw="$BW_Mbps" 'BEGIN{ printf "%.0f", bw * 0.93 }')
    CAKE_BW="${CAKE_BW_VAL}mbit"
    _info "CAKE 整形带宽: ${CAKE_BW} (原始 ${BW_Mbps}Mbps × 93%)"

    # ---- 收集 RTT 结果 ----
    echo ""
    local AUTO_RTT
    AUTO_RTT="$(_tcptune_rtt_bg_collect)"

    local RTT_ms RTT_ms_INPUT
    if [ -n "$AUTO_RTT" ]; then
        read -rp "  请输入服务器与你之间的延迟 RTT (ms) [默认 ${AUTO_RTT}]: " RTT_ms_INPUT
        RTT_ms="${RTT_ms_INPUT:-$AUTO_RTT}"
    else
        _warn "RTT 自动检测失败"
        read -rp "  请手动输入 RTT (ms) [默认: 150]: " RTT_ms_INPUT
        RTT_ms="${RTT_ms_INPUT:-150}"
    fi
    _is_digit "$RTT_ms" || RTT_ms=150

    # ---- 计算 BDP ----
    local BDP_BYTES MEM_BYTES TWO_BDP RAM_LIMIT_BYTES HARD_CAP MAX_NUM_BYTES
    BDP_BYTES=$(awk -v bw="$BW_Mbps" -v rtt="$RTT_ms" 'BEGIN{ printf "%.0f", bw*125*rtt }')
    MEM_BYTES=$(awk -v g="$MEM_G" 'BEGIN{ printf "%.0f", g*1024*1024*1024 }')
    TWO_BDP=$(( BDP_BYTES * 2 ))
    # 内存限制：RAM ≤ 2GB 用 3%，> 2GB 用 5%，保底 32MB
    RAM_LIMIT_BYTES=$(awk -v m="$MEM_BYTES" 'BEGIN{
        if (m <= 2*1024*1024*1024) limit=m*0.03; else limit=m*0.05
        if (limit < 33554432) limit=33554432
        printf "%.0f", limit
    }')
    # 硬上限分档（代理服务器并发友好）：BW ≤ 1G → 32MB，≤ 4G → 64MB，> 4G → 128MB
    if [ "$BW_Mbps" -gt 4000 ]; then
        HARD_CAP=$(( 128 * 1024 * 1024 ))
    elif [ "$BW_Mbps" -gt 1000 ]; then
        HARD_CAP=$(( 64 * 1024 * 1024 ))
    else
        HARD_CAP=$(( 32 * 1024 * 1024 ))
    fi
    MAX_NUM_BYTES=$(awk -v a="$TWO_BDP" -v b="$RAM_LIMIT_BYTES" -v c="$HARD_CAP" 'BEGIN{ m=a; if(b<m)m=b; if(c<m)m=c; printf "%.0f", m }')

    local MAX_MB MAX_BYTES
    MAX_MB=$(( MAX_NUM_BYTES / 1024 / 1024 ))
    [ "$MAX_MB" -lt 8 ] && MAX_MB=8
    MAX_BYTES=$(( MAX_MB * 1024 * 1024 ))

    local DEF_R DEF_W
    if [ "$MAX_MB" -ge 32 ]; then
        DEF_R=262144; DEF_W=524288
    elif [ "$MAX_MB" -ge 8 ]; then
        DEF_R=131072; DEF_W=262144
    else
        DEF_R=131072; DEF_W=131072
    fi

    local TCP_RMEM_MIN=4096 TCP_RMEM_DEF=131072 TCP_RMEM_MAX=$MAX_BYTES
    local TCP_WMEM_MIN=4096 TCP_WMEM_DEF=131072 TCP_WMEM_MAX=$MAX_BYTES

    # ---- 检测拥塞算法 ----
    local CURRENT_CC
    CURRENT_CC="$(_tcptune_detect_cc)"

    local IS_BBR=0
    case "$CURRENT_CC" in
        bbr|bbr2|bbr3) IS_BBR=1 ;;
    esac

    echo ""
    _info "拥塞算法: ${CURRENT_CC}"
    _info "BDP: $(awk -v b="$BDP_BYTES" 'BEGIN{ printf "%.2f", b/1024/1024 }') MB | 桶值: ${MAX_MB} MB"

    # ---- 自适应参数 ----
    local NOTSENT_LOWAT="" SLOW_START_IDLE=""

    if [ "$IS_BBR" -eq 1 ]; then
        SLOW_START_IDLE=0
        # notsent_lowat = clamp(BDP/8, 16KB, 256KB)
        NOTSENT_LOWAT=$(awk -v bdp="$BDP_BYTES" 'BEGIN{
            v = bdp / 8
            if (v < 16384) v = 16384
            if (v > 262144) v = 262144
            printf "%.0f", v
        }')
        _info "BBR 模式: 禁用 slow_start_after_idle, notsent_lowat=${NOTSENT_LOWAT}"
        echo ""
        local LOWAT_SKIP
        read -rp "  跳过 notsent_lowat 设置 (吞吐优先)? [y/N]: " LOWAT_SKIP
        if [[ "$LOWAT_SKIP" =~ ^[Yy] ]]; then
            NOTSENT_LOWAT=""
            _info "已跳过 notsent_lowat"
        fi
    else
        _info "非 BBR (${CURRENT_CC}): 仅调缓冲区"
    fi

    local BACKLOG
    if [ "$BW_Mbps" -ge 10000 ]; then
        BACKLOG=16384
    elif [ "$BW_Mbps" -ge 1000 ]; then
        BACKLOG=8192
    else
        BACKLOG=4096
    fi

    # ---- 确认配置 ----
    echo ""
    _separator
    printf "  ${BOLD}配置信息确认${PLAIN}\n"
    printf "    网卡接口 : ${CYAN}%s${PLAIN}\n" "$CAKE_IFACE"
    printf "    NAT 模式 : ${CYAN}%s${PLAIN}\n" "$NAT_MODE"
    printf "    带宽     : ${CYAN}%s${PLAIN}\n" "$CAKE_BW"
    printf "    RTT      : ${CYAN}%s ms${PLAIN}\n" "$RTT_ms"
    printf "    链路类型 : ${CYAN}%s${PLAIN}\n" "$CAKE_LINK_OPTS"
    printf "    ACK 过滤 : ${CYAN}%s${PLAIN}\n" "$CAKE_ACK_OPT"
    printf "    桶值     : ${CYAN}%s MB${PLAIN}\n" "$MAX_MB"
    _separator
    echo ""

    local CONFIRM
    read -rp "  是否确认应用该配置？(y/n): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        _warn "已取消配置，未做任何更改。"
        _press_any_key
        return
    fi

    # ---- 冲突清理 ----
    echo ""
    _info "清理冲突配置..."
    _separator
    _tcptune_comment_conflicts_in_sysctl_conf
    _tcptune_comment_conflicts_in_dir "/etc/sysctl.d"
    _tcptune_scan_conflicts_ro "/usr/local/lib/sysctl.d"
    _tcptune_scan_conflicts_ro "/usr/lib/sysctl.d"
    _tcptune_scan_conflicts_ro "/lib/sysctl.d"
    _tcptune_scan_conflicts_ro "/run/sysctl.d"

    # ---- 写入 TCP sysctl 配置 ----
    local tmpf
    tmpf="$(mktemp)"
    cat >"$tmpf" <<TCPTUNE_EOF
# Auto-generated by VPSGo TCP Tune (CAKE mode)
# Inputs: MEM_G=${MEM_G}GiB, BW=${BW_Mbps}Mbps, RTT=${RTT_ms}ms
# BDP: ${BDP_BYTES} bytes (~$(awk -v b="$BDP_BYTES" 'BEGIN{ printf "%.2f", b/1024/1024 }') MB)
# Caps: clamp(2*BDP, 8MB, min(RAM_cap, BW_cap)) -> Bucket ${MAX_MB} MB
# Detected CC: ${CURRENT_CC}, Qdisc: cake

# ---- 核心缓冲区 ----
net.core.rmem_default = ${DEF_R}
net.core.wmem_default = ${DEF_W}
net.core.rmem_max = ${MAX_BYTES}
net.core.wmem_max = ${MAX_BYTES}
net.core.netdev_max_backlog = ${BACKLOG}

# ---- TCP 缓冲区 ----
net.ipv4.tcp_rmem = ${TCP_RMEM_MIN} ${TCP_RMEM_DEF} ${TCP_RMEM_MAX}
net.ipv4.tcp_wmem = ${TCP_WMEM_MIN} ${TCP_WMEM_DEF} ${TCP_WMEM_MAX}

# ---- 通用优化 ----
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_window_scaling = 1
TCPTUNE_EOF

    if [ -n "$SLOW_START_IDLE" ]; then
        cat >>"$tmpf" <<TCPTUNE_EOF

# BBR: 禁用 idle 后慢启动重置
net.ipv4.tcp_slow_start_after_idle = ${SLOW_START_IDLE}
TCPTUNE_EOF
    fi

    if [ -n "$NOTSENT_LOWAT" ]; then
        cat >>"$tmpf" <<TCPTUNE_EOF

# 控制未发送数据上限，减少 bufferbloat
net.ipv4.tcp_notsent_lowat = ${NOTSENT_LOWAT}
TCPTUNE_EOF
    fi

    install -m 0644 "$tmpf" "$_TCPTUNE_SYSCTL_TARGET"
    rm -f "$tmpf"
    sysctl --system >/dev/null

    # ---- 生成 CAKE 配置脚本 ----
    _info "生成 CAKE 配置脚本: ${CAKE_SCRIPT_FILE}"
    cat > "$CAKE_SCRIPT_FILE" <<CAKESCRIPT_EOF
#!/bin/bash
# Auto-generated by VPSGo — CAKE qdisc setup

IFACE="${CAKE_IFACE}"

# 删除旧的 qdisc（避免重复添加）
tc qdisc del dev "\$IFACE" root 2>/dev/null

# 添加 CAKE 队列规则
tc qdisc add dev "\$IFACE" root cake \\
    bandwidth ${CAKE_BW} \\
    rtt ${RTT_ms}ms \\
    besteffort \\
    ${NAT_MODE} \\
    triple-isolate \\
    ${CAKE_ACK_OPT} \\
    split-gso \\
    ${CAKE_LINK_OPTS} \\
    wash
CAKESCRIPT_EOF
    chmod +x "$CAKE_SCRIPT_FILE"

    # ---- 生成 systemd service ----
    _info "生成 systemd 服务: ${CAKE_SERVICE_FILE}"
    cat > "$CAKE_SERVICE_FILE" <<CAKESERVICE_EOF
[Unit]
Description=Set CAKE Qdisc on ${CAKE_IFACE}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${CAKE_SCRIPT_FILE}
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
CAKESERVICE_EOF

    systemctl daemon-reload
    systemctl enable set-cake.service >/dev/null 2>&1
    systemctl restart set-cake.service

    # ---- 显示结果 ----
    echo ""
    _header "调优完成 (CAKE 模式)"
    echo ""
    printf "  ${BOLD}CAKE 配置${PLAIN}\n"
    printf "    网卡接口 : ${GREEN}%s${PLAIN}\n" "$CAKE_IFACE"
    printf "    NAT 模式 : ${GREEN}%s${PLAIN}\n" "$NAT_MODE"
    printf "    带宽     : ${GREEN}%s${PLAIN}\n" "$CAKE_BW"
    printf "    RTT      : ${GREEN}%s${PLAIN}\n" "${RTT_ms}ms"
    echo ""

    if command -v tc >/dev/null 2>&1; then
        printf "  ${BOLD}CAKE 队列状态${PLAIN}\n"
        tc -s qdisc show dev "$CAKE_IFACE" 2>/dev/null | while IFS= read -r line; do
            printf "    ${DIM}%s${PLAIN}\n" "$line"
        done
        echo ""
    fi

    printf "  ${BOLD}输入参数${PLAIN}\n"
    printf "    带宽: ${CYAN}%s Mbps${PLAIN}  RTT: ${CYAN}%s ms${PLAIN}  内存: ${CYAN}%s GiB${PLAIN}\n" "$BW_Mbps" "$RTT_ms" "$MEM_G"
    printf "    BDP: ${CYAN}$(awk -v b="$BDP_BYTES" 'BEGIN{ printf "%.2f", b/1024/1024 }') MB${PLAIN}  桶值: ${CYAN}${MAX_MB} MB${PLAIN}  CC: ${CYAN}${CURRENT_CC}${PLAIN}\n"
    echo ""
    _separator
    printf "  ${BOLD}核心缓冲区${PLAIN}\n"
    printf "    %-20s ${GREEN}%s${PLAIN}\n" "rmem_default"   "$(sysctl -n net.core.rmem_default 2>/dev/null)"
    printf "    %-20s ${GREEN}%s${PLAIN}\n" "wmem_default"   "$(sysctl -n net.core.wmem_default 2>/dev/null)"
    printf "    %-20s ${GREEN}%s${PLAIN}\n" "rmem_max"       "$(sysctl -n net.core.rmem_max 2>/dev/null)"
    printf "    %-20s ${GREEN}%s${PLAIN}\n" "wmem_max"       "$(sysctl -n net.core.wmem_max 2>/dev/null)"
    printf "    %-20s ${GREEN}%s${PLAIN}\n" "backlog"        "$(sysctl -n net.core.netdev_max_backlog 2>/dev/null)"
    echo ""
    printf "  ${BOLD}TCP 缓冲区${PLAIN}\n"
    printf "    %-20s ${GREEN}%s${PLAIN}\n" "tcp_rmem"       "$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null)"
    printf "    %-20s ${GREEN}%s${PLAIN}\n" "tcp_wmem"       "$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null)"
    echo ""
    printf "  ${BOLD}通用优化${PLAIN}\n"
    printf "    %-20s ${GREEN}%s${PLAIN}\n" "mtu_probing"    "$(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null)"
    printf "    %-20s ${GREEN}%s${PLAIN}\n" "fastopen"       "$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null)"
    printf "    %-20s ${GREEN}%s${PLAIN}\n" "timestamps"     "$(sysctl -n net.ipv4.tcp_timestamps 2>/dev/null)"
    printf "    %-20s ${GREEN}%s${PLAIN}\n" "sack"           "$(sysctl -n net.ipv4.tcp_sack 2>/dev/null)"
    printf "    %-20s ${GREEN}%s${PLAIN}\n" "window_scaling" "$(sysctl -n net.ipv4.tcp_window_scaling 2>/dev/null)"
    if [ "$IS_BBR" -eq 1 ]; then
        echo ""
        printf "  ${BOLD}BBR 参数${PLAIN}\n"
        printf "    %-20s ${GREEN}%s${PLAIN}\n" "slow_start_idle" "$(sysctl -n net.ipv4.tcp_slow_start_after_idle 2>/dev/null)"
        printf "    %-20s ${GREEN}%s${PLAIN}\n" "notsent_lowat"   "$(sysctl -n net.ipv4.tcp_notsent_lowat 2>/dev/null || echo N/A)"
    fi
    echo ""
    _separator
    _info "TCP 配置已写入: ${_TCPTUNE_SYSCTL_TARGET}"
    _info "CAKE 脚本: ${CAKE_SCRIPT_FILE}"
    _info "CAKE 服务: ${CAKE_SERVICE_FILE} (已启用开机自启)"
    echo ""
    _info "常用命令:"
    printf "    systemctl status set-cake.service  ${DIM}# 查看 CAKE 服务状态${PLAIN}\n"
    printf "    tc -s qdisc show dev %s            ${DIM}# 查看 CAKE 队列统计${PLAIN}\n" "$CAKE_IFACE"

    _network_reboot_prompt
    _press_any_key
}

_tcptune_setup() {
    while true; do
        _header "TCP 缓冲区调优"
        echo ""
        printf "  ${BOLD}请选择调优模式:${PLAIN}\n"
        _separator
        printf "    ${GREEN}1${PLAIN}) 自动优化                        ${DIM}— 根据带宽/RTT 自动计算桶值${PLAIN}\n"
        printf "    ${GREEN}2${PLAIN}) 手动修改桶值                    ${DIM}— 手动指定 TCP 缓冲区大小${PLAIN}\n"
        echo ""
        printf "    ${RED}0${PLAIN}) 返回主菜单\n"
        echo ""

        local choice
        read -rp "  请输入选项 [0-2]: " choice

        case "$choice" in
            1)
                local DEFAULT_IFACE CURRENT_QDISC
                DEFAULT_IFACE="$(_tcptune_default_iface)"
                CURRENT_QDISC="$(_tcptune_detect_qdisc "$DEFAULT_IFACE")"

                case "$CURRENT_QDISC" in
                    cake)
                        _info "检测到当前队列算法: ${CURRENT_QDISC}，进入 CAKE 模式调优"
                        _tcptune_setup_cake "$DEFAULT_IFACE"
                        ;;
                    *)
                        _tcptune_setup_fq
                        ;;
                esac
                ;;
            2)
                _tcptune_manual_bucket
                ;;
            0)
                return
                ;;
            *)
                _error_no_exit "无效选项: ${choice}"
                sleep 1
                ;;
        esac
    done
}

# --- 7. Docker 日志轮转 ---

_dockerlog_setup() {
    _header "Docker 日志轮转配置"

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

    echo ""
    echo "  请选择操作:"
    _separator
    printf "    ${GREEN}1${PLAIN}) 应用日志轮转配置 ${DIM}(自动备份原配置)${PLAIN}\n"
    echo ""
    printf "    ${RED}0${PLAIN}) 返回主菜单\n"
    echo ""

    local choice
    read -rp "  请输入选项 [0-1]: " choice
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
        cur_ver=$("${INSTALL_DIR}/mihomo" -v 2>/dev/null | head -1 || echo "未知")
        _info "当前已安装: ${cur_ver}"
    else
        _info "当前未安装 mihomo"
    fi

    # 检测架构
    _info "检测系统架构..."
    local ARCH
    ARCH=$(_mihomo_detect_arch)
    if [[ -z "$ARCH" ]]; then
        _error_no_exit "不支持的架构: $(uname -m)"
        _press_any_key
        return
    fi
    _info "检测到架构: ${ARCH}"

    echo ""
    echo "  请选择操作:"
    _separator
    printf "    ${GREEN}1${PLAIN}) 安装/更新 mihomo ${DIM}(自动获取最新版)${PLAIN}\n"
    echo ""
    printf "    ${RED}0${PLAIN}) 返回主菜单\n"
    echo ""

    local choice
    read -rp "  请输入选项 [0-1]: " choice
    case "$choice" in
        1) ;;
        0) return ;;
        *) _error_no_exit "无效选项"; _press_any_key; return ;;
    esac

    # 获取最新版本
    _info "获取最新版本号..."
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
    local string="$1" encoded="" i c
    for (( i=0; i<${#string}; i++ )); do
        c="${string:$i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) encoded+="$c" ;;
            *) encoded+=$(printf '%%%02X' "'$c") ;;
        esac
    done
    echo "$encoded"
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
        params="peer=${sni}&${params}"
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
    grep -q "type: ${type}" "$_MIHOMOCONF_CONFIG_FILE" 2>/dev/null
}

_mihomoconf_list_listeners() {
    local type="$1"
    awk -v t="$type" '
        /^  - name:/ { name=$3 }
        /type:/ && $2 == t { found=1 }
        found && /port:/ { print "      " name " (端口: " $2 ")"; found=0 }
    ' "$_MIHOMOCONF_CONFIG_FILE" 2>/dev/null
}

_mihomoconf_remove_listeners_by_type() {
    local type="$1"
    local tmp
    tmp=$(mktemp)
    awk -v t="$type" '
        BEGIN { skip=0; buf="" }
        /^  - name:/ {
            if (skip) { skip=0; buf="" }
            if (buf != "") { printf "%s", buf; buf="" }
            buf = $0 "\n"
            next
        }
        buf != "" && /^    type:/ {
            if ($2 == t) {
                skip=1; buf=""
            } else {
                buf = buf $0 "\n"
            }
            next
        }
        buf != "" && !skip {
            buf = buf $0 "\n"
            next
        }
        skip && /^  - / { skip=0; buf = $0 "\n"; next }
        skip && /^[^ ]/ { skip=0; print; next }
        skip { next }
        { print }
        END { if (buf != "" && !skip) printf "%s", buf }
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
            name=type=port=cipher=password=user_id=user_pass=sni=""
            hy2_up=hy2_down=hy2_ignore=hy2_obfs=hy2_obfs_password=hy2_masquerade=hy2_mport=hy2_insecure=""
            in_users=0
        }
        function emit() {
            if (name == "") return
            printf "%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\n", \
                type, name, port, cipher, password, user_id, user_pass, sni, hy2_up, hy2_down, \
                hy2_ignore, hy2_obfs, hy2_obfs_password, hy2_masquerade, hy2_mport, hy2_insecure
        }
        BEGIN {
            reset_state()
        }
        /^  - name:/ {
            emit()
            line=$0
            sub(/^  - name:[[:space:]]*/, "", line)
            name=unquote(trim(line))
            type=port=cipher=password=user_id=user_pass=sni=""
            hy2_up=hy2_down=hy2_ignore=hy2_obfs=hy2_obfs_password=hy2_masquerade=hy2_mport=hy2_insecure=""
            in_users=0
            next
        }
        /^    #[[:space:]]*vpsgo-sni:/ {
            line=$0
            sub(/^    #[[:space:]]*vpsgo-sni:[[:space:]]*/, "", line)
            sni=trim(line)
            next
        }
        /^    #[[:space:]]*vpsgo-peer:/ {
            line=$0
            sub(/^    #[[:space:]]*vpsgo-peer:[[:space:]]*/, "", line)
            sni=trim(line)
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
    local SS_REPLACE="n" ANYTLS_REPLACE="n" HY2_REPLACE="n"

    local SS_PORT="" SS_CIPHER="" SS_PASSWORD=""
    local ANYTLS_PORT="" ANYTLS_SNI="" ANYTLS_USER_ID="" ANYTLS_PASSWORD=""
    local HY2_PORT="" HY2_USER="hy2-user" HY2_PASSWORD="" HY2_UP="" HY2_DOWN=""
    local HY2_IGNORE_CLIENT_BANDWIDTH="false" HY2_SNI="" HY2_INSECURE="0"
    local HY2_MPORT="" HY2_OBFS="" HY2_OBFS_PASSWORD="" HY2_MASQUERADE=""
    local SERVER_IP="" SERVER_HOST="" SAVED_HOST="" host_input=""

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
        echo "  请选择操作(已有配置):"
        _separator
        printf "    ${GREEN}1${PLAIN}) 追加新节点到现有配置\n"
        printf "    ${GREEN}2${PLAIN}) 覆盖，重新生成配置\n"
        printf "    ${RED}0${PLAIN}) 返回主菜单\n"
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
    echo "  请选择要添加的协议 (可多选，空格分隔):"
    _separator
    printf "    ${GREEN}1${PLAIN}) SS2022\n"
    printf "    ${GREEN}2${PLAIN}) AnyTLS\n"
    printf "    ${GREEN}3${PLAIN}) HY2\n"
    local PROTOCOL_CHOICES
    read -rp "  请输入选项 (如 \"1 2\" 表示两个都添加): " -a PROTOCOL_CHOICES

    for ch in "${PROTOCOL_CHOICES[@]}"; do
        case "$ch" in
            1) ENABLE_SS="y" ;;
            2) ENABLE_ANYTLS="y" ;;
            3) ENABLE_HY2="y" ;;
            *) _warn "忽略无效选项: $ch" ;;
        esac
    done
    if [[ "$ENABLE_SS" == "n" && "$ENABLE_ANYTLS" == "n" && "$ENABLE_HY2" == "n" ]]; then
        _error_no_exit "未选择任何协议"
        _press_any_key
        return
    fi

    # ---- 追加模式: 检查已有同协议节点 ----
    if [[ "$WRITE_MODE" == "append" ]]; then
        if [[ "$ENABLE_SS" == "y" ]] && _mihomoconf_has_listener_type "shadowsocks"; then
            _warn "配置中已存在 SS2022 节点:"
            _mihomoconf_list_listeners "shadowsocks"
            printf "    ${GREEN}1${PLAIN}) 覆盖已有 SS2022 节点\n"
            printf "    ${GREEN}2${PLAIN}) 保留已有，继续添加\n"
            local ss_action
            read -rp "  请选择 [1/2，默认 2]: " ss_action
            [[ "${ss_action:-2}" == "1" ]] && SS_REPLACE="y"
        fi
        if [[ "$ENABLE_ANYTLS" == "y" ]] && _mihomoconf_has_listener_type "anytls"; then
            _warn "配置中已存在 AnyTLS 节点:"
            _mihomoconf_list_listeners "anytls"
            printf "    ${GREEN}1${PLAIN}) 覆盖已有 AnyTLS 节点\n"
            printf "    ${GREEN}2${PLAIN}) 保留已有，继续添加\n"
            local anytls_action
            read -rp "  请选择 [1/2，默认 2]: " anytls_action
            [[ "${anytls_action:-2}" == "1" ]] && ANYTLS_REPLACE="y"
        fi
        if [[ "$ENABLE_HY2" == "y" ]] && _mihomoconf_has_listener_type "hysteria2"; then
            _warn "配置中已存在 HY2 节点:"
            _mihomoconf_list_listeners "hysteria2"
            printf "    ${GREEN}1${PLAIN}) 覆盖已有 HY2 节点\n"
            printf "    ${GREEN}2${PLAIN}) 保留已有，继续添加\n"
            local hy2_action
            read -rp "  请选择 [1/2，默认 2]: " hy2_action
            [[ "${hy2_action:-2}" == "1" ]] && HY2_REPLACE="y"
        fi
    fi

    # ---- SS2022 配置 ----
    if [[ "$ENABLE_SS" == "y" ]]; then
        printf "  ${BOLD}SS2022 配置${PLAIN}\n"
        _separator
        read -rp "    SS2022 监听端口 [默认 12353]: " SS_PORT
        SS_PORT="${SS_PORT:-12353}"
        if ! _is_valid_port "$SS_PORT"; then
            _error_no_exit "端口无效，请输入 1-65535 范围的数字"
            _press_any_key
            return
        fi

        echo "    请选择加密方式:"
        printf "      ${GREEN}1${PLAIN}) 2022-blake3-aes-128-gcm ${DIM}(推荐)${PLAIN}\n"
        printf "      ${GREEN}2${PLAIN}) 2022-blake3-aes-256-gcm\n"
        local cipher_choice
        read -rp "    请输入选项 [1/2，默认 1]: " cipher_choice
        case "${cipher_choice:-1}" in
            1) SS_CIPHER="2022-blake3-aes-128-gcm"; SS_PASSWORD=$(_mihomoconf_gen_ss_password_128) ;;
            2) SS_CIPHER="2022-blake3-aes-256-gcm"; SS_PASSWORD=$(_mihomoconf_gen_ss_password_256) ;;
            *) _error_no_exit "无效选项"; _press_any_key; return ;;
        esac
        _info "SS2022 密码已随机生成"
    fi

    # ---- AnyTLS 配置 ----
    if [[ "$ENABLE_ANYTLS" == "y" ]]; then
        printf "  ${BOLD}AnyTLS 配置${PLAIN}\n"
        _separator
        read -rp "    AnyTLS 监听端口 [默认 443]: " ANYTLS_PORT
        ANYTLS_PORT="${ANYTLS_PORT:-443}"
        if ! _is_valid_port "$ANYTLS_PORT"; then
            _error_no_exit "端口无效，请输入 1-65535 范围的数字"
            _press_any_key
            return
        fi
        read -rp "    SNI 域名 (留空则用 IP): " ANYTLS_SNI
        ANYTLS_SNI="${ANYTLS_SNI:-}"
        ANYTLS_USER_ID=$(_mihomoconf_gen_uuid)
        ANYTLS_PASSWORD=$(_mihomoconf_gen_anytls_password)
        _info "AnyTLS 用户 ID 和密码已随机生成"
    fi

    # ---- HY2 配置 ----
    if [[ "$ENABLE_HY2" == "y" ]]; then
        printf "  ${BOLD}HY2 配置${PLAIN}\n"
        _separator
        read -rp "    HY2 监听端口 [默认 8080]: " HY2_PORT
        HY2_PORT="${HY2_PORT:-8080}"
        if ! _is_valid_port "$HY2_PORT"; then
            _error_no_exit "端口无效，请输入 1-65535 范围的数字"
            _press_any_key
            return
        fi

        if [[ -n "${ANYTLS_SNI:-}" ]]; then
            read -rp "    HY2 SNI 域名 [默认复用 AnyTLS: ${ANYTLS_SNI}]: " HY2_SNI
            HY2_SNI="${HY2_SNI:-$ANYTLS_SNI}"
        else
            read -rp "    HY2 SNI 域名 (留空则用 IP): " HY2_SNI
            HY2_SNI="${HY2_SNI:-}"
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

        local hy2_ignore_input
        read -rp "    忽略客户端带宽声明? [y/N]: " hy2_ignore_input
        [[ "$hy2_ignore_input" =~ ^[Yy] ]] && HY2_IGNORE_CLIENT_BANDWIDTH="true" || HY2_IGNORE_CLIENT_BANDWIDTH="false"

        local hy2_enable_hop hy2_hop_size hy2_end_port
        read -rp "    开启端口跳跃? [y/N]: " hy2_enable_hop
        if [[ "$hy2_enable_hop" =~ ^[Yy] ]]; then
            read -rp "    端口跳跃大小 [默认 1000]: " hy2_hop_size
            hy2_hop_size="${hy2_hop_size:-1000}"
            if ! _is_digit "$hy2_hop_size" || [[ "$hy2_hop_size" -le 0 ]]; then
                _error_no_exit "端口跳跃大小必须为正整数"
                _press_any_key
                return
            fi
            hy2_end_port=$((HY2_PORT + hy2_hop_size - 1))
            if (( hy2_end_port > 65535 )); then
                _error_no_exit "端口跳跃范围超出 65535，请减小跳跃大小"
                _press_any_key
                return
            fi
            HY2_MPORT="${HY2_PORT}-${hy2_end_port}"
        fi

        local hy2_insecure_input
        read -rp "    允许客户端跳过证书验证? [y/N]: " hy2_insecure_input
        [[ "$hy2_insecure_input" =~ ^[Yy] ]] && HY2_INSECURE="1" || HY2_INSECURE="0"

        local hy2_obfs_enable hy2_obfs_pass_input
        read -rp "    启用 salamander 混淆? [y/N]: " hy2_obfs_enable
        if [[ "$hy2_obfs_enable" =~ ^[Yy] ]]; then
            HY2_OBFS="salamander"
            read -rp "    obfs 密码 [留空自动生成]: " hy2_obfs_pass_input
            HY2_OBFS_PASSWORD="${hy2_obfs_pass_input:-$(_mihomoconf_gen_anytls_password)}"
        fi

        local hy2_masquerade_input
        read -rp "    masquerade URL [默认 https://bing.com，输入 none 关闭]: " hy2_masquerade_input
        case "${hy2_masquerade_input:-}" in
            "") HY2_MASQUERADE="https://bing.com" ;;
            none|None|NONE) HY2_MASQUERADE="" ;;
            *) HY2_MASQUERADE="$hy2_masquerade_input" ;;
        esac

        HY2_PASSWORD=$(_mihomoconf_gen_anytls_password)
        _info "HY2 密码已随机生成(与 AnyTLS 独立)"
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

    _info "正在获取服务器公网 IP..."
    SERVER_IP=$(_mihomoconf_get_server_ip)
    _info "服务器 IP: ${SERVER_IP}"
    if [[ -n "$SAVED_HOST" ]]; then
        read -rp "  链接/JSON Host [默认 ${SAVED_HOST}，可填域名]: " host_input
        SERVER_HOST="${host_input:-$SAVED_HOST}"
    else
        read -rp "  链接/JSON Host [默认 ${SERVER_IP}，可填域名]: " host_input
        SERVER_HOST="${host_input:-$SERVER_IP}"
    fi
    _info "导出 Host: ${SERVER_HOST}"

    # ---- 写入配置 ----
    mkdir -p "$CONFIG_DIR"

    # 内部函数: 追加 listeners 到指定文件
    _mihomoconf_append_listeners_to() {
        local _target_file="$1"
        if [[ "$ENABLE_SS" == "y" ]]; then
            cat >> "$_target_file" <<MIHOMOCONF_SS_EOF
  - name: ss2022-in-${SS_PORT}
    type: shadowsocks
    port: ${SS_PORT}
    listen: "::"
    cipher: ${SS_CIPHER}
    password: "${SS_PASSWORD}"
    udp: true
MIHOMOCONF_SS_EOF
        fi
        if [[ "$ENABLE_ANYTLS" == "y" ]]; then
            cat >> "$_target_file" <<MIHOMOCONF_AT_EOF
  - name: anytls-in-${ANYTLS_PORT}
    type: anytls
    port: ${ANYTLS_PORT}
    listen: "::"
    # vpsgo-sni: ${ANYTLS_SNI}
    certificate: "${SSL_DIR}/cert.crt"
    private-key: "${SSL_DIR}/cert.key"
    users:
      "${ANYTLS_USER_ID}": "${ANYTLS_PASSWORD}"
MIHOMOCONF_AT_EOF
        fi
        if [[ "$ENABLE_HY2" == "y" ]]; then
            cat >> "$_target_file" <<MIHOMOCONF_HY2_EOF
  - name: hy2-in-${HY2_PORT}
    type: hysteria2
    port: ${HY2_PORT}
    listen: "::"
    # vpsgo-peer: ${HY2_SNI}
    # vpsgo-mport: ${HY2_MPORT}
    # vpsgo-insecure: ${HY2_INSECURE}
    users:
      "${HY2_USER}": "${HY2_PASSWORD}"
    up: ${HY2_UP}
    down: ${HY2_DOWN}
    ignore-client-bandwidth: ${HY2_IGNORE_CLIENT_BANDWIDTH}
MIHOMOCONF_HY2_EOF
            if [[ -n "$HY2_OBFS" ]]; then
                cat >> "$_target_file" <<MIHOMOCONF_HY2_OBFS_EOF
    obfs: ${HY2_OBFS}
    obfs-password: "${HY2_OBFS_PASSWORD}"
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
        printf "  ${BOLD}SS2022 连接信息${PLAIN}\n"
        _separator
        printf "    服务器 : ${GREEN}%s${PLAIN}\n" "$SERVER_HOST"
        printf "    端口   : ${GREEN}%s${PLAIN}\n" "$SS_PORT"
        printf "    加密   : ${GREEN}%s${PLAIN}\n" "$SS_CIPHER"
        printf "    密码   : ${GREEN}%s${PLAIN}\n" "$SS_PASSWORD"
        local SS_LINK
        SS_LINK=$(_mihomoconf_gen_ss_link "$SERVER_HOST" "$SS_PORT" "$SS_CIPHER" "$SS_PASSWORD" "mihomo-ss2022-${SS_PORT}")
        printf "  ${BOLD}SS2022 分享链接:${PLAIN}\n"
        printf "  ${GREEN}%s${PLAIN}\n" "$SS_LINK"
        printf "  ${BOLD}Clash Meta 客户端 YAML:${PLAIN}\n"
        _separator
        cat <<MIHOMOCONF_SS_YAML
    proxies:
      - name: "mihomo-ss2022-${SS_PORT}"
        type: ss
        server: ${SERVER_HOST}
        port: ${SS_PORT}
        cipher: ${SS_CIPHER}
        password: "${SS_PASSWORD}"
        udp: true
        tfo: true
        udp-over-tcp: true
MIHOMOCONF_SS_YAML
    fi

    # AnyTLS 输出
    if [[ "$ENABLE_ANYTLS" == "y" ]]; then
        local ANYTLS_LINK
        ANYTLS_LINK=$(_mihomoconf_gen_anytls_link "$SERVER_HOST" "$ANYTLS_PORT" "$ANYTLS_PASSWORD" "mihomo-anytls-${ANYTLS_PORT}" "$ANYTLS_SNI")
        printf "  ${BOLD}AnyTLS 分享链接:${PLAIN}\n"
        printf "  ${GREEN}%s${PLAIN}\n" "$ANYTLS_LINK"
        printf "  ${BOLD}Clash Meta 客户端 YAML:${PLAIN}\n"
        _separator
        cat <<MIHOMOCONF_AT_YAML
    proxies:
      - name: "mihomo-anytls-${ANYTLS_PORT}"
        type: anytls
        server: ${SERVER_HOST}
        port: ${ANYTLS_PORT}
        password: "${ANYTLS_PASSWORD}"
        udp: true
        tfo: true
MIHOMOCONF_AT_YAML
        if [[ -n "$ANYTLS_SNI" ]]; then
            echo "        sni: ${ANYTLS_SNI}"
        else
            echo "        skip-cert-verify: true"
        fi
    fi

    # HY2 输出
    if [[ "$ENABLE_HY2" == "y" ]]; then
        printf "  ${BOLD}HY2 连接信息${PLAIN}\n"
        _separator
        printf "    服务器 : ${GREEN}%s${PLAIN}\n" "$SERVER_HOST"
        printf "    端口   : ${GREEN}%s${PLAIN}\n" "$HY2_PORT"
        printf "    用户   : ${GREEN}%s${PLAIN}\n" "$HY2_USER"
        printf "    密码   : ${GREEN}%s${PLAIN}\n" "$HY2_PASSWORD"
        printf "    up/down: ${GREEN}%s/%s Mbps${PLAIN}\n" "$HY2_UP" "$HY2_DOWN"
        [[ -n "$HY2_SNI" ]] && printf "    SNI    : ${GREEN}%s${PLAIN}\n" "$HY2_SNI"
        [[ -n "$HY2_MPORT" ]] && printf "    跳跃端口: ${GREEN}%s${PLAIN}\n" "$HY2_MPORT"
        [[ "$HY2_INSECURE" == "1" ]] && printf "    insecure: ${YELLOW}开启${PLAIN}\n"
        [[ -n "$HY2_OBFS" ]] && printf "    obfs    : ${GREEN}%s${PLAIN}\n" "$HY2_OBFS"
        [[ -n "$HY2_MASQUERADE" ]] && printf "    masquerade: ${GREEN}%s${PLAIN}\n" "$HY2_MASQUERADE"
        local HY2_LINK
        HY2_LINK=$(_mihomoconf_gen_hy2_link "$SERVER_HOST" "$HY2_PORT" "$HY2_PASSWORD" "mihomo-hy2-${HY2_PORT}" "$HY2_SNI" "$HY2_INSECURE" "$HY2_OBFS" "$HY2_OBFS_PASSWORD" "$HY2_MPORT")
        printf "  ${BOLD}HY2 分享链接:${PLAIN}\n"
        printf "  ${GREEN}%s${PLAIN}\n" "$HY2_LINK"
        printf "  ${BOLD}HY2 JSON:${PLAIN}\n"
        _separator
        cat <<MIHOMOCONF_HY2_JSON
    {
      "type": "hysteria2",
      "tag": "mihomo-hy2-${HY2_PORT}",
      "server": "${SERVER_HOST}",
      "server_port": ${HY2_PORT},
      "password": "${HY2_PASSWORD}",
      "sni": "${HY2_SNI}",
      "insecure": ${HY2_INSECURE},
      "up_mbps": ${HY2_UP},
      "down_mbps": ${HY2_DOWN},
      "mport": "${HY2_MPORT}",
      "obfs": "${HY2_OBFS}",
      "obfs_password": "${HY2_OBFS_PASSWORD}"
    }
MIHOMOCONF_HY2_JSON
    fi

    _separator
    _info "可在 Mihomo 管理菜单中通过「读取配置并生成节点」随时生成链接/JSON"
    _info "启动命令: mihomo -d ${CONFIG_DIR}"

    _press_any_key
}

# --- Mihomo 管理子菜单 ---

_mihomo_restart() {
    _header "Mihomo 重启"

    if ! command -v mihomo >/dev/null 2>&1; then
        _error_no_exit "未检测到 mihomo，请先安装"
        _press_any_key
        return
    fi

    # systemd 服务
    if systemctl is-enabled mihomo.service &>/dev/null || systemctl is-active mihomo.service &>/dev/null; then
        _info "通过 systemd 重启 mihomo..."
        systemctl restart mihomo
        sleep 1
        if systemctl is-active --quiet mihomo; then
            _info "mihomo 已成功重启"
        else
            _error_no_exit "mihomo 重启失败，请检查 systemctl status mihomo"
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
            else
                _error_no_exit "mihomo 启动失败"
            fi
        else
            _error_no_exit "配置目录 $config_dir 不存在，请先生成配置"
        fi
    fi

    _press_any_key
}

_mihomo_enable() {
    _header "Mihomo 自启动配置"

    if ! command -v mihomo >/dev/null 2>&1; then
        _error_no_exit "未检测到 mihomo，请先安装"
        _press_any_key
        return
    fi

    local service_file="/etc/systemd/system/mihomo.service"
    local config_dir="/etc/mihomo"
    local mihomo_bin
    mihomo_bin=$(command -v mihomo)

    if [[ ! -d "$config_dir" ]]; then
        _error_no_exit "配置目录 $config_dir 不存在，请先生成配置"
        _press_any_key
        return
    fi

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

    systemctl daemon-reload
    systemctl enable mihomo
    _info "已设置开机自启"

    systemctl start mihomo
    sleep 1
    if systemctl is-active --quiet mihomo; then
        _info "mihomo 已成功启动"
    else
        _error_no_exit "mihomo 启动失败，请检查: systemctl status mihomo"
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
    local type name port cipher password user_id user_pass sni
    local hy2_up hy2_down hy2_ignore hy2_obfs hy2_obfs_password hy2_masquerade hy2_mport hy2_insecure

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
        _info "正在获取服务器公网 IP..."
        server_ip=$(_mihomoconf_get_server_ip)
        _info "导出 Host(公网IP): ${server_ip}"
    fi

    while IFS=$'\x1f' read -r type name port cipher password user_id user_pass sni \
        hy2_up hy2_down hy2_ignore hy2_obfs hy2_obfs_password hy2_masquerade hy2_mport hy2_insecure; do
        [[ -z "${name:-}" ]] && continue
        total_count=$((total_count + 1))

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
                local ss_link
                ss_link=$(_mihomoconf_gen_ss_link "$server_ip" "$port" "$cipher" "$password" "$name")
                _separator
                printf "  ${BOLD}[SS2022] %s${PLAIN}\n" "$name"
                printf "    链接: ${GREEN}%s${PLAIN}\n" "$ss_link"
                printf "    JSON:\n"
                cat <<MIHOMO_SS2022_JSON
    {
      "type": "shadowsocks",
      "tag": "${name}",
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
                local anytls_link
                anytls_link=$(_mihomoconf_gen_anytls_link "$server_ip" "$port" "$user_pass" "$name" "$sni")
                _separator
                printf "  ${BOLD}[AnyTLS] %s${PLAIN}\n" "$name"
                printf "    链接: ${GREEN}%s${PLAIN}\n" "$anytls_link"
                [[ -n "$sni" ]] && printf "    SNI: ${GREEN}%s${PLAIN}\n" "$sni"
                printf "    JSON:\n"
                cat <<MIHOMO_ANYTLS_JSON
    {
      "type": "anytls",
      "tag": "${name}",
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
                local hy2_link
                hy2_link=$(_mihomoconf_gen_hy2_link "$server_ip" "$port" "$user_pass" "$name" "$sni" "${hy2_insecure:-0}" "$hy2_obfs" "$hy2_obfs_password" "$hy2_mport")
                _separator
                printf "  ${BOLD}[HY2] %s${PLAIN}\n" "$name"
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
      "tag": "${name}",
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
        printf "    ${GREEN}1${PLAIN}) 安装/更新 Mihomo\n"
        printf "    ${GREEN}2${PLAIN}) 生成配置 ${DIM}(SS2022 / AnyTLS / HY2)${PLAIN}\n"
        printf "    ${GREEN}3${PLAIN}) 配置自启并启动\n"
        printf "    ${GREEN}4${PLAIN}) 重启 Mihomo\n"
        printf "    ${GREEN}5${PLAIN}) 查看日志\n"
        printf "    ${GREEN}6${PLAIN}) 读取配置并生成节点\n"
        printf "    ${RED}0${PLAIN}) 返回主菜单\n"

        local choice
        read -rp "  请输入选项 [0-6]: " choice
        case "$choice" in
            1) _mihomo_setup ;;
            2) _mihomoconf_setup ;;
            3) _mihomo_enable ;;
            4) _mihomo_restart ;;
            5) _mihomo_log ;;
            6) _mihomo_read_config ;;
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
    echo ""
    printf "    ${GREEN}1${PLAIN}) 终止占用进程并继续\n"
    printf "    ${GREEN}2${PLAIN}) 更换端口\n"
    printf "    ${RED}0${PLAIN}) 返回\n"
    echo ""
    local action
    read -rp "  请输入选项 [0-2]: " action
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

    echo ""
    echo "  请选择操作:"
    _separator
    printf "    ${GREEN}1${PLAIN}) 启动 iperf3 服务端\n"
    echo ""
    printf "    ${RED}0${PLAIN}) 返回主菜单\n"
    echo ""
    local choice
    read -rp "  请输入选项 [0-1]: " choice
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
    echo ""
    echo "  请选择版本:"
    _separator
    printf "    ${GREEN}1${PLAIN}) sing-box ${DIM}(稳定版)${PLAIN}\n"
    printf "    ${GREEN}2${PLAIN}) sing-box-beta ${DIM}(测试版)${PLAIN}\n"
    echo ""
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
        cur_ver=$(sing-box version 2>/dev/null | head -1 || echo "未知")
        _info "当前已安装: ${cur_ver}"
    else
        _info "当前未安装 sing-box"
    fi

    echo ""
    echo "  请选择操作:"
    _separator
    printf "    ${GREEN}1${PLAIN}) 安装/更新 sing-box\n"
    echo ""
    printf "    ${RED}0${PLAIN}) 返回主菜单\n"
    echo ""
    local choice
    read -rp "  请输入选项 [0-1]: " choice
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

        echo ""
        _separator
        printf "    ${GREEN}1${PLAIN}) 安装/更新 Sing-Box\n"
        printf "    ${GREEN}2${PLAIN}) 配置自启并启动\n"
        printf "    ${GREEN}3${PLAIN}) 重启 Sing-Box\n"
        printf "    ${GREEN}4${PLAIN}) 查看状态\n"
        printf "    ${GREEN}5${PLAIN}) 查看日志\n"
        echo ""
        printf "    ${RED}0${PLAIN}) 返回主菜单\n"
        echo ""

        local choice
        read -rp "  请输入选项 [0-5]: " choice
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

    _info "正在重启相关组件: ${_DNS_RESTART_SERVICES[*]}"
    for svc in "${_DNS_RESTART_SERVICES[@]}"; do
        if _dns_restart_service "$svc"; then
            _info "已重启服务: ${svc}"
        else
            _warn "服务 ${svc} 重启失败，请手动检查"
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
    _DNS_RESTART_SERVICES=()

    _info "正在写入永久 DNS 配置..."

    if _dns_apply_permanent_resolved; then
        methods+=("systemd-resolved")
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

    _info "永久 DNS 应用方式: ${methods[*]}"
    _dns_restart_related_services
    if [ "$_DNS_CLEAR_EXISTING" -eq 1 ]; then
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
    local resolv_nameserver_line=""
    local resolved_line=""

    while IFS= read -r line; do
        [ -n "$line" ] && resolv_nameserver_line="${resolv_nameserver_line}${line} "
    done < <(awk '/^[[:space:]]*nameserver[[:space:]]+/ {print $2}' /etc/resolv.conf 2>/dev/null)
    resolv_nameserver_line="${resolv_nameserver_line%" "}"

    if command -v resolvectl >/dev/null 2>&1 && resolvectl status >/dev/null 2>&1; then
        while IFS= read -r line; do
            [ -n "$line" ] && resolved_line="${resolved_line}${line} "
        done < <(resolvectl dns 2>/dev/null | sed -n 's/^.*: //p')
        resolved_line="${resolved_line%" "}"
    fi

    echo ""
    printf "  ${BOLD}[ 当前 DNS 配置 ]${PLAIN}\n"
    if [ -n "$resolv_nameserver_line" ]; then
        printf "    /etc/resolv.conf: ${CYAN}%s${PLAIN}\n" "$resolv_nameserver_line"
    else
        printf "    /etc/resolv.conf: ${YELLOW}未检测到 nameserver${PLAIN}\n"
    fi
    if [ -n "$resolved_line" ]; then
        printf "    systemd-resolved: ${CYAN}%s${PLAIN}\n" "$resolved_line"
    fi
}

_dns_verify_resolution() {
    local test_domain="cloudflare.com"
    local out server answer

    _dns_ensure_lookup_tool || true
    _info "正在使用系统默认解析器验证 DNS..."

    if command -v dig >/dev/null 2>&1; then
        out=$(dig +time=3 +tries=1 "$test_domain" 2>/dev/null || true)
        server=$(echo "$out" | awk -F': ' '/^;; SERVER:/{print $2; exit}')
        answer=$(echo "$out" | awk '/^[^;].*[[:space:]]IN[[:space:]]A[[:space:]]/ {print $5; exit}')
        if [ -n "$server" ]; then
            printf "    dig SERVER: ${CYAN}%s${PLAIN}\n" "$server"
        fi
        if [ -n "$answer" ]; then
            _info "dig 解析成功: ${test_domain} -> ${answer}"
            return 0
        fi
        _warn "dig 未返回 A 记录，继续尝试 nslookup..."
    fi

    if command -v nslookup >/dev/null 2>&1; then
        out=$(nslookup "$test_domain" 2>/dev/null || true)
        server=$(echo "$out" | awk '/^Server:/{print $2; exit}')
        answer=$(echo "$out" | awk '/^Address: /{print $2}' | tail -1)
        if [ -n "$server" ]; then
            printf "    nslookup Server: ${CYAN}%s${PLAIN}\n" "$server"
        fi
        if [ -n "$answer" ]; then
            _info "nslookup 解析成功: ${test_domain} -> ${answer}"
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
        echo ""
        printf "  请选择测速分组:\n"
        _separator
        printf "    ${GREEN}1${PLAIN}) 国内 DNS 组                     ${DIM}— 测试域名: qq.com${PLAIN}\n"
        printf "    ${GREEN}2${PLAIN}) 国外 DNS 组                     ${DIM}— 测试域名: google.com${PLAIN}\n"
        printf "    ${GREEN}3${PLAIN}) ECS DNS 组                      ${DIM}— 常见支持 ECS 的 DNS${PLAIN}\n"
        echo ""
        printf "    ${RED}0${PLAIN}) 返回上一层\n"
        echo ""

        local group_choice
        read -rp "  请输入选项 [0-3]: " group_choice
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

    _info "将应用 DNS: ${_DNS_SERVERS[*]}"
    echo ""
    if [ "$mode" = "temporary" ]; then
        _dns_apply_temporary || true
    else
        _dns_apply_permanent || true
    fi

    _dns_show_current_config
    echo ""
    _dns_verify_resolution || true
    _press_any_key
}

_dns_manage() {
    while true; do
        _header "Linux DNS 管理"
        _dns_show_current_config

        echo ""
        printf "  请选择操作:\n"
        _separator
        printf "    ${GREEN}1${PLAIN}) 临时修改 DNS                    ${DIM}— 重启或重连后可能失效${PLAIN}\n"
        printf "    ${GREEN}2${PLAIN}) 永久修改 DNS                    ${DIM}— 持久化并重启相关组件${PLAIN}\n"
        printf "    ${GREEN}3${PLAIN}) 仅验证当前 DNS                  ${DIM}— 使用 dig/nslookup 测试${PLAIN}\n"
        printf "    ${GREEN}4${PLAIN}) 主流 DNS 测速                   ${DIM}— 先选国内/国外/ECS 分组${PLAIN}\n"
        echo ""
        printf "    ${RED}0${PLAIN}) 返回主菜单\n"
        echo ""

        local choice
        read -rp "  请输入选项 [0-4]: " choice
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
        echo ""
        printf "    ${GREEN}1${PLAIN}) 仍要创建/扩展 Swap\n"
        printf "    ${RED}2${PLAIN}) 删除现有 Swap 文件 (/swapfile)\n"
        printf "    ${RED}0${PLAIN}) 返回主菜单\n"
        echo ""
        local sub_choice
        read -rp "  请输入选项: " sub_choice
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
    clear
    echo ""
    printf "${CYAN}"
    cat << 'BANNER'
  VV     VV PPPPPP   SSSSS    GGGG
   VV   VV  PP   PP SS       GG
    VV VV   PPPPPP   SSSSS  GG  GGG  OOOOO
     VVV    PP           SS  GG   GG OO   OO
      V     PP       SSSSS   GGGGGG  OOOOO
BANNER
    printf "${PLAIN}"
    printf "${DIM}      VPS 一站式管理脚本  v${VERSION}${PLAIN}\n"
}

_show_main_menu() {
    _show_sys_info
    printf "  ${BOLD}[ 网络优化 ]${PLAIN}\n"
    printf "    ${GREEN}1${PLAIN}) 开启内核自带 BBR                ${DIM}— 安装 BBR${PLAIN}\n"
    printf "    ${GREEN}2${PLAIN}) 设置队列调度算法                ${DIM}— fq/cake/fq_pie${PLAIN}\n"
    printf "    ${GREEN}3${PLAIN}) 设置 IPv4/IPv6 优先级           ${DIM}— 出口协议栈偏好${PLAIN}\n"
    printf "    ${GREEN}4${PLAIN}) TCP 缓冲区调优                  ${DIM}— 优化连接(效果不稳定）${PLAIN}\n"
    printf "  ${BOLD}[ 工具 ]${PLAIN}\n"
    printf "    ${GREEN}5${PLAIN}) iPerf3 测速服务端               ${DIM}— 临时启动${PLAIN}\n"
    printf "    ${GREEN}6${PLAIN}) NodeQuality 测试                ${DIM}— vps 测试脚本${PLAIN}\n"
    printf "    ${GREEN}7${PLAIN}) Docker 日志轮转                 ${DIM}— 限制容器日志大小${PLAIN}\n"
    printf "    ${GREEN}8${PLAIN}) Mihomo 管理                     ${DIM}— 安装/配置/重启${PLAIN}\n"
    printf "    ${GREEN}9${PLAIN}) Sing-Box 管理                   ${DIM}— 安装/自启/重启${PLAIN}\n"
    printf "    ${GREEN}10${PLAIN}) Akile DNS 解锁检测             ${DIM}— DNS 媒体解锁测速${PLAIN}\n"
    printf "    ${GREEN}11${PLAIN}) Linux DNS 管理                 ${DIM}— 临时/永久修改 DNS${PLAIN}\n"
    printf "  ${BOLD}[ 系统 ]${PLAIN}\n"
    printf "    ${GREEN}12${PLAIN}) Swap 管理                      ${DIM}— 创建/删除 Swap${PLAIN}\n"
    echo ""
    printf "    ${GREEN}u${PLAIN}) 更新 VPSGo                      ${DIM}— 从 GitHub 拉取最新版${PLAIN}\n"
    printf "    ${RED}x${PLAIN}) 卸载 VPSGo                      ${DIM}— 卸载${PLAIN}\n"
    printf "    ${RED}0${PLAIN}) 退出脚本\n"
    echo ""
}

main() {
    [[ $EUID -ne 0 ]] && _error "此脚本需要 root 权限，请使用 sudo vpsgo 运行"

    _self_install

    while true; do
        _show_banner
        _show_main_menu

        local choice
        read -rp "  请输入选项: " choice

        case "$choice" in
            1) _bbr_install ;;
            2) _qdisc_setup ;;
            3) _v4v6_setup ;;
            4) _tcptune_setup ;;
            5) _iperf3_setup ;;
            6) _nodequality_setup ;;
            7) _dockerlog_setup ;;
            8) _mihomo_manage ;;
            9) _singbox_manage ;;
            10) _akdns_setup ;;
            11) _dns_manage ;;
            12) _swap_setup ;;
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
