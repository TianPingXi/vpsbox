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
