#!/usr/bin/env bash
set -euo pipefail

exec bash <(curl -fsSL https://raw.githubusercontent.com/QXTianPing/vpsbox/main/vpsbox.sh) "$@"
