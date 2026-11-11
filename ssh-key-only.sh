#!/usr/bin/env bash
# 兼容旧版独立入口：实际实现已迁移到 modules/ssh.sh。
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
exec bash "$SCRIPT_DIR/modules/ssh.sh" "$@"
