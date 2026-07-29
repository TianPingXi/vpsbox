#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=tests/test_helper.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

# shellcheck source=../vpsbox.sh
source "$REPO_DIR/vpsbox.sh"

# 文件级依赖桩会让多数节点用例不访问宿主机软件环境；先保留生产组合谓词，
# 供专项测试验证命令清单与 CA 信任检查确实接在一起。
eval "production_node_dependencies_available() $(declare -f node_dependencies_available | sed '1d')"

# 单元测试不访问软件源；需要验证依赖修复时在对应测试内覆盖此探测函数。
node_dependencies_available() { return 0; }
missing_node_commands() { printf '\n'; }

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

test_delayed_node_host_paste_is_adopted() {
    (
        local domain=""
        local output="$TEST_TMP/node-host-delayed-paste.out"
        public_ipv4() { printf '%s\n' 198.51.100.42; }
        node_ipv4_is_assigned_locally() { return 0; }

        prompt_node_host domain "地址：" \
            <<< $'\n\033[200~node.example.com\033[201~' > "$output" 2>&1
        assert_eq "node.example.com" "$domain" \
            "错位到确认阶段的合法节点地址必须自动采用"
        assert_file_contains "$output" \
            '检测到延迟到达的节点连接地址，已自动采用：node[.]example[.]com'
        assert_file_contains "$output" '已识别节点连接地址：node[.]example[.]com'
        assert_file_not_contains "$output" '已识别节点连接地址：198[.]51[.]100[.]42' \
            "检测到延迟粘贴后不得继续采用自动公网 IPv4"
        assert_file_not_contains "$output" '请输入 y、n' \
            "合法的延迟粘贴不得被当作无效确认输入"
    )
    (
        local domain=""
        local output="$TEST_TMP/node-host-delayed-repeat.out"
        public_ipv4() { printf '%s\n' 198.51.100.42; }
        node_ipv4_is_assigned_locally() { return 0; }

        prompt_node_host domain "地址：" \
            <<< $'\nnode.example.comnode.example.com\nvalid.example.com' > "$output" 2>&1
        assert_eq "valid.example.com" "$domain" \
            "延迟到达的重复粘贴必须拒绝，并允许重新输入"
        assert_file_contains "$output" '检测到节点地址可能被重复粘贴'
        assert_file_not_contains "$output" \
            '已自动采用：node[.]example[.]comnode[.]example[.]com' \
            "重复粘贴通过公共校验前不得宣称已采用"
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
        ip() { :; }
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

test_default_yes_confirmation_behavior() {
    local output="$TEST_TMP/default-yes-confirm.out"

    confirm_default_yes "确认？" <<< "" ||
        fail "默认确认直接回车时应继续按 y 处理"
    confirm_default_yes "确认？" <<< y ||
        fail "默认确认应接受小写 y"
    if confirm_default_yes "确认？" <<< n; then
        fail "默认确认应在输入小写 n 时取消"
    fi
    confirm_default_yes "确认？" <<< $'invalid\ny' >"$output" 2>&1 ||
        fail "无效输入后重新输入 y 应确认"
    assert_file_contains "$output" '请输入 y 或 n；直接回车默认 y。'
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

}

test_detect_os_preserves_node_state_globals() {
    (
        local before after variable os_release_values
        local expected_os="unknown"
        local expected_os_id=""
        local expected_os_id_like=""
        local -a node_state_vars=(
            DOMAIN NAME PORT PASSWORD METHOD PROTOCOL UUID FLOW
            REALITY_SERVER_NAME REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY
            REALITY_SHORT_ID FINGERPRINT CONFIG_ID
        )

        if [ -f /etc/os-release ]; then
            os_release_values="$(
                # shellcheck disable=SC1091
                . /etc/os-release || exit 1
                printf '%s\034%s' "${ID:-}" "${ID_LIKE:-}"
            )"
            IFS=$'\034' read -r expected_os_id expected_os_id_like <<< "$os_release_values"
        fi
        case "$expected_os_id $expected_os_id_like" in
            *alpine*) expected_os="alpine" ;;
            *debian*|*ubuntu*) expected_os="debian" ;;
            *centos*|*rhel*|*fedora*|*rocky*|*almalinux*) expected_os="redhat" ;;
        esac

        for variable in "${node_state_vars[@]}"; do
            printf -v "$variable" 'sentinel-%s' "$variable"
        done
        before="$(declare -p "${node_state_vars[@]}")"

        detect_os

        after="$(declare -p "${node_state_vars[@]}")"
        assert_eq "$before" "$after" \
            "detect_os 不得覆盖当前节点状态变量"
        assert_eq "$expected_os_id" "$OS_ID" \
            "detect_os 应刷新系统 ID"
        assert_eq "$expected_os_id_like" "$OS_ID_LIKE" \
            "detect_os 应刷新系统兼容 ID"
        assert_eq "$expected_os" "$OS" \
            "detect_os 应按 os-release 正确分类系统"
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

test_ssh_access_controls_are_checked_before_mutation() {
    (
        local event_log="$TEST_TMP/ssh-access-controls.events"
        SSHD_MAIN_CONF="$TEST_TMP/ssh-access-controls-sshd_config"
        printf '%s\n' 'Port 22' > "$SSHD_MAIN_CONF"
        : > "$event_log"
        sshd_binary() { printf '%s\n' /usr/sbin/sshd; }
        ssh_socket_activation_enabled_or_active() { return 1; }
        settle_stale_unapplied_ssh_tracking() { return 0; }
        choose_ssh_target_port() { printf '%s\n' 23333; }
        ssh_effective_ports_match_target() { return 1; }
        validate_ssh_access_controls() {
            printf '%s\n' access-check >> "$event_log"
            return 1
        }
        backup_change_file_once() { printf '%s\n' backup >> "$event_log"; }
        ssh_firewall_transition_begin() { printf '%s\n' firewall >> "$event_log"; }

        if apply_ssh_port_change >"$TEST_TMP/ssh-access-controls.out" 2>&1; then
            fail "本机访问控制未放行目标端口时 SSH 修改不应继续"
        fi
        assert_eq access-check "$(cat "$event_log")" \
            "访问控制检查失败后不得备份、改配置或调整防火墙"
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

test_node_publish_keeps_temporary_file_outside_config_set() {
    (
        local dir="$TEST_TMP/node-publish-layout"
        local source copied_during_publish=0
        CONFIG_DIR="$dir/etc/sing-box"
        NODE_CONFIG_DIR="$CONFIG_DIR/vpsbox.d"
        SS_CONFIG_PATH="$NODE_CONFIG_DIR/10-shadowsocks.json"
        # shellcheck disable=SC2034 # 被测目录白名单函数动态读取。
        VLESS_CONFIG_PATH="$NODE_CONFIG_DIR/20-vless-reality.json"
        source="$dir/staged.json"
        mkdir -p "$NODE_CONFIG_DIR"
        printf '%s\n' '{"inbounds":[]}' > "$source"
        chown() { return 0; }
        node_dir_is_secure() { return 0; }
        node_file_is_secure() { return 0; }
        cp() {
            local target="${!#}"
            case "$target" in
                "$CONFIG_DIR"/.vpsbox-node-publish.*) copied_during_publish=1 ;;
                *) fail "节点发布临时文件必须位于 CONFIG_DIR，不能进入受管配置集合：$target" ;;
            esac
            command cp "$@"
        }

        publish_staged_node_file "$source" "$SS_CONFIG_PATH"
        assert_eq 1 "$copied_during_publish" "节点发布必须经过受管目录外的临时文件"
        node_config_dir_contents_valid ||
            fail "节点发布期间的临时文件不得污染受管配置目录"
        assert_file_contains "$SS_CONFIG_PATH" '"inbounds"'
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

test_lock_acquisition_installs_runtime_cleanup_traps() {
    local log="$TEST_TMP/lock-cleanup-trap.log"

    : > "$log"
    (
        RUNTIME_DIR="$TEST_TMP/lock-cleanup-trap-flock"
        # shellcheck disable=SC2034 # 由已 source 的 acquire_lock 动态读取。
        LOCK_FILE="$RUNTIME_DIR/menu.lock"
        mkdir -p "$RUNTIME_DIR"
        prepare_runtime_dir() { :; }
        flock() { return 0; }
        write_flock_metadata() { :; }
        install_lock_cleanup_traps() { printf '%s\n' trap >> "$log"; }

        acquire_lock
        exec 200>&-
    )
    assert_eq trap "$(cat "$log")" \
        "flock 锁成功后必须安装运行时清理 trap"

    : > "$log"
    (
        RUNTIME_DIR="$TEST_TMP/lock-cleanup-trap-dir"
        LOCK_DIR="$RUNTIME_DIR/menu.lock.d"
        mkdir -p "$RUNTIME_DIR"
        prepare_runtime_dir() { :; }
        command() {
            if [ "${1:-}" = -v ] && [ "${2:-}" = flock ]; then
                return 1
            fi
            builtin command "$@"
        }
        acquire_lockdir_reclaim_guard() { return 0; }
        release_lockdir_reclaim_guard() { return 0; }
        write_lockdir_metadata() { return 0; }
        install_lock_cleanup_traps() { printf '%s\n' trap >> "$log"; }

        acquire_lock
    )
    assert_eq trap "$(cat "$log")" \
        "无 flock 锁成功后必须安装运行时清理 trap"
}

test_reality_checks_require_bounded_dns_and_openssl() {
    (
        local log="$TEST_TMP/dns-bounded.log" timeout
        getent() { return 0; }
        run_bounded_command() {
            printf '%s\n' "$*" > "$log"
            return 1
        }
        if resolve_host_ips example.com; then
            fail "有界 DNS 命令失败时解析不应成功"
        fi
        assert_file_contains "$log" '^[0-9]+ getent ahosts example\.com$'
        timeout="$(awk '$2 == "getent" && $3 == "ahosts" { print $1; exit }' "$log")"
        [[ "$timeout" =~ ^[0-9]+$ ]] &&
            [ "$timeout" -ge 1 ] && [ "$timeout" -le 60 ] ||
            fail "Reality DNS 检查必须设置 1-60 秒的有界超时"
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

test_reality_candidate_is_checked_only_once() {
    (
        local check_log="$TEST_TMP/reality-candidate-checks.log"

        ensure_node_dependencies() { return 0; }
        require_valid_node_state_if_present() { return 0; }
        protocol_visible_exists() { return 1; }
        configured_node_ports_csv() { printf '\n'; }
        prompt_node_host() { printf -v "$1" '%s' vless.example.com; }
        choose_node_port() { printf '%s\n' 20001; }
        confirm_default_yes() { return 0; }
        begin_node_transaction() { return 0; }
        install_singbox_for_node_transaction() { return 0; }
        rollback_node_files_transaction() { return 0; }
        check_reality_server() {
            printf '%s\n' "$1" >> "$check_log"
            [ "$1" = good.example ]
        }
        sing-box() { return 1; }

        : > "$check_log"
        if create_vless_reality_node <<< $'\nbad.example\ngood.example\n' >/dev/null 2>&1; then
            fail "UUID 夹具失败时创建流程不应报告成功"
        fi
        assert_eq $'bad.example\ngood.example' "$(cat "$check_log")" \
            "每个 Reality 候选只能执行一次 DNS/TLS 探测"
    )
    (
        local event_log="$TEST_TMP/reality-dependency-order.log"
        local dependencies_ready=0

        node_dependencies_available() { [ "$dependencies_ready" -eq 1 ]; }
        install_deps() {
            printf 'install\n' >> "$event_log"
            dependencies_ready=1
        }
        require_valid_node_state_if_present() { return 0; }
        protocol_visible_exists() { return 1; }
        configured_node_ports_csv() { printf '\n'; }
        prompt_node_host() { printf -v "$1" '%s' vless.example.com; }
        choose_node_port() { printf '%s\n' 20001; }
        check_reality_server() {
            [ "$dependencies_ready" -eq 1 ] ||
                fail "Reality 探测不得早于依赖补齐"
            printf 'check:%s\n' "$1" >> "$event_log"
        }
        confirm_default_yes() {
            printf 'confirm\n' >> "$event_log"
            return 1
        }
        command() {
            if [ "${1:-}" = -v ] && [ "${2:-}" = openssl ]; then
                [ "$dependencies_ready" -eq 1 ]
                return
            fi
            builtin command "$@"
        }

        : > "$event_log"
        create_vless_reality_node <<< $'\ngood.example\n' >/dev/null
        assert_eq $'install\ncheck:good.example\nconfirm' "$(cat "$event_log")" \
            "缺少依赖时必须先补齐，再对成功候选只探测一次"
    )
}

test_view_node_link_is_read_only() {
    (
        local write_log="$TEST_TMP/view-node-write.log"
        local output="$TEST_TMP/view-node-link.out"

        require_valid_node_state_if_present() { return 0; }
        node_exists() { return 0; }
        protocol_visible_exists() { [ "$1" = ss ]; }
        load_protocol_state() {
            PROTOCOL=shadowsocks
            DOMAIN=ss.example.com
            PORT=20001
            NAME=ss-node
            METHOD=2022-blake3-aes-128-gcm
            PASSWORD=QUFBQUFBQUFBQUFBQUFBQQ==
            : "$PROTOCOL" "$DOMAIN" "$PORT" "$NAME" "$METHOD" "$PASSWORD"
        }
        write_uri_files() {
            printf 'unexpected-write\n' >> "$write_log"
            return 1
        }
        repair_node_uri_cache() {
            printf 'unexpected-repair\n' >> "$write_log"
            return 1
        }
        repair_node_uri_cache_best_effort() {
            printf 'unexpected-best-effort-repair\n' >> "$write_log"
            return 1
        }

        : > "$write_log"
        view_node_link > "$output"
        assert_empty_file "$write_log" "查看节点链接不得写入 URI 缓存"
        assert_file_contains "$output" '^ ss://'
    )
}

test_uri_cache_repair_failure_is_warning_only() {
    (
        local output="$TEST_TMP/uri-cache-best-effort-unsafe.out"

        repair_node_uri_cache() { return 1; }
        node_uri_cache_status() { printf '%s\n' unsafe; }

        repair_node_uri_cache_best_effort "测试操作" > "$output" 2>&1 ||
            fail "URI 缓存修复失败不得阻止核心节点操作"
        assert_file_contains "$output" \
            '测试操作未自动修复节点链接缓存.*不安全权限'
    )
    (
        local output="$TEST_TMP/uri-cache-best-effort-stale.out"

        repair_node_uri_cache() { return 1; }
        node_uri_cache_status() { printf '%s\n' stale; }

        repair_node_uri_cache_best_effort "测试操作" > "$output" 2>&1 ||
            fail "普通 URI 缓存重建失败不得阻止核心节点操作"
        assert_file_contains "$output" \
            '测试操作未能更新节点链接缓存.*核心配置不受影响'
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

test_ssh_port_summary_line_states() {
    (
        local mock_ports=6384 mock_failed=0
        ssh_port_state() {
            [ "$mock_failed" -eq 0 ] || return 1
            printf '%s\n' "$mock_ports"
        }

        assert_eq " SSH 端口：6384" "$(ssh_port_summary_line)"
        mock_ports="22,6384"
        assert_eq " SSH 端口：22,6384" "$(ssh_port_summary_line)"
        mock_failed=1
        assert_eq " SSH 端口：无法读取" "$(ssh_port_summary_line)"
    )
}

test_node_summary_orders_only_existing_protocols() {
    (
        local mock_vless=0 mock_ss=0 output="$TEST_TMP/node-summary.out"
        node_core_artifacts_present() { return 1; }
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
        node_summary > "$output"
        assert_file_contains "$output" 'VLESS Reality 节点'
        assert_file_not_contains "$output" 'Shadowsocks 节点' \
            "未创建的 Shadowsocks 不应显示状态区块"

        mock_ss=1
        node_summary > "$output"
        awk '
            /VLESS Reality 节点/ {
                section = "vless"
                vless_heading = NR
                next
            }
            /Shadowsocks 节点/ {
                section = "ss"
                ss_heading = NR
                next
            }
            section == "vless" && /状态：已创建/ { vless_status = 1 }
            section == "vless" && /名称：vless-node/ { vless_name = 1 }
            section == "vless" && /地址：vless[.]example[.]com/ { vless_address = 1 }
            section == "vless" && /端口：30000/ { vless_port = 1 }
            section == "ss" && /状态：已创建/ { ss_status = 1 }
            section == "ss" && /名称：ss-node/ { ss_name = 1 }
            section == "ss" && /地址：ss[.]example[.]com/ { ss_address = 1 }
            section == "ss" && /端口：30001/ { ss_port = 1 }
            END {
                ok = vless_heading && ss_heading && vless_heading < ss_heading
                ok = ok && vless_status && vless_name && vless_address && vless_port
                ok = ok && ss_status && ss_name && ss_address && ss_port
                exit(ok ? 0 : 1)
            }
        ' "$output" ||
            fail "节点汇总必须按 VLESS、Shadowsocks 顺序显示各自状态、名称、地址和端口"
        assert_file_not_contains "$output" '2022' \
            "Shadowsocks 状态名称不应包含 2022"
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

test_self_check_classifies_and_summarizes_results() {
    (
        local first_output="$TEST_TMP/self-check-empty-first.out"
        local second_output="$TEST_TMP/self-check-empty-second.out"
        local metadata_output="$TEST_TMP/self-check-install-metadata.out"
        local metadata_invalid_output="$TEST_TMP/self-check-install-metadata-invalid.out"
        local external_output="$TEST_TMP/self-check-external-journald.out"
        local scan_fail_output="$TEST_TMP/self-check-scan-fail.out"
        local status count
        local mock_ntp_state=未安装 mock_journald_state=未配置 ports_ok=1

        detect_os() { OS=debian; }
        id() { printf '%s\n' 0; }
        CMD_PATH=/bin/sh
        node_core_artifacts_present() { return 1; }
        load_protocol_state() { return 1; }
        singbox_installed() { return 1; }
        public_ipv4() { return 1; }
        ntp_sync_state() { printf '%s\n' "$mock_ntp_state"; }
        bbr_state() { printf '%s\n' 未启用; }
        fq_state() { printf '%s\n' 未启用; }
        ipv4_priority_state() { printf '%s\n' 未启用; }
        ssh_effective_ports_listening() { return 0; }
        ssh_port_state() { printf '%s\n' 22; }
        ssh_hardening_state() { printf '%s\n' 未配置; }
        fail2ban_installed() { return 1; }
        firewall_control_plane_present() { return 1; }
        reboot_required_state() { printf '%s\n' 不需要; }
        journal_disk_usage() { printf '%s\n' 0B; }
        journald_limit_state() { printf '%s\n' "$mock_journald_state"; }
        journald_conf_value() {
            case "$1" in
                SystemMaxUse) printf '%s\n' 500M ;;
                SystemMaxFileSize) printf '%s\n' 50M ;;
                *) return 1 ;;
            esac
        }
        install_metadata_read() {
            [ -f "$INSTALL_METADATA_FILE" ] || return 1
            case "$(cat "$INSTALL_METADATA_FILE")" in
                $'FIRST_INSTALLED_VERSION=v1.0.44\nFIRST_INSTALLED_AT=2026-07-29T01:02:03Z')
                    printf '%s\n' v1.0.44 2026-07-29T01:02:03Z
                    ;;
                *)
                    return 1
                    ;;
            esac
        }
        show_ports_security_group() {
            [ "$ports_ok" -eq 1 ] || return 1
            printf '%s\n' PORTS_MARKER
        }
        JOURNALD_VPSBOX_CONF="$TEST_TMP/missing-journald.conf"
        FIREWALL_STATE_FILE="$TEST_TMP/missing-firewall.env"
        BBR_CONF="$TEST_TMP/missing-bbr.conf"
        SSHD_VPSBOX_HARDENING_CONF="$TEST_TMP/missing-ssh-hardening.conf"
        VPSBOX_STATE_DIR="$TEST_TMP/self-check-state"
        INSTALL_METADATA_FILE="$VPSBOX_STATE_DIR/install.env"
        change_applied_recorded_readonly() { return 1; }

        run_self_check > "$first_output" 2>&1 ||
            fail "包含未启用项的一键检测仍应正常完成"
        run_self_check > "$second_output" 2>&1 ||
            fail "重复执行一键检测仍应正常完成"

        for status in OK INFO WARN FAIL; do
            count="$(awk -v status="$status" '$1 == status && $2 == "|" { count++ } END { print count + 0 }' "$first_output")"
            assert_file_contains "$first_output" \
                "^检测结果：.*${status} ${count}([ /]|$)" \
                "摘要中的 $status 数量必须来自实际结果行"
        done
        assert_eq "$(grep '^检测结果：' "$first_output")" \
            "$(grep '^检测结果：' "$second_output")" \
            "每次一键检测必须重新开始计数"
        assert_eq 1 "$(grep -c '^检测结果：' "$first_output")" \
            "一次检测只能输出一条结果摘要"
        awk '
            /PORTS_MARKER/ { marker = NR }
            /^检测结果：/ { summary = NR }
            END { exit !(marker && summary > marker) }
        ' "$first_output" || fail "检测摘要必须位于端口建议之后"
        assert_eq 1 "$(grep -Ec ' INFO[[:space:]]+[|] 节点[[:space:]]+[|] 未创建' "$first_output")" \
            "未创建节点只能显示一条 INFO"
        assert_file_contains "$first_output" 'INFO[[:space:]]+[|] sing-box[[:space:]]+[|] 未安装'
        assert_file_not_contains "$first_output" '配置文件.*不存在|服务状态.*未运行' \
            "未创建节点不得重复报告派生状态"
        assert_eq 1 "$(grep -Ec ' INFO[[:space:]]+[|] Fail2ban[[:space:]]+[|] 未安装' "$first_output")" \
            "未安装 Fail2ban 只能显示一条 INFO"
        assert_file_not_contains "$first_output" '（可选）|[|] Fail2ban 状态|[|] SSH 防护' \
            "Fail2ban 未安装时不得输出重复状态行"
        assert_eq 1 "$(grep -Ec ' INFO[[:space:]]+[|] 日志限制[[:space:]]+[|] 未配置' "$first_output")" \
            "未配置 journald 限制只能显示一条 INFO"
        assert_file_not_contains "$first_output" '日志最大占用|单个日志最大' \
            "未配置 journald 限制时不得输出派生值"
        assert_file_contains "$first_output" 'INFO[[:space:]]+[|] BBR[[:space:]]+[|] 未启用'
        assert_file_contains "$first_output" 'INFO[[:space:]]+[|] fq[[:space:]]+[|] 未启用'
        assert_file_contains "$first_output" 'INFO[[:space:]]+[|] IPv4 优先[[:space:]]+[|] 未启用'
        assert_file_contains "$first_output" 'INFO[[:space:]]+[|] SSH 基础加固[[:space:]]+[|] 未配置'
        assert_file_contains "$first_output" 'INFO[[:space:]]+[|] NTP 同步[[:space:]]+[|] 未安装'
        assert_file_contains "$first_output" 'INFO[[:space:]]+[|] 主机防火墙[[:space:]]+[|] 未启用'
        assert_file_contains "$first_output" \
            'INFO[[:space:]]+[|] 首次安装[[:space:]]+[|] 历史未记录'

        mkdir -p "$VPSBOX_STATE_DIR"
        chmod 700 "$VPSBOX_STATE_DIR"
        printf '%s\n' \
            'FIRST_INSTALLED_VERSION=v1.0.44' \
            'FIRST_INSTALLED_AT=2026-07-29T01:02:03Z' \
            > "$INSTALL_METADATA_FILE"
        chmod 600 "$INSTALL_METADATA_FILE"
        run_self_check > "$metadata_output" 2>&1 ||
            fail "有首次安装记录时一键检测应正常完成"
        assert_file_contains "$metadata_output" \
            'OK[[:space:]]+[|] 首次安装[[:space:]]+[|] v1[.]0[.]44 / 2026-07-29T01:02:03Z'
        printf '%s\n' 'MALFORMED=keep-me' > "$INSTALL_METADATA_FILE"
        chmod 600 "$INSTALL_METADATA_FILE"
        run_self_check > "$metadata_invalid_output" 2>&1 ||
            fail "首次安装记录异常时一键检测仍应正常完成"
        assert_file_contains "$metadata_invalid_output" \
            'WARN[[:space:]]+[|] 首次安装[[:space:]]+[|] 记录异常'

        mock_ntp_state=运行中
        mock_journald_state=已配置
        run_self_check > "$external_output" 2>&1 ||
            fail "外部 journald 限制已生效时一键检测应正常完成"
        assert_file_contains "$external_output" 'WARN[[:space:]]+[|] NTP 同步[[:space:]]+[|] 运行中'
        assert_file_contains "$external_output" 'OK[[:space:]]+[|] 日志限制[[:space:]]+[|] 已配置（系统配置已生效）'
        assert_file_contains "$external_output" 'OK[[:space:]]+[|] 日志最大占用[[:space:]]+[|] 500M'
        assert_file_contains "$external_output" 'OK[[:space:]]+[|] 单个日志最大[[:space:]]+[|] 50M'

        ports_ok=0
        run_self_check > "$scan_fail_output" 2>&1 ||
            fail "端口扫描失败仍应完成其余状态报告"
        assert_file_contains "$scan_fail_output" 'WARN[[:space:]]+[|] 端口扫描[[:space:]]+[|] 未完成'
        assert_eq 1 "$(grep -c '^检测结果：' "$scan_fail_output")" \
            "端口扫描失败时仍只能输出一条摘要"
    )
    (
        local output="$TEST_TMP/self-check-damaged.out"
        local state_output="$TEST_TMP/self-check-damaged-firewall-state.out"
        local saved_state_output="$TEST_TMP/self-check-saved-firewall-state.out"
        local status count
        local firewall_present=1 state_secure=1 state_valid=1

        detect_os() { OS=debian; }
        id() { printf '%s\n' 0; }
        CMD_PATH=/bin/sh
        node_core_artifacts_present() { return 0; }
        require_valid_node_state_if_present() { return 1; }
        load_protocol_state() { return 1; }
        singbox_installed() { return 0; }
        singbox_version() { printf '%s\n' 1.13.14; }
        public_ipv4() { return 1; }
        ntp_sync_state() { printf '%s\n' 未运行; }
        bbr_state() { printf '%s\n' 未启用; }
        fq_state() { printf '%s\n' 未启用; }
        ipv4_priority_state() { printf '%s\n' 未启用; }
        ssh_effective_ports_listening() { return 1; }
        ssh_port_state() { printf '%s\n' 22; }
        ssh_hardening_state() { printf '%s\n' 未配置; }
        fail2ban_installed() { return 0; }
        fail2ban_sshd_configuration_healthy() { return 1; }
        fail2ban_service_state() { printf '%s\n' 运行中; }
        fail2ban_service_is_enabled() { return 0; }
        fail2ban_sshd_state() { printf '%s\n' 已启用; }
        firewall_control_plane_present() { [ "$firewall_present" -eq 1 ]; }
        firewall_managed_file_is_secure() { return 1; }
        firewall_state_file_is_secure() { [ "$state_secure" -eq 1 ]; }
        firewall_load_state() { [ "$state_valid" -eq 1 ]; }
        reboot_required_state() { printf '%s\n' 不需要; }
        journal_disk_usage() { printf '%s\n' 0B; }
        journald_limit_state() { printf '%s\n' 未配置; }
        show_ports_security_group() { printf '%s\n' PORTS_MARKER; }
        JOURNALD_VPSBOX_CONF="$TEST_TMP/damaged-journald.conf"
        BBR_CONF="$TEST_TMP/damaged-bbr.conf"
        SSHD_VPSBOX_HARDENING_CONF="$TEST_TMP/damaged-ssh-hardening.conf"
        VPSBOX_STATE_DIR="$TEST_TMP/self-check-damaged-state"
        INSTALL_METADATA_FILE="$VPSBOX_STATE_DIR/install.env"
        change_applied_recorded_readonly() { [ "$1" = GAI_CONF ]; }
        printf '%s\n' broken > "$JOURNALD_VPSBOX_CONF"
        printf '%s\n' broken > "$BBR_CONF"
        printf '%s\n' broken > "$SSHD_VPSBOX_HARDENING_CONF"
        chmod 644 "$JOURNALD_VPSBOX_CONF"

        run_self_check > "$output" 2>&1 ||
            fail "包含 FAIL 结果的一键检测仍应作为状态报告正常完成"
        assert_eq 1 "$(grep -Ec ' FAIL[[:space:]]+[|] 配置完整性[[:space:]]+[|] 未通过' "$output")" \
            "节点完整性损坏只能报告一次"
        assert_file_not_contains "$output" '配置语法.*配置完整性未通过' \
            "节点完整性失败不得派生第二条语法失败"
        assert_eq 1 "$(grep -Ec ' FAIL[[:space:]]+[|] Fail2ban[[:space:]]+[|]' "$output")" \
            "Fail2ban 损坏只能合并为一条 FAIL"
        assert_file_not_contains "$output" '[|] Fail2ban 状态|[|] SSH 防护' \
            "Fail2ban 损坏不得恢复成三行重复结果"
        assert_file_contains "$output" '配置或 nftables 后端异常'
        assert_file_contains "$output" 'FAIL[[:space:]]+[|] NTP 同步[[:space:]]+[|] 未运行'
        assert_file_contains "$output" 'FAIL[[:space:]]+[|] 主机防火墙[[:space:]]+[|] 配置文件不完整或不安全'
        assert_file_contains "$output" 'FAIL[[:space:]]+[|] 日志限制[[:space:]]+[|] 配置存在但未按预期生效或不安全'
        assert_file_contains "$output" 'FAIL[[:space:]]+[|] BBR[[:space:]]+[|] 配置存在但未生效'
        assert_file_contains "$output" 'FAIL[[:space:]]+[|] fq[[:space:]]+[|] 配置存在但未生效'
        assert_file_contains "$output" 'FAIL[[:space:]]+[|] IPv4 优先[[:space:]]+[|] 配置记录存在但未生效'
        assert_file_contains "$output" 'FAIL[[:space:]]+[|] SSH 基础加固[[:space:]]+[|] 配置存在但未生效'
        assert_file_not_contains "$output" '日志最大占用|单个日志最大' \
            "journald 配置损坏时不得继续显示派生值"
        assert_eq 1 "$(grep -c '^检测结果：' "$output")" \
            "损坏场景只能输出一条结果摘要"
        for status in OK INFO WARN FAIL; do
            count="$(awk -v status="$status" '$1 == status && $2 == "|" { count++ } END { print count + 0 }' "$output")"
            assert_file_contains "$output" \
                "^检测结果：.*${status} ${count}([ /]|$)" \
                "损坏场景摘要中的 $status 数量必须来自实际结果行"
        done

        firewall_present=0
        state_secure=1
        state_valid=0
        FIREWALL_STATE_FILE="$TEST_TMP/damaged-firewall-state.env"
        printf '%s\n' 'EXTRA_TCP_PORTS=invalid' > "$FIREWALL_STATE_FILE"
        run_self_check > "$state_output" 2>&1 ||
            fail "关闭防火墙但残留损坏状态文件时仍应完成状态报告"
        assert_file_contains "$state_output" \
            'FAIL[[:space:]]+[|] 主机防火墙[[:space:]]+[|] 未启用，但状态文件不完整或不安全'

        state_valid=1
        printf '%s\n' 'EXTRA_TCP_PORTS=8443' 'EXTRA_UDP_PORTS=' > "$FIREWALL_STATE_FILE"
        run_self_check > "$saved_state_output" 2>&1 ||
            fail "关闭防火墙且状态文件有效时仍应完成状态报告"
        assert_file_contains "$saved_state_output" \
            'INFO[[:space:]]+[|] 主机防火墙[[:space:]]+[|] 未启用，已保存额外端口'
    )
    (
        local output="$TEST_TMP/self-check-node-unavailable.out"
        local unsafe_output="$TEST_TMP/self-check-node-uri-unsafe.out"
        local current_output="$TEST_TMP/self-check-node-uri-current.out"
        local mock_uri_cache_state=stale

        detect_os() { OS=debian; }
        id() { printf '%s\n' 0; }
        CMD_PATH=/bin/sh
        node_core_artifacts_present() { return 0; }
        node_uri_artifacts_present() { return 1; }
        require_valid_node_state_if_present() { return 0; }
        node_uri_cache_status() { printf '%s\n' "$mock_uri_cache_state"; }
        load_protocol_state() {
            [ "$1" = vless ] || return 1
            DOMAIN=192.0.2.10
            PORT=20001
            # shellcheck disable=SC2034 # run_self_check 在状态加载后动态读取。
            REALITY_SERVER_NAME=example.com
        }
        singbox_installed() { return 0; }
        singbox_version() { printf '%s\n' 1.13.14; }
        port_listener_ready() { return 1; }
        check_active_node_config() { return 0; }
        service_status_short() { printf '%s\n' 运行中; }
        public_ipv4() { return 1; }
        ntp_sync_state() { printf '%s\n' 已同步; }
        bbr_state() { printf '%s\n' 已启用; }
        fq_state() { printf '%s\n' 已启用; }
        ipv4_priority_state() { printf '%s\n' 已启用; }
        ssh_effective_ports_listening() { return 0; }
        ssh_port_state() { printf '%s\n' 22; }
        ssh_hardening_state() { printf '%s\n' 已配置; }
        fail2ban_installed() { return 1; }
        firewall_control_plane_present() { return 1; }
        reboot_required_state() { printf '%s\n' 不需要; }
        journal_disk_usage() { printf '%s\n' 0B; }
        journald_limit_state() { printf '%s\n' 未配置; }
        show_ports_security_group() { printf '%s\n' PORTS_MARKER; }
        change_applied_recorded_readonly() { return 1; }
        BBR_CONF="$TEST_TMP/missing-node-case-bbr.conf"
        SSHD_VPSBOX_HARDENING_CONF="$TEST_TMP/missing-node-case-ssh-hardening.conf"
        JOURNALD_VPSBOX_CONF="$TEST_TMP/missing-node-case-journald.conf"
        FIREWALL_STATE_FILE="$TEST_TMP/missing-node-case-firewall.env"
        URI_FILE="$TEST_TMP/missing-node-uri.txt"
        VPSBOX_STATE_DIR="$TEST_TMP/self-check-node-state"
        INSTALL_METADATA_FILE="$VPSBOX_STATE_DIR/install.env"

        run_self_check > "$output" 2>&1 ||
            fail "节点监听和链接缺失时仍应完成状态报告"
        assert_file_contains "$output" 'FAIL[[:space:]]+[|] VLESS Reality 监听[[:space:]]+[|] 20001 未监听'
        assert_file_contains "$output" 'WARN[[:space:]]+[|] 节点链接[[:space:]]+[|] 缺失或已过期'
        assert_file_not_contains "$output" 'FAIL[[:space:]]+[|] 配置完整性'

        mock_uri_cache_state=unsafe
        run_self_check > "$unsafe_output" 2>&1 ||
            fail "URI 缓存不安全时一键检测仍应完成状态报告"
        assert_file_contains "$unsafe_output" \
            'FAIL[[:space:]]+[|] 节点链接[[:space:]]+[|] 文件不安全，已拒绝自动覆盖'
        assert_file_not_contains "$unsafe_output" \
            'WARN[[:space:]]+[|] 节点链接|OK[[:space:]]+[|] 节点链接'

        mock_uri_cache_state=current
        run_self_check > "$current_output" 2>&1 ||
            fail "URI 缓存正常时一键检测仍应完成状态报告"
        assert_file_contains "$current_output" \
            'OK[[:space:]]+[|] 节点链接[[:space:]]+[|]'
        assert_file_not_contains "$current_output" \
            'WARN[[:space:]]+[|] 节点链接|FAIL[[:space:]]+[|] 节点链接'
    )
}

test_main_menu_update_notice_spacing_and_entries() {
    (
        local output="$TEST_TMP/main-menu-no-update.out"
        clear() { :; }
        singbox_summary_line() { printf '%s\n' ' sing-box：未安装'; }
        ssh_port_summary_line() { printf '%s\n' ' SSH 端口：22'; }
        node_summary() { :; }
        ipv4_dns_lines() { printf '%s\n' ' nameserver 1.1.1.1'; }
        UPDATE_AVAILABLE=0

        show_menu > "$output"
        awk '
            /提示：输入 vpsbox 打开管理面板/ {
                found = 1
                getline
                exit($0 != "----------------------------------------")
            }
            END { if (!found) exit 1 }
        ' "$output" || fail "没有更新提示时，提示行后必须直接显示分隔线"
        assert_file_contains "$output" '^ [[]6[]] 第三方脚本$'
        assert_file_not_contains "$output" '^ [[]7[]] ' \
            "第三方脚本改为编号 6 后不得残留旧编号 7"
    )
    (
        local output="$TEST_TMP/main-menu-with-update.out"
        clear() { :; }
        singbox_summary_line() { printf '%s\n' ' sing-box：未安装'; }
        ssh_port_summary_line() { printf '%s\n' ' SSH 端口：22'; }
        node_summary() { :; }
        ipv4_dns_lines() { printf '%s\n' ' nameserver 1.1.1.1'; }
        # shellcheck disable=SC2034 # 由 show_menu 调用的更新提示函数动态读取。
        UPDATE_AVAILABLE=1
        # shellcheck disable=SC2034 # 由 show_menu 调用的更新提示函数动态读取。
        REMOTE_VERSION=v9.9.9

        show_menu > "$output"
        awk '
            /提示：输入 vpsbox 打开管理面板/ {
                found = 1
                getline
                if ($0 !~ /^ 新版本：v9[.]9[.]9/) exit 1
                getline
                exit($0 != "----------------------------------------")
            }
            END { if (!found) exit 1 }
        ' "$output" || fail "有更新提示时，只能在提示与分隔线之间增加一行通知"
    )
}

test_vpsbox_main_orchestration_and_recovery_short_circuit() {
    local log="$TEST_TMP/vpsbox-main.log"
    local output="$TEST_TMP/vpsbox-main.out"

    : > "$log"
    (
        export PENDING_VPSBOX_UPDATE_BACKUP=""
        export PENDING_VPSBOX_UPDATE_READY_FILE=""
        need_root() { printf '%s\n' root >> "$log"; }
        detect_os() { printf '%s\n' os >> "$log"; }
        acquire_lock() { printf '%s\n' lock >> "$log"; }
        recover_pending_singbox_update() { printf '%s\n' recover-singbox >> "$log"; }
        recover_pending_node_transaction() { printf '%s\n' recover-node >> "$log"; }
        repair_node_uri_cache_on_startup() { printf '%s\n' repair-uri >> "$log"; }
        install_self_command() { printf '%s\n' install-self >> "$log"; }
        check_vpsbox_update_on_start() { printf '%s\n' check-update >> "$log"; }
        auto_update_vpsbox_on_start() { printf '%s\n' auto-update >> "$log"; }
        main_loop() { printf '%s\n' menu >> "$log"; }

        vpsbox_main
    )
    assert_eq $'root\nos\nlock\nrecover-singbox\nrecover-node\nrepair-uri\ninstall-self\ncheck-update\nauto-update\nmenu' \
        "$(cat "$log")" "vpsbox_main 必须按恢复、安装、更新、菜单的顺序完成启动"

    : > "$log"
    (
        export PENDING_VPSBOX_UPDATE_BACKUP=""
        export PENDING_VPSBOX_UPDATE_READY_FILE=""
        need_root() { printf '%s\n' root >> "$log"; }
        detect_os() { printf '%s\n' os >> "$log"; }
        acquire_lock() { printf '%s\n' lock >> "$log"; }
        recover_pending_singbox_update() {
            printf '%s\n' recover-singbox >> "$log"
            return 23
        }
        recover_pending_node_transaction() { printf '%s\n' unexpected-node >> "$log"; }
        repair_node_uri_cache_on_startup() { printf '%s\n' unexpected-repair >> "$log"; }
        install_self_command() { printf '%s\n' unexpected-install >> "$log"; }
        main_loop() { printf '%s\n' unexpected-menu >> "$log"; }

        if vpsbox_main > "$output" 2>&1; then
            fail "sing-box 更新恢复失败时 vpsbox_main 不得继续"
        fi
    )
    assert_eq $'root\nos\nlock\nrecover-singbox' "$(cat "$log")" \
        "sing-box 更新恢复失败后必须立即停止启动"

    : > "$log"
    (
        export PENDING_VPSBOX_UPDATE_BACKUP=""
        export PENDING_VPSBOX_UPDATE_READY_FILE=""
        need_root() { printf '%s\n' root >> "$log"; }
        detect_os() { printf '%s\n' os >> "$log"; }
        acquire_lock() { printf '%s\n' lock >> "$log"; }
        recover_pending_singbox_update() { printf '%s\n' recover-singbox >> "$log"; }
        recover_pending_node_transaction() {
            printf '%s\n' recover-node >> "$log"
            return 24
        }
        repair_node_uri_cache_on_startup() { printf '%s\n' unexpected-repair >> "$log"; }
        install_self_command() { printf '%s\n' unexpected-install >> "$log"; }
        main_loop() { printf '%s\n' unexpected-menu >> "$log"; }

        if vpsbox_main > "$output" 2>&1; then
            fail "节点事务恢复失败时 vpsbox_main 不得继续"
        fi
    )
    assert_eq $'root\nos\nlock\nrecover-singbox\nrecover-node' "$(cat "$log")" \
        "节点事务恢复失败后必须立即停止启动"
}

test_menu_dispatch_and_system_status_wiring() {
    local dispatch_log="$TEST_TMP/main-menu-dispatch.log"
    local handshake_log="$TEST_TMP/main-menu-handshake.log"
    local submenu_log="$TEST_TMP/submenu-dispatch.log"
    local entry choice action
    local -a third_party_cases=(
        '1 show_ip_quality_script_info'
        '2 show_network_quality_script_info'
        '3 show_tcp_quality_script_info'
        '4 show_node_quality_script_info'
        '5 show_reinstall_script_info'
    )

    : > "$dispatch_log"
    (
        show_menu() { :; }
        confirm_pending_vpsbox_update() { :; }
        pause() { :; }
        run_menu_action() { printf '%s\n' "$1" >> "$dispatch_log"; }

        main_loop <<< $'1\n2\n3\n4\n5\n6\n7\n00\n88\n0' >/dev/null
    )
    assert_eq $'node_menu\nsingbox_menu\nsystem_menu\nfirewall_menu\nrun_self_check\nother_scripts_menu\nupdate_vpsbox\nuninstall_all' \
        "$(cat "$dispatch_log")" \
        "主菜单全部功能编号必须分发到对应操作，旧编号 7 不得执行功能"

    : > "$handshake_log"
    (
        show_menu() { printf '%s\n' menu >> "$handshake_log"; }
        confirm_pending_vpsbox_update() { printf '%s\n' ready >> "$handshake_log"; }

        main_loop <<< "0" >/dev/null
    )
    assert_eq $'menu\nready' "$(cat "$handshake_log")" \
        "主菜单首次渲染后、读取选项前必须确认新版启动握手"

    (
        local uninstall_log="$TEST_TMP/uninstall-menu-dispatch.log"
        : > "$uninstall_log"
        show_menu() { :; }
        confirm_pending_vpsbox_update() { :; }
        uninstall_all() {
            printf '%s\n' uninstall >> "$uninstall_log"
            return 23
        }
        pause() { printf '%s\n' pause >> "$uninstall_log"; }

        main_loop <<< $'88\n0' >/dev/null 2>&1
        assert_eq $'uninstall\npause' "$(cat "$uninstall_log")" \
            "卸载失败后必须保留菜单并执行返回暂停"
    )

    : > "$submenu_log"
    (
        clear() { :; }
        singbox_summary_line() { :; }
        node_summary() { :; }
        pause() { :; }
        run_menu_action() { printf '%s\n' "$1" >> "$submenu_log"; }

        node_menu <<< $'1\n2\n3\n4\n5\n0' >/dev/null
    )
    assert_eq $'create_vless_reality_node\ncreate_or_rebuild_node\nview_node_link\ndelete_vless_reality_node\ndelete_node' \
        "$(cat "$submenu_log")" "节点菜单全部编号必须分发到对应操作"

    : > "$submenu_log"
    (
        clear() { :; }
        singbox_summary_line() { :; }
        pause() { :; }
        run_menu_action() { printf '%s\n' "$1" >> "$submenu_log"; }

        singbox_menu <<< $'1\n2\n3\n4\n0' >/dev/null
    )
    assert_eq $'start_service_action\nstop_service_action\nrestart_service_action\nupdate_singbox' \
        "$(cat "$submenu_log")" "sing-box 菜单全部编号必须分发到对应操作"

    : > "$submenu_log"
    (
        clear() { :; }
        detect_os() { OS=debian; }
        bbr_fq_summary_state() { :; }
        ipv4_priority_state() { :; }
        ssh_port_state() { :; }
        ssh_hardening_state() { :; }
        fail2ban_service_state() { :; }
        fail2ban_sshd_state() { :; }
        ntp_sync_state() { :; }
        reboot_required_state() { :; }
        pause() { :; }
        run_menu_action() { printf '%s\n' "$1" >> "$submenu_log"; }
        ssh_port_change_menu() { printf '%s\n' ssh_port_change_menu >> "$submenu_log"; }
        ssh_basic_hardening_menu() { printf '%s\n' ssh_basic_hardening_menu >> "$submenu_log"; }

        system_menu <<< $'1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n0' >/dev/null
    )
    assert_eq $'update_system_packages\ncleanup_system_garbage\nchange_system_hostname\nenable_ntp_sync\nchange_ipv4_dns\nenable_ipv4_priority\nenable_bbr_fq\nssh_port_change_menu\nssh_basic_hardening_menu\nshow_current_ssh_config\ninstall_fail2ban\nlimit_systemd_journal\nrestore_vpsbox_system_changes' \
        "$(cat "$submenu_log")" "系统菜单全部编号必须分发到对应操作"

    for entry in "${third_party_cases[@]}"; do
        read -r choice action <<< "$entry"
        : > "$submenu_log"
        (
            clear() { :; }
            show_ip_quality_script_info() { printf '%s\n' show_ip_quality_script_info >> "$submenu_log"; }
            show_network_quality_script_info() { printf '%s\n' show_network_quality_script_info >> "$submenu_log"; }
            show_tcp_quality_script_info() { printf '%s\n' show_tcp_quality_script_info >> "$submenu_log"; }
            show_node_quality_script_info() { printf '%s\n' show_node_quality_script_info >> "$submenu_log"; }
            show_reinstall_script_info() { printf '%s\n' show_reinstall_script_info >> "$submenu_log"; }

            other_scripts_menu <<< "$choice" >/dev/null
        )
        assert_eq "$action" "$(cat "$submenu_log")" \
            "第三方脚本菜单编号 $choice 必须分发到 $action"
    done

    (
        local system_output="$TEST_TMP/system-menu.out"
        clear() { :; }
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
        assert_file_contains "$system_output" 'BBR.*已开启'
        assert_file_contains "$system_output" 'IPv4.*已启用'
        assert_file_contains "$system_output" 'SSH.*23333.*已配置'
        assert_file_contains "$system_output" 'Fail2ban.*运行中.*已启用'
        assert_file_contains "$system_output" 'NTP.*已同步'
        assert_file_contains "$system_output" '系统重启.*不需要'
    )
}

test_third_party_entries_keep_attribution_and_commands() {
    (
        local menu_output="$TEST_TMP/third-party-menu.out"
        local detail_output="$TEST_TMP/third-party-details.out"
        clear() { :; }

        other_scripts_menu <<< "0" > "$menu_output"
        assert_file_contains "$menu_output" 'IP 质量体检脚本（xykt）'
        assert_file_contains "$menu_output" '网络质量体检脚本（xykt）'
        assert_file_contains "$menu_output" 'TCP 质量检测脚本（ibsgss）'
        assert_file_contains "$menu_output" 'VPS 综合质量测试脚本（LloydAsp）'
        assert_file_contains "$menu_output" '一键 VPS 系统重装脚本（bin456789）'

        {
            show_ip_quality_script_info
            show_network_quality_script_info
            show_tcp_quality_script_info
            show_node_quality_script_info
            show_reinstall_script_info
        } > "$detail_output"
        grep -Fq 'bash <(curl -Ls https://Check.Place) -I' "$detail_output" ||
            fail "IP 质量体检脚本必须保留上游命令"
        grep -Fq 'bash <(curl -Ls https://Check.Place) -N' "$detail_output" ||
            fail "网络质量体检脚本必须保留上游命令"
        grep -Fq 'https://github.com/ibsgss/TcpQuality' "$detail_output" ||
            fail "TCP 质量检测脚本必须保留上游项目地址"
        grep -Fq 'https://github.com/LloydAsp/NodeQuality' "$detail_output" ||
            fail "VPS 综合质量测试脚本必须保留上游项目地址"
        grep -Fq 'https://github.com/bin456789/reinstall' "$detail_output" ||
            fail "系统重装脚本必须保留上游项目地址"
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
        repair_node_uri_cache_best_effort() { return 0; }
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
        repair_node_uri_cache_best_effort() { printf '%s\n' repair >> "$log"; }
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
        assert_file_contains "$log" '^repair$'
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
        repair_node_uri_cache_best_effort() { printf '%s\n' repair >> "$log"; }
        install_singbox_if_missing() { printf '%s\n' install >> "$log"; }
        setup_service() { printf '%s\n' setup >> "$log"; }
        restart_singbox_cleanly() { printf '%s\n' restart >> "$log"; }
        verify_current_node_runtime() { return 0; }

        restart_service_action >/dev/null
        assert_file_contains "$log" '^repair$'
        assert_file_contains "$log" '^install$'
        assert_file_contains "$log" '^setup$'
        assert_file_contains "$log" '^restart$'
    )
}

test_stop_service_action_reports_final_state() {
    (
        local log="$TEST_TMP/stop-service-normal.log"
        local output="$TEST_TMP/stop-service-normal.out"
        : > "$log"
        service_stop() { printf '%s\n' service-stop >> "$log"; }
        stop_singbox_config_processes() { printf '%s\n' process-stop >> "$log"; }
        service_manager_is_active() { return 1; }
        singbox_config_pids() { :; }

        stop_service_action > "$output" 2>&1
        assert_eq $'service-stop\nprocess-stop' "$(cat "$log")" \
            "正常停止必须同时处理服务管理器与配置残留进程"
        assert_file_contains "$output" 'sing-box 服务已停止'
    )

    (
        local output="$TEST_TMP/stop-service-residual.out"
        service_stop() { return 0; }
        stop_singbox_config_processes() { return 0; }
        service_manager_is_active() { return 1; }
        singbox_config_pids() { printf '%s\n' 4242; }

        if stop_service_action > "$output" 2>&1; then
            fail "配置残留进程仍在时停止操作不得成功"
        fi
        assert_file_contains "$output" '残留进程仍在运行'
        assert_file_not_contains "$output" '服务已停止。'
    )

    (
        local log="$TEST_TMP/stop-service-command-failure.log"
        local output="$TEST_TMP/stop-service-command-failure.out"
        : > "$log"
        service_stop() {
            printf '%s\n' service-stop-failed >> "$log"
            return 23
        }
        stop_singbox_config_processes() { printf '%s\n' process-stop >> "$log"; }
        service_manager_is_active() { return 1; }
        singbox_config_pids() { :; }

        if stop_service_action > "$output" 2>&1; then
            fail "服务命令失败时即使最终已停止也必须返回失败"
        fi
        assert_eq $'service-stop-failed\nprocess-stop' "$(cat "$log")"
        assert_file_contains "$output" 'sing-box 已停止，但服务管理命令执行失败'
        assert_file_not_contains "$output" 'sing-box 服务已停止。'
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

test_install_metadata_parser_rejects_malformed_or_insecure_records() {
    [ "$(id -u)" = "0" ] ||
        { skip "需要 root 文件属主语义"; return "$?"; }
    (
        local root="$TEST_TMP/install-metadata-parser"
        local values
        VPSBOX_STATE_DIR="$root/state"
        INSTALL_METADATA_FILE="$VPSBOX_STATE_DIR/install.env"
        mkdir -p "$VPSBOX_STATE_DIR"
        chmod 700 "$VPSBOX_STATE_DIR"

        printf '%s\n' \
            'FIRST_INSTALLED_VERSION=v1.2.3' \
            'FIRST_INSTALLED_AT=2026-07-29T01:02:03Z' \
            > "$INSTALL_METADATA_FILE"
        chmod 600 "$INSTALL_METADATA_FILE"
        values="$(install_metadata_read)" ||
            fail "合法的首次安装记录必须可读取"
        assert_eq $'v1.2.3\n2026-07-29T01:02:03Z' "$values"

        chmod 755 "$VPSBOX_STATE_DIR"
        if install_metadata_read >/dev/null 2>&1; then
            fail "首次安装记录目录权限不安全时必须拒绝读取"
        fi
        chmod 700 "$VPSBOX_STATE_DIR"

        chown 65534:65534 "$VPSBOX_STATE_DIR"
        if install_metadata_read >/dev/null 2>&1; then
            fail "首次安装记录目录不是 root 所有时必须拒绝读取"
        fi
        chown root:root "$VPSBOX_STATE_DIR"

        chown 65534:65534 "$INSTALL_METADATA_FILE"
        if install_metadata_read >/dev/null 2>&1; then
            fail "首次安装记录文件不是 root 所有时必须拒绝读取"
        fi
        chown root:root "$INSTALL_METADATA_FILE"

        printf '%s\n' \
            'FIRST_INSTALLED_VERSION=v1.2.3' \
            'FIRST_INSTALLED_AT=2026-07-29T01:02:03Z' \
            'EXTRA_FIELD=unexpected' \
            > "$INSTALL_METADATA_FILE"
        chmod 600 "$INSTALL_METADATA_FILE"
        if install_metadata_read >/dev/null 2>&1; then
            fail "首次安装记录不得接受白名单外字段"
        fi

        printf '%s\n' \
            'FIRST_INSTALLED_VERSION=v1.2.3' \
            'FIRST_INSTALLED_VERSION=v9.9.9' \
            'FIRST_INSTALLED_AT=2026-07-29T01:02:03Z' \
            > "$INSTALL_METADATA_FILE"
        chmod 600 "$INSTALL_METADATA_FILE"
        if install_metadata_read >/dev/null 2>&1; then
            fail "首次安装记录不得接受重复字段"
        fi

        printf '%s\n' \
            'FIRST_INSTALLED_VERSION=1.2.3' \
            'FIRST_INSTALLED_AT=2026-07-29 01:02:03' \
            > "$INSTALL_METADATA_FILE"
        chmod 600 "$INSTALL_METADATA_FILE"
        if install_metadata_read >/dev/null 2>&1; then
            fail "首次安装记录不得接受非规范版本或时间"
        fi

        printf '%s\n' \
            'FIRST_INSTALLED_VERSION=unknown' \
            'FIRST_INSTALLED_AT=2026-07-29T01:02:03Z' \
            > "$INSTALL_METADATA_FILE"
        chmod 600 "$INSTALL_METADATA_FILE"
        if install_metadata_read >/dev/null 2>&1; then
            fail "首次安装记录不得混用 unknown 与精确值"
        fi

        printf '%s\n' \
            'FIRST_INSTALLED_VERSION=unknown' \
            'FIRST_INSTALLED_AT=unknown' \
            > "$INSTALL_METADATA_FILE"
        chmod 666 "$INSTALL_METADATA_FILE"
        if install_metadata_read >/dev/null 2>&1; then
            fail "首次安装记录权限不安全时必须拒绝读取"
        fi

        require_real_symlink file || return "$?"
        rm -f "$INSTALL_METADATA_FILE"
        printf '%s\n' \
            'FIRST_INSTALLED_VERSION=unknown' \
            'FIRST_INSTALLED_AT=unknown' \
            > "$root/linked-install.env"
        chmod 600 "$root/linked-install.env"
        ln -s "$root/linked-install.env" "$INSTALL_METADATA_FILE"
        if install_metadata_read >/dev/null 2>&1; then
            fail "首次安装记录为符号链接时必须拒绝读取"
        fi

        rm -f "$INSTALL_METADATA_FILE"
        printf '%s\n' \
            'FIRST_INSTALLED_VERSION=unknown' \
            'FIRST_INSTALLED_AT=unknown' \
            > "$VPSBOX_STATE_DIR/install.env"
        chmod 600 "$VPSBOX_STATE_DIR/install.env"
        mv "$VPSBOX_STATE_DIR" "$root/real-state"
        ln -s "$root/real-state" "$VPSBOX_STATE_DIR"
        if install_metadata_read >/dev/null 2>&1; then
            fail "首次安装记录目录为符号链接时必须拒绝读取"
        fi
    )
}

test_install_self_records_fresh_or_unknown_metadata_once() {
    [ "$(id -u)" = "0" ] ||
        { skip "需要 root 文件属主语义"; return "$?"; }
    (
        local root="$TEST_TMP/install-metadata-fresh"
        local source="$root/source.sh"
        local alias_log="$root/alias.log"
        local values
        mkdir -p "$root"
        printf '%s\n' \
            '#!/usr/bin/env bash' \
            'VPSBOX_VERSION="v9.8.7"' \
            > "$source"
        CMD_PATH="$root/bin/vpsbox"
        VPSBOX_STATE_DIR="$root/state"
        INSTALL_METADATA_FILE="$VPSBOX_STATE_DIR/install.env"
        install_command_alias() { printf '%s\n' alias >> "$alias_log"; }

        install_self_command "$source" ||
            fail "全新安装完成命令文件与快捷入口后应成功"
        assert_eq alias "$(cat "$alias_log")" "首次安装必须先完成快捷入口"
        values="$(install_metadata_read)" ||
            fail "全新安装必须生成可验证的首次安装记录"
        assert_file_contains "$INSTALL_METADATA_FILE" '^FIRST_INSTALLED_VERSION=v9[.]8[.]7$'
        assert_file_contains "$INSTALL_METADATA_FILE" \
            '^FIRST_INSTALLED_AT=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
        assert_eq '0:0 700' \
            "$(stat -c '%u:%g %a' "$VPSBOX_STATE_DIR")" \
            "首次安装记录目录必须为 root:root 700"
        assert_eq '0:0 600' \
            "$(stat -c '%u:%g %a' "$INSTALL_METADATA_FILE")" \
            "首次安装记录必须为 root:root 600"
        [ "${values%%$'\n'*}" = "v9.8.7" ] ||
            fail "首次安装版本必须来自最终安装的脚本"
    )
    (
        local root="$TEST_TMP/install-metadata-existing"
        local source="$root/source.sh"
        mkdir -p "$root/bin"
        printf '%s\n' \
            '#!/usr/bin/env bash' \
            'VPSBOX_VERSION="v1.0.1"' \
            > "$root/bin/vpsbox"
        printf '%s\n' \
            '#!/usr/bin/env bash' \
            'VPSBOX_VERSION="v9.8.7"' \
            > "$source"
        CMD_PATH="$root/bin/vpsbox"
        VPSBOX_STATE_DIR="$root/state"
        INSTALL_METADATA_FILE="$VPSBOX_STATE_DIR/install.env"
        install_command_alias() { :; }

        install_self_command "$source" ||
            fail "已有安装缺少历史记录时仍应完成更新"
        assert_eq $'unknown\nunknown' "$(install_metadata_read)" \
            "已有安装不得从当前版本、旧文件或时间戳推断首次安装信息"
    )
}

test_install_metadata_is_preserved_and_failures_do_not_block_install() {
    [ "$(id -u)" = "0" ] ||
        { skip "需要 root 文件属主语义"; return "$?"; }
    (
        local root="$TEST_TMP/install-metadata-preserve"
        local source="$root/source.sh"
        local inode_before inode_after
        mkdir -p "$root/bin" "$root/state"
        chmod 700 "$root/state"
        printf '%s\n' \
            '#!/usr/bin/env bash' \
            'VPSBOX_VERSION="v1.0.1"' \
            > "$root/bin/vpsbox"
        printf '%s\n' \
            '#!/usr/bin/env bash' \
            'VPSBOX_VERSION="v9.8.7"' \
            > "$source"
        printf '%s\n' \
            'FIRST_INSTALLED_VERSION=v1.0.1' \
            'FIRST_INSTALLED_AT=2026-07-01T00:00:00Z' \
            > "$root/state/install.env"
        chmod 600 "$root/state/install.env"
        CMD_PATH="$root/bin/vpsbox"
        VPSBOX_STATE_DIR="$root/state"
        INSTALL_METADATA_FILE="$VPSBOX_STATE_DIR/install.env"
        install_command_alias() { :; }
        inode_before="$(stat -c '%i' "$INSTALL_METADATA_FILE")"

        install_self_command "$source" ||
            fail "已有有效首次安装记录时更新仍应成功"
        inode_after="$(stat -c '%i' "$INSTALL_METADATA_FILE")"
        assert_eq "$inode_before" "$inode_after" \
            "已有有效首次安装记录不得被原子替换或覆盖"
        assert_eq $'v1.0.1\n2026-07-01T00:00:00Z' "$(install_metadata_read)"
    )
    (
        local root="$TEST_TMP/install-metadata-invalid"
        local source="$root/source.sh"
        local output="$root/install.out"
        local content_before
        mkdir -p "$root/bin" "$root/state"
        chmod 700 "$root/state"
        printf '%s\n' \
            '#!/usr/bin/env bash' \
            'VPSBOX_VERSION="v1.0.1"' \
            > "$root/bin/vpsbox"
        printf '%s\n' \
            '#!/usr/bin/env bash' \
            'VPSBOX_VERSION="v9.8.7"' \
            > "$source"
        printf '%s\n' 'MALFORMED=keep-me' > "$root/state/install.env"
        chmod 600 "$root/state/install.env"
        content_before="$(cat "$root/state/install.env")"
        CMD_PATH="$root/bin/vpsbox"
        VPSBOX_STATE_DIR="$root/state"
        INSTALL_METADATA_FILE="$VPSBOX_STATE_DIR/install.env"
        install_command_alias() { :; }

        install_self_command "$source" > "$output" 2>&1 ||
            fail "异常首次安装记录不得阻断脚本更新"
        assert_eq "$content_before" "$(cat "$INSTALL_METADATA_FILE")" \
            "异常的已有首次安装记录必须保留，不得擅自覆盖"
        assert_file_contains "$output" '首次安装记录.*异常'
    )
    (
        local root="$TEST_TMP/install-metadata-symlink"
        local source="$root/source.sh"
        local target="$root/linked-install.env"
        local output="$root/install.out"
        local content_before
        mkdir -p "$root/bin" "$root/state"
        chmod 700 "$root/state"
        printf '%s\n' \
            '#!/usr/bin/env bash' \
            'VPSBOX_VERSION="v1.0.1"' \
            > "$root/bin/vpsbox"
        printf '%s\n' \
            '#!/usr/bin/env bash' \
            'VPSBOX_VERSION="v9.8.7"' \
            > "$source"
        printf '%s\n' 'MALFORMED=keep-linked' > "$target"
        chmod 600 "$target"
        ln -s "$target" "$root/state/install.env"
        content_before="$(cat "$target")"
        CMD_PATH="$root/bin/vpsbox"
        VPSBOX_STATE_DIR="$root/state"
        INSTALL_METADATA_FILE="$VPSBOX_STATE_DIR/install.env"
        install_command_alias() { :; }

        install_self_command "$source" > "$output" 2>&1 ||
            fail "已有符号链接记录不得阻断脚本更新"
        [ -L "$INSTALL_METADATA_FILE" ] ||
            fail "已有首次安装记录符号链接必须原样保留"
        assert_eq "$content_before" "$(cat "$target")" \
            "已有首次安装记录符号链接的目标内容不得被覆盖"
        assert_file_contains "$output" '首次安装记录.*异常'
    )
    (
        local root="$TEST_TMP/install-metadata-alias-failure"
        local source="$root/source.sh"
        local alias_should_fail=1
        mkdir -p "$root"
        printf '%s\n' \
            '#!/usr/bin/env bash' \
            'VPSBOX_VERSION="v9.8.7"' \
            > "$source"
        CMD_PATH="$root/bin/vpsbox"
        VPSBOX_STATE_DIR="$root/state"
        INSTALL_METADATA_FILE="$VPSBOX_STATE_DIR/install.env"
        install_command_alias() { [ "$alias_should_fail" -eq 0 ]; }

        if install_self_command "$source" > "$root/install.out" 2>&1; then
            fail "快捷入口失败时安装必须返回非零"
        fi
        [ ! -e "$INSTALL_METADATA_FILE" ] && [ ! -L "$INSTALL_METADATA_FILE" ] ||
            fail "快捷入口成功前不得写入首次安装记录"
        [ ! -e "$CMD_PATH" ] && [ ! -L "$CMD_PATH" ] ||
            fail "全新安装的快捷入口失败后不得残留管理命令"

        alias_should_fail=0
        install_self_command "$source" || fail "清理未完成安装后必须允许成功重试"
        assert_eq v9.8.7 "$(install_metadata_read | sed -n '1p')" \
            "首次成功安装必须记录实际版本，不得误记为历史未知"
    )
}

test_uninstall_preserves_install_metadata() {
    (
        local root="$TEST_TMP/install-metadata-uninstall"
        local removed_log="$root/removed.log"
        mkdir -p "$root/bin" "$root/state"
        printf '%s\n' command > "$root/bin/vpsbox"
        printf '%s\n' \
            'FIRST_INSTALLED_VERSION=v1.0.44' \
            'FIRST_INSTALLED_AT=2026-07-29T01:02:03Z' \
            > "$root/state/install.env"
        CMD_PATH="$root/bin/vpsbox"
        CMD_ALIAS_PATH="$root/bin/vpsbox-alias"
        VPSBOX_STATE_DIR="$root/state"
        INSTALL_METADATA_FILE="$VPSBOX_STATE_DIR/install.env"
        firewall_artifacts_present() { return 1; }
        singbox_artifacts_present() { return 1; }
        offer_restore_recorded_changes_before_uninstall() { :; }
        rm() {
            local arg
            for arg in "$@"; do
                case "$arg" in
                    -*) ;;
                    "$CMD_PATH")
                        printf '%s\n' "$arg" >> "$removed_log"
                        command rm -f -- "$arg"
                        ;;
                    "$CMD_ALIAS_PATH")
                        printf '%s\n' "$arg" >> "$removed_log"
                        command rm -f -- "$arg"
                        ;;
                    *)
                        fail "卸载测试出现未预期删除目标：$arg"
                        return 1
                        ;;
                esac
            done
        }
        exit() { return 0; }

        uninstall_all <<< 'YES' > "$root/uninstall.out" 2>&1 ||
            fail "只卸载 vpsbox 管理命令时应成功"
        [ -f "$INSTALL_METADATA_FILE" ] ||
            fail "卸载 vpsbox 后必须保留首次安装记录"
        assert_eq "$CMD_PATH" "$(
            grep -Fx "$CMD_PATH" "$removed_log"
        )"
    )
}

test_runtime_cleanup_traps_dispatch_recovery_handlers() {
    local runner="$TEST_TMP/runtime-cleanup-runner.sh"
    local entry mode expected_status status event_log case_dir
    local -a cases=(
        'EXIT 23'
        'INT 130'
        'TERM 143'
    )

    cat > "$runner" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$REPO_DIR/vpsbox.sh"

NODE_TRANSACTION_DIR="$NODE_DIR"
ACTIVE_NODE_BACKUP="$NODE_TRANSACTION_DIR"
ACTIVE_FIREWALL_ROLLBACK_DIR="$FW_DIR"
mkdir -p "$NODE_TRANSACTION_DIR" "$FW_DIR"

cleanup_active_bounded_command() { :; }
rollback_active_singbox_update() { :; }
rollback_active_node_transaction() { printf '%s\n' node >> "$EVENT_LOG"; }
ssh_firewall_transition_reconcile() { :; }
firewall_abort_port_transition() { :; }
firewall_rollback_dir_valid() { return 0; }
firewall_restore_snapshot_now() { printf 'firewall:%s\n' "$2" >> "$EVENT_LOG"; }
cleanup_active_fail2ban_test() { :; }
cleanup_unapplied_ssh_tracking() { :; }
cleanup_vpsbox_lock() { printf '%s\n' lock >> "$EVENT_LOG"; }
rollback_pending_vpsbox_update() { printf '%s\n' update >> "$EVENT_LOG"; }

install_lock_cleanup_traps
case "$1" in
    EXIT) exit 23 ;;
    INT) kill -s INT "$$" ;;
    TERM) kill -s TERM "$$" ;;
    *) exit 99 ;;
esac
EOF
    chmod 755 "$runner"

    for entry in "${cases[@]}"; do
        read -r mode expected_status <<< "$entry"
        case_dir="$TEST_TMP/runtime-cleanup-$mode"
        event_log="$case_dir/events.log"
        mkdir -p "$case_dir/node" "$case_dir/firewall"
        : > "$event_log"

        set +e
        REPO_DIR="$REPO_DIR" EVENT_LOG="$event_log" \
            NODE_DIR="$case_dir/node" FW_DIR="$case_dir/firewall" \
            bash "$runner" "$mode" > "$case_dir/output.log" 2>&1
        status=$?
        set -e

        assert_eq "$expected_status" "$status" "$mode 必须保留原始退出状态"
        assert_eq $'node\nfirewall:0\nlock\nupdate' "$(cat "$event_log")" \
            "$mode 必须通过真实 cleanup coordinator 调用节点、防火墙和更新恢复"
    done
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
        node_dependencies_available() { return 1; }
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

test_singbox_package_restore_failure_accepts_verified_binary_fallback() {
    (
        local event_log="$TEST_TMP/singbox-package-fallback.events"
        local output="$TEST_TMP/singbox-package-fallback.out"
        : > "$event_log"
        service_stop() { printf '%s\n' stop >> "$event_log"; }
        service_manager_is_active() { return 1; }
        stop_singbox_config_processes() { return 0; }
        install_singbox_package_file() {
            printf '%s\n' package-failed >> "$event_log"
            return 23
        }
        restore_singbox_binary_atomically() {
            printf '%s\n' binary-restored >> "$event_log"
        }
        node_exists() { return 1; }
        restore_singbox_service_state() {
            printf 'service-restored:%s:%s\n' "$1" "$2" >> "$event_log"
        }

        restore_singbox_update_backup \
            /usr/bin/sing-box "$TEST_TMP/old-binary" "$TEST_TMP/update-backup" \
            1 1 "$TEST_TMP/old.deb" 1.13.13 >"$output" 2>&1 ||
            fail "软件包恢复失败但可信二进制和服务状态已恢复时，不应继续阻塞启动"
        assert_eq $'stop\npackage-failed\nbinary-restored\nservice-restored:1:1' \
            "$(cat "$event_log")"
        assert_file_contains "$output" '软件包管理记录可能不一致'
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
    require_linux_proc || return "$?"

    (
        # shellcheck disable=SC2034 # 被测的 service_start 动态读取。
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

        : > "$TEST_TMP/openrc-ssh-restart.log"
        rc-service() {
            [ ! -e "/proc/$BASHPID/fd/200" ] ||
                fail "OpenRC SSH 重启命令继承了菜单锁 FD 200"
            printf '%s\n' "$*" > "$TEST_TMP/openrc-ssh-restart.log"
        }
        restart_ssh_service
        assert_file_contains "$TEST_TMP/openrc-ssh-restart.log" '^sshd restart$'
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

test_existing_singbox_still_repairs_node_dependencies() {
    (
        local dependencies_ready=0
        local event_log="$TEST_TMP/node-dependencies.log"
        : > "$event_log"

        node_dependencies_available() { [ "$dependencies_ready" -eq 1 ]; }
        install_deps() {
            printf '%s\n' deps >> "$event_log"
            dependencies_ready=1
        }
        singbox_installed() { return 0; }
        mark_node_transaction_mutated() {
            printf '%s\n' mutated >> "$event_log"
        }

        install_singbox_for_node_transaction
        assert_file_contains "$event_log" '^deps$' \
            "已有 sing-box 时也必须补齐节点依赖"
        assert_file_not_contains "$event_log" '^mutated$' \
            "仅补齐依赖时不得把节点文件事务标记为已修改"
    )
}

test_node_dependency_repair_requires_complete_result() {
    (
        local event_log="$TEST_TMP/node-dependencies-incomplete.log"
        : > "$event_log"

        node_dependencies_available() { return 1; }
        install_deps() { printf '%s\n' deps >> "$event_log"; }

        if ensure_node_dependencies >"$TEST_TMP/node-dependencies-incomplete.out" 2>&1; then
            fail "依赖安装后仍不完整时不得继续节点操作"
        fi
        assert_file_contains "$event_log" '^deps$'
        assert_file_contains "$TEST_TMP/node-dependencies-incomplete.out" \
            'vpsbox 节点管理依赖安装后仍不完整'
    )
}

test_node_ca_trust_detection() {
    (
        local bundle="$TEST_TMP/test-ca-bundle.crt"

        if node_ca_trust_available "$bundle"; then
            fail "不存在的 CA 文件不得判定为可用"
        fi
        : > "$bundle"
        if node_ca_trust_available "$bundle"; then
            fail "空 CA 文件不得判定为可用"
        fi
        printf '%s\n' certificate > "$bundle"
        node_ca_trust_available "$bundle" || fail "非空 CA 文件应判定为可用"
    )
}

test_node_dependency_predicate_combines_commands_and_ca_trust() {
    (
        local commands_ok=1 ca_ok=1
        local log="$TEST_TMP/node-dependency-predicate.log"
        : > "$log"
        node_commands_available() {
            printf 'commands:%s\n' "$*" >> "$log"
            [ "$commands_ok" -eq 1 ]
        }
        node_ca_trust_available() {
            printf 'ca:%s\n' "$*" >> "$log"
            [ "$ca_ok" -eq 1 ]
        }

        production_node_dependencies_available ||
            fail "命令与 CA 信任均可用时生产依赖谓词应成功"
        assert_file_contains "$log" '^commands:curl openssl jq ss sha256sum base64$' \
            "生产依赖谓词必须检查完整命令集合"
        assert_file_contains "$log" '^ca:/etc/ssl/certs/ca-certificates[.]crt /etc/pki/tls/certs/ca-bundle[.]crt /etc/ssl/ca-bundle[.]pem /etc/pki/ca-trust/extracted/pem/tls-ca-bundle[.]pem$' \
            "生产依赖谓词必须检查受支持的 CA 证书路径"

        : > "$log"
        commands_ok=0
        if production_node_dependencies_available; then
            fail "命令集合不完整时生产依赖谓词不得成功"
        fi
        assert_file_contains "$log" '^commands:'
        assert_file_not_contains "$log" '^ca:' \
            "命令集合已失败时不应误报已检查 CA 信任"

        : > "$log"
        commands_ok=1
        ca_ok=0
        if production_node_dependencies_available; then
            fail "CA 信任不可用时生产依赖谓词不得成功"
        fi
        assert_file_contains "$log" '^commands:'
        assert_file_contains "$log" '^ca:'
    )
}

test_first_singbox_install_prepares_dependencies_once() {
    (
        local dependencies_ready=0 installed=0 dependency_runs=0

        node_dependencies_available() { [ "$dependencies_ready" -eq 1 ]; }
        install_deps() {
            dependency_runs=$((dependency_runs + 1))
            dependencies_ready=1
        }
        singbox_installed() { [ "$installed" -eq 1 ]; }
        mark_node_transaction_mutated() { return 0; }
        detect_os() { return 0; }
        run_singbox_installer() { installed=1; }
        singbox_version() { printf '%s\n' 1.13.14; }

        install_singbox_for_node_transaction
        assert_eq 1 "$dependency_runs" \
            "首次安装 sing-box 不得重复执行整套依赖安装"
    )
}

test_node_dependency_install_is_automatic() {
    local creator

    for creator in create_or_rebuild_node create_vless_reality_node; do
        (
            local dependencies_ready=0
            local event_log="$TEST_TMP/$creator-dependency-auto.log"
            : > "$event_log"

            node_dependencies_available() { [ "$dependencies_ready" -eq 1 ]; }
            confirm_default_yes() { printf '%s\n' confirm >> "$event_log"; return 1; }
            install_deps() {
                printf '%s\n' install >> "$event_log"
                dependencies_ready=1
            }
            require_valid_node_state_if_present() {
                printf '%s\n' validation >> "$event_log"
                return 23
            }
            begin_node_transaction() { printf '%s\n' transaction >> "$event_log"; }

            if "$creator" >"$TEST_TMP/$creator-dependency-auto.out" 2>&1; then
                fail "$creator 应在后续节点校验失败时停止"
            fi
            assert_file_contains "$event_log" '^install$' \
                "$creator 缺少依赖时应自动调用安装流程"
            assert_file_contains "$event_log" '^validation$' \
                "$creator 依赖补齐后应继续节点校验"
            assert_file_not_contains "$event_log" '^confirm$' \
                "$creator 自动补齐依赖前不得询问用户"
            assert_file_not_contains "$event_log" '^transaction$' \
                "$creator 后续校验失败时不得开始节点事务"
        )
    done
}

test_read_only_node_actions_do_not_install_dependencies() {
    local action

    for action in view_node_link delete_node; do
        (
            local event_log="$TEST_TMP/$action-dependency-order.log"
            : > "$event_log"

            node_core_artifacts_present() { return 0; }
            missing_node_commands() { printf '%s\n' jq; }
            install_deps() { printf '%s\n' install >> "$event_log"; }
            require_valid_node_state_if_present() {
                printf '%s\n' validation >> "$event_log"
            }

            if "$action" >"$TEST_TMP/$action-dependency-order.out" 2>&1; then
                fail "$action 缺少校验依赖时不得继续"
            fi
            assert_empty_file "$event_log" \
                "$action 不得安装依赖，且依赖缺失后不得进入节点校验"
            assert_file_contains "$TEST_TMP/$action-dependency-order.out" \
                '缺少必要命令：jq'
        )
    done
}

test_singbox_update_prepares_dependencies_before_validation() {
    (
        local event_log="$TEST_TMP/update_singbox-dependency-order.log"
        : > "$event_log"

        node_core_artifacts_present() { return 0; }
        singbox_installed() { return 0; }
        singbox_version() { printf '%s\n' 1.13.13; }
        singbox_binary_is_package_managed() { return 0; }
        ensure_node_dependencies() {
            printf '%s\n' dependencies >> "$event_log"
            return 23
        }
        require_valid_node_state_if_present() {
            printf '%s\n' validation >> "$event_log"
        }

        if update_singbox >"$TEST_TMP/update_singbox-dependency-order.out" 2>&1; then
            fail "update_singbox 在依赖准备失败时不得继续"
        fi
        assert_eq dependencies "$(cat "$event_log")" \
            "update_singbox 必须先准备依赖，且失败后不得进入节点校验"
    )
}

test_runtime_dependency_install_is_automatic() {
    (
        local dependencies_ready=0 dependency_runs=0
        local event_log="$TEST_TMP/runtime-dependency-auto.log"
        : > "$event_log"
        missing_node_commands() {
            [ "$dependencies_ready" -eq 1 ] && printf '\n' || printf '%s\n' jq
        }
        confirm_default_yes() {
            printf '%s\n' confirm >> "$event_log"
            return 1
        }
        install_deps() {
            dependency_runs=$((dependency_runs + 1))
            dependencies_ready=1
        }

        ensure_node_runtime_commands
        assert_eq 1 "$dependency_runs" "运行依赖只能自动安装一次"
        assert_file_not_contains "$event_log" '^confirm$' "自动补齐运行依赖前不得询问用户"
    )
    (
        missing_node_commands() { printf '%s\n' jq; }
        install_deps() { return 0; }

        if ensure_node_runtime_commands >"$TEST_TMP/runtime-dependency-incomplete.out" 2>&1; then
            fail "运行依赖安装后仍不完整时不得继续"
        fi
        assert_file_contains "$TEST_TMP/runtime-dependency-incomplete.out" \
            '节点服务管理 缺少必要命令：jq'
    )
}

test_dangling_node_symlink_is_not_treated_as_no_node() {
    local action

    require_real_symlink dangling-directory || return "$?"

    for action in start_service_action restart_service_action; do
        (
            local root="$TEST_TMP/$action-dangling-node"
            CONFIG_DIR="$root/config"
            URI_FILE="$CONFIG_DIR/vpsbox-uri.txt"
            NODE_CONFIG_DIR="$CONFIG_DIR/vpsbox.d"
            SS_STATE_FILE="$CONFIG_DIR/vpsbox-ss.env"
            VLESS_STATE_FILE="$CONFIG_DIR/vpsbox-vless.env"
            SS_URI_FILE="$CONFIG_DIR/vpsbox-ss-uri.txt"
            VLESS_URI_FILE="$CONFIG_DIR/vpsbox-vless-uri.txt"
            mkdir -p "$CONFIG_DIR"
            ln -s /definitely/missing-vpsbox-node-dir "$NODE_CONFIG_DIR"

            node_artifacts_present || fail "$action 必须识别悬空的节点符号链接"
            if "$action" >"$TEST_TMP/$action-dangling-node.out" 2>&1; then
                fail "$action 不得把悬空节点符号链接误报为无节点"
            fi
            assert_file_contains "$TEST_TMP/$action-dangling-node.out" \
                '检测到节点路径为符号链接'
        )
    done
}

main() {
    local name test status passed=0 skipped=0
    local -a required=(
        acquire_lock
        install_lock_cleanup_traps
        prompt_node_host
        create_or_rebuild_node
        cleanup_vpsbox_runtime
        update_singbox
        install_self_command
        install_metadata_read
        stop_service_action
        ssh_port_summary_line
        change_applied_recorded_readonly
        node_core_artifacts_present
        node_uri_cache_status
        repair_node_uri_cache
        repair_node_uri_cache_best_effort
        repair_node_uri_cache_on_startup
        run_self_check
        show_menu
        main_loop
        node_menu
        singbox_menu
        system_menu
        other_scripts_menu
        vpsbox_main
        production_node_dependencies_available
    )
    local -a tests=(
        test_address_fallback_validation
        test_blank_node_host_uses_detected_public_ipv4
        test_delayed_node_host_paste_is_adopted
        test_node_host_detection_failure_falls_back_to_manual_input
        test_node_host_rejected_detection_falls_back_to_manual_input
        test_node_host_warns_for_possible_nat
        test_uri_write_preserves_existing_on_failure
        test_node_eof_has_no_mutation
        test_default_yes_confirmation_behavior
        test_interactive_confirm_is_function_local
        test_detect_os_preserves_node_state_globals
        test_sensitive_interaction_eof_cancels_before_mutation
        test_ssh_access_controls_are_checked_before_mutation
        test_ss_password_generation_failure_rolls_back_before_mutation
        test_first_singbox_install_marks_transaction_before_install
        test_atomic_root_publish_preserves_existing_target
        test_node_publish_keeps_temporary_file_outside_config_set
        test_singbox_service_publish_preserves_existing_target
        test_setup_service_rejects_missing_binary_before_mutation
        test_singbox_package_removal_failure_preserves_files
        test_firewall_sync_restore_failure_preserves_backup
        test_runtime_dir_permission_failure_is_fatal
        test_lockdir_first_acquisition_uses_reclaim_guard
        test_lock_acquisition_installs_runtime_cleanup_traps
        test_reality_checks_require_bounded_dns_and_openssl
        test_reality_candidate_is_checked_only_once
        test_view_node_link_is_read_only
        test_uri_cache_repair_failure_is_warning_only
        test_node_state_writes_are_atomic
        test_service_running_requires_exact_config_process
        test_singbox_summary_line_states
        test_ssh_port_summary_line_states
        test_node_summary_orders_only_existing_protocols
        test_bbr_fq_summary_preserves_partial_state
        test_self_check_classifies_and_summarizes_results
        test_main_menu_update_notice_spacing_and_entries
        test_vpsbox_main_orchestration_and_recovery_short_circuit
        test_menu_dispatch_and_system_status_wiring
        test_third_party_entries_keep_attribution_and_commands
        test_service_restore_checks_final_state
        test_start_service_action_healthy_is_noop
        test_start_service_action_uses_light_start
        test_restart_service_action_keeps_full_restart
        test_stop_service_action_reports_final_state
        test_test_mode_blocks_real_service_mutation
        test_protocol_specific_listener_checks
        test_install_self_reports_download_failure
        test_install_metadata_parser_rejects_malformed_or_insecure_records
        test_install_self_records_fresh_or_unknown_metadata_once
        test_install_metadata_is_preserved_and_failures_do_not_block_install
        test_uninstall_preserves_install_metadata
        test_runtime_cleanup_traps_dispatch_recovery_handlers
        test_interrupted_singbox_update_rolls_back
        test_lockdir_metadata_window_is_waited
        test_same_second_timestamp_is_not_after
        test_singbox_dependency_failure_does_not_touch_service
        test_failed_singbox_update_restores_binary_and_state
        test_singbox_package_restore_failure_accepts_verified_binary_fallback
        test_port_detection_failures_are_not_treated_as_free
        test_lockdir_reclaim_guard_serializes_contenders
        test_openrc_service_does_not_inherit_menu_lock_fd
        test_singbox_pending_update_recovers_on_next_start
        test_singbox_atomic_restore_preserves_current_on_replace_failure
        test_singbox_recovery_rejects_corrupted_backup
        test_external_singbox_update_is_rejected_before_mutation
        test_existing_singbox_still_repairs_node_dependencies
        test_node_dependency_repair_requires_complete_result
        test_node_ca_trust_detection
        test_node_dependency_predicate_combines_commands_and_ca_trust
        test_first_singbox_install_prepares_dependencies_once
        test_node_dependency_install_is_automatic
        test_read_only_node_actions_do_not_install_dependencies
        test_singbox_update_prepares_dependencies_before_validation
        test_runtime_dependency_install_is_automatic
        test_dangling_node_symlink_is_not_treated_as_no_node
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
    printf '%s core regression tests passed, %s skipped, %s registered.\n' \
        "$passed" "$skipped" "${#tests[@]}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
