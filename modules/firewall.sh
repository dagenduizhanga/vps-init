#!/usr/bin/env bash
# 防火墙：先确保 SSH 端口放行，再启用 UFW / Firewalld。只做必要的修改，全部可以撤销。
set -Eeuo pipefail
MODULE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$MODULE_DIR/../lib/common.sh"

STATE_DIR=/var/lib/vps-init/security
STATE=$STATE_DIR/firewall.state
LEGACY_STATE=$STATE_DIR/firewall-rule # 0.3.x 的记录：三行，依次是后端、端口、区域

BACKEND='' ZONE='' PORT='' UFW_RULES='' ACTIVE=0
S_ENABLED=0 S_RULES=''          # 状态记录：防火墙是否由本工具启用、本工具添加的规则
RUN_ENABLED=0 RUN_RULES=()       # 本次运行做的修改，测试失败时只撤销这些
RULES=()

usage() {
  cat <<EOF
用法：firewall.sh [命令]

  （无参数）  检查防火墙；需要修改时列出方案并询问
  --allow 端口…  指定额外放行的端口（如 443 53/udp），跳过选端口，仍验证新连接
  status      查看防火墙状态
  --undo      撤销本工具做过的防火墙修改
EOF
}

# ---------- 检测 ----------
# 选用哪套防火墙：优先已启用的；都没启用时优先 UFW
backend() {
  if command_exists ufw && is_active ufw; then echo ufw
  elif command_exists firewall-cmd && is_active firewalld; then echo firewalld
  elif command_exists ufw; then echo ufw
  elif command_exists firewall-cmd; then echo firewalld
  else echo none; fi
}

is_active() {
  case $1 in
    ufw) [[ $(LC_ALL=C ufw status 2>/dev/null) == 'Status: active'* ]] ;;
    firewalld) firewall-cmd --state >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

backend_name() { case $1 in ufw) echo UFW ;; firewalld) echo Firewalld ;; *) echo 无 ;; esac; }

# Firewalld 区域：运行中取当前 SSH 连接入站网卡所在的区域，否则取默认区域
fwd_zone() {
  local iface zone
  if ((!ACTIVE)); then
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

# 运行时与永久规则可以由不同的人维护，查询、添加、撤销都区分两层。
fwd_cmd() {
  local scope=$1
  shift
  case $scope in
    runtime) firewall-cmd --zone="$ZONE" "$@" ;;
    permanent) firewall-cmd --permanent --zone="$ZONE" "$@" ;;
    offline) firewall-offline-cmd --zone="$ZONE" "$@" ;;
    *) return 2 ;;
  esac
}

fwd_allows() {
  local scope=$1 spec=$2 rc=0
  fwd_cmd "$scope" --query-port="$spec" >/dev/null 2>&1 || rc=$?
  ((rc == 1)) || return "$rc" # 0 已存在，1 不存在，其他值是查询出错
  [[ $spec == 22/tcp ]] && fwd_cmd "$scope" --query-service=ssh >/dev/null 2>&1
}

# 一次读取供本轮规划使用；写入后重新读取，供复查使用。
read_firewall() {
  local status rc peer=${SSH_CONNECTION:-}
  ACTIVE=0
  if [[ $BACKEND == firewalld ]]; then
    if is_active firewalld; then ACTIVE=1; else
      rc=$?
      ((rc == 252)) || { log_error "无法确定 Firewalld 运行状态（$rc）"; return 1; }
    fi
    return 0
  fi
  status=$(LC_ALL=C ufw status) || return 1
  if [[ $status == 'Status: active'* ]]; then
    ACTIVE=1
    UFW_RULES=$(awk -v peer="${peer%% *}" '{
      v6 = /\(v6\)/; gsub(/ \(v6\)/, "")
      for (i=2; i<=NF; i++) if ($i ~ /^(ALLOW|LIMIT|DENY|REJECT)$/) {
        if ($(i+1) == "OUT" || $(i+1) == "FWD") next
        if ($i == "DENY" || $i == "REJECT") print "deny", $1
        else if (i != 2 || $NF != "Anywhere" || v6 != (index(peer, ":") != 0)) print "scoped", $1
        else print $1
        break
      }
    }' <<<"$status")
  elif [[ $status == 'Status: inactive'* ]]; then
    UFW_RULES=$(LC_ALL=C ufw show added | awk '
      $1 == "ufw" && $2 ~ /^(allow|limit|deny|reject)$/ && $3 != "out" {
        sub(/ comment .*/, "")
        if (NF == 3) {print ($2 ~ /^(deny|reject)$/ ? "deny " : "") $3; next}
        for (i=3; i<NF; i++) if ($i == "port") print "scoped", $(i+1)
      }')
  else
    log_error "无法识别 UFW 的运行状态"; return 1
  fi
}

# allows 端口/协议：现有规则是否已放行。不限协议的规则也算；22/tcp 还认 OpenSSH 应用配置和 ssh 服务
allows() {
  local spec=$1 port=${1%/*} proto=${1#*/} re
  case $BACKEND in
    ufw)
      re="$port(/$proto)?"
      [[ $spec == 22/tcp ]] && re+='|OpenSSH'
      grep -qxE "deny ($re)" <<<"$UFW_RULES" && return 2
      grep -qxE "$re" <<<"$UFW_RULES" && return 0
      grep -qxE "scoped ($re)" <<<"$UFW_RULES" && return 2
      return 1
      ;;
    firewalld)
      if ((ACTIVE)); then
        fwd_allows runtime "$spec" && fwd_allows permanent "$spec"
      else
        fwd_allows offline "$spec"
      fi
      ;;
    *) return 1 ;;
  esac
}

# 查询错误或已有定向规则时，不能自动新增一条面向所有地址的规则。
plan_allows() {
  local rc=0
  allows "$1" || rc=$?
  ((rc <= 1)) || die "无法确认 $1 对当前连接的放行策略，请检查已有规则"
  return "$rc"
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
  BACKEND='' ZONE='' S_ENABLED=0 S_RULES=''
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
  [[ $BACKEND == ufw || $BACKEND == firewalld ]] && [[ $S_ENABLED == 0 || $S_ENABLED == 1 || $S_ENABLED == 2 ]]
}

save_state() {
  local tmp
  if [[ -z $S_RULES ]] && ((S_ENABLED == 0)); then
    rm -f "$STATE" "$LEGACY_STATE"; return
  fi
  install -d -m 700 "$STATE_DIR" || return 1
  tmp=$(mktemp "$STATE_DIR/.firewall.XXXXXX") || return 1
  if printf 'backend=%s\nzone=%s\nenabled=%s\nrules=%s\n' "$BACKEND" "$ZONE" "$S_ENABLED" "$S_RULES" >"$tmp" &&
    mv -f -- "$tmp" "$STATE"; then
    rm -f "$LEGACY_STATE"
  else
    rm -f "$tmp"; return 1
  fi
}

# ---------- 修改 ----------
add_rule() {
  local spec=$1 scope record rc previous
  local -a scopes=(ufw)
  if [[ $BACKEND == firewalld ]]; then
    if ((ACTIVE)); then scopes=(permanent runtime); else scopes=(offline); fi
  fi
  for scope in "${scopes[@]}"; do
    record=$spec rc=0
    if [[ $scope == ufw ]]; then
      allows "$spec" || rc=$?
    else
      fwd_allows "$scope" "$spec" || rc=$?
      [[ $scope == offline ]] || record="$spec@$scope"
    fi
    ((rc != 0)) || continue
    ((rc == 1)) || { log_error "无法核对 $spec 的已有规则（$scope）"; return 1; }
    # 先记录已确认缺少的规则。命令部分生效或进程中断后，--undo 仍能逐条核对。
    if [[ " $S_RULES " != *" $record "* ]]; then
      previous=$S_RULES
      S_RULES+="${S_RULES:+ }$record"
      save_state || { S_RULES=$previous; return 1; }
    fi
    RUN_RULES+=("$record")
    if [[ $scope == ufw ]]; then
      run_task "放行 $spec" ufw allow "$spec" || return 1
    else
      run_task "放行 $spec（$scope）" fwd_cmd "$scope" --add-port="$spec" || return 1
    fi
  done
}

delete_rule() {
  local spec=${1%@*} scope rc added
  local -a scopes=(permanent runtime) # 无后缀是旧记录，或启动前写入的规则
  if [[ $BACKEND == ufw ]]; then
    added=$(LC_ALL=C ufw show added) || return 1
    if grep -qxF "ufw allow $spec" <<<"$added"; then ufw --force delete allow "$spec"; fi
    return
  fi
  if [[ $1 == *@* ]]; then scopes=("${1##*@}"); fi
  if ((!ACTIVE)); then
    [[ $1 != *@runtime ]] || return 0 # 服务停止时运行时规则已经消失
    scopes=(offline)
  fi
  for scope in "${scopes[@]}"; do
    rc=0; fwd_cmd "$scope" --query-port="$spec" >/dev/null || rc=$?
    ((rc != 1)) || continue
    ((rc == 0)) || return 1
    fwd_cmd "$scope" --remove-port="$spec" || return 1
  done
}

enable_backend() {
  case $BACKEND in
    ufw) ufw --force enable ;;
    firewalld)
      if ((RUN_ENABLED == 2)); then systemctl start firewalld; else systemctl enable --now firewalld; fi ;;
  esac
}

disable_backend() {
  case $BACKEND in
    ufw) ufw --force disable ;;
    firewalld)
      if (($1 == 2)); then systemctl stop firewalld; else systemctl disable --now firewalld; fi ;;
  esac
}

# revert 是否关闭防火墙 规则…：撤销指定的修改，并同步更新状态记录
revert() {
  local disable=$1 rule kept item failed=0
  shift
  if ((disable)); then
    run_task "关闭 $(backend_name "$BACKEND")" disable_backend "$disable" ||
      { log_error "关闭防火墙失败，已保留放行规则和撤销记录"; return 1; }
    S_ENABLED=0
    save_state || return 1
  fi
  if [[ $BACKEND == firewalld ]]; then read_firewall || return 1; fi
  for rule in "$@"; do
    if ! run_task "删除规则 $rule" delete_rule "$rule"; then failed=1; continue; fi
    kept=''
    for item in $S_RULES; do [[ $item == "$rule" ]] || kept+="${kept:+ }$item"; done
    S_RULES=$kept
    save_state || return 1
  done
  ((failed == 0)) || { log_error "部分规则未删除，已保留记录，请重试 --undo"; return 1; }
}

port_spec() {
  local port proto=tcp
  case $1 in
    */tcp | */udp) proto=${1##*/} ;;
    */*) return 1 ;;
  esac
  port=$(port_number "${1%/*}") || return 1
  printf '%s/%s\n' "$port" "$proto"
}

# 列出启用后会被挡住的服务，让用户选择一并放行的端口，结果追加到 RULES
choose_extra_ports() {
  local spec name input token normalized found i rc
  local -a blocked=() names=() docker=() picked tokens
  while read -r spec name; do
    [[ -n $spec ]] || continue
    rc=0; allows "$spec" || rc=$?
    ((rc != 0)) || continue
    if ((rc != 1)); then log_info "$spec 的现有策略需单独核对"; continue; fi
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
  (($# == 0)) || return 0 # 调用者已给出清单，仍展示监听情况
  ((${#blocked[@]})) || return 0
  while :; do
    input=$(ask "要一并放行哪些？输入端口（空格分隔），a = 全部，直接回车 = 都不放行：")
    read -ra tokens <<<"${input//$'\n'/ }"
    picked=()
    for token in ${tokens[@]+"${tokens[@]}"}; do
      if [[ $token == a || $token == all ]]; then
        picked+=("${blocked[@]}")
      elif normalized=$(port_spec "$token"); then
        found=0
        for spec in "${blocked[@]}"; do
          if [[ $spec == "$normalized" || ($token != */* && ${spec%/*} == "${normalized%/*}") ]]; then picked+=("$spec"); found=1; fi
        done
        ((found)) || picked+=("$normalized")
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
  local ssh_ok=0 rule state_text ssh_text
  for rule in "$@"; do
    rule=$(port_spec "$rule") || die "无效端口，请使用 1–65535 和 tcp 或 udp"
    RULES+=("$rule")
  done
  require_root
  lock_module firewall
  ui_title "防火墙" "确保 SSH 端口已放行，再启用防火墙。只在需要修改时才会询问。"
  PORT=$(detect_ssh_port) || die "无法确定 SSH 端口；为避免把自己锁在外面，已停止"
  BACKEND=$(backend)
  if [[ $BACKEND == none ]]; then
    log_warn "没有安装 UFW 或 Firewalld；本工具不会擅自安装防火墙"
    log_info "如需安装：Debian/Ubuntu 用 apt install ufw，RHEL 系用 dnf install firewalld，装好后重新运行"
    (($# == 0)); return
  fi
  read_firewall || die "无法读取防火墙状态，已停止"
  if [[ $BACKEND == firewalld ]]; then
    ((ACTIVE)) || command_exists firewall-offline-cmd ||
      die "Firewalld 未运行且缺少 firewall-offline-cmd，无法先放行 SSH 再启动，已停止"
    ZONE=$(fwd_zone)
  fi

  plan_allows "$PORT/tcp" && ssh_ok=1
  if ((ACTIVE)); then state_text=$(ui_good 已启用); else state_text=$(ui_bad 未启用); fi
  if ((ssh_ok)); then ssh_text=$(ui_good 已放行); else ssh_text=$(ui_bad 未放行); fi
  ui_kv "防火墙" "$(backend_name "$BACKEND") · $state_text${ZONE:+ · 区域 $ZONE}"
  ui_kv "SSH 端口" "$PORT/tcp · $ssh_text"
  RULES=("$PORT/tcp" ${RULES[@]+"${RULES[@]}"})
  if ((!ACTIVE)); then
    choose_extra_ports "$@"
  fi

  # 去重，并去掉已经放行的端口：已有规则不算本工具添加的，撤销时也就不会误删
  local -A seen=()
  local -a requested=() todo=()
  for rule in ${RULES[@]+"${RULES[@]}"}; do
    [[ -z ${seen[$rule]:-} ]] || continue
    seen[$rule]=1
    requested+=("$rule")
    if [[ $rule == "$PORT/tcp" ]]; then
      ((ssh_ok)) && continue
    elif plan_allows "$rule"; then continue; fi
    todo+=("$rule")
  done
  if ((ACTIVE && ${#todo[@]} == 0)); then
    log_ok "防火墙已启用，请求的端口已放行，无需修改"; return 0
  fi
  has_tty || die "防火墙修改需要交互终端，以便确认端口和验证新连接"
  local planned_backend=$BACKEND rule_zone=$ZONE was_active=$ACTIVE
  if [[ -f $STATE || -f $LEGACY_STATE ]]; then
    load_state || die "无法读取已有防火墙记录：$STATE_DIR"
    [[ $BACKEND == "$planned_backend" && $ZONE == "$rule_zone" ]] ||
      die "已有记录属于其他防火墙或区域，请先检查 $STATE_DIR"
  fi

  printf '\n'
  log_info "即将执行："
  for rule in ${todo[@]+"${todo[@]}"}; do log_info "• 放行 $rule"; done
  ((ACTIVE)) || log_info "• 启用 $(backend_name "$BACKEND")：除已放行的端口外，拒绝其他入站连接"
  log_info "• 云服务商的安全组不受影响，需要时请在服务商控制台另行放行"
  confirm "确认执行？" || { log_info "已取消，防火墙没有任何修改"; return 0; }

  # 等待确认期间，其他管理工具可能已调整规则、启动服务或切换区域。
  if [[ $(backend) != "$planned_backend" ]] || ! read_firewall; then
    die "防火墙状态已经变化或无法读取，请重新运行"
  fi
  if ((ACTIVE != was_active)) || { [[ $BACKEND == firewalld ]] && [[ $(fwd_zone) != "$rule_zone" ]]; }; then
    die "防火墙状态或区域已经变化，请重新运行"
  fi
  printf '\n'
  for rule in ${todo[@]+"${todo[@]}"}; do
    if ! add_rule "$rule"; then
      revert "$RUN_ENABLED" ${RUN_RULES[@]+"${RUN_RULES[@]}"}
      die "放行 $rule 失败，已撤销本次修改"
    fi
  done
  if ((!ACTIVE)); then
    RUN_ENABLED=1
    if [[ $BACKEND == firewalld ]] && systemctl is-enabled --quiet firewalld; then RUN_ENABLED=2; fi
    S_ENABLED=$RUN_ENABLED
    save_state # 先记录再启用：即使中途断开，也能用 --undo 撤销
    if ! run_task "启用 $(backend_name "$BACKEND")" enable_backend; then
      revert "$RUN_ENABLED" ${RUN_RULES[@]+"${RUN_RULES[@]}"}
      die "启用防火墙失败，已撤销本次修改"
    fi
  fi
  # 启用后重新检查。Firewalld 刚启动时，SSH 网卡可能属于默认区域以外的区域，要按实际区域检查
  local verified=1
  if ! read_firewall || ((!ACTIVE)); then
    verified=0
  elif [[ $BACKEND == firewalld ]] && ! ZONE=$(fwd_zone); then
    verified=0
  else
    for rule in "${requested[@]}"; do
      if ! allows "$rule"; then verified=0; break; fi
    done
  fi
  if ((!verified)); then
    ZONE=$rule_zone
    revert "$RUN_ENABLED" ${RUN_RULES[@]+"${RUN_RULES[@]}"}
    die "应用后端口检查未通过，已撤销本次修改"
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
  lock_module firewall
  if [[ ! -f $STATE && ! -f $LEGACY_STATE ]]; then log_info "没有本工具做过的防火墙修改，无需撤销"; return 0; fi
  load_state || die "无法读取已有防火墙记录：$STATE_DIR"
  local rule port
  ui_title "撤销防火墙修改"
  for rule in $S_RULES; do log_info "• 删除规则 $rule"; done
  if ((S_ENABLED)); then
    log_info "• 关闭 $(backend_name "$BACKEND")（它是本工具启用的）"
  elif is_active "$BACKEND" && port=$(detect_ssh_port) && [[ " $S_RULES " == *" $port/tcp "* || " $S_RULES " == *" $port/tcp@"* ]]; then
    log_warn "防火墙会继续运行，而 SSH 端口 $port 的放行规则将被删除；如果没有其他规则放行它，新的 SSH 连接会被拒绝"
  fi
  has_tty || die "撤销防火墙修改需要交互终端"
  confirm "确认撤销？" || { log_info "已取消"; return 0; }
  # shellcheck disable=SC2086  # 规则列表按空格拆分
  revert "$S_ENABLED" $S_RULES
  log_ok "已撤销本工具的防火墙修改"
}

summary() {
  is_root || { echo '需要 root'; return 0; }
  BACKEND=$(backend)
  [[ $BACKEND != none ]] || { ui_bad '未安装 UFW / Firewalld'; echo; return 0; }
  read_firewall || { ui_bad '无法读取防火墙状态'; echo; return 0; }
  if ((!ACTIVE)); then
    printf '%s · %s\n' "$(backend_name "$BACKEND")" "$(ui_bad 未启用)"
    return 0
  fi
  [[ $BACKEND != firewalld ]] || ZONE=$(fwd_zone)
  printf '%s · %s' "$(backend_name "$BACKEND")" "$(ui_good 已启用)"
  if PORT=$(detect_ssh_port); then
    if allows "$PORT/tcp"; then printf ' · SSH %s/tcp 已放行' "$PORT"
    elif (($? == 1)); then printf ' · %s' "$(ui_bad "SSH $PORT/tcp 未放行")"
    else printf ' · %s' "$(ui_bad "SSH $PORT/tcp 需核对已有规则")"; fi
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
  [[ ${1:-} == --allow ]] || (($# <= 1)) || die "参数过多：指定放行端口请使用 --allow"
  case ${1:-check} in
    --allow) shift; (($#)) || die "--allow 后需要至少一个端口"; check "$@" ;;
    check | firewall | menu) check ;;
    status) status ;;
    summary) summary ;;
    --undo | undo) undo ;;
    -h | --help) usage ;;
    *) log_error "未知命令：$1"; usage >&2; exit 2 ;;
  esac
}

main "$@"
