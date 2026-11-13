#!/usr/bin/env bash
# vps-init 公共函数库：版本、界面输出、交互、任务执行、系统检测。
# shellcheck disable=SC2034  # 颜色等变量供各模块使用

VPS_INIT_VERSION="0.4.0"
VPS_INIT_RAW="https://raw.githubusercontent.com/dagenduizhanga/vps-init/${VPS_INIT_REF:-main}"
VPS_INIT_LOG="${VPS_INIT_LOG:-/var/log/vps-init.log}"
export PATH="$PATH:/usr/sbin:/sbin"

# ---------- 界面 ----------
# 只在终端里输出颜色（菜单调用模块取状态摘要时用 VPS_INIT_COLOR=1 传递），并遵循 NO_COLOR 约定
if [[ (-t 1 || ${VPS_INIT_COLOR:-} == 1) && -z ${NO_COLOR:-} ]]; then
  C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m' C_CYAN=$'\e[36m'
  C_DIM=$'\e[2m' C_BOLD=$'\e[1m' C_RESET=$'\e[0m'
else
  C_RED='' C_GREEN='' C_YELLOW='' C_CYAN='' C_DIM='' C_BOLD='' C_RESET=''
fi

log_info()  { printf '  %s\n' "$*"; }
log_ok()    { printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
log_warn()  { printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
log_error() { printf '  %s✗%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()       { log_error "$*"; exit 1; }

ui_rule()  { printf '  %s%s%s\n' "$C_DIM" '──────────────────────────────────────────────' "$C_RESET"; }
ui_title() { printf '\n  %s%s%s\n' "$C_BOLD" "$1" "$C_RESET"; ui_rule; [[ -z ${2:-} ]] || printf '  %s\n' "$2"; }
ui_step()  { printf '\n  %s[%s/%s]%s %s%s%s\n' "$C_CYAN" "$1" "$2" "$C_RESET" "$C_BOLD" "$3" "$C_RESET"; }
ui_good()  { printf '%s%s%s' "$C_GREEN" "$*" "$C_RESET"; }
ui_bad()   { printf '%s%s%s' "$C_YELLOW" "$*" "$C_RESET"; }

# 按显示宽度补齐（中文按 2 列计算），用于对齐「标签  内容」两栏
ui_pad() {
  local s=$1 width=$2 LC_ALL=C
  local ascii=${s//[^ -~]/}
  local w=$((${#ascii} + (${#s} - ${#ascii}) * 2 / 3))
  printf '%s%*s' "$s" $((width > w ? width - w : 0)) ''
}
ui_kv() { printf '  %s%s%s%s\n' "$C_DIM" "$(ui_pad "$1" 12)" "$C_RESET" "${2:-未知}"; }
ui_item() { printf '  %s%s%s  %s%s%s%s\n' "$C_CYAN" "$1" "$C_RESET" "$(ui_pad "$2" 16)" "$C_DIM" "${3:-}" "$C_RESET"; }

# 远程一键命令（提示用户时使用）
cmd_hint() { printf 'bash <(curl -fsSL %s/install.sh) %s' "$VPS_INIT_RAW" "$*"; }

# ---------- 交互 ----------
# 交互一律读写 /dev/tty，所以 curl ... | bash 也能正常提问
has_tty() { { : </dev/tty; } 2>/dev/null; }

# ask "提示"：输出用户输入；一次粘贴的多行内容会一起收下
ask() {
  local answer extra
  has_tty || die "需要交互终端；自动化场景请使用命令参数（--help 查看）"
  printf '  %s' "$1" >/dev/tty
  IFS= read -r answer </dev/tty || { printf '\n' >/dev/tty; die "已取消"; }
  while IFS= read -r -t 0.2 extra </dev/tty; do answer+=$'\n'$extra; done
  printf '%s' "$answer"
}

# confirm "问题" [y|n]：第二个参数是直接回车时的默认值，默认为否
confirm() {
  local default=${2:-n} hint='[y/N]' answer
  [[ $default == y ]] && hint='[Y/n]'
  answer=$(ask "$1 $hint ") || return 1
  answer=${answer%%$'\n'*}
  answer=${answer//[[:space:]]/}
  [[ ${answer:-$default} =~ ^[Yy]([Ee][Ss])?$ ]]
}

# ---------- 任务执行 ----------
# run_task "描述" 命令…：命令输出写入日志，界面只显示进度和结果；失败时展示日志末尾
run_task() {
  local desc=$1 pid rc=0 i=0
  local -a spin=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  shift
  printf '\n==> %s  %s\n' "$(date '+%F %T')" "$*" >>"$VPS_INIT_LOG"
  "$@" >>"$VPS_INIT_LOG" 2>&1 </dev/null &
  pid=$!
  if [[ -t 1 ]]; then
    while kill -0 "$pid" 2>/dev/null; do
      printf '\r  %s%s%s %s' "$C_CYAN" "${spin[i++ % 10]}" "$C_RESET" "$desc"
      sleep 0.1
    done
    printf '\r\e[K'
  fi
  wait "$pid" || rc=$?
  if ((rc == 0)); then
    log_ok "$desc"
  else
    log_error "$desc 失败（完整日志：$VPS_INIT_LOG）"
    tail -n 12 "$VPS_INIT_LOG" | sed 's/^/      /' >&2
  fi
  return "$rc"
}

# ---------- 系统检测 ----------
command_exists() { command -v "$1" >/dev/null 2>&1; }
is_root() { [[ ${EUID:-$(id -u)} -eq 0 ]]; }
require_root() { is_root || die "请使用 root 运行"; }

detect_os() {
  [[ -r /etc/os-release ]] || die "无法识别系统：缺少 /etc/os-release"
  # shellcheck source=/dev/null
  . /etc/os-release
  OS_ID=${ID:-unknown} OS_NAME=${PRETTY_NAME:-${ID:-Linux}}
}

# 当前 SSH 服务端口：优先取本次连接实际使用的端口，其次取 sshd 配置；都拿不到就失败，绝不猜默认值
detect_ssh_port() {
  local port=''
  [[ -n ${SSH_CONNECTION:-} ]] && port=$(awk '{print $4}' <<<"$SSH_CONNECTION")
  if [[ -z $port ]] && command_exists sshd; then
    port=$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2; exit}') || true
  fi
  [[ $port =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535)) || return 1
  printf '%s\n' "$port"
}
