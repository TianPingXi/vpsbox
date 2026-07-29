#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=tests/test_helper.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

# vpsbox.sh 通过直接执行保护后可以安全加载；测试只覆盖函数，不运行主菜单。
# shellcheck disable=SC1091
source "$REPO_DIR/vpsbox.sh"

# 多数封禁用例需要固定本机地址夹具，但仍要保留并直接验证生产实现，
# 防止文件级 mock 让 fail2ban_local_ipv4_text 的回归永久不可见。
eval "production_fail2ban_local_ipv4_text() $(declare -f fail2ban_local_ipv4_text | sed '1d')"

MOCK_CALL_LOG="$TEST_TMP/fail2ban-calls.log"
MOCK_JAIL_STATE="$TEST_TMP/fail2ban-jail.state"
MOCK_BACKEND_STATE="$TEST_TMP/fail2ban-backend.state"
MOCK_ACTION_NAME="nftables-multiport"
MOCK_ACTIONBAN="/usr/sbin/nft add element inet f2b-table addr-set-sshd { <ip> }"
MOCK_BAN_MODE="normal"
MOCK_UNBAN_FAIL=0

test_cleanup() {
    if [ "${KEEP_TEST_TMP:-0}" = "1" ]; then
        printf '保留测试临时目录：%s\n' "$TEST_TMP" >&2
    else
        rm -rf -- "$TEST_TMP"
    fi
}
trap test_cleanup EXIT

reset_mock() {
    : > "$MOCK_CALL_LOG"
    : > "$MOCK_JAIL_STATE"
    : > "$MOCK_BACKEND_STATE"
    MOCK_ACTION_NAME="nftables-multiport"
    MOCK_ACTIONBAN="/usr/sbin/nft add element inet f2b-table addr-set-sshd { <ip> }"
    MOCK_BAN_MODE="normal"
    MOCK_UNBAN_FAIL=0
    ACTIVE_FAIL2BAN_TEST_IP=""
    # Read by the production cleanup function through shared global state.
    # shellcheck disable=SC2034
    ACTIVE_FAIL2BAN_TEST_BACKENDS=""
    fail2ban_local_ipv4_text() {
        printf '%s\n' 10.0.0.1
    }
}

remove_mock_ip() {
    local file="$1" ip="$2" tmp
    tmp="${file}.tmp"
    grep -Fvx -- "$ip" "$file" > "$tmp" || true
    mv -f -- "$tmp" "$file"
}

fail2ban-client() {
    printf '%s\n' "$*" >> "$MOCK_CALL_LOG"

    if [ "${1:-}" = "-t" ]; then
        return 0
    fi
    case "${1:-} ${2:-} ${3:-}" in
        "get sshd actions")
            printf 'The jail sshd has the following actions:\n%s\n' "$MOCK_ACTION_NAME"
            ;;
        "get sshd action")
            [ "${5:-}" = "actionban" ] || return 2
            printf '%s\n' "$MOCK_ACTIONBAN"
            ;;
        "get sshd banip")
            tr '\n' ' ' < "$MOCK_JAIL_STATE"
            printf '\n'
            ;;
        "set sshd banip")
            local ip="${4:-}"
            [ -n "$ip" ] || return 2
            [ "$MOCK_BAN_MODE" != "command-fails" ] || return 1
            printf '%s\n' "$ip" >> "$MOCK_JAIL_STATE"
            if [ "$MOCK_BAN_MODE" = "normal" ]; then
                printf '%s\n' "$ip" >> "$MOCK_BACKEND_STATE"
            fi
            printf '1\n'
            ;;
        "set sshd unbanip")
            local ip="${4:-}"
            [ -n "$ip" ] || return 2
            [ "$MOCK_UNBAN_FAIL" -eq 0 ] || return 1
            remove_mock_ip "$MOCK_JAIL_STATE" "$ip"
            remove_mock_ip "$MOCK_BACKEND_STATE" "$ip"
            printf '1\n'
            ;;
        "status sshd ")
            return 0
            ;;
        *)
            return 2
            ;;
    esac
}

nft() {
    if [[ " $* " != *" list ruleset "* ]]; then
        return 2
    fi

    printf 'table inet f2b-table {\n'
    printf '  set addr-set-sshd { type ipv4_addr; elements = { '
    paste -sd ', ' "$MOCK_BACKEND_STATE"
    printf ' } }\n}\n'
}

iptables-save() {
    cat "$MOCK_BACKEND_STATE"
}

ipset() {
    [ "${1:-}" = "save" ] || return 2
    cat "$MOCK_BACKEND_STATE"
}

ufw() {
    [ "${1:-} ${2:-}" = "show raw" ] || return 2
    cat "$MOCK_BACKEND_STATE"
}

firewall-cmd() {
    case "$*" in
        "--direct --get-all-rules") cat "$MOCK_BACKEND_STATE" ;;
        "--list-all-zones"|"--get-ipsets") return 0 ;;
        *) return 2 ;;
    esac
}

# 重试等待在本地 mock 中无需真实耗时。
sleep() {
    :
}

test_action_parser() {
    local -a actions=()
    reset_mock
    mapfile -t actions < <(fail2ban_action_names)
    assert_eq "1" "${#actions[@]}" "应只解析实际 action 名称"
    assert_eq "nftables-multiport" "${actions[0]}" "action 名称解析错误"
}

test_real_local_ipv4_text_prefers_ip_and_falls_back_to_hostname() {
    local bin="$TEST_TMP/local-ipv4-bin" output="$TEST_TMP/local-ipv4.out"

    mkdir -p "$bin"
    cat > "$bin/ip" <<'EOF'
#!/bin/sh
[ "$*" = "-o -4 addr show" ] || exit 2
printf '%s\n' '2: eth0    inet 192.0.2.10/24 scope global eth0'
EOF
    cat > "$bin/hostname" <<'EOF'
#!/bin/sh
exit 99
EOF
    chmod 755 "$bin/ip" "$bin/hostname"

    PATH="$bin" production_fail2ban_local_ipv4_text > "$output" ||
        fail "存在 ip 命令时生产地址枚举应成功"
    assert_file_contains "$output" '192[.]0[.]2[.]10/24'

    rm -f "$bin/ip"
    cat > "$bin/hostname" <<'EOF'
#!/bin/sh
[ "${1:-}" = "-I" ] || exit 2
printf '%s\n' '198.51.100.20 2001:db8::20'
EOF
    chmod 755 "$bin/hostname"

    PATH="$bin" production_fail2ban_local_ipv4_text > "$output" ||
        fail "缺少 ip 时生产地址枚举应回退到 hostname -I"
    assert_file_contains "$output" '^198[.]51[.]100[.]20 2001:db8::20$'
}

test_sshd_config_forces_nftables_banaction() {
    local output="$TEST_TMP/fail2ban-nftables-config.out"

    render_fail2ban_sshd_config 6384 systemd > "$output"
    assert_file_contains "$output" '^banaction = nftables-multiport$' \
        "vpsbox 管理的 sshd jail 应固定使用 nftables"
}

test_missing_nftables_dependency_is_installed_automatically() {
    (
        local nft_ready=0
        local log="$TEST_TMP/fail2ban-nftables-auto-install.log"
        : > "$log"
        command() {
            if [ "${1:-}" = "-v" ] && [ "${2:-}" = "nft" ]; then
                [ "$nft_ready" -eq 1 ]
            else
                builtin command "$@"
            fi
        }
        install_fail2ban_nftables_dependency() {
            printf '%s\n' install >> "$log"
            nft_ready=1
        }
        confirm_default_yes() {
            printf '%s\n' confirm >> "$log"
            return 1
        }

        ensure_fail2ban_nftables_dependency
        assert_file_contains "$log" '^install$' \
            "缺少 nft 时应自动安装 nftables"
        assert_file_not_contains "$log" '^confirm$' \
            "自动补齐 nftables 前不得询问用户"
    )
}

test_nftables_dependency_install_requires_nft_command() {
    (
        local nft_ready=0
        local output="$TEST_TMP/fail2ban-nftables-incomplete.out"
        command() {
            if [ "${1:-}" = "-v" ] && [ "${2:-}" = "nft" ]; then
                [ "$nft_ready" -eq 1 ]
            else
                builtin command "$@"
            fi
        }
        install_fail2ban_nftables_dependency() { return 0; }

        if ensure_fail2ban_nftables_dependency >"$output" 2>&1; then
            fail "nftables 安装后仍缺少 nft 命令时不得继续"
        fi
        assert_file_contains "$output" 'nftables 安装后仍找不到 nft 命令'
    )
}

test_exact_ipv4_match() {
    fail2ban_ipv4_in_text '192.0.2.1' 'elements = { 192.0.2.10 }' &&
        fail "精确匹配不得把 192.0.2.10 识别为 192.0.2.1"
    fail2ban_ipv4_in_text '192.0.2.1' 'elements = { 192.0.2.1/24 }' &&
        fail "精确匹配不得把网段识别为单个测试地址"
    fail2ban_ipv4_in_text '192.0.2.1' 'elements = { 192.0.2.1/32 }' ||
        fail "精确匹配应识别带 /32 的 IPv4"
}

test_supported_backend_snapshots() {
    local backend
    reset_mock
    printf 'rule contains 192.0.2.254/32\n' > "$MOCK_BACKEND_STATE"

    for backend in nftables iptables ipset ufw firewalld; do
        fail2ban_backend_has_ip "$backend" 192.0.2.254 ||
            fail "$backend 后端快照应能找到精确测试地址"
    done
}

assert_action_round_trip() {
    local label="$1" action="$2" actionban="$3" output

    output="$TEST_TMP/action-$label.out"

    reset_mock
    MOCK_ACTION_NAME="$action"
    MOCK_ACTIONBAN="$actionban"
    if ! verify_fail2ban_real_ban > "$output" 2>&1; then
        sed -n '1,120p' "$output" >&2
        fail "$label 官方防火墙动作应完成封禁往返验证"
    fi
    assert_empty_file "$MOCK_JAIL_STATE" "$label 验证后 jail 不应有残留"
    assert_empty_file "$MOCK_BACKEND_STATE" "$label 验证后后端不应有残留"
}

test_supported_action_round_trips() {
    assert_action_round_trip iptables iptables-multiport \
        '/usr/sbin/iptables -w -I f2b-sshd 1 -s <ip> -j REJECT'
    assert_action_round_trip ipset iptables-ipset-proto4 \
        'ipset --test f2b-sshd <ip> || ipset --add f2b-sshd <ip>'
    assert_action_round_trip ufw ufw \
        $'if [ -n "" ] && ufw app info ""\nthen\n  ufw prepend reject from <ip> to any comment "by Fail2Ban"\nelse\n  ufw prepend reject from <ip> to any comment "by Fail2Ban"\nfi'
    assert_action_round_trip firewalld firewallcmd-multiport \
        'firewall-cmd --direct --add-rule ipv4 filter f2b-sshd 0 -s <ip> -j REJECT'
}

test_successful_real_ban_round_trip() {
    local output="$TEST_TMP/success.out"
    reset_mock

    if ! verify_fail2ban_real_ban > "$output" 2>&1; then
        sed -n '1,120p' "$output" >&2
        fail "真实封禁验证的成功路径不应失败"
    fi

    assert_file_contains "$MOCK_CALL_LOG" \
        '^set sshd banip (192\.0\.2\.|198\.51\.100\.|203\.0\.113\.)' \
        "应使用 TEST-NET IPv4 执行手动封禁"
    assert_file_contains "$MOCK_CALL_LOG" '^set sshd unbanip ' "验证后必须解封测试地址"
    assert_empty_file "$MOCK_JAIL_STATE" "验证后 jail 内不应残留测试地址"
    assert_empty_file "$MOCK_BACKEND_STATE" "验证后 nftables 内不应残留测试地址"
    assert_eq "" "$ACTIVE_FAIL2BAN_TEST_IP" "成功清理后应清空活动测试 IP"
}

test_unknown_action_is_rejected_before_ban() {
    local output="$TEST_TMP/unknown-action.out"
    reset_mock
    MOCK_ACTION_NAME="sendmail-whois"
    MOCK_ACTIONBAN="printf '%s' '<ip>' | /usr/sbin/sendmail root"

    if verify_fail2ban_real_ban > "$output" 2>&1; then
        fail "含未知或外部副作用 action 时必须拒绝测试"
    fi

    assert_file_not_contains "$MOCK_CALL_LOG" '^set sshd banip ' \
        "拒绝未知 action 后不得执行手动封禁"
    assert_empty_file "$MOCK_JAIL_STATE"
    assert_empty_file "$MOCK_BACKEND_STATE"
}

test_missing_backend_rule_is_cleaned() {
    local output="$TEST_TMP/missing-backend.out"
    reset_mock
    MOCK_BAN_MODE="jail-only"

    if verify_fail2ban_real_ban > "$output" 2>&1; then
        fail "jail 已记录但真实防火墙未落地时必须报失败"
    fi

    assert_file_contains "$MOCK_CALL_LOG" '^set sshd unbanip ' \
        "部分封禁失败后仍必须尝试解封"
    assert_empty_file "$MOCK_JAIL_STATE" "失败清理后 jail 内不应残留测试地址"
    assert_empty_file "$MOCK_BACKEND_STATE" "失败清理后防火墙内不应残留测试地址"
    assert_eq "" "$ACTIVE_FAIL2BAN_TEST_IP" "清理完成后应清空活动测试 IP"
}

test_cleanup_keeps_residual_state_visible() {
    local output="$TEST_TMP/unban-failure.out" residual_ip status
    reset_mock
    MOCK_UNBAN_FAIL=1

    if verify_fail2ban_real_ban > "$output" 2>&1; then
        fail "无法解封测试地址时验证必须报失败"
    else
        status=$?
    fi

    assert_eq "2" "$status" "存在残留时应返回专用状态码"
    residual_ip="$ACTIVE_FAIL2BAN_TEST_IP"
    [ -n "$residual_ip" ] || fail "解封失败后必须保留活动测试 IP 供再次清理"
    assert_file_contains "$MOCK_JAIL_STATE" "^${residual_ip//./\\.}$" \
        "解封失败场景应能观察到 jail 残留"

    MOCK_UNBAN_FAIL=0
    cleanup_active_fail2ban_test > /dev/null 2>&1 || fail "恢复后再次清理应成功"
    assert_empty_file "$MOCK_JAIL_STATE"
    assert_empty_file "$MOCK_BACKEND_STATE"
    assert_eq "" "$ACTIVE_FAIL2BAN_TEST_IP" "再次清理成功后应清空活动测试 IP"
}

test_runtime_cleanup_reuses_active_unban() {
    reset_mock
    printf '198.51.100.254\n' > "$MOCK_JAIL_STATE"
    printf '198.51.100.254\n' > "$MOCK_BACKEND_STATE"
    ACTIVE_FAIL2BAN_TEST_IP="198.51.100.254"
    ACTIVE_FAIL2BAN_TEST_BACKENDS="nftables"

    cleanup_vpsbox_runtime > /dev/null 2>&1 || fail "全局运行时清理应复用 Fail2ban 解封"
    assert_empty_file "$MOCK_JAIL_STATE"
    assert_empty_file "$MOCK_BACKEND_STATE"
    assert_eq "" "$ACTIVE_FAIL2BAN_TEST_IP"
}

test_stale_active_test_blocks_new_ban() {
    local status old_ip="203.0.113.253"
    reset_mock
    printf '%s\n' "$old_ip" > "$MOCK_JAIL_STATE"
    printf '%s\n' "$old_ip" > "$MOCK_BACKEND_STATE"
    ACTIVE_FAIL2BAN_TEST_IP="$old_ip"
    # shellcheck disable=SC2034 # 被测的运行时清理函数动态读取。
    ACTIVE_FAIL2BAN_TEST_BACKENDS="nftables"
    MOCK_UNBAN_FAIL=1

    if verify_fail2ban_real_ban > "$TEST_TMP/stale-active.out" 2>&1; then
        fail "旧测试地址未清理时不得启动新验证"
    else
        status=$?
    fi
    assert_eq "2" "$status"
    assert_eq "$old_ip" "$ACTIVE_FAIL2BAN_TEST_IP" "不得覆盖旧的活动测试地址"
    assert_file_not_contains "$MOCK_CALL_LOG" '^set sshd banip ' "不得封禁新的测试地址"

    MOCK_UNBAN_FAIL=0
    cleanup_active_fail2ban_test >/dev/null 2>&1 || fail "测试收尾应能清理旧地址"
}

test_sync_deep_validation_failure_warns_and_commits() {
    local sync_dir="$TEST_TMP/sync-advisory" systemctl_log="$TEST_TMP/systemctl-advisory.log"
    local output="$TEST_TMP/sync-advisory.out"
    reset_mock
    mkdir -p "$sync_dir"
    FAIL2BAN_CONFIG_DIR="$sync_dir"
    FAIL2BAN_VPSBOX_SSHD_CONF="$sync_dir/99-vpsbox-sshd.local"
    printf 'old-config\n' > "$FAIL2BAN_VPSBOX_SSHD_CONF"
    : > "$systemctl_log"
    MOCK_ACTION_NAME="sendmail-whois"
    MOCK_ACTIONBAN="/usr/sbin/sendmail root"

    fail2ban_installed() { return 0; }
    fail2ban_service_state() { printf '运行中\n'; }
    fail2ban_service_is_enabled() { return 0; }
    manifest_set_once() { return 0; }
    backup_change_file_once() { return 0; }
    begin_change_transaction() { return 0; }
    ssh_effective_ports_csv() { printf '6384\n'; }
    is_systemd() { return 0; }
    chown() { return 0; }
    systemctl() { printf '%s\n' "$*" >> "$systemctl_log"; }
    mark_change_applied() { printf 'marked\n' >> "$systemctl_log"; }

    sync_fail2ban_sshd_port > "$output" 2>&1 ||
        fail "真实封禁普通失败不得否定已通过基础验收的配置"
    assert_file_contains "$FAIL2BAN_VPSBOX_SSHD_CONF" '^port = 6384$' \
        "深度检测普通失败后应保留新配置"
    assert_file_not_contains "$FAIL2BAN_VPSBOX_SSHD_CONF" '^old-config$' \
        "深度检测普通失败不得恢复旧配置"
    assert_file_contains "$output" '真实封禁深度检测未通过；已保留当前配置' \
        "普通深度检测失败应明确降级为警告"
    assert_file_not_contains "$output" '\[ERR\]' \
        "普通深度检测失败不得显示为硬错误"
    assert_file_not_contains "$output" '已恢复同步前的配置与服务状态' \
        "普通深度检测失败不得触发回滚"
    assert_file_contains "$systemctl_log" '^marked$' \
        "基础验收通过后必须标记变更已应用"
}

test_sync_config_precheck_failure_rolls_back() {
    local sync_dir="$TEST_TMP/sync-config-failure"
    local systemctl_log="$TEST_TMP/systemctl-config-failure.log"
    local config_checks=0
    reset_mock
    mkdir -p "$sync_dir"
    FAIL2BAN_CONFIG_DIR="$sync_dir"
    FAIL2BAN_VPSBOX_SSHD_CONF="$sync_dir/99-vpsbox-sshd.local"
    printf 'old-config\n' > "$FAIL2BAN_VPSBOX_SSHD_CONF"
    : > "$systemctl_log"

    fail2ban_installed() { return 0; }
    fail2ban_service_state() { printf '运行中\n'; }
    fail2ban_service_is_enabled() { return 0; }
    manifest_set_once() { return 0; }
    backup_change_file_once() { return 0; }
    begin_change_transaction() { return 0; }
    ssh_effective_ports_csv() { printf '6384\n'; }
    is_systemd() { return 0; }
    chown() { return 0; }
    systemctl() { printf '%s\n' "$*" >> "$systemctl_log"; }
    mark_change_applied() { printf 'marked\n' >> "$systemctl_log"; }
    fail2ban-client() {
        if [ "${1:-}" = "-t" ]; then
            config_checks=$((config_checks + 1))
            [ "$config_checks" -gt 1 ]
            return
        fi
        return 0
    }

    if sync_fail2ban_sshd_port > "$TEST_TMP/sync-config-failure.out" 2>&1; then
        fail "Fail2ban 配置预检失败时同步不得成功"
    fi
    assert_file_contains "$FAIL2BAN_VPSBOX_SSHD_CONF" '^old-config$' \
        "配置预检失败后必须恢复旧配置"
    assert_file_contains "$systemctl_log" '^restart fail2ban$' \
        "恢复旧配置后必须恢复原运行状态"
    assert_file_not_contains "$systemctl_log" '^marked$' \
        "配置预检失败不得标记变更已应用"
}

test_sync_service_failure_rolls_back() {
    local sync_dir="$TEST_TMP/sync-service-failure"
    local systemctl_log="$TEST_TMP/systemctl-service-failure.log"
    local restart_calls=0
    reset_mock
    mkdir -p "$sync_dir"
    FAIL2BAN_CONFIG_DIR="$sync_dir"
    FAIL2BAN_VPSBOX_SSHD_CONF="$sync_dir/99-vpsbox-sshd.local"
    printf 'old-config\n' > "$FAIL2BAN_VPSBOX_SSHD_CONF"
    : > "$systemctl_log"

    fail2ban_installed() { return 0; }
    fail2ban_service_state() { printf '运行中\n'; }
    fail2ban_service_is_enabled() { return 0; }
    manifest_set_once() { return 0; }
    backup_change_file_once() { return 0; }
    begin_change_transaction() { return 0; }
    ssh_effective_ports_csv() { printf '6384\n'; }
    is_systemd() { return 0; }
    chown() { return 0; }
    systemctl() {
        printf '%s\n' "$*" >> "$systemctl_log"
        if [ "${1:-}" = "restart" ]; then
            restart_calls=$((restart_calls + 1))
            [ "$restart_calls" -gt 3 ]
            return
        fi
        return 0
    }
    mark_change_applied() { printf 'marked\n' >> "$systemctl_log"; }

    if sync_fail2ban_sshd_port > "$TEST_TMP/sync-service-failure.out" 2>&1; then
        fail "Fail2ban 服务重启失败时同步不得成功"
    fi
    assert_file_contains "$FAIL2BAN_VPSBOX_SSHD_CONF" '^old-config$' \
        "服务重启失败后必须恢复旧配置"
    assert_eq 4 "$(grep -c '^restart fail2ban$' "$systemctl_log")" \
        "三次服务重试失败后应再重启一次恢复旧配置"
    assert_file_not_contains "$systemctl_log" '^marked$' \
        "服务重启失败不得标记变更已应用"
}

test_sync_jail_not_ready_rolls_back() {
    local sync_dir="$TEST_TMP/sync-jail-failure"
    local systemctl_log="$TEST_TMP/systemctl-jail-failure.log"
    reset_mock
    mkdir -p "$sync_dir"
    FAIL2BAN_CONFIG_DIR="$sync_dir"
    FAIL2BAN_VPSBOX_SSHD_CONF="$sync_dir/99-vpsbox-sshd.local"
    printf 'old-config\n' > "$FAIL2BAN_VPSBOX_SSHD_CONF"
    : > "$systemctl_log"

    fail2ban_installed() { return 0; }
    fail2ban_service_state() { printf '运行中\n'; }
    fail2ban_service_is_enabled() { return 0; }
    manifest_set_once() { return 0; }
    backup_change_file_once() { return 0; }
    begin_change_transaction() { return 0; }
    ssh_effective_ports_csv() { printf '6384\n'; }
    is_systemd() { return 0; }
    chown() { return 0; }
    systemctl() { printf '%s\n' "$*" >> "$systemctl_log"; }
    mark_change_applied() { printf 'marked\n' >> "$systemctl_log"; }
    fail2ban-client() {
        [ "${1:-}" = "-t" ] && return 0
        [ "${1:-} ${2:-}" != "status sshd" ]
    }

    if sync_fail2ban_sshd_port > "$TEST_TMP/sync-jail-failure.out" 2>&1; then
        fail "sshd jail 未就绪时同步不得成功"
    fi
    assert_file_contains "$FAIL2BAN_VPSBOX_SSHD_CONF" '^old-config$' \
        "sshd jail 未就绪时必须恢复旧配置"
    assert_file_contains "$systemctl_log" '^restart fail2ban$' \
        "jail 验证失败后必须恢复原服务状态"
    assert_file_not_contains "$systemctl_log" '^marked$' \
        "jail 未就绪不得标记变更已应用"
}

test_sync_port_mismatch_rolls_back() {
    local sync_dir="$TEST_TMP/sync-port-mismatch"
    local systemctl_log="$TEST_TMP/systemctl-port-mismatch.log"
    reset_mock
    mkdir -p "$sync_dir"
    FAIL2BAN_CONFIG_DIR="$sync_dir"
    FAIL2BAN_VPSBOX_SSHD_CONF="$sync_dir/99-vpsbox-sshd.local"
    printf 'old-config\n' > "$FAIL2BAN_VPSBOX_SSHD_CONF"
    : > "$systemctl_log"

    fail2ban_installed() { return 0; }
    fail2ban_service_state() { printf '运行中\n'; }
    fail2ban_service_is_enabled() { return 0; }
    fail2ban_sshd_state() { printf '端口未同步\n'; }
    manifest_set_once() { return 0; }
    backup_change_file_once() { return 0; }
    begin_change_transaction() { return 0; }
    ssh_effective_ports_csv() { printf '6384\n'; }
    is_systemd() { return 0; }
    chown() { return 0; }
    systemctl() { printf '%s\n' "$*" >> "$systemctl_log"; }
    mark_change_applied() { printf 'marked\n' >> "$systemctl_log"; }

    if sync_fail2ban_sshd_port > "$TEST_TMP/sync-port-mismatch.out" 2>&1; then
        fail "Fail2ban 端口与 SSH 生效端口不一致时同步不得成功"
    fi
    assert_file_contains "$FAIL2BAN_VPSBOX_SSHD_CONF" '^old-config$' \
        "端口一致性验证失败时必须恢复旧配置"
    assert_file_not_contains "$systemctl_log" '^marked$' \
        "端口不一致不得标记变更已应用"
}

test_sync_residual_test_ip_commits_without_rollback_then_fails() {
    local sync_dir="$TEST_TMP/sync-residual"
    local transition_log="$TEST_TMP/systemctl-residual.log"
    local output="$TEST_TMP/sync-residual.out"
    local running=0
    reset_mock
    mkdir -p "$sync_dir"
    FAIL2BAN_CONFIG_DIR="$sync_dir"
    FAIL2BAN_VPSBOX_SSHD_CONF="$sync_dir/99-vpsbox-sshd.local"
    printf 'old-config\n' > "$FAIL2BAN_VPSBOX_SSHD_CONF"
    : > "$transition_log"

    fail2ban_installed() { return 0; }
    fail2ban_service_state() {
        [ "$running" -eq 1 ] && printf '运行中\n' || printf '未运行\n'
    }
    fail2ban_service_is_enabled() { return 1; }
    manifest_set_once() { return 0; }
    backup_change_file_once() { return 0; }
    begin_change_transaction() { return 0; }
    ssh_effective_ports_csv() { printf '6384\n'; }
    is_systemd() { return 0; }
    chown() { return 0; }
    systemctl() {
        case "${1:-}" in
            start|restart) running=1 ;;
            stop) running=0 ;;
        esac
        printf '%s\n' "$*" >> "$transition_log"
    }
    verify_fail2ban_real_ban_advisory() {
        ACTIVE_FAIL2BAN_TEST_IP="192.0.2.254"
        return 2
    }
    mark_change_applied() { printf 'marked\n' >> "$transition_log"; }

    if sync_fail2ban_sshd_port > "$output" 2>&1; then
        fail "测试地址未清理时同步必须返回失败"
    fi
    assert_eq $'start fail2ban\nstop fail2ban\nmarked' "$(cat "$transition_log")" \
        "残留失败前必须先恢复原停止状态并标记基础变更已应用"
    assert_eq 0 "$running" "残留失败后必须恢复原运行状态"
    assert_file_contains "$FAIL2BAN_VPSBOX_SSHD_CONF" '^port = 6384$' \
        "测试地址残留不得回滚已通过基础验收的新配置"
    assert_file_not_contains "$FAIL2BAN_VPSBOX_SSHD_CONF" '^old-config$' \
        "测试地址残留不得恢复旧配置"
    assert_file_contains "$output" '基础配置已通过并保留' \
        "残留失败应明确说明基础配置已保留"
}

test_sync_restores_initial_stopped_state() {
    local sync_dir="$TEST_TMP/sync-stopped" systemctl_log="$TEST_TMP/systemctl-stopped.log"
    local running=0
    reset_mock
    mkdir -p "$sync_dir"
    # shellcheck disable=SC2034 # 被测同步函数动态读取。
    FAIL2BAN_CONFIG_DIR="$sync_dir"
    FAIL2BAN_VPSBOX_SSHD_CONF="$sync_dir/99-vpsbox-sshd.local"
    : > "$systemctl_log"

    fail2ban_installed() { return 0; }
    fail2ban_service_state() { [ "$running" -eq 1 ] && printf '运行中\n' || printf '未运行\n'; }
    fail2ban_service_is_enabled() { return 1; }
    manifest_set_once() { return 0; }
    backup_change_file_once() { return 0; }
    begin_change_transaction() { return 0; }
    ssh_effective_ports_csv() { printf '2222\n'; }
    is_systemd() { return 0; }
    systemctl() {
        printf '%s\n' "$*" >> "$systemctl_log"
        case "${1:-}" in
            start|restart) running=1 ;;
            stop) running=0 ;;
        esac
    }
    mark_change_applied() { printf 'marked\n' >> "$systemctl_log"; }

    sync_fail2ban_sshd_port > "$TEST_TMP/sync-stopped.out" 2>&1 ||
        fail "原本停止的 Fail2ban 应能临时验证并恢复停止状态"
    assert_file_contains "$systemctl_log" '^start fail2ban$' "验证前应临时启动 Fail2ban"
    assert_file_contains "$systemctl_log" '^stop fail2ban$' "验证后应恢复原停止状态"
    assert_file_contains "$systemctl_log" '^marked$'
    assert_eq 0 "$running" "同步后不得把原本停止的 Fail2ban 留在运行状态"
}

test_sync_healthy_configuration_only_checks_nftables_dependency() {
    (
        local log="$TEST_TMP/fail2ban-sync-healthy.log"
        : > "$log"
        fail2ban_installed() { return 0; }
        fail2ban_sshd_configuration_healthy() { return 0; }
        ensure_fail2ban_nftables_dependency() { printf '%s\n' dependency >> "$log"; }
        manifest_set_once() { printf '%s\n' manifest >> "$log"; }
        backup_change_file_once() { printf '%s\n' backup >> "$log"; }
        verify_fail2ban_real_ban() { printf '%s\n' ban-test >> "$log"; }

        sync_fail2ban_sshd_port >/dev/null
        assert_eq dependency "$(cat "$log")" \
            "健康配置只应复核 nftables 依赖，不得备份、改写或测试封禁"
    )
}

test_fail2ban_health_requires_canonical_current_config() {
    (
        local dir="$TEST_TMP/fail2ban-health"
        reset_mock
        mkdir -p "$dir"
        FAIL2BAN_VPSBOX_SSHD_CONF="$dir/99-vpsbox-sshd.local"
        render_fail2ban_sshd_config 22222 systemd > "$FAIL2BAN_VPSBOX_SSHD_CONF"
        fail2ban_installed() { return 0; }
        fail2ban_service_state() { printf '运行中\n'; }
        fail2ban_service_is_enabled() { return 0; }
        ssh_effective_ports_csv() { printf '22222\n'; }
        is_systemd() { return 0; }

        fail2ban_sshd_configuration_healthy ||
            fail "规范配置、端口及服务状态正常时应识别为健康"
        MOCK_ACTION_NAME="iptables-multiport"
        MOCK_ACTIONBAN="/usr/sbin/iptables -w -I f2b-sshd 1 -s <ip> -j REJECT"
        if fail2ban_sshd_configuration_healthy; then
            fail "配置文件正确但运行态仍使用 iptables 时不得识别为健康"
        fi
        MOCK_ACTION_NAME="nftables-multiport"
        MOCK_ACTIONBAN="/usr/sbin/nft add element inet f2b-table addr-set-sshd { <ip> }"
        printf 'port = 22\n' >> "$FAIL2BAN_VPSBOX_SSHD_CONF"
        if fail2ban_sshd_configuration_healthy; then
            fail "含额外漂移内容的 Fail2ban 配置不得跳过同步"
        fi
    )
}

test_install_fail2ban_healthy_only_checks_nftables_dependency() {
    (
        local log="$TEST_TMP/fail2ban-install-healthy.log"
        : > "$log"
        detect_os() { OS=debian; }
        fail2ban_sshd_configuration_healthy() { return 0; }
        ensure_fail2ban_nftables_dependency() { printf '%s\n' dependency >> "$log"; }
        fail2ban_installed() { printf '%s\n' installed-check >> "$log"; return 0; }
        apt_get_bounded() { printf '%s\n' package >> "$log"; }
        ensure_fail2ban_service_running() { printf '%s\n' service >> "$log"; }
        sync_fail2ban_sshd_port() { printf '%s\n' sync >> "$log"; }

        install_fail2ban >/dev/null
        assert_eq dependency "$(cat "$log")" \
            "健康的 Fail2ban 只应复核 nftables 依赖，不得触发其他包管理或服务修改"
    )
}

test_installed_fail2ban_repairs_without_package_manager() {
    (
        local log="$TEST_TMP/fail2ban-install-repair.log"
        : > "$log"
        detect_os() { OS=debian; }
        fail2ban_sshd_configuration_healthy() { return 1; }
        fail2ban_installed() { return 0; }
        apt_get_bounded() { printf '%s\n' package >> "$log"; }
        ensure_fail2ban_service_running() { printf '%s\n' service >> "$log"; }
        sync_fail2ban_sshd_port() { printf '%s\n' sync >> "$log"; }
        fail2ban_service_is_enabled() { return 0; }
        fail2ban_service_state() { printf '运行中\n'; }
        fail2ban_sshd_state() { printf '已启用\n'; }
        ssh_effective_ports_csv() { printf '22222\n'; }
        ensure_change_store() { printf '%s\n' change-store >> "$log"; }
        backup_change_file_once() { printf 'backup:%s\n' "$1" >> "$log"; }
        manifest_set_once() { printf 'manifest:%s=%s\n' "$1" "$2" >> "$log"; }
        begin_change_transaction() { printf 'begin:%s\n' "$1" >> "$log"; }
        mark_change_applied() { printf 'applied:%s\n' "$1" >> "$log"; }

        install_fail2ban >/dev/null
        assert_file_contains "$log" '^service$'
        assert_file_contains "$log" '^sync$'
        assert_file_not_contains "$log" '^package$' "已安装时不得访问软件源"
    )
}

test_install_fail2ban_records_service_state_before_mutation() {
    (
        local log="$TEST_TMP/fail2ban-install-baseline.log"
        local running=0 enabled=0
        : > "$log"
        detect_os() { OS=debian; }
        fail2ban_sshd_configuration_healthy() { return 1; }
        fail2ban_installed() { return 0; }
        fail2ban_service_state() {
            [ "$running" -eq 1 ] && printf '运行中\n' || printf '未运行\n'
        }
        fail2ban_service_is_enabled() { [ "$enabled" -eq 1 ]; }
        ensure_change_store() { printf '%s\n' change-store >> "$log"; }
        backup_change_file_once() { printf 'backup:%s\n' "$1" >> "$log"; }
        manifest_set_once() { printf 'manifest:%s=%s\n' "$1" "$2" >> "$log"; }
        begin_change_transaction() { printf 'begin:%s\n' "$1" >> "$log"; }
        ensure_fail2ban_service_running() {
            printf '%s\n' service-mutation >> "$log"
            running=1
            enabled=1
        }
        sync_fail2ban_sshd_port() { printf '%s\n' sync >> "$log"; }
        fail2ban_sshd_state() { printf '已启用\n'; }
        ssh_effective_ports_csv() { printf '22222\n'; }
        mark_change_applied() { printf 'applied:%s\n' "$1" >> "$log"; }

        install_fail2ban >/dev/null

        assert_file_contains "$log" '^manifest:FAIL2BAN_ACTIVE=inactive$'
        assert_file_contains "$log" '^manifest:FAIL2BAN_ENABLED=disabled$'
        assert_file_contains "$log" '^begin:FAIL2BAN_SSHD$'
        assert_file_contains "$log" '^applied:FAIL2BAN_SSHD$'
        [ "$(grep -n '^manifest:FAIL2BAN_ACTIVE=' "$log" | cut -d: -f1)" -lt \
            "$(grep -n '^service-mutation$' "$log" | cut -d: -f1)" ] ||
            fail "Fail2ban 运行状态必须在服务启动前记录"
        [ "$(grep -n '^manifest:FAIL2BAN_ENABLED=' "$log" | cut -d: -f1)" -lt \
            "$(grep -n '^service-mutation$' "$log" | cut -d: -f1)" ] ||
            fail "Fail2ban 自启状态必须在服务启用前记录"
    )
}

test_fail2ban_service_state_does_not_require_client_binary() {
    (
        fail2ban_installed() { return 1; }
        is_systemd() { return 0; }
        systemctl() {
            [ "${1:-}" = is-active ] && [ "${3:-}" = fail2ban ]
        }

        assert_eq "运行中" "$(fail2ban_service_state)" \
            "fail2ban-client 缺失时仍应按服务管理器记录真实运行状态"
    )
}

test_install_fail2ban_first_install_records_baseline_before_package_mutation() {
    (
        local log="$TEST_TMP/fail2ban-first-install-baseline.log"
        local installed=0 running=0 enabled=0
        local manifest_active_line manifest_enabled_line begin_line package_line
        : > "$log"
        detect_os() { OS=debian; }
        fail2ban_sshd_configuration_healthy() { return 1; }
        fail2ban_installed() { [ "$installed" -eq 1 ]; }
        fail2ban_service_state() {
            [ "$running" -eq 1 ] && printf '运行中\n' || printf '未运行\n'
        }
        fail2ban_service_is_enabled() { [ "$enabled" -eq 1 ]; }
        ensure_change_store() { printf '%s\n' change-store >> "$log"; }
        backup_change_file_once() { printf 'backup:%s\n' "$1" >> "$log"; }
        manifest_set_once() { printf 'manifest:%s=%s\n' "$1" "$2" >> "$log"; }
        begin_change_transaction() { printf 'begin:%s\n' "$1" >> "$log"; }
        apt_get_bounded() {
            if [ "${2:-}" = install ]; then
                printf 'package-args:%s\n' "$*" >> "$log"
                printf '%s\n' package-mutation >> "$log"
                installed=1
                running=1
                enabled=1
            fi
        }
        ensure_fail2ban_service_running() { printf '%s\n' service-check >> "$log"; }
        sync_fail2ban_sshd_port() { printf '%s\n' sync >> "$log"; }
        fail2ban_sshd_state() { printf '已启用\n'; }
        ssh_effective_ports_csv() { printf '22222\n'; }
        mark_change_applied() { printf 'applied:%s\n' "$1" >> "$log"; }

        install_fail2ban >/dev/null

        assert_file_contains "$log" '^manifest:FAIL2BAN_ACTIVE=inactive$'
        assert_file_contains "$log" '^manifest:FAIL2BAN_ENABLED=disabled$'
        assert_file_contains "$log" '^begin:FAIL2BAN_SSHD$'
        assert_file_contains "$log" '^package-mutation$'
        assert_file_contains "$log" \
            '^package-args:[0-9][0-9]* install -y fail2ban nftables$' \
            "首次安装 Fail2ban 应同时安装 nftables"
        manifest_active_line="$(grep -n '^manifest:FAIL2BAN_ACTIVE=' "$log" | cut -d: -f1)"
        manifest_enabled_line="$(grep -n '^manifest:FAIL2BAN_ENABLED=' "$log" | cut -d: -f1)"
        begin_line="$(grep -n '^begin:FAIL2BAN_SSHD$' "$log" | cut -d: -f1)"
        package_line="$(grep -n '^package-mutation$' "$log" | cut -d: -f1)"
        [ "$manifest_active_line" -lt "$package_line" ] &&
            [ "$manifest_enabled_line" -lt "$package_line" ] &&
            [ "$begin_line" -lt "$package_line" ] ||
            fail "Fail2ban 首次安装前必须先记录运行、自启基线并建立事务"
    )
}

test_install_fail2ban_failure_keeps_pending_baseline() {
    (
        local log="$TEST_TMP/fail2ban-install-pending.log"
        : > "$log"
        # shellcheck disable=SC2034 # 被测安装函数动态读取。
        detect_os() { OS=debian; }
        fail2ban_sshd_configuration_healthy() { return 1; }
        fail2ban_installed() { return 0; }
        fail2ban_service_state() { printf '未运行\n'; }
        fail2ban_service_is_enabled() { return 1; }
        ensure_change_store() { :; }
        backup_change_file_once() { printf 'backup:%s\n' "$1" >> "$log"; }
        manifest_set_once() { printf 'manifest:%s=%s\n' "$1" "$2" >> "$log"; }
        begin_change_transaction() { printf 'pending:%s\n' "$1" >> "$log"; }
        ensure_fail2ban_service_running() { return 42; }
        mark_change_applied() { printf '%s\n' applied >> "$log"; }

        if install_fail2ban >/dev/null 2>&1; then
            fail "Fail2ban 服务启动失败时安装流程不得成功"
        fi
        assert_file_contains "$log" '^pending:FAIL2BAN_SSHD$'
        assert_file_not_contains "$log" '^applied$' "失败后不得把事务标记为已应用"
        assert_file_contains "$log" '^manifest:FAIL2BAN_ACTIVE=inactive$'
        assert_file_contains "$log" '^manifest:FAIL2BAN_ENABLED=disabled$'
    )
}

test_fail2ban_backup_rotation_keeps_five() {
    local dir="$TEST_TMP/fail2ban-backups" i count
    mkdir -p "$dir"
    FAIL2BAN_VPSBOX_SSHD_CONF="$dir/99-vpsbox-sshd.local"
    for i in {1..8}; do
        printf '%s\n' "$i" > "${FAIL2BAN_VPSBOX_SSHD_CONF}.bak.2026010100000${i}"
    done

    prune_fail2ban_sshd_backups
    count="$(find "$dir" -maxdepth 1 -type f -name '*.bak.*' | wc -l | tr -d ' ')"
    assert_eq 5 "$count" "Fail2ban 历史备份应只保留最近 5 份"
    [ ! -e "${FAIL2BAN_VPSBOX_SSHD_CONF}.bak.20260101000001" ] || fail "最旧备份未删除"
    [ -e "${FAIL2BAN_VPSBOX_SSHD_CONF}.bak.20260101000008" ] || fail "最新备份不应删除"
}

test_fail2ban_atomic_restore_preserves_current_on_failure() {
    (
        local dir="$TEST_TMP/fail2ban-atomic-restore"
        mkdir -p "$dir"
        FAIL2BAN_VPSBOX_SSHD_CONF="$dir/99-vpsbox-sshd.local"
        printf '%s\n' old > "$dir/backup"
        printf '%s\n' current > "$FAIL2BAN_VPSBOX_SSHD_CONF"
        chown() { return 0; }
        mv() { return 1; }

        if restore_fail2ban_sshd_config_file "$dir/backup"; then
            fail "Fail2ban 原子恢复替换失败时不得报告成功"
        fi
        assert_file_contains "$FAIL2BAN_VPSBOX_SSHD_CONF" '^current$'
    )
}

test_fail2ban_rollback_failure_is_reported() {
    (
        local output="$TEST_TMP/fail2ban-rollback-failure.out"
        restore_fail2ban_sshd_sync_state() { return 23; }

        if fail2ban_sync_failure_with_rollback "Fail2ban 测试失败" "" 0 >"$output" 2>&1; then
            fail "Fail2ban 回滚失败路径不得报告成功"
        fi
        assert_file_contains "$output" '同步前状态未能完整恢复'
        assert_file_not_contains "$output" '已恢复同步前的配置与服务状态'
    )
}

main() {
    local -a required=(
        fail2ban_action_names
        fail2ban_ipv4_in_text
        production_fail2ban_local_ipv4_text
        ensure_fail2ban_nftables_dependency
        verify_fail2ban_real_ban
        verify_fail2ban_real_ban_advisory
        cleanup_active_fail2ban_test
    )
    local name test status passed=0 skipped=0
    local -a tests=(
        test_action_parser
        test_real_local_ipv4_text_prefers_ip_and_falls_back_to_hostname
        test_sshd_config_forces_nftables_banaction
        test_missing_nftables_dependency_is_installed_automatically
        test_nftables_dependency_install_requires_nft_command
        test_exact_ipv4_match
        test_supported_backend_snapshots
        test_supported_action_round_trips
        test_successful_real_ban_round_trip
        test_unknown_action_is_rejected_before_ban
        test_missing_backend_rule_is_cleaned
        test_cleanup_keeps_residual_state_visible
        test_runtime_cleanup_reuses_active_unban
        test_stale_active_test_blocks_new_ban
        test_sync_deep_validation_failure_warns_and_commits
        test_sync_config_precheck_failure_rolls_back
        test_sync_service_failure_rolls_back
        test_sync_jail_not_ready_rolls_back
        test_sync_port_mismatch_rolls_back
        test_sync_residual_test_ip_commits_without_rollback_then_fails
        test_sync_restores_initial_stopped_state
        test_sync_healthy_configuration_only_checks_nftables_dependency
        test_fail2ban_health_requires_canonical_current_config
        test_install_fail2ban_healthy_only_checks_nftables_dependency
        test_installed_fail2ban_repairs_without_package_manager
        test_install_fail2ban_records_service_state_before_mutation
        test_fail2ban_service_state_does_not_require_client_binary
        test_install_fail2ban_first_install_records_baseline_before_package_mutation
        test_install_fail2ban_failure_keeps_pending_baseline
        test_fail2ban_backup_rotation_keeps_five
        test_fail2ban_atomic_restore_preserves_current_on_failure
        test_fail2ban_rollback_failure_is_reported
    )

    for name in "${required[@]}"; do
        require_function "$name"
    done

    assert_all_tests_registered "${BASH_SOURCE[0]}" "${tests[@]}" || return 1
    for test in "${tests[@]}"; do
        set +e
        run_test_case "$test"
        status=$?
        set -e
        case "$status" in
            0)
                printf 'ok - %s\n' "$test"
                passed=$((passed + 1))
                ;;
            "$SKIP_STATUS")
                printf 'ok - %s # SKIP %s\n' "$test" "$(test_skip_reason)"
                skipped=$((skipped + 1))
                ;;
            *)
                printf 'not ok - %s\n' "$test" >&2
                return 1
                ;;
        esac
    done

    printf '%s Fail2Ban mock tests passed, %s skipped, %s registered.\n' \
        "$passed" "$skipped" "${#tests[@]}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
