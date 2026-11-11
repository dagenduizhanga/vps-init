#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

for script in "$ROOT_DIR/install.sh" "$ROOT_DIR/vps-init.sh" "$ROOT_DIR"/lib/*.sh "$ROOT_DIR"/modules/*.sh "$ROOT_DIR/ssh-key-only.sh; do
  [[ -f "$script" ]] && bash -n "$script"
done

help_output=$(bash "$ROOT_DIR/vps-init.sh" --help)
grep -q '轻量级 VPS 初始化工具' <<<"$help_output"
grep -q 'system' <<<"$help_output"
grep -q 'security' <<<"$help_output"

status_output=$(bash "$ROOT_DIR/vps-init.sh" status)
grep -q 'VPS 系统状态' <<<"$status_output"

system_output=$(bash "$ROOT_DIR/modules/system.sh" status)
grep -q '系统：' <<<"$system_output"

security_output=$(bash "$ROOT_DIR/modules/security.sh" status)
grep -q '防火墙状态' <<<"$security_output"

ssh_help=$(bash "$ROOT_DIR/ssh-key-only.sh" --help)
grep -q -- '--undo' <<<"$ssh_help"

printf '%s\\n' '基础语法、入口和模块状态测试通过。'
