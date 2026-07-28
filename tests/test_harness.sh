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

suite_runner_shape_valid() {
    local file="$1"

    awk '
        {
            lines[NR] = $0
            text = $0
            sub(/^[[:space:]]*/, "", text)
            if (text ~ /^#/) next

            if ($0 ~ /^[[:space:]]*main\(\)[[:space:]]*\{[[:space:]]*$/) {
                main_count++
                if (!main_line) {
                    main_line = NR
                    main_depth = 1
                    in_main = 1
                }
            } else if (in_main) {
                open_count = gsub(/(^|[[:space:];|&])\{([[:space:];|&]|$)/, "&", text)
                close_count = gsub(/(^|[[:space:];|&])\}([[:space:];|&]|$)/, "&", text)
                main_depth += open_count - close_count
                if (main_depth == 0) {
                    main_end = NR
                    in_main = 0
                }
            }
            if ($0 ~ /^[[:space:]]*if \[\[ "\$\{BASH_SOURCE\[0\]\}" == "\$0" \]\]; then[[:space:]]*$/) {
                guard_count++
                guard_line = NR
            }
            if ($0 ~ /^[[:space:]]*for[[:space:]]+test[[:space:]]+in[[:space:]]+"\$\{tests\[@\]\}";[[:space:]]+do[[:space:]]*$/) {
                runner_loops++
                runner_loop_line = NR
                in_runner_loop = 1
            }
            if ($0 ~ /(^|[[:space:];|&!()])run_test_case([[:space:]]|$)/) {
                calls++
                call_line = NR
                exact_call = ($0 ~ /^[[:space:]]*run_test_case[[:space:]]+"\$test"[[:space:]]*$/)
                call_in_runner_loop = in_runner_loop
            }
            if (in_runner_loop && text ~ /^done[[:space:]]*$/) {
                in_runner_loop = 0
            }
        }
        END {
            bad = 0
            if (calls != 1) {
                printf "run_test_case 调用次数必须为 1，实际为 %d\n", calls > "/dev/stderr"
                bad = 1
            }
            if (runner_loops != 1) {
                printf "标准测试循环数量必须为 1，实际为 %d\n", runner_loops > "/dev/stderr"
                bad = 1
            }
            if (main_count != 1 || !main_end) {
                printf "main 定义必须唯一且可确定结束位置，实际为 %d\n", main_count > "/dev/stderr"
                bad = 1
            }
            if (guard_count != 1) {
                printf "脚本执行入口守卫数量必须为 1，实际为 %d\n", guard_count > "/dev/stderr"
                bad = 1
            }
            if (calls == 1) {
                if (!exact_call) {
                    print "run_test_case 必须作为独立命令执行" > "/dev/stderr"
                    bad = 1
                }
                if (!call_in_runner_loop) {
                    print "run_test_case 不在标准 tests 数组循环内" > "/dev/stderr"
                    bad = 1
                }
                if (!main_line || !main_end || !guard_line ||
                    runner_loop_line <= main_line || runner_loop_line >= main_end ||
                    call_line <= runner_loop_line || call_line >= main_end ||
                    guard_line <= main_end) {
                    print "run_test_case 不在 main 入口范围内" > "/dev/stderr"
                    bad = 1
                }
                if (lines[call_line - 1] !~ /^[[:space:]]*set \+e[[:space:]]*$/ ||
                    lines[call_line + 1] !~ /^[[:space:]]*status=\$\?[[:space:]]*$/ ||
                    lines[call_line + 2] !~ /^[[:space:]]*set -e[[:space:]]*$/) {
                    print "run_test_case 必须使用 set +e / 调用 / $? / set -e 四行序列" > "/dev/stderr"
                    bad = 1
                }
                if (lines[call_line + 3] !~ /^[[:space:]]*case[[:space:]]+"\$status"[[:space:]]+in[[:space:]]*$/) {
                    print "run_test_case 状态必须立即进入统一 case 分支" > "/dev/stderr"
                    bad = 1
                }
            }
            exit bad
        }
    ' "$file"
}

write_runner_fixture() {
    local file="$1" call="$2" side_fixture="${3:-0}" override_status="${4:-0}"

    {
        printf '%s\n' '#!/usr/bin/env bash'
        if [ "$side_fixture" -eq 1 ]; then
            printf '%s\n' \
                'unused_fixture() {' \
                '    set +e' \
                '    run_test_case "$test"' \
                '    status=$?' \
                '    set -e' \
                '}'
        fi
        printf '%s\n' \
            'main() {' \
            '    local test status' \
            '    local -a tests=(test_alpha)' \
            '    for test in "${tests[@]}"; do' \
            '        set +e'
        printf '        %s\n' "$call"
        printf '%s\n' \
            '        status=$?' \
            '        set -e'
        if [ "$override_status" -eq 1 ]; then
            printf '%s\n' '        status=0'
        fi
        printf '%s\n' \
            '        case "$status" in' \
            '            0) : ;;' \
            '            "$SKIP_STATUS") : ;;' \
            '            *) return 1 ;;' \
            '        esac' \
            '    done' \
            '}' \
            'if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then' \
            '    main "$@"' \
            'fi'
    } > "$file"
}

write_out_of_main_runner_fixture() {
    local file="$1"

    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'main() {' \
        '    :' \
        '}' \
        'run_tests() {' \
        '    local test status' \
        '    local -a tests=(test_alpha)' \
        '    for test in "${tests[@]}"; do' \
        '        set +e' \
        '        run_test_case "$test"' \
        '        status=$?' \
        '        set -e' \
        '        case "$status" in' \
        '            0) : ;;' \
        '            "$SKIP_STATUS") : ;;' \
        '            *) return 1 ;;' \
        '        esac' \
        '    done' \
        '}' \
        'if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then' \
        '    main "$@"' \
        'fi' > "$file"
}

test_suite_runners_keep_test_case_out_of_conditionals() {
    local path file
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
        suite_runner_shape_valid "$TEST_DIR/$file" ||
            fail "$file 的 run_test_case 调用不符合独立四行序列"
    done
}

test_suite_runner_linter_rejects_conditional_pipeline_and_side_fixture() {
    local fixture="$TEST_TMP/runner-shape.sh" call
    local -a invalid_calls=(
        'if run_test_case "$test"; then :; fi'
        '! run_test_case "$test"'
        'run_test_case "$test" | tee /dev/null'
        'run_test_case "$test" && :'
        'run_test_case "$test" || :'
    )

    write_runner_fixture "$fixture" 'run_test_case "$test"'
    suite_runner_shape_valid "$fixture" || fail "合法的独立 runner 序列被拒绝"

    for call in "${invalid_calls[@]}"; do
        write_runner_fixture "$fixture" "$call"
        if suite_runner_shape_valid "$fixture" >/dev/null 2>&1; then
            fail "runner linter 未拒绝条件或管道上下文：$call"
        fi
    done

    write_runner_fixture "$fixture" 'if run_test_case "$test"; then :; fi' 1
    if suite_runner_shape_valid "$fixture" >/dev/null 2>&1; then
        fail "旁置的合法夹具不得掩盖 main 中的错误 runner"
    fi

    write_out_of_main_runner_fixture "$fixture"
    if suite_runner_shape_valid "$fixture" >/dev/null 2>&1; then
        fail "main 外部的标准 runner 不得通过作用域检查"
    fi

    write_runner_fixture "$fixture" 'run_test_case "$test"' 0 1
    if suite_runner_shape_valid "$fixture" >/dev/null 2>&1; then
        fail "捕获后覆盖 run_test_case 状态不得通过 runner 检查"
    fi
}

test_capability_preconditions_propagate_exact_status() {
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
            $0 !~ /\|\|[[:space:]]*return[[:space:]]+"\$\?"[[:space:]]*$/ {
            print FILENAME ":" FNR ":" $0
        }
    ' "${suites[@]}")"
    [ -z "$violations" ] ||
        fail "能力前置条件必须原样传播实际状态：$violations"
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
        test_suite_runners_keep_test_case_out_of_conditionals
        test_suite_runner_linter_rejects_conditional_pipeline_and_side_fixture
        test_capability_preconditions_propagate_exact_status
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
