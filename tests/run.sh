#!/usr/bin/env bash

set -uo pipefail

# 日常回归：bash tests/run.sh
# 正式验收：VPSBOX_TEST_STRICT=1 bash tests/run.sh（任何环境能力 SKIP 都失败）
TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || exit 1
ONLY_SUITE=""
TOTAL_SKIPPED=0
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
RUN_RESULT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vpsbox-test-run.XXXXXX")" || {
    printf '无法创建测试汇总目录。\n' >&2
    exit 2
}
cleanup_run_results() {
    rm -rf -- "$RUN_RESULT_DIR"
}
trap cleanup_run_results EXIT

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
    printf '正式验收：VPSBOX_TEST_STRICT=1 bash %s [--only <suite.sh>]\n' "$0"
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
    skip_file="$RUN_RESULT_DIR/${suite}.skips"
    [ -z "$ONLY_SUITE" ] || [ "$suite" = "$ONLY_SUITE" ] || continue
    : > "$skip_file" || {
        printf '无法创建 SKIP 汇总文件：%s\n' "$skip_file" >&2
        exit 2
    }
    printf '=== %s ===\n' "$suite"
    if ! VPSBOX_TEST_SKIP_FILE="$skip_file" bash "$TEST_DIR/$suite"; then
        FAILED_SUITES+=("$suite")
    fi
    skipped="$(wc -l < "$skip_file")" || {
        printf '无法读取 SKIP 汇总文件：%s\n' "$skip_file" >&2
        exit 2
    }
    skipped="${skipped//[[:space:]]/}"
    [[ "$skipped" =~ ^[0-9]+$ ]] || {
        printf 'SKIP 汇总数量无效：%s\n' "$skipped" >&2
        exit 2
    }
    TOTAL_SKIPPED=$((TOTAL_SKIPPED + skipped))
done

if [ "${#FAILED_SUITES[@]}" -gt 0 ]; then
    printf '\n失败套件（%s）：%s\n' \
        "${#FAILED_SUITES[@]}" "${FAILED_SUITES[*]}" >&2
    [ "$TOTAL_SKIPPED" -eq 0 ] ||
        printf '本次另有 %s 项测试触发 SKIP。\n' "$TOTAL_SKIPPED" >&2
    exit 1
fi

if [ "$TOTAL_SKIPPED" -gt 0 ]; then
    printf '\n全部选定测试套件完成，但有 %s 项因环境能力跳过。\n' "$TOTAL_SKIPPED"
    printf '正式验收请运行：VPSBOX_TEST_STRICT=1 bash tests/run.sh\n'
else
    printf '\n全部选定测试套件通过（0 项跳过）。\n'
fi
