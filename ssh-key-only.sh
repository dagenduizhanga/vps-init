#!/usr/bin/env bash
# SSH 密钥登录向导：给 root 装上公钥，然后关闭密码登录。可重复运行，任何检查不通过都会自动回滚。
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/dagenduizhanga/vps-init/main/ssh-key-only.sh)
#
# 不带参数：交互式向导，一步步提示输入。
# 带一个参数：不提问，直接执行（适合自动化）
#   'ssh-ed25519 AAAA... 备注'   直接给公钥
#   gh:<GitHub用户名>             使用 github.com/<用户名>.keys 上的全部公钥
#   https://example.com/key.pub   从网址拉取公钥
#   --undo                        撤销：恢复系统原有的登录方式（已装的公钥保留）
#
# 只写入 /etc/ssh/sshd_config.d/00-key-only.conf，不改 sshd_config 本身。需要 OpenSSH 8.2+。
set -euo pipefail
export PATH=$PATH:/usr/sbin:/sbin

URL=https://raw.githubusercontent.com/dagenduizhanga/vps-init/main/ssh-key-only.sh
DROP=/etc/ssh/sshd_config.d/00-key-only.conf
AUTH=/root/.ssh/authorized_keys
KEYS=()

if [[ -t 1 ]]; then R=$'\e[31m' G=$'\e[32m' Y=$'\e[33m' B=$'\e[1m' N=$'\e[0m'; else R='' G='' Y='' B='' N=''; fi
err()  { echo "${R}✗ $*${N}" >&2; }
die()  { err "$@"; exit 1; }
ok()   { echo "${G}✓${N} $*"; }
warn() { echo "${Y}⚠ $*${N}"; }
step() { echo; echo "${B}[$1/4] $2${N}"; }

# 交互输入一律读 /dev/tty，所以 curl ... | bash 也能用
ask() {
    local a l
    printf '%s' "$1" >/dev/tty
    IFS= read -r a </dev/tty || die "已取消"
    while IFS= read -r -t 0.2 l </dev/tty; do a+=$'\n'$l; done # 一次粘贴多行时，把剩下的行也收进来
    printf '%s' "$a"
}
confirm() { [[ $(ask "$1 [y/N] ") == [yY]* ]]; }

fp() { ssh-keygen -lf - <<<"$1" 2>/dev/null | awk '{print $2}'; }
list_auth() { ssh-keygen -lf "$AUTH" 2>/dev/null || true; }

fetch() {
    case $1 in
        gh:*)                 curl -fsSL "https://github.com/${1#gh:}.keys" ;;
        http://* | https://*) curl -fsSL "$1" ;;
        *)                    printf '%s\n' "$1" ;;
    esac
}

# 校验一段文本里的公钥：全部有效才加入 KEYS
add_keys() {
    local k t b
    local -a new=()
    [[ $1 == *"PRIVATE KEY"* ]] &&
        { err "这是私钥！私钥只能留在你自己的设备上，这里要的是公钥（ssh-ed25519 / ssh-rsa 开头的一行）"; return 1; }
    while IFS= read -r k; do
        k=${k%$'\r'}
        [[ -z ${k//[[:space:]]/} || $k == \#* ]] && continue
        read -r t b _ <<<"$k"
        [[ -n $(fp "$k") ]] || { err "无效公钥：$t ${b:0:16}…"; return 1; }
        new+=("$k")
    done <<<"$1"
    ((${#new[@]})) || { err "没有找到公钥"; return 1; }
    KEYS+=("${new[@]}")
    for k in "${new[@]}"; do ok "$(ssh-keygen -lf - <<<"$k")"; done
}

precheck() {
    command -v sshd >/dev/null || die "没有找到 sshd，请先安装 openssh-server"
    grep -Eiq '^[[:space:]]*Include[[:space:]].*sshd_config\.d' /etc/ssh/sshd_config ||
        die "sshd_config 不支持 sshd_config.d（OpenSSH 8.2 以下的老系统），本脚本不适用"
}

reload_sshd() {
    sshd -t || die "sshd 配置检查失败，未重载"
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null ||
        service ssh reload 2>/dev/null || service sshd reload 2>/dev/null ||
        die "重载 sshd 失败，请手动重载"
}

undo() {
    rm -f "$DROP"
    reload_sshd
    ok "已撤销，SSH 恢复为系统原有的登录方式"
}

apply() {
    local k f have prev kv eff

    # 安装公钥：按指纹去重，备注不同也不会重复添加
    install -d -m 700 /root/.ssh
    touch "$AUTH" && chmod 600 "$AUTH"
    have=$(list_auth | awk '{print $2}')
    if ((${#KEYS[@]})); then
        for k in "${KEYS[@]}"; do
            f=$(fp "$k")
            grep -qxF "$f" <<<"$have" && continue
            printf '%s\n' "$k" >>"$AUTH"
            have+=$'\n'$f
        done
    fi
    if command -v restorecon >/dev/null; then restorecon -R /root/.ssh; fi
    [[ -n $(list_auth) ]] || die "root 没有任何公钥，不能关闭密码登录"

    # 写入配置；00- 前缀保证排在 50-cloud-init.conf 等之前（sshd 取第一次出现的值）
    prev=$(cat "$DROP" 2>/dev/null || true)
    rollback() {
        if [[ -n $prev ]]; then printf '%s\n' "$prev" >"$DROP"; else rm -f "$DROP"; fi
        die "$1，已回滚，SSH 配置未改动"
    }
    install -d /etc/ssh/sshd_config.d
    cat >"$DROP" <<'EOF'
# 由 ssh-key-only.sh 生成；删除本文件并重载 sshd 即可恢复原有登录方式
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin prohibit-password
EOF

    # 校验语法和最终生效值，通过后才重载
    eff=$(sshd -T 2>&1) || rollback "sshd 配置检查失败：$eff"
    for kv in "pubkeyauthentication yes" "passwordauthentication no" \
              "kbdinteractiveauthentication no" "permitrootlogin without-password"; do
        grep -qx "$kv" <<<"$eff" ||
            rollback "生效值不是「$kv」（可能被更早的配置覆盖）"
    done
    reload_sshd
    ok "已启用密钥登录、关闭密码登录"
}

wizard() {
    local existing choice src u
    { : </dev/tty; } 2>/dev/null || die "没有可交互的终端；自动化场景请带参数运行（见脚本开头说明）"

    echo "${B}SSH 密钥登录向导${N}"
    echo "装好你的公钥后关闭密码登录，之后 root 只能用密钥登录。确认之前不会做任何改动。"

    step 1 "检查环境"
    precheck
    # shellcheck source=/dev/null
    ok "$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Linux}")，支持 sshd_config.d"
    existing=$(list_auth)
    if [[ -n $existing ]]; then
        echo "root 目前已有 $(grep -c . <<<"$existing") 把公钥："
        list_auth | sed 's/^/    /'
    else
        echo "root 目前还没有公钥。"
    fi

    step 2 "添加公钥"
    while :; do
        echo "  1) 粘贴公钥（例如在 Termius 的 Keychain 里复制的公钥）"
        echo "  2) 从 GitHub 账号导入（github.com/用户名.keys）"
        [[ -n $existing && ${#KEYS[@]} -eq 0 ]] && echo "  3) 不添加，直接用上面已有的公钥"
        choice=$(ask "请选择 [1]：")
        case ${choice//[[:space:]]/} in
            "" | 1) src=$(ask "粘贴公钥后回车：") ;;
            2)
                u=$(ask "GitHub 用户名：")
                u=${u//[[:space:]]/}
                [[ $u =~ ^[A-Za-z0-9-]+$ ]] || { err "用户名格式不对"; continue; }
                src=$(fetch "gh:$u") || { err "拉取失败，请检查用户名或网络"; continue; }
                warn "将导入 $u 账号上的全部公钥，每一把都能登录 root："
                ;;
            3)
                [[ -n $existing && ${#KEYS[@]} -eq 0 ]] && break
                err "请输入 1 或 2"; continue
                ;;
            *) err "请输入列表里的数字"; continue ;;
        esac
        add_keys "$src" || continue
        confirm "还要再添加一把公钥吗？" || break
    done

    step 3 "确认"
    echo "即将执行："
    if ((${#KEYS[@]})); then echo "  • 把上面 ${#KEYS[@]} 把公钥加入 $AUTH（已存在的自动跳过）"; fi
    echo "  • 关闭密码登录，root 只能用密钥登录"
    echo "  • 配置只写在 $DROP，随时可以撤销"
    confirm "确认执行？" || die "已取消，未做任何改动"

    step 4 "应用"
    apply

    echo
    warn "先别关这个窗口！现在新开一个终端，用密钥登录这台服务器试试。"
    if confirm "新窗口用密钥登录成功了吗？（回答 n 会撤销，恢复密码登录）"; then
        ok "全部完成。以后要撤销：bash <(curl -fsSL $URL) --undo"
    else
        undo
        warn "密码登录已恢复。请确认这里粘贴的公钥和 Termius 里用的是同一把密钥，再重新运行。"
    fi
}

main() {
    [[ $EUID -eq 0 ]] || die "请用 root 运行"
    (($# <= 1)) || die "参数太多；公钥请用引号整体括起来"
    case ${1-} in
        "")        wizard ;;
        --undo)    undo ;;
        -h | --help) echo "用法：bash <(curl -fsSL $URL) [公钥 | gh:用户名 | https://... | --undo]" ;;
        *)
            precheck
            src=$(fetch "$1") || die "拉取公钥失败：$1"
            add_keys "$src" || exit 1
            apply
            warn "先别关当前窗口：新开窗口用密钥登录成功后再退出。"
            ;;
    esac
}

# 整个脚本下载、解析完才执行，下载中断时不会只跑半截
main "$@"
