#!/usr/bin/env bash
# 旧版入口，保留兼容：等同于 vps-init ssh，参数原样转发。
# 在仓库里运行时直接调用模块；通过 bash <(curl …) 远程运行时，经 install.sh 下载完整项目。
set -Eeuo pipefail
dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [[ -f $dir/modules/ssh.sh ]]; then
  exec bash "$dir/modules/ssh.sh" "$@"
fi
installer=$(curl --proto '=https' --tlsv1.2 -fsSL --connect-timeout 10 --max-time 60 \
  "https://raw.githubusercontent.com/dagenduizhanga/vps-init/${VPS_INIT_REF:-main}/install.sh") ||
  { echo "下载 vps-init 失败，请检查网络" >&2; exit 1; }
exec bash -c "$installer" install.sh ssh "$@"
