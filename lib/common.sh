#!/usr/bin/env bash
# Shared helpers for vps-init. Compatible with Bash 4+.
VPS_INIT_VERSION="0.2.0"
if [[ -t 1 ]]; then C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'; else C_RED=''; C_GREEN=''; C_YELLOW=''; C_BOLD=''; C_RESET=''; fi
log_info() { printf '%s\n' "$*"; }
log_ok() { printf '%s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
log_warn() { printf '%s⚠%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
log_error() { printf '%s✗%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die() { log_error "$*"; return 1; }
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 运行此模块"; }
command_exists() { command -v "$1" >/dev/null 2>&1; }
confirm() { local answer; [[ -r /dev/tty ]] || return 1; printf '%s [y/N] ' "$1" >/dev/tty; IFS= read -r answer </dev/tty || return 1; [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]; }
