#!/usr/bin/env bash
# 下载仓库源码到临时目录并启动；不在服务器上安装常驻文件。
set -Eeuo pipefail
REPO_TARBALL='https://github.com/dagenduizhanga/vps-init/archive/refs/heads/main.tar.gz'
command -v curl >/dev/null 2>&1 || { echo '请先安装 curl' >&2; exit 1; }
command -v tar >/dev/null 2>&1 || { echo '请先安装 tar' >&2; exit 1; }
tmp_dir=$(mktemp -d)
cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT INT TERM
curl --fail --silent --show-error --location --connect-timeout 10 --max-time 120 "$REPO_TARBALL" -o "$tmp_dir/source.tar.gz"
tar -xzf "$tmp_dir/source.tar.gz" -C "$tmp_dir"
source_dir=$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d -print -quit)
[[ -n "$source_dir" && -f "$source_dir/vps-init.sh" ]] || { echo '下载的项目结构不完整' >&2; exit 1; }
bash "$source_dir/vps-init.sh" "$@"
