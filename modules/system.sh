#!/usr/bin/env bash
# 系统初始化：默认上海时区、自动时间同步，并补齐常用工具。
set -Eeuo pipefail
MODULE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$MODULE_DIR/../lib/common.sh"

APT_INDEX_UPDATED=0
apt_update_once() {
  if ((APT_INDEX_UPDATED == 0)); then
    apt-get update
    APT_INDEX_UPDATED=1
  fi
}

show_time_sync_status() {
  if command_exists timedatectl; then
    local ntp synced
    ntp=$(timedatectl show -p NTP --value 2>/dev/null || true)
    synced=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)
    printf 'NTP 自动同步：%s\n' "${ntp:-未知}"
    printf '系统时钟已同步：%s\n' "${synced:-未知}"
  elif command_exists chronyc; then
    echo "Chrony 时间同步状态："
    chronyc tracking 2>/dev/null || true
  else
    echo "未检测到时间同步服务"
  fi
}

show_system_info() {
  detect_os
  printf '\n系统：%s\n' "$OS_NAME"
  printf '包管理器：'
  if command_exists apt-get; then echo APT
  elif command_exists dnf; then echo DNF
  elif command_exists yum; then echo YUM
  elif command_exists apk; then echo APK
  else echo 未识别
  fi
  printf '时区：%s\n' "$(timedatectl show -p Timezone --value 2>/dev/null || date +%Z)"
  show_time_sync_status
  printf '可用磁盘：\n'
  df -h / 2>/dev/null | tail -n 1
}

set_timezone() {
  require_root
  local zone="${1:-Asia/Shanghai}"
  [[ "$zone" =~ ^[A-Za-z0-9_+/-]+$ ]] || { die "时区格式不正确：$zone"; return 1; }
  [[ -e "/usr/share/zoneinfo/$zone" ]] || { die "系统中不存在时区：$zone"; return 1; }

  local current
  current=$(timedatectl show -p Timezone --value 2>/dev/null || true)
  if [[ "$current" == "$zone" ]]; then
    log_ok "时区已经是 $zone，无需修改"
  elif command_exists timedatectl; then
    timedatectl set-timezone "$zone"
    log_ok "时区已设置为 $zone"
  else
    ln -snf "/usr/share/zoneinfo/$zone" /etc/localtime
    log_ok "时区已设置为 $zone"
  fi
}

install_chrony() {
  detect_os
  echo "系统没有可用的 NTP 客户端，正在安装 Chrony……"
  if command_exists apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    apt_update_once
    apt-get install -y chrony
  elif command_exists dnf; then
    dnf install -y chrony
  elif command_exists yum; then
    yum install -y chrony
  elif command_exists apk; then
    apk add chrony
  else
    die "无法自动安装 Chrony：不支持当前包管理器"
    return 1
  fi
}

start_chrony() {
  if command_exists systemctl; then
    if systemctl enable --now chrony 2>/dev/null || systemctl enable --now chronyd 2>/dev/null; then
      return 0
    fi
  elif command_exists rc-update && command_exists rc-service; then
    rc-update add chronyd default >/dev/null 2>&1 || true
    rc-service chronyd start
    return $?
  fi
  return 1
}

enable_time_sync() {
  require_root

  # 优先使用系统已有的 NTP 服务，不重复安装或替换。
  if command_exists chronyd; then
    if start_chrony; then
      log_ok "Chrony 已设置为开机启动并正在运行"
      return 0
    fi
    log_warn "检测到 Chrony，但无法启动服务"
    return 1
  fi

  # systemd 系统优先使用系统自带的 NTP 管理接口。
  if command_exists timedatectl && timedatectl set-ntp true 2>/dev/null; then
    local ntp
    ntp=$(timedatectl show -p NTP --value 2>/dev/null || true)
    if [[ "$ntp" == yes ]]; then
      log_ok "已启用系统 NTP 自动同步"
      return 0
    fi
  fi

  # 没有可用的系统 NTP 服务时，自动安装并启用 Chrony。
  install_chrony
  command_exists chronyd || { die "Chrony 安装后仍未找到 chronyd"; return 1; }
  start_chrony || { die "Chrony 已安装，但服务启动失败"; return 1; }
  log_ok "Chrony 已设置为开机启动并正在运行"
}

install_tools() {
  require_root
  detect_os
  local -a packages=()
  local tool
  for tool in curl wget git vim htop unzip; do
    command_exists "$tool" || packages+=("$tool")
  done

  if ((${#packages[@]} == 0)); then
    log_ok "常用工具已经齐全，无需安装"
    return 0
  fi

  echo "正在补齐缺少的常用工具：${packages[*]}"
  if command_exists apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    apt_update_once
    apt-get install -y "${packages[@]}"
  elif command_exists dnf; then
    dnf install -y "${packages[@]}"
  elif command_exists yum; then
    yum install -y "${packages[@]}"
  elif command_exists apk; then
    apk add "${packages[@]}"
  else
    die "暂不支持此系统的软件包管理器"
    return 1
  fi
  log_ok "常用工具安装完成"
}

initialize_system() {
  require_root
  detect_os
  local zone="${1:-Asia/Shanghai}"

  echo "${C_BOLD}开始 VPS 基础初始化${C_RESET}"
  echo "默认时区：$zone"
  echo "自动时间同步：开启"
  echo "常用工具：只安装当前缺少的项目"
  echo

  echo "[1/3] 设置时区"
  set_timezone "$zone"

  echo
  echo "[2/3] 启用自动时间同步"
  enable_time_sync

  echo
  echo "[3/3] 检查常用工具"
  install_tools

  echo
  log_ok "基础初始化完成"
  show_time_sync_status
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

main() {
  case "${1:-init}" in
    init) initialize_system "${2:-Asia/Shanghai}" ;;
    status) show_system_info ;;
    update) update_system ;;
    timezone) set_timezone "${2:-Asia/Shanghai}" ;;
    -h|--help)
      echo "用法：system.sh [init [时区]|status|update|timezone [时区]]"
      echo "不带参数默认执行基础初始化：Asia/Shanghai、NTP 自动同步、补齐常用工具。"
      ;;
    *) die "未知系统模块命令：$1"; return 2 ;;
  esac
}
main "$@"
