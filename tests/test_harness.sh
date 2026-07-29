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

test_run_test_case_honors_errexit_in_command_substitution() {
    local marker="$TEST_TMP/reached-inside-command-substitution" status

    substitution_case() {
        local value
        value="$(false; : > "$marker"; printf ok)"
        [ "$value" = ok ]
    }

    shopt -u inherit_errexit
    set +e
    run_test_case substitution_case
    status=$?
    set -e

    [ "$status" -ne 0 ] ||
        fail "命令替换中的前置失败不得被后续成功命令改写为通过"
    [ ! -e "$marker" ] || fail "命令替换失败后不应继续执行"
    if shopt -q inherit_errexit; then
        fail "run_test_case 不得向调用方泄漏 inherit_errexit"
    fi
}

test_harness_runner_enables_inherit_errexit() {
    shopt -q inherit_errexit ||
        fail "harness 自身的测试子 shell 必须启用 inherit_errexit"
}

test_run_test_case_preserves_caller_options() {
    local VPSBOX_TEST_STRICT=0 VPSBOX_TEST_SKIP_FILE="" status

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
    local VPSBOX_TEST_STRICT=1 VPSBOX_TEST_SKIP_FILE=""
    local status output="$TEST_TMP/strict-skip.out"

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

test_run_test_case_rejects_unexplained_skip() {
    local status output="$TEST_TMP/unexplained-skip.out"

    unexplained_skip_case() {
        return "$SKIP_STATUS"
    }

    set +e
    run_test_case unexplained_skip_case >"$output" 2>&1
    status=$?
    set -e

    assert_eq 1 "$status" "裸返回 77 不得被当成合法 SKIP"
    assert_file_contains "$output" '测试返回 SKIP 状态但未记录原因：unexplained_skip_case'
}

test_run_test_case_records_explicit_skip() {
    local VPSBOX_TEST_STRICT=0 status
    local VPSBOX_TEST_SKIP_FILE="$TEST_TMP/recorded-skips"

    : > "$VPSBOX_TEST_SKIP_FILE"
    recorded_skip_case() {
        skip "汇总夹具"
    }

    set +e
    run_test_case recorded_skip_case
    status=$?
    set -e

    assert_eq "$SKIP_STATUS" "$status" "合法 SKIP 必须保留统一退出状态"
    assert_file_contains "$VPSBOX_TEST_SKIP_FILE" $'^recorded_skip_case\t汇总夹具$' \
        "合法 SKIP 必须写入运行器汇总文件"
}

test_negative_file_assertions_require_regular_files() {
    local missing="$TEST_TMP/missing-output" regular="$TEST_TMP/regular-output"
    local target="$TEST_TMP/assertion-target" link="$TEST_TMP/assertion-link"

    if assert_empty_file "$missing" >/dev/null 2>&1; then
        fail "assert_empty_file 不得把缺失文件当成空文件"
    fi
    if assert_file_not_contains "$missing" forbidden >/dev/null 2>&1; then
        fail "assert_file_not_contains 不得把缺失文件当成匹配失败"
    fi
    assert_missing_or_empty_file "$missing"
    assert_missing_or_file_not_contains "$missing" forbidden

    : > "$regular"
    assert_empty_file "$regular"
    printf '%s\n' allowed > "$regular"
    assert_file_not_contains "$regular" forbidden
    assert_missing_or_file_not_contains "$regular" forbidden

    require_real_symlink file || return "$?"
    : > "$target"
    ln -s "$target" "$link" || fail "能力探测通过后仍无法创建断言用符号链接"
    if assert_empty_file "$link" >/dev/null 2>&1; then
        fail "assert_empty_file 不得接受符号链接"
    fi
    if assert_file_not_contains "$link" forbidden >/dev/null 2>&1; then
        fail "assert_file_not_contains 不得接受符号链接"
    fi
    if assert_missing_or_empty_file "$link" >/dev/null 2>&1; then
        fail "可缺失断言不得把符号链接当成缺失路径"
    fi

    grep() { return 2; }
    if assert_file_not_contains "$regular" forbidden >/dev/null 2>&1; then
        fail "assert_file_not_contains 不得把 grep 读取错误当成没有匹配"
    fi
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
        '  test_alpha() { :; }' \
        'function test_beta { :; }' \
        'function test_gamma() { :; }' \
        'test_delta()' \
        '{' \
        '    :' \
        '}' \
        'test_cleanup() { :; }' > "$fixture"
    assert_all_tests_registered "$fixture" test_alpha test_beta test_gamma test_delta
    if assert_all_tests_registered "$fixture" test_alpha test_beta test_gamma >/dev/null 2>&1; then
        fail "已定义但未登记的测试必须被拒绝"
    fi
    if assert_all_tests_registered \
        "$fixture" test_alpha test_beta test_gamma test_delta test_extra >/dev/null 2>&1; then
        fail "已登记但未定义的测试必须被拒绝"
    fi
    if assert_all_tests_registered \
        "$fixture" test_alpha test_alpha test_beta test_gamma test_delta >/dev/null 2>&1; then
        fail "重复登记的测试必须被拒绝"
    fi
    printf '%s\n' 'test_alpha() { :; }' >> "$fixture"
    if assert_all_tests_registered \
        "$fixture" test_alpha test_beta test_gamma test_delta >/dev/null 2>&1; then
        fail "使用不同缩进重复定义的测试必须被拒绝"
    fi
}

test_shared_suite_runner_preserves_failure_semantics() {
    local marker="$TEST_TMP/suite-reached-after-failure"
    local after="$TEST_TMP/suite-ran-after-failure"
    local output="$TEST_TMP/suite-failure.out" status

    fixture_case_failure() {
        false
        : > "$marker"
    }
    fixture_case_after_failure() {
        : > "$after"
    }

    set +e
    run_test_suite \
        "fixture tests" fixture_case_failure fixture_case_after_failure \
        >"$output" 2>&1
    status=$?
    case "$-" in
        *e*) fail "统一 runner 不得向禁用 errexit 的调用方泄漏选项" ;;
    esac
    set -e

    assert_eq 1 "$status" "用例失败必须使统一 runner 失败"
    [ ! -e "$marker" ] || fail "失败用例不得继续执行后续命令"
    [ ! -e "$after" ] || fail "统一 runner 必须在首个失败处停止"
    assert_file_contains "$output" '^not ok - fixture_case_failure$'
}

test_shared_suite_runner_preserves_skip_and_strict_mode() {
    local VPSBOX_TEST_STRICT=0 VPSBOX_TEST_SKIP_FILE=""
    local output="$TEST_TMP/suite-skip.out" strict_output="$TEST_TMP/suite-strict.out"
    local after="$TEST_TMP/suite-ran-after-strict-skip" status

    fixture_case_pass() { :; }
    fixture_case_skip() { skip "统一 runner 跳过夹具"; }
    fixture_case_after_skip() { : > "$after"; }

    set +e
    run_test_suite "fixture tests" fixture_case_pass fixture_case_skip >"$output" 2>&1
    status=$?
    set -e
    assert_eq 0 "$status" "非严格模式必须接受有原因的 SKIP"
    assert_file_contains "$output" '^ok - fixture_case_pass$'
    assert_file_contains "$output" '^ok - fixture_case_skip # SKIP 统一 runner 跳过夹具$'
    assert_file_contains "$output" '^1 fixture tests passed, 1 skipped, 2 registered\.$'

    VPSBOX_TEST_STRICT=1
    set +e
    run_test_suite \
        "strict fixture tests" fixture_case_skip fixture_case_after_skip \
        >"$strict_output" 2>&1
    status=$?
    set -e
    assert_eq 1 "$status" "严格模式必须把统一 runner 中的 SKIP 转为失败"
    [ ! -e "$after" ] || fail "严格模式遇到 SKIP 后不得继续运行其他用例"
    assert_file_contains "$strict_output" '严格模式不允许跳过：统一 runner 跳过夹具'
}

test_shared_suite_runner_rejects_conditional_context() {
    local marker="$TEST_TMP/suite-conditional-marker"
    local output="$TEST_TMP/suite-conditional.out" status

    fixture_conditional_case() {
        false
        : > "$marker"
    }

    set +e
    if run_test_suite "conditional fixture tests" fixture_conditional_case \
        >"$output" 2>&1; then
        status=0
    else
        status=$?
    fi
    set -e

    assert_eq 2 "$status" "条件上下文中的统一 runner 必须明确拒绝执行"
    [ ! -e "$marker" ] || fail "条件上下文探测失败后不得进入测试用例"
    assert_file_contains "$output" '不能在 if、!、&& 或 [|][|] 条件上下文中调用'
}

test_business_suites_use_registered_runner() {
    local path file count

    for path in "$TEST_DIR"/test_*.sh; do
        file="${path##*/}"
        case "$file" in
            test_helper.sh|test_harness.sh) continue ;;
        esac
        count="$(grep -Ec \
            '^[[:space:]]*run_registered_test_suite([[:space:]]|$)' "$path")"
        assert_eq 1 "$count" \
            "$file 必须且只能通过统一注册 runner 执行测试数组"
    done
}

test_capability_preconditions_do_not_mask_failure_status() {
    local path file violations
    local -a suites=()

    for path in "$TEST_DIR"/test_*.sh; do
        file="${path##*/}"
        case "$file" in
            test_helper.sh|test_harness.sh) continue ;;
        esac
        suites+=("$path")
    done
    [ "${#suites[@]}" -gt 0 ] || fail "未发现任何待检查的测试套件"

    violations="$(awk '
        /^[[:space:]]*require_(command|linux_proc|real_symlink)[[:space:]]/ &&
            $0 ~ /\|\|/ &&
            $0 !~ /\|\|[[:space:]]*return[[:space:]]+"\$\?"[[:space:]]*$/ {
            print FILENAME ":" FNR ":" $0
        }
    ' "${suites[@]}")"
    [ -z "$violations" ] ||
        fail "能力前置条件不得把真实失败改写成 SKIP 或成功：$violations"
}

main() {
    local test status passed=0 skipped=0
    local -a tests=(
        test_run_test_case_honors_errexit
        test_run_test_case_honors_errexit_in_command_substitution
        test_harness_runner_enables_inherit_errexit
        test_run_test_case_preserves_caller_options
        test_run_test_case_strict_mode_rejects_skip
        test_run_test_case_rejects_unexplained_skip
        test_run_test_case_records_explicit_skip
        test_negative_file_assertions_require_regular_files
        test_require_command_records_explicit_skip
        test_require_real_symlink_rejects_unknown_kind
        test_forbidden_marker_survives_ignored_status
        test_forbidden_marker_survives_command_substitution
        test_registration_check_rejects_missing_extra_and_duplicates
        test_shared_suite_runner_preserves_failure_semantics
        test_shared_suite_runner_preserves_skip_and_strict_mode
        test_shared_suite_runner_rejects_conditional_context
        test_business_suites_use_registered_runner
        test_capability_preconditions_do_not_mask_failure_status
    )

    assert_all_tests_registered "${BASH_SOURCE[0]}" "${tests[@]}" || return 1
    for test in "${tests[@]}"; do
        : > "$SKIP_REASON_FILE" || return 1
        set +e
        (
            set -e
            shopt -u inherit_errexit
            shopt -s inherit_errexit
            "$test"
        )
        status=$?
        set -e
        case "$status" in
            0)
                printf 'ok - %s\n' "$test"
                passed=$((passed + 1))
                ;;
            "$SKIP_STATUS")
                [ -s "$SKIP_REASON_FILE" ] || {
                    printf 'not ok - %s（SKIP 未记录原因）\n' "$test" >&2
                    return 1
                }
                if [ -n "${VPSBOX_TEST_SKIP_FILE:-}" ]; then
                    [ -f "$VPSBOX_TEST_SKIP_FILE" ] &&
                        [ ! -L "$VPSBOX_TEST_SKIP_FILE" ] || return 1
                    printf '%s\t%s\n' "$test" "$(test_skip_reason)" \
                        >> "$VPSBOX_TEST_SKIP_FILE" || return 1
                fi
                if [ "${VPSBOX_TEST_STRICT:-0}" = "1" ]; then
                    printf 'not ok - %s（严格模式不允许跳过：%s）\n' \
                        "$test" "$(test_skip_reason)" >&2
                    return 1
                fi
                printf 'ok - %s # SKIP %s\n' "$test" "$(test_skip_reason)"
                skipped=$((skipped + 1))
                ;;
            *)
                printf 'not ok - %s\n' "$test" >&2
                return 1
                ;;
        esac
    done
    printf '%s test harness tests passed, %s skipped, %s registered.\n' \
        "$passed" "$skipped" "${#tests[@]}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
