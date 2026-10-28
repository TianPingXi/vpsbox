#!/usr/bin/env bash
# 可选原生验收；仅使用调用者提供并已校验来源的内核和 Go 探针。
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../vpsbox.sh
source "$root/vpsbox.sh"
: "${SINGBOX_NATIVE_BINARY:?需提供已验证的 sing-box 绝对路径}"
: "${VPSBOX_NATIVE_PROBE:?需提供已编译的 singbox-probe 绝对路径}"
work="$(mktemp -d /tmp/vpsbox-native.XXXXXX)"
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/bin"
ln -s "$SINGBOX_NATIVE_BINARY" "$work/bin/sing-box"
export PATH="$work/bin:$PATH"
export VPSBOX_TEST_MODE=1
RUNTIME_DIR="$work/runtime"
mkdir "$RUNTIME_DIR"
CONFIG_DIR="$work/config"
NODE_CONFIG_DIR="$CONFIG_DIR/vpsbox.d"
# shellcheck disable=SC2034 # 被 source 的生成函数使用。
SS_CONFIG_PATH="$NODE_CONFIG_DIR/10-ss.json"
# shellcheck disable=SC2034 # 被 source 的生成函数使用。
VLESS_CONFIG_PATH="$NODE_CONFIG_DIR/20-vless-reality.json"
sing-box version | head -1
keys="$(generate_reality_keypair)"
private_key="${keys%%$'\n'*}"
uuid="$(sing-box generate uuid)"
id="$(generate_node_config_id)"
password="$(sing-box generate rand --base64 16)"
short_id="$(sing-box generate rand --hex 8)"
if [ -n "${CN_NATIVE_RULE_FILE:-}" ]; then
    validate_egress_rule_content "$CN_NATIVE_RULE_FILE" "$work/cn-decoded.json"
    printf 'PASS upstream CN rule-set validation\n'
fi
if [ -n "${CN_NATIVE_DOMAIN_FILE:-}" ]; then
    validate_egress_rule_content "$CN_NATIVE_DOMAIN_FILE" "$work/domain-decoded.json" domain
    printf 'PASS upstream official domain rule-set validation\n'
    if [ -n "${CN_NATIVE_RULE_FILE:-}" ]; then
        (
            download_egress_rules() {
                case "$2" in
                    ip) cp -- "$CN_NATIVE_RULE_FILE" "$1" ;;
                    domain) cp -- "$CN_NATIVE_DOMAIN_FILE" "$1" ;;
                    *) return 1 ;;
                esac
            }
            build_egress_rules "$work/upstream-combined.srs"
            printf 'PASS upstream combined rule-set compile and validation\n'
            for destination in www.baidu.com www.qq.com www.bilibili.com www.taobao.com www.jd.com 223.5.5.5 2400:3200::1; do
                result="$(sing-box rule-set match -f binary "$work/upstream-combined.srs" "$destination" 2>&1)"
                [[ "$result" == 'match rules.['* ]] || { printf 'Missing upstream match: %s\n' "$destination" >&2; exit 1; }
                printf 'PASS upstream match %s\n' "$destination"
            done
            for destination in github.com www.cloudflare.com www.google.com; do
                result="$(sing-box rule-set match -f binary "$work/upstream-combined.srs" "$destination" 2>&1)"
                [ -z "$result" ] || { printf 'Unexpected upstream match: %s\n' "$destination" >&2; exit 1; }
                printf 'PASS upstream no match %s\n' "$destination"
            done
        )
    fi
fi
printf '%s\n' '{"version":1,"rules":[{"ip_cidr":["127.0.0.2/32","::1/128"]},{"domain_suffix":["blocked-domain.native.test"],"domain_regex":["^cn[0-9]+[.]native[.]test$"]}]}' > "$work/test-cn.json"
sing-box rule-set compile "$work/test-cn.json" -o "$work/test-cn.srs"
for family in ipv4 ipv6; do
    listen_mode() { printf '%s\n' "$family"; }
    write_config 29101 "$password" "$id"
    write_vless_reality_config 29102 "$uuid" native.example "$private_key" "$short_id" "$id"
    sing-box check -C "$NODE_CONFIG_DIR"
    "$VPSBOX_NATIVE_PROBE" "$SINGBOX_NATIVE_BINARY" "$NODE_CONFIG_DIR" "$family"
    render_egress_policy_config "$(egress_policy_tags "$NODE_CONFIG_DIR")" "$work/test-cn.srs" > "$NODE_CONFIG_DIR/30-egress-policy.json"
    sing-box check -C "$NODE_CONFIG_DIR"
    "$VPSBOX_NATIVE_PROBE" "$SINGBOX_NATIVE_BINARY" "$NODE_CONFIG_DIR" "$family" policy
    rm -- "$NODE_CONFIG_DIR/30-egress-policy.json"
done
