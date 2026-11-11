#!/usr/bin/env bash
# 系统初始化：更新软件包、设置时区和安装常用工具。
set -Eeuo pipefail
MODULE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$MODULE_DIR/../lib/common.sh"
show_system_info() {
  detect_os
  printf '\n系统：%s\n' "$OS_NAME"
  printf '包管理器：'
  if command_exists apt-get; then echo APT; elif command_exists dnf; then echo DNF; elif command_exists yum; then echo YUM; elif command_exists apk; then echo APK; else echo 未识别; fi
  printf '时区：%s\n' "$(timedatectl show -p Timezone --value 2>/dev/null || date +%Z)"
  printf '可用磁盘：\n'; df -h / 2>/dev/null | tail -n 1
}
update_system() {
  require_root; detect_os
  local manager
  if command_exists apt-get; then manager=apt; elif command_exists dnf; then manager=dnf; elif command_exists yum; then manager=yum; elif command_exists apk; then manager=apk; else die "暂不支持此系统的软件包管理器"; return 1; fi
  echo "即将更新系统软件包（$manager）。此操作可能更新内核或重启服务。"
  confirm "确认开始系统更新？" || { log_info "已取消，系统未修改。"; return 0; }
  case "$manager" in
    apt) export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get -y upgrade ;;
    dnf) dnf -y upgrade ;;
    yum) yum -y update ;;
    apk) apk update && apk upgrade ;;
  esac
  log_ok "系统软件包更新完成"
}
set_timezone() {
  require_root
  local zone="${1:-}"
  if [[ -z "$zone" ]]; then
    printf '请输入时区名称（例如 Asia/Shanghai、Asia/Singapore）：'
    [[ -r /dev/tty ]] || die "非交互模式请提供时区参数"; IFS= read -r zone </dev/tty
  fi
  [[ "$zone" =~ ^[A-Za-z0-9_+/-]+$ ]] || die "时区格式不正确"
  [[ -e "/usr/share/zoneinfo/$zone" ]] || die "系统中不存在时区：$zone"
  echo "即将把系统时区设置为：$zone"
  confirm "确认修改时区？" || { log_info "已取消。"; return 0; }
  if command_exists timedatectl; then timedatectl set-timezone "$zone"; else ln -snf "/usr/share/zoneinfo/$zone" /etc/localtime; fi
  log_ok "时区已设置为 $zone"
}
install_tools() {
  require_root; detect_os
  local -a packages=(curl wget git vim htop unzip)
  echo "即将安装常用工具：${packages[*]}"
  confirm "确认安装？" || { log_info "已取消。"; return 0; }
  if command_exists apt-get; then export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get install -y "${packages[@]}"
  elif command_exists dnf; then dnf install -y "${packages[@]}"
  elif command_exists yum; then yum install -y "${packages[@]}"
  elif command_exists apk; then apk add "${packages[@]}"
  else die "暂不支持此系统的软件包管理器"; return 1; fi
  log_ok "常用工具安装完成"
}
show_menu() {
  local choice
  while true; do
    printf '\n%s\n' "${C_BOLD}系统初始化${C_RESET}"
    printf '%s\n' '  1. 查看系统信息' '  2. 更新系统软件包' '  3. 设置时区' '  4. 安装常用工具' '' '  0. 返回'
    printf '请选择：' >/dev/tty; IFS= read -r choice </dev/tty || return 0
    case "$choice" in 1) show_system_info ;; 2) update_system ;; 3) set_timezone ;; 4) install_tools ;; 0) return 0 ;; *) log_warn "选项无效" ;; esac
  done
}
main() {
  case "${1:-menu}" in menu) show_menu ;; status) show_system_info ;; update) update_system ;; timezone) set_timezone "${2:-}" ;; tools) install_tools ;; -h|--help) echo "用法：system.sh [status|update|timezone 时区|tools]" ;; *) die "未知系统模块命令：$1"; return 2 ;; esac
}
main "$@"
