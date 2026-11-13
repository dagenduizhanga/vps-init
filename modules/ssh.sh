#!/usr/bin/env bash
# SSH 密钥登录：为 root 安装公钥并关闭密码登录。支持交互向导、命令参数和撤销。
set -Eeuo pipefail
MODULE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$MODULE_DIR/../lib/common.sh"

DROP=/etc/ssh/sshd_config.d/00-key-only.conf
AUTH=/root/.ssh/authorized_keys
LOCK=/run/lock/vps-init-ssh.lock
SIGNATURE='由 ssh-key-only.sh 生成' # 本工具写入的配置都带这句，用来识别
# 状态文件格式与 0.3.x 保持一致，旧版本留下的记录可以直接撤销
STATE=/var/lib/vps-init/ssh
BACKUP=$STATE/00-key-only.conf.backup
MARKER=$STATE/original-existed
KEYS=()

usage() {
  cat <<EOF
用法：ssh.sh [参数]

  （无参数）          交互向导
  'ssh-ed25519 AAAA…' 直接添加这把公钥（多行即多把）
  gh:<用户名>         导入 github.com/<用户名>.keys 上的全部公钥
  https://…           从网址获取公钥
  --undo              撤销：恢复原来的登录方式（已添加的公钥保留）
  status              查看 SSH 登录状态
EOF
}

# ---------- 公钥 ----------
fingerprint() { ssh-keygen -lf - <<<"$1" 2>/dev/null | awk '{print $2}'; }
list_auth() { if [[ -f $AUTH ]]; then ssh-keygen -lf "$AUTH" 2>/dev/null || true; fi; }

# 把 ssh-keygen -l 的输出排成「类型  指纹  备注」
print_keys() {
  awk '{
    type = $NF; gsub(/[()]/, "", type); note = ""
    for (i = 3; i < NF; i++) note = note (i > 3 ? " " : "") $i
    if (note == "no comment") note = "（无备注）"
    printf "      %-8s %s  %s\n", type, $2, note
  }'
}

fetch() {
  local curl_opts=(--proto '=https' -fsSL --connect-timeout 8 --max-time 20 --max-filesize 262144)
  case $1 in
    gh:*)
      [[ ${1#gh:} =~ ^[A-Za-z0-9-]+$ ]] || return 1
      curl "${curl_opts[@]}" "https://github.com/${1#gh:}.keys"
      ;;
    https://*) curl "${curl_opts[@]}" "$1" ;;
    http://*) log_error "为避免公钥在传输中被篡改，网址必须使用 HTTPS"; return 1 ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# 校验一段文本里的公钥：全部有效才加入 KEYS
add_keys() {
  local line type blob
  local -a new=()
  if [[ $1 == *"PRIVATE KEY"* ]]; then
    log_error "这是私钥！私钥只能留在你自己的设备上，这里需要的是公钥（ssh-ed25519 或 ssh-rsa 开头的一行）"
    return 1
  fi
  while IFS= read -r line; do
    line=${line%$'\r'}
    [[ -z ${line//[[:space:]]/} || $line == \#* ]] && continue
    read -r type blob _ <<<"$line"
    [[ -n $(fingerprint "$line") ]] || { log_error "无效公钥：$type ${blob:0:16}…"; return 1; }
    new+=("$line")
  done <<<"$1"
  ((${#new[@]})) || { log_error "没有找到公钥"; return 1; }
  KEYS+=("${new[@]}")
  for line in "${new[@]}"; do ssh-keygen -lf - <<<"$line"; done | print_keys
}

# ---------- sshd ----------
sshd_version() { { ssh -V || sshd -V; } 2>&1 | grep -oE 'OpenSSH_[0-9.]+(p[0-9]+)?' | head -n 1 | tr _ ' ' || true; }

precheck() {
  command_exists sshd || die "没有找到 sshd，请先安装 openssh-server"
  # Debian/Ubuntu 的 sshd 在服务未运行时（例如从 VNC 控制台操作）缺这个目录会导致 sshd -t 报错
  [[ -d /run/sshd || ! -f /etc/debian_version ]] || install -d -m 755 /run/sshd
  grep -Eiq '^[[:space:]]*Include[[:space:]].*sshd_config\.d' /etc/ssh/sshd_config ||
    die "sshd_config 没有启用 sshd_config.d（OpenSSH 8.2 以下的老系统）；本工具不会直接修改主配置"
  sshd -t || die "当前 SSH 配置本身有错误（sshd -t 未通过），请先修复"
}

reload_sshd() {
  sshd -t || return 1
  if command_exists systemctl && systemctl --version >/dev/null 2>&1; then
    # try-reload-or-restart：服务在运行就重载，没运行（如按需启动的 ssh.socket）就什么都不做
    systemctl try-reload-or-restart ssh 2>/dev/null || systemctl try-reload-or-restart sshd 2>/dev/null
  elif command_exists rc-service; then
    rc-service sshd reload
  elif command_exists service; then
    service ssh reload 2>/dev/null || service sshd reload
  else
    log_error "未找到服务管理命令，无法重载 sshd"
    return 1
  fi
}

# ---------- 备份与恢复 ----------
save_original() {
  install -d -m 700 "$STATE"
  [[ -f $STATE/managed ]] && return 0
  if [[ -e $DROP ]]; then
    grep -q "$SIGNATURE" "$DROP" || die "$DROP 已存在且不是本工具生成的；为避免覆盖你的配置，已停止"
    install -m 600 "$DROP" "$BACKUP"
    stat -c '%a' "$DROP" >"$STATE/original-mode"
    echo yes >"$MARKER"
  else
    echo no >"$MARKER"
  fi
  echo vps-init-ssh >"$STATE/managed"
}

restore_original() {
  if [[ $(cat "$MARKER" 2>/dev/null) == yes ]]; then
    [[ -f $BACKUP ]] || { log_error "找不到原配置备份：$BACKUP"; return 1; }
    local mode=600
    [[ -f $STATE/original-mode ]] && read -r mode <"$STATE/original-mode"
    install -m "$mode" "$BACKUP" "$DROP.tmp" && mv -f "$DROP.tmp" "$DROP"
  else
    rm -f "$DROP"
  fi
}

# 回滚只撤销本次运行的改动：配置文件恢复成运行前的样子；状态目录是本次创建的才删除
rollback() {
  if [[ -n $PREV_MODE ]]; then
    if ! { printf '%s\n' "$PREV_DROP" >"$DROP.tmp" && chmod "$PREV_MODE" "$DROP.tmp" && mv -f "$DROP.tmp" "$DROP"; }; then
      log_warn "自动恢复失败；请保持当前连接，必要时用服务商的 VNC 控制台修复"
    fi
  else
    rm -f "$DROP"
  fi
  ((HAD_STATE)) || rm -rf "$STATE"
  if sshd -t 2>/dev/null; then reload_sshd >/dev/null 2>&1 || true; fi
  die "$1；SSH 配置已恢复到本次运行之前，登录方式没有改变"
}

# 有登录 shell、却没有配置公钥的普通用户：关闭密码登录后他们将无法通过 SSH 登录
warn_password_users() {
  local user home users=''
  while IFS=: read -r user home; do
    [[ -s $home/.ssh/authorized_keys ]] || users+="${users:+、}$user"
  done < <(awk -F: '$3 >= 1000 && $3 < 60000 && $7 !~ /(nologin|false|sync)$/ {print $1 ":" $6}' /etc/passwd)
  [[ -z $users ]] || log_warn "这些用户还没有配置公钥，之后将无法用密码通过 SSH 登录：$users"
}

undo() {
  if [[ -f $STATE/managed ]]; then
    restore_original || die "恢复原 SSH 配置失败"
  elif [[ -f $DROP ]] && grep -q "$SIGNATURE" "$DROP"; then
    rm -f "$DROP" # 早期版本只写这一个文件，没有状态目录
  else
    log_info "没有本工具的 SSH 配置，无需撤销"
    return 0
  fi
  reload_sshd || die "配置已恢复，但重载 sshd 失败；请保持当前连接并检查 sshd 状态"
  rm -rf "$STATE"
  log_ok "已撤销：SSH 恢复为原来的登录方式（已添加的公钥保留）"
}

# ---------- 应用 ----------
apply() {
  local key fp have tmp effective setting addr=${SSH_CONNECTION:-127.0.0.1}

  # 1. 安装公钥：按指纹去重，备注不同也不会重复添加
  install -d -m 700 /root/.ssh
  touch "$AUTH" && chmod 600 "$AUTH"
  [[ -s $AUTH && -n $(tail -c 1 "$AUTH") ]] && printf '\n' >>"$AUTH" # 补上文件末尾缺的换行
  have=$(list_auth | awk '{print $2}')
  if ((${#KEYS[@]})); then
    for key in "${KEYS[@]}"; do
      fp=$(fingerprint "$key")
      grep -qxF "$fp" <<<"$have" && continue
      printf '%s\n' "$key" >>"$AUTH"
      have+=$'\n'$fp
    done
  fi
  if command_exists restorecon; then restorecon -R /root/.ssh || true; fi
  [[ -n $(list_auth) ]] || die "root 没有任何有效公钥，不能关闭密码登录"

  # 2. 写入配置：先记下运行前的状态（用于回滚），再写临时文件、原子替换
  PREV_DROP='' PREV_MODE='' HAD_STATE=0
  if [[ -f $DROP ]]; then PREV_DROP=$(cat "$DROP") PREV_MODE=$(stat -c '%a' "$DROP"); fi
  if [[ -f $STATE/managed ]]; then HAD_STATE=1; fi
  save_original
  install -d -m 755 /etc/ssh/sshd_config.d
  tmp=$(mktemp /etc/ssh/sshd_config.d/.vps-init.XXXXXX)
  cat >"$tmp" <<EOF
# $SIGNATURE（vps-init）；撤销：$(cmd_hint ssh --undo)
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin prohibit-password
EOF
  chmod 600 "$tmp"
  mv -f "$tmp" "$DROP"

  # 3. 校验语法，再按「root + 当前来源地址」计算最终生效值（会套用 Match 规则），全部通过才重载
  sshd -t || rollback "sshd 语法检查未通过"
  effective=$(sshd -T -C "user=root,host=${HOSTNAME:-localhost},addr=${addr%% *}" 2>&1) ||
    rollback "无法读取 sshd 最终生效配置"
  for setting in "pubkeyauthentication yes" "passwordauthentication no" "kbdinteractiveauthentication no"; do
    grep -qx "$setting" <<<"$effective" || rollback "最终生效值不是「$setting」（可能被 Match 规则或更早的配置覆盖）"
  done
  # OpenSSH 8.7 以前，ChallengeResponseAuthentication 会重新打开键盘交互（密码）认证
  if grep -q '^challengeresponseauthentication ' <<<"$effective"; then
    grep -qx 'challengeresponseauthentication no' <<<"$effective" ||
      rollback "ChallengeResponseAuthentication 仍是开启状态"
  fi
  grep -Eqx 'permitrootlogin (prohibit-password|without-password)' <<<"$effective" ||
    rollback "root 仅密钥登录的策略没有生效"
  reload_sshd || rollback "重载 sshd 失败"
}

# ---------- 状态 ----------
# 读取 sshd 当前设置：PW（密码登录是否关闭）、ROOT（root 登录策略）、NKEYS（root 公钥数）
read_facts() {
  local eff
  eff=$(sshd -T 2>/dev/null) || return 1
  PW=closed
  grep -qx 'passwordauthentication no' <<<"$eff" && grep -qx 'kbdinteractiveauthentication no' <<<"$eff" || PW=open
  case $(awk '$1 == "permitrootlogin" {print $2}' <<<"$eff") in
    no) ROOT='禁止登录' ;;
    prohibit-password | without-password) ROOT='仅密钥' ;;
    forced-commands-only) ROOT='仅限指定命令' ;;
    *) ROOT='允许密码' ;;
  esac
  NKEYS=$(list_auth | grep -c . || true)
}

summary() {
  is_root || { echo '需要 root'; return 0; }
  command_exists sshd || { ui_bad '未安装 sshd'; echo; return 0; }
  read_facts || { ui_bad '无法读取配置'; echo; return 0; }
  if [[ $PW == closed ]]; then ui_good '密码登录已关闭'; else ui_bad '密码登录开启中'; fi
  printf ' · root %s · %s 把公钥\n' "$ROOT" "$NKEYS"
}

status() {
  ui_title "SSH"
  is_root || { log_info "需要 root 才能读取 SSH 配置"; return 0; }
  command_exists sshd || { log_warn "未安装 sshd"; return 0; }
  read_facts || { log_warn "无法读取 sshd 配置"; return 0; }
  ui_kv "版本" "$(sshd_version)"
  ui_kv "端口" "$(detect_ssh_port || echo 未知)"
  ui_kv "密码登录" "$(if [[ $PW == closed ]]; then ui_good 已关闭; else ui_bad 开启中; fi)"
  ui_kv "root 登录" "$ROOT"
  ui_kv "root 公钥" "$NKEYS 把"
  ui_kv "本工具配置" "$(if [[ -f $DROP ]]; then echo "已应用（$DROP）"; else echo 未应用; fi)"
}

# ---------- 交互向导 ----------
wizard() {
  local existing choice src user
  ui_title "SSH 密钥登录" "为 root 安装公钥并关闭密码登录。确认之前不会做任何修改。"

  ui_step 1 4 "检查环境"
  precheck
  detect_os
  log_ok "$OS_NAME · $(sshd_version)"
  existing=$(list_auth)
  if [[ -n $existing ]]; then
    log_info "root 已有 $(grep -c . <<<"$existing") 把公钥："
    print_keys <<<"$existing"
  else
    log_info "root 目前没有公钥"
  fi

  ui_step 2 4 "添加公钥"
  while :; do
    ui_item 1 "粘贴公钥" "Termius 或 ~/.ssh/id_ed25519.pub 里的内容"
    ui_item 2 "从 GitHub 导入" "github.com/用户名.keys 上的全部公钥"
    if [[ -n $existing ]] && ((${#KEYS[@]} == 0)); then ui_item 3 "使用已有公钥" "不添加新公钥"; fi
    choice=$(ask "请选择 [1]：")
    case ${choice//[[:space:]]/} in
      '' | 1) src=$(ask "粘贴公钥后回车：") ;;
      2)
        user=$(ask "GitHub 用户名：")
        user=${user//[[:space:]]/}
        src=$(fetch "gh:$user") || { log_error "获取失败：请检查用户名和网络"; continue; }
        log_warn "将导入 $user 账号上的全部公钥，每一把都能以 root 登录"
        ;;
      3)
        if [[ -n $existing ]] && ((${#KEYS[@]} == 0)); then break; fi
        log_error "请输入列表中的数字"; continue
        ;;
      *) log_error "请输入列表中的数字"; continue ;;
    esac
    add_keys "$src" || continue
    confirm "还要添加其他公钥吗？" || break
  done

  ui_step 3 4 "确认"
  if ((${#KEYS[@]})); then log_info "• 添加上面 ${#KEYS[@]} 把公钥（已存在的自动跳过）"; fi
  log_info "• 关闭所有用户的密码登录和键盘交互认证（不只是 root）"
  log_info "• root 只能用密钥登录"
  log_info "• 配置写入 $DROP，可以随时撤销"
  warn_password_users
  confirm "确认执行？" || die "已取消，没有做任何修改"

  ui_step 4 4 "应用"
  apply
  log_ok "已启用密钥登录，密码登录已关闭"

  printf '\n'
  log_warn "先别关闭这个窗口！新开一个终端，用密钥登录这台服务器试试"
  if confirm "新窗口登录成功了吗？（回答 n 会立即撤销）"; then
    log_ok "完成。如需撤销：$(cmd_hint ssh --undo)"
  else
    undo
    log_warn "已恢复密码登录。请确认这里添加的公钥与客户端使用的私钥是同一对，然后再试"
  fi
}

main() {
  case ${1-} in
    -h | --help) usage; return 0 ;;
    status) status; return 0 ;;
    summary) summary; return 0 ;;
  esac
  require_root
  (($# <= 1)) || die "参数过多：公钥请整体加引号"
  if command_exists flock; then
    install -d -m 755 "${LOCK%/*}"
    exec 9>"$LOCK"
    flock -n 9 || die "另一个 SSH 配置任务正在运行"
  fi
  case ${1-} in
    '')
      has_tty || die "需要交互终端；自动化请直接传入公钥，例如：ssh.sh 'ssh-ed25519 AAAA…'"
      wizard
      ;;
    --undo) undo ;;
    *)
      local src
      precheck
      src=$(fetch "$1") || die "获取公钥失败：$1"
      add_keys "$src" || exit 1
      warn_password_users
      apply
      log_ok "已启用密钥登录，密码登录已关闭"
      log_warn "请保持当前连接，另开窗口确认密钥能登录后再退出"
      ;;
  esac
}

main "$@"
