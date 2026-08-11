#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=tests/test_helper.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

# shellcheck source=../vpsbox.sh
source "$REPO_DIR/vpsbox.sh"

test_cleanup() {
    rm -rf -- "$TEST_TMP"
}
trap test_cleanup EXIT

chown() { :; }

reset_change_store() {
    local name="$1"

    VPSBOX_STATE_DIR="$TEST_TMP/$name/state"
    CHANGE_MANIFEST="$VPSBOX_STATE_DIR/changes.env"
    CHANGE_BACKUP_DIR="$VPSBOX_STATE_DIR/backups"
    mkdir -p "$CHANGE_BACKUP_DIR"
    : > "$CHANGE_MANIFEST"
}

test_manifest_failure_preserves_existing_file() {
    reset_change_store manifest
    printf 'EXISTING=keep\n' > "$CHANGE_MANIFEST"
    awk() { return 42; }

    if manifest_set NEW value; then
        fail "awk 失败时 manifest_set 不应成功"
    fi
    assert_file_contains "$CHANGE_MANIFEST" '^EXISTING=keep$'
    assert_file_not_contains "$CHANGE_MANIFEST" '^NEW='
}

test_manifest_round_trips_ssh_port_csv() {
    reset_change_store manifest-port-csv

    manifest_set SSH_PORTS "22,2222"

    assert_eq "22,2222" "$(manifest_value SSH_PORTS)" \
        "变更清单应安全保存规范化的 SSH 多端口 CSV"
}

test_clear_change_tracking_reports_partial_failure() {
    local log="$TEST_TMP/clear-tracking.log"

    reset_change_store clear-tracking
    : > "$CHANGE_BACKUP_DIR/TEST"
    manifest_remove() {
        printf '%s\n' "$1" >> "$log"
        [ "$1" != "BACKUP_TEST" ]
    }

    if clear_change_tracking TEST; then
        fail "任一清理步骤失败时 clear_change_tracking 不应报告成功"
    fi
    assert_file_contains "$log" '^BACKUP_TEST$'
    assert_file_contains "$log" '^APPLIED_TEST$'
    [ ! -e "$CHANGE_BACKUP_DIR/TEST" ] || fail "可清理的备份文件仍应删除"
}

test_restore_replaces_target_symlink() {
    local target victim

    require_real_symlink file || return "$?"
    reset_change_store symlink
    target="$TEST_TMP/symlink/target"
    victim="$TEST_TMP/symlink/victim"
    printf 'original\n' > "$target"
    backup_change_file_once TEST_FILE "$target"
    printf 'victim\n' > "$victim"
    rm -f "$target"
    ln -s "$victim" "$target"

    restore_change_file TEST_FILE "$target"
    [ -f "$target" ] && [ ! -L "$target" ] || fail "恢复后目标应为普通文件"
    assert_file_contains "$target" '^original$'
    assert_file_contains "$victim" '^victim$' "不得覆盖符号链接指向的文件"
}

test_atomic_snapshot_restore_replaces_target_symlink() {
    local source target victim

    require_real_symlink file || return "$?"
    source="$TEST_TMP/atomic-restore/source"
    target="$TEST_TMP/atomic-restore/target"
    victim="$TEST_TMP/atomic-restore/victim"
    mkdir -p "$(dirname "$source")"
    printf 'snapshot\n' > "$source"
    printf 'victim\n' > "$victim"
    ln -s "$victim" "$target"

    restore_file_atomically_from_snapshot "$source" "$target"

    [ -f "$target" ] && [ ! -L "$target" ] ||
        fail "原子恢复后目标应为普通文件"
    assert_file_contains "$target" '^snapshot$'
    assert_file_contains "$victim" '^victim$' "不得写入原符号链接指向的文件"
}

test_atomic_snapshot_restore_rejects_directory_symlink() {
    local source target victim

    require_real_symlink directory || return "$?"
    source="$TEST_TMP/atomic-restore-dir/source"
    target="$TEST_TMP/atomic-restore-dir/target"
    victim="$TEST_TMP/atomic-restore-dir/victim"
    mkdir -p "$(dirname "$source")" "$victim"
    printf 'snapshot\n' > "$source"
    ln -s "$victim" "$target"

    if restore_file_atomically_from_snapshot "$source" "$target"; then
        fail "指向目录的目标符号链接不得被当作恢复目录"
    fi
    [ -L "$target" ] || fail "拒绝恢复后应保留原目标符号链接"
    [ -z "$(find "$victim" -mindepth 1 -maxdepth 1 -print -quit)" ] ||
        fail "不得向符号链接指向的目录写入任何文件"
}

test_atomic_snapshot_restore_replaces_dangling_symlink() {
    local source target missing

    require_real_symlink file || return "$?"
    source="$TEST_TMP/atomic-restore-dangling/source"
    target="$TEST_TMP/atomic-restore-dangling/target"
    missing="$TEST_TMP/atomic-restore-dangling/missing"
    mkdir -p "$(dirname "$source")"
    printf 'snapshot\n' > "$source"
    ln -s "$missing" "$target"

    restore_file_atomically_from_snapshot "$source" "$target"

    [ -f "$target" ] && [ ! -L "$target" ] ||
        fail "原子恢复应安全替换悬空符号链接"
    assert_file_contains "$target" '^snapshot$'
    [ ! -e "$missing" ] || fail "不得创建悬空链接原本指向的文件"
}

test_backup_rejects_dangling_symlink_without_absent_record() {
    local target missing

    require_real_symlink file || return "$?"
    reset_change_store backup-dangling-symlink
    target="$TEST_TMP/backup-dangling-symlink/target"
    missing="$TEST_TMP/backup-dangling-symlink/missing"
    ln -s "$missing" "$target"

    if backup_change_file_once TEST_FILE "$target" >/dev/null 2>&1; then
        fail "悬空符号链接不得被记录为不存在"
    fi
    [ -L "$target" ] || fail "拒绝备份后必须保留原悬空符号链接"
    assert_file_not_contains "$CHANGE_MANIFEST" '^BACKUP_TEST_FILE='
}

test_backup_rejects_untracked_destination_symlink() {
    local target victim backup

    require_real_symlink file || return "$?"
    reset_change_store backup-destination-symlink
    target="$TEST_TMP/backup-destination-symlink/target"
    victim="$TEST_TMP/backup-destination-symlink/victim"
    backup="$CHANGE_BACKUP_DIR/TEST_FILE"
    printf 'source\n' > "$target"
    printf 'victim\n' > "$victim"
    ln -s "$victim" "$backup"

    if backup_change_file_once TEST_FILE "$target" >/dev/null 2>&1; then
        fail "没有清单记录的备份符号链接不得被覆盖"
    fi
    [ -L "$backup" ] || fail "拒绝备份后应保留异常备份链接供人工检查"
    assert_file_contains "$victim" '^victim$' "不得覆盖备份链接指向的外部文件"
    assert_file_not_contains "$CHANGE_MANIFEST" '^BACKUP_TEST_FILE='
}

test_orphan_cleanup_rejects_symlinked_backup_directory() {
    local victim

    require_real_symlink directory || return "$?"
    reset_change_store orphan-backup-directory
    victim="$TEST_TMP/orphan-backup-directory/victim"
    rm -rf -- "$CHANGE_BACKUP_DIR"
    mkdir -p "$victim"
    printf 'keep\n' > "$victim/ORPHAN"
    ln -s "$victim" "$CHANGE_BACKUP_DIR"

    if cleanup_orphaned_change_backups >/dev/null 2>&1; then
        fail "孤儿备份清理不得跟随备份目录符号链接"
    fi
    assert_file_contains "$victim/ORPHAN" '^keep$' "不得删除链接目录中的外部文件"
}

test_orphan_cleanup_preserves_backups_when_manifest_is_damaged() {
    local backup

    reset_change_store orphan-damaged-manifest
    backup="$CHANGE_BACKUP_DIR/ORPHAN"
    printf 'keep\n' > "$backup"
    touch -t 202001010000 "$backup"
    printf 'BROKEN MANIFEST LINE\n' > "$CHANGE_MANIFEST"

    if cleanup_orphaned_change_backups >/dev/null 2>&1; then
        fail "变更清单损坏时孤儿备份清理不得报告成功"
    fi
    assert_file_contains "$backup" '^keep$' "清单损坏时必须保留可能仍被引用的恢复备份"
}

test_orphan_cleanup_removes_only_unreferenced_old_backup() {
    local orphan referenced

    reset_change_store orphan-unreferenced
    orphan="$CHANGE_BACKUP_DIR/ORPHAN"
    referenced="$CHANGE_BACKUP_DIR/REFERENCED"
    printf 'remove\n' > "$orphan"
    printf 'keep\n' > "$referenced"
    touch -t 202001010000 "$orphan" "$referenced"
    manifest_set BACKUP_REFERENCED file

    cleanup_orphaned_change_backups >/dev/null

    [ ! -e "$orphan" ] || fail "有效清单中确实没有引用的过期备份应被清理"
    assert_file_contains "$referenced" '^keep$' "有效清单引用的恢复备份不得被清理"
}

test_ntp_rejects_dangling_config_before_tracking_or_install() {
    (
        local base="$TEST_TMP/ntp-dangling-config"
        local missing="$base/missing-chrony.conf"
        local package_calls=0

        require_real_symlink file || return "$?"
        reset_change_store ntp-dangling-config
        mkdir -p "$base"
        ln -s "$missing" "$base/chrony.conf"
        CHRONY_SOURCE_FILE="$base/vpsbox.sources"
        detect_os() { OS=debian; }
        is_systemd() { return 0; }
        chrony_service_name() { printf '%s\n' chrony; }
        chrony_conf_path() { printf '%s\n' "$base/chrony.conf"; }
        ntp_package_installed() { return 1; }
        systemd_unit_exists() { return 1; }
        apt_get_bounded() { package_calls=$((package_calls + 1)); }

        if enable_ntp_sync >/dev/null 2>&1; then
            fail "chrony 配置是悬空链接时必须拒绝修改"
        fi
        assert_eq 0 "$package_calls" \
            "拒绝不安全配置目标后不得安装软件包"
        [ -L "$base/chrony.conf" ] ||
            fail "拒绝 NTP 修改后必须保留原悬空符号链接"
        assert_file_not_contains "$CHANGE_MANIFEST" 'NTP_' \
            "修改前拒绝时不得留下 NTP 恢复记录"
    )
}

test_atomic_snapshot_restore_move_failure_preserves_target() {
    (
        local source target

        source="$TEST_TMP/atomic-restore-move-failure/source"
        target="$TEST_TMP/atomic-restore-move-failure/target"
        mkdir -p "$(dirname "$source")"
        printf 'snapshot\n' > "$source"
        printf 'current\n' > "$target"
        mv() { return 1; }

        if restore_file_atomically_from_snapshot "$source" "$target"; then
            fail "最终替换失败时原子恢复不得报告成功"
        fi
        assert_file_contains "$target" '^current$' "最终替换失败时应保留原目标文件"
        [ -z "$(find "$(dirname "$target")" -maxdepth 1 -name '.vpsbox-restore.*' -print -quit)" ] ||
            fail "最终替换失败后应清理临时恢复文件"
    )
}

test_debian_update_stops_after_first_failure() {
    local log="$TEST_TMP/debian-update.log"

    detect_os() { OS=debian; }
    apt_get_bounded() {
        printf '%s\n' "$*" >> "$log"
        return 23
    }
    reboot_required_state() { printf '不需要\n'; }

    if update_system_packages <<< "y" >/dev/null 2>&1; then
        fail "apt update 失败时系统更新不应成功"
    fi
    assert_eq 1 "$(wc -l < "$log" | tr -d ' ')" "失败后不得继续 upgrade/autoremove"
    assert_file_contains "$log" ' update$'
}

test_debian_update_uses_upgrade_timeout() {
    local log="$TEST_TMP/debian-update-success.log"

    detect_os() { OS=debian; }
    apt_get_bounded() { printf '%s\n' "$*" >> "$log"; }
    reboot_required_state() { printf '不需要\n'; }

    update_system_packages <<< "y" >/dev/null
    assert_file_contains "$log" "^${PACKAGE_UPDATE_TIMEOUT} update$"
    assert_file_contains "$log" "^${SYSTEM_UPGRADE_TIMEOUT} upgrade -y$"
    assert_file_contains "$log" "^${SYSTEM_UPGRADE_TIMEOUT} autoremove -y$"
    assert_eq 3 "$(wc -l < "$log" | tr -d ' ')" "Debian 更新应依次执行三个有界步骤"
    [ "$SYSTEM_UPGRADE_TIMEOUT" -ge 3600 ] ||
        fail "完整系统升级的上限不应沿用短安装超时"
}

test_debian_upgrade_failure_skips_autoremove() {
    local log="$TEST_TMP/debian-upgrade-failure.log"

    detect_os() { OS=debian; }
    apt_get_bounded() {
        printf '%s\n' "$*" >> "$log"
        [[ "$*" != *" upgrade -y" ]]
    }
    reboot_required_state() { printf '不需要\n'; }

    if update_system_packages <<< "y" >/dev/null 2>&1; then
        fail "apt upgrade 失败时系统更新不应成功"
    fi
    assert_eq 2 "$(wc -l < "$log" | tr -d ' ')" "upgrade 失败后不得继续 autoremove"
    assert_file_not_contains "$log" 'autoremove'
}

test_alpine_update_uses_bounded_steps() {
    local log="$TEST_TMP/alpine-update.log"

    detect_os() { OS=alpine; }
    apk_bounded() { printf '%s\n' "$*" >> "$log"; }
    reboot_required_state() { printf '不需要\n'; }

    update_system_packages <<< "y" >/dev/null
    assert_file_contains "$log" "^${PACKAGE_UPDATE_TIMEOUT} update$"
    assert_file_contains "$log" "^${SYSTEM_UPGRADE_TIMEOUT} upgrade$"
    assert_eq 2 "$(wc -l < "$log" | tr -d ' ')" "Alpine 应只执行 update 和 upgrade"
}

test_ntp_package_rollback_restores_timesyncd() {
    local log="$TEST_TMP/ntp-packages.log"
    local chrony_installed=1 timesyncd_installed=0

    # Read by the sourced package-restore helper.
    # shellcheck disable=SC2034
    OS=debian
    ntp_package_installed() {
        case "$1" in
            chrony) [ "$chrony_installed" -eq 1 ] ;;
            systemd-timesyncd) [ "$timesyncd_installed" -eq 1 ] ;;
            *) return 1 ;;
        esac
    }
    apt_get_bounded() {
        printf '%s\n' "$*" >> "$log"
        case "$*" in
            *"purge -y chrony") chrony_installed=0 ;;
            *"install -y systemd-timesyncd") timesyncd_installed=1 ;;
        esac
    }

    restore_ntp_packages_to_state absent installed
    assert_eq 0 "$chrony_installed" "应移除本次新安装的 chrony"
    assert_eq 1 "$timesyncd_installed" "应重新安装原有 systemd-timesyncd"
    assert_file_contains "$log" 'purge -y chrony$'
    assert_file_contains "$log" 'install -y systemd-timesyncd$'
}

test_chrony_source_layout_detection() {
    (
        local dir="$TEST_TMP/chrony-layout" test_conf
        mkdir -p "$dir/sources.d"
        test_conf="$dir/chrony.conf"
        CHRONY_SOURCE_FILE="$dir/sources.d/vpsbox.sources"
        chrony_conf_path() { printf '%s\n' "$test_conf"; }

        printf 'sourcedir /etc/chrony/sources.d\n' > "$test_conf"
        chrony_expected_sources > "$CHRONY_SOURCE_FILE"
        chrony_sources_are_current || fail "独立 sources.d 配置应识别为当前状态"

        printf 'sourcedir /etc/chrony/sources.d/ # trailing slash\n' > "$test_conf"
        chrony_sources_are_current || fail "带尾部斜杠的 sources.d 配置应识别为当前状态"
        printf 'sourcedir /etc/chrony/sources.d//\n' > "$test_conf"
        if chrony_main_uses_source_dir "$test_conf"; then
            fail "双尾部斜杠不得被识别为规范 sources.d 路径"
        fi
        printf 'sourcedir /etc/chrony/sources.d/extra\n' > "$test_conf"
        if chrony_main_uses_source_dir "$test_conf"; then
            fail "sources.d 子路径不得被识别为规范目录"
        fi

        rm -f "$CHRONY_SOURCE_FILE"
        printf 'driftfile /var/lib/chrony/drift\n\n%s\n' "$NTP_SOURCES_BEGIN" > "$test_conf"
        chrony_expected_sources >> "$test_conf"
        printf '%s\n' "$NTP_SOURCES_END" >> "$test_conf"
        chrony_sources_are_current || fail "主配置中的规范 vpsbox 区块应识别为当前状态"

        printf 'pool unexpected.example iburst\n' >> "$test_conf"
        chrony_sources_are_current || fail "区块外的用户配置不应导致重复改写"
    )
}

test_chrony_vpsbox_marker_validation() {
    (
        local conf="$TEST_TMP/chrony-marker-validation.conf"
        local mode

        for mode in absent valid orphan-begin orphan-end duplicate reversed; do
            case "$mode" in
                absent)
                    printf '%s\n' 'driftfile /var/lib/chrony/drift' > "$conf"
                    ;;
                valid)
                    printf '%s\n' "$NTP_SOURCES_BEGIN" 'pool example.test iburst' \
                        "$NTP_SOURCES_END" > "$conf"
                    ;;
                orphan-begin)
                    printf '%s\n' "$NTP_SOURCES_BEGIN" > "$conf"
                    ;;
                orphan-end)
                    printf '%s\n' "$NTP_SOURCES_END" > "$conf"
                    ;;
                duplicate)
                    printf '%s\n' "$NTP_SOURCES_BEGIN" "$NTP_SOURCES_BEGIN" \
                        "$NTP_SOURCES_END" > "$conf"
                    ;;
                reversed)
                    printf '%s\n' "$NTP_SOURCES_END" "$NTP_SOURCES_BEGIN" > "$conf"
                    ;;
            esac

            if [ "$mode" = absent ] || [ "$mode" = valid ]; then
                chrony_vpsbox_markers_valid "$conf" ||
                    fail "NTP 标记的 $mode 布局应被接受"
            elif chrony_vpsbox_markers_valid "$conf"; then
                fail "NTP 标记的 $mode 布局必须被拒绝"
            fi
        done
    )
}

test_chrony_sourcedir_inside_managed_block_is_not_external() {
    (
        local conf="$TEST_TMP/chrony-sourcedir-inside-block.conf"

        printf '%s\n' "$NTP_SOURCES_BEGIN" \
            'sourcedir /etc/chrony/sources.d/' "$NTP_SOURCES_END" > "$conf"

        if chrony_main_uses_source_dir "$conf"; then
            fail "旧管理块内的 sourcedir 不得被识别为用户的外部 sourcedir"
        fi
    )
}

test_installed_chrony_config_drift_skips_package_manager() {
    (
        local case_dir="$TEST_TMP/ntp-installed-drift"
        local log="$case_dir/events.log"

        mkdir -p "$case_dir"
        : > "$log"
        CHRONY_SOURCE_FILE="$case_dir/vpsbox.sources"
        printf '%s\n' 'driftfile /var/lib/chrony/drift' > "$case_dir/chrony.conf"
        detect_os() { OS=debian; }
        is_systemd() { return 0; }
        chrony_service_name() { printf '%s\n' chrony; }
        chrony_conf_path() { printf '%s\n' "$case_dir/chrony.conf"; }
        ntp_package_installed() { [ "$1" = chrony ]; }
        systemd_unit_exists() { [ "$1" = chrony.service ]; }
        chrony_sources_are_current() { return 1; }
        systemctl() {
            case "$*" in
                'is-active --quiet chrony'|'is-enabled --quiet chrony') return 0 ;;
                'stop chrony'|'enable --now chrony') return 0 ;;
                *) return 1 ;;
            esac
        }
        backup_change_file_once() { return 0; }
        manifest_set_once() { return 0; }
        mark_change_applied() { return 0; }
        manifest_value() { return 1; }
        write_chrony_sources() { printf '%s\n' write >> "$log"; }
        apt_get_bounded() { forbid "已安装 chrony 的配置漂移不得调用 apt"; }
        dnf_bounded() { forbid "已安装 chrony 的配置漂移不得调用 dnf"; }
        yum_bounded() { forbid "已安装 chrony 的配置漂移不得调用 yum"; }
        show_ntp_runtime_details() { :; }
        sleep() { :; }

        forbid_init
        enable_ntp_sync >/dev/null

        assert_file_contains "$log" '^write$' "配置漂移仍应进入配置修复路径"
        assert_no_forbidden "已安装 chrony 的配置漂移路径调用了包管理器"
    )
}

test_enable_ntp_healthy_is_noop() {
    (
        local log="$TEST_TMP/ntp-healthy.log"
        : > "$log"
        detect_os() { :; }
        is_systemd() { return 0; }
        chrony_service_name() { printf 'chrony\n'; }
        chrony_conf_path() { printf '/unused/chrony.conf\n'; }
        ntp_package_installed() { [ "$1" = "chrony" ]; }
        systemd_unit_exists() { [ "$1" = "chrony.service" ]; }
        chrony_sources_are_current() { return 0; }
        ntp_service_state_is_healthy() { return 0; }
        show_ntp_runtime_details() { printf '%s\n' details >> "$log"; }
        backup_change_file_once() { printf '%s\n' backup >> "$log"; }
        apt_get_bounded() { printf '%s\n' package >> "$log"; }
        repair_ntp_service_state() { printf '%s\n' repair >> "$log"; }

        enable_ntp_sync >/dev/null
        assert_eq details "$(cat "$log")" \
            "健康但尚未同步时只能展示状态，不得安装、备份或修复"
    )
}

test_enable_ntp_rejects_incomplete_existing_metadata_before_backup() {
    (
        forbid_init
        detect_os() {
            # shellcheck disable=SC2034 # 被测 NTP 入口动态读取。
            OS=debian
        }
        is_systemd() { return 0; }
        chrony_service_name() { printf '%s\n' chrony; }
        chrony_conf_path() { printf '%s\n' /unused/chrony.conf; }
        ntp_package_installed() { return 1; }
        systemd_unit_exists() { return 1; }
        manifest_value() {
            case "$1" in
                APPLIED_NTP_CONF) printf '%s\n' 1 ;;
                BACKUP_NTP_CONF) return 1 ;;
                BACKUP_NTP_SOURCES) printf '%s\n' absent ;;
                NTP_CHRONY_PACKAGE|NTP_TIMESYNCD_PACKAGE) printf '%s\n' absent ;;
                NTP_CHRONY_UNIT|NTP_TIMESYNCD_UNIT) printf '%s\n' absent ;;
                NTP_CHRONY_ENABLED|NTP_TIMESYNCD_ENABLED) printf '%s\n' disabled ;;
                NTP_CHRONY_ACTIVE|NTP_TIMESYNCD_ACTIVE) printf '%s\n' inactive ;;
                *) return 1 ;;
            esac
        }
        backup_change_file_once() {
            forbid "已有 NTP 恢复记录不完整时不得改写恢复基线"
        }

        if enable_ntp_sync >/dev/null 2>&1; then
            fail "已有 NTP 恢复记录不完整时重复配置必须失败"
        fi
        assert_no_forbidden "NTP 元数据校验必须发生在备份副作用之前"
    )
}

test_ntp_unsynchronized_status_is_nonfatal() {
    (
        local output="$TEST_TMP/ntp-unsynchronized.out"
        systemctl() {
            case "$*" in
                'is-enabled chrony') printf 'enabled\n' ;;
                'is-active chrony') printf 'active\n' ;;
                *) return 1 ;;
            esac
        }
        chronyc() {
            case "$1" in
                sources) printf 'time.cloudflare.com\n' ;;
                tracking) printf 'Leap status     : Not synchronised\n' ;;
                *) return 1 ;;
            esac
        }
        timedatectl() { return 0; }

        show_ntp_runtime_details chrony > "$output"
        assert_file_contains "$output" '首次同步可能需要几分钟'
        assert_file_contains "$output" '当前配置不会重复改写'
    )
}

test_ntp_service_drift_uses_light_repair() {
    (
        local log="$TEST_TMP/ntp-service-repair.log"
        local mock_chrony_enabled=0 mock_chrony_active=0
        local mock_timesyncd_enabled=1 mock_timesyncd_active=1
        : > "$log"
        systemd_unit_exists() { [ "$1" = "systemd-timesyncd.service" ]; }
        systemctl() {
            case "$*" in
                'is-enabled --quiet chrony') [ "$mock_chrony_enabled" -eq 1 ] ;;
                'is-active --quiet chrony') [ "$mock_chrony_active" -eq 1 ] ;;
                'is-enabled --quiet systemd-timesyncd') [ "$mock_timesyncd_enabled" -eq 1 ] ;;
                'is-active --quiet systemd-timesyncd') [ "$mock_timesyncd_active" -eq 1 ] ;;
                'enable chrony')
                    assert_eq 1 "${ACTIVE_NTP_SERVICE_ROLLBACK:-0}" \
                        "NTP 轻量修复必须在首次服务修改前登记回滚"
                    mock_chrony_enabled=1
                    printf '%s\n' 'enable chrony' >> "$log"
                    ;;
                'start chrony') mock_chrony_active=1; printf '%s\n' 'start chrony' >> "$log" ;;
                'disable --now systemd-timesyncd')
                    mock_timesyncd_enabled=0
                    mock_timesyncd_active=0
                    printf '%s\n' 'disable timesyncd' >> "$log"
                    ;;
                *) return 1 ;;
            esac
        }

        repair_ntp_service_state chrony >/dev/null
        assert_file_contains "$log" '^enable chrony$'
        assert_file_contains "$log" '^start chrony$'
        assert_file_contains "$log" '^disable timesyncd$'
        assert_eq 0 "${ACTIVE_NTP_SERVICE_ROLLBACK:-0}" \
            "NTP 轻量修复成功后必须清除活动回滚"
    )
}

test_ntp_light_repair_reports_restore_outcome() {
    local mode

    for mode in restored incomplete masked; do
        (
            local output="$TEST_TMP/ntp-light-repair-$mode.out"
            local mock_chrony_enabled_state=disabled
            local mock_chrony_active_state=inactive
            local mock_timesyncd_enabled_state=enabled
            local mock_timesyncd_active_state=active

            [ "$mode" != masked ] || mock_chrony_enabled_state=masked

            systemd_unit_exists() { return 0; }
            systemctl() {
                case "$*" in
                    'is-enabled --quiet chrony')
                        [ "$mock_chrony_enabled_state" = enabled ]
                        ;;
                    'is-active --quiet chrony')
                        [ "$mock_chrony_active_state" = active ]
                        ;;
                    'is-enabled --quiet systemd-timesyncd')
                        [ "$mock_timesyncd_enabled_state" = enabled ]
                        ;;
                    'is-active --quiet systemd-timesyncd')
                        [ "$mock_timesyncd_active_state" = active ]
                        ;;
                    'enable chrony')
                        [ "$mock_chrony_enabled_state" != masked ] || return 23
                        mock_chrony_enabled_state=enabled
                        ;;
                    'start chrony') mock_chrony_active_state=active ;;
                    'disable --now systemd-timesyncd')
                        mock_timesyncd_enabled_state=disabled
                        mock_timesyncd_active_state=inactive
                        return 23
                        ;;
                    'disable chrony')
                        [ "$mock_chrony_enabled_state" = masked ] ||
                            mock_chrony_enabled_state=disabled
                        ;;
                    'stop chrony')
                        [ "$mode" = incomplete ] ||
                            mock_chrony_active_state=inactive
                        ;;
                    'enable systemd-timesyncd')
                        mock_timesyncd_enabled_state=enabled
                        ;;
                    'start systemd-timesyncd')
                        mock_timesyncd_active_state=active
                        ;;
                    'is-enabled chrony')
                        printf '%s\n' "$mock_chrony_enabled_state"
                        [ "$mock_chrony_enabled_state" = enabled ]
                        ;;
                    'is-active chrony')
                        printf '%s\n' "$mock_chrony_active_state"
                        [ "$mock_chrony_active_state" = active ]
                        ;;
                    'is-enabled systemd-timesyncd')
                        printf '%s\n' "$mock_timesyncd_enabled_state"
                        [ "$mock_timesyncd_enabled_state" = enabled ]
                        ;;
                    'is-active systemd-timesyncd')
                        printf '%s\n' "$mock_timesyncd_active_state"
                        [ "$mock_timesyncd_active_state" = active ]
                        ;;
                    *) return 1 ;;
                esac
            }

            if repair_ntp_service_state chrony > "$output" 2>&1; then
                fail "NTP 轻量修复失败后不得报告成功"
            fi
            if [ "$mode" = restored ]; then
                assert_eq disabled "$mock_chrony_enabled_state"
                assert_eq inactive "$mock_chrony_active_state"
                assert_eq enabled "$mock_timesyncd_enabled_state"
                assert_eq active "$mock_timesyncd_active_state"
                assert_file_contains "$output" '已恢复修改前状态'
                assert_file_not_contains "$output" '未能完整恢复'
            elif [ "$mode" = incomplete ]; then
                assert_eq enabled "$mock_timesyncd_enabled_state"
                assert_eq active "$mock_timesyncd_active_state"
                assert_file_contains "$output" '未能完整恢复'
                assert_file_not_contains "$output" '已恢复修改前状态'
            else
                assert_eq masked "$mock_chrony_enabled_state"
                assert_eq inactive "$mock_chrony_active_state"
                assert_eq enabled "$mock_timesyncd_enabled_state"
                assert_eq active "$mock_timesyncd_active_state"
                assert_file_contains "$output" '已恢复修改前状态'
                assert_file_not_contains "$output" '未能完整恢复'
            fi
        )
    done
}

test_ntp_light_repair_is_covered_by_runtime_cleanup() {
    (
        local observed_chrony_enabled=enabled observed_chrony_active=active
        local observed_timesyncd_enabled=disabled observed_timesyncd_active=inactive

        # shellcheck disable=SC2034 # 被测 NTP 事务入口通过动态作用域读取。
        ACTIVE_NTP_SNAPSHOT=""
        # shellcheck disable=SC2034 # 被测 NTP 事务入口通过动态作用域读取。
        ACTIVE_NTP_ROLLBACK_ARGS=()
        ACTIVE_NTP_SERVICE_ROLLBACK=0
        ACTIVE_NTP_SERVICE_ROLLBACK_ARGS=()
        systemd_unit_exists() {
            case "$1" in
                chrony.service|systemd-timesyncd.service) return 0 ;;
                *) return 1 ;;
            esac
        }
        systemctl() {
            case "$*" in
                'enable chrony') observed_chrony_enabled=enabled ;;
                'disable chrony') observed_chrony_enabled=disabled ;;
                'start chrony') observed_chrony_active=active ;;
                'stop chrony') observed_chrony_active=inactive ;;
                'enable systemd-timesyncd') observed_timesyncd_enabled=enabled ;;
                'disable systemd-timesyncd') observed_timesyncd_enabled=disabled ;;
                'start systemd-timesyncd') observed_timesyncd_active=active ;;
                'stop systemd-timesyncd') observed_timesyncd_active=inactive ;;
                'is-enabled chrony') printf '%s\n' "$observed_chrony_enabled" ;;
                'is-active chrony') printf '%s\n' "$observed_chrony_active" ;;
                'is-enabled systemd-timesyncd') printf '%s\n' "$observed_timesyncd_enabled" ;;
                'is-active systemd-timesyncd') printf '%s\n' "$observed_timesyncd_active" ;;
                *) return 1 ;;
            esac
        }
        cleanup_vpsbox_lock() { return 0; }

        arm_ntp_service_runtime_rollback chrony disabled inactive \
            present enabled active
        cleanup_vpsbox_runtime

        assert_eq disabled "$observed_chrony_enabled"
        assert_eq inactive "$observed_chrony_active"
        assert_eq enabled "$observed_timesyncd_enabled"
        assert_eq active "$observed_timesyncd_active"
        assert_eq 0 "${ACTIVE_NTP_SERVICE_ROLLBACK:-0}"
        assert_eq 0 "${#ACTIVE_NTP_SERVICE_ROLLBACK_ARGS[@]}"
    )
}

test_enable_ntp_failure_stages_enter_runtime_rollback() {
    local stage

    for stage in package sources enable active timesyncd; do
        (
            local case_dir="$TEST_TMP/ntp-entry-$stage"
            local log="$case_dir/events.log" chrony_active=0

            mkdir -p "$case_dir"
            : > "$log"
            CHRONY_SOURCE_FILE="$case_dir/vpsbox.sources"
            printf '%s\n' old-conf > "$case_dir/chrony.conf"
            printf '%s\n' old-sources > "$CHRONY_SOURCE_FILE"

            detect_os() {
                # shellcheck disable=SC2034 # 被测 NTP 入口动态读取。
                OS=debian
            }
            is_systemd() { return 0; }
            chrony_service_name() { printf '%s\n' chrony; }
            chrony_conf_path() { printf '%s\n' "$case_dir/chrony.conf"; }
            ntp_package_installed() { return 1; }
            systemd_unit_exists() { [ "$1" = systemd-timesyncd.service ]; }
            backup_change_file_once() { return 0; }
            manifest_value() {
                case "$1" in
                    APPLIED_NTP_CONF) printf '%s\n' 1 ;;
                    BACKUP_NTP_CONF|BACKUP_NTP_SOURCES) printf '%s\n' absent ;;
                    NTP_CHRONY_PACKAGE|NTP_TIMESYNCD_PACKAGE) printf '%s\n' absent ;;
                    NTP_CHRONY_UNIT|NTP_TIMESYNCD_UNIT) printf '%s\n' absent ;;
                    NTP_CHRONY_ENABLED|NTP_TIMESYNCD_ENABLED) printf '%s\n' disabled ;;
                    NTP_CHRONY_ACTIVE|NTP_TIMESYNCD_ACTIVE) printf '%s\n' inactive ;;
                    *) return 1 ;;
                esac
            }
            apt_get_bounded() {
                if [ "$stage" = package ] && [[ " $* " == *" install -y chrony "* ]]; then
                    return 23
                fi
                return 0
            }
            write_chrony_sources() {
                printf '%s\n' sources >> "$log"
                [ "$stage" != sources ]
            }
            systemctl() {
                printf 'systemctl:%s\n' "$*" >> "$log"
                case "$*" in
                    'is-active --quiet systemd-timesyncd'|'is-enabled --quiet systemd-timesyncd') return 0 ;;
                    'stop chrony') return 0 ;;
                    'enable --now chrony')
                        [ "$stage" != enable ] || return 23
                        chrony_active=1
                        ;;
                    'is-active --quiet chrony')
                        [ "$stage" != active ] && [ "$chrony_active" -eq 1 ]
                        ;;
                    'disable --now systemd-timesyncd') [ "$stage" != timesyncd ] ;;
                    *) return 2 ;;
                esac
            }
            settle_failed_ntp_change() {
                printf 'rollback:%s\n' "$stage" >> "$log"
                rm -rf -- "$1"
            }
            show_chrony_permission_hint() { :; }
            sleep() { :; }

            if enable_ntp_sync > "$case_dir/output" 2>&1; then
                fail "NTP 的 $stage 阶段失败时入口不得报告成功"
            fi
            assert_eq 1 "$(grep -c '^rollback:' "$log")" \
                "NTP 的 $stage 阶段失败后必须进入统一运行态回滚"
            assert_file_contains "$log" "^rollback:${stage}$"
            case "$stage" in
                enable)
                    assert_file_contains "$log" '^systemctl:enable --now chrony$'
                    ;;
                active)
                    assert_file_contains "$log" '^systemctl:is-active --quiet chrony$'
                    ;;
                timesyncd)
                    assert_file_contains "$log" \
                        '^systemctl:disable --now systemd-timesyncd$'
                    ;;
            esac
        )
    done
}

test_ntp_pre_mutation_snapshot_failures_clear_new_tracking() {
    local stage

    for stage in directory conf-copy sources-copy arm; do
        (
            local case_dir="$TEST_TMP/ntp-pre-mutation-$stage"
            local conf_path="$case_dir/chrony.conf" cp_target

            mkdir -p "$case_dir"
            reset_change_store "ntp-pre-mutation-$stage"
            CHRONY_SOURCE_FILE="$case_dir/vpsbox.sources"
            printf '%s\n' old-conf > "$conf_path"
            printf '%s\n' old-sources > "$CHRONY_SOURCE_FILE"

            detect_os() { OS=debian; }
            is_systemd() { return 0; }
            chrony_service_name() { printf '%s\n' chrony; }
            chrony_conf_path() { printf '%s\n' "$conf_path"; }
            chrony_sources_are_current() { return 1; }
            ntp_package_installed() { [ "$1" = chrony ]; }
            systemd_unit_exists() { [ "$1" = chrony.service ]; }
            systemctl() {
                case "$*" in
                    'is-active --quiet chrony'|'is-enabled --quiet chrony') return 0 ;;
                    *) forbid "NTP 快照建立前不得修改服务：$*" ;;
                esac
            }
            apt_get_bounded() { forbid "NTP 快照建立前不得调用包管理器"; }
            write_chrony_sources() { forbid "NTP 快照建立前不得写配置"; }
            show_ntp_runtime_details() { forbid "NTP 快照失败后不得进入成功展示"; }
            sleep() { forbid "NTP 快照失败后不得等待服务"; }
            mktemp() {
                if [ "$stage" = directory ] && [ "${1:-}" = -d ] &&
                    [ "${2:-}" = /tmp/vpsbox-chrony.XXXXXX ]; then
                    return 41
                fi
                command mktemp "$@"
            }
            cp() {
                cp_target="${*: -1}"
                case "$cp_target" in
                    "$CHANGE_BACKUP_DIR"/NTP_*)
                        assert_eq 1 "${ACTIVE_NTP_TRACKING_CANCEL:-0}" \
                            "NTP 必须在写第一份持久恢复记录前登记退出清理" || return 44
                        ;;
                esac
                if { [ "$stage" = conf-copy ] && [[ "$cp_target" == */conf ]]; } ||
                    { [ "$stage" = sources-copy ] && [[ "$cp_target" == */sources ]]; }; then
                    return 42
                fi
                command cp "$@"
            }
            if [ "$stage" = arm ]; then
                arm_ntp_runtime_rollback() { return 43; }
            fi

            forbid_init
            if enable_ntp_sync > "$case_dir/output" 2>&1; then
                fail "NTP 的 $stage 快照阶段失败时入口不得报告成功"
            fi
            assert_file_not_contains "$CHANGE_MANIFEST" \
                '^(BACKUP_NTP_|PENDING_NTP_|APPLIED_NTP_|NTP_)' \
                "NTP 尚未修改时不得留下首次恢复记录"
            if find "$CHANGE_BACKUP_DIR" -maxdepth 1 -type f -name 'NTP_*' -print -quit |
                grep -q .; then
                fail "NTP 尚未修改时不得留下首次配置备份"
            fi
            assert_file_contains "$conf_path" '^old-conf$'
            assert_file_contains "$CHRONY_SOURCE_FILE" '^old-sources$'
            assert_eq "" "${ACTIVE_NTP_SNAPSHOT:-}" "NTP 快照失败后不得留下活动句柄"
            assert_eq 0 "${ACTIVE_NTP_TRACKING_CANCEL:-0}" \
                "NTP 快照失败后不得留下首次记录清理句柄"
            assert_no_forbidden "NTP 快照建立失败后产生了系统修改"
        )
    done
}

test_ntp_pre_mutation_tracking_is_covered_by_runtime_cleanup() {
    (
        local case_dir="$TEST_TMP/ntp-pre-mutation-cleanup"
        local conf_path="$case_dir/chrony.conf"

        mkdir -p "$case_dir"
        reset_change_store ntp-pre-mutation-cleanup
        CHRONY_SOURCE_FILE="$case_dir/vpsbox.sources"
        printf '%s\n' old-conf > "$conf_path"
        printf '%s\n' old-sources > "$CHRONY_SOURCE_FILE"

        ACTIVE_NTP_SNAPSHOT=""
        # shellcheck disable=SC2034 # 被测统一退出清理通过动态作用域读取。
        ACTIVE_NTP_ROLLBACK_ARGS=()
        ACTIVE_NTP_SERVICE_ROLLBACK=0
        ACTIVE_NTP_SERVICE_ROLLBACK_ARGS=()
        ACTIVE_NTP_TRACKING_CANCEL=1
        backup_change_file_once NTP_CONF "$conf_path"
        manifest_set NTP_CHRONY_ACTIVE active
        mark_change_applied NTP_CONF
        cleanup_vpsbox_lock() { :; }

        cleanup_vpsbox_runtime

        assert_file_not_contains "$CHANGE_MANIFEST" \
            '^(BACKUP_NTP_|PENDING_NTP_|APPLIED_NTP_|NTP_)' \
            "NTP 受控退出必须清除尚未修改系统的首次恢复记录"
        [ ! -e "$CHANGE_BACKUP_DIR/NTP_CONF" ] ||
            fail "NTP 受控退出必须清除尚未使用的首次配置备份"
        assert_eq 0 "${ACTIVE_NTP_TRACKING_CANCEL:-0}" \
            "NTP 受控退出清理成功后必须清除活动句柄"
        assert_file_contains "$conf_path" '^old-conf$'
        assert_file_contains "$CHRONY_SOURCE_FILE" '^old-sources$'
    )
}

test_cancel_unmodified_ntp_tracking_preserves_existing_baseline() {
    (
        local case_dir="$TEST_TMP/ntp-existing-baseline"
        local conf="$case_dir/chrony.conf" before_manifest before_conf before_sources

        mkdir -p "$case_dir"
        reset_change_store ntp-existing-baseline
        CHRONY_SOURCE_FILE="$case_dir/vpsbox.sources"
        printf '%s\n' original-conf > "$conf"
        printf '%s\n' original-sources > "$CHRONY_SOURCE_FILE"
        backup_change_file_once NTP_CONF "$conf"
        backup_change_file_once NTP_SOURCES "$CHRONY_SOURCE_FILE"
        manifest_set NTP_CHRONY_ACTIVE active
        manifest_set NTP_CHRONY_ENABLED enabled
        manifest_set NTP_CHRONY_PACKAGE installed
        manifest_set NTP_CHRONY_UNIT present
        manifest_set NTP_TIMESYNCD_ACTIVE inactive
        manifest_set NTP_TIMESYNCD_ENABLED disabled
        manifest_set NTP_TIMESYNCD_PACKAGE absent
        manifest_set NTP_TIMESYNCD_UNIT absent
        mark_change_applied NTP_CONF
        before_manifest="$(cksum < "$CHANGE_MANIFEST")"
        before_conf="$(cksum < "$CHANGE_BACKUP_DIR/NTP_CONF")"
        before_sources="$(cksum < "$CHANGE_BACKUP_DIR/NTP_SOURCES")"

        cancel_unmodified_ntp_tracking 1

        assert_eq "$before_manifest" "$(cksum < "$CHANGE_MANIFEST")" \
            "既有 NTP 恢复清单不得被首次失败清理"
        assert_eq "$before_conf" "$(cksum < "$CHANGE_BACKUP_DIR/NTP_CONF")"
        assert_eq "$before_sources" "$(cksum < "$CHANGE_BACKUP_DIR/NTP_SOURCES")"
    )
}

test_bbr_fq_healthy_is_noop() {
    (
        local log="$TEST_TMP/bbr-healthy.log"
        BBR_CONF="$TEST_TMP/99-vpsbox-bbr-healthy.conf"
        render_bbr_fq_config > "$BBR_CONF"
        : > "$log"
        sysctl() {
            case "$*" in
                '-n net.ipv4.tcp_congestion_control') printf 'bbr\n' ;;
                '-n net.core.default_qdisc') printf 'fq\n' ;;
                *) printf '%s\n' "$*" >> "$log" ;;
            esac
        }
        modprobe() { printf '%s\n' "$*" >> "$log"; }
        backup_change_file_once() { printf '%s\n' backup >> "$log"; }

        enable_bbr_fq >/dev/null
        assert_empty_file "$log" "健康的 BBR + fq 不得加载模块、应用 sysctl 或创建备份"
    )
}

test_bbr_fq_runtime_drift_uses_light_repair() {
    (
        local log="$TEST_TMP/bbr-repair.log"
        local cc=cubic fq=pfifo_fast
        BBR_CONF="$TEST_TMP/99-vpsbox-bbr-repair.conf"
        render_bbr_fq_config > "$BBR_CONF"
        : > "$log"
        sysctl() {
            case "$1" in
                -n)
                    [ "$2" = "net.ipv4.tcp_congestion_control" ] && printf '%s\n' "$cc" || printf '%s\n' "$fq"
                    ;;
                -p)
                    cc=bbr
                    fq=fq
                    printf '%s\n' 'sysctl-p' >> "$log"
                    ;;
                -w) return 0 ;;
                *) return 1 ;;
            esac
        }
        modprobe() { printf 'modprobe %s\n' "$1" >> "$log"; }
        backup_change_file_once() { printf '%s\n' backup >> "$log"; }
        bbr_state() { printf '%s\n' "$cc"; }
        fq_state() { printf '%s\n' "$fq"; }

        enable_bbr_fq >/dev/null
        assert_file_contains "$log" '^modprobe tcp_bbr$'
        assert_file_contains "$log" '^modprobe sch_fq$'
        assert_file_contains "$log" '^sysctl-p$'
        assert_file_not_contains "$log" '^backup$' "只修复运行参数时不得改写持久化配置"
    )
}

test_unsupported_kernel_leaves_no_phantom_pending_change() {
    (
        local changes="$TEST_TMP/bbr-phantom.out"
        local modprobe_log="$TEST_TMP/bbr-phantom.modprobe"
        reset_change_store bbr-phantom
        BBR_CONF="$TEST_TMP/bbr-phantom/99-vpsbox-bbr.conf"
        mkdir -p "$(dirname "$BBR_CONF")"
        : > "$modprobe_log"

        bbr_fq_persistent_config_is_current() { return 1; }
        sysctl() { case "$1" in -n) printf 'cubic\n' ;; *) return 1 ;; esac; }
        modprobe() {
            printf '%s\n' "$*" >> "$modprobe_log"
            return 1
        }

        if enable_bbr_fq >/dev/null 2>&1; then
            fail "内核不支持 tcp_bbr 时不得报告成功"
        fi
        assert_file_contains "$modprobe_log" '^tcp_bbr$' \
            "测试必须实际执行到内核模块加载失败路径"
        [ ! -e "$BBR_CONF" ] || fail "失败路径不得留下持久化配置"
        [ ! -e "$CHANGE_BACKUP_DIR/BBR_CONF" ] || fail "失败路径不得留下陈旧 BBR 基线"
        assert_file_not_contains "$CHANGE_MANIFEST" '^(BACKUP_BBR_CONF|PENDING_BBR_CONF|APPLIED_BBR_CONF|BBR_CC|BBR_FQ)='
        assert_eq none "$(change_restore_state BBR_CONF)" \
            "从未修改过的变更不得长期显示为待恢复"
        show_vpsbox_changes > "$changes" 2>&1 ||
            fail "无法读取 vpsbox 系统改动状态"
        assert_file_not_contains "$changes" 'BBR_CONF：未完成' \
            "查看系统改动里不得出现从未发生的改动"
    )
}

test_failed_bbr_runtime_restore_keeps_recovery_transaction() {
    (
        local output="$TEST_TMP/bbr-runtime-restore.out"
        local current_cc=cubic current_fq=fq_codel
        reset_change_store bbr-runtime-restore
        BBR_CONF="$TEST_TMP/bbr-runtime-restore/99-vpsbox-bbr.conf"
        mkdir -p "$(dirname "$BBR_CONF")"

        bbr_fq_persistent_config_is_current() { return 1; }
        modprobe() { return 0; }
        sysctl() {
            case "$1:$2" in
                -n:net.ipv4.tcp_congestion_control) printf '%s\n' "$current_cc" ;;
                -n:net.core.default_qdisc) printf '%s\n' "$current_fq" ;;
                -p:*)
                    current_cc=bbr
                    return 1
                    ;;
                -w:net.ipv4.tcp_congestion_control=cubic) return 1 ;;
                -w:net.core.default_qdisc=fq_codel) current_fq=fq_codel ;;
                *) return 1 ;;
            esac
        }

        if enable_bbr_fq > "$output" 2>&1; then
            fail "BBR 部分生效且恢复失败时不得报告成功"
        fi
        assert_eq bbr "$current_cc" "夹具必须模拟 BBR 运行参数恢复失败"
        assert_eq pending "$(change_restore_state BBR_CONF)" \
            "运行参数未完整恢复时必须保留 pending 事务"
        assert_file_contains "$CHANGE_MANIFEST" '^BACKUP_BBR_CONF=absent$'
        assert_file_contains "$CHANGE_MANIFEST" '^BBR_CC=cubic$'
        assert_file_contains "$CHANGE_MANIFEST" '^BBR_FQ=fq_codel$'
        assert_file_contains "$output" '已保留事务记录'
    )
}

setup_tcp_buffer_case() {
    local name="$1"

    TCP_TEST_DIR="$TEST_TMP/tcp-buffer-$name"
    TCP_BUFFER_CONF="$TCP_TEST_DIR/99-vpsbox-tcp-buffer.conf"
    VPSBOX_STATE_DIR="$TCP_TEST_DIR/state"
    CHANGE_MANIFEST="$VPSBOX_STATE_DIR/changes.env"
    CHANGE_BACKUP_DIR="$VPSBOX_STATE_DIR/backups"
    TCP_TEST_CORE_RMEM=212992
    TCP_TEST_CORE_WMEM=212992
    TCP_TEST_TCP_RMEM="4096 131072 6291456"
    TCP_TEST_TCP_WMEM="4096 16384 4194304"
    TCP_TEST_MODERATE=1
    TCP_TEST_WINDOW_SCALING=1
    TCP_TEST_APPLY_FAIL=0
    TCP_TEST_KEEP_RUNTIME=0
    TCP_TEST_RESTORE_FAIL_KEY=""
    TCP_TEST_SYSCTL_LOG="$TCP_TEST_DIR/sysctl.log"
    mkdir -p "$TCP_TEST_DIR"
    : > "$TCP_TEST_SYSCTL_LOG"

    sysctl() {
        local key value

        case "$1" in
            -n)
                case "$2" in
                    net.core.rmem_max) printf '%s\n' "$TCP_TEST_CORE_RMEM" ;;
                    net.core.wmem_max) printf '%s\n' "$TCP_TEST_CORE_WMEM" ;;
                    net.ipv4.tcp_rmem) printf '%s\n' "$TCP_TEST_TCP_RMEM" ;;
                    net.ipv4.tcp_wmem) printf '%s\n' "$TCP_TEST_TCP_WMEM" ;;
                    net.ipv4.tcp_moderate_rcvbuf) printf '%s\n' "$TCP_TEST_MODERATE" ;;
                    net.ipv4.tcp_window_scaling) printf '%s\n' "$TCP_TEST_WINDOW_SCALING" ;;
                    *) return 2 ;;
                esac
                ;;
            -p)
                printf 'p:%s\n' "$2" >> "$TCP_TEST_SYSCTL_LOG"
                [ "$TCP_TEST_KEEP_RUNTIME" -eq 0 ] || return 0
                TCP_TEST_CORE_RMEM="$(awk '$1 == "net.core.rmem_max" { print $3 }' "$2")"
                if [ "$TCP_TEST_APPLY_FAIL" -eq 1 ]; then
                    return 41
                fi
                TCP_TEST_CORE_WMEM="$(awk '$1 == "net.core.wmem_max" { print $3 }' "$2")"
                TCP_TEST_TCP_RMEM="$(awk '$1 == "net.ipv4.tcp_rmem" { print $3, $4, $5 }' "$2")"
                TCP_TEST_TCP_WMEM="$(awk '$1 == "net.ipv4.tcp_wmem" { print $3, $4, $5 }' "$2")"
                ;;
            -w)
                printf 'w:%s\n' "$2" >> "$TCP_TEST_SYSCTL_LOG"
                key="${2%%=*}"
                value="${2#*=}"
                [ "$key" != "$TCP_TEST_RESTORE_FAIL_KEY" ] || return 43
                case "$key" in
                    net.core.rmem_max) TCP_TEST_CORE_RMEM="$value" ;;
                    net.core.wmem_max) TCP_TEST_CORE_WMEM="$value" ;;
                    net.ipv4.tcp_rmem) TCP_TEST_TCP_RMEM="$value" ;;
                    net.ipv4.tcp_wmem) TCP_TEST_TCP_WMEM="$value" ;;
                    *) return 2 ;;
                esac
                ;;
            *) return 2 ;;
        esac
    }
}

test_tcp_buffer_tiers_preserve_defaults_and_restore_first_baseline() {
    (
        local output="$TEST_TMP/tcp-buffer-tier.out"

        setup_tcp_buffer_case tiers
        apply_tcp_buffer_tier 1 <<< "" > "$output"

        assert_file_contains "$TCP_BUFFER_CONF" '^net[.]core[.]rmem_max = 8388608$'
        assert_file_contains "$TCP_BUFFER_CONF" '^net[.]core[.]wmem_max = 8388608$'
        assert_file_contains "$TCP_BUFFER_CONF" '^net[.]ipv4[.]tcp_rmem = 4096 131072 8388608$'
        assert_file_contains "$TCP_BUFFER_CONF" '^net[.]ipv4[.]tcp_wmem = 4096 16384 8388608$'
        assert_eq "8388608 8388608 4096 131072 8388608 4096 16384 8388608" \
            "$TCP_TEST_CORE_RMEM $TCP_TEST_CORE_WMEM $TCP_TEST_TCP_RMEM $TCP_TEST_TCP_WMEM"
        assert_file_contains "$CHANGE_MANIFEST" '^BACKUP_TCP_BUFFER_CONF=absent$'
        assert_file_contains "$CHANGE_MANIFEST" '^TCP_BUFFER_RMEM_MAX=212992$'
        assert_file_contains "$CHANGE_MANIFEST" '^TCP_BUFFER_WMEM_MAX=212992$'
        assert_file_contains "$CHANGE_MANIFEST" '^TCP_BUFFER_TCP_RMEM=4096,131072,6291456$'
        assert_file_contains "$CHANGE_MANIFEST" '^TCP_BUFFER_TCP_WMEM=4096,16384,4194304$'
        assert_file_contains "$CHANGE_MANIFEST" '^APPLIED_TCP_BUFFER_CONF=1$'
        assert_file_contains "$output" '系统接收缓冲区上限：208 KiB'
        assert_file_contains "$output" '目标参数'
        assert_file_contains "$output" '当前档位：第一档'

        apply_tcp_buffer_tier 2 <<< "" >/dev/null
        assert_file_contains "$TCP_BUFFER_CONF" '^net[.]ipv4[.]tcp_rmem = 4096 131072 16777216$'
        assert_file_contains "$TCP_BUFFER_CONF" '^net[.]ipv4[.]tcp_wmem = 4096 16384 16777216$'
        assert_file_contains "$CHANGE_MANIFEST" '^TCP_BUFFER_RMEM_MAX=212992$' \
            "切换档位不得覆盖首次修改前的恢复基线"

        restore_vpsbox_system_change tcp_buffer >/dev/null
        [ ! -e "$TCP_BUFFER_CONF" ] || fail "恢复后应移除首次创建的 TCP 缓冲区配置"
        assert_eq "212992 212992 4096 131072 6291456 4096 16384 4194304" \
            "$TCP_TEST_CORE_RMEM $TCP_TEST_CORE_WMEM $TCP_TEST_TCP_RMEM $TCP_TEST_TCP_WMEM"
        assert_file_not_contains "$CHANGE_MANIFEST" \
            '^(BACKUP_TCP_BUFFER_CONF|PENDING_TCP_BUFFER_CONF|APPLIED_TCP_BUFFER_CONF|TCP_BUFFER_.*)='
    )
}

test_tcp_buffer_cancel_invalid_default_and_healthy_noop_are_read_only() {
    (
        local output="$TEST_TMP/tcp-buffer-cancel.out"

        setup_tcp_buffer_case cancel
        apply_tcp_buffer_tier 1 <<< "n" > "$output"
        assert_file_contains "$output" '已取消 TCP 缓冲区调优'
        [ ! -e "$TCP_BUFFER_CONF" ] || fail "取消时不得创建 TCP 缓冲区配置"
        [ ! -e "$CHANGE_MANIFEST" ] || fail "取消时不得创建恢复记录"
        assert_empty_file "$TCP_TEST_SYSCTL_LOG" "取消时不得修改 TCP 运行参数"
    )
    (
        local output="$TEST_TMP/tcp-buffer-invalid-default.out"

        setup_tcp_buffer_case invalid-default
        TCP_TEST_TCP_RMEM="4096 16777216 33554432"
        if apply_tcp_buffer_tier 1 > "$output" 2>&1; then
            fail "默认值高于档位上限时不得生成配置"
        fi
        assert_file_contains "$output" '当前 TCP 最小值或默认值高于所选档位上限'
        [ ! -e "$TCP_BUFFER_CONF" ] || fail "非法目标不得创建配置"
        [ ! -e "$CHANGE_MANIFEST" ] || fail "非法目标不得创建恢复记录"
    )
    (
        local output="$TEST_TMP/tcp-buffer-noop.out"
        local values='8388608 8388608 4096,131072,8388608 4096,16384,8388608'

        setup_tcp_buffer_case noop
        render_tcp_buffer_config "$values" > "$TCP_BUFFER_CONF"
        TCP_TEST_CORE_RMEM=8388608
        TCP_TEST_CORE_WMEM=8388608
        TCP_TEST_TCP_RMEM="4096 131072 8388608"
        TCP_TEST_TCP_WMEM="4096 16384 8388608"
        apply_tcp_buffer_tier 1 </dev/null > "$output"
        assert_file_contains "$output" '无需重复应用'
        assert_file_not_contains "$output" '是否应用所选 TCP 缓冲区参数'
        assert_empty_file "$TCP_TEST_SYSCTL_LOG" "健康档位不得重复应用 sysctl"
    )
}

test_pending_system_change_blocks_fast_return_paths() {
    (
        local output="$TEST_TMP/ipv6-pending-fast-return.out"

        reset_change_store ipv6-pending-fast-return
        manifest_set PENDING_IPV6_CONF 1
        global_ipv6_addresses() { forbid "IPv6 pending 应在地址检测前被拦截"; }
        forbid_init
        if disable_ipv6 > "$output" 2>&1; then
            fail "IPv6 存在未完成事务时不得按无地址路径返回成功"
        fi
        assert_file_contains "$output" '尚未处理的 IPv6 修改事务'
        assert_no_forbidden "IPv6 pending 检查顺序错误"
    )
    (
        local output="$TEST_TMP/tcp-pending-fast-return.out"

        reset_change_store tcp-pending-fast-return
        manifest_set PENDING_TCP_BUFFER_CONF 1
        tcp_buffer_tier_max() { printf '%s\n' 8388608; }
        tcp_buffer_tier_description() { printf '%s\n' 第一档; }
        tcp_buffer_runtime_values() { forbid "TCP pending 应在读取运行参数前被拦截"; }
        forbid_init
        if apply_tcp_buffer_tier 1 > "$output" 2>&1; then
            fail "TCP 缓冲区存在未完成事务时不得按健康档位返回成功"
        fi
        assert_file_contains "$output" '尚未处理的 TCP 缓冲区修改事务'
        assert_no_forbidden "TCP pending 检查顺序错误"
    )
    (
        local output="$TEST_TMP/bbr-pending-fast-return.out"

        reset_change_store bbr-pending-fast-return
        manifest_set PENDING_BBR_CONF 1
        bbr_fq_persistent_config_is_current() { forbid "BBR pending 应在健康检查前被拦截"; }
        forbid_init
        if enable_bbr_fq > "$output" 2>&1; then
            fail "BBR 存在未完成事务时不得按健康配置返回成功"
        fi
        assert_file_contains "$output" '尚未处理的 BBR 修改事务'
        assert_no_forbidden "BBR pending 检查顺序错误"
    )
}

test_tcp_buffer_abnormal_managed_config_is_rejected_read_only() {
    local mode

    for mode in comment extra unknown-tier; do
        (
            local output="$TEST_TMP/tcp-buffer-abnormal-$mode.out" before after

            setup_tcp_buffer_case "abnormal-$mode"
            case "$mode" in
                comment)
                    {
                        printf '%s\n' '# operator note'
                        render_tcp_buffer_config \
                            '8388608 8388608 4096,131072,8388608 4096,16384,8388608'
                    } > "$TCP_BUFFER_CONF"
                    ;;
                extra)
                    render_tcp_buffer_config \
                        '8388608 8388608 4096,131072,8388608 4096,16384,8388608' \
                        > "$TCP_BUFFER_CONF"
                    printf '%s\n' 'net.ipv4.tcp_no_metrics_save = 1' >> "$TCP_BUFFER_CONF"
                    ;;
                unknown-tier)
                    render_tcp_buffer_config \
                        '10485760 10485760 4096,131072,10485760 4096,16384,10485760' \
                        > "$TCP_BUFFER_CONF"
                    ;;
            esac
            before="$(cksum < "$TCP_BUFFER_CONF")"
            forbid_init
            sysctl() { forbid "异常 TCP 配置不得读取或修改运行参数"; }
            confirm_default_yes() { forbid "异常 TCP 配置不得询问覆盖确认"; }
            backup_change_file_once() { forbid "异常 TCP 配置不得创建恢复备份"; }
            mktemp() { forbid "异常 TCP 配置不得创建发布临时文件"; }

            if apply_tcp_buffer_tier 1 > "$output" 2>&1; then
                fail "TCP 的 $mode 异常受管配置不得被覆盖"
            fi
            after="$(cksum < "$TCP_BUFFER_CONF")"
            assert_eq "$before" "$after" "异常 TCP 配置必须逐字节保持不变"
            assert_file_contains "$output" '内容不符合 VPSBox TCP 四项档位模板，已拒绝覆盖'
            [ ! -e "$CHANGE_MANIFEST" ] || fail "拒绝异常 TCP 配置后不得创建恢复记录"
            assert_no_forbidden "异常 TCP 配置拒绝路径仍产生了副作用"
        )
    done
}

test_tcp_buffer_failures_restore_runtime_or_keep_pending_record() {
    (
        local output="$TEST_TMP/tcp-buffer-apply-failure.out"

        setup_tcp_buffer_case apply-failure
        TCP_TEST_APPLY_FAIL=1
        if apply_tcp_buffer_tier 1 <<< "" > "$output" 2>&1; then
            fail "TCP 缓冲区部分应用失败时不得报告成功"
        fi
        assert_eq "212992 212992 4096 131072 6291456 4096 16384 4194304" \
            "$TCP_TEST_CORE_RMEM $TCP_TEST_CORE_WMEM $TCP_TEST_TCP_RMEM $TCP_TEST_TCP_WMEM"
        [ ! -e "$TCP_BUFFER_CONF" ] || fail "应用失败不得发布配置"
        assert_file_not_contains "$CHANGE_MANIFEST" \
            '^(BACKUP_TCP_BUFFER_CONF|PENDING_TCP_BUFFER_CONF|APPLIED_TCP_BUFFER_CONF|TCP_BUFFER_.*)='
        assert_file_contains "$output" '运行参数已恢复，持久配置未改动'
    )
    (
        local output="$TEST_TMP/tcp-buffer-restore-failure.out"

        setup_tcp_buffer_case restore-failure
        TCP_TEST_APPLY_FAIL=1
        TCP_TEST_RESTORE_FAIL_KEY=net.core.rmem_max
        if apply_tcp_buffer_tier 1 <<< "" > "$output" 2>&1; then
            fail "TCP 缓冲区回退失败时不得报告成功"
        fi
        assert_file_contains "$CHANGE_MANIFEST" '^PENDING_TCP_BUFFER_CONF=1$'
        assert_file_contains "$CHANGE_MANIFEST" '^BACKUP_TCP_BUFFER_CONF=absent$'
        assert_file_contains "$CHANGE_MANIFEST" '^TCP_BUFFER_RMEM_MAX=212992$'
        assert_file_contains "$output" '已保留事务记录'
    )
}

test_tcp_buffer_publish_failure_preserves_existing_file() {
    (
        local output="$TEST_TMP/tcp-buffer-publish-failure.out"
        local before after

        setup_tcp_buffer_case publish-failure
        render_tcp_buffer_config \
            '16777216 16777216 4096,131072,16777216 4096,16384,16777216' \
            > "$TCP_BUFFER_CONF"
        before="$(cksum < "$TCP_BUFFER_CONF")"
        mv() {
            local last="${!#}"
            [ "$last" != "$TCP_BUFFER_CONF" ] || return 42
            command mv "$@"
        }

        if apply_tcp_buffer_tier 1 <<< "" > "$output" 2>&1; then
            fail "TCP 缓冲区配置发布失败时不得报告成功"
        fi
        after="$(cksum < "$TCP_BUFFER_CONF")"
        assert_eq "$before" "$after" "TCP 发布失败时必须逐字节保留原受管配置"
        assert_eq "212992 212992 4096 131072 6291456 4096 16384 4194304" \
            "$TCP_TEST_CORE_RMEM $TCP_TEST_CORE_WMEM $TCP_TEST_TCP_RMEM $TCP_TEST_TCP_WMEM"
        assert_file_not_contains "$CHANGE_MANIFEST" \
            '^(BACKUP_TCP_BUFFER_CONF|PENDING_TCP_BUFFER_CONF|APPLIED_TCP_BUFFER_CONF|TCP_BUFFER_.*)='
        assert_file_contains "$output" '原配置未改动'
    )
}

test_tcp_buffer_restore_rejects_invalid_metadata_before_mutation() {
    (
        setup_tcp_buffer_case invalid-restore-metadata
        reset_change_store tcp-buffer-invalid-restore-metadata
        TCP_BUFFER_CONF="$TEST_TMP/tcp-buffer-invalid-restore-metadata/99-vpsbox-tcp-buffer.conf"
        backup_change_file_once TCP_BUFFER_CONF "$TCP_BUFFER_CONF"
        manifest_set TCP_BUFFER_RMEM_MAX 212992
        manifest_set TCP_BUFFER_WMEM_MAX 212992
        manifest_set TCP_BUFFER_TCP_RMEM 4096,131072
        manifest_set TCP_BUFFER_TCP_WMEM 4096,16384,4194304
        mark_change_applied TCP_BUFFER_CONF
        forbid_init
        restore_change_file() { forbid "TCP 恢复元数据异常时不得恢复文件"; }
        sysctl() { forbid "TCP 恢复元数据异常时不得修改运行参数"; }

        if restore_tcp_buffer_system_change >/dev/null 2>&1; then
            fail "TCP 缓冲区恢复元数据异常时必须失败"
        fi
        assert_no_forbidden "TCP 恢复必须先完整校验元数据"
    )
}

setup_ipv6_disable_case() {
    local name="$1"

    IPV6_TEST_DIR="$TEST_TMP/ipv6-$name"
    IPV6_DISABLE_CONF="$IPV6_TEST_DIR/99-vpsbox-disable-ipv6.conf"
    VPSBOX_STATE_DIR="$IPV6_TEST_DIR/state"
    CHANGE_MANIFEST="$VPSBOX_STATE_DIR/changes.env"
    CHANGE_BACKUP_DIR="$VPSBOX_STATE_DIR/backups"
    IPV6_TEST_ALL=0
    IPV6_TEST_DEFAULT=0
    IPV6_TEST_LO=0
    IPV6_TEST_IP_FAIL=0
    IPV6_TEST_APPLY_FAIL=0
    IPV6_TEST_KEEP_ADDRESSES=0
    IPV6_TEST_RESTORE_FAIL_KEY=""
    IPV6_TEST_WRITE_FAIL_ONCE_KEY=""
    IPV6_TEST_ADDRESSES=$'2: ens17 inet6 2001:db8:100::7f/64 scope global\n2: ens17 inet6 2001:db8:100::80/64 scope global'
    IPV6_TEST_SYSCTL_LOG="$IPV6_TEST_DIR/sysctl.log"
    mkdir -p "$IPV6_TEST_DIR"
    : > "$IPV6_TEST_SYSCTL_LOG"
    unset SSH_CONNECTION

    ip() {
        [ "$*" = "-6 -o addr show scope global" ] || return 2
        [ "$IPV6_TEST_IP_FAIL" -eq 0 ] || return 42
        if [ "$IPV6_TEST_ALL" -eq 1 ] && [ "$IPV6_TEST_KEEP_ADDRESSES" -eq 0 ]; then
            return 0
        fi
        [ -z "$IPV6_TEST_ADDRESSES" ] || printf '%s\n' "$IPV6_TEST_ADDRESSES"
    }
    sysctl() {
        local key value

        case "$1" in
            -n)
                case "$2" in
                    net.ipv6.conf.all.disable_ipv6) printf '%s\n' "$IPV6_TEST_ALL" ;;
                    net.ipv6.conf.default.disable_ipv6) printf '%s\n' "$IPV6_TEST_DEFAULT" ;;
                    net.ipv6.conf.lo.disable_ipv6) printf '%s\n' "$IPV6_TEST_LO" ;;
                    *) return 2 ;;
                esac
                ;;
            -p)
                printf 'p:%s\n' "$2" >> "$IPV6_TEST_SYSCTL_LOG"
                IPV6_TEST_ALL=1
                if [ "$IPV6_TEST_APPLY_FAIL" -eq 1 ]; then
                    return 41
                fi
                IPV6_TEST_DEFAULT=1
                IPV6_TEST_LO=1
                ;;
            -w)
                printf 'w:%s\n' "$2" >> "$IPV6_TEST_SYSCTL_LOG"
                key="${2%%=*}"
                value="${2#*=}"
                if [ "$key" = "$IPV6_TEST_WRITE_FAIL_ONCE_KEY" ]; then
                    IPV6_TEST_WRITE_FAIL_ONCE_KEY=""
                    return 42
                fi
                [ "$key" != "$IPV6_TEST_RESTORE_FAIL_KEY" ] || return 43
                case "$key" in
                    net.ipv6.conf.all.disable_ipv6) IPV6_TEST_ALL="$value" ;;
                    net.ipv6.conf.default.disable_ipv6) IPV6_TEST_DEFAULT="$value" ;;
                    net.ipv6.conf.lo.disable_ipv6) IPV6_TEST_LO="$value" ;;
                    *) return 2 ;;
                esac
                ;;
            *) return 2 ;;
        esac
    }
}

test_ipv6_no_global_address_is_noop_and_detection_failure_is_fatal() {
    (
        local output="$TEST_TMP/ipv6-none.out"

        setup_ipv6_disable_case none
        IPV6_TEST_ADDRESSES=""
        forbid_init
        read() { forbid "无全局 IPv6 时不得询问"; }
        sysctl() { forbid "无全局 IPv6 时不得读取或修改 sysctl"; }

        disable_ipv6 > "$output"

        assert_file_contains "$output" '未检测到全局 IPv6 地址，无需禁用'
        [ ! -e "$IPV6_DISABLE_CONF" ] || fail "无全局 IPv6 时不得创建配置"
        assert_no_forbidden "无全局 IPv6 时必须零副作用"
    )
    (
        local output="$TEST_TMP/ipv6-detect-failure.out"

        setup_ipv6_disable_case detection-failure
        IPV6_TEST_IP_FAIL=1
        forbid_init
        read() { forbid "IPv6 检测失败时不得询问"; }
        sysctl() { forbid "IPv6 检测失败时不得读取或修改 sysctl"; }

        if disable_ipv6 > "$output" 2>&1; then
            fail "ip 命令失败时不得误报无 IPv6"
        fi
        assert_file_contains "$output" '无法读取全局 IPv6 地址'
        assert_no_forbidden "IPv6 检测失败必须在修改前停止"
    )
}

test_ipv6_addresses_are_displayed_and_cancel_is_read_only() {
    (
        local output="$TEST_TMP/ipv6-cancel.out"

        setup_ipv6_disable_case cancel
        unset SSH_CONNECTION

        disable_ipv6 <<< "n" > "$output"

        assert_file_contains "$output" 'ens17：2001:db8:100::7f/64'
        assert_file_contains "$output" 'ens17：2001:db8:100::80/64'
        assert_file_contains "$output" '已取消禁用 IPv6'
        assert_empty_file "$IPV6_TEST_SYSCTL_LOG" "取消时不得调用 sysctl"
        [ ! -e "$IPV6_DISABLE_CONF" ] || fail "取消时不得创建持久配置"
        [ ! -e "$CHANGE_MANIFEST" ] || fail "IPv6 禁用不应创建通用恢复记录"
    )
}

test_ipv6_ssh_session_is_rejected_before_confirmation() {
    (
        local output="$TEST_TMP/ipv6-ssh.out"

        setup_ipv6_disable_case ssh-ipv6
        SSH_CONNECTION="2001:db8:200::20 52341 2001:db8:100::7f 22"

        disable_ipv6 </dev/null > "$output" 2>&1

        assert_file_contains "$output" '当前 SSH 会话正在通过 IPv6 连接'
        assert_file_contains "$output" '请改用 IPv4 SSH 或 VPS 控制台后重试'
        assert_empty_file "$IPV6_TEST_SYSCTL_LOG" "IPv6 SSH 拦截后不得调用 sysctl"
        [ ! -e "$IPV6_DISABLE_CONF" ] || fail "IPv6 SSH 拦截后不得创建配置"
    )
}

test_ipv6_default_confirmation_applies_and_repeated_run_is_noop() {
    (
        local output="$TEST_TMP/ipv6-success.out" before_count after_count

        setup_ipv6_disable_case success
        # shellcheck disable=SC2034 # 被测 IPv6 会话检测通过动态作用域读取。
        SSH_CONNECTION="198.51.100.20 52341 192.0.2.10 22"
        forbid_init
        systemctl() { forbid "禁用 IPv6 不得调用 systemd"; }
        rc-service() { forbid "禁用 IPv6 不得调用 OpenRC"; }

        disable_ipv6 <<< "" > "$output"

        [ -f "$IPV6_DISABLE_CONF" ] && [ ! -L "$IPV6_DISABLE_CONF" ] ||
            fail "默认确认后必须发布 IPv6 配置"
        assert_eq "$(render_ipv6_disable_config)" "$(cat "$IPV6_DISABLE_CONF")" \
            "IPv6 持久配置内容不正确"
        assert_eq "1 1 1" "$IPV6_TEST_ALL $IPV6_TEST_DEFAULT $IPV6_TEST_LO" \
            "默认确认后必须禁用 all/default/lo"
        assert_file_contains "$output" 'IPv6 已禁用，重启后仍会保持禁用'
        assert_file_contains "$CHANGE_MANIFEST" '^BACKUP_IPV6_CONF=absent$'
        assert_file_contains "$CHANGE_MANIFEST" '^IPV6_ALL=0$'
        assert_file_contains "$CHANGE_MANIFEST" '^IPV6_DEFAULT=0$'
        assert_file_contains "$CHANGE_MANIFEST" '^IPV6_LO=0$'
        assert_file_contains "$CHANGE_MANIFEST" '^APPLIED_IPV6_CONF=1$'
        assert_file_contains "$output" '可通过 vpsbox 系统改动恢复菜单恢复禁用前状态'
        assert_no_forbidden "禁用 IPv6 不得重启服务"

        IPV6_TEST_ALL=0
        IPV6_TEST_DEFAULT=0
        IPV6_TEST_LO=0
        disable_ipv6 <<< "" > "$TEST_TMP/ipv6-repair.out"
        assert_eq "1 1 1" "$IPV6_TEST_ALL $IPV6_TEST_DEFAULT $IPV6_TEST_LO" \
            "持久配置已存在时应只修复运行参数"
        assert_eq "$(render_ipv6_disable_config)" "$(cat "$IPV6_DISABLE_CONF")" \
            "运行参数修复不得改写持久配置内容"

        before_count="$(grep -c '^p:' "$IPV6_TEST_SYSCTL_LOG")"
        forbid_init
        read() { forbid "已无全局 IPv6 时重复执行不得询问"; }
        disable_ipv6 > "$TEST_TMP/ipv6-repeat.out"
        after_count="$(grep -c '^p:' "$IPV6_TEST_SYSCTL_LOG")"
        assert_eq "$before_count" "$after_count" "重复执行不得再次应用 sysctl"
        assert_no_forbidden "重复执行必须在确认前返回"
    )
}

test_ipv6_existing_unmanaged_config_is_rejected() {
    (
        local output="$TEST_TMP/ipv6-existing.out"

        setup_ipv6_disable_case existing
        printf '%s\n' 'net.ipv6.conf.all.disable_ipv6 = 0' > "$IPV6_DISABLE_CONF"

        if disable_ipv6 <<< "" > "$output" 2>&1; then
            fail "已有不同内容的 IPv6 配置不得被覆盖"
        fi

        assert_file_contains "$IPV6_DISABLE_CONF" '^net.ipv6.conf.all.disable_ipv6 = 0$'
        assert_file_contains "$output" '已存在且内容不属于当前配置，已拒绝覆盖'
        assert_empty_file "$IPV6_TEST_SYSCTL_LOG" "拒绝现有配置后不得调用 sysctl"
    )
}

test_ipv6_runtime_apply_or_verification_failure_restores_values() {
    local mode

    for mode in apply verify; do
        (
            local output="$TEST_TMP/ipv6-${mode}-failure.out"

            setup_ipv6_disable_case "$mode-failure"
            if [ "$mode" = "apply" ]; then
                IPV6_TEST_APPLY_FAIL=1
            else
                IPV6_TEST_KEEP_ADDRESSES=1
            fi

            if disable_ipv6 <<< "" > "$output" 2>&1; then
                fail "IPv6 ${mode} 失败时不得报告成功"
            fi

            assert_eq "0 0 0" "$IPV6_TEST_ALL $IPV6_TEST_DEFAULT $IPV6_TEST_LO" \
                "IPv6 ${mode} 失败后应恢复记录的运行参数"
            [ ! -e "$IPV6_DISABLE_CONF" ] || fail "IPv6 ${mode} 失败不得发布持久配置"
            assert_file_contains "$output" '已恢复记录的运行参数，持久配置未改动'
            assert_eq 3 "$(grep -c '^w:' "$IPV6_TEST_SYSCTL_LOG")" \
                "IPv6 ${mode} 失败后应回退三个运行参数"
            assert_file_not_contains "$CHANGE_MANIFEST" \
                '^(BACKUP_IPV6_CONF|PENDING_IPV6_CONF|APPLIED_IPV6_CONF|IPV6_ALL|IPV6_DEFAULT|IPV6_LO)='
        )
    done
}

test_ipv6_publish_failure_restores_runtime_and_preserves_target() {
    (
        local output="$TEST_TMP/ipv6-publish-failure.out"

        setup_ipv6_disable_case publish-failure
        mv() {
            local last="${!#}"
            [ "$last" != "$IPV6_DISABLE_CONF" ] || return 42
            command mv "$@"
        }

        if disable_ipv6 <<< "" > "$output" 2>&1; then
            fail "IPv6 配置发布失败时不得报告成功"
        fi

        assert_eq "0 0 0" "$IPV6_TEST_ALL $IPV6_TEST_DEFAULT $IPV6_TEST_LO" \
            "发布失败后应恢复记录的运行参数"
        [ ! -e "$IPV6_DISABLE_CONF" ] || fail "发布失败不得留下正式配置"
        assert_file_contains "$output" '保存 IPv6 配置失败；已恢复记录的运行参数'
        assert_file_not_contains "$CHANGE_MANIFEST" \
            '^(BACKUP_IPV6_CONF|PENDING_IPV6_CONF|APPLIED_IPV6_CONF|IPV6_ALL|IPV6_DEFAULT|IPV6_LO)='
        if find "$IPV6_TEST_DIR" -maxdepth 1 -name '.vpsbox-disable-ipv6.*' -print -quit | grep -q .; then
            fail "发布失败后不得残留 IPv6 临时配置"
        fi
    )
}

test_ipv6_failed_runtime_restore_reports_manual_recovery() {
    (
        local output="$TEST_TMP/ipv6-restore-failure.out"

        setup_ipv6_disable_case restore-failure
        IPV6_TEST_APPLY_FAIL=1
        IPV6_TEST_RESTORE_FAIL_KEY="net.ipv6.conf.all.disable_ipv6"

        if disable_ipv6 <<< "" > "$output" 2>&1; then
            fail "IPv6 运行参数回退失败时不得报告成功"
        fi

        assert_eq 1 "$IPV6_TEST_ALL" "夹具必须保留未恢复的 all.disable_ipv6"
        assert_file_contains "$output" '记录的运行参数未能确认完整恢复'
        assert_file_contains "$output" '已保留事务记录'
        assert_file_contains "$CHANGE_MANIFEST" '^PENDING_IPV6_CONF=1$'
        assert_file_contains "$CHANGE_MANIFEST" '^BACKUP_IPV6_CONF=absent$'
        assert_file_contains "$CHANGE_MANIFEST" '^IPV6_ALL=0$'
        [ ! -e "$IPV6_DISABLE_CONF" ] || fail "回退失败也不得发布持久配置"
    )
}

test_ipv6_recorded_restore_recovers_file_and_runtime() {
    (
        local output="$TEST_TMP/ipv6-recorded-restore.out"

        setup_ipv6_disable_case recorded-restore
        disable_ipv6 <<< "" >/dev/null

        restore_vpsbox_system_change ipv6 > "$output"

        [ ! -e "$IPV6_DISABLE_CONF" ] || fail "恢复后应移除首次创建的 IPv6 禁用配置"
        assert_eq "0 0 0" "$IPV6_TEST_ALL $IPV6_TEST_DEFAULT $IPV6_TEST_LO" \
            "IPv6 恢复必须还原禁用前的三个运行参数"
        assert_file_not_contains "$CHANGE_MANIFEST" \
            '^(BACKUP_IPV6_CONF|PENDING_IPV6_CONF|APPLIED_IPV6_CONF|IPV6_ALL|IPV6_DEFAULT|IPV6_LO)='
        assert_file_contains "$output" '已重新检测到全局 IPv6 地址'
        assert_file_contains "$output" 'IPv6 禁用 已恢复'
    )
}

test_ipv6_untracked_config_uses_explicit_reenable_path() {
    (
        local output="$TEST_TMP/ipv6-untracked-reenable.out"
        local disable_output="$TEST_TMP/ipv6-untracked-disable.out"

        setup_ipv6_disable_case untracked-reenable
        render_ipv6_disable_config > "$IPV6_DISABLE_CONF"
        if disable_ipv6 <<< "" > "$disable_output" 2>&1; then
            fail "无原始记录的旧版 IPv6 配置不得建立错误恢复基线"
        fi
        assert_file_contains "$disable_output" '请先在系统改动菜单中重新启用 IPv6'
        assert_empty_file "$IPV6_TEST_SYSCTL_LOG" \
            "拒绝旧版 IPv6 配置时不得重新应用运行参数"
        IPV6_TEST_ALL=1
        IPV6_TEST_DEFAULT=1
        IPV6_TEST_LO=1

        assert_eq legacy "$(system_change_state ipv6)" \
            "无原始记录的 VPSBox IPv6 配置应显示单独重新启用状态"
        if recorded_system_changes_present; then
            fail "无原始记录的 IPv6 配置不得进入恢复全部"
        fi
        restore_vpsbox_system_change_interactive ipv6 <<< "YES" > "$output"

        [ ! -e "$IPV6_DISABLE_CONF" ] || fail "重新启用后应移除无记录的 VPSBox 禁用配置"
        assert_eq "0 0 0" "$IPV6_TEST_ALL $IPV6_TEST_DEFAULT $IPV6_TEST_LO"
        assert_file_contains "$output" '不属于精确还原'
        assert_file_contains "$output" 'all/default/lo 已设置为 0'
        assert_file_contains "$output" '已重新检测到全局 IPv6 地址'
        assert_eq "" "${ACTIVE_IPV6_REENABLE_SNAPSHOT:-}" \
            "IPv6 重新启用成功后必须清除活动回滚句柄"
        if find "$IPV6_TEST_DIR" -maxdepth 1 -name '.vpsbox-enable-ipv6.*' -print -quit |
            grep -q .; then
            fail "IPv6 重新启用成功后不得残留临时快照"
        fi
    )
}

test_ipv6_untracked_reenable_failure_restores_original_state() {
    (
        local output="$TEST_TMP/ipv6-untracked-reenable-failure.out"

        setup_ipv6_disable_case untracked-reenable-failure
        render_ipv6_disable_config > "$IPV6_DISABLE_CONF"
        IPV6_TEST_ALL=1
        IPV6_TEST_DEFAULT=1
        IPV6_TEST_LO=1
        IPV6_TEST_WRITE_FAIL_ONCE_KEY=net.ipv6.conf.default.disable_ipv6

        if reenable_untracked_ipv6 > "$output" 2>&1; then
            fail "IPv6 运行参数部分写入失败时不得报告重新启用成功"
        fi
        ipv6_disable_config_is_current || fail "IPv6 重新启用失败后必须保留禁用配置"
        assert_eq "1 1 1" "$IPV6_TEST_ALL $IPV6_TEST_DEFAULT $IPV6_TEST_LO" \
            "IPv6 重新启用失败后必须恢复原运行参数"
        assert_eq "" "${ACTIVE_IPV6_REENABLE_SNAPSHOT:-}" \
            "IPv6 回滚成功后必须清除活动句柄"
        assert_file_contains "$output" '已恢复原禁用配置和运行参数'
        if find "$IPV6_TEST_DIR" -maxdepth 1 -name '.vpsbox-enable-ipv6.*' -print -quit |
            grep -q .; then
            fail "IPv6 回滚成功后不得残留临时快照"
        fi
    )
}

test_runtime_cleanup_rolls_back_active_untracked_ipv6_reenable() {
    (
        local snapshot

        setup_ipv6_disable_case untracked-reenable-cleanup
        render_ipv6_disable_config > "$IPV6_DISABLE_CONF"
        IPV6_TEST_ALL=1
        IPV6_TEST_DEFAULT=1
        IPV6_TEST_LO=1
        snapshot="$(mktemp "$IPV6_TEST_DIR/.vpsbox-enable-ipv6.XXXXXX")"
        cp -a -- "$IPV6_DISABLE_CONF" "$snapshot"
        arm_untracked_ipv6_reenable_rollback "$snapshot" 1 1 1
        IPV6_TEST_ALL=0
        IPV6_TEST_DEFAULT=1
        IPV6_TEST_LO=0
        rm -f -- "$IPV6_DISABLE_CONF"
        cleanup_vpsbox_lock() { return 0; }

        cleanup_vpsbox_runtime

        ipv6_disable_config_is_current || fail "统一退出清理必须恢复 IPv6 禁用配置"
        assert_eq "1 1 1" "$IPV6_TEST_ALL $IPV6_TEST_DEFAULT $IPV6_TEST_LO" \
            "统一退出清理必须恢复 IPv6 原运行参数"
        assert_eq "" "${ACTIVE_IPV6_REENABLE_SNAPSHOT:-}" \
            "统一退出清理成功后必须清除 IPv6 活动句柄"
        [ ! -e "$snapshot" ] || fail "统一退出回滚成功后必须清理 IPv6 临时快照"
    )
}

test_journald_healthy_is_noop() {
    (
        local log="$TEST_TMP/journald-healthy.log"
        : > "$log"
        is_systemd() { return 0; }
        journalctl() { return 0; }
        journald_limit_state() { printf '已配置\n'; }
        systemctl() {
            if [ "$*" = "is-active --quiet systemd-journald" ]; then
                return 0
            fi
            printf '%s\n' "$*" >> "$log"
        }
        journal_disk_usage() { printf '12M\n'; }
        backup_change_file_once() { printf '%s\n' backup >> "$log"; }

        limit_systemd_journal >/dev/null
        assert_empty_file "$log" "健康的 journald 限制不得备份、写配置或重启服务"
    )
}

test_journald_fallback_prefers_managed_dropin() {
    (
        local case_dir="$TEST_TMP/journald-fallback" value

        mkdir -p "$case_dir"
        JOURNALD_VPSBOX_CONF="$case_dir/99-vpsbox.conf"
        printf '%s\n' 'SystemMaxUse=500M' > "$JOURNALD_VPSBOX_CONF"
        systemd-analyze() { return 42; }
        grep() {
            [ "${1:-}" = -E ] &&
                [ "${3:-}" = /etc/systemd/journald.conf ] &&
                [ "${4:-}" = "$JOURNALD_VPSBOX_CONF" ] || return 42
            printf '%s\n' 'SystemMaxUse=100M' 'SystemMaxUse=500M'
        }

        value="$(journald_conf_value SystemMaxUse)" ||
            fail "旧 systemd fallback 应能读取 journald 配置"
        assert_eq 500M "$value" "VPSBox drop-in 必须覆盖 journald 主配置中的旧值"
    )
}

test_journald_apply_and_failed_restart_restore_previous_config() {
    (
        journalctl() {
            printf '%s\n' 'Archived and active journals take up 48.0M in the file system.'
        }

        assert_eq 48.0M "$(journal_disk_usage)" \
            "journald 占用应去掉固定英文说明"
    )
    (
        local output="$TEST_TMP/journald-openrc-unsupported.out"

        forbid_init
        is_systemd() { return 1; }
        journalctl() { forbid "OpenRC 环境不得调用 journalctl"; }

        if limit_systemd_journal > "$output" 2>&1; then
            fail "非 systemd 环境不得进入 journald 配置流程"
        fi
        assert_file_contains "$output" '未检测到 systemd，无法配置 systemd-journald'
        assert_no_forbidden "OpenRC 环境应在 journalctl 调用前退出"
    )
    (
        local case_dir="$TEST_TMP/journald-apply" log="$TEST_TMP/journald-apply.log"

        mkdir -p "$case_dir"
        : > "$log"
        JOURNALD_VPSBOX_CONF="$case_dir/99-vpsbox.conf"
        is_systemd() { return 0; }
        journalctl() { return 0; }
        systemd-analyze() { cat "$JOURNALD_VPSBOX_CONF" 2>/dev/null; }
        backup_change_file_once() { printf '%s\n' backup >> "$log"; }
        begin_change_transaction() { printf '%s\n' begin >> "$log"; }
        systemctl() {
            printf 'systemctl:%s\n' "$*" >> "$log"
            return 0
        }
        mark_change_applied() { printf 'applied:%s\n' "$1" >> "$log"; }
        journal_disk_usage() { printf '%s\n' 0B; }

        limit_systemd_journal <<< "" >/dev/null ||
            fail "journald 正常应用流程应成功"
        assert_file_contains "$JOURNALD_VPSBOX_CONF" '^SystemMaxUse=500M$'
        assert_file_contains "$JOURNALD_VPSBOX_CONF" '^SystemMaxFileSize=50M$'
        assert_file_contains "$log" '^systemctl:restart systemd-journald$'
        assert_file_contains "$log" '^systemctl:is-active --quiet systemd-journald$'
        assert_file_contains "$log" '^applied:JOURNALD_CONF$'
    )
    (
        local case_dir="$TEST_TMP/journald-rotate-vacuum" log="$TEST_TMP/journald-rotate-vacuum.log"

        mkdir -p "$case_dir"
        : > "$log"
        JOURNALD_VPSBOX_CONF="$case_dir/99-vpsbox.conf"
        is_systemd() { return 0; }
        journalctl() { printf 'journalctl:%s\n' "$*" >> "$log"; }
        systemd-analyze() { cat "$JOURNALD_VPSBOX_CONF" 2>/dev/null; }
        backup_change_file_once() { :; }
        begin_change_transaction() { :; }
        systemctl() { return 0; }
        mark_change_applied() { :; }
        journal_disk_usage() { printf '%s\n' 500M; }

        limit_systemd_journal <<< "YES" >/dev/null ||
            fail "journald 立即清理流程应成功"
        assert_eq 1 "$(grep -Fxc 'journalctl:--rotate --vacuum-size=500M' "$log")" \
            "立即清理必须先轮转活动日志，再按 500M 清理归档日志"
    )
    (
        local case_dir="$TEST_TMP/journald-restart-failure"
        local log="$TEST_TMP/journald-restart-failure.log" restart_calls=0

        mkdir -p "$case_dir"
        : > "$log"
        JOURNALD_VPSBOX_CONF="$case_dir/99-vpsbox.conf"
        printf '%s\n' old-journald-config > "$JOURNALD_VPSBOX_CONF"
        is_systemd() { return 0; }
        journalctl() { return 0; }
        systemd-analyze() { cat "$JOURNALD_VPSBOX_CONF" 2>/dev/null; }
        backup_change_file_once() { :; }
        begin_change_transaction() { :; }
        systemctl() {
            case "$*" in
                'restart systemd-journald')
                    restart_calls=$((restart_calls + 1))
                    printf 'restart:%s\n' "$restart_calls" >> "$log"
                    [ "$restart_calls" -gt 1 ]
                    ;;
                *) return 0 ;;
            esac
        }
        mark_change_applied() { printf '%s\n' applied >> "$log"; }

        if limit_systemd_journal > "$case_dir/output" 2>&1; then
            fail "journald 首次重启失败时入口不得报告成功"
        fi
        assert_file_contains "$JOURNALD_VPSBOX_CONF" '^old-journald-config$' \
            "journald 应恢复本次操作前的配置"
        assert_file_contains "$log" '^restart:1$'
        assert_file_contains "$log" '^restart:2$' \
            "恢复旧配置后必须重新启动 journald"
        assert_file_not_contains "$log" '^applied$' \
            "失败的 journald 事务不得标记为已应用"
        assert_file_contains "$case_dir/output" '已恢复修改前的配置与服务'
    )
}

prepare_legacy_ssh_change_tracking() {
    reset_change_store "$1"
    printf '%s\n' \
        'BACKUP_SSHD_MAIN=present' \
        'BACKUP_SSHD_PORT=present' \
        'BACKUP_SSHD_HARDENING=present' \
        'APPLIED_SSH_CONFIG=1' \
        'SSH_PORTS=22' > "$CHANGE_MANIFEST"
    : > "$CHANGE_BACKUP_DIR/SSHD_MAIN"
    : > "$CHANGE_BACKUP_DIR/SSHD_PORT"
    : > "$CHANGE_BACKUP_DIR/SSHD_HARDENING"
}

assert_ssh_tracking_cleared() {
    assert_file_not_contains "$CHANGE_MANIFEST" \
        '^(BACKUP_SSHD_(MAIN|PORT|HARDENING)|APPLIED_SSH_CONFIG|SSH_PORTS)='
    [ ! -e "$CHANGE_BACKUP_DIR/SSHD_MAIN" ] || fail "SSHD_MAIN 备份未清理"
    [ ! -e "$CHANGE_BACKUP_DIR/SSHD_PORT" ] || fail "SSHD_PORT 备份未清理"
    [ ! -e "$CHANGE_BACKUP_DIR/SSHD_HARDENING" ] || fail "SSHD_HARDENING 备份未清理"
}

test_ssh_snapshot_root_and_transaction_names_are_restricted() {
    (
        RUNTIME_DIR="$TEST_TMP/runtime-root"
        assert_eq "$RUNTIME_DIR/ssh-transactions" "$(ssh_restore_snapshot_root)"
        ssh_restore_snapshot_path_allowed "$RUNTIME_DIR/ssh-transactions/transaction.good" ||
            fail "transaction.* 运行期快照名称应被接受"
        ssh_restore_snapshot_path_allowed "$RUNTIME_DIR/ssh-transactions/.building.good" ||
            fail ".building.* 构建目录名称应被接受"
        if ssh_restore_snapshot_path_allowed /tmp/transaction.bad; then
            fail "不得接受 /tmp 下的 SSH 快照"
        fi
        if ssh_restore_snapshot_path_allowed "$TEST_TMP/persistent/ssh-transactions/transaction.old"; then
            fail "不得接受旧持久状态根下的 SSH 快照"
        fi
        if ssh_restore_snapshot_path_allowed "$RUNTIME_DIR/ssh-transactions/restore.old"; then
            fail "不得接受旧 restore.* 快照名称"
        fi
    )
}

test_ssh_port_transaction_stage_order_and_rollback() {
    local stage

    for stage in publish validate restart listener fail2ban firewall commit success; do
        (
            local case_dir="$TEST_TMP/ssh-port-transaction-$stage" log
            log="$case_dir/events.log"
            mkdir -p "$case_dir"
            : > "$log"
            SSH_TARGET_PORT=2222
            begin_ssh_runtime_transaction() {
                [ "$1" = 22 ] && [ "$2" = 1 ] || return 1
                printf '%s\n' snapshot >> "$log"
            }
            ssh_firewall_transition_begin() { printf '%s\n' firewall-begin >> "$log"; }
            sshd_main_has_active_port_directive() { return 1; }
            sshd_vpsbox_port_include_available() { return 0; }
            write_vpsbox_ssh_port_config() {
                printf '%s\n' publish >> "$log"
                [ "$stage" != publish ]
            }
            validate_ssh_port_effective_config() {
                printf '%s\n' validate >> "$log"
                [ "$stage" != validate ]
            }
            restart_ssh_service() {
                printf '%s\n' restart >> "$log"
                [ "$stage" != restart ]
            }
            wait_for_ssh_listener() {
                printf '%s\n' listener >> "$log"
                [ "$stage" != listener ]
            }
            sync_fail2ban_sshd_port() {
                printf '%s\n' fail2ban >> "$log"
                [ "$stage" != fail2ban ]
            }
            ssh_firewall_transition_finish() {
                printf '%s\n' firewall-finish >> "$log"
                [ "$stage" != firewall ]
            }
            commit_ssh_runtime_transaction() {
                printf '%s\n' commit >> "$log"
                [ "$stage" != commit ]
            }
            rollback_active_ssh_transaction() { printf '%s\n' rollback >> "$log"; }
            retire_legacy_ssh_change_tracking() { printf '%s\n' retire >> "$log"; }
            fail2ban_installed() { return 0; }

            if [ "$stage" = success ]; then
                apply_ssh_port_target_transaction 22 >/dev/null ||
                    fail "SSH 端口完整成功路径不应失败"
                assert_eq $'snapshot\nfirewall-begin\npublish\nvalidate\nrestart\nlistener\nfail2ban\nfirewall-finish\ncommit\nretire' "$(cat "$log")" \
                    "SSH 端口事务阶段顺序错误"
            else
                if apply_ssh_port_target_transaction 22 >/dev/null 2>&1; then
                    fail "SSH 端口的 $stage 阶段失败时入口不得报告成功"
                fi
                assert_eq 1 "$(grep -c '^rollback$' "$log")" \
                    "SSH 端口的 $stage 阶段失败后必须触发一次完整回滚"
                assert_file_not_contains "$log" '^retire$' \
                    "SSH 端口事务失败后不得退役旧状态"
                if [ "$stage" = fail2ban ]; then
                    assert_file_not_contains "$log" '^commit$' \
                        "Fail2ban 失败后不得提交 SSH 事务"
                fi
            fi
        )
    done
}

test_ssh_port_conflicting_main_and_dropin_converge_to_main() {
    (
        local ssh_dir="$TEST_TMP/ssh-port-source-conflict" output

        mkdir -p "$ssh_dir/sshd_config.d"
        SSHD_MAIN_CONF="$ssh_dir/sshd_config"
        SSHD_CONFIG_DIR="$ssh_dir/sshd_config.d"
        SSHD_VPSBOX_PORT_CONF="$SSHD_CONFIG_DIR/00-vpsbox-ssh-port.conf"
        SSH_TARGET_PORT=49222
        output="$ssh_dir/output"
        printf '%s\n' "Include $SSHD_VPSBOX_PORT_CONF" 'Port 22' > "$SSHD_MAIN_CONF"
        printf '%s\n' '# Managed by vpsbox' 'Port 23333' > "$SSHD_VPSBOX_PORT_CONF"

        begin_ssh_runtime_transaction() { [ "$1" = "22,23333" ] && [ "$2" = 1 ]; }
        ssh_firewall_transition_begin() { [ "$1" = "$SSH_TARGET_PORT" ]; }
        write_vpsbox_ssh_port_config() { forbid "双来源冲突不得继续写入端口 drop-in"; }
        validate_ssh_port_effective_config() {
            assert_file_contains "$SSHD_MAIN_CONF" "^Include $SSHD_VPSBOX_PORT_CONF$"
            assert_file_contains "$SSHD_MAIN_CONF" '^Port 49222$'
            assert_eq 1 "$(grep -Eic '^[[:space:]]*port[[:space:]]+' "$SSHD_MAIN_CONF")"
            [ ! -e "$SSHD_VPSBOX_PORT_CONF" ] ||
                fail "主配置成为权威来源后必须停用已加载的 VPSBox 端口 drop-in"
        }
        restart_ssh_service() { return 0; }
        wait_for_ssh_listener() { [ "$1" = "$SSH_TARGET_PORT" ]; }
        sync_fail2ban_sshd_port() { return 0; }
        ssh_firewall_transition_finish() { return 0; }
        commit_ssh_runtime_transaction() { return 0; }
        retire_legacy_ssh_change_tracking() { return 0; }
        fail2ban_installed() { return 1; }
        fail_ssh_runtime_transaction() { forbid "SSH 双来源收敛不应进入回滚：$1"; }

        forbid_init
        apply_ssh_port_target_transaction 22,23333 > "$output"

        assert_file_contains "$output" 'SSH 配置写入位置：主配置（已停用 VPSBox 端口 drop-in）'
        assert_no_forbidden "SSH 双来源收敛走错写入或回滚分支"
    )
}

test_runtime_cleanup_rolls_back_active_ssh_transaction() {
    (
        local log="$TEST_TMP/ssh-cleanup-active.log"
        : > "$log"
        ACTIVE_SSH_TRANSACTION_DIR="$TEST_TMP/runtime/ssh-transactions/transaction.active"
        rollback_active_ssh_transaction() {
            printf '%s\n' rollback >> "$log"
            ACTIVE_SSH_TRANSACTION_DIR=""
        }
        cleanup_vpsbox_lock() { return 0; }

        cleanup_vpsbox_runtime
        assert_eq rollback "$(cat "$log")" \
            "cleanup 必须回滚活动 SSH 运行期事务"
    )
}

test_finished_ssh_firewall_is_resynced_during_rollback() {
    (
        local log="$TEST_TMP/ssh-finished-firewall-rollback.log"
        : > "$log"
        ACTIVE_SSH_TRANSACTION_DIR="$TEST_TMP/runtime/ssh-transactions/transaction.finished"
        ACTIVE_SSH_ORIGINAL_PORTS=22
        ACTIVE_SSH_TRANSACTION_HAS_PORT_CHANGE=1
        ACTIVE_SSH_FAIL2BAN_INSTALLED=1
        ACTIVE_SSH_FAIL2BAN_WAS_RUNNING=1
        ACTIVE_SSH_FAIL2BAN_MUTATED=1
        # shellcheck disable=SC2034 # 被测 SSH 回滚通过动态作用域读取。
        ACTIVE_SSH_FIREWALL_TRANSITION=0
        # shellcheck disable=SC2034 # 被测 SSH 回滚通过动态作用域读取。
        ACTIVE_FIREWALL_TRANSITION_DIR=""
        # shellcheck disable=SC2034 # 被测 Fail2ban 清理通过动态作用域读取。
        ACTIVE_FAIL2BAN_SYNC_WAS_RUNNING=""
        restore_ssh_runtime_snapshot() { printf '%s\n' restore >> "$log"; }
        restore_ssh_fail2ban_snapshot() {
            [ "$1" = "$ACTIVE_SSH_TRANSACTION_DIR" ] && [ "$2" = 1 ] && [ "$3" = 1 ] || return 1
            printf '%s\n' fail2ban-restore >> "$log"
        }
        firewall_runtime_enabled() { return 0; }
        ssh_firewall_sync_current_safe_ports() { printf '%s\n' firewall-sync >> "$log"; }
        remove_ssh_restore_snapshot() { printf '%s\n' snapshot-remove >> "$log"; }

        rollback_active_ssh_transaction
        assert_eq $'restore\nfail2ban-restore\nfirewall-sync\nsnapshot-remove' "$(cat "$log")" \
            "finish 后的端口事务回滚必须按恢复 SSH、精确恢复 Fail2ban、重同步防火墙顺序执行"
        assert_eq "" "$ACTIVE_SSH_TRANSACTION_DIR"
        assert_eq 0 "$ACTIVE_SSH_TRANSACTION_HAS_PORT_CHANGE"
        assert_eq 0 "$ACTIVE_SSH_FAIL2BAN_INSTALLED"
        assert_eq 0 "$ACTIVE_SSH_FAIL2BAN_WAS_RUNNING"
        assert_eq 0 "$ACTIVE_SSH_FAIL2BAN_MUTATED"
    )
    (
        local log="$TEST_TMP/ssh-before-fail2ban-rollback.log"
        : > "$log"
        ACTIVE_SSH_TRANSACTION_DIR="$TEST_TMP/runtime/ssh-transactions/transaction.before-fail2ban"
        ACTIVE_SSH_ORIGINAL_PORTS=22
        ACTIVE_SSH_TRANSACTION_HAS_PORT_CHANGE=0
        ACTIVE_SSH_FAIL2BAN_INSTALLED=1
        ACTIVE_SSH_FAIL2BAN_WAS_RUNNING=1
        ACTIVE_SSH_FAIL2BAN_MUTATED=0
        # shellcheck disable=SC2034 # 被测 SSH 回滚通过动态作用域读取。
        ACTIVE_FAIL2BAN_SYNC_WAS_RUNNING=""
        # shellcheck disable=SC2034 # 被测 SSH 回滚通过动态作用域读取。
        ACTIVE_SSH_FIREWALL_TRANSITION=0
        # shellcheck disable=SC2034 # 被测 SSH 回滚通过动态作用域读取。
        ACTIVE_FIREWALL_TRANSITION_DIR=""
        restore_ssh_runtime_snapshot() { printf '%s\n' restore >> "$log"; }
        restore_ssh_fail2ban_snapshot() { forbid "未修改 Fail2ban 时不得重启或恢复它"; }
        remove_ssh_restore_snapshot() { printf '%s\n' snapshot-remove >> "$log"; }
        forbid_init

        rollback_active_ssh_transaction

        assert_eq $'restore\nsnapshot-remove' "$(cat "$log")" \
            "Fail2ban 尚未同步时，SSH 回滚只能恢复实际修改过的领域"
        assert_no_forbidden "SSH 提前失败仍触碰了未修改的 Fail2ban"
    )
}

test_successful_ssh_transaction_uses_only_runtime_snapshot() {
    (
        local log="$TEST_TMP/ssh-runtime-only.log"
        : > "$log"
        forbid_init
        SSH_TARGET_PORT=2222
        ACTIVE_SSH_TRANSACTION_DIR="$TEST_TMP/runtime/ssh-transactions/transaction.success"
        ACTIVE_SSH_ORIGINAL_PORTS=22
        begin_ssh_runtime_transaction() {
            [ "$1" = 22 ] && [ "$2" = 1 ] || return 1
            printf '%s\n' snapshot >> "$log"
        }
        ssh_firewall_transition_begin() { printf '%s\n' firewall-begin >> "$log"; }
        sshd_main_has_active_port_directive() { return 1; }
        sshd_vpsbox_port_include_available() { return 0; }
        write_vpsbox_ssh_port_config() { printf '%s\n' publish >> "$log"; }
        validate_ssh_port_effective_config() { return 0; }
        restart_ssh_service() { return 0; }
        wait_for_ssh_listener() { return 0; }
        sync_fail2ban_sshd_port() { return 0; }
        ssh_firewall_transition_finish() { return 0; }
        commit_ssh_runtime_transaction() {
            printf '%s\n' commit >> "$log"
            ACTIVE_SSH_TRANSACTION_DIR=""
            ACTIVE_SSH_ORIGINAL_PORTS=""
            ACTIVE_SSH_TRANSACTION_HAS_PORT_CHANGE=0
        }
        retire_legacy_ssh_change_tracking() { return 0; }
        fail2ban_installed() { return 1; }
        backup_change_file_once() { forbid "SSH 成功路径不得创建持久备份"; }
        manifest_set() { forbid "SSH 成功路径不得写入 SSH_PORTS"; }
        manifest_set_once() { forbid "SSH 成功路径不得写入 SSH_PORTS"; }

        apply_ssh_port_target_transaction 22 >/dev/null
        assert_eq "" "$ACTIVE_SSH_TRANSACTION_DIR" "成功后必须清除运行期快照标记"
        assert_eq "" "$ACTIVE_SSH_ORIGINAL_PORTS" "成功后必须清除原端口标记"
        assert_eq 0 "$ACTIVE_SSH_TRANSACTION_HAS_PORT_CHANGE" \
            "成功后必须清除端口变更标记"
        assert_no_forbidden "SSH 成功路径仍调用了旧持久备份接口"
    )
}

test_absent_resolv_conf_is_created_successfully() {
    (
        reset_change_store dns-absent
        RESOLV_CONF="$TEST_TMP/dns-absent/resolv.conf"
        verify_dns_resolution() { return 2; }

        write_resolv_conf_dns 1.1.1.1 8.8.8.8 >/dev/null

        assert_file_contains "$RESOLV_CONF" '^nameserver 1\.1\.1\.1$'
        assert_file_contains "$RESOLV_CONF" '^nameserver 8\.8\.8\.8$'
        assert_file_contains "$CHANGE_MANIFEST" '^APPLIED_DNS_RESOLV=1$'
    )
}

test_resolv_conf_ipv4_replacement_preserves_ipv6_and_other_lines() {
    (
        local source="$TEST_TMP/resolv-preserve-ipv6.conf" actual expected

        printf '%s\n' \
            '# resolver note' \
            ' nameserver 9.9.9.9 # replace valid IPv4' \
            'nameserver 2001:db8::53' \
            'nameserver 999.1.1.1' \
            'nameserver 01.1.1.1' \
            'search example.test' \
            'options timeout:2' \
            '' > "$source"

        actual="$(render_resolv_conf_dns 1.1.1.1 8.8.8.8 "$source")"
        expected=$'nameserver 1.1.1.1\nnameserver 8.8.8.8\n# resolver note\nnameserver 2001:db8::53\nnameserver 999.1.1.1\nnameserver 01.1.1.1\nsearch example.test\noptions timeout:2'
        assert_eq "$expected" "$actual" \
            "修改 IPv4 DNS 必须保留 IPv6、非法地址行和其他 resolv.conf 内容"
    )
}

test_identical_resolv_conf_is_side_effect_free() {
    (
        local case_dir="$TEST_TMP/dns-identical-direct"
        local before after

        mkdir -p "$case_dir"
        RESOLV_CONF="$case_dir/resolv.conf"
        printf '%s\n' 'nameserver 1.1.1.1' 'nameserver 8.8.8.8' \
            'search example.test' > "$RESOLV_CONF"
        before="$(cksum < "$RESOLV_CONF")"
        forbid_init
        root_owned_config_file_is_safe_readonly() { return 0; }
        mktemp() { forbid "相同 resolv.conf 不得创建临时文件"; }
        backup_change_file_once() { forbid "相同 resolv.conf 不得创建恢复备份"; }
        begin_change_transaction() { forbid "相同 resolv.conf 不得开启事务"; }
        mv() { forbid "相同 resolv.conf 不得写入"; }
        chown() { forbid "相同 resolv.conf 不得改所有者"; }
        chmod() { forbid "相同 resolv.conf 不得改权限"; }

        write_resolv_conf_dns 1.1.1.1 8.8.8.8 >/dev/null
        after="$(cksum < "$RESOLV_CONF")"

        assert_eq "$before" "$after" "相同 resolv.conf 内容必须保持不变"
        assert_no_forbidden "相同 resolv.conf 仍产生了写入副作用"
        [ -z "$(find "$case_dir" -type f -name '*.bak.*' -print -quit)" ] ||
            fail "DNS 幂等路径不得生成带时间戳的 .bak 文件"
    )
}

test_identical_systemd_resolved_config_repairs_only_service_state() {
    local initial_state

    for initial_state in active inactive; do
        (
            local state="$initial_state"
            local log="$TEST_TMP/resolved-identical-$initial_state.log"

            : > "$log"
            forbid_init
            root_owned_config_dir_is_safe_readonly() { return 0; }
            root_owned_config_file_is_safe_readonly() { return 0; }
            cmp() { cat >/dev/null; }
            retry() {
                shift 2
                "$@"
            }
            systemctl() {
                printf '%s\n' "$*" >> "$log"
                case "$*" in
                    'is-active --quiet systemd-resolved') [ "$state" = active ] ;;
                    'start systemd-resolved') state=active ;;
                    *) return 1 ;;
                esac
            }
            ensure_public_config_dir() { forbid "相同 resolved 配置不得准备写入目录"; }
            mktemp() { forbid "相同 resolved 配置不得创建临时文件"; }
            backup_change_file_once() { forbid "相同 resolved 配置不得创建恢复备份"; }
            begin_change_transaction() { forbid "相同 resolved 配置不得开启事务"; }
            mv() { forbid "相同 resolved 配置不得写入"; }

            write_systemd_resolved_dns 1.1.1.1 8.8.8.8 >/dev/null

            assert_no_forbidden "相同 resolved 配置仍产生了文件副作用"
            assert_file_not_contains "$log" '^restart systemd-resolved$' \
                "相同 resolved 配置不得重启服务"
            if [ "$initial_state" = active ]; then
                assert_eq 1 "$(grep -c '^is-active --quiet systemd-resolved$' "$log")" \
                    "活动服务只需检查一次状态"
                assert_file_not_contains "$log" '^start systemd-resolved$'
            else
                assert_eq 2 "$(grep -c '^is-active --quiet systemd-resolved$' "$log")" \
                    "启动后应再次确认服务状态"
                assert_eq 1 "$(grep -c '^start systemd-resolved$' "$log")" \
                    "非活动服务应只执行 start"
            fi
        )
    done
}

test_dns_operation_snapshot_restores_existing_and_absent_targets() {
    local mode

    for mode in existing absent; do
        (
            local case_dir="$TEST_TMP/dns-operation-snapshot-$mode"
            local target snapshot="" was_created=0

            mkdir -p "$case_dir"
            target="$case_dir/target.conf"
            if [ "$mode" = existing ]; then
                printf '%s\n' original > "$target"
            fi

            create_dns_operation_snapshot "$target" ".rollback" snapshot was_created
            if [ "$mode" = existing ]; then
                assert_eq 0 "$was_created"
                [ -f "$snapshot" ] || fail "既有 DNS 文件必须创建本次操作快照"
                assert_file_contains "$snapshot" '^original$'
            else
                assert_eq 1 "$was_created"
                assert_eq "" "$snapshot" "原目标不存在时不应伪造快照路径"
            fi

            printf '%s\n' modified > "$target"
            restore_dns_operation_snapshot "$snapshot" "$target" "$was_created"
            remove_dns_operation_snapshot "$snapshot"

            if [ "$mode" = existing ]; then
                assert_file_contains "$target" '^original$'
                [ ! -e "$snapshot" ] || fail "恢复成功后必须清理 DNS 操作快照"
            else
                [ ! -e "$target" ] || fail "原目标不存在时回滚必须删除新建文件"
            fi
        )
    done
}

test_pending_dns_same_target_commits_without_rewrite() {
    local kind

    for kind in direct resolved; do
        (
            local case_dir="$TEST_TMP/dns-pending-same-$kind"
            local log="$case_dir/events.log"

            mkdir -p "$case_dir"
            : > "$log"
            RESOLV_CONF="$case_dir/resolv.conf"
            printf '%s\n' 'nameserver 1.1.1.1' 'nameserver 8.8.8.8' > "$RESOLV_CONF"
            forbid_init
            manifest_value_readonly() {
                case "$1" in
                    PENDING_DNS_RESOLV) [ "$kind" = direct ] && printf '%s\n' 1 ;;
                    PENDING_DNS_RESOLVED) [ "$kind" = resolved ] && printf '%s\n' 1 ;;
                    *) return 1 ;;
                esac
            }
            change_backup_record_is_valid() {
                printf 'backup:%s\n' "$1" >> "$log"
                return 0
            }
            root_owned_config_file_is_safe_readonly() { return 0; }
            root_owned_config_dir_is_safe_readonly() { return 0; }
            cmp() { cat >/dev/null; }
            verify_dns_resolution() { printf '%s\n' verify >> "$log"; }
            mark_change_applied() { printf 'applied:%s\n' "$1" >> "$log"; }
            systemctl() {
                printf 'systemctl:%s\n' "$*" >> "$log"
                [ "$*" = 'is-active --quiet systemd-resolved' ]
            }
            mktemp() { forbid "pending 同目标提交不得创建临时文件"; }
            backup_change_file_once() { forbid "pending 同目标提交不得覆盖恢复基线"; }
            begin_change_transaction() { forbid "pending 同目标提交不得重开事务"; }
            ensure_public_config_dir() { forbid "pending 同目标提交不得准备写入目录"; }
            mv() { forbid "pending 同目标提交不得重写 DNS 文件"; }

            if [ "$kind" = direct ]; then
                write_resolv_conf_dns 1.1.1.1 8.8.8.8 >/dev/null
                assert_eq $'backup:DNS_RESOLV\nverify\napplied:DNS_RESOLV' "$(cat "$log")"
            else
                write_systemd_resolved_dns 1.1.1.1 8.8.8.8 >/dev/null
                assert_eq $'backup:DNS_RESOLVED\nsystemctl:is-active --quiet systemd-resolved\nsystemctl:is-active --quiet systemd-resolved\nverify\napplied:DNS_RESOLVED' \
                    "$(cat "$log")"
            fi
            assert_no_forbidden "pending 同目标提交产生了重复写入副作用"
        )
    done
}

test_pending_dns_different_target_is_rejected_without_side_effects() {
    local kind

    for kind in direct resolved; do
        (
            local case_dir="$TEST_TMP/dns-pending-different-$kind"

            mkdir -p "$case_dir"
            RESOLV_CONF="$case_dir/resolv.conf"
            printf '%s\n' 'nameserver 9.9.9.9' > "$RESOLV_CONF"
            forbid_init
            manifest_value_readonly() {
                case "$1" in
                    PENDING_DNS_RESOLV) [ "$kind" = direct ] && printf '%s\n' 1 ;;
                    PENDING_DNS_RESOLVED) [ "$kind" = resolved ] && printf '%s\n' 1 ;;
                    *) return 1 ;;
                esac
            }
            change_backup_record_is_valid() { return 0; }
            root_owned_config_file_is_safe_readonly() { return 0; }
            root_owned_config_dir_is_safe_readonly() { return 0; }
            cmp() { cat >/dev/null; return 1; }
            verify_dns_resolution() { forbid "pending 不同目标不得验证新配置"; }
            mark_change_applied() { forbid "pending 不同目标不得提交事务"; }
            systemctl() { forbid "pending 不同目标不得修改服务"; }
            mktemp() { forbid "pending 不同目标不得创建临时文件"; }
            ensure_public_config_dir() { forbid "pending 不同目标不得准备写入目录"; }
            mv() { forbid "pending 不同目标不得重写 DNS 文件"; }

            if [ "$kind" = direct ]; then
                if write_resolv_conf_dns 1.1.1.1 8.8.8.8 >/dev/null 2>&1; then
                    fail "direct pending 与目标不同时必须拒绝"
                fi
            elif write_systemd_resolved_dns 1.1.1.1 8.8.8.8 >/dev/null 2>&1; then
                fail "resolved pending 与目标不同时必须拒绝"
            fi
            assert_no_forbidden "pending 不同目标拒绝后仍产生副作用"
        )
    done
}

test_pending_resolved_unsafe_directory_never_starts_service() {
    (
        forbid_init
        manifest_value_readonly() {
            [ "$1" = PENDING_DNS_RESOLVED ] && printf '%s\n' 1
        }
        change_backup_record_is_valid() { return 0; }
        root_owned_config_dir_is_safe_readonly() { return 1; }
        root_owned_config_file_is_safe_readonly() {
            forbid "危险 resolved 目录后不得继续检查配置文件"
        }
        systemctl() { forbid "危险 resolved 目录不得启动或查询服务"; }
        ensure_public_config_dir() { forbid "pending 危险目录不得进入写入修复"; }
        mktemp() { forbid "pending 危险目录不得创建临时文件"; }
        mark_change_applied() { forbid "pending 危险目录不得提交事务"; }

        if write_systemd_resolved_dns 1.1.1.1 8.8.8.8 >/dev/null 2>&1; then
            fail "pending resolved 目录不安全时必须拒绝"
        fi
        assert_no_forbidden "危险 resolved 目录仍触发了服务或写入副作用"
    )
}

test_runtime_cleanup_dispatches_active_dns_rollback() {
    (
        local log="$TEST_TMP/dns-runtime-cleanup.log"

        : > "$log"
        ACTIVE_DNS_OPERATION_NAME=DNS_RESOLV
        rollback_active_dns_operation() {
            printf '%s\n' dns-rollback >> "$log"
            clear_active_dns_operation
        }
        cleanup_vpsbox_lock() { printf '%s\n' lock >> "$log"; }

        cleanup_vpsbox_runtime

        assert_eq $'dns-rollback\nlock' "$(cat "$log")" \
            "cleanup 必须在释放锁前分派活动 DNS 回滚"
        assert_eq "" "$ACTIVE_DNS_OPERATION_NAME"
    )
}

test_systemd_resolved_restart_and_verification_failures_rollback() {
    local stage

    for stage in restart verify; do
        (
            local case_dir="$TEST_TMP/resolved-entry-$stage"
            local log="$case_dir/events.log" rollback_status=0

            mkdir -p "$case_dir"
            : > "$log"
            ensure_public_config_dir() { return 0; }
            backup_change_file_once() { return 0; }
            begin_change_transaction() { return 0; }
            create_dns_operation_snapshot() {
                printf -v "$3" '%s' "$case_dir/vpsbox.conf.rollback"
                printf -v "$4" '%s' 1
            }
            arm_dns_operation_rollback() { return 0; }
            cp() { return 0; }
            mktemp() {
                printf '%s\n' "$case_dir/vpsbox.conf.tmp"
            }
            mv() {
                printf 'publish:%s\n' "$*" >> "$log"
                return 0
            }
            retry() {
                shift 2
                "$@"
            }
            systemctl() {
                printf 'systemctl:%s\n' "$*" >> "$log"
                if [ "$stage" = restart ] && [ "$*" = 'restart systemd-resolved' ]; then
                    return 23
                fi
                return 0
            }
            resolvectl() { return 0; }
            verify_dns_resolution() { [ "$stage" != verify ]; }
            rollback_active_dns_operation() {
                printf 'rollback:%s\n' "$stage" >> "$log"
                return "$rollback_status"
            }
            mark_change_applied() { printf '%s\n' applied >> "$log"; }

            if write_systemd_resolved_dns 1.1.1.1 8.8.8.8 > "$case_dir/output" 2>&1; then
                fail "systemd-resolved 的 $stage 阶段失败时入口不得报告成功"
            fi
            assert_eq 1 "$(grep -c '^rollback:' "$log")" \
                "systemd-resolved 的 $stage 阶段失败后必须触发一次配置回滚"
            assert_file_contains "$log" "^rollback:${stage}$"
            assert_file_not_contains "$log" '^applied$' \
                "DNS 回滚路径不得标记变更已应用"
        )
    done
}

test_systemd_resolved_rollback_failure_is_reported() {
    (
        local output="$TEST_TMP/resolved-rollback-failure.out"
        remove_snapshot_target_file() { return 23; }

        if rollback_systemd_resolved_dns \
            /etc/systemd/resolved.conf.d/vpsbox.conf "" 1 0 > "$output" 2>&1; then
            fail "systemd-resolved 回滚失败时不得报告成功"
        fi
    )
}

test_main_ssh_port_rewrite_handles_case_and_match_blocks() {
    (
        local ssh_dir="$TEST_TMP/ssh-main-port-rewrite"
        mkdir -p "$ssh_dir"
        SSHD_MAIN_CONF="$ssh_dir/sshd_config"
        SSH_TARGET_PORT=49222
        printf '%s\n' \
            '# global settings' \
            'port 22' \
            'PORT 2200' \
            'Match Group sftponly' \
            '    ForceCommand internal-sftp' > "$SSHD_MAIN_CONF"

        sshd_main_has_active_port_directive ||
            fail "SSH 主配置端口识别必须忽略指令大小写"
        set_main_ssh_port_directives

        assert_eq 1 "$(grep -Eic '^[[:space:]]*port[[:space:]]+' "$SSHD_MAIN_CONF")" \
            "多个全局 Port 指令必须收敛为一个目标端口"
        assert_file_contains "$SSHD_MAIN_CONF" '^Port 49222$'
        awk '
            /^Port 49222$/ { port_line = NR }
            /^[[:space:]]*[Mm][Aa][Tt][Cc][Hh][[:space:]]/ { match_line = NR }
            END { exit !(port_line && match_line && port_line < match_line) }
        ' "$SSHD_MAIN_CONF" ||
            fail "目标 Port 必须位于第一个 Match 块之前"
        assert_file_not_contains "$SSHD_MAIN_CONF" \
            '^[[:space:]]*[Pp][Oo][Rr][Tt][[:space:]]+(22|2200)$'
    )
}

test_main_ssh_port_is_inserted_before_match_without_global_port() {
    (
        local ssh_dir="$TEST_TMP/ssh-main-port-before-match"
        mkdir -p "$ssh_dir"
        SSHD_MAIN_CONF="$ssh_dir/sshd_config"
        SSH_TARGET_PORT=49222
        printf '%s\n' \
            'PasswordAuthentication no' \
            'Match Group sftponly' \
            '    ForceCommand internal-sftp' > "$SSHD_MAIN_CONF"

        set_main_ssh_port_directives

        assert_eq 1 "$(grep -Eic '^[[:space:]]*port[[:space:]]+' "$SSHD_MAIN_CONF")" \
            "没有全局 Port 时必须新增且仅新增一个目标端口"
        awk '
            /^Port 49222$/ { port_line = NR }
            /^[[:space:]]*[Mm][Aa][Tt][Cc][Hh][[:space:]]/ { match_line = NR }
            END { exit !(port_line && match_line && port_line < match_line) }
        ' "$SSHD_MAIN_CONF" ||
            fail "没有全局 Port 时仍必须在第一个 Match 块之前插入目标端口"
        assert_file_contains "$SSHD_MAIN_CONF" '^[[:space:]]+ForceCommand internal-sftp$'
    )
}

test_active_ufw_and_firewalld_unrecognized_rules_warn() {
    (
        local ufw_active=1 ufw_allow_target=0
        local firewalld_active=0 firewalld_allow_target=0
        local output="$TEST_TMP/ssh-access-firewall-warning.out"

        # shellcheck disable=SC2034 # 被测访问控制函数动态读取。
        SSH_TARGET_PORT=49222
        ufw() {
            [ "$1" = status ] || return 1
            if [ "$ufw_active" -eq 1 ]; then
                printf '%s\n' 'Status: active'
            else
                printf '%s\n' 'Status: inactive'
            fi
            [ "$ufw_allow_target" -eq 0 ] ||
                printf '%s\n' '49222/tcp                 ALLOW       Anywhere'
        }
        firewall-cmd() {
            case "${1:-}" in
                --state) [ "$firewalld_active" -eq 1 ] ;;
                --quiet)
                    [ "${2:-}" = "--query-port=49222/tcp" ] &&
                        [ "$firewalld_allow_target" -eq 1 ]
                    ;;
                *) return 2 ;;
            esac
        }
        getenforce() { printf 'Disabled\n'; }

        validate_ssh_access_controls > "$output" 2>&1 ||
            fail "活动 UFW 无简单规则时应允许转入人工确认"
        assert_file_contains "$output" 'UFW.*自动确认.*TCP 49222' \
            "无法识别 UFW 简单规则时应给出人工确认前置警告"
        assert_file_not_contains "$output" '\[ERR\]' \
            "UFW 规则无法自动确认不得显示为硬错误"

        ufw_allow_target=1
        : > "$output"
        validate_ssh_access_controls > "$output" 2>&1 ||
            fail "活动 UFW 已直接放行新 SSH 端口时应通过检查"
        assert_file_not_contains "$output" 'UFW.*自动确认.*TCP 49222' \
            "已识别 UFW 直接规则时不应要求人工兜底"

        ufw_active=0
        firewalld_active=1
        : > "$output"
        validate_ssh_access_controls > "$output" 2>&1 ||
            fail "活动 firewalld 无简单规则时应允许转入人工确认"
        assert_file_contains "$output" 'firewalld.*自动确认.*TCP 49222' \
            "无法识别 firewalld 简单规则时应给出人工确认前置警告"
        assert_file_not_contains "$output" '\[ERR\]' \
            "firewalld 规则无法自动确认不得显示为硬错误"

        firewalld_allow_target=1
        : > "$output"
        validate_ssh_access_controls > "$output" 2>&1 ||
            fail "活动 firewalld 已直接放行新 SSH 端口时应通过检查"
        assert_file_not_contains "$output" 'firewalld.*自动确认.*TCP 49222' \
            "已识别 firewalld 直接规则时不应要求人工兜底"
    )
}

test_unrecognized_local_firewall_rule_still_requires_exact_yes() {
    local answer

    for answer in yes YES; do
        (
            local case_dir="$TEST_TMP/ssh-firewall-confirm-$answer"
            local event_log="$case_dir/events.log"
            local output="$case_dir/output.log"
            mkdir -p "$case_dir"
            : > "$event_log"
            SSHD_MAIN_CONF="$case_dir/sshd_config"
            printf 'Port 22\n' > "$SSHD_MAIN_CONF"

            sshd_binary() { printf '%s\n' /bin/true; }
            ssh_socket_activation_enabled_or_active() { return 1; }
            choose_ssh_target_port() { printf '49222\n'; }
            ssh_effective_ports_match_target() { return 1; }
            firewall_runtime_enabled() { return 1; }
            ufw() {
                [ "${1:-}" = status ] || return 1
                printf 'Status: active\n'
            }
            firewall-cmd() {
                [ "${1:-}" = --state ] && return 0
                return 1
            }
            getenforce() { printf 'Disabled\n'; }
            ssh_effective_ports_csv() { printf '%s\n' 22; }
            begin_ssh_runtime_transaction() {
                printf 'begin\n' >> "$event_log"
                return 1
            }

            if [ "$answer" = YES ]; then
                if apply_ssh_port_change <<< "$answer" > "$output" 2>&1; then
                    fail "精确 YES 后的运行期事务创建失败不应报告成功"
                fi
                assert_file_contains "$event_log" '^begin$' \
                    "精确 YES 应通过人工确认并进入运行期事务阶段"
            else
                apply_ssh_port_change <<< "$answer" > "$output" 2>&1 ||
                    fail "非精确 YES 应作为安全取消返回"
                assert_empty_file "$event_log" \
                    "非精确 YES 不得备份、修改 SSH 或调整防火墙"
            fi
            assert_file_contains "$output" 'UFW.*自动确认.*TCP 49222' \
                "UFW 简单规则未识别时必须保留警告"
            assert_file_contains "$output" 'firewalld.*自动确认.*TCP 49222' \
                "firewalld 简单规则未识别时必须保留警告"
        )
    done
}

test_selinux_ssh_port_range_is_validated() {
    (
        # shellcheck disable=SC2034 # 被测访问控制函数动态读取。
        SSH_TARGET_PORT=2222
        getenforce() { printf '%s\n' Enforcing; }
        semanage() { printf '%s\n' 'ssh_port_t              tcp      22, 2200-2299'; }

        validate_ssh_access_controls >/dev/null ||
            fail "SELinux ssh_port_t 范围内的目标端口应通过检查"
        # shellcheck disable=SC2034 # 被测访问控制函数动态读取。
        SSH_TARGET_PORT=49222
        if validate_ssh_access_controls >/dev/null 2>&1; then
            fail "SELinux ssh_port_t 范围外的目标端口必须被拒绝"
        fi
    )
}

test_enabled_inactive_ssh_socket_is_detected() {
    (
        is_systemd() { return 0; }
        systemctl() {
            case "$*" in
                "is-active --quiet "*) return 1 ;;
                "is-enabled --quiet ssh.socket") return 0 ;;
                *) return 1 ;;
            esac
        }

        ssh_socket_activation_enabled_or_active ||
            fail "已启用但未运行的 ssh.socket 必须被识别"
    )
}

test_multiple_ssh_socket_streams_are_parsed() {
    (
        is_systemd() { return 0; }
        systemctl() {
            case "$*" in
                "is-active --quiet ssh.socket") return 0 ;;
                "is-active --quiet sshd.socket") return 1 ;;
                "show ssh.socket --property=Listen --value")
                    printf '%s\n' '0.0.0.0:22 (Stream) [::]:2222 (Stream)'
                    ;;
                *) return 1 ;;
            esac
        }

        assert_eq "22,2222" "$(ssh_socket_activation_ports_csv)" \
            "多个 ListenStream 端口必须全部保留"
    )
}

test_ssh_restore_entry_targets_22_without_other_ssh_changes() {
    (
        local ssh_dir="$TEST_TMP/ssh-restore-22" log="$TEST_TMP/ssh-restore-22.log"
        forbid_init
        mkdir -p "$ssh_dir/sshd_config.d"
        SSHD_MAIN_CONF="$ssh_dir/sshd_config"
        SSHD_CONFIG_DIR="$ssh_dir/sshd_config.d"
        SSHD_VPSBOX_PORT_CONF="$SSHD_CONFIG_DIR/00-vpsbox-ssh-port.conf"
        printf '%s\n' 'Port 23333' > "$SSHD_MAIN_CONF"
        : > "$log"
        sshd_binary() { printf '%s\n' /bin/true; }
        ss() { return 1; }
        port_is_effective_ssh_port() { return 1; }
        port_in_use_tcp() { return 1; }
        docker_reserved_ports_for_port_choice() { printf '\n'; }
        validate_ssh_access_controls() { return 0; }
        ssh_effective_ports_csv() { printf '%s\n' 23333; }
        apply_ssh_port_target_transaction() {
            printf 'target=%s original=%s\n' "$SSH_TARGET_PORT" "$1" >> "$log"
        }

        restore_ssh_port_to_22 <<< "YES" >/dev/null
        assert_eq 'target=22 original=23333' "$(cat "$log")" \
            "恢复入口必须仅通过公共事务把目标设为 22"
        assert_no_forbidden "恢复 SSH 端口时执行了范围外操作"
    )
}

test_ssh_restore_menu_copy_is_exact() {
    assert_file_contains "$REPO_DIR/vpsbox.sh" '^ \[2\] 恢复 SSH 端口为 22$' \
        "SSH 恢复菜单文案必须精确"
    assert_file_contains "$REPO_DIR/vpsbox.sh" \
        '^            2\) run_menu_action restore_ssh_port_to_22; pause ;;$'
}

test_legacy_ssh_state_retires_only_after_success_and_preserves_history() {
    (
        local ssh_dir="$TEST_TMP/legacy-ssh-history/etc/ssh"
        local sentinel="$ssh_dir/sshd_config.vpsbox.bak"
        prepare_legacy_ssh_change_tracking legacy-retirement
        mkdir -p "$ssh_dir"
        printf '%s\n' historical > "$sentinel"

        retire_legacy_ssh_change_tracking
        assert_ssh_tracking_cleared
        assert_file_contains "$sentinel" '^historical$' \
            "退役旧状态不得删除历史 /etc/ssh/*.vpsbox.bak 文件"
    )
}

test_ssh_config_publish_failure_preserves_target() {
    (
        local dir="$TEST_TMP/ssh-atomic-publish"
        mkdir -p "$dir"
        printf '%s\n' old > "$dir/target"
        printf '%s\n' new > "$dir/source"
        chown() { return 0; }
        mv() { return 1; }

        if install_ssh_config_atomically "$dir/source" "$dir/target" 644; then
            fail "SSH 配置原子替换失败时不应报告成功"
        fi
        assert_file_contains "$dir/target" '^old$' "发布失败时必须保留原 SSH 配置"
        if find "$dir" -maxdepth 1 -name '.vpsbox-publish.*' -print -quit | grep -q .; then
            fail "SSH 配置发布失败后不应遗留临时文件"
        fi
    )
}

test_ssh_restore_snapshot_integrity_is_verified() {
    require_root_permission_semantics || return "$?"
    (
        local ssh_dir="$TEST_TMP/ssh-snapshot-integrity/etc/ssh" snapshot=""
        reset_change_store ssh-snapshot-integrity
        RUNTIME_DIR="$TEST_TMP/ssh-snapshot-integrity/runtime"
        mkdir -p "$RUNTIME_DIR"
        command chown root:root "$RUNTIME_DIR"
        chmod 700 "$RUNTIME_DIR"
        mkdir -p "$ssh_dir/sshd_config.d"
        SSHD_MAIN_CONF="$ssh_dir/sshd_config"
        SSHD_CONFIG_DIR="$ssh_dir/sshd_config.d"
        SSHD_VPSBOX_PORT_CONF="$SSHD_CONFIG_DIR/00-vpsbox-ssh-port.conf"
        SSHD_VPSBOX_HARDENING_CONF="$SSHD_CONFIG_DIR/01-vpsbox-ssh-hardening.conf"
        FAIL2BAN_VPSBOX_SSHD_CONF="$TEST_TMP/ssh-snapshot-integrity/etc/fail2ban/jail.d/vpsbox-sshd.local"
        printf '%s\n' original > "$SSHD_MAIN_CONF"
        printf '%s\n' 'Port 23333' > "$SSHD_VPSBOX_PORT_CONF"

        create_ssh_restore_snapshot snapshot
        [[ "$snapshot" == "$RUNTIME_DIR"/ssh-transactions/transaction.* ]] ||
            fail "SSH 快照必须位于运行期 ssh-transactions 根目录"
        ssh_restore_snapshot_dir_valid "$snapshot" ||
            fail "新建的 SSH 恢复快照应通过完整性校验"

        printf '%s\n' tampered > "$snapshot/main"
        printf '%s\n' current > "$SSHD_MAIN_CONF"
        if restore_ssh_runtime_snapshot "$snapshot" ""; then
            fail "被篡改的 SSH 恢复快照不得用于恢复"
        fi
        assert_file_contains "$SSHD_MAIN_CONF" '^current$' \
            "快照校验失败时不得修改现有 SSH 配置"
    )
}

test_ssh_snapshot_restores_exact_fail2ban_state() {
    require_root_permission_semantics || return "$?"
    (
        local base="$TEST_TMP/ssh-fail2ban-snapshot" snapshot="" log

        reset_change_store ssh-fail2ban-snapshot
        RUNTIME_DIR="$base/runtime"
        SSHD_MAIN_CONF="$base/etc/ssh/sshd_config"
        SSHD_CONFIG_DIR="$base/etc/ssh/sshd_config.d"
        SSHD_VPSBOX_PORT_CONF="$SSHD_CONFIG_DIR/00-vpsbox-ssh-port.conf"
        SSHD_VPSBOX_HARDENING_CONF="$SSHD_CONFIG_DIR/01-vpsbox-ssh-hardening.conf"
        FAIL2BAN_VPSBOX_SSHD_CONF="$base/etc/fail2ban/jail.d/vpsbox-sshd.local"
        log="$base/service.log"
        mkdir -p "$RUNTIME_DIR" "$SSHD_CONFIG_DIR" "$(dirname "$FAIL2BAN_VPSBOX_SSHD_CONF")"
        command chown root:root "$RUNTIME_DIR"
        chmod 700 "$RUNTIME_DIR"
        printf '%s\n' 'Port 22' > "$SSHD_MAIN_CONF"
        [ ! -e "$SSHD_VPSBOX_HARDENING_CONF" ] ||
            fail "SSH 快照测试不应继承旧加固文件"
        printf '%s\n' 'custom-before-ssh' > "$FAIL2BAN_VPSBOX_SSHD_CONF"
        chmod 640 "$FAIL2BAN_VPSBOX_SSHD_CONF"
        : > "$log"

        create_ssh_restore_snapshot snapshot
        printf '%s\n' 'canonical-after-sync' > "$FAIL2BAN_VPSBOX_SSHD_CONF"
        is_systemd() { return 0; }
        fail2ban-client() { [ "$*" = '-t -c /etc/fail2ban' ]; }
        systemctl() { printf '%s\n' "$*" >> "$log"; }
        fail2ban_service_state() { printf '%s\n' 运行中; }

        restore_ssh_fail2ban_snapshot "$snapshot" 1 1

        assert_file_contains "$FAIL2BAN_VPSBOX_SSHD_CONF" '^custom-before-ssh$' \
            "SSH 回滚必须恢复操作前的 Fail2ban 文件，而不是重新生成标准配置"
        assert_eq 640 "$(stat -c '%a' "$FAIL2BAN_VPSBOX_SSHD_CONF")" \
            "SSH 回滚必须恢复 Fail2ban 文件原权限"
        assert_file_contains "$log" '^restart fail2ban$' \
            "操作前运行中的 Fail2ban 必须恢复为运行状态"
    )
}

test_ssh_restore_snapshot_path_enforces_owner_and_mode() {
    (
        local file="$TEST_TMP/ssh-snapshot-security"

        require_root_permission_semantics || return "$?"
        : > "$file"
        command chown root:root "$file"
        chmod 600 "$file"
        ssh_restore_snapshot_path_is_secure "$file" 600 ||
            fail "root 属主且模式精确为 600 的 SSH 快照应被接受"

        chmod 666 "$file"
        if ssh_restore_snapshot_path_is_secure "$file" 600; then
            fail "可被其他用户写入的 SSH 快照必须被拒绝"
        fi
        chmod 640 "$file"
        if ssh_restore_snapshot_path_is_secure "$file" 600; then
            fail "SSH 快照模式不是精确 600 时必须被拒绝"
        fi
        chmod 600 "$file"
        command chown 65534:65534 "$file"
        if ssh_restore_snapshot_path_is_secure "$file" 600; then
            fail "非 root 属主的 SSH 快照必须被拒绝"
        fi
    )
}

test_public_config_dirs_are_repaired_only_for_managed_files() {
    (
        local base="$TEST_TMP/public-config-dir" new_dir managed_dir unmanaged_dir managed_file

        require_root_permission_semantics || return "$?"
        unset -f chown
        new_dir="$base/new"
        ensure_public_config_dir "$new_dir" "$new_dir/vpsbox.conf"
        assert_eq '0:0 755' "$(stat -c '%u:%g %a' "$new_dir")" \
            "新建的服务配置目录必须为 root:root 755"

        managed_dir="$base/managed"
        managed_file="$managed_dir/vpsbox.conf"
        mkdir -p "$managed_dir"
        : > "$managed_file"
        command chown root:root "$managed_dir" "$managed_file"
        chmod 700 "$managed_dir"
        chmod 644 "$managed_file"
        ensure_public_config_dir "$managed_dir" "$managed_file"
        assert_eq 755 "$(stat -c '%a' "$managed_dir")" \
            "确认由 vpsbox 管理的旧 700 目录应修复为服务可读"

        unmanaged_dir="$base/unmanaged"
        mkdir -p "$unmanaged_dir"
        command chown root:root "$unmanaged_dir"
        chmod 700 "$unmanaged_dir"
        if ensure_public_config_dir "$unmanaged_dir" "$unmanaged_dir/vpsbox.conf" >/dev/null 2>&1; then
            fail "不得擅自放宽没有 vpsbox 管理文件的既有目录"
        fi
        assert_eq 700 "$(stat -c '%a' "$unmanaged_dir")"
    )
}

test_public_config_dir_rejects_symlink() {
    (
        local target="$TEST_TMP/public-config-target" link="$TEST_TMP/public-config-link"

        require_real_symlink directory || return "$?"
        mkdir -p "$target"
        chmod 700 "$target"
        ln -s "$target" "$link"
        if ensure_public_config_dir "$link" "$link/vpsbox.conf" >/dev/null 2>&1; then
            fail "服务配置目录为符号链接时必须拒绝"
        fi
        assert_eq 700 "$(stat -c '%a' "$target")" \
            "拒绝符号链接时不得修改其目标目录"
    )
}

test_chrony_source_file_is_service_readable() {
    (
        local base="$TEST_TMP/chrony-source-mode" fixture_conf

        require_root_permission_semantics || return "$?"
        unset -f chown
        mkdir -p "$base/sources.d"
        command chown root:root "$base/sources.d"
        chmod 755 "$base/sources.d"
        fixture_conf="$base/chrony.conf"
        printf '%s\n' 'sourcedir /etc/chrony/sources.d' > "$fixture_conf"
        CHRONY_SOURCE_FILE="$base/sources.d/vpsbox.sources"
        chrony_conf_path() { printf '%s\n' "$fixture_conf"; }

        write_chrony_sources >/dev/null
        assert_eq '0:0 644' "$(stat -c '%u:%g %a' "$CHRONY_SOURCE_FILE")" \
            "Chrony 管理源必须能被降权服务进程读取"
        chrony_sources_are_current || fail "写入后的 Chrony 源必须通过内容校验"
    )
}

test_dns_verification_uses_bounded_command() {
    (
        local log="$TEST_TMP/dns-verify-bounded.log" timeout
        command() {
            if [ "${1:-}" = "-v" ] && [ "${2:-}" = "getent" ]; then
                return 0
            fi
            if [ "${1:-}" = "-v" ] && [ "${2:-}" = "resolvectl" ]; then
                return 1
            fi
            builtin command "$@"
        }
        run_bounded_command() {
            printf '%s\n' "$*" > "$log"
            printf '%s\n' '192.0.2.1 STREAM example.com'
        }

        verify_dns_resolution || fail "有界 DNS 命令返回地址时应验证成功"
        assert_file_contains "$log" '^[0-9]+ getent ahosts example[.]com$'
        timeout="$(awk '$2 == "getent" && $3 == "ahosts" { print $1; exit }' "$log")"
        [[ "$timeout" =~ ^[0-9]+$ ]] &&
            [ "$timeout" -ge 1 ] && [ "$timeout" -le 60 ] ||
            fail "DNS 验证必须设置 1-60 秒的有界超时"
    )
}

test_hostname_change_does_not_create_restore_record() {
    (
        local runtime_hostname="old.example"

        reset_change_store hostname-no-restore-record
        HOSTNAME_PATH="$TEST_TMP/hostname-no-restore-record/hostname"
        HOSTS_PATH="$TEST_TMP/hostname-no-restore-record/hosts"
        printf '%s\n' old.example > "$HOSTNAME_PATH"
        printf '%s\n' '127.0.0.1 localhost' '192.0.2.10 user-entry' > "$HOSTS_PATH"
        hostname_current_value() { printf '%s\n' "$runtime_hostname"; }
        set_system_hostname() { runtime_hostname="$1"; }

        change_system_hostname <<< "new.example" >/dev/null

        assert_eq new.example "$runtime_hostname"
        assert_file_contains "$HOSTNAME_PATH" '^new[.]example$'
        assert_file_contains "$HOSTS_PATH" '^192\.0\.2\.10 user-entry$'
        assert_file_contains "$HOSTS_PATH" '^127[.]0[.]1[.]1 new[.]example new$'
        assert_file_not_contains "$CHANGE_MANIFEST" 'HOSTNAME' \
            "主机名修改不应写入 vpsbox 持久恢复清单"
        [ ! -e "$CHANGE_BACKUP_DIR/HOSTNAME_FILE" ] &&
            [ ! -e "$CHANGE_BACKUP_DIR/HOSTS_FILE" ] ||
            fail "主机名修改不应创建持久备份"
        assert_eq 'dns bbr ipv4_priority fail2ban journald ntp ipv6 tcp_buffer' \
            "$(system_change_items | paste -sd ' ' -)" \
            "系统恢复项目不应再包含主机名"
    )
}

test_hostname_partial_failure_reports_current_state_without_restore_claim() {
    (
        local runtime_hostname="old.example" fail_hosts_publish=1
        local output="$TEST_TMP/hostname-partial-failure.out"

        reset_change_store hostname-partial-failure
        HOSTNAME_PATH="$TEST_TMP/hostname-partial-failure/hostname"
        HOSTS_PATH="$TEST_TMP/hostname-partial-failure/hosts"
        printf '%s\n' old.example > "$HOSTNAME_PATH"
        printf '%s\n' \
            '127.0.0.1 localhost' '192.0.2.10 user-entry' > "$HOSTS_PATH"
        hostname_current_value() { printf '%s\n' "$runtime_hostname"; }
        set_system_hostname() { runtime_hostname="$1"; }
        mv() {
            local source target
            local -a args=("$@")
            source="${args[${#args[@]}-2]}"
            target="${args[${#args[@]}-1]}"
            if [ "$target" = "$HOSTS_PATH" ] &&
                [ "$fail_hosts_publish" -eq 1 ]; then
                fail_hosts_publish=0
                return 23
            fi
            command mv "$@"
        }

        if change_system_hostname <<< "new.example" > "$output" 2>&1; then
            fail "hosts 发布失败时主机名修改不得报告成功"
        fi

        assert_eq new.example "$runtime_hostname" \
            "不再提供回滚后，应保留已经成功设置的运行时主机名"
        assert_file_contains "$HOSTNAME_PATH" '^new[.]example$'
        assert_file_contains "$HOSTS_PATH" '^192[.]0[.]2[.]10 user-entry$'
        assert_file_not_contains "$HOSTS_PATH" '^# (BEGIN|END) VPSBOX HOSTNAME$'
        assert_file_not_contains "$CHANGE_MANIFEST" 'HOSTNAME'
        assert_file_contains "$output" 'hosts 更新失败'
        assert_file_contains "$output" \
            '当前状态：.*hostname=new[.]example；运行时主机名=new[.]example；.*hosts=未发布'
        assert_file_not_contains "$output" '恢复' \
            "没有执行回滚时不得声称已恢复或尝试恢复"
    )
}

test_signal_traps_preserve_exit_status() {
    local signal expected status

    for signal in INT TERM; do
        case "$signal" in
            INT) expected=130 ;;
            TERM) expected=143 ;;
        esac
        set +e
        REPO_DIR="$REPO_DIR" bash -c '
            set -euo pipefail
            source "$REPO_DIR/vpsbox.sh"
            install_lock_cleanup_traps
            kill -s "$1" "$$"
        ' _ "$signal" >/dev/null 2>&1
        status=$?
        set -e
        assert_eq "$expected" "$status" "$signal 不应被转换成成功退出"
    done
}

test_ssh_restore_rejects_legacy_tmp_snapshot() {
    local legacy="/tmp/vpsbox-ssh-restore.legacy-test.$$"

    if ssh_restore_snapshot_path_allowed "$legacy"; then
        fail "v1.0.43 兼容基线不应再接受 /tmp 中无清单的 SSH 恢复快照"
    fi
}

test_ntp_restore_accepts_complete_current_metadata() {
    (
        local log="$TEST_TMP/ntp-current-metadata.log"
        : > "$log"
        # shellcheck disable=SC2034 # 被测恢复函数动态读取。
        CHRONY_SOURCE_FILE="/unused/vpsbox.sources"
        detect_os() {
            # shellcheck disable=SC2034 # 被测恢复函数动态读取。
            OS=debian
        }
        is_systemd() { return 0; }
        chrony_service_name() { printf '%s\n' chrony; }
        chrony_conf_path() { printf '%s\n' /unused/chrony.conf; }
        manifest_value() {
            case "$1" in
                BACKUP_NTP_CONF|BACKUP_NTP_SOURCES) printf '%s\n' absent ;;
                NTP_CHRONY_PACKAGE) printf '%s\n' installed ;;
                NTP_TIMESYNCD_PACKAGE) printf '%s\n' absent ;;
                NTP_CHRONY_UNIT) printf '%s\n' present ;;
                NTP_TIMESYNCD_UNIT) printf '%s\n' absent ;;
                NTP_CHRONY_ENABLED) printf '%s\n' enabled ;;
                NTP_CHRONY_ACTIVE) printf '%s\n' active ;;
                NTP_TIMESYNCD_ENABLED) printf '%s\n' disabled ;;
                NTP_TIMESYNCD_ACTIVE) printf '%s\n' inactive ;;
                *) return 1 ;;
            esac
        }
        systemctl() { printf 'systemctl:%s\n' "$*" >> "$log"; }
        restore_ntp_packages_to_state() {
            printf 'packages:%s:%s\n' "$1" "$2" >> "$log"
        }
        restore_change_file() {
            printf 'file:%s:%s\n' "$1" "$2" >> "$log"
        }
        restore_ntp_unit_state() {
            printf 'unit:%s:%s:%s:%s\n' "$1" "$2" "$3" "$4" >> "$log"
        }

        restore_recorded_ntp_change ||
            fail "字段完整的 v1.0.43+ NTP 恢复记录必须继续可用"
        assert_file_contains "$log" '^systemctl:stop chrony$'
        assert_file_contains "$log" '^packages:installed:absent$'
        assert_file_contains "$log" '^unit:chrony:present:enabled:active$'
        assert_file_contains "$log" \
            '^unit:systemd-timesyncd:absent:disabled:inactive$'
    )
}

assert_ntp_restore_rejects_metadata() {
    local mode="$1" failure_message="$2"

    (
        forbid_init
        detect_os() {
            # shellcheck disable=SC2034 # 被测恢复函数动态读取。
            OS=debian
        }
        is_systemd() { return 0; }
        chrony_service_name() { printf '%s\n' chrony; }
        manifest_value() {
            if [ "$mode" = "missing" ] && [ "$1" = "BACKUP_NTP_CONF" ]; then
                return 1
            fi
            if [ "$mode" = "invalid" ] && [ "$1" = "NTP_CHRONY_ACTIVE" ]; then
                printf '%s\n' damaged
                return 0
            fi
            case "$1" in
                BACKUP_NTP_CONF|BACKUP_NTP_SOURCES) printf '%s\n' absent ;;
                NTP_CHRONY_PACKAGE|NTP_TIMESYNCD_PACKAGE) printf '%s\n' installed ;;
                NTP_CHRONY_UNIT|NTP_TIMESYNCD_UNIT) printf '%s\n' present ;;
                NTP_CHRONY_ENABLED|NTP_TIMESYNCD_ENABLED) printf '%s\n' enabled ;;
                NTP_CHRONY_ACTIVE) printf '%s\n' active ;;
                NTP_TIMESYNCD_ACTIVE) printf '%s\n' inactive ;;
                *) return 1 ;;
            esac
        }
        systemctl() { forbid "NTP 元数据异常时不得修改服务"; }
        restore_ntp_packages_to_state() { forbid "NTP 元数据异常时不得修改软件包"; }
        restore_change_file() { forbid "NTP 元数据异常时不得恢复文件"; }

        if restore_recorded_ntp_change >/dev/null 2>&1; then
            fail "$failure_message"
        fi
        assert_no_forbidden "NTP 元数据校验必须先于任何恢复副作用"
    )
}

test_ntp_restore_rejects_incomplete_or_invalid_current_metadata() {
    assert_ntp_restore_rejects_metadata missing \
        "缺少当前格式的 NTP 文件备份状态时恢复必须失败"
    assert_ntp_restore_rejects_metadata invalid \
        "NTP 恢复记录包含非法枚举值时必须失败"
}

assert_fail2ban_restore_rejects_metadata() {
    local mode="$1" failure_message="$2"

    (
        forbid_init
        # shellcheck disable=SC2034 # 被测恢复函数动态读取。
        OS=debian
        manifest_value() {
            case "$1" in
                FAIL2BAN_ACTIVE) printf '%s\n' active ;;
                FAIL2BAN_ENABLED)
                    case "$mode" in
                        missing) return 1 ;;
                        invalid) printf '%s\n' damaged ;;
                        *) return 1 ;;
                    esac
                    ;;
                *) return 1 ;;
            esac
        }
        restore_change_file() { forbid "Fail2ban 元数据异常时不得恢复配置"; }
        fail2ban_installed() { return 0; }
        is_systemd() { return 0; }
        resolv_conf_managed_by_systemd_resolved() { return 1; }
        systemctl() { forbid "Fail2ban 元数据异常时不得修改服务"; }

        if restore_fail2ban_system_change >/dev/null 2>&1; then
            fail "$failure_message"
        fi
        assert_no_forbidden "Fail2ban 元数据校验必须先于配置和服务恢复"
    )
}

test_fail2ban_restore_rejects_incomplete_or_invalid_service_metadata() {
    assert_fail2ban_restore_rejects_metadata missing \
        "缺少当前格式的 Fail2ban 服务状态时恢复必须失败"
    assert_fail2ban_restore_rejects_metadata invalid \
        "Fail2ban 恢复记录包含非法枚举值时必须失败"
}

test_fail2ban_restore_accepts_complete_service_metadata() {
    (
        local log="$TEST_TMP/fail2ban-current-metadata.log"
        : > "$log"
        detect_os() {
            # shellcheck disable=SC2034 # 被测恢复函数动态读取。
            OS=debian
        }
        manifest_value() {
            case "$1" in
                FAIL2BAN_ACTIVE) printf '%s\n' active ;;
                FAIL2BAN_ENABLED) printf '%s\n' enabled ;;
                *) return 1 ;;
            esac
        }
        change_backup_record_is_valid() { return 0; }
        restore_change_file() { printf 'restore:%s\n' "$1" >> "$log"; }
        fail2ban_installed() { return 0; }
        fail2ban-client() { printf 'client:%s\n' "$*" >> "$log"; }
        is_systemd() { return 0; }
        resolv_conf_managed_by_systemd_resolved() { return 1; }
        systemctl() { printf 'systemctl:%s\n' "$*" >> "$log"; }
        clear_change_tracking() { return 0; }
        manifest_remove() { return 0; }

        restore_fail2ban_system_change ||
            fail "字段完整的 v1.0.43+ Fail2ban 恢复记录必须继续可用"
        assert_file_contains "$log" '^restore:FAIL2BAN_SSHD$'
        assert_file_contains "$log" '^client:-t -c /etc/fail2ban$'
        assert_file_contains "$log" '^systemctl:enable fail2ban$'
        assert_file_contains "$log" '^systemctl:restart fail2ban$'
    )
}

test_restore_system_changes_clears_success_and_preserves_failed_group() {
    (
        local case_dir="$TEST_TMP/restore-groups"
        local dns_target="$case_dir/resolv.conf" gai_target="$case_dir/gai.conf"
        local output="$case_dir/restore.out" status_output="$case_dir/status.out"

        forbid_init
        reset_change_store restore-groups
        mkdir -p "$case_dir"
        # shellcheck disable=SC2034 # 被测系统恢复入口动态读取。
        RESOLV_CONF="$dns_target"
        # shellcheck disable=SC2034 # 被测系统恢复入口动态读取。
        GAI_CONF="$gai_target"
        printf '%s\n' dns-original > "$dns_target"
        printf '%s\n' gai-original > "$gai_target"
        backup_change_file_once DNS_RESOLV "$dns_target"
        mark_change_applied DNS_RESOLV
        begin_change_transaction DNS_RESOLVED
        backup_change_file_once GAI_CONF "$gai_target"
        mark_change_applied GAI_CONF
        printf '%s\n' dns-modified > "$dns_target"
        printf '%s\n' gai-modified > "$gai_target"
        systemctl() { forbid "DNS 组预检失败时不得修改服务"; }

        show_vpsbox_changes > "$status_output"
        assert_file_contains "$status_output" 'IPv4 DNS：未完成，可恢复'
        assert_file_contains "$status_output" 'IPv4 优先：可恢复'
        assert_file_not_contains "$status_output" 'DNS_RESOLV|GAI_CONF' \
            "系统改动状态不得暴露内部清单键"

        if restore_vpsbox_system_changes 1 > "$output" 2>&1; then
            fail "存在失败项目时恢复全部不得报告成功"
        fi
        assert_file_contains "$dns_target" '^dns-modified$' \
            "组合项目预检失败时不得先恢复其中一部分"
        assert_file_contains "$CHANGE_MANIFEST" '^BACKUP_DNS_RESOLV=file$'
        assert_file_contains "$CHANGE_MANIFEST" '^APPLIED_DNS_RESOLV=1$'
        assert_file_contains "$CHANGE_MANIFEST" '^PENDING_DNS_RESOLVED=1$'
        [ -f "$CHANGE_BACKUP_DIR/DNS_RESOLV" ] ||
            fail "失败的 DNS 组必须保留原始备份"

        assert_file_contains "$gai_target" '^gai-original$' \
            "前一项目失败后仍必须继续恢复后续项目"
        assert_file_not_contains "$CHANGE_MANIFEST" \
            '^(BACKUP_GAI_CONF|APPLIED_GAI_CONF|PENDING_GAI_CONF)='
        [ ! -e "$CHANGE_BACKUP_DIR/GAI_CONF" ] ||
            fail "成功项目必须立即清理自己的备份"
        assert_file_contains "$output" '恢复成功：1 项'
        assert_file_contains "$output" '恢复失败：1 项'
        assert_file_contains "$output" '无记录：6 项'
        assert_no_forbidden "失败组预检后仍执行了系统服务修改"
    )
}

test_single_system_change_restore_is_isolated() {
    (
        local case_dir="$TEST_TMP/restore-single"
        local dns_target="$case_dir/resolv.conf" gai_target="$case_dir/gai.conf"

        reset_change_store restore-single
        mkdir -p "$case_dir"
        # shellcheck disable=SC2034 # 被测单项恢复函数动态读取。
        RESOLV_CONF="$dns_target"
        # shellcheck disable=SC2034 # 被测单项恢复函数动态读取。
        GAI_CONF="$gai_target"
        printf '%s\n' dns-original > "$dns_target"
        printf '%s\n' gai-original > "$gai_target"
        backup_change_file_once DNS_RESOLV "$dns_target"
        mark_change_applied DNS_RESOLV
        backup_change_file_once GAI_CONF "$gai_target"
        mark_change_applied GAI_CONF
        printf '%s\n' dns-modified > "$dns_target"
        printf '%s\n' gai-modified > "$gai_target"

        restore_vpsbox_system_change_interactive ipv4_priority <<< "YES" >/dev/null

        assert_file_contains "$gai_target" '^gai-original$'
        assert_file_not_contains "$CHANGE_MANIFEST" \
            '^(BACKUP_GAI_CONF|APPLIED_GAI_CONF|PENDING_GAI_CONF)='
        [ ! -e "$CHANGE_BACKUP_DIR/GAI_CONF" ] ||
            fail "单项恢复成功后必须清理目标项目备份"
        assert_file_contains "$dns_target" '^dns-modified$' \
            "单项恢复不得修改其他项目"
        assert_file_contains "$CHANGE_MANIFEST" '^APPLIED_DNS_RESOLV=1$'
        [ -f "$CHANGE_BACKUP_DIR/DNS_RESOLV" ] ||
            fail "单项恢复不得清理其他项目备份"
    )
}

test_system_change_without_record_is_noop() {
    (
        local output="$TEST_TMP/restore-no-record.out"

        forbid_init
        reset_change_store restore-no-record
        restore_change_file() { forbid "无记录项目不得恢复文件"; }
        clear_change_tracking() { forbid "无记录项目不得清理清单"; }
        systemctl() { forbid "无记录项目不得修改服务"; }
        sysctl() { forbid "无记录项目不得修改运行参数"; }

        restore_vpsbox_system_change_interactive dns > "$output"
        assert_file_contains "$output" '没有可恢复记录'
        assert_no_forbidden "无记录项目仍产生了恢复副作用"
    )
}

test_uninstall_restore_offer_runs_internal_restore() {
    (
        local log="$TEST_TMP/uninstall-restore.log"
        recorded_system_changes_present() { return 0; }
        show_vpsbox_changes() { printf '%s\n' show >> "$log"; }
        restore_vpsbox_system_changes() { printf 'restore:%s\n' "${1:-}" >> "$log"; }

        offer_restore_recorded_changes_before_uninstall <<< "YES" >/dev/null
        assert_file_contains "$log" '^show$'
        assert_file_contains "$log" '^restore:1$' "卸载恢复应跳过重复确认并执行内部恢复"
    )
}

test_uninstall_restore_offer_can_preserve_changes() {
    (
        local log="$TEST_TMP/uninstall-preserve.log"
        : > "$log"
        recorded_system_changes_present() { return 0; }
        show_vpsbox_changes() { :; }
        restore_vpsbox_system_changes() { printf '%s\n' restore >> "$log"; }

        offer_restore_recorded_changes_before_uninstall <<< "NO" >/dev/null
        assert_empty_file "$log" "选择保留现状时不得调用恢复"
    )
}

test_uninstall_restore_failure_aborts_offer() {
    (
        recorded_system_changes_present() { return 0; }
        show_vpsbox_changes() { :; }
        restore_vpsbox_system_changes() { return 23; }

        if offer_restore_recorded_changes_before_uninstall <<< "YES" >/dev/null 2>&1; then
            fail "系统设置恢复失败时卸载前置步骤不应成功"
        fi
    )
}

main() {
    local name
    local -a required=(
        cancel_unmodified_change_transaction
        cancel_unmodified_ntp_tracking
        change_restore_state
        change_restore_state_readonly
        create_dns_operation_snapshot
        chrony_main_uses_source_dir
        chrony_sources_are_current
        chrony_vpsbox_markers_valid
        disable_ipv6
        rollback_active_untracked_ipv6_reenable
        resolv_conf_line_is_ipv4_nameserver
        apply_tcp_buffer_tier
        enable_bbr_fq
        ensure_public_config_dir
        set_main_ssh_port_directives
        apply_ssh_port_change
        enable_ipv4_priority
        enable_ntp_sync
        ntp_unit_state_matches
        repair_ntp_service_state
        limit_systemd_journal
        change_system_hostname
        system_change_state
        restore_vpsbox_system_change
        restore_vpsbox_system_change_interactive
        restore_vpsbox_system_changes
        restore_ipv6_system_change
        restore_tcp_buffer_system_change
        restore_dns_operation_snapshot
        show_vpsbox_changes
        restore_recorded_ntp_change
        ssh_restore_snapshot_path_allowed
        ssh_restore_snapshot_path_is_secure
        restore_ssh_fail2ban_snapshot
        write_systemd_resolved_dns
        write_chrony_sources
    )
    local -a tests=(
        test_manifest_failure_preserves_existing_file
        test_manifest_round_trips_ssh_port_csv
        test_clear_change_tracking_reports_partial_failure
        test_restore_replaces_target_symlink
        test_atomic_snapshot_restore_replaces_target_symlink
        test_atomic_snapshot_restore_rejects_directory_symlink
        test_atomic_snapshot_restore_replaces_dangling_symlink
        test_backup_rejects_dangling_symlink_without_absent_record
        test_backup_rejects_untracked_destination_symlink
        test_orphan_cleanup_rejects_symlinked_backup_directory
        test_orphan_cleanup_preserves_backups_when_manifest_is_damaged
        test_orphan_cleanup_removes_only_unreferenced_old_backup
        test_ntp_rejects_dangling_config_before_tracking_or_install
        test_atomic_snapshot_restore_move_failure_preserves_target
        test_debian_update_stops_after_first_failure
        test_debian_update_uses_upgrade_timeout
        test_debian_upgrade_failure_skips_autoremove
        test_alpine_update_uses_bounded_steps
        test_ntp_package_rollback_restores_timesyncd
        test_chrony_source_layout_detection
        test_chrony_vpsbox_marker_validation
        test_chrony_sourcedir_inside_managed_block_is_not_external
        test_installed_chrony_config_drift_skips_package_manager
        test_enable_ntp_healthy_is_noop
        test_enable_ntp_rejects_incomplete_existing_metadata_before_backup
        test_ntp_unsynchronized_status_is_nonfatal
        test_ntp_service_drift_uses_light_repair
        test_ntp_light_repair_reports_restore_outcome
        test_ntp_light_repair_is_covered_by_runtime_cleanup
        test_enable_ntp_failure_stages_enter_runtime_rollback
        test_ntp_pre_mutation_snapshot_failures_clear_new_tracking
        test_ntp_pre_mutation_tracking_is_covered_by_runtime_cleanup
        test_cancel_unmodified_ntp_tracking_preserves_existing_baseline
        test_ipv6_no_global_address_is_noop_and_detection_failure_is_fatal
        test_ipv6_addresses_are_displayed_and_cancel_is_read_only
        test_ipv6_ssh_session_is_rejected_before_confirmation
        test_ipv6_default_confirmation_applies_and_repeated_run_is_noop
        test_ipv6_existing_unmanaged_config_is_rejected
        test_ipv6_runtime_apply_or_verification_failure_restores_values
        test_ipv6_publish_failure_restores_runtime_and_preserves_target
        test_ipv6_failed_runtime_restore_reports_manual_recovery
        test_ipv6_recorded_restore_recovers_file_and_runtime
        test_ipv6_untracked_config_uses_explicit_reenable_path
        test_ipv6_untracked_reenable_failure_restores_original_state
        test_runtime_cleanup_rolls_back_active_untracked_ipv6_reenable
        test_bbr_fq_healthy_is_noop
        test_bbr_fq_runtime_drift_uses_light_repair
        test_unsupported_kernel_leaves_no_phantom_pending_change
        test_failed_bbr_runtime_restore_keeps_recovery_transaction
        test_tcp_buffer_tiers_preserve_defaults_and_restore_first_baseline
        test_tcp_buffer_cancel_invalid_default_and_healthy_noop_are_read_only
        test_pending_system_change_blocks_fast_return_paths
        test_tcp_buffer_abnormal_managed_config_is_rejected_read_only
        test_tcp_buffer_failures_restore_runtime_or_keep_pending_record
        test_tcp_buffer_publish_failure_preserves_existing_file
        test_tcp_buffer_restore_rejects_invalid_metadata_before_mutation
        test_journald_healthy_is_noop
        test_journald_fallback_prefers_managed_dropin
        test_journald_apply_and_failed_restart_restore_previous_config
        test_ssh_snapshot_root_and_transaction_names_are_restricted
        test_ssh_port_transaction_stage_order_and_rollback
        test_ssh_port_conflicting_main_and_dropin_converge_to_main
        test_runtime_cleanup_rolls_back_active_ssh_transaction
        test_finished_ssh_firewall_is_resynced_during_rollback
        test_successful_ssh_transaction_uses_only_runtime_snapshot
        test_absent_resolv_conf_is_created_successfully
        test_resolv_conf_ipv4_replacement_preserves_ipv6_and_other_lines
        test_identical_resolv_conf_is_side_effect_free
        test_identical_systemd_resolved_config_repairs_only_service_state
        test_dns_operation_snapshot_restores_existing_and_absent_targets
        test_pending_dns_same_target_commits_without_rewrite
        test_pending_dns_different_target_is_rejected_without_side_effects
        test_pending_resolved_unsafe_directory_never_starts_service
        test_runtime_cleanup_dispatches_active_dns_rollback
        test_systemd_resolved_restart_and_verification_failures_rollback
        test_systemd_resolved_rollback_failure_is_reported
        test_main_ssh_port_rewrite_handles_case_and_match_blocks
        test_main_ssh_port_is_inserted_before_match_without_global_port
        test_active_ufw_and_firewalld_unrecognized_rules_warn
        test_unrecognized_local_firewall_rule_still_requires_exact_yes
        test_selinux_ssh_port_range_is_validated
        test_enabled_inactive_ssh_socket_is_detected
        test_multiple_ssh_socket_streams_are_parsed
        test_ssh_restore_entry_targets_22_without_other_ssh_changes
        test_ssh_restore_menu_copy_is_exact
        test_legacy_ssh_state_retires_only_after_success_and_preserves_history
        test_ssh_config_publish_failure_preserves_target
        test_ssh_restore_snapshot_integrity_is_verified
        test_ssh_snapshot_restores_exact_fail2ban_state
        test_ssh_restore_snapshot_path_enforces_owner_and_mode
        test_public_config_dirs_are_repaired_only_for_managed_files
        test_public_config_dir_rejects_symlink
        test_chrony_source_file_is_service_readable
        test_dns_verification_uses_bounded_command
        test_hostname_change_does_not_create_restore_record
        test_hostname_partial_failure_reports_current_state_without_restore_claim
        test_signal_traps_preserve_exit_status
        test_ssh_restore_rejects_legacy_tmp_snapshot
        test_ntp_restore_accepts_complete_current_metadata
        test_ntp_restore_rejects_incomplete_or_invalid_current_metadata
        test_fail2ban_restore_rejects_incomplete_or_invalid_service_metadata
        test_fail2ban_restore_accepts_complete_service_metadata
        test_restore_system_changes_clears_success_and_preserves_failed_group
        test_single_system_change_restore_is_isolated
        test_system_change_without_record_is_noop
        test_uninstall_restore_offer_runs_internal_restore
        test_uninstall_restore_offer_can_preserve_changes
        test_uninstall_restore_failure_aborts_offer
    )

    for name in "${required[@]}"; do
        require_function "$name"
    done
    run_registered_test_suite \
        "${BASH_SOURCE[0]}" "system regression tests" "${tests[@]}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
