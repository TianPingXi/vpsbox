#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/test_helper.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
# shellcheck source=../vpsbox.sh
source "$REPO_DIR/vpsbox.sh"
trap 'rm -rf -- "$TEST_TMP"' EXIT

version_case() {
    require_root_permission_semantics || return "$?"
    VPSBOX_STATE_DIR="$TEST_TMP/$1"
    mkdir -m 700 "$VPSBOX_STATE_DIR"
    version_result=1.14.4 version_failure=0
    : > "$VPSBOX_STATE_DIR/calls"
    fetch_singbox_latest_version() {
        printf 'fetch\n' >> "$VPSBOX_STATE_DIR/calls"
        [ "$version_failure" = 0 ] || return 1
        printf '%s\n' "$version_result"
    }
    singbox_version() { printf '%s\n' 1.13.14; }
}

test_versions_cache_and_manual_refresh() {
    (
        version_case cache
        check_singbox_latest_version
        assert_eq 1.14.4 "$SINGBOX_LATEST_VERSION"
        check_singbox_latest_version
        assert_eq 1 "$(wc -l < "$VPSBOX_STATE_DIR/calls")"
        version_result=1.14.5
        singbox_version_advice 1
        assert_eq WARN "$SINGBOX_NOTICE_LEVEL"
        [[ "$SINGBOX_NOTICE" == *尚未纳入* && "$SINGBOX_NOTICE" == *可通过菜单更新* ]] || fail '提示必须区分受管目标与上游版本'
        assert_eq 2 "$(wc -l < "$VPSBOX_STATE_DIR/calls")"
        assert_eq 1.14.4 "$SINGBOX_RELEASE_VERSION" '查询不得修改安装目标'
    )
}

test_versions_failure_and_stale_cache() {
    (
        version_case failure
        version_failure=1
        singbox_version_advice
        [[ "$SINGBOX_NOTICE" == *无法确认* ]] || fail '失败不得报告已经最新'
        check_singbox_latest_version
        assert_eq 1 "$(wc -l < "$VPSBOX_STATE_DIR/calls")" '失败应限频'
        singbox_version() { return 1; }
        singbox_version_advice
        [[ "$SINGBOX_NOTICE" == *无法确认* ]] || fail '已安装版本读取失败不得中断提示'
        version_failure=0
        check_singbox_latest_version 1
        version_failure=1
        singbox_version_advice 1
        assert_eq stale "$SINGBOX_LATEST_STATUS"
        [[ "$SINGBOX_NOTICE" == *旧缓存* && "$SINGBOX_NOTICE" == *检查时间* ]] || fail '旧缓存必须标注'
    )
}

test_versions_reject_invalid_data_and_links() {
    (
        version_case invalid
        version_result=1.15.0-alpha.1
        check_singbox_latest_version
        assert_eq unknown "$SINGBOX_LATEST_STATUS"
        version_result=1.14.4
        check_singbox_latest_version 1
        local cache="$VPSBOX_STATE_DIR/singbox-latest.json" data
        data="$(cat "$cache")"
        printf '%s\n%s\n' "$data" "$data" > "$cache"
        check_singbox_latest_version
        assert_eq current "$SINGBOX_LATEST_STATUS" '多条 JSON 缓存须丢弃并重新查询'
        assert_eq 3 "$(wc -l < "$VPSBOX_STATE_DIR/calls")"
        printf 'untouched\n' > "$TEST_TMP/target"
        rm "$VPSBOX_STATE_DIR/singbox-latest.json"
        ln -s "$TEST_TMP/target" "$VPSBOX_STATE_DIR/singbox-latest.json"
        version_result=1.14.4
        check_singbox_latest_version 1
        assert_eq untouched "$(cat "$TEST_TMP/target")"
        assert_eq 1.14.4 "$SINGBOX_LATEST_VERSION" '缓存写入失败仍可使用本次查询'
    )
}

test_versions_stale_expiry_and_future_clock() {
    (
        version_case clock
        check_singbox_latest_version
        local cache="$VPSBOX_STATE_DIR/singbox-latest.json" data
        data="$(jq '.attempted_at=1 | .checked_at=1' "$cache")"
        printf '%s\n' "$data" > "$cache"
        check_singbox_latest_version
        assert_eq 2 "$(wc -l < "$VPSBOX_STATE_DIR/calls")"
        data="$(jq '.attempted_at=4000000000 | .checked_at=4000000000' "$cache")"
        printf '%s\n' "$data" > "$cache"
        version_failure=1
        check_singbox_latest_version
        assert_eq unknown "$SINGBOX_LATEST_STATUS" '未来时间不得成为新鲜结果'
    )
}

test_versions_self_check_uses_shared_notice() {
    (
        version_case selfcheck
        node_core_artifacts_present() { return 1; }
        singbox_installed() { return 0; }
        protocol_node_status() { printf 'absent\n'; }
        node_uri_artifacts_present() { return 1; }
        self_check_node_stack > "$VPSBOX_STATE_DIR/output"
        assert_file_contains "$VPSBOX_STATE_DIR/output" 'sing-box 版本.*受管：v1.14.4.*上游稳定版：v1.14.4'
        assert_eq 1 "$(wc -l < "$VPSBOX_STATE_DIR/calls")"
    )
}

test_versions_upstream_parser_rejects_nonstable_metadata() {
    (
        # shellcheck disable=SC2034 # 只允许被测解析函数调用本例的 curl 替身。
        VPSBOX_TEST_MODE=0
        local response='{"draft":false,"prerelease":false,"tag_name":"v1.14.4"}'
        curl() {
            [[ "$*" == *'--connect-timeout 2 --max-time 5'* ]] || return 9
            printf '%s' "$response"
        }
        assert_eq 1.14.4 "$(fetch_singbox_latest_version)"
        for response in \
            '{"draft":true,"prerelease":false,"tag_name":"v1.14.4"}' \
            '{"draft":false,"prerelease":true,"tag_name":"v1.14.4"}' \
            '{"draft":false,"prerelease":false,"tag_name":"v1.15.0-beta.1"}' \
            '{"message":"rate limit exceeded"}' \
            '{"draft":false,"prerelease":false,"tag_name":"v1.14.4"} {}'; do
            if fetch_singbox_latest_version >/dev/null; then fail '不得接受非稳定版本或异常响应'; fi
        done
    )
}

main() {
    run_registered_test_suite "${BASH_SOURCE[0]}" 'sing-box version notices' \
        test_versions_cache_and_manual_refresh \
        test_versions_failure_and_stale_cache \
        test_versions_reject_invalid_data_and_links \
        test_versions_stale_expiry_and_future_clock \
        test_versions_self_check_uses_shared_notice \
        test_versions_upstream_parser_rejects_nonstable_metadata
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
