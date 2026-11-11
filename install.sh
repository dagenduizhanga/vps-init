#!/usr/bin/env bash
# 下载仓库源码到临时目录并启动；不在服务器上安装常驻文件。
set -Eeuo pipefail
REPO_TARBALL='https://github.com/dagenduizhanga/vps-init/archive/refs/heads/main.tar.gz'
command -v curl >/dev/null 2>&1 || { echo '请先安装 curl' >&2; exit 1; }
command -v tar >/dev/null 2>&1 || { echo '请先安装 tar' >&2; exit 1; }
临时目录=$(mktemp -d)
清理() { rm -rf "$临时目录"; }
trap 清理 EXIT INT TERM
curl --fail --silent --show-error --location --connect-timeout 10 --max-time 120 "$REPO_TARBALL" -o "$临时目录/source.tar.gz"
tar -xzf "$临时目录/source.tar.gz" -C "$临时目录"
源码目录=$(find "$临时目录" -mindepth 1 -maxdepth 1 -type d -print -quit)
[[ -n "$源码目录" && -f "$源码目录/vps-init.sh" ]] || { echo '下载的项目结构不完整' >&2; exit 1; }
exec bash "$源码目录/vps-init.sh" "$@"
