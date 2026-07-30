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

        rm -f "$CHRONY_SOURCE_FILE"
        printf 'driftfile /var/lib/chrony/drift\n\n%s\n' "$NTP_SOURCES_BEGIN" > "$test_conf"
        chrony_expected_sources >> "$test_conf"
        printf '%s\n' "$NTP_SOURCES_END" >> "$test_conf"
        chrony_sources_are_current || fail "主配置中的规范 vpsbox 区块应识别为当前状态"

        printf 'pool unexpected.example iburst\n' >> "$test_conf"
        chrony_sources_are_current || fail "区块外的用户配置不应导致重复改写"
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
                'enable chrony') mock_chrony_enabled=1; printf '%s\n' 'enable chrony' >> "$log" ;;
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
            mktemp() {
                if [ "${1:-}" = -d ]; then
                    mkdir -p "$case_dir/snapshot"
                    printf '%s\n' "$case_dir/snapshot"
                else
                    command mktemp "$@"
                fi
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

test_journald_apply_and_failed_restart_restore_previous_config() {
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

prepare_ssh_change_tracking() {
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

test_first_ssh_port_rollback_clears_tracking() {
    prepare_ssh_change_tracking ssh-port-first
    restore_ssh_config_backup() { return 0; }
    sshd_binary() { printf '%s\n' /bin/true; }
    restart_ssh_service() { return 0; }
    wait_for_any_ssh_listener_csv() { return 0; }
    ssh_firewall_transition_abort() { return 0; }

    rollback_ssh_port_change "" "" 22 0
    assert_ssh_tracking_cleared
}

test_first_ssh_hardening_rollback_clears_tracking() {
    prepare_ssh_change_tracking ssh-hardening-first
    restore_ssh_config_backup() { return 0; }
    restart_ssh_service() { return 0; }

    rollback_ssh_hardening_change "" "" 0 1
    assert_ssh_tracking_cleared
}

test_existing_ssh_baseline_survives_later_rollback() {
    prepare_ssh_change_tracking ssh-existing
    restore_ssh_config_backup() { return 0; }
    restart_ssh_service() { return 0; }

    rollback_ssh_hardening_change "" "" 1 1
    assert_file_contains "$CHANGE_MANIFEST" '^BACKUP_SSHD_MAIN=present$'
    assert_file_contains "$CHANGE_MANIFEST" '^APPLIED_SSH_CONFIG=1$'
    assert_file_contains "$CHANGE_MANIFEST" '^SSH_PORTS=22$'
    [ -f "$CHANGE_BACKUP_DIR/SSHD_MAIN" ] ||
        fail "后续事务失败不应删除此前成功应用所需的 SSH 基线"
}

test_ssh_hardening_requires_listener_after_restart() {
    (
        local ssh_dir="$TEST_TMP/ssh-hardening-listener/etc/ssh"
        local log="$TEST_TMP/ssh-hardening-listener.log"
        local wait_calls=0
        reset_change_store ssh-hardening-listener
        mkdir -p "$ssh_dir/sshd_config.d"
        SSHD_MAIN_CONF="$ssh_dir/sshd_config"
        SSHD_CONFIG_DIR="$ssh_dir/sshd_config.d"
        SSHD_VPSBOX_PORT_CONF="$SSHD_CONFIG_DIR/00-vpsbox-ssh-port.conf"
        SSHD_VPSBOX_HARDENING_CONF="$SSHD_CONFIG_DIR/01-vpsbox-ssh-hardening.conf"
        printf '%s\n' 'Port 6384' > "$SSHD_MAIN_CONF"
        : > "$log"

        sshd_binary() { printf '%s\n' /bin/true; }
        settle_stale_unapplied_ssh_tracking() { return 0; }
        ssh_basic_hardening_effective() { return 1; }
        backup_change_file_once() { return 0; }
        ssh_effective_ports_csv() { printf '%s\n' 6384; }
        manifest_set_once() { return 0; }
        backup_ssh_file() { printf '%s\n' "$TEST_TMP/ssh-hardening-backup"; }
        mark_change_applied() { return 0; }
        write_vpsbox_ssh_hardening_config() { return 0; }
        ensure_sshd_dropin_include() { return 0; }
        validate_ssh_hardening_effective_config() { return 0; }
        restart_ssh_service() { printf '%s\n' restart >> "$log"; }
        wait_for_any_ssh_listener_csv() {
            wait_calls=$((wait_calls + 1))
            printf 'wait:%s:%s\n' "$wait_calls" "$1" >> "$log"
            [ "$wait_calls" -gt 1 ]
        }
        restore_ssh_config_backup() { printf '%s\n' restore >> "$log"; }
        clear_ssh_change_tracking() { printf '%s\n' clear >> "$log"; }

        if apply_ssh_basic_hardening <<< "y" >"$TEST_TMP/ssh-hardening-listener.out" 2>&1; then
            fail "SSH 重启后原端口未监听时加固不得报告成功"
        fi
        assert_file_contains "$log" '^wait:1:6384$'
        assert_file_contains "$log" '^restore$' "监听验证失败后必须回滚配置"
        assert_file_contains "$log" '^wait:2:6384$' "回滚后必须再次确认原端口监听"
        assert_file_contains "$log" '^clear$'
    )
}

test_ssh_pre_mark_failure_cleans_first_baseline() {
    local ssh_dir="$TEST_TMP/ssh-pre-mark/etc/ssh"

    reset_change_store ssh-pre-mark
    mkdir -p "$ssh_dir/sshd_config.d"
    SSHD_MAIN_CONF="$ssh_dir/sshd_config"
    SSHD_CONFIG_DIR="$ssh_dir/sshd_config.d"
    # Consumed indirectly by the sourced SSH transaction.
    # shellcheck disable=SC2034
    SSHD_VPSBOX_PORT_CONF="$SSHD_CONFIG_DIR/00-vpsbox-ssh-port.conf"
    # shellcheck disable=SC2034
    SSHD_VPSBOX_HARDENING_CONF="$SSHD_CONFIG_DIR/01-vpsbox-ssh-hardening.conf"
    printf '%s\n' 'Port 22' > "$SSHD_MAIN_CONF"
    ACTIVE_UNAPPLIED_SSH_TRACKING=0

    sshd_binary() { printf '%s\n' /bin/true; }
    ssh_socket_activation_active() { return 1; }
    choose_ssh_target_port() { printf '%s\n' 2222; }
    ssh_effective_ports_match_target() { return 1; }
    firewall_runtime_enabled() { return 1; }
    ssh_effective_ports_csv() { return 23; }

    if apply_ssh_port_change <<< "YES" >/dev/null 2>&1; then
        fail "首次 SSH 事务在 APPLIED 标记前失败时不应成功"
    fi
    assert_ssh_tracking_cleared
    assert_eq 0 "$ACTIVE_UNAPPLIED_SSH_TRACKING" "失败后不应保留活动清理标记"
}

test_ssh_port_change_failure_stages_rollback_and_success_syncs_fail2ban() {
    local stage

    for stage in publish validate restart listener firewall success; do
        (
            local case_dir="$TEST_TMP/ssh-port-entry-$stage"
            local log="$case_dir/events.log"

            mkdir -p "$case_dir"
            : > "$log"
            SSHD_MAIN_CONF="$case_dir/sshd_config"
            SSHD_CONFIG_DIR="$case_dir/sshd_config.d"
            SSHD_VPSBOX_PORT_CONF="$SSHD_CONFIG_DIR/00-vpsbox-ssh-port.conf"
            SSHD_VPSBOX_HARDENING_CONF="$SSHD_CONFIG_DIR/01-vpsbox-ssh-hardening.conf"
            mkdir -p "$SSHD_CONFIG_DIR"
            printf '%s\n' 'Port 22' > "$SSHD_MAIN_CONF"

            sshd_binary() { printf '%s\n' /bin/true; }
            ssh_socket_activation_enabled_or_active() { return 1; }
            settle_stale_unapplied_ssh_tracking() { return 0; }
            choose_ssh_target_port() { printf '%s\n' 2222; }
            ssh_effective_ports_match_target() { return 1; }
            validate_ssh_access_controls() { return 0; }
            firewall_runtime_enabled() { return 1; }
            manifest_value() {
                [ "$1" = APPLIED_SSH_CONFIG ] && printf '%s\n' 1
            }
            backup_change_file_once() { return 0; }
            ssh_effective_ports_csv() { printf '%s\n' 22; }
            manifest_set_once() { return 0; }
            backup_ssh_file() { printf '%s\n' "$case_dir/backup-${1##*/}"; }
            ssh_firewall_transition_begin() { printf '%s\n' firewall-begin >> "$log"; }
            mark_change_applied() { return 0; }
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
            ssh_firewall_transition_finish() {
                printf '%s\n' firewall-finish >> "$log"
                [ "$stage" != firewall ]
            }
            rollback_ssh_port_change() {
                printf 'rollback:%s\n' "$stage" >> "$log"
                return 0
            }
            sync_fail2ban_sshd_port() { printf '%s\n' fail2ban-sync >> "$log"; }
            fail2ban_installed() { return 0; }

            if [ "$stage" = success ]; then
                apply_ssh_port_change <<< "YES" >/dev/null ||
                    fail "SSH 端口完整成功路径不应失败"
                assert_file_contains "$log" '^fail2ban-sync$' \
                    "SSH 端口修改成功后必须同步 Fail2ban"
                assert_file_not_contains "$log" '^rollback:' \
                    "SSH 端口成功路径不得回滚"
            else
                if apply_ssh_port_change <<< "YES" >/dev/null 2>&1; then
                    fail "SSH 端口的 $stage 阶段失败时入口不得报告成功"
                fi
                assert_eq 1 "$(grep -c '^rollback:' "$log")" \
                    "SSH 端口的 $stage 阶段失败后必须触发一次完整回滚"
                assert_file_contains "$log" "^rollback:${stage}$"
                assert_file_not_contains "$log" '^fail2ban-sync$' \
                    "SSH 端口事务失败后不得同步 Fail2ban"
            fi
        )
    done
}

test_runtime_cleanup_clears_interrupted_ssh_baseline() {
    prepare_ssh_change_tracking ssh-interrupted
    ACTIVE_UNAPPLIED_SSH_TRACKING=1
    cleanup_vpsbox_lock() { return 0; }

    cleanup_vpsbox_runtime

    assert_ssh_tracking_cleared
    assert_eq 0 "$ACTIVE_UNAPPLIED_SSH_TRACKING" "运行时清理后不应保留 SSH 首次事务标记"
}

test_failed_ssh_tracking_cleanup_remains_retryable() {
    local fail_once=1

    reset_change_store ssh-cleanup-retry
    : > "$CHANGE_BACKUP_DIR/SSHD_MAIN"
    ACTIVE_UNAPPLIED_SSH_TRACKING=1
    manifest_remove() {
        if [ "$1" = "BACKUP_SSHD_MAIN" ] && [ "$fail_once" -eq 1 ]; then
            fail_once=0
            return 23
        fi
        return 0
    }

    if cleanup_unapplied_ssh_tracking 0; then
        fail "首次清理失败时不应报告成功"
    fi
    assert_eq 1 "$ACTIVE_UNAPPLIED_SSH_TRACKING" "清理失败后必须保留重试标记"
    cleanup_unapplied_ssh_tracking 0
    assert_eq 0 "$ACTIVE_UNAPPLIED_SSH_TRACKING" "后续完整清理后才可清除重试标记"
}

test_stale_unapplied_ssh_baseline_is_removed_on_next_run() {
    prepare_ssh_change_tracking ssh-stale-unapplied
    manifest_remove APPLIED_SSH_CONFIG
    ACTIVE_UNAPPLIED_SSH_TRACKING=0

    settle_stale_unapplied_ssh_tracking

    assert_ssh_tracking_cleared
    assert_eq 0 "$ACTIVE_UNAPPLIED_SSH_TRACKING"
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
            rollback_systemd_resolved_dns() {
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

        rollback_systemd_resolved_dns \
            /etc/systemd/resolved.conf.d/vpsbox.conf "" 1 > "$output" 2>&1
        assert_file_contains "$output" '删除新建的 systemd-resolved DNS 配置失败'
        assert_file_not_contains "$output" '已删除新建的 systemd-resolved DNS 配置'
    )
}

test_sshd_include_only_activates_vpsbox_files() {
    (
        local ssh_dir="$TEST_TMP/ssh-explicit-include"
        mkdir -p "$ssh_dir/sshd_config.d"
        SSHD_MAIN_CONF="$ssh_dir/sshd_config"
        SSHD_CONFIG_DIR="$ssh_dir/sshd_config.d"
        SSHD_VPSBOX_PORT_CONF="$SSHD_CONFIG_DIR/00-vpsbox-ssh-port.conf"
        SSHD_VPSBOX_HARDENING_CONF="$SSHD_CONFIG_DIR/01-vpsbox-ssh-hardening.conf"
        printf '%s\n' 'Port 22' > "$SSHD_MAIN_CONF"
        printf '%s\n' 'PasswordAuthentication yes' > "$SSHD_CONFIG_DIR/90-dormant.conf"

        ensure_sshd_dropin_include

        assert_file_contains "$SSHD_MAIN_CONF" \
            "^Include $SSHD_VPSBOX_PORT_CONF $SSHD_VPSBOX_HARDENING_CONF$"
        assert_file_not_contains "$SSHD_MAIN_CONF" 'sshd_config\.d/\*\.conf'
        assert_file_contains "$SSHD_CONFIG_DIR/90-dormant.conf" '^PasswordAuthentication yes$'
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
            settle_stale_unapplied_ssh_tracking() { return 0; }
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
            backup_change_file_once() {
                printf 'backup\n' >> "$event_log"
                return 1
            }
            cleanup_unapplied_ssh_tracking() { return 0; }

            if [ "$answer" = YES ]; then
                if apply_ssh_port_change <<< "$answer" > "$output" 2>&1; then
                    fail "精确 YES 后的强制备份失败不应报告成功"
                fi
                assert_file_contains "$event_log" '^backup$' \
                    "精确 YES 应通过人工确认并进入修改前备份阶段"
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

test_ssh_restore_does_not_require_current_config_to_parse() {
    require_root_permission_semantics || return "$?"
    (
        local ssh_dir="$TEST_TMP/ssh-invalid-current" transition_log="$TEST_TMP/ssh-invalid-transition"
        forbid_init
        reset_change_store ssh-invalid-current
        mkdir -p "$ssh_dir/sshd_config.d"
        SSHD_MAIN_CONF="$ssh_dir/sshd_config"
        SSHD_CONFIG_DIR="$ssh_dir/sshd_config.d"
        SSHD_VPSBOX_PORT_CONF="$SSHD_CONFIG_DIR/00-vpsbox-ssh-port.conf"
        SSHD_VPSBOX_HARDENING_CONF="$SSHD_CONFIG_DIR/01-vpsbox-ssh-hardening.conf"
        printf '%s\n' broken > "$SSHD_MAIN_CONF"
        # shellcheck disable=SC2034 # 被测的 SSH 连接端口解析函数动态读取。
        SSH_CONNECTION="192.0.2.10 50000 192.0.2.20 6384"
        manifest_value() {
            case "$1" in
                APPLIED_SSH_CONFIG) printf '%s\n' 1 ;;
                SSH_PORTS) printf '%s\n' 22 ;;
                *) return 1 ;;
            esac
        }
        ssh_listening_ports_csv() { printf '%s\n' 23333; }
        ssh_effective_ports_csv() { forbid "损坏配置恢复入口不得调用 sshd -T"; }
        ssh_firewall_transition_begin() { printf '%s\n' "$1" > "$transition_log"; }
        restore_change_file() { return 0; }
        sshd_binary() { printf '%s\n' /bin/true; }
        restart_ssh_service() { return 0; }
        wait_for_any_ssh_listener_csv() { return 0; }
        ssh_firewall_transition_finish() { return 0; }
        clear_ssh_change_tracking() { return 0; }
        sync_fail2ban_sshd_port() { printf '%s\n' fail2ban-sync >> "$transition_log"; }

        restore_vpsbox_ssh_config <<< "YES" >/dev/null
        assert_file_contains "$transition_log" '^22,6384,23333$'
        assert_file_contains "$transition_log" '^fail2ban-sync$' \
            "SSH 配置恢复成功后必须同步 Fail2ban 端口"
        assert_no_forbidden "损坏配置恢复入口调用了 sshd -T"
    )
}

test_failed_ssh_restore_preserves_retry_snapshot() {
    require_root_permission_semantics || return "$?"
    (
        local ssh_dir="$TEST_TMP/ssh-restore-snapshot/etc/ssh"
        local snapshot
        reset_change_store ssh-restore-snapshot
        mkdir -p "$ssh_dir/sshd_config.d"
        SSHD_MAIN_CONF="$ssh_dir/sshd_config"
        SSHD_CONFIG_DIR="$ssh_dir/sshd_config.d"
        SSHD_VPSBOX_PORT_CONF="$SSHD_CONFIG_DIR/00-vpsbox-ssh-port.conf"
        SSHD_VPSBOX_HARDENING_CONF="$SSHD_CONFIG_DIR/01-vpsbox-ssh-hardening.conf"
        printf '%s\n' broken > "$SSHD_MAIN_CONF"
        manifest_value() {
            case "$1" in
                APPLIED_SSH_CONFIG) printf '%s\n' 1 ;;
                SSH_PORTS) printf '%s\n' 22 ;;
                *) return 1 ;;
            esac
        }
        ssh_listening_ports_csv() { printf '%s\n' 23333; }
        ssh_firewall_transition_begin() { return 0; }
        restore_change_file() { return 1; }
        settle_failed_ssh_restore() { return 1; }

        if restore_vpsbox_ssh_config <<< "YES" >/dev/null 2>&1; then
            fail "SSH 配置恢复失败时不得报告成功"
        fi
        snapshot="$(find "$(ssh_restore_snapshot_root)" -maxdepth 1 -type d -name 'restore.*' -print -quit)"
        [ -d "$snapshot" ] || fail "二次回滚失败后必须保留恢复前快照"
        assert_file_contains "$snapshot/main" '^broken$'
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
        mkdir -p "$ssh_dir/sshd_config.d"
        SSHD_MAIN_CONF="$ssh_dir/sshd_config"
        SSHD_CONFIG_DIR="$ssh_dir/sshd_config.d"
        SSHD_VPSBOX_PORT_CONF="$SSHD_CONFIG_DIR/00-vpsbox-ssh-port.conf"
        SSHD_VPSBOX_HARDENING_CONF="$SSHD_CONFIG_DIR/01-vpsbox-ssh-hardening.conf"
        printf '%s\n' original > "$SSHD_MAIN_CONF"
        printf '%s\n' 'Port 23333' > "$SSHD_VPSBOX_PORT_CONF"

        create_ssh_restore_snapshot snapshot
        [[ "$snapshot" == "$(ssh_restore_snapshot_root)"/restore.* ]] ||
            fail "SSH 恢复快照必须位于 vpsbox 持久状态目录"
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
        assert_eq 'dns bbr ipv4_priority fail2ban journald ntp' \
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

test_ntp_restore_requires_complete_current_metadata() {
    assert_ntp_restore_rejects_metadata missing \
        "缺少当前格式的 NTP 文件备份状态时恢复必须失败"
}

test_ntp_restore_rejects_invalid_current_metadata() {
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

test_fail2ban_restore_requires_complete_service_metadata() {
    assert_fail2ban_restore_rejects_metadata missing \
        "缺少当前格式的 Fail2ban 服务状态时恢复必须失败"
}

test_fail2ban_restore_rejects_invalid_service_metadata() {
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
        assert_file_contains "$output" '无记录：4 项'
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
        change_restore_state
        chrony_sources_are_current
        enable_bbr_fq
        ensure_public_config_dir
        set_main_ssh_port_directives
        ensure_sshd_dropin_include
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
        show_vpsbox_changes
        restore_recorded_ntp_change
        ssh_restore_snapshot_path_allowed
        ssh_restore_snapshot_path_is_secure
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
        test_ntp_rejects_dangling_config_before_tracking_or_install
        test_atomic_snapshot_restore_move_failure_preserves_target
        test_debian_update_stops_after_first_failure
        test_debian_update_uses_upgrade_timeout
        test_debian_upgrade_failure_skips_autoremove
        test_alpine_update_uses_bounded_steps
        test_ntp_package_rollback_restores_timesyncd
        test_chrony_source_layout_detection
        test_enable_ntp_healthy_is_noop
        test_enable_ntp_rejects_incomplete_existing_metadata_before_backup
        test_ntp_unsynchronized_status_is_nonfatal
        test_ntp_service_drift_uses_light_repair
        test_ntp_light_repair_reports_restore_outcome
        test_enable_ntp_failure_stages_enter_runtime_rollback
        test_bbr_fq_healthy_is_noop
        test_bbr_fq_runtime_drift_uses_light_repair
        test_unsupported_kernel_leaves_no_phantom_pending_change
        test_failed_bbr_runtime_restore_keeps_recovery_transaction
        test_journald_healthy_is_noop
        test_journald_apply_and_failed_restart_restore_previous_config
        test_first_ssh_port_rollback_clears_tracking
        test_first_ssh_hardening_rollback_clears_tracking
        test_existing_ssh_baseline_survives_later_rollback
        test_ssh_hardening_requires_listener_after_restart
        test_ssh_pre_mark_failure_cleans_first_baseline
        test_ssh_port_change_failure_stages_rollback_and_success_syncs_fail2ban
        test_runtime_cleanup_clears_interrupted_ssh_baseline
        test_failed_ssh_tracking_cleanup_remains_retryable
        test_stale_unapplied_ssh_baseline_is_removed_on_next_run
        test_absent_resolv_conf_is_created_successfully
        test_systemd_resolved_restart_and_verification_failures_rollback
        test_systemd_resolved_rollback_failure_is_reported
        test_sshd_include_only_activates_vpsbox_files
        test_main_ssh_port_rewrite_handles_case_and_match_blocks
        test_main_ssh_port_is_inserted_before_match_without_global_port
        test_active_ufw_and_firewalld_unrecognized_rules_warn
        test_unrecognized_local_firewall_rule_still_requires_exact_yes
        test_selinux_ssh_port_range_is_validated
        test_enabled_inactive_ssh_socket_is_detected
        test_multiple_ssh_socket_streams_are_parsed
        test_ssh_restore_does_not_require_current_config_to_parse
        test_failed_ssh_restore_preserves_retry_snapshot
        test_ssh_config_publish_failure_preserves_target
        test_ssh_restore_snapshot_integrity_is_verified
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
        test_ntp_restore_requires_complete_current_metadata
        test_ntp_restore_rejects_invalid_current_metadata
        test_fail2ban_restore_requires_complete_service_metadata
        test_fail2ban_restore_rejects_invalid_service_metadata
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
