#!/usr/bin/env bash
# vps-init 远程启动器：下载源码到临时目录后运行，结束后自动清理，不在服务器上留下文件。
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/dagenduizhanga/vps-init/main/install.sh) [命令]
#
# 固定到某个版本（分支、标签或提交），避免仓库更新带来意外变化：
#   VPS_INIT_REF=<版本> bash <(curl -fsSL https://raw.githubusercontent.com/dagenduizhanga/vps-init/<版本>/install.sh)
set -Eeuo pipefail

((BASH_VERSINFO[0] >= 4)) || { echo "需要 Bash 4 或更高版本" >&2; exit 1; }
for cmd in curl tar; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "缺少 $cmd，请先安装" >&2; exit 1; }
done

export VPS_INIT_REF=${VPS_INIT_REF:-main}
url="https://codeload.github.com/dagenduizhanga/vps-init/tar.gz/$VPS_INIT_REF"
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT INT TERM

curl --proto '=https' --tlsv1.2 -fsSL --retry 2 --connect-timeout 10 --max-time 120 "$url" |
  tar -xz -C "$tmp_dir" --strip-components 1 ||
  { echo "下载 vps-init（$VPS_INIT_REF）失败，请检查网络" >&2; exit 1; }
[[ -f $tmp_dir/vps-init.sh ]] || { echo "下载的文件不完整" >&2; exit 1; }

bash "$tmp_dir/vps-init.sh" "$@"
