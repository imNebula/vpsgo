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
#   7. Ookla Speedtest CLI 安装
#   8. NextTrace 安装与快速路由检测
#   9. Docker 日志轮转配置
#  10. Mihomo 管理 (安装/配置/重启/卸载)
#  11. Sing-Box 管理 (安装/自启/重启/日志/卸载)
#  12. Snell V5 管理 (官方安装/配置/重启/日志/卸载)
#  13. WireGuard 原生节点 (安装/部署/重启/状态/卸载)
#  14. Shadowsocks-Rust 管理 (安装/配置/重启/日志/卸载)
#  15. Akile DNS 解锁检测与配置
#  16. Linux DNS 管理 (临时/永久修改)
#  17. Swap 管理
#  18. 1Panel iptables 代理链快速应用
#  19. WARP 管理
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

VERSION="4.0"
# --- 全局变量 ---
SCRIPT_DIR="$(cd -P -- "$(dirname -- "$0")" && pwd -P)"
INSTALL_PATH="${VPSGO_INSTALL_PATH:-/usr/local/bin/vpsgo}"
UPDATE_URL="${VPSGO_UPDATE_URL:-${VPSGO_URL:-https://raw.githubusercontent.com/imNebula/vpsgo/refs/heads/main/vpsgo.sh}}"
VPSGO_CONFIG_FILE="${VPSGO_CONFIG_FILE:-/etc/vpsgo/config}"
_SPEEDTEST_VERSION="1.2.0"
_SPEEDTEST_DOWNLOAD_BASE="https://install.speedtest.net/app/cli"
_NTRACE_REPO_URL="https://github.com/nxtrace/NTrace-core"
_NTRACE_INSTALL_URL="https://nxtrace.org/nt"
_NTRACE_INSTALL_DIR="/usr/local/bin"
_WARP_SH_URL="https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh"
_WARP_GO_URL="https://gitlab.com/fscarmen/warp/-/raw/main/warp-go.sh"
_WARP_REFRESH_SCRIPT="/usr/local/bin/vpsgo-warp-refresh.sh"
_WARP_REFRESH_CRON="/etc/cron.d/vpsgo-warp-refresh"
_WARP_REFRESH_LOG="/var/log/vpsgo-warp-refresh.log"
_MIHOMO_AUTO_UPDATE_SCRIPT="/usr/local/bin/vpsgo-mihomo-auto-update.sh"
_MIHOMO_AUTO_UPDATE_CRON="/etc/cron.d/vpsgo-mihomo-auto-update"
_MIHOMO_AUTO_UPDATE_LOG="/var/log/vpsgo-mihomo-auto-update.log"
_MIHOMO_TRACK="stable"
_GITHUB_PROXY_DEFAULT_BASE="https://gh-proxy.org"
_GITHUB_PROXY_ENABLED="0"
_GITHUB_PROXY_BASE="$_GITHUB_PROXY_DEFAULT_BASE"

# 颜色
RED=$(printf '\033[1;31m')
GREEN=$(printf '\033[1;32m')
YELLOW=$(printf '\033[1;33m')
CYAN=$(printf '\033[1;36m')
BLUE=$(printf '\033[1;34m')
MAGENTA=$(printf '\033[1;35m')
DIM=$(printf '\033[2m')
BOLD=$(printf '\033[1m')
PLAIN=$(printf '\033[0m')

_trim_trailing_slashes() {
    local s="${1:-}"
    while [[ "$s" == */ ]]; do
        s="${s%/}"
    done
    printf '%s' "$s"
}

_is_truthy() {
    local value
    value=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
    case "$value" in
        1|y|yes|on|true|enable|enabled) return 0 ;;
    esac
    return 1
}

_config_read_value() {
    local key="$1" default="${2:-}" value
    [[ -r "$VPSGO_CONFIG_FILE" ]] || {
        printf '%s' "$default"
        return 0
    }
    value=$(awk -F= -v k="$key" '$1 == k { print substr($0, index($0, "=") + 1) }' "$VPSGO_CONFIG_FILE" 2>/dev/null | tail -n1)
    if [[ -z "${value:-}" ]]; then
        value="$default"
    fi
    printf '%s' "$value"
}

_github_proxy_normalize_base() {
    local base="${1:-$_GITHUB_PROXY_DEFAULT_BASE}"
    if [[ "$base" != http://* && "$base" != https://* ]]; then
        base="https://${base}"
    fi
    base=$(_trim_trailing_slashes "$base")
    printf '%s' "$base"
}

_load_runtime_config() {
    local file_enabled file_base file_track
    file_enabled=$(_config_read_value "VPSGO_GITHUB_PROXY" "0")
    file_base=$(_config_read_value "VPSGO_GITHUB_PROXY_BASE" "$_GITHUB_PROXY_DEFAULT_BASE")
    file_track=$(_config_read_value "VPSGO_MIHOMO_TRACK" "stable")
    if [[ "$file_base" == "https://gh-proxy.com" ]] || [[ "$file_base" == "gh-proxy.com" ]]; then
        file_base="$_GITHUB_PROXY_DEFAULT_BASE"
    fi

    _GITHUB_PROXY_ENABLED="${VPSGO_GITHUB_PROXY:-$file_enabled}"
    _GITHUB_PROXY_BASE="${VPSGO_GITHUB_PROXY_BASE:-$file_base}"
    _GITHUB_PROXY_BASE=$(_github_proxy_normalize_base "$_GITHUB_PROXY_BASE")
    _MIHOMO_TRACK="${VPSGO_MIHOMO_TRACK:-$file_track}"
}

_save_runtime_config() {
    local cfg_dir tmp_file enabled_value
    cfg_dir="$(dirname "$VPSGO_CONFIG_FILE")"
    tmp_file=$(mktemp /tmp/vpsgo-config.XXXXXX) || return 1
    _GITHUB_PROXY_BASE=$(_github_proxy_normalize_base "$_GITHUB_PROXY_BASE")
    enabled_value="0"
    _is_truthy "$_GITHUB_PROXY_ENABLED" && enabled_value="1"

    mkdir -p "$cfg_dir" || {
        rm -f "$tmp_file"
        return 1
    }

    {
        printf '# Managed by VPSGo\n'
        printf 'VPSGO_GITHUB_PROXY=%s\n' "$enabled_value"
        printf 'VPSGO_GITHUB_PROXY_BASE=%s\n' "$_GITHUB_PROXY_BASE"
        printf 'VPSGO_MIHOMO_TRACK=%s\n' "$_MIHOMO_TRACK"
    } > "$tmp_file" || {
        rm -f "$tmp_file"
        return 1
    }

    chmod 0644 "$tmp_file" 2>/dev/null || true
    mv "$tmp_file" "$VPSGO_CONFIG_FILE"
}

_github_proxy_base_label() {
    local base
    base=$(_github_proxy_normalize_base "$_GITHUB_PROXY_BASE")
    base="${base#https://}"
    base="${base#http://}"
    printf '%s' "$base"
}

_github_proxy_supports_url() {
    local url="$1" rest host
    case "$url" in
        http://*|https://*) ;;
        *) return 1 ;;
    esac

    rest="${url#*://}"
    host="${rest%%/*}"
    host="${host%%\?*}"
    host=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')

    case "$host" in
        github.com|www.github.com|api.github.com|raw.githubusercontent.com|gist.github.com|gist.githubusercontent.com|codeload.github.com|objects.githubusercontent.com|*.githubusercontent.com|*.githubassets.com)
            return 0
            ;;
    esac
    return 1
}

_github_proxy_url() {
    local url="${1:-}" base
    [[ -n "$url" ]] || {
        printf '%s' "$url"
        return 0
    }
    if ! _is_truthy "$_GITHUB_PROXY_ENABLED"; then
        printf '%s' "$url"
        return 0
    fi

    base=$(_github_proxy_normalize_base "$_GITHUB_PROXY_BASE")
    if [[ "$url" == "${base}/"* ]] || ! _github_proxy_supports_url "$url"; then
        printf '%s' "$url"
        return 0
    fi
    printf '%s/%s' "$base" "$url"
}

_github_proxy_status_text() {
    if _is_truthy "$_GITHUB_PROXY_ENABLED"; then
        printf '开启 (%s)' "$(_github_proxy_base_label)"
    else
        printf '关闭'
    fi
}

_github_proxy_status_desc() {
    if _is_truthy "$_GITHUB_PROXY_ENABLED"; then
        printf '开启中，按 g 关闭'
    else
        printf '关闭中，按 g 开启'
    fi
}

_github_proxy_status_tone() {
    if _is_truthy "$_GITHUB_PROXY_ENABLED"; then
        printf 'green'
    else
        printf 'dim'
    fi
}

_toggle_github_proxy() {
    _header "GitHub 代理设置"

    if _is_truthy "$_GITHUB_PROXY_ENABLED"; then
        _GITHUB_PROXY_ENABLED="0"
    else
        _GITHUB_PROXY_ENABLED="1"
    fi

    if ! _save_runtime_config; then
        _error_no_exit "保存配置失败: ${VPSGO_CONFIG_FILE}"
        _press_any_key
        return
    fi

    if _is_truthy "$_GITHUB_PROXY_ENABLED"; then
        _success "GitHub 代理已开启"
        _info "代理入口: ${_GITHUB_PROXY_BASE}"
        _info "GitHub Releases / Raw / 自更新将自动走代理"
    else
        _success "GitHub 代理已关闭"
        _info "后续 GitHub 相关下载将恢复直连"
    fi
    _press_any_key
}

# --- 通用工具函数 ---

_info() {
    printf "${CYAN}• ${PLAIN}%b\n" "$1"
}

_success() {
    printf "${GREEN}✔ ${PLAIN}%b\n" "$1"
}

_warn() {
    printf "${YELLOW}⚠ ${PLAIN}%b\n" "$1"
}

_error() {
    printf "${RED}✘ ${PLAIN}%b\n" "$1"
    exit 1
}

_error_no_exit() {
    printf "${RED}✘ ${PLAIN}%b\n" "$1"
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

_mktemp_file() {
    local prefix="${1:-vpsgo}" suffix="${2:-}" tmp
    tmp=$(mktemp "/tmp/${prefix}.XXXXXX" 2>/dev/null) || return 1
    if [[ -n "$suffix" ]]; then
        mv "$tmp" "${tmp}${suffix}" || {
            rm -f "$tmp"
            return 1
        }
        tmp="${tmp}${suffix}"
    fi
    printf '%s' "$tmp"
}

_download_file() {
    local url="$1" output="$2" fetch_url
    [[ -n "${url:-}" && -n "${output:-}" ]] || return 1

    fetch_url=$(_github_proxy_url "$url")
    rm -f "$output"

    if command -v curl >/dev/null 2>&1; then
        if curl -fsSL --retry 2 --connect-timeout 10 --max-time 180 -o "$output" "$fetch_url"; then
            [[ -s "$output" ]] && return 0
        fi
        rm -f "$output"
    fi

    if command -v wget >/dev/null 2>&1; then
        if wget -q -T 30 -O "$output" "$fetch_url"; then
            [[ -s "$output" ]] && return 0
        fi
        rm -f "$output"
    fi

    return 1
}

_ensure_script_mode_ok() {
    local path="$1"
    [[ -f "$path" ]] || return 1
    [[ -r "$path" && -x "$path" ]] && return 0
    chmod 0755 "$path" 2>/dev/null || return 1
    [[ -r "$path" && -x "$path" ]]
}

_script_file_looks_like_vpsgo() {
    local path="$1"
    [[ -f "$path" && -r "$path" ]] || return 1
    grep -q '^VERSION=' "$path" 2>/dev/null || return 1
    grep -q 'VPS Go' "$path" 2>/dev/null || return 1
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

_status_kv_cell() {
    local key="$1" value="$2" tone="${3:-cyan}" key_width="${4:-8}" cell_width="${5:-38}"
    local value_color="$CYAN"
    case "$tone" in
        green) value_color="$GREEN" ;;
        yellow) value_color="$YELLOW" ;;
        red) value_color="$RED" ;;
        dim) value_color="$DIM" ;;
    esac

    local prefix_w=4
    local sep_w=3
    local val_max_w=$((cell_width - prefix_w - key_width - sep_w))
    [ "$val_max_w" -lt 4 ] && val_max_w=4

    local val_txt
    val_txt=$(_ui_truncate_text "$value" "$val_max_w")

    local val_w
    val_w=$(_ui_display_width "$val_txt")

    local total_w=$((prefix_w + key_width + sep_w + val_w))
    local pad=0
    if [ "$total_w" -lt "$cell_width" ]; then
        pad=$((cell_width - total_w))
    fi

    printf "  ${DIM}·${PLAIN} "
    _ui_pad_right_text "$key" "$key_width"
    printf " ${DIM}:${PLAIN} ${value_color}%s${PLAIN}" "$val_txt"
    _ui_repeat_char " " "$pad"
}

_status_kv_pair() {
    local k1="$1" v1="$2" t1="${3:-cyan}" kw1="${4:-8}"
    local k2="${5:-}" v2="${6:-}" t2="${7:-cyan}" kw2="${8:-8}"

    local cols col_w
    cols=$(_ui_term_cols)
    col_w=$(( (cols - 4) / 2 ))

    _status_kv_cell "$k1" "$v1" "$t1" "$kw1" "$col_w"
    if [[ -n "$k2" ]]; then
        _status_kv_cell "$k2" "$v2" "$t2" "$kw2" "$col_w"
    fi
    printf "\n"
}

_ui_term_cols() {
    local cols
    if _is_digit "${_UI_TERM_COLS_CACHE:-}"; then
        printf '%s' "$_UI_TERM_COLS_CACHE"
        return
    fi

    cols="${COLUMNS:-}"
    if ! _is_digit "${cols:-}" && command -v tput >/dev/null 2>&1; then
        cols=$(tput cols 2>/dev/null || true)
    fi
    if ! _is_digit "${cols:-}"; then
        cols=80
    fi
    [ "$cols" -lt 72 ] && cols=72
    [ "$cols" -gt 100 ] && cols=100
    printf '%s' "$cols"
}

_ui_clear_screen() {
    [ -t 1 ] || return 0
    [ "${_UI_SCREEN_ACTIVE:-0}" = "1" ] && return 0
    if command -v tput >/dev/null 2>&1; then
        tput clear 2>/dev/null || printf '\033[2J\033[H'
    else
        printf '\033[2J\033[H'
    fi
}

_ui_print_screen() {
    local old_cols="${_UI_TERM_COLS_CACHE:-}" old_active="${_UI_SCREEN_ACTIVE:-0}"
    _UI_TERM_COLS_CACHE="$(_ui_term_cols)"
    _UI_SCREEN_ACTIVE=1

    if [ -t 1 ]; then
        # Synchronized updates are ignored by terminals that do not support them,
        # but prevent visible top-to-bottom redraws in modern terminal emulators.
        printf '\033[?2026h\033[2J\033[H'
    fi
    "$@"
    if [ -t 1 ]; then
        printf '\033[?2026l'
    fi

    _UI_SCREEN_ACTIVE="$old_active"
    _UI_TERM_COLS_CACHE="$old_cols"
}

_ui_repeat_char() {
    local char="$1" count="$2"
    if [[ "$count" -gt 0 ]]; then
        local pad
        printf -v pad "%${count}s" ""
        printf '%s' "${pad// /$char}"
    fi
}

_ui_display_width_var() {
    local s="$1"
    local non_ascii
    non_ascii="${s//[ -~]/}"
    _UI_WIDTH=$(( ${#s} + ${#non_ascii} ))
}

_ui_display_width() {
    local _UI_WIDTH
    _ui_display_width_var "$1"
    printf '%s' "$_UI_WIDTH"
}

_ui_truncate_text() {
    local text="$1" max="$2"
    if ! _is_digit "${max:-}" || [ "$max" -le 0 ]; then
        printf ''
        return
    fi

    local _UI_WIDTH
    _ui_display_width_var "$text"
    local width="$_UI_WIDTH"
    if [ "$width" -le "$max" ]; then
        printf '%s' "$text"
        return
    fi

    if [ "$max" -le 3 ]; then
        printf '%.*s' "$max" "..."
        return
    fi

    local limit=$((max - 3))
    local out=""
    width=0
    local len=${#text}
    local i ch non_ascii cw
    for ((i=0; i<len; i++)); do
        ch="${text:i:1}"
        non_ascii="${ch//[ -~]/}"
        cw=$(( 1 + ${#non_ascii} ))
        if [ $((width + cw)) -gt "$limit" ]; then
            break
        fi
        out="${out}${ch}"
        width=$((width + cw))
    done
    printf '%s...' "$out"
}

_ui_pad_right_text() {
    local text="$1" target="$2"
    local _UI_WIDTH
    _ui_display_width_var "$text"
    local width="$_UI_WIDTH"
    printf '%s' "$text"
    if [ "$width" -lt "$target" ]; then
        local pad=$((target - width))
        _ui_repeat_char " " "$pad"
    fi
}

_header() {
    local title="$1"
    local cols rule_w line safe_title
    cols=$(_ui_term_cols)
    rule_w=$((cols - 4))
    [ "$rule_w" -lt 24 ] && rule_w=24
    [ "$rule_w" -gt 76 ] && rule_w=76
    safe_title=$(_ui_truncate_text "$title" "$rule_w")
    line=$(_ui_repeat_char "─" "$rule_w")

    _ui_clear_screen
    printf "  ${CYAN}%s${PLAIN}\n" "$line"
    printf "  ${BOLD}%s${PLAIN}\n" "$safe_title"
    printf "  ${DIM}%s${PLAIN}\n" "$line"
}

_separator() {
    local cols rule_w line
    cols=$(_ui_term_cols)
    rule_w=$((cols - 4))
    [ "$rule_w" -lt 24 ] && rule_w=24
    [ "$rule_w" -gt 76 ] && rule_w=76
    line=$(_ui_repeat_char "─" "$rule_w")
    printf "  ${DIM}%s${PLAIN}\n" "$line"
}

_menu_item() {
    local key="$1" label="$2" desc="${3:-}" tone="${4:-green}"
    local color="$GREEN" key_token cols
    local label_txt desc_txt line_max label_w desc_w desc_max
    local key_col_w=4 key_w key_pad label_col_w=18 label_pad
    case "$tone" in
        red) color="$RED" ;;
        yellow) color="$YELLOW" ;;
        cyan) color="$CYAN" ;;
    esac

    key_token="[${key}]"
    key_w=$(_ui_display_width "$key_token")
    key_pad=$((key_col_w - key_w))
    [ "$key_pad" -lt 1 ] && key_pad=1

    cols=$(_ui_term_cols)
    line_max=$((cols - 8))
    [ "$line_max" -lt 20 ] && line_max=20
    label_txt="$label"
    if [[ -n "$desc" ]]; then
        label_w=$(_ui_display_width "$label_txt")
        desc_w=$(_ui_display_width "$desc")
        if [ "$label_w" -lt "$label_col_w" ]; then
            label_pad=$((label_col_w - label_w))
            desc_max=$((line_max - key_col_w - 1 - label_col_w - 1))
        else
            label_pad=1
            desc_max=$((line_max - key_col_w - 1 - label_w - 1))
        fi
        if [ "$desc_max" -ge "$desc_w" ]; then
            desc_txt="$desc"
        elif [ "$desc_max" -ge 8 ]; then
            desc_txt=$(_ui_truncate_text "$desc" "$desc_max")
        else
            desc_txt=""
        fi
    else
        desc_txt=""
        label_pad=0
    fi

    printf "  ${color}%s${PLAIN}" "$key_token"
    _ui_repeat_char " " "$key_pad"
    printf "%s" "$label_txt"
    if [[ -n "$desc_txt" ]]; then
        _ui_repeat_char " " "$label_pad"
        printf "${DIM}%s${PLAIN}" "$desc_txt"
    fi
    printf "\n"
}

_menu_pair() {
    local k1="$1" l1="$2" d1="${3:-}" t1="${4:-green}"
    local k2="${5:-}" l2="${6:-}" d2="${7:-}" t2="${8:-green}"

    _menu_item "$k1" "$l1" "$d1" "$t1"
    if [[ -n "$k2" ]]; then
        _menu_item "$k2" "$l2" "$d2" "$t2"
    fi
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

_valid_hhmm() {
    local value="$1" hh mm
    [[ "$value" =~ ^[0-2][0-9]:[0-5][0-9]$ ]] || return 1
    hh="${value%%:*}"
    mm="${value##*:}"
    [ "$hh" -le 23 ] && [ "$mm" -le 59 ]
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

_restore_tty_echo() {
    if [[ -t 0 ]]; then
        stty echo icanon 2>/dev/null || stty sane 2>/dev/null || true
        return 0
    fi
    if { : 2>/dev/null < /dev/tty; }; then
        stty echo icanon 2>/dev/null < /dev/tty || stty sane 2>/dev/null < /dev/tty || true
    fi
}

read() {
    _restore_tty_echo
    builtin read "$@"
}

_read_single_key_safely() {
    local _key
    _restore_tty_echo
    if [[ -t 0 ]]; then
        IFS= builtin read -r -n 1 _key || true
    elif { : 2>/dev/null < /dev/tty; }; then
        IFS= builtin read -r -n 1 _key 2>/dev/null < /dev/tty || true
    fi
}

_press_any_key() {
    echo ""
    printf "${DIM}  继续请按任意键...${PLAIN}"
    _read_single_key_safely
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

_is_container_like() {
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

_has_time_privilege() {
    if date -s "$(date "+%H:%M:%S")" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

_show_sys_info() {
    local opsy arch kern virt gh_proxy gh_tone cols text_max
    opsy="$(_os_full)"
    arch="$(uname -m) ($(getconf LONG_BIT) Bit)"
    kern="$(uname -r)"
    virt="$(_detect_virt)"
    gh_proxy="$(_github_proxy_status_text)"
    gh_tone="$(_github_proxy_status_tone)"

    cols=$(_ui_term_cols)
    text_max=$(( (cols - 4) / 2 - 18 ))
    [ "$text_max" -lt 16 ] && text_max=16

    opsy=$(_ui_truncate_text "$opsy" "$text_max")
    arch=$(_ui_truncate_text "$arch" "$text_max")
    kern=$(_ui_truncate_text "$kern" "$text_max")
    virt=$(_ui_truncate_text "$virt" "$text_max")
    gh_proxy=$(_ui_truncate_text "$gh_proxy" "$text_max")

    printf "  ${BOLD}系统信息${PLAIN}\n"
    _separator
    _status_kv_pair "OS" "$opsy" "dim" 8 "Arch" "$arch" "dim" 8
    _status_kv_pair "Kernel" "$kern" "dim" 8 "Virt" "$virt" "dim" 8
    _status_kv_pair "GitHub" "$gh_proxy" "$gh_tone" 8 "" "" "" 8
    _separator
}

_is_alpine() {
    [ -f /etc/os-release ] || return 1
    (
        . /etc/os-release
        [[ "${ID:-}" == "alpine" ]]
    )
}

# ── Cron abstraction (Alpine busybox crond vs vixie-cron /etc/cron.d) ──

# Write a named daily cron job. On Alpine uses /etc/crontabs/root
# (no username field, no per-file env vars); elsewhere /etc/cron.d/<name>.
_cron_job_write() {
    local name="$1" minute="$2" hour="$3" cmd="$4"
    if _is_alpine; then
        mkdir -p /etc/crontabs
        _cron_job_remove "$name"
        echo "${minute} ${hour} * * * TZ=Asia/Shanghai ${cmd}  # ${name}" >> /etc/crontabs/root
    else
        mkdir -p /etc/cron.d
        cat > "/etc/cron.d/${name}" <<EOF
# Managed by VPSGo. Runs by Beijing time.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
CRON_TZ=Asia/Shanghai
${minute} ${hour} * * * root ${cmd}
EOF
        chmod 0644 "/etc/cron.d/${name}"
    fi
}

_cron_job_remove() {
    local name="$1"
    if _is_alpine; then
        sed -i "/# ${name}$/d" /etc/crontabs/root 2>/dev/null || true
    else
        rm -f "/etc/cron.d/${name}"
    fi
}

_cron_job_exists() {
    local name="$1"
    if _is_alpine; then
        [ -f /etc/crontabs/root ] && grep -q "# ${name}$" /etc/crontabs/root 2>/dev/null
    else
        [ -f "/etc/cron.d/${name}" ]
    fi
}

_cron_job_show() {
    local name="$1"
    if _is_alpine; then
        grep "# ${name}$" /etc/crontabs/root 2>/dev/null || true
    else
        cat "/etc/cron.d/${name}" 2>/dev/null || true
    fi
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
    read -rp "  实时跟踪日志? [y/N]: " follow
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
        if _is_container_like; then
            local sync_val
            sync_val=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)
            if [ "$sync_val" = "yes" ]; then
                return 0
            fi
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
    if _is_container_like && ! _has_time_privilege; then
        _warn "检测到容器环境且无时间修改权限 (CAP_SYS_TIME)。"
        _warn "无法在容器内部开启自动时间同步服务。请在宿主机上开启时间同步服务。"
        return 1
    fi

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

_time_sync_force_once() {
    if _is_container_like && ! _has_time_privilege; then
        _warn "检测到容器环境且无时间修改权限 (CAP_SYS_TIME)，无法强制执行手动时间同步。"
        _warn "请在宿主机上执行时间同步，或在宿主机为容器分配 sys_time 权限。"
        return 1
    fi

    _info "尝试强制进行一次手动时间同步..."
    local synced=0

    # 1. 尝试使用 chronyd
    if command -v chronyd >/dev/null 2>&1; then
        _info "尝试使用 chronyd 进行单次时间同步..."
        if chronyd -q 'server pool.ntp.org iburst' >/dev/null 2>&1; then
            synced=1
        fi
    fi

    # 2. 尝试使用 ntpdate
    if [[ "$synced" -eq 0 ]] && command -v ntpdate >/dev/null 2>&1; then
        _info "尝试使用 ntpdate 进行单次时间同步..."
        if ntpdate -u pool.ntp.org >/dev/null 2>&1; then
            synced=1
        fi
    fi

    # 3. 尝试使用 ntpd
    if [[ "$synced" -eq 0 ]] && command -v ntpd >/dev/null 2>&1; then
        _info "尝试使用 ntpd 进行单次时间同步..."
        if ntpd -gq >/dev/null 2>&1; then
            synced=1
        fi
    fi

    # 4. 尝试通过 HTTP 响应头同步时间
    if [[ "$synced" -eq 0 ]]; then
        _info "NTP 同步未成功，尝试通过 HTTP 响应头同步时间..."
        local http_time=""
        if command -v curl >/dev/null 2>&1; then
            http_time=$(curl -sI --connect-timeout 5 https://www.baidu.com | grep -i '^date:' | cut -d' ' -f2- | tr -d '\r')
            if [[ -z "$http_time" ]]; then
                http_time=$(curl -sI --connect-timeout 5 https://www.cloudflare.com | grep -i '^date:' | cut -d' ' -f2- | tr -d '\r')
            fi
        elif command -v wget >/dev/null 2>&1; then
            http_time=$(wget -S --spider --timeout=5 https://www.baidu.com 2>&1 | grep -i '^[[:space:]]*date:' | head -n 1 | sed 's/^[[:space:]]*[Dd]ate:[[:space:]]*//' | tr -d '\r')
        fi

        if [[ -n "$http_time" ]]; then
            if date -s "$http_time" >/dev/null 2>&1; then
                synced=1
            fi
        fi
    fi

    if [[ "$synced" -eq 1 ]]; then
        _success "手动时间同步成功，当前时间: $(date)"
        return 0
    else
        _warn "手动时间同步未成功，请检查网络连接"
        return 1
    fi
}

_time_sync_check_and_enable() {
    if _is_container_like && ! _has_time_privilege; then
        _info "检测到容器环境且无时间修改权限 (CAP_SYS_TIME)。"
        if _time_sync_is_enabled; then
            _success "系统时钟已通过宿主机同步 (NTPSynchronized=yes)"
            return 0
        else
            _warn "系统时钟未同步，且容器无权修改时间。请确保宿主机已启用 NTP 时间同步。"
            _warn "提示：如果是 Proxmox LXC 容器，可在宿主机配置文件中添加 'lxc.cap.keep: sys_time'（不推荐，更建议在宿主机同步）。"
            return 1
        fi
    fi

    _time_sync_force_once
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
    _is_container_like
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

    printf "  ${BOLD}选择队列算法${PLAIN}\n"
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

    printf "  ${BOLD}选择操作${PLAIN}\n"
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

# --- WARP 管理 ---

_warp_command_available() {
    command -v warp >/dev/null 2>&1 || command -v warp-go >/dev/null 2>&1 || command -v warp-cli >/dev/null 2>&1
}

_warp_get_cli_proxy_port() {
    local port=""
    if command -v warp-cli >/dev/null 2>&1; then
        port=$(warp-cli settings 2>/dev/null | grep -Ei 'proxy.*port|port' | grep -oE '[0-9]+' | head -n1)
    fi
    printf '%s' "${port:-30000}"
}

_warp_check_netflix_local() {
    local proxy_port="$1"
    local target_region="${2:-}"
    local ip_version="${3:-}"
    local ua="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    local proxy_opt=""
    if [ -n "$proxy_port" ] && [ "$proxy_port" -gt 0 ]; then
        proxy_opt="-x socks5://127.0.0.1:$proxy_port"
    fi
    local dns_opt=""
    if [ "$ip_version" = "4" ]; then
        dns_opt="-4"
    elif [ "$ip_version" = "6" ]; then
        dns_opt="-6"
    fi

    local code
    code=$(curl -sL -o /dev/null -A "$ua" -w "%{http_code}" --max-time 10 ${proxy_opt} ${dns_opt} "https://www.netflix.com/title/80018499")
    if [ "$code" -ne 200 ]; then
        printf "blocked"
        return 1
    fi

    local code2
    code2=$(curl -sL -o /dev/null -A "$ua" -w "%{http_code}" --max-time 10 ${proxy_opt} ${dns_opt} "https://www.netflix.com/title/70143836")
    if [ "$code2" -ne 200 ]; then
        printf "originals"
        return 2
    fi

    if [ -n "$target_region" ]; then
        local current_region=""
        current_region=$(curl -s --max-time 5 ${proxy_opt} ${dns_opt} "https://ipinfo.io/country" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
        if [ "$current_region" != "$(echo "$target_region" | tr '[:upper:]' '[:lower:]')" ]; then
            printf "region_mismatch:%s" "$current_region"
            return 3
        fi
    fi

    printf "unlocked"
    return 0
}

_warp_refresh_netflix_local_loop() {
    local proxy_port="$1"
    local target_region="${2:-}"
    local ip_version="${3:-}"
    local max_minutes="${4:-120}"
    local start_time
    start_time=$(date +%s)
    local max_seconds=$((max_minutes * 60))
    local attempt=0

    _info "开始本地 Netflix IP 轮换 (Socks5 端口: ${proxy_port}, 目标地区: ${target_region:-任意}, IP类型: IPv${ip_version:-自动})..."
    
    while true; do
        if [ "$max_seconds" -gt 0 ]; then
            local current_time
            current_time=$(date +%s)
            local elapsed=$((current_time - start_time))
            if [ "$elapsed" -ge "$max_seconds" ]; then
                _error_no_exit "达到最大运行时间限制 (${max_minutes} 分钟)，停止刷新。"
                return 1
            fi
        fi

        local status
        status=$(_warp_check_netflix_local "$proxy_port" "$target_region" "$ip_version")
        
        case "$status" in
            unlocked)
                _success "成功解锁 Netflix! 目标地区: ${target_region:-任意}"
                return 0
                ;;
            blocked)
                _info "Netflix 状态: 被封锁 (Blocked)。正在更换 IP..."
                ;;
            originals)
                _info "Netflix 状态: 仅支持自制剧 (Originals Only)。正在更换 IP..."
                ;;
            region_mismatch:*)
                local actual_region="${status##*:}"
                _info "Netflix 状态: 已解锁但地区不匹配 (当前: ${actual_region}, 目标: ${target_region})。正在更换 IP..."
                ;;
            *)
                _warn "Netflix 检测异常 (${status})。正在更换 IP..."
                ;;
        esac

        ((attempt++))
        if [ "$attempt" -ge 5 ]; then
            _warn "官方 warp-cli 已重试 ${attempt} 次仍无法解锁 Netflix。"
            _warn "提示：Cloudflare 官方 IP 库已被 Netflix 广泛屏蔽，且官方客户端不支持自定义 Endpoint (优选 IP)。"
            _warn "在此 VPS 上，官方 warp-cli 无法成功刷出解锁 Netflix 的 IP。"
            return 1
        fi

        warp-cli --accept-tos disconnect >/dev/null 2>&1
        sleep 2
        warp-cli --accept-tos connect >/dev/null 2>&1
        sleep 5
    done
}

_warp_install_cli_packages() {
    local os
    os="$(_os)"
    if [[ "$os" != "debian" && "$os" != "ubuntu" && "$os" != "centos" && "$os" != "rhel" && "$os" != "rocky" && "$os" != "almalinux" ]]; then
        _error_no_exit "错误：此功能目前仅支持 Debian, Ubuntu, CentOS, RHEL, Rocky Linux 或 AlmaLinux 系统。"
        return 1
    fi

    _info "开始安装 Cloudflare WARP 官方客户端 (warp-cli)..."

    # Install dependencies
    if [[ "$os" == "debian" || "$os" == "ubuntu" ]]; then
        _info "安装 Debian/Ubuntu 依赖包..."
        apt-get update -qq || true
        apt-get install -y -qq curl gnupg ca-certificates lsb-release >/dev/null 2>&1 || true

        _info "导入 Cloudflare GPG 密钥..."
        mkdir -p /usr/share/keyrings
        if ! curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg; then
            _error_no_exit "导入 Cloudflare GPG 密钥失败"
            return 1
        fi

        _info "配置 Cloudflare APT 源..."
        local codename=""
        if [ -f /etc/os-release ]; then
            . /etc/os-release
            codename="${VERSION_CODENAME:-}"
        fi
        if [ -z "$codename" ] && command -v lsb_release >/dev/null 2>&1; then
            codename=$(lsb_release -cs)
        fi
        if [ -z "$codename" ]; then
            if [ "$os" == "ubuntu" ]; then
                codename="jammy"
            else
                codename="bookworm"
            fi
        fi

        echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $codename main" | tee /etc/apt/sources.list.d/cloudflare-client.list >/dev/null

        _info "更新软件源并安装 cloudflare-warp..."
        apt-get update -y
        if ! apt-get install -y cloudflare-warp; then
            _error_no_exit "安装 cloudflare-warp 失败，请检查网络或系统版本。"
            return 1
        fi

    elif [[ "$os" == "centos" || "$os" == "rhel" || "$os" == "rocky" || "$os" == "almalinux" ]]; then
        _info "配置 Cloudflare YUM/DNF 源..."
        if ! curl -fsSL https://pkg.cloudflareclient.com/cloudflare-warp-ascii.repo | tee /etc/yum.repos.d/cloudflare-warp.repo >/dev/null; then
            _error_no_exit "配置 Cloudflare YUM/DNF 源失败"
            return 1
        fi

        _info "更新缓存并安装 cloudflare-warp..."
        if command -v dnf >/dev/null 2>&1; then
            dnf makecache || true
            if ! dnf install -y cloudflare-warp; then
                _error_no_exit "安装 cloudflare-warp 失败，请检查网络或系统版本。"
                return 1
            fi
        else
            yum makecache || true
            if ! yum install -y cloudflare-warp; then
                _error_no_exit "安装 cloudflare-warp 失败，请检查网络或系统版本。"
                return 1
            fi
        fi
    fi

    # Start and enable the service
    _info "启动并启用 warp-svc 服务..."
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload || true
        systemctl enable --now warp-svc || true
        systemctl start warp-svc || true
    elif [ -x "$(type -p rc-service)" ]; then
        rc-service warp-svc start || true
        rc-update add warp-svc default || true
    fi

    sleep 2

    # Verify command availability
    if ! command -v warp-cli >/dev/null 2>&1; then
        _error_no_exit "未检测到 warp-cli 命令，可能安装未成功。"
        return 1
    fi

    return 0
}

_warp_configure_cli_interactive() {
    _info "正在配置 warp-cli..."

    # 1. Registration
    if ! warp-cli --accept-tos registration new; then
        _warn "WARP 账户注册失败或已注册过，继续进行其他配置。"
    fi

    # 2. Mode proxy
    _info "设置 WARP 运行模式为 Proxy 代理模式..."
    if ! warp-cli --accept-tos mode proxy; then
        _error_no_exit "设置 Proxy 模式失败"
    fi

    # 3. Port settings
    local proxy_port
    while true; do
        read -rp "  请输入 Socks5 代理端口 (1024-65535, 默认 30000): " proxy_port
        proxy_port="${proxy_port:-30000}"
        if _is_digit "$proxy_port" && [ "$proxy_port" -ge 1024 ] && [ "$proxy_port" -le 65535 ]; then
            break
        fi
        _warn "端口无效，请输入 1024 到 65535 之间的数字。"
    done

    _info "设置 Socks5 代理端口为 ${proxy_port}..."
    if ! warp-cli --accept-tos proxy port "$proxy_port"; then
        _error_no_exit "设置代理端口失败"
    fi

    # 4. MASQUE protocol choice
    local use_masque
    read -rp "  是否使用 MASQUE 协议连接? [Y/n] (默认 Y): " use_masque
    use_masque="${use_masque:-y}"
    if [[ "$use_masque" =~ ^[Yy] ]]; then
        _info "设置 WARP 传输协议为 MASQUE..."
        warp-cli --accept-tos tunnel protocol set MASQUE || _warn "设置 MASQUE 协议失败，可能当前版本不支持或配置错误。"
    else
        _info "设置 WARP 传输协议为 Wireguard..."
        warp-cli --accept-tos tunnel protocol set wireguard || true
    fi

    # 5. Connect WARP
    _info "正在连接 WARP..."
    if ! warp-cli --accept-tos connect; then
        _error_no_exit "连接 WARP 失败"
        _press_any_key
        return 1
    fi

    # 6. Verify connection via proxy
    _info "正在通过 Socks5 代理验证 WARP 出口 IP (大约耗时 5 秒)..."
    sleep 5
    local warp_ip=""
    warp_ip=$(curl -s -m 8 --proxy socks5://127.0.0.1:"$proxy_port" ifconfig.me || true)
    if [ -n "$warp_ip" ]; then
        _success "WARP-cli 安装并配置成功！"
        _status_kv "Socks5 代理" "socks5://127.0.0.1:${proxy_port}" "green" 15
        _status_kv "WARP 出口 IP" "$warp_ip" "green" 15
    else
        _warn "通过 Socks5 代理获取 IP 失败。这可能是因为 WARP 连接延迟，或者没有成功启用。"
        _info "你可以稍后通过 '刷新 WARP 网络' 来重试连接。"
    fi

    # 7. Optionally check IP quality
    local check_ip_quality
    read -rp "  是否使用 IP.Check.Place 测试 WARP IP 质量? [y/N] (默认 N): " check_ip_quality
    if [[ "$check_ip_quality" =~ ^[Yy] ]]; then
        _info "正在测试 IP 质量..."
        bash <(curl -Ls IP.Check.Place) -x socks5://127.0.0.1:"$proxy_port"
    fi

    _press_any_key
}

_warp_uninstall_cli_packages() {
    _info "正在卸载 cloudflare-warp..."
    
    # 1. Stop and disable the service
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now warp-svc >/dev/null 2>&1 || true
    fi
    if [ -x "$(type -p rc-service)" ]; then
        rc-service warp-svc stop >/dev/null 2>&1 || true
        rc-update del warp-svc default >/dev/null 2>&1 || true
    fi

    # 2. Package removal
    local os
    os="$(_os)"
    if [[ "$os" == "debian" || "$os" == "ubuntu" ]]; then
        apt-get purge -y cloudflare-warp || apt-get remove -y cloudflare-warp
        rm -f /etc/apt/sources.list.d/cloudflare-client.list
        apt-get update -qq || true
    elif [[ "$os" == "centos" || "$os" == "rhel" || "$os" == "rocky" || "$os" == "almalinux" ]]; then
        if command -v dnf >/dev/null 2>&1; then
            dnf remove -y cloudflare-warp
        else
            yum remove -y cloudflare-warp
        fi
        rm -f /etc/yum.repos.d/cloudflare-warp.repo
    fi

    # 3. Clean files
    rm -rf /var/lib/cloudflare-warp /etc/cloudflare-warp
    hash -r 2>/dev/null || true
    _success "cloudflare-warp 卸载完成。"
}

_warp_cli_manage_screen() {
    _header "warp-cli 管理"
    
    local status="未运行"
    if pgrep -x warp-svc >/dev/null 2>&1; then
        status="运行中"
    fi
    local port
    port=$(warp-cli settings 2>/dev/null | grep -Ei 'proxy.*port|port' | grep -oE '[0-9]+' | head -n1)
    port="${port:-30000}"
    local protocol
    protocol=$(warp-cli settings 2>/dev/null | grep -Ei 'protocol' | awk '{print $NF}')
    protocol="${protocol:-Wireguard}"

    _status_kv "服务状态" "$status" "$([ "$status" = "运行中" ] && printf "green" || printf "red")" 12
    _status_kv "代理端口" "Socks5 127.0.0.1:${port}" "cyan" 12
    _status_kv "传输协议" "$protocol" "cyan" 12
    _separator

    _menu_pair "1" "连接 WARP" "connect" "green" "2" "断开 WARP" "disconnect" "yellow"
    _menu_pair "3" "重启守护进程" "warp-svc" "green" "4" "重新配置端口" "修改 Socks5 端口" "cyan"
    _menu_pair "5" "切换传输协议" "MASQUE / Wireguard" "cyan" "6" "重新注册账号" "registration new" "yellow"
    _menu_pair "7" "完整覆盖安装" "更新/重装软件包" "cyan" "8" "卸载 warp-cli" "清理配置" "red"
    _separator
    _menu_item "0" "返回上级菜单" "" "red"
    _separator
}

_warp_cli_manage() {
    if ! command -v warp-cli >/dev/null 2>&1; then
        local confirm_install
        read -rp "  未检测到 warp-cli，是否开始安装? [Y/n]: " confirm_install
        confirm_install="${confirm_install:-y}"
        if [[ "$confirm_install" =~ ^[Yy] ]]; then
            if _warp_install_cli_packages; then
                _warp_configure_cli_interactive
            fi
        fi
        return
    fi

    while true; do
        _ui_print_screen _warp_cli_manage_screen
        local ch
        read -rp "  选择 [0-8]: " ch
        case "$ch" in
            1)
                _info "正在连接 WARP..."
                warp-cli --accept-tos connect
                _press_any_key
                ;;
            2)
                _info "正在断开 WARP..."
                warp-cli --accept-tos disconnect
                _press_any_key
                ;;
            3)
                _info "正在重启 warp-svc 服务..."
                if command -v systemctl >/dev/null 2>&1; then
                    systemctl restart warp-svc
                elif [ -x "$(type -p rc-service)" ]; then
                    rc-service warp-svc restart
                fi
                _press_any_key
                ;;
            4)
                local proxy_port
                while true; do
                    read -rp "  请输入新的 Socks5 代理端口 (1024-65535, 默认 30000): " proxy_port
                    proxy_port="${proxy_port:-30000}"
                    if _is_digit "$proxy_port" && [ "$proxy_port" -ge 1024 ] && [ "$proxy_port" -le 65535 ]; then
                        break
                    fi
                    _warn "端口无效，请输入 1024 到 65535 之间的数字。"
                done
                _info "设置 Socks5 代理端口为 ${proxy_port}..."
                warp-cli --accept-tos proxy port "$proxy_port"
                _press_any_key
                ;;
            5)
                local current_proto
                current_proto=$(warp-cli settings 2>/dev/null | grep -Ei 'protocol' | awk '{print $NF}' | tr '[:upper:]' '[:lower:]')
                if [ "$current_proto" = "masque" ]; then
                    _info "切换协议至 Wireguard..."
                    warp-cli --accept-tos tunnel protocol set wireguard
                else
                    _info "切换协议至 MASQUE..."
                    warp-cli --accept-tos tunnel protocol set MASQUE || _warn "设置 MASQUE 协议失败，可能当前版本不支持。"
                fi
                _press_any_key
                ;;
            6)
                _info "重新注册 WARP 账号..."
                warp-cli --accept-tos registration new
                _press_any_key
                ;;
            7)
                if _warp_install_cli_packages; then
                    _warp_configure_cli_interactive
                fi
                ;;
            8)
                local confirm_uninstall
                read -rp "  确定要卸载 warp-cli 吗? [y/N]: " confirm_uninstall
                if [[ "$confirm_uninstall" =~ ^[Yy] ]]; then
                    _warp_uninstall_cli_packages
                fi
                _press_any_key
                ;;
            0) return ;;
            * ) _error_no_exit "无效选项: ${ch}"; sleep 1 ;;
        esac
    done
}

_warp_install_cli() {
    _warp_cli_manage
}

_warp_run_upstream_script() {
    local script_type="${1:-warp-sh}"
    local name="warp-sh"
    local url="$_WARP_SH_URL"
    local project="https://github.com/fscarmen/warp-sh"

    if [ "$script_type" = "warp-go" ]; then
        name="warp-go"
        url="$_WARP_GO_URL"
        project="https://gitlab.com/fscarmen/warp"
    fi

    _header "${name} 管理"
    _info "打开 ${name} 原脚本菜单，用于安装、切换或卸载 WARP。"
    _status_kv "项目" "$project" "cyan" 10
    _status_kv "脚本" "$url" "cyan" 10
    echo ""

    if ! command -v bash >/dev/null 2>&1; then
        _error_no_exit "未检测到 bash，无法运行 WARP 脚本。"
        _press_any_key
        return
    fi
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        _error_no_exit "需要 curl 或 wget 下载 WARP 脚本。"
        _press_any_key
        return
    fi

    local confirm tmp_file
    read -rp "  继续? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy] ]]; then
        _info "已取消"
        _press_any_key
        return
    fi

    tmp_file=$(_mktemp_file vpsgo-warp .sh) || {
        _error_no_exit "创建临时文件失败"
        _press_any_key
        return
    }

    if command -v curl >/dev/null 2>&1; then
        if ! curl -fsSL -o "$tmp_file" "$url"; then
            rm -f "$tmp_file"
            _error_no_exit "下载 WARP 脚本失败"
            _press_any_key
            return
        fi
    else
        if ! wget -qO "$tmp_file" "$url"; then
            rm -f "$tmp_file"
            _error_no_exit "下载 WARP 脚本失败"
            _press_any_key
            return
        fi
    fi

    chmod 0755 "$tmp_file" 2>/dev/null || true
    bash "$tmp_file"
    rm -f "$tmp_file"
    _press_any_key
}

_warp_run_command() {
    local mode="$1"
    shift || true

    if [ "$mode" = "n" ]; then
        if [ -s /etc/wireguard/proxy.conf ] || pgrep -x wireproxy >/dev/null 2>&1; then
            _info "检测到已安装 wireproxy，重启/启动服务以刷新 network..."
            if command -v systemctl >/dev/null 2>&1; then
                systemctl restart wireproxy || systemctl start wireproxy
                return $?
            elif [ -x "$(type -p rc-service)" ]; then
                rc-service wireproxy restart || rc-service wireproxy start
                return $?
            else
                killall -HUP wireproxy || killall wireproxy || true
                local wp_bin
                wp_bin=$(command -v wireproxy)
                if [ -n "$wp_bin" ] && [ -x "$wp_bin" ]; then
                    "$wp_bin" -c /etc/wireguard/proxy.conf >/dev/null 2>&1 &
                    return 0
                fi
                return 1
            fi
        elif command -v warp-go >/dev/null 2>&1 || [ -s /opt/warp-go/warp.conf ]; then
            _info "检测到已安装 warp-go，重启服务以刷新 network..."
            if command -v systemctl >/dev/null 2>&1; then
                systemctl restart warp-go
                return $?
            elif [ -x "$(type -p rc-service)" ]; then
                rc-service warp-go restart
                return $?
            else
                kill -15 $(pgrep warp-go) >/dev/null 2>&1 || true
                sleep 1
                if [ -x /opt/warp-go/warp-go ]; then
                    /opt/warp-go/warp-go --config=/opt/warp-go/warp.conf 2>&1 &
                    return 0
                fi
                return 1
            fi
        elif command -v warp-cli >/dev/null 2>&1; then
            _info "检测到已安装 warp-cli，重连以刷新网络..."
            if ! pgrep -x warp-svc >/dev/null 2>&1; then
                if command -v systemctl >/dev/null 2>&1; then
                    systemctl start warp-svc || true
                elif [ -x "$(type -p rc-service)" ]; then
                    rc-service warp-svc start || true
                fi
                sleep 1
            fi
            warp-cli --accept-tos disconnect >/dev/null 2>&1
            sleep 2
            warp-cli --accept-tos connect
            return $?
        fi
    elif [ "$mode" = "i" ]; then
        local region="${1:-}"
        if command -v warp-cli >/dev/null 2>&1 && ! command -v warp >/dev/null 2>&1 && ! command -v warp-go >/dev/null 2>&1; then
            _error_no_exit "官方 warp-cli 不支持刷 Netflix 功能（因为官方客户端不支持自定义 Endpoint 优选 IP 且官方 IP 库已被 Netflix 封锁）。"
            return 1
        fi
    fi

    if command -v warp >/dev/null 2>&1; then
        warp "$mode" "$@"
        return $?
    elif command -v warp-go >/dev/null 2>&1; then
        warp-go "$mode" "$@"
        return $?
    fi

    if command -v curl >/dev/null 2>&1; then
        bash <(curl -fsSL "$_WARP_SH_URL") "$mode" "$@"
        return $?
    fi
    if command -v wget >/dev/null 2>&1; then
        local tmp_file
        tmp_file=$(_mktemp_file vpsgo-warp .sh) || return 1
        wget -qO "$tmp_file" "$_WARP_SH_URL" || {
            rm -f "$tmp_file"
            return 1
        }
        bash "$tmp_file" "$mode" "$@"
        local rc=$?
        rm -f "$tmp_file"
        return "$rc"
    fi
    return 1
}

_warp_refresh_now() {
    _header "WARP 网络刷新"

    if ! _warp_command_available; then
        _warn "未检测到 warp 命令，将临时下载脚本执行。"
    fi

    _info "刷新 WARP 当前网络。"
    if ! _warp_run_command n; then
        _error_no_exit "WARP 网络刷新失败，请先运行 WARP 安装脚本。"
    fi
    _press_any_key
}

_warp_prompt_netflix_ip_version() {
    local choice
    echo ""
    printf "  ${BOLD}Netflix 刷 IP 类型${PLAIN}\n"
    _separator
    _menu_pair "1" "刷 WARP IPv4" "" "green" "2" "刷 WARP IPv6" "默认" "green"
    _separator
    read -rp "  选择 [1-2]（默认 2）: " choice
    choice="${choice:-2}"
    case "$choice" in
        1|2) _WARP_NETFLIX_IP_CHOICE="$choice" ;;
        *) _WARP_NETFLIX_IP_CHOICE="2" ;;
    esac
}

_warp_prompt_netflix_region() {
    local region
    read -rp "  Netflix 目标地区 [默认当前地区，示例 hk/sg/jp/us]: " region
    region=$(printf '%s' "${region:-}" | tr '[:upper:]' '[:lower:]')
    if [[ -n "$region" && ! "$region" =~ ^[a-z]{2}$ ]]; then
        _warn "地区格式无效，将使用当前地区。"
        region=""
    fi
    _WARP_NETFLIX_REGION="$region"
}

_warp_refresh_netflix_now() {
    _header "WARP Netflix 刷 IP"

    if command -v warp-cli >/dev/null 2>&1 && ! command -v warp >/dev/null 2>&1 && ! command -v warp-go >/dev/null 2>&1; then
        _error_no_exit "官方 warp-cli 不支持刷 Netflix 功能（因为官方客户端不支持自定义 Endpoint 优选 IP 且官方 IP 库已被 Netflix 封锁）。"
        _press_any_key
        return 1
    fi

    _info "更换 WARP IP，直到 Netflix 检测通过。"

    local ip_choice region
    _warp_prompt_netflix_ip_version
    _warp_prompt_netflix_region
    ip_choice="$_WARP_NETFLIX_IP_CHOICE"
    region="$_WARP_NETFLIX_REGION"

    echo ""
    _status_kv "IP 类型" "WARP IPv$([ "$ip_choice" = 1 ] && printf 4 || printf 6)" "green" 10
    _status_kv "地区" "${region:-当前地区}" "green" 10

    if ! printf '%s\n%s\n' "$ip_choice" "$ip_choice" | _warp_run_command i "$region"; then
        _error_no_exit "WARP Netflix 刷 IP 失败，请确认 WARP 已安装并可用。"
    fi
    _press_any_key
}

_warp_valid_hhmm() {
    _valid_hhmm "$1"
}

_warp_write_refresh_script() {
    local mode="$1" ip_choice="$2" region="$3" max_minutes="$4"

    cat > "$_WARP_REFRESH_SCRIPT" <<EOF
#!/usr/bin/env bash
set -uo pipefail

export TZ=Asia/Shanghai
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

MODE="${mode}"
IP_CHOICE="${ip_choice}"
REGION="${region}"
MAX_MINUTES="${max_minutes}"
LOG_FILE="${_WARP_REFRESH_LOG}"
LOCK_FILE="/run/vpsgo-warp-refresh.lock"

mkdir -p "\$(dirname "\$LOG_FILE")" /run
touch "\$LOG_FILE"
exec 9>"\$LOCK_FILE"
if command -v flock >/dev/null 2>&1; then
    flock -n 9 || {
        printf '[%s] Previous WARP refresh is still running, skip.\\n' "\$(date '+%F %T %Z')" >> "\$LOG_FILE"
        exit 0
    }
fi

_check_netflix_local() {
    local proxy_port="\$1"
    local target_region="\${2:-}"
    local ip_version="\${3:-}"
    local ua="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    local proxy_opt=""
    if [ -n "\$proxy_port" ] && [ "\$proxy_port" -gt 0 ]; then
        proxy_opt="-x socks5://127.0.0.1:\$proxy_port"
    fi
    local dns_opt=""
    if [ "\$ip_version" = "4" ]; then
        dns_opt="-4"
    elif [ "\$ip_version" = "6" ]; then
        dns_opt="-6"
    fi

    local code
    code=\$(curl -sL -o /dev/null -A "\$ua" -w "%{http_code}" --max-time 10 \${proxy_opt} \${dns_opt} "https://www.netflix.com/title/80018499")
    if [ "\$code" -ne 200 ]; then
        printf "blocked"
        return 1
    fi

    local code2
    code2=\$(curl -sL -o /dev/null -A "\$ua" -w "%{http_code}" --max-time 10 \${proxy_opt} \${dns_opt} "https://www.netflix.com/title/70143836")
    if [ "\$code2" -ne 200 ]; then
        printf "originals"
        return 2
    fi

    if [ -n "\$target_region" ]; then
        local current_region=""
        current_region=\$(curl -s --max-time 5 \${proxy_opt} \${dns_opt} "https://ipinfo.io/country" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
        if [ "\$current_region" != "\$(echo "\$target_region" | tr '[:upper:]' '[:lower:]')" ]; then
            printf "region_mismatch:\%s" "\$current_region"
            return 3
        fi
    fi

    printf "unlocked"
    return 0
}

_refresh_netflix_local_loop() {
    local proxy_port="\$1"
    local target_region="\${2:-}"
    local ip_version="\${3:-}"
    local max_mins="\${4:-120}"
    local start_time
    start_time=\$(date +%s)
    local max_seconds=\$((max_mins * 60))
    local attempt=0

    printf '[%s] Start local Netflix IP rotation for warp-cli (port=%s, region=%s, ip_ver=%s)\\n' "\$(date '+%F %T %Z')" "\$proxy_port" "\${target_region:-any}" "\${ip_version:-auto}"
    
    while true; do
        if [ "\$max_seconds" -gt 0 ]; then
            local current_time
            current_time=\$(date +%s)
            local elapsed=\$((current_time - start_time))
            if [ "\$elapsed" -ge "\$max_seconds" ]; then
                printf '[%s] Reached maximum time limit (%s minutes), stopping.\\n' "\$(date '+%F %T %Z')" "\$max_mins"
                return 1
            fi
        fi

        local status
        status=\$(_check_netflix_local "\$proxy_port" "\$target_region" "\$ip_version")
        
        case "\$status" in
            unlocked)
                printf '[%s] Successfully unlocked Netflix! Region: %s\\n' "\$(date '+%F %T %Z')" "\${target_region:-any}"
                return 0
                ;;
            blocked)
                printf '[%s] Netflix blocked. Rotating IP...\\n' "\$(date '+%F %T %Z')"
                ;;
            originals)
                printf '[%s] Netflix Originals only. Rotating IP...\\n' "\$(date '+%F %T %Z')"
                ;;
            region_mismatch:*)
                local actual_region="\${status##*:}"
                printf '[%s] Netflix unlocked but region mismatch (current: %s, target: %s). Rotating IP...\\n' "\$(date '+%F %T %Z')" "\$actual_region" "\$target_region"
                ;;
            *)
                printf '[%s] Netflix check anomaly (%s). Rotating IP...\\n' "\$(date '+%F %T %Z')" "\$status"
                ;;
        esac

        attempt=\$((attempt + 1))
        if [ "\$attempt" -ge 5 ]; then
            printf '[%s] Official warp-cli retried %s times but still unable to unlock Netflix. Cloudflare IPs are blocked, and warp-cli does not support custom endpoints. Exiting.\\n' "\$(date '+%F %T %Z')" "\$attempt"
            return 1
        fi

        warp-cli --accept-tos disconnect >/dev/null 2>&1
        sleep 2
        warp-cli --accept-tos connect >/dev/null 2>&1
        sleep 5
    done
}

run_warp() {
    if [[ "\$1" == "n" ]]; then
        if [ -s /etc/wireguard/proxy.conf ] || pgrep -x wireproxy >/dev/null 2>&1; then
            printf '[%s] wireproxy detected, restarting/starting service...\\n' "\$(date '+%F %T %Z')"
            if command -v systemctl >/dev/null 2>&1; then
                systemctl restart wireproxy || systemctl start wireproxy
                return \$?
            elif [ -x "\$(type -p rc-service)" ]; then
                rc-service wireproxy restart || rc-service wireproxy start
                return \$?
            else
                killall -HUP wireproxy || killall wireproxy || true
                local wp_bin
                wp_bin=\$(command -v wireproxy)
                if [ -n "\$wp_bin" ] && [ -x "\$wp_bin" ]; then
                    "\$wp_bin" -c /etc/wireguard/proxy.conf >/dev/null 2>&1 &
                    return 0
                fi
                return 1
            fi
        elif command -v warp-go >/dev/null 2>&1 || [ -s /opt/warp-go/warp.conf ]; then
            printf '[%s] warp-go detected, restarting service...\\n' "\$(date '+%F %T %Z')"
            if command -v systemctl >/dev/null 2>&1; then
                systemctl restart warp-go
                return \$?
            elif [ -x "\$(type -p rc-service)" ]; then
                rc-service warp-go restart
                return \$?
            else
                kill -15 \$(pgrep warp-go) >/dev/null 2>&1 || true
                sleep 1
                if [ -x /opt/warp-go/warp-go ]; then
                    /opt/warp-go/warp-go --config=/opt/warp-go/warp.conf 2>&1 &
                    return 0
                fi
                return 1
            fi
        elif command -v warp-cli >/dev/null 2>&1; then
            printf '[%s] warp-cli detected, reconnecting client...\\n' "\$(date '+%F %T %Z')"
            if ! pgrep -x warp-svc >/dev/null 2>&1; then
                if command -v systemctl >/dev/null 2>&1; then
                    systemctl start warp-svc || true
                elif [ -x "\$(type -p rc-service)" ]; then
                    rc-service warp-svc start || true
                fi
                sleep 1
            fi
            warp-cli --accept-tos disconnect >/dev/null 2>&1
            sleep 2
            warp-cli --accept-tos connect
            return \$?
        fi
    elif [[ "\$1" == "i" ]]; then
        local region="\${2:-}"
        if command -v warp-cli >/dev/null 2>&1; then
            local ip_choice=""
            if [ ! -t 0 ]; then
                read -r ip_choice || true
            fi
            local ip_ver=""
            if [ "\$ip_choice" = "1" ]; then
                ip_ver="4"
            elif [ "\$ip_choice" = "2" ]; then
                ip_ver="6"
            fi
            local port=""
            port=\$(warp-cli settings 2>/dev/null | grep -Ei 'proxy.*port|port' | grep -oE '[0-9]+' | head -n1)
            port="\${port:-30000}"
            _refresh_netflix_local_loop "\$port" "\$region" "\$ip_ver" "\$MAX_MINUTES"
            return \$?
        fi
    fi

    if command -v warp >/dev/null 2>&1; then
        warp "$@"
        return \$?
    elif command -v warp-go >/dev/null 2>&1; then
        warp-go "$@"
        return \$?
    fi
    if command -v curl >/dev/null 2>&1; then
        bash <(curl -fsSL "${_WARP_SH_URL}") "\$@"
        return \$?
    fi
    printf '[%s] Missing warp command and curl.\\n' "\$(date '+%F %T %Z')"
    return 1
}

run_with_timeout() {
    if [[ "\$MAX_MINUTES" =~ ^[0-9]+$ ]] && [ "\$MAX_MINUTES" -gt 0 ]; then
        "\$@" <&0 &
        cmd_pid=\$!
        (
            sleep "\${MAX_MINUTES}m"
            pkill -TERM -P "\$cmd_pid" >/dev/null 2>&1 || true
            kill "\$cmd_pid" >/dev/null 2>&1 || true
        ) &
        timer_pid=\$!
        wait "\$cmd_pid"
        rc=\$?
        kill "\$timer_pid" >/dev/null 2>&1 || true
        wait "\$timer_pid" 2>/dev/null || true
        return "\$rc"
    else
        "\$@"
    fi
}

{
    printf '\\n[%s] Start VPSGo WARP refresh, mode=%s, region=%s, ip_choice=%s\\n' "\$(date '+%F %T %Z')" "\$MODE" "\${REGION:-current}" "\${IP_CHOICE:-auto}"
    case "\$MODE" in
        network)
            run_warp n
            ;;
        netflix)
            if [ -n "\$REGION" ]; then
                printf '%s\\n%s\\n' "\$IP_CHOICE" "\$IP_CHOICE" | run_with_timeout run_warp i "\$REGION"
            else
                printf '%s\\n%s\\n' "\$IP_CHOICE" "\$IP_CHOICE" | run_with_timeout run_warp i
            fi
            ;;
        *)
            printf '[%s] Invalid mode: %s\\n' "\$(date '+%F %T %Z')" "\$MODE"
            exit 1
            ;;
    esac
    rc=\$?
    printf '[%s] Finish VPSGo WARP refresh, rc=%s\\n' "\$(date '+%F %T %Z')" "\$rc"
    exit "\$rc"
} >> "\$LOG_FILE" 2>&1
EOF
    chmod 0755 "$_WARP_REFRESH_SCRIPT"
}

_warp_configure_refresh_cron() {
    _header "WARP 定时刷新"

    echo ""
    printf "  ${BOLD}刷新类型${PLAIN}\n"
    _separator
    _menu_pair "1" "刷新 WARP 网络" "重连 WARP" "green" "2" "刷 Netflix IP" "更换解锁 IP" "green"
    _separator

    local mode_choice mode ip_choice="" region="" time_hhmm hour minute max_minutes="120"
    read -rp "  选择 [1-2]: " mode_choice
    case "$mode_choice" in
        1) mode="network" ;;
        2)
            if command -v warp-cli >/dev/null 2>&1 && ! command -v warp >/dev/null 2>&1 && ! command -v warp-go >/dev/null 2>&1; then
                _error_no_exit "官方 warp-cli 不支持刷 Netflix IP 的定时任务（官方客户端不支持自定义 Endpoint 优选 IP 且官方 IP 库已被 Netflix 封锁）。"
                _press_any_key
                return
            fi
            mode="netflix"
            _warp_prompt_netflix_ip_version
            _warp_prompt_netflix_region
            ip_choice="$_WARP_NETFLIX_IP_CHOICE"
            region="$_WARP_NETFLIX_REGION"
            read -rp "  单次最多运行分钟数 [默认 120，0 表示不限制]: " max_minutes
            max_minutes="${max_minutes:-120}"
            if ! _is_digit "$max_minutes"; then
                _warn "运行时长格式无效，使用默认 120 分钟。"
                max_minutes="120"
            fi
            ;;
        *)
            _error_no_exit "无效选项: ${mode_choice}"
            _press_any_key
            return
            ;;
    esac

    echo ""
    _info "输入北京时间，格式 HH:MM，例如 03:30。"
    read -rp "  每天执行时间 [HH:MM]: " time_hhmm
    if ! _warp_valid_hhmm "$time_hhmm"; then
        _error_no_exit "时间格式无效，请使用 HH:MM，例如 03:30。"
        _press_any_key
        return
    fi

    hour="${time_hhmm%%:*}"
    minute="${time_hhmm##*:}"
    hour=$((10#$hour))
    minute=$((10#$minute))

    _warp_write_refresh_script "$mode" "$ip_choice" "$region" "$max_minutes"
    _cron_job_write "vpsgo-warp-refresh" "$minute" "$hour" "$_WARP_REFRESH_SCRIPT"

    _restart_first_available_service cron crond >/dev/null 2>&1 || true

    echo ""
    _success "WARP 定时刷新已配置"
    _status_kv "时间" "每天北京时间 ${time_hhmm}" "green" 12
    _status_kv "模式" "$([ "$mode" = network ] && printf '刷新 WARP 网络' || printf '刷 Netflix IP')" "green" 12
    [ "$mode" = netflix ] && _status_kv "Netflix" "IPv$([ "$ip_choice" = 1 ] && printf 4 || printf 6) ${region:-当前地区}" "green" 12
    _status_kv "日志" "$_WARP_REFRESH_LOG" "cyan" 12
    _press_any_key
}

_warp_show_refresh_cron() {
    _header "WARP 定时刷新状态"

    if _cron_job_exists "vpsgo-warp-refresh"; then
        printf "  ${BOLD}Cron 配置${PLAIN}\n"
        _separator
        _cron_job_show "vpsgo-warp-refresh" | sed 's/^/    /'
    else
        _warn "未检测到 WARP 定时刷新配置。"
    fi

    if [ -f "$_WARP_REFRESH_SCRIPT" ]; then
        echo ""
        _status_kv "执行脚本" "$_WARP_REFRESH_SCRIPT" "cyan" 12
    fi
    if [ -f "$_WARP_REFRESH_LOG" ]; then
        echo ""
        printf "  ${BOLD}最近日志${PLAIN}\n"
        _separator
        tail -n 30 "$_WARP_REFRESH_LOG" | sed 's/^/    /'
    fi
    _press_any_key
}

_warp_remove_refresh_cron() {
    _header "删除 WARP 定时刷新"

    if ! _cron_job_exists "vpsgo-warp-refresh" && [ ! -f "$_WARP_REFRESH_SCRIPT" ]; then
        _info "未检测到 WARP 定时刷新配置。"
        _press_any_key
        return
    fi

    local confirm
    read -rp "  确认删除 WARP 定时刷新? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy] ]]; then
        _info "已取消"
        _press_any_key
        return
    fi

    _cron_job_remove "vpsgo-warp-refresh"
    rm -f "$_WARP_REFRESH_SCRIPT"
    _restart_first_available_service cron crond >/dev/null 2>&1 || true
    _success "已删除 WARP 定时刷新配置。"
    _press_any_key
}

_warp_manage_screen() {
    _header "WARP 管理"
    _menu_pair "1" "安装/管理 warp-cli" "官方客户端" "green"
    _menu_pair "2" "打开 warp-sh" "安装/管理 WARP" "green" "3" "打开 warp-go" "安装/管理 warp-go" "green"
    _menu_pair "4" "刷新 WARP 网络" "重连 WARP" "green" "5" "刷 Netflix IP" "IPv4/IPv6" "green"
    _menu_pair "6" "定时刷新" "北京时间" "green" "7" "查看定时任务" "配置/日志" "cyan"
    _menu_pair "8" "删除定时任务" "" "yellow"
    _separator
    _menu_item "0" "返回上级菜单" "" "red"
    _separator
}

_warp_manage() {
    while true; do
        _ui_print_screen _warp_manage_screen
        local ch
        read -rp "  ${CYAN}➜${PLAIN}  选择 [0-8]: " ch
        case "$ch" in
            1) _warp_install_cli ;;
            2) _warp_run_upstream_script "warp-sh" ;;
            3) _warp_run_upstream_script "warp-go" ;;
            4) _warp_refresh_now ;;
            5) _warp_refresh_netflix_now ;;
            6) _warp_configure_refresh_cron ;;
            7) _warp_show_refresh_cron ;;
            8) _warp_remove_refresh_cron ;;
            0) return ;;
            * ) _error_no_exit "无效选项: ${ch}"; sleep 1 ;;
        esac
    done
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
_TCPTUNE_LAST_BACKUP_DIR=""
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
    _menu_item "4" "64 MiB" "经验档位: 高 RTT / 跨区" "green"
    _menu_item "5" "128 MiB" "经验档位: 高带宽或高并发" "green"
    _separator
    read -rp "  选择 [1-5]（默认 4）: " choice
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

_tcptune_backup_safe_name() {
    printf '%s' "$1" | sed 's#^/##; s#[/ ]#_#g; s#[^A-Za-z0-9._-]#_#g'
}

_tcptune_backup_meta_get() {
    local backup_dir="$1" key="$2" default="${3:-}" meta_file value
    meta_file="${backup_dir}/meta.env"
    [[ -r "$meta_file" ]] || {
        printf '%s' "$default"
        return 0
    }
    value=$(awk -F= -v k="$key" '$1 == k { print substr($0, index($0, "=") + 1) }' "$meta_file" 2>/dev/null | tail -n1)
    if [[ -z "${value:-}" ]]; then
        value="$default"
    fi
    printf '%s' "$value"
}

_tcptune_backup_manifest_has_path() {
    local backup_dir="$1" path="$2" manifest
    manifest="${backup_dir}/file_manifest.tsv"
    [[ -r "$manifest" ]] || return 1
    awk -F'\t' -v p="$path" '$1 == p { found=1 } END { exit(found ? 0 : 1) }' "$manifest"
}

_tcptune_backup_register_file() {
    local backup_dir="$1" path="$2" manifest files_dir rel_name
    [[ -n "$backup_dir" && -n "$path" ]] || return 0
    manifest="${backup_dir}/file_manifest.tsv"
    files_dir="${backup_dir}/files"

    if _tcptune_backup_manifest_has_path "$backup_dir" "$path"; then
        return 0
    fi

    mkdir -p "$files_dir" || return 1
    rel_name=$(_tcptune_backup_safe_name "$path")
    if [ -f "$path" ]; then
        cp -p "$path" "${files_dir}/${rel_name}" 2>/dev/null || cp "$path" "${files_dir}/${rel_name}" || return 1
        printf '%s\tpresent\tfiles/%s\n' "$path" "$rel_name" >> "$manifest"
    else
        printf '%s\tabsent\t-\n' "$path" >> "$manifest"
    fi
}

_tcptune_detect_cake_bandwidth() {
    local iface="$1" qdisc_output bw value unit
    [ -n "$iface" ] || return 1
    command -v tc >/dev/null 2>&1 || return 1

    qdisc_output=$(tc qdisc show dev "$iface" 2>/dev/null || true)
    bw=$(printf '%s\n' "$qdisc_output" | sed -nE 's/.*\bcake\b.*\bbandwidth[[:space:]]+([0-9]+)([KMG])bit.*/\1 \2/p' | head -n1)
    [ -n "$bw" ] || return 1

    value="${bw%% *}"
    unit="${bw##* }"
    case "$unit" in
        G) printf '%s' $((value * 1000)) ;;
        M) printf '%s' "$value" ;;
        K) printf '%s' $((value / 1000)) ;;
        *) return 1 ;;
    esac
}

_tcptune_backup_runtime() {
    local iface="$1" backup_dir backup_file meta_file qdisc_mode cake_bw
    mkdir -p "$_TCPTUNE_BACKUP_DIR"
    backup_dir="${_TCPTUNE_BACKUP_DIR}/backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir" || return 1
    backup_file="${backup_dir}/sysctl_snapshot.conf"
    meta_file="${backup_dir}/meta.env"
    qdisc_mode=$(_tcptune_detect_qdisc_mode "$iface")
    cake_bw=$(_tcptune_detect_cake_bandwidth "$iface" 2>/dev/null || true)
    if ! _is_digit "${cake_bw:-}" || [ "$cake_bw" -le 0 ]; then
        cake_bw=0
    fi
    {
        printf "# TCP Tuning Backup - %s\n" "$(date)"
        printf "# Kernel: %s\n" "$(uname -r)"
        printf "# Interface: %s\n" "${iface:-N/A}"
        printf "# Source: sysctl -a filtered snapshot\n\n"
        sysctl -a 2>/dev/null | grep -E "^net\.(core\.(rmem|wmem|somaxconn|netdev_max_backlog|netdev_budget|default_qdisc|busy_(poll|read)|optmem_max)|ipv4\.tcp_(rmem|wmem|congestion|frto|slow_start|notsent|window_scaling|timestamps|sack|moderate|mtu_probing|limit_output_bytes|fastopen|fin_timeout|keepalive|max_tw|tw_reuse|max_syn|syncookies|max_orphans|adv_win)|ipv4\.ip_local_port_range)" | sort
        printf "fs.file-max = %s\n" "$(_tcptune_sysctl_get fs.file-max)"
    } > "$backup_file"
    {
        printf 'CREATED_AT=%s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
        printf 'KERNEL=%s\n' "$(uname -r)"
        printf 'INTERFACE=%s\n' "${iface:-}"
        printf 'QDISC_MODE=%s\n' "${qdisc_mode:-fq}"
        printf 'CAKE_BW_MBIT=%s\n' "${cake_bw:-0}"
        printf 'SYSCTL_SNAPSHOT=%s\n' "$backup_file"
    } > "$meta_file"
    _tcptune_backup_register_file "$backup_dir" "$_TCPTUNE_SYSCTL_FILE" || true
    _tcptune_backup_register_file "$backup_dir" "$_TCPTUNE_CAKE_SERVICE_FILE" || true
    _tcptune_backup_register_file "$backup_dir" "$_TCPTUNE_CAKE_OPENRC_SERVICE_FILE" || true
    _tcptune_backup_register_file "$backup_dir" "$_TCPTUNE_CAKE_APPLY_SCRIPT" || true
    _TCPTUNE_LAST_BACKUP_DIR="$backup_dir"
    _TCPTUNE_LAST_BACKUP_FILE="$backup_file"
    _success "已备份当前配置: ${backup_dir}"
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
                    [ -n "$_TCPTUNE_LAST_BACKUP_DIR" ] && _tcptune_backup_register_file "$_TCPTUNE_LAST_BACKUP_DIR" "$file" || true
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
    _menu_item "1" "自动清理冲突项" "注释旧配置并保留备份" "green"
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
        printf "    运行前备份目录: %s\n" "${_TCPTUNE_LAST_BACKUP_DIR:-$(dirname "$_TCPTUNE_LAST_BACKUP_FILE")}"
        printf "    运行前快照: %s\n" "$_TCPTUNE_LAST_BACKUP_FILE"
        printf "    恢复方式: TCP 调优菜单 -> 从备份恢复\n"
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

_tcptune_list_backup_dirs() {
    local d
    [ -d "$_TCPTUNE_BACKUP_DIR" ] || return 0
    for d in "$_TCPTUNE_BACKUP_DIR"/backup_*; do
        [ -d "$d" ] && printf '%s\n' "$d"
    done | sort -r
}

_tcptune_show_backups() {
    local backups=() backup_dir idx created iface qdisc cake_bw
    while IFS= read -r backup_dir; do
        [ -n "$backup_dir" ] && backups+=("$backup_dir")
    done < <(_tcptune_list_backup_dirs)

    echo ""
    printf "  ${BOLD}TCP 调优备份列表${PLAIN}\n"
    _separator
    if [ "${#backups[@]}" -eq 0 ]; then
        _info "当前没有可用备份。"
        return 1
    fi

    for idx in "${!backups[@]}"; do
        backup_dir="${backups[$idx]}"
        created=$(_tcptune_backup_meta_get "$backup_dir" "CREATED_AT" "$(basename "$backup_dir")")
        iface=$(_tcptune_backup_meta_get "$backup_dir" "INTERFACE" "-")
        qdisc=$(_tcptune_backup_meta_get "$backup_dir" "QDISC_MODE" "-")
        cake_bw=$(_tcptune_backup_meta_get "$backup_dir" "CAKE_BW_MBIT" "0")
        printf "  [%d] %s\n" "$((idx + 1))" "$created"
        printf "      iface=%s qdisc=%s" "$iface" "$qdisc"
        if _is_digit "${cake_bw:-}" && [ "$cake_bw" -gt 0 ]; then
            printf " cake=%sMbps" "$cake_bw"
        fi
        printf "\n"
        printf "      %s\n" "$backup_dir"
    done
    return 0
}

_tcptune_select_backup() {
    local backups=() backup_dir choice
    while IFS= read -r backup_dir; do
        [ -n "$backup_dir" ] && backups+=("$backup_dir")
    done < <(_tcptune_list_backup_dirs)

    [ "${#backups[@]}" -gt 0 ] || return 1
    _tcptune_show_backups || return 1
    echo ""
    read -rp "  选择备份编号 [1-${#backups[@]}，0 返回]: " choice
    if [ "${choice:-0}" = "0" ]; then
        return 1
    fi
    if ! _is_digit "${choice:-}" || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#backups[@]}" ]; then
        _warn "无效编号。"
        return 1
    fi
    printf '%s' "${backups[$((choice - 1))]}"
}

_tcptune_restore_files_from_manifest() {
    local backup_dir="$1" manifest path state rel src
    manifest="${backup_dir}/file_manifest.tsv"
    [ -r "$manifest" ] || return 0

    while IFS=$'\t' read -r path state rel; do
        [ -n "$path" ] || continue
        case "$state" in
            present)
                src="${backup_dir}/${rel}"
                mkdir -p "$(dirname "$path")" || return 1
                cp -p "$src" "$path" 2>/dev/null || cp "$src" "$path" || return 1
                ;;
            absent)
                rm -f "$path"
                ;;
        esac
    done < "$manifest"

    if _has_systemd; then
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
}

_tcptune_restore_backup() {
    local backup_dir="$1"
    local snapshot iface qdisc_mode cake_bw created confirm

    snapshot="${backup_dir}/sysctl_snapshot.conf"
    if [ ! -d "$backup_dir" ] || [ ! -f "$snapshot" ]; then
        _error_no_exit "备份目录无效: ${backup_dir}"
        return 1
    fi

    created=$(_tcptune_backup_meta_get "$backup_dir" "CREATED_AT" "$(basename "$backup_dir")")
    iface=$(_tcptune_backup_meta_get "$backup_dir" "INTERFACE" "$(_tcptune_guess_iface)")
    qdisc_mode=$(_tcptune_backup_meta_get "$backup_dir" "QDISC_MODE" "fq")
    cake_bw=$(_tcptune_backup_meta_get "$backup_dir" "CAKE_BW_MBIT" "0")

    echo ""
    printf "  ${BOLD}准备恢复 TCP 调优备份${PLAIN}\n"
    _separator
    _status_kv "备份时间" "$created" "green" 18
    _status_kv "接口" "${iface:-N/A}" "green" 18
    _status_kv "qdisc" "$qdisc_mode" "green" 18
    if _is_digit "${cake_bw:-}" && [ "$cake_bw" -gt 0 ]; then
        _status_kv "cake" "${cake_bw} Mbps" "green" 18
    fi
    echo ""
    _warn "将恢复 TCP 调优修改过的配置文件、sysctl 参数，以及 qdisc 持久化状态。"
    read -rp "  确认恢复该备份? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        _info "已取消。"
        return 1
    fi

    _tcptune_restore_files_from_manifest "$backup_dir" || {
        _error_no_exit "恢复备份文件失败。"
        return 1
    }

    if ! sysctl -p "$snapshot" >/dev/null 2>&1; then
        _warn "sysctl 快照恢复返回非 0，可能是容器/权限限制。"
    else
        _success "sysctl 参数已恢复。"
    fi

    if [ -n "$iface" ]; then
        case "$qdisc_mode" in
            cake)
                if _is_digit "${cake_bw:-}" && [ "$cake_bw" -gt 0 ]; then
                    _tcptune_verify_cake_qdisc "$iface" "$cake_bw" || true
                    _tcptune_enable_cake_persist "$iface" "$cake_bw" || true
                    _TCPTUNE_LAST_CAKE_BW_MBIT="$cake_bw"
                else
                    _warn "备份中未记录有效 CAKE 带宽，已恢复 sysctl/文件，但未主动重放 CAKE qdisc。"
                fi
                ;;
            *)
                _tcptune_verify_fq_qdisc "$iface" || true
                _tcptune_disable_cake_persist
                _TCPTUNE_LAST_CAKE_BW_MBIT=0
                ;;
        esac
    fi

    _TCPTUNE_LAST_BACKUP_DIR="$backup_dir"
    _TCPTUNE_LAST_BACKUP_FILE="$snapshot"
    _TCPTUNE_LAST_IFACE="$iface"
    _TCPTUNE_LAST_QDISC_MODE="$qdisc_mode"

    echo ""
    _success "TCP 调优已恢复到备份状态。"
    _tcptune_show_current
    return 0
}

_tcptune_restore_from_menu() {
    local backup_dir
    backup_dir=$(_tcptune_select_backup) || return 0
    _tcptune_restore_backup "$backup_dir"
    _press_any_key
}

_tcptune_run_v2() {
    local iface link_speed mem_mb kernel confirm qdisc_mode kv min_kv
    local managed_keys=() key

    _header "TCP 调优 (Azure/Proxy 基线)"
    _tcptune_show_current
    echo ""
    _warn "将写入 TCP 调优配置并立即应用。"
    read -rp "  继续? [Y/n]: " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        _info "已取消。"
        _press_any_key
        return
    fi

    echo ""
    _info "步骤 1/8: 采集系统信息"
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
    _info "步骤 2/8: 计算 TCP 缓冲区"
    _tcptune_choose_ceiling "$link_speed"

    echo ""
    if [ "$_TCPTUNE_LAST_QDISC_MODE" = "cake" ]; then
        _info "步骤 3/8: 设置 CAKE 带宽"
        _tcptune_choose_cake_bandwidth "$link_speed"
    else
        _info "步骤 3/8: FQ 无需设置带宽"
        _TCPTUNE_LAST_CAKE_BW_MBIT=0
    fi

    echo ""
    _info "步骤 4/8: 检查 BBR"
    if ! _tcptune_ensure_bbr_available; then
        _error_no_exit "当前内核未检测到 BBR。请先执行“开启 BBR”模块。"
        _press_any_key
        return
    fi

    echo ""
    _info "步骤 5/8: 备份配置"
    _tcptune_backup_runtime "$iface"

    echo ""
    _info "步骤 6/8: 写入配置"
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
    _info "步骤 7/8: 应用 Qdisc"
    if [ "$_TCPTUNE_LAST_QDISC_MODE" = "cake" ]; then
        _tcptune_verify_cake_qdisc "$iface" "$_TCPTUNE_LAST_CAKE_BW_MBIT" || true
        _tcptune_enable_cake_persist "$iface" "$_TCPTUNE_LAST_CAKE_BW_MBIT" || true
    else
        _tcptune_verify_fq_qdisc "$iface"
        _tcptune_disable_cake_persist
    fi

    echo ""
    _info "步骤 8/8: 验证结果"
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
        _menu_pair "1" "应用 TCP 调优" "写入并验证参数" "green" "2" "查看验证命令" "iperf3/ss/tc/nstat" "cyan"
        _menu_pair "3" "查看备份列表" "恢复前可先确认内容" "cyan" "4" "从备份恢复" "回滚被修改项" "yellow"
        _menu_item "0" "返回主菜单" "" "red"
        _separator

        local choice
        read -rp "  选择 [0-4]: " choice
        case "$choice" in
            1) _tcptune_run_v2 ;;
            2) _tcptune_print_verify_hint "$(_tcptune_guess_iface)" "$_TCPTUNE_LAST_CEILING_BYTES" "$_TCPTUNE_LAST_QDISC_MODE" "$_TCPTUNE_LAST_CAKE_BW_MBIT"; _press_any_key ;;
            3) _tcptune_show_backups; _press_any_key ;;
            4) _tcptune_restore_from_menu ;;
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

    printf "  ${BOLD}选择操作${PLAIN}\n"
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
    _download_file "$1" "$2"
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
    local version latest_url api_url latest_release_url fetch_api fetch_latest

    if [[ "$_MIHOMO_TRACK" == "dev" ]]; then
        api_url="https://api.github.com/repos/MetaCubeX/mihomo/releases/tags/Prerelease-Alpha"
        fetch_api=$(_github_proxy_url "$api_url")
        local json_content
        if command -v curl >/dev/null 2>&1; then
            json_content=$(curl -fsSL "$fetch_api" 2>/dev/null)
        elif command -v wget >/dev/null 2>&1; then
            json_content=$(wget -qO- "$fetch_api" 2>/dev/null)
        fi
        [[ -n "$json_content" ]] || return 1
        local arch
        arch=$(_mihomo_detect_arch)
        [[ -n "$arch" ]] || return 1
        local url
        url=$(printf '%s\n' "$json_content" | grep -o '"browser_download_url":"[^"]*' | grep -o 'https://[^"]*' | grep "mihomo-linux-${arch}-alpha-" | head -n 1)
        [[ -n "$url" ]] || return 1
        version=$(printf '%s\n' "$url" | sed -nE 's/.*mihomo-linux-[^/]*-alpha-([0-9a-zA-Z]+)\.gz/\1/p')
        [[ -n "$version" ]] || return 1
        printf 'alpha-%s' "$version"
        return 0
    fi

    api_url="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
    latest_release_url="https://github.com/MetaCubeX/mihomo/releases/latest"
    fetch_api=$(_github_proxy_url "$api_url")
    fetch_latest=$(_github_proxy_url "$latest_release_url")

    if command -v curl >/dev/null 2>&1; then
        version=$(curl -fsSL "$fetch_api" 2>/dev/null \
            | awk -F'"' '$2=="tag_name"{print $4; exit}')
    elif command -v wget >/dev/null 2>&1; then
        version=$(wget -qO- "$fetch_api" 2>/dev/null \
            | awk -F'"' '$2=="tag_name"{print $4; exit}')
    fi
    if [[ -n "${version:-}" ]] && [[ "$version" =~ ^v?[0-9]+([.][0-9]+){1,3}([._-][0-9A-Za-z]+)*$ ]]; then
        printf '%s' "$version"
        return 0
    fi

    if command -v curl >/dev/null 2>&1; then
        latest_url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "$fetch_latest" 2>/dev/null || true)
    elif command -v wget >/dev/null 2>&1; then
        latest_url=$(wget -S --spider "$fetch_latest" 2>&1 | awk '/^  Location: /{u=$2} END{print u}' | tr -d '\r')
    fi
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
    local url
    if [[ "$_MIHOMO_TRACK" == "dev" ]]; then
        local fetch_api json_content api_url
        api_url="https://api.github.com/repos/MetaCubeX/mihomo/releases/tags/Prerelease-Alpha"
        fetch_api=$(_github_proxy_url "$api_url")
        if command -v curl >/dev/null 2>&1; then
            json_content=$(curl -fsSL "$fetch_api" 2>/dev/null)
        elif command -v wget >/dev/null 2>&1; then
            json_content=$(wget -qO- "$fetch_api" 2>/dev/null)
        fi
        [[ -n "$json_content" ]] || return 1
        url=$(printf '%s\n' "$json_content" | grep -o '"browser_download_url":"[^"]*' | grep -o 'https://[^"]*' | grep "mihomo-linux-${arch}-alpha-" | head -n 1)
        [[ -n "$url" ]] || return 1
    else
        url="https://github.com/MetaCubeX/mihomo/releases/download/${version}/mihomo-linux-${arch}-${version}.gz"
    fi
    local tmp_file
    tmp_file=$(_mktemp_file mihomo .gz) || return 1

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

_mihomo_write_auto_update_script() {
    cat > "$_MIHOMO_AUTO_UPDATE_SCRIPT" <<EOF
#!/usr/bin/env bash
set -uo pipefail

export TZ=Asia/Shanghai
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

PROXY_ENABLED="${_GITHUB_PROXY_ENABLED}"
PROXY_BASE="${_GITHUB_PROXY_BASE}"
TRACK="${_MIHOMO_TRACK}"
LOG_FILE="${_MIHOMO_AUTO_UPDATE_LOG}"
EOF
    cat >> "$_MIHOMO_AUTO_UPDATE_SCRIPT" <<'EOF'
LOCK_FILE="/run/vpsgo-mihomo-auto-update.lock"
DEFAULT_INSTALL_BIN="/usr/local/bin/mihomo"
INSTALL_BIN=""
INSTALL_DIR=""
RELEASE_API="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
LATEST_URL="https://github.com/MetaCubeX/mihomo/releases/latest"

log() {
    printf '[%s] %s\n' "$(date '+%F %T %Z')" "$*"
}

supports_proxy_url() {
    local url="$1" rest host
    rest="${url#*://}"
    host="${rest%%/*}"
    host="${host%%\?*}"
    host=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')
    case "$host" in
        github.com|www.github.com|api.github.com|raw.githubusercontent.com|gist.github.com|gist.githubusercontent.com|codeload.github.com|objects.githubusercontent.com|*.githubusercontent.com|*.githubassets.com)
            return 0
            ;;
    esac
    return 1
}

proxy_url() {
    local url="${1:-}" base
    if [ "${PROXY_ENABLED}" != "1" ] && [ "${PROXY_ENABLED}" != "true" ] && [ "${PROXY_ENABLED}" != "yes" ] && [ "${PROXY_ENABLED}" != "on" ]; then
        printf '%s' "$url"
        return
    fi
    base="${PROXY_BASE%/}"
    if [ -z "$base" ] || ! supports_proxy_url "$url" || [ "${url#${base}/}" != "$url" ]; then
        printf '%s' "$url"
        return
    fi
    printf '%s/%s' "$base" "$url"
}

download_file() {
    local url="$1" output="$2" fetch_url
    fetch_url=$(proxy_url "$url")
    rm -f "$output"
    if command -v curl >/dev/null 2>&1; then
        if curl -fsSL --retry 2 --connect-timeout 10 --max-time 180 -o "$output" "$fetch_url"; then
            [ -s "$output" ] && return 0
        fi
        rm -f "$output"
    fi
    if command -v wget >/dev/null 2>&1; then
        if wget -q -T 30 -O "$output" "$fetch_url"; then
            [ -s "$output" ] && return 0
        fi
        rm -f "$output"
    fi
    return 1
}

resolve_install_path() {
    if [ -x "$DEFAULT_INSTALL_BIN" ]; then
        INSTALL_BIN="$DEFAULT_INSTALL_BIN"
    else
        INSTALL_BIN=$(command -v mihomo 2>/dev/null || true)
    fi
    [ -n "$INSTALL_BIN" ] || INSTALL_BIN="$DEFAULT_INSTALL_BIN"
    INSTALL_DIR=$(dirname "$INSTALL_BIN")
}

latest_version() {
    local version latest_url fetch_latest fetch_api
    if [ "${TRACK}" = "dev" ]; then
        fetch_api=$(proxy_url "https://api.github.com/repos/MetaCubeX/mihomo/releases/tags/Prerelease-Alpha")
        local json_content
        if command -v curl >/dev/null 2>&1; then
            json_content=$(curl -fsSL "$fetch_api" 2>/dev/null)
        elif command -v wget >/dev/null 2>&1; then
            json_content=$(wget -qO- "$fetch_api" 2>/dev/null)
        fi
        [ -n "$json_content" ] || return 1
        local arch
        arch=$(detect_arch)
        [ -n "$arch" ] || return 1
        local url
        url=$(printf '%s\n' "$json_content" | grep -o '"browser_download_url":"[^"]*' | grep -o 'https://[^"]*' | grep "mihomo-linux-${arch}-alpha-" | head -n 1)
        [ -n "$url" ] || return 1
        version=$(printf '%s\n' "$url" | sed -nE 's/.*mihomo-linux-[^/]*-alpha-([0-9a-zA-Z]+)\.gz/\1/p')
        [ -n "$version" ] || return 1
        printf 'alpha-%s' "$version"
        return 0
    else
        fetch_api=$(proxy_url "$RELEASE_API")
        if command -v curl >/dev/null 2>&1; then
            version=$(curl -fsSL "$fetch_api" 2>/dev/null | awk -F'"' '$2=="tag_name"{print $4; exit}')
        elif command -v wget >/dev/null 2>&1; then
            version=$(wget -qO- "$fetch_api" 2>/dev/null | awk -F'"' '$2=="tag_name"{print $4; exit}')
        fi
        if [ -n "${version:-}" ] && printf '%s' "$version" | grep -Eq '^v?[0-9]+([.][0-9]+){1,3}([._-][0-9A-Za-z]+)*$'; then
            printf '%s' "$version"
            return 0
        fi

        fetch_latest=$(proxy_url "$LATEST_URL")
        if command -v curl >/dev/null 2>&1; then
            latest_url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "$fetch_latest" 2>/dev/null || true)
        elif command -v wget >/dev/null 2>&1; then
            latest_url=$(wget -S --spider "$fetch_latest" 2>&1 | awk '/^  Location: /{u=$2} END{print u}' | tr -d '\r')
        fi
        if [ -n "${latest_url:-}" ] && [ "${latest_url#*/releases/tag/}" != "$latest_url" ]; then
            version="${latest_url##*/}"
            if [ -n "${version:-}" ] && printf '%s' "$version" | grep -Eq '^v?[0-9]+([.][0-9]+){1,3}([._-][0-9A-Za-z]+)*$'; then
                printf '%s' "$version"
                return 0
            fi
        fi
        return 1
    fi
}

current_version() {
    local bin output version
    [ -n "$INSTALL_BIN" ] || resolve_install_path
    bin="$INSTALL_BIN"
    [ -x "$bin" ] || bin=$(command -v mihomo 2>/dev/null || true)
    [ -n "$bin" ] && [ -x "$bin" ] || return 1
    output=$("$bin" -v 2>/dev/null | head -1 || true)
    version=$(printf '%s\n' "$output" | grep -Eom1 'v?[0-9]+([.][0-9]+){1,3}([._-][0-9A-Za-z]+)*|alpha-[0-9a-zA-Z]+' || true)
    [ -n "$version" ] || return 1
    printf '%s' "$version"
}

normalize_version() {
    printf '%s' "$1" | sed -E 's/^v//'
}

detect_amd64_level() {
    local flags
    flags=$(grep -m1 '^flags' /proc/cpuinfo 2>/dev/null | cut -d: -f2 || true)
    if echo "$flags" | grep -qw 'avx2'; then
        echo "amd64-v3"
    elif echo "$flags" | grep -qw 'sse4_2' && echo "$flags" | grep -qw 'popcnt'; then
        echo "amd64-v2"
    else
        echo "amd64-compatible"
    fi
}

detect_mips_float() {
    if grep -q 'FPU' /proc/cpuinfo 2>/dev/null; then
        echo "hardfloat"
    else
        echo "softfloat"
    fi
}

detect_arch() {
    local machine
    machine=$(uname -m)
    case "$machine" in
        x86_64|amd64)       detect_amd64_level ;;
        i386|i486|i586|i686) echo "386" ;;
        aarch64|arm64)      echo "arm64" ;;
        armv7*|armhf)       echo "armv7" ;;
        armv6*)             echo "armv6" ;;
        armv5*)             echo "armv5" ;;
        mips64)             echo "mips64" ;;
        mips64el|mips64le)  echo "mips64le" ;;
        mips)               echo "mips-$(detect_mips_float)" ;;
        mipsel|mipsle)      echo "mipsle-$(detect_mips_float)" ;;
        riscv64)            echo "riscv64" ;;
        s390x)              echo "s390x" ;;
        ppc64le)            echo "ppc64le" ;;
        loongarch64)        echo "loong64-abi2" ;;
        *)                  echo "" ;;
    esac
}

try_install_arch() {
    local arch="$1" version="$2" url tmp_gz tmp_bin
    if [ "${TRACK}" = "dev" ]; then
        local fetch_api json_content
        fetch_api=$(proxy_url "https://api.github.com/repos/MetaCubeX/mihomo/releases/tags/Prerelease-Alpha")
        if command -v curl >/dev/null 2>&1; then
            json_content=$(curl -fsSL "$fetch_api" 2>/dev/null)
        elif command -v wget >/dev/null 2>&1; then
            json_content=$(wget -qO- "$fetch_api" 2>/dev/null)
        fi
        [ -n "$json_content" ] || return 1
        url=$(printf '%s\n' "$json_content" | grep -o '"browser_download_url":"[^"]*' | grep -o 'https://[^"]*' | grep "mihomo-linux-${arch}-alpha-" | head -n 1)
        [ -n "$url" ] || return 1
    else
        url="https://github.com/MetaCubeX/mihomo/releases/download/${version}/mihomo-linux-${arch}-${version}.gz"
    fi
    tmp_gz=$(mktemp "/tmp/vpsgo-mihomo-${arch}.XXXXXX.gz") || return 1
    tmp_bin=$(mktemp "/tmp/vpsgo-mihomo-${arch}.XXXXXX") || {
        rm -f "$tmp_gz"
        return 1
    }

    log "Downloading $(basename "$url")"
    if ! download_file "$url" "$tmp_gz"; then
        rm -f "$tmp_gz" "$tmp_bin"
        return 1
    fi
    if ! gunzip -c "$tmp_gz" > "$tmp_bin"; then
        rm -f "$tmp_gz" "$tmp_bin"
        return 1
    fi
    chmod 0755 "$tmp_bin"
    if ! "$tmp_bin" -v >/dev/null 2>&1; then
        rm -f "$tmp_gz" "$tmp_bin"
        return 1
    fi

    mkdir -p "$INSTALL_DIR"
    mv -f "$tmp_bin" "$INSTALL_BIN"
    chmod 0755 "$INSTALL_BIN"
    rm -f "$tmp_gz"
    log "Installed ${INSTALL_BIN} (${arch}, ${version})"
    return 0
}

install_latest() {
    local arch="$1" version="$2"
    if try_install_arch "$arch" "$version"; then
        return 0
    fi
    if [ "$arch" = "amd64-v3" ]; then
        log "amd64-v3 failed, fallback to amd64-v2"
        if try_install_arch "amd64-v2" "$version"; then
            return 0
        fi
        log "amd64-v2 failed, fallback to amd64-compatible"
        try_install_arch "amd64-compatible" "$version"
        return $?
    fi
    return 1
}

mihomo_pid() {
    local pid ps_output
    pid=$(pgrep -x mihomo 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//' || true)
    [ -n "${pid:-}" ] && { printf '%s' "$pid"; return 0; }
    pid=$(pidof mihomo 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//' || true)
    [ -n "${pid:-}" ] && { printf '%s' "$pid"; return 0; }
    ps_output=$(ps -w 2>/dev/null || ps 2>/dev/null || true)
    pid=$(printf '%s\n' "$ps_output" | awk '
        NR == 1 { next }
        {
            line=$0
            pid=$1
            if (pid !~ /^[0-9]+$/) next
            if (line ~ /(^|[\/[:space:]])mihomo([[:space:]]|$)/ && line !~ /awk|grep|vpsgo/) print pid
        }
    ' | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    [ -n "${pid:-}" ] && { printf '%s' "$pid"; return 0; }
    return 1
}

mihomo_running() {
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet mihomo 2>/dev/null; then
        return 0
    fi
    if command -v rc-service >/dev/null 2>&1 && [ -x /etc/init.d/mihomo ] && rc-service mihomo status >/dev/null 2>&1; then
        return 0
    fi
    mihomo_pid >/dev/null 2>&1
}

restart_mihomo() {
    if command -v systemctl >/dev/null 2>&1; then
        local state
        state=$(systemctl show -p LoadState --value mihomo.service 2>/dev/null || true)
        if [ -n "$state" ] && [ "$state" != "not-found" ]; then
            systemctl restart mihomo >/dev/null 2>&1
            return $?
        fi
    fi
    if command -v rc-service >/dev/null 2>&1 && [ -x /etc/init.d/mihomo ]; then
        rc-service mihomo restart >/dev/null 2>&1 || rc-service mihomo start >/dev/null 2>&1
        return $?
    fi
    local mihomo_pids one_pid
    mihomo_pids=$(mihomo_pid 2>/dev/null || true)
    if [[ -n "$mihomo_pids" ]]; then
        for one_pid in $mihomo_pids; do
            kill "$one_pid" 2>/dev/null || true
        done
        sleep 1
    fi
    if [ -d /etc/mihomo ]; then
        nohup "$INSTALL_BIN" -d /etc/mihomo >/dev/null 2>&1 &
        sleep 1
        mihomo_pid >/dev/null 2>&1
        return $?
    fi
    return 0
}

main() {
    local latest current arch was_running=0
    mkdir -p "$(dirname "$LOG_FILE")" /run
    touch "$LOG_FILE"
    exec >> "$LOG_FILE" 2>&1
    exec 9>"$LOCK_FILE"
    if command -v flock >/dev/null 2>&1; then
        flock -n 9 || {
            log "Previous Mihomo auto update is still running, skip."
            exit 0
        }
    fi

    resolve_install_path
    if ! command -v mihomo >/dev/null 2>&1 && [ ! -x "$INSTALL_BIN" ]; then
        log "Mihomo is not installed, skip."
        exit 0
    fi
    if ! command -v gunzip >/dev/null 2>&1; then
        log "Missing gunzip, cannot update."
        exit 1
    fi
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        log "Missing curl/wget, cannot update."
        exit 1
    fi

    log "Start VPSGo Mihomo auto update."
    latest=$(latest_version) || {
        log "Failed to fetch latest version."
        exit 1
    }
    current=$(current_version 2>/dev/null || true)
    if [ -n "$current" ] && [ "$(normalize_version "$current")" = "$(normalize_version "$latest")" ]; then
        log "Already latest: ${current}"
        exit 0
    fi

    arch=$(detect_arch)
    if [ -z "$arch" ]; then
        log "Unsupported arch: $(uname -m)"
        exit 1
    fi
    mihomo_running && was_running=1
    log "Update needed: current=${current:-unknown}, latest=${latest}, arch=${arch}"
    if ! install_latest "$arch" "$latest"; then
        log "Install failed."
        exit 1
    fi

    if [ "$was_running" = "1" ]; then
        if restart_mihomo; then
            log "Mihomo restarted."
        else
            log "Mihomo updated, but restart failed."
            exit 1
        fi
    else
        log "Mihomo was not running, skip restart."
    fi
    log "Finish VPSGo Mihomo auto update."
}

main "$@"
EOF
    chmod 0755 "$_MIHOMO_AUTO_UPDATE_SCRIPT"
}

_mihomo_configure_auto_update_cron() {
    _header "Mihomo 定时自动更新"

    if ! command -v mihomo >/dev/null 2>&1; then
        _warn "当前未检测到 mihomo，请先安装后再配置自动更新。"
        _press_any_key
        return
    fi

    local time_hhmm hour minute
    echo ""
    _info "输入北京时间，格式 HH:MM，例如 04:20。"
    _info "任务每天执行一次，只在发现新版本时更新。"
    read -rp "  每天检查时间 [HH:MM]: " time_hhmm
    if ! _valid_hhmm "$time_hhmm"; then
        _error_no_exit "时间格式无效，请使用 HH:MM，例如 04:20。"
        _press_any_key
        return
    fi

    hour="${time_hhmm%%:*}"
    minute="${time_hhmm##*:}"
    hour=$((10#$hour))
    minute=$((10#$minute))

    _mihomo_write_auto_update_script
    _cron_job_write "vpsgo-mihomo-auto-update" "$minute" "$hour" "$_MIHOMO_AUTO_UPDATE_SCRIPT"
    _restart_first_available_service cron crond >/dev/null 2>&1 || true

    echo ""
    _success "Mihomo 定时自动更新已配置"
    _status_kv "时间" "每天北京时间 ${time_hhmm}" "green" 12
    _status_kv "策略" "发现新版本后自动更新" "green" 12
    _status_kv "日志" "$_MIHOMO_AUTO_UPDATE_LOG" "cyan" 12
    if _is_truthy "$_GITHUB_PROXY_ENABLED"; then
        _status_kv "GitHub 代理" "$_GITHUB_PROXY_BASE" "cyan" 12
    fi
    _press_any_key
}

_mihomo_show_auto_update_cron() {
    _header "Mihomo 定时自动更新状态"

    if _cron_job_exists "vpsgo-mihomo-auto-update"; then
        printf "  ${BOLD}Cron 配置${PLAIN}\n"
        _separator
        _cron_job_show "vpsgo-mihomo-auto-update" | sed 's/^/    /'
    else
        _warn "未检测到 Mihomo 定时自动更新配置。"
    fi

    if [ -f "$_MIHOMO_AUTO_UPDATE_SCRIPT" ]; then
        echo ""
        _status_kv "执行脚本" "$_MIHOMO_AUTO_UPDATE_SCRIPT" "cyan" 12
    fi
    if [ -f "$_MIHOMO_AUTO_UPDATE_LOG" ]; then
        echo ""
        printf "  ${BOLD}最近日志${PLAIN}\n"
        _separator
        tail -n 30 "$_MIHOMO_AUTO_UPDATE_LOG" | sed 's/^/    /'
    fi
    _press_any_key
}

_mihomo_remove_auto_update_cron() {
    _header "删除 Mihomo 定时自动更新"

    if ! _cron_job_exists "vpsgo-mihomo-auto-update" && [ ! -f "$_MIHOMO_AUTO_UPDATE_SCRIPT" ]; then
        _info "未检测到 Mihomo 定时自动更新配置。"
        _press_any_key
        return
    fi

    local confirm
    read -rp "  确认删除 Mihomo 定时自动更新? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy] ]]; then
        _info "已取消"
        _press_any_key
        return
    fi

    _cron_job_remove "vpsgo-mihomo-auto-update"
    rm -f "$_MIHOMO_AUTO_UPDATE_SCRIPT"
    _restart_first_available_service cron crond >/dev/null 2>&1 || true
    _success "已删除 Mihomo 定时自动更新配置。"
    _press_any_key
}

_mihomo_auto_update_manage() {
    while true; do
        _header "Mihomo 定时自动更新"
        if _cron_job_exists "vpsgo-mihomo-auto-update"; then
            _info "当前状态: 已配置"
        else
            _info "当前状态: 未配置"
        fi
        _separator
        _menu_pair "1" "配置/更新定时任务" "北京时间" "green" "2" "查看定时任务" "配置/日志" "cyan"
        _menu_pair "3" "删除定时任务" "" "yellow" "0" "返回上级菜单" "" "red"
        _separator

        local choice
        read -rp "  选择 [0-3]: " choice
        case "$choice" in
            1) _mihomo_configure_auto_update_cron ;;
            2) _mihomo_show_auto_update_cron ;;
            3) _mihomo_remove_auto_update_cron ;;
            0) return ;;
            *) _error_no_exit "无效选项"; sleep 1 ;;
        esac
    done
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
    read -rp "  安装或更新 mihomo? [Y/n]: " confirm_install
    if [[ "$confirm_install" =~ ^([Nn]|[Nn][Oo])$ ]]; then
        _info "已取消"
        _press_any_key
        return
    fi

    # 选择版本类型
    echo ""
    _info "选择安装的版本分支 (默认稳定版):"
    _menu_pair "1" "稳定版 (Stable)" "官方正式发布版，适合日常稳定运行" "green" \
               "2" "开发版 (Alpha)" "包含最新功能和修复，可能存在实验性代码" "yellow"

    local track_choice
    read -rp "  请选择 [1-2, 默认 1]: " track_choice
    if [[ "$track_choice" == "2" ]]; then
        _MIHOMO_TRACK="dev"
    else
        _MIHOMO_TRACK="stable"
    fi
    _save_runtime_config
    if _cron_job_exists "vpsgo-mihomo-auto-update"; then
        _mihomo_write_auto_update_script
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
_MIHOMORULE_IOS_TREE_API="https://api.github.com/repos/blackmatrix7/ios_rule_script/git/trees/master?recursive=1"
_MIHOMORULE_IOS_RAW_BASE="https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master"
_MIHOMO_WG_PROXY_SUPPORT_CACHE="unknown"
_MIHOMO_SYSTEMD_SERVICE_FILE="/etc/systemd/system/mihomo.service"
_MIHOMO_OPENRC_SERVICE_FILE="/etc/init.d/mihomo"
_MIHOMO_OPENRC_LOG_FILE="/var/log/mihomo.log"
_MIHOMO_OPENRC_ERR_FILE="/var/log/mihomo.error.log"

_mihomoconf_gen_ss_password_128() { head -c 16 /dev/urandom | base64 | tr -d '\n'; }
_mihomoconf_gen_ss_password_256() { head -c 32 /dev/urandom | base64 | tr -d '\n'; }
_mihomoconf_gen_anytls_password()  { head -c 32 /dev/urandom | base64 | tr -d '\n' | tr '/+' 'Aa' | tr -d '=' | head -c 32; }
_mihomoconf_gen_reality_short_id() { head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

_mihomoconf_gen_reality_keypair() {
    local output private_key public_key

    if ! command -v mihomo >/dev/null 2>&1; then
        return 1
    fi

    output=$(mihomo generate reality-keypair 2>/dev/null) || return 1
    private_key=$(printf '%s\n' "$output" | awk -F': *' '/^PrivateKey:/ {print $2; exit}')
    public_key=$(printf '%s\n' "$output" | awk -F': *' '/^PublicKey:/ {print $2; exit}')
    [[ -n "$private_key" && -n "$public_key" ]] || return 1
    printf '%s\t%s\n' "$private_key" "$public_key"
}

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
    local peer="${5:-}" insecure="${6:-0}" obfs="${7:-}" obfs_password="${8:-}" mport="${9:-}" congestion_control="${10:-brutal}"
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
    [[ -n "$congestion_control" ]] && params+=("congestion_control=$(_mihomoconf_urlencode "$congestion_control")")

    if (( ${#params[@]} > 0 )); then
        local IFS='&'
        query="?${params[*]}"
    fi
    echo "hysteria2://${password}@${server}:${port}${query}#${encoded_name}"
}

_mihomoconf_gen_tuic_link() {
    local server="$1" port="$2" uuid="$3" password="$4" name="$5"
    local sni="${6:-}" congestion_control="${7:-bbr}" alpn="${8:-h3}" udp_relay_mode="${9:-native}"
    local encoded_name query=""
    local -a params=()

    encoded_name=$(_mihomoconf_urlencode "${name}")
    [[ -n "$sni" ]] && params+=("sni=$(_mihomoconf_urlencode "$sni")")
    [[ -n "$congestion_control" ]] && params+=("congestion_control=$(_mihomoconf_urlencode "$congestion_control")")
    [[ -n "$alpn" ]] && params+=("alpn=$(_mihomoconf_urlencode "$alpn")")
    if [[ -n "$udp_relay_mode" ]]; then
        params+=("udp_relay_mode=$(_mihomoconf_urlencode "$udp_relay_mode")")
    fi

    if (( ${#params[@]} > 0 )); then
        local IFS='&'
        query="?${params[*]}"
    fi
    echo "tuic://${uuid}:${password}@${server}:${port}${query}#${encoded_name}"
}

_mihomoconf_gen_vless_link() {
    local server="$1" port="$2" uuid="$3" name="$4" servername="$5" public_key="$6" short_id="$7"
    local flow="${8:-xtls-rprx-vision}" client_fingerprint="${9:-chrome}"
    local encoded_name query=""
    local -a params=()

    encoded_name=$(_mihomoconf_urlencode "${name}")
    params+=("encryption=none")
    [[ -n "$flow" ]] && params+=("flow=$(_mihomoconf_urlencode "$flow")")
    params+=("security=reality")
    params+=("type=tcp")
    [[ -n "$servername" ]] && params+=("sni=$(_mihomoconf_urlencode "$servername")")
    [[ -n "$client_fingerprint" ]] && params+=("fp=$(_mihomoconf_urlencode "$client_fingerprint")")
    [[ -n "$public_key" ]] && params+=("pbk=$(_mihomoconf_urlencode "$public_key")")
    [[ -n "$short_id" ]] && params+=("sid=$(_mihomoconf_urlencode "$short_id")")

    if (( ${#params[@]} > 0 )); then
        local IFS='&'
        query="?${params[*]}"
    fi
    echo "vless://${uuid}@${server}:${port}${query}#${encoded_name}"
}

_mihomoconf_gen_vless_ws_link() {
    local server="$1" port="$2" uuid="$3" name="$4" path="$5" tls="$6" host="$7"
    local encoded_name query=""
    local -a params=()

    encoded_name=$(_mihomoconf_urlencode "${name}")
    params+=("encryption=none")
    params+=("type=ws")
    [[ -n "$path" ]] && params+=("path=$(_mihomoconf_urlencode "$path")")
    if [[ "$tls" == "true" ]]; then
        params+=("security=tls")
        [[ -n "$host" ]] && params+=("sni=$(_mihomoconf_urlencode "$host")")
    else
        params+=("security=none")
    fi
    [[ -n "$host" ]] && params+=("host=$(_mihomoconf_urlencode "$host")")

    if (( ${#params[@]} > 0 )); then
        local IFS='&'
        query="?${params[*]}"
    fi
    echo "vless://${uuid}@${server}:${port}${query}#${encoded_name}"
}


_mihomoconf_gen_socks_link() {
    local server="$1" port="$2" username="$3" password="$4" name="$5"
    local encoded_name encoded_user encoded_pass userinfo=""
    encoded_name=$(_mihomoconf_urlencode "${name}")
    if [[ -n "$username" && -n "$password" ]]; then
        encoded_user=$(_mihomoconf_urlencode "${username}")
        encoded_pass=$(_mihomoconf_urlencode "${password}")
        userinfo="${encoded_user}:${encoded_pass}@"
    fi
    echo "socks5://${userinfo}${server}:${port}#${encoded_name}"
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
    printf '%s%s' "$flag" "$country_code"
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
        function flush_item() {
            if (!in_item) return
            resolved_type = type_val
            if (type_val == "vless") {
                if (is_ws) {
                    resolved_type = "vless-ws"
                } else {
                    resolved_type = "vless"
                }
            }
            if (resolved_type == t) {
                found = 1
            }
            in_item = 0
            is_ws = 0
            type_val = ""
        }
        BEGIN {
            in_listeners=0
            in_item=0
            found=0
            is_ws=0
            type_val=""
        }
        /^[^[:space:]#][^:]*:[[:space:]]*.*$/ {
            if (in_listeners) {
                flush_item()
            }
            in_listeners = ($0 ~ /^listeners:[[:space:]]*$/)
            next
        }
        !in_listeners { next }
        /^[[:space:]]*-[[:space:]]*name:/ {
            flush_item()
            in_item=1
            next
        }
        in_item {
            if ($0 ~ /^[[:space:]]+#[[:space:]]*vpsgo-vless-type:[[:space:]]*ws/) {
                is_ws=1
            }
            if ($0 ~ /^    type:/) {
                line=$0
                sub(/^    type:[[:space:]]*/, "", line)
                type_val=unquote(trim(line))
            }
            next
        }
        END {
            if (in_listeners) {
                flush_item()
            }
            exit found ? 0 : 1
        }
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
        function flush_item() {
            if (!in_item) return
            resolved_type = type_val
            if (type_val == "vless") {
                if (is_ws) {
                    resolved_type = "vless-ws"
                } else {
                    resolved_type = "vless"
                }
            }
            if (resolved_type == t) {
                if (tag != "") {
                    print "      " name " (tag: " tag ", 端口: " port ")"
                } else {
                    print "      " name " (端口: " port ")"
                }
            }
            in_item = 0
            is_ws = 0
            type_val = ""
            name = ""
            tag = ""
            port = ""
        }
        BEGIN {
            in_listeners=0
            in_item=0
            is_ws=0
            type_val=""
            name=""
            tag=""
            port=""
        }
        /^[^[:space:]#][^:]*:[[:space:]]*.*$/ {
            if (in_listeners) {
                flush_item()
            }
            in_listeners = ($0 ~ /^listeners:[[:space:]]*$/)
            next
        }
        !in_listeners { next }
        /^[[:space:]]*-[[:space:]]*name:/ {
            flush_item()
            in_item=1
            line=$0
            sub(/^[[:space:]]*-[[:space:]]*name:[[:space:]]*/, "", line)
            name=unquote(trim(line))
            next
        }
        in_item {
            if ($0 ~ /^[[:space:]]+#[[:space:]]*vpsgo-vless-type:[[:space:]]*ws/) {
                is_ws=1
            }
            if ($0 ~ /^    type:/) {
                line=$0
                sub(/^    type:[[:space:]]*/, "", line)
                type_val=unquote(trim(line))
            }
            if ($0 ~ /^    tag:/) {
                line=$0
                sub(/^    tag:[[:space:]]*/, "", line)
                tag=unquote(trim(line))
            }
            if ($0 ~ /^    port:/) {
                line=$0
                sub(/^    port:[[:space:]]*/, "", line)
                port=trim(line)
            }
            next
        }
        END {
            if (in_listeners) {
                flush_item()
            }
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
            skip_item=0
            resolved_type=type_val
            if (type_val == "vless") {
                if (is_ws) {
                    resolved_type = "vless-ws"
                } else {
                    resolved_type = "vless"
                }
            }
            if (resolved_type == t) {
                skip_item=1
            }
            if (!skip_item) {
                printf "%s", item_buf
            }
            item_buf=""
            in_item=0
        }
        BEGIN {
            in_listeners=0
            in_item=0
            skip_item=0
            item_buf=""
            is_ws=0
            type_val=""
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
            is_ws=0
            type_val=""
            next
        }
        in_item {
            item_buf=item_buf $0 "\n"
            if ($0 ~ /^[[:space:]]+#[[:space:]]*vpsgo-vless-type:[[:space:]]*ws/) {
                is_ws=1
            }
            if ($0 ~ /^    type:/) {
                line=$0
                sub(/^    type:[[:space:]]*/, "", line)
                type_val=unquote(trim(line))
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
        function flush_vless_user() {
            if (current_vless_username == "") return
            if (user_id == "") user_id=current_vless_username
            if (user_pass == "") user_pass=current_vless_uuid
            if (vless_flow == "") vless_flow=current_vless_flow
            current_vless_username=""
            current_vless_uuid=""
            current_vless_flow=""
        }
        function reset_state() {
            name=tag=type=port=cipher=password=user_id=user_pass=sni=""
            hy2_up=hy2_down=hy2_ignore=hy2_obfs=hy2_obfs_password=hy2_masquerade=hy2_mport=hy2_insecure=hy2_congestion_control=""
            vless_public_key=vless_short_id=vless_flow=vless_client_fingerprint=""
            tuic_congestion_control=tuic_alpn=tuic_udp_relay_mode=""
            vless_type=vless_ws_path=vless_ws_tls=vless_ws_host=vless_grpc_service_name=""
            in_users=0
            item_indent=-1
            users_indent=-1
            current_vless_username=current_vless_uuid=current_vless_flow=""
        }
        function emit() {
            if (name == "") return
            flush_vless_user()
            actual_type = type
            if (type == "vless") {
                if (vless_type == "ws") {
                    actual_type = "vless-ws"
                } else if (vless_type == "grpc") {
                    actual_type = "vless-grpc"
                }
            }
            printf "%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\n", \
                actual_type, name, port, cipher, password, user_id, user_pass, sni, hy2_up, hy2_down, \
                hy2_ignore, hy2_obfs, hy2_obfs_password, hy2_masquerade, hy2_mport, hy2_insecure, tag, \
                vless_public_key, vless_short_id, vless_flow, vless_client_fingerprint, \
                tuic_congestion_control, tuic_alpn, tuic_udp_relay_mode, hy2_congestion_control, \
                vless_type, vless_ws_path, vless_ws_tls, vless_ws_host, vless_grpc_service_name
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
            hy2_up=hy2_down=hy2_ignore=hy2_obfs=hy2_obfs_password=hy2_masquerade=hy2_mport=hy2_insecure=hy2_congestion_control=""
            vless_public_key=vless_short_id=vless_flow=vless_client_fingerprint=""
            tuic_congestion_control=tuic_alpn=tuic_udp_relay_mode=""
            in_users=0
            users_indent=-1
            next
        }
        in_users {
            curr_indent=lindent($0)
            if (curr_indent <= users_indent) {
                flush_vless_user()
                in_users=0
            } else if ($0 ~ /^[[:space:]]*-[[:space:]]*username:/) {
                flush_vless_user()
                line=$0
                sub(/^[[:space:]]*-[[:space:]]*username:[[:space:]]*/, "", line)
                current_vless_username=unquote(trim(line))
                next
            } else if (current_vless_username != "" && $0 ~ /^[[:space:]]+uuid:/) {
                line=$0
                sub(/^[[:space:]]+uuid:[[:space:]]*/, "", line)
                current_vless_uuid=unquote(trim(line))
                next
            } else if (current_vless_username != "" && $0 ~ /^[[:space:]]+password:/) {
                line=$0
                sub(/^[[:space:]]+password:[[:space:]]*/, "", line)
                current_vless_uuid=unquote(trim(line))
                next
            } else if (current_vless_username != "" && $0 ~ /^[[:space:]]+flow:/) {
                line=$0
                sub(/^[[:space:]]+flow:[[:space:]]*/, "", line)
                current_vless_flow=unquote(trim(line))
                next
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
        /^[[:space:]]+#[[:space:]]*vpsgo-server-name:/ {
            line=$0
            sub(/^[[:space:]]+#[[:space:]]*vpsgo-server-name:[[:space:]]*/, "", line)
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
        /^[[:space:]]+#[[:space:]]*vpsgo-hy2-congestion-control:/ {
            line=$0
            sub(/^[[:space:]]+#[[:space:]]*vpsgo-hy2-congestion-control:[[:space:]]*/, "", line)
            hy2_congestion_control=trim(line)
            next
        }
        /^[[:space:]]+#[[:space:]]*vpsgo-reality-public-key:/ {
            line=$0
            sub(/^[[:space:]]+#[[:space:]]*vpsgo-reality-public-key:[[:space:]]*/, "", line)
            vless_public_key=unquote(trim(line))
            next
        }
        /^[[:space:]]+#[[:space:]]*vpsgo-reality-short-id:/ {
            line=$0
            sub(/^[[:space:]]+#[[:space:]]*vpsgo-reality-short-id:[[:space:]]*/, "", line)
            vless_short_id=unquote(trim(line))
            next
        }
        /^[[:space:]]+#[[:space:]]*vpsgo-vless-flow:/ {
            line=$0
            sub(/^[[:space:]]+#[[:space:]]*vpsgo-vless-flow:[[:space:]]*/, "", line)
            vless_flow=unquote(trim(line))
            next
        }
        /^[[:space:]]+#[[:space:]]*vpsgo-vless-client-fingerprint:/ {
            line=$0
            sub(/^[[:space:]]+#[[:space:]]*vpsgo-vless-client-fingerprint:[[:space:]]*/, "", line)
            vless_client_fingerprint=unquote(trim(line))
            next
        }
        /^[[:space:]]+#[[:space:]]*vpsgo-vless-type:/ {
            line=$0
            sub(/^[[:space:]]+#[[:space:]]*vpsgo-vless-type:[[:space:]]*/, "", line)
            vless_type=unquote(trim(line))
            next
        }
        /^[[:space:]]+#[[:space:]]*vpsgo-vless-ws-path:/ {
            line=$0
            sub(/^[[:space:]]+#[[:space:]]*vpsgo-vless-ws-path:[[:space:]]*/, "", line)
            vless_ws_path=unquote(trim(line))
            next
        }
        /^[[:space:]]+#[[:space:]]*vpsgo-vless-ws-tls:/ {
            line=$0
            sub(/^[[:space:]]+#[[:space:]]*vpsgo-vless-ws-tls:[[:space:]]*/, "", line)
            vless_ws_tls=unquote(trim(line))
            next
        }
        /^[[:space:]]+#[[:space:]]*vpsgo-vless-ws-host:/ {
            line=$0
            sub(/^[[:space:]]+#[[:space:]]*vpsgo-vless-ws-host:[[:space:]]*/, "", line)
            vless_ws_host=unquote(trim(line))
            next
        }
        /^[[:space:]]+#[[:space:]]*vpsgo-vless-grpc-service-name:/ {
            line=$0
            sub(/^[[:space:]]+#[[:space:]]*vpsgo-vless-grpc-service-name:[[:space:]]*/, "", line)
            vless_grpc_service_name=unquote(trim(line))
            next
        }
        /^[[:space:]]+#[[:space:]]*vpsgo-vless-grpc-tls:/ {
            line=$0
            sub(/^[[:space:]]+#[[:space:]]*vpsgo-vless-grpc-tls:[[:space:]]*/, "", line)
            vless_ws_tls=unquote(trim(line))
            next
        }
        /^[[:space:]]+#[[:space:]]*vpsgo-vless-grpc-host:/ {
            line=$0
            sub(/^[[:space:]]+#[[:space:]]*vpsgo-vless-grpc-host:[[:space:]]*/, "", line)
            vless_ws_host=unquote(trim(line))
            next
        }
        /^[[:space:]]+#[[:space:]]*vpsgo-tuic-congestion-control:/ {
            line=$0
            sub(/^[[:space:]]+#[[:space:]]*vpsgo-tuic-congestion-control:[[:space:]]*/, "", line)
            tuic_congestion_control=trim(line)
            next
        }
        /^[[:space:]]+#[[:space:]]*vpsgo-tuic-alpn:/ {
            line=$0
            sub(/^[[:space:]]+#[[:space:]]*vpsgo-tuic-alpn:[[:space:]]*/, "", line)
            tuic_alpn=trim(line)
            next
        }
        /^[[:space:]]+#[[:space:]]*vpsgo-tuic-udp-relay-mode:/ {
            line=$0
            sub(/^[[:space:]]+#[[:space:]]*vpsgo-tuic-udp-relay-mode:[[:space:]]*/, "", line)
            tuic_udp_relay_mode=trim(line)
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

_mihomoconf_is_valid_uuid() {
    local uuid="$1"
    [[ "$uuid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
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
            vless) password=$(_mihomoconf_gen_uuid) ;;
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
        function flush_vless_user() {
            if (current_vless_username == "") return
            printf "%s\037%s\n", current_vless_username, current_vless_uuid
            current_vless_username=""
            current_vless_uuid=""
        }
        function update_match() {
            matched = ((tag != "" && tag == target) || (name != "" && name == target))
        }
        function reset_listener() {
            flush_vless_user()
            name=""
            tag=""
            in_users=0
            matched=0
            users_indent=-1
            current_vless_username=""
            current_vless_uuid=""
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
                flush_vless_user()
                in_users=0
            } else if ($0 ~ /^[[:space:]]*-[[:space:]]*username:/) {
                flush_vless_user()
                line=$0
                sub(/^[[:space:]]*-[[:space:]]*username:[[:space:]]*/, "", line)
                current_vless_username=unquote(trim(line))
                next
            } else if (current_vless_username != "" && $0 ~ /^[[:space:]]+uuid:/) {
                line=$0
                sub(/^[[:space:]]+uuid:[[:space:]]*/, "", line)
                current_vless_uuid=unquote(trim(line))
                next
            } else if (current_vless_username != "" && $0 ~ /^[[:space:]]+password:/) {
                line=$0
                sub(/^[[:space:]]+password:[[:space:]]*/, "", line)
                current_vless_uuid=unquote(trim(line))
                next
            } else if (current_vless_username != "" && $0 ~ /^[[:space:]]+flow:/) {
                next
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
        END {
            flush_vless_user()
        }
    ' "$config_file"
}

_mihomoconf_read_listener_user_rows() {
    local config_file="$1"
    local type name port cipher password user_id user_pass sni
    local hy2_up hy2_down hy2_ignore hy2_obfs hy2_obfs_password hy2_masquerade hy2_mport hy2_insecure hy2_congestion_control listener_tag
    local vless_public_key vless_short_id vless_flow vless_client_fingerprint
    local tuic_congestion_control tuic_alpn tuic_udp_relay_mode
    local vless_type vless_ws_path vless_ws_tls vless_ws_host vless_grpc_service_name
    local username passwd
    while IFS=$'\x1f' read -r type name port cipher password user_id user_pass sni \
        hy2_up hy2_down hy2_ignore hy2_obfs hy2_obfs_password hy2_masquerade hy2_mport hy2_insecure listener_tag \
        vless_public_key vless_short_id vless_flow vless_client_fingerprint \
        tuic_congestion_control tuic_alpn tuic_udp_relay_mode hy2_congestion_control \
        vless_type vless_ws_path vless_ws_tls vless_ws_host vless_grpc_service_name; do
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
    local hy2_up hy2_down hy2_ignore hy2_obfs hy2_obfs_password hy2_masquerade hy2_mport hy2_insecure hy2_congestion_control tag
    local vless_public_key vless_short_id vless_flow vless_client_fingerprint
    local tuic_congestion_control tuic_alpn tuic_udp_relay_mode
    local vless_type vless_ws_path vless_ws_tls vless_ws_host vless_grpc_service_name
    local resolved_tag
    while IFS=$'\x1f' read -r type name port cipher password user_id user_pass sni \
        hy2_up hy2_down hy2_ignore hy2_obfs hy2_obfs_password hy2_masquerade hy2_mport hy2_insecure tag \
        vless_public_key vless_short_id vless_flow vless_client_fingerprint \
        tuic_congestion_control tuic_alpn tuic_udp_relay_mode hy2_congestion_control \
        vless_type vless_ws_path vless_ws_tls vless_ws_host vless_grpc_service_name; do
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

_mihomoconf_read_tuic_usernames_by_tag() {
    local config_file="$1" listener_tag="$2"
    awk -v target="$listener_tag" '
        function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
        function unquote(s) { gsub(/^"/, "", s); gsub(/"$/, "", s); return s }
        BEGIN { in_target=0 }
        /^  - name:/ {
            in_target=0
            line=$0; sub(/^  - name:[[:space:]]*/, "", line)
            if (unquote(trim(line)) == target) in_target=1
            next
        }
        /^    tag:/ {
            line=$0; sub(/^    tag:[[:space:]]*/, "", line)
            if (unquote(trim(line)) == target) in_target=1
            next
        }
        !in_target { next }
        /^[^ ]/ { in_target=0; next }
        /# vpsgo-tuic-username:/ {
            line=$0; sub(/^[[:space:]]+#[[:space:]]*vpsgo-tuic-username:[[:space:]]*/, "", line)
            printf "%s\n", trim(line)
        }
    ' "$config_file"
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
                if (item_type != "anytls" && item_type != "hysteria2" && item_type != "hy2" && item_type != "shadowsocks" && item_type != "tuic") {
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

_mihomoconf_add_tuic_listener_user() {
    local config_file="$1" listener_tag="$2" display_name="$3" uuid="$4" password="$5"
    local quoted_display quoted_uuid quoted_pass tmp ec

    [[ -f "$config_file" ]] || return 1
    [[ -n "$listener_tag" && -n "$display_name" && -n "$uuid" && -n "$password" ]] || return 1
    _mihomoconf_is_valid_username "$display_name" || return 1
    _mihomoconf_is_valid_uuid "$uuid" || return 1

    quoted_display=$(_mihomochain_yaml_quote "$display_name")
    quoted_uuid=$(_mihomochain_yaml_quote "$(printf '%s' "$uuid" | tr '[:upper:]' '[:lower:]')")
    quoted_pass=$(_mihomochain_yaml_quote "$password")
    tmp=$(mktemp)
    awk -v target="$listener_tag" -v q_display="$quoted_display" -v q_uuid="$quoted_uuid" -v q_pass="$quoted_pass" '
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
        function upsert_tuic_user(   i, j, line, pos, key, users_idx, users_end, user_line, comment_line, curr_indent) {
            users_idx=0
            users_end=0
            user_line=0
            comment_line=0

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
                    if (item_lines[i] ~ /^[[:space:]]+#[[:space:]]*vpsgo-tuic-username:/) {
                        comment_line=i
                    } else if (item_lines[i] ~ /^[[:space:]]+[^[:space:]#].*:/) {
                        line=item_lines[i]
                        sub(/^[[:space:]]+/, "", line)
                        pos=index(line, ":")
                        if (pos > 0) {
                            key=unquote(trim(substr(line, 1, pos - 1)))
                            if (tolower(key) == tolower(q_uuid)) {
                                user_line=i
                                break
                            }
                        }
                    }
                }
                if (user_line > 0) {
                    item_lines[user_line] = "      \"" q_uuid "\": \"" q_pass "\""
                    if (comment_line == user_line - 1) {
                        item_lines[comment_line] = "      # vpsgo-tuic-username: " q_display
                    }
                } else {
                    for (j=line_count; j>=users_end + 1; j--) {
                        item_lines[j + 2] = item_lines[j]
                    }
                    item_lines[users_end + 1] = "      # vpsgo-tuic-username: " q_display
                    item_lines[users_end + 2] = "      \"" q_uuid "\": \"" q_pass "\""
                    line_count += 2
                }
                changed=1
                return
            }

            line_count++
            item_lines[line_count] = "    users:"
            line_count++
            item_lines[line_count] = "      # vpsgo-tuic-username: " q_display
            line_count++
            item_lines[line_count] = "      \"" q_uuid "\": \"" q_pass "\""
            changed=1
        }
        function flush_item(   resolved_tag) {
            if (!in_item) return
            resolved_tag=item_tag
            if (resolved_tag == "") resolved_tag=item_name
            if (resolved_tag == target || item_name == target) {
                matched=1
                if (item_type != "tuic") {
                    unsupported=1
                    print_item()
                } else {
                    upsert_tuic_user()
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

_mihomoconf_add_socks_listener_user() {
    local config_file="$1" listener_tag="$2" username="$3" password="$4"
    local quoted_user quoted_pass tmp ec

    [[ -f "$config_file" ]] || return 1
    [[ -n "$listener_tag" && -n "$username" && -n "$password" ]] || return 1
    _mihomoconf_is_valid_username "$username" || return 1

    quoted_user=$(_mihomochain_yaml_quote "$username")
    quoted_pass=$(_mihomochain_yaml_quote "$password")
    tmp=$(mktemp)
    awk -v target="$listener_tag" -v q_user="$quoted_user" -v q_pass="$quoted_pass" '
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
        function upsert_socks_user(   i, j, line, pos, key, users_idx, users_end, user_line, username_line, password_line, curr_indent) {
            users_idx=0
            users_end=0
            username_line=0
            password_line=0

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
                    if (item_lines[i] ~ /^[[:space:]]*-[[:space:]]*username:/) {
                        line=item_lines[i]
                        sub(/^[[:space:]]*-[[:space:]]*username:[[:space:]]*/, "", line)
                        key=unquote(trim(line))
                        if (tolower(key) == tolower(q_user)) {
                            username_line=i
                            for (j=i+1; j<=line_count; j++) {
                                if (lindent(item_lines[j]) <= 4 || item_lines[j] ~ /^[[:space:]]*-[[:space:]]*username:/) {
                                    break
                                }
                                if (item_lines[j] ~ /^[[:space:]]+password:/) {
                                    password_line=j
                                    break
                                }
                            }
                            break
                        }
                    }
                }
                if (username_line > 0) {
                    item_lines[username_line] = "      - username: \"" q_user "\""
                    if (password_line > 0) {
                        item_lines[password_line] = "        password: \"" q_pass "\""
                    } else {
                        for (j=line_count; j>=username_line + 1; j--) {
                            item_lines[j + 1] = item_lines[j]
                        }
                        item_lines[username_line + 1] = "        password: \"" q_pass "\""
                        line_count++
                    }
                } else {
                    for (j=line_count; j>=users_end + 1; j--) {
                        item_lines[j + 2] = item_lines[j]
                    }
                    item_lines[users_end + 1] = "      - username: \"" q_user "\""
                    item_lines[users_end + 2] = "        password: \"" q_pass "\""
                    line_count += 2
                }
                changed=1
                return
            }

            line_count++
            item_lines[line_count] = "    users:"
            line_count++
            item_lines[line_count] = "      - username: \"" q_user "\""
            line_count++
            item_lines[line_count] = "        password: \"" q_pass "\""
            changed=1
        }
        function flush_item(   resolved_tag) {
            if (!in_item) return
            resolved_tag=item_tag
            if (resolved_tag == "") resolved_tag=item_name
            if (resolved_tag == target || item_name == target) {
                matched=1
                if (item_type != "socks") {
                    unsupported=1
                    print_item()
                } else {
                    upsert_socks_user()
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

_mihomoconf_add_vless_listener_user() {
    local config_file="$1" listener_tag="$2" username="$3" uuid="$4" flow="${5:-}"
    local quoted_user quoted_uuid quoted_flow tmp ec

    [[ -f "$config_file" ]] || return 1
    [[ -n "$listener_tag" && -n "$username" && -n "$uuid" ]] || return 1
    _mihomoconf_is_valid_username "$username" || return 1
    _mihomoconf_is_valid_uuid "$uuid" || return 1

    quoted_user=$(_mihomochain_yaml_quote "$username")
    quoted_uuid=$(_mihomochain_yaml_quote "$(printf '%s' "$uuid" | tr '[:upper:]' '[:lower:]')")
    quoted_flow=$(_mihomochain_yaml_quote "$flow")

    tmp=$(mktemp)
    awk -v target="$listener_tag" -v q_user="$quoted_user" -v q_uuid="$quoted_uuid" -v q_flow="$quoted_flow" '
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
        function upsert_vless_user(   i, j, k, line, pos, key, users_idx, users_end, user_line, curr_indent, found_user_idx) {
            users_idx=0
            users_end=0
            user_line=0
            found_user_idx=-1

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
                    if (item_lines[i] ~ /^[[:space:]]*-[[:space:]]*username:/) {
                        line=item_lines[i]
                        sub(/^[[:space:]]*-[[:space:]]*username:[[:space:]]*/, "", line)
                        if (unquote(trim(line)) == q_user) {
                            found_user_idx=i
                        }
                    }
                }

                if (found_user_idx > 0) {
                    local next_user_idx=users_end+1
                    for (k=found_user_idx+1; k<=users_end; k++) {
                        if (item_lines[k] ~ /^[[:space:]]*-[[:space:]]*username:/) {
                            next_user_idx=k
                            break
                        }
                    }
                    for (k=found_user_idx+1; k<next_user_idx; k++) {
                        if (item_lines[k] ~ /^[[:space:]]+uuid:/) {
                            item_lines[k] = "        uuid: \"" q_uuid "\""
                        }
                        if (q_flow != "" && item_lines[k] ~ /^[[:space:]]+flow:/) {
                            item_lines[k] = "        flow: " q_flow
                        }
                    }
                } else {
                    for (j=line_count; j>=users_end + 1; j--) {
                        item_lines[j + 3] = item_lines[j]
                    }
                    item_lines[users_end + 1] = "      - username: \"" q_user "\""
                    item_lines[users_end + 2] = "        uuid: \"" q_uuid "\""
                    if (q_flow != "") {
                        item_lines[users_end + 3] = "        flow: " q_flow
                        line_count += 3
                    } else {
                        for (j=users_end + 3; j<=line_count+2; j++) {
                            item_lines[j] = item_lines[j+1]
                        }
                        line_count += 2
                    }
                }
                changed=1
                return
            }

            line_count++
            item_lines[line_count] = "    users:"
            line_count++
            item_lines[line_count] = "      - username: \"" q_user "\""
            line_count++
            item_lines[line_count] = "        uuid: \"" q_uuid "\""
            if (q_flow != "") {
                line_count++
                item_lines[line_count] = "        flow: " q_flow
            }
            changed=1
        }
        function flush_item(   resolved_tag) {
            if (!in_item) return
            resolved_tag=item_tag
            if (resolved_tag == "") resolved_tag=item_name
            if (resolved_tag == target || item_name == target) {
                matched=1
                if (item_type != "vless") {
                    unsupported=1
                    print_item()
                } else {
                    upsert_vless_user()
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
    else
        rm -f "$tmp"
        return "$ec"
    fi
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

_mihomoconf_ensure_vpsgo_direct_proxy() {
    local config_file="$1" proxy_name="$2" ip_ver="$3"
    local tmp

    if ! grep -Fq "name: \"${proxy_name}\"" "$config_file"; then
        if grep -q '^proxies:[[:space:]]*$' "$config_file"; then
            tmp=$(mktemp)
            awk -v pname="$proxy_name" -v ipver="$ip_ver" '
                function print_proxy() {
                    print "  - name: \"" pname "\""
                    print "    type: direct"
                    print "    udp: true"
                    print "    ip-version: " ipver
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
                echo "    ip-version: ${ip_ver}"
            } >> "$config_file"
        fi
    fi
}

_mihomoconf_apply_vpsgo_direct_policies() {
    local config_file="$1"
    [[ -f "$config_file" ]] || return 0
    if grep -q '^[[:space:]]*-.*,vpsgo-ipv4-direct\([[:space:]]*$\|,\)' "$config_file"; then
        _mihomoconf_ensure_vpsgo_direct_proxy "$config_file" "vpsgo-ipv4-direct" "ipv4"
    fi
    if grep -q '^[[:space:]]*-.*,vpsgo-ipv6-direct\([[:space:]]*$\|,\)' "$config_file"; then
        _mihomoconf_ensure_vpsgo_direct_proxy "$config_file" "vpsgo-ipv6-direct" "ipv6"
    fi
}

_mihomoconf_dns_get() {
    local config_file="$1"
    if [[ ! -f "$config_file" ]]; then
        return 0
    fi
    awk '
        BEGIN { in_dns=0; in_nameserver=0 }
        /^dns:[[:space:]]*$/ { in_dns=1; next }
        in_dns && /^[^[:space:]#]/ { in_dns=0; in_nameserver=0 }
        in_dns && /^[[:space:]]+nameserver:[[:space:]]*$/ { in_nameserver=1; next }
        in_nameserver && /^[[:space:]]+[a-zA-Z0-9_-]+:/ { in_nameserver=0 }
        in_nameserver && /^[[:space:]]+-[[:space:]]+/ {
            item = $0
            sub(/^[[:space:]]+-[[:space:]]*/, "", item)
            gsub(/^[\x27\x22]|[\x27\x22]$/, "", item)
            print item
        }
    ' "$config_file"
}

_mihomoconf_dns_set() {
    local config_file="$1" dns_list="$2"
    local tmp
    tmp=$(mktemp)
    awk -v dns_csv="$dns_list" '
        BEGIN {
            in_dns=0
            in_nameserver=0
            dns_found=0
            nameserver_found=0
            n = split(dns_csv, arr, ",")
        }
        /^dns:[[:space:]]*$/ {
            in_dns=1
            dns_found=1
            print
            next
        }
        in_dns && /^[^[:space:]#]/ {
            if (!nameserver_found) {
                print "  nameserver:"
                for (i=1; i<=n; i++) {
                    item = arr[i]
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", item)
                    if (item != "") print "    - \"" item "\""
                }
                nameserver_found=1
            }
            in_dns=0
            in_nameserver=0
        }
        in_dns && /^[[:space:]]+nameserver:[[:space:]]*$/ {
            in_nameserver=1
            nameserver_found=1
            print "  nameserver:"
            for (i=1; i<=n; i++) {
                item = arr[i]
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", item)
                if (item != "") print "    - \"" item "\""
            }
            next
        }
        in_nameserver && /^[[:space:]]+[a-zA-Z0-9_-]+:/ {
            in_nameserver=0
        }
        in_nameserver && /^[[:space:]]+-[[:space:]]+/ {
            next
        }
        { print }
        END {
            if (!dns_found) {
                print ""
                print "dns:"
                print "  enable: true"
                print "  ipv6: true"
                print "  nameserver:"
                for (i=1; i<=n; i++) {
                    item = arr[i]
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", item)
                    if (item != "") print "    - \"" item "\""
                }
            } else if (!nameserver_found) {
                print "  nameserver:"
                for (i=1; i<=n; i++) {
                    item = arr[i]
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", item)
                    if (item != "") print "    - \"" item "\""
                }
            }
        }
    ' "$config_file" > "$tmp"
    mv "$tmp" "$config_file"
}

_mihomoconf_bootstrap_dns_get() {
    local config_file="$1"
    if [[ ! -f "$config_file" ]]; then
        return 0
    fi
    awk '
        BEGIN { in_dns=0; in_bootstrap=0 }
        /^dns:[[:space:]]*$/ { in_dns=1; next }
        in_dns && /^[^[:space:]#]/ { in_dns=0; in_bootstrap=0 }
        in_dns && /^[[:space:]]+default-nameserver:[[:space:]]*$/ { in_bootstrap=1; next }
        in_bootstrap && /^[[:space:]]+[a-zA-Z0-9_-]+:/ { in_bootstrap=0 }
        in_bootstrap && /^[[:space:]]+-[[:space:]]+/ {
            item = $0
            sub(/^[[:space:]]+-[[:space:]]*/, "", item)
            gsub(/^[\x27\x22]|[\x27\x22]$/, "", item)
            print item
        }
    ' "$config_file"
}

_mihomoconf_bootstrap_dns_set() {
    local config_file="$1" dns_list="$2"
    local tmp
    tmp=$(mktemp)
    
    if [[ -z "$dns_list" ]]; then
        awk '
            BEGIN { in_dns=0; in_bootstrap=0 }
            /^dns:[[:space:]]*$/ { in_dns=1; print; next }
            in_dns && /^[^[:space:]#]/ { in_dns=0; in_bootstrap=0 }
            in_dns && /^[[:space:]]+default-nameserver:[[:space:]]*$/ { in_bootstrap=1; next }
            in_bootstrap && /^[[:space:]]+[a-zA-Z0-9_-]+:/ { in_bootstrap=0 }
            in_bootstrap && /^[[:space:]]+-[[:space:]]+/ { next }
            { print }
        ' "$config_file" > "$tmp"
    else
        awk -v dns_csv="$dns_list" '
            BEGIN {
                in_dns=0
                in_bootstrap=0
                dns_found=0
                bootstrap_found=0
                n = split(dns_csv, arr, ",")
            }
            /^dns:[[:space:]]*$/ {
                in_dns=1
                dns_found=1
                print
                next
            }
            in_dns && /^[^[:space:]#]/ {
                if (!bootstrap_found) {
                    print "  default-nameserver:"
                    for (i=1; i<=n; i++) {
                        item = arr[i]
                        gsub(/^[[:space:]]+|[[:space:]]+$/, "", item)
                        if (item != "") print "    - \"" item "\""
                    }
                    bootstrap_found=1
                }
                in_dns=0
                in_bootstrap=0
            }
            in_dns && /^[[:space:]]+default-nameserver:[[:space:]]*$/ {
                in_bootstrap=1
                bootstrap_found=1
                print "  default-nameserver:"
                for (i=1; i<=n; i++) {
                    item = arr[i]
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", item)
                    if (item != "") print "    - \"" item "\""
                }
                next
            }
            in_bootstrap && /^[[:space:]]+[a-zA-Z0-9_-]+:/ {
                in_bootstrap=0
            }
            in_bootstrap && /^[[:space:]]+-[[:space:]]+/ {
                next
            }
            { print }
            END {
                if (!dns_found) {
                    print ""
                    print "dns:"
                    print "  enable: true"
                    print "  ipv6: true"
                    print "  default-nameserver:"
                    for (i=1; i<=n; i++) {
                        item = arr[i]
                        gsub(/^[[:space:]]+|[[:space:]]+$/, "", item)
                        if (item != "") print "    - \"" item "\""
                    }
                } else if (!bootstrap_found) {
                    print "  default-nameserver:"
                    for (i=1; i<=n; i++) {
                        item = arr[i]
                        gsub(/^[[:space:]]+|[[:space:]]+$/, "", item)
                        if (item != "") print "    - \"" item "\""
                    }
                }
            }
        ' "$config_file" > "$tmp"
    fi
    mv "$tmp" "$config_file"
}

_mihomoconf_setup() {
    _header "Mihomo 配置生成"

    local CONFIG_DIR="$_MIHOMOCONF_CONFIG_DIR"
    local CONFIG_FILE="$_MIHOMOCONF_CONFIG_FILE"
    local SSL_DIR="$_MIHOMOCONF_SSL_DIR"
    local CONFIG_STATUS

    local WRITE_MODE="new"
    local ENABLE_SS="n" ENABLE_ANYTLS="n" ENABLE_VLESS="n" ENABLE_HY2="n" ENABLE_TUIC="n" ENABLE_SOCKS="n" ENABLE_VLESS_WS="n"
    local SS_COUNT=0 ANYTLS_COUNT=0 VLESS_COUNT=0 HY2_COUNT=0 TUIC_COUNT=0 SOCKS_COUNT=0 VLESS_WS_COUNT=0
    local SS_REPLACE="n" ANYTLS_REPLACE="n" VLESS_REPLACE="n" HY2_REPLACE="n" TUIC_REPLACE="n" SOCKS_REPLACE="n" VLESS_WS_REPLACE="n"

    local -a SS_PORTS=() SS_TAGS=() SS_USER_ROWS=()
    local SS_CIPHER=""
    local SS_EXPORT_UDP="1" SS_EXPORT_UOT="1"
    local -a ANYTLS_PORTS=() ANYTLS_TAGS=() ANYTLS_USER_ROWS=()
    local ANYTLS_SNI=""
    local -a VLESS_PORTS=() VLESS_TAGS=() VLESS_USER_ROWS=() VLESS_PRIVATE_KEYS=() VLESS_PUBLIC_KEYS=() VLESS_SHORT_IDS=()
    local VLESS_REALITY_SERVER_NAME="" VLESS_FLOW="xtls-rprx-vision" VLESS_CLIENT_FINGERPRINT="chrome"
    local -a VLESS_WS_PORTS=() VLESS_WS_TAGS=() VLESS_WS_USER_ROWS=() VLESS_WS_PATHS=() VLESS_WS_TLS_OPTS=() VLESS_WS_HOSTS=()
    local -a HY2_PORTS=() HY2_TAGS=() HY2_MPORTS=() HY2_OBFS_PASSWORDS=() HY2_USER_ROWS=()
    local -a RESERVED_PORTS=() NEW_PORTS=()
    local HY2_UP="" HY2_DOWN=""
    local HY2_IGNORE_CLIENT_BANDWIDTH="false" HY2_SNI="" HY2_INSECURE="0"
    local HY2_OBFS="" HY2_MASQUERADE="" HY2_CONGESTION_CONTROL="brutal"
    local -a TUIC_PORTS=() TUIC_TAGS=() TUIC_USER_ROWS=()
    local TUIC_SNI="" TUIC_CONGESTION_CONTROL="bbr" TUIC_ALPN="h3" TUIC_UDP_RELAY_MODE="native" TUIC_INSECURE="0"
    local -a SOCKS_PORTS=() SOCKS_TAGS=() SOCKS_USER_ROWS=()
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
    _info "协议: Shadowsocks / AnyTLS / VLESS Reality / VLESS WS / HY2 / Tuic / Socks5"
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
        printf "  ${BOLD}选择配置方式${PLAIN}\n"
        _separator
        _menu_pair "1" "追加新节点到现有配置" "" "green" "2" "覆盖并重新生成配置" "" "yellow"
        _menu_item "0" "返回主菜单" "" "red"
        _separator
        local file_action
        read -rp "  选择 [0-2]: " file_action
        case "$file_action" in
            1) WRITE_MODE="append" ;;
            2) WRITE_MODE="new" ;;
            0) return ;;
            *) _error_no_exit "无效选项"; _press_any_key; return ;;
        esac
    fi

    # ---- 选择协议 ----
    printf "  ${BOLD}选择协议，可重复输入${PLAIN}\n"
    printf "  ${DIM}提示: 每输入一次数字就会创建一个对应协议入站，例如 1 1 3 = 2个Shadowsocks + 1个HY2${PLAIN}\n"
    _separator
    _menu_pair "1" "Shadowsocks" "" "green" "2" "AnyTLS" "" "green"
    _menu_pair "3" "VLESS Vision Reality" "" "green" "4" "HY2" "" "green"
    _menu_pair "5" "Tuic" "" "green" "6" "Socks5" "" "green"
    _menu_item "7" "VLESS WebSocket (CDN 回源)" "" "green"
    _separator
    local PROTOCOL_CHOICES
    read -rp "  选择 (如 \"1 1 2\" 表示 2 个 SS + 1 个 AnyTLS): " -a PROTOCOL_CHOICES

    for ch in "${PROTOCOL_CHOICES[@]}"; do
        case "$ch" in
            1) ENABLE_SS="y"; SS_COUNT=$((SS_COUNT + 1)) ;;
            2) ENABLE_ANYTLS="y"; ANYTLS_COUNT=$((ANYTLS_COUNT + 1)) ;;
            3) ENABLE_VLESS="y"; VLESS_COUNT=$((VLESS_COUNT + 1)) ;;
            4) ENABLE_HY2="y"; HY2_COUNT=$((HY2_COUNT + 1)) ;;
            5) ENABLE_TUIC="y"; TUIC_COUNT=$((TUIC_COUNT + 1)) ;;
            6) ENABLE_SOCKS="y"; SOCKS_COUNT=$((SOCKS_COUNT + 1)) ;;
            7) ENABLE_VLESS_WS="y"; VLESS_WS_COUNT=$((VLESS_WS_COUNT + 1)) ;;
            *) _warn "忽略无效选项: $ch" ;;
        esac
    done
    if [[ "$SS_COUNT" -eq 0 && "$ANYTLS_COUNT" -eq 0 && "$VLESS_COUNT" -eq 0 && "$HY2_COUNT" -eq 0 && "$TUIC_COUNT" -eq 0 && "$SOCKS_COUNT" -eq 0 && "$VLESS_WS_COUNT" -eq 0 ]]; then
        _error_no_exit "未选择任何协议"
        _press_any_key
        return
    fi
    _status_kv "SS 数量" "${SS_COUNT}" "cyan" 10
    _status_kv "AnyTLS 数量" "${ANYTLS_COUNT}" "cyan" 10
    _status_kv "VLESS 数量" "${VLESS_COUNT}" "cyan" 10
    _status_kv "VLESS WS 数量" "${VLESS_WS_COUNT}" "cyan" 10
    _status_kv "HY2 数量" "${HY2_COUNT}" "cyan" 10
    _status_kv "Tuic 数量" "${TUIC_COUNT}" "cyan" 10
    _status_kv "Socks5 数量" "${SOCKS_COUNT}" "cyan" 10

    # ---- 追加模式: 检查已有同协议节点 ----
    if [[ "$WRITE_MODE" == "append" ]]; then
        if [[ "$ENABLE_SS" == "y" ]] && _mihomoconf_has_listener_type "shadowsocks"; then
            _warn "配置中已存在 Shadowsocks 节点:"
            _mihomoconf_list_listeners "shadowsocks"
            _separator
            _menu_pair "1" "覆盖已有 Shadowsocks 节点" "" "yellow" "2" "保留已有，继续添加" "" "green"
            _separator
            local ss_action
        read -rp "  选择 [1/2]（默认 2）: " ss_action
            [[ "${ss_action:-2}" == "1" ]] && SS_REPLACE="y"
        fi
        if [[ "$ENABLE_ANYTLS" == "y" ]] && _mihomoconf_has_listener_type "anytls"; then
            _warn "配置中已存在 AnyTLS 节点:"
            _mihomoconf_list_listeners "anytls"
            _separator
            _menu_pair "1" "覆盖已有 AnyTLS 节点" "" "yellow" "2" "保留已有，继续添加" "" "green"
            _separator
            local anytls_action
        read -rp "  选择 [1/2]（默认 2）: " anytls_action
            [[ "${anytls_action:-2}" == "1" ]] && ANYTLS_REPLACE="y"
        fi
        if [[ "$ENABLE_VLESS" == "y" ]] && _mihomoconf_has_listener_type "vless"; then
            _warn "配置中已存在 VLESS Vision Reality 节点:"
            _mihomoconf_list_listeners "vless"
            _separator
            _menu_pair "1" "覆盖已有 VLESS 节点" "" "yellow" "2" "保留已有，继续添加" "" "green"
            _separator
            local vless_action
        read -rp "  选择 [1/2]（默认 2）: " vless_action
            [[ "${vless_action:-2}" == "1" ]] && VLESS_REPLACE="y"
        fi
        if [[ "$ENABLE_VLESS_WS" == "y" ]] && _mihomoconf_has_listener_type "vless-ws"; then
            _warn "配置中已存在 VLESS WebSocket 节点:"
            _mihomoconf_list_listeners "vless-ws"
            _separator
            _menu_pair "1" "覆盖已有 VLESS WS 节点" "" "yellow" "2" "保留已有，继续添加" "" "green"
            _separator
            local vless_ws_action
        read -rp "  选择 [1/2]（默认 2）: " vless_ws_action
            [[ "${vless_ws_action:-2}" == "1" ]] && VLESS_WS_REPLACE="y"
        fi
        if [[ "$ENABLE_HY2" == "y" ]] && _mihomoconf_has_listener_type "hysteria2"; then
            _warn "配置中已存在 HY2 节点:"
            _mihomoconf_list_listeners "hysteria2"
            _separator
            _menu_pair "1" "覆盖已有 HY2 节点" "" "yellow" "2" "保留已有，继续添加" "" "green"
            _separator
            local hy2_action
        read -rp "  选择 [1/2]（默认 2）: " hy2_action
            [[ "${hy2_action:-2}" == "1" ]] && HY2_REPLACE="y"
        fi
        if [[ "$ENABLE_TUIC" == "y" ]] && _mihomoconf_has_listener_type "tuic"; then
            _warn "配置中已存在 Tuic 节点:"
            _mihomoconf_list_listeners "tuic"
            _separator
            _menu_pair "1" "覆盖已有 Tuic 节点" "" "yellow" "2" "保留已有，继续添加" "" "green"
            _separator
            local tuic_action
        read -rp "  选择 [1/2]（默认 2）: " tuic_action
            [[ "${tuic_action:-2}" == "1" ]] && TUIC_REPLACE="y"
        fi
        if [[ "$ENABLE_SOCKS" == "y" ]] && _mihomoconf_has_listener_type "socks"; then
            _warn "配置中已存在 Socks5 节点:"
            _mihomoconf_list_listeners "socks"
            _separator
            _menu_pair "1" "覆盖已有 Socks5 节点" "" "yellow" "2" "保留已有，继续添加" "" "green"
            _separator
            local socks_action
        read -rp "  选择 [1/2]（默认 2）: " socks_action
            [[ "${socks_action:-2}" == "1" ]] && SOCKS_REPLACE="y"
        fi
    fi

    # ---- 端口冲突基线: 追加模式下保留现有端口（被替换协议除外）----
    if [[ "$WRITE_MODE" == "append" && -f "$CONFIG_FILE" ]]; then
        local _e_type _e_name _e_port _e_cipher _e_password _e_user_id _e_user_pass _e_sni _e_tag
        local _e_hy2_up _e_hy2_down _e_hy2_ignore _e_hy2_obfs _e_hy2_obfs_password _e_hy2_masquerade _e_hy2_mport _e_hy2_insecure _e_hy2_congestion_control
        local _e_vless_public_key _e_vless_short_id _e_vless_flow _e_vless_client_fingerprint
        local _e_tuic_congestion_control _e_tuic_alpn _e_tuic_udp_relay_mode
        local _e_vless_type _e_vless_ws_path _e_vless_ws_tls _e_vless_ws_host _e_vless_grpc_service_name
        while IFS=$'\x1f' read -r _e_type _e_name _e_port _e_cipher _e_password _e_user_id _e_user_pass _e_sni \
            _e_hy2_up _e_hy2_down _e_hy2_ignore _e_hy2_obfs _e_hy2_obfs_password _e_hy2_masquerade _e_hy2_mport _e_hy2_insecure _e_tag \
            _e_vless_public_key _e_vless_short_id _e_vless_flow _e_vless_client_fingerprint \
            _e_tuic_congestion_control _e_tuic_alpn _e_tuic_udp_relay_mode _e_hy2_congestion_control \
            _e_vless_type _e_vless_ws_path _e_vless_ws_tls _e_vless_ws_host _e_vless_grpc_service_name; do
            [[ -z "${_e_port:-}" ]] && continue
            case "$_e_type" in
                shadowsocks) [[ "$SS_REPLACE" == "y" ]] && continue ;;
                anytls) [[ "$ANYTLS_REPLACE" == "y" ]] && continue ;;
                vless) [[ "$VLESS_REPLACE" == "y" ]] && continue ;;
                vless-ws) [[ "$VLESS_WS_REPLACE" == "y" ]] && continue ;;
                vless-grpc) [[ "$VLESS_GRPC_REPLACE" == "y" ]] && continue ;;
                hysteria2) [[ "$HY2_REPLACE" == "y" ]] && continue ;;
                tuic) [[ "$TUIC_REPLACE" == "y" ]] && continue ;;
                socks) [[ "$SOCKS_REPLACE" == "y" ]] && continue ;;
            esac
            _mihomoconf_port_in_list "$_e_port" "${RESERVED_PORTS[@]}" || RESERVED_PORTS+=("$_e_port")
        done < <(_mihomoconf_read_listener_rows "$CONFIG_FILE")
        if [ "${#RESERVED_PORTS[@]}" -gt 0 ]; then
            _info "已加载现有监听端口 ${#RESERVED_PORTS[@]} 个，创建时将自动避开冲突"
        fi
    fi

    # ---- Shadowsocks 配置 ----
    if [[ "$ENABLE_SS" == "y" ]]; then
        printf "  ${BOLD}Shadowsocks 配置${PLAIN}\n"
        _separator
        local _ss_idx ss_port_input
        for ((_ss_idx=1; _ss_idx<=SS_COUNT; _ss_idx++)); do
            while true; do
                read -rp "    Shadowsocks #${_ss_idx} 监听端口 [默认 12353]: " ss_port_input
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

        echo "    选择加密方式:"
        printf "      ${GREEN}1${PLAIN}) chacha20-ietf-poly1305\n"
        printf "      ${GREEN}2${PLAIN}) aes-256-gcm\n"
        printf "      ${GREEN}3${PLAIN}) aes-128-gcm\n"
        printf "      ${GREEN}4${PLAIN}) 2022-blake3-aes-128-gcm\n"
        printf "      ${GREEN}5${PLAIN}) 2022-blake3-aes-256-gcm\n"
        local cipher_choice
        read -rp "    选择 [1-5]（默认 1）: " cipher_choice
        case "${cipher_choice:-1}" in
            1) SS_CIPHER="chacha20-ietf-poly1305" ;;
            2) SS_CIPHER="aes-256-gcm" ;;
            3) SS_CIPHER="aes-128-gcm" ;;
            4) SS_CIPHER="2022-blake3-aes-128-gcm" ;;
            5) SS_CIPHER="2022-blake3-aes-256-gcm" ;;
            *) _error_no_exit "无效选项"; _press_any_key; return ;;
        esac
        local i _u_name _u_pass
        for i in "${!SS_PORTS[@]}"; do
            SS_TAGS+=("$(_mihomoconf_gen_listener_tag "ss_relay")")
            read -rp "    Shadowsocks #$((i + 1)) 用户名 [留空自动生成]: " _u_name < /dev/tty
            _u_name=$(_mihomoconf_trim "${_u_name:-}")
            if [[ -z "$_u_name" ]]; then
                _u_name="user-$(_mihomoconf_gen_uuid | cut -d'-' -f1)"
                _info "已自动生成用户名: ${_u_name}"
            elif ! _mihomoconf_is_valid_username "$_u_name"; then
                _warn "用户名无效，仅支持字母/数字/.-_，已自动生成"
                _u_name="user-$(_mihomoconf_gen_uuid | cut -d'-' -f1)"
                _info "自动生成用户名: ${_u_name}"
            fi
            _u_pass=$(_mihomoconf_gen_ss_password_for_cipher "$SS_CIPHER")
            SS_USER_ROWS+=("${i}"$'\x1f'"${_u_name}"$'\x1f'"${_u_pass}")
        done
        _info "Shadowsocks 已生成 ${#SS_PORTS[@]} 个入站节点"
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

    # ---- VLESS Vision Reality 配置 ----
    if [[ "$ENABLE_VLESS" == "y" ]]; then
        printf "  ${BOLD}VLESS Vision Reality 配置${PLAIN}\n"
        _separator
        local _vless_idx vless_port_input
        for ((_vless_idx=1; _vless_idx<=VLESS_COUNT; _vless_idx++)); do
            while true; do
                read -rp "    VLESS #${_vless_idx} 监听端口 [默认 443]: " vless_port_input
                vless_port_input=$(_mihomoconf_trim "${vless_port_input:-443}")
                if _is_valid_port "$vless_port_input"; then
                    if _mihomoconf_port_in_list "$vless_port_input" "${NEW_PORTS[@]}"; then
                        _warn "端口 ${vless_port_input} 与本次新增节点冲突，请更换端口"
                        continue
                    fi
                    if _mihomoconf_port_in_list "$vless_port_input" "${RESERVED_PORTS[@]}"; then
                        _warn "端口 ${vless_port_input} 已被现有 listeners 占用，请更换端口"
                        continue
                    fi
                    VLESS_PORTS+=("$vless_port_input")
                    NEW_PORTS+=("$vless_port_input")
                    break
                fi
                _warn "端口无效，请输入 1-65535 的数字"
            done
        done

        if [[ -n "${ANYTLS_SNI:-}" ]]; then
            read -rp "    伪造域名 [默认复用 AnyTLS: ${ANYTLS_SNI}]: " VLESS_REALITY_SERVER_NAME
            VLESS_REALITY_SERVER_NAME=$(_mihomoconf_trim "${VLESS_REALITY_SERVER_NAME:-$ANYTLS_SNI}")
        else
            read -rp "    伪造域名 (必填，如 www.microsoft.com): " VLESS_REALITY_SERVER_NAME
            VLESS_REALITY_SERVER_NAME=$(_mihomoconf_trim "${VLESS_REALITY_SERVER_NAME:-}")
        fi
        if [[ -z "$VLESS_REALITY_SERVER_NAME" ]]; then
            _error_no_exit "VLESS Reality 伪造域名不能为空"
            _press_any_key
            return
        fi

        local i _keypair _vless_private_key _vless_public_key _vless_short_id
        local _user_rows _u_name _u_uuid _vless_user_total=0
        for i in "${!VLESS_PORTS[@]}"; do
            if ! _keypair=$(_mihomoconf_gen_reality_keypair); then
                _error_no_exit "生成 Reality 密钥失败，请先安装支持 reality-keypair 的 mihomo 后重试"
                _press_any_key
                return
            fi
            IFS=$'\t' read -r _vless_private_key _vless_public_key <<< "$_keypair"
            _vless_short_id=$(_mihomoconf_gen_reality_short_id)
            VLESS_PRIVATE_KEYS+=("$_vless_private_key")
            VLESS_PUBLIC_KEYS+=("$_vless_public_key")
            VLESS_SHORT_IDS+=("$_vless_short_id")
            VLESS_TAGS+=("$(_mihomoconf_gen_listener_tag "vless_relay")")

            _user_rows=$(_mihomoconf_collect_users_input "VLESS #$((i + 1))" "" "vless")
            while IFS=$'\t' read -r _u_name _u_uuid; do
                [[ -z "${_u_name:-}" || -z "${_u_uuid:-}" ]] && continue
                VLESS_USER_ROWS+=("${i}"$'\x1f'"${_u_name}"$'\x1f'"${_u_uuid}")
                _vless_user_total=$((_vless_user_total + 1))
            done <<< "$_user_rows"
        done
        _info "VLESS Vision Reality 已生成 ${#VLESS_PORTS[@]} 个入站，共 ${_vless_user_total} 个 user"
    fi

    # ---- VLESS WebSocket 配置 ----
    if [[ "$ENABLE_VLESS_WS" == "y" ]]; then
        printf "  ${BOLD}VLESS WebSocket 配置${PLAIN}\n"
        _separator
        local _vless_ws_idx vless_ws_port_input
        for ((_vless_ws_idx=1; _vless_ws_idx<=VLESS_WS_COUNT; _vless_ws_idx++)); do
            while true; do
                read -rp "    VLESS WS #${_vless_ws_idx} 监听端口 [默认 8080]: " vless_ws_port_input
                vless_ws_port_input=$(_mihomoconf_trim "${vless_ws_port_input:-8080}")
                if _is_valid_port "$vless_ws_port_input"; then
                    if _mihomoconf_port_in_list "$vless_ws_port_input" "${NEW_PORTS[@]}"; then
                        _warn "端口 ${vless_ws_port_input} 与本次新增节点冲突，请更换端口"
                        continue
                    fi
                    if _mihomoconf_port_in_list "$vless_ws_port_input" "${RESERVED_PORTS[@]}"; then
                        _warn "端口 ${vless_ws_port_input} 已被现有 listeners 占用，请更换端口"
                        continue
                    fi
                    VLESS_WS_PORTS+=("$vless_ws_port_input")
                    NEW_PORTS+=("$vless_ws_port_input")
                    break
                fi
                _warn "端口无效，请输入 1-65535 的数字"
            done
        done

        local _vless_ws_path_input _vless_ws_tls_input _vless_ws_host_input
        local i _user_rows _u_name _u_uuid _vless_ws_user_total=0
        for i in "${!VLESS_WS_PORTS[@]}"; do
            read -rp "    VLESS WS #$((i + 1)) WebSocket Path [默认 /vless-ws]: " _vless_ws_path_input
            _vless_ws_path_input=$(_mihomoconf_trim "${_vless_ws_path_input:-/vless-ws}")
            [[ "${_vless_ws_path_input:0:1}" != "/" ]] && _vless_ws_path_input="/${_vless_ws_path_input}"
            VLESS_WS_PATHS+=("$_vless_ws_path_input")

            read -rp "    VLESS WS #$((i + 1)) 是否启用 TLS (用于 CDN https 回源) [y/N]: " _vless_ws_tls_input
            _vless_ws_tls_input=$(_mihomoconf_trim "${_vless_ws_tls_input:-N}")
            if [[ "$_vless_ws_tls_input" =~ ^[Yy]$ ]]; then
                VLESS_WS_TLS_OPTS+=("true")
            else
                VLESS_WS_TLS_OPTS+=("false")
            fi

            read -rp "    VLESS WS #$((i + 1)) CDN Host / 域名 (可选，留空则不校验主机名): " _vless_ws_host_input
            VLESS_WS_HOSTS+=("$(_mihomoconf_trim "${_vless_ws_host_input:-}")")

            VLESS_WS_TAGS+=("$(_mihomoconf_gen_listener_tag "vless_ws_relay")")

            _user_rows=$(_mihomoconf_collect_users_input "VLESS WS #$((i + 1))" "" "vless")
            while IFS=$'\t' read -r _u_name _u_uuid; do
                [[ -z "${_u_name:-}" || -z "${_u_uuid:-}" ]] && continue
                VLESS_WS_USER_ROWS+=("${i}"$'\x1f'"${_u_name}"$'\x1f'"${_u_uuid}")
                _vless_ws_user_total=$((_vless_ws_user_total + 1))
            done <<< "$_user_rows"
        done
        _info "VLESS WebSocket 已生成 ${#VLESS_WS_PORTS[@]} 个入站，共 ${_vless_ws_user_total} 个 user"
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

        # congestion control (must precede up/down: only brutal needs bandwidth)
        printf "    选择拥塞控制:\n"
        printf "      ${GREEN}1${PLAIN}) brutal ${DIM}(激进，默认)${PLAIN}\n"
        printf "      ${GREEN}2${PLAIN}) bbr ${DIM}(温和)${PLAIN}\n"
        printf "      ${GREEN}3${PLAIN}) reno ${DIM}(最温和)${PLAIN}\n"
        local hy2_cc_choice
        read -rp "    选择 [1/2/3]（默认 1）: " hy2_cc_choice
        case "${hy2_cc_choice:-1}" in
            1) HY2_CONGESTION_CONTROL="brutal" ;;
            2) HY2_CONGESTION_CONTROL="bbr" ;;
            3) HY2_CONGESTION_CONTROL="reno" ;;
            *) _error_no_exit "无效选项"; _press_any_key; return ;;
        esac

        if [[ "$HY2_CONGESTION_CONTROL" == "brutal" ]]; then
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
        else
            HY2_UP=""
            HY2_DOWN=""
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

    # ---- Tuic 配置 ----
    if [[ "$ENABLE_TUIC" == "y" ]]; then
        printf "  ${BOLD}Tuic 配置${PLAIN}\n"
        _separator
        local _tuic_idx tuic_port_input
        for ((_tuic_idx=1; _tuic_idx<=TUIC_COUNT; _tuic_idx++)); do
            while true; do
                read -rp "    Tuic #${_tuic_idx} 监听端口 [默认 8443]: " tuic_port_input
                tuic_port_input=$(_mihomoconf_trim "${tuic_port_input:-8443}")
                if _is_valid_port "$tuic_port_input"; then
                    if _mihomoconf_port_in_list "$tuic_port_input" "${NEW_PORTS[@]}"; then
                        _warn "端口 ${tuic_port_input} 与本次新增节点冲突，请更换端口"
                        continue
                    fi
                    if _mihomoconf_port_in_list "$tuic_port_input" "${RESERVED_PORTS[@]}"; then
                        _warn "端口 ${tuic_port_input} 已被现有 listeners 占用，请更换端口"
                        continue
                    fi
                    TUIC_PORTS+=("$tuic_port_input")
                    NEW_PORTS+=("$tuic_port_input")
                    break
                fi
                _warn "端口无效，请输入 1-65535 的数字"
            done
        done

        if [[ -n "${ANYTLS_SNI:-}" ]]; then
            read -rp "    Tuic SNI 域名 [默认复用 AnyTLS: ${ANYTLS_SNI}]: " TUIC_SNI
            TUIC_SNI=$(_mihomoconf_trim "${TUIC_SNI:-$ANYTLS_SNI}")
        else
            read -rp "    Tuic SNI 域名 (留空则用 IP): " TUIC_SNI
            TUIC_SNI=$(_mihomoconf_trim "${TUIC_SNI:-}")
        fi

        # congestion control
        printf "    选择拥塞控制:\n"
        printf "      ${GREEN}1${PLAIN}) bbr\n"
        printf "      ${GREEN}2${PLAIN}) cubic\n"
        printf "      ${GREEN}3${PLAIN}) new_reno\n"
        local cc_choice
        read -rp "    选择 [1/2/3]（默认 1）: " cc_choice
        case "${cc_choice:-1}" in
            1) TUIC_CONGESTION_CONTROL="bbr" ;;
            2) TUIC_CONGESTION_CONTROL="cubic" ;;
            3) TUIC_CONGESTION_CONTROL="new_reno" ;;
            *) _error_no_exit "无效选项"; _press_any_key; return ;;
        esac

        # ALPN
        printf "    选择 ALPN:\n"
        printf "      ${GREEN}1${PLAIN}) h3\n"
        printf "      ${GREEN}2${PLAIN}) h3,http/1.1\n"
        local alpn_choice
        read -rp "    选择 [1/2]（默认 1）: " alpn_choice
        case "${alpn_choice:-1}" in
            1) TUIC_ALPN="h3" ;;
            2) TUIC_ALPN="h3,http/1.1" ;;
            *) _error_no_exit "无效选项"; _press_any_key; return ;;
        esac

        local i _user_rows _u_name _u_pass _tuic_user_total=0
        local _tuic_uuid
        for i in "${!TUIC_PORTS[@]}"; do
            TUIC_TAGS+=("$(_mihomoconf_gen_listener_tag "tuic_relay")")
            _user_rows=$(_mihomoconf_collect_users_input "Tuic #$((i + 1))" "1")
            while IFS=$'\t' read -r _u_name _u_pass; do
                [[ -z "${_u_name:-}" || -z "${_u_pass:-}" ]] && continue
                _tuic_uuid=$(_mihomoconf_gen_uuid)
                TUIC_USER_ROWS+=("${i}"$'\x1f'"${_u_name}"$'\x1f'"${_tuic_uuid}"$'\x1f'"${_u_pass}")
                _tuic_user_total=$((_tuic_user_total + 1))
            done <<< "$_user_rows"
        done
        _info "Tuic 已生成 ${#TUIC_PORTS[@]} 个入站，共 ${_tuic_user_total} 个 user"
    fi

    # ---- Socks5 配置 ----
    if [[ "$ENABLE_SOCKS" == "y" ]]; then
        printf "  ${BOLD}Socks5 配置${PLAIN}\n"
        _separator
        local _socks_idx socks_port_input
        for ((_socks_idx=1; _socks_idx<=SOCKS_COUNT; _socks_idx++)); do
            while true; do
                read -rp "    Socks5 #${_socks_idx} 监听端口 [默认 1080]: " socks_port_input
                socks_port_input=$(_mihomoconf_trim "${socks_port_input:-1080}")
                if _is_valid_port "$socks_port_input"; then
                    if _mihomoconf_port_in_list "$socks_port_input" "${NEW_PORTS[@]}"; then
                        _warn "端口 ${socks_port_input} 与本次新增节点冲突，请更换端口"
                        continue
                    fi
                    if _mihomoconf_port_in_list "$socks_port_input" "${RESERVED_PORTS[@]}"; then
                        _warn "端口 ${socks_port_input} 已被现有 listeners 占用，请更换端口"
                        continue
                    fi
                    SOCKS_PORTS+=("$socks_port_input")
                    NEW_PORTS+=("$socks_port_input")
                    break
                fi
                _warn "端口无效，请输入 1-65535 的数字"
            done
        done

        local i _user_rows _u_name _u_pass _socks_user_total=0
        for i in "${!SOCKS_PORTS[@]}"; do
            SOCKS_TAGS+=("$(_mihomoconf_gen_listener_tag "socks_relay")")
            _user_rows=$(_mihomoconf_collect_users_input "Socks5 #$((i + 1))")
            while IFS=$'\t' read -r _u_name _u_pass; do
                [[ -z "${_u_name:-}" || -z "${_u_pass:-}" ]] && continue
                SOCKS_USER_ROWS+=("${i}"$'\x1f'"${_u_name}"$'\x1f'"${_u_pass}")
                _socks_user_total=$((_socks_user_total + 1))
            done <<< "$_user_rows"
        done
        _info "Socks5 已生成 ${#SOCKS_PORTS[@]} 个入站，共 ${_socks_user_total} 个 user"
    fi

    # ---- TLS 证书检查 (AnyTLS / HY2 / Tuic 共用) ----
    if [[ "$ENABLE_ANYTLS" == "y" || "$ENABLE_HY2" == "y" || "$ENABLE_TUIC" == "y" ]]; then
        mkdir -p "$SSL_DIR"
        if [[ -f "${SSL_DIR}/cert.crt" && -f "${SSL_DIR}/cert.key" ]]; then
            _info "已检测到 TLS 证书: ${SSL_DIR}/"
        else
            _warn "AnyTLS/HY2/Tuic 需要 TLS 证书才能正常运行!"
            _warn "请将证书文件放到以下路径:"
            printf "    证书: ${YELLOW}${SSL_DIR}/cert.crt${PLAIN}\n"
            printf "    私钥: ${YELLOW}${SSL_DIR}/cert.key${PLAIN}\n"
            _info "目录 ${SSL_DIR}/ 已自动创建"
            printf "${YELLOW}  按任意键继续...${PLAIN}"
            _read_single_key_safely
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
    elif [[ -n "${VLESS_REALITY_SERVER_NAME:-}" ]]; then
        HOST_DEFAULT="$VLESS_REALITY_SERVER_NAME"
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
        local _vless_port _vless_tag _vless_private_key _vless_public_key _vless_short_id
        local _hy2_port _hy2_tag _hy2_mport _hy2_obfs_password
        local _tuic_port _tuic_tag _tuic_uuid
        local _vless_ws_port _vless_ws_tag _vless_ws_path _vless_ws_tls _vless_ws_host
        local _row _li _u_name _u_pass _u_uuid
        if [[ "$ENABLE_SS" == "y" ]]; then
            for i in "${!SS_PORTS[@]}"; do
                _ss_port="${SS_PORTS[$i]}"
                _ss_tag="${SS_TAGS[$i]}"
                _u_name="" _u_pass=""
                for _row in "${SS_USER_ROWS[@]}"; do
                    IFS=$'\x1f' read -r _li _u_name _u_pass <<< "$_row"
                    [[ "$_li" == "$i" ]] && break
                done
                if [[ -z "$_u_pass" ]]; then
                    _u_pass=$(_mihomoconf_gen_ss_password_for_cipher "$SS_CIPHER")
                    _u_name="direct"
                fi
                cat >> "$_target_file" <<MIHOMOCONF_SS_EOF
  - name: ss-${_u_name}-${_ss_port}
    tag: "${_ss_tag}"
    type: shadowsocks
    port: ${_ss_port}
    listen: "::"
    cipher: ${SS_CIPHER}
    password: "${_u_pass}"
    udp: true
MIHOMOCONF_SS_EOF
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
        if [[ "$ENABLE_VLESS" == "y" ]]; then
            for i in "${!VLESS_PORTS[@]}"; do
                _vless_port="${VLESS_PORTS[$i]}"
                _vless_tag="${VLESS_TAGS[$i]}"
                _vless_private_key="${VLESS_PRIVATE_KEYS[$i]}"
                _vless_public_key="${VLESS_PUBLIC_KEYS[$i]}"
                _vless_short_id="${VLESS_SHORT_IDS[$i]}"
                cat >> "$_target_file" <<MIHOMOCONF_VLESS_EOF
  - name: vless-in-${_vless_port}
    tag: "${_vless_tag}"
    type: vless
    port: ${_vless_port}
    listen: "::"
    # vpsgo-server-name: ${VLESS_REALITY_SERVER_NAME}
    # vpsgo-vless-flow: ${VLESS_FLOW}
    # vpsgo-vless-client-fingerprint: ${VLESS_CLIENT_FINGERPRINT}
    # vpsgo-reality-public-key: ${_vless_public_key}
    # vpsgo-reality-short-id: ${_vless_short_id}
    users:
MIHOMOCONF_VLESS_EOF
                for _row in "${VLESS_USER_ROWS[@]}"; do
                    IFS=$'\x1f' read -r _li _u_name _u_uuid <<< "$_row"
                    [[ "$_li" == "$i" ]] || continue
                    cat >> "$_target_file" <<MIHOMOCONF_VLESS_USER_EOF
      - username: "${_u_name}"
        uuid: "${_u_uuid}"
        flow: ${VLESS_FLOW}
MIHOMOCONF_VLESS_USER_EOF
                done
                cat >> "$_target_file" <<MIHOMOCONF_VLESS_REALITY_EOF
    reality-config:
      dest: ${VLESS_REALITY_SERVER_NAME}:443
      private-key: ${_vless_private_key}
      short-id:
        - ${_vless_short_id}
      server-names:
        - ${VLESS_REALITY_SERVER_NAME}
MIHOMOCONF_VLESS_REALITY_EOF
            done
        fi
        if [[ "$ENABLE_VLESS_WS" == "y" ]]; then
            for i in "${!VLESS_WS_PORTS[@]}"; do
                _vless_ws_port="${VLESS_WS_PORTS[$i]}"
                _vless_ws_tag="${VLESS_WS_TAGS[$i]}"
                _vless_ws_path="${VLESS_WS_PATHS[$i]}"
                _vless_ws_tls="${VLESS_WS_TLS_OPTS[$i]}"
                _vless_ws_host="${VLESS_WS_HOSTS[$i]}"
                cat >> "$_target_file" <<MIHOMOCONF_VLESS_WS_EOF
  - name: vless-ws-in-${_vless_ws_port}
    tag: "${_vless_ws_tag}"
    type: vless
    port: ${_vless_ws_port}
    listen: "::"
    # vpsgo-vless-type: ws
    # vpsgo-vless-ws-path: ${_vless_ws_path}
    # vpsgo-vless-ws-tls: ${_vless_ws_tls}
    # vpsgo-vless-ws-host: ${_vless_ws_host}
    users:
MIHOMOCONF_VLESS_WS_EOF
                for _row in "${VLESS_WS_USER_ROWS[@]}"; do
                    IFS=$'\x1f' read -r _li _u_name _u_uuid <<< "$_row"
                    [[ "$_li" == "$i" ]] || continue
                    cat >> "$_target_file" <<MIHOMOCONF_VLESS_WS_USER_EOF
      - username: "${_u_name}"
        uuid: "${_u_uuid}"
MIHOMOCONF_VLESS_WS_USER_EOF
                done
                cat >> "$_target_file" <<MIHOMOCONF_VLESS_WS_TRANS_EOF
    transport:
      type: ws
      path: ${_vless_ws_path}
MIHOMOCONF_VLESS_WS_TRANS_EOF
                if [[ -n "$_vless_ws_host" ]]; then
                    cat >> "$_target_file" <<MIHOMOCONF_VLESS_WS_HOST_EOF
      headers:
        Host: "${_vless_ws_host}"
MIHOMOCONF_VLESS_WS_HOST_EOF
                fi
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
    # vpsgo-hy2-congestion-control: ${HY2_CONGESTION_CONTROL}
    users:
MIHOMOCONF_HY2_EOF
                for _row in "${HY2_USER_ROWS[@]}"; do
                    IFS=$'\x1f' read -r _li _u_name _u_pass <<< "$_row"
                    [[ "$_li" == "$i" ]] || continue
                    printf "      \"%s\": \"%s\"\n" "$_u_name" "$_u_pass" >> "$_target_file"
                done
                if [[ -n "$HY2_UP" ]]; then
                    cat >> "$_target_file" <<MIHOMOCONF_HY2_RATE_EOF
    up: ${HY2_UP}
    down: ${HY2_DOWN}
    ignore-client-bandwidth: ${HY2_IGNORE_CLIENT_BANDWIDTH}
MIHOMOCONF_HY2_RATE_EOF
                fi
                printf '    congestion-controller: %s\n' "$HY2_CONGESTION_CONTROL" >> "$_target_file"
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
        if [[ "$ENABLE_TUIC" == "y" ]]; then
            for i in "${!TUIC_PORTS[@]}"; do
                _tuic_port="${TUIC_PORTS[$i]}"
                _tuic_tag="${TUIC_TAGS[$i]}"
                cat >> "$_target_file" <<MIHOMOCONF_TUIC_EOF
  - name: tuic-in-${_tuic_port}
    tag: "${_tuic_tag}"
    type: tuic
    port: ${_tuic_port}
    listen: "::"
    # vpsgo-peer: ${TUIC_SNI}
    # vpsgo-tuic-congestion-control: ${TUIC_CONGESTION_CONTROL}
    # vpsgo-tuic-alpn: ${TUIC_ALPN}
    # vpsgo-tuic-udp-relay-mode: ${TUIC_UDP_RELAY_MODE}
    users:
MIHOMOCONF_TUIC_EOF
                for _row in "${TUIC_USER_ROWS[@]}"; do
                    IFS=$'\x1f' read -r _li _u_name _tuic_uuid _u_pass <<< "$_row"
                    [[ "$_li" == "$i" ]] || continue
                    printf "      # vpsgo-tuic-username: %s\n" "$_u_name" >> "$_target_file"
                    printf "      \"%s\": \"%s\"\n" "$_tuic_uuid" "$_u_pass" >> "$_target_file"
                done
                printf '    congestion-controller: %s\n' "$TUIC_CONGESTION_CONTROL" >> "$_target_file"
                echo "    alpn:" >> "$_target_file"
                local _tuic_alpn_item
                IFS=',' read -r -a _tuic_alpn_arr <<< "$TUIC_ALPN"
                for _tuic_alpn_item in "${_tuic_alpn_arr[@]}"; do
                    _tuic_alpn_item=$(_mihomoconf_trim "$_tuic_alpn_item")
                    [[ -n "$_tuic_alpn_item" ]] && printf '      - %s\n' "$_tuic_alpn_item" >> "$_target_file"
                done
                cat >> "$_target_file" <<MIHOMOCONF_TUIC_TLS_EOF
    certificate: "${SSL_DIR}/cert.crt"
    private-key: "${SSL_DIR}/cert.key"
MIHOMOCONF_TUIC_TLS_EOF
            done
        fi
        if [[ "$ENABLE_SOCKS" == "y" ]]; then
            for i in "${!SOCKS_PORTS[@]}"; do
                _socks_port="${SOCKS_PORTS[$i]}"
                _socks_tag="${SOCKS_TAGS[$i]}"
                cat >> "$_target_file" <<MIHOMOCONF_SOCKS_EOF
  - name: socks-in-${_socks_port}
    tag: "${_socks_tag}"
    type: socks
    port: ${_socks_port}
    listen: "::"
    udp: true
    users:
MIHOMOCONF_SOCKS_EOF
                for _row in "${SOCKS_USER_ROWS[@]}"; do
                    IFS=$'\x1f' read -r _li _u_name _u_pass <<< "$_row"
                    [[ "$_li" == "$i" ]] || continue
                    cat >> "$_target_file" <<MIHOMOCONF_SOCKS_USER_EOF
      - username: "${_u_name}"
        password: "${_u_pass}"
MIHOMOCONF_SOCKS_USER_EOF
                done
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
        [[ "$SS_REPLACE" == "y" ]] && _mihomoconf_remove_listeners_by_type "shadowsocks" && _info "已移除旧的 Shadowsocks 节点"
        [[ "$ANYTLS_REPLACE" == "y" ]] && _mihomoconf_remove_listeners_by_type "anytls" && _info "已移除旧的 AnyTLS 节点"
        [[ "$VLESS_REPLACE" == "y" ]] && _mihomoconf_remove_listeners_by_type "vless" && _info "已移除旧的 VLESS 节点"
        [[ "$VLESS_WS_REPLACE" == "y" ]] && _mihomoconf_remove_listeners_by_type "vless-ws" && _info "已移除旧的 VLESS WS 节点"
        [[ "$HY2_REPLACE" == "y" ]] && _mihomoconf_remove_listeners_by_type "hysteria2" && _info "已移除旧的 HY2 节点"
        [[ "$TUIC_REPLACE" == "y" ]] && _mihomoconf_remove_listeners_by_type "tuic" && _info "已移除旧的 Tuic 节点"
        [[ "$SOCKS_REPLACE" == "y" ]] && _mihomoconf_remove_listeners_by_type "socks" && _info "已移除旧的 Socks5 节点"
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
    _mihomoconf_apply_vpsgo_direct_policies "$CONFIG_FILE"
    _mihomoconf_set_saved_host "$CONFIG_FILE" "$SERVER_HOST"

    # ---- 输出结果 ----
    _header "配置生成完成"
    _info "配置文件: ${CONFIG_FILE}"
    _info "写入模式: $( [[ "$WRITE_MODE" == "new" ]] && echo "全新生成" || echo "追加到现有配置" )"

    # Shadowsocks 输出
    if [[ "$ENABLE_SS" == "y" ]]; then
        local ss_export_udp_answer ss_export_uot_answer _ss_udp_bool _ss_uot_bool
        read -rp "  SS 导出: 开启 UDP? [Y/n]: " ss_export_udp_answer
        if [[ "$ss_export_udp_answer" =~ ^([Nn]|[Nn][Oo])$ ]]; then
            SS_EXPORT_UDP="0"
            SS_EXPORT_UOT="0"
            _info "已关闭 SS 导出的 UDP 与 UDP over TCP v2"
        else
            read -rp "  SS 导出: 开启 UDP over TCP v2? [Y/n]: " ss_export_uot_answer
            if [[ "$ss_export_uot_answer" =~ ^([Nn]|[Nn][Oo])$ ]]; then
                SS_EXPORT_UOT="0"
            else
                SS_EXPORT_UOT="1"
            fi
        fi
        [[ "$SS_EXPORT_UDP" == "1" ]] && _ss_udp_bool="true" || _ss_udp_bool="false"
        [[ "$SS_EXPORT_UOT" == "1" ]] && _ss_uot_bool="true" || _ss_uot_bool="false"

        printf "  ${BOLD}Shadowsocks 连接信息 (%s 个)${PLAIN}\n" "${#SS_PORTS[@]}"
        local i SS_LINK _ss_port _ss_tag _ss_name _ss_client_name _row _li _u_name _u_pass
        for i in "${!SS_PORTS[@]}"; do
            _ss_port="${SS_PORTS[$i]}"
            _ss_tag="${SS_TAGS[$i]}"
            _ss_name=$(_mihomoconf_make_node_name "SS" "$NODE_FLAG" "$NODE_COUNTRY_CODE")
            _u_name="" _u_pass=""
            for _row in "${SS_USER_ROWS[@]}"; do
                IFS=$'\x1f' read -r _li _u_name _u_pass <<< "$_row"
                [[ "$_li" == "$i" ]] && break
            done
            if [[ -z "$_u_pass" ]]; then
                _warn "  Shadowsocks 入站 ${_ss_tag} 未配置用户，已跳过导出"
                continue
            fi
            _ss_client_name="${_ss_name}-${_u_name}"
            SS_LINK=$(_mihomoconf_gen_ss_link "$SERVER_HOST" "$_ss_port" "$SS_CIPHER" "$_u_pass" "$_ss_client_name" "$SS_EXPORT_UDP" "$SS_EXPORT_UOT")
            _separator
            printf "    [%s] 节点名: ${GREEN}%s${PLAIN}\n" "$((i + 1))" "$_ss_client_name"
            printf "      入站tag: ${GREEN}%s${PLAIN}\n" "$_ss_tag"
            printf "      服务器 : ${GREEN}%s${PLAIN}\n" "$SERVER_HOST"
            printf "      端口   : ${GREEN}%s${PLAIN}\n" "$_ss_port"
            printf "      加密   : ${GREEN}%s${PLAIN}\n" "$SS_CIPHER"
            printf "      用户   : ${GREEN}%s${PLAIN}\n" "$_u_name"
            printf "      密码   : ${GREEN}%s${PLAIN}\n" "$_u_pass"
            printf "  ${BOLD}Shadowsocks 分享链接:${PLAIN}\n"
            printf "  ${GREEN}%s${PLAIN}\n" "$SS_LINK"
            printf "  ${BOLD}Clash Meta 客户端 YAML:${PLAIN}\n"
            cat <<MIHOMOCONF_SS_YAML
    proxies:
      - name: "${_ss_client_name}"
        type: ss
        server: ${SERVER_HOST}
        port: ${_ss_port}
        cipher: ${SS_CIPHER}
        password: "${_u_pass}"
MIHOMOCONF_SS_YAML
            printf "        udp: %s\n" "$_ss_udp_bool"
            printf "        tfo: true\n"
            printf "        udp-over-tcp: %s\n" "$_ss_uot_bool"
            if [[ "$SS_EXPORT_UOT" == "1" ]]; then
                printf "        udp-over-tcp-version: 2\n"
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

    # VLESS Vision Reality 输出
    if [[ "$ENABLE_VLESS" == "y" ]]; then
        printf "  ${BOLD}VLESS Vision Reality 连接信息 (%s 个)${PLAIN}\n" "${#VLESS_PORTS[@]}"
        local i VLESS_LINK _vless_port _vless_tag _vless_name _vless_client_name
        local _vless_public_key _vless_private_key _vless_short_id _vless_user_idx _u_uuid
        local _row _li _u_name
        for i in "${!VLESS_PORTS[@]}"; do
            _vless_port="${VLESS_PORTS[$i]}"
            _vless_tag="${VLESS_TAGS[$i]}"
            _vless_private_key="${VLESS_PRIVATE_KEYS[$i]}"
            _vless_public_key="${VLESS_PUBLIC_KEYS[$i]}"
            _vless_short_id="${VLESS_SHORT_IDS[$i]}"
            _vless_name=$(_mihomoconf_make_node_name "VLESS" "$NODE_FLAG" "$NODE_COUNTRY_CODE")
            _separator
            printf "    [%s] 节点名: ${GREEN}%s${PLAIN}\n" "$((i + 1))" "$_vless_name"
            printf "      入站tag : ${GREEN}%s${PLAIN}\n" "$_vless_tag"
            printf "      服务器  : ${GREEN}%s${PLAIN}\n" "$SERVER_HOST"
            printf "      端口    : ${GREEN}%s${PLAIN}\n" "$_vless_port"
            printf "      伪造域名: ${GREEN}%s${PLAIN}\n" "$VLESS_REALITY_SERVER_NAME"
            printf "      Flow    : ${GREEN}%s${PLAIN}\n" "$VLESS_FLOW"
            printf "      指纹    : ${GREEN}%s${PLAIN}\n" "$VLESS_CLIENT_FINGERPRINT"
            printf "      Reality 公钥 : ${GREEN}%s${PLAIN}\n" "$_vless_public_key"
            printf "      Reality 私钥 : ${GREEN}%s${PLAIN}\n" "$_vless_private_key"
            printf "      Short ID: ${GREEN}%s${PLAIN}\n" "$_vless_short_id"
            _vless_user_idx=0
            for _row in "${VLESS_USER_ROWS[@]}"; do
                IFS=$'\x1f' read -r _li _u_name _u_uuid <<< "$_row"
                [[ "$_li" == "$i" ]] || continue
                _vless_user_idx=$((_vless_user_idx + 1))
                _vless_client_name="${_vless_name}-${_u_name}"
                VLESS_LINK=$(_mihomoconf_gen_vless_link "$SERVER_HOST" "$_vless_port" "$_u_uuid" "$_vless_client_name" "$VLESS_REALITY_SERVER_NAME" "$_vless_public_key" "$_vless_short_id" "$VLESS_FLOW" "$VLESS_CLIENT_FINGERPRINT")
                printf "      用户[%s]: ${GREEN}%s${PLAIN}\n" "$_vless_user_idx" "$_u_name"
                printf "      UUID    : ${GREEN}%s${PLAIN}\n" "$_u_uuid"
                printf "  ${BOLD}VLESS 分享链接:${PLAIN}\n"
                printf "  ${GREEN}%s${PLAIN}\n" "$VLESS_LINK"
                printf "  ${BOLD}Clash Meta 客户端 YAML:${PLAIN}\n"
                cat <<MIHOMOCONF_VLESS_YAML
    proxies:
      - name: "${_vless_client_name}"
        type: vless
        server: ${SERVER_HOST}
        port: ${_vless_port}
        udp: true
        uuid: "${_u_uuid}"
        flow: ${VLESS_FLOW}
        packet-encoding: xudp
        tls: true
        servername: ${VLESS_REALITY_SERVER_NAME}
        client-fingerprint: ${VLESS_CLIENT_FINGERPRINT}
        reality-opts:
          public-key: "${_vless_public_key}"
          short-id: "${_vless_short_id}"
MIHOMOCONF_VLESS_YAML
            done
            if [[ "$_vless_user_idx" -eq 0 ]]; then
                _warn "  VLESS 入站 ${_vless_tag} 未配置 user，已跳过导出"
            fi
        done
    fi

    # VLESS WebSocket 输出
    if [[ "$ENABLE_VLESS_WS" == "y" ]]; then
        printf "  ${BOLD}VLESS WebSocket 连接信息 (%s 个)${PLAIN}\n" "${#VLESS_WS_PORTS[@]}"
        local i VLESS_WS_LINK _vless_ws_port _vless_ws_tag _vless_ws_name _vless_ws_client_name
        local _vless_ws_path _vless_ws_tls _vless_ws_host _vless_ws_user_idx _u_uuid
        local _row _li _u_name
        for i in "${!VLESS_WS_PORTS[@]}"; do
            _vless_ws_port="${VLESS_WS_PORTS[$i]}"
            _vless_ws_tag="${VLESS_WS_TAGS[$i]}"
            _vless_ws_path="${VLESS_WS_PATHS[$i]}"
            _vless_ws_tls="${VLESS_WS_TLS_OPTS[$i]}"
            _vless_ws_host="${VLESS_WS_HOSTS[$i]}"
            _vless_ws_name=$(_mihomoconf_make_node_name "VLESS-WS" "$NODE_FLAG" "$NODE_COUNTRY_CODE")
            _separator
            printf "    [%s] 节点名: ${GREEN}%s${PLAIN}\n" "$((i + 1))" "$_vless_ws_name"
            printf "      入站tag: ${GREEN}%s${PLAIN}\n" "$_vless_ws_tag"
            printf "      服务器 : ${GREEN}%s${PLAIN}\n" "$SERVER_HOST"
            printf "      端口   : ${GREEN}%s${PLAIN}\n" "$_vless_ws_port"
            printf "      WS Path: ${GREEN}%s${PLAIN}\n" "$_vless_ws_path"
            printf "      WS TLS : ${GREEN}%s${PLAIN}\n" "$_vless_ws_tls"
            [[ -n "$_vless_ws_host" ]] && printf "      WS Host: ${GREEN}%s${PLAIN}\n" "$_vless_ws_host"
            _vless_ws_user_idx=0
            for _row in "${VLESS_WS_USER_ROWS[@]}"; do
                IFS=$'\x1f' read -r _li _u_name _u_uuid <<< "$_row"
                [[ "$_li" == "$i" ]] || continue
                _vless_ws_user_idx=$((_vless_ws_user_idx + 1))
                _vless_ws_client_name="${_vless_ws_name}-${_u_name}"
                VLESS_WS_LINK=$(_mihomoconf_gen_vless_ws_link "$SERVER_HOST" "$_vless_ws_port" "$_u_uuid" "$_vless_ws_client_name" "$_vless_ws_path" "$_vless_ws_tls" "$_vless_ws_host")
                printf "      用户[%s]: ${GREEN}%s${PLAIN}\n" "$_vless_ws_user_idx" "$_u_name"
                printf "      UUID   : ${GREEN}%s${PLAIN}\n" "$_u_uuid"
                printf "  ${BOLD}VLESS WS 分享链接:${PLAIN}\n"
                printf "  ${GREEN}%s${PLAIN}\n" "$VLESS_WS_LINK"
                printf "  ${BOLD}Clash Meta 客户端 YAML:${PLAIN}\n"
                cat <<MIHOMOCONF_VLESS_WS_YAML
    proxies:
      - name: "${_vless_ws_client_name}"
        type: vless
        server: ${SERVER_HOST}
        port: ${_vless_ws_port}
        uuid: "${_u_uuid}"
        udp: true
        tls: ${_vless_ws_tls}
MIHOMOCONF_VLESS_WS_YAML
                if [[ "$_vless_ws_tls" == "true" && -n "$_vless_ws_host" ]]; then
                    echo "        servername: ${_vless_ws_host}"
                fi
                cat <<MIHOMOCONF_VLESS_WS_YAML2
        network: ws
        ws-opts:
          path: ${_vless_ws_path}
MIHOMOCONF_VLESS_WS_YAML2
                if [[ -n "$_vless_ws_host" ]]; then
                    cat <<MIHOMOCONF_VLESS_WS_YAML3
          headers:
            Host: ${_vless_ws_host}
MIHOMOCONF_VLESS_WS_YAML3
                fi
            done
            if [[ "$_vless_ws_user_idx" -eq 0 ]]; then
                _warn "  VLESS WS 入站 ${_vless_ws_tag} 未配置 user，已跳过导出"
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
                HY2_LINK=$(_mihomoconf_gen_hy2_link "$SERVER_HOST" "$_hy2_port" "$_u_pass" "$_hy2_client_name" "$HY2_SNI" "$HY2_INSECURE" "$HY2_OBFS" "$_hy2_obfs_password" "$_hy2_mport" "$HY2_CONGESTION_CONTROL")
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
      "obfs_password": "${_hy2_obfs_password}",
      "congestion_control": "${HY2_CONGESTION_CONTROL}"
    }
MIHOMOCONF_HY2_JSON
            done
            if [[ "$_user_idx" -eq 0 ]]; then
                _warn "  HY2 入站 ${_hy2_tag} 未配置 user，已跳过导出"
            fi
        done
    fi

    # Tuic 输出
    if [[ "$ENABLE_TUIC" == "y" ]]; then
        printf "  ${BOLD}Tuic 连接信息 (%s 个)${PLAIN}\n" "${#TUIC_PORTS[@]}"
        local i TUIC_LINK _tuic_port _tuic_tag _tuic_name _tuic_client_name
        local _row _li _u_name _tuic_uuid _u_pass _user_idx
        for i in "${!TUIC_PORTS[@]}"; do
            _tuic_port="${TUIC_PORTS[$i]}"
            _tuic_tag="${TUIC_TAGS[$i]}"
            _tuic_name=$(_mihomoconf_make_node_name "Tuic" "$NODE_FLAG" "$NODE_COUNTRY_CODE")
            _separator
            printf "    [%s] 节点名: ${GREEN}%s${PLAIN}\n" "$((i + 1))" "$_tuic_name"
            printf "      入站tag: ${GREEN}%s${PLAIN}\n" "$_tuic_tag"
            printf "      服务器 : ${GREEN}%s${PLAIN}\n" "$SERVER_HOST"
            printf "      端口   : ${GREEN}%s${PLAIN}\n" "$_tuic_port"
            [[ -n "$TUIC_SNI" ]] && printf "      SNI    : ${GREEN}%s${PLAIN}\n" "$TUIC_SNI"
            printf "      拥塞控制: ${GREEN}%s${PLAIN}\n" "$TUIC_CONGESTION_CONTROL"
            printf "      ALPN   : ${GREEN}%s${PLAIN}\n" "$TUIC_ALPN"
            printf "      UDP模式: ${GREEN}%s${PLAIN}\n" "$TUIC_UDP_RELAY_MODE"
            _user_idx=0
            for _row in "${TUIC_USER_ROWS[@]}"; do
                IFS=$'\x1f' read -r _li _u_name _tuic_uuid _u_pass <<< "$_row"
                [[ "$_li" == "$i" ]] || continue
                _user_idx=$((_user_idx + 1))
                _tuic_client_name="${_tuic_name}-${_u_name}"
                TUIC_LINK=$(_mihomoconf_gen_tuic_link "$SERVER_HOST" "$_tuic_port" "$_tuic_uuid" "$_u_pass" "$_tuic_client_name" "$TUIC_SNI" "$TUIC_CONGESTION_CONTROL" "$TUIC_ALPN" "$TUIC_UDP_RELAY_MODE")
                printf "      用户[%s]: ${GREEN}%s${PLAIN}\n" "$_user_idx" "$_u_name"
                printf "      UUID   : ${GREEN}%s${PLAIN}\n" "$_tuic_uuid"
                printf "      密码   : ${GREEN}%s${PLAIN}\n" "$_u_pass"
                printf "  ${BOLD}Tuic 分享链接:${PLAIN}\n"
                printf "  ${GREEN}%s${PLAIN}\n" "$TUIC_LINK"
                printf "  ${BOLD}Tuic JSON:${PLAIN}\n"
                cat <<MIHOMOCONF_TUIC_JSON
    {
      "type": "tuic",
      "tag": "${_tuic_client_name}",
      "server": "${SERVER_HOST}",
      "server_port": ${_tuic_port},
      "uuid": "${_tuic_uuid}",
      "password": "${_u_pass}",
      "sni": "${TUIC_SNI}",
      "congestion_control": "${TUIC_CONGESTION_CONTROL}",
      "alpn": "${TUIC_ALPN}",
      "udp_relay_mode": "${TUIC_UDP_RELAY_MODE}"
    }
MIHOMOCONF_TUIC_JSON
            done
            if [[ "$_user_idx" -eq 0 ]]; then
                _warn "  Tuic 入站 ${_tuic_tag} 未配置 user，已跳过导出"
            fi
        done
    fi

    # Socks5 输出
    if [[ "$ENABLE_SOCKS" == "y" ]]; then
        printf "  ${BOLD}Socks5 连接信息 (%s 个)${PLAIN}\n" "${#SOCKS_PORTS[@]}"
        local i SOCKS_LINK _socks_port _socks_tag _socks_name _socks_client_name
        local _row _li _u_name _u_pass _user_idx
        for i in "${!SOCKS_PORTS[@]}"; do
            _socks_port="${SOCKS_PORTS[$i]}"
            _socks_tag="${SOCKS_TAGS[$i]}"
            _socks_name=$(_mihomoconf_make_node_name "Socks5" "$NODE_FLAG" "$NODE_COUNTRY_CODE")
            _separator
            printf "    [%s] 节点名: ${GREEN}%s${PLAIN}\n" "$((i + 1))" "$_socks_name"
            printf "      入站tag: ${GREEN}%s${PLAIN}\n" "$_socks_tag"
            printf "      服务器 : ${GREEN}%s${PLAIN}\n" "$SERVER_HOST"
            printf "      端口   : ${GREEN}%s${PLAIN}\n" "$_socks_port"
            _user_idx=0
            for _row in "${SOCKS_USER_ROWS[@]}"; do
                IFS=$'\x1f' read -r _li _u_name _u_pass <<< "$_row"
                [[ "$_li" == "$i" ]] || continue
                _user_idx=$((_user_idx + 1))
                _socks_client_name="${_socks_name}-${_u_name}"
                SOCKS_LINK=$(_mihomoconf_gen_socks_link "$SERVER_HOST" "$_socks_port" "$_u_name" "$_u_pass" "$_socks_client_name")
                printf "      用户[%s]: ${GREEN}%s${PLAIN}\n" "$_user_idx" "$_u_name"
                printf "      密码   : ${GREEN}%s${PLAIN}\n" "$_u_pass"
                printf "  ${BOLD}Socks5 分享链接:${PLAIN}\n"
                printf "  ${GREEN}%s${PLAIN}\n" "$SOCKS_LINK"
                printf "  ${BOLD}Clash Meta 客户端 YAML:${PLAIN}\n"
                cat <<MIHOMOCONF_SOCKS_YAML
    proxies:
      - name: "${_socks_client_name}"
        type: socks5
        server: ${SERVER_HOST}
        port: ${_socks_port}
        username: "${_u_name}"
        password: "${_u_pass}"
        udp: true
MIHOMOCONF_SOCKS_YAML
            done
            if [[ "$_user_idx" -eq 0 ]]; then
                _warn "  Socks5 入站 ${_socks_tag} 未配置 user，已跳过导出"
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
    _mihomo_pid >/dev/null 2>&1
}

_mihomo_pid() {
    local pid ps_output

    pid=$(pgrep -x mihomo 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//' || true)
    if [[ -n "${pid:-}" ]]; then
        printf '%s' "$pid"
        return 0
    fi

    pid=$(pidof mihomo 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//' || true)
    if [[ -n "${pid:-}" ]]; then
        printf '%s' "$pid"
        return 0
    fi

    ps_output=$(ps -w 2>/dev/null || ps 2>/dev/null || true)
    pid=$(printf '%s\n' "$ps_output" | awk '
        NR == 1 { next }
        {
            line=$0
            pid=$1
            if (pid !~ /^[0-9]+$/) next
            if (line ~ /(^|[\/[:space:]])mihomo([[:space:]]|$)/ && line !~ /awk|grep|vpsgo/) {
                print pid
            }
        }
    ' | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    if [[ -n "${pid:-}" ]]; then
        printf '%s' "$pid"
        return 0
    fi

    return 1
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
        local pid p
        pid=$(_mihomo_pid 2>/dev/null || true)
        if [[ -n "$pid" ]]; then
            _info "终止旧进程 (PID: $pid)..."
            for p in $pid; do
                kill "$p" 2>/dev/null || true
            done
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
        if pid=$(_mihomo_pid 2>/dev/null); then
            _info "mihomo 已成功启动 (PID: $pid)"
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

_mihomo_reload_or_restart() {
    if ! command -v mihomo >/dev/null 2>&1; then
        _error_no_exit "未检测到 mihomo，请先安装"
        return 1
    fi

    if ! _mihomo_validate_config_dir "$_MIHOMOCONF_CONFIG_DIR"; then
        return 1
    fi

    if _mihomo_service_is_active; then
        _info "正在热重载 mihomo 配置..."
        local pids
        pids=$(_mihomo_pid 2>/dev/null || true)
        if [[ -n "$pids" ]]; then
            local pid reload_ok=1
            for pid in $pids; do
                if ! kill -HUP "$pid" 2>/dev/null; then
                    reload_ok=0
                fi
            done
            if [[ "$reload_ok" -eq 1 ]]; then
                _success "已热重载"
                return 0
            else
                _warn "配置热重载部分失败，将执行完全重启..."
            fi
        fi
    fi

    if _mihomo_service_is_configured; then
        _mihomo_restart_now
    else
        _mihomo_enable_now "1"
    fi
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
ExecReload=/bin/kill -HUP \$MAINPID

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

    if [[ -f "$config_file" ]] && grep -Eq '^[[:space:]]*type:[[:space:]]*(anytls|hysteria2|tuic)[[:space:]]*$' "$config_file"; then
        tls_required="1"
    fi

    if [[ "$tls_required" == "1" ]]; then
        if [[ ! -f "$cert_file" || ! -f "$key_file" ]]; then
            _warn "检测到 AnyTLS/HY2/Tuic 配置但 SSL 证书不完整，跳过自动启动提示"
            return 0
        fi
        _info "检测到 SSL 证书: ${ssl_dir}"
    else
        _info "当前配置未启用 AnyTLS/HY2/Tuic，跳过 SSL 证书检查"
    fi

    if _mihomo_service_is_active; then
        read -rp "  检测到 mihomo 已启动，立即热重载 (Reload) 应用新配置? [Y/n]: " answer
        if [[ "$answer" =~ ^([Nn]|[Nn][Oo])$ ]]; then
            _info "已跳过热重载"
            return 0
        fi
        _mihomo_reload_or_restart
        return $?
    fi

    if _mihomo_service_is_configured; then
        read -rp "  检测到 mihomo 服务已配置，立即启动? [Y/n]: " answer
        if [[ "$answer" =~ ^([Nn]|[Nn][Oo])$ ]]; then
            _info "已跳过启动"
            return 0
        fi
        _mihomo_restart_now
        return $?
    fi

    if [[ "$tls_required" == "1" ]]; then
        read -rp "  检测到 SSL 证书，配置自启并启动 mihomo? [Y/n]: " answer
    else
        read -rp "  配置自启并启动 mihomo? [Y/n]: " answer
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
        read -rp "  覆盖? [y/N]: " overwrite
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

    _warn "将停止并卸载 Mihomo，可删除配置目录。"
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

    local mihomo_pids mihomo_pid
    mihomo_pids=$(_mihomo_pid 2>/dev/null || true)
    if [[ -n "$mihomo_pids" ]]; then
        for mihomo_pid in $mihomo_pids; do
            kill "$mihomo_pid" 2>/dev/null || true
        done
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
    if _cron_job_exists "vpsgo-mihomo-auto-update" || [[ -f "$_MIHOMO_AUTO_UPDATE_SCRIPT" ]]; then
        _cron_job_remove "vpsgo-mihomo-auto-update"
        rm -f "$_MIHOMO_AUTO_UPDATE_SCRIPT"
        removed_count=$((removed_count + 1))
        _info "已删除定时自动更新配置"
        _restart_first_available_service cron crond >/dev/null 2>&1 || true
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
        read -rp "  同时删除配置目录 ${config_dir}? [y/N]: " remove_config
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
        read -rp "  实时跟踪日志? [y/N]: " follow
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
    local hy2_up hy2_down hy2_ignore hy2_obfs hy2_obfs_password hy2_masquerade hy2_mport hy2_insecure hy2_congestion_control
    local vless_public_key vless_short_id vless_flow vless_client_fingerprint
    local tuic_congestion_control tuic_alpn tuic_udp_relay_mode
    local vless_type vless_ws_path vless_ws_tls vless_ws_host
    local p_name p_type p_server p_port p_cipher p_user p_pass p_sni p_insecure p_obfs p_obfs_password p_mport
    local p_wg_ip p_wg_ipv6 p_wg_private_key p_wg_public_key p_wg_allowed_ips p_wg_preshared_key p_wg_reserved p_wg_mtu p_wg_keepalive
    local p_vless_uuid p_vless_flow p_vless_public_key p_vless_short_id p_vless_client_fingerprint p_vless_packet_encoding
    local SS_EXPORT_UDP="1" SS_EXPORT_UOT="1" SS_EXPORT_ASKED="0"
    local SS_EXPORT_UDP_BOOL="true" SS_EXPORT_UOT_BOOL="true"
    local NODE_COUNTRY="" NODE_CITY="" NODE_COUNTRY_CODE="UN" NODE_FLAG="🏳"
    local GEO_LOOKUP_IP=""
    local OUTPUT_LINK_ONLY="0" output_mode_answer

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

    read -rp "  输出模式: 1) 完整信息  2) 仅分享链接 [默认 2]: " output_mode_answer
    case "${output_mode_answer:-2}" in
        2) OUTPUT_LINK_ONLY="1" ;;
        1) OUTPUT_LINK_ONLY="0" ;;
        *)
            _error_no_exit "输入格式错误：请输入 1 或 2"
            _press_any_key
            return
            ;;
    esac

    if [[ "$OUTPUT_LINK_ONLY" != "1" ]]; then
        _info "配置文件: ${config_file}"
        _info "支持导出 listeners(Shadowsocks / AnyTLS / VLESS Reality / VLESS WS / HY2 / Tuic) 与 proxies(SS / WireGuard Beta)"
    fi
    saved_host=$(_mihomoconf_get_saved_host "$config_file")
    if [[ -n "$saved_host" ]]; then
        server_ip="$saved_host"
        [[ "$OUTPUT_LINK_ONLY" != "1" ]] && _info "导出 Host(配置中): ${server_ip}"
    else
        server_ip=$(_mihomoconf_get_server_ip)
        [[ "$OUTPUT_LINK_ONLY" != "1" ]] && _info "导出 Host(公网IP): ${server_ip}"
    fi
    GEO_LOOKUP_IP="$server_ip"
    if [[ ! "$GEO_LOOKUP_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        GEO_LOOKUP_IP=$(_mihomoconf_get_server_ip)
    fi
    IFS=$'\x1f' read -r NODE_COUNTRY NODE_CITY NODE_COUNTRY_CODE NODE_FLAG < <(_mihomoconf_get_geo_profile "$GEO_LOOKUP_IP")
    if [[ "$OUTPUT_LINK_ONLY" != "1" ]]; then
        if [[ -n "$NODE_CITY" ]]; then
            _info "地区识别: ${NODE_COUNTRY} ${NODE_CITY} (${NODE_FLAG}${NODE_COUNTRY_CODE})"
        else
            _info "地区识别: ${NODE_COUNTRY} (${NODE_FLAG}${NODE_COUNTRY_CODE})"
        fi
    fi

    while IFS=$'\x1f' read -r type name port cipher password user_id user_pass sni \
        hy2_up hy2_down hy2_ignore hy2_obfs hy2_obfs_password hy2_masquerade hy2_mport hy2_insecure listener_tag \
        vless_public_key vless_short_id vless_flow vless_client_fingerprint \
        tuic_congestion_control tuic_alpn tuic_udp_relay_mode hy2_congestion_control \
        vless_type vless_ws_path vless_ws_tls vless_ws_host; do
        [[ -z "${name:-}" ]] && continue
        total_count=$((total_count + 1))
        listener_total=$((listener_total + 1))
        listener_tag="${listener_tag:-$name}"

        case "$type" in
            shadowsocks)
                if [[ -z "$port" || -z "$cipher" ]]; then
                    _warn "跳过 ${name}: 节点字段不完整(port/cipher)"
                    continue
                fi
                if [[ "$SS_EXPORT_ASKED" != "1" ]]; then
                    local ss_export_udp_answer ss_export_uot_answer
                    read -rp "  SS 导出: 开启 UDP? [Y/n]: " ss_export_udp_answer < /dev/tty
                    if [[ "$ss_export_udp_answer" =~ ^([Nn]|[Nn][Oo])$ ]]; then
                        SS_EXPORT_UDP="0"
                        SS_EXPORT_UOT="0"
                        _info "已关闭 SS 导出的 UDP 与 UDP over TCP v2"
                    else
                        read -rp "  SS 导出: 开启 UDP over TCP v2? [Y/n]: " ss_export_uot_answer < /dev/tty
                        if [[ "$ss_export_uot_answer" =~ ^([Nn]|[Nn][Oo])$ ]]; then
                            SS_EXPORT_UOT="0"
                        else
                            SS_EXPORT_UOT="1"
                        fi
                    fi
                    [[ "$SS_EXPORT_UDP" == "1" ]] && SS_EXPORT_UDP_BOOL="true" || SS_EXPORT_UDP_BOOL="false"
                    [[ "$SS_EXPORT_UOT" == "1" ]] && SS_EXPORT_UOT_BOOL="true" || SS_EXPORT_UOT_BOOL="false"
                    SS_EXPORT_ASKED="1"
                fi
                local ss_link ss_name ss_user_name
                if [[ -z "$password" ]]; then
                    _warn "跳过 ${name}: 未配置密码"
                    continue
                fi
                # 兼容新旧 listener name: ss-<user>-<port> / ss2022-<user>-<port>
                case "$name" in
                    ss2022-*) ss_user_name="${name#ss2022-}" ;;
                    ss-*) ss_user_name="${name#ss-}" ;;
                    *) ss_user_name="$name" ;;
                esac
                ss_user_name="${ss_user_name%-*}"
                [[ -z "$ss_user_name" ]] && ss_user_name="$name"
                export_count=$((export_count + 1))
                listener_export=$((listener_export + 1))
                ss_name="$(_mihomoconf_make_node_name "SS" "$NODE_FLAG" "$NODE_COUNTRY_CODE")-${ss_user_name}"
                ss_link=$(_mihomoconf_gen_ss_link "$server_ip" "$port" "$cipher" "$password" "$ss_name" "$SS_EXPORT_UDP" "$SS_EXPORT_UOT")
                if [[ "$OUTPUT_LINK_ONLY" == "1" ]]; then
                    printf "%s\n" "$ss_link"
                else
                    _separator
                    printf "  ${BOLD}[Shadowsocks] %s${PLAIN}\n" "$ss_name"
                    printf "    入站tag: ${GREEN}%s${PLAIN}\n" "$listener_tag"
                    printf "    用户: ${GREEN}%s${PLAIN}\n" "$ss_user_name"
                    printf "    链接: ${GREEN}%s${PLAIN}\n" "$ss_link"
                    printf "    JSON:\n"
                    cat <<MIHOMO_SS_JSON
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
MIHOMO_SS_JSON
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
                    if [[ "$OUTPUT_LINK_ONLY" == "1" ]]; then
                        printf "%s\n" "$anytls_link"
                    else
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
                    fi
                done < <(_mihomoconf_read_users_by_tag "$config_file" "$listener_tag")
                if [[ "$anytls_found" -eq 0 ]]; then
                    _warn "跳过 ${name}: 未配置可用 user"
                fi
                ;;
            vless)
                if [[ -z "$port" || -z "$sni" || -z "$vless_public_key" || -z "$vless_short_id" ]]; then
                    _warn "跳过 ${name}: VLESS Reality 字段不完整(port/server-name/public-key/short-id)"
                    continue
                fi
                local vless_found=0 vless_link vless_name vless_user vless_uuid vless_flow_value vless_fp_value
                vless_flow_value="${vless_flow:-xtls-rprx-vision}"
                vless_fp_value="${vless_client_fingerprint:-chrome}"
                while IFS=$'\x1f' read -r vless_user vless_uuid; do
                    [[ -z "${vless_user:-}" || -z "${vless_uuid:-}" ]] && continue
                    vless_found=1
                    export_count=$((export_count + 1))
                    listener_export=$((listener_export + 1))
                    vless_name="$(_mihomoconf_make_node_name "VLESS" "$NODE_FLAG" "$NODE_COUNTRY_CODE")-${vless_user}"
                    vless_link=$(_mihomoconf_gen_vless_link "$server_ip" "$port" "$vless_uuid" "$vless_name" "$sni" "$vless_public_key" "$vless_short_id" "$vless_flow_value" "$vless_fp_value")
                    if [[ "$OUTPUT_LINK_ONLY" == "1" ]]; then
                        printf "%s\n" "$vless_link"
                    else
                        _separator
                        printf "  ${BOLD}[VLESS Reality] %s${PLAIN}\n" "$vless_name"
                        printf "    入站tag: ${GREEN}%s${PLAIN}\n" "$listener_tag"
                        printf "    用户: ${GREEN}%s${PLAIN}\n" "$vless_user"
                        printf "    UUID: ${GREEN}%s${PLAIN}\n" "$vless_uuid"
                        printf "    伪造域名: ${GREEN}%s${PLAIN}\n" "$sni"
                        printf "    Reality 公钥: ${GREEN}%s${PLAIN}\n" "$vless_public_key"
                        printf "    Short ID: ${GREEN}%s${PLAIN}\n" "$vless_short_id"
                        printf "    链接: ${GREEN}%s${PLAIN}\n" "$vless_link"
                        printf "    YAML:\n"
                        cat <<MIHOMO_VLESS_YAML
    proxies:
      - name: "${vless_name}"
        type: vless
        server: ${server_ip}
        port: ${port}
        udp: true
        uuid: "${vless_uuid}"
        flow: ${vless_flow_value}
        packet-encoding: xudp
        tls: true
        servername: ${sni}
        client-fingerprint: ${vless_fp_value}
        reality-opts:
          public-key: "${vless_public_key}"
          short-id: "${vless_short_id}"
MIHOMO_VLESS_YAML
                    fi
                done < <(_mihomoconf_read_users_by_tag "$config_file" "$listener_tag")
                if [[ "$vless_found" -eq 0 ]]; then
                    _warn "跳过 ${name}: 未配置可用 user"
                fi
                ;;
            vless-ws)
                if [[ -z "$port" ]]; then
                    _warn "跳过 ${name}: VLESS WS 字段不完整"
                    continue
                fi
                local vless_found=0 vless_link vless_name vless_user vless_uuid
                while IFS=$'\x1f' read -r vless_user vless_uuid; do
                    [[ -z "${vless_user:-}" || -z "${vless_uuid:-}" ]] && continue
                    vless_found=1
                    export_count=$((export_count + 1))
                    listener_export=$((listener_export + 1))
                    vless_name="$(_mihomoconf_make_node_name "VLESS-WS" "$NODE_FLAG" "$NODE_COUNTRY_CODE")-${vless_user}"
                    vless_link=$(_mihomoconf_gen_vless_ws_link "$server_ip" "$port" "$vless_uuid" "$vless_name" "$vless_ws_path" "$vless_ws_tls" "$vless_ws_host")
                    if [[ "$OUTPUT_LINK_ONLY" == "1" ]]; then
                        printf "%s\n" "$vless_link"
                    else
                        _separator
                        printf "  ${BOLD}[VLESS WS] %s${PLAIN}\n" "$vless_name"
                        printf "    入站tag: ${GREEN}%s${PLAIN}\n" "$listener_tag"
                        printf "    用户: ${GREEN}%s${PLAIN}\n" "$vless_user"
                        printf "    UUID: ${GREEN}%s${PLAIN}\n" "$vless_uuid"
                        printf "    WS Path: ${GREEN}%s${PLAIN}\n" "$vless_ws_path"
                        printf "    WS TLS : ${GREEN}%s${PLAIN}\n" "$vless_ws_tls"
                        [[ -n "$vless_ws_host" ]] && printf "    WS Host: ${GREEN}%s${PLAIN}\n" "$vless_ws_host"
                        printf "    链接: ${GREEN}%s${PLAIN}\n" "$vless_link"
                        printf "    YAML:\n"
                        cat <<MIHOMO_VLESS_WS_YAML
    proxies:
      - name: "${vless_name}"
        type: vless
        server: ${server_ip}
        port: ${port}
        uuid: "${vless_uuid}"
        udp: true
        tls: ${vless_ws_tls}
MIHOMO_VLESS_WS_YAML
                        if [[ "$vless_ws_tls" == "true" && -n "$vless_ws_host" ]]; then
                            echo "        servername: ${vless_ws_host}"
                        fi
                        cat <<MIHOMO_VLESS_WS_YAML2
        network: ws
        ws-opts:
          path: ${vless_ws_path}
MIHOMO_VLESS_WS_YAML2
                        if [[ -n "$vless_ws_host" ]]; then
                            cat <<MIHOMO_VLESS_WS_YAML3
          headers:
            Host: ${vless_ws_host}
MIHOMO_VLESS_WS_YAML3
                        fi
                    fi
                done < <(_mihomoconf_read_users_by_tag "$config_file" "$listener_tag")
                if [[ "$vless_found" -eq 0 ]]; then
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
                    hy2_link=$(_mihomoconf_gen_hy2_link "$server_ip" "$port" "$hy2_pass" "$hy2_name" "$sni" "${hy2_insecure:-0}" "$hy2_obfs" "$hy2_obfs_password" "$hy2_mport" "${hy2_congestion_control:-brutal}")
                    if [[ "$OUTPUT_LINK_ONLY" == "1" ]]; then
                        printf "%s\n" "$hy2_link"
                    else
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
      "obfs_password": "${hy2_obfs_password}",
      "congestion_control": "${hy2_congestion_control:-brutal}"
    }
MIHOMO_HY2_JSON
                    fi
                done < <(_mihomoconf_read_users_by_tag "$config_file" "$listener_tag")
                if [[ "$hy2_found" -eq 0 ]]; then
                    _warn "跳过 ${name}: 未配置可用 user"
                fi
                ;;
            tuic)
                if [[ -z "$port" ]]; then
                    _warn "跳过 ${name}: 节点字段不完整"
                    continue
                fi
                local tuic_found=0 tuic_link tuic_name tuic_user_uuid tuic_user_pass tuic_display_name
                local tuic_cc="${tuic_congestion_control:-bbr}"
                local tuic_alpn_val="${tuic_alpn:-h3}"
                local tuic_urm="${tuic_udp_relay_mode:-native}"
                local -a tuic_usernames
                local _tn
                while IFS= read -r _tn; do
                    [[ -n "${_tn:-}" ]] && tuic_usernames+=("$_tn")
                done < <(_mihomoconf_read_tuic_usernames_by_tag "$config_file" "$listener_tag")
                local _tuic_uidx=0
                while IFS=$'\x1f' read -r tuic_user_uuid tuic_user_pass; do
                    [[ -z "${tuic_user_uuid:-}" || -z "${tuic_user_pass:-}" ]] && continue
                    tuic_found=1
                    tuic_display_name="${tuic_usernames[$_tuic_uidx]:-${tuic_user_uuid:0:8}}"
                    _tuic_uidx=$((_tuic_uidx + 1))
                    export_count=$((export_count + 1))
                    listener_export=$((listener_export + 1))
                    tuic_name="$(_mihomoconf_make_node_name "Tuic" "$NODE_FLAG" "$NODE_COUNTRY_CODE")-${tuic_display_name}"
                    tuic_link=$(_mihomoconf_gen_tuic_link "$server_ip" "$port" "$tuic_user_uuid" "$tuic_user_pass" "$tuic_name" "$sni" "$tuic_cc" "$tuic_alpn_val" "$tuic_urm")
                    if [[ "$OUTPUT_LINK_ONLY" == "1" ]]; then
                        printf "%s\n" "$tuic_link"
                    else
                        _separator
                        printf "  ${BOLD}[Tuic] %s${PLAIN}\n" "$tuic_name"
                        printf "    入站tag: ${GREEN}%s${PLAIN}\n" "$listener_tag"
                        printf "    用户: ${GREEN}%s${PLAIN}\n" "$tuic_display_name"
                        printf "    UUID: ${GREEN}%s${PLAIN}\n" "$tuic_user_uuid"
                        printf "    链接: ${GREEN}%s${PLAIN}\n" "$tuic_link"
                        [[ -n "$sni" ]] && printf "    SNI: ${GREEN}%s${PLAIN}\n" "$sni"
                        printf "    拥塞控制: ${GREEN}%s${PLAIN}\n" "$tuic_cc"
                        printf "    ALPN: ${GREEN}%s${PLAIN}\n" "$tuic_alpn_val"
                        printf "    链接 JSON:\n"
                        cat <<MIHOMO_TUIC_JSON
    {
      "type": "tuic",
      "tag": "${tuic_name}",
      "server": "${server_ip}",
      "server_port": ${port},
      "uuid": "${tuic_user_uuid}",
      "password": "${tuic_user_pass}",
      "sni": "${sni}",
      "congestion_control": "${tuic_cc}",
      "alpn": "${tuic_alpn_val}",
      "udp_relay_mode": "${tuic_urm}"
    }
MIHOMO_TUIC_JSON
                    fi
                done < <(_mihomoconf_read_users_by_tag "$config_file" "$listener_tag")
                if [[ "$tuic_found" -eq 0 ]]; then
                    _warn "跳过 ${name}: 未配置可用 user"
                fi
                ;;
            socks)
                if [[ -z "$port" ]]; then
                    _warn "跳过 ${name}: 节点字段不完整"
                    continue
                fi
                local socks_found=0 socks_link socks_name socks_user socks_pass
                while IFS=$'\x1f' read -r socks_user socks_pass; do
                    [[ -z "${socks_user:-}" || -z "${socks_pass:-}" ]] && continue
                    socks_found=1
                    export_count=$((export_count + 1))
                    listener_export=$((listener_export + 1))
                    socks_name="$(_mihomoconf_make_node_name "Socks5" "$NODE_FLAG" "$NODE_COUNTRY_CODE")-${socks_user}"
                    socks_link=$(_mihomoconf_gen_socks_link "$server_ip" "$port" "$socks_user" "$socks_pass" "$socks_name")
                    if [[ "$OUTPUT_LINK_ONLY" == "1" ]]; then
                        printf "%s\n" "$socks_link"
                    else
                        _separator
                        printf "  ${BOLD}[Socks5] %s${PLAIN}\n" "$socks_name"
                        printf "    入站tag: ${GREEN}%s${PLAIN}\n" "$listener_tag"
                        printf "    用户: ${GREEN}%s${PLAIN}\n" "$socks_user"
                        printf "    链接: ${GREEN}%s${PLAIN}\n" "$socks_link"
                        printf "    YAML:\n"
                        cat <<MIHOMO_SOCKS_YAML
    proxies:
      - name: "${socks_name}"
        type: socks5
        server: ${server_ip}
        port: ${port}
        username: "${socks_user}"
        password: "${socks_pass}"
        udp: true
MIHOMO_SOCKS_YAML
                    fi
                done < <(_mihomoconf_read_users_by_tag "$config_file" "$listener_tag")
                if [[ "$socks_found" -eq 0 ]]; then
                    _warn "跳过 ${name}: 未配置可用 user"
                fi
                ;;
            *)
                _warn "跳过 ${name}: 暂不支持类型 ${type}"
                ;;
        esac
    done < <(_mihomoconf_read_listener_rows "$config_file")

    while IFS=$'\x1f' read -r p_name p_type p_server p_port p_cipher p_user p_pass p_sni p_insecure p_obfs p_obfs_password p_mport \
        p_wg_ip p_wg_ipv6 p_wg_private_key p_wg_public_key p_wg_allowed_ips p_wg_preshared_key p_wg_reserved p_wg_mtu p_wg_keepalive \
        p_vless_uuid p_vless_flow p_vless_public_key p_vless_short_id p_vless_client_fingerprint p_vless_packet_encoding; do
        [[ -z "${p_name:-}" ]] && continue
        proxy_total=$((proxy_total + 1))
        total_count=$((total_count + 1))
        case "$p_type" in
            ss)
                if [[ -z "$p_server" || -z "$p_port" || -z "$p_cipher" || -z "$p_pass" ]]; then
                    _warn "跳过 ${p_name}: ss 出站字段不完整(server/port/cipher/password)"
                    continue
                fi
                local ss_proxy_udp ss_proxy_uot ss_proxy_link ss_proxy_udp_bool ss_proxy_uot_bool
                IFS=$'\x1f' read -r ss_proxy_udp ss_proxy_uot < <(_mihomochain_ss_proxy_udp_uot_by_name "$config_file" "$p_name")
                [[ "$ss_proxy_udp" == "1" ]] && ss_proxy_udp_bool="true" || ss_proxy_udp_bool="false"
                [[ "$ss_proxy_uot" == "1" ]] && ss_proxy_uot_bool="true" || ss_proxy_uot_bool="false"
                ss_proxy_link=$(_mihomoconf_gen_ss_link "$p_server" "$p_port" "$p_cipher" "$p_pass" "$p_name" "$ss_proxy_udp" "$ss_proxy_uot")
                proxy_export=$((proxy_export + 1))
                export_count=$((export_count + 1))
                if [[ "$OUTPUT_LINK_ONLY" == "1" ]]; then
                    printf "%s\n" "$ss_proxy_link"
                else
                    _separator
                    printf "  ${BOLD}[SS 出站] %s${PLAIN}\n" "$p_name"
                    printf "    地址: ${GREEN}%s:%s${PLAIN}\n" "$p_server" "$p_port"
                    printf "    加密: ${GREEN}%s${PLAIN}\n" "$p_cipher"
                    printf "    链接: ${GREEN}%s${PLAIN}\n" "$ss_proxy_link"
                    printf "    YAML:\n"
                    cat <<MIHOMO_SS_PROXY_YAML
    proxies:
      - name: "${p_name}"
        type: ss
        server: "${p_server}"
        port: ${p_port}
        cipher: ${p_cipher}
        password: "${p_pass}"
        udp: ${ss_proxy_udp_bool}
MIHOMO_SS_PROXY_YAML
                    if [[ "$ss_proxy_uot" == "1" ]]; then
                        cat <<MIHOMO_SS_PROXY_UOT_YAML
        udp-over-tcp: ${ss_proxy_uot_bool}
        udp-over-tcp-version: 2
MIHOMO_SS_PROXY_UOT_YAML
                    fi
                fi
                ;;
            wireguard|wg)
                if [[ -z "$p_server" || -z "$p_port" || -z "$p_wg_ip" || -z "$p_wg_private_key" || -z "$p_wg_public_key" ]]; then
                    _warn "跳过 ${p_name}: wireguard(Beta) 字段不完整(server/port/ip/private-key/public-key)"
                    continue
                fi
                [[ "$OUTPUT_LINK_ONLY" == "1" ]] && continue
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

    if [[ "$OUTPUT_LINK_ONLY" != "1" ]]; then
        _separator
        if [[ "$total_count" -eq 0 ]]; then
            _warn "未在配置中检测到可读节点 (listeners/proxies)"
        elif [[ "$export_count" -eq 0 ]]; then
            _warn "共读取 ${total_count} 个节点，但没有可导出的 Shadowsocks/AnyTLS/VLESS/HY2/SS出站/WireGuard(Beta) 节点"
        else
            _info "listeners: 读取 ${listener_total}，导出 ${listener_export}"
            _info "proxies: 读取 ${proxy_total}，导出 ${proxy_export} (SS / WireGuard Beta)"
            _info "总计: 读取 ${total_count}，导出 ${export_count}"
        fi
    fi

    _press_any_key
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
    if [[ -z "$raw" ]]; then
        printf '["0.0.0.0/0","::/0"]'
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
            vless_uuid=vless_flow=vless_public_key=vless_short_id=vless_client_fingerprint=vless_packet_encoding=""
            in_reality=0
            reality_indent=-1
        }
        function emit() {
            if (name == "") return
            if (insecure == "") insecure="0"
            printf "%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\n", \
                name, type, server, port, cipher, username, password, sni, insecure, obfs, obfs_password, mport, \
                wg_ip, wg_ipv6, wg_private_key, wg_public_key, wg_allowed_ips, wg_preshared_key, wg_reserved, wg_mtu, wg_keepalive, \
                vless_uuid, vless_flow, vless_public_key, vless_short_id, vless_client_fingerprint, vless_packet_encoding
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
        /^    uuid:/ {
            line=$0
            sub(/^    uuid:[[:space:]]*/, "", line)
            vless_uuid=unquote(trim(line))
            next
        }
        /^    flow:/ {
            line=$0
            sub(/^    flow:[[:space:]]*/, "", line)
            vless_flow=unquote(trim(line))
            next
        }
        /^    packet-encoding:/ {
            line=$0
            sub(/^    packet-encoding:[[:space:]]*/, "", line)
            vless_packet_encoding=unquote(trim(line))
            next
        }
        /^    client-fingerprint:/ {
            line=$0
            sub(/^    client-fingerprint:[[:space:]]*/, "", line)
            vless_client_fingerprint=unquote(trim(line))
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
        /^    reality-opts:[[:space:]]*$/ {
            in_reality=1
            reality_indent=4
            next
        }
        in_reality && /^    [^ ]/ {
            in_reality=0
        }
        in_reality && /^      public-key:/ {
            line=$0
            sub(/^      public-key:[[:space:]]*/, "", line)
            vless_public_key=unquote(trim(line))
            next
        }
        in_reality && /^      short-id:/ {
            line=$0
            sub(/^      short-id:[[:space:]]*/, "", line)
            vless_short_id=unquote(trim(line))
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
    local vless_uuid vless_flow vless_public_key vless_short_id vless_client_fingerprint vless_packet_encoding
    while IFS=$'\x1f' read -r name type server port cipher username password sni insecure obfs obfs_password mport \
        wg_ip wg_ipv6 wg_private_key wg_public_key wg_allowed_ips wg_preshared_key wg_reserved wg_mtu wg_keepalive \
        vless_uuid vless_flow vless_public_key vless_short_id vless_client_fingerprint vless_packet_encoding; do
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
    local vless_uuid vless_flow vless_public_key vless_short_id vless_client_fingerprint vless_packet_encoding
    while IFS=$'\x1f' read -r name type server port cipher username password sni insecure obfs obfs_password mport \
        wg_ip wg_ipv6 wg_private_key wg_public_key wg_allowed_ips wg_preshared_key wg_reserved wg_mtu wg_keepalive \
        vless_uuid vless_flow vless_public_key vless_short_id vless_client_fingerprint vless_packet_encoding; do
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
    local vless_uuid vless_flow vless_public_key vless_short_id vless_client_fingerprint vless_packet_encoding
    while IFS=$'\x1f' read -r n type server port cipher username password sni insecure obfs obfs_password mport \
        wg_ip wg_ipv6 wg_private_key wg_public_key wg_allowed_ips wg_preshared_key wg_reserved wg_mtu wg_keepalive \
        vless_uuid vless_flow vless_public_key vless_short_id vless_client_fingerprint vless_packet_encoding; do
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
    local vless_public_key vless_short_id vless_flow vless_client_fingerprint
    local vless_type vless_ws_path vless_ws_tls vless_ws_host vless_grpc_service_name
    while IFS=$'\x1f' read -r type name port cipher password user_id user_pass sni \
        hy2_up hy2_down hy2_ignore hy2_obfs hy2_obfs_password hy2_masquerade hy2_mport hy2_insecure listener_tag \
        vless_public_key vless_short_id vless_flow vless_client_fingerprint \
        tuic_congestion_control tuic_alpn tuic_udp_relay_mode hy2_congestion_control \
        vless_type vless_ws_path vless_ws_tls vless_ws_host vless_grpc_service_name; do
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
    local vless_public_key vless_short_id vless_flow vless_client_fingerprint
    local vless_type vless_ws_path vless_ws_tls vless_ws_host vless_grpc_service_name
    while IFS=$'\x1f' read -r type name port cipher password user_id user_pass sni \
        hy2_up hy2_down hy2_ignore hy2_obfs hy2_obfs_password hy2_masquerade hy2_mport hy2_insecure listener_tag \
        vless_public_key vless_short_id vless_flow vless_client_fingerprint \
        tuic_congestion_control tuic_alpn tuic_udp_relay_mode hy2_congestion_control \
        vless_type vless_ws_path vless_ws_tls vless_ws_host vless_grpc_service_name; do
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
    local vless_uuid vless_flow vless_public_key vless_short_id vless_client_fingerprint vless_packet_encoding
    while IFS=$'\x1f' read -r name type server port cipher username password sni insecure obfs obfs_password mport \
        wg_ip wg_ipv6 wg_private_key wg_public_key wg_allowed_ips wg_preshared_key wg_reserved wg_mtu wg_keepalive \
        vless_uuid vless_flow vless_public_key vless_short_id vless_client_fingerprint vless_packet_encoding; do
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
            vless)
                local vless_extra=""
                [[ -n "${sni:-}" ]] && vless_extra="${vless_extra}, sni=${sni}"
                [[ -n "${vless_flow:-}" ]] && vless_extra="${vless_extra}, flow=${vless_flow}"
                [[ -n "${vless_short_id:-}" ]] && vless_extra="${vless_extra}, sid=${vless_short_id}"
                printf "      %s (type=vless, %s:%s%s)\n" "$show_name" "$server" "$port" "$vless_extra"
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
            tuic)
                local tuic_extra=""
                [[ -n "${sni:-}" ]] && tuic_extra="${tuic_extra}, sni=${sni}"
                [[ -n "${vless_uuid:-}" ]] && tuic_extra="${tuic_extra}, uuid=${vless_uuid:0:8}..."
                printf "      %s (type=tuic, %s:%s%s)\n" "$show_name" "$server" "$port" "$tuic_extra"
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
    local vless_public_key vless_short_id vless_flow vless_client_fingerprint
    local vless_type vless_ws_path vless_ws_tls vless_ws_host vless_grpc_service_name
    local u_name u_pass u_count
    while IFS=$'\x1f' read -r type name port cipher password user_id user_pass sni \
        hy2_up hy2_down hy2_ignore hy2_obfs hy2_obfs_password hy2_masquerade hy2_mport hy2_insecure listener_tag \
        vless_public_key vless_short_id vless_flow vless_client_fingerprint \
        tuic_congestion_control tuic_alpn tuic_udp_relay_mode hy2_congestion_control \
        vless_type vless_ws_path vless_ws_tls vless_ws_host vless_grpc_service_name; do
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

_mihomochain_normalize_query_key() {
    local key="${1:-}"
    key=$(_mihomochain_urldecode "$key")
    key=$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')
    key="${key//_/-}"
    case "$key" in
        udpovertcp|udp-over-tcp-enable|udp-over-tcp-enabled) printf 'udp-over-tcp' ;;
        udpovertcpversion|udp-over-tcp-ver) printf 'udp-over-tcp-version' ;;
        uotversion|uot-version) printf 'uot-version' ;;
        *) printf '%s' "$key" ;;
    esac
}

_mihomochain_query_value_enabled() {
    local val="${1:-}" lower
    lower=$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')
    case "$lower" in
        ""|1|2|true|yes|on|enable|enabled) return 0 ;;
        *) return 1 ;;
    esac
}

_mihomochain_query_value_disabled() {
    local val="${1:-}" lower
    lower=$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')
    case "$lower" in
        0|false|no|off|disable|disabled) return 0 ;;
        *) return 1 ;;
    esac
}

_mihomochain_apply_ss_query_param() {
    local raw_key="$1" raw_val="$2" _udp_var="$3" _uot_var="$4"
    local key val

    key=$(_mihomochain_normalize_query_key "$raw_key")
    val=$(_mihomochain_urldecode "$raw_val")
    case "$key" in
        plugin)
            return 2
            ;;
        udp)
            if _mihomochain_query_value_disabled "$val"; then
                printf -v "$_udp_var" '%s' "0"
                printf -v "$_uot_var" '%s' "0"
            elif _mihomochain_query_value_enabled "$val"; then
                printf -v "$_udp_var" '%s' "1"
            fi
            ;;
        uot|uot-version|udp-over-tcp|udp-over-tcp-version)
            if _mihomochain_query_value_disabled "$val"; then
                printf -v "$_uot_var" '%s' "0"
            elif _mihomochain_query_value_enabled "$val"; then
                printf -v "$_uot_var" '%s' "1"
            fi
            ;;
    esac
    return 0
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

_mihomochain_parse_host_port() {
    local input="${1:-}" _host_var="$2" _port_var="$3"
    local host port rest

    if [[ "$input" == \[*\]:* ]]; then
        host="${input#\[}"
        host="${host%%\]*}"
        rest="${input#*\]}"
        rest="${rest#:}"
        port="$rest"
    else
        host="${input%:*}"
        port="${input##*:}"
    fi

    [[ -n "$host" && "$host" != "$input" ]] || return 1
    _is_valid_port "$port" || return 1
    printf -v "$_host_var" '%s' "$host"
    printf -v "$_port_var" '%s' "$port"
    return 0
}

_mihomochain_default_outbound_name() {
    local out_type="${1:-outbound}" out_server="${2:-server}" out_port="${3:-0}"
    case "$out_type" in
        hysteria2) out_type="hy2" ;;
    esac
    printf '%s-%s-%s' "$out_type" "$out_server" "$out_port"
}

_mihomochain_ss_proxy_udp_uot_by_name() {
    local config_file="${1:-$_MIHOMOCONF_CONFIG_FILE}" target_name="$2"
    awk -v target="$target_name" '
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
        function enabled(s) {
            s=tolower(trim(unquote(s)))
            return (s == "true" || s == "1" || s == "yes" || s == "on")
        }
        function version_enabled(s) {
            s=tolower(trim(unquote(s)))
            return (s == "1" || s == "2")
        }
        function reset_item() {
            name=type=""
            udp="true"
            uot="false"
            uot_version=""
        }
        function emit() {
            if (name == target && type == "ss") {
                printf "%s\037%s\n", enabled(udp) ? "1" : "0", (enabled(uot) || version_enabled(uot_version)) ? "1" : "0"
                found=1
            }
        }
        BEGIN {
            in_proxies=0
            found=0
            reset_item()
        }
        /^[^[:space:]#][^:]*:[[:space:]]*.*$/ {
            if (in_proxies) emit()
            in_proxies = ($0 ~ /^proxies:[[:space:]]*$/)
            reset_item()
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
            type=unquote(trim(line))
            next
        }
        /^    udp:/ {
            line=$0
            sub(/^    udp:[[:space:]]*/, "", line)
            udp=line
            next
        }
        /^    udp-over-tcp:/ {
            line=$0
            sub(/^    udp-over-tcp:[[:space:]]*/, "", line)
            uot=line
            next
        }
        /^    udp-over-tcp-version:/ {
            line=$0
            sub(/^    udp-over-tcp-version:[[:space:]]*/, "", line)
            uot_version=trim(line)
            next
        }
        END {
            if (in_proxies) emit()
            if (!found) print "1\0370"
        }
    ' "$config_file"
}

_mihomochain_add_or_update_outbound() {
    local tag="$1" type="$2" server="$3" port="$4" cipher="$5" username="$6" password="$7"
    local sni="${8:-}" insecure="${9:-0}" obfs="${10:-}" obfs_password="${11:-}" mport="${12:-}" out_name="${13:-}"
    local wg_ip="${14:-}" wg_ipv6="${15:-}" wg_private_key="${16:-}" wg_public_key="${17:-}"
    local wg_allowed_ips="${18:-}" wg_preshared_key="${19:-}" wg_reserved="${20:-}" wg_mtu="${21:-}" wg_keepalive="${22:-}"
    local vless_uuid="${23:-}" vless_flow="${24:-xtls-rprx-vision}" vless_public_key="${25:-}"
    local vless_short_id="${26:-}" vless_client_fingerprint="${27:-chrome}" vless_packet_encoding="${28:-xudp}"
    local hy2_congestion_control="${29:-brutal}" ss_udp="${30:-1}" ss_uot="${31:-0}"
    local config_file="$_MIHOMOCONF_CONFIG_FILE"
    local name q_name q_server q_cipher q_user q_pass q_sni q_obfs q_obfs_password q_mport q_hy2_congestion_control
    local q_wg_ip q_wg_ipv6 q_wg_private_key q_wg_public_key q_wg_allowed_ips q_wg_preshared_key q_wg_reserved
    local q_vless_uuid q_vless_flow q_vless_public_key q_vless_short_id q_vless_client_fingerprint q_vless_packet_encoding
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
    q_hy2_congestion_control=$(_mihomochain_yaml_quote "$hy2_congestion_control")
    q_wg_ip=$(_mihomochain_yaml_quote "$wg_ip")
    q_wg_ipv6=$(_mihomochain_yaml_quote "$wg_ipv6")
    q_wg_private_key=$(_mihomochain_yaml_quote "$wg_private_key")
    q_wg_public_key=$(_mihomochain_yaml_quote "$wg_public_key")
    q_wg_allowed_ips=$(_mihomochain_yaml_list_from_csv "$wg_allowed_ips")
    q_wg_preshared_key=$(_mihomochain_yaml_quote "$wg_preshared_key")
    q_wg_reserved=$(_mihomochain_yaml_quote "$wg_reserved")
    q_vless_uuid=$(_mihomochain_yaml_quote "$vless_uuid")
    q_vless_flow=$(_mihomochain_yaml_quote "$vless_flow")
    q_vless_public_key=$(_mihomochain_yaml_quote "$vless_public_key")
    q_vless_short_id=$(_mihomochain_yaml_quote "$vless_short_id")
    q_vless_client_fingerprint=$(_mihomochain_yaml_quote "$vless_client_fingerprint")
    q_vless_packet_encoding=$(_mihomochain_yaml_quote "$vless_packet_encoding")

    tmp_block=$(mktemp)
    case "$type" in
        ss)
            local ss_udp_bool="true" ss_uot_bool="false"
            case "$(printf '%s' "$ss_udp" | tr '[:upper:]' '[:lower:]')" in
                0|false|no|off) ss_udp_bool="false"; ss_uot="0" ;;
            esac
            case "$(printf '%s' "$ss_uot" | tr '[:upper:]' '[:lower:]')" in
                1|true|yes|on|2) ss_uot_bool="true" ;;
            esac
            cat > "$tmp_block" <<EOF
  - name: "${q_name}"
    type: ss
    server: "${q_server}"
    port: ${port}
    cipher: ${q_cipher}
    password: "${q_pass}"
    udp: ${ss_udp_bool}
EOF
            if [[ "$ss_uot_bool" == "true" ]]; then
                cat >> "$tmp_block" <<'EOF'
    udp-over-tcp: true
    udp-over-tcp-version: 2
EOF
            fi
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
            if [[ -n "$q_hy2_congestion_control" ]]; then
                printf '    congestion-controller: "%s"\n' "$q_hy2_congestion_control" >> "$tmp_block"
            fi
            ;;
        vless)
            if [[ -z "$vless_uuid" ]]; then
                rm -f "$tmp_block"
                return 1
            fi
            cat > "$tmp_block" <<EOF
  - name: "${q_name}"
    type: vless
    server: "${q_server}"
    port: ${port}
    uuid: "${q_vless_uuid}"
    udp: true
    tls: true
EOF
            if [[ -n "$q_sni" ]]; then
                printf '    servername: "%s"\n' "$q_sni" >> "$tmp_block"
            fi
            if [[ -n "$q_vless_flow" ]]; then
                printf '    flow: "%s"\n' "$q_vless_flow" >> "$tmp_block"
            fi
            if [[ -n "$q_vless_packet_encoding" ]]; then
                printf '    packet-encoding: "%s"\n' "$q_vless_packet_encoding" >> "$tmp_block"
            fi
            if [[ -n "$q_vless_client_fingerprint" ]]; then
                printf '    client-fingerprint: "%s"\n' "$q_vless_client_fingerprint" >> "$tmp_block"
            fi
            if [[ "$insecure" == "1" ]]; then
                echo "    skip-cert-verify: true" >> "$tmp_block"
            fi
            if [[ -n "$q_vless_public_key" || -n "$q_vless_short_id" ]]; then
                echo "    reality-opts:" >> "$tmp_block"
                if [[ -n "$q_vless_public_key" ]]; then
                    printf '      public-key: "%s"\n' "$q_vless_public_key" >> "$tmp_block"
                fi
                if [[ -n "$q_vless_short_id" ]]; then
                    printf '      short-id: "%s"\n' "$q_vless_short_id" >> "$tmp_block"
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
        tuic)
            if [[ -z "$vless_uuid" ]]; then
                rm -f "$tmp_block"
                return 1
            fi
            cat > "$tmp_block" <<EOF
  - name: "${q_name}"
    type: tuic
    server: "${q_server}"
    port: ${port}
    uuid: "${q_vless_uuid}"
    password: "${q_pass}"
    udp: true
EOF
            if [[ -n "$q_sni" ]]; then
                printf '    sni: "%s"\n' "$q_sni" >> "$tmp_block"
            fi
            if [[ "$insecure" == "1" ]]; then
                echo "    skip-cert-verify: true" >> "$tmp_block"
            fi
            if [[ -n "$q_vless_flow" ]]; then
                printf '    congestion-controller: "%s"\n' "$q_vless_flow" >> "$tmp_block"
            else
                echo '    congestion-controller: bbr' >> "$tmp_block"
            fi
            if [[ -n "$q_vless_client_fingerprint" ]]; then
                echo "    alpn:" >> "$tmp_block"
                printf '      - %s\n' "$q_vless_client_fingerprint" >> "$tmp_block"
            else
                cat >> "$tmp_block" <<'EOF'
    alpn:
      - h3
EOF
            fi
            if [[ -n "$q_vless_packet_encoding" ]]; then
                printf '    udp-relay-mode: "%s"\n' "$q_vless_packet_encoding" >> "$tmp_block"
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
        _mihomochain_add_or_update_rule "$resolved_tag" "$out_tag"
        return $?
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
                    if [[ -n "$listener_name" ]]; then
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

_mihomorule_read_providers() {
    local config_file="${1:-$_MIHOMOCONF_CONFIG_FILE}"
    [[ -f "$config_file" ]] || return 1
    awk '
        function trim(s) {
            sub(/^[[:space:]]+/, "", s)
            sub(/[[:space:]]+$/, "", s)
            return s
        }
        BEGIN { in_providers=0 }
        /^[^[:space:]#][^:]*:[[:space:]]*.*$/ {
            in_providers = ($0 ~ /^rule-providers:[[:space:]]*$/)
            next
        }
        !in_providers { next }
        /^  [^[:space:]#][^:]*:[[:space:]]*$/ {
            line=$0
            sub(/^  /, "", line)
            sub(/:[[:space:]]*$/, "", line)
            print trim(line)
        }
    ' "$config_file"
}

_mihomorule_safe_provider_name() {
    local raw="${1:-}" safe
    safe=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9._-' '_')
    safe="${safe##_}"
    safe="${safe%%_}"
    [[ -n "$safe" ]] || safe="custom"
    [[ "$safe" == vpsgo_* ]] || safe="vpsgo_${safe}"
    printf '%s' "$safe"
}

_mihomorule_provider_block_upsert() {
    local config_file="$1" provider_name="$2" block_file="$3"
    local tmp
    tmp=$(mktemp)
    awk -v target="$provider_name" -v blockf="$block_file" '
        function trim(s) {
            sub(/^[[:space:]]+/, "", s)
            sub(/[[:space:]]+$/, "", s)
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
            in_providers=0
            in_item=0
            has_providers=0
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
            if (in_providers) {
                flush_item()
                if (!replaced) {
                    printf "%s", new_block
                    replaced=1
                }
            }
            in_providers = ($0 ~ /^rule-providers:[[:space:]]*$/)
            if (in_providers) has_providers=1
            print
            next
        }
        !in_providers {
            print
            next
        }
        /^  [^[:space:]#][^:]*:[[:space:]]*$/ {
            flush_item()
            in_item=1
            item_buf=$0 "\n"
            line=$0
            sub(/^  /, "", line)
            sub(/:[[:space:]]*$/, "", line)
            item_name=trim(line)
            next
        }
        in_item {
            item_buf=item_buf $0 "\n"
            next
        }
        { print }
        END {
            if (in_providers) {
                flush_item()
                if (!replaced) {
                    printf "%s", new_block
                    replaced=1
                }
            }
            if (!has_providers) {
                print ""
                print "rule-providers:"
                printf "%s", new_block
            }
        }
    ' "$config_file" > "$tmp"
    mv "$tmp" "$config_file"
}

_mihomorule_provider_remove() {
    local config_file="$1" provider_name="$2"
    local tmp
    tmp=$(mktemp)
    awk -v target="$provider_name" '
        function trim(s) {
            sub(/^[[:space:]]+/, "", s)
            sub(/[[:space:]]+$/, "", s)
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
            in_providers=0
            in_item=0
            item_buf=""
            item_name=""
        }
        /^[^[:space:]#][^:]*:[[:space:]]*.*$/ {
            if (in_providers) flush_item()
            in_providers = ($0 ~ /^rule-providers:[[:space:]]*$/)
            print
            next
        }
        !in_providers {
            print
            next
        }
        /^  [^[:space:]#][^:]*:[[:space:]]*$/ {
            flush_item()
            in_item=1
            item_buf=$0 "\n"
            line=$0
            sub(/^  /, "", line)
            sub(/:[[:space:]]*$/, "", line)
            item_name=trim(line)
            next
        }
        in_item {
            item_buf=item_buf $0 "\n"
            next
        }
        { print }
        END {
            if (in_providers) flush_item()
        }
    ' "$config_file" > "$tmp"
    mv "$tmp" "$config_file"
}

_mihomorule_upsert_remote_provider() {
    local config_file="$1" provider_name="$2" url="$3" behavior="$4" format="$5" interval="${6:-86400}" path="${7:-}"
    local q_url q_path tmp_block suffix proxied_url
   
    [[ "$behavior" == "domain" || "$behavior" == "ipcidr" || "$behavior" == "classical" ]] || return 1
    [[ "$format" == "yaml" || "$format" == "text" || "$format" == "mrs" ]] || return 1
    if [[ "$format" == "mrs" && "$behavior" == "classical" ]]; then
        _error_no_exit "mrs 规则集仅支持 behavior=domain/ipcidr，不支持 classical"
        return 1
    fi
    _is_digit "$interval" || interval="86400"
    if [[ -z "$path" ]]; then
        suffix="$format"
        path="./ruleset/${provider_name}.${suffix}"
    fi

    proxied_url=$(_github_proxy_url "$url")
    q_url=$(_mihomochain_yaml_quote "$proxied_url")
    q_path=$(_mihomochain_yaml_quote "$path")
    tmp_block=$(mktemp)
    cat > "$tmp_block" <<EOF
  ${provider_name}:
    type: http
    behavior: ${behavior}
    format: ${format}
    url: "${q_url}"
    path: "${q_path}"
    interval: ${interval}
EOF
    _mihomorule_provider_block_upsert "$config_file" "$provider_name" "$tmp_block"
    rm -f "$tmp_block"
}

_mihomorule_add_policy_rule() {
    local config_file="$1" prefix="$2" value="$3" out_name="$4" position="${5:-bottom}"
    local tmp_other tmp_user tmp_name tmp_new tmp_ordered new_rule pattern

    if [[ "$prefix" == "DNS-PRE" ]]; then
        local u_part="${value%%|*}"
        local r_part="${value##*|}"
        new_rule="AND,((IN-USER,${u_part}),(RULE-SET,${r_part}),(OR,((IP-CIDR,0.0.0.0/0),(IP-CIDR6,::/0)))),${out_name}"
        pattern="AND,((IN-USER,${u_part}),(RULE-SET,${r_part}),(OR,((IP-CIDR,0.0.0.0/0),(IP-CIDR6,::/0)))),"
    elif [[ "$prefix" == "DNS-PRE-ALL" ]]; then
        new_rule="AND,((IN-USER,${value}),(OR,((IP-CIDR,0.0.0.0/0),(IP-CIDR6,::/0)))),${out_name}"
        pattern="AND,((IN-USER,${value}),(OR,((IP-CIDR,0.0.0.0/0),(IP-CIDR6,::/0)))),"
    else
        new_rule="${prefix},${value},${out_name}"
        pattern="${prefix},${value},"
    fi

    tmp_other=$(mktemp)
    tmp_user=$(mktemp)
    tmp_name=$(mktemp)
    tmp_new=$(mktemp)
    _mihomochain_rule_split_parts "$config_file" "$tmp_other" "$tmp_user" "$tmp_name"
    awk -v p="$pattern" 'index($0, p) != 1 { print }' "$tmp_other" > "$tmp_new"
    if [[ "$position" =~ ^[0-9]+$ ]]; then
        tmp_ordered=$(mktemp)
        awk -v idx="$position" -v nr="$new_rule" '
            NR == idx + 1 { print nr }
            { print }
            END { if (idx >= NR) print nr }
        ' "$tmp_new" > "$tmp_ordered"
        mv "$tmp_ordered" "$tmp_new"
    elif [[ "$position" == "top" ]]; then
        tmp_ordered=$(mktemp)
        printf '%s\n' "$new_rule" > "$tmp_ordered"
        cat "$tmp_new" >> "$tmp_ordered"
        mv "$tmp_ordered" "$tmp_new"
    else
        printf '%s\n' "$new_rule" >> "$tmp_new"
    fi
    mv "$tmp_new" "$tmp_other"
    _mihomochain_rule_write_parts "$config_file" "$tmp_other" "$tmp_user" "$tmp_name"
    rm -f "$tmp_other" "$tmp_user" "$tmp_name"
}

_mihomorule_remove_policy_rule() {
    local config_file="$1" prefix="$2" value="$3"
    local tmp_other tmp_user tmp_name tmp_new
    local pattern

    if [[ "$prefix" == "DNS-PRE" ]]; then
        local u_part="${value%%|*}"
        local r_part="${value##*|}"
        pattern="AND,((IN-USER,${u_part}),(RULE-SET,${r_part}),(OR,((IP-CIDR,0.0.0.0/0),(IP-CIDR6,::/0)))),"
    elif [[ "$prefix" == "DNS-PRE-ALL" ]]; then
        pattern="AND,((IN-USER,${value}),(OR,((IP-CIDR,0.0.0.0/0),(IP-CIDR6,::/0)))),"
    else
        pattern="${prefix},${value},"
    fi

    tmp_other=$(mktemp)
    tmp_user=$(mktemp)
    tmp_name=$(mktemp)
    tmp_new=$(mktemp)
    _mihomochain_rule_split_parts "$config_file" "$tmp_other" "$tmp_user" "$tmp_name"
    awk -v p="$pattern" 'index($0, p) != 1 { print }' "$tmp_other" > "$tmp_new"
    mv "$tmp_new" "$tmp_other"
    _mihomochain_rule_write_parts "$config_file" "$tmp_other" "$tmp_user" "$tmp_name"
    rm -f "$tmp_other" "$tmp_user" "$tmp_name"
}

_mihomorule_read_policy_rules() {
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
            if (line == "") next
            if (line ~ /^RULE-SET,[^,]+,[^,]+$/) {
                split(line, a, ",")
                printf "RULE-SET\037%s\037%s\n", a[2], a[3]
            } else if (line ~ /^DST-PORT,[^,]+,[^,]+$/) {
                split(line, a, ",")
                printf "DST-PORT\037%s\037%s\n", a[2], a[3]
            } else if (line ~ /^AND,\(\(IN-USER,[^,]+\),\(RULE-SET,[^,]+\),\(OR,\(\(IP-CIDR,0\.0\.0\.0\/0\),\(IP-CIDR6,::\/0\)\)\)\),[^,]+$/) {
                match(line, /IN-USER,[^)]+/)
                user = substr(line, RSTART + 8, RLENGTH - 8)
                match(line, /RULE-SET,[^)]+/)
                ruleset = substr(line, RSTART + 9, RLENGTH - 9)
                idx = index(line, "))))")
                out = substr(line, idx + 5)
                printf "DNS-PRE\037%s|%s\037%s\n", user, ruleset, out
            } else if (line ~ /^AND,\(\(IN-USER,[^,]+\),\(OR,\(\(IP-CIDR,0\.0\.0\.0\/0\),\(IP-CIDR6,::\/0\)\)\)\),[^,]+$/) {
                match(line, /IN-USER,[^)]+/)
                user = substr(line, RSTART + 8, RLENGTH - 8)
                idx = index(line, "))))")
                out = substr(line, idx + 5)
                printf "DNS-PRE-ALL\037%s\037%s\n", user, out
            }
        }
    ' "$config_file"
}

_mihomorule_list_policy_rules() {
    local config_file="${1:-$_MIHOMOCONF_CONFIG_FILE}"
    local shown=0 idx=0 kind value out_name out_show
    while IFS=$'\x1f' read -r kind value out_name; do
        [[ -z "${kind:-}" ]] && continue
        shown=1
        idx=$((idx + 1))
        out_show=$(_mihomochain_display_name "$out_name")
        case "$kind" in
            RULE-SET) printf "      [%d] 远程规则 %-28s ${DIM}-->${PLAIN} %s\n" "$idx" "$value" "$out_show" ;;
            DST-PORT) printf "      [%d] 目标端口 %-28s ${DIM}-->${PLAIN} %s\n" "$idx" "$value" "$out_show" ;;
            DNS-PRE)
                local u_part="${value%%|*}"
                local r_part="${value##*|}"
                printf "      [%d] 本地解析直发 用户 [ %s ] 规则集 [ %s ] ${DIM}-->${PLAIN} %s\n" "$idx" "$u_part" "$r_part" "$out_show"
                ;;
            DNS-PRE-ALL)
                printf "      [%d] 本地解析直发 用户 [ %s ] 全部流量 ${DIM}-->${PLAIN} %s\n" "$idx" "$value" "$out_show"
                ;;
        esac
    done < <(_mihomorule_read_policy_rules "$config_file")
    if [[ "$shown" -eq 0 ]]; then
        _warn "暂无服务/端口分流规则"
        return 1
    fi
    return 0
}

_mihomorule_pick_outbound() {
    local config_file="$1" _name_var="$2" _show_var="$3"
    local idx=0 pick oi row_out_name row_out_show type server port cipher username password sni insecure obfs obfs_password mport
    local wg_ip wg_ipv6 wg_private_key wg_public_key wg_allowed_ips wg_preshared_key wg_reserved wg_mtu wg_keepalive
    local vless_uuid vless_flow vless_public_key vless_short_id vless_client_fingerprint vless_packet_encoding
    local -a outbound_names=() outbound_show_names=()

    printf "  ${BOLD}可用出口节点:${PLAIN}\n"
    _separator
    while IFS=$'\x1f' read -r row_out_name type server port cipher username password sni insecure obfs obfs_password mport \
        wg_ip wg_ipv6 wg_private_key wg_public_key wg_allowed_ips wg_preshared_key wg_reserved wg_mtu wg_keepalive \
        vless_uuid vless_flow vless_public_key vless_short_id vless_client_fingerprint vless_packet_encoding; do
        [[ -z "${row_out_name:-}" ]] && continue
        [[ "$row_out_name" == "$_MIHOMOCONF_IPV4_FORCE_PROXY_NAME" ]] && continue
        [[ "$row_out_name" == "vpsgo-ipv4-direct" ]] && continue
        [[ "$row_out_name" == "vpsgo-ipv6-direct" ]] && continue
        row_out_show=$(_mihomochain_display_name "$row_out_name")
        outbound_names+=("$row_out_name")
        outbound_show_names+=("$row_out_show")
        idx=$((idx + 1))
        printf "      [%d] %s (type=%s, %s:%s)\n" "$idx" "$row_out_show" "$type" "$server" "$port"
    done < <(_mihomochain_read_proxy_rows "$config_file")

    # 添加内置/虚拟直连出口
    idx=$((idx + 1))
    outbound_names+=("DIRECT")
    outbound_show_names+=("DIRECT (默认直连)")
    printf "      [%d] DIRECT (默认直连)\n" "$idx"

    idx=$((idx + 1))
    outbound_names+=("vpsgo-ipv4-direct")
    outbound_show_names+=("vpsgo-ipv4-direct (直连 - 强制 IPv4)")
    printf "      [%d] vpsgo-ipv4-direct (直连 - 强制 IPv4)\n" "$idx"

    idx=$((idx + 1))
    outbound_names+=("vpsgo-ipv6-direct")
    outbound_show_names+=("vpsgo-ipv6-direct (直连 - 强制 IPv6)")
    printf "      [%d] vpsgo-ipv6-direct (直连 - 强制 IPv6)\n" "$idx"

    _separator
    read -rp "  选择出口节点 [序号]: " pick
    pick=$(_mihomoconf_trim "${pick:-}")
    if [[ -z "$pick" || ! "$pick" =~ ^[0-9]+$ ]]; then
        _error_no_exit "请输入有效序号"
        return 1
    fi
    oi=$((10#$pick))
    if (( oi < 1 || oi > ${#outbound_names[@]} )); then
        _error_no_exit "出口序号超出范围: ${pick}"
        return 1
    fi

    local selected_name="${outbound_names[$((oi - 1))]}"
    if [[ "$selected_name" == "vpsgo-ipv4-direct" ]]; then
        _mihomoconf_ensure_vpsgo_direct_proxy "$config_file" "vpsgo-ipv4-direct" "ipv4"
    elif [[ "$selected_name" == "vpsgo-ipv6-direct" ]]; then
        _mihomoconf_ensure_vpsgo_direct_proxy "$config_file" "vpsgo-ipv6-direct" "ipv6"
    fi

    printf -v "$_name_var" '%s' "$selected_name"
    printf -v "$_show_var" '%s' "${outbound_show_names[$((oi - 1))]}"
    return 0
}

_mihomorule_normalize_port_match() {
    local raw="${1:-}" _out_var="$2" token start end
    local -a parts=() normalized=()

    raw=$(_mihomoconf_trim "$raw")
    raw="${raw//\// }"
    raw="${raw//,/ }"
    raw="${raw//;/ }"
    raw="${raw//	/ }"
    read -r -a parts <<< "$raw"
    for token in "${parts[@]}"; do
        token=$(_mihomoconf_trim "$token")
        [[ -z "$token" ]] && continue
        if [[ "$token" == *-* ]]; then
            start="${token%-*}"
            end="${token#*-}"
            if ! _is_valid_port "$start" || ! _is_valid_port "$end" || (( 10#$start > 10#$end )); then
                return 1
            fi
            normalized+=("${start}-${end}")
        else
            _is_valid_port "$token" || return 1
            normalized+=("$token")
        fi
    done
    (( ${#normalized[@]} > 0 )) || return 1
    local joined="" i
    for i in "${!normalized[@]}"; do
        [[ "$i" -gt 0 ]] && joined+="/"
        joined+="${normalized[$i]}"
    done
    printf -v "$_out_var" '%s' "$joined"
    return 0
}

_mihomorule_ios_rule_fallback_paths() {
    cat <<'EOF'
rule/Clash/AppStore/AppStore.yaml
rule/Clash/Apple/Apple.yaml
rule/Clash/AppleMusic/AppleMusic.yaml
rule/Clash/AppleNews/AppleNews.yaml
rule/Clash/AppleTV/AppleTV.yaml
rule/Clash/Gemini/Gemini.yaml
rule/Clash/GitHub/GitHub.yaml
rule/Clash/Google/Google.yaml
rule/Clash/GoogleDrive/GoogleDrive.yaml
rule/Clash/GoogleEarth/GoogleEarth.yaml
rule/Clash/GoogleFCM/GoogleFCM.yaml
rule/Clash/GoogleSearch/GoogleSearch.yaml
rule/Clash/GoogleVoice/GoogleVoice.yaml
rule/Clash/Netflix/Netflix.yaml
rule/Clash/OpenAI/OpenAI.yaml
rule/Clash/Telegram/Telegram.yaml
rule/Clash/TestFlight/TestFlight.yaml
rule/Clash/YouTube/YouTube.yaml
rule/Clash/iCloud/iCloud.yaml
EOF
}

_mihomorule_related_terms() {
    local raw="${1:-}" lower
    raw=$(_mihomoconf_trim "$raw")
    lower=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')
    {
        case "$lower" in
            yt) printf '%s\n' YouTube ;;
            nf) printf '%s\n' Netflix ;;
            *) printf '%s\n' "$raw" ;;
        esac
        case "$lower" in
            *apple*|*icloud*|*itunes*|*appstore*|*ios*|*macos*|*testflight*)
                printf '%s\n' Apple iCloud AppStore AppleMusic AppleNews AppleTV TestFlight
                ;;
        esac
        case "$lower" in
            *youtube*|yt)
                printf '%s\n' YouTube Google Gemini GoogleDrive GoogleFCM GoogleSearch GoogleVoice GoogleEarth
                ;;
            *gemini*|*bard*)
                printf '%s\n' Gemini Google YouTube GoogleDrive GoogleFCM GoogleSearch GoogleVoice GoogleEarth
                ;;
            *google*)
                printf '%s\n' Google YouTube Gemini GoogleDrive GoogleFCM GoogleSearch GoogleVoice GoogleEarth
                ;;
        esac
        case "$lower" in
            *netflix*|nf)
                printf '%s\n' Netflix
                ;;
        esac
    } | awk '
        function trim(s) {
            sub(/^[[:space:]]+/, "", s)
            sub(/[[:space:]]+$/, "", s)
            return s
        }
        {
            t=trim($0)
            k=tolower(t)
            if (t != "" && !seen[k]++) print t
        }
    '
}

_mihomorule_fetch_ios_rule_paths() {
    local output_file="$1" tmp_json fetch_status=0
    tmp_json=$(mktemp) || return 1

    if _download_file "$_MIHOMORULE_IOS_TREE_API" "$tmp_json" >/dev/null 2>&1; then
        awk -F'"' '$2=="path" && $4 ~ /^rule\/Clash\/[^\/]+\/[^\/]+\.yaml$/ { print $4 }' "$tmp_json" \
            | awk -F/ '{
                name=$3
                file=$4
                sub(/\.yaml$/, "", file)
                if (file == name) print
            }' > "$output_file"
    else
        fetch_status=2
    fi
    rm -f "$tmp_json"

    if [[ ! -s "$output_file" ]]; then
        _mihomorule_ios_rule_fallback_paths > "$output_file"
        fetch_status=2
    fi
    return "$fetch_status"
}

_mihomorule_search_ios_rules() {
    local query="$1" output_file="$2"
    local tmp_paths tmp_terms fetch_status=0 tab
    tmp_paths=$(mktemp) || return 1
    tmp_terms=$(mktemp) || {
        rm -f "$tmp_paths"
        return 1
    }
    tab=$'\t'

    _mihomorule_related_terms "$query" > "$tmp_terms"
    _mihomorule_fetch_ios_rule_paths "$tmp_paths"
    fetch_status=$?

    awk -v termsf="$tmp_terms" '
        function trim(s) {
            sub(/^[[:space:]]+/, "", s)
            sub(/[[:space:]]+$/, "", s)
            return s
        }
        function compact(s) {
            gsub(/[[:space:]_.-]+/, "", s)
            return s
        }
        BEGIN {
            while ((getline t < termsf) > 0) {
                t=trim(t)
                if (t == "") continue
                terms[++term_count]=tolower(t)
            }
            close(termsf)
        }
        {
            path=$0
            split(path, a, "/")
            if (a[1] != "rule" || a[2] != "Clash" || a[3] == "") next
            name=a[3]
            lname=tolower(name)
            lpath=tolower(path)
            lname_compact=compact(lname)
            score=0
            for (i=1; i<=term_count; i++) {
                term=terms[i]
                term_compact=compact(term)
                one=0
                if (lname == term || lname_compact == term_compact) {
                    one=100
                } else if (term != "" && (index(lname, term) == 1 || index(lname_compact, term_compact) == 1)) {
                    one=90
                } else if (term != "" && (index(lname, term) > 0 || index(lname_compact, term_compact) > 0)) {
                    one=80
                } else if (term != "" && index(lpath, term) > 0) {
                    one=65
                }
                if (i > 1 && one > 20) one-=15
                if (one > score) score=one
            }
            if (score > 0) printf "%03d\t%s\t%s\n", score, name, path
        }
    ' "$tmp_paths" \
        | LC_ALL=C sort -t "$tab" -k1,1nr -k2,2f \
        | awk -F'\t' '!seen[tolower($2)]++ { printf "%s\037%s\n", $2, $3; count++; if (count >= 30) exit }' \
        > "$output_file"

    rm -f "$tmp_paths" "$tmp_terms"
    return "$fetch_status"
}

_mihomorule_ios_rule_name_from_path() {
    local rule_path="${1:-}" rest name
    rest="${rule_path#rule/Clash/}"
    name="${rest%%/*}"
    [[ -n "$name" && "$name" != "$rest" ]] || return 1
    printf '%s' "$name"
}

_mihomorule_prompt_priority() {
    local config_file="$1" _out_var="$2"
    local idx=0 kind value out_name out_show pick ri
    local -a rule_kinds=() rule_values=() rule_outs=()

    printf "  ${BOLD}当前已有出站分流规则:${PLAIN}\n"
    _separator
    while IFS=$'\x1f' read -r kind value out_name; do
        [[ -z "${kind:-}" ]] && continue
        idx=$((idx + 1))
        rule_kinds+=("$kind")
        rule_values+=("$value")
        rule_outs+=("$out_name")
        out_show=$(_mihomochain_display_name "$out_name")
        case "$kind" in
            RULE-SET) printf "      [%d] 远程规则 %s -> %s\n" "$idx" "$value" "$out_show" ;;
            DST-PORT) printf "      [%d] 目标端口 %s -> %s\n" "$idx" "$value" "$out_show" ;;
            DNS-PRE)
                local u_part="${value%%|*}"
                local r_part="${value##*|}"
                printf "      [%d] 本地解析直发 用户 [ %s ] 规则集 [ %s ] -> %s\n" "$idx" "$u_part" "$r_part" "$out_show"
                ;;
            DNS-PRE-ALL)
                printf "      [%d] 本地解析直发 用户 [ %s ] 全部流量 -> %s\n" "$idx" "$value" "$out_show"
                ;;
        esac
    done < <(_mihomorule_read_policy_rules "$config_file")

    _separator
    if (( idx == 0 )); then
        _info "当前暂无规则，新规则将默认放置在最前面。"
        printf -v "$_out_var" '%s' "0"
        return 0
    fi

    printf "  ${BOLD}选择新规则的插入位置:${PLAIN}\n"
    printf "      [0] 插入到最前面\n"
    local i
    for (( i=1; i<=idx; i++ )); do
        printf "      [%d] 插入在 [%d] 之后\n" "$i" "$i"
    done
    _separator
    read -rp "  请选择插入位置 [0-${idx}, 默认 ${idx} (最后面)]: " pick
    pick=$(_mihomoconf_trim "${pick:-}")
    if [[ -z "$pick" ]]; then
        pick="$idx"
    fi
    if [[ ! "$pick" =~ ^[0-9]+$ ]]; then
        _error_no_exit "请输入有效序号"
        return 1
    fi
    ri=$((10#$pick))
    if (( ri < 0 || ri > idx )); then
        _error_no_exit "序号超出范围: ${pick}"
        return 1
    fi

    printf -v "$_out_var" '%s' "$ri"
    return 0
}

_mihomorule_add_ios_rule_path() {
    local config_file="$1" rule_path="$2" out_name="$3" position="${4:-bottom}"
    local rule_name provider_name url
    rule_name=$(_mihomorule_ios_rule_name_from_path "$rule_path") || return 1
    provider_name=$(_mihomorule_safe_provider_name "$rule_name")
    url="${_MIHOMORULE_IOS_RAW_BASE}/${rule_path}"

    _mihomorule_upsert_remote_provider "$config_file" "$provider_name" "$url" "classical" "yaml" "86400" "./ruleset/${provider_name}.yaml" || return 1
    _mihomorule_add_policy_rule "$config_file" "RULE-SET" "$provider_name" "$out_name" "$position"
}

_mihomorule_search_ios_rule_add() {
    local config_file="$1" query tmp_results fetch_status pick out_name out_show position token idx selected_count=0
    local rule_name rule_path related_text applied=0 failed=0
    local -a result_names=() result_paths=() selected_names=() selected_paths=() tokens=()

    read -rp "  输入要搜索的规则/服务名称: " query
    query=$(_mihomoconf_trim "${query:-}")
    if [[ -z "$query" ]]; then
        _error_no_exit "搜索名称不能为空"
        return 1
    fi

    tmp_results=$(mktemp) || return 1
    _mihomorule_search_ios_rules "$query" "$tmp_results"
    fetch_status=$?
    if [[ "$fetch_status" -eq 2 ]]; then
        _warn "在线检索 iOS rule 仓库失败，已使用内置常用规则兜底"
    fi

    while IFS=$'\x1f' read -r rule_name rule_path; do
        [[ -z "${rule_name:-}" || -z "${rule_path:-}" ]] && continue
        result_names+=("$rule_name")
        result_paths+=("$rule_path")
    done < "$tmp_results"
    rm -f "$tmp_results"

    if (( ${#result_names[@]} == 0 )); then
        _warn "未找到匹配规则"
        return 1
    fi

    related_text=$(_mihomorule_related_terms "$query" | awk '{ out = (out == "" ? $0 : out "/" $0) } END { print out }')
    [[ -n "$related_text" ]] && _info "关联搜索: ${related_text}"
    printf "  ${BOLD}匹配规则:${PLAIN}\n"
    _separator
    for idx in "${!result_names[@]}"; do
        printf "      [%d] %s  ${DIM}%s${PLAIN}\n" "$((idx + 1))" "${result_names[$idx]}" "${result_paths[$idx]}"
    done

    read -rp "  选择规则 [序号，可多选如 1 3 5，Enter 取消]: " pick
    pick=$(_mihomoconf_trim "${pick:-}")
    [[ -n "$pick" ]] || return 1
    pick="${pick//,/ }"
    pick="${pick//;/ }"
    read -r -a tokens <<< "$pick"
    local seen_picks=" "
    for token in "${tokens[@]}"; do
        token=$(_mihomoconf_trim "$token")
        [[ -n "$token" ]] || continue
        if [[ ! "$token" =~ ^[0-9]+$ ]]; then
            _error_no_exit "无效序号: ${token}"
            return 1
        fi
        idx=$((10#$token))
        if (( idx < 1 || idx > ${#result_names[@]} )); then
            _error_no_exit "序号超出范围: ${token}"
            return 1
        fi
        if [[ "$seen_picks" == *" ${idx} "* ]]; then
            continue
        fi
        seen_picks+="${idx} "
        selected_names+=("${result_names[$((idx - 1))]}")
        selected_paths+=("${result_paths[$((idx - 1))]}")
        selected_count=$((selected_count + 1))
    done
    if (( selected_count == 0 )); then
        _error_no_exit "未选择任何规则"
        return 1
    fi

    if ! _mihomorule_pick_outbound "$config_file" out_name out_show; then
        return 1
    fi
    if ! _mihomorule_prompt_priority "$config_file" position; then
        return 1
    fi

    if [[ "$position" =~ ^[0-9]+$ ]]; then
        local current_pos="$position"
        for idx in "${!selected_paths[@]}"; do
            if _mihomorule_add_ios_rule_path "$config_file" "${selected_paths[$idx]}" "$out_name" "$current_pos"; then
                applied=$((applied + 1))
                current_pos=$((current_pos + 1))
            else
                failed=1
                _warn "规则保存失败: ${selected_names[$idx]}"
            fi
        done
    elif [[ "$position" == "top" ]]; then
        for ((idx=selected_count - 1; idx>=0; idx--)); do
            if _mihomorule_add_ios_rule_path "$config_file" "${selected_paths[$idx]}" "$out_name" "$position"; then
                applied=$((applied + 1))
            else
                failed=1
                _warn "规则保存失败: ${selected_names[$idx]}"
            fi
        done
    else
        for idx in "${!selected_paths[@]}"; do
            if _mihomorule_add_ios_rule_path "$config_file" "${selected_paths[$idx]}" "$out_name" "$position"; then
                applied=$((applied + 1))
            else
                failed=1
                _warn "规则保存失败: ${selected_names[$idx]}"
            fi
        done
    fi

    if (( applied == 0 )); then
        return 1
    fi
    _info "已保存 ${applied} 个 iOS rule 规则 -> ${out_show}"
    [[ "$failed" -eq 1 ]] && _warn "部分规则保存失败，请核对上方提示"
    if ! _mihomorule_apply_and_restart; then
        _warn "自动应用或重启失败，请检查日志后重试"
    fi
    return 0
}

_mihomorule_is_policy_line() {
    local line="$1"
    if [[ "$line" =~ ^(RULE-SET|DST-PORT),[^,]+,[^,]+$ ]]; then
        return 0
    fi
    if [[ "$line" =~ ^AND,\(\(IN-USER,[^,]+\),\(RULE-SET,[^,]+\),\(OR,\(\(IP-CIDR,0\.0\.0\.0/0\),\(IP-CIDR6,::/0\)\)\)\),[^,]+$ ]]; then
        return 0
    fi
    if [[ "$line" =~ ^AND,\(\(IN-USER,[^,]+\),\(OR,\(\(IP-CIDR,0\.0\.0\.0/0\),\(IP-CIDR6,::/0\)\)\)\),[^,]+$ ]]; then
        return 0
    fi
    return 1
}

_mihomorule_manage_priority() {
    local config_file="$1"
    local tmp_other tmp_user tmp_name tmp_reordered line kind value out_name out_show pick action ri idx target
    local -a policy_lines=() new_policy_lines=()

    tmp_other=$(mktemp)
    tmp_user=$(mktemp)
    tmp_name=$(mktemp)
    tmp_reordered=$(mktemp)
    _mihomochain_rule_split_parts "$config_file" "$tmp_other" "$tmp_user" "$tmp_name"

    while IFS= read -r line; do
        if _mihomorule_is_policy_line "$line"; then
            policy_lines+=("$line")
        fi
    done < "$tmp_other"

    if (( ${#policy_lines[@]} < 2 )); then
        _warn "至少需要 2 条服务/端口/域名解析分流规则才能调整优先级"
        rm -f "$tmp_other" "$tmp_user" "$tmp_name" "$tmp_reordered"
        return 1
    fi

    printf "  ${BOLD}当前优先级（越靠前越先匹配）:${PLAIN}\n"
    _separator
    for idx in "${!policy_lines[@]}"; do
        local pline="${policy_lines[$idx]}"
        if [[ "$pline" == RULE-SET,* ]]; then
            IFS=',' read -r kind value out_name <<< "$pline"
            out_show=$(_mihomochain_display_name "$out_name")
            printf "      [%d] 远程规则 %s -> %s\n" "$((idx + 1))" "$value" "$out_show"
        elif [[ "$pline" == DST-PORT,* ]]; then
            IFS=',' read -r kind value out_name <<< "$pline"
            out_show=$(_mihomochain_display_name "$out_name")
            printf "      [%d] 目标端口 %s -> %s\n" "$((idx + 1))" "$value" "$out_show"
        elif [[ "$pline" == AND,\(\(IN-USER,*\),\(RULE-SET,*\),\(OR,\(\(IP-CIDR,0.0.0.0/0\),\(IP-CIDR6,::/0\)\)\)\),* ]]; then
            out_name="${pline##*)))),}"
            out_show=$(_mihomochain_display_name "$out_name")
            local user_part="${pline#*AND,((IN-USER,}"
            local user="${user_part%%),(RULE-SET,*}"
            local ruleset_part="${pline#*),(RULE-SET,}"
            local ruleset="${ruleset_part%%),(OR,*}"
            printf "      [%d] 本地解析直发 用户 [ %s ] 规则集 [ %s ] -> %s\n" "$((idx + 1))" "$user" "$ruleset" "$out_show"
        elif [[ "$pline" == AND,\(\(IN-USER,*\),\(OR,\(\(IP-CIDR,0.0.0.0/0\),\(IP-CIDR6,::/0\)\)\)\),* ]]; then
            out_name="${pline##*)))),}"
            out_show=$(_mihomochain_display_name "$out_name")
            local user_part="${pline#*AND,((IN-USER,}"
            local user="${user_part%%),(OR,*}"
            printf "      [%d] 本地解析直发 用户 [ %s ] 全部流量 -> %s\n" "$((idx + 1))" "$user" "$out_show"
        fi
    done

    read -rp "  选择要调整的规则 [序号]: " pick
    pick=$(_mihomoconf_trim "${pick:-}")
    if [[ -z "$pick" || ! "$pick" =~ ^[0-9]+$ ]]; then
        _error_no_exit "请输入有效序号"
        rm -f "$tmp_other" "$tmp_user" "$tmp_name" "$tmp_reordered"
        return 1
    fi
    ri=$((10#$pick - 1))
    if (( ri < 0 || ri >= ${#policy_lines[@]} )); then
        _error_no_exit "序号超出范围: ${pick}"
        rm -f "$tmp_other" "$tmp_user" "$tmp_name" "$tmp_reordered"
        return 1
    fi

    printf "  ${BOLD}调整方式:${PLAIN}\n"
    _separator
    _menu_pair "1" "上移" "" "green" "2" "下移" "" "green"
    _menu_pair "3" "置顶" "" "green" "4" "置底" "" "yellow"
    read -rp "  选择 [1-4]: " action
    action=$(_mihomoconf_trim "${action:-}")

    case "$action" in
        1)
            if (( ri == 0 )); then
                _warn "该规则已经在最前"
            else
                target="${policy_lines[$ri]}"
                policy_lines[$ri]="${policy_lines[$((ri - 1))]}"
                policy_lines[$((ri - 1))]="$target"
            fi
            ;;
        2)
            if (( ri == ${#policy_lines[@]} - 1 )); then
                _warn "该规则已经在最后"
            else
                target="${policy_lines[$ri]}"
                policy_lines[$ri]="${policy_lines[$((ri + 1))]}"
                policy_lines[$((ri + 1))]="$target"
            fi
            ;;
        3)
            target="${policy_lines[$ri]}"
            new_policy_lines=("$target")
            for idx in "${!policy_lines[@]}"; do
                (( idx == ri )) && continue
                new_policy_lines+=("${policy_lines[$idx]}")
            done
            policy_lines=("${new_policy_lines[@]}")
            ;;
        4)
            target="${policy_lines[$ri]}"
            new_policy_lines=()
            for idx in "${!policy_lines[@]}"; do
                (( idx == ri )) && continue
                new_policy_lines+=("${policy_lines[$idx]}")
            done
            new_policy_lines+=("$target")
            policy_lines=("${new_policy_lines[@]}")
            ;;
        *)
            _error_no_exit "无效选项"
            rm -f "$tmp_other" "$tmp_user" "$tmp_name" "$tmp_reordered"
            return 1
            ;;
    esac

    idx=0
    while IFS= read -r line; do
        if _mihomorule_is_policy_line "$line"; then
            printf '%s\n' "${policy_lines[$idx]}" >> "$tmp_reordered"
            idx=$((idx + 1))
        else
            printf '%s\n' "$line" >> "$tmp_reordered"
        fi
    done < "$tmp_other"
    mv "$tmp_reordered" "$tmp_other"
    _mihomochain_rule_write_parts "$config_file" "$tmp_other" "$tmp_user" "$tmp_name"
    rm -f "$tmp_other" "$tmp_user" "$tmp_name"

    _info "规则优先级已更新"
    if ! _mihomorule_apply_and_restart; then
        _warn "自动应用或重启失败，请检查日志后重试"
    fi
    return 0
}

_mihomorule_apply_and_restart() {
    if ! _mihomochain_apply_to_config; then
        return 1
    fi
    if ! _mihomo_reload_or_restart; then
        return 1
    fi
    _success "出站分流规则已生效"
    return 0
}

_mihomorule_add_dns_pre_rule_flow() {
    local config_file="$1"
    local -a user_list=()
    local username

    # Collect unique users
    while IFS= read -r username; do
        [[ -n "$username" ]] && user_list+=("$username")
    done < <(_mihomoconf_read_listener_user_rows "$config_file" | awk -F'\x1f' '{print $5}' | sort -u)

    local target_user=""
    if (( ${#user_list[@]} > 0 )); then
        _header "选择入站用户/UUID"
        local uidx
        for uidx in "${!user_list[@]}"; do
            printf "      [%d] %s\n" "$((uidx + 1))" "${user_list[$uidx]}"
        done
        printf "      [m] 手动输入用户名/UUID\n"
        _separator
        
        local pick_user
        read -rp "  选择用户 [序号/m]: " pick_user
        pick_user=$(_mihomoconf_trim "${pick_user:-}")
        if [[ "$pick_user" == "m" || "$pick_user" == "M" ]]; then
            read -rp "  请输入入站用户或UUID: " target_user
            target_user=$(_mihomoconf_trim "${target_user:-}")
        else
            if [[ -z "$pick_user" || ! "$pick_user" =~ ^[0-9]+$ ]]; then
                _error_no_exit "请输入有效序号"
                return 1
            fi
            local ui=$((10#$pick_user - 1))
            if (( ui < 0 || ui >= ${#user_list[@]} )); then
                _error_no_exit "序号超出范围: ${pick_user}"
                return 1
            fi
            target_user="${user_list[$ui]}"
        fi
    else
        read -rp "  请输入入站用户或UUID: " target_user
        target_user=$(_mihomoconf_trim "${target_user:-}")
    fi

    if [[ -z "$target_user" ]]; then
        _error_no_exit "用户名或UUID不能为空"
        return 1
    fi

    # Collect unique rule-sets/providers
    local -a provider_list=()
    local provider_name
    while IFS= read -r provider_name; do
        [[ -n "$provider_name" ]] && provider_list+=("$provider_name")
    done < <(_mihomorule_read_providers "$config_file")

    _header "选择规则匹配范围"
    printf "      [1] 全部流量 (用户所有域名与IP)\n"
    local pidx
    for pidx in "${!provider_list[@]}"; do
        printf "      [%d] 规则集 [ %s ]\n" "$((pidx + 2))" "${provider_list[$pidx]}"
    done
    _separator

    local pick_scope
    read -rp "  选择范围 [序号]: " pick_scope
    pick_scope=$(_mihomoconf_trim "${pick_scope:-}")
    if [[ -z "$pick_scope" || ! "$pick_scope" =~ ^[0-9]+$ ]]; then
        _error_no_exit "请输入有效序号"
        return 1
    fi
    local si=$((10#$pick_scope))
    
    local target_ruleset=""
    local rule_type=""
    local target_value=""
    if (( si == 1 )); then
        rule_type="DNS-PRE-ALL"
        target_value="$target_user"
    else
        local pi=$((si - 2))
        if (( pi < 0 || pi >= ${#provider_list[@]} )); then
            _error_no_exit "序号超出范围: ${pick_scope}"
            return 1
        fi
        rule_type="DNS-PRE"
        target_ruleset="${provider_list[$pi]}"
        target_value="${target_user}|${target_ruleset}"
    fi

    # Pick outbound
    local out_name="" out_show=""
    if ! _mihomorule_pick_outbound "$config_file" out_name out_show; then
        return 1
    fi

    # Prompt priority
    local position=""
    if ! _mihomorule_prompt_priority "$config_file" position; then
        return 1
    fi

    # Add and apply
    if _mihomorule_add_policy_rule "$config_file" "$rule_type" "$target_value" "$out_name" "$position"; then
        _info "本地解析直发分流规则添加成功 -> ${out_show}"
        if ! _mihomorule_apply_and_restart; then
            _warn "自动应用或重启失败，请检查日志后重试"
        fi
        return 0
    else
        _error_no_exit "本地解析直发分流规则添加失败"
        return 1
    fi
}

_mihomo_outbound_rule_manage() {
    local config_file="$_MIHOMOCONF_CONFIG_FILE"
    if [[ ! -f "$config_file" ]]; then
        _error_no_exit "未找到配置文件: ${config_file}"
        _info "请先在 Mihomo 菜单中生成基础配置"
        _press_any_key
        return
    fi

    while true; do
        _header "Mihomo 出站分流规则"
        _info "配置文件: ${config_file}"
        _info "预置规则来源: blackmatrix7/ios_rule_script (Clash classical yaml)"
        _info "支持 iOS rule 模糊搜索、多选添加和规则优先级调整"
        _info "自定义远程规则支持 yaml/text/mrs；mrs 仅支持 domain/ipcidr"
        _separator
        _menu_pair "1" "查看当前分流" "含优先级" "green" "2" "搜索 iOS 规则" "模糊搜索/多选" "green"
        _menu_pair "3" "分流 Google" "远程规则" "green" "4" "分流 Netflix" "远程规则" "green"
        _menu_pair "5" "分流指定端口" "DST-PORT" "green" "6" "自定义远程规则" "支持 mrs" "green"
        _menu_pair "7" "调整规则优先级" "上移/置顶" "green" "8" "删除分流规则" "" "yellow"
        _menu_pair "9" "本地解析直发分流" "DNS 预解析" "green" "10" "Gemini/Google IPv4 定向" "解决 Gemini 地区限制" "green"
        _menu_item "0" "返回上级菜单" "" "red"
        _separator

        local ch
        read -rp "  选择 [0-10]: " ch
        case "$ch" in
            1)
                printf "  ${BOLD}服务/端口分流:${PLAIN}\n"
                _separator
                _mihomorule_list_policy_rules "$config_file"
                _press_any_key
                ;;
            2)
                _mihomorule_search_ios_rule_add "$config_file"
                _press_any_key
                ;;
            3|4)
                local provider_name service_name url out_name out_show position
                if [[ "$ch" == "3" ]]; then
                    service_name="Google"
                    provider_name="vpsgo_google"
                    url="https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/Google/Google.yaml"
                else
                    service_name="Netflix"
                    provider_name="vpsgo_netflix"
                    url="https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/Netflix/Netflix.yaml"
                fi
                if ! _mihomorule_pick_outbound "$config_file" out_name out_show; then
                    _press_any_key
                    continue
                fi
                if ! _mihomorule_prompt_priority "$config_file" position; then
                    _press_any_key
                    continue
                fi
                _mihomorule_upsert_remote_provider "$config_file" "$provider_name" "$url" "classical" "yaml" "86400" "./ruleset/${provider_name}.yaml"
                _mihomorule_add_policy_rule "$config_file" "RULE-SET" "$provider_name" "$out_name" "$position"
                _info "规则已保存: ${service_name} -> ${out_show}"
                if ! _mihomorule_apply_and_restart; then
                    _warn "自动应用或重启失败，请检查日志后重试"
                fi
                _press_any_key
                ;;
            5)
                local port_input port_match out_name out_show position
                read -rp "  目标端口/范围 (如 443 或 80/443/8000-9000): " port_input
                if ! _mihomorule_normalize_port_match "$port_input" port_match; then
                    _error_no_exit "端口格式无效，支持单端口、范围和 / 分隔的多个端口"
                    _press_any_key
                    continue
                fi
                if ! _mihomorule_pick_outbound "$config_file" out_name out_show; then
                    _press_any_key
                    continue
                fi
                if ! _mihomorule_prompt_priority "$config_file" position; then
                    _press_any_key
                    continue
                fi
                _mihomorule_add_policy_rule "$config_file" "DST-PORT" "$port_match" "$out_name" "$position"
                _info "规则已保存: 目标端口 ${port_match} -> ${out_show}"
                if ! _mihomorule_apply_and_restart; then
                    _warn "自动应用或重启失败，请检查日志后重试"
                fi
                _press_any_key
                ;;
            6)
                local rule_label provider_name url behavior format interval path out_name out_show position
                read -rp "  规则名称 [如 youtube_domain]: " rule_label
                rule_label=$(_mihomoconf_trim "${rule_label:-}")
                provider_name=$(_mihomorule_safe_provider_name "$rule_label")
                read -rp "  远程规则 URL: " url
                url=$(_mihomoconf_trim "${url:-}")
                if [[ "$url" != http://* && "$url" != https://* ]]; then
                    _error_no_exit "远程规则 URL 必须以 http:// 或 https:// 开头"
                    _press_any_key
                    continue
                fi
                if [[ "$url" == *.mrs* ]]; then
                    format="mrs"
                    behavior="domain"
                else
                    format="yaml"
                    behavior="classical"
                fi
                read -rp "  format [默认 ${format}; yaml/text/mrs]: " format
                format=$(_mihomoconf_trim "${format:-}")
                [[ -n "$format" ]] || format=$([[ "$url" == *.mrs* ]] && printf 'mrs' || printf 'yaml')
                case "$format" in
                    yaml|text|mrs) ;;
                    *) _error_no_exit "format 仅支持 yaml/text/mrs"; _press_any_key; continue ;;
                esac
                if [[ "$format" == "mrs" ]]; then
                    read -rp "  behavior [默认 domain; domain/ipcidr]: " behavior
                    behavior=$(_mihomoconf_trim "${behavior:-domain}")
                    case "$behavior" in
                        domain|ipcidr) ;;
                        *) _error_no_exit "mrs 仅支持 behavior=domain/ipcidr"; _press_any_key; continue ;;
                    esac
                else
                    read -rp "  behavior [默认 classical; classical/domain/ipcidr]: " behavior
                    behavior=$(_mihomoconf_trim "${behavior:-classical}")
                    case "$behavior" in
                        classical|domain|ipcidr) ;;
                        *) _error_no_exit "behavior 仅支持 classical/domain/ipcidr"; _press_any_key; continue ;;
                    esac
                fi
                read -rp "  更新间隔秒数 [默认 86400]: " interval
                interval=$(_mihomoconf_trim "${interval:-86400}")
                if ! _is_digit "$interval" || [[ "$interval" -le 0 ]]; then
                    _error_no_exit "更新间隔必须为正整数"
                    _press_any_key
                    continue
                fi
                path="./ruleset/${provider_name}.${format}"
                read -rp "  本地缓存路径 [默认 ${path}]: " path
                path=$(_mihomoconf_trim "${path:-./ruleset/${provider_name}.${format}}")
                if ! _mihomorule_pick_outbound "$config_file" out_name out_show; then
                    _press_any_key
                    continue
                fi
                if ! _mihomorule_prompt_priority "$config_file" position; then
                    _press_any_key
                    continue
                fi
                if ! _mihomorule_upsert_remote_provider "$config_file" "$provider_name" "$url" "$behavior" "$format" "$interval" "$path"; then
                    _press_any_key
                    continue
                fi
                _mihomorule_add_policy_rule "$config_file" "RULE-SET" "$provider_name" "$out_name" "$position"
                _info "规则已保存: ${provider_name} (${format}/${behavior}) -> ${out_show}"
                if ! _mihomorule_apply_and_restart; then
                    _warn "自动应用或重启失败，请检查日志后重试"
                fi
                _press_any_key
                ;;
            7)
                _mihomorule_manage_priority "$config_file"
                _press_any_key
                ;;
            8)
                local idx=0 kind value out_name out_show pick ri
                local -a rule_kinds=() rule_values=() rule_outs=()
                printf "  ${BOLD}可删除的服务/端口/本地解析分流:${PLAIN}\n"
                _separator
                while IFS=$'\x1f' read -r kind value out_name; do
                    [[ -z "${kind:-}" ]] && continue
                    idx=$((idx + 1))
                    rule_kinds+=("$kind")
                    rule_values+=("$value")
                    rule_outs+=("$out_name")
                    out_show=$(_mihomochain_display_name "$out_name")
                    case "$kind" in
                        RULE-SET) printf "      [%d] 远程规则 %s -> %s\n" "$idx" "$value" "$out_show" ;;
                        DST-PORT) printf "      [%d] 目标端口 %s -> %s\n" "$idx" "$value" "$out_show" ;;
                        DNS-PRE)
                            local u_part="${value%%|*}"
                            local r_part="${value##*|}"
                            printf "      [%d] 本地解析直发 用户 [ %s ] 规则集 [ %s ] -> %s\n" "$idx" "$u_part" "$r_part" "$out_show"
                            ;;
                        DNS-PRE-ALL)
                            printf "      [%d] 本地解析直发 用户 [ %s ] 全部流量 -> %s\n" "$idx" "$value" "$out_show"
                            ;;
                    esac
                done < <(_mihomorule_read_policy_rules "$config_file")
                if (( idx == 0 )); then
                    _warn "暂无可删除的服务/端口/本地解析分流规则"
                    _press_any_key
                    continue
                fi
                read -rp "  选择要删除的规则 [序号]: " pick
                pick=$(_mihomoconf_trim "${pick:-}")
                if [[ -z "$pick" || ! "$pick" =~ ^[0-9]+$ ]]; then
                    _error_no_exit "请输入有效序号"
                    _press_any_key
                    continue
                fi
                ri=$((10#$pick))
                if (( ri < 1 || ri > idx )); then
                    _error_no_exit "序号超出范围: ${pick}"
                    _press_any_key
                    continue
                fi
                kind="${rule_kinds[$((ri - 1))]}"
                value="${rule_values[$((ri - 1))]}"
                _mihomorule_remove_policy_rule "$config_file" "$kind" "$value"
                if [[ "$kind" == "RULE-SET" && "$value" == vpsgo_* ]]; then
                    _mihomorule_provider_remove "$config_file" "$value"
                fi
                _info "规则已删除: ${kind},${value}"
                if ! _mihomorule_apply_and_restart; then
                    _warn "自动应用或重启失败，请检查日志后重试"
                fi
                _press_any_key
                ;;
            9)
                _mihomorule_add_dns_pre_rule_flow "$config_file"
                _press_any_key
                ;;
            10)
                _mihomo_ipv4_google_manage
                ;;
            0) return ;;
            *)
                _error_no_exit "无效选项"
                sleep 1
                ;;
        esac
    done
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
    _mihomoconf_apply_vpsgo_direct_policies "$config_file"
    _info "Mihomo 出站/分流配置已写入: ${config_file}"
    return 0
}

_mihomochain_apply_and_restart() {
    if ! _mihomochain_apply_to_config; then
        return 1
    fi
    if ! _mihomo_reload_or_restart; then
        return 1
    fi
    _success "出口管理配置已生效"
    return 0
}

_mihomo_chain_proxy_manage() {
    _header "出口管理（支持链式）"

    local config_file="$_MIHOMOCONF_CONFIG_FILE"

    if [[ ! -f "$config_file" ]]; then
        _error_no_exit "未找到配置文件: ${config_file}"
        _info "请先在 Mihomo 菜单中生成基础配置"
        _press_any_key
        return
    fi

    while true; do
        _header "出口管理（支持链式）"
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
                _menu_pair "1" "通过链接导入" "ss:// socks5:// hy2:// anytls:// vless:// tuic:// wireguard:// (Beta)" "green" "2" "手动录入" "" "green"
                _separator
                local import_mode out_name out_tag out_type out_server out_port out_cipher out_user out_pass
                local out_sni out_insecure out_obfs out_obfs_pass out_mport
                local out_ss_udp out_ss_uot out_hy2_cc
                local out_wg_ip out_wg_ipv6 out_wg_private_key out_wg_public_key out_wg_allowed_ips
                local out_wg_preshared_key out_wg_reserved out_wg_mtu out_wg_keepalive
                local out_vless_uuid out_vless_flow out_vless_public_key out_vless_short_id out_vless_client_fingerprint out_vless_packet_encoding
                read -rp "  选择 [1/2]: " import_mode
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
                out_ss_udp="1"
                out_ss_uot="0"
                out_sni=""
                out_insecure="0"
                out_obfs=""
                out_obfs_pass=""
                out_mport=""
                out_hy2_cc=""
                out_wg_ip=""
                out_wg_ipv6=""
                out_wg_private_key=""
                out_wg_public_key=""
                out_wg_allowed_ips=""
                out_wg_preshared_key=""
                out_wg_reserved=""
                out_wg_mtu=""
                out_wg_keepalive=""
                out_vless_uuid=""
                out_vless_flow="xtls-rprx-vision"
                out_vless_public_key=""
                out_vless_short_id=""
                out_vless_client_fingerprint="chrome"
                out_vless_packet_encoding="xudp"
                case "$import_mode" in
                    1)
                        local in_link link_body link_userinfo link_hostport link_query link_name
                        local rename_confirm custom_name_input
                        local ss_decoded kv k v
                        local -a _qarr
                        read -rp "  输入链接 (ss:// / socks5:// / hy2:// / hysteria2:// / anytls:// / vless:// / wireguard://[Beta]): " in_link
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
                                        [[ "$kv" == *=* ]] && v="${kv#*=}" || v=""
                                        if ! _mihomochain_apply_ss_query_param "$k" "$v" out_ss_udp out_ss_uot; then
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
                                [[ "$out_ss_udp" == "0" ]] && out_ss_uot="0"
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
                                            congestion_control) out_hy2_cc="$v" ;;
                                        esac
                                    done
                                fi
                                ;;
                            vless://*)
                                link_body="${in_link#vless://}"
                                link_body="${link_body%%#*}"
                                link_query=""
                                if [[ "$link_body" == *\?* ]]; then
                                    link_query="${link_body#*\?}"
                                    link_body="${link_body%%\?*}"
                                fi
                                if [[ "$link_body" != *@* ]]; then
                                    _error_no_exit "vless 链接格式错误"
                                    _press_any_key
                                    continue
                                fi
                                link_userinfo="${link_body%@*}"
                                link_hostport="${link_body#*@}"
                                link_hostport="${link_hostport%%/*}"
                                out_server="${link_hostport%:*}"
                                out_port="${link_hostport##*:}"
                                out_vless_uuid=$(_mihomochain_urldecode "$link_userinfo")
                                if [[ -z "$out_server" || -z "$out_vless_uuid" ]] || ! _is_valid_port "$out_port"; then
                                    _error_no_exit "vless 链接解析失败"
                                    _press_any_key
                                    continue
                                fi
                                out_type="vless"
                                if [[ -n "$link_query" ]]; then
                                    local out_vless_security="" out_vless_network=""
                                    IFS='&' read -r -a _qarr <<< "$link_query"
                                    for kv in "${_qarr[@]}"; do
                                        k="${kv%%=*}"
                                        [[ "$kv" == *=* ]] && v="${kv#*=}" || v=""
                                        k=$(_mihomochain_urldecode "$k")
                                        v=$(_mihomochain_urldecode "$v")
                                        case "$k" in
                                            sni|peer|servername|host) out_sni="$v" ;;
                                            security) out_vless_security="$v" ;;
                                            type|network) out_vless_network="$v" ;;
                                            flow) out_vless_flow="$v" ;;
                                            fp|client-fingerprint|client_fingerprint) out_vless_client_fingerprint="$v" ;;
                                            pbk|public-key|public_key) out_vless_public_key="$v" ;;
                                            sid|short-id|short_id) out_vless_short_id="$v" ;;
                                            packet-encoding|packetEncoding) out_vless_packet_encoding="$v" ;;
                                            insecure)
                                                if [[ "$v" == "1" || "$v" =~ ^([Tt][Rr][Uu][Ee]|[Yy][Ee][Ss])$ ]]; then
                                                    out_insecure="1"
                                                fi
                                                ;;
                                        esac
                                    done
                                    if [[ -n "$out_vless_security" && "$out_vless_security" != "reality" && "$out_vless_security" != "tls" && "$out_vless_security" != "none" ]]; then
                                        _error_no_exit "暂不支持该 VLESS security=${out_vless_security}"
                                        _press_any_key
                                        continue
                                    fi
                                    if [[ -n "$out_vless_network" && "$out_vless_network" != "tcp" ]]; then
                                        _error_no_exit "当前仅支持 VLESS TCP 出站导入"
                                        _press_any_key
                                        continue
                                    fi
                                fi
                                ;;
                            socks5://*|socks://*)
                                if [[ "$in_link" == socks5://* ]]; then
                                    link_body="${in_link#socks5://}"
                                else
                                    link_body="${in_link#socks://}"
                                fi
                                link_body="${link_body%%#*}"
                                link_query=""
                                if [[ "$link_body" == *\?* ]]; then
                                    link_query="${link_body#*\?}"
                                    link_body="${link_body%%\?*}"
                                fi
                                link_body="${link_body%%/*}"
                                out_user=""
                                out_pass=""
                                if [[ "$link_body" == *@* ]]; then
                                    link_userinfo="${link_body%@*}"
                                    link_hostport="${link_body#*@}"
                                    if [[ "$link_userinfo" == *:* ]]; then
                                        out_user=$(_mihomochain_urldecode "${link_userinfo%%:*}")
                                        out_pass=$(_mihomochain_urldecode "${link_userinfo#*:}")
                                    else
                                        out_user=$(_mihomochain_urldecode "$link_userinfo")
                                    fi
                                else
                                    link_hostport="$link_body"
                                fi
                                if ! _mihomochain_parse_host_port "$link_hostport" out_server out_port; then
                                    _error_no_exit "socks5 链接解析失败，需为 socks5://[user:pass@]server:port"
                                    _press_any_key
                                    continue
                                fi
                                out_type="socks5"
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
                            tuic://*)
                                link_body="${in_link#tuic://}"
                                link_body="${link_body%%#*}"
                                link_query=""
                                if [[ "$link_body" == *\?* ]]; then
                                    link_query="${link_body#*\?}"
                                    link_body="${link_body%%\?*}"
                                fi
                                if [[ "$link_body" != *@* ]]; then
                                    _error_no_exit "tuic 链接格式错误"
                                    _press_any_key
                                    continue
                                fi
                                link_userinfo="${link_body%@*}"
                                link_hostport="${link_body#*@}"
                                link_hostport="${link_hostport%%/*}"
                                out_server="${link_hostport%:*}"
                                out_port="${link_hostport##*:}"
                                if [[ "$link_userinfo" != *:* ]]; then
                                    _error_no_exit "tuic 链接格式错误，需为 tuic://UUID:PASSWORD@server:port?..."
                                    _press_any_key
                                    continue
                                fi
                                out_vless_uuid="${link_userinfo%%:*}"
                                out_pass="${link_userinfo#*:}"
                                out_pass=$(_mihomochain_urldecode "$out_pass")
                                if [[ -z "$out_server" || -z "$out_vless_uuid" || -z "$out_pass" ]] || ! _is_valid_port "$out_port"; then
                                    _error_no_exit "tuic 链接解析失败"
                                    _press_any_key
                                    continue
                                fi
                                out_type="tuic"
                                if [[ -n "$link_query" ]]; then
                                    IFS='&' read -r -a _qarr <<< "$link_query"
                                    for kv in "${_qarr[@]}"; do
                                        k="${kv%%=*}"
                                        [[ "$kv" == *=* ]] && v="${kv#*=}" || v=""
                                        k=$(_mihomochain_urldecode "$k")
                                        v=$(_mihomochain_urldecode "$v")
                                        case "$k" in
                                            sni|peer) out_sni="$v" ;;
                                            congestion_control) out_vless_flow="$v" ;;
                                            alpn) out_vless_client_fingerprint="$v" ;;
                                            udp_relay_mode) out_vless_packet_encoding="$v" ;;
                                            insecure)
                                                if [[ "$v" == "1" || "$v" =~ ^([Tt][Rr][Uu][Ee]|[Yy][Ee][Ss])$ ]]; then
                                                    out_insecure="1"
                                                fi
                                                ;;
                                        esac
                                    done
                                fi
                                ;;
                            *)
                                _error_no_exit "暂不支持该链接类型，请使用 ss:// / socks5:// / hy2:// / hysteria2:// / anytls:// / vless:// / tuic:// / wireguard://(Beta)"
                                _press_any_key
                                continue
                                ;;
                        esac
                        out_name=$(_mihomoconf_trim "${link_name:-}")
                        if [[ -z "$out_name" ]]; then
                            out_name=$(_mihomochain_default_outbound_name "$out_type" "$out_server" "$out_port")
                        fi
                        read -rp "  自定义出口节点名称? [y/N]: " rename_confirm
                        if [[ "$rename_confirm" =~ ^[Yy] ]]; then
                            read -rp "  出口节点名称 [默认 ${out_name}]: " custom_name_input
                            out_name=$(_mihomoconf_trim "${custom_name_input:-$out_name}")
                        fi
                        ;;
                    2)
                        _separator
                        _menu_pair "1" "ss" "" "green" "2" "hy2" "" "green"
                        _menu_pair "3" "anytls" "" "green" "4" "vless" "" "green"
                        _menu_pair "5" "socks5" "" "green" "6" "http" "" "green"
                        _menu_pair "7" "wireguard (Beta)" "" "green" "8" "tuic" "" "green"
                        _separator
                        local type_choice
                        read -rp "  出站类型 [1-8]: " type_choice
                        case "$type_choice" in
                            1) out_type="ss" ;;
                            2) out_type="hysteria2" ;;
                            3) out_type="anytls" ;;
                            4) out_type="vless" ;;
                            5) out_type="socks5" ;;
                            6) out_type="http" ;;
                            7) out_type="wireguard" ;;
                            8) out_type="tuic" ;;
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
                                local ss_udp_answer ss_uot_answer
                                read -rp "  cipher [默认 aes-256-gcm]: " out_cipher
                                out_cipher="${out_cipher:-aes-256-gcm}"
                                read -rp "  password: " out_pass
                                if [[ -z "$out_pass" ]]; then
                                    _error_no_exit "ss password 不能为空"
                                    _press_any_key
                                    continue
                                fi
                                read -rp "  开启 UDP? [Y/n]: " ss_udp_answer
                                if [[ "$ss_udp_answer" =~ ^([Nn]|[Nn][Oo])$ ]]; then
                                    out_ss_udp="0"
                                    out_ss_uot="0"
                                else
                                    out_ss_udp="1"
                                    read -rp "  开启 UDP over TCP v2? [y/N]: " ss_uot_answer
                                    [[ "$ss_uot_answer" =~ ^([Yy]|[Yy][Ee][Ss])$ ]] && out_ss_uot="1" || out_ss_uot="0"
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
                                read -rp "  congestion-control [默认 brutal]: " out_hy2_cc
                                out_hy2_cc=$(_mihomoconf_trim "${out_hy2_cc:-brutal}")
                                if [[ -z "$out_pass" ]]; then
                                    _error_no_exit "hy2 password 不能为空"
                                    _press_any_key
                                    continue
                                fi
                                ;;
                            vless)
                                read -rp "  uuid: " out_vless_uuid
                                out_vless_uuid=$(_mihomoconf_trim "${out_vless_uuid:-}")
                                read -rp "  servername/sni [可留空，默认跟随 server]: " out_sni
                                out_sni=$(_mihomoconf_trim "${out_sni:-}")
                                read -rp "  flow [默认 xtls-rprx-vision]: " out_vless_flow
                                out_vless_flow=$(_mihomoconf_trim "${out_vless_flow:-xtls-rprx-vision}")
                                read -rp "  client-fingerprint [默认 chrome]: " out_vless_client_fingerprint
                                out_vless_client_fingerprint=$(_mihomoconf_trim "${out_vless_client_fingerprint:-chrome}")
                                read -rp "  packet-encoding [默认 xudp]: " out_vless_packet_encoding
                                out_vless_packet_encoding=$(_mihomoconf_trim "${out_vless_packet_encoding:-xudp}")
                                read -rp "  reality public-key [可留空]: " out_vless_public_key
                                out_vless_public_key=$(_mihomoconf_trim "${out_vless_public_key:-}")
                                read -rp "  reality short-id [可留空]: " out_vless_short_id
                                out_vless_short_id=$(_mihomoconf_trim "${out_vless_short_id:-}")
                                local vless_insecure_input
                                read -rp "  insecure (跳过证书验证)? [y/N]: " vless_insecure_input
                                [[ "$vless_insecure_input" =~ ^[Yy] ]] && out_insecure="1" || out_insecure="0"
                                if [[ -z "$out_vless_uuid" ]]; then
                                    _error_no_exit "vless uuid 不能为空"
                                    _press_any_key
                                    continue
                                fi
                                ;;
                            socks5|http)
                                read -rp "  username [可留空]: " out_user
                                read -rp "  password [可留空]: " out_pass
                                ;;
                            tuic)
                                read -rp "  uuid [留空自动生成]: " out_vless_uuid
                                out_vless_uuid=$(_mihomoconf_trim "${out_vless_uuid:-}")
                                if [[ -z "$out_vless_uuid" ]]; then
                                    out_vless_uuid=$(_mihomoconf_gen_uuid)
                                    _info "已自动生成 UUID: ${out_vless_uuid}"
                                fi
                                read -rp "  password: " out_pass
                                read -rp "  sni/peer [可留空]: " out_sni
                                local tuic_insecure_input
                                read -rp "  insecure (跳过证书验证)? [y/N]: " tuic_insecure_input
                                [[ "$tuic_insecure_input" =~ ^[Yy] ]] && out_insecure="1" || out_insecure="0"
                                read -rp "  congestion-control [默认 bbr]: " out_vless_flow
                                out_vless_flow=$(_mihomoconf_trim "${out_vless_flow:-bbr}")
                                read -rp "  alpn [默认 h3]: " out_vless_client_fingerprint
                                out_vless_client_fingerprint=$(_mihomoconf_trim "${out_vless_client_fingerprint:-h3}")
                                read -rp "  udp-relay-mode [默认 native]: " out_vless_packet_encoding
                                out_vless_packet_encoding=$(_mihomoconf_trim "${out_vless_packet_encoding:-native}")
                                if [[ -z "$out_pass" ]]; then
                                    _error_no_exit "tuic password 不能为空"
                                    _press_any_key
                                    continue
                                fi
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

                if [[ "$out_name$out_server$out_cipher$out_user$out_pass$out_sni$out_obfs$out_obfs_pass$out_mport$out_hy2_cc"\
"$out_wg_ip$out_wg_ipv6$out_wg_private_key$out_wg_public_key$out_wg_allowed_ips$out_wg_preshared_key$out_wg_reserved$out_wg_mtu$out_wg_keepalive"\
"$out_vless_uuid$out_vless_flow$out_vless_public_key$out_vless_short_id$out_vless_client_fingerprint$out_vless_packet_encoding" == *"|"* ]]; then
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
                    "${out_wg_allowed_ips:-}" "${out_wg_preshared_key:-}" "${out_wg_reserved:-}" "${out_wg_mtu:-}" "${out_wg_keepalive:-}" \
                    "${out_vless_uuid:-}" "${out_vless_flow:-}" "${out_vless_public_key:-}" "${out_vless_short_id:-}" \
                    "${out_vless_client_fingerprint:-}" "${out_vless_packet_encoding:-}" \
                    "${out_hy2_cc:-brutal}" "${out_ss_udp:-1}" "${out_ss_uot:-0}"; then
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
                local vless_uuid vless_flow vless_public_key vless_short_id vless_client_fingerprint vless_packet_encoding
                local l_type l_name l_port l_cipher l_password l_user_id l_user_pass l_sni
                local l_hy2_up l_hy2_down l_hy2_ignore l_hy2_obfs l_hy2_obfs_password l_hy2_masquerade l_hy2_mport l_hy2_insecure l_listener_tag
                local l_vless_public_key l_vless_short_id l_vless_flow l_vless_client_fingerprint
                local l_vless_type l_vless_ws_path l_vless_ws_tls l_vless_ws_host l_vless_grpc_service_name
                local -a listener_names=() outbound_names=() outbound_show_names=()

                printf "  ${BOLD}可用入站节点:${PLAIN}\n"
                _separator
                idx=0
                while IFS=$'\x1f' read -r l_type l_name l_port l_cipher l_password l_user_id l_user_pass l_sni \
                    l_hy2_up l_hy2_down l_hy2_ignore l_hy2_obfs l_hy2_obfs_password l_hy2_masquerade l_hy2_mport l_hy2_insecure l_listener_tag \
                    l_vless_public_key l_vless_short_id l_vless_flow l_vless_client_fingerprint \
                    l_tuic_congestion_control l_tuic_alpn l_tuic_udp_relay_mode l_hy2_congestion_control \
                    l_vless_type l_vless_ws_path l_vless_ws_tls l_vless_ws_host l_vless_grpc_service_name; do
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
                    wg_ip wg_ipv6 wg_private_key wg_public_key wg_allowed_ips wg_preshared_key wg_reserved wg_mtu wg_keepalive \
                    vless_uuid vless_flow vless_public_key vless_short_id vless_client_fingerprint vless_packet_encoding; do
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
                        vless)
                            if [[ -n "${sni:-}" ]]; then
                                printf "      [%d] %s (type=vless, %s:%s, sni=%s)\n" "$idx" "$out_show_name" "$server" "$port" "$sni"
                            else
                                printf "      [%d] %s (type=vless, %s:%s)\n" "$idx" "$out_show_name" "$server" "$port"
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
                local vless_uuid vless_flow vless_public_key vless_short_id vless_client_fingerprint vless_packet_encoding
                local l_type l_name l_port l_cipher l_password l_user_id l_user_pass l_sni
                local l_hy2_up l_hy2_down l_hy2_ignore l_hy2_obfs l_hy2_obfs_password l_hy2_masquerade l_hy2_mport l_hy2_insecure l_listener_tag
                local l_vless_public_key l_vless_short_id l_vless_flow l_vless_client_fingerprint
                local l_vless_type l_vless_ws_path l_vless_ws_tls l_vless_ws_host l_vless_grpc_service_name
                local u_name u_pass user_count
                local -a listener_tags=() listener_names=()
                local -a listener_users=() outbound_names=() outbound_show_names=()

                printf "  ${BOLD}可用入站节点:${PLAIN}\n"
                _separator
                idx=0
                while IFS=$'\x1f' read -r l_type l_name l_port l_cipher l_password l_user_id l_user_pass l_sni \
                    l_hy2_up l_hy2_down l_hy2_ignore l_hy2_obfs l_hy2_obfs_password l_hy2_masquerade l_hy2_mport l_hy2_insecure l_listener_tag \
                    l_vless_public_key l_vless_short_id l_vless_flow l_vless_client_fingerprint \
                    l_tuic_congestion_control l_tuic_alpn l_tuic_udp_relay_mode l_hy2_congestion_control \
                    l_vless_type l_vless_ws_path l_vless_ws_tls l_vless_ws_host l_vless_grpc_service_name; do
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
                local -a tuic_usernames=()
                local _tuname
                while IFS= read -r _tuname; do
                    [[ -n "${_tuname:-}" ]] && tuic_usernames+=("$_tuname")
                done < <(_mihomoconf_read_tuic_usernames_by_tag "$config_file" "$user_listener_tag")
                local _tuic_uidx=0 _display_name
                while IFS=$'\x1f' read -r u_name u_pass; do
                    [[ -z "${u_name:-}" ]] && continue
                    listener_users+=("$u_name")
                    idx=$((idx + 1))
                    if (( ${#tuic_usernames[@]} > 0 )); then
                        _display_name="${tuic_usernames[$_tuic_uidx]:-${u_name:0:8}}"
                        _tuic_uidx=$((_tuic_uidx + 1))
                    else
                        _display_name="$u_name"
                    fi
                    printf "      [%d] %s\n" "$idx" "$_display_name"
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
                    wg_ip wg_ipv6 wg_private_key wg_public_key wg_allowed_ips wg_preshared_key wg_reserved wg_mtu wg_keepalive \
                    vless_uuid vless_flow vless_public_key vless_short_id vless_client_fingerprint vless_packet_encoding; do
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
                        vless)
                            if [[ -n "${sni:-}" ]]; then
                                printf "      [%d] %s (type=vless, %s:%s, sni=%s)\n" "$idx" "$out_show_name" "$server" "$port" "$sni"
                            else
                                printf "      [%d] %s (type=vless, %s:%s)\n" "$idx" "$out_show_name" "$server" "$port"
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
                local vless_uuid vless_flow vless_public_key vless_short_id vless_client_fingerprint vless_packet_encoding
                local -a rm_out_names=() rm_out_show_names=() rm_out_tags=()
                while IFS=$'\x1f' read -r out_name type server port cipher username password sni insecure obfs obfs_password mport \
                    wg_ip wg_ipv6 wg_private_key wg_public_key wg_allowed_ips wg_preshared_key wg_reserved wg_mtu wg_keepalive \
                    vless_uuid vless_flow vless_public_key vless_short_id vless_client_fingerprint vless_packet_encoding; do
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
                        vless)
                            if [[ -n "${sni:-}" ]]; then
                                printf "      [%d] %s (type=vless, %s:%s, sni=%s)\n" "$rm_out_idx" "$out_show_name" "$server" "$port" "$sni"
                            else
                                printf "      [%d] %s (type=vless, %s:%s)\n" "$rm_out_idx" "$out_show_name" "$server" "$port"
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
                local -a rule_types=() rule_in_names=() rule_keys=() rule_users=()
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
                local add_mode add_username add_uuid add_password add_overwrite add_result add_action
                local add_count add_prefix add_idx add_suffix add_attempt
                local idx li user_count l_type l_name l_port l_cipher l_password l_user_id l_user_pass l_sni
                local l_hy2_up l_hy2_down l_hy2_ignore l_hy2_obfs l_hy2_obfs_password l_hy2_masquerade l_hy2_mport l_hy2_insecure l_listener_tag
                local l_vless_public_key l_vless_short_id l_vless_flow l_vless_client_fingerprint
                local l_vless_type l_vless_ws_path l_vless_ws_tls l_vless_ws_host
                local u_name u_pass
                local -a add_created_users=() add_created_uuids=() add_created_passwords=()
                local -a add_listener_tags=() add_listener_names=() add_listener_types=() add_listener_ciphers=()

                printf "  ${BOLD}可新增用户的入站节点:${PLAIN}\n"
                _separator
                idx=0
                while IFS=$'\x1f' read -r l_type l_name l_port l_cipher l_password l_user_id l_user_pass l_sni \
                    l_hy2_up l_hy2_down l_hy2_ignore l_hy2_obfs l_hy2_obfs_password l_hy2_masquerade l_hy2_mport l_hy2_insecure l_listener_tag \
                    l_vless_public_key l_vless_short_id l_vless_flow l_vless_client_fingerprint \
                    l_tuic_congestion_control l_tuic_alpn l_tuic_udp_relay_mode l_hy2_congestion_control \
                    l_vless_type l_vless_ws_path l_vless_ws_tls l_vless_ws_host; do
                    [[ -z "${l_name:-}" ]] && continue
                    case "$l_type" in
                        anytls|hysteria2|hy2|tuic|socks|vless|vless-ws) ;;
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
                    _warn "未找到支持 users 的入站节点 (AnyTLS/HY2/TUIC/Socks5/VLESS/VLESS-WS)"
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

                printf "  ${BOLD}创建方式:${PLAIN}\n"
                _menu_pair "1" "单个用户" "可指定用户名/密码" "green" "2" "快速批量生成" "指定数量自动生成" "green"
                read -rp "  选择 [1/2，默认 1]: " add_mode
                add_mode=$(_mihomoconf_trim "${add_mode:-1}")
                case "$add_mode" in
                    1|2) ;;
                    *)
                        _error_no_exit "无效选项，请输入 1 或 2"
                        _press_any_key
                        continue
                        ;;
                esac

                if [[ "$add_mode" == "1" ]]; then
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
                        read -rp "  用户已存在，将更新密码，继续? [Y/n]: " add_overwrite
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

                    add_uuid=""
                    if [[ "$add_listener_type" == "tuic" ]]; then
                        add_uuid=$(_mihomoconf_gen_uuid)
                        _mihomoconf_add_tuic_listener_user "$config_file" "$add_listener_tag" "$add_username" "$add_uuid" "$add_password"
                    elif [[ "$add_listener_type" == "socks" ]]; then
                        _mihomoconf_add_socks_listener_user "$config_file" "$add_listener_tag" "$add_username" "$add_password"
                    elif [[ "$add_listener_type" == "vless" ]]; then
                        add_uuid=$(_mihomoconf_gen_uuid)
                        _mihomoconf_add_vless_listener_user "$config_file" "$add_listener_tag" "$add_username" "$add_uuid" "xtls-rprx-vision"
                    elif [[ "$add_listener_type" == "vless-ws" ]]; then
                        add_uuid=$(_mihomoconf_gen_uuid)
                        _mihomoconf_add_vless_listener_user "$config_file" "$add_listener_tag" "$add_username" "$add_uuid" ""
                    else
                        _mihomoconf_add_or_update_listener_user "$config_file" "$add_listener_tag" "$add_username" "$add_password"
                    fi
                    add_result=$?
                    if [[ "$add_result" -ne 0 ]]; then
                        case "$add_result" in
                            2) _error_no_exit "未找到入站节点: ${add_listener_name}" ;;
                            3) _error_no_exit "入站类型 ${add_listener_type} 不支持 users（仅支持 AnyTLS/HY2/TUIC/Socks5/VLESS/VLESS-WS）" ;;
                            *) _error_no_exit "用户写入失败，请检查配置格式后重试" ;;
                        esac
                        _press_any_key
                        continue
                    fi

                    add_created_users+=("$add_username")
                    add_created_uuids+=("$add_uuid")
                    add_created_passwords+=("$add_password")
                    _info "已${add_action}用户: ${add_listener_name}[user=${add_username}]"
                else
                    read -rp "  快速创建数量 [默认 1]: " add_count
                    add_count=$(_mihomoconf_trim "${add_count:-1}")
                    if ! _is_digit "$add_count" || [[ "$add_count" -le 0 ]]; then
                        _error_no_exit "数量必须是正整数"
                        _press_any_key
                        continue
                    fi
                    read -rp "  用户名前缀 [默认 user]: " add_prefix
                    add_prefix=$(_mihomoconf_trim "${add_prefix:-user}")
                    if [[ -z "$add_prefix" ]] || ! _mihomoconf_is_valid_username "$add_prefix"; then
                        _error_no_exit "用户名前缀无效，仅支持字母/数字/.-_"
                        _press_any_key
                        continue
                    fi

                    for ((add_idx=1; add_idx<=add_count; add_idx++)); do
                        add_attempt=0
                        while true; do
                            add_attempt=$((add_attempt + 1))
                            add_suffix=$(_mihomoconf_gen_uuid | cut -d'-' -f1)
                            add_username="${add_prefix}-${add_idx}-${add_suffix}"
                            if ! _mihomoconf_listener_has_user "$config_file" "$add_listener_tag" "$add_username"; then
                                break
                            fi
                            if (( add_attempt >= 20 )); then
                                _error_no_exit "生成唯一用户名失败，请更换前缀后重试"
                                _press_any_key
                                continue 3
                            fi
                        done

                        if [[ "$add_listener_type" == "shadowsocks" ]]; then
                            add_password=$(_mihomoconf_gen_ss_password_for_cipher "$add_listener_cipher")
                        else
                            add_password=$(_mihomoconf_gen_anytls_password)
                        fi

                        add_uuid=""
                        if [[ "$add_listener_type" == "tuic" ]]; then
                            add_uuid=$(_mihomoconf_gen_uuid)
                            _mihomoconf_add_tuic_listener_user "$config_file" "$add_listener_tag" "$add_username" "$add_uuid" "$add_password"
                        elif [[ "$add_listener_type" == "socks" ]]; then
                            _mihomoconf_add_socks_listener_user "$config_file" "$add_listener_tag" "$add_username" "$add_password"
                        elif [[ "$add_listener_type" == "vless" ]]; then
                            add_uuid=$(_mihomoconf_gen_uuid)
                            _mihomoconf_add_vless_listener_user "$config_file" "$add_listener_tag" "$add_username" "$add_uuid" "xtls-rprx-vision"
                        elif [[ "$add_listener_type" == "vless-ws" ]]; then
                            add_uuid=$(_mihomoconf_gen_uuid)
                            _mihomoconf_add_vless_listener_user "$config_file" "$add_listener_tag" "$add_username" "$add_uuid" ""
                        else
                            _mihomoconf_add_or_update_listener_user "$config_file" "$add_listener_tag" "$add_username" "$add_password"
                        fi
                        add_result=$?
                        if [[ "$add_result" -ne 0 ]]; then
                            case "$add_result" in
                                2) _error_no_exit "未找到入站节点: ${add_listener_name}" ;;
                                3) _error_no_exit "入站类型 ${add_listener_type} 不支持 users（仅支持 AnyTLS/HY2/TUIC/Socks5/VLESS/VLESS-WS）" ;;
                                *) _error_no_exit "用户写入失败，请检查配置格式后重试" ;;
                            esac
                            _press_any_key
                            continue 2
                        fi

                        add_created_users+=("$add_username")
                        add_created_uuids+=("$add_uuid")
                        add_created_passwords+=("$add_password")
                    done

                    _info "已批量新增 ${#add_created_users[@]} 个用户: ${add_listener_name}"
                fi

                if (( ${#add_created_users[@]} > 0 )); then
                    printf "  ${BOLD}新增用户列表:${PLAIN}\n"
                    for add_idx in "${!add_created_users[@]}"; do
                        if [[ -n "${add_created_uuids[$add_idx]:-}" ]]; then
                            printf "    [%d] user=${GREEN}%s${PLAIN} uuid=${GREEN}%s${PLAIN} password=${GREEN}%s${PLAIN}\n" \
                                "$((add_idx + 1))" "${add_created_users[$add_idx]}" "${add_created_uuids[$add_idx]}" "${add_created_passwords[$add_idx]}"
                        else
                            printf "    [%d] user=${GREEN}%s${PLAIN} password=${GREEN}%s${PLAIN}\n" \
                                "$((add_idx + 1))" "${add_created_users[$add_idx]}" "${add_created_passwords[$add_idx]}"
                        fi
                    done
                fi

                _info "可使用 [4] 将用户绑定到指定出口节点"
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
            _info "当前状态: 开启"
        else
            _info "当前状态: 关闭"
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
        if ! _mihomo_reload_or_restart; then
            _warn "自动热重载/重启失败，请检查日志后重试"
        else
            if [[ "$new_pref" == "on" ]]; then
                _success "已开启 Gemini/Google IPv4 定向"
            else
                _success "已关闭 Gemini/Google IPv4 定向"
            fi
        fi
        _press_any_key
    done
}
_merge_dns_lists() {
    local list1="$1"
    local list2="$2"
    local -a merged=()
    
    _contains_item() {
        local target="$1"
        local item
        [[ ${#merged[@]} -eq 0 ]] && return 1
        for item in "${merged[@]}"; do
            if [[ "$item" == "$target" ]]; then
                return 0
            fi
        done
        return 1
    }
    
    # Process list2 (new selections) first to preserve their order and priority
    local -a arr2
    IFS=',' read -r -a arr2 <<< "$list2"
    for item in "${arr2[@]}"; do
        item=$(echo "$item" | xargs)
        [[ -z "$item" ]] && continue
        if ! _contains_item "$item"; then
            merged+=("$item")
        fi
    done
    
    # Process list1 (existing settings) next, appending any other unique items
    local -a arr1
    IFS=',' read -r -a arr1 <<< "$list1"
    for item in "${arr1[@]}"; do
        item=$(echo "$item" | xargs)
        [[ -z "$item" ]] && continue
        [[ "$item" == "system" ]] && continue
        if ! _contains_item "$item"; then
            merged+=("$item")
        fi
    done
    
    if [[ "${#merged[@]}" -eq 0 ]]; then
        echo "system"
    else
        (IFS=,; echo "${merged[*]}")
    fi
}

_mihomo_dns_ask_append_or_overwrite() {
    local config_file="$1"
    local new_dns_csv="$2"
    
    # Read existing DNS
    local current_dns=""
    local -a current_dns_arr=()
    while read -r line; do
        [[ -n "$line" ]] && current_dns_arr+=("$line")
    done < <(_mihomoconf_dns_get "$config_file")
    current_dns=$(IFS=,; echo "${current_dns_arr[*]}")
    
    if [[ -z "$current_dns" || "$current_dns" == "system" ]]; then
        echo "$new_dns_csv"
        return 0
    fi
    
    printf "\n" >&2
    printf "${CYAN}• ${PLAIN}当前已配置的 DNS: %s\n" "$current_dns" >&2
    printf "${CYAN}• ${PLAIN}您选择的新 DNS: %s\n" "$new_dns_csv" >&2
    
    local confirm
    printf "  是否追加到现有的 DNS 列表中? (输入 Y 追加，输入 N 覆盖/覆盖现有列表) [Y/n]: " >&2
    read -r confirm
    confirm=$(_mihomoconf_trim "${confirm:-Y}")
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        echo "$new_dns_csv"
    else
        _merge_dns_lists "$current_dns" "$new_dns_csv"
    fi
}

_get_domestic_dns_url() {
    local pid="$1" proto="$2"
    case "$pid" in
        1) # AliDNS
            case "$proto" in
                2) echo "tls://dns.alidns.com" ;;
                3) echo "quic://dns.alidns.com" ;;
                4) echo "223.5.5.5" ;;
                *) echo "https://dns.alidns.com/dns-query" ;;
            esac
            ;;
        2) # DNSPod
            case "$proto" in
                2) echo "tls://dot.pub" ;;
                3)
                    _warn "DNSPod 不支持 DoQ 协议，已切换为 DoH" >&2
                    echo "https://doh.pub/dns-query"
                    ;;
                4) echo "119.29.29.29" ;;
                *) echo "https://doh.pub/dns-query" ;;
            esac
            ;;
        3) # ByteDance DNS
            case "$proto" in
                2) echo "tls://dns.volcengine.com" ;;
                3)
                    _warn "ByteDance DNS 不支持 DoQ 协议，已切换为 DoH" >&2
                    echo "https://dns.volcengine.com/dns-query"
                    ;;
                4) echo "180.184.1.1" ;;
                *) echo "https://dns.volcengine.com/dns-query" ;;
            esac
            ;;
        4) # 360 Secure DNS
            case "$proto" in
                2) echo "tls://dot.360.cn" ;;
                3)
                    _warn "360 DNS 不支持 DoQ 协议，已切换为 DoH" >&2
                    echo "https://doh.360.cn/dns-query"
                    ;;
                4) echo "101.226.4.6" ;;
                *) echo "https://doh.360.cn/dns-query" ;;
            esac
            ;;
        5) # Baidu DNS
            if [[ "$proto" -ne 4 ]]; then
                _warn "Baidu DNS 仅支持 UDP 协议，已切换为 UDP" >&2
            fi
            echo "180.76.76.76"
            ;;
        6) # 114DNS
            if [[ "$proto" -ne 4 ]]; then
                _warn "114DNS 仅支持 UDP 协议，已切换为 UDP" >&2
            fi
            echo "114.114.114.114"
            ;;
    esac
}

_get_foreign_dns_url() {
    local pid="$1" proto="$2"
    case "$pid" in
        1) # Cloudflare
            case "$proto" in
                2) echo "tls://cloudflare-dns.com" ;;
                3)
                    _warn "Cloudflare 不支持 DoQ 协议，已切换为 DoH" >&2
                    echo "https://cloudflare-dns.com/dns-query"
                    ;;
                4) echo "1.1.1.1" ;;
                *) echo "https://cloudflare-dns.com/dns-query" ;;
            esac
            ;;
        2) # Google
            case "$proto" in
                2) echo "tls://dns.google" ;;
                3)
                    _warn "Google DNS 不支持 DoQ 协议，已切换为 DoH" >&2
                    echo "https://dns.google/dns-query"
                    ;;
                4) echo "8.8.8.8" ;;
                *) echo "https://dns.google/dns-query" ;;
            esac
            ;;
        3) # AdGuard
            case "$proto" in
                2) echo "tls://dns.adguard-dns.com" ;;
                3) echo "quic://dns.adguard-dns.com" ;;
                4) echo "94.140.14.14" ;;
                *) echo "https://dns.adguard-dns.com/dns-query" ;;
            esac
            ;;
        4) # Quad9
            case "$proto" in
                2) echo "tls://dns.quad9.net" ;;
                3) echo "quic://dns.quad9.net" ;;
                4) echo "9.9.9.9" ;;
                *) echo "https://dns.quad9.net/dns-query" ;;
            esac
            ;;
        5) # NextDNS
            case "$proto" in
                2) echo "tls://dns.nextdns.io" ;;
                3) echo "quic://dns.nextdns.io" ;;
                4) echo "45.90.28.0" ;;
                *) echo "https://dns.nextdns.io" ;;
            esac
            ;;
        6) # OpenDNS
            case "$proto" in
                2) echo "tls://dns.opendns.com" ;;
                3)
                    _warn "OpenDNS 不支持 DoQ 协议，已切换为 DoH" >&2
                    echo "https://doh.opendns.com/dns-query"
                    ;;
                4) echo "208.67.222.222" ;;
                *) echo "https://doh.opendns.com/dns-query" ;;
            esac
            ;;
    esac
}

_mihomo_dns_restart_prompt() {
    if ! _mihomo_reload_or_restart; then
        _warn "自动应用失败，请检查日志后重试"
    else
        _success "DNS 配置已生效"
    fi
    _press_any_key
}

_mihomo_dns_test_availability() {
    local url="$1"
    local host=""
    local port=""

    if [[ "$url" == https://* ]]; then
        # DoH: Use curl (test HTTP/HTTPS connection)
        if curl -sI --connect-timeout 2 --max-time 3 "$url" >/dev/null 2>&1; then
            return 0
        else
            return 1
        fi
    elif [[ "$url" == tls://* ]]; then
        # DoT: Use /dev/tcp connection test
        host="${url#tls://}"
        host="${host%%/*}"
        port="853"
        if [[ "$host" == *:* ]]; then
            port="${host##*:}"
            host="${host%%:*}"
        fi
        if timeout 2 bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null; then
            return 0
        else
            return 1
        fi
    elif [[ "$url" == quic://* ]]; then
        # DoQ: QUIC is UDP, check if host resolves or is pingable
        host="${url#quic://}"
        host="${host%%/*}"
        if [[ "$host" == *:* ]]; then
            host="${host%%:*}"
        fi
        if getent hosts "$host" >/dev/null 2>&1 || nslookup "$host" >/dev/null 2>&1 || ping -c 1 -W 2 "$host" >/dev/null 2>&1; then
            return 0
        else
            return 1
        fi
    else
        # UDP IP address (or domain)
        host="$url"
        port="53"
        if [[ "$host" == *:* ]]; then
            port="${host##*:}"
            host="${host%%:*}"
        fi

        # Check if dig or nslookup is available to query DNS directly
        if command -v dig >/dev/null 2>&1; then
            if dig "@$host" -p "$port" cloudflare.com +time=2 +tries=1 >/dev/null 2>&1; then
                return 0
            fi
        elif command -v nslookup >/dev/null 2>&1; then
            if nslookup cloudflare.com "$host" >/dev/null 2>&1; then
                return 0
            fi
        fi

        # Fallback: test TCP port 53 or ping
        if timeout 2 bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null; then
            return 0
        elif ping -c 1 -W 2 "$host" >/dev/null 2>&1; then
            return 0
        fi
        return 1
    fi
}

_mihomo_dns_process_and_set() {
    local config_file="$1"
    local dns_list_str="$2"

    # Split by comma into array
    local -a dns_arr
    IFS=',' read -r -a dns_arr <<< "$dns_list_str"

    if [[ "${#dns_arr[@]}" -eq 0 ]]; then
        _error_no_exit "没有检测到任何 DNS 地址"
        return 1
    fi

    _info "正在对 DNS 服务器进行可用性测试 (请稍候)..."
    _separator

    local -a ok_dns=()
    local -a fail_dns=()

    for dns in "${dns_arr[@]}"; do
        dns=$(echo "$dns" | xargs) # trim whitespace
        [[ -z "$dns" ]] && continue

        printf "  • %-50s " "$dns"
        if _mihomo_dns_test_availability "$dns"; then
            printf "[  ${GREEN}可用${PLAIN}  ]\n"
            ok_dns+=("$dns")
        else
            printf "[ ${RED}不可用/超时${PLAIN} ]\n"
            fail_dns+=("$dns")
        fi
    done
    _separator

    local final_dns_list=""
    if [[ "${#ok_dns[@]}" -eq 0 ]]; then
        _warn "警告: 所有选中的 DNS 节点均测试失败！这可能是由于当前服务器完全无法连接这些服务商，或者是您的服务器当前网络中断。"
        local confirm
        read -rp "  是否依然强制应用这些 DNS 配置？[y/N]: " confirm
        if [[ "$confirm" =~ ^[yY](es)?$ ]]; then
            final_dns_list="$dns_list_str"
        else
            _info "配置应用已取消。"
            _press_any_key
            return 1
        fi
    elif [[ "${#fail_dns[@]}" -gt 0 ]]; then
        _warn "检测到部分 DNS 服务器在当前网络下不可用。"
        local choice
        read -rp "  是否仅保留测试成功的 DNS 服务器？(如果选择否，将写入全部选择) [Y/n]: " choice
        if [[ -z "$choice" || "$choice" =~ ^[yY](es)?$ ]]; then
            final_dns_list=$(IFS=,; echo "${ok_dns[*]}")
        else
            final_dns_list="$dns_list_str"
        fi
    else
        _success "选中的 DNS 服务器均可用"
        final_dns_list="$dns_list_str"
    fi

    if [[ -n "$final_dns_list" ]]; then
        _mihomoconf_dns_set "$config_file" "$final_dns_list"
        _success "DNS 成功配置为: $final_dns_list"
        _mihomo_dns_restart_prompt
        return 0
    else
        _info "未写入任何配置。"
        _press_any_key
        return 1
    fi
}

_mihomo_dns_domestic_menu() {
    local config_file="$1"
    while true; do
        _header "国内公共 DNS"
        printf "  ${BOLD}请选择要启用的公共 DNS 服务商 (可输入多个，空格分隔，如 '1 2'):${PLAIN}\n"
        _separator
        printf "    ${GREEN}1${PLAIN}) AliDNS (阿里)         ${DIM}(支持 DoH/DoT/DoQ/UDP)${PLAIN}\n"
        printf "    ${GREEN}2${PLAIN}) DNSPod (腾讯)         ${DIM}(支持 DoH/DoT/UDP)${PLAIN}\n"
        printf "    ${GREEN}3${PLAIN}) Volcengine DNS (字节)   ${DIM}(支持 DoH/DoT/UDP)${PLAIN}\n"
        printf "    ${GREEN}4${PLAIN}) 360 Secure DNS        ${DIM}(支持 DoH/DoT/UDP)${PLAIN}\n"
        printf "    ${GREEN}5${PLAIN}) Baidu DNS (百度)      ${DIM}(仅支持 UDP: 180.76.76.76)${PLAIN}\n"
        printf "    ${GREEN}6${PLAIN}) 114DNS               ${DIM}(仅支持 UDP: 114.114.114.114)${PLAIN}\n"
        printf "    ${GREEN}0${PLAIN}) 返回上一级\n"
        _separator
        local choices
        read -rp "  选择服务商: " -a choices
        if [[ "${#choices[@]}" -eq 0 ]]; then
            _warn "未选择任何服务商"
            sleep 1
            continue
        fi
        if [[ "${choices[0]}" == "0" ]]; then
            return
        fi

        local has_valid=0
        for ch in "${choices[@]}"; do
            if [[ "$ch" =~ ^[1-6]$ ]]; then
                has_valid=1
            fi
        done
        if [[ "$has_valid" -eq 0 ]]; then
            _error_no_exit "没有有效选择，请重新选择"
            sleep 1
            continue
        fi

        # Protocol choices
        printf "\n"
        printf "  ${BOLD}请选择 DNS 协议类型:${PLAIN}\n"
        _separator
        printf "    ${GREEN}1${PLAIN}) DoH (DNS-over-HTTPS, 默认)\n"
        printf "    ${GREEN}2${PLAIN}) DoT (DNS-over-TLS)\n"
        printf "    ${GREEN}3${PLAIN}) DoQ (DNS-over-QUIC)\n"
        printf "    ${GREEN}4${PLAIN}) 普通 UDP\n"
        _separator
        local proto_choice
        read -rp "  选择协议 [1-4, 默认 1]: " proto_choice
        if [[ -z "$proto_choice" ]]; then
            proto_choice="1"
        fi

        local dns_urls=()
        for ch in "${choices[@]}"; do
            if [[ "$ch" =~ ^[1-6]$ ]]; then
                local url
                url=$(_get_domestic_dns_url "$ch" "$proto_choice")
                if [[ -n "$url" ]]; then
                    dns_urls+=("$url")
                fi
            fi
        done

        if [[ "${#dns_urls[@]}" -eq 0 ]]; then
            _error_no_exit "没有解析出任何 DNS 地址，请重新选择"
            sleep 1
            continue
        fi

        local dns_list_str
        dns_list_str=$(IFS=,; echo "${dns_urls[*]}")
        
        # Ask append or overwrite
        local final_list_str
        final_list_str=$(_mihomo_dns_ask_append_or_overwrite "$config_file" "$dns_list_str")
        
        if _mihomo_dns_process_and_set "$config_file" "$final_list_str"; then
            return
        fi
    done
}

_mihomo_dns_foreign_menu() {
    local config_file="$1"
    while true; do
        _header "国外公共 DNS"
        printf "  ${BOLD}请选择要启用的公共 DNS 服务商 (可输入多个，空格分隔，如 '1 2'):${PLAIN}\n"
        _separator
        printf "    ${GREEN}1${PLAIN}) Cloudflare DNS  ${DIM}(支持 DoH/DoT/UDP)${PLAIN}\n"
        printf "    ${GREEN}2${PLAIN}) Google DNS      ${DIM}(支持 DoH/DoT/UDP)${PLAIN}\n"
        printf "    ${GREEN}3${PLAIN}) AdGuard DNS     ${DIM}(支持 DoH/DoT/DoQ/UDP)${PLAIN}\n"
        printf "    ${GREEN}4${PLAIN}) Quad9 DNS       ${DIM}(支持 DoH/DoT/DoQ/UDP)${PLAIN}\n"
        printf "    ${GREEN}5${PLAIN}) NextDNS         ${DIM}(支持 DoH/DoT/DoQ/UDP)${PLAIN}\n"
        printf "    ${GREEN}6${PLAIN}) OpenDNS         ${DIM}(支持 DoH/DoT/UDP)${PLAIN}\n"
        printf "    ${GREEN}0${PLAIN}) 返回上一级\n"
        _separator
        local choices
        read -rp "  选择服务商: " -a choices
        if [[ "${#choices[@]}" -eq 0 ]]; then
            _warn "未选择任何服务商"
            sleep 1
            continue
        fi
        if [[ "${choices[0]}" == "0" ]]; then
            return
        fi

        local has_valid=0
        for ch in "${choices[@]}"; do
            if [[ "$ch" =~ ^[1-6]$ ]]; then
                has_valid=1
            fi
        done
        if [[ "$has_valid" -eq 0 ]]; then
            _error_no_exit "没有有效选择，请重新选择"
            sleep 1
            continue
        fi

        # Protocol choices
        printf "\n"
        printf "  ${BOLD}请选择 DNS 协议类型:${PLAIN}\n"
        _separator
        printf "    ${GREEN}1${PLAIN}) DoH (DNS-over-HTTPS, 默认)\n"
        printf "    ${GREEN}2${PLAIN}) DoT (DNS-over-TLS)\n"
        printf "    ${GREEN}3${PLAIN}) DoQ (DNS-over-QUIC)\n"
        printf "    ${GREEN}4${PLAIN}) 普通 UDP\n"
        _separator
        local proto_choice
        read -rp "  选择协议 [1-4, 默认 1]: " proto_choice
        if [[ -z "$proto_choice" ]]; then
            proto_choice="1"
        fi

        local dns_urls=()
        for ch in "${choices[@]}"; do
            if [[ "$ch" =~ ^[1-6]$ ]]; then
                local url
                url=$(_get_foreign_dns_url "$ch" "$proto_choice")
                if [[ -n "$url" ]]; then
                    dns_urls+=("$url")
                fi
            fi
        done

        if [[ "${#dns_urls[@]}" -eq 0 ]]; then
            _error_no_exit "没有解析出任何 DNS 地址，请重新选择"
            sleep 1
            continue
        fi

        local dns_list_str
        dns_list_str=$(IFS=,; echo "${dns_urls[*]}")
        
        # Ask append or overwrite
        local final_list_str
        final_list_str=$(_mihomo_dns_ask_append_or_overwrite "$config_file" "$dns_list_str")
        
        if _mihomo_dns_process_and_set "$config_file" "$final_list_str"; then
            return
        fi
    done
}

_mihomo_dns_custom_input() {
    local config_file="$1"
    _header "自定义 DNS 配置"
    _info "支持以下格式:"
    printf "    - 普通 UDP: ${GREEN}223.5.5.5${PLAIN} 或 ${GREEN}8.8.8.8:53${PLAIN}\n"
    printf "    - DoH 域名: ${GREEN}https://dns.alidns.com/dns-query${PLAIN}\n"
    printf "    - DoT 域名: ${GREEN}tls://dns.google${PLAIN}\n"
    printf "    - DoQ 域名: ${GREEN}quic://dns.adguard-dns.com${PLAIN}\n"
    _separator
    _info "多个地址请用 ${YELLOW}逗号${PLAIN} 或 ${YELLOW}空格${PLAIN} 分隔。"
    local raw_input formatted_input
    read -rp "  请输入 DNS 列表: " raw_input
    formatted_input=$(echo "$raw_input" | tr ' ' ',' | tr -s ',' | sed 's/^,//;s/,$//')
    if [[ -z "$formatted_input" ]]; then
        _warn "输入为空，已取消"
        _press_any_key
        return
    fi
    
    # Ask append or overwrite
    local final_list_str
    final_list_str=$(_mihomo_dns_ask_append_or_overwrite "$config_file" "$formatted_input")
    
    _mihomo_dns_process_and_set "$config_file" "$final_list_str"
}

_mihomo_dns_bootstrap_menu() {
    local config_file="$1"
    while true; do
        _header "底层 DNS 设置 (default-nameserver)"
        _info "作用: 用于解析 DoH/DoT/DoQ 加密 DNS 的域名"
        _info "当前底层 DNS 列表:"
        local bootstrap_list=()
        local idx=1
        while read -r line; do
            [[ -n "$line" ]] && bootstrap_list+=("$line")
        done < <(_mihomoconf_bootstrap_dns_get "$config_file")
        
        if [ "${#bootstrap_list[@]}" -eq 0 ]; then
            printf "    ${YELLOW}无 (未配置，将默认使用系统 DNS 或者是预置引导)${PLAIN}\n"
        else
            for bs_item in "${bootstrap_list[@]}"; do
                printf "    ${GREEN}%d.${PLAIN} %s\n" "$idx" "$bs_item"
                idx=$((idx + 1))
            done
        fi
        _separator
        _menu_pair "1" "使用国内常用底层 DNS" "阿里 223.5.5.5, 腾讯 119.29.29.29" "green" \
                   "2" "使用国外常用底层 DNS" "Cloudflare 1.1.1.1, Google 8.8.8.8" "green"
        _menu_pair "3" "自定义底层 DNS" "支持手动输入多个，空格或逗号分隔" "yellow" \
                   "4" "清空底层 DNS" "从配置文件中移除 default-nameserver 块" "red"
        _menu_item "0" "返回上级菜单" "" "red"
        _separator
        
        local ch
        read -rp "  选择 [0-4]: " ch
        case "$ch" in
            1)
                _mihomoconf_bootstrap_dns_set "$config_file" "223.5.5.5,119.29.29.29"
                _success "底层 DNS 已配置为: 223.5.5.5, 119.29.29.29"
                _mihomo_dns_restart_prompt
                ;;
            2)
                _mihomoconf_bootstrap_dns_set "$config_file" "1.1.1.1,8.8.8.8"
                _success "底层 DNS 已配置为: 1.1.1.1, 8.8.8.8"
                _mihomo_dns_restart_prompt
                ;;
            3)
                printf "\n"
                _info "请输入底层 DNS (仅支持普通 IP 地址，多个用空格或逗号分隔):"
                local raw_input formatted_input
                read -rp "  请输入: " raw_input
                formatted_input=$(echo "$raw_input" | tr ' ' ',' | tr -s ',' | sed 's/^,//;s/,$//')
                if [[ -z "$formatted_input" ]]; then
                    _warn "输入为空，已取消"
                    _press_any_key
                    continue
                fi
                _mihomoconf_bootstrap_dns_set "$config_file" "$formatted_input"
                _success "底层 DNS 已配置为: $formatted_input"
                _mihomo_dns_restart_prompt
                ;;
            4)
                _mihomoconf_bootstrap_dns_set "$config_file" ""
                _success "已清除底层 DNS 配置 (已从配置中完全删除 default-nameserver 块)"
                _mihomo_dns_restart_prompt
                ;;
            0)
                return
                ;;
            *)
                _error_no_exit "无效选项"
                sleep 1
                ;;
        esac
    done
}

_mihomo_dns_manage() {
    local config_file="$_MIHOMOCONF_CONFIG_FILE"
    if [[ ! -f "$config_file" ]]; then
        _error_no_exit "未找到配置文件: ${config_file}"
        _info "请先在 Mihomo 菜单中生成基础配置"
        _press_any_key
        return
    fi

    while true; do
        _header "Mihomo DNS 设置"
        _info "配置文件: ${config_file}"
        printf "\n"
        printf "  ${BOLD}当前 DNS 服务器列表 (nameserver):${PLAIN}\n"
        local dns_list=()
        local idx=1
        while read -r line; do
            [[ -n "$line" ]] && dns_list+=("$line")
        done < <(_mihomoconf_dns_get "$config_file")

        if [ "${#dns_list[@]}" -eq 0 ]; then
            printf "    ${YELLOW}无 (未配置或解析失败)${PLAIN}\n"
        else
            for dns_item in "${dns_list[@]}"; do
                printf "    ${GREEN}%d.${PLAIN} %s\n" "$idx" "$dns_item"
                idx=$((idx + 1))
            done
        fi
        
        printf "\n"
        printf "  ${BOLD}当前底层 DNS 列表 (default-nameserver):${PLAIN}\n"
        local bootstrap_list=()
        local bs_idx=1
        while read -r line; do
            [[ -n "$line" ]] && bootstrap_list+=("$line")
        done < <(_mihomoconf_bootstrap_dns_get "$config_file")

        if [ "${#bootstrap_list[@]}" -eq 0 ]; then
            printf "    ${YELLOW}无 (未配置，将默认使用系统 DNS)${PLAIN}\n"
        else
            for bs_item in "${bootstrap_list[@]}"; do
                printf "    ${GREEN}%d.${PLAIN} %s\n" "$bs_idx" "$bs_item"
                bs_idx=$((bs_idx + 1))
            done
        fi
        _separator
        _menu_pair "1" "添加/启用国内公共 DNS" "腾讯/阿里/火山等 (多协议选择)" "green" \
                   "2" "添加/启用国外公共 DNS" "Google/Cloudflare/AdGuard" "green"
        _menu_pair "3" "添加自定义 DNS 列表" "支持手动输入多个/可追加或覆盖" "yellow" \
                   "4" "配置底层 DNS 设置" "用于解析加密 DNS 的 nameserver 域名" "cyan"
        _menu_item "5" "重置为系统默认 (system)" "重置 nameserver 为 system" "yellow"
        _menu_item "0" "返回上级菜单" "" "red"
        _separator

        local ch
        read -rp "  选择 [0-5]: " ch
        case "$ch" in
            1)
                _mihomo_dns_domestic_menu "$config_file"
                ;;
            2)
                _mihomo_dns_foreign_menu "$config_file"
                ;;
            3)
                _mihomo_dns_custom_input "$config_file"
                ;;
            4)
                _mihomo_dns_bootstrap_menu "$config_file"
                ;;
            5)
                _mihomoconf_dns_set "$config_file" "system"
                _info "DNS 重置为系统默认 (system)"
                _mihomo_dns_restart_prompt
                ;;
            0)
                return
                ;;
            *)
                _error_no_exit "无效选项"
                sleep 1
                ;;
        esac
    done
}

_mihomo_manage_screen() {
    _header "Mihomo 管理"
    local config_dir="$_MIHOMOCONF_CONFIG_DIR"
    local config_file="$_MIHOMOCONF_CONFIG_FILE"

    local mihomo_ver="未安装"
    local mihomo_status="未运行"
    local mihomo_status_tone="red"
    local config_status="不存在"
    local config_tone="yellow"

    if command -v mihomo >/dev/null 2>&1; then
        local ver
        ver=$(mihomo -v 2>/dev/null | head -1)
        mihomo_ver="${ver:-未知}"
        local pid
        pid=$(_mihomo_pid 2>/dev/null || true)
        if [[ -n "$pid" ]]; then
            mihomo_status="运行中 (PID: $pid)"
            mihomo_status_tone="green"
        fi
    fi

    if [[ -f "$config_file" ]]; then
        config_status="已存在"
        config_tone="green"
    fi

    printf "  ${BOLD}状态信息${PLAIN}\n"
    _separator
    _status_kv_pair "版本" "$mihomo_ver" "dim" 8 "状态" "$mihomo_status" "$mihomo_status_tone" 8
    _status_kv_pair "配置" "$config_status" "$config_tone" 8 "目录" "$config_dir" "dim" 8
    _status_kv_pair "文件" "$config_file" "dim" 8 "" "" "" 8

    _separator
    _menu_pair "1" "安装/更新 Mihomo" "" "green" "2" "生成配置" "Shadowsocks / AnyTLS / HY2" "green"
    _menu_pair "3" "配置自启并启动" "" "green" "4" "重启 Mihomo" "" "green"
    _menu_pair "5" "查看日志" "" "green" "6" "读取配置并生成节点" "支持仅输出链接" "green"
    _menu_pair "7" "出口管理" "支持链式代理" "green" "8" "出站分流规则" "检索规则/优先级" "green"
    _menu_pair "9" "DNS 设置" "支持 DoH/DoT/DoQ/UDP" "green" "10" "定时自动更新" "检查新版本" "green"
    _menu_pair "11" "卸载 Mihomo" "停止并清理" "yellow" "0" "返回主菜单" "" "red"
    _separator
}

_mihomo_manage() {
    while true; do
        _ui_print_screen _mihomo_manage_screen

        local choice
        read -rp "  ${CYAN}➜${PLAIN}  选择 [0-11]: " choice
        case "$choice" in
            1) _mihomo_setup ;;
            2) _mihomoconf_setup ;;
            3) _mihomo_enable ;;
            4) _mihomo_restart ;;
            5) _mihomo_log ;;
            6) _mihomo_read_config ;;
            7) _mihomo_chain_proxy_manage ;;
            8) _mihomo_outbound_rule_manage ;;
            9) _mihomo_dns_manage ;;
            10) _mihomo_auto_update_manage ;;
            11) _mihomo_uninstall ;;
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
        apt-get update -qq || true
        apt-get install -y -qq iperf3
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

_iperf3_port_in_use() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        if readlink -f "$(command -v ss)" 2>/dev/null | grep -q busybox \
            || ss --help 2>&1 | head -1 | grep -qi busybox; then
            ss -tln 2>/dev/null | awk -v p="$port" '
                /^Netid/ || /^State/ || /^Proto/ { next }
                {
                    for (i = 1; i <= NF; i++) {
                        n = split($i, arr, ":")
                        if (n >= 2 && arr[n] == p) { exit 0 }
                    }
                }
                END { exit 1 }
            '
            return $?
        fi
        ss -tlnH "sport = :${port}" 2>/dev/null | grep -q .
        return $?
    fi
    if command -v netstat >/dev/null 2>&1; then
        netstat -ltun 2>/dev/null | awk -v p="$port" '
            {
                addr = $4
                sub(/%[[:alnum:]_.-]+$/, "", addr)
                split(addr, arr, ":")
                if (arr[length(arr)] == p) { found=1; exit }
            }
            END { exit !found }
        '
        return $?
    fi
    if command -v lsof >/dev/null 2>&1; then
        if ! (lsof -h 2>&1 | grep -q -i busybox || lsof --help 2>&1 | grep -q -i busybox); then
            lsof -ti :"$port" >/dev/null 2>&1
            return $?
        fi
    fi
    return 1
}

_iperf3_check_port() {
    local port="$1"
    local pid=""
    if command -v ss >/dev/null 2>&1; then
        if readlink -f "$(command -v ss)" 2>/dev/null | grep -q busybox \
            || ss --help 2>&1 | head -1 | grep -qi busybox; then
            # BusyBox ss: detect port via simple listing, get PID via fuser
            if ss -tln 2>/dev/null | awk -v p="$port" '
                /^Netid/ || /^State/ || /^Proto/ { next }
                {
                    for (i = 1; i <= NF; i++) {
                        n = split($i, arr, ":")
                        if (n >= 2 && arr[n] == p) { found=1; exit }
                    }
                }
                END { exit !found }
            '; then
                pid=$(fuser "$port/tcp" 2>/dev/null | tr -d ' ' || true)
                pid="${pid%%[[:space:]]*}"
            fi
        else
            pid="$(ss -tlnp "sport = :$port" 2>/dev/null | awk 'NR>1{match($0,/pid=([0-9]+)/,m); if(m[1]) print m[1]}' | head -1)"
        fi
    elif command -v netstat >/dev/null 2>&1; then
        local ns_line
        ns_line=$(netstat -ltunp 2>/dev/null | awk -v p="$port" '
            {
                addr = $4
                sub(/%[[:alnum:]_.-]+$/, "", addr)
                split(addr, arr, ":")
                if (arr[length(arr)] == p) { print; exit }
            }
        ')
        if [[ -n "$ns_line" ]]; then
            local last_col
            last_col=$(echo "$ns_line" | awk '{print $NF}')
            if [[ "$last_col" =~ ^[0-9]+/ ]]; then
                pid="${last_col%%/*}"
            fi
        fi
        if [[ -z "$pid" ]] && command -v fuser >/dev/null 2>&1; then
            pid=$(fuser "$port/tcp" 2>/dev/null | tr -d ' ' || true)
            pid="${pid%%[[:space:]]*}"
        fi
    elif command -v lsof >/dev/null 2>&1; then
        if ! (lsof -h 2>&1 | grep -q -i busybox || lsof --help 2>&1 | grep -q -i busybox); then
            pid="$(lsof -ti :"$port" 2>/dev/null || true)"
        fi
    fi

    if [[ -z "$pid" ]]; then
        if ! command -v ss >/dev/null 2>&1 && ! command -v netstat >/dev/null 2>&1 && { ! command -v lsof >/dev/null 2>&1 || lsof -h 2>&1 | grep -q -i busybox || lsof --help 2>&1 | grep -q -i busybox; }; then
            _warn "lsof、ss 和 netstat 均不可用，无法检测端口占用"
        fi
        return 0
    fi

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
            if _iperf3_port_in_use "$port"; then
                kill -9 "$pid" 2>/dev/null || true
                sleep 1
            fi
            if _iperf3_port_in_use "$port"; then
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

    printf "  ${BOLD}选择操作${PLAIN}\n"
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

# --- 7. Ookla Speedtest CLI 安装 ---

_speedtest_prompt_yes_default() {
    local prompt="$1" answer
    read -rp "  ${prompt} [Y/n]: " answer
    [[ ! "$answer" =~ ^[Nn] ]]
}

_speedtest_run_timeout() {
    local seconds="${1:-60}"
    shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$seconds" "$@"
    else
        "$@"
    fi
}

_speedtest_ensure_cmd_available() {
    local cmd="$1" pkg="${2:-$1}"

    if command -v "$cmd" >/dev/null 2>&1; then
        return 0
    fi

    _warn "未检测到 ${cmd}，尝试安装 ${pkg}..."
    if command -v apt-get >/dev/null 2>&1; then
        _speedtest_run_timeout 45 env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none NEEDRESTART_MODE=a \
            apt-get update -qq >/dev/null 2>&1 || true
        _speedtest_run_timeout 60 env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none NEEDRESTART_MODE=a \
            apt-get install -y -qq "$pkg" >/dev/null 2>&1 || true
    elif command -v dnf >/dev/null 2>&1; then
        _speedtest_run_timeout 60 dnf install -y "$pkg" >/dev/null 2>&1 || true
    elif command -v yum >/dev/null 2>&1; then
        _speedtest_run_timeout 60 yum install -y "$pkg" >/dev/null 2>&1 || true
    elif command -v pacman >/dev/null 2>&1; then
        _speedtest_run_timeout 60 pacman -Sy --noconfirm "$pkg" >/dev/null 2>&1 || true
    elif command -v apk >/dev/null 2>&1; then
        _speedtest_run_timeout 45 apk add --no-cache "$pkg" >/dev/null 2>&1 || true
    elif command -v zypper >/dev/null 2>&1; then
        _speedtest_run_timeout 60 zypper install -y "$pkg" >/dev/null 2>&1 || true
    elif command -v pkg >/dev/null 2>&1; then
        _speedtest_run_timeout 60 pkg install -y "$pkg" >/dev/null 2>&1 || true
    fi

    if ! command -v "$cmd" >/dev/null 2>&1; then
        _error_no_exit "缺少 ${cmd}，自动安装超时或失败，请先手动安装后重试"
        return 1
    fi
    return 0
}

_speedtest_install_file() {
    local src="$1" dst="$2" mode="${3:-0755}" dst_dir
    dst_dir="$(dirname "$dst")"
    mkdir -p "$dst_dir" || return 1

    if command -v install >/dev/null 2>&1; then
        install -m "$mode" "$src" "$dst" || return 1
    else
        cp "$src" "$dst" || return 1
        chmod "$mode" "$dst" || return 1
    fi
}

_speedtest_cleanup_deb_conflicts() {
    local old_repo="/etc/apt/sources.list.d/speedtest.list"
    if [[ -f "$old_repo" ]]; then
        local backup="${old_repo}.bak.$(date +%Y%m%d%H%M%S)"
        mv "$old_repo" "$backup"
        _info "已备份旧 Bintray APT 源: ${backup}"
        _speedtest_run_timeout 45 env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none NEEDRESTART_MODE=a \
            apt-get update -qq >/dev/null 2>&1 || true
    fi

    local pc_repo="/etc/apt/sources.list.d/ookla_speedtest-cli.list"
    if [[ -f "$pc_repo" ]]; then
        local pc_backup="${pc_repo}.bak.$(date +%Y%m%d%H%M%S)"
        mv "$pc_repo" "$pc_backup"
        _info "已备份可能失效的 Ookla Packagecloud APT 源: ${pc_backup}"
        _speedtest_run_timeout 45 env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none NEEDRESTART_MODE=a \
            apt-get update -qq >/dev/null 2>&1 || true
    fi

    if command -v dpkg >/dev/null 2>&1 && dpkg -s speedtest-cli >/dev/null 2>&1; then
        _warn "检测到非官方 speedtest-cli 包，可能与 Ookla 官方 speedtest 冲突"
        if _speedtest_prompt_yes_default "移除 speedtest-cli"; then
            _speedtest_run_timeout 60 env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none NEEDRESTART_MODE=a \
                apt-get remove -y speedtest-cli || return 1
        else
            _warn "已保留 speedtest-cli，后续安装可能失败"
        fi
    fi
    return 0
}

_speedtest_install_deb_repo() {
    _info "使用 Ookla 官方 APT 仓库安装..."
    _speedtest_ensure_cmd_available curl curl || return 1
    _speedtest_cleanup_deb_conflicts || return 1

    _speedtest_run_timeout 45 env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none NEEDRESTART_MODE=a \
        apt-get update -qq >/dev/null 2>&1 || true
    _speedtest_run_timeout 60 env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none NEEDRESTART_MODE=a \
        apt-get install -y -qq curl ca-certificates >/dev/null 2>&1 || true
    if ! _speedtest_run_timeout 60 bash -c 'curl -fsSL --connect-timeout 10 --max-time 45 https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash'; then
        return 1
    fi
    _speedtest_run_timeout 45 env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none NEEDRESTART_MODE=a \
        apt-get update -qq >/dev/null 2>&1 || true
    _speedtest_run_timeout 90 env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none NEEDRESTART_MODE=a \
        apt-get install -y speedtest
}

_speedtest_cleanup_rpm_conflicts() {
    local old_repo="/etc/yum.repos.d/bintray-ookla-rhel.repo"
    local pkg_cmd="yum"
    command -v dnf >/dev/null 2>&1 && pkg_cmd="dnf"

    if [[ -f "$old_repo" ]]; then
        local backup="${old_repo}.bak.$(date +%Y%m%d%H%M%S)"
        mv "$old_repo" "$backup"
        _info "已备份旧 Bintray RPM 源: ${backup}"
    fi

    if command -v rpm >/dev/null 2>&1 && rpm -q speedtest-cli >/dev/null 2>&1; then
        _warn "检测到非官方 speedtest-cli 包，可能与 Ookla 官方 speedtest 冲突"
        if _speedtest_prompt_yes_default "移除 speedtest-cli"; then
            _speedtest_run_timeout 60 "$pkg_cmd" remove -y speedtest-cli || rpm -e speedtest-cli || return 1
        else
            _warn "已保留 speedtest-cli，后续安装可能失败"
        fi
    fi
    return 0
}

_speedtest_install_rpm_repo() {
    local pkg_cmd="yum"
    command -v dnf >/dev/null 2>&1 && pkg_cmd="dnf"

    _info "使用 Ookla 官方 RPM 仓库安装..."
    _speedtest_ensure_cmd_available curl curl || return 1
    _speedtest_cleanup_rpm_conflicts || return 1

    if ! _speedtest_run_timeout 60 bash -c 'curl -fsSL --connect-timeout 10 --max-time 45 https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh | bash'; then
        return 1
    fi
    _speedtest_run_timeout 90 "$pkg_cmd" install -y speedtest
}

_speedtest_linux_arch_token() {
    local arch

    if command -v dpkg >/dev/null 2>&1; then
        arch="$(dpkg --print-architecture 2>/dev/null || true)"
        case "$arch" in
            amd64) printf 'x86_64'; return 0 ;;
            arm64) printf 'aarch64'; return 0 ;;
            i386) printf 'i386'; return 0 ;;
            armel|armhf) printf '%s' "$arch"; return 0 ;;
        esac
    fi

    if command -v apk >/dev/null 2>&1; then
        arch="$(apk --print-arch 2>/dev/null || true)"
        case "$arch" in
            x86_64|x86|aarch64|armhf|armv7|armv7l) ;;
            *) arch="" ;;
        esac
        case "$arch" in
            x86_64) printf 'x86_64'; return 0 ;;
            x86) printf 'i386'; return 0 ;;
            aarch64) printf 'aarch64'; return 0 ;;
            armhf|armv7|armv7l) printf 'armhf'; return 0 ;;
        esac
    fi

    arch="$(uname -m 2>/dev/null || true)"
    case "$arch" in
        x86_64|amd64) printf 'x86_64' ;;
        i386|i486|i586|i686|x86) printf 'i386' ;;
        aarch64|arm64) printf 'aarch64' ;;
        armv7*|armv6*|armhf) printf 'armhf' ;;
        armv5*|armel|arm*) printf 'armel' ;;
        *) return 1 ;;
    esac
}

_speedtest_install_linux_tarball() {
    local arch url tmp_dir tarball bin_dst

    _info "使用 Ookla 官方 Linux tarball 安装..."
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        _speedtest_ensure_cmd_available curl curl || return 1
    fi
    _speedtest_ensure_cmd_available tar tar || return 1

    if ! arch="$(_speedtest_linux_arch_token)"; then
        _error_no_exit "当前 Linux 架构不受 Ookla 官方 tarball 支持: $(uname -m 2>/dev/null || echo unknown)"
        return 1
    fi

    url="${_SPEEDTEST_DOWNLOAD_BASE}/ookla-speedtest-${_SPEEDTEST_VERSION}-linux-${arch}.tgz"
    tmp_dir=$(mktemp -d /tmp/vpsgo-speedtest.XXXXXX) || {
        _error_no_exit "创建临时目录失败"
        return 1
    }
    tarball="${tmp_dir}/speedtest.tgz"

    _info "下载: ${url}"
    if ! _mihomo_download "$url" "$tarball"; then
        rm -rf "$tmp_dir"
        _error_no_exit "下载 Ookla Speedtest 失败"
        return 1
    fi

    if ! tar -xzf "$tarball" -C "$tmp_dir"; then
        rm -rf "$tmp_dir"
        _error_no_exit "解压 Ookla Speedtest 失败"
        return 1
    fi

    if [[ ! -x "${tmp_dir}/speedtest" ]]; then
        rm -rf "$tmp_dir"
        _error_no_exit "压缩包内未找到 speedtest 可执行文件"
        return 1
    fi

    bin_dst="/usr/local/bin/speedtest"
    if ! _speedtest_install_file "${tmp_dir}/speedtest" "$bin_dst" 0755; then
        rm -rf "$tmp_dir"
        _error_no_exit "安装 speedtest 到 ${bin_dst} 失败"
        return 1
    fi

    if ! "$bin_dst" --version >/dev/null 2>&1; then
        rm -rf "$tmp_dir"
        rm -f "$bin_dst"
        _error_no_exit "speedtest 安装后无法运行，当前系统可能不兼容官方 Linux tarball"
        return 1
    fi

    [[ -f "${tmp_dir}/speedtest.5" ]] && _speedtest_install_file "${tmp_dir}/speedtest.5" "/usr/local/share/man/man5/speedtest.5" 0644 || true
    [[ -f "${tmp_dir}/speedtest.md" ]] && _speedtest_install_file "${tmp_dir}/speedtest.md" "/usr/local/share/doc/ookla-speedtest/speedtest.md" 0644 || true

    rm -rf "$tmp_dir"
    _success "已安装 Ookla Speedtest: ${bin_dst}"
    return 0
}

_speedtest_find_brew() {
    local brew_bin candidate
    brew_bin="$(command -v brew 2>/dev/null || true)"
    if [[ -z "$brew_bin" && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]] && command -v sudo >/dev/null 2>&1; then
        brew_bin="$(sudo -H -u "$SUDO_USER" bash -lc 'command -v brew' 2>/dev/null || true)"
    fi
    if [[ -z "$brew_bin" ]]; then
        for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
            if [[ -x "$candidate" ]]; then
                brew_bin="$candidate"
                break
            fi
        done
    fi
    printf '%s' "$brew_bin"
}

_speedtest_brew_exec() {
    local brew_bin="$1"
    shift

    if [[ $EUID -eq 0 ]]; then
        if [[ -z "${SUDO_USER:-}" || "${SUDO_USER}" == "root" ]]; then
            _error_no_exit "Homebrew 不允许 root 直接执行，请用 sudo 从普通用户运行本脚本"
            return 1
        fi
        sudo -H -u "$SUDO_USER" "$brew_bin" "$@"
    else
        "$brew_bin" "$@"
    fi
}

_speedtest_install_macos() {
    local brew_bin

    brew_bin="$(_speedtest_find_brew)"
    if [[ -z "$brew_bin" ]]; then
        _error_no_exit "未检测到 Homebrew，请先安装 Homebrew 后重试"
        _info "官方建议 macOS 通过 Homebrew 安装 Ookla Speedtest"
        return 1
    fi

    _info "使用 Homebrew 安装 Ookla Speedtest..."
    if _speedtest_brew_exec "$brew_bin" list speedtest-cli >/dev/null 2>&1; then
        _warn "检测到可能冲突的 speedtest-cli"
        if _speedtest_prompt_yes_default "卸载 speedtest-cli"; then
            _speedtest_brew_exec "$brew_bin" uninstall speedtest-cli --force || return 1
        fi
    fi

    _speedtest_brew_exec "$brew_bin" tap teamookla/speedtest || return 1
    _speedtest_brew_exec "$brew_bin" update || _warn "brew update 失败，继续尝试安装"
    _speedtest_brew_exec "$brew_bin" install speedtest --force
}

_speedtest_install_freebsd() {
    local major arch pkg_url

    if ! command -v pkg >/dev/null 2>&1; then
        _error_no_exit "未检测到 FreeBSD pkg，请先安装 pkg"
        return 1
    fi

    arch="$(uname -m 2>/dev/null || true)"
    case "$arch" in
        amd64|x86_64) ;;
        *)
            _error_no_exit "Ookla 官方 FreeBSD 包仅支持 x86_64/amd64"
            return 1
            ;;
    esac

    major="$(freebsd-version -u 2>/dev/null || uname -r 2>/dev/null || true)"
    major="${major%%.*}"
    case "$major" in
        12|13) ;;
        *)
            _error_no_exit "Ookla 官方页面当前仅提供 FreeBSD 12/13 x86_64 包"
            return 1
            ;;
    esac

    _info "使用 Ookla 官方 FreeBSD ${major} 包安装..."
    pkg update -f >/dev/null 2>&1 || pkg update >/dev/null 2>&1 || true
    pkg install -y libidn2 ca_root_nss || return 1

    pkg_url="${_SPEEDTEST_DOWNLOAD_BASE}/ookla-speedtest-${_SPEEDTEST_VERSION}-freebsd${major}-x86_64.pkg"
    pkg add -f "$pkg_url"
}

_speedtest_install_linux() {
    if _speedtest_install_linux_tarball; then
        return 0
    fi

    _warn "官方 Linux tarball 安装失败，尝试发行版仓库方式"

    if command -v apt-get >/dev/null 2>&1; then
        if _speedtest_install_deb_repo; then
            return 0
        fi
    elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
        if _speedtest_install_rpm_repo; then
            return 0
        fi
    fi

    return 1
}

_speedtest_install_current_os() {
    local os_name
    os_name="$(uname -s 2>/dev/null || echo unknown)"

    case "$os_name" in
        Linux) _speedtest_install_linux ;;
        Darwin) _speedtest_install_macos ;;
        FreeBSD) _speedtest_install_freebsd ;;
        MINGW*|MSYS*|CYGWIN*)
            _error_no_exit "Windows 版 Speedtest CLI 官方提供 zip 包，当前 VPSGo Bash 菜单暂不处理 Windows 安装"
            return 1
            ;;
        *)
            _error_no_exit "暂不支持当前系统: ${os_name}"
            return 1
            ;;
    esac
}

_speedtest_show_installed_status() {
    local bin_path version
    hash -r 2>/dev/null || true
    bin_path="$(command -v speedtest 2>/dev/null || true)"

    if [[ -z "$bin_path" ]]; then
        _error_no_exit "未在 PATH 中检测到 speedtest 命令"
        _warn "如果已安装到 /usr/local/bin，请确认该目录在 PATH 中"
        return 1
    fi

    if ! version="$("$bin_path" --version 2>&1 | head -1)"; then
        _error_no_exit "speedtest 命令无法运行: ${bin_path}"
        return 1
    fi

    _success "Ookla Speedtest 已可用: ${bin_path}"
    [[ -n "$version" ]] && _info "版本信息: ${version}"
    return 0
}

_speedtest_setup() {
    _header "Ookla Speedtest CLI 安装"

    _info "官方页面: https://www.speedtest.net/apps/cli"
    if command -v speedtest >/dev/null 2>&1; then
        local current_version
        current_version="$(speedtest --version 2>&1 | head -1 || true)"
        _info "当前已检测到 speedtest: ${current_version:-$(command -v speedtest)}"
    else
        _info "当前未检测到 speedtest"
    fi

    echo ""
    printf "  ${BOLD}选择操作${PLAIN}\n"
    _separator
    _menu_pair "1" "安装/更新 Speedtest" "测速 CLI" "green" "0" "返回主菜单" "" "red"
    _separator

    local choice
    read -rp "  选择 [0-1]: " choice
    case "$choice" in
        1) ;;
        0) return ;;
        *) _error_no_exit "无效选项"; _press_any_key; return ;;
    esac

    echo ""
    if _speedtest_install_current_os && _speedtest_show_installed_status; then
        _info "首次运行 speedtest 时会提示确认 Ookla 许可与隐私条款"
    else
        _error_no_exit "Ookla Speedtest 安装失败"
    fi
    _press_any_key
}

# --- 8. NextTrace 安装与快速路由检测 ---

_ntrace_bin_for_flavor() {
    case "${1:-full}" in
        tiny) printf 'nexttrace-tiny' ;;
        ntr) printf 'ntr' ;;
        *) printf 'nexttrace' ;;
    esac
}

_ntrace_detect_platform() {
    local os arch goos goarch

    os="$(uname -s 2>/dev/null || echo unknown)"
    arch="$(uname -m 2>/dev/null || echo unknown)"

    case "$os" in
        Linux) goos="linux" ;;
        Darwin) goos="darwin" ;;
        FreeBSD) goos="freebsd" ;;
        OpenBSD) goos="openbsd" ;;
        NetBSD) goos="netbsd" ;;
        *) return 1 ;;
    esac

    if [[ "$goos" == "darwin" ]]; then
        printf '%s_%s' "$goos" "universal"
        return 0
    fi

    case "$arch" in
        x86_64|amd64) goarch="amd64" ;;
        i386|i486|i586|i686|x86) goarch="386" ;;
        aarch64|arm64) goarch="arm64" ;;
        armv7*|armhf) goarch="armv7" ;;
        armv6*) goarch="armv6" ;;
        armv5*) goarch="armv5" ;;
        riscv64) goarch="riscv64" ;;
        s390x) goarch="s390x" ;;
        ppc64le) goarch="ppc64le" ;;
        loongarch64|loong64) goarch="loong64" ;;
        mips64el|mips64le) goarch="mips64le" ;;
        mips64) goarch="mips64" ;;
        mipsel|mipsle) goarch="mipsle" ;;
        mips) goarch="mips" ;;
        *) return 1 ;;
    esac

    printf '%s_%s' "$goos" "$goarch"
}

_ntrace_version_line() {
    local bin="$1" version=""
    version="$("$bin" --version 2>&1 | head -1 || true)"
    if [[ -z "$version" || "$version" == *"unknown flag"* || "$version" == *"Usage:"* ]]; then
        version="$("$bin" -V 2>&1 | head -1 || true)"
    fi
    printf '%s' "${version:-$bin}"
}

_ntrace_show_installed_status() {
    local bin path version found=1

    for bin in nexttrace nexttrace-tiny ntr; do
        path="$(command -v "$bin" 2>/dev/null || true)"
        if [[ -n "$path" ]]; then
            version="$(_ntrace_version_line "$path")"
            _status_kv "$bin" "${version} (${path})" "green" 16
            found=0
        else
            _status_kv "$bin" "未安装" "dim" 16
        fi
    done

    return "$found"
}

_ntrace_install_with_official_script() {
    local flavor="$1" bin tmp_script

    bin="$(_ntrace_bin_for_flavor "$flavor")"
    tmp_script=$(_mktemp_file ntrace-install .sh) || return 1

    _warn "Release 二进制下载失败，改用 NextTrace 官方安装脚本"
    _info "下载: ${_NTRACE_INSTALL_URL}"
    if ! _download_file "$_NTRACE_INSTALL_URL" "$tmp_script"; then
        rm -f "$tmp_script"
        return 1
    fi

    chmod 0755 "$tmp_script" 2>/dev/null || true
    if [[ "$flavor" == "full" ]]; then
        bash "$tmp_script"
    else
        bash "$tmp_script" --flavor "$flavor"
    fi
    rm -f "$tmp_script"

    hash -r 2>/dev/null || true
    command -v "$bin" >/dev/null 2>&1
}

_ntrace_install_flavor() {
    local flavor="${1:-full}" bin platform asset url tmp_bin dst

    bin="$(_ntrace_bin_for_flavor "$flavor")"
    if ! platform="$(_ntrace_detect_platform)" || [[ -z "$platform" ]]; then
        _error_no_exit "NextTrace 暂不支持当前平台自动安装: $(uname -s 2>/dev/null || echo unknown)/$(uname -m 2>/dev/null || echo unknown)"
        return 1
    fi

    asset="${bin}_${platform}"
    url="${_NTRACE_REPO_URL}/releases/latest/download/${asset}"
    tmp_bin=$(_mktemp_file "vpsgo-${bin}") || return 1
    dst="${_NTRACE_INSTALL_DIR}/${bin}"

    _info "下载 NextTrace ${bin}: ${asset}"
    printf "    ${DIM}%s${PLAIN}\n" "$url"
    if _download_file "$url" "$tmp_bin" && [[ -s "$tmp_bin" ]]; then
        chmod 0755 "$tmp_bin" 2>/dev/null || true
        if _install_script_file "$tmp_bin" "$dst"; then
            rm -f "$tmp_bin"
            hash -r 2>/dev/null || true
            if command -v "$bin" >/dev/null 2>&1; then
                if ! "$bin" --version >/dev/null 2>&1 && ! "$bin" -V >/dev/null 2>&1 && ! "$bin" -h >/dev/null 2>&1; then
                    _error_no_exit "${bin} 安装后无法运行，当前系统可能不兼容该 Release 二进制"
                    rm -f "$dst" 2>/dev/null || true
                    hash -r 2>/dev/null || true
                else
                    _success "已安装 ${bin}: $(command -v "$bin")"
                    _info "版本信息: $(_ntrace_version_line "$bin")"
                    return 0
                fi
            else
                _error_no_exit "已写入 ${dst}，但 PATH 中未检测到 ${bin}"
            fi
        fi
    fi

    rm -f "$tmp_bin"
    if _ntrace_install_with_official_script "$flavor"; then
        _success "已安装 ${bin}: $(command -v "$bin")"
        _info "版本信息: $(_ntrace_version_line "$bin")"
        return 0
    fi

    _error_no_exit "NextTrace ${bin} 安装失败"
    return 1
}

_ntrace_require_nexttrace() {
    if command -v nexttrace >/dev/null 2>&1; then
        return 0
    fi

    _warn "未检测到 nexttrace 完整版"
    if _speedtest_prompt_yes_default "现在安装/更新 nexttrace"; then
        _ntrace_install_flavor full
        return $?
    fi
    return 1
}

_ntrace_prompt_target() {
    local prompt="${1:-目标 IP/域名}" default_target="${2:-1.1.1.1}" target
    read -rp "  ${prompt} [${default_target}]: " target
    printf '%s' "${target:-$default_target}"
}

_ntrace_prompt_ip_family_arg() {
    local choice

    read -rp "  IP 版本 [0 自动 / 1 IPv4 / 2 IPv6，默认 0]: " choice
    case "${choice:-0}" in
        1) printf '%s' "--ipv4" ;;
        2) printf '%s' "--ipv6" ;;
        0|"") ;;
        *) ;;
    esac
}

_ntrace_print_command() {
    local -a cmd=("$@")
    printf "  ${DIM}执行:${PLAIN} ${GREEN}"
    printf '%q ' "${cmd[@]}"
    printf "${PLAIN}\n\n"
}

_ntrace_run_nexttrace() {
    local -a cmd=("nexttrace" "$@")

    echo ""
    _ntrace_print_command "${cmd[@]}"
    "${cmd[@]}"
    local rc=$?
    echo ""
    if [[ "$rc" -eq 0 ]]; then
        _success "NextTrace 检测完成"
    else
        _error_no_exit "NextTrace 返回非零状态: ${rc}"
        _warn "TCP/UDP、MTR 或部分系统下可能需要 root 权限、CAP_NET_RAW 或防火墙放行"
    fi
    _press_any_key
}

_ntrace_quick_trace() {
    local target protocol port output provider rdns
    local family_arg
    local -a args=()

    _header "NextTrace 快速 Trace"
    _ntrace_require_nexttrace || { _press_any_key; return; }

    target="$(_ntrace_prompt_target "目标 IP/域名/URL" "1.1.1.1")"
    family_arg="$(_ntrace_prompt_ip_family_arg)"
    [[ -n "$family_arg" ]] && args+=("$family_arg")

    echo ""
    printf "  ${BOLD}探测协议${PLAIN}\n"
    _menu_pair "1" "ICMP" "默认" "green" "2" "TCP SYN" "可指定端口" "green"
    _menu_item "3" "UDP" "可指定端口" "green"
    read -rp "  选择 [1-3，默认 1]: " protocol
    case "${protocol:-1}" in
        2)
            args+=("--tcp")
            read -rp "  TCP 目标端口 [80]: " port
            port="${port:-80}"
            if _is_valid_port "$port"; then
                args+=("--port" "$port")
            else
                _warn "端口无效，使用 nexttrace 默认端口"
            fi
            ;;
        3)
            args+=("--udp")
            read -rp "  UDP 目标端口 [33494]: " port
            port="${port:-33494}"
            if _is_valid_port "$port"; then
                args+=("--port" "$port")
            else
                _warn "端口无效，使用 nexttrace 默认端口"
            fi
            ;;
        1|"") ;;
        *) _warn "协议选择无效，使用 ICMP" ;;
    esac

    echo ""
    printf "  ${BOLD}输出模式${PLAIN}\n"
    _menu_pair "1" "实时输出" "默认" "green" "2" "表格汇总" "--table" "green"
    _menu_pair "3" "JSON" "--json" "green" "4" "Raw" "--raw" "green"
    _menu_item "5" "Classic" "--classic" "green"
    read -rp "  选择 [1-5，默认 1]: " output
    case "${output:-1}" in
        2) args+=("--table") ;;
        3) args+=("--json") ;;
        4) args+=("--raw") ;;
        5) args+=("--classic") ;;
        1|"") ;;
        *) _warn "输出模式无效，使用实时输出" ;;
    esac

    echo ""
    printf "  ${BOLD}IP 数据源${PLAIN}\n"
    _menu_pair "0" "默认" "" "green" "1" "IP.SB" "" "green"
    _menu_pair "2" "IPInfo" "" "green" "3" "ip-api.com" "" "green"
    _menu_item "4" "禁用 GeoIP" "disable-geoip" "green"
    read -rp "  选择 [0-4，默认 0]: " provider
    case "${provider:-0}" in
        1) args+=("--data-provider" "IP.SB") ;;
        2) args+=("--data-provider" "IPInfo") ;;
        3) args+=("--data-provider" "ip-api.com") ;;
        4) args+=("--data-provider" "disable-geoip") ;;
        0|"") ;;
        *) _warn "数据源选择无效，使用默认数据源" ;;
    esac

    echo ""
    printf "  ${BOLD}RDNS${PLAIN}\n"
    _menu_pair "0" "默认" "" "green" "1" "不查询" "--no-rdns" "green"
    _menu_item "2" "总是查询" "--always-rdns" "green"
    read -rp "  选择 [0-2，默认 0]: " rdns
    case "${rdns:-0}" in
        1) args+=("--no-rdns") ;;
        2) args+=("--always-rdns") ;;
        0|"") ;;
        *) _warn "RDNS 选择无效，使用默认策略" ;;
    esac

    _ntrace_run_nexttrace "${args[@]}" "$target"
}

_ntrace_fast_trace() {
    local transport="${1:-icmp}"
    local family_arg
    local -a args=("--fast-trace")

    _header "NextTrace 快速回程检测"
    _ntrace_require_nexttrace || { _press_any_key; return; }
    family_arg="$(_ntrace_prompt_ip_family_arg)"
    [[ -n "$family_arg" ]] && args+=("$family_arg")
    [[ "$transport" == "tcp" ]] && args+=("--tcp")
    _ntrace_run_nexttrace "${args[@]}"
}

_ntrace_custom_file() {
    local file use_tcp
    local family_arg
    local -a args=()

    _header "NextTrace 自定义列表检测"
    _ntrace_require_nexttrace || { _press_any_key; return; }

    read -rp "  列表文件路径: " file
    if [[ -z "${file:-}" || ! -f "$file" ]]; then
        _error_no_exit "列表文件不存在"
        _press_any_key
        return
    fi

    family_arg="$(_ntrace_prompt_ip_family_arg)"
    [[ -n "$family_arg" ]] && args+=("$family_arg")
    read -rp "  使用 TCP SYN 检测? [y/N]: " use_tcp
    [[ "$use_tcp" =~ ^[Yy] ]] && args+=("--tcp")
    args+=("--file" "$file")
    _ntrace_run_nexttrace "${args[@]}"
}

_ntrace_mtr() {
    local target mode show_ips
    local family_arg
    local -a args=("--mtr")

    _header "NextTrace MTR 检测"
    _ntrace_require_nexttrace || { _press_any_key; return; }

    target="$(_ntrace_prompt_target "目标 IP/域名" "1.1.1.1")"
    family_arg="$(_ntrace_prompt_ip_family_arg)"
    [[ -n "$family_arg" ]] && args+=("$family_arg")

    echo ""
    printf "  ${BOLD}MTR 模式${PLAIN}\n"
    _menu_pair "1" "实时 TUI" "" "green" "2" "报告" "--report" "green"
    _menu_pair "3" "宽报告" "--wide" "green" "4" "Raw" "--raw" "green"
    read -rp "  选择 [1-4，默认 1]: " mode
    case "${mode:-1}" in
        2) args+=("--report") ;;
        3) args+=("--wide") ;;
        4) args+=("--raw") ;;
        1|"") ;;
        *) _warn "MTR 模式无效，使用实时 TUI" ;;
    esac

    read -rp "  显示每跳 IP? [Y/n]: " show_ips
    [[ ! "$show_ips" =~ ^[Nn] ]] && args+=("--show-ips")
    _ntrace_run_nexttrace "${args[@]}" "$target"
}

_ntrace_mtu() {
    local target
    local family_arg
    local -a args=("--mtu")

    _header "NextTrace MTU 探测"
    _ntrace_require_nexttrace || { _press_any_key; return; }

    target="$(_ntrace_prompt_target "目标 IP/域名" "1.1.1.1")"
    family_arg="$(_ntrace_prompt_ip_family_arg)"
    [[ -n "$family_arg" ]] && args+=("$family_arg")
    _ntrace_run_nexttrace "${args[@]}" "$target"
}

_ntrace_speed() {
    local provider json_mode
    local -a args=("--speed")

    _header "NextTrace CDN Speed"
    _ntrace_require_nexttrace || { _press_any_key; return; }

    echo ""
    printf "  ${BOLD}测速后端${PLAIN}\n"
    _menu_pair "1" "Apple CDN" "默认" "green" "2" "Cloudflare" "" "green"
    read -rp "  选择 [1-2，默认 1]: " provider
    [[ "${provider:-1}" == "2" ]] && args+=("--speed-provider" "cloudflare")

    read -rp "  输出 JSON 非交互结果? [y/N]: " json_mode
    [[ "$json_mode" =~ ^[Yy] ]] && args+=("--json" "--non-interactive" "--no-metadata")
    _ntrace_run_nexttrace "${args[@]}"
}

_ntrace_setup() {
    while true; do
        _header "NextTrace"
        _info "项目地址: ${_NTRACE_REPO_URL}"
        _ntrace_show_installed_status || true
        echo ""
        printf "  ${BOLD}选择操作${PLAIN}\n"
        _separator
        _menu_pair "1" "安装/更新 nexttrace" "完整版" "green" "2" "安装/更新 tiny" "精简版" "green"
        _menu_pair "3" "安装/更新 ntr" "MTR 专用" "green" "4" "快速 Trace" "常用参数向导" "green"
        _menu_pair "5" "快速回程" "--fast-trace" "green" "6" "TCP 回程" "--fast-trace --tcp" "green"
        _menu_pair "7" "自定义列表" "--file" "green" "8" "MTR 检测" "--mtr" "green"
        _menu_pair "9" "MTU 探测" "--mtu" "green" "10" "CDN Speed" "--speed" "green"
        _menu_item "0" "返回上级菜单" "" "red"
        _separator

        local choice
        read -rp "  选择 [0-10]: " choice
        case "$choice" in
            1) _ntrace_install_flavor full; _press_any_key ;;
            2) _ntrace_install_flavor tiny; _press_any_key ;;
            3) _ntrace_install_flavor ntr; _press_any_key ;;
            4) _ntrace_quick_trace ;;
            5) _ntrace_fast_trace icmp ;;
            6) _ntrace_fast_trace tcp ;;
            7) _ntrace_custom_file ;;
            8) _ntrace_mtr ;;
            9) _ntrace_mtu ;;
            10) _ntrace_speed ;;
            0) return ;;
            *) _error_no_exit "无效选项"; sleep 1 ;;
        esac
    done
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

    apt-get update -qq || true
    printf "  ${BOLD}选择版本${PLAIN}\n"
    _separator
    _menu_pair "1" "sing-box" "稳定版" "green" "2" "sing-box-beta" "测试版" "yellow"
    _separator
    local ver_choice
    read -rp "  选择 [1/2]（默认 1）: " ver_choice
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

    printf "  ${BOLD}选择操作${PLAIN}\n"
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
        read -rp "  覆盖? [y/N]: " overwrite
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
        read -rp "  实时跟踪日志? [y/N]: " follow
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

    _warn "将停止并卸载 Sing-Box，可删除配置目录。"
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
        read -rp "  同时删除 Sing-Box APT 源配置? [y/N]: " remove_repo
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
        read -rp "  同时删除配置目录 ${config_dir}? [y/N]: " remove_config
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

_singbox_manage_screen() {
    _header "Sing-Box 管理"

    local sb_ver="未安装"
    local sb_status="未运行"
    local sb_status_tone="red"

    if command -v sing-box >/dev/null 2>&1; then
        local ver
        ver=$(sing-box version 2>/dev/null | head -1)
        sb_ver="${ver:-未知}"
        local pid
        pid=$(pgrep -x sing-box 2>/dev/null || true)
        if [[ -n "$pid" ]]; then
            sb_status="运行中 (PID: $pid)"
            sb_status_tone="green"
        fi
    fi

    printf "  ${BOLD}状态信息${PLAIN}\n"
    _separator
    _status_kv_pair "版本" "$sb_ver" "dim" 8 "状态" "$sb_status" "$sb_status_tone" 8

    _separator
    _menu_pair "1" "安装/更新 Sing-Box" "" "green" "2" "配置自启并启动" "" "green"
    _menu_pair "3" "重启 Sing-Box" "" "green" "4" "查看状态" "" "green"
    _menu_pair "5" "查看日志" "" "green" "6" "卸载 Sing-Box" "停止并清理" "yellow"
    _menu_item "0" "返回主菜单" "" "red"
    _separator
}

_singbox_manage() {
    while true; do
        _ui_print_screen _singbox_manage_screen

        local choice
        read -rp "  ${CYAN}➜${PLAIN}  选择 [0-6]: " choice
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


_snell_port_usage_line() {
    local port="$1"
    # Prefer ss — BusyBox lsof does not support -i/-s flags and gives false positives
    if command -v ss >/dev/null 2>&1; then
        # BusyBox ss does not support -H (no header) or -p (show process).
        # Detect BusyBox: if 'ss' links to busybox, use plain flags + skip header.
        local _ss_flags="-lnutpH"
        if readlink -f "$(command -v ss)" 2>/dev/null | grep -q busybox \
            || ss --help 2>&1 | head -1 | grep -qi busybox; then
            _ss_flags="-lntu"
        fi
        ss $_ss_flags 2>/dev/null | awk -v p="$port" '
            /^Netid/ || /^State/ || /^Proto/ { next }
            {
                for (i = 1; i <= NF; i++) {
                    f = $i
                    sub(/%[[:alnum:]_.-]+$/, "", f)
                    n = split(f, arr, ":")
                    if (n >= 2 && arr[n] == p) {
                        print
                        exit
                    }
                }
            }
        '
        return
    fi
    if command -v netstat >/dev/null 2>&1; then
        local ns_out
        ns_out=$(netstat -lntup 2>/dev/null || netstat -lntu 2>/dev/null)
        if [[ -n "$ns_out" ]]; then
            echo "$ns_out" | awk -v p="$port" '
                NR <= 2 { next }
                {
                    addr = $4
                    sub(/%[[:alnum:]_.-]+$/, "", addr)
                    split(addr, arr, ":")
                    if (arr[length(arr)] == p) {
                        print
                        exit
                    }
                }
            '
            return
        fi
    fi
    if command -v lsof >/dev/null 2>&1; then
        if ! (lsof -h 2>&1 | grep -q -i busybox || lsof --help 2>&1 | grep -q -i busybox); then
            lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | sed -n '2p'
        fi
    fi
}

_snell_port_conflict_with_mihomo() {
    local target_port="$1"
    local config_file="$_MIHOMOCONF_CONFIG_FILE"
    local type name port cipher password user_id user_pass sni
    local hy2_up hy2_down hy2_ignore hy2_obfs hy2_obfs_password hy2_masquerade hy2_mport hy2_insecure listener_tag
    local vless_public_key vless_short_id vless_flow vless_client_fingerprint
    local vless_type vless_ws_path vless_ws_tls vless_ws_host

    [[ -f "$config_file" ]] || return 1
    while IFS=$'\x1f' read -r type name port cipher password user_id user_pass sni \
        hy2_up hy2_down hy2_ignore hy2_obfs hy2_obfs_password hy2_masquerade hy2_mport hy2_insecure listener_tag \
        vless_public_key vless_short_id vless_flow vless_client_fingerprint \
        tuic_congestion_control tuic_alpn tuic_udp_relay_mode hy2_congestion_control \
        vless_type vless_ws_path vless_ws_tls vless_ws_host; do
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
    tmp_zip=$(_mktemp_file snell .zip) || {
        _error_no_exit "创建临时文件失败"
        return 1
    }
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
    local node_name
    local NODE_COUNTRY="" NODE_CITY="" NODE_COUNTRY_CODE="UN" NODE_FLAG="🏳"
    local GEO_LOOKUP_IP=""

    if [[ ! -x "$_SNELL_BIN" ]]; then
        read -rp "  未检测到 snell-server，先安装? [Y/n]: " install_confirm
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

    read -rp "  启用 IPv6 转发? [y/N]: " ipv6_input
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
    if [[ -z "$client_host" ]]; then
        _error_no_exit "客户端连接地址不能为空"
        _press_any_key
        return
    fi

    GEO_LOOKUP_IP="$client_host"
    if [[ ! "$GEO_LOOKUP_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        GEO_LOOKUP_IP=$(_mihomoconf_get_server_ip)
    fi
    IFS=$'\x1f' read -r NODE_COUNTRY NODE_CITY NODE_COUNTRY_CODE NODE_FLAG < <(_mihomoconf_get_geo_profile "$GEO_LOOKUP_IP")
    if [[ -n "$NODE_CITY" ]]; then
        _info "地区识别: ${NODE_COUNTRY} ${NODE_CITY} (${NODE_FLAG}${NODE_COUNTRY_CODE})"
    else
        _info "地区识别: ${NODE_COUNTRY} (${NODE_FLAG}${NODE_COUNTRY_CODE})"
    fi
    node_name=$(printf '%s%s' "$NODE_FLAG" "$NODE_COUNTRY_CODE")

    local encoded_name snell_link
    encoded_name=$(_mihomoconf_urlencode "$node_name")
    snell_link=$(printf 'snell://%s@%s:%s?version=5&reuse=true&tfo=true#%s' \
        "$psk_value" "$client_host" "$listen_port" "$encoded_name")

    echo ""
    _separator
    printf "  ${BOLD}Snell V5 节点配置与链接${PLAIN}\n"
    _separator
    printf "  ${CYAN}Surge V5 配置:${PLAIN}\n"
    printf "  %s=snell,%s,%s,psk=%s,version=5,reuse=true,tfo=true\n\n" "$node_name" "$client_host" "$listen_port" "$psk_value"
    printf "  ${CYAN}Mihomo (Clash Meta) 配置:${PLAIN}\n"
    printf "  - name: \"%s\"\n" "$node_name"
    printf "    type: snell\n"
    printf "    server: %s\n" "$client_host"
    printf "    port: %s\n" "$listen_port"
    printf "    psk: %s\n" "$psk_value"
    printf "    version: 5\n"
    printf "    udp: true\n"
    printf "    tfo: true\n\n"
    printf "  ${CYAN}分享链接:${PLAIN}\n"
    printf "  %s\n" "$snell_link"
    _separator
    _press_any_key
}

_snell_export_node_config() {
    _header "导出 Snell 节点配置"

    if [[ ! -f "$_SNELL_CONFIG_FILE" ]]; then
        _error_no_exit "未找到配置文件: ${_SNELL_CONFIG_FILE}"
        _info "请先执行「配置并启动 Snell」"
        _press_any_key
        return
    fi

    local listen_port current_listen psk_value
    local host_default host_input client_host
    local node_name node_name_input surge_line
    local NODE_COUNTRY="" NODE_CITY="" NODE_COUNTRY_CODE="UN" NODE_FLAG="🏳"
    local GEO_LOOKUP_IP=""

    listen_port=$(_snell_conf_get_value "port" 2>/dev/null || true)
    if ! _is_valid_port "${listen_port:-}"; then
        current_listen=$(_snell_conf_get_value "listen" 2>/dev/null || true)
        listen_port=$(_snell_parse_port_from_listen "$current_listen" 2>/dev/null || true)
    fi
    psk_value=$(_snell_conf_get_value "psk" 2>/dev/null || true)

    if ! _is_valid_port "${listen_port:-}"; then
        _error_no_exit "配置中的端口无效，请先重新配置"
        _press_any_key
        return
    fi
    if [[ -z "$psk_value" ]]; then
        _error_no_exit "配置缺少 PSK，请先重新配置"
        _press_any_key
        return
    fi

    host_default=$(_mihomoconf_get_saved_host "$_MIHOMOCONF_CONFIG_FILE" 2>/dev/null || true)
    [[ -z "$host_default" ]] && host_default=$(_mihomoconf_get_server_ip)
    [[ -z "$host_default" ]] && host_default="YOUR_SERVER_IP"

    read -rp "  客户端连接地址 [默认 ${host_default}]: " host_input
    client_host=$(_mihomoconf_trim "${host_input:-$host_default}")
    if [[ -z "$client_host" ]]; then
        _error_no_exit "客户端连接地址不能为空"
        _press_any_key
        return
    fi

    GEO_LOOKUP_IP="$client_host"
    if [[ ! "$GEO_LOOKUP_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        GEO_LOOKUP_IP=$(_mihomoconf_get_server_ip)
    fi
    IFS=$'\x1f' read -r NODE_COUNTRY NODE_CITY NODE_COUNTRY_CODE NODE_FLAG < <(_mihomoconf_get_geo_profile "$GEO_LOOKUP_IP")
    if [[ -n "$NODE_CITY" ]]; then
        _info "地区识别: ${NODE_COUNTRY} ${NODE_CITY} (${NODE_FLAG}${NODE_COUNTRY_CODE})"
    else
        _info "地区识别: ${NODE_COUNTRY} (${NODE_FLAG}${NODE_COUNTRY_CODE})"
    fi

    node_name=$(printf '%s%s' "$NODE_FLAG" "$NODE_COUNTRY_CODE")
    read -rp "  节点名称 [默认 ${node_name}]: " node_name_input
    node_name=$(_mihomoconf_trim "${node_name_input:-$node_name}")
    [[ -z "$node_name" ]] && node_name=$(printf '%s%s' "$NODE_FLAG" "$NODE_COUNTRY_CODE")

    local encoded_name snell_link
    encoded_name=$(_mihomoconf_urlencode "$node_name")
    snell_link=$(printf 'snell://%s@%s:%s?version=5&reuse=true&tfo=true#%s' \
        "$psk_value" "$client_host" "$listen_port" "$encoded_name")

    echo ""
    _success "Snell V5 节点配置如下"
    _separator
    printf "  ${CYAN}Surge V5 配置:${PLAIN}\n"
    printf "  %s=snell,%s,%s,psk=%s,version=5,reuse=true,tfo=true\n\n" "$node_name" "$client_host" "$listen_port" "$psk_value"
    printf "  ${CYAN}Mihomo (Clash Meta) 配置:${PLAIN}\n"
    printf "  - name: \"%s\"\n" "$node_name"
    printf "    type: snell\n"
    printf "    server: %s\n" "$client_host"
    printf "    port: %s\n" "$listen_port"
    printf "    psk: %s\n" "$psk_value"
    printf "    version: 5\n"
    printf "    udp: true\n"
    printf "    tfo: true\n\n"
    printf "  ${CYAN}分享链接:${PLAIN}\n"
    printf "  %s\n" "$snell_link"
    _separator
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
        read -rp "  实时跟踪日志? [y/N]: " follow
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

    _warn "将停止并卸载 Snell，可删除配置目录。"
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
        read -rp "  同时删除配置目录 ${_SNELL_CONFIG_DIR}? [y/N]: " remove_config
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

_snell_manage_screen() {
    _header "Snell V5 管理"
    local snell_ver="未安装"
    local snell_status="未运行"
    local snell_status_tone="red"
    local snell_port="-"

    if [[ -x "$_SNELL_BIN" ]]; then
        local ver
        ver=$(_snell_bin_version)
        snell_ver="${ver:-已安装}"
        if _snell_service_is_active; then
            local pid
            pid=$(_snell_running_pid 2>/dev/null || true)
            if [[ -n "$pid" ]]; then
                snell_status="运行中 (PID: $pid)"
            else
                snell_status="运行中"
            fi
            snell_status_tone="green"
        fi
    fi

    if [[ -f "$_SNELL_CONFIG_FILE" ]]; then
        local p
        p=$(_snell_conf_get_value "port" 2>/dev/null || true)
        if ! _is_valid_port "${p:-}"; then
            local l
            l=$(_snell_conf_get_value "listen" 2>/dev/null || true)
            p=$(_snell_parse_port_from_listen "$l" 2>/dev/null || true)
        fi
        snell_port="${p:-未知}"
    fi

    printf "  ${BOLD}状态信息${PLAIN}\n"
    _separator
    _status_kv_pair "版本" "$snell_ver" "dim" 8 "状态" "$snell_status" "$snell_status_tone" 8
    _status_kv_pair "端口" "$snell_port" "cyan" 8 "文件" "$_SNELL_CONFIG_FILE" "dim" 8

    _separator
    _menu_pair "1" "安装/更新 Snell V5" "安装服务端" "green" "2" "配置并启动 Snell" "检查端口" "green"
    _menu_pair "3" "重启 Snell" "" "green" "4" "查看状态" "" "green"
    _menu_pair "5" "导出 Snell V5 配置" "输出 Surge/Mihomo/链接" "green" "6" "查看日志" "" "green"
    _menu_item "7" "卸载 Snell" "停止并清理" "yellow"
    _menu_item "0" "返回上级菜单" "" "red"
    _separator
}

_snell_manage() {
    while true; do
        _ui_print_screen _snell_manage_screen

        local ch
        read -rp "  ${CYAN}➜${PLAIN}  选择 [0-7]: " ch
        case "$ch" in
            1) _snell_install_latest ;;
            2) _snell_configure ;;
            3) _snell_restart ;;
            4) _snell_status ;;
            5) _snell_export_node_config ;;
            6) _snell_log ;;
            7) _snell_uninstall ;;
            0) return ;;
            *) _error_no_exit "无效选项"; sleep 1 ;;
        esac
    done
}

# --- 12. Realm 端口转发管理 ---

_REALM_CONFIG_DIR="/etc/realm"
_REALM_CONFIG_FILE="/etc/realm/config.toml"
_REALM_SERVICE_NAME="realm"
_REALM_SYSTEMD_SERVICE_FILE="/etc/systemd/system/${_REALM_SERVICE_NAME}.service"
_REALM_OPENRC_SERVICE_FILE="/etc/init.d/${_REALM_SERVICE_NAME}"
_REALM_BIN="/usr/local/bin/realm"
_REALM_LOG_FILE="/var/log/realm.log"
_REALM_ERR_FILE="/var/log/realm.error.log"
_REALM_RELEASE_API="https://api.github.com/repos/zhboner/realm/releases/latest"

_realm_running_pid() {
    local pid=""
    local pid_file="/run/${_REALM_SERVICE_NAME}.pid"

    if [[ -f "$pid_file" ]]; then
        pid=$(tr -cd '0-9' < "$pid_file" 2>/dev/null || true)
        if _is_digit "${pid:-}" && kill -0 "$pid" >/dev/null 2>&1; then
            printf '%s' "$pid"
            return 0
        fi
    fi

    if command -v pgrep >/dev/null 2>&1; then
        pid=$(pgrep -x realm 2>/dev/null | head -n1 || true)
        [[ -z "$pid" ]] && pid=$(pgrep realm 2>/dev/null | head -n1 || true)
        if _is_digit "${pid:-}" && kill -0 "$pid" >/dev/null 2>&1; then
            printf '%s' "$pid"
            return 0
        fi
    fi
    return 1
}

_realm_systemd_service_configured() {
    _has_systemd || return 1
    systemctl is-enabled "${_REALM_SERVICE_NAME}.service" &>/dev/null \
        || systemctl is-active "${_REALM_SERVICE_NAME}.service" &>/dev/null \
        || [[ -f "$_REALM_SYSTEMD_SERVICE_FILE" ]]
}

_realm_openrc_service_configured() {
    _has_openrc || return 1
    [[ -x "$_REALM_OPENRC_SERVICE_FILE" ]] || _openrc_service_in_default "$_REALM_SERVICE_NAME"
}

_realm_service_is_active() {
    if _has_systemd && systemctl is-active --quiet "$_REALM_SERVICE_NAME" 2>/dev/null; then
        return 0
    fi
    if _has_openrc && [[ -x "$_REALM_OPENRC_SERVICE_FILE" ]] && rc-service "$_REALM_SERVICE_NAME" status >/dev/null 2>&1; then
        return 0
    fi
    _realm_running_pid >/dev/null 2>&1
}

_realm_detect_arch() {
    local machine
    machine=$(uname -m 2>/dev/null || echo unknown)
    case "$machine" in
        x86_64|amd64) echo "x86_64" ;;
        i386|i486|i586|i686) echo "i686" ;;
        aarch64|arm64) echo "aarch64" ;;
        armv7l|armv7) echo "armv7" ;;
        *) echo "" ;;
    esac
}

_realm_bin_version() {
    if [[ -x "$_REALM_BIN" ]]; then
        local out
        out=$("$_REALM_BIN" --version 2>/dev/null | head -1 || true)
        [[ -z "$out" ]] && out=$("$_REALM_BIN" -V 2>/dev/null | head -1 || true)
        printf '%s' "$out"
        return
    fi
    echo ""
}

_realm_is_musl() {
    if command -v ldd >/dev/null 2>&1; then
        if ldd --version 2>&1 | grep -qi 'musl'; then
            return 0
        fi
    fi
    ls /lib/ld-musl-*.so.1 >/dev/null 2>&1
}

_realm_release_tag_from_json() {
    local release_json="$1"
    printf '%s\n' "$release_json" \
        | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        | head -1
}

_realm_pick_asset_url() {
    local release_json="$1" arch="$2" prefer_musl="$3"
    local keywords=() urls=() line kw url

    while IFS= read -r line; do
        [[ -n "$line" ]] && urls+=("$line")
    done < <(
        printf '%s\n' "$release_json" \
            | grep -oE 'https://[^"]+/download/[^"]+/realm-[^"]+\.(tar\.gz|tar\.xz|zip)' \
            | sort -u
    )
    (( ${#urls[@]} > 0 )) || return 1

    case "$arch" in
        x86_64)
            if [[ "$prefer_musl" == "1" ]]; then
                keywords=("x86_64-unknown-linux-musl" "x86_64-unknown-linux-gnu")
            else
                keywords=("x86_64-unknown-linux-gnu" "x86_64-unknown-linux-musl")
            fi
            ;;
        aarch64)
            if [[ "$prefer_musl" == "1" ]]; then
                keywords=("aarch64-unknown-linux-musl" "aarch64-unknown-linux-gnu")
            else
                keywords=("aarch64-unknown-linux-gnu" "aarch64-unknown-linux-musl")
            fi
            ;;
        armv7)
            keywords=("armv7-unknown-linux-gnueabihf" "arm-unknown-linux-gnueabihf" "armv7-unknown-linux-musleabihf")
            ;;
        i686)
            keywords=("i686-unknown-linux-gnu" "i686-unknown-linux-musl")
            ;;
        *) return 1 ;;
    esac

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

_realm_install_latest_core() {
    local arch prefer_musl latest_json latest_version asset_url
    local tmp_pkg tmp_dir extracted_bin

    if [[ "$(uname -s)" != "Linux" ]]; then
        _error_no_exit "Realm 仅支持 Linux 系统"
        return 1
    fi
    for cmd in curl tar; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            _error_no_exit "缺少必要命令: $cmd，请先安装"
            return 1
        fi
    done

    arch=$(_realm_detect_arch)
    if [[ -z "$arch" ]]; then
        _error_no_exit "不支持的架构: $(uname -m)"
        return 1
    fi

    prefer_musl="0"
    _realm_is_musl && prefer_musl="1"

    latest_json=$(curl -fsSL "$(_github_proxy_url "$_REALM_RELEASE_API")" 2>/dev/null || true)
    if [[ -z "$latest_json" ]]; then
        _error_no_exit "无法获取 Realm 最新版本信息"
        return 1
    fi
    latest_version=$(_realm_release_tag_from_json "$latest_json")
    if [[ -z "$latest_version" ]]; then
        _error_no_exit "解析 Realm 版本号失败"
        return 1
    fi

    asset_url=$(_realm_pick_asset_url "$latest_json" "$arch" "$prefer_musl")
    if [[ -z "$asset_url" ]]; then
        _error_no_exit "未找到匹配当前系统的 Realm 发行包"
        return 1
    fi

    tmp_pkg=$(_mktemp_file realm .tar.gz) || {
        _error_no_exit "创建临时文件失败"
        return 1
    }
    tmp_dir=$(mktemp -d /tmp/realm.XXXXXX)

    _info "下载 Realm: ${latest_version}"
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

    if ! tar -xzf "$tmp_pkg" -C "$tmp_dir" 2>/dev/null; then
        if ! tar -xf "$tmp_pkg" -C "$tmp_dir" 2>/dev/null; then
            rm -rf "$tmp_pkg" "$tmp_dir"
            _error_no_exit "解压失败，请确认 tar 支持已安装"
            return 1
        fi
    fi

    extracted_bin=$(find "$tmp_dir" -type f \( -name 'realm' -o -name 'realm-slim' \) | head -1)
    if [[ -z "$extracted_bin" || ! -f "$extracted_bin" ]]; then
        rm -rf "$tmp_pkg" "$tmp_dir"
        _error_no_exit "发行包中未找到 realm 可执行文件"
        return 1
    fi

    install -m 0755 "$extracted_bin" "$_REALM_BIN"
    rm -rf "$tmp_pkg" "$tmp_dir"

    if [[ ! -x "$_REALM_BIN" ]]; then
        _error_no_exit "realm 安装失败"
        return 1
    fi
    _success "Realm 安装完成"
    _info "版本: $(_realm_bin_version)"
    return 0
}

_realm_install_or_update() {
    _header "Realm 安装/更新"
    _time_sync_check_and_enable
    _realm_install_latest_core
    _press_any_key
}

# ---- Realm 配置解析 ----

_realm_parse_endpoints() {
    local config_file="$1"
    [[ -f "$config_file" ]] || return 1
    awk '
        function trim(s) {
            gsub(/^[[:space:]]+/, "", s)
            gsub(/[[:space:]]+$/, "", s)
            return s
        }
        function unquote(s) {
            gsub(/^"/, "", s)
            gsub(/"$/, "", s)
            gsub(/^'\''/, "", s)
            gsub(/'\''$/, "", s)
            return s
        }
        BEGIN { in_endpoint = 0; listen = ""; remote = "" }
        /^\[\[endpoints\]\]/ {
            if (in_endpoint && listen != "" && remote != "")
                printf "%s\x1f%s\n", listen, remote
            in_endpoint = 1
            listen = ""
            remote = ""
            next
        }
        in_endpoint && /^[[:space:]]*listen[[:space:]]*=/ {
            val = $0; sub(/^[^=]*=/, "", val)
            listen = unquote(trim(val))
            next
        }
        in_endpoint && /^[[:space:]]*remote[[:space:]]*=/ {
            val = $0; sub(/^[^=]*=/, "", val)
            remote = unquote(trim(val))
            next
        }
        /^\[/ && !/^\[\[endpoints\]\]/ {
            if (in_endpoint && listen != "" && remote != "")
                printf "%s\x1f%s\n", listen, remote
            in_endpoint = 0
            listen = ""
            remote = ""
            next
        }
        END {
            if (in_endpoint && listen != "" && remote != "")
                printf "%s\x1f%s\n", listen, remote
        }
    ' "$config_file"
}

_realm_add_endpoint_to_config() {
    local listen="$1" remote="$2"
    local -a lines=()
    local found=0 l r

    if [[ -f "$_REALM_CONFIG_FILE" ]]; then
        while IFS=$'\x1f' read -r l r; do
            [[ -z "$l" ]] && continue
            if [[ "$l" == "$listen" ]]; then
                found=1
            fi
            lines+=("${l}|${r}")
        done < <(_realm_parse_endpoints "$_REALM_CONFIG_FILE")
    fi

    if [[ "$found" == "1" ]]; then
        return 2
    fi

    lines+=("${listen}|${remote}")
    _realm_write_config_from_lines "${lines[@]}"
}

_realm_delete_endpoint_from_config() {
    local index="$1"
    local -a lines=()
    local i=0 l r

    if [[ ! -f "$_REALM_CONFIG_FILE" ]]; then
        return 1
    fi

    while IFS=$'\x1f' read -r l r; do
        [[ -z "$l" ]] && continue
        if (( i != index )); then
            lines+=("${l}|${r}")
        fi
        ((i++))
    done < <(_realm_parse_endpoints "$_REALM_CONFIG_FILE")

    if (( ${#lines[@]} == 0 )); then
        rm -f "$_REALM_CONFIG_FILE"
        return 0
    fi

    _realm_write_config_from_lines "${lines[@]}"
}

_realm_write_config_from_lines() {
    local line listen remote
    mkdir -p "$_REALM_CONFIG_DIR"
    {
        printf '[log]\nlevel = "warn"\n\n'
        for line in "$@"; do
            listen="${line%%|*}"
            remote="${line##*|}"
            printf '[[endpoints]]\nlisten = "%s"\nremote = "%s"\n\n' "$listen" "$remote"
        done
    } > "$_REALM_CONFIG_FILE"
}

# ---- Realm 端口冲突检查 ----

_realm_port_usage_line() {
    local port="$1"
    # Prefer ss — BusyBox lsof does not support -i/-s flags and gives false positives
    if command -v ss >/dev/null 2>&1; then
        # BusyBox ss does not support -H (no header) or -p (show process).
        # Detect BusyBox: if 'ss' links to busybox, use plain flags + skip header.
        local _ss_flags="-lnutpH"
        if readlink -f "$(command -v ss)" 2>/dev/null | grep -q busybox \
            || ss --help 2>&1 | head -1 | grep -qi busybox; then
            _ss_flags="-lntu"
        fi
        ss $_ss_flags 2>/dev/null | awk -v p="$port" '
            /^Netid/ || /^State/ || /^Proto/ { next }
            {
                for (i = 1; i <= NF; i++) {
                    f = $i
                    sub(/%[[:alnum:]_.-]+$/, "", f)
                    n = split(f, arr, ":")
                    if (n >= 2 && arr[n] == p) {
                        print
                        exit
                    }
                }
            }
        '
        return
    fi
    if command -v netstat >/dev/null 2>&1; then
        local ns_out
        ns_out=$(netstat -lntup 2>/dev/null || netstat -lntu 2>/dev/null)
        if [[ -n "$ns_out" ]]; then
            echo "$ns_out" | awk -v p="$port" '
                NR <= 2 { next }
                {
                    addr = $4
                    sub(/%[[:alnum:]_.-]+$/, "", addr)
                    split(addr, arr, ":")
                    if (arr[length(arr)] == p) {
                        print
                        exit
                    }
                }
            '
            return
        fi
    fi
    if command -v lsof >/dev/null 2>&1; then
        if ! (lsof -h 2>&1 | grep -q -i busybox || lsof --help 2>&1 | grep -q -i busybox); then
            lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | sed -n '2p'
        fi
    fi
}

_realm_port_conflict_with_mihomo() {
    local target_port="$1"
    [[ -f "$_MIHOMOCONF_CONFIG_FILE" ]] || return 1
    if declare -F _snell_port_conflict_with_mihomo >/dev/null 2>&1; then
        _snell_port_conflict_with_mihomo "$target_port"
        return $?
    fi
    return 1
}

_realm_pick_listen_port() {
    local default_port="${1:-8000}"
    local port_input usage_line

    while true; do
        read -rp "  监听端口 [默认 ${default_port}]: " port_input
        port_input=$(_mihomoconf_trim "${port_input:-$default_port}")
        if ! _is_valid_port "$port_input"; then
            _warn "端口无效，请输入 1-65535 的数字"
            continue
        fi
        if _realm_port_conflict_with_mihomo "$port_input"; then
            _warn "端口 ${port_input} 与 mihomo 配置冲突（listeners/port/mixed-port 等），请更换端口"
            continue
        fi
        usage_line=$(_realm_port_usage_line "$port_input")
        if [[ -n "$usage_line" && "$usage_line" != *"realm"* ]]; then
            _warn "端口 ${port_input} 已被占用: ${usage_line}"
            continue
        fi
        printf '%s' "$port_input"
        return 0
    done
}

# ---- Realm 服务管理 ----

_realm_enable_now() {
    if [[ ! -x "$_REALM_BIN" ]]; then
        _error_no_exit "未检测到 realm，请先安装"
        return 1
    fi
    if [[ ! -f "$_REALM_CONFIG_FILE" ]]; then
        _error_no_exit "未检测到配置文件: ${_REALM_CONFIG_FILE}"
        return 1
    fi

    if _has_systemd; then
        cat > "$_REALM_SYSTEMD_SERVICE_FILE" <<EOF
[Unit]
Description=Realm Port Forwarding Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=${_REALM_BIN} -c ${_REALM_CONFIG_FILE}
Restart=on-failure
RestartSec=3
LimitNOFILE=32768

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload >/dev/null 2>&1 || true
        if ! systemctl enable "$_REALM_SERVICE_NAME" >/dev/null 2>&1; then
            _error_no_exit "设置 realm 开机自启失败"
            return 1
        fi
        if ! systemctl restart "$_REALM_SERVICE_NAME" >/dev/null 2>&1; then
            _error_no_exit "realm 启动失败，请检查: systemctl status ${_REALM_SERVICE_NAME}"
            return 1
        fi
        sleep 1
        if systemctl is-active --quiet "$_REALM_SERVICE_NAME"; then
            _success "realm 已成功启动"
            return 0
        fi
        _error_no_exit "realm 启动失败，请检查: systemctl status ${_REALM_SERVICE_NAME}"
        return 1
    fi

    if _has_openrc; then
        mkdir -p "$(dirname "$_REALM_LOG_FILE")"
        cat > "$_REALM_OPENRC_SERVICE_FILE" <<EOF
#!/sbin/openrc-run
name="Realm"
description="Realm Port Forwarding Service"

command="${_REALM_BIN}"
command_args="-c ${_REALM_CONFIG_FILE}"
command_background=true
pidfile="/run/${_REALM_SERVICE_NAME}.pid"
output_log="${_REALM_LOG_FILE}"
error_log="${_REALM_ERR_FILE}"

depend() {
    need net
}
EOF
        chmod 0755 "$_REALM_OPENRC_SERVICE_FILE" || {
            _error_no_exit "写入 OpenRC 服务文件失败: ${_REALM_OPENRC_SERVICE_FILE}"
            return 1
        }
        if ! rc-update add "$_REALM_SERVICE_NAME" default >/dev/null 2>&1; then
            if ! _openrc_service_in_default "$_REALM_SERVICE_NAME"; then
                _error_no_exit "设置 realm 开机自启失败"
                return 1
            fi
        fi
        if ! rc-service "$_REALM_SERVICE_NAME" restart >/dev/null 2>&1; then
            if ! rc-service "$_REALM_SERVICE_NAME" start >/dev/null 2>&1; then
                _error_no_exit "realm 启动失败，请检查: rc-service ${_REALM_SERVICE_NAME} status"
                return 1
            fi
        fi
        sleep 1
        if _realm_service_is_active; then
            _success "realm 已成功启动"
            return 0
        fi
        _error_no_exit "realm 启动失败，请检查: rc-service ${_REALM_SERVICE_NAME} status"
        return 1
    fi

    mkdir -p "$(dirname "$_REALM_LOG_FILE")"
    pkill -x realm >/dev/null 2>&1 || pkill realm >/dev/null 2>&1 || true
    nohup "$_REALM_BIN" -c "$_REALM_CONFIG_FILE" >>"$_REALM_LOG_FILE" 2>>"$_REALM_ERR_FILE" &
    sleep 1
    if _realm_running_pid >/dev/null 2>&1; then
        _success "realm 已成功启动 (非 systemd/OpenRC 模式)"
        return 0
    fi
    _error_no_exit "realm 启动失败"
    return 1
}

_realm_restart() {
    _header "Realm 重启"

    if [[ ! -x "$_REALM_BIN" ]]; then
        _error_no_exit "未检测到 realm，请先安装"
        _press_any_key
        return
    fi

    if _realm_systemd_service_configured; then
        systemctl daemon-reload >/dev/null 2>&1 || true
        if ! systemctl restart "$_REALM_SERVICE_NAME"; then
            _error_no_exit "realm 重启失败，请检查: systemctl status ${_REALM_SERVICE_NAME}"
            _press_any_key
            return
        fi
        sleep 1
        if systemctl is-active --quiet "$_REALM_SERVICE_NAME"; then
            _success "realm 已成功重启"
        else
            _error_no_exit "realm 重启失败，请检查: systemctl status ${_REALM_SERVICE_NAME}"
        fi
    elif _realm_openrc_service_configured; then
        if ! rc-service "$_REALM_SERVICE_NAME" restart >/dev/null 2>&1; then
            if ! rc-service "$_REALM_SERVICE_NAME" start >/dev/null 2>&1; then
                _error_no_exit "realm 重启失败，请检查: rc-service ${_REALM_SERVICE_NAME} status"
                _press_any_key
                return
            fi
        fi
        sleep 1
        if _realm_service_is_active; then
            _success "realm 已成功重启"
        else
            _error_no_exit "realm 重启失败，请检查: rc-service ${_REALM_SERVICE_NAME} status"
        fi
    else
        local pid
        pid=$(_realm_running_pid 2>/dev/null || true)
        if [[ -n "$pid" ]]; then
            kill "$pid" 2>/dev/null || true
            sleep 1
        fi
        if [[ ! -f "$_REALM_CONFIG_FILE" ]]; then
            _error_no_exit "未找到配置文件: ${_REALM_CONFIG_FILE}"
            _press_any_key
            return
        fi
        mkdir -p "$(dirname "$_REALM_LOG_FILE")"
        nohup "$_REALM_BIN" -c "$_REALM_CONFIG_FILE" >>"$_REALM_LOG_FILE" 2>>"$_REALM_ERR_FILE" &
        sleep 1
        if _realm_running_pid >/dev/null 2>&1; then
            _success "realm 已成功启动"
        else
            _error_no_exit "realm 启动失败"
        fi
    fi
    _press_any_key
}

_realm_status() {
    _header "Realm 运行状态"

    if _realm_systemd_service_configured; then
        echo ""
        systemctl status "$_REALM_SERVICE_NAME" --no-pager
    elif _realm_openrc_service_configured; then
        echo ""
        rc-service "$_REALM_SERVICE_NAME" status || true
    else
        local pid
        pid=$(_realm_running_pid 2>/dev/null || true)
        echo ""
        if [[ -n "$pid" ]]; then
            printf "${GREEN}  ✔ ${PLAIN}运行状态: ${GREEN}运行中${PLAIN} (PID: %s)\n" "$pid"
        else
            printf "${GREEN}  ✔ ${PLAIN}运行状态: ${RED}未运行${PLAIN}\n"
        fi
        if [[ -f "$_REALM_CONFIG_FILE" ]]; then
            _info "配置文件: $_REALM_CONFIG_FILE"
            echo ""
            _realm_list_rules
        fi
    fi
    _press_any_key
}

_realm_log() {
    _header "Realm 日志"

    if _realm_systemd_service_configured; then
        _info "显示最近 50 行日志 (Ctrl+C 退出实时跟踪)"
        _separator
        echo ""
        journalctl -u "$_REALM_SERVICE_NAME" --no-pager -n 50
        echo ""
        _separator
        local follow
        read -rp "  实时跟踪日志? [y/N]: " follow
        if [[ "$follow" =~ ^[Yy] ]]; then
            journalctl -u "$_REALM_SERVICE_NAME" -f
        fi
    else
        if ! _tail_log_files_interactive "realm" "$_REALM_LOG_FILE" "$_REALM_ERR_FILE" "rc-service ${_REALM_SERVICE_NAME} status"; then
            _warn "realm 当前未使用 systemd 管理，且未检测到日志文件"
        fi
    fi
    _press_any_key
}

_realm_uninstall() {
    _header "Realm 卸载"

    local confirm remove_config removed_count=0

    _warn "将停止并卸载 Realm，可删除配置目录。"
    printf "    systemd 服务文件: %s\n" "$_REALM_SYSTEMD_SERVICE_FILE"
    printf "    OpenRC 服务文件 : %s\n" "$_REALM_OPENRC_SERVICE_FILE"
    printf "    可执行文件: %s\n" "$_REALM_BIN"
    printf "    配置目录: %s\n" "$_REALM_CONFIG_DIR"
    read -rp "  确认卸载 Realm? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy] ]]; then
        _info "已取消"
        _press_any_key
        return
    fi

    if _has_systemd; then
        systemctl stop "$_REALM_SERVICE_NAME" >/dev/null 2>&1 || true
        systemctl disable "$_REALM_SERVICE_NAME" >/dev/null 2>&1 || true
    fi
    if _has_openrc; then
        rc-service "$_REALM_SERVICE_NAME" stop >/dev/null 2>&1 || true
        rc-update del "$_REALM_SERVICE_NAME" default >/dev/null 2>&1 || true
    fi
    pkill -x realm >/dev/null 2>&1 || pkill realm >/dev/null 2>&1 || true

    if [[ -f "$_REALM_SYSTEMD_SERVICE_FILE" ]]; then
        rm -f "$_REALM_SYSTEMD_SERVICE_FILE"
        removed_count=$((removed_count + 1))
    fi
    if [[ -f "$_REALM_OPENRC_SERVICE_FILE" ]]; then
        rm -f "$_REALM_OPENRC_SERVICE_FILE"
        removed_count=$((removed_count + 1))
    fi
    if _has_systemd; then
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl reset-failed "$_REALM_SERVICE_NAME" >/dev/null 2>&1 || true
    fi

    if [[ -f "$_REALM_BIN" || -L "$_REALM_BIN" ]]; then
        rm -f "$_REALM_BIN"
        removed_count=$((removed_count + 1))
    fi

    if [[ -f "$_REALM_LOG_FILE" || -f "$_REALM_ERR_FILE" ]]; then
        rm -f "$_REALM_LOG_FILE" "$_REALM_ERR_FILE"
        removed_count=$((removed_count + 1))
    fi

    if [[ -d "$_REALM_CONFIG_DIR" ]]; then
        read -rp "  同时删除配置目录 ${_REALM_CONFIG_DIR}? [y/N]: " remove_config
        if [[ "$remove_config" =~ ^[Yy] ]]; then
            rm -rf "$_REALM_CONFIG_DIR"
            removed_count=$((removed_count + 1))
        fi
    fi

    if (( removed_count == 0 )); then
        _warn "未检测到可删除的 Realm 文件，已完成服务清理。"
    else
        _success "Realm 卸载完成"
    fi
    _press_any_key
}

# ---- Realm 规则查看 ----

_realm_list_rules() {
    if [[ ! -f "$_REALM_CONFIG_FILE" ]]; then
        _info "暂无转发规则"
        return
    fi

    local count=0 l r
    printf "  ${BOLD}当前转发规则${PLAIN}\n"
    _separator
    while IFS=$'\x1f' read -r l r; do
        [[ -z "$l" ]] && continue
        printf "  ${GREEN}%2d${PLAIN}  %-24s ${DIM}→${PLAIN} %s\n" "$count" "$l" "$r"
        ((count++))
    done < <(_realm_parse_endpoints "$_REALM_CONFIG_FILE")

    if (( count == 0 )); then
        _info "暂无转发规则"
    else
        _info "共 ${count} 条规则"
    fi
}

_realm_auto_restart_if_active() {
    if ! _realm_service_is_active; then
        return 0
    fi
    _info "检测到 realm 正在运行，自动重启以应用更改..."
    if _realm_systemd_service_configured; then
        systemctl restart "$_REALM_SERVICE_NAME" >/dev/null 2>&1 || true
    elif _realm_openrc_service_configured; then
        rc-service "$_REALM_SERVICE_NAME" restart >/dev/null 2>&1 || true
    else
        local pid
        pid=$(_realm_running_pid 2>/dev/null || true)
        [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
        sleep 1
        nohup "$_REALM_BIN" -c "$_REALM_CONFIG_FILE" >>"$_REALM_LOG_FILE" 2>>"$_REALM_ERR_FILE" &
    fi
    sleep 1
    if _realm_service_is_active; then
        _success "realm 已重启，更改已生效"
    else
        _warn "realm 重启可能失败，请手动检查"
    fi
}

# ---- Realm 规则管理 UI ----

_realm_add_rule() {
    _header "添加转发规则"

    local listen_input listen_port listen_addr remote_host remote_port
    local listen_value listen_value1 listen_value2 remote_value rc
    local addr_type found1 found2 added_count l r

    _info "配置监听端 → 转发目标"
    echo ""

    listen_port=$(_realm_pick_listen_port "8000")

    echo "  选择监听地址类型:"
    echo "    1) 同时监听 IPv4 和 IPv6 (0.0.0.0 和 [::]) [默认]"
    echo "    2) 仅监听 IPv4 (0.0.0.0)"
    echo "    3) 仅监听 IPv6 ([::])"
    echo "    4) 自定义 IP 地址"
    read -rp "  请选择 [1-4，默认 1]: " addr_type
    addr_type=$(_mihomoconf_trim "${addr_type:-1}")

    case "$addr_type" in
        1)
            listen_addr="both"
            ;;
        2)
            listen_addr="0.0.0.0"
            ;;
        3)
            listen_addr="::"
            ;;
        4)
            read -rp "  请输入自定义监听 IP 地址: " listen_input
            listen_addr=$(_mihomoconf_trim "${listen_input:-}")
            if [[ -z "$listen_addr" ]]; then
                _error_no_exit "监听地址不能为空"
                _press_any_key
                return
            fi
            ;;
        *)
            _error_no_exit "无效选择"
            _press_any_key
            return
            ;;
    esac

    if [[ "$listen_addr" == "both" ]]; then
        listen_value1="0.0.0.0:${listen_port}"
        listen_value2="[::]:${listen_port}"
    elif [[ "$listen_addr" == *:* ]]; then
        listen_value="[${listen_addr}]:${listen_port}"
    else
        listen_value="${listen_addr}:${listen_port}"
    fi

    while true; do
        read -rp "  转发目标 IP/域名: " remote_host
        remote_host=$(_mihomoconf_trim "${remote_host:-}")
        if [[ -z "$remote_host" ]]; then
            _warn "转发目标不能为空"
            continue
        fi
        break
    done

    while true; do
        read -rp "  转发目标端口 [1-65535]: " remote_port
        remote_port=$(_mihomoconf_trim "${remote_port:-}")
        if ! _is_valid_port "$remote_port"; then
            _warn "端口无效，请输入 1-65535 的数字"
            continue
        fi
        break
    done

    if [[ "$remote_host" == *:* ]]; then
        remote_value="[${remote_host}]:${remote_port}"
    else
        remote_value="${remote_host}:${remote_port}"
    fi

    if [[ -n "$listen_value1" && -n "$listen_value2" ]]; then
        found1=0
        found2=0
        if [[ -f "$_REALM_CONFIG_FILE" ]]; then
            while IFS=$'\x1f' read -r l r; do
                [[ "$l" == "$listen_value1" ]] && found1=1
                [[ "$l" == "$listen_value2" ]] && found2=1
            done < <(_realm_parse_endpoints "$_REALM_CONFIG_FILE")
        fi
        if (( found1 == 1 && found2 == 1 )); then
            _error_no_exit "监听地址 ${listen_value1} 和 ${listen_value2} 已存在"
            _press_any_key
            return
        fi

        added_count=0
        if (( found1 == 0 )); then
            _realm_add_endpoint_to_config "$listen_value1" "$remote_value"
            ((added_count++))
        fi
        if (( found2 == 0 )); then
            _realm_add_endpoint_to_config "$listen_value2" "$remote_value"
            ((added_count++))
        fi
        _success "转发规则已添加: (同时监听 IPv4 和 IPv6) → ${remote_value}"
    else
        _realm_add_endpoint_to_config "$listen_value" "$remote_value"
        rc=$?
        if [[ $rc -eq 2 ]]; then
            _error_no_exit "监听地址 ${listen_value} 已存在，请先删除旧规则"
            _press_any_key
            return
        elif [[ $rc -ne 0 ]]; then
            _error_no_exit "写入配置失败"
            _press_any_key
            return
        fi
        _success "转发规则已添加: ${listen_value} → ${remote_value}"
    fi

    _realm_auto_restart_if_active
    _press_any_key
}

_realm_delete_rule() {
    _header "删除转发规则"

    if [[ ! -f "$_REALM_CONFIG_FILE" ]]; then
        _info "暂无转发规则"
        _press_any_key
        return
    fi

    _realm_list_rules
    echo ""

    local count=0 l r
    while IFS=$'\x1f' read -r l r; do
        [[ -z "$l" ]] && continue
        ((count++))
    done < <(_realm_parse_endpoints "$_REALM_CONFIG_FILE")

    if (( count == 0 )); then
        _press_any_key
        return
    fi

    local index
    read -rp "  输入要删除的规则编号 [0-$((count - 1))，或按 Enter 取消]: " index
    if [[ -z "${index:-}" ]]; then
        _info "已取消"
        _press_any_key
        return
    fi
    if ! _is_digit "${index:-}" || (( index < 0 || index >= count )); then
        _error_no_exit "无效的编号"
        _press_any_key
        return
    fi

    _realm_delete_endpoint_from_config "$index"
    _success "规则已删除"
    _realm_auto_restart_if_active
    _press_any_key
}

_realm_view_rules() {
    _header "查看转发规则"
    echo ""
    _realm_list_rules
    echo ""

    if _realm_service_is_active; then
        _success "Realm 服务状态: 运行中"
    else
        _warn "Realm 服务状态: 未运行"
    fi
    _press_any_key
}

_realm_configure() {
    _header "Realm 转发规则管理"

    if [[ ! -x "$_REALM_BIN" ]]; then
        local install_confirm
        read -rp "  未检测到 realm，先安装? [Y/n]: " install_confirm
        if [[ "$install_confirm" =~ ^([Nn]|[Nn][Oo])$ ]]; then
            _info "已取消"
            _press_any_key
            return
        fi
        _time_sync_check_and_enable
        if ! _realm_install_latest_core; then
            _press_any_key
            return
        fi
    fi

    while true; do
        _ui_print_screen _realm_configure_screen

        local ch
        read -rp "  选择 [0-3]: " ch
        case "$ch" in
            1) _realm_add_rule ;;
            2) _realm_delete_rule ;;
            3) _realm_enable_now ; _press_any_key ;;
            0) return ;;
            *) _error_no_exit "无效选项"; sleep 1 ;;
        esac
    done
}

_realm_configure_screen() {
    _header "Realm 转发规则管理"
    echo ""

    if [[ -f "$_REALM_CONFIG_FILE" ]]; then
        _realm_list_rules
    else
        _info "暂无转发规则，配置文件未创建"
    fi

    echo ""
    _separator
    _menu_item "1" "添加转发规则" "监听端口 → 目标地址" "green"
    _menu_item "2" "删除转发规则" "" "yellow"
    _menu_item "3" "启动/重启 Realm" "启用服务" "green"
    _menu_item "0" "返回" "" "red"
    _separator
}

_realm_manage_screen() {
    _header "Realm 端口转发管理"

    local realm_ver="未安装"
    local realm_status="未运行"
    local realm_status_tone="red"
    local realm_file="不存在"
    local realm_file_tone="red"
    local realm_rules="0 条"
    local realm_rules_tone="dim"
    local count=0 l r has_rules=0

    if [[ -x "$_REALM_BIN" ]]; then
        local ver
        ver=$(_realm_bin_version)
        realm_ver="${ver:-已安装}"
    fi

    if _realm_service_is_active; then
        realm_status="运行中"
        realm_status_tone="green"
    fi

    if [[ -f "$_REALM_CONFIG_FILE" ]]; then
        realm_file="$_REALM_CONFIG_FILE"
        realm_file_tone="dim"
        local rule_count=0
        while IFS=$'\x1f' read -r l r; do
            [[ -z "$l" ]] && continue
            ((rule_count++))
        done < <(_realm_parse_endpoints "$_REALM_CONFIG_FILE")
        realm_rules="${rule_count} 条规则"
        if [ "$rule_count" -gt 0 ]; then
            realm_rules_tone="green"
        fi
    fi

    printf "  ${BOLD}状态信息${PLAIN}\n"
    _separator
    _status_kv_pair "版本" "$realm_ver" "dim" 8 "状态" "$realm_status" "$realm_status_tone" 8
    _status_kv_pair "配置" "$realm_file" "$realm_file_tone" 8 "规则" "$realm_rules" "$realm_rules_tone" 8

    if [[ -f "$_REALM_CONFIG_FILE" ]]; then
        while IFS=$'\x1f' read -r l r; do
            [[ -z "$l" ]] && continue
            if (( has_rules == 0 )); then
                echo ""
                printf "  ${BOLD}当前转发规则${PLAIN}\n"
                _separator
                has_rules=1
            fi
            printf "  ${GREEN}%2d${PLAIN}  %-24s ${DIM}→${PLAIN} %s\n" "$count" "$l" "$r"
            ((count++))
        done < <(_realm_parse_endpoints "$_REALM_CONFIG_FILE")
    fi

    _separator
    _menu_pair "1" "安装/更新 Realm" "下载二进制" "green" "2" "管理转发规则" "添加/删除规则" "green"
    _menu_pair "3" "查看转发规则" "规则列表" "green" "4" "重启 Realm" "" "green"
    _menu_pair "5" "查看状态" "" "green" "6" "查看日志" "" "green"
    _menu_item "7" "卸载 Realm" "停止并清理" "yellow"
    _menu_item "0" "返回上级菜单" "" "red"
    _separator
}

_realm_manage() {
    while true; do
        _ui_print_screen _realm_manage_screen

        local ch
        read -rp "  ${CYAN}➜${PLAIN}  选择 [0-7]: " ch
        case "$ch" in
            1) _realm_install_or_update ;;
            2) _realm_configure ;;
            3) _realm_view_rules ;;
            4) _realm_restart ;;
            5) _realm_status ;;
            6) _realm_log ;;
            7) _realm_uninstall ;;
            0) return ;;
            *) _error_no_exit "无效选项"; sleep 1 ;;
        esac
    done
}

# --- 13. Shadowsocks-Rust 管理 ---

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

    # 1. Try pid file first
    if [[ -f "$pid_file" ]]; then
        pid=$(tr -cd '0-9' < "$pid_file" 2>/dev/null || true)
        if _is_digit "${pid:-}" && kill -0 "$pid" >/dev/null 2>&1; then
            printf '%s' "$pid"
            return 0
        fi
    fi

    # 2. Try pgrep
    if command -v pgrep >/dev/null 2>&1; then
        pid=$(pgrep -x ssserver 2>/dev/null | head -n1 || true)
        if [[ -z "$pid" ]]; then
            pid=$(pgrep ssserver 2>/dev/null | head -n1 || true)
        fi
        if _is_digit "${pid:-}" && kill -0 "$pid" >/dev/null 2>&1; then
            printf '%s' "$pid"
            return 0
        fi
        return 1 # If pgrep exists but found nothing, ssserver is not running
    fi

    # 3. Try pidof
    if command -v pidof >/dev/null 2>&1; then
        pid=$(pidof ssserver 2>/dev/null | awk '{print $1}' || true)
        if _is_digit "${pid:-}" && kill -0 "$pid" >/dev/null 2>&1; then
            printf '%s' "$pid"
            return 0
        fi
        return 1 # If pidof exists but found nothing, ssserver is not running
    fi

    # 4. Try ps
    if command -v ps >/dev/null 2>&1; then
        pid=$(ps -eo pid=,comm= 2>/dev/null | awk '$2 == "ssserver" {print $1; exit}' || true)
        if [[ -z "$pid" ]]; then
            pid=$(ps -eo pid=,args= 2>/dev/null | awk '
                $0 ~ /(^|[[:space:]])ssserver([[:space:]]|$)/ {print $1; exit}
                $0 ~ /\/ssserver([[:space:]]|$)/ {print $1; exit}
            ' || true)
        fi
        if [[ -z "$pid" ]]; then
            pid=$(ps w 2>/dev/null | awk '/[s]sserver/ {if ($1 ~ /^[0-9]+$/) {print $1; exit}}' || true)
        fi
        if _is_digit "${pid:-}" && kill -0 "$pid" >/dev/null 2>&1; then
            printf '%s' "$pid"
            return 0
        fi
        return 1 # If ps exists but found nothing, ssserver is not running
    fi

    # 5. Fallback: Loop /proc without forking (using read built-in)
    for d in /proc/[0-9]*; do
        [[ -d "$d" ]] || continue
        p="${d##*/}"
        [[ "$p" =~ ^[0-9]+$ ]] || continue
        if [[ -r "$d/comm" ]]; then
            # Use read built-in to avoid head fork
            read -r pid < "$d/comm" 2>/dev/null || true
            if [[ "$pid" == "ssserver" ]] && kill -0 "$p" >/dev/null 2>&1; then
                printf '%s' "$p"
                return 0
            fi
        fi
        if [[ -r "$d/cmdline" ]]; then
            # Only check cmdline if comm check wasn't positive
            # Use read to read the null-separated cmdline into a variable to avoid tr/grep fork
            local cmdline_val
            if read -r -d '' cmdline_val < "$d/cmdline" 2>/dev/null; then
                if [[ "$cmdline_val" == *"ssserver"* ]]; then
                    if kill -0 "$p" >/dev/null 2>&1; then
                        printf '%s' "$p"
                        return 0
                    fi
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
    err_log=$(_mktemp_file shadowsocks-rust.extract .log) || return 1
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

    tmp_file=$(_mktemp_file shadowsocks-rust.config .json) || return 1
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

    latest_json=$(curl -fsSL "$(_github_proxy_url "$_SSRUST_RELEASE_API")" 2>/dev/null || true)
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
    tmp_pkg=$(_mktemp_file shadowsocks-rust ".${pkg_suffix}") || {
        _error_no_exit "创建临时文件失败"
        return 1
    }
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
    if command -v jq >/dev/null 2>&1; then
        local val
        val=$(jq -r ".${key}" "$_SSRUST_CONFIG_FILE" 2>/dev/null || true)
        if [[ -n "$val" && "$val" != "null" ]]; then
            if [[ "$val" =~ ^\{ || "$val" =~ ^\[ ]]; then
                jq -c ".${key}" "$_SSRUST_CONFIG_FILE" 2>/dev/null || true
            else
                echo "$val"
            fi
            return 0
        fi
        return 1
    fi
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

_resolve_ipv4() {
    local host="$1" ip
    if command -v dig >/dev/null 2>&1; then
        ip=$(dig +short "$host" A 2>/dev/null | grep -E '^[0-9.]+$' | head -n1)
        if [[ -n "$ip" ]]; then
            echo "$ip"
            return 0
        fi
    fi
    if command -v host >/dev/null 2>&1; then
        ip=$(host -t A "$host" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
        if [[ -n "$ip" ]]; then
            echo "$ip"
            return 0
        fi
    fi
    if command -v getent >/dev/null 2>&1; then
        ip=$(getent ahosts "$host" 2>/dev/null | awk '{print $1}' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
        if [[ -n "$ip" ]]; then
            echo "$ip"
            return 0
        fi
    fi
    case "$host" in
        dns.alidns.com) echo "223.5.5.5" ;;
        doh.pub|dot.pub) echo "119.29.29.29" ;;
        dns.volcengine.com) echo "180.184.1.1" ;;
        doh.360.cn|dot.360.cn) echo "101.226.4.6" ;;
        cloudflare-dns.com) echo "1.1.1.1" ;;
        doh.opendns.com|dns.opendns.com) echo "208.67.222.222" ;;
        dns.google) echo "8.8.8.8" ;;
        dns.adguard-dns.com) echo "94.140.14.14" ;;
        dns.quad9.net) echo "9.9.9.9" ;;
        dns11.quad9.net) echo "9.9.9.11" ;;
        dns.nextdns.io) echo "45.90.28.0" ;;
        *) echo "" ;;
    esac
}

_ssrust_dns_url_to_json() {
    local url="$1"
    if [[ "$url" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(:[0-9]+)?$ ]]; then
        local ip="$url"
        local port="53"
        if [[ "$ip" == *":"* ]]; then
            port="${ip##*:}"
            ip="${ip%:*}"
        fi
        printf '{"socket_addr":"%s:%s","protocol":"Udp","trust_negative_responses":true}' "$ip" "$port"
        return 0
    fi
    if [[ "$url" != *"://"* ]]; then
        case "$url" in
            google|cloudflare|quad9|system)
                local ip="8.8.8.8"
                if [[ "$url" == "cloudflare" ]]; then
                    ip="1.1.1.1"
                elif [[ "$url" == "quad9" ]]; then
                    ip="9.9.9.9"
                elif [[ "$url" == "system" ]]; then
                    printf '{"socket_addr":"8.8.8.8:53","protocol":"Udp","trust_negative_responses":true}'
                    return 0
                fi
                printf '{"socket_addr":"%s:53","protocol":"Udp","trust_negative_responses":true}' "$ip"
                return 0
                ;;
        esac
        local ip
        ip=$(_resolve_ipv4 "$url")
        if [[ -n "$ip" ]]; then
            printf '{"socket_addr":"%s:53","protocol":"Udp","trust_negative_responses":true}' "$ip"
        else
            return 1
        fi
        return 0
    fi
    local proto="${url%%://*}"
    local rest="${url#*://}"
    local host_path="${rest%%/*}"
    local host="$host_path"
    local port=""
    if [[ "$host" == *":"* ]]; then
        port="${host##*:}"
        host="${host%:*}"
    fi
    local protocol="Udp"
    local default_port="53"
    case "$proto" in
        https) protocol="Https"; default_port="443" ;;
        tls) protocol="Tls"; default_port="853" ;;
        quic) protocol="Quic"; default_port="853" ;;
        h3) protocol="H3"; default_port="443" ;;
    esac
    if [[ -z "$port" ]]; then
        port="$default_port"
    fi
    local ip
    ip=$(_resolve_ipv4 "$host")
    if [[ -z "$ip" ]]; then
        if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            ip="$host"
        else
            return 1
        fi
    fi
    printf '{"socket_addr":"%s:%s","protocol":"%s","tls_dns_name":"%s","trust_negative_responses":true}' "$ip" "$port" "$protocol" "$host"
}

_ssrust_dns_process_and_set() {
    local config_file="$1"
    local dns_list_str="$2"

    if [[ -z "$dns_list_str" ]]; then
        _error_no_exit "DNS 地址为空"
        return 1
    fi

    local -a dns_arr
    IFS=',' read -r -a dns_arr <<< "$dns_list_str"

    _info "正在对 DNS 服务器 进行可用性测试 (请稍候)..."
    _separator

    local -a ok_dns=()
    local -a fail_dns=()

    for dns in "${dns_arr[@]}"; do
        dns=$(echo "$dns" | xargs)
        [[ -z "$dns" ]] && continue

        local test_target="$dns"
        case "$dns" in
            google) test_target="8.8.8.8" ;;
            cloudflare) test_target="1.1.1.1" ;;
            quad9) test_target="9.9.9.9" ;;
            system) test_target="" ;;
        esac

        if [[ -z "$test_target" ]]; then
            printf "  • %-50s [  ${GREEN}已跳过(系统/内置)${PLAIN}  ]\n" "$dns"
            ok_dns+=("$dns")
            continue
        fi

        printf "  • %-50s " "$dns"
        if _mihomo_dns_test_availability "$test_target"; then
            printf "[  ${GREEN}可用${PLAIN}  ]\n"
            ok_dns+=("$dns")
        else
            printf "[ ${RED}不可用/超时${PLAIN} ]\n"
            fail_dns+=("$dns")
        fi
    done
    _separator

    local final_dns_list=""
    if [[ "${#ok_dns[@]}" -eq 0 ]]; then
        _warn "警告: 所有选中的 DNS 节点均测试失败！"
        local confirm
        read -rp "  是否依然强制应用这些 DNS 配置？[y/N]: " confirm
        if [[ "$confirm" =~ ^[yY](es)?$ ]]; then
            final_dns_list="$dns_list_str"
        else
            _info "配置应用已取消。"
            _press_any_key
            return 1
        fi
    elif [[ "${#fail_dns[@]}" -gt 0 ]]; then
        _warn "检测到部分 DNS 服务器在当前网络下不可用。"
        local choice
        read -rp "  是否仅保留测试成功的 DNS 服务器？(如果选择否，将写入全部选择) [Y/n]: " choice
        if [[ -z "$choice" || "$choice" =~ ^[yY](es)?$ ]]; then
            final_dns_list=$(IFS=,; echo "${ok_dns[*]}")
        else
            final_dns_list="$dns_list_str"
        fi
    else
        _success "选中的 DNS 服务器均可用"
        final_dns_list="$dns_list_str"
    fi

    if [[ -n "$final_dns_list" ]]; then
        local -a final_arr
        IFS=',' read -r -a final_arr <<< "$final_dns_list"
        
        local write_val
        local is_simple=0
        if [[ "${#final_arr[@]}" -eq 1 ]]; then
            local item="${final_arr[0]}"
            if [[ "$item" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(:[0-9]+)?$ ]] || [[ "$item" =~ ^(google|cloudflare|quad9|system)$ ]]; then
                is_simple=1
            fi
        fi
        
        if [[ "$is_simple" -eq 1 ]]; then
            write_val="${final_arr[0]}"
        else
            local ns_json=""
            for item in "${final_arr[@]}"; do
                local server_json
                server_json=$(_ssrust_dns_url_to_json "$item")
                if [[ -n "$server_json" ]]; then
                    if [[ -n "$ns_json" ]]; then
                        ns_json="${ns_json},"
                    fi
                    ns_json="${ns_json}${server_json}"
                fi
            done
            write_val="{\"name_servers\":[${ns_json}]}"
        fi

        _ssrust_conf_set_value "dns" "$write_val"
        _success "DNS 成功配置为: $final_dns_list"
        _ssrust_dns_restart_prompt
        return 0
    else
        _info "未写入任何配置。"
        _press_any_key
        return 1
    fi
}

_ssrust_dns_domestic_menu() {
    local config_file="$1"
    while true; do
        _header "国内公共 DNS"
        printf "  ${BOLD}请选择要启用的公共 DNS 服务商 (可输入多个，空格分隔，如 '2 1'):${PLAIN}\n"
        _separator
        printf "    ${GREEN}1${PLAIN}) AliDNS (阿里)         ${DIM}(支持 DoH/DoT/DoQ/UDP)${PLAIN}\n"
        printf "    ${GREEN}2${PLAIN}) DNSPod (腾讯)         ${DIM}(支持 DoH/DoT/UDP)${PLAIN}\n"
        printf "    ${GREEN}3${PLAIN}) Volcengine DNS (字节)   ${DIM}(支持 DoH/DoT/UDP)${PLAIN}\n"
        printf "    ${GREEN}4${PLAIN}) 360 Secure DNS        ${DIM}(支持 DoH/DoT/UDP)${PLAIN}\n"
        printf "    ${GREEN}5${PLAIN}) Baidu DNS (百度)      ${DIM}(仅支持 UDP: 180.76.76.76)${PLAIN}\n"
        printf "    ${GREEN}6${PLAIN}) 114DNS               ${DIM}(仅支持 UDP: 114.114.114.114)${PLAIN}\n"
        printf "    ${GREEN}0${PLAIN}) 返回上一级\n"
        _separator
        local choices
        read -rp "  选择服务商: " -a choices
        if [[ "${#choices[@]}" -eq 0 ]]; then
            _warn "未选择任何服务商"
            sleep 1
            continue
        fi
        if [[ "${choices[0]}" == "0" ]]; then
            return
        fi

        local has_valid=0
        for ch in "${choices[@]}"; do
            if [[ "$ch" =~ ^[1-6]$ ]]; then
                has_valid=1
            fi
        done
        if [[ "$has_valid" -eq 0 ]]; then
            _error_no_exit "没有有效选择，请重新选择"
            sleep 1
            continue
        fi

        # Protocol choices
        printf "\n"
        printf "  ${BOLD}请选择 DNS 协议类型:${PLAIN}\n"
        _separator
        printf "    ${GREEN}1${PLAIN}) DoH (DNS-over-HTTPS, 默认)\n"
        printf "    ${GREEN}2${PLAIN}) DoT (DNS-over-TLS)\n"
        printf "    ${GREEN}3${PLAIN}) DoQ (DNS-over-QUIC)\n"
        printf "    ${GREEN}4${PLAIN}) 普通 UDP\n"
        _separator
        local proto_choice
        read -rp "  选择协议 [1-4, 默认 1]: " proto_choice
        if [[ -z "$proto_choice" ]]; then
            proto_choice="1"
        fi

        local dns_urls=()
        for ch in "${choices[@]}"; do
            if [[ "$ch" =~ ^[1-6]$ ]]; then
                local url
                url=$(_get_domestic_dns_url "$ch" "$proto_choice")
                if [[ -n "$url" ]]; then
                    dns_urls+=("$url")
                fi
            fi
        done

        if [[ "${#dns_urls[@]}" -eq 0 ]]; then
            _error_no_exit "没有解析出任何 DNS 地址，请重新选择"
            sleep 1
            continue
        fi

        local dns_list_str
        dns_list_str=$(IFS=,; echo "${dns_urls[*]}")
        _ssrust_dns_process_and_set "$config_file" "$dns_list_str"
        return
    done
}

_ssrust_dns_foreign_menu() {
    local config_file="$1"
    while true; do
        _header "国外公共 DNS"
        printf "  ${BOLD}请选择要启用的公共 DNS 服务商 (可输入多个，空格分隔，如 '2 1'):${PLAIN}\n"
        _separator
        printf "    ${GREEN}1${PLAIN}) Cloudflare DNS  ${DIM}(支持 DoH/DoT/UDP)${PLAIN}\n"
        printf "    ${GREEN}2${PLAIN}) Google DNS      ${DIM}(支持 DoH/DoT/UDP)${PLAIN}\n"
        printf "    ${GREEN}3${PLAIN}) AdGuard DNS     ${DIM}(支持 DoH/DoT/DoQ/UDP)${PLAIN}\n"
        printf "    ${GREEN}4${PLAIN}) Quad9 DNS       ${DIM}(支持 DoH/DoT/DoQ/UDP)${PLAIN}\n"
        printf "    ${GREEN}5${PLAIN}) NextDNS         ${DIM}(支持 DoH/DoT/DoQ/UDP)${PLAIN}\n"
        printf "    ${GREEN}6${PLAIN}) OpenDNS         ${DIM}(支持 DoH/DoT/UDP)${PLAIN}\n"
        printf "    ${GREEN}0${PLAIN}) 返回上一级\n"
        _separator
        local choices
        read -rp "  选择服务商: " -a choices
        if [[ "${#choices[@]}" -eq 0 ]]; then
            _warn "未选择任何服务商"
            sleep 1
            continue
        fi
        if [[ "${choices[0]}" == "0" ]]; then
            return
        fi

        local has_valid=0
        for ch in "${choices[@]}"; do
            if [[ "$ch" =~ ^[1-6]$ ]]; then
                has_valid=1
            fi
        done
        if [[ "$has_valid" -eq 0 ]]; then
            _error_no_exit "没有有效选择，请重新选择"
            sleep 1
            continue
        fi

        # Protocol choices
        printf "\n"
        printf "  ${BOLD}请选择 DNS 协议类型:${PLAIN}\n"
        _separator
        printf "    ${GREEN}1${PLAIN}) DoH (DNS-over-HTTPS, 默认)\n"
        printf "    ${GREEN}2${PLAIN}) DoT (DNS-over-TLS)\n"
        printf "    ${GREEN}3${PLAIN}) DoQ (DNS-over-QUIC)\n"
        printf "    ${GREEN}4${PLAIN}) 普通 UDP\n"
        _separator
        local proto_choice
        read -rp "  选择协议 [1-4, 默认 1]: " proto_choice
        if [[ -z "$proto_choice" ]]; then
            proto_choice="1"
        fi

        local dns_urls=()
        for ch in "${choices[@]}"; do
            if [[ "$ch" =~ ^[1-6]$ ]]; then
                local url
                url=$(_get_foreign_dns_url "$ch" "$proto_choice")
                if [[ -n "$url" ]]; then
                    dns_urls+=("$url")
                fi
            fi
        done

        if [[ "${#dns_urls[@]}" -eq 0 ]]; then
            _error_no_exit "没有解析出任何 DNS 地址，请重新选择"
            sleep 1
            continue
        fi

        local dns_list_str
        dns_list_str=$(IFS=,; echo "${dns_urls[*]}")
        _ssrust_dns_process_and_set "$config_file" "$dns_list_str"
        return
    done
}

_ssrust_dns_preset_menu() {
    local config_file="$1"
    while true; do
        _header "内置预设 DNS"
        _info "作用: 使用 Shadowsocks-Rust 内置解析 of 预设服务商"
        _separator
        printf "    ${GREEN}1${PLAIN}) google          ${DIM}(Google 默认解析器)${PLAIN}\n"
        printf "    ${GREEN}2${PLAIN}) cloudflare      ${DIM}(Cloudflare 默认解析器)${PLAIN}\n"
        printf "    ${GREEN}3${PLAIN}) quad9           ${DIM}(Quad9 默认解析器)${PLAIN}\n"
        printf "    ${GREEN}4${PLAIN}) system          ${DIM}(系统默认解析器)${PLAIN}\n"
        printf "    ${GREEN}0${PLAIN}) 返回上一级\n"
        _separator
        local choice dns_val
        read -rp "  选择内置预设 [0-4]: " choice
        case "$choice" in
            1) dns_val="google" ;;
            2) dns_val="cloudflare" ;;
            3) dns_val="quad9" ;;
            4) dns_val="system" ;;
            0) return ;;
            *) _error_no_exit "无效选项"; sleep 1; continue ;;
        esac
        
        _ssrust_dns_process_and_set "$config_file" "$dns_val"
        return
    done
}

_ssrust_dns_custom_input() {
    local config_file="$1"
    _header "自定义 DNS 配置"
    _info "支持以下格式:"
    printf "    - 普通 IP: ${GREEN}223.5.5.5${PLAIN} 或 ${GREEN}8.8.8.8:53${PLAIN}\n"
    printf "    - 预设服务商: ${GREEN}google${PLAIN}, ${GREEN}cloudflare${PLAIN}, ${GREEN}quad9${PLAIN}, ${GREEN}system${PLAIN}\n"
    _separator
    local raw_input
    read -rp "  请输入 DNS 地址/服务商: " raw_input
    raw_input=$(_mihomoconf_trim "${raw_input:-}")
    if [[ -z "$raw_input" ]]; then
        _warn "输入为空，已取消"
        _press_any_key
        return
    fi
    
    _ssrust_dns_process_and_set "$config_file" "$raw_input"
}

_ssrust_dns_manage() {
    local config_file="$_SSRUST_CONFIG_FILE"
    if [[ ! -f "$config_file" ]]; then
        _error_no_exit "未找到配置文件: ${config_file}"
        _info "请先在 Shadowsocks-Rust 菜单中配置并启动"
        _press_any_key
        return
    fi

    while true; do
        _header "Shadowsocks-Rust DNS 设置"
        _info "配置文件: ${config_file}"
        printf "\n"
        
        local current_dns displayed_dns
        current_dns=$(_ssrust_conf_get_value "dns" 2>/dev/null || true)
        if [[ -z "$current_dns" ]]; then
            displayed_dns="未配置 (使用系统默认)"
        elif [[ "$current_dns" =~ ^\{ ]]; then
            if command -v jq >/dev/null 2>&1; then
                displayed_dns=$(echo "$current_dns" | jq -r '.name_servers[] | "\(.socket_addr) (\(.protocol))"' 2>/dev/null | tr '\n' ',' | sed 's/,$//')
            else
                displayed_dns=$(echo "$current_dns" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(:[0-9]+)?' | tr '\n' ',' | sed 's/,$//')
            fi
        else
            displayed_dns="$current_dns"
        fi
        
        printf "  ${BOLD}当前 DNS 设置:${PLAIN} ${GREEN}%s${PLAIN}\n" "$displayed_dns"
        _separator
        _menu_pair "1" "使用国内公共 DNS" "腾讯/阿里/火山等 (多协议选择)" "green" \
                   "2" "使用国外公共 DNS" "Google/Cloudflare/AdGuard" "green"
        _menu_pair "3" "使用内置预设 DNS" "google / cloudflare / quad9" "green" \
                   "4" "自定义 DNS 服务器" "支持输入 IP (如 8.8.8.8) 或 DoH/DoT 域名" "yellow"
        _menu_item "5" "重置为系统默认" "移除 dns 配置 (使用 system)" "red"
        _menu_item "0" "返回上级菜单" "" "red"
        _separator

        local ch
        read -rp "  选择 [0-5]: " ch
        case "$ch" in
            1)
                _ssrust_dns_domestic_menu "$config_file"
                ;;
            2)
                _ssrust_dns_foreign_menu "$config_file"
                ;;
            3)
                _ssrust_dns_preset_menu "$config_file"
                ;;
            4)
                _ssrust_dns_custom_input "$config_file"
                ;;
            5)
                _ssrust_conf_delete_key "dns"
                _success "DNS 配置已移除，将使用系统默认"
                _ssrust_dns_restart_prompt
                ;;
            0)
                return
                ;;
            *)
                _error_no_exit "无效选项"
                sleep 1
                ;;
        esac
    done
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
    local _out_var="${2:-}"
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
        if [[ -n "$_out_var" ]]; then
            printf -v "$_out_var" '%s' "$port_input"
            return 0
        fi
        printf '%s' "$port_input"
        return 0
    done
}

_ssrust_gen_ss_uri_link() {
    local server="$1" port="$2" method="$3" password="$4" name="$5"
    local enable_udp="${6:-1}" enable_uot="${7:-1}"
    local userinfo encoded_name server_uri query
    local -a params=()

    userinfo=$(_mihomoconf_url_base64 "${method}:${password}")
    encoded_name=$(_mihomoconf_urlencode "${name}")
    server_uri=$(_snell_uri_host "$server")
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
    printf 'ss://%s@%s:%s?%s#%s' "$userinfo" "$server_uri" "$port" "$query" "$encoded_name"
}

_ssrust_write_config() {
    local listen_addr="$1" port="$2" method="$3" password="$4" mode="$5" dns_val="${6:-}"
    mkdir -p "$_SSRUST_CONFIG_DIR"
    if [[ -n "$dns_val" ]]; then
        local dns_formatted
        if [[ "$dns_val" =~ ^\{ || "$dns_val" =~ ^\[ ]]; then
            dns_formatted="$dns_val"
        else
            dns_formatted="\"$dns_val\""
        fi
        cat > "$_SSRUST_CONFIG_FILE" <<EOF
{
  "server": "${listen_addr}",
  "server_port": ${port},
  "password": "${password}",
  "method": "${method}",
  "mode": "${mode}",
  "fast_open": false,
  "dns": ${dns_formatted}
}
EOF
    else
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
    fi
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
        read -rp "  未检测到 ssserver，先安装? [Y/n]: " install_confirm
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

    local current_port current_method current_password current_mode current_server current_dns
    local listen_port method_pick method_default method_value
    local password_input password_value current_password_compatible
    local mode_pick mode_default mode_value
    local listen_input listen_addr host_default host_input client_host
    local uri_link udp_bool ss_export_uot_answer ss_export_udp="1" ss_export_uot="1" ss_export_uot_bool="true"

    current_port=$(_ssrust_conf_get_value "server_port" 2>/dev/null || true)
    _is_valid_port "${current_port:-}" || current_port="8388"
    current_method=$(_ssrust_conf_get_value "method" 2>/dev/null || true)
    current_password=$(_ssrust_conf_get_value "password" 2>/dev/null || true)
    current_mode=$(_ssrust_conf_get_value "mode" 2>/dev/null || true)
    current_server=$(_ssrust_conf_get_value "server" 2>/dev/null || true)
    current_dns=$(_ssrust_conf_get_value "dns" 2>/dev/null || true)

    _ssrust_pick_listen_port "$current_port" listen_port

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

    _ssrust_write_config "$listen_addr" "$listen_port" "$method_value" "$password_value" "$mode_value" "$current_dns"
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

    udp_bool="true"
    if [[ "$mode_value" == "tcp_only" ]]; then
        udp_bool="false"
        ss_export_udp="0"
        ss_export_uot="0"
        ss_export_uot_bool="false"
    else
        read -rp "  SS-Rust 导出: 开启 UDP over TCP v2? [Y/n]: " ss_export_uot_answer
        if [[ "$ss_export_uot_answer" =~ ^([Nn]|[Nn][Oo])$ ]]; then
            ss_export_uot="0"
            ss_export_uot_bool="false"
        fi
    fi
    uri_link=$(_ssrust_gen_ss_uri_link "$client_host" "$listen_port" "$method_value" "$password_value" "SS-Rust" "$ss_export_udp" "$ss_export_uot")

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
    if [[ "$ss_export_udp" == "1" ]]; then
        printf "      tfo: true\n"
        printf "      udp-over-tcp: %s\n" "$ss_export_uot_bool"
        if [[ "$ss_export_uot" == "1" ]]; then
            printf "      udp-over-tcp-version: 2\n"
        fi
    fi
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
        read -rp "  覆盖? [y/N]: " overwrite
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
    local uri_link udp_bool network_json_line ss_export_uot_answer ss_export_udp="1" ss_export_uot="1" ss_export_uot_bool="true"
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

    udp_bool="true"
    if [[ "$mode" == "tcp_only" ]]; then
        udp_bool="false"
        ss_export_udp="0"
        ss_export_uot="0"
        ss_export_uot_bool="false"
    else
        read -rp "  SS-Rust 导出: 开启 UDP over TCP v2? [Y/n]: " ss_export_uot_answer
        if [[ "$ss_export_uot_answer" =~ ^([Nn]|[Nn][Oo])$ ]]; then
            ss_export_uot="0"
            ss_export_uot_bool="false"
        fi
    fi
    uri_link=$(_ssrust_gen_ss_uri_link "$client_host" "$listen_port" "$method" "$password" "$node_name" "$ss_export_udp" "$ss_export_uot")
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
udp=${ss_export_udp}
udp_over_tcp=${ss_export_uot}
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
    if [[ "$ss_export_udp" == "1" ]]; then
        cat >> "$mihomo_file" <<EOF
    tfo: true
    udp-over-tcp: ${ss_export_uot_bool}
EOF
        if [[ "$ss_export_uot" == "1" ]]; then
            printf "    udp-over-tcp-version: 2\n" >> "$mihomo_file"
        fi
    fi

    cat > "$singbox_file" <<EOF
{
  "type": "shadowsocks",
  "tag": "${q_name}",
  "server": "${q_server}",
  "server_port": ${listen_port},
  "method": "${q_method}",
${network_json_line}
  "password": "${q_password}",
  "udp_over_tcp": {
    "enabled": ${ss_export_uot_bool},
    "version": 2
  }
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
        read -rp "  实时跟踪日志? [y/N]: " follow
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

    _warn "将停止并卸载 Shadowsocks-Rust，可删除配置目录与日志。"
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
        read -rp "  同时删除配置目录 ${_SSRUST_CONFIG_DIR}? [y/N]: " remove_config
        if [[ "$remove_config" =~ ^[Yy] ]]; then
            rm -rf "$_SSRUST_CONFIG_DIR"
            removed_count=$((removed_count + 1))
            _info "已删除配置目录: $_SSRUST_CONFIG_DIR"
        else
            _info "已保留配置目录: $_SSRUST_CONFIG_DIR"
        fi
    fi

    if [[ -f "$_SSRUST_LOG_FILE" || -f "$_SSRUST_ERR_FILE" ]]; then
        read -rp "  同时删除日志文件? [y/N]: " remove_logs
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

_ssrust_conf_set_value() {
    local key="$1"
    local val="$2"
    local file="$_SSRUST_CONFIG_FILE"
    [[ -f "$file" ]] || return 1

    local formatted_val
    if [[ "$val" == "true" || "$val" == "false" || "$val" =~ ^[0-9]+$ ]]; then
        formatted_val="$val"
    elif [[ "$val" =~ ^\{ || "$val" =~ ^\[ ]]; then
        formatted_val="$val"
    else
        local escaped_val
        escaped_val=$(echo "$val" | sed 's/\\/\\\\/g; s/"/\\"/g')
        formatted_val="\"$escaped_val\""
    fi

    local tmp_file
    tmp_file=$(_mktemp_file ssrust-config .json) || return 1

    awk -v k="$key" -v v="$formatted_val" '
        {
            if ($0 ~ "\"" k "\"[[:space:]]*:") {
                match($0, /^[[:space:]]*/)
                indent = substr($0, RSTART, RLENGTH)
                has_comma = ($0 ~ /,[[:space:]]*$/)
                lines[++n] = indent "\"" k "\": " v (has_comma ? "," : "")
                found=1
            } else {
                lines[++n] = $0
            }
        }
        END {
            if (found) {
                for (i=1; i<=n; i++) print lines[i]
            } else {
                last_brace_idx = 0
                for (i=n; i>=1; i--) {
                    if (lines[i] ~ /^[[:space:]]*}[[:space:]]*$/) {
                        last_brace_idx = i
                        break
                    }
                }
                if (last_brace_idx > 0) {
                    prev_idx = 0
                    for (j=last_brace_idx-1; j>=1; j--) {
                        if (lines[j] !~ /^[[:space:]]*$/) {
                            prev_idx = j
                            break
                        }
                    }
                    if (prev_idx > 0) {
                        if (lines[prev_idx] !~ /,[[:space:]]*$/ && lines[prev_idx] !~ /{[[:space:]]*$/) {
                            lines[prev_idx] = lines[prev_idx] ","
                        }
                    }
                    for (i=1; i<last_brace_idx; i++) {
                        print lines[i]
                    }
                    print "  \"" k "\": " v
                    for (i=last_brace_idx; i<=n; i++) {
                        print lines[i]
                    }
                } else {
                    for (i=1; i<=n; i++) print lines[i]
                }
            }
        }
    ' "$file" > "$tmp_file"

    cat "$tmp_file" > "$file"
    rm -f "$tmp_file"
}

_ssrust_conf_delete_key() {
    local key="$1"
    local file="$_SSRUST_CONFIG_FILE"
    [[ -f "$file" ]] || return 1

    local tmp_file
    tmp_file=$(_mktemp_file ssrust-config-del .json) || return 1

    awk -v k="$key" '
        $0 ~ "\"" k "\"[[:space:]]*:" {
            next
        }
        { lines[++n] = $0 }
        END {
            for (i=1; i<=n; i++) {
                line = lines[i]
                if (line ~ /^[[:space:]]*}[[:space:]]*$/) {
                    prev_idx = 0
                    for (j=i-1; j>=1; j--) {
                        if (lines[j] !~ /^[[:space:]]*$/) {
                            prev_idx = j
                            break
                        }
                    }
                    if (prev_idx > 0 && lines[prev_idx] ~ /,[[:space:]]*$/) {
                        sub(/,[[:space:]]*$/, "", lines[prev_idx])
                    }
                }
            }
            for (i=1; i<=n; i++) {
                print lines[i]
            }
        }
    ' "$file" > "$tmp_file"

    cat "$tmp_file" > "$file"
    rm -f "$tmp_file"
}

_ssrust_manage_screen() {
    _header "Shadowsocks-Rust 管理"

    local ssrust_ver="未安装"
    local ssrust_status="未运行"
    local ssrust_status_tone="red"
    local ssrust_port="-"
    local ssrust_port_tone="dim"
    local ssrust_method="-"
    local ssrust_method_tone="dim"
    local ssrust_file="不存在"
    local ssrust_file_tone="red"

    if command -v ssserver >/dev/null 2>&1 || [[ -x "$_SSRUST_BIN" ]]; then
        local ver
        ver=$(_ssrust_bin_version)
        ssrust_ver="${ver:-已安装}"
        local pid
        pid=$(_ssrust_running_pid 2>/dev/null || true)
        if _ssrust_service_is_active; then
            if [[ -n "$pid" ]]; then
                ssrust_status="运行中 (PID: $pid)"
            else
                ssrust_status="运行中"
            fi
            ssrust_status_tone="green"
        fi
    fi
    if [[ -f "$_SSRUST_CONFIG_FILE" ]]; then
        ssrust_file="$_SSRUST_CONFIG_FILE"
        ssrust_file_tone="dim"
        local p m
        p=$(_ssrust_conf_get_value "server_port" 2>/dev/null || true)
        m=$(_ssrust_conf_get_value "method" 2>/dev/null || true)
        if [[ -n "$p" ]]; then
            ssrust_port="$p"
            ssrust_port_tone="cyan"
        fi
        if [[ -n "$m" ]]; then
            ssrust_method="$m"
            ssrust_method_tone="cyan"
        fi
    fi

    printf "  ${BOLD}状态信息${PLAIN}\n"
    _separator
    _status_kv_pair "版本" "$ssrust_ver" "dim" 8 "状态" "$ssrust_status" "$ssrust_status_tone" 8
    _status_kv_pair "端口" "$ssrust_port" "$ssrust_port_tone" 8 "方法" "$ssrust_method" "$ssrust_method_tone" 8
    _status_kv_pair "文件" "$ssrust_file" "$ssrust_file_tone" 8 "" "" "" 8

    _separator
    _menu_pair "1" "安装/更新 Shadowsocks-Rust" "安装服务端" "green" "2" "配置并启动 Shadowsocks-Rust" "检查端口" "green"
    _menu_pair "3" "配置自启并启动" "" "green" "4" "重启 Shadowsocks-Rust" "" "green"
    _menu_pair "5" "导出节点配置文件" "输出 SS/Mihomo/Sing-Box 文件" "green" "6" "查看日志" "" "green"
    _menu_pair "7" "DNS 设置" "支持 DoH/DoT/DoQ/UDP" "green" "8" "卸载 Shadowsocks-Rust" "停止并清理" "yellow"
    _menu_item "0" "返回上级菜单" "" "red"
    _separator
}

_ssrust_manage() {
    while true; do
        _ui_print_screen _ssrust_manage_screen

        local ch
        read -rp "  ${CYAN}➜${PLAIN}  选择 [0-8]: " ch
        case "$ch" in
            1) _ssrust_install_or_update ;;
            2) _ssrust_configure ;;
            3) _ssrust_enable ;;
            4) _ssrust_restart ;;
            5) _ssrust_export_node_config ;;
            6) _ssrust_log ;;
            7) _ssrust_dns_manage ;;
            8) _ssrust_uninstall ;;
            0) return ;;
            *) _error_no_exit "无效选项"; sleep 1 ;;
        esac
    done
}

# --- 14. WireGuard 原生节点 ---

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
        read -rp "  客户端配置已存在，覆盖 ${client_conf}? [y/N]: " overwrite
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

    _warn "将停止 WireGuard 节点服务，可删除配置文件。"
    printf "    服务: %s\n" "$service_name"
    printf "    配置: %s\n" "${_WIREGUARD_DIR}/${iface}.conf"
    read -rp "  继续? [y/N]: " confirm
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

    read -rp "  删除 WireGuard 配置目录 ${_WIREGUARD_DIR}? [y/N]: " remove_config
    if [[ "$remove_config" =~ ^[Yy] ]]; then
        rm -rf "$_WIREGUARD_DIR"
        _success "已删除配置目录: ${_WIREGUARD_DIR}"
    else
        _info "已保留配置目录: ${_WIREGUARD_DIR}"
    fi
    _success "WireGuard 节点已停止"
    _press_any_key
}

_wireguard_manage_screen() {
    _header "WireGuard 原生节点"

    local wg_tools="未安装"
    local wg_status="未运行"
    local wg_status_tone="red"
    local wg_iface="-"
    local wg_iface_tone="dim"
    local wg_file="不存在"
    local wg_file_tone="red"
    local wg_port="-"
    local wg_port_tone="dim"

    if command -v wg >/dev/null 2>&1; then
        local ver
        ver=$(wg --version 2>/dev/null | head -1)
        wg_tools="${ver:-已安装}"
    fi

    local iface conf_file listen_port
    iface=$(_wireguard_detect_iface)
    conf_file="${_WIREGUARD_DIR}/${iface}.conf"

    if [[ -n "$iface" ]]; then
        wg_iface="$iface"
        wg_iface_tone="cyan"
        if _wireguard_service_is_active "$iface"; then
            wg_status="运行中"
            wg_status_tone="green"
        fi
    fi

    if [[ -f "$conf_file" ]]; then
        wg_file="$conf_file"
        wg_file_tone="dim"
        listen_port=$(_wireguard_conf_get_value "$iface" "ListenPort" 2>/dev/null || true)
        if [[ -n "$listen_port" ]]; then
            wg_port="$listen_port"
            wg_port_tone="cyan"
        fi
    else
        wg_file="${conf_file} (未部署)"
    fi

    printf "  ${BOLD}状态信息${PLAIN}\n"
    _separator
    _status_kv_pair "工具" "$wg_tools" "dim" 8 "状态" "$wg_status" "$wg_status_tone" 8
    _status_kv_pair "接口" "$wg_iface" "$wg_iface_tone" 8 "端口" "$wg_port" "$wg_port_tone" 8
    _status_kv_pair "文件" "$wg_file" "$wg_file_tone" 8 "" "" "" 8

    _separator
    _menu_pair "1" "安装/更新 WireGuard" "原生内核方案" "green" "2" "部署/重建节点" "含 Mihomo 端口冲突检查" "green"
    _menu_pair "3" "重启 WireGuard" "" "green" "4" "查看状态" "" "green"
    _menu_pair "5" "查看客户端配置" "可显示二维码" "green" "6" "新增客户端" "不重建服务端" "green"
    _menu_pair "7" "卸载 WireGuard 节点" "停止并清理" "yellow" "0" "返回上级菜单" "" "red"
    _separator
}

_wireguard_manage() {
    while true; do
        _ui_print_screen _wireguard_manage_screen

        local ch
        read -rp "  ${CYAN}➜${PLAIN}  选择 [0-7]: " ch
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
            read -rp "  CF_Token: " cf_token
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

_acme_manage_screen() {
    _header "ACME 证书管理"

    local acme_ver="未安装"
    local acme_ver_tone="red"
    if _acme_is_installed; then
        local ver
        ver=$(_acme_cmd --version 2>/dev/null | tail -n 1)
        acme_ver="${ver:-已安装}"
        acme_ver_tone="dim"
    fi

    printf "  ${BOLD}状态信息${PLAIN}\n"
    _separator
    _status_kv_pair "工具" "$acme_ver" "$acme_ver_tone" 8 "" "" "" 8

    _separator
    _menu_pair "1" "安装 acme.sh" "安装/更新工具" "green" "2" "申请证书" "80/DNS 验证" "green"
    _menu_pair "3" "手动更新 acme.sh" "" "green" "4" "自动更新设置" "开启/关闭" "green"
    _menu_item "5" "手动更新证书" "立即续期并覆盖安装" "green"
    _menu_item "0" "返回主菜单" "" "red"
    _separator
}

_acme_manage() {
    while true; do
        _ui_print_screen _acme_manage_screen

        local choice
        read -rp "  ${CYAN}➜${PLAIN}  选择 [0-5]: " choice
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

# --- 15. Akile DNS 解锁检测与配置 ---

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
            apt-get update -qq || true
            apt-get install -y -qq "${packages[@]}"
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
    read -rp "  已在 https://dns.akile.ai 添加本机 IP? [y/N]: " confirm
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
    if ! bash <(curl -fsSL "$(_github_proxy_url "https://raw.githubusercontent.com/akile-network/aktools/refs/heads/main/akdns.sh")"); then
        _error_no_exit "Akile DNS 脚本执行失败"
    fi
    
    _press_any_key
}

# --- 16. Linux DNS 管理 ---

_DNS_SERVERS=()
_DNS_V4_SERVERS=()
_DNS_V6_SERVERS=()
_DNS_RESTART_SERVICES=()
_DNS_CLEAR_EXISTING=1

_DNS64_PRESETS=(
    "Google DNS64|2001:4860:4860::6464"
    "Google DNS64 2|2001:4860:4860::64"
    "Quad9|2620:fe::fe"
    "Quad9 2|2620:fe::9"
)

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

_dns_server_exists() {
    local needle="$1" item
    for item in "${_DNS_SERVERS[@]+"${_DNS_SERVERS[@]}"}"; do
        [ "$item" = "$needle" ] && return 0
    done
    return 1
}

_dns_add_server() {
    local token="$1"
    [ -n "$token" ] || return 1

    token="${token#[}"
    token="${token%]}"
    token="${token%,}"

    if _dns_validate_ipv4 "$token"; then
        if ! _dns_server_exists "$token"; then
            _DNS_SERVERS+=("$token")
            _DNS_V4_SERVERS+=("$token")
        fi
        return 0
    fi

    if _dns_validate_ipv6 "$token"; then
        if ! _dns_server_exists "$token"; then
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

_dns_has_ipv4_default_route() {
    command -v ip >/dev/null 2>&1 || return 1
    ip -4 route show default 2>/dev/null | grep -q '^default[[:space:]]'
}

_dns_has_ipv6_default_route() {
    command -v ip >/dev/null 2>&1 || return 1
    ip -6 route show default 2>/dev/null | grep -q '^default[[:space:]]'
}

_dns_is_ipv6_only_host() {
    _dns_has_ipv6_default_route || return 1
    ! _dns_has_ipv4_default_route
}

_dns_recommended_servers() {
    if _dns_is_ipv6_only_host; then
        printf '%s' "2001:4860:4860::6464,2001:4860:4860::64"
    elif _dns_has_ipv6_default_route; then
        printf '%s' "8.8.8.8,1.1.1.1,2001:4860:4860::8888,2606:4700:4700::1111"
    else
        printf '%s' "8.8.8.8,1.1.1.1"
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
        iface=$(ip -6 route show default 2>/dev/null | awk '/default/ {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    fi
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

_dns_apply_lxc_alpine_overrides() {
    local virt
    virt="$(_detect_virt)"
    if [ "$virt" = "lxc" ]; then
        if [ ! -f /etc/.pve-ignore.resolv.conf ]; then
            touch /etc/.pve-ignore.resolv.conf >/dev/null 2>&1 || true
            _info "已创建 /etc/.pve-ignore.resolv.conf 以防止 Proxmox 覆盖 DNS"
        fi
    fi

    if _is_alpine; then
        mkdir -p /etc/udhcpc
        local udhcpc_conf="/etc/udhcpc/udhcpc.conf"
        local udhcpc_backup="${udhcpc_conf}.vpsgo.bak"
        if [ ! -f "$udhcpc_conf" ]; then
            echo 'RESOLV_CONF="no"' > "$udhcpc_conf"
            _info "已配置 udhcpc (RESOLV_CONF=\"no\")"
        else
            if ! grep -q '^[[:space:]]*RESOLV_CONF=' "$udhcpc_conf"; then
                [ -f "$udhcpc_backup" ] || cp -a "$udhcpc_conf" "$udhcpc_backup" >/dev/null 2>&1 || true
                echo 'RESOLV_CONF="no"' >> "$udhcpc_conf"
                _info "已配置 udhcpc (RESOLV_CONF=\"no\")"
            elif grep -q '^[[:space:]]*RESOLV_CONF=[^"]*yes' "$udhcpc_conf" || grep -q '^[[:space:]]*RESOLV_CONF="yes"' "$udhcpc_conf"; then
                [ -f "$udhcpc_backup" ] || cp -a "$udhcpc_conf" "$udhcpc_backup" >/dev/null 2>&1 || true
                sed -i 's/^[[:space:]]*RESOLV_CONF=.*/RESOLV_CONF="no"/' "$udhcpc_conf"
                _info "已更新 udhcpc 为 RESOLV_CONF=\"no\""
            fi
        fi
    fi
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
    local dns_csv dns_v4_csv dns_v6_csv dhclient_conf dhcpcd_conf backup
    dns_csv=$(IFS=,; echo "${_DNS_SERVERS[*]-}")
    dns_v4_csv=$(IFS=,; echo "${_DNS_V4_SERVERS[*]-}")
    dns_v6_csv=$(IFS=,; echo "${_DNS_V6_SERVERS[*]-}")

    dhclient_conf="/etc/dhcp/dhclient.conf"
    if [ -f "$dhclient_conf" ]; then
        backup="${dhclient_conf}.vpsgo.bak"
        [ -f "$backup" ] || cp -a "$dhclient_conf" "$backup" >/dev/null 2>&1 || true
        sed -i '/^[[:space:]]*supersede[[:space:]]\+domain-name-servers[[:space:]]\+/d' "$dhclient_conf"
        sed -i '/^[[:space:]]*supersede[[:space:]]\+dhcp6\.name-servers[[:space:]]\+/d' "$dhclient_conf"
        [ -n "$dns_v4_csv" ] && printf "supersede domain-name-servers %s;\n" "$dns_v4_csv" >> "$dhclient_conf"
        [ -n "$dns_v6_csv" ] && printf "supersede dhcp6.name-servers %s;\n" "$dns_v6_csv" >> "$dhclient_conf"
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

    _dns_apply_lxc_alpine_overrides

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

    _dns_apply_lxc_alpine_overrides

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
        apt-get update -qq || true
        apt-get install -y -qq dnsutils
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
    _separator
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
    local out server answer qtype

    _dns_ensure_lookup_tool || true
    printf "  ${BOLD}解析验证${PLAIN}\n"
    _info "正在使用系统默认解析器验证 DNS..."

    if command -v dig >/dev/null 2>&1; then
        for qtype in A AAAA; do
            out=$(dig +time=3 +tries=1 "$test_domain" "$qtype" 2>/dev/null || true)
            server=$(echo "$out" | awk -F': ' '/^;; SERVER:/{print $2; exit}')
            answer=$(echo "$out" | awk -v t="$qtype" '$0 !~ /^;/ && $0 ~ "[[:space:]]IN[[:space:]]" t "[[:space:]]" {print $5; exit}')
            if [ -n "$server" ]; then
                _status_kv "dig SERVER" "$server" "cyan" 17
            fi
            if [ -n "$answer" ]; then
                _success "dig ${qtype} 解析成功: ${test_domain} -> ${answer}"
                return 0
            fi
        done
        _warn "dig 未返回 A/AAAA 记录，继续尝试 nslookup..."
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
    local qtype="${3:-A}"
    local out status query_time

    out=$(dig "@${server}" "${domain}" "$qtype" +time=2 +tries=1 2>/dev/null || true)
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
    local qtype="$3"
    shift 3
    local entries=("$@")
    local tmp_file entry name server query_time ecs_flag score
    local ms_show ecs_show

    tmp_file=$(mktemp)

    echo ""
    printf "  ${BOLD}[ %s ]${PLAIN}\n" "$title"
    printf "    测试域名: ${CYAN}%s${PLAIN} (${qtype})\n" "$test_domain"
    _separator
    printf "    %-16s %-39s %-12s %-8s\n" "DNS" "地址" "延迟" "ECS"

    for entry in "${entries[@]}"; do
        name="${entry%%|*}"
        server="${entry#*|}"
        server="${server%%|*}"
        ecs_flag="${entry##*|}"
        query_time=$(_dns_benchmark_query_time "$server" "$test_domain" "$qtype")
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
        printf "    %-16s %-39s %-12s %-8s\n" "$name" "$server" "$ms_show" "$ecs_show"
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
        "Quad9-ECS|9.9.9.11|yes"
        "OpenDNS|208.67.222.222|yes"
        "AdGuard|94.140.14.14|no"
    )

    local ecs_dns=(
        "AliDNS-ECS|223.5.5.5|yes"
        "AliDNS-ECS2|223.6.6.6|yes"
        "DNSPod-ECS|119.29.29.29|yes"
        "ByteDance-ECS|180.184.1.1|yes"
        "ByteDance-ECS2|180.184.2.2|yes"
        "360-ECS|101.226.4.6|yes"
        "360-ECS2|218.30.118.6|yes"
        "Google-ECS|8.8.8.8|yes"
        "Google-ECS2|8.8.4.4|yes"
        "Quad9-ECS|9.9.9.11|yes"
        "OpenDNS-ECS|208.67.222.222|yes"
        "NextDNS-ECS|45.90.28.0|yes"
    )

    local ipv6_dns=(
        "Cloudflare-v6|2606:4700:4700::1111|no"
        "Cloudflare-v6-2|2606:4700:4700::1001|no"
        "Google-v6|2001:4860:4860::8888|yes"
        "Google-v6-2|2001:4860:4860::8844|yes"
        "Quad9-v6|2620:fe::fe|no"
        "Quad9-v6-2|2620:fe::9|no"
        "Quad9-v6-ECS|2620:fe::11|yes"
        "AliDNS-v6|2400:3200::1|yes"
        "AliDNS-v6-2|2400:3200:baba::1|yes"
        "DNSPod-v6-ECS|2402:4e00::|yes"
    )

    local dns64_dns=(
        "Google-DNS64|2001:4860:4860::6464|no"
        "Google-DNS64-2|2001:4860:4860::64|no"
        "Quad9|2620:fe::fe|no"
        "Quad9-2|2620:fe::9|no"
    )

    echo ""
    _info "DNS 测速基于 dig 请求延迟（单位 ms）"
    _dns_is_ipv6_only_host && _info "检测到 IPv6-only 网络，建议优先测试 DNS64 或 IPv6 DNS 组。"
    _warn "结果受线路、运营商缓存、网络波动影响，建议多测几次取平均。"

    _dns_ensure_lookup_tool || true
    if ! command -v dig >/dev/null 2>&1; then
        _error_no_exit "测速依赖 dig，当前环境不可用，请先安装后重试。"
        _press_any_key
        return
    fi

    while true; do
        printf "  ${BOLD}选择测速分组${PLAIN}\n"
        _separator
        _menu_pair "1" "国内 DNS 组" "测试域名: qq.com" "green" "2" "国外 DNS 组" "测试域名: google.com" "green"
        _menu_pair "3" "ECS DNS 组" "常见支持 ECS 的 DNS" "green" "4" "IPv6 DNS 组" "适合 IPv6-only VPS" "green"
        _menu_item "5" "DNS64 测速组" "Google/Quad9 DNS64" "green"
        _menu_item "0" "返回上一层" "" "red"
        _separator

        local group_choice

        read -rp "  选择 [0-5]: " group_choice
        case "$group_choice" in
            1)
                _dns_benchmark_print_group_table "国内 DNS 组测速（ECS 标记）" "qq.com" "A" "${cn_dns[@]}"
                _press_any_key
                return
                ;;
            2)
                _dns_benchmark_print_group_table "国外 DNS 组测速（ECS 标记，含 9.9.9.9）" "google.com" "A" "${global_dns[@]}"
                _press_any_key
                return
                ;;
            3)
                _dns_benchmark_print_group_table "ECS DNS 组测速（qq.com）" "qq.com" "A" "${ecs_dns[@]}"
                _dns_benchmark_print_group_table "ECS DNS 组测速（google.com）" "google.com" "A" "${ecs_dns[@]}"
                _press_any_key
                return
                ;;
            4)
                _dns_benchmark_print_group_table "IPv6 DNS 组测速（AAAA）" "cloudflare.com" "AAAA" "${ipv6_dns[@]}"
                _press_any_key
                return
                ;;
            5)
                _dns_benchmark_print_group_table "DNS64 组测速（合成 AAAA，测 cloudflare.com）" "cloudflare.com" "AAAA" "${dns64_dns[@]}"
                _press_any_key
                return
                ;;
            0) return ;;
            *) _error_no_exit "无效选项: ${group_choice}"; sleep 1 ;;
        esac
    done
}

_dns64_quick_setup_flow() {
    echo ""

    if ! _dns_is_ipv6_only_host; then
        _warn "当前主机不是 IPv6-only 网络环境，DNS64 主要用于纯 IPv6 服务器。"
        read -rp "  是否继续设置 DNS64? [y/N]: " confirm
        echo ""
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            return
        fi
    else
        _info "已检测到 IPv6-only 网络 — DNS64 可合成 AAAA 记录以访问 IPv4 资源。"
    fi

    echo ""
    printf "  ${BOLD}选择 DNS64 服务器${PLAIN}\n"
    _separator
    local i=1 entry name addr
    for entry in "${_DNS64_PRESETS[@]}"; do
        name="${entry%%|*}"
        addr="${entry#*|}"
        _menu_item "$i" "${name}" "${addr}" "green"
        i=$((i + 1))
    done
    _menu_item "0" "返回上一层" "" "red"
    _separator

    local choice selected_servers=""
    read -rp "  选择 DNS64 服务器 (编号，空格分隔多选): " choice

    i=1
    for entry in "${_DNS64_PRESETS[@]}"; do
        if echo " $choice " | grep -qE "[[:space:]]$i[[:space:]]"; then
            addr="${entry#*|}"
            selected_servers="${selected_servers}${selected_servers:+, }${addr}"
        fi
        i=$((i + 1))
    done

    if echo " $choice " | grep -qE "[[:space:]]0[[:space:]]"; then
        return
    fi

    if [ -z "$selected_servers" ]; then
        _error_no_exit "未选择任何 DNS64 服务器。"
        _press_any_key
        return
    fi

    echo ""
    _info "已选择: ${selected_servers}"

    local mode
    echo ""
    printf "  ${BOLD}选择应用模式${PLAIN}\n"
    _separator
    _menu_item "1" "临时修改" "重启后可能失效" "green"
    _menu_item "2" "永久修改" "持久化并重启组件" "green"
    _separator

    read -rp "  选择 [1-2, 默认2]: " mode
    echo ""
    mode="${mode:-2}"

    if ! _dns_parse_servers "$selected_servers"; then
        _press_any_key
        return
    fi

    _DNS_CLEAR_EXISTING=1
    printf "  ${BOLD}应用计划${PLAIN}\n"
    _status_kv "模式" "$([ "$mode" = "1" ] && echo "临时修改" || echo "永久修改")" "cyan" 10
    _status_kv "DNS64" "${_DNS_SERVERS[*]}" "cyan" 10
    printf "\n  ${BOLD}执行过程${PLAIN}\n"

    if [ "$mode" = "1" ]; then
        _dns_apply_temporary || true
    else
        _dns_apply_permanent || true
    fi

    _dns_show_current_config
    printf "\n"
    _dns_verify_resolution || true

    echo ""
    _info "DNS64 已设置。在 IPv6-only 环境下，DNS64 会为纯 IPv4 域名合成 AAAA 记录。"
    _info "使用 NAT64 网关 (如 64:ff9b::/96) 即可访问 IPv4 资源。"
    _press_any_key
}

_dns_change_flow() {
    local mode="$1"
    local dns_input clear_existing dns_default

    echo ""
    read -rp "  清除现有 DNS，仅保留你输入的新 DNS? [Y/n]: " clear_existing
    echo ""
    dns_default="$(_dns_recommended_servers)"
    if _dns_is_ipv6_only_host; then
        _info "检测到 IPv6-only 网络，推荐使用 DNS64 服务器以访问 IPv4 资源。"
    fi
    read -rp "  请输入 DNS（空格/逗号分隔）[默认 ${dns_default}]: " dns_input
    dns_input="${dns_input:-$dns_default}"
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

_dns_manage_screen() {
    _header "Linux DNS 管理"
    _dns_show_current_config

    printf "  ${BOLD}选择操作${PLAIN}\n"
    _separator
    _menu_pair "1" "临时修改 DNS" "重启后可能失效" "green" "2" "永久修改 DNS" "持久化并重启组件" "green"
    _menu_pair "3" "仅验证当前 DNS" "A/AAAA 解析测试" "green" "4" "主流 DNS 测速" "国内/国外/ECS/IPv6" "green"
    _menu_item "5" "DNS64 快速设置" "IPv6-only 合成 AAAA 记录" "green"
    _menu_item "0" "返回主菜单" "" "red"
    _separator
}

_dns_manage() {
    while true; do
        _ui_print_screen _dns_manage_screen

        local choice
        read -rp "  ${CYAN}➜${PLAIN}  选择 [0-5]: " choice
        case "$choice" in
            1) _dns_change_flow "temporary" ;;
            2) _dns_change_flow "permanent" ;;
            3)
                echo ""
                _dns_verify_resolution || true
                _press_any_key
                ;;
            4) _dns_benchmark_mainstream ;;
            5) _dns64_quick_setup_flow ;;
            0) return ;;
            *) _error_no_exit "无效选项: ${choice}"; sleep 1 ;;
        esac
    done
}

# --- 17. Swap 管理 ---

_swap_human_readable() {
    local bytes=$1
    if [ "$bytes" -ge $((1024 * 1024 * 1024)) ]; then
        awk -v b="$bytes" 'BEGIN{ printf "%.1f GiB", b/1024/1024/1024 }'
    else
        awk -v b="$bytes" 'BEGIN{ printf "%.0f MiB", b/1024/1024 }'
    fi
}

_swap_create_flow() {
    # ---- 检测物理内存 ----
    local mem_total_kb mem_total_bytes
    mem_total_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
    mem_total_bytes=$((mem_total_kb * 1024))

    # ---- 检测现有 Swap ----
    local swap_total_kb existing_swap_mib
    swap_total_kb=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo)
    existing_swap_mib=$((swap_total_kb / 1024))

    # ---- 检测硬盘剩余空间 ----
    local disk_avail_kb disk_avail_bytes disk_avail_display
    disk_avail_kb=$(df -k / | awk 'NR==2{print $4}')
    disk_avail_bytes=$((disk_avail_kb * 1024))
    disk_avail_display=$(_swap_human_readable "$disk_avail_bytes")

    # ---- 计算建议 Swap 大小 (MiB) ----
    local mem_mib=$((mem_total_kb / 1024))
    local recommend_mib
    if [ "$mem_mib" -le 1024 ]; then
        recommend_mib=$((mem_mib * 2))
    elif [ "$mem_mib" -le 4096 ]; then
        recommend_mib=$mem_mib
    else
        recommend_mib=4096
    fi

    # 确保建议值不超过磁盘可用空间的 80%
    local disk_limit_mib=$((disk_avail_kb / 1024 * 80 / 100))
    if [ "$recommend_mib" -gt "$disk_limit_mib" ]; then
        recommend_mib=$disk_limit_mib
    fi

    # 扣除已有 swap
    local recommend_new_mib=$((recommend_mib - existing_swap_mib))
    if [ "$recommend_new_mib" -lt 0 ]; then
        recommend_new_mib=0
    fi

    printf "  ${BOLD}[ 建议新建 Swap ]${PLAIN}\n"
    printf "    建议大小: ${GREEN}%s MiB${PLAIN}\n" "$recommend_new_mib"
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
    read -rp "  继续? [y/N]: " confirm
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
    read -rp "  立即重启系统? [y/N]: " reboot_confirm
    if [[ "$reboot_confirm" =~ ^[Yy] ]]; then
        _info "系统将在 3 秒后重启..."
        sleep 3
        reboot
    fi

    _press_any_key
}

_swap_delete_flow() {
    if [ -f /swapfile ]; then
        _warn "确定要删除 /swapfile 并释放空间吗？"
        local confirm
        read -rp "  确定删除? [y/N]: " confirm
        if [[ ! "$confirm" =~ ^[Yy] ]]; then
            _info "已取消"
            _press_any_key
            return
        fi

        _info "正在删除 /swapfile..."
        swapoff /swapfile 2>/dev/null
        rm -f /swapfile
        sed -i '\|/swapfile|d' /etc/fstab
        _info "已删除 /swapfile 并移除 fstab 条目"
        echo ""
        local reboot_confirm
        read -rp "  立即重启系统? [y/N]: " reboot_confirm
        if [[ "$reboot_confirm" =~ ^[Yy] ]]; then
            _info "系统将在 3 秒后重启..."
            sleep 3
            reboot
        fi
    else
        _warn "未找到 /swapfile，可能是由其他盘挂载的 Swap，请手动管理"
    fi
    _press_any_key
}

_swap_set_swappiness() {
    local val="$1"
    _info "正在设置 vm.swappiness 到 ${val}..."
    if ! sysctl -w vm.swappiness="$val" >/dev/null 2>&1; then
        echo "$val" > /proc/sys/vm/swappiness 2>/dev/null || true
    fi

    if [[ "$val" -eq 60 ]]; then
        rm -f /etc/sysctl.d/99-vpsgo-swappiness.conf
        _success "Swappiness 已恢复为默认值并已移除持久化配置"
    else
        mkdir -p /etc/sysctl.d
        cat > /etc/sysctl.d/99-vpsgo-swappiness.conf <<EOF
# VPSGo Optimized Swappiness
# Recommended for proxy servers to avoid swap jitter
vm.swappiness = ${val}
EOF
        _success "Swappiness 已优化为 ${val} 并已持久化写入 /etc/sysctl.d/99-vpsgo-swappiness.conf"
    fi
    _press_any_key
}

_swap_setup() {
    while true; do
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

        # ---- 检测现有 swappiness ----
        local current_swappiness="未知"
        if [ -f /proc/sys/vm/swappiness ]; then
            current_swappiness=$(cat /proc/sys/vm/swappiness 2>/dev/null || sysctl -n vm.swappiness 2>/dev/null || echo "未知")
        fi

        # ---- 展示信息 ----
        echo ""
        printf "  ${BOLD}[ 当前系统状态 ]${PLAIN}\n"
        printf "    物理内存:         ${CYAN}%s${PLAIN}\n" "$mem_total_display"
        printf "    现有 Swap:        ${CYAN}%s${PLAIN}\n" "$swap_total_display"
        printf "    当前 Swappiness:  ${CYAN}%s${PLAIN} %s\n" "$current_swappiness" "$([[ "$current_swappiness" =~ ^[0-9]+$ ]] && ((current_swappiness <= 10)) && echo '(已优化，倾向使用物理内存)' || echo '(默认值，高负载下可能导致代理抖动)')"
        echo ""
        _separator
        _menu_pair "1" "创建/扩展 Swap" "新建或调整 Swap 大小" "green" "2" "删除现有 /swapfile" "完全释放 Swap 空间" "red"
        _menu_pair "3" "优化 Swappiness" "设置 vm.swappiness=1 (推荐代理服务器)" "yellow" "4" "恢复 Swappiness" "重置 vm.swappiness=60 (系统默认)" "cyan"
        _menu_item "0" "返回主菜单" "" "red"
        _separator

        local choice
        read -rp "  选择 [0-4]: " choice
        case "$choice" in
            1) _swap_create_flow ;;
            2) _swap_delete_flow ;;
            3) _swap_set_swappiness 1 ;;
            4) _swap_set_swappiness 60 ;;
            0) return ;;
            *) _error_no_exit "无效选项: ${choice}"; _press_any_key ;;
        esac
    done
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

_ssh_list_config_files() {
    local f
    printf '%s\n' "/etc/ssh/sshd_config"
    for f in /etc/ssh/sshd_config.d/*.conf; do
        [ -f "$f" ] && printf '%s\n' "$f"
    done
}

_ssh_current_ports() {
    local sshd_cfg="/etc/ssh/sshd_config" ports
    if command -v sshd >/dev/null 2>&1 && [ -f "$sshd_cfg" ]; then
        ports=$(sshd -T -f "$sshd_cfg" 2>/dev/null | awk '$1 == "port" { print $2 }' | sort -nu)
        if [ -n "$ports" ]; then
            printf '%s' "$(printf '%s\n' "$ports" | paste -sd ',' -)"
            return
        fi
    fi

    ports=$(
        while IFS= read -r f; do
            [ -f "$f" ] || continue
            sed -nE 's/^[[:space:]]*[Pp][Oo][Rr][Tt][[:space:]]+([0-9]+).*/\1/p' "$f" 2>/dev/null
        done < <(_ssh_list_config_files) | sort -nu
    )
    printf '%s' "${ports:-22}" | paste -sd ',' -
}

_ssh_port_in_current_list() {
    local port="$1" current="${2:-}" item
    local -a ports_arr
    IFS=',' read -r -a ports_arr <<< "$current"
    for item in "${ports_arr[@]}"; do
        [ "$item" = "$port" ] && return 0
    done
    return 1
}

_ssh_port_is_listening() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        # BusyBox ss does not support -H or filter expressions.
        if readlink -f "$(command -v ss)" 2>/dev/null | grep -q busybox \
            || ss --help 2>&1 | head -1 | grep -qi busybox; then
            ss -ltn 2>/dev/null | awk -v p="$port" '
                /^Netid/ || /^State/ || /^Proto/ { next }
                {
                    for (i = 1; i <= NF; i++) {
                        n = split($i, arr, ":")
                        if (n >= 2 && arr[n] == p) { found=1; exit }
                    }
                }
                END { exit !found }
            '
            return $?
        fi
        ss -ltnH "sport = :${port}" 2>/dev/null | grep -q .
        return $?
    fi
    if command -v netstat >/dev/null 2>&1; then
        netstat -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"
        return $?
    fi
    return 1
}


_ssh_backup_file_once() {
    local file="$1" backup
    [ -f "$file" ] || return 0
    backup="${file}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$file" "$backup" || return 1
    _info "已备份 SSH 配置: ${backup}"
}

_ssh_comment_active_port_lines() {
    local file="$1" tmp_file
    [ -f "$file" ] || return 0
    grep -Eiq '^[[:space:]]*Port[[:space:]]+[0-9]+' "$file" || return 0
    tmp_file=$(mktemp /tmp/vpsgo-sshd-port.XXXXXX) || return 1
    awk '
        /^[[:space:]]*[Pp][Oo][Rr][Tt][[:space:]]+[0-9]+/ {
            match($0, /^[[:space:]]*/)
            indent=substr($0, 1, RLENGTH)
            rest=substr($0, RLENGTH + 1)
            sub(/^[Pp][Oo][Rr][Tt][[:space:]]+/, "", rest)
            print indent "# Port " rest "  # disabled by VPSGo port change"
            next
        }
        { print }
    ' "$file" > "$tmp_file" || {
        rm -f "$tmp_file"
        return 1
    }
    cat "$tmp_file" > "$file"
    rm -f "$tmp_file"
}

_ssh_write_managed_port_block() {
    local file="$1" port="$2" tmp_file
    tmp_file=$(mktemp /tmp/vpsgo-sshd.XXXXXX) || return 1
    awk -v port="$port" '
        function print_block() {
            print ""
            print "# VPSGO SSH PORT BEGIN"
            print "Port " port
            print "# VPSGO SSH PORT END"
        }
        /^# VPSGO SSH PORT BEGIN$/ { skip=1; next }
        /^# VPSGO SSH PORT END$/ { skip=0; next }
        skip { next }
        /^[[:space:]]*Match[[:space:]]/ && !inserted {
            print_block()
            inserted=1
        }
        { print }
        END {
            if (!inserted) {
                print_block()
            }
        }
    ' "$file" > "$tmp_file" || {
        rm -f "$tmp_file"
        return 1
    }
    cat "$tmp_file" > "$file"
    rm -f "$tmp_file"
}

_ssh_change_port() {
    _header "快速修改 SSH 端口"

    local sshd_cfg="/etc/ssh/sshd_config"
    if [ ! -f "$sshd_cfg" ]; then
        _error_no_exit "未找到 ${sshd_cfg}"
        _press_any_key
        return
    fi

    local current_ports new_port confirm f
    current_ports=$(_ssh_current_ports)
    _info "当前 SSH 端口: ${current_ports:-22}"
    if command -v sshd >/dev/null 2>&1; then
        mkdir -p /run/sshd 2>/dev/null || true
        if ! sshd -t -f "$sshd_cfg" >/dev/null 2>&1; then
            _error_no_exit "当前 sshd 配置校验失败，未修改端口"
            _press_any_key
            return
        fi
    fi

    read -rp "  新 SSH 端口 [1-65535]: " new_port
    if ! _is_valid_port "${new_port:-}"; then
        _error_no_exit "端口无效: ${new_port:-空}"
        _press_any_key
        return
    fi

    if _ssh_port_is_listening "$new_port" && ! _ssh_port_in_current_list "$new_port" "$current_ports"; then
        _error_no_exit "端口 ${new_port} 已被占用，请换一个端口"
        _press_any_key
        return
    fi

    _warn "将把 SSH 监听端口改为 ${new_port}，请确认防火墙/安全组已放行该端口。"
    read -rp "  继续? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        _info "已取消"
        _press_any_key
        return
    fi

    while IFS= read -r f; do
        [ -f "$f" ] || continue
        if [ "$f" = "$sshd_cfg" ] || grep -Eiq '^[[:space:]]*Port[[:space:]]+[0-9]+' "$f"; then
            _ssh_backup_file_once "$f" || {
                _error_no_exit "备份失败: ${f}"
                _press_any_key
                return
            }
        fi
        _ssh_comment_active_port_lines "$f"
    done < <(_ssh_list_config_files)

    if ! _ssh_write_managed_port_block "$sshd_cfg" "$new_port"; then
        _error_no_exit "写入 SSH 端口配置失败"
        _press_any_key
        return
    fi

    if command -v sshd >/dev/null 2>&1; then
        mkdir -p /run/sshd 2>/dev/null || true
        if ! sshd -t -f "$sshd_cfg" >/dev/null 2>&1; then
            _error_no_exit "sshd 配置校验失败，请根据备份文件恢复后重试"
            _press_any_key
            return
        fi
    else
        _warn "未找到 sshd 命令，已跳过配置语法校验"
    fi

    if ! _restart_first_available_service ssh sshd; then
        _warn "未检测到可重启的 ssh/sshd 服务，请手动重启 SSH 服务"
    fi

    echo ""
    _success "SSH 端口已修改为 ${new_port}"
    _warn "请先用新终端测试: ssh -p ${new_port} <user>@<server>，确认成功后再关闭当前会话"
    _press_any_key
}

_rootssh_enable() {
    _header "启用 Root SSH 登录"
    _warn "将设置 root 密码，允许 root SSH 登录。"

    local confirm
    read -rp "  继续? [Y/n]: " confirm
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
    _warn "将禁用 SSH 密码登录，仅允许密钥登录。"

    local confirm
    read -rp "  继续? [Y/n]: " confirm
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

# --- 1Panel iptables 代理链 ---

_onepanel_iptables_chain_exists() {
    local chain="$1"
    iptables -w 5 -t nat -n -L "$chain" >/dev/null 2>&1
}

_onepanel_iptables_jump_exists() {
    local chain="$1" target="$2"
    iptables -w 5 -t nat -C "$chain" -j "$target" >/dev/null 2>&1
}

_onepanel_iptables_ref_text() {
    local chain="$1" first_line
    first_line=$(iptables -w 5 -t nat -n -L "$chain" 2>/dev/null | sed -n '1p')
    if [ -z "$first_line" ]; then
        printf '%s' "未检测到"
        return
    fi
    printf '%s' "$first_line" | awk -F'[()]' '{print $2}'
}

_onepanel_save_iptables_if_possible() {
    if ! command -v iptables-save >/dev/null 2>&1; then
        _warn "未检测到 iptables-save，已跳过持久化保存。"
        return 1
    fi

    if command -v netfilter-persistent >/dev/null 2>&1; then
        if netfilter-persistent save >/dev/null 2>&1; then
            _success "已通过 netfilter-persistent 保存规则。"
            return 0
        fi
        _warn "netfilter-persistent save 执行失败，尝试写入 /etc/iptables/rules.v4。"
    fi

    if [ -d /etc/iptables ]; then
        if iptables-save > /etc/iptables/rules.v4; then
            chmod 0644 /etc/iptables/rules.v4 2>/dev/null || true
            _success "已保存到 /etc/iptables/rules.v4。"
            return 0
        fi
        _warn "写入 /etc/iptables/rules.v4 失败。"
        return 1
    fi

    _warn "未检测到 /etc/iptables 目录，当前规则已运行时生效但重启后可能丢失。"
    _info "Debian/Ubuntu 可执行: apt install iptables-persistent -y && netfilter-persistent save"
    return 1
}

_onepanel_apply_iptables_chains() {
    _header "1Panel iptables 代理链"

    _info "把 1Panel NAT 子链接入系统 NAT 主链。"
    _info "会检查并补齐以下跳转规则:"
    printf "    iptables -t nat -I PREROUTING 1 -j 1PANEL_PREROUTING\n"
    printf "    iptables -t nat -I POSTROUTING 1 -j 1PANEL_POSTROUTING\n"
    echo ""

    if ! command -v iptables >/dev/null 2>&1; then
        _error_no_exit "未检测到 iptables，无法应用 1Panel 代理链。"
        _press_any_key
        return
    fi

    local missing=0
    if ! _onepanel_iptables_chain_exists "1PANEL_PREROUTING"; then
        _error_no_exit "未检测到 nat/1PANEL_PREROUTING，请先在 1Panel 创建端口转发规则。"
        missing=1
    fi
    if ! _onepanel_iptables_chain_exists "1PANEL_POSTROUTING"; then
        _error_no_exit "未检测到 nat/1PANEL_POSTROUTING，请先在 1Panel 创建端口转发规则。"
        missing=1
    fi
    if [ "$missing" -eq 1 ]; then
        _press_any_key
        return
    fi

    printf "  ${BOLD}应用前状态${PLAIN}\n"
    _separator
    _status_kv "PREROUTING" "$(_onepanel_iptables_ref_text 1PANEL_PREROUTING)" "cyan" 14
    _status_kv "POSTROUTING" "$(_onepanel_iptables_ref_text 1PANEL_POSTROUTING)" "cyan" 14

    echo ""
    if _onepanel_iptables_jump_exists "PREROUTING" "1PANEL_PREROUTING"; then
        _info "PREROUTING 已挂载 1PANEL_PREROUTING，跳过重复插入。"
    else
        if iptables -w 5 -t nat -I PREROUTING 1 -j 1PANEL_PREROUTING; then
            _success "已挂载: PREROUTING -> 1PANEL_PREROUTING"
        else
            _error_no_exit "挂载 PREROUTING -> 1PANEL_PREROUTING 失败。"
            _press_any_key
            return
        fi
    fi

    if _onepanel_iptables_jump_exists "POSTROUTING" "1PANEL_POSTROUTING"; then
        _info "POSTROUTING 已挂载 1PANEL_POSTROUTING，跳过重复插入。"
    else
        if iptables -w 5 -t nat -I POSTROUTING 1 -j 1PANEL_POSTROUTING; then
            _success "已挂载: POSTROUTING -> 1PANEL_POSTROUTING"
        else
            _error_no_exit "挂载 POSTROUTING -> 1PANEL_POSTROUTING 失败。"
            _press_any_key
            return
        fi
    fi

    echo ""
    printf "  ${BOLD}应用后状态${PLAIN}\n"
    _separator
    _status_kv "PREROUTING" "$(_onepanel_iptables_ref_text 1PANEL_PREROUTING)" "green" 14
    _status_kv "POSTROUTING" "$(_onepanel_iptables_ref_text 1PANEL_POSTROUTING)" "green" 14

    echo ""
    local save_choice
    read -rp "  保存规则以便重启后生效? [Y/n]: " save_choice
    if [[ "$save_choice" =~ ^[Nn]$ ]]; then
        _warn "已跳过保存；重启服务器或重启防火墙后规则可能丢失。"
    else
        _onepanel_save_iptables_if_possible || true
    fi

    echo ""
    _success "1Panel iptables 代理链已应用"
    _info "检查命令: iptables -t nat -L -n -v"
    _press_any_key
}

# --- 自更新 ---

_self_update() {
    _header "VPSGo 更新"

    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        _error_no_exit "需要 curl 或 wget 命令"
        _press_any_key
        return
    fi

    _info "当前版本: v${VERSION}"
    _info "正在检查更新..."

    local tmp_file remote_ver current_file backup_file need_update="1"
    tmp_file=$(_mktemp_file vpsgo .sh) || {
        _error_no_exit "创建临时文件失败"
        _press_any_key
        return
    }
    if ! _download_file "$UPDATE_URL" "$tmp_file"; then
        rm -f "$tmp_file"
        _error_no_exit "下载失败，请检查网络连接，或在首页按 g 开启 GitHub 代理"
        _press_any_key
        return
    fi

    if [[ ! -s "$tmp_file" ]]; then
        rm -f "$tmp_file"
        _error_no_exit "下载文件为空"
        _press_any_key
        return
    fi

    if ! _script_file_looks_like_vpsgo "$tmp_file"; then
        rm -f "$tmp_file"
        _error_no_exit "下载内容不像 VPSGo 脚本，已取消更新"
        _press_any_key
        return
    fi

    if ! bash -n "$tmp_file" >/dev/null 2>&1; then
        rm -f "$tmp_file"
        _error_no_exit "下载到的脚本语法校验失败，已取消更新"
        _press_any_key
        return
    fi

    if [[ -d "$INSTALL_PATH" ]]; then
        rm -f "$tmp_file"
        _error_no_exit "${INSTALL_PATH} 是目录，无法写入可执行文件"
        _press_any_key
        return
    fi

    remote_ver=$(grep '^VERSION=' "$tmp_file" | head -1 | sed 's/VERSION=//;s/[\"'"'"']//g')

    if [[ -z "$remote_ver" ]]; then
        _error_no_exit "无法解析远程版本号"
        rm -f "$tmp_file"
        _press_any_key
        return
    else
        _info "最新版本: v${remote_ver}"
    fi
    if [[ "$remote_ver" != "$VERSION" ]] && _version_ge "$VERSION" "$remote_ver" && ! _version_ge "$remote_ver" "$VERSION"; then
        if ! _is_truthy "${VPSGO_ALLOW_DOWNGRADE:-0}"; then
            _warn "远程版本 v${remote_ver} 低于当前版本 v${VERSION}，已取消更新"
            _info "如确需降级，可设置 VPSGO_ALLOW_DOWNGRADE=1 后重试"
            rm -f "$tmp_file"
            _press_any_key
            return
        fi
        _warn "即将按 VPSGO_ALLOW_DOWNGRADE=1 降级到 v${remote_ver}"
    fi

    current_file="$INSTALL_PATH"
    if [[ ! -f "$current_file" ]]; then
        current_file="$(readlink -f "$0" 2>/dev/null || echo "$0")"
    fi
    if [[ "$remote_ver" == "$VERSION" && -f "$current_file" ]] && cmp -s "$tmp_file" "$current_file"; then
        need_update="0"
    fi
    if [[ "$need_update" == "0" ]]; then
        _info "已是最新版本，无需更新"
        rm -f "$tmp_file"
        _press_any_key
        return
    fi
    if [[ "$remote_ver" == "$VERSION" ]]; then
        _warn "远程版本号相同，但脚本内容不同，将重新覆盖安装以修复本地脚本"
    fi

    backup_file=""
    if [[ -f "$INSTALL_PATH" ]]; then
        backup_file=$(_mktemp_file vpsgo-backup .sh) || {
            rm -f "$tmp_file"
            _error_no_exit "创建备份文件失败"
            _press_any_key
            return
        }
        if ! cp -p "$INSTALL_PATH" "$backup_file"; then
            rm -f "$tmp_file" "$backup_file"
            _error_no_exit "备份当前脚本失败，已取消更新"
            _press_any_key
            return
        fi
    fi

    if ! _install_script_file "$tmp_file" "$INSTALL_PATH"; then
        [[ -n "$backup_file" ]] && cp -p "$backup_file" "$INSTALL_PATH" 2>/dev/null || true
        rm -f "$tmp_file"
        _error_no_exit "更新失败，无法写入 ${INSTALL_PATH}"
        _warn "请检查目录权限或挂载参数（如 noexec），或改用 VPSGO_INSTALL_PATH 指定其他路径"
        _press_any_key
        return
    fi

    if ! _ensure_script_mode_ok "$INSTALL_PATH"; then
        [[ -n "$backup_file" ]] && cp -p "$backup_file" "$INSTALL_PATH" 2>/dev/null || true
        rm -f "$tmp_file"
        _error_no_exit "更新失败，${INSTALL_PATH} 权限异常"
        _warn "请手动执行: chmod 0755 ${INSTALL_PATH}"
        _press_any_key
        return
    fi

    if ! bash -n "$INSTALL_PATH" >/dev/null 2>&1; then
        [[ -n "$backup_file" ]] && cp -p "$backup_file" "$INSTALL_PATH" 2>/dev/null || true
        rm -f "$tmp_file" "$backup_file"
        _error_no_exit "安装后的脚本语法校验失败，已尝试恢复旧版本"
        _press_any_key
        return
    fi

    rm -f "$tmp_file" "$backup_file"

    _info "更新完成! v${VERSION} -> v${remote_ver}"
    _info "正在重新启动..."
    echo ""
    exec "$INSTALL_PATH" "$@"
}

# --- 自安装 ---

_self_install() {
    local self tmp_self=""
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

    # 检查源文件是否为当前脚本；管道运行时 $0 可能是 bash 或不可读路径。
    if ! _script_file_looks_like_vpsgo "$self"; then
        if command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; then
            tmp_self=$(_mktemp_file vpsgo-install .sh) || return
            if _download_file "$UPDATE_URL" "$tmp_self" && _script_file_looks_like_vpsgo "$tmp_self" && bash -n "$tmp_self" >/dev/null 2>&1; then
                self="$tmp_self"
            else
                rm -f "$tmp_self"
                return
            fi
        else
            return
        fi
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

    [[ -n "$tmp_self" ]] && rm -f "$tmp_self"
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
    line_w=$((cols - 4))
    [ "$line_w" -lt 24 ] && line_w=24
    [ "$line_w" -gt 76 ] && line_w=76
    line=$(_ui_repeat_char "═" "$line_w")

    _ui_clear_screen
    printf "  ${CYAN}%s${PLAIN}\n" "$line"
    printf "  ${CYAN}"
    cat << 'BANNER'
  __     __  ____    ____     ____    ___  
  \ \   / / |  _ \  / ___|   / ___|  / _ \ 
   \ \ / /  | |_) | \___ \  | |  _  | | | |
    \ V /   |  __/   ___) | | |_| | | |_| |
     \_/    |_|     |____/   \____|  \___/ 
BANNER
    printf "${PLAIN}"
    printf "    ${DIM}   VPS 一站式管理脚本${PLAIN} ${BOLD}v%s${PLAIN}\n" "$VERSION"
    printf "  ${CYAN}%s${PLAIN}\n" "$line"
}

_show_main_menu() {
    _show_sys_info
    printf "  ${BOLD}功能分类${PLAIN}\n"
    _separator
    _menu_pair "1" "网络优化" "内核/路由/WARP" "green" "2" "脚本工具" "测速/DNS/路由" "green"
    _menu_pair "3" "系统相关" "日志/Swap/SSH/NAT" "green" "4" "代理工具" "服务端/证书" "green"
    _separator
    _menu_pair "g" "GitHub 代理" "$(_github_proxy_status_desc)" "cyan" "u" "更新 VPSGo" "拉取最新版" "cyan"
    _menu_pair "x" "卸载 VPSGo" "" "red" "0" "退出脚本" "" "red"
    _separator
}

_show_home_screen() {
    _show_banner
    _show_main_menu
}

# --- LXC Container & HE Tunnel Module ---

_ensure_lxcbr0() {
    # 确保 lxcbr0 网桥存在且 UP
    if ip link show lxcbr0 >/dev/null 2>&1; then
        ip link set lxcbr0 up 2>/dev/null || true
        return 0
    fi

    _info "检测到 lxcbr0 网桥不存在，正在尝试通过 lxc-net 服务创建..."
    systemctl unmask lxc-net 2>/dev/null || true
    systemctl enable --now lxc-net 2>/dev/null || true
    systemctl restart lxc-net 2>/dev/null || true
    for i in $(seq 1 10); do
        if ip link show lxcbr0 >/dev/null 2>&1; then
            ip link set lxcbr0 up 2>/dev/null || true
            return 0
        fi
        sleep 1
    done

    # lxc-net 可能不可用，手动创建网桥作为兜底
    _warn "lxc-net 服务未能创建 lxcbr0，尝试手动创建网桥..."
    ip link add name lxcbr0 type bridge 2>/dev/null || true
    ip addr add 10.0.3.1/24 dev lxcbr0 2>/dev/null || true
    ip link set lxcbr0 up 2>/dev/null || true

    if ip link show lxcbr0 >/dev/null 2>&1; then
        _success "已手动创建 lxcbr0 网桥 (10.0.3.1/24)"
        # 确保 NAT 规则存在以便容器访问外网
        iptables -t nat -C POSTROUTING -s 10.0.3.0/24 ! -d 10.0.3.0/24 -j MASQUERADE 2>/dev/null || \
            iptables -t nat -A POSTROUTING -s 10.0.3.0/24 ! -d 10.0.3.0/24 -j MASQUERADE 2>/dev/null || true
        iptables -C FORWARD -i lxcbr0 -j ACCEPT 2>/dev/null || \
            iptables -A FORWARD -i lxcbr0 -j ACCEPT 2>/dev/null || true
        iptables -C FORWARD -o lxcbr0 -j ACCEPT 2>/dev/null || \
            iptables -A FORWARD -o lxcbr0 -j ACCEPT 2>/dev/null || true
        return 0
    fi

    _error_no_exit "lxcbr0 网桥无法创建，请手动排查网络配置。"
    return 1
}

_update_lxc_net_config() {
    local key="$1"
    local val="$2"
    local file="/etc/default/lxc-net"
    if [ ! -f "$file" ]; then
        return
    fi
    if grep -q -E "^#?\s*${key}=" "$file"; then
        sed -i -E "s|^#?\s*${key}=.*|${key}=\"${val}\"|" "$file"
    else
        echo "${key}=\"${val}\"" >> "$file"
    fi
}

_reset_lxc_net_ipv6_config() {
    _update_lxc_net_config "LXC_IPV6_ADDR" ""
    _update_lxc_net_config "LXC_IPV6_MASK" ""
    _update_lxc_net_config "LXC_IPV6_NETWORK" ""
    _update_lxc_net_config "LXC_IPV6_NAT" "false"
}

_he_ipv6_lxc_menu_screen() {
    _header "LXC 容器(支持HE隧道)"

    # --- 状态概览 ---
    local tunnel_line="不存在"
    local tunnel_tone="yellow"
    if ip link show he-ipv6 >/dev/null 2>&1; then
        local tstate
        tstate=$(ip link show he-ipv6 | grep -oE "state [A-Z]+" | awk '{print $2}' || echo "UP")
        local taddr
        taddr=$(ip -6 addr show dev he-ipv6 2>/dev/null | grep -oE "inet6 [^ ]+" | head -1 | awk '{print $2}' || true)
        tunnel_line="${tstate}${taddr:+  ${taddr}}"
        tunnel_tone="green"
    fi
    _status_kv "HE 隧道" "$tunnel_line" "$tunnel_tone" "8"

    # 列出所有 lxc 容器（最多 3 个）
    local lxc_list=()
    if command -v lxc-ls >/dev/null 2>&1; then
        while IFS= read -r cname; do
            cname=$(echo "$cname" | xargs)
            [[ -z "$cname" ]] && continue
            lxc_list+=("$cname")
        done < <(lxc-ls -1 2>/dev/null || lxc-ls 2>/dev/null | tr ' ' '\n' || true)
    fi

    if [ "${#lxc_list[@]}" -eq 0 ]; then
        _status_kv "LXC 容器" "无已创建容器" "dim" "8"
    else
        local shown=0
        for cname in "${lxc_list[@]}"; do
            [ "$shown" -ge 3 ] && break
            local cstate
            cstate=$(lxc-info -n "$cname" -s 2>/dev/null | awk '{print $2}' || echo "UNKNOWN")
            local ctone="yellow"
            [[ "$cstate" == "RUNNING" ]] && ctone="green"
            [[ "$cstate" == "STOPPED" ]] && ctone="dim"
            local cip
            cip=$(lxc-info -n "$cname" -i 2>/dev/null | awk '{print $2}' | head -1 || true)
            _status_kv "$cname" "${cstate}${cip:+  ${cip}}" "$ctone" "16"
            shown=$((shown + 1))
        done
        [ "${#lxc_list[@]}" -gt 3 ] && _info "  ... 共 ${#lxc_list[@]} 个容器"
    fi

    _separator
    _menu_pair "1" "创建/配置容器" "创建 Debian 容器(可选 HE 隧道)" "green" "2" "修改 HE 隧道配置" "重新设置 HE 参数并重启隧道" "green"
    _menu_pair "3" "端口转发管理" "映射宿主机端口到容器" "green" "4" "可用性与状态检查" "诊断宿主机与容器的网络" "green"
    _menu_pair "5" "启动/停止容器" "控制 LXC 容器开关" "green" "6" "进入容器终端" "快速连入运行中容器的 Shell" "green"
    _menu_item "7" "卸载与清理" "删除容器与 HE 隧道配置" "red"
    _separator
    _menu_item "0" "返回上级菜单" "" "red"
    _separator
}

_he_ipv6_lxc_menu() {
    while true; do
        _ui_print_screen _he_ipv6_lxc_menu_screen
        local ch
        read -rp "  ${CYAN}➜${PLAIN}  选择 [0-7]: " ch
        case "$ch" in
            1) _he_ipv6_lxc_install ;;
            2) _he_tunnel_edit ;;
            3) _lxc_port_forward_menu ;;
            4) _he_ipv6_lxc_status_check ;;
            5) _he_ipv6_lxc_power_control ;;
            6) _lxc_attach ;;
            7) _he_ipv6_lxc_uninstall ;;
            0) return ;;
            *) _error_no_exit "无效选项: ${ch}"; sleep 1 ;;
        esac
    done
}

# 从持久化配置中读取当前隧道参数
_he_tunnel_read_current() {
    local cfg="/etc/network/interfaces.d/he-ipv6"
    if [ ! -f "$cfg" ]; then
        return 1
    fi
    _HE_CUR_CLIENT_IPV6=$(awk '/^\s*address /{print $2}' "$cfg" | head -1)
    _HE_CUR_SERVER_IPV4=$(awk '/^\s*endpoint /{print $2}' "$cfg" | head -1)
    _HE_CUR_LOCAL_IPV4=$(awk '/^\s*local /{print $2}' "$cfg" | head -1)
    _HE_CUR_SERVER_IPV6=$(awk '/^\s*gateway /{print $2}' "$cfg" | head -1)
    return 0
}

_he_tunnel_edit() {
    _header "修改 HE 隧道配置"

    if [ ! -f /etc/network/interfaces.d/he-ipv6 ]; then
        _warn "未检测到已持久化的 HE 隧道配置文件 (/etc/network/interfaces.d/he-ipv6)。"
        _info "请先通过「创建/配置容器」建立 HE 隧道。"
        _press_any_key
        return
    fi

    local _HE_CUR_CLIENT_IPV6="" _HE_CUR_SERVER_IPV4="" _HE_CUR_LOCAL_IPV4="" _HE_CUR_SERVER_IPV6=""
    _he_tunnel_read_current

    _info "当前 HE 隧道参数："
    _status_kv "Server IPv4  " "${_HE_CUR_SERVER_IPV4:-未知}" "cyan" "14"
    _status_kv "Client IPv6  " "${_HE_CUR_CLIENT_IPV6:-未知}" "cyan" "14"
    _status_kv "Server IPv6  " "${_HE_CUR_SERVER_IPV6:-未知}" "cyan" "14"
    _status_kv "Local IPv4   " "${_HE_CUR_LOCAL_IPV4:-未知}" "cyan" "14"
    echo ""

    # 逐项重新输入（回车保留原值）
    local new_server_ipv4 new_client_ipv6 new_server_ipv6 new_local_ipv4 new_routed_ipv6

    read -rp "  HE Server IPv4 [${_HE_CUR_SERVER_IPV4}]: " new_server_ipv4
    new_server_ipv4="${new_server_ipv4:-$_HE_CUR_SERVER_IPV4}"
    # Server IPv4: 去掉可能的 /32
    new_server_ipv4="${new_server_ipv4%%/*}"

    read -rp "  HE Client IPv6 Address [${_HE_CUR_CLIENT_IPV6}] (可带 /64): " new_client_ipv6
    new_client_ipv6="${new_client_ipv6:-$_HE_CUR_CLIENT_IPV6}"
    # Client IPv6: interfaces 里 address 行单独写 netmask，只取纯地址
    new_client_ipv6="${new_client_ipv6%%/*}"

    read -rp "  HE Server IPv6 Address [${_HE_CUR_SERVER_IPV6}] (可带 /64): " new_server_ipv6
    new_server_ipv6="${new_server_ipv6:-$_HE_CUR_SERVER_IPV6}"
    # Server IPv6: gateway 只需纯地址
    new_server_ipv6="${new_server_ipv6%%/*}"

    local default_local_ipv4
    default_local_ipv4=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+' || echo "$_HE_CUR_LOCAL_IPV4")
    read -rp "  宿主机本地 IPv4 [${_HE_CUR_LOCAL_IPV4:-$default_local_ipv4}]: " new_local_ipv4
    new_local_ipv4="${new_local_ipv4:-${_HE_CUR_LOCAL_IPV4:-$default_local_ipv4}}"
    # Local IPv4: 去掉可能的 /32
    new_local_ipv4="${new_local_ipv4%%/*}"

    read -rp "  HE Routed IPv6 Prefix (例如: 2001:470:1f11:xx::/64) [回车跳过]: " new_routed_ipv6
    # Routed Prefix: 去除多余空格，保留 /64 供后续前缀提取
    new_routed_ipv6=$(echo "$new_routed_ipv6" | sed 's/[[:space:]]//g')

    local share_with_host="y"
    if grep -q "table 100" /etc/network/interfaces.d/he-ipv6 2>/dev/null; then
        share_with_host="n"
    fi
    local input_share
    read -rp "  是否允许宿主机也使用此 IPv6 隧道访问外网? [y/N] (当前: $([[ "$share_with_host" == "y" ]] && echo "是" || echo "否")): " input_share
    if [[ -n "$input_share" ]]; then
        if [[ "$input_share" =~ ^[Yy] ]]; then
            share_with_host="y"
        else
            share_with_host="n"
        fi
    fi

    _info "正在停止旧 HE 隧道接口..."
    # 自动检测并清理可能残留的 physXXXX 重命名物理接口
    local phys_dev
    for phys_dev in $(ip -o link show | awk -F': ' '{print $2}' | grep -oE '^phys[a-zA-Z0-9]+' || true); do
        _info "检测到上次运行残留的网卡接口 ${phys_dev}，正在清理..."
        ip link set "${phys_dev}" down 2>/dev/null || true
        ip tunnel del "${phys_dev}" 2>/dev/null || true
        ip link delete "${phys_dev}" 2>/dev/null || true
    done

    ip link set he-ipv6 down 2>/dev/null || true
    ip tunnel del he-ipv6 2>/dev/null || true

    _info "正在写入新 HE 隧道配置..."
    if [ ! -d /etc/network/interfaces.d ]; then
        mkdir -p /etc/network/interfaces.d
    fi

    local active_routed_ipv6="${new_routed_ipv6}"
    if [[ -z "$active_routed_ipv6" && -f /etc/default/lxc-net ]]; then
        active_routed_ipv6=$(grep -oE 'LXC_IPV6_NETWORK="[^"]+"' /etc/default/lxc-net | cut -d'"' -f2 || true)
    fi
    active_routed_ipv6="${active_routed_ipv6:-2001:db8:1::/64}"

    if [[ "$share_with_host" == "y" ]]; then
        cat > /etc/network/interfaces.d/he-ipv6 <<EOF
auto he-ipv6
iface he-ipv6 inet6 v4tunnel
    address ${new_client_ipv6}
    netmask 64
    endpoint ${new_server_ipv4}
    local ${new_local_ipv4}
    ttl 255
    post-up ip -6 route add default via ${new_server_ipv6} dev he-ipv6 table 100 2>/dev/null || true
    post-up ip -6 rule add from ${active_routed_ipv6} lookup 100 2>/dev/null || true
    pre-down ip -6 rule del from ${active_routed_ipv6} lookup 100 2>/dev/null || true
    pre-down ip -6 route del default via ${new_server_ipv6} dev he-ipv6 table 100 2>/dev/null || true
EOF
    else
        cat > /etc/network/interfaces.d/he-ipv6 <<EOF
auto he-ipv6
iface he-ipv6 inet6 v4tunnel
    address ${new_client_ipv6}
    netmask 64
    endpoint ${new_server_ipv4}
    local ${new_local_ipv4}
    ttl 255
EOF
    fi

    _info "正在重新启动 HE 隧道..."
    if ! ifup he-ipv6 2>/dev/null; then
        modprobe sit >/dev/null 2>&1 || true
        local err_msg
        if ! err_msg=$(ip tunnel add he-ipv6 mode sit remote "${new_server_ipv4}" local "${new_local_ipv4}" ttl 255 2>&1); then
            _error_no_exit "创建 sit 隧道失败: ${err_msg}"
            _error_no_exit "请检查本地 IPv4 (${new_local_ipv4}) 是否是网卡上绑定的真实 IP (如果是 NAT 机，必须填内网 IP)。"
            _press_any_key
            return 1
        fi
        if ! err_msg=$(ip link set he-ipv6 up 2>&1); then
            _error_no_exit "启用 he-ipv6 接口失败: ${err_msg}"
            _press_any_key
            return 1
        fi
        if ! err_msg=$(ip addr add "${new_client_ipv6}" dev he-ipv6 2>&1); then
            _error_no_exit "为 he-ipv6 绑定 Client IPv6 失败: ${err_msg}"
            _press_any_key
            return 1
        fi
        if [[ "$share_with_host" == "y" ]]; then
            ip -6 route add default via "${new_server_ipv6}" dev he-ipv6 table 100 2>/dev/null || true
            ip -6 rule add from "${active_routed_ipv6}" lookup 100 2>/dev/null || true
        fi
    fi
    _success "HE 隧道接口已重新应用"

    # 如果有 Routed IPv6 Prefix，更新容器内 interfaces（仅提示，不自动修改）
    if [[ -n "$new_routed_ipv6" ]]; then
        # 提取前缀 base：先去掉 /64，再根据是否含 :: 分支处理
        local prefix_base
        local _routed_addr="${new_routed_ipv6%%/*}"  # 去掉 /64 等前缀长度
        if [[ "$_routed_addr" == *::* ]]; then
            prefix_base="${_routed_addr%%::*}"  # 取 :: 之前的网络前缀部分
        else
            prefix_base="${_routed_addr%:*}"    # 展开格式：去掉最后一个主机段
        fi
        local container_routed_ip="${prefix_base}::2"
        _info "Routed IPv6 已提供，容器内 Routed IP 应为: ${container_routed_ip}/64"
        _warn "注意：容器内 /etc/network/interfaces 需要手动或重建容器才能同步更新。"
        _warn "可通过 lxc-attach -n <容器名> 进入容器后自行修改。"
    fi

    _info "正在测试 HE 隧道连通性..."
    if ping6 -c 3 -W 3 "${new_server_ipv6}" >/dev/null 2>&1; then
        _success "HE 隧道连通性测试成功！Server IPv6 可达。"
    else
        _warn "无法 ping6 通 HE 网关 ${new_server_ipv6}，请检查 Server IPv4 端点与协议号 41 放行状态。"
    fi

    _press_any_key
}

_he_ipv6_lxc_install() {
    _header "创建 LXC 容器与 HE 隧道"
    
    local os
    os="$(_os)"
    if [[ "$os" != "debian" && "$os" != "ubuntu" ]]; then
        _error_no_exit "错误：此功能目前仅支持 Debian 或 Ubuntu 宿主机系统。"
        _press_any_key
        return 1
    fi
    
    _info "正在检查并安装 LXC 相关依赖..."
    modprobe tun >/dev/null 2>&1 || true
    if ! command -v lxc-create >/dev/null 2>&1; then
        _info "正在安装 lxc, lxc-templates, bridge-utils, iptables..."
        apt-get update && apt-get install -y lxc lxc-templates bridge-utils iptables curl gpg lsb-release
        systemctl enable --now lxc || true
        systemctl enable --now lxc-net || true
    else
        _success "LXC 依赖检查通过"
    fi

    # 确保 LXC 私有网桥配置已启用并创建
    if [ -f "/etc/default/lxc-net" ]; then
        _update_lxc_net_config "USE_LXC_BRIDGE" "true"
        if ! _ensure_lxcbr0; then
            _press_any_key
            return 1
        fi
    fi
    
    local container_name
    read -rp "  请输入 LXC 容器名称 [默认: warp-container]: " container_name
    container_name="${container_name:-warp-container}"
    container_name=$(echo "$container_name" | xargs)
    
    local configure_he="n"
    read -rp "  是否配置并绑定 HE IPv6 隧道? [y/N]: " configure_he
    if [[ "$configure_he" =~ ^[Yy] ]]; then
        configure_he="y"
    else
        configure_he="n"
    fi
    
    local ipv4_mode="1"
    _info "请选择容器的 IPv4 配置方式："
    _info "  1: 默认 DHCP (内外网均通，外网可通过 NAT 访问 IPv4)"
    _info "  2: 仅内网互通 (仅用于宿主机与容器互访，外网强制走 IPv6)"
    _info "  3: 完全禁用 IPv4 (容器内无任何 IPv4 地址，仅保留 IPv6)"
    read -rp "  请选择 [1-3, 默认: 1]: " ipv4_mode
    ipv4_mode="${ipv4_mode:-1}"
    if [[ ! "$ipv4_mode" =~ ^[123]$ ]]; then
        ipv4_mode="1"
    fi
    
    local he_server_ipv4="" he_client_ipv6="" he_server_ipv6="" he_local_ipv4="" share_with_host="n" routed_ipv6=""
    if [[ "$configure_he" == "y" ]]; then
        while true; do
            read -rp "  请输入 HE Server IPv4 (Endpoint) [必填]: " he_server_ipv4
            if [[ -n "$he_server_ipv4" ]]; then
                break
            fi
            _error_no_exit "此项必填"
        done
        
        while true; do
            read -rp "  请输入 HE Client IPv6 Address (例如: 2001:470:1f10:xx::2/64) [必填]: " he_client_ipv6
            if [[ -n "$he_client_ipv6" ]]; then
                break
            fi
            _error_no_exit "此项必填"
        done
        # Client IPv6: 提取纯地址（去掉 /64 等前缀长度），interfaces 中 netmask 单独写
        he_client_ipv6="${he_client_ipv6%%/*}"
        
        while true; do
            read -rp "  请输入 HE Server IPv6 Address (例如: 2001:470:1f10:xx::1/64 或纯地址) [必填]: " he_server_ipv6
            if [[ -n "$he_server_ipv6" ]]; then
                break
            fi
            _error_no_exit "此项必填"
        done
        # Server IPv6: gateway 只需纯地址
        he_server_ipv6="${he_server_ipv6%%/*}"
        
        local default_local_ipv4
        default_local_ipv4=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+' || ip route get 8.8.8.8 2>/dev/null | awk '{print $7}' || curl -4 -s -m 5 ip.sb 2>/dev/null || true)
        read -rp "  请输入宿主机本地 IPv4 地址 (通常为公网 IP，若在 NAT 后则为内网 IP) [默认: $default_local_ipv4]: " he_local_ipv4
        he_local_ipv4="${he_local_ipv4:-$default_local_ipv4}"
        # Local IPv4: 去掉可能携带的 /32
        he_local_ipv4="${he_local_ipv4%%/*}"
        if [[ -z "$he_local_ipv4" ]]; then
            _error_no_exit "无法自动获取本地 IPv4，且未手动输入，配置取消。"
            _press_any_key
            return 1
        fi
        
        read -rp "  是否允许宿主机也使用此 IPv6 隧道访问外网? (否:仅容器可用，是:宿主机与容器均可用) [y/N]: " share_with_host
        if [[ "$share_with_host" =~ ^[Yy] ]]; then
            share_with_host="y"
        else
            share_with_host="n"
        fi
        
        _info "请提供 HE 分配的 Routed IPv6 Prefix 以获得更广泛的地址空间。"
        _info "（在 HE 控制台 → Tunnel Details → Routed IPv6 Prefixes 中查看）"
        while true; do
            read -rp "  请输入 HE Routed IPv6 Prefix (例如: 2001:470:1f11:xx::/64) [必填]: " routed_ipv6
            if [[ -n "$routed_ipv6" ]]; then
                break
            fi
            _error_no_exit "此项必填，请于 HE 控制台获取 Routed IPv6 Prefix"
        done
        # Routed Prefix: 规范化——保留网络部分（去掉末尾 /xx 之前的多余空格，但保留 /64）
        # 提取前缀 base 时用 ${routed_ipv6%%/*} 或 ${routed_ipv6%%::*}；这里只做轻量规范
        routed_ipv6=$(echo "$routed_ipv6" | sed 's/[[:space:]]//g')

        local random_suffix
        random_suffix=$(printf '%04x' $((RANDOM % 65536)))
        read -rp "  请输入 Routed Prefix 的子网后缀 (随机生成可避免冲突) [默认: ${random_suffix}]: " routed_suffix
        routed_suffix="${routed_suffix:-$random_suffix}"
        routed_suffix=$(echo "$routed_suffix" | sed 's/[^a-fA-F0-9]//g' | tr '[:upper:]' '[:lower:]')
        if [[ -z "$routed_suffix" ]]; then
            routed_suffix="$random_suffix"
        fi
        _info "容器 IPv6 地址后缀: ${routed_suffix} (Host: ::1, Container: ::2)"
    fi
    
    if [[ "$configure_he" == "y" ]]; then
        # 自动检测并清理可能残留的 physXXXX 重命名物理接口
        local phys_dev
        for phys_dev in $(ip -o link show | awk -F': ' '{print $2}' | grep -oE '^phys[a-zA-Z0-9]+' || true); do
            _info "检测到上次运行残留的网卡接口 ${phys_dev}，正在清理..."
            ip link set "${phys_dev}" down 2>/dev/null || true
            ip tunnel del "${phys_dev}" 2>/dev/null || true
            ip link delete "${phys_dev}" 2>/dev/null || true
        done

        if ip link show he-ipv6 >/dev/null 2>&1; then
            _warn "宿主机上已存在 he-ipv6 接口。"
            local overwrite_tunnel
            read -rp "  是否删除并重新配置该接口? [y/N]: " overwrite_tunnel
            if [[ "$overwrite_tunnel" =~ ^[Yy] ]]; then
                _info "正在清理旧的 he-ipv6 接口..."
                ip link set he-ipv6 down 2>/dev/null || true
                ip tunnel del he-ipv6 2>/dev/null || true
                rm -f /etc/network/interfaces.d/he-ipv6
            else
                _info "已取消。"
                _press_any_key
                return 1
            fi
        fi
        
        _info "正在配置宿主机 HE 隧道接口..."
        if [ ! -d /etc/network/interfaces.d ]; then
            mkdir -p /etc/network/interfaces.d
        fi
        if [ -f /etc/network/interfaces ] && ! grep -q -E "^\s*source\s+/etc/network/interfaces.d/" /etc/network/interfaces; then
            echo "" >> /etc/network/interfaces
            echo "source /etc/network/interfaces.d/*" >> /etc/network/interfaces
        fi
        
        if [[ "$share_with_host" == "y" ]]; then
            cat > /etc/network/interfaces.d/he-ipv6 <<EOF
auto he-ipv6
iface he-ipv6 inet6 v4tunnel
    address ${he_client_ipv6}
    netmask 64
    endpoint ${he_server_ipv4}
    local ${he_local_ipv4}
    ttl 255
    post-up ip -6 route add default via ${he_server_ipv6} dev he-ipv6 table 100 2>/dev/null || true
    post-up ip -6 rule add from ${routed_ipv6} lookup 100 2>/dev/null || true
    pre-down ip -6 rule del from ${routed_ipv6} lookup 100 2>/dev/null || true
    pre-down ip -6 route del default via ${he_server_ipv6} dev he-ipv6 table 100 2>/dev/null || true
EOF
        else
            cat > /etc/network/interfaces.d/he-ipv6 <<EOF
auto he-ipv6
iface he-ipv6 inet6 v4tunnel
    address ${he_client_ipv6}
    netmask 64
    endpoint ${he_server_ipv4}
    local ${he_local_ipv4}
    ttl 255
EOF
        fi
        
        _info "正在启动宿主机 sit 隧道接口..."
        ifdown he-ipv6 >/dev/null 2>&1 || true
        if ! ifup he-ipv6 2>/dev/null; then
            modprobe sit >/dev/null 2>&1 || true
            local err_msg
            if ! err_msg=$(ip tunnel add he-ipv6 mode sit remote "${he_server_ipv4}" local "${he_local_ipv4}" ttl 255 2>&1); then
                _error_no_exit "创建 sit 隧道失败: ${err_msg}"
                _error_no_exit "请检查本地 IPv4 (${he_local_ipv4}) 是否是网卡上绑定的真实 IP (如果是 NAT 机，必须填内网 IP)。"
                _press_any_key
                return 1
            fi
            if ! err_msg=$(ip link set he-ipv6 up 2>&1); then
                _error_no_exit "启用 he-ipv6 接口失败: ${err_msg}"
                _press_any_key
                return 1
            fi
            if ! err_msg=$(ip addr add "${he_client_ipv6}" dev he-ipv6 2>&1); then
                _error_no_exit "为 he-ipv6 绑定 Client IPv6 失败: ${err_msg}"
                _press_any_key
                return 1
            fi
            if [[ "$share_with_host" == "y" ]]; then
                ip route add ::/0 dev he-ipv6 via "${he_server_ipv6}" 2>/dev/null || true
            else
                ip -6 route add default via "${he_server_ipv6}" dev he-ipv6 table 100 2>/dev/null || true
                ip -6 rule add from "${routed_ipv6}" lookup 100 2>/dev/null || true
            fi
        fi
        
        _info "正在测试宿主机隧道连通性 (ping6 ${he_server_ipv6})..."
        if ping6 -c 3 -W 3 "${he_server_ipv6}" >/dev/null 2>&1; then
            _success "宿主机 HE IPv6 隧道连通性测试成功！"
        else
            _warn "宿主机无法 ping6 通 HE 网关 ${he_server_ipv6}，请检查安全组或本地 IPv4 是否放行协议号 41。"
        fi
    fi
    
    local container_exists=0
    if lxc-info -n "$container_name" >/dev/null 2>&1; then
        container_exists=1
        _warn "LXC 容器 $container_name 已存在。"
        local recreate_container
        read -rp "  是否删除并重新创建此容器? [y/N]: " recreate_container
        if [[ "$recreate_container" =~ ^[Yy] ]]; then
            _info "正在停止并删除旧容器..."
            lxc-stop -n "$container_name" -k 2>/dev/null || true
            lxc-destroy -n "$container_name" 2>/dev/null || true
            container_exists=0
        fi
    fi
    
    if [ "$container_exists" -eq 0 ]; then
        _info "正在创建 Debian 12 LXC 容器 (名称: $container_name)..."
        _info "将从官方下载模板，首次拉取可能需要几分钟，请耐心等待..."
        if ! lxc-create -t download -n "$container_name" -- -d debian -r bookworm -a amd64; then
            _error_no_exit "创建 LXC 容器失败，请检查网络后重试。"
            _press_any_key
            return 1
        fi
        _success "LXC 容器创建成功"
    fi
    
    local lxc_config="/var/lib/lxc/$container_name/config"
    if [ ! -f "$lxc_config" ]; then
        _error_no_exit "未找到容器配置文件: $lxc_config"
        _press_any_key
        return 1
    fi
    
    sed -i '/lxc.cgroup2.devices.allow = c 10:200/d' "$lxc_config"
    sed -i '/lxc.cgroup.devices.allow = c 10:200/d' "$lxc_config"
    sed -i '/lxc.hook.autodev/d' "$lxc_config"
    sed -i '/lxc.mount.entry = \/dev\/net\/tun/d' "$lxc_config"
    sed -i '/lxc.apparmor.profile/d' "$lxc_config"
    sed -i '/lxc.net.1./d' "$lxc_config"
    
    cat >> "$lxc_config" <<EOF
# 1. 允许并挂载 TUN 设备（WARP 必需）
lxc.cgroup2.devices.allow = c 10:200 rwm
lxc.cgroup.devices.allow = c 10:200 rwm
lxc.mount.entry = /dev/net/tun dev/net/tun none bind,create=file
lxc.apparmor.profile = unconfined
EOF
    

    
    local container_rootfs="/var/lib/lxc/$container_name/rootfs"
    local container_interfaces="${container_rootfs}/etc/network/interfaces"
    if [ ! -d "$container_rootfs" ]; then
        _error_no_exit "未找到容器 rootfs 路径: ${container_rootfs}，配置失败。"
        _press_any_key
        return 1
    fi
    mkdir -p "${container_rootfs}/etc/network"
    
    local container_local_ipv4="" bridge_mask="24"
    if [[ "$ipv4_mode" == "2" ]]; then
        local bridge_ip_mask bridge_ip ip_prefix
        bridge_ip_mask=$(ip -o -4 addr show dev lxcbr0 2>/dev/null | awk '{print $4}' || echo "")
        if [[ -n "$bridge_ip_mask" ]]; then
            bridge_ip="${bridge_ip_mask%%/*}"
            bridge_mask="${bridge_ip_mask##*/}"
            ip_prefix="${bridge_ip%.*}"
            container_local_ipv4="${ip_prefix}.200"
        else
            container_local_ipv4="10.0.3.200"
            bridge_mask="24"
        fi
    fi

    if [[ "$configure_he" == "n" ]]; then
        if [[ "$ipv4_mode" == "3" ]]; then
            cat > "$container_interfaces" <<EOF
auto lo
iface lo inet loopback
EOF
        elif [[ "$ipv4_mode" == "2" ]]; then
            cat > "$container_interfaces" <<EOF
auto lo
iface lo inet loopback

# IPv4 仅内网互通 (无默认路由)
auto eth0
iface eth0 inet static
    address ${container_local_ipv4}/${bridge_mask}
EOF
        else
            cat > "$container_interfaces" <<EOF
auto lo
iface lo inet loopback

# IPv4 默认网卡
auto eth0
iface eth0 inet dhcp
EOF
        fi
    else
        local prefix_base container_routed_ip host_bridge_ipv6
        # 提取前缀 base：先去掉 /64，再根据是否含 :: 分支处理
        local _routed_addr="${routed_ipv6%%/*}"  # 去掉 /64 等前缀长度
        if [[ "$_routed_addr" == *::* ]]; then
            prefix_base="${_routed_addr%%::*}"  # 取 :: 之前的网络前缀部分
        else
            prefix_base="${_routed_addr%:*}"    # 展开格式：去掉最后一个主机段
        fi
        container_routed_ip="${prefix_base}:${routed_suffix}::2"
        host_bridge_ipv6="${prefix_base}:${routed_suffix}::1"
        
        if [[ "$ipv4_mode" == "3" ]]; then
            # 完全禁用 IPv4
            cat > "$container_interfaces" <<EOF
auto lo
iface lo inet loopback

# HE IPv6 共享/路由网卡 (Routed IPv6 Prefix)
auto eth0
iface eth0 inet6 static
    address ${container_routed_ip}/64
    gateway ${host_bridge_ipv6}
    dns-nameservers 2606:4700:4700::1111 2001:4860:4860::8888
EOF
        elif [[ "$ipv4_mode" == "2" ]]; then
            # 仅内网互通 (IPv4 静态内网 IP 无 gateway) + HE IPv6
            cat > "$container_interfaces" <<EOF
auto lo
iface lo inet loopback

# IPv4 仅内网互通 (无默认路由)
auto eth0
iface eth0 inet static
    address ${container_local_ipv4}/${bridge_mask}

# HE IPv6 共享/路由网卡 (Routed IPv6 Prefix)
iface eth0 inet6 static
    address ${container_routed_ip}/64
    gateway ${host_bridge_ipv6}
    dns-nameservers 2606:4700:4700::1111 2001:4860:4860::8888
EOF
        else
            # 默认 DHCP + HE IPv6
            cat > "$container_interfaces" <<EOF
auto lo
iface lo inet loopback

# IPv4 默认网卡
auto eth0
iface eth0 inet dhcp

# HE IPv6 共享/路由网卡 (Routed IPv6 Prefix)
iface eth0 inet6 static
    address ${container_routed_ip}/64
    gateway ${host_bridge_ipv6}
EOF
        fi
    fi

    # 额外兼容 systemd-networkd (部分 Debian/Ubuntu 官方模板默认使用 systemd-networkd)
    local container_networkd_dir="${container_rootfs}/etc/systemd/network"
    if [ -d "$container_networkd_dir" ]; then
        local container_networkd_conf="${container_networkd_dir}/eth0.network"
        _info "检测到 systemd-networkd 配置目录，正在配置 eth0.network..."
        
        # 备份原配置（如果存在且不是我们写入的备份）
        if [ -f "$container_networkd_conf" ] && [ ! -f "${container_networkd_conf}.bak" ]; then
            cp "$container_networkd_conf" "${container_networkd_conf}.bak" 2>/dev/null || true
        fi
        
        if [[ "$configure_he" == "n" ]]; then
            if [[ "$ipv4_mode" == "3" ]]; then
                cat > "$container_networkd_conf" <<EOF
[Match]
Name=eth0

[Network]
DHCP=no
LinkLocalAddressing=no
EOF
            elif [[ "$ipv4_mode" == "2" ]]; then
                cat > "$container_networkd_conf" <<EOF
[Match]
Name=eth0

[Network]
DHCP=no
Address=${container_local_ipv4}/${bridge_mask}
LinkLocalAddressing=no
EOF
            else
                cat > "$container_networkd_conf" <<EOF
[Match]
Name=eth0

[Network]
DHCP=ipv4
EOF
            fi
        else
            if [[ "$ipv4_mode" == "3" ]]; then
                cat > "$container_networkd_conf" <<EOF
[Match]
Name=eth0

[Network]
DHCP=no
LinkLocalAddressing=no
Address=${container_routed_ip}/64
Gateway=${host_bridge_ipv6}
DNS=2606:4700:4700::1111
DNS=2001:4860:4860::8888
DNS=2606:4700:4700::1001
DNS=2001:4860:4860::8844
EOF
            elif [[ "$ipv4_mode" == "2" ]]; then
                cat > "$container_networkd_conf" <<EOF
[Match]
Name=eth0

[Network]
DHCP=no
Address=${container_local_ipv4}/${bridge_mask}
Address=${container_routed_ip}/64
Gateway=${host_bridge_ipv6}
DNS=2606:4700:4700::1111
DNS=2001:4860:4860::8888
DNS=2606:4700:4700::1001
DNS=2001:4860:4860::8844
EOF
            else
                cat > "$container_networkd_conf" <<EOF
[Match]
Name=eth0

[Network]
DHCP=ipv4
Address=${container_routed_ip}/64
Gateway=${host_bridge_ipv6}
DNS=2606:4700:4700::1111
DNS=2001:4860:4860::8888
DNS=2606:4700:4700::1001
DNS=2001:4860:4860::8844
EOF
            fi
        fi
    fi

    if [[ "$ipv4_mode" == "2" || "$ipv4_mode" == "3" ]]; then
        _info "正在配置容器 IPv6 DNS (写入容器内的 /etc/resolv.conf)..."
        local container_resolv="${container_rootfs}/etc/resolv.conf"
        if [ -f "$container_resolv" ] || [ -L "$container_resolv" ]; then
            rm -f "$container_resolv" 2>/dev/null || true
        fi
        cat > "$container_resolv" <<EOF
nameserver 2606:4700:4700::1111
nameserver 2001:4860:4860::8888
nameserver 2606:4700:4700::1001
nameserver 2001:4860:4860::8844
EOF
        # 防止 Proxmox VE 覆盖容器 DNS
        touch "${container_rootfs}/etc/.pve-ignore.resolv.conf" 2>/dev/null || true

        # 锁定 APT 仅走 IPv6
        _info "正在配置容器 APT 强制 IPv6..."
        mkdir -p "${container_rootfs}/etc/apt/apt.conf.d" 2>/dev/null || true
        echo 'Acquire::ForceIPv6 "true";' > "${container_rootfs}/etc/apt/apt.conf.d/99force-ipv6"
        _success "已写入 Acquire::ForceIPv6 true (容器内 /etc/apt/apt.conf.d/99force-ipv6)"
    fi

    if [[ "$configure_he" == "y" ]]; then
        _info "正在配置宿主机 LXC 网桥 IPv6 参数..."
        _update_lxc_net_config "USE_LXC_BRIDGE" "true"
        _update_lxc_net_config "LXC_IPV6_ADDR" "$host_bridge_ipv6"
        _update_lxc_net_config "LXC_IPV6_MASK" "64"
        _update_lxc_net_config "LXC_IPV6_NETWORK" "${routed_ipv6}"
        _update_lxc_net_config "LXC_IPV6_NAT" "false"
        
        _info "正在开启宿主机 IPv6 转发..."
        sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || true
        echo "net.ipv6.conf.all.forwarding=1" > /etc/sysctl.d/99-ipv6-forwarding.conf 2>/dev/null || true
        
        _info "正在直接配置 lxcbr0 IPv6 地址 (避免 restart 导致网桥中断)..."
        ip -6 addr add ${host_bridge_ipv6}/64 dev lxcbr0 2>/dev/null || true
        ip link set lxcbr0 up 2>/dev/null || true
    fi

    local auto_start="y"
    read -rp "  是否设置容器开机自启? [Y/n]: " auto_start
    auto_start="${auto_start:-y}"
    if [[ "$auto_start" =~ ^[Yy] ]]; then
        sed -i '/lxc.start.auto/d' "$lxc_config"
        sed -i '/lxc.start.delay/d' "$lxc_config"
        cat >> "$lxc_config" <<EOF
lxc.start.auto = 1
lxc.start.delay = 5
EOF
        _success "已配置容器开机自启"
    fi

    _info "正在启动 LXC 容器 $container_name..."
    if [[ "$configure_he" == "y" ]]; then
        if ! ip link show he-ipv6 >/dev/null 2>&1; then
            ifup he-ipv6 >/dev/null 2>&1 || true
        fi
    fi
    
    lxc-start -n "$container_name" -l DEBUG -o "/tmp/lxc_${container_name}.log"
    
    local wait_i=0
    while [ $wait_i -lt 15 ]; do
        if lxc-info -n "$container_name" -s | grep -q "RUNNING"; then
            break
        fi
        sleep 1
        wait_i=$((wait_i + 1))
    done
    
    if lxc-info -n "$container_name" -s | grep -q "RUNNING"; then
        _success "LXC 容器 $container_name 启动成功"
    else
        _error_no_exit "LXC 容器启动超时，请后续使用 lxc-info 手动排查。"
        if [ -f "/tmp/lxc_${container_name}.log" ]; then
            _info "容器启动调试日志最后 20 行："
            tail -n 20 "/tmp/lxc_${container_name}.log" | sed 's/^/      /'
        fi
        _press_any_key
        return 1
    fi
    
    local container_vpsgo="${container_rootfs}/usr/local/bin/vpsgo"
    _info "正在将 vpsgo 脚本集成到容器内的 /usr/local/bin/vpsgo..."
    mkdir -p "$(dirname "$container_vpsgo")"
    local current_script
    current_script=$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")
    if cp "$current_script" "$container_vpsgo"; then
        chmod 0755 "$container_vpsgo"
        mkdir -p "${container_rootfs}/etc/vpsgo"
        _success "vpsgo 脚本成功复制并集成到容器内部"
    else
        _warn "复制 vpsgo 到容器失败，请后续手动部署。"
    fi
    
    _info "正在等待容器网络初始化 (10 秒)..."
    sleep 10
    
    _info "正在进行容器内网络可用性检查..."
    if [[ "$configure_he" == "y" ]]; then
        _info "容器内 Ping HE IPv6 网关测试:"
        if lxc-attach -n "$container_name" -- ping6 -c 3 -W 3 "${he_server_ipv6}" >/tmp/lxc_ping_test.log 2>&1; then
            _success "容器内 Ping HE IPv6 网关成功！"
        else
            _warn "容器内无法 ping6 通 HE 网关 ${he_server_ipv6}。"
            cat /tmp/lxc_ping_test.log | sed 's/^/      /' || true
        fi
        
        _info "容器内获取公共 IPv6 测试:"
        local ipv6_hosts=("ip.sb" "api6.ipify.org" "icanhazip.com" "ident.me")
        local container_ipv6_addr=""
        for host in "${ipv6_hosts[@]}"; do
            container_ipv6_addr=$(lxc-attach -n "$container_name" -- curl -6 -s -m 5 "$host" 2>/dev/null | tr -d '[:space:]')
            if [[ -n "$container_ipv6_addr" ]]; then
                break
            fi
        done
        
        if [[ -n "$container_ipv6_addr" ]]; then
            _success "容器内成功获取公共 IPv6 地址: ${container_ipv6_addr}"
        else
            _error_no_exit "容器内获取公共 IPv6 地址失败，请检查 HE 隧道设置。"
        fi
    else
        _info "测试容器内 IPv4 网络连通性 (ping 1.1.1.1):"
        if lxc-attach -n "$container_name" -- ping -c 3 -W 3 1.1.1.1 >/dev/null 2>&1; then
            _success "容器内 IPv4 网络连接正常！"
        else
            _warn "容器内无法访问外网 IPv4，请检查宿主机 NAT 规则与 lxc-net 状态。"
        fi
    fi
    
    _press_any_key
}

# --- Port Forwarding Submodule ---

_lxc_port_forward_menu_screen() {
    _header "容器端口转发管理"
    _menu_pair "1" "查看转发规则" "显示当前配置的转发列表" "green" "2" "添加转发规则" "添加宿主机到容器的映射" "green"
    _menu_item "3" "删除转发规则" "移除已配的端口转发" "yellow"
    _separator
    _menu_item "0" "返回上级菜单" "" "red"
    _separator
}

_lxc_port_forward_menu() {
    while true; do
        _ui_print_screen _lxc_port_forward_menu_screen
        local ch
        read -rp "  ${CYAN}➜${PLAIN}  选择 [0-3]: " ch
        case "$ch" in
            1)
                _lxc_port_forward_list
                _press_any_key
                ;;
            2) _lxc_port_forward_add ;;
            3) _lxc_port_forward_delete ;;
            0) return ;;
            *) _error_no_exit "无效选项: ${ch}"; sleep 1 ;;
        esac
    done
}

_lxc_port_forward_list() {
    _info "当前的容器端口转发规则:"
    local rules
    rules=$(iptables -t nat -S PREROUTING 2>/dev/null | grep "vpsgo-lxc-forward" || true)
    if [[ -z "$rules" ]]; then
        _info "无活动的端口转发规则。"
        return
    fi
    
    printf "    %-6s %-10s %-12s %-20s\n" "序号" "协议" "宿主机端口" "容器目标 IP:端口"
    _separator
    local idx=1
    while read -r rule; do
        [[ -z "$rule" ]] && continue
        local proto
        proto=$(echo "$rule" | grep -oE "\-p (tcp|udp)" | awk '{print $2}')
        local dport
        dport=$(echo "$rule" | grep -oE "\-\-dport [0-9]+" | awk '{print $2}')
        local to_dest
        to_dest=$(echo "$rule" | grep -oE "\-\-to\-destination [^ ]+" | awk '{print $2}')
        
        printf "    %-6s %-10s %-12s %-20s\n" "$idx" "$proto" "$dport" "$to_dest"
        idx=$((idx + 1))
    done <<< "$rules"
}

_lxc_port_forward_add() {
    _header "添加端口转发"
    
    local container_name
    read -rp "  请输入 LXC 容器名称 [默认: warp-container]: " container_name
    container_name="${container_name:-warp-container}"
    container_name=$(echo "$container_name" | xargs)
    
    local container_ip=""
    if lxc-info -n "$container_name" -i >/dev/null 2>&1; then
        container_ip=$(lxc-info -n "$container_name" -i | awk '{print $2}' | grep -E "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | head -n1 || true)
    fi
    
    local input_ip
    read -rp "  请输入容器的内网 IPv4 地址 [检测到: ${container_ip:-未知}]: " input_ip
    container_ip="${input_ip:-$container_ip}"
    if [[ -z "$container_ip" ]]; then
        _error_no_exit "必须指定容器 IP 地址。"
        _press_any_key
        return
    fi
    
    local host_port
    while true; do
        read -rp "  请输入宿主机监听端口 (1-65535): " host_port
        if [[ "$host_port" =~ ^[0-9]+$ ]] && [ "$host_port" -ge 1 ] && [ "$host_port" -le 65535 ]; then
            break
        fi
        _error_no_exit "无效端口"
    done
    
    local container_port
    while true; do
        read -rp "  请输入容器目标端口 [默认与宿主机端口一致: $host_port]: " container_port
        container_port="${container_port:-$host_port}"
        if [[ "$container_port" =~ ^[0-9]+$ ]] && [ "$container_port" -ge 1 ] && [ "$container_port" -le 65535 ]; then
            break
        fi
        _error_no_exit "无效端口"
    done
    
    local proto
    read -rp "  请输入转发协议 (tcp/udp/both) [默认: both]: " proto
    proto=$(echo "${proto:-both}" | tr '[:upper:]' '[:lower:]')
    
    if [[ "$proto" == "tcp" || "$proto" == "both" ]]; then
        iptables -t nat -A PREROUTING -p tcp --dport "$host_port" -j DNAT --to-destination "${container_ip}:${container_port}" -m comment --comment "vpsgo-lxc-forward"
        iptables -A FORWARD -p tcp -d "$container_ip" --dport "$container_port" -j ACCEPT -m comment --comment "vpsgo-lxc-forward"
    fi
    if [[ "$proto" == "udp" || "$proto" == "both" ]]; then
        iptables -t nat -A PREROUTING -p udp --dport "$host_port" -j DNAT --to-destination "${container_ip}:${container_port}" -m comment --comment "vpsgo-lxc-forward"
        iptables -A FORWARD -p udp -d "$container_ip" --dport "$container_port" -j ACCEPT -m comment --comment "vpsgo-lxc-forward"
    fi
    
    _success "端口转发规则已添加！宿主机端口 $host_port ➜ 容器 $container_ip:$container_port ($proto)"
    _info "提示: 为了在重启后保留规则，请使用 iptables-persistent 保存规则:"
    _info "  dpkg-reconfigure iptables-persistent  或  netfilter-persistent save"
    _press_any_key
}

_lxc_port_forward_delete() {
    _header "删除端口转发"
    
    local rules
    rules=$(iptables -t nat -S PREROUTING 2>/dev/null | grep "vpsgo-lxc-forward" || true)
    if [[ -z "$rules" ]]; then
        _info "无活动的端口转发规则。"
        _press_any_key
        return
    fi
    
    _lxc_port_forward_list
    
    local count
    count=$(echo "$rules" | wc -l)
    
    local num
    read -rp "  请选择要删除的规则序号 [1-$count, 默认取消]: " num
    if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt "$count" ]; then
        _info "已取消。"
        _press_any_key
        return
    fi
    
    local rule_line
    rule_line=$(echo "$rules" | sed -n "${num}p")
    
    local proto
    proto=$(echo "$rule_line" | grep -oE "\-p (tcp|udp)" | awk '{print $2}')
    local dport
    dport=$(echo "$rule_line" | grep -oE "\-\-dport [0-9]+" | awk '{print $2}')
    local to_dest
    to_dest=$(echo "$rule_line" | grep -oE "\-\-to\-destination [^ ]+" | awk '{print $2}')
    
    local dest_ip="${to_dest%%:*}"
    local dest_port="${to_dest##*:}"
    
    iptables -t nat -D PREROUTING -p "$proto" --dport "$dport" -j DNAT --to-destination "$to_dest" -m comment --comment "vpsgo-lxc-forward" 2>/dev/null || true
    iptables -D FORWARD -p "$proto" -d "$dest_ip" --dport "$dest_port" -j ACCEPT -m comment --comment "vpsgo-lxc-forward" 2>/dev/null || true
    
    _success "规则已成功删除。"
    _press_any_key
}

# --- Check & Control ---

_he_ipv6_lxc_status_check() {
    _header "可用性与状态检查"
    
    local container_name
    read -rp "  请输入 LXC 容器名称 [默认: warp-container]: " container_name
    container_name="${container_name:-warp-container}"
    container_name=$(echo "$container_name" | xargs)
    
    if ! lxc-info -n "$container_name" >/dev/null 2>&1; then
        _error_no_exit "LXC 容器 $container_name 不存在。"
        _press_any_key
        return
    fi
    
    local c_status
    c_status=$(lxc-info -n "$container_name" -s | awk '{print $2}' || echo "UNKNOWN")
    _status_kv "容器名称" "$container_name" "cyan"
    _status_kv "运行状态" "$c_status" "$( [[ "$c_status" == "RUNNING" ]] && echo "green" || echo "red" )"
    
    if ip link show he-ipv6 >/dev/null 2>&1; then
        local tunnel_state
        tunnel_state=$(ip link show he-ipv6 | grep -oE "state [A-Z]+" | awk '{print $2}' || echo "UP")
        _status_kv "宿主机 he-ipv6 接口" "$tunnel_state" "green"
    else
        _status_kv "宿主机 he-ipv6 接口" "不存在/已直通移出" "yellow"
    fi
    
    if [[ "$c_status" == "RUNNING" ]]; then
        _info "容器内网口分配列表:"
        local raw_ips
        raw_ips=$(lxc-attach -n "$container_name" -- ip -o addr show 2>/dev/null || true)
        if [[ -n "$raw_ips" ]]; then
            local last_iface=""
            while read -r line; do
                [[ -z "$line" ]] && continue
                local iface type ip details
                iface=$(echo "$line" | awk '{print $2}')
                type=$(echo "$line" | awk '{print $3}')
                ip=$(echo "$line" | awk '{print $4}')
                details=$(echo "$line" | cut -d' ' -f5-)
                
                [[ "$type" != "inet" && "$type" != "inet6" ]] && continue
                
                if [[ "$iface" != "$last_iface" ]]; then
                    _info "  网卡 [${iface}]:"
                    last_iface="$iface"
                fi
                
                local label="IPv4"
                if [[ "$type" == "inet6" ]]; then
                    if [[ "$details" == *"scope link"* ]]; then
                        label="IPv6 本地链路 (Link-Local)"
                    else
                        label="IPv6 全局单播 (Global)"
                    fi
                else
                    if [[ "$details" == *"dynamic"* ]]; then
                        label="IPv4 动态分配 (DHCP)"
                    else
                        label="IPv4 静态分配 (Static)"
                    fi
                fi
                echo "      - ${label}: ${ip}"
            done <<< "$raw_ips"
            
            echo ""
            local show_raw="n"
            read -rp "  是否查看原始网卡数据? [y/N]: " show_raw
            if [[ "$show_raw" =~ ^[Yy] ]]; then
                _info "原始网卡数据:"
                lxc-attach -n "$container_name" -- ip addr show 2>/dev/null | sed 's/^/      /' || true
            fi
        else
            _warn "无法获取容器网卡信息。"
        fi
        
        _info "正在诊断容器网络..."
        local has_ipv6="n"
        if lxc-attach -n "$container_name" -- ip -6 route show | grep -q "default"; then
            has_ipv6="y"
        fi
        
        if [[ "$has_ipv6" == "y" ]]; then
            local ipv6_hosts=("ip.sb" "api6.ipify.org" "icanhazip.com" "ident.me")
            local container_ipv6_addr=""
            for host in "${ipv6_hosts[@]}"; do
                container_ipv6_addr=$(lxc-attach -n "$container_name" -- curl -6 -s -m 5 "$host" 2>/dev/null | tr -d '[:space:]')
                if [[ -n "$container_ipv6_addr" ]]; then
                    break
                fi
            done
            
            if [[ -n "$container_ipv6_addr" ]]; then
                _success "容器内 IPv6 通畅，公网 IP: ${container_ipv6_addr}"
            else
                _error_no_exit "容器内 IPv6 网络未成功连接外网"
            fi
        else
            if lxc-attach -n "$container_name" -- ping -c 3 -W 3 1.1.1.1 >/dev/null 2>&1; then
                _success "容器内 IPv4 外网连接正常"
            else
                _error_no_exit "容器内网络不通"
            fi
        fi
        
        if lxc-attach -n "$container_name" -- [ -f /usr/local/bin/vpsgo ] 2>/dev/null; then
            _success "vpsgo 脚本在容器内状态: 已安装"
        else
            _warn "vpsgo 脚本在容器内状态: 未安装"
        fi
    else
        _warn "容器未运行，无法进行内部网络诊断。"
    fi
    
    _press_any_key
}

_he_ipv6_lxc_power_control() {
    _header "启动/停止容器"
    
    local container_name
    read -rp "  请输入 LXC 容器名称 [默认: warp-container]: " container_name
    container_name="${container_name:-warp-container}"
    container_name=$(echo "$container_name" | xargs)
    
    if ! lxc-info -n "$container_name" >/dev/null 2>&1; then
        _error_no_exit "LXC 容器 $container_name 不存在。"
        _press_any_key
        return
    fi
    
    local c_status
    c_status=$(lxc-info -n "$container_name" -s | awk '{print $2}')
    
    if [[ "$c_status" == "RUNNING" ]]; then
        _info "当前容器正在运行。"
        local action
        read -rp "  是否停止容器? [y/N]: " action
        if [[ "$action" =~ ^[Yy] ]]; then
            _info "正在停止容器..."
            lxc-stop -n "$container_name"
            _success "容器已停止"
        fi
    else
        _info "当前容器已停止。"
        local action
        read -rp "  是否启动容器? [y/N]: " action
        if [[ "$action" =~ ^[Yy] ]]; then
            if [ -f /etc/network/interfaces.d/he-ipv6 ]; then
                if ! ip link show he-ipv6 >/dev/null 2>&1; then
                    _info "正在建立宿主机 sit 隧道接口..."
                    ifup he-ipv6 >/dev/null 2>&1 || true
                fi
            fi
            if ! _ensure_lxcbr0; then
                _press_any_key
                return 1
            fi
            _info "正在启动容器..."
            lxc-start -n "$container_name" -l DEBUG -o "/tmp/lxc_${container_name}.log"
            local wait_i=0
            while [ $wait_i -lt 15 ]; do
                if lxc-info -n "$container_name" -s | grep -q "RUNNING"; then
                    break
                fi
                sleep 1
                wait_i=$((wait_i + 1))
            done
            if lxc-info -n "$container_name" -s | grep -q "RUNNING"; then
                _success "容器已启动"
            else
                _error_no_exit "启动容器超时，请手动排查。"
                if [ -f "/tmp/lxc_${container_name}.log" ]; then
                    _info "容器启动调试日志最后 20 行："
                    tail -n 20 "/tmp/lxc_${container_name}.log" | sed 's/^/      /'
                fi
            fi
        fi
    fi
    _press_any_key
}

_lxc_attach() {
    _header "快速进入容器终端"
    
    local lxc_list=()
    if command -v lxc-ls >/dev/null 2>&1; then
        while IFS= read -r cname; do
            cname=$(echo "$cname" | xargs)
            [[ -z "$cname" ]] && continue
            lxc_list+=("$cname")
        done < <(lxc-ls -1 2>/dev/null || lxc-ls 2>/dev/null | tr ' ' '\n' || true)
    fi

    if [ "${#lxc_list[@]}" -eq 0 ]; then
        _error_no_exit "当前系统中未检测到任何 LXC 容器。"
        _press_any_key
        return 1
    fi

    _info "可用 LXC 容器列表："
    local i=1
    for cname in "${lxc_list[@]}"; do
        local cstate
        cstate=$(lxc-info -n "$cname" -s 2>/dev/null | awk '{print $2}' || echo "UNKNOWN")
        local ctone="yellow"
        [[ "$cstate" == "RUNNING" ]] && ctone="green"
        [[ "$cstate" == "STOPPED" ]] && ctone="dim"
        _status_kv "[$i] $cname" "$cstate" "$ctone" "20"
        i=$((i+1))
    done
    echo ""

    local choice
    read -rp "  请输入要进入的容器序号或名称 [默认: 1]: " choice
    choice="${choice:-1}"
    choice=$(echo "$choice" | xargs)

    local target_name=""
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -le "${#lxc_list[@]}" ] && [ "$choice" -gt 0 ]; then
        target_name="${lxc_list[$((choice-1))]}"
    else
        target_name="$choice"
    fi

    if ! lxc-info -n "$target_name" >/dev/null 2>&1; then
        _error_no_exit "LXC 容器 $target_name 不存在。"
        _press_any_key
        return 1
    fi

    local c_status
    c_status=$(lxc-info -n "$target_name" -s | awk '{print $2}')
    if [[ "$c_status" != "RUNNING" ]]; then
        _warn "容器 $target_name 当前处于 $c_status 状态，无法进入终端。"
        local start_choice
        read -rp "  是否尝试启动该容器? [Y/n]: " start_choice
        start_choice="${start_choice:-y}"
        if [[ "$start_choice" =~ ^[Yy] ]]; then
            if ! _ensure_lxcbr0; then
                _press_any_key
                return 1
            fi
            _info "正在启动容器 $target_name..."
            lxc-start -n "$target_name" -l DEBUG -o "/tmp/lxc_${target_name}.log"
            local wait_i=0
            while [ $wait_i -lt 10 ]; do
                if lxc-info -n "$target_name" -s | grep -q "RUNNING"; then
                    break
                fi
                sleep 1
                wait_i=$((wait_i + 1))
            done
            c_status=$(lxc-info -n "$target_name" -s | awk '{print $2}')
            if [[ "$c_status" != "RUNNING" ]]; then
                _error_no_exit "启动容器失败，请手动检查。"
                if [ -f "/tmp/lxc_${target_name}.log" ]; then
                    _info "容器启动调试日志最后 20 行："
                    tail -n 20 "/tmp/lxc_${target_name}.log" | sed 's/^/      /'
                fi
                _press_any_key
                return 1
            fi
        else
            return 1
        fi
    fi

    _info "正在进入容器 $target_name 终端 (输入 'exit' 退出)..."
    lxc-attach -n "$target_name"
}

_he_ipv6_lxc_uninstall() {
    _header "卸载与清理"

    local lxc_list=()
    if command -v lxc-ls >/dev/null 2>&1; then
        while IFS= read -r cname; do
            cname=$(echo "$cname" | xargs)
            [[ -z "$cname" ]] && continue
            lxc_list+=("$cname")
        done < <(lxc-ls -1 2>/dev/null || lxc-ls 2>/dev/null | tr ' ' '\n' || true)
    fi

    if [ "${#lxc_list[@]}" -eq 0 ]; then
        _info "当前没有任何 LXC 容器，无需卸载。"
        _press_any_key
        return
    fi

    _info "当前存在的 LXC 容器："
    local i=1
    for cname in "${lxc_list[@]}"; do
        local c_status="停止"
        lxc-info -n "$cname" -s 2>/dev/null | grep -q "RUNNING" && c_status="运行中"
        echo -e "      ${GREEN}${i}.${PLAIN} ${cname} (${c_status})"
        i=$((i + 1))
    done
    echo ""

    local container_name
    read -rp "  请输入要删除的容器名称 [默认: ${lxc_list[0]}]: " container_name
    container_name="${container_name:-${lxc_list[0]}}"
    container_name=$(echo "$container_name" | xargs)

    if ! lxc-info -n "$container_name" >/dev/null 2>&1; then
        _error_no_exit "LXC 容器 $container_name 不存在。"
        _press_any_key
        return
    fi
    
    _warn "警告：此操作将永久删除容器 $container_name 并清除关联的隧道和端口转发配置！"
    local confirm
    read -rp "  你确定要继续吗? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy] ]]; then
        _info "已取消卸载操作。"
        _press_any_key
        return
    fi
    
    local container_ip=""
    if lxc-info -n "$container_name" -i >/dev/null 2>&1; then
        container_ip=$(lxc-info -n "$container_name" -i | awk '{print $2}' | grep -E "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | head -n1 || true)
    fi
    
    if lxc-info -n "$container_name" >/dev/null 2>&1; then
        _info "正在停止并销毁 LXC 容器 $container_name..."
        lxc-stop -n "$container_name" -k 2>/dev/null || true
        lxc-destroy -n "$container_name" 2>/dev/null || true
        _success "LXC 容器已删除"
    else
        _info "未检测到容器 $container_name。"
    fi
    
    if [[ -n "$container_ip" ]]; then
        _info "正在清理关联的端口转发规则..."
        local rules
        rules=$(iptables -t nat -S PREROUTING 2>/dev/null | grep "vpsgo-lxc-forward" | grep "$container_ip" || true)
        while read -r rule; do
            [[ -z "$rule" ]] && continue
            local proto dport to_dest
            proto=$(echo "$rule" | grep -oE "\-p (tcp|udp)" | awk '{print $2}')
            dport=$(echo "$rule" | grep -oE "\-\-dport [0-9]+" | awk '{print $2}')
            to_dest=$(echo "$rule" | grep -oE "\-\-to\-destination [^ ]+" | awk '{print $2}')
            local dest_port="${to_dest##*:}"
            
            iptables -t nat -D PREROUTING -p "$proto" --dport "$dport" -j DNAT --to-destination "$to_dest" -m comment --comment "vpsgo-lxc-forward" 2>/dev/null || true
            iptables -D FORWARD -p "$proto" -d "$container_ip" --dport "$dest_port" -j ACCEPT -m comment --comment "vpsgo-lxc-forward" 2>/dev/null || true
        done <<< "$rules"
        _success "关联端口转发规则已清理"
    fi
    
    _info "正在清理宿主机 he-ipv6 隧道接口与配置..."
    ip -6 rule del lookup 100 2>/dev/null || true
    ip -6 route flush table 100 2>/dev/null || true
    ip link set he-ipv6 down 2>/dev/null || true
    ip tunnel del he-ipv6 2>/dev/null || true
    rm -f /etc/network/interfaces.d/he-ipv6
    _success "HE 隧道配置已删除"
    
    _info "正在重置宿主机 LXC 网桥 IPv6 配置..."
    _reset_lxc_net_ipv6_config
    systemctl restart lxc-net >/dev/null 2>&1 || true
    _success "LXC 网桥已重置"
    
    _success "全部清理完成！"
    _press_any_key
}

# --- HE Host Tunnel Module ---

_he_host_tunnel_menu_screen() {
    _header "宿主机 HE IPv6 隧道管理"
    
    # --- 状态概览 ---
    local tunnel_line="不存在"
    local tunnel_tone="yellow"
    if ip link show he-ipv6 >/dev/null 2>&1; then
        local tstate
        tstate=$(ip link show he-ipv6 | grep -oE "state [A-Z]+" | awk '{print $2}' || echo "UP")
        local taddr
        taddr=$(ip -6 addr show dev he-ipv6 2>/dev/null | grep -oE "inet6 [^ ]+" | head -1 | awk '{print $2}' || true)
        tunnel_line="${tstate}${taddr:+  ${taddr}}"
        tunnel_tone="green"
    fi
    _status_kv "HE 隧道状态" "$tunnel_line" "$tunnel_tone" "12"
    _separator
    
    _menu_pair "1" "配置/启用 HE 隧道" "为宿主机建立 IPv6 默认路由隧道" "green" "2" "可用性与状态检查" "诊断宿主机 HE 隧道连通性" "green"
    _menu_pair "3" "启用/禁用 HE 隧道" "控制宿主机隧道接口开关" "green" "4" "卸载与清理" "彻底删除宿主机 HE 隧道配置" "red"
    _separator
    _menu_item "0" "返回上级菜单" "" "red"
    _separator
}

_he_host_tunnel_menu() {
    while true; do
        _ui_print_screen _he_host_tunnel_menu_screen
        local ch
        read -rp "  ${CYAN}➜${PLAIN}  选择 [0-4]: " ch
        case "$ch" in
            1) _he_host_tunnel_install ;;
            2) _he_host_tunnel_status ;;
            3) _he_host_tunnel_toggle ;;
            4) _he_host_tunnel_uninstall ;;
            0) return ;;
            *) _error_no_exit "无效选项: ${ch}"; sleep 1 ;;
        esac
    done
}

_he_host_tunnel_install() {
    _header "一键配置宿主机 HE IPv6 隧道"
    
    local os
    os="$(_os)"
    if [[ "$os" != "debian" && "$os" != "ubuntu" ]]; then
        _error_no_exit "错误：此功能目前仅支持 Debian 或 Ubuntu 宿主机系统。"
        _press_any_key
        return 1
    fi
    
    local he_server_ipv4="" he_client_ipv6="" he_server_ipv6="" he_local_ipv4=""
    
    while true; do
        read -rp "  请输入 HE Server IPv4 (Endpoint) [必填]: " he_server_ipv4
        if [[ -n "$he_server_ipv4" ]]; then
            break
        fi
        _error_no_exit "此项必填"
    done
    
    while true; do
        read -rp "  请输入 HE Client IPv6 Address (例如: 2001:470:1f10:xx::2/64) [必填]: " he_client_ipv6
        if [[ -n "$he_client_ipv6" ]]; then
            break
        fi
        _error_no_exit "此项必填"
    done
    he_client_ipv6="${he_client_ipv6%%/*}"
    
    while true; do
        read -rp "  请输入 HE Server IPv6 Address (例如: 2001:470:1f10:xx::1/64 或纯地址) [必填]: " he_server_ipv6
        if [[ -n "$he_server_ipv6" ]]; then
            break
        fi
        _error_no_exit "此项必填"
    done
    he_server_ipv6="${he_server_ipv6%%/*}"
    
    local default_local_ipv4
    default_local_ipv4=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+' || ip route get 8.8.8.8 2>/dev/null | awk '{print $7}' || curl -4 -s -m 5 ip.sb 2>/dev/null || true)
    read -rp "  请输入宿主机本地 IPv4 地址 (通常为公网 IP，若在 NAT 后则为内网 IP) [默认: $default_local_ipv4]: " he_local_ipv4
    he_local_ipv4="${he_local_ipv4:-$default_local_ipv4}"
    he_local_ipv4="${he_local_ipv4%%/*}"
    if [[ -z "$he_local_ipv4" ]]; then
        _error_no_exit "无法自动获取本地 IPv4，且未手动输入，配置取消。"
        _press_any_key
        return 1
    fi
    
    if ip link show he-ipv6 >/dev/null 2>&1; then
        _warn "宿主机上已存在 he-ipv6 接口。"
        local overwrite_tunnel
        read -rp "  是否删除并重新配置该接口? [y/N]: " overwrite_tunnel
        if [[ "$overwrite_tunnel" =~ ^[Yy] ]]; then
            _info "正在清理旧的 he-ipv6 接口..."
            ip link set he-ipv6 down 2>/dev/null || true
            ip tunnel del he-ipv6 2>/dev/null || true
            rm -f /etc/network/interfaces.d/he-ipv6
        else
            _info "已取消配置。"
            _press_any_key
            return 1
        fi
    fi
    
    _info "正在配置宿主机 HE 隧道接口..."
    if [ ! -d /etc/network/interfaces.d ]; then
        mkdir -p /etc/network/interfaces.d
    fi
    if [ -f /etc/network/interfaces ] && ! grep -q -E "^\s*source\s+/etc/network/interfaces.d/" /etc/network/interfaces; then
        echo "" >> /etc/network/interfaces
        echo "source /etc/network/interfaces.d/*" >> /etc/network/interfaces
    fi
    
    cat > /etc/network/interfaces.d/he-ipv6 <<EOF
auto he-ipv6
iface he-ipv6 inet6 v4tunnel
    address ${he_client_ipv6}
    netmask 64
    endpoint ${he_server_ipv4}
    local ${he_local_ipv4}
    ttl 255
    gateway ${he_server_ipv6}
EOF
    
    _info "正在启用宿主机 sit 隧道接口..."
    ifdown he-ipv6 >/dev/null 2>&1 || true
    if ! ifup he-ipv6 2>/dev/null; then
        modprobe sit >/dev/null 2>&1 || true
        local err_msg
        if ! err_msg=$(ip tunnel add he-ipv6 mode sit remote "${he_server_ipv4}" local "${he_local_ipv4}" ttl 255 2>&1); then
            _error_no_exit "创建 sit 隧道失败: ${err_msg}"
            _press_any_key
            return 1
        fi
        if ! err_msg=$(ip link set he-ipv6 up 2>&1); then
            _error_no_exit "启用 he-ipv6 接口失败: ${err_msg}"
            _press_any_key
            return 1
        fi
        if ! err_msg=$(ip addr add "${he_client_ipv6}/64" dev he-ipv6 2>&1); then
            _error_no_exit "为 he-ipv6 绑定 Client IPv6 失败: ${err_msg}"
            _press_any_key
            return 1
        fi
        ip route add ::/0 dev he-ipv6 via "${he_server_ipv6}" 2>/dev/null || true
    fi
    
    _info "正在测试宿主机隧道连通性 (ping6 ${he_server_ipv6})..."
    if ping6 -c 3 -W 3 "${he_server_ipv6}" >/dev/null 2>&1; then
        _success "宿主机 HE IPv6 隧道连通性测试成功！"
    else
        _warn "宿主机无法 ping6 通 HE 网关 ${he_server_ipv6}，请检查安全组或本地 IPv4 是否放行协议号 41。"
    fi
    
    _press_any_key
}

_he_host_tunnel_status() {
    _header "宿主机 HE 隧道可用性与状态检查"
    
    if ! ip link show he-ipv6 >/dev/null 2>&1; then
        _error_no_exit "宿主机未检测到 he-ipv6 接口。"
        _press_any_key
        return
    fi
    
    _info "宿主机 he-ipv6 接口信息:"
    ip addr show dev he-ipv6 | sed 's/^/      /' || true
    
    _info "宿主机 IPv6 路由表:"
    ip -6 route show | grep -E "default|he-ipv6" | sed 's/^/      /' || true
    
    _info "正在测试宿主机 HE 隧道连通性..."
    local gateway_ip
    gateway_ip=$(ip -6 route show | grep default | grep he-ipv6 | awk '{print $3}' || true)
    if [[ -z "$gateway_ip" ]]; then
        gateway_ip="2001:4860:4860::8888" 
    fi
    
    _info "Ping 探测目标: ${gateway_ip}"
    if ping6 -c 3 -W 3 "${gateway_ip}" >/tmp/host_ping_test.log 2>&1; then
        _success "宿主机 HE IPv6 隧道连接正常！"
    else
        _warn "宿主机无法 ping6 通目标 ${gateway_ip}。"
        cat /tmp/host_ping_test.log | sed 's/^/      /' || true
    fi
    
    _press_any_key
}

_he_host_tunnel_toggle() {
    _header "启动/停止宿主机 HE 隧道"
    
    if ! ip link show he-ipv6 >/dev/null 2>&1; then
        _error_no_exit "宿主机未检测到 he-ipv6 接口，请先配置。"
        _press_any_key
        return
    fi
    
    local state
    state=$(ip link show he-ipv6 | grep -oE "state [A-Z]+" | awk '{print $2}' || echo "UP")
    _info "当前宿主机 HE 隧道接口状态: $state"
    
    local action
    if [[ "$state" == "UP" || "$state" == "UNKNOWN" ]]; then
        read -rp "  是否关闭宿主机 HE 隧道? [y/N]: " action
        if [[ "$action" =~ ^[Yy] ]]; then
            _info "正在关闭 he-ipv6 接口..."
            ip link set he-ipv6 down 2>/dev/null || true
            _success "已关闭"
        fi
    else
        read -rp "  是否开启宿主机 HE 隧道? [y/N]: " action
        if [[ "$action" =~ ^[Yy] ]]; then
            _info "正在开启 he-ipv6 接口..."
            ip link set he-ipv6 up 2>/dev/null || true
            _success "已开启"
        fi
    fi
    _press_any_key
}

_he_host_tunnel_uninstall() {
    _header "卸载宿主机 HE 隧道"
    
    local action
    read -rp "  确定要完全删除宿主机的 HE 隧道配置与接口吗? [y/N]: " action
    if [[ "$action" =~ ^[Yy] ]]; then
        _info "正在停止并删除 he-ipv6 隧道接口..."
        ip link set he-ipv6 down 2>/dev/null || true
        ip tunnel del he-ipv6 2>/dev/null || true
        
        _info "正在删除配置文件..."
        rm -f /etc/network/interfaces.d/he-ipv6
        
        _success "宿主机 HE 隧道配置已彻底清除！"
    else
        _info "操作已取消。"
    fi
    _press_any_key
}

_network_opt_menu_screen() {
    _header "网络优化"
    _menu_pair "1" "BBR" "启用拥塞控制" "green" "2" "队列调度" "切换 qdisc" "green"
    _menu_pair "3" "IPv4/IPv6 优先" "切换出口偏好" "green" "4" "TCP 缓冲区" "调整内核参数" "green"
    _menu_item "5" "WARP 管理" "安装/刷新/定时" "green"
    _separator
    _menu_item "0" "返回主菜单" "" "red"
    _separator
}

_network_opt_menu() {
    while true; do
        _ui_print_screen _network_opt_menu_screen
        local ch
        read -rp "  ${CYAN}➜${PLAIN}  选择 [0-5]: " ch
        case "$ch" in
            1) _bbr_install ;;
            2) _qdisc_setup ;;
            3) _v4v6_setup ;;
            4) _tcptune_setup ;;
            5) _warp_manage ;;
            0) return ;;
            *) _error_no_exit "无效选项: ${ch}"; sleep 1 ;;
        esac
    done
}

_script_tools_menu_screen() {
    _header "脚本工具"
    _menu_pair "1" "iPerf3 服务端" "启动测速服务" "green" "2" "NodeQuality" "线路质量测试" "green"
    _menu_pair "3" "Speedtest" "安装测速 CLI" "green" "4" "Akile DNS" "检测 DNS 解锁" "green"
    _menu_pair "5" "DNS 管理" "修改/验证 DNS" "green" "6" "NextTrace" "安装/路由检测" "green"
    _separator
    _menu_item "0" "返回主菜单" "" "red"
    _separator
}

_script_tools_menu() {
    while true; do
        _ui_print_screen _script_tools_menu_screen
        local ch
        read -rp "  ${CYAN}➜${PLAIN}  选择 [0-6]: " ch
        case "$ch" in
            1) _iperf3_setup ;;
            2) _nodequality_setup ;;
            3) _speedtest_setup ;;
            4) _akdns_setup ;;
            5) _dns_manage ;;
            6) _ntrace_setup ;;
            0) return ;;
            *) _error_no_exit "无效选项: ${ch}"; sleep 1 ;;
        esac
    done
}

_virt_container_diagnose() {
    _header "环境诊断"

    _info "正在采集环境信息..."
    local virt_type="unknown"
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        virt_type=$(systemd-detect-virt)
    else
        # Fallbacks
        if grep -qaE '(docker|containerd|kubepods)' /proc/1/cgroup 2>/dev/null || [ -f /.dockerenv ]; then
            virt_type="docker"
        elif grep -qa 'container=lxc' /proc/1/environ 2>/dev/null || grep -qa 'lxc' /proc/1/cgroup 2>/dev/null; then
            virt_type="lxc"
        elif grep -qaE 'openvz' /proc/1/cgroup 2>/dev/null; then
            virt_type="openvz"
        elif grep -qiE '(qemu|kvm)' /sys/class/dmi/id/product_name 2>/dev/null || grep -qiE '(qemu|kvm)' /sys/class/dmi/id/sys_vendor 2>/dev/null; then
            virt_type="kvm"
        elif grep -q 'hypervisor' /proc/cpuinfo 2>/dev/null; then
            virt_type="vm"
        else
            virt_type="metal"
        fi
    fi

    # Display environment
    local env_display="物理机"
    case "$virt_type" in
        kvm|qemu) env_display="KVM 虚拟机" ;;
        lxc) env_display="LXC 容器" ;;
        docker) env_display="Docker 容器" ;;
        openvz) env_display="OpenVZ 容器" ;;
        vm) env_display="其他类型虚拟机" ;;
        none|metal) env_display="物理机" ;;
        *) env_display="未知环境 ($virt_type)" ;;
    esac

    _status_kv "运行环境" "$env_display" "green" 18

    # Common time sync status
    local time_sync_status="未启用"
    if _is_container_like; then
        if _has_time_privilege; then
            if _time_sync_is_enabled; then
                time_sync_status="已启用 (容器独立)"
                _status_kv "时间自动同步" "$time_sync_status" "green" 18
            else
                _status_kv "时间自动同步" "$time_sync_status" "yellow" 18
            fi
        else
            local host_sync="no"
            if command -v timedatectl >/dev/null 2>&1; then
                host_sync=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)
            fi
            if [ "$host_sync" = "yes" ]; then
                time_sync_status="已启用 (由宿主机同步)"
                _status_kv "时间自动同步" "$time_sync_status" "green" 18
            else
                time_sync_status="未启用 (受限，需在宿主机开启 NTP)"
                _status_kv "时间自动同步" "$time_sync_status" "yellow" 18
            fi
        fi
    else
        if _time_sync_is_enabled; then
            time_sync_status="已启用"
            _status_kv "时间自动同步" "$time_sync_status" "green" 18
        else
            _status_kv "时间自动同步" "$time_sync_status" "yellow" 18
        fi
    fi

    local current_time
    current_time=$(date "+%Y-%m-%d %H:%M:%S %Z")
    _status_kv "系统当前时间" "$current_time" "cyan" 18

    echo ""
    _separator

    # Diagnosing details based on env
    if [[ "$virt_type" == "kvm" || "$virt_type" == "qemu" || "$virt_type" == "vm" ]]; then
        _info "[ 虚拟机环境诊断结果 ]"
        
        # Clock source
        local clocksource="未知"
        if [ -f /sys/devices/system/clocksource/clocksource0/current_clocksource ]; then
            clocksource=$(cat /sys/devices/system/clocksource/clocksource0/current_clocksource 2>/dev/null)
        fi
        
        if [[ "$clocksource" == "kvm-clock" || "$clocksource" == "tsc" ]]; then
            _success "时钟源: ${clocksource} (推荐，运行高效且稳定)"
        else
            _warn "时钟源: ${clocksource} (不推荐。建议在 KVM 虚拟机中使用 kvm-clock 或 tsc 以降低虚拟化开销并避免时间漂移)"
        fi

        # Network interface driver
        local iface
        iface=$(_tcptune_guess_iface)
        if [[ -n "$iface" ]]; then
            local is_virtio=0
            if [ -d "/sys/class/net/${iface}/device" ]; then
                local driver_link
                driver_link=$(readlink "/sys/class/net/${iface}/device/driver" 2>/dev/null || true)
                if [[ "$driver_link" == *"virtio_net"* ]]; then
                    is_virtio=1
                fi
            fi

            if [[ "$is_virtio" -eq 1 ]]; then
                _success "网卡接口: ${iface} 使用 virtio_net 驱动 (已启用半虚拟化，性能优越)"
            else
                _warn "网卡接口: ${iface} 未使用 virtio_net 驱动。在 KVM 下运行仿真网卡（如 e1000/rtl8139）网络吞吐可能受到严重限制，建议联系服务商修改为 virtio 网卡"
            fi
        else
            _warn "网卡接口: 无法自动识别出口网卡"
        fi

    elif [[ "$virt_type" == "lxc" ]]; then
        _info "[ LXC 容器环境诊断结果 ]"

        # Privileged / Unprivileged
        local is_unprivileged=0
        if [ -f /proc/self/uid_map ]; then
            local first_uid_map host_uid_start
            first_uid_map=$(head -n 1 /proc/self/uid_map 2>/dev/null || true)
            host_uid_start=$(echo "$first_uid_map" | awk '{print $2}')
            if [[ -n "$host_uid_start" && "$host_uid_start" -ne 0 ]]; then
                is_unprivileged=1
            fi
        fi

        if [[ "$is_unprivileged" -eq 1 ]]; then
            _warn "特权级别: 非特权容器 (安全性较高，但 UID 映射使得磁盘顺序写/文件 I/O 存在约 30% 额外性能损耗，对于高频日志场景可考虑特权容器)"
        else
            _success "特权级别: 特权容器 (I/O 无额外损耗)"
        fi

        # Time Sync Privilege
        if ! _has_time_privilege; then
            _warn "时钟同步: 容器内无时间修改权限 (非特权/未放行 CAP_SYS_TIME)"
            _info "          -> 时间同步完全依赖宿主机，请确保宿主机 (如 PVE) 已开启 NTP 服务"
            _info "          -> 若确需在容器内运行 NTP 服务，需在宿主机配置文件中添加 'lxc.cap.keep: sys_time'"
        else
            _success "时钟同步: 容器内拥有时间修改权限"
        fi

        # Network mode
        local iface
        iface=$(_tcptune_guess_iface)
        if [[ -n "$iface" ]]; then
            local iface_info iface_type="veth"
            iface_info=$(ip -d link show "$iface" 2>/dev/null || true)
            if echo "$iface_info" | grep -qi 'macvlan'; then
                iface_type="macvlan"
            elif echo "$iface_info" | grep -qi 'ipvlan'; then
                iface_type="ipvlan"
            fi

            if [[ "$iface_type" == "macvlan" || "$iface_type" == "ipvlan" ]]; then
                _success "网卡模式: ${iface} 使用 ${iface_type} 模式 (已绕过虚拟网桥，网络吞吐接近物理网卡)"
            else
                _warn "网卡模式: ${iface} 疑似使用 veth 桥接模式 (存在额外的桥接转发和 NAT 性能损耗，对于高吞吐场景建议在宿主机更改为 macvlan/ipvlan 模式)"
            fi
        else
            _warn "网卡接口: 无法自动识别出口网卡"
        fi

    else
        _info "当前环境为物理机或无需特殊虚拟化诊断。"
    fi

    # Display timedatectl details if available
    if command -v timedatectl >/dev/null 2>&1; then
        echo ""
        _info "详细时间状态 (timedatectl):"
        timedatectl status | grep -E "NTP service|synchronized|Local time|Universal time" | sed 's/^/    /' || true
    fi

    echo ""
    _separator
    _menu_pair "1" "强制执行手动时间同步" "拉取最新的网络时间" "green" "2" "开启时间自动同步服务" "尝试安装/配置 ntpd/chrony" "yellow"
    _menu_item "0" "返回上级菜单" "" "red"
    _separator

    local ch
    read -rp "  选择 [0-2]: " ch
    case "$ch" in
        1)
            _time_sync_force_once
            _press_any_key
            ;;
        2)
            _time_sync_check_and_enable
            _press_any_key
            ;;
        0) return ;;
        *) _error_no_exit "无效选项: ${ch}"; sleep 1 ;;
    esac
}

_system_opt_menu_screen() {
    _header "系统相关"
    _menu_pair "1" "日志轮转" "限制 Docker 日志" "green" "2" "Swap 管理" "创建/删除 Swap" "green"
    _menu_pair "3" "Root SSH" "允许 root 登录" "green" "4" "SSH 密钥登录" "禁用密码登录" "green"
    _menu_pair "5" "SSH 端口" "快速修改 sshd 监听端口" "green" "6" "1Panel NAT 链" "挂载转发链" "green"
    _menu_pair "7" "环境诊断" "KVM/LXC 时钟及特权诊断" "green" "8" "LXC 容器(支持HE隧道)" "管理容器与 HE 隧道" "green"
    _menu_item "9" "宿主机 HE 隧道" "为宿主机配置与绑定 HE IPv6 隧道" "green"
    _separator
    _menu_item "0" "返回主菜单" "" "red"
    _separator
}

_system_opt_menu() {
    while true; do
        _ui_print_screen _system_opt_menu_screen
        local ch
        read -rp "  ${CYAN}➜${PLAIN}  选择 [0-9]: " ch
        case "$ch" in
            1) _dockerlog_setup ;;
            2) _swap_setup ;;
            3) _rootssh_enable ;;
            4) _ssh_force_key_login ;;
            5) _ssh_change_port ;;
            6) _onepanel_apply_iptables_chains ;;
            7) _virt_container_diagnose ;;
            8) _he_ipv6_lxc_menu ;;
            9) _he_host_tunnel_menu ;;
            0) return ;;
            *) _error_no_exit "无效选项: ${ch}"; sleep 1 ;;
        esac
    done
}

_proxy_cipher_speed_supports_quick() {
    local help
    command -v openssl >/dev/null 2>&1 || return 1
    help=$(openssl speed -help 2>&1 || true)
    [[ "$help" == *"-seconds"* && "$help" == *"-bytes"* && "$help" == *"-evp"* ]]
}

_proxy_cipher_speed_mbps() {
    local evp="$1" mode="${2:-enc}" out mbps
    local -a cmd=(openssl speed -elapsed -seconds 1 -bytes 16384 -evp "$evp" -mr)

    [[ "$mode" == "dec" ]] && cmd+=( -decrypt )
    out=$("${cmd[@]}" 2>&1) || return 1
    mbps=$(printf '%s\n' "$out" | awk -F: '
        /^\+F:/ {
            v=$NF
            if (v ~ /^[0-9.]+$/) {
                printf "%.1f", v / 1024 / 1024
                found=1
            }
        }
        END { if (!found) exit 1 }
    ') || return 1
    printf '%s' "$mbps"
}

_proxy_cipher_list_algorithms() {
    local out
    out=$(openssl list -cipher-algorithms 2>/dev/null || true)
    [[ -n "$out" ]] || out=$(openssl list-cipher-algorithms 2>/dev/null || true)
    [[ -n "$out" ]] || out=$(openssl enc -ciphers 2>/dev/null || true)
    printf '%s\n' "$out"
}

_proxy_cipher_available() {
    local evp="$1" list pattern
    list=$(_proxy_cipher_list_algorithms | tr '[:upper:]' '[:lower:]' 2>/dev/null || true)
    case "$evp" in
        chacha20-poly1305) pattern='chacha20-poly1305|chacha' ;;
        aes-128-gcm) pattern='aes-128-gcm|id-aes128-gcm' ;;
        aes-256-gcm) pattern='aes-256-gcm|id-aes256-gcm' ;;
        aes-128-ctr) pattern='aes-128-ctr|aes128' ;;
        aes-256-ctr) pattern='aes-256-ctr|aes256' ;;
        *) pattern="$evp" ;;
    esac
    printf '%s\n' "$list" | grep -Eiq "$pattern"
}

_proxy_cipher_benchmark() {
    _header "加密吞吐量测试"

    if ! command -v openssl >/dev/null 2>&1; then
        _warn "未检测到 openssl，尝试自动安装..."
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -qq >/dev/null 2>&1 || true
            apt-get install -y -qq openssl >/dev/null 2>&1 || true
        elif command -v yum >/dev/null 2>&1; then
            yum install -y openssl >/dev/null 2>&1 || true
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y openssl >/dev/null 2>&1 || true
        elif command -v apk >/dev/null 2>&1; then
            apk add --no-cache openssl >/dev/null 2>&1 || true
        fi
        if ! command -v openssl >/dev/null 2>&1; then
            _error_no_exit "未检测到 openssl，且自动安装失败，无法测试加密算法"
            _press_any_key
            return
        fi
        _success "openssl 安装成功"
    fi

    _info "OpenSSL: $(openssl version 2>/dev/null || echo unknown)"
    _info "测试说明: 默认每个算法加密 1 秒 + 解密 1 秒，结果仅作本机 CPU/库参考。"
    _separator
    _menu_pair "1" "快速测试" "3项，约6秒" "green" "2" "完整测试" "5项，约10秒" "green"
    _menu_item "0" "返回" "" "red"
    _separator

    local choice
    read -rp "  选择 [0-2，默认 1]: " choice
    choice="${choice:-1}"
    case "$choice" in
        0) return ;;
        1|2) ;;
        *) _error_no_exit "无效选项"; _press_any_key; return ;;
    esac

    local -a labels=(
        "chacha20-ietf-poly1305"
        "aes-128-gcm"
        "aes-256-gcm"
    )
    local -a evps=(
        "chacha20-poly1305"
        "aes-128-gcm"
        "aes-256-gcm"
    )
    if [[ "$choice" == "2" ]]; then
        labels+=("aes-128-ctr" "aes-256-ctr")
        evps+=("aes-128-ctr" "aes-256-ctr")
    fi

    echo ""
    if ! _proxy_cipher_speed_supports_quick; then
        _warn "当前 openssl speed 不支持 -seconds/-bytes 测试参数，为避免耗时，仅做可用性检测。"
        printf "    %-28s %-10s\n" "算法" "状态"
        _separator
        local i
        for i in "${!labels[@]}"; do
            if _proxy_cipher_available "${evps[$i]}"; then
                printf "    %-28s ${GREEN}可用${PLAIN}\n" "${labels[$i]}"
            else
                printf "    %-28s ${YELLOW}未检测到${PLAIN}\n" "${labels[$i]}"
            fi
        done
        _warn "SS2022 的 2022-blake3-aes-* 依赖 BLAKE3/实现库，openssl 测试无法准确代表。"
        _press_any_key
        return
    fi

    printf "    %-28s %-14s %-14s %-8s\n" "算法" "加密MB/s" "解密MB/s" "状态"
    _separator
    local i enc_mbps dec_mbps
    for i in "${!labels[@]}"; do
        enc_mbps=""
        dec_mbps=""
        if enc_mbps=$(_proxy_cipher_speed_mbps "${evps[$i]}" enc) \
            && dec_mbps=$(_proxy_cipher_speed_mbps "${evps[$i]}" dec); then
            printf "    %-28s %-14s %-14s ${GREEN}OK${PLAIN}\n" "${labels[$i]}" "$enc_mbps" "$dec_mbps"
        else
            printf "    %-28s %-14s %-14s ${YELLOW}不支持${PLAIN}\n" "${labels[$i]}" "-" "-"
        fi
    done
    _warn "实际速度取决于代理工具实现。"
    _press_any_key
}

_proxy_tools_menu_screen() {
    _header "代理工具"
    _menu_pair "1" "Mihomo" "安装/配置/日志" "green" "2" "Sing-Box" "安装/服务/日志" "green"
    _menu_pair "3" "Snell V5" "配置/导出/日志" "green" "4" "WireGuard" "部署/客户端/状态" "green"
    _menu_pair "5" "Shadowsocks-Rust" "配置/导出/日志" "green" "6" "Realm 转发" "端口转发管理" "green"
    _menu_item "7" "ACME 证书" "申请/续期证书" "green"
    _menu_item "8" "加密吞吐量测试" "常见加解密测试" "green"
    _menu_item "0" "返回主菜单" "" "red"
    _separator
}

_proxy_tools_menu() {
    while true; do
        _ui_print_screen _proxy_tools_menu_screen
        local ch
        read -rp "  ${CYAN}➜${PLAIN}  选择 [0-8]: " ch
        case "$ch" in
            1) _mihomo_manage ;;
            2) _singbox_manage ;;
            3) _snell_manage ;;
            4) _wireguard_manage ;;
            5) _ssrust_manage ;;
            6) _realm_manage ;;
            7) _acme_manage ;;
            8) _proxy_cipher_benchmark ;;
            0) return ;;
            *) _error_no_exit "无效选项: ${ch}"; sleep 1 ;;
        esac
    done
}

main() {
    [[ $EUID -ne 0 ]] && _error "此脚本需要 root 权限，请使用 sudo vpsgo 运行"

    _load_runtime_config
    _self_install

    while true; do
        _ui_print_screen _show_home_screen

        local choice
        read -rp "  ${CYAN}➜${PLAIN}  选择: " choice

        case "$choice" in
            1) _network_opt_menu ;;
            2) _script_tools_menu ;;
            3) _system_opt_menu ;;
            4) _proxy_tools_menu ;;
            g|G) _toggle_github_proxy ;;
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
