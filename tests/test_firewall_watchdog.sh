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
firewall_runtime_enabled() { return 1; }
firewall_persistence_enabled() { return 1; }
firewall_service_active() { return 1; }

write_mock_commands() {
    mkdir -p "$TEST_TMP/bin"
    printf '%s\n' \
        '#!/bin/sh' \
        'case "${1:-}" in' \
        '  is-enabled|is-active) exit 1 ;;' \
        '  *) exit 0 ;;' \
        'esac' > "$TEST_TMP/bin/systemctl"
    printf '%s\n' \
        '#!/bin/sh' \
        'if [ "${1:-} ${2:-} ${3:-}" = "list table inet" ]; then exit 1; fi' \
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

test_commit_stops_watchdog_and_sleep() {
    local snapshot="" watchdog child elapsed

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

test_identity_mismatch_is_cleaned_without_kill() {
    local dir pid start boot

    CASE_TEST_PIDS=""
    trap cleanup_case_processes EXIT
    reset_firewall_case mismatch
    dir="$RUNTIME_DIR/firewall-rollback.mismatch"
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

    CASE_TEST_PIDS=""
    trap cleanup_case_processes EXIT
    reset_firewall_case pid-only
    dir="$RUNTIME_DIR/firewall-rollback.pid-only"
    mkdir -p "$dir"
    printf '%s\n' '#!/bin/sh' "sleep $FIREWALL_ROLLBACK_SECONDS" > "$dir/rollback.sh"
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

    reset_firewall_case partial
    dir="$RUNTIME_DIR/firewall-rollback.partial"
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
        dir="$RUNTIME_DIR/firewall-rollback.invalid-$suffix"
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

    CASE_TEST_PIDS=""
    trap cleanup_case_processes EXIT
    reset_firewall_case stale
    dir="$RUNTIME_DIR/firewall-rollback.stale"
    mkdir -p "$dir"
    printf '%s\n' '#!/bin/sh' "sleep $FIREWALL_ROLLBACK_SECONDS" > "$dir/rollback.sh"
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
    local name test status passed=0
    local -a required=(
        firewall_create_rollback_snapshot
        firewall_start_rollback_watchdog
        firewall_stop_rollback_watchdog
        firewall_finish_commit
    )
    local -a tests=(
        test_commit_stops_watchdog_and_sleep
        test_immediate_restore_stops_timed_watchdog
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
    printf '%s firewall watchdog tests passed.\n' "$passed"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
