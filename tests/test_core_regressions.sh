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
        mkdir -p "$CONFIG_DIR"
        printf '%s\n' keep > "$URI_FILE"
        secure_config_dir() { return 0; }
        generate_link() { return 42; }

        if write_uri_file; then
            fail "链接生成失败时 write_uri_file 不应成功"
        fi
        assert_file_contains "$URI_FILE" '^keep$' "生成失败不应截断原链接文件"
    )
}

test_node_eof_rolls_back_fresh_install_config() {
    local creator

    for creator in create_or_rebuild_node create_vless_reality_node; do
        (
            CONFIG_DIR="$TEST_TMP/$creator-config"
            CONFIG_PATH="$CONFIG_DIR/config.json"
            URI_FILE="$CONFIG_DIR/vpsbox-uri.txt"
            ACTIVE_NODE_BACKUP=""
            require_valid_node_state_if_present() { return 0; }
            node_exists() { return 1; }
            backup_node_files() { mkdir -p "$1"; }
            install_singbox_if_missing() {
                mkdir -p "$CONFIG_DIR"
                printf '%s\n' package-default > "$CONFIG_PATH"
            }
            rollback_node_files_transaction() {
                local backup="${ACTIVE_NODE_BACKUP:-}"
                ACTIVE_NODE_BACKUP=""
                rm -f -- "$CONFIG_PATH"
                rm -rf -- "$backup"
                printf '%s\n' rolled-back > "$TEST_TMP/$creator.rollback"
            }

            if "$creator" </dev/null >"$TEST_TMP/$creator.out" 2>&1; then
                fail "$creator 在 EOF 取消时应返回失败"
            fi
            [ ! -e "$CONFIG_PATH" ] || fail "$creator 留下了阻塞后续创建的默认配置"
            assert_file_contains "$TEST_TMP/$creator.rollback" '^rolled-back$'
        )
    done
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
        load_state() { return 0; }
        write_uri_file() { return 1; }

        if view_node_link >/dev/null 2>&1; then
            fail "节点链接写入失败时查看功能不应成功"
        fi
    )
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
        mkdir -p "$fake_bin"
        printf '%s\n' old-binary > "$fake_bin/sing-box"
        chmod 755 "$fake_bin/sing-box"
        PATH="$fake_bin:$PATH"

        singbox_installed() { return 0; }
        singbox_version() { printf '%s\n' 1.13.13; }
        service_is_running() { return 0; }
        service_is_enabled() { return 0; }
        node_exists() { return 1; }
        install_deps() { return 0; }
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
        assert_file_contains "$fake_bin/sing-box" '^old-binary$'
        assert_file_contains "$TEST_TMP/restored-service-state" '^1 1$'
        [ -f "$update_backup/sing-box" ] || fail "更新失败后应保留旧二进制备份"
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
        test_node_eof_rolls_back_fresh_install_config
        test_reality_checks_require_bounded_dns_and_openssl
        test_view_node_propagates_uri_failure
        test_singbox_dependency_failure_does_not_touch_service
        test_failed_singbox_update_restores_binary_and_state
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
