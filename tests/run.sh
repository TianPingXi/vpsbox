#!/usr/bin/env bash

set -uo pipefail

# 发布验收可设置 VPSBOX_TEST_STRICT=1，使任何环境能力 SKIP 都导致失败。
TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || exit 1
ONLY_SUITE=""
declare -a FAILED_SUITES=()
declare -a DISCOVERED_SUITES=()
declare -a SUITES=(
    test_harness.sh
    test_updates.sh
    test_fail2ban.sh
    test_package_timeouts.sh
    test_ipv4_priority.sh
    test_firewall_watchdog.sh
    test_core_regressions.sh
    test_dual_nodes.sh
    test_system_regressions.sh
    test_firewall_regressions.sh
)
for suite_path in "$TEST_DIR"/test_*.sh; do
    suite="${suite_path##*/}"
    [ "$suite" = "test_helper.sh" ] || DISCOVERED_SUITES+=("$suite")
done
discovered="$(printf '%s\n' "${DISCOVERED_SUITES[@]}" | sort)"
registered="$(printf '%s\n' "${SUITES[@]}" | sort)"
if [ "$discovered" != "$registered" ]; then
    printf '测试套件登记与 tests 目录不一致。\n' >&2
    printf '目录：%s\n登记：%s\n' \
        "$(printf '%s ' "${DISCOVERED_SUITES[@]}")" \
        "$(printf '%s ' "${SUITES[@]}")" >&2
    exit 2
fi

usage() {
    printf '用法：%s [--only <suite.sh>]\n' "${0##*/}"
}

if [ "$#" -gt 0 ]; then
    if [ "$#" -ne 2 ] || [ "$1" != "--only" ] || [ -z "$2" ]; then
        usage >&2
        exit 2
    fi
    ONLY_SUITE="$2"
    if ! printf '%s\n' "${SUITES[@]}" | grep -Fqx -- "$ONLY_SUITE"; then
        printf '未知测试套件：%s\n' "$ONLY_SUITE" >&2
        usage >&2
        exit 2
    fi
fi

for suite in "${SUITES[@]}"; do
    [ -z "$ONLY_SUITE" ] || [ "$suite" = "$ONLY_SUITE" ] || continue
    printf '=== %s ===\n' "$suite"
    if ! bash "$TEST_DIR/$suite"; then
        FAILED_SUITES+=("$suite")
    fi
done

if [ "${#FAILED_SUITES[@]}" -gt 0 ]; then
    printf '\n失败套件（%s）：%s\n' \
        "${#FAILED_SUITES[@]}" "${FAILED_SUITES[*]}" >&2
    exit 1
fi

printf '\n全部选定测试套件通过。\n'
