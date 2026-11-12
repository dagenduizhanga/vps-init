#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$ROOT_DIR/lib/common.sh"

show_help() {
  cat <<'EOF'
vps-init - 轻量级 VPS 初始化工具

用法：
  bash vps-init.sh                 打开交互菜单
  bash vps-init.sh ssh             配置 SSH 密钥登录
  bash vps-init.sh system          一键基础初始化（上海时区、自动校时、常用工具）
  bash vps-init.sh security        自动检查安全状态，必要时询问是否启用防火墙
  bash vps-init.sh status          查看系统状态
  bash vps-init.sh --help          显示帮助
  bash vps-init.sh --version       显示版本
EOF
}

show_status() {
  printf '\n%s\n' "${C_BOLD}VPS 系统状态${C_RESET}"
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    printf '系统：%s\n' "${PRETTY_NAME:-未知}"
  fi
  printf '内核：%s\n' "$(uname -r)"
  printf '架构：%s\n' "$(uname -m)"
  printf '主机名：%s\n' "$(hostname 2>/dev/null || printf '未知')"
  if command_exists systemctl; then
    if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then
      log_ok 'SSH 服务正在运行'
    else
      log_warn '无法通过 systemd 确认 SSH 服务正在运行'
    fi
  fi
}

show_menu() {
  local choice
  while true; do
    printf '\n%s\n' "${C_BOLD}       VPS INIT${C_RESET}"
    printf '%s\n' '       VPS 初始化工具' '' '  1. SSH 密钥登录与安全配置' '  2. 系统初始化' '  3. 安全加固' '  4. 查看系统状态' '' '  0. 退出' ''
    [[ -r /dev/tty ]] || die '交互菜单需要终端，请使用命令行子命令'
    printf '请选择功能：' >/dev/tty
    IFS= read -r choice </dev/tty || return 0
    case "$choice" in
      1) bash "$ROOT_DIR/modules/ssh.sh" ;;
      2) bash "$ROOT_DIR/modules/system.sh" ;;
      3) bash "$ROOT_DIR/modules/security.sh" ;;
      4) show_status ;;
      0) return 0 ;;
      *) log_warn '选项无效，请重新输入' ;;
    esac
  done
}

main() {
  local action="${1:-menu}"
  shift || true
  case "$action" in
    menu) show_menu ;;
    ssh) bash "$ROOT_DIR/modules/ssh.sh" "$@" ;;
    system) bash "$ROOT_DIR/modules/system.sh" "$@" ;;
    security) bash "$ROOT_DIR/modules/security.sh" "$@" ;;
    status) show_status ;;
    -h|--help|help) show_help ;;
    --version) printf 'vps-init %s\n' "$VPS_INIT_VERSION" ;;
    *) log_error "未知命令：$action"; show_help; return 2 ;;
  esac
}
main "$@"
