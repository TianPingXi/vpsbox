#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=tests/test_helper.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

# shellcheck source=../vpsbox.sh
source "$REPO_DIR/vpsbox.sh"

cleanup() {
    rm -rf -- "$TEST_TMP"
}
trap cleanup EXIT

test_address_fallback_validation() {
    local ip
    local -a accepted=(
        "1:2:3:4:5:6:7::"
        "::1:2:3:4:5:6:7"
        "2001:db8::1"
        "::ffff:192.0.2.1"
        "1:2:3:4:5:6:192.0.2.1"
    )
    local -a rejected=(
        "1:2:3:4:5:6:7:8::"
        "1:2:3:4:5:6:7"
        "1::2::3"
        "::ffff:192.168.001.1"
        "01.2.3.4"
        "1.2.3.999"
    )

    for ip in "${accepted[@]}"; do
        is_ipv4_address "$ip" || is_ipv6_address_basic "$ip" ||
            fail "合法地址被回退校验拒绝：$ip"
    done
    for ip in "${rejected[@]}"; do
        if is_ipv4_address "$ip" || is_ipv6_address_basic "$ip"; then
            fail "非法地址被回退校验接受：$ip"
        fi
    done
}

test_blank_node_host_uses_detected_public_ipv4() {
    (
        local domain=""
        local output="$TEST_TMP/node-host-auto.out"
        public_ipv4() { printf '%s\n' 198.51.100.42; }
        node_ipv4_is_assigned_locally() { return 0; }

        prompt_node_host domain "地址：" <<< $'\n' >"$output" 2>&1
        assert_eq "198.51.100.42" "$domain" "留空时应采用自动检测到的公网 IPv4"
        assert_file_contains "$output" '自动检测到公网 IPv4：198\.51\.100\.42'
        assert_file_contains "$output" '已识别节点连接地址：198\.51\.100\.42'
    )
}

test_node_host_detection_failure_falls_back_to_manual_input() {
    (
        local domain=""
        local output="$TEST_TMP/node-host-fallback.out"
        public_ipv4() { return 1; }

        prompt_node_host domain "地址：" <<< $'\nnode.example.com' >"$output" 2>&1
        assert_eq "node.example.com" "$domain" "自动检测失败后应接受手动地址"
        assert_file_contains "$output" '公网 IPv4 自动检测失败，请手动输入节点连接地址。'
    )
}

test_node_host_rejected_detection_falls_back_to_manual_input() {
    (
        local domain=""
        local output="$TEST_TMP/node-host-reject.out"
        public_ipv4() { printf '%s\n' 198.51.100.42; }
        node_ipv4_is_assigned_locally() { return 0; }

        prompt_node_host domain "地址：" <<< $'\nn\nnode.example.com' >"$output" 2>&1
        assert_eq "node.example.com" "$domain" "拒绝自动地址后应接受手动地址"
        assert_file_contains "$output" '请手动输入节点连接地址。'
    )
}

test_node_host_warns_for_possible_nat() {
    (
        local domain=""
        local output="$TEST_TMP/node-host-nat.out"
        public_ipv4() { printf '%s\n' 198.51.100.42; }
        node_ipv4_is_assigned_locally() { return 1; }

        prompt_node_host domain "地址：" <<< $'\n' >"$output" 2>&1
        assert_eq "198.51.100.42" "$domain"
        assert_file_contains "$output" '当前 VPS 可能使用 NAT。'
        assert_file_contains "$output" '将后续节点端口映射到相同端口。'
    )
}

test_uri_write_preserves_existing_on_failure() {
    (
        CONFIG_DIR="$TEST_TMP/uri-config"
        URI_FILE="$CONFIG_DIR/vpsbox-uri.txt"
        SS_URI_FILE="$CONFIG_DIR/vpsbox-ss-uri.txt"
        VLESS_URI_FILE="$CONFIG_DIR/vpsbox-vless-uri.txt"
        : "$SS_URI_FILE" "$VLESS_URI_FILE"
        mkdir -p "$CONFIG_DIR"
        printf '%s\n' keep > "$URI_FILE"
        secure_config_dir() { return 0; }
        protocol_node_exists() { [ "$1" = ss ]; }
        generate_protocol_link() { return 42; }

        if write_uri_files; then
            fail "链接生成失败时 write_uri_files 不应成功"
        fi
        assert_file_contains "$URI_FILE" '^keep$' "生成失败不应截断原链接文件"
    )
}

test_node_eof_has_no_mutation() {
    local creator

    for creator in create_or_rebuild_node create_vless_reality_node; do
        (
            local event_log="$TEST_TMP/$creator.eof-events"
            : > "$event_log"
            require_valid_node_state_if_present() { return 0; }
            protocol_visible_exists() { return 1; }
            configured_node_ports_csv() { printf '\n'; }
            begin_node_transaction() { printf 'transaction\n' >> "$event_log"; }
            install_singbox_if_missing() { printf 'install\n' >> "$event_log"; }
            service_stop() { printf 'stop\n' >> "$event_log"; }
            firewall_refresh_if_enabled() { printf 'firewall\n' >> "$event_log"; }

            if "$creator" </dev/null >"$TEST_TMP/$creator.out" 2>&1; then
                fail "$creator 在 EOF 取消时应返回失败"
            fi
            assert_empty_file "$event_log" "$creator 在 EOF 前不得开始节点事务"
        )
    done
}

test_interactive_confirm_is_function_local() {
    (
        confirm=sentinel
        PORT=20000
        PROTOCOL=shadowsocks
        require_valid_node_state_if_present() { return 0; }
        protocol_visible_exists() { [ "$1" = ss ]; }
        load_protocol_state() { PORT=20000; PROTOCOL=shadowsocks; }

        create_or_rebuild_node <<< n >"$TEST_TMP/create-confirm.out" 2>&1 ||
            fail "取消覆盖节点应正常返回"
        assert_eq sentinel "$confirm" "创建节点确认不得覆盖同名全局变量"
    )

    (
        confirm=sentinel
        require_valid_node_state_if_present() { return 0; }
        protocol_visible_exists() { [ "$1" = ss ]; }
        load_protocol_state() {
            PORT=20000
            PROTOCOL=shadowsocks
            : "$PORT" "$PROTOCOL"
        }

        delete_node <<< n >"$TEST_TMP/delete-confirm.out" 2>&1 ||
            fail "取消删除节点应正常返回"
        assert_eq sentinel "$confirm" "删除节点确认不得覆盖同名全局变量"
    )

    (
        confirm=sentinel
        nexttrace_installed() { return 1; }

        if ensure_nexttrace <<< n >"$TEST_TMP/nexttrace-confirm.out" 2>&1; then
            fail "取消安装 nexttrace 应返回失败"
        fi
        assert_eq sentinel "$confirm" "nexttrace 安装确认不得覆盖同名全局变量"
    )
}

test_sensitive_interaction_eof_cancels_before_mutation() {
    (
        local event_log="$TEST_TMP/dns-eof-events"
        : > "$event_log"
        ipv4_dns_lines() { printf '%s\n' 1.1.1.1; }
        apply_ipv4_dns() { printf '%s\n' apply >> "$event_log"; }

        change_ipv4_dns </dev/null >"$TEST_TMP/dns-eof.out" 2>&1
        assert_empty_file "$event_log" "DNS 输入结束后不得应用配置"
        assert_file_contains "$TEST_TMP/dns-eof.out" '输入已结束，已取消'
    )

    (
        local event_log="$TEST_TMP/ssh-port-eof-events"
        : > "$event_log"
        SSHD_MAIN_CONF="$TEST_TMP/ssh-port-eof-sshd_config"
        : > "$SSHD_MAIN_CONF"
        sshd_binary() { printf '%s\n' /usr/sbin/sshd; }
        ssh_socket_activation_enabled_or_active() { return 1; }
        settle_stale_unapplied_ssh_tracking() { return 0; }
        choose_ssh_target_port() { printf '%s\n' 23333; }
        ssh_effective_ports_match_target() { return 1; }
        firewall_runtime_enabled() { return 1; }
        backup_change_file_once() { printf '%s\n' backup >> "$event_log"; }
        ssh_firewall_transition_begin() { printf '%s\n' firewall >> "$event_log"; }

        apply_ssh_port_change </dev/null >"$TEST_TMP/ssh-port-eof.out" 2>&1
        assert_empty_file "$event_log" "SSH 确认输入结束后不得备份或修改配置"
        assert_file_contains "$TEST_TMP/ssh-port-eof.out" '输入已结束，已取消'
    )

    (
        local event_log="$TEST_TMP/ssh-hardening-eof-events"
        : > "$event_log"
        SSHD_MAIN_CONF="$TEST_TMP/ssh-hardening-eof-sshd_config"
        : > "$SSHD_MAIN_CONF"
        sshd_binary() { printf '%s\n' /usr/sbin/sshd; }
        settle_stale_unapplied_ssh_tracking() { return 0; }
        ssh_basic_hardening_effective() { return 1; }
        backup_change_file_once() { printf '%s\n' backup >> "$event_log"; }

        apply_ssh_basic_hardening </dev/null >"$TEST_TMP/ssh-hardening-eof.out" 2>&1
        assert_empty_file "$event_log" "SSH 加固确认输入结束后不得备份或修改配置"
        assert_file_contains "$TEST_TMP/ssh-hardening-eof.out" '输入已结束，已取消'
    )

    (
        local event_log="$TEST_TMP/uninstall-eof-events"
        : > "$event_log"
        offer_restore_recorded_changes_before_uninstall() {
            printf '%s\n' restore >> "$event_log"
        }
        firewall_artifacts_present() {
            printf '%s\n' firewall >> "$event_log"
            return 1
        }

        uninstall_all </dev/null >"$TEST_TMP/uninstall-eof.out" 2>&1
        assert_empty_file "$event_log" "卸载确认输入结束后不得进入卸载流程"
        assert_file_contains "$TEST_TMP/uninstall-eof.out" '输入已结束，已取消卸载'
    )

    (
        local event_log="$TEST_TMP/uninstall-late-eof-events"
        : > "$event_log"
        firewall_artifacts_present() { return 0; }
        singbox_artifacts_present() { return 0; }
        offer_restore_recorded_changes_before_uninstall() {
            printf '%s\n' restore >> "$event_log"
        }
        firewall_disable_internal() {
            printf '%s\n' firewall-disable >> "$event_log"
        }
        uninstall_singbox_and_nodes() {
            printf '%s\n' singbox-remove >> "$event_log"
        }

        uninstall_all < <(printf 'YES\nYES\n') \
            >"$TEST_TMP/uninstall-late-eof.out" 2>&1
        assert_empty_file "$event_log" \
            "卸载后段输入结束前不得恢复系统设置、关闭防火墙或删除 sing-box"
        assert_file_contains "$TEST_TMP/uninstall-late-eof.out" '输入已结束，已取消卸载'
    )

    (
        local event_log="$TEST_TMP/hostname-eof-events"
        : > "$event_log"
        hostname_current_value() { printf '%s\n' old-host; }
        backup_change_file_once() { printf '%s\n' backup >> "$event_log"; }

        change_system_hostname </dev/null >"$TEST_TMP/hostname-eof.out" 2>&1
        assert_empty_file "$event_log" "主机名输入结束后不得备份或修改文件"
        assert_file_contains "$TEST_TMP/hostname-eof.out" '输入已结束，已取消'
    )

    (
        local event_log="$TEST_TMP/restore-eof-events"
        : > "$event_log"
        show_vpsbox_changes() { return 0; }
        change_needs_restore() {
            printf '%s\n' restore >> "$event_log"
            return 1
        }

        restore_vpsbox_system_changes </dev/null >"$TEST_TMP/restore-eof.out" 2>&1
        assert_empty_file "$event_log" "恢复确认输入结束后不得读取或恢复变更"
        assert_file_contains "$TEST_TMP/restore-eof.out" '输入已结束，已取消恢复'
    )

    (
        ss() { return 1; }
        ssh_effective_ports_csv() { printf '%s\n' 22; }
        docker_reserved_ports_for_port_choice() { printf '\n'; }
        port_is_effective_ssh_port() { return 1; }
        port_in_use_for_protocols() { return 1; }
        singbox_config_pids() { return 0; }

        if choose_node_port "" tcp "" "" <<< 80 >"$TEST_TMP/node-port-eof.out" 2>&1; then
            fail "特权节点端口确认输入结束后不应返回端口"
        fi
        assert_file_contains "$TEST_TMP/node-port-eof.out" '输入已结束，已取消节点端口选择'
    )

    (
        ss() { return 1; }
        ssh_effective_ports_csv() { printf '%s\n' 22; }
        docker_reserved_ports_for_port_choice() { printf '\n'; }
        port_in_use_tcp() { return 1; }

        if choose_ssh_target_port <<< 80 >"$TEST_TMP/ssh-privileged-port-eof.out" 2>&1; then
            fail "特权 SSH 端口确认输入结束后不应返回端口"
        fi
        assert_file_contains "$TEST_TMP/ssh-privileged-port-eof.out" '输入已结束，已取消修改'
    )
}

test_ss_password_generation_failure_rolls_back_before_mutation() {
    (
        local event_log="$TEST_TMP/password-failure-events"
        CONFIG_DIR="$TEST_TMP/password-failure-config"
        URI_FILE="$CONFIG_DIR/vpsbox-uri.txt"
        ACTIVE_NODE_BACKUP=""
        : > "$event_log"

        require_valid_node_state_if_present() { return 0; }
        protocol_visible_exists() { return 1; }
        begin_node_transaction() {
            ACTIVE_NODE_BACKUP="$TEST_TMP/password-failure-transaction"
            mkdir -p "$ACTIVE_NODE_BACKUP"
        }
        singbox_installed() { return 0; }
        install_singbox_if_missing() { return 0; }
        configured_node_ports_csv() { return 0; }
        prompt_node_host() { printf -v "$1" '%s' node.example.com; }
        default_name_for_host() { printf '%s\n' ss-node; }
        sanitize_paste_input() { printf '%s\n' "$1"; }
        sanitize_name() { printf '%s\n' "$1"; }
        choose_node_port() { printf '%s\n' 20000; }
        confirm_default_yes() { return 0; }
        random_password() { return 1; }
        rollback_node_files_transaction() {
            local backup="${ACTIVE_NODE_BACKUP:-}"
            ACTIVE_NODE_BACKUP=""
            rm -rf -- "$backup"
            printf '%s\n' rolled-back > "$TEST_TMP/password-failure.rollback"
        }
        firewall_prepare_port_transition() { printf '%s\n' firewall >> "$event_log"; }
        write_config() { printf '%s\n' config >> "$event_log"; }
        save_state() { printf '%s\n' state >> "$event_log"; }

        if create_or_rebuild_node <<< '' >"$TEST_TMP/password-failure.out" 2>&1; then
            fail "密码生成失败时节点创建不应成功"
        fi
        assert_file_contains "$TEST_TMP/password-failure.rollback" '^rolled-back$'
        assert_empty_file "$event_log" "密码生成失败后不得修改防火墙或节点文件"
        assert_file_contains "$TEST_TMP/password-failure.out" '随机强密码生成失败，未创建 Shadowsocks 节点。'
    )
}

test_first_singbox_install_marks_transaction_before_install() {
    (
        local log="$TEST_TMP/node-first-install.log"
        : > "$log"
        singbox_installed() { return 1; }
        mark_node_transaction_mutated() { printf '%s\n' mark >> "$log"; }
        install_singbox_if_missing() { printf '%s\n' install >> "$log"; }

        install_singbox_for_node_transaction
        assert_eq $'mark\ninstall' "$(cat "$log")" \
            "首次安装 sing-box 前必须先持久化节点事务修改标记"
    )

    (
        local log="$TEST_TMP/node-first-install-mark-failure.log"
        : > "$log"
        singbox_installed() { return 1; }
        mark_node_transaction_mutated() { return 23; }
        install_singbox_if_missing() { printf '%s\n' install >> "$log"; }

        if install_singbox_for_node_transaction; then
            fail "节点事务修改标记失败后不得继续安装 sing-box"
        fi
        assert_empty_file "$log"
    )
}

test_atomic_root_publish_preserves_existing_target() {
    (
        local dir="$TEST_TMP/root-atomic-publish"
        mkdir -p "$dir"
        printf '%s\n' old > "$dir/target"
        printf '%s\n' new > "$dir/source"
        chown() { return 0; }
        mv() { return 1; }

        if install_root_file_atomically "$dir/source" "$dir/target" 755; then
            fail "原子发布替换失败时不应报告成功"
        fi
        assert_file_contains "$dir/target" '^old$'
        if find "$dir" -maxdepth 1 -name '.vpsbox-publish.*' -print -quit | grep -q .; then
            fail "原子发布失败后不应遗留临时文件"
        fi
    )
}

test_singbox_service_publish_preserves_existing_target() {
    (
        local dir="$TEST_TMP/service-atomic-publish"
        local target="$dir/sing-box.service"
        local fake_bin="$dir/sing-box"
        local install_log="$dir/install.log"
        mkdir -p "$dir"
        printf '%s\n' old-service > "$target"
        printf '%s\n' '#!/bin/sh' 'exit 0' > "$fake_bin"
        chmod 755 "$fake_bin"
        : > "$install_log"
        failing_renderer() {
            printf '%s\n' partial-service
            return 23
        }
        install_root_file_atomically() {
            printf '%s\n' called >> "$install_log"
            return 0
        }

        if publish_singbox_service_definition \
            failing_renderer "$fake_bin" "$target" 644; then
            fail "服务定义渲染失败时不应报告成功"
        fi
        assert_file_contains "$target" '^old-service$' \
            "服务定义渲染失败不得截断现有文件"
        assert_empty_file "$install_log" \
            "服务定义渲染失败后不得进入发布阶段"
    )

    (
        local dir="$TEST_TMP/service-directory-target"
        local target="$dir/sing-box.service"
        local fake_bin="$dir/sing-box"
        mkdir -p "$target"
        printf '%s\n' '#!/bin/sh' 'exit 0' > "$fake_bin"
        chmod 755 "$fake_bin"
        valid_renderer() {
            printf '%s\n' '[Unit]' 'Description=sing-box'
        }
        chown() { return 0; }

        if publish_singbox_service_definition \
            valid_renderer "$fake_bin" "$target" 644; then
            fail "服务定义目标为目录时不应报告发布成功"
        fi
        [ -d "$target" ] || fail "拒绝目录目标时不得替换原目录"
        if find "$target" -mindepth 1 -print -quit | grep -q .; then
            fail "拒绝目录目标时不得在目录内遗留发布文件"
        fi
    )
}

test_setup_service_rejects_missing_binary_before_mutation() {
    (
        local event_log="$TEST_TMP/service-missing-binary-events"
        local output="$TEST_TMP/service-missing-binary.out"
        : > "$event_log"
        command() {
            if [ "${1:-}" = "-v" ] && [ "${2:-}" = sing-box ]; then
                return 1
            fi
            builtin command "$@"
        }
        is_systemd() {
            printf '%s\n' systemd >> "$event_log"
            return 0
        }
        publish_singbox_service_definition() {
            printf '%s\n' publish >> "$event_log"
            return 0
        }
        service_enable() {
            printf '%s\n' enable >> "$event_log"
            return 0
        }

        if setup_service >"$output" 2>&1; then
            fail "缺少 sing-box 可执行文件时 setup_service 不应成功"
        fi
        assert_empty_file "$event_log" \
            "缺少 sing-box 可执行文件时不得探测服务管理器或修改服务"
        assert_file_contains "$output" '未找到 sing-box 可执行文件'
    )
}

test_singbox_package_removal_failure_preserves_files() {
    (
        local delete_log="$TEST_TMP/singbox-uninstall-failure-delete-events"
        local service_log="$TEST_TMP/singbox-uninstall-failure-service-events"
        local output="$TEST_TMP/singbox-uninstall-failure.out"
        local service_active=1 service_enabled=1
        : > "$delete_log"
        : > "$service_log"
        OS=debian
        service_stop() {
            printf '%s\n' stop >> "$service_log"
            service_active=0
        }
        service_start() {
            printf '%s\n' start >> "$service_log"
            service_active=1
        }
        stop_singbox_config_processes() { return 0; }
        singbox_config_pids() { return 0; }
        sleep() { return 0; }
        service_is_running() { [ "$service_active" -eq 1 ]; }
        service_manager_is_active() { [ "$service_active" -eq 1 ]; }
        service_is_enabled() { [ "$service_enabled" -eq 1 ]; }
        service_disable() {
            printf '%s\n' disable >> "$service_log"
            service_enabled=0
        }
        service_enable() {
            printf '%s\n' enable >> "$service_log"
            service_enabled=1
        }
        singbox_package_installed() { return 0; }
        apt_get_bounded() { return 23; }
        is_systemd() {
            printf '%s\n' systemd >> "$delete_log"
            return 0
        }
        rm() {
            printf 'rm %s\n' "$*" >> "$delete_log"
            return 0
        }

        if uninstall_singbox_and_nodes >"$output" 2>&1; then
            fail "sing-box 软件包卸载失败时整体卸载不应成功"
        fi
        assert_empty_file "$delete_log" \
            "软件包卸载失败后不得删除服务、二进制或节点文件"
        [ "$service_active" -eq 1 ] || fail "软件包卸载失败后应恢复原运行状态"
        [ "$service_enabled" -eq 1 ] || fail "软件包卸载失败后应恢复原自启状态"
        assert_file_contains "$service_log" '^enable$'
        assert_file_contains "$service_log" '^start$'
        assert_file_contains "$output" \
            '已恢复 sing-box 原运行与自启状态'
    )
}

test_firewall_sync_restore_failure_preserves_backup() {
    (
        local install_calls=0 backup
        local case_dir="$TEST_TMP/firewall-sync-restore"
        RUNTIME_DIR="$case_dir/run"
        FIREWALL_ROLLBACK_DIR="$case_dir/persistent-rollbacks"
        FIREWALL_CONFIG="$case_dir/firewall.nft"
        FIREWALL_STATE_FILE="$case_dir/firewall.env"
        mkdir -p "$RUNTIME_DIR" "$FIREWALL_ROLLBACK_DIR"
        printf '%s\n' old-config > "$FIREWALL_CONFIG"
        printf '%s\n' state > "$FIREWALL_STATE_FILE"
        firewall_recover_pending_rollbacks() { return 0; }
        firewall_runtime_enabled() { return 0; }
        firewall_load_state() { return 0; }
        firewall_detect_allowed_ports() { return 0; }
        firewall_write_config() { printf '%s\n' new-config > "$1"; }
        firewall_install_managed_file() {
            install_calls=$((install_calls + 1))
            if [ "$install_calls" -eq 1 ]; then
                cp -- "$1" "$2"
            else
                return 23
            fi
        }
        nft() {
            [ "${1:-}" = "-c" ] && return 0
            return 42
        }

        if firewall_sync_active_config "" "" 1 >"$TEST_TMP/firewall-sync-restore.out" 2>&1; then
            fail "新防火墙规则应用失败时同步不应成功"
        fi
        backup="$(find "$FIREWALL_ROLLBACK_DIR" -maxdepth 1 -name 'firewall-config-backup.*' -print -quit)"
        [ -n "$backup" ] || fail "旧防火墙配置恢复失败时必须保留备份"
        assert_file_contains "$backup" '^old-config$'
        if find "$RUNTIME_DIR" -maxdepth 1 -name 'firewall-config-backup.*' -print -quit | grep -q .; then
            fail "旧防火墙救援备份不得只保存在易失运行目录"
        fi
        assert_file_contains "$TEST_TMP/firewall-sync-restore.out" \
            '磁盘配置未能恢复；旧配置持久备份已保留'
    )
}

test_runtime_dir_permission_failure_is_fatal() {
    (
        RUNTIME_DIR="$TEST_TMP/runtime-permission-failure"
        chown() { return 23; }

        if (prepare_runtime_dir) >"$TEST_TMP/runtime-permission.out" 2>&1; then
            fail "运行目录权限无法保护时不得继续"
        fi
        assert_file_contains "$TEST_TMP/runtime-permission.out" '无法保护运行目录'
    )
}

test_lockdir_first_acquisition_uses_reclaim_guard() {
    (
        local log="$TEST_TMP/lock-first-guard.log"
        RUNTIME_DIR="$TEST_TMP/lock-first-guard"
        LOCK_DIR="$RUNTIME_DIR/menu.lock.d"
        : > "$log"
        prepare_runtime_dir() { mkdir -p "$RUNTIME_DIR"; }
        command() {
            if [ "${1:-}" = "-v" ] && [ "${2:-}" = flock ]; then
                return 1
            fi
            builtin command "$@"
        }
        acquire_lockdir_reclaim_guard() { printf '%s\n' guard >> "$log"; }
        release_lockdir_reclaim_guard() { printf '%s\n' release >> "$log"; }
        activate_lockdir_lock() {
            assert_file_contains "$log" '^guard$' \
                "首次创建无 flock 锁目录前必须先取得回收保护"
        }

        acquire_lock
        assert_eq $'guard\nrelease' "$(cat "$log")"
    )
}

test_reality_checks_require_bounded_dns_and_openssl() {
    (
        local log="$TEST_TMP/dns-bounded.log"
        getent() { return 0; }
        run_bounded_command() {
            printf '%s\n' "$*" > "$log"
            return 1
        }
        if resolve_host_ips example.com; then
            fail "有界 DNS 命令失败时解析不应成功"
        fi
        assert_file_contains "$log" '^12 getent ahosts example\.com$'
    )
    (
        resolve_host_ips() { printf '%s\n' 192.0.2.1; }
        command() {
            if [ "${1:-}" = "-v" ] && [ "${2:-}" = "openssl" ]; then
                return 1
            fi
            builtin command "$@"
        }
        if check_reality_server example.com >/dev/null 2>&1; then
            fail "缺少 openssl 时不得把 Reality TLS 检查视为成功"
        fi
    )
}

test_view_node_propagates_uri_failure() {
    (
        require_valid_node_state_if_present() { return 0; }
        node_exists() { return 0; }
        write_uri_files() { return 1; }

        if view_node_link >/dev/null 2>&1; then
            fail "节点链接写入失败时查看功能不应成功"
        fi
    )
}

test_node_state_writes_are_atomic() {
    (
        local old_state="$TEST_TMP/state-atomic/old"
        CONFIG_DIR="$TEST_TMP/state-atomic/config"
        SS_STATE_FILE="$CONFIG_DIR/vpsbox-ss.env"
        VLESS_STATE_FILE="$CONFIG_DIR/vpsbox-vless.env"
        mkdir -p "$CONFIG_DIR"
        printf '%s\n' keep-old > "$SS_STATE_FILE"
        secure_config_dir() { return 0; }
        printf() {
            [ "${1:-}" != 'NAME=%s\n' ] || return 42
            builtin printf "$@"
        }

        if save_state example.com node 12345 secret 111111111111111111111111; then
            unset -f printf
            fail "SS 状态中途写入失败时不应报告成功"
        fi
        unset -f printf
        cp "$SS_STATE_FILE" "$old_state"
        assert_file_contains "$old_state" '^keep-old$' "SS 写入失败不得截断旧状态"
        [ -z "$(find "$CONFIG_DIR" -maxdepth 1 -name '.vpsbox-ss-state.*' -print -quit)" ] ||
            fail "SS 写入失败后残留临时状态文件"

        printf '%s\n' keep-vless > "$VLESS_STATE_FILE"
        printf() {
            [ "${1:-}" != 'UUID=%s\n' ] || return 42
            builtin printf "$@"
        }
        if save_vless_reality_state \
            example.com node 12345 uuid sni private key abcdef0123456789 \
            222222222222222222222222; then
            unset -f printf
            fail "VLESS 状态中途写入失败时不应报告成功"
        fi
        unset -f printf
        assert_file_contains "$VLESS_STATE_FILE" '^keep-vless$' "VLESS 写入失败不得截断旧状态"
        [ -z "$(find "$CONFIG_DIR" -maxdepth 1 -name '.vpsbox-vless-state.*' -print -quit)" ] ||
            fail "VLESS 写入失败后残留临时状态文件"
    )
}

test_service_running_requires_exact_config_process() {
    (
        singbox_installed() { return 0; }
        service_manager_is_active() { return 0; }
        singbox_config_pids() { return 0; }
        if service_is_running; then
            fail "服务管理器 active 但没有配置匹配进程时不得报告运行中"
        fi
        singbox_config_pids() { printf '%s\n' 1234; }
        service_is_running || fail "服务 active 且存在配置匹配进程时应报告运行中"
    )
}

test_singbox_summary_line_states() {
    (
        local mock_installed=0 mock_version=1.13.14 mock_status=未运行
        singbox_installed() { [ "$mock_installed" -eq 1 ]; }
        singbox_version() { printf '%s\n' "$mock_version"; }
        service_status_short() { printf '%s\n' "$mock_status"; }

        assert_eq " sing-box：未安装" "$(singbox_summary_line)"
        mock_installed=1
        assert_eq " sing-box：1.13.14 未运行" "$(singbox_summary_line)"
        mock_status=运行中
        assert_eq " sing-box：1.13.14 运行中" "$(singbox_summary_line)"
        mock_version=""
        assert_eq " sing-box：版本未知 运行中" "$(singbox_summary_line)"
    )
}

test_node_summary_orders_only_existing_protocols() {
    (
        local mock_vless=0 mock_ss=0
        node_artifacts_present() { return 1; }
        load_protocol_state() {
            case "$1" in
                vless)
                    [ "$mock_vless" -eq 1 ] || return 1
                    NAME=vless-node DOMAIN=vless.example.com PORT=30000
                    ;;
                ss)
                    [ "$mock_ss" -eq 1 ] || return 1
                    NAME=ss-node DOMAIN=ss.example.com PORT=30001
                    ;;
            esac
            : "$NAME" "$DOMAIN" "$PORT"
        }

        assert_eq "" "$(node_summary)" "未创建的协议不应显示状态区块"
        mock_vless=1
        mock_ss=1
        assert_eq "----------------------------------------
 VLESS Reality 节点
 状态：已创建
 名称：vless-node
 地址：vless.example.com
 端口：30000
----------------------------------------
 Shadowsocks 节点
 状态：已创建
 名称：ss-node
 地址：ss.example.com
 端口：30001" "$(node_summary)" \
            "VLESS 应显示在 Shadowsocks 上方，且 Shadowsocks 名称不带 2022"
    )
}

test_bbr_fq_summary_preserves_partial_state() {
    (
        local mock_bbr=已启用 mock_fq=已启用
        bbr_state() { printf '%s\n' "$mock_bbr"; }
        fq_state() { printf '%s\n' "$mock_fq"; }

        assert_eq "已开启" "$(bbr_fq_summary_state)"
        mock_fq="未启用（当前：fq_codel）"
        assert_eq "BBR 已启用 / fq 未启用（当前：fq_codel）" \
            "$(bbr_fq_summary_state)" "不完整状态应保留具体原因"
    )
}

test_main_and_system_menu_presentation() {
    (
        local main_output="$TEST_TMP/main-menu.out"
        local node_output="$TEST_TMP/node-menu.out"
        local system_output="$TEST_TMP/system-menu.out"
        clear() { :; }
        vpsbox_update_notice() { return 0; }
        singbox_summary_line() { printf ' sing-box：未安装\n'; }
        node_summary() { return 0; }
        ipv4_dns_lines() { printf ' nameserver 1.1.1.1\n'; }

        show_menu > "$main_output"
        assert_file_contains "$main_output" '^ \[5\] 一键检测$'
        assert_file_contains "$main_output" '^ \[6\] 三网回程测试$'
        assert_file_contains "$main_output" '^ \[7\] 第三方脚本$'
        assert_file_contains "$main_output" '^ \[00\] 更新 vpsbox$'
        assert_file_not_contains "$main_output" '一键自检|查看三网回程|其他脚本|更新 vpsbox 脚本'

        node_menu <<< "0" > "$node_output"
        assert_file_contains "$node_output" '^ \[1\] 创建/重建 VLESS Reality 节点（推荐）$'
        assert_file_contains "$node_output" '^ \[2\] 创建/重建 Shadowsocks 节点$'
        assert_file_contains "$node_output" '^ \[4\] 删除 VLESS Reality 节点$'
        assert_file_contains "$node_output" '^ \[5\] 删除 Shadowsocks 节点$'
        assert_file_not_contains "$node_output" 'SS 2022|删除当前节点'

        detect_os() {
            # OS is consumed dynamically by system_menu.
            # shellcheck disable=SC2034
            OS=debian
        }
        bbr_fq_summary_state() { printf '已开启\n'; }
        ipv4_priority_state() { printf '已启用\n'; }
        ssh_port_state() { printf '23333\n'; }
        ssh_hardening_state() { printf '已配置\n'; }
        fail2ban_service_state() { printf '运行中\n'; }
        fail2ban_sshd_state() { printf '已启用\n'; }
        ntp_sync_state() { printf '已同步\n'; }
        reboot_required_state() { printf '不需要\n'; }

        system_menu <<< "0" > "$system_output"
        assert_file_contains "$system_output" '^ BBR \+ fq：已开启$'
        assert_file_contains "$system_output" '^ SSH：端口 23333 / 加固已配置$'
        assert_file_contains "$system_output" '^ Fail2ban：运行中 / SSH 防护已启用$'
        assert_file_contains "$system_output" '^ 基础$'
        assert_file_contains "$system_output" '^ 网络$'
        assert_file_contains "$system_output" '^ SSH 安全$'
        assert_file_contains "$system_output" '^ 维护$'
        assert_file_contains "$system_output" '^ \[5\] 修改 IPv4 DNS$'
        assert_file_contains "$system_output" '^ \[12\] 限制 journald 日志大小$'
        awk 'previous == "----------------------------------------" && $0 == " [0] 返回主菜单" { found=1 }
            { previous=$0 } END { exit(found ? 0 : 1) }' "$system_output" ||
            fail "系统优化的返回项上方应有分割线"
    )
}

test_third_party_menu_keeps_authors() {
    (
        local output="$TEST_TMP/third-party-menu.out"
        clear() { :; }

        other_scripts_menu <<< "0" > "$output"
        assert_file_contains "$output" '^ 第三方脚本$'
        assert_file_contains "$output" '^ \[1\] IP 质量体检脚本（xykt）$'
        assert_file_contains "$output" '^ \[3\] TCP 质量检测脚本（ibsgss）$'
        assert_file_contains "$output" '^ \[4\] VPS 综合质量测试脚本（LloydAsp）$'
        assert_file_contains "$output" '^ \[5\] 一键 VPS 系统重装脚本（bin456789）$'
        awk 'previous == "----------------------------------------" && $0 == " [0] 返回主菜单" { found=1 }
            { previous=$0 } END { exit(found ? 0 : 1) }' "$output" ||
            fail "第三方脚本的返回项上方应有分割线"
    )
}

test_service_restore_checks_final_state() {
    (
        service_disable() { return 23; }
        service_is_enabled() { return 1; }
        service_stop() { return 23; }
        service_manager_is_active() { return 1; }
        stop_singbox_config_processes() { return 0; }
        singbox_config_pids() { return 0; }

        restore_singbox_service_state 0 0 ||
            fail "服务命令报错但禁用/停止目标状态已满足时应允许恢复完成"

        service_start() { return 0; }
        service_is_running() { return 1; }
        service_stop() { return 0; }
        if restart_singbox_cleanly; then
            fail "服务启动命令成功但实际进程未运行时不得报告重启成功"
        fi
    )
}

test_start_service_action_healthy_is_noop() {
    (
        local log="$TEST_TMP/start-service-healthy.log"
        : > "$log"
        require_valid_node_state_if_present() { return 0; }
        node_exists() { return 0; }
        service_is_running() { return 0; }
        verify_current_node_runtime() { return 0; }
        singbox_service_definition_is_current() { return 0; }
        service_is_enabled() { return 0; }
        install_singbox_if_missing() { printf '%s\n' install >> "$log"; }
        service_enable() { printf '%s\n' enable >> "$log"; }
        setup_service() { printf '%s\n' setup >> "$log"; }
        restart_singbox_cleanly() { printf '%s\n' restart >> "$log"; }
        service_start() { printf '%s\n' start >> "$log"; }

        start_service_action >/dev/null
        assert_empty_file "$log" "健康的 sing-box 启动操作不得产生修改"
    )
}

test_start_service_action_uses_light_start() {
    (
        local log="$TEST_TMP/start-service-light.log"
        : > "$log"
        require_valid_node_state_if_present() { return 0; }
        node_exists() { return 0; }
        service_is_running() { return 1; }
        install_singbox_if_missing() { printf '%s\n' install >> "$log"; }
        singbox_service_definition_is_current() { return 0; }
        service_manager_is_active() { return 1; }
        singbox_config_pids() { return 0; }
        service_is_enabled() { return 0; }
        service_enable() { printf '%s\n' enable >> "$log"; }
        service_start() { printf '%s\n' start >> "$log"; }
        setup_service() { printf '%s\n' setup >> "$log"; }
        restart_singbox_cleanly() { printf '%s\n' restart >> "$log"; }
        verify_current_node_runtime() { return 0; }

        start_service_action >/dev/null
        assert_file_contains "$log" '^install$'
        assert_file_contains "$log" '^start$'
        assert_file_not_contains "$log" '^(enable|setup|restart)$' \
            "当前服务定义只需启动时不得重写或重启"
    )
}

test_restart_service_action_keeps_full_restart() {
    (
        local log="$TEST_TMP/restart-service-full.log"
        : > "$log"
        require_valid_node_state_if_present() { return 0; }
        node_exists() { return 0; }
        install_singbox_if_missing() { printf '%s\n' install >> "$log"; }
        setup_service() { printf '%s\n' setup >> "$log"; }
        restart_singbox_cleanly() { printf '%s\n' restart >> "$log"; }
        verify_current_node_runtime() { return 0; }

        restart_service_action >/dev/null
        assert_file_contains "$log" '^install$'
        assert_file_contains "$log" '^setup$'
        assert_file_contains "$log" '^restart$'
    )
}

test_test_mode_blocks_real_service_mutation() {
    if service_start >"$TEST_TMP/service-guard.out" 2>&1; then
        fail "测试模式不得调用真实服务启动命令"
    fi
    assert_file_contains "$TEST_TMP/service-guard.out" '测试模式禁止调用真实服务管理命令'
}

test_protocol_specific_listener_checks() {
    (
        local tcp_ready=1 udp_ready=0
        ss() {
            case "$*" in
                '-H -ltn') [ "$tcp_ready" -eq 1 ] && printf '%s\n' 'LISTEN 0 4096 0.0.0.0:43333 0.0.0.0:*' ;;
                '-H -lun') [ "$udp_ready" -eq 1 ] && printf '%s\n' 'UNCONN 0 0 0.0.0.0:43333 0.0.0.0:*' ;;
            esac
        }

        port_listener_ready 43333 tcp || fail "VLESS 的 TCP 监听应被识别"
        if port_listener_ready 43333 both; then
            fail "SS 只有 TCP、缺少 UDP 时不得通过监听检查"
        fi
        if port_conflicts_with_existing_node 43333 tcp tcp; then
            fail "重建 VLESS 时，原节点占用的 TCP 不应被误判为外部冲突"
        fi
        udp_ready=1
        port_listener_ready 43333 both || fail "SS 的 TCP 与 UDP 都监听时应通过"
        if port_conflicts_with_existing_node 43333 both both; then
            fail "重建 Shadowsocks 时，原节点占用的 TCP/UDP 不应被误判为外部冲突"
        fi
    )
}

test_install_self_reports_download_failure() {
    (
        CMD_PATH="$TEST_TMP/install-self/bin/vpsbox"
        download_vpsbox_script() { return 23; }
        if install_self_command /dev/fd/63 >"$TEST_TMP/install-self.out" 2>&1; then
            fail "进程替换首次安装下载失败时必须返回非零"
        fi
        [ ! -e "$CMD_PATH" ] || fail "下载失败不应留下管理命令"
    )
}

test_interrupted_singbox_update_rolls_back() {
    (
        local case_dir="$TEST_TMP/singbox-interrupt"
        local binary="$case_dir/sing-box" backup_dir="$case_dir/update" backup="$case_dir/update/sing-box"
        mkdir -p "$backup_dir"
        printf '%s\n' old-binary > "$binary"
        cp "$binary" "$backup"
        service_stop() { return 0; }
        service_manager_is_active() { return 1; }
        stop_singbox_config_processes() { return 0; }
        node_exists() { return 1; }
        restore_singbox_service_state() { printf '%s %s\n' "$1" "$2" > "$case_dir/service-state"; }
        cleanup_vpsbox_lock() { return 0; }

        begin_singbox_update_transaction "$binary" "$backup" "$backup_dir" 1 1
        # 由已 source 的 cleanup_vpsbox_runtime 间接读取。
        # shellcheck disable=SC2034
        ACTIVE_SINGBOX_UPDATE_MUTATED=1
        printf '%s\n' partial-new-binary > "$binary"
        cleanup_vpsbox_runtime

        assert_file_contains "$binary" '^old-binary$' "更新中断后应恢复旧二进制"
        assert_file_contains "$case_dir/service-state" '^1 1$' "更新中断后应恢复原服务状态"
        assert_eq "" "$ACTIVE_SINGBOX_UPDATE_DIR" "回滚后必须清空活动更新事务"
    )
}

test_lockdir_metadata_window_is_waited() {
    (
        LOCK_DIR="$TEST_TMP/lock-window/lockdir"
        mkdir -p "$LOCK_DIR"
        (sleep 0.2; printf '%s\n' 'pid=4242' > "$LOCK_DIR/pid") &
        wait_for_lockdir_metadata || fail "锁目录创建后应等待并发持有者写入元数据"
        assert_eq 4242 "$(lock_pid_from_file "$LOCK_DIR/pid")"
        wait
    )
}

test_same_second_timestamp_is_not_after() {
    if timestamp_strictly_after 100 100; then
        fail "同秒 Docker 配置时间不得误判为启动后修改"
    fi
    timestamp_strictly_after 101 100 || fail "严格更晚的配置时间应被识别"
}

test_singbox_dependency_failure_does_not_touch_service() {
    (
        local fake_bin="$TEST_TMP/singbox-deps-bin"
        local event_log="$TEST_TMP/singbox-deps-events"
        local update_backup="$TEST_TMP/singbox-deps-backup"
        mkdir -p "$fake_bin"
        printf '%s\n' old-binary > "$fake_bin/sing-box"
        chmod 755 "$fake_bin/sing-box"
        PATH="$fake_bin:$PATH"
        : > "$event_log"

        singbox_installed() { return 0; }
        singbox_version() { printf '%s\n' 1.13.13; }
        singbox_binary_is_package_managed() { return 0; }
        service_is_running() { return 0; }
        service_is_enabled() { return 0; }
        install_deps() {
            printf '%s\n' deps >> "$event_log"
            return 23
        }
        run_singbox_installer() { printf '%s\n' installer >> "$event_log"; }
        restore_singbox_update_backup() { printf '%s\n' restore >> "$event_log"; }
        mktemp() {
            if [ "${1:-}" = "-d" ] && [[ "${2:-}" == /tmp/vpsbox-sing-box-update.* ]]; then
                mkdir -p "$update_backup"
                printf '%s\n' "$update_backup"
            else
                command mktemp "$@"
            fi
        }

        if update_singbox >"$TEST_TMP/singbox-deps.out" 2>&1; then
            fail "依赖准备失败时 update_singbox 应返回失败"
        fi
        assert_file_contains "$fake_bin/sing-box" '^old-binary$'
        assert_file_contains "$event_log" '^deps$'
        assert_file_not_contains "$event_log" '^(installer|restore)$'
        [ ! -e "$update_backup" ] || fail "未修改二进制时不应保留无用更新备份"
    )
}

test_failed_singbox_update_restores_binary_and_state() {
    (
        local fake_bin="$TEST_TMP/singbox-bin"
        local output="$TEST_TMP/singbox-update.out"
        local update_backup="$TEST_TMP/singbox-update-backup"
        VPSBOX_STATE_DIR="$TEST_TMP/singbox-update-state"
        SINGBOX_UPDATE_TRANSACTION_DIR="$VPSBOX_STATE_DIR/singbox-update"
        # shellcheck disable=SC2034 # 被测的 sing-box 持久事务函数动态读取。
        SINGBOX_UPDATE_TRANSACTION_STATE="$SINGBOX_UPDATE_TRANSACTION_DIR/state"
        mkdir -p "$fake_bin"
        printf '%s\n' '#!/bin/sh' 'printf "sing-box version 1.13.13\n"' > "$fake_bin/sing-box"
        chmod 755 "$fake_bin/sing-box"
        PATH="$fake_bin:$PATH"

        singbox_installed() { return 0; }
        singbox_version() { printf '%s\n' 1.13.13; }
        singbox_binary_is_package_managed() { return 0; }
        service_is_running() { return 0; }
        service_is_enabled() { return 0; }
        node_exists() { return 1; }
        install_deps() { return 0; }
        prepare_singbox_rollback_package() {
            local package="$2/sing-box-old.deb"
            : > "$package"
            printf '%s\n' "$package"
        }
        install_singbox_package_file() {
            cp "$SINGBOX_UPDATE_TRANSACTION_DIR/old-binary" "$fake_bin/sing-box"
        }
        run_singbox_installer() {
            printf '%s\n' broken-new-binary > "$fake_bin/sing-box"
            return 1
        }
        service_stop() { return 0; }
        stop_singbox_config_processes() { return 0; }
        setup_service() { return 0; }
        restore_singbox_service_state() {
            printf '%s %s\n' "$1" "$2" > "$TEST_TMP/restored-service-state"
        }
        mktemp() {
            if [ "${1:-}" = "-d" ] && [[ "${2:-}" == /tmp/vpsbox-sing-box-update.* ]]; then
                mkdir -p "$update_backup"
                printf '%s\n' "$update_backup"
            else
                command mktemp "$@"
            fi
        }

        if update_singbox >"$output" 2>&1; then
            fail "安装器失败时 update_singbox 应返回失败"
        fi
        assert_file_contains "$fake_bin/sing-box" '^#!/bin/sh$'
        assert_file_contains "$TEST_TMP/restored-service-state" '^1 1$'
        [ ! -e "$SINGBOX_UPDATE_TRANSACTION_DIR" ] ||
            fail "旧二进制和服务状态完整恢复后应清理持久事务"
    )
}

test_port_detection_failures_are_not_treated_as_free() {
    (
        local status
        ss() { return 127; }
        ssh_effective_ports_csv() { printf '%s\n' 22; }

        if port_in_use_tcp 43333; then
            fail "ss 失败时不得报告端口被正常识别为占用"
        else
            status=$?
        fi
        [ "$status" -gt 1 ] || fail "ss 失败必须与端口空闲状态区分"
        if random_port tcp >/dev/null 2>&1; then
            fail "监听探测失败时不得随机选出端口"
        fi
    )
    (
        ss() { return 0; }
        ssh_effective_ports_csv() { return 23; }
        if random_port tcp >/dev/null 2>&1; then
            fail "SSH 生效端口读取失败时不得随机选出端口"
        fi
    )
}

test_lockdir_reclaim_guard_serializes_contenders() {
    (
        local critical="$TEST_TMP/lock-reclaim-critical" overlap="$TEST_TMP/lock-reclaim-overlap"
        LOCK_RECLAIM_DIR="$TEST_TMP/lock-reclaim-guard"
        rm -rf -- "$LOCK_RECLAIM_DIR" "$critical" "$overlap"
        run_contender() {
            acquire_lockdir_reclaim_guard || return 1
            if ! mkdir "$critical" 2>/dev/null; then
                : > "$overlap"
            else
                sleep 0.2
                rmdir "$critical"
            fi
            release_lockdir_reclaim_guard
        }

        run_contender &
        local first=$!
        run_contender &
        local second=$!
        wait "$first"
        wait "$second"
        [ ! -e "$overlap" ] || fail "锁目录回收临界区发生并发重叠"

        mkdir "$LOCK_RECLAIM_DIR"
        acquire_lockdir_reclaim_guard ||
            fail "写入 owner 前中断留下的空回收目录应可安全回收"
        lockdir_reclaim_owned_by_self ||
            fail "回收空目录后必须建立当前进程的有效所有者元数据"
        release_lockdir_reclaim_guard
    )
}

test_openrc_service_does_not_inherit_menu_lock_fd() {
    (
        VPSBOX_TEST_MODE=0
        # shellcheck disable=SC2034 # 被测的 service_start 动态读取。
        OS=alpine
        is_systemd() { return 1; }
        retry() {
            shift 2
            "$@"
        }
        rc-service() {
            [ ! -e "/proc/$BASHPID/fd/200" ] ||
                fail "OpenRC 服务命令继承了菜单锁 FD 200"
        }
        exec 200>"$TEST_TMP/openrc-menu-lock"

        service_start
        [ -e "/proc/$BASHPID/fd/200" ] ||
            fail "关闭子命令 FD 不得关闭父菜单自己的锁"
        exec 200>&-
    )
}

test_singbox_pending_update_recovers_on_next_start() {
    (
        local fake_bin="$TEST_TMP/singbox-recovery/bin" backup="$TEST_TMP/singbox-recovery/old"
        local package="$TEST_TMP/singbox-recovery/old.deb" state_log="$TEST_TMP/singbox-recovery/service"
        mkdir -p "$fake_bin"
        printf '%s\n' '#!/bin/sh' 'printf "sing-box version 1.13.13\n"' > "$fake_bin/sing-box"
        chmod 755 "$fake_bin/sing-box"
        cp -a "$fake_bin/sing-box" "$backup"
        : > "$package"
        PATH="$fake_bin:$PATH"
        VPSBOX_STATE_DIR="$TEST_TMP/singbox-recovery/state"
        SINGBOX_UPDATE_TRANSACTION_DIR="$VPSBOX_STATE_DIR/singbox-update"
        SINGBOX_UPDATE_TRANSACTION_STATE="$SINGBOX_UPDATE_TRANSACTION_DIR/state"

        persist_singbox_update_transaction \
            "$fake_bin/sing-box" "$backup" "$package" 1.13.13 1 1
        printf '%s\n' '#!/bin/sh' 'printf "sing-box version 1.13.14\n"' > "$fake_bin/sing-box"
        chmod 755 "$fake_bin/sing-box"
        service_stop() { return 0; }
        service_manager_is_active() { return 1; }
        stop_singbox_config_processes() { return 0; }
        node_exists() { return 1; }
        install_singbox_package_file() {
            cp -a "$SINGBOX_UPDATE_TRANSACTION_DIR/old-binary" "$fake_bin/sing-box"
        }
        restore_singbox_service_state() { printf '%s %s\n' "$1" "$2" > "$state_log"; }

        recover_pending_singbox_update >/dev/null
        assert_eq 1.13.13 "$(singbox_version)"
        assert_file_contains "$state_log" '^1 1$'
        [ ! -e "$SINGBOX_UPDATE_TRANSACTION_DIR" ] ||
            fail "完整恢复后必须删除 sing-box 更新事务"
    )
}

test_singbox_atomic_restore_preserves_current_on_replace_failure() {
    (
        local dir="$TEST_TMP/singbox-atomic" target backup
        mkdir -p "$dir"
        target="$dir/sing-box"
        backup="$dir/old-binary"
        printf '%s\n' '#!/bin/sh' 'printf "sing-box version 1.13.14\n"' > "$target"
        printf '%s\n' '#!/bin/sh' 'printf "sing-box version 1.13.13\n"' > "$backup"
        chmod 755 "$target" "$backup"
        mv() { return 23; }

        if restore_singbox_binary_atomically "$backup" "$target" 1.13.13; then
            fail "最终原子替换失败时不得报告恢复成功"
        fi
        assert_eq 1.13.14 "$(singbox_binary_version_at "$target")" \
            "原子替换失败不得截断或覆盖当前二进制"
    )
}

test_singbox_recovery_rejects_corrupted_backup() {
    (
        local fake_bin="$TEST_TMP/singbox-corrupt/bin" backup="$TEST_TMP/singbox-corrupt/old"
        local package="$TEST_TMP/singbox-corrupt/old.deb"
        mkdir -p "$fake_bin"
        printf '%s\n' '#!/bin/sh' 'printf "sing-box version 1.13.13\n"' > "$fake_bin/sing-box"
        chmod 755 "$fake_bin/sing-box"
        cp -a "$fake_bin/sing-box" "$backup"
        : > "$package"
        PATH="$fake_bin:$PATH"
        VPSBOX_STATE_DIR="$TEST_TMP/singbox-corrupt/state"
        SINGBOX_UPDATE_TRANSACTION_DIR="$VPSBOX_STATE_DIR/singbox-update"
        # shellcheck disable=SC2034 # 被测的 sing-box 持久事务函数动态读取。
        SINGBOX_UPDATE_TRANSACTION_STATE="$SINGBOX_UPDATE_TRANSACTION_DIR/state"
        persist_singbox_update_transaction \
            "$fake_bin/sing-box" "$backup" "$package" 1.13.13 0 0
        printf '%s\n' tampered >> "$SINGBOX_UPDATE_TRANSACTION_DIR/old-binary"

        if recover_pending_singbox_update >/dev/null 2>&1; then
            fail "哈希损坏的 sing-box 备份不得用于恢复"
        fi
        [ -d "$SINGBOX_UPDATE_TRANSACTION_DIR" ] ||
            fail "校验失败时必须保留恢复记录供人工处理"
    )
}

test_external_singbox_update_is_rejected_before_mutation() {
    (
        local fake_bin="$TEST_TMP/singbox-external-bin"
        local event_log="$TEST_TMP/singbox-external-events"
        mkdir -p "$fake_bin"
        printf '%s\n' external-binary > "$fake_bin/sing-box"
        chmod 755 "$fake_bin/sing-box"
        PATH="$fake_bin:$PATH"
        : > "$event_log"

        singbox_installed() { return 0; }
        singbox_version() { printf '%s\n' 1.13.13; }
        singbox_binary_is_package_managed() { return 1; }
        install_deps() { printf '%s\n' deps >> "$event_log"; }
        run_singbox_installer() { printf '%s\n' installer >> "$event_log"; }

        if update_singbox >"$TEST_TMP/singbox-external.out" 2>&1; then
            fail "非软件包管理的 sing-box 应拒绝自动更新"
        fi
        assert_file_contains "$fake_bin/sing-box" '^external-binary$'
        assert_empty_file "$event_log" "拒绝外部安装时不得准备依赖或运行安装器"
        assert_file_contains "$TEST_TMP/singbox-external.out" '不是由系统 sing-box 软件包管理'
    )
}

main() {
    local test status passed=0
    local -a tests=(
        test_address_fallback_validation
        test_blank_node_host_uses_detected_public_ipv4
        test_node_host_detection_failure_falls_back_to_manual_input
        test_node_host_rejected_detection_falls_back_to_manual_input
        test_node_host_warns_for_possible_nat
        test_uri_write_preserves_existing_on_failure
        test_node_eof_has_no_mutation
        test_interactive_confirm_is_function_local
        test_sensitive_interaction_eof_cancels_before_mutation
        test_ss_password_generation_failure_rolls_back_before_mutation
        test_first_singbox_install_marks_transaction_before_install
        test_atomic_root_publish_preserves_existing_target
        test_singbox_service_publish_preserves_existing_target
        test_setup_service_rejects_missing_binary_before_mutation
        test_singbox_package_removal_failure_preserves_files
        test_firewall_sync_restore_failure_preserves_backup
        test_runtime_dir_permission_failure_is_fatal
        test_lockdir_first_acquisition_uses_reclaim_guard
        test_reality_checks_require_bounded_dns_and_openssl
        test_view_node_propagates_uri_failure
        test_node_state_writes_are_atomic
        test_service_running_requires_exact_config_process
        test_singbox_summary_line_states
        test_node_summary_orders_only_existing_protocols
        test_bbr_fq_summary_preserves_partial_state
        test_main_and_system_menu_presentation
        test_third_party_menu_keeps_authors
        test_service_restore_checks_final_state
        test_start_service_action_healthy_is_noop
        test_start_service_action_uses_light_start
        test_restart_service_action_keeps_full_restart
        test_test_mode_blocks_real_service_mutation
        test_protocol_specific_listener_checks
        test_install_self_reports_download_failure
        test_interrupted_singbox_update_rolls_back
        test_lockdir_metadata_window_is_waited
        test_same_second_timestamp_is_not_after
        test_singbox_dependency_failure_does_not_touch_service
        test_failed_singbox_update_restores_binary_and_state
        test_port_detection_failures_are_not_treated_as_free
        test_lockdir_reclaim_guard_serializes_contenders
        test_openrc_service_does_not_inherit_menu_lock_fd
        test_singbox_pending_update_recovers_on_next_start
        test_singbox_atomic_restore_preserves_current_on_replace_failure
        test_singbox_recovery_rejects_corrupted_backup
        test_external_singbox_update_is_rejected_before_mutation
    )

    for test in "${tests[@]}"; do
        set +e
        (set -e; "$test")
        status=$?
        set -e
        if [ "$status" -eq 0 ]; then
            printf 'ok - %s\n' "$test"
            passed=$((passed + 1))
        else
            printf 'not ok - %s\n' "$test" >&2
            return 1
        fi
    done
    printf '%s core regression tests passed.\n' "$passed"
}

main "$@"
