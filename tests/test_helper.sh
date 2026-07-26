#!/usr/bin/env bash

set -euo pipefail

# 所有测试默认禁止调用真实 systemd/OpenRC 服务管理命令；需要服务行为时必须显式 mock。
export VPSBOX_TEST_MODE=1

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# These variables are consumed by test files that source this helper.
# shellcheck disable=SC2034
REPO_DIR="$(cd -- "$TEST_DIR/.." && pwd)"
# shellcheck disable=SC2034
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/vpsbox-test.XXXXXX")"
SKIP_STATUS=77
SKIP_REASON_FILE="$TEST_TMP/skip-reason"
FORBIDDEN_LOG=""

fail() {
    printf 'not ok - %s\n' "$*" >&2
    return 1
}

assert_eq() {
    local expected="$1" actual="$2" message="${3:-值不相等}"
    if [ "$expected" != "$actual" ]; then
        fail "$message（期望：$expected，实际：$actual）"
    fi
}

assert_empty_file() {
    local file="$1" message="${2:-文件应为空}"
    if [ -s "$file" ]; then
        fail "$message：$(tr '\n' ' ' < "$file")"
    fi
}

assert_file_contains() {
    local file="$1" pattern="$2" message="${3:-文件缺少预期内容}"
    if ! grep -Eq -- "$pattern" "$file"; then
        fail "$message（模式：$pattern）"
    fi
}

assert_file_not_contains() {
    local file="$1" pattern="$2" message="${3:-文件包含非预期内容}"
    if grep -Eq -- "$pattern" "$file"; then
        fail "$message（模式：$pattern）"
    fi
}

require_function() {
    local name="$1"
    declare -F "$name" >/dev/null 2>&1 || fail "缺少待测函数：$name"
}

forbid_init() {
    FORBIDDEN_LOG="$(mktemp "$TEST_TMP/forbidden.XXXXXX")" ||
        fail "无法创建禁止调用标记文件"
}

forbid() {
    printf 'forbidden:%s\n' "${1:?forbid 需要说明被禁止的行为}" \
        >> "${FORBIDDEN_LOG:?forbid 前必须先调用 forbid_init}"
    return 1
}

assert_no_forbidden() {
    [ -n "${FORBIDDEN_LOG:-}" ] || {
        fail "本用例未调用 forbid_init"
        return 1
    }
    [ -f "$FORBIDDEN_LOG" ] && [ ! -L "$FORBIDDEN_LOG" ] || {
        fail "禁止调用标记文件缺失或类型不安全"
        return 1
    }
    assert_empty_file "$FORBIDDEN_LOG" "${1:-发生了被禁止的调用}"
}

skip() {
    printf '%s\n' "${1:-未说明原因}" > "$SKIP_REASON_FILE"
    return "$SKIP_STATUS"
}

test_skip_reason() {
    if [ -s "$SKIP_REASON_FILE" ]; then
        tr '\n' ' ' < "$SKIP_REASON_FILE" | sed 's/[[:space:]]*$//'
    else
        printf '%s\n' "未说明原因"
    fi
}

run_test_case() {
    local name="$1" status=0
    # Shell 选项默认是全局状态；限制在函数作用域，避免 set +/-e 泄漏给调用方。
    local -

    : > "$SKIP_REASON_FILE" || return 1
    # 子 shell 必须独立成句。放进 if/&&/|| 会让 Bash 忽略内部的 errexit。
    set +e
    (
        set -e
        "$name"
    )
    status=$?
    return "$status"
}

assert_all_tests_registered() {
    local file="$1"
    local definitions registered
    local duplicate_definitions duplicate_registrations missing extra
    shift

    [ -f "$file" ] || {
        fail "测试源文件不存在：$file"
        return 1
    }
    definitions="$(mktemp "$TEST_TMP/defined-tests.XXXXXX")" || return 1
    registered="$(mktemp "$TEST_TMP/registered-tests.XXXXXX")" || return 1
    if ! sed -nE 's/^(test_[A-Za-z0-9_]+)\(\).*/\1/p' "$file" |
        grep -vx 'test_cleanup' | sort > "$definitions"; then
        fail "无法读取测试定义：$file"
        return 1
    fi
    if ! printf '%s\n' "$@" | sort > "$registered"; then
        fail "无法整理测试登记：$file"
        return 1
    fi

    duplicate_definitions="$(uniq -d "$definitions" | paste -sd, -)" || return 1
    duplicate_registrations="$(uniq -d "$registered" | paste -sd, -)" || return 1
    missing="$(comm -23 "$definitions" "$registered" | paste -sd, -)" || return 1
    extra="$(comm -13 "$definitions" "$registered" | paste -sd, -)" || return 1

    [ -z "$duplicate_definitions" ] || {
        fail "存在重复定义的测试：$duplicate_definitions"
        return 1
    }
    [ -z "$duplicate_registrations" ] || {
        fail "存在重复登记的测试：$duplicate_registrations"
        return 1
    }
    [ -z "$missing" ] || {
        fail "存在已定义但未登记的测试：$missing"
        return 1
    }
    [ -z "$extra" ] || {
        fail "存在已登记但未定义的测试：$extra"
        return 1
    }
}
