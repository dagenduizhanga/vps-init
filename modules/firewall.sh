#!/usr/bin/env bash
# 防火墙：先确保 SSH 端口放行，再启用 UFW / Firewalld。只做必要的修改，全部可以撤销。
set -Eeuo pipefail
MODULE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$MODULE_DIR/../lib/common.sh"

STATE_DIR=/var/lib/vps-init/security
STATE=$STATE_DIR/firewall.state
LEGACY_STATE=$STATE_DIR/firewall-rule # 0.3.x 的记录：三行，依次是后端、端口、区域

BACKEND='' ZONE='' PORT=''
S_ENABLED=0 S_RULES=''          # 状态记录：防火墙是否由本工具启用、本工具添加的规则
RUN_ENABLED=0 RUN_RULES=()       # 本次运行做的修改，测试失败时只撤销这些
RULES=()

usage() {
  cat <<EOF
用法：firewall.sh [命令]

  （无参数）  检查防火墙；需要修改时列出方案并询问
  status      查看防火墙状态
  --undo      撤销本工具做过的防火墙修改
EOF
}

# ---------- 检测 ----------
# 选用哪套防火墙：优先已启用的；都没启用时优先 UFW
backend() {
  if command_exists ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then echo ufw
  elif command_exists firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then echo firewalld
  elif command_exists ufw; then echo ufw
  elif command_exists firewall-cmd; then echo firewalld
  else echo none; fi
}

is_active() {
  case $1 in
    ufw) ufw status 2>/dev/null | grep -q '^Status: active' ;;
    firewalld) firewall-cmd --state >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

backend_name() { case $1 in ufw) echo UFW ;; firewalld) echo Firewalld ;; *) echo 无 ;; esac; }

# Firewalld 区域：运行中取当前 SSH 连接入站网卡所在的区域，否则取默认区域
fwd_zone() {
  local iface zone
  if ! is_active firewalld; then
    firewall-offline-cmd --get-default-zone
    return
  fi
  if [[ -n ${SSH_CONNECTION:-} ]] && command_exists ip; then
    iface=$(ip route get "${SSH_CONNECTION%% *}" 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}')
    if [[ -n $iface ]] && zone=$(firewall-cmd --get-zone-of-interface="$iface" 2>/dev/null); then
      echo "$zone"
      return
    fi
  fi
  firewall-cmd --get-default-zone
}

# Firewalld 运行中时，永久规则和运行时规则都要有；未运行时只看永久规则
fwd_query() {
  if is_active firewalld; then
    firewall-cmd --zone="$ZONE" "$@" >/dev/null 2>&1 && firewall-cmd --permanent --zone="$ZONE" "$@" >/dev/null 2>&1
  else
    firewall-offline-cmd --zone="$ZONE" "$@" >/dev/null 2>&1
  fi
}

# allows 端口/协议：现有规则是否已放行。不限协议的规则也算；22/tcp 还认 OpenSSH 应用配置和 ssh 服务
allows() {
  local spec=$1 port=${1%/*} proto=${1#*/} rules re
  case $BACKEND in
    ufw)
      if is_active ufw; then
        rules=$(ufw status | awk '/ALLOW|LIMIT/ {print $1}')
      else
        rules=$(ufw show added 2>/dev/null | awk '$1 == "ufw" && ($2 == "allow" || $2 == "limit") && NF == 3 {print $3}')
      fi
      re="$port(/$proto)?"
      [[ $spec == 22/tcp ]] && re+='|OpenSSH'
      grep -qxE "$re" <<<"$rules"
      ;;
    firewalld)
      fwd_query --query-port="$spec" || { [[ $spec == 22/tcp ]] && fwd_query --query-service=ssh; }
      ;;
    *) return 1 ;;
  esac
}

# 对外监听的端口，每行「端口/协议 进程名」；排除回环和链路本地地址、DHCP 客户端、SSH 端口
exposed_ports() {
  command_exists ss || return 0
  ss -Hltunp 2>/dev/null | awk -v ssh="$PORT/tcp" '{
    proto = $1; addr = $5; port = addr
    sub(/.*:/, "", port); sub(/:[^:]*$/, "", addr)
    if (port !~ /^[0-9]+$/ || addr ~ /^(127\.|\[::1\]|::1$|\[fe80|fe80)/) next
    spec = port "/" proto
    if (spec == ssh || spec == "68/udp" || spec == "546/udp" || seen[spec]++) next
    name = "?"
    if (match($0, /\(\("[^"]+"/)) name = substr($0, RSTART + 3, RLENGTH - 4)
    print spec, name
  }' | sort -n
}

# ---------- 状态记录 ----------
load_state() {
  S_ENABLED=0 S_RULES=''
  local key value
  local -a old
  if [[ -f $STATE ]]; then
    while IFS='=' read -r key value; do
      case $key in
        backend) BACKEND=$value ;;
        zone) ZONE=$value ;;
        enabled) S_ENABLED=$value ;;
        rules) S_RULES=$value ;;
      esac
    done <"$STATE"
  elif [[ -f $LEGACY_STATE ]]; then
    mapfile -t old <"$LEGACY_STATE"
    BACKEND=${old[0]:-} S_RULES=${old[1]:+${old[1]}/tcp} ZONE=${old[2]:-}
    [[ $ZONE == - ]] && ZONE=''
  else
    return 1
  fi
  [[ $BACKEND == ufw || $BACKEND == firewalld ]]
}

save_state() {
  rm -f "$LEGACY_STATE"
  if [[ -z $S_RULES ]] && ((S_ENABLED == 0)); then
    rm -f "$STATE"
    return
  fi
  install -d -m 700 "$STATE_DIR"
  printf 'backend=%s\nzone=%s\nenabled=%s\nrules=%s\n' "$BACKEND" "$ZONE" "$S_ENABLED" "$S_RULES" >"$STATE"
  chmod 600 "$STATE"
}

# ---------- 修改 ----------
add_rule() {
  case $BACKEND in
    ufw) ufw allow "$1" ;;
    firewalld)
      if is_active firewalld; then
        firewall-cmd --permanent --zone="$ZONE" --add-port="$1" && firewall-cmd --zone="$ZONE" --add-port="$1"
      else
        firewall-offline-cmd --zone="$ZONE" --add-port="$1"
      fi
      ;;
  esac
}

delete_rule() {
  case $BACKEND in
    ufw) ufw --force delete allow "$1" ;;
    firewalld)
      if is_active firewalld; then
        firewall-cmd --permanent --zone="$ZONE" --remove-port="$1" && firewall-cmd --zone="$ZONE" --remove-port="$1"
      else
        firewall-offline-cmd --zone="$ZONE" --remove-port="$1"
      fi
      ;;
  esac
}

enable_backend() {
  case $BACKEND in
    ufw) ufw --force enable ;;
    firewalld) systemctl enable --now firewalld ;;
  esac
}

disable_backend() {
  case $BACKEND in
    ufw) ufw --force disable ;;
    firewalld) systemctl disable --now firewalld ;;
  esac
}

# revert 是否关闭防火墙 规则…：撤销指定的修改，并同步更新状态记录
revert() {
  local disable=$1 rule kept item
  shift
  if ((disable)); then
    run_task "关闭 $(backend_name "$BACKEND")" disable_backend || log_warn "关闭防火墙失败，请手动检查"
    S_ENABLED=0
  fi
  for rule in "$@"; do
    run_task "删除规则 $rule" delete_rule "$rule" || log_warn "删除规则 $rule 失败，请手动检查"
    kept=''
    for item in $S_RULES; do [[ $item == "$rule" ]] || kept+="${kept:+ }$item"; done
    S_RULES=$kept
  done
  save_state
}

# 列出启用后会被挡住的服务，让用户选择一并放行的端口，结果追加到 RULES
choose_extra_ports() {
  local spec name input token found i
  local -a blocked=() names=() docker=() picked tokens
  while read -r spec name; do
    if [[ -z $spec ]] || allows "$spec"; then continue; fi
    if [[ $name == docker-proxy ]]; then
      docker+=("$spec")
    else
      blocked+=("$spec") names+=("$name")
    fi
  done < <(exposed_ports)
  if ((${#blocked[@]})); then
    printf '\n'
    log_warn "启用后，下面这些正在对外提供的服务将无法从外部访问："
    for i in "${!blocked[@]}"; do
      printf '      %s%s%s%s\n' "$(ui_pad "${blocked[i]}" 12)" "$C_DIM" "${names[i]}" "$C_RESET"
    done
  fi
  if ((${#docker[@]})); then log_info "Docker 映射的端口（${docker[*]}）通常绕过本机防火墙，不受影响"; fi
  ((${#blocked[@]})) || return 0
  while :; do
    input=$(ask "要一并放行哪些？输入端口（空格分隔），a = 全部，直接回车 = 都不放行：")
    read -ra tokens <<<"${input//$'\n'/ }"
    picked=()
    for token in ${tokens[@]+"${tokens[@]}"}; do
      if [[ $token == a || $token == all ]]; then
        picked+=("${blocked[@]}")
      elif [[ $token =~ ^([0-9]{1,5})(/(tcp|udp))?$ ]] && ((BASH_REMATCH[1] >= 1 && BASH_REMATCH[1] <= 65535)); then
        found=0
        for spec in "${blocked[@]}"; do
          if [[ $spec == "$token" || ${spec%/*} == "$token" ]]; then picked+=("$spec"); found=1; fi
        done
        ((found)) || picked+=("${token%/*}/${BASH_REMATCH[3]:-tcp}")
      else
        log_error "看不懂「$token」，请输入端口号，例如 3000 或 51413/udp"
        continue 2
      fi
    done
    RULES+=(${picked[@]+"${picked[@]}"})
    return 0
  done
}

# ---------- 主流程 ----------
check() {
  require_root
  ui_title "防火墙" "确保 SSH 端口已放行，再启用防火墙。只在需要修改时才会询问。"
  PORT=$(detect_ssh_port) || die "无法确定 SSH 端口；为避免把自己锁在外面，已停止"
  BACKEND=$(backend)
  if [[ $BACKEND == none ]]; then
    log_warn "没有安装 UFW 或 Firewalld；本工具不会擅自安装防火墙"
    log_info "如需安装：Debian/Ubuntu 用 apt install ufw，RHEL 系用 dnf install firewalld，装好后重新运行"
    return 0
  fi
  if [[ $BACKEND == firewalld ]]; then
    is_active firewalld || command_exists firewall-offline-cmd ||
      die "Firewalld 未运行且缺少 firewall-offline-cmd，无法先放行 SSH 再启动，已停止"
    ZONE=$(fwd_zone)
  fi

  local active=0 ssh_ok=0 rule state_text ssh_text
  is_active "$BACKEND" && active=1
  allows "$PORT/tcp" && ssh_ok=1
  if ((active)); then state_text=$(ui_good 已启用); else state_text=$(ui_bad 未启用); fi
  if ((ssh_ok)); then ssh_text=$(ui_good 已放行); else ssh_text=$(ui_bad 未放行); fi
  ui_kv "防火墙" "$(backend_name "$BACKEND") · $state_text${ZONE:+ · 区域 $ZONE}"
  ui_kv "SSH 端口" "$PORT/tcp · $ssh_text"
  if ((active && ssh_ok)); then
    log_ok "防火墙已启用，SSH 已放行，无需修改"
    return 0
  fi

  RULES=()
  ((ssh_ok)) || RULES+=("$PORT/tcp")
  ((active)) || choose_extra_ports

  # 去重，并去掉已经放行的端口：已有规则不算本工具添加的，撤销时也就不会误删
  local -A seen=()
  local -a todo=()
  for rule in ${RULES[@]+"${RULES[@]}"}; do
    [[ -z ${seen[$rule]:-} ]] || continue
    seen[$rule]=1
    if [[ $rule != "$PORT/tcp" ]] && allows "$rule"; then continue; fi
    todo+=("$rule")
  done
  RULES=(${todo[@]+"${todo[@]}"})

  printf '\n'
  log_info "即将执行："
  for rule in ${RULES[@]+"${RULES[@]}"}; do log_info "• 放行 $rule"; done
  ((active)) || log_info "• 启用 $(backend_name "$BACKEND")：除已放行的端口外，拒绝其他入站连接"
  log_info "• 云服务商的安全组不受影响，需要时请在服务商控制台另行放行"
  confirm "确认执行？" || { log_info "已取消，防火墙没有任何修改"; return 0; }

  printf '\n'
  load_state || true # 合并以前的记录，撤销时一并处理
  BACKEND=$(backend)
  [[ $BACKEND != firewalld ]] || ZONE=$(fwd_zone)
  for rule in ${RULES[@]+"${RULES[@]}"}; do
    if ! run_task "放行 $rule" add_rule "$rule"; then
      revert "$RUN_ENABLED" ${RUN_RULES[@]+"${RUN_RULES[@]}"}
      die "放行 $rule 失败，已撤销本次修改"
    fi
    RUN_RULES+=("$rule")
    S_RULES+="${S_RULES:+ }$rule"
    save_state
  done
  if ((!active)); then
    RUN_ENABLED=1 S_ENABLED=1
    save_state # 先记录再启用：即使中途断开，也能用 --undo 撤销
    if ! run_task "启用 $(backend_name "$BACKEND")" enable_backend; then
      revert 1 ${RUN_RULES[@]+"${RUN_RULES[@]}"}
      die "启用防火墙失败，已撤销本次修改"
    fi
  fi
  # 启用后重新检查。Firewalld 刚启动时，SSH 网卡可能属于默认区域以外的区域，要按实际区域检查
  local rule_zone=$ZONE
  [[ $BACKEND != firewalld ]] || ZONE=$(fwd_zone)
  if ! is_active "$BACKEND" || ! allows "$PORT/tcp"; then
    ZONE=$rule_zone
    revert "$RUN_ENABLED" ${RUN_RULES[@]+"${RUN_RULES[@]}"}
    die "启用后检查未通过（SSH 端口在当前区域没有放行），已撤销本次修改"
  fi
  ZONE=$rule_zone

  printf '\n'
  log_warn "先别关闭这个窗口！新开一个终端连接 SSH 试试"
  if confirm "新窗口能连上吗？（回答 n 会立即撤销）"; then
    log_ok "完成。如需撤销：$(cmd_hint firewall --undo)"
  else
    revert "$RUN_ENABLED" ${RUN_RULES[@]+"${RUN_RULES[@]}"}
    log_warn "已撤销本次修改。请检查云服务商安全组是否放行了 SSH 端口 $PORT"
  fi
}

undo() {
  require_root
  load_state || { log_info "没有本工具做过的防火墙修改，无需撤销"; return 0; }
  local rule port
  ui_title "撤销防火墙修改"
  for rule in $S_RULES; do log_info "• 删除规则 $rule"; done
  if ((S_ENABLED)); then
    log_info "• 关闭 $(backend_name "$BACKEND")（它是本工具启用的）"
  elif is_active "$BACKEND" && port=$(detect_ssh_port) && [[ " $S_RULES " == *" $port/tcp "* ]]; then
    log_warn "防火墙会继续运行，而 SSH 端口 $port 的放行规则将被删除；如果没有其他规则放行它，新的 SSH 连接会被拒绝"
  fi
  confirm "确认撤销？" || { log_info "已取消"; return 0; }
  # shellcheck disable=SC2086  # 规则列表按空格拆分
  revert "$S_ENABLED" $S_RULES
  log_ok "已撤销本工具的防火墙修改"
}

summary() {
  is_root || { echo '需要 root'; return 0; }
  BACKEND=$(backend)
  [[ $BACKEND != none ]] || { ui_bad '未安装 UFW / Firewalld'; echo; return 0; }
  if ! is_active "$BACKEND"; then
    printf '%s · %s\n' "$(backend_name "$BACKEND")" "$(ui_bad 未启用)"
    return 0
  fi
  [[ $BACKEND != firewalld ]] || ZONE=$(fwd_zone)
  printf '%s · %s' "$(backend_name "$BACKEND")" "$(ui_good 已启用)"
  if PORT=$(detect_ssh_port); then
    if allows "$PORT/tcp"; then printf ' · SSH %s/tcp 已放行' "$PORT"; else printf ' · %s' "$(ui_bad "SSH $PORT/tcp 未放行")"; fi
  fi
  echo
}

status() {
  ui_title "防火墙"
  is_root || { log_info "需要 root 才能读取防火墙状态"; return 0; }
  ui_kv "状态" "$(summary)"
  if load_state; then
    local note=${S_RULES:-无规则}
    if ((S_ENABLED)); then note+='；防火墙由本工具启用'; fi
    ui_kv "本工具修改" "$note"
  fi
}

main() {
  case ${1:-check} in
    check | firewall | menu) check ;;
    status) status ;;
    summary) summary ;;
    --undo | undo) undo ;;
    -h | --help) usage ;;
    *) log_error "未知命令：$1"; usage >&2; exit 2 ;;
  esac
}

main "$@"
