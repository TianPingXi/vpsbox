#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=tests/test_helper.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

# shellcheck source=../vpsbox.sh
source "$REPO_DIR/vpsbox.sh"

ACTIVE_TEST_CHILD_FILE=""

test_cleanup() {
    if [ "${KEEP_TEST_TMP:-0}" = "1" ]; then
        printf '保留测试临时目录：%s\n' "$TEST_TMP" >&2
    else
        rm -rf -- "$TEST_TMP"
    fi
}
trap test_cleanup EXIT

assert_pid_gone() {
    local pid="$1" message="$2"

    for _ in {1..30}; do
        [ ! -e "/proc/$pid" ] && return 0
        sleep 0.1
    done
    fail "$message（PID $pid）"
}

cleanup_active_test_sleep() {
    cleanup_sleep_from_file "$ACTIVE_TEST_CHILD_FILE"
}

cleanup_sleep_from_file() {
    local file="$1" pid
    local -a args=()

    [ -s "$file" ] || return 0
    IFS= read -r pid < "$file" || return 0
    [[ "$pid" =~ ^[0-9]+$ ]] || return 0
    [ -r "/proc/$pid/cmdline" ] || return 0
    mapfile -d '' -t args < "/proc/$pid/cmdline" 2>/dev/null || true
    [ "${#args[@]}" -eq 2 ] && [[ "${args[0]}" == sleep || "${args[0]}" == */sleep ]] &&
        [ "${args[1]}" = "30" ] || return 0
    kill -KILL "$pid" 2>/dev/null || true
}

test_timeout_kills_command_tree() {
    local child_file="$TEST_TMP/timeout-child.pid" status elapsed child

    require_linux_proc || return "$?"
    ACTIVE_TEST_CHILD_FILE="$child_file"
    trap cleanup_active_test_sleep EXIT
    # Consumed by the sourced timeout supervisor.
    # shellcheck disable=SC2034
    PACKAGE_KILL_GRACE=1
    SECONDS=0
    set +e
    run_bounded_command 1 bash -c \
        'sleep 30 & printf "%s\n" "$!" > "$1"; wait' _ "$child_file" >/dev/null 2>&1
    status=$?
    set -e
    elapsed=$SECONDS

    assert_eq 124 "$status" "超时命令应返回 124"
    [ "$elapsed" -le 4 ] || fail "超时命令退出过慢（${elapsed} 秒）"
    [ -s "$child_file" ] || fail "测试子进程 PID 未写入"
    child="$(cat "$child_file")"
    assert_pid_gone "$child" "超时后仍残留子进程"
    trap - EXIT
    ACTIVE_TEST_CHILD_FILE=""
}

test_timeout_is_not_retried() {
    local attempts="$TEST_TMP/timeout-attempts" child_file="$TEST_TMP/retry-child.pid"
    local status count child=""

    require_linux_proc || return "$?"
    ACTIVE_TEST_CHILD_FILE="$child_file"
    trap cleanup_active_test_sleep EXIT
    : > "$attempts"
    # shellcheck disable=SC2034
    PACKAGE_KILL_GRACE=1
    set +e
    retry_bounded_command 3 0 1 bash -c \
        'printf x >> "$1"; sleep 30 & printf "%s\n" "$!" > "$2"; wait' \
        _ "$attempts" "$child_file" >/dev/null 2>&1
    status=$?
    set -e
    count="$(wc -c < "$attempts" | tr -d ' ')"
    child="$(cat "$child_file")"
    assert_eq 124 "$status" "持续超时应返回 124"
    assert_eq 1 "$count" "超时后不应再次执行命令"
    assert_pid_gone "$child" "重试测试残留子进程"
    child=""
    trap - EXIT
    ACTIVE_TEST_CHILD_FILE=""
}

test_timeout_kills_separate_process_group() {
    local child_file="$TEST_TMP/separate-group-child.pid" status child=""

    require_linux_proc || return "$?"
    ACTIVE_TEST_CHILD_FILE="$child_file"
    trap cleanup_active_test_sleep EXIT
    # shellcheck disable=SC2034
    PACKAGE_KILL_GRACE=1
    set +e
    run_bounded_command 1 bash -c \
        'set -m; sleep 30 & printf "%s\n" "$!" > "$1"; wait' _ "$child_file" \
        >/dev/null 2>&1
    status=$?
    set -e
    child="$(cat "$child_file")"

    assert_eq 124 "$status" "独立进程组超时应返回 124"
    assert_pid_gone "$child" "超时后仍残留同会话的新进程组"
    child=""
    trap - EXIT
    ACTIVE_TEST_CHILD_FILE=""
}

test_nonzero_exit_cleans_descendants() {
    local child_file="$TEST_TMP/nonzero-child.pid" status child=""

    require_linux_proc || return "$?"
    ACTIVE_TEST_CHILD_FILE="$child_file"
    trap cleanup_active_test_sleep EXIT
    set +e
    run_bounded_command 30 bash -c \
        'sleep 30 & printf "%s\n" "$!" > "$1"; exit 7' _ "$child_file" \
        >/dev/null 2>&1
    status=$?
    set -e
    child="$(cat "$child_file")"

    assert_eq 7 "$status" "命令原始失败状态应保留"
    assert_pid_gone "$child" "失败命令的子进程未在重试前清理"
    child=""
    trap - EXIT
    ACTIVE_TEST_CHILD_FILE=""
}

test_apt_options_are_bounded() {
    local log="$TEST_TMP/apt-options.log" value option

    run_bounded_command() {
        printf '%s\n' "$*" > "$log"
    }
    # Consumed by the sourced retry wrapper.
    # shellcheck disable=SC2034
    PACKAGE_RETRY_MAX=1
    apt_get_bounded 77 install -y demo

    assert_file_contains "$log" '^77 apt-get '
    value="$(sed -n 's/.*Acquire::Retries=\([0-9][0-9]*\).*/\1/p' "$log")"
    [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -le 3 ] ||
        fail "APT 下载重试次数必须保持在 0-3 次"
    for option in Acquire::http::Timeout Acquire::https::Timeout Dpkg::Lock::Timeout; do
        value="$(sed -n "s/.*${option}=\\([0-9][0-9]*\\).*/\\1/p" "$log")"
        [[ "$value" =~ ^[0-9]+$ ]] &&
            [ "$value" -ge 1 ] && [ "$value" -le 60 ] ||
            fail "$option 必须设置 1-60 秒的有界超时"
    done
    assert_file_contains "$log" 'install -y demo$'
}

test_debian_dependency_install_uses_bounds() {
    local log="$TEST_TMP/install-deps.log" install_line dependency

    detect_os() {
        # Consumed by the sourced install_deps function.
        # shellcheck disable=SC2034
        OS=debian
    }
    apt_get_bounded() { printf '%s\n' "$*" >> "$log"; }
    install_deps

    [ "$PACKAGE_UPDATE_TIMEOUT" -ge 1 ] && [ "$PACKAGE_UPDATE_TIMEOUT" -le 3600 ] ||
        fail "依赖索引更新必须设置不超过 3600 秒的超时"
    [ "$PACKAGE_INSTALL_TIMEOUT" -ge 1 ] && [ "$PACKAGE_INSTALL_TIMEOUT" -le 3600 ] ||
        fail "依赖安装必须设置不超过 3600 秒的超时"
    assert_file_contains "$log" "^${PACKAGE_UPDATE_TIMEOUT} update( -y)?$"
    install_line="$(
        awk -v timeout="$PACKAGE_INSTALL_TIMEOUT" \
            '$1 == timeout && $2 == "install" && $3 == "-y" { print; exit }' "$log"
    )"
    [ -n "$install_line" ] ||
        fail "Debian 依赖安装必须使用 PACKAGE_INSTALL_TIMEOUT"
    for dependency in curl ca-certificates openssl jq iproute2 coreutils; do
        case " $install_line " in
            *" $dependency "*) ;;
            *) fail "Debian 依赖安装缺少必要软件包：$dependency" ;;
        esac
    done
}

test_alpine_dependency_install_uses_bounds() {
    local log="$TEST_TMP/install-deps-alpine.log" install_line dependency

    detect_os() {
        # Consumed by the sourced install_deps function.
        # shellcheck disable=SC2034
        OS=alpine
    }
    apk_bounded() { printf '%s\n' "$*" >> "$log"; }
    install_deps

    assert_file_contains "$log" "^${PACKAGE_UPDATE_TIMEOUT} update$"
    install_line="$(
        awk -v timeout="$PACKAGE_INSTALL_TIMEOUT" \
            '$1 == timeout && $2 == "add" && $3 == "--no-cache" { print; exit }' "$log"
    )"
    [ -n "$install_line" ] ||
        fail "Alpine 依赖安装必须使用 PACKAGE_INSTALL_TIMEOUT 和 --no-cache"
    for dependency in bash curl ca-certificates openssl jq iproute2 coreutils; do
        case " $install_line " in
            *" $dependency "*) ;;
            *) fail "Alpine 依赖安装缺少必要软件包：$dependency" ;;
        esac
    done
}

test_missing_timeout_fails_fast() {
    local empty_path="$TEST_TMP/empty-path" status

    mkdir -p "$empty_path"
    set +e
    PATH="$empty_path" run_bounded_command 1 /bin/true >/dev/null 2>&1
    status=$?
    set -e
    assert_eq 127 "$status" "缺少 timeout 时应明确失败"
}

test_old_busybox_timeout_compatibility() {
    local bin="$TEST_TMP/old-timeout-bin" output="$TEST_TMP/old-timeout.out"

    mkdir -p "$bin"
    printf '%s\n' \
        '#!/bin/sh' \
        'if [ "${1:-}" = "-k" ]; then exit 2; fi' \
        'shift' \
        'exec "$@"' > "$bin/timeout"
    chmod 755 "$bin/timeout"

    PATH="$bin" run_bounded_command 1 /bin/true > "$output" 2>&1 ||
        fail "旧版 BusyBox timeout 兼容模式应可执行"
    assert_file_contains "$output" 'timeout 不支持强制终止延迟'
}

main() {
    local name
    local -a required=(run_bounded_command retry_bounded_command apt_get_bounded install_deps)
    local -a tests=(
        test_timeout_kills_command_tree
        test_timeout_is_not_retried
        test_timeout_kills_separate_process_group
        test_nonzero_exit_cleans_descendants
        test_apt_options_are_bounded
        test_debian_dependency_install_uses_bounds
        test_alpine_dependency_install_uses_bounds
        test_missing_timeout_fails_fast
        test_old_busybox_timeout_compatibility
    )

    for name in "${required[@]}"; do
        require_function "$name"
    done
    run_registered_test_suite \
        "${BASH_SOURCE[0]}" "package timeout tests" "${tests[@]}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
