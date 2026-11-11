#!/usr/bin/env bash
# 安全检查与防火墙配置。默认只检查，不自动启用防火墙。
set -Eeuo pipefail
MODULE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$MODULE_DIR/../lib/common.sh"
firewall_status() {
  if command_exists ufw; then ufw status verbose
  elif command_exists firewall-cmd; then firewall-cmd --state 2>/dev/null || true; firewall-cmd --list-all 2>/dev/null || true
  else echo "未检测到 UFW 或 Firewalld"; fi
}
security_report() {
  detect_os
  printf '\n系统：%s\n' "$OS_NAME"
  printf 'SSH 服务端口：%s\n' "$(detect_ssh_port)"
  if command_exists sshd; then
    local effective; effective=$(sshd -T 2>/dev/null || true)
    grep -E '^(permitrootlogin|passwordauthentication|pubkeyauthentication|port) ' <<<"$effective" || true
  else log_warn "未检测到 sshd"; fi
  printf '\n防火墙状态：\n'; firewall_status
}
enable_firewall() {
  require_root
  local port; port=$(detect_ssh_port)
  [[ "$port" =~ ^[0-9]+$ ]] && ((port > 0 && port <= 65535)) || die "无法确定 SSH 端口，拒绝启用防火墙"
  echo "启用前将先放行当前 SSH TCP 端口：$port"
  echo "注意：云厂商安全组不受本工具管理，请确认云端规则也允许 SSH。"
  if command_exists ufw; then
    echo "将执行：ufw allow $port/tcp；ufw --force enable"
    confirm "确认配置并启用 UFW？" || { log_info "已取消，防火墙未修改。"; return 0; }
    ufw allow "$port/tcp"; ufw --force enable; ufw status verbose
  elif command_exists firewall-cmd; then
    echo "将永久放行 SSH 端口 $port/tcp，并启用 Firewalld。"
    confirm "确认配置并启用 Firewalld？" || { log_info "已取消，防火墙未修改。"; return 0; }
    systemctl enable --now firewalld
    firewall-cmd --permanent --add-port="$port/tcp"; firewall-cmd --add-port="$port/tcp"; firewall-cmd --reload; firewall-cmd --list-all
  else die "未安装 UFW 或 Firewalld。本工具不会自动安装防火墙。"; return 1; fi
  log_ok "防火墙已配置。请保持当前 SSH 会话，并另开窗口验证登录。"
}
show_menu() {
  local choice
  while true; do
    printf '\n%s\n' "${C_BOLD}安全加固${C_RESET}"
    printf '%s\n' '  1. 查看 SSH 与防火墙安全状态' '  2. 配置并启用防火墙（谨慎）' '' '  0. 返回'
    printf '请选择：' >/dev/tty; IFS= read -r choice </dev/tty || return 0
    case "$choice" in 1) security_report ;; 2) enable_firewall ;; 0) return 0 ;; *) log_warn "选项无效" ;; esac
  done
}
main() {
  case "${1:-menu}" in menu) show_menu ;; status) security_report ;; firewall) enable_firewall ;; -h|--help) echo "用法：security.sh [status|firewall]" ;; *) die "未知安全模块命令：$1"; return 2 ;; esac
}
main "$@"
