#!/usr/bin/env bash

set -euo pipefail
# shellcheck source=tests/test_helper.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
# shellcheck source=../vpsbox.sh
source "$REPO_DIR/vpsbox.sh"
trap 'rm -rf -- "$TEST_TMP"' EXIT

write_update_test_binary() {
    printf '#!/bin/sh\nprintf "sing-box version %s\\n"\n' "$1" > "$case_binary"
    chmod 755 "$case_binary"
}

setup_service_update_case() {
    case_root="$TEST_TMP/$1"
    case_manager="${2:-systemd}"
    case_active=1 case_enabled=1 case_managed=0 case_failure=early
    case_reload_failure=0 case_restore_failure=0 case_package=none
    mkdir -p "$case_root/bin"
    case_binary="$case_root/bin/sing-box"
    write_update_test_binary 1.13.13
    PATH="$case_root/bin:$PATH"
    VPSBOX_STATE_DIR="$case_root/state"
    SINGBOX_UPDATE_TRANSACTION_DIR="$VPSBOX_STATE_DIR/singbox-update"
    # shellcheck disable=SC2034 # 生产事务函数动态读取。
    SINGBOX_UPDATE_TRANSACTION_STATE="$SINGBOX_UPDATE_TRANSACTION_DIR/state"
    mock_singbox_update_service_files "$case_root/service-files"
    singbox_update_service_manager() { printf '%s\n' "$case_manager"; }
    case_entry=systemd-local
    [ "$case_manager" != openrc ] || case_entry=openrc
    printf 'ExecStart=%s run -c /etc/sing-box/custom.json\nUser=custom\n' "$case_binary" \
        > "$SINGBOX_TEST_SERVICE_ROOT/$case_entry"
    chmod 640 "$SINGBOX_TEST_SERVICE_ROOT/$case_entry"
    cp -a "$SINGBOX_TEST_SERVICE_ROOT/$case_entry" "$case_root/original"
    : > "$case_root/events"

    # 节点校验、包安装、进程与服务管理均使用替身；事务、文件恢复和状态恢复用生产函数。
    singbox_binary_is_package_managed() { return 0; }
    ensure_node_dependencies() { return 0; }
    node_core_artifacts_present() { return 0; }
    node_exists() { return 0; }
    require_valid_node_state_if_present() { return 0; }
    check_node_config_set() { return 0; }
    repair_node_uri_cache_best_effort() { return 0; }
    service_manager_is_active() { [ "$case_active" = 1 ]; }
    service_is_enabled() { [ "$case_enabled" = 1 ]; }
    singbox_config_pids() { [ "$case_managed" = 0 ] || printf '424242\n'; }
    service_stop() { case_active=0; case_managed=0; }
    stop_singbox_config_processes() { case_managed=0; }
    service_enable() { case_enabled=1; }
    service_disable() { case_enabled=0; }
    service_start() {
        printf '%s\n' start >> "$case_root/events"
        case_active=1
        if grep -q 'run -C ' "$SINGBOX_TEST_SERVICE_ROOT/$case_entry"; then
            case_managed=1
        fi
    }
    systemctl() {
        [ "$*" = daemon-reload ] || return 2
        printf '%s\n' reload >> "$case_root/events"
        [ "$case_reload_failure" = 0 ]
    }
    prepare_singbox_rollback_package() {
        [ "$case_package" = available ] || return 23
        : > "$2/old.deb"
        printf '%s\n' "$2/old.deb"
    }
    install_singbox_package_file() {
        write_update_test_binary 1.13.13
        printf 'package unit\n' > "$SINGBOX_TEST_SERVICE_ROOT/$case_entry"
        case_active=1
    }
    run_singbox_installer() {
        if [ "$case_failure" != early ]; then
            write_update_test_binary 1.13.14
            local entry
            while IFS= read -r entry; do
                printf 'new package unit\n' > "$SINGBOX_TEST_SERVICE_ROOT/$entry"
            done < <(singbox_update_service_entries "$case_manager")
        fi
        return 23
    }
    # 只在恢复文件的最终 rename 处注入失败，不绕过生产恢复逻辑。
    mv() {
        if [ "$case_restore_failure" = 1 ] && [[ "${!#}" == "$SINGBOX_TEST_SERVICE_ROOT/"* ]]; then
            return 23
        fi
        command mv "$@"
    }
    setup_service() { fail '更新失败的回滚不得重建服务模板'; }
}

assert_service_update_restored() {
    local active="$1" enabled="$2" managed="$3" entry
    assert_eq 1.13.13 "$(singbox_version)"
    cmp -s "$case_root/original" "$SINGBOX_TEST_SERVICE_ROOT/$case_entry" || fail '原服务定义必须逐字恢复'
    assert_eq 640 "$(stat -c '%a' "$SINGBOX_TEST_SERVICE_ROOT/$case_entry")"
    assert_eq 0:0 "$(stat -c '%u:%g' "$SINGBOX_TEST_SERVICE_ROOT/$case_entry")"
    assert_eq "$active" "$case_active"
    assert_eq "$enabled" "$case_enabled"
    assert_eq "$managed" "$case_managed"
    while IFS= read -r entry; do
        [ "$entry" = "$case_entry" ] || [ ! -e "$SINGBOX_TEST_SERVICE_ROOT/$entry" ] ||
            fail '原本不存在的服务文件必须清除'
    done < <(singbox_update_service_entries "$case_manager")
    [ ! -e "$SINGBOX_UPDATE_TRANSACTION_DIR" ] || fail '成功恢复后应清理事务'
}

test_update_failure_restores_original_service_matrix() {
    require_root_permission_semantics || return "$?"
    local manager phase active enabled managed
    for manager in systemd openrc; do
        for phase in early mutated; do
            for active in 0 1; do
                for enabled in 0 1; do
                    for managed in 0 1; do
                        [ "$active" = 1 ] || [ "$managed" = 0 ] || continue
                        (
                            setup_service_update_case "$manager-$phase-$active-$enabled-$managed" "$manager"
                            case_failure="$phase" case_active="$active" case_enabled="$enabled" case_managed="$managed"
                            if [ "$managed" = 1 ]; then
                                sed -i 's@run -c /etc/sing-box/custom.json@run -C /etc/sing-box/vpsbox.d@' \
                                    "$SINGBOX_TEST_SERVICE_ROOT/$case_entry"
                                cp -a "$SINGBOX_TEST_SERVICE_ROOT/$case_entry" "$case_root/original"
                            fi
                            if update_singbox > "$case_root/output" 2>&1; then fail '安装失败必须返回失败'; fi
                            assert_service_update_restored "$active" "$enabled" "$managed"
                        )
                    done
                done
            done
        done
    done
}

test_update_package_rollback_restores_custom_service() {
    require_root_permission_semantics || return "$?"
    (
        setup_service_update_case package
        case_package=available case_failure=mutated
        if update_singbox > "$case_root/output" 2>&1; then fail '安装失败必须返回失败'; fi
        assert_service_update_restored 1 1 0
    )
}

test_update_service_snapshot_recovers_on_next_start() {
    require_root_permission_semantics || return "$?"
    (
        setup_service_update_case startup
        local backup_dir='' enabled='' active=''
        prepare_singbox_update_transaction "$case_binary" 1.13.13 backup_dir enabled active
        case_failure=mutated
        run_singbox_installer || true
        # 丢弃进程内句柄，恢复只能依赖持久记录。
        # shellcheck disable=SC2034 # 生产事务清理函数动态读取。
        ACTIVE_SINGBOX_UPDATE_DIR=''
        recover_pending_singbox_update > "$case_root/output" 2>&1
        assert_service_update_restored 1 1 0
    )
}

test_update_service_restore_failure_retains_transaction() {
    require_root_permission_semantics || return "$?"
    local failure
    for failure in file reload start; do
        (
            setup_service_update_case "restore-$failure"
            case_failure=mutated case_package=available
            case "$failure" in
                file) case_restore_failure=1 ;;
                reload) case_reload_failure=1 ;;
                start) service_start() { return 23; } ;;
            esac
            if update_singbox > "$case_root/output" 2>&1; then fail '恢复失败不得报成功'; fi
            [ -f "$SINGBOX_UPDATE_TRANSACTION_DIR/pending" ] || fail '恢复失败必须保留事务'
            assert_eq 0 "$case_active"
            if [ "$failure" != start ]; then
                assert_file_not_contains "$case_root/events" '^start$' '文件或 reload 失败后不得启动服务'
            fi
        )
    done
}

test_failed_rollback_package_is_stopped_before_binary_fallback() {
    require_root_permission_semantics || return "$?"
    local failure
    for failure in binary stop; do
        (
            setup_service_update_case "package-failure-$failure"
            case_active=0 case_enabled=0 case_failure=mutated case_package=available
            local package_attempted=0
            install_singbox_package_file() {
                write_update_test_binary 1.13.13
                printf 'package unit\n' > "$SINGBOX_TEST_SERVICE_ROOT/$case_entry"
                case_active=1
                package_attempted=1
                return 23
            }
            service_stop() {
                if [ "$package_attempted" = 1 ] && [ "$failure" = stop ]; then
                    return 23
                fi
                case_active=0
                case_managed=0
            }
            mv() {
                if [ "${!#}" = "$case_binary" ]; then
                    printf 'binary-replace:active=%s\n' "$case_active" >> "$case_root/events"
                    return 23
                fi
                command mv "$@"
            }
            if update_singbox > "$case_root/output" 2>&1; then fail '回滚失败必须返回失败'; fi
            [ -f "$SINGBOX_UPDATE_TRANSACTION_DIR/pending" ] || fail '回滚失败必须保留事务'
            if [ "$failure" = binary ]; then
                assert_eq 0 "$case_active" '旧包失败且二进制替换失败后不得留下意外启动的服务'
                assert_file_contains "$case_root/events" '^binary-replace:active=0$' '替换二进制前必须先停止旧包启动的服务'
                assert_file_contains "$case_root/output" '旧 sing-box 二进制恢复失败'
            else
                assert_empty_file "$case_root/events" '旧包启动的服务无法停止时不得覆盖二进制或启动服务'
                assert_file_contains "$case_root/output" '回滚软件包后的 sing-box 未能停止'
            fi
        )
    done
}

test_update_restores_absent_service_and_vendor_definition() {
    require_root_permission_semantics || return "$?"
    local layout
    for layout in absent vendor; do
        (
            setup_service_update_case "layout-$layout"
            rm "$SINGBOX_TEST_SERVICE_ROOT/systemd-local"
            case_active=0 case_enabled=0 case_failure=mutated
            if [ "$layout" = vendor ]; then
                case_entry=systemd-usr
                cp -a "$case_root/original" "$SINGBOX_TEST_SERVICE_ROOT/$case_entry"
                case_active=1
            fi
            if update_singbox > "$case_root/output" 2>&1; then fail '安装失败必须返回失败'; fi
            if [ "$layout" = vendor ]; then
                assert_service_update_restored 1 0 0
            else
                [ -z "$(find "$SINGBOX_TEST_SERVICE_ROOT" -type f -print)" ] || fail '原本没有服务文件时必须清除新增文件'
                assert_eq 0 "$case_active"
                assert_eq 0 "$case_enabled"
                [ ! -e "$SINGBOX_UPDATE_TRANSACTION_DIR" ] || fail '完整恢复后应清理事务'
            fi
        )
    done
}

test_update_service_snapshot_damage_and_legacy_are_rejected() {
    require_root_permission_semantics || return "$?"
    local damage
    for damage in corrupt missing symlink legacy binary; do
        (
            setup_service_update_case "damage-$damage"
            local backup_dir='' enabled='' active=''
            prepare_singbox_update_transaction "$case_binary" 1.13.13 backup_dir enabled active
            case_failure=mutated
            run_singbox_installer || true
            case "$damage" in
                corrupt) printf 'tamper\n' >> "$backup_dir/service/systemd-local" ;;
                missing) rm "$backup_dir/service/systemd-local" ;;
                symlink) mv "$backup_dir/service/systemd-local" "$backup_dir/saved"; ln -s ../saved "$backup_dir/service/systemd-local" ;;
                legacy) sed -i 's/^version=2$/version=1/' "$backup_dir/state"; rm -rf "$backup_dir/service" ;;
                binary) rm "$backup_dir/old-binary" ;;
            esac
            if recover_pending_singbox_update > "$case_root/output" 2>&1; then fail '不完整事务必须拒绝恢复'; fi
            assert_eq 1.13.14 "$(singbox_version)" '拒绝恢复时不得改写二进制'
            assert_empty_file "$case_root/events" '拒绝恢复时不得 reload 或启动服务'
            [ -f "$backup_dir/pending" ] || fail '不完整事务必须保留'
        )
    done
}

test_update_managed_service_restore_requires_original_process() {
    require_root_permission_semantics || return "$?"
    (
        setup_service_update_case missing-managed-process
        case_managed=1 case_failure=mutated
        sed -i 's@run -c /etc/sing-box/custom.json@run -C /etc/sing-box/vpsbox.d@' \
            "$SINGBOX_TEST_SERVICE_ROOT/$case_entry"
        service_start() { case_active=1; case_managed=0; }
        if update_singbox > "$case_root/output" 2>&1; then fail '原受管进程缺失时不得报告恢复成功'; fi
        [ -f "$SINGBOX_UPDATE_TRANSACTION_DIR/pending" ] || fail '服务状态恢复不完整必须保留事务'
        assert_file_contains "$case_root/output" '原服务状态恢复失败'
    )
}

test_update_snapshot_failure_prevents_installer() {
    require_root_permission_semantics || return "$?"
    (
        setup_service_update_case snapshot-failure
        chmod 666 "$SINGBOX_TEST_SERVICE_ROOT/$case_entry"
        run_singbox_installer() { printf 'installer\n' >> "$case_root/events"; return 23; }
        if update_singbox > "$case_root/output" 2>&1; then fail '快照失败必须中止更新'; fi
        assert_empty_file "$case_root/events"
        assert_eq 1 "$case_active"
        assert_eq 1.13.13 "$(singbox_version)"
    )
}

tests=(
    test_update_failure_restores_original_service_matrix
    test_update_package_rollback_restores_custom_service
    test_update_service_snapshot_recovers_on_next_start
    test_update_service_restore_failure_retains_transaction
    test_failed_rollback_package_is_stopped_before_binary_fallback
    test_update_restores_absent_service_and_vendor_definition
    test_update_service_snapshot_damage_and_legacy_are_rejected
    test_update_managed_service_restore_requires_original_process
    test_update_snapshot_failure_prevents_installer
)
run_registered_test_suite "${BASH_SOURCE[0]}" "sing-box service update tests" "${tests[@]}"
