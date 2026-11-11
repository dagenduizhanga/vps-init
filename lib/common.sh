#!/usr/bin/env bash
# vps-init 公共函数库
VPS_INIT_VERSION="0.3.0"
export VPS_INIT_VERSION
if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else C_RED=''; C_GREEN=''; C_YELLOW=''; C_BOLD=''; C_RESET=''; fi
export C_RED C_GREEN C_YELLOW C_BOLD C_RESET
log_info() { printf '%s\n' "$*"; }
log_ok() { printf '%s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
log_warn() { printf '%s⚠%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
log_error() { printf '%s✗%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die() { log_error "$*"; return 1; }
command_exists() { command -v "$1" >/dev/null 2>&1; }
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 运行此模块"; }
confirm() {
  local answer
  [[ -r /dev/tty ]] || { log_warn "当前没有交互终端，已取消操作"; return 1; }
  printf '%s [y/N] ' "$1" >/dev/tty
  IFS= read -r answer </dev/tty || return 1
  [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}
detect_os() {
  [[ -r /etc/os-release ]] || die "无法识别系统：缺少 /etc/os-release"
  # shellcheck source=/dev/null
  . /etc/os-release
  OS_ID=${ID:-unknown}; OS_FAMILY=${ID_LIKE:-$OS_ID}; OS_NAME=${PRETTY_NAME:-$OS_ID}
  export OS_ID OS_FAMILY OS_NAME
}
detect_ssh_port() {
  local port
  if command_exists sshd; then port=$(sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}'); fi
  printf '%s\n' "${port:-22}"
}
