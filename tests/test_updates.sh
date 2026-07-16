#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=tests/test_helper.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

# shellcheck source=../vpsbox.sh
source "$REPO_DIR/vpsbox.sh"

MOCK_REMOTE_SCRIPT=""
MOCK_EVENT_LOG="$TEST_TMP/update-events.log"

test_cleanup() {
    if [ "${KEEP_TEST_TMP:-0}" = "1" ]; then
        printf '保留测试临时目录：%s\n' "$TEST_TMP" >&2
    else
        rm -rf -- "$TEST_TMP"
    fi
}
trap test_cleanup EXIT

write_fixture() {
    local path="$1" version="$2" marker="$3"
    printf '#!/usr/bin/env bash\nVPSBOX_VERSION="%s"\nprintf %s\\n\n' \
        "$version" "'$marker'" > "$path"
    chmod 755 "$path"
}

curl() {
    local output=""

    while [ "$#" -gt 0 ]; do
        if [ "$1" = "-o" ]; then
            output="${2:-}"
            shift 2
        else
            shift
        fi
    done
    [ -n "$output" ] || return 2
    cp "$MOCK_REMOTE_SCRIPT" "$output"
}

install_command_alias() {
    printf '%s\n' alias >> "$MOCK_EVENT_LOG"
}

cleanup_vpsbox_lock() {
    printf '%s\n' cleanup-lock >> "$MOCK_EVENT_LOG"
}

reexec_updated_vpsbox() {
    printf '%s\n' reexec >> "$MOCK_EVENT_LOG"
}

acquire_lock() {
    printf '%s\n' acquire-lock >> "$MOCK_EVENT_LOG"
}

reset_update_case() {
    local name="$1"

    CASE_DIR="$TEST_TMP/$name"
    mkdir -p "$CASE_DIR"
    CMD_PATH="$CASE_DIR/vpsbox"
    MOCK_REMOTE_SCRIPT="$CASE_DIR/remote.sh"
    MOCK_EVENT_LOG="$CASE_DIR/events.log"
    : > "$MOCK_EVENT_LOG"
    REMOTE_VERSION="v9.9.9"
    UPDATE_AVAILABLE=1
}

test_version_relation() {
    assert_eq newer "$(version_relation v1.0.21 v1.0.20)"
    assert_eq same "$(version_relation 1.0.20 v1.0.20)"
    assert_eq older "$(version_relation v1.0.19 1.0.20)"
    assert_eq newer "$(version_relation v1.1.0 v1.0.99)"
    if version_relation v1.0 v1.0.20 >/dev/null 2>&1; then
        fail "畸形版本不应通过比较"
    fi
}

test_vpsbox_same_is_noop() {
    local output="$TEST_TMP/same.out"
    reset_update_case same
    write_fixture "$CMD_PATH" v1.0.20 installed
    printf 'keep-backup\n' > "${CMD_PATH}.previous"
    write_fixture "$MOCK_REMOTE_SCRIPT" v1.0.20 remote

    update_vpsbox > "$output" 2>&1 || fail "相同版本应正常返回"

    assert_file_contains "$output" '当前已是最新版，无需更新'
    assert_file_contains "$CMD_PATH" 'installed'
    assert_file_contains "${CMD_PATH}.previous" '^keep-backup$'
    assert_empty_file "$MOCK_EVENT_LOG" "相同版本不得触发替换后的副作用"
    assert_eq "0" "$UPDATE_AVAILABLE"
    assert_eq "" "$REMOTE_VERSION"
}

test_vpsbox_older_is_noop() {
    local output="$TEST_TMP/older.out"
    reset_update_case older
    write_fixture "$CMD_PATH" v1.0.20 installed
    printf 'keep-backup\n' > "${CMD_PATH}.previous"
    write_fixture "$MOCK_REMOTE_SCRIPT" v1.0.19 remote

    update_vpsbox > "$output" 2>&1 || fail "远端旧版本应安全返回"

    assert_file_contains "$output" '低于当前版本.*已拒绝降级'
    assert_file_contains "$CMD_PATH" 'installed'
    assert_file_contains "${CMD_PATH}.previous" '^keep-backup$'
    assert_empty_file "$MOCK_EVENT_LOG" "远端旧版本不得触发替换后的副作用"
}

test_vpsbox_newer_updates_once() {
    reset_update_case newer
    write_fixture "$CMD_PATH" v1.0.20 installed
    write_fixture "$MOCK_REMOTE_SCRIPT" v1.0.21 remote

    update_vpsbox > "$TEST_TMP/newer.out" 2>&1 || fail "远端新版本应更新成功"

    assert_file_contains "$CMD_PATH" 'VPSBOX_VERSION="v1\.0\.21"'
    assert_file_contains "$CMD_PATH" 'remote'
    assert_file_contains "${CMD_PATH}.previous" 'installed'
    assert_file_contains "$MOCK_EVENT_LOG" '^alias$'
    assert_file_contains "$MOCK_EVENT_LOG" '^cleanup-lock$'
    assert_file_contains "$MOCK_EVENT_LOG" '^reexec$'
}

test_vpsbox_invalid_download_preserves_current() {
    local output="$TEST_TMP/invalid.out"
    reset_update_case invalid
    write_fixture "$CMD_PATH" v1.0.20 installed
    printf 'keep-backup\n' > "${CMD_PATH}.previous"
    printf '#!/usr/bin/env bash\nif then\n' > "$MOCK_REMOTE_SCRIPT"

    if update_vpsbox > "$output" 2>&1; then
        fail "语法损坏的远程脚本必须报失败"
    fi

    assert_file_contains "$output" '未通过语法检查'
    assert_file_contains "$CMD_PATH" 'installed'
    assert_file_contains "${CMD_PATH}.previous" '^keep-backup$'
    assert_empty_file "$MOCK_EVENT_LOG" "下载校验失败不得触发替换后的副作用"
}

MOCK_SINGBOX_VERSION=""
MOCK_SINGBOX_EVENT_LOG=""

singbox_installed() { return 0; }
singbox_version() { printf '%s\n' "$MOCK_SINGBOX_VERSION"; }
service_is_running() { return 1; }
service_is_enabled() { return 1; }
node_exists() { return 1; }
install_deps() { printf '%s\n' deps >> "$MOCK_SINGBOX_EVENT_LOG"; }
run_singbox_installer() {
    printf 'installer:%s\n' "${1:-$SINGBOX_RELEASE_VERSION}" >> "$MOCK_SINGBOX_EVENT_LOG"
    MOCK_SINGBOX_VERSION="${1:-$SINGBOX_RELEASE_VERSION}"
}

reset_singbox_case() {
    local name="$1"

    MOCK_SINGBOX_EVENT_LOG="$TEST_TMP/singbox-$name.log"
    : > "$MOCK_SINGBOX_EVENT_LOG"
}

test_singbox_version_guards() {
    local fake_bin="$TEST_TMP/bin"
    mkdir -p "$fake_bin"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$fake_bin/sing-box"
    chmod 755 "$fake_bin/sing-box"
    PATH="$fake_bin:$PATH"

    reset_singbox_case same
    MOCK_SINGBOX_VERSION="$SINGBOX_RELEASE_VERSION"
    update_singbox > "$TEST_TMP/singbox-same.out" 2>&1 || fail "相同 sing-box 版本应正常返回"
    assert_empty_file "$MOCK_SINGBOX_EVENT_LOG" "相同版本不得安装依赖或二进制"

    reset_singbox_case higher
    MOCK_SINGBOX_VERSION="1.14.0"
    update_singbox > "$TEST_TMP/singbox-higher.out" 2>&1 || fail "较高 sing-box 版本应拒绝降级并正常返回"
    assert_empty_file "$MOCK_SINGBOX_EVENT_LOG" "较高版本不得隐式降级"
    assert_file_contains "$TEST_TMP/singbox-higher.out" '已拒绝隐式降级'

    reset_singbox_case lower
    MOCK_SINGBOX_VERSION="1.13.13"
    update_singbox > "$TEST_TMP/singbox-lower.out" 2>&1 || fail "较低 sing-box 版本应更新"
    assert_file_contains "$MOCK_SINGBOX_EVENT_LOG" '^deps$'
    assert_file_contains "$MOCK_SINGBOX_EVENT_LOG" '^installer:1\.13\.14$'
}

main() {
    local test status passed=0
    local -a tests=(
        test_version_relation
        test_vpsbox_same_is_noop
        test_vpsbox_older_is_noop
        test_vpsbox_newer_updates_once
        test_vpsbox_invalid_download_preserves_current
        test_singbox_version_guards
    )

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
    printf '%s update mock tests passed.\n' "$passed"
}

main "$@"
