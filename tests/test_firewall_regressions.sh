#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=tests/test_helper.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

# shellcheck source=../vpsbox.sh
source "$REPO_DIR/vpsbox.sh"

CASE_PIDS=""
CASE_PID_FILE="$TEST_TMP/firewall-case-pids"
: > "$CASE_PID_FILE"

record_case_pid() {
    local pid="$1" start_ticks

    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    start_ticks="$(process_start_ticks "$pid" 2>/dev/null)" || return 1
    [[ "$start_ticks" =~ ^[0-9]+$ ]] || return 1
    CASE_PIDS="$CASE_PIDS $pid"
    printf '%s %s\n' "$pid" "$start_ticks" >> "$CASE_PID_FILE"
}

case_pid_list() {
    [ -f "$CASE_PID_FILE" ] && [ ! -L "$CASE_PID_FILE" ] || return 1
    awk '
        $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && NF == 2 {
            key = $1 ":" $2
            if (!seen[key]++) print $1, $2
        }
    ' "$CASE_PID_FILE"
}

cleanup_case_pids() {
    local pid recorded_ticks current_ticks entries killed=""

    entries="$(case_pid_list 2>/dev/null || true)"
    while read -r pid recorded_ticks; do
        [ -n "$pid" ] || continue
        current_ticks="$(process_start_ticks "$pid" 2>/dev/null || true)"
        [ -n "$current_ticks" ] && [ "$current_ticks" = "$recorded_ticks" ] || continue
        if kill -KILL "$pid" 2>/dev/null; then
            killed="$killed $pid"
        fi
    done <<< "$entries"
    for pid in $killed; do
        wait "$pid" 2>/dev/null || true
    done
    CASE_PIDS=""
    if [ -f "$CASE_PID_FILE" ] && [ ! -L "$CASE_PID_FILE" ]; then
        : > "$CASE_PID_FILE"
    fi
}

test_cleanup() {
    cleanup_case_pids
    if [ "${KEEP_TEST_TMP:-0}" = "1" ]; then
        printf '保留测试临时目录：%s\n' "$TEST_TMP" >&2
    else
        rm -rf -- "$TEST_TMP"
    fi
}
trap test_cleanup EXIT

wait_for_file() {
    local path="$1"

    for _ in {1..50}; do
        [ -s "$path" ] && return 0
        sleep 0.1
    done
    fail "等待文件超时：$path"
}

process_children() {
    local pid="$1"

    cat "/proc/$pid/task/$pid/children" 2>/dev/null || true
}

remember_process_tree() {
    local pid="$1" child

    for child in $(process_children "$pid"); do
        record_case_pid "$child"
        remember_process_tree "$child"
    done
}

assert_fd_closed() {
    local pid="$1" fd="$2" message="$3"

    [ ! -e "/proc/$pid/fd/$fd" ] || fail "$message（PID $pid 仍持有 FD $fd）"
}

assert_lock_available() {
    local path="$1" message="$2"

    exec 201<>"$path"
    if ! flock -n 201; then
        exec 201>&-
        fail "$message"
        return 1
    fi
    flock -u 201
    exec 201>&-
}

emit_public_listener_sample() {
    printf '%s\n' \
        'udp UNCONN 0 0 0.0.0.0:30000 0.0.0.0:* users:(("sing-box",pid=759,fd=8))' \
        'udp UNCONN 0 0 1.1.1.1:68 0.0.0.0:* users:(("dhcpcd",pid=623,fd=3))' \
        'udp UNCONN 0 0 *:443 *:* users:(("caddy",pid=754,fd=7))' \
        'udp UNCONN 0 0 [2606:4700:4700::1111]:546 [::]:* users:(("dhcpcd",pid=730,fd=3))' \
        'udp UNCONN 0 0 [fe80::1234]%ens3:546 [::]:* users:(("dhcpcd",pid=604,fd=3))' \
        'tcp LISTEN 0 128 0.0.0.0:22222 0.0.0.0:* users:(("sshd",pid=779,fd=6))' \
        'tcp LISTEN 0 4096 0.0.0.0:30000 0.0.0.0:* users:(("sing-box",pid=759,fd=7))' \
        'tcp LISTEN 0 128 [::]:22222 [::]:* users:(("sshd",pid=779,fd=7))' \
        'tcp LISTEN 0 4096 *:443 *:* users:(("caddy",pid=754,fd=6))' \
        'tcp LISTEN 0 4096 *:80 *:* users:(("caddy",pid=754,fd=8))' \
        'tcp LISTEN 0 4096 127.0.0.1:2019 0.0.0.0:* users:(("caddy",pid=754,fd=9))' \
        'tcp LISTEN 0 4096 10.0.0.2:3001 0.0.0.0:* users:(("private-api",pid=900,fd=3))' \
        'tcp LISTEN 0 4096 100.64.1.2:41641 0.0.0.0:* users:(("tailscaled",pid=901,fd=3))'
}

test_port_decimal_normalization() {
    local normalized

    normalized="$(normalize_port_csv "00080,80,00443,443,65535")"
    assert_eq "80,443,65535" "$normalized" "端口 CSV 应统一为十进制并去重"
    normalize_port_decimal "00080" | grep -qx 80 ||
        fail "旧状态中的前导零端口应可规范为十进制"
    is_valid_port 80 || fail "规范十进制端口应通过交互校验"
    if is_valid_port 00080; then
        fail "交互端口不应接受带前导零的非规范表示"
    fi
    if normalize_port_decimal 00000 >/dev/null; then
        fail "端口 0 不应通过规范化"
    fi
}

test_public_listener_address_classification() {
    local addr

    for addr in 0.0.0.0 '*' :: '[::]' 1.1.1.1 192.0.0.9 192.0.0.10 192.0.1.1 \
        2606:4700:4700::1111 100:1::1 2001:3::1 3fff:1000::1 ::ffff:0808:0808; do
        is_public_listen_addr "$addr" || fail "应识别为公网监听地址：$addr"
    done
    for addr in 127.0.0.1 ::1 10.0.0.1 100.64.1.2 169.254.1.1 172.16.0.1 \
        192.0.0.1 192.0.2.1 192.168.1.1 198.18.0.1 203.0.113.1 \
        fe80::1%ens3 '[fe80::1]%ens3' fd00::1 ff02::1 100::1 100:0:0:1::1 \
        2001:2::1 2001:10::1 2001:1f::1 2001:20::1 2001:2f::1 \
        2001:db8::1 3fff:0fff::1 ::ffff:c0a8:101; do
        if is_public_listen_addr "$addr"; then
            fail "不应识别为公网监听地址：$addr"
        fi
    done
}

test_listener_sample_collects_expected_public_ports() {
    (
        ss() { emit_public_listener_sample; }

        firewall_detect_public_listeners
        assert_eq '80,443,22222,30000' "$FW_PUBLIC_TCP" "公网 TCP 应包含 Caddy、SSH 与节点"
        assert_eq '443,30000' "$FW_PUBLIC_UDP" "公网 UDP 应包含 Caddy HTTP/3 与节点"
    )
}

test_security_group_suggestions_exclude_dhcp_clients() {
    local output

    output="$({
        ss() { emit_public_listener_sample; }
        show_ports_security_group
    })"
    printf '%s\n' "$output" | grep -Eq '^TCP 80$' || fail "自检应建议放行 Caddy TCP 80"
    printf '%s\n' "$output" | grep -Eq '^TCP 443$' || fail "自检应建议放行 Caddy TCP 443"
    printf '%s\n' "$output" | grep -Eq '^UDP 443$' || fail "自检应建议放行 Caddy UDP 443"
    if printf '%s\n' "$output" | grep -Eq '^UDP (68|546)$'; then
        fail "DHCP 客户端端口不应进入普通入站放行建议"
    fi
    printf '%s\n' "$output" | grep -Eq '^UDP[[:space:]]+68[[:space:]]+dhcpcd$' ||
        fail "DHCP 客户端监听仍应显示在非公网列表"
}

test_allowed_ports_merge_known_public_docker_and_extra_sources() {
    (
        FW_EXTRA_TCP='8443'
        FW_EXTRA_UDP='5353'
        ssh_effective_ports_csv() { printf '%s\n' 23333; }
        ssh_listening_ports_csv() { printf '%s\n' 23333; }
        require_valid_node_state_if_present() { :; }
        protocol_visible_exists() { return 0; }
        load_protocol_state() {
            if [ "$1" = vless ]; then
                PORT=43333
                PROTOCOL=vless-reality
            else
                PORT=31423
                PROTOCOL=shadowsocks
            fi
            : "$PORT" "$PROTOCOL"
        }
        firewall_detect_docker_ports() {
            FW_DOCKER_PUBLIC_TCP='8080'
            FW_DOCKER_PUBLIC_UDP=''
        }
        firewall_detect_public_listeners() {
            FW_PUBLIC_TCP='80,443,8080,8443,23333,31423,43333'
            FW_PUBLIC_UDP='443,5353,31423'
        }

        firewall_detect_allowed_ports
        assert_eq '80,443,8080,8443,23333,31423,43333' "$FW_ALLOWED_TCP" "TCP 应合并两种节点及其他放行来源"
        assert_eq '443,5353,31423' "$FW_ALLOWED_UDP" "UDP 应合并所有放行来源"
        assert_eq '80,443' "$FW_OTHER_PUBLIC_TCP" "其他公网 TCP 应扣除已分类来源"
        assert_eq '443' "$FW_OTHER_PUBLIC_UDP" "其他公网 UDP 应扣除节点与额外端口"
    )
}

test_stopped_public_service_is_removed_unless_extra() {
    (
        local detected_tcp='80' detected_udp='443'
        FW_EXTRA_TCP='8443'
        FW_EXTRA_UDP='5353'
        ssh_effective_ports_csv() { printf '%s\n' 23333; }
        ssh_listening_ports_csv() { printf '%s\n' 23333; }
        require_valid_node_state_if_present() { :; }
        protocol_visible_exists() { return 1; }
        firewall_detect_docker_ports() {
            FW_DOCKER_PUBLIC_TCP=''
            FW_DOCKER_PUBLIC_UDP=''
            : "$FW_DOCKER_PUBLIC_TCP" "$FW_DOCKER_PUBLIC_UDP"
        }
        firewall_detect_public_listeners() {
            FW_PUBLIC_TCP="$detected_tcp"
            FW_PUBLIC_UDP="$detected_udp"
        }

        firewall_detect_allowed_ports
        assert_eq '80,8443,23333' "$FW_ALLOWED_TCP" "运行中的公网服务应自动放行"
        assert_eq '443,5353' "$FW_ALLOWED_UDP" "运行中的公网 UDP 服务应自动放行"

        detected_tcp=''
        detected_udp=''
        firewall_detect_allowed_ports
        assert_eq '8443,23333' "$FW_ALLOWED_TCP" "停止的普通服务应在下次完整更新移除"
        assert_eq '5353' "$FW_ALLOWED_UDP" "额外 UDP 应在服务停止后继续保留"
    )
}

emit_live_firewall_table_sample() {
    cat <<'EOF'
table inet vpsbox {
    set docker4_tcp_ports {
        type inet_service
        elements = { 18080 }
    }
    set docker6_udp_ports {
        type inet_service
        elements = { 18443 }
    }
    set extra_tcp_dnat_ports {
        type inet_service
        elements = { 20000 }
    }
    chain input {
        type filter hook input priority filter; policy drop;
        meta nfproto ipv4 udp sport 67 udp dport 68 accept
        meta nfproto ipv6 udp sport 547 udp dport 546 accept
        tcp dport { 23333, 31423 } accept
        udp dport 31423 accept
    }
    chain docker_port_guard {
        meta l4proto tcp ct original proto-dst @extra_tcp_dnat_ports accept
        meta nfproto ipv4 meta l4proto tcp oifname @docker_bridge_ifaces ct original proto-dst @docker4_tcp_ports accept
        meta l4proto tcp drop
        meta nfproto ipv6 meta l4proto udp oifname @docker_bridge_ifaces ct original proto-dst @docker6_udp_ports accept
        meta l4proto udp drop
        drop
    }
    chain docker_forward {
        type filter hook forward priority -1; policy accept;
        ct direction original ct status dnat jump docker_port_guard
    }
}
EOF
}

set_minimal_live_match_expectations() {
    FW_ALLOWED_TCP='22,80'
    FW_ALLOWED_UDP='443'
    FW_DOCKER_PUBLIC4_TCP=''
    FW_DOCKER_PUBLIC4_UDP=''
    FW_DOCKER_PUBLIC6_TCP=''
    FW_DOCKER_PUBLIC6_UDP=''
    FW_DOCKER_PROXY4_TCP=''
    FW_DOCKER_PROXY4_UDP=''
    FW_DOCKER_PROXY6_TCP=''
    FW_DOCKER_PROXY6_UDP=''
    FW_DOCKER_BRIDGES=''
    FW_EXTRA_TCP=''
    FW_EXTRA_UDP=''
}

emit_numeric_live_table_fixture() {
    cat <<EOF
table inet vpsbox {
$([ "${LIVE_MATCH_DRIFT:-}" != unexpected-set ] || printf '%s\n' \
'    set unexpected_ports {' \
'        type inet_service' \
'        elements = { 9999 }' \
'    }')
    chain input {
        type filter hook input priority filter; policy drop;
        ct state 0x1 drop
        ct state 0x2,0x4 accept
        iifname "lo" accept
        ip protocol 1 accept
        meta l4proto 58 accept
        meta nfproto 2 udp sport 67 udp dport 68 accept
        meta nfproto 10 udp sport 547 udp dport 546 accept
        tcp dport { 22, 80 } accept
        udp dport 443 accept
    }
    chain docker_port_guard {
        meta l4proto 6 drop
        meta l4proto 17 drop
        drop
    }
    chain docker_forward {
        type filter hook forward priority -1; policy accept;
        ct state 0x2,0x4 accept
        ct direction 0 ct status 0x20 jump docker_port_guard
    }
}
EOF
}

emit_numeric_live_input_fixture() {
    local priority=filter
    [ "${LIVE_MATCH_DRIFT:-}" != input-priority ] || priority=10
    cat <<EOF
table inet vpsbox {
    chain input {
        type filter hook input priority $priority; policy drop;
        ct state 0x1 drop
        ct state 0x2,0x4 accept
        iifname "lo" accept
        ip protocol 1 accept
        meta l4proto 58 accept
        meta nfproto 2 udp sport 67 udp dport 68 accept
        meta nfproto 10 udp sport 547 udp dport 546 accept
        tcp dport { 22, 80 } accept
        udp dport 443 accept
    }
}
EOF
}

emit_numeric_live_guard_fixture() {
    cat <<'EOF'
table inet vpsbox {
    chain docker_port_guard {
        meta l4proto 6 drop
        meta l4proto 17 drop
        drop
    }
}
EOF
}

emit_numeric_live_forward_fixture() {
    cat <<EOF
table inet vpsbox {
    chain docker_forward {
        type filter hook forward priority -1; policy accept;
$([ "${LIVE_MATCH_DRIFT:-}" = forward-rule ] || printf '%s\n' '        ct state 0x2,0x4 accept')
        ct direction 0 ct status 0x20 jump docker_port_guard
    }
}
EOF
}

mock_numeric_live_nft() {
    case "$*" in
        '-nn list table inet vpsbox') emit_numeric_live_table_fixture ;;
        '-nn list chain inet vpsbox input') emit_numeric_live_input_fixture ;;
        '-nn list chain inet vpsbox docker_port_guard') emit_numeric_live_guard_fixture ;;
        '-nn list chain inet vpsbox docker_forward') emit_numeric_live_forward_fixture ;;
        'list chain inet vpsbox output'|'list set inet vpsbox '*) return 1 ;;
        *) return 1 ;;
    esac
}

test_live_config_match_accepts_numeric_nft_snapshot() {
    (
        set_minimal_live_match_expectations
        LIVE_MATCH_DRIFT=''
        firewall_runtime_enabled() { return 0; }
        nft() { mock_numeric_live_nft "$@"; }

        firewall_live_config_matches_expected ||
            fail "与期望一致的 nft -nn 规则快照应通过 live 配置校验"
    )
}

test_live_config_match_rejects_critical_drift() {
    (
        local drift
        set_minimal_live_match_expectations
        firewall_runtime_enabled() { return 0; }
        nft() { mock_numeric_live_nft "$@"; }

        for drift in input-priority forward-rule unexpected-set; do
            LIVE_MATCH_DRIFT="$drift"
            if firewall_live_config_matches_expected; then
                fail "live 配置校验必须拒绝漂移：$drift"
            fi
        done
    )
}

test_view_rules_reads_live_nft_instead_of_current_listeners() {
    (
        local output="$TEST_TMP/firewall-live-view.out"
        forbid_init
        firewall_runtime_enabled() { return 0; }
        firewall_persistence_state() { printf '已启用\n'; }
        firewall_detect_allowed_ports() { forbid "查看实际规则不得重新扫描当前监听"; }
        nft() {
            [ "$*" = '-nn list table inet vpsbox' ] || return 1
            emit_live_firewall_table_sample
        }

        firewall_view_rules > "$output"

        assert_file_contains "$output" '主机入站[[:space:]]+TCP[[:space:]]+23333,31423'
        assert_file_contains "$output" '主机入站[[:space:]]+UDP[[:space:]]+31423'
        assert_file_contains "$output" 'Docker 转发[[:space:]]+TCP[[:space:]]+18080'
        assert_file_contains "$output" 'Docker 转发[[:space:]]+UDP[[:space:]]+18443'
        assert_file_contains "$output" '额外 DNAT[[:space:]]+TCP[[:space:]]+20000'
        assert_file_not_contains "$output" '(^|[^0-9])(68|546|80|443)([^0-9]|$)' \
            "未实际放行的新监听和 DHCP 客户端端口不得显示"
        assert_no_forbidden "查看实际规则时重新扫描了当前监听"
    )
}

test_view_rules_inactive_reports_no_live_ports_without_scanning() {
    (
        local output="$TEST_TMP/firewall-inactive-view.out"
        forbid_init
        firewall_runtime_enabled() { return 1; }
        firewall_runtime_state() { printf '配置存在但未运行\n'; }
        firewall_persistence_state() { printf '已启用\n'; }
        firewall_detect_allowed_ports() { forbid "停用防火墙的查看操作不得扫描期望端口"; }
        nft() { forbid "停用防火墙时不得读取不存在的 live 表"; }

        firewall_view_rules > "$output"

        assert_file_contains "$output" '主机入站[[:space:]]+TCP[[:space:]]+-$'
        assert_file_contains "$output" '防火墙：配置存在但未运行'
        assert_file_contains "$output" '当前没有正在生效的 vpsbox 防火墙规则'
        assert_no_forbidden "停用防火墙的查看操作读取了 live 表或扫描了期望端口"
    )
}

test_view_rules_accepts_normalized_forward_priority_expression() {
    (
        local output="$TEST_TMP/firewall-normalized-forward-priority.out"
        firewall_runtime_enabled() { return 0; }
        firewall_persistence_state() { printf '已启用\n'; }
        nft() {
            [ "$*" = '-nn list table inet vpsbox' ] || return 1
            emit_live_firewall_table_sample | sed 's/hook forward priority -1; policy accept;/hook forward priority filter - 1; policy accept;/'
        }

        firewall_view_rules > "$output"
        assert_file_contains "$output" 'Docker 转发[[:space:]]+TCP[[:space:]]+18080'
        assert_file_contains "$output" '防火墙：运行中'
    )
}

test_view_rules_rejects_unhooked_or_permissive_base_chains() {
    (
        local output="$TEST_TMP/firewall-invalid-input-base.out"
        firewall_runtime_enabled() { return 0; }
        firewall_persistence_state() { printf '已启用\n'; }
        nft() {
            [ "$*" = '-nn list table inet vpsbox' ] || return 1
            emit_live_firewall_table_sample | sed 's/hook input priority filter; policy drop;/hook input priority filter; policy accept;/'
        }

        if firewall_view_rules > "$output" 2>&1; then
            fail "policy accept 的 input 链不得被报告为正在生效的放行规则"
        fi
        assert_file_contains "$output" '无法可靠读取当前 nftables 放行规则'
    )
    (
        local output="$TEST_TMP/firewall-invalid-forward-base.out"
        firewall_runtime_enabled() { return 0; }
        firewall_persistence_state() { printf '已启用\n'; }
        nft() {
            [ "$*" = '-nn list table inet vpsbox' ] || return 1
            emit_live_firewall_table_sample | sed 's/hook forward priority -1; policy accept;/hook forward priority 0; policy accept;/'
        }

        if firewall_view_rules > "$output" 2>&1; then
            fail "未使用受管优先级的 forward 链不得被报告为有效 Docker 转发规则"
        fi
        assert_file_contains "$output" '无法可靠读取当前 nftables 放行规则'
    )
}

test_firewall_table_parsers_consume_large_trailing_input() {
    local table body rules i

    table="$(
        emit_live_firewall_table_sample
        for ((i = 0; i < 12000; i++)); do
            printf '# trailing filler for pipefail regression %05d\n' "$i"
        done
    )"
    body="$(printf '%s\n' "$table" | firewall_set_body_lines docker4_tcp_ports)" ||
        fail "set 解析器不得因提前关闭大型输入管道而触发 pipefail"
    rules="$(printf '%s\n' "$table" | firewall_chain_rule_lines input)" ||
        fail "chain 解析器不得因提前关闭大型输入管道而触发 pipefail"
    [[ "$body" == *'elements = { 18080 }'* ]] ||
        fail "大型表中的端口 set 未正确解析"
    [[ "$rules" == *'tcp dport { 23333, 31423 } accept'* ]] ||
        fail "大型表中的 input 规则未正确解析"
}

test_systemd_enabled_inactive_firewalld_conflict() {
    (
        # Consumed by firewall_firewalld_enabled_or_active from the sourced script.
        # shellcheck disable=SC2034
        OS=debian
        is_systemd() { return 0; }
        systemctl() {
            case "${1:-}" in
                is-active) return 1 ;;
                is-enabled) return 0 ;;
                *) return 1 ;;
            esac
        }

        if firewall_check_conflicts >/dev/null 2>&1; then
            fail "systemd 中已启用但未运行的 firewalld 应被识别为冲突"
        fi
    )
}

test_openrc_enabled_inactive_firewalld_conflict() {
    local runlevels="$TEST_TMP/openrc-runlevels"

    require_real_symlink directory || return "$?"
    mkdir -p "$runlevels/default"
    ln -s /etc/init.d/firewalld "$runlevels/default/firewalld"
    firewall_openrc_service_enabled firewalld "$runlevels" ||
        fail "OpenRC runlevel 中的 firewalld 启用链接应被识别"

    (
        # Consumed by firewall_firewalld_enabled_or_active from the sourced script.
        # shellcheck disable=SC2034
        OS=alpine
        is_systemd() { return 1; }
        rc-service() { return 1; }
        firewall_openrc_service_enabled() { return 0; }

        if firewall_check_conflicts >/dev/null 2>&1; then
            fail "OpenRC 中已启用但未运行的 firewalld 应被识别为冲突"
        fi
    )
}

test_case_pid_registry_survives_nested_subshell() {
    local pid start_ticks

    cleanup_case_pids
    sleep 30 &
    pid=$!
    (
        record_case_pid "$pid"
    )

    [ -z "$CASE_PIDS" ] ||
        fail "嵌套子 Shell 的变量不应被误认为已回传父 Shell"
    kill -0 "$pid" 2>/dev/null || fail "清理验证前测试进程应仍在运行"
    cleanup_case_pids
    if kill -0 "$pid" 2>/dev/null; then
        fail "共享 PID 文件必须允许父 Shell 清理子 Shell 登记的进程"
    fi

    sleep 30 &
    pid=$!
    start_ticks="$(process_start_ticks "$pid")"
    printf '%s %s\n' "$pid" "$((start_ticks + 1))" >> "$CASE_PID_FILE"
    cleanup_case_pids
    kill -0 "$pid" 2>/dev/null ||
        fail "清理器不得终止启动时间不匹配的复用 PID"
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

test_bounded_background_processes_release_lock() {
    local case_dir="$TEST_TMP/bounded-lock" driver ready lock child_count=0
    local driver_pid descendants pid

    require_command flock || return "$?"
    require_linux_proc || return "$?"
    mkdir -p "$case_dir"
    driver="$case_dir/driver.sh"
    ready="$case_dir/ready"
    lock="$case_dir/menu.lock"
    cat > "$driver" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$REPO_DIR/vpsbox.sh"
PACKAGE_KILL_GRACE=1
exec 200<>"$LOCK_TARGET"
flock 200
run_bounded_in_new_session 20 sh -c 'printf ready > "$1"; sleep 30' sh "$READY_FILE"
EOF
    chmod 700 "$driver"

    REPO_DIR="$REPO_DIR" LOCK_TARGET="$lock" READY_FILE="$ready" bash "$driver" &
    driver_pid=$!
    record_case_pid "$driver_pid"
    wait_for_file "$ready"
    for _ in {1..50}; do
        descendants="$(process_children "$driver_pid")"
        child_count="$(wc -w <<< "$descendants")"
        [ "$child_count" -ge 2 ] && break
        sleep 0.1
    done
    [ "$child_count" -ge 2 ] || fail "未观察到受限命令及其超时计时器"
    remember_process_tree "$driver_pid"
    for pid in $(process_children "$driver_pid"); do
        assert_fd_closed "$pid" 200 "受限命令或超时计时器继承了菜单锁"
    done

    kill -KILL "$driver_pid"
    wait "$driver_pid" 2>/dev/null || true
    assert_lock_available "$lock" "父菜单被 SIGKILL 后，后台受限命令仍占用 flock"
    cleanup_case_pids
}

run_timeout_lock_case() {
    local name="$1" mode="$2"
    local case_dir="$TEST_TMP/$name" driver ready lock driver_pid pid
    local real_timeout test_path="$PATH"

    mkdir -p "$case_dir"
    driver="$case_dir/driver.sh"
    ready="$case_dir/ready"
    lock="$case_dir/menu.lock"
    if [ "$mode" = "busybox-fallback" ]; then
        real_timeout="$(command -v timeout)"
        mkdir -p "$case_dir/bin"
        cat > "$case_dir/bin/timeout" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-k" ]; then
    exit 125
fi
exec "$REAL_TIMEOUT" "$@"
EOF
        chmod 700 "$case_dir/bin/timeout"
        test_path="$case_dir/bin:$PATH"
    fi
    cat > "$driver" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$REPO_DIR/vpsbox.sh"
PACKAGE_KILL_GRACE=1
exec 200<>"$LOCK_TARGET"
flock 200
run_bounded_with_timeout 20 sh -c 'printf ready > "$1"; sleep 30' sh "$READY_FILE"
EOF
    chmod 700 "$driver"

    REPO_DIR="$REPO_DIR" LOCK_TARGET="$lock" READY_FILE="$ready" \
        REAL_TIMEOUT="${real_timeout:-}" PATH="$test_path" bash "$driver" &
    driver_pid=$!
    record_case_pid "$driver_pid"
    wait_for_file "$ready"
    remember_process_tree "$driver_pid"
    [ "$(wc -w <<< "$CASE_PIDS")" -ge 3 ] ||
        fail "未观察到 timeout 及其受限命令"
    for pid in $CASE_PIDS; do
        [ "$pid" = "$driver_pid" ] ||
            assert_fd_closed "$pid" 200 "timeout 兼容路径继承了菜单锁"
    done

    kill -KILL "$driver_pid"
    wait "$driver_pid" 2>/dev/null || true
    assert_lock_available "$lock" "父菜单被 SIGKILL 后，timeout 兼容路径仍占用 flock"
    cleanup_case_pids
}

test_timeout_processes_release_lock() {
    require_command flock || return "$?"
    require_linux_proc || return "$?"
    run_timeout_lock_case timeout-lock supported
}

test_busybox_timeout_fallback_releases_lock() {
    require_command flock || return "$?"
    require_linux_proc || return "$?"
    run_timeout_lock_case timeout-fallback busybox-fallback
}

test_watchdog_survives_parent_without_holding_lock() {
    local case_dir="$TEST_TMP/watchdog-lock" driver ready lock runtime snapshot
    local driver_pid watchdog child=""

    require_command flock || return "$?"
    require_linux_proc || return "$?"
    mkdir -p "$case_dir"
    driver="$case_dir/driver.sh"
    ready="$case_dir/ready"
    lock="$case_dir/menu.lock"
    runtime="$case_dir/run"
    snapshot="$runtime/firewall-rollback.test"
    cat > "$driver" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$REPO_DIR/vpsbox.sh"
RUNTIME_DIR="$RUNTIME_TARGET"
snapshot="$RUNTIME_DIR/firewall-rollback.test"
mkdir -p "$snapshot"
printf '%s\n' '#!/bin/sh' 'sleep 30' > "$snapshot/rollback.sh"
chmod 700 "$snapshot/rollback.sh"
exec 200<>"$LOCK_TARGET"
flock 200
firewall_start_rollback_watchdog "$snapshot"
cat "$snapshot/watchdog.pid" > "$WATCHDOG_FILE"
printf ready > "$READY_FILE"
wait "$(cat "$snapshot/watchdog.pid")"
EOF
    chmod 700 "$driver"

    REPO_DIR="$REPO_DIR" RUNTIME_TARGET="$runtime" LOCK_TARGET="$lock" \
        WATCHDOG_FILE="$case_dir/watchdog.pid" READY_FILE="$ready" bash "$driver" &
    driver_pid=$!
    record_case_pid "$driver_pid"
    wait_for_file "$ready"
    watchdog="$(cat "$case_dir/watchdog.pid")"
    record_case_pid "$watchdog"
    for _ in {1..50}; do
        child="$(process_children "$watchdog" | awk '{print $1}')"
        [ -n "$child" ] && break
        sleep 0.1
    done
    [ -n "$child" ] || fail "watchdog 未创建等待子进程"
    record_case_pid "$child"
    assert_fd_closed "$watchdog" 200 "防火墙 watchdog 继承了菜单锁"
    assert_fd_closed "$child" 200 "watchdog 的等待子进程继承了菜单锁"

    kill -KILL "$driver_pid"
    wait "$driver_pid" 2>/dev/null || true
    kill -0 "$watchdog" 2>/dev/null || fail "父菜单异常退出不应破坏防火墙 watchdog"
    assert_lock_available "$lock" "父菜单被 SIGKILL 后，防火墙 watchdog 仍占用 flock"
    cleanup_case_pids
    rm -rf -- "$snapshot"
}

test_stopped_docker_fixed_binding_is_public() {
    (
        docker() { :; }
        firewall_docker_available() { return 0; }
        firewall_validate_docker_daemon_mode() { return 0; }
        firewall_detect_docker_proxy_ports() { return 0; }
        firewall_docker_daemon_identity_unchanged() { return 0; }
        docker_with_timeout() {
            case "$*" in
                "context show") printf '%s\n' default ;;
                "context inspect --format {{.Endpoints.docker.Host}} default") printf '%s\n' unix:///var/run/docker.sock ;;
                "info --format {{json .SecurityOptions}}") printf '%s\n' '[]' ;;
                "info --format {{.Swarm.LocalNodeState}}") printf '%s\n' inactive ;;
                "ps -aq") printf '%s\n' stopped-container ;;
                "inspect --format {{.HostConfig.NetworkMode}} stopped-container") printf '%s\n' bridge ;;
                "inspect --format {{.HostConfig.PublishAllPorts}} stopped-container") printf '%s\n' false ;;
                "inspect --format {{range \$port, \$bindings := .HostConfig.PortBindings}}{{range \$bindings}}{{printf \"%s|%s|%s\\n\" \$port .HostIp .HostPort}}{{end}}{{end}} stopped-container")
                    printf '%s\n' '80/tcp|0.0.0.0|8080'
                    ;;
                "inspect --format {{.State.Running}} stopped-container") printf '%s\n' false ;;
                "network ls --format {{.ID}}|{{.Name}}|{{.Driver}}") : ;;
                *)
                    printf 'unexpected docker call: %s\n' "$*" >&2
                    return 1
                    ;;
            esac
        }

        firewall_detect_docker_ports || fail "停止容器的固定映射应能完成检测"
        assert_eq 8080 "$FW_DOCKER_TCP" "固定映射应进入 Docker TCP 端口集合"
        assert_eq 8080 "$FW_DOCKER_PUBLIC4_TCP" "0.0.0.0 固定映射应进入 IPv4 公网端口集合"
        assert_eq 8080 "$FW_DOCKER_PUBLIC_TCP" "停止容器的公网固定映射不得被遗漏"
    )
}

test_additive_config_builder_adds_tcp_without_rebuilding_other_rules() {
    local source="$TEST_TMP/additive-tcp-old.nft"
    local dest="$TEST_TMP/additive-tcp-new.nft"

    FW_ALLOWED_TCP="443,6384,8080"
    FW_ALLOWED_UDP=""
    FW_EXTRA_TCP="8080"
    FW_EXTRA_UDP=""
    FW_DOCKER_PUBLIC4_TCP=""
    FW_DOCKER_PUBLIC4_UDP=""
    FW_DOCKER_PUBLIC6_TCP=""
    FW_DOCKER_PUBLIC6_UDP=""
    FW_DOCKER_PROXY4_TCP=""
    FW_DOCKER_PROXY4_UDP=""
    FW_DOCKER_PROXY6_TCP=""
    FW_DOCKER_PROXY6_UDP=""
    FW_DOCKER_BRIDGES=""
    : "$FW_ALLOWED_TCP" "$FW_ALLOWED_UDP" "$FW_DOCKER_PUBLIC4_UDP" \
        "$FW_DOCKER_PUBLIC6_TCP" "$FW_DOCKER_PUBLIC6_UDP" \
        "$FW_DOCKER_PROXY4_TCP" "$FW_DOCKER_PROXY4_UDP" \
        "$FW_DOCKER_PROXY6_TCP" "$FW_DOCKER_PROXY6_UDP" "$FW_DOCKER_BRIDGES"
    firewall_write_config "$source"
    firewall_config_additive_shape_valid "$source" 8080 "" ||
        fail "受管防火墙配置应满足 TCP 轻量新增前置结构"

    FW_EXTRA_TCP="8080,8443"
    firewall_build_config_with_added_ports "$source" "$dest" tcp

    assert_file_contains "$dest" '^[[:space:]]*tcp dport \{ 443, 6384, 8080, 8443 \} accept$'
    assert_file_contains "$dest" '^[[:space:]]*set extra_tcp_dnat_ports \{$'
    assert_file_contains "$dest" '^[[:space:]]*elements = \{ 8080, 8443 \}$'
    assert_eq 1 "$(grep -Fxc '        meta l4proto tcp ct original proto-dst @extra_tcp_dnat_ports accept' "$dest")" \
        "TCP Docker DNAT 放行规则应恰好一条"
    assert_file_contains "$dest" '^# Managed by vpsbox\.' "轻量更新不得替换其他受管规则"
}

test_additive_config_builder_creates_first_udp_rule_and_set() {
    local source="$TEST_TMP/additive-udp-old.nft"
    local dest="$TEST_TMP/additive-udp-new.nft"

    FW_ALLOWED_TCP="6384"
    FW_ALLOWED_UDP=""
    FW_EXTRA_TCP=""
    FW_EXTRA_UDP=""
    FW_DOCKER_PUBLIC4_TCP=""
    FW_DOCKER_PUBLIC4_UDP=""
    FW_DOCKER_PUBLIC6_TCP=""
    FW_DOCKER_PUBLIC6_UDP=""
    FW_DOCKER_PROXY4_TCP=""
    FW_DOCKER_PROXY4_UDP=""
    FW_DOCKER_PROXY6_TCP=""
    FW_DOCKER_PROXY6_UDP=""
    FW_DOCKER_BRIDGES=""
    : "$FW_ALLOWED_TCP" "$FW_ALLOWED_UDP" "$FW_DOCKER_PUBLIC4_UDP" \
        "$FW_DOCKER_PUBLIC6_TCP" "$FW_DOCKER_PUBLIC6_UDP" \
        "$FW_DOCKER_PROXY4_TCP" "$FW_DOCKER_PROXY4_UDP" \
        "$FW_DOCKER_PROXY6_TCP" "$FW_DOCKER_PROXY6_UDP" "$FW_DOCKER_BRIDGES"
    firewall_write_config "$source"
    firewall_config_additive_shape_valid "$source" "" "" ||
        fail "受管防火墙配置应满足首次 UDP 轻量新增前置结构"

    FW_EXTRA_UDP="5353"
    firewall_build_config_with_added_ports "$source" "$dest" udp

    assert_file_contains "$dest" '^[[:space:]]*udp dport \{ 5353 \} accept$'
    assert_file_contains "$dest" '^[[:space:]]*set extra_udp_dnat_ports \{$'
    assert_file_contains "$dest" '^[[:space:]]*elements = \{ 5353 \}$'
    assert_eq 1 "$(grep -Fxc '        meta l4proto udp ct original proto-dst @extra_udp_dnat_ports accept' "$dest")" \
        "UDP Docker DNAT 放行规则应恰好一条"
}

test_adding_port_uses_lightweight_commit_path() {
    (
        local log="$TEST_TMP/additive-route.log"
        forbid_init
        firewall_settle_pending_port_transition() { :; }
        firewall_load_state() { FW_EXTRA_TCP="8080"; FW_EXTRA_UDP=""; }
        firewall_prompt_port() { printf '%s\n' 8443; }
        firewall_control_plane_present() { return 0; }
        firewall_apply_added_ports() {
            printf '%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$FW_EXTRA_TCP" "$FW_EXTRA_UDP" > "$log"
        }
        firewall_apply_desired_state() { forbid "新增端口不得调用完整防火墙更新"; }

        firewall_add_extra_port tcp
        assert_file_contains "$log" '^tcp\|8443\|8080\|8080,8443\|$'
        assert_no_forbidden "新增端口调用了完整防火墙更新"
    )
}

test_apply_without_rollback_watchdog_must_not_touch_firewall() {
    (
        local case_dir="$TEST_TMP/apply-watchdog-guard"
        local log="$TEST_TMP/apply-watchdog-guard.log"

        forbid_init
        mkdir -p "$case_dir"
        RUNTIME_DIR="$case_dir/run"
        VPSBOX_STATE_DIR="$case_dir"
        mkdir -p "$RUNTIME_DIR"
        FIREWALL_CONFIG="$case_dir/firewall.nft"
        FIREWALL_STATE_FILE="$case_dir/firewall.env"
        # shellcheck disable=SC2034 # 被测的完整更新流程动态读取。
        FIREWALL_SYSTEMD_UNIT="$case_dir/vpsbox-firewall.service"
        # shellcheck disable=SC2034 # 被测的完整更新流程动态读取。
        FIREWALL_OPENRC_SERVICE="$case_dir/vpsbox-firewall"
        : > "$log"

        detect_os() { OS=debian; : "$OS"; }
        firewall_settle_pending_port_transition() { :; }
        firewall_recover_pending_rollbacks() { :; }
        firewall_check_conflicts() { :; }
        ensure_nftables() { :; }
        firewall_detect_allowed_ports() { FW_SSH_PORTS=22; }
        firewall_show_port_summary() { :; }
        ensure_change_store() { :; }
        firewall_write_state_file() { printf '%s\n' state > "$1"; }
        firewall_write_config() { printf '%s\n' config > "$1"; }
        firewall_write_service_definition() { printf '%s\n' service > "$1"; }
        firewall_create_rollback_snapshot() {
            mkdir -p "$case_dir/snapshot"
            printf -v "$1" '%s' "$case_dir/snapshot"
        }
        firewall_start_rollback_watchdog() {
            printf '%s\n' watchdog-failed >> "$log"
            return 1
        }
        firewall_restore_snapshot_now() {
            assert_eq "$case_dir/snapshot" "$1" "必须恢复刚创建的快照" || return "$?"
            printf '%s\n' restored >> "$log"
        }
        firewall_apply_config_file() { forbid "未获得自动回滚保护时应用了防火墙规则"; }
        firewall_install_managed_file() { forbid "未获得自动回滚保护时写入了受管配置"; }
        firewall_begin_commit() { forbid "未获得自动回滚保护时进入了提交阶段"; }

        if firewall_apply_desired_state <<< "YES" >/dev/null 2>&1; then
            fail "自动回滚保护启动失败时防火墙更新不得报告成功"
        fi
        assert_file_contains "$log" '^watchdog-failed$' \
            "应用规则前必须先启动自动回滚保护"
        assert_file_contains "$log" '^restored$' \
            "保护启动失败后必须恢复应用前状态"
        assert_no_forbidden "在没有自动回滚保护的情况下改动了防火墙"
    )
}

test_unchanged_firewall_skips_confirmation_and_mutation() {
    (
        local output="$TEST_TMP/firewall-no-change.out"

        forbid_init
        detect_os() { OS=debian; : "$OS"; }
        firewall_settle_pending_port_transition() { :; }
        firewall_recover_pending_rollbacks() { :; }
        firewall_check_conflicts() { :; }
        ensure_nftables() { :; }
        firewall_load_state() { :; }
        firewall_detect_allowed_ports() { :; }
        firewall_desired_state_is_current() { return 0; }
        firewall_show_port_summary() { forbid "无变化时不应显示应用确认摘要"; }
        firewall_create_rollback_snapshot() { forbid "无变化时不应创建回滚快照"; }
        firewall_start_rollback_watchdog() { forbid "无变化时不应启动 watchdog"; }
        firewall_apply_config_file() { forbid "无变化时不应应用 nftables 规则"; }
        firewall_install_managed_file() { forbid "无变化时不应重写受管文件"; }

        firewall_apply_desired_state </dev/null > "$output" 2>&1 ||
            fail "完全健康且无变化的防火墙应直接返回成功"
        assert_file_contains "$output" '当前防火墙规则与端口状态一致，无需更新。'
        assert_no_forbidden "无变化防火墙仍进入了确认或修改流程"
    )
}

test_second_firewall_scan_can_become_noop_before_mutation() {
    (
        local output="$TEST_TMP/firewall-second-scan-noop.out"
        local current_checks=0 detect_calls=0

        forbid_init
        detect_os() { OS=debian; : "$OS"; }
        firewall_settle_pending_port_transition() { :; }
        firewall_recover_pending_rollbacks() { :; }
        firewall_check_conflicts() { :; }
        ensure_nftables() { :; }
        firewall_load_state() { :; }
        firewall_detect_allowed_ports() { detect_calls=$((detect_calls + 1)); }
        firewall_desired_state_is_current() {
            current_checks=$((current_checks + 1))
            [ "$current_checks" -eq 2 ]
        }
        firewall_show_port_summary() { :; }
        firewall_create_rollback_snapshot() { forbid "二次扫描已一致时不应创建回滚快照"; }
        firewall_start_rollback_watchdog() { forbid "二次扫描已一致时不应启动 watchdog"; }
        firewall_apply_config_file() { forbid "二次扫描已一致时不应应用规则"; }

        firewall_apply_desired_state <<< "YES" > "$output" 2>&1 ||
            fail "确认后二次扫描已一致时应安全短路"
        assert_eq 2 "$detect_calls" "确认前后必须分别获取一次实时端口状态"
        assert_eq 2 "$current_checks" "两次实时状态都必须执行完整一致性判断"
        assert_file_contains "$output" '当前防火墙规则与端口状态一致，无需更新。'
        assert_no_forbidden "二次扫描已一致后仍进入了防火墙事务"
    )
}

test_firewall_noop_requires_complete_managed_state() {
    (
        local case_dir="$TEST_TMP/firewall-current-state"
        local runtime_ok=1 service_ok=1 live_ok=1
        local mock_enabled_state=enabled mock_fragment_path mock_reload_state=no

        [ "$(id -u)" = "0" ] || { skip "需要 root 文件属主语义"; return "$?"; }
        mkdir -p "$case_dir/run"
        chmod 700 "$case_dir"
        RUNTIME_DIR="$case_dir/run"
        VPSBOX_STATE_DIR="$case_dir"
        FIREWALL_CONFIG="$case_dir/firewall.nft"
        FIREWALL_STATE_FILE="$case_dir/firewall.env"
        FIREWALL_SYSTEMD_UNIT="$case_dir/vpsbox-firewall.service"
        OS=debian
        mock_fragment_path="$FIREWALL_SYSTEMD_UNIT"
        printf '%s\n' config > "$FIREWALL_CONFIG"
        printf '%s\n' state > "$FIREWALL_STATE_FILE"
        printf '%s\n' service > "$FIREWALL_SYSTEMD_UNIT"
        chown root:root "$FIREWALL_CONFIG" "$FIREWALL_STATE_FILE" "$FIREWALL_SYSTEMD_UNIT"
        chmod 600 "$FIREWALL_CONFIG" "$FIREWALL_STATE_FILE"
        chmod 644 "$FIREWALL_SYSTEMD_UNIT"

        is_systemd() { return 0; }
        firewall_runtime_enabled() { [ "$runtime_ok" -eq 1 ]; }
        firewall_service_active() { [ "$service_ok" -eq 1 ]; }
        firewall_live_config_matches_expected() { [ "$live_ok" -eq 1 ]; }
        firewall_write_state_file() { printf '%s\n' state > "$1"; }
        firewall_write_config() { printf '%s\n' config > "$1"; }
        firewall_write_service_definition() { printf '%s\n' service > "$1"; }
        nft() { return 0; }
        systemctl() {
            case "$1" in
                is-enabled) printf '%s\n' "$mock_enabled_state" ;;
                show)
                    case "$*" in
                        *FragmentPath*) printf '%s\n' "$mock_fragment_path" ;;
                        *NeedDaemonReload*) printf '%s\n' "$mock_reload_state" ;;
                        *) return 1 ;;
                    esac
                    ;;
                *) return 1 ;;
            esac
        }

        firewall_desired_state_is_current || fail "完整健康状态应允许无变化短路"

        chmod 755 "$VPSBOX_STATE_DIR"
        if firewall_desired_state_is_current; then fail "状态目录权限漂移时不得短路"; fi
        chmod 700 "$VPSBOX_STATE_DIR"
        chmod 640 "$FIREWALL_CONFIG"
        if firewall_desired_state_is_current; then fail "配置权限漂移时不得短路"; fi
        chmod 600 "$FIREWALL_CONFIG"
        printf '%s\n' drift > "$FIREWALL_STATE_FILE"
        if firewall_desired_state_is_current; then fail "状态文件内容漂移时不得短路"; fi
        printf '%s\n' state > "$FIREWALL_STATE_FILE"
        printf '%s\n' drift > "$FIREWALL_SYSTEMD_UNIT"
        if firewall_desired_state_is_current; then fail "服务定义漂移时不得短路"; fi
        printf '%s\n' service > "$FIREWALL_SYSTEMD_UNIT"
        live_ok=0
        if firewall_desired_state_is_current; then fail "内核规则漂移时不得短路"; fi
        live_ok=1
        service_ok=0
        if firewall_desired_state_is_current; then fail "服务未运行时不得短路"; fi
        service_ok=1
        mock_enabled_state=enabled-runtime
        if firewall_desired_state_is_current; then fail "仅运行时启用的 systemd 服务不得短路"; fi
        mock_enabled_state=enabled
        mock_reload_state=yes
        if firewall_desired_state_is_current; then fail "systemd 尚需 daemon-reload 时不得短路"; fi
        mock_reload_state=no
        mock_fragment_path="$case_dir/wrong.service"
        if firewall_desired_state_is_current; then fail "systemd 加载了错误 unit 时不得短路"; fi
        mock_fragment_path="$FIREWALL_SYSTEMD_UNIT"
        runtime_ok=0
        if firewall_desired_state_is_current; then fail "防火墙运行规则不存在时不得短路"; fi
    )
    (
        local case_dir="$TEST_TMP/firewall-current-openrc"
        local service_ok=1 live_ok=1

        [ "$(id -u)" = "0" ] || { skip "需要 root 文件属主语义"; return "$?"; }
        mkdir -p "$case_dir/run" "$case_dir/init.d" "$case_dir/runlevels/default"
        chmod 700 "$case_dir"
        RUNTIME_DIR="$case_dir/run"
        VPSBOX_STATE_DIR="$case_dir"
        FIREWALL_CONFIG="$case_dir/firewall.nft"
        FIREWALL_STATE_FILE="$case_dir/firewall.env"
        FIREWALL_OPENRC_SERVICE="$case_dir/init.d/vpsbox-firewall"
        FIREWALL_OPENRC_RUNLEVELS_DIR="$case_dir/runlevels"
        OS=alpine
        printf '%s\n' config > "$FIREWALL_CONFIG"
        printf '%s\n' state > "$FIREWALL_STATE_FILE"
        printf '%s\n' service > "$FIREWALL_OPENRC_SERVICE"
        chown root:root "$case_dir" "$FIREWALL_CONFIG" "$FIREWALL_STATE_FILE" "$FIREWALL_OPENRC_SERVICE"
        chmod 700 "$case_dir"
        chmod 600 "$FIREWALL_CONFIG" "$FIREWALL_STATE_FILE"
        chmod 755 "$FIREWALL_OPENRC_SERVICE"
        ln -s "$FIREWALL_OPENRC_SERVICE" "$FIREWALL_OPENRC_RUNLEVELS_DIR/default/$FIREWALL_SERVICE_NAME"

        is_systemd() { return 1; }
        firewall_runtime_enabled() { return 0; }
        firewall_service_active() { [ "$service_ok" -eq 1 ]; }
        firewall_live_config_matches_expected() { [ "$live_ok" -eq 1 ]; }
        firewall_write_state_file() { printf '%s\n' state > "$1"; }
        firewall_write_config() { printf '%s\n' config > "$1"; }
        firewall_write_service_definition() { printf '%s\n' service > "$1"; }
        nft() { return 0; }

        firewall_desired_state_is_current || fail "完整健康的 OpenRC 状态应允许无变化短路"

        chmod 744 "$FIREWALL_OPENRC_SERVICE"
        if firewall_desired_state_is_current; then fail "OpenRC 服务脚本权限漂移时不得短路"; fi
        chmod 755 "$FIREWALL_OPENRC_SERVICE"
        rm "$FIREWALL_OPENRC_RUNLEVELS_DIR/default/$FIREWALL_SERVICE_NAME"
        if firewall_desired_state_is_current; then fail "OpenRC default 自启链接缺失时不得短路"; fi
        printf '%s\n' wrong > "$case_dir/wrong-service"
        ln -s "$case_dir/wrong-service" "$FIREWALL_OPENRC_RUNLEVELS_DIR/default/$FIREWALL_SERVICE_NAME"
        if firewall_desired_state_is_current; then fail "OpenRC default 自启链接指错目标时不得短路"; fi
        rm "$FIREWALL_OPENRC_RUNLEVELS_DIR/default/$FIREWALL_SERVICE_NAME"
        ln -s "$FIREWALL_OPENRC_SERVICE" "$FIREWALL_OPENRC_RUNLEVELS_DIR/default/$FIREWALL_SERVICE_NAME"
        service_ok=0
        if firewall_desired_state_is_current; then fail "OpenRC 服务未运行时不得短路"; fi
    )
}

test_firewall_disable_internal_verifies_service_and_live_table() {
    (
        local case_dir="$TEST_TMP/firewall-disable-systemd" log="$TEST_TMP/firewall-disable-systemd.log"
        mkdir -p "$case_dir"
        FIREWALL_CONFIG="$case_dir/firewall.nft"
        FIREWALL_STATE_FILE="$case_dir/firewall.env"
        FIREWALL_SYSTEMD_UNIT="$case_dir/vpsbox-firewall.service"
        FIREWALL_OPENRC_SERVICE="$case_dir/vpsbox-firewall"
        printf '%s\n' managed > "$FIREWALL_CONFIG"
        printf '%s\n' managed > "$FIREWALL_STATE_FILE"
        printf '%s\n' managed > "$FIREWALL_SYSTEMD_UNIT"
        : > "$log"

        firewall_settle_pending_port_transition() { :; }
        firewall_recover_pending_rollbacks() { :; }
        firewall_control_plane_present() { return 0; }
        is_systemd() { return 0; }
        systemctl() {
            printf 'systemctl:%s\n' "$*" >> "$log"
            case "$1" in
                is-active|is-enabled) return 1 ;;
                *) return 0 ;;
            esac
        }
        nft() {
            printf 'nft:%s\n' "$*" >> "$log"
            [ "$1" != "list" ]
        }

        firewall_disable_internal
        assert_file_contains "$log" '^systemctl:disable --now '
        assert_file_contains "$log" '^systemctl:is-active --quiet '
        assert_file_contains "$log" '^systemctl:is-enabled --quiet '
        assert_file_contains "$log" '^nft:delete table inet vpsbox$'
        assert_file_contains "$log" '^nft:list table inet vpsbox$'
        [ ! -e "$FIREWALL_CONFIG" ] && [ ! -e "$FIREWALL_STATE_FILE" ] &&
            [ ! -e "$FIREWALL_SYSTEMD_UNIT" ] ||
            fail "systemd 防火墙确认停用后应删除受管文件"
    )
    (
        local case_dir="$TEST_TMP/firewall-disable-verification-failure"
        mkdir -p "$case_dir"
        FIREWALL_CONFIG="$case_dir/firewall.nft"
        FIREWALL_STATE_FILE="$case_dir/firewall.env"
        FIREWALL_SYSTEMD_UNIT="$case_dir/vpsbox-firewall.service"
        FIREWALL_OPENRC_SERVICE="$case_dir/vpsbox-firewall"
        printf '%s\n' managed > "$FIREWALL_CONFIG"
        printf '%s\n' managed > "$FIREWALL_STATE_FILE"
        printf '%s\n' managed > "$FIREWALL_SYSTEMD_UNIT"

        firewall_settle_pending_port_transition() { :; }
        firewall_recover_pending_rollbacks() { :; }
        firewall_control_plane_present() { return 0; }
        is_systemd() { return 0; }
        systemctl() {
            [ "$1" != "is-active" ]
        }
        nft() { [ "$1" != "list" ]; }

        if firewall_disable_internal >/dev/null 2>&1; then
            fail "服务仍 active 时防火墙关闭不得报告成功"
        fi
        [ -e "$FIREWALL_CONFIG" ] && [ -e "$FIREWALL_STATE_FILE" ] &&
            [ -e "$FIREWALL_SYSTEMD_UNIT" ] ||
            fail "停用验收失败时必须保留受管文件供重试"
    )
    (
        local case_dir="$TEST_TMP/firewall-disable-openrc" link
        local log="$TEST_TMP/firewall-disable-openrc.log"
        local service_active=1 service_enabled=1
        mkdir -p "$case_dir/runlevels/default"
        : > "$log"
        FIREWALL_CONFIG="$case_dir/firewall.nft"
        FIREWALL_STATE_FILE="$case_dir/firewall.env"
        FIREWALL_SYSTEMD_UNIT="$case_dir/vpsbox-firewall.service"
        FIREWALL_OPENRC_SERVICE="$case_dir/vpsbox-firewall"
        FIREWALL_OPENRC_RUNLEVELS_DIR="$case_dir/runlevels"
        OS=alpine
        link="$FIREWALL_OPENRC_RUNLEVELS_DIR/default/$FIREWALL_SERVICE_NAME"
        printf '%s\n' managed > "$FIREWALL_CONFIG"
        printf '%s\n' managed > "$FIREWALL_STATE_FILE"
        printf '%s\n' managed > "$FIREWALL_OPENRC_SERVICE"
        ln -s "$FIREWALL_OPENRC_SERVICE" "$link"

        firewall_settle_pending_port_transition() { :; }
        firewall_recover_pending_rollbacks() { :; }
        firewall_control_plane_present() { return 0; }
        is_systemd() { return 1; }
        rc-service() {
            printf 'rc-service:%s\n' "$*" >> "$log"
            case "$*" in
                "$FIREWALL_SERVICE_NAME stop")
                    service_active=0
                    ;;
                "$FIREWALL_SERVICE_NAME status")
                    [ "$service_active" -eq 1 ]
                    ;;
                *) return 2 ;;
            esac
        }
        rc-update() {
            printf 'rc-update:%s\n' "$*" >> "$log"
            [ "$*" = "del $FIREWALL_SERVICE_NAME default" ] || return 2
            service_enabled=0
            rm -f -- "$link"
        }
        nft() { [ "$1" != "list" ]; }

        firewall_disable_internal
        assert_file_contains "$log" \
            "^rc-service:${FIREWALL_SERVICE_NAME} stop$"
        assert_file_contains "$log" \
            "^rc-update:del ${FIREWALL_SERVICE_NAME} default$"
        assert_file_contains "$log" \
            "^rc-service:${FIREWALL_SERVICE_NAME} status$"
        assert_eq 0 "$service_active" "OpenRC 防火墙服务必须先停止"
        assert_eq 0 "$service_enabled" "OpenRC 防火墙服务必须移出 default runlevel"
        [ ! -e "$link" ] && [ ! -L "$link" ] ||
            fail "OpenRC 防火墙关闭后不得残留 default 自启链接"
        [ ! -e "$FIREWALL_OPENRC_SERVICE" ] ||
            fail "OpenRC 防火墙确认停用后应删除受管服务脚本"
    )
}

test_extra_port_remove_and_clear_commit_expected_state() {
    (
        local log="$TEST_TMP/firewall-extra-remove.log" prompt_port=443
        : > "$log"
        FW_EXTRA_TCP="80,443"
        FW_EXTRA_UDP="53,443"

        firewall_settle_pending_port_transition() { :; }
        firewall_load_state() { :; }
        firewall_prompt_port() { printf '%s\n' "$prompt_port"; }
        firewall_commit_port_state() {
            printf '%s|%s\n' "$FW_EXTRA_TCP" "$FW_EXTRA_UDP" >> "$log"
        }

        firewall_remove_extra_port tcp
        assert_eq "80" "$FW_EXTRA_TCP" "删除 TCP 端口必须只更新 TCP 额外列表"
        assert_eq "53,443" "$FW_EXTRA_UDP" "删除 TCP 端口不得改动 UDP 列表"
        assert_file_contains "$log" '^80[|]53,443$'

        prompt_port=53
        firewall_remove_extra_port udp
        assert_eq "443" "$FW_EXTRA_UDP" "删除 UDP 端口必须更新 UDP 额外列表"
        assert_file_contains "$log" '^80[|]443$'

        : > "$log"
        prompt_port=9999
        firewall_remove_extra_port tcp >/dev/null
        assert_empty_file "$log" "删除不存在的额外端口不得提交状态"

        firewall_clear_extra_ports <<< "YES"
        assert_eq "" "$FW_EXTRA_TCP" "确认清空后 TCP 额外列表应为空"
        assert_eq "" "$FW_EXTRA_UDP" "确认清空后 UDP 额外列表应为空"
        assert_file_contains "$log" '^[|]$'
    )
    (
        local commit_calls=0
        FW_EXTRA_TCP="80"
        FW_EXTRA_UDP="53"
        firewall_settle_pending_port_transition() { :; }
        firewall_load_state() { :; }
        firewall_commit_port_state() { commit_calls=$((commit_calls + 1)); }

        firewall_clear_extra_ports <<< "no" >/dev/null
        assert_eq "80" "$FW_EXTRA_TCP" "取消清空必须保留 TCP 额外端口"
        assert_eq "53" "$FW_EXTRA_UDP" "取消清空必须保留 UDP 额外端口"
        assert_eq 0 "$commit_calls" "取消清空不得提交防火墙状态"
    )
}

test_lightweight_add_does_not_rescan_docker_or_ssh() {
    (
        local case_dir="$TEST_TMP/additive-apply" log="$TEST_TMP/additive-apply.log"
        forbid_init
        mkdir -p "$case_dir"
        RUNTIME_DIR="$case_dir/run"
        FIREWALL_CONFIG="$case_dir/firewall.nft"
        FIREWALL_STATE_FILE="$case_dir/firewall.env"
        : > "$FIREWALL_CONFIG"
        : > "$FIREWALL_STATE_FILE"
        : > "$log"
        FW_EXTRA_TCP="8080,8443"
        FW_EXTRA_UDP=""

        firewall_recover_pending_rollbacks() { :; }
        firewall_runtime_enabled() { return 0; }
        firewall_managed_file_is_secure() { return 0; }
        firewall_state_file_is_secure() { return 0; }
        firewall_config_additive_shape_valid() { return 0; }
        prepare_runtime_dir() { mkdir -p "$RUNTIME_DIR"; }
        firewall_build_config_with_added_ports() { printf '%s\n' config > "$2"; }
        firewall_write_state_file() { printf '%s\n' state > "$1"; }
        firewall_check_config_file() { return 0; }
        firewall_config_direct_ports() { printf '%s\n' 6384; }
        firewall_create_rollback_snapshot() {
            printf 'snapshot:%s\n' "$2" >> "$log"
            mkdir -p "$case_dir/snapshot"
            printf -v "$1" '%s' "$case_dir/snapshot"
        }
        firewall_apply_config_file() { printf '%s\n' apply >> "$log"; }
        firewall_live_added_ports_match() { printf '%s\n' verify >> "$log"; }
        firewall_begin_commit() { printf '%s\n' begin >> "$log"; }
        firewall_install_managed_file() { printf '%s\n' install >> "$log"; }
        firewall_finish_commit() { printf '%s\n' finish >> "$log"; }
        firewall_detect_allowed_ports() { forbid "轻量新增不得重新扫描 SSH、节点或 Docker"; }

        firewall_apply_added_ports tcp 8443 8080 ""
        assert_file_contains "$log" '^snapshot:6384$'
        assert_file_contains "$log" '^apply$'
        assert_eq 2 "$(grep -Fxc verify "$log")" "运行规则与持久化后都应验证新增端口"
        assert_file_contains "$log" '^begin$'
        assert_eq 2 "$(grep -Fxc install "$log")" "配置与状态应分别原子落盘"
        assert_file_contains "$log" '^finish$'
        assert_no_forbidden "轻量新增重新扫描了 SSH、节点或 Docker"
    )
}

test_internal_port_transition_preserves_unrelated_public_ports() {
    (
        local case_dir="$TEST_TMP/target-transition"
        local managed_node_tcp=31423 direct_tcp direct_udp

        forbid_init
        mkdir -p "$case_dir"
        RUNTIME_DIR="$case_dir/run"
        FIREWALL_CONFIG="$case_dir/firewall.nft"
        # shellcheck disable=SC2034 # 被测事务函数动态读取并更新。
        ACTIVE_FIREWALL_TRANSITION_DIR=""
        FW_ALLOWED_TCP="80,443,23333,31423"
        FW_ALLOWED_UDP="443,31423"
        FW_EXTRA_TCP=""
        FW_EXTRA_UDP=""
        FW_DOCKER_PUBLIC4_TCP=""
        FW_DOCKER_PUBLIC4_UDP=""
        FW_DOCKER_PUBLIC6_TCP=""
        FW_DOCKER_PUBLIC6_UDP=""
        FW_DOCKER_PROXY4_TCP=""
        FW_DOCKER_PROXY4_UDP=""
        FW_DOCKER_PROXY6_TCP=""
        FW_DOCKER_PROXY6_UDP=""
        FW_DOCKER_BRIDGES=""
        firewall_write_config "$FIREWALL_CONFIG"

        prepare_runtime_dir() { mkdir -p "$RUNTIME_DIR"; }
        ssh_effective_ports_csv() { printf '%s\n' 23333; }
        ssh_listening_ports_csv() { printf '%s\n' 23333; }
        firewall_active_config_ready_for_sync() { :; }
        firewall_load_state() { FW_EXTRA_TCP=""; FW_EXTRA_UDP=""; }
        firewall_detect_managed_ports() {
            # shellcheck disable=SC2034 # 被测增量同步函数动态读取。
            FW_SSH_PORTS=23333
            # shellcheck disable=SC2034 # 被测增量同步函数动态读取。
            FW_NODE_TCP="$managed_node_tcp"
            # shellcheck disable=SC2034 # 被测增量同步函数动态读取。
            FW_NODE_UDP=""
        }
        firewall_replace_active_config() { cp "$1" "$FIREWALL_CONFIG"; }
        firewall_detect_docker_ports() { forbid "内部端口切换不得重新扫描 Docker"; }
        firewall_detect_public_listeners() { forbid "内部端口切换不得重新扫描公网监听"; }
        firewall_sync_active_config() { forbid "内部端口切换不得走完整防火墙对账"; }

        firewall_prepare_port_transition 43333 "" 31423 ""
        direct_tcp="$(firewall_config_direct_ports "$FIREWALL_CONFIG" tcp)"
        assert_eq '80,443,23333,31423,43333' "$direct_tcp" \
            "准备阶段应仅增补新节点端口并保留旧节点与其他公网端口"

        managed_node_tcp=43333
        firewall_complete_port_transition
        direct_tcp="$(firewall_config_direct_ports "$FIREWALL_CONFIG" tcp)"
        direct_udp="$(firewall_config_direct_ports "$FIREWALL_CONFIG" udp)"
        assert_eq '80,443,23333,43333' "$direct_tcp" \
            "完成阶段应只移除旧节点 TCP 端口"
        assert_eq '443,31423' "$direct_udp" \
            "TCP 节点切换不得改动同号 UDP 或其他公网 UDP 端口"
        assert_no_forbidden "内部端口切换触发了无关来源扫描"
    )
}

main() {
    local name test status passed=0 skipped=0
    local -a required=(
        process_start_ticks
        normalize_port_decimal
        normalize_port_csv
        is_public_listen_addr
        collect_listening_sockets
        firewall_check_conflicts
        firewall_openrc_service_enabled
        run_bounded_in_new_session
        run_bounded_with_timeout
        firewall_start_rollback_watchdog
        firewall_apply_desired_state
        firewall_directory_metadata_is_exact
        firewall_desired_state_is_current
        firewall_detect_docker_ports
        firewall_detect_public_listeners
        firewall_detect_allowed_ports
        firewall_build_config_with_added_ports
        firewall_read_live_allowed_ports
        firewall_view_rules
        firewall_live_config_matches_expected
    )
    local -a tests=(
        test_port_decimal_normalization
        test_public_listener_address_classification
        test_listener_sample_collects_expected_public_ports
        test_security_group_suggestions_exclude_dhcp_clients
        test_allowed_ports_merge_known_public_docker_and_extra_sources
        test_stopped_public_service_is_removed_unless_extra
        test_live_config_match_accepts_numeric_nft_snapshot
        test_live_config_match_rejects_critical_drift
        test_view_rules_reads_live_nft_instead_of_current_listeners
        test_view_rules_inactive_reports_no_live_ports_without_scanning
        test_view_rules_accepts_normalized_forward_priority_expression
        test_view_rules_rejects_unhooked_or_permissive_base_chains
        test_firewall_table_parsers_consume_large_trailing_input
        test_systemd_enabled_inactive_firewalld_conflict
        test_openrc_enabled_inactive_firewalld_conflict
        test_case_pid_registry_survives_nested_subshell
        test_bounded_background_processes_release_lock
        test_timeout_processes_release_lock
        test_busybox_timeout_fallback_releases_lock
        test_watchdog_survives_parent_without_holding_lock
        test_stopped_docker_fixed_binding_is_public
        test_additive_config_builder_adds_tcp_without_rebuilding_other_rules
        test_additive_config_builder_creates_first_udp_rule_and_set
        test_adding_port_uses_lightweight_commit_path
        test_apply_without_rollback_watchdog_must_not_touch_firewall
        test_unchanged_firewall_skips_confirmation_and_mutation
        test_second_firewall_scan_can_become_noop_before_mutation
        test_firewall_noop_requires_complete_managed_state
        test_firewall_disable_internal_verifies_service_and_live_table
        test_extra_port_remove_and_clear_commit_expected_state
        test_lightweight_add_does_not_rescan_docker_or_ssh
        test_internal_port_transition_preserves_unrelated_public_ports
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
    printf '%s firewall regression tests passed, %s skipped, %s registered.\n' \
        "$passed" "$skipped" "${#tests[@]}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
