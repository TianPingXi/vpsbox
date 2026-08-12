#!/usr/bin/env bash
set -euo pipefail
umask 077

# ==============================================================================
# 源码导航
# ==============================================================================
# 0. 全局配置与运行时状态
# 1. 核心运行时：输出、输入、超时、进程、清理与实例锁
# 2. 平台适配与通用持久化：系统识别、启动更新探测、下载、依赖与变更记录
# 3. 节点与 sing-box：依赖、服务、监听检查、状态、配置、事务及版本更新
# 4. vpsbox 自更新发布与回滚事务
# 5. 系统优化与安全：BBR、IPv6、TCP、Fail2ban、NTP、DNS、SSH 与系统维护
# 6. 主机防火墙：端口发现、nftables、Docker 转发、回滚与菜单
# 7. 检测：一键检测
# 8. 维护、恢复与末端菜单动作
# 9. 菜单与交互
# 10. 程序入口
#
# vpsbox.sh 是唯一运行时源码；tests/ 通过 source 本文件并按场景替换部分函数与入口。
# 章节标题只描述当前职责边界，不代表已经拆分为可独立加载的模块。

# ==============================================================================
# 0. 全局配置与运行时状态
# ==============================================================================
# 产品、版本、受管路径和超时均在加载时确定，业务函数只读取这些配置。
APP_NAME="vpsbox"
VPSBOX_VERSION="v1.0.55"
# 只从当前仓库下载并识别可执行脚本。
SCRIPT_URL="https://raw.githubusercontent.com/TianPingXi/vpsbox/main/vpsbox.sh"
SINGBOX_RELEASE_VERSION="1.13.14"
REALITY_POOL_PROBE_TIMEOUT=3
REALITY_CLOUDFLARE_CHECK_TIMEOUT=3
REALITY_CLOUDFLARE_RESPONSE_LIMIT=65536
REALITY_PROBE_FALLBACK_SERVER_NAME="www.dell.com"
REALITY_SERVER_POOL=(
    "www.dell.com"
    "www.sony.com"
    "www.amd.com"
    "www.intel.com"
    "www.oracle.com"
    "www.nvidia.com"
    "www.samsung.com"
    "www.tesla.com"
)
CMD_PATH="/usr/local/bin/vpsbox"
CMD_ALIAS_PATH="/usr/bin/vpsbox"
CONFIG_DIR="/etc/sing-box"
# sing-box 软件包可能生成默认 config.json；vpsbox 节点只使用 vpsbox.d 独立配置。
URI_FILE="$CONFIG_DIR/vpsbox-uri.txt"
NODE_CONFIG_DIR="$CONFIG_DIR/vpsbox.d"
SS_CONFIG_PATH="$NODE_CONFIG_DIR/10-ss.json"
VLESS_CONFIG_PATH="$NODE_CONFIG_DIR/20-vless-reality.json"
SS_STATE_FILE="$CONFIG_DIR/vpsbox-ss.env"
VLESS_STATE_FILE="$CONFIG_DIR/vpsbox-vless.env"
SS_URI_FILE="$CONFIG_DIR/vpsbox-ss-uri.txt"
VLESS_URI_FILE="$CONFIG_DIR/vpsbox-vless-uri.txt"
BBR_CONF="/etc/sysctl.d/99-vpsbox-bbr.conf"
IPV6_DISABLE_CONF="/etc/sysctl.d/99-vpsbox-disable-ipv6.conf"
TCP_BUFFER_CONF="/etc/sysctl.d/99-vpsbox-tcp-buffer.conf"
TCP_BUFFER_TIER_1_MAX=8388608
TCP_BUFFER_TIER_2_MAX=16777216
TCP_BUFFER_TIER_3_MAX=33554432
JOURNALD_VPSBOX_CONF="/etc/systemd/journald.conf.d/99-vpsbox.conf"
VPSBOX_STATE_DIR="/etc/vpsbox"
# 独立于系统改动清单保存，卸载管理命令时继续保留。
INSTALL_METADATA_FILE="$VPSBOX_STATE_DIR/install.env"
CHANGE_MANIFEST="$VPSBOX_STATE_DIR/changes.env"
CHANGE_BACKUP_DIR="$VPSBOX_STATE_DIR/backups"
NODE_TRANSACTION_DIR="$VPSBOX_STATE_DIR/node-transaction"
NODE_TRANSACTION_BACKUP="$NODE_TRANSACTION_DIR/backup"
NODE_TRANSACTION_STAGE="$NODE_TRANSACTION_DIR/stage"
SINGBOX_UPDATE_TRANSACTION_DIR="$VPSBOX_STATE_DIR/singbox-update"
SINGBOX_UPDATE_TRANSACTION_STATE="$SINGBOX_UPDATE_TRANSACTION_DIR/state"
GAI_CONF="/etc/gai.conf"
RESOLV_CONF="/etc/resolv.conf"
NTP_SOURCES_BEGIN="# BEGIN VPSBOX NTP SOURCES"
NTP_SOURCES_END="# END VPSBOX NTP SOURCES"
CHRONY_SOURCE_FILE="/etc/chrony/sources.d/vpsbox.sources"
HOSTNAME_BEGIN="# BEGIN VPSBOX HOSTNAME"
HOSTNAME_END="# END VPSBOX HOSTNAME"
HOSTNAME_PATH="/etc/hostname"
HOSTS_PATH="/etc/hosts"
SSHD_MAIN_CONF="/etc/ssh/sshd_config"
SSHD_CONFIG_DIR="/etc/ssh/sshd_config.d"
SSHD_VPSBOX_PORT_CONF="$SSHD_CONFIG_DIR/00-vpsbox-ssh-port.conf"
# 仅用于 SSH 端口事务的快照与回滚；新版不再主动创建或更新该配置。
SSHD_VPSBOX_HARDENING_CONF="$SSHD_CONFIG_DIR/01-vpsbox-ssh-hardening.conf"
# SSH 端口修改流程维护的当前目标值；文件头只提供初始默认值。
SSH_TARGET_PORT="23333"
FAIL2BAN_CONFIG_DIR="/etc/fail2ban/jail.d"
FAIL2BAN_VPSBOX_SSHD_CONF="$FAIL2BAN_CONFIG_DIR/99-vpsbox-sshd.local"
FIREWALL_CONFIG="$VPSBOX_STATE_DIR/firewall.nft"
FIREWALL_STATE_FILE="$VPSBOX_STATE_DIR/firewall.env"
FIREWALL_SYSTEMD_UNIT="/etc/systemd/system/vpsbox-firewall.service"
FIREWALL_OPENRC_SERVICE="/etc/init.d/vpsbox-firewall"
FIREWALL_SERVICE_NAME="vpsbox-firewall"
FIREWALL_OPENRC_RUNLEVELS_DIR="/etc/runlevels"
FIREWALL_ROLLBACK_SECONDS=90
FIREWALL_ROLLBACK_DIR="$VPSBOX_STATE_DIR/firewall-rollbacks"
PACKAGE_CONNECT_TIMEOUT=15
PACKAGE_UPDATE_TIMEOUT=120
PACKAGE_INSTALL_TIMEOUT=600
SYSTEM_UPGRADE_TIMEOUT=7200
VPSBOX_UPDATE_PREPARE_TIMEOUT=60
VPSBOX_UPDATE_STARTUP_TIMEOUT=$((PACKAGE_INSTALL_TIMEOUT + 120))
PACKAGE_KILL_GRACE=10
PACKAGE_RETRY_MAX=2
PACKAGE_RETRY_DELAY=2

# 有界命令状态由 run_bounded_* / cleanup_active_bounded_command 独占维护；
# 任何退出路径都必须经统一清理，不能由业务函数直接复用这些字段。
ACTIVE_BOUNDED_PID=""
ACTIVE_BOUNDED_START=""
ACTIVE_BOUNDED_TIMER_PID=""
ACTIVE_BOUNDED_MARKER=""
ACTIVE_BOUNDED_PARENT_PID=""

# 实例锁状态由 acquire_lock 与 cleanup_vpsbox_runtime 管理。
RUNTIME_DIR="/run/vpsbox"
LOCK_FILE="$RUNTIME_DIR/vpsbox.lock"
LOCK_DIR="$RUNTIME_DIR/lockdir"
LOCK_RECLAIM_DIR="$RUNTIME_DIR/lockdir-reclaim"
LOCK_USING_FLOCK=0
LOCK_USING_DIR=0

# ACTIVE_* 是各操作域的进程内生命周期句柄。所属节点、防火墙、SSH、NTP、DNS、
# Fail2ban 或 sing-box 更新流程负责写入。统一退出清理可以先接管并清空句柄再调用
# 对应恢复入口，也可以在操作完成后清空；失败后的保留与提示策略由各领域清理函数负责。
ACTIVE_NODE_BACKUP=""
ACTIVE_NODE_TRANSACTION_MUTATED=0
ACTIVE_FIREWALL_TRANSITION_DIR=""
ACTIVE_SSH_FIREWALL_TRANSITION=0
ACTIVE_SSH_TRANSACTION_DIR=""
ACTIVE_SSH_ORIGINAL_PORTS=""
ACTIVE_SSH_TRANSACTION_HAS_PORT_CHANGE=0
ACTIVE_SSH_FAIL2BAN_INSTALLED=0
ACTIVE_SSH_FAIL2BAN_WAS_RUNNING=0
ACTIVE_SSH_FAIL2BAN_MUTATED=0
ACTIVE_FIREWALL_ROLLBACK_DIR=""
ACTIVE_FIREWALL_ADDITIVE_DIR=""
ACTIVE_FAIL2BAN_TEST_IP=""
ACTIVE_FAIL2BAN_TEST_BACKENDS=""
ACTIVE_FAIL2BAN_SYNC_BACKUP=""
ACTIVE_FAIL2BAN_SYNC_WAS_RUNNING=""
ACTIVE_DNS_OPERATION_NAME=""
ACTIVE_DNS_OPERATION_SNAPSHOT=""
ACTIVE_DNS_OPERATION_TARGET=""
ACTIVE_DNS_OPERATION_CREATED=0
ACTIVE_DNS_OPERATION_APPLIED_BEFORE=0
ACTIVE_NTP_SNAPSHOT=""
ACTIVE_NTP_ROLLBACK_ARGS=()
ACTIVE_NTP_SERVICE_ROLLBACK=0
ACTIVE_NTP_SERVICE_ROLLBACK_ARGS=()
ACTIVE_NTP_TRACKING_CANCEL=0
ACTIVE_IPV6_REENABLE_SNAPSHOT=""
ACTIVE_IPV6_REENABLE_OLD_VALUES=""
ACTIVE_SINGBOX_UPDATE_BINARY=""
ACTIVE_SINGBOX_UPDATE_BACKUP=""
ACTIVE_SINGBOX_UPDATE_DIR=""
ACTIVE_SINGBOX_UPDATE_PACKAGE=""
ACTIVE_SINGBOX_UPDATE_OLD_VERSION=""
ACTIVE_SINGBOX_UPDATE_WAS_ENABLED=0
ACTIVE_SINGBOX_UPDATE_WAS_ACTIVE=0
ACTIVE_SINGBOX_UPDATE_MUTATED=0
ACTIVE_SINGBOX_UPDATE_ROLLING_BACK=0

# sing-box 与节点默认值；load_state_file 会把最近一次成功加载的节点字段写入全局变量。
SERVICE_NAME="sing-box"
SS_METHOD="2022-blake3-aes-128-gcm"
METHOD="$SS_METHOD"
PORT_MIN=10000
PORT_MAX=60000

# vpsbox 自更新握手状态由检查、watchdog 与新进程启动确认流程共同维护。
REMOTE_VERSION=""
UPDATE_AVAILABLE=0
PENDING_VPSBOX_UPDATE_BACKUP="${VPSBOX_UPDATE_BACKUP:-}"
PENDING_VPSBOX_UPDATE_READY_FILE="${VPSBOX_UPDATE_READY_FILE:-}"
VPSBOX_UPDATE_STARTUP_CONFIRMED=0
VPSBOX_UPDATE_WATCHDOG_PID=""
VPSBOX_UPDATE_WATCHDOG_DIR=""

# FW_* 是防火墙模块的一次内存快照：先由加载/探测函数重置并填充，
# 再由计算、展示和渲染函数消费，不应跨两次防火墙操作缓存。
FW_EXTRA_TCP=""
FW_EXTRA_UDP=""
FW_SSH_PORTS=""
FW_NODE_TCP=""
FW_NODE_UDP=""
FW_PUBLIC_TCP=""
FW_PUBLIC_UDP=""
FW_OTHER_PUBLIC_TCP=""
FW_OTHER_PUBLIC_UDP=""
FW_DOCKER_TCP=""
FW_DOCKER_UDP=""
FW_DOCKER_PUBLIC_TCP=""
FW_DOCKER_PUBLIC_UDP=""
FW_DOCKER_PUBLIC4_TCP=""
FW_DOCKER_PUBLIC4_UDP=""
FW_DOCKER_PUBLIC6_TCP=""
FW_DOCKER_PUBLIC6_UDP=""
FW_DOCKER_PROXY4_TCP=""
FW_DOCKER_PROXY4_UDP=""
FW_DOCKER_PROXY6_TCP=""
FW_DOCKER_PROXY6_UDP=""
FW_DOCKER_BRIDGES=""
FW_DOCKER_DAEMON_PID=""
FW_DOCKER_DAEMON_START_TICKS=""
FW_DOCKER_HOST_NETWORK=0
FW_DOCKER_DYNAMIC_PORT=0
FW_DOCKER_DIRECT_NETWORK=0
FW_DOCKER_CUSTOM_BRIDGE=0
FW_DOCKER_STOPPED_IGNORED=0
FW_ALLOWED_TCP=""
FW_ALLOWED_UDP=""

# ==============================================================================
# 1. 核心运行时：输出、输入、超时、进程、清理与实例锁
# ==============================================================================
info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }

confirm_default_yes() {
    local prompt="$1" answer
    while true; do
        read -r -p "$prompt [Y/n]: " answer || return 1
        case "$answer" in
            ""|Y|y) return 0 ;;
            N|n) return 1 ;;
            *) warn "请输入 y 或 n；直接回车默认 y。" ;;
        esac
    done
}

confirm_default_no() {
    local prompt="$1" answer
    while true; do
        read -r -p "$prompt [y/N]: " answer || return 1
        case "$answer" in
            Y|y) return 0 ;;
            ""|N|n) return 1 ;;
            *) warn "请输入 y 或 n；直接回车默认 n。" ;;
        esac
    done
}

retry() {
    local max="$1"
    local delay="$2"
    local attempt=1
    local status=0

    shift 2

    while [ "$attempt" -le "$max" ]; do
        if "$@"; then
            return 0
        else
            status=$?
        fi

        if [ "$attempt" -ge "$max" ]; then
            err "命令重试 ${max} 次后仍失败：$*"
            return "$status"
        fi

        warn "命令失败，${delay} 秒后重试（${attempt}/${max}）：$*"
        sleep "$delay"
        attempt=$((attempt + 1))
    done
}

run_bounded_in_new_session() {
    local limit="$1" marker pid start="" timer timer_sleep="" status marker_state i

    shift
    marker="$(mktemp /tmp/vpsbox-command-timeout.XXXXXX)" || return 1
    printf '%s\n' pending > "$marker"
    ACTIVE_BOUNDED_MARKER="$marker"
    ACTIVE_BOUNDED_PARENT_PID="${BASHPID:-$$}"
    # 后台命令必须关闭菜单锁描述符；否则父菜单被 SIGKILL 后，子进程会继续占用 flock。
    setsid "$@" 200>&- &
    pid=$!
    ACTIVE_BOUNDED_PID="$pid"

    for i in {1..50}; do
        if ! process_alive "$pid" || process_is_zombie "$pid"; then
            if wait "$pid"; then status=0; else status=$?; fi
            if [ "$status" -ne 0 ] && bounded_session_has_processes "$pid"; then
                terminate_bounded_session "$pid" 1
            fi
            clear_active_bounded_state
            rm -f -- "$marker"
            return "$status"
        fi
        start="$(process_start_ticks "$pid" || true)"
        if [[ "$start" =~ ^[0-9]+$ ]] && bounded_process_group_matches "$pid" "$start"; then
            break
        fi
        start=""
        sleep 0.02
    done
    if [ -z "$start" ]; then
        kill -TERM "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        clear_active_bounded_state
        rm -f -- "$marker"
        err "无法为命令建立独立进程组，已取消执行：$1"
        return 125
    fi

    ACTIVE_BOUNDED_START="$start"
    (
        trap '
            if is_pid "$timer_sleep"; then
                kill -TERM "$timer_sleep" 2>/dev/null || true
                wait "$timer_sleep" 2>/dev/null || true
            fi
            exit 0
        ' HUP INT TERM
        sleep "$limit" &
        timer_sleep=$!
        if ! wait "$timer_sleep"; then
            exit 0
        fi
        timer_sleep=""
        trap - HUP INT TERM
        if bounded_process_group_matches "$pid" "$start"; then
            printf '%s\n' timeout > "$marker"
            terminate_bounded_session "$pid" "$PACKAGE_KILL_GRACE"
        fi
    ) </dev/null >/dev/null 2>&1 200>&- &
    timer=$!
    ACTIVE_BOUNDED_TIMER_PID="$timer"

    if wait "$pid"; then status=0; else status=$?; fi
    marker_state="$(cat "$marker" 2>/dev/null || true)"
    if [ "$marker_state" = "timeout" ]; then
        wait "$timer" 2>/dev/null || true
        status=124
    else
        kill -TERM "$timer" 2>/dev/null || true
        wait "$timer" 2>/dev/null || true
        if [ "$status" -ne 0 ] && bounded_session_has_processes "$pid"; then
            terminate_bounded_session "$pid" 1
        fi
    fi

    clear_active_bounded_state
    rm -f -- "$marker"
    return "$status"
}

run_bounded_with_timeout() {
    local limit="$1" status

    shift
    if timeout -k 1 1 true 200>&- >/dev/null 2>&1; then
        if timeout -k "$PACKAGE_KILL_GRACE" "$limit" "$@" 200>&-; then return 0; else status=$?; fi
    else
        # 兼容 BusyBox 1.35 之前不支持 timeout -k 的版本；旧 Alpine 仍可能使用该实现，
        # 因此保留普通 timeout 回退。两条 timeout 路径都必须关闭 FD 200，避免旧系统
        # 在父菜单异常退出后由包管理子进程继续占用 vpsbox 菜单锁。
        warn "当前 timeout 不支持强制终止延迟，使用兼容模式。"
        if timeout "$limit" "$@" 200>&-; then return 0; else status=$?; fi
    fi
    return "$status"
}

run_bounded_command() {
    local limit="$1" status

    shift
    [[ "$limit" =~ ^[1-9][0-9]*$ ]] && [ "$#" -gt 0 ] || return 2
    if command -v setsid >/dev/null 2>&1; then
        if run_bounded_in_new_session "$limit" "$@"; then return 0; else status=$?; fi
    elif command -v timeout >/dev/null 2>&1; then
        if run_bounded_with_timeout "$limit" "$@"; then return 0; else status=$?; fi
    else
        err "缺少 setsid/timeout，已拒绝执行无时限命令：$1"
        return 127
    fi
    case "$status" in
        124|137|143)
            err "命令执行超时或被强制终止（上限 ${limit} 秒）：$1"
            ;;
    esac
    return "$status"
}

retry_bounded_command() {
    local max="$1" delay="$2" limit="$3"
    local attempt=1 status=0

    shift 3
    while [ "$attempt" -le "$max" ]; do
        if run_bounded_command "$limit" "$@"; then
            return 0
        else
            status=$?
        fi
        case "$status" in
            124|125|126|127|137|143) return "$status" ;;
        esac
        if [ "$attempt" -ge "$max" ]; then
            err "命令重试 ${max} 次后仍失败：$*"
            return "$status"
        fi
        warn "命令失败，${delay} 秒后重试（${attempt}/${max}）：$*"
        sleep "$delay"
        attempt=$((attempt + 1))
    done
}

apt_get_bounded() {
    local limit="$1"

    shift
    retry_bounded_command "$PACKAGE_RETRY_MAX" "$PACKAGE_RETRY_DELAY" "$limit" \
        apt-get \
        -o "Acquire::Retries=1" \
        -o "Acquire::http::Timeout=$PACKAGE_CONNECT_TIMEOUT" \
        -o "Acquire::https::Timeout=$PACKAGE_CONNECT_TIMEOUT" \
        -o "Dpkg::Lock::Timeout=$PACKAGE_CONNECT_TIMEOUT" \
        "$@"
}

apk_bounded() {
    local limit="$1"

    shift
    retry_bounded_command "$PACKAGE_RETRY_MAX" "$PACKAGE_RETRY_DELAY" "$limit" apk "$@"
}

dnf_bounded() {
    local limit="$1"

    shift
    retry_bounded_command "$PACKAGE_RETRY_MAX" "$PACKAGE_RETRY_DELAY" "$limit" \
        dnf --setopt="timeout=$PACKAGE_CONNECT_TIMEOUT" --setopt="retries=1" "$@"
}

yum_bounded() {
    local limit="$1"

    shift
    retry_bounded_command "$PACKAGE_RETRY_MAX" "$PACKAGE_RETRY_DELAY" "$limit" \
        yum --setopt="timeout=$PACKAGE_CONNECT_TIMEOUT" --setopt="retries=1" "$@"
}

pause() {
    echo ""
    read -r -p "按回车返回当前菜单..." _ || exit 0
}

run_menu_action() {
    local status
    if "$@"; then
        return 0
    else
        status=$?
    fi
    warn "操作未完成（退出码：$status），已保留当前菜单。"
    return 0
}

need_root() {
    if [ "$(id -u)" != "0" ]; then
        err "请使用 root 用户运行。"
        exit 1
    fi
}

prepare_runtime_dir() {
    if [ -L "$RUNTIME_DIR" ]; then
        err "$RUNTIME_DIR 是符号链接，已拒绝使用。"
        exit 1
    fi

    if ! mkdir -p "$RUNTIME_DIR"; then
        err "无法创建运行目录：$RUNTIME_DIR"
        exit 1
    fi

    if ! chown root:root "$RUNTIME_DIR" 2>/dev/null ||
        ! chmod 700 "$RUNTIME_DIR" 2>/dev/null; then
        err "无法保护运行目录：$RUNTIME_DIR"
        exit 1
    fi
}

is_pid() {
    [[ "${1:-}" =~ ^[0-9]+$ ]]
}

process_alive() {
    local pid="$1"

    is_pid "$pid" && kill -0 "$pid" 2>/dev/null
}

lock_metadata_value() {
    local path="$1" key="$2"
    [ -f "$path" ] || return 1
    awk -F= -v key="$key" '$1 == key { print $2; exit }' "$path" 2>/dev/null
}

process_start_ticks() {
    local pid="$1" stat
    stat="$(cat "/proc/$pid/stat" 2>/dev/null)" || return 1
    stat="${stat##*) }"
    printf '%s\n' "$stat" | awk '{print $20}'
}

process_is_zombie() {
    local pid="$1" stat

    stat="$(cat "/proc/$pid/stat" 2>/dev/null)" || return 1
    stat="${stat##*) }"
    [ "${stat%% *}" = "Z" ]
}

process_group_session_ids() {
    local pid="$1" stat _state _ppid pgrp session

    stat="$(cat "/proc/$pid/stat" 2>/dev/null)" || return 1
    stat="${stat##*) }"
    read -r _state _ppid pgrp session _ <<< "$stat"
    [[ "$pgrp" =~ ^[0-9]+$ && "$session" =~ ^[0-9]+$ ]] || return 1
    printf '%s %s\n' "$pgrp" "$session"
}

bounded_process_group_identity_matches() {
    local pid="$1" expected_start="$2" ids

    process_alive "$pid" || return 1
    [ "$(process_start_ticks "$pid" 2>/dev/null || true)" = "$expected_start" ] || return 1
    ids="$(process_group_session_ids "$pid" || true)"
    [ "$ids" = "$pid $pid" ]
}

bounded_process_group_matches() {
    local pid="$1" expected_start="$2"

    bounded_process_group_identity_matches "$pid" "$expected_start" || return 1
    ! process_is_zombie "$pid"
}

bounded_session_has_processes() {
    local session="$1" stat_path stat _state _ppid _pgrp sid

    for stat_path in /proc/[0-9]*/stat; do
        [ -r "$stat_path" ] || continue
        stat="$(cat "$stat_path" 2>/dev/null || true)"
        [ -n "$stat" ] || continue
        stat="${stat##*) }"
        read -r _state _ppid _pgrp sid _ <<< "$stat"
        [ "$sid" = "$session" ] && return 0
    done
    return 1
}

bounded_session_signal() {
    local session="$1" signal="$2" stat_path stat _state _ppid _pgrp sid pid leader_matches=0

    case "$signal" in TERM|KILL) ;; *) return 2 ;; esac
    # 会话成员只能由该命令派生；先通知子进程，最后通知会话 leader。
    for stat_path in /proc/[0-9]*/stat; do
        [ -r "$stat_path" ] || continue
        pid="${stat_path#/proc/}"
        pid="${pid%/stat}"
        [ "$pid" != "$$" ] && [ "$pid" -gt 1 ] || continue
        stat="$(cat "$stat_path" 2>/dev/null || true)"
        [ -n "$stat" ] || continue
        stat="${stat##*) }"
        read -r _state _ppid _pgrp sid _ <<< "$stat"
        [ "$sid" = "$session" ] || continue
        if [ "$pid" = "$session" ]; then
            leader_matches=1
            continue
        fi
        kill "-$signal" "$pid" 2>/dev/null || true
    done
    if [ "$leader_matches" -eq 1 ]; then
        kill "-$signal" "$session" 2>/dev/null || true
    fi
}

terminate_bounded_session() {
    local session="$1" grace="$2" i loops

    bounded_session_signal "$session" TERM
    loops=$((grace * 10))
    [ "$loops" -gt 0 ] || loops=1
    for ((i = 0; i < loops; i++)); do
        bounded_session_has_processes "$session" || return 0
        sleep 0.1
    done
    if bounded_session_has_processes "$session"; then
        bounded_session_signal "$session" KILL
    fi
}

bounded_process_group_is_direct_child() {
    local pid="$1" expected_parent="$2" stat _state ppid pgrp session

    stat="$(cat "/proc/$pid/stat" 2>/dev/null)" || return 1
    stat="${stat##*) }"
    read -r _state ppid pgrp session _ <<< "$stat"
    [ "$ppid" = "$expected_parent" ] && [ "$pgrp" = "$pid" ] && [ "$session" = "$pid" ]
}

clear_active_bounded_state() {
    ACTIVE_BOUNDED_PID=""
    ACTIVE_BOUNDED_START=""
    ACTIVE_BOUNDED_TIMER_PID=""
    ACTIVE_BOUNDED_MARKER=""
    ACTIVE_BOUNDED_PARENT_PID=""
}

cleanup_active_bounded_command() {
    local pid="${ACTIVE_BOUNDED_PID:-}" start="${ACTIVE_BOUNDED_START:-}"
    local timer="${ACTIVE_BOUNDED_TIMER_PID:-}" marker="${ACTIVE_BOUNDED_MARKER:-}"
    local parent="${ACTIVE_BOUNDED_PARENT_PID:-}" provisional_start=""

    clear_active_bounded_state
    if is_pid "$timer"; then
        kill -TERM "$timer" 2>/dev/null || true
        wait "$timer" 2>/dev/null || true
    fi
    if is_pid "$pid" && [[ "$start" =~ ^[0-9]+$ ]] &&
        { bounded_process_group_identity_matches "$pid" "$start" ||
            { ! process_alive "$pid" && bounded_session_has_processes "$pid"; }; }; then
        terminate_bounded_session "$pid" 1
        wait "$pid" 2>/dev/null || true
    elif is_pid "$pid" && is_pid "$parent" &&
        bounded_process_group_is_direct_child "$pid" "$parent"; then
        provisional_start="$(process_start_ticks "$pid" 2>/dev/null || true)"
        if [[ "$provisional_start" =~ ^[0-9]+$ ]] &&
            bounded_process_group_identity_matches "$pid" "$provisional_start"; then
            terminate_bounded_session "$pid" 1
            wait "$pid" 2>/dev/null || true
        fi
    fi
    if [[ "$marker" == /tmp/vpsbox-command-timeout.* ]] && [ -f "$marker" ] && [ ! -L "$marker" ]; then
        rm -f -- "$marker"
    fi
}

process_stdin_tty() {
    local pid="$1" tty
    tty="$(readlink "/proc/$pid/fd/0" 2>/dev/null || true)"
    case "$tty" in
        /dev/pts/*|/dev/tty*) [ -c "$tty" ] && printf '%s\n' "$tty" ;;
    esac
}

process_identity_matches() {
    local pid="$1" recorded_start="$2" recorded_boot="$3"
    local current_start current_boot

    process_alive "$pid" || return 1
    current_start="$(process_start_ticks "$pid" || true)"
    current_boot="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"
    [[ "$recorded_start" =~ ^[0-9]+$ ]] && [ "$recorded_start" = "$current_start" ] &&
        [ -n "$recorded_boot" ] && [ "$recorded_boot" = "$current_boot" ]
}

old_menu_lost_terminal() {
    local pid="$1" recorded_start="$2" recorded_boot="$3"

    process_identity_matches "$pid" "$recorded_start" "$recorded_boot" || return 1
    [ -z "$(process_stdin_tty "$pid")" ]
}

terminate_orphaned_vpsbox_menu() {
    local pid="$1" recorded_start="$2" recorded_boot="$3" i

    process_identity_matches "$pid" "$recorded_start" "$recorded_boot" || return 1
    warn "检测到失去终端的旧 vpsbox 菜单（PID $pid），正在自动回收锁。"
    process_identity_matches "$pid" "$recorded_start" "$recorded_boot" || return 1
    kill -TERM "$pid" 2>/dev/null || return 1
    for i in 1 2 3 4 5; do
        process_identity_matches "$pid" "$recorded_start" "$recorded_boot" || return 0
        sleep 1
    done
    process_identity_matches "$pid" "$recorded_start" "$recorded_boot" || return 0
    kill -KILL "$pid" 2>/dev/null || return 1
    sleep 1
    ! process_identity_matches "$pid" "$recorded_start" "$recorded_boot"
}

cleanup_vpsbox_lock() {
    if [ "$LOCK_USING_FLOCK" = "1" ]; then
        if [ -f "$LOCK_FILE" ] && [ ! -L "$LOCK_FILE" ]; then
            : > "$LOCK_FILE"
        fi
        flock -u 200 2>/dev/null || true
        exec 200>&-
        LOCK_USING_FLOCK=0
    fi
    if [ "$LOCK_USING_DIR" = "1" ] && [ -d "$LOCK_DIR" ] && [ ! -L "$LOCK_DIR" ]; then
        rm -rf "$LOCK_DIR"
        LOCK_USING_DIR=0
    fi
}

cleanup_vpsbox_runtime() {
    local backup="${ACTIVE_NODE_BACKUP:-}"
    local firewall_rollback="${ACTIVE_FIREWALL_ROLLBACK_DIR:-}"
    local firewall_additive="${ACTIVE_FIREWALL_ADDITIVE_DIR:-}"
    if declare -F cleanup_active_bounded_command >/dev/null 2>&1; then
        cleanup_active_bounded_command
    fi
    if { [ -n "${ACTIVE_NTP_SNAPSHOT:-}" ] ||
        [ "${ACTIVE_NTP_SERVICE_ROLLBACK:-0}" = "1" ] ||
        [ "${ACTIVE_NTP_TRACKING_CANCEL:-0}" = "1" ]; } &&
        declare -F rollback_active_ntp_operation >/dev/null 2>&1; then
        rollback_active_ntp_operation ||
            warn "NTP 操作被中断，首次恢复记录清理或原状态恢复未能完整完成。"
    fi
    if [ -n "${ACTIVE_IPV6_REENABLE_SNAPSHOT:-}" ] &&
        declare -F rollback_active_untracked_ipv6_reenable >/dev/null 2>&1; then
        rollback_active_untracked_ipv6_reenable ||
            warn "IPv6 重新启用被中断，配置或运行参数未能完整恢复；临时快照已保留。"
    fi
    if declare -F rollback_active_singbox_update >/dev/null 2>&1; then
        rollback_active_singbox_update ||
            warn "sing-box 更新被中断，旧版本或原服务状态未能完整恢复；更新备份已保留。"
    fi
    if [ "$backup" = "$NODE_TRANSACTION_DIR" ] && [ -d "$backup" ]; then
        if declare -F rollback_active_node_transaction >/dev/null 2>&1; then
            rollback_active_node_transaction ||
                warn "节点操作被中断，自动恢复未完成；事务备份已保留：$NODE_TRANSACTION_DIR"
        elif declare -F restore_node_files >/dev/null 2>&1; then
            ACTIVE_NODE_BACKUP=""
            restore_node_files "$NODE_TRANSACTION_BACKUP" ||
                warn "节点操作被中断，自动恢复未完成；事务备份已保留：$NODE_TRANSACTION_DIR"
        fi
    fi
    if [ -n "${ACTIVE_SSH_TRANSACTION_DIR:-}" ] &&
        declare -F rollback_active_ssh_transaction >/dev/null 2>&1; then
        rollback_active_ssh_transaction ||
            warn "SSH 操作被中断，配置、监听、Fail2ban 或防火墙未能完整恢复；运行期快照已保留。"
    fi
    if [ "${ACTIVE_SSH_FIREWALL_TRANSITION:-0}" = "1" ] &&
        declare -F ssh_firewall_transition_reconcile >/dev/null 2>&1; then
        ssh_firewall_transition_reconcile ||
            warn "SSH 端口切换被中断，无法自动对账；临时放行规则已保留，请重新进入防火墙菜单更新。"
    fi
    if [ "${ACTIVE_SSH_FIREWALL_TRANSITION:-0}" != "1" ] &&
        declare -F firewall_abort_port_transition >/dev/null 2>&1; then
        firewall_abort_port_transition ||
            warn "端口切换被中断，防火墙临时规则恢复失败，请重新进入防火墙菜单更新。"
    fi
    if [ -n "$firewall_additive" ] &&
        declare -F firewall_additive_transaction_dir_valid >/dev/null 2>&1 &&
        firewall_additive_transaction_dir_valid "$firewall_additive" &&
        declare -F firewall_restore_additive_transaction >/dev/null 2>&1; then
        if [ -e "$firewall_additive/committed" ]; then
            ACTIVE_FIREWALL_ADDITIVE_DIR=""
            rm -rf -- "$firewall_additive" ||
                warn "新增防火墙端口已提交，但轻量事务残留未能清理：$firewall_additive"
        else
            firewall_restore_additive_transaction "$firewall_additive" ||
                warn "新增防火墙端口操作被中断，配置恢复失败；轻量事务已保留：$firewall_additive"
        fi
    fi
    if declare -F firewall_rollback_dir_valid >/dev/null 2>&1 &&
        firewall_rollback_dir_valid "$firewall_rollback" &&
        [ -d "$firewall_rollback" ] && [ ! -L "$firewall_rollback" ] &&
        declare -F firewall_restore_snapshot_now >/dev/null 2>&1; then
        if [ -e "$firewall_rollback/completed" ]; then
            ACTIVE_FIREWALL_ROLLBACK_DIR=""
            if declare -F firewall_cleanup_finished_rollback >/dev/null 2>&1; then
                firewall_cleanup_finished_rollback "$firewall_rollback" ||
                    warn "防火墙规则已提交，但回滚进程清理尚未完成：$firewall_rollback"
            else
                rm -rf "$firewall_rollback"
            fi
        elif [ "$(cat "$firewall_rollback/decision" 2>/dev/null || true)" = "commit" ]; then
            firewall_restore_snapshot_now "$firewall_rollback" 1 ||
                warn "防火墙操作被中断，自动恢复失败；快照已保留：$firewall_rollback"
        else
            firewall_restore_snapshot_now "$firewall_rollback" 0 ||
                warn "防火墙操作被中断，自动恢复失败；快照已保留：$firewall_rollback"
        fi
    fi
    if declare -F cleanup_active_fail2ban_test >/dev/null 2>&1; then
        cleanup_active_fail2ban_test ||
            warn "Fail2ban 测试地址自动解封失败，请按错误提示手动清理。"
    fi
    if declare -F cleanup_active_fail2ban_sync >/dev/null 2>&1; then
        cleanup_active_fail2ban_sync ||
            warn "Fail2ban 同步被中断，配置或原服务状态未能完整恢复；恢复依据已保留。"
    fi
    if [ -n "${ACTIVE_DNS_OPERATION_NAME:-}" ] &&
        declare -F rollback_active_dns_operation >/dev/null 2>&1; then
        rollback_active_dns_operation ||
            warn "DNS 修改被中断，配置或服务状态未能完整恢复；临时快照已保留。"
    fi
    cleanup_vpsbox_lock
    if declare -F rollback_pending_vpsbox_update >/dev/null 2>&1; then
        rollback_pending_vpsbox_update ||
            warn "新版 vpsbox 启动失败，旧版脚本未能自动恢复，请检查 ${CMD_PATH}.previous。"
    fi
}

install_lock_cleanup_traps() {
    trap cleanup_vpsbox_runtime EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 131' QUIT
}

read_lock_owner_snapshot() {
    local path="$1" pid_var="$2" start_var="$3" boot_var="$4"
    local snapshot_pid="" snapshot_start="" snapshot_boot=""

    if [ -f "$path" ]; then
        snapshot_pid="$(lock_metadata_value "$path" pid || true)"
        snapshot_start="$(lock_metadata_value "$path" start_ticks || true)"
        snapshot_boot="$(lock_metadata_value "$path" boot_id || true)"
    fi
    printf -v "$pid_var" '%s' "$snapshot_pid"
    printf -v "$start_var" '%s' "$snapshot_start"
    printf -v "$boot_var" '%s' "$snapshot_boot"
    is_pid "$snapshot_pid" && [[ "$snapshot_start" =~ ^[0-9]+$ ]] &&
        [ -n "$snapshot_boot" ]
}

show_process_summary() {
    local pid="$1"

    if process_alive "$pid"; then
        ps -p "$pid" -o pid=,tty=,etime=,cmd= 2>/dev/null || true
    fi
}

terminate_old_vpsbox_menu() {
    local pid="$1" recorded_start="$2" recorded_boot="$3"
    local confirm
    local i

    if ! process_identity_matches "$pid" "$recorded_start" "$recorded_boot"; then
        return 1
    fi

    warn "检测到旧 vpsbox 菜单仍在运行："
    show_process_summary "$pid"
    echo ""
    if ! read -r -p "输入 YES 结束旧菜单并继续，其他任意输入取消: " confirm; then
        err "输入已结束，未终止旧 vpsbox 菜单。"
        exit 1
    fi
    if [ "$confirm" != "YES" ]; then
        err "检测到另一个 vpsbox 正在运行，请先退出旧菜单。"
        exit 1
    fi

    if ! process_identity_matches "$pid" "$recorded_start" "$recorded_boot"; then
        err "旧菜单进程身份已变化，已拒绝终止该 PID。"
        return 1
    fi
    kill -TERM "$pid" 2>/dev/null || true
    for i in 1 2 3 4 5; do
        process_identity_matches "$pid" "$recorded_start" "$recorded_boot" || return 0
        sleep 1
    done

    process_identity_matches "$pid" "$recorded_start" "$recorded_boot" || return 0
    warn "旧菜单未正常退出，正在强制结束。"
    kill -KILL "$pid" 2>/dev/null || true
    sleep 1
    process_identity_matches "$pid" "$recorded_start" "$recorded_boot" && return 1 || return 0
}

write_flock_metadata() {
    : > "$LOCK_FILE"
    {
        printf 'pid=%s\n' "$$"
        printf 'start_ticks=%s\n' "$(process_start_ticks "$$" || true)"
        printf 'boot_id=%s\n' "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"
        printf 'tty=%s\n' "$(process_stdin_tty "$$" || true)"
        printf 'started=%s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    } >&200
}

write_lockdir_metadata() {
    {
        printf 'pid=%s\n' "$$"
        printf 'start_ticks=%s\n' "$(process_start_ticks "$$" || true)"
        printf 'boot_id=%s\n' "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"
        printf 'tty=%s\n' "$(process_stdin_tty "$$" || true)"
        printf 'started=%s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    } > "$LOCK_DIR/pid"
}

wait_for_lockdir_metadata() {
    local i

    # mkdir 是原子的，但创建者在写入 pid 元数据前存在极短窗口；等待后再判断残留，
    # 避免没有 flock 的系统上两个并发菜单互相删除刚创建的有效锁。
    for i in {1..10}; do
        [ -s "$LOCK_DIR/pid" ] && return 0
        [ -d "$LOCK_DIR" ] && [ ! -L "$LOCK_DIR" ] || return 1
        sleep 0.1
    done
    [ -s "$LOCK_DIR/pid" ]
}

lockdir_reclaim_owner_matches() {
    local path="$LOCK_RECLAIM_DIR/owner" pid start boot

    [ -f "$path" ] && [ ! -L "$path" ] || return 1
    pid="$(awk -F= '$1 == "pid" { print $2; exit }' "$path" 2>/dev/null || true)"
    start="$(awk -F= '$1 == "start_ticks" { print $2; exit }' "$path" 2>/dev/null || true)"
    boot="$(awk -F= '$1 == "boot_id" { print $2; exit }' "$path" 2>/dev/null || true)"
    is_pid "$pid" && [[ "$start" =~ ^[0-9]+$ ]] && [ -n "$boot" ] || return 1
    process_alive "$pid" &&
        [ "$(process_start_ticks "$pid" 2>/dev/null || true)" = "$start" ] &&
        [ "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)" = "$boot" ]
}

lockdir_reclaim_owned_by_self() {
    local pid self_pid="$BASHPID"

    pid="$(awk -F= '$1 == "pid" { print $2; exit }' "$LOCK_RECLAIM_DIR/owner" 2>/dev/null || true)"
    [ "$pid" = "$self_pid" ] && lockdir_reclaim_owner_matches
}

write_lockdir_reclaim_metadata() {
    local self_pid="$BASHPID" tmp="${LOCK_RECLAIM_DIR}.owner.$BASHPID"

    rm -f -- "$tmp"
    if ! {
        printf 'pid=%s\n' "$self_pid"
        printf 'start_ticks=%s\n' "$(process_start_ticks "$self_pid" || true)"
        printf 'boot_id=%s\n' "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"
    } > "$tmp" ||
        ! chmod 600 "$tmp" ||
        ! mv -f -- "$tmp" "$LOCK_RECLAIM_DIR/owner"; then
        rm -f -- "$tmp"
        return 1
    fi
}

acquire_lockdir_reclaim_guard() {
    local i

    for i in {1..30}; do
        if mkdir "$LOCK_RECLAIM_DIR" 2>/dev/null; then
            if write_lockdir_reclaim_metadata; then
                return 0
            fi
            rm -rf -- "$LOCK_RECLAIM_DIR"
            return 1
        fi
        if [ -L "$LOCK_RECLAIM_DIR" ] ||
            { [ -e "$LOCK_RECLAIM_DIR" ] && [ ! -d "$LOCK_RECLAIM_DIR" ]; }; then
            return 1
        fi
        # 创建者写 owner 前有极短窗口；先等待，再只回收已确认没有存活持有者的目录。
        if [ ! -s "$LOCK_RECLAIM_DIR/owner" ]; then
            sleep 0.1
            continue
        fi
        lockdir_reclaim_owner_matches || {
            rm -rf -- "$LOCK_RECLAIM_DIR"
            continue
        }
        sleep 0.1
    done
    # 创建者若在写 owner 前被 SIGKILL，会留下空回收目录。rmdir 只会删除空目录；
    # 若另一个存活创建者已写入元数据则原子失败，不会误删有效保护。
    if [ -d "$LOCK_RECLAIM_DIR" ] && [ ! -L "$LOCK_RECLAIM_DIR" ] &&
        [ ! -e "$LOCK_RECLAIM_DIR/owner" ] &&
        rmdir -- "$LOCK_RECLAIM_DIR" 2>/dev/null &&
        mkdir "$LOCK_RECLAIM_DIR" 2>/dev/null; then
        if write_lockdir_reclaim_metadata; then
            return 0
        fi
        rm -rf -- "$LOCK_RECLAIM_DIR"
    fi
    return 1
}

release_lockdir_reclaim_guard() {
    if lockdir_reclaim_owned_by_self; then
        rm -f -- "$LOCK_RECLAIM_DIR/owner"
        rmdir -- "$LOCK_RECLAIM_DIR" 2>/dev/null || true
    fi
}

activate_lockdir_lock() {
    write_lockdir_metadata || {
        rm -rf -- "$LOCK_DIR"
        return 1
    }
    LOCK_USING_DIR=1
    install_lock_cleanup_traps
}

acquire_lock() {
    local old_pid="" old_start="" old_boot="" snapshot_valid=0
    local reclaim_guard=0

    prepare_runtime_dir

    if command -v flock >/dev/null 2>&1; then
        [ ! -L "$LOCK_FILE" ] || { err "$LOCK_FILE 是符号链接，已拒绝使用。"; exit 1; }
        exec 200<>"$LOCK_FILE"
        if flock -n 200; then
            LOCK_USING_FLOCK=1
            write_flock_metadata
            install_lock_cleanup_traps
            return 0
        fi

        snapshot_valid=0
        read_lock_owner_snapshot "$LOCK_FILE" old_pid old_start old_boot && snapshot_valid=1
        if [ "$snapshot_valid" -ne 1 ] ||
            ! process_identity_matches "$old_pid" "$old_start" "$old_boot"; then
            err "vpsbox 锁元数据不完整或进程身份不匹配，已拒绝猜测或终止进程。请先退出旧菜单；必要时重启 VPS。"
            exit 1
        fi
        if old_menu_lost_terminal "$old_pid" "$old_start" "$old_boot" &&
            terminate_orphaned_vpsbox_menu "$old_pid" "$old_start" "$old_boot"; then
            if flock -n 200; then
                LOCK_USING_FLOCK=1
                write_flock_metadata
                install_lock_cleanup_traps
                return 0
            fi
        fi
        if terminate_old_vpsbox_menu "$old_pid" "$old_start" "$old_boot"; then
            if flock -n 200; then
                LOCK_USING_FLOCK=1
                write_flock_metadata
                install_lock_cleanup_traps
                return 0
            fi
            err "旧菜单已处理，但锁仍被占用，请稍后重试。"
            exit 1
        fi

        err "检测到另一个 vpsbox 正在运行，请先退出旧菜单。"
        exit 1
    fi

    if [ -L "$LOCK_DIR" ] || { [ -e "$LOCK_DIR" ] && [ ! -d "$LOCK_DIR" ]; }; then
        err "$LOCK_DIR 不是安全的锁目录，已拒绝使用。"
        exit 1
    fi

    acquire_lockdir_reclaim_guard || {
        err "无法取得 vpsbox 锁回收保护，请稍后重试。"
        exit 1
    }
    reclaim_guard=1
    # 无 flock 时，首次创建和残留锁回收都必须在同一保护内完成，避免锁目录已创建、
    # 元数据尚未写入时被并发进程误判为残留锁。
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        activate_lockdir_lock || {
            release_lockdir_reclaim_guard
            err "vpsbox 锁元数据写入失败。"
            exit 1
        }
        release_lockdir_reclaim_guard
        return
    fi
    if [ -L "$LOCK_DIR" ] || { [ -e "$LOCK_DIR" ] && [ ! -d "$LOCK_DIR" ]; }; then
        release_lockdir_reclaim_guard
        err "$LOCK_DIR 不是安全的锁目录，已拒绝使用。"
        exit 1
    fi

    wait_for_lockdir_metadata || true
    snapshot_valid=0
    read_lock_owner_snapshot "$LOCK_DIR/pid" old_pid old_start old_boot && snapshot_valid=1
    if ! is_pid "$old_pid"; then
        release_lockdir_reclaim_guard
        err "vpsbox 锁元数据缺少有效 PID，已拒绝猜测、终止进程或清理锁目录。请先退出旧菜单；必要时重启 VPS。"
        exit 1
    fi
    if ! process_alive "$old_pid"; then
        warn "检测到残留 vpsbox 锁，正在清理。"
        rm -rf -- "$LOCK_DIR"
    elif [ "$snapshot_valid" -ne 1 ] ||
        ! process_identity_matches "$old_pid" "$old_start" "$old_boot"; then
        release_lockdir_reclaim_guard
        err "vpsbox 锁元数据不完整或进程身份不匹配，已拒绝终止进程或清理锁目录。请先退出旧菜单；必要时重启 VPS。"
        exit 1
    elif old_menu_lost_terminal "$old_pid" "$old_start" "$old_boot" &&
        terminate_orphaned_vpsbox_menu "$old_pid" "$old_start" "$old_boot"; then
        rm -rf -- "$LOCK_DIR"
    elif terminate_old_vpsbox_menu "$old_pid" "$old_start" "$old_boot"; then
        rm -rf -- "$LOCK_DIR"
    else
        release_lockdir_reclaim_guard
        err "检测到另一个 vpsbox 正在运行，请先退出旧菜单。"
        exit 1
    fi

    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        release_lockdir_reclaim_guard
        err "检测到另一个 vpsbox 正在运行，请先退出旧菜单。"
        exit 1
    fi
    activate_lockdir_lock || {
        release_lockdir_reclaim_guard
        err "vpsbox 锁元数据写入失败。"
        exit 1
    }
    [ "$reclaim_guard" = "1" ] && release_lockdir_reclaim_guard
}

# ==============================================================================
# 2. 平台适配与通用持久化：系统识别、启动更新探测、下载、依赖与变更记录
# ==============================================================================
detect_os() {
    local os_release_values=""

    OS="unknown"
    OS_ID=""
    OS_ID_LIKE=""

    if [ -f /etc/os-release ]; then
        os_release_values="$(
            # shellcheck disable=SC1091
            . /etc/os-release || exit 1
            printf '%s\034%s' "${ID:-}" "${ID_LIKE:-}"
        )" || os_release_values=""
        IFS=$'\034' read -r OS_ID OS_ID_LIKE <<< "$os_release_values"
    fi

    if echo "$OS_ID $OS_ID_LIKE" | grep -qi "alpine"; then
        OS="alpine"
    elif echo "$OS_ID $OS_ID_LIKE" | grep -Eqi "debian|ubuntu"; then
        OS="debian"
    elif echo "$OS_ID $OS_ID_LIKE" | grep -Eqi "centos|rhel|fedora|rocky|almalinux"; then
        OS="redhat"
    fi
}

is_systemd() {
    command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

ensure_public_config_dir() {
    local dir="$1" managed_file="${2:-}" mode owner group

    [ ! -L "$dir" ] || {
        err "服务配置目录是符号链接，已拒绝修改：$dir"
        return 1
    }
    if [ ! -e "$dir" ]; then
        mkdir -p -- "$dir" || return 1
        chown root:root "$dir" || return 1
        chmod 755 "$dir" || return 1
        return 0
    fi
    [ -d "$dir" ] || return 1
    owner="$(stat -c '%u' "$dir" 2>/dev/null)" || return 1
    group="$(stat -c '%g' "$dir" 2>/dev/null)" || return 1
    mode="$(stat -c '%a' "$dir" 2>/dev/null)" || return 1
    [ "$owner" = "0" ] && [ "$group" = "0" ] || {
        err "服务配置目录不是 root:root，已拒绝修改：$dir"
        return 1
    }
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    [ $((8#$mode & 8#022)) -eq 0 ] || {
        err "服务配置目录允许非 root 用户写入，已拒绝使用：$dir"
        return 1
    }
    if [ $((8#$mode & 8#005)) -eq 5 ]; then
        return 0
    fi
    [ -n "$managed_file" ] && [ -f "$managed_file" ] && [ ! -L "$managed_file" ] &&
        [ "$(stat -c '%u:%g' "$managed_file" 2>/dev/null || true)" = "0:0" ] || {
        err "既有服务配置目录不可公开读取，且无法确认由 vpsbox 创建：$dir"
        return 1
    }
    chmod 755 "$dir"
}

atomic_staging_dir() {
    local target="$1" staging_dir target_parent staging_device target_device

    target_parent="$(dirname "$target")" || return 1
    staging_dir="$target_parent"
    case "$target" in
        "$NODE_CONFIG_DIR"/*)
            staging_dir="$CONFIG_DIR"
            [ -d "$NODE_CONFIG_DIR" ] && [ ! -L "$NODE_CONFIG_DIR" ] || return 1
            [ -d "$staging_dir" ] && [ ! -L "$staging_dir" ] || return 1
            staging_device="$(stat -c '%d' "$staging_dir" 2>/dev/null)" || return 1
            target_device="$(stat -c '%d' "$NODE_CONFIG_DIR" 2>/dev/null)" || return 1
            [ "$staging_device" = "$target_device" ] || {
                err "节点配置目录与安全临时目录不在同一文件系统，已拒绝非原子替换。"
                return 1
            }
            ;;
    esac
    printf '%s\n' "$staging_dir"
}

install_root_file_atomically() {
    local source="$1" target="$2" mode="${3:-644}"
    local parent tmp

    [ -f "$source" ] && [ ! -L "$source" ] || return 1
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    [ ! -L "$target" ] || return 1
    if [ -e "$target" ] && [ ! -f "$target" ]; then
        return 1
    fi
    parent="$(atomic_staging_dir "$target")" || return 1
    [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
    command -v mktemp >/dev/null 2>&1 || return 1
    tmp="$(mktemp "$parent/.vpsbox-publish.XXXXXX")" || return 1
    if ! cp -- "$source" "$tmp" ||
        ! chown root:root "$tmp" ||
        ! chmod "$mode" "$tmp" ||
        ! mv -f -- "$tmp" "$target"; then
        rm -f -- "$tmp"
        return 1
    fi
}

restore_file_atomically_from_snapshot() {
    local snapshot="$1" target="$2" parent tmp

    [ -f "$snapshot" ] && [ ! -L "$snapshot" ] || return 1
    # mv 会把“指向目录的符号链接”当作目标目录；此处明确拒绝，避免把
    # 临时恢复文件移入链接指向的目录后仍误报成功。
    if [ -L "$target" ]; then
        [ ! -d "$target" ] || return 1
    elif [ -e "$target" ] && [ ! -f "$target" ]; then
        return 1
    fi
    parent="$(atomic_staging_dir "$target")" || return 1
    [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
    command -v mktemp >/dev/null 2>&1 || return 1
    tmp="$(mktemp "$parent/.vpsbox-restore.XXXXXX")" || return 1
    # 在同一文件系统的安全目录中准备副本再 rename，恢复过程中不会把目标文件直接截断。
    if ! cp -a -- "$snapshot" "$tmp" ||
        ! mv -f -- "$tmp" "$target"; then
        rm -f -- "$tmp"
        return 1
    fi
}

remove_snapshot_target_file() {
    local target="$1"

    if [ -e "$target" ] && [ ! -f "$target" ] && [ ! -L "$target" ]; then
        return 1
    fi
    rm -f -- "$target"
}

restore_root_file_snapshot() {
    local snapshot="$1" target="$2" was_present="$3"
    local mode

    if [ "$was_present" = "1" ]; then
        [ -f "$snapshot" ] && [ ! -L "$snapshot" ] || return 1
        mode="$(stat -c '%a' "$snapshot" 2>/dev/null)" || return 1
        install_root_file_atomically "$snapshot" "$target" "$mode"
    else
        [ ! -L "$target" ] || return 1
        if [ -e "$target" ] && [ ! -f "$target" ]; then
            return 1
        fi
        remove_snapshot_target_file "$target"
    fi
}

install_command_alias() {
    local alias_target

    if [ ! -f "$CMD_PATH" ] || [ -L "$CMD_PATH" ]; then
        err "管理命令文件不存在或不安全：$CMD_PATH"
        return 1
    fi
    if [ -d "$CMD_ALIAS_PATH" ]; then
        err "管理命令入口是目录或指向目录，已拒绝覆盖：$CMD_ALIAS_PATH"
        return 1
    fi
    chmod 755 "$CMD_PATH" || {
        err "无法设置管理命令权限：$CMD_PATH"
        return 1
    }
    ln -sf "$CMD_PATH" "$CMD_ALIAS_PATH" || {
        err "无法创建命令入口：$CMD_ALIAS_PATH"
        return 1
    }
    alias_target="$(readlink "$CMD_ALIAS_PATH" 2>/dev/null || true)"
    if [ ! -L "$CMD_ALIAS_PATH" ] || [ "$alias_target" != "$CMD_PATH" ]; then
        err "管理命令入口创建后校验失败：$CMD_ALIAS_PATH"
        return 1
    fi
}

ensure_curl() {
    if command -v curl >/dev/null 2>&1; then
        return 0
    fi

    info "未检测到 curl，正在安装依赖..."
    install_deps

    if command -v curl >/dev/null 2>&1; then
        return 0
    fi

    err "未找到 curl，无法继续。"
    return 1
}

vpsbox_script_identity_valid() {
    local script="$1"

    [ -f "$script" ] && [ ! -L "$script" ] || return 1
    grep -Fqx 'APP_NAME="vpsbox"' "$script" || return 1
    grep -Fqx "SCRIPT_URL=\"$SCRIPT_URL\"" "$script" || return 1
    grep -Fqx 'vpsbox_main() {' "$script" || return 1
    grep -Fqx 'if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then' "$script" || return 1
    grep -Fqx '    vpsbox_main "$@"' "$script" || return 1
}

fetch_vpsbox_script_once() {
    local dest="$1" connect_timeout="$2" max_time="$3"

    rm -f -- "$dest"
    if curl -fsSL --connect-timeout "$connect_timeout" --max-time "$max_time" \
        "$SCRIPT_URL" -o "$dest"; then
        return 0
    fi
    rm -f -- "$dest"
    return 1
}

download_vpsbox_script() {
    local dest="$1"
    local require_newer="${2:-0}"
    local tmp
    local downloaded_version

    ensure_curl || return 1

    mkdir -p "$(dirname "$dest")" || return 1
    command -v mktemp >/dev/null 2>&1 || {
        err "未找到 mktemp，无法安全创建下载临时文件。"
        return 1
    }
    tmp="$(mktemp "${dest}.tmp.XXXXXX")" || return 1

    if ! retry 3 2 fetch_vpsbox_script_once "$tmp" 8 180; then
        rm -f "$tmp"
        err "GitHub Raw 下载失败，请检查网络后重试。"
        return 1
    fi

    if ! bash -n "$tmp"; then
        rm -f "$tmp"
        err "下载到的脚本未通过语法检查，已保留当前版本。"
        return 1
    fi

    if ! downloaded_version="$(vpsbox_script_version_from_file "$tmp")"; then
        rm -f "$tmp"
        err "下载到的脚本版本声明不唯一或格式无效，已保留当前版本。"
        return 1
    fi
    if ! vpsbox_script_identity_valid "$tmp"; then
        rm -f "$tmp"
        err "下载到的脚本缺少 vpsbox 项目标识或必要入口，已保留当前版本。"
        return 1
    fi
    if [ "$require_newer" = "1" ]; then
        case "$(version_relation "$downloaded_version" "$VPSBOX_VERSION")" in
            newer) ;;
            same)
                rm -f "$tmp"
                return 2
                ;;
            older)
                rm -f "$tmp"
                warn "远程版本 $downloaded_version 低于当前版本 $VPSBOX_VERSION，已拒绝降级。"
                return 3
                ;;
            *)
                rm -f "$tmp"
                err "无法比较远程版本 $downloaded_version 与当前版本 $VPSBOX_VERSION。"
                return 1
                ;;
        esac
    fi

    chmod 755 "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
}

version_is_newer() {
    local candidate="${1#v}"
    local current="${2#v}"
    local candidate_part
    local current_part
    local i
    local -a candidate_parts
    local -a current_parts

    IFS=. read -r -a candidate_parts <<< "$candidate"
    IFS=. read -r -a current_parts <<< "$current"

    for i in 0 1 2; do
        candidate_part="${candidate_parts[$i]:-0}"
        current_part="${current_parts[$i]:-0}"
        [[ "$candidate_part" =~ ^[0-9]+$ ]] || return 1
        [[ "$current_part" =~ ^[0-9]+$ ]] || return 1
        if ((10#$candidate_part > 10#$current_part)); then
            return 0
        fi
        if ((10#$candidate_part < 10#$current_part)); then
            return 1
        fi
    done

    return 1
}

version_relation() {
    local candidate="$1"
    local current="$2"

    [[ "$candidate" =~ ^v?[0-9]+([.][0-9]+){2}$ ]] || return 1
    [[ "$current" =~ ^v?[0-9]+([.][0-9]+){2}$ ]] || return 1

    if version_is_newer "$candidate" "$current"; then
        printf '%s\n' newer
    elif version_is_newer "$current" "$candidate"; then
        printf '%s\n' older
    else
        printf '%s\n' same
    fi
}

# ------------------------------------------------------------------------------
# vpsbox 启动更新探测；发布、启动确认与回滚见第 4 节
# ------------------------------------------------------------------------------
check_vpsbox_update_on_start() {
    local src
    local current_path
    local installed_path
    local tmp
    local remote_version

    [ -t 0 ] && [ -t 1 ] || return 0
    command -v curl >/dev/null 2>&1 || return 0

    src="${BASH_SOURCE[0]:-$0}"
    current_path="$(readlink -f "$src" 2>/dev/null || printf '%s\n' "$src")"
    installed_path="$(readlink -f "$CMD_PATH" 2>/dev/null || printf '%s\n' "$CMD_PATH")"
    [ "$current_path" = "$installed_path" ] || return 0
    [ -f "$CMD_PATH" ] || return 0

    tmp="$(mktemp "$RUNTIME_DIR/update-check.XXXXXX")" || return 0
    if ! fetch_vpsbox_script_once "$tmp" 3 8 >/dev/null 2>&1; then
        rm -f "$tmp"
        return 0
    fi

    remote_version="$(sed -n 's/^VPSBOX_VERSION="\([^"]*\)"$/\1/p' "$tmp" | head -n 1)"
    rm -f "$tmp"
    [[ "$remote_version" =~ ^v[0-9]+([.][0-9]+){2}$ ]] || return 0

    REMOTE_VERSION="$remote_version"
    if version_is_newer "$REMOTE_VERSION" "$VPSBOX_VERSION"; then
        UPDATE_AVAILABLE=1
    fi
}

auto_update_vpsbox_on_start() {
    [ "$UPDATE_AVAILABLE" -eq 1 ] || return 0

    info "发现新版本 $REMOTE_VERSION，正在自动更新..."
    if update_vpsbox; then
        return 0
    fi

    warn "自动更新失败，继续使用当前版本；可稍后使用菜单 00 重试。"
    return 0
}

vpsbox_update_notice() {
    if [ "$UPDATE_AVAILABLE" -eq 1 ]; then
        printf ' 新版本：%s（自动更新失败，请使用菜单 00 重试）\n' "$REMOTE_VERSION"
    fi
}

github_release_asset() {
    local repo="$1" tag="$2" asset="$3" api url digest

    ensure_curl || return 1
    command -v jq >/dev/null 2>&1 || { err "未找到 jq，无法校验 GitHub Release 资产。"; return 1; }
    api="https://api.github.com/repos/$repo/releases/tags/$tag"
    if ! api="$(curl -fsSL --connect-timeout 8 --max-time 30 "$api")"; then
        err "无法读取 $repo 的 Release 元数据：$tag"
        return 1
    fi
    url="$(printf '%s' "$api" | jq -r --arg asset "$asset" '.assets[] | select(.name == $asset) | .browser_download_url' | head -n 1)"
    digest="$(printf '%s' "$api" | jq -r --arg asset "$asset" '.assets[] | select(.name == $asset) | .digest' | head -n 1)"
    [[ "$url" =~ ^https://github.com/ ]] || { err "未找到 Release 资产：$asset"; return 1; }
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { err "Release 未提供有效 SHA256：$asset"; return 1; }
    printf '%s\n%s\n' "$url" "$digest"
}

download_verified_github_asset() {
    local repo="$1" tag="$2" asset="$3" dest="$4"
    local metadata url digest actual

    metadata="$(github_release_asset "$repo" "$tag" "$asset")" || return 1
    url="$(printf '%s\n' "$metadata" | sed -n '1p')"
    digest="$(printf '%s\n' "$metadata" | sed -n '2p')"
    if ! retry 3 2 curl -fL --connect-timeout 8 --max-time 180 "$url" -o "$dest"; then
        rm -f "$dest"
        return 1
    fi
    actual="sha256:$(sha256sum "$dest" | awk '{print $1}')"
    if [ "$actual" != "$digest" ]; then
        rm -f "$dest"
        err "SHA256 校验失败：$asset"
        return 1
    fi
}

singbox_release_package_arch() {
    local machine

    case "$OS" in
        debian)
            command -v dpkg >/dev/null 2>&1 || return 1
            dpkg --print-architecture
            ;;
        alpine)
            command -v apk >/dev/null 2>&1 || return 1
            apk --print-arch
            ;;
        redhat)
            machine="$(uname -m)" || return 1
            case "$machine" in
                amd64) printf '%s\n' x86_64 ;;
                arm64) printf '%s\n' aarch64 ;;
                armv7|armv7l) printf '%s\n' armv7hl ;;
                armv6|armv6l) printf '%s\n' armv6hl ;;
                i386|i486|i586|i686) printf '%s\n' i386 ;;
                ppc64el) printf '%s\n' ppc64le ;;
                mips64le) printf '%s\n' mips64el ;;
                x86_64|aarch64|armv7hl|armv6hl|loongarch64|mips64el|mipsel|ppc64le|riscv64|s390x)
                    printf '%s\n' "$machine"
                    ;;
                *)
                    err "当前 RedHat 架构没有对应的 sing-box RPM：$machine"
                    return 1
                    ;;
            esac
            ;;
        *) return 1 ;;
    esac
}

run_singbox_installer() {
    local version="${1:-$SINGBOX_RELEASE_VERSION}"
    local arch suffix asset tmp_dir tmp

    [[ "$version" =~ ^[0-9]+([.][0-9]+){2}$ ]] || { err "sing-box 版本格式无效：$version"; return 1; }

    detect_os
    case "$OS" in
        debian) suffix="deb" ;;
        alpine) suffix="apk" ;;
        redhat) suffix="rpm" ;;
        *) err "当前系统不支持 sing-box 固定 Release 安装。"; return 1 ;;
    esac
    arch="$(singbox_release_package_arch)" || return 1
    asset="sing-box_${version}_linux_${arch}.${suffix}"
    tmp_dir="$(mktemp -d /tmp/vpsbox-sing-box-release.XXXXXX)" || return 1
    tmp="$tmp_dir/$asset"
    info "正在下载并校验 sing-box v$version（$asset）..."
    if ! download_verified_github_asset "SagerNet/sing-box" "v$version" "$asset" "$tmp"; then
        rm -rf "$tmp_dir"
        return 1
    fi
    case "$OS" in
        debian)
            run_bounded_command "$PACKAGE_INSTALL_TIMEOUT" \
                env DEBIAN_FRONTEND=noninteractive \
                dpkg --force-confdef --force-confold --install "$tmp" ||
                { rm -rf "$tmp_dir"; return 1; }
            ;;
        alpine) apk_bounded "$PACKAGE_INSTALL_TIMEOUT" add --allow-untrusted "$tmp" || { rm -rf "$tmp_dir"; return 1; } ;;
        redhat)
            if command -v dnf >/dev/null 2>&1; then
                dnf_bounded "$PACKAGE_INSTALL_TIMEOUT" install -y "$tmp"
            else
                yum_bounded "$PACKAGE_INSTALL_TIMEOUT" install -y "$tmp"
            fi || { rm -rf "$tmp_dir"; return 1; }
            ;;
    esac
    rm -rf "$tmp_dir"
    return 0
}

singbox_binary_is_package_managed() {
    local binary_path="$1" owner

    binary_path="$(readlink -f -- "$binary_path" 2>/dev/null || printf '%s' "$binary_path")"
    detect_os
    case "$OS" in
        debian)
            command -v dpkg-query >/dev/null 2>&1 || return 1
            owner="$(dpkg-query -S "$binary_path" 2>/dev/null | awk -F: 'NR == 1 { print $1 }')"
            [[ "$owner" =~ ^sing-box(:[^:]+)?$ ]]
            ;;
        alpine)
            command -v apk >/dev/null 2>&1 || return 1
            apk info --who-owns "$binary_path" 2>/dev/null | grep -Eq ' owned by sing-box-[^[:space:]]+$'
            ;;
        redhat)
            command -v rpm >/dev/null 2>&1 || return 1
            [ "$(rpm -qf --queryformat '%{NAME}\n' "$binary_path" 2>/dev/null || true)" = "sing-box" ]
            ;;
        *) return 1 ;;
    esac
}

prepare_singbox_rollback_package() {
    local version="$1" backup_dir="$2"
    local arch suffix asset package

    [[ "$version" =~ ^[0-9]+([.][0-9]+){2}$ ]] || return 1
    detect_os
    case "$OS" in
        debian) suffix="deb" ;;
        alpine) suffix="apk" ;;
        redhat) suffix="rpm" ;;
        *) return 1 ;;
    esac
    arch="$(singbox_release_package_arch)" || return 1
    asset="sing-box_${version}_linux_${arch}.${suffix}"
    package="$backup_dir/$asset"
    download_verified_github_asset "SagerNet/sing-box" "v$version" "$asset" "$package" || return 1
    printf '%s\n' "$package"
}

install_singbox_package_file() {
    local package="$1"

    [ -f "$package" ] && [ ! -L "$package" ] || return 1
    detect_os
    case "$OS" in
        debian)
            run_bounded_command "$PACKAGE_INSTALL_TIMEOUT" \
                env DEBIAN_FRONTEND=noninteractive \
                dpkg --force-confdef --force-confold --install "$package"
            ;;
        alpine)
            apk_bounded "$PACKAGE_INSTALL_TIMEOUT" add --allow-untrusted "$package"
            ;;
        redhat)
            run_bounded_command "$PACKAGE_INSTALL_TIMEOUT" \
                rpm -Uvh --oldpackage --replacepkgs "$package"
            ;;
        *) return 1 ;;
    esac
}

vpsbox_script_version_from_file() {
    local script="$1"
    local declaration version

    [ -f "$script" ] && [ ! -L "$script" ] || return 1
    declaration="$(
        awk '
            /^[[:space:]]*((export|readonly|local)[[:space:]]+|(declare|typeset)([[:space:]]+-[^[:space:]]+)*[[:space:]]+)?VPSBOX_VERSION[[:space:]]*=/ {
                print
            }
        ' "$script"
    )" || return 1
    [ -n "$declaration" ] &&
        [[ "$declaration" != *$'\n'* ]] &&
        [[ "$declaration" =~ ^VPSBOX_VERSION=\"v[0-9]+([.][0-9]+){2}\"$ ]] ||
        return 1
    version="${declaration#VPSBOX_VERSION=\"}"
    version="${version%\"}"
    printf '%s\n' "$version"
}

install_metadata_values_valid() {
    local version="$1" installed_at="$2"

    if [ "$version" = "unknown" ] || [ "$installed_at" = "unknown" ]; then
        [ "$version" = "unknown" ] && [ "$installed_at" = "unknown" ]
        return
    fi
    [[ "$version" =~ ^v[0-9]+([.][0-9]+){2}$ ]] &&
        [[ "$installed_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

install_metadata_read() {
    local owner mode line value
    local version="" installed_at=""
    local seen_version=0 seen_at=0

    [ -d "$VPSBOX_STATE_DIR" ] && [ ! -L "$VPSBOX_STATE_DIR" ] || return 1
    owner="$(stat -c '%u:%g' "$VPSBOX_STATE_DIR" 2>/dev/null)" || return 1
    mode="$(stat -c '%a' "$VPSBOX_STATE_DIR" 2>/dev/null)" || return 1
    [ "$owner" = "0:0" ] && [ "$mode" = "700" ] || return 1

    [ -f "$INSTALL_METADATA_FILE" ] && [ ! -L "$INSTALL_METADATA_FILE" ] || return 1
    owner="$(stat -c '%u:%g' "$INSTALL_METADATA_FILE" 2>/dev/null)" || return 1
    mode="$(stat -c '%a' "$INSTALL_METADATA_FILE" 2>/dev/null)" || return 1
    [ "$owner" = "0:0" ] && [ "$mode" = "600" ] || return 1

    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            FIRST_INSTALLED_VERSION=*)
                [ "$seen_version" -eq 0 ] || return 1
                value="${line#FIRST_INSTALLED_VERSION=}"
                version="$value"
                seen_version=1
                ;;
            FIRST_INSTALLED_AT=*)
                [ "$seen_at" -eq 0 ] || return 1
                value="${line#FIRST_INSTALLED_AT=}"
                installed_at="$value"
                seen_at=1
                ;;
            *)
                return 1
                ;;
        esac
    done < "$INSTALL_METADATA_FILE"

    [ "$seen_version" -eq 1 ] && [ "$seen_at" -eq 1 ] || return 1
    install_metadata_values_valid "$version" "$installed_at" || return 1
    printf '%s\n%s\n' "$version" "$installed_at"
}

prepare_install_metadata_dir() {
    if [ -L "$VPSBOX_STATE_DIR" ]; then
        return 1
    fi
    if [ -e "$VPSBOX_STATE_DIR" ] && [ ! -d "$VPSBOX_STATE_DIR" ]; then
        return 1
    fi
    mkdir -p "$VPSBOX_STATE_DIR" || return 1
    chown root:root "$VPSBOX_STATE_DIR" || return 1
    chmod 700 "$VPSBOX_STATE_DIR" || return 1
}

install_metadata_write_once() {
    local version="$1" installed_at="$2"
    local tmp

    install_metadata_values_valid "$version" "$installed_at" || return 1
    if [ -e "$INSTALL_METADATA_FILE" ] || [ -L "$INSTALL_METADATA_FILE" ]; then
        install_metadata_read >/dev/null
        return
    fi

    prepare_install_metadata_dir || return 1
    if [ -e "$INSTALL_METADATA_FILE" ] || [ -L "$INSTALL_METADATA_FILE" ]; then
        install_metadata_read >/dev/null
        return
    fi
    command -v mktemp >/dev/null 2>&1 || return 1
    tmp="$(mktemp "$VPSBOX_STATE_DIR/.install.env.XXXXXX")" || return 1
    if ! printf '%s\n' \
        "FIRST_INSTALLED_VERSION=$version" \
        "FIRST_INSTALLED_AT=$installed_at" > "$tmp" ||
        ! chown root:root "$tmp" ||
        ! chmod 600 "$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi

    # 以同目录硬链接原子发布；目标若已出现则 ln 失败，不会覆盖已有记录。
    if ! ln -- "$tmp" "$INSTALL_METADATA_FILE"; then
        rm -f -- "$tmp"
        if [ -e "$INSTALL_METADATA_FILE" ] || [ -L "$INSTALL_METADATA_FILE" ]; then
            install_metadata_read >/dev/null
            return
        fi
        return 1
    fi
    rm -f -- "$tmp" || return 1
    install_metadata_read >/dev/null
}

record_install_metadata_after_install() {
    local had_installed_command="$1"
    local version installed_at

    if [ -e "$INSTALL_METADATA_FILE" ] || [ -L "$INSTALL_METADATA_FILE" ]; then
        install_metadata_read >/dev/null
        return
    fi
    case "$had_installed_command" in
        0)
            version="$(vpsbox_script_version_from_file "$CMD_PATH")" || return 1
            installed_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')" || return 1
            ;;
        1)
            # install.env 首次引入前没有可信历史；不得从当前版本、备份或文件时间推断。
            version="unknown"
            installed_at="unknown"
            ;;
        *)
            return 1
            ;;
    esac
    install_metadata_write_once "$version" "$installed_at"
}

install_self_command() {
    local src
    local had_installed_command=0
    src="${1:-${BASH_SOURCE[0]:-$0}}"

    if [ -f "$CMD_PATH" ] && [ ! -L "$CMD_PATH" ]; then
        had_installed_command=1
    fi
    mkdir -p "$(dirname "$CMD_PATH")" || { err "无法创建管理命令目录。"; return 1; }

    case "$src" in
        /dev/fd/*|/proc/*)
            if download_vpsbox_script "$CMD_PATH"; then
                :
            else
                err "管理命令安装失败，请检查网络后重新运行安装命令。"
                return 1
            fi
            ;;
        *)
            [ -f "$src" ] && [ ! -L "$src" ] ||
                { err "找不到当前 vpsbox 脚本，或脚本路径不安全：$src"; return 1; }

            if [ "$(readlink -f "$src" 2>/dev/null || echo "$src")" != "$CMD_PATH" ]; then
                if ! install_root_file_atomically "$src" "$CMD_PATH" 755; then
                    err "无法安装管理命令到 $CMD_PATH。"
                    return 1
                fi
            fi
            ;;
    esac

    if ! install_command_alias; then
        if [ "$had_installed_command" -eq 0 ]; then
            if ! rm -f -- "$CMD_PATH"; then
                warn "快捷入口安装失败，且无法清理未完成的管理命令：$CMD_PATH"
            fi
        fi
        return 1
    fi

    if ! record_install_metadata_after_install "$had_installed_command"; then
        warn "首次安装记录保存或校验异常，已保留现有文件（如有）：$INSTALL_METADATA_FILE"
    fi
    return 0
}

secure_config_dir() {
    local path

    if [ -L "$CONFIG_DIR" ] || [ -L "$NODE_CONFIG_DIR" ]; then
        err "$CONFIG_DIR 是符号链接，已拒绝使用。"
        return 1
    fi

    mkdir -p "$CONFIG_DIR" || return 1
    chown root:root "$CONFIG_DIR" || return 1
    chmod 700 "$CONFIG_DIR" || return 1
    if [ -d "$NODE_CONFIG_DIR" ]; then
        chown root:root "$NODE_CONFIG_DIR" || return 1
        chmod 700 "$NODE_CONFIG_DIR" || return 1
    fi

    for path in "$URI_FILE" "$SS_CONFIG_PATH" "$VLESS_CONFIG_PATH" \
        "$SS_STATE_FILE" "$VLESS_STATE_FILE" "$SS_URI_FILE" "$VLESS_URI_FILE"; do
        if [ -L "$path" ]; then
            err "$path 是符号链接，已拒绝使用。"
            return 1
        fi
    done
}

secure_node_config_dir() {
    secure_config_dir || return 1
    mkdir -p "$NODE_CONFIG_DIR" || return 1
    chown root:root "$NODE_CONFIG_DIR" || return 1
    chmod 700 "$NODE_CONFIG_DIR"
}

ensure_change_store() {
    [ ! -L "$VPSBOX_STATE_DIR" ] && [ ! -L "$CHANGE_BACKUP_DIR" ] && [ ! -L "$CHANGE_MANIFEST" ] || {
        err "vpsbox 变更清单路径包含符号链接，已拒绝使用。"
        return 1
    }
    mkdir -p "$CHANGE_BACKUP_DIR" || return 1
    chown root:root "$VPSBOX_STATE_DIR" "$CHANGE_BACKUP_DIR" || return 1
    chmod 700 "$VPSBOX_STATE_DIR" "$CHANGE_BACKUP_DIR" || return 1
    [ -e "$CHANGE_MANIFEST" ] || : > "$CHANGE_MANIFEST"
    chown root:root "$CHANGE_MANIFEST" && chmod 600 "$CHANGE_MANIFEST"
}

manifest_value() {
    local key="$1"
    ensure_change_store || return 1
    # 值始终是单行 token；额外允许逗号保存已规范化的多字段 CSV。
    awk -F= -v key="$key" '$1 == key && $2 ~ /^[A-Za-z0-9_.:,-]+$/ { value=$2 } END { if (value != "") print value; else exit 1 }' "$CHANGE_MANIFEST"
}

manifest_value_readonly() {
    local key="$1"

    [[ "$key" =~ ^[A-Z0-9_]+$ ]] || return 1
    [ -f "$CHANGE_MANIFEST" ] && [ ! -L "$CHANGE_MANIFEST" ] || return 1
    awk -F= -v key="$key" \
        '$1 == key && $2 ~ /^[A-Za-z0-9_.:,-]+$/ { value=$2 } END { if (value != "") print value; else exit 1 }' \
        "$CHANGE_MANIFEST"
}

manifest_set() {
    local key="$1" value="$2" tmp
    [[ "$key" =~ ^[A-Z0-9_]+$ && "$value" =~ ^[A-Za-z0-9_.:,-]+$ ]] || return 1
    ensure_change_store || return 1
    tmp="$(mktemp "$VPSBOX_STATE_DIR/.changes.XXXXXX")" || return 1
    if ! awk -F= -v key="$key" '$1 != key { print }' "$CHANGE_MANIFEST" > "$tmp" ||
        ! printf '%s=%s\n' "$key" "$value" >> "$tmp" ||
        ! chown root:root "$tmp" ||
        ! chmod 600 "$tmp" ||
        ! mv -f -- "$tmp" "$CHANGE_MANIFEST"; then
        rm -f -- "$tmp"
        return 1
    fi
}

manifest_set_once() {
    local key="$1" value="$2"
    [ -n "$(manifest_value "$key" 2>/dev/null || true)" ] || manifest_set "$key" "$value"
}

manifest_remove() {
    local key="$1" tmp
    [[ "$key" =~ ^[A-Z0-9_]+$ ]] || return 1
    ensure_change_store || return 1
    tmp="$(mktemp "$VPSBOX_STATE_DIR/.changes.XXXXXX")" || return 1
    if ! awk -F= -v key="$key" '$1 != key { print }' "$CHANGE_MANIFEST" > "$tmp" ||
        ! chown root:root "$tmp" ||
        ! chmod 600 "$tmp" ||
        ! mv -f -- "$tmp" "$CHANGE_MANIFEST"; then
        rm -f -- "$tmp"
        return 1
    fi
}

backup_change_file_once() {
    local name="$1" target="$2" state backup
    [[ "$name" =~ ^[A-Z0-9_]+$ ]] || return 1
    state="$(manifest_value "BACKUP_$name" 2>/dev/null || true)"
    [ -n "$state" ] && return 0
    backup="$CHANGE_BACKUP_DIR/$name"
    if [ -e "$backup" ] || [ -L "$backup" ]; then
        err "备份保存位置已存在但没有对应记录，已拒绝覆盖：$backup"
        return 1
    fi
    [ ! -L "$target" ] || {
        err "备份目标是符号链接，已拒绝：$target"
        return 1
    }
    if [ -e "$target" ]; then
        if ! cp -a "$target" "$backup"; then
            if [ ! -L "$backup" ] && [ -f "$backup" ]; then
                rm -f -- "$backup" || true
            fi
            return 1
        fi
        if ! manifest_set "BACKUP_$name" file; then
            if [ ! -L "$backup" ] && [ -f "$backup" ]; then
                rm -f -- "$backup" || true
            fi
            return 1
        fi
    else
        manifest_set "BACKUP_$name" absent
    fi
}

change_backup_record_is_valid() {
    local name="$1" state backup

    [[ "$name" =~ ^[A-Z0-9_]+$ ]] || return 1
    state="$(manifest_value "BACKUP_$name" 2>/dev/null || true)"
    case "$state" in
        file)
            backup="$CHANGE_BACKUP_DIR/$name"
            [ -f "$backup" ] && [ ! -L "$backup" ]
            ;;
        absent)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

mark_change_applied() {
    local name="$1"

    manifest_set "APPLIED_$name" 1 || return 1
    manifest_remove "PENDING_$name"
}

begin_change_transaction() {
    manifest_set "PENDING_$1" 1
}

cancel_unmodified_change_transaction() {
    local name="$1" key failed=0
    shift

    if [ "$(manifest_value "APPLIED_$name" 2>/dev/null || true)" = "1" ]; then
        manifest_remove "PENDING_$name"
        return
    fi
    rm -f -- "$CHANGE_BACKUP_DIR/$name" || failed=1
    manifest_remove "BACKUP_$name" || failed=1
    manifest_remove "PENDING_$name" || failed=1
    manifest_remove "APPLIED_$name" || failed=1
    for key in "$@"; do
        manifest_remove "$key" || failed=1
    done
    return "$failed"
}

change_restore_state() {
    local name="$1"

    if [ "$(manifest_value "PENDING_$name" 2>/dev/null || true)" = "1" ]; then
        printf '%s\n' pending
    # APPLIED 表示当前版本已经提交、仍可由恢复菜单处理的变更。
    elif [ "$(manifest_value "APPLIED_$name" 2>/dev/null || true)" = "1" ]; then
        printf '%s\n' applied
    else
        printf '%s\n' none
    fi
}

change_restore_state_readonly() {
    local name="$1"

    if [ "$(manifest_value_readonly "PENDING_$name" 2>/dev/null || true)" = "1" ]; then
        printf '%s\n' pending
    elif [ "$(manifest_value_readonly "APPLIED_$name" 2>/dev/null || true)" = "1" ]; then
        printf '%s\n' applied
    else
        printf '%s\n' none
    fi
}

change_needs_restore() {
    [ "$(change_restore_state "$1")" != none ]
}

change_applied_recorded_readonly() {
    local name="$1"

    [[ "$name" =~ ^[A-Z0-9_]+$ ]] || return 1
    [ -f "$CHANGE_MANIFEST" ] && [ ! -L "$CHANGE_MANIFEST" ] || return 1
    [ "$(stat -c '%u:%g %a' "$CHANGE_MANIFEST" 2>/dev/null || true)" = "0:0 600" ] || return 1
    grep -qxF "APPLIED_$name=1" "$CHANGE_MANIFEST" 2>/dev/null
}

restore_change_file() {
    local name="$1" target="$2" state backup
    state="$(manifest_value "BACKUP_$name" 2>/dev/null || true)"
    case "$state" in
        file)
            backup="$CHANGE_BACKUP_DIR/$name"
            [ -f "$backup" ] && [ ! -L "$backup" ] || {
                err "$name 的备份文件无效，已拒绝恢复。"
                return 1
            }
            if ! restore_file_atomically_from_snapshot "$backup" "$target"; then
                return 1
            fi
            ;;
        absent)
            if [ -L "$target" ] || [ -f "$target" ]; then
                rm -f -- "$target"
            elif [ -e "$target" ]; then
                err "恢复目标不是普通文件，已拒绝删除：$target"
                return 1
            fi
            ;;
        *) warn "没有 $name 的可恢复备份。"; return 1 ;;
    esac
}

clear_change_tracking() {
    local name="$1" failed=0

    rm -f "$CHANGE_BACKUP_DIR/$name" || failed=1
    manifest_remove "BACKUP_$name" || failed=1
    manifest_remove "APPLIED_$name" || failed=1
    manifest_remove "PENDING_$name" || failed=1
    return "$failed"
}

install_deps() {
    detect_os

    case "$OS" in
        alpine)
            apk_bounded "$PACKAGE_UPDATE_TIMEOUT" update || return 1
            apk_bounded "$PACKAGE_INSTALL_TIMEOUT" add --no-cache bash curl ca-certificates openssl jq iproute2 coreutils || return 1
            ;;
        debian)
            export DEBIAN_FRONTEND=noninteractive
            apt_get_bounded "$PACKAGE_UPDATE_TIMEOUT" update -y || return 1
            apt_get_bounded "$PACKAGE_INSTALL_TIMEOUT" install -y curl ca-certificates openssl jq iproute2 coreutils || return 1
            ;;
        redhat)
            if command -v dnf >/dev/null 2>&1; then
                dnf_bounded "$PACKAGE_INSTALL_TIMEOUT" install -y curl ca-certificates openssl jq iproute coreutils || return 1
            else
                yum_bounded "$PACKAGE_INSTALL_TIMEOUT" install -y curl ca-certificates openssl jq iproute coreutils || return 1
            fi
            ;;
        *)
            warn "未识别系统类型，跳过自动安装依赖。"
            ;;
    esac
}

# ==============================================================================
# 3. 节点与 sing-box：依赖、服务、监听检查、状态、配置、事务及版本更新
# ==============================================================================
node_commands_available() {
    local command_name

    for command_name in "$@"; do
        command -v "$command_name" >/dev/null 2>&1 || return 1
    done
}

node_ca_trust_available() {
    local bundle

    for bundle in "$@"; do
        [ -s "$bundle" ] && return 0
    done
    return 1
}

node_dependencies_available() {
    node_commands_available curl openssl jq ss sha256sum base64 &&
        node_ca_trust_available \
            /etc/ssl/certs/ca-certificates.crt \
            /etc/pki/tls/certs/ca-bundle.crt \
            /etc/ssl/ca-bundle.pem \
            /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
}

missing_node_commands() {
    local command_name missing=""

    for command_name in "$@"; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            [ -n "$missing" ] && missing="$missing、"
            missing="$missing$command_name"
        fi
    done
    printf '%s\n' "$missing"
}

require_node_commands() {
    local action="$1" missing

    shift
    missing="$(missing_node_commands "$@")"
    [ -z "$missing" ] && return 0
    err "$action 缺少必要命令：$missing。"
    info "请先安装缺少的系统依赖后重试。"
    return 1
}

ensure_node_dependencies() {
    if node_dependencies_available; then
        return 0
    fi

    info "vpsbox 节点管理依赖不完整，正在自动补齐..."
    install_deps || {
        err "vpsbox 节点管理依赖安装失败，请检查软件源或网络。"
        return 1
    }
    if ! node_dependencies_available; then
        err "vpsbox 节点管理依赖安装后仍不完整，需要 curl、openssl、jq、ss、sha256sum、base64 与可用的 CA 证书。"
        return 1
    fi
}

ensure_node_runtime_commands() {
    local missing

    missing="$(missing_node_commands jq ss)"
    [ -z "$missing" ] && return 0
    info "节点服务管理缺少必要命令：$missing，正在自动补齐..."
    install_deps || {
        err "节点服务管理依赖安装失败，请检查软件源或网络。"
        return 1
    }
    require_node_commands "节点服务管理" jq ss
}

singbox_installed() {
    command -v sing-box >/dev/null 2>&1
}

singbox_package_installed() {
    case "$OS" in
        alpine)
            command -v apk >/dev/null 2>&1 && apk info -e sing-box >/dev/null 2>&1
            ;;
        debian)
            command -v dpkg-query >/dev/null 2>&1 &&
                [ "$(dpkg-query -W -f='${Status}' sing-box 2>/dev/null || true)" = "install ok installed" ]
            ;;
        redhat)
            command -v rpm >/dev/null 2>&1 && rpm -q sing-box >/dev/null 2>&1
            ;;
        *) return 1 ;;
    esac
}

singbox_artifacts_present() {
    singbox_installed || singbox_package_installed ||
        [ -e "$CONFIG_DIR" ] ||
        [ -e /etc/systemd/system/sing-box.service ] ||
        [ -e /usr/lib/systemd/system/sing-box.service ] ||
        [ -e /lib/systemd/system/sing-box.service ] ||
        [ -e /etc/init.d/sing-box ] ||
        [ -e /usr/bin/sing-box ] ||
        [ -e /usr/local/bin/sing-box ] ||
        pgrep -x sing-box >/dev/null 2>&1
}

singbox_version() {
    if singbox_installed; then
        sing-box version 2>/dev/null | head -n1 | sed 's/^sing-box version //'
    else
        echo "-"
    fi
}

install_singbox_if_missing() {
    if singbox_installed; then
        return 0
    fi

    info "未检测到 sing-box，开始自动安装..."
    ensure_node_dependencies || return 1
    detect_os

    # 使用固定官方 Release 包与 GitHub 提供的 SHA256，不混用 Alpine edge/community。
    run_singbox_installer || return 1

    if ! singbox_installed; then
        err "sing-box 安装失败，请检查网络或手动安装。"
        return 1
    fi

    info "sing-box 安装完成：$(singbox_version)"
}

install_singbox_for_node_transaction() {
    ensure_node_dependencies || return 1
    if ! singbox_installed; then
        # 首次安装会写入二进制和服务文件，必须先把节点事务标记为已修改，
        # 这样安装中断后下次启动会恢复安装前的服务状态，而不是丢弃事务。
        mark_node_transaction_mutated || return 1
    fi
    install_singbox_if_missing
}

refuse_service_mutation_in_test() {
    if [ "${VPSBOX_TEST_MODE:-0}" = "1" ]; then
        err "测试模式禁止调用真实服务管理命令：$1"
        return 1
    fi
}

run_openrc_service() {
    # OpenRC 可能通过 supervise-daemon 启动长期进程；明确关闭菜单 flock，
    # 防止守护进程继承 FD 200 后让已退出的 vpsbox 看起来仍持有锁。
    rc-service "$@" 200>&-
}

service_start() {
    refuse_service_mutation_in_test service_start || return 1
    if is_systemd; then
        retry 3 2 systemctl start "$SERVICE_NAME"
    elif [ "$OS" = "alpine" ] && command -v rc-service >/dev/null 2>&1; then
        retry 3 2 run_openrc_service "$SERVICE_NAME" start
    else
        err "未检测到 systemd/OpenRC，无法管理服务。"
        return 1
    fi
}

service_stop() {
    refuse_service_mutation_in_test service_stop || return 1
    if is_systemd; then
        retry 3 2 systemctl stop "$SERVICE_NAME"
    elif [ "$OS" = "alpine" ] && command -v rc-service >/dev/null 2>&1; then
        retry 3 2 run_openrc_service "$SERVICE_NAME" stop
    else
        err "未检测到 systemd/OpenRC，无法管理服务。"
        return 1
    fi
}

service_enable() {
    refuse_service_mutation_in_test service_enable || return 1
    if is_systemd; then
        systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
    elif [ "$OS" = "alpine" ] && command -v rc-update >/dev/null 2>&1; then
        rc-update add "$SERVICE_NAME" default >/dev/null 2>&1
    else
        return 1
    fi
}

service_is_enabled() {
    if is_systemd; then
        systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null
    elif [ "$OS" = "alpine" ]; then
        [ -e "/etc/runlevels/default/$SERVICE_NAME" ] || [ -L "/etc/runlevels/default/$SERVICE_NAME" ]
    else
        return 1
    fi
}

service_disable() {
    refuse_service_mutation_in_test service_disable || return 1
    if is_systemd; then
        systemctl disable "$SERVICE_NAME" >/dev/null 2>&1
    elif [ "$OS" = "alpine" ] && command -v rc-update >/dev/null 2>&1; then
        rc-update del "$SERVICE_NAME" default >/dev/null 2>&1
    else
        return 1
    fi
}

service_manager_is_active() {
    if is_systemd; then
        systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null
    elif [ "$OS" = "alpine" ] && command -v rc-service >/dev/null 2>&1; then
        run_openrc_service "$SERVICE_NAME" status >/dev/null 2>&1
    else
        return 1
    fi
}

service_is_running() {
    singbox_installed && service_manager_is_active && [ -n "$(singbox_config_pids)" ]
}

service_status_short() {
    if ! singbox_installed; then
        echo "未运行"
    elif service_is_running; then
        echo "运行中"
    elif is_systemd || { [ "$OS" = "alpine" ] && command -v rc-service >/dev/null 2>&1; }; then
        echo "未运行"
    else
        echo "未知"
    fi
}

singbox_config_pids() {
    local proc pid exe
    local -a args

    for proc in /proc/[0-9]*; do
        [ -r "$proc/cmdline" ] || continue
        pid="${proc##*/}"
        [ "$pid" != "$$" ] || continue
        exe="$(readlink "$proc/exe" 2>/dev/null || true)"
        # Linux 会给仍在运行但磁盘文件已被升级/删除的程序追加 " (deleted)"；
        # 只剥离该精确后缀，并继续核对可执行文件名及完整配置参数，避免扩大进程匹配范围。
        case "$exe" in
            *' (deleted)') exe="${exe% (deleted)}" ;;
        esac
        [ "${exe##*/}" = "sing-box" ] || continue
        mapfile -d '' -t args < "$proc/cmdline" 2>/dev/null || true
        [ "${#args[@]}" -ge 4 ] || continue
        if [ "${args[1]}" = "run" ] &&
            [ "${args[2]}" = "-C" ] && [ "${args[3]}" = "$NODE_CONFIG_DIR" ]; then
            printf '%s\n' "$pid"
        fi
    done
}

stop_singbox_config_processes() {
    local pids pid i

    refuse_service_mutation_in_test stop_singbox_config_processes || return 1
    pids="$(singbox_config_pids)"
    [ -n "$pids" ] || return 0
    warn "检测到使用 vpsbox 节点配置的残留 sing-box 进程，正在停止：$(echo "$pids" | tr '\n' ' ')"
    while read -r pid; do
        [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null || true
    done <<< "$pids"
    for i in 1 2 3 4 5; do
        [ -z "$(singbox_config_pids)" ] && return 0
        sleep 1
    done
    pids="$(singbox_config_pids)"
    while read -r pid; do
        [ -n "$pid" ] && kill -KILL "$pid" 2>/dev/null || true
    done <<< "$pids"
    sleep 1
    [ -z "$(singbox_config_pids)" ]
}

restart_singbox_cleanly() {
    local require_vpsbox_process="${1:-1}"
    local stop_failed=0

    [[ "$require_vpsbox_process" =~ ^[01]$ ]] || return 2

    service_stop 2>/dev/null || stop_failed=1
    stop_singbox_config_processes || {
        err "旧 sing-box 进程无法停止，已拒绝启动新实例。"
        return 1
    }
    if [ "$stop_failed" -eq 1 ] && service_manager_is_active; then
        err "服务管理器未能停止旧 sing-box，已拒绝启动新实例。"
        return 1
    fi
    service_start || return 1
    service_manager_is_active || return 1
    [ "$require_vpsbox_process" = "0" ] || [ -n "$(singbox_config_pids)" ]
}

restore_singbox_service_state() {
    local was_enabled="$1" was_active="$2" require_vpsbox_process="${3:-1}"

    [[ "$require_vpsbox_process" =~ ^[01]$ ]] || return 2

    if [ "$was_enabled" = "1" ]; then
        service_enable || return 1
        service_is_enabled || return 1
    else
        if ! service_disable && service_is_enabled; then
            return 1
        fi
        service_is_enabled && return 1
    fi
    if [ "$was_active" = "1" ]; then
        restart_singbox_cleanly "$require_vpsbox_process"
    else
        if ! service_stop && service_manager_is_active; then
            return 1
        fi
        stop_singbox_config_processes || return 1
        ! service_manager_is_active && [ -z "$(singbox_config_pids)" ]
    fi
}

show_service_status() {
    if is_systemd; then
        systemctl status "$SERVICE_NAME" --no-pager || true
    elif [ "$OS" = "alpine" ] && command -v rc-service >/dev/null 2>&1; then
        rc-service "$SERVICE_NAME" status || true
    else
        warn "未检测到 systemd/OpenRC。"
    fi
}

show_logs() {
    if is_systemd; then
        journalctl -u "$SERVICE_NAME" -f
    elif [ "$OS" = "alpine" ]; then
        tail -f /var/log/sing-box.log /var/log/sing-box.err 2>/dev/null || true
    else
        warn "未检测到可用日志方式。"
    fi
}

# ------------------------------------------------------------------------------
# 共用监听地址分类、socket 采集与安全组建议
# ------------------------------------------------------------------------------
is_loopback_listen_addr() {
    local addr="$1"

    addr="${addr,,}"
    case "$addr" in
        127.*|::1|0:0:0:0:0:0:0:1|::ffff:127.*|::ffff:7f*|0:0:0:0:0:ffff:7f*|localhost|ip6-localhost)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

ipv4_listen_addr_is_public() {
    local addr="$1" first second third fourth octet

    [[ "$addr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r first second third fourth <<< "$addr"
    for octet in "$first" "$second" "$third" "$fourth"; do
        (( 10#$octet <= 255 )) || return 1
    done
    first=$((10#$first))
    second=$((10#$second))
    third=$((10#$third))
    fourth=$((10#$fourth))

    # IANA special-purpose, private, shared, loopback, link-local, documentation,
    # benchmark, multicast and reserved ranges are not public listener addresses.
    (( first == 0 || first == 10 || first == 127 || first >= 224 )) && return 1
    (( first == 100 && second >= 64 && second <= 127 )) && return 1
    (( first == 169 && second == 254 )) && return 1
    (( first == 172 && second >= 16 && second <= 31 )) && return 1
    (( first == 192 && second == 0 && third == 0 && fourth != 9 && fourth != 10 )) && return 1
    (( first == 192 && second == 0 && third == 2 )) && return 1
    (( first == 192 && second == 88 && third == 99 )) && return 1
    (( first == 192 && second == 168 )) && return 1
    (( first == 198 && (second == 18 || second == 19) )) && return 1
    (( first == 198 && second == 51 && third == 100 )) && return 1
    (( first == 203 && second == 0 && third == 113 )) && return 1
    return 0
}

ipv6_expand_hextets() {
    local addr="${1,,}" left right part missing
    local -a left_parts=() right_parts=() parts=()

    [[ "$addr" == *:* ]] && [[ "$addr" != *.* ]] || return 1
    if [[ "$addr" == *::* ]]; then
        [ "${addr#*::}" = "${addr##*::}" ] || return 1
        left="${addr%%::*}"
        right="${addr#*::}"
        [ -z "$left" ] || IFS=':' read -r -a left_parts <<< "$left"
        [ -z "$right" ] || IFS=':' read -r -a right_parts <<< "$right"
        missing=$((8 - ${#left_parts[@]} - ${#right_parts[@]}))
        [ "$missing" -ge 1 ] || return 1
        parts=("${left_parts[@]}")
        while [ "$missing" -gt 0 ]; do
            parts+=(0)
            missing=$((missing - 1))
        done
        parts+=("${right_parts[@]}")
    else
        IFS=':' read -r -a parts <<< "$addr"
        [ "${#parts[@]}" -eq 8 ] || return 1
    fi
    [ "${#parts[@]}" -eq 8 ] || return 1
    for part in "${parts[@]}"; do
        [[ "$part" =~ ^[0-9a-f]{1,4}$ ]] || return 1
        printf '%u ' "$((16#$part))"
    done
    printf '\n'
}

ipv6_listen_addr_is_public() {
    local addr="${1,,}" embedded expanded
    local h0 h1 h2 h3 h4 h5 h6 h7

    addr="${addr%%%*}"
    case "$addr" in
        ::ffff:*.*.*.*)
            embedded="${addr##*::ffff:}"
            ipv4_listen_addr_is_public "$embedded"
            return $?
            ;;
    esac

    expanded="$(ipv6_expand_hextets "$addr")" || return 1
    read -r h0 h1 h2 h3 h4 h5 h6 h7 <<< "$expanded"
    if [ "$h0" -eq 0 ] && [ "$h1" -eq 0 ] && [ "$h2" -eq 0 ] &&
        [ "$h3" -eq 0 ] && [ "$h4" -eq 0 ]; then
        if [ "$h5" -eq 0 ] && [ "$h6" -eq 0 ] &&
            { [ "$h7" -eq 0 ] || [ "$h7" -eq 1 ]; }; then
            return 1
        fi
        if [ "$h5" -eq 65535 ]; then
            embedded="$((h6 >> 8)).$((h6 & 255)).$((h7 >> 8)).$((h7 & 255))"
            ipv4_listen_addr_is_public "$embedded"
            return $?
        fi
    fi

    # 64:ff9b::/96 是 IANA 登记的全球可达 IPv4/IPv6 转换前缀；
    # 其余普通全球单播地址必须先落在当前分配的 2000::/3 中。
    if (( h0 == 0x0064 && h1 == 0xff9b && h2 == 0 && h3 == 0 &&
        h4 == 0 && h5 == 0 )); then
        return 0
    fi
    (( (h0 & 0xe000) == 0x2000 )) || return 1

    # 精确按 IANA 前缀判断，避免用字符串通配把 /64、/48 或 /20 扩大成 /16。
    (( h0 == 0x0100 && h1 == 0 && h2 == 0 && (h3 == 0 || h3 == 1) )) && return 1
    (( (h0 & 0xfe00) == 0xfc00 )) && return 1
    (( (h0 & 0xffc0) == 0xfe80 || (h0 & 0xffc0) == 0xfec0 )) && return 1
    (( (h0 & 0xff00) == 0xff00 )) && return 1
    (( h0 == 0x2001 && h1 == 0x0002 && h2 == 0 )) && return 1
    (( h0 == 0x2001 && (h1 & 0xfff0) == 0x0010 )) && return 1
    (( h0 == 0x2001 && h1 == 0x0db8 )) && return 1
    (( h0 == 0x2002 )) && return 1
    (( h0 == 0x3fff && (h1 & 0xf000) == 0 )) && return 1
    (( h0 == 0x5f00 )) && return 1
    return 0
}

is_public_listen_addr() {
    local addr="${1,,}"

    addr="${addr#[}"
    addr="${addr/\]/}"
    is_wildcard_listen_addr "$addr" && return 0
    is_loopback_listen_addr "$addr" && return 1
    if [[ "$addr" == *:* ]]; then
        ipv6_listen_addr_is_public "$addr"
    else
        ipv4_listen_addr_is_public "$addr"
    fi
}

is_dhcp_client_listener() {
    local protocol="$1" port="$2"

    [ "$protocol" = "udp" ] && { [ "$port" = "68" ] || [ "$port" = "546" ]; }
}

collect_listening_sockets() {
    local output proto protocol state local_addr addr port proc_info proc_name scope
    local _recvq _sendq _peer_addr

    command -v ss >/dev/null 2>&1 || {
        err "未找到 ss 命令，无法读取监听端口。"
        return 1
    }
    output="$(ss -H -tulpn 2>/dev/null)" || {
        err "无法读取系统监听端口。"
        return 1
    }

    while read -r proto state _recvq _sendq local_addr _peer_addr proc_info; do
        case "${proto,,}:$state" in
            tcp*:LISTEN) protocol="tcp" ;;
            udp*:UNCONN) protocol="udp" ;;
            *) continue ;;
        esac

        port="${local_addr##*:}"
        port="$(normalize_port_decimal "$port" 2>/dev/null)" || continue
        addr="${local_addr%:*}"
        addr="${addr#\[}"
        addr="${addr/\]/}"

        proc_name="-"
        if [[ "${proc_info:-}" =~ \"([^\"]+)\" ]]; then
            proc_name="${BASH_REMATCH[1]}"
        fi

        if is_dhcp_client_listener "$protocol" "$port"; then
            scope="system"
        elif is_loopback_listen_addr "$addr"; then
            scope="local"
        elif is_public_listen_addr "$addr"; then
            scope="public"
        else
            scope="nonpublic"
        fi
        printf '%s|%s|%s|%s|%s\n' "$scope" "$protocol" "$port" "$addr" "$proc_name"
    done <<< "$output"
}

show_ports_security_group() {
    local public_file local_file suggest_file records
    local scope protocol port _addr proc_name proto_upper

    public_file="$(mktemp)" || {
        err "无法创建端口检测临时文件。"
        return 1
    }
    local_file="$(mktemp)" || {
        rm -f -- "$public_file"
        err "无法创建端口检测临时文件。"
        return 1
    }
    suggest_file="$(mktemp)" || {
        rm -f -- "$public_file" "$local_file"
        err "无法创建端口检测临时文件。"
        return 1
    }
    records="$(collect_listening_sockets)" || {
        rm -f "$public_file" "$local_file" "$suggest_file"
        return 1
    }

    while IFS='|' read -r scope protocol port _addr proc_name; do
        [ -n "$scope" ] || continue
        proto_upper="${protocol^^}"
        if [ "$scope" = "public" ]; then
            printf '%-5s %-8s %s\n' "$proto_upper" "$port" "$proc_name" >> "$public_file"
            printf '%s %s\n' "$proto_upper" "$port" >> "$suggest_file"
        else
            printf '%-5s %-8s %s\n' "$proto_upper" "$port" "$proc_name" >> "$local_file"
        fi
    done <<< "$records"

    cat <<EOF
========================================
 端口与安全组建议
========================================
公网监听，需要安全组放行：
EOF
    if [ -s "$public_file" ]; then
        sort -u "$public_file"
    else
        echo "无"
    fi

    cat <<EOF

本机或非公网监听，无需安全组放行：
EOF
    if [ -s "$local_file" ]; then
        sort -u "$local_file"
    else
        echo "无"
    fi

    cat <<EOF

建议入站放行：
EOF
    if [ -s "$suggest_file" ]; then
        sort -u -k1,1 -k2,2n "$suggest_file"
    else
        echo "无"
    fi

    cat <<EOF
ICMP 可选

建议出站：
ALL
========================================
EOF

    rm -f "$public_file" "$local_file" "$suggest_file"
}

# ------------------------------------------------------------------------------
# 节点状态与配置
# ------------------------------------------------------------------------------
node_config_path() {
    case "$1" in
        ss) printf '%s\n' "$SS_CONFIG_PATH" ;;
        vless) printf '%s\n' "$VLESS_CONFIG_PATH" ;;
        *) return 2 ;;
    esac
}

node_state_path() {
    case "$1" in
        ss) printf '%s\n' "$SS_STATE_FILE" ;;
        vless) printf '%s\n' "$VLESS_STATE_FILE" ;;
        *) return 2 ;;
    esac
}

node_uri_path() {
    case "$1" in
        ss) printf '%s\n' "$SS_URI_FILE" ;;
        vless) printf '%s\n' "$VLESS_URI_FILE" ;;
        *) return 2 ;;
    esac
}

node_protocol_display_name() {
    case "$1" in
        ss) printf '%s\n' "Shadowsocks" ;;
        vless) printf '%s\n' "VLESS Reality" ;;
        *) return 2 ;;
    esac
}

node_file_is_secure() {
    local file="$1"
    local owner group mode

    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    owner="$(stat -c '%u' "$file" 2>/dev/null)" || return 1
    group="$(stat -c '%g' "$file" 2>/dev/null)" || return 1
    mode="$(stat -c '%a' "$file" 2>/dev/null)" || return 1
    [ "$owner" = "0" ] && [ "$group" = "0" ] || return 1
    case "$mode" in
        400|600) return 0 ;;
        *) return 1 ;;
    esac
}

node_cleanup_source_file_is_safe() {
    local file="$1" owner group mode

    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    owner="$(stat -c '%u' "$file" 2>/dev/null)" || return 1
    group="$(stat -c '%g' "$file" 2>/dev/null)" || return 1
    mode="$(stat -c '%a' "$file" 2>/dev/null)" || return 1
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    [ "$owner" = "0" ] && [ "$group" = "0" ] &&
        [ $((8#$mode & 8#400)) -ne 0 ] &&
        [ $((8#$mode & 8#022)) -eq 0 ]
}

node_uri_file_is_safe() {
    local file="$1" owner group mode

    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    owner="$(stat -c '%u' "$file" 2>/dev/null)" || return 1
    group="$(stat -c '%g' "$file" 2>/dev/null)" || return 1
    mode="$(stat -c '%a' "$file" 2>/dev/null)" || return 1
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    [ "$owner" = "0" ] && [ "$group" = "0" ] &&
        [ $((8#$mode & 8#077)) -eq 0 ]
}

node_dir_is_secure() {
    local dir="$1"
    local owner group mode

    [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
    owner="$(stat -c '%u' "$dir" 2>/dev/null)" || return 1
    group="$(stat -c '%g' "$dir" 2>/dev/null)" || return 1
    mode="$(stat -c '%a' "$dir" 2>/dev/null)" || return 1
    [ "$owner" = "0" ] && [ "$group" = "0" ] && [ "$mode" = "700" ]
}

# 成功时会覆盖 DOMAIN、NAME、PORT、PASSWORD、METHOD、PROTOCOL、UUID、FLOW、
# Reality 字段及 CONFIG_ID。调用者应立即消费或复制所需值；再次成功调用会替换当前节点视图，
# 调用失败则保留上一次成功加载的值。
load_state_file() {
    local file="$1"
    local expected_protocol="$2"
    local key
    local value
    local domain=""
    local name=""
    local port=""
    local password=""
    local method=""
    local protocol=""
    local uuid=""
    local flow=""
    local reality_server_name=""
    local reality_private_key=""
    local reality_public_key=""
    local reality_short_id=""
    local fingerprint=""
    local config_id=""
    local seen_keys=""

    node_file_is_secure "$file" || return 1
    while IFS='=' read -r key value; do
        case "$key" in
            ""|'#'*) continue ;;
            DOMAIN|NAME|PORT|PASSWORD|METHOD|PROTOCOL|UUID|FLOW|REALITY_SERVER_NAME|REALITY_PRIVATE_KEY|REALITY_PUBLIC_KEY|REALITY_SHORT_ID|FINGERPRINT|CONFIG_ID)
                case " $seen_keys " in
                    *" $key "*) return 1 ;;
                esac
                seen_keys="$seen_keys $key"
                ;;
            *) return 1 ;;
        esac
        case "$key" in
            DOMAIN) domain="$value" ;;
            NAME) name="$value" ;;
            PORT) port="$value" ;;
            PASSWORD) password="$value" ;;
            METHOD) method="$value" ;;
            PROTOCOL) protocol="$value" ;;
            UUID) uuid="$value" ;;
            FLOW) flow="$value" ;;
            REALITY_SERVER_NAME) reality_server_name="$value" ;;
            REALITY_PRIVATE_KEY) reality_private_key="$value" ;;
            REALITY_PUBLIC_KEY) reality_public_key="$value" ;;
            REALITY_SHORT_ID) reality_short_id="$value" ;;
            FINGERPRINT) fingerprint="$value" ;;
            CONFIG_ID) config_id="$value" ;;
        esac
    done < "$file"

    is_valid_node_host "$domain" || return 1
    [ -n "$name" ] && [ "$(sanitize_name "$name")" = "$name" ] || return 1
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1
    [ "$protocol" = "$expected_protocol" ] || return 1
    [[ "$config_id" =~ ^[0-9a-f]{24}$ ]] || return 1
    case "$protocol" in
        shadowsocks)
            [[ "$password" =~ ^[A-Za-z0-9_+/=-]+$ ]] || return 1
            [ "$method" = "$SS_METHOD" ] || return 1
            ;;
        vless-reality)
            [[ "$uuid" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || return 1
            [ "$flow" = "xtls-rprx-vision" ] || return 1
            is_domain_name "$reality_server_name" || return 1
            [[ "$reality_private_key" =~ ^[A-Za-z0-9_-]{40,60}$ ]] || return 1
            [[ "$reality_public_key" =~ ^[A-Za-z0-9_-]{40,60}$ ]] || return 1
            [[ "$reality_short_id" =~ ^[0-9A-Fa-f]{16}$ ]] || return 1
            [ "$fingerprint" = "chrome" ] || return 1
            ;;
        *) return 1 ;;
    esac

    DOMAIN="$domain"
    NAME="$name"
    PORT="$port"
    PASSWORD="$password"
    METHOD="$method"
    PROTOCOL="$protocol"
    UUID="$uuid"
    FLOW="$flow"
    REALITY_SERVER_NAME="$reality_server_name"
    REALITY_PRIVATE_KEY="$reality_private_key"
    REALITY_PUBLIC_KEY="$reality_public_key"
    REALITY_SHORT_ID="$reality_short_id"
    FINGERPRINT="$fingerprint"
    CONFIG_ID="$config_id"
}

node_config_matches_loaded_state() {
    local protocol="$1"
    local config="$2"

    command -v jq >/dev/null 2>&1 || return 1
    node_file_is_secure "$config" || return 1
    case "$protocol" in
        ss)
            jq -e \
                --argjson port "$PORT" \
                --arg method "$METHOD" \
                --arg password "$PASSWORD" \
                --arg config_id "$CONFIG_ID" '
                (.inbounds | type == "array" and length > 0) and
                all(.inbounds[];
                    .type == "shadowsocks" and
                    .listen_port == $port and
                    .method == $method and
                    .password == $password and
                    (.tag | type == "string" and contains($config_id))
                )
            ' "$config" >/dev/null 2>&1
            ;;
        vless)
            jq -e \
                --argjson port "$PORT" \
                --arg uuid "$UUID" \
                --arg flow "$FLOW" \
                --arg server_name "$REALITY_SERVER_NAME" \
                --arg private_key "${REALITY_PRIVATE_KEY:-}" \
                --arg short_id "$REALITY_SHORT_ID" \
                --arg config_id "$CONFIG_ID" '
                (.inbounds | type == "array" and length > 0) and
                all(.inbounds[];
                    .type == "vless" and
                    .listen_port == $port and
                    any(.users[]?; .uuid == $uuid and .flow == $flow) and
                    .tls.enabled == true and
                    .tls.server_name == $server_name and
                    .tls.reality.enabled == true and
                    .tls.reality.handshake.server == $server_name and
                    .tls.reality.private_key == $private_key and
                    any(.tls.reality.short_id[]?; . == $short_id) and
                    (.tag | type == "string" and contains($config_id))
                )
            ' "$config" >/dev/null 2>&1
            ;;
        *) return 2 ;;
    esac
}

# 这里只判断配置是否仍符合 vpsbox 当前生成模板，不代表 sing-box 的通用配置规范。
# 合法的自定义监听地址或出站类型仍可通过核心完整性检查，但会在状态界面提示已偏离模板。
node_config_matches_vpsbox_template() {
    local protocol="$1"
    local config="$2"

    command -v jq >/dev/null 2>&1 || return 1
    node_file_is_secure "$config" || return 1
    case "$protocol" in
        ss)
            jq -e --arg config_id "$CONFIG_ID" '
                (.inbounds | type == "array" and (length == 1 or length == 2)) and
                (all(.inbounds[];
                    (.listen == "0.0.0.0" or .listen == "::") and
                    (.tag | type == "string" and contains($config_id))
                )) and
                (if (.inbounds | length) == 2 then
                    ([.inbounds[].listen] | sort | unique) == ["0.0.0.0", "::"]
                 else true end) and
                (.outbounds | type == "array" and length == 1) and
                (.outbounds[0].type == "direct") and
                (.outbounds[0].tag == ("direct-" + $config_id + "-ss"))
            ' "$config" >/dev/null 2>&1
            ;;
        vless)
            jq -e \
                --arg config_id "$CONFIG_ID" \
                --arg uuid "${UUID:-}" \
                --arg flow "${FLOW:-}" \
                --arg short_id "${REALITY_SHORT_ID:-}" '
                (.inbounds | type == "array" and (length == 1 or length == 2)) and
                (all(.inbounds[];
                    (.listen == "0.0.0.0" or .listen == "::") and
                    (.users | type == "array" and length == 1) and
                    (.users[0].uuid == $uuid and .users[0].flow == $flow) and
                    (.tls.reality.short_id | type == "array" and length == 1) and
                    (.tls.reality.short_id[0] == $short_id) and
                    (.tag | type == "string" and contains($config_id))
                )) and
                (if (.inbounds | length) == 2 then
                    ([.inbounds[].listen] | sort | unique) == ["0.0.0.0", "::"]
                 else true end) and
                (.outbounds | type == "array" and length == 1) and
                (.outbounds[0].type == "direct") and
                (.outbounds[0].tag == ("direct-" + $config_id + "-vless"))
            ' "$config" >/dev/null 2>&1
            ;;
        *) return 2 ;;
    esac
}

node_uri_matches_loaded_state() {
    local uri="$1"
    local expected

    [ -f "$uri" ] && [ ! -L "$uri" ] || return 1
    node_file_is_secure "$uri" || return 1
    expected="$(generate_link_from_loaded_state)" || return 1
    [ "$(wc -l < "$uri")" -eq 1 ] && [ "$(cat "$uri")" = "$expected" ]
}

validate_protocol_node_core() {
    local protocol="$1"
    local config="${2:-}"
    local state="${3:-}"
    local expected

    [ -n "$config" ] || config="$(node_config_path "$protocol")" || return 2
    [ -n "$state" ] || state="$(node_state_path "$protocol")" || return 2
    case "$protocol" in
        ss) expected=shadowsocks ;;
        vless) expected=vless-reality ;;
        *) return 2 ;;
    esac
    node_file_is_secure "$state" || return 1
    load_state_file "$state" "$expected" || return 1
    node_config_matches_loaded_state "$protocol" "$config"
}

protocol_node_exists() {
    local protocol="$1" config state

    config="$(node_config_path "$protocol")" || return 2
    state="$(node_state_path "$protocol")" || return 2
    case "$protocol" in
        ss|vless) ;;
        *) return 2 ;;
    esac
    [ -f "$config" ] && [ ! -L "$config" ] &&
        [ -f "$state" ] && [ ! -L "$state" ] &&
        validate_protocol_node_core "$protocol" "$config" "$state" >/dev/null 2>&1
}

protocol_node_status() {
    local protocol="$1" config state

    config="$(node_config_path "$protocol")" || return 2
    state="$(node_state_path "$protocol")" || return 2
    if [ ! -e "$config" ] && [ ! -L "$config" ] &&
        [ ! -e "$state" ] && [ ! -L "$state" ]; then
        printf '%s\n' absent
        return 0
    fi
    if [ ! -f "$config" ] || [ -L "$config" ] ||
        [ ! -f "$state" ] || [ -L "$state" ] ||
        ! validate_protocol_node_core "$protocol" "$config" "$state"; then
        printf '%s\n' damaged
        return 0
    fi
    if node_config_matches_vpsbox_template "$protocol" "$config"; then
        printf '%s\n' normal
    else
        printf '%s\n' deviated
    fi
}

protocol_visible_exists() {
    protocol_node_exists "$1"
}

load_protocol_state() {
    local protocol="$1" state expected

    state="$(node_state_path "$protocol")" || return 2
    case "$protocol" in
        ss) expected=shadowsocks ;;
        vless) expected=vless-reality ;;
        *) return 2 ;;
    esac
    protocol_node_exists "$protocol" || return 1
    load_state_file "$state" "$expected"
}

node_exists() {
    protocol_node_exists ss || protocol_node_exists vless
}

node_core_artifacts_present() {
    [ -e "$NODE_CONFIG_DIR" ] || [ -L "$NODE_CONFIG_DIR" ] ||
        [ -e "$SS_STATE_FILE" ] || [ -L "$SS_STATE_FILE" ] ||
        [ -e "$VLESS_STATE_FILE" ] || [ -L "$VLESS_STATE_FILE" ]
}

node_uri_artifacts_present() {
    [ -e "$URI_FILE" ] || [ -L "$URI_FILE" ] ||
        [ -e "$SS_URI_FILE" ] || [ -L "$SS_URI_FILE" ] ||
        [ -e "$VLESS_URI_FILE" ] || [ -L "$VLESS_URI_FILE" ]
}

node_artifacts_present() {
    node_core_artifacts_present || node_uri_artifacts_present
}

node_config_dir_contents_valid() {
    local path entries

    [ -e "$NODE_CONFIG_DIR" ] || return 0
    node_dir_is_secure "$NODE_CONFIG_DIR" || return 1
    entries="$(find "$NODE_CONFIG_DIR" -mindepth 1 -maxdepth 1 -print 2>/dev/null)" || return 1
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        case "$path" in
            "$SS_CONFIG_PATH"|"$VLESS_CONFIG_PATH") ;;
            *) return 1 ;;
        esac
        node_file_is_secure "$path" || return 1
    done <<< "$entries"
}

node_config_dir_layout_valid() {
    local path entries

    if [ ! -e "$NODE_CONFIG_DIR" ] && [ ! -L "$NODE_CONFIG_DIR" ]; then
        return 0
    fi
    node_dir_is_secure "$NODE_CONFIG_DIR" || return 1
    entries="$(find "$NODE_CONFIG_DIR" -mindepth 1 -maxdepth 1 -print 2>/dev/null)" || return 1
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        case "$path" in
            "$SS_CONFIG_PATH"|"$VLESS_CONFIG_PATH") ;;
            *) return 1 ;;
        esac
    done <<< "$entries"
}

aggregate_uri_matches_nodes() {
    local protocol expected="" link

    node_exists || {
        [ ! -e "$URI_FILE" ] && [ ! -L "$URI_FILE" ]
        return
    }
    node_file_is_secure "$URI_FILE" || return 1
    for protocol in ss vless; do
        protocol_node_exists "$protocol" || continue
        link="$(generate_protocol_link "$protocol")" || return 1
        [ -n "$expected" ] && expected="${expected}"$'\n'
        expected="${expected}${link}"
    done
    [ -n "$expected" ] && [ "$(cat "$URI_FILE")" = "$expected" ]
}

node_uri_cache_paths_secure() {
    local path

    for path in "$URI_FILE" "$SS_URI_FILE" "$VLESS_URI_FILE"; do
        if [ -e "$path" ] || [ -L "$path" ]; then
            node_uri_file_is_safe "$path" || return 1
        fi
    done
}

node_uri_cache_matches_nodes() {
    local protocol uri

    node_uri_cache_paths_secure || return 1
    for protocol in ss vless; do
        uri="$(node_uri_path "$protocol")" || return 1
        if protocol_node_exists "$protocol"; then
            load_protocol_state "$protocol" || return 1
            node_uri_matches_loaded_state "$uri" || return 1
        elif [ -e "$uri" ] || [ -L "$uri" ]; then
            return 1
        fi
    done
    aggregate_uri_matches_nodes
}

node_uri_cache_status() {
    if ! node_uri_cache_paths_secure; then
        printf '%s\n' unsafe
    elif node_uri_cache_matches_nodes; then
        printf '%s\n' current
    else
        printf '%s\n' stale
    fi
}

require_valid_node_state_if_present() {
    local protocol label config state
    local path

    for path in "$NODE_CONFIG_DIR" "$SS_CONFIG_PATH" "$VLESS_CONFIG_PATH" \
        "$SS_STATE_FILE" "$VLESS_STATE_FILE"; do
        if [ -L "$path" ]; then
            err "检测到节点路径为符号链接，已拒绝继续：$path"
            return 1
        fi
    done
    node_config_dir_contents_valid || {
        err "节点配置目录包含未知、残缺或不安全的文件：$NODE_CONFIG_DIR"
        return 1
    }

    for protocol in ss vless; do
        label="$(node_protocol_display_name "$protocol")" || return 1
        config="$(node_config_path "$protocol")" || return 1
        state="$(node_state_path "$protocol")" || return 1
        if [ -e "$config" ] || [ -e "$state" ]; then
            [ -f "$config" ] && [ -f "$state" ] &&
                validate_protocol_node_core "$protocol" "$config" "$state" || {
                err "检测到 $label 节点配置残缺、不安全或内容无效。"
                err "请检查 $config 与 $state。"
                return 1
            }
        fi
    done
}

commit_node_state_file() {
    local tmp="$1"
    local dest="$2"

    if ! chown root:root "$tmp" ||
        ! chmod 600 "$tmp" ||
        ! mv -f -- "$tmp" "$dest"; then
        rm -f -- "$tmp"
        return 1
    fi
}

save_state() {
    local domain="$1"
    local name="$2"
    local port="$3"
    local password="$4"
    local config_id="$5"
    local dest="${6:-$SS_STATE_FILE}"
    local tmp

    [[ "$config_id" =~ ^[0-9a-f]{24}$ ]] || return 1
    secure_config_dir || return 1
    tmp="$(mktemp "$CONFIG_DIR/.vpsbox-ss-state.XXXXXX")" || return 1
    if ! {
        printf 'PROTOCOL=shadowsocks\n' &&
            printf 'CONFIG_ID=%s\n' "$config_id" &&
            printf 'DOMAIN=%s\n' "$domain" &&
            printf 'NAME=%s\n' "$name" &&
            printf 'PORT=%s\n' "$port" &&
            printf 'PASSWORD=%s\n' "$password" &&
            printf 'METHOD=%s\n' "$SS_METHOD"
    } > "$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    commit_node_state_file "$tmp" "$dest"
}

save_vless_reality_state() {
    local domain="$1" name="$2" port="$3" uuid="$4" server_name="$5"
    local private_key="$6" public_key="$7" short_id="$8"
    local config_id="$9"
    local dest="${10:-$VLESS_STATE_FILE}"
    local tmp

    [[ "$config_id" =~ ^[0-9a-f]{24}$ ]] || return 1
    secure_config_dir || return 1
    tmp="$(mktemp "$CONFIG_DIR/.vpsbox-vless-state.XXXXXX")" || return 1
    if ! {
        printf 'PROTOCOL=vless-reality\n' &&
            printf 'CONFIG_ID=%s\n' "$config_id" &&
            printf 'DOMAIN=%s\n' "$domain" &&
            printf 'NAME=%s\n' "$name" &&
            printf 'PORT=%s\n' "$port" &&
            printf 'UUID=%s\n' "$uuid" &&
            printf 'FLOW=xtls-rprx-vision\n' &&
            printf 'REALITY_SERVER_NAME=%s\n' "$server_name" &&
            printf 'REALITY_PRIVATE_KEY=%s\n' "$private_key" &&
            printf 'REALITY_PUBLIC_KEY=%s\n' "$public_key" &&
            printf 'REALITY_SHORT_ID=%s\n' "$short_id" &&
            printf 'FINGERPRINT=chrome\n'
    } > "$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    commit_node_state_file "$tmp" "$dest"
}

normalize_host() {
    local host="$1"
    local no_colons
    local colon_count

    host="$(sanitize_paste_input "$host")"
    host="$(printf '%s' "$host" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    host="${host#http://}"
    host="${host#https://}"
    host="${host%%/*}"
    host="${host%%\?*}"
    host="${host%%#*}"

    if [[ "$host" == \[*\]* ]]; then
        host="${host#\[}"
        host="${host%%\]*}"
    else
        no_colons="${host//:/}"
        colon_count=$((${#host} - ${#no_colons}))
        if [ "$colon_count" -eq 1 ] && [[ "${host##*:}" =~ ^[0-9]+$ ]]; then
            host="${host%:*}"
        fi
    fi

    host="${host%.}"
    echo "$host"
}

sanitize_paste_input() {
    local value="$1"

    value="${value//$'\033[200~'/}"
    value="${value//$'\033[201~'/}"
    value="$(printf '%s' "$value" | LC_ALL=C tr -d '\000-\037\177')"
    value="${value#\[200~}"
    value="${value%\[201~}"
    printf '%s' "$value"
}

is_ipv4_address() {
    local ip="$1"
    local IFS=.
    local -a parts
    local part

    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    read -r -a parts <<< "$ip"
    [ "${#parts[@]}" -eq 4 ] || return 1

    for part in "${parts[@]}"; do
        [[ "$part" =~ ^[0-9]+$ ]] || return 1
        [ "${#part}" -eq 1 ] || [[ "$part" != 0* ]] || return 1
        ((10#$part <= 255)) || return 1
    done
}

is_ipv6_address_basic() {
    local ip="$1"
    local check_ip
    local maybe_v4
    local left right
    local side segment
    local units=0
    local -a chunks

    [[ "$ip" == *:* ]] || return 1
    [[ "$ip" =~ ^[0-9A-Fa-f:.]+$ ]] || return 1
    [[ "$ip" != *:::* ]] || return 1
    [[ "$ip" != :[^:]* ]] || return 1
    [[ "$ip" != *[^:]: ]] || return 1

    check_ip="$ip"
    if [[ "$check_ip" == *.* ]]; then
        maybe_v4="${check_ip##*:}"
        is_ipv4_address "$maybe_v4" || return 1
        check_ip="${check_ip%"$maybe_v4"}0:0"
    fi

    if [[ "$check_ip" == *::* ]]; then
        right="${check_ip#*::}"
        [[ "$right" != *::* ]] || return 1
        left="${check_ip%%::*}"
        for side in "$left" "$right"; do
            [ -n "$side" ] || continue
            IFS=: read -r -a chunks <<< "$side"
            for segment in "${chunks[@]}"; do
                [[ "$segment" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
                units=$((units + 1))
            done
        done
        # "::" 必须压缩至少一个 16 位段；七个显式段加边缘压缩仍是合法地址。
        [ "$units" -lt 8 ]
    else
        IFS=: read -r -a chunks <<< "$check_ip"
        [ "${#chunks[@]}" -eq 8 ] || return 1
        for segment in "${chunks[@]}"; do
            if [[ ! "$segment" =~ ^[0-9A-Fa-f]{1,4}$ ]]; then
                return 1
            fi
        done
        return 0
    fi
}

is_ip_address() {
    local host="$1"

    if command -v python3 >/dev/null 2>&1; then
        python3 - "$host" <<'PY' >/dev/null 2>&1
import ipaddress
import sys

try:
    ipaddress.ip_address(sys.argv[1])
except ValueError:
    sys.exit(1)
PY
        return $?
    fi

    is_ipv4_address "$host" || is_ipv6_address_basic "$host"
}

is_domain_name() {
    local domain="$1"
    local IFS=.
    local -a labels
    local label
    local last

    [ "${#domain}" -ge 4 ] || return 1
    [ "${#domain}" -le 253 ] || return 1
    [[ "$domain" == *.* ]] || return 1
    [[ "$domain" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
    [[ "$domain" != *..* ]] || return 1

    read -r -a labels <<< "$domain"
    [ "${#labels[@]}" -ge 2 ] || return 1

    for label in "${labels[@]}"; do
        [ -n "$label" ] || return 1
        [ "${#label}" -le 63 ] || return 1
        [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || return 1
    done

    last="${labels[${#labels[@]}-1]}"
    [ "${#last}" -ge 2 ] || return 1
    [[ "$last" =~ [A-Za-z] ]]
}

is_valid_node_host() {
    local host="$1"
    is_ip_address "$host" || is_domain_name "$host"
}

is_repeated_node_host() {
    local host="${1,,}"
    local length="${#1}"
    local half

    [ "$length" -ge 8 ] || return 1
    ((length % 2 == 0)) || return 1
    half=$((length / 2))
    [ "${host:0:half}" = "${host:half:half}" ]
}

node_ipv4_is_assigned_locally() {
    local address="$1"

    command -v ip >/dev/null 2>&1 || return 1
    ip -4 -o addr show scope global 2>/dev/null \
        | awk -v target="$address" '{ split($4, parts, "/"); if (parts[1] == target) found = 1 } END { exit !found }'
}

prompt_node_host() {
    local result_var="$1"
    local prompt="$2"
    local input_host host answer delayed_host
    local used_detected_ipv4=0 delayed_host_adopted=0

    [[ "$result_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1

    while true; do
        read -r -p "$prompt" input_host || return 1
        host="$(normalize_host "$input_host")"
        used_detected_ipv4=0
        delayed_host_adopted=0

        if [ -z "$host" ]; then
            info "正在自动检测 VPS 公网 IPv4..."
            host="$(normalize_host "$(public_ipv4 || true)")"
            if ! is_ipv4_address "$host"; then
                warn "公网 IPv4 自动检测失败，请手动输入节点连接地址。"
                continue
            fi

            info "自动检测到公网 IPv4：$host"
            while true; do
                read -r -p "确认使用该公网 IPv4？ [Y/n]: " answer || return 1
                case "$answer" in
                    ""|Y|y)
                        used_detected_ipv4=1
                        break
                        ;;
                    N|n)
                        info "请手动输入节点连接地址。"
                        host=""
                        break
                        ;;
                    *)
                        delayed_host="$(normalize_host "$answer")"
                        if is_valid_node_host "$delayed_host"; then
                            host="$delayed_host"
                            delayed_host_adopted=1
                            break
                        fi
                        warn "请输入 y、n，或直接输入有效的节点域名或 IP；直接回车默认 y。"
                        ;;
                esac
            done
            [ -n "$host" ] || continue
            if [ "$used_detected_ipv4" -eq 1 ] &&
                command -v ip >/dev/null 2>&1 &&
                ! node_ipv4_is_assigned_locally "$host"; then
                warn "该公网 IPv4 未直接配置在本机，当前 VPS 可能使用 NAT。"
                warn "请确认公网映射地址正确，并将后续节点端口映射到相同端口。"
            fi
        elif ! is_valid_node_host "$host"; then
            err "格式不正确，请输入类似 sb.example.com、1.2.3.4 或 2001:db8::1。"
            continue
        fi

        if is_repeated_node_host "$host"; then
            err "检测到节点地址可能被重复粘贴：$host"
            err "请只输入一次域名或 IP。"
            continue
        fi

        if [ "$delayed_host_adopted" -eq 1 ]; then
            info "检测到延迟到达的节点连接地址，已自动采用：$host"
        fi
        printf -v "$result_var" '%s' "$host"
        info "已识别节点连接地址：$host"
        return 0
    done
}

uri_host() {
    local host="$1"
    if [[ "$host" == *:* && "$host" != \[*\] ]]; then
        echo "[$host]"
    else
        echo "$host"
    fi
}

sanitize_name() {
    local raw="$1"
    local cleaned
    cleaned="$(printf "%s" "$raw" | sed 's/[^A-Za-z0-9._-]/-/g')"
    cleaned="$(printf "%s" "$cleaned" | sed 's/--*/-/g; s/^-//; s/-$//')"
    [ -n "$cleaned" ] && echo "$cleaned" || echo "ss"
}

default_name_for_host() {
    local host="$1"
    local first="${host%%.*}"
    first="$(sanitize_name "$first")"
    echo "ss-$first"
}

url_encode_userinfo() {
    printf "%s" "$1" \
        | sed -e 's/%/%25/g' \
              -e 's/:/%3A/g' \
              -e 's/+/%2B/g' \
              -e 's/\//%2F/g' \
              -e 's/=/%3D/g'
}

generate_link_from_loaded_state() {
    local host
    local encoded

    host="$(uri_host "${DOMAIN:-}")" || return 1
    case "${PROTOCOL:-shadowsocks}" in
        shadowsocks)
            encoded="$(url_encode_userinfo "${METHOD:-$SS_METHOD}:${PASSWORD:-}")" || return 1
            printf 'ss://%s@%s:%s#%s\n' "$encoded" "$host" "${PORT:-0}" "${NAME:-ss}"
            ;;
        vless-reality)
            printf 'vless://%s@%s:%s?encryption=none&flow=%s&security=reality&sni=%s&fp=%s&pbk=%s&sid=%s&type=tcp#%s\n' \
                "$UUID" "$host" "$PORT" "$FLOW" "$REALITY_SERVER_NAME" "$FINGERPRINT" \
                "$REALITY_PUBLIC_KEY" "$REALITY_SHORT_ID" "$NAME"
            ;;
        *) return 1 ;;
    esac
}

generate_protocol_link() {
    load_protocol_state "$1" || return 1
    generate_link_from_loaded_state
}

secure_uri_build_files() {
    local build_dir="$1"
    local path

    for path in "$build_dir"/*.txt; do
        [ -f "$path" ] || continue
        chown root:root "$path" && chmod 600 "$path" || return 1
    done
}

build_current_uri_files() {
    local build_dir="$1"
    local aggregate="$build_dir/${URI_FILE##*/}"
    local protocol dest tmp
    local has_node=0

    mkdir -p "$build_dir" || return 1
    : > "$aggregate" || return 1
    for protocol in ss vless; do
        dest="$(node_uri_path "$protocol")" || return 1
        tmp="$build_dir/${dest##*/}"
        if protocol_node_exists "$protocol"; then
            generate_protocol_link "$protocol" > "$tmp" || return 1
            cat "$tmp" >> "$aggregate" || return 1
            has_node=1
        fi
    done
    if [ "$has_node" -eq 0 ]; then
        rm -f -- "$aggregate" || return 1
    fi
    secure_uri_build_files "$build_dir"
}

restore_uri_file_group() {
    local backup_dir="$1"
    local dest backup

    for dest in "$URI_FILE" "$SS_URI_FILE" "$VLESS_URI_FILE"; do
        backup="$backup_dir/${dest##*/}"
        if [ -f "$backup" ]; then
            restore_file_atomically_from_snapshot "$backup" "$dest" || return 1
        else
            remove_snapshot_target_file "$dest" || return 1
        fi
    done
}

publish_uri_file_group() {
    local build_dir="$1"
    local rollback_dir tmp_dir dest source tmp failed=0

    rollback_dir="$(mktemp -d "$CONFIG_DIR/.vpsbox-uri-rollback.XXXXXX")" || return 1
    tmp_dir="$(mktemp -d "$CONFIG_DIR/.vpsbox-uri-publish.XXXXXX")" || {
        rm -rf -- "$rollback_dir"
        return 1
    }
    for dest in "$URI_FILE" "$SS_URI_FILE" "$VLESS_URI_FILE"; do
        if [ -e "$dest" ] || [ -L "$dest" ]; then
            node_uri_file_is_safe "$dest" || {
                rm -rf -- "$rollback_dir" "$tmp_dir"
                return 1
            }
            cp -a -- "$dest" "$rollback_dir/${dest##*/}" || {
                rm -rf -- "$rollback_dir" "$tmp_dir"
                return 1
            }
        fi
        source="$build_dir/${dest##*/}"
        if [ -f "$source" ]; then
            tmp="$tmp_dir/${dest##*/}"
            cp -- "$source" "$tmp" &&
                chown root:root "$tmp" &&
                chmod 600 "$tmp" || {
                rm -rf -- "$rollback_dir" "$tmp_dir"
                return 1
            }
        fi
    done
    for dest in "$URI_FILE" "$SS_URI_FILE" "$VLESS_URI_FILE"; do
        tmp="$tmp_dir/${dest##*/}"
        if [ -f "$tmp" ]; then
            mv -f -- "$tmp" "$dest" || { failed=1; break; }
        else
            rm -f -- "$dest" || { failed=1; break; }
        fi
    done
    if [ "$failed" -ne 0 ]; then
        if ! restore_uri_file_group "$rollback_dir"; then
            err "节点链接文件组更新失败，旧链接组也未能完整恢复。"
        fi
        rm -rf -- "$rollback_dir" "$tmp_dir"
        return 1
    fi
    rm -rf -- "$rollback_dir" "$tmp_dir"
}

write_uri_files() {
    local build_dir

    require_valid_node_state_if_present || return 1
    node_uri_cache_paths_secure || return 1
    secure_config_dir || return 1
    build_dir="$(mktemp -d "$CONFIG_DIR/.vpsbox-uri-build.XXXXXX")" || return 1
    if ! build_current_uri_files "$build_dir" ||
        ! publish_uri_file_group "$build_dir"; then
        rm -rf -- "$build_dir"
        return 1
    fi
    rm -rf -- "$build_dir"
}

repair_node_uri_cache() {
    local status

    require_valid_node_state_if_present || return 1
    status="$(node_uri_cache_status)" || return 1
    case "$status" in
        current) return 0 ;;
        unsafe) return 1 ;;
        stale) ;;
        *) return 1 ;;
    esac
    write_uri_files || return 1
    [ "$(node_uri_cache_status)" = current ]
}

repair_node_uri_cache_best_effort() {
    local context="${1:-节点操作}"
    local status

    repair_node_uri_cache && return 0
    status="$(node_uri_cache_status 2>/dev/null || true)"
    if [ "$status" = unsafe ]; then
        warn "$context未自动修复节点链接缓存：检测到符号链接、非普通文件或不安全权限。"
    else
        warn "$context未能更新节点链接缓存；核心配置不受影响，可稍后运行一键检测。"
    fi
    return 0
}

repair_node_uri_cache_on_startup() {
    node_core_artifacts_present || node_uri_artifacts_present || return 0
    if node_core_artifacts_present && ! command -v jq >/dev/null 2>&1; then
        return 0
    fi
    require_valid_node_state_if_present >/dev/null 2>&1 || return 0
    repair_node_uri_cache_best_effort "启动恢复后"
}

node_transaction_validation_spec() {
    local transaction_dir="$1"
    local spec_file="$transaction_dir/validation-mode"
    local spec

    if [ ! -e "$spec_file" ] && [ ! -L "$spec_file" ]; then
        # v1.0.43-v1.0.44 的旧事务没有该字段，均按原完整事务校验。
        printf '%s\n' full
        return 0
    fi
    node_file_is_secure "$spec_file" || return 1
    [ "$(wc -l < "$spec_file")" -eq 1 ] || return 1
    IFS= read -r spec < "$spec_file" || return 1
    case "$spec" in
        full|static|cleanup:ss|cleanup:vless)
            printf '%s\n' "$spec"
            ;;
        *) return 1 ;;
    esac
}

write_node_transaction_validation_spec() {
    local spec="$1"
    local spec_file="$NODE_TRANSACTION_DIR/validation-mode"

    case "$spec" in
        full|static|cleanup:ss|cleanup:vless) ;;
        *) return 2 ;;
    esac
    printf '%s\n' "$spec" > "$spec_file" || return 1
    chown root:root "$spec_file" && chmod 600 "$spec_file"
}

backup_node_files() {
    local backup_dir="$1"
    local validation_spec="${2:-full}"
    local manifest="$backup_dir/manifest"
    local cleanup_protocol="" normalize_ss=0 normalize_vless=0 path

    case "$validation_spec" in
        full|static) ;;
        cleanup:ss) cleanup_protocol=ss; normalize_ss=1 ;;
        cleanup:vless) cleanup_protocol=vless; normalize_vless=1 ;;
        *) return 2 ;;
    esac

    command -v sha256sum >/dev/null 2>&1 || {
        err "缺少 sha256sum，无法建立可校验的节点事务备份。"
        return 1
    }
    if [ -n "$cleanup_protocol" ]; then
        for path in "$(node_config_path "$cleanup_protocol")" \
            "$(node_state_path "$cleanup_protocol")"; do
            if [ -e "$path" ] || [ -L "$path" ]; then
                node_cleanup_source_file_is_safe "$path" || return 1
            fi
        done
    fi
    mkdir -p "$backup_dir" || return 1
    : > "$manifest" || return 1
    printf 'version|1\n' >> "$manifest" || return 1

    # URI 是可由配置与状态重建的派生缓存，不作为事务恢复的权威材料。
    # 保留旧清单字段，兼容 v1.0.43 起已经落盘的 version|1 事务格式。
    printf 'file|node-uri.txt|absent|-\n' >> "$manifest" || return 1

    if [ -d "$NODE_CONFIG_DIR" ] && [ ! -L "$NODE_CONFIG_DIR" ]; then
        cp -a "$NODE_CONFIG_DIR" "$backup_dir/vpsbox.d" || return 1
        printf 'dir|vpsbox.d|present|-\n' >> "$manifest" || return 1
        backup_node_copied_file_with_manifest \
            "$backup_dir/vpsbox.d/${SS_CONFIG_PATH##*/}" \
            "vpsbox.d/${SS_CONFIG_PATH##*/}" "$manifest" "$normalize_ss" || return 1
        backup_node_copied_file_with_manifest \
            "$backup_dir/vpsbox.d/${VLESS_CONFIG_PATH##*/}" \
            "vpsbox.d/${VLESS_CONFIG_PATH##*/}" "$manifest" "$normalize_vless" || return 1
    elif [ ! -e "$NODE_CONFIG_DIR" ] && [ ! -L "$NODE_CONFIG_DIR" ]; then
        printf 'dir|vpsbox.d|absent|-\n' >> "$manifest" || return 1
        printf 'file|vpsbox.d/%s|absent|-\n' "${SS_CONFIG_PATH##*/}" >> "$manifest" || return 1
        printf 'file|vpsbox.d/%s|absent|-\n' "${VLESS_CONFIG_PATH##*/}" >> "$manifest" || return 1
    else
        return 1
    fi

    backup_node_file_with_manifest "$SS_STATE_FILE" "$backup_dir/ss-state.env" \
        ss-state.env "$manifest" "$normalize_ss" || return 1
    backup_node_file_with_manifest "$VLESS_STATE_FILE" "$backup_dir/vless-state.env" \
        vless-state.env "$manifest" "$normalize_vless" || return 1
    printf 'file|ss-uri.txt|absent|-\n' >> "$manifest" || return 1
    printf 'file|vless-uri.txt|absent|-\n' >> "$manifest" || return 1
    backup_node_file_with_manifest /etc/systemd/system/sing-box.service \
        "$backup_dir/sing-box.service" sing-box.service "$manifest" || return 1
    backup_node_file_with_manifest /etc/init.d/sing-box \
        "$backup_dir/openrc-sing-box" openrc-sing-box "$manifest" || return 1

    # 事务恢复的是服务管理器原本的 active 状态。精确匹配 `run -C vpsbox.d`
    # 只用于 vpsbox 节点运行验证，不能把 active 的自定义或旧布局服务记成未运行。
    if service_manager_is_active; then
        printf '1\n' > "$backup_dir/service-running" || return 1
    else
        printf '0\n' > "$backup_dir/service-running" || return 1
    fi
    if service_is_enabled; then
        printf '1\n' > "$backup_dir/service-enabled" || return 1
    else
        printf '0\n' > "$backup_dir/service-enabled" || return 1
    fi
    chown root:root "$backup_dir/service-running" "$backup_dir/service-enabled" "$manifest" ||
        return 1
    chmod 600 "$backup_dir/service-running" "$backup_dir/service-enabled" "$manifest" ||
        return 1
    backup_node_copied_file_with_manifest "$backup_dir/service-running" \
        service-running "$manifest" || return 1
    backup_node_copied_file_with_manifest "$backup_dir/service-enabled" \
        service-enabled "$manifest" || return 1
}

normalize_cleanup_backup_file() {
    local file="$1" mode

    chown root:root "$file" || return 1
    mode="$(stat -c '%a' "$file" 2>/dev/null)" || return 1
    case "$mode" in
        400|600) ;;
        *) chmod 600 "$file" || return 1 ;;
    esac
}

backup_node_file_with_manifest() {
    local source="$1" backup="$2" name="$3" manifest="$4"
    local normalize="${5:-0}"
    local digest

    if [ -f "$source" ] && [ ! -L "$source" ]; then
        cp -a -- "$source" "$backup" || return 1
        if [ "$normalize" = "1" ]; then
            normalize_cleanup_backup_file "$backup" || return 1
        fi
        digest="$(sha256sum "$backup" | awk '{print $1}')" || return 1
        [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
        printf 'file|%s|present|%s\n' "$name" "$digest" >> "$manifest"
    elif [ ! -e "$source" ] && [ ! -L "$source" ]; then
        printf 'file|%s|absent|-\n' "$name" >> "$manifest"
    else
        return 1
    fi
}

backup_node_copied_file_with_manifest() {
    local backup="$1" name="$2" manifest="$3"
    local normalize="${4:-0}"
    local digest

    if [ -f "$backup" ] && [ ! -L "$backup" ]; then
        if [ "$normalize" = "1" ]; then
            normalize_cleanup_backup_file "$backup" || return 1
        fi
        digest="$(sha256sum "$backup" | awk '{print $1}')" || return 1
        [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
        printf 'file|%s|present|%s\n' "$name" "$digest" >> "$manifest"
    elif [ ! -e "$backup" ] && [ ! -L "$backup" ]; then
        printf 'file|%s|absent|-\n' "$name" >> "$manifest"
    else
        return 1
    fi
}

node_backup_file_is_safe() {
    local file="$1" owner group mode

    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    owner="$(stat -c '%u' "$file" 2>/dev/null)" || return 1
    group="$(stat -c '%g' "$file" 2>/dev/null)" || return 1
    mode="$(stat -c '%a' "$file" 2>/dev/null)" || return 1
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    [ "$owner" = "0" ] && [ "$group" = "0" ] &&
        [ $((8#$mode & 8#022)) -eq 0 ]
}

node_backup_manifest_entry() {
    local manifest="$1" name="$2"

    awk -F'|' -v name="$name" '
        $2 == name { line=$0; count++ }
        END {
            if (count == 1) print line
            else exit 1
        }
    ' "$manifest"
}

validate_node_backup_file_entry() {
    local manifest="$1" name="$2" path="$3"
    local line kind entry_name state digest actual

    line="$(node_backup_manifest_entry "$manifest" "$name")" || return 1
    IFS='|' read -r kind entry_name state digest <<< "$line"
    [ "$kind" = "file" ] && [ "$entry_name" = "$name" ] || return 1
    case "$state" in
        present)
            [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
            node_backup_file_is_safe "$path" || return 1
            actual="$(sha256sum "$path" | awk '{print $1}')" || return 1
            [ "$actual" = "$digest" ]
            ;;
        absent)
            [ "$digest" = "-" ] && [ ! -e "$path" ] && [ ! -L "$path" ]
            ;;
        *) return 1 ;;
    esac
}

validate_derived_uri_manifest_entry() {
    local manifest="$1" name="$2"
    local line kind entry_name state digest

    line="$(node_backup_manifest_entry "$manifest" "$name")" || return 1
    IFS='|' read -r kind entry_name state digest <<< "$line"
    [ "$kind" = "file" ] && [ "$entry_name" = "$name" ] || return 1
    case "$state" in
        present) [[ "$digest" =~ ^[0-9a-f]{64}$ ]] ;;
        absent) [ "$digest" = "-" ] ;;
        *) return 1 ;;
    esac
}

node_backup_entry_is_present() {
    local manifest="$1" name="$2" line kind entry_name state digest

    line="$(node_backup_manifest_entry "$manifest" "$name")" || return 2
    IFS='|' read -r kind entry_name state digest <<< "$line"
    [ "$entry_name" = "$name" ] || return 2
    case "$state" in
        present) return 0 ;;
        absent) return 1 ;;
        *) return 2 ;;
    esac
}

validate_node_transaction_backup() {
    local backup_dir="$1"
    local validation_spec="${2:-full}"
    local manifest="$backup_dir/manifest"
    local config_dir="$backup_dir/vpsbox.d"
    local ss_config="$config_dir/${SS_CONFIG_PATH##*/}"
    local vless_config="$config_dir/${VLESS_CONFIG_PATH##*/}"
    local line kind name state digest path protocol config state_path
    local config_dir_present=0 config_count=0 entry_status
    local cleanup_protocol="" config_present state_present
    local -a entries=(
        node-uri.txt vpsbox.d "vpsbox.d/${SS_CONFIG_PATH##*/}"
        "vpsbox.d/${VLESS_CONFIG_PATH##*/}" ss-state.env vless-state.env
        ss-uri.txt vless-uri.txt sing-box.service openrc-sing-box
        service-running service-enabled
    )

    case "$validation_spec" in
        full|static) ;;
        cleanup:ss) cleanup_protocol=ss ;;
        cleanup:vless) cleanup_protocol=vless ;;
        *) return 1 ;;
    esac
    command -v sha256sum >/dev/null 2>&1 || return 1
    [ -d "$backup_dir" ] && [ ! -L "$backup_dir" ] || return 1
    node_backup_file_is_safe "$manifest" || return 1
    [ "$(sed -n '1p' "$manifest")" = "version|1" ] || return 1
    [ "$(wc -l < "$manifest")" -eq 13 ] || return 1
    for name in "${entries[@]}"; do
        node_backup_manifest_entry "$manifest" "$name" >/dev/null || return 1
    done

    line="$(node_backup_manifest_entry "$manifest" vpsbox.d)" || return 1
    IFS='|' read -r kind name state digest <<< "$line"
    [ "$kind" = "dir" ] && [ "$name" = "vpsbox.d" ] && [ "$digest" = "-" ] || return 1
    case "$state" in
        present)
            [ -d "$config_dir" ] && [ ! -L "$config_dir" ] || return 1
            config_dir_present=1
            ;;
        absent)
            [ ! -e "$config_dir" ] && [ ! -L "$config_dir" ] || return 1
            ;;
        *) return 1 ;;
    esac

    # v1.0.43 起的旧事务会保存 URI 快照。URI 已是派生缓存，旧快照只校验
    # 清单结构，不再因文件丢失、权限或哈希损坏阻止核心配置恢复。
    validate_derived_uri_manifest_entry "$manifest" node-uri.txt || return 1
    validate_node_backup_file_entry "$manifest" "vpsbox.d/${SS_CONFIG_PATH##*/}" "$ss_config" || return 1
    validate_node_backup_file_entry "$manifest" "vpsbox.d/${VLESS_CONFIG_PATH##*/}" "$vless_config" || return 1
    validate_node_backup_file_entry "$manifest" ss-state.env "$backup_dir/ss-state.env" || return 1
    validate_node_backup_file_entry "$manifest" vless-state.env "$backup_dir/vless-state.env" || return 1
    validate_derived_uri_manifest_entry "$manifest" ss-uri.txt || return 1
    validate_derived_uri_manifest_entry "$manifest" vless-uri.txt || return 1
    validate_node_backup_file_entry "$manifest" sing-box.service "$backup_dir/sing-box.service" || return 1
    validate_node_backup_file_entry "$manifest" openrc-sing-box "$backup_dir/openrc-sing-box" || return 1
    validate_node_backup_file_entry "$manifest" service-running "$backup_dir/service-running" || return 1
    validate_node_backup_file_entry "$manifest" service-enabled "$backup_dir/service-enabled" || return 1

    grep -Eq '^[01]$' "$backup_dir/service-running" || return 1
    grep -Eq '^[01]$' "$backup_dir/service-enabled" || return 1

    for protocol in ss vless; do
        case "$protocol" in
            ss)
                config="$ss_config"
                state_path="$backup_dir/ss-state.env"
                ;;
            vless)
                config="$vless_config"
                state_path="$backup_dir/vless-state.env"
                ;;
        esac
        config_present=0
        state_present=0
        if node_backup_entry_is_present "$manifest" "vpsbox.d/${config##*/}"; then
            config_present=1
            config_count=$((config_count + 1))
        else
            entry_status=$?
            [ "$entry_status" -eq 1 ] || return 1
        fi
        if node_backup_entry_is_present "$manifest" "${state_path##*/}"; then
            state_present=1
        else
            entry_status=$?
            [ "$entry_status" -eq 1 ] || return 1
        fi

        if [ "$protocol" = "$cleanup_protocol" ]; then
            [ "$config_present" -eq 1 ] || [ "$state_present" -eq 1 ] || return 1
            continue
        fi
        [ "$config_present" -eq "$state_present" ] || return 1
        if [ "$config_present" -eq 1 ]; then
            validate_protocol_node_core "$protocol" "$config" "$state_path" || return 1
        fi
    done
    if [ "$config_count" -gt 0 ]; then
        [ "$config_dir_present" -eq 1 ] || return 1
        while IFS= read -r path; do
            [ -n "$path" ] || continue
            case "$path" in
                "$ss_config"|"$vless_config") ;;
                *) return 1 ;;
            esac
        done < <(find "$config_dir" -mindepth 1 -maxdepth 1 -print 2>/dev/null)
    elif [ "$config_dir_present" -eq 1 ]; then
        [ -z "$(find "$config_dir" -mindepth 1 -maxdepth 1 -print 2>/dev/null)" ] || return 1
    fi
}

sync_node_transaction_store() {
    [ "${VPSBOX_TEST_MODE:-0}" != "1" ] || return 0
    command -v sync >/dev/null 2>&1 || return 1
    sync
}

node_transaction_dir_valid() {
    [ "${1:-}" = "$NODE_TRANSACTION_DIR" ] &&
        [ "$NODE_TRANSACTION_DIR" = "$VPSBOX_STATE_DIR/node-transaction" ]
}

remove_node_transaction_dir() {
    local transaction_dir="${1:-$NODE_TRANSACTION_DIR}"

    node_transaction_dir_valid "$transaction_dir" || {
        err "节点事务目录异常，已拒绝递归清理：$transaction_dir"
        return 1
    }
    [ ! -L "$transaction_dir" ] || {
        err "节点事务目录是符号链接，已拒绝清理：$transaction_dir"
        return 1
    }
    rm -rf -- "$transaction_dir"
}

prepare_node_transaction_store() {
    [ ! -L "$VPSBOX_STATE_DIR" ] && [ ! -L "$NODE_TRANSACTION_DIR" ] || {
        err "节点事务路径包含符号链接，已拒绝使用。"
        return 1
    }
    mkdir -p "$VPSBOX_STATE_DIR" || return 1
    chown root:root "$VPSBOX_STATE_DIR" || return 1
    chmod 700 "$VPSBOX_STATE_DIR"
}

begin_node_transaction() {
    local validation_spec="${1:-full}"

    case "$validation_spec" in
        full|static|cleanup:ss|cleanup:vless) ;;
        *) return 2 ;;
    esac
    prepare_node_transaction_store || return 1
    if [ -e "$NODE_TRANSACTION_DIR/pending" ]; then
        err "检测到尚未恢复的节点事务，已拒绝开始新操作：$NODE_TRANSACTION_DIR"
        return 1
    fi
    if [ -e "$NODE_TRANSACTION_DIR/committed" ]; then
        node_file_is_secure "$NODE_TRANSACTION_DIR/committed" || {
            err "节点事务 committed 标记不安全，已拒绝开始新操作。"
            return 1
        }
        remove_node_transaction_dir || return 1
    elif [ -e "$NODE_TRANSACTION_DIR" ]; then
        # pending 标记只会在完整备份后写入；没有标记说明尚未修改节点文件。
        remove_node_transaction_dir || return 1
    fi
    mkdir -p "$NODE_TRANSACTION_BACKUP" "$NODE_TRANSACTION_STAGE" || {
        remove_node_transaction_dir || true
        return 1
    }
    chown root:root "$NODE_TRANSACTION_DIR" "$NODE_TRANSACTION_BACKUP" "$NODE_TRANSACTION_STAGE" || {
        remove_node_transaction_dir || true
        return 1
    }
    chmod 700 "$NODE_TRANSACTION_DIR" "$NODE_TRANSACTION_BACKUP" "$NODE_TRANSACTION_STAGE" || {
        remove_node_transaction_dir || true
        return 1
    }
    if ! write_node_transaction_validation_spec "$validation_spec"; then
        remove_node_transaction_dir || true
        return 1
    fi
    if ! backup_node_files "$NODE_TRANSACTION_BACKUP" "$validation_spec"; then
        remove_node_transaction_dir || true
        return 1
    fi
    if ! validate_node_transaction_backup "$NODE_TRANSACTION_BACKUP" "$validation_spec"; then
        remove_node_transaction_dir || true
        err "节点事务备份未通过完整性检查。"
        return 1
    fi
    if [ "$validation_spec" = "full" ] &&
        { [ -f "$NODE_TRANSACTION_BACKUP/vpsbox.d/${SS_CONFIG_PATH##*/}" ] ||
            [ -f "$NODE_TRANSACTION_BACKUP/vpsbox.d/${VLESS_CONFIG_PATH##*/}" ]; }; then
        if ! command -v sing-box >/dev/null 2>&1 ||
            ! sing-box check -C "$NODE_TRANSACTION_BACKUP/vpsbox.d" >/dev/null; then
            remove_node_transaction_dir || true
            err "节点事务备份未通过 sing-box 配置检查。"
            return 1
        fi
    fi
    if ! sync_node_transaction_store; then
        remove_node_transaction_dir || true
        err "节点事务备份未通过持久化检查。"
        return 1
    fi
    : > "$NODE_TRANSACTION_DIR/pending" || {
        remove_node_transaction_dir || true
        return 1
    }
    chown root:root "$NODE_TRANSACTION_DIR/pending" &&
        chmod 600 "$NODE_TRANSACTION_DIR/pending" || {
        remove_node_transaction_dir || true
        return 1
    }
    sync_node_transaction_store || {
        remove_node_transaction_dir || true
        return 1
    }
    ACTIVE_NODE_BACKUP="$NODE_TRANSACTION_DIR"
    ACTIVE_NODE_TRANSACTION_MUTATED=0
}

mark_node_transaction_mutated() {
    [ "${ACTIVE_NODE_BACKUP:-}" = "$NODE_TRANSACTION_DIR" ] || return 1
    [ -f "$NODE_TRANSACTION_DIR/pending" ] && [ ! -L "$NODE_TRANSACTION_DIR/pending" ] ||
        return 1
    : > "$NODE_TRANSACTION_DIR/mutated" || return 1
    chown root:root "$NODE_TRANSACTION_DIR/mutated" &&
        chmod 600 "$NODE_TRANSACTION_DIR/mutated" || return 1
    sync_node_transaction_store || return 1
    ACTIVE_NODE_TRANSACTION_MUTATED=1
}

cancel_unmodified_node_transaction() {
    local transaction_dir="${ACTIVE_NODE_BACKUP:-}"

    [ -n "$transaction_dir" ] || return 0
    node_transaction_dir_valid "$transaction_dir" || return 1
    [ "${ACTIVE_NODE_TRANSACTION_MUTATED:-0}" = "0" ] || return 1
    [ ! -e "$transaction_dir/mutated" ] || return 1
    ACTIVE_NODE_BACKUP=""
    ACTIVE_NODE_TRANSACTION_MUTATED=0
    remove_node_transaction_dir "$transaction_dir"
}

commit_node_transaction() {
    [ "${ACTIVE_NODE_BACKUP:-}" = "$NODE_TRANSACTION_DIR" ] || return 1
    [ -f "$NODE_TRANSACTION_DIR/pending" ] && [ ! -L "$NODE_TRANSACTION_DIR/pending" ] || return 1
    : > "$NODE_TRANSACTION_DIR/committed" || return 1
    chown root:root "$NODE_TRANSACTION_DIR/committed" &&
        chmod 600 "$NODE_TRANSACTION_DIR/committed" || return 1
    sync_node_transaction_store || return 1
    # committed 标记完成持久化后即越过核心提交点。后续只清理事务痕迹，
    # 即使失败也必须保留新节点状态，并交由下次启动按 committed 语义清理。
    ACTIVE_NODE_BACKUP=""
    ACTIVE_NODE_TRANSACTION_MUTATED=0
    if ! rm -f -- "$NODE_TRANSACTION_DIR/pending"; then
        warn "节点事务已提交，但 pending 标记未能清理：$NODE_TRANSACTION_DIR/pending"
        return 0
    fi
    if ! sync_node_transaction_store; then
        warn "节点事务已提交，但清理状态未能持久化：$NODE_TRANSACTION_DIR"
        return 0
    fi
    remove_node_transaction_dir || {
        warn "节点事务已提交，但临时目录未能清理：$NODE_TRANSACTION_DIR"
        return 0
    }
}

restore_node_file_from_backup() {
    local backup_dir="$1" entry="$2" snapshot="$3" target="$4" status

    if node_backup_entry_is_present "$backup_dir/manifest" "$entry"; then
        restore_file_atomically_from_snapshot "$snapshot" "$target"
        return $?
    else
        status=$?
    fi
    [ "$status" -eq 1 ] || return 1
    remove_snapshot_target_file "$target"
}

restore_node_config_dir_from_backup() {
    local backup_dir="$1" validation_spec="${2:-full}" status

    if [ -L "$NODE_CONFIG_DIR" ] && [ -e "$NODE_CONFIG_DIR" ]; then
        err "当前节点配置目录是符号链接，已拒绝覆盖：$NODE_CONFIG_DIR"
        return 1
    fi
    if [ -e "$NODE_CONFIG_DIR" ] && [ ! -L "$NODE_CONFIG_DIR" ] &&
        ! node_config_dir_restore_target_safe "$validation_spec"; then
        err "当前节点配置目录不安全或包含未知文件，已拒绝覆盖：$NODE_CONFIG_DIR"
        return 1
    fi
    if node_backup_entry_is_present "$backup_dir/manifest" vpsbox.d; then
        if [ -L "$NODE_CONFIG_DIR" ]; then
            rm -f -- "$NODE_CONFIG_DIR" || return 1
        fi
        if [ ! -e "$NODE_CONFIG_DIR" ]; then
            install -d -o root -g root -m 700 "$NODE_CONFIG_DIR" || return 1
        fi
        node_dir_is_secure "$NODE_CONFIG_DIR" || return 1
        restore_node_file_from_backup "$backup_dir" "vpsbox.d/${SS_CONFIG_PATH##*/}" \
            "$backup_dir/vpsbox.d/${SS_CONFIG_PATH##*/}" "$SS_CONFIG_PATH" || return 1
        restore_node_file_from_backup "$backup_dir" "vpsbox.d/${VLESS_CONFIG_PATH##*/}" \
            "$backup_dir/vpsbox.d/${VLESS_CONFIG_PATH##*/}" "$VLESS_CONFIG_PATH" || return 1
        node_config_dir_contents_valid
        return $?
    else
        status=$?
    fi
    [ "$status" -eq 1 ] || return 1
    restore_node_file_from_backup "$backup_dir" "vpsbox.d/${SS_CONFIG_PATH##*/}" \
        "$backup_dir/vpsbox.d/${SS_CONFIG_PATH##*/}" "$SS_CONFIG_PATH" || return 1
    restore_node_file_from_backup "$backup_dir" "vpsbox.d/${VLESS_CONFIG_PATH##*/}" \
        "$backup_dir/vpsbox.d/${VLESS_CONFIG_PATH##*/}" "$VLESS_CONFIG_PATH" || return 1
    if [ -L "$NODE_CONFIG_DIR" ]; then
        rm -f -- "$NODE_CONFIG_DIR"
    elif [ -e "$NODE_CONFIG_DIR" ]; then
        rmdir -- "$NODE_CONFIG_DIR"
    fi
}

node_config_dir_restore_target_safe() {
    local validation_spec="$1" cleanup_target="" path entries

    case "$validation_spec" in
        full|static)
            node_config_dir_contents_valid
            return $?
            ;;
        cleanup:ss) cleanup_target="$SS_CONFIG_PATH" ;;
        cleanup:vless) cleanup_target="$VLESS_CONFIG_PATH" ;;
        *) return 1 ;;
    esac
    [ -e "$NODE_CONFIG_DIR" ] || return 0
    node_dir_is_secure "$NODE_CONFIG_DIR" || return 1
    entries="$(find "$NODE_CONFIG_DIR" -mindepth 1 -maxdepth 1 -print 2>/dev/null)" ||
        return 1
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        case "$path" in
            "$SS_CONFIG_PATH"|"$VLESS_CONFIG_PATH") ;;
            *) return 1 ;;
        esac
        if [ "$path" = "$cleanup_target" ]; then
            node_cleanup_source_file_is_safe "$path" || return 1
        else
            node_file_is_secure "$path" || return 1
        fi
    done <<< "$entries"
}

restore_node_files() {
    local backup_dir="$1"
    local transaction_dir validation_spec
    local was_active="0"
    local was_enabled="0"
    local failed=0

    transaction_dir="$(dirname "$backup_dir")"
    validation_spec="$(node_transaction_validation_spec "$transaction_dir")" || {
        err "节点事务校验模式不安全或内容无效，已拒绝恢复。"
        return 1
    }
    if ! validate_node_transaction_backup "$backup_dir" "$validation_spec"; then
        err "节点事务备份不完整、不可解析或哈希不匹配，已拒绝覆盖现有节点文件。"
        err "事务备份已保留：$backup_dir"
        return 1
    fi
    was_active="$(cat "$backup_dir/service-running")" || return 1
    was_enabled="$(cat "$backup_dir/service-enabled")" || return 1

    warn "操作未完成，正在恢复操作前的节点配置..."
    service_stop 2>/dev/null || true
    stop_singbox_config_processes 2>/dev/null || true
    if service_manager_is_active || [ -n "$(singbox_config_pids)" ]; then
        err "sing-box 服务或残留进程未能停止，已拒绝覆盖节点文件。"
        err "事务备份已保留：$backup_dir"
        return 1
    fi

    [ "$NODE_CONFIG_DIR" = "$CONFIG_DIR/vpsbox.d" ] || {
        err "节点配置目录异常，已拒绝恢复：$NODE_CONFIG_DIR"
        return 1
    }
    restore_node_config_dir_from_backup "$backup_dir" "$validation_spec" || failed=1
    restore_node_file_from_backup "$backup_dir" ss-state.env "$backup_dir/ss-state.env" "$SS_STATE_FILE" || failed=1
    restore_node_file_from_backup "$backup_dir" vless-state.env "$backup_dir/vless-state.env" "$VLESS_STATE_FILE" || failed=1

    # 文件未完整恢复前保持服务停止，避免用混合的新旧配置重新拉起 sing-box。
    if [ "$failed" -ne 0 ]; then
        err "操作前的节点文件恢复不完整，备份已保留：$backup_dir"
        return 1
    fi

    if is_systemd; then
        restore_node_file_from_backup "$backup_dir" sing-box.service \
            "$backup_dir/sing-box.service" /etc/systemd/system/sing-box.service || failed=1
        systemctl daemon-reload 2>/dev/null || failed=1
    fi

    if [ "$OS" = "alpine" ]; then
        restore_node_file_from_backup "$backup_dir" openrc-sing-box \
            "$backup_dir/openrc-sing-box" /etc/init.d/sing-box || failed=1
    fi

    if [ "$failed" -ne 0 ]; then
        err "操作前的节点服务文件恢复不完整，备份已保留：$backup_dir"
        return 1
    fi

    # 原服务可能使用自定义或旧布局；这里验证服务管理器的 enabled/active 状态，
    # 不要求恢复出的进程必须匹配 vpsbox 的 `run -C vpsbox.d`。
    restore_singbox_service_state "$was_enabled" "$was_active" 0 2>/dev/null || failed=1

    if [ "$failed" -ne 0 ]; then
        err "操作前的节点配置恢复不完整，备份已保留：$backup_dir"
        return 1
    fi
    # v1.0.43 起的旧事务可能仍含 URI 快照；URI 现已按派生缓存处理，
    # 恢复只信任配置和状态，随后安全重建，失败不会掩盖核心恢复结果。
    repair_node_uri_cache_best_effort "节点事务恢复后"
    info "已恢复到创建前状态。"
}

rollback_node_files_transaction() {
    local transaction_dir="${ACTIVE_NODE_BACKUP:-}"

    [ -n "$transaction_dir" ] || return 0
    node_transaction_dir_valid "$transaction_dir" || return 1
    [ -f "$transaction_dir/pending" ] || return 1
    if [ "${ACTIVE_NODE_TRANSACTION_MUTATED:-0}" = "0" ] &&
        [ ! -e "$transaction_dir/mutated" ]; then
        cancel_unmodified_node_transaction
        return $?
    fi
    if ! restore_node_files "$transaction_dir/backup"; then
        return 1
    fi
    ACTIVE_NODE_BACKUP=""
    ACTIVE_NODE_TRANSACTION_MUTATED=0
    remove_node_transaction_dir "$transaction_dir"
}

fail_after_node_rollback() {
    local reason="$1" previous_state="$2"

    if rollback_active_node_transaction; then
        err "$reason；节点配置与 sing-box 已恢复到${previous_state}状态。"
    else
        err "$reason；节点状态未能确认完整恢复，请检查上方错误和事务目录。"
    fi
    return 1
}

rollback_active_node_transaction() {
    local transaction_dir="${ACTIVE_NODE_BACKUP:-}"
    local had_firewall_transition=0

    [ -n "$transaction_dir" ] || return 0
    node_transaction_dir_valid "$transaction_dir" || return 1
    if [ "${ACTIVE_NODE_TRANSACTION_MUTATED:-0}" = "0" ] &&
        [ ! -e "$transaction_dir/mutated" ]; then
        cancel_unmodified_node_transaction
        return $?
    fi
    [ -n "${ACTIVE_FIREWALL_TRANSITION_DIR:-}" ] && had_firewall_transition=1
    if ! restore_node_files "$transaction_dir/backup"; then
        ACTIVE_NODE_BACKUP=""
        ACTIVE_NODE_TRANSACTION_MUTATED=0
        return 1
    fi
    if [ "$had_firewall_transition" -eq 1 ] &&
        declare -F firewall_abort_port_transition >/dev/null 2>&1; then
        firewall_abort_port_transition || {
            warn "节点已恢复，但主机防火墙临时规则未能同步；请进入 [4] 主机防火墙执行一键开启/更新。"
        }
    elif declare -F firewall_refresh_if_enabled >/dev/null 2>&1; then
        firewall_refresh_if_enabled || {
            warn "节点已恢复，但主机防火墙端口未能同步；请进入 [4] 主机防火墙执行一键开启/更新。"
        }
    fi
    ACTIVE_NODE_BACKUP=""
    ACTIVE_NODE_TRANSACTION_MUTATED=0
    if ! remove_node_transaction_dir "$transaction_dir"; then
        err "节点已经恢复，但事务目录未能清理：$transaction_dir"
        return 1
    fi
}

recover_pending_node_transaction() {
    local had_pending=0

    [ -e "$NODE_TRANSACTION_DIR" ] || return 0
    prepare_node_transaction_store || return 1
    node_transaction_dir_valid "$NODE_TRANSACTION_DIR" || return 1
    [ -d "$NODE_TRANSACTION_DIR" ] && [ ! -L "$NODE_TRANSACTION_DIR" ] || {
        err "节点事务目录不安全，已拒绝启动：$NODE_TRANSACTION_DIR"
        return 1
    }
    if [ -f "$NODE_TRANSACTION_DIR/committed" ]; then
        node_file_is_secure "$NODE_TRANSACTION_DIR/committed" || {
            err "节点事务 committed 标记不安全，已拒绝自动处理。"
            return 1
        }
        remove_node_transaction_dir
        return
    fi
    if [ -f "$NODE_TRANSACTION_DIR/pending" ]; then
        node_file_is_secure "$NODE_TRANSACTION_DIR/pending" || {
            err "节点事务 pending 标记不安全，已拒绝自动恢复。"
            return 1
        }
        had_pending=1
    fi
    if [ "$had_pending" -eq 0 ]; then
        # 没有 pending 表示上次只创建了未完成备份，尚未开始修改节点。
        remove_node_transaction_dir
        return
    fi
    if [ ! -e "$NODE_TRANSACTION_DIR/mutated" ]; then
        # pending 已持久化但还没有首次真实修改时，硬中断只需丢弃备份。
        remove_node_transaction_dir
        return
    fi
    node_file_is_secure "$NODE_TRANSACTION_DIR/mutated" || {
        err "节点事务 mutated 标记不安全，已拒绝自动恢复。"
        return 1
    }
    [ -d "$NODE_TRANSACTION_BACKUP" ] && [ ! -L "$NODE_TRANSACTION_BACKUP" ] || {
        err "待恢复节点事务缺少可信备份，已拒绝启动。"
        return 1
    }
    warn "检测到上次未提交的节点事务，正在优先恢复..."
    ACTIVE_NODE_BACKUP="$NODE_TRANSACTION_DIR"
    ACTIVE_NODE_TRANSACTION_MUTATED=1
    if ! restore_node_files "$NODE_TRANSACTION_BACKUP"; then
        ACTIVE_NODE_BACKUP=""
        ACTIVE_NODE_TRANSACTION_MUTATED=0
        err "未提交节点事务恢复失败，备份已保留；修复前禁止继续覆盖节点文件。"
        return 1
    fi
    if declare -F firewall_refresh_if_enabled >/dev/null 2>&1 &&
        ! firewall_refresh_if_enabled; then
        warn "节点配置与服务状态已恢复，但主机防火墙端口未能同步；请进入 [4] 主机防火墙执行一键开启/更新。"
    fi
    ACTIVE_NODE_BACKUP=""
    ACTIVE_NODE_TRANSACTION_MUTATED=0
    if ! remove_node_transaction_dir; then
        err "节点已经恢复，但事务目录未能清理：$NODE_TRANSACTION_DIR"
        return 1
    fi
    info "未提交节点事务的节点配置与服务状态已恢复。"
}

port_in_use_tcp() {
    local port="$1" output

    command -v ss >/dev/null 2>&1 || return 2
    output="$(ss -H -ltn 2>/dev/null)" || return 2
    printf '%s\n' "$output" |
        awk -v port="$port" '$4 ~ ("[:.]" port "$") { found=1 } END { exit !found }'
}

port_in_use_udp() {
    local port="$1" output

    command -v ss >/dev/null 2>&1 || return 2
    output="$(ss -H -lun 2>/dev/null)" || return 2
    printf '%s\n' "$output" |
        awk -v port="$port" '$4 ~ ("[:.]" port "$") { found=1 } END { exit !found }'
}

port_in_use_for_protocols() {
    local port="$1" protocols="${2:-both}"
    local tcp_status udp_status

    case "$protocols" in
        tcp) port_in_use_tcp "$port" ;;
        udp) port_in_use_udp "$port" ;;
        both)
            if port_in_use_tcp "$port"; then
                tcp_status=0
            else
                tcp_status=$?
            fi
            if port_in_use_udp "$port"; then
                udp_status=0
            else
                udp_status=$?
            fi
            if [ "$tcp_status" -eq 0 ] || [ "$udp_status" -eq 0 ]; then
                return 0
            fi
            if [ "$tcp_status" -gt 1 ] || [ "$udp_status" -gt 1 ]; then
                return 2
            fi
            return 1
            ;;
        *) return 2 ;;
    esac
}

port_in_use() {
    port_in_use_for_protocols "$1" both
}

port_conflicts_with_existing_node() {
    local port="$1" desired="$2" existing="$3"

    [ "$desired" = "$existing" ] && return 1
    port_in_use_for_protocols "$port" "$desired"
}

port_listener_ready() {
    local port="$1" protocols="${2:-both}"

    case "$protocols" in
        tcp) port_in_use_tcp "$port" ;;
        udp) port_in_use_udp "$port" ;;
        both) port_in_use_tcp "$port" && port_in_use_udp "$port" ;;
        *) return 2 ;;
    esac
}

wait_for_port_listener() {
    local port="$1" protocols="${2:-both}" i
    for i in 1 2 3 4 5; do
        port_listener_ready "$port" "$protocols" && return 0
        sleep 1
    done
    return 1
}

ipv6_listen_available() {
    [ -r /proc/net/if_inet6 ] || return 1
    [ -s /proc/net/if_inet6 ] || return 1

    if [ -r /proc/sys/net/ipv6/conf/all/disable_ipv6 ] &&
        [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" = "1" ]; then
        return 1
    fi
}

ipv6_bindv6only_value() {
    local value

    value="$(sysctl -n net.ipv6.bindv6only 2>/dev/null || cat /proc/sys/net/ipv6/bindv6only 2>/dev/null || echo 0)"
    case "$value" in
        1) echo "1" ;;
        *) echo "0" ;;
    esac
}

listen_mode() {
    if ipv6_listen_available; then
        if [ "$(ipv6_bindv6only_value)" = "1" ]; then
            echo "dual"
        else
            echo "ipv6"
        fi
    else
        echo "ipv4"
    fi
}

random_port() {
    local port docker_ports protocols="${2:-both}" reserved_node_ports="${3:-}"
    local i status

    command -v ss >/dev/null 2>&1 || {
        err "缺少 ss，无法可靠检查节点端口占用。"
        return 1
    }
    if ! ssh_effective_ports_csv >/dev/null 2>&1; then
        err "无法读取 SSH 当前生效端口，已取消随机端口选择。"
        return 1
    fi
    if [ "$#" -ge 1 ]; then
        docker_ports="$1"
    else
        docker_ports="$(docker_reserved_ports_csv "$protocols")" || {
            err "无法可靠读取 Docker 已发布端口，已取消随机端口选择。"
            return 1
        }
    fi
    for i in $(seq 1 100); do
        port="$(shuf -i "${PORT_MIN}-${PORT_MAX}" -n 1 2>/dev/null || echo $((RANDOM % (PORT_MAX - PORT_MIN + 1) + PORT_MIN)))"
        if port_in_use_for_protocols "$port" "$protocols"; then
            continue
        else
            status=$?
            [ "$status" -eq 1 ] || {
                err "无法检查端口 $port 的监听状态，已取消随机端口选择。"
                return 1
            }
        fi
        if port_is_effective_ssh_port "$port"; then
            continue
        else
            status=$?
            [ "$status" -eq 1 ] || {
                err "无法读取 SSH 当前生效端口，已取消随机端口选择。"
                return 1
            }
        fi
        if ! csv_contains_port "$docker_ports" "$port" &&
            ! csv_contains_port "$reserved_node_ports" "$port"; then
            echo "$port"
            return 0
        fi
    done
    err "连续 100 次未找到可用随机端口。"
    return 1
}

normalize_port_decimal() {
    local port="${1:-}" normalized

    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    normalized="${port#"${port%%[!0]*}"}"
    [ -n "$normalized" ] || normalized=0
    [ "${#normalized}" -le 5 ] || return 1
    [ "$normalized" -ge 1 ] && [ "$normalized" -le 65535 ] || return 1
    printf '%s\n' "$normalized"
}

is_valid_port() {
    local normalized

    normalized="$(normalize_port_decimal "${1:-}")" || return 1
    # 交互输入使用规范十进制，避免 00080 进入 JSON、状态文件或 nftables 后产生不同表示。
    [ "$normalized" = "$1" ]
}

port_is_effective_ssh_port() {
    local port="$1" ports

    ports="$(ssh_effective_ports_csv 2>/dev/null)" || return 2
    case ",$ports," in
        *",$port,"*) return 0 ;;
        *) return 1 ;;
    esac
}

choose_node_port() {
    local existing_port="${1:-}" protocols="${2:-both}" existing_protocols="${3:-}"
    local reserved_node_ports="${4:-}"
    local input confirm docker_ports managed_pids status

    command -v ss >/dev/null 2>&1 || {
        err "缺少 ss，无法可靠检查节点端口占用。"
        return 1
    }
    ssh_effective_ports_csv >/dev/null 2>&1 || {
        err "无法读取 SSH 当前生效端口，已取消节点端口选择。"
        return 1
    }

    docker_ports="$(docker_reserved_ports_for_port_choice "$protocols")" || {
        err "无法可靠读取 Docker 已发布端口，已取消节点端口选择。"
        return 1
    }

    while true; do
        if [ -n "$existing_port" ]; then
            printf '请输入节点端口（留空自动随机；当前端口 %s 可保留）: ' "$existing_port" >&2
        else
            printf '请输入节点端口（1-65535，留空自动随机）: ' >&2
        fi
        read -r input || return 1
        if [ -z "$input" ]; then
            random_port "$docker_ports" "$protocols" "$reserved_node_ports"
            return $?
        fi
        if ! is_valid_port "$input"; then
            err "端口必须是 1-65535 的整数。"
            continue
        fi
        if port_is_effective_ssh_port "$input"; then
            err "端口 $input 是当前 SSH 生效端口，不能用于节点。"
            continue
        else
            status=$?
            if [ "$status" -ne 1 ]; then
                err "无法读取 SSH 当前生效端口，已取消节点端口选择。"
                return 1
            fi
        fi
        if csv_contains_port "$reserved_node_ports" "$input"; then
            err "端口 $input 已被另一个节点使用，请更换。"
            continue
        fi
        managed_pids="$(singbox_config_pids || true)"
        status=1
        if [ "$input" = "$existing_port" ] && [ -n "$managed_pids" ]; then
            if port_conflicts_with_existing_node "$input" "$protocols" "$existing_protocols"; then
                status=0
            else
                status=$?
            fi
        elif port_in_use_for_protocols "$input" "$protocols"; then
            status=0
        else
            status=$?
        fi
        case "$status" in
            0)
                err "端口 $input 已被占用，请更换。"
                continue
                ;;
            1) ;;
            *)
                err "无法检查端口 $input 的监听状态，已取消节点端口选择。"
                return 1
                ;;
        esac
        if csv_contains_port "$docker_ports" "$input"; then
            err "端口 $input 已被 Docker 发布规则占用，请更换。"
            continue
        fi
        if [ "$input" -lt 1024 ]; then
            if ! read -r -p "端口 $input 属于特权端口，确认使用？请输入 YES：" confirm; then
                info "输入已结束，已取消节点端口选择。"
                return 1
            fi
            [ "$confirm" = "YES" ] || continue
        fi
        printf '%s\n' "$input"
        return 0
    done
}

configured_node_ports_csv() {
    local exclude_protocol="${1:-}" protocol result=""

    for protocol in ss vless; do
        [ "$protocol" != "$exclude_protocol" ] || continue
        if load_protocol_state "$protocol" >/dev/null 2>&1; then
            result="$(csv_add_port "$result" "$PORT")" || return 1
        fi
    done
    printf '%s\n' "$result"
}

random_password() {
    if singbox_installed; then
        sing-box generate rand --base64 16 2>/dev/null | tr -d '\n\r' && return 0
    fi

    openssl rand -base64 16 2>/dev/null | tr -d '\n\r' && return 0
    head -c 16 /dev/urandom | base64 | tr -d '\n\r'
}

write_shadowsocks_inbound_json() {
    local tag="$1"
    local listen="$2"
    local port="$3"
    local password="$4"
    local suffix="${5:-}"

    # --- BEGIN GENERATED TEMPLATE: Shadowsocks inbound JSON ---
    cat <<EOF
    {
      "type": "shadowsocks",
      "tag": "$tag",
      "listen": "$listen",
      "listen_port": $port,
      "method": "$SS_METHOD",
      "password": "$password"
    }$suffix
EOF
    # --- END GENERATED TEMPLATE: Shadowsocks inbound JSON ---
}

write_config() {
    local port="$1"
    local password="$2"
    local config_id="$3"
    local dest="${4:-$SS_CONFIG_PATH}"
    local mode tmp

    [[ "$config_id" =~ ^[0-9a-f]{24}$ ]] || return 1
    if [ "$dest" = "$SS_CONFIG_PATH" ]; then
        secure_node_config_dir || return 1
    else
        secure_config_dir || return 1
        [ -d "${dest%/*}" ] && [ ! -L "${dest%/*}" ] || return 1
    fi
    mode="$(listen_mode)"

    case "$mode" in
        ipv6)
            info "监听地址：::（IPv4/IPv6 双栈）"
            ;;
        dual)
            info "监听地址：0.0.0.0 + ::（系统启用了 IPv6-only 监听）"
            ;;
        *)
            info "监听地址：0.0.0.0"
            ;;
    esac

    tmp="$(mktemp "$CONFIG_DIR/.10-ss.XXXXXX")" || return 1
    # --- BEGIN GENERATED TEMPLATE: Shadowsocks node JSON ---
    cat > "$tmp" <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
EOF
    case "$mode" in
        ipv6)
            write_shadowsocks_inbound_json "vpsbox-${config_id}-ss-in" "::" "$port" "$password" >> "$tmp"
            ;;
        dual)
            write_shadowsocks_inbound_json "vpsbox-${config_id}-ss-in-ipv4" "0.0.0.0" "$port" "$password" "," >> "$tmp"
            write_shadowsocks_inbound_json "vpsbox-${config_id}-ss-in-ipv6" "::" "$port" "$password" >> "$tmp"
            ;;
        *)
            write_shadowsocks_inbound_json "vpsbox-${config_id}-ss-in" "0.0.0.0" "$port" "$password" >> "$tmp"
            ;;
    esac

    cat >> "$tmp" <<EOF
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct-${config_id}-ss"
    }
  ]
}
EOF
    # --- END GENERATED TEMPLATE: Shadowsocks node JSON ---
    if ! chown root:root "$tmp" ||
        ! chmod 600 "$tmp" ||
        ! sing-box check -c "$tmp" >/dev/null ||
        ! mv -f -- "$tmp" "$dest"; then
        rm -f -- "$tmp"
        return 1
    fi
}

write_vless_reality_inbound_json() {
    local tag="$1" listen="$2" port="$3" uuid="$4" server_name="$5" private_key="$6" short_id="$7" suffix="${8:-}"

    # --- BEGIN GENERATED TEMPLATE: VLESS Reality inbound JSON ---
    cat <<EOF
    {
      "type": "vless",
      "tag": "$tag",
      "listen": "$listen",
      "listen_port": $port,
      "users": [
        {
          "name": "vpsbox",
          "uuid": "$uuid",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$server_name",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "$server_name",
            "server_port": 443
          },
          "private_key": "$private_key",
          "short_id": ["$short_id"]
        }
      }
    }$suffix
EOF
    # --- END GENERATED TEMPLATE: VLESS Reality inbound JSON ---
}

write_vless_reality_config() {
    local port="$1" uuid="$2" server_name="$3" private_key="$4" short_id="$5"
    local config_id="$6" dest="${7:-$VLESS_CONFIG_PATH}" mode tmp

    [[ "$config_id" =~ ^[0-9a-f]{24}$ ]] || return 1
    if [ "$dest" = "$VLESS_CONFIG_PATH" ]; then
        secure_node_config_dir || return 1
    else
        secure_config_dir || return 1
        [ -d "${dest%/*}" ] && [ ! -L "${dest%/*}" ] || return 1
    fi
    mode="$(listen_mode)"
    case "$mode" in
        ipv6) info "监听地址：::（IPv4/IPv6 双栈）" ;;
        dual) info "监听地址：0.0.0.0 + ::（系统启用了 IPv6-only 监听）" ;;
        *) info "监听地址：0.0.0.0" ;;
    esac

    tmp="$(mktemp "$CONFIG_DIR/.20-vless-reality.XXXXXX")" || return 1
    # --- BEGIN GENERATED TEMPLATE: VLESS Reality node JSON ---
    cat > "$tmp" <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
EOF
    case "$mode" in
        ipv6) write_vless_reality_inbound_json "vpsbox-${config_id}-vless-reality-in" "::" "$port" "$uuid" "$server_name" "$private_key" "$short_id" >> "$tmp" ;;
        dual)
            write_vless_reality_inbound_json "vpsbox-${config_id}-vless-reality-in-ipv4" "0.0.0.0" "$port" "$uuid" "$server_name" "$private_key" "$short_id" "," >> "$tmp"
            write_vless_reality_inbound_json "vpsbox-${config_id}-vless-reality-in-ipv6" "::" "$port" "$uuid" "$server_name" "$private_key" "$short_id" >> "$tmp"
            ;;
        *) write_vless_reality_inbound_json "vpsbox-${config_id}-vless-reality-in" "0.0.0.0" "$port" "$uuid" "$server_name" "$private_key" "$short_id" >> "$tmp" ;;
    esac
    cat >> "$tmp" <<EOF
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct-${config_id}-vless"
    }
  ]
}
EOF
    # --- END GENERATED TEMPLATE: VLESS Reality node JSON ---
    if ! chown root:root "$tmp" ||
        ! chmod 600 "$tmp" ||
        ! sing-box check -c "$tmp" >/dev/null ||
        ! mv -f -- "$tmp" "$dest"; then
        rm -f -- "$tmp"
        return 1
    fi
}

generate_node_config_id() {
    local config_id

    config_id="$(sing-box generate rand 12 --hex 2>/dev/null | tr -d '\r\n')" || return 1
    [[ "$config_id" =~ ^[0-9a-f]{24}$ ]] || return 1
    printf '%s\n' "$config_id"
}

prepare_node_stage() {
    [ "${ACTIVE_NODE_BACKUP:-}" = "$NODE_TRANSACTION_DIR" ] || return 1
    [ "$NODE_TRANSACTION_STAGE" = "$NODE_TRANSACTION_DIR/stage" ] || return 1
    rm -rf -- "$NODE_TRANSACTION_STAGE" || return 1
    mkdir -p "$NODE_TRANSACTION_STAGE/configs" \
        "$NODE_TRANSACTION_STAGE/states" || return 1
    chown -R root:root "$NODE_TRANSACTION_STAGE" || return 1
    chmod 700 "$NODE_TRANSACTION_STAGE" "$NODE_TRANSACTION_STAGE/configs" \
        "$NODE_TRANSACTION_STAGE/states"
}

stage_sibling_node_config() {
    local target_protocol="$1"
    local protocol source

    for protocol in ss vless; do
        [ "$protocol" != "$target_protocol" ] || continue
        if protocol_node_exists "$protocol"; then
            source="$(node_config_path "$protocol")" || return 1
            cp -- "$source" "$NODE_TRANSACTION_STAGE/configs/${source##*/}" || return 1
            chown root:root "$NODE_TRANSACTION_STAGE/configs/${source##*/}" &&
                chmod 600 "$NODE_TRANSACTION_STAGE/configs/${source##*/}" || return 1
        fi
    done
}

validate_staged_node() {
    local target_protocol="$1"
    local protocol config state final_path

    case "$target_protocol" in
        ss|vless) ;;
        *) return 2 ;;
    esac
    for protocol in ss vless; do
        final_path="$(node_config_path "$protocol")" || return 1
        config="$NODE_TRANSACTION_STAGE/configs/${final_path##*/}"
        final_path="$(node_state_path "$protocol")" || return 1
        if [ "$protocol" = "$target_protocol" ]; then
            state="$NODE_TRANSACTION_STAGE/states/${final_path##*/}"
        else
            state="$final_path"
        fi

        if [ "$protocol" != "$target_protocol" ] &&
            [ ! -e "$config" ] && [ ! -L "$config" ] &&
            [ ! -e "$state" ] && [ ! -L "$state" ]; then
            continue
        fi
        validate_protocol_node_core \
            "$protocol" "$config" "$state" || return 1
    done
    sing-box check -C "$NODE_TRANSACTION_STAGE/configs" >/dev/null
}

publish_staged_node_file() {
    local source="$1"
    local dest="$2"
    local tmp publish_dir

    [ -f "$source" ] && [ ! -L "$source" ] || return 1
    # 节点配置目录只允许存在两份正式 JSON；受检查的 staging 目录既要避开
    # sing-box 的 -C 扫描范围，也必须与目标位于同一文件系统。
    publish_dir="$(atomic_staging_dir "$dest")" || return 1
    [ -d "$publish_dir" ] && [ ! -L "$publish_dir" ] || return 1
    tmp="$(mktemp "$publish_dir/.vpsbox-node-publish.XXXXXX")" || return 1
    if ! cp -- "$source" "$tmp" ||
        ! chown root:root "$tmp" ||
        ! chmod 600 "$tmp" ||
        ! mv -f -- "$tmp" "$dest"; then
        rm -f -- "$tmp"
        return 1
    fi
}

publish_staged_node() {
    local protocol="$1"
    local config state

    config="$(node_config_path "$protocol")" || return 1
    state="$(node_state_path "$protocol")" || return 1
    prepare_node_layout_for_write || return 1
    publish_staged_node_file \
        "$NODE_TRANSACTION_STAGE/configs/${config##*/}" "$config" || return 1
    publish_staged_node_file \
        "$NODE_TRANSACTION_STAGE/states/${state##*/}" "$state" || return 1
    require_valid_node_state_if_present
}

check_node_config_set() {
    [ -d "$NODE_CONFIG_DIR" ] && [ ! -L "$NODE_CONFIG_DIR" ] || return 1
    { [ -f "$SS_CONFIG_PATH" ] || [ -f "$VLESS_CONFIG_PATH" ]; } || return 1
    node_config_dir_contents_valid || return 1
    sing-box check -C "$NODE_CONFIG_DIR" >/dev/null
}

check_active_node_config() {
    require_valid_node_state_if_present || return 1
    node_exists || return 1
    check_node_config_set
}

generate_reality_keypair() {
    local output private_key public_key
    output="$(sing-box generate reality-keypair 2>/dev/null)" || return 1
    private_key="$(printf '%s\n' "$output" | awk -F': *' '/^PrivateKey:/ {print $2; exit}')"
    public_key="$(printf '%s\n' "$output" | awk -F': *' '/^PublicKey:/ {print $2; exit}')"
    [[ "$private_key" =~ ^[A-Za-z0-9_-]{40,60}$ ]] || return 1
    [[ "$public_key" =~ ^[A-Za-z0-9_-]{40,60}$ ]] || return 1
    printf '%s\n%s\n' "$private_key" "$public_key"
}

reality_now_ns() {
    local result_name="$1" stamp seconds fraction

    stamp="${EPOCHREALTIME:-}"
    if [[ "$stamp" =~ ^([0-9]+)\.([0-9]+)$ ]]; then
        seconds="${BASH_REMATCH[1]}"
        fraction="${BASH_REMATCH[2]}000000"
        fraction="${fraction:0:6}"
        printf -v "$result_name" '%s%s000' "$seconds" "$fraction"
        return 0
    fi

    stamp="$(date +%s%N 2>/dev/null)" || return 1
    [[ "$stamp" =~ ^[0-9]+$ ]] || return 1
    [ "${#stamp}" -le 19 ] || return 1
    printf -v "$result_name" '%s' "$stamp"
}

reality_remaining_seconds() {
    local deadline_ns="$1" result_name="$2" now_ns remaining_ns remaining_seconds

    [[ "$deadline_ns" =~ ^[0-9]+$ ]] || return 1
    reality_now_ns now_ns || return 1
    remaining_ns=$((deadline_ns - now_ns))
    ((remaining_ns > 0)) || return 1
    remaining_seconds=$(((remaining_ns + 999999999) / 1000000000))
    ((remaining_seconds <= REALITY_POOL_PROBE_TIMEOUT)) ||
        remaining_seconds="$REALITY_POOL_PROBE_TIMEOUT"
    printf -v "$result_name" '%s' "$remaining_seconds"
}

reality_tls_probe_supported() {
    local help_output

    command -v openssl >/dev/null 2>&1 || return 1
    help_output="$(openssl s_client -help 2>&1 || true)"
    grep -Eq '(^|[[:space:]])-tls1_3([[:space:]]|$)' <<< "$help_output" || return 1
    grep -Eq '(^|[[:space:]])-alpn([[:space:]]|$)' <<< "$help_output"
}

run_reality_tls_probe() {
    local server_name="$1" connect_host="$2" time_limit="$3"
    local endpoint output

    [[ "$time_limit" =~ ^[1-9][0-9]*$ ]] || return 1
    endpoint="$(uri_host "$connect_host")" || return 1
    if ! output="$(run_bounded_command "$time_limit" openssl s_client \
        -connect "${endpoint}:443" -servername "$server_name" \
        -tls1_3 -alpn h2,http/1.1 \
        </dev/null 2>&1)"; then
        return 1
    fi
    grep -Eq '^ALPN protocol: h2\r?$' <<< "$output" || return 2
}

check_reality_server() {
    local server_name="$1"

    is_domain_name "$server_name" || return 1
    resolve_host_ips "$server_name" | grep -q . || return 1
    command -v openssl >/dev/null 2>&1 || {
        err "未找到 openssl，无法验证 Reality 目标的 TLS 1.3 与 H2。"
        return 1
    }
    run_reality_tls_probe "$server_name" "$server_name" 12
}

read_reality_cloudflare_trace() {
    local server_name="$1"

    command -v curl >/dev/null 2>&1 || return 1
    # head 达到上限后会关闭管道，curl 可能因此返回 23；保留已读取正文并继续判断。
    curl -q -sS \
        --connect-timeout "$REALITY_CLOUDFLARE_CHECK_TIMEOUT" \
        --max-time "$REALITY_CLOUDFLARE_CHECK_TIMEOUT" \
        "https://${server_name}/cdn-cgi/trace" 2>/dev/null |
        head -c "$REALITY_CLOUDFLARE_RESPONSE_LIMIT" |
        tr -d '\000'
}

reality_target_uses_cloudflare() {
    local server_name="$1" response

    is_domain_name "$server_name" || return 1
    if ! response="$(read_reality_cloudflare_trace "$server_name")"; then
        :
    fi

    response="${response//$'\r'/}"
    grep -Eq '^fl=[^[:space:]]+$' <<< "$response" &&
        grep -Fqix "h=$server_name" <<< "$response" &&
        grep -Eq '^colo=[A-Z]{3}$' <<< "$response"
}

probe_reality_candidate_latency() {
    local server_name="$1" total_start_ns deadline_ns dns_limit resolved
    local probe_start_ns end_ns elapsed_ns latency_ms attempt_limit ip
    local -a resolved_ips=() candidate_ips=()

    is_domain_name "$server_name" || return 1
    command -v openssl >/dev/null 2>&1 || return 1
    reality_now_ns total_start_ns || return 1
    deadline_ns=$((total_start_ns + REALITY_POOL_PROBE_TIMEOUT * 1000000000))
    reality_remaining_seconds "$deadline_ns" dns_limit || return 1
    resolved="$(resolve_host_ips "$server_name" "$dns_limit" 2>/dev/null)" || return 1
    [ -n "$resolved" ] || return 1
    mapfile -t resolved_ips <<< "$resolved"
    for ip in "${resolved_ips[@]}"; do
        is_ip_address "$ip" && candidate_ips+=("$ip")
    done
    [ "${#candidate_ips[@]}" -gt 0 ] || return 1
    reality_now_ns probe_start_ns || return 1

    for ip in "${candidate_ips[@]}"; do
        reality_remaining_seconds "$deadline_ns" attempt_limit || return 1
        if run_reality_tls_probe "$server_name" "$ip" "$attempt_limit" 2>/dev/null; then
            reality_now_ns end_ns || return 1
            ((end_ns <= deadline_ns)) || return 1
            elapsed_ns=$((end_ns - probe_start_ns))
            ((elapsed_ns >= 0)) || return 1
            latency_ms=$((elapsed_ns / 1000000))
            ((latency_ms > 0)) || latency_ms=1
            printf '%s\n' "$latency_ms"
            return 0
        fi
    done
    return 1
}

select_fastest_reality_server() {
    local server_result_name="$1" latency_result_name="$2"
    local candidate_server candidate_latency best_server="" best_latency=""

    for candidate_server in "${REALITY_SERVER_POOL[@]}"; do
        if candidate_latency="$(probe_reality_candidate_latency "$candidate_server" 2>/dev/null)" &&
            [[ "$candidate_latency" =~ ^[0-9]+$ ]]; then
            if [ -z "$best_server" ] || ((candidate_latency < best_latency)); then
                best_server="$candidate_server"
                best_latency="$candidate_latency"
            fi
        fi
    done

    [ -n "$best_server" ] || return 1
    printf -v "$server_result_name" '%s' "$best_server"
    printf -v "$latency_result_name" '%s' "$best_latency"
}

render_singbox_systemd_service() {
    local bin="$1"

    require_valid_node_state_if_present || return 1
    node_exists || return 1

    # --- BEGIN GENERATED TEMPLATE: sing-box systemd unit ---
    cat <<EOF
[Unit]
Description=Sing-box Proxy Server
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target
Wants=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$CONFIG_DIR
ExecStart=$bin run -C $NODE_CONFIG_DIR
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10s
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    # --- END GENERATED TEMPLATE: sing-box systemd unit ---
}

render_singbox_openrc_service() {
    local bin="$1"

    require_valid_node_state_if_present || return 1
    node_exists || return 1

    # --- BEGIN GENERATED TEMPLATE: sing-box OpenRC service ---
    cat <<EOF
#!/sbin/openrc-run
name="sing-box"
description="Sing-box Proxy Server"
command="$bin"
command_args="run -C $NODE_CONFIG_DIR"
command_background="yes"
pidfile="/run/sing-box.pid"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.err"
supervisor=supervise-daemon
supervise_daemon_args="--respawn-max 0 --respawn-delay 5"

depend() {
    need net
}
EOF
    # --- END GENERATED TEMPLATE: sing-box OpenRC service ---
}

publish_singbox_service_definition() {
    local renderer="$1" bin="$2" target="$3" mode="$4"
    local tmp

    [ -n "$bin" ] && [ -x "$bin" ] || return 1
    [ ! -L "$target" ] || return 1
    tmp="$(mktemp)" || return 1
    if ! "$renderer" "$bin" > "$tmp" ||
        ! install_root_file_atomically "$tmp" "$target" "$mode"; then
        rm -f -- "$tmp"
        return 1
    fi
    rm -f -- "$tmp"
}

singbox_service_definition_is_current() {
    local bin

    bin="$(command -v sing-box 2>/dev/null)" || return 1
    if is_systemd; then
        [ -f /etc/systemd/system/sing-box.service ] &&
            [ ! -L /etc/systemd/system/sing-box.service ] || return 1
        render_singbox_systemd_service "$bin" |
            cmp -s - /etc/systemd/system/sing-box.service
    elif [ "$OS" = "alpine" ] && command -v rc-service >/dev/null 2>&1; then
        [ -f /etc/init.d/sing-box ] && [ ! -L /etc/init.d/sing-box ] || return 1
        render_singbox_openrc_service "$bin" | cmp -s - /etc/init.d/sing-box
    else
        return 1
    fi
}

setup_service() {
    local bin
    bin="$(command -v sing-box 2>/dev/null)" || {
        err "未找到 sing-box 可执行文件，无法创建服务。"
        return 1
    }
    [ -x "$bin" ] || {
        err "sing-box 文件不可执行，无法创建服务：$bin"
        return 1
    }

    if is_systemd; then
        [ ! -L /etc/systemd/system/sing-box.service ] || { err "sing-box systemd 服务文件是符号链接，已拒绝覆盖。"; return 1; }
        publish_singbox_service_definition \
            render_singbox_systemd_service "$bin" \
            /etc/systemd/system/sing-box.service 644 || {
            err "无法安全写入 sing-box systemd 服务文件。"
            return 1
        }
        retry 3 2 systemctl daemon-reload || return 1
        service_enable || return 1
        return 0
    elif [ "$OS" = "alpine" ] && command -v rc-service >/dev/null 2>&1; then
        [ ! -L /etc/init.d/sing-box ] || { err "sing-box OpenRC 服务文件是符号链接，已拒绝覆盖。"; return 1; }
        publish_singbox_service_definition \
            render_singbox_openrc_service "$bin" \
            /etc/init.d/sing-box 755 || {
            err "无法安全写入 sing-box OpenRC 服务文件。"
            return 1
        }
        service_enable || return 1
        return 0
    else
        err "未检测到 systemd/OpenRC，无法创建服务。"
        return 1
    fi
}

prepare_node_layout_for_write() {
    # vpsbox 服务只加载 vpsbox.d；软件包或用户自己的 config.json 不参与节点布局。
    secure_node_config_dir
}

verify_all_node_runtime() {
    local protocol protocols

    service_is_running || return 1
    for protocol in vless ss; do
        protocol_visible_exists "$protocol" || continue
        load_protocol_state "$protocol" || return 1
        if [ "$protocol" = "vless" ]; then
            [ -n "${REALITY_PRIVATE_KEY:-}" ] || return 1
            protocols=tcp
        else
            protocols=both
        fi
        wait_for_port_listener "$PORT" "$protocols" || return 1
    done
}

create_or_rebuild_node() {
    local confirm domain default_name input_name name port password config_id
    local staged_config staged_state
    local existing_port="" existing_protocols="" sibling_ports=""

    ensure_node_dependencies || return 1
    require_valid_node_state_if_present || return 1
    if protocol_visible_exists ss; then
        load_protocol_state ss || return 1
        existing_port="$PORT"
        existing_protocols=both
        warn "检测到已有 Shadowsocks 节点。"
        if ! read -r -p "是否覆盖重建 Shadowsocks 节点？[y/N]: " confirm; then
            info "输入已结束，已取消。"
            return 1
        fi
        [[ "$confirm" =~ ^[Yy]$ ]] || { info "已取消。"; return 0; }
    fi

    sibling_ports="$(configured_node_ports_csv ss)" || {
        err "无法读取 VLESS Reality 节点端口，未创建 Shadowsocks 节点。"
        return 1
    }

    if ! prompt_node_host domain "请输入节点域名或 IP（留空自动检测公网 IPv4）："; then
        info "输入已结束，已取消。"
        return 1
    fi
    default_name="$(default_name_for_host "$domain")"
    while true; do
        read -r -p "请输入节点名称，留空默认 ${default_name}：" input_name ||
            { info "输入已结束，已取消。"; return 1; }
        input_name="$(sanitize_paste_input "$input_name")"
        if [ -n "$input_name" ] && [[ "${input_name,,}" == "${domain,,}"* ]]; then
            err "检测到节点名称包含连接地址前缀，可能是粘贴残留：$input_name"
            err "请重新输入节点名称。"
            continue
        fi
        name="$(sanitize_name "${input_name:-$default_name}")"
        info "已识别节点名称：$name"
        break
    done
    if ! port="$(choose_node_port "$existing_port" both "$existing_protocols" "$sibling_ports")"; then
        err "节点端口选择失败，未创建 Shadowsocks 节点。"
        return 1
    fi
    info "节点端口：$port"

    cat <<EOF
----------------------------------------
 请确认节点信息
 协议：Shadowsocks
 连接地址：$domain
 连接端口：$port
 节点名称：$name
----------------------------------------
EOF
    if ! confirm_default_yes "确认无误并创建？"; then
        info "已取消，未修改现有节点。"
        return 0
    fi

    # 最终确认前不创建事务、不停止服务，也不刷新防火墙；pending 写入后才允许首次修改。
    if ! begin_node_transaction; then
        err "无法创建受保护的节点事务，未修改 Shadowsocks 节点。"
        return 1
    fi
    if ! install_singbox_for_node_transaction; then
        rollback_node_files_transaction || true
        err "sing-box 或节点依赖安装失败，未创建 Shadowsocks 节点。"
        return 1
    fi
    info "正在自动生成随机强密码..."
    if ! password="$(random_password)" || [ -z "$password" ]; then
        rollback_node_files_transaction || true
        err "随机强密码生成失败，未创建 Shadowsocks 节点。"
        return 1
    fi

    config_id="$(generate_node_config_id)" || {
        rollback_node_files_transaction || true
        err "节点配置标识生成失败，未创建 Shadowsocks 节点。"
        return 1
    }
    staged_config="$NODE_TRANSACTION_STAGE/configs/${SS_CONFIG_PATH##*/}"
    staged_state="$NODE_TRANSACTION_STAGE/states/${SS_STATE_FILE##*/}"
    if ! prepare_node_stage ||
        ! stage_sibling_node_config ss ||
        ! write_config "$port" "$password" "$config_id" "$staged_config" ||
        ! save_state "$domain" "$name" "$port" "$password" "$config_id" "$staged_state" ||
        ! validate_staged_node ss; then
        rollback_node_files_transaction || true
        err "Shadowsocks 配置或状态预生成校验失败，未修改现有节点。"
        return 1
    fi
    if ! mark_node_transaction_mutated ||
        ! firewall_prepare_port_transition "$port" "$port" "$existing_port" "$existing_port"; then
        fail_after_node_rollback "主机防火墙无法临时放行新节点端口，未创建 Shadowsocks 节点" "创建前" || true
        return 1
    fi
    info "加密方式：$SS_METHOD"
    info "正在写入 Shadowsocks 配置..."
    if ! publish_staged_node ss ||
        ! check_node_config_set ||
        ! setup_service; then
        fail_after_node_rollback "Shadowsocks 配置、状态或服务写入失败" "创建前" || true
        return 1
    fi
    info "正在启动 sing-box 服务..."
    if ! restart_singbox_cleanly || ! verify_all_node_runtime; then
        fail_after_node_rollback "sing-box 未保持运行或节点端口未完整监听" "创建前" || true
        return 1
    fi
    if ! firewall_complete_port_transition; then
        fail_after_node_rollback "主机防火墙未能同步节点端口" "创建前" || true
        return 1
    fi

    if ! commit_node_transaction; then
        fail_after_node_rollback "节点事务提交失败" "创建前" || true
        return 1
    fi
    repair_node_uri_cache_best_effort "创建 Shadowsocks 节点后"
    info "Shadowsocks 节点创建完成，当前节点链接如下："
    view_node_link || {
        err "节点已创建并运行，但链接显示失败，请稍后使用查看节点链接功能重试。"
        return 1
    }
}

create_vless_reality_node() {
    local confirm domain default_name input_name name port input_sni server_name
    local uuid short_id private_key public_key config_id staged_config staged_state
    local existing_port="" existing_protocols="" reality_check_deferred=0 reality_check_status=0
    local sibling_ports="" reality_latency_ms="" reality_probe_capability_checked=0
    local reality_target_is_manual=0
    local -a keypair

    ensure_node_dependencies || return 1
    require_valid_node_state_if_present || return 1
    if protocol_visible_exists vless; then
        load_protocol_state vless || return 1
        existing_port="$PORT"
        existing_protocols=tcp
        warn "检测到已有 VLESS Reality 节点。"
        if ! read -r -p "是否覆盖重建 VLESS Reality 节点？[y/N]: " confirm; then
            info "输入已结束，已取消。"
            return 1
        fi
        [[ "$confirm" =~ ^[Yy]$ ]] || { info "已取消。"; return 0; }
    fi

    sibling_ports="$(configured_node_ports_csv vless)" || {
        err "无法读取 Shadowsocks 节点端口，未创建 VLESS Reality 节点。"
        return 1
    }

    if ! prompt_node_host domain "请输入节点连接地址（域名或 IP，留空自动检测公网 IPv4）："; then
        info "输入已结束，已取消。"
        return 1
    fi
    default_name="$(default_name_for_host "$domain")"
    default_name="vless-${default_name#ss-}"
    while true; do
        read -r -p "请输入节点名称，留空默认 ${default_name}：" input_name ||
            { info "输入已结束，已取消。"; return 1; }
        input_name="$(sanitize_paste_input "$input_name")"
        if [ -n "$input_name" ] && [[ "${input_name,,}" == "${domain,,}"* ]]; then
            err "检测到节点名称包含连接地址前缀，可能是粘贴残留：$input_name"
            err "请重新输入节点名称。"
            continue
        fi
        name="$(sanitize_name "${input_name:-$default_name}")"
        info "已识别节点名称：$name"
        break
    done
    while true; do
        read -r -p "请输入 Reality 目标域名/SNI（留空自动选择）：" input_sni ||
            { info "输入已结束，已取消。"; return 1; }
        input_sni="$(sanitize_paste_input "$input_sni")"
        if [ "$reality_probe_capability_checked" -eq 0 ]; then
            reality_probe_capability_checked=1
            if ! reality_tls_probe_supported; then
                warn "当前 OpenSSL 版本过旧或不支持 TLS 1.3 / ALPN 探测，无法检测 Reality 目标。"
                server_name="$REALITY_PROBE_FALLBACK_SERVER_NAME"
                info "已使用默认 Reality 目标：$server_name"
                reality_check_deferred=0
                break
            fi
        fi
        if [ -z "$input_sni" ]; then
            info "正在自动选择 Reality 目标，请稍候..."
            if select_fastest_reality_server server_name reality_latency_ms; then
                info "已选择 Reality 目标：${server_name}（连接耗时 ${reality_latency_ms} ms）"
                reality_check_deferred=0
                break
            fi
            err "默认域名池中没有可用的 Reality 目标，请手动输入。"
            continue
        fi
        server_name="$(normalize_host "$input_sni")"
        if ! is_domain_name "$server_name"; then
            err "Reality 目标必须是有效域名，不能使用 IP 地址。"
            continue
        fi
        if command -v openssl >/dev/null 2>&1; then
            info "正在检查 Reality 目标的 DNS、TLS 1.3 与 H2 支持..."
            if check_reality_server "$server_name"; then
                reality_check_status=0
            else
                reality_check_status=$?
            fi
            if [ "$reality_check_status" -ne 0 ]; then
                if [ "$reality_check_status" -eq 2 ]; then
                    err "目标域名支持 TLS 1.3，但未协商 H2，请更换。"
                else
                    err "目标域名无法解析或 TLS 1.3 不可达，请更换。"
                fi
                continue
            fi
        else
            reality_check_deferred=1
            info "将在最终确认并补齐依赖后检查 Reality 目标。"
        fi
        reality_target_is_manual=1
        break
    done
    if [ "$reality_target_is_manual" -eq 1 ] &&
        reality_target_uses_cloudflare "$server_name"; then
        warn "检测到该 Reality 目标使用 Cloudflare，可能产生 fallback 转发流量。"
    fi
    if ! port="$(choose_node_port "$existing_port" tcp "$existing_protocols" "$sibling_ports")"; then
        err "节点端口选择失败，未创建 VLESS Reality 节点。"
        return 1
    fi
    info "节点端口：$port"

    cat <<EOF
----------------------------------------
 请确认节点信息
 协议：VLESS Reality
 连接地址：$domain
 连接端口：$port
 Reality 目标：${server_name}:443
 节点名称：$name
----------------------------------------
EOF
    if ! confirm_default_yes "确认无误并创建？"; then
        info "已取消，未修改现有节点。"
        return 0
    fi

    if ! begin_node_transaction; then
        err "无法创建受保护的节点事务，未修改 VLESS Reality 节点。"
        return 1
    fi
    if ! install_singbox_for_node_transaction; then
        rollback_node_files_transaction || true
        err "sing-box 或节点依赖安装失败，未创建 VLESS Reality 节点。"
        return 1
    fi
    if [ "$reality_check_deferred" -eq 1 ]; then
        info "正在检查 Reality 目标的 DNS、TLS 1.3 与 H2 支持..."
        if check_reality_server "$server_name"; then
            reality_check_status=0
        else
            reality_check_status=$?
        fi
        if [ "$reality_check_status" -ne 0 ]; then
            rollback_node_files_transaction || true
            if [ "$reality_check_status" -eq 2 ]; then
                err "目标域名支持 TLS 1.3，但未协商 H2，未创建 VLESS Reality 节点。"
            else
                err "目标域名无法解析或 TLS 1.3 不可达，未创建 VLESS Reality 节点。"
            fi
            return 1
        fi
    fi
    uuid="$(sing-box generate uuid 2>/dev/null | tr -d '\r\n')"
    if [[ ! "$uuid" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
        rollback_node_files_transaction || true
        err "UUID 生成失败，未创建 VLESS Reality 节点。"
        return 1
    fi
    mapfile -t keypair < <(generate_reality_keypair) || true
    if [ "${#keypair[@]}" -ne 2 ]; then
        rollback_node_files_transaction || true
        err "Reality 密钥生成失败，未创建 VLESS Reality 节点。"
        return 1
    fi
    private_key="${keypair[0]}"
    public_key="${keypair[1]}"
    short_id="$(sing-box generate rand 8 --hex 2>/dev/null | tr -d '\r\n')"
    if [[ ! "$short_id" =~ ^[0-9A-Fa-f]{16}$ ]]; then
        rollback_node_files_transaction || true
        err "Reality Short ID 生成失败，未创建 VLESS Reality 节点。"
        return 1
    fi

    config_id="$(generate_node_config_id)" || {
        rollback_node_files_transaction || true
        err "节点配置标识生成失败，未创建 VLESS Reality 节点。"
        return 1
    }
    staged_config="$NODE_TRANSACTION_STAGE/configs/${VLESS_CONFIG_PATH##*/}"
    staged_state="$NODE_TRANSACTION_STAGE/states/${VLESS_STATE_FILE##*/}"
    if ! prepare_node_stage ||
        ! stage_sibling_node_config vless ||
        ! write_vless_reality_config \
            "$port" "$uuid" "$server_name" "$private_key" "$short_id" \
            "$config_id" "$staged_config" ||
        ! save_vless_reality_state \
            "$domain" "$name" "$port" "$uuid" "$server_name" \
            "$private_key" "$public_key" "$short_id" "$config_id" "$staged_state" ||
        ! validate_staged_node vless; then
        rollback_node_files_transaction || true
        err "VLESS Reality 配置或状态预生成校验失败，未修改现有节点。"
        return 1
    fi
    if ! mark_node_transaction_mutated ||
        ! firewall_prepare_port_transition "$port" "" "$existing_port" ""; then
        fail_after_node_rollback "主机防火墙无法临时放行新节点端口，未创建 VLESS Reality 节点" "创建前" || true
        return 1
    fi
    info "正在写入 VLESS Reality 配置..."
    if ! publish_staged_node vless ||
        ! check_node_config_set ||
        ! setup_service; then
        fail_after_node_rollback "VLESS Reality 配置、状态或服务写入失败" "创建前" || true
        return 1
    fi
    info "正在启动 sing-box 服务..."
    if ! restart_singbox_cleanly || ! verify_all_node_runtime; then
        fail_after_node_rollback "sing-box 未保持运行或节点端口未完整监听" "创建前" || true
        return 1
    fi
    if ! firewall_complete_port_transition; then
        fail_after_node_rollback "主机防火墙未能同步节点端口" "创建前" || true
        return 1
    fi

    if ! commit_node_transaction; then
        fail_after_node_rollback "节点事务提交失败" "创建前" || true
        return 1
    fi
    repair_node_uri_cache_best_effort "创建 VLESS Reality 节点后"
    info "VLESS Reality 节点创建完成，当前节点链接如下："
    view_node_link || {
        err "节点已创建并运行，但链接显示失败，请稍后使用查看节点链接功能重试。"
        return 1
    }
}

view_node_link() {
    local protocol label uri status path displayed=0 damaged=0

    if node_core_artifacts_present; then
        require_node_commands "查看节点链接" jq || return 1
    fi
    for path in "$NODE_CONFIG_DIR" "$SS_CONFIG_PATH" "$VLESS_CONFIG_PATH" \
        "$SS_STATE_FILE" "$VLESS_STATE_FILE"; do
        if [ -L "$path" ]; then
            err "检测到节点路径为符号链接，已拒绝显示链接：$path"
            return 1
        fi
    done
    node_config_dir_layout_valid || {
        err "节点配置目录不安全或包含未知文件，已拒绝显示链接：$NODE_CONFIG_DIR"
        return 1
    }

    for protocol in vless ss; do
        label="$(node_protocol_display_name "$protocol")" || return 1
        status="$(protocol_node_status "$protocol")" || return 1
        case "$status" in
            absent) continue ;;
            damaged)
                warn "$label 节点配置残缺、不安全或内容无效，已跳过该节点链接。"
                damaged=1
                continue
                ;;
            normal|deviated) ;;
            *) return 1 ;;
        esac
        load_protocol_state "$protocol" || {
            err "$label 节点状态读取失败，无法显示链接。"
            return 1
        }
        uri="$(generate_link_from_loaded_state)" || {
            err "$label 节点链接生成失败。"
            return 1
        }
        if [ "$protocol" = "vless" ]; then
            cat <<EOF
========================================
 VLESS Reality 节点
========================================
 节点地址：${DOMAIN}:${PORT}
 Reality SNI：${REALITY_SERVER_NAME}
 流控：${FLOW}
----------------------------------------
 链接：
 $uri
========================================
EOF
        else
            cat <<EOF
========================================
 Shadowsocks 节点
========================================
 节点地址：${DOMAIN}:${PORT}
 加密方式：${METHOD}
 密码：${PASSWORD}
----------------------------------------
 链接：
 $uri
========================================
EOF
        fi
        displayed=1
    done
    if [ "$displayed" -eq 1 ]; then
        return 0
    fi
    if [ "$damaged" -eq 1 ]; then
        err "没有可安全显示链接的有效节点。"
        return 1
    fi
    warn "当前没有已创建的节点。"
}

node_cleanup_target_artifacts_safe() {
    local protocol="$1" config state path found=0

    config="$(node_config_path "$protocol")" || return 2
    state="$(node_state_path "$protocol")" || return 2
    for path in "$config" "$state"; do
        if [ -e "$path" ] || [ -L "$path" ]; then
            found=1
            node_cleanup_source_file_is_safe "$path" || {
                err "损坏节点路径不是受保护的 root 普通文件，已拒绝自动删除：$path"
                return 1
            }
        fi
    done
    [ "$found" -eq 1 ]
}

delete_node_protocol() {
    local protocol="$1" label config state node_port="" node_protocols
    local confirm port_status transaction_validation="full" singbox_available=1
    local firewall_drop_udp="" status sibling_protocol sibling_status
    local cleanup_mode=0 port_unknown=0

    case "$protocol" in
        vless)
            label="VLESS Reality"
            node_protocols=tcp
            sibling_protocol=ss
            ;;
        ss)
            label="Shadowsocks"
            node_protocols=both
            sibling_protocol=vless
            ;;
        *) return 2 ;;
    esac
    if node_core_artifacts_present; then
        if command -v sing-box >/dev/null 2>&1; then
            require_node_commands "删除节点" jq ss sha256sum || return 1
        else
            # 仅清理残留配置不需要监听检查，避免为已卸载的 sing-box 强制要求 ss。
            require_node_commands "删除节点" jq sha256sum || return 1
        fi
    fi
    node_config_dir_layout_valid || {
        err "节点配置目录不安全或包含未知文件，已拒绝删除：$NODE_CONFIG_DIR"
        return 1
    }
    status="$(protocol_node_status "$protocol")" || return 1
    case "$status" in
        absent)
            warn "当前没有已创建的 $label 节点。"
            return 0
            ;;
        normal|deviated)
            require_valid_node_state_if_present || return 1
            load_protocol_state "$protocol" || {
                err "$label 节点状态读取失败，已拒绝删除。"
                return 1
            }
            node_port="$PORT"
            ;;
        damaged)
            cleanup_mode=1
            transaction_validation="cleanup:$protocol"
            node_cleanup_target_artifacts_safe "$protocol" || return 1
            sibling_status="$(protocol_node_status "$sibling_protocol")" || return 1
            case "$sibling_status" in
                absent|normal|deviated) ;;
                damaged)
                    err "两个协议的节点均已损坏；为避免批量清理扩大影响，已拒绝自动删除。"
                    return 1
                    ;;
                *) return 1 ;;
            esac
            port_unknown=1
            if command -v sing-box >/dev/null 2>&1 &&
                service_is_running &&
                ! sing-box check -C "$NODE_CONFIG_DIR" >/dev/null 2>&1; then
                err "sing-box 当前仍在运行，但磁盘节点配置无法通过检查；停止服务前无法保证失败回滚后恢复运行。"
                err "请先在 sing-box 管理中停止服务，再重新清理损坏节点。"
                return 1
            fi
            warn "$label 节点配置已损坏；本次只清理固定受管路径，不从损坏内容推断旧端口，并保留可校验事务备份。"
            ;;
        *) return 1 ;;
    esac
    if [ "$protocol" = "ss" ] && [ -n "$node_port" ]; then
        firewall_drop_udp="$node_port"
    fi
    if [ "$cleanup_mode" -eq 1 ]; then
        if ! read -r -p "确认清理损坏的 $label 节点？[y/N]: " confirm; then
            info "输入已结束，已取消。"
            return 1
        fi
    elif ! read -r -p "确认删除 $label 节点？[y/N]: " confirm; then
        info "输入已结束，已取消。"
        return 1
    fi
    [[ "$confirm" =~ ^[Yy]$ ]] || { info "已取消。"; return 0; }

    if ! command -v sing-box >/dev/null 2>&1; then
        singbox_available=0
        [ "$cleanup_mode" -eq 1 ] || transaction_validation="static"
        if service_manager_is_active || [ -n "$(singbox_config_pids)" ]; then
            err "sing-box 未安装，但服务或残留进程仍在运行；为保留回滚能力，已拒绝删除节点。"
            return 1
        fi
        if [ "$cleanup_mode" -eq 1 ]; then
            warn "sing-box 未安装；本次只清理已通过结构与备份校验的损坏节点残留。"
        else
            warn "sing-box 未安装；本次只删除已通过静态完整性校验的残留节点配置。"
        fi
    fi

    if ! begin_node_transaction "$transaction_validation"; then
        err "备份当前节点失败，已取消删除。"
        return 1
    fi
    if ! mark_node_transaction_mutated; then
        fail_after_node_rollback "节点删除事务无法记录首次修改，已取消删除" "删除前" || true
        return 1
    fi
    if [ "$cleanup_mode" -eq 0 ] &&
        ! firewall_prepare_port_transition \
            "" "" "$node_port" "$firewall_drop_udp"; then
        fail_after_node_rollback "主机防火墙无法开始节点删除事务，已取消删除" "删除前" || true
        return 1
    fi

    if [ "$singbox_available" -eq 1 ]; then
        service_stop 2>/dev/null ||
            warn "服务管理器未能正常停止 sing-box，将继续检查 vpsbox 配置对应的进程。"
        if ! stop_singbox_config_processes; then
            fail_after_node_rollback "残留 sing-box 进程无法停止" "删除前" || true
            return 1
        fi
        sleep 1
    fi
    if service_manager_is_active || [ -n "$(singbox_config_pids)" ]; then
        fail_after_node_rollback "sing-box 服务仍在运行" "删除前" || true
        return 1
    fi
    if [ "$singbox_available" -eq 1 ] && [ -n "$node_port" ]; then
        if port_in_use_for_protocols "$node_port" "$node_protocols"; then
            fail_after_node_rollback "节点端口 $node_port 仍被其他进程监听" "删除前" || true
            return 1
        else
            port_status=$?
            if [ "$port_status" -ne 1 ]; then
                fail_after_node_rollback "无法确认节点端口 $node_port 是否已释放" "删除前" || true
                return 1
            fi
        fi
    fi

    config="$(node_config_path "$protocol")" || return 1
    state="$(node_state_path "$protocol")" || return 1
    rm -f -- "$config" "$state" || {
        fail_after_node_rollback "$label 节点文件删除失败" "删除前" || true
        return 1
    }
    repair_node_uri_cache_best_effort "删除节点后"

    if node_exists; then
        if [ "$singbox_available" -eq 1 ]; then
            if ! check_node_config_set ||
                ! setup_service ||
                ! restart_singbox_cleanly ||
                ! verify_all_node_runtime; then
                fail_after_node_rollback "剩余节点恢复运行失败" "删除前" || true
                return 1
            fi
        elif ! require_valid_node_state_if_present; then
            fail_after_node_rollback "剩余节点静态完整性校验失败" "删除前" || true
            return 1
        fi
    else
        if [ "$singbox_available" -eq 1 ] || service_is_enabled; then
            if ! service_disable || service_is_enabled; then
                fail_after_node_rollback "无法禁用 sing-box 开机启动" "删除前" || true
                return 1
            fi
        fi
        [ "$NODE_CONFIG_DIR" = "$CONFIG_DIR/vpsbox.d" ] &&
            rmdir "$NODE_CONFIG_DIR" 2>/dev/null || true
    fi
    if [ "$cleanup_mode" -eq 0 ] && ! firewall_complete_port_transition; then
        fail_after_node_rollback "主机防火墙端口同步失败" "删除前" || true
        return 1
    fi

    if ! commit_node_transaction; then
        fail_after_node_rollback "节点删除事务提交失败" "删除前" || true
        return 1
    fi
    if [ "$port_unknown" -eq 1 ] && firewall_control_plane_present; then
        warn "无法从损坏状态中取得可信旧端口，未自动猜测或删除防火墙端口；请进入 [4] 主机防火墙执行一键开启/更新。"
    fi
    if node_exists; then
        if [ "$singbox_available" -eq 1 ]; then
            if [ "$cleanup_mode" -eq 1 ]; then
                info "损坏的 $label 节点残留已清理，其他节点继续运行。"
            else
                info "$label 节点已删除，其他节点继续运行。"
            fi
        else
            info "$label 节点已删除；其他节点配置已保留，但 sing-box 未安装，当前不会运行。"
        fi
    else
        if [ "$singbox_available" -eq 1 ]; then
            if [ "$cleanup_mode" -eq 1 ]; then
                info "损坏的 $label 节点残留已清理，sing-box 服务已停止并禁用开机启动。"
            else
                info "$label 节点已删除，sing-box 服务已停止并禁用开机启动。"
            fi
        else
            info "$label 节点残留配置已删除；sing-box 未安装，无需停止服务。"
        fi
    fi
}

delete_vless_reality_node() {
    delete_node_protocol vless
}

delete_node() {
    delete_node_protocol ss
}

singbox_binary_version_at() {
    local binary="$1"

    [ -x "$binary" ] && [ ! -L "$binary" ] || return 1
    "$binary" version 2>/dev/null | head -n1 | sed 's/^sing-box version //'
}

restore_singbox_binary_atomically() {
    local backup_binary="$1" binary_path="$2" old_version="$3"
    local parent tmp restored_version

    [ -f "$backup_binary" ] && [ ! -L "$backup_binary" ] || return 1
    parent="$(dirname "$binary_path")"
    [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
    tmp="$(mktemp "$parent/.sing-box-vpsbox-restore.XXXXXX")" || return 1
    if ! cp -a -- "$backup_binary" "$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    restored_version="$(singbox_binary_version_at "$tmp" 2>/dev/null || true)"
    if [ -n "$old_version" ] && [ "$restored_version" != "$old_version" ]; then
        rm -f -- "$tmp"
        return 1
    fi
    if ! mv -f -- "$tmp" "$binary_path"; then
        rm -f -- "$tmp"
        return 1
    fi
}

singbox_update_transaction_dir_valid() {
    [ "${1:-}" = "$SINGBOX_UPDATE_TRANSACTION_DIR" ] &&
        [ "$SINGBOX_UPDATE_TRANSACTION_DIR" = "$VPSBOX_STATE_DIR/singbox-update" ]
}

remove_singbox_update_transaction_dir() {
    local dir="${1:-$SINGBOX_UPDATE_TRANSACTION_DIR}"

    singbox_update_transaction_dir_valid "$dir" || return 1
    [ ! -L "$dir" ] || return 1
    if [ -e "$dir/pending" ] || [ -L "$dir/pending" ]; then
        [ -f "$dir/pending" ] && [ ! -L "$dir/pending" ] || return 1
        rm -f -- "$dir/pending" || return 1
        sync_node_transaction_store || return 1
    fi
    rm -rf -- "$dir"
}

singbox_update_state_value() {
    local key="$1"

    [ -f "$SINGBOX_UPDATE_TRANSACTION_STATE" ] &&
        [ ! -L "$SINGBOX_UPDATE_TRANSACTION_STATE" ] || return 1
    awk -F= -v key="$key" '$1 == key { print substr($0, index($0, "=") + 1); found=1; exit }
        END { if (!found) exit 1 }' "$SINGBOX_UPDATE_TRANSACTION_STATE"
}

singbox_update_binary_path_allowed() {
    local binary_path="$1"

    if [ "${VPSBOX_TEST_MODE:-0}" = "1" ]; then
        [[ "$binary_path" == /tmp/vpsbox-test.*/sing-box ||
            "$binary_path" == /tmp/vpsbox-test.*/*/sing-box ]]
    else
        case "$binary_path" in
            /usr/bin/sing-box|/usr/local/bin/sing-box) return 0 ;;
            *) return 1 ;;
        esac
    fi
}

singbox_update_metadata_without_backup_valid() {
    local binary_path old_version was_enabled was_active package_name
    local binary_hash package_hash mode

    singbox_update_transaction_dir_valid "$SINGBOX_UPDATE_TRANSACTION_DIR" || return 1
    [ -d "$SINGBOX_UPDATE_TRANSACTION_DIR" ] &&
        [ ! -L "$SINGBOX_UPDATE_TRANSACTION_DIR" ] || return 1
    [ -f "$SINGBOX_UPDATE_TRANSACTION_DIR/pending" ] &&
        [ ! -L "$SINGBOX_UPDATE_TRANSACTION_DIR/pending" ] || return 1
    [ -f "$SINGBOX_UPDATE_TRANSACTION_STATE" ] &&
        [ ! -L "$SINGBOX_UPDATE_TRANSACTION_STATE" ] || return 1
    mode="$(stat -c '%a' "$SINGBOX_UPDATE_TRANSACTION_DIR" 2>/dev/null || true)"
    [ "$mode" = "700" ] || return 1
    [ "$(stat -c '%u:%g %a' "$SINGBOX_UPDATE_TRANSACTION_STATE" 2>/dev/null || true)" = "0:0 600" ] ||
        return 1
    [ "$(stat -c '%u:%g %a' "$SINGBOX_UPDATE_TRANSACTION_DIR/pending" 2>/dev/null || true)" = "0:0 600" ] ||
        return 1
    [ "$(stat -c '%u:%g' "$SINGBOX_UPDATE_TRANSACTION_DIR" 2>/dev/null || true)" = "0:0" ] ||
        return 1

    [ "$(singbox_update_state_value version 2>/dev/null || true)" = "1" ] || return 1
    binary_path="$(singbox_update_state_value binary_path 2>/dev/null || true)"
    old_version="$(singbox_update_state_value old_version 2>/dev/null || true)"
    was_enabled="$(singbox_update_state_value was_enabled 2>/dev/null || true)"
    was_active="$(singbox_update_state_value was_active 2>/dev/null || true)"
    package_name="$(singbox_update_state_value package_name 2>/dev/null || true)"
    binary_hash="$(singbox_update_state_value binary_sha256 2>/dev/null || true)"
    package_hash="$(singbox_update_state_value package_sha256 2>/dev/null || true)"
    singbox_update_binary_path_allowed "$binary_path" || return 1
    [[ "$old_version" =~ ^[0-9]+([.][0-9]+){2}$ ]] || return 1
    [[ "$was_enabled" =~ ^[01]$ && "$was_active" =~ ^[01]$ ]] || return 1
    [[ "$binary_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
    case "$package_name" in
        rollback-package.deb|rollback-package.apk|rollback-package.rpm)
            [[ "$package_hash" =~ ^[0-9a-f]{64}$ ]]
            ;;
        none) [ "$package_hash" = "none" ] ;;
        *) return 1 ;;
    esac
}

current_singbox_update_binary_usable() {
    local binary_path mode version

    singbox_update_metadata_without_backup_valid || return 1
    binary_path="$(singbox_update_state_value binary_path 2>/dev/null || true)"
    [ -f "$binary_path" ] && [ ! -L "$binary_path" ] && [ -x "$binary_path" ] || return 1
    [ "$(stat -c '%u:%g' "$binary_path" 2>/dev/null || true)" = "0:0" ] || return 1
    mode="$(stat -c '%a' "$binary_path" 2>/dev/null || true)"
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    [ $((8#$mode & 8#022)) -eq 0 ] || return 1
    version="$(singbox_binary_version_at "$binary_path" 2>/dev/null || true)"
    [[ "$version" =~ ^[0-9]+([.][0-9]+){2}$ ]]
}

singbox_update_transaction_valid() {
    local binary_path old_version was_enabled was_active package_name
    local binary_hash package_hash current_hash mode

    singbox_update_transaction_dir_valid "$SINGBOX_UPDATE_TRANSACTION_DIR" || return 1
    [ -d "$SINGBOX_UPDATE_TRANSACTION_DIR" ] &&
        [ ! -L "$SINGBOX_UPDATE_TRANSACTION_DIR" ] || return 1
    [ -f "$SINGBOX_UPDATE_TRANSACTION_DIR/pending" ] &&
        [ ! -L "$SINGBOX_UPDATE_TRANSACTION_DIR/pending" ] || return 1
    [ -f "$SINGBOX_UPDATE_TRANSACTION_STATE" ] &&
        [ ! -L "$SINGBOX_UPDATE_TRANSACTION_STATE" ] || return 1
    [ -f "$SINGBOX_UPDATE_TRANSACTION_DIR/old-binary" ] &&
        [ ! -L "$SINGBOX_UPDATE_TRANSACTION_DIR/old-binary" ] || return 1
    mode="$(stat -c '%a' "$SINGBOX_UPDATE_TRANSACTION_DIR" 2>/dev/null || true)"
    [ "$mode" = "700" ] || return 1
    mode="$(stat -c '%a' "$SINGBOX_UPDATE_TRANSACTION_STATE" 2>/dev/null || true)"
    [ "$mode" = "600" ] || return 1
    [ "$(stat -c '%u:%g' "$SINGBOX_UPDATE_TRANSACTION_DIR" "$SINGBOX_UPDATE_TRANSACTION_STATE" \
        "$SINGBOX_UPDATE_TRANSACTION_DIR/pending" "$SINGBOX_UPDATE_TRANSACTION_DIR/old-binary" \
        2>/dev/null | sort -u)" = "0:0" ] || return 1
    mode="$(stat -c '%a' "$SINGBOX_UPDATE_TRANSACTION_DIR/pending" 2>/dev/null || true)"
    [ "$mode" = "600" ] || return 1
    mode="$(stat -c '%a' "$SINGBOX_UPDATE_TRANSACTION_DIR/old-binary" 2>/dev/null || true)"
    [ "$mode" = "755" ] || return 1

    [ "$(singbox_update_state_value version 2>/dev/null || true)" = "1" ] || return 1
    binary_path="$(singbox_update_state_value binary_path 2>/dev/null || true)"
    old_version="$(singbox_update_state_value old_version 2>/dev/null || true)"
    was_enabled="$(singbox_update_state_value was_enabled 2>/dev/null || true)"
    was_active="$(singbox_update_state_value was_active 2>/dev/null || true)"
    package_name="$(singbox_update_state_value package_name 2>/dev/null || true)"
    binary_hash="$(singbox_update_state_value binary_sha256 2>/dev/null || true)"
    package_hash="$(singbox_update_state_value package_sha256 2>/dev/null || true)"
    singbox_update_binary_path_allowed "$binary_path" || return 1
    [[ "$old_version" =~ ^[0-9]+([.][0-9]+){2}$ ]] || return 1
    [[ "$was_enabled" =~ ^[01]$ && "$was_active" =~ ^[01]$ ]] || return 1
    [[ "$binary_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
    current_hash="$(sha256sum "$SINGBOX_UPDATE_TRANSACTION_DIR/old-binary" 2>/dev/null | awk '{print $1}')"
    [ "$current_hash" = "$binary_hash" ] || return 1
    [ "$(singbox_binary_version_at "$SINGBOX_UPDATE_TRANSACTION_DIR/old-binary" 2>/dev/null || true)" = "$old_version" ] ||
        return 1
    case "$package_name" in
        rollback-package.deb|rollback-package.apk|rollback-package.rpm)
            [ -f "$SINGBOX_UPDATE_TRANSACTION_DIR/$package_name" ] &&
                [ ! -L "$SINGBOX_UPDATE_TRANSACTION_DIR/$package_name" ] || return 1
            [ "$(stat -c '%u:%g %a' "$SINGBOX_UPDATE_TRANSACTION_DIR/$package_name" 2>/dev/null || true)" = "0:0 600" ] ||
                return 1
            [[ "$package_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
            current_hash="$(sha256sum "$SINGBOX_UPDATE_TRANSACTION_DIR/$package_name" 2>/dev/null | awk '{print $1}')"
            [ "$current_hash" = "$package_hash" ]
            ;;
        none)
            [ "$package_hash" = "none" ]
            ;;
        *) return 1 ;;
    esac
}

persist_singbox_update_transaction() {
    local binary_path="$1" backup_binary="$2" rollback_package="$3" old_version="$4"
    local was_enabled="$5" was_active="$6" package_name package_hash="none"
    local binary_hash tmp_dir

    command -v sha256sum >/dev/null 2>&1 || return 1
    [ ! -L "$VPSBOX_STATE_DIR" ] && [ ! -L "$SINGBOX_UPDATE_TRANSACTION_DIR" ] || return 1
    mkdir -p "$VPSBOX_STATE_DIR" || return 1
    chown root:root "$VPSBOX_STATE_DIR" || return 1
    chmod 700 "$VPSBOX_STATE_DIR" || return 1
    if [ -e "$SINGBOX_UPDATE_TRANSACTION_DIR" ]; then
        [ ! -e "$SINGBOX_UPDATE_TRANSACTION_DIR/pending" ] || return 1
        remove_singbox_update_transaction_dir || return 1
    fi
    tmp_dir="$(mktemp -d "$VPSBOX_STATE_DIR/.singbox-update.XXXXXX")" || return 1
    chmod 700 "$tmp_dir" || { rm -rf -- "$tmp_dir"; return 1; }
    if ! cp -a -- "$backup_binary" "$tmp_dir/old-binary" ||
        ! chmod 755 "$tmp_dir/old-binary"; then
        rm -rf -- "$tmp_dir"
        return 1
    fi
    binary_hash="$(sha256sum "$tmp_dir/old-binary" | awk '{print $1}')"
    if [ -n "$rollback_package" ]; then
        case "$rollback_package" in
            *.deb) package_name="rollback-package.deb" ;;
            *.apk) package_name="rollback-package.apk" ;;
            *.rpm) package_name="rollback-package.rpm" ;;
            *) rm -rf -- "$tmp_dir"; return 1 ;;
        esac
        if ! cp -a -- "$rollback_package" "$tmp_dir/$package_name" ||
            ! chmod 600 "$tmp_dir/$package_name"; then
            rm -rf -- "$tmp_dir"
            return 1
        fi
        package_hash="$(sha256sum "$tmp_dir/$package_name" | awk '{print $1}')"
    else
        package_name=none
    fi
    if ! {
        printf 'version=1\n'
        printf 'binary_path=%s\n' "$binary_path"
        printf 'old_version=%s\n' "$old_version"
        printf 'was_enabled=%s\n' "$was_enabled"
        printf 'was_active=%s\n' "$was_active"
        printf 'package_name=%s\n' "$package_name"
        printf 'binary_sha256=%s\n' "$binary_hash"
        printf 'package_sha256=%s\n' "$package_hash"
    } > "$tmp_dir/state" ||
        ! chmod 600 "$tmp_dir/state" ||
        ! : > "$tmp_dir/pending" ||
        ! chmod 600 "$tmp_dir/pending" ||
        ! mv -- "$tmp_dir" "$SINGBOX_UPDATE_TRANSACTION_DIR"; then
        rm -rf -- "$tmp_dir"
        return 1
    fi
    if ! sync_node_transaction_store || ! singbox_update_transaction_valid; then
        remove_singbox_update_transaction_dir || true
        return 1
    fi
}

restore_singbox_update_backup() {
    local binary_path="$1" backup_binary="$2" backup_dir="$3"
    local was_enabled="$4" was_active="$5"
    local rollback_package="${6:-}" old_version="${7:-}"
    local failed=0 package_state_may_differ=0 require_vpsbox_process=0
    local package_restored=0 binary_ready=0 service_ready=1

    if ! service_stop 2>/dev/null && service_manager_is_active; then
        err "更新后的 sing-box 服务无法停止，已拒绝在运行中覆盖二进制。"
        failed=1
    fi
    if ! stop_singbox_config_processes 2>/dev/null; then
        err "更新后的 sing-box 进程无法停止，已拒绝在运行中覆盖二进制。"
        failed=1
    fi
    if [ "$failed" -ne 0 ]; then
        warn "sing-box 更新备份已保留：$backup_dir"
        return 1
    fi
    if [ -n "$rollback_package" ] && [ -n "$old_version" ]; then
        if install_singbox_package_file "$rollback_package" &&
            [ "$(singbox_version)" = "$old_version" ]; then
            package_restored=1
            binary_ready=1
        else
            err "旧 sing-box 软件包恢复失败，正在尝试恢复二进制副本。"
            package_state_may_differ=1
        fi
    else
        # 旧版本 Release 包只是优先回滚材料；可信旧二进制仍是持久事务的必要保障。
        # 二进制回滚可恢复运行，但无法保证 dpkg/apk/rpm 的版本记录一并回退。
        package_state_may_differ=1
    fi
    if [ "$package_restored" -eq 0 ]; then
        if restore_singbox_binary_atomically "$backup_binary" "$binary_path" "$old_version"; then
            binary_ready=1
        else
            err "旧 sing-box 二进制恢复失败：$backup_binary"
            failed=1
        fi
    fi
    hash -r
    if [ "$binary_ready" -eq 1 ] && node_exists; then
        require_vpsbox_process=1
        if ! setup_service; then
            err "旧 sing-box 服务配置恢复失败。"
            failed=1
            service_ready=0
        fi
    fi
    if [ "$binary_ready" -eq 1 ] && [ "$service_ready" -eq 1 ] &&
        ! restore_singbox_service_state "$was_enabled" "$was_active" "$require_vpsbox_process"; then
        err "旧 sing-box 二进制已恢复，但原服务状态恢复失败。"
        failed=1
    fi

    if [ "$failed" -ne 0 ]; then
        # 更新失败时保留本地二进制备份，避免包管理器处于异常状态后失去最后恢复副本。
        warn "sing-box 更新备份已保留：$backup_dir"
        return 1
    fi
    if [ "$package_state_may_differ" -eq 1 ]; then
        warn "旧 sing-box 二进制和服务状态已恢复，但软件包管理记录可能不一致；后续更新前请检查系统软件包状态。"
    fi
    return 0
}

recover_pending_singbox_update() {
    local binary_path current_version old_version was_enabled was_active package_name rollback_package=""

    [ -e "$SINGBOX_UPDATE_TRANSACTION_DIR" ] || return 0
    [ -d "$SINGBOX_UPDATE_TRANSACTION_DIR" ] &&
        [ ! -L "$SINGBOX_UPDATE_TRANSACTION_DIR" ] || {
            err "sing-box 更新事务路径不安全，已拒绝自动处理。"
            return 1
        }
    if [ ! -e "$SINGBOX_UPDATE_TRANSACTION_DIR/pending" ]; then
        remove_singbox_update_transaction_dir || return 1
        return 0
    fi
    if [ ! -e "$SINGBOX_UPDATE_TRANSACTION_DIR/old-binary" ] &&
        [ ! -L "$SINGBOX_UPDATE_TRANSACTION_DIR/old-binary" ]; then
        if ! current_singbox_update_binary_usable; then
            err "sing-box 旧二进制恢复材料缺失，且当前二进制或事务元数据不可用；已保留记录：$SINGBOX_UPDATE_TRANSACTION_DIR"
            return 1
        fi
        binary_path="$(singbox_update_state_value binary_path)"
        current_version="$(singbox_binary_version_at "$binary_path")"
        if node_exists; then
            require_valid_node_state_if_present || {
                err "当前节点状态未通过校验，sing-box 更新事务记录已保留。"
                return 1
            }
            "$binary_path" check -C "$NODE_CONFIG_DIR" >/dev/null 2>&1 || {
                err "当前 sing-box 无法加载节点配置，更新事务记录已保留。"
                return 1
            }
        fi
        warn "检测到 sing-box 更新或回滚清理曾中断；当前 sing-box v$current_version 可用，正在清理无恢复价值的事务残留。"
        remove_singbox_update_transaction_dir || return 1
        return 0
    fi
    singbox_update_transaction_valid || {
        err "sing-box 更新恢复记录未通过完整性检查，已保留：$SINGBOX_UPDATE_TRANSACTION_DIR"
        return 1
    }
    binary_path="$(singbox_update_state_value binary_path)"
    old_version="$(singbox_update_state_value old_version)"
    was_enabled="$(singbox_update_state_value was_enabled)"
    was_active="$(singbox_update_state_value was_active)"
    package_name="$(singbox_update_state_value package_name)"
    [ "$package_name" = "none" ] ||
        rollback_package="$SINGBOX_UPDATE_TRANSACTION_DIR/$package_name"

    warn "检测到上次未完成的 sing-box 更新，正在恢复旧版本。"
    if ! restore_singbox_update_backup \
        "$binary_path" "$SINGBOX_UPDATE_TRANSACTION_DIR/old-binary" \
        "$SINGBOX_UPDATE_TRANSACTION_DIR" "$was_enabled" "$was_active" \
        "$rollback_package" "$old_version"; then
        err "sing-box 旧版本未能完整恢复，事务记录已保留：$SINGBOX_UPDATE_TRANSACTION_DIR"
        return 1
    fi
    [ "$(singbox_version)" = "$old_version" ] || {
        err "sing-box 恢复后的版本不符，事务记录已保留：$SINGBOX_UPDATE_TRANSACTION_DIR"
        return 1
    }
    remove_singbox_update_transaction_dir || return 1
    info "上次中断的 sing-box 更新已恢复到 v$old_version。"
}

begin_singbox_update_transaction() {
    ACTIVE_SINGBOX_UPDATE_BINARY="$1"
    ACTIVE_SINGBOX_UPDATE_BACKUP="$2"
    ACTIVE_SINGBOX_UPDATE_DIR="$3"
    ACTIVE_SINGBOX_UPDATE_PACKAGE="${6:-}"
    ACTIVE_SINGBOX_UPDATE_OLD_VERSION="${7:-}"
    ACTIVE_SINGBOX_UPDATE_WAS_ENABLED="$4"
    ACTIVE_SINGBOX_UPDATE_WAS_ACTIVE="$5"
    ACTIVE_SINGBOX_UPDATE_MUTATED=0
}

cancel_unmodified_singbox_update_transaction() {
    local backup_dir="${ACTIVE_SINGBOX_UPDATE_DIR:-}"

    ACTIVE_SINGBOX_UPDATE_BINARY=""
    ACTIVE_SINGBOX_UPDATE_BACKUP=""
    ACTIVE_SINGBOX_UPDATE_DIR=""
    ACTIVE_SINGBOX_UPDATE_PACKAGE=""
    ACTIVE_SINGBOX_UPDATE_OLD_VERSION=""
    ACTIVE_SINGBOX_UPDATE_WAS_ENABLED=0
    ACTIVE_SINGBOX_UPDATE_WAS_ACTIVE=0
    ACTIVE_SINGBOX_UPDATE_MUTATED=0
    if { [[ "$backup_dir" == /tmp/vpsbox-sing-box-update.* ]] ||
        singbox_update_transaction_dir_valid "$backup_dir" ||
        [ "${VPSBOX_TEST_MODE:-0}" = "1" ]; } &&
        [ -d "$backup_dir" ] && [ ! -L "$backup_dir" ]; then
        if singbox_update_transaction_dir_valid "$backup_dir"; then
            remove_singbox_update_transaction_dir
        else
            rm -rf -- "$backup_dir"
        fi
    fi
}

rollback_active_singbox_update() {
    local binary_path backup_binary backup_dir rollback_package old_version
    local was_enabled was_active mutated result=0

    [ "${ACTIVE_SINGBOX_UPDATE_ROLLING_BACK:-0}" = "0" ] || return 0
    backup_dir="${ACTIVE_SINGBOX_UPDATE_DIR:-}"
    [ -n "$backup_dir" ] || return 0
    binary_path="$ACTIVE_SINGBOX_UPDATE_BINARY"
    backup_binary="$ACTIVE_SINGBOX_UPDATE_BACKUP"
    rollback_package="$ACTIVE_SINGBOX_UPDATE_PACKAGE"
    old_version="$ACTIVE_SINGBOX_UPDATE_OLD_VERSION"
    was_enabled="$ACTIVE_SINGBOX_UPDATE_WAS_ENABLED"
    was_active="$ACTIVE_SINGBOX_UPDATE_WAS_ACTIVE"
    mutated="$ACTIVE_SINGBOX_UPDATE_MUTATED"
    ACTIVE_SINGBOX_UPDATE_ROLLING_BACK=1

    # 先清空全局事务，防止恢复命令再次收到信号时重复进入同一回滚。
    ACTIVE_SINGBOX_UPDATE_BINARY=""
    ACTIVE_SINGBOX_UPDATE_BACKUP=""
    ACTIVE_SINGBOX_UPDATE_DIR=""
    ACTIVE_SINGBOX_UPDATE_PACKAGE=""
    ACTIVE_SINGBOX_UPDATE_OLD_VERSION=""
    ACTIVE_SINGBOX_UPDATE_WAS_ENABLED=0
    ACTIVE_SINGBOX_UPDATE_WAS_ACTIVE=0
    ACTIVE_SINGBOX_UPDATE_MUTATED=0
    if [ "$mutated" = "1" ]; then
        restore_singbox_update_backup \
            "$binary_path" "$backup_binary" "$backup_dir" "$was_enabled" "$was_active" \
            "$rollback_package" "$old_version" || result=1
        if [ "$result" -eq 0 ] && singbox_update_transaction_dir_valid "$backup_dir"; then
            remove_singbox_update_transaction_dir || result=1
        fi
    elif { [[ "$backup_dir" == /tmp/vpsbox-sing-box-update.* ]] ||
        singbox_update_transaction_dir_valid "$backup_dir" ||
        [ "${VPSBOX_TEST_MODE:-0}" = "1" ]; } &&
        [ -d "$backup_dir" ] && [ ! -L "$backup_dir" ]; then
        if singbox_update_transaction_dir_valid "$backup_dir"; then
            remove_singbox_update_transaction_dir || result=1
        else
            rm -rf -- "$backup_dir" || result=1
        fi
    else
        result=1
    fi
    ACTIVE_SINGBOX_UPDATE_ROLLING_BACK=0
    return "$result"
}

commit_singbox_update_transaction() {
    local backup_dir="${ACTIVE_SINGBOX_UPDATE_DIR:-}"

    ACTIVE_SINGBOX_UPDATE_BINARY=""
    ACTIVE_SINGBOX_UPDATE_BACKUP=""
    ACTIVE_SINGBOX_UPDATE_DIR=""
    ACTIVE_SINGBOX_UPDATE_PACKAGE=""
    ACTIVE_SINGBOX_UPDATE_OLD_VERSION=""
    ACTIVE_SINGBOX_UPDATE_WAS_ENABLED=0
    ACTIVE_SINGBOX_UPDATE_WAS_ACTIVE=0
    ACTIVE_SINGBOX_UPDATE_MUTATED=0
    { [[ "$backup_dir" == /tmp/vpsbox-sing-box-update.* ]] ||
        singbox_update_transaction_dir_valid "$backup_dir" ||
        [ "${VPSBOX_TEST_MODE:-0}" = "1" ]; } &&
        [ -d "$backup_dir" ] && [ ! -L "$backup_dir" ] || return 1
    if singbox_update_transaction_dir_valid "$backup_dir"; then
        remove_singbox_update_transaction_dir
    else
        rm -rf -- "$backup_dir"
    fi
}

update_singbox() {
    local binary_path backup_dir backup_binary rollback_package old_version package_name
    local relation new_version
    local was_active=0 was_enabled=0 had_nodes=0

    if ! singbox_installed; then
        warn "当前未安装 sing-box，已取消更新。"
        info "如需安装 sing-box，请先创建节点或启动服务。"
        return 0
    fi
    binary_path="$(command -v sing-box)"
    old_version="$(singbox_version)"
    [[ "$old_version" =~ ^[0-9]+([.][0-9]+){2}$ ]] || { err "无法识别当前 sing-box 版本，已取消更新。"; return 1; }
    relation="$(version_relation "$SINGBOX_RELEASE_VERSION" "$old_version")" || {
        err "无法比较 sing-box 版本，已取消更新。"
        return 1
    }
    case "$relation" in
        same)
            info "sing-box 当前已是受管版本 v$SINGBOX_RELEASE_VERSION，无需更新。"
            return 0
            ;;
        older)
            warn "当前 sing-box v$old_version 高于受管版本 v$SINGBOX_RELEASE_VERSION，已拒绝隐式降级。"
            return 0
            ;;
        newer) ;;
    esac
    if ! singbox_binary_is_package_managed "$binary_path"; then
        err "当前 sing-box 不是由系统 sing-box 软件包管理，已拒绝自动更新。"
        info "请先用原安装方式更新或卸载，再由 vpsbox 安装受管版本。"
        return 1
    fi
    if node_core_artifacts_present; then
        ensure_node_dependencies || return 1
        require_valid_node_state_if_present || {
            err "节点配置完整性未通过，已拒绝更新 sing-box。"
            return 1
        }
        repair_node_uri_cache_best_effort "更新 sing-box 前"
        node_exists && check_node_config_set || {
            err "节点配置未通过当前 sing-box 检查，已拒绝更新。"
            return 1
        }
        had_nodes=1
    fi
    backup_dir="$(mktemp -d /tmp/vpsbox-sing-box-update.XXXXXX)" || return 1
    backup_binary="$backup_dir/sing-box"
    cp -a "$binary_path" "$backup_binary" || { rm -rf "$backup_dir"; err "备份当前 sing-box 二进制失败，已取消更新。"; return 1; }

    # 更新回滚需要恢复服务管理器的原始 active 状态；精确的 vpsbox 进程匹配
    # 只用于节点运行检查，不能把 active 的自定义/旧布局服务误记为未运行。
    if service_manager_is_active; then
        was_active=1
    fi
    if service_is_enabled; then
        was_enabled=1
    fi
    begin_singbox_update_transaction \
        "$binary_path" "$backup_binary" "$backup_dir" "$was_enabled" "$was_active"

    if ! ensure_node_dependencies; then
        cancel_unmodified_singbox_update_transaction
        err "更新依赖准备失败；sing-box 二进制和服务状态均未修改。"
        return 1
    fi
    if ! rollback_package="$(prepare_singbox_rollback_package "$old_version" "$backup_dir")"; then
        rollback_package=""
        warn "无法下载并校验旧版 sing-box 回滚包；将使用已校验的旧二进制副本作为回滚保障并继续更新。若后续发生回滚，软件包管理记录可能仍显示新版。"
    fi
    ACTIVE_SINGBOX_UPDATE_PACKAGE="$rollback_package"
    ACTIVE_SINGBOX_UPDATE_OLD_VERSION="$old_version"
    if ! persist_singbox_update_transaction \
        "$binary_path" "$backup_binary" "$rollback_package" "$old_version" \
        "$was_enabled" "$was_active"; then
        cancel_unmodified_singbox_update_transaction
        err "无法持久化 sing-box 更新回滚记录，已取消更新。"
        return 1
    fi
    rm -rf -- "$backup_dir"
    backup_dir="$SINGBOX_UPDATE_TRANSACTION_DIR"
    backup_binary="$backup_dir/old-binary"
    package_name="$(singbox_update_state_value package_name)"
    if [ "$package_name" = "none" ]; then
        rollback_package=""
    else
        rollback_package="$backup_dir/$package_name"
    fi
    ACTIVE_SINGBOX_UPDATE_DIR="$backup_dir"
    ACTIVE_SINGBOX_UPDATE_BACKUP="$backup_binary"
    ACTIVE_SINGBOX_UPDATE_PACKAGE="$rollback_package"
    info "正在更新 sing-box..."
    ACTIVE_SINGBOX_UPDATE_MUTATED=1
    if ! run_singbox_installer; then
        err "sing-box 安装过程失败，正在恢复旧二进制和原服务状态。"
        rollback_active_singbox_update || true
        return 1
    fi

    new_version="$(singbox_version)"
    if [ "$new_version" != "$SINGBOX_RELEASE_VERSION" ]; then
        err "安装后的 sing-box 版本异常（当前：$new_version），正在恢复旧版本。"
        rollback_active_singbox_update || true
        return 1
    fi

    if [ "$had_nodes" -eq 1 ]; then
        if ! check_node_config_set; then
            err "当前节点配置未通过新版 sing-box 检查，正在恢复旧二进制。"
            rollback_active_singbox_update || true
            return 1
        fi
        if ! setup_service || ! restore_singbox_service_state "$was_enabled" "$was_active" 1; then
            err "新版 sing-box 未能恢复原服务状态，正在恢复旧二进制。"
            rollback_active_singbox_update || true
            return 1
        fi
    elif ! restore_singbox_service_state "$was_enabled" "$was_active" 0; then
        err "新版 sing-box 未能恢复原服务状态，正在恢复旧二进制。"
        rollback_active_singbox_update || true
        return 1
    fi

    commit_singbox_update_transaction || {
        err "sing-box 已更新，但临时备份清理失败：$backup_dir"
        return 1
    }
    info "更新完成：$(singbox_version)"
}

# ==============================================================================
# 4. vpsbox 自更新发布与回滚事务
# ==============================================================================
restore_previous_vpsbox() {
    local backup="$1"
    local tmp

    [ -f "$backup" ] && [ ! -L "$backup" ] || {
        err "未找到可用的旧版备份：$backup"
        return 1
    }
    if ! bash -n "$backup" >/dev/null 2>&1 ||
        ! vpsbox_script_identity_valid "$backup"; then
        err "旧版备份未通过语法或项目身份检查：$backup"
        return 1
    fi
    tmp="$(mktemp "$(dirname "$CMD_PATH")/.vpsbox-restore.XXXXXX")" || return 1
    if ! cp -a -- "$backup" "$tmp" ||
        ! chmod 755 "$tmp" ||
        ! mv -f -- "$tmp" "$CMD_PATH"; then
        rm -f -- "$tmp"
        err "旧版 vpsbox 恢复失败，备份仍保留在：$backup"
        return 1
    fi
    install_command_alias || return 1
    info "已从 $backup 恢复旧版 vpsbox。"
}

vpsbox_update_ready_path_valid() {
    local ready="$1" dir

    [ -n "$ready" ] || return 1
    dir="${ready%/ready}"
    [ "$ready" = "$dir/ready" ] || return 1
    [[ "$dir" == "$RUNTIME_DIR"/update-startup.* ]] || return 1
    [ -d "$dir" ] && [ ! -L "$dir" ] && [ ! -L "$ready" ]
}

vpsbox_update_handoff_path_valid() {
    local handoff="$1" dir

    [ -n "$handoff" ] || return 1
    dir="${handoff%/handoff}"
    [ "$handoff" = "$dir/handoff" ] || return 1
    [[ "$dir" == "$RUNTIME_DIR"/update-startup.* ]] || return 1
    [ -d "$dir" ] && [ ! -L "$dir" ] && [ ! -L "$handoff" ]
}

mark_vpsbox_update_handoff() {
    local handoff="$1" dir tmp

    vpsbox_update_handoff_path_valid "$handoff" || return 1
    dir="${handoff%/handoff}"
    tmp="$(mktemp "$dir/.handoff.XXXXXX")" || return 1
    if ! printf '%s\n' "$$" > "$tmp" ||
        ! chmod 600 "$tmp" ||
        ! mv -f -- "$tmp" "$handoff"; then
        rm -f -- "$tmp"
        return 1
    fi
}

mark_vpsbox_update_ready() {
    local ready="$1" dir tmp

    vpsbox_update_ready_path_valid "$ready" || return 1
    dir="${ready%/ready}"
    tmp="$(mktemp "$dir/.ready.XXXXXX")" || return 1
    if ! printf '%s\n' "$$" > "$tmp" ||
        ! chmod 600 "$tmp" ||
        ! mv -f -- "$tmp" "$ready"; then
        rm -f -- "$tmp"
        return 1
    fi
}

start_vpsbox_update_watchdog() {
    local backup="$1" dir handoff ready owner_pid owner_start

    # 当前更新协议由旧进程先启动独立 watchdog，再 exec 新脚本。这样即使候选脚本
    # 在解析完毕后、进入 vpsbox_main 之前顶层退出，也能依据 PID 启动时间恢复 .previous。
    [ "$backup" = "${CMD_PATH}.previous" ] || return 1
    if [ ! -f "$backup" ] || [ -L "$backup" ] ||
        ! bash -n "$backup" >/dev/null 2>&1 ||
        ! vpsbox_script_identity_valid "$backup"; then
        return 1
    fi
    [ -d "$RUNTIME_DIR" ] && [ ! -L "$RUNTIME_DIR" ] || return 1
    dir="$(mktemp -d "$RUNTIME_DIR/update-startup.XXXXXX")" || return 1
    chmod 700 "$dir" || { rm -rf -- "$dir"; return 1; }
    handoff="$dir/handoff"
    ready="$dir/ready"
    owner_pid="$$"
    owner_start="$(process_start_ticks "$owner_pid" 2>/dev/null || true)"
    [[ "$owner_start" =~ ^[0-9]+$ ]] || { rm -rf -- "$dir"; return 1; }

    (
        local elapsed=0 current_start i

        trap - EXIT HUP INT TERM QUIT
        # 准备期覆盖脚本替换和命令入口安装；exec 前由 handoff 重新开始计算
        # 新版启动验收时间，避免准备工作消耗恢复事务所需的启动预算。
        while [ "$elapsed" -lt "$VPSBOX_UPDATE_PREPARE_TIMEOUT" ]; do
            if [ -f "$ready" ] && [ ! -L "$ready" ]; then
                rm -rf -- "$dir"
                exit 0
            fi
            if [ -f "$handoff" ] && [ ! -L "$handoff" ]; then
                break
            fi
            current_start="$(process_start_ticks "$owner_pid" 2>/dev/null || true)"
            [ "$current_start" = "$owner_start" ] || break
            sleep 1
            elapsed=$((elapsed + 1))
        done

        if [ -f "$ready" ] && [ ! -L "$ready" ]; then
            rm -rf -- "$dir"
            exit 0
        fi
        if [ -f "$handoff" ] && [ ! -L "$handoff" ]; then
            elapsed=0
            while [ "$elapsed" -lt "$VPSBOX_UPDATE_STARTUP_TIMEOUT" ]; do
                if [ -f "$ready" ] && [ ! -L "$ready" ]; then
                    rm -rf -- "$dir"
                    exit 0
                fi
                current_start="$(process_start_ticks "$owner_pid" 2>/dev/null || true)"
                [ "$current_start" = "$owner_start" ] || break
                sleep 1
                elapsed=$((elapsed + 1))
            done
            if [ -f "$ready" ] && [ ! -L "$ready" ]; then
                rm -rf -- "$dir"
                exit 0
            fi
        fi

        # 从这里开始只允许回滚。即使 TERM/KILL 期间出现迟到的 ready，
        # 也不能把已经终止候选进程的结果重新解释为启动成功。
        current_start="$(process_start_ticks "$owner_pid" 2>/dev/null || true)"
        if [ "$current_start" = "$owner_start" ]; then
            kill -TERM "$owner_pid" 2>/dev/null || true
            for i in 1 2 3 4 5; do
                sleep 1
                current_start="$(process_start_ticks "$owner_pid" 2>/dev/null || true)"
                [ "$current_start" = "$owner_start" ] || break
            done
            [ "$current_start" != "$owner_start" ] ||
                kill -KILL "$owner_pid" 2>/dev/null || true
        fi
        if restore_previous_vpsbox "$backup"; then
            if [ -w /dev/tty ]; then
                printf '\n[WARN] 新版 vpsbox 未完成启动，已自动恢复旧版。\n' >/dev/tty 2>/dev/null || true
            fi
            rm -rf -- "$dir"
        else
            printf '%s\n' "restore_failed=1" > "$dir/restore-failed" 2>/dev/null || true
            if [ -w /dev/tty ]; then
                printf '\n[ERR] 新版 vpsbox 启动失败，且旧版自动恢复失败：%s\n' "$backup" >/dev/tty 2>/dev/null || true
            fi
        fi
    ) 200>&- </dev/null >>"$dir/watchdog.log" 2>&1 &
    VPSBOX_UPDATE_WATCHDOG_PID=$!
    VPSBOX_UPDATE_WATCHDOG_DIR="$dir"
}

rollback_pending_vpsbox_update() {
    local backup="${PENDING_VPSBOX_UPDATE_BACKUP:-}"
    local ready="${PENDING_VPSBOX_UPDATE_READY_FILE:-}"

    [ -n "$backup$ready" ] || return 0
    [ "${VPSBOX_UPDATE_STARTUP_CONFIRMED:-0}" != "1" ] || return 0
    PENDING_VPSBOX_UPDATE_BACKUP=""
    PENDING_VPSBOX_UPDATE_READY_FILE=""
    unset VPSBOX_UPDATE_BACKUP || true
    unset VPSBOX_UPDATE_READY_FILE || true

    # .previous 本身不能证明本次启动来自更新；没有一次性握手变量时绝不自动回退，
    # 避免普通启动误用陈旧备份。
    [ "$backup" = "${CMD_PATH}.previous" ] || {
        err "拒绝使用非预期的 vpsbox 更新备份路径：$backup"
        return 1
    }
    vpsbox_update_ready_path_valid "$ready" || {
        err "拒绝使用无效的 vpsbox 更新握手路径：$ready"
        return 1
    }
    err "新版 vpsbox 未完成首次界面启动，正在恢复旧版脚本。"
    if restore_previous_vpsbox "$backup"; then
        mark_vpsbox_update_ready "$ready" || true
        return 0
    fi
    return 1
}

confirm_pending_vpsbox_update() {
    local ready="${PENDING_VPSBOX_UPDATE_READY_FILE:-}"

    [ -n "${PENDING_VPSBOX_UPDATE_BACKUP:-}$ready" ] || return 0
    if ! mark_vpsbox_update_ready "$ready"; then
        err "无法确认新版 vpsbox 启动状态，已触发安全回滚。"
        return 1
    fi
    VPSBOX_UPDATE_STARTUP_CONFIRMED=1
    PENDING_VPSBOX_UPDATE_BACKUP=""
    PENDING_VPSBOX_UPDATE_READY_FILE=""
    unset VPSBOX_UPDATE_BACKUP || true
    unset VPSBOX_UPDATE_READY_FILE || true
}

settle_vpsbox_update_watchdog_after_safe_restore() {
    local ready watchdog_pid watchdog_dir status=0

    watchdog_pid="${VPSBOX_UPDATE_WATCHDOG_PID:-}"
    watchdog_dir="${VPSBOX_UPDATE_WATCHDOG_DIR:-}"
    [ -n "$watchdog_pid$watchdog_dir" ] || return 0
    [ -n "$watchdog_pid" ] && [ -n "$watchdog_dir" ] || return 1
    ready="$watchdog_dir/ready"
    if mark_vpsbox_update_ready "$ready"; then
        wait "$watchdog_pid" 2>/dev/null || true
    else
        status=1
        warn "旧版脚本已经恢复，但无法确认更新监护状态；正在终止本次监护进程。"
        kill -TERM "$watchdog_pid" 2>/dev/null || true
        wait "$watchdog_pid" 2>/dev/null || true
        if [[ "$watchdog_dir" == "$RUNTIME_DIR"/update-startup.* ]] &&
            [ -d "$watchdog_dir" ] && [ ! -L "$watchdog_dir" ]; then
            rm -rf -- "$watchdog_dir" || status=1
        fi
    fi
    VPSBOX_UPDATE_WATCHDOG_PID=""
    VPSBOX_UPDATE_WATCHDOG_DIR=""
    return "$status"
}

update_vpsbox() {
    local backup="${CMD_PATH}.previous"
    local candidate
    local status

    info "正在下载最新 vpsbox 脚本..."
    mkdir -p "$(dirname "$CMD_PATH")" || return 1
    candidate="$(mktemp "$(dirname "$CMD_PATH")/.vpsbox-update.XXXXXX")" || return 1
    if download_vpsbox_script "$candidate" 1; then
        :
    else
        status=$?
        rm -f "$candidate"
        REMOTE_VERSION=""
        UPDATE_AVAILABLE=0
        case "$status" in
            2)
                info "当前已是最新版，无需更新。"
                return 0
                ;;
            3) return 0 ;;
            *) return "$status" ;;
        esac
    fi

    [ -f "$CMD_PATH" ] && [ ! -L "$CMD_PATH" ] || {
        rm -f "$candidate"
        err "未找到可备份的当前 vpsbox 主脚本，已取消更新。"
        return 1
    }
    if [ -e "$backup" ] || [ -L "$backup" ]; then
        if [ ! -f "$backup" ] || [ -L "$backup" ]; then
            rm -f "$candidate"
            err "旧版本备份路径不是安全的普通文件，已取消更新：$backup"
            return 1
        fi
        rm -f -- "$backup" || { rm -f "$candidate"; return 1; }
    fi
    cp -a "$CMD_PATH" "$backup" || {
        rm -f "$candidate"
        err "备份当前 vpsbox 脚本失败，已取消更新。"
        return 1
    }
    chmod 700 "$backup" || { rm -f "$candidate"; return 1; }
    start_vpsbox_update_watchdog "$backup" || {
        rm -f "$candidate"
        err "无法启动新版 vpsbox 启动监护，已取消更新。"
        return 1
    }
    if ! mv -f "$candidate" "$CMD_PATH"; then
        rm -f "$candidate"
        err "替换 vpsbox 脚本失败，正在从备份恢复。"
        if restore_previous_vpsbox "$backup"; then
            settle_vpsbox_update_watchdog_after_safe_restore ||
                warn "旧版脚本已恢复，但更新监护清理失败。"
        else
            err "自动恢复失败；当前进程将退出，并由更新监护再次尝试恢复：$backup"
            exit 1
        fi
        return 1
    fi
    if ! install_command_alias; then
        err "新版 vpsbox 管理命令入口安装失败，正在恢复旧版脚本。"
        if [ -f "$backup" ] && restore_previous_vpsbox "$backup"; then
            if settle_vpsbox_update_watchdog_after_safe_restore; then
                warn "已恢复更新前的 vpsbox 脚本。"
            else
                err "旧版脚本已恢复，但更新监护清理失败。"
            fi
        else
            err "自动恢复失败；请使用备份手动恢复：$backup"
            if [ -n "${VPSBOX_UPDATE_WATCHDOG_PID:-}" ]; then
                err "当前 vpsbox 将退出，并由更新监护再次尝试恢复旧版。"
                exit 1
            fi
        fi
        return 1
    fi

    info "vpsbox 已更新；旧版本备份：$backup"
    info "正在重新打开新版管理面板..."
    cleanup_vpsbox_lock
    reexec_updated_vpsbox "$backup" || {
        status=$?
        err "无法重新打开新版管理面板，正在恢复旧版脚本。"
        if restore_previous_vpsbox "$backup"; then
            if settle_vpsbox_update_watchdog_after_safe_restore; then
                warn "已恢复更新前的 vpsbox 脚本。"
            else
                err "旧版脚本已恢复，但更新监护清理失败。"
            fi
            acquire_lock || true
            return "$status"
        fi
        err "自动恢复失败；请使用备份手动恢复：$backup"
        if [ -n "${VPSBOX_UPDATE_WATCHDOG_PID:-}" ]; then
            err "当前 vpsbox 将退出，并由更新监护再次尝试恢复旧版。"
            exit "$status"
        fi
        acquire_lock || true
        return "$status"
    }
}

reexec_updated_vpsbox() {
    local backup="$1" handoff ready status execfail_was_set=0

    # 正常更新路径会在替换正式脚本前启动监护。保留此降级分支供独立调用与旧测试夹具使用。
    if [ -z "${VPSBOX_UPDATE_WATCHDOG_PID:-}" ] ||
        [ -z "${VPSBOX_UPDATE_WATCHDOG_DIR:-}" ]; then
        start_vpsbox_update_watchdog "$backup" || {
            err "无法启动新版 vpsbox 启动监护，已取消切换。"
            return 1
        }
    fi
    handoff="$VPSBOX_UPDATE_WATCHDOG_DIR/handoff"
    ready="$VPSBOX_UPDATE_WATCHDOG_DIR/ready"
    if ! mark_vpsbox_update_handoff "$handoff"; then
        err "无法通知更新监护进入新版启动阶段，已取消切换。"
        return 1
    fi
    vpsbox_update_ready_path_valid "$ready" || return 1
    shopt -q execfail && execfail_was_set=1
    shopt -s execfail
    VPSBOX_UPDATE_BACKUP="$backup" VPSBOX_UPDATE_READY_FILE="$ready" exec "$CMD_PATH"
    status=$?
    [ "$execfail_was_set" -eq 1 ] || shopt -u execfail
    unset VPSBOX_UPDATE_BACKUP || true
    unset VPSBOX_UPDATE_READY_FILE || true
    return "$status"
}

# ==============================================================================
# 5. 系统优化与安全：BBR、IPv6、TCP、Fail2ban、NTP、DNS、SSH 与系统维护
# ==============================================================================
bbr_state() {
    local cc
    cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")"
    [ "$cc" = "bbr" ] && echo "已启用" || echo "未启用"
}

fq_state() {
    local qdisc
    qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "")"
    if [ "$qdisc" = "fq" ]; then
        echo "已启用"
    elif [ -n "$qdisc" ]; then
        echo "未启用（当前：$qdisc）"
    else
        echo "未启用"
    fi
}

bbr_fq_summary_state() {
    local bbr fq

    bbr="$(bbr_state)"
    fq="$(fq_state)"
    if [ "$bbr" = "已启用" ] && [ "$fq" = "已启用" ]; then
        echo "已开启"
    else
        printf 'BBR %s / fq %s\n' "$bbr" "$fq"
    fi
}

ipv4_priority_state() {
    if [ -f "$GAI_CONF" ] &&
        grep -Eq '^[[:space:]]*precedence[[:space:]]+::ffff:0:0/96[[:space:]]+100([[:space:]]|$)' "$GAI_CONF"; then
        echo "已启用"
    else
        echo "未启用"
    fi
}

fail2ban_installed() {
    command -v fail2ban-client >/dev/null 2>&1
}

fail2ban_install_state() {
    fail2ban_installed && echo "已安装" || echo "未安装"
}

fail2ban_service_state() {
    if is_systemd; then
        if systemctl is-active --quiet fail2ban 2>/dev/null; then
            echo "运行中"
        else
            echo "未运行"
        fi
    elif [ "$OS" = "alpine" ] && command -v rc-service >/dev/null 2>&1; then
        if rc-service fail2ban status >/dev/null 2>&1; then
            echo "运行中"
        else
            echo "未运行"
        fi
    else
        echo "未知"
    fi
}

fail2ban_service_is_enabled() {
    if is_systemd; then
        systemctl is-enabled --quiet fail2ban 2>/dev/null
    elif [ "$OS" = "alpine" ]; then
        [ -e /etc/runlevels/default/fail2ban ] || [ -L /etc/runlevels/default/fail2ban ]
    else
        return 1
    fi
}

fail2ban_sshd_state() {
    local configured_ports
    local effective_ports

    if ! fail2ban_installed; then
        echo "未启用"
        return
    fi

    if ! fail2ban-client status sshd >/dev/null 2>&1; then
        echo "未启用"
        return
    fi

    configured_ports="$(awk -F= '/^[[:space:]]*port[[:space:]]*=/ {
        value=$2
        gsub(/[[:space:]]/, "", value)
        print value
        exit
    }' "$FAIL2BAN_VPSBOX_SSHD_CONF" 2>/dev/null || true)"
    effective_ports="$(ssh_effective_ports_csv || true)"
    if [ -n "$effective_ports" ] &&
        [ "$configured_ports" = "$effective_ports" ] &&
        fail2ban_sshd_runtime_ports_match "$effective_ports"; then
        echo "已启用"
    else
        echo "端口未同步"
    fi
}

render_fail2ban_sshd_config() {
    local ports="$1" backend="$2"

    # --- BEGIN GENERATED TEMPLATE: Fail2ban sshd jail ---
    cat <<EOF
[sshd]
enabled = true
port = $ports
backend = $backend
banaction = nftables-multiport
bantime = 1d
EOF
    # --- END GENERATED TEMPLATE: Fail2ban sshd jail ---
}

fail2ban_sshd_configuration_healthy() {
    local backend="auto" ports

    fail2ban_installed || return 1
    [ "$(fail2ban_service_state)" = "运行中" ] || return 1
    fail2ban_service_is_enabled || return 1
    [ -f "$FAIL2BAN_VPSBOX_SSHD_CONF" ] &&
        [ ! -L "$FAIL2BAN_VPSBOX_SSHD_CONF" ] || return 1
    ports="$(ssh_effective_ports_csv)" || return 1
    is_systemd && backend="systemd"
    render_fail2ban_sshd_config "$ports" "$backend" |
        cmp -s - "$FAIL2BAN_VPSBOX_SSHD_CONF" || return 1
    fail2ban-client -t -c /etc/fail2ban >/dev/null 2>&1 || return 1
    fail2ban-client status sshd >/dev/null 2>&1 || return 1
    fail2ban_sshd_runtime_ports_match "$ports" || return 1
    fail2ban_sshd_uses_only_nftables
}

fail2ban_action_names() {
    local output header

    output="$(fail2ban-client get sshd actions 2>/dev/null)" || return 1
    header="${output%%$'\n'*}"
    [[ "$header" == "The jail sshd has the following actions:" ]] || return 1
    printf '%s\n' "$output" |
        sed '1d' |
        tr ',' '\n' |
        sed 's/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d'
}

fail2ban_sshd_runtime_ports_match() {
    local expected_ports actions action action_ports normalized_ports
    local checked=0

    expected_ports="$(normalize_port_csv "${1:-}")" || return 1
    [ -n "$expected_ports" ] || return 1
    actions="$(fail2ban_action_names)" || return 1
    [ -n "$actions" ] || return 1

    while IFS= read -r action; do
        [ -n "$action" ] || continue
        action_ports="$(fail2ban-client get sshd action "$action" port 2>/dev/null)" || return 1
        action_ports="${action_ports//[[:space:]]/}"
        normalized_ports="$(normalize_port_csv "$action_ports")" || return 1
        [ -n "$normalized_ports" ] && [ "$normalized_ports" = "$expected_ports" ] || return 1
        checked=1
    done <<< "$actions"

    [ "$checked" -eq 1 ]
}

fail2ban_deep_check_error() {
    if [ "${FAIL2BAN_DEEP_CHECK_WARN_ONLY:-0}" = "1" ]; then
        warn "$@" >&2
    else
        err "$@"
    fi
}

fail2ban_single_action_line() {
    local line

    line="$(printf '%s\n' "$1" |
        sed 's/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d')"
    [ -n "$line" ] && [[ "$line" != *$'\n'* ]] || return 1
    printf '%s\n' "$line"
}

fail2ban_action_executable() {
    local line="$1" executable

    read -r executable _ <<< "$line"
    executable="${executable#\"}"
    executable="${executable%\"}"
    printf '%s\n' "$executable"
}

fail2ban_simple_action_is_safe() {
    local actionban="$1"

    [[ "$actionban" != *';'* ]] &&
        [[ "$actionban" != *'|'* ]] &&
        [[ "$actionban" != *'&'* ]] &&
        [[ "$actionban" != *'`'* ]] &&
        [[ "$actionban" != *'$('* ]]
}

fail2ban_action_backend() {
    local action="$1" actionban="$2" line executable

    # vpsbox 只写入 nftables-multiport；深度检测拒绝其他动作，避免测试封禁
    # 意外触发邮件、外部命令或与受管配置不一致的防火墙后端。
    [[ "$actionban" == *'<ip>'* ]] || return 1
    case "$action" in
        nftables|nftables-multiport|nftables-allports)
            fail2ban_simple_action_is_safe "$actionban" || return 1
            line="$(fail2ban_single_action_line "$actionban")" || return 1
            executable="$(fail2ban_action_executable "$line")"
            case "$executable" in nft|*/nft|'<nft>'|'<nftables>') ;; *) return 1 ;; esac
            [[ " $line " == *' add element '* ]] || return 1
            printf '%s\n' nftables
            ;;
        *) return 1 ;;
    esac
}

fail2ban_effective_firewall_backends() {
    local actions action actionban backend backends=""

    actions="$(fail2ban_action_names)" || {
        fail2ban_deep_check_error "无法读取 Fail2ban sshd jail 的动作列表，已取消真实封禁验证。"
        return 1
    }
    [ -n "$actions" ] || {
        fail2ban_deep_check_error "Fail2ban sshd jail 没有可验证的封禁动作。"
        return 1
    }

    while IFS= read -r action; do
        [ -n "$action" ] || continue
        actionban="$(fail2ban-client get sshd action "$action" actionban 2>/dev/null)" || {
            fail2ban_deep_check_error "无法读取 Fail2ban 动作 $action 的实际封禁命令。"
            return 1
        }
        [ -n "$actionban" ] || {
            fail2ban_deep_check_error "Fail2ban 动作 $action 没有实际封禁命令。"
            return 1
        }
        backend="$(fail2ban_action_backend "$action" "$actionban")" || {
            fail2ban_deep_check_error "Fail2ban 动作 $action 不是受支持的纯防火墙封禁命令；为避免通知或外部副作用，未执行测试封禁。"
            return 1
        }
        if ! grep -qxF "$backend" <<< "$backends"; then
            backends+="${backends:+$'\n'}$backend"
        fi
    done <<< "$actions"

    [ -n "$backends" ] || return 1
    printf '%s\n' "$backends"
}

fail2ban_sshd_uses_only_nftables() {
    local backends

    backends="$(fail2ban_effective_firewall_backends 2>/dev/null)" || return 1
    [ "$backends" = "nftables" ]
}

install_fail2ban_nftables_dependency() {
    # 这里只补齐 Fail2ban 动作需要的 nft 命令；不启用 nftables.service，
    # 不写入 /etc/nftables.conf，也不调用 vpsbox 主机防火墙模块。
    detect_os

    case "$OS" in
        alpine)
            apk_bounded "$PACKAGE_UPDATE_TIMEOUT" update || return 1
            apk_bounded "$PACKAGE_INSTALL_TIMEOUT" add --no-cache nftables || return 1
            ;;
        debian)
            export DEBIAN_FRONTEND=noninteractive
            apt_get_bounded "$PACKAGE_UPDATE_TIMEOUT" update || return 1
            apt_get_bounded "$PACKAGE_INSTALL_TIMEOUT" install -y nftables || return 1
            ;;
        redhat)
            if command -v dnf >/dev/null 2>&1; then
                dnf_bounded "$PACKAGE_INSTALL_TIMEOUT" install -y nftables || return 1
            else
                yum_bounded "$PACKAGE_INSTALL_TIMEOUT" install -y nftables || return 1
            fi
            ;;
        *)
            err "未识别系统类型，无法自动安装 Fail2ban 的 nftables 依赖。"
            return 1
            ;;
    esac
}

ensure_fail2ban_nftables_dependency() {
    command -v nft >/dev/null 2>&1 && return 0

    info "Fail2ban 缺少 nftables 后端依赖，正在自动补齐..."
    if ! install_fail2ban_nftables_dependency; then
        err "Fail2ban 的 nftables 后端依赖安装失败，请检查软件源或网络。"
        return 1
    fi
    command -v nft >/dev/null 2>&1 || {
        err "nftables 安装后仍找不到 nft 命令。"
        return 1
    }
}

fail2ban_backend_dump() {
    local backend="$1"

    case "$backend" in
        nftables)
            command -v nft >/dev/null 2>&1 || return 1
            nft list ruleset 2>/dev/null
            ;;
        *) return 1 ;;
    esac
}

fail2ban_backends_readable() {
    local backends="$1" backend

    while IFS= read -r backend; do
        [ -n "$backend" ] || continue
        if ! fail2ban_backend_dump "$backend" >/dev/null; then
            fail2ban_deep_check_error "无法读取 Fail2ban 的 $backend 防火墙后端；请检查对应命令与运行状态。"
            return 1
        fi
    done <<< "$backends"
}

fail2ban_ipv4_in_text() {
    local ip="$1"
    local text="${2:-}"
    local escaped

    is_ipv4_address "$ip" || return 1
    escaped="${ip//./\\.}"
    grep -Eq "(^|[^0-9.])${escaped}(/32)?([^0-9./]|$)" <<< "$text"
}

fail2ban_jail_has_ip() {
    local ip="$1" output

    output="$(fail2ban-client get sshd banip 2>/dev/null)" || return 2
    fail2ban_ipv4_in_text "$ip" "$output"
}

fail2ban_backend_has_ip() {
    local backend="$1" ip="$2" output

    output="$(fail2ban_backend_dump "$backend")" || return 2
    fail2ban_ipv4_in_text "$ip" "$output"
}

fail2ban_test_state_present() {
    local ip="$1" backends="$2" backend status

    if fail2ban_jail_has_ip "$ip"; then
        :
    else
        status=$?
        [ "$status" -eq 1 ] && return 1
        return 2
    fi
    while IFS= read -r backend; do
        [ -n "$backend" ] || continue
        if fail2ban_backend_has_ip "$backend" "$ip"; then
            :
        else
            status=$?
            [ "$status" -eq 1 ] && return 1
            return 2
        fi
    done <<< "$backends"
    return 0
}

fail2ban_test_state_absent() {
    local ip="$1" backends="$2" backend status

    if fail2ban_jail_has_ip "$ip"; then
        return 1
    else
        status=$?
        [ "$status" -eq 1 ] || return 2
    fi
    while IFS= read -r backend; do
        [ -n "$backend" ] || continue
        if fail2ban_backend_has_ip "$backend" "$ip"; then
            return 1
        else
            status=$?
            [ "$status" -eq 1 ] || return 2
        fi
    done <<< "$backends"
    return 0
}

fail2ban_test_client_ipv4() {
    local ip=""

    if [ -n "${SSH_CONNECTION:-}" ]; then
        ip="${SSH_CONNECTION%% *}"
    elif [ -n "${SSH_CLIENT:-}" ]; then
        ip="${SSH_CLIENT%% *}"
    fi
    is_ipv4_address "$ip" && printf '%s\n' "$ip"
}

fail2ban_local_ipv4_text() {
    if command -v ip >/dev/null 2>&1; then
        ip -o -4 addr show 2>/dev/null
    elif command -v hostname >/dev/null 2>&1; then
        hostname -I 2>/dev/null
    else
        return 1
    fi
}

fail2ban_select_test_ip() {
    local backends="$1" client_ip local_ipv4 candidate status
    local -a candidates=(
        "192.0.2.254" "198.51.100.254" "203.0.113.254"
        "192.0.2.253" "198.51.100.253" "203.0.113.253"
    )

    client_ip="$(fail2ban_test_client_ipv4 || true)"
    local_ipv4="$(fail2ban_local_ipv4_text)" || return 1
    for candidate in "${candidates[@]}"; do
        [ "$candidate" = "$client_ip" ] && continue
        fail2ban_ipv4_in_text "$candidate" "$local_ipv4" && continue
        if fail2ban_test_state_absent "$candidate" "$backends"; then
            printf '%s\n' "$candidate"
            return 0
        else
            status=$?
            [ "$status" -eq 1 ] && continue
            return 1
        fi
    done
    return 1
}

cleanup_active_fail2ban_test() {
    local ip="${ACTIVE_FAIL2BAN_TEST_IP:-}"
    local backends="${ACTIVE_FAIL2BAN_TEST_BACKENDS:-}"
    local attempt

    [ -n "$ip" ] || return 0
    for attempt in 1 2 3 4 5; do
        fail2ban-client set sshd unbanip "$ip" >/dev/null 2>&1 || true
        if fail2ban_test_state_absent "$ip" "$backends"; then
            ACTIVE_FAIL2BAN_TEST_IP=""
            ACTIVE_FAIL2BAN_TEST_BACKENDS=""
            return 0
        fi
        [ "$attempt" -lt 5 ] && sleep 1
    done

    fail2ban_deep_check_error "Fail2ban 测试地址 $ip 未能自动完全解封。"
    fail2ban_deep_check_error "请保持当前 SSH 会话并执行：fail2ban-client set sshd unbanip $ip"
    return 1
}

verify_fail2ban_real_ban() {
    local backends test_ip attempt present=0

    if [ -n "${ACTIVE_FAIL2BAN_TEST_IP:-}" ] && ! cleanup_active_fail2ban_test; then
        fail2ban_deep_check_error "上一次 Fail2ban 测试地址仍未清理，已拒绝开始新的验证。"
        return 2
    fi
    backends="$(fail2ban_effective_firewall_backends)" || return 1
    fail2ban_backends_readable "$backends" || return 1
    test_ip="$(fail2ban_select_test_ip "$backends")" || {
        fail2ban_deep_check_error "无法选出未被占用的 TEST-NET IPv4 测试地址。"
        return 1
    }

    ACTIVE_FAIL2BAN_TEST_IP="$test_ip"
    ACTIVE_FAIL2BAN_TEST_BACKENDS="$backends"
    info "正在验证 Fail2ban sshd jail 与实际防火墙封禁链路..."
    if ! fail2ban-client set sshd banip "$test_ip" >/dev/null 2>&1; then
        fail2ban_deep_check_error "Fail2ban 测试封禁命令执行失败。"
        if cleanup_active_fail2ban_test; then
            return 1
        fi
        return 2
    fi
    for attempt in 1 2 3 4 5; do
        if fail2ban_test_state_present "$test_ip" "$backends"; then
            present=1
            break
        fi
        [ "$attempt" -lt 5 ] && sleep 1
    done
    if [ "$present" -ne 1 ]; then
        fail2ban_deep_check_error "测试地址未同时出现在 sshd jail 与实际防火墙后端。"
        if cleanup_active_fail2ban_test; then
            return 1
        fi
        return 2
    fi
    if ! cleanup_active_fail2ban_test; then
        return 2
    fi

    info "Fail2ban 真实封禁、后端落地与解封清理验证通过。"
}

verify_fail2ban_real_ban_advisory() {
    local FAIL2BAN_DEEP_CHECK_WARN_ONLY=1
    local status

    if verify_fail2ban_real_ban; then
        return 0
    else
        status=$?
    fi
    if [ "$status" -eq 2 ] || [ -n "${ACTIVE_FAIL2BAN_TEST_IP:-}" ]; then
        return 2
    fi
    warn "Fail2ban 基础配置已通过，但真实封禁深度检测未通过；已保留当前配置。"
    return 0
}

chrony_service_name() {
    detect_os
    case "$OS" in
        debian) echo "chrony" ;;
        redhat) echo "chronyd" ;;
        *) echo "chrony" ;;
    esac
}

chrony_conf_path() {
    detect_os
    case "$OS" in
        redhat) echo "/etc/chrony.conf" ;;
        *) echo "/etc/chrony/chrony.conf" ;;
    esac
}

ntp_sync_state() {
    local svc

    if ! is_systemd; then
        echo "不支持"
        return
    fi

    svc="$(chrony_service_name)"
    if ! command -v chronyc >/dev/null 2>&1 &&
        ! systemctl list-unit-files "${svc}.service" 2>/dev/null | grep -q "^${svc}\\.service"; then
        echo "未安装"
        return
    fi

    if ! systemctl is-active --quiet "$svc" 2>/dev/null; then
        echo "未运行"
        return
    fi

    if command -v chronyc >/dev/null 2>&1 &&
        chronyc tracking 2>/dev/null | grep -Eq '^Leap status[[:space:]]*:[[:space:]]*Normal'; then
        echo "已同步"
    else
        echo "运行中"
    fi
}

chrony_vpsbox_markers_valid() {
    local file="$1" begin_count end_count begin_line end_line

    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    begin_count="$(grep -Fxc "$NTP_SOURCES_BEGIN" "$file" 2>/dev/null || true)"
    end_count="$(grep -Fxc "$NTP_SOURCES_END" "$file" 2>/dev/null || true)"
    if [ "$begin_count" = "0" ] && [ "$end_count" = "0" ]; then
        return 0
    fi
    [ "$begin_count" = "1" ] && [ "$end_count" = "1" ] || return 1
    begin_line="$(grep -Fnx "$NTP_SOURCES_BEGIN" "$file" | cut -d: -f1)"
    end_line="$(grep -Fnx "$NTP_SOURCES_END" "$file" | cut -d: -f1)"
    [ "$begin_line" -lt "$end_line" ]
}

render_chrony_main_without_vpsbox_block() {
    local file="$1"

    chrony_vpsbox_markers_valid "$file" || return 1
    awk -v begin="$NTP_SOURCES_BEGIN" -v end="$NTP_SOURCES_END" '
        $0 == begin { skip=1; next }
        $0 == end { skip=0; next }
        !skip { print }
    ' "$file"
}

chrony_main_uses_source_dir() {
    local file="$1"

    render_chrony_main_without_vpsbox_block "$file" |
        grep -Eq '^[[:space:]]*sourcedir[[:space:]]+/etc/chrony/sources\.d/?([[:space:]]|$)'
}

stage_chrony_main_config() {
    local conf="$1" use_source_dir="$2" output_var="$3"
    local parent tmp owner group mode

    chrony_vpsbox_markers_valid "$conf" || return 1
    parent="$(dirname "$conf")"
    [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
    owner="$(stat -c '%u' "$conf" 2>/dev/null)" || return 1
    group="$(stat -c '%g' "$conf" 2>/dev/null)" || return 1
    mode="$(stat -c '%a' "$conf" 2>/dev/null)" || return 1
    tmp="$(mktemp "$parent/.vpsbox-chrony.XXXXXX")" || return 1
    if ! render_chrony_main_without_vpsbox_block "$conf" > "$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    if [ "$use_source_dir" = "0" ]; then
        # --- BEGIN GENERATED TEMPLATE: chrony managed source block ---
        if ! cat >> "$tmp" <<EOF

$NTP_SOURCES_BEGIN
pool time.cloudflare.com iburst maxsources 4
pool pool.ntp.org iburst maxsources 4
$NTP_SOURCES_END
EOF
        # --- END GENERATED TEMPLATE: chrony managed source block ---
        then
            rm -f -- "$tmp"
            return 1
        fi
    fi
    if ! chown "$owner:$group" "$tmp" || ! chmod "$mode" "$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    printf -v "$output_var" '%s' "$tmp"
}

write_chrony_sources() {
    local conf tmp main_tmp use_source_dir=0
    local source_file="$CHRONY_SOURCE_FILE"

    conf="$(chrony_conf_path)"
    if [ ! -f "$conf" ]; then
        err "未找到 chrony 配置文件：$conf"
        return 1
    fi

    chrony_vpsbox_markers_valid "$conf" || {
        err "chrony 配置中的 vpsbox NTP 标记不完整、重复或顺序错误，已拒绝修改：$conf"
        return 1
    }
    if chrony_main_uses_source_dir "$conf"; then
        use_source_dir=1
        ensure_public_config_dir "$(dirname "$source_file")" "$source_file" || return 1
        tmp="$(mktemp "$(dirname "$source_file")/.vpsbox.sources.XXXXXX")" || return 1
        # --- BEGIN GENERATED TEMPLATE: chrony source file ---
        if ! cat > "$tmp" <<EOF
pool time.cloudflare.com iburst maxsources 4
pool pool.ntp.org iburst maxsources 4
EOF
        # --- END GENERATED TEMPLATE: chrony source file ---
        then
            rm -f -- "$tmp"
            return 1
        fi
        if ! chown root:root "$tmp" || ! chmod 644 "$tmp"; then
            rm -f -- "$tmp"
            return 1
        fi
    fi

    if ! stage_chrony_main_config "$conf" "$use_source_dir" main_tmp; then
        [ -z "${tmp:-}" ] || rm -f -- "$tmp"
        return 1
    fi
    if ! cmp -s "$main_tmp" "$conf" && ! mv -f -- "$main_tmp" "$conf"; then
        rm -f -- "$main_tmp"
        [ -z "${tmp:-}" ] || rm -f -- "$tmp"
        return 1
    fi
    [ -e "$main_tmp" ] && rm -f -- "$main_tmp"

    if [ "$use_source_dir" = "1" ]; then
        if ! mv -f -- "$tmp" "$source_file"; then
            rm -f -- "$tmp"
            return 1
        fi
        info "已写入 NTP 源：$source_file"
    else
        rm -f -- "$source_file" || return 1
        info "已写入 NTP 源：$conf"
    fi
}

chrony_expected_sources() {
    # --- BEGIN GENERATED TEMPLATE: chrony expected source set ---
    cat <<EOF
pool time.cloudflare.com iburst maxsources 4
pool pool.ntp.org iburst maxsources 4
EOF
    # --- END GENERATED TEMPLATE: chrony expected source set ---
}

chrony_sources_are_current() {
    local conf source_file="$CHRONY_SOURCE_FILE"
    local expected actual begin_count end_count

    conf="$(chrony_conf_path)"
    [ -f "$conf" ] && [ ! -L "$conf" ] || return 1
    chrony_vpsbox_markers_valid "$conf" || return 1
    expected="$(chrony_expected_sources)"
    if chrony_main_uses_source_dir "$conf"; then
        [ -f "$source_file" ] && [ ! -L "$source_file" ] || return 1
        actual="$(cat "$source_file")"
        [ "$actual" = "$expected" ] || return 1
        ! grep -Fq "$NTP_SOURCES_BEGIN" "$conf" &&
            ! grep -Fq "$NTP_SOURCES_END" "$conf"
        return
    fi

    [ ! -e "$source_file" ] && [ ! -L "$source_file" ] || return 1
    begin_count="$(grep -Fxc "$NTP_SOURCES_BEGIN" "$conf" 2>/dev/null || true)"
    end_count="$(grep -Fxc "$NTP_SOURCES_END" "$conf" 2>/dev/null || true)"
    [ "$begin_count" = "1" ] && [ "$end_count" = "1" ] || return 1
    actual="$(sed -n "/^${NTP_SOURCES_BEGIN}$/,/^${NTP_SOURCES_END}$/p" "$conf")"
    [ "$actual" = "$NTP_SOURCES_BEGIN
$expected
$NTP_SOURCES_END" ]
}

ntp_service_state_is_healthy() {
    local svc="$1"

    systemctl is-enabled --quiet "$svc" 2>/dev/null &&
        systemctl is-active --quiet "$svc" 2>/dev/null || return 1
    if systemd_unit_exists systemd-timesyncd.service; then
        ! systemctl is-enabled --quiet systemd-timesyncd 2>/dev/null &&
            ! systemctl is-active --quiet systemd-timesyncd 2>/dev/null || return 1
    fi
}

ntp_unit_state_matches() {
    local unit="$1" existed="$2" enabled="$3" active="$4"
    local enabled_state active_state

    if [ "$existed" = "absent" ]; then
        ! systemd_unit_exists "${unit}.service"
        return
    fi
    [ "$existed" = "present" ] || return 1
    systemd_unit_exists "${unit}.service" || return 1
    enabled_state="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
    active_state="$(systemctl is-active "$unit" 2>/dev/null || true)"
    case "$enabled:$enabled_state" in
        enabled:enabled|enabled:enabled-runtime|enabled:linked|\
            enabled:linked-runtime|enabled:alias|disabled:disabled|\
            disabled:static|disabled:indirect|disabled:masked|\
            disabled:masked-runtime|disabled:generated|disabled:transient) ;;
        *) return 1 ;;
    esac
    case "$active:$active_state" in
        active:active|active:reloading|inactive:inactive|inactive:failed) ;;
        *) return 1 ;;
    esac
}

restore_ntp_service_runtime_state() {
    local svc="$1" chrony_enabled="$2" chrony_active="$3"
    local timesyncd_unit="$4" timesyncd_enabled="$5" timesyncd_active="$6"
    local failed=0

    restore_ntp_unit_state "$svc" present \
        "$chrony_enabled" "$chrony_active" || failed=1
    restore_ntp_unit_state systemd-timesyncd "$timesyncd_unit" \
        "$timesyncd_enabled" "$timesyncd_active" || failed=1
    ntp_unit_state_matches "$svc" present \
        "$chrony_enabled" "$chrony_active" || failed=1
    ntp_unit_state_matches systemd-timesyncd "$timesyncd_unit" \
        "$timesyncd_enabled" "$timesyncd_active" || failed=1
    return "$failed"
}

repair_ntp_service_state() {
    local svc="$1" failed=0 timesyncd_unit="absent"
    local chrony_enabled="disabled" chrony_active="inactive"
    local timesyncd_enabled="disabled" timesyncd_active="inactive"

    info "NTP 配置已存在，正在轻量修复服务状态..."
    systemctl is-enabled --quiet "$svc" 2>/dev/null && chrony_enabled="enabled"
    systemctl is-active --quiet "$svc" 2>/dev/null && chrony_active="active"
    if systemd_unit_exists systemd-timesyncd.service; then
        timesyncd_unit="present"
        systemctl is-enabled --quiet systemd-timesyncd 2>/dev/null &&
            timesyncd_enabled="enabled"
        systemctl is-active --quiet systemd-timesyncd 2>/dev/null &&
            timesyncd_active="active"
    fi

    if ! arm_ntp_service_runtime_rollback "$svc" \
        "$chrony_enabled" "$chrony_active" \
        "$timesyncd_unit" "$timesyncd_enabled" "$timesyncd_active"; then
        err "无法登记 NTP 服务状态中断回滚，已取消轻量修复。"
        return 1
    fi

    systemctl enable "$svc" >/dev/null 2>&1 || failed=1
    if [ "$failed" -eq 0 ] && ! systemctl is-active --quiet "$svc" 2>/dev/null; then
        retry 3 2 systemctl start "$svc" || failed=1
    fi
    if [ "$failed" -eq 0 ] && [ "$timesyncd_unit" = "present" ] &&
        { systemctl is-enabled --quiet systemd-timesyncd 2>/dev/null ||
            systemctl is-active --quiet systemd-timesyncd 2>/dev/null; }; then
        systemctl disable --now systemd-timesyncd >/dev/null 2>&1 || failed=1
    fi
    if [ "$failed" -eq 0 ] && ntp_service_state_is_healthy "$svc"; then
        clear_active_ntp_operation
        return 0
    fi

    warn "NTP 服务状态轻量修复失败，正在恢复修改前状态。"
    if restore_ntp_service_runtime_state "$svc" \
        "$chrony_enabled" "$chrony_active" \
        "$timesyncd_unit" "$timesyncd_enabled" "$timesyncd_active"; then
        clear_active_ntp_operation
        info "NTP 服务状态已恢复修改前状态。"
    else
        err "NTP 服务状态未能完整恢复，请检查 chrony 与 systemd-timesyncd。"
    fi
    return 1
}

show_ntp_runtime_details() {
    local svc="$1" enabled_state active_state sources_output tracking_output

    enabled_state="$(systemctl is-enabled "$svc" 2>/dev/null || echo "unknown")"
    active_state="$(systemctl is-active "$svc" 2>/dev/null || echo "unknown")"
    info "chrony 开机自启：$enabled_state"
    info "chrony 运行状态：$active_state"

    echo ""
    info "NTP 时间源："
    if ! sources_output="$(chronyc sources -v 2>/dev/null)"; then
        sleep 1
        sources_output="$(chronyc sources -v 2>/dev/null || true)"
    fi
    if [ -n "$sources_output" ]; then
        printf '%s\n' "$sources_output"
    else
        warn "无法读取 chrony 时间源。"
    fi

    echo ""
    info "同步状态："
    tracking_output="$(chronyc tracking 2>/dev/null || true)"
    if [ -n "$tracking_output" ]; then
        printf '%s\n' "$tracking_output"
        if echo "$tracking_output" | grep -Eq '^Leap status[[:space:]]*:[[:space:]]*Normal'; then
            info "NTP 时间同步已启用。"
        else
            warn "chrony 已运行，首次同步可能需要几分钟；当前配置不会重复改写。"
        fi
    else
        warn "无法读取 chrony 同步状态。"
    fi

    echo ""
    info "系统时间关键状态："
    timedatectl show -p Timezone -p NTP -p NTPSynchronized -p TimeUSec 2>/dev/null || true
    warn "如确认需要立即校准，可手动执行：chronyc makestep"
}

systemd_unit_exists() {
    local unit="$1"

    systemctl list-unit-files "$unit" 2>/dev/null | grep -q "^${unit//./\\.}"
}

ntp_package_installed() {
    local package="$1"

    case "$OS" in
        debian)
            dpkg-query -W -f='${Status}\n' "$package" 2>/dev/null |
                grep -qx 'install ok installed'
            ;;
        redhat)
            rpm -q "$package" >/dev/null 2>&1
            ;;
        *)
            return 1
            ;;
    esac
}

restore_ntp_packages_to_state() {
    local chrony_state="$1" timesyncd_state="${2:-}" failed=0

    case "$chrony_state" in installed|absent) ;; *) return 1 ;; esac
    case "$OS" in
        debian)
            case "$timesyncd_state" in installed|absent) ;; *) return 1 ;; esac
            export DEBIAN_FRONTEND=noninteractive
            if [ "$chrony_state" = "absent" ]; then
                if ntp_package_installed chrony &&
                    ! apt_get_bounded "$PACKAGE_INSTALL_TIMEOUT" purge -y chrony; then
                    failed=1
                fi
                if [ "$timesyncd_state" = "installed" ]; then
                    ntp_package_installed systemd-timesyncd ||
                        apt_get_bounded "$PACKAGE_INSTALL_TIMEOUT" install -y systemd-timesyncd ||
                        failed=1
                elif ntp_package_installed systemd-timesyncd &&
                    ! apt_get_bounded "$PACKAGE_INSTALL_TIMEOUT" purge -y systemd-timesyncd; then
                    failed=1
                fi
            else
                ntp_package_installed chrony ||
                    apt_get_bounded "$PACKAGE_INSTALL_TIMEOUT" install -y chrony ||
                    failed=1
                if [ "$timesyncd_state" = "absent" ] &&
                    ntp_package_installed systemd-timesyncd &&
                    ! apt_get_bounded "$PACKAGE_INSTALL_TIMEOUT" purge -y systemd-timesyncd; then
                    failed=1
                fi
            fi
            ;;
        redhat)
            if [ "$chrony_state" = "installed" ] && ! ntp_package_installed chrony; then
                if command -v dnf >/dev/null 2>&1; then
                    dnf_bounded "$PACKAGE_INSTALL_TIMEOUT" install -y chrony || failed=1
                else
                    yum_bounded "$PACKAGE_INSTALL_TIMEOUT" install -y chrony || failed=1
                fi
            elif [ "$chrony_state" = "absent" ] && ntp_package_installed chrony; then
                if command -v dnf >/dev/null 2>&1; then
                    dnf_bounded "$PACKAGE_INSTALL_TIMEOUT" remove -y chrony || failed=1
                else
                    yum_bounded "$PACKAGE_INSTALL_TIMEOUT" remove -y chrony || failed=1
                fi
            fi
            ;;
        *)
            return 1
            ;;
    esac
    return "$failed"
}

restore_ntp_unit_state() {
    local unit="$1" existed="$2" enabled="$3" active="$4"

    if [ "$existed" = "absent" ]; then
        if systemd_unit_exists "${unit}.service"; then
            systemctl disable --now "$unit" >/dev/null 2>&1 || return 1
        fi
        return 0
    fi
    [ "$existed" = "present" ] || return 1
    systemd_unit_exists "${unit}.service" || return 1
    if [ "$enabled" = "enabled" ]; then
        systemctl enable "$unit" >/dev/null || return 1
    else
        systemctl disable "$unit" >/dev/null || return 1
    fi
    if [ "$active" = "active" ]; then
        systemctl start "$unit" >/dev/null || return 1
    else
        systemctl stop "$unit" >/dev/null || return 1
    fi
}

restore_ntp_snapshot_file() {
    local snapshot_dir="$1" name="$2" target="$3"

    if [ -f "$snapshot_dir/$name.present" ]; then
        [ -f "$snapshot_dir/$name" ] && [ ! -L "$snapshot_dir/$name" ] || return 1
        restore_file_atomically_from_snapshot "$snapshot_dir/$name" "$target"
    elif [ -f "$snapshot_dir/$name.absent" ]; then
        remove_snapshot_target_file "$target"
    else
        return 1
    fi
}

ntp_snapshot_path_allowed() {
    local snapshot_dir="$1" parent base

    parent="$(dirname -- "$snapshot_dir")" || return 1
    base="${snapshot_dir##*/}"
    [ "$parent" = "/tmp" ] && [[ "$base" == vpsbox-chrony.* ]]
}

cleanup_ntp_snapshot() {
    local snapshot_dir="$1"

    ntp_snapshot_path_allowed "$snapshot_dir" &&
        [ -d "$snapshot_dir" ] && [ ! -L "$snapshot_dir" ] || return 1
    rm -rf -- "$snapshot_dir"
}

arm_ntp_runtime_rollback() {
    local snapshot_dir="$1"
    shift

    [ -z "${ACTIVE_NTP_SNAPSHOT:-}" ] &&
        [ "${ACTIVE_NTP_SERVICE_ROLLBACK:-0}" = "0" ] || return 1
    [ "$#" -eq 12 ] || return 1
    ntp_snapshot_path_allowed "$snapshot_dir" &&
        [ -d "$snapshot_dir" ] && [ ! -L "$snapshot_dir" ] || return 1
    ACTIVE_NTP_ROLLBACK_ARGS=("$@")
    # 最后登记目录作为活动标记；此前尚未修改软件包、配置或服务。
    ACTIVE_NTP_SNAPSHOT="$snapshot_dir"
}

arm_ntp_service_runtime_rollback() {
    local svc="$1"
    shift

    [ -z "${ACTIVE_NTP_SNAPSHOT:-}" ] &&
        [ "${ACTIVE_NTP_SERVICE_ROLLBACK:-0}" = "0" ] || return 1
    [ -n "$svc" ] && [ "$#" -eq 5 ] || return 1
    case "$1:$2" in
        enabled:active|enabled:inactive|disabled:active|disabled:inactive) ;;
        *) return 1 ;;
    esac
    case "$3:$4:$5" in
        absent:disabled:inactive|present:enabled:active|present:enabled:inactive|\
            present:disabled:active|present:disabled:inactive) ;;
        *) return 1 ;;
    esac
    ACTIVE_NTP_SERVICE_ROLLBACK_ARGS=("$svc" "$@")
    # 最后登记活动标记；此前尚未修改任何服务状态。
    ACTIVE_NTP_SERVICE_ROLLBACK=1
}

clear_active_ntp_operation() {
    ACTIVE_NTP_SNAPSHOT=""
    ACTIVE_NTP_ROLLBACK_ARGS=()
    ACTIVE_NTP_SERVICE_ROLLBACK=0
    ACTIVE_NTP_SERVICE_ROLLBACK_ARGS=()
    ACTIVE_NTP_TRACKING_CANCEL=0
}

rollback_active_ntp_operation() {
    local snapshot_dir="${ACTIVE_NTP_SNAPSHOT:-}"
    local -a rollback_args=("${ACTIVE_NTP_ROLLBACK_ARGS[@]}")
    local -a service_args=("${ACTIVE_NTP_SERVICE_ROLLBACK_ARGS[@]}")

    if [ "${ACTIVE_NTP_SERVICE_ROLLBACK:-0}" = "1" ]; then
        [ -z "$snapshot_dir" ] && [ "${#service_args[@]}" -eq 6 ] || return 1
        restore_ntp_service_runtime_state "${service_args[@]}" || return 1
        clear_active_ntp_operation
        return 0
    fi

    if [ -n "$snapshot_dir" ]; then
        [ "${#rollback_args[@]}" -eq 12 ] || return 1
        settle_failed_ntp_change "$snapshot_dir" "${rollback_args[@]}"
        return
    fi
    if [ "${ACTIVE_NTP_TRACKING_CANCEL:-0}" = "1" ]; then
        cancel_unmodified_ntp_tracking 0
    fi
}

rollback_ntp_runtime_state() {
    local snapshot_dir="$1" conf="$2" source_file="$3" svc="$4"
    local chrony_package="$5" timesyncd_package="$6"
    local chrony_unit="$7" chrony_enabled="$8" chrony_active="$9"
    local timesyncd_unit="${10}" timesyncd_enabled="${11}" timesyncd_active="${12}"
    local failed=0

    systemctl stop "$svc" >/dev/null 2>&1 || true
    restore_ntp_packages_to_state "$chrony_package" "$timesyncd_package" || failed=1
    restore_ntp_snapshot_file "$snapshot_dir" conf "$conf" || failed=1
    restore_ntp_snapshot_file "$snapshot_dir" sources "$source_file" || failed=1
    restore_ntp_unit_state "$svc" "$chrony_unit" "$chrony_enabled" "$chrony_active" ||
        failed=1
    restore_ntp_unit_state systemd-timesyncd "$timesyncd_unit" \
        "$timesyncd_enabled" "$timesyncd_active" || failed=1
    return "$failed"
}

clear_ntp_change_tracking() {
    local key failed=0

    clear_change_tracking NTP_CONF || failed=1
    clear_change_tracking NTP_SOURCES || failed=1
    for key in NTP_CHRONY_ACTIVE NTP_CHRONY_ENABLED NTP_CHRONY_PACKAGE \
        NTP_CHRONY_UNIT NTP_TIMESYNCD_ACTIVE NTP_TIMESYNCD_ENABLED \
        NTP_TIMESYNCD_PACKAGE NTP_TIMESYNCD_UNIT; do
        manifest_remove "$key" || failed=1
    done
    return "$failed"
}

cancel_unmodified_ntp_tracking() {
    local applied_before="$1"

    case "$applied_before" in
        0)
            clear_ntp_change_tracking || return 1
            ACTIVE_NTP_TRACKING_CANCEL=0
            ;;
        1) return 0 ;;
        *) return 1 ;;
    esac
}

settle_failed_ntp_change() {
    local snapshot_dir="$1" conf="$2" source_file="$3" svc="$4"
    local chrony_package="$5" timesyncd_package="$6"
    local chrony_unit="$7" chrony_enabled="$8" chrony_active="$9"
    local timesyncd_unit="${10}" timesyncd_enabled="${11}" timesyncd_active="${12}"
    local applied_before="${13}"

    if ! rollback_ntp_runtime_state "$snapshot_dir" "$conf" "$source_file" "$svc" \
        "$chrony_package" "$timesyncd_package" \
        "$chrony_unit" "$chrony_enabled" "$chrony_active" \
        "$timesyncd_unit" "$timesyncd_enabled" "$timesyncd_active"; then
        err "NTP 原状态未能完整恢复；恢复记录与临时快照已保留：$snapshot_dir"
        return 1
    fi
    if ! cancel_unmodified_ntp_tracking "$applied_before"; then
        warn "NTP 已回滚，但变更清单清理失败；恢复菜单仍会保留该项目。"
        return 1
    fi
    if [ "${ACTIVE_NTP_SNAPSHOT:-}" = "$snapshot_dir" ]; then
        clear_active_ntp_operation
    fi
    cleanup_ntp_snapshot "$snapshot_dir" ||
        warn "NTP 已回滚，但临时快照清理失败：$snapshot_dir"
}

ntp_restore_metadata_values_valid() {
    [ "$#" -eq 8 ] || return 1
    case "$1" in installed|absent) ;; *) return 1 ;; esac
    case "$2" in installed|absent) ;; *) return 1 ;; esac
    case "$3" in present|absent) ;; *) return 1 ;; esac
    case "$4" in present|absent) ;; *) return 1 ;; esac
    case "$5" in enabled|disabled) ;; *) return 1 ;; esac
    case "$6" in active|inactive) ;; *) return 1 ;; esac
    case "$7" in enabled|disabled) ;; *) return 1 ;; esac
    case "$8" in active|inactive) ;; *) return 1 ;; esac
}

recorded_ntp_metadata_is_complete() {
    ntp_restore_metadata_values_valid \
        "$(manifest_value NTP_CHRONY_PACKAGE 2>/dev/null || true)" \
        "$(manifest_value NTP_TIMESYNCD_PACKAGE 2>/dev/null || true)" \
        "$(manifest_value NTP_CHRONY_UNIT 2>/dev/null || true)" \
        "$(manifest_value NTP_TIMESYNCD_UNIT 2>/dev/null || true)" \
        "$(manifest_value NTP_CHRONY_ENABLED 2>/dev/null || true)" \
        "$(manifest_value NTP_CHRONY_ACTIVE 2>/dev/null || true)" \
        "$(manifest_value NTP_TIMESYNCD_ENABLED 2>/dev/null || true)" \
        "$(manifest_value NTP_TIMESYNCD_ACTIVE 2>/dev/null || true)" &&
        change_backup_record_is_valid NTP_CONF &&
        change_backup_record_is_valid NTP_SOURCES
}

restore_recorded_ntp_change() {
    local svc chrony_package timesyncd_package chrony_unit timesyncd_unit
    local chrony_enabled chrony_active timesyncd_enabled timesyncd_active failed=0

    detect_os
    is_systemd || return 1
    svc="$(chrony_service_name)"
    chrony_package="$(manifest_value NTP_CHRONY_PACKAGE 2>/dev/null || true)"
    timesyncd_package="$(manifest_value NTP_TIMESYNCD_PACKAGE 2>/dev/null || true)"
    chrony_unit="$(manifest_value NTP_CHRONY_UNIT 2>/dev/null || true)"
    timesyncd_unit="$(manifest_value NTP_TIMESYNCD_UNIT 2>/dev/null || true)"
    chrony_enabled="$(manifest_value NTP_CHRONY_ENABLED 2>/dev/null || true)"
    chrony_active="$(manifest_value NTP_CHRONY_ACTIVE 2>/dev/null || true)"
    timesyncd_enabled="$(manifest_value NTP_TIMESYNCD_ENABLED 2>/dev/null || true)"
    timesyncd_active="$(manifest_value NTP_TIMESYNCD_ACTIVE 2>/dev/null || true)"
    if ! ntp_restore_metadata_values_valid \
        "$chrony_package" "$timesyncd_package" "$chrony_unit" "$timesyncd_unit" \
        "$chrony_enabled" "$chrony_active" "$timesyncd_enabled" "$timesyncd_active" ||
        ! change_backup_record_is_valid NTP_CONF ||
        ! change_backup_record_is_valid NTP_SOURCES; then
        err "NTP 恢复记录不完整或格式不正确，已拒绝修改服务、软件包和配置。"
        return 1
    fi

    systemctl stop "$svc" >/dev/null 2>&1 || true
    restore_ntp_packages_to_state "$chrony_package" "$timesyncd_package" ||
        failed=1
    restore_change_file NTP_CONF "$(chrony_conf_path)" || failed=1
    restore_change_file NTP_SOURCES "$CHRONY_SOURCE_FILE" || failed=1

    restore_ntp_unit_state "$svc" "$chrony_unit" "$chrony_enabled" "$chrony_active" ||
        failed=1
    restore_ntp_unit_state systemd-timesyncd "$timesyncd_unit" \
        "$timesyncd_enabled" "$timesyncd_active" || failed=1
    return "$failed"
}

show_chrony_permission_hint() {
    local svc="$1"
    local logs

    logs="$(journalctl -u "$svc" -n 30 --no-pager 2>/dev/null || true)"
    if echo "$logs" | grep -Eqi 'adjtimex|Operation not permitted'; then
        warn "检测到 chrony 无权限调整系统时间。"
        warn "当前可能是 LXC/OpenVZ 容器 VPS，实例内无法自行校时，请依赖宿主机 NTP 或联系服务商。"
    else
        warn "chrony 未正常启动，可执行以下命令查看原因："
        warn "journalctl -u $svc -n 50 --no-pager"
    fi
}

enable_ntp_sync() {
    local svc
    local conf source_file backup_dir
    local chrony_package="absent" timesyncd_package="absent"
    local chrony_unit="absent" timesyncd_unit="absent"
    local chrony_active="inactive" chrony_enabled="disabled"
    local timesyncd_active="inactive" timesyncd_enabled="disabled"
    local applied_before=0

    { [ -z "${ACTIVE_NTP_SNAPSHOT:-}" ] &&
        [ "${ACTIVE_NTP_SERVICE_ROLLBACK:-0}" = "0" ] &&
        [ "${ACTIVE_NTP_TRACKING_CANCEL:-0}" = "0" ]; } || {
        err "当前进程仍有未完成的 NTP 回滚，已拒绝开始新的修改。"
        return 1
    }
    detect_os
    if ! is_systemd; then
        if [ "$OS" = "alpine" ]; then
            err "Alpine/OpenRC 当前不适用此功能；vpsbox 不会自动修改 chrony。"
        else
            err "未检测到 systemd，无法自动配置 chrony。"
        fi
        return 1
    fi

    svc="$(chrony_service_name)"
    conf="$(chrony_conf_path)"
    source_file="$CHRONY_SOURCE_FILE"
    if ntp_package_installed chrony &&
        systemd_unit_exists "${svc}.service" &&
        chrony_sources_are_current; then
        if ntp_service_state_is_healthy "$svc"; then
            info "NTP 配置与 chrony 服务已正常，无需重复安装或改写。"
        elif ! repair_ntp_service_state "$svc"; then
            err "NTP 配置正确，但 chrony 服务状态修复失败。"
            show_chrony_permission_hint "$svc"
            return 1
        fi
        show_ntp_runtime_details "$svc"
        return 0
    fi
    if [ -L "$conf" ] || { [ -e "$conf" ] && [ ! -f "$conf" ]; }; then
        err "chrony 配置不是普通文件，已拒绝修改：$conf"
        return 1
    fi
    if [ -L "$source_file" ] ||
        { [ -e "$source_file" ] && [ ! -f "$source_file" ]; }; then
        err "NTP 源配置不是普通文件，已拒绝修改：$source_file"
        return 1
    fi
    if [ -f "$conf" ] && ! chrony_vpsbox_markers_valid "$conf"; then
        err "chrony 配置中的 vpsbox NTP 标记不完整、重复或顺序错误，已拒绝修改：$conf"
        return 1
    fi

    ntp_package_installed chrony && chrony_package="installed"
    if [ "$OS" = "debian" ] && ntp_package_installed systemd-timesyncd; then
        timesyncd_package="installed"
    fi
    if systemd_unit_exists "${svc}.service"; then
        chrony_unit="present"
        systemctl is-active --quiet "$svc" 2>/dev/null && chrony_active="active"
        systemctl is-enabled --quiet "$svc" 2>/dev/null && chrony_enabled="enabled"
    fi
    if systemd_unit_exists systemd-timesyncd.service; then
        timesyncd_unit="present"
        systemctl is-active --quiet systemd-timesyncd 2>/dev/null &&
            timesyncd_active="active"
        systemctl is-enabled --quiet systemd-timesyncd 2>/dev/null &&
            timesyncd_enabled="enabled"
    fi

    [ "$(manifest_value APPLIED_NTP_CONF 2>/dev/null || true)" = "1" ] &&
        applied_before=1
    if [ "$applied_before" -eq 0 ]; then
        # 在第一份持久恢复记录前登记只清理记录的活动阶段；此时尚未修改系统。
        ACTIVE_NTP_TRACKING_CANCEL=1
        if ! backup_change_file_once NTP_CONF "$conf" ||
            ! backup_change_file_once NTP_SOURCES "$source_file" ||
            ! manifest_set_once NTP_CHRONY_ACTIVE "$chrony_active" ||
            ! manifest_set_once NTP_CHRONY_ENABLED "$chrony_enabled" ||
            ! manifest_set_once NTP_CHRONY_PACKAGE "$chrony_package" ||
            ! manifest_set_once NTP_CHRONY_UNIT "$chrony_unit" ||
            ! manifest_set_once NTP_TIMESYNCD_ACTIVE "$timesyncd_active" ||
            ! manifest_set_once NTP_TIMESYNCD_ENABLED "$timesyncd_enabled" ||
            ! manifest_set_once NTP_TIMESYNCD_PACKAGE "$timesyncd_package" ||
            ! manifest_set_once NTP_TIMESYNCD_UNIT "$timesyncd_unit"; then
            cancel_unmodified_ntp_tracking "$applied_before" ||
                warn "NTP 尚未修改，但首次恢复记录清理失败；恢复菜单可能保留该项目。"
            err "记录 NTP 原状态失败，已取消修改。"
            return 1
        fi
        mark_change_applied NTP_CONF || {
            cancel_unmodified_ntp_tracking "$applied_before" ||
                warn "NTP 尚未修改，但首次恢复记录清理失败；恢复菜单可能保留该项目。"
            err "无法记录 NTP 事务，已取消修改。"
            return 1
        }
    else
        # 重复配置先验证首次操作前的完整恢复基线，且不得用当前状态覆盖它。
        recorded_ntp_metadata_is_complete || {
            err "现有 NTP 恢复记录不完整，已拒绝继续修改。"
            return 1
        }
    fi

    backup_dir="$(mktemp -d /tmp/vpsbox-chrony.XXXXXX)" || {
        cancel_unmodified_ntp_tracking "$applied_before" ||
            warn "NTP 尚未修改，但首次恢复记录清理失败；恢复菜单可能保留该项目。"
        err "创建 NTP 临时快照目录失败，已取消修改。"
        return 1
    }
    if [ -f "$conf" ] && [ ! -L "$conf" ]; then
        cp -a "$conf" "$backup_dir/conf" &&
            : > "$backup_dir/conf.present" || {
            cleanup_ntp_snapshot "$backup_dir" ||
                warn "NTP 尚未修改，但临时快照清理失败：$backup_dir"
            cancel_unmodified_ntp_tracking "$applied_before" ||
                warn "NTP 尚未修改，但首次恢复记录清理失败；恢复菜单可能保留该项目。"
            return 1
        }
    elif [ ! -e "$conf" ] && [ ! -L "$conf" ]; then
        if ! : > "$backup_dir/conf.absent"; then
            cleanup_ntp_snapshot "$backup_dir" ||
                warn "NTP 尚未修改，但临时快照清理失败：$backup_dir"
            cancel_unmodified_ntp_tracking "$applied_before" ||
                warn "NTP 尚未修改，但首次恢复记录清理失败；恢复菜单可能保留该项目。"
            return 1
        fi
    else
        cleanup_ntp_snapshot "$backup_dir" ||
            warn "NTP 尚未修改，但临时快照清理失败：$backup_dir"
        cancel_unmodified_ntp_tracking "$applied_before" ||
            warn "NTP 尚未修改，但首次恢复记录清理失败；恢复菜单可能保留该项目。"
        err "chrony 配置不是普通文件，已拒绝修改：$conf"
        return 1
    fi
    if [ -f "$source_file" ] && [ ! -L "$source_file" ]; then
        cp -a "$source_file" "$backup_dir/sources" &&
            : > "$backup_dir/sources.present" || {
            cleanup_ntp_snapshot "$backup_dir" ||
                warn "NTP 尚未修改，但临时快照清理失败：$backup_dir"
            cancel_unmodified_ntp_tracking "$applied_before" ||
                warn "NTP 尚未修改，但首次恢复记录清理失败；恢复菜单可能保留该项目。"
            return 1
        }
    elif [ ! -e "$source_file" ] && [ ! -L "$source_file" ]; then
        if ! : > "$backup_dir/sources.absent"; then
            cleanup_ntp_snapshot "$backup_dir" ||
                warn "NTP 尚未修改，但临时快照清理失败：$backup_dir"
            cancel_unmodified_ntp_tracking "$applied_before" ||
                warn "NTP 尚未修改，但首次恢复记录清理失败；恢复菜单可能保留该项目。"
            return 1
        fi
    else
        cleanup_ntp_snapshot "$backup_dir" ||
            warn "NTP 尚未修改，但临时快照清理失败：$backup_dir"
        cancel_unmodified_ntp_tracking "$applied_before" ||
            warn "NTP 尚未修改，但首次恢复记录清理失败；恢复菜单可能保留该项目。"
        err "NTP 源配置不是普通文件，已拒绝修改：$source_file"
        return 1
    fi
    if ! arm_ntp_runtime_rollback "$backup_dir" "$conf" "$source_file" "$svc" \
        "$chrony_package" "$timesyncd_package" \
        "$chrony_unit" "$chrony_enabled" "$chrony_active" \
        "$timesyncd_unit" "$timesyncd_enabled" "$timesyncd_active" \
        "$applied_before"; then
        cleanup_ntp_snapshot "$backup_dir" ||
            warn "NTP 尚未修改，但临时快照清理失败：$backup_dir"
        cancel_unmodified_ntp_tracking "$applied_before" ||
            warn "NTP 尚未修改，但首次恢复记录清理失败；恢复菜单可能保留该项目。"
        err "无法登记 NTP 中断回滚状态，已取消修改。"
        return 1
    fi

    if [ "$chrony_package" = "absent" ]; then
        info "正在安装 chrony..."
        case "$OS" in
            debian)
                export DEBIAN_FRONTEND=noninteractive
                if ! apt_get_bounded "$PACKAGE_UPDATE_TIMEOUT" update ||
                    ! apt_get_bounded "$PACKAGE_INSTALL_TIMEOUT" install -y chrony; then
                    settle_failed_ntp_change "$backup_dir" "$conf" "$source_file" "$svc" \
                        "$chrony_package" "$timesyncd_package" \
                        "$chrony_unit" "$chrony_enabled" "$chrony_active" \
                        "$timesyncd_unit" "$timesyncd_enabled" "$timesyncd_active" \
                        "$applied_before" || true
                    return 1
                fi
                ;;
            redhat)
                if command -v dnf >/dev/null 2>&1; then
                    dnf_bounded "$PACKAGE_INSTALL_TIMEOUT" install -y chrony
                else
                    yum_bounded "$PACKAGE_INSTALL_TIMEOUT" install -y chrony
                fi || {
                    settle_failed_ntp_change "$backup_dir" "$conf" "$source_file" "$svc" \
                        "$chrony_package" "$timesyncd_package" \
                        "$chrony_unit" "$chrony_enabled" "$chrony_active" \
                        "$timesyncd_unit" "$timesyncd_enabled" "$timesyncd_active" \
                        "$applied_before" || true
                    return 1
                }
                ;;
            *)
                settle_failed_ntp_change "$backup_dir" "$conf" "$source_file" "$svc" \
                    "$chrony_package" "$timesyncd_package" \
                    "$chrony_unit" "$chrony_enabled" "$chrony_active" \
                    "$timesyncd_unit" "$timesyncd_enabled" "$timesyncd_active" \
                    "$applied_before" || true
                err "未识别系统类型，无法自动配置 chrony。"
                return 1
                ;;
        esac
    else
        info "chrony 已安装，跳过包管理器，仅修复配置与服务。"
    fi

    if [ ! -f "$conf" ] || [ -L "$conf" ]; then
        err "chrony 安装后未生成有效配置，正在恢复原 NTP 状态。"
        settle_failed_ntp_change "$backup_dir" "$conf" "$source_file" "$svc" \
            "$chrony_package" "$timesyncd_package" \
            "$chrony_unit" "$chrony_enabled" "$chrony_active" \
            "$timesyncd_unit" "$timesyncd_enabled" "$timesyncd_active" \
            "$applied_before" || true
        return 1
    fi
    info "chrony 服务名：$svc"

    if ! systemctl stop "$svc" 2>/dev/null; then
        err "chrony 停止失败，正在恢复原 NTP 状态。"
        settle_failed_ntp_change "$backup_dir" "$conf" "$source_file" "$svc" \
            "$chrony_package" "$timesyncd_package" \
            "$chrony_unit" "$chrony_enabled" "$chrony_active" \
            "$timesyncd_unit" "$timesyncd_enabled" "$timesyncd_active" \
            "$applied_before" || true
        return 1
    fi
    if ! write_chrony_sources; then
        settle_failed_ntp_change "$backup_dir" "$conf" "$source_file" "$svc" \
            "$chrony_package" "$timesyncd_package" \
            "$chrony_unit" "$chrony_enabled" "$chrony_active" \
            "$timesyncd_unit" "$timesyncd_enabled" "$timesyncd_active" \
            "$applied_before" || true
        return 1
    fi

    info "正在启用 chrony 并设置开机自启..."
    if ! systemctl enable --now "$svc"; then
        err "chrony 启动失败，正在恢复原 NTP 配置。"
        settle_failed_ntp_change "$backup_dir" "$conf" "$source_file" "$svc" \
            "$chrony_package" "$timesyncd_package" \
            "$chrony_unit" "$chrony_enabled" "$chrony_active" \
            "$timesyncd_unit" "$timesyncd_enabled" "$timesyncd_active" \
            "$applied_before" || true
        show_chrony_permission_hint "$svc"
        return 1
    fi

    sleep 2
    if ! systemctl is-active --quiet "$svc" 2>/dev/null; then
        err "chrony 未保持运行，正在恢复原 NTP 配置。"
        settle_failed_ntp_change "$backup_dir" "$conf" "$source_file" "$svc" \
            "$chrony_package" "$timesyncd_package" \
            "$chrony_unit" "$chrony_enabled" "$chrony_active" \
            "$timesyncd_unit" "$timesyncd_enabled" "$timesyncd_active" \
            "$applied_before" || true
        show_chrony_permission_hint "$svc"
        return 1
    fi

    if systemd_unit_exists systemd-timesyncd.service; then
        info "chrony 已确认运行，正在停用 systemd-timesyncd，避免多个 NTP 客户端并存..."
        if ! systemctl disable --now systemd-timesyncd; then
            warn "无法停用 systemd-timesyncd；为避免多个 NTP 客户端并存，正在回滚 chrony 配置。"
            settle_failed_ntp_change "$backup_dir" "$conf" "$source_file" "$svc" \
                "$chrony_package" "$timesyncd_package" \
                "$chrony_unit" "$chrony_enabled" "$chrony_active" \
                "$timesyncd_unit" "$timesyncd_enabled" "$timesyncd_active" \
                "$applied_before" || true
            return 1
        fi
    fi
    clear_active_ntp_operation
    cleanup_ntp_snapshot "$backup_dir" ||
        warn "NTP 配置已生效，但临时快照清理失败：$backup_dir"

    show_ntp_runtime_details "$svc"
}

print_ipv4_dns_from_resolvectl() {
    command -v resolvectl >/dev/null 2>&1 || return 1

    local found=1
    local seen=" "
    local line
    local token
    local ip

    while IFS= read -r line; do
        line="${line#*:}"
        for token in $line; do
            ip="${token%%%*}"
            ip="${ip%#*}"
            if is_ipv4_address "$ip"; then
                case "$seen" in
                    *" $ip "*) ;;
                    *)
                        printf ' nameserver %s\n' "$ip"
                        seen="${seen}${ip} "
                        found=0
                        ;;
                esac
            fi
        done
    done < <(resolvectl dns 2>/dev/null)

    return "$found"
}

print_ipv4_dns_from_resolv_conf() {
    [ -r "$RESOLV_CONF" ] || return 1

    local found=1
    local seen=" "
    local keyword
    local ip

    while read -r keyword ip _; do
        [ "$keyword" = "nameserver" ] || continue
        if is_ipv4_address "$ip"; then
            case "$seen" in
                *" $ip "*) ;;
                *)
                    printf ' nameserver %s\n' "$ip"
                    seen="${seen}${ip} "
                    found=0
                    ;;
            esac
        fi
    done < "$RESOLV_CONF"

    return "$found"
}

resolv_conf_managed_by_systemd_resolved() {
    [ -L "$RESOLV_CONF" ] || return 1

    local target
    target="$(readlink "$RESOLV_CONF" 2>/dev/null || true)"

    case "$target" in
        *systemd/resolve*)
            command -v systemctl >/dev/null 2>&1 || return 1
            systemctl list-unit-files systemd-resolved.service 2>/dev/null |
                grep -q '^systemd-resolved\.service' || return 1
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

ipv4_dns_lines() {
    if resolv_conf_managed_by_systemd_resolved; then
        if print_ipv4_dns_from_resolvectl; then
            return 0
        fi
        if print_ipv4_dns_from_resolv_conf; then
            return 0
        fi
        echo " 未检测到 IPv4 DNS"
        return
    fi

    if print_ipv4_dns_from_resolv_conf; then
        return 0
    fi

    if print_ipv4_dns_from_resolvectl; then
        return 0
    fi

    echo " 未检测到 IPv4 DNS"
}

dns_values_line() {
    local dns1="$1"
    local dns2="${2:-}"

    if [ -n "$dns2" ]; then
        printf '%s %s\n' "$dns1" "$dns2"
    else
        printf '%s\n' "$dns1"
    fi
}

verify_dns_resolution() {
    local output

    if command -v getent >/dev/null 2>&1; then
        output="$(run_bounded_command 8 getent ahosts example.com 2>/dev/null)" || return 1
        grep -Eq '^[0-9A-Fa-f:.]+' <<< "$output"
        return
    fi
    if command -v resolvectl >/dev/null 2>&1; then
        run_bounded_command 8 resolvectl query example.com >/dev/null 2>&1
        return
    fi
    return 2
}

resolv_conf_line_is_ipv4_nameserver() {
    local line="$1" keyword="" address="" rest=""

    read -r keyword address rest <<< "$line"
    [ "$keyword" = "nameserver" ] && is_ipv4_address "$address"
}

render_resolv_conf_dns() {
    local dns1="$1" dns2="${2:-}" source="${3:-$RESOLV_CONF}" line

    printf 'nameserver %s\n' "$dns1"
    [ -z "$dns2" ] || printf 'nameserver %s\n' "$dns2"
    if [ -r "$source" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            resolv_conf_line_is_ipv4_nameserver "$line" && continue
            printf '%s\n' "$line"
        done < "$source"
    fi
}

render_systemd_resolved_dns() {
    local dns1="$1" dns2="${2:-}"

    # --- BEGIN GENERATED TEMPLATE: systemd-resolved DNS drop-in ---
    cat <<EOF
[Resolve]
DNS=$(dns_values_line "$dns1" "$dns2")
Domains=~.
EOF
    # --- END GENERATED TEMPLATE: systemd-resolved DNS drop-in ---
}

root_owned_config_file_is_safe_readonly() {
    local path="$1" owner group mode

    [ -f "$path" ] && [ ! -L "$path" ] || return 1
    owner="$(stat -c '%u' "$path" 2>/dev/null)" || return 1
    group="$(stat -c '%g' "$path" 2>/dev/null)" || return 1
    mode="$(stat -c '%a' "$path" 2>/dev/null)" || return 1
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    [ "$owner" = "0" ] && [ "$group" = "0" ] && [ $((8#$mode & 8#022)) -eq 0 ]
}

root_owned_config_dir_is_safe_readonly() {
    local path="$1" owner group mode

    [ -d "$path" ] && [ ! -L "$path" ] || return 1
    owner="$(stat -c '%u' "$path" 2>/dev/null)" || return 1
    group="$(stat -c '%g' "$path" 2>/dev/null)" || return 1
    mode="$(stat -c '%a' "$path" 2>/dev/null)" || return 1
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    [ "$owner" = "0" ] && [ "$group" = "0" ] && [ $((8#$mode & 8#022)) -eq 0 ]
}

create_dns_operation_snapshot() {
    local target="$1" prefix="$2" output_var="$3" created_var="$4"
    local parent snapshot_path="" created=0

    parent="$(dirname "$target")"
    [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
    if [ -f "$target" ] && [ ! -L "$target" ]; then
        snapshot_path="$(mktemp "$parent/$prefix.XXXXXX")" || return 1
        if ! cp -a -- "$target" "$snapshot_path"; then
            rm -f -- "$snapshot_path"
            return 1
        fi
    elif [ ! -e "$target" ] && [ ! -L "$target" ]; then
        created=1
    else
        return 1
    fi
    printf -v "$output_var" '%s' "$snapshot_path"
    printf -v "$created_var" '%s' "$created"
}

restore_dns_operation_snapshot() {
    local snapshot="$1" target="$2" created="$3"

    if [ -n "$snapshot" ]; then
        [ -f "$snapshot" ] && [ ! -L "$snapshot" ] || return 1
        restore_file_atomically_from_snapshot "$snapshot" "$target" || return 1
    elif [ "$created" = "1" ]; then
        remove_snapshot_target_file "$target"
    else
        return 1
    fi
}

remove_dns_operation_snapshot() {
    local snapshot="$1"

    [ -z "$snapshot" ] || rm -f -- "$snapshot"
}

restore_dns_change_tracking() {
    local name="$1" applied_before="$2" failed=0

    if [ "$applied_before" = "1" ]; then
        manifest_set "APPLIED_$name" 1 || failed=1
        manifest_remove "PENDING_$name" || failed=1
    else
        manifest_remove "APPLIED_$name" || failed=1
        cancel_unmodified_change_transaction "$name" || failed=1
    fi
    return "$failed"
}

rollback_dns_change() {
    local name="$1" snapshot="$2" target="$3" created="$4" applied_before="$5"

    restore_dns_operation_snapshot "$snapshot" "$target" "$created" || return 1
    restore_dns_change_tracking "$name" "$applied_before"
}

arm_dns_operation_rollback() {
    local name="$1" snapshot="$2" target="$3" created="$4" applied_before="$5"

    [ -z "${ACTIVE_DNS_OPERATION_NAME:-}" ] || return 1
    case "$name" in DNS_RESOLV|DNS_RESOLVED) ;; *) return 1 ;; esac
    case "$created:$applied_before" in
        0:0|0:1|1:0|1:1) ;;
        *) return 1 ;;
    esac
    if [ -n "$snapshot" ]; then
        [ -f "$snapshot" ] && [ ! -L "$snapshot" ] || return 1
    else
        [ "$created" = "1" ] || return 1
    fi
    ACTIVE_DNS_OPERATION_SNAPSHOT="$snapshot"
    ACTIVE_DNS_OPERATION_TARGET="$target"
    ACTIVE_DNS_OPERATION_CREATED="$created"
    ACTIVE_DNS_OPERATION_APPLIED_BEFORE="$applied_before"
    ACTIVE_DNS_OPERATION_NAME="$name"
}

clear_active_dns_operation() {
    ACTIVE_DNS_OPERATION_NAME=""
    ACTIVE_DNS_OPERATION_SNAPSHOT=""
    ACTIVE_DNS_OPERATION_TARGET=""
    ACTIVE_DNS_OPERATION_CREATED=0
    ACTIVE_DNS_OPERATION_APPLIED_BEFORE=0
}

finish_active_dns_operation() {
    local snapshot="${ACTIVE_DNS_OPERATION_SNAPSHOT:-}"

    clear_active_dns_operation
    remove_dns_operation_snapshot "$snapshot"
}

cancel_active_dns_operation_before_publish() {
    local name="${ACTIVE_DNS_OPERATION_NAME:-}"
    local snapshot="${ACTIVE_DNS_OPERATION_SNAPSHOT:-}"
    local applied_before="${ACTIVE_DNS_OPERATION_APPLIED_BEFORE:-0}"

    [ -n "$name" ] || return 0
    restore_dns_change_tracking "$name" "$applied_before" || return 1
    remove_dns_operation_snapshot "$snapshot" || return 1
    clear_active_dns_operation
}

rollback_active_dns_operation() {
    local name="${ACTIVE_DNS_OPERATION_NAME:-}"
    local snapshot="${ACTIVE_DNS_OPERATION_SNAPSHOT:-}"
    local target="${ACTIVE_DNS_OPERATION_TARGET:-}"
    local created="${ACTIVE_DNS_OPERATION_CREATED:-0}"
    local applied_before="${ACTIVE_DNS_OPERATION_APPLIED_BEFORE:-0}"

    [ -n "$name" ] || return 0
    rollback_dns_change "$name" "$snapshot" "$target" "$created" "$applied_before" ||
        return 1
    if [ "$name" = "DNS_RESOLVED" ]; then
        retry 2 2 systemctl restart systemd-resolved >/dev/null 2>&1 || return 1
    fi
    remove_dns_operation_snapshot "$snapshot" || return 1
    clear_active_dns_operation
}

write_resolv_conf_dns() {
    local dns1="$1"
    local dns2="${2:-}"
    local snapshot=""
    local created_resolv="0"
    local applied_before="0"
    local pending_before="0"
    local target_is_current=0
    local verify_status
    local tmp

    [ -z "${ACTIVE_DNS_OPERATION_NAME:-}" ] || {
        err "当前进程仍有未完成的 DNS 回滚，已拒绝开始新的修改。"
        return 1
    }
    applied_before="$(manifest_value_readonly APPLIED_DNS_RESOLV 2>/dev/null || true)"
    pending_before="$(manifest_value_readonly PENDING_DNS_RESOLV 2>/dev/null || true)"
    [ "$applied_before" = "1" ] || applied_before=0
    [ "$pending_before" = "1" ] || pending_before=0
    if root_owned_config_file_is_safe_readonly "$RESOLV_CONF" &&
        render_resolv_conf_dns "$dns1" "$dns2" | cmp -s - "$RESOLV_CONF"; then
        target_is_current=1
    fi
    if [ "$pending_before" = "1" ]; then
        if ! change_backup_record_is_valid DNS_RESOLV; then
            err "未完成的 IPv4 DNS 修改缺少可信恢复基线，已拒绝提交或覆盖。"
            return 1
        fi
        if [ "$target_is_current" -ne 1 ]; then
            err "检测到未完成的 IPv4 DNS 修改，且当前配置与本次目标不一致。"
            err "请先在系统优化恢复菜单中恢复 IPv4 DNS，再重新修改。"
            return 1
        fi
        if verify_dns_resolution; then
            info "未完成的 IPv4 DNS 配置已通过解析验证。"
        else
            verify_status=$?
            if [ "$verify_status" -ne 2 ]; then
                err "未完成的 IPv4 DNS 配置无法通过解析验证，已保留恢复记录。"
                return 1
            fi
            warn "未找到 getent/resolvectl，无法自动验证 DNS 解析。"
        fi
        mark_change_applied DNS_RESOLV || {
            err "IPv4 DNS 配置已存在，但未完成事务无法提交。"
            return 1
        }
        info "已提交上次中断的 IPv4 DNS 修改，无需重复写入。"
        return 0
    fi
    if [ "$target_is_current" -eq 1 ]; then
        info "IPv4 DNS 已是目标配置，无需重复写入。"
        return 0
    fi

    tmp="$(mktemp "$(dirname "$RESOLV_CONF")/.resolv.conf.vpsbox.XXXXXX")" || return 1
    if ! render_resolv_conf_dns "$dns1" "$dns2" > "$tmp"; then
        rm -f "$tmp"
        err "生成新的 $RESOLV_CONF 失败。"
        return 1
    fi
    if ! backup_change_file_once DNS_RESOLV "$RESOLV_CONF"; then
        rm -f -- "$tmp"
        err "记录 DNS 原配置失败，已取消修改。"
        return 1
    fi
    if ! begin_change_transaction DNS_RESOLV; then
        rm -f -- "$tmp"
        remove_dns_operation_snapshot "$snapshot" || true
        cancel_unmodified_change_transaction DNS_RESOLV || true
        err "记录 DNS 修改事务失败，已取消修改。"
        return 1
    fi
    if ! create_dns_operation_snapshot "$RESOLV_CONF" ".resolv.conf.vpsbox-rollback" \
        snapshot created_resolv; then
        rm -f -- "$tmp"
        restore_dns_change_tracking DNS_RESOLV "$applied_before" || true
        err "创建 DNS 临时回滚快照失败，已取消修改。"
        return 1
    fi
    if ! arm_dns_operation_rollback DNS_RESOLV "$snapshot" "$RESOLV_CONF" \
        "$created_resolv" "$applied_before"; then
        rm -f -- "$tmp"
        remove_dns_operation_snapshot "$snapshot" || true
        restore_dns_change_tracking DNS_RESOLV "$applied_before" || true
        err "登记 DNS 中断回滚状态失败，已取消修改。"
        return 1
    fi
    if ! chown root:root "$tmp" || ! chmod 644 "$tmp"; then
        rm -f -- "$tmp"
        cancel_active_dns_operation_before_publish || true
        return 1
    fi
    if ! mv -f "$tmp" "$RESOLV_CONF"; then
        rm -f "$tmp"
        cancel_active_dns_operation_before_publish || true
        err "原子替换 $RESOLV_CONF 失败。"
        return 1
    fi

    if verify_dns_resolution; then
        info "DNS 解析验证通过。"
    else
        verify_status=$?
        if [ "$verify_status" -eq 2 ]; then
            warn "未找到 getent/resolvectl，无法自动验证 DNS 解析。"
        else
            err "DNS 解析验证失败，正在恢复原配置。"
            if rollback_active_dns_operation; then
                err "DNS 解析验证失败，已恢复修改前配置。"
            else
                err "DNS 解析验证失败，且临时快照未能完整恢复。"
                [ -z "$snapshot" ] || warn "临时快照已保留：$snapshot"
            fi
            return 1
        fi
    fi

    if ! mark_change_applied DNS_RESOLV; then
        err "DNS 配置已写入，但恢复记录提交失败，正在回滚。"
        rollback_active_dns_operation ||
            err "DNS 恢复记录提交失败，且临时快照未能完整恢复。"
        return 1
    fi
    finish_active_dns_operation ||
        warn "DNS 已更新，但临时回滚快照清理失败：$snapshot"
    return 0
}

rollback_systemd_resolved_dns() {
    local conf_file="$1"
    local snapshot="$2"
    local created_conf="$3"
    local applied_before="$4"

    rollback_dns_change DNS_RESOLVED "$snapshot" "$conf_file" "$created_conf" "$applied_before" ||
        return 1
    remove_dns_operation_snapshot "$snapshot"
}

write_systemd_resolved_dns() {
    local dns1="$1"
    local dns2="${2:-}"
    local conf_dir="/etc/systemd/resolved.conf.d"
    local conf_file="$conf_dir/vpsbox.conf"
    local snapshot=""
    local created_conf="0"
    local applied_before="0"
    local pending_before="0"
    local target_is_current=0
    local tmp
    local verify_status

    [ -z "${ACTIVE_DNS_OPERATION_NAME:-}" ] || {
        err "当前进程仍有未完成的 DNS 回滚，已拒绝开始新的修改。"
        return 1
    }
    [ ! -L "$conf_file" ] || {
        err "$conf_file 是符号链接，已拒绝覆盖。"
        return 1
    }

    applied_before="$(manifest_value_readonly APPLIED_DNS_RESOLVED 2>/dev/null || true)"
    pending_before="$(manifest_value_readonly PENDING_DNS_RESOLVED 2>/dev/null || true)"
    [ "$applied_before" = "1" ] || applied_before=0
    [ "$pending_before" = "1" ] || pending_before=0
    if root_owned_config_dir_is_safe_readonly "$conf_dir" &&
        root_owned_config_file_is_safe_readonly "$conf_file" &&
        render_systemd_resolved_dns "$dns1" "$dns2" |
        cmp -s - "$conf_file"; then
        target_is_current=1
    fi
    if [ "$pending_before" = "1" ]; then
        if ! change_backup_record_is_valid DNS_RESOLVED; then
            err "未完成的 systemd-resolved DNS 修改缺少可信恢复基线，已拒绝提交或覆盖。"
            return 1
        fi
        if [ "$target_is_current" -ne 1 ]; then
            err "检测到未完成的 systemd-resolved DNS 修改，且当前配置与本次目标不一致。"
            err "请先在系统优化恢复菜单中恢复 IPv4 DNS，再重新修改。"
            return 1
        fi
        if ! systemctl is-active --quiet systemd-resolved 2>/dev/null; then
            info "systemd-resolved DNS 配置正确，正在恢复未完成事务的服务状态..."
            retry 3 2 systemctl start systemd-resolved || {
                err "systemd-resolved 服务启动失败，已保留未完成的 DNS 恢复记录。"
                return 1
            }
        fi
        systemctl is-active --quiet systemd-resolved 2>/dev/null || return 1
        if verify_dns_resolution; then
            info "未完成的 systemd-resolved DNS 配置已通过解析验证。"
        else
            verify_status=$?
            if [ "$verify_status" -ne 2 ]; then
                err "未完成的 systemd-resolved DNS 配置无法通过解析验证，已保留恢复记录。"
                return 1
            fi
            warn "未找到可用命令，无法自动验证 DNS 解析。"
        fi
        mark_change_applied DNS_RESOLVED || {
            err "systemd-resolved DNS 配置已存在，但未完成事务无法提交。"
            return 1
        }
        info "已提交上次中断的 systemd-resolved DNS 修改，无需重复写入。"
        return 0
    fi
    if [ "$target_is_current" -eq 1 ]; then
        if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
            info "systemd-resolved IPv4 DNS 已是目标配置，无需重复写入或重启。"
            return 0
        fi
        info "systemd-resolved DNS 配置正确，正在轻量恢复服务..."
        if retry 3 2 systemctl start systemd-resolved &&
            systemctl is-active --quiet systemd-resolved 2>/dev/null; then
            info "systemd-resolved 服务已恢复，无需重写 DNS 配置。"
            return 0
        fi
        err "systemd-resolved DNS 配置正确，但服务启动失败。"
        return 1
    fi

    ensure_public_config_dir "$conf_dir" "$conf_file" || return 1
    tmp="$(mktemp "$conf_dir/.vpsbox.conf.XXXXXX")" || return 1
    if ! render_systemd_resolved_dns "$dns1" "$dns2" > "$tmp"; then
        rm -f "$tmp"
        err "写入 $conf_file 失败。"
        return 1
    fi
    if ! backup_change_file_once DNS_RESOLVED "$conf_file"; then
        rm -f -- "$tmp"
        err "记录 DNS 原配置失败，已取消修改。"
        return 1
    fi
    if ! begin_change_transaction DNS_RESOLVED; then
        rm -f -- "$tmp"
        remove_dns_operation_snapshot "$snapshot" || true
        cancel_unmodified_change_transaction DNS_RESOLVED || true
        err "记录 DNS 修改事务失败，已取消修改。"
        return 1
    fi
    if ! create_dns_operation_snapshot "$conf_file" ".vpsbox.conf.rollback" \
        snapshot created_conf; then
        rm -f -- "$tmp"
        restore_dns_change_tracking DNS_RESOLVED "$applied_before" || true
        err "创建 systemd-resolved DNS 临时回滚快照失败，已取消修改。"
        return 1
    fi
    if ! arm_dns_operation_rollback DNS_RESOLVED "$snapshot" "$conf_file" \
        "$created_conf" "$applied_before"; then
        rm -f -- "$tmp"
        remove_dns_operation_snapshot "$snapshot" || true
        restore_dns_change_tracking DNS_RESOLVED "$applied_before" || true
        err "登记 systemd-resolved DNS 中断回滚状态失败，已取消修改。"
        return 1
    fi
    if ! chown root:root "$tmp" || ! chmod 644 "$tmp"; then
        rm -f -- "$tmp"
        cancel_active_dns_operation_before_publish || true
        return 1
    fi
    if ! mv -f "$tmp" "$conf_file"; then
        rm -f -- "$tmp"
        cancel_active_dns_operation_before_publish || true
        return 1
    fi

    info "检测到 systemd-resolved，已写入：$conf_file"
    warn "Domains=~. 会让 systemd-resolved 将全局 DNS 查询交给上述服务器。"
    info "正在重启 systemd-resolved 以应用 DNS，不会重启 VPS..."
    if ! retry 3 2 systemctl restart systemd-resolved; then
        err "重启 systemd-resolved 失败，请检查 systemctl status systemd-resolved --no-pager。"
        if rollback_active_dns_operation; then
            info "已恢复修改前的 systemd-resolved DNS 配置。"
        else
            err "systemd-resolved DNS 配置未能完整恢复。"
            [ -z "$snapshot" ] || warn "临时快照已保留：$snapshot"
        fi
        return 1
    fi

    resolvectl flush-caches >/dev/null 2>&1 || true
    if verify_dns_resolution; then
        info "DNS 解析验证通过。"
    else
        verify_status=$?
        if [ "$verify_status" -eq 2 ]; then
            warn "未找到可用命令，无法自动验证 DNS 解析。"
        else
            err "DNS 解析验证失败，正在恢复 systemd-resolved 配置。"
            if rollback_active_dns_operation; then
                info "已恢复修改前的 systemd-resolved DNS 配置。"
            else
                err "systemd-resolved DNS 配置未能完整恢复。"
                [ -z "$snapshot" ] || warn "临时快照已保留：$snapshot"
            fi
            return 1
        fi
    fi
    if ! mark_change_applied DNS_RESOLVED; then
        err "systemd-resolved DNS 已写入，但恢复记录提交失败，正在回滚。"
        if ! rollback_active_dns_operation; then
            err "systemd-resolved DNS 恢复记录提交失败，且临时快照未能完整恢复。"
        fi
        return 1
    fi
    finish_active_dns_operation ||
        warn "DNS 已更新，但临时回滚快照清理失败：$snapshot"
    return 0
}

apply_ipv4_dns() {
    local dns1="$1"
    local dns2="${2:-}"

    if resolv_conf_managed_by_systemd_resolved; then
        write_systemd_resolved_dns "$dns1" "$dns2"
        return $?
    fi

    if [ -L "$RESOLV_CONF" ]; then
        warn "$RESOLV_CONF 是未知符号链接，DNS 可能由系统网络服务管理。"
        warn "为避免破坏 NetworkManager、DHCP 或 cloud-init 管理的 DNS，已拒绝直接覆盖。"
        return 2
    fi

    write_resolv_conf_dns "$dns1" "$dns2"
}

change_ipv4_dns() {
    local choice
    local dns1=""
    local dns2=""
    local apply_status

    cat <<EOF
========================================
 修改 IPv4 DNS
========================================
当前 IPv4 DNS：
$(ipv4_dns_lines)
----------------------------------------
 [1] 使用默认 DNS：1.1.1.1 + 8.8.8.8
 [2] 自定义 IPv4 DNS
 [0] 取消
========================================
EOF

    if ! read -r -p "请输入选项: " choice; then
        info "输入已结束，已取消。"
        return 0
    fi
    case "$choice" in
        1)
            dns1="1.1.1.1"
            dns2="8.8.8.8"
            ;;
        2)
            while true; do
                if ! read -r -p "请输入 DNS1 IPv4 地址: " dns1; then
                    info "输入已结束，已取消。"
                    return 0
                fi
                if is_ipv4_address "$dns1"; then
                    break
                fi
                err "DNS1 格式不正确，请输入 IPv4 地址，例如 1.1.1.1。"
            done

            while true; do
                if ! read -r -p "请输入 DNS2 IPv4 地址，留空跳过: " dns2; then
                    info "输入已结束，已取消。"
                    return 0
                fi
                [ -z "$dns2" ] && break
                if is_ipv4_address "$dns2"; then
                    break
                fi
                err "DNS2 格式不正确，请输入 IPv4 地址，例如 8.8.8.8。"
            done
            ;;
        0)
            info "已取消。"
            return 0
            ;;
        *)
            warn "无效选项。"
            return 1
            ;;
    esac

    if apply_ipv4_dns "$dns1" "$dns2"; then
        :
    else
        apply_status=$?
        [ "$apply_status" -eq 2 ] && return 0
        return "$apply_status"
    fi

    info "当前 IPv4 DNS："
    ipv4_dns_lines
}

cancel_unpublished_ipv4_priority_change() {
    local prior_state="$1"

    [ "$prior_state" = "pending" ] && return 0
    if ! cancel_unmodified_change_transaction GAI_CONF; then
        warn "IPv4 优先尚未修改，但本次恢复记录未能完整清理。"
    fi
    return 0
}

enable_ipv4_priority() {
    local parent tmp prior_state

    prior_state="$(change_restore_state_readonly GAI_CONF)" || return 1
    if [ "$prior_state" = "pending" ]; then
        err "检测到尚未处理的 IPv4 优先修改事务，请先在恢复菜单中检查或恢复。"
        return 1
    fi

    info "正在开启 IPv4 优先，不会禁用 IPv6。"
    if [ "$(ipv4_priority_state)" = "已启用" ]; then
        info "IPv4 优先已开启，无需重复修改。"
        return 0
    fi
    [ ! -L "$GAI_CONF" ] || { err "$GAI_CONF 是符号链接，已拒绝修改。"; return 1; }
    prior_state="$(change_restore_state GAI_CONF)" || return 1
    if [ "$prior_state" = "pending" ]; then
        err "检测到尚未处理的 IPv4 优先修改事务，请先在恢复菜单中检查或恢复。"
        return 1
    fi
    backup_change_file_once GAI_CONF "$GAI_CONF" || { err "记录 IPv4 优先原配置失败，已取消修改。"; return 1; }
    begin_change_transaction GAI_CONF || {
        cancel_unpublished_ipv4_priority_change "$prior_state"
        err "记录 IPv4 优先事务失败，已取消修改。"
        return 1
    }

    parent="$(dirname "$GAI_CONF")"
    [ -d "$parent" ] && [ ! -L "$parent" ] || {
        cancel_unpublished_ipv4_priority_change "$prior_state"
        err "IPv4 优先配置目录无效或为符号链接：$parent"
        return 1
    }
    tmp="$(mktemp "$parent/.gai.conf.vpsbox.XXXXXX")" || {
        cancel_unpublished_ipv4_priority_change "$prior_state"
        return 1
    }
    if [ -f "$GAI_CONF" ]; then
        cp -a -- "$GAI_CONF" "$tmp" || {
            rm -f -- "$tmp"
            cancel_unpublished_ipv4_priority_change "$prior_state"
            return 1
        }
    else
        chmod 644 "$tmp" || {
            rm -f -- "$tmp"
            cancel_unpublished_ipv4_priority_change "$prior_state"
            return 1
        }
    fi

    if ! sed -i '/^[#[:space:]]*precedence[[:space:]]\+::ffff:0:0\/96[[:space:]]\+/d' "$tmp"; then
        rm -f -- "$tmp"
        cancel_unpublished_ipv4_priority_change "$prior_state"
        err "清理旧 IPv4 优先配置失败。"
        return 1
    fi

    if ! printf '%s\n' 'precedence ::ffff:0:0/96 100' >> "$tmp"; then
        rm -f -- "$tmp"
        cancel_unpublished_ipv4_priority_change "$prior_state"
        err "写入 IPv4 优先配置失败。"
        return 1
    fi
    if ! chown root:root "$tmp" || ! mv -f -- "$tmp" "$GAI_CONF"; then
        rm -f -- "$tmp"
        cancel_unpublished_ipv4_priority_change "$prior_state"
        err "原子替换 IPv4 优先配置失败。"
        return 1
    fi

    info "已写入：precedence ::ffff:0:0/96 100"
    mark_change_applied GAI_CONF || return 1
    info "当前 IPv4 优先：$(ipv4_priority_state)"
    info "可用 curl ip.sb 或 curl -v ip.sb 验证默认出口。"
}

sshd_binary() {
    local bin

    bin="$(command -v sshd 2>/dev/null || true)"
    if [ -n "$bin" ]; then
        printf '%s\n' "$bin"
    elif [ -x /usr/sbin/sshd ]; then
        printf '%s\n' "/usr/sbin/sshd"
    else
        return 1
    fi
}

sshd_effective_config() {
    local bin

    bin="$(sshd_binary)" || return 1
    "$bin" -T 2>/dev/null
}

sshd_effective_values() {
    local key="$1"

    sshd_effective_config | awk -v key="$key" '$1 == key {
        $1 = ""
        sub(/^ /, "")
        print
    }'
}

sshd_effective_value_list() {
    local key="$1"
    local values

    values="$(sshd_effective_values "$key" | awk 'BEGIN { sep = "" } { printf "%s%s", sep, $0; sep = ", " } END { printf "\n" }' || true)"
    [ -n "$values" ] && printf '%s\n' "$values" || printf '%s\n' "未知"
}

ssh_effective_ports_csv() {
    local ports

    ports="$(sshd_effective_values port | awk '/^[0-9]+$/ && $1 >= 1 && $1 <= 65535' | sort -n -u | paste -sd, -)"
    [ -n "$ports" ] || return 1
    printf '%s\n' "$ports"
}

ssh_port_state() {
    sshd_effective_value_list port
}

ssh_effective_ports_match_target() {
    local ports

    ports="$(ssh_effective_ports_csv)" || return 1
    [ "$ports" = "$SSH_TARGET_PORT" ]
}

sshd_main_has_active_port_directive() {
    awk '
        tolower($1) == "match" { exit }
        tolower($1) == "port" && $2 ~ /^[0-9]+$/ { found = 1 }
        END { exit !found }
    ' "$SSHD_MAIN_CONF" 2>/dev/null
}

sshd_vpsbox_port_include_available() {
    sshd_main_has_dropin_wildcard ||
        sshd_main_includes_path "$SSHD_VPSBOX_PORT_CONF"
}

sshd_main_has_dropin_wildcard() {
    awk '
        tolower($1) == "include" {
            for (i = 2; i <= NF; i++) {
                if ($i ~ /sshd_config[.]d\/[*][.]conf$/) found = 1
            }
        }
        END { exit !found }
    ' "$SSHD_MAIN_CONF" 2>/dev/null
}

sshd_main_includes_path() {
    local expected="$1"

    awk -v expected="$expected" '
        tolower($1) == "include" {
            for (i = 2; i <= NF; i++) {
                if ($i == expected) found = 1
            }
        }
        END { exit !found }
    ' "$SSHD_MAIN_CONF" 2>/dev/null
}

install_ssh_config_atomically() {
    install_root_file_atomically "$@"
}

set_main_ssh_port_directives() {
    local tmp

    tmp="$(mktemp)" || return 1
    awk -v port="$SSH_TARGET_PORT" '
        {
            keyword = tolower($1)
        }
        keyword == "match" && !in_match {
            if (!changed) {
                print "Port " port
                changed = 1
            }
            in_match = 1
            print
            next
        }
        keyword == "port" && !in_match {
            if (!changed) print "Port " port
            changed = 1
            next
        }
        { print }
        END {
            if (!changed) print "Port " port
        }
    ' "$SSHD_MAIN_CONF" > "$tmp" || { rm -f "$tmp"; return 1; }
    install_ssh_config_atomically "$tmp" "$SSHD_MAIN_CONF" 644 ||
        { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
}

write_vpsbox_ssh_port_config() {
    local tmp

    mkdir -p "$SSHD_CONFIG_DIR" || return 1
    tmp="$(mktemp)" || return 1
    # --- BEGIN GENERATED TEMPLATE: SSH port drop-in ---
    cat > "$tmp" <<EOF || { rm -f "$tmp"; return 1; }
# Managed by vpsbox
Port $SSH_TARGET_PORT
EOF
    # --- END GENERATED TEMPLATE: SSH port drop-in ---
    install_ssh_config_atomically "$tmp" "$SSHD_VPSBOX_PORT_CONF" 644 ||
        { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
}

validate_ssh_port_effective_config() {
    local bin

    bin="$(sshd_binary)" || { err "未找到 sshd，无法检查 SSH 配置。"; return 1; }

    if ! "$bin" -t; then
        err "sshd -t 检查未通过。"
        return 1
    fi

    if ! ssh_effective_ports_match_target; then
        err "SSH 当前生效端口不是 $SSH_TARGET_PORT，当前为：$(ssh_port_state)"
        warn "可能还有其他 SSH 配置文件也写了 Port，请先检查 /etc/ssh/sshd_config 和 /etc/ssh/sshd_config.d/。"
        return 1
    fi
}

restart_ssh_service() {
    if is_systemd; then
        retry 3 2 systemctl restart ssh || retry 3 2 systemctl restart sshd
    elif [ "$OS" = "alpine" ] && command -v rc-service >/dev/null 2>&1; then
        retry 3 2 run_openrc_service sshd restart
    elif command -v service >/dev/null 2>&1; then
        retry 3 2 service ssh restart || retry 3 2 service sshd restart
    else
        err "未找到可用的 SSH 服务重启方式。"
        return 1
    fi
}

ssh_listener_on_port() {
    local port="$1" socket_ports

    command -v ss >/dev/null 2>&1 || return 1
    if ss -H -tlnp 2>/dev/null | awk -v port="$port" '
        $4 ~ (":" port "$") && $0 ~ /"sshd"/ { found=1 }
        END { exit(found ? 0 : 1) }
    '; then
        return 0
    fi

    if ssh_socket_activation_active; then
        socket_ports="$(ssh_socket_activation_ports_csv)" || return 1
        csv_contains_port "$socket_ports" "$port" || return 1
        ss -H -tln 2>/dev/null | awk -v port="$port" '
            $4 ~ (":" port "$") { found=1 }
            END { exit(found ? 0 : 1) }
        '
        return $?
    fi
    return 1
}

ssh_effective_ports_listening() {
    local ports port
    local IFS=,

    ports="$(ssh_effective_ports_csv)" || return 1
    for port in $ports; do
        ssh_listener_on_port "$port" || return 1
    done
}

wait_for_ssh_listener() {
    local port="$1"
    local i

    for i in 1 2 3 4 5; do
        ssh_listener_on_port "$port" && return 0
        sleep 1
    done
    return 1
}

wait_for_any_ssh_listener_csv() {
    local ports="$1" port
    local IFS=,

    for port in $ports; do
        wait_for_ssh_listener "$port" && return 0
    done
    return 1
}

wait_for_all_ssh_listeners_csv() {
    local ports="$1" port
    local IFS=,

    for port in $ports; do
        wait_for_ssh_listener "$port" || return 1
    done
}

ssh_effective_ports_match_csv() {
    local expected="$1" current

    expected="$(normalize_port_csv "$expected")" || return 1
    current="$(ssh_effective_ports_csv)" || return 1
    current="$(normalize_port_csv "$current")" || return 1
    [ "$current" = "$expected" ]
}

ssh_connection_server_port() {
    local client_ip client_port server_ip server_port extra

    [ -n "${SSH_CONNECTION:-}" ] || return 1
    read -r client_ip client_port server_ip server_port extra <<< "$SSH_CONNECTION"
    [ -n "$client_ip" ] && [ -n "$client_port" ] && [ -n "$server_ip" ] &&
        [ -z "${extra:-}" ] && is_valid_port "$server_port" || return 1
    printf '%s\n' "$server_port"
}

ssh_socket_activation_ports_csv() {
    local unit output ports="" parsed active=0

    is_systemd || return 1
    for unit in ssh.socket sshd.socket; do
        systemctl is-active --quiet "$unit" 2>/dev/null || continue
        active=1
        output="$(systemctl show "$unit" --property=Listen --value 2>/dev/null)" || return 1
        parsed="$(printf '%s\n' "$output" | awk '
            {
                for (i = 1; i < NF; i++) {
                    token = $i
                    sub(/^Listen=/, "", token)
                    if ($(i + 1) != "(Stream)") continue
                    if (token ~ /^[0-9]+$/ ||
                        token ~ /^\[[^][]+\]:[0-9]+$/ ||
                        token ~ /^[*A-Za-z0-9_.-]+:[0-9]+$/) {
                        sub(/^.*:/, "", token)
                        print token
                    }
                }
            }
        ')" || return 1
        [ -n "$parsed" ] || return 1
        ports="$(merge_port_csv "$ports" "$(printf '%s\n' "$parsed" | paste -sd, -)")" || return 1
    done
    [ "$active" -eq 1 ] && [ -n "$ports" ] || return 1
    printf '%s\n' "$ports"
}

ssh_listening_ports_csv() {
    local output ports socket_ports connection_port

    command -v ss >/dev/null 2>&1 || return 1
    output="$(ss -H -tlnp 2>/dev/null)" || return 1
    ports="$(printf '%s\n' "$output" | awk '
        /"sshd"/ {
            address=$4
            sub(/^.*:/, "", address)
            if (address ~ /^[0-9]+$/) print address
        }
    ' | paste -sd, -)" || return 1
    connection_port="$(ssh_connection_server_port 2>/dev/null || true)"
    if ssh_socket_activation_active; then
        socket_ports="$(ssh_socket_activation_ports_csv)" || return 1
    else
        socket_ports=""
    fi
    ports="$(merge_port_csv "$ports" "$socket_ports" "$connection_port")" || return 1
    [ -n "$ports" ] || return 1
    printf '%s\n' "$ports"
}

ssh_firewall_transition_begin() {
    local tcp_ports="$1"

    [ "${ACTIVE_SSH_FIREWALL_TRANSITION:-0}" = "0" ] || {
        err "已有未完成的 SSH 防火墙端口切换。"
        return 1
    }
    ACTIVE_SSH_FIREWALL_TRANSITION=1
    if ! firewall_prepare_port_transition "$tcp_ports" ""; then
        ACTIVE_SSH_FIREWALL_TRANSITION=0
        return 1
    fi
}

ssh_firewall_transition_abort() {
    # SSH 的事务前防火墙快照可能早已落后于 sshd；按配置与实际监听并集重算更安全。
    ssh_firewall_transition_reconcile
}

ssh_firewall_transition_finish() {
    firewall_complete_port_transition || return 1
    ACTIVE_SSH_FIREWALL_TRANSITION=0
}

ssh_firewall_sync_current_safe_ports() {
    local configured_ports listening_ports safe_ports

    configured_ports="$(ssh_effective_ports_csv 2>/dev/null || true)"
    listening_ports="$(ssh_listening_ports_csv 2>/dev/null || true)"
    safe_ports="$(merge_port_csv "$configured_ports" "$listening_ports")" || return 1
    [ -n "$safe_ports" ] || return 1
    firewall_sync_active_config "$safe_ports" "" 1
}

ssh_firewall_transition_reconcile() {
    local transition_dir

    [ "${ACTIVE_SSH_FIREWALL_TRANSITION:-0}" = "1" ] || return 0
    ssh_firewall_sync_current_safe_ports || return 1
    transition_dir="${ACTIVE_FIREWALL_TRANSITION_DIR:-}"
    if [ -n "$transition_dir" ]; then
        firewall_discard_port_transition || return 1
    fi
    ACTIVE_SSH_FIREWALL_TRANSITION=0
}

firewall_settle_pending_port_transition() {
    if [ -n "${ACTIVE_NODE_BACKUP:-}" ]; then
        warn "检测到未完成的节点端口事务，正在先恢复节点与防火墙状态。"
        rollback_active_node_transaction || return 1
    fi
    if [ "${ACTIVE_SSH_FIREWALL_TRANSITION:-0}" = "1" ]; then
        warn "检测到未完成的 SSH 端口事务，正在保留配置端口与实际监听端口的安全并集。"
        ssh_firewall_transition_reconcile || {
            err "SSH 端口事务无法安全对账，已拒绝继续修改主机防火墙。"
            return 1
        }
    elif [ -n "${ACTIVE_FIREWALL_TRANSITION_DIR:-}" ]; then
        warn "检测到未完成的端口事务，正在恢复事务前的防火墙配置。"
        firewall_abort_port_transition || {
            err "未完成的端口事务无法恢复，已拒绝继续修改主机防火墙。"
            return 1
        }
    fi
    [ -z "${ACTIVE_NODE_BACKUP:-}" ] &&
        [ "${ACTIVE_SSH_FIREWALL_TRANSITION:-0}" = "0" ] &&
        [ -z "${ACTIVE_FIREWALL_TRANSITION_DIR:-}" ]
}

ssh_socket_activation_active() {
    is_systemd && { systemctl is-active --quiet ssh.socket 2>/dev/null || systemctl is-active --quiet sshd.socket 2>/dev/null; }
}

ssh_socket_activation_enabled_or_active() {
    local unit

    is_systemd || return 1
    for unit in ssh.socket sshd.socket; do
        if systemctl is-active --quiet "$unit" 2>/dev/null ||
            systemctl is-enabled --quiet "$unit" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

choose_ssh_target_port() {
    local input confirm docker_ports status

    command -v ss >/dev/null 2>&1 || {
        err "缺少 ss，无法可靠检查 SSH 端口占用。"
        return 1
    }
    ssh_effective_ports_csv >/dev/null 2>&1 || {
        err "无法读取 SSH 当前生效端口，已取消修改。"
        return 1
    }

    docker_ports="$(docker_reserved_ports_for_port_choice tcp)" || {
        err "无法可靠读取 Docker 已发布端口，已取消 SSH 端口选择。"
        return 1
    }

    while true; do
        read -r -p "请输入新 SSH 端口（1-65535，留空默认 23333）: " input || return 1
        input="${input:-23333}"
        is_valid_port "$input" || { err "端口必须是 1-65535 的整数。"; continue; }
        if port_is_effective_ssh_port "$input"; then
            status=0
        else
            status=$?
            if [ "$status" -ne 1 ]; then
                err "无法读取 SSH 当前生效端口，已取消修改。"
                return 1
            fi
            if port_in_use_tcp "$input"; then
                err "端口 $input 已被占用，请更换。"
                continue
            else
                status=$?
                if [ "$status" -ne 1 ]; then
                    err "无法检查端口 $input 的监听状态，已取消修改。"
                    return 1
                fi
            fi
        fi
        if [ "$status" -ne 0 ] && csv_contains_port "$docker_ports" "$input"; then
            err "端口 $input 已被 Docker 发布规则占用，请更换。"
            continue
        fi
        if [ "$input" -lt 1024 ]; then
            if ! read -r -p "端口 $input 属于特权端口，输入 YES 确认使用: " confirm; then
                info "输入已结束，已取消修改。"
                return 1
            fi
            [ "$confirm" = "YES" ] || continue
        fi
        printf '%s\n' "$input"
        return 0
    done
}

clear_ssh_change_tracking() {
    local failed=0

    clear_change_tracking SSHD_MAIN || failed=1
    clear_change_tracking SSHD_PORT || failed=1
    clear_change_tracking SSHD_HARDENING || failed=1
    manifest_remove PENDING_SSH_CONFIG || failed=1
    manifest_remove APPLIED_SSH_CONFIG || failed=1
    manifest_remove SSH_PORTS || failed=1
    return "$failed"
}

legacy_ssh_change_tracking_present() {
    local key

    for key in BACKUP_SSHD_MAIN BACKUP_SSHD_PORT BACKUP_SSHD_HARDENING \
        PENDING_SSHD_MAIN PENDING_SSHD_PORT PENDING_SSHD_HARDENING \
        APPLIED_SSHD_MAIN APPLIED_SSHD_PORT APPLIED_SSHD_HARDENING \
        PENDING_SSH_CONFIG APPLIED_SSH_CONFIG SSH_PORTS; do
        manifest_value_readonly "$key" >/dev/null 2>&1 && return 0
    done
    [ -e "$CHANGE_BACKUP_DIR/SSHD_MAIN" ] || [ -L "$CHANGE_BACKUP_DIR/SSHD_MAIN" ] ||
        [ -e "$CHANGE_BACKUP_DIR/SSHD_PORT" ] || [ -L "$CHANGE_BACKUP_DIR/SSHD_PORT" ] ||
        [ -e "$CHANGE_BACKUP_DIR/SSHD_HARDENING" ] || [ -L "$CHANGE_BACKUP_DIR/SSHD_HARDENING" ]
}

retire_legacy_ssh_change_tracking() {
    legacy_ssh_change_tracking_present || return 0
    clear_ssh_change_tracking
}

validate_ssh_access_controls() {
    local failed=0

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
        if ! ufw status 2>/dev/null | grep -Eq "^${SSH_TARGET_PORT}/tcp[[:space:]]+ALLOW"; then
            warn "UFW 正在运行，但未能自动确认已放行 TCP $SSH_TARGET_PORT；将由修改前的人工确认兜底。"
        fi
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        if ! firewall-cmd --quiet --query-port="${SSH_TARGET_PORT}/tcp" >/dev/null 2>&1; then
            warn "firewalld 正在运行，但未能自动确认已放行 TCP $SSH_TARGET_PORT；将由修改前的人工确认兜底。"
        fi
    fi
    if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null)" = "Enforcing" ]; then
        if command -v semanage >/dev/null 2>&1; then
            semanage port -l 2>/dev/null | awk -v target="$SSH_TARGET_PORT" '
                $1 == "ssh_port_t" {
                    for (i = 3; i <= NF; i++) {
                        token = $i
                        gsub(/,/, "", token)
                        if (token ~ /^[0-9]+$/ && token + 0 == target) found = 1
                        if (token ~ /^[0-9]+-[0-9]+$/) {
                            split(token, range, "-")
                            if (target >= range[1] && target <= range[2]) found = 1
                        }
                    }
                }
                END { exit !found }
            ' ||
                { err "SELinux 为 Enforcing，但 ssh_port_t 未包含端口 $SSH_TARGET_PORT；请先配置后重试。"; failed=1; }
        else
            err "SELinux 为 Enforcing，但未安装 semanage，无法验证 SSH 新端口策略。"
            failed=1
        fi
    fi
    return "$failed"
}

restore_fail2ban_sshd_config_file() {
    local backup="$1"
    local mode

    if [ -n "$backup" ]; then
        [ -f "$backup" ] && [ ! -L "$backup" ] || return 1
        mode="$(stat -c '%a' "$backup" 2>/dev/null)" || return 1
        install_root_file_atomically "$backup" "$FAIL2BAN_VPSBOX_SSHD_CONF" "$mode"
    else
        [ ! -L "$FAIL2BAN_VPSBOX_SSHD_CONF" ] || return 1
        if [ -e "$FAIL2BAN_VPSBOX_SSHD_CONF" ] &&
            [ ! -f "$FAIL2BAN_VPSBOX_SSHD_CONF" ]; then
            return 1
        fi
        rm -f -- "$FAIL2BAN_VPSBOX_SSHD_CONF"
    fi
}

restore_fail2ban_sshd_sync_state() {
    local backup="$1" was_running="$2"
    local config_ready=1
    local failed=0

    case "$was_running" in
        0|1) ;;
        *) return 1 ;;
    esac
    if ! restore_fail2ban_sshd_config_file "$backup"; then
        config_ready=0
        failed=1
    elif ! fail2ban-client -t -c /etc/fail2ban >/dev/null 2>&1; then
        config_ready=0
        failed=1
    fi

    # 原服务在运行时，只有旧配置已安全恢复并通过预检才允许重启；否则保留
    # 当前进程并报告回滚不完整。原服务停止时，即使配置恢复失败也必须继续
    # 尝试停止同步期间临时启动的服务。
    if [ "$was_running" -eq 1 ] && [ "$config_ready" -ne 1 ]; then
        return 1
    fi

    if is_systemd; then
        if [ "$was_running" -eq 1 ]; then
            retry 3 1 systemctl restart fail2ban >/dev/null || failed=1
        else
            retry 3 1 systemctl stop fail2ban >/dev/null || failed=1
        fi
    elif command -v rc-service >/dev/null 2>&1; then
        if [ "$was_running" -eq 1 ]; then
            retry 3 1 rc-service fail2ban restart >/dev/null || failed=1
        else
            retry 3 1 rc-service fail2ban stop >/dev/null || failed=1
        fi
    else
        failed=1
    fi
    if [ "$was_running" -eq 0 ] && [ "$(fail2ban_service_state)" = "运行中" ]; then
        failed=1
    fi
    return "$failed"
}

clear_active_fail2ban_sync() {
    # WAS_RUNNING 是活动标记，必须先清除；若信号卡在两次赋值之间，退出清理
    # 看到空标记就不会把已清空的 BACKUP 误判为“原配置不存在”。
    ACTIVE_FAIL2BAN_SYNC_WAS_RUNNING=""
    ACTIVE_FAIL2BAN_SYNC_BACKUP=""
}

arm_fail2ban_sync_rollback() {
    local backup="$1" was_running="$2"

    [ -z "${ACTIVE_FAIL2BAN_SYNC_WAS_RUNNING:-}" ] || return 1
    case "$was_running" in
        0|1) ;;
        *) return 1 ;;
    esac
    if [ -n "$backup" ]; then
        [ -f "$backup" ] && [ ! -L "$backup" ] || return 1
    fi
    ACTIVE_FAIL2BAN_SYNC_BACKUP="$backup"
    # 最后写入运行状态作为活动标记；在此之前正式配置尚未替换。
    ACTIVE_FAIL2BAN_SYNC_WAS_RUNNING="$was_running"
}

cleanup_active_fail2ban_sync() {
    local backup="${ACTIVE_FAIL2BAN_SYNC_BACKUP:-}"
    local was_running="${ACTIVE_FAIL2BAN_SYNC_WAS_RUNNING:-}"

    [ -n "$was_running" ] || return 0
    case "$was_running" in
        0|1) ;;
        *) clear_active_fail2ban_sync; return 1 ;;
    esac

    # 先消费活动标记，避免重复执行退出清理时再次覆盖配置或重启服务。
    # 回滚失败时，时间戳备份与 PENDING 变更记录仍会保留恢复依据。
    clear_active_fail2ban_sync
    restore_fail2ban_sshd_sync_state "$backup" "$was_running"
}

fail2ban_sync_failure_with_rollback() {
    local reason="$1" backup="$2" was_running="$3"

    if [ -z "${ACTIVE_FAIL2BAN_SYNC_WAS_RUNNING:-}" ]; then
        if ! arm_fail2ban_sync_rollback "$backup" "$was_running"; then
            err "$reason，且无法登记 Fail2ban 回滚的中断恢复状态。"
            return 1
        fi
    elif [ "${ACTIVE_FAIL2BAN_SYNC_BACKUP:-}" != "$backup" ] ||
        [ "$ACTIVE_FAIL2BAN_SYNC_WAS_RUNNING" != "$was_running" ]; then
        err "$reason，且 Fail2ban 回滚的中断恢复状态不一致。"
        return 1
    fi

    # 显式回滚完成前保持活动标记；若恢复本身再被信号中断，EXIT 清理仍可接管。
    if restore_fail2ban_sshd_sync_state "$backup" "$was_running"; then
        clear_active_fail2ban_sync
        err "$reason，已恢复同步前的配置与服务状态。"
    else
        clear_active_fail2ban_sync
        err "$reason，且同步前状态未能完整恢复，请检查服务与配置。"
    fi
    return 1
}

restore_fail2ban_runtime_after_sync() {
    local was_running="$1"

    [ "$was_running" -eq 0 ] || return 0
    if is_systemd; then
        retry 3 1 systemctl stop fail2ban >/dev/null || return 1
    elif command -v rc-service >/dev/null 2>&1; then
        retry 3 1 rc-service fail2ban stop >/dev/null || return 1
    else
        return 1
    fi
    [ "$(fail2ban_service_state)" != "运行中" ]
}

prune_fail2ban_sshd_backups() {
    local backup nullglob_was_set=0
    local -a backups

    shopt -q nullglob && nullglob_was_set=1
    shopt -s nullglob
    backups=("${FAIL2BAN_VPSBOX_SSHD_CONF}.bak."*)
    [ "$nullglob_was_set" -eq 1 ] || shopt -u nullglob
    while [ "${#backups[@]}" -gt 5 ]; do
        backup="${backups[0]}"
        [ -f "$backup" ] && [ ! -L "$backup" ] || return 1
        rm -f -- "$backup" || return 1
        backups=("${backups[@]:1}")
    done
}

sync_fail2ban_sshd_port() {
    local backup=""
    local backend="auto"
    local deep_check_status=0
    local ports
    local service_action
    local tmp
    local was_running=0

    if ! fail2ban_installed; then
        return 0
    fi
    ensure_fail2ban_nftables_dependency || return 1
    if fail2ban_sshd_configuration_healthy; then
        info "Fail2ban SSH 防护配置已是当前状态，无需重复同步。"
        return 0
    fi
    [ "$(fail2ban_service_state)" = "运行中" ] && was_running=1
    manifest_set_once FAIL2BAN_ACTIVE "$([ "$was_running" -eq 1 ] && echo active || echo inactive)" || return 1
    if fail2ban_service_is_enabled; then
        manifest_set_once FAIL2BAN_ENABLED enabled || return 1
    else
        manifest_set_once FAIL2BAN_ENABLED disabled || return 1
    fi

    mkdir -p "$FAIL2BAN_CONFIG_DIR" || return 1
    if [ -L "$FAIL2BAN_VPSBOX_SSHD_CONF" ] ||
        { [ -e "$FAIL2BAN_VPSBOX_SSHD_CONF" ] && [ ! -f "$FAIL2BAN_VPSBOX_SSHD_CONF" ]; }; then
        err "Fail2ban SSH 防护配置路径不安全，已拒绝修改：$FAIL2BAN_VPSBOX_SSHD_CONF"
        return 1
    fi
    backup_change_file_once FAIL2BAN_SSHD "$FAIL2BAN_VPSBOX_SSHD_CONF" || return 1
    ports="$(ssh_effective_ports_csv)" || {
        err "无法读取 SSH 当前生效端口，已取消同步 Fail2ban。"
        return 1
    }
    is_systemd && backend="systemd"

    if [ -e "$FAIL2BAN_VPSBOX_SSHD_CONF" ]; then
        backup="${FAIL2BAN_VPSBOX_SSHD_CONF}.bak.$(date +%Y%m%d%H%M%S)"
        cp -a "$FAIL2BAN_VPSBOX_SSHD_CONF" "$backup" || return 1
    fi
    begin_change_transaction FAIL2BAN_SSHD || { err "记录 Fail2ban 修改事务失败，已取消修改。"; return 1; }

    tmp="$(mktemp "$FAIL2BAN_CONFIG_DIR/.vpsbox-sshd.XXXXXX")" || return 1
    render_fail2ban_sshd_config "$ports" "$backend" > "$tmp" || {
        rm -f "$tmp"
        return 1
    }
    chmod 644 "$tmp" || { rm -f "$tmp"; return 1; }

    if ! arm_fail2ban_sync_rollback "$backup" "$was_running"; then
        rm -f -- "$tmp"
        err "无法登记 Fail2ban 同步的中断恢复状态，已取消修改。"
        return 1
    fi
    if ! mv -f "$tmp" "$FAIL2BAN_VPSBOX_SSHD_CONF"; then
        clear_active_fail2ban_sync
        rm -f -- "$tmp"
        return 1
    fi
    if [ -n "${ACTIVE_SSH_TRANSACTION_DIR:-}" ]; then
        ACTIVE_SSH_FAIL2BAN_MUTATED=1
    fi
    if ! fail2ban-client -t -c /etc/fail2ban >/dev/null 2>&1; then
        fail2ban_sync_failure_with_rollback "Fail2ban 配置预检失败" "$backup" "$was_running" || true
        return 1
    fi

    if is_systemd; then
        if [ "$was_running" -eq 1 ]; then
            service_action="restart"
        else
            service_action="start"
        fi
        if ! retry 3 2 systemctl "$service_action" fail2ban; then
            fail2ban_sync_failure_with_rollback \
                "Fail2ban 服务启动或重启失败" "$backup" "$was_running" || true
            return 1
        fi
    elif command -v rc-service >/dev/null 2>&1; then
        if [ "$was_running" -eq 1 ]; then
            service_action="restart"
        else
            service_action="start"
        fi
        if ! retry 3 2 rc-service fail2ban "$service_action"; then
            fail2ban_sync_failure_with_rollback \
                "Fail2ban 服务启动或重启失败" "$backup" "$was_running" || true
            return 1
        fi
    else
        fail2ban_sync_failure_with_rollback \
            "未找到 Fail2ban 服务启动或重启方式" "$backup" "$was_running" || true
        return 1
    fi

    if ! retry 5 1 fail2ban-client status sshd >/dev/null 2>&1; then
        fail2ban_sync_failure_with_rollback \
            "Fail2ban 服务已启动，但 sshd jail 未在预期时间内就绪" \
            "$backup" "$was_running" || true
        return 1
    fi
    if [ "$(fail2ban_sshd_state)" != "已启用" ]; then
        fail2ban_sync_failure_with_rollback \
            "Fail2ban sshd jail 端口未与 SSH 当前生效端口一致" \
            "$backup" "$was_running" || true
        return 1
    fi
    if ! fail2ban_sshd_uses_only_nftables; then
        fail2ban_sync_failure_with_rollback \
            "Fail2ban sshd jail 未使用预期的 nftables 防火墙后端" \
            "$backup" "$was_running" || true
        return 1
    fi
    if verify_fail2ban_real_ban_advisory; then
        :
    else
        deep_check_status=$?
    fi
    if ! restore_fail2ban_runtime_after_sync "$was_running"; then
        fail2ban_sync_failure_with_rollback \
            "Fail2ban 配置验证通过，但无法恢复同步前的停止状态" \
            "$backup" "$was_running" || true
        return 1
    fi
    # 配置与运行态均已通过验收；此后即使记录提交被中断，也不应回滚健康配置。
    clear_active_fail2ban_sync
    if ! mark_change_applied FAIL2BAN_SSHD; then
        if [ "$deep_check_status" -eq 2 ] || [ -n "${ACTIVE_FAIL2BAN_TEST_IP:-}" ]; then
            err "Fail2ban 基础配置已通过，但测试地址仍有残留且无法记录已应用状态；当前配置未回滚。"
            return 1
        fi
        fail2ban_sync_failure_with_rollback \
            "Fail2ban 防护已验证，但无法记录已应用状态" "$backup" "$was_running" || true
        return 1
    fi
    prune_fail2ban_sshd_backups || warn "Fail2ban 历史备份清理不完整，最多保留 5 份的策略未完全执行。"
    if [ "$deep_check_status" -eq 2 ] || [ -n "${ACTIVE_FAIL2BAN_TEST_IP:-}" ]; then
        warn "Fail2ban 基础配置已通过并保留，但深度检测的测试地址仍未完全清理。"
    fi
}

apply_ssh_port_target_transaction() {
    local original_ports="$1" write_action

    if ! begin_ssh_runtime_transaction "$original_ports" 1; then
        err "无法创建可校验的 SSH 运行期回滚快照，已取消修改。"
        return 1
    fi
    if ! ssh_firewall_transition_begin "$SSH_TARGET_PORT"; then
        cancel_ssh_runtime_transaction ||
            warn "SSH 尚未修改，但运行期快照未能清理。"
        err "主机防火墙无法临时放行 SSH 目标端口，已取消修改。"
        return 1
    fi

    if sshd_main_has_active_port_directive; then
        write_action="主配置"
        if [ -e "$SSHD_VPSBOX_PORT_CONF" ] && sshd_vpsbox_port_include_available; then
            if ! rm -f -- "$SSHD_VPSBOX_PORT_CONF"; then
                fail_ssh_runtime_transaction "停用冲突的 SSH 端口 drop-in 失败" || true
                return 1
            fi
            write_action="主配置（已停用 vpsbox 端口 drop-in）"
        fi
        if ! set_main_ssh_port_directives; then
            fail_ssh_runtime_transaction "写入 SSH 主配置失败" || true
            return 1
        fi
    elif sshd_vpsbox_port_include_available; then
        write_action="vpsbox drop-in"
        if ! write_vpsbox_ssh_port_config; then
            fail_ssh_runtime_transaction "写入 SSH drop-in 失败" || true
            return 1
        fi
    else
        write_action="主配置"
        if ! set_main_ssh_port_directives; then
            fail_ssh_runtime_transaction "写入 SSH 主配置失败" || true
            return 1
        fi
    fi

    if ! validate_ssh_port_effective_config; then
        fail_ssh_runtime_transaction "SSH 端口配置验证失败" || true
        return 1
    fi
    if ! restart_ssh_service; then
        fail_ssh_runtime_transaction "SSH 服务重启失败" || true
        return 1
    fi
    if ! wait_for_ssh_listener "$SSH_TARGET_PORT"; then
        fail_ssh_runtime_transaction \
            "SSH 重启后未检测到 sshd 监听端口 $SSH_TARGET_PORT" || true
        return 1
    fi
    if ! sync_fail2ban_sshd_port; then
        fail_ssh_runtime_transaction "Fail2ban sshd 端口同步或验收失败" || true
        return 1
    fi
    if ! ssh_firewall_transition_finish; then
        fail_ssh_runtime_transaction "主机防火墙无法同步 SSH 目标端口" || true
        return 1
    fi
    if ! commit_ssh_runtime_transaction; then
        err "SSH 运行期事务无法提交，正在回滚。"
        rollback_active_ssh_transaction || true
        return 1
    fi

    retire_legacy_ssh_change_tracking ||
        warn "SSH 已成功提交，但旧版 SSH 恢复记录未能完整退役；不会再使用这些记录自动恢复。"
    info "SSH 配置写入位置：$write_action"
    if fail2ban_installed; then
        info "Fail2ban sshd 端口已同步为 $SSH_TARGET_PORT。"
    fi
    return 0
}

apply_ssh_port_change() {
    local confirm new_port original_ports retired_ports
    local vpsbox_firewall_active=0

    if ! sshd_binary >/dev/null 2>&1; then
        err "未找到 sshd，无法修改 SSH 配置。"
        return 1
    fi

    if [ ! -f "$SSHD_MAIN_CONF" ]; then
        err "未找到 SSH 主配置：$SSHD_MAIN_CONF"
        return 1
    fi

    if ssh_socket_activation_enabled_or_active; then
        err "检测到 SSH socket activation 正在运行或已启用；为避免重启后端口错配，当前不自动修改。"
        err "请先通过控制台处理 ssh.socket/sshd.socket，或关闭 socket activation 后重试。"
        return 1
    fi
    new_port="$(choose_ssh_target_port)" || { info "已取消。"; return 0; }
    SSH_TARGET_PORT="$new_port"

    if ssh_effective_ports_match_target; then
        info "SSH 端口已经是 $SSH_TARGET_PORT，无需重复修改。"
        if ! read -r -p "仍要重新写入并重启 SSH？[y/N]: " confirm; then
            info "输入已结束，已取消重复修改。"
            return 0
        fi
        case "$confirm" in
            y|Y|yes|YES) ;;
            *) info "已取消重复修改。"; return 0 ;;
        esac
    fi

    validate_ssh_access_controls || {
        err "本机访问控制检查未通过，未修改 SSH 配置。"
        return 1
    }

    if firewall_runtime_enabled; then
        vpsbox_firewall_active=1
        if ! read -r -p "vpsbox 防火墙将自动临时放行 TCP $SSH_TARGET_PORT；请确认商家安全组、UFW/firewalld 或其他防火墙也已放行。输入 YES 继续: " confirm; then
            info "输入已结束，已取消，未修改 SSH 配置。"
            return 0
        fi
    else
        if ! read -r -p "确认已在商家安全组、UFW/firewalld 或其他防火墙放行 TCP $SSH_TARGET_PORT？输入 YES 继续: " confirm; then
            info "输入已结束，已取消，未修改 SSH 配置。"
            return 0
        fi
    fi
    if [ "$confirm" != "YES" ]; then
        info "已取消，未修改 SSH 配置。"
        return 0
    fi

    original_ports="$(ssh_effective_ports_csv)" || {
        err "无法读取 SSH 当前生效端口，已取消修改。"
        return 1
    }
    retired_ports="$(csv_remove_port "$original_ports" "$SSH_TARGET_PORT")" || {
        err "无法计算 SSH 旧端口，已取消修改。"
        return 1
    }
    apply_ssh_port_target_transaction "$original_ports" || return 1

    info "SSH 端口已修改为 $SSH_TARGET_PORT。"
    warn "不要关闭当前 SSH 窗口。"
    warn "请另开一个新窗口测试：ssh -p $SSH_TARGET_PORT root@你的服务器IP"
    if [ -n "$retired_ports" ]; then
        if [ "$vpsbox_firewall_active" -eq 1 ]; then
            warn "确认新端口可以登录后，请在新 SSH 会话再次更新 vpsbox 防火墙，以移除可能因旧会话暂时保留的端口（$retired_ports）。"
            warn "如果厂商安全组仍放行旧端口（$retired_ports），届时也可在厂商面板关闭。"
        else
            warn "确认新端口可以登录后，再在商家安全组或其他外部防火墙关闭旧端口（$retired_ports）。"
        fi
    fi
}

ssh_port_change_firewall_hint() {
    if firewall_runtime_enabled; then
        echo "vpsbox 防火墙运行中，新端口将自动临时放行并同步。"
        echo "如厂商另有安全组，仍需先在厂商面板放行新端口。"
    else
        echo "请先在商家安全组或其他外部防火墙放行即将输入的 TCP 端口。"
    fi
}

ssh_restore_snapshot_root() {
    printf '%s\n' "$RUNTIME_DIR/ssh-transactions"
}

ssh_restore_snapshot_path_allowed() {
    local snapshot_dir="$1" root parent base

    root="$(ssh_restore_snapshot_root)"
    parent="$(dirname -- "$snapshot_dir")"
    base="${snapshot_dir##*/}"
    [ "$parent" = "$root" ] &&
        [[ "$base" == transaction.* || "$base" == .building.* ]]
}

remove_ssh_restore_snapshot() {
    local snapshot_dir="$1"

    ssh_restore_snapshot_path_allowed "$snapshot_dir" &&
        [ -d "$snapshot_dir" ] && [ ! -L "$snapshot_dir" ] || return 1
    rm -rf -- "$snapshot_dir"
}

ssh_restore_snapshot_path_is_secure() {
    local path="$1" expected_mode="$2" owner group mode

    [ ! -L "$path" ] || return 1
    owner="$(stat -c '%u' "$path" 2>/dev/null)" || return 1
    group="$(stat -c '%g' "$path" 2>/dev/null)" || return 1
    mode="$(stat -c '%a' "$path" 2>/dev/null)" || return 1
    [ "$owner" = "0" ] && [ "$group" = "0" ] && [ "$mode" = "$expected_mode" ]
}

ssh_restore_snapshot_manifest_entry() {
    local manifest="$1" name="$2"

    awk -F'|' -v name="$name" '
        $1 == name { line=$0; count++ }
        END {
            if (count == 1) print line
            else exit 1
        }
    ' "$manifest"
}

ssh_restore_snapshot_dir_valid() {
    local snapshot_dir="$1" root manifest name entry state mode digest path actual

    ssh_restore_snapshot_path_allowed "$snapshot_dir" &&
        [ -d "$snapshot_dir" ] && [ ! -L "$snapshot_dir" ] || return 1
    root="$(ssh_restore_snapshot_root)"
    [[ "$snapshot_dir" == "$root"/transaction.* ]] || return 1
    [ -d "$root" ] && [ ! -L "$root" ] &&
        ssh_restore_snapshot_path_is_secure "$root" 700 || return 1
    ssh_restore_snapshot_path_is_secure "$snapshot_dir" 700 || return 1
    manifest="$snapshot_dir/manifest"
    [ -f "$manifest" ] && [ ! -L "$manifest" ] &&
        ssh_restore_snapshot_path_is_secure "$manifest" 600 || return 1
    [ "$(awk 'END { print NR + 0 }' "$manifest")" = "4" ] || return 1
    for name in main port hardening fail2ban; do
        entry="$(ssh_restore_snapshot_manifest_entry "$manifest" "$name")" || return 1
        IFS='|' read -r _ state mode digest <<< "$entry"
        case "$state" in
            file)
                [[ "$mode" =~ ^[0-7]{3,4}$ ]] &&
                    [ $((8#$mode & 8#022)) -eq 0 ] ||
                    return 1
                path="$snapshot_dir/$name"
                [ -f "$path" ] && [ ! -L "$path" ] &&
                    [ ! -e "$snapshot_dir/$name.absent" ] &&
                    ssh_restore_snapshot_path_is_secure "$path" 600 || return 1
                ;;
            absent)
                [ "$mode" = "-" ] || return 1
                path="$snapshot_dir/$name.absent"
                [ -f "$path" ] && [ ! -L "$path" ] &&
                    [ ! -e "$snapshot_dir/$name" ] &&
                    ssh_restore_snapshot_path_is_secure "$path" 600 || return 1
                ;;
            *) return 1 ;;
        esac
        [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
        actual="$(sha256sum "$path" 2>/dev/null | awk '{print $1}')" || return 1
        [ "$actual" = "$digest" ] || return 1
    done
}

create_ssh_restore_snapshot() {
    local output_var="$1" root build final suffix manifest name path mode digest

    command -v sha256sum >/dev/null 2>&1 || return 1
    root="$(ssh_restore_snapshot_root)"
    [ -d "$RUNTIME_DIR" ] && [ ! -L "$RUNTIME_DIR" ] &&
        ssh_restore_snapshot_path_is_secure "$RUNTIME_DIR" 700 || return 1
    [ ! -L "$root" ] || return 1
    mkdir -p "$root" || return 1
    chown root:root "$root" || return 1
    chmod 700 "$root" || return 1
    build="$(mktemp -d "$root/.building.XXXXXX")" || return 1
    chown root:root "$build" && chmod 700 "$build" || {
        remove_ssh_restore_snapshot "$build" || true
        return 1
    }
    manifest="$build/manifest"
    for name in main port hardening fail2ban; do
        case "$name" in
            main) path="$SSHD_MAIN_CONF" ;;
            port) path="$SSHD_VPSBOX_PORT_CONF" ;;
            hardening) path="$SSHD_VPSBOX_HARDENING_CONF" ;;
            fail2ban) path="$FAIL2BAN_VPSBOX_SSHD_CONF" ;;
        esac
        if [ -f "$path" ] && [ ! -L "$path" ]; then
            mode="$(stat -c '%a' "$path" 2>/dev/null)" &&
                [[ "$mode" =~ ^[0-7]{3,4}$ ]] &&
                [ $((8#$mode & 8#022)) -eq 0 ] &&
                cp -- "$path" "$build/$name" &&
                chown root:root "$build/$name" &&
                chmod 600 "$build/$name" || {
                remove_ssh_restore_snapshot "$build" || true
                return 1
            }
            digest="$(sha256sum "$build/$name" | awk '{print $1}')" || {
                remove_ssh_restore_snapshot "$build" || true
                return 1
            }
            printf '%s|file|%s|%s\n' "$name" "$mode" "$digest" >> "$manifest" || {
                remove_ssh_restore_snapshot "$build" || true
                return 1
            }
        elif [ ! -e "$path" ] && [ ! -L "$path" ]; then
            : > "$build/$name.absent" &&
                chown root:root "$build/$name.absent" &&
                chmod 600 "$build/$name.absent" || {
                remove_ssh_restore_snapshot "$build" || true
                return 1
            }
            digest="$(sha256sum "$build/$name.absent" | awk '{print $1}')" || {
                remove_ssh_restore_snapshot "$build" || true
                return 1
            }
            printf '%s|absent|-|%s\n' "$name" "$digest" >> "$manifest" || {
                remove_ssh_restore_snapshot "$build" || true
                return 1
            }
        else
            remove_ssh_restore_snapshot "$build" || true
            return 1
        fi
    done
    chown root:root "$manifest" && chmod 600 "$manifest" || {
        remove_ssh_restore_snapshot "$build" || true
        return 1
    }
    suffix="${build##*.building.}"
    final="$root/transaction.$suffix"
    [ ! -e "$final" ] && mv -- "$build" "$final" || {
        remove_ssh_restore_snapshot "$build" || true
        return 1
    }
    ssh_restore_snapshot_dir_valid "$final" || {
        remove_ssh_restore_snapshot "$final" || true
        return 1
    }
    printf -v "$output_var" '%s' "$final"
}

restore_ssh_runtime_snapshot() {
    local snapshot_dir="$1" expected_ports="$2" name path bin entry mode

    ssh_restore_snapshot_dir_valid "$snapshot_dir" || return 1
    for name in main port hardening; do
        case "$name" in
            main) path="$SSHD_MAIN_CONF" ;;
            port) path="$SSHD_VPSBOX_PORT_CONF" ;;
            hardening) path="$SSHD_VPSBOX_HARDENING_CONF" ;;
        esac
        if [ -f "$snapshot_dir/$name" ]; then
            entry="$(ssh_restore_snapshot_manifest_entry "$snapshot_dir/manifest" "$name")" ||
                return 1
            IFS='|' read -r _ _ mode _ <<< "$entry"
            install_ssh_config_atomically "$snapshot_dir/$name" "$path" "$mode" || return 1
        elif [ -f "$snapshot_dir/$name.absent" ]; then
            rm -f "$path" || return 1
        else
            return 1
        fi
    done
    bin="$(sshd_binary)" || return 1
    "$bin" -t || return 1
    restart_ssh_service || return 1
    [ -z "$expected_ports" ] || wait_for_all_ssh_listeners_csv "$expected_ports"
}

restore_ssh_fail2ban_snapshot() {
    local snapshot_dir="$1" was_installed="$2" was_running="$3"
    local entry state mode path="$FAIL2BAN_VPSBOX_SSHD_CONF" failed=0

    case "$was_installed:$was_running" in
        0:0|1:0|1:1) ;;
        *) return 1 ;;
    esac
    ssh_restore_snapshot_dir_valid "$snapshot_dir" || return 1
    entry="$(ssh_restore_snapshot_manifest_entry "$snapshot_dir/manifest" fail2ban)" || return 1
    IFS='|' read -r _ state mode _ <<< "$entry"
    case "$state" in
        file)
            install_root_file_atomically "$snapshot_dir/fail2ban" "$path" "$mode" || return 1
            ;;
        absent)
            remove_snapshot_target_file "$path" || return 1
            ;;
        *) return 1 ;;
    esac

    [ "$was_installed" -eq 1 ] || return 0
    if is_systemd; then
        if [ "$was_running" -eq 1 ]; then
            fail2ban-client -t -c /etc/fail2ban >/dev/null 2>&1 || return 1
            retry 3 1 systemctl restart fail2ban >/dev/null || failed=1
        else
            retry 3 1 systemctl stop fail2ban >/dev/null || failed=1
        fi
    elif command -v rc-service >/dev/null 2>&1; then
        if [ "$was_running" -eq 1 ]; then
            fail2ban-client -t -c /etc/fail2ban >/dev/null 2>&1 || return 1
            retry 3 1 rc-service fail2ban restart >/dev/null || failed=1
        else
            retry 3 1 rc-service fail2ban stop >/dev/null || failed=1
        fi
    else
        failed=1
    fi
    if [ "$was_running" -eq 1 ]; then
        [ "$(fail2ban_service_state)" = "运行中" ] || failed=1
    else
        [ "$(fail2ban_service_state)" != "运行中" ] || failed=1
    fi
    return "$failed"
}

begin_ssh_runtime_transaction() {
    local original_ports="$1" has_port_change="${2:-0}" snapshot_dir=""
    local fail2ban_installed_before=0 fail2ban_running_before=0

    [ -z "${ACTIVE_SSH_TRANSACTION_DIR:-}" ] || return 1
    case "$has_port_change" in 0|1) ;; *) return 1 ;; esac
    original_ports="$(normalize_port_csv "$original_ports")" || return 1
    [ -n "$original_ports" ] || return 1
    create_ssh_restore_snapshot snapshot_dir || return 1
    if fail2ban_installed; then
        fail2ban_installed_before=1
        [ "$(fail2ban_service_state)" = "运行中" ] && fail2ban_running_before=1
    fi
    ACTIVE_SSH_ORIGINAL_PORTS="$original_ports"
    ACTIVE_SSH_TRANSACTION_HAS_PORT_CHANGE="$has_port_change"
    ACTIVE_SSH_FAIL2BAN_INSTALLED="$fail2ban_installed_before"
    ACTIVE_SSH_FAIL2BAN_WAS_RUNNING="$fail2ban_running_before"
    ACTIVE_SSH_FAIL2BAN_MUTATED=0
    # 最后登记目录作为活动标记；在此之前尚未修改正式配置。
    ACTIVE_SSH_TRANSACTION_DIR="$snapshot_dir"
}

cancel_ssh_runtime_transaction() {
    local snapshot_dir="${ACTIVE_SSH_TRANSACTION_DIR:-}"

    [ -n "$snapshot_dir" ] || return 0
    ACTIVE_SSH_TRANSACTION_DIR=""
    ACTIVE_SSH_ORIGINAL_PORTS=""
    ACTIVE_SSH_TRANSACTION_HAS_PORT_CHANGE=0
    ACTIVE_SSH_FAIL2BAN_INSTALLED=0
    ACTIVE_SSH_FAIL2BAN_WAS_RUNNING=0
    ACTIVE_SSH_FAIL2BAN_MUTATED=0
    remove_ssh_restore_snapshot "$snapshot_dir"
}

commit_ssh_runtime_transaction() {
    local snapshot_dir="${ACTIVE_SSH_TRANSACTION_DIR:-}"
    local original_ports="${ACTIVE_SSH_ORIGINAL_PORTS:-}"
    local has_port_change="${ACTIVE_SSH_TRANSACTION_HAS_PORT_CHANGE:-0}"
    local fail2ban_installed_before="${ACTIVE_SSH_FAIL2BAN_INSTALLED:-0}"
    local fail2ban_running_before="${ACTIVE_SSH_FAIL2BAN_WAS_RUNNING:-0}"
    local fail2ban_mutated="${ACTIVE_SSH_FAIL2BAN_MUTATED:-0}"

    [ -n "$snapshot_dir" ] || return 1
    # 先撤销活动标记，提交后即使收到信号也不应回滚已验收的健康配置。
    ACTIVE_SSH_TRANSACTION_DIR=""
    ACTIVE_SSH_ORIGINAL_PORTS=""
    ACTIVE_SSH_TRANSACTION_HAS_PORT_CHANGE=0
    ACTIVE_SSH_FAIL2BAN_INSTALLED=0
    ACTIVE_SSH_FAIL2BAN_WAS_RUNNING=0
    ACTIVE_SSH_FAIL2BAN_MUTATED=0
    if remove_ssh_restore_snapshot "$snapshot_dir"; then
        return 0
    fi
    ACTIVE_SSH_ORIGINAL_PORTS="$original_ports"
    ACTIVE_SSH_TRANSACTION_HAS_PORT_CHANGE="$has_port_change"
    ACTIVE_SSH_FAIL2BAN_INSTALLED="$fail2ban_installed_before"
    ACTIVE_SSH_FAIL2BAN_WAS_RUNNING="$fail2ban_running_before"
    ACTIVE_SSH_FAIL2BAN_MUTATED="$fail2ban_mutated"
    ACTIVE_SSH_TRANSACTION_DIR="$snapshot_dir"
    return 1
}

rollback_active_ssh_transaction() {
    local snapshot_dir="${ACTIVE_SSH_TRANSACTION_DIR:-}"
    local original_ports="${ACTIVE_SSH_ORIGINAL_PORTS:-}"
    local has_port_change="${ACTIVE_SSH_TRANSACTION_HAS_PORT_CHANGE:-0}"
    local fail2ban_installed_before="${ACTIVE_SSH_FAIL2BAN_INSTALLED:-0}"
    local fail2ban_running_before="${ACTIVE_SSH_FAIL2BAN_WAS_RUNNING:-0}"
    local fail2ban_mutated="${ACTIVE_SSH_FAIL2BAN_MUTATED:-0}"
    local failed=0

    [ -n "$snapshot_dir" ] || return 0
    if [ -n "${ACTIVE_FAIL2BAN_SYNC_WAS_RUNNING:-}" ]; then
        cleanup_active_fail2ban_sync || failed=1
    fi
    if ! restore_ssh_runtime_snapshot "$snapshot_dir" "$original_ports"; then
        failed=1
    fi
    if [ "$fail2ban_mutated" = "1" ]; then
        if ! restore_ssh_fail2ban_snapshot \
            "$snapshot_dir" "$fail2ban_installed_before" "$fail2ban_running_before"; then
            failed=1
        fi
    elif [ "$fail2ban_mutated" != "0" ]; then
        failed=1
    fi
    if [ "${ACTIVE_SSH_FIREWALL_TRANSITION:-0}" = "1" ]; then
        if ! ssh_firewall_transition_abort; then
            failed=1
        fi
    elif [ -n "${ACTIVE_FIREWALL_TRANSITION_DIR:-}" ]; then
        if ! firewall_abort_port_transition; then
            failed=1
        fi
    elif [ "$has_port_change" = "1" ] && firewall_runtime_enabled; then
        if ! ssh_firewall_sync_current_safe_ports; then
            failed=1
        fi
    fi
    if [ "$failed" -ne 0 ]; then
        return 1
    fi

    ACTIVE_SSH_TRANSACTION_DIR=""
    ACTIVE_SSH_ORIGINAL_PORTS=""
    ACTIVE_SSH_TRANSACTION_HAS_PORT_CHANGE=0
    ACTIVE_SSH_FAIL2BAN_INSTALLED=0
    ACTIVE_SSH_FAIL2BAN_WAS_RUNNING=0
    ACTIVE_SSH_FAIL2BAN_MUTATED=0
    if remove_ssh_restore_snapshot "$snapshot_dir"; then
        return 0
    fi
    ACTIVE_SSH_ORIGINAL_PORTS="$original_ports"
    ACTIVE_SSH_TRANSACTION_HAS_PORT_CHANGE="$has_port_change"
    ACTIVE_SSH_FAIL2BAN_INSTALLED="$fail2ban_installed_before"
    ACTIVE_SSH_FAIL2BAN_WAS_RUNNING="$fail2ban_running_before"
    ACTIVE_SSH_FAIL2BAN_MUTATED="$fail2ban_mutated"
    ACTIVE_SSH_TRANSACTION_DIR="$snapshot_dir"
    return 1
}

fail_ssh_runtime_transaction() {
    local reason="$1" snapshot_dir="${ACTIVE_SSH_TRANSACTION_DIR:-}"

    err "$reason，正在恢复修改前的 SSH 状态。"
    if rollback_active_ssh_transaction; then
        info "已恢复修改前的 SSH 配置、监听、Fail2ban 与防火墙状态。"
        return 0
    fi
    err "SSH 自动回滚未完成；请勿关闭当前连接，并通过控制台检查。"
    [ -z "$snapshot_dir" ] || warn "运行期快照已保留：$snapshot_dir"
    return 1
}

restore_ssh_port_to_22() {
    local confirm original_ports docker_ports status

    if ! sshd_binary >/dev/null 2>&1; then
        err "未找到 sshd，无法恢复 SSH 端口。"
        return 1
    fi
    [ -f "$SSHD_MAIN_CONF" ] && [ ! -L "$SSHD_MAIN_CONF" ] || {
        err "SSH 主配置不存在或不是安全的普通文件：$SSHD_MAIN_CONF"
        return 1
    }
    if ssh_socket_activation_enabled_or_active; then
        err "检测到 SSH socket activation 正在运行或已启用，已拒绝自动恢复端口。"
        return 1
    fi
    command -v ss >/dev/null 2>&1 || {
        err "缺少 ss，无法可靠检查 SSH 端口占用。"
        return 1
    }

    SSH_TARGET_PORT=22
    if port_is_effective_ssh_port 22; then
        :
    else
        status=$?
        if [ "$status" -ne 1 ]; then
            err "无法读取 SSH 当前生效端口，已取消恢复。"
            return 1
        fi
        if port_in_use_tcp 22; then
            err "TCP 22 已被其他服务占用，无法恢复 SSH 端口。"
            return 1
        else
            status=$?
            [ "$status" -eq 1 ] || {
                err "无法检查 TCP 22 的监听状态，已取消恢复。"
                return 1
            }
        fi
        docker_ports="$(docker_reserved_ports_for_port_choice tcp)" || {
            err "无法可靠读取 Docker 已发布端口，已取消恢复。"
            return 1
        }
        if csv_contains_port "$docker_ports" 22; then
            err "TCP 22 已被 Docker 发布规则占用，无法恢复 SSH 端口。"
            return 1
        fi
    fi
    validate_ssh_access_controls || {
        err "本机访问控制检查未通过，未修改 SSH 配置。"
        return 1
    }
    original_ports="$(ssh_effective_ports_csv)" || {
        err "无法读取 SSH 当前生效端口，已取消恢复。"
        return 1
    }

    echo "将仅把 SSH 端口恢复为 22；其他 SSH 配置保持不变。"
    echo "请先确认商家安全组及其他外部防火墙已放行 TCP 22。"
    if ! read -r -p "请确认已有控制台或备用连接。输入 YES 恢复 SSH 端口为 22：" confirm; then
        info "输入已结束，已取消 SSH 端口恢复。"
        return 0
    fi
    [ "$confirm" = "YES" ] || { info "已取消 SSH 端口恢复。"; return 0; }

    apply_ssh_port_target_transaction "$original_ports" || return 1
    info "SSH 端口已恢复为 22，其他 SSH 配置未修改。"
    warn "不要关闭当前 SSH 窗口，请另开新窗口测试 TCP 22 登录。"
}

ssh_port_change_menu() {
    local opt

    while true; do
        clear 2>/dev/null || true
        cat <<EOF
========================================
 修改 SSH 端口
========================================
 当前 SSH 端口：$(ssh_port_state)
 新端口：创建时输入，留空默认 23333
----------------------------------------
将根据当前 SSH 配置，最小化修改主配置或 vpsbox drop-in。
$(ssh_port_change_firewall_hint)
----------------------------------------
 [1] 应用 SSH 端口修改
 [2] 恢复 SSH 端口为 22
----------------------------------------
 [0] 返回系统优化
========================================
EOF
        read -r -p "请输入选项: " opt || exit 0
        echo ""

        case "$opt" in
            1) run_menu_action apply_ssh_port_change; pause ;;
            2) run_menu_action restore_ssh_port_to_22; pause ;;
            0) return 0 ;;
            *) warn "无效选项：$opt"; pause ;;
        esac
    done
}

update_system_packages() {
    local confirm

    detect_os
    case "$OS" in
        debian)
            cat <<EOF
即将执行系统更新：
apt update && apt upgrade -y && apt autoremove -y
EOF
            ;;
        alpine)
            cat <<EOF
即将执行系统更新：
apk update && apk upgrade
EOF
            ;;
        redhat)
            err "系统更新当前不自动支持 RedHat 系。"
            warn "可手动执行：dnf upgrade -y 或 yum update -y"
            return 1
            ;;
        *)
            err "未识别系统类型，已取消系统更新。"
            return 1
            ;;
    esac

    read -r -p "确认继续？[y/N]: " confirm || return 1
    case "$confirm" in
        y|Y|yes|YES) ;;
        *) info "已取消系统更新。"; return 0 ;;
    esac

    case "$OS" in
        debian)
            export DEBIAN_FRONTEND=noninteractive
            apt_get_bounded "$PACKAGE_UPDATE_TIMEOUT" update || {
                err "APT 软件包索引更新失败，已停止后续步骤。"
                return 1
            }
            apt_get_bounded "$SYSTEM_UPGRADE_TIMEOUT" upgrade -y || {
                err "APT 软件包升级失败，已停止后续步骤。"
                return 1
            }
            apt_get_bounded "$SYSTEM_UPGRADE_TIMEOUT" autoremove -y || {
                err "APT 自动清理失败。"
                return 1
            }
            ;;
        alpine)
            apk_bounded "$PACKAGE_UPDATE_TIMEOUT" update || {
                err "APK 软件包索引更新失败，已停止后续步骤。"
                return 1
            }
            apk_bounded "$SYSTEM_UPGRADE_TIMEOUT" upgrade || {
                err "APK 软件包升级失败。"
                return 1
            }
            ;;
    esac

    if [ "$(reboot_required_state)" = "需要" ]; then
        warn "系统更新完成，检测到需要重启 VPS。"
    else
        info "系统更新完成，当前不需要重启。"
    fi
}

global_ipv6_addresses() {
    command -v ip >/dev/null 2>&1 || return 1
    ip -6 -o addr show scope global 2>/dev/null |
        awk '$3 == "inet6" && $4 != "" { print $2, $4 }'
}

current_ssh_connection_uses_ipv6() {
    local client_ip client_port server_ip server_port extra

    [ -n "${SSH_CONNECTION:-}" ] || return 1
    read -r client_ip client_port server_ip server_port extra <<< "$SSH_CONNECTION"
    [ -n "$client_ip" ] &&
        [[ "$client_port" =~ ^[0-9]+$ ]] &&
        [ -n "$server_ip" ] &&
        [[ "$server_port" =~ ^[0-9]+$ ]] &&
        [ -z "${extra:-}" ] &&
        [[ "$server_ip" == *:* ]]
}

render_ipv6_disable_config() {
    # --- BEGIN GENERATED TEMPLATE: disable IPv6 sysctl drop-in ---
    cat <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    # --- END GENERATED TEMPLATE: disable IPv6 sysctl drop-in ---
}

ipv6_disable_config_is_current() {
    [ -f "$IPV6_DISABLE_CONF" ] && [ ! -L "$IPV6_DISABLE_CONF" ] || return 1
    render_ipv6_disable_config | cmp -s - "$IPV6_DISABLE_CONF"
}

ipv6_disable_runtime_values() {
    local all default lo

    all="$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)" || return 1
    default="$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null)" || return 1
    lo="$(sysctl -n net.ipv6.conf.lo.disable_ipv6 2>/dev/null)" || return 1
    [[ "$all" =~ ^[01]$ ]] && [[ "$default" =~ ^[01]$ ]] && [[ "$lo" =~ ^[01]$ ]] || return 1
    printf '%s %s %s\n' "$all" "$default" "$lo"
}

ipv6_runtime_matches_values() {
    local expected_all="$1" expected_default="$2" expected_lo="$3"
    local actual

    actual="$(ipv6_disable_runtime_values)" || return 1
    [ "$actual" = "$expected_all $expected_default $expected_lo" ]
}

ipv6_disabled_runtime_is_current() {
    local addresses

    ipv6_runtime_matches_values 1 1 1 || return 1
    addresses="$(global_ipv6_addresses)" || return 1
    [ -z "$addresses" ]
}

ipv6_summary_state() {
    local runtime addresses count

    runtime="$(ipv6_disable_runtime_values)" || {
        printf '%s\n' "无法检测"
        return 0
    }
    addresses="$(global_ipv6_addresses)" || {
        printf '%s\n' "无法检测"
        return 0
    }

    if [ -e "$IPV6_DISABLE_CONF" ] || [ -L "$IPV6_DISABLE_CONF" ]; then
        if ! ipv6_disable_config_is_current; then
            printf '%s\n' "配置异常"
        elif [ "$runtime" = "1 1 1" ] && [ -z "$addresses" ]; then
            printf '%s\n' "已禁用"
        else
            printf '%s\n' "禁用配置存在但未生效"
        fi
        return 0
    fi

    if [ "$runtime" = "1 1 1" ]; then
        if [ -z "$addresses" ]; then
            printf '%s\n' "已禁用（非 vpsbox 配置）"
        else
            printf '%s\n' "无法检测"
        fi
    elif [ -n "$addresses" ]; then
        count="$(awk 'NF { count++ } END { print count + 0 }' <<< "$addresses")"
        printf '已启用（%s 个全局地址）\n' "$count"
    else
        printf '%s\n' "未检测到全局 IPv6"
    fi
}

restore_ipv6_runtime_values() {
    local old_all="$1" old_default="$2" old_lo="$3" failed=0

    sysctl -w "net.ipv6.conf.all.disable_ipv6=$old_all" >/dev/null 2>&1 || failed=1
    sysctl -w "net.ipv6.conf.default.disable_ipv6=$old_default" >/dev/null 2>&1 || failed=1
    sysctl -w "net.ipv6.conf.lo.disable_ipv6=$old_lo" >/dev/null 2>&1 || failed=1
    [ "$failed" -eq 0 ] && ipv6_runtime_matches_values "$old_all" "$old_default" "$old_lo"
}

cancel_unmodified_ipv6_change() {
    if ! cancel_unmodified_change_transaction \
        IPV6_CONF IPV6_ALL IPV6_DEFAULT IPV6_LO; then
        err "清理尚未应用的 IPv6 修改记录失败，请先使用恢复菜单检查系统改动。"
        return 1
    fi
}

disable_ipv6() {
    local addresses runtime_values old_all old_default old_lo
    local parent tmp interface address tracking_state

    tracking_state="$(change_restore_state_readonly IPV6_CONF)" || return 1
    if [ "$tracking_state" = "pending" ]; then
        err "检测到尚未处理的 IPv6 修改事务，请先在恢复菜单中检查或恢复。"
        return 1
    fi

    if ! addresses="$(global_ipv6_addresses)"; then
        err "无法读取全局 IPv6 地址，已取消禁用。"
        return 1
    fi
    if [ -z "$addresses" ]; then
        info "未检测到全局 IPv6 地址，无需禁用。"
        return 0
    fi

    echo "检测到以下全局 IPv6 地址："
    while read -r interface address; do
        [ -n "$interface" ] && [ -n "$address" ] || continue
        printf ' - %s：%s\n' "$interface" "$address"
    done <<< "$addresses"

    if current_ssh_connection_uses_ipv6; then
        warn "当前 SSH 会话正在通过 IPv6 连接，禁用后会立即断开。"
        warn "请改用 IPv4 SSH 或 VPS 控制台后重试。"
        return 0
    fi

    warn "禁用后，IPv6 地址、路由和现有 IPv6 连接会立即失效。"
    warn "现有节点配置不会自动改写；请先确认节点和其他服务可通过 IPv4 访问。"
    if ! confirm_default_yes "是否禁用 IPv6？"; then
        info "已取消禁用 IPv6。"
        return 0
    fi

    parent="$(dirname "$IPV6_DISABLE_CONF")"
    [ -d "$parent" ] && [ ! -L "$parent" ] || {
        err "IPv6 配置目录不存在或不安全：$parent"
        return 1
    }
    if [ -e "$IPV6_DISABLE_CONF" ] || [ -L "$IPV6_DISABLE_CONF" ]; then
        [ -f "$IPV6_DISABLE_CONF" ] && [ ! -L "$IPV6_DISABLE_CONF" ] || {
            err "$IPV6_DISABLE_CONF 不是安全的普通文件，已拒绝覆盖。"
            return 1
        }
        if ! ipv6_disable_config_is_current; then
            err "$IPV6_DISABLE_CONF 已存在且内容不属于当前配置，已拒绝覆盖。"
            return 1
        fi
    fi

    tracking_state="$(change_restore_state IPV6_CONF)" || return 1
    if [ "$tracking_state" = "pending" ]; then
        err "检测到尚未处理的 IPv6 修改事务，请先在恢复菜单中检查或恢复。"
        return 1
    fi
    if [ "$tracking_state" = "none" ] && ipv6_disable_config_is_current; then
        err "检测到没有原始恢复记录的 vpsbox IPv6 禁用配置。"
        err "请先在系统改动菜单中重新启用 IPv6，再重新执行禁用以建立恢复基线。"
        return 1
    fi
    if [ "$tracking_state" = "none" ] && {
        [ -n "$(manifest_value BACKUP_IPV6_CONF 2>/dev/null || true)" ] ||
            [ -n "$(manifest_value IPV6_ALL 2>/dev/null || true)" ] ||
            [ -n "$(manifest_value IPV6_DEFAULT 2>/dev/null || true)" ] ||
            [ -n "$(manifest_value IPV6_LO 2>/dev/null || true)" ];
    }; then
        cancel_unmodified_ipv6_change || return 1
    fi

    runtime_values="$(ipv6_disable_runtime_values)" || {
        err "无法读取 IPv6 内核运行参数，未修改系统。"
        return 1
    }
    read -r old_all old_default old_lo <<< "$runtime_values"

    if ! backup_change_file_once IPV6_CONF "$IPV6_DISABLE_CONF" ||
        ! manifest_set_once IPV6_ALL "$old_all" ||
        ! manifest_set_once IPV6_DEFAULT "$old_default" ||
        ! manifest_set_once IPV6_LO "$old_lo"; then
        cancel_unmodified_ipv6_change || true
        err "记录 IPv6 原配置失败，已取消修改。"
        return 1
    fi
    if ! begin_change_transaction IPV6_CONF; then
        cancel_unmodified_ipv6_change || true
        err "记录 IPv6 修改事务失败，已取消修改。"
        return 1
    fi

    tmp="$(mktemp "$parent/.vpsbox-disable-ipv6.XXXXXX")" || {
        cancel_unmodified_ipv6_change || true
        return 1
    }
    if ! render_ipv6_disable_config > "$tmp" ||
        ! chown root:root "$tmp" ||
        ! chmod 644 "$tmp"; then
        rm -f -- "$tmp" || warn "清理 IPv6 临时配置失败：$tmp"
        cancel_unmodified_ipv6_change || true
        err "生成 IPv6 配置失败，未修改系统。"
        return 1
    fi

    if ! sysctl -p "$tmp" >/dev/null 2>&1 || ! ipv6_disabled_runtime_is_current; then
        rm -f -- "$tmp" || warn "清理 IPv6 临时配置失败：$tmp"
        if restore_ipv6_runtime_values "$old_all" "$old_default" "$old_lo"; then
            if cancel_unmodified_ipv6_change; then
                err "禁用 IPv6 失败；已恢复记录的运行参数，持久配置未改动。"
            else
                err "禁用 IPv6 失败；运行参数已恢复，但事务记录清理失败。"
            fi
        else
            err "禁用 IPv6 失败，且记录的运行参数未能确认完整恢复。"
            err "已保留事务记录，请通过恢复菜单或 IPv4/VPS 控制台处理。"
        fi
        return 1
    fi

    if ! mv -f -- "$tmp" "$IPV6_DISABLE_CONF"; then
        rm -f -- "$tmp" || warn "清理 IPv6 临时配置失败：$tmp"
        if restore_ipv6_runtime_values "$old_all" "$old_default" "$old_lo"; then
            if cancel_unmodified_ipv6_change; then
                err "保存 IPv6 配置失败；已恢复记录的运行参数，持久配置未改动。"
            else
                err "保存 IPv6 配置失败；运行参数已恢复，但事务记录清理失败。"
            fi
        else
            err "保存 IPv6 配置失败，且记录的运行参数未能确认完整恢复。"
            err "已保留事务记录，请通过恢复菜单或 IPv4/VPS 控制台处理。"
        fi
        return 1
    fi

    if ! mark_change_applied IPV6_CONF; then
        err "IPv6 已禁用，但恢复记录提交失败；已保留待恢复记录。"
        return 1
    fi

    info "IPv6 已禁用，重启后仍会保持禁用。"
    info "可通过 vpsbox 系统改动恢复菜单恢复禁用前状态。"
}

report_ipv6_reenable_address_state() {
    local addresses

    if ! addresses="$(global_ipv6_addresses)"; then
        warn "IPv6 开关已恢复，但无法读取全局 IPv6 地址；请通过 IPv4 或 VPS 控制台检查。"
    elif [ -z "$addresses" ]; then
        warn "IPv6 开关已恢复，但全局 IPv6 地址尚未重新出现。"
        warn "请保持 IPv4 或控制台连接，并在方便时重启 VPS。"
    else
        info "已重新检测到全局 IPv6 地址。"
    fi
}

ipv6_reenable_snapshot_path_allowed() {
    local snapshot="$1" parent expected_parent base

    [ -n "$snapshot" ] || return 1
    parent="$(dirname -- "$snapshot")" || return 1
    expected_parent="$(dirname -- "$IPV6_DISABLE_CONF")" || return 1
    base="${snapshot##*/}"
    [ "$parent" = "$expected_parent" ] && [[ "$base" == .vpsbox-enable-ipv6.* ]]
}

arm_untracked_ipv6_reenable_rollback() {
    local snapshot="$1" old_all="$2" old_default="$3" old_lo="$4"

    [ -z "${ACTIVE_IPV6_REENABLE_SNAPSHOT:-}" ] || return 1
    ipv6_reenable_snapshot_path_allowed "$snapshot" &&
        [ -f "$snapshot" ] && [ ! -L "$snapshot" ] || return 1
    [[ "$old_all" =~ ^[01]$ ]] && [[ "$old_default" =~ ^[01]$ ]] &&
        [[ "$old_lo" =~ ^[01]$ ]] || return 1
    ACTIVE_IPV6_REENABLE_OLD_VALUES="$old_all $old_default $old_lo"
    # 最后登记快照作为活动标记；在此之前尚未修改配置或运行参数。
    ACTIVE_IPV6_REENABLE_SNAPSHOT="$snapshot"
}

clear_active_untracked_ipv6_reenable() {
    ACTIVE_IPV6_REENABLE_SNAPSHOT=""
    ACTIVE_IPV6_REENABLE_OLD_VALUES=""
}

rollback_active_untracked_ipv6_reenable() {
    local snapshot="${ACTIVE_IPV6_REENABLE_SNAPSHOT:-}"
    local old_values="${ACTIVE_IPV6_REENABLE_OLD_VALUES:-}"
    local old_all old_default old_lo failed=0

    [ -n "$snapshot" ] || return 0
    ipv6_reenable_snapshot_path_allowed "$snapshot" &&
        [ -f "$snapshot" ] && [ ! -L "$snapshot" ] || return 1
    read -r old_all old_default old_lo <<< "$old_values"
    [[ "$old_all" =~ ^[01]$ ]] && [[ "$old_default" =~ ^[01]$ ]] &&
        [[ "$old_lo" =~ ^[01]$ ]] || return 1

    if [ -e "$IPV6_DISABLE_CONF" ] || [ -L "$IPV6_DISABLE_CONF" ]; then
        ipv6_disable_config_is_current || failed=1
    else
        restore_file_atomically_from_snapshot "$snapshot" "$IPV6_DISABLE_CONF" || failed=1
    fi
    restore_ipv6_runtime_values "$old_all" "$old_default" "$old_lo" || failed=1
    [ "$failed" -eq 0 ] || return 1

    clear_active_untracked_ipv6_reenable
    rm -f -- "$snapshot" || warn "IPv6 原状态已恢复，但临时快照清理失败：$snapshot"
}

reenable_untracked_ipv6() {
    local runtime_values old_all old_default old_lo parent snapshot failed=0

    ipv6_disable_config_is_current || {
        err "未找到可安全识别的 vpsbox IPv6 禁用配置，已拒绝自动处理。"
        return 1
    }
    [ "$(change_restore_state IPV6_CONF)" = "none" ] || {
        err "检测到 IPv6 恢复记录，请使用正常恢复流程。"
        return 1
    }
    runtime_values="$(ipv6_disable_runtime_values)" || {
        err "无法读取 IPv6 内核运行参数，未修改系统。"
        return 1
    }
    read -r old_all old_default old_lo <<< "$runtime_values"
    parent="$(dirname "$IPV6_DISABLE_CONF")"
    [ -d "$parent" ] && [ ! -L "$parent" ] || {
        err "IPv6 配置目录不存在或不安全：$parent"
        return 1
    }
    snapshot="$(mktemp "$parent/.vpsbox-enable-ipv6.XXXXXX")" || return 1
    if ! cp -a -- "$IPV6_DISABLE_CONF" "$snapshot"; then
        rm -f -- "$snapshot"
        err "创建 IPv6 重新启用快照失败，未修改系统。"
        return 1
    fi
    if ! arm_untracked_ipv6_reenable_rollback "$snapshot" \
        "$old_all" "$old_default" "$old_lo"; then
        rm -f -- "$snapshot"
        err "登记 IPv6 中断回滚状态失败，未修改系统。"
        return 1
    fi

    sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1 || failed=1
    sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1 || failed=1
    sysctl -w net.ipv6.conf.lo.disable_ipv6=0 >/dev/null 2>&1 || failed=1
    if [ "$failed" -ne 0 ] || ! ipv6_runtime_matches_values 0 0 0; then
        if ! rollback_active_untracked_ipv6_reenable; then
            err "重新启用 IPv6 失败，且禁用配置或原运行参数未能完整恢复。"
            err "请通过 IPv4 或 VPS 控制台检查 IPv6 配置。"
        else
            err "重新启用 IPv6 失败，已恢复原禁用配置和运行参数。"
        fi
        return 1
    fi

    if ! rm -f -- "$IPV6_DISABLE_CONF"; then
        if ! rollback_active_untracked_ipv6_reenable; then
            err "移除 IPv6 禁用配置失败，且原配置或运行参数未能完整恢复。"
            err "请通过 IPv4 或 VPS 控制台检查 IPv6 配置。"
        else
            err "移除 IPv6 禁用配置失败，已恢复原禁用配置和运行参数。"
        fi
        return 1
    fi

    # 文件移除且运行参数已验收即提交；此后中断不应回滚成功状态。
    clear_active_untracked_ipv6_reenable
    rm -f -- "$snapshot" || warn "IPv6 已重新启用，但临时快照清理失败：$snapshot"
    info "vpsbox IPv6 禁用配置已移除，all/default/lo 已设置为 0。"
    report_ipv6_reenable_address_state
}

tcp_buffer_tier_max() {
    case "$1" in
        1) printf '%s\n' "$TCP_BUFFER_TIER_1_MAX" ;;
        2) printf '%s\n' "$TCP_BUFFER_TIER_2_MAX" ;;
        3) printf '%s\n' "$TCP_BUFFER_TIER_3_MAX" ;;
        *) return 2 ;;
    esac
}

tcp_buffer_tier_description() {
    case "$1" in
        1) printf '%s\n' "第一档（100–300 Mbps / 最大 8 MiB）" ;;
        2) printf '%s\n' "第二档（301–600 Mbps / 最大 16 MiB）" ;;
        3) printf '%s\n' "第三档（601–1000 Mbps / 最大 32 MiB）" ;;
        *) return 2 ;;
    esac
}

tcp_buffer_format_bytes() {
    local raw="$1" value

    [[ "$raw" =~ ^[0-9]+$ ]] || return 1
    value=$((10#$raw))
    if [ $((value % 1048576)) -eq 0 ]; then
        printf '%s MiB\n' "$((value / 1048576))"
    elif [ $((value % 1024)) -eq 0 ]; then
        printf '%s KiB\n' "$((value / 1024))"
    else
        printf '%s B\n' "$value"
    fi
}

normalize_tcp_buffer_vector() {
    local raw="$1" minimum default maximum extra

    read -r minimum default maximum extra <<< "$raw"
    [ -z "${extra:-}" ] &&
        [[ "$minimum" =~ ^[0-9]+$ ]] &&
        [[ "$default" =~ ^[0-9]+$ ]] &&
        [[ "$maximum" =~ ^[0-9]+$ ]] || return 1
    [ $((10#$minimum)) -le $((10#$default)) ] &&
        [ $((10#$default)) -le $((10#$maximum)) ] || return 1
    printf '%s,%s,%s\n' "$minimum" "$default" "$maximum"
}

tcp_buffer_vector_to_spaces() {
    local csv="$1" minimum default maximum extra

    IFS=, read -r minimum default maximum extra <<< "$csv"
    [ -z "${extra:-}" ] &&
        [[ "$minimum" =~ ^[0-9]+$ ]] &&
        [[ "$default" =~ ^[0-9]+$ ]] &&
        [[ "$maximum" =~ ^[0-9]+$ ]] || return 1
    [ $((10#$minimum)) -le $((10#$default)) ] &&
        [ $((10#$default)) -le $((10#$maximum)) ] || return 1
    printf '%s %s %s\n' "$minimum" "$default" "$maximum"
}

tcp_buffer_runtime_values() {
    local core_rmem core_wmem tcp_rmem tcp_wmem

    core_rmem="$(sysctl -n net.core.rmem_max 2>/dev/null)" || return 1
    core_wmem="$(sysctl -n net.core.wmem_max 2>/dev/null)" || return 1
    [[ "$core_rmem" =~ ^[0-9]+$ ]] && [[ "$core_wmem" =~ ^[0-9]+$ ]] || return 1
    tcp_rmem="$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null)" || return 1
    tcp_wmem="$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null)" || return 1
    tcp_rmem="$(normalize_tcp_buffer_vector "$tcp_rmem")" || return 1
    tcp_wmem="$(normalize_tcp_buffer_vector "$tcp_wmem")" || return 1
    printf '%s %s %s %s\n' "$core_rmem" "$core_wmem" "$tcp_rmem" "$tcp_wmem"
}

tcp_buffer_autotuning_values() {
    local moderate window_scaling

    moderate="$(sysctl -n net.ipv4.tcp_moderate_rcvbuf 2>/dev/null)" || return 1
    window_scaling="$(sysctl -n net.ipv4.tcp_window_scaling 2>/dev/null)" || return 1
    [[ "$moderate" =~ ^[01]$ ]] && [[ "$window_scaling" =~ ^[01]$ ]] || return 1
    printf '%s %s\n' "$moderate" "$window_scaling"
}

tcp_buffer_autotuning_is_ready() {
    [ "$(tcp_buffer_autotuning_values 2>/dev/null)" = "1 1" ]
}

tcp_buffer_target_values() {
    local source="$1" target_max="$2"
    local _core_rmem _core_wmem tcp_rmem tcp_wmem
    local rmem_min rmem_default _rmem_max wmem_min wmem_default _wmem_max

    [[ "$target_max" =~ ^[0-9]+$ ]] || return 1
    read -r _core_rmem _core_wmem tcp_rmem tcp_wmem <<< "$source"
    tcp_buffer_vector_to_spaces "$tcp_rmem" >/dev/null || return 1
    tcp_buffer_vector_to_spaces "$tcp_wmem" >/dev/null || return 1
    IFS=, read -r rmem_min rmem_default _rmem_max <<< "$tcp_rmem"
    IFS=, read -r wmem_min wmem_default _wmem_max <<< "$tcp_wmem"
    [ $((10#$rmem_default)) -le $((10#$target_max)) ] &&
        [ $((10#$wmem_default)) -le $((10#$target_max)) ] || return 2
    printf '%s %s %s,%s,%s %s,%s,%s\n' \
        "$target_max" "$target_max" \
        "$rmem_min" "$rmem_default" "$target_max" \
        "$wmem_min" "$wmem_default" "$target_max"
}

render_tcp_buffer_config() {
    local values="$1" core_rmem core_wmem tcp_rmem tcp_wmem
    local tcp_rmem_spaces tcp_wmem_spaces

    read -r core_rmem core_wmem tcp_rmem tcp_wmem <<< "$values"
    [[ "$core_rmem" =~ ^[0-9]+$ ]] && [[ "$core_wmem" =~ ^[0-9]+$ ]] || return 1
    tcp_rmem_spaces="$(tcp_buffer_vector_to_spaces "$tcp_rmem")" || return 1
    tcp_wmem_spaces="$(tcp_buffer_vector_to_spaces "$tcp_wmem")" || return 1
    # --- BEGIN GENERATED TEMPLATE: TCP buffer sysctl drop-in ---
    cat <<EOF
net.core.rmem_max = $core_rmem
net.core.wmem_max = $core_wmem
net.ipv4.tcp_rmem = $tcp_rmem_spaces
net.ipv4.tcp_wmem = $tcp_wmem_spaces
EOF
    # --- END GENERATED TEMPLATE: TCP buffer sysctl drop-in ---
}

tcp_buffer_config_values() {
    [ -f "$TCP_BUFFER_CONF" ] && [ ! -L "$TCP_BUFFER_CONF" ] || return 1
    awk '
        function extract_value(line, value) {
            value = line
            sub(/^[^=]*=[[:space:]]*/, "", value)
            sub(/[[:space:]]*$/, "", value)
            return value
        }
        /^[[:space:]]*$/ { next }
        {
            line = $0
            sub(/^[[:space:]]*/, "", line)
            count++
            if (line ~ /^net[.]core[.]rmem_max[[:space:]]*=[[:space:]]*[0-9]+[[:space:]]*$/ && !seen_core_rmem++) {
                core_rmem = extract_value(line)
            } else if (line ~ /^net[.]core[.]wmem_max[[:space:]]*=[[:space:]]*[0-9]+[[:space:]]*$/ && !seen_core_wmem++) {
                core_wmem = extract_value(line)
            } else if (line ~ /^net[.]ipv4[.]tcp_rmem[[:space:]]*=[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+[[:space:]]*$/ && !seen_tcp_rmem++) {
                tcp_rmem = extract_value(line)
                gsub(/[[:space:]]+/, ",", tcp_rmem)
            } else if (line ~ /^net[.]ipv4[.]tcp_wmem[[:space:]]*=[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+[[:space:]]*$/ && !seen_tcp_wmem++) {
                tcp_wmem = extract_value(line)
                gsub(/[[:space:]]+/, ",", tcp_wmem)
            } else {
                invalid = 1
            }
        }
        END {
            if (invalid || count != 4 || seen_core_rmem != 1 || seen_core_wmem != 1 || seen_tcp_rmem != 1 || seen_tcp_wmem != 1) {
                exit 1
            }
            print core_rmem, core_wmem, tcp_rmem, tcp_wmem
        }
    ' "$TCP_BUFFER_CONF"
}

tcp_buffer_tier_from_values() {
    local values="$1" core_rmem core_wmem tcp_rmem tcp_wmem
    local _rmem_min _rmem_default rmem_max _wmem_min _wmem_default wmem_max
    local tier target_max

    read -r core_rmem core_wmem tcp_rmem tcp_wmem <<< "$values"
    [[ "$core_rmem" =~ ^[0-9]+$ ]] && [[ "$core_wmem" =~ ^[0-9]+$ ]] || return 1
    tcp_buffer_vector_to_spaces "$tcp_rmem" >/dev/null || return 1
    tcp_buffer_vector_to_spaces "$tcp_wmem" >/dev/null || return 1
    IFS=, read -r _rmem_min _rmem_default rmem_max <<< "$tcp_rmem"
    IFS=, read -r _wmem_min _wmem_default wmem_max <<< "$tcp_wmem"
    for tier in 1 2 3; do
        target_max="$(tcp_buffer_tier_max "$tier")" || return 1
        if [ "$core_rmem" = "$target_max" ] && [ "$core_wmem" = "$target_max" ] &&
            [ "$rmem_max" = "$target_max" ] && [ "$wmem_max" = "$target_max" ]; then
            printf '%s\n' "$tier"
            return 0
        fi
    done
    return 1
}

tcp_buffer_persistent_matches_values() {
    local expected="$1" actual

    actual="$(tcp_buffer_config_values)" || return 1
    [ "$actual" = "$expected" ]
}

tcp_buffer_runtime_matches_values() {
    local expected="$1" actual

    actual="$(tcp_buffer_runtime_values)" || return 1
    [ "$actual" = "$expected" ]
}

tcp_buffer_summary_state() {
    local values tier

    if ! values="$(tcp_buffer_config_values 2>/dev/null)"; then
        if [ -e "$TCP_BUFFER_CONF" ] || [ -L "$TCP_BUFFER_CONF" ]; then
            printf '%s\n' "配置异常"
        else
            printf '%s\n' "未配置"
        fi
        return 0
    fi
    tier="$(tcp_buffer_tier_from_values "$values" 2>/dev/null)" || {
        printf '%s\n' "配置异常"
        return 0
    }
    if ! tcp_buffer_runtime_matches_values "$values"; then
        printf '%s\n' "第${tier}档配置存在但未生效"
    elif ! tcp_buffer_autotuning_is_ready; then
        printf '%s\n' "第${tier}档已配置，自动调节未开启"
    else
        tcp_buffer_tier_description "$tier"
    fi
}

print_tcp_buffer_values() {
    local title="$1" values="$2" core_rmem core_wmem tcp_rmem tcp_wmem
    local rmem_min rmem_default rmem_max wmem_min wmem_default wmem_max

    read -r core_rmem core_wmem tcp_rmem tcp_wmem <<< "$values"
    tcp_buffer_vector_to_spaces "$tcp_rmem" >/dev/null || return 1
    tcp_buffer_vector_to_spaces "$tcp_wmem" >/dev/null || return 1
    IFS=, read -r rmem_min rmem_default rmem_max <<< "$tcp_rmem"
    IFS=, read -r wmem_min wmem_default wmem_max <<< "$tcp_wmem"
    printf ' %s\n' "$title"
    printf ' 系统接收缓冲区上限：%s\n' "$(tcp_buffer_format_bytes "$core_rmem")"
    printf ' 系统发送缓冲区上限：%s\n' "$(tcp_buffer_format_bytes "$core_wmem")"
    printf ' TCP 接收缓冲区：最小 %s / 默认 %s / 最大 %s\n' \
        "$(tcp_buffer_format_bytes "$rmem_min")" \
        "$(tcp_buffer_format_bytes "$rmem_default")" \
        "$(tcp_buffer_format_bytes "$rmem_max")"
    printf ' TCP 发送缓冲区：最小 %s / 默认 %s / 最大 %s\n' \
        "$(tcp_buffer_format_bytes "$wmem_min")" \
        "$(tcp_buffer_format_bytes "$wmem_default")" \
        "$(tcp_buffer_format_bytes "$wmem_max")"
}

restore_tcp_buffer_runtime_values() {
    local values="$1" core_rmem core_wmem tcp_rmem tcp_wmem failed=0
    local tcp_rmem_spaces tcp_wmem_spaces

    read -r core_rmem core_wmem tcp_rmem tcp_wmem <<< "$values"
    [[ "$core_rmem" =~ ^[0-9]+$ ]] && [[ "$core_wmem" =~ ^[0-9]+$ ]] || return 1
    tcp_rmem_spaces="$(tcp_buffer_vector_to_spaces "$tcp_rmem")" || return 1
    tcp_wmem_spaces="$(tcp_buffer_vector_to_spaces "$tcp_wmem")" || return 1
    sysctl -w "net.core.rmem_max=$core_rmem" >/dev/null 2>&1 || failed=1
    sysctl -w "net.core.wmem_max=$core_wmem" >/dev/null 2>&1 || failed=1
    sysctl -w "net.ipv4.tcp_rmem=$tcp_rmem_spaces" >/dev/null 2>&1 || failed=1
    sysctl -w "net.ipv4.tcp_wmem=$tcp_wmem_spaces" >/dev/null 2>&1 || failed=1
    [ "$failed" -eq 0 ] && tcp_buffer_runtime_matches_values "$values"
}

cancel_unmodified_tcp_buffer_change() {
    if ! cancel_unmodified_change_transaction \
        TCP_BUFFER_CONF TCP_BUFFER_RMEM_MAX TCP_BUFFER_WMEM_MAX \
        TCP_BUFFER_TCP_RMEM TCP_BUFFER_TCP_WMEM; then
        err "清理尚未应用的 TCP 缓冲区修改记录失败，请先使用恢复菜单检查系统改动。"
        return 1
    fi
}

tcp_buffer_values_have_max_above() {
    local values="$1" target_max="$2" core_rmem core_wmem tcp_rmem tcp_wmem
    local _a _b rmem_max _c _d wmem_max

    read -r core_rmem core_wmem tcp_rmem tcp_wmem <<< "$values"
    IFS=, read -r _a _b rmem_max <<< "$tcp_rmem"
    IFS=, read -r _c _d wmem_max <<< "$tcp_wmem"
    [ $((10#$core_rmem)) -gt $((10#$target_max)) ] ||
        [ $((10#$core_wmem)) -gt $((10#$target_max)) ] ||
        [ $((10#$rmem_max)) -gt $((10#$target_max)) ] ||
        [ $((10#$wmem_max)) -gt $((10#$target_max)) ]
}

apply_tcp_buffer_tier() {
    local tier="$1" target_max tier_description runtime_values source_values target_values
    local config_values="" current_config_values="" config_present=0
    local auto_values parent tmp tracking_state
    local old_core_rmem old_core_wmem old_tcp_rmem old_tcp_wmem
    local auto_moderate auto_window

    target_max="$(tcp_buffer_tier_max "$tier")" || return 2
    tier_description="$(tcp_buffer_tier_description "$tier")" || return 2
    tracking_state="$(change_restore_state_readonly TCP_BUFFER_CONF)" || return 1
    if [ "$tracking_state" = "pending" ]; then
        err "检测到尚未处理的 TCP 缓冲区修改事务，请先在恢复菜单中检查或恢复。"
        return 1
    fi
    if [ -e "$TCP_BUFFER_CONF" ] || [ -L "$TCP_BUFFER_CONF" ]; then
        [ -f "$TCP_BUFFER_CONF" ] && [ ! -L "$TCP_BUFFER_CONF" ] || {
            err "$TCP_BUFFER_CONF 不是安全的普通文件，已拒绝覆盖。"
            return 1
        }
        if ! config_values="$(tcp_buffer_config_values)" ||
            ! tcp_buffer_tier_from_values "$config_values" >/dev/null 2>&1; then
            err "$TCP_BUFFER_CONF 内容不符合 vpsbox TCP 四项档位模板，已拒绝覆盖。"
            return 1
        fi
        config_present=1
    fi
    runtime_values="$(tcp_buffer_runtime_values)" || {
        err "无法读取 TCP 缓冲区运行参数，未修改系统。"
        return 1
    }
    auto_values="$(tcp_buffer_autotuning_values)" || {
        err "无法读取 TCP 自动调节或窗口缩放状态，未修改系统。"
        return 1
    }
    if [ "$auto_values" != "1 1" ]; then
        read -r auto_moderate auto_window <<< "$auto_values"
        err "TCP 自动调节条件未满足，未修改系统。"
        info "net.ipv4.tcp_moderate_rcvbuf=$auto_moderate"
        info "net.ipv4.tcp_window_scaling=$auto_window"
        return 1
    fi

    source_values="$runtime_values"
    if [ "$config_present" -eq 1 ]; then
        source_values="$config_values"
    fi
    if ! target_values="$(tcp_buffer_target_values "$source_values" "$target_max")"; then
        err "当前 TCP 最小值或默认值高于所选档位上限，请选择更高档位。"
        return 1
    fi

    echo "========================================"
    echo " TCP 缓冲区调优"
    echo "========================================"
    printf ' 已选择：%s\n' "$tier_description"
    echo "----------------------------------------"
    print_tcp_buffer_values "当前参数" "$runtime_values" || return 1
    echo "----------------------------------------"
    print_tcp_buffer_values "目标参数" "$target_values" || return 1
    echo "----------------------------------------"
    echo "缓冲区最大值是动态上限，不会立即占用对应大小的内存。"
    if tcp_buffer_values_have_max_above "$runtime_values" "$target_max"; then
        warn "所选档位低于当前部分最大值，本次应用会下调这些上限。"
    fi

    if tcp_buffer_persistent_matches_values "$target_values" &&
        tcp_buffer_runtime_matches_values "$target_values"; then
        info "当前 TCP 缓冲区配置和运行状态已是所选档位，无需重复应用。"
        return 0
    fi
    if ! confirm_default_yes "是否应用所选 TCP 缓冲区参数？"; then
        info "已取消 TCP 缓冲区调优。"
        return 0
    fi

    parent="$(dirname "$TCP_BUFFER_CONF")"
    [ -d "$parent" ] && [ ! -L "$parent" ] || {
        err "TCP 缓冲区配置目录不存在或不安全：$parent"
        return 1
    }
    if [ "$config_present" -eq 1 ]; then
        if [ ! -f "$TCP_BUFFER_CONF" ] || [ -L "$TCP_BUFFER_CONF" ] ||
            ! current_config_values="$(tcp_buffer_config_values)" ||
            ! tcp_buffer_tier_from_values "$current_config_values" >/dev/null 2>&1 ||
            [ "$current_config_values" != "$config_values" ]; then
            err "$TCP_BUFFER_CONF 在确认期间发生变化，已拒绝覆盖。"
            return 1
        fi
    elif [ -e "$TCP_BUFFER_CONF" ] || [ -L "$TCP_BUFFER_CONF" ]; then
        err "$TCP_BUFFER_CONF 在确认期间出现，已拒绝覆盖。"
        return 1
    fi

    tracking_state="$(change_restore_state TCP_BUFFER_CONF)" || return 1
    if [ "$tracking_state" = "pending" ]; then
        err "检测到尚未处理的 TCP 缓冲区修改事务，请先在恢复菜单中检查或恢复。"
        return 1
    fi
    if [ "$tracking_state" = "none" ] && {
        [ -n "$(manifest_value BACKUP_TCP_BUFFER_CONF 2>/dev/null || true)" ] ||
            [ -n "$(manifest_value TCP_BUFFER_RMEM_MAX 2>/dev/null || true)" ] ||
            [ -n "$(manifest_value TCP_BUFFER_WMEM_MAX 2>/dev/null || true)" ] ||
            [ -n "$(manifest_value TCP_BUFFER_TCP_RMEM 2>/dev/null || true)" ] ||
            [ -n "$(manifest_value TCP_BUFFER_TCP_WMEM 2>/dev/null || true)" ];
    }; then
        cancel_unmodified_tcp_buffer_change || return 1
    fi

    read -r old_core_rmem old_core_wmem old_tcp_rmem old_tcp_wmem <<< "$runtime_values"
    if ! backup_change_file_once TCP_BUFFER_CONF "$TCP_BUFFER_CONF" ||
        ! manifest_set_once TCP_BUFFER_RMEM_MAX "$old_core_rmem" ||
        ! manifest_set_once TCP_BUFFER_WMEM_MAX "$old_core_wmem" ||
        ! manifest_set_once TCP_BUFFER_TCP_RMEM "$old_tcp_rmem" ||
        ! manifest_set_once TCP_BUFFER_TCP_WMEM "$old_tcp_wmem"; then
        cancel_unmodified_tcp_buffer_change || true
        err "记录 TCP 缓冲区原配置失败，已取消修改。"
        return 1
    fi
    if ! begin_change_transaction TCP_BUFFER_CONF; then
        cancel_unmodified_tcp_buffer_change || true
        err "记录 TCP 缓冲区修改事务失败，已取消修改。"
        return 1
    fi

    tmp="$(mktemp "$parent/.vpsbox-tcp-buffer.XXXXXX")" || {
        cancel_unmodified_tcp_buffer_change || true
        return 1
    }
    if ! render_tcp_buffer_config "$target_values" > "$tmp" ||
        ! chown root:root "$tmp" ||
        ! chmod 644 "$tmp"; then
        rm -f -- "$tmp"
        cancel_unmodified_tcp_buffer_change || true
        err "生成 TCP 缓冲区配置失败，未修改系统。"
        return 1
    fi

    if ! sysctl -p "$tmp" >/dev/null 2>&1 ||
        ! tcp_buffer_runtime_matches_values "$target_values" ||
        ! tcp_buffer_autotuning_is_ready; then
        rm -f -- "$tmp"
        if restore_tcp_buffer_runtime_values "$runtime_values"; then
            if cancel_unmodified_tcp_buffer_change; then
                err "TCP 缓冲区调优未能完整生效；运行参数已恢复，持久配置未改动。"
            else
                err "TCP 缓冲区调优失败；运行参数已恢复，但事务记录清理失败。"
            fi
        else
            err "TCP 缓冲区调优失败，且运行参数未能确认完整恢复。"
            err "已保留事务记录，请使用恢复菜单处理。"
        fi
        return 1
    fi

    if ! mv -f -- "$tmp" "$TCP_BUFFER_CONF"; then
        rm -f -- "$tmp"
        if restore_tcp_buffer_runtime_values "$runtime_values"; then
            if cancel_unmodified_tcp_buffer_change; then
                err "保存 TCP 缓冲区配置失败；运行参数已恢复，原配置未改动。"
            else
                err "保存 TCP 缓冲区配置失败；运行参数已恢复，但事务记录清理失败。"
            fi
        else
            err "保存 TCP 缓冲区配置失败，且运行参数未能确认完整恢复。"
            err "已保留事务记录，请使用恢复菜单处理。"
        fi
        return 1
    fi

    if ! mark_change_applied TCP_BUFFER_CONF; then
        err "TCP 缓冲区参数已应用，但恢复记录提交失败；已保留待恢复记录。"
        return 1
    fi
    info "TCP 缓冲区调优已应用。"
    info "当前档位：$tier_description"
    info "配置重启后仍会生效，可通过系统改动恢复菜单恢复。"
}

tcp_buffer_menu() {
    local opt

    while true; do
        clear 2>/dev/null || true
        cat <<EOF
========================================
 TCP 缓冲区调优
========================================
 当前状态：$(tcp_buffer_summary_state)
----------------------------------------
 [1] 第一档（100–300 Mbps / 最大 8 MiB）
 [2] 第二档（301–600 Mbps / 最大 16 MiB）
 [3] 第三档（601–1000 Mbps / 最大 32 MiB）
----------------------------------------
 [0] 返回系统优化菜单
========================================
EOF
        read -r -p "请输入选项: " opt || return 0
        echo ""
        case "$opt" in
            1|2|3) run_menu_action apply_tcp_buffer_tier "$opt"; pause ;;
            0) return 0 ;;
            *) warn "无效选项：$opt"; pause ;;
        esac
    done
}

render_bbr_fq_config() {
    # --- BEGIN GENERATED TEMPLATE: BBR and fq sysctl drop-in ---
    cat <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    # --- END GENERATED TEMPLATE: BBR and fq sysctl drop-in ---
}

bbr_fq_persistent_config_is_current() {
    [ -f "$BBR_CONF" ] && [ ! -L "$BBR_CONF" ] || return 1
    render_bbr_fq_config | cmp -s - "$BBR_CONF"
}

bbr_fq_runtime_is_current() {
    [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)" = "bbr" ] &&
        [ "$(sysctl -n net.core.default_qdisc 2>/dev/null || true)" = "fq" ]
}

repair_bbr_fq_runtime() {
    local old_cc old_fq

    old_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
    old_fq="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
    if ! modprobe tcp_bbr >/dev/null 2>&1 ||
        ! modprobe sch_fq >/dev/null 2>&1 ||
        ! sysctl -p "$BBR_CONF" >/dev/null 2>&1 ||
        ! bbr_fq_runtime_is_current; then
        [ -n "$old_cc" ] && sysctl -w "net.ipv4.tcp_congestion_control=$old_cc" >/dev/null 2>&1 || true
        [ -n "$old_fq" ] && sysctl -w "net.core.default_qdisc=$old_fq" >/dev/null 2>&1 || true
        return 1
    fi
}

bbr_runtime_matches_values() {
    local expected_cc="$1" expected_fq="$2" current_cc current_fq

    current_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" || return 1
    current_fq="$(sysctl -n net.core.default_qdisc 2>/dev/null)" || return 1
    [ "$current_cc" = "$expected_cc" ] && [ "$current_fq" = "$expected_fq" ]
}

restore_bbr_runtime_values() {
    local old_cc="$1" old_fq="$2" failed=0

    if [ -n "$old_cc" ]; then
        sysctl -w "net.ipv4.tcp_congestion_control=$old_cc" >/dev/null 2>&1 || failed=1
    else
        failed=1
    fi
    if [ -n "$old_fq" ]; then
        sysctl -w "net.core.default_qdisc=$old_fq" >/dev/null 2>&1 || failed=1
    else
        failed=1
    fi
    [ "$failed" -eq 0 ] && bbr_runtime_matches_values "$old_cc" "$old_fq"
}

cancel_unmodified_bbr_change() {
    if ! cancel_unmodified_change_transaction BBR_CONF BBR_CC BBR_FQ; then
        err "清理尚未应用的 BBR 修改记录失败，请先使用恢复菜单检查系统改动。"
        return 1
    fi
}

enable_bbr_fq() {
    local old_cc old_fq tmp parent tracking_state

    tracking_state="$(change_restore_state_readonly BBR_CONF)" || return 1
    if [ "$tracking_state" = "pending" ]; then
        err "检测到尚未处理的 BBR 修改事务，请先在恢复菜单中检查或恢复。"
        return 1
    fi

    if bbr_fq_persistent_config_is_current; then
        if bbr_fq_runtime_is_current; then
            info "BBR + fq 配置和运行状态已正确，无需重复应用。"
            return 0
        fi
        info "BBR + fq 持久化配置已存在，正在轻量修复运行参数..."
        if ! repair_bbr_fq_runtime; then
            err "BBR + fq 运行参数修复失败，已恢复修改前的运行参数。"
            return 1
        fi
        info "当前 BBR：$(bbr_state)"
        info "当前 fq：$(fq_state)"
        return 0
    fi

    tracking_state="$(change_restore_state BBR_CONF)" || return 1
    if [ "$tracking_state" = "pending" ]; then
        err "检测到尚未处理的 BBR 修改事务，请先在恢复菜单中检查或恢复。"
        return 1
    fi
    if [ "$tracking_state" = "none" ] && {
        [ -n "$(manifest_value BACKUP_BBR_CONF 2>/dev/null || true)" ] ||
            [ -n "$(manifest_value BBR_CC 2>/dev/null || true)" ] ||
            [ -n "$(manifest_value BBR_FQ 2>/dev/null || true)" ];
    }; then
        cancel_unmodified_bbr_change || return 1
    fi

    old_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
    old_fq="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
    if [ -e "$BBR_CONF" ] || [ -L "$BBR_CONF" ]; then
        [ ! -L "$BBR_CONF" ] || { err "$BBR_CONF 是符号链接，已拒绝覆盖。"; return 1; }
    fi
    if ! modprobe tcp_bbr >/dev/null 2>&1 || ! modprobe sch_fq >/dev/null 2>&1; then
        err "内核不支持 tcp_bbr 或 sch_fq，未写入持久化配置。"
        return 1
    fi
    if ! backup_change_file_once BBR_CONF "$BBR_CONF" ||
        ! manifest_set_once BBR_CC "${old_cc:-unknown}" ||
        ! manifest_set_once BBR_FQ "${old_fq:-unknown}"; then
        cancel_unmodified_bbr_change || true
        err "记录 BBR 原配置失败，已取消修改。"
        return 1
    fi
    if ! begin_change_transaction BBR_CONF; then
        cancel_unmodified_bbr_change || true
        err "记录 BBR 修改事务失败，已取消修改。"
        return 1
    fi
    parent="$(dirname "$BBR_CONF")"
    if [ ! -d "$parent" ] || [ -L "$parent" ]; then
        cancel_unmodified_bbr_change || true
        err "BBR 配置目录不存在或不安全：$parent"
        return 1
    fi
    tmp="$(mktemp "$parent/.vpsbox-bbr.XXXXXX")" || {
        cancel_unmodified_bbr_change || true
        return 1
    }
    render_bbr_fq_config > "$tmp" || {
        rm -f -- "$tmp"
        cancel_unmodified_bbr_change || true
        return 1
    }

    if ! sysctl -p "$tmp" >/dev/null 2>&1 || [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)" != "bbr" ] || [ "$(sysctl -n net.core.default_qdisc 2>/dev/null || true)" != "fq" ]; then
        rm -f -- "$tmp"
        if restore_bbr_runtime_values "$old_cc" "$old_fq"; then
            cancel_unmodified_bbr_change || true
            err "BBR + fq 未能同时生效；运行时内核参数已恢复，未写入持久化配置。"
        else
            err "BBR + fq 未能同时生效，且运行时内核参数未能确认完整恢复；已保留事务记录，请使用恢复菜单处理。"
        fi
        return 1
    fi

    if ! chown root:root "$tmp" || ! chmod 644 "$tmp" || ! mv -f "$tmp" "$BBR_CONF"; then
        rm -f -- "$tmp"
        if restore_bbr_runtime_values "$old_cc" "$old_fq"; then
            cancel_unmodified_bbr_change || true
            err "保存 BBR 配置失败；原持久化配置未被替换，运行时参数已恢复。"
        else
            err "保存 BBR 配置失败，且运行时参数未能确认完整恢复；已保留事务记录，请使用恢复菜单处理。"
        fi
        return 1
    fi
    mark_change_applied BBR_CONF || return 1

    echo ""
    info "当前 BBR：$(bbr_state)"
    info "当前 fq：$(fq_state)"
}

ensure_fail2ban_service_running() {
    if is_systemd; then
        systemctl enable fail2ban >/dev/null 2>&1 || return 1
        if [ "$(fail2ban_service_state)" != "运行中" ]; then
            retry 3 2 systemctl start fail2ban || return 1
        fi
    elif [ "$OS" = "alpine" ] && command -v rc-service >/dev/null 2>&1; then
        command -v rc-update >/dev/null 2>&1 || return 1
        rc-update add fail2ban default >/dev/null 2>&1 || return 1
        if [ "$(fail2ban_service_state)" != "运行中" ]; then
            retry 3 2 rc-service fail2ban start || return 1
        fi
    else
        return 1
    fi
}

install_fail2ban() {
    local original_active original_enabled

    detect_os
    if fail2ban_sshd_configuration_healthy; then
        ensure_fail2ban_nftables_dependency || return 1
        info "Fail2ban SSH 防护已正常运行，无需重复安装或配置。"
        return 0
    fi

    if [ "$(fail2ban_service_state)" = "运行中" ]; then
        original_active=active
    else
        original_active=inactive
    fi
    if fail2ban_service_is_enabled; then
        original_enabled=enabled
    else
        original_enabled=disabled
    fi
    ensure_change_store || return 1
    backup_change_file_once FAIL2BAN_SSHD "$FAIL2BAN_VPSBOX_SSHD_CONF" || return 1
    manifest_set_once FAIL2BAN_ACTIVE "$original_active" || return 1
    manifest_set_once FAIL2BAN_ENABLED "$original_enabled" || return 1
    begin_change_transaction FAIL2BAN_SSHD || {
        err "记录 Fail2ban 安装事务失败，已取消修改。"
        return 1
    }

    if ! fail2ban_installed; then
        info "正在安装 Fail2ban..."
        case "$OS" in
            debian)
                export DEBIAN_FRONTEND=noninteractive
                if ! apt_get_bounded "$PACKAGE_UPDATE_TIMEOUT" update ||
                    ! apt_get_bounded "$PACKAGE_INSTALL_TIMEOUT" install -y fail2ban nftables; then
                    warn "Fail2ban 安装未完全成功，将检查最终安装状态。"
                fi
                ;;
            alpine)
                if ! apk_bounded "$PACKAGE_UPDATE_TIMEOUT" update ||
                    ! apk_bounded "$PACKAGE_INSTALL_TIMEOUT" add --no-cache fail2ban nftables; then
                    err "Fail2ban 安装失败。"
                    return 1
                fi
                ;;
            redhat)
                if command -v dnf >/dev/null 2>&1; then
                    dnf_bounded "$PACKAGE_INSTALL_TIMEOUT" install -y fail2ban nftables || { err "Fail2ban 安装失败。"; return 1; }
                else
                    yum_bounded "$PACKAGE_INSTALL_TIMEOUT" install -y fail2ban nftables || { err "Fail2ban 安装失败。"; return 1; }
                fi
                ;;
            *)
                err "未识别系统类型，无法自动安装 Fail2ban。"
                return 1
                ;;
        esac
    else
        info "Fail2ban 已安装，正在检查服务与 SSH 防护配置..."
    fi

    if ! fail2ban_installed; then
        err "Fail2ban 未安装成功，请检查软件源或网络。"
        return 1
    fi
    ensure_fail2ban_nftables_dependency || return 1

    ensure_fail2ban_service_running || {
        err "无法启动 Fail2ban 或设置开机自启。"
        return 1
    }

    info "正在按 SSH 当前生效端口配置 Fail2ban..."
    sync_fail2ban_sshd_port || {
        err "Fail2ban SSH 配置或重启失败。"
        return 1
    }

    if ! fail2ban_service_is_enabled ||
        [ "$(fail2ban_service_state)" != "运行中" ] ||
        [ "$(fail2ban_sshd_state)" != "已启用" ]; then
        err "Fail2ban 未达到预期状态，请检查服务日志和 SSH 端口配置。"
        return 1
    fi
    if ! mark_change_applied FAIL2BAN_SSHD; then
        err "Fail2ban 已启用，但无法记录可恢复状态；变更清单已保留供重试。"
        return 1
    fi

    info "Fail2ban 已安装，SSH 防护已启用，端口：$(ssh_effective_ports_csv)"
}

# ==============================================================================
# 6. 主机防火墙：端口发现、nftables、Docker 转发、回滚与菜单
# ==============================================================================
normalize_port_csv() {
    local input="${1:-}" item
    local -a items normalized_items=()

    [ -n "$input" ] || return 0
    IFS=',' read -ra items <<< "$input"
    for item in "${items[@]}"; do
        item="$(normalize_port_decimal "$item")" || return 1
        normalized_items+=("$item")
    done
    # 旧状态文件可能保存过带前导零的端口；读取时统一迁移成 nftables 使用的十进制形式。
    printf '%s\n' "${normalized_items[@]}" | sort -n -u | paste -sd, -
}

csv_contains_port() {
    local csv="${1:-}" port="$2"
    case ",$csv," in
        *",$port,"*) return 0 ;;
        *) return 1 ;;
    esac
}

csv_add_port() {
    local csv="${1:-}" port="$2"
    if [ -n "$csv" ]; then
        normalize_port_csv "$csv,$port"
    else
        normalize_port_csv "$port"
    fi
}

csv_remove_port() {
    local csv="${1:-}" port="$2" item
    local result=""
    local -a items

    [ -n "$csv" ] || return 0
    IFS=',' read -ra items <<< "$csv"
    for item in "${items[@]}"; do
        [ "$item" = "$port" ] && continue
        if [ -n "$result" ]; then result="$result,$item"; else result="$item"; fi
    done
    normalize_port_csv "$result"
}

merge_port_csv() {
    local result="" csv
    for csv in "$@"; do
        [ -n "$csv" ] || continue
        if [ -n "$result" ]; then result="$result,$csv"; else result="$csv"; fi
    done
    normalize_port_csv "$result"
}

subtract_port_csv() {
    local result="${1:-}" excluded="${2:-}" port
    local IFS=,

    result="$(normalize_port_csv "$result")" || return 1
    excluded="$(normalize_port_csv "$excluded")" || return 1
    [ -n "$excluded" ] || { printf '%s\n' "$result"; return 0; }
    for port in $excluded; do
        result="$(csv_remove_port "$result" "$port")" || return 1
    done
    printf '%s\n' "$result"
}

port_csv_is_subset() {
    local required="${1:-}" available="${2:-}" port
    local IFS=,

    [ -n "$required" ] || return 0
    for port in $required; do
        csv_contains_port "$available" "$port" || return 1
    done
}

firewall_write_ssh_safe_snapshot() {
    local source="$1" dest="$2" ssh_ports="$3" existing_tcp formatted tmp

    [ -f "$source" ] && [ ! -L "$source" ] || return 1
    ssh_ports="$(normalize_port_csv "$ssh_ports")" || return 1
    [ -n "$ssh_ports" ] || return 1
    existing_tcp="$(awk '
        /^[[:space:]]*chain[[:space:]]+input[[:space:]]*\{/ { in_input=1; next }
        in_input && /^[[:space:]]*\}/ { exit }
        in_input && $0 !~ /meta nfproto/ { print }
    ' "$source" | firewall_ports_from_nft_chain tcp)" || return 1
    if port_csv_is_subset "$ssh_ports" "$existing_tcp"; then
        [ "$source" = "$dest" ] || cp -a "$source" "$dest"
        return $?
    fi

    formatted="$(printf '%s' "$ssh_ports" | sed 's/,/, /g')"
    tmp="$(mktemp "$(dirname "$dest")/.firewall-ssh-safe.XXXXXX")" || return 1
    if ! awk -v ports="$formatted" '
        /^[[:space:]]*chain[[:space:]]+input[[:space:]]*\{/ { in_input=1 }
        in_input && /^[[:space:]]*\}/ {
            print "        tcp dport { " ports " } accept"
            inserted=1
            in_input=0
        }
        { print }
        END { if (!inserted) exit 1 }
    ' "$source" > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$dest"
}

firewall_state_file_is_secure() {
    local owner mode

    [ -f "$FIREWALL_STATE_FILE" ] && [ ! -L "$FIREWALL_STATE_FILE" ] || return 1
    owner="$(stat -c '%u' "$FIREWALL_STATE_FILE" 2>/dev/null)" || return 1
    mode="$(stat -c '%a' "$FIREWALL_STATE_FILE" 2>/dev/null)" || return 1
    [ "$owner" = "0" ] || return 1
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 8#077) == 0 ))
}

firewall_managed_file_is_secure() {
    local path="$1" owner mode
    [ -f "$path" ] && [ ! -L "$path" ] || return 1
    owner="$(stat -c '%u' "$path" 2>/dev/null)" || return 1
    mode="$(stat -c '%a' "$path" 2>/dev/null)" || return 1
    [ "$owner" = "0" ] || return 1
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 8#077) == 0 ))
}

firewall_load_state() {
    local key value tcp="" udp=""

    FW_EXTRA_TCP=""
    FW_EXTRA_UDP=""
    [ -e "$FIREWALL_STATE_FILE" ] || return 0
    firewall_state_file_is_secure || {
        err "防火墙状态文件不安全，已拒绝读取：$FIREWALL_STATE_FILE"
        return 1
    }

    while IFS='=' read -r key value || [ -n "$key" ]; do
        case "$key" in
            EXTRA_TCP_PORTS) tcp="$value" ;;
            EXTRA_UDP_PORTS) udp="$value" ;;
            "") ;;
            *)
                err "防火墙状态文件包含未知字段：$key"
                return 1
                ;;
        esac
    done < "$FIREWALL_STATE_FILE"

    [[ "$tcp" =~ ^$|^[0-9]+(,[0-9]+)*$ ]] || return 1
    [[ "$udp" =~ ^$|^[0-9]+(,[0-9]+)*$ ]] || return 1
    FW_EXTRA_TCP="$(normalize_port_csv "$tcp")" || return 1
    FW_EXTRA_UDP="$(normalize_port_csv "$udp")" || return 1
}

firewall_write_state_file() {
    local dest="$1"
    {
        printf 'EXTRA_TCP_PORTS=%s\n' "$FW_EXTRA_TCP"
        printf 'EXTRA_UDP_PORTS=%s\n' "$FW_EXTRA_UDP"
    } > "$dest"
}

firewall_install_managed_file() {
    local source="$1" target="$2" mode="$3" target_dir tmp

    [ ! -L "$target" ] || {
        err "目标文件是符号链接，已拒绝覆盖：$target"
        return 1
    }
    target_dir="$(dirname "$target")"
    mkdir -p "$target_dir" || return 1
    tmp="$(mktemp "$target_dir/.vpsbox-firewall.XXXXXX")" || return 1
    if ! cp "$source" "$tmp" ||
        ! chown root:root "$tmp" ||
        ! chmod "$mode" "$tmp" ||
        ! mv -f "$tmp" "$target"; then
        rm -f "$tmp"
        return 1
    fi
}

firewall_runtime_enabled() {
    command -v nft >/dev/null 2>&1 &&
        nft list table inet vpsbox >/dev/null 2>&1 &&
        nft list chain inet vpsbox input >/dev/null 2>&1
}

firewall_persistence_enabled() {
    if is_systemd; then
        systemctl is-enabled --quiet "$FIREWALL_SERVICE_NAME" 2>/dev/null
    elif [ "$OS" = "alpine" ]; then
        [ -e "$FIREWALL_OPENRC_RUNLEVELS_DIR/default/$FIREWALL_SERVICE_NAME" ] ||
            [ -L "$FIREWALL_OPENRC_RUNLEVELS_DIR/default/$FIREWALL_SERVICE_NAME" ]
    else
        return 1
    fi
}

firewall_service_active() {
    if is_systemd; then
        systemctl is-active --quiet "$FIREWALL_SERVICE_NAME" 2>/dev/null
    elif [ "$OS" = "alpine" ] && command -v rc-service >/dev/null 2>&1; then
        rc-service "$FIREWALL_SERVICE_NAME" status >/dev/null 2>&1
    else
        return 1
    fi
}

firewall_snapshot_runtime_state() {
    local output_var="$1" table_file="$2"
    local state tables

    if nft list table inet vpsbox > "$table_file" 2>/dev/null; then
        state="present"
    else
        rm -f "$table_file" || return 1
        tables="$(nft list tables 2>/dev/null)" || return 1
        if awk '
            $1 == "table" && $2 == "inet" && $3 == "vpsbox" {
                found=1
            }
            END { exit !found }
        ' <<< "$tables"; then
            return 1
        fi
        state="absent"
    fi
    printf -v "$output_var" '%s' "$state"
}

firewall_snapshot_persistence_state() {
    local output_var="$1"
    local state probe

    if is_systemd; then
        if probe="$(systemctl is-enabled "$FIREWALL_SERVICE_NAME" 2>/dev/null)"; then
            case "$probe" in
                enabled|enabled-runtime|linked|linked-runtime|alias)
                    state="enabled"
                    ;;
                *) return 1 ;;
            esac
        else
            case "$probe" in
                disabled|not-found) state="disabled" ;;
                *) return 1 ;;
            esac
        fi
    elif [ "$OS" = "alpine" ]; then
        [ -d "$FIREWALL_OPENRC_RUNLEVELS_DIR/default" ] || return 1
        if [ -e "$FIREWALL_OPENRC_RUNLEVELS_DIR/default/$FIREWALL_SERVICE_NAME" ] ||
            [ -L "$FIREWALL_OPENRC_RUNLEVELS_DIR/default/$FIREWALL_SERVICE_NAME" ]; then
            state="enabled"
        else
            state="disabled"
        fi
    else
        return 1
    fi
    printf -v "$output_var" '%s' "$state"
}

firewall_snapshot_service_state() {
    local output_var="$1"
    local state status probe

    if is_systemd; then
        if probe="$(systemctl is-active "$FIREWALL_SERVICE_NAME" 2>/dev/null)"; then
            case "$probe" in
                active|reloading) state="active" ;;
                *) return 1 ;;
            esac
        else
            case "$probe" in
                inactive|failed|unknown) state="inactive" ;;
                *) return 1 ;;
            esac
        fi
    elif [ "$OS" = "alpine" ]; then
        command -v rc-service >/dev/null 2>&1 || return 1
        if probe="$(rc-service "$FIREWALL_SERVICE_NAME" status 2>/dev/null)"; then
            state="active"
        else
            status=$?
            [ "$status" -eq 3 ] || return 1
            state="inactive"
        fi
    else
        return 1
    fi
    printf -v "$output_var" '%s' "$state"
}

firewall_control_plane_present() {
    firewall_runtime_enabled ||
        [ -e "$FIREWALL_CONFIG" ] ||
        [ -e "$FIREWALL_SYSTEMD_UNIT" ] ||
        [ -e "$FIREWALL_OPENRC_SERVICE" ] ||
        firewall_persistence_enabled ||
        firewall_service_active
}

firewall_artifacts_present() {
    firewall_control_plane_present || [ -e "$FIREWALL_STATE_FILE" ]
}

firewall_install_state() {
    command -v nft >/dev/null 2>&1 && echo "已安装" || echo "未安装"
}

firewall_runtime_state() {
    if firewall_runtime_enabled; then
        echo "运行中"
    elif [ -f "$FIREWALL_CONFIG" ]; then
        echo "配置存在但未运行"
    elif [ -e "$FIREWALL_SYSTEMD_UNIT" ] ||
        [ -e "$FIREWALL_OPENRC_SERVICE" ] ||
        firewall_persistence_enabled || firewall_service_active; then
        echo "状态不完整"
    else
        echo "未启用"
    fi
}

firewall_persistence_state() {
    firewall_persistence_enabled && echo "已启用" || echo "未启用"
}

firewall_native_service_enabled() {
    if is_systemd; then
        systemctl is-enabled --quiet nftables 2>/dev/null ||
            systemctl is-active --quiet nftables 2>/dev/null
    elif [ "$OS" = "alpine" ]; then
        [ -e /etc/runlevels/default/nftables ] ||
            [ -L /etc/runlevels/default/nftables ] ||
            { command -v rc-service >/dev/null 2>&1 && rc-service nftables status >/dev/null 2>&1; }
    else
        return 1
    fi
}

firewall_openrc_service_enabled() {
    local service="$1" runlevels_dir="${2:-$FIREWALL_OPENRC_RUNLEVELS_DIR}" entry

    [ -n "$service" ] && [ -d "$runlevels_dir" ] || return 1
    for entry in "$runlevels_dir"/*/"$service"; do
        [ -e "$entry" ] || [ -L "$entry" ] || continue
        return 0
    done
    return 1
}

firewall_firewalld_enabled_or_active() {
    if is_systemd; then
        systemctl is-active --quiet firewalld 2>/dev/null ||
            systemctl is-enabled --quiet firewalld 2>/dev/null
    elif [ "$OS" = "alpine" ]; then
        { command -v rc-service >/dev/null 2>&1 &&
            rc-service firewalld status >/dev/null 2>&1; } ||
            firewall_openrc_service_enabled firewalld
    else
        return 1
    fi
}

firewall_check_conflicts() {
    if command -v ufw >/dev/null 2>&1 &&
        ufw status 2>/dev/null | grep -Eqi '^Status:[[:space:]]*active'; then
        err "检测到 UFW 正在运行。为避免规则链冲突，请先停用 UFW 后再启用主机防火墙。"
        return 1
    fi
    if firewall_firewalld_enabled_or_active; then
        err "检测到 firewalld 已启用或正在运行。为避免重启后出现规则链冲突，请先停用 firewalld。"
        return 1
    fi
    if firewall_native_service_enabled; then
        err "检测到系统 nftables 服务已启用或正在运行。"
        err "vpsbox 不会覆盖现有 /etc/nftables.conf；请先迁移或停用原服务。"
        return 1
    fi
    if command -v nft >/dev/null 2>&1 &&
        nft list table inet vpsbox >/dev/null 2>&1 &&
        { [ ! -f "$FIREWALL_CONFIG" ] || [ ! -f "$FIREWALL_STATE_FILE" ]; }; then
        err "检测到非完整 vpsbox 状态的 inet vpsbox 表，已拒绝覆盖。"
        return 1
    fi
}

ensure_nftables() {
    if command -v nft >/dev/null 2>&1 &&
        command -v jq >/dev/null 2>&1 &&
        command -v ss >/dev/null 2>&1 &&
        command -v timeout >/dev/null 2>&1; then
        return 0
    fi
    detect_os
    info "正在安装主机防火墙所需的 nftables、jq、iproute2 与 coreutils..."
    case "$OS" in
        debian)
            export DEBIAN_FRONTEND=noninteractive
            apt_get_bounded "$PACKAGE_UPDATE_TIMEOUT" update -y || return 1
            apt_get_bounded "$PACKAGE_INSTALL_TIMEOUT" install -y nftables jq iproute2 coreutils || return 1
            ;;
        alpine)
            apk_bounded "$PACKAGE_UPDATE_TIMEOUT" update || return 1
            apk_bounded "$PACKAGE_INSTALL_TIMEOUT" add --no-cache nftables jq iproute2 coreutils || return 1
            ;;
        *)
            err "主机防火墙目前仅支持 Debian/Ubuntu 与 Alpine。"
            return 1
            ;;
    esac
    command -v nft >/dev/null 2>&1 &&
        command -v jq >/dev/null 2>&1 &&
        command -v ss >/dev/null 2>&1 &&
        command -v timeout >/dev/null 2>&1 || {
            err "主机防火墙依赖安装后仍不完整。"
            return 1
        }
}

is_valid_interface_name() {
    local name="${1:-}"
    [ -n "$name" ] && [ "${#name}" -le 15 ] &&
        [[ "$name" =~ ^[A-Za-z0-9_.:-]+$ ]]
}

normalize_interface_csv() {
    local input="${1:-}" item
    local -a items

    [ -n "$input" ] || return 0
    IFS=',' read -ra items <<< "$input"
    for item in "${items[@]}"; do
        is_valid_interface_name "$item" || return 1
    done
    printf '%s\n' "${items[@]}" | sort -u | paste -sd, -
}

interface_csv_add() {
    local csv="${1:-}" name="$2"
    if [ -n "$csv" ]; then
        normalize_interface_csv "$csv,$name"
    else
        normalize_interface_csv "$name"
    fi
}

firewall_docker_available() {
    command -v docker >/dev/null 2>&1 &&
        docker_with_timeout info >/dev/null 2>&1
}

docker_with_timeout() {
    command -v docker >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1 || return 1
    timeout 15 docker "$@"
}

docker_daemon_process_present() {
    local comm_file comm_name

    for comm_file in /proc/[0-9]*/comm; do
        [ -r "$comm_file" ] || continue
        read -r comm_name < "$comm_file" || continue
        [ "$comm_name" = "dockerd" ] && return 0
    done
    return 1
}

docker_single_daemon_pid() {
    local comm_file comm_name pid="" count=0

    for comm_file in /proc/[0-9]*/comm; do
        [ -r "$comm_file" ] || continue
        read -r comm_name < "$comm_file" || continue
        [ "$comm_name" = "dockerd" ] || continue
        pid="${comm_file%/comm}"
        pid="${pid##*/}"
        count=$((count + 1))
    done
    [ "$count" -eq 1 ] || return 1
    printf '%s\n' "$pid"
}

firewall_docker_config_has_unsafe_mode() {
    local config_file="$1"

    jq -e '
        (.["allow-direct-routing"] == true) or
        (.iptables == false) or
        (.ip6tables == false) or
        ([.["default-network-opts"] // {} | .. | objects | to_entries[]? |
            select(
                (
                    ((.key | endswith("gateway_mode_ipv4")) or (.key | endswith("gateway_mode_ipv6"))) and
                    ((.value == "routed") or (.value == "nat-unprotected"))
                ) or
                ((.key | endswith("trusted_host_interfaces")) and ((.value // "") != ""))
            )
        ] | length > 0)
    ' "$config_file" >/dev/null 2>&1
}

docker_go_bool_value() {
    local value="${1,,}"

    case "$value" in
        1|t|true) printf '%s\n' true ;;
        0|f|false) printf '%s\n' false ;;
        *) return 1 ;;
    esac
}

timestamp_strictly_after() {
    local candidate="$1" reference="$2"

    [[ "$candidate" =~ ^[0-9]+$ ]] && [[ "$reference" =~ ^[0-9]+$ ]] &&
        [ "$candidate" -gt "$reference" ]
}

firewall_validate_docker_daemon_mode() {
    local comm_file comm_name cmdline_file="" config_file="/etc/docker/daemon.json"
    local config_view config_parent arg value parsed_bool i daemon_found=0 config_explicit=0
    local daemon_pid="" clock_ticks boot_epoch start_ticks daemon_start_epoch config_mtime config_ctime
    local -a daemon_argv

    for comm_file in /proc/[0-9]*/comm; do
        [ -r "$comm_file" ] || continue
        read -r comm_name < "$comm_file" || continue
        [ "$comm_name" = "dockerd" ] || continue
        cmdline_file="${comm_file%/comm}/cmdline"
        [ -r "$cmdline_file" ] || continue
        [ "$daemon_found" -eq 0 ] || {
            err "检测到多个 dockerd 进程，无法确认当前 socket 对应的 daemon 参数。"
            return 1
        }
        mapfile -d '' -t daemon_argv < "$cmdline_file"
        daemon_pid="${comm_file%/comm}"
        daemon_pid="${daemon_pid##*/}"
        daemon_found=1
    done
    [ "$daemon_found" -eq 1 ] || {
        err "无法确认本机 dockerd 进程参数，已拒绝更新防火墙。"
        return 1
    }

    for ((i = 0; i < ${#daemon_argv[@]}; i++)); do
        arg="${daemon_argv[$i]}"
        case "$arg" in
            --config-file=*) config_file="${arg#*=}"; config_explicit=1 ;;
            --config-file)
                i=$((i + 1))
                [ "$i" -lt "${#daemon_argv[@]}" ] || {
                    err "dockerd --config-file 缺少路径。"
                    return 1
                }
                config_file="${daemon_argv[$i]}"
                config_explicit=1
                ;;
            --allow-direct-routing)
                err "检测到 Docker direct routing，已拒绝更新防火墙。"
                return 1
                ;;
            --allow-direct-routing=*)
                value="${arg#*=}"
                parsed_bool="$(docker_go_bool_value "$value")" || {
                    err "dockerd 返回了无法识别的 allow-direct-routing 布尔值：$value"
                    return 1
                }
                if [ "$parsed_bool" = "true" ]; then
                    err "检测到 Docker direct routing，已拒绝更新防火墙。"
                    return 1
                fi
                ;;
            --iptables=*|--ip6tables=*)
                value="${arg#*=}"
                parsed_bool="$(docker_go_bool_value "$value")" || {
                    err "dockerd 返回了无法识别的防火墙布尔值：$value"
                    return 1
                }
                if [ "$parsed_bool" = "false" ]; then
                    err "检测到 Docker 已关闭 iptables/ip6tables 管理，无法可靠守卫发布端口。"
                    return 1
                fi
                ;;
            --default-network-opt=*)
                value="${arg#*=}"
                case "$value" in
                    *gateway_mode_ipv4=routed*|*gateway_mode_ipv6=routed*|\
                    *gateway_mode_ipv4=nat-unprotected*|*gateway_mode_ipv6=nat-unprotected*|\
                    *trusted_host_interfaces=*)
                        err "dockerd 默认网络参数启用了直连/非保护模式，已拒绝更新防火墙。"
                        return 1
                        ;;
                esac
                ;;
            --default-network-opt)
                i=$((i + 1))
                [ "$i" -lt "${#daemon_argv[@]}" ] || {
                    err "dockerd --default-network-opt 缺少参数。"
                    return 1
                }
                value="${daemon_argv[$i]}"
                case "$value" in
                    *gateway_mode_ipv4=routed*|*gateway_mode_ipv6=routed*|\
                    *gateway_mode_ipv4=nat-unprotected*|*gateway_mode_ipv6=nat-unprotected*|\
                    *trusted_host_interfaces=*)
                        err "dockerd 默认网络参数启用了直连/非保护模式，已拒绝更新防火墙。"
                        return 1
                        ;;
                esac
                ;;
        esac
    done

    case "$config_file" in
        /*) ;;
        *)
            err "dockerd 配置文件不是绝对路径，无法安全检查：$config_file"
            return 1
            ;;
    esac
    start_ticks="$(awk '{ print $22; exit }' "/proc/$daemon_pid/stat" 2>/dev/null || true)"
    [[ "$start_ticks" =~ ^[0-9]+$ ]] || {
        err "无法读取 dockerd 进程启动标识，已拒绝更新防火墙。"
        return 1
    }
    FW_DOCKER_DAEMON_PID="$daemon_pid"
    FW_DOCKER_DAEMON_START_TICKS="$start_ticks"
    clock_ticks="$(getconf CLK_TCK 2>/dev/null)" || clock_ticks=""
    [[ "$clock_ticks" =~ ^[1-9][0-9]*$ ]] || clock_ticks=100
    boot_epoch="$(awk '$1 == "btime" { print $2; exit }' /proc/stat 2>/dev/null)"
    if ! [[ "$boot_epoch" =~ ^[0-9]+$ ]]; then
        err "无法确认 dockerd 启动时间，已拒绝根据磁盘配置更新防火墙。"
        return 1
    fi
    daemon_start_epoch=$((boot_epoch + start_ticks / clock_ticks))

    config_view="/proc/$daemon_pid/root$config_file"
    if [ ! -e "$config_view" ]; then
        if [ "$config_explicit" -eq 1 ]; then
            err "dockerd 显式配置文件在当前 daemon 视图中不存在：$config_file"
            return 1
        fi
        config_parent="${config_view%/*}"
        if [ -e "$config_parent" ]; then
            [ -d "$config_parent" ] && [ ! -L "$config_parent" ] || {
                err "dockerd 默认配置目录状态异常，无法确认启动时配置：${config_file%/*}"
                return 1
            }
            config_mtime="$(stat -c '%Y' "$config_parent" 2>/dev/null)" || return 1
            config_ctime="$(stat -c '%Z' "$config_parent" 2>/dev/null)" || return 1
            # /proc 的 btime 与 stat 时间只有秒级；同一秒无法证明目录变更晚于 daemon，
            # 仅在时间戳严格更晚时拒绝，避免刚启动 Docker 时产生同秒误报。
            if timestamp_strictly_after "$config_mtime" "$daemon_start_epoch" ||
                timestamp_strictly_after "$config_ctime" "$daemon_start_epoch"; then
                err "dockerd 默认配置文件当前不存在，但配置目录在 daemon 启动后发生过变化。"
                err "无法排除配置已被删除；请重启 Docker 后再更新 vpsbox 防火墙。"
                return 1
            fi
        fi
        return 0
    fi
    [ ! -L "$config_view" ] || {
        err "dockerd 配置文件是符号链接，无法确认运行时加载的文件版本：$config_file"
        return 1
    }
    command -v jq >/dev/null 2>&1 || {
        err "dockerd 使用了配置文件，但缺少 jq，无法安全检查：$config_file"
        return 1
    }
    [ -r "$config_view" ] && [ -f "$config_view" ] || {
        err "无法安全读取 dockerd 配置文件：$config_file"
        return 1
    }
    config_mtime="$(stat -c '%Y' "$config_view" 2>/dev/null)" || return 1
    config_ctime="$(stat -c '%Z' "$config_view" 2>/dev/null)" || return 1
    if ! [[ "$config_mtime" =~ ^[0-9]+$ ]] || ! [[ "$config_ctime" =~ ^[0-9]+$ ]]; then
        err "无法确认 dockerd 配置文件时间，已拒绝更新防火墙。"
        return 1
    fi
    # 同秒时间戳在现有内核接口精度下无法排序，只有严格晚于启动秒才视为未加载变更。
    if timestamp_strictly_after "$config_mtime" "$daemon_start_epoch" ||
        timestamp_strictly_after "$config_ctime" "$daemon_start_epoch"; then
        err "dockerd 配置文件在 daemon 启动后发生过变化，当前运行态可能尚未加载。"
        err "请重启 Docker 并确认容器正常后，再更新 vpsbox 防火墙。"
        return 1
    fi
    jq empty "$config_view" >/dev/null 2>&1 || {
        err "dockerd 配置文件不是有效 JSON：$config_file"
        return 1
    }
    if firewall_docker_config_has_unsafe_mode "$config_view"; then
        err "dockerd 配置启用了 direct routing、非保护网关或关闭了防火墙管理。"
        return 1
    fi
}

firewall_docker_daemon_identity_unchanged() {
    local expected_pid="${FW_DOCKER_DAEMON_PID:-}" expected_ticks="${FW_DOCKER_DAEMON_START_TICKS:-}"
    local comm_file comm_name pid="" count=0 current_ticks

    [[ "$expected_pid" =~ ^[0-9]+$ ]] && [[ "$expected_ticks" =~ ^[0-9]+$ ]] || return 1
    for comm_file in /proc/[0-9]*/comm; do
        [ -r "$comm_file" ] || continue
        read -r comm_name < "$comm_file" || continue
        [ "$comm_name" = "dockerd" ] || continue
        pid="${comm_file%/comm}"
        pid="${pid##*/}"
        count=$((count + 1))
    done
    [ "$count" -eq 1 ] && [ "$pid" = "$expected_pid" ] || return 1
    current_ticks="$(awk '{ print $22; exit }' "/proc/$pid/stat" 2>/dev/null)" || return 1
    [ "$current_ticks" = "$expected_ticks" ]
}

is_wildcard_listen_addr() {
    local addr="${1,,}"

    case "$addr" in
        ""|'*'|0.0.0.0|::|0:0:0:0:0:0:0:0) return 0 ;;
        *) return 1 ;;
    esac
}

firewall_record_docker_public_binding() {
    local protocol="$1" host_ip="${2,,}" port="$3"

    is_valid_port "$port" || return 1
    is_loopback_listen_addr "$host_ip" && return 0
    case "$host_ip" in
        "")
            err "Docker 发布地址尚未确定，已拒绝把端口 $port 视为公网端口。"
            return 1
            ;;
        0.0.0.0|'*')
            case "$protocol" in
                tcp) FW_DOCKER_PUBLIC4_TCP="$(csv_add_port "$FW_DOCKER_PUBLIC4_TCP" "$port")" ;;
                udp) FW_DOCKER_PUBLIC4_UDP="$(csv_add_port "$FW_DOCKER_PUBLIC4_UDP" "$port")" ;;
                *) return 1 ;;
            esac
            ;;
        ::|0:0:0:0:0:0:0:0)
            case "$protocol" in
                tcp) FW_DOCKER_PUBLIC6_TCP="$(csv_add_port "$FW_DOCKER_PUBLIC6_TCP" "$port")" ;;
                udp) FW_DOCKER_PUBLIC6_UDP="$(csv_add_port "$FW_DOCKER_PUBLIC6_UDP" "$port")" ;;
                *) return 1 ;;
            esac
            ;;
        *)
            err "Docker 发布到特定非回环地址 $host_ip:$port，当前无法保留地址级访问边界。"
            err "请改用通配地址/回环地址，或关闭 vpsbox 防火墙后自行管理规则。"
            return 1
            ;;
    esac
    FW_DOCKER_PUBLIC_TCP="$(merge_port_csv "$FW_DOCKER_PUBLIC4_TCP" "$FW_DOCKER_PUBLIC6_TCP")" || return 1
    FW_DOCKER_PUBLIC_UDP="$(merge_port_csv "$FW_DOCKER_PUBLIC4_UDP" "$FW_DOCKER_PUBLIC6_UDP")" || return 1
}

firewall_detect_docker_proxy_ports() {
    local family output mapping protocol listen_address host port

    FW_DOCKER_PROXY4_TCP=""
    FW_DOCKER_PROXY4_UDP=""
    FW_DOCKER_PROXY6_TCP=""
    FW_DOCKER_PROXY6_UDP=""
    command -v ss >/dev/null 2>&1 || {
        err "缺少 ss，无法检查 docker-proxy 监听。"
        return 1
    }
    for family in 4 6; do
        output="$(ss -H "-$family" -lntup 2>/dev/null)" || {
            err "无法读取 IPv$family docker-proxy 监听状态。"
            return 1
        }
        while IFS='|' read -r protocol listen_address; do
            [ -n "$protocol" ] || continue
            port="${listen_address##*:}"
            host="${listen_address%:*}"
            host="${host#[}"
            host="${host%]}"
            is_valid_port "$port" || {
                err "docker-proxy 返回了无效监听端口：$listen_address"
                return 1
            }
            is_loopback_listen_addr "$host" && continue
            is_wildcard_listen_addr "$host" || {
                err "docker-proxy 监听特定地址 $listen_address，无法用端口级规则保持地址边界。"
                return 1
            }
            case "$protocol:$family" in
                tcp:4)
                    csv_contains_port "$FW_DOCKER_PUBLIC4_TCP" "$port" || return 1
                    FW_DOCKER_PROXY4_TCP="$(csv_add_port "$FW_DOCKER_PROXY4_TCP" "$port")"
                    ;;
                udp:4)
                    csv_contains_port "$FW_DOCKER_PUBLIC4_UDP" "$port" || return 1
                    FW_DOCKER_PROXY4_UDP="$(csv_add_port "$FW_DOCKER_PROXY4_UDP" "$port")"
                    ;;
                tcp:6)
                    csv_contains_port "$FW_DOCKER_PUBLIC6_TCP" "$port" || return 1
                    FW_DOCKER_PROXY6_TCP="$(csv_add_port "$FW_DOCKER_PROXY6_TCP" "$port")"
                    ;;
                udp:6)
                    csv_contains_port "$FW_DOCKER_PUBLIC6_UDP" "$port" || return 1
                    FW_DOCKER_PROXY6_UDP="$(csv_add_port "$FW_DOCKER_PROXY6_UDP" "$port")"
                    ;;
            esac
        done < <(printf '%s\n' "$output" | awk '/docker-proxy/ {
            address=$5
            if ($1 == "tcp" || $1 == "udp") print $1 "|" address
        }')
    done
}

firewall_detect_docker_ports() {
    local container mode mapping container_port protocol binding host_ip host_port remainder
    local network_id network_name network_driver bridge_name swarm_state
    local docker_host context endpoint effective_endpoint security_options container_list network_list
    local bindings running publish_all port_mappings network_data gateway_v4 gateway_v6 trusted_interfaces
    local container_dynamic container_unresolved_fixed
    local connected_count

    FW_DOCKER_TCP=""
    FW_DOCKER_UDP=""
    FW_DOCKER_PUBLIC_TCP=""
    FW_DOCKER_PUBLIC_UDP=""
    FW_DOCKER_PUBLIC4_TCP=""
    FW_DOCKER_PUBLIC4_UDP=""
    FW_DOCKER_PUBLIC6_TCP=""
    FW_DOCKER_PUBLIC6_UDP=""
    FW_DOCKER_PROXY4_TCP=""
    FW_DOCKER_PROXY4_UDP=""
    FW_DOCKER_PROXY6_TCP=""
    FW_DOCKER_PROXY6_UDP=""
    FW_DOCKER_BRIDGES=""
    FW_DOCKER_DAEMON_PID=""
    FW_DOCKER_DAEMON_START_TICKS=""
    FW_DOCKER_HOST_NETWORK=0
    FW_DOCKER_DYNAMIC_PORT=0
    FW_DOCKER_DIRECT_NETWORK=0
    FW_DOCKER_CUSTOM_BRIDGE=0

    if ! command -v docker >/dev/null 2>&1; then
        docker_daemon_process_present || return 0
        err "检测到 dockerd 进程但缺少 docker CLI，无法可靠检查发布端口。"
        return 1
    fi

    docker_host="${DOCKER_HOST:-}"
    case "$docker_host" in
        ""|unix:///*) ;;
        *)
            err "检测到远程 DOCKER_HOST，已拒绝用远端容器信息配置本机防火墙。"
            return 1
            ;;
    esac
    context="$(docker_with_timeout context show 2>/dev/null)" || {
        err "无法确认 Docker 当前 context，已拒绝更新防火墙。"
        return 1
    }
    endpoint="$(docker_with_timeout context inspect --format '{{.Endpoints.docker.Host}}' "$context" 2>/dev/null)" || {
        err "无法读取 Docker context 连接地址，已拒绝更新防火墙。"
        return 1
    }
    effective_endpoint="${docker_host:-$endpoint}"
    case "$effective_endpoint" in
        unix:///var/run/docker.sock|unix:///run/docker.sock) ;;
        *)
            err "Docker 当前连接不是受支持的本机 rootful socket：$effective_endpoint"
            return 1
            ;;
    esac

    if ! firewall_docker_available; then
        if docker_daemon_process_present; then
            err "检测到 dockerd 正在运行，但无法读取 Docker daemon；已拒绝忽略可能存在的发布端口。"
            return 1
        fi
        return 2
    fi

    security_options="$(docker_with_timeout info --format '{{json .SecurityOptions}}' 2>/dev/null)" || {
        err "无法读取 Docker 安全模式，已拒绝更新防火墙。"
        return 1
    }
    if [[ "$security_options" == *rootless* ]]; then
        err "检测到 rootless Docker；当前防火墙仅支持本机 rootful Docker。"
        return 1
    fi

    swarm_state="$(docker_with_timeout info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null)" || {
        err "无法读取 Docker Swarm 状态，已拒绝更新防火墙。"
        return 1
    }
    if [ "$swarm_state" != "inactive" ]; then
        err "Docker Swarm 状态不是 inactive（当前：$swarm_state），已拒绝更新防火墙。"
        return 1
    fi

    firewall_validate_docker_daemon_mode || return 1

    container_list="$(docker_with_timeout ps -aq 2>/dev/null)" || {
        err "Docker 容器枚举失败，已拒绝生成不完整的防火墙规则。"
        return 1
    }

    while IFS= read -r container; do
        [ -n "$container" ] || continue
        container_dynamic=0
        container_unresolved_fixed=0
        mode="$(docker_with_timeout inspect --format '{{.HostConfig.NetworkMode}}' "$container" 2>/dev/null)" || {
            err "无法读取 Docker 容器网络模式：$container"
            return 1
        }
        if [ "$mode" = "host" ]; then
            FW_DOCKER_HOST_NETWORK=1
            continue
        fi
        publish_all="$(docker_with_timeout inspect --format '{{.HostConfig.PublishAllPorts}}' "$container" 2>/dev/null)" || {
            err "无法读取 Docker 容器随机发布设置：$container"
            return 1
        }
        case "$publish_all" in
            true) container_dynamic=1 ;;
            false) ;;
            *)
                err "Docker 返回了无效的随机发布状态：$publish_all"
                return 1
                ;;
        esac
        bindings="$(docker_with_timeout inspect --format \
            '{{range $port, $bindings := .HostConfig.PortBindings}}{{range $bindings}}{{printf "%s|%s|%s\n" $port .HostIp .HostPort}}{{end}}{{end}}' \
            "$container" 2>/dev/null)" || {
            err "无法读取 Docker 容器端口映射：$container"
            return 1
        }
        while IFS= read -r mapping; do
            [ -n "$mapping" ] || continue
            container_port="${mapping%%|*}"
            remainder="${mapping#*|}"
            host_ip="${remainder%%|*}"
            host_port="${remainder##*|}"
            protocol="${container_port##*/}"
            if [ -z "$host_port" ] || [ "$host_port" = "0" ]; then
                container_dynamic=1
                continue
            fi
            is_valid_port "$host_port" || {
                err "Docker 返回了无效宿主机端口：$host_port"
                return 1
            }
            case "$protocol" in
                tcp)
                    FW_DOCKER_TCP="$(csv_add_port "$FW_DOCKER_TCP" "$host_port")"
                    [ -n "$host_ip" ] || container_unresolved_fixed=1
                    ;;
                udp)
                    FW_DOCKER_UDP="$(csv_add_port "$FW_DOCKER_UDP" "$host_port")"
                    [ -n "$host_ip" ] || container_unresolved_fixed=1
                    ;;
                *)
                    err "检测到不受支持的 Docker 发布协议：$protocol"
                    return 1
                    ;;
            esac
            if [ -n "$host_ip" ]; then
                firewall_record_docker_public_binding "$protocol" "$host_ip" "$host_port" || return 1
            fi
        done <<< "$bindings"

        running="$(docker_with_timeout inspect --format '{{.State.Running}}' "$container" 2>/dev/null)" || {
            err "无法读取 Docker 容器运行状态：$container"
            return 1
        }
        if [ "$running" != "true" ]; then
            if [ "$container_unresolved_fixed" = "1" ]; then
                err "Docker 容器 $container 使用固定宿主机端口但未指定绑定地址；容器停止时无法确认实际绑定范围。"
                info "请启动该容器后重试，或为端口映射显式指定宿主机绑定地址。"
                return 1
            fi
            [ "$container_dynamic" = "0" ] || FW_DOCKER_DYNAMIC_PORT=1
            continue
        fi
        port_mappings="$(docker_with_timeout port "$container" 2>/dev/null)" || {
            err "无法读取运行中 Docker 容器的实际发布端口：$container"
            return 1
        }
        if [ -n "$port_mappings" ]; then
            container_dynamic=0
            container_unresolved_fixed=0
        fi
        while IFS= read -r mapping; do
            [ -n "$mapping" ] || continue
            container_port="${mapping%% -> *}"
            protocol="${container_port##*/}"
            binding="${mapping#* -> }"
            host_port="${binding##*:}"
            host_ip="${binding%:*}"
            host_ip="${host_ip#[}"
            host_ip="${host_ip%]}"
            is_valid_port "$host_port" || {
                err "Docker 返回了无效运行端口：$host_port"
                return 1
            }
            case "$protocol" in
                tcp)
                    FW_DOCKER_TCP="$(csv_add_port "$FW_DOCKER_TCP" "$host_port")"
                    firewall_record_docker_public_binding tcp "$host_ip" "$host_port" || return 1
                    ;;
                udp)
                    FW_DOCKER_UDP="$(csv_add_port "$FW_DOCKER_UDP" "$host_port")"
                    firewall_record_docker_public_binding udp "$host_ip" "$host_port" || return 1
                    ;;
                *)
                    err "检测到不受支持的 Docker 运行协议：$protocol"
                    return 1
                    ;;
            esac
        done <<< "$port_mappings"
        if [ "$container_unresolved_fixed" = "1" ]; then
            err "无法确认 Docker 容器 $container 固定端口的实际绑定地址。"
            return 1
        fi
        [ "$container_dynamic" = "0" ] || FW_DOCKER_DYNAMIC_PORT=1
    done <<< "$container_list"

    network_list="$(docker_with_timeout network ls --format '{{.ID}}|{{.Name}}|{{.Driver}}' 2>/dev/null)" || {
        err "Docker 网络枚举失败，已拒绝生成不完整的防火墙规则。"
        return 1
    }
    while IFS='|' read -r network_id network_name network_driver; do
        [ -n "$network_id" ] || continue
        network_data="$(docker_with_timeout network inspect --format \
            '{{index .Options "com.docker.network.bridge.name"}}|{{index .Options "com.docker.network.bridge.gateway_mode_ipv4"}}|{{index .Options "com.docker.network.bridge.gateway_mode_ipv6"}}|{{index .Options "com.docker.network.bridge.trusted_host_interfaces"}}|{{len .Containers}}' \
            "$network_id" 2>/dev/null)" || {
            err "无法读取 Docker 网络配置：$network_name"
            return 1
        }
        IFS='|' read -r bridge_name gateway_v4 gateway_v6 trusted_interfaces connected_count <<< "$network_data"
        case "$network_driver" in
            bridge)
                case "$gateway_v4,$gateway_v6" in
                    *routed*|*nat-unprotected*)
                        err "Docker 网络 $network_name 使用 $gateway_v4/$gateway_v6 直连模式，已拒绝更新。"
                        return 1
                        ;;
                esac
                if [ -n "$trusted_interfaces" ] && [ "$trusted_interfaces" != "<no value>" ]; then
                    err "Docker 网络 $network_name 允许可信接口直连，已拒绝更新。"
                    return 1
                fi
                if [ -z "$bridge_name" ] || [ "$bridge_name" = "<no value>" ]; then
                    if [ "$network_name" = "bridge" ]; then
                        bridge_name="docker0"
                    else
                        bridge_name="br-${network_id:0:12}"
                    fi
                fi
                is_valid_interface_name "$bridge_name" || {
                    err "Docker 返回了无效 bridge 接口名：$bridge_name"
                    return 1
                }
                [ -d "/sys/class/net/$bridge_name/bridge" ] || {
                    err "Docker 返回的接口不是可用 Linux bridge：$bridge_name"
                    return 1
                }
                case "$bridge_name" in
                    docker0|br-*) ;;
                    *) FW_DOCKER_CUSTOM_BRIDGE=1 ;;
                esac
                FW_DOCKER_BRIDGES="$(interface_csv_add "$FW_DOCKER_BRIDGES" "$bridge_name")"
                ;;
            host|none|null) ;;
            *)
                if [[ "$connected_count" =~ ^[1-9][0-9]*$ ]]; then
                    FW_DOCKER_DIRECT_NETWORK=1
                    err "Docker 网络 $network_name 使用 $network_driver 且连接了容器，当前无法安全接管。"
                    return 1
                fi
                ;;
        esac
    done <<< "$network_list"

    firewall_detect_docker_proxy_ports || {
        err "docker-proxy 监听与 Docker 发布端口不一致，已拒绝更新防火墙。"
        return 1
    }
    firewall_docker_daemon_identity_unchanged || {
        err "Docker daemon 在检查期间发生变化，已拒绝使用可能不一致的端口结果。"
        return 1
    }

}

docker_reserved_ports_csv() {
    local protocols="${1:-both}"
    local docker_host context endpoint effective_endpoint container container_list
    local bindings mapping host_port binding_protocol running port_mappings swarm_state control_available
    local service service_list published_ports port reserved=""
    local daemon_pid daemon_start_ticks current_pid current_start_ticks

    case "$protocols" in
        tcp|udp|both) ;;
        *) return 2 ;;
    esac

    if ! command -v docker >/dev/null 2>&1; then
        docker_daemon_process_present || return 0
        err "检测到 dockerd 进程但缺少 docker CLI，无法可靠检查保留端口。"
        return 1
    fi
    docker_host="${DOCKER_HOST:-}"
    case "$docker_host" in
        ""|unix:///*) ;;
        *)
            err "检测到远程 DOCKER_HOST，无法据此判断本机 Docker 保留端口。"
            return 1
            ;;
    esac
    context="$(docker_with_timeout context show 2>/dev/null)" || return 1
    endpoint="$(docker_with_timeout context inspect --format '{{.Endpoints.docker.Host}}' "$context" 2>/dev/null)" || return 1
    effective_endpoint="${docker_host:-$endpoint}"
    case "$effective_endpoint" in
        unix:///*) ;;
        *)
            err "Docker 当前连接不是本机 Unix socket，无法可靠检查保留端口。"
            return 1
            ;;
    esac
    docker_with_timeout info >/dev/null 2>&1 || {
        err "检测到 Docker 命令，但无法连接本机 Docker daemon。"
        return 1
    }
    daemon_pid="$(docker_single_daemon_pid)" || {
        err "无法确认唯一的本机 dockerd 进程，已拒绝使用不完整的保留端口结果。"
        return 1
    }
    daemon_start_ticks="$(awk '{ print $22; exit }' "/proc/$daemon_pid/stat" 2>/dev/null || true)"
    [[ "$daemon_start_ticks" =~ ^[0-9]+$ ]] || return 1

    container_list="$(docker_with_timeout ps -aq 2>/dev/null)" || return 1
    while IFS= read -r container; do
        [ -n "$container" ] || continue
        bindings="$(docker_with_timeout inspect --format \
            '{{range $port, $bindings := .HostConfig.PortBindings}}{{range $bindings}}{{printf "%s|%s|%s\n" $port .HostIp .HostPort}}{{end}}{{end}}' \
            "$container" 2>/dev/null)" || return 1
        while IFS= read -r mapping; do
            [ -n "$mapping" ] || continue
            binding_protocol="${mapping%%|*}"
            binding_protocol="${binding_protocol##*/}"
            case "$binding_protocol" in
                tcp|udp) ;;
                *) continue ;;
            esac
            host_port="${mapping##*|}"
            [ -z "$host_port" ] || [ "$host_port" = "0" ] || {
                is_valid_port "$host_port" || return 1
                if [ "$protocols" = "both" ] || [ "$protocols" = "$binding_protocol" ]; then
                    reserved="$(csv_add_port "$reserved" "$host_port")" || return 1
                fi
            }
        done <<< "$bindings"

        running="$(docker_with_timeout inspect --format '{{.State.Running}}' "$container" 2>/dev/null)" || return 1
        [ "$running" = "true" ] || continue
        port_mappings="$(docker_with_timeout port "$container" 2>/dev/null)" || return 1
        while IFS= read -r mapping; do
            [ -n "$mapping" ] || continue
            binding_protocol="${mapping%% ->*}"
            binding_protocol="${binding_protocol##*/}"
            case "$binding_protocol" in
                tcp|udp) ;;
                *) continue ;;
            esac
            host_port="${mapping##*:}"
            is_valid_port "$host_port" || return 1
            if [ "$protocols" = "both" ] || [ "$protocols" = "$binding_protocol" ]; then
                reserved="$(csv_add_port "$reserved" "$host_port")" || return 1
            fi
        done <<< "$port_mappings"
    done <<< "$container_list"

    swarm_state="$(docker_with_timeout info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null)" || return 1
    if [ "$swarm_state" != "inactive" ]; then
        [ "$swarm_state" = "active" ] || {
            err "Docker Swarm 状态为 $swarm_state，无法可靠枚举保留端口。"
            return 1
        }
        control_available="$(docker_with_timeout info --format '{{.Swarm.ControlAvailable}}' 2>/dev/null)" || return 1
        [ "$control_available" = "true" ] || {
            err "当前 Swarm 节点不是 manager，无法可靠枚举服务发布端口。"
            return 1
        }
        service_list="$(docker_with_timeout service ls -q 2>/dev/null)" || return 1
        while IFS= read -r service; do
            [ -n "$service" ] || continue
            published_ports="$(docker_with_timeout service inspect --format \
                '{{range .Endpoint.Spec.Ports}}{{printf "%d|%s\n" .PublishedPort .Protocol}}{{end}}' \
                "$service" 2>/dev/null)" || return 1
            while IFS='|' read -r port binding_protocol; do
                [ -n "$port" ] || continue
                case "$binding_protocol" in
                    tcp|udp) ;;
                    *) continue ;;
                esac
                is_valid_port "$port" || return 1
                if [ "$protocols" = "both" ] || [ "$protocols" = "$binding_protocol" ]; then
                    reserved="$(csv_add_port "$reserved" "$port")" || return 1
                fi
            done <<< "$published_ports"
        done <<< "$service_list"
    fi
    current_pid="$(docker_single_daemon_pid)" || return 1
    current_start_ticks="$(awk '{ print $22; exit }' "/proc/$current_pid/stat" 2>/dev/null || true)"
    [ "$current_pid" = "$daemon_pid" ] && [ "$current_start_ticks" = "$daemon_start_ticks" ] || {
        err "Docker daemon 在端口枚举期间发生变化，已拒绝使用结果。"
        return 1
    }
    printf '%s\n' "$reserved"
}

docker_reserved_ports_for_port_choice() {
    local protocols="${1:-both}" result

    if result="$(docker_reserved_ports_csv "$protocols")"; then
        printf '%s\n' "$result"
        return 0
    fi
    if firewall_control_plane_present; then
        [ -z "$result" ] || printf '%s\n' "$result" >&2
        return 1
    fi
    warn "无法可靠读取 Docker 已发布端口；当前未启用 vpsbox 防火墙，本次仅检查系统实际监听端口。Docker 恢复后请确认没有端口冲突。" >&2
    printf '\n'
}

firewall_detect_public_listeners() {
    local records scope protocol port _addr _proc_name

    FW_PUBLIC_TCP=""
    FW_PUBLIC_UDP=""
    records="$(collect_listening_sockets)" || return 1
    while IFS='|' read -r scope protocol port _addr _proc_name; do
        [ "$scope" = "public" ] || continue
        case "$protocol" in
            tcp) FW_PUBLIC_TCP="$(csv_add_port "$FW_PUBLIC_TCP" "$port")" || return 1 ;;
            udp) FW_PUBLIC_UDP="$(csv_add_port "$FW_PUBLIC_UDP" "$port")" || return 1 ;;
        esac
    done <<< "$records"
}

firewall_detect_managed_ports() {
    local ssh_configured_ports ssh_listening_ports protocol label

    ssh_configured_ports="$(ssh_effective_ports_csv 2>/dev/null || true)"
    [ -n "$ssh_configured_ports" ] || {
        err "无法读取 SSH 当前实际生效端口，已拒绝启用防火墙。"
        return 1
    }
    ssh_listening_ports="$(ssh_listening_ports_csv 2>/dev/null)" || {
        err "无法可靠读取 SSH 实际监听端口，已拒绝更新防火墙。"
        return 1
    }
    FW_SSH_PORTS="$(merge_port_csv "$ssh_configured_ports" "$ssh_listening_ports")" || return 1

    FW_NODE_TCP=""
    FW_NODE_UDP=""
    require_valid_node_state_if_present || return 1
    for protocol in vless ss; do
        protocol_visible_exists "$protocol" || continue
        label="$(node_protocol_display_name "$protocol")" || return 1
        load_protocol_state "$protocol" || return 1
        is_valid_port "${PORT:-}" || {
            err "$label 节点端口无效，已拒绝生成防火墙规则。"
            return 1
        }
        FW_NODE_TCP="$(csv_add_port "$FW_NODE_TCP" "$PORT")" || return 1
        if [ "$protocol" = "ss" ]; then
            FW_NODE_UDP="$(csv_add_port "$FW_NODE_UDP" "$PORT")" || return 1
        fi
    done
}

firewall_detect_docker_ports_for_update() {
    local phase="${1:-strict}" status

    if firewall_detect_docker_ports; then
        return 0
    else
        status=$?
    fi
    [ "$status" -eq 2 ] || return "$status"

    case "$phase" in
        initial)
            warn "检测到本机 Docker 客户端，但 Docker daemon 当前未运行，无法枚举发布端口。"
            if confirm_default_no "本次忽略 Docker 并继续更新防火墙？"; then
                FW_DOCKER_STOPPED_IGNORED=1
                warn "本次将按没有 Docker 发布端口处理；启动 Docker 后必须再次执行 [1] 一键开启/更新防火墙。"
                return 0
            fi
            info "已取消，未修改防火墙。"
            return 3
            ;;
        confirmed)
            if [ "${FW_DOCKER_STOPPED_IGNORED:-0}" = "1" ]; then
                return 0
            fi
            err "Docker daemon 在确认期间停止，端口状态已变化；请重新执行防火墙更新。"
            return 1
            ;;
        strict)
            err "检测到本机 Docker 客户端，但 Docker daemon 未运行，无法可靠核对发布端口。"
            return 1
            ;;
        *) return 2 ;;
    esac
}

firewall_detect_allowed_ports() {
    local docker_phase="${1:-strict}" known_tcp known_udp

    firewall_detect_managed_ports || return 1
    firewall_detect_docker_ports_for_update "$docker_phase" || return $?
    firewall_detect_public_listeners || return 1
    known_tcp="$(merge_port_csv "$FW_SSH_PORTS" "$FW_NODE_TCP" "$FW_DOCKER_PUBLIC_TCP" "$FW_EXTRA_TCP")" || return 1
    known_udp="$(merge_port_csv "$FW_NODE_UDP" "$FW_DOCKER_PUBLIC_UDP" "$FW_EXTRA_UDP")" || return 1
    FW_OTHER_PUBLIC_TCP="$(subtract_port_csv "$FW_PUBLIC_TCP" "$known_tcp")" || return 1
    FW_OTHER_PUBLIC_UDP="$(subtract_port_csv "$FW_PUBLIC_UDP" "$known_udp")" || return 1
    FW_ALLOWED_TCP="$(merge_port_csv "$FW_SSH_PORTS" "$FW_NODE_TCP" "$FW_PUBLIC_TCP" "$FW_EXTRA_TCP")" || return 1
    FW_ALLOWED_UDP="$(merge_port_csv "$FW_NODE_UDP" "$FW_PUBLIC_UDP" "$FW_EXTRA_UDP")" || return 1
}

firewall_write_config() {
    local dest="$1" tcp_ports udp_ports
    local docker4_tcp docker4_udp docker6_tcp docker6_udp
    local docker_bridges docker_bridge_elements extra_tcp extra_udp
    local proxy4_tcp proxy4_udp proxy6_tcp proxy6_udp

    tcp_ports="$(printf '%s' "$FW_ALLOWED_TCP" | sed 's/,/, /g')"
    udp_ports="$(printf '%s' "$FW_ALLOWED_UDP" | sed 's/,/, /g')"
    docker4_tcp="$(normalize_port_csv "$FW_DOCKER_PUBLIC4_TCP")" || return 1
    docker4_udp="$(normalize_port_csv "$FW_DOCKER_PUBLIC4_UDP")" || return 1
    docker6_tcp="$(normalize_port_csv "$FW_DOCKER_PUBLIC6_TCP")" || return 1
    docker6_udp="$(normalize_port_csv "$FW_DOCKER_PUBLIC6_UDP")" || return 1
    extra_tcp="$(normalize_port_csv "$FW_EXTRA_TCP")" || return 1
    extra_udp="$(normalize_port_csv "$FW_EXTRA_UDP")" || return 1
    docker_bridges="$(normalize_interface_csv "$FW_DOCKER_BRIDGES")" || return 1
    if [ -n "$docker4_tcp$docker4_udp$docker6_tcp$docker6_udp" ] && [ -z "$docker_bridges" ]; then
        err "检测到 Docker 公开端口，但没有可验证的 Docker bridge。"
        return 1
    fi
    if [ -n "$docker_bridges" ]; then
        docker_bridge_elements="$(printf '%s\n' "$docker_bridges" | awk -F, '{
            for (i = 1; i <= NF; i++) printf "%s\"%s\"", (i == 1 ? "" : ", "), $i
        }')"
    else
        docker_bridge_elements=""
    fi
    proxy4_tcp="$(printf '%s' "$FW_DOCKER_PROXY4_TCP" | sed 's/,/, /g')"
    proxy4_udp="$(printf '%s' "$FW_DOCKER_PROXY4_UDP" | sed 's/,/, /g')"
    proxy6_tcp="$(printf '%s' "$FW_DOCKER_PROXY6_TCP" | sed 's/,/, /g')"
    proxy6_udp="$(printf '%s' "$FW_DOCKER_PROXY6_UDP" | sed 's/,/, /g')"
    # --- BEGIN GENERATED TEMPLATE: nftables managed table ---
    cat > "$dest" <<'EOF'
# Managed by vpsbox. Replace only the dedicated table; never flush the global ruleset.
delete table inet vpsbox

table inet vpsbox {
EOF
    if [ -n "$docker_bridge_elements" ]; then
        printf '    set docker_bridge_ifaces {\n        type ifname\n        elements = { %s }\n    }\n\n' \
            "$docker_bridge_elements" >> "$dest"
    fi
    if [ -n "$docker4_tcp" ]; then
        printf '    set docker4_tcp_ports {\n        type inet_service\n        elements = { %s }\n    }\n\n' \
            "$(printf '%s' "$docker4_tcp" | sed 's/,/, /g')" >> "$dest"
    fi
    if [ -n "$docker4_udp" ]; then
        printf '    set docker4_udp_ports {\n        type inet_service\n        elements = { %s }\n    }\n\n' \
            "$(printf '%s' "$docker4_udp" | sed 's/,/, /g')" >> "$dest"
    fi
    if [ -n "$docker6_tcp" ]; then
        printf '    set docker6_tcp_ports {\n        type inet_service\n        elements = { %s }\n    }\n\n' \
            "$(printf '%s' "$docker6_tcp" | sed 's/,/, /g')" >> "$dest"
    fi
    if [ -n "$docker6_udp" ]; then
        printf '    set docker6_udp_ports {\n        type inet_service\n        elements = { %s }\n    }\n\n' \
            "$(printf '%s' "$docker6_udp" | sed 's/,/, /g')" >> "$dest"
    fi
    if [ -n "$extra_tcp" ]; then
        printf '    set extra_tcp_dnat_ports {\n        type inet_service\n        elements = { %s }\n    }\n\n' \
            "$(printf '%s' "$extra_tcp" | sed 's/,/, /g')" >> "$dest"
    fi
    if [ -n "$extra_udp" ]; then
        printf '    set extra_udp_dnat_ports {\n        type inet_service\n        elements = { %s }\n    }\n\n' \
            "$(printf '%s' "$extra_udp" | sed 's/,/, /g')" >> "$dest"
    fi

    cat >> "$dest" <<'EOF'
    chain input {
        type filter hook input priority filter; policy drop;

        ct state invalid drop
        ct state established,related accept
        iifname "lo" accept

        ip protocol icmp accept
        meta l4proto ipv6-icmp accept

        meta nfproto ipv4 udp sport 67 udp dport 68 accept
        meta nfproto ipv6 udp sport 547 udp dport 546 accept
EOF
    [ -n "$tcp_ports" ] && printf '        tcp dport { %s } accept\n' "$tcp_ports" >> "$dest"
    [ -n "$udp_ports" ] && printf '        udp dport { %s } accept\n' "$udp_ports" >> "$dest"
    [ -n "$proxy4_tcp" ] && printf '        meta nfproto ipv4 tcp dport { %s } accept\n' "$proxy4_tcp" >> "$dest"
    [ -n "$proxy4_udp" ] && printf '        meta nfproto ipv4 udp dport { %s } accept\n' "$proxy4_udp" >> "$dest"
    [ -n "$proxy6_tcp" ] && printf '        meta nfproto ipv6 tcp dport { %s } accept\n' "$proxy6_tcp" >> "$dest"
    [ -n "$proxy6_udp" ] && printf '        meta nfproto ipv6 udp dport { %s } accept\n' "$proxy6_udp" >> "$dest"
    cat >> "$dest" <<'EOF'
    }
EOF
    cat >> "$dest" <<'EOF'

    chain docker_port_guard {
EOF
    if [ -n "$extra_tcp" ]; then
        printf '        meta l4proto tcp ct original proto-dst @extra_tcp_dnat_ports accept\n' >> "$dest"
    fi
    if [ -n "$docker4_tcp" ]; then
        printf '        meta nfproto ipv4 meta l4proto tcp oifname @docker_bridge_ifaces ct original proto-dst @docker4_tcp_ports accept\n' >> "$dest"
    fi
    if [ -n "$docker6_tcp" ]; then
        printf '        meta nfproto ipv6 meta l4proto tcp oifname @docker_bridge_ifaces ct original proto-dst @docker6_tcp_ports accept\n' >> "$dest"
    fi
    printf '        meta l4proto tcp drop\n' >> "$dest"
    if [ -n "$extra_udp" ]; then
        printf '        meta l4proto udp ct original proto-dst @extra_udp_dnat_ports accept\n' >> "$dest"
    fi
    if [ -n "$docker4_udp" ]; then
        printf '        meta nfproto ipv4 meta l4proto udp oifname @docker_bridge_ifaces ct original proto-dst @docker4_udp_ports accept\n' >> "$dest"
    fi
    if [ -n "$docker6_udp" ]; then
        printf '        meta nfproto ipv6 meta l4proto udp oifname @docker_bridge_ifaces ct original proto-dst @docker6_udp_ports accept\n' >> "$dest"
    fi
    printf '        meta l4proto udp drop\n' >> "$dest"
    printf '        drop\n' >> "$dest"
    cat >> "$dest" <<'EOF'
    }

    chain docker_forward {
        type filter hook forward priority -1; policy accept;

        ct state established,related accept
EOF
    if [ -n "$docker_bridge_elements" ]; then
        printf '        iifname @docker_bridge_ifaces accept\n' >> "$dest"
    fi
    printf '        ct direction original ct status dnat jump docker_port_guard\n' >> "$dest"
    if [ -n "$docker_bridge_elements" ]; then
        printf '        oifname @docker_bridge_ifaces drop\n' >> "$dest"
    fi
    cat >> "$dest" <<'EOF'
    }
EOF
    cat >> "$dest" <<'EOF'
}
EOF
    # --- END GENERATED TEMPLATE: nftables managed table ---
}

firewall_write_service_definition() {
    local dest="$1" nft_path
    nft_path="$(command -v nft)" || return 1

    if is_systemd; then
        # --- BEGIN GENERATED TEMPLATE: vpsbox firewall systemd unit ---
        cat > "$dest" <<EOF
[Unit]
Description=vpsbox host firewall
DefaultDependencies=no
Wants=network-pre.target
Before=network-pre.target shutdown.target
Conflicts=shutdown.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=-$nft_path add table inet vpsbox
ExecStart=$nft_path -f $FIREWALL_CONFIG
ExecStop=-$nft_path delete table inet vpsbox

[Install]
WantedBy=sysinit.target
EOF
        # --- END GENERATED TEMPLATE: vpsbox firewall systemd unit ---
    elif [ "$OS" = "alpine" ] && command -v rc-update >/dev/null 2>&1; then
        # --- BEGIN GENERATED TEMPLATE: vpsbox firewall OpenRC service ---
        cat > "$dest" <<EOF
#!/sbin/openrc-run
description="vpsbox host firewall"

depend() {
    need localmount
    before net
}

start() {
    ebegin "Loading vpsbox host firewall"
    $nft_path add table inet vpsbox >/dev/null 2>&1 || true
    $nft_path -f $FIREWALL_CONFIG
    eend \$?
}

stop() {
    ebegin "Removing vpsbox host firewall"
    $nft_path delete table inet vpsbox >/dev/null 2>&1 || true
    eend 0
}
EOF
        # --- END GENERATED TEMPLATE: vpsbox firewall OpenRC service ---
    else
        err "未检测到受支持的 systemd/OpenRC 服务管理器。"
        return 1
    fi
}

firewall_snapshot_file() {
    local dir="$1" name="$2" path="$3"
    if [ -e "$path" ]; then
        [ ! -L "$path" ] || return 1
        cp -a "$path" "$dir/$name" || return 1
        : > "$dir/$name.present"
    fi
}

firewall_prepare_rollback_store() {
    [ ! -L "$VPSBOX_STATE_DIR" ] && [ ! -L "$FIREWALL_ROLLBACK_DIR" ] || {
        err "防火墙回滚目录包含符号链接，已拒绝使用。"
        return 1
    }
    mkdir -p "$FIREWALL_ROLLBACK_DIR" || return 1
    chown root:root "$FIREWALL_ROLLBACK_DIR" || return 1
    chmod 700 "$FIREWALL_ROLLBACK_DIR" || return 1
}

firewall_rollback_dir_valid() {
    local dir="${1:-}"

    case "$dir" in
        "$FIREWALL_ROLLBACK_DIR"/firewall-rollback.*) ;;
        *) return 1 ;;
    esac
    [ -d "$dir" ] && [ ! -L "$dir" ]
}

firewall_watchdog_cmdline_matches() {
    local dir="$1" pid="$2"
    local -a args=()

    firewall_rollback_dir_valid "$dir" || return 1
    is_pid "$pid" && [ "$pid" -gt 1 ] && [ "$pid" -ne "$$" ] || return 1
    process_alive "$pid" || return 1
    process_is_zombie "$pid" && return 1
    [ -r "/proc/$pid/cmdline" ] || return 1
    mapfile -d '' -t args < "/proc/$pid/cmdline" 2>/dev/null || true
    [ "${#args[@]}" -eq 2 ] || return 1
    case "${args[0]}" in
        sh|*/sh) ;;
        *) return 1 ;;
    esac
    [ "${args[1]}" = "$dir/rollback.sh" ]
}

firewall_watchdog_process_matches() {
    local dir="$1" pid="$2" expected_start="$3"

    firewall_watchdog_cmdline_matches "$dir" "$pid" || return 1
    [ "$(process_start_ticks "$pid" 2>/dev/null || true)" = "$expected_start" ]
}

firewall_watchdog_identity_matches() {
    local dir="$1" pid="$2"
    local path recorded_pid recorded_start recorded_boot current_start current_boot

    firewall_rollback_dir_valid "$dir" || return 2
    is_pid "$pid" && [ "$pid" -gt 1 ] && [ "$pid" -ne "$$" ] || return 2
    for path in "$dir/watchdog.pid" "$dir/watchdog.start" "$dir/watchdog.boot"; do
        [ -f "$path" ] && [ ! -L "$path" ] || return 2
    done
    IFS= read -r recorded_pid < "$dir/watchdog.pid" || return 2
    IFS= read -r recorded_start < "$dir/watchdog.start" || return 2
    IFS= read -r recorded_boot < "$dir/watchdog.boot" || return 2
    [ "$recorded_pid" = "$pid" ] && [[ "$recorded_start" =~ ^[0-9]+$ ]] &&
        [ -n "$recorded_boot" ] || return 2

    process_alive "$pid" || return 1
    process_is_zombie "$pid" && return 1
    current_start="$(process_start_ticks "$pid" || true)"
    current_boot="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"
    [ -n "$current_start" ] && [ "$recorded_start" = "$current_start" ] || return 1
    [ -n "$current_boot" ] && [ "$recorded_boot" = "$current_boot" ] || return 1
    firewall_watchdog_cmdline_matches "$dir" "$pid" || return 1
}

firewall_sleep_process_matches() {
    local pid="$1" expected_start="$2"
    local -a args=()

    process_alive "$pid" || return 1
    process_is_zombie "$pid" && return 1
    [ "$(process_start_ticks "$pid" 2>/dev/null || true)" = "$expected_start" ] || return 1
    [ -r "/proc/$pid/cmdline" ] || return 1
    mapfile -d '' -t args < "/proc/$pid/cmdline" 2>/dev/null || true
    [ "${#args[@]}" -eq 2 ] || return 1
    case "${args[0]}" in
        sleep|*/sleep) ;;
        *) return 1 ;;
    esac
    # 当前 watchdog 只使用 sleep 1 轮询，精确限制参数以避免误杀其他 sleep。
    [ "${args[1]}" = "1" ]
}

firewall_watchdog_sleep_records() {
    local parent="$1" child start children

    children="$(cat "/proc/$parent/task/$parent/children" 2>/dev/null || true)"
    for child in $children; do
        is_pid "$child" || continue
        start="$(process_start_ticks "$child" 2>/dev/null || true)"
        [[ "$start" =~ ^[0-9]+$ ]] || continue
        firewall_sleep_process_matches "$child" "$start" || continue
        printf '%s:%s\n' "$child" "$start"
    done
}

firewall_stop_recorded_sleeps() {
    local records="$1" record pid start i failed=0

    for record in $records; do
        pid="${record%%:*}"
        start="${record#*:}"
        firewall_sleep_process_matches "$pid" "$start" || continue
        kill -TERM "$pid" 2>/dev/null || true
        for i in {1..10}; do
            firewall_sleep_process_matches "$pid" "$start" || break
            sleep 0.1
        done
        if firewall_sleep_process_matches "$pid" "$start"; then
            kill -KILL "$pid" 2>/dev/null || true
        fi
        for i in {1..10}; do
            firewall_sleep_process_matches "$pid" "$start" || break
            sleep 0.1
        done
        firewall_sleep_process_matches "$pid" "$start" && failed=1
    done
    [ "$failed" -eq 0 ]
}

firewall_forget_watchdog_metadata() {
    local dir="$1"

    rm -f "$dir/watchdog.pid" "$dir/watchdog.start" "$dir/watchdog.boot"
}

firewall_wait_watchdog_exit() {
    local pid="$1" i

    for i in {1..20}; do
        if ! process_alive "$pid" || process_is_zombie "$pid"; then
            wait "$pid" 2>/dev/null || true
            return 0
        fi
        sleep 0.1
    done
    return 1
}

firewall_stop_verified_watchdog() {
    local dir="$1" pid="$2" start="$3" status sleep_records

    firewall_watchdog_process_matches "$dir" "$pid" "$start" || return 0
    sleep_records="$(firewall_watchdog_sleep_records "$pid")"
    if firewall_wait_watchdog_exit "$pid"; then
        firewall_stop_recorded_sleeps "$sleep_records"
        return $?
    fi

    firewall_stop_recorded_sleeps "$sleep_records" || status=1
    if firewall_wait_watchdog_exit "$pid"; then
        return "${status:-0}"
    fi
    firewall_watchdog_process_matches "$dir" "$pid" "$start" || return "${status:-0}"

    kill -TERM "$pid" 2>/dev/null || true
    if firewall_wait_watchdog_exit "$pid"; then
        return "${status:-0}"
    fi
    firewall_watchdog_process_matches "$dir" "$pid" "$start" || return "${status:-0}"

    kill -KILL "$pid" 2>/dev/null || true
    if firewall_wait_watchdog_exit "$pid"; then
        return "${status:-0}"
    fi
    return 1
}

firewall_find_watchdog_pids() {
    local dir="$1" proc pid

    for proc in /proc/[0-9]*; do
        [ -d "$proc" ] || continue
        pid="${proc##*/}"
        firewall_watchdog_cmdline_matches "$dir" "$pid" || continue
        printf '%s\n' "$pid"
    done
}

firewall_stop_rollback_watchdog() {
    local dir="$1" path pid start found_pid

    firewall_rollback_dir_valid "$dir" || return 1
    for path in "$dir/watchdog.pid" "$dir/watchdog.start" "$dir/watchdog.boot"; do
        [ ! -e "$path" ] || { [ -f "$path" ] && [ ! -L "$path" ]; } || {
            warn "防火墙回滚进程元数据路径不安全，已保留快照：$dir"
            return 1
        }
    done
    if [ -e "$dir/watchdog.pid" ]; then
        IFS= read -r pid < "$dir/watchdog.pid" || pid=""
        if is_pid "$pid" && [ "$pid" -gt 1 ] && [ "$pid" -ne "$$" ]; then
            # 当前版本分步写入 watchdog 元数据；中断后可能只留下 PID。
            # 缺少身份字段时必须再核对精确脚本命令行，避免 PID 复用导致误杀。
            if [ -e "$dir/watchdog.start" ] && [ -e "$dir/watchdog.boot" ]; then
                if firewall_watchdog_identity_matches "$dir" "$pid"; then
                    start="$(process_start_ticks "$pid")"
                fi
            fi
            if [ -z "${start:-}" ] && firewall_watchdog_cmdline_matches "$dir" "$pid"; then
                start="$(process_start_ticks "$pid" 2>/dev/null || true)"
            fi
            if [[ "${start:-}" =~ ^[0-9]+$ ]]; then
                firewall_stop_verified_watchdog "$dir" "$pid" "$start" || {
                    warn "防火墙回滚进程未能退出，快照已保留：$dir"
                    return 1
                }
            elif process_is_zombie "$pid"; then
                wait "$pid" 2>/dev/null || true
            fi
        else
            warn "防火墙回滚进程 PID 元数据无效，将按脚本路径安全扫描：$dir"
        fi
    fi

    # 收敛空 PID、陈旧 PID，以及当前版本在元数据落盘前中断的情况。
    # PID 文件仅作快速定位，最终只扫描精确 rollback.sh 命令行，既能收敛遗留 watchdog 又避免误杀。
    while IFS= read -r found_pid; do
        [ -n "$found_pid" ] || continue
        start="$(process_start_ticks "$found_pid" 2>/dev/null || true)"
        [[ "$start" =~ ^[0-9]+$ ]] || continue
        firewall_stop_verified_watchdog "$dir" "$found_pid" "$start" || {
            warn "防火墙回滚进程未能退出，快照已保留：$dir"
            return 1
        }
    done < <(firewall_find_watchdog_pids "$dir")
    firewall_forget_watchdog_metadata "$dir"
    return 0
}

firewall_cleanup_finished_rollback() {
    local dir="$1"

    firewall_rollback_dir_valid "$dir" || return 1
    [ -e "$dir/completed" ] || [ -e "$dir/rolled-back" ] || return 1
    firewall_stop_rollback_watchdog "$dir" || return 1
    [ "${ACTIVE_FIREWALL_ROLLBACK_DIR:-}" = "$dir" ] && ACTIVE_FIREWALL_ROLLBACK_DIR=""
    rm -rf -- "$dir"
}

firewall_additive_transaction_path() {
    printf '%s/firewall-additive\n' "$FIREWALL_ROLLBACK_DIR"
}

firewall_additive_transaction_dir_valid() {
    [ "${1:-}" = "$(firewall_additive_transaction_path)" ]
}

firewall_config_keeps_tcp_ports() {
    local config="$1" required="$2" actual

    required="$(normalize_port_csv "$required")" || return 1
    actual="$(firewall_config_direct_ports "$config" tcp)" || return 1
    port_csv_is_subset "$required" "$actual"
}

firewall_live_tcp_ports() {
    nft -nn list chain inet vpsbox input 2>/dev/null |
        firewall_ports_from_nft_chain tcp
}

firewall_additive_transaction_contents_valid() {
    local dir="$1" path old_tcp normalized marker_count=0

    [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
    [ "$(stat -c '%u:%g %a' "$dir" 2>/dev/null || true)" = "0:0 700" ] || return 1
    for path in config state old-tcp; do
        [ -f "$dir/$path" ] && [ ! -L "$dir/$path" ] || return 1
        [ "$(stat -c '%u:%g %a' "$dir/$path" 2>/dev/null || true)" = "0:0 600" ] || return 1
    done
    for path in pending committed runtime-active; do
        [ -e "$dir/$path" ] || continue
        [ -f "$dir/$path" ] && [ ! -L "$dir/$path" ] || return 1
        [ "$(stat -c '%u:%g %a' "$dir/$path" 2>/dev/null || true)" = "0:0 600" ] || return 1
    done
    [ -e "$dir/pending" ] && marker_count=$((marker_count + 1))
    [ -e "$dir/committed" ] && marker_count=$((marker_count + 1))
    [ "$marker_count" -ge 1 ] || return 1

    old_tcp="$(cat "$dir/old-tcp" 2>/dev/null)" || return 1
    [ -n "$old_tcp" ] || return 1
    normalized="$(normalize_port_csv "$old_tcp")" || return 1
    [ "$normalized" = "$old_tcp" ] || return 1
    firewall_config_keeps_tcp_ports "$dir/config" "$old_tcp"
}

firewall_remove_additive_transaction_dir() {
    local dir="${1:-$(firewall_additive_transaction_path)}"

    firewall_additive_transaction_dir_valid "$dir" || return 1
    [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
    rm -rf -- "$dir" || return 1
    sync_node_transaction_store
}

firewall_begin_additive_transaction() {
    local old_tcp="$1" was_runtime="$2" target build_dir path

    [ "$was_runtime" = "0" ] || [ "$was_runtime" = "1" ] || return 2
    old_tcp="$(normalize_port_csv "$old_tcp")" || return 1
    [ -n "$old_tcp" ] || return 1
    [ -z "${ACTIVE_FIREWALL_ADDITIVE_DIR:-}" ] &&
        [ -z "${ACTIVE_FIREWALL_ROLLBACK_DIR:-}" ] || return 1
    firewall_prepare_rollback_store || return 1
    target="$(firewall_additive_transaction_path)"
    [ ! -e "$target" ] && [ ! -L "$target" ] || {
        err "已有未完成的防火墙轻量事务，已拒绝覆盖：$target"
        return 1
    }

    build_dir="$(mktemp -d "$FIREWALL_ROLLBACK_DIR/.firewall-additive-build.XXXXXX")" || return 1
    chmod 700 "$build_dir" || { rm -rf -- "$build_dir"; return 1; }
    if ! cp -a -- "$FIREWALL_CONFIG" "$build_dir/config" ||
        ! cp -a -- "$FIREWALL_STATE_FILE" "$build_dir/state" ||
        ! printf '%s\n' "$old_tcp" >"$build_dir/old-tcp" ||
        ! : >"$build_dir/pending"; then
        rm -rf -- "$build_dir"
        return 1
    fi
    if [ "$was_runtime" = "1" ] && ! : >"$build_dir/runtime-active"; then
        rm -rf -- "$build_dir"
        return 1
    fi
    for path in config state old-tcp pending runtime-active; do
        [ -e "$build_dir/$path" ] || continue
        chown root:root "$build_dir/$path" && chmod 600 "$build_dir/$path" || {
            rm -rf -- "$build_dir"
            return 1
        }
    done
    chown root:root "$build_dir" || { rm -rf -- "$build_dir"; return 1; }
    firewall_additive_transaction_contents_valid "$build_dir" || {
        rm -rf -- "$build_dir"
        return 1
    }
    sync_node_transaction_store || { rm -rf -- "$build_dir"; return 1; }
    mv -- "$build_dir" "$target" || { rm -rf -- "$build_dir"; return 1; }
    ACTIVE_FIREWALL_ADDITIVE_DIR="$target"
    sync_node_transaction_store || return 1
    firewall_additive_transaction_contents_valid "$target"
}

firewall_mark_additive_transaction_committed() {
    local dir="${ACTIVE_FIREWALL_ADDITIVE_DIR:-$(firewall_additive_transaction_path)}"
    local tmp

    firewall_additive_transaction_dir_valid "$dir" || return 1
    firewall_additive_transaction_contents_valid "$dir" || return 1
    tmp="$(mktemp "$dir/.committed.XXXXXX")" || return 1
    if ! chown root:root "$tmp" || ! chmod 600 "$tmp" ||
        ! mv -f -- "$tmp" "$dir/committed"; then
        rm -f -- "$tmp"
        return 1
    fi
    sync_node_transaction_store
}

firewall_commit_additive_transaction() {
    local dir="${ACTIVE_FIREWALL_ADDITIVE_DIR:-}"

    firewall_additive_transaction_dir_valid "$dir" || return 1
    firewall_mark_additive_transaction_committed || return 1
    ACTIVE_FIREWALL_ADDITIVE_DIR=""
    if ! firewall_remove_additive_transaction_dir "$dir"; then
        warn "新增端口已提交，但轻量事务残留未能清理：$dir"
    fi
    return 0
}

firewall_restore_additive_transaction() {
    local dir="$1" old_tcp live_tcp failed=0

    firewall_additive_transaction_dir_valid "$dir" || return 1
    firewall_additive_transaction_contents_valid "$dir" || return 1
    [ ! -e "$dir/committed" ] || return 1
    old_tcp="$(cat "$dir/old-tcp")" || return 1

    firewall_install_managed_file "$dir/config" "$FIREWALL_CONFIG" 600 || failed=1
    firewall_install_managed_file "$dir/state" "$FIREWALL_STATE_FILE" 600 || failed=1
    if [ -e "$dir/runtime-active" ]; then
        firewall_apply_config_file "$dir/config" || failed=1
    fi
    cmp -s "$dir/config" "$FIREWALL_CONFIG" || failed=1
    cmp -s "$dir/state" "$FIREWALL_STATE_FILE" || failed=1
    firewall_config_keeps_tcp_ports "$FIREWALL_CONFIG" "$old_tcp" || failed=1
    if [ -e "$dir/runtime-active" ]; then
        live_tcp="$(firewall_live_tcp_ports)" || failed=1
        port_csv_is_subset "$old_tcp" "$live_tcp" || failed=1
    fi
    [ "$failed" -eq 0 ] || return 1
    # 先确保持久化旧配置和状态，再删除唯一的轻量事务备份。
    sync_node_transaction_store || return 1

    ACTIVE_FIREWALL_ADDITIVE_DIR=""
    firewall_remove_additive_transaction_dir "$dir"
}

firewall_recover_pending_additive_transaction() {
    local dir build_dir

    firewall_prepare_rollback_store || return 1
    for build_dir in "$FIREWALL_ROLLBACK_DIR"/.firewall-additive-build.*; do
        [ -e "$build_dir" ] || continue
        [ -d "$build_dir" ] && [ ! -L "$build_dir" ] || {
            err "检测到不安全的防火墙轻量事务构建目录：$build_dir"
            return 1
        }
        rm -rf -- "$build_dir" || return 1
    done

    dir="$(firewall_additive_transaction_path)"
    [ -e "$dir" ] || [ -L "$dir" ] || return 0
    firewall_additive_transaction_dir_valid "$dir" &&
        firewall_additive_transaction_contents_valid "$dir" || {
        err "防火墙轻量事务未通过完整性检查，已保留：$dir"
        return 1
    }
    if [ -e "$dir/committed" ]; then
        ACTIVE_FIREWALL_ADDITIVE_DIR=""
        firewall_remove_additive_transaction_dir "$dir"
        return
    fi
    warn "检测到未完成的新增端口操作，正在恢复原防火墙配置。"
    ACTIVE_FIREWALL_ADDITIVE_DIR="$dir"
    firewall_restore_additive_transaction "$dir" || {
        err "新增端口的旧配置未能完整恢复，轻量事务已保留：$dir"
        return 1
    }
}

firewall_recover_pending_rollbacks() {
    local dir decision owner

    firewall_prepare_rollback_store || return 1
    firewall_recover_pending_additive_transaction || return 1
    for dir in "$FIREWALL_ROLLBACK_DIR"/.firewall-rollback-build.*; do
        [ -e "$dir" ] || continue
        if [ ! -d "$dir" ] || [ -L "$dir" ]; then
            err "检测到不安全的防火墙回滚构建目录：$dir"
            return 1
        fi
        rm -rf "$dir" || return 1
    done
    for dir in "$FIREWALL_ROLLBACK_DIR"/firewall-rollback.*; do
        [ -e "$dir" ] || continue
        if [ ! -d "$dir" ] || [ -L "$dir" ]; then
            err "检测到不安全的防火墙回滚目录：$dir"
            return 1
        fi
        if [ -e "$dir/completed" ] || [ -e "$dir/rolled-back" ]; then
            if ! firewall_cleanup_finished_rollback "$dir"; then
                err "已完成的防火墙快照清理失败，已拒绝开始新的防火墙操作：$dir"
                return 1
            fi
            continue
        fi
        decision="$(cat "$dir/decision" 2>/dev/null || true)"
        owner=0
        [ "$decision" = "commit" ] && owner=1
        warn "检测到未完成的防火墙操作，正在先恢复快照：$dir"
        if ! firewall_restore_snapshot_now "$dir" "$owner"; then
            err "旧防火墙快照尚未恢复，已拒绝开始新的防火墙操作。"
            return 1
        fi
    done
}

firewall_create_rollback_snapshot() {
    local output_var="$1" ssh_ports="$2" dir build_dir final_dir suffix nft_path
    local runtime_state persistence_state service_state

    if [ -n "${ACTIVE_FIREWALL_ROLLBACK_DIR:-}" ]; then
        err "已有未完成的防火墙回滚快照，已拒绝创建新快照。"
        return 1
    fi
    firewall_prepare_rollback_store || return 1
    for dir in "$FIREWALL_ROLLBACK_DIR"/firewall-rollback.*; do
        [ -d "$dir" ] || continue
        err "检测到尚未处理的防火墙回滚目录：$dir"
        return 1
    done

    build_dir="$(mktemp -d "$FIREWALL_ROLLBACK_DIR/.firewall-rollback-build.XXXXXX")" || return 1
    suffix="${build_dir##*.firewall-rollback-build.}"
    final_dir="$FIREWALL_ROLLBACK_DIR/firewall-rollback.$suffix"
    if [ -e "$final_dir" ] || [ -L "$final_dir" ]; then
        rm -rf "$build_dir"
        err "防火墙回滚目录发生冲突，已拒绝继续。"
        return 1
    fi
    nft_path="$(command -v nft)" || { rm -rf "$build_dir"; return 1; }
    firewall_snapshot_file "$build_dir" config "$FIREWALL_CONFIG" &&
        firewall_snapshot_file "$build_dir" state "$FIREWALL_STATE_FILE" &&
        firewall_snapshot_file "$build_dir" systemd-unit "$FIREWALL_SYSTEMD_UNIT" &&
        firewall_snapshot_file "$build_dir" openrc-service "$FIREWALL_OPENRC_SERVICE" || {
            rm -rf "$build_dir"
            return 1
        }
    if ! firewall_snapshot_runtime_state runtime_state "$build_dir/table.nft"; then
        rm -rf "$build_dir"
        err "无法确认防火墙运行状态，已拒绝创建回滚快照。"
        return 1
    fi
    if ! firewall_snapshot_persistence_state persistence_state; then
        rm -rf "$build_dir"
        err "无法确认防火墙开机加载状态，已拒绝创建回滚快照。"
        return 1
    fi
    if ! firewall_snapshot_service_state service_state; then
        rm -rf "$build_dir"
        err "无法确认防火墙服务状态，已拒绝创建回滚快照。"
        return 1
    fi
    if [ "$runtime_state" = "present" ]; then
        : > "$build_dir/table.present" || {
            rm -rf "$build_dir"
            return 1
        }
    fi
    if [ -e "$build_dir/config.present" ] &&
        ! firewall_write_ssh_safe_snapshot "$build_dir/config" "$build_dir/config" "$ssh_ports"; then
        rm -rf "$build_dir"
        return 1
    fi
    if [ -e "$build_dir/table.present" ] &&
        ! firewall_write_ssh_safe_snapshot "$build_dir/table.nft" "$build_dir/table.nft" "$ssh_ports"; then
        rm -rf "$build_dir"
        return 1
    fi
    if [ "$persistence_state" = "enabled" ]; then
        : > "$build_dir/service.enabled" || {
            rm -rf "$build_dir"
            return 1
        }
    fi
    if [ "$service_state" = "active" ]; then
        : > "$build_dir/service.active" || {
            rm -rf "$build_dir"
            return 1
        }
    fi

    printf '%s\n' commit > "$build_dir/commit.token" || { rm -rf "$build_dir"; return 1; }
    printf '%s\n' rollback > "$build_dir/rollback.token" || { rm -rf "$build_dir"; return 1; }

    # --- BEGIN GENERATED TEMPLATE: firewall rollback helper ---
    if ! cat > "$build_dir/rollback.sh" <<EOF
#!/bin/sh
set -u
dir='$final_dir'
nft='$nft_path'
failed=0
mode="\${1:-}"
sleep_pid=''

stop_watchdog_wait() {
    if [ -n "\$sleep_pid" ]; then
        kill -TERM "\$sleep_pid" 2>/dev/null || true
        wait "\$sleep_pid" 2>/dev/null || true
    fi
    exit 0
}

restore_lock_process_start() {
    awk '{ print \$22 }' "/proc/\$1/stat" 2>/dev/null
}

restore_lock_metadata_value() {
    metadata_file="\$1"
    metadata_key="\$2"
    awk -F= -v key="\$metadata_key" '\$1 == key { print substr(\$0, length(key) + 2); exit }' \
        "\$metadata_file" 2>/dev/null
}

restore_lock_metadata_ready() {
    lock_dir="\$dir/restore.lock"
    [ -s "\$lock_dir/owner" ] && [ ! -L "\$lock_dir/owner" ]
}

restore_lock_owner_matches() {
    lock_dir="\$dir/restore.lock"
    [ -d "\$lock_dir" ] && [ ! -L "\$lock_dir" ] || return 1
    [ -s "\$lock_dir/owner" ] && [ ! -L "\$lock_dir/owner" ] || return 1
    lock_pid="\$(restore_lock_metadata_value "\$lock_dir/owner" pid)" || return 1
    lock_start="\$(restore_lock_metadata_value "\$lock_dir/owner" start)" || return 1
    lock_boot="\$(restore_lock_metadata_value "\$lock_dir/owner" boot)" || return 1
    case "\$lock_pid:\$lock_start" in
        *[!0-9:]*|:*|*:) return 1 ;;
    esac
    kill -0 "\$lock_pid" 2>/dev/null || return 1
    [ "\$(restore_lock_process_start "\$lock_pid")" = "\$lock_start" ] &&
        [ "\$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)" = "\$lock_boot" ]
}

cleanup_restore_lock() {
    lock_dir="\$dir/restore.lock"
    rm -f "\$lock_dir/owner" "\$dir/.restore.lock.owner.\$\$"
    rmdir "\$lock_dir" >/dev/null 2>&1 || true
}

acquire_restore_lock() {
    lock_dir="\$dir/restore.lock"
    if ! mkdir "\$lock_dir" 2>/dev/null; then
        [ -d "\$lock_dir" ] && [ ! -L "\$lock_dir" ] || return 1
        lock_wait=0
        while [ "\$lock_wait" -lt 30 ] && ! restore_lock_metadata_ready; do
            sleep 0.1
            lock_wait=\$((lock_wait + 1))
        done
        restore_lock_owner_matches && return 2
        # 恢复进程被 SIGKILL 后可能遗留 restore.lock。只有持有者身份已失效，
        # 且目录中仅含 vpsbox 元数据时才回收，避免覆盖仍在执行的恢复。
        rm -f "\$lock_dir/owner"
        rmdir "\$lock_dir" 2>/dev/null || return 1
        mkdir "\$lock_dir" 2>/dev/null || return 1
    fi
    lock_start="\$(restore_lock_process_start "\$\$")"
    lock_boot="\$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"
    case "\$lock_start" in ''|*[!0-9]*) cleanup_restore_lock; return 1 ;; esac
    [ -n "\$lock_boot" ] || { cleanup_restore_lock; return 1; }
    owner_tmp="\$dir/.restore.lock.owner.\$\$"
    {
        printf 'pid=%s\n' "\$\$"
        printf 'start=%s\n' "\$lock_start"
        printf 'boot=%s\n' "\$lock_boot"
    } > "\$owner_tmp" &&
        chmod 600 "\$owner_tmp" &&
        mv -f "\$owner_tmp" "\$lock_dir/owner" || {
        cleanup_restore_lock
        return 1
    }
}

if [ "\$mode" != "--now" ] && [ "\$mode" != "--commit-owner" ]; then
    trap stop_watchdog_wait HUP INT TERM
    waited=0
    while [ "\$waited" -lt "$FIREWALL_ROLLBACK_SECONDS" ]; do
        [ -d "\$dir" ] || exit 0
        [ ! -e "\$dir/completed" ] || exit 0
        [ ! -e "\$dir/rolled-back" ] || exit 0
        sleep 1 &
        sleep_pid=\$!
        wait "\$sleep_pid" || exit 0
        sleep_pid=''
        waited=\$((waited + 1))
    done
    trap - HUP INT TERM
fi
[ -d "\$dir" ] || exit 0
[ ! -e "\$dir/completed" ] || exit 0
[ ! -e "\$dir/rolled-back" ] || exit 0

if [ "\$mode" = "--commit-owner" ]; then
    [ "\$(cat "\$dir/decision" 2>/dev/null)" = "commit" ] || exit 1
else
    if ! ln "\$dir/rollback.token" "\$dir/decision" 2>/dev/null; then
        case "\$(cat "\$dir/decision" 2>/dev/null)" in
            commit) exit 0 ;;
            rollback) ;;
            *) exit 1 ;;
        esac
    fi
fi

if acquire_restore_lock; then
    :
else
    restore_lock_status=\$?
    [ "\$restore_lock_status" -eq 2 ] && exit 0
    : > "\$dir/rollback-failed"
    exit 1
fi
trap cleanup_restore_lock EXIT
trap 'exit 1' HUP INT TERM
[ ! -e "\$dir/completed" ] || exit 0
[ ! -e "\$dir/rolled-back" ] || exit 0
rm -f "\$dir/rollback-failed"
: > "\$dir/restoring"

run_limited() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 20 "\$@"
    else
        "\$@"
    fi
}

restore_file() {
    name="\$1"
    target="\$2"
    if [ -e "\$dir/\$name.present" ]; then
        source="\$dir/\$name"
        [ -f "\$source" ] && [ ! -L "\$source" ] || return 1
        # 防止 mv 将临时文件移入符号链接指向的目录并误报恢复成功。
        if [ -L "\$target" ]; then
            [ ! -d "\$target" ] || return 1
        elif [ -e "\$target" ] && [ ! -f "\$target" ]; then
            return 1
        fi
        parent="\$(dirname "\$target")"
        [ -d "\$parent" ] && [ ! -L "\$parent" ] || return 1
        tmp="\$(mktemp "\$parent/.vpsbox-firewall-restore.XXXXXX")" || return 1
        if ! cp -a "\$source" "\$tmp" || ! mv -f "\$tmp" "\$target"; then
            rm -f "\$tmp"
            return 1
        fi
    else
        if [ -e "\$target" ] && [ ! -f "\$target" ] && [ ! -L "\$target" ]; then
            return 1
        fi
        rm -f "\$target" || return 1
    fi
}

restore_file config '$FIREWALL_CONFIG' || failed=1
restore_file state '$FIREWALL_STATE_FILE' || failed=1
restore_file systemd-unit '$FIREWALL_SYSTEMD_UNIT' || failed=1
restore_file openrc-service '$FIREWALL_OPENRC_SERVICE' || failed=1

if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    run_limited systemctl daemon-reload || failed=1
    if [ -e "\$dir/service.enabled" ]; then
        run_limited systemctl enable '$FIREWALL_SERVICE_NAME' || failed=1
        systemctl is-enabled --quiet '$FIREWALL_SERVICE_NAME' 2>/dev/null || failed=1
    else
        run_limited systemctl disable '$FIREWALL_SERVICE_NAME' >/dev/null 2>&1 || true
        systemctl is-enabled --quiet '$FIREWALL_SERVICE_NAME' 2>/dev/null && failed=1
    fi
    if [ -e "\$dir/service.active" ]; then
        run_limited systemctl restart '$FIREWALL_SERVICE_NAME' || failed=1
        systemctl is-active --quiet '$FIREWALL_SERVICE_NAME' 2>/dev/null || failed=1
    else
        run_limited systemctl stop '$FIREWALL_SERVICE_NAME' >/dev/null 2>&1 || true
        systemctl is-active --quiet '$FIREWALL_SERVICE_NAME' 2>/dev/null && failed=1
    fi
elif command -v rc-update >/dev/null 2>&1; then
    if [ -e "\$dir/service.enabled" ]; then
        run_limited rc-update add '$FIREWALL_SERVICE_NAME' default || failed=1
        [ -e '$FIREWALL_OPENRC_RUNLEVELS_DIR/default/$FIREWALL_SERVICE_NAME' ] || failed=1
    else
        run_limited rc-update del '$FIREWALL_SERVICE_NAME' default >/dev/null 2>&1 || true
        [ ! -e '$FIREWALL_OPENRC_RUNLEVELS_DIR/default/$FIREWALL_SERVICE_NAME' ] || failed=1
    fi
    if [ -e "\$dir/service.active" ]; then
        run_limited rc-service '$FIREWALL_SERVICE_NAME' restart || failed=1
        rc-service '$FIREWALL_SERVICE_NAME' status >/dev/null 2>&1 || failed=1
    else
        run_limited rc-service '$FIREWALL_SERVICE_NAME' stop >/dev/null 2>&1 || true
        rc-service '$FIREWALL_SERVICE_NAME' status >/dev/null 2>&1 && failed=1
    fi
else
    failed=1
fi

"\$nft" delete table inet vpsbox >/dev/null 2>&1 || true
if [ -e "\$dir/table.present" ]; then
    "\$nft" -f "\$dir/table.nft" || failed=1
    "\$nft" list table inet vpsbox >/dev/null 2>&1 || failed=1
elif "\$nft" list table inet vpsbox >/dev/null 2>&1; then
    failed=1
fi

if [ "\$failed" -eq 0 ]; then
    rm -f "\$dir/restoring"
    : > "\$dir/rolled-back"
    exit 0
fi
: > "\$dir/rollback-failed"
exit 1
EOF
    then
        rm -rf "$build_dir"
        return 1
    fi
    # --- END GENERATED TEMPLATE: firewall rollback helper ---
    chmod 700 "$build_dir/rollback.sh" || { rm -rf "$build_dir"; return 1; }
    sh -n "$build_dir/rollback.sh" || { rm -rf "$build_dir"; return 1; }

    # 仅完整快照使用正式前缀；中断时隐藏构建目录不会被当作待恢复操作。
    ACTIVE_FIREWALL_ROLLBACK_DIR="$final_dir"
    if ! mv "$build_dir" "$final_dir"; then
        ACTIVE_FIREWALL_ROLLBACK_DIR=""
        rm -rf "$build_dir"
        return 1
    fi
    printf -v "$output_var" '%s' "$final_dir"
}

firewall_start_rollback_watchdog() {
    local dir="$1" pid start boot
    firewall_rollback_dir_valid "$dir" || return 1
    : > "$dir/armed"
    # watchdog 必须独立于菜单存活以执行超时回滚，但不能继承菜单的 flock FD 200。
    nohup sh "$dir/rollback.sh" >> "$dir/rollback.log" 2>&1 200>&- &
    pid=$!
    start="$(process_start_ticks "$pid" || true)"
    boot="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"
    if ! process_alive "$pid" || ! [[ "$start" =~ ^[0-9]+$ ]] || [ -z "$boot" ] ||
        ! printf '%s\n' "$pid" > "$dir/watchdog.pid" ||
        ! printf '%s\n' "$start" > "$dir/watchdog.start" ||
        ! printf '%s\n' "$boot" > "$dir/watchdog.boot"; then
        kill -TERM "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        firewall_forget_watchdog_metadata "$dir"
        return 1
    fi
}

firewall_restore_snapshot_now() {
    local dir="$1" commit_owner="${2:-0}" i mode="--now"

    if ! firewall_rollback_dir_valid "$dir"; then
        return 1
    fi
    if [ -e "$dir/completed" ]; then
        [ "${ACTIVE_FIREWALL_ROLLBACK_DIR:-}" = "$dir" ] && ACTIVE_FIREWALL_ROLLBACK_DIR=""
        firewall_cleanup_finished_rollback "$dir" ||
            warn "防火墙操作已提交，但回滚进程清理尚未完成：$dir"
        return 0
    fi
    [ -x "$dir/rollback.sh" ] || return 1
    [ "$commit_owner" = "1" ] && mode="--commit-owner"
    sh "$dir/rollback.sh" "$mode" >> "$dir/rollback.log" 2>&1 || true
    for i in {1..90}; do
        if [ -e "$dir/rolled-back" ]; then
            [ "${ACTIVE_FIREWALL_ROLLBACK_DIR:-}" = "$dir" ] && ACTIVE_FIREWALL_ROLLBACK_DIR=""
            firewall_cleanup_finished_rollback "$dir" ||
                warn "防火墙快照已恢复，但回滚进程清理尚未完成：$dir"
            return 0
        fi
        [ -e "$dir/rollback-failed" ] && {
            err "防火墙自动恢复失败，快照保留在：$dir"
            return 1
        }
        sleep 1
    done
    err "防火墙恢复结果无法确认，快照保留在：$dir"
    return 1
}

firewall_begin_commit() {
    local dir="$1"
    firewall_rollback_dir_valid "$dir" || return 1
    : > "$dir/committing" || return 1
    if ! ln "$dir/commit.token" "$dir/decision" 2>/dev/null; then
        rm -f "$dir/committing"
        return 1
    fi
}

firewall_finish_commit() {
    local dir="$1"

    firewall_rollback_dir_valid "$dir" || return 1
    [ "$(cat "$dir/decision" 2>/dev/null || true)" = "commit" ] || return 1
    : > "$dir/completed" || return 1
    ACTIVE_FIREWALL_ROLLBACK_DIR=""
    firewall_cleanup_finished_rollback "$dir" ||
        warn "防火墙规则已提交，但回滚进程清理尚未完成：$dir"
    return 0
}

firewall_apply_config_file() {
    local config="$1" table_existed=0

    firewall_runtime_enabled && table_existed=1
    if [ "$table_existed" -eq 0 ]; then
        nft add table inet vpsbox || return 1
    fi
    if ! nft -c -f "$config"; then
        [ "$table_existed" -eq 1 ] || nft delete table inet vpsbox >/dev/null 2>&1 || true
        return 1
    fi
    if ! nft -f "$config"; then
        [ "$table_existed" -eq 1 ] || nft delete table inet vpsbox >/dev/null 2>&1 || true
        return 1
    fi
}

firewall_enable_persistence() {
    command -v timeout >/dev/null 2>&1 || {
        err "缺少 timeout 命令，无法为防火墙持久化设置执行上限。"
        return 1
    }
    if is_systemd; then
        timeout 20 systemctl daemon-reload &&
            timeout 20 systemctl enable --now "$FIREWALL_SERVICE_NAME"
    elif [ "$OS" = "alpine" ] && command -v rc-update >/dev/null 2>&1; then
        timeout 20 rc-update add "$FIREWALL_SERVICE_NAME" default >/dev/null &&
            { timeout 20 rc-service "$FIREWALL_SERVICE_NAME" restart >/dev/null 2>&1 ||
                timeout 20 rc-service "$FIREWALL_SERVICE_NAME" start; }
    else
        return 1
    fi
}

firewall_show_port_summary() {
    cat <<EOF
----------------------------------------
 即将应用主机防火墙
 SSH TCP：${FW_SSH_PORTS:--}
 节点 TCP：${FW_NODE_TCP:--}
 节点 UDP：${FW_NODE_UDP:--}
 Docker TCP：${FW_DOCKER_PUBLIC_TCP:--}
 Docker UDP：${FW_DOCKER_PUBLIC_UDP:--}
 其他公网 TCP：${FW_OTHER_PUBLIC_TCP:--}
 其他公网 UDP：${FW_OTHER_PUBLIC_UDP:--}
 额外 TCP：${FW_EXTRA_TCP:--}
 额外 UDP：${FW_EXTRA_UDP:--}
 默认入站策略：拒绝
 出站：不创建规则
 Docker 转发：仅检查已发布端口，不限制容器出站
----------------------------------------
EOF
    if [ "$FW_DOCKER_HOST_NETWORK" = "1" ]; then
        warn "检测到 host 网络模式容器；当前公网监听已自动纳入，未启动服务请通过额外端口提前放行。"
    fi
    if [ "$FW_DOCKER_DYNAMIC_PORT" = "1" ]; then
        warn "检测到尚未确定的 Docker 随机发布端口；容器启动后请重新更新防火墙。"
    fi
    if [ "$FW_DOCKER_DIRECT_NETWORK" = "1" ]; then
        warn "检测到 Docker 直连网络；该模式不会由当前端口守卫自动放行。"
    fi
    if [ "$FW_DOCKER_CUSTOM_BRIDGE" = "1" ]; then
        warn "检测到自定义 Docker bridge 接口名；新增或变更该网络后必须重新更新防火墙。"
    fi
}

firewall_apply_desired_state() {
    local work_dir rollback_dir answer service_file service_target service_mode
    local detect_status requested_extra_tcp="" requested_extra_udp="" override_extra_ports=0

    if [ "$#" -eq 2 ]; then
        requested_extra_tcp="$1"
        requested_extra_udp="$2"
        override_extra_ports=1
    elif [ "$#" -ne 0 ]; then
        return 2
    fi

    firewall_settle_pending_port_transition || return 1
    detect_os
    case "$OS" in
        debian|alpine) ;;
        *) err "主机防火墙目前仅支持 Debian/Ubuntu 与 Alpine。"; return 1 ;;
    esac
    firewall_recover_pending_rollbacks || return 1
    firewall_check_conflicts || return 1
    ensure_nftables || return 1
    firewall_check_conflicts || return 1
    firewall_load_state || return 1
    if [ "$override_extra_ports" -eq 1 ]; then
        FW_EXTRA_TCP="$requested_extra_tcp"
        FW_EXTRA_UDP="$requested_extra_udp"
    fi
    FW_DOCKER_STOPPED_IGNORED=0
    if firewall_detect_allowed_ports initial; then
        :
    else
        detect_status=$?
        [ "$detect_status" -eq 3 ] && return 0
        return "$detect_status"
    fi

    if firewall_desired_state_is_current; then
        info "当前防火墙规则与端口状态一致，无需更新。"
        return 0
    fi
    firewall_show_port_summary
    read -r -p "确认应用以上规则？请输入 YES：" answer || return 1
    [ "$answer" = "YES" ] || { info "已取消，未修改防火墙。"; return 0; }

    # 用户确认期间 ssh.socket、sshd、Docker 或公网监听可能变化；落盘前重新取一次实时状态。
    firewall_load_state || {
        err "确认后防火墙状态文件发生异常，未修改防火墙。"
        return 1
    }
    if [ "$override_extra_ports" -eq 1 ]; then
        FW_EXTRA_TCP="$requested_extra_tcp"
        FW_EXTRA_UDP="$requested_extra_udp"
    fi
    if ! firewall_detect_allowed_ports confirmed; then
        err "确认后端口状态发生异常，未修改防火墙。"
        return 1
    fi
    if firewall_desired_state_is_current; then
        info "当前防火墙规则与端口状态一致，无需更新。"
        return 0
    fi

    ensure_change_store || return 1
    work_dir="$(mktemp -d "$RUNTIME_DIR/firewall-work.XXXXXX")" || return 1
    firewall_write_state_file "$work_dir/firewall.env" || { rm -rf "$work_dir"; return 1; }
    firewall_write_config "$work_dir/firewall.nft" || { rm -rf "$work_dir"; return 1; }
    if is_systemd; then
        service_file="$work_dir/vpsbox-firewall.service"
        service_target="$FIREWALL_SYSTEMD_UNIT"
        service_mode=644
    else
        service_file="$work_dir/vpsbox-firewall"
        service_target="$FIREWALL_OPENRC_SERVICE"
        service_mode=755
    fi
    firewall_write_service_definition "$service_file" || { rm -rf "$work_dir"; return 1; }

    if ! firewall_create_rollback_snapshot rollback_dir "$FW_SSH_PORTS"; then
        rm -rf "$work_dir"
        err "无法创建防火墙回滚快照。"
        return 1
    fi
    if ! firewall_start_rollback_watchdog "$rollback_dir"; then
        err "无法启动自动回滚保护，正在恢复原状态。"
        if ! firewall_restore_snapshot_now "$rollback_dir"; then
            err "原状态恢复失败，必须先处理保留的回滚快照。"
        fi
        rm -rf "$work_dir"
        return 1
    fi
    # SSH 二次确认前只修改内核运行态，不覆盖开机配置。若此时异常重启，
    # 系统仍按原有持久配置启动；持久快照会在下次进入防火墙功能时继续恢复/清理。
    if ! firewall_apply_config_file "$work_dir/firewall.nft"; then
        err "防火墙临时配置校验或应用失败，正在恢复原状态。"
        if ! firewall_restore_snapshot_now "$rollback_dir"; then
            err "原状态恢复失败，必须先处理保留的回滚快照。"
        fi
        rm -rf "$work_dir"
        return 1
    fi

    info "规则已临时应用，$FIREWALL_ROLLBACK_SECONDS 秒内未确认将自动恢复。"
    warn "请保持当前 SSH 会话，并立即另开一个 SSH 窗口测试登录。"
    read -r -p "确认新 SSH 会话可以登录后，输入 YES 保存规则：" answer || answer=""
    if [ "$answer" != "YES" ]; then
        warn "未收到有效确认，正在恢复应用前的防火墙状态。"
        if ! firewall_restore_snapshot_now "$rollback_dir"; then
            err "原状态恢复失败，必须先处理保留的回滚快照。"
        fi
        rm -rf "$work_dir"
        return 1
    fi

    if ! firewall_begin_commit "$rollback_dir"; then
        err "确认前规则已经开始自动恢复，本次设置未保存。"
        if ! firewall_restore_snapshot_now "$rollback_dir"; then
            err "自动恢复尚未完成，已保留回滚快照。"
        fi
        rm -rf "$work_dir"
        return 1
    fi
    if ! firewall_install_managed_file "$work_dir/firewall.env" "$FIREWALL_STATE_FILE" 600 ||
        ! firewall_install_managed_file "$work_dir/firewall.nft" "$FIREWALL_CONFIG" 600 ||
        ! firewall_install_managed_file "$service_file" "$service_target" "$service_mode" ||
        ! firewall_enable_persistence ||
        ! firewall_runtime_enabled ||
        ! firewall_persistence_enabled ||
        ! firewall_service_active; then
        err "防火墙持久化验证失败，正在恢复应用前状态。"
        if ! firewall_restore_snapshot_now "$rollback_dir" 1; then
            err "原状态恢复失败，必须先处理保留的回滚快照。"
        fi
        rm -rf "$work_dir"
        return 1
    fi
    if ! firewall_finish_commit "$rollback_dir"; then
        err "防火墙提交状态写入失败，正在恢复应用前状态。"
        if ! firewall_restore_snapshot_now "$rollback_dir" 1; then
            err "原状态恢复失败，必须先处理保留的回滚快照。"
        fi
        rm -rf "$work_dir"
        return 1
    fi
    rm -rf "$work_dir"
    info "主机防火墙已启用并设置为开机自动加载。"
}

firewall_replace_active_config() {
    local generated="$1" backup

    [ -f "$generated" ] && [ ! -L "$generated" ] || return 1
    backup="$(mktemp "$FIREWALL_ROLLBACK_DIR/firewall-config-backup.XXXXXX")" || return 1
    cp "$FIREWALL_CONFIG" "$backup" || { rm -f "$backup"; return 1; }
    if ! nft -c -f "$generated"; then
        rm -f "$backup"
        return 1
    fi
    if ! firewall_install_managed_file "$generated" "$FIREWALL_CONFIG" 600; then
        rm -f "$backup"
        return 1
    fi
    if ! nft -f "$FIREWALL_CONFIG"; then
        if ! firewall_install_managed_file "$backup" "$FIREWALL_CONFIG" 600; then
            err "防火墙同步失败，且磁盘配置未能恢复；旧配置持久备份已保留：$backup"
            return 1
        fi
        rm -f "$backup"
        return 1
    fi
    rm -f "$backup"
}

firewall_active_config_ready_for_sync() {
    # 没有回滚目录或活动事务句柄时不存在可扫描的事务；
    # 节点和 SSH 的空同步无需预先创建持久回滚目录。
    if [ -n "${ACTIVE_FIREWALL_ROLLBACK_DIR:-}${ACTIVE_FIREWALL_ADDITIVE_DIR:-}" ] ||
        [ -e "$FIREWALL_ROLLBACK_DIR" ] ||
        [ -L "$FIREWALL_ROLLBACK_DIR" ]; then
        firewall_recover_pending_rollbacks || return 1
    fi
    if [ ! -f "$FIREWALL_CONFIG" ]; then
        if firewall_runtime_enabled ||
            [ -e "$FIREWALL_SYSTEMD_UNIT" ] ||
            [ -e "$FIREWALL_OPENRC_SERVICE" ] ||
            firewall_persistence_enabled ||
            firewall_service_active; then
            err "主机防火墙运行状态不完整且配置文件缺失，请先在防火墙菜单关闭或修复。"
            return 1
        fi
        return 0
    fi
    [ -f "$FIREWALL_STATE_FILE" ] || {
        err "主机防火墙配置不完整，请先在防火墙菜单执行更新或关闭。"
        return 1
    }
    firewall_runtime_enabled || {
        err "主机防火墙配置存在但规则表未运行，无法同步端口。"
        return 1
    }
    firewall_prepare_rollback_store
}

firewall_sync_active_config() {
    local temporary_tcp="${1:-}" temporary_udp="${2:-}" quiet="${3:-0}"
    local tmp

    firewall_active_config_ready_for_sync || return 1
    [ -f "$FIREWALL_CONFIG" ] || return 0
    firewall_load_state || return 1
    firewall_detect_allowed_ports || return 1
    FW_ALLOWED_TCP="$(merge_port_csv "$FW_ALLOWED_TCP" "$temporary_tcp")" || return 1
    FW_ALLOWED_UDP="$(merge_port_csv "$FW_ALLOWED_UDP" "$temporary_udp")" || return 1
    tmp="$(mktemp "$RUNTIME_DIR/firewall-refresh.XXXXXX")" || return 1
    if ! firewall_write_config "$tmp" ||
        ! firewall_replace_active_config "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    rm -f "$tmp"
    [ "$quiet" = "1" ] || info "主机防火墙已同步当前 SSH、节点、Docker 和公网监听端口。"
}

firewall_prepare_port_transition() {
    local tcp_ports="${1:-}" udp_ports="${2:-}"
    local drop_tcp="${3:-}" drop_udp="${4:-}" transition_dir
    local ssh_configured_ports ssh_listening_ports ssh_safe_ports

    if [ -n "${ACTIVE_FIREWALL_TRANSITION_DIR:-}" ]; then
        err "已有未完成的防火墙端口切换，已拒绝开始新的切换。"
        return 1
    fi
    if [ ! -f "$FIREWALL_CONFIG" ]; then
        firewall_sync_active_config "$tcp_ports" "$udp_ports" 1
        return $?
    fi

    prepare_runtime_dir
    transition_dir="$(mktemp -d "$RUNTIME_DIR/firewall-transition.XXXXXX")" || return 1
    ssh_configured_ports="$(ssh_effective_ports_csv 2>/dev/null)" || {
        rm -rf "$transition_dir"
        return 1
    }
    ssh_listening_ports="$(ssh_listening_ports_csv 2>/dev/null)" || {
        rm -rf "$transition_dir"
        return 1
    }
    ssh_safe_ports="$(merge_port_csv "$ssh_configured_ports" "$ssh_listening_ports")" || {
        rm -rf "$transition_dir"
        return 1
    }
    # 事务前文件可能落后于 sshd；快照只增补安全 SSH 端口，不提前收窄其他服务。
    if ! firewall_write_ssh_safe_snapshot \
        "$FIREWALL_CONFIG" "$transition_dir/firewall.nft" "$ssh_safe_ports"; then
        rm -rf "$transition_dir"
        return 1
    fi
    drop_tcp="$(normalize_port_csv "$drop_tcp")" || { rm -rf "$transition_dir"; return 1; }
    drop_udp="$(normalize_port_csv "$drop_udp")" || { rm -rf "$transition_dir"; return 1; }
    printf '%s\n' "$drop_tcp" > "$transition_dir/drop-tcp.csv" ||
        { rm -rf "$transition_dir"; return 1; }
    printf '%s\n' "$drop_udp" > "$transition_dir/drop-udp.csv" ||
        { rm -rf "$transition_dir"; return 1; }
    chmod 600 "$transition_dir/drop-tcp.csv" "$transition_dir/drop-udp.csv" ||
        { rm -rf "$transition_dir"; return 1; }
    ACTIVE_FIREWALL_TRANSITION_DIR="$transition_dir"
    # 节点与 SSH 内部操作只增补自己的目标端口，不重新扫描或收窄其他公网监听。
    if ! firewall_sync_target_ports "$tcp_ports" "$udp_ports" "" "" 1; then
        firewall_abort_port_transition || true
        return 1
    fi
}

firewall_abort_port_transition() {
    local transition_dir="${ACTIVE_FIREWALL_TRANSITION_DIR:-}"

    [ -n "$transition_dir" ] || return 0
    if [[ "$transition_dir" != "$RUNTIME_DIR"/firewall-transition.* ]] ||
        [ ! -d "$transition_dir" ] || [ -L "$transition_dir" ] ||
        [ ! -f "$transition_dir/firewall.nft" ]; then
        err "防火墙端口切换备份无效，已拒绝自动恢复：$transition_dir"
        return 1
    fi
    if ! firewall_install_managed_file "$transition_dir/firewall.nft" "$FIREWALL_CONFIG" 600 ||
        ! firewall_apply_config_file "$FIREWALL_CONFIG"; then
        err "防火墙端口切换恢复失败，备份已保留：$transition_dir"
        return 1
    fi
    ACTIVE_FIREWALL_TRANSITION_DIR=""
    rm -rf "$transition_dir"
}

firewall_discard_port_transition() {
    local transition_dir="${ACTIVE_FIREWALL_TRANSITION_DIR:-}"

    [ -n "$transition_dir" ] || return 0
    if [[ "$transition_dir" != "$RUNTIME_DIR"/firewall-transition.* ]] ||
        [ ! -d "$transition_dir" ] || [ -L "$transition_dir" ]; then
        err "防火墙端口切换目录无效，已拒绝清理：$transition_dir"
        return 1
    fi
    ACTIVE_FIREWALL_TRANSITION_DIR=""
    rm -rf "$transition_dir"
}

firewall_complete_port_transition() {
    local transition_dir="${ACTIVE_FIREWALL_TRANSITION_DIR:-}" drop_tcp="" drop_udp=""

    if [ -z "$transition_dir" ]; then
        firewall_sync_target_ports "" "" "" "" 0
        return $?
    fi
    if [[ "$transition_dir" != "$RUNTIME_DIR"/firewall-transition.* ]] ||
        [ ! -d "$transition_dir" ] || [ -L "$transition_dir" ] ||
        [ ! -f "$transition_dir/drop-tcp.csv" ] || [ -L "$transition_dir/drop-tcp.csv" ] ||
        [ ! -f "$transition_dir/drop-udp.csv" ] || [ -L "$transition_dir/drop-udp.csv" ]; then
        err "防火墙端口切换目录无效，无法完成清理：$transition_dir"
        return 1
    fi
    IFS= read -r drop_tcp < "$transition_dir/drop-tcp.csv" || return 1
    IFS= read -r drop_udp < "$transition_dir/drop-udp.csv" || return 1
    drop_tcp="$(normalize_port_csv "$drop_tcp")" || return 1
    drop_udp="$(normalize_port_csv "$drop_udp")" || return 1
    firewall_sync_target_ports "" "" "$drop_tcp" "$drop_udp" 0 || return 1
    firewall_discard_port_transition
}

firewall_refresh_if_enabled() {
    firewall_sync_active_config "" "" 0
}

firewall_ports_from_nft_chain() {
    local protocol="$1"

    awk -v protocol="$protocol" '
        {
            line=$0
            if (index(line, protocol " sport ") > 0) next
            marker=protocol " dport "
            start=index(line, marker)
            if (start == 0) next
            tail=substr(line, start + length(marker))
            stop=index(tail, " accept")
            if (stop == 0) next
            values=substr(tail, 1, stop - 1)
            gsub(/[{},]/, " ", values)
            count=split(values, parts, /[[:space:]]+/)
            for (i=1; i<=count; i++) {
                if (parts[i] ~ /^[0-9]+$/) print parts[i]
            }
        }
    ' | sort -n -u | paste -sd, -
}

firewall_live_port_set_matches() {
    local set_name="$1" expected="$2" set_rules live_body live_set

    if [ -n "$expected" ]; then
        expected="$(normalize_port_csv "$expected")" || return 1
        set_rules="$(nft -nn list set inet vpsbox "$set_name" 2>/dev/null)" || return 1
        live_body="$(printf '%s\n' "$set_rules" | firewall_set_body_lines "$set_name")" || return 1
        live_set="$(printf '%s\n' "$live_body" | firewall_discrete_port_set_values)" || return 1
        [ "$live_set" = "$expected" ]
    else
        ! nft list set inet vpsbox "$set_name" >/dev/null 2>&1
    fi
}

firewall_live_interface_set_matches() {
    local set_name="$1" expected="$2" set_rules live_body live_set

    if [ -n "$expected" ]; then
        expected="$(normalize_interface_csv "$expected")" || return 1
        set_rules="$(nft -nn list set inet vpsbox "$set_name" 2>/dev/null)" || return 1
        live_body="$(printf '%s\n' "$set_rules" | firewall_set_body_lines "$set_name")" || return 1
        live_set="$(printf '%s\n' "$live_body" | firewall_discrete_interface_set_values)" || return 1
        [ "$live_set" = "$expected" ]
    else
        ! nft list set inet vpsbox "$set_name" >/dev/null 2>&1
    fi
}

firewall_set_body_lines() {
    local set_name="$1"

    awk -v target="$set_name" '
        $1 == "set" && $2 == target && $3 == "{" { inside=1; next }
        inside && /^[[:space:]]*}[[:space:]]*$/ { inside=0; next }
        inside {
            line=$0
            sub(/^[[:space:]]*/, "", line)
            sub(/[[:space:]]*;?[[:space:]]*$/, "", line)
            gsub(/[[:space:]]+/, " ", line)
            if (line != "") print line
        }
    '
}

firewall_discrete_port_set_values() {
    awk '
        NR == 1 { if ($0 != "type inet_service") exit 1; next }
        { text = text (text == "" ? "" : " ") $0 }
        END {
            gsub(/[[:space:]]+/, " ", text)
            if (text !~ /^elements = \{ [0-9]+(, [0-9]+)* \}$/) exit 1
            sub(/^elements = \{ /, "", text)
            sub(/ \}$/, "", text)
            count=split(text, values, /, /)
            for (i=1; i<=count; i++) print values[i]
        }
    ' | sort -n -u | paste -sd, -
}

firewall_discrete_interface_set_values() {
    awk '
        NR == 1 { if ($0 != "type ifname") exit 1; next }
        { text = text (text == "" ? "" : " ") $0 }
        END {
            gsub(/[[:space:]]+/, " ", text)
            if (text !~ /^elements = \{ "[A-Za-z0-9_.:-]+"(, "[A-Za-z0-9_.:-]+")* \}$/) exit 1
            sub(/^elements = \{ /, "", text)
            sub(/ \}$/, "", text)
            count=split(text, values, /, /)
            for (i=1; i<=count; i++) {
                sub(/^"/, "", values[i])
                sub(/"$/, "", values[i])
                print values[i]
            }
        }
    ' | sort -u | paste -sd, -
}

firewall_nft_port_expression() {
    local csv

    csv="$(normalize_port_csv "${1:-}")" || return 1
    [ -n "$csv" ] || return 1
    if [[ "$csv" == *,* ]]; then
        printf '{ %s }\n' "$(printf '%s' "$csv" | sed 's/,/, /g')"
    else
        printf '%s\n' "$csv"
    fi
}

firewall_chain_rule_lines() {
    local chain="$1"

    awk -v target="$chain" '
        $1 == "chain" && $2 == target && $3 == "{" { inside=1; next }
        inside && /^[[:space:]]*}[[:space:]]*$/ { inside=0; next }
        inside {
            line=$0
            sub(/^[[:space:]]*/, "", line)
            sub(/[[:space:]]*$/, "", line)
            gsub(/[[:space:]]+/, " ", line)
            if (line == "" || line ~ /^type filter hook /) next
            print line
        }
    '
}

firewall_chain_base_matches() {
    local chain="$1" hook="$2" priority="$3" alternate_priority="$4" policy="$5"

    awk -v target="$chain" -v hook="$hook" -v priority="$priority" \
        -v alternate="$alternate_priority" -v policy="$policy" '
        $1 == "chain" && $2 == target && $3 == "{" { inside=1; next }
        inside && /^[[:space:]]*}[[:space:]]*$/ { inside=0; next }
        inside {
            line=$0
            sub(/^[[:space:]]*/, "", line)
            sub(/[[:space:]]*$/, "", line)
            gsub(/[[:space:]]+/, " ", line)
            expected="type filter hook " hook " priority " priority "; policy " policy ";"
            if (line == expected) matched=1
            if (alternate != "") {
                expected="type filter hook " hook " priority " alternate "; policy " policy ";"
                if (line == expected) matched=1
            }
        }
        END { exit !matched }
    '
}

firewall_expected_input_rule_lines() {
    local expression

    printf '%s\n' \
        'ct state 0x1 drop' \
        'ct state 0x2,0x4 accept' \
        'iifname "lo" accept' \
        'ip protocol 1 accept' \
        'meta l4proto 58 accept' \
        'meta nfproto 2 udp sport 67 udp dport 68 accept' \
        'meta nfproto 10 udp sport 547 udp dport 546 accept'
    if [ -n "$FW_ALLOWED_TCP" ]; then
        expression="$(firewall_nft_port_expression "$FW_ALLOWED_TCP")" || return 1
        printf 'tcp dport %s accept\n' "$expression"
    fi
    if [ -n "$FW_ALLOWED_UDP" ]; then
        expression="$(firewall_nft_port_expression "$FW_ALLOWED_UDP")" || return 1
        printf 'udp dport %s accept\n' "$expression"
    fi
    if [ -n "$FW_DOCKER_PROXY4_TCP" ]; then
        expression="$(firewall_nft_port_expression "$FW_DOCKER_PROXY4_TCP")" || return 1
        printf 'meta nfproto 2 tcp dport %s accept\n' "$expression"
    fi
    if [ -n "$FW_DOCKER_PROXY4_UDP" ]; then
        expression="$(firewall_nft_port_expression "$FW_DOCKER_PROXY4_UDP")" || return 1
        printf 'meta nfproto 2 udp dport %s accept\n' "$expression"
    fi
    if [ -n "$FW_DOCKER_PROXY6_TCP" ]; then
        expression="$(firewall_nft_port_expression "$FW_DOCKER_PROXY6_TCP")" || return 1
        printf 'meta nfproto 10 tcp dport %s accept\n' "$expression"
    fi
    if [ -n "$FW_DOCKER_PROXY6_UDP" ]; then
        expression="$(firewall_nft_port_expression "$FW_DOCKER_PROXY6_UDP")" || return 1
        printf 'meta nfproto 10 udp dport %s accept\n' "$expression"
    fi
}

firewall_expected_guard_rule_lines() {
    [ -z "$FW_EXTRA_TCP" ] || printf '%s\n' \
        'meta l4proto 6 ct original proto-dst @extra_tcp_dnat_ports accept'
    [ -z "$FW_DOCKER_PUBLIC4_TCP" ] || printf '%s\n' \
        'meta nfproto 2 meta l4proto 6 oifname @docker_bridge_ifaces ct original proto-dst @docker4_tcp_ports accept'
    [ -z "$FW_DOCKER_PUBLIC6_TCP" ] || printf '%s\n' \
        'meta nfproto 10 meta l4proto 6 oifname @docker_bridge_ifaces ct original proto-dst @docker6_tcp_ports accept'
    printf '%s\n' 'meta l4proto 6 drop'
    [ -z "$FW_EXTRA_UDP" ] || printf '%s\n' \
        'meta l4proto 17 ct original proto-dst @extra_udp_dnat_ports accept'
    [ -z "$FW_DOCKER_PUBLIC4_UDP" ] || printf '%s\n' \
        'meta nfproto 2 meta l4proto 17 oifname @docker_bridge_ifaces ct original proto-dst @docker4_udp_ports accept'
    [ -z "$FW_DOCKER_PUBLIC6_UDP" ] || printf '%s\n' \
        'meta nfproto 10 meta l4proto 17 oifname @docker_bridge_ifaces ct original proto-dst @docker6_udp_ports accept'
    printf '%s\n' 'meta l4proto 17 drop' 'drop'
}

firewall_expected_forward_rule_lines() {
    printf '%s\n' 'ct state 0x2,0x4 accept'
    [ -z "$FW_DOCKER_BRIDGES" ] || printf '%s\n' 'iifname @docker_bridge_ifaces accept'
    printf '%s\n' 'ct direction 0 ct status 0x20 jump docker_port_guard'
    [ -z "$FW_DOCKER_BRIDGES" ] || printf '%s\n' 'oifname @docker_bridge_ifaces drop'
}

firewall_expected_set_names() {
    [ -z "$FW_DOCKER_BRIDGES" ] || printf '%s\n' docker_bridge_ifaces
    [ -z "$FW_DOCKER_PUBLIC4_TCP" ] || printf '%s\n' docker4_tcp_ports
    [ -z "$FW_DOCKER_PUBLIC4_UDP" ] || printf '%s\n' docker4_udp_ports
    [ -z "$FW_DOCKER_PUBLIC6_TCP" ] || printf '%s\n' docker6_tcp_ports
    [ -z "$FW_DOCKER_PUBLIC6_UDP" ] || printf '%s\n' docker6_udp_ports
    [ -z "$FW_EXTRA_TCP" ] || printf '%s\n' extra_tcp_dnat_ports
    [ -z "$FW_EXTRA_UDP" ] || printf '%s\n' extra_udp_dnat_ports
}

firewall_table_object_names() {
    local object_type="$1"

    awk -v object_type="$object_type" '
        $1 == object_type && $3 == "{" { print $2 }
    ' | sort -u | paste -sd, -
}

firewall_live_config_matches_expected() {
    local table_rules input_rules live_tcp live_udp guard_rules forward_rules
    local live_rule_lines expected_rule_lines
    local live_chain_names live_set_names expected_set_names
    local expected_input_tcp expected_input_udp
    local expected_docker4_tcp expected_docker4_udp expected_docker6_tcp expected_docker6_udp
    local expected_docker_bridges

    firewall_runtime_enabled || return 1
    table_rules="$(nft -nn list table inet vpsbox 2>/dev/null)" || return 1
    live_chain_names="$(printf '%s\n' "$table_rules" | firewall_table_object_names chain)" || return 1
    [ "$live_chain_names" = "docker_forward,docker_port_guard,input" ] || return 1
    live_set_names="$(printf '%s\n' "$table_rules" | firewall_table_object_names set)" || return 1
    expected_set_names="$(firewall_expected_set_names | sort -u | paste -sd, -)" || return 1
    [ "$live_set_names" = "$expected_set_names" ] || return 1
    if printf '%s\n' "$table_rules" |
        grep -Eq '^[[:space:]]*(map|flowtable|counter|quota|limit|synproxy)[[:space:]]+[^[:space:]]+[[:space:]]*\{'; then
        return 1
    fi
    input_rules="$(nft -nn list chain inet vpsbox input 2>/dev/null)" || return 1
    printf '%s\n' "$input_rules" |
        grep -Eq 'hook input priority (filter|0); policy drop;' || return 1
    live_rule_lines="$(printf '%s\n' "$input_rules" | firewall_chain_rule_lines input)" || return 1
    expected_rule_lines="$(firewall_expected_input_rule_lines)" || return 1
    [ "$live_rule_lines" = "$expected_rule_lines" ] || return 1
    live_tcp="$(printf '%s\n' "$input_rules" | firewall_ports_from_nft_chain tcp)" || return 1
    live_udp="$(printf '%s\n' "$input_rules" | firewall_ports_from_nft_chain udp)" || return 1
    expected_input_tcp="$(merge_port_csv "$FW_ALLOWED_TCP" "$FW_DOCKER_PROXY4_TCP" "$FW_DOCKER_PROXY6_TCP")" || return 1
    expected_input_udp="$(merge_port_csv "$FW_ALLOWED_UDP" "$FW_DOCKER_PROXY4_UDP" "$FW_DOCKER_PROXY6_UDP")" || return 1
    [ "$live_tcp" = "$expected_input_tcp" ] || return 1
    [ "$live_udp" = "$expected_input_udp" ] || return 1
    guard_rules="$(nft -nn list chain inet vpsbox docker_port_guard 2>/dev/null)" || return 1
    forward_rules="$(nft -nn list chain inet vpsbox docker_forward 2>/dev/null)" || return 1
    live_rule_lines="$(printf '%s\n' "$guard_rules" | firewall_chain_rule_lines docker_port_guard)" || return 1
    expected_rule_lines="$(firewall_expected_guard_rule_lines)" || return 1
    [ "$live_rule_lines" = "$expected_rule_lines" ] || return 1
    live_rule_lines="$(printf '%s\n' "$forward_rules" | firewall_chain_rule_lines docker_forward)" || return 1
    expected_rule_lines="$(firewall_expected_forward_rule_lines)" || return 1
    [ "$live_rule_lines" = "$expected_rule_lines" ] || return 1
    printf '%s\n' "$forward_rules" |
        grep -Eq 'hook forward priority (-1|filter[[:space:]]*-[[:space:]]*1); policy accept;' || return 1
    if nft list chain inet vpsbox output >/dev/null 2>&1; then return 1; fi

    expected_docker4_tcp="$(normalize_port_csv "$FW_DOCKER_PUBLIC4_TCP")" || return 1
    expected_docker4_udp="$(normalize_port_csv "$FW_DOCKER_PUBLIC4_UDP")" || return 1
    expected_docker6_tcp="$(normalize_port_csv "$FW_DOCKER_PUBLIC6_TCP")" || return 1
    expected_docker6_udp="$(normalize_port_csv "$FW_DOCKER_PUBLIC6_UDP")" || return 1
    expected_docker_bridges="$(normalize_interface_csv "$FW_DOCKER_BRIDGES")" || return 1
    if [ -n "$expected_docker4_tcp$expected_docker4_udp$expected_docker6_tcp$expected_docker6_udp" ] &&
        [ -z "$expected_docker_bridges" ]; then return 1; fi
    firewall_live_port_set_matches docker4_tcp_ports "$expected_docker4_tcp" || return 1
    firewall_live_port_set_matches docker4_udp_ports "$expected_docker4_udp" || return 1
    firewall_live_port_set_matches docker6_tcp_ports "$expected_docker6_tcp" || return 1
    firewall_live_port_set_matches docker6_udp_ports "$expected_docker6_udp" || return 1
    firewall_live_port_set_matches extra_tcp_dnat_ports "$FW_EXTRA_TCP" || return 1
    firewall_live_port_set_matches extra_udp_dnat_ports "$FW_EXTRA_UDP" || return 1
    firewall_live_interface_set_matches docker_bridge_ifaces "$expected_docker_bridges" || return 1
    ! nft list set inet vpsbox docker_tcp_ports >/dev/null 2>&1 || return 1
    ! nft list set inet vpsbox docker_udp_ports >/dev/null 2>&1 || return 1
}

firewall_config_direct_ports() {
    local source="$1" protocol="$2"

    [ -f "$source" ] && [ ! -L "$source" ] || return 1
    case "$protocol" in tcp|udp) ;; *) return 2 ;; esac
    awk '
        /^[[:space:]]*chain[[:space:]]+input[[:space:]]*\{/ { in_input=1; next }
        in_input && /^[[:space:]]*\}/ { exit }
        in_input && $0 !~ /meta nfproto/ { print }
    ' "$source" | firewall_ports_from_nft_chain "$protocol"
}

firewall_config_port_set_matches() {
    local source="$1" set_name="$2" expected="$3" body actual count

    count="$(grep -Ec "^[[:space:]]*set[[:space:]]+${set_name}[[:space:]]*\\{" "$source" || true)"
    if [ -z "$expected" ]; then
        [ "$count" -eq 0 ]
        return
    fi
    [ "$count" -eq 1 ] || return 1
    expected="$(normalize_port_csv "$expected")" || return 1
    body="$(firewall_set_body_lines "$set_name" < "$source")" || return 1
    actual="$(printf '%s\n' "$body" | firewall_discrete_port_set_values)" || return 1
    [ "$actual" = "$expected" ]
}

firewall_config_additive_shape_valid() {
    local source="$1" old_tcp="$2" old_udp="$3"
    local direct_tcp direct_udp count expected_rule

    [ -f "$source" ] && [ ! -L "$source" ] || return 1
    grep -Fqx '# Managed by vpsbox. Replace only the dedicated table; never flush the global ruleset.' "$source" || return 1
    [ "$(grep -Ec '^[[:space:]]*table[[:space:]]+inet[[:space:]]+vpsbox[[:space:]]*\{' "$source" || true)" -eq 1 ] || return 1
    for count in input docker_port_guard docker_forward; do
        [ "$(grep -Ec "^[[:space:]]*chain[[:space:]]+${count}[[:space:]]*\\{" "$source" || true)" -eq 1 ] || return 1
    done
    ! grep -Eq '^[[:space:]]*chain[[:space:]]+output[[:space:]]*\{' "$source" || return 1
    [ "$(grep -Ec '^[[:space:]]*tcp[[:space:]]+dport[[:space:]]+\{[^}]+\}[[:space:]]+accept[[:space:]]*$' "$source" || true)" -eq 1 ] || return 1
    [ "$(grep -Ec '^[[:space:]]*udp[[:space:]]+dport[[:space:]]+\{[^}]+\}[[:space:]]+accept[[:space:]]*$' "$source" || true)" -le 1 ] || return 1

    direct_tcp="$(firewall_config_direct_ports "$source" tcp)" || return 1
    direct_udp="$(firewall_config_direct_ports "$source" udp)" || return 1
    [ -n "$direct_tcp" ] || return 1
    port_csv_is_subset "$old_tcp" "$direct_tcp" || return 1
    port_csv_is_subset "$old_udp" "$direct_udp" || return 1
    firewall_config_port_set_matches "$source" extra_tcp_dnat_ports "$old_tcp" || return 1
    firewall_config_port_set_matches "$source" extra_udp_dnat_ports "$old_udp" || return 1

    expected_rule='        meta l4proto tcp ct original proto-dst @extra_tcp_dnat_ports accept'
    count="$(grep -Fxc "$expected_rule" "$source" || true)"
    if [ -n "$old_tcp" ]; then [ "$count" -eq 1 ] || return 1; else [ "$count" -eq 0 ] || return 1; fi
    expected_rule='        meta l4proto udp ct original proto-dst @extra_udp_dnat_ports accept'
    count="$(grep -Fxc "$expected_rule" "$source" || true)"
    if [ -n "$old_udp" ]; then [ "$count" -eq 1 ] || return 1; else [ "$count" -eq 0 ] || return 1; fi
}

firewall_replace_input_direct_ports() {
    local source="$1" dest="$2" protocol="$3" ports="$4" formatted

    ports="$(normalize_port_csv "$ports")" || return 1
    formatted="$(printf '%s' "$ports" | sed 's/,/, /g')"
    awk -v protocol="$protocol" -v formatted="$formatted" '
        function emit_rule() {
            if (formatted == "") return
            print "        " protocol " dport { " formatted " } accept"
            inserted=1
        }
        /^[[:space:]]*chain[[:space:]]+input[[:space:]]*\{/ {
            in_input=1
            print
            next
        }
        in_input {
            target="^[[:space:]]*" protocol "[[:space:]]+dport[[:space:]]+\\{[^}]+\\}[[:space:]]+accept[[:space:]]*$"
            if ($0 ~ target) {
                seen++
                if (!inserted && formatted != "") emit_rule()
                next
            }
            if (formatted != "" && !inserted && protocol == "tcp" && $0 ~ /^[[:space:]]*udp[[:space:]]+dport[[:space:]]+/) emit_rule()
            if (formatted != "" && !inserted && $0 ~ /^[[:space:]]*meta[[:space:]]+nfproto.*(tcp|udp)[[:space:]]+dport[[:space:]]+/) emit_rule()
            if (formatted != "" && !inserted && $0 ~ /^[[:space:]]*}[[:space:]]*$/) emit_rule()
            if ($0 ~ /^[[:space:]]*}[[:space:]]*$/) in_input=0
        }
        { print }
        END {
            if (seen > 1) exit 1
            if (formatted != "" && !inserted) exit 1
        }
    ' "$source" > "$dest"
}

firewall_sync_target_ports() {
    local add_tcp="${1:-}" add_udp="${2:-}" drop_tcp="${3:-}" drop_udp="${4:-}"
    local quiet="${5:-0}" direct_tcp direct_udp next_tcp next_udp work_dir

    firewall_active_config_ready_for_sync || return 1
    [ -f "$FIREWALL_CONFIG" ] || return 0
    firewall_load_state || return 1
    if ! firewall_config_additive_shape_valid \
        "$FIREWALL_CONFIG" "$FW_EXTRA_TCP" "$FW_EXTRA_UDP"; then
        err "当前防火墙规则结构无法安全执行目标端口增量更新；请使用 [1] 一键开启/更新防火墙。"
        return 1
    fi
    firewall_detect_managed_ports || return 1
    add_tcp="$(normalize_port_csv "$add_tcp")" || return 1
    add_udp="$(normalize_port_csv "$add_udp")" || return 1
    drop_tcp="$(normalize_port_csv "$drop_tcp")" || return 1
    drop_udp="$(normalize_port_csv "$drop_udp")" || return 1
    direct_tcp="$(firewall_config_direct_ports "$FIREWALL_CONFIG" tcp)" || return 1
    direct_udp="$(firewall_config_direct_ports "$FIREWALL_CONFIG" udp)" || return 1
    next_tcp="$(merge_port_csv "$direct_tcp" "$add_tcp")" || return 1
    next_udp="$(merge_port_csv "$direct_udp" "$add_udp")" || return 1
    next_tcp="$(subtract_port_csv "$next_tcp" "$drop_tcp")" || return 1
    next_udp="$(subtract_port_csv "$next_udp" "$drop_udp")" || return 1
    # 当前受管来源始终优先于删除列表，避免同端口重建或端口复用时误删有效规则。
    next_tcp="$(merge_port_csv "$next_tcp" "$FW_SSH_PORTS" "$FW_NODE_TCP" "$FW_EXTRA_TCP")" || return 1
    next_udp="$(merge_port_csv "$next_udp" "$FW_NODE_UDP" "$FW_EXTRA_UDP")" || return 1
    [ -n "$next_tcp" ] || {
        err "目标端口更新会移除全部 TCP 入站端口，已拒绝应用。"
        return 1
    }

    prepare_runtime_dir || return 1
    work_dir="$(mktemp -d "$RUNTIME_DIR/firewall-target-sync.XXXXXX")" || return 1
    if ! firewall_replace_input_direct_ports \
        "$FIREWALL_CONFIG" "$work_dir/tcp.nft" tcp "$next_tcp" ||
        ! firewall_replace_input_direct_ports \
        "$work_dir/tcp.nft" "$work_dir/firewall.nft" udp "$next_udp" ||
        ! firewall_replace_active_config "$work_dir/firewall.nft"; then
        rm -rf "$work_dir"
        return 1
    fi
    rm -rf "$work_dir"
    [ "$quiet" = "1" ] || info "主机防火墙已同步本次 SSH 或节点端口，其他现有放行端口保持不变。"
}

firewall_replace_extra_port_set() {
    local source="$1" dest="$2" set_name="$3" ports="$4" anchor="$5" formatted

    ports="$(normalize_port_csv "$ports")" || return 1
    [ -n "$ports" ] || return 1
    formatted="$(printf '%s' "$ports" | sed 's/,/, /g')"
    awk -v target="$set_name" -v formatted="$formatted" -v anchor="$anchor" '
        function emit_set() {
            print "    set " target " {"
            print "        type inet_service"
            print "        elements = { " formatted " }"
            print "    }"
            print ""
            inserted=1
        }
        skipping {
            if ($0 ~ /^[[:space:]]*}[[:space:]]*$/) skipping=0
            next
        }
        $1 == "set" && $2 == target && $3 == "{" {
            seen++
            if (!inserted) emit_set()
            skipping=1
            next
        }
        !inserted && anchor != "" && $1 == "set" && $2 == anchor && $3 == "{" { emit_set() }
        !inserted && $1 == "chain" && $2 == "input" && $3 == "{" { emit_set() }
        { print }
        END { if (!inserted || skipping || seen > 1) exit 1 }
    ' "$source" > "$dest"
}

firewall_ensure_extra_guard_rule() {
    local source="$1" dest="$2" protocol="$3" rule count

    rule="        meta l4proto $protocol ct original proto-dst @extra_${protocol}_dnat_ports accept"
    count="$(grep -Fxc "$rule" "$source" || true)"
    if [ "$count" -eq 1 ]; then
        cp "$source" "$dest"
        return
    fi
    [ "$count" -eq 0 ] || return 1
    awk -v protocol="$protocol" -v rule="$rule" '
        /^[[:space:]]*chain[[:space:]]+docker_port_guard[[:space:]]*\{/ {
            in_guard=1
            print
            if (protocol == "tcp") { print rule; inserted=1 }
            next
        }
        in_guard && protocol == "udp" && $0 ~ /^[[:space:]]*meta[[:space:]]+l4proto[[:space:]]+tcp[[:space:]]+drop[[:space:]]*$/ {
            print
            print rule
            inserted=1
            next
        }
        in_guard && $0 ~ /^[[:space:]]*}[[:space:]]*$/ { in_guard=0 }
        { print }
        END { if (!inserted) exit 1 }
    ' "$source" > "$dest"
}

firewall_build_config_with_added_ports() {
    local source="$1" dest="$2" protocols="$3"
    local work_dir current next protocol direct desired set_name anchor

    case "$protocols" in tcp|udp|both) ;; *) return 2 ;; esac
    work_dir="$(mktemp -d "$(dirname "$dest")/.firewall-add-build.XXXXXX")" || return 1
    current="$work_dir/current.nft"
    cp "$source" "$current" || { rm -rf "$work_dir"; return 1; }
    for protocol in tcp udp; do
        [ "$protocols" = "both" ] || [ "$protocols" = "$protocol" ] || continue
        if [ "$protocol" = "tcp" ]; then
            desired="$FW_EXTRA_TCP"
            set_name=extra_tcp_dnat_ports
            anchor=extra_udp_dnat_ports
        else
            desired="$FW_EXTRA_UDP"
            set_name=extra_udp_dnat_ports
            anchor=""
        fi
        direct="$(firewall_config_direct_ports "$current" "$protocol")" || { rm -rf "$work_dir"; return 1; }
        direct="$(merge_port_csv "$direct" "$desired")" || { rm -rf "$work_dir"; return 1; }
        next="$work_dir/input-$protocol.nft"
        firewall_replace_input_direct_ports "$current" "$next" "$protocol" "$direct" || { rm -rf "$work_dir"; return 1; }
        current="$next"
        next="$work_dir/set-$protocol.nft"
        firewall_replace_extra_port_set "$current" "$next" "$set_name" "$desired" "$anchor" || { rm -rf "$work_dir"; return 1; }
        current="$next"
        next="$work_dir/guard-$protocol.nft"
        firewall_ensure_extra_guard_rule "$current" "$next" "$protocol" || { rm -rf "$work_dir"; return 1; }
        current="$next"
    done
    cp "$current" "$dest" || { rm -rf "$work_dir"; return 1; }
    rm -rf "$work_dir"
}

firewall_check_config_file() {
    local config="$1" table_existed=0 status=0

    command -v nft >/dev/null 2>&1 || return 1
    nft list table inet vpsbox >/dev/null 2>&1 && table_existed=1
    if [ "$table_existed" -eq 0 ] && ! nft add table inet vpsbox; then
        return 1
    fi
    nft -c -f "$config" >/dev/null 2>&1 || status=1
    [ "$table_existed" -eq 1 ] || nft delete table inet vpsbox >/dev/null 2>&1 || true
    return "$status"
}

firewall_live_added_ports_match() {
    local protocols="$1" port="$2" required_tcp="${3:-}" input_ports

    case "$protocols" in tcp|udp|both) ;; *) return 2 ;; esac
    if [ "$protocols" = "tcp" ] || [ "$protocols" = "both" ]; then
        input_ports="$(nft -nn list chain inet vpsbox input 2>/dev/null | firewall_ports_from_nft_chain tcp)" || return 1
        csv_contains_port "$input_ports" "$port" || return 1
        firewall_live_port_set_matches extra_tcp_dnat_ports "$FW_EXTRA_TCP" || return 1
    fi
    if [ "$protocols" = "udp" ] || [ "$protocols" = "both" ]; then
        input_ports="$(nft -nn list chain inet vpsbox input 2>/dev/null | firewall_ports_from_nft_chain udp)" || return 1
        csv_contains_port "$input_ports" "$port" || return 1
        firewall_live_port_set_matches extra_udp_dnat_ports "$FW_EXTRA_UDP" || return 1
    fi
    if [ -n "$required_tcp" ]; then
        input_ports="$(firewall_live_tcp_ports)" || return 1
        port_csv_is_subset "$required_tcp" "$input_ports" || return 1
    fi
}

firewall_apply_added_ports() {
    local protocols="$1" port="$2" old_tcp="$3" old_udp="$4"
    local work_dir old_direct_tcp was_runtime=0 persist_failed=0
    local new_config new_state

    case "$protocols" in tcp|udp|both) ;; *) return 2 ;; esac
    firewall_recover_pending_rollbacks || return 1
    firewall_runtime_enabled && was_runtime=1
    firewall_managed_file_is_secure "$FIREWALL_CONFIG" || {
        err "当前防火墙配置不是安全的 vpsbox 受管文件；请使用 [1] 一键开启/更新防火墙。"
        return 1
    }
    firewall_state_file_is_secure || {
        err "当前防火墙状态文件不可用；请使用 [1] 一键开启/更新防火墙。"
        return 1
    }
    if ! firewall_config_additive_shape_valid "$FIREWALL_CONFIG" "$old_tcp" "$old_udp"; then
        err "当前防火墙规则结构无法安全执行增量更新；请使用 [1] 一键开启/更新防火墙。"
        return 1
    fi

    prepare_runtime_dir || return 1
    work_dir="$(mktemp -d "$RUNTIME_DIR/firewall-add.XXXXXX")" || return 1
    new_config="$work_dir/firewall.nft"
    new_state="$work_dir/firewall.env"
    if ! firewall_build_config_with_added_ports "$FIREWALL_CONFIG" "$new_config" "$protocols" ||
        ! firewall_write_state_file "$new_state" ||
        ! firewall_check_config_file "$new_config"; then
        rm -rf "$work_dir"
        err "无法生成或校验新增端口后的防火墙配置。"
        return 1
    fi
    old_direct_tcp="$(firewall_config_direct_ports "$FIREWALL_CONFIG" tcp)" || {
        rm -rf "$work_dir"
        return 1
    }
    if ! firewall_config_keeps_tcp_ports "$new_config" "$old_direct_tcp"; then
        rm -rf "$work_dir"
        err "新增端口后的配置未保留原有 TCP 放行端口，已拒绝应用。"
        return 1
    fi
    if ! firewall_begin_additive_transaction "$old_direct_tcp" "$was_runtime"; then
        rm -rf "$work_dir"
        err "无法创建新增端口的轻量回滚事务。"
        return 1
    fi

    if [ "$was_runtime" -eq 1 ]; then
        if ! firewall_apply_config_file "$new_config" ||
            ! firewall_live_added_ports_match "$protocols" "$port" "$old_direct_tcp"; then
            err "新增端口的运行规则验证失败，正在恢复旧状态。"
            firewall_restore_additive_transaction "$ACTIVE_FIREWALL_ADDITIVE_DIR" ||
                err "旧防火墙配置未能完整恢复，轻量事务已保留：$ACTIVE_FIREWALL_ADDITIVE_DIR"
            rm -rf "$work_dir"
            return 1
        fi
    fi
    if ! firewall_install_managed_file "$new_config" "$FIREWALL_CONFIG" 600; then
        persist_failed=1
    elif ! firewall_install_managed_file "$new_state" "$FIREWALL_STATE_FILE" 600; then
        persist_failed=1
    elif ! cmp -s "$new_config" "$FIREWALL_CONFIG" ||
        ! cmp -s "$new_state" "$FIREWALL_STATE_FILE" ||
        ! firewall_config_keeps_tcp_ports "$FIREWALL_CONFIG" "$old_direct_tcp"; then
        persist_failed=1
    elif [ "$was_runtime" -eq 1 ] &&
        ! firewall_live_added_ports_match "$protocols" "$port" "$old_direct_tcp"; then
        persist_failed=1
    fi
    # committed 标记表示新文件可作为启动恢复基线；发布标记前必须先落盘。
    if [ "$persist_failed" -eq 0 ] && ! sync_node_transaction_store; then
        persist_failed=1
    fi
    if [ "$persist_failed" -ne 0 ]; then
        err "新增端口的持久化验证失败，正在恢复旧状态。"
        firewall_restore_additive_transaction "$ACTIVE_FIREWALL_ADDITIVE_DIR" ||
            err "旧防火墙配置未能完整恢复，轻量事务已保留：$ACTIVE_FIREWALL_ADDITIVE_DIR"
        rm -rf "$work_dir"
        return 1
    fi
    if ! firewall_commit_additive_transaction; then
        err "新增端口提交标记失败，正在恢复旧状态。"
        firewall_restore_additive_transaction "$ACTIVE_FIREWALL_ADDITIVE_DIR" ||
            err "旧防火墙配置未能完整恢复，轻量事务已保留：$ACTIVE_FIREWALL_ADDITIVE_DIR"
        rm -rf "$work_dir"
        return 1
    fi
    rm -rf "$work_dir"
    if [ "$was_runtime" -eq 1 ]; then
        info "已轻量放行 $protocols 端口：$port"
    else
        info "额外端口已保存；防火墙下次启动时会自动放行：$port"
    fi
}

firewall_config_matches_expected() {
    local tmp status=0
    [ -f "$FIREWALL_CONFIG" ] && [ -f "$FIREWALL_STATE_FILE" ] || return 1
    firewall_load_state || return 1
    firewall_detect_allowed_ports || return 1
    tmp="$(mktemp "$RUNTIME_DIR/firewall-check.XXXXXX")" || return 1
    firewall_write_config "$tmp" || status=1
    if [ "$status" -eq 0 ] && ! cmp -s "$tmp" "$FIREWALL_CONFIG"; then status=1; fi
    if [ "$status" -eq 0 ] && ! nft -c -f "$FIREWALL_CONFIG" >/dev/null 2>&1; then status=1; fi
    if [ "$status" -eq 0 ] && ! firewall_live_config_matches_expected; then status=1; fi
    rm -f "$tmp"
    [ "$status" -eq 0 ]
}

firewall_file_metadata_is_exact() {
    local path="$1" expected_mode="$2"

    [ -f "$path" ] && [ ! -L "$path" ] || return 1
    [ "$(stat -c '%u:%g %a' "$path" 2>/dev/null || true)" = "0:0 $expected_mode" ]
}

firewall_directory_metadata_is_exact() {
    local path="$1" expected_mode="$2"

    [ -d "$path" ] && [ ! -L "$path" ] || return 1
    [ "$(stat -c '%u:%g %a' "$path" 2>/dev/null || true)" = "0:0 $expected_mode" ]
}

firewall_persistence_is_canonical() {
    local enabled_state fragment_path reload_state entry entry_target service_target

    if is_systemd; then
        enabled_state="$(systemctl is-enabled "$FIREWALL_SERVICE_NAME" 2>/dev/null)" || return 1
        [ "$enabled_state" = "enabled" ] || return 1
        fragment_path="$(systemctl show "$FIREWALL_SERVICE_NAME" -p FragmentPath --value 2>/dev/null)" || return 1
        [ "$fragment_path" = "$FIREWALL_SYSTEMD_UNIT" ] || return 1
        reload_state="$(systemctl show "$FIREWALL_SERVICE_NAME" -p NeedDaemonReload --value 2>/dev/null)" || return 1
        [ "$reload_state" = "no" ]
    elif [ "$OS" = "alpine" ]; then
        entry="$FIREWALL_OPENRC_RUNLEVELS_DIR/default/$FIREWALL_SERVICE_NAME"
        [ -L "$entry" ] || return 1
        entry_target="$(readlink -f "$entry" 2>/dev/null)" || return 1
        service_target="$(readlink -f "$FIREWALL_OPENRC_SERVICE" 2>/dev/null)" || return 1
        [ "$entry_target" = "$service_target" ]
    else
        return 1
    fi
}

firewall_desired_state_is_current() {
    local work_dir service_file service_target service_mode status=0

    firewall_directory_metadata_is_exact "$VPSBOX_STATE_DIR" 700 || return 1
    firewall_file_metadata_is_exact "$FIREWALL_CONFIG" 600 || return 1
    firewall_file_metadata_is_exact "$FIREWALL_STATE_FILE" 600 || return 1
    firewall_runtime_enabled || return 1
    firewall_service_active || return 1
    firewall_persistence_is_canonical || return 1

    work_dir="$(mktemp -d "$RUNTIME_DIR/firewall-current.XXXXXX")" || return 1
    if is_systemd; then
        service_file="$work_dir/vpsbox-firewall.service"
        service_target="$FIREWALL_SYSTEMD_UNIT"
        service_mode=644
    else
        service_file="$work_dir/vpsbox-firewall"
        service_target="$FIREWALL_OPENRC_SERVICE"
        service_mode=755
    fi
    firewall_write_state_file "$work_dir/firewall.env" || status=1
    firewall_write_config "$work_dir/firewall.nft" || status=1
    firewall_write_service_definition "$service_file" || status=1
    if [ "$status" -eq 0 ]; then
        firewall_file_metadata_is_exact "$service_target" "$service_mode" || status=1
    fi
    if [ "$status" -eq 0 ] && ! cmp -s "$work_dir/firewall.env" "$FIREWALL_STATE_FILE"; then status=1; fi
    if [ "$status" -eq 0 ] && ! cmp -s "$work_dir/firewall.nft" "$FIREWALL_CONFIG"; then status=1; fi
    if [ "$status" -eq 0 ] && ! cmp -s "$service_file" "$service_target"; then status=1; fi
    if [ "$status" -eq 0 ] && ! nft -c -f "$FIREWALL_CONFIG" >/dev/null 2>&1; then status=1; fi
    if [ "$status" -eq 0 ] && ! firewall_live_config_matches_expected; then status=1; fi
    rm -rf -- "$work_dir" || return 1
    [ "$status" -eq 0 ]
}

firewall_live_set_ports_from_table() {
    local table_rules="$1" set_name="$2"
    local set_names body guard_rules

    set_names="$(printf '%s\n' "$table_rules" | firewall_table_object_names set)" || return 1
    case ",$set_names," in
        *",$set_name,"*) ;;
        *) return 0 ;;
    esac
    body="$(printf '%s\n' "$table_rules" | firewall_set_body_lines "$set_name")" || return 1
    guard_rules="$(printf '%s\n' "$table_rules" | firewall_chain_rule_lines docker_port_guard)" || return 1
    grep -Fq "@$set_name accept" <<< "$guard_rules" || return 1
    printf '%s\n' "$body" | firewall_discrete_port_set_values
}

firewall_read_live_allowed_ports() {
    local table_rules input_rules forward_rules
    local docker4_tcp docker4_udp docker6_tcp docker6_udp

    FW_LIVE_INPUT_TCP=""
    FW_LIVE_INPUT_UDP=""
    FW_LIVE_DOCKER_TCP=""
    FW_LIVE_DOCKER_UDP=""
    FW_LIVE_EXTRA_DNAT_TCP=""
    FW_LIVE_EXTRA_DNAT_UDP=""

    table_rules="$(nft -nn list table inet vpsbox 2>/dev/null)" || return 1
    case ",$(printf '%s\n' "$table_rules" | firewall_table_object_names chain)," in
        *,input,*) ;;
        *) return 1 ;;
    esac
    firewall_chain_base_matches input input filter 0 drop <<< "$table_rules" || return 1
    input_rules="$(printf '%s\n' "$table_rules" | firewall_chain_rule_lines input)" || return 1
    FW_LIVE_INPUT_TCP="$(printf '%s\n' "$input_rules" | firewall_ports_from_nft_chain tcp)" || return 1
    FW_LIVE_INPUT_UDP="$(printf '%s\n' "$input_rules" | firewall_ports_from_nft_chain udp)" || return 1

    docker4_tcp="$(firewall_live_set_ports_from_table "$table_rules" docker4_tcp_ports)" || return 1
    docker4_udp="$(firewall_live_set_ports_from_table "$table_rules" docker4_udp_ports)" || return 1
    docker6_tcp="$(firewall_live_set_ports_from_table "$table_rules" docker6_tcp_ports)" || return 1
    docker6_udp="$(firewall_live_set_ports_from_table "$table_rules" docker6_udp_ports)" || return 1
    FW_LIVE_DOCKER_TCP="$(merge_port_csv "$docker4_tcp" "$docker6_tcp")" || return 1
    FW_LIVE_DOCKER_UDP="$(merge_port_csv "$docker4_udp" "$docker6_udp")" || return 1
    FW_LIVE_EXTRA_DNAT_TCP="$(firewall_live_set_ports_from_table "$table_rules" extra_tcp_dnat_ports)" || return 1
    FW_LIVE_EXTRA_DNAT_UDP="$(firewall_live_set_ports_from_table "$table_rules" extra_udp_dnat_ports)" || return 1

    if [ -n "$FW_LIVE_DOCKER_TCP$FW_LIVE_DOCKER_UDP$FW_LIVE_EXTRA_DNAT_TCP$FW_LIVE_EXTRA_DNAT_UDP" ]; then
        firewall_chain_base_matches docker_forward forward -1 "filter - 1" accept <<< "$table_rules" || return 1
        forward_rules="$(printf '%s\n' "$table_rules" | firewall_chain_rule_lines docker_forward)" || return 1
        grep -Fq 'jump docker_port_guard' <<< "$forward_rules" || return 1
    fi
}

firewall_view_rules() {
    local runtime_state persistence_state

    if firewall_runtime_enabled; then
        runtime_state="运行中"
        if ! firewall_read_live_allowed_ports; then
            err "无法可靠读取当前 nftables 放行规则。"
            return 1
        fi
    else
        runtime_state="$(firewall_runtime_state)"
        FW_LIVE_INPUT_TCP=""
        FW_LIVE_INPUT_UDP=""
        FW_LIVE_DOCKER_TCP=""
        FW_LIVE_DOCKER_UDP=""
        FW_LIVE_EXTRA_DNAT_TCP=""
        FW_LIVE_EXTRA_DNAT_UDP=""
    fi
    persistence_state="$(firewall_persistence_state)"
    cat <<EOF
========================================
 当前放行端口
========================================
 类型           协议       端口
----------------------------------------
 主机入站       TCP        ${FW_LIVE_INPUT_TCP:--}
 主机入站       UDP        ${FW_LIVE_INPUT_UDP:--}
 Docker 转发    TCP        ${FW_LIVE_DOCKER_TCP:--}
 Docker 转发    UDP        ${FW_LIVE_DOCKER_UDP:--}
 额外 DNAT      TCP        ${FW_LIVE_EXTRA_DNAT_TCP:--}
 额外 DNAT      UDP        ${FW_LIVE_EXTRA_DNAT_UDP:--}
----------------------------------------
 防火墙：$runtime_state
 开机加载：$persistence_state
 出站规则：不创建
========================================
EOF
    if [ "$runtime_state" = "运行中" ]; then
        echo "说明：以上端口直接读取自当前 nftables 规则；新增服务后需执行 [1] 才会放行。"
    else
        echo "说明：当前没有正在生效的 vpsbox 防火墙规则；NAT 映射和商家安全组需单独设置。"
    fi
}

firewall_save_inactive_state() {
    local tmp
    ensure_change_store || return 1
    tmp="$(mktemp "$RUNTIME_DIR/firewall-state.XXXXXX")" || return 1
    firewall_write_state_file "$tmp" &&
        firewall_install_managed_file "$tmp" "$FIREWALL_STATE_FILE" 600 || {
            rm -f "$tmp"
            return 1
        }
    rm -f "$tmp"
}

firewall_commit_port_state() {
    if firewall_control_plane_present; then
        firewall_apply_desired_state "$FW_EXTRA_TCP" "$FW_EXTRA_UDP"
    else
        firewall_save_inactive_state
        info "额外端口已保存；启用主机防火墙时会自动使用。"
    fi
}

firewall_prompt_port() {
    local port
    read -r -p "请输入端口（1-65535）：" port || return 1
    is_valid_port "$port" || {
        err "端口必须是 1-65535 的整数。"
        return 1
    }
    printf '%s\n' "$port"
}

firewall_add_extra_port() {
    local protocol="$1" port old_tcp old_udp
    firewall_settle_pending_port_transition || return 1
    firewall_load_state || return 1
    port="$(firewall_prompt_port)" || return 1
    old_tcp="$FW_EXTRA_TCP"
    old_udp="$FW_EXTRA_UDP"
    case "$protocol" in
        tcp)
            csv_contains_port "$FW_EXTRA_TCP" "$port" && { info "额外 TCP 列表已包含端口：$port"; return 0; }
            FW_EXTRA_TCP="$(csv_add_port "$FW_EXTRA_TCP" "$port")"
            ;;
        udp)
            csv_contains_port "$FW_EXTRA_UDP" "$port" && { info "额外 UDP 列表已包含端口：$port"; return 0; }
            FW_EXTRA_UDP="$(csv_add_port "$FW_EXTRA_UDP" "$port")"
            ;;
        both)
            if csv_contains_port "$FW_EXTRA_TCP" "$port" && csv_contains_port "$FW_EXTRA_UDP" "$port"; then
                info "额外 TCP/UDP 列表已包含端口：$port"
                return 0
            fi
            FW_EXTRA_TCP="$(csv_add_port "$FW_EXTRA_TCP" "$port")"
            FW_EXTRA_UDP="$(csv_add_port "$FW_EXTRA_UDP" "$port")"
            ;;
        *) return 1 ;;
    esac
    if firewall_control_plane_present; then
        firewall_apply_added_ports "$protocol" "$port" "$old_tcp" "$old_udp"
    else
        firewall_save_inactive_state || return 1
        info "额外端口已保存；启用主机防火墙时会自动使用。"
    fi
}

firewall_remove_extra_port() {
    local protocol="$1" port
    firewall_settle_pending_port_transition || return 1
    firewall_load_state || return 1
    port="$(firewall_prompt_port)" || return 1
    case "$protocol" in
        tcp)
            csv_contains_port "$FW_EXTRA_TCP" "$port" || { warn "额外 TCP 列表中没有端口 $port。"; return 0; }
            FW_EXTRA_TCP="$(csv_remove_port "$FW_EXTRA_TCP" "$port")"
            ;;
        udp)
            csv_contains_port "$FW_EXTRA_UDP" "$port" || { warn "额外 UDP 列表中没有端口 $port。"; return 0; }
            FW_EXTRA_UDP="$(csv_remove_port "$FW_EXTRA_UDP" "$port")"
            ;;
        *) return 1 ;;
    esac
    firewall_commit_port_state
}

firewall_clear_extra_ports() {
    local answer
    firewall_settle_pending_port_transition || return 1
    firewall_load_state || return 1
    read -r -p "清空所有额外 TCP/UDP 放行端口？请输入 YES：" answer || return 1
    [ "$answer" = "YES" ] || { info "已取消。"; return 0; }
    FW_EXTRA_TCP=""
    FW_EXTRA_UDP=""
    firewall_commit_port_state
}

firewall_extra_ports_menu() {
    local opt
    while true; do
        firewall_load_state || return 1
        clear 2>/dev/null || true
        cat <<EOF
========================================
 额外放行端口
========================================
 TCP：${FW_EXTRA_TCP:--}
 UDP：${FW_EXTRA_UDP:--}
----------------------------------------
 [1] 添加 TCP 端口
 [2] 添加 UDP 端口
 [3] 同时添加 TCP/UDP 端口
 [4] 删除 TCP 端口
 [5] 删除 UDP 端口
 [6] 清空额外端口
----------------------------------------
 [0] 返回主机防火墙
========================================
EOF
        read -r -p "请输入选项: " opt || return 0
        echo ""
        case "$opt" in
            1) run_menu_action firewall_add_extra_port tcp; pause ;;
            2) run_menu_action firewall_add_extra_port udp; pause ;;
            3) run_menu_action firewall_add_extra_port both; pause ;;
            4) run_menu_action firewall_remove_extra_port tcp; pause ;;
            5) run_menu_action firewall_remove_extra_port udp; pause ;;
            6) run_menu_action firewall_clear_extra_ports; pause ;;
            0) return 0 ;;
            *) warn "无效选项：$opt"; pause ;;
        esac
    done
}

firewall_disable_internal() {
    local failed=0

    firewall_settle_pending_port_transition || return 1
    firewall_recover_pending_rollbacks || return 1
    if firewall_control_plane_present && ! command -v nft >/dev/null 2>&1; then
        err "缺少 nft 命令，无法确认并删除当前 vpsbox 规则表。"
        return 1
    fi
    if is_systemd; then
        systemctl disable --now "$FIREWALL_SERVICE_NAME" >/dev/null 2>&1 || true
        systemctl is-active --quiet "$FIREWALL_SERVICE_NAME" 2>/dev/null && failed=1
        systemctl is-enabled --quiet "$FIREWALL_SERVICE_NAME" 2>/dev/null && failed=1
    elif [ "$OS" = "alpine" ]; then
        rc-service "$FIREWALL_SERVICE_NAME" stop >/dev/null 2>&1 || true
        rc-update del "$FIREWALL_SERVICE_NAME" default >/dev/null 2>&1 || true
        rc-service "$FIREWALL_SERVICE_NAME" status >/dev/null 2>&1 && failed=1
        { [ -e "$FIREWALL_OPENRC_RUNLEVELS_DIR/default/$FIREWALL_SERVICE_NAME" ] ||
            [ -L "$FIREWALL_OPENRC_RUNLEVELS_DIR/default/$FIREWALL_SERVICE_NAME" ]; } && failed=1
    fi
    if command -v nft >/dev/null 2>&1; then
        nft delete table inet vpsbox >/dev/null 2>&1 || true
        nft list table inet vpsbox >/dev/null 2>&1 && failed=1
    fi
    [ "$failed" -eq 0 ] || {
        err "无法完整停止防火墙服务或删除 inet vpsbox 规则表，已保留管理文件便于重试。"
        return 1
    }
    if ! rm -f "$FIREWALL_CONFIG" "$FIREWALL_STATE_FILE" \
        "$FIREWALL_SYSTEMD_UNIT" "$FIREWALL_OPENRC_SERVICE"; then
        err "防火墙已停止，但管理文件删除失败。"
        return 1
    fi
    is_systemd && systemctl daemon-reload >/dev/null 2>&1 || true
    info "vpsbox 主机防火墙已关闭；其他程序的规则未被修改。"
}

firewall_disable() {
    local answer
    firewall_recover_pending_rollbacks || return 1
    if ! firewall_artifacts_present; then
        info "主机防火墙未启用，无需关闭。"
        return 0
    fi
    read -r -p "关闭后将不再由 vpsbox 限制入站连接，输入 YES 确认：" answer || return 1
    [ "$answer" = "YES" ] || { info "已取消。"; return 0; }
    firewall_disable_internal
}

firewall_menu() {
    local opt ssh_ports node_tcp node_udp docker_tcp docker_udp public_tcp public_udp protocol
    local ssh_known node_tcp_known node_udp_known docker_tcp_known docker_udp_known known_tcp known_udp

    firewall_settle_pending_port_transition || return 1
    while true; do
        firewall_load_state || return 1
        ssh_ports="$(ssh_effective_ports_csv 2>/dev/null || echo "-")"
        node_tcp="-"
        node_udp="-"
        for protocol in vless ss; do
            if load_protocol_state "$protocol" >/dev/null 2>&1; then
                [ "$node_tcp" = "-" ] && node_tcp=""
                node_tcp="$(csv_add_port "$node_tcp" "$PORT")"
                if [ "$protocol" = "ss" ]; then
                    [ "$node_udp" = "-" ] && node_udp=""
                    node_udp="$(csv_add_port "$node_udp" "$PORT")"
                fi
            fi
        done
        node_tcp="${node_tcp:--}"
        node_udp="${node_udp:--}"
        docker_tcp="-"
        docker_udp="-"
        if firewall_docker_available; then
            if firewall_detect_docker_ports; then
                docker_tcp="${FW_DOCKER_PUBLIC_TCP:--}"
                docker_udp="${FW_DOCKER_PUBLIC_UDP:--}"
            fi
        elif command -v docker >/dev/null 2>&1; then
            docker_tcp="daemon 不可用"
            docker_udp="daemon 不可用"
        fi
        public_tcp="-"
        public_udp="-"
        if firewall_detect_public_listeners 2>/dev/null; then
            ssh_known="$(normalize_port_csv "$ssh_ports" 2>/dev/null || true)"
            node_tcp_known="$(normalize_port_csv "$node_tcp" 2>/dev/null || true)"
            node_udp_known="$(normalize_port_csv "$node_udp" 2>/dev/null || true)"
            docker_tcp_known="$(normalize_port_csv "$docker_tcp" 2>/dev/null || true)"
            docker_udp_known="$(normalize_port_csv "$docker_udp" 2>/dev/null || true)"
            known_tcp="$(merge_port_csv "$ssh_known" "$node_tcp_known" "$docker_tcp_known" "$FW_EXTRA_TCP")"
            known_udp="$(merge_port_csv "$node_udp_known" "$docker_udp_known" "$FW_EXTRA_UDP")"
            public_tcp="$(subtract_port_csv "$FW_PUBLIC_TCP" "$known_tcp")"
            public_udp="$(subtract_port_csv "$FW_PUBLIC_UDP" "$known_udp")"
            public_tcp="${public_tcp:--}"
            public_udp="${public_udp:--}"
        fi

        clear 2>/dev/null || true
        cat <<EOF
========================================
 主机防火墙
========================================
 nftables：$(firewall_install_state)
 防火墙：$(firewall_runtime_state)
 开机加载：$(firewall_persistence_state)
----------------------------------------
 SSH TCP：$ssh_ports
 节点 TCP：$node_tcp
 节点 UDP：$node_udp
 Docker TCP：$docker_tcp
 Docker UDP：$docker_udp
 其他公网 TCP：$public_tcp
 其他公网 UDP：$public_udp
 额外 TCP：${FW_EXTRA_TCP:--}
 额外 UDP：${FW_EXTRA_UDP:--}
 默认入站：拒绝未放行的连接
 出站规则：不创建
----------------------------------------
 [1] 一键开启/更新防火墙
 [2] 查看当前放行端口
 [3] 管理额外放行端口
 [4] 关闭并移除 vpsbox 防火墙
----------------------------------------
 [0] 返回主菜单
========================================
EOF
        read -r -p "请输入选项: " opt || return 0
        echo ""
        case "$opt" in
            1) run_menu_action firewall_apply_desired_state; pause ;;
            2) run_menu_action firewall_view_rules; pause ;;
            3) firewall_extra_ports_menu ;;
            4) run_menu_action firewall_disable; pause ;;
            0) return 0 ;;
            *) warn "无效选项：$opt"; pause ;;
        esac
    done
}

# ==============================================================================
# 7. 检测：一键检测
# ==============================================================================
check_table_header() {
    cat <<'EOF'
----------------------------------------
 状态   | 项目             | 结果
--------+------------------+------------
EOF
}

check_table_footer() {
    cat <<'EOF'
--------+------------------+------------
EOF
}

display_width() {
    local text="$1"
    local i ch width=0

    for ((i = 0; i < ${#text}; i++)); do
        ch="${text:i:1}"
        case "$ch" in
            [[:ascii:]]) width=$((width + 1)) ;;
            *) width=$((width + 2)) ;;
        esac
    done

    printf '%s' "$width"
}

pad_right_display() {
    local text="$1"
    local target_width="$2"
    local width
    local padding

    width="$(display_width "$text")"
    padding=$((target_width - width))
    [ "$padding" -lt 0 ] && padding=0

    printf '%s' "$text"
    printf '%*s' "$padding" ''
}

check_row() {
    case "$1" in
        OK) CHECK_OK_COUNT=$(( ${CHECK_OK_COUNT:-0} + 1 )) ;;
        INFO) CHECK_INFO_COUNT=$(( ${CHECK_INFO_COUNT:-0} + 1 )) ;;
        WARN) CHECK_WARN_COUNT=$(( ${CHECK_WARN_COUNT:-0} + 1 )) ;;
        FAIL) CHECK_FAIL_COUNT=$(( ${CHECK_FAIL_COUNT:-0} + 1 )) ;;
    esac
    printf ' %-6s | ' "$1"
    pad_right_display "$2" 16
    printf ' | %s\n' "${3:-}"
}

check_ok() {
    check_row "OK" "$1" "${2:-}"
}

check_warn() {
    check_row "WARN" "$1" "${2:-}"
}

check_info() {
    check_row "INFO" "$1" "${2:-}"
}

check_fail() {
    check_row "FAIL" "$1" "${2:-}"
}

public_ipv4() {
    command -v curl >/dev/null 2>&1 || return 1
    curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null
}

resolve_host_ips() {
    local host="$1" time_limit="${2:-12}"
    local output

    [[ "$time_limit" =~ ^[1-9][0-9]*$ ]] || return 1
    command -v getent >/dev/null 2>&1 || return 1
    output="$(run_bounded_command "$time_limit" getent ahosts "$host" 2>/dev/null)" || return 1
    printf '%s\n' "$output" |
        awk '!seen[$1]++ { print $1; count++; if (count == 5) exit }'
}

run_self_check() {
    local has_node="0"
    local has_node_artifacts="0"
    local node_integrity_failed="0"
    local max_use
    local max_file
    local state node_protocols protocol protocol_status label detail ports_report uri_cache_state
    local config_state service_state listener_ok listener_fail
    local install_metadata installed_version installed_at
    local bbr_config_expected=0 ipv4_priority_expected=0
    local singbox_available=0
    local CHECK_OK_COUNT=0
    local CHECK_INFO_COUNT=0
    local CHECK_WARN_COUNT=0
    local CHECK_FAIL_COUNT=0

    detect_os

    cat <<EOF
========================================
 一键检测
========================================
EOF
    check_table_header

    if [ "$(id -u)" = "0" ]; then
        check_ok "运行用户" "root"
    else
        check_fail "运行用户" "不是 root"
    fi

    if [ -x "$CMD_PATH" ]; then
        check_ok "vpsbox 命令" "$CMD_PATH"
    else
        check_warn "vpsbox 命令" "未安装到 $CMD_PATH"
    fi
    if install_metadata="$(install_metadata_read 2>/dev/null)"; then
        installed_version="${install_metadata%%$'\n'*}"
        installed_at="${install_metadata#*$'\n'}"
        if [ "$installed_version" = "unknown" ]; then
            check_info "首次安装" "历史未记录"
        else
            check_ok "首次安装" "$installed_version / $installed_at"
        fi
    elif [ -e "$INSTALL_METADATA_FILE" ] || [ -L "$INSTALL_METADATA_FILE" ]; then
        check_warn "首次安装" "记录异常"
    else
        check_info "首次安装" "历史未记录"
    fi

    check_ok "运行时间" "$(uptime -p 2>/dev/null || echo "无法检测")"
    check_ok "系统时间" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    state="$(ntp_sync_state)"
    case "$state" in
        已同步) check_ok "NTP 同步" "$state" ;;
        未安装|不支持) check_info "NTP 同步" "$state" ;;
        未运行) check_fail "NTP 同步" "$state" ;;
        *) check_warn "NTP 同步" "$state" ;;
    esac

    if node_core_artifacts_present; then
        has_node_artifacts="1"
        if ! require_valid_node_state_if_present >/dev/null 2>&1; then
            node_integrity_failed="1"
            check_fail "配置完整性" "未通过"
        fi
    fi
    if singbox_installed; then
        singbox_available=1
        check_ok "sing-box" "$(singbox_version)"
    elif [ "$has_node_artifacts" = "1" ]; then
        check_fail "sing-box" "未安装，现有节点无法运行"
    else
        check_info "sing-box" "未安装"
    fi
    for protocol in vless ss; do
        protocol_status="$(protocol_node_status "$protocol" 2>/dev/null || true)"
        case "$protocol_status" in
            normal|deviated) ;;
            *) continue ;;
        esac
        load_protocol_state "$protocol" >/dev/null 2>&1 || continue
        has_node="1"
        [ "$protocol" = "vless" ] && label="VLESS Reality" || label="Shadowsocks"
        if [ "$protocol" = "vless" ]; then
            node_protocols=tcp
            listener_ok="TCP 监听正常"
            listener_fail="TCP 未监听"
        else
            node_protocols=both
            listener_ok="TCP、UDP 监听正常"
            listener_fail="TCP、UDP 未完整监听"
        fi
        if port_listener_ready "$PORT" "$node_protocols"; then
            check_ok "$label 节点" "${DOMAIN:-未知}:${PORT:-未知} / $listener_ok"
        else
            check_fail "$label 节点" "${DOMAIN:-未知}:${PORT:-未知} / $listener_fail"
        fi
        if [ "$protocol_status" = "deviated" ]; then
            check_warn "$label 模板" "已偏离 vpsbox 管理模板"
        fi
        if [ "$protocol" = "vless" ]; then
            check_ok "Reality SNI" "${REALITY_SERVER_NAME:-未知}"
        fi
    done
    if [ "$has_node" != "1" ] && [ "$node_integrity_failed" != "1" ]; then
        check_info "节点" "未创建"
    fi

    if [ "$has_node" = "1" ] && [ "$singbox_available" -eq 1 ]; then
        service_state="$(service_status_short)"
        if [ "$node_integrity_failed" = "1" ]; then
            if [ "$service_state" = "运行中" ]; then
                check_ok "sing-box 状态" "$service_state"
            else
                check_fail "sing-box 状态" "$service_state"
            fi
        else
            if check_active_node_config >/dev/null 2>&1; then
                config_state="配置正常"
            else
                config_state="配置未通过"
            fi
            detail="$config_state / $service_state"
            if [ "$config_state" = "配置正常" ] && [ "$service_state" = "运行中" ]; then
                check_ok "sing-box 状态" "$detail"
            else
                check_fail "sing-box 状态" "$detail"
            fi
        fi
    fi

    if [ "$has_node" = "1" ] || node_uri_artifacts_present; then
        uri_cache_state="$(node_uri_cache_status 2>/dev/null || true)"
        case "$uri_cache_state" in
            current) check_ok "节点链接" "$URI_FILE" ;;
            stale) check_warn "节点链接" "缺失或已过期" ;;
            unsafe) check_fail "节点链接" "文件不安全，已拒绝自动覆盖" ;;
            *) check_warn "节点链接" "状态无法确认" ;;
        esac
    fi

    local ip
    ip="$(public_ipv4 || true)"
    if [ -n "$ip" ] && is_ipv4_address "$ip"; then
        check_ok "公网 IPv4" "$ip"
    else
        check_warn "公网 IPv4" "获取失败"
    fi

    state="$(ssh_port_state || true)"
    [ -n "$state" ] || state="无法读取"
    if ssh_effective_ports_listening; then
        check_ok "SSH 端口" "$state"
    else
        check_fail "SSH 端口" "$state"
    fi
    if ! fail2ban_installed; then
        check_info "Fail2ban" "未安装"
    elif fail2ban_sshd_configuration_healthy; then
        check_ok "Fail2ban" "运行中，SSH 防护已启用"
    else
        state="$(fail2ban_service_state)"
        if [ "$state" != "运行中" ]; then
            detail="已安装，但服务$state"
        elif ! fail2ban_service_is_enabled; then
            detail="已安装，但未启用自启"
        else
            state="$(fail2ban_sshd_state)"
            if [ "$state" = "已启用" ]; then
                detail="已安装，但配置或 nftables 后端异常"
            else
                detail="已安装，但 SSH 防护$state"
            fi
        fi
        check_fail "Fail2ban" "$detail"
    fi

    if ! firewall_control_plane_present; then
        if [ -e "$FIREWALL_STATE_FILE" ] || [ -L "$FIREWALL_STATE_FILE" ]; then
            if firewall_state_file_is_secure && (firewall_load_state >/dev/null 2>&1); then
                check_info "主机防火墙" "未启用，已保存额外端口"
            else
                check_fail "主机防火墙" "未启用，但状态文件不完整或不安全"
            fi
        else
            check_info "主机防火墙" "未启用（如已使用厂商安全组可忽略）"
        fi
    elif ! firewall_managed_file_is_secure "$FIREWALL_CONFIG" ||
        ! firewall_state_file_is_secure; then
        check_fail "主机防火墙" "配置文件不完整或不安全"
    elif ! firewall_runtime_enabled; then
        check_fail "主机防火墙" "配置存在但规则未运行"
    else
        check_ok "主机防火墙" "运行中"
        if firewall_persistence_enabled && firewall_service_active; then
            check_ok "防火墙自启" "已启用"
        else
            check_fail "防火墙自启" "未正常启用"
        fi
        if firewall_config_matches_expected >/dev/null 2>&1; then
            check_ok "防火墙端口" "与 SSH/节点/Docker/公网监听状态一致"
        else
            check_fail "防火墙端口" "配置已过期，请执行防火墙更新"
        fi
    fi

    if change_applied_recorded_readonly GAI_CONF; then
        ipv4_priority_expected=1
    fi
    state="$(ipv4_priority_state)"
    if [ "$state" = "已启用" ]; then
        check_ok "IPv4 优先" "$state"
    elif [ "$ipv4_priority_expected" -eq 1 ]; then
        check_fail "IPv4 优先" "配置记录存在但未生效"
    else
        check_info "IPv4 优先" "$state"
    fi

    state="$(ipv6_summary_state)"
    case "$state" in
        已禁用|已启用（*个全局地址）) check_ok "IPv6" "$state" ;;
        "已禁用（非 vpsbox 配置）"|"未检测到全局 IPv6") check_info "IPv6" "$state" ;;
        "禁用配置存在但未生效"|配置异常) check_fail "IPv6" "$state" ;;
        *) check_warn "IPv6" "$state" ;;
    esac

    if [ -e "$BBR_CONF" ] || [ -L "$BBR_CONF" ] || change_applied_recorded_readonly BBR_CONF; then
        bbr_config_expected=1
    fi
    state="$(bbr_state)"
    if [ "$state" = "已启用" ]; then
        check_ok "BBR" "$state"
    elif [ "$bbr_config_expected" -eq 1 ]; then
        check_fail "BBR" "配置存在但未生效"
    else
        check_info "BBR" "$state"
    fi
    state="$(fq_state)"
    if [ "$state" = "已启用" ]; then
        check_ok "fq" "$state"
    elif [ "$bbr_config_expected" -eq 1 ]; then
        check_fail "fq" "配置存在但未生效"
    else
        check_info "fq" "$state"
    fi
    state="$(tcp_buffer_summary_state)"
    case "$state" in
        *未生效*|*未开启*|配置异常) check_fail "TCP 缓冲区" "$state" ;;
        第一档*|第二档*|第三档*) check_ok "TCP 缓冲区" "$state" ;;
        *) check_info "TCP 缓冲区" "$state" ;;
    esac

    state="$(journald_limit_state)"
    if [ "$state" = "不支持" ]; then
        check_info "日志限制" "$state"
    elif [ -e "$JOURNALD_VPSBOX_CONF" ] || [ -L "$JOURNALD_VPSBOX_CONF" ]; then
        if [ "$state" = "已配置" ] &&
            [ -f "$JOURNALD_VPSBOX_CONF" ] && [ ! -L "$JOURNALD_VPSBOX_CONF" ] &&
            [ "$(stat -c '%u:%g %a' "$JOURNALD_VPSBOX_CONF" 2>/dev/null || true)" = "0:0 644" ]; then
            max_use="$(journald_conf_value SystemMaxUse || echo "未配置")"
            max_file="$(journald_conf_value SystemMaxFileSize || echo "未配置")"
            check_ok "日志限制" "总上限 $max_use / 单文件 $max_file"
        else
            check_fail "日志限制" "配置存在但未按预期生效或不安全"
        fi
    elif [ "$state" = "已配置" ]; then
        max_use="$(journald_conf_value SystemMaxUse || echo "未配置")"
        max_file="$(journald_conf_value SystemMaxFileSize || echo "未配置")"
        check_ok "日志限制" "总上限 $max_use / 单文件 $max_file"
    else
        check_info "日志限制" "$state"
    fi
    state="$(journal_disk_usage)"
    if [ "$state" = "无法检测" ]; then check_warn "日志占用" "$state"; else check_ok "日志占用" "$state"; fi

    if [ "$(reboot_required_state)" = "需要" ]; then
        check_warn "系统重启" "需要重启"
    else
        check_ok "系统重启" "不需要重启"
    fi

    if ports_report="$(show_ports_security_group 2>&1)"; then
        check_table_footer
        printf '%s\n' "$ports_report"
    else
        check_warn "端口扫描" "未完成"
        check_table_footer
        [ -z "$ports_report" ] || printf '%s\n' "$ports_report"
    fi
    printf '\n检测结果：OK %s / INFO %s / WARN %s / FAIL %s\n' \
        "$CHECK_OK_COUNT" "$CHECK_INFO_COUNT" "$CHECK_WARN_COUNT" "$CHECK_FAIL_COUNT"
}

# ==============================================================================
# 8. 维护、恢复与末端菜单动作
# ==============================================================================
uninstall_singbox_and_nodes() {
    local failed=0 package_remove_failed=0
    local was_active=0 was_enabled=0

    if service_is_running; then
        was_active=1
    fi
    if service_is_enabled; then
        was_enabled=1
    fi

    info "正在停止并禁用 sing-box 服务..."
    service_stop 2>/dev/null || warn "服务管理器未能正常停止 sing-box，将继续检查 vpsbox 配置对应的进程。"
    if ! stop_singbox_config_processes; then
        err "残留 sing-box 进程无法停止，已取消删除。"
        return 1
    fi
    sleep 1
    if service_is_running; then
        err "sing-box 服务仍在运行，已取消删除。"
        return 1
    fi
    service_disable 2>/dev/null ||
        warn "无法通过服务管理器禁用 sing-box，将继续清理并在最后复核。"

    if [ "$OS" = "alpine" ]; then
        if singbox_package_installed &&
            ! apk_bounded "$PACKAGE_INSTALL_TIMEOUT" del sing-box; then
            package_remove_failed=1
        fi
    elif [ "$OS" = "debian" ]; then
        if singbox_package_installed &&
            ! apt_get_bounded "$PACKAGE_INSTALL_TIMEOUT" purge -y sing-box; then
            package_remove_failed=1
        fi
    elif [ "$OS" = "redhat" ]; then
        if singbox_package_installed; then
            if command -v dnf >/dev/null 2>&1; then
                dnf_bounded "$PACKAGE_INSTALL_TIMEOUT" remove -y sing-box ||
                    package_remove_failed=1
            else
                yum_bounded "$PACKAGE_INSTALL_TIMEOUT" remove -y sing-box ||
                    package_remove_failed=1
            fi
        fi
    fi

    if [ "$package_remove_failed" -eq 1 ]; then
        err "sing-box 软件包卸载失败，vpsbox 未继续删除服务文件、二进制或节点配置。"
        if restore_singbox_service_state "$was_enabled" "$was_active"; then
            info "已恢复 sing-box 原运行与自启状态。"
        else
            err "sing-box 原服务状态恢复失败，请立即检查服务、软件包和节点配置。"
        fi
        return 1
    fi

    if is_systemd; then
        rm -f /etc/systemd/system/sing-box.service \
            /etc/systemd/system/multi-user.target.wants/sing-box.service \
            /usr/lib/systemd/system/sing-box.service \
            /lib/systemd/system/sing-box.service || failed=1
        systemctl daemon-reload 2>/dev/null || failed=1
        systemctl reset-failed sing-box 2>/dev/null || true
    elif [ "$OS" = "alpine" ]; then
        rm -f /etc/init.d/sing-box /etc/runlevels/default/sing-box || failed=1
    fi

    info "正在删除 sing-box 和节点配置..."
    [ "$CONFIG_DIR" = "/etc/sing-box" ] || {
        err "sing-box 配置目录异常，已拒绝递归删除：$CONFIG_DIR"
        return 1
    }
    rm -rf -- "$CONFIG_DIR" || failed=1
    rm -f /usr/bin/sing-box /usr/local/bin/sing-box || failed=1
    rm -f /var/log/sing-box* || failed=1
    hash -r

    if service_is_running || service_is_enabled || singbox_artifacts_present; then
        err "仍检测到 sing-box 的进程、软件包、服务或配置残留。"
        failed=1
    fi
    if [ "$failed" -ne 0 ]; then
        err "sing-box 卸载未完整通过验收，已保留 vpsbox 管理命令便于重试。"
        return 1
    fi

    info "sing-box 和节点配置已删除。"
}

uninstall_all() {
    local confirm
    local remove_singbox=""
    local remove_firewall=""
    local has_singbox=0
    local has_firewall=0

    echo "此操作会卸载 vpsbox 管理命令。"
    echo "默认不会删除 sing-box，也不会删除节点配置。"
    echo "如有已记录的系统设置，卸载前可选择恢复。"
    if ! read -r -p "确认卸载 vpsbox？请输入 YES：" confirm; then
        info "输入已结束，已取消卸载。"
        return 0
    fi
    [ "$confirm" = "YES" ] || { info "已取消。"; return 0; }

    if firewall_artifacts_present; then
        has_firewall=1
        echo "检测到由 vpsbox 管理的主机防火墙。"
        if ! read -r -p "卸载前必须关闭并移除该防火墙，输入 YES 继续：" remove_firewall; then
            info "输入已结束，已取消卸载。"
            return 0
        fi
        if [ "$remove_firewall" != "YES" ]; then
            info "已取消卸载，主机防火墙和 vpsbox 命令均已保留。"
            return 0
        fi
    fi

    if ! singbox_artifacts_present; then
        info "未安装 sing-box，无需删除节点配置。"
    else
        has_singbox=1
        if ! read -r -p "是否同时删除 sing-box 和所有节点配置？请输入 YES 确认：" remove_singbox; then
            info "输入已结束，已取消卸载。"
            return 0
        fi
    fi

    offer_restore_recorded_changes_before_uninstall || {
        err "系统设置恢复未完成，已取消卸载并保留 vpsbox 管理命令。"
        return 1
    }

    if [ "$has_firewall" -eq 1 ]; then
        firewall_disable_internal || {
            err "主机防火墙未能完整移除，已取消卸载 vpsbox。"
            return 1
        }
    fi

    if [ "$has_singbox" -eq 1 ]; then
        if [ "$remove_singbox" = "YES" ]; then
            uninstall_singbox_and_nodes || {
                err "sing-box 卸载未完成，已保留 vpsbox 管理命令便于重试。"
                return 1
            }
        else
            info "已保留 sing-box 和节点配置。"
        fi
    fi

    info "正在删除 vpsbox 命令..."
    if ! rm -f "$CMD_PATH" "$CMD_ALIAS_PATH" ||
        [ -e "$CMD_PATH" ] || [ -L "$CMD_PATH" ] ||
        [ -e "$CMD_ALIAS_PATH" ] || [ -L "$CMD_ALIAS_PATH" ]; then
        err "vpsbox 管理命令删除失败，请检查 $CMD_PATH 与 $CMD_ALIAS_PATH。"
        return 1
    fi

    info "卸载完成。"
    info "vpsbox 命令已删除，当前菜单即将退出。"
    exit 0
}

is_valid_hostname_value() {
    local value="$1"
    [ -n "$value" ] && [ "${#value}" -le 64 ] || return 1
    [[ "$value" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || return 1
    local label
    IFS='.' read -ra labels <<< "$value"
    for label in "${labels[@]}"; do
        [ -n "$label" ] && [ "${#label}" -le 63 ] || return 1
        [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
    done
}

hostname_current_value() {
    if is_systemd && command -v hostnamectl >/dev/null 2>&1; then
        hostnamectl --static 2>/dev/null || hostname 2>/dev/null
    else
        hostname 2>/dev/null
    fi
}

set_system_hostname() {
    local value="$1"
    if is_systemd && command -v hostnamectl >/dev/null 2>&1; then
        hostnamectl set-hostname "$value"
    else
        hostname "$value"
    fi
}

hostname_hosts_markers_valid() {
    local begin_count end_count begin_line end_line

    [ -f "$HOSTS_PATH" ] && [ ! -L "$HOSTS_PATH" ] || return 1
    begin_count="$(grep -Fxc "$HOSTNAME_BEGIN" "$HOSTS_PATH" 2>/dev/null || true)"
    end_count="$(grep -Fxc "$HOSTNAME_END" "$HOSTS_PATH" 2>/dev/null || true)"
    if [ "$begin_count" = "0" ] && [ "$end_count" = "0" ]; then
        return 0
    fi
    [ "$begin_count" = "1" ] && [ "$end_count" = "1" ] || return 1
    begin_line="$(grep -Fnx "$HOSTNAME_BEGIN" "$HOSTS_PATH" | cut -d: -f1)"
    end_line="$(grep -Fnx "$HOSTNAME_END" "$HOSTS_PATH" | cut -d: -f1)"
    [ "$begin_line" -lt "$end_line" ]
}

hostname_short_name() {
    printf '%s\n' "${1%%.*}"
}

change_system_hostname() {
    local old new short_name hosts_entry hostname_tmp="" hosts_tmp=""
    local hostname_file_value runtime_value hosts_state

    old="$(hostname_current_value)" || {
        err "无法读取当前主机名，已取消修改。"
        return 1
    }
    [ -n "$old" ] || {
        err "当前主机名为空，已取消修改。"
        return 1
    }
    echo "当前主机名：$old"
    if ! read -r -p "请输入新主机名（留空取消）: " new; then
        info "输入已结束，已取消。"
        return 0
    fi
    new="$(sanitize_paste_input "$new")"
    [ -n "$new" ] || { info "已取消。"; return 0; }
    is_valid_hostname_value "$new" || { err "主机名格式不正确：仅允许字母、数字、点和连字符，长度不超过 64。"; return 1; }
    [ "$new" != "$old" ] || { info "新旧主机名相同。"; return 0; }
    if [ -L "$HOSTNAME_PATH" ] ||
        { [ -e "$HOSTNAME_PATH" ] && [ ! -f "$HOSTNAME_PATH" ]; }; then
        err "$HOSTNAME_PATH 不是安全的普通文件，已拒绝修改。"
        return 1
    fi
    hostname_hosts_markers_valid || { err "$HOSTS_PATH 是符号链接或 vpsbox 主机名标记异常，已拒绝修改。"; return 1; }

    short_name="$(hostname_short_name "$new")"
    hosts_entry="127.0.1.1 $new"
    [ "$short_name" = "$new" ] || hosts_entry+=" $short_name"

    hostname_tmp="$(mktemp "$(dirname "$HOSTNAME_PATH")/.hostname.vpsbox.XXXXXX")" || {
        err "无法创建 $HOSTNAME_PATH 的临时文件，系统未修改。"
        return 1
    }
    if ! printf '%s\n' "$new" > "$hostname_tmp" ||
        ! chown root:root "$hostname_tmp" || ! chmod 644 "$hostname_tmp"; then
        rm -f -- "$hostname_tmp"
        err "生成 $HOSTNAME_PATH 的新内容失败，系统未修改。"
        return 1
    fi

    hosts_tmp="$(mktemp "$(dirname "$HOSTS_PATH")/.hosts.vpsbox.XXXXXX")" || {
        rm -f -- "$hostname_tmp"
        err "无法创建 $HOSTS_PATH 的临时文件，系统未修改。"
        return 1
    }
    if ! awk -v begin="$HOSTNAME_BEGIN" -v end="$HOSTNAME_END" '
        $0 == begin { skip=1; next }
        $0 == end { skip=0; next }
        !skip { print }
    ' "$HOSTS_PATH" > "$hosts_tmp"; then
        rm -f -- "$hostname_tmp" "$hosts_tmp"
        err "读取 $HOSTS_PATH 失败，系统未修改。"
        return 1
    fi
    if ! {
        printf '%s\n' "$HOSTNAME_BEGIN" &&
            printf '%s\n' "$hosts_entry" &&
            printf '%s\n' "$HOSTNAME_END"
    } >> "$hosts_tmp" ||
        ! chown root:root "$hosts_tmp" || ! chmod 644 "$hosts_tmp"; then
        rm -f -- "$hostname_tmp" "$hosts_tmp"
        err "生成 $HOSTS_PATH 的新内容失败，系统未修改。"
        return 1
    fi

    if ! mv -f -- "$hostname_tmp" "$HOSTNAME_PATH"; then
        rm -f -- "$hostname_tmp" "$hosts_tmp"
        err "写入 $HOSTNAME_PATH 失败，运行时主机名和 $HOSTS_PATH 未修改。"
        return 1
    fi
    hostname_tmp=""
    if ! set_system_hostname "$new"; then
        rm -f -- "$hosts_tmp"
        hostname_file_value="$(tr -d '\r\n' <"$HOSTNAME_PATH" 2>/dev/null || true)"
        runtime_value="$(hostname_current_value 2>/dev/null || true)"
        [ -n "$hostname_file_value" ] || hostname_file_value="<空或无法读取>"
        [ -n "$runtime_value" ] || runtime_value="<空或无法读取>"
        err "运行时主机名设置命令失败，$HOSTS_PATH 未修改。"
        err "当前状态：$HOSTNAME_PATH=$hostname_file_value；运行时主机名=$runtime_value；$HOSTS_PATH=未发布。"
        return 1
    fi
    if ! mv -f -- "$hosts_tmp" "$HOSTS_PATH"; then
        rm -f -- "$hosts_tmp"
        hostname_file_value="$(tr -d '\r\n' <"$HOSTNAME_PATH" 2>/dev/null || true)"
        runtime_value="$(hostname_current_value 2>/dev/null || true)"
        [ -n "$hostname_file_value" ] || hostname_file_value="<空或无法读取>"
        [ -n "$runtime_value" ] || runtime_value="<空或无法读取>"
        err "$HOSTS_PATH 更新失败。"
        err "当前状态：$HOSTNAME_PATH=$hostname_file_value；运行时主机名=$runtime_value；$HOSTS_PATH=未发布。"
        return 1
    fi
    hosts_tmp=""

    hostname_file_value="$(tr -d '\r\n' <"$HOSTNAME_PATH" 2>/dev/null || true)"
    runtime_value="$(hostname_current_value 2>/dev/null || true)"
    if grep -Fqx "$hosts_entry" "$HOSTS_PATH"; then
        hosts_state="已发布"
    else
        hosts_state="未检测到目标条目"
    fi
    if [ "$hostname_file_value" != "$new" ] ||
        [ "$runtime_value" != "$new" ] || [ "$hosts_state" != "已发布" ]; then
        [ -n "$hostname_file_value" ] || hostname_file_value="<空或无法读取>"
        [ -n "$runtime_value" ] || runtime_value="<空或无法读取>"
        err "主机名修改后的验证未通过。"
        err "当前状态：$HOSTNAME_PATH=$hostname_file_value；运行时主机名=$runtime_value；$HOSTS_PATH=$hosts_state。"
        return 1
    fi
    info "主机名已修改为：$new"
}

cleanup_size_for() {
    local path="$1"
    [ -d "$path" ] || { echo 0; return; }
    du -sb "$path" 2>/dev/null | awk '{print $1}'
}

cleanup_preview() {
    local path size
    for path in /var/cache/apt /var/cache/dnf /var/cache/yum /var/cache/apk /tmp /var/tmp "$CHANGE_BACKUP_DIR"; do
        [ -d "$path" ] || continue
        size="$(cleanup_size_for "$path")"
        printf '%-30s %s bytes\n' "$path" "$size"
    done
    command -v journalctl >/dev/null 2>&1 && journalctl --disk-usage 2>/dev/null || true
}

cleanup_old_temp_files() {
    local path="$1"
    [ -d "$path" ] || return 0
    find "$path" -xdev -maxdepth 1 -type f -user root -name 'vpsbox-*' -mtime +7 -print -delete 2>/dev/null || true
}

cleanup_old_temp_dirs() {
    local base="$1" path

    case "$base" in
        /tmp|/var/tmp) ;;
        *) return 1 ;;
    esac
    [ -d "$base" ] && [ ! -L "$base" ] || return 0
    while IFS= read -r -d '' path; do
        [ -d "$path" ] && [ ! -L "$path" ] || continue
        case "$path" in
            "${ACTIVE_NODE_BACKUP:-}") continue ;;
        esac
        case "$path" in
            "$base"/vpsbox-node-backup.*|\
            "$base"/vpsbox-sing-box-release.*|\
            "$base"/vpsbox-sing-box-update.*|\
            "$base"/vpsbox-chrony.*|\
            "$base"/vpsbox-bbr.*|\
            "$base"/vpsbox-journald.*)
                rm -rf -- "$path" || warn "清理遗留临时目录失败：$path"
                ;;
        esac
    done < <(
        find "$base" -xdev -mindepth 1 -maxdepth 1 -type d -user root -mtime +7 \
            \( -name 'vpsbox-node-backup.*' \
            -o -name 'vpsbox-sing-box-release.*' \
            -o -name 'vpsbox-sing-box-update.*' \
            -o -name 'vpsbox-chrony.*' \
            -o -name 'vpsbox-bbr.*' \
            -o -name 'vpsbox-journald.*' \) \
            -print0 2>/dev/null
    )
}

manifest_value_for_backup_cleanup() {
    local key="$1"

    [[ "$key" =~ ^[A-Z0-9_]+$ ]] || return 2
    [ -f "$CHANGE_MANIFEST" ] && [ ! -L "$CHANGE_MANIFEST" ] &&
        [ -r "$CHANGE_MANIFEST" ] || return 2
    awk -F= -v key="$key" '
        $0 !~ /^[A-Z0-9_]+=[A-Za-z0-9_.:,-]+$/ { invalid=1; next }
        seen[$1]++ { invalid=1; next }
        $1 == key { value=$2; found=1 }
        END {
            if (invalid) exit 2
            if (found) print value
            else exit 1
        }
    ' "$CHANGE_MANIFEST"
}

cleanup_orphaned_change_backups() {
    local backup name state old_file status
    if [ -L "$CHANGE_BACKUP_DIR" ]; then
        err "vpsbox 备份目录是符号链接，已拒绝清理：$CHANGE_BACKUP_DIR"
        return 1
    fi
    [ -d "$CHANGE_BACKUP_DIR" ] || return 0
    for backup in "$CHANGE_BACKUP_DIR"/*; do
        [ -f "$backup" ] && [ ! -L "$backup" ] || continue
        name="${backup##*/}"
        [[ "$name" =~ ^[A-Z0-9_]+$ ]] || continue
        if state="$(manifest_value_for_backup_cleanup "BACKUP_$name" 2>/dev/null)"; then
            case "$state" in
                file) continue ;;
                absent) ;;
                *)
                    err "vpsbox 变更清单中的备份状态无效，已停止清理：BACKUP_$name=$state"
                    return 1
                    ;;
            esac
        else
            status=$?
            if [ "$status" -ne 1 ]; then
                err "vpsbox 变更清单不可读、损坏或包含重复记录，已停止清理：$CHANGE_MANIFEST"
                return 1
            fi
        fi
        old_file="$(find "$backup" -xdev -type f -mtime +30 -print -quit 2>/dev/null || true)"
        [ -n "$old_file" ] || continue
        if find "$backup" -xdev -type f -mtime +30 -delete 2>/dev/null; then
            info "已清理未引用的 vpsbox 备份：$name"
        else
            warn "清理未引用的 vpsbox 备份失败：$name"
            return 1
        fi
    done
}

cleanup_system_garbage() {
    local confirm journal_confirm
    echo "将扫描并清理：包管理器缓存、超过 7 天的 vpsbox 临时文件、未引用的 vpsbox 过期备份。"
    echo "不会清理节点配置、用户主目录、Docker 数据卷或数据库。"
    cleanup_preview
    if ! read -r -p "确认执行垃圾清理？请输入 YES：" confirm; then
        info "输入已结束，已取消清理。"
        return 0
    fi
    [ "$confirm" = "YES" ] || { info "已取消清理。"; return 0; }

    if command -v apt-get >/dev/null 2>&1; then apt-get clean || warn "APT 缓存清理失败。"; fi
    if command -v dnf >/dev/null 2>&1; then dnf clean all || warn "DNF 缓存清理失败。"; fi
    if command -v yum >/dev/null 2>&1; then yum clean all || warn "YUM 缓存清理失败。"; fi
    if command -v apk >/dev/null 2>&1; then apk cache clean || warn "APK 缓存清理失败。"; fi
    cleanup_old_temp_files /tmp
    cleanup_old_temp_files /var/tmp
    cleanup_old_temp_dirs /tmp
    cleanup_old_temp_dirs /var/tmp
    cleanup_orphaned_change_backups || warn "vpsbox 未引用备份清理不完整。"
    if command -v journalctl >/dev/null 2>&1; then
        if ! read -r -p "是否清理超过 30 天的 systemd 日志？请输入 YES，其他输入跳过：" journal_confirm; then
            journal_confirm=""
        fi
        if [ "$journal_confirm" = "YES" ]; then
            journalctl --vacuum-time=30d || warn "systemd 历史日志清理失败。"
        else
            info "已跳过 systemd 历史日志清理。"
        fi
    fi
    info "垃圾清理完成，当前占用："
    cleanup_preview
}

system_change_items() {
    printf '%s\n' dns bbr ipv4_priority fail2ban journald ntp ipv6 tcp_buffer
}

system_change_label() {
    case "$1" in
        dns) printf '%s\n' "IPv4 DNS" ;;
        bbr) printf '%s\n' "BBR + fq" ;;
        ipv4_priority) printf '%s\n' "IPv4 优先" ;;
        fail2ban) printf '%s\n' "Fail2ban" ;;
        journald) printf '%s\n' "journald 日志限制" ;;
        ntp) printf '%s\n' "NTP 时间同步" ;;
        ipv6) printf '%s\n' "IPv6 禁用" ;;
        tcp_buffer) printf '%s\n' "TCP 缓冲区" ;;
        *) return 2 ;;
    esac
}

system_change_members() {
    case "$1" in
        dns) printf '%s\n' DNS_RESOLV DNS_RESOLVED ;;
        bbr) printf '%s\n' BBR_CONF ;;
        ipv4_priority) printf '%s\n' GAI_CONF ;;
        fail2ban) printf '%s\n' FAIL2BAN_SSHD ;;
        journald) printf '%s\n' JOURNALD_CONF ;;
        ntp) printf '%s\n' NTP_CONF ;;
        ipv6) printf '%s\n' IPV6_CONF ;;
        tcp_buffer) printf '%s\n' TCP_BUFFER_CONF ;;
        *) return 2 ;;
    esac
}

system_change_state() {
    local item="$1" members name state result=none

    members="$(system_change_members "$item")" || return $?
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        state="$(change_restore_state "$name")"
        case "$state" in
            pending)
                printf '%s\n' pending
                return 0
                ;;
            applied) result=applied ;;
        esac
    done <<< "$members"
    if [ "$result" = "none" ] && [ "$item" = "ipv6" ] &&
        ipv6_disable_config_is_current; then
        printf '%s\n' legacy
    else
        printf '%s\n' "$result"
    fi
}

system_change_state_text() {
    case "$(system_change_state "$1")" in
        pending) printf '%s\n' "未完成，可恢复" ;;
        applied) printf '%s\n' "可恢复" ;;
        legacy) printf '%s\n' "可重新启用（无原始记录）" ;;
        none) printf '%s\n' "无记录" ;;
        *) return 1 ;;
    esac
}

show_vpsbox_changes() {
    local item state found=0

    echo "vpsbox 已记录的系统变更："
    while IFS= read -r item; do
        state="$(system_change_state "$item")" || return 1
        [ "$state" != none ] || continue
        printf ' - %s：%s\n' "$(system_change_label "$item")" \
            "$(system_change_state_text "$item")"
        found=1
    done < <(system_change_items)
    [ "$found" -eq 1 ] || echo " - 无"
    if [ "$(system_change_state ipv6 2>/dev/null || true)" = "legacy" ]; then
        echo "未记录原始值的 IPv6 配置只支持单项重新启用，不包含在恢复全部中。"
    fi
    echo "SSH 配置不会由此功能自动恢复，请保持当前连接并手动核验后处理。"
}

recorded_system_changes_present() {
    local item

    while IFS= read -r item; do
        case "$(system_change_state "$item")" in
            pending|applied) return 0 ;;
        esac
    done < <(system_change_items)
    return 1
}

restore_dns_system_change() {
    local restore_resolv=0 restore_resolved=0 failed=0

    change_needs_restore DNS_RESOLV && restore_resolv=1
    change_needs_restore DNS_RESOLVED && restore_resolved=1
    if { [ "$restore_resolv" -eq 1 ] && ! change_backup_record_is_valid DNS_RESOLV; } ||
        { [ "$restore_resolved" -eq 1 ] && ! change_backup_record_is_valid DNS_RESOLVED; }; then
        err "IPv4 DNS 恢复记录不完整，已拒绝修改系统。"
        return 1
    fi
    [ "$restore_resolv" -eq 0 ] ||
        restore_change_file DNS_RESOLV "$RESOLV_CONF" || failed=1
    [ "$restore_resolved" -eq 0 ] ||
        restore_change_file DNS_RESOLVED /etc/systemd/resolved.conf.d/vpsbox.conf || failed=1
    [ "$failed" -eq 0 ] || return 1
    if resolv_conf_managed_by_systemd_resolved &&
        ! systemctl restart systemd-resolved; then
        return 1
    fi

    [ "$restore_resolv" -eq 0 ] || clear_change_tracking DNS_RESOLV || failed=1
    [ "$restore_resolved" -eq 0 ] || clear_change_tracking DNS_RESOLVED || failed=1
    return "$failed"
}

restore_bbr_system_change() {
    local cc fq failed=0

    cc="$(manifest_value BBR_CC 2>/dev/null || true)"
    fq="$(manifest_value BBR_FQ 2>/dev/null || true)"
    change_backup_record_is_valid BBR_CONF &&
        [ -n "$cc" ] && [ -n "$fq" ] || {
        err "BBR + fq 恢复记录不完整，已拒绝修改系统。"
        return 1
    }
    restore_change_file BBR_CONF "$BBR_CONF" || return 1
    if [ "$cc" != "unknown" ]; then
        sysctl -w "net.ipv4.tcp_congestion_control=$cc" >/dev/null 2>&1 || return 1
    fi
    if [ "$fq" != "unknown" ]; then
        sysctl -w "net.core.default_qdisc=$fq" >/dev/null 2>&1 || return 1
    fi

    clear_change_tracking BBR_CONF || failed=1
    manifest_remove BBR_CC || failed=1
    manifest_remove BBR_FQ || failed=1
    return "$failed"
}

restore_ipv6_system_change() {
    local all default lo failed=0

    all="$(manifest_value IPV6_ALL 2>/dev/null || true)"
    default="$(manifest_value IPV6_DEFAULT 2>/dev/null || true)"
    lo="$(manifest_value IPV6_LO 2>/dev/null || true)"
    change_backup_record_is_valid IPV6_CONF &&
        [[ "$all" =~ ^[01]$ ]] &&
        [[ "$default" =~ ^[01]$ ]] &&
        [[ "$lo" =~ ^[01]$ ]] || {
        err "IPv6 禁用恢复记录不完整，已拒绝修改系统。"
        return 1
    }
    restore_change_file IPV6_CONF "$IPV6_DISABLE_CONF" || return 1
    restore_ipv6_runtime_values "$all" "$default" "$lo" || return 1

    clear_change_tracking IPV6_CONF || failed=1
    manifest_remove IPV6_ALL || failed=1
    manifest_remove IPV6_DEFAULT || failed=1
    manifest_remove IPV6_LO || failed=1
    [ "$failed" -eq 0 ] || return 1
    report_ipv6_reenable_address_state
}

restore_tcp_buffer_system_change() {
    local core_rmem core_wmem tcp_rmem tcp_wmem values failed=0

    core_rmem="$(manifest_value TCP_BUFFER_RMEM_MAX 2>/dev/null || true)"
    core_wmem="$(manifest_value TCP_BUFFER_WMEM_MAX 2>/dev/null || true)"
    tcp_rmem="$(manifest_value TCP_BUFFER_TCP_RMEM 2>/dev/null || true)"
    tcp_wmem="$(manifest_value TCP_BUFFER_TCP_WMEM 2>/dev/null || true)"
    change_backup_record_is_valid TCP_BUFFER_CONF &&
        [[ "$core_rmem" =~ ^[0-9]+$ ]] &&
        [[ "$core_wmem" =~ ^[0-9]+$ ]] &&
        tcp_buffer_vector_to_spaces "$tcp_rmem" >/dev/null &&
        tcp_buffer_vector_to_spaces "$tcp_wmem" >/dev/null || {
        err "TCP 缓冲区恢复记录不完整，已拒绝修改系统。"
        return 1
    }
    values="$core_rmem $core_wmem $tcp_rmem $tcp_wmem"
    restore_change_file TCP_BUFFER_CONF "$TCP_BUFFER_CONF" || return 1
    restore_tcp_buffer_runtime_values "$values" || return 1

    clear_change_tracking TCP_BUFFER_CONF || failed=1
    manifest_remove TCP_BUFFER_RMEM_MAX || failed=1
    manifest_remove TCP_BUFFER_WMEM_MAX || failed=1
    manifest_remove TCP_BUFFER_TCP_RMEM || failed=1
    manifest_remove TCP_BUFFER_TCP_WMEM || failed=1
    return "$failed"
}

restore_ipv4_priority_system_change() {
    change_backup_record_is_valid GAI_CONF || {
        err "IPv4 优先恢复记录不完整，已拒绝修改系统。"
        return 1
    }
    restore_change_file GAI_CONF "$GAI_CONF" || return 1
    clear_change_tracking GAI_CONF
}

restore_fail2ban_system_change() {
    local fail2ban_active fail2ban_enabled failed=0

    fail2ban_active="$(manifest_value FAIL2BAN_ACTIVE 2>/dev/null || true)"
    fail2ban_enabled="$(manifest_value FAIL2BAN_ENABLED 2>/dev/null || true)"
    case "$fail2ban_active:$fail2ban_enabled" in
        active:enabled|active:disabled|inactive:enabled|inactive:disabled) ;;
        *)
            err "Fail2ban 恢复记录缺少有效的服务状态，已拒绝修改配置和服务。"
            return 1
            ;;
    esac
    change_backup_record_is_valid FAIL2BAN_SSHD || {
        err "Fail2ban 配置备份不完整，已拒绝修改配置和服务。"
        return 1
    }
    restore_change_file FAIL2BAN_SSHD "$FAIL2BAN_VPSBOX_SSHD_CONF" || return 1
    if fail2ban_installed; then
        fail2ban-client -t -c /etc/fail2ban >/dev/null 2>&1 || return 1
        detect_os
        if is_systemd; then
            if [ "$fail2ban_enabled" = "enabled" ]; then
                systemctl enable fail2ban || return 1
            else
                systemctl disable fail2ban || return 1
            fi
            if [ "$fail2ban_active" = "active" ]; then
                systemctl restart fail2ban || return 1
            else
                systemctl stop fail2ban || return 1
            fi
        elif [ "$OS" = "alpine" ] && command -v rc-service >/dev/null 2>&1; then
            if [ "$fail2ban_enabled" = "enabled" ]; then
                rc-update add fail2ban default || return 1
            else
                rc-update del fail2ban default || return 1
            fi
            if [ "$fail2ban_active" = "active" ]; then
                rc-service fail2ban restart || return 1
            else
                rc-service fail2ban stop || return 1
            fi
        else
            err "当前环境无法恢复 Fail2ban 服务状态。"
            return 1
        fi
    fi

    clear_change_tracking FAIL2BAN_SSHD || failed=1
    manifest_remove FAIL2BAN_ACTIVE || failed=1
    manifest_remove FAIL2BAN_ENABLED || failed=1
    return "$failed"
}

restore_journald_system_change() {
    change_backup_record_is_valid JOURNALD_CONF || {
        err "journald 恢复记录不完整，已拒绝修改系统。"
        return 1
    }
    is_systemd || {
        err "当前环境无法恢复 systemd 管理的 journald 状态。"
        return 1
    }
    restore_change_file JOURNALD_CONF "$JOURNALD_VPSBOX_CONF" || return 1
    systemctl restart systemd-journald &&
        systemctl is-active --quiet systemd-journald || return 1
    clear_change_tracking JOURNALD_CONF
}

restore_ntp_system_change() {
    restore_recorded_ntp_change || {
        err "当前环境无法恢复 systemd 管理的 NTP 状态。"
        return 1
    }
    clear_ntp_change_tracking
}

restore_vpsbox_system_change() {
    local item="$1" label state

    state="$(system_change_state "$item")" || return 1
    [ "$state" != none ] && [ "$state" != legacy ] || return 2
    label="$(system_change_label "$item")" || return 2
    case "$item" in
        dns) restore_dns_system_change ;;
        bbr) restore_bbr_system_change ;;
        ipv4_priority) restore_ipv4_priority_system_change ;;
        fail2ban) restore_fail2ban_system_change ;;
        journald) restore_journald_system_change ;;
        ntp) restore_ntp_system_change ;;
        ipv6) restore_ipv6_system_change ;;
        tcp_buffer) restore_tcp_buffer_system_change ;;
        *) return 2 ;;
    esac || {
        err "$label 未能完整恢复；未清理的记录已保留，请检查后重试。"
        return 1
    }
    info "$label 已恢复。"
}

restore_vpsbox_system_change_interactive() {
    local item="$1" label state confirm

    label="$(system_change_label "$item")" || return 2
    state="$(system_change_state "$item")" || return 1
    if [ "$state" = none ]; then
        info "$label 没有可恢复记录。"
        return 0
    fi
    if [ "$item" = "ipv6" ] && [ "$state" = "legacy" ]; then
        warn "未找到禁用前的原始记录，只能移除 vpsbox 配置并将 all/default/lo 设置为 0。"
        warn "这会重新启用 IPv6，但不属于精确还原。"
        if ! read -r -p "重新启用 IPv6？请输入 YES：" confirm; then
            info "输入已结束，已取消重新启用 IPv6。"
            return 0
        fi
        [ "$confirm" = "YES" ] || { info "已取消重新启用 IPv6。"; return 0; }
        reenable_untracked_ipv6
        return
    fi
    if ! read -r -p "恢复 $label？请输入 YES：" confirm; then
        info "输入已结束，已取消恢复。"
        return 0
    fi
    [ "$confirm" = "YES" ] || { info "已取消恢复。"; return 0; }
    restore_vpsbox_system_change "$item"
}

restore_vpsbox_system_changes() {
    local skip_confirmation="${1:-0}" confirm item state
    local restored=0 failed=0 absent=0

    if ! recorded_system_changes_present; then
        info "当前没有可恢复的 vpsbox 系统改动。"
        return 0
    fi
    if [ "$skip_confirmation" != "1" ]; then
        show_vpsbox_changes
        if ! read -r -p "恢复上述 vpsbox 已记录的系统设置？请输入 YES：" confirm; then
            info "输入已结束，已取消恢复。"
            return 0
        fi
        [ "$confirm" = "YES" ] || { info "已取消恢复。"; return 0; }
    fi

    while IFS= read -r item; do
        state="$(system_change_state "$item")" || {
            failed=$((failed + 1))
            continue
        }
        if [ "$state" = none ]; then
            absent=$((absent + 1))
            continue
        fi
        if [ "$state" = legacy ]; then
            absent=$((absent + 1))
            continue
        fi
        if restore_vpsbox_system_change "$item"; then
            restored=$((restored + 1))
        else
            failed=$((failed + 1))
        fi
    done < <(system_change_items)

    echo "----------------------------------------"
    echo " 恢复成功：$restored 项"
    echo " 恢复失败：$failed 项"
    echo " 无记录：$absent 项"
    echo "----------------------------------------"
    if [ "$failed" -ne 0 ]; then
        err "部分项目恢复失败；失败项目的剩余记录未清理，请检查后重试。"
        return 1
    fi
    info "已恢复全部记录项目；请使用自检和对应服务状态确认结果。"
}

offer_restore_recorded_changes_before_uninstall() {
    local confirm

    recorded_system_changes_present || return 0
    echo "检测到 vpsbox 已记录且可恢复的系统设置："
    show_vpsbox_changes
    if ! read -r -p "是否在卸载前恢复上述系统设置？请输入 YES 恢复，其他输入保留现状：" confirm; then
        err "未能读取恢复选择，已取消卸载。"
        return 1
    fi
    if [ "$confirm" = "YES" ]; then
        restore_vpsbox_system_changes 1
    else
        info "已保留当前系统设置。"
    fi
}

system_changes_menu() {
    local opt

    while true; do
        clear 2>/dev/null || true
        cat <<EOF
========================================
 vpsbox 系统改动
========================================
 [1] 恢复全部已记录项目
 [2] IPv4 DNS：$(system_change_state_text dns)
 [3] BBR + fq：$(system_change_state_text bbr)
 [4] IPv4 优先：$(system_change_state_text ipv4_priority)
 [5] Fail2ban：$(system_change_state_text fail2ban)
 [6] journald 日志限制：$(system_change_state_text journald)
 [7] NTP 时间同步：$(system_change_state_text ntp)
 [8] IPv6 禁用：$(system_change_state_text ipv6)
 [9] TCP 缓冲区：$(system_change_state_text tcp_buffer)
----------------------------------------
 [0] 返回系统优化菜单
========================================
EOF
        read -r -p "请输入选项: " opt || return 0
        echo ""

        case "$opt" in
            1) run_menu_action restore_vpsbox_system_changes; pause ;;
            2) run_menu_action restore_vpsbox_system_change_interactive dns; pause ;;
            3) run_menu_action restore_vpsbox_system_change_interactive bbr; pause ;;
            4) run_menu_action restore_vpsbox_system_change_interactive ipv4_priority; pause ;;
            5) run_menu_action restore_vpsbox_system_change_interactive fail2ban; pause ;;
            6) run_menu_action restore_vpsbox_system_change_interactive journald; pause ;;
            7) run_menu_action restore_vpsbox_system_change_interactive ntp; pause ;;
            8) run_menu_action restore_vpsbox_system_change_interactive ipv6; pause ;;
            9) run_menu_action restore_vpsbox_system_change_interactive tcp_buffer; pause ;;
            0) return 0 ;;
            *) warn "无效选项：$opt"; pause ;;
        esac
    done
}

verify_current_node_runtime() {
    verify_all_node_runtime
}

start_service_action() {
    if ! node_core_artifacts_present && ! node_exists; then
        warn "当前没有节点配置，请先创建节点。"
        return 0
    fi
    ensure_node_runtime_commands || return 1
    require_valid_node_state_if_present || return 1
    if ! node_exists; then
        warn "当前没有节点配置，请先创建节点。"
        return 0
    fi
    repair_node_uri_cache_best_effort "启动 sing-box 前"

    if service_is_running &&
        verify_current_node_runtime &&
        singbox_service_definition_is_current; then
        if ! service_is_enabled; then
            service_enable || {
                err "sing-box 正在运行，但设置开机自启失败。"
                return 1
            }
        fi
        info "sing-box 服务已在运行，无需重复启动。"
        return 0
    fi

    install_singbox_if_missing || return 1
    if singbox_service_definition_is_current &&
        ! service_manager_is_active &&
        [ -z "$(singbox_config_pids)" ]; then
        service_is_enabled || service_enable || return 1
        service_start || return 1
    else
        setup_service || return 1
        restart_singbox_cleanly || return 1
    fi
    if ! verify_current_node_runtime; then
        err "sing-box 未保持运行或节点端口未按协议完整监听。"
        return 1
    fi
    info "sing-box 服务已启动。"
}

restart_service_action() {
    if ! node_core_artifacts_present && ! node_exists; then
        warn "当前没有节点配置，请先创建节点。"
        return 0
    fi
    ensure_node_runtime_commands || return 1
    require_valid_node_state_if_present || return 1
    if ! node_exists; then
        warn "当前没有节点配置，请先创建节点。"
        return 0
    fi
    repair_node_uri_cache_best_effort "重启 sing-box 前"
    install_singbox_if_missing || return 1
    setup_service || return 1
    restart_singbox_cleanly || return 1
    if ! verify_current_node_runtime; then
        err "sing-box 未保持运行或节点端口未按协议完整监听。"
        return 1
    fi
    info "sing-box 服务已重启。"
}

stop_service_action() {
    local failed=0

    service_stop || failed=1
    stop_singbox_config_processes || failed=1
    if service_manager_is_active || [ -n "$(singbox_config_pids)" ]; then
        err "sing-box 服务或当前配置对应的残留进程仍在运行。"
        return 1
    fi
    if [ "$failed" -ne 0 ]; then
        err "sing-box 已停止，但服务管理命令执行失败，请检查服务定义。"
        return 1
    fi
    info "sing-box 服务已停止。"
}

singbox_summary_line() {
    local version status

    if ! singbox_installed; then
        echo " sing-box：未安装"
        return 0
    fi
    version="$(singbox_version)"
    [ -n "$version" ] && [ "$version" != "-" ] || version="版本未知"
    status="$(service_status_short)"
    printf ' sing-box：%s %s\n' "$version" "$status"
}

ssh_port_summary_line() {
    local ports

    ports="$(ssh_port_state 2>/dev/null)" || ports=""
    [ -n "$ports" ] || ports="无法读取"
    printf ' SSH 端口：%s\n' "$ports"
}

node_state() {
    local states=""

    protocol_visible_exists vless && states="VLESS Reality"
    if protocol_visible_exists ss; then
        [ -n "$states" ] && states="$states + Shadowsocks" || states="Shadowsocks"
    fi
    printf '%s\n' "${states:-未创建}"
}

node_address() {
    local protocol addresses=""

    for protocol in vless ss; do
        if load_protocol_state "$protocol" >/dev/null 2>&1; then
            [ -n "$addresses" ] && addresses="$addresses, "
            addresses="${addresses}${DOMAIN}:${PORT}"
        fi
    done
    printf '%s\n' "${addresses:--}"
}

node_summary() {
    local protocol label status

    # 未知配置会参与 sing-box -C 加载，必须整体告警；两个受管协议文件自身的
    # 权限、类型与内容则由 protocol_node_status 分别判断，避免一个损坏遮住另一个。
    if ! node_config_dir_layout_valid >/dev/null 2>&1; then
        printf '%s\n 节点状态：异常，请进入节点管理检查\n' '----------------------------------------'
        return 0
    fi
    for protocol in vless ss; do
        status="$(protocol_node_status "$protocol" 2>/dev/null || printf '%s\n' damaged)"
        [ "$protocol" = "vless" ] && label="VLESS Reality" || label="Shadowsocks"
        case "$status" in
            absent) continue ;;
            damaged)
                printf '%s\n' '----------------------------------------'
                printf ' %s 节点\n 状态：损坏，请进入节点管理检查\n' "$label"
                ;;
            normal|deviated)
                load_protocol_state "$protocol" >/dev/null 2>&1 || continue
                [ "$status" = "normal" ] && status="已创建" ||
                    status="已创建（配置已偏离 vpsbox 管理模板）"
                printf '%s\n' '----------------------------------------'
                printf ' %s 节点\n 状态：%s\n 名称：%s\n 地址：%s\n 端口：%s\n' \
                    "$label" "$status" "$NAME" "$DOMAIN" "$PORT"
                ;;
        esac
    done
}

reboot_required_state() {
    if [ -f /var/run/reboot-required ] || [ -f /run/reboot-required ]; then
        echo "需要"
    else
        echo "不需要"
    fi
}

journal_disk_usage() {
    if command -v journalctl >/dev/null 2>&1; then
        journalctl --disk-usage 2>/dev/null |
            sed -E 's/^Archived and active journals take up //; s/ in the file system\.?$//; s/\.$//'
    else
        echo "无法检测"
    fi
}

journald_conf_value() {
    local key="$1"
    local rendered value

    if command -v systemd-analyze >/dev/null 2>&1 &&
        rendered="$(systemd-analyze cat-config systemd/journald.conf 2>/dev/null)"; then
        value="$(awk -F= -v key="$key" '$0 ~ "^[[:space:]]*" key "=" { value=$2 } END { print value }' <<< "$rendered")"
    else
        value="$(grep -h -E "^[[:space:]]*$key=" /etc/systemd/journald.conf "$JOURNALD_VPSBOX_CONF" 2>/dev/null | tail -n 1 | cut -d= -f2- || true)"
    fi
    [ -n "$value" ] || return 1
    printf '%s\n' "$value"
}

journald_limit_state() {
    local max_use
    local max_file

    if ! is_systemd; then
        echo "不支持"
        return 0
    fi

    max_use="$(journald_conf_value SystemMaxUse || true)"
    max_file="$(journald_conf_value SystemMaxFileSize || true)"

    if [ "$max_use" = "500M" ] && [ "$max_file" = "50M" ]; then
        echo "已配置"
    else
        echo "未配置"
    fi
}

limit_systemd_journal() {
    local conf_dir backup_dir tmp had_old=0 confirm

    if ! is_systemd; then
        err "未检测到 systemd，无法配置 systemd-journald。"
        return 1
    fi

    if ! command -v journalctl >/dev/null 2>&1; then
        err "未找到 journalctl，无法清理 systemd 日志。"
        return 1
    fi

    if [ "$(journald_limit_state)" = "已配置" ] &&
        systemctl is-active --quiet systemd-journald 2>/dev/null; then
        info "systemd 日志限制已正确生效，无需重复写入或重启服务。"
        info "当前日志占用：$(journal_disk_usage)"
        info "总大小：500M"
        info "单文件：50M"
        return 0
    fi

    conf_dir="$(dirname "$JOURNALD_VPSBOX_CONF")"
    if [ -L "$conf_dir" ] || [ -L "$JOURNALD_VPSBOX_CONF" ]; then
        err "journald 配置路径包含符号链接，已拒绝修改。"
        return 1
    fi
    mkdir -p "$conf_dir" || return 1
    backup_change_file_once JOURNALD_CONF "$JOURNALD_VPSBOX_CONF" || { err "记录 journald 原配置失败，已取消修改。"; return 1; }
    backup_dir="$(mktemp -d /tmp/vpsbox-journald.XXXXXX)" || return 1
    if [ -e "$JOURNALD_VPSBOX_CONF" ]; then
        cp -a "$JOURNALD_VPSBOX_CONF" "$backup_dir/99-vpsbox.conf" || { rm -rf "$backup_dir"; err "备份 journald 配置失败。"; return 1; }
        had_old=1
    fi
    begin_change_transaction JOURNALD_CONF || { rm -rf "$backup_dir"; err "记录 journald 修改事务失败，已取消修改。"; return 1; }
    tmp="$(mktemp "$conf_dir/.99-vpsbox.XXXXXX")" || { rm -rf "$backup_dir"; return 1; }
    # --- BEGIN GENERATED TEMPLATE: journald drop-in ---
    cat > "$tmp" <<EOF
[Journal]
SystemMaxUse=500M
SystemMaxFileSize=50M
EOF
    # --- END GENERATED TEMPLATE: journald drop-in ---
    if ! chown root:root "$tmp" || ! chmod 644 "$tmp" || ! mv -f "$tmp" "$JOURNALD_VPSBOX_CONF"; then
        rm -f "$tmp"
        rm -rf "$backup_dir"
        err "写入 journald 配置失败。"
        return 1
    fi

    if ! systemctl restart systemd-journald || ! systemctl is-active --quiet systemd-journald || [ "$(journald_conf_value SystemMaxUse || true)" != "500M" ] || [ "$(journald_conf_value SystemMaxFileSize || true)" != "50M" ]; then
        err "journald 配置未生效，正在恢复原配置。"
        if restore_root_file_snapshot \
            "$backup_dir/99-vpsbox.conf" "$JOURNALD_VPSBOX_CONF" "$had_old" &&
            systemctl restart systemd-journald >/dev/null 2>&1; then
            rm -rf "$backup_dir"
            err "journald 配置未生效，已恢复修改前的配置与服务。"
        else
            err "journald 配置未生效，且未能完整恢复；恢复菜单中的原始基线仍保留。"
            warn "本次临时备份保留在：$backup_dir"
        fi
        return 1
    fi
    rm -rf "$backup_dir"
    mark_change_applied JOURNALD_CONF || return 1
    info "systemd 日志限制已设置。"
    info "当前日志占用：$(journal_disk_usage)"
    info "总大小：500M"
    info "单文件：50M"
    if ! read -r -p "是否立即清理历史日志至 500M？此操作不可恢复。请输入 YES 确认：" confirm; then
        confirm=""
    fi
    if [ "$confirm" = "YES" ]; then
        if retry 3 2 journalctl --rotate --vacuum-size=500M; then
            info "清理完成，当前日志占用：$(journal_disk_usage)"
        else
            err "历史日志清理失败，日志大小限制仍已生效。"
            return 1
        fi
    else
        info "已跳过清理历史日志；新限制会在后续日志轮转中生效。"
    fi
}

# ==============================================================================
# 9. 菜单与交互
# ==============================================================================
show_menu() {
    clear 2>/dev/null || true
    cat <<EOF
========================================
 $APP_NAME
========================================
 版本：$VPSBOX_VERSION
 提示：输入 vpsbox 打开管理面板
EOF
    vpsbox_update_notice
    cat <<EOF
----------------------------------------
$(singbox_summary_line)
$(ssh_port_summary_line)
EOF
    node_summary
    cat <<EOF
----------------------------------------
 IPv4 DNS：
$(ipv4_dns_lines)
----------------------------------------
 [1] 节点管理
 [2] sing-box 管理
 [3] 系统优化
 [4] 主机防火墙
 [5] 一键检测
 [6] 第三方脚本
----------------------------------------
 [00] 更新 vpsbox
 [88] 卸载 vpsbox
 [0] 退出
========================================
EOF
}

node_menu() {
    local opt

    while true; do
        clear 2>/dev/null || true
        cat <<EOF
========================================
 节点管理
========================================
$(singbox_summary_line)
$(node_summary)
----------------------------------------
 [1] 创建/重建 VLESS Reality 节点（推荐）
 [2] 创建/重建 Shadowsocks 节点
 [3] 查看节点链接
 [4] 删除 VLESS Reality 节点
 [5] 删除 Shadowsocks 节点
----------------------------------------
 [0] 返回主菜单
========================================
EOF
        read -r -p "请输入选项: " opt || exit 0
        echo ""

        case "$opt" in
            1) run_menu_action create_vless_reality_node; pause ;;
            2) run_menu_action create_or_rebuild_node; pause ;;
            3) run_menu_action view_node_link; pause ;;
            4) run_menu_action delete_vless_reality_node; pause ;;
            5) run_menu_action delete_node; pause ;;
            0) return 0 ;;
            *) warn "无效选项：$opt"; pause ;;
        esac
    done
}

singbox_menu() {
    local opt

    while true; do
        clear 2>/dev/null || true
        cat <<EOF
========================================
 sing-box 管理
========================================
$(singbox_summary_line)
----------------------------------------
 [1] 启动服务
 [2] 停止服务
 [3] 重启服务
 [4] 更新 sing-box
----------------------------------------
 [0] 返回主菜单
========================================
EOF
        read -r -p "请输入选项: " opt || exit 0
        echo ""

        case "$opt" in
            1) run_menu_action start_service_action; pause ;;
            2) run_menu_action stop_service_action; pause ;;
            3) run_menu_action restart_service_action; pause ;;
            4) run_menu_action update_singbox; pause ;;
            0) return 0 ;;
            *) warn "无效选项：$opt"; pause ;;
        esac
    done
}

system_menu() {
    local opt ntp_label journal_label

    while true; do
        detect_os
        ntp_label="开启 NTP 时间同步"
        journal_label="限制 journald 日志大小"
        if [ "$OS" = "alpine" ]; then
            ntp_label+="（Alpine/OpenRC 不适用）"
            journal_label+="（Alpine/OpenRC 不适用）"
        fi
        clear 2>/dev/null || true
        cat <<EOF
========================================
 系统优化
========================================
 NTP：$(ntp_sync_state)
 SSH：端口 $(ssh_port_state)
 Fail2ban：$(fail2ban_service_state) / SSH 防护$(fail2ban_sshd_state)
 IPv4 优先：$(ipv4_priority_state)
 IPv6：$(ipv6_summary_state)
 BBR + fq：$(bbr_fq_summary_state)
 TCP 缓冲区：$(tcp_buffer_summary_state)
 journald 日志限制：$(journald_limit_state)
 系统重启：$(reboot_required_state)
----------------------------------------
 基础
 [1] 系统更新
 [2] 垃圾清理
 [3] 修改主机名
 [4] $ntp_label

 SSH 安全
 [5] 修改 SSH 端口
 [6] 安装 Fail2ban

 网络
 [7] 修改 IPv4 DNS
 [8] 开启 IPv4 优先
 [9] 禁用 IPv6
 [10] 开启 BBR + fq
 [11] TCP 缓冲区调优

 维护
 [12] $journal_label
 [13] 查看/恢复 vpsbox 系统改动
----------------------------------------
 [0] 返回主菜单
========================================
EOF
        read -r -p "请输入选项: " opt || exit 0
        echo ""

        case "$opt" in
            1) run_menu_action update_system_packages; pause ;;
            2) run_menu_action cleanup_system_garbage; pause ;;
            3) run_menu_action change_system_hostname; pause ;;
            4) run_menu_action enable_ntp_sync; pause ;;
            5) ssh_port_change_menu ;;
            6) run_menu_action install_fail2ban; pause ;;
            7) run_menu_action change_ipv4_dns; pause ;;
            8) run_menu_action enable_ipv4_priority; pause ;;
            9) run_menu_action disable_ipv6; pause ;;
            10) run_menu_action enable_bbr_fq; pause ;;
            11) tcp_buffer_menu ;;
            12) run_menu_action limit_systemd_journal; pause ;;
            13) system_changes_menu ;;
            0) return 0 ;;
            *) warn "无效选项：$opt"; pause ;;
        esac
    done
}

show_ip_quality_script_info() {
    clear 2>/dev/null || true
    cat <<'EOF'
========================================
 IP 质量体检脚本
========================================
 项目地址：
 https://github.com/xykt/ScriptMenu

 上游命令：
 bash <(curl -Ls https://Check.Place) -I

 说明：vpsbox 仅提供第三方脚本链接和命令提示，
 不会自动执行。
========================================
EOF
}

show_network_quality_script_info() {
    clear 2>/dev/null || true
    cat <<'EOF'
========================================
 网络质量体检脚本
========================================
 项目地址：
 https://github.com/xykt/ScriptMenu

 上游命令：
 bash <(curl -Ls https://Check.Place) -N

 说明：vpsbox 仅提供第三方脚本链接和命令提示，
 不会自动执行。
========================================
EOF
}

show_tcp_quality_script_info() {
    clear 2>/dev/null || true
    cat <<'EOF'
========================================
 TCP 质量检测脚本
========================================
 项目地址：
 https://github.com/ibsgss/TcpQuality

 上游命令：
 bash <(curl -fsSL https://raw.githubusercontent.com/ibsgss/TcpQuality/main/runTcpQuality.sh)

 说明：vpsbox 仅提供第三方脚本链接和命令提示，
 不会自动执行。
========================================
EOF
}

show_node_quality_script_info() {
    clear 2>/dev/null || true
    cat <<'EOF'
========================================
 VPS 综合质量测试脚本
========================================
 项目地址：
 https://github.com/LloydAsp/NodeQuality

 上游命令：
 bash <(curl -sL https://run.NodeQuality.com)

 说明：vpsbox 仅提供第三方脚本链接和命令提示，
 不会自动执行。
========================================
EOF
}

show_reinstall_script_info() {
    clear 2>/dev/null || true
    cat <<'EOF'
========================================
 一键 VPS 系统重装脚本
========================================
 项目地址：
 https://github.com/bin456789/reinstall

 上游命令（安装 Debian 13）：
 curl -fL https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh -o reinstall.sh && bash reinstall.sh debian 13

 警告：执行重装会清除整个系统盘的数据。
 vpsbox 仅提供第三方脚本链接和命令提示，
 不会自动执行。
========================================
EOF
}

other_scripts_menu() {
    local opt

    while true; do
        clear 2>/dev/null || true
        cat <<'EOF'
========================================
 第三方脚本
========================================
 [1] IP 质量体检脚本（xykt）
 [2] 网络质量体检脚本（xykt）
 [3] TCP 质量检测脚本（ibsgss）
 [4] VPS 综合质量测试脚本（LloydAsp）
 [5] 一键 VPS 系统重装脚本（bin456789）
----------------------------------------
 [0] 返回主菜单
========================================
EOF
        read -r -p "请输入选项: " opt || exit 0
        echo ""

        case "$opt" in
            1)
                show_ip_quality_script_info
                exit 0
                ;;
            2)
                show_network_quality_script_info
                exit 0
                ;;
            3)
                show_tcp_quality_script_info
                exit 0
                ;;
            4)
                show_node_quality_script_info
                exit 0
                ;;
            5)
                show_reinstall_script_info
                exit 0
                ;;
            0) return 0 ;;
            *) warn "无效选项：$opt"; pause ;;
        esac
    done
}

main_loop() {
    while true; do
        show_menu
        # 只有新版已完成初始化并成功渲染首个菜单，且收到本次更新的一次性握手变量，
        # 才确认自更新启动成功；普通启动不会误用陈旧 .previous。
        confirm_pending_vpsbox_update
        read -r -p "请输入选项: " opt || exit 0
        echo ""

        case "$opt" in
            1) run_menu_action node_menu ;;
            2) run_menu_action singbox_menu ;;
            3) run_menu_action system_menu ;;
            4) run_menu_action firewall_menu ;;
            5) run_menu_action run_self_check; pause ;;
            6) run_menu_action other_scripts_menu ;;
            00) run_menu_action update_vpsbox; pause ;;
            88) run_menu_action uninstall_all; pause ;;
            0) exit 0 ;;
            *) warn "无效选项：$opt"; pause ;;
        esac
    done
}

# ==============================================================================
# 10. 程序入口
# ==============================================================================
vpsbox_main() {
    if [ -n "${PENDING_VPSBOX_UPDATE_BACKUP:-}${PENDING_VPSBOX_UPDATE_READY_FILE:-}" ]; then
        # 更新后的新进程可能在取得菜单锁前失败，必须提前安装 EXIT 回滚处理。
        trap cleanup_vpsbox_runtime EXIT
    fi
    need_root
    detect_os
    acquire_lock
    recover_pending_singbox_update || {
        err "sing-box 更新事务未能恢复，已停止启动 vpsbox，避免丢失旧二进制。"
        return 1
    }
    recover_pending_node_transaction || {
        err "节点事务未能恢复，已停止启动 vpsbox，避免覆盖现有节点。"
        return 1
    }
    repair_node_uri_cache_on_startup
    install_self_command
    if [ -z "${PENDING_VPSBOX_UPDATE_BACKUP:-}${PENDING_VPSBOX_UPDATE_READY_FILE:-}" ]; then
        check_vpsbox_update_on_start
        auto_update_vpsbox_on_start
    fi
    main_loop
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    vpsbox_main "$@"
fi
