#!/usr/bin/env bash
# 系统初始化：时区、自动校时、常用工具；系统更新单独执行并需要确认。
set -Eeuo pipefail
MODULE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$MODULE_DIR/../lib/common.sh"

DEFAULT_TZ=Asia/Shanghai
TOOLS=(curl wget git vim htop unzip)
APT_REFRESHED=0

usage() {
  cat <<EOF
用法：system.sh [命令]

  init [时区]      一键初始化：时区（默认 $DEFAULT_TZ）、自动校时、补齐常用工具（默认命令）
  update           升级全部软件包（需要确认）
  timezone [时区]  只设置时区
  status           查看系统状态
EOF
}

# ---------- 软件包 ----------
pkg_manager() {
  local m
  for m in apt-get dnf yum apk; do
    if command_exists "$m"; then echo "${m%-get}"; return; fi
  done
  echo none
}

pkg_install() {
  case $(pkg_manager) in
    apt) DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$@" ;;
    dnf) dnf install -y -q "$@" ;;
    yum) yum install -y -q "$@" ;;
    apk) apk add -q "$@" ;;
    *) echo "不支持的包管理器" >&2; return 1 ;;
  esac
}

# APT 安装前刷新一次软件源；失败也继续，用本地缓存尝试安装
pkg_refresh() {
  [[ $(pkg_manager) == apt ]] && ((APT_REFRESHED == 0)) || return 0
  run_task "刷新软件源" apt-get update -q || log_warn "软件源刷新失败，继续尝试安装"
  APT_REFRESHED=1
}

# ---------- 时区与校时 ----------
current_tz() {
  local tz=''
  command_exists timedatectl && tz=$(timedatectl show -p Timezone --value 2>/dev/null || true)
  [[ -n $tz ]] || tz=$(readlink -f /etc/localtime 2>/dev/null | sed -n 's|.*/zoneinfo/||p')
  printf '%s' "${tz:-未知}"
}

check_tz() {
  [[ $1 =~ ^[A-Za-z0-9_+/-]+$ && -e /usr/share/zoneinfo/$1 ]] || die "无效的时区：$1（例如 Asia/Shanghai、Asia/Singapore）"
}

set_timezone() {
  local zone=$1 current
  check_tz "$zone"
  current=$(current_tz)
  if [[ $current == "$zone" ]]; then
    log_ok "时区已经是 $zone"
    return 0
  fi
  if ! { command_exists timedatectl && timedatectl set-timezone "$zone" 2>/dev/null; }; then
    ln -snf "/usr/share/zoneinfo/$zone" /etc/localtime
    [[ ! -f /etc/timezone ]] || echo "$zone" >/etc/timezone
  fi
  log_ok "时区已设置为 $zone（原来是 $current）"
}

start_chrony() {
  if command_exists systemctl; then
    systemctl enable --now chrony 2>/dev/null || systemctl enable --now chronyd 2>/dev/null
  elif command_exists rc-service; then
    rc-update add chronyd default >/dev/null 2>&1 || true
    rc-service chronyd start
  else
    return 1
  fi
}

enable_time_sync() {
  # 已经装了 Chrony 就直接用它，不另装其他服务
  if command_exists chronyd; then
    start_chrony && { log_ok "自动校时已开启（Chrony）"; return 0; }
    log_warn "检测到 Chrony，但无法启动它的服务"
    return 1
  fi
  # systemd 系统优先用自带的 systemd-timesyncd
  if command_exists timedatectl && timedatectl set-ntp true 2>/dev/null &&
    [[ $(timedatectl show -p NTP --value 2>/dev/null) == yes ]]; then
    log_ok "自动校时已开启（systemd-timesyncd）"
    return 0
  fi
  # 都没有时安装 Chrony
  pkg_refresh
  run_task "安装 Chrony" pkg_install chrony || return 1
  start_chrony || { log_warn "Chrony 已安装，但服务启动失败"; return 1; }
  log_ok "自动校时已开启（Chrony）"
}

time_sync_text() {
  if command_exists timedatectl && [[ $(timedatectl show -p NTPSynchronized --value 2>/dev/null) == yes ]]; then
    ui_good 已同步
  elif command_exists timedatectl && [[ $(timedatectl show -p NTP --value 2>/dev/null) == yes ]]; then
    printf '已开启，等待首次同步'
  elif command_exists chronyc && chronyc tracking >/dev/null 2>&1; then
    ui_good 'Chrony 运行中'
  else
    ui_bad 未开启
  fi
}

# ---------- 常用工具 ----------
install_tools() {
  local tool
  local -a missing=() failed=()
  for tool in "${TOOLS[@]}"; do command_exists "$tool" || missing+=("$tool"); done
  if ((${#missing[@]} == 0)); then
    log_ok "常用工具已经齐全：${TOOLS[*]}"
    return 0
  fi
  pkg_refresh
  # 逐个安装：某个包不可用（例如 RHEL 系的 htop 需要 EPEL）不影响其他包
  for tool in "${missing[@]}"; do
    run_task "安装 $tool" pkg_install "$tool" || failed+=("$tool")
  done
  if ((${#failed[@]})); then
    log_warn "未能安装：${failed[*]}（RHEL 系可先运行 dnf install -y epel-release 再重试）"
  fi
}

# ---------- 命令 ----------
initialize() {
  local zone=${1:-$DEFAULT_TZ}
  require_root
  check_tz "$zone"
  detect_os
  ui_title "系统初始化" "$OS_NAME · 时区 $zone · 自动校时 · 常用工具（已完成的项目自动跳过）"

  ui_step 1 3 "时区"
  set_timezone "$zone"

  ui_step 2 3 "自动校时"
  enable_time_sync || log_warn "自动校时没有开启，可以稍后重新运行本功能"

  ui_step 3 3 "常用工具"
  install_tools

  printf '\n'
  log_ok "初始化完成 · 时区 $(current_tz) · 校时 $(time_sync_text)"
}

update_system() {
  local pm
  require_root
  pm=$(pkg_manager)
  [[ $pm != none ]] || die "不支持当前系统的包管理器"
  ui_title "系统更新" "升级全部软件包。可能包含内核更新，相关服务会自动重启。"
  confirm "开始更新？" || { log_info "已取消，系统没有任何修改"; return 0; }
  printf '\n'
  case $pm in
    apt)
      pkg_refresh
      # 输出写入日志，必须避免任何交互提示：保留现有配置文件、自动重启受影响的服务
      run_task "升级软件包（可能需要几分钟）" env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
        apt-get -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade
      ;;
    dnf) run_task "升级软件包（可能需要几分钟）" dnf -y -q upgrade ;;
    yum) run_task "升级软件包（可能需要几分钟）" yum -y -q update ;;
    apk) { run_task "刷新软件源" apk update -q && run_task "升级软件包" apk upgrade -q; } || exit 1 ;;
  esac
  log_ok "系统更新完成"
  if [[ -f /var/run/reboot-required ]] ||
    { command_exists needs-restarting && ! needs-restarting -r >/dev/null 2>&1; }; then
    log_warn "需要重启才能使用新内核，确认服务都正常后运行 reboot"
  fi
}

uptime_text() {
  local seconds
  read -r seconds _ </proc/uptime
  seconds=${seconds%.*}
  printf '%d 天 %d 小时 %d 分' $((seconds / 86400)) $((seconds % 86400 / 3600)) $((seconds % 3600 / 60))
}

primary_ip() {
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}'
}

status() {
  detect_os
  ui_title "系统"
  ui_kv "主机名" "${HOSTNAME:-未知}"
  ui_kv "系统" "$OS_NAME · $(uname -m)"
  ui_kv "内核" "$(uname -r)"
  ui_kv "IP 地址" "$(primary_ip 2>/dev/null || true)"
  ui_kv "运行时间" "$(uptime_text)"
  ui_kv "负载" "$(cut -d' ' -f1-3 /proc/loadavg)"
  ui_kv "内存" "$(awk '/^MemTotal/ {t = $2} /^MemAvailable/ {a = $2} END {printf "已用 %.1fG / 共 %.1fG", (t - a) / 1048576, t / 1048576}' /proc/meminfo)"
  ui_kv "磁盘 /" "$(df -hP / | awk 'NR == 2 {print "已用 " $3 " / 共 " $2 "（" $5 "）"}')"
  ui_kv "时区" "$(current_tz)"
  ui_kv "自动校时" "$(time_sync_text)"
}

summary() { printf '%s · 自动校时 %s\n' "$(current_tz)" "$(time_sync_text)"; }

main() {
  local cmd=${1:-init}
  (($#)) && shift
  case $cmd in
    init) initialize "$@" ;;
    */*) initialize "$cmd" ;; # system Asia/Singapore 等同于 system init Asia/Singapore
    update) update_system ;;
    timezone) require_root; set_timezone "${1:-$DEFAULT_TZ}" ;;
    status) status ;;
    summary) summary ;;
    -h | --help) usage ;;
    *) log_error "未知命令：$cmd"; usage >&2; exit 2 ;;
  esac
}

main "$@"
