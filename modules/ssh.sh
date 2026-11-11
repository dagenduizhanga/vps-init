#!/usr/bin/env bash
# SSH 模块兼容入口：迁移期间完整复用原有向导，避免功能回归。
set -Eeuo pipefail
MODULE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
exec bash "$MODULE_DIR/../ssh-key-only.sh" "$@"
