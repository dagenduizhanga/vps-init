#!/usr/bin/env bash
# SSH 密钥登录向导：为 root 安装公钥，并关闭密码登录。
# 支持交互向导、公钥参数、GitHub 公钥导入和撤销。
set -Eeuo pipefail
export PATH="$PATH:/usr/sbin:/sbin"

URL="https://raw.githubusercontent.com/dagenduizhanga/vps-init/main/ssh-key-only.sh"
DROP="/etc/ssh/sshd_config.d/00-key-only.conf"
AUTH="/root/.ssh/authorized_keys"
STATE="/var/lib/vps-init/ssh"
BACKUP="$STATE/00-key-only.conf.backup"
MARKER="$STATE/original-existed"
KEYS=()
LOCK_FILE="/run/lock/vps-init-ssh.lock"

if [[ -t 1 ]]; then R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[1m'; N=$'\033[0m'; else R=''; G=''; Y=''; B=''; N=''; fi
err() { echo "${R}✗ $*${N}" >&2; }
die() { err "$@"; exit 1; }
ok() { echo "${G}✓${N} $*"; }
warn() { echo "${Y}⚠${N} $*" >&2; }
step() { echo; echo "${B}[$1/4] $2${N}"; }

ask() {
  local answer extra
  [[ -r /dev/tty ]] || die "没有可交互终端"
  printf '%s' "$1" >/dev/tty
  IFS= read -r answer </dev/tty || die "已取消"
  while IFS= read -r -t 0.2 extra </dev/tty; do answer+=$'\n'$extra; done
  printf '%s' "$answer"
}
confirm() { [[ "$(ask "$1 [y/N] ")" =~ ^[Yy]([Ee][Ss])?$ ]]; }
fp() { ssh-keygen -lf - <<<"$1" 2>/dev/null | awk '{print $2}'; }
list_auth() { [[ -f "$AUTH" ]] && ssh-keygen -lf "$AUTH" 2>/dev/null || true; }

fetch() {
  case "$1" in
    gh:*)
      local user="${1#gh:}"
      [[ "$user" =~ ^[A-Za-z0-9-]+$ ]] || return 1
      curl -fsSL --connect-timeout 8 --max-time 20 --max-filesize 262144 "https://github.com/$user.keys"
      ;;
    https://*)
      curl -fsSL --connect-timeout 8 --max-time 20 --max-filesize 262144 "$1"
      ;;
    http://*) err "为避免明文传输，公钥网址必须使用 HTTPS"; return 1 ;;
    *) printf '%s\n' "$1" ;;
  esac
}

add_keys() {
  local line key_type key_blob
  local -a new=()
  [[ "$1" == *"PRIVATE KEY"* ]] && { err "检测到私钥内容！这里只接受公钥，绝不要上传私钥。"; return 1; }
  while IFS= read -r line; do
    line="${line%$'\r'}"
    [[ -z "${line//[[:space:]]/}" || "$line" == \#* ]] && continue
    read -r key_type key_blob _ <<<"$line"
    [[ -n "$key_type" && -n "$key_blob" && -n "$(fp "$line")" ]] || { err "发现无效公钥：$key_type ${key_blob:0:16}"; return 1; }
    new+=("$line")
  done <<<"$1"
  ((${#new[@]} > 0)) || { err "没有找到有效公钥"; return 1; }
  KEYS+=("${new[@]}")
  for line in "${new[@]}"; do ok "$(ssh-keygen -lf - <<<"$line")"; done
}

precheck() {
  command -v sshd >/dev/null 2>&1 || die "没有找到 sshd，请先安装 OpenSSH Server"
  [[ -r /etc/ssh/sshd_config ]] || die "无法读取 /etc/ssh/sshd_config"
  grep -Eiq '^[[:space:]]*Include[[:space:]].*sshd_config\.d' /etc/ssh/sshd_config ||
    die "当前 SSH 主配置未启用 sshd_config.d，拒绝直接修改主配置"
  sshd -t || die "当前 SSH 配置已经存在错误，请先修复"
}

reload_sshd() {
  sshd -t || return 1
  if command -v systemctl >/dev/null 2>&1; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null
  elif command -v service >/dev/null 2>&1; then
    service ssh reload 2>/dev/null || service sshd reload 2>/dev/null
  else
    err "未找到可用的服务管理命令，配置已写入但未能重载 SSH"
    return 1
  fi
}

restore_config() {
  install -d -m 755 "$(dirname "$DROP")"
  if [[ -f "$MARKER" && "$(cat "$MARKER")" == yes ]]; then
    [[ -f "$BACKUP" ]] || { err "找不到原配置备份：$BACKUP"; return 1; }
    install -m 600 "$BACKUP" "$DROP.restore"
    mv -f "$DROP.restore" "$DROP"
  else
    rm -f "$DROP"
  fi
}

undo() {
  if [[ ! -f "$STATE/managed" ]]; then
    # 兼容旧版本：旧版只写入固定 drop-in 文件，没有独立状态目录。
    if [[ -f "$DROP" ]] && grep -q '由 ssh-key-only.sh 生成' "$DROP"; then
      rm -f "$DROP"
      sshd -t || die "删除旧版配置后 SSH 检查失败，请勿关闭当前连接"
      reload_sshd || die "旧版配置已删除，但 SSH 服务重载失败"
      ok "已撤销旧版本 SSH 配置；公钥保留"
      return 0
    fi
    die "没有找到本工具的 SSH 配置记录，未执行撤销"
  fi
  restore_config || die "恢复原 SSH 配置失败"
  sshd -t || die "恢复后的 SSH 配置检查失败，请勿关闭当前连接"
  reload_sshd || die "配置已恢复，但 SSH 服务重载失败；请检查服务状态"
  rm -rf "$STATE"
  ok "已撤销本工具的 SSH 设置；已安装的公钥会保留"
}

save_original() {
  install -d -m 700 "$STATE"
  if [[ -f "$STATE/managed" ]]; then return 0; fi
  if [[ -e "$DROP" ]]; then
    # 只接管本工具旧版本生成的文件；不覆盖用户自己的同名配置。
    grep -q '由 ssh-key-only.sh 生成' "$DROP" || die "$DROP 已存在且不是本工具生成，拒绝覆盖"
    install -m 600 "$DROP" "$BACKUP"
    printf 'yes\n' >"$MARKER"
  else
    printf 'no\n' >"$MARKER"
  fi
  printf 'vps-init-ssh\n' >"$STATE/managed"
}

rollback_apply() {
  local reason="$1"
  restore_config || warn "自动恢复配置失败，请保持当前 SSH 会话并使用服务商控制台修复"
  if sshd -t; then
    if ! reload_sshd; then warn "回滚后 SSH 服务重载失败，请保持当前连接"; fi
  else
    warn "回滚后 SSH 配置检查失败，请保持当前连接"
  fi
  die "$reason；已尝试恢复原 SSH 配置"
}

apply() {
  local key fingerprint existing_fingerprints tmp effective context
  install -d -m 700 /root/.ssh
  touch "$AUTH"
  chmod 600 "$AUTH"
  existing_fingerprints="$(list_auth | awk '{print $2}')"
  for key in "${KEYS[@]}"; do
    fingerprint="$(fp "$key")"
    if ! grep -qxF "$fingerprint" <<<"$existing_fingerprints"; then
      printf '%s\n' "$key" >>"$AUTH"
      existing_fingerprints+=$'\n'$fingerprint
    fi
  done
  command -v restorecon >/dev/null 2>&1 && restorecon -R /root/.ssh || true
  [[ -n "$(list_auth)" ]] || die "root 没有任何有效公钥，不能关闭密码登录"

  save_original
  install -d -m 755 /etc/ssh/sshd_config.d
  tmp=$(mktemp /etc/ssh/sshd_config.d/.vps-init.XXXXXX)
  cat >"$tmp" <<'EOF'
# 由 ssh-key-only.sh 生成；撤销请运行 --undo
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
  chmod 600 "$tmp"
  mv -f "$tmp" "$DROP"

  sshd -t || rollback_apply "SSH 配置语法检查失败"
  context="user=root,host=localhost,addr=127.0.0.1"
  effective=$(sshd -T -C "$context" 2>&1) || rollback_apply "无法读取 SSH 最终生效配置"
  for setting in "pubkeyauthentication yes" "passwordauthentication no" "kbdinteractiveauthentication no"; do
    grep -qx "$setting" <<<"$effective" || rollback_apply "SSH 最终配置未满足：$setting"
  done
  grep -Eq '^permitrootlogin (prohibit-password|without-password)$' <<<"$effective" || rollback_apply "root 密钥登录策略未生效"
  reload_sshd || rollback_apply "SSH 服务重载失败"
  ok "已启用密钥登录并关闭密码及键盘交互认证"
}

wizard() {
  local existing choice source username
  [[ -r /dev/tty ]] || die "没有可交互终端；自动化请直接传入公钥参数"
  echo "${B}SSH 密钥登录向导${N}"
  echo "将为 root 配置公钥并关闭密码登录；确认之前不会修改 SSH 配置。"
  step 1 "检查环境"
  precheck
  # shellcheck disable=SC1091
  ok "$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Linux}")"
  existing="$(list_auth)"
  if [[ -n "$existing" ]]; then echo "root 当前已有公钥："; printf '%s\n' "$existing" | sed 's/^/  /'; else echo "root 当前没有公钥。"; fi
  step 2 "添加公钥"
  while true; do
    echo "  1) 粘贴公钥"
    echo "  2) 从 GitHub 账号导入"
    [[ -n "$existing" && "${#KEYS[@]}" -eq 0 ]] && echo "  3) 使用现有公钥"
    choice="$(ask "请选择 [1]：")"
    case "${choice//[[:space:]]/}" in
      ""|1) source="$(ask "粘贴公钥后回车：")" ;;
      2)
        username="$(ask "GitHub 用户名：")"
        username="${username//[[:space:]]/}"
        [[ "$username" =~ ^[A-Za-z0-9-]+$ ]] || { err "用户名格式不正确"; continue; }
        source="$(fetch "gh:$username")" || { err "获取公钥失败"; continue; }
        warn "将导入该账号的全部公开 SSH 公钥，请确认账号归属正确。"
        ;;
      3) [[ -n "$existing" && "${#KEYS[@]}" -eq 0 ]] && break; err "选项无效"; continue ;;
      *) err "选项无效"; continue ;;
    esac
    add_keys "$source" || continue
    confirm "还要添加其他公钥吗？" || break
  done
  step 3 "确认"
  if ((${#KEYS[@]} > 0)); then echo "将新增 ${#KEYS[@]} 把公钥（已存在的指纹会跳过）。"; fi
  echo "将关闭密码登录，并限制 root 只能使用密钥登录。"
  echo "原 SSH 配置会备份到 $STATE，撤销时恢复；公钥会保留。"
  confirm "确认执行？" || die "已取消，未修改 SSH 配置"
  step 4 "应用"
  apply
  warn "请保持当前窗口打开，另开终端测试密钥登录。"
  if confirm "新窗口已经成功登录了吗？"; then
    ok "SSH 密钥登录配置完成"
  else
    undo
    warn "已尝试恢复原登录策略；请确认公钥和客户端密钥匹配后再试。"
  fi
}

main() {
  if [[ "${1-}" == "-h" || "${1-}" == "--help" ]]; then
    echo "用法：bash <(curl -fsSL $URL) [公钥 | gh:用户名 | https://网址 | --undo]"
    return 0
  fi
  [[ "$EUID" -eq 0 ]] || die "请使用 root 运行"
  if command -v flock >/dev/null 2>&1; then
    install -d -m 755 "$(dirname "$LOCK_FILE")"
    exec 9>"$LOCK_FILE"
    flock -n 9 || die "另一个 SSH 配置任务正在运行"
  fi
  (($# <= 1)) || die "参数过多；公钥参数请整体加引号"
  case "${1-}" in
    "") wizard ;;
    --undo) command -v sshd >/dev/null 2>&1 || die "没有找到 sshd"; undo ;;

    *)
      precheck
      source="$(fetch "$1")" || die "获取公钥失败"
      add_keys "$source" || exit 1
      apply
      warn "请保持当前连接，并另开窗口测试密钥登录后再退出。"
      ;;
  esac
}
main "$@"
