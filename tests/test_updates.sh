#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=tests/test_helper.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

# shellcheck source=../vpsbox.sh
source "$REPO_DIR/vpsbox.sh"

# 更新用例会用事件桩替换命令入口安装；先保留生产实现，避免成功路径永久被桩遮蔽。
eval "production_install_command_alias() $(declare -f install_command_alias | sed '1d')"
eval "production_start_vpsbox_update_watchdog() $(declare -f start_vpsbox_update_watchdog | sed '1d')"

# 更新夹具通过 install_deps 记录依赖阶段，不访问测试宿主机的软件源。
ensure_node_dependencies() { install_deps; }

MOCK_REMOTE_SCRIPT=""
MOCK_EVENT_LOG="$TEST_TMP/update-events.log"
MOCK_CURL_LOG="$TEST_TMP/update-curl.log"
MOCK_CURL_OPTIONS_LOG="$TEST_TMP/update-curl-options.log"
MOCK_CURL_FAIL_URLS=""
UPDATE_TEST_CURRENT=""
UPDATE_TEST_OLDER=""
UPDATE_TEST_NEWER=""

derive_update_test_versions() {
    local raw="${VPSBOX_VERSION#v}"
    local major minor patch extra=""

    IFS=. read -r major minor patch extra <<< "$raw"
    [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ && "$patch" =~ ^[0-9]+$ && -z "$extra" ]] ||
        fail "无法从 VPSBOX_VERSION 派生更新测试版本：$VPSBOX_VERSION"
    major=$((10#$major))
    minor=$((10#$minor))
    patch=$((10#$patch))

    UPDATE_TEST_CURRENT="v${major}.${minor}.${patch}"
    if [ "$patch" -lt 99 ]; then
        UPDATE_TEST_NEWER="v${major}.${minor}.$((patch + 1))"
    elif [ "$patch" -eq 99 ]; then
        UPDATE_TEST_NEWER="v${major}.$((minor + 1)).0"
    else
        fail "VPSBOX_VERSION 的补丁位不能大于 99：$VPSBOX_VERSION"
    fi
    if [ "$patch" -gt 0 ]; then
        UPDATE_TEST_OLDER="v${major}.${minor}.$((patch - 1))"
    elif [ "$minor" -gt 0 ]; then
        UPDATE_TEST_OLDER="v${major}.$((minor - 1)).99"
    elif [ "$major" -gt 0 ]; then
        UPDATE_TEST_OLDER="v$((major - 1)).99.99"
    else
        fail "VPSBOX_VERSION 不能使用 v0.0.0：无法构造更旧版本"
    fi
}

derive_update_test_versions

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
    local script_url="${4:-$SCRIPT_URL}"
    cat >"$path" <<EOF
#!/usr/bin/env bash
APP_NAME="vpsbox"
VPSBOX_VERSION="$version"
SCRIPT_URL="$script_url"
vpsbox_main() {
    printf '%s\n' '$marker'
}
if [[ "\${BASH_SOURCE[0]}" == "\$0" ]]; then
    vpsbox_main "\$@"
fi
EOF
    chmod 755 "$path"
}

assert_fixture_version() {
    local file="$1" version="$2"

    if ! grep -Fqx -- "VPSBOX_VERSION=\"$version\"" "$file"; then
        fail "文件版本不符合预期（期望：$version）"
    fi
}

curl() {
    local output="" url="" connect_timeout="" max_time=""

    while [ "$#" -gt 0 ]; do
        case "$1" in
            -o)
                output="${2:-}"
                shift 2
                ;;
            --connect-timeout)
                connect_timeout="${2:-}"
                shift 2
                ;;
            --max-time)
                max_time="${2:-}"
                shift 2
                ;;
            https://*)
                url="$1"
                shift
                ;;
            *) shift ;;
        esac
    done
    [ -n "$output" ] && [ -n "$url" ] || return 2
    printf '%s\n' "$url" >> "$MOCK_CURL_LOG"
    printf '%s|%s|%s\n' "$url" "$connect_timeout" "$max_time" >> "$MOCK_CURL_OPTIONS_LOG"
    if [ -n "$MOCK_CURL_FAIL_URLS" ] &&
        grep -Fqx -- "$url" <<< "$MOCK_CURL_FAIL_URLS"; then
        return 22
    fi
    cp "$MOCK_REMOTE_SCRIPT" "$output"
}

install_command_alias() {
    printf '%s\n' alias >> "$MOCK_EVENT_LOG"
}

cleanup_vpsbox_lock() {
    printf '%s\n' cleanup-lock >> "$MOCK_EVENT_LOG"
}

reexec_updated_vpsbox() {
    printf 'reexec:%s\n' "${1:-}" >> "$MOCK_EVENT_LOG"
}

start_vpsbox_update_watchdog() {
    # update_vpsbox 的单元夹具只验证接线顺序；真实 watchdog 由独立子进程用例覆盖。
    assert_fixture_version "$CMD_PATH" "$UPDATE_TEST_CURRENT" || return "$?"
    printf 'watchdog-start:%s\n' "${1:-}" >> "$MOCK_EVENT_LOG"
    VPSBOX_UPDATE_WATCHDOG_PID=""
    VPSBOX_UPDATE_WATCHDOG_DIR=""
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
    MOCK_CURL_LOG="$CASE_DIR/curl.log"
    MOCK_CURL_OPTIONS_LOG="$CASE_DIR/curl-options.log"
    MOCK_CURL_FAIL_URLS=""
    : > "$MOCK_EVENT_LOG"
    : > "$MOCK_CURL_LOG"
    : > "$MOCK_CURL_OPTIONS_LOG"
    RUNTIME_DIR="$CASE_DIR/run"
    mkdir -p "$RUNTIME_DIR"
    REMOTE_VERSION="v9.9.9"
    UPDATE_AVAILABLE=1
}

test_production_install_command_alias_wires_target() {
    (
        local alias_dir="$TEST_TMP/install-command-alias"
        local target_dir="$alias_dir/target-dir"
        local log="$TEST_TMP/install-command-alias.log"
        local output="$TEST_TMP/install-command-alias.out"
        CMD_PATH="$alias_dir/vpsbox.sh"
        CMD_ALIAS_PATH="$alias_dir/vpsbox"
        mkdir -p "$alias_dir"
        printf '%s\n' '#!/usr/bin/env bash' > "$CMD_PATH"

        production_install_command_alias > "$output" 2>&1
        [ -L "$CMD_ALIAS_PATH" ] ||
            fail "生产命令入口安装成功后必须生成符号链接"
        assert_eq "$CMD_PATH" "$(readlink "$CMD_ALIAS_PATH")" \
            "生产命令入口必须直接指向 CMD_PATH"

        rm -f -- "$CMD_ALIAS_PATH"
        mkdir "$CMD_ALIAS_PATH"
        if production_install_command_alias > "$output" 2>&1; then
            fail "命令入口是目录时必须拒绝覆盖"
        fi
        [ -d "$CMD_ALIAS_PATH" ] ||
            fail "拒绝目录冲突时不得删除原目录"
        [ ! -e "$CMD_ALIAS_PATH/${CMD_PATH##*/}" ] ||
            fail "命令入口是目录时不得在目录内创建嵌套链接"

        rmdir "$CMD_ALIAS_PATH"
        mkdir "$target_dir"
        command ln -s "$target_dir" "$CMD_ALIAS_PATH"
        if production_install_command_alias > "$output" 2>&1; then
            fail "命令入口指向目录时必须拒绝覆盖"
        fi
        [ -L "$CMD_ALIAS_PATH" ] &&
            [ "$(readlink "$CMD_ALIAS_PATH")" = "$target_dir" ] ||
            fail "拒绝目录链接冲突时不得替换原链接"
        [ ! -e "$target_dir/${CMD_PATH##*/}" ] ||
            fail "命令入口指向目录时不得在目标目录内创建嵌套链接"
        rm -f -- "$CMD_ALIAS_PATH"

        chmod() { return 0; }
        ln() { return 0; }
        if production_install_command_alias > "$output" 2>&1; then
            fail "ln 未生成预期符号链接时安装不得误报成功"
        fi
        assert_file_contains "$output" '入口创建后校验失败'

        : > "$log"
        chmod() {
            printf 'chmod-failed:%s\n' "$*" >> "$log"
            return 23
        }
        ln() { printf 'unexpected-ln:%s\n' "$*" >> "$log"; }
        if production_install_command_alias > "$output" 2>&1; then
            fail "管理脚本权限设置失败时命令入口安装不得成功"
        fi
        assert_file_contains "$log" '^chmod-failed:'
        assert_file_not_contains "$log" '^unexpected-ln:' \
            "权限设置失败后不得继续替换 /usr/bin/vpsbox"
    )
}

test_vpsbox_download_uses_bounded_curl_timeouts() {
    local dest line url connect_timeout max_time

    reset_update_case bounded-curl
    write_fixture "$MOCK_REMOTE_SCRIPT" "$UPDATE_TEST_CURRENT" remote
    dest="$CASE_DIR/downloaded.sh"

    download_vpsbox_script "$dest"
    line="$(cat "$MOCK_CURL_OPTIONS_LOG")"
    IFS='|' read -r url connect_timeout max_time <<< "$line"

    assert_eq "$SCRIPT_URL" "$url" "下载超时记录必须对应主脚本地址"
    [[ "$connect_timeout" =~ ^[0-9]+$ ]] && [ "$connect_timeout" -gt 0 ] &&
        [ "$connect_timeout" -le 30 ] ||
        fail "curl 连接超时必须是 1-30 秒的有界正整数：$connect_timeout"
    [[ "$max_time" =~ ^[0-9]+$ ]] && [ "$max_time" -ge "$connect_timeout" ] &&
        [ "$max_time" -le 300 ] ||
        fail "curl 总超时必须不小于连接超时且不超过 300 秒：$max_time"
}

test_version_relation() {
    assert_eq newer "$(version_relation v1.2.4 v1.2.3)"
    assert_eq same "$(version_relation 1.2.3 v1.2.3)"
    assert_eq older "$(version_relation v1.2.2 1.2.3)"
    assert_eq newer "$(version_relation v1.3.0 v1.2.99)"
    if version_relation v1.2 v1.2.3 >/dev/null 2>&1; then
        fail "畸形版本不应通过比较"
    fi
}

test_current_repository_identity_is_required() {
    local legacy="$TEST_TMP/legacy-old-owner.sh"
    local future="$TEST_TMP/future-new-owner.sh"
    local third_party="$TEST_TMP/third-party.sh"
    local legacy_url="https://raw.githubusercontent.com/QXTianPing/vpsbox/main/vpsbox.sh"

    write_fixture "$legacy" "$UPDATE_TEST_OLDER" legacy "$legacy_url"
    if vpsbox_script_identity_valid "$legacy"; then
        fail "v1.0.43 兼容基线不再接受旧用户名地址生成的历史备份"
    fi

    write_fixture "$future" "$UPDATE_TEST_NEWER" future "$SCRIPT_URL"
    vpsbox_script_identity_valid "$future" ||
        fail "必须接受当前官方地址生成的更新候选"

    write_fixture "$third_party" "$UPDATE_TEST_NEWER" third-party \
        "https://raw.githubusercontent.com/example/vpsbox/main/vpsbox.sh"
    if vpsbox_script_identity_valid "$third_party"; then
        fail "第三方仓库地址不得通过项目身份校验"
    fi
}

test_vpsbox_same_is_noop() {
    local output="$TEST_TMP/same.out"
    reset_update_case same
    write_fixture "$CMD_PATH" "$UPDATE_TEST_CURRENT" installed
    printf 'keep-backup\n' > "${CMD_PATH}.previous"
    write_fixture "$MOCK_REMOTE_SCRIPT" "$UPDATE_TEST_CURRENT" remote

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
    write_fixture "$CMD_PATH" "$UPDATE_TEST_CURRENT" installed
    printf 'keep-backup\n' > "${CMD_PATH}.previous"
    write_fixture "$MOCK_REMOTE_SCRIPT" "$UPDATE_TEST_OLDER" remote

    update_vpsbox > "$output" 2>&1 || fail "远端旧版本应安全返回"

    assert_file_contains "$output" '低于当前版本.*已拒绝降级'
    assert_file_contains "$CMD_PATH" 'installed'
    assert_file_contains "${CMD_PATH}.previous" '^keep-backup$'
    assert_empty_file "$MOCK_EVENT_LOG" "远端旧版本不得触发替换后的副作用"
}

test_vpsbox_newer_updates_once() {
    reset_update_case newer
    write_fixture "$CMD_PATH" "$UPDATE_TEST_CURRENT" installed
    printf 'keep-backup\n' > "${CMD_PATH}.previous"
    write_fixture "$MOCK_REMOTE_SCRIPT" "$UPDATE_TEST_NEWER" remote

    update_vpsbox > "$TEST_TMP/newer.out" 2>&1 || fail "远端新版本应更新成功"

    assert_fixture_version "$CMD_PATH" "$UPDATE_TEST_NEWER"
    assert_file_contains "$CMD_PATH" 'remote'
    assert_file_contains "${CMD_PATH}.previous" 'installed'
    assert_eq "watchdog-start:${CMD_PATH}.previous
alias
cleanup-lock
reexec:${CMD_PATH}.previous" "$(cat "$MOCK_EVENT_LOG")" \
        "更新必须在替换主脚本前启动 watchdog，再安装入口并重新执行"
    assert_eq "$SCRIPT_URL" "$(cat "$MOCK_CURL_LOG")" \
        "新地址可用时只应访问当前官方地址"
}

test_vpsbox_backup_copy_failure_preserves_existing_previous() {
    local output="$TEST_TMP/backup-copy-failure.out"

    reset_update_case backup-copy-failure
    write_fixture "$CMD_PATH" "$UPDATE_TEST_CURRENT" installed
    printf 'keep-backup\n' > "${CMD_PATH}.previous"
    write_fixture "$MOCK_REMOTE_SCRIPT" "$UPDATE_TEST_NEWER" remote
    cp() {
        if [ "$#" -ge 4 ] && [ "$1" = -a ] &&
            [ "$3" = "$CMD_PATH" ]; then
            return 23
        fi
        command cp "$@"
    }

    if update_vpsbox > "$output" 2>&1; then
        fail "当前脚本复制失败时更新不得继续"
    fi
    assert_fixture_version "$CMD_PATH" "$UPDATE_TEST_CURRENT"
    assert_file_contains "$CMD_PATH" 'installed'
    assert_file_contains "${CMD_PATH}.previous" '^keep-backup$' \
        "当前脚本复制失败时必须保留旧 .previous"
    assert_empty_file "$MOCK_EVENT_LOG" \
        "备份复制失败后不得启动 watchdog 或替换命令入口"
    [ -z "$(find "$CASE_DIR" -maxdepth 1 \
        \( -name '.vpsbox-update.*' -o -name '.vpsbox-previous.*' \) \
        -print -quit)" ] || fail "备份复制失败后必须清理更新临时文件"
    assert_file_contains "$output" '备份当前 vpsbox 脚本失败'
}

test_vpsbox_backup_publish_failure_preserves_existing_previous() {
    local output="$TEST_TMP/backup-publish-failure.out"

    reset_update_case backup-publish-failure
    write_fixture "$CMD_PATH" "$UPDATE_TEST_CURRENT" installed
    printf 'keep-backup\n' > "${CMD_PATH}.previous"
    write_fixture "$MOCK_REMOTE_SCRIPT" "$UPDATE_TEST_NEWER" remote
    mv() {
        local destination=""
        local arg

        for arg in "$@"; do
            destination="$arg"
        done
        if [ "$destination" = "${CMD_PATH}.previous" ]; then
            return 23
        fi
        command mv "$@"
    }

    if update_vpsbox > "$output" 2>&1; then
        fail ".previous 原子发布失败时更新不得继续"
    fi
    assert_fixture_version "$CMD_PATH" "$UPDATE_TEST_CURRENT"
    assert_file_contains "$CMD_PATH" 'installed'
    assert_file_contains "${CMD_PATH}.previous" '^keep-backup$' \
        ".previous 原子发布失败时必须保留旧备份"
    assert_empty_file "$MOCK_EVENT_LOG" \
        "备份发布失败后不得启动 watchdog 或替换命令入口"
    [ -z "$(find "$CASE_DIR" -maxdepth 1 \
        \( -name '.vpsbox-update.*' -o -name '.vpsbox-previous.*' \) \
        -print -quit)" ] || fail "备份发布失败后必须清理更新临时文件"
    assert_file_contains "$output" '备份当前 vpsbox 脚本失败'
}

test_vpsbox_watchdog_start_failure_preserves_current() {
    local output="$TEST_TMP/watchdog-start-failure.out"

    reset_update_case watchdog-start-failure
    write_fixture "$CMD_PATH" "$UPDATE_TEST_CURRENT" installed
    write_fixture "$MOCK_REMOTE_SCRIPT" "$UPDATE_TEST_NEWER" remote
    start_vpsbox_update_watchdog() {
        printf '%s\n' watchdog-start-failed >> "$MOCK_EVENT_LOG"
        return 23
    }

    if update_vpsbox > "$output" 2>&1; then
        fail "watchdog 启动失败时更新不得继续"
    fi
    assert_fixture_version "$CMD_PATH" "$UPDATE_TEST_CURRENT"
    assert_file_contains "$CMD_PATH" 'installed'
    assert_fixture_version "${CMD_PATH}.previous" "$UPDATE_TEST_CURRENT"
    assert_eq watchdog-start-failed "$(cat "$MOCK_EVENT_LOG")" \
        "watchdog 启动失败后不得安装入口或执行候选脚本"
    assert_file_contains "$output" '无法启动新版 vpsbox 启动监护'
}

test_vpsbox_update_rejects_unsafe_previous_target() {
    local output="$TEST_TMP/unsafe-previous.out" victim

    require_real_symlink file || return "$?"
    reset_update_case unsafe-previous
    write_fixture "$CMD_PATH" "$UPDATE_TEST_CURRENT" installed
    write_fixture "$MOCK_REMOTE_SCRIPT" "$UPDATE_TEST_NEWER" remote
    victim="$CASE_DIR/victim"
    printf '%s\n' keep > "$victim"
    ln -s "$victim" "${CMD_PATH}.previous"

    if update_vpsbox > "$output" 2>&1; then
        fail "自更新不得覆盖异常的 .previous 符号链接"
    fi
    assert_fixture_version "$CMD_PATH" "$UPDATE_TEST_CURRENT"
    [ -L "${CMD_PATH}.previous" ] || fail "拒绝更新后应保留异常链接供人工检查"
    assert_file_contains "$victim" '^keep$' "不得覆盖 .previous 链接指向的外部文件"
    assert_file_contains "$output" '旧版本备份路径不是安全的普通文件'
    assert_empty_file "$MOCK_EVENT_LOG" "拒绝异常备份路径后不得启动 watchdog 或替换命令入口"
}

test_vpsbox_never_fetches_old_owner_url() {
    local primary_count

    reset_update_case owner-failure
    write_fixture "$CMD_PATH" "$UPDATE_TEST_CURRENT" installed
    printf 'keep-backup\n' >"${CMD_PATH}.previous"
    write_fixture "$MOCK_REMOTE_SCRIPT" "$UPDATE_TEST_NEWER" remote
    MOCK_CURL_FAIL_URLS="$SCRIPT_URL"
    sleep() { :; }

    if update_vpsbox >"$TEST_TMP/owner-failure.out" 2>&1; then
        fail "当前官方地址失败时更新必须失败"
    fi

    assert_file_contains "$CMD_PATH" 'installed'
    assert_file_contains "${CMD_PATH}.previous" '^keep-backup$'
    primary_count="$(grep -Fxc -- "$SCRIPT_URL" "$MOCK_CURL_LOG" || true)"
    assert_eq 3 "$primary_count" "应只重试当前官方地址"
    if grep -Fvx -- "$SCRIPT_URL" "$MOCK_CURL_LOG" >/dev/null; then
        fail "更新失败时不得尝试当前官方地址以外的回退源"
    fi
}

test_primary_url_failure_preserves_current() {
    local primary_count

    reset_update_case primary-url-fail
    write_fixture "$CMD_PATH" "$UPDATE_TEST_CURRENT" installed
    printf 'keep-backup\n' >"${CMD_PATH}.previous"
    write_fixture "$MOCK_REMOTE_SCRIPT" "$UPDATE_TEST_NEWER" remote
    MOCK_CURL_FAIL_URLS="$SCRIPT_URL"
    sleep() { :; }

    if update_vpsbox >"$TEST_TMP/primary-url-fail.out" 2>&1; then
        fail "当前官方地址失败时更新必须报失败"
    fi

    assert_file_contains "$CMD_PATH" 'installed'
    assert_file_contains "${CMD_PATH}.previous" '^keep-backup$'
    assert_empty_file "$MOCK_EVENT_LOG" "下载失败不得触发替换后的副作用"
    primary_count="$(grep -Fxc -- "$SCRIPT_URL" "$MOCK_CURL_LOG" || true)"
    assert_eq 3 "$primary_count" "每轮都应尝试新主地址"
}

test_vpsbox_invalid_download_preserves_current() {
    local output="$TEST_TMP/invalid.out"
    reset_update_case invalid
    write_fixture "$CMD_PATH" "$UPDATE_TEST_CURRENT" installed
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

test_vpsbox_duplicate_version_declaration_preserves_current() {
    local index output
    local -a labels=(same export readonly declare)
    local -a declarations=(
        "VPSBOX_VERSION=\"$UPDATE_TEST_NEWER\""
        "export VPSBOX_VERSION=\"$UPDATE_TEST_OLDER\""
        "readonly VPSBOX_VERSION=\"$UPDATE_TEST_OLDER\""
        "declare -g VPSBOX_VERSION=\"$UPDATE_TEST_OLDER\""
    )

    for index in "${!labels[@]}"; do
        (
            reset_update_case "duplicate-version-${labels[index]}"
            output="$CASE_DIR/output"
            write_fixture "$CMD_PATH" "$UPDATE_TEST_CURRENT" installed
            printf 'keep-backup\n' > "${CMD_PATH}.previous"
            write_fixture "$MOCK_REMOTE_SCRIPT" "$UPDATE_TEST_NEWER" remote
            printf '%s\n' "${declarations[index]}" >> "$MOCK_REMOTE_SCRIPT"

            if update_vpsbox > "$output" 2>&1; then
                fail "包含重复 VPSBOX_VERSION 声明的远程脚本必须被拒绝"
            fi

            assert_file_contains "$output" '版本声明不唯一或格式无效'
            assert_file_contains "$CMD_PATH" 'installed'
            assert_file_contains "${CMD_PATH}.previous" '^keep-backup$'
            assert_empty_file "$MOCK_EVENT_LOG" \
                "重复版本声明不得触发替换后的副作用"
        )
    done
}

test_vpsbox_wrong_project_preserves_current() {
    local output="$TEST_TMP/wrong-project.out"
    reset_update_case wrong-project
    write_fixture "$CMD_PATH" "$UPDATE_TEST_CURRENT" installed
    printf 'keep-backup\n' > "${CMD_PATH}.previous"
    cat > "$MOCK_REMOTE_SCRIPT" <<EOF
#!/usr/bin/env bash
VPSBOX_VERSION="$UPDATE_TEST_NEWER"
printf '%s\n' wrong-project
EOF
    chmod 755 "$MOCK_REMOTE_SCRIPT"

    if update_vpsbox > "$output" 2>&1; then
        fail "仅伪造高版本号的错误项目脚本必须报失败"
    fi

    assert_file_contains "$output" '缺少 vpsbox 项目标识或必要入口'
    assert_file_contains "$CMD_PATH" 'installed'
    assert_file_contains "${CMD_PATH}.previous" '^keep-backup$'
    assert_empty_file "$MOCK_EVENT_LOG" "项目身份校验失败不得触发替换后的副作用"
}

test_vpsbox_reexec_failure_restores_previous() {
    local output="$TEST_TMP/reexec-failure.out"
    reset_update_case reexec-failure
    write_fixture "$CMD_PATH" "$UPDATE_TEST_CURRENT" installed "$SCRIPT_URL"
    write_fixture "$MOCK_REMOTE_SCRIPT" "$UPDATE_TEST_NEWER" remote
    reexec_updated_vpsbox() {
        printf 'reexec-failed:%s\n' "${1:-}" >> "$MOCK_EVENT_LOG"
        return 42
    }

    if update_vpsbox > "$output" 2>&1; then
        fail "新版重新执行失败时应返回失败"
    fi

    assert_fixture_version "$CMD_PATH" "$UPDATE_TEST_CURRENT"
    assert_file_contains "$CMD_PATH" 'installed'
    assert_fixture_version "${CMD_PATH}.previous" "$UPDATE_TEST_CURRENT"
    grep -Fqx -- "reexec-failed:${CMD_PATH}.previous" "$MOCK_EVENT_LOG" ||
        fail "重执行失败路径未收到本次备份路径"
    assert_file_contains "$MOCK_EVENT_LOG" '^acquire-lock$'
    assert_file_contains "$output" '已从 .*previous 恢复旧版 vpsbox'
}

test_real_reexec_failure_returns_without_option_or_env_leaks() {
    local case_dir="$TEST_TMP/real-reexec-failure" output status

    mkdir -p "$case_dir/watchdog"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$case_dir/not-executable"
    chmod 600 "$case_dir/not-executable"
    set +e
    REPO_DIR="$REPO_DIR" CASE_DIR="$case_dir" bash -c '
        set -euo pipefail
        source "$REPO_DIR/vpsbox.sh"
        cleanup_test_watchdog() {
            local pid="${VPSBOX_UPDATE_WATCHDOG_PID:-}"
            [ -n "$pid" ] || return 0
            kill -TERM "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        }
        trap cleanup_test_watchdog EXIT
        declare -F reexec_updated_vpsbox >/dev/null || {
            printf "missing:reexec_updated_vpsbox\n"
            exit 97
        }
        CMD_PATH="$CASE_DIR/not-executable"
        RUNTIME_DIR="$CASE_DIR"
        start_vpsbox_update_watchdog() {
            VPSBOX_UPDATE_WATCHDOG_DIR="$CASE_DIR/update-startup.test"
            mkdir -p "$VPSBOX_UPDATE_WATCHDOG_DIR"
            ( while :; do sleep 1; done ) &
            # shellcheck disable=SC2034 # 被测函数通过动态全局读取 watchdog PID。
            VPSBOX_UPDATE_WATCHDOG_PID=$!
        }
        shopt -u execfail
        set +e
        reexec_updated_vpsbox "$CASE_DIR/previous"
        rc=$?
        set -e
        [ -f "$VPSBOX_UPDATE_WATCHDOG_DIR/handoff" ] &&
            [ ! -L "$VPSBOX_UPDATE_WATCHDOG_DIR/handoff" ] &&
            printf "handoff:present\n"
        kill -TERM "$VPSBOX_UPDATE_WATCHDOG_PID" 2>/dev/null || true
        wait "$VPSBOX_UPDATE_WATCHDOG_PID" 2>/dev/null || true
        VPSBOX_UPDATE_WATCHDOG_PID=""
        printf "reached:%s\n" "$rc"
        shopt -q execfail && printf "execfail:on\n" || printf "execfail:off\n"
        [ -z "${VPSBOX_UPDATE_BACKUP+x}" ] && printf "backup-env:clear\n"
        [ -z "${VPSBOX_UPDATE_READY_FILE+x}" ] && printf "ready-env:clear\n"
    ' > "$case_dir/output" 2>&1
    status=$?
    set -e
    [ "$status" -eq 0 ] || fail "真实 reexec 失败夹具异常退出：$status"
    output="$case_dir/output"
    assert_file_contains "$output" '^reached:126$' \
        "不可执行文件必须以 126 返回控制权"
    assert_file_not_contains "$output" 'command not found|missing:reexec_updated_vpsbox'
    assert_file_contains "$output" '^handoff:present$' \
        "production reexec 必须在 exec 前通知 watchdog 进入新版启动阶段"
    assert_file_contains "$output" '^execfail:off$'
    assert_file_contains "$output" '^backup-env:clear$'
    assert_file_contains "$output" '^ready-env:clear$'
}

test_vpsbox_reexec_failure_restores_before_ready() {
    (
        local output="$TEST_TMP/reexec-order.out" ready order_watchdog_pid=""
        cleanup_order_watchdog() {
            [ -n "$order_watchdog_pid" ] || return 0
            kill -TERM "$order_watchdog_pid" 2>/dev/null || true
            wait "$order_watchdog_pid" 2>/dev/null || true
        }
        trap cleanup_order_watchdog EXIT
        reset_update_case reexec-order
        write_fixture "$CMD_PATH" "$UPDATE_TEST_CURRENT" installed
        write_fixture "$MOCK_REMOTE_SCRIPT" "$UPDATE_TEST_NEWER" remote

        reexec_updated_vpsbox() {
            VPSBOX_UPDATE_WATCHDOG_DIR="$RUNTIME_DIR/update-startup.order"
            mkdir -p "$VPSBOX_UPDATE_WATCHDOG_DIR"
            ready="$VPSBOX_UPDATE_WATCHDOG_DIR/ready"
            (
                while [ ! -e "$ready" ]; do sleep 0.01; done
            ) &
            order_watchdog_pid=$!
            # shellcheck disable=SC2034 # update_vpsbox 的监护收尾 helper 动态读取。
            VPSBOX_UPDATE_WATCHDOG_PID=$order_watchdog_pid
            return 42
        }
        mark_vpsbox_update_ready() {
            assert_fixture_version "$CMD_PATH" "$UPDATE_TEST_CURRENT" || return "$?"
            printf '%s\n' ready-after-restore >> "$MOCK_EVENT_LOG"
            : > "$1"
        }

        if update_vpsbox > "$output" 2>&1; then
            fail "新版重新执行失败时更新不得报告成功"
        fi
        assert_fixture_version "$CMD_PATH" "$UPDATE_TEST_CURRENT"
        assert_file_contains "$MOCK_EVENT_LOG" '^ready-after-restore$' \
            "只有旧版安全落盘后才能解除 watchdog"
        assert_file_contains "$MOCK_EVENT_LOG" '^acquire-lock$'
        cleanup_order_watchdog
        order_watchdog_pid=""
        trap - EXIT
    )
}

test_vpsbox_alias_failure_restores_previous_without_reexec() {
    local output
    reset_update_case alias-failure
    output="$TEST_TMP/alias-failure.out"
    write_fixture "$CMD_PATH" "$UPDATE_TEST_CURRENT" current
    write_fixture "$MOCK_REMOTE_SCRIPT" "$UPDATE_TEST_NEWER" newer
    install_command_alias() {
        printf '%s\n' alias-failed >> "$MOCK_EVENT_LOG"
        return 1
    }
    restore_previous_vpsbox() {
        printf 'restore:%s\n' "$1" >> "$MOCK_EVENT_LOG"
        cp "$1" "$CMD_PATH"
    }

    if update_vpsbox > "$output" 2>&1; then
        fail "管理命令入口安装失败时更新不应成功"
    fi
    assert_fixture_version "$CMD_PATH" "$UPDATE_TEST_CURRENT"
    assert_file_contains "$MOCK_EVENT_LOG" '^alias-failed$'
    assert_file_contains "$MOCK_EVENT_LOG" '^restore:'
    assert_file_not_contains "$MOCK_EVENT_LOG" '^reexec:'
    assert_file_not_contains "$MOCK_EVENT_LOG" '^cleanup-lock$'
    assert_file_contains "$output" '管理命令入口安装失败'
    assert_file_contains "$output" '已恢复更新前的 vpsbox 脚本。'
}

test_pending_update_startup_failure_restores_previous() {
    local status

    reset_update_case startup-rollback
    write_fixture "${CMD_PATH}.previous" "$UPDATE_TEST_CURRENT" installed
    cat > "$CMD_PATH" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$REPO_DIR/vpsbox.sh"
CMD_PATH="$TARGET_PATH"
RUNTIME_DIR="$RUNTIME_TARGET"
LOCK_FILE="$RUNTIME_DIR/vpsbox.lock"
LOCK_DIR="$RUNTIME_DIR/lockdir"
install_command_alias() { :; }
need_root() { return 42; }
vpsbox_main
EOF
    chmod 755 "$CMD_PATH"

    set +e
    REPO_DIR="$REPO_DIR" TARGET_PATH="$CMD_PATH" RUNTIME_TARGET="$RUNTIME_DIR" bash -c '
        set -euo pipefail
        source "$REPO_DIR/vpsbox.sh"
        CMD_PATH="$TARGET_PATH"
        RUNTIME_DIR="$RUNTIME_TARGET"
        LOCK_FILE="$RUNTIME_DIR/vpsbox.lock"
        LOCK_DIR="$RUNTIME_DIR/lockdir"
        install_command_alias() { :; }
        reexec_updated_vpsbox "${TARGET_PATH}.previous"
    ' >"$TEST_TMP/startup-rollback.out" 2>&1
    status=$?
    set -e

    assert_eq 42 "$status" "新版启动失败的原退出状态不应被回滚处理吞掉"
    assert_fixture_version "$CMD_PATH" "$UPDATE_TEST_CURRENT"
    assert_file_contains "$CMD_PATH" 'installed'
    assert_fixture_version "${CMD_PATH}.previous" "$UPDATE_TEST_CURRENT"
    assert_file_contains "$TEST_TMP/startup-rollback.out" '未完成首次界面启动'
    assert_file_contains "$TEST_TMP/startup-rollback.out" '已从 .*previous 恢复旧版 vpsbox'
}

test_top_level_startup_failure_restores_previous() {
    local status restored=0

    reset_update_case top-level-rollback
    write_fixture "${CMD_PATH}.previous" "$UPDATE_TEST_CURRENT" installed
    cat > "$CMD_PATH" <<EOF
#!/usr/bin/env bash
exit 41
APP_NAME="vpsbox"
VPSBOX_VERSION="$UPDATE_TEST_NEWER"
SCRIPT_URL="https://raw.githubusercontent.com/TianPingXi/vpsbox/main/vpsbox.sh"
vpsbox_main() {
    printf '%s\n' should-not-run
}
if [[ "\${BASH_SOURCE[0]}" == "\$0" ]]; then
    vpsbox_main "\$@"
fi
EOF
    chmod 755 "$CMD_PATH"
    vpsbox_script_identity_valid "$CMD_PATH" ||
        fail "测试候选应能通过现有静态身份校验"

    set +e
    REPO_DIR="$REPO_DIR" TARGET_PATH="$CMD_PATH" RUNTIME_TARGET="$RUNTIME_DIR" bash -c '
        set -euo pipefail
        source "$REPO_DIR/vpsbox.sh"
        CMD_PATH="$TARGET_PATH"
        RUNTIME_DIR="$RUNTIME_TARGET"
        LOCK_FILE="$RUNTIME_DIR/vpsbox.lock"
        LOCK_DIR="$RUNTIME_DIR/lockdir"
        install_command_alias() { :; }
        reexec_updated_vpsbox "${TARGET_PATH}.previous"
    ' >"$TEST_TMP/top-level-rollback.out" 2>&1
    status=$?
    set -e

    assert_eq 41 "$status" "候选顶层退出码不应被监护进程吞掉"
    for _ in {1..50}; do
        if grep -Fq installed "$CMD_PATH" 2>/dev/null; then
            restored=1
            break
        fi
        sleep 0.1
    done
    assert_eq 1 "$restored" "候选在进入 vpsbox_main 前退出时应自动恢复旧版"
    assert_fixture_version "$CMD_PATH" "$UPDATE_TEST_CURRENT"
    assert_file_contains "$CMD_PATH" 'installed'
}

test_pending_update_confirmation_prevents_rollback() {
    local ready_dir ready

    reset_update_case startup-confirmed
    write_fixture "$CMD_PATH" "$UPDATE_TEST_NEWER" remote
    write_fixture "${CMD_PATH}.previous" "$UPDATE_TEST_CURRENT" installed
    ready_dir="$RUNTIME_DIR/update-startup.confirmed"
    ready="$ready_dir/ready"
    mkdir -p "$ready_dir"
    PENDING_VPSBOX_UPDATE_BACKUP="${CMD_PATH}.previous"
    PENDING_VPSBOX_UPDATE_READY_FILE="$ready"
    VPSBOX_UPDATE_STARTUP_CONFIRMED=0

    confirm_pending_vpsbox_update
    rollback_pending_vpsbox_update

    assert_fixture_version "$CMD_PATH" "$UPDATE_TEST_NEWER"
    assert_file_contains "$CMD_PATH" 'remote'
    assert_eq "" "$PENDING_VPSBOX_UPDATE_BACKUP"
    assert_eq "" "$PENDING_VPSBOX_UPDATE_READY_FILE"
    assert_eq 1 "$VPSBOX_UPDATE_STARTUP_CONFIRMED"
    [ -f "$ready" ] || fail "确认新版启动时应通知父进程 watchdog"
}

test_update_watchdog_late_ready_cannot_cancel_rollback() {
    (
        local event_log="$TEST_TMP/watchdog-late-ready.log" watchdog_pid

        reset_update_case watchdog-late-ready
        write_fixture "$CMD_PATH" "$UPDATE_TEST_NEWER" remote
        write_fixture "${CMD_PATH}.previous" "$UPDATE_TEST_CURRENT" installed
        : > "$event_log"
        VPSBOX_UPDATE_PREPARE_TIMEOUT=0
        VPSBOX_UPDATE_STARTUP_TIMEOUT=0
        process_start_ticks() { printf '%s\n' 12345; }
        sleep() { :; }
        kill() {
            local dir
            printf 'kill:%s\n' "$*" >> "$event_log"
            if [ "${1:-}" = -TERM ]; then
                for dir in "$RUNTIME_DIR"/update-startup.*; do
                    [ -d "$dir" ] || continue
                    : > "$dir/ready"
                done
            fi
        }
        restore_previous_vpsbox() {
            printf 'restore:%s\n' "$1" >> "$event_log"
        }

        production_start_vpsbox_update_watchdog "${CMD_PATH}.previous"
        watchdog_pid="$VPSBOX_UPDATE_WATCHDOG_PID"
        wait "$watchdog_pid"

        assert_file_contains "$event_log" '^kill:-TERM '
        assert_file_contains "$event_log" '^restore:' \
            "进入回滚阶段后迟到的 ready 不得把已终止候选重新判为成功"
    )
}

test_update_watchdog_handoff_resets_startup_timer() {
    (
        local event_log="$TEST_TMP/watchdog-handoff.log" watchdog_pid="" watchdog_dir
        cleanup_handoff_watchdog() {
            [ -n "$watchdog_pid" ] || return 0
            builtin kill -TERM "$watchdog_pid" 2>/dev/null || true
            wait "$watchdog_pid" 2>/dev/null || true
        }
        trap cleanup_handoff_watchdog EXIT

        reset_update_case watchdog-handoff
        write_fixture "$CMD_PATH" "$UPDATE_TEST_NEWER" remote
        write_fixture "${CMD_PATH}.previous" "$UPDATE_TEST_CURRENT" installed
        : > "$event_log"
        [ "$VPSBOX_UPDATE_STARTUP_TIMEOUT" -gt "$PACKAGE_INSTALL_TIMEOUT" ] ||
            fail "新版启动预算必须覆盖合法的包恢复上限"
        export VPSBOX_UPDATE_PREPARE_TIMEOUT=7
        VPSBOX_UPDATE_STARTUP_TIMEOUT=4
        process_start_ticks() { printf '%s\n' 12345; }
        kill() { printf 'kill:%s\n' "$*" >> "$event_log"; }
        restore_previous_vpsbox() { printf 'restore:%s\n' "$1" >> "$event_log"; }

        production_start_vpsbox_update_watchdog "${CMD_PATH}.previous"
        watchdog_pid="$VPSBOX_UPDATE_WATCHDOG_PID"
        watchdog_dir="$VPSBOX_UPDATE_WATCHDOG_DIR"
        command sleep 4
        builtin kill -0 "$watchdog_pid" 2>/dev/null ||
            fail "handoff 前的准备期不应消耗新版启动预算"
        assert_empty_file "$event_log" "handoff 前 watchdog 不应终止或恢复仍存活的更新进程"

        mark_vpsbox_update_handoff "$watchdog_dir/handoff"
        command sleep 2
        mark_vpsbox_update_ready "$watchdog_dir/ready"
        wait "$watchdog_pid"
        watchdog_pid=""
        assert_empty_file "$event_log" "handoff 后及时 ready 不应触发终止或恢复"
        trap - EXIT
    )
}

test_stale_previous_without_handshake_is_ignored() {
    reset_update_case startup-no-handshake
    write_fixture "$CMD_PATH" "$UPDATE_TEST_NEWER" remote
    write_fixture "${CMD_PATH}.previous" "$UPDATE_TEST_CURRENT" installed
    PENDING_VPSBOX_UPDATE_BACKUP=""
    PENDING_VPSBOX_UPDATE_READY_FILE=""
    VPSBOX_UPDATE_STARTUP_CONFIRMED=0

    rollback_pending_vpsbox_update

    assert_fixture_version "$CMD_PATH" "$UPDATE_TEST_NEWER"
    assert_file_contains "$CMD_PATH" 'remote'
}

test_pending_update_rejects_unexpected_backup_path() {
    local ready_dir

    reset_update_case startup-invalid-backup
    write_fixture "$CMD_PATH" "$UPDATE_TEST_NEWER" remote
    write_fixture "$CASE_DIR/unexpected.previous" "$UPDATE_TEST_CURRENT" installed
    ready_dir="$RUNTIME_DIR/update-startup.invalid"
    mkdir -p "$ready_dir"
    PENDING_VPSBOX_UPDATE_BACKUP="$CASE_DIR/unexpected.previous"
    PENDING_VPSBOX_UPDATE_READY_FILE="$ready_dir/ready"
    VPSBOX_UPDATE_STARTUP_CONFIRMED=0

    if rollback_pending_vpsbox_update >"$TEST_TMP/invalid-backup.out" 2>&1; then
        fail "启动回滚不得接受非 ${CMD_PATH}.previous 路径"
    fi
    assert_fixture_version "$CMD_PATH" "$UPDATE_TEST_NEWER"
    assert_file_contains "$TEST_TMP/invalid-backup.out" '拒绝使用非预期'
}

MOCK_SINGBOX_VERSION=""
MOCK_SINGBOX_EVENT_LOG=""

singbox_installed() { return 0; }
singbox_version() { printf '%s\n' "$MOCK_SINGBOX_VERSION"; }
service_is_running() { return 1; }
service_is_enabled() { return 1; }
service_manager_is_active() { return 1; }
service_stop() { printf '%s\n' service-stop >> "${MOCK_SINGBOX_EVENT_LOG:?先调用 reset_singbox_case}"; }
stop_singbox_config_processes() { printf '%s\n' process-stop >> "${MOCK_SINGBOX_EVENT_LOG:?先调用 reset_singbox_case}"; }
node_exists() { return 1; }
install_deps() { printf '%s\n' deps >> "${MOCK_SINGBOX_EVENT_LOG:?先调用 reset_singbox_case}"; }
singbox_binary_is_package_managed() { return 0; }
prepare_singbox_rollback_package() {
    local package="$2/sing-box-old.deb"
    : > "$package"
    printf '%s\n' "$package"
}
run_singbox_installer() {
    printf 'installer:%s\n' "${1:-$SINGBOX_RELEASE_VERSION}" \
        >> "${MOCK_SINGBOX_EVENT_LOG:?先调用 reset_singbox_case}"
    MOCK_SINGBOX_VERSION="${1:-$SINGBOX_RELEASE_VERSION}"
}
restore_singbox_service_state() {
    printf 'restore:%s:%s:%s\n' "$1" "$2" "${3:-1}" \
        >> "${MOCK_SINGBOX_EVENT_LOG:?先调用 reset_singbox_case}"
}

reset_singbox_case() {
    local name="$1"

    MOCK_SINGBOX_EVENT_LOG="$TEST_TMP/singbox-$name.log"
    : > "$MOCK_SINGBOX_EVENT_LOG"
    VPSBOX_STATE_DIR="$TEST_TMP/singbox-$name-state"
    SINGBOX_UPDATE_TRANSACTION_DIR="$VPSBOX_STATE_DIR/singbox-update"
    # shellcheck disable=SC2034 # 被测的 sing-box 持久事务函数动态读取。
    SINGBOX_UPDATE_TRANSACTION_STATE="$SINGBOX_UPDATE_TRANSACTION_DIR/state"
    # shellcheck disable=SC2034 # 被测的 sing-box 持久事务函数动态读取。
    VPSBOX_TEST_MODE=1
}

write_singbox_cleanup_residual() {
    local binary_path="$1"

    mkdir -p "$SINGBOX_UPDATE_TRANSACTION_DIR"
    chmod 700 "$SINGBOX_UPDATE_TRANSACTION_DIR"
    cat > "$SINGBOX_UPDATE_TRANSACTION_STATE" <<EOF
version=1
binary_path=$binary_path
old_version=1.13.13
was_enabled=0
was_active=0
package_name=none
binary_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
package_sha256=none
EOF
    : > "$SINGBOX_UPDATE_TRANSACTION_DIR/pending"
    chmod 600 "$SINGBOX_UPDATE_TRANSACTION_STATE" "$SINGBOX_UPDATE_TRANSACTION_DIR/pending"
    command chown root:root "$SINGBOX_UPDATE_TRANSACTION_DIR" \
        "$SINGBOX_UPDATE_TRANSACTION_STATE" "$SINGBOX_UPDATE_TRANSACTION_DIR/pending"
}

test_interrupted_singbox_cleanup_validates_current_binary() {
    (
        local binary output="$TEST_TMP/singbox-cleanup-valid.out"

        require_root_permission_semantics || return "$?"
        reset_singbox_case cleanup-valid
        binary="$TEST_TMP/singbox-cleanup-valid/sing-box"
        mkdir -p "$(dirname "$binary")" "$VPSBOX_STATE_DIR"
        printf '%s\n' '#!/bin/sh' 'printf "sing-box version 1.13.14\n"' > "$binary"
        chmod 755 "$binary"
        command chown root:root "$binary" "$VPSBOX_STATE_DIR"
        write_singbox_cleanup_residual "$binary"
        : > "$VPSBOX_STATE_DIR/keep-sibling"

        recover_pending_singbox_update > "$output" 2>&1 ||
            fail "当前 sing-box 可信可用时应清理无恢复价值的事务残留"
        [ ! -e "$SINGBOX_UPDATE_TRANSACTION_DIR" ] ||
            fail "有效当前二进制确认后应清理事务残留"
        [ -f "$VPSBOX_STATE_DIR/keep-sibling" ] ||
            fail "自愈不得删除 sing-box 事务目录以外的状态"
        assert_file_contains "$output" '更新或回滚清理曾中断'
        assert_file_not_contains "$output" '更新完成'
    )
    (
        local binary output="$TEST_TMP/singbox-cleanup-invalid.out"

        require_root_permission_semantics || return "$?"
        reset_singbox_case cleanup-invalid
        binary="$TEST_TMP/singbox-cleanup-invalid/sing-box"
        mkdir -p "$(dirname "$binary")" "$VPSBOX_STATE_DIR"
        printf '%s\n' '#!/bin/sh' 'printf "sing-box version 1.13.14\n"' > "$binary"
        chmod 775 "$binary"
        command chown root:root "$binary" "$VPSBOX_STATE_DIR"
        write_singbox_cleanup_residual "$binary"

        if recover_pending_singbox_update > "$output" 2>&1; then
            fail "当前二进制可被非 root 写入时不得自动清理事务"
        fi
        [ -f "$SINGBOX_UPDATE_TRANSACTION_DIR/pending" ] ||
            fail "无法安全判定时必须保留事务记录"
        assert_file_contains "$output" '当前二进制或事务元数据不可用'
    )
}

test_singbox_commit_removes_pending_then_syncs_before_cleanup() {
    (
        local log="$TEST_TMP/singbox-pending-first.log"
        reset_singbox_case pending-first
        mkdir -p "$SINGBOX_UPDATE_TRANSACTION_DIR"
        : > "$SINGBOX_UPDATE_TRANSACTION_DIR/pending"
        : > "$log"
        rm() { printf 'rm:%s\n' "$*" >> "$log"; }
        sync_node_transaction_store() { printf '%s\n' sync >> "$log"; }

        remove_singbox_update_transaction_dir
        assert_eq "rm:-f -- $SINGBOX_UPDATE_TRANSACTION_DIR/pending
sync
rm:-rf -- $SINGBOX_UPDATE_TRANSACTION_DIR" "$(cat "$log")" \
            "事务提交清理必须先移除 pending、持久化，再删除其余恢复材料"
    )
}

test_singbox_version_noop_guards() {
    local fake_bin="$TEST_TMP/bin"
    mkdir -p "$fake_bin"
    printf '#!/usr/bin/env bash\nprintf \"sing-box version 1.13.13\\n\"\n' > "$fake_bin/sing-box"
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
}

test_singbox_lower_version_updates() {
    local fake_bin="$TEST_TMP/bin-lower"

    require_root_permission_semantics || return "$?"
    mkdir -p "$fake_bin"
    printf '#!/usr/bin/env bash\nprintf \"sing-box version 1.13.13\\n\"\n' > "$fake_bin/sing-box"
    chmod 755 "$fake_bin/sing-box"
    PATH="$fake_bin:$PATH"

    reset_singbox_case lower
    MOCK_SINGBOX_VERSION="1.13.13"
    update_singbox > "$TEST_TMP/singbox-lower.out" 2>&1 || fail "较低 sing-box 版本应更新"
    assert_file_contains "$MOCK_SINGBOX_EVENT_LOG" '^deps$'
    assert_file_contains "$MOCK_SINGBOX_EVENT_LOG" '^installer:1\.13\.14$'
}

test_singbox_update_continues_without_rollback_package() {
    (
        local fake_bin="$TEST_TMP/singbox-no-package-success/bin"
        local output="$TEST_TMP/singbox-no-package-success.out"

        require_root_permission_semantics || return "$?"
        reset_singbox_case no-package-success
        mkdir -p "$fake_bin"
        printf '%s\n' '#!/bin/sh' 'printf "sing-box version 1.13.13\n"' > "$fake_bin/sing-box"
        chmod 755 "$fake_bin/sing-box"
        PATH="$fake_bin:$PATH"
        MOCK_SINGBOX_VERSION=1.13.13

        node_core_artifacts_present() { return 1; }
        prepare_singbox_rollback_package() {
            printf '%s\n' rollback-package-unavailable >> "$MOCK_SINGBOX_EVENT_LOG"
            return 23
        }

        update_singbox > "$output" 2>&1 ||
            fail "旧版本回滚包不可用时，可信旧二进制已持久化后仍应继续更新"
        assert_file_contains "$MOCK_SINGBOX_EVENT_LOG" '^rollback-package-unavailable$'
        assert_file_contains "$MOCK_SINGBOX_EVENT_LOG" '^installer:1\.13\.14$'
        assert_file_contains "$output" '旧版 sing-box 回滚包.*继续更新'
        [ ! -e "$SINGBOX_UPDATE_TRANSACTION_DIR" ] ||
            fail "无旧包的成功更新也必须提交并清理事务"
    )
}

test_singbox_update_without_package_rolls_back_binary_and_service() {
    (
        local fake_bin="$TEST_TMP/singbox-no-package-failure/bin"
        local output="$TEST_TMP/singbox-no-package-failure.out"

        require_root_permission_semantics || return "$?"
        reset_singbox_case no-package-failure
        mkdir -p "$fake_bin"
        printf '%s\n' '#!/bin/sh' 'printf "sing-box version 1.13.13\n"' > "$fake_bin/sing-box"
        chmod 755 "$fake_bin/sing-box"
        PATH="$fake_bin:$PATH"
        MOCK_SINGBOX_VERSION=1.13.13

        node_core_artifacts_present() { return 1; }
        # 服务管理器 active，但没有精确匹配 vpsbox 配置目录的进程。
        service_is_running() { return 1; }
        service_manager_is_active() { return 0; }
        service_is_enabled() { return 0; }
        prepare_singbox_rollback_package() { return 23; }
        install_singbox_package_file() {
            printf 'package-install:%s\n' "$1" >> "$MOCK_SINGBOX_EVENT_LOG"
            return 23
        }
        run_singbox_installer() {
            printf '%s\n' installer-failed >> "$MOCK_SINGBOX_EVENT_LOG"
            printf '%s\n' '#!/bin/sh' 'printf "sing-box version 1.13.14\n"' > "$fake_bin/sing-box"
            chmod 755 "$fake_bin/sing-box"
            MOCK_SINGBOX_VERSION=1.13.14
            return 23
        }

        if update_singbox > "$output" 2>&1; then
            fail "新版安装失败后 update_singbox 必须返回失败"
        fi
        assert_file_contains "$MOCK_SINGBOX_EVENT_LOG" '^installer-failed$'
        assert_file_not_contains "$MOCK_SINGBOX_EVENT_LOG" '^package-install:'
        assert_file_contains "$MOCK_SINGBOX_EVENT_LOG" '^restore:1:1:0$' \
            "无节点更新应按服务管理器状态恢复，不要求匹配 vpsbox 节点进程"
        assert_eq 1.13.13 "$(singbox_binary_version_at "$fake_bin/sing-box")" \
            "无旧包时必须恢复经过版本校验的旧二进制"
        assert_file_contains "$output" '软件包管理记录可能不一致'
        [ ! -e "$SINGBOX_UPDATE_TRANSACTION_DIR" ] ||
            fail "旧二进制和服务状态完整恢复后应清理事务"
    )
}

test_pending_singbox_update_without_package_recovers_on_startup() {
    (
        local root="$TEST_TMP/singbox-no-package-recovery"
        local binary="$root/bin/sing-box" backup="$root/old-binary"
        local output="$root/recovery.out"

        require_root_permission_semantics || return "$?"
        reset_singbox_case no-package-recovery
        mkdir -p "$(dirname "$binary")"
        printf '%s\n' '#!/bin/sh' 'printf "sing-box version 1.13.13\n"' > "$binary"
        chmod 755 "$binary"
        cp -a "$binary" "$backup"
        singbox_version() { singbox_binary_version_at "$binary"; }
        install_singbox_package_file() {
            fail "package_name=none 时不得尝试安装路径：$1"
        }

        persist_singbox_update_transaction \
            "$binary" "$backup" "" 1.13.13 1 1
        assert_file_contains "$SINGBOX_UPDATE_TRANSACTION_STATE" '^package_name=none$'
        assert_file_contains "$SINGBOX_UPDATE_TRANSACTION_STATE" '^package_sha256=none$'

        printf '%s\n' '#!/bin/sh' 'printf "sing-box version 1.13.14\n"' > "$binary"
        chmod 755 "$binary"
        recover_pending_singbox_update > "$output" 2>&1 ||
            fail "无旧包的未完成更新应使用持久化旧二进制恢复"

        assert_eq 1.13.13 "$(singbox_binary_version_at "$binary")"
        assert_file_contains "$MOCK_SINGBOX_EVENT_LOG" '^restore:1:1:0$'
        assert_file_contains "$output" '软件包管理记录可能不一致'
        [ ! -e "$SINGBOX_UPDATE_TRANSACTION_DIR" ] ||
            fail "无旧包事务完整恢复后必须清理"
    )
}

test_singbox_redhat_release_arch_mapping() {
    local input expected actual
    local -a cases=(
        amd64 x86_64 arm64 aarch64 armv7 armv7hl armv7l armv7hl
        armv6 armv6hl armv6l armv6hl i386 i386 i486 i386 i586 i386 i686 i386
        ppc64el ppc64le mips64le mips64el x86_64 x86_64 aarch64 aarch64
        loongarch64 loongarch64 mips64el mips64el mipsel mipsel ppc64le ppc64le
        riscv64 riscv64 s390x s390x
    )

    export OS=redhat
    while [ "${#cases[@]}" -gt 0 ]; do
        input="${cases[0]}"
        expected="${cases[1]}"
        cases=("${cases[@]:2}")
        uname() { printf '%s\n' "$input"; }
        actual="$(singbox_release_package_arch)" ||
            fail "RedHat 架构 $input 应有对应 RPM"
        assert_eq "$expected" "$actual" "RedHat RPM 架构映射错误：$input"
    done

    uname() { printf '%s\n' sparc64; }
    if singbox_release_package_arch > "$TEST_TMP/singbox-unsupported-arch.out" 2>&1; then
        fail "没有官方 RPM 的 RedHat 架构必须被拒绝"
    fi
    assert_file_contains "$TEST_TMP/singbox-unsupported-arch.out" '没有对应的 sing-box RPM：sparc64'
}

main() {
    local name
    local -a required=(
        version_is_newer
        version_relation
        fetch_vpsbox_script_once
        download_vpsbox_script
        update_vpsbox
        auto_update_vpsbox_on_start
        rollback_pending_vpsbox_update
        reexec_updated_vpsbox
        start_vpsbox_update_watchdog
        mark_vpsbox_update_handoff
        settle_vpsbox_update_watchdog_after_safe_restore
        recover_pending_singbox_update
        remove_singbox_update_transaction_dir
        current_singbox_update_binary_usable
        production_install_command_alias
        production_start_vpsbox_update_watchdog
    )
    local -a tests=(
        test_production_install_command_alias_wires_target
        test_vpsbox_download_uses_bounded_curl_timeouts
        test_version_relation
        test_current_repository_identity_is_required
        test_vpsbox_same_is_noop
        test_vpsbox_older_is_noop
        test_vpsbox_newer_updates_once
        test_vpsbox_backup_copy_failure_preserves_existing_previous
        test_vpsbox_backup_publish_failure_preserves_existing_previous
        test_vpsbox_watchdog_start_failure_preserves_current
        test_vpsbox_update_rejects_unsafe_previous_target
        test_vpsbox_never_fetches_old_owner_url
        test_primary_url_failure_preserves_current
        test_vpsbox_invalid_download_preserves_current
        test_vpsbox_duplicate_version_declaration_preserves_current
        test_vpsbox_wrong_project_preserves_current
        test_vpsbox_reexec_failure_restores_previous
        test_real_reexec_failure_returns_without_option_or_env_leaks
        test_vpsbox_reexec_failure_restores_before_ready
        test_vpsbox_alias_failure_restores_previous_without_reexec
        test_pending_update_startup_failure_restores_previous
        test_top_level_startup_failure_restores_previous
        test_pending_update_confirmation_prevents_rollback
        test_update_watchdog_late_ready_cannot_cancel_rollback
        test_update_watchdog_handoff_resets_startup_timer
        test_stale_previous_without_handshake_is_ignored
        test_pending_update_rejects_unexpected_backup_path
        test_singbox_version_noop_guards
        test_singbox_lower_version_updates
        test_singbox_update_continues_without_rollback_package
        test_singbox_update_without_package_rolls_back_binary_and_service
        test_pending_singbox_update_without_package_recovers_on_startup
        test_interrupted_singbox_cleanup_validates_current_binary
        test_singbox_commit_removes_pending_then_syncs_before_cleanup
        test_singbox_redhat_release_arch_mapping
    )

    for name in "${required[@]}"; do
        require_function "$name"
    done
    run_registered_test_suite \
        "${BASH_SOURCE[0]}" "update mock tests" "${tests[@]}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
