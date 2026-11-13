#!/usr/bin/env python3
"""交互流程测试：用 pexpect 模拟真实终端，覆盖 SSH 向导、主菜单和防火墙。

需要 root 和 python3-pexpect。防火墙使用 tests/stubs 里的 UFW 替身，不会改动真实防火墙；
SSH 向导会在本机 sshd 上应用后再撤销。
"""
import os
import shutil
import subprocess
import sys
import tempfile
import traceback

import pexpect

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STUBS = os.path.join(ROOT, "tests", "stubs")
WORK = tempfile.mkdtemp()
UFW_DIR = os.path.join(WORK, "ufw")
DROP = "/etc/ssh/sshd_config.d/00-key-only.conf"
AUTH = "/root/.ssh/authorized_keys"
SSH_STATE = "/var/lib/vps-init/ssh"
FW_STATE_DIR = "/var/lib/vps-init/security"

ENV = dict(
    os.environ,
    PATH=f"{STUBS}:{os.environ['PATH']}",
    NO_COLOR="1",
    TERM="dumb",
    VPS_INIT_LOG=os.path.join(WORK, "vps-init.log"),
    UFW_STUB_DIR=UFW_DIR,
    SS_STUB_FILE=os.path.join(STUBS, "listening.txt"),
    SSH_CONNECTION="203.0.113.5 50000 198.51.100.1 22",
)


def keypair(name, comment):
    path = os.path.join(WORK, name)
    subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", comment, "-f", path], check=True)
    with open(path) as priv, open(path + ".pub") as pub:
        return priv.read(), pub.read().strip()


PRIV1, K1 = keypair("k1", "laptop")
_, K2 = keypair("k2", "phone")


def spawn(*args, env=None):
    child = pexpect.spawn("bash", list(args), cwd=ROOT, env=env or ENV, encoding="utf-8", timeout=15)
    child.logfile_read = open(os.path.join(WORK, "last.log"), "w")
    return child


def finish(child):
    child.expect(pexpect.EOF)
    child.close()
    return child.exitstatus


def sshd_value(key):
    out = subprocess.run(["sshd", "-T"], capture_output=True, text=True, check=True).stdout
    return next(line.split()[1] for line in out.splitlines() if line.startswith(key + " "))


def reset_ssh(keys=()):
    shutil.rmtree(SSH_STATE, ignore_errors=True)
    for path in (DROP, AUTH):
        if os.path.exists(path):
            os.remove(path)
    if keys:
        os.makedirs("/root/.ssh", mode=0o700, exist_ok=True)
        with open(AUTH, "w") as f:
            f.write("\n".join(keys) + "\n")


def reset_fw(active=False, rules=(), legacy=None):
    shutil.rmtree(UFW_DIR, ignore_errors=True)
    shutil.rmtree(FW_STATE_DIR, ignore_errors=True)
    os.makedirs(UFW_DIR)
    with open(os.path.join(UFW_DIR, "rules"), "w") as f:
        f.writelines(rule + "\n" for rule in rules)
    if active:
        open(os.path.join(UFW_DIR, "active"), "w").close()
    if legacy:
        os.makedirs(FW_STATE_DIR)
        with open(os.path.join(FW_STATE_DIR, "firewall-rule"), "w") as f:
            f.write(legacy)


def ufw_state():
    with open(os.path.join(UFW_DIR, "rules")) as f:
        rules = [line.strip() for line in f if line.strip()]
    return os.path.exists(os.path.join(UFW_DIR, "active")), rules


def fw_state_file():
    path = os.path.join(FW_STATE_DIR, "firewall.state")
    return open(path).read() if os.path.exists(path) else None


# ---------------- SSH 向导 ----------------
def test_ssh_wizard_happy_path():
    reset_ssh()
    c = spawn("modules/ssh.sh")
    c.expect("请选择 \\[1\\]"); c.sendline("")
    c.expect("粘贴公钥后回车"); c.sendline(K1)
    c.expect("laptop"); c.expect("还要添加其他公钥吗"); c.sendline("n")
    c.expect("确认执行"); c.sendline("y")
    c.expect("新窗口登录成功了吗"); c.sendline("y")
    c.expect("完成")
    assert finish(c) == 0
    assert sshd_value("passwordauthentication") == "no"
    subprocess.run(["bash", "modules/ssh.sh", "--undo"], cwd=ROOT, env=ENV, check=True, capture_output=True)


def test_ssh_wizard_mistakes_then_revert():
    reset_ssh()
    c = spawn("modules/ssh.sh")
    c.expect("请选择"); c.sendline("1")
    c.expect("粘贴公钥"); c.sendline("ssh-ed25519 AAAA... 这里替换为你的公钥")
    c.expect("无效公钥")
    c.expect("请选择"); c.sendline("1")
    c.expect("粘贴公钥"); c.send(PRIV1)  # 多行私钥一次粘贴
    c.expect("这是私钥")
    c.expect("请选择"); c.sendline("1")
    c.expect("粘贴公钥"); c.send(K1 + "\n" + K2 + "\n")
    c.expect("phone"); c.expect("还要添加其他公钥吗"); c.sendline("")
    c.expect("添加上面 2 把公钥")
    c.expect("确认执行"); c.sendline("y")
    c.expect("新窗口登录成功了吗"); c.sendline("n")
    c.expect("已恢复密码登录")
    assert finish(c) == 0
    assert not os.path.exists(DROP) and not os.path.exists(SSH_STATE)


def test_ssh_wizard_use_existing_then_cancel():
    reset_ssh([K1])
    c = spawn("modules/ssh.sh")
    c.expect("已有 1 把公钥"); c.expect("使用已有公钥")
    c.expect("请选择"); c.sendline("3")
    c.expect("确认执行"); c.sendline("")
    c.expect("已取消，没有做任何修改")
    assert finish(c) == 1
    assert not os.path.exists(DROP)


# ---------------- 主菜单 ----------------
def test_menu_returns_after_cancel():
    reset_ssh(); reset_fw()
    c = spawn("vps-init.sh")
    c.expect("密码登录")                # 状态面板（开启或关闭取决于本机原有配置）
    c.expect("UFW · 未启用")
    c.expect("请选择 \\[0-5\\]"); c.sendline("2")
    c.expect("请选择 \\[1\\]"); c.sendcontrol("d")  # 在 SSH 向导里取消
    c.expect("按回车返回菜单"); c.sendline("")
    c.expect("请选择 \\[0-5\\]"); c.sendline("5")
    c.expect("自动校时"); c.expect("root 公钥"); c.expect("防火墙")
    c.expect("按回车返回菜单"); c.sendline("")
    c.expect("请选择 \\[0-5\\]"); c.sendline("0")
    assert finish(c) == 0


def test_update_asks_first_and_can_cancel():
    c = spawn("modules/system.sh", "update")
    c.expect("开始更新"); c.sendline("")  # 直接回车 = 不更新
    c.expect("已取消，系统没有任何修改")
    assert finish(c) == 0


# ---------------- 防火墙 ----------------
def test_firewall_enable_pick_ports_and_undo():
    reset_fw()
    c = spawn("modules/firewall.sh")
    c.expect("UFW · 未启用"); c.expect("22/tcp · 未放行")
    c.expect("3000/tcp"); c.expect("node"); c.expect("8096/tcp"); c.expect("jellyfin")
    c.expect("Docker 映射的端口（8080/tcp）")  # Docker 端口单独提示，不让用户选
    c.expect("要一并放行哪些"); c.sendline("abc")
    c.expect("看不懂")
    c.expect("要一并放行哪些"); c.sendline("3000 51413")
    for rule in ("22/tcp", "3000/tcp", "51413/tcp", "51413/udp"):
        c.expect("放行 " + rule)
    c.expect("启用 UFW")
    c.expect("确认执行"); c.sendline("y")
    c.expect("新窗口能连上吗"); c.sendline("y")
    c.expect("完成")
    assert finish(c) == 0
    active, rules = ufw_state()
    assert active and rules == ["allow 22/tcp", "allow 3000/tcp", "allow 51413/tcp", "allow 51413/udp"], rules
    assert "enabled=1" in fw_state_file()

    c = spawn("modules/firewall.sh")
    c.expect("无需修改")
    assert finish(c) == 0

    c = spawn("modules/firewall.sh", "--undo")
    c.expect("关闭 UFW（它是本工具启用的）")
    c.expect("确认撤销"); c.sendline("y")
    c.expect("已撤销本工具的防火墙修改")
    assert finish(c) == 0
    assert ufw_state() == (False, []) and fw_state_file() is None


def test_firewall_failed_test_reverts():
    reset_fw()
    c = spawn("modules/firewall.sh")
    c.expect("要一并放行哪些"); c.sendline("")
    c.expect("确认执行"); c.sendline("y")
    c.expect("新窗口能连上吗"); c.sendline("n")
    c.expect("已撤销本次修改")
    assert finish(c) == 0
    assert ufw_state() == (False, []) and fw_state_file() is None


def test_firewall_recognises_existing_ssh_rules():
    for rule in ("allow 22", "allow OpenSSH", "limit 22/tcp"):
        reset_fw(active=True, rules=[rule])
        c = spawn("modules/firewall.sh")
        c.expect("无需修改")
        assert finish(c) == 0, rule
        assert ufw_state() == (True, [rule]), rule


def test_firewall_undo_keeps_preexisting_rules():
    reset_fw(rules=["allow 3000/tcp"])
    c = spawn("modules/firewall.sh")
    c.expect("8096/tcp")
    c.expect("要一并放行哪些"); c.sendline("3000")  # 3000 已有规则，不应算作本工具添加
    c.expect("确认执行"); c.sendline("y")
    c.expect("新窗口能连上吗"); c.sendline("y")
    assert finish(c) == 0
    assert "rules=22/tcp\n" in fw_state_file()
    c = spawn("modules/firewall.sh", "--undo")
    c.expect("确认撤销"); c.sendline("y")
    assert finish(c) == 0
    assert ufw_state() == (False, ["allow 3000/tcp"])


def test_firewall_legacy_state_warns_before_removing_ssh_rule():
    reset_fw(active=True, rules=["allow 22/tcp"], legacy="ufw\n22\n-\n")
    c = spawn("modules/firewall.sh", "--undo")
    c.expect("删除规则 22/tcp")
    c.expect("新的 SSH 连接会被拒绝")
    c.expect("确认撤销"); c.sendline("n")
    c.expect("已取消")
    assert finish(c) == 0
    assert ufw_state() == (True, ["allow 22/tcp"])


def test_firewall_not_installed():
    if any(shutil.which(tool, path="/usr/sbin:/sbin:/usr/bin:/bin") for tool in ("ufw", "firewall-cmd")):
        return print("    （本机装有真实防火墙，跳过「未安装」场景）")
    bare = os.path.join(WORK, "bare")
    os.makedirs(bare, exist_ok=True)
    for tool in ("ss", "systemctl"):
        shutil.copy(os.path.join(STUBS, tool), bare)
    c = spawn("modules/firewall.sh", env=dict(ENV, PATH=f"{bare}:{os.environ['PATH']}"))
    c.expect("没有安装 UFW 或 Firewalld")
    assert finish(c) == 0


def main():
    if os.geteuid() != 0:
        sys.exit("需要 root 运行")
    backup = open(AUTH).read() if os.path.exists(AUTH) else None
    tests = [(name, fn) for name, fn in globals().items() if name.startswith("test_")]
    failed = 0
    try:
        for name, fn in tests:
            try:
                fn()
                print(f"  ✓ {fn.__name__}")
            except Exception:
                failed += 1
                print(f"  ✗ {fn.__name__}")
                print("      " + traceback.format_exc().strip().replace("\n", "\n      "))
                log = open(os.path.join(WORK, "last.log")).read()
                print("      ---- 终端输出 ----\n      " + log[-1500:].replace("\n", "\n      "))
    finally:
        reset_ssh()
        if backup is not None:
            os.makedirs("/root/.ssh", mode=0o700, exist_ok=True)
            open(AUTH, "w").write(backup)
        shutil.rmtree(FW_STATE_DIR, ignore_errors=True)
        shutil.rmtree(WORK, ignore_errors=True)
    print(f"\n通过 {len(tests) - failed} 项，失败 {failed} 项")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
