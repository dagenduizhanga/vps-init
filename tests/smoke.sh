#!/usr/bin/env bash
# 冒烟测试：语法、命令入口、帮助与状态输出、公共函数。不需要 root，也不会修改系统。
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export NO_COLOR=1

failed=0
check() {
  local name=$1
  shift
  if "$@" >/dev/null 2>&1; then printf '  ✓ %s\n' "$name"; else printf '  ✗ %s\n' "$name"; failed=$((failed + 1)); fi
}
contains() { grep -qF -- "$2" <<<"$1"; }
is() { [[ $1 == "$2" ]]; }

for script in "$ROOT"/install.sh "$ROOT"/vps-init.sh "$ROOT"/ssh-key-only.sh "$ROOT"/lib/*.sh "$ROOT"/modules/*.sh "$ROOT"/tests/*.sh; do
  check "语法：${script#"$ROOT"/}" bash -n "$script"
done

# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
check "--version 与代码中的版本一致" is "$(bash "$ROOT/vps-init.sh" --version)" "vps-init $VPS_INIT_VERSION"
help=$(bash "$ROOT/vps-init.sh" --help)
for cmd in system ssh firewall update status; do check "帮助里有 $cmd 命令" contains "$help" "$cmd"; done
check "未知命令返回 2" bash -c "bash '$ROOT/vps-init.sh' no-such-command; [[ \$? == 2 ]]"
for module in system ssh firewall; do check "模块 $module 有帮助" bash "$ROOT/modules/$module.sh" --help; done
check "旧入口 ssh-key-only.sh 转发到模块" contains "$(bash "$ROOT/ssh-key-only.sh" --help)" "--undo"

status=$(bash "$ROOT/vps-init.sh" status 2>&1)
for section in 系统 SSH 防火墙 时区 自动校时; do check "状态页包含「$section」" contains "$status" "$section"; done

check "中文按 2 列对齐" is "$(ui_pad 防火墙 10)|" "防火墙    |"
check "中英混排对齐" is "$(ui_pad 'root 登录' 12)|" "root 登录   |"
check "SSH 端口取自当前连接" is "$(SSH_CONNECTION='198.51.100.10 54321 192.0.2.20 2222' detect_ssh_port)" 2222
check "端口无效时拒绝猜测" bash -c "source '$ROOT/lib/common.sh'; PATH=/nonexistent; SSH_CONNECTION='1 2 3 99999' detect_ssh_port; [[ \$? != 0 ]]"

printf '\n冒烟测试%s\n' "$( ((failed == 0)) && echo '全部通过' || echo "失败 $failed 项")"
((failed == 0))
