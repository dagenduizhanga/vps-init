#!/usr/bin/env bash
# 安全检查与防火墙配置。默认只检查，不自动启用防火墙。
set -Eeuo pipefail
MODULE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$MODULE_DIR/../lib/common.sh"
STATE_DIR="/var/lib/vps-init/security"

firewall_backend() {
  if command_exists ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
    echo ufw
  elif command_exists firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
    echo firewalld
  elif command_exists ufw; then
    echo ufw
  elif command_exists firewall-cmd; then
    echo firewalld
  else
    echo none
  fi
}

firewall_status() {
  if [[ "$EUID" -ne 0 ]]; then
    echo "查看防火墙详细状态需要 root 权限"
    return 0
  fi
  case "$(firewall_backend)" in
    ufw) ufw status verbose ;;
    firewalld)
      firewall-cmd --state 2>/dev/null || true
      firewall-cmd --list-all 2>/dev/null || true
      ;;
    *) echo "未检测到 UFW 或 Firewalld" ;;
  esac
}

security_report() {
  detect_os
  printf '\n系统：%s\n' "$OS_NAME"
  if command_exists sshd; then
    printf 'SSH 服务端口：%s\n' "$(detect_ssh_port)"
    local effective
    effective=$(sshd -T 2>/dev/null || true)
    grep -E '^(permitrootlogin|passwordauthentication|pubkeyauthentication|port) ' <<<"$effective" || true
  else
    log_warn "未检测到 sshd，无法确认 SSH 端口"
  fi
  printf '\n防火墙状态：\n'
  firewall_status
}

save_rule_state() {
  install -d -m 700 "$STATE_DIR"
  printf '%s\n' "$1" "$2" "$3" >"$STATE_DIR/firewall-rule"
  chmod 600 "$STATE_DIR/firewall-rule"
}

enable_ufw() {
  local port="$1" was_active=0 added=0
  if ufw status | grep -q '^Status: active'; then was_active=1; fi
  if ! ufw status | grep -Eq "^$port/tcp[[:space:]]+ALLOW"; then
    ufw allow "$port/tcp"
    added=1
  fi
  if ((was_active == 0)); then
    if ! ufw --force enable; then
      if ((added != 0)); then ufw --force delete allow "$port/tcp" || true; fi
      die "UFW 启用失败，已尝试撤销本次新增规则"
      return 1
    fi
  fi
  ((added == 0)) || save_rule_state ufw "$port" -
  ufw status verbose
}

ssh_firewalld_zone() {
  local client_ip iface zone
  if [[ -n "${SSH_CONNECTION:-}" ]] && command_exists ip; then
    client_ip="${SSH_CONNECTION%% *}"
    iface=$(ip route get "$client_ip" 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')
    if [[ -n "$iface" ]]; then
      zone=$(firewall-cmd --get-zone-of-interface="$iface" 2>/dev/null || true)
      [[ -n "$zone" ]] && { printf '%s\n' "$zone"; return 0; }
    fi
  fi
  firewall-cmd --get-default-zone
}

enable_firewalld() {
  local port="$1" zone active=0 added=0
  if ! command_exists firewall-cmd; then die "未安装 Firewalld"; return 1; fi
  if firewall-cmd --state >/dev/null 2>&1; then active=1; fi
  if ((active == 1)); then
    zone=$(ssh_firewalld_zone)
    if ! firewall-cmd --permanent --zone="$zone" --query-port="$port/tcp" >/dev/null 2>&1; then
      firewall-cmd --permanent --zone="$zone" --add-port="$port/tcp"
      added=1
    fi
    if ! firewall-cmd --zone="$zone" --query-port="$port/tcp" >/dev/null 2>&1; then
      firewall-cmd --zone="$zone" --add-port="$port/tcp" || {
        if ((added != 0)); then firewall-cmd --permanent --zone="$zone" --remove-port="$port/tcp" || true; fi
        die "添加运行时 SSH 放行规则失败"; return 1;
      }
    fi
  else
    command_exists firewall-offline-cmd || { die "Firewalld 当前未运行，且缺少 firewall-offline-cmd；为避免远程断连，拒绝直接启动"; return 1; }
    command_exists systemctl || { die "未找到 systemctl，拒绝自动启动 Firewalld"; return 1; }
    zone=$(firewall-offline-cmd --get-default-zone)
    if ! firewall-offline-cmd --zone="$zone" --query-port="$port/tcp" >/dev/null 2>&1; then
      firewall-offline-cmd --zone="$zone" --add-port="$port/tcp"
      added=1
    fi
    if ! systemctl enable --now firewalld; then
      if ((added != 0)); then firewall-offline-cmd --zone="$zone" --remove-port="$port/tcp" || true; fi
      die "Firewalld 启动失败，已尝试撤销新增规则"; return 1
    fi
  fi
  ((added == 0)) || save_rule_state firewalld "$port" "$zone"
  firewall-cmd --reload
  firewall-cmd --list-all
}

enable_firewall() {
  require_root
  local port
  port=$(detect_ssh_port)
  if [[ ! "$port" =~ ^[0-9]+$ ]] || ((port <= 0 || port > 65535)); then
    die "无法确定 SSH 端口，拒绝启用防火墙"
    return 1
  fi
  echo "即将检查并放行当前 SSH TCP 端口：$port"
  echo "云厂商安全组不受本工具管理，请确认云端规则也允许 SSH。"
  echo "本工具只添加 SSH 放行规则，不会修改默认入站策略或删除现有规则。"
  confirm "确认配置并启用防火墙？" || { log_info "已取消，防火墙未修改。"; return 0; }
  case "$(firewall_backend)" in
    ufw) enable_ufw "$port" ;;
    firewalld) enable_firewalld "$port" ;;
    *) die "未安装 UFW 或 Firewalld；为避免误配置，本工具不会自动安装"; return 1 ;;
  esac
  log_ok "防火墙规则已处理。请保持当前 SSH 会话，并另开窗口验证登录。"
}

undo_firewall_rule() {
  require_root
  [[ -f "$STATE_DIR/firewall-rule" ]] || { log_info "没有本工具新增的防火墙规则记录"; return 0; }
  local kind port zone
  read -r kind port zone <"$STATE_DIR/firewall-rule"
  confirm "仅删除本工具新增的 SSH 放行规则（$port/tcp），不关闭防火墙？" || return 0
  case "$kind" in
    ufw) ufw --force delete allow "$port/tcp" ;;
    firewalld)
      if firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --zone="$zone" --remove-port="$port/tcp" || true
        firewall-cmd --zone="$zone" --remove-port="$port/tcp" || true
        firewall-cmd --reload
      else
        firewall-offline-cmd --zone="$zone" --remove-port="$port/tcp"
      fi
      ;;
    *) die "防火墙记录无法识别"; return 1 ;;
  esac
  rm -f "$STATE_DIR/firewall-rule"
  log_ok "已删除本工具新增的防火墙规则；防火墙本身保持原状态"
}

auto_check() {
  security_report

  if [[ "$EUID" -ne 0 ]]; then
    log_info "当前不是 root，已完成只读检查；需要 root 才能调整防火墙。"
    return 0
  fi

  local port zone
  if ! port=$(detect_ssh_port); then
    log_warn "无法可靠识别 SSH 端口，本次不自动调整防火墙。"
    return 0
  fi

  case "$(firewall_backend)" in
    ufw)
      if ufw status 2>/dev/null | grep -Eq "^$port/tcp[[:space:]]+ALLOW"; then
        log_ok "UFW 已启用，SSH 端口 $port 已放行，无需修改"
        return 0
      fi
      ;;
    firewalld)
      if firewall-cmd --state >/dev/null 2>&1; then
        zone=$(ssh_firewalld_zone)
        if firewall-cmd --permanent --zone="$zone" --query-port="$port/tcp" >/dev/null 2>&1 &&
           firewall-cmd --zone="$zone" --query-port="$port/tcp" >/dev/null 2>&1; then
          log_ok "Firewalld 已启用，SSH 端口 $port 已放行，无需修改"
          return 0
        fi
      fi
      ;;
    none)
      log_warn "未安装 UFW 或 Firewalld。为避免擅自改变网络策略，本工具不会自动安装或启用防火墙。"
      return 0
      ;;
  esac

  echo
  echo "检测到防火墙尚未启用，或当前 SSH 端口 $port 尚未完整放行。"
  enable_firewall
}

main() {
  case "${1:-menu}" in
    menu|check) auto_check ;;
    status) security_report ;;
    firewall) enable_firewall ;;
    --undo) undo_firewall_rule ;;
    -h|--help) echo "用法：security.sh [check|status|firewall|--undo]"; echo "不带参数时自动检查安全状态，必要时才询问是否配置防火墙。" ;;
    *) die "未知安全模块命令：$1"; return 2 ;;
  esac
}
main "$@"
