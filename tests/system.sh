#!/usr/bin/env bash
# 系统模块行为测试：实际执行初始化（时区、校时、常用工具）和系统更新。
# 会修改时区、安装软件包、升级系统，只应在一次性环境（CI 容器或虚拟机）中以 root 运行。
# SKIP_UPDATE=1 时跳过系统更新（在软件包很多的虚拟机上会很慢）。
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SYSTEM="$ROOT/modules/system.sh"
[[ $EUID -eq 0 ]] || { echo "需要 root 运行" >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export VPS_INIT_LOG=$work/vps-init.log NO_COLOR=1

passed=0 failed=0
report() {
  if (($1 == 0)); then
    printf '  ✓ %s\n' "$2"; passed=$((passed + 1))
  else
    printf '  ✗ %s\n' "$2"; failed=$((failed + 1)); sed 's/^/      | /' "$work/out"
  fi
}
# 每条命令的输出另存到 $work/last，供下一条断言检查
ok() { local name=$1 rc=0; shift; "$@" >"$work/out" 2>&1 || rc=$?; report $((rc != 0)) "$name"; cp "$work/out" "$work/last"; }
fails() { local name=$1 rc=0; shift; "$@" >"$work/out" 2>&1 || rc=$?; report $((rc == 0)) "$name"; cp "$work/out" "$work/last"; }
contains() { grep -qF -- "$2" <<<"$1"; }
lacks() { ! grep -qF -- "$2" <<<"$1"; }
tz_now() {
  local tz=''
  command -v timedatectl >/dev/null && tz=$(timedatectl show -p Timezone --value 2>/dev/null || true)
  [[ -n $tz ]] || tz=$(readlink -f /etc/localtime | sed -n 's|.*/zoneinfo/||p')
  echo "$tz"
}

. /etc/os-release
echo "系统：$PRETTY_NAME"

echo "时区"
had_zoneinfo=0
[[ -d /usr/share/zoneinfo ]] && had_zoneinfo=1
output=$(bash "$SYSTEM" Mars/Base 2>&1) && rc=0 || rc=$?
ok "无效时区报错" test "$rc" -ne 0
ok "提示无效的时区" contains "$output" "无效的时区：Mars/Base"
if ((had_zoneinfo)); then
  ok "报错发生在开始执行之前" lacks "$output" "[1/3]"
  fails "时区目录不能用作时区文件" bash "$SYSTEM" timezone Asia
  fails "时区数据库的文本清单也不能用作时区文件" bash "$SYSTEM" timezone zone.tab
else
  ok "缺少时区数据时先安装 tzdata" contains "$output" "安装时区数据 tzdata"
fi

echo "初始化"
ok "一键初始化（不指定时区，使用默认值）" bash "$SYSTEM"
cp "$work/out" "$work/init.out"
ok "默认时区为 Asia/Singapore" test "$(tz_now)" = Asia/Singapore
for tool in curl wget git vim htop unzip; do
  # 装不上的包（例如 RHEL 系没有 EPEL 时的 htop）必须在提示里点名
  if command -v "$tool" >/dev/null; then
    ok "已安装 $tool" true
  else
    ok "$tool 未安装时有提示" grep -q "未能安装：.*$tool" "$work/init.out"
  fi
done
ok "再次运行" bash "$SYSTEM" init Asia/Singapore
ok "再次运行时跳过已设置的时区" grep -q '时区已经是 Asia/Singapore' "$work/last"

echo "状态"
ok "状态页" bash "$SYSTEM" status
ok "状态页显示时区" grep -q 'Asia/Singapore' "$work/last"
ok "指定其他时区" bash "$SYSTEM" timezone Asia/Shanghai
ok "时区已改为 Asia/Shanghai" test "$(tz_now)" = Asia/Shanghai

# 在受控的包管理器上模拟整批成功和只安装了第一项就失败的情况。
# shellcheck disable=SC2317,SC2329  # 模拟函数由模块中的 install_tools 和 run_task 间接调用
exercise_batch() (
  local mode=$1 candidate
  # shellcheck source=/dev/null
  source "$SYSTEM"
  # shellcheck disable=SC2034  # install_tools 读取这份受控工具清单
  TOOLS=(curl wget htop)
  mkdir "$work/$mode"
  command_exists() { [[ -f $work/$mode/$1 ]]; }
  pkg_refresh() { :; }
  pkg_install() {
    echo "$*" >>"$work/$mode/calls"
    for candidate in "$@"; do
      if [[ $mode == partial && $candidate == wget ]]; then return 1; fi
      touch "$work/$mode/$candidate"
    done
  }
  install_tools
  if [[ $mode == full ]]; then install_tools; fi
)
ok "整批安装后再次初始化" exercise_batch full
ok "两次初始化只调用一次包管理器" test "$(cat "$work/full/calls")" = 'curl wget htop'
ok "批量部分失败后继续安装其余工具" exercise_batch partial
ok "失败项单独提示" grep -q '未能安装：wget' "$work/last"
ok "仅重试仍缺少的工具" test "$(cat "$work/partial/calls")" = $'curl wget htop\nwget\nhtop'

mkdir "$work/bin"
cat >"$work/bin/apt-get" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$APT_CALLS"
[[ $1 != update ]] || exit 100
EOF
chmod +x "$work/bin/apt-get"
mock_apt=(env "PATH=$work/bin:$PATH" "APT_CALLS=$work/apt.calls" bash "$ROOT/vps-init.sh" update)
fails "选项有误时拒绝升级" "${mock_apt[@]}" --yes --typo
ok "参数错误时没有调用包管理器" test ! -e "$work/apt.calls"
fails "刷新失败时自动更新返回错误" "${mock_apt[@]}" --yes
ok "刷新失败后没有运行 upgrade" test "$(cat "$work/apt.calls")" = 'update -q --error-on=any'

if [[ ${SKIP_UPDATE:-} != 1 ]]; then
  echo "系统更新"
  if command -v setsid >/dev/null; then
    fails "没有终端、也没有 --yes 时返回错误" setsid -w bash "$SYSTEM" update </dev/null
  fi
  ok "update --yes" bash "$SYSTEM" update --yes
  ok "提示更新完成" grep -q '系统更新完成' "$work/last"
fi

printf '\n通过 %d 项，失败 %d 项\n' "$passed" "$failed"
((failed == 0))
