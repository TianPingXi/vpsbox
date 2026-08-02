#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=tests/test_helper.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

# shellcheck source=../vpsbox.sh
source "$REPO_DIR/vpsbox.sh"

# 双节点夹具只验证配置与事务，不访问软件源安装宿主机依赖。
node_dependencies_available() { return 0; }
missing_node_commands() { printf '\n'; }

mkdir -p "$TEST_TMP/bin"
cat > "$TEST_TMP/bin/sing-box" <<'EOF'
#!/bin/sh
validate_config() {
    jq -e '
        (.inbounds | type == "array" and length > 0) and
        (all(.inbounds[];
            if .type == "shadowsocks" then
                (.listen_port | type == "number") and
                (.method == "2022-blake3-aes-128-gcm") and
                (.password | type == "string" and length > 0)
            elif .type == "vless" then
                (.listen_port | type == "number") and
                (.users | type == "array" and length > 0) and
                (.tls.enabled == true) and
                (.tls.reality.enabled == true) and
                (.tls.reality.handshake.server_port == 443)
            else
                false
            end
        )) and
        (.outbounds | type == "array" and length == 1) and
        (.outbounds[0].type == "direct") and
        (.outbounds[0].tag | type == "string" and startswith("direct-"))
    ' "$1" >/dev/null
}

case "${1:-}" in
    version) printf 'sing-box version 1.13.14\n' ;;
    check)
        case "${2:-}" in
            -c)
                [ -f "${3:-}" ] && validate_config "$3"
                ;;
            -C)
                found=0
                for file in "${3:-}"/*.json; do
                    [ -f "$file" ] || continue
                    found=1
                    validate_config "$file" || exit 1
                done
                [ "$found" -eq 1 ]
                ;;
            *) exit 2 ;;
        esac
        ;;
    *) exit 0 ;;
esac
EOF
chmod 755 "$TEST_TMP/bin/sing-box"
PATH="$TEST_TMP/bin:$PATH"
export PATH

node_permission_semantics_available() {
    local probe="$TEST_TMP/node-permission-capability" file
    local owner group dir_mode file_mode supported=0

    file="$probe/file"
    mkdir -p "$probe" || return 1
    : > "$file" || { rm -rf "$probe"; return 1; }
    if command chown 0:0 "$probe" "$file" 2>/dev/null &&
        command chmod 700 "$probe" &&
        command chmod 600 "$file"; then
        owner="$(stat -c '%u' "$file" 2>/dev/null || true)"
        group="$(stat -c '%g' "$file" 2>/dev/null || true)"
        dir_mode="$(stat -c '%a' "$probe" 2>/dev/null || true)"
        file_mode="$(stat -c '%a' "$file" 2>/dev/null || true)"
        if [ "$owner" = 0 ] && [ "$group" = 0 ] &&
            [ "$dir_mode" = 700 ] && [ "$file_mode" = 600 ]; then
            supported=1
        fi
    fi
    rm -rf "$probe" || return 1
    [ "$supported" -eq 1 ]
}

DUAL_NODES_REAL_PERMISSIONS=0
if node_permission_semantics_available; then
    DUAL_NODES_REAL_PERMISSIONS=1
else
    # 不支持 root 属主/Unix 模式的宿主仍运行配置与事务测试；严格验收会因权限专项 SKIP 而失败。
    chown() { return 0; }
    node_file_is_secure() {
        [ -f "$1" ] && [ ! -L "$1" ]
    }
    node_cleanup_source_file_is_safe() {
        [ -f "$1" ] && [ ! -L "$1" ]
    }
    node_uri_file_is_safe() {
        [ -f "$1" ] && [ ! -L "$1" ] &&
            [ "$(stat -c '%a' "$1" 2>/dev/null)" = "600" ]
    }
    node_dir_is_secure() {
        [ -d "$1" ] && [ ! -L "$1" ]
    }
    node_backup_file_is_safe() {
        [ -f "$1" ] && [ ! -L "$1" ]
    }
fi

cleanup() {
    rm -rf -- "$TEST_TMP"
}
trap cleanup EXIT

set_node_paths() {
    CONFIG_DIR="$1"
    URI_FILE="$CONFIG_DIR/vpsbox-uri.txt"
    NODE_CONFIG_DIR="$CONFIG_DIR/vpsbox.d"
    SS_CONFIG_PATH="$NODE_CONFIG_DIR/10-ss.json"
    VLESS_CONFIG_PATH="$NODE_CONFIG_DIR/20-vless-reality.json"
    SS_STATE_FILE="$CONFIG_DIR/vpsbox-ss.env"
    VLESS_STATE_FILE="$CONFIG_DIR/vpsbox-vless.env"
    SS_URI_FILE="$CONFIG_DIR/vpsbox-ss-uri.txt"
    VLESS_URI_FILE="$CONFIG_DIR/vpsbox-vless-uri.txt"
    VPSBOX_STATE_DIR="$CONFIG_DIR/vpsbox-state"
    NODE_TRANSACTION_DIR="$VPSBOX_STATE_DIR/node-transaction"
    NODE_TRANSACTION_BACKUP="$NODE_TRANSACTION_DIR/backup"
    # shellcheck disable=SC2034 # 被被测的节点事务函数动态读取。
    NODE_TRANSACTION_STAGE="$NODE_TRANSACTION_DIR/stage"
    ACTIVE_NODE_BACKUP=""
}

write_ss_state_fixture() {
    local file="$1" port="${2:-20001}" config_id="${3:-111111111111111111111111}"
    cat > "$file" <<EOF
PROTOCOL=shadowsocks
CONFIG_ID=$config_id
DOMAIN=ss.example.com
NAME=ss-node
PORT=$port
PASSWORD=QUFBQUFBQUFBQUFBQUFBQQ==
METHOD=$SS_METHOD
EOF
    chmod 600 "$file"
}

write_vless_state_fixture() {
    local file="$1" port="${2:-20002}" config_id="${3:-222222222222222222222222}"
    cat > "$file" <<EOF
PROTOCOL=vless-reality
CONFIG_ID=$config_id
DOMAIN=vless.example.com
NAME=vless-node
PORT=$port
UUID=11111111-2222-4333-8444-555555555555
FLOW=xtls-rprx-vision
REALITY_SERVER_NAME=addons.mozilla.org
REALITY_PRIVATE_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
REALITY_PUBLIC_KEY=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
REALITY_SHORT_ID=0123456789abcdef
FINGERPRINT=chrome
EOF
    chmod 600 "$file"
}

write_ss_config_fixture() {
    local file="$1" port="${2:-20001}" config_id="${3:-111111111111111111111111}"
    cat > "$file" <<EOF
{
  "inbounds": [{
    "type": "shadowsocks",
    "tag": "vpsbox-${config_id}-ss-in",
    "listen": "0.0.0.0",
    "listen_port": $port,
    "method": "$SS_METHOD",
    "password": "QUFBQUFBQUFBQUFBQUFBQQ=="
  }],
  "outbounds": [{"type": "direct", "tag": "direct-${config_id}-ss"}]
}
EOF
    chmod 600 "$file"
}

write_vless_config_fixture() {
    local file="$1" port="${2:-20002}" config_id="${3:-222222222222222222222222}"
    cat > "$file" <<EOF
{
  "inbounds": [{
    "type": "vless",
    "tag": "vpsbox-${config_id}-vless-reality-in",
    "listen": "0.0.0.0",
    "listen_port": $port,
    "users": [{
      "name": "vpsbox",
      "uuid": "11111111-2222-4333-8444-555555555555",
      "flow": "xtls-rprx-vision"
    }],
    "tls": {
      "enabled": true,
      "server_name": "addons.mozilla.org",
      "reality": {
        "enabled": true,
        "handshake": {"server": "addons.mozilla.org", "server_port": 443},
        "private_key": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "short_id": ["0123456789abcdef"]
      }
    }
  }],
  "outbounds": [{"type": "direct", "tag": "direct-${config_id}-vless"}]
}
EOF
    chmod 600 "$file"
}

test_fake_singbox_rejects_invalid_config_schema() {
    local config="$TEST_TMP/invalid-singbox-schema.json"

    cat > "$config" <<'EOF'
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "shadowsocks",
      "listen_port": 20001,
      "method": "2022-blake3-aes-128-gcm",
      "password": "QUFBQUFBQUFBQUFBQUFBQQ=="
    }
  ],
  "outbounds": [ { "type": "invalid", "tag": "direct-test" } ]
}
EOF
    if sing-box check -c "$config" >/dev/null 2>&1; then
        fail "测试用 sing-box 不得无条件接受无效 outbound 类型"
    fi
}

test_complete_configs_merge_with_unique_tags() {
    (
        local vless_before
        set_node_paths "$TEST_TMP/config-pair"
        listen_mode() { printf '%s\n' ipv4; }

        write_vless_reality_config \
            20002 11111111-2222-4333-8444-555555555555 addons.mozilla.org \
            AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA 0123456789abcdef \
            222222222222222222222222
        write_vless_state_fixture "$VLESS_STATE_FILE"
        vless_before="$(cat "$VLESS_CONFIG_PATH")"
        write_config 20001 QUFBQUFBQUFBQUFBQUFBQQ== 111111111111111111111111
        write_ss_state_fixture "$SS_STATE_FILE"
        check_node_config_set

        assert_file_contains "$SS_CONFIG_PATH" '"type": "shadowsocks"'
        assert_file_contains "$SS_CONFIG_PATH" '"tag": "direct-111111111111111111111111-ss"'
        assert_file_contains "$VLESS_CONFIG_PATH" '"type": "vless"'
        assert_file_contains "$VLESS_CONFIG_PATH" '"tag": "direct-222222222222222222222222-vless"'
        assert_file_not_contains "$SS_CONFIG_PATH" '"tag": "direct"'
        assert_file_not_contains "$VLESS_CONFIG_PATH" '"tag": "direct"'
        assert_eq "$vless_before" "$(cat "$VLESS_CONFIG_PATH")" \
            "创建 Shadowsocks 时不得改写既有 VLESS Reality 完整配置"
    )
}

test_create_shadowsocks_preserves_vless_and_tolerates_uri_cache_failure() {
    (
        local vless_config_before vless_state_before
        local event_log="$TEST_TMP/create-shadowsocks-uri.events"
        local output="$TEST_TMP/create-shadowsocks-uri.out"
        set_node_paths "$TEST_TMP/create-shadowsocks"
        mkdir -p "$NODE_CONFIG_DIR"
        write_vless_config_fixture "$VLESS_CONFIG_PATH"
        write_vless_state_fixture "$VLESS_STATE_FILE" 20002
        write_uri_files
        vless_config_before="$(cat "$VLESS_CONFIG_PATH")"
        vless_state_before="$(cat "$VLESS_STATE_FILE")"
        : > "$event_log"

        service_is_running() { return 1; }
        service_is_enabled() { return 1; }
        install_singbox_if_missing() { return 0; }
        prompt_node_host() { printf -v "$1" '%s' ss.example.com; }
        choose_node_port() { printf '%s\n' 20001; }
        confirm_default_yes() { return 0; }
        random_password() { printf '%s\n' QUFBQUFBQUFBQUFBQUFBQQ==; }
        listen_mode() { printf '%s\n' ipv4; }
        sing-box() {
            case "${1:-} ${2:-} ${3:-} ${4:-}" in
                "generate rand 12 --hex") printf '%s\n' 111111111111111111111111 ;;
                "check "*) command sing-box "$@" ;;
                *) return 1 ;;
            esac
        }
        firewall_prepare_port_transition() { return 0; }
        setup_service() { return 0; }
        restart_singbox_cleanly() { return 0; }
        verify_all_node_runtime() { return 0; }
        firewall_complete_port_transition() { return 0; }
        view_node_link() { return 0; }
        repair_node_uri_cache() {
            if [ -z "${ACTIVE_NODE_BACKUP:-}" ] &&
                [ ! -e "$NODE_TRANSACTION_DIR/pending" ]; then
                printf '%s\n' uri-after-commit >> "$event_log"
            else
                printf '%s\n' uri-before-commit >> "$event_log"
            fi
            return 1
        }
        node_uri_cache_status() { printf '%s\n' stale; }
        rollback_node_files_transaction() {
            printf '%s\n' rollback-files >> "$event_log"
            return 1
        }
        rollback_active_node_transaction() {
            printf '%s\n' rollback-active >> "$event_log"
            return 1
        }

        create_or_rebuild_node <<< $'\n' > "$output" 2>&1

        protocol_node_exists ss ||
            fail "创建后的 Shadowsocks 节点应可独立读取"
        assert_eq "$vless_config_before" "$(cat "$VLESS_CONFIG_PATH")" \
            "创建 Shadowsocks 时不得改写 VLESS Reality 配置"
        assert_eq "$vless_state_before" "$(cat "$VLESS_STATE_FILE")" \
            "创建 Shadowsocks 时不得改写 VLESS Reality 状态"
        assert_file_contains "$event_log" '^uri-after-commit$' \
            "Shadowsocks 创建必须先提交核心事务，再尝试修复 URI 缓存"
        assert_file_not_contains "$event_log" '^(uri-before-commit|rollback-)' \
            "URI 缓存失败不得提前发生或触发 Shadowsocks 核心事务回滚"
        assert_file_contains "$output" '核心配置不受影响' \
            "Shadowsocks URI 缓存重建失败应仅给出告警"
    )
}

test_create_vless_preserves_shadowsocks_and_tolerates_uri_cache_failure() {
    (
        local ss_config_before ss_state_before
        local event_log="$TEST_TMP/create-vless-uri.events"
        local output="$TEST_TMP/create-vless-uri.out"
        set_node_paths "$TEST_TMP/create-vless"
        mkdir -p "$NODE_CONFIG_DIR"
        write_ss_config_fixture "$SS_CONFIG_PATH"
        write_ss_state_fixture "$SS_STATE_FILE" 20001
        write_uri_files
        ss_config_before="$(cat "$SS_CONFIG_PATH")"
        ss_state_before="$(cat "$SS_STATE_FILE")"
        : > "$event_log"

        service_is_running() { return 1; }
        service_is_enabled() { return 1; }
        install_singbox_if_missing() { return 0; }
        prompt_node_host() { printf -v "$1" '%s' vless.example.com; }
        check_reality_server() { return 0; }
        choose_node_port() { printf '%s\n' 20002; }
        confirm_default_yes() { return 0; }
        listen_mode() { printf '%s\n' ipv4; }
        sing-box() {
            case "${1:-} ${2:-} ${3:-} ${4:-}" in
                "generate uuid  ") printf '%s\n' 11111111-2222-4333-8444-555555555555 ;;
                "generate rand 8 --hex") printf '%s\n' 0123456789abcdef ;;
                "generate rand 12 --hex") printf '%s\n' 222222222222222222222222 ;;
                "check "*) command sing-box "$@" ;;
                *) return 1 ;;
            esac
        }
        generate_reality_keypair() {
            printf '%s\n%s\n' \
                AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA \
                BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
        }
        firewall_prepare_port_transition() { return 0; }
        setup_service() { return 0; }
        restart_singbox_cleanly() { return 0; }
        verify_all_node_runtime() { return 0; }
        firewall_complete_port_transition() { return 0; }
        view_node_link() { return 0; }
        repair_node_uri_cache() {
            if [ -z "${ACTIVE_NODE_BACKUP:-}" ] &&
                [ ! -e "$NODE_TRANSACTION_DIR/pending" ]; then
                printf '%s\n' uri-after-commit >> "$event_log"
            else
                printf '%s\n' uri-before-commit >> "$event_log"
            fi
            return 1
        }
        node_uri_cache_status() { printf '%s\n' stale; }
        rollback_node_files_transaction() {
            printf '%s\n' rollback-files >> "$event_log"
            return 1
        }
        rollback_active_node_transaction() {
            printf '%s\n' rollback-active >> "$event_log"
            return 1
        }

        create_vless_reality_node <<< $'\n\n' > "$output" 2>&1

        protocol_node_exists vless ||
            fail "创建后的 VLESS Reality 节点应可独立读取"
        assert_eq "$ss_config_before" "$(cat "$SS_CONFIG_PATH")" \
            "创建 VLESS Reality 时不得改写 Shadowsocks 配置"
        assert_eq "$ss_state_before" "$(cat "$SS_STATE_FILE")" \
            "创建 VLESS Reality 时不得改写 Shadowsocks 状态"
        assert_file_contains "$event_log" '^uri-after-commit$' \
            "VLESS Reality 创建必须先提交核心事务，再尝试修复 URI 缓存"
        assert_file_not_contains "$event_log" '^(uri-before-commit|rollback-)' \
            "URI 缓存失败不得提前发生或触发 VLESS Reality 核心事务回滚"
        assert_file_contains "$output" '核心配置不受影响' \
            "VLESS Reality URI 缓存重建失败应仅给出告警"
    )
}

test_independent_states_and_links_are_aggregated() {
    (
        set_node_paths "$TEST_TMP/state-links"
        mkdir -p "$NODE_CONFIG_DIR"
        write_ss_config_fixture "$SS_CONFIG_PATH"
        write_vless_config_fixture "$VLESS_CONFIG_PATH"
        write_ss_state_fixture "$SS_STATE_FILE"
        write_vless_state_fixture "$VLESS_STATE_FILE"

        write_uri_files

        assert_file_contains "$SS_URI_FILE" '^ss://'
        assert_file_contains "$VLESS_URI_FILE" '^vless://'
        [ "$(wc -l < "$URI_FILE")" -eq 2 ] || fail "汇总链接文件应包含两个节点"
        [ "$(sed -n '1p' "$URI_FILE")" = "$(cat "$SS_URI_FILE")" ] ||
            fail "汇总链接第一行应为 Shadowsocks"
        [ "$(sed -n '2p' "$URI_FILE")" = "$(cat "$VLESS_URI_FILE")" ] ||
            fail "汇总链接第二行应为 VLESS Reality"
    )
}

test_service_definition_uses_independent_config_directory() {
    (
        set_node_paths "$TEST_TMP/service-mode"
        mkdir -p "$NODE_CONFIG_DIR"
        write_ss_config_fixture "$SS_CONFIG_PATH"
        write_ss_state_fixture "$SS_STATE_FILE"
        write_uri_files
        render_singbox_systemd_service /usr/bin/sing-box > "$TEST_TMP/sing-box.service"
        assert_file_contains "$TEST_TMP/sing-box.service" "ExecStart=/usr/bin/sing-box run -C $NODE_CONFIG_DIR"
        assert_file_not_contains "$TEST_TMP/sing-box.service" ' run -c '
    )
}

test_uri_cache_is_derived_from_core_state() {
    (
        set_node_paths "$TEST_TMP/derived-uri"
        mkdir -p "$NODE_CONFIG_DIR"
        write_ss_config_fixture "$SS_CONFIG_PATH"
        write_ss_state_fixture "$SS_STATE_FILE"
        write_uri_files
        printf 'stale-protocol\n' > "$SS_URI_FILE"
        printf 'stale-aggregate\n' > "$URI_FILE"
        chmod 600 "$SS_URI_FILE" "$URI_FILE"

        require_valid_node_state_if_present ||
            fail "URI 缓存陈旧不得破坏核心节点完整性"
        protocol_node_exists ss ||
            fail "URI 缓存陈旧时仍应识别 Shadowsocks 核心节点"
        [ "$(node_uri_cache_status)" = stale ] ||
            fail "陈旧 URI 缓存必须被单独识别"
        repair_node_uri_cache ||
            fail "安全的陈旧 URI 缓存应能一次原子重建"
        assert_eq current "$(node_uri_cache_status)" \
            "URI 缓存重建后必须与核心状态一致"
        assert_file_contains "$SS_URI_FILE" '^ss://'
        assert_file_contains "$URI_FILE" '^ss://'

        rm -f "$URI_FILE" "$SS_URI_FILE" "$VLESS_URI_FILE"
        assert_eq stale "$(node_uri_cache_status)" \
            "核心节点存在但 URI 全部缺失时必须识别为缓存缺失"
        repair_node_uri_cache ||
            fail "缺失的 URI 缓存应能从核心状态重建"
        assert_eq current "$(node_uri_cache_status)"
    )
}

test_uri_cache_repair_refuses_unsafe_paths() {
    (
        local target="$TEST_TMP/unsafe-uri-target"

        if [ "$DUAL_NODES_REAL_PERMISSIONS" -ne 1 ]; then
            skip "需要真实的 root 属主与 Unix 权限语义"
            return "$SKIP_STATUS"
        fi
        require_real_symlink file || return "$?"
        set_node_paths "$TEST_TMP/unsafe-uri"
        mkdir -p "$NODE_CONFIG_DIR"
        write_ss_config_fixture "$SS_CONFIG_PATH"
        write_ss_state_fixture "$SS_STATE_FILE"
        write_uri_files

        chmod 666 "$SS_URI_FILE"
        assert_eq unsafe "$(node_uri_cache_status)" \
            "权限不安全的 URI 必须分类为 unsafe"
        if repair_node_uri_cache >/dev/null 2>&1; then
            fail "权限不安全的 URI 缓存不得被自动覆盖"
        fi
        assert_file_contains "$SS_URI_FILE" '^ss://'
        assert_eq 666 "$(stat -c '%a' "$SS_URI_FILE")" \
            "自动修复不得偷偷收紧不安全 URI 的权限"

        chmod 600 "$SS_URI_FILE"
        command chown 65534:65534 "$SS_URI_FILE"
        assert_eq unsafe "$(node_uri_cache_status)" \
            "所有者不安全的 URI 必须分类为 unsafe"
        if repair_node_uri_cache >/dev/null 2>&1; then
            fail "所有者不安全的 URI 缓存不得被自动覆盖"
        fi
        assert_eq 65534 "$(stat -c '%u' "$SS_URI_FILE")" \
            "自动修复不得替换所有者不安全的 URI"
        command chown root:root "$SS_URI_FILE"

        chmod 400 "$SS_URI_FILE"
        assert_eq current "$(node_uri_cache_status)" \
            "root 所有的 0400 只读 URI 应视为安全且保持可用"
        repair_node_uri_cache ||
            fail "安全的只读 URI 不应阻止缓存检查"
        assert_eq 400 "$(stat -c '%a' "$SS_URI_FILE")" \
            "只读检查不得擅自把用户设置的安全 0400 权限改回 0600"
        assert_eq current "$(node_uri_cache_status)"

        printf 'keep-target\n' > "$target"
        rm -f "$SS_URI_FILE"
        ln -s "$target" "$SS_URI_FILE"
        assert_eq unsafe "$(node_uri_cache_status)" \
            "URI 符号链接必须分类为 unsafe"
        if repair_node_uri_cache >/dev/null 2>&1; then
            fail "URI 符号链接不得被自动覆盖"
        fi
        [ -L "$SS_URI_FILE" ] || fail "自动修复不得替换 URI 符号链接"
        assert_file_contains "$target" '^keep-target$'

        rm -f "$SS_URI_FILE"
        mkdir "$SS_URI_FILE"
        assert_eq unsafe "$(node_uri_cache_status)" \
            "非普通 URI 文件必须分类为 unsafe"
        if repair_node_uri_cache >/dev/null 2>&1; then
            fail "非普通 URI 文件不得被自动覆盖"
        fi
        [ -d "$SS_URI_FILE" ] || fail "自动修复不得删除非普通 URI 文件"
        require_valid_node_state_if_present ||
            fail "不安全 URI 缓存不得使配置与状态一致的核心节点失效"
        protocol_node_exists ss ||
            fail "不安全 URI 缓存存在时仍应识别有效的 Shadowsocks 节点"
    )
}

test_unsafe_uri_cache_does_not_block_node_transaction() {
    (
        local target="$TEST_TMP/transaction-uri-target"

        require_real_symlink file || return "$?"
        set_node_paths "$TEST_TMP/transaction-unsafe-uri"
        mkdir -p "$NODE_CONFIG_DIR"
        write_ss_config_fixture "$SS_CONFIG_PATH"
        write_ss_state_fixture "$SS_STATE_FILE"
        printf 'keep-target\n' > "$target"
        ln -s "$target" "$SS_URI_FILE"
        service_is_running() { return 1; }
        service_is_enabled() { return 1; }

        begin_node_transaction static ||
            fail "URI 是派生缓存，不安全 URI 不应阻止核心节点事务"
        cancel_unmodified_node_transaction ||
            fail "未修改事务应能正常清理"
        [ -L "$SS_URI_FILE" ] ||
            fail "事务准备不得擅自替换 URI 符号链接"
        assert_file_contains "$target" '^keep-target$'
    )
}

test_stopped_sibling_port_is_rejected() {
    (
        local output="$TEST_TMP/sibling-port.out"
        ss() { :; }
        docker_reserved_ports_for_port_choice() { printf '\n'; }
        ssh_effective_ports_csv() { printf '%s\n' 22; }
        port_is_effective_ssh_port() { return 1; }
        port_in_use_for_protocols() { return 1; }

        choose_node_port "" tcp "" 20001 <<< $'20001\n20002' > "$output"
        assert_file_contains "$output" '^20002$'
    ) 2> "$TEST_TMP/sibling-port.err"
    assert_file_contains "$TEST_TMP/sibling-port.err" '端口 20001 已被另一个节点使用'
}

test_stopped_target_port_is_rechecked_against_system_listeners() {
    (
        local output="$TEST_TMP/stopped-target-port.out"
        ss() { :; }
        docker_reserved_ports_for_port_choice() { printf '\n'; }
        ssh_effective_ports_csv() { printf '%s\n' 22; }
        port_is_effective_ssh_port() { return 1; }
        singbox_config_pids() { return 0; }
        port_in_use_for_protocols() { [ "$1" = 20001 ]; }

        choose_node_port 20001 tcp tcp "" <<< $'20001\n20002' > "$output"
        assert_file_contains "$output" '^20002$'
    ) 2> "$TEST_TMP/stopped-target-port.err"
    assert_file_contains "$TEST_TMP/stopped-target-port.err" '端口 20001 已被占用'
}

test_delete_one_protocol_keeps_sibling_running() {
    (
        local event_log="$TEST_TMP/delete-events"
        set_node_paths "$TEST_TMP/delete-one"
        mkdir -p "$NODE_CONFIG_DIR"
        write_ss_config_fixture "$SS_CONFIG_PATH"
        write_vless_config_fixture "$VLESS_CONFIG_PATH"
        write_ss_state_fixture "$SS_STATE_FILE"
        write_vless_state_fixture "$VLESS_STATE_FILE"
        # shellcheck disable=SC2218 # 先调用生产实现生成基线，随后才覆盖为事件记录 mock。
        write_uri_files
        : > "$event_log"

        begin_node_transaction() { printf 'transaction\n' >> "$event_log"; }
        mark_node_transaction_mutated() { printf 'mutated\n' >> "$event_log"; }
        commit_node_transaction() { printf 'commit\n' >> "$event_log"; }
        rollback_active_node_transaction() { printf 'rollback\n' >> "$event_log"; }
        firewall_prepare_port_transition() { printf 'prepare\n' >> "$event_log"; }
        service_stop() { printf 'stop\n' >> "$event_log"; }
        stop_singbox_config_processes() { return 0; }
        service_manager_is_active() { return 1; }
        singbox_config_pids() { return 0; }
        port_in_use_for_protocols() { return 1; }
        write_uri_files() { printf 'links\n' >> "$event_log"; }
        check_node_config_set() { return 0; }
        setup_service() { printf 'setup\n' >> "$event_log"; }
        restart_singbox_cleanly() { printf 'restart\n' >> "$event_log"; }
        verify_all_node_runtime() { printf 'verify\n' >> "$event_log"; }
        firewall_complete_port_transition() { printf 'complete\n' >> "$event_log"; }

        delete_vless_reality_node <<< y >/dev/null

        [ ! -e "$VLESS_CONFIG_PATH" ] && [ ! -e "$VLESS_STATE_FILE" ] ||
            fail "目标 VLESS 文件应被删除"
        [ -e "$SS_CONFIG_PATH" ] && [ -e "$SS_STATE_FILE" ] ||
            fail "Shadowsocks 兄弟节点文件必须保留"
        assert_file_contains "$event_log" '^restart$'
        assert_file_contains "$event_log" '^verify$'
        assert_file_contains "$event_log" '^complete$'
    )
}

test_delete_last_protocol_disables_service() {
    (
        local event_log="$TEST_TMP/delete-last-events"
        set_node_paths "$TEST_TMP/delete-last"
        mkdir -p "$NODE_CONFIG_DIR"
        write_vless_config_fixture "$VLESS_CONFIG_PATH"
        write_vless_state_fixture "$VLESS_STATE_FILE"
        write_uri_files
        : > "$event_log"

        begin_node_transaction() { printf 'transaction\n' >> "$event_log"; }
        mark_node_transaction_mutated() { printf 'mutated\n' >> "$event_log"; }
        commit_node_transaction() { printf 'commit\n' >> "$event_log"; }
        rollback_active_node_transaction() { printf 'rollback\n' >> "$event_log"; }
        firewall_prepare_port_transition() { printf 'prepare\n' >> "$event_log"; }
        service_stop() { printf 'stop\n' >> "$event_log"; }
        stop_singbox_config_processes() { return 0; }
        service_manager_is_active() { return 1; }
        singbox_config_pids() { return 0; }
        port_in_use_for_protocols() { return 1; }
        service_disable() { printf 'disable\n' >> "$event_log"; }
        service_is_enabled() { return 1; }
        firewall_complete_port_transition() { printf 'complete\n' >> "$event_log"; }

        delete_vless_reality_node <<< y >/dev/null

        [ ! -e "$VLESS_CONFIG_PATH" ] && [ ! -e "$VLESS_STATE_FILE" ] ||
            fail "最后一个节点的文件应被删除"
        assert_file_contains "$event_log" '^disable$'
        assert_file_contains "$event_log" '^complete$'
        assert_file_not_contains "$event_log" '^(setup|restart)$'
    )
}

test_delete_residual_node_without_singbox_keeps_sibling_static() {
    (
        local event_log="$TEST_TMP/delete-without-singbox.events"
        local output="$TEST_TMP/delete-without-singbox.out"
        set_node_paths "$TEST_TMP/delete-without-singbox"
        mkdir -p "$NODE_CONFIG_DIR"
        write_ss_config_fixture "$SS_CONFIG_PATH"
        write_vless_config_fixture "$VLESS_CONFIG_PATH"
        write_ss_state_fixture "$SS_STATE_FILE"
        write_vless_state_fixture "$VLESS_STATE_FILE"
        write_uri_files
        : > "$event_log"

        command() {
            if [ "${1:-}" = -v ]; then
                case "${2:-}" in sing-box|ss) return 1 ;; esac
            fi
            builtin command "$@"
        }
        missing_node_commands() {
            local command_name
            for command_name in "$@"; do
                [ "$command_name" != ss ] || { printf 'ss\n'; return 0; }
            done
            printf '\n'
        }
        # shellcheck disable=SC2120 # 调用来自运行时 source 的生产函数。
        begin_node_transaction() { printf 'transaction:%s\n' "$1" >> "$event_log"; }
        mark_node_transaction_mutated() { printf '%s\n' mutated >> "$event_log"; }
        commit_node_transaction() { printf '%s\n' commit >> "$event_log"; }
        rollback_active_node_transaction() { printf '%s\n' rollback >> "$event_log"; }
        firewall_prepare_port_transition() { printf '%s\n' prepare >> "$event_log"; }
        firewall_complete_port_transition() { printf '%s\n' complete >> "$event_log"; }
        service_manager_is_active() { return 1; }
        singbox_config_pids() { return 0; }
        service_stop() { printf '%s\n' unexpected:service-stop >> "$event_log"; return 1; }
        stop_singbox_config_processes() { printf '%s\n' unexpected:process-stop >> "$event_log"; return 1; }
        port_in_use_for_protocols() { printf '%s\n' unexpected:port-check >> "$event_log"; return 1; }
        setup_service() { printf '%s\n' unexpected:setup >> "$event_log"; return 1; }
        restart_singbox_cleanly() { printf '%s\n' unexpected:restart >> "$event_log"; return 1; }
        verify_all_node_runtime() { printf '%s\n' unexpected:verify >> "$event_log"; return 1; }

        delete_vless_reality_node <<< y > "$output"

        [ ! -e "$VLESS_CONFIG_PATH" ] && [ ! -e "$VLESS_STATE_FILE" ] ||
            fail "sing-box 缺失时应能删除目标残留节点"
        [ -e "$SS_CONFIG_PATH" ] && [ -e "$SS_STATE_FILE" ] ||
            fail "sing-box 缺失时必须保留兄弟节点配置"
        assert_file_contains "$event_log" '^transaction:static$'
        assert_file_contains "$event_log" '^complete$'
        assert_file_not_contains "$event_log" '^(unexpected:|rollback$)'
        assert_file_contains "$output" '其他节点配置已保留，但 sing-box 未安装，当前不会运行'
    )
}

test_delete_last_residual_node_without_singbox_skips_missing_service() {
    (
        local event_log="$TEST_TMP/delete-last-without-singbox.events"
        local output="$TEST_TMP/delete-last-without-singbox.out"
        set_node_paths "$TEST_TMP/delete-last-without-singbox"
        mkdir -p "$NODE_CONFIG_DIR"
        write_vless_config_fixture "$VLESS_CONFIG_PATH"
        write_vless_state_fixture "$VLESS_STATE_FILE"
        write_uri_files
        : > "$event_log"

        command() {
            if [ "${1:-}" = -v ]; then
                case "${2:-}" in sing-box|ss) return 1 ;; esac
            fi
            builtin command "$@"
        }
        # shellcheck disable=SC2120 # 调用来自运行时 source 的生产函数。
        begin_node_transaction() { printf 'transaction:%s\n' "$1" >> "$event_log"; }
        mark_node_transaction_mutated() { printf '%s\n' mutated >> "$event_log"; }
        commit_node_transaction() { printf '%s\n' commit >> "$event_log"; }
        rollback_active_node_transaction() { printf '%s\n' rollback >> "$event_log"; }
        firewall_prepare_port_transition() { printf '%s\n' prepare >> "$event_log"; }
        firewall_complete_port_transition() { printf '%s\n' complete >> "$event_log"; }
        service_manager_is_active() { return 1; }
        service_is_enabled() { return 1; }
        singbox_config_pids() { return 0; }
        port_in_use_for_protocols() { printf '%s\n' unexpected:port-check >> "$event_log"; return 1; }
        service_stop() { printf '%s\n' unexpected:service-stop >> "$event_log"; return 1; }
        service_disable() { printf '%s\n' unexpected:disable >> "$event_log"; return 1; }
        stop_singbox_config_processes() { printf '%s\n' unexpected:process-stop >> "$event_log"; return 1; }

        delete_vless_reality_node <<< y > "$output"

        [ ! -e "$VLESS_CONFIG_PATH" ] && [ ! -e "$VLESS_STATE_FILE" ] ||
            fail "sing-box 缺失时应能删除最后一个残留节点"
        assert_file_contains "$event_log" '^transaction:static$'
        assert_file_contains "$event_log" '^complete$'
        assert_file_not_contains "$event_log" '^(unexpected:|rollback$)'
        assert_file_contains "$output" 'sing-box 未安装，无需停止服务'
    )
}

test_delete_damaged_protocol_keeps_valid_sibling_running() {
    (
        local event_log="$TEST_TMP/delete-damaged-with-sibling.events"
        local output="$TEST_TMP/delete-damaged-with-sibling.out"
        local ss_config_before ss_state_before

        set_node_paths "$TEST_TMP/delete-damaged-with-sibling"
        mkdir -p "$NODE_CONFIG_DIR"
        write_ss_config_fixture "$SS_CONFIG_PATH"
        write_ss_state_fixture "$SS_STATE_FILE"
        write_vless_config_fixture "$VLESS_CONFIG_PATH"
        write_vless_state_fixture "$VLESS_STATE_FILE"
        write_uri_files
        printf '%s\n' '{"broken":true}' > "$VLESS_CONFIG_PATH"
        chmod 600 "$VLESS_CONFIG_PATH"
        assert_eq damaged "$(protocol_node_status vless)" \
            "测试前提：目标 VLESS 节点必须处于损坏状态"
        ss_config_before="$(cat "$SS_CONFIG_PATH")"
        ss_state_before="$(cat "$SS_STATE_FILE")"
        : > "$event_log"
        forbid_init

        require_node_commands() { return 0; }
        service_is_running() { return 1; }
        service_is_enabled() { return 0; }
        service_stop() { return 0; }
        stop_singbox_config_processes() { return 0; }
        service_manager_is_active() { return 1; }
        singbox_config_pids() { return 0; }
        port_in_use_for_protocols() {
            forbid "损坏配置对应的可解析 state 端口不得用于占用检查"
        }
        firewall_prepare_port_transition() {
            forbid "损坏配置对应的可解析 state 端口不得用于防火墙删除"
        }
        firewall_complete_port_transition() {
            forbid "cleanup 不得提交未建立的防火墙端口事务"
        }
        setup_service() { printf '%s\n' setup >> "$event_log"; }
        restart_singbox_cleanly() { printf '%s\n' restart >> "$event_log"; }
        verify_all_node_runtime() { printf '%s\n' verify >> "$event_log"; }

        delete_vless_reality_node <<< y > "$output" 2>&1 ||
            fail "应能安全删除损坏的 VLESS 节点并保留健康兄弟节点"

        [ ! -e "$VLESS_CONFIG_PATH" ] && [ ! -L "$VLESS_CONFIG_PATH" ] &&
            [ ! -e "$VLESS_STATE_FILE" ] && [ ! -L "$VLESS_STATE_FILE" ] ||
            fail "损坏目标节点的配置与状态文件都应被删除"
        assert_eq "$ss_config_before" "$(cat "$SS_CONFIG_PATH")" \
            "清理损坏目标时不得改写健康兄弟节点配置"
        assert_eq "$ss_state_before" "$(cat "$SS_STATE_FILE")" \
            "清理损坏目标时不得改写健康兄弟节点状态"
        validate_protocol_node_core ss "$SS_CONFIG_PATH" "$SS_STATE_FILE" ||
            fail "删除损坏目标后健康兄弟节点必须保持完整"
        assert_eq $'setup\nrestart\nverify' "$(cat "$event_log")" \
            "健康兄弟节点必须重新建立服务、启动并验证运行状态"
        assert_file_contains "$output" '其他节点继续运行'
        assert_no_forbidden "损坏节点清理错误使用了不可信 state 端口"
    )
}

test_delete_partial_damaged_protocol_does_not_guess_firewall_port() {
    (
        local output="$TEST_TMP/delete-partial-damaged.out"

        set_node_paths "$TEST_TMP/delete-partial-damaged"
        mkdir -p "$NODE_CONFIG_DIR"
        write_ss_config_fixture "$SS_CONFIG_PATH"
        write_ss_state_fixture "$SS_STATE_FILE"
        printf '%s\n' '{"broken":true}' > "$VLESS_CONFIG_PATH"
        chmod 600 "$VLESS_CONFIG_PATH"
        assert_eq damaged "$(protocol_node_status vless)" \
            "测试前提：缺少状态文件的 VLESS 节点必须处于损坏状态"
        forbid_init

        require_node_commands() { return 0; }
        service_is_running() { return 1; }
        service_is_enabled() { return 0; }
        service_stop() { return 0; }
        stop_singbox_config_processes() { return 0; }
        service_manager_is_active() { return 1; }
        singbox_config_pids() { return 0; }
        port_in_use_for_protocols() {
            forbid "没有可信目标端口时不得执行端口占用检查"
        }
        firewall_prepare_port_transition() {
            forbid "损坏节点端口未知时不得开始端口删除事务"
        }
        firewall_complete_port_transition() {
            forbid "损坏节点端口未知时不得提交端口删除事务"
        }
        firewall_runtime_enabled() { return 1; }
        firewall_control_plane_present() { return 0; }
        setup_service() { return 0; }
        restart_singbox_cleanly() { return 0; }
        verify_all_node_runtime() { return 0; }

        delete_vless_reality_node <<< y > "$output" 2>&1 ||
            fail "状态文件缺失时仍应能清理固定路径上的损坏 VLESS 配置"

        [ ! -e "$VLESS_CONFIG_PATH" ] && [ ! -L "$VLESS_CONFIG_PATH" ] ||
            fail "残缺目标的配置文件应被删除"
        [ ! -e "$VLESS_STATE_FILE" ] && [ ! -L "$VLESS_STATE_FILE" ] ||
            fail "残缺目标不得产生新的状态文件"
        validate_protocol_node_core ss "$SS_CONFIG_PATH" "$SS_STATE_FILE" ||
            fail "清理残缺目标后健康兄弟节点必须保持完整"
        assert_file_contains "$output" '未自动猜测或删除防火墙端口' \
            "防火墙持久控制面存在时必须明确保留无法确认的旧端口规则"
        assert_no_forbidden "残缺节点清理使用了未经确认的目标端口"
    )
}

test_running_service_with_invalid_disk_config_blocks_damaged_cleanup() {
    (
        local output="$TEST_TMP/delete-running-invalid.out"

        set_node_paths "$TEST_TMP/delete-running-invalid"
        mkdir -p "$NODE_CONFIG_DIR"
        write_ss_config_fixture "$SS_CONFIG_PATH"
        write_ss_state_fixture "$SS_STATE_FILE"
        printf '%s\n' '{"broken":true}' > "$VLESS_CONFIG_PATH"
        chmod 600 "$VLESS_CONFIG_PATH"
        forbid_init

        require_node_commands() { return 0; }
        service_is_running() { return 0; }
        service_stop() { forbid "运行中的无效磁盘配置不得进入停止服务阶段"; }
        stop_singbox_config_processes() { forbid "运行中的无效磁盘配置不得停止进程"; }
        begin_node_transaction() { forbid "运行中的无效磁盘配置不得建立删除事务"; }
        firewall_prepare_port_transition() { forbid "运行中的无效磁盘配置不得修改防火墙"; }

        if delete_vless_reality_node <<< y > "$output" 2>&1; then
            fail "运行中的 sing-box 对应无效磁盘配置时必须拒绝清理"
        fi

        [ -f "$VLESS_CONFIG_PATH" ] ||
            fail "拒绝清理后必须保留损坏节点文件"
        validate_protocol_node_core ss "$SS_CONFIG_PATH" "$SS_STATE_FILE" ||
            fail "拒绝清理时健康兄弟节点必须保持完整"
        assert_file_contains "$output" '请先在 sing-box 管理中停止服务'
        assert_no_forbidden "运行中的无效磁盘配置拒绝路径发生了系统修改"
    )
}

test_delete_damaged_protocol_rejects_unsafe_target_before_mutation() {
    (
        local external="$TEST_TMP/delete-unsafe-target.external"
        local output="$TEST_TMP/delete-unsafe-target.out"

        require_real_symlink file || return "$?"
        set_node_paths "$TEST_TMP/delete-unsafe-target"
        mkdir -p "$NODE_CONFIG_DIR"
        write_ss_config_fixture "$SS_CONFIG_PATH"
        write_ss_state_fixture "$SS_STATE_FILE"
        printf '%s\n' external-node-data > "$external"
        ln -s "$external" "$VLESS_CONFIG_PATH"
        write_vless_state_fixture "$VLESS_STATE_FILE"
        forbid_init

        require_node_commands() { return 0; }
        service_stop() { forbid "不安全目标不得触发服务停止"; }
        stop_singbox_config_processes() { forbid "不安全目标不得触发进程停止"; }
        firewall_prepare_port_transition() { forbid "不安全目标不得触发防火墙事务"; }

        if delete_vless_reality_node <<< y > "$output" 2>&1; then
            fail "符号链接形式的损坏节点目标必须拒绝删除"
        fi

        [ -L "$VLESS_CONFIG_PATH" ] ||
            fail "拒绝删除后目标符号链接必须保留"
        assert_eq external-node-data "$(cat "$external")" \
            "拒绝删除时不得改写符号链接指向的外部文件"
        validate_protocol_node_core ss "$SS_CONFIG_PATH" "$SS_STATE_FILE" ||
            fail "拒绝不安全目标时健康兄弟节点必须保持完整"
        assert_no_forbidden "拒绝不安全损坏节点前发生了系统修改"
    )
}

test_delete_damaged_protocol_requires_valid_sibling() {
    (
        local output="$TEST_TMP/delete-damaged-sibling.out"

        set_node_paths "$TEST_TMP/delete-damaged-sibling"
        mkdir -p "$NODE_CONFIG_DIR"
        write_ss_config_fixture "$SS_CONFIG_PATH"
        write_ss_state_fixture "$SS_STATE_FILE"
        write_vless_config_fixture "$VLESS_CONFIG_PATH"
        write_vless_state_fixture "$VLESS_STATE_FILE"
        printf '%s\n' '{"broken":"ss"}' > "$SS_CONFIG_PATH"
        printf '%s\n' '{"broken":"vless"}' > "$VLESS_CONFIG_PATH"
        chmod 600 "$SS_CONFIG_PATH" "$VLESS_CONFIG_PATH"
        forbid_init

        require_node_commands() { return 0; }
        service_stop() { forbid "兄弟节点也损坏时不得停止服务"; }
        stop_singbox_config_processes() { forbid "兄弟节点也损坏时不得停止进程"; }
        firewall_prepare_port_transition() { forbid "兄弟节点也损坏时不得修改防火墙"; }

        if delete_vless_reality_node <<< y > "$output" 2>&1; then
            fail "兄弟节点也损坏时不得进入单协议 cleanup 删除"
        fi

        [ -f "$SS_CONFIG_PATH" ] && [ -f "$SS_STATE_FILE" ] &&
            [ -f "$VLESS_CONFIG_PATH" ] && [ -f "$VLESS_STATE_FILE" ] ||
            fail "拒绝含损坏兄弟节点的 cleanup 时必须保留全部节点文件"
        assert_no_forbidden "兄弟节点损坏的 cleanup 拒绝路径发生了系统修改"
    )
}

test_damaged_protocol_cleanup_rolls_back_after_late_failure() {
    (
        local event_log="$TEST_TMP/delete-damaged-rollback.events"
        local output="$TEST_TMP/delete-damaged-rollback.out"
        local ss_config_before ss_state_before vless_config_before vless_state_before

        set_node_paths "$TEST_TMP/delete-damaged-rollback"
        mkdir -p "$NODE_CONFIG_DIR"
        write_ss_config_fixture "$SS_CONFIG_PATH"
        write_ss_state_fixture "$SS_STATE_FILE"
        write_vless_config_fixture "$VLESS_CONFIG_PATH"
        write_vless_state_fixture "$VLESS_STATE_FILE"
        write_uri_files
        printf '%s\n' '{"broken":"restore-exactly"}' > "$VLESS_CONFIG_PATH"
        chmod 600 "$VLESS_CONFIG_PATH"
        ss_config_before="$(cat "$SS_CONFIG_PATH")"
        ss_state_before="$(cat "$SS_STATE_FILE")"
        vless_config_before="$(cat "$VLESS_CONFIG_PATH")"
        vless_state_before="$(cat "$VLESS_STATE_FILE")"
        : > "$event_log"

        require_node_commands() { return 0; }
        service_is_running() { return 1; }
        service_is_enabled() { return 0; }
        service_stop() { return 0; }
        stop_singbox_config_processes() { return 0; }
        service_manager_is_active() { return 1; }
        singbox_config_pids() { return 0; }
        port_in_use_for_protocols() { return 1; }
        firewall_prepare_port_transition() { return 0; }
        firewall_complete_port_transition() { return 0; }
        commit_node_transaction() {
            printf '%s\n' commit-reached >> "$event_log"
            return 1
        }
        firewall_refresh_if_enabled() { return 0; }
        setup_service() { return 0; }
        restart_singbox_cleanly() { return 0; }
        verify_all_node_runtime() { return 0; }
        restore_singbox_service_state() { return 0; }
        is_systemd() { return 1; }
        OS=debian

        if delete_vless_reality_node <<< y > "$output" 2>&1; then
            fail "删除后的事务提交失败时 cleanup 不得报告成功"
        fi

        assert_file_contains "$event_log" '^commit-reached$' \
            "测试必须确认失败发生在目标文件删除之后"
        assert_eq "$ss_config_before" "$(cat "$SS_CONFIG_PATH")" \
            "cleanup 回滚必须恢复健康兄弟节点配置"
        assert_eq "$ss_state_before" "$(cat "$SS_STATE_FILE")" \
            "cleanup 回滚必须恢复健康兄弟节点状态"
        assert_eq "$vless_config_before" "$(cat "$VLESS_CONFIG_PATH")" \
            "cleanup 回滚必须逐字恢复原损坏配置"
        assert_eq "$vless_state_before" "$(cat "$VLESS_STATE_FILE")" \
            "cleanup 回滚必须恢复原目标状态"
        assert_file_contains "$output" '恢复' \
            "cleanup 回滚完成后必须向用户说明恢复结果"
    )
}

test_cleanup_transaction_recovers_one_sided_damage_after_hard_interruption() {
    (
        local config_before output="$TEST_TMP/cleanup-hard-interruption.out"

        require_root_permission_semantics || return "$?"
        set_node_paths "$TEST_TMP/cleanup-hard-interruption"
        mkdir -p "$NODE_CONFIG_DIR"
        write_ss_config_fixture "$SS_CONFIG_PATH"
        write_ss_state_fixture "$SS_STATE_FILE"
        printf '%s\n' '{"broken":"one-sided"}' > "$VLESS_CONFIG_PATH"
        chmod 400 "$VLESS_CONFIG_PATH"
        config_before="$(cat "$VLESS_CONFIG_PATH")"

        service_is_running() { return 1; }
        service_is_enabled() { return 1; }
        service_stop() { return 0; }
        stop_singbox_config_processes() { return 0; }
        service_manager_is_active() { return 1; }
        singbox_config_pids() { return 0; }
        restore_singbox_service_state() { return 0; }
        firewall_refresh_if_enabled() { return 0; }
        is_systemd() { return 1; }
        OS=debian

        begin_node_transaction cleanup:vless ||
            fail "应能为单边损坏节点建立 cleanup 事务"
        mark_node_transaction_mutated ||
            fail "应能持久化 cleanup 事务的首次修改标记"
        rm -f -- "$VLESS_CONFIG_PATH"

        # 模拟进程被硬中断后由下一次 vpsbox 启动恢复，只依赖落盘事务信息。
        ACTIVE_NODE_BACKUP=""
        # shellcheck disable=SC2034 # 被已 source 的生产恢复函数通过全局状态动态读取。
        ACTIVE_NODE_TRANSACTION_MUTATED=0
        recover_pending_node_transaction > "$output" 2>&1 ||
            fail "下次启动必须能按持久化 cleanup 模式恢复单边损坏节点"

        assert_eq "$config_before" "$(cat "$VLESS_CONFIG_PATH")" \
            "硬中断恢复必须逐字恢复原损坏配置"
        assert_eq 400 "$(stat -c '%a' "$VLESS_CONFIG_PATH")" \
            "cleanup 事务应保留原 0400 权限"
        [ ! -e "$VLESS_STATE_FILE" ] && [ ! -L "$VLESS_STATE_FILE" ] ||
            fail "原本缺失的状态文件在恢复后仍应缺失"
        validate_protocol_node_core ss "$SS_CONFIG_PATH" "$SS_STATE_FILE" ||
            fail "硬中断恢复不得破坏健康兄弟节点"
        [ ! -e "$NODE_TRANSACTION_DIR" ] ||
            fail "成功恢复后应清理已完成的事务目录"
        assert_file_contains "$output" '未提交节点事务的节点配置与服务状态已恢复'
    )
}

test_cleanup_recovery_can_replace_safe_permission_damaged_target() {
    (
        local config_before output="$TEST_TMP/cleanup-permission-recovery.out"

        require_root_permission_semantics || return "$?"
        set_node_paths "$TEST_TMP/cleanup-permission-recovery"
        mkdir -p "$NODE_CONFIG_DIR"
        write_ss_config_fixture "$SS_CONFIG_PATH"
        write_ss_state_fixture "$SS_STATE_FILE"
        write_vless_config_fixture "$VLESS_CONFIG_PATH"
        write_vless_state_fixture "$VLESS_STATE_FILE"
        config_before="$(cat "$VLESS_CONFIG_PATH")"
        chmod 644 "$VLESS_CONFIG_PATH"

        service_is_running() { return 1; }
        service_is_enabled() { return 1; }
        service_stop() { return 0; }
        stop_singbox_config_processes() { return 0; }
        service_manager_is_active() { return 1; }
        singbox_config_pids() { return 0; }
        restore_singbox_service_state() { return 0; }
        firewall_refresh_if_enabled() { return 0; }
        is_systemd() { return 1; }
        OS=debian

        begin_node_transaction cleanup:vless ||
            fail "应能为权限损坏但来源安全的节点建立 cleanup 事务"
        mark_node_transaction_mutated ||
            fail "应能持久化 cleanup 事务的首次修改标记"

        # 模拟写入 mutated 后、真正删除目标文件前被硬中断。
        ACTIVE_NODE_BACKUP=""
        # shellcheck disable=SC2034 # 被已 source 的生产恢复函数通过全局状态动态读取。
        ACTIVE_NODE_TRANSACTION_MUTATED=0
        recover_pending_node_transaction > "$output" 2>&1 ||
            fail "cleanup 恢复必须能安全覆盖原 0644 目标，不能被严格节点权限卡住"

        assert_eq "$config_before" "$(cat "$VLESS_CONFIG_PATH")" \
            "权限损坏目标恢复后内容必须保持不变"
        assert_eq 600 "$(stat -c '%a' "$VLESS_CONFIG_PATH")" \
            "cleanup 备份恢复后应收敛为安全的 0600 权限"
        validate_protocol_node_core vless "$VLESS_CONFIG_PATH" "$VLESS_STATE_FILE" ||
            fail "权限损坏目标恢复后必须重新满足节点核心完整性"
        validate_protocol_node_core ss "$SS_CONFIG_PATH" "$SS_STATE_FILE" ||
            fail "权限损坏目标恢复不得破坏健康兄弟节点"
        [ ! -e "$NODE_TRANSACTION_DIR" ] ||
            fail "权限损坏目标成功恢复后应清理事务目录"
    )
}

test_delete_last_damaged_protocol_stops_and_disables_service() {
    (
        local enabled=1 event_log="$TEST_TMP/delete-last-damaged.events"
        local output="$TEST_TMP/delete-last-damaged.out"

        set_node_paths "$TEST_TMP/delete-last-damaged"
        mkdir -p "$NODE_CONFIG_DIR"
        write_vless_config_fixture "$VLESS_CONFIG_PATH"
        write_vless_state_fixture "$VLESS_STATE_FILE"
        printf '%s\n' '{"broken":"last-node"}' > "$VLESS_CONFIG_PATH"
        chmod 600 "$VLESS_CONFIG_PATH"
        : > "$event_log"
        forbid_init

        require_node_commands() { return 0; }
        service_is_running() { return 1; }
        service_is_enabled() { [ "$enabled" -eq 1 ]; }
        service_stop() { printf '%s\n' stop >> "$event_log"; }
        stop_singbox_config_processes() { return 0; }
        service_manager_is_active() { return 1; }
        singbox_config_pids() { return 0; }
        port_in_use_for_protocols() { forbid "损坏节点不得执行旧端口占用检查"; }
        firewall_prepare_port_transition() { forbid "损坏节点不得删除推测的防火墙端口"; }
        firewall_complete_port_transition() { forbid "cleanup 不得提交防火墙端口事务"; }
        firewall_control_plane_present() { return 1; }
        setup_service() { forbid "删除最后节点后不得重建服务"; }
        restart_singbox_cleanly() { forbid "删除最后节点后不得重启服务"; }
        verify_all_node_runtime() { forbid "删除最后节点后不得验证已删除节点"; }
        service_disable() {
            enabled=0
            printf '%s\n' disable >> "$event_log"
        }

        delete_vless_reality_node <<< y > "$output" 2>&1 ||
            fail "最后一个损坏节点应能安全清理"

        [ ! -e "$VLESS_CONFIG_PATH" ] && [ ! -L "$VLESS_CONFIG_PATH" ] &&
            [ ! -e "$VLESS_STATE_FILE" ] && [ ! -L "$VLESS_STATE_FILE" ] ||
            fail "最后一个损坏节点的固定配置与状态路径都应删除"
        assert_eq 0 "$enabled" "删除最后一个损坏节点后必须禁用开机启动"
        assert_eq $'stop\ndisable' "$(cat "$event_log")" \
            "删除最后一个损坏节点必须停止服务并禁用自启"
        assert_file_contains "$output" '服务已停止并禁用开机启动'
        assert_no_forbidden "删除最后一个损坏节点调用了兄弟节点或端口流程"
    )
}

test_view_link_uses_real_files_and_skips_damaged_sibling() {
    (
        local output="$TEST_TMP/view-link-real-sibling.out"

        set_node_paths "$TEST_TMP/view-link-real-sibling"
        mkdir -p "$NODE_CONFIG_DIR"
        write_ss_config_fixture "$SS_CONFIG_PATH"
        write_ss_state_fixture "$SS_STATE_FILE"
        write_vless_config_fixture "$VLESS_CONFIG_PATH"
        write_vless_state_fixture "$VLESS_STATE_FILE"
        printf '%s\n' '{"broken":"link-sibling"}' > "$VLESS_CONFIG_PATH"
        chmod 600 "$VLESS_CONFIG_PATH"

        view_node_link > "$output" 2>&1 ||
            fail "真实文件夹具中损坏兄弟节点不应阻止显示健康链接"

        assert_file_contains "$output" 'VLESS Reality 节点配置.*已跳过该节点链接' \
            "链接页面必须说明已跳过损坏兄弟节点"
        assert_file_contains "$output" 'Shadowsocks 节点'
        assert_file_contains "$output" '^ ss://'
        assert_file_not_contains "$output" '^ vless://' \
            "损坏兄弟节点不得生成 VLESS 链接"
    )
}

test_static_node_backup_validation_does_not_execute_singbox() {
    (
        local backup="$TEST_TMP/static-backup-validation/backup"
        forbid_init
        set_node_paths "$TEST_TMP/static-backup-validation/node"
        mkdir -p "$NODE_CONFIG_DIR"
        write_ss_config_fixture "$SS_CONFIG_PATH"
        write_ss_state_fixture "$SS_STATE_FILE"
        write_uri_files
        service_is_running() { return 1; }
        service_is_enabled() { return 1; }
        sing-box() { forbid "静态事务备份校验不得执行 sing-box"; }

        backup_node_files "$backup"
        validate_node_transaction_backup "$backup" ||
            fail "没有 sing-box 时，哈希及配置状态一致的备份应通过静态校验"
        printf '%s\n' tampered >> "$backup/ss-state.env"
        if validate_node_transaction_backup "$backup"; then
            fail "静态校验仍必须拒绝哈希被篡改的备份"
        fi
        assert_no_forbidden "静态事务备份校验执行了 sing-box"
    )
}

test_legacy_uri_snapshot_damage_does_not_block_core_recovery() {
    (
        local backup="$TEST_TMP/legacy-uri-backup/backup"
        local manifest_tmp="$TEST_TMP/legacy-uri-backup/manifest.tmp"
        local source name digest

        set_node_paths "$TEST_TMP/legacy-uri-backup/node"
        mkdir -p "$NODE_CONFIG_DIR"
        write_ss_config_fixture "$SS_CONFIG_PATH"
        write_ss_state_fixture "$SS_STATE_FILE"
        write_uri_files
        service_is_running() { return 1; }
        service_is_enabled() { return 1; }

        backup_node_files "$backup"
        for source in "$URI_FILE" "$SS_URI_FILE"; do
            case "$source" in
                "$URI_FILE") name=node-uri.txt ;;
                "$SS_URI_FILE") name=ss-uri.txt ;;
            esac
            cp -- "$source" "$backup/$name"
            chmod 600 "$backup/$name"
            digest="$(sha256sum "$backup/$name" | awk '{print $1}')"
            awk -F'|' -v OFS='|' -v name="$name" -v digest="$digest" '
                $1 == "file" && $2 == name {
                    $3 = "present"
                    $4 = digest
                }
                { print }
            ' "$backup/manifest" > "$manifest_tmp"
            mv -- "$manifest_tmp" "$backup/manifest"
            chmod 600 "$backup/manifest"
        done

        validate_node_transaction_backup "$backup" ||
            fail "v1.0.43 的合法 URI 快照清单应继续兼容"

        printf 'tampered-derived-cache\n' > "$backup/node-uri.txt"
        rm -f "$backup/ss-uri.txt"
        validate_node_transaction_backup "$backup" ||
            fail "派生 URI 快照损坏或丢失不得阻止核心配置恢复"

        awk -F'|' -v OFS='|' '
            $1 == "file" && $2 == "node-uri.txt" { $4 = "invalid-digest" }
            { print }
        ' "$backup/manifest" > "$manifest_tmp"
        mv -- "$manifest_tmp" "$backup/manifest"
        chmod 600 "$backup/manifest"
        if validate_node_transaction_backup "$backup"; then
            fail "旧 URI 清单的结构或摘要字段非法时仍必须拒绝恢复"
        fi
    )
}

test_node_transaction_full_and_static_validation_modes() {
    (
        set_node_paths "$TEST_TMP/transaction-validation-modes"
        mkdir -p "$NODE_CONFIG_DIR"
        write_ss_config_fixture "$SS_CONFIG_PATH"
        write_ss_state_fixture "$SS_STATE_FILE"
        write_uri_files
        service_is_running() { return 1; }
        service_is_enabled() { return 1; }
        sing-box() {
            [ "${1:-}" != check ] || return 1
        }

        begin_node_transaction static ||
            fail "静态事务校验不应依赖 sing-box check"
        [ -f "$NODE_TRANSACTION_DIR/pending" ] ||
            fail "静态事务校验成功后应建立 pending 标记"
        cancel_unmodified_node_transaction ||
            fail "静态事务测试完成后应能清理未修改事务"

        if begin_node_transaction full > "$TEST_TMP/full-transaction-check.out" 2>&1; then
            fail "完整事务校验必须拒绝 sing-box check 失败的备份"
        fi
        [ ! -e "$NODE_TRANSACTION_DIR" ] ||
            fail "完整事务校验失败后不得保留未生效事务目录"
        assert_file_contains "$TEST_TMP/full-transaction-check.out" '未通过 sing-box 配置检查'
    )
}

test_node_transaction_restores_service_manager_state() {
    (
        local backup="$TEST_TMP/service-manager-state-backup"
        local service_active=1 service_enabled=1 restored_process_requirement=""

        set_node_paths "$TEST_TMP/service-manager-state"
        service_manager_is_active() { [ "$service_active" -eq 1 ]; }
        service_is_enabled() { [ "$service_enabled" -eq 1 ]; }
        # 模拟 active 的自定义/旧 -c 服务：服务管理器可见，但不匹配 VPSBox -C 进程。
        service_is_running() { return 1; }

        backup_node_files "$backup"
        assert_eq 1 "$(cat "$backup/service-running")" \
            "节点事务必须记录服务管理器原本的 active 状态"
        assert_eq 1 "$(cat "$backup/service-enabled")" \
            "节点事务必须记录服务管理器原本的 enabled 状态"

        service_active=0
        service_enabled=0
        service_stop() { service_active=0; }
        stop_singbox_config_processes() { return 0; }
        singbox_config_pids() { return 0; }
        service_enable() { service_enabled=1; }
        service_disable() { service_enabled=0; }
        restart_singbox_cleanly() {
            restored_process_requirement="${1:-}"
            service_active=1
            service_manager_is_active
        }
        is_systemd() { return 1; }
        OS=unknown
        : "$OS"
        repair_node_uri_cache_best_effort() { return 0; }

        restore_node_files "$backup" >/dev/null
        [ "$service_active" -eq 1 ] ||
            fail "节点事务恢复后必须重新激活原 active 服务"
        [ "$service_enabled" -eq 1 ] ||
            fail "节点事务恢复后必须恢复原 enabled 状态"
        assert_eq 0 "$restored_process_requirement" \
            "恢复自定义或旧布局服务时只验证服务管理器 active，不要求匹配 VPSBox -C 进程"
    )
}

test_dual_node_backup_restore_round_trip() {
    (
        local backup="$TEST_TMP/dual-backup"
        set_node_paths "$TEST_TMP/backup-round-trip"
        mkdir -p "$NODE_CONFIG_DIR"
        write_ss_config_fixture "$SS_CONFIG_PATH"
        write_vless_config_fixture "$VLESS_CONFIG_PATH"
        write_ss_state_fixture "$SS_STATE_FILE"
        write_vless_state_fixture "$VLESS_STATE_FILE"
        write_uri_files

        service_is_running() { return 1; }
        service_is_enabled() { return 1; }
        backup_node_files "$backup"

        printf 'broken\n' > "$SS_CONFIG_PATH"
        rm -f "$VLESS_CONFIG_PATH" "$SS_STATE_FILE" "$VLESS_STATE_FILE" \
            "$SS_URI_FILE" "$VLESS_URI_FILE" "$URI_FILE"

        service_stop() { return 0; }
        stop_singbox_config_processes() { return 0; }
        service_manager_is_active() { return 1; }
        singbox_config_pids() { return 0; }
        is_systemd() { return 1; }
        OS=unknown
        : "$OS"
        service_disable() { return 0; }
        service_is_enabled() { return 1; }
        singbox_installed() { return 1; }

        restore_node_files "$backup" >/dev/null

        assert_file_contains "$SS_CONFIG_PATH" '"type": "shadowsocks"'
        assert_file_contains "$VLESS_CONFIG_PATH" '"type": "vless"'
        assert_file_contains "$SS_STATE_FILE" '^PROTOCOL=shadowsocks$'
        assert_file_contains "$VLESS_STATE_FILE" '^PROTOCOL=vless-reality$'
        assert_file_contains "$URI_FILE" '^ss://'
    )
}

test_verify_runtime_checks_both_protocols() {
    (
        local checked=""
        service_is_running() { return 0; }
        protocol_visible_exists() { return 0; }
        load_protocol_state() {
            if [ "$1" = vless ]; then
                PORT=20002
                REALITY_PRIVATE_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
            else
                PORT=20001
            fi
            : "$PORT" "${REALITY_PRIVATE_KEY:-}"
        }
        wait_for_port_listener() {
            checked="${checked}${1}:$2 "
        }

        verify_all_node_runtime
        assert_eq "20002:tcp 20001:both " "$checked"
    )
}

test_cancel_eof_and_input_interrupt_have_no_mutation() {
    (
        local event_log="$TEST_TMP/cancel-no-mutation.events"
        set_node_paths "$TEST_TMP/cancel-no-mutation"
        : > "$event_log"
        require_valid_node_state_if_present() { return 0; }
        protocol_visible_exists() { return 1; }
        configured_node_ports_csv() { printf '\n'; }
        prompt_node_host() { printf -v "$1" '%s' ss.example.com; }
        choose_node_port() { printf '%s\n' 20001; }
        confirm_default_yes() { return 1; }
        begin_node_transaction() { printf 'transaction\n' >> "$event_log"; }
        install_singbox_if_missing() { printf 'install\n' >> "$event_log"; }
        service_stop() { printf 'stop\n' >> "$event_log"; }
        restart_singbox_cleanly() { printf 'restart\n' >> "$event_log"; }
        firewall_prepare_port_transition() { printf 'firewall\n' >> "$event_log"; }

        create_or_rebuild_node <<< $'\n' >/dev/null
        assert_empty_file "$event_log" "最终取消不得停止服务、安装依赖或刷新防火墙"
    )
    (
        local event_log="$TEST_TMP/eof-no-mutation.events"
        set_node_paths "$TEST_TMP/eof-no-mutation"
        : > "$event_log"
        require_valid_node_state_if_present() { return 0; }
        protocol_visible_exists() { return 1; }
        configured_node_ports_csv() { printf '\n'; }
        prompt_node_host() { printf -v "$1" '%s' ss.example.com; }
        begin_node_transaction() { printf 'transaction\n' >> "$event_log"; }
        service_stop() { printf 'stop\n' >> "$event_log"; }
        firewall_refresh_if_enabled() { printf 'firewall\n' >> "$event_log"; }

        if create_or_rebuild_node </dev/null >/dev/null 2>&1; then
            fail "名称输入遇到 EOF 时应取消创建"
        fi
        assert_empty_file "$event_log" "EOF 不得建立事务、停止服务或刷新防火墙"
    )
    (
        local event_log="$TEST_TMP/interrupt-no-mutation.events"
        set_node_paths "$TEST_TMP/interrupt-no-mutation"
        : > "$event_log"
        require_valid_node_state_if_present() { return 0; }
        protocol_visible_exists() { return 1; }
        configured_node_ports_csv() { printf '\n'; }
        prompt_node_host() { return 130; }
        begin_node_transaction() { printf 'transaction\n' >> "$event_log"; }
        service_stop() { printf 'stop\n' >> "$event_log"; }
        firewall_refresh_if_enabled() { printf 'firewall\n' >> "$event_log"; }

        if create_or_rebuild_node >/dev/null 2>&1; then
            fail "输入阶段中断时应取消创建"
        fi
        assert_empty_file "$event_log" "输入阶段 Ctrl+C 不得建立事务或触发服务、防火墙操作"
    )
}

write_state_lines() {
    local file="$1"
    shift
    printf '%s\n' "$@" > "$file"
    chmod 600 "$file"
    command chown root:root "$file" 2>/dev/null || true
}

test_failed_rollback_must_not_claim_state_was_restored() {
    (
        local out="$TEST_TMP/failed-rollback-message.out"

        rollback_active_node_transaction() { return 1; }
        if fail_after_node_rollback "配置写入失败" "创建前" > "$out" 2>&1; then
            fail "回滚失败时原始操作不得报告成功"
        fi
        assert_file_not_contains "$out" '已恢复到创建前状态' \
            "回滚失败后不得宣称节点已经恢复"
        assert_file_contains "$out" '未能确认完整恢复'

        rollback_active_node_transaction() { return 0; }
        if fail_after_node_rollback "配置写入失败" "创建前" > "$out" 2>&1; then
            fail "操作失败时即使回滚成功也必须返回失败"
        fi
        assert_file_contains "$out" '已恢复到创建前状态'
    )
}

test_node_rollback_firewall_failure_is_partial_success() {
    (
        local output="$TEST_TMP/node-rollback-firewall-warning.out"
        set_node_paths "$TEST_TMP/node-rollback-firewall-warning"
        mkdir -p "$NODE_CONFIG_DIR"
        write_ss_config_fixture "$SS_CONFIG_PATH"
        write_ss_state_fixture "$SS_STATE_FILE"
        write_uri_files
        service_is_running() { return 1; }
        service_is_enabled() { return 1; }
        begin_node_transaction
        mark_node_transaction_mutated
        printf 'broken\n' > "$SS_CONFIG_PATH"

        service_stop() { return 0; }
        stop_singbox_config_processes() { return 0; }
        service_manager_is_active() { return 1; }
        singbox_config_pids() { return 0; }
        service_disable() { return 0; }
        is_systemd() { return 1; }
        OS=unknown
        : "$OS"
        firewall_refresh_if_enabled() { return 1; }

        rollback_active_node_transaction > "$output" 2>&1 ||
            fail "节点已恢复时，单独的防火墙同步失败不得把节点回滚判成失败"
        assert_file_contains "$SS_CONFIG_PATH" '"type": "shadowsocks"'
        [ ! -e "$NODE_TRANSACTION_DIR" ] ||
            fail "节点恢复成功后必须清理节点事务目录"
        assert_file_contains "$output" '主机防火墙端口未能同步'
        assert_file_not_contains "$output" '备份已保留'
    )
}

test_node_backup_file_safety_enforces_owner_and_mode() {
    (
        local dir="$TEST_TMP/backup-file-safety" file

        if [ "$DUAL_NODES_REAL_PERMISSIONS" -ne 1 ]; then
            skip "需要真实的 root 属主与 Unix 权限语义"
            return "$SKIP_STATUS"
        fi
        mkdir -p "$dir"
        file="$dir/service-running"
        : > "$file"
        command chown root:root "$file"
        chmod 600 "$file"
        node_backup_file_is_safe "$file" ||
            fail "root 属主且 600 的事务备份文件应被接受"

        chmod 620 "$file"
        if node_backup_file_is_safe "$file"; then
            fail "组可写的事务备份文件必须被拒绝"
        fi
        chmod 602 "$file"
        if node_backup_file_is_safe "$file"; then
            fail "其他用户可写的事务备份文件必须被拒绝"
        fi
        chmod 600 "$file"
        command chown 65534:65534 "$file"
        if node_backup_file_is_safe "$file"; then
            fail "属主不是 root 的事务备份文件必须被拒绝"
        fi
    )
}

test_interrupted_restore_leaves_node_config_dir_usable() {
    (
        local snapshot="$TEST_TMP/interrupted-restore-source"
        set_node_paths "$TEST_TMP/interrupted-restore"
        mkdir -p "$NODE_CONFIG_DIR"
        write_ss_config_fixture "$SS_CONFIG_PATH"
        write_ss_state_fixture "$SS_STATE_FILE"
        write_uri_files
        write_ss_config_fixture "$snapshot" 20009

        node_config_dir_contents_valid ||
            fail "夹具本身必须是一个合法的节点配置目录"
        mv() { return 42; }
        rm() { return 0; }
        if restore_file_atomically_from_snapshot "$snapshot" "$SS_CONFIG_PATH"; then
            fail "替换失败时原子恢复不得报告成功"
        fi
        unset -f mv rm

        node_config_dir_contents_valid ||
            fail "恢复中断后，节点配置目录不得被临时文件顶死"
        assert_file_contains "$SS_CONFIG_PATH" '"listen_port": 20001' \
            "替换失败时必须保留原节点配置"
    )
}

test_atomic_staging_rejects_cross_device_node_directory() {
    (
        local target output="$TEST_TMP/cross-device-staging.out"
        set_node_paths "$TEST_TMP/cross-device-staging"
        mkdir -p "$NODE_CONFIG_DIR"
        target="$SS_CONFIG_PATH"
        stat() {
            case "${*: -1}" in
                "$CONFIG_DIR") printf '101\n' ;;
                "$NODE_CONFIG_DIR") printf '202\n' ;;
                *) command stat "$@" ;;
            esac
        }
        if atomic_staging_dir "$target" > "$output" 2>&1; then
            fail "节点目录跨文件系统时不得声称可以原子替换"
        fi
        assert_file_contains "$output" '不在同一文件系统'
    )
}

test_state_file_field_validation_rejects_malformed_values() {
    (
        local dir="$TEST_TMP/state-validation" file case_name
        local -a ss_valid vless_valid line_set

        mkdir -p "$dir"
        file="$dir/state.env"
        ss_valid=(
            'PROTOCOL=shadowsocks'
            'CONFIG_ID=111111111111111111111111'
            'DOMAIN=ss.example.com'
            'NAME=ss-node'
            'PORT=20001'
            'PASSWORD=QUFBQUFBQUFBQUFBQUFBQQ=='
            "METHOD=$SS_METHOD"
        )
        vless_valid=(
            'PROTOCOL=vless-reality'
            'CONFIG_ID=222222222222222222222222'
            'DOMAIN=vless.example.com'
            'NAME=vless-node'
            'PORT=20002'
            'UUID=11111111-2222-4333-8444-555555555555'
            'FLOW=xtls-rprx-vision'
            'REALITY_SERVER_NAME=addons.mozilla.org'
            'REALITY_PRIVATE_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
            'REALITY_PUBLIC_KEY=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB'
            'REALITY_SHORT_ID=0123456789abcdef'
            'FINGERPRINT=chrome'
        )

        write_state_lines "$file" "${ss_valid[@]}"
        load_state_file "$file" shadowsocks ||
            fail "合法的 Shadowsocks 状态文件必须被接受"
        assert_eq 20001 "$PORT" "接受后必须发布端口"
        write_state_lines "$file" "${vless_valid[@]}"
        load_state_file "$file" vless-reality ||
            fail "合法的 VLESS Reality 状态文件必须被接受"
        assert_eq addons.mozilla.org "$REALITY_SERVER_NAME" "接受后必须发布 Reality 域名"

        reject_ss() {
            case_name="$1"
            shift
            line_set=("${ss_valid[@]}")
            write_state_lines "$file" "${line_set[@]/$1/$2}"
            if load_state_file "$file" shadowsocks; then
                fail "Shadowsocks 状态校验必须拒绝：$case_name"
            fi
        }
        reject_vless() {
            case_name="$1"
            shift
            line_set=("${vless_valid[@]}")
            write_state_lines "$file" "${line_set[@]/$1/$2}"
            if load_state_file "$file" vless-reality; then
                fail "VLESS Reality 状态校验必须拒绝：$case_name"
            fi
        }

        reject_ss '端口超出范围' 'PORT=20001' 'PORT=999999'
        reject_ss '端口为零' 'PORT=20001' 'PORT=0'
        reject_ss '端口非数字' 'PORT=20001' 'PORT=abc'
        reject_ss '域名非法' 'DOMAIN=ss.example.com' 'DOMAIN=bad host'
        reject_ss '名称含非法字符' 'NAME=ss-node' 'NAME=ss node;rm'
        reject_ss 'CONFIG_ID 过短' 'CONFIG_ID=111111111111111111111111' 'CONFIG_ID=1111'
        reject_ss 'CONFIG_ID 非十六进制' 'CONFIG_ID=111111111111111111111111' 'CONFIG_ID=zzzzzzzzzzzzzzzzzzzzzzzz'
        reject_ss '密码含非法字符' 'PASSWORD=QUFBQUFBQUFBQUFBQUFBQQ==' 'PASSWORD=abc$(id)'
        reject_ss '加密方式不受支持' "METHOD=$SS_METHOD" 'METHOD=rc4-md5'
        reject_vless 'UUID 格式错误' 'UUID=11111111-2222-4333-8444-555555555555' 'UUID=not-a-uuid'
        reject_vless 'flow 不受支持' 'FLOW=xtls-rprx-vision' 'FLOW=none'
        reject_vless 'Reality 域名非法' 'REALITY_SERVER_NAME=addons.mozilla.org' 'REALITY_SERVER_NAME=-bad-'
        reject_vless 'Reality 私钥格式错误' \
            'REALITY_PRIVATE_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' 'REALITY_PRIVATE_KEY=short'
        reject_vless 'Reality 公钥格式错误' \
            'REALITY_PUBLIC_KEY=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB' 'REALITY_PUBLIC_KEY=short'
        reject_vless 'Reality short_id 格式错误' \
            'REALITY_SHORT_ID=0123456789abcdef' 'REALITY_SHORT_ID=xyz'
        reject_vless 'fingerprint 不受支持' 'FINGERPRINT=chrome' 'FINGERPRINT=firefox'

        write_state_lines "$file" "${ss_valid[@]}"
        if load_state_file "$file" vless-reality; then
            fail "状态校验必须拒绝：协议与期望不符"
        fi
        write_state_lines "$file" "${ss_valid[@]}" 'EXTRA=1'
        if load_state_file "$file" shadowsocks; then
            fail "状态校验必须拒绝：出现未知键"
        fi
        write_state_lines "$file" "${ss_valid[@]}" 'PORT=20002'
        if load_state_file "$file" shadowsocks; then
            fail "状态校验必须拒绝：同一个键出现两次"
        fi

        write_state_lines "$file" "${ss_valid[@]/PORT=20001/PORT=020001}"
        load_state_file "$file" shadowsocks ||
            fail "历史状态文件中的前导零端口必须继续被接受"
        assert_eq 20001 "$(normalize_port_decimal "$PORT")" \
            "前导零端口必须规范化为相同十进制值"
    )
}

test_firewall_sync_failure_does_not_block_node_transaction_completion() {
    (
        local output="$TEST_TMP/firewall-not-blocking.out"
        local order_log="$TEST_TMP/firewall-not-blocking.order"
        set_node_paths "$TEST_TMP/firewall-not-blocking"
        mkdir -p "$NODE_CONFIG_DIR"
        write_ss_config_fixture "$SS_CONFIG_PATH"
        write_ss_state_fixture "$SS_STATE_FILE"
        write_uri_files
        service_is_running() { return 1; }
        service_is_enabled() { return 1; }

        begin_node_transaction
        mark_node_transaction_mutated
        printf 'broken\n' > "$SS_CONFIG_PATH"
        rm -f "$SS_STATE_FILE" "$URI_FILE" "$SS_URI_FILE"
        ACTIVE_NODE_BACKUP=""

        service_stop() { return 0; }
        stop_singbox_config_processes() { return 0; }
        service_manager_is_active() { return 1; }
        singbox_config_pids() { return 0; }
        service_disable() { return 0; }
        is_systemd() { return 1; }
        OS=unknown
        : "$OS"
        : > "$order_log"
        firewall_refresh_if_enabled() {
            [ -d "$NODE_TRANSACTION_DIR" ] || printf '%s\n' missing-transaction >> "$order_log"
            printf '%s\n' firewall-refresh >> "$order_log"
            return 1
        }

        recover_pending_node_transaction > "$output" 2>&1 ||
            fail "节点文件已恢复时，防火墙同步失败不得阻断节点事务"
        assert_file_contains "$SS_CONFIG_PATH" '"type": "shadowsocks"'
        assert_file_contains "$SS_STATE_FILE" '^PROTOCOL=shadowsocks$'
        [ ! -e "$NODE_TRANSACTION_DIR" ] ||
            fail "节点已恢复后必须清理事务目录"
        assert_file_not_contains "$order_log" '^missing-transaction$' \
            "防火墙刷新完成前必须保留 pending 事务，以便硬中断后重试"
        assert_file_contains "$output" '主机防火墙端口未能同步'
        assert_file_not_contains "$output" '已完整恢复'
    )
}

test_unrecovered_pending_transaction_blocks_new_operation() {
    (
        local output="$TEST_TMP/pending-blocks-new.out"
        set_node_paths "$TEST_TMP/pending-blocks-new"
        mkdir -p "$NODE_CONFIG_DIR"
        write_ss_config_fixture "$SS_CONFIG_PATH"
        write_ss_state_fixture "$SS_STATE_FILE"
        write_uri_files
        service_is_running() { return 1; }
        service_is_enabled() { return 1; }

        begin_node_transaction || fail "首次节点事务应能建立"
        mark_node_transaction_mutated
        printf 'broken\n' > "$SS_CONFIG_PATH"
        ACTIVE_NODE_BACKUP=""

        if begin_node_transaction > "$output" 2>&1; then
            fail "存在未恢复的 pending 事务时不得开始新操作"
        fi
        assert_file_contains "$output" '尚未恢复的节点事务'
        [ -f "$NODE_TRANSACTION_DIR/pending" ] ||
            fail "被拒绝的新操作不得清除 pending 标记"
        assert_file_contains \
            "$NODE_TRANSACTION_BACKUP/vpsbox.d/${SS_CONFIG_PATH##*/}" \
            '"type": "shadowsocks"' \
            "被拒绝的新操作不得覆盖改动前的备份"
    )
}

test_pending_transaction_recovers_after_hard_interruption() {
    (
        set_node_paths "$TEST_TMP/pending-recovery"
        mkdir -p "$NODE_CONFIG_DIR"
        write_ss_config_fixture "$SS_CONFIG_PATH"
        write_ss_state_fixture "$SS_STATE_FILE"
        write_uri_files
        service_is_running() { return 1; }
        service_is_enabled() { return 1; }

        begin_node_transaction
        mark_node_transaction_mutated
        printf 'broken\n' > "$SS_CONFIG_PATH"
        rm -f "$SS_STATE_FILE" "$URI_FILE" "$SS_URI_FILE"
        ACTIVE_NODE_BACKUP=""

        service_stop() { return 0; }
        stop_singbox_config_processes() { return 0; }
        service_manager_is_active() { return 1; }
        singbox_config_pids() { return 0; }
        service_disable() { return 0; }
        service_is_enabled() { return 1; }
        firewall_refresh_if_enabled() { return 0; }
        is_systemd() { return 1; }
        OS=unknown

        recover_pending_node_transaction >/dev/null

        assert_file_contains "$SS_STATE_FILE" '^CONFIG_ID=111111111111111111111111$'
        assert_file_contains "$SS_CONFIG_PATH" '"type": "shadowsocks"'
        assert_file_contains "$URI_FILE" '^ss://'
        [ ! -e "$NODE_TRANSACTION_DIR" ] || fail "恢复完成后应清理 pending 事务"
    )
}

test_absent_backup_entry_removes_target_and_invalid_entry_is_rejected() {
    (
        local backup_dir target

        backup_dir="$TEST_TMP/restore-entry-status/backup"
        target="$TEST_TMP/restore-entry-status/target"
        mkdir -p "$backup_dir"
        printf 'current\n' > "$target"
        node_backup_entry_is_present() { return 1; }

        restore_node_file_from_backup "$backup_dir" absent "$backup_dir/unused" "$target"
        [ ! -e "$target" ] || fail "备份清单标记 absent 时应删除当前目标文件"

        printf 'current\n' > "$target"
        node_backup_entry_is_present() { return 2; }
        if restore_node_file_from_backup "$backup_dir" invalid "$backup_dir/unused" "$target"; then
            fail "备份清单条目无效时不得继续恢复"
        fi
        assert_file_contains "$target" '^current$' "条目无效时不得删除当前目标文件"
    )
}

test_absent_node_directory_backup_removes_dangling_link() {
    (
        local base="$TEST_TMP/restore-dangling-node-dir" backup_dir missing

        require_real_symlink directory || return "$?"
        set_node_paths "$base"
        backup_dir="$base/backup"
        missing="$base/missing-vpsbox.d"
        mkdir -p "$backup_dir" "$(dirname "$NODE_CONFIG_DIR")"
        : > "$backup_dir/manifest"
        ln -s "$missing" "$NODE_CONFIG_DIR"
        node_backup_entry_is_present() { return 1; }

        restore_node_config_dir_from_backup "$backup_dir" full

        [ ! -e "$NODE_CONFIG_DIR" ] && [ ! -L "$NODE_CONFIG_DIR" ] ||
            fail "原目录不存在时，回滚必须移除事务期间出现的悬空节点目录链接"
        [ ! -e "$missing" ] || fail "回滚不得创建悬空链接原本指向的目录"
    )
}

test_unmodified_pending_transaction_is_discarded_without_service_stop() {
    (
        forbid_init
        set_node_paths "$TEST_TMP/pending-unmodified"
        mkdir -p "$NODE_CONFIG_DIR"
        write_ss_config_fixture "$SS_CONFIG_PATH"
        write_ss_state_fixture "$SS_STATE_FILE"
        write_uri_files
        service_is_running() { return 1; }
        service_is_enabled() { return 1; }
        begin_node_transaction
        ACTIVE_NODE_BACKUP=""
        service_stop() { forbid "尚未修改节点文件时不得停止 sing-box"; }

        recover_pending_node_transaction >/dev/null

        assert_file_contains "$SS_CONFIG_PATH" '"type": "shadowsocks"'
        [ ! -e "$NODE_TRANSACTION_DIR" ] ||
            fail "没有 mutated 标记的 pending 事务应直接清理"
        assert_no_forbidden "未修改的 pending 事务停止了 sing-box"
    )
}

test_corrupted_node_backup_is_rejected_before_overwrite() {
    (
        forbid_init
        set_node_paths "$TEST_TMP/pending-corrupt"
        mkdir -p "$NODE_CONFIG_DIR"
        write_ss_config_fixture "$SS_CONFIG_PATH"
        write_ss_state_fixture "$SS_STATE_FILE"
        write_uri_files
        service_is_running() { return 1; }
        service_is_enabled() { return 1; }
        begin_node_transaction
        mark_node_transaction_mutated
        printf '%s\n' tampered >> "$NODE_TRANSACTION_BACKUP/ss-state.env"
        printf '%s\n' current-live > "$SS_CONFIG_PATH"
        ACTIVE_NODE_BACKUP=""
        service_stop() { forbid "备份校验失败时不得停止或覆盖现有服务"; }

        if recover_pending_node_transaction >/dev/null 2>&1; then
            fail "哈希损坏的节点备份不得自动恢复"
        fi
        assert_file_contains "$SS_CONFIG_PATH" '^current-live$'
        [ -d "$NODE_TRANSACTION_BACKUP" ] ||
            fail "损坏的事务备份必须保留供人工处理"
        assert_no_forbidden "损坏备份校验失败后停止了现有服务"
    )
}

test_failed_recovery_keeps_transaction_backup() {
    (
        set_node_paths "$TEST_TMP/pending-stop-failure"
        mkdir -p "$NODE_CONFIG_DIR"
        write_ss_config_fixture "$SS_CONFIG_PATH"
        write_ss_state_fixture "$SS_STATE_FILE"
        write_uri_files
        service_is_running() { return 1; }
        service_is_enabled() { return 1; }
        begin_node_transaction
        mark_node_transaction_mutated
        printf 'broken\n' > "$SS_CONFIG_PATH"
        ACTIVE_NODE_BACKUP=""

        service_stop() { return 1; }
        stop_singbox_config_processes() { return 1; }
        service_manager_is_active() { return 0; }
        singbox_config_pids() { printf '%s\n' 1234; }

        if recover_pending_node_transaction > "$TEST_TMP/pending-stop-failure.out" 2>&1; then
            fail "服务或残留进程未停止时恢复不得成功"
        fi
        [ -f "$NODE_TRANSACTION_DIR/pending" ] ||
            fail "恢复失败后必须保留 pending 标记"
        [ -d "$NODE_TRANSACTION_BACKUP" ] ||
            fail "恢复失败后必须保留节点备份"
        assert_file_contains "$SS_CONFIG_PATH" '^broken$' \
            "停止失败时不得开始覆盖现有文件"
    )
}

test_committed_transaction_is_not_rolled_back() {
    (
        forbid_init
        set_node_paths "$TEST_TMP/committed-recovery"
        mkdir -p "$NODE_CONFIG_DIR"
        write_ss_config_fixture "$SS_CONFIG_PATH"
        write_ss_state_fixture "$SS_STATE_FILE"
        write_uri_files
        service_is_running() { return 1; }
        service_is_enabled() { return 1; }
        begin_node_transaction
        printf 'committed-new-state\n' > "$SS_CONFIG_PATH"
        : > "$NODE_TRANSACTION_DIR/committed"
        chmod 600 "$NODE_TRANSACTION_DIR/committed"
        # shellcheck disable=SC2034 # 被被测的事务恢复函数动态读取。
        ACTIVE_NODE_BACKUP=""
        service_stop() { forbid "committed 事务不得触发操作前状态恢复"; }

        recover_pending_node_transaction >/dev/null

        assert_file_contains "$SS_CONFIG_PATH" '^committed-new-state$'
        [ ! -e "$NODE_TRANSACTION_DIR" ] || fail "committed 残留事务应只清理目录"
        assert_no_forbidden "committed 事务触发了操作前状态恢复"
    )
}

test_node_commit_cleanup_sync_failure_keeps_committed_state() {
    (
        local sync_calls=0

        forbid_init
        set_node_paths "$TEST_TMP/committed-cleanup-sync-failure"
        mkdir -p "$NODE_CONFIG_DIR"
        write_ss_config_fixture "$SS_CONFIG_PATH"
        write_ss_state_fixture "$SS_STATE_FILE"
        write_uri_files
        service_is_running() { return 1; }
        service_is_enabled() { return 1; }
        begin_node_transaction
        mark_node_transaction_mutated
        printf 'committed-new-state\n' > "$SS_CONFIG_PATH"
        sync_node_transaction_store() {
            sync_calls=$((sync_calls + 1))
            [ "$sync_calls" -eq 1 ]
        }
        service_stop() { forbid "committed 后的清理同步失败不得触发节点回滚"; }

        commit_node_transaction >/dev/null ||
            fail "committed 已持久化后，清理同步失败不得把提交改判为失败"
        assert_eq "" "$ACTIVE_NODE_BACKUP" "提交点后必须立即清除活动事务句柄"
        assert_eq 0 "$ACTIVE_NODE_TRANSACTION_MUTATED" "提交点后必须清除 mutated 运行状态"
        [ -f "$NODE_TRANSACTION_DIR/committed" ] ||
            fail "清理同步失败时应保留 committed 事务供启动清理"
        [ ! -e "$NODE_TRANSACTION_DIR/pending" ] ||
            fail "清理同步失败发生前 pending 应已删除"

        recover_pending_node_transaction >/dev/null

        assert_file_contains "$SS_CONFIG_PATH" '^committed-new-state$'
        [ ! -e "$NODE_TRANSACTION_DIR" ] || fail "启动恢复应只清理 committed 残留目录"
        assert_no_forbidden "committed 后的清理同步失败触发了节点回滚"
    )
}

test_node_commit_pending_cleanup_failure_keeps_committed_state() {
    (
        forbid_init
        set_node_paths "$TEST_TMP/committed-pending-cleanup-failure"
        mkdir -p "$NODE_CONFIG_DIR"
        write_ss_config_fixture "$SS_CONFIG_PATH"
        write_ss_state_fixture "$SS_STATE_FILE"
        write_uri_files
        service_is_running() { return 1; }
        service_is_enabled() { return 1; }
        begin_node_transaction
        mark_node_transaction_mutated
        printf 'committed-new-state\n' > "$SS_CONFIG_PATH"
        rm() {
            if [ "$#" -eq 3 ] && [ "$1" = -f ] && [ "$2" = -- ] &&
                [ "$3" = "$NODE_TRANSACTION_DIR/pending" ]; then
                return 42
            fi
            command rm "$@"
        }
        service_stop() { forbid "committed 后 pending 清理失败不得触发节点回滚"; }

        commit_node_transaction >/dev/null ||
            fail "committed 已持久化后，pending 清理失败不得把提交改判为失败"
        assert_eq "" "$ACTIVE_NODE_BACKUP" "提交点后必须立即清除活动事务句柄"
        [ -f "$NODE_TRANSACTION_DIR/committed" ] || fail "必须保留 committed 标记"
        [ -f "$NODE_TRANSACTION_DIR/pending" ] || fail "失败的 pending 清理应保留原标记"

        recover_pending_node_transaction >/dev/null

        assert_file_contains "$SS_CONFIG_PATH" '^committed-new-state$'
        [ ! -e "$NODE_TRANSACTION_DIR" ] || fail "启动恢复应清理 committed 残留目录"
        assert_no_forbidden "committed 后 pending 清理失败触发了节点回滚"
    )
}

test_node_commit_marker_sync_failure_keeps_active_transaction() {
    (
        set_node_paths "$TEST_TMP/commit-marker-sync-failure"
        mkdir -p "$NODE_CONFIG_DIR"
        write_ss_config_fixture "$SS_CONFIG_PATH"
        write_ss_state_fixture "$SS_STATE_FILE"
        write_uri_files
        service_is_running() { return 1; }
        service_is_enabled() { return 1; }
        begin_node_transaction
        mark_node_transaction_mutated
        sync_node_transaction_store() { return 42; }

        if commit_node_transaction >/dev/null 2>&1; then
            fail "committed 标记未持久化时事务提交必须失败"
        fi
        assert_eq "$NODE_TRANSACTION_DIR" "$ACTIVE_NODE_BACKUP" \
            "越过提交点前失败必须保留活动事务供调用者回滚"
        [ -f "$NODE_TRANSACTION_DIR/pending" ] || fail "提交点前失败必须保留 pending 标记"
    )
}

test_config_state_identity_and_credentials_must_match() {
    (
        set_node_paths "$TEST_TMP/mismatch-ss-id"
        mkdir -p "$NODE_CONFIG_DIR"
        write_ss_config_fixture "$SS_CONFIG_PATH"
        write_ss_state_fixture "$SS_STATE_FILE" 20001 999999999999999999999999
        if validate_protocol_node_core ss "$SS_CONFIG_PATH" "$SS_STATE_FILE"; then
            fail "配置标识不一致时 Shadowsocks 完整性校验不得通过"
        fi
    )
    (
        set_node_paths "$TEST_TMP/mismatch-ss-password"
        mkdir -p "$NODE_CONFIG_DIR"
        write_ss_config_fixture "$SS_CONFIG_PATH"
        write_ss_state_fixture "$SS_STATE_FILE"
        sed -i 's/^PASSWORD=.*/PASSWORD=TkVXTkVXTkVXTkVXTkVXQQ==/' "$SS_STATE_FILE"
        if validate_protocol_node_core ss "$SS_CONFIG_PATH" "$SS_STATE_FILE"; then
            fail "Shadowsocks 密码不一致时完整性校验不得通过"
        fi
    )
    (
        set_node_paths "$TEST_TMP/mismatch-vless-port"
        mkdir -p "$NODE_CONFIG_DIR"
        write_vless_config_fixture "$VLESS_CONFIG_PATH"
        write_vless_state_fixture "$VLESS_STATE_FILE" 29999
        if validate_protocol_node_core vless "$VLESS_CONFIG_PATH" "$VLESS_STATE_FILE"; then
            fail "VLESS 端口不一致时完整性校验不得通过"
        fi
    )
    (
        set_node_paths "$TEST_TMP/mismatch-vless-credentials"
        mkdir -p "$NODE_CONFIG_DIR"
        write_vless_config_fixture "$VLESS_CONFIG_PATH"
        write_vless_state_fixture "$VLESS_STATE_FILE"
        sed -i \
            -e 's/^UUID=.*/UUID=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee/' \
            -e 's/^REALITY_PRIVATE_KEY=.*/REALITY_PRIVATE_KEY=CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC/' \
            "$VLESS_STATE_FILE"
        if validate_protocol_node_core vless "$VLESS_CONFIG_PATH" "$VLESS_STATE_FILE"; then
            fail "VLESS UUID 或 Reality 私钥不一致时完整性校验不得通过"
        fi
    )
}

test_protocol_status_distinguishes_template_drift_from_damage() {
    (
        set_node_paths "$TEST_TMP/status-normal"
        listen_mode() { printf '%s\n' ipv4; }
        write_config \
            20001 QUFBQUFBQUFBQUFBQUFBQQ== 111111111111111111111111 \
            "$SS_CONFIG_PATH" >/dev/null
        write_ss_state_fixture "$SS_STATE_FILE"

        validate_protocol_node_core ss "$SS_CONFIG_PATH" "$SS_STATE_FILE" ||
            fail "vpsbox 当前生成模板必须通过核心完整性校验"
        node_config_matches_vpsbox_template ss "$SS_CONFIG_PATH" ||
            fail "vpsbox 当前生成模板必须被识别为标准模板"
        assert_eq normal "$(protocol_node_status ss)" \
            "vpsbox 当前生成模板的节点状态应为 normal"
    )
    (
        local output="$TEST_TMP/status-vless-template.out"

        set_node_paths "$TEST_TMP/status-vless-template"
        mkdir -p "$NODE_CONFIG_DIR"
        write_vless_config_fixture "$VLESS_CONFIG_PATH"
        write_vless_state_fixture "$VLESS_STATE_FILE"

        assert_eq normal "$(protocol_node_status vless)" \
            "VLESS 当前生成模板的节点状态应为 normal"
        sed -i 's/"listen": "0.0.0.0"/"listen": "::1"/' "$VLESS_CONFIG_PATH"
        assert_eq deviated "$(protocol_node_status vless)" \
            "VLESS 自定义监听地址应标记为 deviated，而不是损坏"
        node_summary > "$output"
        assert_file_contains "$output" \
            '状态：已创建（配置已偏离 VPSBox 管理模板）' \
            "主界面必须把合法自定义 VLESS 配置显示为偏离模板"

        write_vless_config_fixture "$VLESS_CONFIG_PATH"
        jq '.outbounds[0].type = "block"' \
            "$VLESS_CONFIG_PATH" > "$VLESS_CONFIG_PATH.tmp"
        mv "$VLESS_CONFIG_PATH.tmp" "$VLESS_CONFIG_PATH"
        chmod 600 "$VLESS_CONFIG_PATH"
        assert_eq deviated "$(protocol_node_status vless)" \
            "VLESS 自定义出站应标记为 deviated，而不是损坏"
    )
    (
        set_node_paths "$TEST_TMP/status-vless-extra-credentials"
        mkdir -p "$NODE_CONFIG_DIR"
        write_vless_config_fixture "$VLESS_CONFIG_PATH"
        write_vless_state_fixture "$VLESS_STATE_FILE"
        jq '
            .inbounds[].users += [{
                "name": "extra",
                "uuid": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
                "flow": "xtls-rprx-vision"
            }] |
            .inbounds[].tls.reality.short_id += ["fedcba9876543210"]
        ' "$VLESS_CONFIG_PATH" > "$VLESS_CONFIG_PATH.tmp"
        mv "$VLESS_CONFIG_PATH.tmp" "$VLESS_CONFIG_PATH"
        chmod 600 "$VLESS_CONFIG_PATH"

        validate_protocol_node_core vless "$VLESS_CONFIG_PATH" "$VLESS_STATE_FILE" ||
            fail "额外 VLESS user 或 short_id 不应破坏配置与状态的核心一致性"
        check_node_config_set ||
            fail "合法的额外 VLESS 凭据不应阻止 sing-box 配置检查"
        if node_config_matches_vpsbox_template vless "$VLESS_CONFIG_PATH"; then
            fail "额外 VLESS user 或 short_id 不应继续被识别为 VPSBox 管理模板"
        fi
        assert_eq deviated "$(protocol_node_status vless)" \
            "额外 VLESS user 或 short_id 应标记为 deviated，而不是 damaged"
    )
    (
        set_node_paths "$TEST_TMP/status-custom-listen"
        mkdir -p "$NODE_CONFIG_DIR"
        write_ss_config_fixture "$SS_CONFIG_PATH"
        write_ss_state_fixture "$SS_STATE_FILE"
        sed -i 's/"listen": "0.0.0.0"/"listen": "127.0.0.1"/' "$SS_CONFIG_PATH"

        validate_protocol_node_core ss "$SS_CONFIG_PATH" "$SS_STATE_FILE" ||
            fail "自定义监听地址不应破坏配置与状态的一致性"
        if node_config_matches_vpsbox_template ss "$SS_CONFIG_PATH"; then
            fail "自定义监听地址不应继续被识别为 vpsbox 管理模板"
        fi
        assert_eq deviated "$(protocol_node_status ss)" \
            "自定义监听地址应标记为 deviated，而不是损坏"
    )
    (
        set_node_paths "$TEST_TMP/status-custom-outbound"
        mkdir -p "$NODE_CONFIG_DIR"
        write_ss_config_fixture "$SS_CONFIG_PATH"
        write_ss_state_fixture "$SS_STATE_FILE"
        jq '
            .outbounds[0] = {
                "type": "socks",
                "tag": "custom-proxy",
                "server": "127.0.0.1",
                "server_port": 1080
            }
        ' "$SS_CONFIG_PATH" > "$SS_CONFIG_PATH.tmp"
        mv "$SS_CONFIG_PATH.tmp" "$SS_CONFIG_PATH"
        chmod 600 "$SS_CONFIG_PATH"

        validate_protocol_node_core ss "$SS_CONFIG_PATH" "$SS_STATE_FILE" ||
            fail "自定义出站不应破坏配置与状态的一致性"
        if node_config_matches_vpsbox_template ss "$SS_CONFIG_PATH"; then
            fail "自定义出站不应继续被识别为 vpsbox 管理模板"
        fi
        assert_eq deviated "$(protocol_node_status ss)" \
            "自定义出站应标记为 deviated，而不是损坏"
    )
    (
        set_node_paths "$TEST_TMP/status-damaged-credentials"
        mkdir -p "$NODE_CONFIG_DIR"
        write_ss_config_fixture "$SS_CONFIG_PATH"
        write_ss_state_fixture "$SS_STATE_FILE"
        sed -i 's/^PASSWORD=.*/PASSWORD=TkVXTkVXTkVXTkVXTkVXQQ==/' "$SS_STATE_FILE"

        assert_eq damaged "$(protocol_node_status ss)" \
            "配置与状态的凭据错配必须标记为 damaged"
    )
}

test_self_check_warns_for_template_drift_without_integrity_failure() {
    (
        local output="$TEST_TMP/self-check-template-drift.out"

        set_node_paths "$TEST_TMP/self-check-template-drift"
        mkdir -p "$NODE_CONFIG_DIR"
        write_ss_config_fixture "$SS_CONFIG_PATH"
        write_ss_state_fixture "$SS_STATE_FILE"
        sed -i 's/"listen": "0.0.0.0"/"listen": "127.0.0.1"/' "$SS_CONFIG_PATH"
        singbox_installed() { return 0; }
        singbox_version() { printf '%s\n' 1.13.14; }
        port_listener_ready() { return 0; }
        resolve_host_ips() { printf '%s\n' 192.0.2.1; }
        check_active_node_config() { return 0; }
        service_status_short() { printf '%s\n' 运行中; }
        node_uri_cache_status() { printf '%s\n' stale; }
        public_ipv4() { return 1; }
        firewall_control_plane_present() { return 1; }

        run_self_check > "$output" 2>&1

        assert_file_contains "$output" \
            'WARN[[:space:]]+[|] Shadowsocks 模板[[:space:]]+[|] 已偏离 VPSBox 管理模板' \
            "偏离管理模板应明确显示 WARN"
        assert_file_not_contains "$output" \
            'FAIL[[:space:]]+[|] Shadowsocks 模板' \
            "偏离管理模板不得被标记为 FAIL"
        assert_file_not_contains "$output" \
            'FAIL[[:space:]]+[|] 配置完整性[[:space:]]+[|] 未通过' \
            "仅偏离管理模板时核心配置完整性仍应通过"
    )
}

test_staged_core_validation_does_not_require_uri_files() {
    (
        local staged_ss_state

        set_node_paths "$TEST_TMP/staged-core-only"
        mkdir -p "$NODE_CONFIG_DIR" \
            "$NODE_TRANSACTION_STAGE/configs" \
            "$NODE_TRANSACTION_STAGE/states"
        chmod 700 "$NODE_TRANSACTION_STAGE" \
            "$NODE_TRANSACTION_STAGE/configs" \
            "$NODE_TRANSACTION_STAGE/states"
        write_vless_config_fixture "$VLESS_CONFIG_PATH"
        write_vless_state_fixture "$VLESS_STATE_FILE"
        cp -- "$VLESS_CONFIG_PATH" \
            "$NODE_TRANSACTION_STAGE/configs/${VLESS_CONFIG_PATH##*/}"
        staged_ss_state="$NODE_TRANSACTION_STAGE/states/${SS_STATE_FILE##*/}"
        write_ss_config_fixture \
            "$NODE_TRANSACTION_STAGE/configs/${SS_CONFIG_PATH##*/}"
        write_ss_state_fixture "$staged_ss_state"

        validate_staged_node ss ||
            fail "配置与状态一致的暂存节点不应依赖 URI 文件"
        [ ! -e "$NODE_TRANSACTION_STAGE/uris" ] ||
            fail "核心节点暂存区不应创建 URI 缓存目录"

        sed -i 's/^PORT=20001$/PORT=29999/' "$staged_ss_state"
        if validate_staged_node ss; then
            fail "URI 解耦后仍必须拒绝配置与状态端口不一致的暂存节点"
        fi
    )
}

test_aggregate_uri_drift_does_not_invalidate_core_node() {
    (
        set_node_paths "$TEST_TMP/mismatch-aggregate-uri"
        mkdir -p "$NODE_CONFIG_DIR"
        write_ss_config_fixture "$SS_CONFIG_PATH"
        write_ss_state_fixture "$SS_STATE_FILE"
        write_uri_files
        printf 'stale-aggregate\n' > "$URI_FILE"

        require_valid_node_state_if_present ||
            fail "汇总 URI 陈旧不得使核心节点完整性失败"
        assert_eq stale "$(node_uri_cache_status)" \
            "汇总 URI 陈旧必须被识别为缓存漂移"
        repair_node_uri_cache ||
            fail "汇总 URI 陈旧时应能从核心状态重建"
        assert_eq current "$(node_uri_cache_status)"
    )
}

test_singbox_update_rejects_mismatched_layout_before_download() {
    (
        local event_log="$TEST_TMP/update-mismatch.events"
        set_node_paths "$TEST_TMP/update-mismatch"
        mkdir -p "$NODE_CONFIG_DIR"
        write_ss_config_fixture "$SS_CONFIG_PATH"
        write_ss_state_fixture "$SS_STATE_FILE" 29999
        : > "$event_log"
        singbox_installed() { return 0; }
        singbox_version() { printf '%s\n' 1.13.13; }
        singbox_binary_is_package_managed() { return 0; }
        install_deps() { printf 'deps\n' >> "$event_log"; }
        run_singbox_installer() { printf 'installer\n' >> "$event_log"; }

        if update_singbox > "$TEST_TMP/update-mismatch.out" 2>&1; then
            fail "节点配置错配时 sing-box 更新不得继续"
        fi
        assert_empty_file "$event_log" "完整性失败必须发生在依赖下载和二进制替换前"
        assert_file_contains "$TEST_TMP/update-mismatch.out" '节点配置完整性未通过'
    )
}

test_uri_group_failure_restores_old_files() {
    local fail_at

    for fail_at in 2 3; do
        (
            local move_count=0 before_aggregate before_ss before_vless build_dir
            set_node_paths "$TEST_TMP/uri-failure-$fail_at"
            mkdir -p "$NODE_CONFIG_DIR"
            write_ss_config_fixture "$SS_CONFIG_PATH"
            write_vless_config_fixture "$VLESS_CONFIG_PATH"
            write_ss_state_fixture "$SS_STATE_FILE"
            write_vless_state_fixture "$VLESS_STATE_FILE"
            write_uri_files
            before_aggregate="$(cat "$URI_FILE")"
            before_ss="$(cat "$SS_URI_FILE")"
            before_vless="$(cat "$VLESS_URI_FILE")"
            build_dir="$TEST_TMP/uri-failure-$fail_at-build"
            mkdir -p "$build_dir"
            printf 'new-aggregate\n' > "$build_dir/${URI_FILE##*/}"
            printf 'new-ss\n' > "$build_dir/${SS_URI_FILE##*/}"
            printf 'new-vless\n' > "$build_dir/${VLESS_URI_FILE##*/}"
            chmod 600 "$build_dir"/*.txt
            mv() {
                move_count=$((move_count + 1))
                if [ "$move_count" -eq "$fail_at" ]; then
                    return 42
                fi
                command mv "$@"
            }

            if publish_uri_file_group "$build_dir" >/dev/null 2>&1; then
                unset -f mv
                fail "第 $fail_at 次链接替换失败时不应报告成功"
            fi
            unset -f mv
            assert_eq "$before_aggregate" "$(cat "$URI_FILE")" "汇总链接必须恢复"
            assert_eq "$before_ss" "$(cat "$SS_URI_FILE")" "Shadowsocks 链接必须恢复"
            assert_eq "$before_vless" "$(cat "$VLESS_URI_FILE")" "VLESS 链接必须恢复"
        )
    done
}

test_last_uri_delete_failure_is_not_masked() {
    (
        local failed_once=0
        set_node_paths "$TEST_TMP/uri-delete-failure"
        mkdir -p "$CONFIG_DIR"
        printf 'old-link\n' > "$URI_FILE"
        chmod 600 "$URI_FILE"
        rm() {
            if [ "$failed_once" -eq 0 ] && [ "${1:-}" = "-f" ] &&
                [[ " $* " == *" $URI_FILE "* ]]; then
                failed_once=1
                return 42
            fi
            command rm "$@"
        }

        if write_uri_files >/dev/null 2>&1; then
            unset -f rm
            fail "删除最后一个汇总链接失败时不得报告成功"
        fi
        unset -f rm
        assert_file_contains "$URI_FILE" '^old-link$'
    )
}

test_insecure_node_permissions_are_rejected() {
    (
        if [ "$DUAL_NODES_REAL_PERMISSIONS" -ne 1 ]; then
            skip "需要真实的 root 属主与 Unix 权限语义"
            return "$SKIP_STATUS"
        fi
        set_node_paths "$TEST_TMP/insecure-permissions"
        mkdir -p "$NODE_CONFIG_DIR"
        write_ss_config_fixture "$SS_CONFIG_PATH"
        write_ss_state_fixture "$SS_STATE_FILE"
        write_uri_files
        command chown root:root "$CONFIG_DIR" "$NODE_CONFIG_DIR" \
            "$SS_CONFIG_PATH" "$SS_STATE_FILE" "$URI_FILE" "$SS_URI_FILE"
        chmod 700 "$CONFIG_DIR" "$NODE_CONFIG_DIR"
        chmod 600 "$SS_CONFIG_PATH" "$SS_STATE_FILE" "$URI_FILE" "$SS_URI_FILE"

        require_valid_node_state_if_present >/dev/null 2>&1 ||
            fail "root:root 且 0600 的节点配置与状态必须被接受"
        chmod 400 "$SS_CONFIG_PATH" "$SS_STATE_FILE"
        require_valid_node_state_if_present >/dev/null 2>&1 ||
            fail "root:root 且 0400 的只读节点配置与状态必须被接受"
        assert_eq normal "$(protocol_node_status ss)" \
            "0400 节点仍应被识别为正常节点"

        chmod 440 "$SS_CONFIG_PATH"
        if require_valid_node_state_if_present >/dev/null 2>&1; then
            fail "组可读的 0440 节点配置必须被拒绝"
        fi
        chmod 600 "$SS_CONFIG_PATH" "$SS_STATE_FILE"
        chmod 666 "$SS_CONFIG_PATH"
        if require_valid_node_state_if_present >/dev/null 2>&1; then
            fail "0666 节点配置必须被拒绝"
        fi
        chmod 600 "$SS_CONFIG_PATH"
        chmod 755 "$NODE_CONFIG_DIR"
        if require_valid_node_state_if_present >/dev/null 2>&1; then
            fail "权限不是 700 的节点目录必须被拒绝"
        fi
        chmod 700 "$NODE_CONFIG_DIR"
        command chown 65534:65534 "$SS_STATE_FILE"
        if require_valid_node_state_if_present >/dev/null 2>&1; then
            fail "所有者不是 root 的节点状态必须被拒绝"
        fi
    )
}

test_node_security_predicates_reject_symlinks() {
    (
        local file_target file_link dir_target dir_link

        if [ "$DUAL_NODES_REAL_PERMISSIONS" -ne 1 ]; then
            skip "需要真实的 root 属主与 Unix 权限语义"
            return "$SKIP_STATUS"
        fi
        require_real_symlink file || return "$?"
        require_real_symlink directory || return "$?"
        set_node_paths "$TEST_TMP/node-security-symlinks"
        mkdir -p "$NODE_CONFIG_DIR"
        file_target="$CONFIG_DIR/secure-file"
        file_link="$CONFIG_DIR/file-link"
        dir_target="$CONFIG_DIR/secure-dir"
        dir_link="$CONFIG_DIR/dir-link"
        : > "$file_target"
        mkdir "$dir_target"
        command chown root:root "$file_target" "$dir_target"
        chmod 600 "$file_target"
        chmod 700 "$dir_target"
        ln -s "$file_target" "$file_link"
        ln -s "$dir_target" "$dir_link"

        if node_file_is_secure "$file_link"; then
            fail "节点安全判定不得接受文件符号链接"
        fi
        if node_dir_is_secure "$dir_link"; then
            fail "节点安全判定不得接受目录符号链接"
        fi
    )
}

test_self_check_keeps_valid_sibling_visible() {
    (
        local summary_output="$TEST_TMP/node-summary-sibling.out"

        set_node_paths "$TEST_TMP/self-check-sibling"
        mkdir -p "$NODE_CONFIG_DIR"
        write_ss_config_fixture "$SS_CONFIG_PATH"
        write_ss_state_fixture "$SS_STATE_FILE"
        mkdir "$VLESS_CONFIG_PATH"
        write_vless_state_fixture "$VLESS_STATE_FILE" 29999
        singbox_installed() { return 1; }
        port_listener_ready() { return 1; }
        resolve_host_ips() { printf '%s\n' 192.0.2.1; }
        public_ipv4() { return 1; }
        firewall_control_plane_present() { return 1; }

        run_self_check > "$TEST_TMP/self-check-sibling.out" 2>&1

        assert_eq 1 "$(grep -Ec 'FAIL[[:space:]]+[|] 配置完整性[[:space:]]+[|] 未通过' "$TEST_TMP/self-check-sibling.out")" \
            "残缺节点只能产生一条配置完整性失败"
        assert_file_contains "$TEST_TMP/self-check-sibling.out" 'Shadowsocks 节点'
        assert_file_not_contains "$TEST_TMP/self-check-sibling.out" 'VLESS Reality 模板.*已偏离' \
            "损坏节点不得再被误报为仅偏离管理模板"
        assert_file_not_contains "$TEST_TMP/self-check-sibling.out" '配置文件.*不存在'
        assert_file_not_contains "$TEST_TMP/self-check-sibling.out" '配置语法.*配置完整性未通过' \
            "已有完整性失败时不得重复报告配置语法失败"

        node_summary > "$summary_output"
        awk '
            /VLESS Reality 节点/ { section = "vless"; next }
            /Shadowsocks 节点/ { section = "ss"; next }
            section == "vless" && /状态：损坏，请进入节点管理检查/ { vless_damaged = 1 }
            section == "ss" && /状态：已创建/ { ss_created = 1 }
            section == "ss" && /名称：ss-node/ { ss_name = 1 }
            END { exit(vless_damaged && ss_created && ss_name ? 0 : 1) }
        ' "$summary_output" ||
            fail "主界面必须分别显示损坏的 VLESS 与有效的 Shadowsocks"
        assert_file_not_contains "$summary_output" '^ 节点状态：异常' \
            "一个受管协议损坏时不得遮住另一个有效协议"

        : > "$NODE_CONFIG_DIR/unknown.json"
        chmod 600 "$NODE_CONFIG_DIR/unknown.json"
        node_summary > "$summary_output"
        assert_file_contains "$summary_output" '^ 节点状态：异常' \
            "未知配置会参与 sing-box 目录加载，主界面必须整体告警"
        assert_file_not_contains "$summary_output" 'Shadowsocks 节点|VLESS Reality 节点' \
            "存在未知配置时不得把局部状态误报为完整视图"
    )
}

main() {
    local name
    local -a required=(
        atomic_staging_dir
        fail_after_node_rollback
        node_file_is_secure
        node_uri_file_is_safe
        node_dir_is_secure
        node_backup_file_is_safe
        validate_protocol_node_core
        validate_derived_uri_manifest_entry
        validate_staged_node
        node_config_matches_loaded_state
        node_config_matches_vpsbox_template
        protocol_node_status
        node_config_dir_contents_valid
        node_config_dir_layout_valid
        node_uri_cache_status
        repair_node_uri_cache
        require_valid_node_state_if_present
        normalize_cleanup_backup_file
        node_config_dir_restore_target_safe
        begin_node_transaction
        mark_node_transaction_mutated
        rollback_active_node_transaction
        recover_pending_node_transaction
        restore_file_atomically_from_snapshot
        load_state_file
        normalize_port_decimal
        delete_node
        write_uri_files
        run_self_check
        node_summary
    )
    local -a tests=(
        test_fake_singbox_rejects_invalid_config_schema
        test_complete_configs_merge_with_unique_tags
        test_create_shadowsocks_preserves_vless_and_tolerates_uri_cache_failure
        test_create_vless_preserves_shadowsocks_and_tolerates_uri_cache_failure
        test_independent_states_and_links_are_aggregated
        test_service_definition_uses_independent_config_directory
        test_uri_cache_is_derived_from_core_state
        test_uri_cache_repair_refuses_unsafe_paths
        test_unsafe_uri_cache_does_not_block_node_transaction
        test_stopped_sibling_port_is_rejected
        test_stopped_target_port_is_rechecked_against_system_listeners
        test_delete_one_protocol_keeps_sibling_running
        test_delete_last_protocol_disables_service
        test_delete_residual_node_without_singbox_keeps_sibling_static
        test_delete_last_residual_node_without_singbox_skips_missing_service
        test_delete_damaged_protocol_keeps_valid_sibling_running
        test_delete_partial_damaged_protocol_does_not_guess_firewall_port
        test_running_service_with_invalid_disk_config_blocks_damaged_cleanup
        test_delete_damaged_protocol_rejects_unsafe_target_before_mutation
        test_delete_damaged_protocol_requires_valid_sibling
        test_damaged_protocol_cleanup_rolls_back_after_late_failure
        test_cleanup_transaction_recovers_one_sided_damage_after_hard_interruption
        test_cleanup_recovery_can_replace_safe_permission_damaged_target
        test_delete_last_damaged_protocol_stops_and_disables_service
        test_view_link_uses_real_files_and_skips_damaged_sibling
        test_static_node_backup_validation_does_not_execute_singbox
        test_legacy_uri_snapshot_damage_does_not_block_core_recovery
        test_node_transaction_full_and_static_validation_modes
        test_node_transaction_restores_service_manager_state
        test_dual_node_backup_restore_round_trip
        test_verify_runtime_checks_both_protocols
        test_cancel_eof_and_input_interrupt_have_no_mutation
        test_failed_rollback_must_not_claim_state_was_restored
        test_node_rollback_firewall_failure_is_partial_success
        test_node_backup_file_safety_enforces_owner_and_mode
        test_interrupted_restore_leaves_node_config_dir_usable
        test_atomic_staging_rejects_cross_device_node_directory
        test_state_file_field_validation_rejects_malformed_values
        test_firewall_sync_failure_does_not_block_node_transaction_completion
        test_unrecovered_pending_transaction_blocks_new_operation
        test_absent_backup_entry_removes_target_and_invalid_entry_is_rejected
        test_absent_node_directory_backup_removes_dangling_link
        test_pending_transaction_recovers_after_hard_interruption
        test_unmodified_pending_transaction_is_discarded_without_service_stop
        test_corrupted_node_backup_is_rejected_before_overwrite
        test_failed_recovery_keeps_transaction_backup
        test_committed_transaction_is_not_rolled_back
        test_node_commit_cleanup_sync_failure_keeps_committed_state
        test_node_commit_pending_cleanup_failure_keeps_committed_state
        test_node_commit_marker_sync_failure_keeps_active_transaction
        test_config_state_identity_and_credentials_must_match
        test_protocol_status_distinguishes_template_drift_from_damage
        test_self_check_warns_for_template_drift_without_integrity_failure
        test_staged_core_validation_does_not_require_uri_files
        test_aggregate_uri_drift_does_not_invalidate_core_node
        test_singbox_update_rejects_mismatched_layout_before_download
        test_uri_group_failure_restores_old_files
        test_last_uri_delete_failure_is_not_masked
        test_insecure_node_permissions_are_rejected
        test_node_security_predicates_reject_symlinks
        test_self_check_keeps_valid_sibling_visible
    )

    require_command jq || return "$?"
    for name in "${required[@]}"; do
        require_function "$name"
    done
    run_registered_test_suite \
        "${BASH_SOURCE[0]}" "dual node tests" "${tests[@]}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
