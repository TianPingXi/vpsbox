#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=tests/test_helper.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

# shellcheck source=../vpsbox.sh
source "$REPO_DIR/vpsbox.sh"

CASE_TEST_PIDS=""

cleanup_case_processes() {
    local pid
    for pid in $CASE_TEST_PIDS; do
        kill -KILL "$pid" 2>/dev/null || true
    done
    for pid in $CASE_TEST_PIDS; do
        wait "$pid" 2>/dev/null || true
    done
}

test_cleanup() {
    if [ "${KEEP_TEST_TMP:-0}" = "1" ]; then
        printf '保留测试临时目录：%s\n' "$TEST_TMP" >&2
    else
        rm -rf -- "$TEST_TMP"
    fi
}
trap test_cleanup EXIT

chown() { :; }
# 多数用例只关心快照与 watchdog，因此旧布尔状态入口使用默认桩；
# 新的快照三态探测直接读取命令层的明确状态。
firewall_runtime_enabled() { return 1; }
firewall_persistence_enabled() { return 1; }
firewall_service_active() { return 1; }

write_mock_commands() {
    mkdir -p "$TEST_TMP/bin"
    printf '%s\n' \
        '#!/bin/sh' \
        'case "${1:-}" in' \
        '  is-enabled) printf "%s\n" disabled; exit 1 ;;' \
        '  is-active) printf "%s\n" inactive; exit 3 ;;' \
        '  *) exit 0 ;;' \
        'esac' > "$TEST_TMP/bin/systemctl"
    printf '%s\n' \
        '#!/bin/sh' \
        'if [ "${1:-} ${2:-} ${3:-}" = "list table inet" ]; then exit 1; fi' \
        'if [ "${1:-} ${2:-}" = "list tables" ]; then exit 0; fi' \
        'exit 0' > "$TEST_TMP/bin/nft"
    printf '%s\n' '#!/bin/sh' 'exit 0' > "$TEST_TMP/bin/rc-update"
    printf '%s\n' \
        '#!/bin/sh' \
        'if [ "${2:-}" = "status" ]; then exit 1; fi' \
        'exit 0' > "$TEST_TMP/bin/rc-service"
    chmod 755 "$TEST_TMP/bin/systemctl" "$TEST_TMP/bin/nft" \
        "$TEST_TMP/bin/rc-update" "$TEST_TMP/bin/rc-service"
    PATH="$TEST_TMP/bin:$PATH"
    export PATH
}

reset_firewall_case() {
    local name="$1"

    CASE_DIR="$TEST_TMP/$name"
    RUNTIME_DIR="$CASE_DIR/run"
    VPSBOX_STATE_DIR="$CASE_DIR/state"
    FIREWALL_ROLLBACK_DIR="$VPSBOX_STATE_DIR/firewall-rollbacks"
    # These globals are consumed by functions sourced from vpsbox.sh.
    # shellcheck disable=SC2034
    FIREWALL_CONFIG="$CASE_DIR/etc/vpsbox-firewall.nft"
    # shellcheck disable=SC2034
    FIREWALL_STATE_FILE="$CASE_DIR/etc/firewall.env"
    # shellcheck disable=SC2034
    FIREWALL_SYSTEMD_UNIT="$CASE_DIR/etc/vpsbox-firewall.service"
    # shellcheck disable=SC2034
    FIREWALL_OPENRC_SERVICE="$CASE_DIR/etc/vpsbox-firewall"
    # shellcheck disable=SC2034
    FIREWALL_SERVICE_NAME="vpsbox-firewall-test"
    FIREWALL_OPENRC_RUNLEVELS_DIR="$CASE_DIR/runlevels"
    FIREWALL_ROLLBACK_SECONDS=30
    # shellcheck disable=SC2034
    ACTIVE_FIREWALL_ROLLBACK_DIR=""
    mkdir -p "$CASE_DIR/etc"
}

wait_for_sleep_child() {
    local parent="$1" output_var="$2" detected_child=""

    for _ in {1..30}; do
        if [ -r "/proc/$parent/task/$parent/children" ]; then
            detected_child="$(awk '{print $1}' "/proc/$parent/task/$parent/children")"
            [ -n "$detected_child" ] && break
        fi
        sleep 0.1
    done
    [ -n "$detected_child" ] || fail "watchdog 未创建 sleep 子进程"
    printf -v "$output_var" '%s' "$detected_child"
}

assert_process_gone() {
    local pid="$1" message="$2"

    for _ in {1..30}; do
        [ ! -e "/proc/$pid" ] && return 0
        sleep 0.1
    done
    fail "$message（PID $pid，状态：$(cat "/proc/$pid/stat" 2>/dev/null || echo 未知)）"
}

write_managed_firewall_fixture() {
    cat > "$FIREWALL_CONFIG" <<'EOF'
table inet vpsbox {
    chain input {
        type filter hook input priority filter; policy drop;
        tcp dport { 22 } accept
    }
}
EOF
}

wait_for_snapshot_rollback() {
    local snapshot="$1"

    for _ in {1..60}; do
        [ -e "$snapshot/rolled-back" ] && return 0
        [ ! -e "$snapshot/rollback-failed" ] ||
            fail "watchdog 自动回滚失败：$(cat "$snapshot/rollback.log" 2>/dev/null || true)"
        sleep 0.1
    done
    fail "watchdog 未在预期时间内完成自动回滚"
}

test_commit_stops_watchdog_and_sleep() {
    local snapshot="" watchdog child elapsed

    require_linux_proc || return "$?"
    CASE_TEST_PIDS=""
    trap cleanup_case_processes EXIT
    reset_firewall_case commit
    firewall_create_rollback_snapshot snapshot ""
    [[ "$snapshot" == "$FIREWALL_ROLLBACK_DIR"/firewall-rollback.* ]] ||
        fail "新防火墙回滚快照必须保存在持久目录"
    firewall_start_rollback_watchdog "$snapshot"
    watchdog="$(cat "$snapshot/watchdog.pid")"
    CASE_TEST_PIDS="$watchdog"
    wait_for_sleep_child "$watchdog" child
    CASE_TEST_PIDS="$CASE_TEST_PIDS $child"

    firewall_begin_commit "$snapshot"
    SECONDS=0
    firewall_finish_commit "$snapshot"
    elapsed=$SECONDS

    [ ! -e "$snapshot" ] || fail "提交后应删除回滚快照"
    [ "$elapsed" -le 5 ] || fail "提交后的进程清理过慢（${elapsed} 秒）"
    assert_process_gone "$watchdog" "提交后 watchdog 仍在运行"
    assert_process_gone "$child" "提交后 sleep 子进程仍在运行"
    CASE_TEST_PIDS=""
    trap - EXIT
}

test_immediate_restore_stops_timed_watchdog() {
    local snapshot="" watchdog child elapsed

    require_linux_proc || return "$?"
    CASE_TEST_PIDS=""
    trap cleanup_case_processes EXIT
    reset_firewall_case restore
    firewall_create_rollback_snapshot snapshot ""
    firewall_start_rollback_watchdog "$snapshot"
    watchdog="$(cat "$snapshot/watchdog.pid")"
    CASE_TEST_PIDS="$watchdog"
    wait_for_sleep_child "$watchdog" child
    CASE_TEST_PIDS="$CASE_TEST_PIDS $child"

    SECONDS=0
    firewall_restore_snapshot_now "$snapshot" 0
    elapsed=$SECONDS

    [ ! -e "$snapshot" ] || fail "恢复后应删除回滚快照"
    [ "$elapsed" -le 5 ] || fail "恢复后的进程清理过慢（${elapsed} 秒）"
    assert_process_gone "$watchdog" "恢复后 watchdog 仍在运行"
    assert_process_gone "$child" "恢复后 sleep 子进程仍在运行"
    CASE_TEST_PIDS=""
    trap - EXIT
}

test_snapshot_rejects_unknown_capture_states() {
    local state

    for state in runtime persistence service; do
        (
            local snapshot="" output="$TEST_TMP/snapshot-unknown-$state.out"

            reset_firewall_case "snapshot-unknown-$state"
            is_systemd() { return 0; }
            case "$state" in
                runtime)
                    nft() { return 2; }
                    ;;
                persistence)
                    systemctl() {
                        case "${1:-}" in
                            is-enabled) return 4 ;;
                            is-active) printf '%s\n' inactive; return 3 ;;
                            *) return 0 ;;
                        esac
                    }
                    ;;
                service)
                    systemctl() {
                        case "${1:-}" in
                            is-enabled) printf '%s\n' disabled; return 1 ;;
                            is-active) return 4 ;;
                            *) return 0 ;;
                        esac
                    }
                    ;;
            esac

            if firewall_create_rollback_snapshot snapshot "" > "$output" 2>&1; then
                fail "防火墙 $state 状态未知时不得创建回滚快照"
            fi
            [ -z "$snapshot" ] || fail "失败时不得发布回滚快照路径"
            [ -z "${ACTIVE_FIREWALL_ROLLBACK_DIR:-}" ] ||
                fail "失败时不得留下活动回滚快照"
            [ -z "$(find "$FIREWALL_ROLLBACK_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ] ||
                fail "状态探测失败后必须清理快照构建目录"
            assert_file_contains "$output" '无法确认防火墙.*状态'
        )
    done
}

test_snapshot_accepts_confirmed_negative_service_states() {
    local backend

    for backend in systemd openrc; do
        (
            local snapshot=""

            reset_firewall_case "snapshot-negative-$backend"
            if [ "$backend" = systemd ]; then
                is_systemd() { return 0; }
                systemctl() {
                    case "${1:-}" in
                        is-enabled) printf '%s\n' disabled; return 1 ;;
                        is-active) printf '%s\n' inactive; return 3 ;;
                        *) return 0 ;;
                    esac
                }
            else
                OS=alpine
                is_systemd() { return 1; }
                mkdir -p "$FIREWALL_OPENRC_RUNLEVELS_DIR/default"
                rc-service() {
                    [ "${2:-}" = status ] || return 1
                    return 3
                }
            fi

            firewall_create_rollback_snapshot snapshot "" ||
                fail "$backend 已确认 disabled/inactive 时应能创建快照"
            [ ! -e "$snapshot/service.enabled" ] ||
                fail "$backend disabled 状态不得记录 enabled 标记"
            [ ! -e "$snapshot/service.active" ] ||
                fail "$backend inactive 状态不得记录 active 标记"
        )
    done
}

test_snapshot_runtime_probe_recognizes_partial_table() {
    local runtime_result="" table_file

    reset_firewall_case snapshot-partial-table
    table_file="$CASE_DIR/partial-table.nft"
    nft() {
        case "$*" in
            'list table inet vpsbox')
                printf '%s\n' \
                    'table inet vpsbox {' \
                    '    chain partial {' \
                    '    }' \
                    '}'
                ;;
            'list tables') printf '%s\n' 'table inet vpsbox' ;;
            *) return 1 ;;
        esac
    }

    firewall_snapshot_runtime_state runtime_result "$table_file" ||
        fail "缺少 input 链的既有 vpsbox 表仍应识别为 present"
    assert_eq present "$runtime_result"
    assert_file_contains "$table_file" '^table inet vpsbox \{$'
    assert_file_contains "$table_file" 'chain partial'
}

test_natural_timeout_rolls_back_snapshot() {
    local snapshot="" watchdog original="$TEST_TMP/natural-timeout-original.nft"

    require_linux_proc || return "$?"
    CASE_TEST_PIDS=""
    trap cleanup_case_processes EXIT
    reset_firewall_case natural-timeout
    FIREWALL_ROLLBACK_SECONDS=2
    write_managed_firewall_fixture
    cp "$FIREWALL_CONFIG" "$original"
    firewall_create_rollback_snapshot snapshot "22" ||
        fail "自然超时测试无法创建回滚快照"
    firewall_start_rollback_watchdog "$snapshot"
    watchdog="$(cat "$snapshot/watchdog.pid")"
    CASE_TEST_PIDS="$watchdog"
    printf '%s\n' 'temporary-unconfirmed-rules' > "$FIREWALL_CONFIG"

    wait_for_snapshot_rollback "$snapshot"
    cmp -s "$original" "$FIREWALL_CONFIG" ||
        fail "自然超时后未恢复倒计时开始前的防火墙配置"
    [ ! -e "$snapshot/rollback-failed" ] || fail "自然超时回滚留下失败标记"
    assert_process_gone "$watchdog" "自然超时回滚后 watchdog 仍在运行"
    CASE_TEST_PIDS=""
    trap - EXIT
}

test_hup_does_not_cancel_timeout_rollback() {
    local snapshot="" watchdog child original="$TEST_TMP/hup-timeout-original.nft"

    require_linux_proc || return "$?"
    CASE_TEST_PIDS=""
    trap cleanup_case_processes EXIT
    reset_firewall_case hup-timeout
    # shellcheck disable=SC2034 # 被测回滚脚本生成器动态读取此超时覆写。
    FIREWALL_ROLLBACK_SECONDS=2
    write_managed_firewall_fixture
    cp "$FIREWALL_CONFIG" "$original"
    firewall_create_rollback_snapshot snapshot "22" ||
        fail "HUP 测试无法创建回滚快照"
    firewall_start_rollback_watchdog "$snapshot"
    watchdog="$(cat "$snapshot/watchdog.pid")"
    CASE_TEST_PIDS="$watchdog"
    wait_for_sleep_child "$watchdog" child
    CASE_TEST_PIDS="$CASE_TEST_PIDS $child"
    printf '%s\n' 'temporary-unconfirmed-rules' > "$FIREWALL_CONFIG"

    kill -HUP "$watchdog"
    sleep 0.1
    kill -0 "$watchdog" 2>/dev/null ||
        fail "nohup 启动的 watchdog 不应因 HUP 提前退出"
    wait_for_snapshot_rollback "$snapshot"
    cmp -s "$original" "$FIREWALL_CONFIG" ||
        fail "HUP 后倒计时结束时未恢复原防火墙配置"
    [ ! -e "$snapshot/rollback-failed" ] || fail "HUP 后自动回滚留下失败标记"
    assert_process_gone "$watchdog" "HUP 后完成回滚的 watchdog 仍在运行"
    CASE_TEST_PIDS=""
    trap - EXIT
}

test_enabled_active_service_state_is_restored() {
    local snapshot="" state_dir="$TEST_TMP/service-state" log="$TEST_TMP/service-state.log"

    if [ ! -d /run/systemd/system ]; then
        skip "需要 systemd 运行目录才能验证服务状态恢复"
        return "$SKIP_STATUS"
    fi
    reset_firewall_case service-state
    mkdir -p "$state_dir"
    : > "$log"
    export MOCK_SYSTEMCTL_STATE_DIR="$state_dir"
    export MOCK_SYSTEMCTL_LOG="$log"
    cat > "$TEST_TMP/bin/systemctl" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$MOCK_SYSTEMCTL_LOG"
case "${1:-}" in
    daemon-reload) exit 0 ;;
    enable) : > "$MOCK_SYSTEMCTL_STATE_DIR/enabled"; exit 0 ;;
    disable) rm -f "$MOCK_SYSTEMCTL_STATE_DIR/enabled"; exit 0 ;;
    restart|start) : > "$MOCK_SYSTEMCTL_STATE_DIR/active"; exit 0 ;;
    stop) rm -f "$MOCK_SYSTEMCTL_STATE_DIR/active"; exit 0 ;;
    is-enabled)
        if [ -e "$MOCK_SYSTEMCTL_STATE_DIR/enabled" ]; then
            printf '%s\n' enabled
        else
            printf '%s\n' disabled
            exit 1
        fi
        ;;
    is-active)
        if [ -e "$MOCK_SYSTEMCTL_STATE_DIR/active" ]; then
            printf '%s\n' active
        else
            printf '%s\n' inactive
            exit 3
        fi
        ;;
    *) exit 0 ;;
esac
EOF
    chmod 755 "$TEST_TMP/bin/systemctl"
    : > "$state_dir/enabled"
    : > "$state_dir/active"

    firewall_create_rollback_snapshot snapshot "" ||
        fail "服务状态恢复测试无法创建回滚快照"
    [ -e "$snapshot/service.enabled" ] || fail "快照未记录服务自启状态"
    [ -e "$snapshot/service.active" ] || fail "快照未记录服务运行状态"

    sh "$snapshot/rollback.sh" --now ||
        fail "已启用且运行中的服务状态未能恢复"
    [ -e "$state_dir/enabled" ] || fail "回滚未恢复服务自启状态"
    [ -e "$state_dir/active" ] || fail "回滚未恢复服务运行状态"
    assert_file_contains "$log" '^enable vpsbox-firewall-test$'
    assert_file_contains "$log" '^restart vpsbox-firewall-test$'
    [ -e "$snapshot/rolled-back" ] || fail "服务状态恢复后缺少 rolled-back 标记"
    [ ! -e "$snapshot/rollback-failed" ] || fail "服务状态恢复留下失败标记"
    write_mock_commands
}

test_openrc_enabled_active_service_state_is_restored() {
    local snapshot="" state_dir="$TEST_TMP/openrc-service-state"
    local log="$TEST_TMP/openrc-service-state.log"
    local openrc_bin="$TEST_TMP/openrc-bin" command_name command_path

    require_linux_proc || return "$?"
    reset_firewall_case openrc-service-state
    mkdir -p "$state_dir" "$FIREWALL_OPENRC_RUNLEVELS_DIR/default" "$openrc_bin"
    : > "$log"
    export MOCK_OPENRC_STATE_DIR="$state_dir"
    export MOCK_OPENRC_LOG="$log"
    export MOCK_OPENRC_RUNLEVELS_DIR="$FIREWALL_OPENRC_RUNLEVELS_DIR"
    # shellcheck disable=SC2034 # 被测 firewall_persistence_enabled 动态读取。
    OS=alpine
    is_systemd() { return 1; }
    cat > "$openrc_bin/rc-update" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$MOCK_OPENRC_LOG"
case "${1:-}" in
    add)
        mkdir -p "$MOCK_OPENRC_RUNLEVELS_DIR/${3:?}"
        : > "$MOCK_OPENRC_RUNLEVELS_DIR/$3/${2:?}"
        ;;
    del)
        rm -f "$MOCK_OPENRC_RUNLEVELS_DIR/${3:?}/${2:?}"
        ;;
    *) exit 1 ;;
esac
EOF
    cat > "$openrc_bin/rc-service" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$MOCK_OPENRC_LOG"
case "${2:-}" in
    restart|start)
        : > "$MOCK_OPENRC_STATE_DIR/active"
        ;;
    stop)
        rm -f "$MOCK_OPENRC_STATE_DIR/active"
        ;;
    status)
        [ -e "$MOCK_OPENRC_STATE_DIR/active" ]
        ;;
    *) exit 1 ;;
esac
EOF
    chmod 755 "$openrc_bin/rc-update" "$openrc_bin/rc-service"
    for command_name in awk cat chmod cp dirname ln mkdir mktemp mv rm rmdir sleep; do
        command_path="$(command -v "$command_name")" ||
            fail "OpenRC 回滚测试缺少命令：$command_name"
        ln -s "$command_path" "$openrc_bin/$command_name"
    done
    : > "$FIREWALL_OPENRC_RUNLEVELS_DIR/default/$FIREWALL_SERVICE_NAME"
    : > "$state_dir/active"
    PATH="$openrc_bin:$PATH"
    export PATH

    firewall_create_rollback_snapshot snapshot "" ||
        fail "OpenRC 服务状态恢复测试无法创建回滚快照"
    [ -e "$snapshot/service.enabled" ] || fail "快照未记录 OpenRC 服务自启状态"
    [ -e "$snapshot/service.active" ] || fail "快照未记录 OpenRC 服务运行状态"
    rm -f "$FIREWALL_OPENRC_RUNLEVELS_DIR/default/$FIREWALL_SERVICE_NAME"

    PATH="$openrc_bin" /bin/sh "$snapshot/rollback.sh" --now ||
        fail "已启用且运行中的 OpenRC 服务状态未能恢复"
    [ -e "$FIREWALL_OPENRC_RUNLEVELS_DIR/default/$FIREWALL_SERVICE_NAME" ] ||
        fail "OpenRC 回滚未恢复服务自启状态"
    [ -e "$state_dir/active" ] || fail "OpenRC 回滚未恢复服务运行状态"
    assert_file_contains "$log" '^add vpsbox-firewall-test default$'
    assert_file_contains "$log" '^vpsbox-firewall-test restart$'
    [ -e "$snapshot/rolled-back" ] || fail "OpenRC 服务状态恢复后缺少 rolled-back 标记"
    [ ! -e "$snapshot/rollback-failed" ] || fail "OpenRC 服务状态恢复留下失败标记"
}

test_legacy_runtime_snapshot_is_rejected() {
    local legacy current

    reset_firewall_case snapshot-path-baseline
    legacy="$RUNTIME_DIR/firewall-rollback.legacy"
    current="$FIREWALL_ROLLBACK_DIR/firewall-rollback.current"
    mkdir -p "$legacy" "$current"

    if firewall_rollback_dir_valid "$legacy"; then
        fail "v1.0.43 兼容基线不应再接受 /run 中的旧防火墙快照"
    fi
    firewall_rollback_dir_valid "$current" ||
        fail "当前持久化防火墙快照路径必须继续接受"
}

test_stale_restore_lock_is_reclaimed() {
    local snapshot=""

    require_linux_proc || return "$?"
    reset_firewall_case stale-restore-lock
    firewall_create_rollback_snapshot snapshot ""
    mkdir "$snapshot/restore.lock"
    {
        printf 'pid=%s\n' 999999
        printf 'start=%s\n' 1
        printf 'boot=%s\n' "$(cat /proc/sys/kernel/random/boot_id)"
    } > "$snapshot/restore.lock/owner"

    firewall_restore_snapshot_now "$snapshot" 0

    [ ! -e "$snapshot" ] ||
        fail "SIGKILL 遗留的 restore.lock 不应永久阻塞快照恢复"
}

test_restore_lock_metadata_is_atomically_published() {
    local snapshot=""

    reset_firewall_case atomic-restore-lock
    firewall_create_rollback_snapshot snapshot ""

    assert_file_contains "$snapshot/rollback.sh" \
        '[.]restore[.]lock[.]owner[.]\$\$'
    assert_file_contains "$snapshot/rollback.sh" \
        'mv[[:space:]]+-f[[:space:]]+"\$[^"]+"[[:space:]]+"\$lock_dir/owner"'
    assert_file_not_contains "$snapshot/rollback.sh" \
        '>[[:space:]]*"\$lock_dir/owner"'
    assert_file_contains "$snapshot/rollback.sh" \
        'mktemp "\$parent/[.]vpsbox-firewall-restore[.]XXXXXX"'
    assert_file_contains "$snapshot/rollback.sh" \
        'mv[[:space:]]+-f[[:space:]]+"\$[^"]+"[[:space:]]+"\$target"'
    assert_file_contains "$snapshot/rollback.sh" \
        'if \[ -L "\$target" \]; then'
    assert_file_contains "$snapshot/rollback.sh" \
        '\[ ! -d "\$target" \] \|\| return 1'
    assert_file_not_contains "$snapshot/rollback.sh" \
        '>[[:space:]]*"\$lock_dir/pid"'
}

test_rollback_rejects_directory_symlink_target() {
    local snapshot="" victim

    require_real_symlink directory || return "$?"
    reset_firewall_case directory-symlink-target
    cat > "$FIREWALL_CONFIG" <<'EOF'
table inet vpsbox {
    chain input {
        type filter hook input priority filter; policy drop;
        tcp dport { 22 } accept
    }
}
EOF
    firewall_create_rollback_snapshot snapshot "22"
    rm -f "$FIREWALL_CONFIG"
    victim="$CASE_DIR/linked-directory"
    mkdir "$victim"
    ln -s "$victim" "$FIREWALL_CONFIG"

    if sh "$snapshot/rollback.sh" --now >/dev/null 2>&1; then
        fail "防火墙回滚不得把目录符号链接当作恢复目录"
    fi
    [ -L "$FIREWALL_CONFIG" ] || fail "失败后应保留原目标符号链接"
    [ -z "$(find "$victim" -mindepth 1 -maxdepth 1 -print -quit)" ] ||
        fail "防火墙回滚不得向符号链接指向的目录写入文件"
    [ -e "$snapshot/rollback-failed" ] || fail "失败的防火墙回滚应保留可重试标记"
}

test_identity_mismatch_is_cleaned_without_kill() {
    local dir pid start boot

    require_linux_proc || return "$?"
    CASE_TEST_PIDS=""
    trap cleanup_case_processes EXIT
    reset_firewall_case mismatch
    dir="$FIREWALL_ROLLBACK_DIR/firewall-rollback.mismatch"
    mkdir -p "$dir"
    : > "$dir/completed"
    sleep 30 &
    pid=$!
    CASE_TEST_PIDS="$pid"
    start="$(process_start_ticks "$pid")"
    boot="$(cat /proc/sys/kernel/random/boot_id)"
    printf '%s\n' "$pid" > "$dir/watchdog.pid"
    printf '%s\n' "$start" > "$dir/watchdog.start"
    printf '%s\n' "$boot" > "$dir/watchdog.boot"

    firewall_cleanup_finished_rollback "$dir"
    [ ! -e "$dir" ] || fail "身份不匹配的旧元数据应完成清理"
    kill -0 "$pid" 2>/dev/null || fail "身份不匹配的进程不应被终止"
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    CASE_TEST_PIDS=""
    trap - EXIT
}

test_pid_only_partial_watchdog_is_stopped() {
    local dir watchdog child elapsed

    require_linux_proc || return "$?"
    CASE_TEST_PIDS=""
    trap cleanup_case_processes EXIT
    reset_firewall_case pid-only
    dir="$FIREWALL_ROLLBACK_DIR/firewall-rollback.pid-only"
    mkdir -p "$dir"
    printf '%s\n' '#!/bin/sh' 'while :; do sleep 1; done' > "$dir/rollback.sh"
    chmod 700 "$dir/rollback.sh"
    : > "$dir/completed"
    nohup sh "$dir/rollback.sh" >/dev/null 2>&1 &
    watchdog=$!
    printf '%s\n' "$watchdog" > "$dir/watchdog.pid"
    CASE_TEST_PIDS="$watchdog"
    wait_for_sleep_child "$watchdog" child
    CASE_TEST_PIDS="$CASE_TEST_PIDS $child"

    SECONDS=0
    firewall_cleanup_finished_rollback "$dir"
    elapsed=$SECONDS

    [ ! -e "$dir" ] || fail "只写入 PID 的中断快照应完成清理"
    [ "$elapsed" -le 5 ] || fail "只写入 PID 的 watchdog 清理过慢（${elapsed} 秒）"
    assert_process_gone "$watchdog" "只写入 PID 的 watchdog 仍在运行"
    assert_process_gone "$child" "只写入 PID 的 sleep 子进程仍在运行"
    CASE_TEST_PIDS=""
    trap - EXIT
}

test_partial_dead_metadata_is_cleaned() {
    local dir

    require_linux_proc || return "$?"
    reset_firewall_case partial
    dir="$FIREWALL_ROLLBACK_DIR/firewall-rollback.partial"
    mkdir -p "$dir"
    : > "$dir/completed"
    printf '%s\n' 12345 > "$dir/watchdog.start"

    firewall_cleanup_finished_rollback "$dir"
    [ ! -e "$dir" ] || fail "无存活进程的部分元数据不应阻塞清理"
}

test_invalid_pid_metadata_is_cleaned() {
    local dir suffix

    for suffix in empty invalid; do
        reset_firewall_case "invalid-$suffix"
        dir="$FIREWALL_ROLLBACK_DIR/firewall-rollback.invalid-$suffix"
        mkdir -p "$dir"
        : > "$dir/completed"
        if [ "$suffix" = "empty" ]; then
            : > "$dir/watchdog.pid"
        else
            printf '%s\n' not-a-pid > "$dir/watchdog.pid"
        fi

        firewall_cleanup_finished_rollback "$dir" >/dev/null
        [ ! -e "$dir" ] || fail "损坏的 $suffix PID 元数据不应阻塞清理"
    done
}

test_stale_pid_does_not_hide_real_watchdog() {
    local dir unrelated watchdog child start boot elapsed

    require_linux_proc || return "$?"
    CASE_TEST_PIDS=""
    trap cleanup_case_processes EXIT
    reset_firewall_case stale
    dir="$FIREWALL_ROLLBACK_DIR/firewall-rollback.stale"
    mkdir -p "$dir"
    printf '%s\n' '#!/bin/sh' 'while :; do sleep 1; done' > "$dir/rollback.sh"
    chmod 700 "$dir/rollback.sh"
    : > "$dir/completed"

    sleep 30 &
    unrelated=$!
    nohup sh "$dir/rollback.sh" >/dev/null 2>&1 &
    watchdog=$!
    CASE_TEST_PIDS="$unrelated $watchdog"
    wait_for_sleep_child "$watchdog" child
    CASE_TEST_PIDS="$CASE_TEST_PIDS $child"
    start="$(process_start_ticks "$unrelated")"
    boot="$(cat /proc/sys/kernel/random/boot_id)"
    printf '%s\n' "$unrelated" > "$dir/watchdog.pid"
    printf '%s\n' "$start" > "$dir/watchdog.start"
    printf '%s\n' "$boot" > "$dir/watchdog.boot"

    SECONDS=0
    firewall_cleanup_finished_rollback "$dir"
    elapsed=$SECONDS

    [ ! -e "$dir" ] || fail "陈旧 PID 快照应完成清理"
    [ "$elapsed" -le 5 ] || fail "陈旧 PID 后的真实 watchdog 清理过慢（${elapsed} 秒）"
    kill -0 "$unrelated" 2>/dev/null || fail "陈旧 PID 指向的无关进程不应被终止"
    assert_process_gone "$watchdog" "陈旧 PID 掩盖了真实 watchdog"
    assert_process_gone "$child" "陈旧 PID 掩盖了真实 sleep 子进程"
    kill -TERM "$unrelated" 2>/dev/null || true
    wait "$unrelated" 2>/dev/null || true
    CASE_TEST_PIDS=""
    trap - EXIT
}

main() {
    local name test status passed=0 skipped=0
    local -a required=(
        firewall_create_rollback_snapshot
        firewall_snapshot_runtime_state
        firewall_snapshot_persistence_state
        firewall_snapshot_service_state
        firewall_persistence_enabled
        firewall_restore_snapshot_now
        firewall_start_rollback_watchdog
        firewall_stop_rollback_watchdog
        firewall_finish_commit
        firewall_rollback_dir_valid
    )
    local -a tests=(
        test_commit_stops_watchdog_and_sleep
        test_immediate_restore_stops_timed_watchdog
        test_snapshot_rejects_unknown_capture_states
        test_snapshot_accepts_confirmed_negative_service_states
        test_snapshot_runtime_probe_recognizes_partial_table
        test_natural_timeout_rolls_back_snapshot
        test_hup_does_not_cancel_timeout_rollback
        test_enabled_active_service_state_is_restored
        test_openrc_enabled_active_service_state_is_restored
        test_legacy_runtime_snapshot_is_rejected
        test_stale_restore_lock_is_reclaimed
        test_restore_lock_metadata_is_atomically_published
        test_rollback_rejects_directory_symlink_target
        test_identity_mismatch_is_cleaned_without_kill
        test_pid_only_partial_watchdog_is_stopped
        test_partial_dead_metadata_is_cleaned
        test_invalid_pid_metadata_is_cleaned
        test_stale_pid_does_not_hide_real_watchdog
    )

    write_mock_commands
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
    printf '%s firewall watchdog tests passed, %s skipped, %s registered.\n' \
        "$passed" "$skipped" "${#tests[@]}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
