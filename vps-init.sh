#!/usr/bin/env bash
# vps-init 统一入口：交互菜单与子命令。
set -Eeuo pipefail
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$ROOT_DIR/lib/common.sh"

usage() {
  cat <<EOF
vps-init $VPS_INIT_VERSION — 新 VPS 初始化工具

用法：vps-init.sh [命令]

  （无参数）       打开交互菜单
  system [时区]    系统初始化：时区（默认 Asia/Shanghai）、自动校时、常用工具
  ssh [公钥]       SSH 密钥登录；可直接传入公钥、gh:用户名 或 https 网址，--undo 撤销
  firewall         放行 SSH 后启用防火墙；--undo 撤销
  update [--yes]   升级系统软件包（需要确认；--yes 用于自动化）
  status           查看系统、SSH、防火墙状态
  --version        显示版本

远程运行：$(cmd_hint '[命令]')
EOF
}

module() { bash "$ROOT_DIR/modules/$1.sh" "${@:2}"; }

show_status() {
  module system status
  module ssh status
  module firewall status
  printf '\n'
}

header() {
  detect_os
  printf '\n  %svps-init%s %sv%s%s\n' "$C_BOLD" "$C_RESET" "$C_DIM" "$VPS_INIT_VERSION" "$C_RESET"
  ui_rule
  ui_kv "主机" "${HOSTNAME:-未知} · $OS_NAME"
  if is_root; then
    ui_kv "SSH" "$(module ssh summary)"
    ui_kv "防火墙" "$(module firewall summary)"
  else
    ui_kv "提示" "$(ui_bad '当前不是 root，只能查看状态')"
  fi
  ui_kv "时间" "$(module system summary)"
  ui_rule
}

pause() {
  printf '\n  %s按回车返回菜单%s' "$C_DIM" "$C_RESET" >/dev/tty
  read -r _ </dev/tty || true
}

# 在菜单中运行模块：模块出错、取消或按 Ctrl-C，都回到菜单
run_in_menu() {
  module "$@" || true
  pause
}

show_menu() {
  local choice
  has_tty || die "交互菜单需要终端；也可以直接使用子命令，见 --help"
  export VPS_INIT_COLOR=1 # 让模块输出的状态摘要也带颜色
  trap 'printf "\n"' INT
  while :; do
    printf '\e[H\e[2J'
    header
    ui_item 1 "系统初始化" "时区、自动校时、常用工具"
    ui_item 2 "SSH 密钥登录" "安装公钥，关闭密码登录"
    ui_item 3 "防火墙" "放行 SSH 后启用防火墙"
    ui_item 4 "系统更新" "升级全部软件包"
    ui_item 5 "详细状态"
    ui_item 0 "退出"
    printf '\n'
    choice=$(ask "请选择 [0-5]：") || return 0
    case ${choice//[[:space:]]/} in
      1) run_in_menu system init ;;
      2) run_in_menu ssh ;;
      3) run_in_menu firewall ;;
      4) run_in_menu system update ;;
      5) show_status; pause ;;
      0 | q) return 0 ;;
      *) ;;
    esac
  done
}

main() {
  local cmd=${1:-menu}
  (($#)) && shift
  case $cmd in
    menu) show_menu ;;
    system) module system "$@" ;;
    update) module system update "$@" ;;
    ssh) module ssh "$@" ;;
    firewall | security) module firewall "$@" ;;
    status) show_status ;;
    -h | --help | help) usage ;;
    -v | --version | version) echo "vps-init $VPS_INIT_VERSION" ;;
    *) log_error "未知命令：$cmd"; usage >&2; exit 2 ;;
  esac
}

main "$@"
