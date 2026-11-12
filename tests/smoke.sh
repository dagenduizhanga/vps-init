#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

for script in "$ROOT_DIR/install.sh" "$ROOT_DIR/vps-init.sh" "$ROOT_DIR"/lib/*.sh "$ROOT_DIR"/modules/*.sh "$ROOT_DIR/ssh-key-only.sh"; do
  [[ -f "$script" ]] && bash -n "$script"
done

help_output=$(bash "$ROOT_DIR/vps-init.sh" --help)
grep -q '轻量级 VPS 初始化工具' <<<"$help_output"
grep -q 'system' <<<"$help_output"
grep -q 'security' <<<"$help_output"

version_output=$(bash "$ROOT_DIR/vps-init.sh" --version)
grep -q 'vps-init 0.3.1' <<<"$version_output"

status_output=$(bash "$ROOT_DIR/vps-init.sh" status)
grep -q 'VPS 系统状态' <<<"$status_output"

source "$ROOT_DIR/lib/common.sh"
SSH_CONNECTION='198.51.100.10 54321 192.0.2.20 2222'
grep -q '^2222
grep -q '系统：' <<<"$system_output"
grep -q 'NTP 自动同步' <<<"$system_output"

system_help=$(bash "$ROOT_DIR/modules/system.sh" --help)
grep -q 'init' <<<"$system_help"
grep -q 'Asia/Shanghai' <<<"$system_help"

security_output=$(bash "$ROOT_DIR/modules/security.sh" status)
grep -q '防火墙状态' <<<"$security_output"

ssh_help=$(bash "$ROOT_DIR/ssh-key-only.sh" --help)
grep -q -- '--undo' <<<"$ssh_help"

echo '基础语法、入口和模块状态测试通过。'
 < <(detect_ssh_port)

system_output=$(bash "$ROOT_DIR/modules/system.sh" status)
grep -q '系统：' <<<"$system_output"
grep -q 'NTP 自动同步' <<<"$system_output"

system_help=$(bash "$ROOT_DIR/modules/system.sh" --help)
grep -q 'init' <<<"$system_help"
grep -q 'Asia/Shanghai' <<<"$system_help"

security_output=$(bash "$ROOT_DIR/modules/security.sh" status)
grep -q '防火墙状态' <<<"$security_output"

ssh_help=$(bash "$ROOT_DIR/ssh-key-only.sh" --help)
grep -q -- '--undo' <<<"$ssh_help"

echo '基础语法、入口和模块状态测试通过。'
