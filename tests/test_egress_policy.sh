#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/test_helper.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
# shellcheck source=../vpsbox.sh
source "$REPO_DIR/vpsbox.sh"
trap 'rm -rf -- "$TEST_TMP"' EXIT

egress_case() {
    require_root_permission_semantics || return "$?"
    CONFIG_DIR="$TEST_TMP/$1/config"
    NODE_CONFIG_DIR="$CONFIG_DIR/vpsbox.d"
    SS_CONFIG_PATH="$NODE_CONFIG_DIR/10-ss.json"
    VLESS_CONFIG_PATH="$NODE_CONFIG_DIR/20-vless-reality.json"
    SS_STATE_FILE="$CONFIG_DIR/vpsbox-ss.env" VLESS_STATE_FILE="$CONFIG_DIR/vpsbox-vless.env"
    # shellcheck disable=SC2034 # 被 source 的节点 URI 恢复逻辑读取。
    SS_URI_FILE="$CONFIG_DIR/ss-uri" VLESS_URI_FILE="$CONFIG_DIR/vless-uri" URI_FILE="$CONFIG_DIR/uris"
    VPSBOX_STATE_DIR="$TEST_TMP/$1/state"
    NODE_TRANSACTION_DIR="$VPSBOX_STATE_DIR/node-transaction"
    NODE_TRANSACTION_BACKUP="$NODE_TRANSACTION_DIR/backup" NODE_TRANSACTION_STAGE="$NODE_TRANSACTION_DIR/stage"
    RUNTIME_DIR="$TEST_TMP/$1/runtime"
    mkdir -p "$CONFIG_DIR" "$VPSBOX_STATE_DIR" "$RUNTIME_DIR" "$TEST_TMP/$1/bin"
    chmod 700 "$CONFIG_DIR" "$VPSBOX_STATE_DIR" "$RUNTIME_DIR"
    cat > "$TEST_TMP/$1/bin/sing-box" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
 version) printf 'sing-box version %s\n' "${POLICY_TEST_VERSION:-1.14.4}" ;;
 rule-set)
  [ "${POLICY_TEST_COMPILE_FAIL:-0}:$2" != '1:compile' ] || exit 1
  cp -- "$3" "$5" ;;
 check)
  if [ "$2" = -c ]; then files=("$3"); else files=("$3/"*.json); fi
  for file in "${files[@]}"; do
   jq -e '((.inbounds | type == "array" and length > 0) and (.outbounds | length == 1)) or
    (.dns.servers[0].type == "local" and (.route.rules | length > 0) and all(.route.rules[]; (.action == "resolve" or .action == "reject" or .action == "sniff")))' "$file" >/dev/null
   while IFS= read -r rule; do [ -f "$rule" ]; done < <(jq -r '.route.rule_set[]?.path' "$file")
  done ;;
 *) exit 2 ;;
esac
EOF
    chmod 755 "$TEST_TMP/$1/bin/sing-box"
    PATH="$TEST_TMP/$1/bin:$PATH"
    export PATH
    # shellcheck disable=SC2034 # 被 source 的服务与事务函数读取。
    OS=unknown ACTIVE_NODE_BACKUP='' ACTIVE_NODE_TRANSACTION_MUTATED=0
    policy_active=0 policy_enabled=0 policy_restarts=0 policy_fail_restart=0
    policy_download_fail=0 policy_rule='{"version":1,"rules":[{"ip_cidr":["1.0.1.0/24","240e::/16"]}]}'
    policy_domain_fail=0 policy_domain='{"version":1,"rules":[{"domain_suffix":["domestic.test"],"domain_regex":["^cn[0-9]+[.]test$"]}]}'
    is_systemd() { return 1; }
    listen_mode() { printf 'ipv4\n'; }
    service_is_running() { [ "$policy_active" = 1 ]; }
    service_manager_is_active() { [ "$policy_active" = 1 ]; }
    service_is_enabled() { [ "$policy_enabled" = 1 ]; }
    service_enable() { policy_enabled=1; }
    service_disable() { policy_enabled=0; }
    service_stop() { policy_active=0; }
    stop_singbox_config_processes() { return 0; }
    singbox_config_pids() { return 0; }
    restart_singbox_cleanly() {
        policy_restarts=$((policy_restarts + 1))
        if [ "$policy_fail_restart" = 1 ]; then policy_fail_restart=0; return 1; fi
        policy_active=1
    }
    verify_all_node_runtime() { [ "$policy_active" = 1 ]; }
    firewall_refresh_if_enabled() { return 0; }
    download_egress_rules() {
        [ "$policy_download_fail" = 0 ] || return 1
        if [ "${2:-ip}" = domain ]; then
            [ "$policy_domain_fail" = 0 ] || return 1
            printf '%s\n' "$policy_domain" > "$1"
        else
            printf '%s\n' "$policy_rule" > "$1"
        fi
    }
}

egress_add_ss() {
    local config="${1:-$SS_CONFIG_PATH}" state="${2:-$SS_STATE_FILE}"
    write_config 20101 QUFBQUFBQUFBQUFBQUFBQQ== 111111111111111111111111 "$config" >/dev/null
    save_state ss.example ss 20101 QUFBQUFBQUFBQUFBQUFBQQ== 111111111111111111111111 "$state"
}

egress_add_vless() {
    write_vless_reality_config 20102 11111111-2222-4333-8444-555555555555 native.example \
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA 0123456789abcdef 222222222222222222222222 >/dev/null
    save_vless_reality_state vless.example vless 20102 11111111-2222-4333-8444-555555555555 native.example \
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB \
        0123456789abcdef 222222222222222222222222
}

test_egress_default_and_preset_inherited_by_creation() {
    (
        egress_case preset
        assert_eq '已关闭（默认）' "$(egress_policy_summary)"
        apply_egress_policy on
        [ ! -e "$NODE_CONFIG_DIR" ] || fail '预设开关不得制造节点目录'
        [[ "$(egress_policy_summary)" == *待创建* ]]
        begin_node_transaction
        prepare_node_stage
        egress_add_ss "$NODE_TRANSACTION_STAGE/configs/10-ss.json" "$NODE_TRANSACTION_STAGE/states/vpsbox-ss.env"
        validate_staged_node ss
        mark_node_transaction_mutated
        publish_staged_node ss
        commit_node_transaction
        validate_egress_policy
        assert_eq 0 "$policy_restarts"
        jq -e '[.route.rules[].action] == ["reject","sniff","reject","resolve","reject"]' "$NODE_CONFIG_DIR/30-egress-policy.json" >/dev/null
    )
}

test_egress_toggle_preserves_credentials_and_service_states() {
    local running
    for running in 0 1; do
        (
            egress_case "toggle-$running"
            egress_add_ss; egress_add_vless
            local before
            before="$(sha256sum "$SS_CONFIG_PATH" "$SS_STATE_FILE" "$VLESS_CONFIG_PATH" "$VLESS_STATE_FILE")"
            policy_active="$running" policy_enabled="$running"
            apply_egress_policy on
            validate_egress_policy
            jq -e '(.route.rules[0].inbound | length) == 2' "$NODE_CONFIG_DIR/30-egress-policy.json" >/dev/null
            apply_egress_policy off
            assert_eq "$before" "$(sha256sum "$SS_CONFIG_PATH" "$SS_STATE_FILE" "$VLESS_CONFIG_PATH" "$VLESS_STATE_FILE")"
            assert_eq "$running" "$policy_active"; assert_eq "$running" "$policy_enabled"
            assert_eq "$((running * 2))" "$policy_restarts"
            [ ! -e "$NODE_CONFIG_DIR/30-egress-policy.json" ]
        )
    done
}

test_egress_rejects_old_kernel_custom_routes_and_bad_download() {
    (
        egress_case reject
        egress_add_ss
        export POLICY_TEST_VERSION=1.13.14
        if apply_egress_policy on >/dev/null 2>&1; then fail '旧内核不得启用'; fi
        [ ! -e "$CONFIG_DIR/vpsbox-egress.json" ]
        unset POLICY_TEST_VERSION
        jq '.route={rules:[]}' "$SS_CONFIG_PATH" > "$CONFIG_DIR/custom"
        cat "$CONFIG_DIR/custom" > "$SS_CONFIG_PATH"
        if apply_egress_policy on >/dev/null 2>&1; then fail '不得覆盖自定义路由'; fi
        egress_add_ss
        policy_download_fail=1
        if apply_egress_policy on >/dev/null 2>&1; then fail '下载失败不得启用'; fi
        policy_download_fail=0 policy_rule='{"version":1,"rules":[{"domain_suffix":["cn"]}]}'
        if apply_egress_policy on >/dev/null 2>&1; then fail '非 IP 规则不得启用'; fi
        [ ! -e "$CONFIG_DIR/vpsbox-egress.json" ] && [ ! -e "$NODE_TRANSACTION_DIR" ]
    )
}

test_egress_failed_reload_rolls_back_policy_and_rules() {
    (
        egress_case rollback
        egress_add_ss
        policy_active=1 policy_enabled=1
        apply_egress_policy on
        local before
        before="$(sha256sum "$CONFIG_DIR/vpsbox-egress.json" "$NODE_CONFIG_DIR/30-egress-policy.json")"
        policy_rule='{"version":1,"rules":[{"ip_cidr":["1.0.2.0/24","240e::/16"]}]}'
        policy_fail_restart=1
        if apply_egress_policy update >/dev/null 2>&1; then fail '验收失败必须返回非零'; fi
        assert_eq "$before" "$(sha256sum "$CONFIG_DIR/vpsbox-egress.json" "$NODE_CONFIG_DIR/30-egress-policy.json")"
        validate_egress_policy
        assert_eq 1 "$policy_active"
        [ ! -e "$NODE_TRANSACTION_DIR" ]
    )
}

test_egress_missing_rules_can_be_disabled_offline() {
    (
        egress_case missing
        egress_add_ss
        apply_egress_policy on
        local rule
        rule="$(jq -r '.route.rule_set[0].path' "$NODE_CONFIG_DIR/30-egress-policy.json")"
        rm -- "$rule"
        if require_valid_node_state_if_present >/dev/null 2>&1; then fail '缺失规则不能静默放行'; fi
        policy_download_fail=1
        apply_egress_policy off
        require_valid_node_state_if_present
        [ ! -e "$NODE_CONFIG_DIR/30-egress-policy.json" ]
    )
}

test_egress_backup_uses_snapshot_rules_and_recovers_after_interruption() {
    (
        egress_case snapshot
        egress_add_ss
        apply_egress_policy on
        begin_node_transaction
        assert_eq 'version|2' "$(head -1 "$NODE_TRANSACTION_BACKUP/manifest")"
        local rule
        rule="$(jq -r '.route.rule_set[0].path' "$NODE_CONFIG_DIR/30-egress-policy.json")"
        mark_node_transaction_mutated
        rm -- "$rule" "$CONFIG_DIR/vpsbox-egress.json"
        validate_node_transaction_backup "$NODE_TRANSACTION_BACKUP"
        check_node_config_directory "$NODE_TRANSACTION_BACKUP/vpsbox.d" "$NODE_TRANSACTION_BACKUP/egress-rule.srs"
        # shellcheck disable=SC2034 # 模拟进程消失后仅依靠持久标记恢复。
        ACTIVE_NODE_BACKUP='' ACTIVE_NODE_TRANSACTION_MUTATED=0
        recover_pending_node_transaction
        validate_egress_policy
        [ -f "$rule" ] && [ ! -e "$NODE_TRANSACTION_DIR" ]
    )
}

test_egress_deleting_nodes_refreshes_tags_and_retains_preference() {
    (
        egress_case deletion
        egress_add_ss; egress_add_vless
        apply_egress_policy on
        begin_node_transaction
        mark_node_transaction_mutated
        publish_node_deletion vless VLESS
        validate_egress_policy
        jq -e '(.route.rules[0].inbound | length) == 1' "$NODE_CONFIG_DIR/30-egress-policy.json" >/dev/null
        commit_node_transaction
        begin_node_transaction
        mark_node_transaction_mutated
        publish_node_deletion ss SS
        commit_node_transaction
        [ ! -e "$NODE_CONFIG_DIR/30-egress-policy.json" ]
        jq -e .enabled "$CONFIG_DIR/vpsbox-egress.json" >/dev/null
        [[ "$(egress_policy_summary)" == *待创建* ]]
    )
}

test_egress_noop_and_failed_download_preserve_active_policy() {
    (
        egress_case noop
        egress_add_ss
        policy_active=1
        apply_egress_policy on
        local before
        before="$(sha256sum "$CONFIG_DIR/vpsbox-egress.json" "$NODE_CONFIG_DIR/30-egress-policy.json")"
        policy_download_fail=1
        apply_egress_policy on
        if apply_egress_policy update >/dev/null 2>&1; then fail '失败下载不得成功'; fi
        assert_eq "$before" "$(sha256sum "$CONFIG_DIR/vpsbox-egress.json" "$NODE_CONFIG_DIR/30-egress-policy.json")"
        policy_download_fail=0
        apply_egress_policy update
        assert_eq 1 "$policy_restarts" '相同开关或相同规则不得重复重启'
        policy_rule='{"version":1,"rules":[{"ip_cidr":["1.0.2.0/24","240e::/16"]}]}'
        apply_egress_policy update
        assert_eq 2 "$policy_restarts"
        validate_egress_policy
    )
}

test_egress_first_enable_failure_restores_v1_snapshot() {
    (
        egress_case first-failure
        egress_add_ss
        policy_active=1 policy_fail_restart=1
        if apply_egress_policy on >/dev/null 2>&1; then fail '首次启用失败必须回滚'; fi
        [ ! -e "$CONFIG_DIR/vpsbox-egress.json" ] && [ ! -e "$NODE_CONFIG_DIR/30-egress-policy.json" ]
        assert_eq 1 "$policy_active"
        [ ! -e "$NODE_TRANSACTION_DIR" ]
        require_valid_node_state_if_present
    )
}

test_egress_unsafe_paths_and_corrupt_rules_are_rejected() {
    (
        egress_case safety
        egress_add_ss
        printf 'keep\n' > "$CONFIG_DIR/target"
        ln -s "$CONFIG_DIR/target" "$CONFIG_DIR/vpsbox-egress.json"
        if apply_egress_policy on >/dev/null 2>&1; then fail '状态链接必须拒绝'; fi
        assert_eq keep "$(cat "$CONFIG_DIR/target")"
        rm "$CONFIG_DIR/vpsbox-egress.json"
        apply_egress_policy on
        local rule
        rule="$(jq -r '.route.rule_set[0].path' "$NODE_CONFIG_DIR/30-egress-policy.json")"
        printf 'damaged\n' > "$rule"
        if require_valid_node_state_if_present >/dev/null 2>&1; then fail '规则哈希必须检查'; fi
        apply_egress_policy off
        apply_egress_policy update
        apply_egress_policy on
        validate_egress_policy
        rm -- "$rule"
        apply_egress_policy update
        validate_egress_policy
    )
}

test_egress_damaged_node_cleanup_keeps_healthy_policy() {
    (
        egress_case damaged-node
        egress_add_ss; egress_add_vless
        apply_egress_policy on
        printf 'damaged\n' > "$VLESS_CONFIG_PATH"
        begin_node_transaction cleanup:vless
        mark_node_transaction_mutated
        publish_node_deletion vless VLESS
        require_valid_node_state_if_present
        commit_node_transaction
        jq -e '(.route.rules[0].inbound | length) == 1' "$NODE_CONFIG_DIR/30-egress-policy.json" >/dev/null
    )
}

test_egress_menu_dispatches_only_confirmed_choices() {
    (
        egress_case menu
        local calls="$CONFIG_DIR/calls"
        : > "$calls"
        apply_egress_policy() { printf '%s\n' "$1" >> "$calls"; }
        pause() { return 0; }
        egress_policy_menu <<< $'1\ny\n2\nn\n3\ny\n0' >/dev/null
        assert_eq $'on\nupdate' "$(cat "$calls")"
        egress_policy_menu </dev/null >/dev/null
        assert_eq $'on\nupdate' "$(cat "$calls")" 'EOF 不得调用设置动作'
    )
}

egress_install_legacy_policy() {
    local digest path
    digest="$(printf '%s\n' "$policy_rule" | sha256sum | awk '{print $1}')"
    path="$(egress_policy_rule_path "$digest")"
    mkdir -p "$CONFIG_DIR/rule-set"
    chmod 700 "$CONFIG_DIR/rule-set"
    printf '%s\n' "$policy_rule" > "$path"
    jq -nc --arg hash "$digest" '{version:1,enabled:true,sha256:$hash,updated_at:1700000000}' > "$CONFIG_DIR/vpsbox-egress.json"
    render_egress_policy_config "$(egress_policy_tags "$NODE_CONFIG_DIR")" "$path" 1 > "$NODE_CONFIG_DIR/30-egress-policy.json"
    chmod 600 "$path" "$CONFIG_DIR/vpsbox-egress.json" "$NODE_CONFIG_DIR/30-egress-policy.json"
}

test_egress_legacy_migration_is_explicit_and_recoverable() {
    (
        egress_case legacy
        egress_add_ss
        egress_install_legacy_policy
        policy_active=1
        local before
        before="$(sha256sum "$CONFIG_DIR/vpsbox-egress.json" "$NODE_CONFIG_DIR/30-egress-policy.json")"
        validate_egress_policy
        [[ "$(egress_policy_summary)" == *旧版仅\ IP* ]]
        apply_egress_policy on
        begin_node_transaction
        prepare_node_stage
        cp -- "$SS_CONFIG_PATH" "$NODE_TRANSACTION_STAGE/configs/10-ss.json"
        prepare_staged_egress_policy inherit
        cmp "$NODE_TRANSACTION_STAGE/configs/30-egress-policy.json" "$NODE_CONFIG_DIR/30-egress-policy.json"
        cancel_unmodified_node_transaction
        assert_eq "$before" "$(sha256sum "$CONFIG_DIR/vpsbox-egress.json" "$NODE_CONFIG_DIR/30-egress-policy.json")"
        policy_domain_fail=1
        if apply_egress_policy update >/dev/null 2>&1; then fail '域名下载失败不得部分迁移'; fi
        policy_domain_fail=0 policy_fail_restart=1
        if apply_egress_policy update >/dev/null 2>&1; then fail '迁移运行验收失败必须回退旧策略'; fi
        assert_eq "$before" "$(sha256sum "$CONFIG_DIR/vpsbox-egress.json" "$NODE_CONFIG_DIR/30-egress-policy.json")"
        validate_egress_policy
        apply_egress_policy update
        jq -e '.version == 2' "$CONFIG_DIR/vpsbox-egress.json" >/dev/null
        [[ "$(egress_policy_summary)" == *官方\ geolocation-cn* ]]
        validate_egress_policy
        [ ! -e "$NODE_TRANSACTION_DIR" ]
    )
}

test_egress_domain_update_validation_and_compile_failures_are_atomic() {
    (
        egress_case domain-update
        egress_add_ss
        policy_active=1
        apply_egress_policy on
        local before bad rule
        before="$(sha256sum "$CONFIG_DIR/vpsbox-egress.json" "$NODE_CONFIG_DIR/30-egress-policy.json")"
        for bad in '{"ip_cidr":["1.0.1.0/24"]}' '{"domain_suffix":[]}' \
            '{"domain_suffix":[""]}' '{"domain_suffix":["cn"],"invert":true}' \
            '{"process_name":["curl"]}'; do
            policy_domain="{\"version\":1,\"rules\":[$bad]}"
            if apply_egress_policy update >/dev/null 2>&1; then fail '不得接受不受支持的域名规则'; fi
            assert_eq "$before" "$(sha256sum "$CONFIG_DIR/vpsbox-egress.json" "$NODE_CONFIG_DIR/30-egress-policy.json")"
        done
        policy_domain='{"version":1,"rules":[{"domain_suffix":["changed.test"]}]}'
        export POLICY_TEST_COMPILE_FAIL=1
        if apply_egress_policy update >/dev/null 2>&1; then fail '编译失败必须保留旧策略'; fi
        unset POLICY_TEST_COMPILE_FAIL
        assert_eq "$before" "$(sha256sum "$CONFIG_DIR/vpsbox-egress.json" "$NODE_CONFIG_DIR/30-egress-policy.json")"
        apply_egress_policy update
        assert_eq 2 "$policy_restarts" '仅域名源变化也应应用新规则'
        rule="$(jq -r '.route.rule_set[0].path' "$NODE_CONFIG_DIR/30-egress-policy.json")"
        jq -e 'any(.rules[]; .domain_suffix == ["changed.test"]) and any(.rules[]; .ip_cidr != null)' "$rule" >/dev/null
        validate_egress_policy
    )
}

test_egress_legacy_disable_and_reenable_upgrades_cached_rules() {
    (
        egress_case legacy-toggle
        egress_add_ss
        egress_install_legacy_policy
        policy_download_fail=1
        apply_egress_policy off
        if apply_egress_policy on >/dev/null 2>&1; then fail '重新开启不得以旧 IP 缓存冒充新策略'; fi
        jq -e '.version == 1 and .enabled == false' "$CONFIG_DIR/vpsbox-egress.json" >/dev/null
        policy_download_fail=0
        apply_egress_policy on
        jq -e '.version == 2 and .enabled == true' "$CONFIG_DIR/vpsbox-egress.json" >/dev/null
        validate_egress_policy
    )
}

test_ip_policy_modes_preserve_nodes_and_cn_state() {
    local enabled strategy running
    for enabled in off on; do
        for running in 0 1; do
            (
                egress_case "ip-$enabled-$running"
                egress_add_ss; egress_add_vless
                policy_active="$running" policy_enabled="$running"
                apply_egress_policy "$enabled"
                local before cn rule_before=''
                before="$(sha256sum "$SS_CONFIG_PATH" "$SS_STATE_FILE" "$VLESS_CONFIG_PATH" "$VLESS_STATE_FILE")"
                cn="$(read_egress_policy_state | jq -c 'del(.ip_strategy)')"
                [ "$enabled" != on ] || rule_before="$(sha256sum "$CONFIG_DIR/"rule-set/*)"
                policy_download_fail=1
                for strategy in prefer_ipv4 prefer_ipv6 ipv4_only default; do
                    apply_egress_policy "ip:$strategy"
                    validate_egress_policy
                    assert_eq "$cn" "$(read_egress_policy_state | jq -c 'del(.ip_strategy)')"
                    assert_eq "$before" "$(sha256sum "$SS_CONFIG_PATH" "$SS_STATE_FILE" "$VLESS_CONFIG_PATH" "$VLESS_STATE_FILE")"
                    assert_eq "$running" "$policy_active"; assert_eq "$running" "$policy_enabled"
                    assert_eq "$(ip_outbound_strategy_label "$strategy")" "$(ip_outbound_policy_summary)"
                    local restarts="$policy_restarts"
                    apply_egress_policy "ip:$strategy"
                    assert_eq "$restarts" "$policy_restarts" '重复选择不得重启'
                    [ "$enabled" != on ] || assert_eq "$rule_before" "$(sha256sum "$CONFIG_DIR/"rule-set/*)"
                done
                if [ "$enabled" = off ]; then [ ! -e "$NODE_CONFIG_DIR/30-egress-policy.json" ]; fi
            )
        done
    done
}

test_ip_policy_only_v4_keeps_full_cn_check_before_filtering() {
    (
        egress_case only4
        egress_add_ss
        apply_egress_policy ip:ipv4_only
        jq -e '.route.rules[0].ip_version == 6 and .route.rules[1].strategy == "ipv4_only" and .route.rule_set == null' "$NODE_CONFIG_DIR/30-egress-policy.json" >/dev/null
        apply_egress_policy on
        jq -e '[.route.rules[].action] == ["reject","reject","sniff","reject","resolve","reject","resolve","reject"] and
            .route.rules[0].ip_version == 6 and .route.rules[4].strategy == "prefer_ipv4" and
            .route.rules[6].strategy == "ipv4_only"' "$NODE_CONFIG_DIR/30-egress-policy.json" >/dev/null
        apply_egress_policy off
        assert_eq 仅IPV4 "$(ip_outbound_policy_summary)"
        validate_egress_policy
    )
}

test_ip_policy_preset_inherits_and_last_deletion_keeps_preference() {
    (
        egress_case ip-preset
        apply_egress_policy ip:prefer_ipv6
        [ ! -e "$NODE_CONFIG_DIR" ]
        begin_node_transaction
        prepare_node_stage
        egress_add_ss "$NODE_TRANSACTION_STAGE/configs/10-ss.json" "$NODE_TRANSACTION_STAGE/states/vpsbox-ss.env"
        validate_staged_node ss
        mark_node_transaction_mutated
        publish_staged_node ss
        commit_node_transaction
        validate_egress_policy
        jq -e '.route.rules[0].strategy == "prefer_ipv6"' "$NODE_CONFIG_DIR/30-egress-policy.json" >/dev/null
        begin_node_transaction
        mark_node_transaction_mutated
        publish_node_deletion ss SS
        commit_node_transaction
        [ ! -e "$NODE_CONFIG_DIR/30-egress-policy.json" ]
        assert_eq IPV6优先 "$(ip_outbound_policy_summary)"
    )
}

test_ip_policy_failures_and_interruption_restore_snapshot() {
    (
        egress_case ip-rollback
        egress_add_ss
        policy_active=1 policy_enabled=1
        apply_egress_policy ip:prefer_ipv6
        local before
        before="$(sha256sum "$CONFIG_DIR/vpsbox-egress.json" "$NODE_CONFIG_DIR/30-egress-policy.json")"
        policy_fail_restart=1
        if apply_egress_policy ip:ipv4_only >/dev/null 2>&1; then fail '失败必须回滚'; fi
        assert_eq "$before" "$(sha256sum "$CONFIG_DIR/vpsbox-egress.json" "$NODE_CONFIG_DIR/30-egress-policy.json")"
        begin_node_transaction
        prepare_node_stage
        cp "$SS_CONFIG_PATH" "$NODE_TRANSACTION_STAGE/configs/10-ss.json"
        prepare_staged_egress_policy ip:prefer_ipv4
        mark_node_transaction_mutated
        publish_staged_egress_policy
        # shellcheck disable=SC2034 # 模拟下一进程恢复未完成事务。
        ACTIVE_NODE_BACKUP='' ACTIVE_NODE_TRANSACTION_MUTATED=0
        recover_pending_node_transaction
        assert_eq "$before" "$(sha256sum "$CONFIG_DIR/vpsbox-egress.json" "$NODE_CONFIG_DIR/30-egress-policy.json")"
        validate_egress_policy
        assert_eq 1 "$policy_active"
        assert_eq 1 "$policy_enabled"
    )
}

test_ip_policy_legacy_cn_and_corrupt_cache_recovery() {
    (
        egress_case ip-legacy
        egress_add_ss
        egress_install_legacy_policy
        assert_eq IPV4优先 "$(ip_outbound_policy_summary)"
        policy_download_fail=1
        apply_egress_policy ip:prefer_ipv6
        jq -e '.version == 1 and .ip_strategy == "prefer_ipv6"' "$CONFIG_DIR/vpsbox-egress.json" >/dev/null
        jq -e '[.route.rules[].action] == ["resolve","reject"] and .route.rules[0].strategy == "prefer_ipv6"' "$NODE_CONFIG_DIR/30-egress-policy.json" >/dev/null
        local rule
        rule="$(jq -r '.route.rule_set[0].path' "$NODE_CONFIG_DIR/30-egress-policy.json")"
        printf damaged > "$rule"
        apply_egress_policy off
        validate_egress_policy
        assert_eq IPV6优先 "$(ip_outbound_policy_summary)"
        policy_download_fail=0
        apply_egress_policy update
        apply_egress_policy on
        validate_egress_policy
        assert_eq IPV6优先 "$(ip_outbound_policy_summary)"
    )
}

test_ip_policy_rejects_bad_state_custom_routes_and_old_kernel() {
    (
        egress_case ip-invalid
        egress_add_ss
        export POLICY_TEST_VERSION=1.13.14
        if apply_egress_policy ip:prefer_ipv6 >/dev/null 2>&1; then fail '旧内核不得启用 IP 策略'; fi
        unset POLICY_TEST_VERSION
        jq '.dns={servers:[]}' "$SS_CONFIG_PATH" > "$CONFIG_DIR/custom"
        cat "$CONFIG_DIR/custom" > "$SS_CONFIG_PATH"
        if apply_egress_policy ip:ipv4_only >/dev/null 2>&1; then fail '不得覆盖自定义 DNS'; fi
        egress_add_ss
        apply_egress_policy ip:prefer_ipv4
        jq '.ip_strategy="ipv6_only"' "$CONFIG_DIR/vpsbox-egress.json" > "$CONFIG_DIR/bad"
        cat "$CONFIG_DIR/bad" > "$CONFIG_DIR/vpsbox-egress.json"
        if read_egress_policy_state >/dev/null; then fail '非法策略必须拒绝'; fi
        if ip_outbound_policy_summary >/dev/null; then fail '异常不得显示默认'; fi
    )
}

test_ip_policy_menu_and_node_status_labels() {
    (
        egress_case ip-menu
        local calls="$CONFIG_DIR/calls" output="$CONFIG_DIR/menu"
        : > "$calls"
        apply_egress_policy() { printf '%s\n' "$1" >> "$calls"; }
        pause() { :; }; clear() { :; }
        ip_outbound_policy_menu <<< $'1\ny\n2\nn\n3\ny\n4\ny\n0' > "$output"
        assert_eq $'ip:default\nip:prefer_ipv6\nip:ipv4_only' "$(cat "$calls")"
        assert_file_contains "$output" '作用范围：所有 sing-box 节点'
        assert_file_not_contains "$output" '允许使用|控制节点|无需修改'
        singbox_summary_line() { :; }; node_summary() { :; }
        node_menu <<< '0' > "$output"
        assert_file_contains "$output" '[[]6[]] 回国流量限制（已关闭）'
        assert_file_contains "$output" '[[]7[]] IP 出站策略（默认）'
        egress_policy_menu <<< '0' > "$output"
        assert_file_contains "$output" '当前状态：已关闭'
        assert_file_contains "$output" '作用范围：所有 sing-box 节点'
        assert_file_not_contains "$output" 'geolocation|摘要|更新时间|VLESS'
    )
}

main() {
    run_registered_test_suite "${BASH_SOURCE[0]}" 'egress policy tests' \
        test_egress_default_and_preset_inherited_by_creation \
        test_egress_toggle_preserves_credentials_and_service_states \
        test_egress_rejects_old_kernel_custom_routes_and_bad_download \
        test_egress_failed_reload_rolls_back_policy_and_rules \
        test_egress_missing_rules_can_be_disabled_offline \
        test_egress_backup_uses_snapshot_rules_and_recovers_after_interruption \
        test_egress_deleting_nodes_refreshes_tags_and_retains_preference \
        test_egress_noop_and_failed_download_preserve_active_policy \
        test_egress_first_enable_failure_restores_v1_snapshot \
        test_egress_unsafe_paths_and_corrupt_rules_are_rejected \
        test_egress_damaged_node_cleanup_keeps_healthy_policy \
        test_egress_legacy_migration_is_explicit_and_recoverable \
        test_egress_domain_update_validation_and_compile_failures_are_atomic \
        test_egress_legacy_disable_and_reenable_upgrades_cached_rules \
        test_egress_menu_dispatches_only_confirmed_choices \
        test_ip_policy_modes_preserve_nodes_and_cn_state \
        test_ip_policy_only_v4_keeps_full_cn_check_before_filtering \
        test_ip_policy_preset_inherits_and_last_deletion_keeps_preference \
        test_ip_policy_failures_and_interruption_restore_snapshot \
        test_ip_policy_legacy_cn_and_corrupt_cache_recovery \
        test_ip_policy_rejects_bad_state_custom_routes_and_old_kernel \
        test_ip_policy_menu_and_node_status_labels
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
