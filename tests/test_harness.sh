#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=tests/test_helper.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

test_cleanup() {
    rm -rf -- "$TEST_TMP"
}
trap test_cleanup EXIT

test_run_test_case_honors_errexit() {
    local marker="$TEST_TMP/reached-after-failure" status

    failing_case() {
        false
        : > "$marker"
    }

    set +e
    run_test_case failing_case
    status=$?
    set -e

    [ "$status" -ne 0 ] || fail "用例中途失败不得被后续成功命令改写为通过"
    [ ! -e "$marker" ] || fail "用例失败后不应继续执行"
}

test_run_test_case_preserves_caller_options() {
    local VPSBOX_TEST_STRICT=0 status

    skipped_case() {
        skip "测试跳过"
        fail "skip 后不得继续执行"
    }

    set +e
    run_test_case skipped_case
    status=$?
    case "$-" in
        *e*) fail "run_test_case 不得向调用方泄漏 errexit" ;;
    esac
    set -e

    assert_eq "$SKIP_STATUS" "$status" "skip 状态应完整返回给调用方"
    assert_eq "测试跳过" "$(test_skip_reason)" "skip 原因应跨子 shell 保留"
}

test_run_test_case_strict_mode_rejects_skip() {
    local VPSBOX_TEST_STRICT=1 status output="$TEST_TMP/strict-skip.out"

    skipped_case() {
        skip "严格模式夹具"
    }

    set +e
    run_test_case skipped_case >"$output" 2>&1
    status=$?
    set -e

    assert_eq 1 "$status" "严格模式必须把 SKIP 转为失败"
    assert_file_contains "$output" '严格模式不允许跳过：严格模式夹具'
}

test_require_command_records_explicit_skip() {
    local status

    set +e
    require_command vpsbox-command-that-must-not-exist
    status=$?
    set -e

    assert_eq "$SKIP_STATUS" "$status" "缺少能力时应返回统一 SKIP 状态"
    assert_eq "需要命令：vpsbox-command-that-must-not-exist" \
        "$(test_skip_reason)" "能力 SKIP 必须记录可读原因"
}

test_require_real_symlink_rejects_unknown_kind() {
    local status output="$TEST_TMP/unknown-symlink-kind.out"

    set +e
    require_real_symlink files >"$output" 2>&1
    status=$?
    set -e

    assert_eq 2 "$status" "能力参数错误不得被当成 SKIP"
    assert_file_contains "$output" '未知的符号链接能力类型：files'
}

test_forbidden_marker_survives_ignored_status() {
    local status

    forbid_init
    forbidden_call() { forbid "故意触发"; }
    forbidden_call 2>/dev/null || true

    set +e
    assert_no_forbidden >/dev/null 2>&1
    status=$?
    set -e
    [ "$status" -ne 0 ] || fail "被 || true 吞掉的禁止调用仍必须使断言失败"
}

test_forbidden_marker_survives_command_substitution() {
    local ignored status

    forbid_init
    forbidden_value() { forbid "命令替换触发"; }
    ignored="$(forbidden_value 2>/dev/null || true)"
    : "$ignored"

    set +e
    assert_no_forbidden >/dev/null 2>&1
    status=$?
    set -e
    [ "$status" -ne 0 ] || fail "命令替换中的禁止调用仍必须使断言失败"
}

test_registration_check_rejects_missing_extra_and_duplicates() {
    local fixture="$TEST_TMP/registration-fixture.sh"

    printf '%s\n' \
        'test_alpha() { :; }' \
        'test_beta() { :; }' \
        'test_cleanup() { :; }' > "$fixture"
    assert_all_tests_registered "$fixture" test_alpha test_beta
    if assert_all_tests_registered "$fixture" test_alpha >/dev/null 2>&1; then
        fail "已定义但未登记的测试必须被拒绝"
    fi
    if assert_all_tests_registered "$fixture" test_alpha test_beta test_gamma >/dev/null 2>&1; then
        fail "已登记但未定义的测试必须被拒绝"
    fi
    if assert_all_tests_registered "$fixture" test_alpha test_alpha test_beta >/dev/null 2>&1; then
        fail "重复登记的测试必须被拒绝"
    fi
}

test_suite_runners_keep_test_case_out_of_conditionals() {
    local path file count
    local -a suites=()

    for path in "$TEST_DIR"/test_*.sh; do
        file="${path##*/}"
        # helper 没有 runner；harness 自身故意直接执行用例，以验证 runner。
        case "$file" in
            test_helper.sh|test_harness.sh) continue ;;
        esac
        suites+=("$file")
    done
    [ "${#suites[@]}" -gt 0 ] || fail "未发现任何待检查的测试套件"

    for file in "${suites[@]}"; do
        count="$(awk '
            /^[[:space:]]*set \+e[[:space:]]*$/ {
                if ((getline first) > 0 &&
                    first ~ /^[[:space:]]*run_test_case "\$test"[[:space:]]*$/ &&
                    (getline second) > 0 &&
                    second ~ /^[[:space:]]*status=\$\?[[:space:]]*$/ &&
                    (getline third) > 0 &&
                    third ~ /^[[:space:]]*set -e[[:space:]]*$/) {
                    found++
                }
            }
            END { print found + 0 }
        ' "$TEST_DIR/$file")"
        assert_eq 1 "$count" "$file 必须以独立三段式调用 run_test_case"
        if grep -Eq 'run_test_case .*(&&|\|\|)' "$TEST_DIR/$file"; then
            fail "$file 不得把 run_test_case 放进 && 或 ||"
        fi
    done
}

main() {
    local test status passed=0
    local -a tests=(
        test_run_test_case_honors_errexit
        test_run_test_case_preserves_caller_options
        test_run_test_case_strict_mode_rejects_skip
        test_require_command_records_explicit_skip
        test_require_real_symlink_rejects_unknown_kind
        test_forbidden_marker_survives_ignored_status
        test_forbidden_marker_survives_command_substitution
        test_registration_check_rejects_missing_extra_and_duplicates
        test_suite_runners_keep_test_case_out_of_conditionals
    )

    assert_all_tests_registered "${BASH_SOURCE[0]}" "${tests[@]}" || return 1
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
    printf '%s test harness tests passed.\n' "$passed"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
