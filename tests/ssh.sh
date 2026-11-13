#!/usr/bin/env bash
# SSH 模块行为测试：在真实 sshd 上应用、撤销和回滚。需要 root，会临时修改本机 SSH 配置，测试结束后恢复。
# CI 会在多个发行版容器里运行；没有 systemd 时使用 tests/stubs 里的 systemctl 替身。
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SSH="$ROOT/modules/ssh.sh"
CONF=/etc/ssh/sshd_config
DROP=/etc/ssh/sshd_config.d/00-key-only.conf
EARLY=/etc/ssh/sshd_config.d/00-aaa-test.conf
AUTH=/root/.ssh/authorized_keys
STATE=/var/lib/vps-init/ssh

[[ $EUID -eq 0 ]] || { echo "需要 root 运行" >&2; exit 1; }
work=$(mktemp -d)
export VPS_INIT_LOG=$work/vps-init.log NO_COLOR=1
[[ -d /run/systemd/system ]] || export PATH="$ROOT/tests/stubs:$PATH"
unset SSH_CONNECTION

# 备份本机状态，结束时恢复
cp -a "$CONF" "$work/sshd_config"
[[ -f $AUTH ]] && cp -a "$AUTH" "$work/authorized_keys"
restore() {
  cp -a "$work/sshd_config" "$CONF"
  rm -rf "$DROP" "$EARLY" "$STATE"
  if [[ -f $work/authorized_keys ]]; then cp -a "$work/authorized_keys" "$AUTH"; else rm -f "$AUTH"; fi
  userdel -r vpsinit-test 2>/dev/null || true
  rm -rf "$work"
}
trap restore EXIT

passed=0 failed=0
report() {
  if (($1 == 0)); then
    printf '  ✓ %s\n' "$2"; passed=$((passed + 1))
  else
    printf '  ✗ %s\n' "$2"; failed=$((failed + 1)); sed 's/^/      | /' "$work/out"
  fi
}
ok() { local name=$1 rc=0; shift; "$@" >"$work/out" 2>&1 || rc=$?; report $((rc != 0)) "$name"; }
fails() { local name=$1 rc=0; shift; "$@" >"$work/out" 2>&1 || rc=$?; report $((rc == 0)) "$name"; }
eff() { sshd -T | awk -v k="$1" '$1 == k {print $2}'; }
is() { [[ $1 == "$2" ]]; }
contains() { grep -qF -- "$2" <<<"$1"; }
matches() { [[ $1 =~ $2 ]]; }
nkeys() { grep -c . "$AUTH" 2>/dev/null || true; }
clean() { rm -rf "$DROP" "$EARLY" "$STATE" "$AUTH"; cp -a "$work/sshd_config" "$CONF"; }

ssh-keygen -q -t ed25519 -N '' -C laptop -f "$work/k1"
ssh-keygen -q -t rsa -b 2048 -N '' -C phone -f "$work/k2"
K1=$(cat "$work/k1.pub") K2=$(cat "$work/k2.pub")
install -d /run/sshd 2>/dev/null || true
echo "OpenSSH：$( { ssh -V || sshd -V; } 2>&1 | head -n 1)"
clean
PW_BEFORE=$(eff passwordauthentication)

echo "输入校验"
fails "拒绝占位符公钥" bash "$SSH" 'ssh-ed25519 AAAA... 这里替换为你的公钥'
fails "拒绝私钥" bash "$SSH" "$(cat "$work/k1")"
fails "拒绝明文 http 网址" bash "$SSH" http://example.com/key.pub
command -v setpriv >/dev/null && fails "拒绝非 root 运行" setpriv --reuid=65534 --regid=65534 --clear-groups bash "$SSH" "$K1"
ok "以上都没有做任何修改" is "$(ls "$DROP" "$STATE" 2>/dev/null)" ""

echo "应用与撤销"
ok "添加公钥并关闭密码登录" bash "$SSH" "$K1"
ok "密码登录已关闭" is "$(eff passwordauthentication)" no
ok "键盘交互认证已关闭" is "$(eff kbdinteractiveauthentication)" no
ok "root 仅允许密钥" matches "$(eff permitrootlogin)" '^(prohibit|without)-password$' # OpenSSH 10 起显示为 prohibit-password
ok "重复运行（同一把钥匙换了备注）" bash "$SSH" "${K1/laptop/termius}"
ok "公钥没有重复添加" is "$(nkeys)" 1
ok "一次添加多把公钥" bash "$SSH" "$K1"$'\n'"$K2"
ok "共 2 把公钥" is "$(nkeys)" 2
ok "撤销" bash "$SSH" --undo
ok "撤销后恢复原登录方式" is "$(eff passwordauthentication)" "$PW_BEFORE"
ok "撤销后不留配置和状态" is "$(ls "$DROP" "$STATE" 2>/dev/null)" ""
ok "撤销保留已添加的公钥" is "$(nkeys)" 2
ok "没有配置时撤销也正常退出" bash "$SSH" --undo

echo "安全回滚"
clean
echo 'PasswordAuthentication yes' >"$EARLY"
fails "被更早的配置覆盖时拒绝" bash "$SSH" "$K1"
ok "回滚后不留配置和状态" is "$(ls "$DROP" "$STATE" 2>/dev/null)" ""
clean
printf '\nMatch User root\n    PasswordAuthentication yes\n' >>"$CONF"
fails "被 Match 规则覆盖时拒绝" bash "$SSH" "$K1"
ok "回滚后不留配置和状态" is "$(ls "$DROP" "$STATE" 2>/dev/null)" ""
clean
sed -i 's/^[[:space:]]*Include/#&/I' "$CONF"
fails "sshd_config 没有 Include 时拒绝" bash "$SSH" "$K1"
ok "没有改动主配置" is "$(cat "$CONF")" "$(sed 's/^[[:space:]]*Include/#&/I' "$work/sshd_config")"

echo "重复运行时的回滚"
clean
ok "首次应用" bash "$SSH" "$K1"
echo 'PasswordAuthentication yes' >"$EARLY"
fails "再次运行时校验未通过" bash "$SSH" "$K1"
ok "保留上一次运行的配置文件" grep -q '由 ssh-key-only.sh 生成' "$DROP"
ok "保留上一次运行的状态记录" test -f "$STATE/managed"
rm -f "$EARLY"
ok "之后仍可正常撤销" bash "$SSH" --undo
ok "撤销后不留配置和状态" is "$(ls "$DROP" "$STATE" 2>/dev/null)" ""

echo "提醒没有公钥的普通用户"
if command -v useradd >/dev/null; then
  clean
  useradd -m -s /bin/bash -u 4242 vpsinit-test
  output=$(bash "$SSH" "$K1" 2>&1) || true
  ok "列出之后无法用密码登录的用户" contains "$output" "vpsinit-test"
  bash "$SSH" --undo >/dev/null
  userdel -r vpsinit-test 2>/dev/null || true
fi

echo "不覆盖用户配置、兼容旧版本"
clean
echo 'PasswordAuthentication no' >"$DROP"
fails "拒绝覆盖用户自己的同名文件" bash "$SSH" "$K1"
ok "用户的文件原样保留" grep -qx 'PasswordAuthentication no' "$DROP"
clean
printf '# 由 ssh-key-only.sh 生成\nPasswordAuthentication no\n' >"$DROP"
ok "接管早期版本写入的配置" bash "$SSH" "$K1"
ok "撤销时还原早期版本的文件" bash "$SSH" --undo
ok "早期版本的文件已还原" grep -q '由 ssh-key-only.sh 生成' "$DROP"
ok "再次撤销会删除早期版本的文件" bash "$SSH" --undo
ok "早期版本的文件已删除" is "$(ls "$DROP" 2>/dev/null)" ""

echo "非交互环境"
clean
if command -v setsid >/dev/null; then
  fails "没有终端时向导报错退出，不会卡住" timeout 10 setsid -w bash "$SSH" </dev/null
fi

printf '\n通过 %d 项，失败 %d 项\n' "$passed" "$failed"
((failed == 0))
