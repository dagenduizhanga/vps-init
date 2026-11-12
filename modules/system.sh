#!/usr/bin/env bash
# 系统初始化：更新软件包、设置时区、时间同步和安装常用工具。
set -Eeuo pipefail
MODULE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$MODULE_DIR/../lib/common.sh"

show_time_sync_status() {
  if command_exists timedatectl; then
    local ntp synced
    ntp=$(timedatectl show -p NTP --value 2>/dev/null || true)
    synced=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)
    printf 'NTP 自动同步：%s\n' "${ntp:-未知}"
    printf '系统时钟已同步：%s\n' "${synced:-未知}"
    timedatectl show-timesync --all 2>/dev/null | grep -E '^(ServerName|ServerAddress|PollIntervalUSec|Frequency):' || true
  elif command_exists chronyc; then
    echo "检测到 Chrony 时间同步服务："
    chronyc tracking 2>/dev/null || true
  elif command_exists ntpq; then
    echo "检测到 NTP 服务："
    ntpq -pn 2>/dev/null || true
  else
    echo "未检测到可识别的时间同步服务。"
  fi
}

show_system_info() {
  detect_os
  printf '\n系统：%s\n' "$OS_NAME"
  printf '包管理器：'
  if command_exists apt-get; then echo APT; elif command_exists dnf; then echo DNF; elif command_exists yum; then echo YUM; elif command_exists apk; then echo APK; else echo 未识别; fi
  printf '时区：%s\n' "$(timedatectl show -p Timezone --value 2>/dev/null || date +%Z)"
  show_time_sync_status
  printf '可用磁盘：\n'
  df -h / 2>/dev/null | tail -n 1
}

update_system() {
  require_root
  detect_os
  local manager
  if command_exists apt-get; then manager=apt
  elif command_exists dnf; then manager=dnf
  elif command_exists yum; then manager=yum
  elif command_exists apk; then manager=apk
  else die "暂不支持此系统的软件包管理器"; return 1; fi
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

choose_timezone() {
  local choice zone
  local current
  current=$(timedatectl show -p Timezone --value 2>/dev/null || date +%Z)
  echo
  echo "当前时区：$current"
  echo "请选择要设置的时区："
  echo "  1. 中国标准时间（北京时间，Asia/Shanghai）[默认]"
  echo "  2. 新加坡时间（Asia/Singapore）"
  echo "  3. 协调世界时（UTC）"
  echo "  4. 自定义时区"
  echo "  0. 返回，不修改"
  printf '请选择 [1]：' >/dev/tty
  IFS= read -r choice </dev/tty || return 1
  case "${choice:-1}" in
    1) zone=Asia/Shanghai ;;
    2) zone=Asia/Singapore ;;
    3) zone=Etc/UTC ;;
    4)
      printf '请输入时区名称（例如 Europe/London）：' >/dev/tty
      IFS= read -r zone </dev/tty || return 1
      ;;
    0) log_info "已取消，时区未修改。"; return 0 ;;
    *) log_warn "选项无效"; return 1 ;;
  esac
  set_timezone "$zone"
}

set_timezone() {
  require_root
  local zone="${1:-}"
  if [[ -z "$zone" ]]; then
    choose_timezone
    return $?
  fi
  [[ "$zone" =~ ^[A-Za-z0-9_+/-]+$ ]] || die "时区格式不正确"
  [[ -e "/usr/share/zoneinfo/$zone" ]] || die "系统中不存在时区：$zone"
  echo "即将把系统时区设置为：$zone"
  confirm "确认修改时区？" || { log_info "已取消。"; return 0; }
  if command_exists timedatectl; then
    timedatectl set-timezone "$zone"
  else
    ln -snf "/usr/share/zoneinfo/$zone" /etc/localtime
  fi
  log_ok "时区已设置为 $zone"
  echo "时区只决定本地时间的显示方式；系统时钟自动校准由 NTP 时间同步负责。"
}

enable_time_sync() {
  require_root
  if ! command_exists timedatectl; then
    echo "当前系统没有 timedatectl，无法通过统一接口启用 NTP。"
    show_time_sync_status
    echo "请使用系统对应的 Chrony 或 NTP 服务管理方式。"
    return 1
  fi
  echo "将启用系统 NTP 自动时间同步。"
  echo "系统会通过网络时间服务持续校准时钟，不是每天只校准一次。"
  confirm "确认启用 NTP 自动同步？" || { log_info "已取消，设置未修改。"; return 0; }
  timedatectl set-ntp true
  log_ok "已向系统请求启用 NTP 自动同步"
  echo
  show_time_sync_status
  echo "提示：首次同步可能需要等待一段时间；请确保服务器可以访问网络时间服务器。"
}

install_tools() {
  require_root
  detect_os
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
    printf '%s\n' '  1. 查看系统信息' '  2. 更新系统软件包' '  3. 设置时区' '  4. 安装常用工具' '  5. 启用 NTP 自动时间同步' '' '  0. 返回'
    printf '请选择：' >/dev/tty
    IFS= read -r choice </dev/tty || return 0
    case "$choice" in
      1) show_system_info ;;
      2) update_system ;;
      3) set_timezone ;;
      4) install_tools ;;
      5) enable_time_sync ;;
      0) return 0 ;;
      *) log_warn "选项无效" ;;
    esac
  done
}

main() {
  case "${1:-menu}" in
    menu) show_menu ;;
    status) show_system_info ;;
    update) update_system ;;
    timezone) set_timezone "${2:-}" ;;
    tools) install_tools ;;
    ntp) enable_time_sync ;;
    -h|--help) echo "用法：system.sh [status|update|timezone [时区]|tools|ntp]" ;;
    *) die "未知系统模块命令：$1"; return 2 ;;
  esac
}
main "$@"
