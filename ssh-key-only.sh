#!/usr/bin/env bash
# 兼容旧版独立入口：本地仓库优先调用模块；远程进程替换则自动下载模块。
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [[ -f "$SCRIPT_DIR/modules/ssh.sh" ]]; then
  exec bash "$SCRIPT_DIR/modules/ssh.sh" "$@"
fi

command -v curl >/dev/null 2>&1 || { echo "需要 curl 才能下载 SSH 模块" >&2; exit 1; }
tmp_file=$(mktemp)
cleanup() { rm -f "$tmp_file"; }
trap cleanup EXIT INT TERM
curl --fail --silent --show-error --location --connect-timeout 10 --max-time 120 \
  "https://raw.githubusercontent.com/dagenduizhanga/vps-init/main/modules/ssh.sh" -o "$tmp_file"
bash "$tmp_file" "$@"
