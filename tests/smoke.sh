#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

bash -n "$ROOT_DIR/install.sh"
bash -n "$ROOT_DIR/vps-init.sh"
bash -n "$ROOT_DIR/lib/common.sh"
for script in "$ROOT_DIR"/modules/*.sh "$ROOT_DIR"/ssh-key-only.sh; do
  [[ -f "$script" ]] && bash -n "$script"
done

help_output=$(bash "$ROOT_DIR/vps-init.sh" --help)
grep -q '轻量级 VPS 初始化工具' <<<"$help_output"
status_output=$(bash "$ROOT_DIR/vps-init.sh" status)
grep -q 'VPS 系统状态' <<<"$status_output"
printf '%s\n' '基础语法与入口冒烟测试通过。'
